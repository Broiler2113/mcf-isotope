class_name CaptureIntent
extends Intent

## Захват соседнего вражеского юнита (§3.4). Стоит 1 ОД.
## Встречный бросок 1d6: выше выигрывает, ничья — переброс.

var target_id: int = -1

func _init(p_actor_id: int, p_target_id: int) -> void:
	super(p_actor_id)
	target_id = p_target_id
