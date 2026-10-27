extends "res://tests/SuiteBase.gd"
## AI rules: HARD leaves announced barrages, neutrals keep shooting AP and hunt bought
## civilians, ruthless civilians, marksman and vehicle choices.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_hard_ai_leaves_zones()

	_neutrals()

	_neutral_shoots_bought_civilian()

	ai_vehicles_and_beam()

	_ruthless_civilians()
	_civilians_wake_by_sight()
	_crew_unseen_by_civilians()

	_hard_ai_storms_vehicles()

## A HARD soldier inside an announced barrage walks out before shooting; it never ends
## an ordinary move inside one.
func _hard_ai_leaves_zones() -> void:
	var m := MapData.blank_arena(30, 20)
	m.set_spawn(Vector2i(10, 10), "light_infantry", 1)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 0)   # in range: without the rule it would shoot
	var s := m.build_state(5)
	s.turns.round_order.assign([1, 0])
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	r.random_events = RandomEvents.new(true, true, 1)
	r.random_events.announce(RandomEvents.MORTAR, {"x": 8, "y": 8, "w": 5, "h": 5}, 1)
	var zone := Rect2i(8, 8, 5, 5)
	var normal := AIController.new(1, AIController.Difficulty.NORMAL)
	normal.bind_match(r)
	ck(not normal._decide(s) is MoveIntent, "NORMAL AI ignores the warning and shoots (unchanged)")
	var ai := AIController.new(1, AIController.Difficulty.HARD)
	ai.bind_match(r)
	var intent: Intent = ai._decide(s)
	ck(intent is MoveIntent and not zone.has_point((intent as MoveIntent).target),
			"HARD soldier in an announced barrage moves out of it before shooting")
	r.random_events.pending.clear()
	var calm := AIController.new(1, AIController.Difficulty.HARD)
	calm.bind_match(r)
	ck(not calm._decide(s) is MoveIntent, "with no warning HARD just shoots")

func _neutrals() -> void:
	var state := GameState.new(20, 12, 9)
	var stats: UnitStats = load("res://src/data/units/light_infantry.tres")
	var neutral := state.spawn_unit(stats, Vector2i(4, 4), MCF.Owner.NEUTRAL)
	neutral.civilian_active = true
	var enemy := state.spawn_unit(stats, Vector2i(7, 4), 0)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var ai := AIController.new(MCF.Owner.NEUTRAL, AIController.Difficulty.HARD)
	var candidates := ai._neutral_candidates(state, r, neutral)
	ck(not candidates.is_empty() and candidates.all(func(c: Dictionary) -> bool: return c["intent"] is ShootIntent), "armed neutral shoots before moving or collecting corpses")
	state.grid.cell(enemy.coord).occupant = null
	enemy.coord = Vector2i(9, 5)
	state.grid.cell(enemy.coord).occupant = enemy
	var move := ai._neutral_firing_move(state, r, neutral)
	ck(not move.is_empty(), "neutral finds a firing position while keeping shooting AP")
	state.turns.round_order = [MCF.Owner.NEUTRAL, 0]
	state.turns.active_index = 0
	var result := r.advance_civilians()
	var walks := {}
	var count := 0
	for event: Dictionary in result.dice_events:
		if event.get("kind", "") != "walk": continue
		count += 1
		var key := str([event["unit"], event["from"], event["path"]])
		ck(not walks.has(key), "neutral movement is emitted only once for replay animation")
		walks[key] = true
	ck(count > 0, "neutral replay regression exercises a movement")

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

func _neutral_shoots_bought_civilian() -> void:
	var f := _field([[Vector2i(5, 5), "civilian", MCF.Owner.PLAYER_1],
			[Vector2i(9, 5), "civilian", MCF.Owner.NEUTRAL],
			[Vector2i(28, 12), "light_infantry", MCF.Owner.PLAYER_2]], [], true)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var mine := _u(st, Vector2i(5, 5))
	var fired := false
	for i in 6:
		var res := r.resolve(EndTurnIntent.new())
		for l: String in res.log_lines:
			if l.find("Civilian → Civilian") >= 0:
				fired = true
		if fired or not mine.is_alive():
			break
	ck(fired or not mine.is_alive(), "a neutral civilian opens fire on a player's civilian instead of fleeing its lane")

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

func ai_vehicles_and_beam() -> void:
	# A marksman whose beam would die in the walls does not fire; with a clear line it does.
	var map := arena()
	map.set_spawn(Vector2i(2, 5), "marksman", 0)
	map.set_spawn(Vector2i(12, 5), "light_infantry", 1)
	for x in range(4, 9):
		map.set_cell(Vector2i(x, 5), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var r := resolver_for(map, 9)
	var s := r.state
	var mk: UnitInstance = s.grid.cell(Vector2i(2, 5)).occupant
	var ai := AIController.new(0, AIController.Difficulty.HARD)
	ai.bind_match(r)
	var beam: Dictionary = ai._laser_outcome(s, r, mk, Vector2i(12, 5))
	ck((beam["kills"] as Array).is_empty(), "five walls drain the beam before the target")
	var shot: Dictionary = ai._best_shoot(s, r, mk)
	ck(shot.is_empty(), "the AI marksman does not waste a shot the walls would swallow")
	for x in range(4, 9):
		s.grid.cell(Vector2i(x, 5)).clear_feature()
		s.grid.cell(Vector2i(x, 5)).cover_height = 0.0
	shot = ai._best_shoot(s, r, mk)
	ck(not shot.is_empty(), "with a clear line the AI marksman fires")
	# Marksmen and anti-tank soldiers deal with tanks; nobody else hugs the hull.
	var vmap := arena(30, 20)
	vmap.set_spawn(Vector2i(2, 10), "marksman", 0)
	vmap.set_spawn(Vector2i(4, 16), "anti_tank", 0)
	vmap.set_spawn(Vector2i(6, 4), "light_infantry", 0)
	vmap.set_spawn(Vector2i(27, 2), "light_infantry", 1)
	var vr := resolver_for(vmap, 13)
	var vs := vr.state
	var tank := vs.spawn_vehicle("tank", Vector2i(14, 9), 1)
	var mk2: UnitInstance = vs.grid.cell(Vector2i(2, 10)).occupant
	var at: UnitInstance = vs.grid.cell(Vector2i(4, 16)).occupant
	var vai := AIController.new(0, AIController.Difficulty.HARD)
	vai.bind_match(vr)
	var vshot: Dictionary = vai._best_vehicle_shot(vs, vr, mk2)
	ck(not vshot.is_empty(), "the AI marksman burns an enemy tank on its line")
	vai._r = vr
	var approach: Dictionary = vai._move_to_vehicle(vs, at)
	if not approach.is_empty():
		var dest: Vector2i = approach["intent"].target
		var nearest := 99
		for fc: Vector2i in tank.footprint():
			nearest = mini(nearest, Combat.distance(dest, fc))
		ck(nearest >= AIPlanner.AT_MIN_RANGE, "the anti-tank soldier stops at firing distance (%d)" % nearest)
	else:
		ck(true, "the anti-tank soldier has no approach to make")
	turn_to(vr, 0)
	vai.begin_turn(vs)
	var close: float = float(vai._planner._veh_close.get(tank.footprint()[0] + Vector2i(-1, 0), 0.0))
	ck(vai._planner._gun_spread and close > 0.0, "the plan sees the tank's gun and the danger beside its hull")

## ruthless civilians: an active civilian with a soldier next to it never retreats
## Owner rule 2026-10-27: seeing a civilian wake up wakes you too, down the line, into the
## same group. A wall, or no straight line at all, keeps a civilian asleep.
func _civilians_wake_by_sight() -> void:
	var m := MapData.new(30, 16)
	for y in 16:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_cell(Vector2i(10, 11), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	m.set_spawn(Vector2i(2, 8), "light_infantry", 0)
	m.set_spawn(Vector2i(28, 0), "light_infantry", 1)
	var civ := {}
	for name: String in ["a", "b", "c", "d", "e", "f"]:
		var at: Vector2i = {"a": Vector2i(10, 8), "b": Vector2i(10, 2), "c": Vector2i(16, 8),
			"d": Vector2i(20, 2), "e": Vector2i(25, 13), "f": Vector2i(10, 15)}[name]
		m.set_spawn(at, "civilian", MCF.Owner.NEUTRAL)
		civ[at] = name
	GameConfig.civilians_enabled = true
	var st: GameState = m.build_state(5)
	var r: GameActionResolver = GameActionResolver.new(st)
	var by_name := {}
	for u in st.all_units():
		if civ.has(u.coord):
			by_name[civ[u.coord]] = u
	ck(by_name.size() == 6, "six civilians placed")
	var res := r.resolve(EndTurnIntent.new())
	ck(res.ok, "the turn passes")
	var a: UnitInstance = by_name["a"]
	ck(a.neutral_group != 0, "a civilian in sight of the soldier wakes")
	for name: String in ["b", "c", "d"]:
		var u: UnitInstance = by_name[name]
		ck(u.civilian_active and u.neutral_group == a.neutral_group,
				"civilian %s, who saw one wake, wakes into the same group (%d vs %d)" % [name, u.neutral_group, a.neutral_group])
	for name: String in ["e", "f"]:
		var u: UnitInstance = by_name[name]
		ck(not u.civilian_active and u.neutral_group == 0, "civilian %s, with no clear line, sleeps on" % name)

## Crew inside a tank are off the board: no civilian sees them, wherever it stands (a sleeper
## on the x == y diagonal used to, since an off-board line counted as clear).
func _crew_unseen_by_civilians() -> void:
	var m := MapData.new(30, 16)
	for y in 16:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(5, 14), "light_infantry", 0)
	m.set_spawn(Vector2i(28, 0), "light_infantry", 1)
	m.set_spawn(Vector2i(12, 12), "civilian", MCF.Owner.NEUTRAL)
	GameConfig.civilians_enabled = true
	var st: GameState = m.build_state(5)
	var tank: Vehicle = st.spawn_vehicle("tank", Vector2i(1, 4), 0)
	var crew: UnitInstance = st.grid.cell(Vector2i(5, 14)).occupant
	st.grid.cell(crew.coord).occupant = null
	crew.coord = GameActionResolver.OFFBOARD
	crew.aboard_vehicle_id = tank.id
	tank.occupants.append(crew.id)
	var civ: UnitInstance = st.grid.cell(Vector2i(12, 12)).occupant
	var r: GameActionResolver = GameActionResolver.new(st)
	ck(r.resolve(EndTurnIntent.new()).ok, "the turn passes with a crewed tank")
	ck(civ != null and not civ.civilian_active and civ.neutral_group == 0,
			"a civilian on the diagonal does not see the crew inside a tank")

func _ruthless_civilians() -> void:
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
	var st: GameState = m.build_state(5)
	var r: GameActionResolver = GameActionResolver.new(st)
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

	# ...and grabs a body next to it first, and never offers to put one down
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

## fix-7 #8 (owner): HARD climbs into an enemy shuttle, tank or empty borg beside it before it
## shoots anyone, and walks up to one within two moves when the way is not under fire.
## NORMAL keeps shooting.
func _hard_ai_storms_vehicles() -> void:
	for kind: String in ["shuttle", "tank", "borg"]:
		var m := MapData.blank_arena(30, 16)
		m.set_spawn(Vector2i(10, 6), kind, 0, Vector2i(1, 0))
		m.set_spawn(Vector2i(9, 6), "light_infantry", 1)
		m.set_spawn(Vector2i(9, 12), "light_infantry", 0)   # an easy shot the storm must beat
		var s := m.build_state(5)
		s.turns.round_order.assign([1, 0])
		s.turns.active_index = 0
		var r := GameActionResolver.new(s)
		r.fog_enabled = false
		var normal := AIController.new(1, AIController.Difficulty.NORMAL)
		normal.bind_match(r)
		ck(not normal._decide(s) is VehicleBoardIntent, "NORMAL AI doesn't storm the enemy %s" % kind)
		var hard := AIController.new(1, AIController.Difficulty.HARD)
		hard.bind_match(r)
		var it: Intent = hard._decide(s)
		ck(it is VehicleBoardIntent, "HARD storms the empty enemy %s beside it (got %s)" % [kind, it])
		if it is VehicleBoardIntent:
			var res := r.resolve(it)
			ck(res.ok and s.get_vehicle(it.vehicle_id).owner == 1, "and takes it: %s" % res.reason)
	# Walking up: a shuttle six cells away, nobody covering it.
	var m2 := MapData.blank_arena(30, 16)
	m2.set_spawn(Vector2i(16, 6), "shuttle", 0)
	m2.set_spawn(Vector2i(9, 6), "light_infantry", 1)
	m2.set_spawn(Vector2i(28, 15), "light_infantry", 0)
	var s2 := m2.build_state(5)
	s2.turns.round_order.assign([1, 0])
	s2.turns.active_index = 0
	var r2 := GameActionResolver.new(s2)
	r2.fog_enabled = false
	var hard2 := AIController.new(1, AIController.Difficulty.HARD)
	hard2.bind_match(r2)
	var step: Intent = hard2._decide(s2)
	ck(step is MoveIntent and Combat.distance((step as MoveIntent).target, Vector2i(16, 6)) <= 2,
			"HARD walks up to an enemy shuttle it can take (got %s)" % [step])
