extends "res://tests/SuiteBase.gd"

## Pixel checks for the complete 2D battle, including the terrain below its actors.
## Run with a real renderer and the shipped native bundle.
var output_dir := OS.get_environment("MCF_RENDER_CAPTURE_DIR")

func run() -> void:
	if DisplayServer.get_name() == "headless":
		ck(false, "battle visibility requires a rendered display")
		return
	if output_dir.is_empty(): output_dir = OS.get_cache_dir().path_join("isotope-battle-visibility")
	DirAccess.make_dir_recursive_absolute(output_dir)
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1280, 720)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.fog_mode = MCF.Fog.OFF
	var ui := root.get_node("Ui")
	ui.snowfall = false
	ui.warm_up(["res://scenes/Lobby.tscn", "res://scenes/Main.tscn"])
	await process_frame
	await deployment_transition()
	ui.dynamic_lighting = false
	root.size = Vector2i(1000, 720)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_factor = 1.0
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
	report.store_string(JSON.stringify({"failures": fails, "platform": OS.get_name(),
			"driver": RenderingServer.get_current_rendering_driver_name(),
			"adapter": RenderingServer.get_video_adapter_name(), "log": GameLog.text()}))

func deployment_transition() -> void:
	GameConfig.map_path = ""
	GameConfig.budget = 1000
	GameConfig.fog_mode = MCF.Fog.STANDARD
	var placement: Node = load("res://scenes/Placement.tscn").instantiate()
	root.add_child(placement)
	current_scene = placement
	for i in 5: await process_frame
	for side: int in [0, 1]:
		placement.brush_unit = "tank"
		placement._click_cell(Vector2i(6 if side == 0 else 15, 5))
		placement.brush_unit = "light_infantry"
		placement._click_cell(Vector2i(9 if side == 0 else 14, 9))
		ck(placement._side_unit_count(side) == 2, "deployment records both actors for side %d" % side)
		placement._on_flow()
	await scene_changed
	for i in 10: await process_frame
	var main := current_scene
	ck(main.scene_file_path == "res://scenes/Main.tscn", "deployment enters the battle scene")
	ck(main.state.all_units().size() == 2, "both deployed soldiers enter the battle")
	ck(main.state.all_vehicles().size() == 2, "both deployed tanks enter the battle")
	var side: int = main.state.active_player()
	var soldier := Vector2i(9 if side == 0 else 14, 9)
	var tank := Vector2i(6 if side == 0 else 15, 5)
	var screen: Vector2 = main._cell_screen(soldier) + Vector2.ONE * main.CELL * main.zoom * 0.5
	ck(main.get_viewport_rect().has_point(screen), "the starting camera includes its own soldier")
	main._handle_click(main._pos_to_cell(screen))
	ck(main.selected_id == main.state.grid.cell(soldier).occupant.id, "the deployed soldier can be selected")
	main._deselect()
	main._handle_click(tank)
	ck(main.selected_vehicle_id == main.state.vehicle_on(tank).id, "the deployed tank can be selected")
	main._deselect()
	var actors := await capture(main)
	actors.save_png(output_dir.path_join("deployment-battle.png"))
	main.self_modulate.a = 0.0
	var terrain := await capture(main)
	var soldier_rect := Rect2i(Rect2(main._cell_screen(soldier) + Vector2.ONE * 8 * main.zoom,
			Vector2.ONE * 24 * main.zoom))
	var hull_rect := Rect2i(Rect2(main._cell_screen(tank) + Vector2.ONE * 24 * main.zoom,
			Vector2.ONE * 72 * main.zoom))
	ck(changed_pixels(actors, terrain, soldier_rect) > 20, "new-battle soldier is drawn with the default camera and lighting")
	ck(changed_pixels(actors, terrain, hull_rect) > 100, "new-battle tank is drawn with the default camera and lighting")
	main.free()
	await process_frame

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
