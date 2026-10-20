extends "res://tests/SuiteBase.gd"
## Bodies and captives: the death ledger, piles cleared from corridors, pulled bodies,
## captives freed, corpse drop rules, burnt bodies, nobody landing on a body.

func run() -> void:
	_corpse_pile_gets_cleared()
	if fails.is_empty():
		print("batch 0.9.3: accents, grill, corridors, doors, the border, empty space"
				+ " and corpse-pile clearing all hold")
	else:
		print("batch 0.9.3: %d failure(s)" % fails.size())

	_death_ledger()
	if fails.is_empty():
		print("batch 0.9.4: counts, events, raiders, tunnels, asteroid plating and texture"
				+ " folders all hold")
	else:
		print("batch 0.9.4: %d failure(s)" % fails.size())

	captives()
	pulled_bodies()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_bodies()

	capture()
	corpse_rules()

	_burnt_bodies_and_ledger()

	_nobody_lands_on_bodies()

## Завал из тел на единственном проходе (0.9.3). Носильщик с полными руками упирался в
## кучу и стоял так до конца боя: взять ещё тело он не может, а класть соглашался только
## когда рядом нет врага. Теперь он освобождает руки и разбирает завал по телу.
func _corpse_pile_gets_cleared() -> void:
	var w := 34
	var h := 5
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			# Коридор в одну клетку по середине, всё остальное — стены.
			var wall: bool = y != 2
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 2.0 if wall else 0.0, false,
					MCF.FEATURE_WALL if wall else "")
	m.set_spawn(Vector2i(1, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(32, 2), "light_infantry", 1)
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	# Завал ровно на дороге, и руки у бойца заняты.
	var pile := Vector2i(4, 2)
	st.grid.cell(pile).corpse_count = 3
	var me: UnitInstance = null
	for u: UnitInstance in st.all_units():
		if u.owner == 0:
			me = u
	me.carried_corpses = 1
	ck(st.grid.blocks_walk(pile), "a pile of bodies blocks the corridor to begin with")
	var ai := AIController.new(0, AIController.Difficulty.NORMAL)
	var pending: Array = []
	ai.intent_ready.connect(func(i: Intent) -> void: pending.append(i))
	var drops := 0
	var picks := 0
	var actions := 0
	while st.turns.round_number <= 10 and actions < 400:
		if st.active_player() != 0:
			r.resolve(EndTurnIntent.new())
			continue
		pending.clear()
		ai.begin_turn(st)
		if pending.is_empty():
			r.resolve(EndTurnIntent.new())
			continue
		var intent: Intent = pending[0]
		if intent is DropCorpseIntent:
			drops += 1
		elif intent is PickUpCorpseIntent:
			picks += 1
		actions += 1
		var res := r.resolve(intent)
		if not res.ok:
			ai.notify_intent_denied(st)
	var left: int = r.corpses_at(pile)
	_civilian_clears_too()
	ck(drops > 0, "the carrier puts its own body down to free its hands (%d drops)" % drops)
	ck(picks > 0, "and takes bodies out of the pile (%d pick-ups)" % picks)
	ck(left < 3, "the pile in the corridor actually shrinks (3 bodies -> %d)" % left)
	ck(left == 0 or not st.grid.blocks_walk(pile) or me.coord.x > 1,
			"and the carrier is no longer stuck where it started (at %s)" % str(me.coord))

## То же самое за НЕЙТРАЛА (0.9.3). Житель тащит тела как щит и по своей воле их не
## кладёт — поэтому перед завалом он застревал ровно так же. Единственное исключение —
## завал на дороге: ради него руки освобождаются. Спрашиваем сам набор ходов жителя:
## ход нейтрала проводит резолвер целым кругом, и гонять ради одной проверки целую
## партию тут не за чем.
func _civilian_clears_too() -> void:
	var w := 34
	var h := 5
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			var wall: bool = y != 2
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 2.0 if wall else 0.0, false,
					MCF.FEATURE_WALL if wall else "")
	m.set_spawn(Vector2i(3, 2), "civilian", MCF.Owner.NEUTRAL)
	m.set_spawn(Vector2i(32, 2), "light_infantry", 0)
	GameConfig.civilians_enabled = true
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false
	st.grid.cell(Vector2i(4, 2)).corpse_count = 2
	var civ: UnitInstance = null
	for u: UnitInstance in st.all_units():
		if MCF.is_neutral(u.owner):
			civ = u
	if civ == null:
		ck(false, "the civilian scenario actually places a civilian")
		return
	civ.civilian_active = true   # «вскрытый» житель: иначе он просто стоит (§3.10)
	var ai := AIController.new(civ.owner, AIController.Difficulty.NORMAL)
	ai._r = r   # обычно его ставит begin_turn; здесь спрашиваем генераторы напрямую
	civ.carried_corpses = 1
	var full := ai._neutral_candidates(st, r, civ)
	var frees_hands := false
	for cand: Dictionary in full:
		if cand["intent"] is DropCorpseIntent:
			frees_hands = true
	civ.carried_corpses = 0
	var empty_handed := ai._neutral_candidates(st, r, civ)
	var digs := false
	for cand: Dictionary in empty_handed:
		if cand["intent"] is PickUpCorpseIntent:
			digs = true
	ck(frees_hands, "a civilian with full hands puts its shield down to dig through a pile")
	ck(digs, "and with free hands it takes a body out of the pile blocking its way")

const TS = preload("res://tests/TestSupport.gd")

# --- item 1: павшие считаются по ледж, а не по трупам на доске ---------------------------
## Тело выбывает из партии, как только его подняли щитом (или сложили в кучу), — счёт по
## трупам на доске от этого полз назад. Ледж state.deaths только растёт и переживает и
## откат, и пересылку по сети.
func _death_ledger() -> void:
	var state := TS.build_map().build_state(TS.SEED)
	var resolver := GameActionResolver.new(state)
	var victim: UnitInstance = null
	var taker: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.owner == MCF.Owner.PLAYER_2 and victim == null:
			victim = u
		elif u.owner == MCF.Owner.PLAYER_1 and taker == null:
			taker = u
	ck(victim != null and taker != null, "the board has somebody to kill and somebody to carry")
	if victim == null or taker == null:
		return
	resolver._kill(victim)
	ck(int(state.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1, "a death is counted against its side")
	var snap := state.snapshot()
	# Тело уходит из партии — ровно то, что делают подбор щита, куча и кресло.
	state.grid.cell(victim.coord).occupant = null
	state.remove_unit(victim.id)
	var still := 0
	for u: UnitInstance in state.all_units():
		if u.owner == MCF.Owner.PLAYER_2 and u.status == MCF.Status.CORPSE:
			still += 1
	ck(still == 0, "the body is off the board")
	ck(int(state.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1,
			"and the side is still one man down (%s)" % str(state.deaths))
	state.deaths[MCF.Owner.PLAYER_2] = 7       # откат обязан вернуть ледж, а не оставить мой
	state.restore(snap)
	ck(int(state.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1, "undo brings the ledger back")
	var wire := StateCodec.encode(state)
	var there := StateCodec.decode(wire)
	ck(int(there.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1, "and it travels over the wire")
	# Дрон — техника станции: ни в живых, ни в павших.
	var drone := state.spawn_unit(load("res://src/data/units/drone.tres"),
			Vector2i(1, 1), MCF.Owner.PLAYER_1, false)
	drone.is_drone = true
	resolver._kill(drone)
	ck(int(state.deaths.get(MCF.Owner.PLAYER_1, 0)) == 0, "a downed drone is not a casualty")

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

func captives() -> void:
	var map := arena()
	map.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(5, 4), "heavy_infantry", 1)
	var r := resolver_for(map, 3)
	var s := r.state
	var a: UnitInstance = s.grid.cell(Vector2i(5, 5)).occupant
	var raider := s.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(6, 5), MCF.independent_slot(1))
	raider.status = MCF.Status.HELD
	raider.captor_id = a.id
	turn_to(r, 1)
	var hv: UnitInstance = s.grid.cell(Vector2i(5, 4)).occupant
	s.dice.feed_scripted([6, 1, 6, 1, 6, 1])
	r.resolve(CaptureIntent.new(hv.id, a.id))
	ck(a.is_held() and not raider.is_held() and raider.captor_id == -1,
		"a captor that is grabbed lets its own captive go at once")
	var b := arena()
	b.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	b.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	var r2 := resolver_for(b, 4)
	var a2: UnitInstance = r2.state.grid.cell(Vector2i(5, 5)).occupant
	var held := r2.state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(12, 12), MCF.independent_slot(1))
	held.status = MCF.Status.HELD
	held.captor_id = a2.id
	turn_to(r2, 0)
	r2.resolve(MoveIntent.new(a2.id, Vector2i(6, 5)))
	ck(not held.is_held(), "a captive left far from a living captor is freed after the next action")

func pulled_bodies() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 9), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 14), "light_infantry", 1)
	var r := resolver_for(map, 5)
	var s := r.state
	var u: UnitInstance = s.grid.cell(Vector2i(3, 9)).occupant
	var tank := s.spawn_vehicle("tank", Vector2i(4, 8), 0)
	tank.corpse_slots.append("Crewman A")
	tank.corpse_slots.append("Crewman B")
	var cells: Array[Vector2i] = r.unload_corpse_cells(u, tank)
	ck(cells.has(u.coord) and cells.has(Vector2i(2, 9)), "the body can go beside the puller or into its arms")
	var drop := r.resolve(VehicleUnloadCorpseIntent.new(u.id, tank.id, Vector2i(2, 9)))
	ck(drop.ok and s.grid.cell(Vector2i(2, 9)).corpse_count == 1, "the pulled body lands on the chosen cell")
	var carry := r.resolve(VehicleUnloadCorpseIntent.new(u.id, tank.id, u.coord))
	ck(carry.ok and u.carried_corpses == 1 and tank.corpse_slots.is_empty(), "clicking the puller makes it carry the body")
	var wire := IntentCodec.decode(IntentCodec.encode(VehicleUnloadCorpseIntent.new(u.id, tank.id, Vector2i(2, 9))))
	ck(wire is VehicleUnloadCorpseIntent and wire.to == Vector2i(2, 9), "the chosen cell travels over the network")
	var plain := IntentCodec.decode(IntentCodec.encode(VehicleUnloadCorpseIntent.new(u.id, tank.id)))
	ck(plain.to == VehicleUnloadCorpseIntent.NOWHERE, "an unaimed pull stays unaimed")

func _bodies() -> void:
	var m := MapData.blank_arena(10, 10)
	m.corpses = PackedInt32Array([22, 22, 22, 22, 22, 34])
	var grid := Grid.new(10, 10)
	m.apply_to_grid(grid)
	ck(grid.cell(Vector2i(2, 2)).feature_id == MCF.FEATURE_CORPSE_WALL and grid.cell(Vector2i(4, 3)).corpse_count == 1, "map bodies become real corpses and a five-body wall")
	m.apply_to_grid(grid)
	ck(grid.cell(Vector2i(4, 3)).corpse_count == 1, "applying a map twice does not duplicate its bodies")
	var captured := MapPresets.capture(m, Rect2i(1, 1, 5, 4))
	var turned := MapPresets.rotated(captured)
	ck(captured.corpses.size() == 6 and turned.corpses[-1] == [1, 3], "copying and rotating a selection preserves real bodies")

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

func capture() -> void:
	for scenario in range(16):
		var carry := bool(scenario & 1)
		var r := arena__player_reports()
		r.fog_enabled = bool(scenario & 2)
		var s := r.state
		var captive := s.grid.cell(Vector2i(2, 5)).occupant
		var captor := s.grid.cell(Vector2i(18, 5)).occupant
		captive.stats = load("res://src/data/units/heavy_infantry.tres")
		if scenario & 4: captor.stats = captive.stats
		if scenario & 8:
			captive.action_state = ActionState.new()
			captive.action_state.remaining_shots = 2
		s.grid.move_occupant(captor.coord, Vector2i(3, 5))
		r.team_visible_coords(0)
		s.turns.active_index = 1
		s.dice.feed_scripted([6, 1])
		ck(r.resolve(CaptureIntent.new(captor.id, captive.id)).ok and captive.is_held(), "enemy grabs soldier")
		if carry:
			ck(r.resolve(MoveIntent.new(captor.id, Vector2i(5, 5))).ok, "captor carries soldier")
		r.team_visible_coords(0)  # Warm the no-sight cache while the sole friendly is held.
		s.turns.active_index = 0
		captive.remaining_ap = 3
		s.dice.feed_scripted([6])
		ck(r.resolve(ReleaseIntent.new(captive.id)).ok and captive.is_alive(), "soldier breaks free")
		ck(r.can_shoot(captive, captor) == "" and r.shootable_target_ids(captive).has(captor.id), "freed soldier can target their captor")
		s.dice.feed_scripted([6, 1, 6, 1, 6, 1, 6, 1])
		ck(r.resolve(ShootIntent.new(captive.id, captor.id)).ok, "freed soldier fires at former captor")

func corpse_rules() -> void:
	var r := arena__player_reports()
	var u := r.state.grid.cell(Vector2i(2, 5)).occupant
	var buddy := add(r, "light_infantry", Vector2i(3, 5))
	u.carried_corpses = 1
	ck(not r.resolve(DropCorpseIntent.new(u.id, buddy.coord)).ok, "cannot drop a corpse underneath another living soldier")
	ck(not r.corpse_drop_cells(u).has(buddy.coord), "corpse drop preview excludes living soldiers")
	var pile := Vector2i(3, 6)
	r.state.grid.cell(pile).corpse_count = 1
	ck(not r.reachable_for(u, 20).can_reach(pile), "path planner never walks onto corpse piles")
	var v := r.state.spawn_vehicle("borg", Vector2i(7, 8), 0)
	var pilot := add(r, "light_infantry", Vector2i(6, 8))
	var helper := add(r, "light_infantry", Vector2i(6, 9))
	r.resolve(VehicleBoardIntent.new(pilot.id, v.id))
	r.state.dice.feed_scripted([1])
	r._destroy_vehicle(v, ActionResult.success([]))
	ck(v.wrecked and r.unloadable_corpse_vehicle_ids(helper).has(v.id), "destroyed borg offers corpse extraction")
	var res := r.resolve(VehicleUnloadCorpseIntent.new(helper.id, v.id))
	ck(res.ok and pilot.coord != v.origin and r.state.grid.cell(v.origin).occupant == null, "body is pulled out without removing borg wreck")

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

## burnt: laser kill and flamethrower kill; ledger for the marksman
func _burnt_bodies_and_ledger() -> void:
	var f := _field(func(m: MapData) -> void:
		m.set_spawn(Vector2i(10, 9), "marksman", 0)
		m.set_spawn(Vector2i(14, 9), "light_infantry", 1)
		m.set_spawn(Vector2i(10, 1), "flamethrower", 0)
		m.set_spawn(Vector2i(12, 1), "light_infantry", 1))
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var mk: UnitInstance = st.grid.cell(Vector2i(10, 9)).occupant
	var v1: UnitInstance = st.grid.cell(Vector2i(14, 9)).occupant
	var res := r.resolve(ShootIntent.new(mk.id, -1, -1, Vector2i(14, 9)))
	ck(res.ok and not v1.is_alive() and v1.burnt, "laser kill leaves a burnt body: " + res.reason)
	ck(st.kills.get(mk.id, []) == [2, 0], "ledger: the beam killed 2 down the row (%s)" % str(st.kills))
	var fl: UnitInstance = st.grid.cell(Vector2i(10, 1)).occupant
	var v2: UnitInstance = st.grid.cell(Vector2i(12, 1)).occupant
	res = r.resolve(ShootIntent.new(fl.id, -1, -1, Vector2i(11, 1)))
	ck(res.ok and not v2.is_alive() and v2.burnt, "flame kill leaves a burnt body: " + res.reason)
	var copy := GameState.new(1, 1)
	StateCodec.restore_into(copy, StateCodec.encode(st))
	ck(copy.get_unit(v2.id).burnt and not copy.get_unit(mk.id).burnt, "StateCodec keeps 'burnt'")

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

func ghosts(r: GameActionResolver) -> int:
	return r.state.all_units().filter(func(u: UnitInstance) -> bool:
		return u.is_on_field() and u.aboard_vehicle_id == -1 and u.borg_id == -1 \
			and r.state.grid.cell(u.coord).occupant != u).size()

## nobody lands on a body: map spawns, deployment and raiders
func _nobody_lands_on_bodies() -> void:
	var r := arena__audit0128(true)
	ck(ghosts(r) == 0 and r.state.grid.cell(Vector2i(18, 5)).occupant != null, "a map spawn on a body stands there; the body gives way")
	r.state.grid.cell(Vector2i(10, 10)).corpse_count = 1
	var before := r.state.all_units().size()
	ck(add(r, "light_infantry", Vector2i(10, 10)) == null and r.state.all_units().size() == before, "spawn_unit refuses a body cell instead of creating a ghost")

	r = arena__audit0128()
	for y in 16:
		for x in range(17, 22):
			if r.state.grid.cell(Vector2i(x, y)).occupant == null: r.state.grid.cell(Vector2i(x, y)).corpse_count = 1
	r.state.grid.cell(Vector2i(21, 8)).corpse_count = 0
	r._land_army({"edge": 1, "along": 8}, ActionResult.success([]))
	var raiders := r.state.all_units().filter(func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner))
	ck(raiders.size() >= 1 and ghosts(r) == 0, "raiders land only on cells free of bodies (%d)" % raiders.size())
