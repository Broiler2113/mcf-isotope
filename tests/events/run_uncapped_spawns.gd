extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var r := GameActionResolver.new(MapData.blank_arena(48, 40).build_state(37))
	var spots := r._army_band_cells(0, 1, 6)
	ck(spots.size() > 60, "edge landing searches beyond sixty cells")
	var excluded: Array[String] = []
	for id: String in r.ARMY_ROSTER:
		if id != "light_infantry": excluded.append(id)
	var cost: int = r._army_stats("light_infantry").cost
	var count := r._spawn_budget(spots, cost * 125, 0, excluded, 1)
	ck(count == 125, "a funded wave spawns 125 soldiers")
	var all_excluded: Array[String] = []
	all_excluded.assign(r.ARMY_ROSTER)
	ck(r._spawn_budget(spots, cost * 125, 0, all_excluded) == 0, "all restrictions terminate without spawning")
	var cells := r._hallway_spawn_cells(Vector2i(20, 20))
	ck(cells.size() > 60, "hallway reinforcements also search beyond sixty cells")
	r.random_events = RandomEvents.new(true)
	r.random_events.excluded_units = excluded
	r._land_army({"edge": 2, "from": 25, "len": 8}, ActionResult.success([]))
	var raiders := 0
	for u: UnitInstance in r.state.all_units():
		if MCF.is_independent(u.owner): raiders += 1
	ck(raiders == 125, "raiders match a large defender budget without a unit cap")
	# The same rules apply after a JSON save round trip.
	var rules: Dictionary = JSON.parse_string(JSON.stringify(StateCodec.encode_rules(r)))
	var loaded := GameActionResolver.new(StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state)))))
	StateCodec.apply_rules(loaded, rules)
	ck(loaded.random_events.excluded_units == excluded, "saved raider restrictions survive")
	ck(loaded._spawn_budget(loaded._army_band_cells(1, 2, 8), cost * 90, 1, excluded, 2) == 90,
			"a resumed match can spawn more than sixty soldiers")
	# Pre-cohort Holdout saves get a deterministic, idempotent initiative upgrade.
	var old := GameActionResolver.new(MapData.blank_arena(20, 16).build_state(8))
	old.state.roster.set_waves(1)
	var wave_side := old.state.roster.waves_side()
	var enemy := old.state.spawn_unit(r._army_stats("light_infantry"), Vector2i(5, 5), wave_side)
	old.state.turns.round_order.assign([0, wave_side])
	old.state.turns.active_index = 1
	var legacy := {"mode": {"kind": MatchMode.Kind.HOLDOUT, "wave_side": wave_side, "wave": 3,
			"waves_total": 12, "next_wave_round": 9, "wave_spawned": 150}}
	var dice := old.state.dice.own_rolls
	StateCodec.apply_rules(old, legacy)
	ck(enemy.neutral_group == 3 and old.state.turns.active_slot() == MCF.wave_slot(3), "old force retains its active turn in a wave cohort")
	ck(old.mode.next_wave_round == 9 and old.mode.wave_spawned == 150, "loading retains wave schedule and cumulative progress")
	var once := JSON.stringify(StateCodec.encode(old.state))
	StateCodec.apply_rules(old, StateCodec.encode_rules(old))
	ck(JSON.stringify(StateCodec.encode(old.state)) == once, "wave migration is idempotent")
	ck(old.state.dice.own_rolls == dice, "migration consumes no gameplay dice")
