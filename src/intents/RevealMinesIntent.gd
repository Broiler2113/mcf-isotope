class_name RevealMinesIntent
extends Intent

## Подсветить все чужие мины в радиусе MCF.MINE_REVEAL_RADIUS, до которых у сапёра
## есть прямая видимость, на MCF.MINE_REVEAL_TURNS ход (item 45). Стоит 1 ОД.

func _init(p_actor_id: int) -> void:
	super(p_actor_id)
