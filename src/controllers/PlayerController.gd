class_name PlayerController
extends RefCounted

## Управляющее лицо одной стороны (§2.1). Слой симуляции не знает, какая это
## реализация. Контроллер НЕ трогает состояние напрямую — он лишь формирует
## Intent и отдаёт его наружу через сигнал (§2.2).

signal intent_ready(intent: Intent)

var owner: int

func _init(p_owner: int) -> void:
	owner = p_owner

## Вызывается, когда наступает ход этой стороны.
func begin_turn(_state: GameState) -> void:
	pass

## Вызывается после каждого применённого действия (для реакции ИИ/сети).
func notify_state_changed(_state: GameState) -> void:
	pass

## Резолвер отклонил предложенное намерение (#60). Контроллер должен как-то
## продвинуться вперёд, иначе он предложит то же самое и ход зациклится.
func notify_intent_denied(_state: GameState) -> void:
	pass

func is_local_human() -> bool:
	return false
