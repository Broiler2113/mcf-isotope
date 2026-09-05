class_name ActionState
extends RefCounted

## Незавершённое действие стрельбы, которое можно дробить между ОД (см. §3.2).
## Не сбрасывается, пока remaining_shots не израсходован.

var target_id: int = -1
var remaining_shots: int = 0

func is_pending() -> bool:
	return remaining_shots > 0 and target_id != -1
