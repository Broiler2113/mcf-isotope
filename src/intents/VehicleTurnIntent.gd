class_name VehicleTurnIntent
extends Intent

## Танк actor_id (id машины) поворачивается фронтом в направление facing (1 ОД).

var facing: Vector2i

func _init(p_vehicle_id: int, p_facing: Vector2i) -> void:
	super(p_vehicle_id)
	facing = p_facing
