class_name NetworkController
extends PlayerController

## Заглушка сетевого игрока до M7. Интерфейс финальный (§2.1, §2.3).
## Позже: приём сериализованных Intent'ов удалённой стороны по ENet; броски
## авторитетны на хосте. Пока — только точка входа для доставленного намерения.

## Вызывается сетевым слоем, когда удалённый игрок прислал своё намерение.
func deliver_remote_intent(intent: Intent) -> void:
	intent_ready.emit(intent)
