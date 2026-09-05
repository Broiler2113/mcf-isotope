class_name DroneMoveIntent
extends Intent

## Полёт дрона в клетку target (§3.12): ортогонально, до 30 клеток за действие,
## не дальше 30 клеток от станции. Над огнём — взрыв; столкновение — взрыв.

var target: Vector2i

func _init(p_actor_id: int, p_target: Vector2i) -> void:
	super(p_actor_id)
	target = p_target
