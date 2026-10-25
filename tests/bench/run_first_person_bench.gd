extends SceneTree

## Reproducible CPU profile; this headless measurement does not measure GPU frame rate.
## godot --headless --script res://tests/bench/run_first_person_bench.gd
func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapGen.generate({"style": MapGen.Style.TOWN, "size": MapGen.SIZE_CUSTOM,
			"width": 100, "height": 80, "seed": 83, "units": 80, "furniture": 3, "winter": true})
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var placed := 0
	for y in range(20, map.height - 20, 2):
		for x in range(20, map.width - 20, 2):
			var at := Vector2i(x, y)
			if placed < 200 and grid.cell(at).feature_id == "" and grid.cell(at).walkable_terrain():
				map.set_spawn(at, "light_infantry", placed % 2)
				placed += 1
	var tiles := TerrainTiles.new(grid, "town")
	tiles.set_winter(true)
	var host := FirstPersonHost.new(map, tiles)
	root.add_child(host)
	var start := Vector2i(-1, -1)
	var fp_script = load("res://scenes/main/FirstPerson.gd")
	for y in range(30, 50):
		for x in range(40, 60):
			if start.x < 0 and fp_script.walkable_start(host, Vector2i(x, y)): start = Vector2i(x, y)
	var enter := Time.get_ticks_usec()
	var fp: Control = fp_script.new(host, start)
	root.add_child(fp)
	print("First-person entry: %.1f ms, map %dx%d, %d units" % [(Time.get_ticks_usec() - enter) / 1000.0,
			map.width, map.height, host.state.units.size()])
	for i in 160: await process_frame
	fp.set_process(false)
	var phases := {"visibility": "_sync_vis", "lighting": "_update_light", "floor refresh": "_refresh_floors",
			"chunk streaming": "_stream_chunks", "doors": "_doors", "units": "_sync_units", "vehicles": "_sync_vehicles", "effects": "_sync_combat_fx"}
	var args := {"visibility": [false], "lighting": [false], "chunk streaming": [fp.BUILD_BUDGET_USEC], "doors": [0.016]}
	var elapsed := {}
	var total := 0.0
	for i in 120:
		fp.yaw += 0.015
		fp.pos.x += 0.01
		for phase: String in phases:
			var t := Time.get_ticks_usec()
			fp.callv(phases[phase], args.get(phase, []))
			elapsed[phase] = float(elapsed.get(phase, 0.0)) + Time.get_ticks_usec() - t
		await process_frame
	for phase: String in elapsed:
		var ms: float = elapsed[phase] / 120000.0
		print("  %s: %.3f ms/frame" % [phase, ms])
		total += ms
	print("Measured CPU phases: %.3f ms/frame; %d resident chunks" % [total, fp._chunks.size()])
	fp.free()
	host.free()
	quit()
