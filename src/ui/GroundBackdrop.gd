class_name GroundBackdrop
extends Node2D

## Cosmetic wallpaper outside the finite board. Repeating one baked texture costs
## at most four quads, regardless of map size or zoom; there are no terrain cells.
## Leaving the board itself uncovered preserves stars in any open-space tiles.
var texture: Texture2D
var _board := Rect2()
var _view := Rect2()

func _init() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func fit_view(origin: Vector2, pixel_scale: float, board_size: Vector2,
		viewport_size: Vector2) -> void:
	if pixel_scale <= 0.0:
		return
	var board := Rect2(Vector2.ZERO, board_size)
	var view := Rect2(-origin / pixel_scale, viewport_size / pixel_scale)
	if position == origin and scale == Vector2.ONE * pixel_scale \
			and _board == board and _view == view:
		return
	position = origin
	scale = Vector2.ONE * pixel_scale
	_board = board
	_view = view
	queue_redraw()

func _draw() -> void:
	if texture == null or not _view.has_area():
		return
	var inside := _view.intersection(_board)
	if not inside.has_area():
		_draw_patch(_view)
		return
	# Top/bottom span the view; left/right span only the intersecting board rows.
	_draw_patch(Rect2(_view.position, Vector2(_view.size.x, inside.position.y - _view.position.y)))
	_draw_patch(Rect2(Vector2(_view.position.x, inside.end.y),
			Vector2(_view.size.x, _view.end.y - inside.end.y)))
	_draw_patch(Rect2(Vector2(_view.position.x, inside.position.y),
			Vector2(inside.position.x - _view.position.x, inside.size.y)))
	_draw_patch(Rect2(Vector2(inside.end.x, inside.position.y),
			Vector2(_view.end.x - inside.end.x, inside.size.y)))

func _draw_patch(rect: Rect2) -> void:
	if rect.has_area():
		# Source coordinates share the board origin, so clipped pieces stay aligned
		# while panning/resizing. Repeat sampling handles UVs outside the texture.
		draw_texture_rect_region(texture, rect, rect, Color.WHITE, false, false)
