extends SceneTree
## Geometric coverage estimate, using the same finite radii and shadow geometry.
func _initialize() -> void:
	for size in [0, 4]:
		for style in 5:
			var start := Time.get_ticks_msec()
			var g := MapGen.build({"style": style, "size": size, "units": 140 if size == 4 else 16, "seed": 317, "furniture": 2})
			var elapsed := Time.get_ticks_msec() - start
			var plan := MapLighting.new()
			plan.g = g
			plan.map = g.m
			var grid := Grid.new(g.w, g.h)
			g.m.apply_to_grid(grid)
			plan.coverage.resize(g.w * g.h)
			var sources := 0
			for cell in grid.cells_flat():
				if Furniture.emits_light(cell.feature_id):
					plan._illuminate(cell.coord, cell.feature_id)
					sources += 1
				for lamp: Array in cell.lamps:
					plan._illuminate(cell.coord, str(lamp[0]), int(lamp[2]))
					sources += 1
			var total := 0
			var lit := 0
			for cell in grid.cells_flat():
				if not g._core.has_point(cell.coord) or not g._in_f(cell.coord) or cell.is_space or cell.cover_height > 0: continue
				total += 1
				if plan.coverage[cell.coord.y * g.w + cell.coord.x] >= 0.12: lit += 1
			print("%s size %d: %dx%d, %d emitters, %d ms generation, %.1f%% floors lit above ambient" % [g.m.env, size, g.w, g.h, sources, elapsed, 100.0 * lit / maxi(1, total)])
	quit()
