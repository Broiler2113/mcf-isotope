extends SceneTree

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	if NativeKernels.terrain() == null:
		printerr("Build native/visuals first.")
		quit(1)
		return
	var map := MapGen.generate({"style": MapGen.Style.TOWN, "size": MapGen.SIZE_CUSTOM,
		"width": 100, "height": 80, "seed": 83, "units": 80, "furniture": 3, "winter": false})
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var measured := {"roof": {false: [], true: []}, "floor": {false: [], true: []}, "lines": {false: [], true: []}}
	var snapshots := {}
	var tiles := TerrainTiles.new(grid, "town")
	var line_tiles := TerrainTiles.new(grid, "town")
	for i in 80:
		if not line_tiles.ground_lines.has(Vector2i.ZERO): line_tiles.ground_lines[Vector2i.ZERO] = []
		line_tiles.ground_lines[Vector2i.ZERO].append([Vector2(i * 0.2, -1), Vector2(16 - i * 0.1, 17), i % 2])
	for repeat in 7:
		for native: bool in ([false, true] if repeat % 2 == 0 else [true, false]):
			NativeKernels.enabled = native
			var start := Time.get_ticks_usec()
			var roof := FirstPersonBoard.roofed(grid, "town")
			if repeat > 0: measured.roof[native].append((Time.get_ticks_usec() - start) / 1000.0)
			if snapshots.has("roof") and snapshots.roof != roof: quit(1); return
			snapshots.roof = roof
			start = Time.get_ticks_usec()
			for cy in ceili(grid.height / float(TerrainTiles.C)):
				for cx in ceili(grid.width / float(TerrainTiles.C)):
					var key := Vector3i(cx, cy, TerrainTiles.FP_RES)
					tiles._drop(key)
					tiles._build(Vector2i(cx, cy), TerrainTiles.FP_RES)
			if repeat > 0: measured.floor[native].append((Time.get_ticks_usec() - start) / 1000.0)
			var image := Image.create(512, 512, false, Image.FORMAT_RGBA8)
			image.fill(Color(0.43, 0.57, 0.22, 0.61))
			start = Time.get_ticks_usec()
			line_tiles._bake_ground_lines(image, Vector2i.ZERO, 32)
			if repeat > 0: measured.lines[native].append((Time.get_ticks_usec() - start) / 1000.0)
			if snapshots.has("lines") and snapshots.lines != image.get_data(): quit(1); return
			snapshots.lines = image.get_data()
	for name: String in measured:
		for native: bool in [false, true]: measured[name][native].sort()
		var script_ms: float = measured[name][false][3]
		var native_ms: float = measured[name][true][3]
		print("Terrain %s median: GDScript %.2f ms, C++ %.2f ms (%.2fx); native boundary and image uploads included" % [name, script_ms, native_ms, script_ms / native_ms])
	NativeKernels.enabled = true
	quit()
