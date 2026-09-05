class_name UseItemIntent
extends Intent

## Применить носимый предмет (гранату) в клетку target (§3.6). Стоит 1 ОД.
## Предмет расходуется вне зависимости от исхода.

var target: Vector2i

func _init(p_actor_id: int, p_target: Vector2i) -> void:
	super(p_actor_id)
	target = p_target
