extends "res://tests/SuiteBase.gd"

## Pixel checks for the complete 2D battle, including the terrain below its actors.
## Run with a real renderer. Windows CI uses ANGLE and the shipped native bundle.
var output_dir := OS.get_environment("MCF_RENDER_CAPTURE_DIR")

func run() -> void:
	if DisplayServer.get_name() == "headless":
		ck(false, "battle visibility requires a rendered display")
		return
	if output_dir.is_empty(): output_dir = OS.get_cache_dir().path_join("isotope-battle-visibility")
	DirAccess.make_dir_recursive_absolute(output_dir)
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1000, 720)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_factor = 1.0
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.fog_mode = MCF.Fog.OFF
	var ui := root.get_node("Ui")
	ui.snowfall = false
	ui.dynamic_lighting = false
	ui.warm_up(["res://scenes/Lobby.tscn", "res://scenes/Main.tscn"])
	await process_frame
	var map := MapData.blank_arena(60, 48)
	map.env = "field"
	map.time_of_day = "day"
	map.set_spawn(Vector2i(10, 5), "tank", 0, Vector2i.RIGHT)
	map.set_spawn(Vector2i(9, 9), "light_infantry", 0)
	map.set_spawn(Vector2i(14, 9), "light_infantry", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	main.set_process(false)
	main._kill_pan_tween()
	main._ui_layer.hide()
	main.state.turns.round_order.assign([0, 1])
	main.state.turns.active_index = 0
	print("Rendered battle: ", OS.get_name(), "; ", RenderingServer.get_video_adapter_name(),
			"; acceleration=", NativeAcceleration.status())
	for fog: int in [MCF.Fog.OFF, MCF.Fog.STANDARD, MCF.Fog.REALISTIC]:
		main.resolver.fog_mode = fog
		for zoom: float in [0.18, 0.75, 1.0, 1.75]:
			main.zoom = zoom
			main.pan = Vector2(420, 320) - main._cell_origin(Vector2i(12, 8)) * zoom
			main.self_modulate.a = 1.0
			var actors := await capture(main)
			main.self_modulate.a = 0.0
			var terrain := await capture(main)
			main.self_modulate.a = 1.0
			var suffix := "%d-%.2f" % [fog, zoom]
			actors.save_png(output_dir.path_join("battle-" + suffix + ".png"))
			for at: Vector2i in [Vector2i(9, 9), Vector2i(14, 9)]:
				var region := Rect2(main._cell_screen(at) + Vector2.ONE * 8 * zoom, Vector2.ONE * 24 * zoom)
				var differences := changed_pixels(actors, terrain, Rect2i(region))
				ck(differences > maxi(3, int(region.get_area() * 0.25)),
						"soldier is visibly drawn at %s, fog/zoom %s (%d pixels)" % [at, suffix, differences])
			var hull := Rect2(main._cell_screen(Vector2i(10, 5)) + Vector2.ONE * 24 * zoom, Vector2.ONE * 72 * zoom)
			var differences := changed_pixels(actors, terrain, Rect2i(hull))
			ck(differences > maxi(20, int(hull.get_area() * 0.4)),
					"tank armour is visibly drawn above terrain, fog/zoom %s (%d pixels)" % [suffix, differences])
	main.free()
	await process_frame
	var report := FileAccess.open(output_dir.path_join("result.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify({"failures": fails, "platform": OS.get_name()}))

func capture(main: Node) -> Image:
	main.queue_redraw()
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func changed_pixels(a: Image, b: Image, region: Rect2i) -> int:
	region = region.intersection(Rect2i(Vector2i.ZERO, a.get_size()))
	var count := 0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var ac := a.get_pixel(x, y)
			var bc := b.get_pixel(x, y)
			if absf(ac.r - bc.r) + absf(ac.g - bc.g) + absf(ac.b - bc.b) > 0.1: count += 1
	return count
