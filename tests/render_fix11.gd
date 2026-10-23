extends "res://tests/SuiteBase.gd"

func run() -> void:
	if DisplayServer.get_name() == "headless": ck(false, "requires rendered display"); return
	root.size = Vector2i(1280, 720)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.cheats_enabled = true
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.roster = Roster.default_duel(false)
	for slot: Roster.Slot in GameConfig.roster.slots: slot.cheats_allowed = true
	var map := MapData.blank_arena(64, 48)
	map.set_spawn(Vector2i(22, 20), "light_infantry", 0)
	map.set_spawn(Vector2i(52, 36), "light_infantry", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	main._kill_pan_tween()
	main._start_first_person(Vector2i(22, 20))
	for i in 70: await process_frame
	var fp: Node = main._fp
	fp.pitch = -0.3
	fp._place_camera()
	fp._vis_img.fill(Color.BLACK)
	for y in range(16, 48):
		for x in 64: fp._vis_img.set_pixel(x, y, Color.WHITE)
	fp._upload_visibility()
	fp.set_process(false)
	main.set_process(false)
	await RenderingServer.frame_post_draw
	var reference: Image = fp._vp.get_texture().get_image()
	var pixel_changes := 0
	for i in 8:
		# Repeated publication of an unchanged visibility image cannot shimmer.
		fp._upload_visibility()
		await process_frame
		await RenderingServer.frame_post_draw
		var current: Image = fp._vp.get_texture().get_image()
		if reference.get_data() != current.get_data(): pixel_changes += 1
	ck(pixel_changes == 0, "first-person fog remains stable across visibility texture publication")
	reference.save_png("/tmp/isotope-fix11-first-person.png")
	var ui := root.get_node("Ui")
	var distance: int = ui.fp_render_distance
	ui.fp_render_distance = 64
	fp._place_camera()
	for material: ShaderMaterial in fp._all_mats:
		ck(material.get_shader_parameter("render_radius") == 64.0, "live render distance reaches every board material")
	ui.fp_render_distance = distance
	fp.leave()
	for i in 3: await process_frame
	main.set_process(true)
	main.resolver.fog_mode = MCF.Fog.OFF
	GameConfig.fog_mode = MCF.Fog.OFF
	main.state.turns.active_index = main.state.turns.round_order.find(0)
	main._kill_pan_tween()
	# Full rendered tile-label coverage lives in render_label_zoom.gd.
	var settings: Node = load("res://src/ui/SettingsWindow.gd").open(main)
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-fix11-settings.png")
	settings.free()
	main._escape_pressed()
	for i in 4: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-fix11-menu.png")
	main._battle_menu.free()
	var data: Dictionary = main.recorder.to_dict().duplicate(true)
	# Populate a short, deterministic replay with visible changes and a rewind marker.
	for i in 60:
		main.resolver.resolve(CheatIntent.new("unit_stat", {"unit": 0, "field": "armor", "value": 1 + i % 12}, 0))
	data = main.recorder.to_dict().duplicate(true)
	var host_hash: int = main.state.digest_hash()
	var executable := ReplayVideoEncoder.find_ffmpeg()
	ck(not executable.is_empty(), "FFmpeg installed for actual video test")
	for speed: float in [1.0, 4.0]:
		var exporter := ReplayVideoExporter.new()
		root.add_child(exporter)
		var result := {"done": false, "error": ""}
		exporter.completed.connect(func(_path: String, error: String): result.done = true; result.error = error)
		var path := "/tmp/isotope-fix11-%dx.mp4" % int(speed)
		exporter.run(data, path, Vector2i(640, 360), 30, speed, executable)
		var deadline := Time.get_ticks_msec() + 60000
		while not result.done and Time.get_ticks_msec() < deadline: await process_frame
		if not result.done: exporter.cancel()
		ck(result.done and result.error.is_empty(), "MP4 export completes at %dx: %s" % [int(speed), result.error])
		ck(FileAccess.file_exists(path), "real video file exists")
		exporter.free()
		await process_frame
	ck(main.state.digest_hash() == host_hash, "video rendering never changes the live match")
	SaveHandoff.pending_replay = data
	var viewing: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(viewing)
	for i in 4: await process_frame
	var window: Node = load("res://src/ui/ReplayExportWindow.gd").open(viewing)
	for i in 5: await process_frame
	ck(not window.export_button.disabled and window.resolution.item_count == 4 and window.fps.item_count == 3, "export window exposes encoder and video choices")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-fix11-video-options.png")
	window.free()
	viewing.free()
	await process_frame
	main.free()
	await process_frame
