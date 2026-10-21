extends "res://tests/SuiteBase.gd"
## Menus and windows: the Manual and unit cards, the keyboard diagram, bug reports,
## American spelling, the lobby's boxes, shortcuts, chat escaping, spawn controls.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	await _lobby()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_manual()
	await _keyboard()
	await _bug_report()
	_american_spelling()
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

	MainScript = load("res://scenes/Main.gd")
	ManualWindowScript = load("res://src/ui/ManualWindow.gd")
	ManualTextScript = load("res://src/ui/ManualText.gd")
	BugReportScript = load("res://src/ui/BugReportWindow.gd")
	SettingsScript = load("res://src/ui/SettingsWindow.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.fog_mode = MCF.Fog.OFF
	_units_and_manual()
	await _attachments()
	await _interface()

	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_shortcut()

	await spawn_controls()

	_chat_text_is_escaped()

## #2: the random map has no Flammable box; flammability follows the map style.
func _lobby() -> void:
	var lobby: Node = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(lobby)
	for i in 3: await process_frame
	var boxes: Array = lobby.find_children("*", "CheckBox", true, false).map(func(c: CheckBox) -> String: return c.text)
	ck(not boxes.has("Flammable") and boxes.has("Obstacles"), "no Flammable box, Obstacles stays: %s" % [boxes])
	if lobby._gen_style != null:
		for style in MapGen.STYLE_FLAMMABLE.size():
			lobby._gen_style.select(style)
			ck(bool(lobby._gen_options()["flammable"]) == MapGen.STYLE_FLAMMABLE[style],
					"style %d: flammable = %s" % [style, MapGen.STYLE_FLAMMABLE[style]])
	lobby.queue_free()
	await process_frame

# --- battle screen ---------------------------------------------------------------------

func _manual() -> void:
	var text: GDScript = load("res://src/ui/ManualText.gd")
	var win: GDScript = load("res://src/ui/ManualWindow.gd")
	var sections: Array = text.sections()
	var ok := sections.size() >= 15
	for s: Array in sections:
		ok = ok and str(s[0]) != "" and str(s[1]).length() > 40
	ck(ok, "the Manual has %d sections, all with text" % sections.size())
	var formatted: String = win.format(str(sections[2][1]))
	ck(formatted.find("[h]") < 0 and formatted.find("[font_size=15]") >= 0, "headings are formatted")
	var cards_ok := true
	for id: String in win.UNIT_ORDER:
		cards_ok = cards_ok and ResourceLoader.exists("res://src/data/units/%s.tres" % id)
	ck(cards_ok, "every unit card has data")
	var keys: Node = root.get_node("/root/Keybinds")
	ck(keys.codes("game_manual").has(KEY_F1) and keys.codes("editor_manual").has(KEY_F2),
			"F1 opens the Manual in the game, F2 in the editor")

func _keyboard() -> void:
	var kb: Control = load("res://src/ui/KeyboardDiagram.gd").new()
	root.add_child(kb)
	await process_frame
	kb.section = "game"
	var n: String = kb.tooltip_for(KEY_N, "N")
	ck(n.find("Lay mine") >= 0 and n.find("Build fortification") >= 0 and n.find("Launch kamikaze drone") >= 0,
			"the N key lists all three of its actions")
	ck(kb._state(KEY_S) == 3, "S is used alone (pan) and in a combination (Ctrl+S)")
	ck(kb._state(KEY_CTRL) == 2 and kb.tooltip_for(KEY_CTRL, "Ctrl").find("Ctrl+S") >= 0, "Ctrl lists its combinations")
	ck(kb.tooltip_for(KEY_F12, "F12").ends_with("Not used"), "a free key says so")
	kb.section = "editor"
	ck(kb.tooltip_for(KEY_Z, "Z").find("Undo") >= 0, "the editor view shows editor shortcuts")
	var overlap := false
	for i in kb._keys.size():
		for j in range(i + 1, kb._keys.size()):
			if (kb._keys[i][0] as Rect2).grow(-0.01).intersects((kb._keys[j][0] as Rect2).grow(-0.01)):
				overlap = true
	ck(not overlap, "no two keys overlap on the diagram")
	kb.queue_free()

func _bug_report() -> void:
	var w: CanvasLayer = load("res://src/ui/BugReportWindow.gd").new()
	w._combat_log = "— Round 1 —"
	w._replay_json = JSON.stringify({"steps": []})
	w._shot_png = PackedByteArray([137, 80, 78, 71])
	root.add_child(w)
	await process_frame
	w._text.text = "test"
	var doc: Dictionary = w.payload()
	ck(doc.has("screenshot") and doc.has("log") and doc.has("combat_log") and doc.has("replay") and doc["version"] != "",
			"a report carries what is ticked: screenshot, log, combat log, replay, version")
	w._send_shot.button_pressed = false
	w._send_log.button_pressed = false
	w._send_match.button_pressed = false
	doc = w.payload()
	ck(not doc.has("screenshot") and not doc.has("log") and not doc.has("replay") and not doc.has("combat_log"),
			"unticked attachments are not sent")
	print("game log captured: %d chars" % GameLog.text().length())
	w.queue_free()
	await process_frame

## Owner rule (0.12): everything players read is in American English. Scans string literals
## only; code identifiers and save keys ("burnt", the "grey" furniture variant) are exempt.
const BRITISH := ["armour", "colour", "defence", "offence", "centre", "metre", "grey", "favour",
	"behaviour", "honour", "neighbour", "labour", "flavour", "humour", "realise", "realised",
	"organise", "recognise", "optimise", "synchronis", "initialis", "immobilis", "cancelled",
	"labelled", "levelled", "levelling", "modelled", "travelled", "tunnelling", "catalogue",
	"manoeuvre", "programme", "licence", "artefact", "judgement", "whilst", "amongst", "towards",
	"learnt", "burnt"]

const EXEMPT := ["\"burnt\"", "\"grey\""]

func _american_spelling() -> void:
	var lit := RegEx.create_from_string("\"\"\"[\\s\\S]*?\"\"\"|\"(?:\\\\.|[^\"\\\\\\n])*\"")
	var hits: Array[String] = []
	for dir in ["res://scenes", "res://src"]:
		for path in _scripts(dir):
			var s := FileAccess.get_file_as_string(path)
			for m in lit.search_all(s):
				var t := m.get_string()
				if t in EXEMPT:
					continue
				var low := t.to_lower()
				for word: String in BRITISH:
					var at := low.find(word)
					if at >= 0 and (at == 0 or not low[at - 1].is_valid_identifier() or low[at - 1] == "\""):
						hits.append("%s: %s" % [path.get_file(), t.substr(0, 60)])
	ck(hits.is_empty(), "player-facing text uses American spelling %s" % (str(hits.slice(0, 5)) if not hits.is_empty() else ""))

func _scripts(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") or f.ends_with(".tscn"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_scripts(dir + "/" + d))
	return out

var MainScript: GDScript

var ManualWindowScript: GDScript

var ManualTextScript: GDScript

var BugReportScript: GDScript

var SettingsScript: GDScript

func state_of(m: MapData) -> GameState:
	var st := m.build_state(77)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

func _units_and_manual() -> void:
	ck(not GameActionResolver.ARMY_ROSTER.has("assault") and not ManualWindowScript.UNIT_ORDER.has("assault"), "Assault removed from armies and manual")
	ck(StateCodec.load_stats("assault").id == "heavy_infantry", "legacy Assault saves resolve to Heavy Infantry")
	ck(StateCodec.load_stats("sapper").display_name == "Minesweeper", "legacy Sapper ID displays Minesweeper")
	var wanted := ["sniper", "marksman", "anti_tank", "flamethrower", "engineer", "miner", "sapper", "shield_bearer", "drone_operator"]
	ck(ManualTextScript.UNIT_BLURBS.size() == wanted.size() and wanted.all(func(id): return ManualTextScript.UNIT_BLURBS.has(id)), "only the requested specialists have descriptions")
	var text := ""
	for section in ManualTextScript.sections(): text += ManualWindowScript.format(section[1])
	for blurb in ManualTextScript.UNIT_BLURBS.values(): text += str(blurb)
	ck(not text.contains("—") and not text.contains("BRU") and not text.contains("Sapper"), "manual uses hyphens, LDF and Minesweeper")
	ck(text.contains("Potential") and text.contains("nine trench digs") and text.contains("[h]") == false, "laser mechanics and Borg engineering documented")
	for env in ["town", "field", "station", "bunker", "asteroid"]:
		for mode in [MatchMode.Kind.ANNIHILATION, MatchMode.Kind.CAPTURE, MatchMode.Kind.HOLDOUT]:
			ck(RandomEvents.available_for_map("dust", env, mode) == (env in ["town", "field"])
				and RandomEvents.available_for_map("minefield", env, mode)
				and RandomEvents.available_for_map("bounty", env, mode) == (mode == MatchMode.Kind.CAPTURE), "event conditions: %s / %d" % [env, mode])

func _attachments() -> void:
	var w = BugReportScript.new()
	root.add_child(w)
	await process_frame
	ck(w._text.placeholder_text.is_empty() and w._send_match.disabled, "menu report starts without example text or a current match")
	var img := Image.create(12, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	img.save_png("user://issues6-shot.png")
	ck(w._load_attachment("screenshot", "user://issues6-shot.png"), "external screenshot loads")
	var replay := {"kind": "replay", "start": {}, "steps": [], "combat_log": "Saved match log"}
	ReplayFile.write("user://issues6-match.mcfr", replay)
	ck(w._load_attachment("replay", "user://issues6-match.mcfr") and w._combat_log == "Saved match log", "compressed replay and included combat log attach from menu")
	var file := FileAccess.open("user://issues6-combat.txt", FileAccess.WRITE)
	file.store_string("A different combat log")
	file.close()
	ck(w._load_attachment("combat_log", "user://issues6-combat.txt") and w._combat_log == "A different combat log", "combat log can be replaced independently")
	ck(not w._load_attachment("replay", "user://issues6-combat.txt") and w._combat_log == "A different combat log", "invalid attachments leave previous selections intact")
	w._text.text = "A report prepared locally for testing"
	var payload: Dictionary = w.payload()
	ck(payload.has("screenshot") and payload.has("replay") and payload.combat_log == "A different combat log", "selected external attachments enter payload without sending it")
	w._send_match.button_pressed = false
	ck(not w.payload().has("combat_log") and not w.payload().has("replay"), "unchecked external attachments stay out of payload")
	w.free()

func _interface() -> void:
	var keys := root.get_node("Keybinds")
	keys.reset_defaults("user://issues6-keys.cfg")
	ck(not keys.codes("game_end_turn").has(KEY_ENTER) and keys.codes("game_end_turn").has(KEY_MASK_SHIFT | KEY_ENTER), "end turn is configurable and not bound to Enter")
	var settings = SettingsScript.open(root)
	settings._tabs.current_tab = 1
	await process_frame
	await process_frame
	var tab: Control = settings._key_sections.get_current_tab_control()
	var actions := tab.get_child(tab.get_child_count() - 1) as ScrollContainer
	ck(actions.size.y > 110 and actions.get_global_rect().end.y >= tab.get_global_rect().end.y - 2, "Actions expands to the bottom of the shortcuts tab")
	settings.free()
	ck(keys.rebind("game_end_turn", keys.key_event(KEY_F10), "user://issues6-keys.cfg") == "", "end-turn shortcut can be reassigned")
	keys.load_bindings("user://issues6-keys.cfg")
	ck(keys.codes("game_end_turn").has(KEY_F10), "end-turn shortcut survives settings reload")
	keys.reset_defaults("user://issues6-keys.cfg")
	var main = MainScript.new()
	main.state = state_of(MapData.blank_arena(16, 12))
	var row: Control = main._camera_row()
	root.add_child(row)
	await process_frame
	var grid := row.get_child(0).get_child(1) as GridContainer
	ck(grid != null and grid.columns == 3 and grid.get_child(0).size.x == grid.get_child(0).size.y, "camera uses aligned square buttons")
	row.free()
	main.free()

func _shortcut() -> void:
	var keys := root.get_node("Keybinds")
	ck(keys.codes("game_fullscreen").has(KEY_F11), "F11 is the default fullscreen shortcut")
	var path := "user://reported-issues-keybind-test.cfg"
	var key: InputEventKey = keys.key_event(KEY_MASK_CTRL | KEY_F11)
	key.pressed = true
	ck(keys.rebind("game_fullscreen", key, path).is_empty(), "fullscreen shortcut can be rebound")
	keys.load_bindings(path)
	ck(keys.matches(key, "game_fullscreen") and not keys.matches(keys.key_event(KEY_F11), "game_fullscreen"), "rebound fullscreen shortcut persists and replaces F11")
	var ui := root.get_node("Ui")
	var was_fullscreen: bool = ui.fullscreen
	keys._unhandled_key_input(key)
	ck(ui.fullscreen != was_fullscreen, "rebound shortcut actually toggles fullscreen")
	keys._unhandled_key_input(key)
	ck(ui.fullscreen == was_fullscreen, "fullscreen shortcut also restores windowed mode")
	keys.load_bindings("user://no-such-default-bindings.cfg")
	DirAccess.remove_absolute(path)

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

func add(r: GameActionResolver, kind: String, c: Vector2i, side: int = 0) -> UnitInstance:
	return r.state.spawn_unit(load("res://src/data/units/%s.tres" % kind), c, side)

func waves() -> void:
	var r := arena()
	r.mode.kind = MatchMode.Kind.HOLDOUT
	r.mode.wave_side = 1
	var shield := add(r, "shield_bearer", Vector2i(8, 5), 1)
	var shooter := r.state.grid.cell(Vector2i(2, 5)).occupant
	ck(not r._shield_blocks_shot(shooter, shield) and not r.is_fireproof(shield), "Holdout soldiers have no shield or fire immunity")
	var flame := add(r, "flamethrower", Vector2i(9, 5), 1)
	ck(not r.is_fireproof(flame), "Holdout flamethrowers have no fire immunity")
	ck(not r._flame_blocked(shield.coord), "Holdout shields do not stop flame spread")
	r.mode.excluded_units.assign(GameActionResolver.ARMY_ROSTER)
	r.mode.excluded_units.erase("light_infantry")
	r.mode.defender_value = 300
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	var first := r.state.all_units().filter(func(u: UnitInstance) -> bool: return u.neutral_group == 1)
	ck(not first.is_empty() and first.all(func(u: UnitInstance) -> bool: return u.stats.id == "light_infantry"), "Holdout restrictions apply to actual arrivals")
	r.random_events.excluded_units.assign(GameActionResolver.ARMY_ROSTER)
	ck(r._independent_roster().is_empty(), "all raider types can be excluded without fallback spawns")
	r.mode.pending_wave = {"edge": 2, "along": 8}
	r._land_wave(ActionResult.success([]))
	var display = load("res://scenes/Main.gd").new()
	display.state = r.state
	display.resolver = r
	var w1 := MCF.wave_slot(1)
	var w2 := MCF.wave_slot(2)
	ck(r.state.turns.round_order.has(w1) and r.state.turns.round_order.has(w2)
			and display._side_label(w1) == "Wave I" and display._side_label(w2) == "Wave II",
			"Initiative lists waves separately by arrival")
	display.free()
	r.random_events.excluded_units.erase("light_infantry")
	r._land_army({"edge": 1, "along": 10}, ActionResult.success([]))
	var raiders := r.state.all_units().filter(func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner))
	ck(not raiders.is_empty() and raiders.all(func(u: UnitInstance) -> bool: return u.stats.id == "light_infantry" and u.neutral_group == 1), "raider arrivals respect exclusions and receive Roman group numbers")
	var rules := StateCodec.encode_rules(r)
	var loaded := GameActionResolver.new(StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state)))) )
	StateCodec.apply_rules(loaded, JSON.parse_string(JSON.stringify(rules)))
	ck(loaded.mode.wave_sizes == r.mode.wave_sizes and loaded.mode.excluded_units == r.mode.excluded_units and loaded.random_events.excluded_units == r.random_events.excluded_units, "wave groups and independent restrictions survive JSON save/load")

func spawn_controls() -> void:
	GameConfig.holdout_excluded_units = []
	GameConfig.raider_excluded_units = []
	var lobby = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	for waves in [true, false]:
		lobby._open_spawn_restrictions(waves)
		var dialog := lobby.get_child(lobby.get_child_count() - 1) as AcceptDialog
		var checks := dialog.find_children("*", "CheckBox", true, false)
		ck(checks.size() == GameActionResolver.ARMY_ROSTER.size(), "spawn restriction dialog lists all soldier types")
		(checks[0] as CheckBox).button_pressed = false
		ck((GameConfig.holdout_excluded_units if waves else GameConfig.raider_excluded_units).has(GameActionResolver.ARMY_ROSTER[0]), "unticking a soldier excludes it from this mode")
		dialog.free()
	var encoded := NetHandoff.encode_rules()
	GameConfig.holdout_excluded_units = []
	GameConfig.raider_excluded_units = []
	NetHandoff.apply_rules(JSON.parse_string(JSON.stringify(encoded)))
	ck(GameConfig.holdout_excluded_units == [GameActionResolver.ARMY_ROSTER[0]] and GameConfig.raider_excluded_units == GameConfig.holdout_excluded_units, "spawn restrictions reach network guests")
	GameConfig.holdout_excluded_units = []
	GameConfig.raider_excluded_units = []
	lobby.queue_free()
	await process_frame

func _chat_text_is_escaped() -> void:
	ck(ChatBox.escape("[b]boom[/b]") == "[lb]b]boom[lb]/b]", "chat text can't inject BBCode")
