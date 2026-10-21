class_name FirstPerson
extends Control

## First-person walk through the board (fix-7 #9, owner's answers 2026-10-21). A free look:
## private, costs nothing, available at any time, and live — soldiers move around you while
## turns resolve. Only what your side has seen can be walked; never-seen cells are black,
## remembered ones dimmed. WASD moves, the mouse looks, Space jumps, X walks through
## everything (but never into the unknown), Esc leaves. Nothing here touches the game state.

signal left

const EYE := 1.62          # eye height of a 1.7 m soldier
const RADIUS := 0.25
const SPEED := 3.6         # m/s
const STEP := 0.36         # climbs onto anything this low without jumping
const GRAVITY := 15.0
const JUMP_V := 5.2        # about 0.9 m: onto a crate, a table or a sandbag wall
const VIEW_R := 36         # metres of board kept built around you
const BUILDS_PER_FRAME := 4
const SHADOW_LIGHTS := 4   # nearest lamps that cast shadows (each one is a cube render)
const LIGHT_R := 30.0      # lamps farther than this switch off
const FIRE_LIGHTS := 8
const UNIT_H := 1.7
const UNIT_W := 0.55
const DRONE := 0.4
const VEHICLE_H := 2.0

var main: Node
var state: GameState
var grid: Grid             # the board as this viewer is shown it (fog memory under fog)
var env := "town"
var viewer := 0
var pos := Vector3.ZERO    # feet
var vel_y := 0.0
var yaw := 0.0
var pitch := 0.0
var noclip := false
var on_ground := true
## Zero-g over open space (owner): what you push stays pushed. Metres per second.
var drift := Vector3.ZERO
const THRUST := 2.2        # m/s² from the suit's jets
const SPACE_FLOOR := 0.0   # never below the station's deck (owner)
const SPACE_CEIL := 6.0
var _walked := 0.0
var _last_cell := Vector2i(-1, -1)

var _vp: SubViewport
var _world: Node3D
var _cam: Camera3D
var _board_node: Node3D
var _dyn: Node3D
var _roof: PackedByteArray
var _vis_img: Image
var _vis_tex: ImageTexture
var _vis_key: Array = []
var _vis_prev: Array[Vector2i] = []
var _vis_timer := 0.0
var _chunks := {}          # 3D chunk -> {"node", "lights": [OmniLight3D], "doors", "tiles": {tcc: tex}}
var _tile := {}            # TerrainTiles chunk -> {"floor": tex, "feat": tex, "feat_img", "w", "h"}
var _mats := {"floor": {}, "feat": {}}
var _door_open := {}       # cell -> 0..1, opened in this view only
var _units := {}           # unit id -> Node3D
var _vehicles := {}
var _side_mats := {}
var _fire_mm: MultiMeshInstance3D
var _gas_mm: MultiMeshInstance3D
var _smoke_mm: MultiMeshInstance3D
var _corpse_mm: MultiMeshInstance3D
var _fire_lights: Array[OmniLight3D] = []
var _flash_lights: Array[OmniLight3D] = []
var _cloud_timer := 0.0
var _light_timer := 0.0
var _minimap: Control
var _ground_tex: Texture2D
var _art_mats := {}

## Station and bunker keep their brighter lamp-lit look; buildings on open maps are softer.
func _lit_inside() -> bool:
	return env in ["station", "bunker"]
var _repeat_sh: Shader
## The board shader with its texture repeating (walls lay a 1 m picture along their length).
func _repeat_shader() -> Shader:
	if _repeat_sh == null:
		_repeat_sh = Shader.new()
		_repeat_sh.code = FirstPersonBoard.SHADER.replace("uniform sampler2D tex : source_color, filter_nearest;",
				"uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;")
	return _repeat_sh

static func walkable_start(m: Node, c: Vector2i) -> bool:
	var g: Grid = m.state.grid
	if not g.in_bounds(c):
		return false
	var cell := g.cell(c)
	return not cell.is_space and cell.cover_height < MCF.WALL_HEIGHT and cell.occupant == null \
			and cell.vehicle_id == -1 and m._view_resolver().team_knows(m._viewing_side(), c)

func _init(p_main: Node, start: Vector2i) -> void:
	main = p_main
	state = main.state
	grid = main._tiles._grid if main._tiles != null else state.grid
	env = state.env
	viewer = main._viewing_side()
	pos = Vector3(start.x + 0.5, 0.0, start.y + 0.5)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL

func _ready() -> void:
	var box := SubViewportContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.stretch = true
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	box.add_child(_vp)
	_world = Node3D.new()
	_vp.add_child(_world)
	_board_node = Node3D.new()
	_world.add_child(_board_node)
	_dyn = Node3D.new()
	_world.add_child(_dyn)
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = 400.0
	_world.add_child(_cam)
	_roof = main._fp_roof(grid, env)
	_vis_img = Image.create(grid.width, grid.height, false, Image.FORMAT_R8)
	_vis_tex = ImageTexture.create_from_image(_vis_img)
	_sync_vis(true)
	_build_materials()
	_build_environment()
	_build_dynamic()
	_minimap = Minimap.new(self)
	add_child(_minimap)
	var cross := Crosshair.new()
	cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cross)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	grab_focus()
	# Build the cells right around you before the first frame, so you never spawn in a void.
	for i in 6:
		_stream_chunks(64)
	_settle_feet()
	_place_camera()

func leave() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	left.emit()

# --- Input -------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var k := float(Ui.fp_sensitivity) * 0.01
		yaw -= event.relative.x * k
		pitch = clampf(pitch - event.relative.y * k, -1.5, 1.5)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ESCAPE:
				leave()
			KEY_X:
				noclip = not noclip
			KEY_SPACE:
				if (on_ground or noclip) and not _in_space(pos):
					vel_y = JUMP_V
					on_ground = false
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()

# --- Frame -------------------------------------------------------------------------------

func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	_move(delta)
	_place_camera()
	_vis_timer -= delta
	if _vis_timer <= 0.0:
		_vis_timer = 0.12
		_sync_vis(false)
	_refresh_dirty_tiles()
	_stream_chunks(BUILDS_PER_FRAME)
	_doors(delta)
	_sync_units()
	_sync_vehicles()
	_cloud_timer -= delta
	if _cloud_timer <= 0.0:
		_cloud_timer = 0.25
		_sync_clouds()
	_light_timer -= delta
	if _light_timer <= 0.0:
		_light_timer = 0.3
		_pick_lights()
	_flicker(delta)
	_sync_flashes()
	_minimap.queue_redraw()

func _place_camera() -> void:
	_cam.fov = clampf(float(Ui.fp_fov), 50.0, 120.0)
	_cam.position = pos + Vector3(0, EYE, 0)
	_cam.rotation = Vector3(pitch, yaw, 0)

# --- Movement ------------------------------------------------------------------------------

## Height of what stands in cell c, for walking: INF is a wall. The unknown is a wall even
## when walking through everything (owner: "except for fog").
func _top(c: Vector2i) -> float:
	if not grid.in_bounds(c) or _vis_img.get_pixel(c.x, c.y).r < 0.2:
		return INF
	if noclip:
		return 0.0
	var cell := grid.cell_fast(c.x, c.y)
	if cell.feature_id == MCF.FEATURE_AIRLOCK:
		return 0.0 if (cell.cover_height < MCF.WALL_HEIGHT or float(_door_open.get(c, 0.0)) > 0.8) else INF
	# Walls first: the board's boundary stands in space too, and you can't float through it.
	if cell.cover_height >= MCF.WALL_HEIGHT and not Furniture.is_furniture(cell.feature_id):
		return INF
	if cell.is_space:
		return -INF   # no floor: you float
	if state.grid.in_bounds(c) and state.grid.cell_fast(c.x, c.y).vehicle_id != -1:
		return VEHICLE_H
	if Furniture.is_furniture(cell.feature_id):
		var spec: Array = FirstPersonBoard.SHAPES.get(cell.feature_id, ["box", Furniture.height_of(cell.feature_id)])
		var hh := float(spec[1])
		return INF if hh > 1.25 else hh
	if cell.feature_id == MCF.FEATURE_TRENCH:
		return -FirstPersonBoard.TRENCH
	if cell.feature_id == "":
		return 0.0
	return cell.cover_height

## The highest top under a circle at p, or INF when any of it is a wall.
func _ground_at(p: Vector3) -> float:
	var top := -INF
	for c: Vector2i in [Vector2i(floori(p.x - RADIUS), floori(p.z - RADIUS)), Vector2i(floori(p.x + RADIUS), floori(p.z - RADIUS)),
			Vector2i(floori(p.x - RADIUS), floori(p.z + RADIUS)), Vector2i(floori(p.x + RADIUS), floori(p.z + RADIUS))]:
		top = maxf(top, _top(c))
	return top

func _blocked(p: Vector3) -> bool:
	var g := _ground_at(p)
	if g > p.y + STEP:
		return true
	# Floating below the deck, the deck's edge is a wall.
	if g > -INF and p.y < g - 0.05:
		return true
	if noclip:
		return false
	for id: int in _units:
		var n: Node3D = _units[id]
		if n.visible and Vector2(n.position.x - p.x, n.position.z - p.z).length() < RADIUS + UNIT_W * 0.5:
			return true
	return false

## Holding Space against a ledge up to 2.2 m high pulls you up onto it: out of a trench,
## onto a wall of sandbags. Units still stand in the way.
func _climb(p: Vector3) -> bool:
	if not Input.is_physical_key_pressed(KEY_SPACE):
		return false
	var g := _ground_at(p)
	if g == INF or g == -INF or g - pos.y > 2.2:
		return false
	var lifted := Vector3(p.x, g, p.z)
	if _blocked(lifted):
		return false
	pos.y = g
	vel_y = 0.0
	return true

## Over open space: no ground under any part of you.
func _in_space(p: Vector3) -> bool:
	return _ground_at(p) == -INF

func _move(delta: float) -> void:
	if _in_space(pos) and not noclip:
		_float(delta)
		return
	drift = Vector3.ZERO
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): dir.z -= 1
	if Input.is_physical_key_pressed(KEY_S): dir.z += 1
	if Input.is_physical_key_pressed(KEY_A): dir.x -= 1
	if Input.is_physical_key_pressed(KEY_D): dir.x += 1
	var step := Vector3.ZERO
	if dir != Vector3.ZERO:
		step = dir.normalized().rotated(Vector3.UP, yaw) * SPEED * delta
	var moved := 0.0
	if step.x != 0.0:
		var p := pos + Vector3(step.x, 0, 0)
		if not _blocked(p) or _climb(p):
			pos.x = p.x
			moved += absf(step.x)
	if step.z != 0.0:
		var p2 := pos + Vector3(0, 0, step.z)
		if not _blocked(p2) or _climb(p2):
			pos.z = p2.z
			moved += absf(step.z)
	# Stepping off the deck into space keeps your walking speed: you drift on.
	if _in_space(pos) and not noclip:
		drift = step / maxf(delta, 0.0001) + Vector3(0, vel_y, 0)
		return
	# Gravity, steps and jumps.
	var ground := _ground_at(pos)
	if ground == INF or ground == -INF:
		ground = pos.y
	vel_y -= GRAVITY * delta
	pos.y += vel_y * delta
	if pos.y <= ground:
		if ground - pos.y <= STEP or vel_y <= 0.0:
			pos.y = ground
		vel_y = 0.0
		on_ground = true
	else:
		on_ground = false
	if _roofed_at(pos) and pos.y + EYE > FirstPersonBoard.CEIL - 0.08:
		pos.y = FirstPersonBoard.CEIL - 0.08 - EYE
		vel_y = minf(vel_y, 0.0)
	# Footsteps: one every 0.8 m on the ground, heard where you stand.
	if on_ground and moved > 0.0:
		_walked += moved
		if _walked >= 0.8:
			_walked = 0.0
			_footstep()
	var here := Vector2i(floori(pos.x), floori(pos.z))
	if here != _last_cell:
		_last_cell = here
		if state.grid.in_bounds(here):
			main._center_on_cell(here, true)   # the battle's sounds are placed around you

func _settle_feet() -> void:
	var g := _ground_at(pos)
	pos.y = 0.0 if g == INF or g == -INF else g

## Zero-g: jets push along where you look (Space pushes up), nothing slows you down, and
## a wall or hull you hit stops the part of your motion that went into it.
func _float(delta: float) -> void:
	var push := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): push.z -= 1
	if Input.is_physical_key_pressed(KEY_S): push.z += 1
	if Input.is_physical_key_pressed(KEY_A): push.x -= 1
	if Input.is_physical_key_pressed(KEY_D): push.x += 1
	if Input.is_physical_key_pressed(KEY_SPACE): push.y += 1
	if push != Vector3.ZERO:
		drift += (_cam.global_transform.basis * push.normalized()) * THRUST * delta
	for axis in 3:
		var p := pos
		p[axis] += drift[axis] * delta
		if axis == 1 and (p.y < SPACE_FLOOR or p.y > SPACE_CEIL):
			drift.y = 0.0
			continue
		# The edge of the board holds you: nobody drifts off for good (owner).
		if axis != 1 and (p[axis] < 0.3 or p[axis] > (grid.width if axis == 0 else grid.height) - 0.3):
			drift[axis] = 0.0
			continue
		if _blocked(p) or (axis == 1 and not _in_space(p) and p.y < _ground_at(p)):
			drift[axis] = 0.0
			continue
		pos = p
	on_ground = false
	# Drifting back over a deck: its gravity takes you down onto it.
	if not _in_space(pos):
		vel_y = drift.y
		drift = Vector3.ZERO

func _roofed_at(p: Vector3) -> bool:
	var c := Vector2i(floori(p.x), floori(p.z))
	return grid.in_bounds(c) and _roof[c.y * grid.width + c.x] == 1

func _footstep() -> void:
	var a = main._audio
	if a == null or not state.grid.in_bounds(_last_cell):
		return
	a.cue(a.STEP.get(a._material(state, _last_cell), "step_concrete"), _last_cell, viewer)

# --- Visibility ---------------------------------------------------------------------------

## 0 never seen, 128 remembered, 255 in sight — one pixel per cell, read by every board
## material. Only the cells that went in or out of sight are rewritten.
func _sync_vis(full: bool) -> void:
	var r: GameActionResolver = main._view_resolver()
	var limited := r.visibility_limited()
	var key := [UnitInstance.vision_epoch, GridCell.vision_version, main._walk_cells.hash(), limited, r.fog_enabled]
	if not full and key == _vis_key:
		return
	_vis_key = key
	var w := grid.width
	if not limited:
		if full or _vis_prev.size() != -1:
			_vis_img.fill(Color(1, 1, 1))
			_vis_prev = []
		_vis_tex.update(_vis_img)
		return
	var visible: Dictionary = main._visible_before_impact(viewer)
	if full:
		_vis_img.fill(Color(0, 0, 0))
		var explored: Dictionary = r.explored.get(viewer, {}) if r.fog_enabled else {}
		for c: Vector2i in explored:
			if c.x < w and c.y < grid.height:
				_vis_img.set_pixel(c.x, c.y, Color(0.5, 0, 0))
	for c: Vector2i in _vis_prev:
		if not visible.has(c):
			_vis_img.set_pixel(c.x, c.y, Color(0.5, 0, 0) if r.fog_enabled else Color(0, 0, 0))
	_vis_prev = []
	for c: Vector2i in visible:
		_vis_img.set_pixel(c.x, c.y, Color(1, 0, 0))
		_vis_prev.append(c)
	_vis_tex.update(_vis_img)

func _seen(c: Vector2i) -> bool:
	return grid.in_bounds(c) and _vis_img.get_pixel(c.x, c.y).r > 0.75

# --- Materials, sky and light ---------------------------------------------------------------

func _build_materials() -> void:
	var board := Vector2(grid.width, grid.height)
	_ground_tex = GroundBackdrop.wallpaper(env)
	_mats["ceiling"] = FirstPersonBoard.material(_vis_tex, board, _panel_texture(env), 0.0, Color.WHITE, 0.7)
	_mats["roof"] = FirstPersonBoard.material(_vis_tex, board, _roof_texture(env), 0.0, Color.WHITE, 0.95)
	var glass := FirstPersonBoard.material(_vis_tex, board, null, 0.0, Color(0.62, 0.8, 0.9, 1.0), 0.08)
	var gsh := glass.shader.code.replace("render_mode cull_back, depth_draw_opaque;", "render_mode cull_disabled, blend_mix, depth_draw_opaque;")
	gsh = gsh.replace("ALBEDO = c.rgb * k;", "ALBEDO = c.rgb * k; ALPHA = 0.32;")
	var gs := Shader.new()
	gs.code = gsh
	glass.shader = gs
	glass.set_shader_parameter("vis", _vis_tex)
	glass.set_shader_parameter("board", board)
	glass.set_shader_parameter("textured", false)
	glass.set_shader_parameter("tint", Color(0.62, 0.8, 0.9))
	glass.set_shader_parameter("rough", 0.08)
	_mats["glass"] = glass
	_mats["glow"] = FirstPersonBoard.material(_vis_tex, board, null, 0.0, Color(1.0, 0.94, 0.82), 0.3, 2.6)
	_mats["env"] = env
	_mats["wall_mat"] = func(kind: String, accent: Color) -> Material:
		var key := "wall|%s|%s" % [kind, accent.to_html()]
		if not _art_mats.has(key):
			var m := FirstPersonBoard.material(_vis_tex, board, FirstPersonArt.wall_texture(kind, accent), 0.0,
					Color.WHITE, 0.92 if kind in ["brick", "stucco", "block", "soil", "rock", "sandbag"] else 0.6,
					0.9 if kind == "ldf" else 0.0)
			# The texture is a metre wide: let it repeat along the wall.
			m.shader = _repeat_shader()
			m.set_shader_parameter("tex", FirstPersonArt.wall_texture(kind, accent))
			_art_mats[key] = m
		return _art_mats[key]
	_mats["door_mat"] = func(style: String, accent: Color) -> Material:
		var key := "door|%s|%s" % [style, accent.to_html()]
		if not _art_mats.has(key):
			_art_mats[key] = FirstPersonBoard.material(_vis_tex, board, FirstPersonArt.door_texture(style, accent),
					0.0, Color.WHITE, 0.5 if style == "metal" else 0.85)
		return _art_mats[key]

## A tile chunk's textures, baked by the battle screen; built here if it never was.
func _tile_chunk(tcc: Vector2i) -> Dictionary:
	var tiles: TerrainTiles = main._tiles
	var key := Vector3i(tcc.x, tcc.y, FirstPersonBoard.RES)
	if tiles._dirty.has(tcc):
		tiles._dirty.erase(tcc)
		for r: int in TerrainTiles.RES:
			tiles._drop(Vector3i(tcc.x, tcc.y, r))
	if not tiles._chunks.has(key):
		tiles._build(tcc, FirstPersonBoard.RES)
	var ch: Dictionary = tiles._chunks[key]
	var known: Dictionary = _tile.get(tcc, {})
	if known.is_empty() or known["floor"] != ch["floor"]:
		var board := Vector2(grid.width, grid.height)
		known = {"floor": ch["floor"], "feat": ch["feat"], "feat_img": (ch["feat"] as ImageTexture).get_image(),
				"w": mini(TerrainTiles.C, grid.width - tcc.x * TerrainTiles.C),
				"h": mini(TerrainTiles.C, grid.height - tcc.y * TerrainTiles.C)}
		_tile[tcc] = known
		var fm := FirstPersonBoard.material(_vis_tex, board, ch["floor"], 0.0, Color.WHITE, 0.9)
		if _ground_tex != null:
			fm.set_shader_parameter("ground", _ground_tex)
			fm.set_shader_parameter("has_ground", true)
		_mats["floor"][tcc] = fm
		_mats["feat"][tcc] = FirstPersonBoard.material(_vis_tex, board, ch["feat"], 0.5, Color.WHITE, 0.8)
	return known

func _build_environment() -> void:
	var e := Environment.new()
	var tod: String = state.time_of_day
	var amb := LightManager.ambient_for(env, float(Ui.light_darkness), tod)
	var night := tod == "night"
	var dusk := tod in ["morning", "evening"]
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = amb if not night else Color(0.32, 0.38, 0.6)
	# Lamps, fire and the sun do the lighting; ambient only keeps shadows from going black.
	e.ambient_light_energy = 0.12 if night else (0.38 if dusk else 0.5)
	if _lit_inside():
		# Indoors under the station's own lighting, whatever the hour (owner liked it as it was).
		e.ambient_light_color = amb.lerp(Color(0.5, 0.5, 0.55), 0.15)
		e.ambient_light_energy = 0.9
		e.tonemap_exposure = 1.1
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.0
	e.glow_enabled = true
	e.glow_intensity = 0.55
	e.glow_hdr_threshold = 1.1
	e.glow_bloom = 0.0
	if _lit_inside():
		e.glow_intensity = 0.7
		e.glow_hdr_threshold = 1.0
		e.glow_bloom = 0.08
	match env:
		"town", "field":
			var sky := Sky.new()
			var pm := ProceduralSkyMaterial.new()
			pm.sky_top_color = Color(0.005, 0.007, 0.018) if night else (Color(0.32, 0.42, 0.66) if dusk else Color(0.28, 0.48, 0.82))
			pm.sky_horizon_color = Color(0.02, 0.025, 0.045) if night else (Color(0.95, 0.66, 0.45) if dusk else Color(0.68, 0.78, 0.9))
			pm.sky_energy_multiplier = 0.4 if night else 1.0
			pm.ground_bottom_color = Color(0.1, 0.1, 0.1)
			pm.ground_horizon_color = pm.sky_horizon_color
			sky.sky_material = pm
			e.background_mode = Environment.BG_SKY
			e.sky = sky
			e.fog_enabled = true
			e.fog_light_color = pm.sky_horizon_color
			e.fog_density = 0.006
			e.fog_density = 0.012 if night else 0.006
			# Day sun, low warm sun, or a faint moon.
			_sun(Color(1.0, 0.95, 0.85) if not (night or dusk) else (Color(1.0, 0.72, 0.5) if dusk else Color(0.5, 0.58, 0.85)),
					0.82 if not (night or dusk) else (0.6 if dusk else 0.07), -50.0 if not dusk else -18.0)
		"asteroid":
			var sky2 := Sky.new()
			var stars := PanoramaSkyMaterial.new()
			stars.panorama = _star_texture()
			sky2.sky_material = stars
			e.background_mode = Environment.BG_SKY
			e.sky = sky2
			_sun(Color(1, 1, 1), 1.3, -35.0)
		_:
			e.background_mode = Environment.BG_COLOR
			e.background_color = Color(0.01, 0.01, 0.015)
			var sky3 := Sky.new()
			var stars3 := PanoramaSkyMaterial.new()
			stars3.panorama = _star_texture()
			sky3.sky_material = stars3
			if env == "station":
				e.background_mode = Environment.BG_SKY
				e.sky = sky3
	var we := WorldEnvironment.new()
	we.environment = e
	_world.add_child(we)

func _sun(col: Color, energy: float, elev: float) -> void:
	var sun := DirectionalLight3D.new()
	sun.light_color = col
	sun.light_energy = energy
	sun.rotation_degrees = Vector3(elev, 35.0, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	sun.shadow_blur = 1.5
	_world.add_child(sun)

static func _star_texture() -> ImageTexture:
	var img := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	img.fill(Color(0.004, 0.004, 0.01))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in 3500:
		var b := pow(rng.randf(), 3.0)
		var tint := Color(0.85 + rng.randf() * 0.15, 0.85 + rng.randf() * 0.15, 1.0)
		img.set_pixel(rng.randi_range(0, 2047), rng.randi_range(0, 1023), tint * (0.25 + b * 0.75))
	return ImageTexture.create_from_image(img)

## Ceiling panels (station, bunker, asteroid domes) or plaster (town, field houses).
static func _panel_texture(e: String) -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var metal := e in ["station", "bunker", "asteroid"]
	for y in 32:
		for x in 32:
			var seam := x % 16 == 0 or y % 16 == 0
			var n := fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0) * 0.04
			var base := Color(0.36, 0.38, 0.41) if metal else Color(0.56, 0.54, 0.51)
			img.set_pixel(x, y, (base * (0.72 if seam else 1.0 + n)) if metal else base * (0.97 + n))
	return ImageTexture.create_from_image(img)

static func _roof_texture(e: String) -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	for y in 32:
		for x in 32:
			var n := fposmod(sin(x * 7.13 + y * 3.71) * 9187.31, 1.0) * 0.08
			var row := (y % 8 == 0)
			var base := Color(0.32, 0.33, 0.35) if e in ["station", "bunker", "asteroid"] else Color(0.36, 0.22, 0.18)
			img.set_pixel(x, y, base * (0.75 if row else 0.95 + n))
	return ImageTexture.create_from_image(img)

# --- The board, streamed around you ---------------------------------------------------------

func _stream_chunks(budget: int) -> void:
	var here := Vector2i(floori(pos.x) / FirstPersonBoard.CH, floori(pos.z) / FirstPersonBoard.CH)
	var reach := VIEW_R / FirstPersonBoard.CH + 1
	var want: Array = []
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var cc := here + Vector2i(dx, dy)
			if cc.x < 0 or cc.y < 0 or cc.x * FirstPersonBoard.CH >= grid.width or cc.y * FirstPersonBoard.CH >= grid.height:
				continue
			if not _chunks.has(cc):
				want.append(cc)
	want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.distance_squared_to(here) < b.distance_squared_to(here))
	for cc: Vector2i in want.slice(0, budget):
		_build_chunk(cc)
	# Far chunks go; they come back when you do.
	for cc: Vector2i in _chunks.keys():
		if maxi(absi(cc.x - here.x), absi(cc.y - here.y)) > reach + 2:
			_drop_chunk(cc)

func _build_chunk(cc: Vector2i) -> void:
	_drop_chunk(cc)
	var tiles := {}
	var ch := FirstPersonBoard.CH
	for ty in range(cc.y * ch / TerrainTiles.C, (cc.y * ch + ch - 1) / TerrainTiles.C + 1):
		for tx in range(cc.x * ch / TerrainTiles.C, (cc.x * ch + ch - 1) / TerrainTiles.C + 1):
			var tcc := Vector2i(tx, ty)
			if tx * TerrainTiles.C < grid.width and ty * TerrainTiles.C < grid.height:
				tiles[tcc] = _tile_chunk(tcc)
	var built := FirstPersonBoard.build(grid, cc, _roof, _mats, tiles)
	var node: Node3D = built["node"]
	_board_node.add_child(node)
	var lights: Array[Light3D] = []
	for l: Array in built["lights"]:
		var o: Light3D
		if l.size() > 4 and l[4] == "spot":
			# A streetlight throws its pool of light down onto the road.
			var sp := SpotLight3D.new()
			sp.rotation_degrees = Vector3(-90, 0, 0)
			sp.spot_range = float(l[2])
			sp.spot_angle = 58.0
			sp.spot_angle_attenuation = 0.8
			o = sp
		else:
			var om := OmniLight3D.new()
			om.omni_range = float(l[2])
			om.omni_attenuation = 1.4 if _lit_inside() else 1.8
			o = om
		o.position = l[0]
		o.light_color = l[1]
		o.light_energy = float(l[3]) * (0.9 if o is SpotLight3D else (1.6 if _lit_inside() else 0.3))
		o.light_size = 0.15
		o.shadow_bias = 0.08
		node.add_child(o)
		lights.append(o)
	for b: Array in built["bills"]:
		_foliage(node, b, tiles)
	_map_decals(node, cc)
	var stamps := {}
	for tcc: Vector2i in tiles:
		stamps[tcc] = tiles[tcc]["floor"]
	_chunks[cc] = {"node": node, "lights": lights, "doors": built["doors"], "tiles": stamps}

## Decals the map maker laid by hand: the battle screen draws them apart from the baked
## tiles, so here they lie on the floor as their own pictures.
func _map_decals(node: Node3D, cc: Vector2i) -> void:
	var tiles: TerrainTiles = main._tiles
	var ch := FirstPersonBoard.CH
	var area := Rect2(cc.x * ch, cc.y * ch, ch, ch)
	var tcc := Vector2i(cc.x * ch / TerrainTiles.C, cc.y * ch / TerrainTiles.C)
	for d: Dictionary in tiles.map_decals.get(tcc, []):
		var p: Vector2 = d["pos"]
		if not area.has_point(p):
			continue
		var kind := str(d["kind"])
		var art := FxDecals.texture_of_kind(kind) if kind.begins_with("item:") else str(FxDecals.TEXTURE.get(kind, ""))
		var tex := Sprites.texture_of(art) if art != "" else null
		if tex == null:
			continue
		var look: Array = FxDecals.look_of(kind)
		var sz := float(d["scale"]) * (float(look[0]) if not look.is_empty() else 0.95)
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(sz, sz)
		q.orientation = PlaneMesh.FACE_Y
		mi.mesh = q
		mi.material_override = _decal_mat(tex)
		mi.position = Vector3(p.x, 0.008, p.y)
		mi.rotation.y = -float(d["rot"])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)

var _decal_mats := {}
func _decal_mat(tex: Texture2D) -> ShaderMaterial:
	if not _decal_mats.has(tex):
		_decal_mats[tex] = FirstPersonBoard.material(_vis_tex, Vector2(grid.width, grid.height), tex, 0.5, Color.WHITE, 0.9)
	return _decal_mats[tex]

## A tree crown, a bush or a plant: its own map art standing up and facing you.
func _foliage(node: Node3D, b: Array, tiles: Dictionary) -> void:
	var at: Vector2i = b[2]
	var bb: Rect2 = b[3]
	var tile: Dictionary = tiles.get(Vector2i(at.x / TerrainTiles.C, at.y / TerrainTiles.C), {})
	if tile.is_empty():
		return
	var res := FirstPersonBoard.RES
	var src := Rect2i((at.x % TerrainTiles.C) * res + int(bb.position.x * res), (at.y % TerrainTiles.C) * res + int(bb.position.y * res),
			maxi(1, int(bb.size.x * res)), maxi(1, int(bb.size.y * res)))
	var img: Image = (tile["feat_img"] as Image).get_region(src)
	if b.size() > 4:
		img = _solid_foliage(img, b[4] == "crown")
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	var sz: Vector2 = b[1]
	q.size = sz
	q.center_offset = Vector3(0, sz.y * 0.5, 0)
	mi.mesh = q
	mi.material_override = _billboard_mat(ImageTexture.create_from_image(img))
	mi.position = b[0]
	node.add_child(mi)

## Seen from the side a crown is leaves all through (owner): the top-down art's gaps and
## the trunk showing in its middle are filled with the leaves' own colour, speckled.
static func _solid_foliage(img: Image, crown: bool) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var sum := Color(0, 0, 0)
	var n := 0
	for y in h:
		for x in w:
			var p := img.get_pixel(x, y)
			if p.a > 0.5 and p.g > p.r:
				sum += p
				n += 1
	if n == 0:
		return img
	var leaf := Color(sum.r / n, sum.g / n, sum.b / n)
	var out := img.duplicate() as Image
	var c := Vector2(w, h) * 0.5
	for y in h:
		for x in w:
			var q := (Vector2(x + 0.5, y + 0.5) - c) / c
			var p := out.get_pixel(x, y)
			var inner := q.length() < (0.86 if crown else 0.8)
			if inner and (p.a < 0.5 or p.g <= p.r):
				var grain := fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5, 1.0)
				out.set_pixel(x, y, leaf.darkened(0.08 + grain * 0.18) if grain > 0.3 else leaf.lightened(0.06))
	return out

func _drop_chunk(cc: Vector2i) -> void:
	if _chunks.has(cc):
		(_chunks[cc]["node"] as Node3D).queue_free()
		_chunks.erase(cc)

## The battle screen re-bakes a tile chunk when its cells change (a wall falls, blood
## lands, the fog memory catches up): the 3D chunks over it are rebuilt to match.
func _refresh_dirty_tiles() -> void:
	var tiles: TerrainTiles = main._tiles
	var redo := {}
	for cc: Vector2i in _chunks:
		for tcc: Vector2i in _chunks[cc]["tiles"]:
			var key := Vector3i(tcc.x, tcc.y, FirstPersonBoard.RES)
			if tiles._dirty.has(tcc) or not tiles._chunks.has(key) \
					or tiles._chunks[key]["floor"] != _chunks[cc]["tiles"][tcc]:
				redo[cc] = true
	var n := 0
	for cc: Vector2i in redo:
		if n >= BUILDS_PER_FRAME:
			break
		_build_chunk(cc)
		n += 1

## Doors open in this view only, when you walk up to them; the game's own open state
## (a soldier standing by) shows too.
func _doors(delta: float) -> void:
	for cc: Vector2i in _chunks:
		for at: Vector2i in _chunks[cc]["doors"]:
			var door: Node3D = _chunks[cc]["doors"][at]
			var cell := grid.cell_fast(at.x, at.y)
			var near := Vector2(at.x + 0.5 - pos.x, at.y + 0.5 - pos.z).length() < 1.4
			var want := 1.0 if (near or cell.cover_height < MCF.WALL_HEIGHT) and not cell.airlock_welded else 0.0
			var was := float(_door_open.get(at, 0.0))
			var now := move_toward(was, want, delta * 3.0)
			if was == 0.0 and now > 0.0 and near:
				var a = main._audio
				if a != null and state.grid.in_bounds(at): a.cue("door_open", at, viewer)
			_door_open[at] = now
			var ease := now * now * (3.0 - 2.0 * now)
			var along_x: bool = door.get_meta("along_x")
			var halves := door.get_child_count()
			for leaf: Node3D in door.get_children():
				# Into the wall beside the doorway: halves apart, a single block aside.
				var off := float(leaf.get_meta("side")) * ease * (0.5 if halves == 2 else 0.98)
				var home: Vector3 = leaf.get_meta("home")
				leaf.position = home + (Vector3(off, 0, 0) if along_x else Vector3(0, 0, off))

# --- Soldiers, bodies, vehicles, drones -------------------------------------------------------

func _build_dynamic() -> void:
	_fire_mm = _cloud_layer(Color(1.0, 0.45, 0.08), true)
	_gas_mm = _cloud_layer(Color(0.74, 0.88, 0.3, 0.4), false)
	_smoke_mm = _cloud_layer(Color(0.62, 0.62, 0.64, 0.5), false)
	var cmm := MultiMesh.new()
	cmm.transform_format = MultiMesh.TRANSFORM_3D
	var cq := QuadMesh.new()
	cq.size = Vector2(UNIT_W, UNIT_H)
	cq.orientation = PlaneMesh.FACE_Y
	cmm.mesh = cq
	_corpse_mm = MultiMeshInstance3D.new()
	_corpse_mm.multimesh = cmm
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.75, 0.05, 0.05, 0.5)
	cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_corpse_mm.material_override = cmat
	_dyn.add_child(_corpse_mm)
	for i in FIRE_LIGHTS:
		var o := OmniLight3D.new()
		o.light_color = Color(1.0, 0.55, 0.2)
		o.omni_range = 5.0
		o.visible = false
		_dyn.add_child(o)
		_fire_lights.append(o)
	for i in 4:
		var f := OmniLight3D.new()
		f.light_color = Color(1.0, 0.75, 0.4)
		f.omni_range = 9.0
		f.visible = false
		_dyn.add_child(f)
		_flash_lights.append(f)

func _cloud_layer(col: Color, fire: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var bm := BoxMesh.new()
	bm.size = Vector3(1, 0.5, 1) if fire else Vector3(1, 1, 1)
	mm.mesh = bm
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	if fire:
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 2.4
		mat.albedo_color = Color(1.0, 0.6, 0.15, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if fire else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dyn.add_child(mi)
	return mi

func _side_mat(side: int) -> StandardMaterial3D:
	if not _side_mats.has(side):
		var m := StandardMaterial3D.new()
		m.albedo_color = main._side_color(side)
		m.roughness = 0.7
		_side_mats[side] = m
	return _side_mats[side]

## A soldier: a flat 1.7 m cut-out in its side's colour that always turns to face you, its
## class tag drawn on it in pixels (owner: 2D rectangles, like a 2.5D shooter's sprites).
func _unit_node(u: UnitInstance) -> Node3D:
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.62, UNIT_H)
	q.center_offset = Vector3(0, UNIT_H * 0.5, 0)
	mi.mesh = q
	mi.material_override = _billboard_mat(_soldier_texture(main._side_color(u.owner),
			Sprites.unit_tag(u.stats.id, u.stats.display_name)))
	n.add_child(mi)
	_dyn.add_child(n)
	return n

var _bill_shader: Shader
var _bill_mats := {}
func _billboard_mat(tex: Texture2D) -> ShaderMaterial:
	if _bill_mats.has(tex):
		return _bill_mats[tex]
	if _bill_shader == null:
		_bill_shader = Shader.new()
		_bill_shader.code = FirstPersonBoard.BILLBOARD
	var m := ShaderMaterial.new()
	m.shader = _bill_shader
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("vis", _vis_tex)
	m.set_shader_parameter("board", Vector2(grid.width, grid.height))
	_bill_mats[tex] = m
	return m

var _soldier_tex := {}
## 18×48 pixels: a body with a darker rim and shading, a head, and the tag in 3×5 letters.
func _soldier_texture(col: Color, tag: String) -> ImageTexture:
	var key := "%s|%s" % [col.to_html(), tag]
	if _soldier_tex.has(key):
		return _soldier_tex[key]
	var w := 18
	var h := 48
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rim := col.darkened(0.55)
	# Head, then shoulders down to the boots.
	for y in range(0, 10):
		for x in range(5, 13):
			var edge := x == 5 or x == 12 or y == 0 or y == 9
			img.set_pixel(x, y, rim if edge else col.lightened(0.12))
	for y in range(10, h):
		var inset := 1 if y < 14 else 2
		if y > 40: inset = 3
		for x in range(inset, w - inset):
			var edge := x == inset or x == w - inset - 1 or y == 10 or y == h - 1
			var shade := col.darkened(0.12) if x > w / 2 else col
			img.set_pixel(x, y, rim if edge else shade)
	_pixel_text(img, tag, Vector2i(w / 2, 22), Color(0.05, 0.05, 0.06))
	var tex := ImageTexture.create_from_image(img)
	_soldier_tex[key] = tex
	return tex

const FONT := {
	"A": "010101111101101", "B": "110101110101110", "C": "011100100100011", "D": "110101101101110",
	"E": "111100110100111", "F": "111100110100100", "G": "011100101101011", "H": "101101111101101",
	"I": "111010010010111", "J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
	"M": "101111111101101", "N": "110101101101101", "O": "010101101101010", "P": "110101110100100",
	"Q": "010101101110011", "R": "110101110101101", "S": "011100010001110", "T": "111010010010010",
	"U": "101101101101111", "V": "101101101101010", "W": "101101111111101", "X": "101101010101101",
	"Y": "101101010010010", "Z": "111001010100111", "0": "111101101101111", "1": "010110010010111",
	"2": "110001010100111", "3": "110001010001110", "4": "101101111001001", "5": "111100110001110",
	"6": "011100110101010", "7": "111001010010010", "8": "010101010101010", "9": "010101011001110",
}
static func _pixel_text(img: Image, text: String, center: Vector2i, col: Color) -> void:
	var x0 := center.x - (text.length() * 4 - 1) / 2
	for i in text.length():
		var g: String = FONT.get(text[i].to_upper(), "")
		for k in g.length():
			if g[k] == "1":
				img.set_pixel(x0 + i * 4 + k % 3, center.y + k / 3, col)

func _unit_pos(u: UnitInstance) -> Vector3:
	var c: Vector2i = main._draw_cell(u)
	var off: Vector2 = main._walk_offset.get(u.id, Vector2.ZERO) / main.CELL
	var y := 0.0
	if grid.in_bounds(c) and grid.cell_fast(c.x, c.y).feature_id == MCF.FEATURE_TRENCH:
		y = -FirstPersonBoard.TRENCH
	return Vector3(c.x + 0.5 + off.x, y, c.y + 0.5 + off.y)

func _sync_units() -> void:
	var visible: Dictionary = main._visible_before_impact(viewer)
	var limited: bool = main._view_resolver().visibility_limited()
	var live := {}
	var corpses: Array[Transform3D] = []
	for u: UnitInstance in state.all_units():
		if u.is_drone:
			if u.is_alive() and grid.in_bounds(u.coord) and (not limited or visible.has(u.coord) or u.owner == viewer):
				live[u.id] = true
				_place_drone(u)
			continue
		if not grid.in_bounds(main._draw_cell(u)) or u.aboard_vehicle_id != -1 or u.borg_id != -1:
			continue
		var at: Vector2i = main._draw_cell(u)
		if u.status == MCF.Status.CORPSE:
			continue   # bodies come from the battle screen's own map below
		if limited and not visible.has(at) and u.owner != viewer \
				and not state.roster.are_allies(viewer, u.owner):
			continue
		live[u.id] = true
		var n: Node3D = _units.get(u.id)
		if n == null:
			n = _unit_node(u)
			_units[u.id] = n
		n.position = _unit_pos(u)
		n.visible = true
	for id: int in _units.keys():
		if not live.has(id):
			(_units[id] as Node3D).queue_free()
			_units.erase(id)
	# Bodies as the battle screen shows them: fallen soldiers and piles set down, under fog
	# as last seen. Half-transparent red, lying flat, one per body.
	for c: Vector2i in _corpses():
		var e: Array = _corpses()[c]
		for k in maxi(1, int(e[1])):
			corpses.append(Transform3D(Basis(Vector3.UP, float((c.x * 7 + c.y * 13 + k * 5) % 9) * 0.35),
					Vector3(c.x + 0.5, 0.02 + k * 0.03, c.y + 0.5)))
	var mm := _corpse_mm.multimesh
	mm.instance_count = corpses.size()
	for i in corpses.size():
		mm.set_instance_transform(i, corpses[i])

var _corpse_cache: Dictionary = {}
var _corpse_frame := -1
func _corpses() -> Dictionary:
	if _corpse_frame == Engine.get_process_frames():
		return _corpse_cache
	_corpse_frame = Engine.get_process_frames()
	var map: Dictionary = main._corpse_map()
	var r: GameActionResolver = main._view_resolver()
	if r.visibility_limited() and r.fog_enabled and main._fog_mem_corpses.has(viewer):
		map = main._fog_mem_corpses[viewer]
	elif r.visibility_limited():
		var vis: Dictionary = main._visible_before_impact(viewer)
		var only := {}
		for c: Vector2i in map:
			if vis.has(c): only[c] = map[c]
		map = only
	_corpse_cache = {}
	for c: Vector2i in map:
		if not main._pending_death_ids.has((map[c][0] as UnitInstance).id if map[c][0] is UnitInstance else -1):
			_corpse_cache[c] = map[c]
	return _corpse_cache

func _place_drone(u: UnitInstance) -> void:
	var n: Node3D = _units.get(u.id)
	if n == null:
		n = Node3D.new()
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(DRONE, DRONE, DRONE)
		mi.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = main._side_color(u.owner)
		m.emission_enabled = true
		m.emission = main._side_color(u.owner) * 0.4
		m.metallic = 0.6
		mi.material_override = m
		n.add_child(mi)
		_dyn.add_child(n)
		_units[u.id] = n
	var p := _unit_pos(u)
	# Hovering just under the ceiling; over a vehicle, above its roof.
	var y := 1.8 + DRONE * 0.5
	if state.grid.in_bounds(u.coord) and state.grid.cell(u.coord).vehicle_id != -1:
		y = VEHICLE_H + DRONE * 0.5 + 0.08
	n.position = Vector3(p.x, y + sin(Time.get_ticks_msec() * 0.003 + u.id) * 0.03, p.z)
	n.rotation.y += 0.01

func _sync_vehicles() -> void:
	var visible: Dictionary = main._visible_before_impact(viewer)
	var limited: bool = main._view_resolver().visibility_limited()
	var live := {}
	for veh: Vehicle in state.all_vehicles():
		var cells := veh.footprint()
		var seen := not limited or veh.owner == viewer
		for c: Vector2i in cells:
			if visible.has(c):
				seen = true
		if not seen or cells.is_empty():
			continue
		live[veh.id] = true
		var n: MeshInstance3D = _vehicles.get(veh.id)
		if n == null:
			n = MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(veh.size.x - 0.06, VEHICLE_H, veh.size.y - 0.06)
			n.mesh = bm
			var m := StandardMaterial3D.new()
			m.albedo_color = main._side_color(veh.owner).darkened(0.15)
			m.metallic = 0.35
			m.roughness = 0.55
			n.material_override = m
			var l := Label3D.new()
			l.text = str(VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)).to_upper()
			l.font_size = 72
			l.pixel_size = 0.006
			l.modulate = Color(0.05, 0.05, 0.05)
			l.position = Vector3(0, 0.2, (veh.size.y - 0.06) * 0.5 + 0.004)
			n.add_child(l)
			_dyn.add_child(n)
			_vehicles[veh.id] = n
		var off: Vector2 = main._veh_offset.get(veh.id, Vector2.ZERO) / main.CELL
		n.position = Vector3(veh.origin.x + veh.size.x * 0.5 + off.x, VEHICLE_H * 0.5, veh.origin.y + veh.size.y * 0.5 + off.y)
		(n.material_override as StandardMaterial3D).albedo_color = Color(0.16, 0.15, 0.14) if veh.wrecked \
				else main._side_color(veh.owner).darkened(0.15)
	for id: int in _vehicles.keys():
		if not live.has(id):
			(_vehicles[id] as Node3D).queue_free()
			_vehicles.erase(id)

# --- Fire, gas and smoke ------------------------------------------------------------------------

func _sync_clouds() -> void:
	var here := Vector2i(floori(pos.x), floori(pos.z))
	var fire: Array[Vector2i] = []
	var gas: Array[Vector2i] = []
	var smoke: Array[Vector2i] = []
	var r := VIEW_R
	for y in range(maxi(0, here.y - r), mini(grid.height, here.y + r + 1)):
		for x in range(maxi(0, here.x - r), mini(grid.width, here.x + r + 1)):
			var c := state.grid.cell_fast(x, y)
			if not (c.on_fire or c.gas or c.smoke):
				continue
			var at := Vector2i(x, y)
			if not _seen(at):
				continue
			if c.on_fire: fire.append(at)
			if c.gas: gas.append(at)
			elif c.smoke: smoke.append(at)
	_fill(_fire_mm, fire, 0.25, 1.0)
	_fill(_gas_mm, gas, FirstPersonBoard.CEIL * 0.5, FirstPersonBoard.CEIL)
	_fill(_smoke_mm, smoke, FirstPersonBoard.CEIL * 0.5, FirstPersonBoard.CEIL)
	fire.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.distance_squared_to(here) < b.distance_squared_to(here))
	for i in _fire_lights.size():
		var o := _fire_lights[i]
		o.visible = i < fire.size()
		if o.visible:
			o.position = Vector3(fire[i].x + 0.5, 0.7, fire[i].y + 0.5)

func _fill(mi: MultiMeshInstance3D, cells: Array[Vector2i], y: float, hgt: float) -> void:
	var mm := mi.multimesh
	mm.instance_count = cells.size()
	for i in cells.size():
		var b := Basis().scaled(Vector3(1, hgt if hgt != 1.0 else 1.0, 1)) if hgt != 1.0 else Basis()
		mm.set_instance_transform(i, Transform3D(b, Vector3(cells[i].x + 0.5, y, cells[i].y + 0.5)))

## Fire breathes: its lights and its half-cubes flicker a little.
func _flicker(_delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001
	for i in _fire_lights.size():
		var o := _fire_lights[i]
		if o.visible:
			o.light_energy = 1.6 + 0.35 * sin(t * 11.0 + i * 1.7) + 0.2 * sin(t * 23.0 + i)
	var m := _fire_mm.material_override as StandardMaterial3D
	m.emission_energy_multiplier = 2.2 + 0.4 * sin(t * 9.0)

func _sync_flashes() -> void:
	var fx: FxDecals = main._fx
	var n := 0
	for flash: Dictionary in fx.flashes:
		if n >= _flash_lights.size():
			break
		var cells: Array = flash["cells"]
		if cells.is_empty():
			continue
		var a := FxDecals.flash_alpha(flash)
		var c: Vector2i = cells[cells.size() / 2]
		var o := _flash_lights[n]
		o.position = Vector3(c.x + 0.5, 1.0, c.y + 0.5)
		o.light_energy = 6.0 * a
		o.visible = a > 0.0 and _seen(c)
		n += 1
	for i in range(n, _flash_lights.size()):
		_flash_lights[i].visible = false

## Lamps far away switch off; the few nearest cast shadows.
func _pick_lights() -> void:
	var all: Array = []
	for cc: Vector2i in _chunks:
		for o: Light3D in _chunks[cc]["lights"]:
			var d := o.position.distance_to(_cam.position)
			o.visible = d < LIGHT_R
			o.shadow_enabled = false
			if o.visible:
				all.append([d, o])
	all.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in mini(SHADOW_LIGHTS, all.size()):
		(all[i][1] as Light3D).shadow_enabled = true

# --- HUD -----------------------------------------------------------------------------------------

class Crosshair extends Control:
	func _draw() -> void:
		var c := size * 0.5
		for d: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			draw_line(c + d * 4.0, c + d * 11.0, Color(0, 0, 0, 0.6), 4.0)
			draw_line(c + d * 4.0, c + d * 11.0, Color(1, 1, 1, 0.9), 2.0)

## North-up map of the cells around you, as your side knows them, with you as an arrow.
class Minimap extends Control:
	const R := 16
	const PX := 6.0
	var fp: FirstPerson
	func _init(p: FirstPerson) -> void:
		fp = p
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_TOP_RIGHT)
		size = Vector2((R * 2 + 1) * PX, (R * 2 + 1) * PX)
		position = Vector2(-size.x - 16.0, 16.0)
	func _draw() -> void:
		var g := fp.grid
		var here := Vector2i(floori(fp.pos.x), floori(fp.pos.z))
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.65))
		for dy in range(-R, R + 1):
			for dx in range(-R, R + 1):
				var c := here + Vector2i(dx, dy)
				if not g.in_bounds(c):
					continue
				var v := fp._vis_img.get_pixel(c.x, c.y).r
				if v < 0.2:
					continue
				var cell := g.cell_fast(c.x, c.y)
				var col := Color(0.32, 0.33, 0.36)
				if cell.is_space: col = Color(0.03, 0.03, 0.06)
				elif FirstPersonBoard.is_wall(cell): col = Color(0.75, 0.76, 0.8)
				elif cell.feature_id != "": col = Color(0.52, 0.5, 0.46)
				if v < 0.75: col = col.darkened(0.55)
				draw_rect(Rect2(Vector2(dx + R, dy + R) * PX, Vector2(PX, PX)), col)
		for id: int in fp._units:
			var n: Node3D = fp._units[id]
			var u := fp.state.get_unit(id)
			if u == null: continue
			var p := (Vector2(n.position.x, n.position.z) - Vector2(here) + Vector2(R, R)) * PX
			if Rect2(Vector2.ZERO, size).has_point(p):
				draw_circle(p, PX * 0.45, fp.main._side_color(u.owner))
		var me := (Vector2(fp.pos.x, fp.pos.z) - Vector2(here) + Vector2(R, R)) * PX
		var f := Vector2(-sin(fp.yaw), -cos(fp.yaw))
		var s := Vector2(-f.y, f.x)
		draw_colored_polygon(PackedVector2Array([me + f * 9.0, me - f * 5.0 + s * 5.0, me - f * 5.0 - s * 5.0]), Color(1, 0.92, 0.3))
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.35), false, 1.0)
