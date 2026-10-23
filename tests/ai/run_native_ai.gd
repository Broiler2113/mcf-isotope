extends "res://tests/SuiteBase.gd"

func run() -> void:
	var native := NativeKernels.ai()
	if native == null:
		ck(not OS.get_cmdline_user_args().has("--require-native"), "native AI kernel must load")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 734399
	_wave_fields(rng)
	_assignments(rng)
	_line_targets(rng)
	_nearest(rng)
	_decision_traces()
	NativeKernels.enabled = true
	print("Compared AI wave fields, firing-line indexes, tied army assignments and complete action/RNG traces.")

func _wave_fields(rng: RandomNumberGenerator) -> void:
	for sample in 80:
		var w := rng.randi_range(1, 45)
		var h := rng.randi_range(1, 35)
		var grid := Grid.new(w, h)
		for c: GridCell in grid.cells_flat():
			if rng.randf() < 0.25: c.set_feature(MCF.FEATURE_WALL)
		var seeds := PackedInt32Array()
		for i in sample % 8:
			seeds.append((rng.randi_range(0, h - 1) + 1) * (w + 2) + rng.randi_range(0, w - 1) + 1)
		if not seeds.is_empty(): seeds.append(seeds[0])
		var required := PackedInt32Array()
		for i in sample % 5:
			required.append((rng.randi_range(0, h - 1) + 1) * (w + 2) + rng.randi_range(0, w - 1) + 1)
		var off := {Vector2i(-100, -100): 0}
		NativeKernels.enabled = false
		var expected := AIController.wave(grid, seeds, off, required, sample % 4)
		NativeKernels.enabled = true
		var actual := AIController.wave(grid, seeds, off, required, sample % 4)
		ck(expected._d.to_byte_array() == actual._d.to_byte_array(), "wave %d preserves every distance and capped-layer boundary" % sample)
		ck(actual.at(Vector2i(-100, -100)) == 0 and actual.at(Vector2i(-101, -100)) == GeoField.FAR,
			"off-board source semantics are preserved")
		if not fails.is_empty(): return

func _assignments(rng: RandomNumberGenerator) -> void:
	for sample in 100:
		var rows: Array = []
		for i in (sample * 43) % 3500:
			rows.append([float(rng.randi_range(-8, 8)) * 0.25, rng.randi_range(1, 90),
				Vector2i(rng.randi_range(-3, 20), rng.randi_range(-3, 20))])
		var zones := {}
		for y in 12:
			for x in 12: zones[Vector2i(x, y)] = (x + y) % 4
		var expected := AIPlanner.new()
		var actual := AIPlanner.new()
		for planner: AIPlanner in [expected, actual]:
			planner._gun_spread = sample % 2 == 0
			planner._zone_of = zones
			planner._zone_cap = [0, 1, 2, 5]
		NativeKernels.enabled = false
		expected._assign_candidates(rows.duplicate())
		NativeKernels.enabled = true
		actual._assign_candidates(rows.duplicate())
		ck(expected.destinations == actual.destinations and expected.destinations.keys() == actual.destinations.keys(),
			"assignment %d preserves choices and insertion order, including tied scores" % sample)
		ck(var_to_bytes(expected.dest_score) == var_to_bytes(actual.dest_score), "assignment scores remain bit-identical")
		if not fails.is_empty(): return

func _line_targets(rng: RandomNumberGenerator) -> void:
	for sample in 12:
		var state := GameState.new(9 + sample * 3, 8 + sample * 2, 89)
		var stats: UnitStats = load("res://src/data/units/light_infantry.tres")
		for i in 24:
			var at := Vector2i(rng.randi_range(0, state.grid.width - 1), rng.randi_range(0, state.grid.height - 1))
			if state.grid.cell(at).occupant == null: state.spawn_unit(stats, at, 1)
		var expected := AIPlanner.new()
		var actual := AIPlanner.new()
		for planner: AIPlanner in [expected, actual]:
			planner._state = state
			planner._enemies = state.all_units()
		NativeKernels.enabled = false
		expected._build_line_targets()
		NativeKernels.enabled = true
		actual._build_line_targets()
		ck(expected._line_targets == actual._line_targets and expected._line_targets.keys() == actual._line_targets.keys(),
			"line targets %d preserve target and cell iteration order" % sample)
		ck(expected._enemy_value == actual._enemy_value, "native target indexing preserves enemy values")

func _nearest(rng: RandomNumberGenerator) -> void:
	var kernel := NativeKernels.ai()
	for sample in 100:
		var xy := PackedInt32Array()
		for i in sample:
			xy.append(rng.randi_range(-20, 20)); xy.append(rng.randi_range(-20, 20))
		var from := Vector2i(rng.randi_range(-10, 10), rng.randi_range(-10, 10))
		var best := -1
		var distance := 1 << 30
		for i in sample:
			var d := Combat.distance(from, Vector2i(xy[i * 2], xy[i * 2 + 1]))
			if d < distance: best = i; distance = d
		ck(kernel.nearest_index(from, xy) == best, "nearest target keeps the first equal-distance enemy")

func _decision_traces() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(32, 22)
	var kinds := ["light_infantry", "machinegunner", "sniper", "miner", "anti_tank", "engineer", "shield_bearer", "marksman"]
	for i in 16:
		var at := Vector2i(3 + i % 4, 3 + (i / 4) * 4)
		map.set_spawn(at, kinds[i % kinds.size()], 0)
		map.set_spawn(Vector2i(31 - at.x, at.y), kinds[(i + 3) % kinds.size()], 1)
	for y in range(2, 20):
		if y % 5 != 0: map.set_cell(Vector2i(15, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	for setting: Array in [[AIController.Difficulty.EASY, AIController.Style.STANDARD],
		[AIController.Difficulty.NORMAL, AIController.Style.RUSH],
		[AIController.Difficulty.HARD, AIController.Style.STANDARD],
		[AIController.Difficulty.HARD, AIController.Style.TURTLE]]:
		var expected := _trace(map, false, setting[0], setting[1])
		var actual := _trace(map, true, setting[0], setting[1])
		ck(expected == actual, "complete %s AI trace preserves decisions, resolved board and RNG after every action" % str(setting))
		if expected != actual:
			for i in mini(expected.size(), actual.size()):
				if expected[i] != actual[i]: print("First trace mismatch at action %d: %s / %s" % [i, expected[i][0], actual[i][0]]); break
			return

func _trace(map: MapData, native: bool, difficulty: int, style: int) -> Array:
	NativeKernels.enabled = native
	seed(714975) # EASY movement uses the engine global RNG as well as the match dice.
	var state := map.build_state(98217)
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.STANDARD
	var brains := {}
	for side in [0, 1]:
		var ai := AIController.new(side, difficulty)
		ai.style = style
		ai.bind_match(resolver)
		brains[side] = ai
	var trace: Array = []
	for step in 160:
		var ai: AIController = brains.get(state.active_player())
		var intent: Intent = ai._decide(state) if ai != null else EndTurnIntent.new()
		var result := resolver.resolve(intent)
		if not result.ok and ai != null: ai.notify_intent_denied(state)
		trace.append([IntentCodec.encode(intent), result.ok, StateCodec.encode(state), state.dice.checkpoint()])
		if state.turns.round_number >= 3: break
	trace.append(["global_rng", randi()])
	return trace
