class_name BuildIntent
extends Intent

## Инженер строит укрепление в соседней клетке (§3.7).
## feature_id — что строим (стена/стекло/БРУ/сетка/ёж). Стоимость в ОД зависит от типа.

var target: Vector2i
var feature_id: String

func _init(p_actor_id: int, p_target: Vector2i, p_feature_id: String) -> void:
	super(p_actor_id)
	target = p_target
	feature_id = p_feature_id
