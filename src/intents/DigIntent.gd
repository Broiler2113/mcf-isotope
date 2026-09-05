class_name DigIntent
extends Intent

## Копка окопа (§3.7): за 1 действие юнит роет соседнюю клетку в окоп (авто-укрытие
## выс. 1). Вынутая земля образует 2 соседние кучи земли (0.5 м).

var target: Vector2i
## Куда сложить две кучи вынутой земли (§3.7). Sentinel = авто-выбор.
var dirt_a: Vector2i = Vector2i(-999, -999)
var dirt_b: Vector2i = Vector2i(-999, -999)

func _init(p_actor_id: int, p_target: Vector2i, p_dirt_a: Vector2i = Vector2i(-999, -999), p_dirt_b: Vector2i = Vector2i(-999, -999)) -> void:
	super(p_actor_id)
	target = p_target
	dirt_a = p_dirt_a
	dirt_b = p_dirt_b
