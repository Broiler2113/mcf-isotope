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

## Saves, replays, maps and presets are plain files in "Isotope Data"; whatever is put
## there by hand is listed, with no caption files left beside it.
func _shared_folders() -> void:
	var root := GameFolders.root()
	ck(DirAccess.dir_exists_absolute(root) and root.ends_with(GameFolders.ROOT_NAME), "the shared folder exists: " + root)
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
