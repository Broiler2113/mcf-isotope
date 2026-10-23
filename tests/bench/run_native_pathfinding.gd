extends SceneTree

func _initialize() -> void: run.call_deferred()

func run() -> void:
	if NativeKernels.pathfinding() == null:
		printerr("Build native/visuals first.")
		quit(1)
		return
	var grid := Grid.new(149, 119)
	for cell: GridCell in grid.cells_flat():
		if cell.coord.x % 13 == 0 and cell.coord.y % 9 != 0: cell.set_feature(MCF.FEATURE_WALL)
		elif (cell.coord.x * 7 + cell.coord.y * 3) % 17 == 0: cell.cover_height = 1.0
	var starts: Array[Vector2i] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 3129
	for i in 300: starts.append(Vector2i(rng.randi_range(0, 148), rng.randi_range(0, 118)))
	for mode: String in ["shared revision", "changed board per search"]:
		var times := {false: [], true: []}
		var checksums := {false: [], true: []}
		for repeat in 7:
			for native: bool in ([false, true] if repeat % 2 == 0 else [true, false]):
				NativeKernels.enabled = native
				Movement._cache.clear()
				Movement._native_version = -1
				var checksum := 0
				var begin := Time.get_ticks_usec()
				for i in starts.size():
					if mode == "changed board per search":
						var cell := grid.cell(Vector2i(148, 118))
						cell.on_fire = not cell.on_fire
					var result := Movement.reachable(grid, starts[i], 6 + i % 9)
					checksum += result.cost.size()
				var elapsed := (Time.get_ticks_usec() - begin) / 1000.0
				checksums[native].append(checksum)
				if repeat > 0: times[native].append(elapsed)
		if checksums[false] != checksums[true]:
			printerr("Reachability benchmark checksums differ")
			quit(1)
			return
		for native: bool in [false, true]: times[native].sort()
		print("300 path searches, %s: GDScript %.2f ms, C++ %.2f ms (%.2fx), including snapshot preparation" % [mode, times[false][3], times[true][3], times[false][3] / times[true][3]])
	NativeKernels.enabled = true
	quit()
