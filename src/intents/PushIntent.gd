class_name PushIntent
extends Intent

## Толчок щитом (§3.14): щитоносец бьёт соседнего врага.
## Бросок защиты цели со штрафом −2; провал — смерть, иначе — толчок на 1 клетку.

var target_id: int = -1

func _init(p_actor_id: int, p_target_id: int) -> void:
	super(p_actor_id)
	target_id = p_target_id
