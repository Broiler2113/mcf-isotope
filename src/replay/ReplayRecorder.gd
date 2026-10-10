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

const SCHEMA := 2

var meta: Dictionary = {}
## Кадр доски ДО открывающего слота мирных и броски самого этого слота: он играется
## вне потока намерений (резолвер ведёт его сам), но кубики бросает — значит без него
## повтор пошёл бы по другой доске уже с первого хода.
var start: Dictionary = {}
var start_rules: Dictionary = {}
var opening: Array = []
var opening_processed: bool = false
var steps: Array = []
var bookmarks: Array = []
var _bookmark_round := -1
var _bookmark_owner := -1
var _checkpoint_at := 0
var _fx: FxDecals

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
	_state = state
	_resolver = resolver
	meta = p_meta.duplicate(true)
	start = StateCodec.encode(state)
	start_rules = StateCodec.encode_rules(resolver)
	steps.clear()
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
	ReplayBookmarks.append(bookmarks, index, _state.turns.round_number, _state.active_player(),
			_bookmark_round, _bookmark_owner, result.log_lines if result != null else [])
	_bookmark_round = _state.turns.round_number
	_bookmark_owner = _state.active_player()
	ReplayCheckpoint.apply_effects(_fx, result)

func on_resolved(intent: Intent, rolls: Array, result: ActionResult = null) -> void:
	var wire := IntentCodec.encode(intent)
	if wire.is_empty():
		return
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
	if _state != null and (intent is EndTurnIntent or at - _checkpoint_at >= ReplayCheckpoint.ACTION_INTERVAL):
		step["k"] = ReplayCheckpoint.pack(_state, _resolver, _fx, not intent is EndTurnIntent)
		_checkpoint_at = at
	steps.append(step)

func is_empty() -> bool:
	return steps.is_empty()

func to_dict() -> Dictionary:
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
		"steps": steps,
	}

## Записать повтор на диск. Возвращает путь или "" при неудаче.
func save(label: String) -> String:
	if is_empty():
		return ""
	var path := ReplayFile.path_for(ReplayFile.REPLAY_DIR,
			ReplayFile.stamped(label, ReplayFile.REPLAY_EXT))
	return path if ReplayFile.write(path, to_dict()) else ""
