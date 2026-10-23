extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.cheats_enabled = true
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.roster = Roster.default_duel(false)
	for slot: Roster.Slot in GameConfig.roster.slots: slot.cheats_allowed = true
	var map := MapData.blank_arena(24, 20)
	map.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 17), "light_infantry", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	var console = load("res://src/cheats/CheatConsole.gd").open(main)
	main._cheat_console = console
	load("res://src/ui/ManualWindow.gd").toggle(main)
	for i in 5: await process_frame
	var manual: Node = get_nodes_in_group("manual_window")[0]
	main._chat_panel.show()
	for panel: Control in [console.window, manual.window, main._chat_panel]:
		var before: Vector2 = main.pan
		var zoom: float = main.zoom
		var gesture := InputEventPanGesture.new()
		gesture.position = panel.get_global_rect().get_center()
		gesture.delta = Vector2(1, 3)
		main._unhandled_input(gesture)
		ck(main.pan == before, "trackpad scroll stays in " + panel.name)
		var pinch := InputEventMagnifyGesture.new()
		pinch.position = gesture.position
		pinch.factor = 1.5
		main._unhandled_input(pinch)
		ck(main.zoom == zoom, "trackpad pinch stays in " + panel.name)
	console.submit("units #1 status")
	ck(console.output.get_parsed_text().contains("Entire board"), "status table contains both scopes")
	ck(not console.output.get_parsed_text().contains("Type | Alive"), "status is a native table, not pipe-separated text")
	console.submit("coords on")
	ck(main._cheat_coords, "coordinates enabled")
	await event_editor(console)
	console.submit("ids on")
	var overlay := CheatOverlay.new()
	overlay.main = main
	root.add_child(overlay)
	var initial := overlay.label_box(Vector2i(3, 3), "U123").size
	for zoom in [0.35, 1.0, 3.0]:
		main.zoom = zoom
		ck(overlay.label_box(Vector2i(3, 3), "U123").size == initial, "ID label size independent of zoom")
	var body: UnitInstance = main.state.get_unit(0)
	main._walk_cells[body.id] = Vector2i(3, 4)
	ck(overlay.labels().has(Vector2i(3, 4)), "living IDs follow the walking sprite")
	main.resolver._kill(body)
	main.state.grid.move_occupant(body.coord, Vector2i(4, 3))
	main._walk_cells[body.id] = Vector2i(3, 3)
	ck(overlay.labels().has(Vector2i(4, 3)) and not overlay.labels().has(Vector2i(3, 3)), "old animation position cannot pin corpse ID")
	body.corpse_carrier_id = 1
	main._walk_cells[1] = Vector2i(18, 17)
	ck(overlay.labels().get(Vector2i(18, 17), []).has("U0-"), "carried corpse ID follows its walking carrier")
	overlay.free()
	manual.free()
	await flight(main)
	main.free()
	await process_frame
	# Repeated battles must not leave accent callbacks targeting freed controls.
	var ui := root.get_node("Ui")
	var count: int = ui.accent_changed.get_connections().size()
	for i in 3:
		var rect = load("res://src/ui/AccentRect.gd").new()
		root.add_child(rect)
		ui.accent_changed.emit()
		ck(rect.color == ui.accent_color(), "live accent follows theme")
		rect.free()
		ui.accent_changed.emit()
	ck(ui.accent_changed.get_connections().size() == count, "freed accent controls leave no signal connections")

func event_editor(console: Node) -> void:
	console.submit("event spawn gas (5,6) (7,8) 4")
	for i in 3: await process_frame
	var clouds: Array = console.main.resolver.random_events.clouds
	ck(clouds.size() == 1 and clouds[0].x == 5 and clouds[0].y == 6 and clouds[0].w == 3 and clouds[0].h == 3, "typed event corners place the exact inclusive rectangle")
	console.submit("world smoke add (10,10) (12,12) 4")
	var smoke: Dictionary = console.main.resolver.random_events.smoke[0]
	console.submit("event edit smoke:%d {x:10,y:10,w:5,h:4}" % smoke.uid)
	smoke = console.main.resolver.random_events.smoke[0]
	ck(smoke.w == 5 and smoke.h == 4, "smoke area edits use the same coordinate convention")
	console.main.resolver._ignite(console.main.state.grid.cell(Vector2i(18, 12)), console.main.resolver.EVENT_FIRE_OWNER)
	console.submit("event remove fire")
	ck(not console.main.state.grid.cell(Vector2i(18, 12)).on_fire, "aggregate fire can be removed through commands")

func flight(main: Node) -> void:
	var fp = load("res://scenes/main/FirstPerson.gd").new(main, Vector2i(5, 5))
	fp.grid = Grid.new(24, 20)
	fp._vis_img = Image.create(24, 20, false, Image.FORMAT_R8)
	fp._vis_img.fill(Color.WHITE)
	fp.noclip = true
	fp.pos = Vector3(5, 100, 5)
	fp._fly(0.1, Vector3.UP, false)
	ck(fp.pos.y > 100, "noclip ascends above all ceilings")
	fp.pos.y = -100
	fp._fly(0.1, Vector3.DOWN, false)
	ck(fp.pos.y < -100, "noclip descends below ground and space floor")
	var before: Vector3 = fp.pos
	fp.drift = Vector3.ONE * 20
	fp._fly(0.1, Vector3.ZERO, false)
	ck(fp.pos == before and fp.drift == Vector3.ZERO, "noclip has no drift or gravity")
	fp.grid.cell(Vector2i(6, 5)).set_feature(MCF.FEATURE_WALL)
	ck(not fp._blocked(Vector3(6.5, -100, 5.5)), "known wall does not block flight at any height")
	fp._vis_img.set_pixel(6, 5, Color.BLACK)
	ck(fp._blocked(Vector3(6.5, 100, 5.5)), "fog blocks flight at every height")
	fp.pos = Vector3(5.5, 10, 5.5)
	fp._fly(1.0, Vector3.RIGHT, true)
	ck(fp.pos.x < 6, "fast flight cannot jump over unknown cell")
	var keys := root.get_node("Keybinds")
	for action: String in ["fp_forward", "fp_back", "fp_left", "fp_right", "fp_run", "fp_up", "fp_down", "fp_noclip", "fp_leave"]:
		ck(keys.definition(action).get("section") == "fp", "first-person settings list " + action)
	var diagram = load("res://src/ui/KeyboardDiagram.gd").new()
	diagram.section = "fp"
	root.add_child(diagram)
	ck(diagram._state(KEY_SHIFT) == 1, "standalone Shift binding is highlighted")
	ck(diagram.tooltip_for(KEY_SHIFT, "Shift").contains("Run / fly faster"), "Shift tooltip explains its standalone binding")
	diagram.section = "editor"
	ck(diagram._state(KEY_SHIFT) == 2, "modifier chords retain their combination highlight")
	ck(diagram.tooltip_for(KEY_SHIFT, "Shift").contains("Redo"), "modifier tooltip still lists its chords")
	diagram.free()
	fp.free()
