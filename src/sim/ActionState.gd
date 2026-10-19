class_name ActionState
extends RefCounted

## Незавершённое действие стрельбы, которое можно дробить между ОД (см. §3.2).
## Не сбрасывается, пока remaining_shots не израсходован.

var target_id: int = -1
## Очередь по ОКНУ (0.9.2): бойца-цели нет, но остаток очереди тоже можно дострелить —
## по тому же окну или по любой другой цели, как у обычной очереди.
const WINDOW := -2
var remaining_shots: int = 0
## A DPMG burst (owner, 2026-10-19) lives here too, tied to the gun's cell: its rounds
## are fired from that gun only and never count as the soldier's own burst.
const NO_DPMG := Vector2i(-1, -1)
var dpmg: Vector2i = NO_DPMG

func is_pending() -> bool:
	return remaining_shots > 0 and target_id != -1 and dpmg == NO_DPMG

func dpmg_pending(at: Vector2i) -> bool:
	return remaining_shots > 0 and dpmg == at and at != NO_DPMG
