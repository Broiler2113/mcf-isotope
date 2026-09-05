class_name Intent
extends RefCounted

## Базовое намерение. PlayerController формирует Intent и отдаёт его
## GameActionResolver — единственную точку изменения состояния (см. §2.2).
## Прямые мутации состояния из UI/контроллеров запрещены.

var actor_id: int = -1

func _init(p_actor_id: int = -1) -> void:
	actor_id = p_actor_id
