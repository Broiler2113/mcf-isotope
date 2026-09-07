class_name RedoIntent
extends Intent

## Повтор откатанного действия (#38, §18.2). Симметричен UndoIntent и по той же
## причине проходит через резолвер: стеки обязаны совпадать у всех пиров.

var requester: int = -1

func _init(p_requester: int = -1) -> void:
	super(-1)
	requester = p_requester
