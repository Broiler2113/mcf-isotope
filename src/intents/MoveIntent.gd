class_name MoveIntent
extends Intent

## Переместить юнита actor_id в клетку target (§3.1). Стоит 1 ОД.

var target: Vector2i
## Куда положить переносимого пленника (§3.4). Sentinel (-999,-999) = авто (у цели).
var carry_drop: Vector2i = Vector2i(-999, -999)

func _init(p_actor_id: int, p_target: Vector2i, p_carry_drop: Vector2i = Vector2i(-999, -999)) -> void:
	super(p_actor_id)
	target = p_target
	carry_drop = p_carry_drop
