class_name AccentRect
extends ColorRect

## The receiver owns the connection, so freeing a HUD disconnects it from Ui.
func _ready() -> void:
	Ui.accent_changed.connect(_refresh)
	_refresh()

func _refresh() -> void:
	color = Ui.accent_color()
