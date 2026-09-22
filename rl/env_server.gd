extends SceneTree

## Сервер среды для обучения (RL v1, spec §1 C1, §5.1, §9.1). Один процесс — один слот
## векторизованной среды: тренер на Python говорит с ним JSON-строками через stdin/stdout.
##
##   → {"cmd":"reset", "map":"/abs/path.json", "seed":N, "side":0|1, "opponent":0|1|2|-1,
##      "round_cap":10, "max_steps":3000, "civilians":false, "random_events":false, "fog":1,
##      "friendly_fire":true, "record":true}
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

var state: GameState = null
var resolver: GameActionResolver = null
var side: int = MCF.Owner.PLAYER_1
var opponent: int = AIController.Difficulty.NORMAL
var round_cap: int = 10
## Потолок шагов эпизода (обеих сторон); задаётся в reset как "max_steps", иначе 300 на раунд.
var max_steps: int = 3000
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
	var res := resolver.resolve(intent)
	_steps += 1
	if not res.ok:
		# Не должно случаться (перечислитель точен) — но если случилось, шаг не теряется:
		# считаем, штрафуем и, чтобы не зациклиться, отдаём ход после серии отказов.
		_illegal += 1
		if acting == side:
			reward += R_TURN_PENALTY
		if _illegal % 8 == 0:
			resolver.resolve(EndTurnIntent.new())
	elif intent is EndTurnIntent and acting == side:
		reward += R_TURN_PENALTY
	_advance()
	return _response(reward, false)

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
	_legal = resolver.legal_intents(acting)
	var desc: Array = []
	for intent: Intent in _legal:
		desc.append(Obs.describe(state, intent))
	resp["legal"] = desc
	resp["obs"] = Obs.encode(resolver, acting, round_cap)
	return resp

func _save_replay(path: String) -> Dictionary:
	if recorder == null or path == "":
		return {"ok": false, "error": "not recording"}
	var d := recorder.to_dict()
	d["meta"]["result"] = _result
	d["meta"]["steps_rl"] = _steps
	return {"ok": ReplayFile.write(path, d)}
