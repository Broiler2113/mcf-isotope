class_name ShootIntent
extends Intent

## Стрельба actor_id по target_id (§3.5). Стоит 1 ОД.
## shots < 0 => полная скорострельность; иначе стрелять указанным числом пуль
## (дробление действия, §3.2). Реализация стрельбы — на M1.

var target_id: int = -1
var shots: int = -1
## Anti-tank ground shot (§3.14): target an empty floor cell instead of a unit.
## Ignored unless target_id < 0. Sentinel (-999,-999) = no cell.
var target_cell: Vector2i = Vector2i(-999, -999)

## Узел машины, по которому целится стрелок (веха «Modular tank system»): "" = узел не
## назван, и попадание разбирается каскадом. Для выстрела по пехоте не значит ничего.
var component: String = ""

func _init(p_actor_id: int, p_target_id: int, p_shots: int = -1, p_target_cell: Vector2i = Vector2i(-999, -999), p_component: String = "") -> void:
	super(p_actor_id)
	target_id = p_target_id
	shots = p_shots
	target_cell = p_target_cell
	component = p_component
