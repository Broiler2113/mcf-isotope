class_name VehicleMeleeIntent
extends Intent

## Шахтёр actor_id бьёт по корпусу соседней машины vehicle_id (item 15): один бросок
## d6, на MCF.MINER_VEHICLE_HIT_NEED снимается MCF.MINER_VEHICLE_DAMAGE прочности.
## Стоит 1 ОД.

var vehicle_id: int = -1

func _init(p_actor_id: int, p_vehicle_id: int) -> void:
	super(p_actor_id)
	vehicle_id = p_vehicle_id
