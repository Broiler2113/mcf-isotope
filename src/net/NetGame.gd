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

const K_INTENT := "intent"   # клиент → хост: «прошу выполнить моё намерение»
const K_ACTION := "action"   # хост → клиент: «авторитетное действие + броски»
const K_INIT := "init"       # хост → клиент: порядок инициативы на всю партию

var state: GameState
var resolver: GameActionResolver
var is_host: bool
var my_owner: int
## Итог открывающего слота мирных (#96). Ход отыгрывается здесь, чтобы броски у хоста
## и клиента совпали, но показать его — дело UI: он ждёт `initiative_synced` и прогоняет
## этот результат через обычную анимацию кубиков.
var opening_civilians: ActionResult = ActionResult.success()

## p_my_owner — сторона, за которую играет ЭТА машина. −1 означает старую дуэльную
## раскладку «хост — первый, гость — второй»; лобби на N игроков передаёт номер явно.
func _init(p_state: GameState, p_resolver: GameActionResolver, p_is_host: bool,
		p_my_owner: int = -1) -> void:
	state = p_state
	resolver = p_resolver
	is_host = p_is_host
	if MCF.is_player(p_my_owner):
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
	if is_host:
		_host_resolve_and_send(intent)
	else:
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
				if it != null:
					_host_resolve_and_send(it)
		K_ACTION:
			if not is_host:
				var it := _decode(msg)
				if it != null:
					_client_apply(it, msg.get("r", []))
		K_INIT:
			if not is_host:
				_client_adopt_initiative(msg)

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
	opening_civilians = resolver.play_civilian_slots()
	msg["r"] = state.dice.take_log()
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
	opening_civilians = resolver.play_civilian_slots()
	initiative_synced.emit()

# --- Хост: авторитетный резолв + рассылка ---
func _host_resolve_and_send(intent: Intent) -> void:
	state.dice.begin_record()
	var result := _resolve_showing_ap(intent)
	var rolls := state.dice.take_log()
	state.dice.record_enabled = false
	if result.ok:
		outgoing.emit({"k": K_ACTION, "i": IntentCodec.encode(intent), "r": rolls})
	action_applied.emit(intent, result)

# --- Клиент: воспроизведение с присланными бросками ---
func _client_apply(intent: Intent, rolls: Array) -> void:
	state.dice.feed_scripted(rolls)
	action_applied.emit(intent, _resolve_showing_ap(intent))

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
