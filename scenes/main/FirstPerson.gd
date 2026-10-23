class_name FirstPerson
extends Control

## First-person walk through the board (fix-7 #9, owner's answers 2026-10-21; rebuilt in
## fix-8). A free look: private, costs nothing, available at any time, and live — soldiers
## move around you while turns resolve. Only what your side has seen can be walked;
## never-seen cells are black, remembered ones dimmed. WASD moves, the mouse looks, Space
## jumps, X walks through everything (but never into the unknown), Esc leaves. Nothing here
## touches the game state.
##
## Light is the battle screen's own light map (owner, fix-8: "exactly the same as in 2D"):
## a second LightManager draws it for the cells around you and every surface reads it, so
## lights share one cached map instead of separate shadow-casting 3D lamps.
## By day outdoors the sun adds its shadows. The board streams in by chunks within a time
## budget; a chunk is rebuilt only when its cells change, and a fresh floor bake (blood,
## debris) just swaps the floor's picture.

signal left

const EYE := 1.62          # eye height of a 1.7 m soldier
const RADIUS := 0.25
const RUN_SPEED := 6.2
const STEP_DISTANCE := 1.6
const RUN_STEP_DISTANCE := 2.1
const SPEED := 3.6         # m/s
const STEP := 0.36         # climbs onto anything this low without jumping
const GRAVITY := 15.0
const JUMP_V := 5.2        # about 0.9 m: onto a crate, a table or a sandbag wall
const VIEW_R := 36         # metres of board kept built around you
const BUILD_BUDGET_USEC := 6000
const LM_TEXELS := 4       # light map texels per cell
const UNIT_H := 1.7
const UNIT_W := 0.55
const VEHICLE_H := 2.0
const SUN_K := 0.42        # how much of the daylight the sun's shadows take back

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
var _render_distance_applied := -1

var _vp: SubViewport
var _world: Node3D
var _cam: Camera3D
var _board_node: Node3D
var _dyn: Node3D
var _roof: PackedByteArray
var _vis_img: Image
var _vis_tex: ImageTexture
var _vis_spare: ImageTexture
var _vis_extra_materials: Array[ShaderMaterial] = []
var _vis_key: Array = []
var _fog_boundary: FirstPersonFog
var _environment_root: Node3D
var _environment_time := ""
var _outer_ground: MeshInstance3D
var _vis_prev: Array[Vector2i] = []
var _vis_timer := 0.0
var _solid_img: Image
var _solid_tex: ImageTexture
var _chunks := {}          # 3D chunk -> {"node", "doors", "tops", "tiles": {tcc: floor texture}}
var _chunk_jobs := {}
var _floor_tex := {}       # tile chunk -> its first-person floor texture
var _floor_jobs := {}
var _floor_refresh := {}
var _mats := {"floor": {}, "floor_cut": {}}
var _all_mats: Array[ShaderMaterial] = []
var _board_sh: Shader
var _bill_sh: Shader
var _glass_sh: Shader
var _sun_on := false
var _look_ver := -1
var _dirty := {}           # 3D chunks whose cells changed
var _door_open := {}       # cell -> 0..1, opened in this view only
var _units := {}           # unit id -> Node3D
var _vehicles := {}
var _walkers := {}
var _presence_timer := 0.0
var _features := {}        # cell -> Node3D: drone stations and mines, as this viewer sees them
var _fire_mm: MultiMeshInstance3D
var _gas_mm: MultiMeshInstance3D
var _smoke_mm: MultiMeshInstance3D
var _corpse_mm: MultiMeshInstance3D
var _cloud_timer := 0.0
var _cloud_cells := {}
var _cloud_version := -1
var _feature_timer := 0.0
var _map_timer := 0.0
var _minimap: Control
var _ground_tex: ImageTexture   # one texel a cell: which open ground lies there
var _ground_img: Image
var _art_mats := {}
var _lm: LightManager
var _lm_spare: LightManager
var _lm_pending := false
var _lm_options: Array = []
var _lm_rect := Rect2i()
var _lm_tex: Texture2D

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
	_cam.near = 0.06
	_cam.far = 700.0
	_world.add_child(_cam)
	_lm = LightManager.new()
	_lm.offscreen = true
	_lm.flicker = false
	add_child(_lm)
	_lm_spare = LightManager.new()
	_lm_spare.offscreen = true
	_lm_spare.flicker = false
	add_child(_lm_spare)
	_roof = main._fp_roof(grid, env)
	_vis_img = Image.create(grid.width, grid.height, false, Image.FORMAT_R8)
	_vis_tex = ImageTexture.create_from_image(_vis_img)
	_build_solid()
	_look_ver = GridCell.look_version
	_sync_vis(true)
	_fog_boundary = FirstPersonFog.new()
	_world.add_child(_fog_boundary)
	_fog_boundary.update_visibility(_vis_img)
	var tod: String = state.time_of_day
	_sun_on = env in ["town", "field"] and tod in ["day", "morning", "evening"]
	_build_shaders()
	_update_light(true)
	_build_materials()
	_build_environment()
	_build_dynamic()
	_sync_snow()
	_minimap = Minimap.new(self)
	add_child(_minimap)
	var cross := Crosshair.new()
	cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cross)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	grab_focus()
	# Build the cells right around you before the first frame, so you never spawn in a void.
	_stream_chunks(400000)
	_settle_feet()
	_place_camera()

func leave() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	left.emit()

func _exit_tree() -> void:
	for job: Dictionary in _chunk_jobs.values(): job.node.free()
	_chunk_jobs.clear()

# --- Input -------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var k := float(Ui.fp_sensitivity) * 0.01
		yaw -= event.relative.x * k
		pitch = clampf(pitch - event.relative.y * k, -1.5, 1.5)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if Keybinds.matches(event, "fp_leave"):
			leave()
		elif Keybinds.matches(event, "fp_noclip"):
			noclip = not noclip
			drift = Vector3.ZERO
			vel_y = 0.0
		elif event.is_action_pressed("fp_up") and on_ground and not noclip and not _in_space(pos):
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
	_presence_timer -= delta
	delta = minf(delta, 0.05)
	_move(delta)
	_sync_snow()
	_place_camera()
	_vis_timer -= delta
	if _vis_timer <= 0.0:
		_vis_timer = 0.12
		_sync_vis(false)
	_sync_environment()
	_update_light(false)
	_take_look_changes()
	_refresh_floors()
	_stream_chunks(BUILD_BUDGET_USEC)
	_doors(delta)
	_sync_units()
	_sync_vehicles()
	_sync_walkers(delta)
	if _presence_timer <= 0.0 and main.has_method("_send_fp_presence"):
		_presence_timer = 0.1
		main._send_fp_presence(true)
	_sync_combat_fx()
	_cloud_timer -= delta
	if _cloud_timer <= 0.0:
		_cloud_timer = 0.25
		_sync_clouds()
	_feature_timer -= delta
	if _feature_timer <= 0.0:
		_feature_timer = 0.3
		_sync_features()
	_map_timer -= delta
	if _map_timer <= 0.0:
		_map_timer = 0.1
		_minimap.queue_redraw()

func view_distance() -> int:
	return Ui.fp_render_distance

func _place_camera() -> void:
	if _render_distance_applied != view_distance():
		_render_distance_applied = view_distance()
		for material: ShaderMaterial in _all_mats:
			material.set_shader_parameter("render_radius", float(_render_distance_applied))
	_cam.fov = clampf(float(Ui.fp_fov), 50.0, 120.0)
	_cam.position = pos + Vector3(0, EYE, 0)
	_cam.rotation = Vector3(pitch, yaw, 0)
	_fog_boundary.set_view(pos, view_distance())
	if _snow != null:
		_snow.position = pos + Vector3(0, 9.0, 0)

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
		var hh := Furniture.height_of(cell.feature_id)
		return INF if hh > 1.25 else hh
	if cell.feature_id == MCF.FEATURE_TRENCH:
		return -FirstPersonBoard.TRENCH
	if cell.feature_id == "" or cell.feature_id in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE]:
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
	if noclip: return g == INF
	if g > p.y + STEP:
		return true
	# Floating below the deck, the deck's edge is a wall.
	if g > -INF and p.y < g - 0.05:
		return true
	for id: int in _units:
		var n: Node3D = _units[id]
		if n.visible and n.has_meta("soldier") and Vector2(n.position.x - p.x, n.position.z - p.z).length() < RADIUS + UNIT_W * 0.5:
			return true
	return false

## Holding Space against a ledge up to 2.2 m high pulls you up onto it: out of a trench,
## onto a wall of sandbags. Units still stand in the way.
func _climb(p: Vector3) -> bool:
	if not Keybinds.movement_down("fp_up"):
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
	if noclip:
		_fly(delta, _move_input(), Keybinds.movement_down("fp_run"))
		return
	if _in_space(pos) and not noclip:
		_float(delta)
		return
	drift = Vector3.ZERO
	var dir := Vector3.ZERO
	if Keybinds.movement_down("fp_forward"): dir.z -= 1
	if Keybinds.movement_down("fp_back"): dir.z += 1
	if Keybinds.movement_down("fp_left"): dir.x -= 1
	if Keybinds.movement_down("fp_right"): dir.x += 1
	_walk(delta, dir, Keybinds.movement_down("fp_run"))

func _move_input() -> Vector3:
	return Vector3(float(Keybinds.movement_down("fp_right")) - float(Keybinds.movement_down("fp_left")),
		float(Keybinds.movement_down("fp_up")) - float(Keybinds.movement_down("fp_down")),
		float(Keybinds.movement_down("fp_back")) - float(Keybinds.movement_down("fp_forward")))

## Noclip has no gravity, inertia, ceiling or altitude limit. Only fog blocks it.
func _fly(delta: float, direction: Vector3, running: bool) -> void:
	drift = Vector3.ZERO
	vel_y = 0.0
	on_ground = false
	var basis := Basis.from_euler(Vector3(pitch, yaw, 0))
	var movement := basis * Vector3(direction.x, 0, direction.z) + Vector3.UP * direction.y
	var step := movement.normalized() * (RUN_SPEED if running else SPEED) * delta
	# Substeps prevent fast movement from skipping a narrow strip of unknown cells.
	var count := maxi(1, ceili(step.length() / 0.2))
	step /= count
	for i in count:
		for axis in [0, 2, 1]:
			var next := pos
			next[axis] += step[axis]
			if not _blocked(next): pos = next

## Ground movement uses one normalized input vector for motion and footstep distance.
func _walk(delta: float, dir: Vector3, running: bool) -> void:
	var step := Vector3.ZERO
	if dir != Vector3.ZERO:
		step = dir.normalized().rotated(Vector3.UP, yaw) * (RUN_SPEED if running else SPEED) * delta
	var before_move := pos
	if step.x != 0.0:
		var p := pos + Vector3(step.x, 0, 0)
		if not _blocked(p) or _climb(p):
			pos.x = p.x
	if step.z != 0.0:
		var p2 := pos + Vector3(0, 0, step.z)
		if not _blocked(p2) or _climb(p2):
			pos.z = p2.z
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
	var moved := Vector2(pos.x - before_move.x, pos.z - before_move.z).length()
	if on_ground and moved > 0.0:
		_walked += moved
		var stride := RUN_STEP_DISTANCE if running else STEP_DISTANCE
		if _walked >= stride:
			_walked = fmod(_walked, stride)
			_footstep()
	var here := Vector2i(floori(pos.x), floori(pos.z))
	if here != _last_cell:
		_last_cell = here
		if state.grid.in_bounds(here) and main.has_method("_center_on_cell"):
			main._center_on_cell(here, true)   # the battle's sounds are placed around you

func _settle_feet() -> void:
	var g := _ground_at(pos)
	pos.y = 0.0 if g == INF or g == -INF else g

## Zero-g: jets push along where you look (Space pushes up), nothing slows you down, and
## a wall or hull you hit stops the part of your motion that went into it.
func _float(delta: float) -> void:
	var push := Vector3.ZERO
	if Keybinds.movement_down("fp_forward"): push.z -= 1
	if Keybinds.movement_down("fp_back"): push.z += 1
	if Keybinds.movement_down("fp_left"): push.x -= 1
	if Keybinds.movement_down("fp_right"): push.x += 1
	if Keybinds.movement_down("fp_up"): push.y += 1
	if Keybinds.movement_down("fp_down"): push.y -= 1
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
	var a = main.get("_audio")
	var cell := Vector2i(floori(pos.x), floori(pos.z))
	if a == null or not state.grid.in_bounds(cell):
		return
	a.cue(a.STEP.get(a._material(state, cell), "step_concrete"), cell, viewer)

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
	if not limited:
		_vis_img.fill(Color(1, 1, 1))
		_vis_prev = []
		_upload_visibility()
		return
	var visible: Dictionary = main._visible_before_impact(viewer)
	if full:
		_vis_img.fill(Color(0, 0, 0))
		var explored: Dictionary = r.explored.get(viewer, {}) if r.fog_enabled else {}
		for c: Vector2i in explored:
			if c.x < grid.width and c.y < grid.height:
				_vis_img.set_pixel(c.x, c.y, Color(0.5, 0, 0))
	for c: Vector2i in _vis_prev:
		if not visible.has(c):
			_vis_img.set_pixel(c.x, c.y, Color(0.5, 0, 0) if r.fog_enabled else Color(0, 0, 0))
	_vis_prev = []
	for c: Vector2i in visible:
		_vis_img.set_pixel(c.x, c.y, Color(1, 0, 0))
		_vis_prev.append(c)
	_upload_visibility()

## Publish a complete visibility image together, without overwriting the sampled map.
func _upload_visibility() -> void:
	if _vis_spare == null: _vis_spare = ImageTexture.create_from_image(_vis_img)
	else: _vis_spare.update(_vis_img)
	var previous := _vis_tex
	_vis_tex = _vis_spare
	_vis_spare = previous
	for material: ShaderMaterial in _all_mats: material.set_shader_parameter("vis", _vis_tex)
	for material: ShaderMaterial in _vis_extra_materials: material.set_shader_parameter("sight", _vis_tex)
	if _fog_boundary != null: _fog_boundary.update_visibility(_vis_img)

func _seen(c: Vector2i) -> bool:
	return grid.in_bounds(c) and _vis_img.get_pixel(c.x, c.y).r > 0.75

## One texel a cell: how much each cell shades the floor beside it (walls, furniture).
func _build_solid() -> void:
	var data := PackedByteArray()
	data.resize(grid.width * grid.height)
	var cells := grid.cells_flat()
	for i in cells.size():
		data[i] = int(FirstPersonBoard.solid_value(cells[i], env) * 255.0)
	_solid_img = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_R8, data)
	_solid_tex = ImageTexture.create_from_image(_solid_img)
	var tiles: TerrainTiles = main._tiles
	var kinds := PackedByteArray()
	kinds.resize(grid.width * grid.height)
	for y in grid.height:
		for x in grid.width:
			kinds[y * grid.width + x] = tiles.ground_kind(Vector2i(x, y))
	_ground_img = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_R8, kinds)
	_ground_tex = ImageTexture.create_from_image(_ground_img)

## Cells whose look changed (a wall fell, furniture moved, a door was welded): their 3D
## chunks — and the neighbours that share a wall face or a piece with them — are rebuilt.
func _take_look_changes() -> void:
	if _look_ver == GridCell.look_version:
		return
	var changed := {}
	if _look_ver < GridCell.look_log_base:
		for cc: Vector2i in _chunks:
			_dirty[cc] = true
		for cc: Vector2i in _chunk_jobs:
			_dirty[cc] = true
	else:
		var ch := GridCell.look_changes
		var i: int = (_look_ver - GridCell.look_log_base) * 2
		while i < ch.size():
			changed[Vector2i(ch[i], ch[i + 1])] = true
			i += 2
	_look_ver = GridCell.look_version
	var solid_dirty := false
	var ground_dirty := false
	for c: Vector2i in changed:
		if not grid.in_bounds(c):
			continue
		var gk: int = main._tiles.ground_kind(c)
		if int(_ground_img.get_pixel(c.x, c.y).r * 255.0 + 0.5) != gk:
			_ground_img.set_pixel(c.x, c.y, Color(gk / 255.0, 0, 0))
			ground_dirty = true
		var v := int(FirstPersonBoard.solid_value(grid.cell_fast(c.x, c.y), env) * 255.0)
		if int(_solid_img.get_pixel(c.x, c.y).r * 255.0 + 0.5) != v:
			_solid_img.set_pixel(c.x, c.y, Color(v / 255.0, 0, 0))
			solid_dirty = true
		for dy in range(-3, 4, 3):
			for dx in range(-3, 4, 3):
				var cc := Vector2i((c.x + dx) / FirstPersonBoard.CH, (c.y + dy) / FirstPersonBoard.CH)
				if _chunks.has(cc) or _chunk_jobs.has(cc):
					_dirty[cc] = true
	if solid_dirty:
		_solid_tex.update(_solid_img)
	if ground_dirty:
		_ground_tex.update(_ground_img)

# --- Shaders, materials, sky and light ---------------------------------------------------------

func _build_shaders() -> void:
	if _board_sh == null: _board_sh = Shader.new()
	_board_sh.code = FirstPersonBoard.sun_shader_code() if _sun_on else FirstPersonBoard.SHADER
	if _bill_sh == null: _bill_sh = Shader.new()
	_bill_sh.code = FirstPersonBoard.BILLBOARD
	var g := _board_sh.code.replace("render_mode cull_back, depth_draw_opaque", "render_mode cull_disabled, blend_mix, depth_draw_opaque")
	g = g.replace("		ALBEDO = c.rgb * lit * k;", "		ALBEDO = c.rgb * lit * k;\n		ALPHA = 0.3;")
	if _glass_sh == null: _glass_sh = Shader.new()
	_glass_sh.code = g

## Every board material shares the sight map, the shade map and the light map.
func _mat(shader: Shader, p: Dictionary) -> ShaderMaterial:
	var common := {"vis": _vis_tex, "solid": _solid_tex, "board": Vector2(grid.width, grid.height),
			"mats": FirstPersonArt.materials(), "sun_k": SUN_K if _sun_on else 0.0,
			"grounds": FirstPersonArt.grounds(), "ground_kind": _ground_tex, "winter": state.winter,
			"render_radius": float(view_distance())}
	common.merge(_light_params())
	common.merge(p, true)
	var m := FirstPersonBoard.material(shader, common)
	_all_mats.append(m)
	return m

func _light_params() -> Dictionary:
	var on: bool = Ui.dynamic_lighting
	return {"lightmap": _lm_tex, "lm_rect": Vector4(_lm_rect.position.x, _lm_rect.position.y, maxi(1, _lm_rect.size.x), maxi(1, _lm_rect.size.y)),
			"lm_px": Vector2(1.0 / maxf(1.0, _lm_rect.size.x * LM_TEXELS), 1.0 / maxf(1.0, _lm_rect.size.y * LM_TEXELS)),
			"lm_on": on and _lm_tex != null, "flat_light": LightManager.flat_tint(env, state.time_of_day)}

func _build_materials() -> void:
	_mats["ceiling"] = _mat(_board_sh, {"tex": _panel_texture(env)})
	_mats["roof"] = _mat(_board_sh, {"tex": _roof_texture(env, state.winter)})
	_mats["models"] = _mat(_board_sh, {"use_mats": true})
	_mats["glass"] = _mat(_glass_sh, {"use_mats": true})
	_mats["env"] = env
	_mats["wall"] = func(kind: String, accent: Color) -> Material:
		var key := "wall|%s|%s" % [kind, accent.to_html()]
		if not _art_mats.has(key):
			_art_mats[key] = _mat(_board_sh, {"tex": FirstPersonArt.wall_texture(kind, accent), "ground_ao": true})
		return _art_mats[key]
	_mats["door"] = func(style: String, accent: Color, at: Vector2i) -> Material:
		var key := "door|%s|%s|%s" % [style, accent.to_html(), at]
		if not _art_mats.has(key):
			_art_mats[key] = _mat(_board_sh, {"tex": FirstPersonArt.door_texture(style, accent),
					"door_bounds": Vector4(at.x + 0.001, at.y + 0.001, at.x + 0.999, at.y + 0.999)})
		return _art_mats[key]

## The first-person floor of a tile chunk (TerrainTiles.FP_RES) and its two materials.
func _tile_floor(tcc: Vector2i) -> void:
	var tiles: TerrainTiles = main._tiles
	var tex := tiles.floor_3d(tcc)
	if _floor_tex.get(tcc) == tex:
		return
	_floor_tex[tcc] = tex
	if _mats["floor"].has(tcc):
		(_mats["floor"][tcc] as ShaderMaterial).set_shader_parameter("tex", tex)
		(_mats["floor_cut"][tcc] as ShaderMaterial).set_shader_parameter("tex", tex)
		return
	var p := {"tex": tex, "relief": 0.6, "ground_ao": true, "has_ground": true}
	_mats["floor"][tcc] = _mat(_board_sh, p)
	_mats["floor_cut"][tcc] = _mat(_board_sh, {"tex": tex, "cut": 0.5, "relief": 0.6})

## A fresh floor bake (blood landed, the fog memory caught up) only swaps the picture.
func _refresh_floors() -> void:
	var tiles: TerrainTiles = main._tiles
	for tcc: Vector2i in _floor_tex:
		var key := Vector3i(tcc.x, tcc.y, TerrainTiles.FP_RES)
		if tiles._dirty.has(tcc) or not tiles._chunks.has(key) or tiles._chunks[key]["floor"] != _floor_tex[tcc]:
			_floor_refresh[tcc] = true
			# New rubble or knocked items there: the chunks over it gather them up.
			var n := (tiles.decals.get(tcc, []) as Array).size()
			var per := TerrainTiles.C / FirstPersonBoard.CH
			for dy in per:
				for dx in per:
					var cc := tcc * per + Vector2i(dx, dy)
					if _chunks.has(cc) and int(_chunks[cc]["decal_n"]) != n:
						_dirty[cc] = true

func _prepare_floor(tcc: Vector2i, deadline: int) -> bool:
	var tiles: TerrainTiles = main._tiles
	var key := Vector3i(tcc.x, tcc.y, TerrainTiles.FP_RES)
	if tiles._dirty.has(tcc): _floor_jobs.erase(tcc)
	if _floor_jobs.has(tcc) and (_floor_jobs[tcc].source != tiles or _floor_jobs[tcc].generation != tiles._generation):
		_floor_jobs.erase(tcc)
	if not tiles._dirty.has(tcc) and tiles._chunks.has(key):
		_tile_floor(tcc)
		return true
	if not _floor_jobs.has(tcc): _floor_jobs[tcc] = tiles.begin_floor_job(tcc)
	if not tiles.advance_floor_job(_floor_jobs[tcc], deadline): return false
	_floor_jobs.erase(tcc)
	_tile_floor(tcc)
	return true

## The light map for the cells around you: the battle screen's lamps, fire and flashes, and
## the drones in the air — redrawn only when something in it changed.
func _update_light(force: bool) -> void:
	if _lm_pending: return
	var r: GameActionResolver = main._view_resolver()
	var limited := r.visibility_limited()
	var visible: Dictionary = main._visible_before_impact(viewer) if limited else {}
	var here := Vector2i(floori(pos.x), floori(pos.z))
	var reach := view_distance() + 8
	var lo := Vector2i(floori((here.x - reach) / 8.0) * 8, floori((here.y - reach) / 8.0) * 8)
	var rect := Rect2i(lo, Vector2i(reach * 2 + 16, reach * 2 + 16)).intersection(Rect2i(0, 0, grid.width, grid.height))
	var base: Grid = main._fog_mem.get(viewer, state.grid) if limited else state.grid
	var lit: Grid = main._terrain_before_impact(base, visible, limited)
	var shifting := rect != _lm_rect and _lm_tex != null
	var target := _lm_spare if shifting else _lm
	target.extra_lights = main.drone_lights(viewer, visible, limited)
	var texture := target.render_area(lit, rect, LM_TEXELS, env, visible, limited, main._fx, state.time_of_day)
	if shifting and DisplayServer.get_name() != "headless":
		# A viewport texture becomes ready after drawing. Keep the previous map AND
		# its coordinates together until the replacement is ready, including resizes
		# at the edge of the board. Otherwise lamps jump for one frame every 8 cells.
		_lm_pending = true
		RenderingServer.frame_post_draw.connect(_commit_light_map.bind(target, texture, rect), CONNECT_ONE_SHOT)
	elif rect != _lm_rect or force or _lm_options != [Ui.dynamic_lighting, state.time_of_day]:
		_commit_light_map(target, texture, rect)

func _commit_light_map(target: LightManager, texture: Texture2D, rect: Rect2i) -> void:
	if target != _lm:
		_lm_spare = _lm
		_lm = target
	_lm_tex = texture
	_lm_rect = rect
	_lm_pending = false
	_lm_options = [Ui.dynamic_lighting, state.time_of_day]
	var params := _light_params()
	for material: ShaderMaterial in _all_mats:
		for key: String in params:
			material.set_shader_parameter(key, params[key])

func _sync_environment() -> void:
	if _environment_time == state.time_of_day: return
	_sun_on = env in ["town", "field"] and state.time_of_day in ["day", "morning", "evening"]
	_build_shaders()
	for material: ShaderMaterial in _all_mats:
		material.set_shader_parameter("sun_k", SUN_K if _sun_on else 0.0)
	main._tiles.set_time_of_day(state.time_of_day)
	# Lamp models include emissive surfaces, so refresh them with the new time.
	for cc: Vector2i in _chunks: _dirty[cc] = true
	for cc: Vector2i in _chunk_jobs: _dirty[cc] = true
	_build_environment()

func _build_environment() -> void:
	if _environment_root != null: _environment_root.free()
	_environment_root = Node3D.new()
	_world.add_child(_environment_root)
	_environment_time = state.time_of_day
	var e := Environment.new()
	var tod: String = state.time_of_day
	var night := tod in ["night", ""]
	var dusk := tod in ["morning", "evening"]
	# The light map is all the light there is; the sun only adds its shadows.
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color.BLACK
	e.ambient_light_energy = 0.0
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.tonemap_exposure = 1.0
	e.glow_enabled = true
	e.glow_intensity = 0.65
	e.glow_strength = 1.0
	e.glow_hdr_threshold = 1.05
	e.glow_bloom = 0.0
	match env:
		"town", "field":
			var sky := Sky.new()
			var pm := ProceduralSkyMaterial.new()
			pm.sky_top_color = Color(0.01, 0.012, 0.03) if night else (Color(0.32, 0.42, 0.66) if dusk else Color(0.28, 0.48, 0.82))
			pm.sky_horizon_color = Color(0.03, 0.035, 0.06) if night else (Color(0.95, 0.66, 0.45) if dusk else Color(0.68, 0.78, 0.9))
			pm.sky_energy_multiplier = 1.0
			pm.ground_bottom_color = Color(0.05, 0.05, 0.05)
			pm.ground_horizon_color = pm.sky_horizon_color
			pm.sun_angle_max = 0.0
			sky.sky_material = pm
			e.background_mode = Environment.BG_SKY
			e.sky = sky
			e.fog_enabled = true
			e.fog_light_color = pm.sky_horizon_color
			e.fog_density = 0.016 if night else 0.008
			e.fog_sky_affect = 0.0
			if _outer_ground == null:
				_outer_ground = _far_ground()
				_world.add_child(_outer_ground)
			if _sun_on:
				var sun := DirectionalLight3D.new()
				sun.light_color = Color.WHITE
				sun.light_energy = 1.0
				sun.rotation_degrees = Vector3(-50.0 if not dusk else -24.0, 35.0, 0)
				sun.shadow_enabled = true
				sun.directional_shadow_max_distance = 55.0
				sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if OS.get_name() == "Web" else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
				sun.shadow_blur = 1.2
				sun.shadow_bias = 0.04
				_environment_root.add_child(sun)
			elif night:
				_environment_root.add_child(_moon())
		"asteroid":
			var sky2 := Sky.new()
			var stars := PanoramaSkyMaterial.new()
			stars.panorama = _star_texture()
			sky2.sky_material = stars
			e.background_mode = Environment.BG_SKY
			e.sky = sky2
		_:
			e.background_mode = Environment.BG_COLOR
			e.background_color = Color(0.01, 0.01, 0.015)
			e.fog_enabled = true
			e.fog_light_color = Color(0.02, 0.02, 0.025)
			e.fog_density = 0.01
			if env == "station":
				var sky3 := Sky.new()
				var stars3 := PanoramaSkyMaterial.new()
				stars3.panorama = _star_texture()
				sky3.sky_material = stars3
				e.background_mode = Environment.BG_SKY
				e.sky = sky3
				e.fog_enabled = false
	var we := WorldEnvironment.new()
	we.environment = e
	_environment_root.add_child(we)

## The land goes on past the map (as on the battle screen, where the ground runs on behind
## the board): one wide plane of the same turf or earth, just under the board's floor.
func _far_ground() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var s := FirstPersonModels.Sink.new()
	s.shade_floor = false
	var w := float(grid.width)
	var h := float(grid.height)
	var r := 800.0
	# A ring round the board, never under it: the board has pits (trenches) to see into.
	for q: Rect2 in [Rect2(-r, -r, w + 2 * r, r), Rect2(-r, h, w + 2 * r, r), Rect2(-r, 0, r, h), Rect2(w, 0, r, h)]:
		s.face_uv([Vector3(q.position.x, -0.01, q.position.y), Vector3(q.end.x, -0.01, q.position.y), Vector3(q.end.x, -0.01, q.end.y),
				Vector3(q.position.x, -0.01, q.end.y)], Vector3.UP, [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO], Color.WHITE)
	mi.mesh = s.mesh()
	var clear := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	clear.fill(Color(0, 0, 0, 0))
	mi.material_override = _mat(_board_sh, {"tex": ImageTexture.create_from_image(clear), "has_ground": true, "no_fog": true})
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

## Snow falling round you on a winter map (fix-8 #3): flakes in a box that follows the
## camera, drifting a little; switched off in Settings with the battle screen's snow.
var _snow: CPUParticles3D
func _sync_snow() -> void:
	var on := state.winter and Ui.snowfall
	if on and _snow == null:
		_world.add_child(_snow_particles())
	if _snow != null:
		_snow.visible = on
		_snow.emitting = on

func _snow_particles() -> CPUParticles3D:
	_snow = CPUParticles3D.new()
	_snow.position = pos + Vector3(0, 9.0, 0)
	_snow.amount = 1400
	_snow.lifetime = 6.0
	_snow.preprocess = 6.0
	_snow.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_snow.emission_box_extents = Vector3(18, 0.5, 18)
	_snow.direction = Vector3(0.15, -1, 0.05)
	_snow.spread = 12.0
	_snow.gravity = Vector3(0, -0.6, 0)
	_snow.initial_velocity_min = 0.9
	_snow.initial_velocity_max = 1.6
	_snow.local_coords = false
	var q := QuadMesh.new()
	q.size = Vector2(0.035, 0.035)
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D roofs : filter_nearest;
uniform sampler2D sight : filter_nearest;
uniform vec2 board;
varying vec3 world_pos;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 uv = (floor(world_pos.xz) + 0.5) / board;
	if (world_pos.y < 0.0 || texture(sight, uv).r < 0.7) discard;
	if (world_pos.y < 2.65 && texture(roofs, uv).r > 0.5) discard;
	ALBEDO = vec3(0.95, 0.97, 1.0);
	ALPHA = 0.75;
}
"""
	m.shader = sh
	var roof_pixels := _roof.duplicate()
	for i in roof_pixels.size():
		roof_pixels[i] *= 255
	m.set_shader_parameter("roofs", ImageTexture.create_from_image(Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_R8, roof_pixels)))
	m.set_shader_parameter("sight", _vis_tex)
	_vis_extra_materials.append(m)
	m.set_shader_parameter("board", Vector2(grid.width, grid.height))
	q.material = m
	_snow.mesh = q
	_snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return _snow

## The moon over a night town: a pale disc far up the sky.
func _moon() -> Node3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(9, 9)
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.85, 0.88, 0.95)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.albedo_texture = _disc_texture()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.disable_fog = true
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(grid.width * 0.5 + 120, 160, grid.height * 0.5 - 140)
	return mi

static func _disc_texture() -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length()
			var crater := FirstPersonArt._vn(x, y, 8, 50) * 0.12
			img.set_pixel(x, y, Color(1.0 - crater, 1.0 - crater, 1.0 - crater, 1.0 if d < 15.0 else 0.0))
	return ImageTexture.create_from_image(img)

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

## Ceiling panels (station, bunker, asteroid domes) or plaster (town, field houses), 1 m a
## tile like everything else, with their joints in relief.
static func _panel_texture(e: String) -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var metal := e in ["station", "bunker", "asteroid"]
	for y in 32:
		for x in 32:
			var n := FirstPersonArt._h(x, y, 60) * 0.04
			var c: Color
			if metal:
				var seam := x % 16 == 0 or y % 16 == 0
				var lit := x % 16 == 1 or y % 16 == 1
				c = Color(0.36, 0.38, 0.41) * (0.7 if seam else (1.08 if lit else 1.0 + n))
				if (x % 16 == 8) and (y % 16 >= 4 and y % 16 <= 11):
					c = Color(0.3, 0.31, 0.33)   # a vent slot
			else:
				var crack := FirstPersonArt._vn(x, y, 8, 61) * 0.05
				c = Color(0.62, 0.6, 0.56) * (0.97 + n - crack)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

static func _roof_texture(e: String, winter := false) -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var metal := e in ["station", "bunker", "asteroid"]
	for y in 32:
		for x in 32:
			var n := FirstPersonArt._h(x, y, 62) * 0.08
			var c: Color
			if winter and not metal:
				# Snow lies on the roofs, a tile edge showing through here and there.
				var thin := FirstPersonArt._vn(x, y, 8, 64) < 0.25 and y % 4 == 3
				img.set_pixel(x, y, Color(0.5, 0.3, 0.24) if thin else Color(0.9, 0.93, 0.97) * (0.96 + n * 0.5))
				continue
			if metal:
				c = Color(0.32, 0.33, 0.35) * (0.75 if (x % 16 == 0 or y % 16 == 0) else 0.95 + n)
			else:
				# Clay tiles in courses, each lit on its upper edge.
				var row := y / 4
				var bx := (x + (2 if row % 2 == 1 else 0)) % 4
				var base := Color(0.46, 0.24, 0.17) * (0.9 + FirstPersonArt._h(row, (x + (2 if row % 2 == 1 else 0)) / 4, 63) * 0.15)
				c = base * (0.72 if y % 4 == 3 else (1.12 if y % 4 == 0 else 1.0)) * (0.85 if bx == 3 else 1.0)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# --- The board, streamed around you ---------------------------------------------------------

## Build missing and changed chunks nearest first, within `budget` microseconds; drop far ones.
func _stream_chunks(budget: int) -> void:
	var t0 := Time.get_ticks_usec()
	var deadline := t0 + budget
	for tcc: Vector2i in _floor_refresh.keys():
		if not _prepare_floor(tcc, deadline): return
		_floor_refresh.erase(tcc)
	var here := Vector2i(floori(pos.x) / FirstPersonBoard.CH, floori(pos.z) / FirstPersonBoard.CH)
	var reach := view_distance() / FirstPersonBoard.CH + 1
	var want: Array = []
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var cc := here + Vector2i(dx, dy)
			if cc.x < 0 or cc.y < 0 or cc.x * FirstPersonBoard.CH >= grid.width or cc.y * FirstPersonBoard.CH >= grid.height:
				continue
			if not _chunks.has(cc) or _dirty.has(cc) or _chunk_jobs.has(cc):
				want.append(cc)
	want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.distance_squared_to(here) < b.distance_squared_to(here))
	for cc: Vector2i in want:
		if Time.get_ticks_usec() - t0 > budget:
			break
		var tcc := Vector2i(cc.x * FirstPersonBoard.CH / TerrainTiles.C, cc.y * FirstPersonBoard.CH / TerrainTiles.C)
		if not _prepare_floor(tcc, deadline): break
		if Time.get_ticks_usec() >= deadline: break
		if not _advance_chunk(cc, deadline): break
	# Far chunks go; they come back when you do.
	for cc: Vector2i in _chunks.keys():
		if maxi(absi(cc.x - here.x), absi(cc.y - here.y)) > reach + 2:
			_drop_chunk(cc)
	for cc: Vector2i in _chunk_jobs.keys():
		if maxi(absi(cc.x - here.x), absi(cc.y - here.y)) > reach + 2:
			_discard_chunk_job(cc)

func _chunk_context() -> Dictionary:
	var tiles: TerrainTiles = main._tiles
	return {"env": env, "mats": _mats, "tod": state.time_of_day, "winter": state.winter,
		"look": func(c: Vector2i, fid: String) -> Array: return tiles.look_of(c, fid),
		"furniture_look": tiles.furniture_look}

func _advance_chunk(cc: Vector2i, deadline: int) -> bool:
	if _dirty.has(cc): _discard_chunk_job(cc)
	if not _chunk_jobs.has(cc):
		_dirty.erase(cc)
		var ctx := _chunk_context()
		var tcc := Vector2i(cc.x * FirstPersonBoard.CH / TerrainTiles.C, cc.y * FirstPersonBoard.CH / TerrainTiles.C)
		ctx["decals"] = main._tiles.decals.get(tcc, [])
		ctx["map_decals"] = main._tiles.map_decals.get(tcc, [])
		_chunk_jobs[cc] = FirstPersonBoard.begin_build(grid, cc, _roof, ctx)
	var job: Dictionary = _chunk_jobs[cc]
	if not job.advance.call(deadline): return false
	if Time.get_ticks_usec() >= deadline: return false
	var built: Dictionary = job.finish.call()
	_chunk_jobs.erase(cc)
	_install_chunk(cc, built)
	return true

func _discard_chunk_job(cc: Vector2i) -> void:
	if _chunk_jobs.has(cc):
		_chunk_jobs[cc].node.free()
		_chunk_jobs.erase(cc)

func _build_chunk(cc: Vector2i) -> void:
	_discard_chunk_job(cc)
	_dirty.erase(cc)
	var ch := FirstPersonBoard.CH
	var tcc := Vector2i(cc.x * ch / TerrainTiles.C, cc.y * ch / TerrainTiles.C)
	_tile_floor(tcc)
	var tiles: TerrainTiles = main._tiles
	var built := FirstPersonBoard.build(grid, cc, _roof, {"env": env, "mats": _mats, "tod": state.time_of_day, "winter": state.winter,
			"look": func(c: Vector2i, fid: String) -> Array: return tiles.look_of(c, fid),
			"furniture_look": tiles.furniture_look,
			"decals": tiles.decals.get(tcc, []), "map_decals": tiles.map_decals.get(tcc, [])})
	_install_chunk(cc, built)

func _install_chunk(cc: Vector2i, built: Dictionary) -> void:
	var tcc := Vector2i(cc.x * FirstPersonBoard.CH / TerrainTiles.C, cc.y * FirstPersonBoard.CH / TerrainTiles.C)
	_drop_chunk(cc)
	var node: Node3D = built["node"]
	_board_node.add_child(node)
	_chunks[cc] = {"node": node, "doors": built["doors"], "tops": built["tops"],
			"decal_n": (main._tiles.decals.get(tcc, []) as Array).size()}

func _drop_chunk(cc: Vector2i) -> void:
	if _chunks.has(cc):
		(_chunks[cc]["node"] as Node3D).queue_free()
		_chunks.erase(cc)

## Kept for older local profiling scripts; wall spatters have been removed.
func _take_new_blood() -> void:
	pass

func _doors(delta: float) -> void:
	for cc: Vector2i in _chunks:
		for at: Vector2i in _chunks[cc]["doors"]:
			var door: Node3D = _chunks[cc]["doors"][at]
			var cell := grid.cell_fast(at.x, at.y)
			var near := Vector2(at.x + 0.5 - pos.x, at.y + 0.5 - pos.z).length() < 1.4
			var want := 1.0 if (near or cell.cover_height < MCF.WALL_HEIGHT) and not cell.airlock_welded else 0.0
			var was := float(_door_open.get(at, 0.0))
			# A streamed/rebuilt chunk has fresh leaves even when the opening is unchanged.
			if was == want and door.get_meta("opening", -1.0) == want:
				continue
			var now := move_toward(was, want, delta * 3.0)
			if was == 0.0 and now > 0.0 and near:
				var a = main.get("_audio")
				if a != null and state.grid.in_bounds(at): a.cue("door_open", at, viewer)
			_door_open[at] = now
			door.set_meta("opening", now)
			var ease := now * now * (3.0 - 2.0 * now)
			var along_x: bool = door.get_meta("along_x")
			var leaves := 0
			for leaf: Node in door.get_children():
				if leaf.has_meta("side"):
					leaves += 1
			for leaf: Node in door.get_children():
				if not leaf.has_meta("side"):
					continue
				# Into the wall beside the doorway: halves apart, a single door aside.
				var off := float(leaf.get_meta("side")) * ease * (0.51 if leaves == 2 else 1.01)
				var home: Vector3 = leaf.get_meta("home")
				(leaf as Node3D).position = home + (Vector3(off, 0, 0) if along_x else Vector3(0, 0, off))

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
	_corpse_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dyn.add_child(_corpse_mm)

## The battle in the air (fix-8: "the atmosphere of the battle"): tracers streaking from the
## muzzle, rockets, shells and grenades in flight, fireballs where a blast went off, and the
## debris, casings and blood thrown about — all from the battle screen's own effects, shown
## where the battle screen shows them. One multimesh of glowing or plain blocks.
var _fx_mm: MultiMeshInstance3D
var _blast_mm: MultiMeshInstance3D
func _sync_combat_fx() -> void:
	var fx: FxDecals = main._fx
	if _fx_mm == null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE
		mm.mesh = bm
		_fx_mm = MultiMeshInstance3D.new()
		_fx_mm.multimesh = mm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		_fx_mm.material_override = m
		_fx_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_dyn.add_child(_fx_mm)
	if _blast_mm == null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		var sphere := SphereMesh.new()
		sphere.radius = 0.5
		sphere.height = 1.0
		sphere.radial_segments = 12
		sphere.rings = 6
		mm.mesh = sphere
		_blast_mm = MultiMeshInstance3D.new()
		_blast_mm.multimesh = mm
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_blast_mm.material_override = material
		_blast_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_dyn.add_child(_blast_mm)
	var visible: Dictionary = main._visible_before_impact(viewer)
	var limited: bool = main._view_resolver().visibility_limited()
	var seen := func(p: Vector2) -> bool: return not limited or visible.has(Vector2i(floori(p.x), floori(p.y)))
	var out: Array = []   # [Transform3D, Color]
	var blasts: Array = []
	var streak := func(a: Vector3, b: Vector3, w: float, col: Color) -> void:
		var d := b - a
		var len := d.length()
		if len < 0.001:
			return
		var x := d / len
		var up := Vector3.UP if absf(x.y) < 0.95 else Vector3.RIGHT
		var z := x.cross(up).normalized()
		var y := z.cross(x)
		out.append([Transform3D(Basis(x * len, y * w, z * w), (a + b) * 0.5), col])
	for beam: Dictionary in fx.beams:
		var a: Vector2 = beam["from"]
		var b: Vector2 = beam["to"]
		var count := maxi(1, ceili(a.distance_to(b) * 4.0))
		# Clip the glowing beam to this viewer's sight, including when it crosses fog.
		for i in count:
			var p0 := a.lerp(b, float(i) / count)
			var p1 := a.lerp(b, float(i + 1) / count)
			if seen.call((p0 + p1) * 0.5):
				streak.call(Vector3(p0.x, 1.3, p0.y), Vector3(p1.x, 1.3, p1.y), 0.055, Color(3.5, 0.18, 0.12))
	for tr: Dictionary in fx.tracers:
		var k := clampf(float(tr["t"]) / maxf(0.001, float(tr["dur"])), 0.0, 1.0)
		if k <= 0.0:
			continue
		var f2: Vector2 = tr["from"]
		var t2: Vector2 = tr["to"]
		var head := f2.lerp(t2, k)
		if not seen.call(head):
			continue
		var tail := f2.lerp(t2, maxf(0.0, k - 1.4 / maxf(0.5, f2.distance_to(t2))))
		streak.call(Vector3(tail.x, 1.28, tail.y), Vector3(head.x, 1.28, head.y), 0.022, Color(3.2, 2.5, 1.0))
		if k < 0.2 and seen.call(f2):
			var dir := (t2 - f2).normalized()
			var mz := f2 + dir * 0.35
			out.append([Transform3D(Basis().scaled(Vector3.ONE * 0.16), Vector3(mz.x, 1.28, mz.y)), Color(3.5, 2.2, 0.8)])
	for sh: Dictionary in fx.shots:
		var k2 := clampf(float(sh["t"]) / maxf(0.001, float(sh["dur"])), 0.0, 1.0)
		var a2: Vector2 = sh["from"]
		var b2: Vector2 = sh["to"]
		var p := a2.lerp(b2, k2)
		if not seen.call(p):
			continue
		var dir2 := (b2 - a2).normalized() if b2 != a2 else Vector2.RIGHT
		match str(sh["kind"]):
			"rocket":
				var back := p - dir2 * 0.45
				streak.call(Vector3(back.x, 1.3, back.y), Vector3(p.x, 1.3, p.y), 0.08, Color(0.18, 0.2, 0.18))
				streak.call(Vector3(back.x - dir2.x * 0.3, 1.3, back.y - dir2.y * 0.3), Vector3(back.x, 1.3, back.y), 0.1, Color(3.5, 2.0, 0.6))
			"shell":
				var back2 := p - dir2 * 0.9
				streak.call(Vector3(back2.x, 1.4, back2.y), Vector3(p.x, 1.4, p.y), 0.05, Color(3.0, 1.8, 0.7))
			_:
				out.append([Transform3D(Basis().scaled(Vector3.ONE * 0.1), Vector3(p.x, 1.2 + sin(k2 * PI) * 1.6, p.y)), Color(0.22, 0.26, 0.18)])
	for flash: Dictionary in fx.flashes:
		var a3 := FxDecals.flash_alpha(flash)
		if a3 <= 0.0:
			continue
		var cells: Array = flash["cells"]
		var step := maxi(1, cells.size() / 9)
		for i in range(0, cells.size(), step):
			var c: Vector2i = cells[i]
			if not seen.call(Vector2(c)):
				continue
			var age := clampf(float(flash["t"]) / FxDecals.FLASH_DUR, 0.0, 1.0)
			var s := (0.75 + age * 0.7) * (1.0 if i == cells.size() / 2 else 0.7)
			var center := Vector3(c.x + 0.5, 0.25 + s * 0.4, c.y + 0.5)
			# Rounded, expanding lobes around a hot core. Deterministic; no game dice.
			for lobe in 5:
				var angle := TAU * lobe / 4.0 + c.x * 0.7 + c.y * 0.3
				var offset := Vector3.ZERO if lobe == 4 else Vector3(cos(angle), 0.15 * (lobe % 2), sin(angle)) * s * 0.35
				var scale := Vector3.ONE * s * (0.75 if lobe == 4 else 0.65)
				var col := Color(3.0, 1.4, 0.3, a3) if lobe == 4 else Color(2.1, 0.45 + 0.12 * lobe, 0.06, a3)
				blasts.append([Transform3D(Basis().scaled(scale), center + offset), col])
	for f: Dictionary in fx.flying:
		var pos := FxDecals.flight_pos(f)
		var origin: Vector2i = f.get("origin", Vector2i(-1, -1))
		if limited and not visible.has(Vector2i(floori(pos.x), floori(pos.y))) and not visible.has(origin):
			continue
		var look := FxDecals.look_of(str(f["kind"]))
		if look.is_empty():
			continue
		var k3 := clampf(float(f["t"]) / maxf(0.001, float(f["dur"])), 0.0, 1.0)
		var size := maxf(0.03, float(look[0]) * float(f["scale"]) * 0.45)
		var col: Color = look[1]
		var basis := Basis(Vector3.UP, FxDecals.flight_rot(f)).scaled(Vector3(size, size * 0.5, size))
		out.append([Transform3D(basis, Vector3(pos.x, 0.05 + sin(k3 * PI) * 0.7, pos.y)), Color(col.r, col.g, col.b, 1.0)])
	var mm2 := _fx_mm.multimesh
	if mm2.instance_count < out.size():
		mm2.instance_count = out.size() + 32
	mm2.visible_instance_count = out.size()
	for i in out.size():
		mm2.set_instance_transform(i, out[i][0])
		mm2.set_instance_color(i, out[i][1])
	var blast_mm := _blast_mm.multimesh
	if blast_mm.instance_count < blasts.size(): blast_mm.instance_count = blasts.size() + 16
	blast_mm.visible_instance_count = blasts.size()
	for i in blasts.size():
		blast_mm.set_instance_transform(i, blasts[i][0])
		blast_mm.set_instance_color(i, blasts[i][1])

## Fire: steady glowing half-cubes (owner, fix-8: no flicker); gas and smoke: haze.
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
		mat.emission_energy_multiplier = 2.2
		mat.albedo_color = Color(1.0, 0.6, 0.15, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dyn.add_child(mi)
	return mi

## A soldier: a flat 1.7 m cut-out in its side's colour that always turns to face you, its
## class tag drawn on it in pixels (owner: 2D rectangles, like a 2.5D shooter's sprites).
func _unit_node(u: UnitInstance) -> Node3D:
	var n := Node3D.new()
	n.set_meta("soldier", true)
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.62, UNIT_H)
	q.center_offset = Vector3(0, UNIT_H * 0.5, 0)
	mi.mesh = q
	mi.material_override = _billboard_mat(_soldier_texture(main._side_color(u.owner),
			Sprites.unit_tag(u.stats.id, u.stats.display_name)))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(mi)
	_dyn.add_child(n)
	return n

var _bill_mats := {}
func _billboard_mat(tex: Texture2D) -> ShaderMaterial:
	if _bill_mats.has(tex):
		return _bill_mats[tex]
	var m := _mat(_bill_sh, {"tex": tex})
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
	var bodies := _corpses()
	for c: Vector2i in bodies:
		var e: Array = bodies[c]
		for k in maxi(1, int(e[1])):
			corpses.append(Transform3D(Basis(Vector3.UP, float((c.x * 7 + c.y * 13 + k * 5) % 9) * 0.35),
					Vector3(c.x + 0.5, 0.02 + k * 0.03, c.y + 0.5)))
	var mm := _corpse_mm.multimesh
	if mm.instance_count != corpses.size():
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

## A drone hangs just under the ceiling (1.8 m, owner); over a vehicle, above its roof.
func _place_drone(u: UnitInstance) -> void:
	var n: Node3D = _units.get(u.id)
	if n == null:
		n = Node3D.new()
		var mi := MeshInstance3D.new()
		var col: Color = main._side_color(u.owner)
		var scout := MCF.is_scout(u)
		var built: Array = FirstPersonModels.cached(str(["drone", col.to_html(), scout]),
				func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void:
					s.shade_floor = false
					FirstPersonModels.drone(s, col, scout))
		mi.mesh = built[0]
		mi.material_override = _mats["models"]
		n.add_child(mi)
		_dyn.add_child(n)
		_units[u.id] = n
	var p := _unit_pos(u)
	var y := 1.85
	if state.grid.in_bounds(u.coord) and state.grid.cell(u.coord).vehicle_id != -1:
		y = VEHICLE_H + 0.25
	n.position = Vector3(p.x, y + sin(Time.get_ticks_msec() * 0.003 + u.id) * 0.03, p.z)
	n.rotation.y += 0.01

## Vehicles as models — the tank's turret turns on its own — with the type's name in the
## battle screen's font on both flanks, sized to stay on the hull (owner, fix-8).
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
		var key := [veh.type_id, veh.owner, veh.wrecked]
		var n: Node3D = _vehicles.get(veh.id)
		if n != null and n.get_meta("key") != key:
			n.queue_free()
			n = null
		if n == null:
			n = _vehicle_node(veh)
			n.set_meta("key", key)
			_dyn.add_child(n)
			_vehicles[veh.id] = n
		var off: Vector2 = main._veh_offset.get(veh.id, Vector2.ZERO) / main.CELL
		n.position = Vector3(veh.origin.x + veh.size.x * 0.5 + off.x, 0.0, veh.origin.y + veh.size.y * 0.5 + off.y)
		var face := Vector2(veh.facing) if veh.facing != Vector2i.ZERO else Vector2(1, 0)
		n.rotation.y = -face.angle()
		var turret: Node3D = n.get_node_or_null("turret")
		if turret != null:
			var aim := Vector2(veh.tower_locked_dir) if veh.tower_locked_dir != Vector2i.ZERO else face
			turret.rotation.y = -(aim.angle() - face.angle())
	for id: int in _vehicles.keys():
		if not live.has(id):
			(_vehicles[id] as Node3D).queue_free()
			_vehicles.erase(id)

## Remote free-look avatars obey this viewer's fog and expire after a lost connection.
func _sync_walkers(delta: float) -> void:
	var peers: Variant = main.get("_fp_walkers")
	if not peers is Dictionary:
		return
	var wanted := {}
	for id: int in peers.keys():
		var p: Dictionary = peers[id]
		if Time.get_ticks_msec() - int(p["time"]) > 3000:
			peers.erase(id)
			continue
		var target: Vector3 = p["pos"]
		var cell := Vector2i(floori(target.x), floori(target.z))
		if not _seen(cell) or target.distance_to(pos) > view_distance():
			continue
		wanted[id] = true
		var n: Node3D = _walkers.get(id)
		if n == null:
			n = Node3D.new()
			var mesh := MeshInstance3D.new()
			var quad := QuadMesh.new()
			quad.size = Vector2(0.62, UNIT_H)
			quad.center_offset = Vector3(0, UNIT_H * 0.5, 0)
			mesh.mesh = quad
			mesh.material_override = _billboard_mat(_soldier_texture(main._side_color(p["side"]), "FP"))
			n.add_child(mesh)
			var label := Label3D.new()
			label.text = state.roster.name_of(p["side"])
			label.position.y = 1.95
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.font_size = 32
			label.pixel_size = 0.007
			n.add_child(label)
			_dyn.add_child(n)
			n.position = target
			_walkers[id] = n
		n.position = target if n.position.distance_to(target) > 3.0 else n.position.lerp(target, 1.0 - exp(-18.0 * delta))
	for id: int in _walkers.keys():
		if not wanted.has(id):
			(_walkers[id] as Node3D).queue_free()
			_walkers.erase(id)

var _handjet: Font
func _vehicle_node(veh: Vehicle) -> Node3D:
	var n := Node3D.new()
	var paint: Color = main._side_color(veh.owner).darkened(0.15)
	var wrecked := veh.wrecked
	var type := veh.type_id
	var hull: Array = FirstPersonModels.cached(str(["veh", type, paint.to_html(), wrecked]),
			func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void: FirstPersonModels.vehicle(s, type, paint, wrecked))
	var mi := MeshInstance3D.new()
	mi.mesh = hull[0]
	mi.material_override = _mats["models"]
	n.add_child(mi)
	if type == "tank":
		var turret := Node3D.new()
		turret.name = "turret"
		var tm := MeshInstance3D.new()
		tm.mesh = FirstPersonModels.cached(str(["turret", paint.to_html(), wrecked]),
				func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void:
					s.shade_floor = false
					FirstPersonModels.tank_turret(s, paint, wrecked))[0]
		tm.material_override = _mats["models"]
		turret.add_child(tm)
		n.add_child(turret)
	# The name on both flanks, within the hull's length.
	if _handjet == null:
		_handjet = load("res://fonts/handjet_ui_bold.ttf")
	var text := str(VehicleDB.get_vehicle(type).get("name", type)).to_upper()
	var half: Vector2 = {"tank": Vector2(1.2, 0.86), "shuttle": Vector2(0.85, 0.81), "borg": Vector2(0.36, 0.41)}.get(type, Vector2(0.5, 0.5))
	var y: float = {"tank": 0.98, "shuttle": 0.68, "borg": 1.5}.get(type, 1.0)
	for side: float in [-1.0, 1.0]:
		var l := Label3D.new()
		l.text = text
		l.font = _handjet
		l.font_size = 64
		l.outline_size = 0
		l.double_sided = false
		l.modulate = Color(0.06, 0.06, 0.06) if not wrecked else Color(0.3, 0.3, 0.3)
		var px := _handjet.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 64).x
		l.pixel_size = minf(0.008, half.x * 1.7 / maxf(1.0, px))
		l.position = Vector3(0, y, (half.y + 0.012) * side)
		l.rotation.y = 0.0 if side > 0 else PI
		n.add_child(l)
	return n

# --- Fire, gas and smoke; drone stations and mines ---------------------------------------------

func _sync_clouds() -> void:
	# Update a sparse index from the appearance journal instead of repeatedly
	# scanning every cell inside the render distance.
	if _cloud_version < GridCell.look_log_base:
		_cloud_cells.clear()
		for cell: GridCell in state.grid.cells_flat():
			if cell.on_fire or cell.gas or cell.smoke: _cloud_cells[cell.coord] = true
	elif _cloud_version != GridCell.look_version:
		var changes := GridCell.look_changes
		for i in range((_cloud_version - GridCell.look_log_base) * 2, changes.size(), 2):
			var at := Vector2i(changes[i], changes[i + 1])
			if not state.grid.in_bounds(at): continue
			var cell := state.grid.cell(at)
			if cell.on_fire or cell.gas or cell.smoke: _cloud_cells[at] = true
			else: _cloud_cells.erase(at)
	_cloud_version = GridCell.look_version
	var here := Vector2i(floori(pos.x), floori(pos.z))
	var fire: Array[Vector2i] = []
	var gas: Array[Vector2i] = []
	var smoke: Array[Vector2i] = []
	var r := view_distance()
	for at: Vector2i in _cloud_cells:
		if absi(at.x - here.x) > r or absi(at.y - here.y) > r or not _seen(at): continue
		var c := state.grid.cell(at)
		if c.on_fire: fire.append(at)
		if c.gas: gas.append(at)
		elif c.smoke: smoke.append(at)
	_fill(_fire_mm, fire, 0.25, 1.0)
	_fill(_gas_mm, gas, FirstPersonBoard.CEIL * 0.5, FirstPersonBoard.CEIL)
	_fill(_smoke_mm, smoke, FirstPersonBoard.CEIL * 0.5, FirstPersonBoard.CEIL)

func _fill(mi: MultiMeshInstance3D, cells: Array[Vector2i], y: float, hgt: float) -> void:
	if mi.get_meta("cells", []) == cells: return
	mi.set_meta("cells", cells)
	var mm := mi.multimesh
	if mm.instance_count != cells.size(): mm.instance_count = cells.size()
	for i in cells.size():
		var b := Basis().scaled(Vector3(1, hgt, 1)) if hgt != 1.0 else Basis()
		mm.set_instance_transform(i, Transform3D(b, Vector3(cells[i].x + 0.5, y, cells[i].y + 0.5)))

## Drone stations and mines are drawn apart from the board on the battle screen too: each
## side sees its own (a station while in sight, mines only its own or the revealed ones).
func _sync_features() -> void:
	var visible: Dictionary = main._visible_before_impact(viewer)
	var limited: bool = main._view_resolver().visibility_limited()
	var want := {}
	var here := Vector2(pos.x, pos.z)
	for sc: Vector2i in main._display_feature_cells(MCF.FEATURE_DRONE_STATION):
		if Vector2(sc).distance_to(here) > view_distance() or state.grid.cell_fast(sc.x, sc.y).vehicle_id != -1:
			continue
		if limited and not visible.has(sc):
			continue
		want[sc] = ["station", _station_colour(sc)]
	for mk: String in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE]:
		for mc: Vector2i in main._display_feature_cells(mk):
			if Vector2(mc).distance_to(here) <= view_distance() and (main.get("editor_view") == true or main.resolver.mine_visible_to(viewer, mc)):
				want[mc] = [mk, Color.WHITE]
	for c: Vector2i in _features.keys():
		if not want.has(c) or (_features[c] as Node3D).get_meta("spec") != want[c]:
			(_features[c] as Node3D).queue_free()
			_features.erase(c)
	for c: Vector2i in want:
		if _features.has(c):
			continue
		var spec: Array = want[c]
		var kind: String = spec[0]
		var col: Color = spec[1]
		var built: Array = FirstPersonModels.cached(str(["feature", kind, col.to_html()]),
				func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void:
					if kind == "station":
						FirstPersonModels.drone_station(s, col)
					else:
						FirstPersonModels.mine(s, kind == MCF.FEATURE_AV_MINE))
		var mi := MeshInstance3D.new()
		mi.mesh = built[0]
		mi.material_override = _mats["models"]
		mi.position = Vector3(c.x, 0, c.y)
		mi.set_meta("spec", spec)
		_dyn.add_child(mi)
		_features[c] = mi

## A station's lights in its operators' colour, when somebody's drone calls it home.
func _station_colour(sc: Vector2i) -> Color:
	for u: UnitInstance in state.all_units():
		if u.is_drone and u.home_station == sc:
			return main._side_color(u.owner)
	return Color(0.55, 0.85, 1.0)

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
				elif FirstPersonBoard.is_wall(cell, fp.env): col = Color(0.75, 0.76, 0.8)
				elif cell.feature_id != "" and cell.feature_id != MCF.FEATURE_BOUNDARY: col = Color(0.52, 0.5, 0.46)
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
