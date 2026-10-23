extends "res://tests/SuiteBase.gd"

## Exercise the real battlefield overlay through zoom input, including fractional
## camera positions. Compare the glyphs themselves, not only layout measurements.
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
	var map := MapData.blank_arena(64, 48)
	map.set_spawn(Vector2i(8, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(52, 40), "light_infantry", 1)
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
	for child: Node in main.get_children():
		if child is CanvasLayer and child.get_children().any(func(node: Node): return node is CheatOverlay): layer = child
	ck(layer != null, "the gameplay label layer exists")
	if layer == null: viewport.free(); return
	# Keep the real scene ancestry and camera updates; hide only the other
	# drawing so battlefield textures cannot conceal a change in label glyphs.
	main.self_modulate.a = 0.0
	for child: Node in main.get_children():
		if child is CanvasLayer: child.visible = child == layer
		elif child is CanvasItem: child.hide()
	await check_glyphs(main, viewport, "unit", Vector2i(8, 8))
	main.resolver._kill(main.state.get_unit(0))
	await check_glyphs(main, viewport, "corpse", Vector2i(8, 8))
	main.state.spawn_vehicle("tank", Vector2i(16, 16), 0)
	await check_glyphs(main, viewport, "vehicle", Vector2i(16, 16))
	await check_glyphs(main, viewport, "coordinate", Vector2i.ZERO)
	viewport.free()
	await process_frame

func check_glyphs(main: Node, viewport: SubViewport, kind: String, cell: Vector2i) -> void:
	main._cheat_ids = "" if kind == "coordinate" else ("vehicles" if kind == "vehicle" else "units")
	main._cheat_coords = kind == "coordinate"
	var world: Vector2 = main._cell_origin(cell)
	if kind != "coordinate": world += Vector2(main.CELL * 0.5, 0)
	var reference := {}
	var sizes: Array[Vector2i] = []
	var phase := 0
	for zoom: float in [0.12, 0.35, 0.75, 1.0, 1.25, 1.75, 2.5]:
		main.zoom = 1.0
		var start := Vector2(120, 40) + Vector2(0.25, 0.25) * (phase % 4)
		main.pan = start - world
		var gesture := InputEventMagnifyGesture.new()
		gesture.position = start + Vector2(12.3, 4.7)
		gesture.factor = zoom
		main._unhandled_input(gesture)
		ck(is_equal_approx(main.zoom, zoom), "pinch reaches %s zoom for %s" % [zoom, kind])
		var anchor: Vector2 = main.pan + world * main.zoom
		var region := Rect2i(Vector2i(anchor.floor()) + Vector2i(-80, -18), Vector2i(160, 18))
		if kind == "coordinate": region = Rect2i(Vector2i(anchor.floor()), Vector2i(40, 16))
		await process_frame
		await RenderingServer.frame_post_draw
		var glyph := glyph_mask(viewport.get_texture().get_image(), region)
		ck(not glyph.is_empty(), "rendered %s glyph is visible at %s" % [kind, zoom])
		if not glyph.is_empty():
			sizes.append(glyph.size)
			if reference.is_empty(): reference = glyph
			else: ck(glyph == reference, "%s pixels remain constant at zoom %s: %s vs %s" % [kind, zoom, glyph.size, reference.size])
		phase += 1
	print(kind, " rendered glyph sizes: ", sizes)

func glyph_mask(image: Image, region: Rect2i) -> Dictionary:
	var points: Array[Vector2i] = []
	var low := Vector2i(9999, 9999)
	var high := Vector2i(-1, -1)
	for y in range(maxi(0, region.position.y), mini(image.get_height(), region.end.y)):
		for x in range(maxi(0, region.position.x), mini(image.get_width(), region.end.x)):
			var pixel := image.get_pixel(x, y)
			if pixel.a > 0.5 and pixel.r > 0.5 and pixel.g > 0.4 and pixel.b > 0.25:
				var point := Vector2i(x, y)
				points.append(point)
				low = low.min(point)
				high = high.max(point)
	if points.is_empty(): return {}
	return {"size": high - low + Vector2i.ONE, "pixels": points.map(func(point: Vector2i): return point - low)}
