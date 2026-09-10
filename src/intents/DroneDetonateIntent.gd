class_name DroneDetonateIntent
extends Intent

## Дистанционный подрыв дрона (§3.12): взрыв, аналогичный взрыву противотанкиста,
## в текущей клетке дрона. Дрон уничтожается.

## Узел машины, который выбирает игрок (§4): подрыв дрона не бросает кубиков вовсе,
## названный узел получает своё очко гарантированно.
var component: String = ""

func _init(p_actor_id: int, p_component: String = "") -> void:
	super(p_actor_id)
	component = p_component
