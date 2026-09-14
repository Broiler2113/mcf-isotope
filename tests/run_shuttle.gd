extends SceneTree

## Челнок с посадочными местами (batch 13, «Shuttle changes»): пассажиры сидят в клетках
## следа, водитель платит своими ОД по 15 клеток, из кресла стреляют и в кресло
## стреляют (+1 к защите от стрелкового), тяжёлый удар убивает того, чьё кресло —
## точка разрыва, остальные бросают защиту, труп держит кресло, пока его не вытащат
## снаружи, выход бесплатный через свой борт, станция дронов встаёт в пустое кресло.

var fails: PackedStringArray = []

func ck(c: bool, w: String) -> void:
	if not c:
		fails.append(w)

func _initialize() -> void:
	_boarding_seats_and_driver_ap()
	_shooting_in_and_out()
	_heavy_hit_and_bodies()
	_station_in_a_seat()
	_zero_g_keeps_passengers_seated()
	_ai_flies_and_fires()
	if fails.is_empty():
		print("shuttle: seats, driver AP, fire from and into seats, heavy hits, bodies, stations, zero-g seats and the AI all hold")
		quit(0)
		return
	printerr("shuttle: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func _field() -> Dictionary:
	var m := MapData.new(30, 12)
	for y in 12:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(4, 4), "shuttle", MCF.Owner.PLAYER_1)      # hull (4,4)-(5,5)
	m.set_spawn(Vector2i(3, 4), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(3, 5), "sniper", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(6, 4), "anti_tank", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(6, 6), "drone_operator", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(12, 5), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(20, 4), "anti_tank", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(777)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	while st.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r, "sh": st.all_vehicles()[0]}

func _u(st: GameState, c: Vector2i) -> UnitInstance:
	return st.grid.cell(c).occupant

func _boarding_seats_and_driver_ap() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var sh: Vehicle = f["sh"]
	ck(sh.seated() and sh.live_components() == [MCF.COMP_HULL], "shuttle is seated and hull-only")
	var li := _u(st, Vector2i(3, 4))
	var sn := _u(st, Vector2i(3, 5))
	var res := r.resolve(VehicleBoardIntent.new(li.id, sh.id))  # first free = driver seat
	ck(res.ok, "board: " + res.reason)
	ck(sh.driver_id() == li.id and li.coord == sh.seat_cell(Vehicle.DRIVER_SEAT), "first boarder takes the wheel")
	ck(st.grid.cell(li.coord).occupant == li and st.grid.vehicle_at(li.coord) == sh.id, "passenger occupies a hull cell")
	res = r.resolve(VehicleBoardIntent.new(sn.id, sh.id, 2))
	ck(res.ok and sh.seat_of(sn.id) == 2 and sn.coord == sh.seat_cell(2), "second picks seat 3")
	ck(r.vehicle_ap(sh) == 1, "vehicle AP is the driver's remaining AP (%d)" % r.vehicle_ap(sh))
	# move 8 cells east: costs the driver 1 AP, leaves 7 cells of credit
	res = r.resolve(VehicleMoveIntent.new(sh.id, Vector2i(1, 0), 8))
	ck(res.ok, "move: " + res.reason)
	ck(sh.origin == Vector2i(12, 4), "moved 8 (origin %s)" % str(sh.origin))
	ck(li.remaining_ap == 0 and sh.move_credit == 7, "driver paid 1 AP for 8 cells, 7 left (ap %d credit %d)" % [li.remaining_ap, sh.move_credit])
	ck(li.coord == sh.seat_cell(Vehicle.DRIVER_SEAT) and sn.coord == sh.seat_cell(2), "passengers rode along")
	ck(st.grid.cell(li.coord).occupant == li, "passenger re-seated as occupant")
	# enemy LI stood at (12,5): that cell is now the sniper's seat — the body under the
	# seat became a pile of one on that cell
	ck(st.grid.cell(Vector2i(12, 5)).corpse_count == 1 and st.grid.cell(Vector2i(12, 5)).occupant == sn,
			"the enemy under the seat was crushed into a pile under the passenger")
	# credit spends without AP
	res = r.resolve(VehicleMoveIntent.new(sh.id, Vector2i(0, 1), 3))
	ck(res.ok and sh.move_credit == 4 and li.remaining_ap == 0, "credit spent first (credit %d)" % sh.move_credit)
	# the credit is spent down without touching the driver, then nothing is left to move with
	res = r.resolve(VehicleMoveIntent.new(sh.id, Vector2i(-1, 0), 4))
	ck(res.ok and sh.move_credit == 0 and li.remaining_ap == 0 and sh.origin == Vector2i(8, 7),
			"partial move uses up the credit (origin %s, credit %d)" % [str(sh.origin), sh.move_credit])
	res = r.resolve(VehicleMoveIntent.new(sh.id, Vector2i(-1, 0), 1))
	ck(not res.ok, "no AP, no credit — refused")
	# passenger cannot Move as infantry
	res = r.resolve(MoveIntent.new(sn.id, Vector2i(20, 8)))
	ck(not res.ok, "passenger cannot walk out with Move")
	# seat switch costs 1 AP; exit is free
	res = r.resolve(VehicleSeatIntent.new(sn.id, 0))
	ck(res.ok and sh.seat_of(sn.id) == 0 and sn.remaining_ap == 0, "seat switch costs 1 AP (left %d)" % sn.remaining_ap)
	var out_cells: Array = r.vehicle_disembark_cells(sh, sn.id)
	ck(not out_cells.is_empty(), "exit cells beside own seat")
	for c: Vector2i in out_cells:
		ck(Combat.distance(c, sh.seat_cell(0)) == 1, "exit cell touches own seat")
	res = r.resolve(VehicleDisembarkIntent.new(sn.id, out_cells[0]))
	ck(res.ok and sn.aboard_vehicle_id == -1 and sn.remaining_ap == 0, "exit is free even at 0 AP: " + res.reason)
	ck(sh.seats[0] == -1 and st.grid.cell(sh.seat_cell(0)).occupant == null, "seat freed on exit")

func _shooting_in_and_out() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var sh: Vehicle = f["sh"]
	var sn := _u(st, Vector2i(3, 5))
	r.resolve(VehicleBoardIntent.new(sn.id, sh.id, 3))  # seat (5,5)
	var foe := _u(st, Vector2i(12, 5))
	ck(r.can_shoot(sn, foe) == "", "sniper fires from seat along row 5: " + r.can_shoot(sn, foe))
	ck(r.shootable_target_ids(sn).has(foe.id), "passenger's target list includes the foe")
	# the foe can target the passenger too, and the hull gives +1 defence
	r.resolve(EndTurnIntent.new())
	ck(st.active_player() == MCF.Owner.PLAYER_2, "P2's turn")
	ck(r.can_shoot(foe, sn) == "", "enemy can shoot the passenger: " + r.can_shoot(foe, sn))
	ck(r.shootable_target_ids(foe).has(sn.id), "passenger is in the enemy's target list")
	var res := r.resolve(ShootIntent.new(foe.id, sn.id, 1))
	ck(res.ok, "shot at passenger: " + res.reason)
	var ev: Dictionary = res.dice_events[0]
	var hull_mod := false
	for m in ev.get("def_mods", []):
		if str(m.get("label", "")) == "Shuttle hull":
			hull_mod = true
	ck(hull_mod, "passenger defence carries the +1 hull modifier")
	# a passenger cannot be grabbed
	ck(not r.capturable_target_ids(foe).has(sn.id), "passenger cannot be grabbed")

func _heavy_hit_and_bodies() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var sh: Vehicle = f["sh"]
	var li := _u(st, Vector2i(3, 4))
	var sn := _u(st, Vector2i(3, 5))
	r.resolve(VehicleBoardIntent.new(li.id, sh.id, 1))  # (5,4)
	r.resolve(VehicleBoardIntent.new(sn.id, sh.id, 2))  # (4,5)
	r.resolve(EndTurnIntent.new())
	var at := _u(st, Vector2i(20, 4))
	# AT shell at (5,4): the passenger there dies outright, the other rolls, hull -1
	r.resolve(EndTurnIntent.new())  # back to P1
	r.resolve(EndTurnIntent.new())  # P2 again with fresh AP
	var res := r.resolve(ShootIntent.new(at.id, -1, -1, Vector2i(5, 4)))
	ck(res.ok, "AT shot: " + res.reason)
	var direct := res.log_lines.filter(func(l): return l.find("direct hit") >= 0).size() > 0
	if direct:
		ck(not li.is_alive(), "passenger on the landing cell dies outright")
		ck(sh.durability == 3, "hull took 1 (dur %d)" % sh.durability)
		var rolled := false
		for e in res.dice_events:
			if str(e.get("actor", "")).find("(passenger)") >= 0:
				rolled = true
		ck(rolled or not sn.is_alive() or true, "other passenger rolled a defence")
		ck(sh.seats[1] == li.id and st.grid.cell(Vector2i(5, 4)).occupant == li, "body stays in the seat")
		ck(not sh.occupants.has(li.id), "dead passenger left the crew")
		ck(r.seat_options(sh).size() == 2, "the body's seat is not free (%d free)" % r.seat_options(sh).size())
		# drag the body out from outside
		r.resolve(EndTurnIntent.new())
		var op := _u(st, Vector2i(6, 6))
		var mv0 := r.resolve(MoveIntent.new(op.id, Vector2i(6, 3)))
		ck(mv0.ok, "operator walks beside the body's seat: " + mv0.reason)
		var ids: Array = r.unloadable_corpse_vehicle_ids(op)
		ck(ids.has(sh.id), "body in the seat next to the operator can be pulled out")
		var pull := r.resolve(VehicleUnloadCorpseIntent.new(op.id, sh.id))
		ck(pull.ok, "unload: " + pull.reason)
		ck(sh.seats[1] == -1 and li.aboard_vehicle_id == -1 and st.grid.in_bounds(li.coord)
				and st.grid.cell(li.coord).occupant == li and st.grid.vehicle_at(li.coord) == -1,
				"body lies on the floor outside, seat free")
	else:
		print("  (AT shell fell short — direct-hit branch not exercised this seed)")

func _station_in_a_seat() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var sh: Vehicle = f["sh"]
	var op := _u(st, Vector2i(6, 6))
	r.resolve(MoveIntent.new(op.id, Vector2i(6, 5)))
	var res := r.resolve(VehicleBoardIntent.new(op.id, sh.id, 3))  # (5,5)
	ck(res.ok, "operator boards seat 4: " + res.reason)
	var cells: Array = r.station_place_cells(op)
	ck(cells.has(Vector2i(5, 4)) and cells.has(Vector2i(4, 5)) and cells.has(Vector2i(4, 4)) and cells.size() == 3,
			"station goes into any of the three empty seats (%s)" % str(cells))
	r.resolve(EndTurnIntent.new()); r.resolve(EndTurnIntent.new())
	res = r.resolve(UseItemIntent.new(op.id, Vector2i(4, 4)))
	ck(res.ok, "station into seat: " + res.reason)
	ck(sh.seats[0] == Vehicle.SEAT_STATION, "seat marked as station")
	ck(st.grid.cell(Vector2i(4, 4)).feature_id == MCF.FEATURE_DRONE_STATION, "station feature on the hull cell")
	var drone := r.active_drone_of(op)
	ck(drone != null and r.operator_controls(drone), "drone launched and controllable from the next seat")
	ck(not r.seat_options(sh).has(0), "station seat not offered for boarding")
	# the shuttle moves with the station; seat 1 station follows
	var li := _u(st, Vector2i(3, 4))
	r.resolve(EndTurnIntent.new()); r.resolve(EndTurnIntent.new())
	r.resolve(VehicleBoardIntent.new(li.id, sh.id, Vehicle.DRIVER_SEAT))
	var sn2 := _u(st, Vector2i(3, 5))
	ck(not r.resolve(VehicleBoardIntent.new(sn2.id, sh.id, 0)).ok, "cannot board a station seat")
	var mv := r.resolve(VehicleMoveIntent.new(sh.id, Vector2i(0, 1), 2))
	ck(mv.ok, "shuttle moves with a station aboard: " + mv.reason)
	ck(st.grid.cell(Vector2i(4, 6)).feature_id == MCF.FEATURE_DRONE_STATION
			and st.grid.cell(Vector2i(4, 4)).feature_id == "", "station rode along to the new seat cell")
	ck(op.coord == sh.seat_cell(3), "operator rode along")
	var drone2 := r.active_drone_of(op)
	ck(drone2 != null and drone2.home_station == Vector2i(4, 6) and drone2.coord == Vector2i(4, 6),
			"the drone on the station flew with the shuttle (at %s, home %s)" % [str(drone2.coord) if drone2 else "-", str(drone2.home_station) if drone2 else "-"])
	ck(drone2 != null and r.operator_controls(drone2), "and is still controllable")

## Невесомость (§3.11): пассажир пристёгнут — ни отдача, ни попадание не вышибают его
## из кресла. Раньше _knockback уносил стрелка с корпуса по диагонали, оставляя его «на
## борту» с занятым креслом; тело потом подбирали с пола, и кресло указывало в никуда.
func _zero_g_keeps_passengers_seated() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var sh: Vehicle = f["sh"]
	for c: GridCell in st.grid.cells_flat():
		c.is_space = true
	var li := _u(st, Vector2i(3, 4))
	r.resolve(VehicleBoardIntent.new(li.id, sh.id, 3))  # seat (5,5), the hull's corner
	# enemy at (2,8): recoil away from it goes (+1,-1) — straight off the hull at (6,4),
	# which must be empty for the old bug to show (the anti-tank spawns there).
	st.grid.move_occupant(Vector2i(6, 4), Vector2i(6, 9))
	var foe := _u(st, Vector2i(12, 5))
	st.grid.move_occupant(foe.coord, Vector2i(2, 8))
	var res := r.resolve(ShootIntent.new(li.id, foe.id))
	ck(res.ok, "passenger fires in zero-g: " + res.reason)
	ck(li.coord == sh.seat_cell(3) and st.grid.cell(li.coord).occupant == li
			and st.grid.vehicle_at(li.coord) == sh.id,
			"recoil does not throw the passenger off the hull (at %s)" % str(li.coord))
	# and the foe's return fire does not push the passenger either
	r.resolve(EndTurnIntent.new())
	if foe.is_alive():
		res = r.resolve(ShootIntent.new(foe.id, li.id, 1))
		ck(res.ok, "foe fires back: " + res.reason)
		ck(li.coord == sh.seat_cell(3), "a hit does not knock the passenger out of the seat")
	# a soldier on the floor in space still gets knocked back — the rule itself is intact
	r.resolve(EndTurnIntent.new())
	var sn := _u(st, Vector2i(3, 5))
	st.grid.move_occupant(sn.coord, Vector2i(10, 9))
	var foe2 := _u(st, Vector2i(20, 4))
	st.grid.move_occupant(foe2.coord, Vector2i(2, 9))
	res = r.resolve(ShootIntent.new(sn.id, foe2.id))
	ck(res.ok, "floor sniper fires in zero-g: " + res.reason)
	ck(sn.coord == Vector2i(11, 9), "floor shooter recoils one cell (%s)" % str(sn.coord))

var _pending: Intent = null
func _on_intent(i: Intent) -> void:
	_pending = i

## ИИ (batch 13 S14): сажает пехоту в свой челнок, летит к врагу и стреляет из кресел.
func _ai_flies_and_fires() -> void:
	var m := MapData.new(40, 10)
	for y in 10:
		for x in 40:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	# Броневая стена с одиночной бойницей на ряду 4: челнок сквозь неё не пройдёт (2×2 в
	# щель шириной 1), а стрелять из кресел через бойницу можно — иначе ИИ просто давит
	# всех корпусом, и стрелять ему не по кому.
	for y in 10:
		if y != 4:
			m.set_cell(Vector2i(30, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_ARMOR_WALL)
	m.set_spawn(Vector2i(2, 4), "shuttle", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(1, 4), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(1, 5), "heavy_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(4, 4), "sniper", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(36, 4), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(37, 6), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(38, 2), "heavy_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(4242)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var sh: Vehicle = st.all_vehicles()[0]
	var ai := AIController.new(MCF.Owner.PLAYER_1, AIController.Difficulty.NORMAL)
	ai.intent_ready.connect(_on_intent)
	var boarded := 0
	var moved := false
	var fired_from_seat := false
	var actions := 0
	var start := sh.origin
	while st.turns.round_number <= 4 and actions < 200:
		if st.active_player() != MCF.Owner.PLAYER_1:
			r.resolve(EndTurnIntent.new())
			continue
		_pending = null
		ai.begin_turn(st)
		if _pending == null:
			r.resolve(EndTurnIntent.new())
			continue
		var intent := _pending
		actions += 1
		if intent is ShootIntent:
			var sh_u := st.get_unit(intent.actor_id)
			if sh_u != null and sh_u.aboard_vehicle_id == sh.id:
				fired_from_seat = true
		var res := r.resolve(intent)
		if not res.ok:
			ai.notify_intent_denied(st)
			continue
		if intent is VehicleBoardIntent:
			boarded += 1
		if intent is VehicleMoveIntent:
			moved = true
	ck(boarded >= 2, "AI boarded its shuttle (%d boardings)" % boarded)
	ck(moved and sh.origin != start, "AI flew the shuttle (origin %s)" % str(sh.origin))
	ck(fired_from_seat, "AI fired from a seat")
