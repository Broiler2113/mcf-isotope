class_name VehicleCannonIntent
extends Intent

## Танк actor_id (id машины) стреляет из главной пушки по клетке target:
## взрыв 3×3, как противотанковый; технике — 2 прочности. 1 ОД, ≤2 раз/ход.

var target: Vector2i
## Узел вражеской машины, по которому наводится пушка ("" = не назван).
var component: String = ""

func _init(p_vehicle_id: int, p_target: Vector2i, p_component: String = "") -> void:
	super(p_vehicle_id)
	target = p_target
	component = p_component
