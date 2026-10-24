extends "res://scenes/Placement.gd"

## Render the purchase screen's real token without its surrounding HUD.
var face := Vector2i.RIGHT
var preview_opacity := 1.0

func _ready() -> void:
	set_process(false)

func _draw() -> void:
	Sprites.set_base_transform(Vector2.ZERO, Vector2.ONE)
	_draw_token(Vector2i.ZERO, 0, "tank", ThemeDB.fallback_font, face, preview_opacity)
