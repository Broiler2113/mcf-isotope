class_name VehicleSeatIntent
extends Intent

## Пассажир челнока actor_id пересаживается в свободное кресло seat (batch 13, S6): 1 ОД.
## Кресло водителя — Vehicle.DRIVER_SEAT; кто в нём сидит, тот и ведёт машину.

var seat: int = -1

func _init(p_actor_id: int, p_seat: int) -> void:
	super(p_actor_id)
	seat = p_seat
