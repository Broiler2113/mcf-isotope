extends SceneTree

## Visual acceptance scenes for the PDF's furniture, fortifications, winter and lighting.
## xvfb-run -a godot --path . --script res://tests/render_first_person.gd
## Screenshots go to /tmp/isotope-first-person-*.png.
var failures: PackedStringArray = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Run with a Compatibility renderer, e.g. xvfb-run -a godot --path . --script res://tests/render_first_person.gd")
		quit(2)
		return
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1000, 700)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var ui: Node = root.get_node("Ui")
	ui.dynamic_lighting = true
	ui.snowfall = true
	var selected := OS.get_cmdline_user_args()
	for name in ["furniture", "damaged-bed", "outdoor", "winter", "vehicles"]:
		if selected.is_empty() or selected.has(name):
			await _scene(name, name == "winter", name in ["furniture", "damaged-bed"], name == "damaged-bed")
	print("first-person render: %d failure(s)" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _put(m: MapData, at: Vector2i, fid: String, size := Vector2i.ONE) -> void:
	for y in size.y:
		for x in size.x:
			m.set_cell(at + Vector2i(x, y), MCF.FLOOR_NORMAL, 0, false, fid)

func _scene(label: String, winter: bool, indoors: bool, damaged := false) -> void:
	var m := MapData.blank_arena(20, 18)
	m.env = "station" if indoors else "town"
	m.time_of_day = "day"
	m.winter = winter
	if indoors:
		for x in range(2, 17):
			_put(m, Vector2i(x, 2), MCF.FEATURE_WALL)
		for y in range(3, 13):
			_put(m, Vector2i(2, y), MCF.FEATURE_WALL)
		_put(m, Vector2i(5, 4), "desk", Vector2i(2, 1))
		_put(m, Vector2i(6, 6), "chair")
		_put(m, Vector2i(9, 4), "bed", Vector2i(1, 2))
		_put(m, Vector2i(12, 4), "hydroponic_rack", Vector2i(2, 1))
		_put(m, Vector2i(15, 4), "planter_bed")
		_put(m, Vector2i(3, 4), "bookshelf")
		_put(m, Vector2i(3, 7), "toilet")
		_put(m, Vector2i(3, 9), "sink")
		m.items = [["monitor", 5.5, 4.35, 0.0], ["keyboard", 5.5, 4.65, 0.0], ["mug", 6.5, 4.5, 0.0], ["rifle", 7.5, 5.5, 0.3]]
		m.fixtures[2 * m.width + 6] = [["wall_strip", 2, 2, 0]]
		m.fixtures[2 * m.width + 12] = [["wall_lamp", 1, 2, 0]]
	elif label == "vehicles":
		m.set_spawn(Vector2i(4, 5), "tank", 0)
		m.set_spawn(Vector2i(9, 5), "shuttle", 0)
		m.set_spawn(Vector2i(13, 5), "borg", 0)
	else:
		for p in [[4, 5, MCF.FEATURE_SANDBAGS], [5, 5, MCF.FEATURE_SANDBAGS],
				[7, 5, MCF.FEATURE_HEDGEHOG], [9, 5, MCF.FEATURE_HEDGEHOG_SANDBAGS],
				[11, 5, MCF.FEATURE_DPMG], [14, 4, "pine_tree"], [16, 5, "park_tree"],
				[3, 3, "bush"], [12, 3, "hedge"], [6, 3, MCF.FEATURE_LDF]]:
			_put(m, Vector2i(p[0], p[1]), p[2])
		if winter:
			m.decals = [["snowman", 12.5, 7.5, 0.0, 1.0], ["snowdrift", 4.5, 7.5, 0.0, 1.0]]
	var grid := Grid.new(m.width, m.height)
	m.apply_to_grid(grid)
	var tiles := TerrainTiles.new(grid, m.env)
	tiles.set_time_of_day(m.time_of_day)
	tiles.set_winter(winter)
	var host := FirstPersonHost.new(m, tiles)
	root.add_child(host)
	if indoors:
		host._fx.wall_blood.append({"cell": Vector2i(8, 2), "face": Vector2i.DOWN, "rot": 1.5, "scale": 1.1})
		host._fx.wall_blood.append({"cell": Vector2i(10, 2), "face": Vector2i.DOWN, "rot": 0.3, "scale": 0.95})
	if damaged:
		tiles.furniture_look = tiles.freeze_furniture()
		grid.cell(Vector2i(9, 4)).clear_feature()
		host.state.grid.cell(Vector2i(9, 4)).clear_feature()
	var before := JSON.stringify(StateCodec.encode(host.state))
	var fp: Control = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(8, 10))
	root.add_child(fp)
	fp.yaw = 0.15
	fp.pitch = -0.24
	for i in 50:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = fp._vp.get_texture().get_image()
	img.save_png("/tmp/isotope-first-person-%s.png" % label)
	if img.is_empty() or img.get_size().x < 500:
		failures.append(label + ": missing rendered viewport")
	var samples: Array[float] = []
	for i in 60:
		var start := Time.get_ticks_usec()
		fp.pos.x = 8.5 + sin(i * 0.04)
		fp.yaw += 0.002
		await process_frame
		samples.append((Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	print("%s: rendered %dx%d; moving frame median %.1f ms, p95 %.1f ms" % [label, img.get_width(), img.get_height(), samples[30], samples[57]])
	if JSON.stringify(StateCodec.encode(host.state)) != before:
		failures.append(label + ": walking changed the simulation")
	fp.free()
	host.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await process_frame
