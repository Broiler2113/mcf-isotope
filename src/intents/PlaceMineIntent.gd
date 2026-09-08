class_name PlaceMineIntent
extends Intent

## Установка мины (item 45). Одна мина за намерение; за одно ДЕЙСТВИЕ их ставится
## до MCF.MINES_PER_ACTION — первая тратит ОД и открывает кредит на остальные,
## ровно как копка окопов открывает кредит на серию (§3.7).
##
## Кредит переживает другие действия и гаснет только на границе раунда: источник
## требует, чтобы прерванный сапёр мог «доставить» оставшиеся мины позже.

var target: Vector2i
## true — противотанковая мина (item 13): бьёт только по технике, пехоту пропускает.
var anti_vehicle: bool = false

func _init(p_actor_id: int, p_target: Vector2i, p_anti_vehicle: bool = false) -> void:
	super(p_actor_id)
	target = p_target
	anti_vehicle = p_anti_vehicle
