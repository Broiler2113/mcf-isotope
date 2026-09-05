class_name LocalHumanController
extends PlayerController

## Ввод локального игрока (hotseat). UI вызывает submit() с намерением,
## сформированным по клику игрока.

func submit(intent: Intent) -> void:
	intent_ready.emit(intent)

func is_local_human() -> bool:
	return true
