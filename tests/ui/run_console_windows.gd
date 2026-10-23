extends "res://tests/SuiteBase.gd"

class StepController extends PlayerController:
	var decisions := 0
	func begin_turn(state: GameState) -> void:
		decisions += 1
		if decisions == 1: intent_ready.emit(MoveIntent.new(1, state.get_unit(1).coord + Vector2i.LEFT))
		else: intent_ready.emit(EndTurnIntent.new(owner))

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.cheats_enabled = true
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.ai_speed = 64.0
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.roster.slots[0].cheats_allowed = true
	GameConfig.roster.slots[1].cheats_allowed = true
	var map := MapData.blank_arena(24, 20)
	map.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	map.set_spawn(Vector2i(21, 17), "light_infantry", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	var console = load("res://src/cheats/CheatConsole.gd").open(main)
	main._cheat_console = console
	await process_frame
	ck(not root.get_node("Keybinds").modal_open(), "console leaves battlefield interactive")
	ck(not console.hints.visible and console.options.is_empty(), "empty input hides hints")
	console._text_changed("s")
	ck(console.hints.visible and not console.options.is_empty(), "first letter shows suggestions")
	ck(not console.hints.get_item_text(0).contains("—"), "suggestions contain commands without explanations")
	console.submit("spawn unit engineer #1")
	ck(not console.tool.is_empty() and not console.input.has_focus(), "spawn releases typing focus for placement")
	click_cell(main, Vector2i(6, 6))
	await process_frame
	click_cell(main, Vector2i(7, 6))
	await process_frame
	ck(main.state.grid.cell(Vector2i(6, 6)).occupant != null and main.state.grid.cell(Vector2i(7, 6)).occupant != null, "repeated placement spawns at clicked cells")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	main._handle_shortcut(esc)
	ck(console.tool.is_empty() and not console.is_queued_for_deletion(), "Escape stops placement but keeps console")
	console.submit("inspect")
	click_cell(main, Vector2i(6, 6))
	ck(console.output.get_parsed_text().contains("engineer") and console.output.get_parsed_text().contains("Stats:"), "click inspection reports unit stats")
	console.cancel_tool()
	console.submit("ids on")
	ck(main._cheat_ids == "all", "ID display enabled")
	console.submit("event spawn gas (12,10) (14,12) 3")
	await process_frame
	ck(console.tool.is_empty(), "event commands do not arm a separate placement tool")
	ck(main.resolver.random_events.clouds.size() == 1, "event command starts an active cloud")
	load("res://src/ui/ManualWindow.gd").toggle(main)
	await process_frame
	ck(not root.get_node("Keybinds").modal_open(), "manual is nonmodal")
	var manual: Node = get_nodes_in_group("manual_window")[0]
	ck(manual.window.grip != null and console.window.grip != null, "both windows expose resize handles")
	manual.queue_free()
	await process_frame
	# One scheduled timer cannot escape a newly applied pause, and a step cannot chain.
	main.state.roster.slots[1].kind = Roster.SlotKind.AI
	main.state.turns.round_order.assign([0, 1])
	main.state.turns.active_index = 1
	var counter := StepController.new(1)
	counter.intent_ready.connect(main._on_intent_ready)
	main.controllers[1] = counter
	console.submit("ai pause #2")
	main._paused = false
	main._kick_if_ai()
	await create_timer(0.05).timeout
	ck(counter.decisions == 0, "paused AI cannot start a scheduled decision")
	console.submit("ai step #2")
	var deadline := Time.get_ticks_msec() + 5000
	while (counter.decisions == 0 or main._animating) and Time.get_ticks_msec() < deadline: await process_frame
	await create_timer(0.05).timeout
	ck(counter.decisions == 1 and main.state.cheat_ai_paused.has(1), "step performs exactly one action then remains paused")
	main._paused = true
	console.submit("ai resume #2")
	ck(not main.state.cheat_ai_paused.has(1), "resume restores AI scheduling")
	main.free()
	await process_frame
	await host_tick()

func click_cell(main: Node, cell: Vector2i) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = main._cell_screen(cell) + Vector2.ONE * main.CELL * main.zoom * 0.5
	main._cheat_console.board_input(click)

func host_tick() -> void:
	var lobby: Node = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(lobby)
	for i in 3: await process_frame
	lobby.roster.slots[0].cheats_allowed = false
	lobby._cheats_check.set_pressed_no_signal(false)
	lobby._cheats_check.button_pressed = true
	await process_frame
	ck(lobby.roster.slots[0].cheats_allowed, "enabling master cheats ticks host permission")
	lobby.free()
	await process_frame
