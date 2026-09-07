class_name SpawnDroneIntent
extends Intent

## Оператор запускает дрон со стоящей рядом станции (§3.12). Стоит 1 ОД оператора.
##
## station — С КАКОЙ именно станции (item 17). Рядом их может стоять несколько, и
## выбирает игрок, а не игра. NOWHERE = «любая подходящая»: так приходят намерения
## от ИИ и старых записей, и резолвер берёт первую по обходу соседей.

const NOWHERE := Vector2i(-999, -999)

var station: Vector2i = NOWHERE

func _init(p_actor_id: int, p_station: Vector2i = NOWHERE) -> void:
	super(p_actor_id)
	station = p_station
