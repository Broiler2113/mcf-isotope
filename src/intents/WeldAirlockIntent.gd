class_name WeldAirlockIntent
extends Intent

## Инженер заваривает соседний шлюз за 1 ОД (#99): створки больше не разъезжаются
## от подошедшего юнита, и клетка навсегда работает как стена (§3.11).

var to: Vector2i

func _init(p_actor_id: int, p_to: Vector2i) -> void:
	super(p_actor_id)
	to = p_to
