extends SceneTree

## Actual Compatibility renderer checks for unlit drawings and late fire/corpse layering.
var failures: Array[String] = []
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func capture(main: Node) -> Image:
	main.queue_redraw()
	for i in 4: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
func run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(2)
		return
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1000, 720)
	root.content_scale_factor = 1.0
	root.content_scale_size = Vector2i.ZERO
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var ui := root.get_node("Ui")
	ui.dynamic_lighting = false
	var map := MapData.blank_arena(18, 14)
	map.env = "town"
	map.time_of_day = "day"
	map.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(7, 5), "light_infantry", 1)
	map.set_spawn(Vector2i(15, 11), "light_infantry", 1)
	MapHandoff.pending = map
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	main._ui_layer.visible = false
	main._kill_pan_tween()
	main.pan = Vector2(20, 20)
	main.zoom = 1.0
	var mark: Vector2 = main.ORIGIN + Vector2(3.5, 5.5) * main.CELL
	main._canvas(0, 0).stroke(mark - Vector2(10, 0), mark + Vector2(10, 0), 6, Color(0, 1, 1))
	var pixel := Vector2i(main.pan + mark)
	var day := await capture(main)
	main.state.time_of_day = "night"
	var night := await capture(main)
	ck(day.get_pixelv(pixel).is_equal_approx(night.get_pixelv(pixel)) and night.get_pixelv(pixel).g > 0.95, "drawings retain their exact color under night tint")
	ui.dynamic_lighting = true
	ui.light_darkness = 1.0
	var lit := await capture(main)
	ck(day.get_pixelv(pixel).is_equal_approx(lit.get_pixelv(pixel)), "drawings retain their exact color above dynamic lighting")
	lit.save_png("/tmp/isotope-drawings-night.png")
	# Compare every pixel of two equally burning cells: the standing soldier is covered
	# by the fire, while the corpse remains visible above it.
	ui.dynamic_lighting = false
	main.state.time_of_day = "day"
	var corpse: UnitInstance = main.state.grid.cell(Vector2i(7, 5)).occupant
	corpse.kill()
	for c in [Vector2i(5, 5), Vector2i(7, 5), Vector2i(9, 5)]: main.state.grid.cell(c).on_fire = true
	var natural := await capture(main)
	natural.save_png("/tmp/isotope-fire-layering.png")
	# The shipped fire is translucent everywhere. Use an opaque test texture to
	# verify draw order without treating underlying terrain variation as a failure.
	var original: Texture2D = Sprites.texture_of("fire")
	var opaque := original.get_image()
	for y in opaque.get_height():
		for x in opaque.get_width():
			var color := opaque.get_pixel(x, y)
			color.a = 1.0
			opaque.set_pixel(x, y, color)
	Sprites._overrides["fire"] = ImageTexture.create_from_image(opaque)
	var fire := await capture(main)
	var live_pixel := Vector2i(main.pan + main.ORIGIN + Vector2(5, 5) * main.CELL)
	var body_pixel := Vector2i(main.pan + main.ORIGIN + Vector2(7, 5) * main.CELL)
	var bare_pixel := Vector2i(main.pan + main.ORIGIN + Vector2(9, 5) * main.CELL)
	var live_diff := 0
	var corpse_diff := 0
	var checked := 0
	# Opaque pixels of the fire must be identical over a soldier and bare floor.
	var texture := Sprites.texture_of("fire")
	var image := texture.get_image()
	for y in range(8, 32):
		for x in range(8, 32):
			var texel := image.get_pixel(int(float(x) / 40 * image.get_width()), int(float(y) / 40 * image.get_height()))
			if texel.a < 0.5: continue
			checked += 1
			var offset := Vector2i(x, y)
			if not fire.get_pixelv(live_pixel + offset).is_equal_approx(fire.get_pixelv(bare_pixel + offset)): live_diff += 1
			if not fire.get_pixelv(body_pixel + offset).is_equal_approx(fire.get_pixelv(bare_pixel + offset)): corpse_diff += 1
	print("fire pixels checked=", checked, " live differences=", live_diff, " corpse differences=", corpse_diff, " source=", image.get_size())
	ck(checked > 0 and live_diff == 0, "opaque fire is drawn over standing units")
	ck(corpse_diff > 0, "corpses remain visible over fire")
	Sprites._overrides["fire"] = original
	main.free()
	print("Rendered reported issues: %d failure(s)" % failures.size())
	quit(0 if failures.is_empty() else 1)
