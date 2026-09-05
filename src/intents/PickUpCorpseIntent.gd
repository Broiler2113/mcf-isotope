class_name PickUpCorpseIntent
extends Intent

## Живой юнит подбирает труп с соседней (или своей) клетки, чтобы нести его как
## переносной щит (#6): каждый несомый труп даёт +1 к его броскам защиты. Стоит 1 ОД.

var from: Vector2i

func _init(p_actor_id: int, p_from: Vector2i) -> void:
	super(p_actor_id)
	from = p_from
