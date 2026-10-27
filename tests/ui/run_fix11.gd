extends "res://tests/SuiteBase.gd"

class CountingAI extends PlayerController:
	var decisions := 0
	func begin_turn(_state: GameState) -> void: decisions += 1

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
	var console: Node = load("res://src/cheats/CheatConsole.gd").open(main)
	main._cheat_console = console
	console.submit("checkpoint baseline")
	ck(console.output.get_parsed_text().contains("saved"), "checkpoint command saves complete scenario")
	var original: int = main.state.digest_hash()
	console.submit("unit stat change U0 armor (12)")
	await process_frame
	ck(main.state.get_unit(0).armor() == 12, "new stat command works through live UI")
	console.submit("game step back")
	ck(main.state.digest_hash() == original and main._history_hold, "host rewind restores and pauses the match")
	console.submit("game step forward")
	ck(main.state.get_unit(0).armor() == 12, "host forward survives checkpoint marker")
	console.submit("spawn unit engineer #1 (10,10)")
	await process_frame
	ck(main.state.all_units().size() == 3, "scenario has an added unit to recover from")
	console.submit("undo")
	ck(main.state.all_units().size() == 2, "console undo takes back the last command")
	console.submit("redo")
	ck(main.state.all_units().size() == 3, "console redo puts the command back")
	main._victory_overlay = Control.new()
	main._ui_layer.add_child(main._victory_overlay)
	main._match_over = true
	console.submit("checkpoint restore baseline")
	ck(main.state.digest_hash() == original and not main._match_over, "checkpoint recovers a completed test match")
	ck(not main.resolver.can_undo(), "checkpoint restoration does not create ordinary Undo")
	ck(main.state.all_units().size() == 2 and main._victory_overlay == null, "restore removes mistaken spawns and the completed-match overlay")
	console.submit("ids on")
	console.submit("coords on")
	var overlay := CheatOverlay.new()
	overlay.main = main
	root.add_child(overlay)
	for zoom in [0.3, 1.0, 3.0]:
		main.zoom = zoom
		var tile := Rect2(main._cell_screen(Vector2i(3, 3)), Vector2.ONE * main.CELL * zoom)
		ck(tile.encloses(overlay.coordinate_box(Vector2i(3, 3))), "coordinate labels stay within their own cell")
	overlay.free()
	console.free()
	main._cheat_console = null
	main._escape_pressed()
	var menu: Node = main._battle_menu
	ck(menu != null, "Escape opens battle menu")
	ck(menu.buttons.map(func(button: Button): return button.text) == ["Resume", "Settings", "Save Game", "Save Replay", "Return to Menu"], "battle menu starts with Resume and ends with Return to Menu")
	for button: Button in main._hud_window.find_children("*", "Button", true, false):
		ck(button.text not in ["Return to Menu", "Save Game", "Save Replay", "Settings"], "battle menu actions removed from right panel")
	var replay_steps: int = main.recorder.steps.size()
	main._do_save_replay("fix11-ui")
	ck(main.recorder != null and main.recorder.steps.size() == replay_steps, "saving a replay keeps recording")
	menu.free()
	var ui := root.get_node("Ui")
	var old: int = ui.fp_render_distance
	ui.set_fp_render_distance(64)
	ui._load_settings()
	ck(ui.fp_render_distance == 64, "render distance persists")
	var fp: Node = load("res://scenes/main/FirstPerson.gd").new(main, Vector2i(3, 3))
	ck(fp.view_distance() == 64, "first-person streaming uses chosen distance")
	fp.free()
	ui.set_fp_render_distance(old)
	await ai_timer_after_restore(main)
	await network_history(main)
	var saved: Dictionary = main._save_payload()
	var record: Dictionary = main.recorder.to_dict()
	var recorded_hash: int = main.state.digest_hash()
	main.free()
	await process_frame
	SaveHandoff.pending_save = saved
	var loaded: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(loaded)
	for i in 4: await process_frame
	ck(loaded._recording_resumed and loaded.recorder.steps.back().i.t == "checkpoint", "manual load preserves history and records the resumed state")
	var result: String = loaded._history_command(CheatCommands.parse("checkpoint restore baseline", loaded.state, 0), 0)
	ck(result.contains("Restored checkpoint"), "named checkpoints remain available after manual load")
	loaded.free()
	await process_frame
	SaveHandoff.pending_replay = record
	var replay_main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(replay_main)
	for i in 4: await process_frame
	replay_main._set_replay_timelapse(true)
	replay_main._replay_speed = 64
	replay_main._replay_toggle()
	var deadline := Time.get_ticks_msec() + 4000
	while replay_main.replay.has_next() and Time.get_ticks_msec() < deadline: await process_frame
	ck(not replay_main.replay.has_next() and not replay_main._animating, "timelapse finishes without animation waits")
	ck(replay_main.state.digest_hash() == recorded_hash, "checkpoint markers play back to the canonical board")
	replay_main.free()
	await process_frame

func network_history(main: Node) -> void:
	var guest_state := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(main.state))))
	var guest := NetGame.new(guest_state, GameActionResolver.new(guest_state), false, 1)
	main.networked = true
	main.net = NetGame.new(main.state, main.resolver, true, 0)
	main.net.recorder = main.recorder
	main.net.outgoing.connect(func(message: Dictionary):
		var wire: Dictionary = JSON.parse_string(JSON.stringify(message))
		wire._from = 1
		guest.receive(wire))
	main.state.roster.slots[1].peer_id = 77
	main.state.roster.slots[1].cheats_allowed = false
	var parsed := CheatCommands.parse("checkpoint restore baseline", main.state, 0)
	main._history_command(parsed, 0)
	ck(main.state.roster.slots[1].peer_id == 77 and not main.state.roster.slots[1].cheats_allowed, "restore preserves current transport identity and permissions")
	ck(guest.state.digest_hash() == main.state.digest_hash(), "host restore synchronizes authoritative board")
	ck(guest.resolver != null and guest.history_restored, "guest uses restored rules and resolver")
	var current: int = main.state.digest_hash()
	main.net.receive({"k": NetGame.K_INTENT, "_from": 77, "epoch": 0, "i": IntentCodec.encode(CheatIntent.new("unit_ap", {"unit": 0, "value": 9}, 1))})
	ck(main.state.digest_hash() == current, "actions sent before a restore cannot mutate the restored board")
	guest.receive({"k": NetGame.K_ACTION, "_from": 1, "epoch": 0, "i": IntentCodec.encode(CheatIntent.new("unit_ap", {"unit": 0, "value": 9}, 0)), "r": []})
	ck(guest.state.digest_hash() == current, "old authoritative actions cannot cross a restore")
	var digest := guest.state.digest_hash()
	guest.receive({"k": NetGame.K_STATE, "_from": 77, "s": {}, "history": true})
	ck(guest.state.digest_hash() == digest, "guest rejects a forged restore")
	for connection: Dictionary in main.net.outgoing.get_connections(): main.net.outgoing.disconnect(connection.callable)
	main.net = guest
	var denial: String = main._history_command(parsed, 1)
	ck(denial.contains("Only the host"), "guest cannot invoke host history")
	main.net = null
	main.networked = false

func ai_timer_after_restore(main: Node) -> void:
	main.state.roster.slots[1].kind = Roster.SlotKind.AI
	main.state.turns.active_index = main.state.turns.round_order.find(1)
	main._make_side(1)
	main._history_command(CheatCommands.parse("checkpoint ai-timer", main.state, 0), 0)
	main._history_hold = false
	main._paused = false
	main._queue_ai_step(main.controllers[1])
	main._history_command(CheatCommands.parse("checkpoint restore ai-timer", main.state, 0), 0)
	var counter := CountingAI.new(1)
	main.controllers[1] = counter
	main._toggle_pause()
	await create_timer(0.7).timeout
	ck(counter.decisions == 1, "Resume schedules one current AI decision and discards the pre-restore timer")
	main._history_command(CheatCommands.parse("checkpoint restore baseline", main.state, 0), 0)
