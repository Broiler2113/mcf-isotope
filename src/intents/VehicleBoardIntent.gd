class_name VehicleBoardIntent
extends Intent

## Пехотинец actor_id садится в машину vehicle_id из соседней клетки (§техника).

var vehicle_id: int = -1

func _init(p_actor_id: int, p_vehicle_id: int) -> void:
	super(p_actor_id)
	vehicle_id = p_vehicle_id
