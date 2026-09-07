class_name DisarmMineIntent
extends Intent

## Сапёр обезвреживает ПОДСВЕЧЕННУЮ его стороной чужую мину на соседней клетке (item 13).
## Обезвреживать вслепую нельзя: сперва мину надо найти зачисткой (RevealMinesIntent).
## Стоит 1 ОД, мина просто снимается — без взрыва.

var target: Vector2i

func _init(p_actor_id: int, p_target: Vector2i) -> void:
	super(p_actor_id)
	target = p_target
