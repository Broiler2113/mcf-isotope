extends SceneTree
## 0.11 batch (issues-fix-10 + review): bursts finished at any target, impossible rolls,
## Enter to roll, events at round end.

var fails: PackedStringArray = []
func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond: fails.append(what)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_burst()
	await _burst_button()
	_impossible_rolls()
	await _enter_rolls()
	_shared_folders()
	_save_preview()
	await _light_colours()
	_builtin_presets()
	await _move_while_walking()
	_piece_pictures()
	print("batch 0.11: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

func _arena() -> GameState:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(10, 10), "light_infantry", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)   # east
	m.set_spawn(Vector2i(10, 6), "light_infantry", 1)    # north — a different firing line
	var s := m.build_state(5)
	s.turns.round_order.assign([0, 1])
	s.turns.active_index = 0
	return s

## The rest of a paid burst can go at another target, on another line, without AP.
func _burst() -> void:
	var s := _arena()
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	var shooter := s.grid.cell(Vector2i(10, 10)).occupant
	var east := s.grid.cell(Vector2i(14, 10)).occupant
	var north := s.grid.cell(Vector2i(10, 6)).occupant
	shooter.remaining_ap = 1
	ck(shooter.rate_of_fire() >= 2, "fixture shooter fires bursts")
	ck(r.resolve(ShootIntent.new(shooter.id, east.id, 1)).ok, "first bullet at the east target")
	ck(shooter.remaining_ap == 0 and shooter.action_state != null and shooter.action_state.remaining_shots >= 1,
			"the burst is paid and has bullets left")
	var res := r.resolve(ShootIntent.new(shooter.id, north.id, -1))
	ck(res.ok, "the rest goes at a target on another line: " + res.reason)
	ck(shooter.remaining_ap == 0, "finishing the burst costs no AP")

## The battle menu keeps a plain "Shoot" button while bullets are left, even when the
## first target is gone (it used to grey out and read "Finish Burst").
func _burst_button() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(10, 10), "light_infantry", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	m.set_spawn(Vector2i(10, 6), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 10: await process_frame
	var st: GameState = main.state
	while st.active_player() != 0:
		main._on_intent_ready(EndTurnIntent.new())
		for i in 5: await process_frame
	var shooter := st.grid.cell(Vector2i(10, 10)).occupant
	var east := st.grid.cell(Vector2i(14, 10)).occupant
	shooter.remaining_ap = 1
	shooter.action_state = ActionState.new()
	shooter.action_state.target_id = east.id
	shooter.action_state.remaining_shots = 1
	shooter.remaining_ap = 0
	east.status = MCF.Status.CORPSE
	main.selected_id = shooter.id
	main._open_menu(shooter)
	var shoot: Button = null
	for b in main._menu.find_children("*", "Button", true, false):
		if str(b.get_meta("action_label", b.text)) == "Shoot": shoot = b
	ck(shoot != null and not shoot.disabled, "a burst with bullets left keeps an enabled Shoot button")
	main._enter_shoot()
	ck(shooter.action_state != null, "opening shoot mode no longer deletes the burst locally")
	main.queue_free()
	await process_frame

## A step whose every die needs 7+ never waits for a Roll press.
func _impossible_rolls() -> void:
	var main: Node = load("res://tests/fixtures/GroundBackgroundOnly.gd").new()
	var ev := {"kind": "check", "roll": 3, "need": 7, "ok": false, "roller": 0}
	var steps: Array = main._dice_steps(ev)
	ck(steps.size() == 1 and steps[0].get("auto", false) and not steps[0]["manual"], "a 7+ check is automatic")
	ck(str(steps[0]["prompt"]).contains("7+"), "and the prompt says why")
	var ok: Array = main._dice_steps({"kind": "check", "roll": 3, "need": 6, "ok": false, "roller": 0})
	ck(not ok[0].get("auto", false), "a 6+ roll stays a normal roll")
	main.free()

func _enter_rolls() -> void:
	var roller: Node = load("res://scenes/DiceRoller.gd").new()
	root.add_child(roller)
	await process_frame
	var pressed := [false]
	roller.play([{"value": 4, "good": true, "tag": "Hit 3+"}], true)
	roller.rolled.connect(func() -> void: pressed[0] = true)
	await process_frame
	ck(roller._roll_btn.visible and roller._roll_btn.text.contains("Enter"), "the Roll button names its key")
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	Input.parse_input_event(key)
	for i in 3: await process_frame
	ck(pressed[0], "Enter rolls the dice")
	roller.queue_free()

## Saves, replays, maps and presets are plain files in their own folders of the game folder
## (0.12; "Isotope Data" in 0.11); whatever is put there by hand is listed, with no caption
## files left beside it.
func _shared_folders() -> void:
	var root := GameFolders.root()
	ck(DirAccess.dir_exists_absolute(root) and (root == GameFolders.game_dir()
			or OS.get_environment("MCF_DATA_DIR") != ""), "the data folders live in the game folder: " + root)
	ck(ReplayFile.SAVE_DIR == root.path_join("Saves") and ReplayFile.REPLAY_DIR == root.path_join("Replays")
			and MapData.MAPS_DIR == root.path_join("Maps"), "saves, replays and maps have their own folders")
	var save := {"kind": ReplayFile.KIND_SAVE, "meta": {"map": "Dropped", "round": 3}}
	var dropped := ReplayFile.SAVE_DIR.path_join("zz-friend-shared.MCFS")
	ck(ReplayFile.write(dropped, save), "a save file can be written into the folder")
	ck(ReplayFile.saves().has("zz-friend-shared.MCFS"), "a dropped save is listed, whatever the case of its extension")
	ck(ReplayFile.note_for(dropped).contains("Dropped"), "its caption is read")
	ck(not FileAccess.file_exists(dropped + ".note"), "no caption file is left in the shared folder")
	DirAccess.remove_absolute(dropped)
	var map := MapData.blank_arena(12, 10)
	var map_path := MapData.MAPS_DIR.path_join("zz-friend-map.json")
	ck(map.save_to(map_path), "a map can be written into the folder")
	ck(MapData.list_maps().has("zz-friend-map.json") and MapData.load_from(MapData.path_for("zz-friend-map.json")) != null,
			"a dropped map is listed and loads")
	DirAccess.remove_absolute(map_path)
	DirAccess.remove_absolute(GameFolders.ADOPTED_MARKER)
	DirAccess.make_dir_recursive_absolute("user://saves")
	var legacy := "user://saves/zz-legacy.mcfs"
	ReplayFile.write(legacy, save)
	ck(GameFolders.adopt_user_data() >= 1 and FileAccess.file_exists(ReplayFile.SAVE_DIR.path_join("zz-legacy.mcfs")),
			"saves from before 0.11 are copied into the shared folder")
	DirAccess.remove_absolute(ReplayFile.SAVE_DIR.path_join("zz-legacy.mcfs"))
	ck(GameFolders.adopt_user_data() == 0 and not FileAccess.file_exists(ReplayFile.SAVE_DIR.path_join("zz-legacy.mcfs")),
			"only once: a save deleted from the shared folder does not come back")
	DirAccess.remove_absolute(legacy)

## A loaded save previews its own battlefield in the lobby, armies included.
func _save_preview() -> void:
	var m := MapData.blank_arena(14, 10)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(11, 7), "light_infantry", 1)
	m.set_cell(Vector2i(6, 4), MCF.FLOOR_NORMAL, MCF.WALL_HEIGHT, false, MCF.FEATURE_WALL)
	var s := m.build_state(3)
	var back := MapData.from_grid(StateCodec.decode(StateCodec.encode(s)).grid, s.env)
	ck(back.width == 14 and back.get_feature(Vector2i(6, 4)) == MCF.FEATURE_WALL, "a saved board converts back into a map")
	var lobby: Node = load("res://scenes/Lobby.gd").new()
	var preview: MapData = lobby._saved_battlefield(StateCodec.encode(s))
	ck(preview != null and preview.spawns.size() == 2, "the preview carries every living soldier (%d)" % (preview.spawns.size() if preview != null else -1))
	lobby.free()

## A lamp's colour is chosen in the editor (right-click or Ctrl+click) and carries into the
## battle: the glow takes the colour, and so does the lamp's glass.
func _light_colours() -> void:
	var ed: Node = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(ed)
	for i in 5: await process_frame
	var c := Vector2i(5, 5)
	var i: int = c.y * ed.map.width + c.x
	var t: Array = ed._tuple(i)
	t[3] = "floor_lamp"
	t[1] = Furniture.height_of("floor_lamp")
	ed._begin()
	ed._write(i, t)
	ed._commit()
	var screen: Vector2 = ed.pan + (Vector2(c) + Vector2(0.5, 0.5)) * ed.cell_size()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.ctrl_pressed = true
	click.position = screen
	ed._unhandled_input(click)
	ck(ed._light_menu != null and ed._light_menu.visible and ed._light_menu.item_count == Furniture.LIGHT_TINTS.size() + 1 + Furniture.LIGHT_LEVELS.size(),
			"Ctrl+click on a lamp opens its colour menu (Mac habit)")
	ed._light_menu.hide()
	for pressed in [true, false]:
		var right := InputEventMouseButton.new()
		right.button_index = MOUSE_BUTTON_RIGHT
		right.pressed = pressed
		right.position = screen
		ed._unhandled_input(right)
	ck(ed._light_menu.visible, "a right-click (two-finger click) opens it too")
	ed._light_menu.id_pressed.emit(4)   # Red
	ck(ed.map.get_tint(i) == 4 and ed._grid.tint_at(c.x, c.y) == 4, "the chosen colour is stored on the map")
	var occ := LightOccluders.new()
	occ.sync(ed._grid)
	ck(occ.sources[c][0].color == Furniture.LIGHT_TINTS[4][1], "the glow takes the colour")
	var back := MapData.from_dict(ed.map.to_dict())
	ck(back.get_tint(i) == 4, "it survives saving the map")
	var g := Grid.new(back.width, back.height)
	back.apply_to_grid(g)
	ck(g.tint_at(c.x, c.y) == 4, "and reaches the battle board")
	var white := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	white.fill(Color(0.95, 0.95, 0.95))
	var red := TerrainTiles.tint_lamp(white, Furniture.LIGHT_TINTS[4][1]).get_pixel(1, 1)
	ck(red.r > 0.8 and red.g < 0.5, "a white lamp's glass turns red with its light")
	ed.undo()
	ck(ed.map.get_tint(i) == 0, "undo puts the colour back")
	ed.queue_free()
	await process_frame

## The built-in rooms are ordinary preset files: listed, renamable, deletable for good.
func _builtin_presets() -> void:
	var store := load("res://src/data/RoomPresetStore.gd")
	var marker: String = store.DIR.path_join(store.SEEDED_MARKER)
	DirAccess.remove_absolute(marker)
	store.remove_preset("Corridor")
	store.seed_builtins()
	ck(store.names().has("Small room") and store.names().has("Hedgehog row"), "built-in rooms are preset files")
	ck(store.rename_preset("Corridor", "zz Hall") and store.names().has("zz Hall") and not store.names().has("Corridor"),
			"a built-in can be renamed")
	store.remove_preset("zz Hall")
	ck(store.seed_builtins() == 0 and not store.names().has("Corridor"), "a deleted built-in stays deleted")
	store.save_preset("Corridor", MapPresets.stamp("corridor"), "station")

## While one of your soldiers walks, the next can already be ordered (0.11).
func _move_while_walking() -> void:
	var m := MapData.blank_arena(24, 16)
	m.set_spawn(Vector2i(2, 3), "light_infantry", 0)
	m.set_spawn(Vector2i(2, 9), "light_infantry", 0)
	m.set_spawn(Vector2i(21, 12), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 10: await process_frame
	var st: GameState = main.state
	while st.active_player() != 0:
		main._on_intent_ready(EndTurnIntent.new())
		for i in 5: await process_frame
	var a := st.grid.cell(Vector2i(2, 3)).occupant
	var b := st.grid.cell(Vector2i(2, 9)).occupant
	main._on_intent_ready(MoveIntent.new(a.id, Vector2i(6, 3)))
	await process_frame
	ck(not main._animating and main._walk_jobs.has(a.id), "a plain move animates without locking the screen")
	main._on_intent_ready(MoveIntent.new(b.id, Vector2i(6, 9)))
	await process_frame
	ck(b.coord == Vector2i(6, 9) and main._walk_jobs.has(a.id) and main._walk_jobs.has(b.id),
			"a second soldier is ordered while the first still walks")
	var waited := 0
	while main._walks_running > 0 and waited < 600:
		await process_frame
		waited += 1
	await process_frame
	ck(main._walks_running == 0 and main._walk_cells.is_empty(), "both walks finish and nobody is left drawn mid-way")
	main.queue_free()
	await process_frame

## A fixed-size piece is one picture: each cell shows its part, turned with the piece (0.11).
func _piece_pictures() -> void:
	var g := Grid.new(8, 6)
	for c: Vector2i in [Vector2i(1, 1), Vector2i(2, 1)]: g.cell(c).set_feature("piano")
	for c: Vector2i in [Vector2i(5, 1), Vector2i(5, 2)]:
		g.cell(c).set_feature("piano")
		g.furniture_turn[c] = ["piano", 1]
	var t := TerrainTiles.new(g, "station")
	var piece: Image = Sprites.texture_of("piano_piece").get_image()
	piece.convert(Image.FORMAT_RGBA8)
	var part := func(img: Image, at: Vector2i) -> PackedByteArray:
		return img.get_region(Rect2i(at * 32, Vector2i(32, 32))).get_data()
	ck(t._furniture_image(Vector2i(1, 1), "piano", 32).get_data() == part.call(piece, Vector2i(0, 0))
			and t._furniture_image(Vector2i(2, 1), "piano", 32).get_data() == part.call(piece, Vector2i(1, 0)),
			"a piano shows its own picture across both cells")
	var turned: Image = piece.duplicate()
	turned.rotate_90(CLOCKWISE)
	ck(t._furniture_image(Vector2i(5, 2), "piano", 32).get_data() == part.call(turned, Vector2i(0, 1)),
			"a turned piano shows the turned picture")
	g.cell(Vector2i(2, 1)).clear_feature()
	var lone := TerrainTiles.new(g, "station")
	ck(lone._furniture_image(Vector2i(1, 1), "piano", 32).get_data() != part.call(piece, Vector2i(0, 0)),
			"half a piano falls back to the sheet")
