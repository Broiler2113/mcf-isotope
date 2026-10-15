extends SceneTree

var failures: Array[String] = []
var MainScript: GDScript
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_armies()
	_mines()
	_solar()
	_cosmetic_undo()
	_texture_budget()
	await _selection()
	await _vehicle_timing()
	await _network_presentation()
	_shortcut()
	print("Reported issues: %d failure(s)" % failures.size())
	quit(0 if failures.is_empty() else 1)

func state_of(m: MapData, seed_value := 77) -> GameState:
	var st := m.build_state(seed_value)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

func _armies() -> void:
	GameConfig.independent_army_difficulty = 2
	var rules := NetHandoff.encode_rules()
	GameConfig.independent_army_difficulty = 0
	NetHandoff.apply_rules(rules)
	ck(GameConfig.independent_army_difficulty == 2, "host army difficulty reaches guests")
	var st := state_of(MapData.blank_arena(20, 12))
	var r := GameActionResolver.new(st)
	var portable := StateCodec.encode_rules(r)
	var restored := GameActionResolver.new(st)
	StateCodec.apply_rules(restored, JSON.parse_string(JSON.stringify(portable)))
	ck(restored.random_events.army_difficulty == 2, "army difficulty survives save/replay rules")
	var mix := []
	for level in 3:
		r.random_events.army_difficulty = level
		var copy := RandomEvents.new()
		copy.restore(JSON.parse_string(JSON.stringify(r.random_events.snapshot())))
		ck(copy.army_difficulty == level, "event state preserves difficulty %d" % level)
		var pool := r._independent_roster()
		var infantry := pool.count("light_infantry") + pool.count("heavy_infantry")
		mix.append([float(infantry) / pool.size(), float(pool.count("anti_tank")) / pool.size()])
	ck(mix[0][0] > mix[1][0] and mix[1][0] > mix[2][0] and mix[0][1] < mix[1][1] and mix[1][1] < mix[2][1], "higher difficulty trades basic infantry for anti-tank and specialists")
	GameConfig.independent_army_difficulty = 1

func _mines() -> void:
	for env in ["town", "field", "station", "bunker", "asteroid"]:
		var kinds := {}
		for seed_value in range(1, 8):
			var m := MapData.blank_arena(18, 14)
			m.env = env
			for y in range(1, 13):
				for x in range(1, 17):
					m.set_look(y * m.width + x, MCF.Look.PLATE)
			m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
			m.set_spawn(Vector2i(15, 11), "light_infantry", 1)
			var st := state_of(m, seed_value)
			var peer := state_of(m, seed_value)
			var r := GameActionResolver.new(st)
			var other := GameActionResolver.new(peer)
			st.dice.begin_record()
			r._start_minefield(ActionResult.new())
			peer.dice.feed_scripted(st.dice.take_log())
			other._start_minefield(ActionResult.new())
			ck(st.digest_hash() == peer.digest_hash() and peer.dice.scripted_remaining() == 0 and peer.dice.fallback_rolls == 0, "%s minefield seed %d is deterministic" % [env, seed_value])
			var count := 0
			for c: GridCell in st.grid.cells_flat():
				if c.feature_id not in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE]: continue
				kinds[c.feature_id] = true
				count += 1
				if c.occupant != null or c.feature_owner != GameActionResolver.OLD_MINE_OWNER:
					ck(false, "old mine avoids occupied cells and is hostile to every side")
			ck(count > 0 and count <= GameActionResolver.MINEFIELD_MAX, "%s field contains mines even on decorated flooring" % env)
		ck(kinds.has(MCF.FEATURE_MINE) and kinds.has(MCF.FEATURE_AV_MINE) and RandomEvents.available_for_map(RandomEvents.MINEFIELD, env, 0), "%s supports both personnel and anti-vehicle old mines" % env)

func _solar() -> void:
	for size in [0, 2]:
		for seed_value in [1, 4, 8]:
			var options := {"style": MapGen.Style.STATION, "size": size, "seed": seed_value}
			var g := MapGen.build(options)
			var repeat := MapGen.build(options)
			var panels := 0
			for i in g.w * g.h:
				if g.m.get_look(i) == MCF.Look.SOLAR: panels += 1
			ck(g._space_doors.size() >= 3 and panels >= 6, "station size %d seed %d has several solar arrays (%d panels)" % [size, seed_value, panels])
			ck(g.m.to_dict() == repeat.m.to_dict(), "solar generation is repeatable")

func vehicle_map() -> MapData:
	var m := MapData.blank_arena(26, 12)
	m.env = "town"
	m.set_spawn(Vector2i(1, 2), "tank", 0, Vector2i.RIGHT)
	m.set_spawn(Vector2i(0, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(10, 4), "light_infantry", 1)
	m.set_spawn(Vector2i(23, 9), "light_infantry", 1)
	m.set_cell(Vector2i(8, 2), 0, 2.0, false, MCF.FEATURE_WOOD_WALL)
	return m

func _cosmetic_undo() -> void:
	var st := state_of(vehicle_map())
	var r := GameActionResolver.new(st)
	var fx := FxDecals.new()
	fx.bounds = Vector2(st.grid.width, st.grid.height)
	r.capture_cosmetics = fx.capture_state
	r.restore_cosmetics = fx.restore_state
	fx.apply([{"fx": "blood", "at": Vector2i(20, 8), "seq": 50}])
	fx.advance(2.0)
	var tank: Vehicle = st.all_vehicles()[0]
	var crew := st.grid.cell(Vector2i(0, 2)).occupant
	ck(r.resolve(VehicleBoardIntent.new(crew.id, tank.id)).ok, "crew boards undo fixture")
	var before := fx.to_dict()
	var moved := r.resolve(VehicleMoveIntent.new(tank.id, Vector2i.RIGHT, 8))
	ck(moved.ok and r.can_undo(), "ramming and crushing remain undoable without dice")
	fx.apply(moved.fx)
	fx.advance(2.0)
	var after := fx.to_dict()
	ck(after != before and not fx.track_marks.is_empty(), "ram creates tracks and debris")
	ck(r.resolve(UndoIntent.new(0)).ok and fx.to_dict() == before, "undo removes only this drive's decals, preserving earlier blood")
	ck(r.resolve(RedoIntent.new(0)).ok and fx.to_dict() == after, "redo restores tracks and wall debris")
	# A sweep removes an existing particle and launches it elsewhere; undo must put it back.
	st = state_of(MapData.blank_arena(12, 10))
	var u := st.spawn_unit(StateCodec.load_stats("shield_bearer"), Vector2i(2, 2), 0)
	st.spawn_unit(StateCodec.load_stats("light_infantry"), Vector2i(10, 8), 1)
	r = GameActionResolver.new(st)
	fx = FxDecals.new()
	r.capture_cosmetics = fx.capture_state
	r.restore_cosmetics = fx.restore_state
	fx._settle(fx.props, {"kind": "casing", "pos": Vector2(3.5, 2.5), "rot": 0.0, "scale": 1.0})
	before = fx.to_dict()
	var step := r.resolve(MoveIntent.new(u.id, Vector2i(3, 2)))
	fx.apply(step.fx)
	ck(step.ok and not fx.flying.is_empty(), "walking scatters an existing casing")
	ck(r.resolve(UndoIntent.new(0)).ok and fx.to_dict() == before and fx.flying.is_empty(), "undo puts scattered items back and cancels their flights")

func _texture_budget() -> void:
	var st := state_of(MapData.blank_arena(40, 24))
	var tiles := TerrainTiles.new(st.grid, "town")
	for x in 2: tiles._build(Vector2i(x, 0), 8)
	var old: ImageTexture = tiles._chunks[Vector3i(1, 0, 8)].floor
	tiles._dirty[Vector2i.ZERO] = true
	tiles._dirty[Vector2i(1, 0)] = true
	tiles._built = 0
	tiles._choose(Vector2i.ZERO, 8)
	tiles._choose(Vector2i(1, 0), 8)
	ck(tiles._built == 1 and tiles._dirty.has(Vector2i(1, 0)) and tiles._chunks[Vector3i(1, 0, 8)].floor == old, "an explosion rebuilds one cached terrain chunk per frame, retaining a valid fallback")
	tiles._built = 0
	tiles._choose(Vector2i(1, 0), 8)
	ck(not tiles._dirty.has(Vector2i(1, 0)), "deferred explosion texture catches up on the next frame")

func make_main(m: MapData) -> Node:
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	return main

func _selection() -> void:
	var m := MapData.blank_arena(30, 20)
	for c in [Vector2i(2, 2), Vector2i(4, 3), Vector2i(12, 3), Vector2i(14, 4)]: m.set_spawn(c, "light_infantry", 0)
	m.set_spawn(Vector2i(27, 17), "light_infantry", 1)
	var main := make_main(m)
	await process_frame
	main._multi_btn.set_pressed_no_signal(true)
	main.pan = Vector2.ZERO
	main.zoom = 1.0
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = main.ORIGIN + Vector2(1.5, 1.5) * main.CELL
	main._unhandled_input(press)
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = main.ORIGIN + Vector2(5.5, 4.5) * main.CELL
	main._unhandled_input(motion)
	main.pan = Vector2(-8 * main.CELL, 0)
	ck(main._box_start_cell == Vector2i(1, 1), "selection start remains anchored as the camera pans")
	main._finalize_box()
	ck(main._group_ids.size() == 3, "camera movement expands the selection toward the cursor")
	main._box_dragging = false
	main._box_additive = true
	main._box_start_cell = Vector2i(13, 3)
	main._box_end_screen = main.pan + main.ORIGIN + Vector2(15, 5) * main.CELL
	main._finalize_box()
	ck(main._group_ids.size() == 4, "Shift box-selection adds a new group without dropping previous units")
	main._finalize_box()
	ck(main._group_ids.size() == 4, "overlapping Shift selections never duplicate units")
	ck(main._annotations.z_index > 2 and main._annotations.material.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED, "drawing layer is above dynamic lighting and ignores time-of-day tint")
	main.free()
	await process_frame

func _vehicle_timing() -> void:
	var main := make_main(vehicle_map())
	await process_frame
	var tank: Vehicle = main.state.all_vehicles()[0]
	var crew: UnitInstance = main.state.grid.cell(Vector2i(0, 2)).occupant
	main.resolver.resolve(VehicleBoardIntent.new(crew.id, tank.id))
	var victim: UnitInstance = main.state.grid.cell(Vector2i(10, 4)).occupant
	var result: ActionResult = main.resolver.resolve(VehicleMoveIntent.new(tank.id, Vector2i.RIGHT, 8))
	ck(result.ok and result.visual_hold.get("cells", {}).has(Vector2i(8, 2)) and result.visual_deaths.has(victim.id), "drive retains intact wall and live victim for presentation")
	main._show_net_action(VehicleMoveIntent.new(tank.id, Vector2i.RIGHT, 8), result)
	ck(main._hold_visual.get("cells", {}).has(Vector2i(8, 2)) and main._pending_death_ids.has(victim.id), "wall and victim stay unchanged at the start of the drive")
	var deadline := Time.get_ticks_msec() + 8000
	var progressed := false
	while main._animating and Time.get_ticks_msec() < deadline:
		if not main._hold_visual.get("cells", {}).has(Vector2i(8, 2)) and main._veh_offset.has(tank.id): progressed = true
		await process_frame
	ck(progressed, "wall breaks while the vehicle is still moving")
	ck(not main._animating and not main._pending_death_ids.has(victim.id) and not main._fx.track_marks.is_empty() and not main._fx.floor_damage.is_empty(), "drive finishes with casualties, debris and tracks visible")
	main.free()
	await process_frame

func _network_presentation() -> void:
	var m := MapData.blank_arena(18, 12)
	m.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	m.set_spawn(Vector2i(8, 4), "light_infantry", 1)
	m.set_spawn(Vector2i(15, 9), "light_infantry", 1)
	var main := make_main(m)
	await process_frame
	var shooter: UnitInstance = main.state.grid.cell(Vector2i(3, 4)).occupant
	var victim: UnitInstance = main.state.grid.cell(Vector2i(8, 4)).occupant
	main.state.dice.feed_scripted([6, 1])
	var shot: ActionResult = main.resolver.resolve(ShootIntent.new(shooter.id, victim.id, 1))
	ck(shot.ok and shot.visual_deaths.has(victim.id), "successful shot records its visual casualty")
	root.get_node("Ui").autoroll_dice = false
	main._show_net_action(ShootIntent.new(shooter.id, victim.id, 1), shot)
	await process_frame
	ck(main._pending_death_ids.has(victim.id) and not main._corpse_map().has(victim.coord), "network victim remains alive visually before attack and defense dice")
	main.net = NetGame.new(main.state, main.resolver, false, 1)
	var other: UnitInstance = main.state.grid.cell(Vector2i(15, 9)).occupant
	var target := Vector2i(14, 9)
	var packet := {"k": NetGame.K_ACTION, "i": IntentCodec.encode(MoveIntent.new(other.id, target)), "r": []}
	main._net_playing = true
	main._on_net_message(packet)
	ck(other.coord == Vector2i(15, 9) and main._net_messages.size() == 1, "later network actions cannot mutate the board while a roll is showing")
	# Finish both manual rolls, including their timer-driven presentation.
	var deadline := Time.get_ticks_msec() + 10000
	while main._animating and Time.get_ticks_msec() < deadline:
		if main._dice._roll_btn.visible: main._dice._roll_btn.pressed.emit()
		await process_frame
	main.state.turns.active_index = 1
	main._net_playing = false
	main._drain_net_messages()
	ck(other.coord == target and main._net_messages.is_empty(), "queued network movement reaches the exact requested tile after the shot")
	main.free()
	await process_frame

func _shortcut() -> void:
	var keys := root.get_node("Keybinds")
	ck(keys.codes("game_fullscreen").has(KEY_F11), "F11 is the default fullscreen shortcut")
	var path := "user://reported-issues-keybind-test.cfg"
	var key: InputEventKey = keys.key_event(KEY_MASK_CTRL | KEY_F11)
	key.pressed = true
	ck(keys.rebind("game_fullscreen", key, path).is_empty(), "fullscreen shortcut can be rebound")
	keys.load_bindings(path)
	ck(keys.matches(key, "game_fullscreen") and not keys.matches(keys.key_event(KEY_F11), "game_fullscreen"), "rebound fullscreen shortcut persists and replaces F11")
	var ui := root.get_node("Ui")
	var was_fullscreen: bool = ui.fullscreen
	keys._unhandled_key_input(key)
	ck(ui.fullscreen != was_fullscreen, "rebound shortcut actually toggles fullscreen")
	keys._unhandled_key_input(key)
	ck(ui.fullscreen == was_fullscreen, "fullscreen shortcut also restores windowed mode")
	keys.load_bindings("user://no-such-default-bindings.cfg")
	DirAccess.remove_absolute(path)
