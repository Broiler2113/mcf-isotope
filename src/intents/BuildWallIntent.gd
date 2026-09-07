class_name BuildWallIntent
extends Intent

## Инженер выкладывает ЛДФ-стену из MCF.LDF_WALL_LENGTH клеток за одно действие
## (§3.7). Лишь одна клетка обязана соседствовать с инженером — остальные ставятся
## свободно, где угодно по свободному полу; игрок «рисует» их вручную (#58).

var cells: Array[Vector2i]

func _init(p_actor_id: int, p_cells: Array[Vector2i]) -> void:
	super(p_actor_id)
	cells = p_cells
