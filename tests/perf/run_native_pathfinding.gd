extends "res://tests/SuiteBase.gd"

var compared := 0

func run() -> void:
	var kernel := NativeKernels.pathfinding()
	if kernel == null:
		ck(not OS.get_cmdline_user_args().has("--require-native"), "native pathfinding library loads")
		var grid := Grid.new(9, 7)
		ck(Movement.reachable(grid, Vector2i(4, 3), 3).can_reach(Vector2i(7, 3)), "source fallback finds a path")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 593715
	for board in 12:
		var grid := Grid.new(11 + board * 2, 9 + board)
		for cell: GridCell in grid.cells_flat():
			var choice := rng.randi_range(0, 17)
			match choice:
				0: cell.set_feature(MCF.FEATURE_WALL)
				1: cell.set_feature(MCF.FEATURE_HEDGEHOG)
				2: cell.set_feature(MCF.FEATURE_DRONE_STATION)
				3:
					cell.set_feature(MCF.FEATURE_AIRLOCK)
					cell.airlock_welded = rng.randi() % 2 == 0
				4, 5, 6: cell.cover_height = [0.5, 1.0, 1.5][choice - 4]
				7:
					cell.dirt_level = rng.randi_range(1, 4)
					cell.cover_height = cell.dirt_level * 0.5
				8: cell.corpse_count = rng.randi_range(1, 3)
				9: cell.vehicle_id = 7
				10: cell.occupant = UnitInstance.new(1, null, cell.coord, 0)
				11: cell.on_fire = true
				12: cell.cover_height = 0.75 # Nonstandard heights use the flat cost.
		for query in 70:
			var start := Vector2i(rng.randi_range(0, grid.width - 1), rng.randi_range(0, grid.height - 1))
			var stop := Vector2i(-1, -1) if query % 3 == 0 else start + Vector2i(rng.randi_range(-8, 8), rng.randi_range(-8, 8))
			var avoid := {}
			var free := {}
			for k in query % 5:
				avoid[Vector2i(rng.randi_range(0, grid.width - 1), rng.randi_range(0, grid.height - 1))] = false
				free[Vector2i(rng.randi_range(0, grid.width - 1), rng.randi_range(0, grid.height - 1))] = false
			_compare(grid, start, rng.randi_range(-1, 25), query % 2 == 0, avoid, free, stop)
			if query % 7 == 0:
				# Changing any walking property must invalidate the primitive snapshot.
				var changed := grid.cell(start)
				changed.clear_feature()
				changed.occupant = null
				changed.corpse_count = 0
				changed.vehicle_id = -1
				changed.on_fire = not changed.on_fire
				_compare(grid, start, 6, true, avoid, free, stop)
			if not fails.is_empty(): return
	_edge_cases()
	ck(kernel.reachable(Vector2i(5, 5), Vector2i.ZERO, 3, PackedByteArray(), PackedFloat64Array(), {}).is_empty(), "malformed native snapshots are declined")
	for invalid: float in [0.0, -1.0, INF, NAN]:
		ck(kernel.reachable(Vector2i.ONE, Vector2i.ZERO, 3, PackedByteArray([1]), PackedFloat64Array([0.0]),
				{"climb": {0.5: invalid}}).is_empty(), "unsupported costs cannot traverse unprepared snapshot cells")
	NativeKernels.enabled = true
	print("Compared %d ordered reachability maps and predecessor trees, including partial searches and changed blockers." % compared)

func _compare(grid: Grid, start: Vector2i, budget: int, fire := false, avoid: Dictionary = {}, free: Dictionary = {}, stop := Vector2i(-1, -1)) -> void:
	var version := GridCell.walk_version
	NativeKernels.enabled = false
	Movement._cache.clear()
	var expected := Movement.reachable(grid, start, budget, fire, avoid, free, stop)
	NativeKernels.enabled = true
	Movement._cache.clear()
	var actual := Movement.reachable(grid, start, budget, fire, avoid, free, stop)
	var label := "search %d at %s budget %d stop %s" % [compared, start, budget, stop]
	if grid.in_bounds(start):
		var direct: Array = NativeKernels.pathfinding().reachable(Vector2i(grid.width, grid.height), start, budget,
				Movement._native_flags, Movement._native_heights, {"avoid_fire": fire, "avoid": avoid,
				"free": free, "stop": stop, "flat": MCF.FLAT_MOVE_COST,
				"jump": MCF.HEDGEHOG_JUMP_COST, "climb": MCF.CLIMB_COST})
		ck(direct.size() == 2, label + " uses the native implementation without fallback")
		if direct.size() == 2:
			ck(direct[0].keys() == actual.cost.keys() and direct[0].values() == actual.cost.values(), label + " native costs reach callers")
	ck(expected.cost.keys() == actual.cost.keys() and expected.cost.values() == actual.cost.values(), label + " ordered costs match")
	ck(expected.came_from.keys() == actual.came_from.keys() and expected.came_from.values() == actual.came_from.values(), label + " ordered predecessors match")
	for target: Vector2i in expected.cost.keys().slice(0, 3):
		ck(expected.path_to(target) == actual.path_to(target), label + " chosen path matches")
	ck(GridCell.walk_version == version, label + " leaves the grid untouched")
	compared += 1

func _edge_cases() -> void:
	var grid := Grid.new(9, 5)
	for cell: GridCell in grid.cells_flat():
		if cell.coord.y != 2: cell.set_feature(MCF.FEATURE_WALL)
	var start := Vector2i(1, 2)
	grid.cell(Vector2i(2, 2)).set_feature(MCF.FEATURE_HEDGEHOG)
	var landing := grid.cell(Vector2i(3, 2))
	landing.occupant = UnitInstance.new(2, null, landing.coord, 0)
	_compare(grid, start, 5, false, {}, {landing.coord: true})
	ck(not Movement.reachable(grid, start, 5, false, {}, {landing.coord: true}).can_reach(landing.coord), "a vacated-cell hint never frees a hedgehog landing")
	landing.occupant = null
	grid.cell(Vector2i(4, 2)).set_feature(MCF.FEATURE_AIRLOCK)
	grid.cell(Vector2i(5, 2)).on_fire = true
	_compare(grid, start, 8, true)
	var reach := Movement.reachable(grid, start, 8, true)
	ck(reach.cost[Vector2i(3, 2)] == 2 and reach.cost[Vector2i(4, 2)] == 3, "hedgehog jump and unopened airlock retain their costs")
	ck(reach.can_reach(Vector2i(5, 2)) and not reach.can_reach(Vector2i(6, 2)), "fire is reachable but terminal")
	_compare(grid, Vector2i(5, 2), 3, true)
	_compare(grid, start, 20, false, {}, {}, start)
	_compare(grid, Vector2i(-9999, -9999), 20)
	_compare(Grid.new(1, 1), Vector2i.ZERO, 9)
	# Return to an earlier grid after another grid populated the same-sized buffers.
	_compare(grid, start, 8, false)
	Movement._cache.clear()
	var cached := Movement.reachable(grid, start, 8)
	ck(is_same(cached, Movement.reachable(grid, start, 8)), "ordinary callers retain the existing shared reachability cache")
	# GridCell permits negative imported counts. Normal entry checks == 0, while
	# Grid.blocks_walk (used for jump landings) checks > 0; retain both predicates.
	var unusual := Grid.new(7, 3)
	for cell: GridCell in unusual.cells_flat():
		if cell.coord.y != 1: cell.set_feature(MCF.FEATURE_WALL)
	var origin := Vector2i(0, 1)
	var hurdle := unusual.cell(Vector2i(1, 1))
	hurdle.corpse_count = -1
	_compare(unusual, origin, 6)
	ck(not Movement.reachable(unusual, origin, 6).can_reach(hurdle.coord), "nonzero corpse counts prevent normal entry")
	hurdle.set_feature(MCF.FEATURE_HEDGEHOG)
	var unusual_landing := unusual.cell(Vector2i(2, 1))
	unusual_landing.corpse_count = -1
	_compare(unusual, origin, 6)
	ck(Movement.reachable(unusual, origin, 6).cost.get(unusual_landing.coord) == MCF.HEDGEHOG_JUMP_COST,
			"negative corpse counts retain the original jump-landing behavior")
