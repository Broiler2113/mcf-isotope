class_name LightManager
extends CanvasLayer

## Lighting-only viewport: engine PointLight2D + LightOccluder2D do all shadow work.
## Each receiver has a unique light mask within its canvas. Additional canvases
## accommodate more sources, so a giant battlefield is not one 16-light object.
## The final multiply layer changes appearance only, below the existing HUD.
const MASKS_PER_CANVAS := 20
const AMBIENT := Color(0.22, 0.23, 0.25, 1.0)
var geometry := LightOccluders.new()
var lights: Dictionary = {}
var batches: Array[Dictionary] = []
var viewport: SubViewport
var ambient: ColorRect
var overlay: Sprite2D
var radial: GradientTexture2D
var white: ImageTexture
var receiver_material: CanvasItemMaterial
var polygon: OccluderPolygon2D
var _geometry_key: Array = []
var _known_shapes: Dictionary = {}
var _clock := 0.0
var _next_canvas_layer := 1
var _cell_size := 32.0
var _grid_bounds := Rect2i()

func _ready() -> void:
	layer = 0
	viewport = SubViewport.new()
	viewport.world_2d = World2D.new()
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	ambient = ColorRect.new()
	ambient.color = AMBIENT
	ambient.light_mask = 0
	viewport.add_child(ambient)
	var gradient := Gradient.new()
	gradient.set_color(0, Color.WHITE)
	gradient.set_color(1, Color(0, 0, 0, 0))
	radial = GradientTexture2D.new()
	radial.gradient = gradient
	radial.width = 256
	radial.height = 256
	radial.fill = GradientTexture2D.FILL_RADIAL
	radial.fill_from = Vector2(0.5, 0.5)
	radial.fill_to = Vector2(1.0, 0.5)
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	white = ImageTexture.create_from_image(image)
	receiver_material = CanvasItemMaterial.new()
	receiver_material.light_mode = CanvasItemMaterial.LIGHT_MODE_NORMAL
	receiver_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	overlay = Sprite2D.new()
	overlay.centered = false
	overlay.texture = viewport.get_texture()
	var multiply := CanvasItemMaterial.new()
	multiply.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	multiply.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	overlay.material = multiply
	add_child(overlay)

func update_view(grid: Grid, offset: Vector2, zoom: float, cell_size: float,
		visible_cells: Dictionary = {}, limited: bool = false, fx: FxDecals = null) -> void:
	if viewport == null: return
	_clock = float(Time.get_ticks_msec()) / 1000.0
	_cell_size = cell_size
	_grid_bounds = Rect2i(0, 0, grid.width, grid.height)
	var size := Vector2i(get_viewport().get_visible_rect().size).max(Vector2i.ONE)
	viewport.size = size
	ambient.size = Vector2(size)
	geometry.sync(grid)
	# Hidden geometry must not reveal itself through shadows on visible ground.
	var visibility_key := [grid.get_instance_id(), limited, hash(visible_cells) if limited else 0, cell_size]
	var full := geometry.full_sync or visibility_key != _geometry_key
	if full:
		_geometry_key = visibility_key
		_known_shapes.clear()
		for c: Vector2i in geometry.shapes:
			if not limited or visible_cells.has(c): _known_shapes[c] = true
		polygon = OccluderPolygon2D.new()
		polygon.polygon = PackedVector2Array([Vector2.ZERO, Vector2(cell_size, 0),
			Vector2(cell_size, cell_size), Vector2(0, cell_size)])
		for batch in batches: _sync_occluders(batch)
	elif not geometry.changed.is_empty():
		for c: Vector2i in geometry.changed:
			if geometry.shapes.has(c) and (not limited or visible_cells.has(c)): _known_shapes[c] = true
			else: _known_shapes.erase(c)
		for batch in batches: _sync_occluders(batch, geometry.changed)
	var wanted: Dictionary = {}
	for c: Vector2i in geometry.sources:
		if limited and not visible_cells.has(c): continue
		for source: Dictionary in geometry.sources[c]:
			var energy: float = source.energy
			if source.kind == "fire": energy *= 0.94 + 0.06 * sin(_clock * 11.0 + c.x * 3 + c.y)
			_request(wanted, "%s:%d:%d" % [source.kind, c.x, c.y], Vector2(c) + Vector2.ONE * 0.5 + Vector2(source.get("offset", Vector2.ZERO)),
				float(source.range), source.color, energy, offset, zoom, size)
	if fx != null:
		for i in fx.flashes.size():
			var flash: Dictionary = fx.flashes[i]
			var alpha := FxDecals.flash_alpha(flash)
			for c: Vector2i in flash.cells:
				if limited and not visible_cells.has(c): continue
				_request(wanted, "flash:%d:%d:%d" % [i, c.x, c.y], Vector2(c) + Vector2.ONE * 0.5,
					3.0, Color(1.0, 0.65, 0.30), alpha, offset, zoom, size)
		for i in fx.lanes.size():
			var lane: Dictionary = fx.lanes[i]
			var c := Vector2(lane.from)
			if limited and not visible_cells.has(Vector2i(c.floor())): continue
			var energy := maxf(0.0, 1.0 - float(lane.t) / 0.12)
			if energy > 0:
				_request(wanted, "muzzle:%d" % i, c, 2.0, Color(1.0, 0.83, 0.48), energy, offset, zoom, size)
	for key: String in lights.keys():
		if not wanted.has(key): _remove_light(key)
	for i in range(batches.size() - 1, -1, -1):
		if batches[i].used.is_empty():
			batches[i].canvas.free()
			batches.remove_at(i)
	var transform := Transform2D(0.0, Vector2(zoom, zoom), 0.0, offset)
	for batch in batches: batch.canvas.transform = transform

func _request(wanted: Dictionary, key: String, at: Vector2, radius: float, color: Color,
		energy: float, offset: Vector2, zoom: float, size: Vector2i) -> void:
	if energy <= 0.0: return
	var centre := at * _cell_size
	var extent := radius * _cell_size
	var screen := Rect2(offset + (centre - Vector2.ONE * extent) * zoom,
		Vector2.ONE * extent * 2.0 * zoom)
	if not screen.intersects(Rect2(Vector2.ZERO, Vector2(size))): return
	wanted[key] = true
	if not lights.has(key): _add_light(key)
	var record: Dictionary = lights[key]
	var cell := Vector2i(at.floor())
	var r := ceili(radius) + 1
	var region := Rect2i(cell - Vector2i(r, r), Vector2i.ONE * (2 * r + 1)).intersection(_grid_bounds)
	if record.get("cell") != cell or record.get("region") != region:
		_clear_shadow_mask(record)
		record.cell = cell
		record.region = region
		_add_shadow_mask(record)
	var light: PointLight2D = record.light
	light.position = centre
	light.texture_scale = extent * 2.0 / radial.width
	light.color = color
	light.energy = energy
	record.receiver.position = centre
	record.receiver.scale = Vector2.ONE * extent * 2.0

func _add_light(key: String) -> void:
	var chosen: Dictionary = {}
	var slot := 0
	for batch in batches:
		if batch.used.size() < MASKS_PER_CANVAS:
			chosen = batch
			break
	if chosen.is_empty():
		var canvas := CanvasLayer.new()
		canvas.layer = _next_canvas_layer
		_next_canvas_layer += 1
		viewport.add_child(canvas)
		var darkness := CanvasModulate.new()
		darkness.color = Color(0, 0, 0, 1)
		canvas.add_child(darkness)
		chosen = {"canvas": canvas, "used": {}, "occluders": {}, "members": {}}
		batches.append(chosen)
	while chosen.used.has(slot): slot += 1
	chosen.used[slot] = true
	var light := PointLight2D.new()
	light.texture = radial
	light.range_layer_min = chosen.canvas.layer
	light.range_layer_max = chosen.canvas.layer
	light.range_item_cull_mask = 1 << slot
	light.shadow_item_cull_mask = 1 << slot
	light.shadow_enabled = true
	light.shadow_filter = Light2D.SHADOW_FILTER_PCF5
	chosen.canvas.add_child(light)
	var receiver := Sprite2D.new()
	receiver.texture = white
	receiver.material = receiver_material
	receiver.light_mask = 1 << slot
	chosen.canvas.add_child(receiver)
	lights[key] = {"light": light, "receiver": receiver, "batch": chosen, "slot": slot}
	chosen.members[key] = true

func _remove_light(key: String) -> void:
	var record: Dictionary = lights[key]
	_clear_shadow_mask(record)
	record.batch.members.erase(key)
	record.light.free()
	record.receiver.free()
	record.batch.used.erase(record.slot)
	lights.erase(key)

# Each canvas keeps only geometry within its lights' finite ranges. A giant map
# does not allocate its entire wall grid once for every group of twenty lights.
func _set_occluder(batch: Dictionary, c: Vector2i, mask: int) -> void:
	if mask == 0:
		if batch.occluders.has(c):
			batch.occluders[c].free()
			batch.occluders.erase(c)
		return
	if not batch.occluders.has(c):
		var node := LightOccluder2D.new()
		batch.canvas.add_child(node)
		batch.occluders[c] = node
	var node: LightOccluder2D = batch.occluders[c]
	node.occluder = polygon
	node.occluder_light_mask = mask
	node.position = Vector2(c) * _cell_size

func _clear_shadow_mask(record: Dictionary) -> void:
	if not record.has("region"): return
	var rect: Rect2i = record.region
	var batch: Dictionary = record.batch
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, y)
			if batch.occluders.has(c):
				_set_occluder(batch, c, batch.occluders[c].occluder_light_mask & ~(1 << record.slot))

func _add_shadow_mask(record: Dictionary) -> void:
	if not record.has("region"): return
	var rect: Rect2i = record.region
	var batch: Dictionary = record.batch
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, y)
			if c == record.cell or not _known_shapes.has(c): continue
			var mask := 0
			if batch.occluders.has(c): mask = batch.occluders[c].occluder_light_mask
			_set_occluder(batch, c, mask | (1 << record.slot))

func _sync_occluders(batch: Dictionary, changed: Dictionary = {}) -> void:
	# Full rebuild changes visibility or scale; ordinary construction/destruction
	# only touches the cells supplied by LightOccluders' incremental journal.
	if changed.is_empty():
		var touched: Dictionary = batch.occluders.duplicate()
		for key: String in batch.members:
			var record: Dictionary = lights[key]
			if not record.has("region"): continue
			var rect: Rect2i = record.region
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					var c := Vector2i(x, y)
					if _known_shapes.has(c): touched[c] = true
		changed = touched
	for c: Vector2i in changed:
		var mask := 0
		if _known_shapes.has(c):
			for key: String in batch.members:
				var record: Dictionary = lights[key]
				if record.has("region") and record.region.has_point(c) and record.cell != c:
					mask |= 1 << record.slot
		_set_occluder(batch, c, mask)
