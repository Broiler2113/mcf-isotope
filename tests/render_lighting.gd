extends SceneTree

## Requires an actual Compatibility renderer: xvfb-run -a godot --script tests/render_lighting.gd
var failures: Array[String] = []
func ck(ok: bool, label: String) -> void:
	print(("ok " if ok else "FAIL ") + label)
	if not ok: failures.append(label)
func _initialize() -> void: run.call_deferred()

## Light-map value at the centre of cell c.
func at(manager: LightManager, c: Vector2i) -> float:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	var img := manager._vp.get_texture().get_image()
	var k := float(img.get_width()) / 16.0
	return img.get_pixel(int((c.x + 0.5) * k), int((c.y + 0.5) * k)).r

func refresh(manager: LightManager, grid: Grid) -> void:
	manager.update_view(grid, Vector2.ZERO, 1.0, Vector2.ZERO, 32.0, "station", {}, false, null, null, 0.8)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("This test needs a display: xvfb-run -a godot --script tests/render_lighting.gd")
		quit(2)
		return
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(512, 512)
	var host := Node2D.new()
	root.add_child(host)
	var manager := LightManager.new()
	host.add_child(manager)
	var grid := Grid.new(16, 16)
	grid.cell(Vector2i(4, 6)).set_feature("lamp")
	for y in range(1, 12): grid.cell(Vector2i(7, y)).set_feature(MCF.FEATURE_WALL)
	refresh(manager, grid)
	var lit := await at(manager, Vector2i(5, 6))
	var face := await at(manager, Vector2i(7, 6))
	var behind := await at(manager, Vector2i(8, 6))
	var source := await at(manager, Vector2i(4, 6))
	print("lit %.2f face %.2f behind %.2f source %.2f ambient %.2f" % [lit, face, behind, source, manager.ambient.r])
	ck(lit > behind + 0.3, "the wall shadows the far side")
	ck(face > behind + 0.2, "the wall tile facing the lamp is lit whole")
	ck(source >= lit - 0.05, "the lamp's own tile is lit, not dark")
	for y in range(1, 12): grid.cell(Vector2i(7, y)).clear_feature()
	refresh(manager, grid)
	ck(await at(manager, Vector2i(8, 6)) > behind + 0.15, "the shadow goes with the wall")
	grid.cell(Vector2i(4, 6)).clear_feature()
	refresh(manager, grid)
	ck(absf(await at(manager, Vector2i(5, 6)) - manager.ambient.r) < 0.03, "a destroyed lamp leaves the ambient level")
	host.free()
	print("Lighting renderer: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
