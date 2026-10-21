class_name GiveUnitsIntent
extends Intent

## Передать своих бойцов другому игроку (fix-7 #18): в любой момент, кому угодно из
## игроков за столом. actor_id — первый боец, как у группового приказа.

var unit_ids: Array[int] = []
var to_side: int = -1

func _init(p_unit_ids: Array[int] = [], p_to_side: int = -1) -> void:
	super(p_unit_ids[0] if not p_unit_ids.is_empty() else -1)
	unit_ids = p_unit_ids.duplicate()
	to_side = p_to_side
