extends SceneTree

## Сервер среды для обучения (RL v1, spec §1 C1, §5.1, §9.1). Один процесс — один слот
## векторизованной среды: тренер на Python говорит с ним JSON-строками через stdin/stdout.
##
##   → {"cmd":"reset", "map":"/abs/path.json", "seed":N, "side":0|1, "opponent":0|1|2|-1,
##      "round_cap":10, "max_steps":3000, "civilians":false, "random_events":false, "fog":1,
##      "friendly_fire":true, "record":true, "max_candidates":0, "max_actors":0}
##   ← {"ok":true, "obs":{...}, "legal":[...], "acting":side, "reward":0, "done":false}
##   → {"cmd":"step", "action":k}          k — индекс в последнем списке legal
##   ← {"obs":..., "legal":[...], "acting":side, "reward":r, "done":bool, "info":{...}}
##   → {"cmd":"save_replay", "path":"/abs/x.mcfr"}   ← {"ok":true}
##   → {"cmd":"quit"}
##
## Ход противника (opponent >= 0 — AIController этой сложности) разыгрывается ВНУТРИ
## процесса, как в tests/run_headless.gd; opponent == -1 означает «внешняя политика»:
## тогда точки решения отдаются и за вторую сторону (поле acting), а тренер сам решает,
## чьи шаги идут в обучение. Награда всегда со стороны side (обучаемого): разница
## стоимости армий с прошлого ответа (§6.1), штраф за передачу хода, терминал ±1, ничья
## по лимиту раундов — малый минус.
##
## Только запись stdout вида {...} — протокол; всё остальное (баннер Godot, ошибки)
## Python отбрасывает. Резолвер обучаемого ходит БЕЗ всеведения (§3.3): туман — тот же,
## что видит человек.

const Obs = preload("res://rl/ObsEncoder.gd")

const R_TURN_PENALTY := -0.01
const R_DRAW := -0.1
const AI_TURN_CAP := 4000
## Цена ОДНОГО своего действия. Без неё «не делать ничего» было строго выгоднее, чем
## закончить ход: конец хода стоит R_TURN_PENALTY, а бесплатное действие — ноль. Политика
## это нашла: 75% её действий стали move_held (бесплатная перекладка пленника), end — 0.4%,
## и за 13 апдейтов доигрались ДВЕ партии. Теперь тикает время само по себе, и топтание на
## месте проигрывает любому осмысленному ходу. Число мало нарочно: ~0.02 за полный ход из
## 40 действий против ±1 за исход партии.
const R_STEP_PENALTY := -0.0005
## Сколько БЕСПЛАТНЫХ (не потративших ОД) действий разрешено одному юниту за ход.
## Ограничение структурное, а не через награду: перечислитель обязан предлагать такие
## намерения (перекладка пленника и тела — законные ходы), но не бесконечно же.
const FREE_ACTIONS_PER_UNIT := 6
## …и сколько их разрешено ВСЕЙ стороне за ход. Потолка на юнита мало: на town'е 176
## бойцов, то есть 176 × 6 ≈ 1000 бесплатных действий за ход — экономия на порядок, а
## затык остаётся. Проверено: жадная «эксплойтная» политика всё равно упиралась в
## max_steps. Общий бюджет режет именно это; для честной игры он щедр — перекладывают
## пленников и тела единицы юнитов, а не рота.
const FREE_ACTIONS_PER_TURN := 48

var state: GameState = null
var resolver: GameActionResolver = null
var side: int = MCF.Owner.PLAYER_1
var opponent: int = AIController.Difficulty.NORMAL
var round_cap: int = 10
## Потолок шагов эпизода (обеих сторон); задаётся в reset как "max_steps", иначе 300 на раунд.
var max_steps: int = 3000
## Потолок КАНДИДАТОВ на точку решения (0 — без потолка). Ротные карты вроде town дают
## 8000+ законных намерений за ход (из них ~5000 — «шагнуть в клетку»), и цена у этого
## тройная: перечислитель, JSON и тензор кандидатов в буфере роллаута. Потолок режет
## список ЗДЕСЬ, до describe и до провода, — см. _cap_legal().
var max_candidates: int = 0
## Потолок АКТЁРОВ, рассматриваемых за шаг (0 — все). Бьёт по самой дорогой части шага —
## перечислителю; см. _actor_subset().
var max_actors: int = 0
var _cap_rng := RandomNumberGenerator.new()
var brains: Dictionary = {}
var recorder: ReplayRecorder = null
var _legal: Array = []
var _pending: Intent = null
var _norm: float = 1.0
var _last_diff: float = 0.0
var _done: bool = true
var _illegal: int = 0
var _steps: int = 0
var _result: String = ""
## Бесплатные действия за текущий ход: ключ актёра → счётчик, и "<ключ>|<вид>" → true.
## Обнуляются на смене хода (_turn_token). См. FREE_ACTIONS_PER_UNIT и _drop_looping().
var _free_count: Dictionary = {}
var _free_kinds: Dictionary = {}
var _free_turn: String = ""
var _free_total: int = 0

func _initialize() -> void:
	while true:
		var line := OS.read_string_from_stdin(1 << 22)
		if line == "":
			break
		line = line.strip_edges()
		if not line.begins_with("{"):
			continue
		var req: Variant = JSON.parse_string(line)
		if typeof(req) != TYPE_DICTIONARY:
			print(JSON.stringify({"ok": false, "error": "bad json"}))
			continue
		var cmd: String = str(req.get("cmd", ""))
		var resp: Dictionary
		match cmd:
			"reset": resp = _reset(req)
			"step": resp = _step(req)
			"save_replay": resp = _save_replay(str(req.get("path", "")))
			"ping": resp = {"ok": true}
			"quit":
				print(JSON.stringify({"ok": true}))
				break
			_: resp = {"ok": false, "error": "unknown cmd %s" % cmd}
		print(JSON.stringify(resp))
	quit(0)

# --- Эпизод -------------------------------------------------------------------------

func _reset(req: Dictionary) -> Dictionary:
	var path := str(req.get("map", ""))
	var m := MapData.load_from(path)
	if m == null:
		return {"ok": false, "error": "map not found: %s" % path}
	GameConfig.civilians_enabled = bool(req.get("civilians", false))
	var seed_value := int(req.get("seed", 1))
	state = m.build_state(seed_value)
	for pid: int in state.roster.player_ids():
		var s := state.roster.slot(pid)
		if s != null:
			s.kind = Roster.SlotKind.AI   # без стека Undo
	side = int(req.get("side", MCF.Owner.PLAYER_1))
	opponent = int(req.get("opponent", AIController.Difficulty.NORMAL))
	round_cap = int(req.get("round_cap", 10))
	max_steps = int(req.get("max_steps", round_cap * 300))
	max_candidates = int(req.get("max_candidates", 0))
	max_actors = int(req.get("max_actors", 0))
	_cap_rng.seed = seed_value
	resolver = GameActionResolver.new(state)
	resolver.fog_mode = int(req.get("fog", MCF.Fog.STANDARD))
	resolver.friendly_fire_enabled = bool(req.get("friendly_fire", true))
	if bool(req.get("random_events", false)):
		resolver.random_events = RandomEvents.new(true)
	resolver.update_airlocks()
	recorder = null
	if bool(req.get("record", false)):
		recorder = ReplayRecorder.new()
		recorder.begin(state, resolver, {"rl": true, "seed": seed_value, "map": path,
				"side": side, "opponent": opponent})
		resolver.replay_recorder = recorder
		recorder.capture_opening()
	else:
		resolver.play_civilian_slots()
	brains.clear()
	if opponent >= 0:
		for pid: int in state.roster.player_ids():
			if pid != side:
				var ai := AIController.new(pid, opponent)
				ai.intent_ready.connect(_on_intent)
				brains[pid] = ai
	var total := 0.0
	for pid: int in state.roster.player_ids():
		total += Obs.army_value(state, pid)
	_norm = maxf(1.0, total / 2.0)
	_last_diff = _value_diff()
	_done = false
	_illegal = 0
	_steps = 0
	_result = ""
	_free_count = {}
	_free_kinds = {}
	_free_turn = ""
	_free_total = 0
	_advance()
	return _response(0.0, true)

func _step(req: Dictionary) -> Dictionary:
	if _done or state == null:
		return {"ok": false, "error": "episode is over — reset first"}
	var k := int(req.get("action", -1))
	if k < 0 or k >= _legal.size():
		return {"ok": false, "error": "action %d out of range (%d legal)" % [k, _legal.size()]}
	var intent: Intent = _legal[k]
	var acting := state.active_player()
	var reward := 0.0
	# ОД актёра ДО действия — по ним и только по ним решается, было ли действие
	# бесплатным. Список «бесплатных видов» хардкодить нельзя: он меняется с правилами,
	# а вот «ОД не убавилось» верно всегда.
	var key := _actor_key(intent)
	var ap_before := _actor_ap(intent)
	var res := resolver.resolve(intent)
	_steps += 1
	if acting == side:
		reward += R_STEP_PENALTY
	if not res.ok:
		# Не должно случаться (перечислитель точен) — но если случилось, шаг не теряется:
		# считаем, штрафуем и, чтобы не зациклиться, отдаём ход после серии отказов.
		_illegal += 1
		if acting == side:
			reward += R_TURN_PENALTY
		if _illegal % 8 == 0:
			resolver.resolve(EndTurnIntent.new())
	elif intent is EndTurnIntent:
		if acting == side:
			reward += R_TURN_PENALTY
	elif key != "" and _actor_ap(intent) >= ap_before:
		# Действие прошло, а ОД не убавилось — оно бесплатное. Считаем его за этим
		# актёром и запоминаем ВИД: после потолка именно этот вид у него и отключится.
		_free_count[key] = int(_free_count.get(key, 0)) + 1
		_free_kinds["%s|%s" % [key, _kind_of(intent)]] = true
		if acting == state.active_player():
			_free_total += 1          # тот же ход продолжается — бюджет стороны тикает
	_advance()
	return _response(reward, false)

## Ключ актёра намерения: id юнита или "v<id>" для машины (пространства id пересекаются).
func _actor_key(intent: Intent) -> String:
	if intent is EndTurnIntent:
		return ""
	if state.get_unit(intent.actor_id) != null:
		return str(intent.actor_id)
	if state.get_vehicle(intent.actor_id) != null:
		return "v%d" % intent.actor_id
	return ""

## Текущие ОД актёра намерения (−1, если актёра нет).
func _actor_ap(intent: Intent) -> int:
	var u := state.get_unit(intent.actor_id)
	if u != null:
		return u.remaining_ap
	var veh := state.get_vehicle(intent.actor_id)
	return resolver.vehicle_ap(veh) if veh != null else -1

func _kind_of(intent: Intent) -> String:
	return str(IntentCodec.encode(intent).get("t", ""))

## Метка текущего хода: сменилась — счётчики бесплатных действий обнуляются.
func _turn_token() -> String:
	return "%d:%d:%d" % [state.active_player(), state.turns.round_number,
			state.turns.active_index]

## Разыграть чужие ходы до следующей точки решения (или конца партии).
func _advance() -> void:
	var guard := 0
	while not _check_over():
		var act := state.active_player()
		if act == side or opponent < 0:
			return
		var ai: AIController = brains.get(act, null)
		if ai == null:
			resolver.resolve(EndTurnIntent.new())
			continue
		_pending = null
		ai.begin_turn(state)
		var intent: Intent = _pending if _pending != null else EndTurnIntent.new()
		var res := resolver.resolve(intent)
		if not res.ok:
			ai.notify_intent_denied(state)
		guard += 1
		if guard > AI_TURN_CAP:
			resolver.resolve(EndTurnIntent.new())
			guard = 0

func _on_intent(intent: Intent) -> void:
	_pending = intent

func _side_has_army(pid: int) -> bool:
	for u in state.all_units():
		if u.owner == pid and u.is_alive() and not u.is_drone:
			return true
	return false

## Исход партии: своя армия мертва — поражение, чужая — победа, обе — ничья,
## лимит раундов — ничья. Пишет _result и возвращает true, когда партия окончена.
func _check_over() -> bool:
	if _done:
		return true
	var mine := _side_has_army(side)
	var theirs := false
	for pid: int in state.roster.player_ids():
		if pid != side and Obs.rel_owner(resolver, side, pid) == 1 and _side_has_army(pid):
			theirs = true
	if not mine and not theirs:
		_result = "draw"
	elif not mine:
		_result = "loss"
	elif not theirs:
		_result = "win"
	elif state.turns.round_number > round_cap:
		_result = "draw_cap"
	elif _steps >= max_steps:
		# Страховка от вечного хода: политика (особенно жадная на оценке) может без конца
		# выбирать бесплатное намерение и никогда не завершить ход — раундовый лимит тогда
		# не наступает. Ничья по шагам; на панели видна как drawrate.
		_result = "draw_steps"
	else:
		return false
	_done = true
	return true

func _value_diff() -> float:
	var mine := Obs.army_value(state, side)
	var theirs := 0.0
	for pid: int in state.roster.player_ids():
		if Obs.rel_owner(resolver, side, pid) == 1:
			theirs += Obs.army_value(state, pid)
	return mine - theirs

func _response(reward: float, is_reset: bool) -> Dictionary:
	var diff := _value_diff()
	reward += (diff - _last_diff) / _norm
	_last_diff = diff
	var resp := {"ok": true, "reward": reward, "done": _done, "acting": state.active_player(),
			"info": {"round": state.turns.round_number, "steps": _steps, "illegal": _illegal,
				"value_diff": diff / _norm}}
	if _done:
		match _result:
			"win": resp["reward"] = float(resp["reward"]) + 1.0
			"loss": resp["reward"] = float(resp["reward"]) - 1.0
			_: resp["reward"] = float(resp["reward"]) + R_DRAW
		resp["info"]["result"] = _result
		_legal = []
		resp["legal"] = []
		resp["obs"] = Obs.encode(resolver, side, round_cap)
		return resp
	var acting := state.active_player()
	var t0 := Time.get_ticks_usec()
	_legal = _cap_legal(_drop_looping(resolver.legal_intents(acting, _actor_subset(acting))))
	var t1 := Time.get_ticks_usec()
	var desc: Array = []
	for intent: Intent in _legal:
		desc.append(Obs.describe(state, intent))
	resp["legal"] = desc
	resp["obs"] = Obs.encode(resolver, acting, round_cap)
	# Во что обошёлся ЭТОТ ответ. Перечислитель — самая дорогая часть шага на больших
	# картах (town без max_actors: ~180 мс из ~190), и когда обучение «висит», первым
	# делом хочется видеть именно это число, а не гадать. Тренер пишет его в TB.
	resp["info"]["legal_ms"] = (t1 - t0) / 1000.0
	resp["info"]["obs_ms"] = (Time.get_ticks_usec() - t1) / 1000.0
	return resp

## Убрать намерения, которыми юнит уже зациклился в этом ходу.
##
## Первый прогон town'а: 75% действий политики — move_held (бесплатная перекладка
## пленника), end — 0.4%, две доигранные партии за 13 апдейтов. Конец хода стоит
## R_TURN_PENALTY, бесплатное действие — ноль, так что «перекладывать вечно» строго
## выгоднее; PPO нашёл это за десяток апдейтов. R_STEP_PENALTY убирает выгоду, а этот
## фильтр убирает саму возможность.
##
## Режется ТОЧЕЧНО: только те виды, которые ЭТОТ юнит уже сделал бесплатно
## FREE_ACTIONS_PER_UNIT раз за этот ход. Платные действия, первые N бесплатных и
## чужие юниты не трогаются — перекладка пленника остаётся законным ходом, перестаёт
## быть бесконечной.
func _drop_looping(list: Array) -> Array:
	var token := _turn_token()
	if token != _free_turn:
		_free_turn = token
		_free_count = {}
		_free_kinds = {}
		_free_total = 0
		return list
	if _free_count.is_empty():
		return list
	# Сначала — КТО упёрся в потолок (бюджет стороны исчерпан — значит все, кто вообще
	# ходил бесплатно). Это дёшево: словарь размером с число отметившихся актёров.
	var side_done := _free_total >= FREE_ACTIONS_PER_TURN
	var blocked := {}
	for key: Variant in _free_count:
		if side_done or int(_free_count[key]) >= FREE_ACTIONS_PER_UNIT:
			blocked[key] = true
	if blocked.is_empty():
		return list
	# И только теперь фильтр. Порядок важен: _kind_of() зовёт IntentCodec.encode(), а он
	# строит словарь на КАЖДОЕ намерение. Прогон по всему списку стоил 230 мс на шаг
	# (276 против 45 до фильтра) — шестикратное замедление среды. Здесь он достаётся
	# только намерениям упёршихся актёров, которых обычно единицы.
	var out: Array = []
	for intent: Intent in list:
		var key := _actor_key(intent)
		if key != "" and blocked.has(key) \
				and _free_kinds.has("%s|%s" % [key, _kind_of(intent)]):
			continue
		out.append(intent)
	return out

## Подмножество актёров, которых перечислитель рассматривает на ЭТОМ шаге (пусто = все).
##
## Перебор всех 176 бойцов стоит ~180 мс за точку решения; за ход таких точек сотни.
## Поэтому за шаг рассматриваются max_actors случайных актёров — выбор каждый раз новый,
## так что за ход очередь доходит до всех. Сначала берутся те, у кого ОСТАЛИСЬ ОД:
## иначе подмножество из выдохшихся юнитов не предлагало бы ничего, кроме конца хода,
## и сторона теряла бы ход с полными ОД на руках.
func _actor_subset(acting: int) -> Dictionary:
	if max_actors <= 0:
		return {}
	var ready: Array = []
	var spent: Array = []
	for u: UnitInstance in state.all_units():
		if u.owner != acting or not u.is_alive():
			continue
		(ready if u.remaining_ap > 0 else spent).append(u.id)
	for veh: Vehicle in state.all_vehicles():
		if veh.owner != acting or not veh.alive() or veh.is_borg():
			continue
		(ready if resolver.vehicle_ap(veh) > 0 else spent).append("v%d" % veh.id)
	if ready.size() + spent.size() <= max_actors:
		return {}
	_shuffle(ready)
	_shuffle(spent)
	var out := {}
	for key: Variant in ready + spent:
		if out.size() >= max_actors:
			break
		out[key] = true
	return out

## Урезать список кандидатов до max_candidates, НЕ обедняя выбор.
##
## Равномерная выборка здесь была бы ловушкой: на town'е 59% списка — «шагнуть», и
## случайные 768 из 8366 почти наверняка не содержали бы ни одного выстрела. Поэтому
## корзины (актёр, вид намерения) обходятся по кругу: каждый юнит получает по одному
## варианту КАЖДОГО своего вида, прежде чем кто-то получит второй. Редкие виды
## (выстрел, постройка, посадка) выживают целиком, режется только избыток ходов.
##
## Порядок берётся из _cap_rng (сид эпизода), так что эпизод воспроизводим, а EndTurn
## остаётся в списке всегда — иначе ход некому было бы закончить.
func _cap_legal(list: Array) -> Array:
	if max_candidates <= 0 or list.size() <= max_candidates:
		return list
	var buckets := {}
	var order: Array = []
	var kept: Array = []
	for intent: Intent in list:
		if intent is EndTurnIntent:
			kept.append(intent)
			continue
		var key := "%d:%s" % [intent.actor_id, str(IntentCodec.encode(intent).get("t", ""))]
		if not buckets.has(key):
			buckets[key] = []
			order.append(key)
		buckets[key].append(intent)
	_shuffle(order)
	for key: String in order:
		_shuffle(buckets[key])
	var round_index := 0
	while kept.size() < max_candidates:
		var took := false
		for key: String in order:
			var b: Array = buckets[key]
			if round_index >= b.size():
				continue
			kept.append(b[round_index])
			took = true
			if kept.size() >= max_candidates:
				break
		if not took:
			break          # все корзины исчерпаны раньше потолка
		round_index += 1
	return kept


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _cap_rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


func _save_replay(path: String) -> Dictionary:
	if recorder == null or path == "":
		return {"ok": false, "error": "not recording"}
	var d := recorder.to_dict()
	d["meta"]["result"] = _result
	d["meta"]["steps_rl"] = _steps
	return {"ok": ReplayFile.write(path, d)}
