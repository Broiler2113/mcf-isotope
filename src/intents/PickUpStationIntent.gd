class_name PickUpStationIntent
extends Intent

## Свернуть свою станцию дронов обратно в переносной предмет (item 16). Стоит 1 ОД,
## как и её установка. Станция должна стоять вплотную, быть своей и не держать
## поднятого дрона: снимать площадку из-под летящего аппарата нельзя.

var coord: Vector2i

func _init(p_actor_id: int, p_coord: Vector2i) -> void:
	super(p_actor_id)
	coord = p_coord
