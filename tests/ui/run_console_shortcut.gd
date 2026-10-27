extends "res://tests/SuiteBase.gd"

## Exercise _input -> focused GUI -> _unhandled_key_input, rather than calling
## _handle_shortcut directly: an inherited handler can otherwise be bypassed.
var main: Node
var keys: Node
const SETTINGS := "user://console-shortcut-test.cfg"

func run() -> void:
	keys = root.get_node("Keybinds")
	keys.reset_defaults(SETTINGS)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.cheats_enabled = true
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	var map := MapData.blank_arena(24, 18)
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(21, 15), "light_infantry", 1)
	MapHandoff.pending = map
	main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 4: await process_frame
	main.set_process(false)
	root.gui_release_focus()
	press(KEY_F2)
	ck(console_open(), "F2 opens the console through the real viewport input path")
	ck(get_nodes_in_group("manual_window").is_empty(), "battle F2 does not fall through to the editor Manual shortcut")
	await close_windows()

	# Chat retains text focus after interacting with its panel.
	main._comms_tabs.current_tab = 1
	await process_frame
	main._chat_input.text = "unsent message"
	main._chat_input.grab_focus()
	ck(main._chat_input.has_focus(), "fixture focuses the actual chat input")
	press(KEY_F2)
	ck(console_open(), "F2 opens while chat owns keyboard focus")
	ck(main._chat_input.text == "unsent message", "opening the console preserves the chat draft")
	if console_open():
		ck(main._cheat_console.input.has_focus(), "opening focuses the command field")
		var repeated: InputEventKey = keys.key_event(KEY_F2)
		repeated.pressed = true
		repeated.echo = true
		root.push_input(repeated)
		ck(console_open(), "key repeat cannot immediately close the console")
		press(KEY_F2)
		ck(not console_open(), "a second F2 closes from the command field")
	await close_windows()

	# A HUD widget that consumes keys must not swallow a global console shortcut.
	var focus := Button.new()
	focus.text = "Focus fixture"
	focus.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey: focus.accept_event())
	main._ui_layer.add_child(focus)
	focus.grab_focus()
	press(KEY_F2)
	ck(console_open(), "F2 runs before a focused HUD control consumes the key")
	await close_windows()
	focus.free()

	# Remapping remains authoritative; typing printable rebound keys is still safe.
	ck(keys.rebind("game_cheats", keys.key_event(KEY_F3), SETTINGS).is_empty(), "console shortcut can be rebound")
	main._chat_input.grab_focus()
	press(KEY_F3)
	ck(console_open(), "rebound function key also opens from chat")
	await close_windows()
	ck(keys.rebind("game_cheats", keys.key_event(KEY_QUOTELEFT), SETTINGS).is_empty(), "console may use an unused printable key")
	main._chat_input.grab_focus()
	var letter: InputEventKey = keys.key_event(KEY_QUOTELEFT)
	letter.pressed = true
	letter.unicode = 96
	root.push_input(letter)
	ck(not console_open() and main._chat_input.text.contains("`"), "a printable binding remains ordinary text while typing")
	keys.reset_defaults(SETTINGS)

	# Master enable, replay, spectator, first-person and modal restrictions hold.
	root.gui_release_focus()
	main.state.cheats_enabled = false
	press(KEY_F2)
	ck(console_open(), "F2 opens the console with cheats disabled")
	main._cheat_console.submit("units")
	ck(main._cheat_console.output.get_parsed_text().contains("disabled"), "commands refuse while cheats are disabled")
	await close_windows()
	main.state.cheats_enabled = true
	main._spectator = true
	press(KEY_F2)
	ck(not console_open(), "spectators cannot open the console")
	main._spectator = false
	main.replay = ReplayPlayer.new({})
	press(KEY_F2)
	ck(not console_open(), "replays cannot open the console")
	main.replay = null
	var modal := Control.new()
	modal.add_to_group("shortcut_modal")
	main.add_child(modal)
	press(KEY_F2)
	ck(not console_open(), "modal dialogs retain keyboard ownership")
	modal.free()
	var fp: Node = load("res://scenes/main/FirstPerson.gd").new(main, Vector2i(2, 2))
	main._fp = fp
	press(KEY_F2)
	ck(not console_open(), "first-person mode cannot open the console")
	main._fp = null
	fp.free()
	await close_windows()

	# The console is accessible during AI turns without borrowing the AI's identity.
	main.state.roster.slots[1].kind = Roster.SlotKind.AI
	main._make_side(1)
	main.state.turns.round_order.assign([0, 1])
	main.state.turns.active_index = 1
	main._last_viewer = 0
	press(KEY_F2)
	ck(console_open(), "local human can open the console during an AI turn")
	if console_open(): ck(main._cheat_console.caller() == 0, "AI-turn console retains the human caller")
	await close_windows()
	main.free()
	await process_frame
	keys.load_bindings()
	DirAccess.remove_absolute(SETTINGS)

func press(code: int) -> void:
	var event: InputEventKey = keys.key_event(code)
	event.physical_keycode = event.keycode
	event.pressed = true
	root.push_input(event)
	var release: InputEventKey = event.duplicate()
	release.pressed = false
	root.push_input(release)

func console_open() -> bool:
	return is_instance_valid(main._cheat_console) and not main._cheat_console.is_queued_for_deletion()

func close_windows() -> void:
	for node: Node in get_nodes_in_group("cheat_console") + get_nodes_in_group("manual_window"):
		node.queue_free()
	await process_frame
	root.gui_release_focus()
