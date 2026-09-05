class_name VehicleDisembarkIntent
extends Intent

## Член экипажа actor_id высаживается из машины в свободную соседнюю клетку target.

var target: Vector2i

func _init(p_actor_id: int, p_target: Vector2i) -> void:
	super(p_actor_id)
	target = p_target
