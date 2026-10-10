extends SceneTree

## Exercise the actual background builders, including the space-tile regression.
## Under a real renderer also check every pixel, camera clipping and tile phase.

var failures: PackedStringArray = []

func _initialize() -> void:
	_run.call_deferred()

func ck(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

func _run() -> void:
	for env in ["field", "town", "station", "bunker"]:
		for space in [false, true]:
			await _check(env, space)
	if failures.is_empty():
		print("ground backdrop: grass/soil, space, camera, bounds and state checks passed")
	else:
		for failure in failures:
			printerr(failure)
	quit(0 if failures.is_empty() else 1)

func _check(env: String, space: bool) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(320, 240)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var m := MapData.new(4, 3)
	m.env = env
	m.set_cell(Vector2i(1, 1), MCF.FLOOR_NORMAL, 0.0, space, "")
	var battle: Variant = load("res://tests/fixtures/GroundBackgroundOnly.gd").new()
	battle.state = m.build_state(97)
	viewport.add_child(battle)
	var before := JSON.stringify(StateCodec.encode(battle.state))
	var tag := "%s space=%s" % [env, space]
	battle._build_sky()
	battle._build_ground()
	var outdoor := env in ["field", "town", "bunker"]
	var expected := outdoor or not space
	ck((battle._ground != null) == expected, tag + ": backdrop exists")
	ck((battle._sky != null) == space, tag + ": space retains its sky")
	for outside in [Vector2i(-1, 1), Vector2i(4, 1), Vector2i(1, -1), Vector2i(1, 3)]:
		ck(Movement.enter_cost(battle.state.grid, Vector2i(1, 1), outside) == -1,
				tag + ": infantry cannot enter cosmetic ground")
		ck(not VehicleRules.cell_entry(battle.state, outside, -1)["ok"],
				tag + ": vehicles cannot enter cosmetic ground")
	if battle._ground != null:
		if env == "bunker":
			ck(battle._ground_floor_name() == "soil", "bunker uses soil wall art")
			var sheet: Image = battle._ground_image("soil_autotile")
			var tile := sheet.get_width() / 4
			var expected_tile := sheet.get_region(Rect2i(tile * 3, tile * 3, tile, tile))
			var actual_tile: Image = battle._ground.texture.get_image().get_region(Rect2i(0, 0, tile, tile))
			ck(expected_tile.get_data() == actual_tile.get_data(), "bunker repeats the connected soil WALL tile")
		var texture_id: int = battle._ground.texture.get_instance_id()
		# Hide the sky for pixel checks: the uncovered board should show clear black.
		if battle._sky != null:
			battle._sky.hide()
		for camera in [Vector3(80, 60, 0.5), Vector3(-32, -24, 1.0),
				Vector3(500, 400, 0.02), Vector3(-10, -10, 4.0)]:
			battle.pan = Vector2(camera.x, camera.y)
			battle.zoom = camera.z
			battle._fit_ground()
			ck(battle._ground.texture.get_instance_id() == texture_id,
					tag + ": camera reuses its baked texture")
			if outdoor and DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
				_check_pixels(viewport, battle, tag)
		viewport.size = Vector2i(400, 180)
		battle._fit_ground()
		if outdoor and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			_check_pixels(viewport, battle, tag + " resized")
	ck(JSON.stringify(StateCodec.encode(battle.state)) == before,
			tag + ": background and camera leave simulation state identical")
	viewport.queue_free()
	await process_frame

func _check_pixels(viewport: SubViewport, battle: Variant, tag: String) -> void:
	var pixels := viewport.get_texture().get_image()
	var board := Rect2(battle.pan + battle.ORIGIN * battle.zoom,
			Vector2(4, 3) * battle.CELL * battle.zoom)
	var wallpaper: Image = battle._ground.texture.get_image()
	var pixel_scale: float = battle._ground.scale.x
	for y in pixels.get_height():
		for x in pixels.get_width():
			var p := Vector2(x + 0.5, y + 0.5)
			var actual := pixels.get_pixel(x, y)
			if board.has_point(p):
				if actual.r > 0.01 or actual.g > 0.01 or actual.b > 0.01:
					ck(false, tag + ": wallpaper covers the board at " + str(p))
					return
			else:
				if battle.state.env != "bunker" and (actual.g <= actual.r or actual.g <= actual.b):
					ck(false, tag + ": uncovered/non-grass pixel at " + str(p))
					return
				# Check the board-relative phase away from sampling boundaries.
				var uv := (p - board.position) / pixel_scale
				if absf(uv.x - roundf(uv.x)) < 0.01 or absf(uv.y - roundf(uv.y)) < 0.01:
					continue
				var expected := wallpaper.get_pixel(posmod(floori(uv.x), wallpaper.get_width()),
						posmod(floori(uv.y), wallpaper.get_height()))
				if absf(actual.r - expected.r) > 0.01 or absf(actual.g - expected.g) > 0.01 \
						or absf(actual.b - expected.b) > 0.01:
					ck(false, tag + ": wallpaper phase shifted at " + str(p))
					return
