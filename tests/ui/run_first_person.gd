extends "res://tests/SuiteBase.gd"

## First person (fix-7 #9): entering and leaving, the board's faces all wound the same way
## (a reversed wall shows its far side and hides trench sides from inside), what blocks
## the walker (walls, units' cells aside; X walks through; trenches are 2 m pits), and that
## looking around never touches the game state.

func run() -> void:
	for style in [1, 0]:   # town (trenches, buildings), station (hull, airlocks)
		await _check(style)

func _check(style: int) -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var m := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": 50, "height": 40, "seed": 11,
			"zones": 2, "units": 24, "civilians": 0, "density": 1, "furniture": 2})
	MapHandoff.pending = m
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 6:
		await process_frame
	var g: Grid = main.state.grid
	var FP = load("res://scenes/main/FirstPerson.gd")
	var start := Vector2i(-1, -1)
	var wall := Vector2i(-1, -1)
	var trench := Vector2i(-1, -1)
	for y in g.height:
		for x in g.width:
			var c := g.cell_fast(x, y)
			if start.x < 0 and x > 5 and y > 5 and FP.walkable_start(main, Vector2i(x, y)):
				start = Vector2i(x, y)
			if wall.x < 0 and FirstPersonBoard.is_wall(c):
				wall = Vector2i(x, y)
			if trench.x < 0 and c.feature_id == MCF.FEATURE_TRENCH:
				trench = Vector2i(x, y)
	ck(start.x >= 0 and wall.x >= 0, "map has a free cell and a wall")
	var before := JSON.stringify(StateCodec.encode(main.state))

	main._start_first_person(start)
	for i in 40:
		await process_frame
	var fp = main._fp
	ck(fp != null and not main._ui_layer.visible, "entering hides the battle UI")
	ck(fp._chunks.size() > 0, "chunks stream in around the walker")

	# Every triangle's winding agrees with its normal the same way as the floor's does.
	var signs := {}
	for cc in fp._chunks:
		for mi in (fp._chunks[cc]["node"] as Node3D).find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null or mi.mesh.get_surface_count() == 0:
				continue
			var mat: Material = mi.material_override
			if mat is ShaderMaterial and (mat as ShaderMaterial).shader.code.contains("cull_disabled"):
				continue
			var arr: Array = mi.mesh.surface_get_arrays(0)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ns: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var n := idx.size() if idx.size() > 0 else vs.size()
			for t in range(0, n - 2, 3):
				var a := idx[t] if idx.size() > 0 else t
				var b := idx[t + 1] if idx.size() > 0 else t + 1
				var c := idx[t + 2] if idx.size() > 0 else t + 2
				var geo := (vs[b] - vs[a]).cross(vs[c] - vs[a])
				if geo.length() < 1e-6:
					continue
				signs[signf(geo.dot(ns[a]))] = true
	ck(signs.size() == 1, "style %d: every face is wound the same way (got %s)" % [style, signs.keys()])

	ck(fp._top(wall) == INF, "a wall stops the walker, in space too")
	if trench.x >= 0:
		ck(is_equal_approx(fp._top(trench), -FirstPersonBoard.TRENCH), "a trench is a 2 m pit")
	fp.noclip = true
	ck(fp._top(wall) == 0.0, "X walks through walls")
	fp.noclip = false

	fp.leave()
	for i in 3:
		await process_frame
	ck(main._fp == null and main._ui_layer.visible, "Esc leaves and brings the battle UI back")
	ck(JSON.stringify(StateCodec.encode(main.state)) == before, "first person never changes the game")
	main.queue_free()
	await process_frame
