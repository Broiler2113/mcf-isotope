extends "res://tests/SuiteBase.gd"
## Fog on screen: the army hidden at deployment, the board as remembered, decals seen only in
## sight, drones over walls, gas seen only where we would see it.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_placement_fog()
	await _battle_screen()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_decal_memory()
	_drone_over_wall()
	_gas_sight()
	await _battle_screen__batch0113()

	_gas_visibility()
	await _memory_keeps_sight_journal()
	await _spare_memory_matches_clone()

## #1: under fog no enemy army on the deployment screen; without fog the lobby toggle rules.
func _placement_fog() -> void:
	var p: Node = load("res://scenes/Placement.gd").new()
	p.roster = Roster.default_duel(false)
	p.active_side = 0
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.live_placement_visible = true
	ck(p._army_hidden(1) and not p._army_hidden(0), "fog on: the other army is hidden, ours is not")
	GameConfig.fog_mode = MCF.Fog.OFF
	ck(not p._army_hidden(1), "fog off + live visibility: the other army shows")
	GameConfig.live_placement_visible = false
	ck(p._army_hidden(1), "fog off, live visibility off: even a ready army stays hidden")
	ck(not p._army_hidden(MCF.Owner.NEUTRAL), "map civilians always show")
	p.free()
	GameConfig.live_placement_visible = true
	var lobby: Node = load("res://scenes/Lobby.gd").new()
	lobby._fog_opt = OptionButton.new()
	for t in ["Off", "Standard", "Realistic"]: lobby._fog_opt.add_item(t)
	lobby._live_check = CheckBox.new()
	lobby._live_check.button_pressed = true
	lobby._fog_opt.select(1)
	lobby._sync_live_check()
	ck(not lobby._live_check.button_pressed and lobby._live_check.disabled, "lobby: fog locks live visibility off")
	lobby._fog_opt.select(0)
	lobby._sync_live_check()
	ck(not lobby._live_check.disabled, "lobby: without fog the box is a toggle again")
	lobby._fog_opt.free()
	lobby._live_check.free()
	lobby.free()

func _deploy(r: GameActionResolver, op: UnitInstance, at: Vector2i) -> void:
	op.held_item_id = MCF.ITEM_DRONE_STATION
	op.remaining_ap = 2
	var res := r.resolve(UseItemIntent.new(op.id, at))
	ck(res.ok, "station deployed at %s (%s)" % [at, res.reason])

func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01 and absf(a.a - b.a) < 0.01

# --- battle screen ---------------------------------------------------------------------

var _main: Node = null

func _battle_screen() -> void:
	var m := MapData.blank_arena(40, 14)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(4, 6), "drone_operator", 0)
	m.set_spawn(Vector2i(8, 2), "shuttle", 0)
	m.set_spawn(Vector2i(38, 12), "light_infantry", 1)
	m.set_spawn(Vector2i(36, 2), "heavy_infantry", 1)
	for y in 14:   # a solid wall: the east half is in the dark for the west
		m.set_cell(Vector2i(20, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	m.set_cell(Vector2i(30, 3), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(true)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	for i in 6: await process_frame
	while _main.state == null or _main._animating: await process_frame
	var st: GameState = _main.state
	var r: GameActionResolver = _main.resolver
	while st.active_player() != 0:
		_main._on_intent_ready(EndTurnIntent.new())
		for i in 3: await process_frame
		while _main._animating: await process_frame
	_main.queue_redraw()
	await process_frame
	var seen: Dictionary = r.team_visible_coords(0)
	ck(not seen.has(Vector2i(30, 6)) and seen.has(Vector2i(2, 3)), "the far east is in the dark")
	# --- #4/#16: the board as remembered
	st.grid.cell(Vector2i(30, 6)).set_feature(MCF.FEATURE_WALL)   # built in the dark
	st.grid.cell(Vector2i(30, 3)).clear_feature()                  # knocked down in the dark
	st.grid.cell(Vector2i(2, 4)).set_feature(MCF.FEATURE_SANDBAGS) # built in plain sight
	_main._lod_sync(false, 0, r.team_visible_coords(0), true)
	var mem: Grid = _main._shown_grid
	ck(mem != st.grid and _main._tiles._grid == mem, "under fog the board drawn is the remembered one")
	ck(not mem.cell(Vector2i(30, 6)).is_wall(), "a wall built in the dark does not show")
	ck(mem.cell(Vector2i(30, 3)).is_wall(), "a wall knocked down in the dark still shows")
	ck(mem.cell(Vector2i(2, 4)).feature_id == MCF.FEATURE_SANDBAGS, "sandbags built in sight show at once")
	_main._fx.floor_damage[Vector2i(30, 6)] = FxDecals.DAMAGE_RUBBLE   # blast in the dark
	_main._fx.floor_damage[Vector2i(3, 3)] = FxDecals.DAMAGE_RUBBLE    # blast in sight
	_main._fx.damage_version += 1
	_main._lod_sync(false, 0, r.team_visible_coords(0), true)
	var dmg: Dictionary = _main._fog_mem_dmg[0]
	ck(not dmg.has(Vector2i(30, 6)) and dmg.has(Vector2i(3, 3)), "rubble shows only where it was seen")
	ck(_main._tiles._damaged.has(Vector2i(3, 3)) and not _main._tiles._damaged.has(Vector2i(30, 6)),
			"the tiles draw the remembered rubble")
	var fog_img: Image = _main._lod_fog
	ck(_near(fog_img.get_pixel(30, 6), _main.FOG_COL) and fog_img.get_pixel(2, 3).a == 0.0,
			"standard fog: a grey veil on unseen cells only (%s)" % fog_img.get_pixel(30, 6))
	r.fog_mode = MCF.Fog.REALISTIC
	_main._lod_sync(false, 0, r.team_visible_coords(0), true)
	ck(_near(_main._lod_fog.get_pixel(30, 6), _main.UNKNOWN_COL),
			"realistic fog: unseen cells go black (%s)" % _main._lod_fog.get_pixel(30, 6))
	r.fog_mode = MCF.Fog.STANDARD
	# --- #5: refusals of unseen enemies stay out of the log
	var hidden := ActionResult.fail("Heavy Infantry cannot reach that cell")
	hidden.actor_owner = 1
	hidden.actor_from = Vector2i(36, 2)
	hidden.actor_to = Vector2i(36, 2)
	var lines := st.log.lines.size()
	_main._on_net_applied(MoveIntent.new(st.grid.cell(Vector2i(36, 2)).occupant.id, Vector2i(37, 2)), hidden)
	ck(st.log.lines.size() == lines, "an unseen enemy's refusal is not logged")
	var own := ActionResult.fail("own refusal")
	own.actor_owner = 0
	own.actor_from = Vector2i(2, 2)
	_main._on_net_applied(MoveIntent.new(st.grid.cell(Vector2i(2, 2)).occupant.id, Vector2i(2, 3)), own)
	ck(st.log.lines.size() == lines + 1, "our own refusal is")
	# --- #4: an unseen shooter's dice are not shown; our defence roll shows bare
	var attack := {"kind": "attack", "shooter": "Heavy Infantry", "target": "Light Infantry", "need": 4,
		"armor": 4, "killed": false, "shooter_owner": 1, "def_owner": 0,
		"hit_mods": [{"label": "Aimed", "delta": 1}], "def_mods": [{"label": "Cover", "delta": 1}],
		"shots": [{"hit_roll": 5, "need": 4, "hit": true, "def_roll": 3, "armor": 4, "parried": false}]}
	_main._play_dice([attack], true)
	await process_frame
	var prompt: String = _main._dice._prompt.text
	ck(_main._dice.visible and prompt.begins_with("You are under attack") and prompt.find("To-hit") < 0
			and prompt.find("Defence") < 0, "hidden attack: only the bare defence prompt '%s'" % prompt)
	_main._dice._roll_btn.pressed.emit()
	while _main._animating: await process_frame
	attack["def_owner"] = 1
	_main._play_dice([attack], true)
	await process_frame
	ck(not _main._animating and not _main._dice.visible, "hidden attack on someone else: no dice at all")
	# A shot that kills our last soldier was still seen by him.
	var ours: Array = st.all_units().filter(func(u: UnitInstance) -> bool: return u.owner == 0 and u.status == MCF.Status.ALIVE)
	for u: UnitInstance in ours: u.status = MCF.Status.CORPSE
	var kill := ActionResult.new()
	kill.actor_owner = 1
	kill.actor_from = Vector2i(10, 2)
	kill.actor_to = Vector2i(10, 2)
	ck(not _main._result_is_audible(kill), "no soldiers left: nothing is seen")
	kill.deaths.append((ours[0] as UnitInstance).id)
	ck(_main._result_is_audible(kill), "the soldier killed by the shot saw the shooter")
	ck((ours[0] as UnitInstance).status == MCF.Status.CORPSE, "and stays dead")
	for u: UnitInstance in ours: u.status = MCF.Status.ALIVE
	# --- #10: a drone whose operator walked off still opens a menu that says why
	var op: UnitInstance = st.grid.cell(Vector2i(4, 6)).occupant
	_deploy(r, op, Vector2i(5, 6))
	var drone := r.active_drone_of(op)
	st.grid.move_occupant(op.coord, Vector2i(4, 9))
	op.coord = Vector2i(4, 9)
	_main._select(drone)
	var labels: Array = []
	for c in _main._menu.find_children("*", "", true, false):
		if c is Button: labels.append((c as Button).text + ("(off)" if (c as Button).disabled else ""))
		elif c is Label: labels.append((c as Label).text)
	ck(_main._menu.visible and labels.any(func(t: String) -> bool: return t.begins_with("Fly") and t.ends_with("(off)"))
			and labels.any(func(t: String) -> bool: return t.begins_with("Detonate") and t.ends_with("(off)"))
			and labels.has("The operator must stand next to the station"), "drone menu explains itself: %s" % [labels])
	# --- #7: a drone over the shuttle is selectable; the click cycle reaches the shuttle
	var sh: Vehicle = null
	for v: Vehicle in st.all_vehicles(): sh = v
	drone.coord = sh.seat_cell(0)
	_main._deselect()
	_main._click_double = false
	_main._handle_click(sh.seat_cell(0))
	ck(_main.selected_id == drone.id, "first click over the shuttle takes the drone")
	_main._handle_click(sh.seat_cell(0))
	ck(_main.selected_vehicle_id == sh.id, "the next click takes the shuttle")
	drone.home_station = sh.seat_cell(0)
	ck(_main._veh_riders(sh).has(drone), "a drone docked in a seat flies with the shuttle")
	drone.home_station = Vector2i(5, 6)
	# --- #3: two stations next to the operator — the player picks one
	st.grid.move_occupant(op.coord, Vector2i(6, 7))
	op.coord = Vector2i(6, 7)
	drone.coord = drone.home_station
	st.grid.cell(Vector2i(7, 7)).set_feature(MCF.FEATURE_DRONE_STATION, 0)
	op.remaining_ap = 2
	_main._select(op)
	var pack: Button = null
	for c in _main._menu.find_children("*", "Button", true, false):
		if (c as Button).text.begins_with("Pack Up Drone Station ("): pack = c
	ck(pack != null, "two stations nearby: the button offers a choice")
	if pack != null:
		pack.pressed.emit()
		var choices: Array = _main._picker.find_children("*", "Button", true, false).filter(
				func(b: Button) -> bool: return b.text.find("Station at") >= 0)
		ck(_main._picker.visible and choices.size() == 2, "the picker lists both stations")
	# --- #6: drawing survives another player's actions and animations
	_main._deselect()
	_main._enter_draw()
	_main._deselect()
	ck(_main.mode == _main.Mode.DRAW, "deselect (another player's action) keeps the pen on")
	_main._animating = true
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(300, 300)
	_main._unhandled_input(press)
	ck(_main._stroke_drawing, "the pen draws while an animation plays")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	_main._unhandled_input(release)
	_main._animating = false
	# --- #8: colours
	_main._draw_colour = Color("#e04545")
	ck(_main._brush_colour() == Color("#e04545"), "the chosen swatch colours the pen")
	_main._draw_colour = Color(0, 0, 0, 0)
	ck(_main._brush_colour() == _main._side_color(0), "the first swatch is the side's colour")
	_main._on_remote_stroke({"a": 0, "s": 2, "c": [400.0, 400.0, 401.0, 400.0], "w": 3, "col": "3cc8e0"})
	var cv: DrawCanvas = _main._canvas(0, 2)
	var t: Dictionary = cv._tiles[Vector2i(1, 1)]
	ck((t["img"] as Image).get_pixel(400 - 256, 400 - 256).is_equal_approx(Color("#3cc8e0")),
			"a stroke from the network keeps its colour")
	# --- #15: a player leaving saves the game
	st.roster.slot(1).kind = Roster.SlotKind.HUMAN
	st.roster.slot(1).peer_id = 77
	_main._on_peer_left(77)
	var saved: Array = Array(st.log.lines).filter(func(l: String) -> bool: return l.begins_with("- Game saved as autosave"))
	ck(saved.size() == 1, "a leaver autosaves: %s" % [saved])
	if saved.size() == 1:
		var fname: String = str(saved[0]).trim_prefix("- Game saved as ").trim_suffix(" -")
		var path := ReplayFile.path_for(ReplayFile.SAVE_DIR, fname)
		ck(FileAccess.file_exists(path), "the autosave is on disk: %s" % path)
		DirAccess.remove_absolute(path)
	_main.queue_free()
	await process_frame

func _casing(fx: FxDecals, at: Vector2) -> Dictionary:
	var p := {"kind": "casing", "pos": at, "rot": 0.0, "scale": 1.0}
	fx._settle(fx.props, p)
	return p

func _held(mem: DecalMemory, p: Dictionary) -> bool:
	for list: Array in mem.view.by_chunk.values():
		for q: Dictionary in list:
			if is_same(q, p): return true
	return false

## #1: what lands in the dark is not shown until it is seen; what goes away in the dark
## stays until it is seen. Laser marks show only the part that was in sight.
func _decal_memory() -> void:
	var gw := 40
	var live := FxDecals.new()
	var mem := DecalMemory.new(live)
	var vis := {}
	for y in 14:
		for x in 20:
			vis[Vector2i(x, y)] = true
	var near := _casing(live, Vector2(3.5, 3.5))
	var far := _casing(live, Vector2(30.5, 6.5))
	mem.update(live, vis, [], gw)
	ck(_held(mem, near) and not _held(mem, far), "a casing in the dark is not shown, one in sight is")
	vis[Vector2i(30, 6)] = true
	mem.update(live, vis, [6 * gw + 30], gw)
	ck(_held(mem, far), "once the spot is seen the casing shows")
	vis.erase(Vector2i(30, 6))
	mem.update(live, vis, [6 * gw + 30], gw)
	ck(_held(mem, far), "and stays remembered after the spot goes dark")
	live._burn({"cells": [Vector2i(30, 6)]})
	ck(live.props.has(far), "fire leaves the casing where it lies (owner, 2026-10-19)")
	live.props.erase(far)   # gone in the dark some other way: kicked aside, undone
	live._reindex()
	mem.update(live, vis, [], gw)
	ck(_held(mem, far), "gone in the dark: still remembered")
	vis[Vector2i(30, 6)] = true
	mem.update(live, vis, [6 * gw + 30], gw)
	ck(not _held(mem, far), "looked again: it is gone")
	ck(mem.view.decal_dirty.has(Vector2i(1, 0)), "the tiles are told which chunk to rebake")
	vis.erase(Vector2i(30, 6))
	live._laser({"from": [2, 5], "to": [30, 5]})
	mem.update(live, vis, [], gw)
	ck(mem.view.laser_lines.size() == 1, "one laser mark in memory (%d)" % mem.view.laser_lines.size())
	if mem.view.laser_lines.size() == 1:
		var seg: Dictionary = mem.view.laser_lines[0]
		ck(Vector2(seg["from"]).is_equal_approx(Vector2(2.5, 5.5)) and Vector2(seg["to"]).is_equal_approx(Vector2(20, 5.5)),
				"only the seen part of the laser mark shows: %s → %s" % [seg["from"], seg["to"]])
	var all := {}
	for y in 14:
		for x in gw:
			all[Vector2i(x, y)] = true
	mem.update(live, all, null, gw)
	ck(mem.view.laser_lines.size() == 1 and is_same(mem.view.laser_lines[0], live.laser_lines[0]),
			"seen whole, the laser mark is exactly the live one")
	live._laser({"from": [2, 9], "to": [12, 9]})
	live.laser_lines = live.laser_lines.slice(1)   # FxDecals trims the oldest mark at its cap
	live.ground_version += 1
	mem.update(live, all, [], gw)
	ck(mem.view.laser_lines.size() == 1 and is_same(mem.view.laser_lines[0], live.laser_lines[0]),
			"a mark trimmed off at the cap goes, the new one shows (%d)" % mem.view.laser_lines.size())

## #4: under fog the cloud shows where we would see it if gas were clear — not behind a wall.
func _gas_sight() -> void:
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	for y in 12:
		m.set_cell(Vector2i(10, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var s := m.build_state(4)
	var r := GameActionResolver.new(s)
	r.random_events = RandomEvents.new()
	r._land_gas({"x": 6, "y": 3, "w": 8, "h": 5, "rounds": 3}, ActionResult.new())
	var seen := r.team_sees_gas(0)
	ck(seen.has(Vector2i(6, 5)) and seen.has(Vector2i(8, 5)) and seen.has(Vector2i(9, 7)),
			"the whole cloud in front of us shows, its middle too")
	ck(not seen.has(Vector2i(11, 5)) and not seen.has(Vector2i(13, 4)), "the cloud behind the wall does not")
	ck(not r.team_visible_coords(0).has(Vector2i(8, 5)), "and what is inside the gas stays hidden")

## #5: a drone hovering over a wall sees nothing past its own cell.
func _drone_over_wall() -> void:
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(5, 5), "drone_operator", 0)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	m.set_cell(Vector2i(8, 5), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var s := m.build_state(4)
	s.turns.round_order.assign([0, 1])
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	var op := s.grid.cell(Vector2i(5, 5)).occupant
	op.held_item_id = MCF.ITEM_DRONE_STATION
	op.remaining_ap = 2
	ck(r.resolve(UseItemIntent.new(op.id, Vector2i(6, 5))).ok, "station deployed")
	var drone := r.active_drone_of(op)
	ck(r.sight_of(drone) > 0, "a drone over the floor sees")
	drone.coord = Vector2i(8, 5)
	ck(r.sight_of(drone) == 0, "a drone over a wall has no sight")
	var seen := r._seen_from(drone.coord, r.sight_of(drone), 0)
	ck(seen.size() == 1 and seen[0] == 5 * s.grid.width + 8, "it sees only its own cell (%d cells)" % seen.size())
	drone.coord = Vector2i(9, 5)
	ck(r._seen_from(drone.coord, r.sight_of(drone), 0).size() > 10, "past the wall it sees again")

func _battle_screen__batch0113() -> void:
	var m := MapData.blank_arena(40, 14)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(38, 12), "light_infantry", 1)
	m.set_spawn(Vector2i(36, 2), "heavy_infantry", 1)
	for y in 14:   # a solid wall: the east half is in the dark for the west
		m.set_cell(Vector2i(20, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.roster = Roster.default_duel(false)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	for i in 6: await process_frame
	while _main.state == null or _main._animating: await process_frame
	var st: GameState = _main.state
	var r: GameActionResolver = _main.resolver
	while st.active_player() != 0:
		_main._on_intent_ready(EndTurnIntent.new())
		for i in 3: await process_frame
		while _main._animating: await process_frame
	var vis: Dictionary = r.team_visible_coords(0)
	ck(not vis.has(Vector2i(30, 6)) and vis.has(Vector2i(3, 3)), "the far east is in the dark")
	# --- #1 decals through the battle screen: tiles and far view
	var fx: FxDecals = _main._fx
	var dark := _casing(fx, Vector2(30.5, 6.5))
	var lit := _casing(fx, Vector2(3.5, 3.5))
	fx.floor_damage[Vector2i(31, 8)] = FxDecals.DAMAGE_RUBBLE   # blast in the dark
	fx.floor_damage[Vector2i(4, 8)] = FxDecals.DAMAGE_RUBBLE    # blast in sight
	fx.damage_version += 1
	_main._lod_sync(false, 0, vis, true)
	var tile_decals: Array = []
	for list: Array in _main._tiles.decals.values(): tile_decals.append_array(list)
	ck(tile_decals.any(func(p: Dictionary) -> bool: return is_same(p, lit))
			and not tile_decals.any(func(p: Dictionary) -> bool: return is_same(p, dark)),
			"the tiles bake the casing in sight, not the one in the dark")
	_main._lod_sync(true, 0, vis, true)
	var img: Image = _main._lod_terrain
	ck(img.get_pixel(31, 8) == img.get_pixel(32, 8), "far view: no rubble from a blast in the dark")
	ck(img.get_pixel(4, 8) != img.get_pixel(5, 8), "far view: rubble in sight shows")
	ck(img.get_pixel(30, 6) == img.get_pixel(32, 6), "far view: no casing tint in the dark")
	ck(img.get_pixel(3, 3) != img.get_pixel(5, 3), "far view: the casing in sight tints its cell")
	# --- #1 corpses: one falls in the dark, one in sight
	var foe: UnitInstance = st.grid.cell(Vector2i(36, 2)).occupant
	foe.status = MCF.Status.CORPSE
	st.grid.cell(Vector2i(4, 4)).corpse_count = 2
	GridCell.corpse_version += 1
	_main.queue_redraw()
	await process_frame
	var cmem: Dictionary = _main._fog_mem_corpses.get(0, {})
	ck(_main._corpse_map().has(Vector2i(36, 2)) and not cmem.has(Vector2i(36, 2)),
			"a soldier who died in the dark is not shown")
	ck(cmem.has(Vector2i(4, 4)) and int(cmem[Vector2i(4, 4)][1]) == 2, "a pile in sight is shown with its count")
	st.grid.cell(Vector2i(4, 4)).corpse_count = 0
	GridCell.corpse_version += 1
	_main.queue_redraw()
	await process_frame
	ck(not _main._fog_mem_corpses[0].has(Vector2i(4, 4)), "a pile carried off in sight disappears")
	foe.status = MCF.Status.ALIVE
	# --- #7 before/after under fog
	ck(not _main._before_known(1, [Vector2i(36, 2)], 0), "before/after: the enemy's start in the dark is hidden")
	ck(_main._before_known(0, [Vector2i(2, 2)], 0), "before/after: our own start shows")
	ck(_main._before_seen.get(0, {}).has(Vector2i(3, 3)), "before/after remembers what we saw at the start")
	r.fog_mode = MCF.Fog.OFF
	ck(_main._before_known(1, [Vector2i(36, 2)], 0), "fog off: before/after shows everyone")
	r.fog_mode = MCF.Fog.STANDARD
	# --- #3 raiders: the AI speed row appears and their turn plays at that speed
	_main._refresh_ai_speed_row()
	ck(_main._ai_speed_row != null and not _main._ai_speed_row.visible, "no AI and no raiders: no AI speed row")
	var raider: UnitInstance = st.grid.cell(Vector2i(38, 12)).occupant
	raider.owner = MCF.INDEPENDENT_BASE
	_main._refresh_ai_speed_row()
	ck(_main._ai_speed_row.visible, "raiders on the board: the AI speed row shows")
	GameConfig.ai_speed = 4.0
	_main._playing_slot = MCF.INDEPENDENT_BASE
	ck(is_equal_approx(_main._pace(), 4.0), "a raider turn plays at the AI speed (%s)" % _main._pace())
	_main._playing_slot = -1
	GameConfig.ai_speed = 1.0
	raider.owner = 1
	_main.queue_free()
	await process_frame

func _arena() -> GameState:
	var m := MapData.blank_arena(16, 12)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(12, 5), "light_infantry", 1)
	var s := m.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	return s

func _gas_visibility() -> void:
	var s := _arena()
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	var own := s.grid.cell(Vector2i(2, 5)).occupant
	var enemy := s.grid.cell(Vector2i(12, 5)).occupant
	s.grid.cell(Vector2i(8, 5)).set_feature(MCF.FEATURE_WALL)
	ck(r.is_visible_to_team(0, enemy), "fog off ignores ordinary walls")
	r.random_events.add_cloud(5, 1, 2, 10, 3)
	r._sync_gas()
	# Fog off (0.11.1, user rule; 0.11 showed it): gas hides what stands behind it too.
	ck(not r.is_visible_to_team(0, enemy) and r.can_shoot(own, enemy) != "",
		"fog off: an enemy behind gas is hidden and cannot be shot")
	r.random_events.clouds.clear()
	r.random_events.add_cloud(12, 5, 1, 1, 3)
	r._sync_gas()
	ck(not r.is_visible_to_team(0, enemy), "fog off: an enemy inside gas is hidden")
	var obs := preload("res://rl/ObsEncoder.gd").encode(r, 0, 20)
	ck(not obs["units"].any(func(u: Dictionary) -> bool: return int(u["own"]) == 1), "RLM observation cannot see enemy soldiers inside gas")
	r.random_events.clouds.clear()
	r.random_events.add_cloud(5, 1, 2, 10, 3)
	r._sync_gas()
	ck(r.team_sees(0, Vector2i(2, 10)), "gas mode retains unlimited range elsewhere")
	r.random_events.clouds.clear()
	r.random_events.add_cloud(2, 5, 1, 1, 3)
	r._sync_gas()
	ck(r.is_visible_to_team(0, own), "own soldier remains visible inside gas")
	ck(not r.is_visible_to_team(1, own), "enemy soldier inside gas is concealed")
	r.random_events.clouds.clear()
	r._sync_gas()
	ck(r.is_visible_to_team(0, enemy), "dissipating gas restores fog-off visibility through walls")
	# The scripted AI ignores fog; a cloud elsewhere must not blind it (0.10.1).
	r.fog_enabled = true
	r.omniscient_side = 1
	r.random_events.add_cloud(7, 1, 1, 1, 3)
	r._sync_gas()
	ck(r.is_visible_to_team(1, own), "fog-ignoring AI still sees soldiers outside gas")
	r.random_events.clouds.clear()
	r.random_events.add_cloud(2, 5, 1, 1, 3)
	r._sync_gas()
	ck(not r.is_visible_to_team(1, own), "fog-ignoring AI cannot see into gas")

## fix-7 #4: drawing the fog memory (copying newly seen cells into the remembered board)
## leaves the board's sight and walk journals alone; it used to log those copies at the same
## coordinates, and every soldier's cached view was thrown away and swept again.
func _memory_keeps_sight_journal() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.roster = Roster.default_duel(false)
	var m := MapData.blank_arena(30, 16)
	for y in range(3, 13):
		m.set_cell(Vector2i(12, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	m.set_spawn(Vector2i(4, 8), "light_infantry", 0)
	m.set_spawn(Vector2i(26, 8), "light_infantry", 1)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 4: await process_frame
	# The wall falls (as under a tank): the fog memory catches up on the next frames.
	for y in range(3, 13):
		main.state.grid.cell(Vector2i(12, y)).cover_height = 0.0
	main.resolver.team_visible_coords(main._viewing_side())
	var vv := GridCell.vision_version
	var wv := GridCell.walk_version
	for i in 4:
		main.queue_redraw()
		await process_frame
	ck(GridCell.vision_version == vv and GridCell.walk_version == wv,
			"remembering what came into view touches no sight or walk journal (%d->%d, %d->%d)" % [
			vv, GridCell.vision_version, wv, GridCell.walk_version])
	main.queue_free()
	await process_frame

## The next viewer's memory is grown a few rows per frame and handed over whole: it must be
## the board of that frame, exactly as a clone made then, and building it must leave the
## live board's sight, walk and look journals alone.
func _spare_memory_matches_clone() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var m := MapData.blank_arena(30, 16)
	for y in range(3, 13):
		m.set_cell(Vector2i(12, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	m.set_spawn(Vector2i(4, 8), "light_infantry", 0)
	m.set_spawn(Vector2i(26, 8), "light_infantry", 1)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	main._fog_spare_budget_usec = 0   # one row per frame
	root.add_child(main)
	await process_frame
	var grid: Grid = main.state.grid
	var rows: int = main._fog_spare.cells_flat().size() / grid.width if main._fog_spare != null else -1
	ck(rows >= 1 and rows < grid.height, "a fogless battle grows a spare memory row by row (%d rows)" % rows)
	# Changes to rows already built (the journal catches them up) and to rows not yet built.
	grid.cell(Vector2i(6, 0)).dirt_level = 1
	grid.cell(Vector2i(12, 3)).cover_height = 0.0
	grid.cell(Vector2i(2, 14)).on_fire = true
	var looks := [GridCell.vision_version, GridCell.walk_version, GridCell.look_version]
	main._fog_spare_step()
	ck([GridCell.vision_version, GridCell.walk_version, GridCell.look_version] == looks,
			"growing the spare writes no sight, walk or look journal")
	for i in grid.height + 2: await process_frame
	ck(main._fog_spare.cells_flat().size() == grid.width * grid.height, "the spare is complete")
	grid.cell(Vector2i(12, 9)).cover_height = 0.0
	grid.cell(Vector2i(20, 1)).dirt_level = 2
	grid.cell(Vector2i(2, 14)).on_fire = false
	var spare: Grid = main._fog_spare
	var mem: Grid = main._take_fog_spare(grid)
	ck(is_same(mem, spare) and main._fog_spare == null, "the complete spare is handed over")
	ck(_look_sig(mem) == _look_sig(main._clone_board(grid)), "the handed-over spare equals a clone of the board now")
	main.queue_free()
	await process_frame

static func _look_sig(g: Grid) -> int:
	var h := 0
	for c: GridCell in g.cells_flat():
		h = hash([h, c.floor_type, c.is_space, c.cover_height, c.feature_id, c.feature_durability,
				c.dirt_level, c.airlock_welded, c.on_fire, c.lamps, c.items_off])
	return hash([h, g.furniture_turn, g.floor_look, g.map_items])
