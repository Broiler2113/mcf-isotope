extends SceneTree
## Batch borg-corpses: bodies block the way, drone wall dips keep their flight, drones hover
## over vehicles, the borg's gun and laser armour, borg trenches, no blood in space,
## smooth vehicle moves stay undoable.
var fails := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1

func field(w: int, h: int, spawns: Array, feats: Dictionary = {}) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for c: Vector2i in feats:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, feats[c])
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(3)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r}

func _initialize() -> void:
	# --- bodies block the way: a pile of bodies and a body lying where it fell ---
	var f := field(14, 3, [[Vector2i(1, 1), "light_infantry", 0], [Vector2i(12, 2), "light_infantry", 1]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var li := st.grid.cell(Vector2i(1, 1)).occupant
	for y in 3:
		if y != 1:
			st.grid.cell(Vector2i(4, y)).set_feature(MCF.FEATURE_WALL)
	st.grid.cell(Vector2i(4, 1)).corpse_count = 1
	var reach := r.reachable_for(li, 9)
	ck(not reach.can_reach(Vector2i(4, 1)) and not reach.can_reach(Vector2i(6, 1)),
			"a pile of bodies can be neither stood on nor walked through")
	ck(not r.resolve(MoveIntent.new(li.id, Vector2i(4, 1))).ok, "a move onto the pile is refused")
	st.grid.cell(Vector2i(4, 1)).corpse_count = 0
	ck(r.reachable_for(li, 9).can_reach(Vector2i(6, 1)), "once the pile is gone the way is open")

	# --- a drone that dips over a wall keeps the rest of its flight ---
	f = field(20, 10, [[Vector2i(5, 5), "drone_operator", 0], [Vector2i(18, 8), "light_infantry", 1]],
			{Vector2i(9, 5): MCF.FEATURE_WALL})
	st = f["s"]; r = f["r"]
	var op := st.grid.cell(Vector2i(5, 5)).occupant
	var station := Vector2i(6, 5)
	st.grid.cell(station).feature_id = MCF.FEATURE_DRONE_STATION
	st.grid.cell(station).feature_owner = 0
	var drone := r._launch_drone_at(station, op)
	drone.remaining_ap = 1
	var up := r.resolve(DroneMoveIntent.new(drone.id, Vector2i(9, 5)))
	var credit_up := drone.move_credit
	var down := r.resolve(DroneMoveIntent.new(drone.id, drone.wall_entry_from))
	ck(up.ok and down.ok and credit_up > 0 and drone.move_credit == credit_up - 1,
			"after the wall dip the drone still has %d of its flight (had %d)" % [drone.move_credit, credit_up])

	# --- drones hover over vehicles instead of ramming them ---
	f = field(24, 12, [[Vector2i(5, 5), "drone_operator", 0], [Vector2i(10, 4), "tank", 1],
			[Vector2i(22, 10), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	op = st.grid.cell(Vector2i(5, 5)).occupant
	st.grid.cell(station).feature_id = MCF.FEATURE_DRONE_STATION
	st.grid.cell(station).feature_owner = 0
	drone = r._launch_drone_at(station, op)
	drone.remaining_ap = 1
	var tank: Vehicle = st.all_vehicles()[0]
	var over := tank.center()
	ck(r.drone_flight_cells(drone).has(over), "the tank's hull is in the drone's flight zone")
	var hover := r.resolve(DroneMoveIntent.new(drone.id, over))
	ck(hover.ok and drone.is_alive() and drone.coord == over, "the drone hovers over the tank (%s)" % hover.reason)

	# --- the borg: RoF 4 for anyone, its hull stops a laser ---
	f = field(20, 8, [[Vector2i(4, 4), "engineer", 0], [Vector2i(5, 4), "borg", 0],
			[Vector2i(12, 4), "marksman", 1], [Vector2i(2, 4), "light_infantry", 0]])
	st = f["s"]; r = f["r"]
	var borg: Vehicle = st.all_vehicles()[0]
	var en := st.grid.cell(Vector2i(4, 4)).occupant
	r.resolve(VehicleBoardIntent.new(en.id, borg.id))
	ck(en.rate_of_fire() == MCF.BORG_ROF, "an engineer in a borg fires the borg's 4 shots")
	var behind := st.grid.cell(Vector2i(2, 4)).occupant
	r.resolve(EndTurnIntent.new())
	while st.active_player() != 1:
		r.resolve(EndTurnIntent.new())
	var mk := st.grid.cell(Vector2i(12, 4)).occupant
	var trace: Array = r._laser_trace(mk.coord, Vector2i(-1, 0))
	var stops_at_borg := false
	for rec: Dictionary in trace:
		if rec["kind"] == "vehicle" and int(rec["vehicle_id"]) == borg.id:
			stops_at_borg = bool(rec["stop"])
	ck(stops_at_borg, "the laser stops at the borg's hull")
	r.resolve(ShootIntent.new(mk.id, -1, -1, Vector2i(0, 4)))
	ck(behind.is_alive(), "the soldier behind the borg is untouched")
	# --- no corpses in a borg ---
	if en.is_alive() and en.borg_id != -1:
		st.grid.cell(en.coord + Vector2i(0, 1)).corpse_count = 1
		ck(r.corpse_pickup_cells(en).is_empty(), "a borg is offered no corpse to pick up")
		ck(not r.resolve(PickUpCorpseIntent.new(en.id, en.coord + Vector2i(0, 1))).ok,
				"and a pick-up from the borg is refused")
		st.grid.cell(en.coord + Vector2i(0, 1)).corpse_count = 0
	# --- a borg digs 9 trenches per AP ---
	r.resolve(EndTurnIntent.new())
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	if en.is_alive() and en.borg_id != -1:
		var cells: Array = r.diggable_cells(en)
		var res := r.resolve(DigIntent.new(en.id, cells[0], LegalIntents.SENT, LegalIntents.SENT)) if not cells.is_empty() else ActionResult.fail("nowhere")
		ck(res.ok and en.dig_credits == MCF.BORG_DIG_TRENCHES - 1,
				"a borg's first trench opens %d more (%s)" % [en.dig_credits, res.reason])

	# --- a soldier carrying a body is not offered the borg ---
	f = field(12, 6, [[Vector2i(4, 3), "light_infantry", 0], [Vector2i(5, 3), "borg", 0],
			[Vector2i(10, 5), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	var carrier := st.grid.cell(Vector2i(4, 3)).occupant
	var empty_borg: Vehicle = st.all_vehicles()[0]
	ck(r.boardable_vehicles(carrier).has(empty_borg), "an empty-handed soldier may board the borg")
	carrier.carried_corpses = 1
	ck(not r.boardable_vehicles(carrier).has(empty_borg), "carrying a body, the borg is not offered")
	ck(not r.resolve(VehicleBoardIntent.new(carrier.id, empty_borg.id)).ok, "and boarding is refused")

	# --- shuttle passengers can't shoot through each other ---
	var sm := MapData.new(20, 8)
	for y in 8:
		for x in 20:
			sm.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	sm.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	sm.set_spawn(Vector2i(3, 5), "light_infantry", 0)
	sm.set_spawn(Vector2i(4, 4), "shuttle", 0)
	sm.set_spawn(Vector2i(15, 4), "light_infantry", 1)
	GameConfig.civilians_enabled = false
	st = sm.build_state(3)
	r = GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	var sh: Vehicle = st.all_vehicles()[0]
	var back_u := st.grid.cell(Vector2i(3, 4)).occupant
	var front_u := st.grid.cell(Vector2i(3, 5)).occupant
	var foe := st.grid.cell(Vector2i(15, 4)).occupant
	# Rear seat and front seat on row 4: (4,4) and (5,4).
	var rear := -1
	var front := -1
	for i in sh.seats.size():
		if sh.seat_cell(i) == Vector2i(4, 4): rear = i
		if sh.seat_cell(i) == Vector2i(5, 4): front = i
	r.resolve(VehicleBoardIntent.new(back_u.id, sh.id, rear))
	r.resolve(VehicleBoardIntent.new(front_u.id, sh.id, front))
	ck(back_u.coord == Vector2i(4, 4) and front_u.coord == Vector2i(5, 4), "two passengers seated on one row")
	ck(r.can_shoot(back_u, foe) != "" and not r.shootable_target_ids(back_u).has(foe.id),
			"the rear passenger can't shoot through the front one (%s)" % r.can_shoot(back_u, foe))
	ck(r.can_shoot(front_u, foe) == "", "the front passenger still can")

	# --- no blood in space; an explosion there still throws chunks ---
	var fx := FxDecals.new()
	fx.space_at = func(c: Vector2i) -> bool: return c.x < 5
	fx.apply([{"fx": "blood", "at": Vector2i(2, 2), "from": Vector2i(8, 2)}])
	var pools := fx.gore.filter(func(p): return p["kind"] == "blood_pool").size()
	ck(pools == 0 and fx.flying.is_empty(), "a death in space leaves no blood")
	fx.apply([{"fx": "blood", "at": Vector2i(2, 2), "from": Vector2i(2, 2), "blast": true}])
	var gibs := fx.flying.filter(func(p): return p["kind"] == "gib").size()
	var drops := fx.flying.filter(func(p): return p["kind"] == "blood_drop").size()
	ck(gibs > 0 and drops == 0, "an explosion in space throws chunks, not blood (%d chunks)" % gibs)
	fx.apply([{"fx": "blood", "at": Vector2i(9, 2), "from": Vector2i(12, 2)}])
	ck(fx.gore.filter(func(p): return p["kind"] == "blood_pool").size() > 0, "on the floor blood still pools")

	# --- nor does the laser scorch space, and nor does rubble settle there ---
	# Same reason as the blood above: there is no floor in space to take the mark. The
	# screens already drew such a cell as space, but the record still rode to the guest
	# and into the save, and a shot across a breach drew a black line over the void.
	fx.apply([{"fx": "debris", "at": Vector2i(2, 2),
			"cells": [Vector2i(2, 2), Vector2i(3, 2), Vector2i(6, 2)]}])
	ck(not fx.floor_damage.has(Vector2i(2, 2)) and not fx.floor_damage.has(Vector2i(3, 2))
			and fx.floor_damage.has(Vector2i(6, 2)),
			"an explosion scars the floor and leaves the space beside it clean (%s)"
			% str(fx.floor_damage.keys()))
	fx.laser_lines.clear()
	fx.apply([{"fx": "laser", "from": [0, 2], "to": [9, 2]}])
	var trail_from: Vector2 = fx.laser_lines[0]["from"] if not fx.laser_lines.is_empty() else Vector2.ZERO
	ck(fx.laser_lines.size() == 1 and absf(trail_from.x - 5.0) < 0.3,
			"the trail of a shot across a breach starts where the floor does (%s)"
			% str(fx.laser_lines))
	fx.laser_lines.clear()
	fx.apply([{"fx": "laser", "from": [0, 5], "to": [3, 5]}])
	ck(fx.laser_lines.is_empty(), "a shot wholly across space leaves no trail at all")
	fx.laser_lines.clear()
	fx.apply([{"fx": "laser", "from": [6, 7], "to": [9, 7]}])
	ck(fx.laser_lines.size() == 1, "and over plain floor it stays ONE unbroken line")
	# Without a scene nothing knows where space is, and the trail must behave as before.
	var bare := FxDecals.new()
	bare.apply([{"fx": "laser", "from": [0, 0], "to": [4, 0]}])
	ck(bare.laser_lines.size() == 1, "with no space hook wired the trail is unchanged")

	# --- a downed drone is machinery: no blood, no gibs ---
	var dm := MapData.new(20, 10)
	for y in 10:
		for x in 20:
			dm.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	dm.set_cell(Vector2i(6, 5), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_DRONE_STATION)
	dm.set_spawn(Vector2i(5, 5), "drone_operator", MCF.Owner.PLAYER_1)
	dm.set_spawn(Vector2i(15, 5), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var dst := dm.build_state(21)
	var dr := GameActionResolver.new(dst)
	dr.fog_mode = MCF.Fog.OFF
	dr.fog_enabled = false
	dst.grid.cell(Vector2i(6, 5)).feature_owner = MCF.Owner.PLAYER_1
	while dst.active_player() != MCF.Owner.PLAYER_1:
		dr.resolve(EndTurnIntent.new())
	var dop: UnitInstance = dst.grid.cell(Vector2i(5, 5)).occupant
	ck(dr.resolve(SpawnDroneIntent.new(dop.id, Vector2i(6, 5))).ok, "a drone goes up for the gore check")
	var uav := dr.active_drone_of(dop)
	ck(uav != null, "and it is airborne")
	var dres := ActionResult.new()
	dr._kill(uav, dres, Vector2i(15, 5))
	var dfx := FxDecals.new()
	dfx.apply(dres.fx)
	ck(dfx.gore.is_empty(), "a downed drone leaves no blood and no gibs (%d)" % dfx.gore.size())
	ck(dst.grid.cell(uav.coord).occupant != uav, "and no body on the cell — it never occupied one")
	# Positive control: a man shot in the same breath still bleeds.
	var man: UnitInstance = dst.grid.cell(Vector2i(15, 5)).occupant
	var mres := ActionResult.new()
	dr._kill(man, mres, Vector2i(5, 5))
	var mfx := FxDecals.new()
	mfx.apply(mres.fx)
	ck(not mfx.gore.is_empty(), "while a man killed beside it still does")

	# --- blood stays for the whole battle; casings are what gets evicted ---
	var gfx := FxDecals.new()
	gfx.apply([{"fx": "blood", "at": Vector2i(5, 5), "from": Vector2i(8, 5)}])
	for _i in 60:
		gfx.advance(1.0)
	var settled := gfx.gore.size()
	ck(settled > 0, "blood settles into the gore layer (%d)" % settled)
	for _i in 400:
		gfx.apply([{"fx": "casings", "at": Vector2i(7, 7), "toward": Vector2i(9, 7), "count": 8}])
		gfx.advance(1.0)
	ck(gfx.props.size() <= FxDecals.PROPS_CAP,
			"casings are still capped (%d <= %d)" % [gfx.props.size(), FxDecals.PROPS_CAP])
	ck(gfx.gore.size() == settled,
			"and not one drop of blood was pushed out (%d -> %d)" % [settled, gfx.gore.size()])

	# --- a vehicle move animates and stays undoable ---
	f = field(30, 10, [[Vector2i(2, 4), "light_infantry", 0], [Vector2i(2, 5), "light_infantry", 0],
			[Vector2i(2, 6), "light_infantry", 0], [Vector2i(3, 4), "tank", 0],
			[Vector2i(28, 8), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	var veh: Vehicle = st.all_vehicles()[0]
	for i in 3:
		var bc: Array = r.vehicle_board_candidates(veh)
		if not bc.is_empty():
			r.resolve(VehicleBoardIntent.new(int(bc[0]), veh.id))
	veh.ap = 3
	var from := veh.origin
	var mv := r.resolve(VehicleMoveIntent.new(veh.id, Vector2i(1, 0), 5))
	var walks := mv.dice_events.filter(func(e): return e.get("kind", "") == "veh_walk")
	ck(mv.ok and walks.size() == 1 and walks[0]["from"] == from and int(walks[0]["steps"]) == 5,
			"a vehicle move is played as a smooth drive")
	ck(not r._is_irreversible(VehicleMoveIntent.new(veh.id, Vector2i(1, 0), 1), mv), "and stays undoable")

	print("borg corpses: %d failure(s)" % fails)
	quit(1 if fails else 0)
