extends SceneTree
## Playtest-20 batch, battle screen: clock start, run-over / drone-blast confirmations,
## double-click to the shuttle, kills table, initiative overlay vs turn line, drawing undo,
## field works out of the baked tiles under fog.
var fails: PackedStringArray = []
var _main: Node = null
var _frames := 0
var _t0 := 0

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

func _initialize() -> void:
	var m := MapData.new(30, 16)
	for y in 16:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_cell(Vector2i(12, 12), MCF.FLOOR_NORMAL, 1.0, false, MCF.FEATURE_SANDBAGS)
	m.set_spawn(Vector2i(2, 4), "tank", 0, Vector2i(1, 0))
	m.set_spawn(Vector2i(1, 4), "light_infantry", 0)
	m.set_spawn(Vector2i(6, 5), "heavy_infantry", 0)
	m.set_spawn(Vector2i(2, 10), "shuttle", 0)
	m.set_spawn(Vector2i(1, 10), "light_infantry", 0)
	m.set_spawn(Vector2i(8, 13), "drone_operator", 0)
	m.set_spawn(Vector2i(27, 8), "light_infantry", 1)
	m.set_spawn(Vector2i(20, 2), "civilian", MCF.Owner.NEUTRAL)
	m.set_spawn(Vector2i(22, 2), "civilian", MCF.Owner.NEUTRAL)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 10
	GameConfig.roster = Roster.default_duel(false)
	_t0 = Time.get_ticks_msec()
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 5 or _main.state == null or _main._animating:
		return false
	var st: GameState = _main.state
	var r: GameActionResolver = _main.resolver
	while st.active_player() != 0:
		_main._on_intent_ready(EndTurnIntent.new())
		return false
	ck(_main._real_start_ms >= _t0 and _main._real_start_ms - _t0 < 5000, "real clock starts with the battle scene")
	var ui: CanvasLayer = _main._ui_layer
	# --- run-over confirmation
	var tank: Vehicle = null
	var shuttle: Vehicle = null
	for v: Vehicle in st.all_vehicles():
		if v.type_id == "tank": tank = v
		else: shuttle = v
	r.resolve(VehicleBoardIntent.new(st.grid.cell(Vector2i(1, 4)).occupant.id, tank.id))
	_main._select_vehicle(tank)
	_main._veh_enter_move()
	var dest := Vector2i(-1, -1)
	for c: Vector2i in _main.veh_move_targets:
		var mt: Dictionary = _main.veh_move_targets[c]
		if mt["dir"] == Vector2i(1, 0) and int(mt["steps"]) == 3:
			dest = c
	ck(dest != Vector2i(-1, -1), "a 3-step move east is offered")
	var kids := ui.get_child_count()
	var origin := tank.origin
	_main._handle_click(dest)
	ck(tank.origin == origin and ui.get_child_count() == kids + 1, "running over our heavy asks first")
	ui.get_child(ui.get_child_count() - 1).queue_free()
	# --- drone blast confirmation (the operator stands next to where we 'blow')
	var op: UnitInstance = st.grid.cell(Vector2i(8, 13)).occupant
	var fake_drone := UnitInstance.new(9999, load("res://src/data/units/drone.tres"), Vector2i(9, 13), 0)
	kids = ui.get_child_count()
	_main._confirm_blast(fake_drone, Vector2i(9, 13), EndTurnIntent.new())
	ck(ui.get_child_count() == kids + 1 and st.active_player() == 0, "a blast next to our operator asks first")
	ui.get_child(ui.get_child_count() - 1).queue_free()
	# --- double click picks the shuttle even when the rider was already selected
	var rider: UnitInstance = st.grid.cell(Vector2i(1, 10)).occupant
	r.resolve(VehicleBoardIntent.new(rider.id, shuttle.id, Vehicle.DRIVER_SEAT))
	_main._deselect()
	_main._click_double = false
	_main._handle_click(rider.coord)
	ck(_main.selected_id == rider.id, "first click takes the rider")
	_main._handle_click(rider.coord)
	ck(_main.selected_vehicle_id == shuttle.id, "second click takes the shuttle")
	_main._handle_click(rider.coord)
	ck(_main.selected_id == rider.id, "third click back to the rider")
	_main._click_double = true
	_main._handle_click(rider.coord)
	_main._click_double = false
	ck(_main.selected_vehicle_id == shuttle.id, "a double click lands on the shuttle")
	# --- kills table
	st.kills = {tank.id: [3, 2], op.id: [1, 0]}
	var tbl: Control = _main._kills_table()
	var texts: Array = []
	for n in tbl.find_children("*", "Label", true, false):
		texts.append((n as Label).text)
	ck(texts.has("Tank") and texts.has("3") and texts.has("2") and texts.has("Drone Operator"),
			"kills table lists the tank (3/2) and the operator: %s" % str(texts))
	tbl.free()
	# --- initiative: an empty neutral group is neither 'Next' nor listed; a live one is
	var civs: Array = []
	for u in st.all_units():
		if MCF.is_neutral(u.owner):
			civs.append(u)
	var live_slot := MCF.neutral_group_slot(1)
	var dead_slot := MCF.neutral_group_slot(2)
	civs[0].owner = live_slot
	civs[1].owner = dead_slot
	civs[1].kill()
	st.turns.round_order.insert(st.turns.round_order.find(0) + 1, dead_slot)
	st.turns.round_order.append(live_slot)
	_main._refresh_status()
	ck(_main._turn_neighbors_label.text.find("Neutral II") < 0,
			"turn line skips the wiped-out group: '%s'" % _main._turn_neighbors_label.text)
	_main._refresh_initiative_overlay()
	var rows: Array = []
	for row in _main._init_overlay_body.get_children():
		rows.append((row.get_child(1) as Label).text)
	ck(rows.any(func(t: String) -> bool: return t.begins_with("Neutral I ") or t.begins_with("Neutral I —")),
			"the live neutral group is listed: %s" % str(rows))
	ck(not rows.any(func(t: String) -> bool: return t.find("Neutral II") >= 0), "the dead group is not")
	# --- drawing undo
	_main._draw_record_begin(0, 0)
	_main._cur_stroke = []
	_main._stroke_add(Vector2(100, 100))
	_main._stroke_add(Vector2(200, 100))
	_main._stroke_commit()
	_main._draw_record_end(0)
	ck(not _main._canvas(0, 0).is_empty(), "stroke drawn")
	_main._undo_my_drawing()
	ck(_main._canvas(0, 0).is_empty(), "undo drawing removes it")
	# --- fog keeps field works out of the baked tiles
	_main._lod_sync(false, 0, r.team_visible_coords(0), {}, true)
	ck(_main._tiles.skip_features.has(MCF.FEATURE_SANDBAGS) and _main._tiles.skip_features.has(MCF.FEATURE_TRENCH),
			"under fog, sandbags/trenches are drawn per visible cell, not baked")
	_main.queue_free()
	if fails.is_empty():
		print("main pt20: all hold")
		quit(0)
	else:
		printerr("main pt20: %d failure(s)" % fails.size())
		quit(1)
	return true
