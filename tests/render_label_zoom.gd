extends "res://tests/SuiteBase.gd"

## The spec's distant map must retain a label on every cell without covering the
## board in screen-sized captions. Check actual pixels, not just box formulas.
func run() -> void:
	if DisplayServer.get_name() == "headless": ck(false, "requires rendered display"); return
	root.size = Vector2i(1280, 720)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.cheats_enabled = true
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.roster = Roster.default_duel(false)
	for slot: Roster.Slot in GameConfig.roster.slots: slot.cheats_allowed = true
	var map := MapData.blank_arena(160, 120)
	map.set_spawn(Vector2i(8, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(152, 110), "light_infantry", 1)
	MapHandoff.pending = map
	var viewport := SubViewport.new()
	viewport.size = root.size
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.world_2d = World2D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	viewport.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	main._kill_pan_tween()
	main.set_process(false)
	var layer: CanvasLayer
	var overlay: CheatOverlay
	for child: Node in main.get_children():
		if child is CanvasLayer:
			for node: Node in child.get_children():
				if node is CheatOverlay: layer = child; overlay = node
	ck(overlay != null, "the gameplay label layer exists")
	if overlay == null: viewport.free(); return
	main.self_modulate.a = 0.0
	var visibility := {}
	for child: Node in main.get_children():
		if child is CanvasLayer or child is CanvasItem: visibility[child] = child.visible
		if child is CanvasLayer: child.visible = child == layer
		elif child is CanvasItem: child.hide()
	await check_labels(main, viewport, overlay, "unit", Vector2i(8, 8))
	main.resolver._kill(main.state.get_unit(0))
	await check_labels(main, viewport, overlay, "corpse", Vector2i(8, 8))
	main.state.spawn_vehicle("tank", Vector2i(16, 16), 0)
	await check_labels(main, viewport, overlay, "vehicle", Vector2i(16, 16))
	await check_labels(main, viewport, overlay, "coordinate", Vector2i(123, 101))
	await check_full_map(main, viewport, overlay)
	await check_stacks(main, viewport, overlay)
	main._cheat_coords = false
	main._cheat_ids = ""
	ck((await frame(viewport)).is_invisible(), "disabling labels removes cached drawing")
	main._cheat_coords = true
	main._cheat_ids = "all"
	var viewer: int = main._viewing_side()
	main.state.roster.slot(viewer).cheats_allowed = false
	ck((await frame(viewport)).is_invisible(), "revoking permission removes cached coordinates and IDs")
	main.state.roster.slot(viewer).cheats_allowed = true
	main._cheat_coords = true
	main._cheat_ids = "all"
	main.self_modulate.a = 1.0
	for child: Node in visibility: child.visible = visibility[child]
	main.zoom = 0.12
	main.pan = Vector2(60, 65)
	main.queue_redraw()
	(await frame(viewport)).save_png("/tmp/isotope-fix12-battlefield-distant.png")
	main.zoom = 1.0
	main.pan = Vector2(120, 100) - main._cell_origin(Vector2i(8, 8))
	main.queue_redraw()
	(await frame(viewport)).save_png("/tmp/isotope-fix12-battlefield-close.png")
	viewport.free()
	await process_frame

func frame(viewport: SubViewport) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func check_labels(main: Node, viewport: SubViewport, overlay: CheatOverlay, kind: String, cell: Vector2i) -> void:
	main._cheat_ids = "" if kind == "coordinate" else ("vehicles" if kind == "vehicle" else "units")
	main._cheat_coords = kind == "coordinate"
	var sizes: Array[Vector2i] = []
	var phase := 0
	for zoom: float in [0.12, 0.35, 0.75, 1.0, 1.25, 1.75, 2.5]:
		main.zoom = 1.0
		var start := Vector2(120, 80) + Vector2(0.25, 0.25) * (phase % 4)
		main.pan = start - main._cell_origin(cell)
		var gesture := InputEventMagnifyGesture.new()
		gesture.position = start + Vector2(12.3, 4.7)
		gesture.factor = zoom
		main._unhandled_input(gesture)
		ck(is_equal_approx(main.zoom, zoom), "pinch reaches %s zoom for %s" % [zoom, kind])
		var tile := Rect2(main._cell_screen(cell), Vector2.ONE * main.CELL * main.zoom)
		var box := overlay.coordinate_box(cell) if kind == "coordinate" else overlay.label_box(cell, "V1000000" if kind == "vehicle" else ("U0-" if kind == "corpse" else "U0"))
		ck(tile.encloses(box), "%s layout fits its tile at %s" % [kind, zoom])
		var capture := await frame(viewport)
		var pixels := ink_bounds(capture, Rect2i(tile.grow(24)) if kind != "coordinate" else Rect2i(tile))
		ck(pixels.has_area(), "%s renders on its own tile at %s" % [kind, zoom])
		ck(tile.grow(1).encloses(Rect2(pixels)), "%s pixels stay inside their tile at %s: %s" % [kind, zoom, pixels])
		sizes.append(pixels.size)
		phase += 1
	ck(sizes[0].x < sizes[3].x and sizes[0].y < sizes[3].y, "%s shrinks with its tile at distant zoom" % kind)
	print(kind, " rendered bounds from 0.12x to 2.5x: ", sizes)

func check_full_map(main: Node, viewport: SubViewport, overlay: CheatOverlay) -> void:
	main._cheat_ids = ""
	main._cheat_coords = true
	main.zoom = 0.12
	main.pan = Vector2(16.25, 20.75)
	var capture := await frame(viewport)
	var missing := 0
	var painted := 0
	for y in main.state.grid.height:
		for x in main.state.grid.width:
			var tile := Rect2(main._cell_screen(Vector2i(x, y)), Vector2.ONE * main.CELL * main.zoom)
			if not ink_bounds(capture, Rect2i(tile)).has_area(): missing += 1
	for y in capture.get_height():
		for x in capture.get_width():
			if capture.get_pixel(x, y).a > 0.05: painted += 1
	var area: float = main.state.grid.width * main.state.grid.height * pow(main.CELL * main.zoom, 2)
	ck(missing == 0, "all 19,200 cells have coordinate pixels at minimum zoom: %d missing" % missing)
	ck(painted / area < 0.4, "distant coordinate labels leave most of each cell uncovered: %.1f%% painted" % (painted * 100 / area))
	print("Full map: ", missing, " missing coordinates; ", snappedf(painted * 100 / area, 0.1), "% label coverage")
	capture.save_png("/tmp/isotope-fix12-labels-distant.png")
	# Pan without changing the visible tile range: retained commands must still
	# move by exactly the camera displacement, with no stale image left behind.
	main.pan += Vector2(13, 9)
	var redraws := [0]
	overlay._coordinates.draw.connect(func(): redraws[0] += 1)
	var moved := await frame(viewport)
	var board := Rect2i(Vector2i(16, 20), Vector2i(780, 590))
	var before := capture.get_region(board).get_data()
	var after := moved.get_region(Rect2i(board.position + Vector2i(13, 9), board.size)).get_data()
	var same := true
	# Translation may change channel rounding by one byte in the renderer.
	for i in before.size():
		if absi(before[i] - after[i]) > 1: same = false; break
	ck(same, "cached coordinates follow panning without changing size or leaving stale pixels")
	for i in 3: await frame(viewport)
	ck(redraws[0] == 0, "static full-map frames and panning reuse the coordinate draw commands")
	main.zoom = 0.35
	main.pan = Vector2(-500, -350)
	capture = await frame(viewport)
	var cells := overlay.visible_coordinate_cells()
	var unlabelled := 0
	for y in range(cells.position.y + 1, cells.end.y - 1):
		for x in range(cells.position.x + 1, cells.end.x - 1):
			var tile := Rect2(main._cell_screen(Vector2i(x, y)), Vector2.ONE * main.CELL * main.zoom)
			if not ink_bounds(capture, Rect2i(tile)).has_area(): unlabelled += 1
	ck(unlabelled == 0, "panning and zooming retain consecutive coordinates, including three-digit cells")

func check_stacks(main: Node, viewport: SubViewport, overlay: CheatOverlay) -> void:
	var cell := Vector2i(16, 16)
	for i in 6:
		var body: UnitInstance = main.state.spawn_unit(main.state.get_unit(0).stats, cell, 0, false)
		body.status = MCF.Status.CORPSE
		body.corpse_stacked = true
		main.state.grid.cell(cell).corpse_count += 1
	main._cheat_ids = "all"
	main._cheat_coords = true
	main.zoom = 1.0
	main.pan = Vector2(200, 100) - main._cell_origin(cell)
	var labels: Array = overlay.labels()[cell]
	ck(labels.size() == 7, "vehicle and six corpses share one labelled tile")
	var tile := Rect2(main._cell_screen(cell), Vector2.ONE * main.CELL)
	var boxes: Array[Rect2] = [overlay.coordinate_box(cell)]
	for row in labels.size():
		var box := overlay.label_box(cell, labels[row], row, labels.size())
		ck(tile.encloses(box) and box.has_area(), "stacked label stays inside cell")
		for other: Rect2 in boxes: ck(not box.intersects(other), "stacked IDs and coordinates do not overlap")
		boxes.append(box)
	var capture := await frame(viewport)
	for box: Rect2 in boxes:
		ck(ink_bounds(capture, Rect2i(box.grow(0.5))).has_area(), "each stacked label produces pixels")
	capture.save_png("/tmp/isotope-fix12-labels-close.png")

func ink_bounds(capture: Image, region: Rect2i) -> Rect2i:
	var low := Vector2i(9999, 9999)
	var high := Vector2i(-1, -1)
	for y in range(maxi(0, region.position.y), mini(capture.get_height(), region.end.y)):
		for x in range(maxi(0, region.position.x), mini(capture.get_width(), region.end.x)):
			if capture.get_pixel(x, y).a > 0.05:
				low = low.min(Vector2i(x, y))
				high = high.max(Vector2i(x, y))
	if high.x < 0: return Rect2i()
	return Rect2i(low, high - low + Vector2i.ONE)
