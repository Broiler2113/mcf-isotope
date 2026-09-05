class_name ReleaseIntent
extends Intent

## Попытка удерживаемого юнита освободиться (§3.4). Стоит 1 ОД.
## Освобождается при броске 4+.

func _init(p_actor_id: int) -> void:
	super(p_actor_id)
