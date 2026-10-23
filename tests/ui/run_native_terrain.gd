extends "res://tests/SuiteBase.gd"

func run() -> void:
	var native := NativeKernels.terrain()
	if native == null:
		ck(not "--require-native" in OS.get_cmdline_user_args(), "native terrain library must load")
		return
	_roofs()
	_floors()
	_lines()
	_rejected_inputs(native)
	NativeKernels.enabled = true
	print("Compared roof flood-fill bytes, complete first-person floor bakes and ground-line pixels with the reference path.")

func _roofs() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 719437
	for sample in 24:
		var grid := Grid.new(19 + sample % 9, 17 + sample % 7)
		grid.floor_look.resize(grid.width * grid.height)
		for y in grid.height:
			for x in grid.width:
				var cell := grid.cell_fast(x, y)
				var kind := rng.randi_range(0, 12)
				cell.is_space = kind == 0
				cell.feature_id = ["", MCF.FEATURE_WALL, MCF.FEATURE_AIRLOCK, MCF.FEATURE_GLASS, MCF.FEATURE_ARMOR_GLASS, MCF.FEATURE_BOUNDARY][kind % 6]
				cell.cover_height = 2.0 if kind < 7 else 0.0
				cell.floor_type = MCF.FLOOR_GRASS if kind == 11 else 0
				grid.floor_look[y * grid.width + x] = MCF.Look.DIRT if kind == 12 else MCF.Look.GRASS if kind == 10 else 0
		var before := [GridCell.look_version, GridCell.feature_version]
		for env: String in ["town", "station", "bunker", "asteroid", "field"]:
			NativeKernels.enabled = false
			var reference := FirstPersonBoard.roofed(grid, env)
			NativeKernels.enabled = true
			ck(reference == FirstPersonBoard.roofed(grid, env), "roofed cells match sample %d/%s" % [sample, env])
		ck(before == [GridCell.look_version, GridCell.feature_version], "roof preparation leaves cells unchanged")
	# An enclosed room and its diagonal boundary walls exercise the final expansion.
	var grid := Grid.new(12, 12)
	for y in range(3, 9):
		for x in range(3, 9):
			if x in [3, 8] or y in [3, 8]: grid.cell_fast(x, y).set_feature(MCF.FEATURE_WALL)
	grid.cell_fast(5, 3).set_feature(MCF.FEATURE_AIRLOCK)
	var mask := FirstPersonBoard.roofed(grid, "town")
	ck(mask[5 * 12 + 5] == 1 and mask[3 * 12 + 3] == 1 and mask[1 * 12 + 1] == 0, "native flood fill retains enclosed roof and diagonal wall corners")
	grid.cell_fast(5, 3).set_feature("")
	grid.cell_fast(5, 3).cover_height = 0.0
	ck(FirstPersonBoard.roofed(grid, "town")[5 * 12 + 5] == 0, "opening a wall reclassifies the room")

func _floors() -> void:
	var grid := Grid.new(37, 23)
	grid.floor_look.resize(grid.width * grid.height)
	var damage := {}
	for i in grid.width * grid.height:
		var cell := grid.cells_flat()[i]
		var at := Vector2i(i % grid.width, i / grid.width)
		cell.is_space = i % 13 == 0
		cell.floor_type = MCF.FLOOR_GRASS if i % 9 == 0 else 0
		cell.feature_id = MCF.FEATURE_AIRLOCK if i % 7 == 0 else ""
		grid.floor_look[i] = 255 if i % 23 == 0 else i % 15
		if i % 17 == 0: damage[at] = FxDecals.DAMAGE_EPICENTER
		elif i % 19 == 0: damage[at] = FxDecals.DAMAGE_RUBBLE
		cell.on_fire = i % 31 == 0
	var before := [GridCell.look_version, GridCell.feature_version]
	for env: String in ["town", "station", "bunker", "asteroid", "field"]:
		for winter in [false, true]:
			var reference := _tiles(grid, env, winter, damage)
			var native := _tiles(grid, env, winter, damage)
			for cy in 2:
				for cx in 3:
					var cc := Vector2i(cx, cy)
					NativeKernels.enabled = false
					reference._build(cc, TerrainTiles.FP_RES)
					NativeKernels.enabled = true
					var job := native.begin_floor_job(cc)
					ck(job.has("native_plan"), "native plan is selected")
					ck(not native.advance_floor_job(job, 0) and job.next == 0, "expired budget leaves staged floor untouched")
					var turns := 0
					while not native.advance_floor_job(job, Time.get_ticks_usec() + 1000) and turns < 10000: turns += 1
					ck(turns < 10000, "staged native bake completes")
					var key := Vector3i(cx, cy, TerrainTiles.FP_RES)
					var a: Image = reference._chunks[key].floor.get_image()
					var b: Image = native._chunks[key].floor.get_image()
					ck(a.get_data() == b.get_data(), "floor pixels including mipmaps agree for %s winter=%s chunk=%s" % [env, winter, cc])
					native._drop(key)
					native._build(cc, TerrainTiles.FP_RES)
					ck(a.get_data() == native._chunks[key].floor.get_image().get_data(), "synchronous and streamed native floors agree")
					if not fails.is_empty(): return
	ck(before == [GridCell.look_version, GridCell.feature_version], "floor preparation leaves game cells unchanged")

func _tiles(grid: Grid, env: String, winter: bool, damage: Dictionary) -> TerrainTiles:
	var tiles := TerrainTiles.new(grid, env)
	tiles.set_winter(winter)
	tiles.origin = Vector2i(-103, 211)
	tiles._damaged = damage.duplicate()
	tiles.hidden_fire[Vector2i(0, 0)] = true
	# Known multi-variant art exercises deterministic hashing, transparency and the
	# missing-base fallback independently of the installed texture pack.
	for name: String in ["floor_grill", "floor_destroyed", "floor_solar"]:
		var variants: Array = []
		for variant in 3:
			var picture := Image.create(32, 32, false, Image.FORMAT_RGBA8)
			picture.fill(Color(0.15 * variant, 0.3, 0.7, 0.35 if name == "floor_grill" else 1.0))
			picture.fill_rect(Rect2i(variant * 4, 2, 4, 25), Color(0.2, 0.8, 0.1, 1.0))
			variants.append(picture)
		tiles._tiles[name + "@32"] = variants
	tiles._tiles["floor_epicenter@32"] = []
	for cy in 2:
		for cx in 3:
			var cc := Vector2i(cx, cy)
			var origin := Vector2(cc * TerrainTiles.C)
			tiles.ground_lines[cc] = [[origin + Vector2(-2.5, 0.5), origin + Vector2(17.2, 12.1), 0],
				[origin + Vector2(0, 15), origin + Vector2(16, 3), 1]]
	return tiles

func _lines() -> void:
	var tiles := TerrainTiles.new(Grid.new(16, 16), "town")
	var rng := RandomNumberGenerator.new()
	rng.seed = 9772
	var lines: Array = [[Vector2(2, 2), Vector2(2, 2), 0], [Vector2(-10, -10), Vector2(-5, -5), 0],
		[Vector2(1.5, 4.25), Vector2(14.5, 4.25), 1], [Vector2(8.5, -4), Vector2(8.5, 20), 0]]
	for i in 100:
		lines.append([Vector2(rng.randf_range(-8, 24), rng.randf_range(-8, 24)), Vector2(rng.randf_range(-8, 24), rng.randf_range(-8, 24)), i % 2])
	tiles.ground_lines[Vector2i.ZERO] = lines
	for res in [8, 16, 32]:
		var reference := Image.create(16 * res, 16 * res, false, Image.FORMAT_RGBA8)
		reference.fill(Color(0.43, 0.57, 0.22, 0.61))
		var native := reference.duplicate() as Image
		NativeKernels.enabled = false
		tiles._bake_ground_lines(reference, Vector2i.ZERO, res)
		NativeKernels.enabled = true
		tiles._bake_ground_lines(native, Vector2i.ZERO, res)
		ck(reference.get_data() == native.get_data(), "dense ground-line pixels agree at %d px/cell" % res)

func _rejected_inputs(native: RefCounted) -> void:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.3, 0.7, 0.4))
	var before := image.get_data()
	ck(not native.paint_ground_lines(image, [[Vector2.ZERO, Vector2.ONE, 0], ["bad"]], Vector2.ZERO, 32), "malformed ground lines are rejected")
	ck(image.get_data() == before, "rejected ground-line call cannot partially paint")
	var plan := {"size": Vector2i.ONE, "names": PackedStringArray(["floor", "overlay"]), "hashes": PackedInt32Array([0])}
	ck(not native.paint_floor(image, plan, {"floor": [image.duplicate()], "overlay": [null]}, 0, 1, 32), "missing tile data is rejected")
	ck(image.get_data() == before, "rejected floor call cannot partially paint")
