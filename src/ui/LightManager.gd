class_name LightManager
extends Node2D

## Soft 2D lighting in the spirit of Space Station 14 (0.11 rework).
##
## A small light map in CELL space — a few texels per cell, and only for the cells on
## screen — is redrawn when the view, the walls or the lights change, never otherwise.
## Every light is one instance of a single MultiMesh quad (one draw call for all of
## them); its shader marches from the lamp towards the texel through a wall mask that
## has one texel per cell, read exactly; five rays across the lamp's width and a blur
## soften the edges. A wall tile that light reaches is lit whole and evenly, while the floor
## behind it stays dark; furniture under 2 m, glass and open doors let light through; a
## lamp always lights its own tile, and a wall lamp only its own side of the wall. Lamps are
## drawn into a cached map of their own, redrawn only when the view, walls or lamps change;
## fire, flashes and muzzle fire go on top of a copy of it, so a flicker never re-marches
## hundreds of lamps (zoomed-out FPS, 2026-10-28). The map starts from the ambient colour and
## the finished texture MULTIPLIES the terrain layer only — tokens, labels and previews
## stay readable. The cost follows the screen, not the number of lamps or the map size.
##
## Usage: add as a child of the board scene, then every frame
##   update_view(grid, pan, zoom, origin, cell, env, visible, limited, fx, after_layer)
## pan/zoom/origin describe the terrain layer's transform (position = pan, scale = zoom,
## board's top-left at `origin` in its local space).

const MAX_RANGE := 16.0
## Texels per cell bounds; the actual density follows the on-screen cell size.
const MIN_TEXELS := 1
const MAX_TEXELS := 12
const SCREEN_PX_PER_TEXEL := 2.0
## The light map covers whole chunks around the screen, so panning inside them is free.
const CHUNK := 12
## Darkness 0..1 maps to the light level of unlit ground.
const AMBIENT_BRIGHT := 1.0
const AMBIENT_DARK := 0.06

## Space cells read the mask's green channel and stay at full brightness: stars are not lit.
const SPACE_SHADER := """
shader_type canvas_item;
render_mode blend_add, unshaded;
uniform sampler2D walls : filter_nearest, repeat_disable;
uniform vec2 board;
uniform vec4 view;           // first cell and size of the light map, in cells
void fragment() {
	float space = texture(walls, (view.xy + UV * view.zw) / board).g;
	COLOR = vec4(vec3(space), 1.0);
}
"""

## Final multiply over the terrain, with a small 5-tap blur so pools have no seams.
const COMPOSITE_SHADER := """
shader_type canvas_item;
render_mode blend_mul, unshaded;
void fragment() {
	vec2 o = TEXTURE_PIXEL_SIZE * 0.85;
	vec3 c = texture(TEXTURE, UV).rgb * 0.36;
	c += texture(TEXTURE, UV + vec2(o.x, o.y)).rgb * 0.16;
	c += texture(TEXTURE, UV + vec2(-o.x, o.y)).rgb * 0.16;
	c += texture(TEXTURE, UV + vec2(o.x, -o.y)).rgb * 0.16;
	c += texture(TEXTURE, UV + vec2(-o.x, -o.y)).rgb * 0.16;
	COLOR = vec4(c, 1.0);
}
"""

const SHADER := """
shader_type canvas_item;
render_mode blend_add, unshaded;

// One texel per cell, read exactly: a ray is stopped by a wall cell or it is not. The
// softness comes from the area light below and the composite blur, never from blending
// the mask - blended reads let light seep a cell deep behind every wall (0.11).
uniform sampler2D walls : filter_nearest, repeat_disable;
uniform vec2 board;          // board size in cells

varying vec2 local;
varying vec4 light;          // x, y (cells), radius, energy
varying vec4 tint;

void vertex() {
	local = VERTEX;            // quad spans [-1, 1]
	light = INSTANCE_CUSTOM;
	tint = COLOR;
}

float wall_at(vec2 q) {
	return texture(walls, q / board).r;
}

void fragment() {
	vec2 lp = light.xy;
	float r = light.z;
	vec2 p = lp + local * r;
	float d = length(p - lp);
	if (d >= r) {
		COLOR = vec4(0.0);
	} else {
		// Broad soft disk: bright most of the way, easing out at the rim. MapLighting
		// spaces lamps with this exact curve (MapLighting.falloff).
		float fall = 1.0 - smoothstep(0.0, 1.0, d / r);
		vec2 own = floor(p);
		vec2 src = floor(lp);
		// A wall tile is lit whole and evenly once light reaches any face of it: every ray
		// aims at the point of the tile nearest its origin, so no texel inside the wall is
		// shaded by the wall tiles next to it (0.11 playtest: "black spots in the middle").
		// The floor behind the wall is a different tile and stays in its shadow.
		bool solid = wall_at(p) > 0.5;
		vec2 dir = (p - lp) / max(d, 0.0001);
		vec2 side = vec2(-dir.y, dir.x);
		// An area light, not a point: five rays from across the lamp's width give wide soft
		// penumbrae instead of hard diagonal wedges behind wall corners. Each ray starts on
		// the lamp's side of any wall: a lamp on a wall never shines from behind it.
		float spread = clamp(r * 0.07, 0.3, 0.8);
		float sum = 0.0;
		for (int k = -2; k <= 2; k++) {
			float want = abs(float(k)) * spread;
			vec2 sd = side * sign(float(k));
			float reach = 0.0;
			for (int j = 1; j <= 8; j++) {
				float a = float(j) * 0.2;
				if (a > want) {
					if (wall_at(lp + sd * want) < 0.5) reach = want;
					break;
				}
				if (wall_at(lp + sd * a) > 0.5) break;
				reach = a;
			}
			vec2 o = lp + sd * reach;
			vec2 aim = solid ? clamp(o, own + 0.02, own + 0.98) : p;
			vec2 to = aim - o;
			float len = length(to);
			vec2 st = to / max(len, 0.0001);
			float t = 1.0;
			for (int i = 0; i < 48; i++) {
				float along = 0.25 + float(i) * 0.35;
				if (along >= len) break;
				vec2 q = o + st * along;
				vec2 cq = floor(q);
				if (cq == own) break;         // reached the target's own cell
				if (cq == src) continue;      // the lamp's own cell never shades it
				t *= 1.0 - wall_at(q);
				if (t < 0.02) break;
			}
			sum += t;
		}
		float tr = sum / 5.0;
		float glow = smoothstep(0.9, 0.0, d) * 0.55;
		COLOR = vec4(tint.rgb * light.w * (fall + glow) * tr, 1.0);
	}
}
"""

var occluders := LightOccluders.new()
var ambient := Color(0.24, 0.25, 0.28)
## Fire breathes a little on the battle screen; the first-person view keeps it steady
## (owner, fix-8: "remove the flickering lights").
var flicker := true
## Lights that are neither lamps nor effects: drones in the air (fix-8 #12). Each is
## [position in cells, radius, energy, colour]; the owner of this map fills it.
var extra_lights: Array = []
## Drawn into a texture only (first person): nothing is laid over the screen.
var offscreen := false
## Debug / test counters.
var redraws := 0
var last_instances := 0

var _vp: SubViewport
## Ambient + space + every static lamp; _vp shows it under the dynamic lights.
var _svp: SubViewport
var _copy: Sprite2D
var _dmesh: MultiMesh
var _static_render: Array = []
var _base: ColorRect
var _space: ColorRect
var _space_mat: ShaderMaterial
var _space_env := false
var _mmi: MultiMeshInstance2D
var _mesh: MultiMesh
var _mat: ShaderMaterial
var _out: Sprite2D
var _shade: Node2D
var _walls_img: Image
var _walls_tex: ImageTexture
var _walls_key: Array = []
var _key: Array = []
var _static_key: Array = []
var _static: Array = []
var _fires: Array = []
var _cell := 32.0
var _origin := Vector2.ZERO

func _ready() -> void:
	show_behind_parent = true
	_vp = SubViewport.new()
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	add_child(_vp)
	# A child viewport is drawn before its parent, so the copy below is never a frame old.
	_svp = SubViewport.new()
	_svp.disable_3d = true
	_svp.transparent_bg = false
	_svp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_svp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	_vp.add_child(_svp)
	_copy = Sprite2D.new()
	_copy.centered = false
	_copy.texture = _svp.get_texture()
	_copy.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_vp.add_child(_copy)
	_base = ColorRect.new()
	_svp.add_child(_base)
	_space = ColorRect.new()
	_space_mat = ShaderMaterial.new()
	var space_shader := Shader.new()
	space_shader.code = SPACE_SHADER
	_space_mat.shader = space_shader
	_space.material = _space_mat
	_svp.add_child(_space)
	_mesh = MultiMesh.new()
	_mesh.transform_format = MultiMesh.TRANSFORM_2D
	_mesh.use_colors = true
	_mesh.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	_mesh.mesh = quad
	_mmi = MultiMeshInstance2D.new()
	_mmi.multimesh = _mesh
	_mat = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	_mat.shader = shader
	_mmi.material = _mat
	_svp.add_child(_mmi)
	_dmesh = MultiMesh.new()
	_dmesh.transform_format = MultiMesh.TRANSFORM_2D
	_dmesh.use_colors = true
	_dmesh.use_custom_data = true
	_dmesh.mesh = quad
	var dmmi := MultiMeshInstance2D.new()
	dmmi.multimesh = _dmesh
	dmmi.material = _mat
	_vp.add_child(dmmi)
	var mul := CanvasItemMaterial.new()
	mul.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	mul.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	_out = Sprite2D.new()
	_out.centered = false
	_out.texture = _vp.get_texture()
	_out.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var composite := ShaderMaterial.new()
	var composite_shader := Shader.new()
	composite_shader.code = COMPOSITE_SHADER
	composite.shader = composite_shader
	_out.material = composite
	add_child(_out)
	_shade = _Shade.new()
	_shade.material = mul
	add_child(_shade)
	if offscreen:
		_out.visible = false
		_shade.visible = false

## Ambient light level from the player's darkness setting (0 = daylight, 1 = pitch black)
## and the map: space and underground maps read cool, the outdoors moonlit.
## Время суток (0.12.1): ночь — настройка игрока как есть; утро, день и вечер светлее и
## со своим оттенком. Под крышей (станция, бункер) солнце видно лишь в окна — сдвиг слабее.
const TIME_DARKNESS := {"morning": 0.45, "day": 0.0, "evening": 0.65, "night": 1.0, "": 1.0}
const TIME_TINT := {"morning": Color(1.06, 0.96, 0.9), "day": Color(1.0, 1.0, 0.98),
		"evening": Color(1.12, 0.86, 0.7), "night": Color(1, 1, 1), "": Color(1, 1, 1)}

static func ambient_for(env: String, darkness: float, time_of_day := "") -> Color:
	var k: float = TIME_DARKNESS.get(time_of_day, 1.0)
	if env in ["station", "bunker"]:
		k = lerpf(1.0, k, 0.4)
	darkness = clampf(darkness, 0.0, 1.0) * k
	var c := _ambient_base(env, darkness)
	var t: Color = TIME_TINT.get(time_of_day, Color(1, 1, 1))
	return Color(c.r * t.r, c.g * t.g, c.b * t.b).clamp()

## Без динамического света время суток всё равно видно (0.12.1): ровный оттенок поля —
## мягче, чем настоящее освещение, чтобы карта оставалась читаемой.
static func source_on(source: Dictionary, time_of_day: String) -> bool:
	return time_of_day != "day" or str(source.get("id", "")) not in ["streetlight", "bollard_light"]

static func flat_tint(env: String, time_of_day: String) -> Color:
	match time_of_day:
		"morning": return Color(1.0, 0.95, 0.9)
		"evening": return Color(1.0, 0.86, 0.74)
		"night": return Color(0.66, 0.7, 0.82) if env in ["town", "field"] else Color(0.78, 0.8, 0.86)
	return Color.WHITE

static func _ambient_base(env: String, darkness: float) -> Color:
	var v := lerpf(AMBIENT_BRIGHT, AMBIENT_DARK, clampf(darkness, 0.0, 1.0))
	match env:
		"town", "field":
			# Open sky: moonlight lifts unlit ground so gaps between lamps read as night,
			# not as stains.
			var m := minf(1.0, v * 1.55)
			return Color(m * 0.9, m * 0.95, m * 1.08).clamp()
		"bunker":
			return Color(v * 1.02, v * 0.98, v * 0.92).clamp()
	return Color(v * 0.95, v * 0.98, v * 1.04).clamp()

func update_view(grid: Grid, pan: Vector2, zoom: float, origin: Vector2, cell_size: float,
		env: String = "", visible_cells: Dictionary = {}, limited: bool = false,
		fx: FxDecals = null, after_layer: Node = null, darkness: float = -1.0, time_of_day := "") -> void:
	if _vp == null or grid == null: return
	if after_layer != null and is_instance_valid(after_layer) and after_layer.get_parent() == get_parent() \
			and get_index() < after_layer.get_index():
		get_parent().move_child(self, after_layer.get_index())
	position = pan
	scale = Vector2(zoom, zoom)
	_cell = cell_size
	_origin = origin
	if darkness < 0.0:
		var ui := get_node_or_null("/root/Ui")
		darkness = float(ui.light_darkness) if ui != null else 0.75
	ambient = ambient_for(env, darkness, time_of_day)
	_space_env = env in ["station", "asteroid"]
	occluders.sync(grid)
	_sync_walls(grid)
	# Cells on screen (+1 for filtering), clamped to the board.
	var screen := get_viewport_rect().size
	var tl := ((Vector2.ZERO - pan) / zoom - origin) / cell_size
	var br := ((screen - pan) / zoom - origin) / cell_size
	var lo := Vector2i((Vector2(tl) / CHUNK).floor()) * CHUNK - Vector2i.ONE * CHUNK
	var hi := Vector2i((Vector2(br) / CHUNK).ceil()) * CHUNK + Vector2i.ONE * CHUNK
	var view := Rect2i(lo, hi - lo).intersection(Rect2i(0, 0, grid.width, grid.height))
	if view.size.x <= 0 or view.size.y <= 0:
		_out.visible = false
		_shade.set_view(Rect2(), Rect2(origin, Vector2(grid.width, grid.height) * cell_size), _outside(),
				Rect2((Vector2.ZERO - pan) / zoom, screen / zoom))
		return
	_out.visible = not offscreen
	var texels := clampi(int(cell_size * zoom / SCREEN_PX_PER_TEXEL), MIN_TEXELS, MAX_TEXELS)
	# Keep the map within a sane texture size however far out the camera is.
	while texels > MIN_TEXELS and view.size.x * view.size.y * texels * texels > 1_500_000:
		texels -= 1
	_out.position = origin + Vector2(view.position) * cell_size
	_out.scale = Vector2.ONE * cell_size / float(texels)
	_shade.set_view(Rect2(_out.position, Vector2(view.size) * cell_size),
			Rect2(origin, Vector2(grid.width, grid.height) * cell_size), _outside(),
			Rect2((Vector2.ZERO - pan) / zoom, screen / zoom))
	_render(grid, view, texels, visible_cells, limited, fx, time_of_day)

## The first-person view (fix-8) lights its board from this very map, so 3D is lit exactly
## like the battle screen: the cells `view` at `texels` per cell, with no screen around it.
## Read the texture at (cell - view.position) / view.size; it is ready next frame.
func render_area(grid: Grid, view: Rect2i, texels: int, env: String, visible_cells: Dictionary,
		limited: bool, fx: FxDecals, time_of_day: String, darkness: float = -1.0) -> Texture2D:
	if _vp == null or grid == null: return null
	if darkness < 0.0:
		var ui := get_node_or_null("/root/Ui")
		darkness = float(ui.light_darkness) if ui != null else 0.75
	ambient = ambient_for(env, darkness, time_of_day)
	_space_env = env in ["station", "asteroid"]
	occluders.sync(grid)
	_sync_walls(grid)
	view = view.intersection(Rect2i(0, 0, grid.width, grid.height))
	if view.size.x > 0 and view.size.y > 0:
		_render(grid, view, texels, visible_cells, limited, fx, time_of_day)
	return _vp.get_texture()

func _render(grid: Grid, view: Rect2i, texels: int, visible_cells: Dictionary, limited: bool,
		fx: FxDecals, time_of_day: String) -> void:
	# Lights: static ones from the index (rebuilt only when the view's reach, the index or
	# — under fog — the sight counters change), plus flashes and muzzle fire from effects.
	var reach := view.grow(int(MAX_RANGE))
	var skey := [reach, occluders.revision, time_of_day]
	if skey != _static_key:
		_static_key = skey
		_static = []
		_fires = []
		for c: Vector2i in occluders.sources:
			if not reach.has_point(c): continue
			for src: Dictionary in occluders.sources[c]:
				if not source_on(src, time_of_day):
					continue
				var entry := [Vector2(c) + Vector2.ONE * 0.5 + Vector2(src.offset), minf(float(src.range), MAX_RANGE),
						float(src.energy), src.color]
				if src.kind == "fire": _fires.append([c, entry])
				else: _static.append(entry)
	var lights := 0
	var dynamic: Array = []
	for f: Array in _fires:
		# Fire on a cell the viewer cannot see would give the burning away.
		if not limited or visible_cells.has(f[0]):
			var cell: Vector2i = f[0]
			var fire: Array = f[1].duplicate()
			if flicker:
				fire[2] = float(fire[2]) * (0.9 + 0.1 * sin(Time.get_ticks_msec() * 0.009 + cell.x * 1.7 + cell.y * 2.3))
			dynamic.append(fire)
	for l: Array in extra_lights:
		if reach.has_point(Vector2i((l[0] as Vector2).floor())):
			dynamic.append(l)
	if fx != null:
		for flash: Dictionary in fx.flashes:
			var a := FxDecals.flash_alpha(flash)
			if a <= 0.0: continue
			for c: Vector2i in flash.cells:
				if limited and not visible_cells.has(c): continue
				if not reach.has_point(c): continue
				dynamic.append([Vector2(c) + Vector2.ONE * 0.5, 4.0, 1.6 * a, Color(1.0, 0.7, 0.35)])
		for lane: Dictionary in fx.lanes:
			if lane.get("hold", false): continue   # previewed before the shot: no flash yet
			var e := maxf(0.0, 1.0 - float(lane.t) / 0.12)
			if e <= 0.0: continue
			var from := Vector2(lane.from)
			if limited and not visible_cells.has(Vector2i(from.floor())): continue
			dynamic.append([from, 2.5, 1.2 * e, Color(1.0, 0.85, 0.5)])
	var key := [view, texels, skey, _walls_key, ambient, hash(dynamic) if not dynamic.is_empty() else 0]
	if key == _key: return
	_key = key
	var size := view.size * texels
	if _vp.size != size:
		_vp.size = size
		_svp.size = size
	# Static map: only for a new view, texel density, lamp index, wall mask or ambient.
	var t := float(texels)
	var srender := [view, texels, skey, _walls_key, ambient]
	if srender != _static_render:
		_static_render = srender
		_base.size = Vector2(size)
		_base.color = ambient
		_space.size = Vector2(size)
		_space_mat.set_shader_parameter("walls", _walls_tex)
		_space_mat.set_shader_parameter("board", Vector2(grid.width, grid.height))
		_space_mat.set_shader_parameter("view", Vector4(view.position.x, view.position.y, view.size.x, view.size.y))
		_mat.set_shader_parameter("walls", _walls_tex)
		_mat.set_shader_parameter("board", Vector2(grid.width, grid.height))
		_mesh.instance_count = _static.size()
		for i in _static.size():
			_put(_mesh, i, _static[i], view, t)
		_svp.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Dynamic pass: the cached map copied 1:1, the few flickering lights added on top.
	if dynamic.size() > _dmesh.instance_count:
		_dmesh.instance_count = maxi(64, dynamic.size() * 2)
	for i in dynamic.size():
		_put(_dmesh, i, dynamic[i], view, t)
	_dmesh.visible_instance_count = dynamic.size()
	lights = _static.size() + dynamic.size()
	last_instances = lights
	redraws += 1
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE

func _put(mesh: MultiMesh, i: int, l: Array, view: Rect2i, t: float) -> void:
	var at: Vector2 = l[0]
	var radius: float = l[1]
	mesh.set_instance_transform_2d(i, Transform2D(0.0, Vector2(radius, radius) * t, 0.0,
			(at - Vector2(view.position)) * t))
	mesh.set_instance_custom_data(i, Color(at.x, at.y, radius, l[2]))
	mesh.set_instance_color(i, l[3])

## Space backdrops (stars) are never darkened; grass and soil share the ambient.
func _outside() -> Color:
	return Color.WHITE if _space_env else ambient

## The wall mask: one RG8 texel per cell — red 255 where light stops, green 255 for space. Rebuilt in full only for
## a new board; otherwise exactly the cells the look journal reported.
func _sync_walls(grid: Grid) -> void:
	var wkey := [grid.get_instance_id(), grid.width, grid.height]
	if _walls_img == null or wkey != _walls_key.slice(0, 3) or occluders.full_sync:
		var data := PackedByteArray()
		data.resize(grid.width * grid.height * 2)
		for i: int in occluders.shapes: data[i * 2] = 255
		var cells := grid.cells_flat()
		for i in cells.size():
			if cells[i].is_space: data[i * 2 + 1] = 255
		_walls_img = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_RG8, data)
		_walls_tex = ImageTexture.create_from_image(_walls_img)
		_walls_key = wkey + [occluders.revision]
		return
	if occluders.changed.is_empty(): return
	for c: Vector2i in occluders.changed:
		_walls_img.set_pixel(c.x, c.y, Color(1.0 if occluders.shapes.has(c.y * grid.width + c.x) else 0.0,
				1.0 if grid.cell(c).is_space else 0.0, 0.0))
	_walls_tex.update(_walls_img)
	_walls_key = wkey + [occluders.revision]

## Ambient around the light map: the rest of the screen (backdrop and off-screen board) is
## multiplied by the same ambient level so the edge of the light map never shows.
class _Shade extends Node2D:
	var lit := Rect2()
	var colour := Color.WHITE
	var view := Rect2()
	func set_view(p_lit: Rect2, _board: Rect2, p_colour: Color, p_view: Rect2) -> void:
		if p_lit == lit and p_colour == colour and p_view == view: return
		lit = p_lit
		colour = p_colour
		view = p_view
		queue_redraw()
	func _draw() -> void:
		var v := view.grow(64.0)
		if lit.size == Vector2.ZERO:
			draw_rect(v, colour)
			return
		# Four bands around the lit rectangle.
		draw_rect(Rect2(v.position, Vector2(v.size.x, maxf(0.0, lit.position.y - v.position.y))), colour)
		draw_rect(Rect2(Vector2(v.position.x, lit.end.y), Vector2(v.size.x, maxf(0.0, v.end.y - lit.end.y))), colour)
		draw_rect(Rect2(Vector2(v.position.x, lit.position.y), Vector2(maxf(0.0, lit.position.x - v.position.x), lit.size.y)), colour)
		draw_rect(Rect2(Vector2(lit.end.x, lit.position.y), Vector2(maxf(0.0, v.end.x - lit.end.x), lit.size.y)), colour)
