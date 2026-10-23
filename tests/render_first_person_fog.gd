extends "res://tests/SuiteBase.gd"

func run() -> void:
	if DisplayServer.get_name() == "headless": ck(false, "requires rendered display"); return
	root.size = Vector2i(960, 640)
	var ui := root.get_node("Ui")
	ui.snowfall = false
	ui.fp_render_distance = 160
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var map := MapData.blank_arena(32, 24)
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var host := FirstPersonHost.new(map, TerrainTiles.new(grid, "town"))
	root.add_child(host)
	var fp: Node = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(16, 17))
	root.add_child(fp)
	fp.set_process(false)
	fp._stream_chunks(10000000)
	fp._vis_img.fill(Color.BLACK)
	for y in range(12, 24):
		for x in 32: fp._vis_img.set_pixel(x, y, Color.WHITE)
	fp._upload_visibility()
	var marker := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(64, 64)
	marker.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.disable_fog = true
	material.albedo_color = Color(1, 0, 1)
	marker.material_override = material
	fp._world.add_child(marker)
	for height: float in [0.0, 100.0, -100.0]:
		fp.pos = Vector3(16.5, height, 17.5)
		fp.yaw = 0.0
		fp.pitch = 0.0
		fp._place_camera()
		marker.position = Vector3(16.5, height + fp.EYE, 6)
		marker.hide()
		var clear := await frame(fp)
		marker.show()
		var hidden := await frame(fp)
		ck(clear.get_data() == hidden.get_data(), "opaque fog hides bright geometry at altitude %s" % height)
		var colors := {}
		for y in range(200, 440, 4):
			for x in range(250, 710, 4): colors[hidden.get_pixel(x, y).to_rgba32()] = true
		ck(colors.size() > 32, "fog has visible texture at altitude %s" % height)
		if height == 0:
			hidden.save_png("/tmp/isotope-first-person-dense-fog.png")
			for i in 3:
				fp._upload_visibility()
				ck((await frame(fp)).get_data() == hidden.get_data(), "unchanged fog remains stable when visibility is republished")
		fp._fog_boundary.hide()
		ck((await frame(fp)).get_data() != hidden.get_data(), "bright marker is visible when the fog surface is removed")
		fp._fog_boundary.show()
	marker.hide()
	await time_cycle(fp)
	fp.free()
	host.free()
	await process_frame

func time_cycle(fp: Node) -> void:
	var ui := root.get_node("Ui")
	ui.light_darkness = 0.75
	fp._vis_img.fill(Color.WHITE)
	fp._upload_visibility()
	fp.pos = Vector3(16.5, 0, 17.5)
	fp._place_camera()
	for dynamic: bool in [true, false]:
		ui.dynamic_lighting = dynamic
		var brightness := {}
		var pictures := {}
		for time: String in ["night", "day", "evening", "morning", "night"]:
			fp.state.time_of_day = time
			fp._sync_environment()
			fp._update_light(true)
			fp._refresh_floors()
			fp._stream_chunks(10000000)
			await frame(fp)
			var picture := await frame(fp)
			var sun_count: int = fp._environment_root.find_children("*", "DirectionalLight3D", true, false).size()
			ck(sun_count == (0 if time == "night" else 1), "time updates first-person sun without reopening: " + time)
			var level := 0.0
			for y in range(picture.get_height() - 80, picture.get_height() - 20, 4):
				for x in range(250, 710, 4): level += picture.get_pixel(x, y).get_luminance()
			brightness[time] = level
			pictures[time] = picture.get_data()
		ck(brightness.day > brightness.night * 1.1, "day ground is brighter than night with dynamic lighting %s" % dynamic)
		ck(pictures.day != pictures.evening and pictures.day != pictures.morning, "dawn/dusk visibly change sky and lighting")

func frame(fp: Node) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return fp._vp.get_texture().get_image()
