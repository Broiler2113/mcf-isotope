class_name TankModel
extends RefCounted

## Supplied SVAROG geometry, normalised once by tools/art/build_tank_meshes.py.
## UVs are unchanged; normals account for the taller hull. +X is the forward axis.
const HULL: Mesh = preload("res://assets/models/tank/hull.obj")
const TURRET: Mesh = preload("res://assets/models/tank/turret.obj")
const TURRET_PIVOT := Vector3(-0.202109216, 0.0, 0.0)
const SPRITE_SIZE := 96
# A 3.6m hull slightly overhangs its 3x3 footprint; padding fits every turret angle.
const SPRITE_METRES := 3.84
static var _sprites := {}
static var _pictures := {}

## Keep text and AP dots on one neutral card below the complete sprite, so neither
## the roof stripe nor the turret is hidden by status labels at any hull facing.
static func draw_status(ci: CanvasItem, rect: Rect2, label: String,
		durability := -1, crew := 0, ap := 0) -> void:
	var font := ThemeDB.fallback_font
	var stats := "DUR %d  CREW %d" % [durability, crew] if durability >= 0 else ""
	var title_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	var stats_size := font.get_string_size(stats, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	var width := maxf(title_size.x + (ap * 8 + 10 if ap > 0 else 0), stats_size.x) + 12
	var title_height := font.get_height(14)
	var height: float = title_height + 8 + (font.get_height(12) + 2 if stats != "" else 0)
	var pos := Vector2(rect.get_center().x - width * 0.5,
			rect.end.y + rect.size.y * (SPRITE_METRES / 3.0 - 1.0) * 0.5 + 2)
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

static func _picture(name: String) -> Image:
	if not _pictures.has(name):
		var tex: Texture2D = load("res://textures/vehicles/tank/%s.png" % name)
		var img := tex.get_image()
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
			var mask := _picture("tank_mask" + suffix)
			for y in SPRITE_SIZE:
				for x in SPRITE_SIZE:
					var c := image.get_pixel(x, y)
					if c.a == 0.0 or mask.get_pixel(x, y).r < 0.5: continue
					var l := c.r * 0.3 + c.g * 0.59 + c.b * 0.11
					image.set_pixel(x, y, Color(l * paint.r, l * paint.g, l * paint.b, c.a))
		_sprites[key] = ImageTexture.create_from_image(image)
	return _sprites[key]

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
static func create(material_for: Callable = Callable()) -> Node3D:
	var root := Node3D.new()
	root.name = "SVAROG"
	root.add_child(_mesh_instance(HULL, material_for))
	var turret := Node3D.new()
	turret.name = "turret"
	turret.position = TURRET_PIVOT
	var gun := _mesh_instance(TURRET, material_for)
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
