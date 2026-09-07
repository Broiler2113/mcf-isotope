class_name DPMGFireIntent
extends Intent

## Использование ДПМГ (стационарного пулемёта, §3.7) из соседней клетки за 1 действие.
## dpmg_coord — клетка пулемёта. Если ДПМГ вражеский — действие отбирает его (захват);
## иначе стреляет по target_id очередью shots (−1 = вся скорострельность).

var dpmg_coord: Vector2i
var target_id: int
var shots: int

func _init(p_actor_id: int, p_dpmg_coord: Vector2i, p_target_id: int = -1, p_shots: int = -1) -> void:
	super(p_actor_id)
	dpmg_coord = p_dpmg_coord
	target_id = p_target_id
	shots = p_shots
