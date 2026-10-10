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
## Ключевые кадры (каждые KEYFRAME_ROUNDS раундов) нужны просмотрщику: перемотка
## НАЗАД — это восстановление ближайшего кадра и быстрый прогон вперёд. Без них
## шаг назад на третьем часу боя переигрывал бы партию с начала.
##
## Network matches share the host dice log through NetGame.on_resolved;
## offline matches use the resolver hook. Only one component starts the dice log.

const SCHEMA := 1
const KEYFRAME_ROUNDS := 5

var meta: Dictionary = {}
## Кадр доски ДО открывающего слота мирных и броски самого этого слота: он играется
## вне потока намерений (резолвер ведёт его сам), но кубики бросает — значит без него
## повтор пошёл бы по другой доске уже с первого хода.
var start: Dictionary = {}
var start_rules: Dictionary = {}
var opening: Array = []
var opening_processed: bool = false
var steps: Array = []

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
var _next_keyframe_round: int = 1 + KEYFRAME_ROUNDS

## Начать запись. Вызывается сразу после сборки состояния, ДО первого действия.
func begin(state: GameState, resolver: GameActionResolver, p_meta: Dictionary = {}) -> void:
	_state = state
	_resolver = resolver
	meta = p_meta.duplicate(true)
	start = StateCodec.encode(state)
	start_rules = StateCodec.encode_rules(resolver)
	steps.clear()
	opening.clear()
	opening_processed = false
	_next_keyframe_round = state.turns.round_number + KEYFRAME_ROUNDS

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
	_state.dice.record_enabled = false
	_resolver.replay_recorder = self
	return res

## Действие применено (зовётся из GameActionResolver.resolve). rolls — броски именно
## этого действия, в том порядке, в каком их взяли.
func on_resolved(intent: Intent, rolls: Array) -> void:
	var wire := IntentCodec.encode(intent)
	if wire.is_empty():
		return   # намерения без кодека в повтор не попадают — молча испортить хуже
	var step := {"i": wire, "r": rolls.duplicate()}
	if _state != null and _state.turns.round_number >= _next_keyframe_round:
		_next_keyframe_round = _state.turns.round_number + KEYFRAME_ROUNDS
		step["k"] = {"state": StateCodec.encode(_state),
				"rules": StateCodec.encode_rules(_resolver)}
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
		"steps": steps,
	}

## Записать повтор на диск. Возвращает путь или "" при неудаче.
func save(label: String) -> String:
	if is_empty():
		return ""
	var path := ReplayFile.path_for(ReplayFile.REPLAY_DIR,
			ReplayFile.stamped(label, ReplayFile.REPLAY_EXT))
	return path if ReplayFile.write(path, to_dict()) else ""
