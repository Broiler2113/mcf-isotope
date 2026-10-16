extends SceneTree
## Repeat a tank's debris disturbance on a populated board, including the quiet tail.
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var scripts: Array[GDScript] = []
	for path in OS.get_cmdline_user_args():
		var old := GDScript.new()
		old.source_code = FileAccess.get_file_as_string(path).replace("class_name TerrainTiles\n", "")
		if old.reload() != OK: quit(1); return
		scripts.append(old)
	scripts.append(load("res://src/ui/TerrainTiles.gd"))
	for script in scripts:
		var grid := Grid.new(96, 64)
		var tiles = script.new(grid, "town")
		var fx := FxDecals.new()
		for y in 64:
			for x in 96:
				fx._settle(fx.props, {"kind": "chunk:wall#2", "pos": Vector2(x + 0.5, y + 0.5), "rot": 0.5, "scale": 1.0})
		tiles.sync_decals(fx)
		for y in 4:
			for x in 6: tiles._build(Vector2i(x, y), 32)
		var worst := 0.0
		var builds := 0
		for step in 12:
			var start := Time.get_ticks_usec()
			fx.apply([{"fx": "sweep_props", "at": Vector2i(20 + step, 20), "from": Vector2i(19 + step, 20)}])
			fx.advance(1.0)
			tiles.sync_decals(fx)
			tiles._built = 0
			for y in 4:
				for x in 6: tiles._choose(Vector2i(x, y), 32)
			builds += tiles._built
			worst = maxf(worst, (Time.get_ticks_usec() - start) / 1000.0)
		var tail := Time.get_ticks_usec()
		for frame in 60:
			fx.advance(1.0 / 60)
			tiles.sync_decals(fx)
			tiles._built = 0
			for y in 4:
				for x in 6: tiles._choose(Vector2i(x, y), 32)
		print("%s: worst drive frame %.2f ms; %d rebuilds in 12 steps; quiet tail %.2f ms/frame; %d particles retained" % ["after" if script == scripts.back() else "before", worst, builds, (Time.get_ticks_usec() - tail) / 60000.0, fx.props.size()])
	quit()
