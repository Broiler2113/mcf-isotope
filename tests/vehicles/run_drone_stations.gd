extends "res://tests/SuiteBase.gd"
## Drone stations: packing up next to an operator, stations in shuttle seats, a second drone,
## seats freed when a station burns.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_station_underfoot()
	_station_rules()
	_shuttle_station()

	stations()

	stations__player_reports()

	_second_drone()

	_fire_frees_station_seat()

	_scout_drone()

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

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func turn_to(r: GameActionResolver, side: int) -> void:
	var guard := 0
	while r.state.active_player() != side and guard < 10:
		r.resolve(EndTurnIntent.new())
		guard += 1

func stations() -> void:
	var map := arena()
	map.set_spawn(Vector2i(5, 5), "drone_operator", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	var r := resolver_for(map, 3)
	var s := r.state
	var op: UnitInstance = s.grid.cell(Vector2i(5, 5)).occupant
	var st := Vector2i(6, 5)
	for cycle in 3:
		turn_to(r, 0)
		r.resolve(UseItemIntent.new(op.id, st))
		r.resolve(SpawnDroneIntent.new(op.id, st))   # a second drone hovers beside the pad
		turn_to(r, 1)
		turn_to(r, 0)
		var res := r.resolve(PickUpStationIntent.new(op.id, st))
		ck(res.ok and op.held_item_id == MCF.ITEM_DRONE_STATION, "cycle %d: the station packs up with both drones" % cycle)

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

func add(r: GameActionResolver, kind: String, c: Vector2i, side: int = 0) -> UnitInstance:
	return r.state.spawn_unit(load("res://src/data/units/%s.tres" % kind), c, side)

func stations__player_reports() -> void:
	var r := arena__player_reports()
	var s := r.state
	var shuttle := s.spawn_vehicle("shuttle", Vector2i(6, 6), 0)
	var driver := add(r, "civilian", Vector2i(5, 5))
	var op := add(r, "drone_operator", Vector2i(8, 5))
	var op2 := add(r, "drone_operator", Vector2i(5, 8))
	ck(r.resolve(VehicleBoardIntent.new(driver.id, shuttle.id, 0)).ok, "civilian boards driver seat")
	ck(r.resolve(VehicleBoardIntent.new(op.id, shuttle.id, 1)).ok, "first drone operator boards")
	ck(r.resolve(VehicleBoardIntent.new(op2.id, shuttle.id, 2)).ok, "second drone operator boards")
	var at := shuttle.seat_cell(3)
	ck(r.resolve(UseItemIntent.new(op.id, at)).ok, "station mounts in fourth seat")
	r._kill(driver)
	ck(r.stations_near(op).has(at) and r.stations_near(op2).has(at), "driver death does not disconnect either operator")
	s.grid.cell(at).feature_durability = 5
	var rocketeer := add(r, "anti_tank", Vector2i(at.x + 4, at.y))
	s.dice.feed_scripted([6, 6, 6, 6, 6, 6, 6, 6])
	var rocket := r.resolve(ShootIntent.new(rocketeer.id, -1, -1, at))
	ck(rocket.ok, "AT round hits the mounted drone station: " + rocket.reason)
	ck(s.grid.cell(at).feature_id == "" and shuttle.seats[3] == -1, "blast deletes station and releases its shuttle seat")
	ck(r.deployed_station_of(op) == Vector2i(-1, -1), "destroyed station no longer blocks replacement")
	# A station outside a shuttle must also disappear in a frag explosion.
	var floor_station := Vector2i(12, 10)
	s.grid.cell(floor_station).set_feature(MCF.FEATURE_DRONE_STATION, 0)
	r._explode_frag(op, floor_station)
	ck(s.grid.cell(floor_station).feature_id == "", "frag explosion deletes drone stations__player_reports")

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

## a second drone while the first is still up
func _second_drone() -> void:
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

func arena__audit0128(body_under_spawn := false) -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 5), "light_infantry", 1)
	if body_under_spawn: map.corpses.append(5 * 22 + 18)
	var s := map.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

## Fire on a mounted station frees its shuttle seat, like a blast.
func _fire_frees_station_seat() -> void:
	var r := arena__audit0128()
	var s := r.state
	var shuttle := s.spawn_vehicle("shuttle", Vector2i(6, 6), 0)
	var driver := add(r, "civilian", Vector2i(5, 5))
	var op := add(r, "drone_operator", Vector2i(8, 5))
	r.resolve(VehicleBoardIntent.new(driver.id, shuttle.id, 0))
	r.resolve(VehicleBoardIntent.new(op.id, shuttle.id, 1))
	var at := shuttle.seat_cell(3)
	ck(r.resolve(UseItemIntent.new(op.id, at)).ok, "station mounts in the fourth seat")
	r._ignite(s.grid.cell(at), 1, ActionResult.success([]))
	ck(s.grid.cell(at).feature_id == "" and shuttle.seats[3] == -1, "a burnt station releases its shuttle seat")

## fix-7 #7: a station also launches scout drones — 60 cells per flight, 45 from the station,
## no detonation, no ram, no blast when shot down or burnt; the kamikaze keeps 30 / 15.
func _scout_drone() -> void:
	var fd := field(70, 12, [[Vector2i(5, 5), "drone_operator", 0], [Vector2i(9, 5), "light_infantry", 0],
			[Vector2i(65, 10), "light_infantry", 1]])
	var sd: GameState = fd["s"]
	var rd: GameActionResolver = fd["r"]
	var op := sd.grid.cell(Vector2i(5, 5)).occupant
	var friend := sd.grid.cell(Vector2i(9, 5)).occupant
	sd.grid.cell(Vector2i(6, 5)).feature_id = MCF.FEATURE_DRONE_STATION
	sd.grid.cell(Vector2i(6, 5)).feature_owner = 0
	sd.grid.cell(Vector2i(6, 5)).station_operator_id = op.id
	op.remaining_ap = 3
	var res := rd.resolve(SpawnDroneIntent.new(op.id, Vector2i(6, 5), true))
	var scout := sd.get_unit(res.spawned_unit_id)
	ck(res.ok and MCF.is_scout(scout), "the station launches a scout drone (%s)" % res.reason)
	var kres := rd.resolve(SpawnDroneIntent.new(op.id, Vector2i(6, 5)))
	var kami := sd.get_unit(kres.spawned_unit_id)
	ck(kres.ok and kami.is_drone and not MCF.is_scout(kami), "and still a kamikaze drone")
	ck(rd.drone_flight_budget(scout) == 60 and rd.drone_flight_budget(kami) == 30, "scout flies 60, kamikaze 30")
	var far := rd.drone_flight_cells(scout)
	ck(far.has(Vector2i(51, 5)) and not far.has(Vector2i(52, 5)), "the scout's leash is 45 cells from the station")
	ck(not rd.drone_flight_cells(kami).has(Vector2i(22, 5)), "the kamikaze keeps its 15-cell leash")
	ck(not rd.resolve(DroneDetonateIntent.new(scout.id)).ok, "a scout drone can't detonate")
	ck(not rd.resolve(DroneMoveIntent.new(scout.id, friend.coord)).ok or friend.is_alive(), "a scout never rams")
	ck(friend.is_alive(), "nobody hurt by the scout")
	# Shot down beside a friend: it falls, no blast.
	scout.coord = friend.coord
	rd._drone_destroyed(scout, scout.coord, "shot down", 0)
	ck(not scout.is_alive() and friend.is_alive(), "a scout shot down over a soldier hurts nobody")
	var round_trip := IntentCodec.decode(IntentCodec.encode(SpawnDroneIntent.new(op.id, Vector2i(6, 5), true)))
	ck(round_trip.scout, "the drone kind travels over the network")

func _station_underfoot() -> void:
	var m := MapData.blank_arena(18, 12)
	m.set_spawn(Vector2i(5, 5), "drone_operator", 0)
	m.set_spawn(Vector2i(16, 10), "light_infantry", 1)
	var state := m.build_state(3)
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	var r := GameActionResolver.new(state)
	var op := state.grid.cell(Vector2i(5, 5)).occupant
	var at := Vector2i(6, 5)
	_deploy(r, op, at)
	state.grid.move_occupant(op.coord, at)
	op.remaining_ap = 2
	ck(r.station_pickup_cells(op).has(at), "standing on a deployed station still offers packing")
	var drone := r.active_drone_of(op)
	ck(drone != null and r.operator_controls(drone), "an operator on the pad controls its drone")
	var res := r.resolve(PickUpStationIntent.new(op.id, at))
	ck(res.ok and op.held_item_id == MCF.ITEM_DRONE_STATION, "the operator packs the station beneath their feet")
	ck(state.grid.cell(at).occupant == op, "packing leaves the operator on the cell")
