class_name VehicleUnloadCorpseIntent
extends Intent

## Пехотинец actor_id вытаскивает один труп из машины vehicle_id на свободную соседнюю
## клетку (item 18): павший экипаж занимает место, и его выгружают, чтобы освободить
## слот и сесть внутрь. Стоит 1 ОД.

var vehicle_id: int = -1

func _init(p_actor_id: int, p_vehicle_id: int) -> void:
	super(p_actor_id)
	vehicle_id = p_vehicle_id
