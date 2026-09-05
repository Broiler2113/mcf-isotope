class_name DragIntent
extends Intent

## Перетаскивание трупа/лёгкого объекта (мешки, ёж, куча земли ≤1 м) на соседнюю
## клетку без броска (§3.4). object_coord — где объект сейчас, dest_coord — куда тащим.

var object_coord: Vector2i
var dest_coord: Vector2i

func _init(p_actor_id: int, p_object_coord: Vector2i, p_dest_coord: Vector2i) -> void:
	super(p_actor_id)
	object_coord = p_object_coord
	dest_coord = p_dest_coord
