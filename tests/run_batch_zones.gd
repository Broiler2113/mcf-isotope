extends SceneTree
## Batch group-zones: glass saves, zero-g recoil for every shot, tanks stay out of space,
## several drones per operator, initiative shown on the purchase screen == the battle's,
## the cannon's aim label, replay notes for the menu.
var fails := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1

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

func _initialize() -> void:
	# --- glass saves each bullet (5+), so a window can survive a burst ---
	ck(MCF.glass_bullet_save(MCF.FEATURE_GLASS) == 5 and MCF.glass_bullet_save(MCF.FEATURE_ARMOR_GLASS) == 4,
			"glass holds on 5+, armored glass on 4+")
	var survived := 0
	var broke := 0
	for i in 30:
		var f := field(16, 6, [[Vector2i(2, 2), "light_infantry", 0], [Vector2i(14, 5), "light_infantry", 1]],
				{Vector2i(6, 2): MCF.FEATURE_GLASS})
		var st: GameState = f["s"]
		st.dice = DiceService.new(1000 + i)
		var li := st.grid.cell(Vector2i(2, 2)).occupant
		var res: ActionResult = f["r"].resolve(ShootIntent.new(li.id, -1, -1, Vector2i(6, 2)))
		if not res.ok:
			continue
		if st.grid.cell(Vector2i(6, 2)).feature_id == MCF.FEATURE_GLASS:
			survived += 1
		else:
			broke += 1
	ck(survived > 0 and broke > 0, "a window sometimes holds and sometimes breaks (%d held, %d broke)" % [survived, broke])

	# --- recoil in space for every kind of shot, blocked when something is behind ---
	for kind in ["light_infantry", "anti_tank", "flamethrower", "marksman"]:
		var sp: Array = []
		for x in range(0, 8):   # the shooter's end is space; the target cells are floor
			sp.append(Vector2i(x, 3))
		var f := field(16, 7, [[Vector2i(6, 3), kind, 0], [Vector2i(11, 3), "light_infantry", 1]], {}, sp)
		var st: GameState = f["s"]
		var u := st.grid.cell(Vector2i(6, 3)).occupant
		var res: ActionResult = f["r"].resolve(ShootIntent.new(u.id, -1, -1, Vector2i(9, 3)) if kind != "light_infantry"
				else ShootIntent.new(u.id, st.grid.cell(Vector2i(11, 3)).occupant.id))
		ck(res.ok and u.coord == Vector2i(5, 3), "%s in space recoils one cell back (%s, at %s)" % [kind, res.reason, u.coord])
	var spb: Array = []
	for x in range(0, 8):
		spb.append(Vector2i(x, 3))
	var fb := field(16, 7, [[Vector2i(6, 3), "anti_tank", 0], [Vector2i(5, 3), "light_infantry", 0],
			[Vector2i(11, 3), "light_infantry", 1]], {}, spb)
	var atb: UnitInstance = fb["s"].grid.cell(Vector2i(6, 3)).occupant
	var bres: ActionResult = fb["r"].resolve(ShootIntent.new(atb.id, -1, -1, Vector2i(9, 3)))
	ck(bres.ok and atb.coord == Vector2i(6, 3), "no recoil when someone stands behind (%s)" % bres.reason)

	# --- tanks stay out of space ---
	var tsp: Array = []
	for y in 12:
		for x in range(12, 16):
			tsp.append(Vector2i(x, y))
	var ft := field(24, 12, [[Vector2i(2, 4), "light_infantry", 0], [Vector2i(2, 5), "light_infantry", 0],
			[Vector2i(2, 6), "light_infantry", 0], [Vector2i(3, 4), "tank", 0],
			[Vector2i(22, 10), "light_infantry", 1]], {}, tsp)
	var veh: Vehicle = ft["s"].all_vehicles()[0]
	var plan := VehicleRules.plan_line_move(ft["s"], veh, Vector2i(1, 0), 20, 40)
	ck(plan["ok"] and veh.origin.x + int(plan["steps"]) + veh.size.x - 1 < 12,
			"a tank drives up to the void and stops (%d steps)" % int(plan["steps"]))

	# --- a second drone while the first is still up ---
	var fd := field(20, 10, [[Vector2i(5, 5), "drone_operator", 0], [Vector2i(18, 8), "light_infantry", 1]])
	var sd: GameState = fd["s"]
	var rd: GameActionResolver = fd["r"]
	var op := sd.grid.cell(Vector2i(5, 5)).occupant
	sd.grid.cell(Vector2i(6, 5)).feature_id = MCF.FEATURE_DRONE_STATION
	sd.grid.cell(Vector2i(6, 5)).feature_owner = 0
	sd.grid.cell(Vector2i(6, 5)).station_operator_id = op.id
	op.remaining_ap = 3
	var r1 := rd.resolve(SpawnDroneIntent.new(op.id, Vector2i(6, 5)))
	var r2 := rd.resolve(SpawnDroneIntent.new(op.id, Vector2i(6, 5)))
	var drones := 0
	for u in sd.all_units():
		if u.is_drone and u.is_alive() and u.operator_id == op.id:
			drones += 1
	ck(r1.ok and r2.ok and drones == 2, "an operator launches a second drone while the first flies (%s)" % r2.reason)

	# --- the purchase screen's initiative is the battle's ---
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

	# --- the cannon's label is the roll it makes ---
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

	# --- replay/save notes let the menu list files without reading them ---
	var path := "user://_tmp_note_test.mcfr"
	ReplayFile.write(path, {"meta": {"map": "town", "round": 4, "steps": 120}})
	ck(FileAccess.file_exists(path + ReplayFile.NOTE_EXT), "writing a replay also writes its note")
	ck(ReplayFile.note_for(path) == "town · round 4 · 120 actions", "the note is the menu caption (%s)" % ReplayFile.note_for(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ReplayFile.NOTE_EXT))

	print("batch zones: %d failure(s)" % fails)
	quit(1 if fails else 0)
