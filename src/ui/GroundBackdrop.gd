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

const GROUND_TILES := 16
const GROUND_PATCH_CHANCE := 0.07

static func wallpaper(env: String) -> ImageTexture:
	var base := _ground_image(_ground_floor_name(env))
	if env == "bunker":
		# Continue the soil WALL using its fully connected tile, not a floor or
		# the standalone wall sprite with a dark outline around every tile.
		var soil := _ground_image("soil_autotile")
		if soil != null:
			var tile := soil.get_width() / 4
			var variants := maxi(1, soil.get_height() / (tile * 4))
			base = Image.create(tile * variants, tile, false, Image.FORMAT_RGBA8)
			for v in variants:
				base.blit_rect(soil, Rect2i(tile * 3, (v * 4 + 3) * tile, tile, tile),
						Vector2i(v * tile, 0))
	if base == null:
		return null
	var patch := _ground_image(_ground_patch_name(env))
	var t := base.get_height()
	var vars_n := maxi(1, base.get_width() / t)
	var img := Image.create(GROUND_TILES * t, GROUND_TILES * t, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = GROUND_TILES * 7919 + t
	for y in GROUND_TILES:
		for x in GROUND_TILES:
			var src := base
			var n := vars_n
			if patch != null and rng.randf() < GROUND_PATCH_CHANCE:
				src = patch
				n = maxi(1, patch.get_width() / patch.get_height())
			var v := TerrainTiles.variant_of(Vector2i(x, y), n)
			img.blit_rect(src, Rect2i(v * t, 0, t, t), Vector2i(x * t, y * t))
	return ImageTexture.create_from_image(img)

static func _ground_image(name: String) -> Image:
	var tex := Sprites.texture_of(name)
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img

## Чем залит экран и чем идут проплешины — по окружению карты.
static func _ground_floor_name(env: String) -> String:
	match env:
		"field", "town": return "floor_grass"
		"bunker": return "soil"
		"": return "floor"
	return TerrainTiles.env_name("floor", env)

static func _ground_patch_name(env: String) -> String:
	match env:
		"field", "town": return ""
		"bunker": return ""
	return "floor_field"
