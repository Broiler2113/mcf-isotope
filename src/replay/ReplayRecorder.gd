class_name ReplayRecorder
extends RefCounted

## Запись матча (item 53). Пишется ровно то, чего достаточно, чтобы сыграть партию
## заново: стартовый кадр доски, правила боя и дальше — поток НАМЕРЕНИЙ, у каждого
## свои броски кубиков.
##
## Почему этого хватает. Состояние в игре меняет одна-единственная функция —
## GameActionResolver.resolve(), — а весь разброс идёт через DiceService. Значит
## «намерение + его броски» полностью описывает переход доски из одного состояния в
## другое: тот же приём, каким живёт сетевая партия (NetGame), только вторая сторона
## провода — файл. Поэтому запись и стоит ровно один хук в resolve().
##
## Compact checkpoints every 48 actions and every handoff bound normal seek work.
## Bookmarks and permanent visual effects are collected alongside the intent stream.
##
## Network matches share the host dice log through NetGame.on_resolved;
## offline matches use the resolver hook. Only one component starts the dice log.

const SCHEMA := 3

var meta: Dictionary = {}
## Кадр доски ДО открывающего слота мирных и броски самого этого слота: он играется
## вне потока намерений (резолвер ведёт его сам), но кубики бросает — значит без него
## повтор пошёл бы по другой доске уже с первого хода.
var start: Dictionary = {}
var start_rules: Dictionary = {}
var opening: Array = []
var opening_processed: bool = false
var steps: Array = []
var revision := 0
# Recent combat text travels with the replay for reports submitted from the menu.
const MAX_COMBAT_LOG := 600_000
var combat_log: Array[String] = []
var _combat_chars := 0
var bookmarks: Array = []
var _bookmark_round := -1
var _bookmark_owner := -1
var _checkpoint_at := 0
var _fx: FxDecals
## Checkpoints being sealed on a worker thread: [task id, step, [result]]. Half of a giant
## board's ~30 ms checkpoint is bytes and compression; the battle goes on meanwhile.
var _sealing: Array = []

var _state: GameState = null
## The resolver owns its recording hook. Keep the return link weak, otherwise
## resolver -> recorder -> resolver retains the entire board after a match/episode.
## The battle screen or env server owns the live resolver throughout recording.
var _resolver_ref: WeakRef = null
var _resolver: GameActionResolver:
	get:
		return _resolver_ref.get_ref() if _resolver_ref != null else null
	set(value):
		_resolver_ref = weakref(value) if value != null else null

## Начать запись. Вызывается сразу после сборки состояния, ДО первого действия.
func begin(state: GameState, resolver: GameActionResolver, p_meta: Dictionary = {}) -> void:
	_collect_sealed(true)
	revision += 1
	_state = state
	_resolver = resolver
	meta = p_meta.duplicate(true)
	start = StateCodec.encode(state)
	start_rules = StateCodec.encode_rules(resolver)
	steps.clear()
	combat_log.clear()
	_combat_chars = 0
	bookmarks.clear()
	_bookmark_round = -1
	_bookmark_owner = -1
	_checkpoint_at = 0
	_fx = ReplayCheckpoint.effects(state)
	opening.clear()
	opening_processed = false

## Отыграть открывающий слот мирных под запись бросков. Резолвер на это время
## ОТЦЕПЛЯЕТСЯ от записи: play_civilian_slots() зовут снаружи, поэтому каждое
## намерение жителя пришло бы в on_resolved как самостоятельное действие партии —
## а оно часть одного открывающего слота, и повтор обязан видеть его целиком.
func capture_opening() -> ActionResult:
	if _resolver == null:
		return ActionResult.success()
	_resolver.replay_recorder = null
	_state.dice.begin_record()
	var res := _resolver.open_match()
	opening = _state.dice.take_log()
	opening_processed = true
	observe_opening(res)
	_state.dice.record_enabled = false
	_resolver.replay_recorder = self
	return res

## Действие применено (зовётся из GameActionResolver.resolve). rolls — броски именно
## этого действия, в том порядке, в каком их взяли.
func observe_opening(result: ActionResult) -> void:
	_observe(0, result)

func _observe(index: int, result: ActionResult) -> void:
	if result != null:
		for line: String in result.log_lines:
			combat_log.append(line)
			_combat_chars += line.length() + 1
		while _combat_chars > MAX_COMBAT_LOG and not combat_log.is_empty():
			_combat_chars -= combat_log.pop_front().length() + 1
	ReplayBookmarks.append(bookmarks, index, _state.turns.round_number, _state.active_player(),
			_bookmark_round, _bookmark_owner, result.log_lines if result != null else [])
	_bookmark_round = _state.turns.round_number
	_bookmark_owner = _state.active_player()
	ReplayCheckpoint.apply_effects(_fx, result)

func on_resolved(intent: Intent, rolls: Array, result: ActionResult = null) -> void:
	var wire := IntentCodec.encode(intent)
	if wire.is_empty():
		return
	revision += 1
	if bookmarks.is_empty():
		# Recorders attached mid-match need a starting location, too.
		var turn: Dictionary = start.get("turns", {})
		var order: Array = turn.get("order", [0, 1])
		_bookmark_round = int(turn.get("round", 1))
		_bookmark_owner = int(order[int(turn.get("index", 0))])
		ReplayBookmarks.append(bookmarks, 0, _bookmark_round, _bookmark_owner, -1, -1, [])
	var at := steps.size() + 1
	var step := {"i": wire, "r": rolls.duplicate()}
	_observe(at, result)
	if _state != null and ReplayCheckpoint.due(_state, at - _checkpoint_at, intent is EndTurnIntent):
		var data := ReplayCheckpoint.payload(_state, _resolver, _fx)
		var mid_turn := not intent is EndTurnIntent
		var box := [null]
		_sealing.append([WorkerThreadPool.add_task(ReplayCheckpoint.seal_into.bind(box, data, mid_turn),
				false, "replay checkpoint"), step, box])
		_checkpoint_at = at
	steps.append(step)
	_collect_sealed(false)

## Every pool task is waited for. (A RefCounted cannot call its own methods while deleted.)
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for job: Array in _sealing: WorkerThreadPool.wait_for_task_completion(job[0])

## Put sealed checkpoints into their steps, in order; wait — also those still being sealed.
## A step whose checkpoint is not in yet is just a step: seeking starts from an earlier one.
func _collect_sealed(wait: bool) -> void:
	while not _sealing.is_empty():
		var job: Array = _sealing[0]
		if not wait and not WorkerThreadPool.is_task_completed(job[0]):
			return
		WorkerThreadPool.wait_for_task_completion(job[0])
		(job[1] as Dictionary)["k"] = job[2][0]
		_sealing.pop_front()

## Keep the canonical replay prefix after host history navigation. The forward branch
## lives in MatchHistory until the next live action replaces it.
func adopt_prefix(data: Dictionary, count: int, state: GameState, resolver: GameActionResolver, effects: Dictionary) -> void:
	_collect_sealed(true)
	_state = state
	_resolver = resolver
	meta = data.get("meta", {}).duplicate(true)
	start = data.get("start", {}).duplicate(true)
	start_rules = data.get("rules", {}).duplicate(true)
	opening.assign(data.get("opening", []))
	opening_processed = bool(data.get("opening_processed", false))
	steps = data.get("steps", []).slice(0, count)
	bookmarks = data.get("bookmarks", []).filter(func(mark: Dictionary) -> bool: return int(mark.get("index", 0)) <= count)
	combat_log.assign(str(data.get("combat_log", "")).split("\n", false))
	_combat_chars = str(data.get("combat_log", "")).length()
	_checkpoint_at = 0
	for i in steps.size():
		if steps[i].has("k"): _checkpoint_at = i + 1
	_bookmark_round = state.turns.round_number
	_bookmark_owner = state.active_player()
	_fx = ReplayCheckpoint.effects(state)
	_fx.from_dict(effects)
	revision += 1

## Resuming a saved match may change lobby rules. Keep that transition explicit so
## sequential playback and seeking apply the same resumed state.
func resume_checkpoint(fx: FxDecals) -> void:
	steps.append({"i": {"t": "checkpoint"}, "r": [], "k": ReplayCheckpoint.pack(_state, _resolver, fx, false)})
	_checkpoint_at = steps.size()
	revision += 1

func is_empty() -> bool:
	return steps.is_empty()

func to_dict() -> Dictionary:
	_collect_sealed(true)
	var out_meta := meta.duplicate(true)
	out_meta["steps"] = steps.size()
	if _state != null:
		out_meta["round"] = _state.turns.round_number
	return {
		"schema": SCHEMA,
		"kind": ReplayFile.KIND_REPLAY,
		"meta": out_meta,
		"start": start,
		"rules": start_rules,
		"opening": opening,
		"opening_processed": opening_processed,
		"bookmarks": bookmarks,
		"seek_version": 1,
		"event_selection": "uniform2",
		"corpse_rules": 1,
		"steps": steps,
		"combat_log": "\n".join(combat_log),
	}

## Записать повтор на диск. Возвращает путь или "" при неудаче.
func save(label: String) -> String:
	if is_empty():
		return ""
	var path := ReplayFile.path_for(ReplayFile.REPLAY_DIR,
			ReplayFile.stamped(label, ReplayFile.REPLAY_EXT))
	return path if ReplayFile.write(path, to_dict()) else ""
