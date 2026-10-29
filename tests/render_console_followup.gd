extends "res://tests/SuiteBase.gd"

func run() -> void:
	if DisplayServer.get_name() == "headless": ck(false, "requires rendered display"); return
	root.size = Vector2i(1280, 900)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.cheats_enabled = true
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.roster = Roster.default_duel(false)
	for slot: Roster.Slot in GameConfig.roster.slots: slot.cheats_allowed = true
	var map := MapData.blank_arena(30, 24)
	map.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	map.set_spawn(Vector2i(21, 17), "engineer", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	main._kill_pan_tween()
	main.pan = Vector2(40, 65)
	main.zoom = 0.9
	main.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	var without := root.get_texture().get_image()
	main._cheat_ids = "all"
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	var with_ids := root.get_texture().get_image()
	var at: Vector2 = main._cell_screen(Vector2i(3, 3))
	var changed := 0
	for y in range(int(at.y), int(at.y + main.CELL * main.zoom)):
		for x in range(int(at.x), int(at.x + main.CELL * main.zoom)):
			if with_ids.get_pixel(x, y) != without.get_pixel(x, y): changed += 1
	ck(changed > 50, "IDs are visibly drawn above the battlefield layers")
	with_ids.save_png("/tmp/isotope-0133-ids.png")
	var console = load("res://src/cheats/CheatConsole.gd").open(main)
	main._cheat_console = console
	for i in 4: await process_frame
	console.window.position = Vector2(400, 100)
	console.window.size = Vector2(650, 500)
	console.submit("units all status")
	console.input.text = "spawn unit en"
	console._text_changed(console.input.text)
	for i in 3: await process_frame
	var before: Vector2 = console.window.position
	await drag(console.window.title_bar, Vector2(-65, 40))
	ck(console.window.position.distance_to(before + Vector2(-65, 40)) < 3, "console title bar drags by pointer motion: %s to %s" % [before, console.window.position])
	var before_size: Vector2 = console.window.size
	await drag(console.window.grip, Vector2(70, 45))
	ck(console.window.size.x > before_size.x + 50 and console.window.size.y > before_size.y + 25, "console resize grip changes dimensions: %s to %s" % [before_size, console.window.size])
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-0133-console.png")
	console.submit("clear")
	console.submit("units all")
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-fix10-unit-table.png")
	console.input.release_focus()
	load("res://src/ui/ManualWindow.gd").toggle(main)
	for i in 4: await process_frame
	var manual: Node = get_nodes_in_group("manual_window")[0]
	manual.window.position = Vector2(45, 45)
	manual.window.size = Vector2(720, 550)
	for i in manual._sections.size():
		if manual._sections[i][0] == "Cheats": manual._show(i)
	for i in 3: await process_frame
	before = manual.window.position
	await drag(manual.window.title_bar, Vector2(40, 25))
	ck(manual.window.position.distance_to(before + Vector2(40, 25)) < 3, "manual title bar drags")
	before_size = manual.window.size
	await drag(manual.window.grip, Vector2(55, 35))
	ck(manual.window.size.x > before_size.x + 35 and manual.window.size.y > before_size.y + 20, "manual resize grip changes dimensions")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-0133-manual.png")
	manual.queue_free()
	await process_frame
	console.submit("event spawn gas (12,10) (14,12) 3")
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-fix11-event-command.png")
	var settings: Node = load("res://src/ui/SettingsWindow.gd").open(main)
	settings._tabs.current_tab = settings.TAB_KEYS
	settings._key_sections.current_tab = 2
	for i in 4: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/isotope-fix10-fp-controls.png")
	ck(settings._key_sections.get_current_tab_control().name == "First-person controls", "first-person controls tab renders alongside editor shortcuts")
	main.free()
	await process_frame

func drag(control: Control, delta: Vector2) -> void:
	var from := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = from
	motion.global_position = from
	root.push_input(motion, true)
	await process_frame
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = from
	click.global_position = from
	root.push_input(click, true)
	await process_frame
	motion = InputEventMouseMotion.new()
	motion.position = from + delta
	motion.global_position = motion.position
	motion.relative = delta
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	await process_frame
	click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = false
	click.position = from + delta
	click.global_position = click.position
	root.push_input(click, true)
	await process_frame
