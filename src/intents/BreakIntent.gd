class_name BreakIntent
extends Intent

## Шахтёр ломает стену/стекло/ЛДФ в соседней клетке за 1 действие (§3.7, обратное инженеру).

var target: Vector2i

func _init(p_actor_id: int, p_target: Vector2i) -> void:
	super(p_actor_id)
	target = p_target
