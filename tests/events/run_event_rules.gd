extends "res://tests/SuiteBase.gd"
## Random events: barrage aim, raiders into bunkers and stations, fire, EMP on vehicles,
## zones on the useful plot, warnings held for the second player, army difficulty, minefields,
## no dice for an empty pool.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_barrage_aim()
	_bunker_raiders()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_events()
	_emp_vehicles()
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

	_events_land_on_the_useful_plot()
	_raiders_reach_a_station()
	if fails.is_empty():
		print("batch 0.9.4: counts, events, raiders, tunnels, asteroid plating and texture"
				+ " folders all hold")
	else:
		print("batch 0.9.4: %d failure(s)" % fails.size())

	_warning()
	_barrages()

	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_armies()
	_mines()

	_no_dice_for_empty_event_pool()

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

const ArmyBuilder := preload("res://rl/ArmyBuilder.gd")

func _map(style: int, seed: int, w := 40, h := 30, units := 8) -> MapData:
	var arng := RandomNumberGenerator.new()
	arng.seed = seed
	var m := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": w, "height": h,
			"density": 1, "seed": seed, "zones": 2, "units": units * 2 + 4, "civilians": 0, "civilian_count": 0})
	ArmyBuilder.populate(m, arng, units, 0)
	return m

func _resolver(m: MapData, mode: int, roster: Roster = null) -> GameActionResolver:
	GameConfig.game_mode = mode
	var st := m.build_state(4242, roster)
	var r := GameActionResolver.new(st)
	r.random_events = RandomEvents.new(false)
	r.update_airlocks()
	r.prepare_mode(m)
	return r

func _events() -> void:
	var r := _resolver(_map(MapGen.Style.TOWN, 21, 40, 30, 8), MatchMode.Kind.CAPTURE)
	r.random_events = RandomEvents.new(true, true, 1)
	var allowed := r._events_allowed()
	ck(allowed.has("dust") and allowed.has("minefield") and allowed.has("bounty") and allowed.has("fire"),
			"a town in Capture & Hold allows dust, the old minefield, the bounty and fire")
	# Fire: lit at the end of the round, then spreads once a round.
	var p := r._roll_event_params(RandomEvents.FIRE)
	r.random_events.announce(RandomEvents.FIRE, p, 1)
	r.land_random_events(ActionResult.success([]))
	var lit := _burning(r)
	ck(lit > 0, "the fire outbreak lights its zone (%d cells)" % lit)
	r.land_random_events(ActionResult.success([]))
	ck(_burning(r) >= lit, "event fire keeps spreading at round ends")
	# Dust: +1 to the roll needed beyond 3 cells, two rounds, one storm at a time.
	r.random_events.announce(RandomEvents.DUST, r._roll_event_params(RandomEvents.DUST), 1)
	r.land_random_events(ActionResult.success([]))
	ck(r.hit_need(6, 12.0) == mini(7, Combat.hit_number(6, 12.0) + 1) and r.hit_need(3, 12.0) == Combat.hit_number(3, 12.0),
			"dust storm: shots beyond 3 cells need one more")
	ck(not r._events_allowed().has("dust"), "no second dust storm while one blows")
	r.land_random_events(ActionResult.success([]))
	r.land_random_events(ActionResult.success([]))
	ck(r.random_events.dust_left == 0, "the dust storm blows over after two rounds")
	# Collapse.
	var walls := r._collapse_walls().size()
	r.random_events.announce(RandomEvents.COLLAPSE, r._roll_event_params(RandomEvents.COLLAPSE), 1)
	r.land_random_events(ActionResult.success([]))
	ck(r._collapse_walls().size() < walls, "a structural collapse brings walls down")
	# Reinforcements go to the side that is behind.
	for u: UnitInstance in r.state.living_units_of(1).slice(0, 4):
		r._kill(u, null, u.coord)
	var before := r.state.living_units_of(1).size()
	ck(int(r._reinforce_target().get("side", -1)) == 1, "reinforcements pick the weaker side")
	r.random_events.announce(RandomEvents.REINFORCE, r._roll_event_params(RandomEvents.REINFORCE), 1)
	r.land_random_events(ActionResult.success([]))
	ck(r.state.living_units_of(1).size() > before, "reinforcements land")
	# Bounty: 2 points to the enemy who kills the marked soldier.
	r._start_bounty(ActionResult.success([]))
	var target := r.state.get_unit(r.mode.bounty_unit)
	ck(target != null, "the bounty marks a soldier")
	var killer := 1 - target.owner
	var key := MatchMode.team_key(r.state.roster, killer)
	var pts := int(r.mode.scores.get(key, 0))
	r._kill(target, null, target.coord)
	r._check_bounty(ActionResult.success([]), killer)
	ck(int(r.mode.scores.get(key, 0)) == pts + 2 and r.mode.bounty_unit == -1, "a bounty kill scores 2 points")
	# Old minefield: outdoors only, hidden from everyone, no location in the report.
	var mres := ActionResult.success([])
	r._start_minefield(mres)
	var mines: Array[Vector2i] = []
	for y in r.state.grid.height:
		for x in r.state.grid.width:
			var c := r.state.grid.cell_fast(x, y)
			if c.feature_id == MCF.FEATURE_MINE and c.feature_owner == GameActionResolver.OLD_MINE_OWNER:
				mines.append(Vector2i(x, y))
	var outdoors := not mines.is_empty()
	for c in mines:
		var cell := r.state.grid.cell(c)
		outdoors = outdoors and cell.floor_type != MCF.FLOOR_FLAMMABLE \
				and r.state.grid.floor_look[c.y * r.state.grid.width + c.x] == 0
	ck(outdoors, "old mines lie outdoors (%d of them)" % mines.size())
	ck(not r.mine_visible_to(0, mines[0]) and not r.mine_visible_to(1, mines[0]), "nobody sees the old mines")
	ck(str(mres.log_lines).find("(") < 0, "the minefield report gives no location")
	var goes := 0
	for i in 60:
		r.state.grid.cell(mines[0]).set_feature(MCF.FEATURE_MINE, GameActionResolver.OLD_MINE_OWNER)
		if r._mine_on_path(null, [mines[0]]) != GameActionResolver.NOWHERE: goes += 1
	ck(goes > 5 and goes < 40, "an old mine goes off only some of the time (%d of 60)" % goes)
	# Where events may happen.
	var st := _resolver(_map(MapGen.Style.STATION, 22), MatchMode.Kind.ANNIHILATION)
	st.random_events = RandomEvents.new(true, true, 1)
	var sa := st._events_allowed()
	ck(not sa.has("dust") and sa.has("minefield") and not sa.has("bounty"), "a station supports old minefields, without dust or bounty")
	var ast := _resolver(_map(MapGen.Style.ASTEROID, 23), MatchMode.Kind.ANNIHILATION)
	ast.random_events = RandomEvents.new(true, true, 1)
	ck(ast._events_allowed().has("minefield") and not ast._events_allowed().has("dust"), "an asteroid: minefield yes, dust no")

## Owner (0.12): EMP bursts target vehicles — the zone is centered on a vehicle (crewed ones
## first), and its gun takes the damage.
func _emp_vehicles() -> void:
	var arng := RandomNumberGenerator.new()
	arng.seed = 61
	var m := MapGen.generate({"style": MapGen.Style.FIELD, "size": MapGen.SIZE_CUSTOM, "width": 44, "height": 34,
			"density": 0, "seed": 61, "zones": 2, "units": 24, "civilians": 0, "civilian_count": 0})
	ArmyBuilder.populate(m, arng, 8, 1, 1)
	var r := _resolver(m, MatchMode.Kind.ANNIHILATION)
	r.random_events = RandomEvents.new(true, true, 1)
	ck(not r.state.all_vehicles().is_empty(), "the test map has a vehicle")
	ck(r._events_allowed().has("emp"), "EMP is possible with a vehicle on the field")
	var p := r._roll_event_params(RandomEvents.EMP)
	var rect := Rect2i(int(p["x"]), int(p["y"]), int(p["w"]), int(p["h"]))
	var aimed: Vehicle = null
	for veh: Vehicle in r.state.all_vehicles():
		if veh.alive() and rect.has_point(veh.center()):
			aimed = veh
	ck(aimed != null, "the EMP zone is centered on a vehicle")
	var gun_before := aimed.component(MCF.COMP_GUN) if aimed != null and aimed.has_component(MCF.COMP_GUN) else -1
	r.random_events.announce(RandomEvents.EMP, p, 1)
	r.land_random_events(ActionResult.success([]))
	if gun_before > 0:
		ck(aimed.component(MCF.COMP_GUN) < gun_before, "the EMP damages that vehicle's gun")
	var bare := _resolver(_map(MapGen.Style.FIELD, 62), MatchMode.Kind.ANNIHILATION)
	bare.random_events = RandomEvents.new(true, true, 1)
	var has_gear := not bare.state.all_vehicles().is_empty() or not bare._emp_targets().is_empty()
	ck(bare._events_allowed().has("emp") == has_gear, "with nothing electronic on the field there is no EMP")

func _burning(r: GameActionResolver) -> int:
	var n := 0
	for y in r.state.grid.height:
		for x in r.state.grid.width:
			if r.state.grid.cell_fast(x, y).on_fire: n += 1
	return n

# --- item 6: газ и обстрел падают на полезный участок ------------------------------------
## На станции край карты — вакуум; зона, выпавшая там, травила пустоту. Зона обязана
## пересекаться с рамкой проходимого участка.
func _events_land_on_the_useful_plot() -> void:
	var outside := 0
	var zones := 0
	for seed_value: int in [11, 23, 57, 101]:
		var m := MapGen.generate({"style": MapGen.Style.STATION, "size": 2, "seed": seed_value,
				"civilians": 0})
		var state := m.build_state(seed_value)
		var resolver := GameActionResolver.new(state)
		var area := resolver._useful_rect()
		for id: String in [RandomEvents.GAS, RandomEvents.MORTAR]:
			for _i in 6:
				var p := resolver._roll_event_params(id)
				var z := Rect2i(int(p["x"]), int(p["y"]), int(p["w"]), int(p["h"]))
				zones += 1
				if not area.intersects(z):
					outside += 1
	ck(outside == 0, "%d of %d event zones fall outside the useful plot" % [outside, zones])

# --- item 6: рейдеры доходят до станции ---------------------------------------------------
## У станции по краям карты вакуум, а жилое начинается клеток через двадцать. Раньше армия
## искала место для высадки только у самой кромки и всегда «поворачивала назад».
func _raiders_reach_a_station() -> void:
	var landed := 0
	var tried := 0
	for seed_value: int in [11, 23, 57, 101]:
		var m := MapGen.generate({"style": MapGen.Style.STATION, "size": 2, "seed": seed_value,
				"civilians": 0})
		var state := m.build_state(seed_value)
		var resolver := GameActionResolver.new(state)
		for edge in 4:
			tried += 1
			var p := {"edge": edge, "from": state.grid.width / 3, "len": 8}
			if not resolver._army_spawn_cells(p).is_empty():
				landed += 1
	ck(landed == tried, "raiders find a landing on every station edge (%d of %d)" % [landed, tried])

func _arena() -> GameState:
	var m := MapData.blank_arena(16, 12)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(12, 5), "light_infantry", 1)
	var s := m.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	return s

func _warning() -> void:
	var s := _arena()
	var r := GameActionResolver.new(s)
	r.random_events = RandomEvents.new(false)
	r.random_events.announce(RandomEvents.GAS, {"x": 2, "y": 5, "w": 1, "h": 1}, 1)
	var saved := r.random_events.snapshot()
	r.random_events.restore(saved)
	s.dice.feed_scripted([6])
	var round_before := s.turns.round_number
	var result := r.resolve(EndTurnIntent.new(-1))
	ck(s.turns.round_number == round_before, "fixture ends first player's turn, not the round")
	ck(r.random_events.pending.size() == 1 and r.random_events.clouds.is_empty(), "mid-round handoff leaves the warning pending: the second player still gets to react")
	result = r.resolve(EndTurnIntent.new(-1))
	ck(s.turns.round_number == round_before + 1, "second handoff closes the round")
	ck(r.random_events.pending.is_empty() and r.random_events.clouds.size() == 1, "warning lands when the round closes, also after restore")
	ck(result.dice_events.any(func(e: Dictionary) -> bool: return e.get("kind") == "check"), "event ck survives end-turn result merging")
	ck(int(r.random_events.clouds[0]["left"]) == 3, "new gas keeps full lifetime")

func _barrages() -> void:
	var r := GameActionResolver.new(_arena())
	var p := {"x": 3, "y": 3, "w": 4, "h": 4}
	r.random_events.announce(RandomEvents.MORTAR, p, 1)
	var next := r._free_barrage_zone(p, Rect2i(0, 0, 16, 12))
	ck(not next.is_empty(), "another barrage finds room")
	ck(not Rect2i(3, 3, 4, 4).intersects(Rect2i(next["x"], next["y"], next["w"], next["h"])), "barrage warning rectangles never overlap")
	ck(r._free_barrage_zone(p, Rect2i(3, 3, 4, 4)).is_empty(), "full area skips barrage rather than hiding a warning")

var MainScript: GDScript

func state_of(m: MapData, seed_value := 77) -> GameState:
	var st := m.build_state(seed_value)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

func _armies() -> void:
	GameConfig.independent_army_difficulty = 2
	var rules := NetHandoff.encode_rules()
	GameConfig.independent_army_difficulty = 0
	NetHandoff.apply_rules(rules)
	ck(GameConfig.independent_army_difficulty == 2, "host army difficulty reaches guests")
	var st := state_of(MapData.blank_arena(20, 12))
	var r := GameActionResolver.new(st)
	var portable := StateCodec.encode_rules(r)
	var restored := GameActionResolver.new(st)
	StateCodec.apply_rules(restored, JSON.parse_string(JSON.stringify(portable)))
	ck(restored.random_events.army_difficulty == 2, "army difficulty survives save/replay rules")
	var mix := []
	for level in 3:
		r.random_events.army_difficulty = level
		var copy := RandomEvents.new()
		copy.restore(JSON.parse_string(JSON.stringify(r.random_events.snapshot())))
		ck(copy.army_difficulty == level, "event state preserves difficulty %d" % level)
		var pool := r._independent_roster()
		var infantry := pool.count("light_infantry") + pool.count("heavy_infantry")
		mix.append([float(infantry) / pool.size(), float(pool.count("anti_tank")) / pool.size()])
	ck(mix[0][0] > mix[1][0] and mix[1][0] > mix[2][0] and mix[0][1] < mix[1][1] and mix[1][1] < mix[2][1], "higher difficulty trades basic infantry for anti-tank and specialists")
	GameConfig.independent_army_difficulty = 1

func _mines() -> void:
	for env in ["town", "field", "station", "bunker", "asteroid"]:
		var kinds := {}
		for seed_value in range(1, 8):
			var m := MapData.blank_arena(18, 14)
			m.env = env
			for y in range(1, 13):
				for x in range(1, 17):
					m.set_look(y * m.width + x, MCF.Look.PLATE)
			m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
			m.set_spawn(Vector2i(15, 11), "light_infantry", 1)
			var st := state_of(m, seed_value)
			var peer := state_of(m, seed_value)
			var r := GameActionResolver.new(st)
			var other := GameActionResolver.new(peer)
			st.dice.begin_record()
			r._start_minefield(ActionResult.new())
			peer.dice.feed_scripted(st.dice.take_log())
			other._start_minefield(ActionResult.new())
			ck(st.digest_hash() == peer.digest_hash() and peer.dice.scripted_remaining() == 0 and peer.dice.fallback_rolls == 0, "%s minefield seed %d is deterministic" % [env, seed_value])
			var count := 0
			for c: GridCell in st.grid.cells_flat():
				if c.feature_id not in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE]: continue
				kinds[c.feature_id] = true
				count += 1
				if c.occupant != null or c.feature_owner != GameActionResolver.OLD_MINE_OWNER:
					ck(false, "old mine avoids occupied cells and is hostile to every side")
			ck(count > 0 and count <= GameActionResolver.MINEFIELD_MAX, "%s field contains mines even on decorated flooring" % env)
		ck(kinds.has(MCF.FEATURE_MINE) and kinds.has(MCF.FEATURE_AV_MINE) and RandomEvents.available_for_map(RandomEvents.MINEFIELD, env, 0), "%s supports both personnel and anti-vehicle old mines" % env)

## No dice for an event pool with nothing eligible; 0.12.7–0.12.8 replays keep the old tape.
func _no_dice_for_empty_event_pool() -> void:
	var ev := RandomEvents.new(true, true, 1, {RandomEvents.BOUNTY: 1})
	var dice := DiceService.new()
	dice.feed_scripted([])
	ck(ev._pick(dice, {RandomEvents.MORTAR: true}) == "" and dice.fallback_rolls == 0, "an empty event pool rolls no dice")
	ev.empty_pool_rolls = true
	dice.feed_scripted([1, 1, 1])
	ck(ev._pick(dice, {RandomEvents.MORTAR: true}) == "" and dice.scripted_remaining() == 0, "older uniform replays still consume their three dice")
