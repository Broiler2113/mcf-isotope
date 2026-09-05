class_name DroneDetonateIntent
extends Intent

## Дистанционный подрыв дрона (§3.12): взрыв, аналогичный взрыву противотанкиста,
## в текущей клетке дрона. Дрон уничтожается.

func _init(p_actor_id: int) -> void:
	super(p_actor_id)
