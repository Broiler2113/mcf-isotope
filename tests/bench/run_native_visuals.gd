extends SceneTree

## Same deterministic work in both backends. Timings are measurements, not test gates.
func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	if NativeVisuals.mesh_builder() == null:
		printerr("Build native/visuals first.")
		quit(1)
		return
	var elapsed := {false: [], true: []}
	for repeat in 7:
		for native: bool in ([false, true] if repeat % 2 == 0 else [true, false]):
			var start := Time.get_ticks_usec()
			var sink := FirstPersonModels.Sink.new(native)
			for i in 1500:
				var at := Vector3(i % 50, 0.0, i / 50)
				sink.box(at, at + Vector3(0.8, 0.6, 0.8), 3, Color(0.6, 0.4, 0.3))
				sink.cyl(at, 0.2, 0.15, 0.6, 2, Color(0.8, 0.7, 0.5), 8)
			var arrays := sink.arrays()
			if arrays[Mesh.ARRAY_VERTEX].size() == 0: quit(1); return
			if repeat > 0: elapsed[native].append((Time.get_ticks_usec() - start) / 1000.0)
	for native: bool in [false, true]: elapsed[native].sort()
	print("Dense model geometry median: GDScript %.2f ms, C++ %.2f ms (%.2fx)" % [elapsed[false][3], elapsed[true][3], elapsed[false][3] / elapsed[true][3]])
	# Full streaming work also includes textures and engine mesh uploads.
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapGen.generate({"style": MapGen.Style.TOWN, "size": MapGen.SIZE_CUSTOM,
		"width": 100, "height": 80, "seed": 83, "units": 80, "furniture": 3, "winter": false})
	var ui := root.get_node("Ui")
	ui.fp_render_distance = 160
	ui.snowfall = false
	var totals := {false: [], true: []}
	for repeat in 4:
		for native: bool in ([false, true] if repeat % 2 == 0 else [true, false]):
			NativeVisuals.enabled = native
			NativeKernels.enabled = native
			FirstPersonModels._cache.clear()
			var grid := Grid.new(map.width, map.height)
			map.apply_to_grid(grid)
			var host := FirstPersonHost.new(map, TerrainTiles.new(grid, "town"))
			root.add_child(host)
			var fp: Node = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(50, 40))
			var start := Time.get_ticks_usec()
			root.add_child(fp)
			fp.set_process(false)
			fp._stream_chunks(60000000)
			totals[native].append((Time.get_ticks_usec() - start) / 1000.0)
			print("Full town terrain %s: %.2f ms, %d chunks" % ["C++" if native else "GDScript", totals[native].back(), fp._chunks.size()])
			fp.free()
			host.free()
			await process_frame
	for native: bool in [false, true]: totals[native].sort()
	print("Full town preparation median: GDScript %.2f ms, C++ %.2f ms (%.2fx); headless CPU, not FPS" % [totals[false][2], totals[true][2], totals[false][2] / totals[true][2]])
	quit()
