extends "res://scenes/Main.gd"

## A frozen, isolated battle renderer. No match startup, controllers, audio, HUD or handoffs.
var image_viewer := 0
var image_time := 0.0
var image_lighting := true
var image_seen := {}
var image_hidden: Variant = null
var image_memory: Grid

func capture(host: Node, lighting: bool, pixels_per_cell: int) -> void:
	video_export = true
	image_viewer = host._viewing_side()
	image_time = host._anim_time()
	image_lighting = lighting
	image_seen = host._visible_before_impact(image_viewer).duplicate()
	var hidden: Variant = host._hidden_before_impact(image_viewer)
	image_hidden = hidden.duplicate() if hidden != null else null
	var logs := GridCell.logs_snapshot()
	GridCell.journaling = false
	state = StateCodec.decode(StateCodec.encode(host.state))
	resolver = GameActionResolver.new(state)
	resolver.track_undo_history = false
	var rules := StateCodec.encode_rules(host.resolver)
	rules.erase("ai_speed")
	rules["fog"] = host._view_resolver().fog_mode
	StateCodec.apply_rules(resolver, rules)
	resolver.legacy_rear_cannon = host.resolver.legacy_rear_cannon
	resolver.legacy_orthogonal_cannon = host.resolver.legacy_orthogonal_cannon
	resolver.explored = host._view_resolver().explored.duplicate(true)
	_fx.restore_state(host._fx.capture_state())
	_fx.bounds = Vector2(state.grid.width, state.grid.height)
	_fx.solid_at = func(c: Vector2i) -> bool: return FxDecals.solid_in(state, c)
	_fx.space_at = func(c: Vector2i) -> bool: return FxDecals.space_in(state, c)
	_furniture_look = host._furniture_look.duplicate(true)
	_furniture_look_of = [state.grid, GridCell.look_version]
	image_memory = _clone_board(host._fog_mem.get(image_viewer, host.state.grid))
	image_memory.furniture_turn = image_memory.furniture_turn.duplicate(true)
	image_memory.map_decals = image_memory.map_decals.duplicate(true)
	image_memory.map_items = image_memory.map_items.duplicate(true)
	for cell: GridCell in image_memory.cells_flat(): cell.lamps = cell.lamps.duplicate(true)
	_fog_mem_grid = state.grid
	_fog_mem[image_viewer] = image_memory
	_fog_mem_viewer = image_viewer
	_fog_mem_dmg[image_viewer] = host._fog_mem_dmg.get(image_viewer, host._fx.floor_damage).duplicate()
	var known_fx := FxDecals.new()
	var remembered: DecalMemory = host._fog_mem_fx.get(image_viewer)
	known_fx.restore_state((remembered.view if remembered != null else host._fx).capture_state())
	_fog_mem_fx[image_viewer] = DecalMemory.new(known_fx)
	var bodies := {}
	for at: Vector2i in host._fog_mem_corpses.get(image_viewer, {}):
		var entry: Array = host._fog_mem_corpses[image_viewer][at]
		bodies[at] = [state.get_unit(entry[0].id) if entry[0] != null else null, entry[1]]
	_fog_mem_corpses[image_viewer] = bodies
	GridCell.logs_restore(logs)
	zoom = float(pixels_per_cell) / CELL
	_hud_width = 0

func _ready() -> void:
	_make_unit_layers()
	_build_ground()
	_build_sky()
	_sync_board_smoke()
	if _sky != null: _sky.set_process(false)
	if image_lighting:
		_lighting = LightManager.new()
		_lighting.z_index = 2
		_lighting.flicker = false
		add_child(_lighting)
	else:
		_sync_time_tint(LightManager.flat_tint(state.env, state.time_of_day))
	set_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	set_process_unhandled_key_input(false)

func prepare_section(offset: Vector2i, margin: int, size: Vector2i) -> void:
	pan = Vector2.ONE * margin - Vector2(offset) - ORIGIN * zoom
	_fit_ground()
	_sync_board_smoke()
	# The star background belongs to the complete image, not to each capture viewport.
	if _sky != null:
		_sky._sky.position = Vector2.ONE * margin - Vector2(offset)
		_sky._sky.size = Vector2(size)
		_sky._mat.set_shader_parameter("px", Vector2(size))
	_sync_lighting()
	queue_redraw()

func freeze_particles() -> void:
	# Let the normal preprocessed smoke appear once, then keep it identical across tiles.
	for particles: CPUParticles2D in _wreck_smoke.values(): particles.speed_scale = 0.0

func _sync_lighting() -> void:
	if _tiles != null:
		# Other matches/viewports share the global journal; this snapshot never changes.
		_tiles._look_ver = GridCell.look_version
		_tiles.set_time_of_day(state.time_of_day)
		_tiles.set_winter(state.winter)
		_tiles.set_grass(Ui.grass)
	if not image_lighting or _lighting == null: return
	var limited := resolver.visibility_limited()
	_lighting.extra_lights = drone_lights(image_viewer, image_seen, limited)
	_lighting.update_view(image_memory if limited else state.grid, pan, zoom, ORIGIN, CELL,
			state.env, image_seen, limited, _fx, _lod, -1.0, state.time_of_day)

func _viewing_side() -> int:
	return image_viewer

func _view_resolver() -> GameActionResolver:
	return resolver

func _visible_before_impact(_viewer: int) -> Dictionary:
	return image_seen

func _hidden_before_impact(_viewer: int) -> Variant:
	return image_hidden

func _board_memory(_viewer: int, _visible: Dictionary, _changed: Variant) -> Grid:
	return image_memory

func _anim_time() -> float:
	return image_time

func _sync_gas_drift() -> void:
	super._sync_gas_drift()
	(_gas_drift.material as ShaderMaterial).set_shader_parameter("fixed_time", image_time)
