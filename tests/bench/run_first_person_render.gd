extends SceneTree

## Rendered 160 m profile. Run with a real display or Xvfb; software-renderer
## timings are comparative measurements, not a prediction of a player's FPS.
func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	if DisplayServer.get_name() == "headless": quit(1); return
	var frames := 60
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="): frames = maxi(10, arg.get_slice("=", 1).to_int())
	root.size = Vector2i(1280, 720)
	var ui := root.get_node("Ui")
	ui.fp_render_distance = 160
	ui.snowfall = false
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapGen.generate({"style": MapGen.Style.TOWN, "size": MapGen.SIZE_CUSTOM,
		"width": 150, "height": 130, "seed": 83, "units": 80, "furniture": 3, "winter": false})
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var tiles := TerrainTiles.new(grid, "town")
	var host := FirstPersonHost.new(map, tiles)
	host.state.time_of_day = "day"
	root.add_child(host)
	var script = load("res://scenes/main/FirstPerson.gd")
	var fp: Control = script.new(host, Vector2i(75, 65))
	root.add_child(fp)
	fp.set_process(false)
	fp._vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	fp.pos = Vector3(75.5, 3.0, 65.5)
	fp.pitch = -0.08
	fp._place_camera()
	var build := Time.get_ticks_usec()
	fp._stream_chunks(60000000)
	print("Full 160 m build: %.1f ms, %d chunks" % [(Time.get_ticks_usec() - build) / 1000.0, fp._chunks.size()])
	fp._vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for i in 8:
		fp._process(0.016)
		await process_frame
		await RenderingServer.frame_post_draw
	fp._vp.get_texture().get_image().save_png("/tmp/isotope-fp-profile.png")
	for moving in [false, true]:
		var times: Array[float] = []
		var cpu: Array[float] = []
		var draws := 0.0
		var triangles := 0.0
		for i in frames:
			var before := Time.get_ticks_usec()
			if moving:
				fp.yaw += 0.025
				fp.pos.x += 0.06
			var t := Time.get_ticks_usec()
			fp._process(0.016)
			cpu.append((Time.get_ticks_usec() - t) / 1000.0)
			await process_frame
			await RenderingServer.frame_post_draw
			times.append((Time.get_ticks_usec() - before) / 1000.0)
			draws += fp._vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			triangles += fp._vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
		times.sort(); cpu.sort()
		print("%s: frame median %.2f ms p95 %.2f ms; CPU median %.2f ms p95 %.2f ms; %.0f draws %.0f triangles" % ["moving" if moving else "still", times[frames / 2], times[int(frames * 0.95)], cpu[frames / 2], cpu[int(frames * 0.95)], draws / frames, triangles / frames])
	fp.free()
	host.free()
	quit()
