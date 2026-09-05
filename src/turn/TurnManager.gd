class_name TurnManager
extends RefCounted

## Инициатива и учёт раундов (§3.3, порядок — по образцу isotope, #53).
##
## Порядок инициативы бросается РОВНО ОДИН раз, в начале партии, и дальше не
## меняется до самого конца боя. Игрок 1 всегда идёт раньше игрока 2, а слот
## мирных жителей — только если мирные на карте вообще есть — вставляется на одну
## из трёх случайных позиций: P1→P2→CIV / P1→CIV→P2 / CIV→P1→P2.
##
## В самом бою порядок не пересчитывается: слот просто ПРОПУСКАЕТСЯ, пока у его
## стороны нет ни одного живого юнита (сторона выбита или мирные кончились).
##
## Внутри своего хода игрок активирует любое число своих юнитов в любом порядке и
## передаёт ход в любой момент. ОД восстанавливаются у всех живых юнитов на
## границе раунда.

signal active_player_changed(owner: int)
signal round_started(round_number: int)

## Фиксированный на всю партию порядок инициативы (см. begin_match).
## До броска — просто два игрока, чтобы состояние было валидным ещё до расстановки.
var round_order: Array[int] = [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]
## Позиция в round_order (историческое имя — индекс активного слота).
var active_index: int = 0
var round_number: int = 1
## Бросок инициативы одноразовый: повторный begin_match ничего не меняет.
var initiative_rolled: bool = false

func active_player() -> int:
	return round_order[active_index]

## Бросок инициативы на всю партию — вызывается ОДИН раз, уже после расстановки
## юнитов (иначе не видно, есть ли на карте мирные). Бросок идёт через DiceService,
## поэтому при заданном зерне порядок воспроизводим и одинаков у хоста и клиента.
func begin_match(all_units: Array, dice: DiceService) -> void:
	if initiative_rolled:
		return
	initiative_rolled = true
	round_order = [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]
	if _has_living(all_units, MCF.Owner.NEUTRAL):
		# d6 % 3 даёт равновероятные 0/1/2 — позиция слота мирных в порядке.
		var slot := (dice.roll_d6() if dice != null else 1) % 3
		round_order.insert(slot, MCF.Owner.NEUTRAL)
	active_index = _open_round(all_units)
	active_player_changed.emit(active_player())

## Человекочитаемый порядок инициативы — для HUD и журнала боя.
func order_names() -> String:
	var parts: Array[String] = []
	for side in round_order:
		parts.append(MCF.owner_name(side))
	return " → ".join(parts)

## Передать ход следующему ИГРАЮЩЕМУ слоту (пустые слоты пропускаются).
## Возвращает true, если круг замкнулся и начался НОВЫЙ раунд — тогда же
## восстанавливаются ОД.
func end_turn(all_units: Array) -> bool:
	var nxt := _next_playable_from(active_index + 1, all_units)
	if nxt < round_order.size():
		active_index = nxt
		active_player_changed.emit(active_player())
		return false
	# Круг замкнулся — новый раунд на ТОМ ЖЕ порядке (перебросов нет, §isotope).
	var first := _next_playable_from(0, all_units)
	if first >= round_order.size():
		# Живых не осталось вовсе — бой окончен, слот не двигаем.
		return false
	active_index = first
	round_number += 1
	_reset_all_ap(all_units)
	round_started.emit(round_number)
	active_player_changed.emit(active_player())
	return true

## Первый играющий слот нового круга. Если играть некому — оставляем текущий,
## чтобы active_player() никогда не вышел за границы массива.
func _open_round(all_units: Array) -> int:
	var i := _next_playable_from(0, all_units)
	return i if i < round_order.size() else active_index

## Индекс первого играющего слота на позиции >= start (size(), если таких нет).
func _next_playable_from(start: int, all_units: Array) -> int:
	var i := maxi(start, 0)
	while i < round_order.size() and not _has_living(all_units, round_order[i]):
		i += 1
	return i

## Есть ли у стороны хоть один живой юнит — по этому и пропускается слот.
func _has_living(all_units: Array, side: int) -> bool:
	for u in all_units:
		if u.owner == side and u.is_alive():
			return true
	return false

func _reset_all_ap(all_units: Array) -> void:
	# ОД восстанавливаются и у удерживаемых юнитов — чтобы они могли пытаться
	# освободиться (§3.4). Трупам ОД не нужны.
	for u in all_units:
		if u.status != MCF.Status.CORPSE:
			u.reset_ap()
