extends "res://tests/SuiteBase.gd"

func run() -> void:
	for turn in 4:
		_bed(turn)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var map := MapData.blank_arena(16, 12)
	map.set_spawn(Vector2i(6, 5), "borg", 0)
	map.set_spawn(Vector2i(5, 5), "engineer", 0)
	map.set_spawn(Vector2i(13, 9), "light_infantry", 1)
	map.set_cell(Vector2i(10, 4), 0, 0, false, "bed")
	map.set_cell(Vector2i(10, 5), 0, 0, false, "bed")
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 3: await process_frame
	var state: GameState = main.state
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	var at := Vector2i(6, 5)
	ck(main._corpse_above_vehicle(at), "bodies lie above an idle borg")
	var engineer := state.grid.cell(Vector2i(5, 5)).occupant
	var borg: Vehicle = state.all_vehicles()[0]
	ck(main.resolver.resolve(VehicleBoardIntent.new(engineer.id, borg.id)).ok, "engineer occupies the borg")
	ck(main._corpse_above_vehicle(engineer.coord), "bodies lie above the occupied borg as well")
	state.grid.cell(Vector2i(10, 4)).clear_feature()
	SaveHandoff.pending_save = main._save_payload()
	main.free()
	var loaded: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(loaded)
	for i in 3: await process_frame
	ck(loaded._furniture_look.has(Vector2i(10, 4)), "save/load retains the destroyed half's original footprint")
	ck(loaded.state.grid.cell(Vector2i(10, 4)).feature_id == "", "restoring the appearance never restores destroyed furniture to gameplay")
	loaded.free()

func _bed(turn: int) -> void:
	var grid := Grid.new(16, 16)
	var start := Vector2i(6, 6)
	var end := start + (Vector2i.RIGHT if turn % 2 else Vector2i.DOWN)
	for at in [start, end]:
		grid.cell(at).set_feature("bed")
		grid.furniture_turn[at] = ["bed", turn]
	var tiles := TerrainTiles.new(grid, "town")
	tiles.furniture_look = tiles.freeze_furniture()
	grid.cell(start).clear_feature()
	var opaque := SurfaceTool.new()
	var glass := SurfaceTool.new()
	opaque.begin(Mesh.PRIMITIVE_TRIANGLES)
	glass.begin(Mesh.PRIMITIVE_TRIANGLES)
	FirstPersonBoard._piece(opaque, glass, {"models": 0, "glass": 0}, grid, end, "bed",
			{"look": tiles.look_of, "furniture_look": tiles.furniture_look}, 3.0, {})
	var mesh := opaque.commit()
	ck(mesh != null, "a damaged bed retains its surviving half, rotation %d" % turn)
	if mesh == null: return
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var inside := true
	for v in vertices:
		if v.x < end.x - 0.001 or v.x > end.x + 1.001 or v.z < end.y - 0.001 or v.z > end.y + 1.001:
			inside = false
	ck(inside, "a damaged bed never redraws its destroyed cell, rotation %d" % turn)
	var box := mesh.get_aabb()
	ck(box.size.x > 0.7 and box.size.z > 0.7, "the surviving model retains its original size, rotation %d" % turn)
