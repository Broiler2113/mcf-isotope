extends "res://tests/SuiteBase.gd"

func run() -> void:
	if DisplayServer.get_name() == "headless": ck(false, "requires rendered display"); return
	root.size = Vector2i(1000, 700)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	root.get_node("Ui").dynamic_lighting = true
	var map := MapData.blank_arena(120, 90)
	map.env = "town"
	map.time_of_day = "night"
	map.set_cell(Vector2i(64, 45), 0, 0, false, "lamp")
	for y in range(48, 51):
		for x in range(60, 69): map.set_cell(Vector2i(x, y), 0, -1, false, MCF.FEATURE_TRENCH)
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var host := FirstPersonHost.new(map, TerrainTiles.new(grid, map.env))
	root.add_child(host)
	var fp = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(52, 50))
	root.add_child(fp)
	for i in 6: await process_frame
	fp.set_process(false)
	var baseline: float = sample(fp, Vector2i(65, 45))
	ck(baseline > 0.2, "test point is lit")
	for x: float in [60.5, 68.5, 76.5, 68.5, 60.5, 52.5, 44.5, 52.5, 60.5]:
		var before: Rect2i = fp._lm_rect
		var texture: Texture2D = fp._lm_tex
		fp.pos.x = x
		fp._update_light(false)
		if fp._lm_pending:
			ck(fp._lm_rect == before and fp._lm_tex == texture, "pending light map keeps its matching coordinates and texture")
		for i in 2: await process_frame
		await RenderingServer.frame_post_draw
		ck(not fp._lm_pending, "replacement map committed after drawing")
		var value: float = sample(fp, Vector2i(65, 45))
		ck(absf(value - baseline) < 0.025, "world light remains stable across moving/resizing windows: %.3f vs %.3f" % [value, baseline])
	fp.pos = Vector3(64.5, 0, 53.5)
	fp.pitch = -0.3
	fp.yaw = 0
	fp._place_camera()
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	fp._vp.get_texture().get_image().save_png("/tmp/isotope-0132-trenches.png")
	fp.free()
	host.free()
	await process_frame
	GameConfig.cheats_enabled = true
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.roster.slots[0].cheats_allowed = true
	GameConfig.roster.slots[1].cheats_allowed = true
	map = MapData.blank_arena(24, 20)
	map.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	map.set_spawn(Vector2i(21, 17), "engineer", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-0132-hud.png")
	var console = load("res://src/cheats/CheatConsole.gd").open(main)
	main._cheat_console = console
	console.submit("players")
	console.submit("unit stat 0 sight 12")
	console.input.text = "spawn unit "
	console._text_changed(console.input.text)
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-0132-console.png")
	console.queue_free()
	await process_frame
	main.free()
	await process_frame

func sample(fp: Node, cell: Vector2i) -> float:
	var rect: Rect2i = fp._lm_rect
	var img: Image = fp._lm_tex.get_image()
	var point := Vector2(cell - rect.position) + Vector2(0.5, 0.5)
	point *= Vector2(img.get_size()) / Vector2(rect.size)
	return img.get_pixel(int(point.x), int(point.y)).r
