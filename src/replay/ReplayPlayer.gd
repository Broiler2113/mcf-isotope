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
## ReplayCheckpoint.ACTION_INTERVAL).

var data: Dictionary = {}
var state: GameState = null
var resolver: GameActionResolver = null
## Сколько шагов уже применено к текущей доске (0 = самое начало матча).
var index: int = 0
## Итог открывающего слота мирных на текущей позиции — UI отыгрывает его анимацией.
var opening_result: ActionResult = null
## Косметика (кровь, гильзы, разрушенный пол), накопленная во время последней перемотки
## (item 9): seek() собирает её из фаст-форварда, а UI применяет к своему слою, чтобы
## после прыжка по таймлайну следы боя не пропадали.
var seek_fx: Array = []
var seek_decals: Dictionary = {}
var _undo_turns: Array[Vector2i] = []
var last_seek_actions := 0
var advance_random := false
var restored_checkpoint: Dictionary = {}
var seek_error := ""

func _init(p_data: Dictionary) -> void:
	data = p_data
	var start := 0
	var has_undo := false
	var list := steps()
	for i in list.size():
		var kind := str(list[i].get("i", {}).get("t", ""))
		has_undo = has_undo or kind in [IntentCodec.T_UNDO, IntentCodec.T_REDO]
		if kind == IntentCodec.T_END or i == list.size() - 1:
			if has_undo:
				_undo_turns.append(Vector2i(start, i + 1))
			start = i + 1
			has_undo = false

func _needs_undo(at: int) -> bool:
	for span: Vector2i in _undo_turns:
		if at >= span.x and at < span.y:
			return true
	return false

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
	# Косметику пересобираем ВСЕГДА с ближайшего ключевого кадра до цели (item 9), чтобы
	# после прыжка по таймлайну кровь/гильзы/разрушенный пол были на месте, а не исчезали.
	seek_fx = []
	seek_error = ""
	last_seek_actions = 0
	var frame := _frame_at_or_before(want)
	_rebuild(frame)
	if advance_random and (state.dice.fallback_rolls > 0 or state.dice.scripted_remaining() > 0): seek_error = "Recorded opening dice did not match."
	if opening_result != null:
		seek_fx.append_array(opening_result.fx)
	while index < want:
		var r := play_next()
		last_seek_actions += 1
		if advance_random and (r == null or not r.ok or state.dice.fallback_rolls > 0 or state.dice.scripted_remaining() > 0): seek_error = "Recorded action %d could not be reconstructed safely." % index
		if r != null:
			seek_fx.append_array(r.fx)

## Применить следующее записанное действие. null — запись кончилась.
func play_next() -> ActionResult:
	restored_checkpoint = {}
	if state == null:
		seek(0)
	if not has_next():
		return null
	var step: Dictionary = steps()[index]
	if step.get("i", {}).get("t", "") == "checkpoint":
		var frame := ReplayCheckpoint.unpack(step.get("k", {}))
		index += 1
		if frame.is_empty(): return ActionResult.fail("Unreadable resumed-match checkpoint")
		restored_checkpoint = frame
		seek_decals = frame.get("fx", {})
		seek_fx.clear()
		StateCodec.restore_into(state, frame.get("state", {}))
		StateCodec.apply_rules(resolver, frame.get("rules", {}))
		_restore_cannon_rules(frame)
		resolver.explored = frame.get("visibility", {}).duplicate(true)
		resolver._undo_stack.clear()
		resolver._redo_stack.clear()
		UnitInstance.vision_epoch += 1
		return ActionResult.success()
	resolver.track_undo_history = _needs_undo(index)
	var intent := IntentCodec.decode(step.get("i", {}))
	index += 1
	if intent == null:
		return ActionResult.fail("Unreadable action in replay")
	# Броски подставляются ровно так же, как их подставляет сетевой клиент: свой
	# генератор при этом не трогается, поэтому доска повторяется бит в бит.
	var rolls: Array = step.get("r", [])
	state.dice.feed_scripted(rolls)
	var result := resolver.resolve(intent)
	if advance_random and not (intent is UndoIntent or intent is RedoIntent): state.dice.advance_recorded(rolls.size())
	return result

## Пересобрать доску по кадру. opening_result заполняется только на стартовом кадре:
## поздние кадры сняты уже ПОСЛЕ открывающего слота мирных.
func _rebuild(frame: Dictionary) -> void:
	state = StateCodec.decode(frame.get("state", {}))
	if state == null:
		state = GameState.new(16, 12)
	resolver = GameActionResolver.new(state)
	resolver.legacy_corpse_rules = int(data.get("corpse_rules", 0)) < 1
	resolver.track_undo_history = _needs_undo(int(frame.get("at", 0)))
	seek_decals = frame.get("fx", {})
	StateCodec.apply_rules(resolver, frame.get("rules", {}))
	_restore_cannon_rules(frame)
	resolver.explored = frame.get("visibility", {}).duplicate(true)
	# Preserve historical point-budget waves only when playing an older recording.
	var saved_mode: Dictionary = frame.get("rules", {}).get("mode", {})
	resolver.mode.live_wave_counts = bool(saved_mode.get("live_wave_counts", false))
	var selection := str(data.get("event_selection", "weighted"))
	resolver.random_events.legacy_selection = selection not in ["uniform", "uniform2"]
	resolver.random_events.empty_pool_rolls = selection == "uniform"
	resolver.update_airlocks()
	index = int(frame.get("at", 0))
	opening_result = null
	var open: Array = frame.get("open", [])
	if bool(frame.get("opening_processed", false)) or not open.is_empty():
		state.dice.feed_scripted(open)
		opening_result = resolver.open_match() if bool(frame.get("opening_processed", false)) \
				else resolver.play_civilian_slots()
		if advance_random: state.dice.advance_recorded(open.size())

## Old prefixes retain their original shots; a resumed live checkpoint switches to
## current rules. This applies both to linear playback and seeking into that branch.
func _restore_cannon_rules(frame: Dictionary) -> void:
	resolver.legacy_rear_cannon = int(frame.get("rules", {}).get("cannon_arc",
			data.get("rules", {}).get("cannon_arc", 0))) < 1

## Ключевой кадр, не позже шага i. Кадр, привязанный к шагу s, снят ПОСЛЕ него,
## то есть описывает позицию s+1.
func _frame_at_or_before(i: int) -> Dictionary:
	var list := steps()
	# The nearest frame is the last one at or before the target. Search back from
	# there: a late seek visits only the gap since that frame, rather than every
	# earlier action. No index/cache is needed, so legacy and edited data still work.
	var s := mini(i, list.size()) - 1
	while s >= 0:
		var step: Dictionary = list[s]
		if step.has("k") and not (_needs_undo(s) and bool(step["k"].get("mid_turn", false))):
			var kf := ReplayCheckpoint.unpack(step["k"])
			if not kf.is_empty():
				var found := {"at": s + 1, "state": kf.get("state", {}),
						"rules": kf.get("rules", {}), "open": []}
				if kf.has("fx"):
					found["fx"] = kf.fx
				if kf.has("visibility"): found["visibility"] = kf.visibility
				return found
		s -= 1
	var first := {"at": 0, "state": data.get("start", {}),
			"rules": data.get("rules", {}), "open": data.get("opening", [])}
	if bool(data.get("opening_processed", false)):
		first["opening_processed"] = true
	return first

## Подпись текущей позиции для полосы управления.
func position_text() -> String:
	var total := step_count()
	var round_no := state.turns.round_number if state != null else 1
	return "action %d / %d · round %d" % [index, total, round_no]

## Кем в этой записи играла обучаемая политика — или "", если запись не из обучения.
##
## Без этого повтор обучения смотреть почти бесполезно: две одинаковые армии ходят по
## очереди, и понять, чьи ходы разбирать, неоткуда. Сторона лежит в meta с самой записи
## (rl/env_server.gd кладёт туда side и opponent при begin()), просто её никто не
## показывал.
func rl_side_text() -> String:
	var meta: Dictionary = data.get("meta", {})
	if not bool(meta.get("rl", false)):
		return ""
	var side := int(meta.get("side", -1))
	if not MCF.is_player(side):
		return ""
	var opp := str(meta.get("opponent", ""))
	var against := " vs %s AI" % opp.to_upper() if opp != "" else ""
	return "RLM plays %s%s" % [MCF.owner_name(side), against]
