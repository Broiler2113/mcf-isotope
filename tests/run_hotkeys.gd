extends SceneTree

var failures: Array[String] = []
var checks := 0
var board: Node
var keys: Node
const TEMP_SETTINGS := "user://hotkeys-test.cfg"

func ck(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func key(code: int) -> InputEventKey:
	var event: InputEventKey = keys.key_event(code)
	event.pressed = true
	return event

func press(code: int) -> bool:
	return board._handle_shortcut(key(code))

func _run() -> void:
	keys = root.get_node("Keybinds")
	keys.reset_defaults(TEMP_SETTINGS)
	_bindings()
	await _battle()
	await _menus()
	await _extra_choices()
	await _undo_and_focus()
	await _replay()
	await _editor()
	await _settings()
	keys.load_bindings()
	DirAccess.remove_absolute(TEMP_SETTINGS)
	print("Hotkeys: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _bindings() -> void:
	for entry: Dictionary in keys.DEFINITIONS:
		ck(InputMap.has_action(entry.id), "registered " + entry.id)
		for code: int in keys.codes(entry.id):
			ck(keys.conflicts(entry.id, code).is_empty(), "default has no simultaneous conflict: " + entry.id)
	ck(not keys.matches(key(KEY_MASK_CTRL | KEY_M), "action_move"), "plain action ignores Ctrl chord")
	ck(not keys.rebind("action_move", key(KEY_F), TEMP_SETTINGS).is_empty(), "duplicate live actions rejected")
	ck(not keys.rebind("action_move", key(KEY_W), TEMP_SETTINGS).is_empty(), "camera conflict rejected")
	ck(not keys.rebind("editor_brush", key(KEY_E), TEMP_SETTINGS).is_empty(), "editor conflict rejected")
	ck(not keys.rebind("action_build", key(KEY_1), TEMP_SETTINGS).is_empty(), "number picker keys reserved")
	ck(keys.rebind("action_move", key(KEY_MASK_ALT | KEY_M), TEMP_SETTINGS).is_empty(), "unused modified shortcut accepted")
	keys.load_bindings(TEMP_SETTINGS)
	ck(keys.matches(key(KEY_MASK_ALT | KEY_M), "action_move") and not keys.matches(key(KEY_M), "action_move"), "rebind persists across reload")
	var config := ConfigFile.new()
	config.load(TEMP_SETTINGS)
	config.set_value("ui", "accent", "blue")
	config.save(TEMP_SETTINGS)
	keys.reset_defaults(TEMP_SETTINGS)
	config.load(TEMP_SETTINGS)
	ck(config.get_value("ui", "accent") == "blue", "reset shortcuts preserves other settings")

func _battle() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(36, 24)
	for spawn in [[Vector2i(3, 4), "light_infantry", 0], [Vector2i(8, 6), "engineer", 0],
			[Vector2i(14, 6), "sapper", 0], [Vector2i(20, 6), "drone_operator", 0],
			[Vector2i(3, 14), "tank", 0], [Vector2i(2, 14), "light_infantry", 0],
			[Vector2i(14, 14), "shuttle", 0], [Vector2i(13, 14), "light_infantry", 0],
			[Vector2i(32, 20), "light_infantry", 1]]:
		map.set_spawn(spawn[0], spawn[1], spawn[2])
	MapHandoff.pending = map
	board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	board.state.turns.round_order.assign([0, 1])
	board.state.turns.active_index = 0
	board._refresh_status()

func _menus() -> void:
	var infantry: UnitInstance = board.state.grid.cell(Vector2i(3, 4)).occupant
	board._select(infantry)
	ck(press(KEY_M) and board.mode == board.Mode.MOVE, "M enters offered infantry move")
	press(KEY_ESCAPE)
	ck(press(KEY_F) and board.mode == board.Mode.SHOOT, "F enters offered infantry shot")
	press(KEY_ESCAPE)
	infantry.remaining_ap = 0
	infantry.move_credit = 0
	board._select(infantry)
	ck(press(KEY_M) and board.mode == board.Mode.MENU, "disabled action is a no-op")
	ck(not press(KEY_N), "absent ability is a no-op")
	infantry.remaining_ap = 2
	var engineer: UnitInstance = board.state.grid.cell(Vector2i(8, 6)).occupant
	board._select(engineer)
	ck(board._menu_actions.has("action_build"), "engineer offers Build")
	var multi_before: bool = board._multi_btn.button_pressed
	press(KEY_Z)
	ck(board._multi_btn.button_pressed != multi_before, "Z enables existing multiselect")
	press(KEY_Z)
	ck(board._multi_btn.button_pressed == multi_before, "Z toggles multiselect back off")
	board._select(engineer)
	press(KEY_N)
	ck(board._picker.visible and board._number_choices.size() > 1, "N opens available build choices")
	var first: Button = board._number_choices[0]
	ck(first.text.begins_with("1."), "choices display number labels")
	press(KEY_1)
	ck(board.mode == board.Mode.BUILD, "number picks the matching build mode")
	press(KEY_ESCAPE)
	var sapper: UnitInstance = board.state.grid.cell(Vector2i(14, 6)).occupant
	board._select(sapper)
	ck(not board._menu_actions.has("action_build"), "engineer actions do not leak to sapper")
	if board._menu_actions.has("action_mine"):
		press(KEY_N)
		ck(board.mode == board.Mode.MINE, "N lays mines for sapper")
		press(KEY_ESCAPE)
	var operator: UnitInstance = board.state.grid.cell(Vector2i(20, 6)).occupant
	for coord in [Vector2i(21, 6), Vector2i(20, 7)]:
		board.state.grid.cell(coord).feature_id = MCF.FEATURE_DRONE_STATION
		board.state.grid.cell(coord).feature_owner = 0
	board._select(operator)
	press(KEY_N)
	ck(board._picker.visible and board._number_choices.size() == 2, "operator N opens station choices")
	press(KEY_KP_2)
	var drone: UnitInstance = board.state.get_unit(board.selected_id)
	ck(drone != null and drone.is_drone and drone.coord == Vector2i(20, 7), "launch chooses station and auto-selects new drone")
	ck(board._menu_actions.has("action_move") and board._menu_actions.has("action_shoot"), "drone exposes fly and detonate")
	press(KEY_M)
	ck(board.mode == board.Mode.DRONE_FLY, "drone movement uses M")
	press(KEY_ESCAPE)
	ck(not press(KEY_N), "drone has no inherited operator N shortcut")
	var group: Array[int] = [infantry.id, engineer.id]
	board._set_group(group)
	press(KEY_T)
	ck(board.mode == board.Mode.GROUP_MOVE, "group T enters tactical movement")
	press(KEY_ESCAPE)
	ck(not board._menu_actions.has("action_launch"), "group has no operator actions")
	var tank: Vehicle
	var shuttle: Vehicle
	for vehicle: Vehicle in board.state.all_vehicles():
		if vehicle.type_id == "tank": tank = vehicle
		else: shuttle = vehicle
	var crew: UnitInstance = board.state.grid.cell(Vector2i(2, 14)).occupant
	ck(board.resolver.resolve(VehicleBoardIntent.new(crew.id, tank.id)).ok, "fixture boards tank")
	board._select_vehicle(tank)
	ck(board._menu_actions.has("action_move") and not board._menu_actions.has("action_build"), "vehicle has independent bindings")
	press(KEY_M)
	ck(board.mode == board.Mode.VEH_MOVE, "vehicle M enters movement")
	press(KEY_ESCAPE)
	var rider: UnitInstance = board.state.grid.cell(Vector2i(13, 14)).occupant
	ck(board.resolver.resolve(VehicleBoardIntent.new(rider.id, shuttle.id, Vehicle.DRIVER_SEAT)).ok, "fixture boards shuttle")
	board._select(rider)
	ck(board._menu_actions.has("action_seat"), "passenger offers seat change on Z")
	var passenger_multi: bool = board._multi_btn.button_pressed
	press(KEY_Z)
	ck(board._multi_btn.button_pressed == passenger_multi, "passenger Z keeps Change Seat instead of toggling multiselect")
	press(KEY_ESCAPE)
	board._select(rider)
	press(KEY_M)
	ck(board.mode == board.Mode.VEH_DISEMBARK, "passenger M selects exit")
	# Runtime collision fallback is displayed and invokes the correct second callback.
	board._select(infantry)
	var calls: Array = []
	var vb := VBoxContainer.new()
	board._menu.add_child(vb)
	board._act_btn(vb, "First", func(): calls.append("first"), true, "", "action_sweep")
	board._act_btn(vb, "Second", func(): calls.append("second"), true, "", "action_demolish")
	var assigned: int = board._menu_actions.action_demolish.code
	ck(assigned != KEY_Q and assigned != 0, "unexpected same-menu collision gets an unused letter")
	press(assigned)
	ck(calls == ["second"], "fallback key invokes the second button only")
	# More than nine candidates remain reachable, including disabled entries and page bounds.
	board._menu_actions.clear()
	for index in 11:
		board._act_btn(vb, "Choice %d" % index, func(): calls.append(index), index != 0, "Unavailable", "action_repair")
	press(KEY_Y)
	press(KEY_1)
	ck(calls == ["second"], "disabled numbered choice cannot fire")
	press(KEY_PAGEDOWN)
	press(KEY_2)
	ck(calls.back() == 10, "second page number selects tenth index")
	board._select(infantry)
	ck(not board._picker.visible and not board._menu_actions.has("action_repair"), "new selection drops old picker/actions")

func _extra_choices() -> void:
	var engineer: UnitInstance = board.state.grid.cell(Vector2i(8, 6)).occupant
	var near: Array[Vehicle] = []
	for at in [Vector2i(9, 6), Vector2i(6, 6)]:
		var vehicle: Vehicle = board.state.spawn_vehicle("shuttle", at, 0)
		vehicle.components[MCF.COMP_HULL] -= 1
		near.append(vehicle)
	board._select(engineer)
	press(KEY_Y)
	ck(board._picker.visible and board._number_choices.size() == 2, "Y selects between two damaged vehicles")
	press(KEY_1)
	ck(board._number_choices.size() == 1 and board._number_choices[0].text.contains("Hull"), "repair vehicle choice opens its numbered components")
	var before: int = near[0].durability
	press(KEY_1)
	ck(near[0].durability == before + 1 and near[1].durability < near[1].component_max(MCF.COMP_HULL), "numbered repair changes only chosen vehicle")
	engineer.remaining_ap = 2
	board._select(engineer)
	press(KEY_Y)
	ck(board._number_choices.size() == 1 and board._number_choices[0].text.contains("Hull"), "one damaged vehicle goes straight to its components")
	press(KEY_ESCAPE)
	press(KEY_B)
	ck(board.mode == board.Mode.BOARD_PICK and board._number_choices.size() == 2, "B opens two nearby boarding candidates")
	press(KEY_2)
	ck(board.veh_board_vid == near[1].id and board.mode == board.Mode.VEH_BOARD_SEAT and not board._picker.visible, "number picks vehicle and continues to seat selection")
	press(KEY_ESCAPE)
	var operator: UnitInstance = board.state.grid.cell(Vector2i(20, 6)).occupant
	board.state.grid.cell(Vector2i(20, 7)).feature_id = ""
	operator.remaining_ap = 2
	board._select(operator)
	var count: int = board.state.all_units().size()
	press(KEY_N)
	var drone: UnitInstance = board.state.get_unit(board.selected_id)
	ck(board.state.all_units().size() == count + 1 and drone.is_drone and not board._picker.visible, "single station launches directly and selects new drone")
	var result := ActionResult.success()
	result.spawned_unit_id = drone.id
	board.networked = true
	board.my_owner = 1
	ck(not board._select_spawned_drone(SpawnDroneIntent.new(operator.id), result), "enemy client's selection is not stolen by drone spawn")
	board.my_owner = 0
	ck(board._select_spawned_drone(SpawnDroneIntent.new(operator.id), result), "owner's network client auto-selects its drone")
	board.networked = false
	ck(not board._select_spawned_drone(SpawnDroneIntent.new(operator.id), ActionResult.fail("denied")), "denied launch does not change selection")
	var infantry: UnitInstance = board.state.grid.cell(Vector2i(3, 4)).occupant
	infantry.status = MCF.Status.HELD
	board._select(infantry)
	ck(board._menu_actions.size() == 1 and board._menu_actions.action_shoot.code == KEY_F, "held unit only exposes F to break free")
	infantry.status = MCF.Status.ALIVE
	board._select(infantry)

func _undo_and_focus() -> void:
	var unit: UnitInstance = board.state.grid.cell(Vector2i(3, 4)).occupant
	unit.remaining_ap = 2
	var before: Vector2i = unit.coord
	ck(board.resolver.resolve(MoveIntent.new(unit.id, before + Vector2i(1, 0))).ok, "undo fixture moves")
	board._select(unit)
	press(KEY_MASK_CTRL | KEY_Z)
	ck(board.state.get_unit(unit.id).coord == before, "Ctrl+Z undoes real game action")
	press(KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_Z)
	ck(board.state.get_unit(unit.id).coord == before + Vector2i(1, 0), "Ctrl+Shift+Z redoes action")
	var digest: int = board.state.digest_hash()
	board.mode = board.Mode.DRAW
	board._draw_record_begin(0, 0)
	board._cur_stroke = []
	board._stroke_add(Vector2(100, 100))
	board._stroke_add(Vector2(200, 100))
	board._stroke_commit()
	board._draw_record_end(0)
	ck(not board._canvas(0, 0).is_empty(), "drawing shortcut fixture has a stroke")
	press(KEY_MASK_CTRL | KEY_Z)
	ck(board._canvas(0, 0).is_empty(), "Ctrl+Z in drawing mode removes only the last stroke")
	ck(board.state.digest_hash() == digest, "drawing undo leaves game state intact")
	board.mode = board.Mode.ERASE
	press(KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_Z)
	ck(board.state.digest_hash() == digest, "drawing mode never redoes gameplay")
	board.mode = board.Mode.NONE
	ck(not press(KEY_1) and not press(KEY_KP_1), "1 and keypad 1 no longer open initiative")
	var focus := Button.new()
	board._ui_layer.add_child(focus)
	focus.grab_focus()
	root.push_input(key(KEY_TAB))
	ck(board._init_overlay.visible, "Tab opens initiative even with a focused button")
	root.push_input(key(KEY_TAB))
	ck(not board._init_overlay.visible, "Tab closes initiative")
	focus.queue_free()
	var input := LineEdit.new()
	board._ui_layer.add_child(input)
	input.grab_focus()
	ck(not press(KEY_TAB) and not press(KEY_M), "text focus owns keyboard input")
	input.release_focus()
	input.queue_free()
	board._animating = true
	board._select(board.state.get_unit(unit.id))
	ck(not press(KEY_M), "animation blocks action keys")
	board._animating = false

func _replay() -> void:
	var state: GameState = MapData.blank_arena(12, 10).build_state(22)
	var map := MapData.blank_arena(12, 10)
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(8, 7), "light_infantry", 1)
	state = map.build_state(22)
	var resolver := GameActionResolver.new(state)
	var recorder := ReplayRecorder.new()
	recorder.begin(state, resolver)
	recorder.capture_opening()
	for i in 4: resolver.resolve(EndTurnIntent.new(state.active_player()))
	board.queue_free()
	await process_frame
	SaveHandoff.pending_replay = recorder.to_dict()
	board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	press(KEY_RIGHT)
	await create_timer(0.2).timeout
	ck(board.replay.index == 1, "Right steps replay")
	press(KEY_LEFT)
	ck(board.replay.index == 0, "Left seeks back")
	press(KEY_LEFT)
	ck(board.replay.index == 0, "Left at start clamps")
	var digest: int = board.state.digest_hash()
	press(KEY_MASK_CTRL | KEY_Z)
	press(KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_Z)
	ck(board.state.digest_hash() == digest, "replay ignores undo/redo")
	var playing: bool = board._replay_playing
	press(KEY_SPACE)
	ck(board._replay_playing != playing, "Space toggles replay playback")
	board.queue_free()
	await process_frame

func _editor() -> void:
	var editor = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	ck(editor._shortcut(key(KEY_E)) and editor.tool == editor.Tool.ERASER, "editor E selects eraser")
	ck(keys.rebind("editor_eraser", key(KEY_J), TEMP_SETTINGS).is_empty(), "editor tool can be rebound")
	editor._shortcut(key(KEY_B))
	ck(not editor._shortcut(key(KEY_E)), "old editor binding no longer works")
	ck(editor._shortcut(key(KEY_J)) and editor.tool == editor.Tool.ERASER, "new editor binding activates tool")
	ck(editor._tool_buttons[editor.Tool.ERASER].tooltip_text.contains("J"), "editor tooltip follows rebind")
	keys.load_bindings(TEMP_SETTINGS)
	ck(editor._shortcut(key(KEY_J)), "editor binding survives reload")
	keys.reset_defaults(TEMP_SETTINGS)
	var popup: PopupMenu = editor._menus["File"]
	popup.popup()
	ck(not editor._shortcut(key(KEY_E)), "open editor menu owns keyboard input")
	popup.hide()
	editor.queue_free()
	await process_frame

func _settings() -> void:
	var settings = load("res://src/ui/SettingsWindow.gd").open(root)
	ck(settings._tabs.get_tab_count() == 2 and settings._tabs.get_tab_title(1) == "Keybinds", "Settings has Keybinds tab")
	ck(settings._key_sections.get_tab_title(0) == "In-game shortcuts" and settings._key_sections.get_tab_title(1) == "Map editor shortcuts", "keybinds are divided into gameplay and editor pages")
	settings.show_keybinds(true)
	ck(settings._tabs.current_tab == 1 and settings._key_sections.current_tab == 1, "editor help opens directly to editor shortcuts")
	ck(settings._key_buttons.has("action_move") and settings._key_buttons.has("editor_brush"), "Settings covers gameplay and editor")
	ck(keys.modal_open(), "settings blocks battle/editor shortcuts")
	settings._capture_action = "action_move"
	settings._input(key(KEY_F))
	ck(settings._key_message.text.contains("Already used") and keys.codes("action_move")[0] == KEY_M, "capture surfaces conflict without replacing binding")
	settings._input(key(KEY_ESCAPE))
	ck(settings._capture_action.is_empty() and not settings.is_queued_for_deletion(), "Escape cancels capture without closing Settings")
	settings.queue_free()
	await process_frame
