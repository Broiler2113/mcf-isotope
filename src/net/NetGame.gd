class_name NetGame
extends RefCounted

## Транспорт-независимая логика сетевой партии (M7, §2.3). Хост — единственный,
## кто реально бросает кубики: он резолвит намерение, ЗАПИСЫВАЕТ броски и рассылает
## клиенту {намерение + броски}. Клиент воспроизводит то же намерение, ПОДСТАВЛЯЯ
## присланные броски, — тот же резолвер, тот же исход, без рассинхрона RNG.
##
## Транспорт подключается снаружи: исходящие сообщения идут через сигнал `outgoing`,
## входящие подаются в receive(). Это позволяет гонять протокол и на ENet, и в тестах
## через прямой loopback между двумя NetGame.

## Применено локально одно действие (для UI: лог + анимация кубиков).
signal action_applied(intent: Intent, result: ActionResult)
## Сообщение, которое транспорт должен доставить второй стороне.
signal outgoing(msg: Dictionary)
## Клиент принял авторитетный порядок инициативы хоста (#53) — обновить HUD.
signal initiative_synced()
## Гость подтянул доску хоста целиком (batch 14) — экран обязан перечитать состояние.
signal resynced()
## Хост отверг НАШЕ намерение (batch 17, item 4): причина для журнала. Раньше отказ
## оставался на хосте, а у гостя кнопка просто «не работала» — ни строки в логе.
signal denied(reason: String)
## Гость сверил доску с хостом после действия и она не сошлась — просьба уже ушла.
signal desync_detected()
## Host: a guest asked for a full snapshot because its board drifted (DesyncReport).
signal resync_requested(from: int)

const K_INTENT := "intent"   # клиент → хост: «прошу выполнить моё намерение»
## Гость обнаружил, что его доска разошлась с доской хоста (batch 14): просит снимок.
const K_RESYNC := "resync"
## Хост → гость: полный снимок состояния (StateCodec) в ответ на K_RESYNC.
const K_STATE := "state"
const K_ACTION := "action"   # хост → клиент: «авторитетное действие + броски»
const K_INIT := "init"       # хост → клиент: порядок инициативы на всю партию
const K_DENIED := "denied"   # хост → клиент: намерение отвергнуто (actor + причина)

var state: GameState
var resolver: GameActionResolver
var is_host: bool
var my_owner: int
## Итог открывающего слота мирных (#96). Ход отыгрывается здесь, чтобы броски у хоста
## и клиента совпали, но показать его — дело UI: он ждёт `initiative_synced` и прогоняет
## этот результат через обычную анимацию кубиков.
var opening_civilians: ActionResult = ActionResult.success()
## Косметика поля (кровь, осколки, гильзы, разбитый пол) в снимок пересинхронизации
## (batch mp-perf): хост отдаёт свою (fx_snapshot -> FxDecals.to_dict), гость получает её в
## restored_fx и кладёт поверх доски — после пересинхронизации поле выглядит как у хоста.
var fx_snapshot: Callable = Callable()
var restored_fx: Dictionary = {}
## Shares the existing host dice log; never starts a second recording stream.
var recorder: ReplayRecorder = null
## The last actions this side applied, oldest first: the wire, its rolls and the board
## fingerprints around it (a guest's "want" is the host's). A desync report carries them.
var recent: Array = []
const RECENT_MAX := 20

func _remember(entry: Dictionary) -> void:
	recent.append(entry)
	if recent.size() > RECENT_MAX:
		recent.pop_front()

## p_my_owner — сторона, за которую играет ЭТА машина. −1 означает старую дуэльную
## раскладку «хост — первый, гость — второй»; лобби на N игроков передаёт номер явно.
func _init(p_state: GameState, p_resolver: GameActionResolver, p_is_host: bool,
		p_my_owner: int = -1) -> void:
	state = p_state
	resolver = p_resolver
	is_host = p_is_host
	if MCF.is_player(p_my_owner) or p_my_owner == -2:
		my_owner = p_my_owner
	else:
		my_owner = MCF.Owner.PLAYER_1 if is_host else MCF.Owner.PLAYER_2

## Стороны, которыми управляют НЕ на этой машине — им нужен NetworkController.
## Раньше такая сторона была ровно одна; теперь их столько, сколько игроков минус я.
func remote_owners() -> Array[int]:
	var out: Array[int] = []
	for side in state.roster.player_ids():
		if side != my_owner:
			out.append(side)
	if out.is_empty():
		out.append(MCF.Owner.PLAYER_2 if my_owner == MCF.Owner.PLAYER_1
				else MCF.Owner.PLAYER_1)
	return out

## Локальный игрок подал намерение (через свой LocalHumanController).
func submit_local(intent: Intent) -> void:
	if my_owner == -2: return
	if is_host:
		_host_resolve_and_send(intent)
	else:
		if intent is EndTurnIntent:
			if _end_turn_pending: return
			_end_turn_pending = true
		if intent is EndTurnIntent or intent is UndoIntent or intent is RedoIntent:
			intent.requester = my_owner
		outgoing.emit({"k": K_INTENT, "i": IntentCodec.encode(intent)})

## Пришло сообщение от второй стороны.
## Сообщение приходит из сети, то есть от чужой машины: считать его правильным
## нельзя. Раньше msg["i"] индексировался напрямую, и пакет без этого ключа ронял
## пир целиком (AUDIT §2.5); нераспознанное намерение декодируется в null и точно
## так же роняло резолвер.
func receive(msg: Dictionary) -> void:
	match msg.get("k", ""):
		K_INTENT:
			if is_host:
				var it := _decode(msg)
				var from := int(msg.get("_from", -1))
				if it != null and _authorized(it, from):
					_host_resolve_and_send(it)
				elif from != -1:
					# Silence left the sender waiting forever (_net_request_pending in Main).
					outgoing.emit({"k": K_DENIED, "a": -1, "reason": "Not your unit or turn",
						"p": state.roster.side_of_peer(from)})
		K_ACTION:
			if not is_host:
				var it := _decode(msg)
				if it != null:
					_client_apply(it, msg.get("r", []), int(msg.get("h", 0)))
		K_INIT:
			if not is_host:
				_client_adopt_initiative(msg)
		K_RESYNC:
			if is_host:
				var snap := {"k": K_STATE, "s": StateCodec.encode(state)}
				if fx_snapshot.is_valid():
					snap["fx"] = fx_snapshot.call()
				# Облака газа и дыма живут не на доске, а в событиях (0.12): без них гость
				# после пересинхронизации видел бы сквозь чужую завесу (или упирался в свою).
				if resolver.random_events != null:
					snap["ev"] = resolver.random_events.snapshot()
				# Счёт, зоны и волны режима (0.12) тоже живут на резолвере.
				snap["mode"] = resolver.mode.snapshot()
				outgoing.emit(snap)
				resync_requested.emit(int(msg.get("_from", -1)))
		K_STATE:
			if not is_host:
				_client_restore(msg)
		K_DENIED:
			if not is_host:
				if int(msg.get("p", -1)) == my_owner:
					_end_turn_pending = false
					denied.emit(str(msg.get("reason", "")))
					return
				var actor := state.get_unit(int(msg.get("a", -1)))
				if actor != null and actor.owner == my_owner:
					denied.emit(str(msg.get("reason", "")))

func _decode(msg: Dictionary) -> Intent:
	var raw: Variant = msg.get("i")
	if not (raw is Dictionary):
		return null
	return IntentCodec.decode(raw)

## Хост: разослать порядок инициативы (#53) и сразу отыграть стартовый слот мирных.
## Бросок инициативы делается локально у каждой стороны из СВОИХ кубиков, поэтому у
## клиента он вышел бы другим — авторитетным считаем порядок хоста, как и всё
## остальное в сетевой партии.
##
## Мирные ходят ВНЕ потока намерений, так что открывающий слот тоже пришлось бы
## бросать дважды. Записываем его броски здесь и везём вместе с порядком: клиент
## воспроизведёт ровно тот же ход жителей (#93).
func announce_initiative() -> void:
	if not is_host:
		return
	# Порядок и позицию снимаем ДО хода жителей: клиент должен встать в ту же точку
	# и проиграть тот же слот, иначе он просто пропустит его (active_index уже уехал).
	var msg := {"k": K_INIT, "o": state.turns.round_order.duplicate(),
			"a": state.turns.active_index, "n": state.turns.round_number}
	state.dice.begin_record()
	opening_civilians = resolver.open_match()
	msg["r"] = state.dice.take_log()
	if recorder != null:
		recorder.opening = msg["r"].duplicate()
		recorder.opening_processed = true
		recorder.observe_opening(opening_civilians)
	state.dice.record_enabled = false
	outgoing.emit(msg)
	initiative_synced.emit()

## Клиент: принять порядок хоста вместо своего и повторить его открывающий слот мирных.
func _client_adopt_initiative(msg: Dictionary) -> void:
	var order: Array[int] = []
	for s in msg.get("o", []):
		order.append(int(s))
	if order.is_empty():
		return
	state.turns.round_order = order
	state.turns.active_index = clampi(int(msg.get("a", 0)), 0, order.size() - 1)
	state.turns.round_number = maxi(int(msg.get("n", 1)), 1)
	state.turns.initiative_rolled = true
	state.dice.feed_scripted(msg.get("r", []))
	opening_civilians = resolver.open_match()
	initiative_synced.emit()

# --- Хост: авторитетный резолв + рассылка ---
func _host_resolve_and_send(intent: Intent) -> void:
	state.dice.begin_record()
	var result := _resolve_showing_ap(intent)
	var rolls := state.dice.take_log()
	state.dice.record_enabled = false
	if result.ok:
		if recorder != null:
			recorder.on_resolved(intent, rolls, result)
		# Подпись доски ПОСЛЕ действия (batch 14): гость сверит с ней свою.
		var digest := state.digest_hash()
		outgoing.emit({"k": K_ACTION, "i": IntentCodec.encode(intent), "r": rolls, "h": digest})
		_remember({"i": IntentCodec.encode(intent), "r": rolls, "h": digest,
				"round": state.turns.round_number})
	else:
		outgoing.emit({"k": K_DENIED, "a": intent.actor_id, "reason": result.reason,
			"p": intent.requester if intent is EndTurnIntent or intent is UndoIntent or intent is RedoIntent else -1})
	action_applied.emit(intent, result)

# --- Клиент: воспроизведение с присланными бросками ---
## Просьба о снимке уже ушла — до его прихода новые расхождения не считаем.
var _resync_pending: bool = false
var _end_turn_pending := false

func _client_apply(intent: Intent, rolls: Array, expected: int = 0) -> void:
	if intent is EndTurnIntent and intent.requester == my_owner: _end_turn_pending = false
	state.dice.feed_scripted(rolls)
	var result := _resolve_showing_ap(intent)
	# Сверка с хостом (batch 14): действие, которое у хоста прошло, а у нас отвергнуто,
	# недоеденные или недостающие броски, иная подпись доски — всё это рассинхрон. Раньше
	# он копился молча и всплывал как «Unit not found» на каждое действие хоста; теперь
	# гость просит у хоста полный снимок и продолжает с него.
	var left := state.dice.scripted_remaining()
	var digest := state.digest_hash()
	_remember({"i": IntentCodec.encode(intent), "r": rolls, "want": expected, "h": digest,
			"ok": result.ok, "reason": result.reason, "rolls_left": left,
			"round": state.turns.round_number})
	var drift := not result.ok or left > 0 or (expected != 0 and digest != expected)
	if drift and not _resync_pending:
		_resync_pending = true
		state.dice.clear_scripted()
		# Before the request: the drifted board is still here for a report to capture.
		desync_detected.emit()
		outgoing.emit({"k": K_RESYNC})
	action_applied.emit(intent, result)

func _client_restore(msg: Dictionary) -> void:
	_end_turn_pending = false
	var data: Variant = msg.get("s")
	if not (data is Dictionary):
		return
	StateCodec.restore_into(state, data)
	var ev: Variant = msg.get("ev")
	if ev is Dictionary:
		if resolver.random_events == null:
			resolver.random_events = RandomEvents.new(false)
		resolver.random_events.restore(ev)
	var md: Variant = msg.get("mode")
	if md is Dictionary:
		resolver.mode.restore(md)
	# Газ и дым на клетках — выводимые: доска пришла без них, выводим из облаков заново.
	resolver._sync_gas()
	var fx: Variant = msg.get("fx")
	restored_fx = fx if fx is Dictionary else {}
	state.dice.clear_scripted()
	_resync_pending = false
	resynced.emit()

## Резолв + событие «точка ОД погасла» (#99). Остаток снимаем ДО действия, потому что
## к моменту сигнала состояние уже изменено, и по нему не понять, чего ход стоил. Так
## жёлтые точки соперника гаснут по одной, как и в игре за одним экраном.
## На симуляцию это не влияет: dice_events по сети не ходят — едут только намерения.
func _resolve_showing_ap(intent: Intent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id) if intent.actor_id >= 0 else null
	var before := actor.remaining_ap if actor != null else 0
	var result := resolver.resolve(intent)
	if actor != null and result.ok and actor.remaining_ap != before \
			and not result.dice_events.is_empty():
		result.dice_events.append({"kind": "ap", "unit": actor.id,
				"from": before, "left": actor.remaining_ap})
	return result

## Authenticate the sending peer, not a side number supplied in its payload.
func _authorized(intent: Intent, peer: int) -> bool:
	if peer == -1: return true # In-process test/legacy transport; ENet always supplies _from.
	var side := state.roster.side_of_peer(peer)
	if side < 0: return false
	if intent is EndTurnIntent or intent is UndoIntent or intent is RedoIntent:
		return intent.requester == side
	# Tank/shuttle drive, turn and cannon orders carry the VEHICLE id (Vehicle.ID_BASE+).
	var actor: Variant = state.get_unit(intent.actor_id)
	if actor == null: actor = state.get_vehicle(intent.actor_id)
	if actor == null or actor.owner != side: return false
	if intent is GroupMoveIntent:
		for id in intent.unit_ids:
			var unit := state.get_unit(id)
			if unit == null or unit.owner != side: return false
	return true
