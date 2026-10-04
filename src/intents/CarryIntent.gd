class_name CarryIntent
extends Intent

## Поднять переносной предмет мебели с соседней клетки в руки (§3.15). Ставят его
## обратно UseItemIntent — как свёрнутую станцию.

var coord: Vector2i

func _init(p_actor_id: int, p_coord: Vector2i) -> void:
	super(p_actor_id)
	coord = p_coord
