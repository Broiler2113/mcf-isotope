class_name RepairVehicleIntent
extends Intent

## Инженер actor_id чинит УЗЕЛ component машины vehicle_id (веха «Modular tank system»).
##
## Стоит 1 ОД и возвращает узлу одно очко прочности, не выше его стартового значения.
## Чинить можно только свою (или союзную) машину и только стоя рядом с ней на земле:
## изнутри до брони не дотянуться.

var vehicle_id: int = -1
var component: String = ""

func _init(p_actor_id: int, p_vehicle_id: int, p_component: String) -> void:
	super(p_actor_id)
	vehicle_id = p_vehicle_id
	component = p_component
