extends "res://tests/SuiteBase.gd"

func run() -> void:
	floor_jobs()
	ground_strokes()
	fog_boundary()
	await live_updates()

func floor_jobs() -> void:
	var map := MapData.blank_arena(20, 18)
	map.set_cell(Vector2i(3, 3), 0, 0, false, MCF.FEATURE_WALL)
	map.set_cell(Vector2i(4, 3), 0, 0, false, MCF.FEATURE_AIRLOCK)
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	grid.cell(Vector2i(8, 8)).on_fire = true
	var reference := TerrainTiles.new(grid, "town")
	var staged := TerrainTiles.new(grid, "town")
	for tiles: TerrainTiles in [reference, staged]:
		tiles.bake_fire = true
		tiles.ground_lines[Vector2i.ZERO] = [[Vector2(0, 0), Vector2(16, 16), 0], [Vector2(2, 15), Vector2(15, 1), 1]]
		tiles.decals[Vector2i.ZERO] = [{"kind": "blood_pool", "pos": Vector2(7.5, 4.5), "scale": 1.0, "rot": 0.4}]
	for cc: Vector2i in [Vector2i.ZERO, Vector2i.ONE]:
		var expected := reference.floor_3d(cc).get_image()
		var job := staged.begin_floor_job(cc)
		ck(not staged.advance_floor_job(job, 0), "expired budget leaves floor preparation pending")
		ck(not staged._chunks.has(Vector3i(cc.x, cc.y, TerrainTiles.FP_RES)), "unfinished floor is never published")
		var done := false
		for i in 10000:
			if staged.advance_floor_job(job, Time.get_ticks_usec() + 200): done = true; break
		ck(done, "floor preparation finishes across small budgets")
		var actual := staged.floor_3d(cc).get_image()
		ck(actual.get_data() == expected.get_data(), "staged floors preserve terrain, decals, fire and mipmaps exactly")

func fog_boundary() -> void:
	var fog := FirstPersonFog.new()
	root.add_child(fog)
	var sight := Image.create(12, 12, false, Image.FORMAT_R8)
	sight.fill(Color.BLACK)
	for y in range(3, 9):
		for x in range(3, 9): sight.set_pixel(x, y, Color.WHITE)
	ck(fog.update_visibility(sight) and fog.boundary_count == 4, "a known rectangle has four merged opaque fog boundaries")
	ck(fog.mesh != null and fog.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == 24, "fog is real geometry at the unexplored edge")
	var previous := fog.mesh
	for y in range(3, 9):
		for x in range(3, 9): sight.set_pixel(x, y, Color(0.5, 0, 0))
	ck(not fog.update_visibility(sight) and fog.mesh == previous, "remembered cells remain accessible without rebuilding the fog boundary")
	sight.fill(Color.WHITE)
	ck(fog.update_visibility(sight) and fog.mesh == null, "fully known maps have no fog curtain")
	fog.free()

func ground_strokes() -> void:
	var tiles := TerrainTiles.new(Grid.new(16, 16), "town")
	var rng := RandomNumberGenerator.new()
	rng.seed = 734
	var lines: Array = [[Vector2(0, 0), Vector2(16, 0), 0], [Vector2(8, 0), Vector2(8, 16), 1],
		[Vector2(4, 4), Vector2(4, 4), 0]]
	for i in 20:
		lines.append([Vector2(rng.randf_range(-4, 20), rng.randf_range(-4, 20)),
			Vector2(rng.randf_range(-4, 20), rng.randf_range(-4, 20)), i % 2])
	tiles.ground_lines[Vector2i.ZERO] = lines
	for res in [2, 8, 32]:
		var expected := Image.create(16 * res, 16 * res, false, Image.FORMAT_RGBA8)
		expected.fill(Color(0.3, 0.4, 0.5))
		var actual := expected.duplicate()
		# Reference the original brute-force stroke rasterizer, including clipping.
		for line: Array in lines:
			var a: Vector2 = line[0] * res
			var b: Vector2 = line[1] * res
			var radius := maxf(0.5, res * (0.11 if int(line[2]) == 0 else 0.04))
			var ink := Color(0.1, 0.08, 0.05, 0.2) if int(line[2]) == 0 else Color(0, 0, 0, 0.4)
			var lo := a.min(b) - Vector2.ONE * radius
			var hi := a.max(b) + Vector2.ONE * radius
			for y in range(maxi(0, floori(lo.y)), mini(expected.get_height(), ceili(hi.y))):
				for x in range(maxi(0, floori(lo.x)), mini(expected.get_width(), ceili(hi.x))):
					var p := Vector2(x + 0.5, y + 0.5)
					if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) <= radius:
						expected.set_pixel(x, y, expected.get_pixel(x, y).blend(ink))
		tiles._bake_ground_lines(actual, Vector2i.ZERO, res)
		ck(actual.get_data() == expected.get_data(), "optimized ground strokes preserve every pixel at resolution %d" % res)

func live_updates() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var map := MapData.blank_arena(32, 24)
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var tiles := TerrainTiles.new(grid, "town")
	var host := FirstPersonHost.new(map, tiles)
	grid = host.state.grid
	tiles._grid = grid
	root.add_child(host)
	var fp: Node = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(12, 12))
	root.add_child(fp)
	fp.set_process(false)
	fp._stream_chunks(10000000)
	var before := host.state.digest_hash()
	var at := Vector2i(10, 10)
	fp._sync_clouds()
	ck(fp._cloud_cells.is_empty(), "empty board has no cloud scan entries")
	host.state.grid.cell(at).gas = true
	fp._sync_clouds()
	ck(fp._gas_mm.multimesh.instance_count == 1, "new gas appears from the changed-cell journal")
	host.state.grid.cell(at).gas = false
	host.state.grid.cell(at).smoke = true
	fp._sync_clouds()
	ck(fp._gas_mm.multimesh.instance_count == 0 and fp._smoke_mm.multimesh.instance_count == 1, "replacing gas updates both visual layers")
	host.state.grid.cell(at).smoke = false
	fp._sync_clouds()
	ck(fp._cloud_cells.is_empty() and fp._smoke_mm.multimesh.instance_count == 0, "expired effects leave neither stale geometry nor index entries")
	var cc := Vector2i(1, 1)
	var old: Node3D = fp._chunks[cc].node
	fp._dirty[cc] = true
	ck(not fp._advance_chunk(cc, 0) and fp._chunks[cc].node == old, "partial rebuild preserves the complete old chunk")
	var abandoned: Node3D = fp._chunk_jobs[cc].node
	grid.cell(at).set_feature(MCF.FEATURE_WALL)
	fp._take_look_changes()
	fp._advance_chunk(cc, 0)
	ck(not is_instance_valid(abandoned), "a changed cell discards an unfinished stale rebuild")
	ck(fp._advance_chunk(cc, Time.get_ticks_usec() + 10000000), "replacement rebuild finishes")
	ck(fp._chunks[cc].node != old and not fp._chunk_jobs.has(cc), "completed chunk replaces its predecessor atomically")
	fp._drop_chunk(cc)
	fp._advance_chunk(cc, 0)
	abandoned = fp._chunk_jobs[cc].node
	grid.cell(at).clear_feature()
	fp._take_look_changes()
	fp._advance_chunk(cc, 0)
	ck(not is_instance_valid(abandoned), "changes also discard partially built chunks never published before")
	fp._advance_chunk(cc, Time.get_ticks_usec() + 10000000)
	var tcc := Vector2i.ZERO
	tiles._touch(at)
	ck(not fp._prepare_floor(tcc, 0), "expired floor budget starts a pending floor job")
	var partial: Image = fp._floor_jobs[tcc].floor
	grid.cell(at).on_fire = true
	tiles.sync({}, 0)
	fp._prepare_floor(tcc, 0)
	ck(fp._floor_jobs[tcc].floor != partial, "new floor changes discard stale pending pixels")
	ck(fp._prepare_floor(tcc, Time.get_ticks_usec() + 10000000), "updated floor completes")
	grid.cell(at).on_fire = false
	grid.cell(at).clear_feature()
	ck(host.state.digest_hash() == before, "render preparation does not alter simulation state")
	fp._dirty[cc] = true
	fp._advance_chunk(cc, 0)
	var pending: Node3D = fp._chunk_jobs[cc].node
	fp.free()
	ck(not is_instance_valid(pending), "leaving first person frees pending off-tree geometry")
	host.free()
	await process_frame
