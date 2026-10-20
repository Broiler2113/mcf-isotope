extends "res://tests/SuiteBase.gd"
## Match modes: Capture & Hold zones and scoring, drawn zones, Holdout waves and frequency,
## wave rules, modes surviving saves.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_zone_placement()
	_capture_scoring()
	_holdout_waves()
	_mode_survives_saves()
	_roster_waves()
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_drawn_zones()

	waves()

	waves__player_reports()

	_holdout_waves_and_fire()

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

## Zones sit on open ground, never inside a deployment zone, and are (nearly) equally far
## from every side by walking distance — on a field, a town and a cramped bunker alike.
func _zone_placement() -> void:
	for style in [MapGen.Style.FIELD, MapGen.Style.TOWN, MapGen.Style.BUNKER]:
		var m := _map(style, 7 + style)
		var g := Grid.new(m.width, m.height)
		m.apply_to_grid(g)
		var zones := MatchMode.zones_for(m, 3, [0, 1], g)
		var name: String = MapGen.STYLE_NAMES[style]
		# A cramped bunker may get fewer zones: fairness is never traded for count.
		var want := 1 if style == MapGen.Style.BUNKER else 3
		ck(zones.size() >= want and zones.size() <= 3, "%s: zones placed (%d)" % [name, zones.size()])
		var open_ok := true
		var deploy_free := true
		for z in zones:
			var walkable := 0
			for y in range(int(z[1]), int(z[1]) + int(z[3])):
				for x in range(int(z[0]), int(z[0]) + int(z[2])):
					if g.cell_fast(x, y).walkable_terrain(): walkable += 1
					if m.get_zone(Vector2i(x, y)) >= 0: deploy_free = false
			open_ok = open_ok and walkable * 10 >= int(z[2]) * int(z[3]) * 6
		ck(open_ok, "%s: every zone is mostly open, walkable ground" % name)
		ck(deploy_free, "%s: no zone overlaps a deployment zone" % name)
		# Fairness: steps from each side's deployment zone to the zone's centre.
		var fair := true
		var spreads := []
		for z in zones:
			var c := Vector2i(int(z[0]) + int(z[2]) / 2, int(z[1]) + int(z[3]) / 2)
			var d := []
			for side in [0, 1]:
				var seeds := PackedInt32Array()
				for zc: Vector2i in m.zone_cells(side):
					if g.cell_fast(zc.x, zc.y).walkable_terrain():
						seeds.append((zc.y + 1) * (g.width + 2) + zc.x + 1)
				d.append(AIController.wave(g, seeds, {}).at(c))
			var spread := absi(int(d[0]) - int(d[1]))
			spreads.append(spread)
			fair = fair and spread <= 3 + int((int(d[0]) + int(d[1])) * 0.04)
		ck(fair, "%s: zones are fair to both sides (step differences %s)" % [name, spreads])

## Round-end scoring: more soldiers holds, a tie holds nothing, points race to the target,
## and wiping out the enemy still wins outright.
func _capture_scoring() -> void:
	GameConfig.capture_zones = 1
	GameConfig.capture_target = 3
	var m := _map(MapGen.Style.FIELD, 31)
	var r := _resolver(m, MatchMode.Kind.CAPTURE)
	var st := r.state
	var rect := r.mode.zone_rect(0)
	var foot := func(u: UnitInstance) -> bool: return not u.is_drone and u.aboard_vehicle_id == -1 and st.grid.in_bounds(u.coord)
	var a: Array = st.living_units_of(0).filter(foot)
	var b: Array = st.living_units_of(1).filter(foot)
	var free: Array[Vector2i] = []
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := st.grid.cell(Vector2i(x, y))
			if c.walkable_terrain() and c.occupant == null and c.vehicle_id == -1: free.append(Vector2i(x, y))
	ck(free.size() >= 3, "the zone has room for a test (%d free cells)" % free.size())
	st.grid.move_occupant(a[0].coord, free[0])
	st.grid.move_occupant(a[1].coord, free[1])
	st.grid.move_occupant(b[0].coord, free[2])
	var res := ActionResult.success([])
	r._mode_round_end(res)
	var ka := MatchMode.team_key(st.roster, 0)
	ck(r.mode.holders[0] == ka and int(r.mode.scores[ka]) == 1, "two against one holds the zone and scores 1")
	r._kill(a[1], null, a[1].coord)
	r._mode_round_end(ActionResult.success([]))
	ck(r.mode.holders[0] == "" and int(r.mode.scores[ka]) == 1, "one against one: a tie scores nothing")
	ck(not r.match_outcome()["over"], "no winner below the target")
	r.mode.scores[ka] = 3
	var out := r.match_outcome()
	ck(out["over"] and out["winner"] == ka and out["reason"] == "points", "reaching the target wins on points")
	r.mode.scores[ka] = 0
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	out = r.match_outcome()
	ck(out["over"] and out["reason"] == "rout", "wiping out the enemy still wins outright")

## Waves come every two rounds, or straight after the previous wave is wiped out (owner rule);
## all waves held wins, the defenders falling loses.
func _holdout_waves() -> void:
	var m := _map(MapGen.Style.FIELD, 41)
	m.spawns = m.spawns.filter(func(s: Dictionary) -> bool: return int(s["owner"]) != 1)
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	var r := _resolver(m, MatchMode.Kind.HOLDOUT, ro)
	r.mode.waves_total = 3   # the lobby offers 5/10/15/Endless; three keeps the test short
	var st := r.state
	ck(r.mode.wave_side == 1 and st.roster.team_of(0) == 0 and st.roster.team_of(1) == 1,
			"the waves side is its own team; the defenders share one")
	ck(st.turns.round_order.has(1), "the waves slot is in the turn order from the start")
	var res := r.open_match()
	ck(not r.mode.pending_wave.is_empty(), "wave 1 is announced in round 1")
	ck(not r.match_outcome()["over"], "an empty waves side is not a defeat")
	_end_round(r)
	ck(r.mode.wave == 1 and r.wave_fighters_left() > 0, "wave 1 lands at the end of round 1 (%d fighters)" % r.wave_fighters_left())
	ck(r.mode.pending_wave.is_empty() and r.mode.next_wave_round == 3, "the next wave is due in round 3")
	# Round 2: wipe wave 1 out mid-round — the next one is called at once, not in round 3.
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	ck(_any_move(r), "a defender action resolves after the wave is wiped")
	ck(st.turns.round_number == 2 and not r.mode.pending_wave.is_empty(),
			"wiping a wave out calls the next one straight away (round %d)" % st.turns.round_number)
	_end_round(r)
	ck(r.mode.wave == 2, "wave 2 landed early, at the end of round 2 (wave %d)" % r.mode.wave)
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	_any_move(r)
	_end_round(r)
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	var out := r.match_outcome()
	ck(r.mode.wave == 3 and out["over"] and out["reason"] == "held", "all three waves beaten: the defenders win (%s)" % [out])
	# Overrun: defenders gone while waves remain.
	var r2 := _resolver(m, MatchMode.Kind.HOLDOUT, ro)
	r2.open_match()
	_end_round(r2)
	for u: UnitInstance in r2.state.living_units_of(0):
		r2._kill(u, null, u.coord)
	out = r2.match_outcome()
	ck(out["over"] and out["reason"] == "overrun", "the defenders falling is an overrun")
	ck(r2.mode.wave_budget(2) > r2.mode.wave_budget(1), "each wave is bigger than the last")

## One legal move for the side to act (any defender, any free neighbouring cell).
func _any_move(r: GameActionResolver) -> bool:
	# The (now empty) waves side may be the one to act: pass to the defenders first.
	var round := r.state.turns.round_number
	while r.state.active_player() != 0 and r.state.turns.round_number == round:
		r.resolve(EndTurnIntent.new())
	var side := r.state.active_player()
	for u: UnitInstance in r.state.living_units_of(side):
		if u.is_drone or u.aboard_vehicle_id != -1 or not r.state.grid.in_bounds(u.coord):
			continue
		for n: Vector2i in r.state.grid.neighbors(u.coord):
			if not r.state.grid.blocks_walk(n) and r.resolve(MoveIntent.new(u.id, n)).ok:
				return true
	return false

## Play end-turns until the round number goes up.
func _end_round(r: GameActionResolver) -> void:
	var round := r.state.turns.round_number
	for i in 8:
		r.resolve(EndTurnIntent.new())
		if r.state.turns.round_number > round:
			return

func _mode_survives_saves() -> void:
	GameConfig.capture_zones = 3
	GameConfig.capture_target = 12
	var r := _resolver(_map(MapGen.Style.TOWN, 51), MatchMode.Kind.CAPTURE)
	r.mode.scores[MatchMode.team_key(r.state.roster, 0)] = 5
	r.mode.holders = ["s0", "", "s1"]
	r.mode.bounty_unit = 7
	r.mode.bounty_until = 4
	var rules := StateCodec.encode_rules(r)
	var copy := GameActionResolver.new(r.state)
	StateCodec.apply_rules(copy, JSON.parse_string(JSON.stringify(rules)))
	ck(JSON.stringify(copy.mode.snapshot()) == JSON.stringify(r.mode.snapshot()),
			"zones, scores, holders and the bounty survive a save (and the wire)")
	var old := GameActionResolver.new(r.state)
	StateCodec.apply_rules(old, {})
	ck(old.mode.kind == MatchMode.Kind.ANNIHILATION, "an old save without a mode plays annihilation")

func _roster_waves() -> void:
	var ro := Roster.default_duel(true)
	ck(ro.set_waves(2), "a waves slot fits")
	ck(ro.set_waves(3), "setting it again replaces it")
	var waves := ro.waves_side()
	ck(waves == 2 and ro.slots.size() == 3 and ro.slots[2].display_name == "Waves",
			"one waves slot, last in the roster")
	ck(ro.slots[2].ai_difficulty == 3, "AI - Learned can lead the waves")
	ck(ro.team_of(0) == 0 and ro.team_of(1) == 0 and ro.team_of(2) == 1, "players defend together")
	var back := Roster.from_dict(ro.to_dict())
	ck(back.waves_side() == 2, "the waves role travels with the roster")
	ro.strip_waves()
	ck(ro.waves_side() == -1 and ro.slots.size() == 2, "stripping removes the waves slot")

## Zones the host draws in the lobby replace Auto placement, ride to guests in the rules,
## are clipped to the board, and Auto (empty) still places them by the map.
func _drawn_zones() -> void:
	var m := MapData.blank_arena(20, 16)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(17, 13), "light_infantry", 1)
	GameConfig.game_mode = MatchMode.Kind.CAPTURE
	GameConfig.capture_drawn = [[4, 4, 3, 3], [12, 8, 2, 2]]
	var r := GameActionResolver.new(m.build_state(9))
	r.prepare_mode(m)
	ck(r.mode.zones == [[4, 4, 3, 3], [12, 8, 2, 2]] and r.mode.holders.size() == 2, "the battle uses the drawn zones")
	var rules := NetHandoff.encode_rules()
	GameConfig.capture_drawn = []
	NetHandoff.apply_rules(rules)
	ck(GameConfig.capture_drawn == [[4, 4, 3, 3], [12, 8, 2, 2]], "drawn zones reach guests in the lobby rules")
	ck(MatchMode.clean_drawn([[18, 14, 5, 5], [30, 30, 2, 2], [1, 1]], 20, 16) == [[18, 14, 2, 2]],
			"zones are clipped to the board and junk is dropped")
	ck(MatchMode.clean_drawn([[0, 0, 1, 1], [1, 0, 1, 1], [2, 0, 1, 1], [3, 0, 1, 1], [4, 0, 1, 1], [5, 0, 1, 1]], 20, 16).size() == 5,
			"no more than five zones (A to E)")
	GameConfig.capture_drawn = []
	var auto := GameActionResolver.new(m.build_state(9))
	auto.prepare_mode(m)
	ck(not auto.mode.zones.is_empty() and auto.mode.zones != [[4, 4, 3, 3], [12, 8, 2, 2]], "Auto still places zones by the map")
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

func waves() -> void:
	GameConfig.holdout_wave_every = 3
	var md := MatchMode.from_config()
	ck(md.wave_every == 3, "the lobby's wave frequency reaches the match")
	var back := MatchMode.new()
	back.restore(md.snapshot())
	ck(back.wave_every == 3, "wave frequency survives saves")
	GameConfig.game_mode = MatchMode.Kind.HOLDOUT
	GameConfig.random_events_enabled = false
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	GameConfig.roster = ro
	var map := MapData.blank_arena(30, 20)
	map.set_spawn(Vector2i(14, 10), "heavy_infantry", 0)
	var r := GameActionResolver.new(map.build_state(11, ro))
	r.random_events = RandomEvents.new(false)
	r.prepare_mode(map)
	r.fog_enabled = false
	r.mode.defender_value = 400
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	ck(r.mode.next_wave_round == r.state.turns.round_number + 3, "the next wave is due three rounds later")
	GameConfig.holdout_wave_every = MatchMode.WAVE_EVERY
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

func arena() -> GameActionResolver:
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

func waves__player_reports() -> void:
	var r := arena()
	r.mode.kind = MatchMode.Kind.HOLDOUT
	r.mode.wave_side = 1
	var shield := add(r, "shield_bearer", Vector2i(8, 5), 1)
	var shooter := r.state.grid.cell(Vector2i(2, 5)).occupant
	ck(not r._shield_blocks_shot(shooter, shield) and not r.is_fireproof(shield), "Holdout soldiers have no shield or fire immunity")
	var flame := add(r, "flamethrower", Vector2i(9, 5), 1)
	ck(not r.is_fireproof(flame), "Holdout flamethrowers have no fire immunity")
	ck(not r._flame_blocked(shield.coord), "Holdout shields do not stop flame spread")
	r.mode.excluded_units.assign(GameActionResolver.ARMY_ROSTER)
	r.mode.excluded_units.erase("light_infantry")
	r.mode.defender_value = 300
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	var first := r.state.all_units().filter(func(u: UnitInstance) -> bool: return u.neutral_group == 1)
	ck(not first.is_empty() and first.all(func(u: UnitInstance) -> bool: return u.stats.id == "light_infantry"), "Holdout restrictions apply to actual arrivals")
	r.random_events.excluded_units.assign(GameActionResolver.ARMY_ROSTER)
	ck(r._independent_roster().is_empty(), "all raider types can be excluded without fallback spawns")
	r.mode.pending_wave = {"edge": 2, "along": 8}
	r._land_wave(ActionResult.success([]))
	var display = load("res://scenes/Main.gd").new()
	display.state = r.state
	display.resolver = r
	var w1 := MCF.wave_slot(1)
	var w2 := MCF.wave_slot(2)
	ck(r.state.turns.round_order.has(w1) and r.state.turns.round_order.has(w2)
			and display._side_label(w1) == "Wave I" and display._side_label(w2) == "Wave II",
			"Initiative lists waves__player_reports separately by arrival")
	display.free()
	r.random_events.excluded_units.erase("light_infantry")
	r._land_army({"edge": 1, "along": 10}, ActionResult.success([]))
	var raiders := r.state.all_units().filter(func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner))
	ck(not raiders.is_empty() and raiders.all(func(u: UnitInstance) -> bool: return u.stats.id == "light_infantry" and u.neutral_group == 1), "raider arrivals respect exclusions and receive Roman group numbers")
	var rules := StateCodec.encode_rules(r)
	var loaded := GameActionResolver.new(StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state)))) )
	StateCodec.apply_rules(loaded, JSON.parse_string(JSON.stringify(rules)))
	ck(loaded.mode.wave_sizes == r.mode.wave_sizes and loaded.mode.excluded_units == r.mode.excluded_units and loaded.random_events.excluded_units == r.random_events.excluded_units, "wave groups and independent restrictions survive JSON save/load")

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

## Holdout waves land beside bodies, and the wave AI knows its flamers and shields burn
func _holdout_waves_and_fire() -> void:
	var r := arena__audit0128()
	r.mode.kind = MatchMode.Kind.HOLDOUT
	r.mode.wave_side = 1
	r.mode.defender_value = 300
	for x in 22:
		r.state.grid.cell(Vector2i(x, 0)).corpse_count = 1
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	ck(ghosts(r) == 0, "Holdout waves never land on bodies")

	# Wave flamers and shields lost their immunity in the rules; the AI must know it too.
	var flame := add(r, "flamethrower", Vector2i(8, 8), 1)
	var shield := add(r, "shield_bearer", Vector2i(8, 9), 1)
	var mine := add(r, "flamethrower", Vector2i(4, 12), 0)
	var ai := AIController.new(1)
	ai._r = r
	ck(ai._avoids_fire(flame) and ai._avoids_fire(shield), "wave AI keeps flamers and shields away from fire")
	ck(not ai._avoids_fire(mine), "a defender's flamethrower is still fireproof to the AI")
	var planner := AIPlanner.new()
	planner._r = r
	planner._state = r.state
	r.state.grid.cell(Vector2i(12, 12)).on_fire = true
	ck(planner._score_cell(flame, Vector2i(12, 11), 0, 0, false) <= -1e8, "planner refuses fire-adjacent cells for wave flamers")
