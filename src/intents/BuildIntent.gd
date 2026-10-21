class_name BuildIntent
extends Intent

## Инженер строит укрепление в соседней клетке (§3.7).
## feature_id — что строим (стена/стекло/ЛДФ/сетка/ёж). Стоимость в ОД зависит от типа.

var target: Vector2i
var feature_id: String
## Оттенок прожектора (Furniture.make_tint); для прочих построек не читается.
var tint: int

func _init(p_actor_id: int, p_target: Vector2i, p_feature_id: String, p_tint: int = 0) -> void:
	super(p_actor_id)
	target = p_target
	feature_id = p_feature_id
	tint = p_tint
