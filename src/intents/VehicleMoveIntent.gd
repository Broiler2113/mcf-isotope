class_name VehicleMoveIntent
extends Intent

## Машина actor_id (id машины) едет в направлении dir на steps клеток (1 ОД).
## Танк: dir = ±facing. Челнок: любое из 8 направлений.

var dir: Vector2i
var steps: int = 1

func _init(p_vehicle_id: int, p_dir: Vector2i, p_steps: int = 1) -> void:
	super(p_vehicle_id)
	dir = p_dir
	steps = p_steps
