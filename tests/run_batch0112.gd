extends SceneTree
## 0.11.2 batch (issues-fix-12): fog hides the enemy army on deployment, the board as the
## viewer remembers it, hidden dice and refusals, drone stations (choice, docked drones,
## shuttle seats), drone menu reasons, drawing tools, colours, artillery aim, autoroll,
## trench height, raiders entering bunkers by their hallways, autosave on leave.

var fails: PackedStringArray = []
func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond: fails.append(what)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_placement_fog()
	_station_rules()
	_shuttle_station()
	_barrage_aim()
	_bunker_raiders()
	ck(TerrainTiles.height_text(0.0, false, MCF.FEATURE_TRENCH) == "-2", "a trench reads -2 on the heightmap")
	await _autoroll()
	await _battle_screen()
	print("batch 0.11.2: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

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

## #3/#14: any own station next to an operator packs up; a docked drone goes with it, a
## flying one has to come back first.
func _station_rules() -> void:
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(5, 5), "drone_operator", 0)
	m.set_spawn(Vector2i(9, 5), "drone_operator", 0)
	m.set_spawn(Vector2i(5, 9), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 10), "drone_operator", 1)
	var s := m.build_state(4)
	s.turns.round_order.assign([0, 1])
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	var a := s.grid.cell(Vector2i(5, 5)).occupant
	var b := s.grid.cell(Vector2i(9, 5)).occupant
	var foe := s.grid.cell(Vector2i(18, 10)).occupant
	_deploy(r, a, Vector2i(6, 5))
	_deploy(r, b, Vector2i(8, 5))
	s.grid.cell(Vector2i(17, 10)).set_feature(MCF.FEATURE_DRONE_STATION, 1)
	var drone := r.active_drone_of(a)
	ck(drone != null and drone.coord == Vector2i(6, 5), "a fresh drone sits on its station")
	# b steps next to both stations (7,5 is between them)
	s.grid.move_occupant(b.coord, Vector2i(7, 4))
	b.coord = Vector2i(7, 4)
	b.remaining_ap = 2
	var cells := r.station_pickup_cells(b)
	ck(cells.has(Vector2i(6, 5)) and cells.has(Vector2i(8, 5)), "both own stations next to b can be packed: %s" % [cells])
	var inf := s.grid.cell(Vector2i(5, 9)).occupant
	ck(r.can_pick_up_station(inf, Vector2i(6, 5)) != "", "a rifleman cannot pack a station")
	r.resolve(DroneMoveIntent.new(drone.id, Vector2i(6, 8)))
	ck(r.can_pick_up_station(b, Vector2i(6, 5)).begins_with("Fly the drone back"), "a drone out flying blocks its station")
	drone.remaining_ap = 1
	r.resolve(DroneMoveIntent.new(drone.id, Vector2i(6, 5)))
	var res := r.resolve(PickUpStationIntent.new(b.id, Vector2i(6, 5)))
	ck(res.ok and b.held_item_id == MCF.ITEM_DRONE_STATION, "b packs a's station (%s)" % res.reason)
	ck(s.get_unit(drone.id) == null and s.grid.cell(Vector2i(6, 5)).feature_id == "", "the docked drone is packed with it")
	s.grid.move_occupant(a.coord, Vector2i(16, 10))
	a.coord = Vector2i(16, 10)
	a.remaining_ap = 2
	ck(r.can_pick_up_station(a, Vector2i(17, 10)) == "That station is not yours", "an enemy station is not ours to pack")

## #7/#14: a station in a shuttle seat keeps its operator through a flight, its drone flies
## with it, and it packs up from the seat.
func _shuttle_station() -> void:
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(4, 4), "shuttle", 0)
	m.set_spawn(Vector2i(3, 4), "drone_operator", 0)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	var s := m.build_state(6)
	s.turns.round_order.assign([0, 1])
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	var op := s.grid.cell(Vector2i(3, 4)).occupant
	var sh: Vehicle = s.all_vehicles()[0]
	ck(r.resolve(VehicleBoardIntent.new(op.id, sh.id, Vehicle.DRIVER_SEAT)).ok, "the operator takes the driver's seat")
	var spare := -1
	for i in sh.seats.size():
		if sh.seats[i] == -1 and Combat.distance(sh.seat_cell(i), op.coord) == 1:
			spare = i
	_deploy(r, op, sh.seat_cell(spare))
	var drone := r.active_drone_of(op)
	ck(drone != null and drone.coord == sh.seat_cell(spare), "the drone rises from the seat")
	op.remaining_ap = 2
	var mv := r.resolve(VehicleMoveIntent.new(sh.id, Vector2i(1, 0), 3))
	ck(mv.ok, "the shuttle flies 3 east (%s)" % mv.reason)
	var at := sh.seat_cell(spare)
	ck(s.grid.cell(at).station_operator_id == op.id, "the station keeps its operator through the flight")
	ck(drone.coord == at and drone.home_station == at, "the docked drone flew with it")
	var res := r.resolve(PickUpStationIntent.new(op.id, at))
	ck(res.ok and sh.seats[spare] == -1 and op.held_item_id == MCF.ITEM_DRONE_STATION,
			"packed up from the seat (%s)" % res.reason)

## #9: sleeping town civilians never draw the barrage; a lone soldier does.
func _barrage_aim() -> void:
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 100
	var m := MapData.blank_arena(30, 30)
	for i in 8:
		m.set_spawn(Vector2i(3 + i % 3, 3 + i / 3), "civilian", MCF.Owner.NEUTRAL)
	m.set_spawn(Vector2i(24, 24), "light_infantry", 0)
	var s := m.build_state(2)
	GameConfig.civilians_enabled = false
	var r := GameActionResolver.new(s)
	var sleepers := s.all_units().filter(func(u: UnitInstance) -> bool: return u.owner == MCF.Owner.NEUTRAL)
	ck(sleepers.size() == 8, "eight sleeping civilians on the board (%d)" % sleepers.size())
	ck(r._densest_spot(5, 5) == Vector2i(24, 24), "the barrage aims at the soldier, not the sleeping block")
	for u in s.all_units():
		if u.owner == MCF.Owner.NEUTRAL: u.owner = MCF.neutral_group_slot(1)
	ck(r._densest_spot(5, 5) != Vector2i(24, 24), "once the block wakes up it is a target")

## #13: on a bunker map the raiders come in through the end of a hallway, inside the bunker.
func _bunker_raiders() -> void:
	var m := MapGen.generate({"style": MapGen.Style.BUNKER, "size": 2, "seed": 7})
	var s := m.build_state(3)
	var r := GameActionResolver.new(s)
	r.random_events = RandomEvents.new(true, true, 1)
	var p := {"edge": 0, "from": 40, "len": 6}
	var entry := r._hallway_entry(p)
	ck(entry.x >= 0 and r.hallway_ends().has(entry), "a hallway end is picked: %s" % [entry])
	p["hx"] = entry.x
	p["hy"] = entry.y
	var before := s.all_units().size()
	var res := ActionResult.new()
	r._land_army(p, res)
	var raiders: Array = s.all_units().filter(func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner))
	ck(raiders.size() > 0 and s.all_units().size() == before + raiders.size(), "raiders landed (%d)" % raiders.size())
	var inside := raiders.all(func(u: UnitInstance) -> bool:
		return s.grid.cell(u.coord).walkable_terrain() and Combat.distance(u.coord, entry) <= 20)
	ck(inside, "every raider stands on bunker floor near the hallway end")
	ck(raiders.any(func(u: UnitInstance) -> bool: return u.coord == entry), "the first one stands at the hallway end")
	ck(str(res.log_lines).find("hallway") >= 0, "the log says where they broke in")

## #11: autoroll starts our own roll without a press.
func _autoroll() -> void:
	var ui := root.get_node_or_null("/root/Ui")
	ui.autoroll_dice = true
	var dice: Node = load("res://scenes/DiceRoller.gd").new()
	root.add_child(dice)
	var got := [false]
	dice.rolled.connect(func() -> void: got[0] = true)
	dice.play([{"value": 4, "good": true, "tag": "Pen 4+"}], true, "roll", 50.0)
	for i in 5: await process_frame
	ck(got[0] and not dice._roll_btn.visible, "autoroll: the roll starts on its own, no Roll button")
	ui.autoroll_dice = false
	dice.queue_free()

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
	var saved: Array = Array(st.log.lines).filter(func(l: String) -> bool: return l.begins_with("— Game saved as autosave"))
	ck(saved.size() == 1, "a leaver autosaves: %s" % [saved])
	if saved.size() == 1:
		var fname: String = str(saved[0]).trim_prefix("— Game saved as ").trim_suffix(" —")
		var path := ReplayFile.path_for(ReplayFile.SAVE_DIR, fname)
		ck(FileAccess.file_exists(path), "the autosave is on disk: %s" % path)
		DirAccess.remove_absolute(path)
	_main.queue_free()
	await process_frame
