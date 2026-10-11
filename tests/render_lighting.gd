extends SceneTree

## Requires an actual Compatibility renderer (xvfb-run works on Linux).
var failures: Array[String] = []
func ck(ok: bool, label: String) -> void:
	print(("ok " if ok else "FAIL ") + label)
	if not ok: failures.append(label)
func _initialize() -> void: run.call_deferred()
func pixels(manager: LightManager) -> Image:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	return manager.viewport.get_texture().get_image()

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("This test needs a display: xvfb-run -a godot --script tests/render_lighting.gd")
		quit(2)
		return
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(512, 512)
	var manager := LightManager.new()
	root.add_child(manager)
	var grid := Grid.new(16, 16)
	grid.cell(Vector2i(4, 6)).set_feature("lamp")
	for y in range(1, 12): grid.cell(Vector2i(7, y)).set_feature(MCF.FEATURE_WALL)
	manager.update_view(grid, Vector2.ZERO, 1.0, 32.0)
	var shadow := await pixels(manager)
	shadow.save_png("/tmp/isotope-lighting-shadow.png")
	var behind := Vector2i(8 * 32 + 16, 6 * 32 + 16)
	var dark := shadow.get_pixelv(behind).r
	for y in range(1, 12): grid.cell(Vector2i(7, y)).clear_feature()
	manager.update_view(grid, Vector2.ZERO, 1.0, 32.0)
	var clear := await pixels(manager)
	clear.save_png("/tmp/isotope-lighting-open.png")
	ck(clear.get_pixelv(behind).r > dark + 0.08, "wall shadow disappears after demolition")
	grid.cell(Vector2i(4, 6)).clear_feature()
	manager.update_view(grid, Vector2.ZERO, 1.0, 32.0)
	var unlit := await pixels(manager)
	ck(absf(unlit.get_pixel(144, 208).r - LightManager.AMBIENT.r) < 0.02, "destroyed lamp leaves readable dark ambient")
	var wanted: Dictionary = {}
	for i in 16:
		manager._request(wanted, "stress:%d" % i, Vector2(8, 8), 7.0, Color.WHITE, 0.008,
			Vector2.ZERO, 1.0, Vector2i(512, 512))
	var sixteen := await pixels(manager)
	for i in range(16, 80):
		manager._request(wanted, "stress:%d" % i, Vector2(8, 8), 7.0, Color.WHITE, 0.008,
			Vector2.ZERO, 1.0, Vector2i(512, 512))
	var eighty := await pixels(manager)
	eighty.save_png("/tmp/isotope-lighting-80-overlap.png")
	print("Light sample 16/80: ", sixteen.get_pixel(256,256), " / ", eighty.get_pixel(256,256))
	ck(manager.lights.size() == 80, "all 80 overlapping lights exist")
	ck(eighty.get_pixel(256, 256).r > sixteen.get_pixel(256, 256).r + 0.25,
		"lights beyond the first sixteen contribute to the rendered image")
	manager.free()
	print("Lighting renderer: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
