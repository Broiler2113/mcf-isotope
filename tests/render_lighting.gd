extends SceneTree

## Requires an actual Compatibility renderer: xvfb-run -a godot --script tests/render_lighting.gd
var failures: Array[String] = []
func ck(ok: bool, label: String) -> void:
	print(("ok " if ok else "FAIL ") + label)
	if not ok: failures.append(label)
func _initialize() -> void: run.call_deferred()

## Light-map value at the centre of cell c (or at fraction f inside it).
func at(manager: LightManager, c: Vector2i, f := Vector2(0.5, 0.5)) -> float:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	var img := manager._vp.get_texture().get_image()
	var k := float(img.get_width()) / 16.0
	return img.get_pixel(int((c.x + f.x) * k), int((c.y + f.y) * k)).r

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
	var face := await at(manager, Vector2i(7, 6), Vector2(0.15, 0.5))
	var far_half := await at(manager, Vector2i(7, 6), Vector2(0.85, 0.5))
	var behind := await at(manager, Vector2i(8, 6))
	var source := await at(manager, Vector2i(4, 6))
	print("lit %.2f face %.2f behind %.2f source %.2f ambient %.2f" % [lit, face, behind, source, manager.ambient.r])
	ck(lit > behind + 0.3, "the wall shadows the far side")
	ck(face > behind + 0.2, "the wall's face towards the lamp is lit")
	ck(far_half > behind + 0.2, "the whole wall tile is lit, no dark middle (0.11 playtest)")
	var along := await at(manager, Vector2i(7, 4), Vector2(0.85, 0.5))
	ck(along > behind + 0.15, "a wall tile further along the wall is lit through, not shaded by its neighbours")
	ck(source >= lit - 0.05, "the lamp's own tile is lit, not dark")
	for y in range(1, 12): grid.cell(Vector2i(7, y)).clear_feature()
	refresh(manager, grid)
	ck(await at(manager, Vector2i(8, 6)) > behind + 0.15, "the shadow goes with the wall")
	grid.cell(Vector2i(4, 6)).clear_feature()
	refresh(manager, grid)
	ck(absf(await at(manager, Vector2i(5, 6)) - manager.ambient.r) < 0.03, "a destroyed lamp leaves the ambient level")
	# A wall lamp hangs on one face (0.11): it lights its own side and never the other.
	for y in range(1, 12): grid.cell(Vector2i(7, y)).set_feature(MCF.FEATURE_WALL)
	grid.cell(Vector2i(7, 6)).lamps = [["wall_lamp", 1, 3, 0]]
	refresh(manager, grid)
	var front := await at(manager, Vector2i(6, 6))
	var back := await at(manager, Vector2i(8, 6))
	print("wall lamp: front %.2f back %.2f" % [front, back])
	ck(front > manager.ambient.r + 0.3, "a wall lamp lights the floor in front of it")
	ck(absf(back - manager.ambient.r) < 0.03, "and nothing at all behind its wall")
	host.free()
	print("Lighting renderer: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
