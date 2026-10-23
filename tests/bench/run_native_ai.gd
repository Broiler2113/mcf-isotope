extends SceneTree

## Alternating backend runs measure AI planning kernels, including GDScript input packing.
func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	if NativeKernels.ai() == null:
		printerr("Build native/visuals before benchmarking AI kernels.")
		quit(1)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 734399
	var grid := Grid.new(250, 250)
	for c: GridCell in grid.cells_flat():
		if rng.randf() < 0.2: c.set_feature(MCF.FEATURE_WALL)
	var seeds := PackedInt32Array([253, 37844, 61000])
	# Populate the terrain snapshot before measuring the BFS itself.
	AIController._walk_mask(grid)
	_measure("AI 250x250 distance field", func() -> void: AIController.wave(grid, seeds, {}), 10)
	var rows: Array = []
	for i in 24000:
		rows.append([float(rng.randi_range(-100, 300)) * 0.25, i % 200,
			Vector2i(rng.randi_range(0, 80), rng.randi_range(0, 60))])
	var planner := AIPlanner.new()
	planner._gun_spread = true
	_measure("AI 24000 candidate assignment", func() -> void:
		planner.destinations.clear()
		planner.dest_score.clear()
		planner._assign_candidates(rows.duplicate()), 5)
	var state := GameState.new(250, 250, 89)
	var stats: UnitStats = load("res://src/data/units/light_infantry.tres")
	for i in 240:
		state.spawn_unit(stats, Vector2i(4 + (i % 20) * 12, 4 + (i / 20) * 20), 1)
	planner._state = state
	planner._enemies = state.all_units()
	_measure("AI 240-enemy firing-line index", func() -> void: planner._build_line_targets(), 3)
	NativeKernels.enabled = true
	quit()

func _measure(label: String, work: Callable, count: int) -> void:
	var elapsed := {false: [], true: []}
	for run in 7:
		for native: bool in ([false, true] if run % 2 == 0 else [true, false]):
			NativeKernels.enabled = native
			var start := Time.get_ticks_usec()
			for i in count: work.call()
			if run > 0: elapsed[native].append(float(Time.get_ticks_usec() - start) / (1000.0 * count))
	for native: bool in [false, true]: elapsed[native].sort()
	print("%s median: GDScript %.3f ms, C++ %.3f ms (%.2fx)" %
		[label, elapsed[false][3], elapsed[true][3], elapsed[false][3] / elapsed[true][3]])
