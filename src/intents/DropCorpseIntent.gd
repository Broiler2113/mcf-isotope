class_name DropCorpseIntent
extends Intent

## Складывает один несомый труп на свою или соседнюю проходимую клетку (#6).
## Бесплатно — юнит просто кладёт щит на землю.

var to: Vector2i

func _init(p_actor_id: int, p_to: Vector2i) -> void:
	super(p_actor_id)
	to = p_to
