extends SceneTree
## Pixel parity for local invalidation, including removal, resettling, fog memory and clear.
var failures := 0
func _initialize() -> void: run.call_deferred()
func run() -> void:
	if DisplayServer.get_name() == "headless": quit(2); return
	for res in [8, 16, 32]:
		var grid := Grid.new(48, 32)
		var fx := FxDecals.new()
		for y in range(10, 22):
			for x in range(10, 38):
				fx._settle(fx.props, {"kind": "chunk:wall#%d" % (x % 6), "pos": Vector2(x + 0.5, y + 0.5), "rot": x * 0.3, "scale": 0.9})
		var tiles := TerrainTiles.new(grid, "town")
		tiles.sync_decals(fx)
		for y in 2:
			for x in 3: tiles._build(Vector2i(x, y), res)
		tiles._dirty.clear()
		var memory := DecalMemory.new(fx)
		var seen := {}
		for y in 32:
			for x in 24: seen[Vector2i(x, y)] = true
		for step in 24:
			var c := Vector2i(10 + step, 16)
			fx.apply([{"fx": "sweep_props", "at": c, "from": c - Vector2i.RIGHT}])
			fx.advance(0.05)
			memory.update(fx, seen, [], grid.width)
			tiles.sync_decals(fx)
			tiles._built = 0
			for y in 2:
				for x in 3: tiles._choose(Vector2i(x, y), res)
		fx.advance(2.0)
		for phase in 3:
			if phase == 1:
				memory.update(fx, seen, [], grid.width)
			elif phase == 2: fx.clear()
			var source := memory.view if phase == 1 else fx
			for frame in 8:
				tiles.sync_decals(source)
				tiles._built = 0
				for y in 2:
					for x in 3: tiles._choose(Vector2i(x, y), res)
			var reference := TerrainTiles.new(grid, "town")
			reference.decals = source.by_chunk
			for y in 2:
				for x in 3:
					reference._build(Vector2i(x, y), res)
					var key := Vector3i(x, y, res)
					for layer in ["floor", "feat"]:
						var got: Image = tiles._chunks[key][layer].get_image()
						var expected: Image = reference._chunks[key][layer].get_image()
						if got.get_data() != expected.get_data():
							printerr("Pixel mismatch res=%d phase=%d chunk=%s layer=%s" % [res, phase, key, layer])
							failures += 1
	print("Crush cache pixels: %d failure(s), 108 layer comparisons" % failures)
	quit(1 if failures else 0)
