extends "res://tests/SuiteBase.gd"
## Vehicles: free boarding, crews reported dead with their hull, captures, sealed crews,
## wrecks, running over enemies and friends, borg weapons and bursts, debris across the
## wire, tanks kept out of space, undoable ramming.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	_vehicle_chunks()

	_free_boarding()
	_hull_kill_reports_its_crew()
	_capture_is_reported()
	_sealed_crew_cannot_disembark()
	_every_vehicle_leaves_a_wreck()

	borg_burst()

	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_cosmetic_undo()
	await _vehicle_timing()

	borg_weapons()

	_tank_runs_over_enemy()
	_friend_in_tank_path()

	_tanks_stay_out_of_space()

func state_of(m: MapData) -> GameState:
	var st := m.build_state(77)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

func _vehicle_chunks() -> void:
	var m := MapData.blank_arena(20, 10)
	m.env = "town"
	m.set_spawn(Vector2i(1, 2), "tank", 0, Vector2i.RIGHT)
	m.set_spawn(Vector2i(0, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 8), "light_infantry", 1)
	var walls := [MCF.FEATURE_WALL, MCF.FEATURE_WOOD_WALL, MCF.FEATURE_SANDBAG_WALL]
	for i in walls.size():
		m.set_cell(Vector2i(8, 2 + i), 0, 2.0, false, walls[i])
	m.set_look(2 * m.width + 8, MCF.wall_look(1))
	var st := state_of(m)
	var peer := state_of(m)
	var r := GameActionResolver.new(st)
	var other := GameActionResolver.new(peer)
	var v: Vehicle = st.all_vehicles()[0]
	var crew := st.grid.cell(Vector2i(0, 2)).occupant
	for intent in [VehicleBoardIntent.new(crew.id, v.id), VehicleMoveIntent.new(v.id, Vector2i.RIGHT, 8)]:
		st.dice.begin_record()
		var res := r.resolve(intent)
		peer.dice.feed_scripted(st.dice.take_log())
		var mirrored := other.resolve(IntentCodec.decode(IntentCodec.encode(intent)))
		ck(res.ok and mirrored.ok and st.digest_hash() == peer.digest_hash() and res.fx == mirrored.fx, "vehicle action and debris agree across the wire")
		if intent is VehicleMoveIntent:
			var chunks: Array = res.fx.filter(func(e): return e.fx == "chunks")
			ck(chunks.size() == 3, "one chunk burst per rammed wall tile")
			ck(chunks.any(func(e): return e.at == Vector2i(8, 2) and e.look == MCF.wall_look(1)), "wall chunks retain an explicitly chosen wall texture")
			for i in walls.size():
				var coord := Vector2i(8, 2 + i)
				ck(st.grid.cell(coord).feature_id == "" and chunks.any(func(e): return e.at == coord and e.fid == walls[i] and e.env == "town" and e.from.x < coord.x), "rammed " + walls[i] + " preserves its material and impact direction")
			var fx := FxDecals.new()
			fx.apply(res.fx)
			ck(fx.flying.any(func(f): return str(f.kind).begins_with("chunk:")), "vehicle wall destruction launches visible chunks")

func _field(spawns: Array, walls: Array = [], civ := false) -> Dictionary:
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for w: Vector2i in walls:
		m.set_cell(w, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = civ
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var guard := 0  # сторона может быть выбита первым же слотом жителей — не зацикливаемся
	while st.active_player() != MCF.Owner.PLAYER_1 and guard < 8:
		r.resolve(EndTurnIntent.new())
		guard += 1
	return {"s": st, "r": r}

func _u(st: GameState, c: Vector2i) -> UnitInstance:
	return st.grid.cell(c).occupant

func _free_boarding() -> void:
	var f := _field([[Vector2i(5, 5), "shuttle", MCF.Owner.PLAYER_1],
			[Vector2i(4, 5), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(10, 5), "borg", MCF.Owner.PLAYER_1],
			[Vector2i(9, 5), "sniper", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var li := _u(st, Vector2i(4, 5))
	var sn := _u(st, Vector2i(9, 5))
	li.remaining_ap = 0
	sn.remaining_ap = 0
	var sh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var bg: Vehicle = st.vehicle_on(Vector2i(10, 5))
	var res := r.resolve(VehicleBoardIntent.new(li.id, sh.id))
	ck(res.ok and li.aboard_vehicle_id == sh.id and li.remaining_ap == 0, "shuttle boarding is free at 0 AP: " + res.reason)
	res = r.resolve(VehicleBoardIntent.new(sn.id, bg.id))
	ck(res.ok and sn.borg_id == bg.id and sn.remaining_ap == 1, "borg boarding is free at 0 AP, pool grows by the borg's extra AP (ap %d): %s" % [sn.remaining_ap, res.reason])

## Подбитый корпус обязан отчитаться о ЭКИПАЖЕ в res.deaths, а не только о себе.
## _kill() сам в deaths ничего не кладёт, и _destroy_vehicle этого не делал: сжечь
## гружёный танк приносило ровно столько же, сколько пустой, и трое внутри не попадали
## ни в награду за убийство, ни в счётчик комбо.
func _hull_kill_reports_its_crew() -> void:
	var f := _field([[Vector2i(5, 5), "tank", MCF.Owner.PLAYER_1],
			[Vector2i(4, 4), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var veh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var crew := _u(st, Vector2i(4, 4))
	ck(r.resolve(VehicleBoardIntent.new(crew.id, veh.id)).ok, "crew boards the tank")
	ck(veh.occupants.has(crew.id), "crew is aboard")
	var res := ActionResult.new()
	res.ok = true
	r._destroy_vehicle(veh, res)
	ck(res.deaths.has(crew.id),
			"a destroyed hull reports its crew in deaths (got %s)" % str(res.deaths))
	ck(not crew.is_alive(), "the crew really died")

## Захват вражеской машины должен быть ВИДЕН в результате, а не только в строке лога:
## награда за него иначе неотличима от обычной посадки.
func _capture_is_reported() -> void:
	var f := _field([[Vector2i(5, 5), "tank", MCF.Owner.PLAYER_2],
			[Vector2i(4, 4), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var veh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var taker := _u(st, Vector2i(4, 4))
	ck(veh.owner == MCF.Owner.PLAYER_2, "the hull starts enemy-owned")
	var res := r.resolve(VehicleBoardIntent.new(taker.id, veh.id))
	ck(res.ok, "boarding an empty enemy hull is legal: " + res.reason)
	ck(veh.owner == MCF.Owner.PLAYER_1, "the hull changed hands (owner %d)" % veh.owner)
	ck(res.captured_vehicles.has(veh.id),
			"the capture is reported in captured_vehicles (got %s)" % str(res.captured_vehicles))

## disembark_enabled = false должен и НЕ ПРЕДЛАГАТЬ высадку, и ОТКАЗЫВАТЬ в ней. Одного
## фильтра в перечислителе мало: резолвер принимает намерения и не из него (встроенный ИИ,
## сеть, повтор), и запрет, живущий только в списке, обходится молча.
func _sealed_crew_cannot_disembark() -> void:
	var f := _field([[Vector2i(5, 5), "tank", MCF.Owner.PLAYER_1],
			[Vector2i(4, 4), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var veh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var crew := _u(st, Vector2i(4, 4))
	ck(r.resolve(VehicleBoardIntent.new(crew.id, veh.id)).ok, "crew boards")
	var cells: Array = r.vehicle_disembark_cells(veh)
	ck(not cells.is_empty(), "there IS somewhere to get out to")

	# Пока разрешено — высадка и предлагается, и проходит.
	var offered := 0
	for i: Intent in LegalIntents.enumerate(r, MCF.Owner.PLAYER_1):
		if i is VehicleDisembarkIntent and i.actor_id == crew.id:
			offered += 1
	ck(offered > 0, "with disembark on, the crew is offered a way out (%d)" % offered)

	r.disembark_enabled = false
	offered = 0
	for i: Intent in LegalIntents.enumerate(r, MCF.Owner.PLAYER_1):
		if i is VehicleDisembarkIntent and i.actor_id == crew.id:
			offered += 1
	ck(offered == 0, "sealed: no disembark is enumerated (got %d)" % offered)
	var res := r.resolve(VehicleDisembarkIntent.new(crew.id, cells[0]))
	ck(not res.ok, "sealed: the resolver refuses a disembark it never offered")
	ck(crew.aboard_vehicle_id == veh.id, "sealed: the crew is still aboard")

func _every_vehicle_leaves_a_wreck() -> void:
	for kind in ["shuttle", "tank", "borg"]:
		var f := _field([[Vector2i(6, 6), kind, MCF.Owner.PLAYER_1],
				[Vector2i(2, 2), "light_infantry", MCF.Owner.PLAYER_1],
				[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
		var st: GameState = f["s"]
		var r: GameActionResolver = f["r"]
		var veh: Vehicle = st.all_vehicles()[0]
		var res := ActionResult.new()
		r._damage_component(veh, MCF.COMP_HULL, 99, "test", res)
		ck(veh.wrecked and st.vehicles.has(veh.id), "%s leaves a wreck (roll %s)" % [kind, str(res.log_lines)])
		var exploded := res.log_lines.any(func(l: String) -> bool: return l.find("explodes") >= 0)
		if exploded:
			ck(res.fx.any(func(x: Dictionary) -> bool: return x.get("fx", "") == "debris"), "%s explosion scorches the floor" % kind)

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

func borg_burst() -> void:
	var map := arena()
	map.set_spawn(Vector2i(6, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(14, 8), "light_infantry", 1)
	map.set_spawn(Vector2i(7, 14), "light_infantry", 1)
	var r := resolver_for(map)
	var s := r.state
	var u: UnitInstance = s.grid.cell(Vector2i(6, 8)).occupant
	var borg := s.spawn_vehicle("borg", Vector2i(7, 8), 0)
	turn_to(r, 0)
	r.resolve(VehicleBoardIntent.new(u.id, borg.id))
	var t1: UnitInstance = s.grid.cell(Vector2i(14, 8)).occupant
	var t2: UnitInstance = s.grid.cell(Vector2i(7, 14)).occupant
	s.dice.feed_scripted([6, 1, 6, 1, 6, 1, 6, 1])
	var first := r.resolve(ShootIntent.new(u.id, t1.id, 1))
	ck(first.ok and not t1.is_alive() and u.action_state != null and u.action_state.remaining_shots == 3,
		"a borg that kills with one round keeps the other three")
	var ap := u.remaining_ap
	var second := r.resolve(ShootIntent.new(u.id, t2.id))
	ck(second.ok and u.remaining_ap == ap and not t2.is_alive(), "the rest of the burst goes to another target without AP")

var MainScript: GDScript

func state_of__reported_issues(m: MapData, seed_value := 77) -> GameState:
	var st := m.build_state(seed_value)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

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
	var st := state_of__reported_issues(vehicle_map())
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
	st = state_of__reported_issues(MapData.blank_arena(12, 10))
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

func make_main(m: MapData) -> Node:
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	return main

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

func borg_weapons() -> void:
	for kind in ["civilian", "miner", "shield_bearer", "engineer", "marksman", "sniper", "flamethrower", "anti_tank", "drone_operator"]:
		var r := arena__player_reports()
		var u := add(r, kind, Vector2i(6, 8))
		var v := r.state.spawn_vehicle("borg", Vector2i(7, 8), 0)
		var target := add(r, "light_infantry", Vector2i(11, 8), 1)
		ck(r.resolve(VehicleBoardIntent.new(u.id, v.id)).ok, kind + " boards borg")
		ck(u.fire_range() == 12 and u.rate_of_fire() == 4 and u.attack_ability() == "", kind + " uses borg weapon stats")
		r.state.dice.feed_scripted([6, 6, 6, 6, 6, 6, 6, 6])
		var shot := r.resolve(ShootIntent.new(u.id, target.id))
		var tracers := shot.fx.filter(func(e: Dictionary) -> bool: return e.get("fx") == "tracer")
		ck(shot.ok and tracers.size() == 1 and int(tracers[0].get("count", 0)) == 4, kind + " fires four bullets, no personal special attack")
		u.remaining_ap = 2
		ck(r.resolve(VehicleDisembarkIntent.new(u.id, Vector2i(6, 8))).ok and u.attack_ability() == u.stats.special_ability_id, kind + " regains personal weapon on exit")

func _field__playtest20(extra: Callable = Callable()) -> Dictionary:
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

## run over an enemy: tracks fx, kill ledger [1,1], undo gives it back, codec keeps it
func _tank_runs_over_enemy() -> void:
	var f := _field__playtest20(func(m: MapData) -> void: m.set_spawn(Vector2i(5, 5), "light_infantry", 1))
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

## a friend in the path is listed
func _friend_in_tank_path() -> void:
	var f := _field__playtest20(func(m: MapData) -> void: m.set_spawn(Vector2i(6, 5), "heavy_infantry", 0))
	var fr: Array = f["r"].vehicle_move_crushed_friends(f["t"], Vector2i(1, 0), 3)
	ck(fr.size() == 1 and fr[0].stats.id == "heavy_infantry", "friendly heavy in the path is listed (%d)" % fr.size())

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

## tanks stay out of space
func _tanks_stay_out_of_space() -> void:
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
