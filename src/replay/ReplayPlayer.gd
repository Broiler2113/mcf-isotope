class_name ReplayPlayer
extends RefCounted

## Проигрыватель записи матча (item 53). Держит СВОИ состояние и резолвер и гоняет
## через них записанные намерения — тем же кодом, каким шла живая партия. Ничего
## «специально для повтора» в правилах нет и быть не должно: любое отличие сделало бы
## повтор другой игрой.
##
## Перемотка вперёд — просто следующее намерение. Перемотка НАЗАД устроена иначе:
## резолвер необратим, поэтому доска пересобирается из ближайшего ключевого кадра и
## быстро догоняется вперёд. Отсюда и требование к записи держать кадры (см.
## ReplayRecorder.KEYFRAME_ROUNDS).

var data: Dictionary = {}
var state: GameState = null
var resolver: GameActionResolver = null
## Сколько шагов уже применено к текущей доске (0 = самое начало матча).
var index: int = 0
## Итог открывающего слота мирных на текущей позиции — UI отыгрывает его анимацией.
var opening_result: ActionResult = null

func _init(p_data: Dictionary) -> void:
	data = p_data

func steps() -> Array:
	return data.get("steps", [])

func step_count() -> int:
	return steps().size()

func has_next() -> bool:
	return index < step_count()

func at_start() -> bool:
	return index <= 0

## Собрать доску на нужный шаг: ближайший кадр не позже него плюс прогон вперёд.
## Дороже всего это стоит на шаге назад, и ровно на столько, сколько действий прошло
## с последнего кадра.
func seek(target: int) -> void:
	var want := clampi(target, 0, step_count())
	# Идти вперёд от того, что уже собрано, дешевле, чем пересобирать с кадра.
	if state != null and index <= want:
		while index < want:
			play_next()
		return
	var frame := _frame_at_or_before(want)
	_rebuild(frame)
	while index < want:
		play_next()

## Применить следующее записанное действие. null — запись кончилась.
func play_next() -> ActionResult:
	if state == null:
		seek(0)
	if not has_next():
		return null
	var step: Dictionary = steps()[index]
	var intent := IntentCodec.decode(step.get("i", {}))
	index += 1
	if intent == null:
		return ActionResult.fail("Unreadable action in replay")
	# Броски подставляются ровно так же, как их подставляет сетевой клиент: свой
	# генератор при этом не трогается, поэтому доска повторяется бит в бит.
	state.dice.feed_scripted(step.get("r", []))
	return resolver.resolve(intent)

## Пересобрать доску по кадру. opening_result заполняется только на стартовом кадре:
## поздние кадры сняты уже ПОСЛЕ открывающего слота мирных.
func _rebuild(frame: Dictionary) -> void:
	state = StateCodec.decode(frame.get("state", {}))
	if state == null:
		state = GameState.new(16, 12)
	resolver = GameActionResolver.new(state)
	StateCodec.apply_rules(resolver, frame.get("rules", {}))
	resolver.update_airlocks()
	index = int(frame.get("at", 0))
	opening_result = null
	var open: Array = frame.get("open", [])
	if not open.is_empty():
		state.dice.feed_scripted(open)
		opening_result = resolver.play_civilian_slots()

## Ключевой кадр, не позже шага i. Кадр, привязанный к шагу s, снят ПОСЛЕ него,
## то есть описывает позицию s+1.
func _frame_at_or_before(i: int) -> Dictionary:
	var best := {"at": 0, "state": data.get("start", {}),
			"rules": data.get("rules", {}), "open": data.get("opening", [])}
	var list := steps()
	for s in list.size():
		if s + 1 > i:
			break
		var step: Dictionary = list[s]
		if step.has("k"):
			var kf: Dictionary = step["k"]
			best = {"at": s + 1, "state": kf.get("state", {}),
					"rules": kf.get("rules", {}), "open": []}
	return best

## Подпись текущей позиции для полосы управления.
func position_text() -> String:
	var total := step_count()
	var round_no := state.turns.round_number if state != null else 1
	return "action %d / %d · round %d" % [index, total, round_no]
