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
	m.set_spawn(Vector2i(4, 4), "shield_bearer", 0)
	m.set_cell(Vector2i(5, 4), 0, 2.0, false, MCF.FEATURE_GLASS)
	m.set_spawn(Vector2i(22, 17), "light_infantry", 1)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await frames()
	var tools_button := find_text(main, "Tools") as Button
	var draw_button := find_text(main, "Drawing") as Button
	ck(tools_button == null and draw_button != null and draw_button.global_position.x < 200, "Drawing is the only top-left tool button")
	for text in ["Multi-Select", "Ruler", "Heightmap", "Camera"]:
		var control := find_text(main, text) as Control
		ck(control != null and control.is_visible_in_tree() and main._hud_window.is_ancestor_of(control), text + " is back in the right sidebar")
	ck(not find_text(main, "Undo drawing").is_visible_in_tree(), "Drawing starts closed")
	draw_button.pressed.emit()
	await frames()
	ck(find_text(main, "Undo drawing").is_visible_in_tree(), "Drawing button opens its panel")
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
	ck(panel.global_position == old_pos, "settings keeps its original centered layout when the header is dragged")
	ck(header.find_child("ResizeGrip", true, false) == null, "settings no longer receives a universal resize handle")
	ck(main._hud_window.find_child("ResizeGrip", true, false) == null, "battle sidebar receives no universal resize handle")
	var log_position: Vector2 = main._log_panel.global_position
	var log_header := main._log_panel.get_child(0).get_child(0) as Control
	drag(log_header, log_position + Vector2(40, 10), log_position + Vector2(70, -20))
	await frames()
	ck(main._log_panel.global_position != log_position, "the battle log retains its original explicit dragging")
	await capture("settings-fixed")
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
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	var shield: UnitInstance = main.state.grid.cell(Vector2i(4, 4)).occupant
	main._select(shield)
	main._enter_push()
	ck(main.item_cells.has(Vector2i(5, 4)), "Shield Push highlights adjacent glass in the battle UI")
	main._handle_click(Vector2i(5, 4))
	await frames()
	ck(main.state.grid.cell(Vector2i(5, 4)).feature_id == "", "clicking the highlighted pane strikes and breaks it")
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
	for env in ["bunker", "station", "asteroid", "town", "field"]:
		editor.set_preset(env)
		var map_menu: PopupMenu = editor._menus["Map"]
		var outdoor: bool = env in ["town", "field"]
		for i in map_menu.item_count:
			if MapData.TIME_NAMES.has(map_menu.get_item_text(i)):
				ck(map_menu.is_item_disabled(i) != outdoor, env + " time menu availability")
		var before: String = editor.map.time_of_day
		editor.set_time_of_day("day")
		ck(editor.map.time_of_day == ("day" if outdoor else before), env + " time selection guard")
	editor.set_preset("town")
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
