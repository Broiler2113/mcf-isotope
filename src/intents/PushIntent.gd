class_name PushIntent
extends Intent

## Толчок щитом (§3.14): щитоносец бьёт соседнего врага.
## Бросок защиты цели со штрафом −2; провал — смерть, иначе — толчок на 1 клетку.

var target_id: int = -1
## An adjacent pane instead of a unit; sentinel preserves older unit-push records.
var target_cell: Vector2i = Vector2i(-999, -999)

func _init(p_actor_id: int, p_target_id: int, p_target_cell := Vector2i(-999, -999)) -> void:
	super(p_actor_id)
	target_id = p_target_id
	target_cell = p_target_cell
