class_name VehicleUnloadCorpseIntent
extends Intent

## Пехотинец actor_id вытаскивает один труп из машины vehicle_id на свободную соседнюю
## клетку (item 18): павший экипаж занимает место, и его выгружают, чтобы освободить
## слот и сесть внутрь. Стоит 1 ОД.

const NOWHERE := Vector2i(-9999, -9999)
var vehicle_id: int = -1
## Where the body goes (owner, 2026-10-19): a free cell beside the puller, or the
## puller's own cell — then it carries the body. NOWHERE = the first free cell.
var to: Vector2i = NOWHERE

func _init(p_actor_id: int, p_vehicle_id: int, p_to: Vector2i = NOWHERE) -> void:
	super(p_actor_id)
	vehicle_id = p_vehicle_id
	to = p_to
