extends SceneTree

var fails: Array[String] = []
var MainScript: GDScript
var ManualWindowScript: GDScript
var ManualTextScript: GDScript
var BugReportScript: GDScript
var SettingsScript: GDScript
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
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
	_fire()
	for weapon in ["anti_tank", "tank"]:
		for roll in [1, 6]: _held_terrain(weapon, roll)
	await _attachments()
	await _interface()
	await _space_boundary()
	await _shot_screen()
	print("PDF 6: %d failure(s)" % fails.size())
	quit(0 if fails.is_empty() else 1)

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

func _fire() -> void:
	var m := MapData.blank_arena(16, 12)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(10, 5), "heavy_infantry", 1)
	var st := state_of(m)
	var r := GameActionResolver.new(st)
	var shooter := st.grid.cell(Vector2i(2, 5)).occupant
	var target := st.grid.cell(Vector2i(10, 5)).occupant
	var need := r.hit_need_for(shooter, target)
	var pane := r.pane_hit_need(shooter, Vector2i(10, 5))
	st.grid.cell(Vector2i(6, 5)).on_fire = true
	var mods := []
	ck(r.hit_need_for(shooter, target, mods) == need and r.pane_hit_need(shooter, Vector2i(10, 5)) == pane and not str(mods).contains("Fire"), "burning cells do not modify unit or glass hit rolls")

	st.grid.cell(Vector2i(3, 5)).set_feature(MCF.FEATURE_DPMG, 0)
	var recorder := ReplayRecorder.new()
	recorder.begin(st, r)
	r.replay_recorder = recorder
	var rolls: Array = []
	for burning in [false, true]:
		st.grid.cell(Vector2i(6, 5)).on_fire = burning
		shooter.remaining_ap = 2
		st.dice.feed_scripted([6, 6])
		var res := r.resolve(DPMGFireIntent.new(shooter.id, Vector2i(3, 5), target.id, 1))
		ck(res.ok, "DPMG shot resolves with fire=%s" % burning)
		var attacks := res.dice_events.filter(func(ev): return ev.has("need"))
		if not attacks.is_empty(): rolls.append(attacks[0].need)
	ck(rolls.size() == 2 and rolls[0] == rolls[1], "DPMG firing through fire uses the same hit number")
	ck(not str(recorder.to_dict().get("combat_log", "")).is_empty(), "new replays contain their recorded combat text")

func terrain_bytes(grid: Grid) -> Array:
	var tiles := TerrainTiles.new(grid, "station")
	tiles._build(Vector2i.ZERO, 32)
	var chunk: Dictionary = tiles._chunks[Vector3i(0, 0, 32)]
	return [chunk.floor.get_image().get_data(), chunk.feat.get_image().get_data()]

func _held_terrain(weapon: String, roll: int) -> void:
	var m := MapData.blank_arena(16, 12)
	m.env = "station"
	m.set_spawn(Vector2i(2, 4) if weapon == "tank" else Vector2i(3, 5), weapon, 0, Vector2i.RIGHT)
	if weapon == "tank": m.set_spawn(Vector2i(1, 4), "engineer", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	for y in range(2, 10):
		m.set_cell(Vector2i(10, y), 0, 2.0, false, MCF.FEATURE_AIRLOCK if y == 6 else MCF.FEATURE_WALL)
		m.set_look(y * m.width + 10, MCF.wall_look(1) if y < 5 else 0)
	var st := state_of(m)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	var actor := st.grid.cell(Vector2i(3, 5)).occupant if weapon != "tank" else st.grid.cell(Vector2i(1, 4)).occupant
	var intent: Intent
	if weapon == "tank":
		var tank: Vehicle = st.all_vehicles()[0]
		ck(r.resolve(VehicleBoardIntent.new(actor.id, tank.id)).ok, "tank crew boards")
		tank.ap = 3
		intent = VehicleCannonIntent.new(tank.id, Vector2i(10, 5))
	else: intent = ShootIntent.new(actor.id, -1, -1, Vector2i(10, 5))
	r.update_airlocks()
	var before := terrain_bytes(st.grid)
	var before_seen := r.team_visible_coords(0).duplicate()
	st.dice.feed_scripted([roll, 6, 6, 6, 6, 6])
	var res := r.resolve(intent)
	ck(res.ok and not res.visual_hold.is_empty(), "%s roll %d captures the terrain" % [weapon, roll])
	if not res.ok: return
	var main = MainScript.new()
	main._hold_visual = res.visual_hold
	var digest := st.digest_hash()
	var logs := GridCell.logs_snapshot()
	var held: Grid = main._terrain_before_impact(st.grid, {}, false)
	ck(terrain_bytes(held) == before, "%s roll %d preserves every rendered floor, wall material, neighbour join and door before impact" % [weapon, roll])
	ck(st.digest_hash() == digest and GridCell.logs_snapshot() == logs, "presentation snapshot never mutates game state or journals")
	ck(res.visual_hold.get("visible", {}).get(0) == before_seen, "shot holds pre-impact fog visibility")
	ck(held.cell(Vector2i(10, 6)).feature_id == MCF.FEATURE_AIRLOCK and held.cell(Vector2i(10, 6)).is_wall(), "held airlock stays closed")
	main._hold_visual = {}
	ck(main._terrain_before_impact(st.grid, {}, false) == st.grid, "impact releases the complete live terrain")
	main.free()

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

func _space_boundary() -> void:
	var m := MapData.blank_arena(16, 12)
	m.env = "station"
	m.set_spawn(Vector2i(3, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	m.set_cell(Vector2i(15, 5), 0, 2.0, true, MCF.FEATURE_BOUNDARY)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	ck(not main._fx.solid_at.call(Vector2i(15, 5)) and not main._fx.solid_at.call(Vector2i(30, 5)) and main._fx.space_at.call(Vector2i(30, 5)), "space particles ignore invisible boundary and keep vacuum outside grid")
	main._fx.flying = [{"kind": "glass_shard", "from": Vector2(14.5, 5.5), "to": Vector2(17.5, 5.5), "t": 0.0, "dur": 1.0, "drift": true, "rot0": 0.0, "rot1": 1.0, "scale": 1.0}]
	var saved_fx: Dictionary = main._fx.to_dict()
	var checkpoint := ReplayCheckpoint.effects(main.state)
	checkpoint.from_dict(saved_fx)
	checkpoint.advance(100.0)
	ck(checkpoint.flying.size() == 1 and checkpoint.flying[0].origin == Vector2i(14, 5), "replay checkpoints preserve off-map drift and its visible origin")
	main._fx.advance(100.0)
	ck(main._fx.flying.size() == 1 and FxDecals.flight_pos(main._fx.flying[0]).x > 300, "debris drifts indefinitely beyond boundary")
	main.free()

func _shot_screen() -> void:
	root.get_node("Ui").autoroll_dice = false
	GameConfig.fog_mode = MCF.Fog.STANDARD
	var m := MapData.blank_arena(16, 12)
	m.env = "station"
	m.set_spawn(Vector2i(3, 5), "anti_tank", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	for y in range(2, 10): m.set_cell(Vector2i(10, y), 0, 2.0, false, MCF.FEATURE_AIRLOCK if y == 6 else MCF.FEATURE_WALL)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	var actor: UnitInstance = main.state.grid.cell(Vector2i(3, 5)).occupant
	main.state.dice.feed_scripted([6])
	main._on_intent_ready(ShootIntent.new(actor.id, -1, -1, Vector2i(10, 5)))
	await process_frame
	await process_frame
	ck(main._dice.visible and main._shown_grid.cell(Vector2i(10, 5)).is_wall(), "actual shot UI keeps wall intact while dice are shown")
	ck(main._shown_grid.cell(Vector2i(10, 6)).is_wall(), "actual shot UI keeps airlock closed before roll")
	var visible: Dictionary = main._visible_before_impact(0)
	main._lod_sync(true, 0, visible, true)
	ck(main._shown_grid.cell(Vector2i(10, 5)).is_wall(), "zoomed-out terrain also holds wall")
	if main._dice._roll_btn.visible: main._dice._roll_btn.pressed.emit()
	var deadline := Time.get_ticks_msec() + 10000
	while main._animating and Time.get_ticks_msec() < deadline: await process_frame
	await process_frame
	ck(not main._animating and main._hold_visual.is_empty() and not main._shown_grid.cell(Vector2i(10, 5)).is_wall(), "impact releases destroyed walls in actual playback")
	main.free()
	GameConfig.fog_mode = MCF.Fog.OFF
