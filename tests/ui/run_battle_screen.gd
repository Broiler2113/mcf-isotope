extends "res://tests/SuiteBase.gd"
## The battle screen: the Shoot button mid-burst, walking while the next is ordered, deaths
## shown on impact, held lanes, selection while panning, initiative and camera buttons,
## drawing, the cannon's label, capture controls.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	await _burst_button()
	await _move_while_walking()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	await _impact_in_battle()

	await _battle()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	await _shot_timing()

	MainScript = load("res://scenes/Main.gd")
	ManualWindowScript = load("res://src/ui/ManualWindow.gd")
	ManualTextScript = load("res://src/ui/ManualText.gd")
	BugReportScript = load("res://src/ui/BugReportWindow.gd")
	SettingsScript = load("res://src/ui/SettingsWindow.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.fog_mode = MCF.Fog.OFF
	for weapon in ["anti_tank", "tank"]:
		for roll in [1, 6]: _held_terrain(weapon, roll)
	await _shot_screen()

	await board_checks()

	await drawing_panel()

	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	await _selection()

	await heavy_capture_ui()

	_eraser_clears_pixels_where_it_went()

	_initiative_skips_empty_slots()
	_drawing_undo_restores_tiles()

	_deployment_initiative()
	_cannon_label()

## The battle menu keeps a plain "Shoot" button while bullets are left, even when the
## first target is gone (it used to grey out and read "Finish Burst").
func _burst_button() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(10, 10), "light_infantry", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	m.set_spawn(Vector2i(10, 6), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 10: await process_frame
	var st: GameState = main.state
	while st.active_player() != 0:
		main._on_intent_ready(EndTurnIntent.new())
		for i in 5: await process_frame
	var shooter := st.grid.cell(Vector2i(10, 10)).occupant
	var east := st.grid.cell(Vector2i(14, 10)).occupant
	shooter.remaining_ap = 1
	shooter.action_state = ActionState.new()
	shooter.action_state.target_id = east.id
	shooter.action_state.remaining_shots = 1
	shooter.remaining_ap = 0
	east.status = MCF.Status.CORPSE
	main.selected_id = shooter.id
	main._open_menu(shooter)
	var shoot: Button = null
	for b in main._menu.find_children("*", "Button", true, false):
		if str(b.get_meta("action_label", b.text)) == "Shoot": shoot = b
	ck(shoot != null and not shoot.disabled, "a burst with bullets left keeps an enabled Shoot button")
	main._enter_shoot()
	ck(shooter.action_state != null, "opening shoot mode no longer deletes the burst locally")
	main.queue_free()
	await process_frame

## While one of your soldiers walks, the next can already be ordered (0.11).
func _move_while_walking() -> void:
	var m := MapData.blank_arena(24, 16)
	m.set_spawn(Vector2i(2, 3), "light_infantry", 0)
	m.set_spawn(Vector2i(2, 9), "light_infantry", 0)
	m.set_spawn(Vector2i(21, 12), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 10: await process_frame
	var st: GameState = main.state
	while st.active_player() != 0:
		main._on_intent_ready(EndTurnIntent.new())
		for i in 5: await process_frame
	var a := st.grid.cell(Vector2i(2, 3)).occupant
	var b := st.grid.cell(Vector2i(2, 9)).occupant
	main._on_intent_ready(MoveIntent.new(a.id, Vector2i(6, 3)))
	await process_frame
	ck(not main._animating and main._walk_jobs.has(a.id), "a plain move animates without locking the screen")
	main._on_intent_ready(MoveIntent.new(b.id, Vector2i(6, 9)))
	await process_frame
	ck(b.coord == Vector2i(6, 9) and main._walk_jobs.has(a.id) and main._walk_jobs.has(b.id),
			"a second soldier is ordered while the first still walks")
	var waited := 0
	while main._walks_running > 0 and waited < 600:
		await process_frame
		waited += 1
	await process_frame
	ck(main._walks_running == 0 and main._walk_cells.is_empty(), "both walks finish and nobody is left drawn mid-way")
	main.queue_free()
	await process_frame

## On the battle screen a killed soldier stays standing until the bullet reaches them, and
## the blood appears with the hit, not when the dice stop.
func _impact_in_battle() -> void:
	var ui := root.get_node("/root/Ui")
	var autoroll: bool = ui.autoroll_dice
	ui.autoroll_dice = true
	var m := MapData.blank_arena(16, 8)
	m.set_spawn(Vector2i(2, 3), "light_infantry", 0)
	m.set_spawn(Vector2i(7, 3), "light_infantry", 1)
	m.set_spawn(Vector2i(15, 7), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 6: await process_frame
	while main.state == null or main._animating: await process_frame
	var st: GameState = main.state
	while st.active_player() != 0:
		main._on_intent_ready(EndTurnIntent.new())
		for i in 3: await process_frame
		while main._animating: await process_frame
	var shooter: UnitInstance = st.grid.cell(Vector2i(2, 3)).occupant
	var target: UnitInstance = st.grid.cell(Vector2i(7, 3)).occupant
	var res: ActionResult = null
	for attempt in 60:
		shooter.remaining_ap = 2
		shooter.action_state = null
		res = main.resolver.resolve(ShootIntent.new(shooter.id, target.id))
		if not target.is_alive():
			break
	var blood_before: int = main._fx.gore.size()
	main._show_result(res)
	var waited := 0
	while main._fx.tracers.is_empty() and waited < 2000:
		await process_frame
		waited += 1
	ck(not target.is_alive() and main._pending_death_ids.has(target.id) and main._fx.gore.size() == blood_before
			and main._fx.flying.filter(func(f: Dictionary) -> bool: return str(f["kind"]).begins_with("blood")).is_empty(),
			"while the bullet flies, the target still stands and there is no blood yet")
	await create_timer(0.6).timeout
	ck(not main._pending_death_ids.has(target.id), "the hit drops the target")
	ck(main._fx.gore.size() > blood_before or main._fx.flying.size() > 0, "and the blood comes with it")
	main.queue_free()
	await process_frame
	ui.autoroll_dice = autoroll

func _battle() -> void:
	var m := MapData.new(12, 12)
	m.env = "town"
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(9, 9), "light_infantry", 1)
	var battle: Variant = load("res://tests/fixtures/GroundBackgroundOnly.gd").new()
	battle.state = m.build_state(2)
	battle.resolver = GameActionResolver.new(battle.state)
	root.add_child(battle)
	battle._capture_opening_view()
	var unit: UnitInstance = battle.state.all_units()[0]
	var original: Vector2i = unit.coord
	var old_opening: Dictionary = battle._opening_state.duplicate(true)
	unit.coord = Vector2i(6, 6)
	battle._capture_opening_view()
	ck(battle._before_units[0][2] == original, "before/after retains the original battlefield after save capture")
	ck(battle._opening_state == old_opening, "opening snapshot does not advance with the live board")
	await battle._play_walk({"unit": unit.id, "from": original, "path": [original + Vector2i.RIGHT], "soldier": true})
	ck(battle._draw_cell(unit) == original + Vector2i.RIGHT, "walk endpoint does not snap to the simulation's final position")
	await battle._play_walk({"unit": unit.id, "from": original + Vector2i.RIGHT, "path": [original + Vector2i(2, 0)], "soldier": true})
	ck(battle._walks_running == 0 and battle._draw_cell(unit) == original + Vector2i(2, 0), "consecutive walks retain their ordered endpoints")
	ck(battle._defense_roll_speed([{"armor": 7}]) == 2.0, "impossible defense roll animates twice as fast")
	ck(battle._defense_roll_speed([{"need": 7}], "need") == 2.0, "grenade defense uses its own threshold")
	ck(battle._defense_roll_speed([{"armor": 6}]) == 1.0, "possible defense keeps normal speed")
	battle.state.turns.round_number = 9
	battle.state.deaths[0] = 4
	battle._real_start_ms = Time.get_ticks_msec() - 73000
	var payload: Dictionary = JSON.parse_string(JSON.stringify(battle._save_payload()))
	SaveHandoff.pending_save = payload
	ck(battle._adopt_save(), "saved match loads")
	battle._capture_opening_view()
	ck(battle.state.turns.round_number == 9 and int(battle.state.deaths[0]) == 4, "save preserves rounds and casualty ledger")
	ck(Time.get_ticks_msec() - battle._real_start_ms >= 73000, "real-time clock resumes at saved elapsed time")
	ck(battle._before_units[0][2] == original, "loading preserves the original Before map")
	battle._spectator = true
	battle._spectator_fog = true
	var rules: int = battle.resolver.fog_mode
	ck(not battle._can_control(0), "spectators cannot command any army")
	ck(battle._view_resolver() != battle.resolver and battle.resolver.fog_mode == rules, "spectator POV does not alter simulation rules")
	battle.state.roster.slots[0].peer_id = 1
	battle.state.roster.slots[1].peer_id = 77
	var net := NetGame.new(battle.state, battle.resolver, true)
	ck(not net._authorized(EndTurnIntent.new(1), 999), "unseated spectator cannot submit end turn")
	ck(not net._authorized(EndTurnIntent.new(0), 77), "guest cannot forge the host's end turn")
	ck(net._authorized(EndTurnIntent.new(1), 77), "seated guest can submit its own end turn")
	var guest := NetGame.new(battle.state, battle.resolver, false, 1)
	var messages: Array = []
	guest.outgoing.connect(func(msg: Dictionary) -> void: messages.append(msg))
	guest.submit_local(EndTurnIntent.new())
	guest.submit_local(EndTurnIntent.new())
	ck(messages.size() == 1 and IntentCodec.decode(messages[0]["i"]).requester == 1,
		"repeated guest end-turn clicks send one request with its authenticated seat")
	guest.receive({"k": NetGame.K_DENIED, "a": -1, "p": 1, "reason": "Not your turn"})
	guest.submit_local(EndTurnIntent.new())
	ck(messages.size() == 2, "host rejection releases the pending end-turn request")
	# Vehicle orders carry the vehicle's id, not a soldier's (0.10.1).
	var tm := MapData.blank_arena(16, 12)
	tm.set_spawn(Vector2i(3, 3), "tank", 0, Vector2i(1, 0))
	tm.set_spawn(Vector2i(11, 7), "tank", 1, Vector2i(-1, 0))
	var ts := tm.build_state(5)
	ts.roster.slots[0].peer_id = 1
	ts.roster.slots[1].peer_id = 77
	var tnet := NetGame.new(ts, GameActionResolver.new(ts), true)
	var mine: Vehicle = null
	var theirs: Vehicle = null
	for v: Vehicle in ts.all_vehicles():
		if v.owner == 1: mine = v
		else: theirs = v
	ck(tnet._authorized(VehicleMoveIntent.new(mine.id, Vector2i(-1, 0)), 77)
			and tnet._authorized(VehicleTurnIntent.new(mine.id, Vector2i(0, 1)), 77)
			and tnet._authorized(VehicleCannonIntent.new(mine.id, Vector2i(3, 3)), 77),
		"guest can drive, turn and fire its own tank")
	ck(not tnet._authorized(VehicleMoveIntent.new(theirs.id, Vector2i(1, 0)), 77), "guest cannot drive the host's tank")

	battle.queue_free()
	await process_frame

func _shot_timing() -> void:
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	root.get_node("Ui").autoroll_dice = false
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(3, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(8, 5), "light_infantry", 1)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	var shooter: UnitInstance = main.state.grid.cell(Vector2i(3, 5)).occupant
	var target: UnitInstance = main.state.grid.cell(Vector2i(8, 5)).occupant
	# Exercise actual local actions plus the replay and queued network presentation paths.
	for path in ["local", "replay", "network"]:
		shooter.remaining_ap = 3
		shooter.action_state = null
		main.state.dice.feed_scripted([6, 6])
		main._fx.clear()
		var intent := ShootIntent.new(shooter.id, target.id, 1)
		if path == "local":
			main._on_intent_ready(intent)
		else:
			var res: ActionResult = main.resolver.resolve(intent)
			ck(res.ok, path + " shot resolves")
			if path == "replay": main._show_result(res)
			else: main._show_net_action(intent, res)
		await process_frame
		ck(main._dice._roll_btn.visible, path + " waits for the attack roll")
		ck(_only_held_lane_to(main._fx, target.coord) and main._fx.tracers.is_empty() and main._fx.shots.is_empty(), path + " shows only a held lane to the target (no flash, no bullets) before attack dice")
		main._dice._roll_btn.pressed.emit()
		await main._dice.finished
		await process_frame
		ck(main._dice._roll_btn.visible, path + " waits for the defense roll")
		ck(_only_held_lane_to(main._fx, target.coord) and main._fx.tracers.is_empty(), path + " shows only a held lane to the target (no flash, no bullets) before defense dice")
		main._dice._roll_btn.pressed.emit()
		var seen := false
		var deadline := Time.get_ticks_msec() + 10000
		while main._animating and Time.get_ticks_msec() < deadline:
			if not main._fx.tracers.is_empty():
				seen = true
				ck(not main._dice.visible and not main._fx.lanes.is_empty(), path + " launches muzzle flash and bullets together after dice")
				break
			await process_frame
		ck(seen, path + " eventually launches its bullet")
		while main._animating and Time.get_ticks_msec() < deadline: await process_frame
		ck(not main._animating, path + " presentation finishes")
	main.free()
	await process_frame

## Issues-fix-6 #1: who fires at whom shows before the dice — a held lane (no muzzle light)
## ending at the aimed target, never at where the bullets will land.
func _only_held_lane_to(fx: FxDecals, at: Vector2i) -> bool:
	return fx.lanes.size() == 1 and fx.lanes[0].get("hold", false) \
			and fx.lanes[0]["to"] == Vector2(at) + Vector2(0.5, 0.5)

var MainScript: GDScript

var ManualWindowScript: GDScript

var ManualTextScript: GDScript

var BugReportScript: GDScript

var SettingsScript: GDScript

func state_of(m: MapData) -> GameState:
	var st := m.build_state(77)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

func terrain_bytes(grid: Grid) -> Array:
	var tiles := TerrainTiles.new(grid, "station")
	tiles._build(Vector2i.ZERO, 32)
	var chunk: Dictionary = tiles._chunks[Vector3i(0, 0, 32)]
	return [chunk.floor.get_image().get_data(), chunk.feat.get_image().get_data()]

func _held_terrain(weapon: String, roll: int) -> void:
	var m := MapData.blank_arena(16, 12)
	m.env = "station"
	m.set_spawn(Vector2i(2, 4) if weapon == "tank" else Vector2i(3, 5), weapon, 0, Vector2i.RIGHT)
	if weapon == "tank": m.set_spawn(Vector2i(1, 4), "engineer", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	for y in range(2, 10):
		m.set_cell(Vector2i(10, y), 0, 2.0, false, MCF.FEATURE_AIRLOCK if y == 6 else MCF.FEATURE_WALL)
		m.set_look(y * m.width + 10, MCF.wall_look(1) if y < 5 else 0)
	var st := state_of(m)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	var actor := st.grid.cell(Vector2i(3, 5)).occupant if weapon != "tank" else st.grid.cell(Vector2i(1, 4)).occupant
	var intent: Intent
	if weapon == "tank":
		var tank: Vehicle = st.all_vehicles()[0]
		ck(r.resolve(VehicleBoardIntent.new(actor.id, tank.id)).ok, "tank crew boards")
		tank.ap = 3
		intent = VehicleCannonIntent.new(tank.id, Vector2i(10, 5))
	else: intent = ShootIntent.new(actor.id, -1, -1, Vector2i(10, 5))
	r.update_airlocks()
	var before := terrain_bytes(st.grid)
	var before_seen := r.team_visible_coords(0).duplicate()
	st.dice.feed_scripted([roll, 6, 6, 6, 6, 6])
	var res := r.resolve(intent)
	ck(res.ok and not res.visual_hold.is_empty(), "%s roll %d captures the terrain" % [weapon, roll])
	if not res.ok: return
	var main = MainScript.new()
	main._hold_visual = res.visual_hold
	var digest := st.digest_hash()
	var logs := GridCell.logs_snapshot()
	var held: Grid = main._terrain_before_impact(st.grid, {}, false)
	ck(terrain_bytes(held) == before, "%s roll %d preserves every rendered floor, wall material, neighbour join and door before impact" % [weapon, roll])
	ck(st.digest_hash() == digest and GridCell.logs_snapshot() == logs, "presentation snapshot never mutates game state or journals")
	ck(res.visual_hold.get("visible", {}).get(0) == before_seen, "shot holds pre-impact fog visibility")
	ck(held.cell(Vector2i(10, 6)).feature_id == MCF.FEATURE_AIRLOCK and held.cell(Vector2i(10, 6)).is_wall(), "held airlock stays closed")
	main._hold_visual = {}
	ck(main._terrain_before_impact(st.grid, {}, false) == st.grid, "impact releases the complete live terrain")
	main.free()

func _shot_screen() -> void:
	root.get_node("Ui").autoroll_dice = false
	GameConfig.fog_mode = MCF.Fog.STANDARD
	var m := MapData.blank_arena(16, 12)
	m.env = "station"
	m.set_spawn(Vector2i(3, 5), "anti_tank", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	for y in range(2, 10): m.set_cell(Vector2i(10, y), 0, 2.0, false, MCF.FEATURE_AIRLOCK if y == 6 else MCF.FEATURE_WALL)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	var actor: UnitInstance = main.state.grid.cell(Vector2i(3, 5)).occupant
	main.state.dice.feed_scripted([6])
	main._on_intent_ready(ShootIntent.new(actor.id, -1, -1, Vector2i(10, 5)))
	await process_frame
	await process_frame
	ck(main._dice.visible and main._shown_grid.cell(Vector2i(10, 5)).is_wall(), "actual shot UI keeps wall intact while dice are shown")
	ck(main._shown_grid.cell(Vector2i(10, 6)).is_wall(), "actual shot UI keeps airlock closed before roll")
	var visible: Dictionary = main._visible_before_impact(0)
	main._lod_sync(true, 0, visible, true)
	ck(main._shown_grid.cell(Vector2i(10, 5)).is_wall(), "zoomed-out terrain also holds wall")
	if main._dice._roll_btn.visible: main._dice._roll_btn.pressed.emit()
	var deadline := Time.get_ticks_msec() + 10000
	while main._animating and Time.get_ticks_msec() < deadline: await process_frame
	await process_frame
	ck(not main._animating and main._hold_visual.is_empty() and not main._shown_grid.cell(Vector2i(10, 5)).is_wall(), "impact releases destroyed walls in actual playback")
	main.free()
	GameConfig.fog_mode = MCF.Fog.OFF

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func board_checks() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 4), "machinegunner", 0)
	map.set_spawn(Vector2i(8, 4), "heavy_infantry", 1)
	map.set_spawn(Vector2i(3, 9), "heavy_infantry", 1)
	MapHandoff.pending = map
	var board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	board.state.turns.round_order.assign([0, 1])
	board.state.turns.active_index = 0
	board._refresh_status()
	board._fx.audio_suppressed = false
	var heard := [0]
	board._fx.sound_requested.connect(func(id: String, _c: Vector2i, _o: int) -> void:
		if id == "mg": heard[0] += 1)
	board._fx.volley_requested.connect(func(id: String, _c: Vector2i, _o: int, n: int) -> void:
		if id == "mg": heard[0] += n)
	var mg: UnitInstance = board.state.grid.cell(Vector2i(3, 4)).occupant
	mg.remaining_ap = 3
	for target_cell: Vector2i in [Vector2i(8, 4), Vector2i(3, 9)]:
		heard[0] = 0
		board.state.dice.feed_scripted([1, 1, 1, 1, 1, 1, 1, 1])
		var target: UnitInstance = board.state.grid.cell(target_cell).occupant
		board._submit(ShootIntent.new(mg.id, target.id))
		for i in 600:
			await process_frame
			if board._dice._roll_btn.visible: board._dice._roll_btn.pressed.emit()   # the defender's Roll
			if i > 5 and not board._animating and not board._fx.lanes.any(func(l: Dictionary) -> bool: return l.has("hold")): break
		ck(heard[0] == 4, "a four-round burst at %s is heard as four shots (%d)" % [target_cell, heard[0]])
	board.queue_free()
	await process_frame

	# Holdout: the end-of-match fog toggle and the wave camera buttons.
	GameConfig.game_mode = MatchMode.Kind.HOLDOUT
	GameConfig.random_events_enabled = false
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	GameConfig.roster = ro
	var hmap := MapData.blank_arena(30, 20)
	hmap.set_spawn(Vector2i(14, 10), "heavy_infantry", 0)
	for y in 20:
		hmap.set_cell(Vector2i(24, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	MapHandoff.pending = hmap
	board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	board.resolver.fog_enabled = true
	board.resolver.fog_mode = MCF.Fog.STANDARD
	var wave: UnitInstance = board.state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(15, 10), board.resolver.mode.wave_side)
	wave.neutral_group = 1
	var far_wave: UnitInstance = board.state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(29, 0), board.resolver.mode.wave_side)
	far_wave.neutral_group = 2
	var targets: Dictionary = board._force_camera_targets(true)
	ck(targets.has(1) and not targets.has(2), "a camera button for the visible wave only, under fog")
	ck(board._force_camera_targets(false).is_empty(), "waves are not listed with the raiders")
	board._match_over = true
	board._refresh_status()
	ck(board._reveal_btn.visible, "after the match the 'Show the whole board' toggle appears")
	board._reveal_btn.button_pressed = true
	ck(not board._view_resolver().visibility_limited(), "…and turns off the fog of war")
	board.queue_free()
	await process_frame
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

func drawing_panel() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	MapHandoff.pending = map
	var board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	ck(board.DRAW_COLOURS[0].a > 0.0 and board._draw_colour == board.DRAW_COLOURS[0], "the first and default colour is not the faction colour")
	var crosses: Array = board._draw_panel.find_children("*", "Button", true, false).filter(
		func(b: Button) -> bool: return b.text == "×")
	ck(crosses.is_empty(), "the drawing panel has no close cross")
	board._draw_panel.visible = true
	board._menu.position = Vector2(12, 44)
	board._menu.size = Vector2(220, 300)
	board._menu.visible = true
	board._reposition_hud_grip()
	ck(board._draw_panel.position.x >= board._menu.position.x + board._menu.size.x, "the drawing panel steps right of an open action menu")
	board._menu.visible = false
	board._reposition_hud_grip()
	ck(is_equal_approx(board._draw_panel.position.x, 12.0), "and comes back when the menu closes")
	board.queue_free()
	await process_frame

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

func arena__player_reports() -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 5), "light_infantry", 1)
	var s := map.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

func heavy_capture_ui() -> void:
	var r := arena__player_reports()
	var s := r.state
	var captive := s.grid.cell(Vector2i(2, 5)).occupant
	var captor := s.grid.cell(Vector2i(18, 5)).occupant
	captive.stats = load("res://src/data/units/heavy_infantry.tres")
	captor.stats = captive.stats
	s.grid.move_occupant(captor.coord, Vector2i(3, 5))
	s.turns.active_index = 1
	s.dice.feed_scripted([6, 1])
	r.resolve(CaptureIntent.new(captor.id, captive.id))
	s.turns.active_index = 0
	SaveHandoff.pending_save = {"state": StateCodec.encode(s), "rules": StateCodec.encode_rules(r)}
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._paused = true
	main._select(main.state.get_unit(captive.id))
	main.state.dice.feed_scripted([6])
	# Exercise the combat UI's actual resolve/animation/menu refresh path.
	main._fast_playback = true
	main._submit(ReleaseIntent.new(captive.id))
	for i in 600:
		if not main._animating: break
		if main._dice._roll_btn.visible: main._dice._roll_btn.pressed.emit()
		await create_timer(0.01).timeout
	ck(not main._animating, "break-free animation finishes and restores combat controls")
	ck(main.state.get_unit(captive.id).is_alive(), "heavy infantry breaks free through the combat UI")
	main._enter_shoot()
	ck(main.target_ids.has(captor.id), "combat UI offers former heavy infantry captor as a shooting target")
	main.recorder = null
	main.queue_free()
	await process_frame

## 15: две линии кистью, ластик поперёк — стёрто ровно там, где прошёл ластик.
func _eraser_clears_pixels_where_it_went() -> void:
	var c := DrawCanvas.new()
	var red := Color(0.9, 0.2, 0.2)
	c.stroke(Vector2(10, 50), Vector2(300, 50), 4.0, red)
	c.stroke(Vector2(10, 150), Vector2(300, 150), 4.0, red)
	c.stroke(Vector2(150, 0), Vector2(150, 200), 12.0, Color(0, 0, 0, 0))
	var img: Image = c._tiles[Vector2i(0, 0)]["img"]
	ck(img.get_pixel(60, 50).a > 0.5 and img.get_pixel(240, 150).a > 0.5, "the brush leaves paint")
	ck(img.get_pixel(150, 50).a == 0.0 and img.get_pixel(150, 150).a == 0.0, "the eraser clears where it passed")
	ck(img.get_pixel(120, 50).a > 0.5 and img.get_pixel(180, 150).a > 0.5,
			"and only there — the rest of the line stays (no straight line re-joins the gap)")

## Prev/Next skip slots with nobody alive
func _initiative_skips_empty_slots() -> void:
	var tm := TurnManager.new()
	tm.round_order = [0, MCF.neutral_group_slot(3), 1, MCF.neutral_group_slot(5)]
	var alive0 := UnitInstance.new(1, load("res://src/data/units/light_infantry.tres"), Vector2i.ZERO, 0)
	var alive1 := UnitInstance.new(2, load("res://src/data/units/light_infantry.tres"), Vector2i.ZERO, 1)
	ck(tm.neighbor_slot(0, 1, [alive0, alive1]) == 1 and tm.neighbor_slot(0, -1, [alive0, alive1]) == 1,
			"Prev/Next skip empty neutral groups")
	ck(tm.neighbor_slot(0, 1) == MCF.neutral_group_slot(3), "old call (no units) unchanged")

## drawing undo restores the tiles exactly
func _drawing_undo_restores_tiles() -> void:
	var cv := DrawCanvas.new()
	cv.stroke(Vector2(10, 10), Vector2(60, 10), 4.0, Color.RED)
	var before_img: Image = (cv._tiles[Vector2i(0, 0)]["img"] as Image).duplicate()
	cv.begin_record()
	cv.stroke(Vector2(10, 40), Vector2(600, 40), 4.0, Color.BLUE)
	var rec := cv.end_record()
	ck(rec.size() == 3 and rec[Vector2i(1, 0)] == null, "record holds 3 tiles, new ones as null")
	cv.restore(rec)
	ck(cv._tiles.size() == 1 and (cv._tiles[Vector2i(0, 0)]["img"] as Image).get_data() == before_img.get_data(),
			"undo puts the canvas back pixel for pixel")
	cv.begin_record()
	cv.stroke(Vector2(10, 10), Vector2(60, 10), 6.0, Color(0, 0, 0, 0))
	rec = cv.end_record()
	cv.restore(rec)
	ck((cv._tiles[Vector2i(0, 0)]["img"] as Image).get_data() == before_img.get_data(), "erase undone too")

func field(w: int, h: int, spawns: Array, feats: Dictionary = {}, space: Array = []) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for c: Vector2i in feats:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, feats[c])
	for c: Vector2i in space:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, true, "")
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r}

## the purchase screen's initiative is the battle's
func _deployment_initiative() -> void:
	var same := true
	for seed in [1, 7, 42, 1234, 99999]:
		for n in [2, 3, 5]:
			var m := MapData.new(20, 10)
			for y in 10:
				for x in 20:
					m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
			for i in n:
				m.set_spawn(Vector2i(2 + i * 3, 2), "light_infantry", i)
			m.set_spawn(Vector2i(10, 8), "civilian", MCF.Owner.NEUTRAL)
			GameConfig.civilian_count = 5
			var bst := m.build_state(seed)
			var ids: Array = bst.roster.player_ids().duplicate()
			ids.sort()
			var shown := TurnManager.roll_order(ids, DiceService.new(seed), true)
			if shown != bst.turns.round_order:
				same = false
				print("   seed %d n %d: shown %s, battle %s" % [seed, n, shown, bst.turns.round_order])
	ck(same, "the initiative shown at purchase is the order the battle rolls")

## the cannon's label is the roll it makes
func _cannon_label() -> void:
	var fc := field(40, 12, [[Vector2i(2, 4), "light_infantry", 0], [Vector2i(2, 5), "light_infantry", 0],
			[Vector2i(2, 6), "light_infantry", 0], [Vector2i(3, 4), "tank", 0],
			[Vector2i(30, 5), "light_infantry", 1]])
	var cv: Vehicle = fc["s"].all_vehicles()[0]
	var rc: GameActionResolver = fc["r"]
	for i in 3:
		var bc: Array = rc.vehicle_board_candidates(cv)
		if not bc.is_empty():
			rc.resolve(VehicleBoardIntent.new(int(bc[0]), cv.id))
	cv.ap = 3
	var tgt := Vector2i(20, 5)
	var shown_need := rc.cannon_aim_need(cv, tgt)
	var cres := rc.resolve(VehicleCannonIntent.new(cv.id, tgt))
	var logged := -1
	for ev in cres.dice_events:
		if ev.has("need"):
			logged = int(ev["need"])
	ck(cres.ok and shown_need == logged, "the cannon label (%d+) is the roll it makes (%d+)" % [shown_need, logged])
