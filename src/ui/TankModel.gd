class_name TankModel
extends RefCounted

## Supplied SVAROG geometry, normalised once by tools/art/build_tank_meshes.py.
## UVs are unchanged; normals account for the taller hull. +X is the forward axis.
## Loaded on use, never preloaded: a missing import must not stop the script compiling.
static func mesh(part: String) -> Mesh:   # "hull", "turret", "wreck_hull", "wreck_turret"
	return Sprites.mesh_at("res://assets/models/tank/%s.obj" % part)

const WRECK_TINT := Color(0.28, 0.27, 0.25)
const TURRET_PIVOT := Vector3(-0.202109216, 0.0, 0.0)
const SPRITE_SIZE := 96
# A 3.6m hull slightly overhangs its 3x3 footprint; padding fits every turret angle.
const SPRITE_METRES := 3.84
static var _sprites := {}
static var _pictures := {}
static var _silhouettes := {}

## Keep the card just below the visible tank, excluding transparent sprite padding.
## Cache alpha bounds once per frame; team colours do not change the silhouette.
static func status_top(rect: Rect2, facing: Vector2i, aim: Vector2i, wrecked := false) -> float:
	var frame := aim_frame(aim)
	var name := ("tank_wreck" if wrecked else "tank") + ("_aim_%d" % frame if frame != 0 else "")
	if not _silhouettes.has(name): _silhouettes[name] = _picture(name).get_used_rect()
	var bounds: Rect2i = _silhouettes[name]
	var angle := Vector2(facing).angle() + PI * 0.5 if facing != Vector2i.ZERO else 0.0
	var bottom := -INF
	for corner: Vector2 in [Vector2(bounds.position), Vector2(bounds.end),
			Vector2(bounds.position.x, bounds.end.y), Vector2(bounds.end.x, bounds.position.y)]:
		var local := (corner - Vector2.ONE * SPRITE_SIZE * 0.5) * rect.size * (SPRITE_METRES / 3.0) / SPRITE_SIZE
		bottom = maxf(bottom, local.rotated(angle).y)
	return rect.get_center().y + bottom + 2

## Keep text and AP dots on one neutral card without covering the stripe or gun.
static func draw_status(ci: CanvasItem, rect: Rect2, label: String,
		durability := -1, crew := 0, ap := 0, facing := Vector2i.UP,
		aim := Vector2i.ZERO, wrecked := false) -> void:
	var font := ThemeDB.fallback_font
	var stats := "DUR %d  CREW %d" % [durability, crew] if durability >= 0 else ""
	var title_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	var stats_size := font.get_string_size(stats, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	var width := maxf(title_size.x + (ap * 8 + 10 if ap > 0 else 0), stats_size.x) + 12
	var title_height := font.get_height(14)
	var height: float = title_height + 8 + (font.get_height(12) + 2 if stats != "" else 0)
	var pos := Vector2(rect.get_center().x - width * 0.5,
			status_top(rect, facing, aim, wrecked))
	var card := Rect2(pos, Vector2(width, height))
	ci.draw_rect(card, Color(0.055, 0.065, 0.08, 0.97))
	ci.draw_rect(card, Color(0.45, 0.49, 0.54), false, 1.0)
	ci.draw_string(font, pos + Vector2(6, 4 + font.get_ascent(14)), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.96, 0.97, 1.0))
	for i in maxi(0, ap):
		ci.draw_circle(pos + Vector2(width - 9 - i * 8, 4 + title_height * 0.5), 3, Color(1, 1, 0.4))
	if stats != "":
		ci.draw_string(font, pos + Vector2(6, 6 + title_height + font.get_ascent(12)), stats,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.94, 0.94, 0.74))

static func aim_frame(direction: Vector2i) -> int:
	return posmod(roundi(Vector2(direction).angle() / (PI / 4.0)), 8) if direction != Vector2i.ZERO else 0

## The sprites import as CPU Images (no GPU readback: Windows players lost every soldier
## when this ran inside the board's _draw). A missing picture draws nothing instead of
## aborting the whole board.
static func _picture(name: String) -> Image:
	if not _pictures.has(name):
		var img := Sprites.image_at("res://textures/vehicles/tank/%s.png" % name)
		if img == null: img = Image.create(SPRITE_SIZE, SPRITE_SIZE, false, Image.FORMAT_RGBA8)
		if img.is_compressed(): img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		_pictures[name] = img
	return _pictures[name]

## A cached 96x96 sprite per team and gun angle. Only the roof stripe is recoloured;
## all other armour, tracks and barrel pixels keep the original texture unchanged.
static func sprite(paint: Color, wrecked := false, aim := 0) -> Texture2D:
	var suffix := "_aim_%d" % aim if aim != 0 else ""
	var key := str([paint.to_rgba32() if not wrecked else 0, wrecked, aim])
	if not _sprites.has(key):
		var image: Image = _picture(("tank_wreck" if wrecked else "tank") + suffix).duplicate()
		if not wrecked:
			paint_stripe(image, _picture("tank_mask" + suffix), paint)
		_sprites[key] = ImageTexture.create_from_image(image)
	return _sprites[key]

## Recolour the mask's white pixels with the side's paint, keeping their light and shade.
static func paint_stripe(image: Image, mask: Image, paint: Color) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.a == 0.0 or mask.get_pixel(x, y).r < 0.5: continue
			var l := c.r * 0.3 + c.g * 0.59 + c.b * 0.11
			image.set_pixel(x, y, Color(l * paint.r, l * paint.g, l * paint.b, c.a))

static func draw(ci: CanvasItem, rect: Rect2, facing: Vector2i, paint: Color,
		wrecked := false, tint := Color.WHITE, aim := Vector2i.ZERO) -> void:
	var name := "tank_wreck" if wrecked else "tank"
	var angle := rad_to_deg(Vector2(facing).angle()) + 90.0 if facing != Vector2i.ZERO else 0.0
	if Sprites.has_user_override(name) or (wrecked and Sprites.has_user_override("tank")):
		Sprites.draw_texture_override_rect(ci, name if Sprites.has_user_override(name) else "tank", rect, angle, tint)
		return
	var picture_size := rect.size * (SPRITE_METRES / 3.0)
	var picture_rect := Rect2(rect.get_center() - picture_size * 0.5, picture_size)
	Sprites.draw_texture_rect(ci, Sprites.nearest(sprite(paint, wrecked, aim_frame(aim))), picture_rect, angle, tint)

## The same assembled model is used by first person and the overhead sprite baker.
## material_for receives the imported material so callers can retain its texture.
static func create(material_for: Callable = Callable(), wrecked := false) -> Node3D:
	var root := Node3D.new()
	root.name = "SVAROG_destroyed" if wrecked else "SVAROG"
	root.add_child(_mesh_instance(mesh("wreck_hull" if wrecked else "hull"), material_for))
	var turret := Node3D.new()
	turret.name = "turret"
	turret.position = TURRET_PIVOT
	var gun := _mesh_instance(mesh("wreck_turret" if wrecked else "turret"), material_for)
	gun.position = -TURRET_PIVOT
	turret.add_child(gun)
	root.add_child(turret)
	return root

static func _mesh_instance(mesh: Mesh, material_for: Callable) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	if material_for.is_valid():
		for surface in mesh.get_surface_count():
			node.set_surface_override_material(surface, material_for.call(mesh.surface_get_material(surface)))
	return node
