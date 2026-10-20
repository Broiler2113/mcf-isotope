extends "res://tests/SuiteBase.gd"
## Game files: folders in the game folder, save previews, time of day through files, notes
## that list files without reading them, saved logs and chat.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_shared_folders()
	_save_preview()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_game_folders()
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_time_of_day()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	_time_choices()

	await save_and_walk()

	_file_notes()

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

## Owner (0.12): saves, replays and maps go into their own folders right in the game folder;
## what 0.11 kept in "Isotope Data" moves up once, without overwriting anything.
func _game_folders() -> void:
	var root := GameFolders.root()
	ck(ReplayFile.SAVE_DIR == root.path_join("Saves") and ReplayFile.REPLAY_DIR == root.path_join("Replays")
			and MapData.MAPS_DIR == root.path_join("Maps"), "Saves, Replays and Maps are folders of the game folder")
	ck(root == GameFolders.game_dir() or OS.get_environment("MCF_DATA_DIR") != "", "the game folder is the root: " + root)
	var old := GameFolders.game_dir().path_join(GameFolders.LEGACY_ROOT).path_join("Saves")
	DirAccess.make_dir_recursive_absolute(old)
	var f := FileAccess.open(old.path_join("zz-012-old.mcfs"), FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	var kept := FileAccess.open(ReplayFile.SAVE_DIR.path_join("zz-012-both.mcfs"), FileAccess.WRITE)
	kept.store_string("new")
	kept.close()
	f = FileAccess.open(old.path_join("zz-012-both.mcfs"), FileAccess.WRITE)
	f.store_string("old")
	f.close()
	var moved := GameFolders.adopt_isotope_data()
	ck(moved >= 1 and FileAccess.file_exists(ReplayFile.SAVE_DIR.path_join("zz-012-old.mcfs"))
			and not FileAccess.file_exists(old.path_join("zz-012-old.mcfs")), "an old save moves into the game folder's Saves")
	ck(FileAccess.get_file_as_string(ReplayFile.SAVE_DIR.path_join("zz-012-both.mcfs")) == "new"
			and FileAccess.file_exists(old.path_join("zz-012-both.mcfs")), "a name clash is never overwritten")
	for p in [ReplayFile.SAVE_DIR.path_join("zz-012-old.mcfs"), ReplayFile.SAVE_DIR.path_join("zz-012-both.mcfs"),
			old.path_join("zz-012-both.mcfs")]:
		DirAccess.remove_absolute(p)
	GameFolders.adopt_isotope_data()
	ck(not DirAccess.dir_exists_absolute(old), "an emptied old folder is removed")
	ck(MapData.list_maps().has("town.json"), "the bundled maps still load from their new place")

## The map's time of day travels through files, the battle state, saves and the generator.
func _time_of_day() -> void:
	var m := MapData.blank_arena(12, 10)
	ck(m.time_of_day == "", "a new map has no time of day (plain night lighting)")
	m.time_of_day = "evening"
	var back := MapData.from_dict(m.to_dict())
	ck(back.time_of_day == "evening", "time of day survives the map file")
	var bad := m.to_dict()
	bad["time"] = "noon"
	ck(MapData.from_dict(bad).time_of_day == "", "an unknown time of day is dropped")
	var st := back.build_state(1)
	ck(st.time_of_day == "evening", "the battle starts at the map's time of day")
	ck(StateCodec.decode(StateCodec.encode(st)).time_of_day == "evening", "saves and resyncs carry it")
	var seen := {}
	for seed in 12:
		seen[MapGen.time_choice({"time": "random", "seed": seed})] = true
	ck(seen.size() >= 3 and seen.keys().all(func(t: String) -> bool: return t in MapData.TIMES),
			"Random picks among the four times (%s)" % ", ".join(seen.keys()))
	ck(MapGen.time_choice({"time": "day", "seed": 1}) == "day", "a chosen time is kept")
	var lm: GDScript = load("res://src/ui/LightManager.gd")
	var night: Color = lm.ambient_for("town", 1.0, "night")
	var day: Color = lm.ambient_for("town", 1.0, "day")
	ck(day.get_luminance() > night.get_luminance() + 0.2, "day is much brighter than night")

func _time_choices() -> void:
	for style in MapGen.STYLE_ENV.size():
		var outdoor := style in [MapGen.Style.TOWN, MapGen.Style.FIELD]
		for time in MapData.TIMES + ["random"]:
			var value := MapGen.time_choice({"style": style, "time": time, "seed": 7})
			ck(MapData.TIMES.has(value) if outdoor else value == "", "%s accepts time=%s only outdoors" % [MapGen.STYLE_NAMES[style], time])

func arena() -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 5), "light_infantry", 1)
	var s := map.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

func save_and_walk() -> void:
	var r := arena()
	MapHandoff.pending = null
	SaveHandoff.pending_save = {"state": StateCodec.encode(r.state), "rules": StateCodec.encode_rules(r),
		"combat_log": ["A saved combat line"], "chat": [{"side": 0, "text": "Saved [b]chat"}]}
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	main._paused = true
	ck(main.state.log.lines.has("A saved combat line") and main._log_label.text.contains("A saved combat line"), "loaded combat log restores its model and panel")
	ck(NetHandoff.chat_history.size() == 1 and main._chat_log.get_parsed_text().contains("Saved [b]chat"), "loaded chat restores literal text safely")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(main._save_payload()))
	ck(saved.combat_log.has("A saved combat line") and saved.chat[0].text == "Saved [b]chat", "saving again retains both histories")
	# An L-shaped route: the midpoint sees a side room neither endpoint can see.
	main.resolver.fog_enabled = true
	var u: UnitInstance = main.state.grid.cell(Vector2i(2, 5)).occupant
	for y in range(1, 15): main.state.grid.cell(Vector2i(6, y)).set_feature(MCF.FEATURE_WALL)
	main.state.grid.cell(Vector2i(6, 8)).clear_feature()
	var target := Vector2i(8, 8)
	main._walk_cells[u.id] = Vector2i(3, 5)
	ck(not main._visible_before_impact(0).has(target), "walk presentation initially hides side room")
	main._walk_cells[u.id] = Vector2i(5, 8)
	ck(main._visible_before_impact(0).has(target), "fog reveals side room at intermediate walk cell")
	ck(u.coord == Vector2i(2, 5), "animated sight never changes authoritative unit position")
	main._walk_cells.clear()
	ck(not main._visible_before_impact(0).has(target), "final sight returns to simulation position")
	main.recorder = null
	main.queue_free()
	await process_frame

## replay/save notes let the menu list files without reading them
func _file_notes() -> void:
	var path := "user://_tmp_note_test.mcfr"
	ReplayFile.write(path, {"meta": {"map": "town", "round": 4, "steps": 120}})
	ck(FileAccess.file_exists(ReplayFile._note_path(path)) and not FileAccess.file_exists(path + ReplayFile.NOTE_EXT),
			"writing a replay caches its note outside the shared folder (0.11)")
	ck(ReplayFile.note_for(path) == "town · round 4 · 120 actions", "the note is the menu caption (%s)" % ReplayFile.note_for(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ReplayFile._note_path(path)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
