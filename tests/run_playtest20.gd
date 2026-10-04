extends SceneTree
## Playtest-20 batch: tracks, kill ledger (+undo, codec), burnt bodies, run-over list,
## ruthless civilians, Prev/Next skipping dead slots, drawing undo, weld overlay.
var fails := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1

func _field(extra: Callable = Callable()) -> Dictionary:
	var m := MapData.new(26, 12)
	for y in 12:
		for x in 26:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(2, 4), "tank", 0, Vector2i(1, 0))
	m.set_spawn(Vector2i(1, 4), "light_infantry", 0)
	m.set_spawn(Vector2i(22, 9), "light_infantry", 1)
	if extra.is_valid():
		extra.call(m)
	GameConfig.civilians_enabled = false
	var st := m.build_state(777)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	var tank: Vehicle = st.all_vehicles()[0]
	r.resolve(VehicleBoardIntent.new(st.grid.cell(Vector2i(1, 4)).occupant.id, tank.id))
	return {"s": st, "r": r, "t": tank}

func _initialize() -> void:
	# --- run over an enemy: tracks fx, kill ledger [1,1], undo gives it back, codec keeps it
	var f := _field(func(m: MapData) -> void: m.set_spawn(Vector2i(5, 5), "light_infantry", 1))
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["t"]
	var foe: UnitInstance = st.grid.cell(Vector2i(5, 5)).occupant
	ck(r.vehicle_move_crushed_friends(tank, Vector2i(1, 0), 2).is_empty(), "an enemy in the path is not a 'friend'")
	var res := r.resolve(VehicleMoveIntent.new(tank.id, Vector2i(1, 0), 2))
	ck(res.ok and not foe.is_alive(), "the tank crushed the enemy: " + res.reason)
	var tracks := res.fx.filter(func(e: Dictionary) -> bool: return e["fx"] == "tracks")
	ck(tracks.size() == 1 and not tracks[0].has("seq"), "one tracks event, without an fx seq")
	ck(st.kills.get(tank.id, []) == [1, 1], "ledger: tank 1 kill, 1 run over (%s)" % str(st.kills))
	var fx := FxDecals.new()
	fx.apply(res.fx)
	ck(fx.track_marks.size() >= 4, "track marks laid (%d)" % fx.track_marks.size())
	fx._laser({"from": [1, 1], "to": [9, 1]})
	var back := FxDecals.new()
	back.from_dict(fx.to_dict())
	ck(back.track_marks.size() == fx.track_marks.size() and back.laser_lines.size() == fx.laser_lines.size(),
			"tracks and laser marks survive to_dict/from_dict (resync, save)")
	var copy := GameState.new(1, 1)
	StateCodec.restore_into(copy, StateCodec.encode(st))
	ck(copy.kills.get(tank.id, []) == [1, 1], "StateCodec keeps the ledger (%s)" % str(copy.kills))
	ck(r.can_undo(), "the run-over is undoable")
	r.resolve(UndoIntent.new(0))
	ck(foe.is_alive() and st.kills.is_empty(), "undo revives the victim AND takes the kill back (%s)" % str(st.kills))

	# --- a friend in the path is listed
	f = _field(func(m: MapData) -> void: m.set_spawn(Vector2i(6, 5), "heavy_infantry", 0))
	var fr: Array = f["r"].vehicle_move_crushed_friends(f["t"], Vector2i(1, 0), 3)
	ck(fr.size() == 1 and fr[0].stats.id == "heavy_infantry", "friendly heavy in the path is listed (%d)" % fr.size())

	# --- burnt: laser kill and flamethrower kill; ledger for the marksman
	f = _field(func(m: MapData) -> void:
		m.set_spawn(Vector2i(10, 9), "marksman", 0)
		m.set_spawn(Vector2i(14, 9), "light_infantry", 1)
		m.set_spawn(Vector2i(10, 1), "flamethrower", 0)
		m.set_spawn(Vector2i(12, 1), "light_infantry", 1))
	st = f["s"]
	r = f["r"]
	var mk: UnitInstance = st.grid.cell(Vector2i(10, 9)).occupant
	var v1: UnitInstance = st.grid.cell(Vector2i(14, 9)).occupant
	res = r.resolve(ShootIntent.new(mk.id, -1, -1, Vector2i(14, 9)))
	ck(res.ok and not v1.is_alive() and v1.burnt, "laser kill leaves a burnt body: " + res.reason)
	ck(st.kills.get(mk.id, []) == [2, 0], "ledger: the beam killed 2 down the row (%s)" % str(st.kills))
	var fl: UnitInstance = st.grid.cell(Vector2i(10, 1)).occupant
	var v2: UnitInstance = st.grid.cell(Vector2i(12, 1)).occupant
	res = r.resolve(ShootIntent.new(fl.id, -1, -1, Vector2i(11, 1)))
	ck(res.ok and not v2.is_alive() and v2.burnt, "flame kill leaves a burnt body: " + res.reason)
	copy = GameState.new(1, 1)
	StateCodec.restore_into(copy, StateCodec.encode(st))
	ck(copy.get_unit(v2.id).burnt and not copy.get_unit(mk.id).burnt, "StateCodec keeps 'burnt'")

	# --- ruthless civilians: an active civilian with a soldier next to it never retreats
	var m := MapData.new(30, 12)
	for y in 12:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_cell(Vector2i(14, 3), MCF.FLOOR_NORMAL, 1.0, false, MCF.FEATURE_SANDBAGS)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(27, 5), "light_infantry", 1)
	m.set_spawn(Vector2i(15, 5), "civilian", MCF.Owner.NEUTRAL)
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 1
	st = m.build_state(5)
	r = GameActionResolver.new(st)
	var civ: UnitInstance = null
	for u in st.all_units():
		if MCF.is_neutral(u.owner):
			civ = u
	civ.civilian_active = true
	var ai := AIController.new(MCF.Owner.NEUTRAL, AIController.Difficulty.HARD)
	r.omniscient_side = MCF.Owner.NEUTRAL
	ai._r = r
	var cands: Array = ai._neutral_candidates(st, r, civ)
	var before := mini(Combat.distance(civ.coord, Vector2i(2, 5)), Combat.distance(civ.coord, Vector2i(27, 5)))
	var closer := true
	for c: Dictionary in cands:
		var it: Intent = c["intent"]
		if it is MoveIntent:
			var to: Vector2i = (it as MoveIntent).target
			closer = closer and mini(Combat.distance(to, Vector2i(2, 5)), Combat.distance(to, Vector2i(27, 5))) < before
		elif not (it is ShootIntent):
			closer = false
	ck(not cands.is_empty() and closer, "civilian only shoots or closes in (%s)" % str(cands.map(func(c): return IntentCodec.encode(c["intent"]))))

	# --- ...and grabs a body next to it first, and never offers to put one down
	var dead := st.grid.cell(Vector2i(2, 5)).occupant
	r._kill(dead)
	civ.coord = Vector2i(3, 5)
	st.grid.move_occupant(Vector2i(15, 5), Vector2i(3, 5))
	cands = ai._neutral_candidates(st, r, civ)
	var top: Dictionary = cands[0]
	for c: Dictionary in cands:
		if float(c["score"]) > float(top["score"]):
			top = c
	ck(top["intent"] is PickUpCorpseIntent, "civilian picks up the body next to it first")
	civ.carried_corpses = 1
	cands = ai._neutral_candidates(st, r, civ)
	ck(not cands.any(func(c: Dictionary) -> bool: return c["intent"] is DropCorpseIntent),
			"a civilian never offers to drop a body")

	# --- Prev/Next skip slots with nobody alive
	var tm := TurnManager.new()
	tm.round_order = [0, MCF.neutral_group_slot(3), 1, MCF.neutral_group_slot(5)]
	var alive0 := UnitInstance.new(1, load("res://src/data/units/light_infantry.tres"), Vector2i.ZERO, 0)
	var alive1 := UnitInstance.new(2, load("res://src/data/units/light_infantry.tres"), Vector2i.ZERO, 1)
	ck(tm.neighbor_slot(0, 1, [alive0, alive1]) == 1 and tm.neighbor_slot(0, -1, [alive0, alive1]) == 1,
			"Prev/Next skip empty neutral groups")
	ck(tm.neighbor_slot(0, 1) == MCF.neutral_group_slot(3), "old call (no units) unchanged")

	# --- drawing undo restores the tiles exactly
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

	# --- welded airlock looks different in the baked tile
	var g := Grid.new(3, 3)
	var cell := g.cell(Vector2i(1, 1))
	cell.set_feature(MCF.FEATURE_AIRLOCK, -1)
	cell.cover_height = MCF.WALL_HEIGHT
	var tt := TerrainTiles.new(g)
	var a := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var fa := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	tt._paint(a, fa, Vector2i(1, 1), Vector2i.ZERO, 32)
	cell.airlock_welded = true
	var b := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var fb := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	tt._paint(b, fb, Vector2i(1, 1), Vector2i.ZERO, 32)
	ck(fa.get_data() != fb.get_data(), "a welded airlock tile differs from a plain one")
	tt.skip_features[MCF.FEATURE_SANDBAGS] = true
	cell.clear_feature()
	cell.set_feature(MCF.FEATURE_SANDBAGS, -1)
	var fc := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	tt._paint(Image.create(32, 32, false, Image.FORMAT_RGBA8), fc, Vector2i(1, 1), Vector2i.ZERO, 32)
	ck(fc.is_invisible(), "skipped field works are not baked")
	print("pt20: %d failure(s)" % fails)
	quit(1 if fails else 0)
