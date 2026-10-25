class_name DroneModel
extends RefCounted

## Kamikaze and scout drones, low-poly on one realistic atlas like the SVAROG tank
## (tools/art/build_drone_meshes.py). +X is the nose; the top plates (TeamStripe) take the
## side's colour. The board draws sprites baked from these same models
## (tools/art/build_drone_sprites.gd), recoloured the tank's way.
const KAMIKAZE: Mesh = preload("res://assets/models/drone/kamikaze.obj")
const SCOUT: Mesh = preload("res://assets/models/drone/scout.obj")
const SPRITE_SIZE := 48
const SPRITE_METRES := 0.62
static var _pictures := {}
static var _sprites := {}

static func create(scout: bool, material_for: Callable = Callable()) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = SCOUT if scout else KAMIKAZE
	if material_for.is_valid():
		for surface in node.mesh.get_surface_count():
			node.set_surface_override_material(surface, material_for.call(node.mesh.surface_get_material(surface)))
	return node

static func _picture(name: String) -> Image:
	if not _pictures.has(name):
		var img := load("res://assets/models/drone/sprites/%s.png" % name) as Image
		img = img.duplicate() if img != null else Image.create(SPRITE_SIZE, SPRITE_SIZE, false, Image.FORMAT_RGBA8)
		img.convert(Image.FORMAT_RGBA8)
		_pictures[name] = img
	return _pictures[name]

## A cached sprite per side colour: only the top plates take the paint.
static func sprite(paint: Color, scout: bool) -> Texture2D:
	var key := str([paint.to_rgba32(), scout])
	if not _sprites.has(key):
		var name := "scout_drone" if scout else "drone"
		var image: Image = _picture(name).duplicate()
		TankModel.paint_stripe(image, _picture(name + "_mask"), paint)
		_sprites[key] = Sprites.nearest(ImageTexture.create_from_image(image))
	return _sprites[key]

## Nose up, as the sprites are baked.
static func draw(ci: CanvasItem, rect: Rect2, paint: Color, scout: bool) -> void:
	ci.draw_texture_rect(sprite(paint, scout), rect, false)
