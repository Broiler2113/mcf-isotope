extends SceneTree

var fails: Array[String] = []
func ck(ok: bool, why: String) -> void:
	print(("ok   " if ok else "FAIL ") + why)
	if not ok: fails.append(why)
func _initialize() -> void: run.call_deferred()
func frames(n := 3) -> void:
	for i in n: await process_frame
func find_text(node: Node, value: String) -> Node:
	if (node is Label or node is Button) and node.text == value: return node
	for child in node.get_children():
		var got := find_text(child, value)
		if got != null: return got
	return null
func drag(control: Control, from: Vector2, to: Vector2) -> void:
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = true
	button.global_position = from
	control.gui_input.emit(button)
	var motion := InputEventMouseMotion.new()
	motion.global_position = to
	motion.relative = to - from
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	control.gui_input.emit(motion)
	button.pressed = false
	button.global_position = to
	control.gui_input.emit(button)
func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-" + name + ".png")
func run() -> void:
	root.size = Vector2i(1280, 800)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.fog_mode = MCF.Fog.OFF
	var m := MapData.blank_arena(26, 20)
	m.time_of_day = "night"
	m.set_cell(Vector2i(9, 8), 0, Furniture.height_of("streetlight"), false, "streetlight")
	m.set_spawn(Vector2i(3, 4), "engineer", 0)
	m.set_spawn(Vector2i(22, 17), "light_infantry", 1)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await frames()
	var tools_button := find_text(main, "Tools") as Button
	var draw_button := find_text(main, "Drawing") as Button
	ck(tools_button != null and draw_button != null and tools_button.global_position.x < 200 and draw_button.global_position.x < 250, "Tools and Drawing have separate top-left buttons")
	tools_button.pressed.emit()
	draw_button.pressed.emit()
	await frames()
	ck(find_text(main, "Ruler").is_visible_in_tree() and find_text(main, "Undo drawing").is_visible_in_tree(), "both buttons open their corresponding panels")
	await capture("battle-panels")
	if DisplayServer.get_name() != "headless":
		ck(not main._tiles._chunks.is_empty(), "time-of-day changes leave the rendered terrain textures alive")
	var settings = load("res://src/ui/SettingsWindow.gd").open(main)
	await frames()
	var label := find_text(settings, "Settings")
	var header := label.get_parent().get_parent().get_parent() as Control
	var panel := header.get_parent().get_parent() as Control
	var old_pos := panel.global_position
	drag(header, old_pos + Vector2(80, 10), old_pos + Vector2(35, 35))
	await frames()
	ck(panel.global_position != old_pos, "a centered settings popup can be dragged and stays where released")
	var grip := header.find_child("ResizeGrip", true, false) as Control
	var old_size := panel.size
	drag(grip, grip.global_position, grip.global_position - Vector2(90, 70))
	await frames()
	ck(panel.size.x < old_size.x and panel.size.y < old_size.y, "the settings popup can shrink with scrolling content")
	await capture("settings-resized")
	settings.free()
	root.get_node("Ui").dynamic_lighting = true
	main._sync_lighting()
	main._toggle_before()
	await frames()
	ck(main._lighting != null and main._lighting.visible and main._lighting.z_index > main._before_layer.z_index and not main._lod.visible, "Before keeps lighting above its board and hides all live terrain and debris layers")
	await capture("before-night")
	var night: Color = main._lighting.ambient
	main.state.time_of_day = "day"
	main._sync_lighting()
	await frames()
	ck(main._lighting.ambient.r > night.r + 0.3 and main._before_tiles.time_of_day == "day", "daylight visibly changes ambient light and updates the opening-board streetlight sprites")
	await capture("before-day")
	main._toggle_before()
	await frames()
	ck(main._lod.visible, "After restores the live board")
	main.free()
	await frames()
	MapHandoff.pending = m
	var placement = load("res://scenes/Placement.tscn").instantiate()
	root.add_child(placement)
	await frames()
	ck(is_equal_approx(placement._panel.size.x, 264.0) and placement._panel.position.y == 0.0 and is_equal_approx(placement._panel.size.y, 800.0), "deployment uses the same sidebar dimensions and edge alignment as battle")
	await capture("deployment-panel")
	placement.free()
	await frames()
	var editor = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(editor)
	await frames()
	editor.create_map("", "town", Vector2i(30, 24))
	editor._select_brush("dining_table")
	editor._begin()
	editor._paint_cells([Vector2i(8, 8)], false)
	editor._commit()
	var existing: Array = editor.map.items.filter(func(it: Array) -> bool: return SmallItems.cell_of(it) == Vector2i(8, 8)).duplicate(true)
	# A hand-placed prop must also survive extending the table.
	existing.append(["radio", 8.2, 8.8, 0.0])
	editor.map.items.append(existing[-1])
	editor._begin()
	editor._paint_cells([Vector2i(9, 8)], false)
	editor._commit()
	ck(editor.map.items.filter(func(it: Array) -> bool: return SmallItems.cell_of(it) == Vector2i(8, 8)) == existing, "extending a table preserves its existing props without duplicates")
	editor._select_brush("item:mug")
	var at: Vector2 = editor.pan + Vector2(8.5, 8.5) * editor.cell_size()
	editor._press(Vector2i(8, 8), false, at)
	var motion := InputEventMouseMotion.new()
	motion.position = at + Vector2(2, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	editor._unhandled_input(motion)
	editor._release(Vector2i(8, 8))
	ck(editor.map.get_feature(Vector2i(8, 8)) == "dining_table", "placing an item with a small mouse movement preserves the table")
	if DisplayServer.get_name() != "headless":
		editor.create_map("", "town", Vector2i(50, 38), {"style": MapGen.Style.TOWN, "size": 2, "seed": 7, "time": "evening"})
		await frames(6)
		await capture("town-layout")
		editor.create_map("", "station", Vector2i(50, 38), {"style": MapGen.Style.STATION, "size": 2, "seed": 4})
		await frames(6)
		await capture("station-layout")
	editor.free()
	await frames()
	print("remaining UI: %d failure(s)" % fails.size())
	quit(0 if fails.is_empty() else 1)
