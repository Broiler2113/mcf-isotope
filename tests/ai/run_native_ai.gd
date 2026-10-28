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
	_plan_scores(rng)
	_decision_traces()
	NativeKernels.enabled = true
	print("Compared AI wave fields, firing-line indexes, tied army assignments, plan cell scores and complete action/RNG traces.")

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

## The staff plan natively (MCFPlanScorer): the threat map, and every candidate row of every
## soldier, native and GDScript, compared exactly, on generated boards strewn with trenches, embrasures,
## hedgehogs, cover, fire, smoke and gas, tanks and a wreck, under every HARD personality
## and the civilians' classic weights, with and without capture objectives.
func _plan_scores(rng: RandomNumberGenerator) -> void:
	var kinds := ["light_infantry", "machinegunner", "sniper", "miner", "anti_tank", "engineer",
		"shield_bearer", "marksman", "heavy_infantry", "flamethrower"]
	var rows := 0
	var native_soldiers := 0
	var beam_records := 0
	for board in 6:
		var style: int = [MapGen.Style.TOWN, MapGen.Style.STATION, MapGen.Style.FIELD][board % 3]
		var m := MapGen.generate({"style": style, "size": 1, "seed": 4100 + board, "civilians": false})
		var state := m.build_state(77 + board)
		var grid := state.grid
		var open: Array[Vector2i] = []
		for c: GridCell in grid.cells_flat():
			if c.occupant == null and c.vehicle_id == -1 and c.cover_height == 0.0 and not c.is_space:
				open.append(c.coord)
		for i in open.size():
			var j := rng.randi_range(i, open.size() - 1)
			var t := open[i]
			open[i] = open[j]
			open[j] = t
		var next := 0
		# Two tanks a side, one of them wrecked, where their footprint is open floor.
		for side in [0, 1, 0, 1]:
			while next < open.size():
				var at := open[next]
				next += 1
				var free := true
				for dy in 3:
					for dx in 3:
						var fc := grid.cell(at + Vector2i(dx, dy))
						free = free and fc != null and fc.occupant == null and fc.vehicle_id == -1 \
								and fc.cover_height == 0.0 and not fc.is_space
				if free:
					var veh: Vehicle = state.spawn_vehicle("tank", at, side)
					if side == 1 and state.all_vehicles().size() == 4: veh.wrecked = true
					break
		var marks: Array[GridCell] = []
		for k in 90:
			if next >= open.size(): break
			var c := grid.cell(open[next])
			next += 1
			if c.vehicle_id != -1: continue
			match k % 9:
				0: c.set_feature(MCF.FEATURE_TRENCH)
				1: c.set_feature(MCF.FEATURE_HEDGEHOG_SANDBAGS)
				2: c.set_feature(MCF.FEATURE_DOT_OPEN)
				3: c.set_feature(MCF.FEATURE_SANDBAGS)
				4: c.on_fire = true
				5: c.smoke = true
				6: c.gas = true
				7: c.set_feature(MCF.FEATURE_DIRT_PILE)
				_: c.set_feature(MCF.FEATURE_WALL)
			marks.append(c)
		var civ_slot := MCF.neutral_group_slot(1)
		for k in 54:
			if next >= open.size(): break
			var at := open[next]
			next += 1
			if grid.cell(at).occupant != null or grid.cell(at).vehicle_id != -1: continue
			var owner: int = civ_slot if k % 9 == 8 else k % 2
			var u := state.spawn_unit(StateCodec.load_stats("civilian" if owner == civ_slot else kinds[k % kinds.size()]), at, owner)
			if u == null: continue
			if owner == civ_slot:
				u.civilian_active = true
				u.neutral_group = 1
			if k % 7 == 3: u.remaining_ap = 1
			if k % 11 == 5: u.move_credit = 2
			if k % 13 == 6: u.carried_corpses = 1
			if k % 17 == 9: u.status = MCF.Status.CORPSE
		var r := GameActionResolver.new(state)
		for setting: Array in [[0, AIPersonality.TACTICIAN, false], [1, AIPersonality.AGGRESSOR, true],
				[0, AIPersonality.FORTIFIER, true], [civ_slot, AIPersonality.TACTICIAN, false]]:
			var owner: int = setting[0]
			r.omniscient_side = owner
			var ai := AIController.new(owner, AIController.Difficulty.HARD)
			ai._r = r
			var planner := AIPlanner.new()
			planner.owner = owner
			planner.style = setting[1]
			planner._state = state
			planner._r = r
			planner._field = ai._enemy_distance_field(state, false, r)
			if setting[2]:
				# A capture zone: its cells, and the walk to it for half of the army.
				var zone := {}
				var seeds := PackedInt32Array()
				var centre: Vector2i = open[open.size() / 2]
				for y in range(centre.y - 1, centre.y + 2):
					for x in range(centre.x - 1, centre.x + 2):
						if grid.in_bounds(Vector2i(x, y)) and not grid.blocks_walk(Vector2i(x, y)):
							zone[Vector2i(x, y)] = 0
							seeds.append((y + 1) * (grid.width + 2) + x + 1)
				var fields := {}
				if not seeds.is_empty():
					var f := AIController.wave(grid, seeds, {})
					for u: UnitInstance in state.living_units_of(owner):
						if u.id % 2 == 0: fields[u.id] = f
				planner.set_objectives(fields, zone, [3])
			planner._apply_weights(state)
			planner._collect_enemies()
			var actors := planner._plannable_units()
			planner._build_lanes(actors)
			NativeKernels.enabled = false
			planner._build_exposure()
			var exposure := planner._exposure
			var threat := planner._threat
			NativeKernels.enabled = true
			planner._build_exposure()
			ck(planner._native_plan != null and planner._exposure == exposure and planner._threat == threat,
					"the native threat map equals GDScript's on board %d (owner %d)" % [board, owner])
			if setting == [0, AIPersonality.TACTICIAN, false] and planner._native_plan != null:
				beam_records += _compare_beams(planner._native_plan, r, state, rng, marks)
			planner._build_line_targets()
			planner._build_tank_paths()
			planner._setup_native_scorer()
			ck(planner._native_plan != null, "the native plan scorer accepts board %d (owner %d)" % [board, owner])
			if planner._native_plan == null: return
			for u: UnitInstance in actors:
				var native_rows: Array = []
				planner._candidates_for(u, native_rows)
				var scorer := planner._native_plan
				planner._native_plan = null
				var reference: Array = []
				planner._candidates_for(u, reference)
				planner._native_plan = scorer
				rows += reference.size()
				if u.stats.special_ability_id != MCF.ABILITY_MARKSMAN: native_soldiers += 1
				if native_rows != reference:
					ck(false, "plan scores of %s at %s on board %d (owner %d) match GDScript" % [u.stats.id, u.coord, board, owner])
					for i in mini(native_rows.size(), reference.size()):
						if native_rows[i] != reference[i]:
							print("  first difference at row %d: native %s, GDScript %s" % [i, native_rows[i], reference[i]])
							break
					return
		for c: GridCell in marks:
			c.on_fire = false
			c.smoke = false
			c.gas = false
	ck(rows > 2000 and native_soldiers > 100, "plan scores compared (%d rows, %d soldiers scored natively)" % [rows, native_soldiers])
	ck(beam_records > 3000, "marksman beams compared (%d records)" % beam_records)
	print("Compared %d plan cell scores (%d soldiers scored natively) and %d beam records." % [rows, native_soldiers, beam_records])

## The marksman's beam (MCFPlanScorer.beam) against GameActionResolver._laser_trace, record by
## record: from every trench, smoke and feature cell strewn above, every unit and some random
## cells, in all eight directions.
func _compare_beams(scorer: RefCounted, r: GameActionResolver, state: GameState,
		rng: RandomNumberGenerator, marks: Array[GridCell]) -> int:
	var grid := state.grid
	var froms: Array[Vector2i] = []
	for c: GridCell in marks: froms.append(c.coord)
	for u: UnitInstance in state.all_units():
		if grid.in_bounds(u.coord): froms.append(u.coord)
	for k in 150: froms.append(Vector2i(rng.randi_range(0, grid.width - 1), rng.randi_range(0, grid.height - 1)))
	var kinds := {"empty": 0, "terrain": 1, "vehicle": 2, "shield": 3, "unit": 4, "feature": 5}
	var count := 0
	for from: Vector2i in froms:
		for step: Vector2i in Grid.N8:
			var want := PackedInt32Array()
			for rec: Dictionary in r._laser_trace(from, step):
				var at: Vector2i = rec["coord"]
				want.append_array([at.x, at.y, kinds[rec["kind"]], int(rec["cost"]), int(rec["destroyed"]),
					int(rec["stop"]), int(rec["damage"]), int(rec["vehicle_id"]), int(rec["left"])])
			var got: PackedInt32Array = scorer.beam(from, step)
			if got != want:
				ck(false, "the native beam from %s toward %s matches _laser_trace" % [from, step])
				print("  native  %s\n  GDScript %s" % [got, want])
				return count
			count += want.size() / 9
	return count

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
