extends SceneTree
## 0.12 batch: game modes (Capture & Hold, Holdout and its wave timing), the seven new random
## events, the Manual, the keyboard diagram, the bug report payload and American spelling of
## everything players read. Interface classes are loaded at run time: they use autoloads
## (Ui, Keybinds) that a --script run compiles after this file.

const ArmyBuilder := preload("res://rl/ArmyBuilder.gd")

var fails: PackedStringArray = []
func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond: fails.append(what)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_zone_placement()
	_capture_scoring()
	_holdout_waves()
	_mode_survives_saves()
	_events()
	_emp_vehicles()
	_roster_waves()
	_manual()
	await _keyboard()
	await _bug_report()
	_american_spelling()
	_game_folders()
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	print("batch 0.12: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

func _map(style: int, seed: int, w := 40, h := 30, units := 8) -> MapData:
	var arng := RandomNumberGenerator.new()
	arng.seed = seed
	var m := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": w, "height": h,
			"density": 1, "seed": seed, "zones": 2, "units": units * 2 + 4, "civilians": 0, "civilian_count": 0})
	ArmyBuilder.populate(m, arng, units, 0)
	return m

func _resolver(m: MapData, mode: int, roster: Roster = null) -> GameActionResolver:
	GameConfig.game_mode = mode
	var st := m.build_state(4242, roster)
	var r := GameActionResolver.new(st)
	r.random_events = RandomEvents.new(false)
	r.update_airlocks()
	r.prepare_mode(m)
	return r

## Zones sit on open ground, never inside a deployment zone, and are (nearly) equally far
## from every side by walking distance — on a field, a town and a cramped bunker alike.
func _zone_placement() -> void:
	for style in [MapGen.Style.FIELD, MapGen.Style.TOWN, MapGen.Style.BUNKER]:
		var m := _map(style, 7 + style)
		var g := Grid.new(m.width, m.height)
		m.apply_to_grid(g)
		var zones := MatchMode.zones_for(m, 3, [0, 1], g)
		var name: String = MapGen.STYLE_NAMES[style]
		# A cramped bunker may get fewer zones: fairness is never traded for count.
		var want := 1 if style == MapGen.Style.BUNKER else 3
		ck(zones.size() >= want and zones.size() <= 3, "%s: zones placed (%d)" % [name, zones.size()])
		var open_ok := true
		var deploy_free := true
		for z in zones:
			var walkable := 0
			for y in range(int(z[1]), int(z[1]) + int(z[3])):
				for x in range(int(z[0]), int(z[0]) + int(z[2])):
					if g.cell_fast(x, y).walkable_terrain(): walkable += 1
					if m.get_zone(Vector2i(x, y)) >= 0: deploy_free = false
			open_ok = open_ok and walkable * 10 >= int(z[2]) * int(z[3]) * 6
		ck(open_ok, "%s: every zone is mostly open, walkable ground" % name)
		ck(deploy_free, "%s: no zone overlaps a deployment zone" % name)
		# Fairness: steps from each side's deployment zone to the zone's centre.
		var fair := true
		var spreads := []
		for z in zones:
			var c := Vector2i(int(z[0]) + int(z[2]) / 2, int(z[1]) + int(z[3]) / 2)
			var d := []
			for side in [0, 1]:
				var seeds := PackedInt32Array()
				for zc: Vector2i in m.zone_cells(side):
					if g.cell_fast(zc.x, zc.y).walkable_terrain():
						seeds.append((zc.y + 1) * (g.width + 2) + zc.x + 1)
				d.append(AIController.wave(g, seeds, {}).at(c))
			var spread := absi(int(d[0]) - int(d[1]))
			spreads.append(spread)
			fair = fair and spread <= 3 + int((int(d[0]) + int(d[1])) * 0.04)
		ck(fair, "%s: zones are fair to both sides (step differences %s)" % [name, spreads])

## Round-end scoring: more soldiers holds, a tie holds nothing, points race to the target,
## and wiping out the enemy still wins outright.
func _capture_scoring() -> void:
	GameConfig.capture_zones = 1
	GameConfig.capture_target = 3
	var m := _map(MapGen.Style.FIELD, 31)
	var r := _resolver(m, MatchMode.Kind.CAPTURE)
	var st := r.state
	var rect := r.mode.zone_rect(0)
	var foot := func(u: UnitInstance) -> bool: return not u.is_drone and u.aboard_vehicle_id == -1 and st.grid.in_bounds(u.coord)
	var a: Array = st.living_units_of(0).filter(foot)
	var b: Array = st.living_units_of(1).filter(foot)
	var free: Array[Vector2i] = []
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := st.grid.cell(Vector2i(x, y))
			if c.walkable_terrain() and c.occupant == null and c.vehicle_id == -1: free.append(Vector2i(x, y))
	ck(free.size() >= 3, "the zone has room for a test (%d free cells)" % free.size())
	st.grid.move_occupant(a[0].coord, free[0])
	st.grid.move_occupant(a[1].coord, free[1])
	st.grid.move_occupant(b[0].coord, free[2])
	var res := ActionResult.success([])
	r._mode_round_end(res)
	var ka := MatchMode.team_key(st.roster, 0)
	ck(r.mode.holders[0] == ka and int(r.mode.scores[ka]) == 1, "two against one holds the zone and scores 1")
	r._kill(a[1], null, a[1].coord)
	r._mode_round_end(ActionResult.success([]))
	ck(r.mode.holders[0] == "" and int(r.mode.scores[ka]) == 1, "one against one: a tie scores nothing")
	ck(not r.match_outcome()["over"], "no winner below the target")
	r.mode.scores[ka] = 3
	var out := r.match_outcome()
	ck(out["over"] and out["winner"] == ka and out["reason"] == "points", "reaching the target wins on points")
	r.mode.scores[ka] = 0
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	out = r.match_outcome()
	ck(out["over"] and out["reason"] == "rout", "wiping out the enemy still wins outright")

## Waves come every two rounds, or straight after the previous wave is wiped out (owner rule);
## all waves held wins, the defenders falling loses.
func _holdout_waves() -> void:
	var m := _map(MapGen.Style.FIELD, 41)
	m.spawns = m.spawns.filter(func(s: Dictionary) -> bool: return int(s["owner"]) != 1)
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	var r := _resolver(m, MatchMode.Kind.HOLDOUT, ro)
	r.mode.waves_total = 3   # the lobby offers 5/10/15/Endless; three keeps the test short
	var st := r.state
	ck(r.mode.wave_side == 1 and st.roster.team_of(0) == 0 and st.roster.team_of(1) == 1,
			"the waves side is its own team; the defenders share one")
	ck(st.turns.round_order.has(1), "the waves slot is in the turn order from the start")
	var res := r.open_match()
	ck(not r.mode.pending_wave.is_empty(), "wave 1 is announced in round 1")
	ck(not r.match_outcome()["over"], "an empty waves side is not a defeat")
	_end_round(r)
	ck(r.mode.wave == 1 and r.wave_fighters_left() > 0, "wave 1 lands at the end of round 1 (%d fighters)" % r.wave_fighters_left())
	ck(r.mode.pending_wave.is_empty() and r.mode.next_wave_round == 3, "the next wave is due in round 3")
	# Round 2: wipe wave 1 out mid-round — the next one is called at once, not in round 3.
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	ck(_any_move(r), "a defender action resolves after the wave is wiped")
	ck(st.turns.round_number == 2 and not r.mode.pending_wave.is_empty(),
			"wiping a wave out calls the next one straight away (round %d)" % st.turns.round_number)
	_end_round(r)
	ck(r.mode.wave == 2, "wave 2 landed early, at the end of round 2 (wave %d)" % r.mode.wave)
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	_any_move(r)
	_end_round(r)
	for u: UnitInstance in st.living_units_of(1):
		r._kill(u, null, u.coord)
	var out := r.match_outcome()
	ck(r.mode.wave == 3 and out["over"] and out["reason"] == "held", "all three waves beaten: the defenders win (%s)" % [out])
	# Overrun: defenders gone while waves remain.
	var r2 := _resolver(m, MatchMode.Kind.HOLDOUT, ro)
	r2.open_match()
	_end_round(r2)
	for u: UnitInstance in r2.state.living_units_of(0):
		r2._kill(u, null, u.coord)
	out = r2.match_outcome()
	ck(out["over"] and out["reason"] == "overrun", "the defenders falling is an overrun")
	ck(r2.mode.wave_budget(2) > r2.mode.wave_budget(1), "each wave is bigger than the last")

## One legal move for the side to act (any defender, any free neighbouring cell).
func _any_move(r: GameActionResolver) -> bool:
	# The (now empty) waves side may be the one to act: pass to the defenders first.
	var round := r.state.turns.round_number
	while r.state.active_player() != 0 and r.state.turns.round_number == round:
		r.resolve(EndTurnIntent.new())
	var side := r.state.active_player()
	for u: UnitInstance in r.state.living_units_of(side):
		if u.is_drone or u.aboard_vehicle_id != -1 or not r.state.grid.in_bounds(u.coord):
			continue
		for n: Vector2i in r.state.grid.neighbors(u.coord):
			if not r.state.grid.blocks_walk(n) and r.resolve(MoveIntent.new(u.id, n)).ok:
				return true
	return false

## Play end-turns until the round number goes up.
func _end_round(r: GameActionResolver) -> void:
	var round := r.state.turns.round_number
	for i in 8:
		r.resolve(EndTurnIntent.new())
		if r.state.turns.round_number > round:
			return

func _mode_survives_saves() -> void:
	GameConfig.capture_zones = 3
	GameConfig.capture_target = 12
	var r := _resolver(_map(MapGen.Style.TOWN, 51), MatchMode.Kind.CAPTURE)
	r.mode.scores[MatchMode.team_key(r.state.roster, 0)] = 5
	r.mode.holders = ["s0", "", "s1"]
	r.mode.bounty_unit = 7
	r.mode.bounty_until = 4
	var rules := StateCodec.encode_rules(r)
	var copy := GameActionResolver.new(r.state)
	StateCodec.apply_rules(copy, JSON.parse_string(JSON.stringify(rules)))
	ck(JSON.stringify(copy.mode.snapshot()) == JSON.stringify(r.mode.snapshot()),
			"zones, scores, holders and the bounty survive a save (and the wire)")
	var old := GameActionResolver.new(r.state)
	StateCodec.apply_rules(old, {})
	ck(old.mode.kind == MatchMode.Kind.ANNIHILATION, "an old save without a mode plays annihilation")

func _events() -> void:
	var r := _resolver(_map(MapGen.Style.TOWN, 21, 40, 30, 8), MatchMode.Kind.CAPTURE)
	r.random_events = RandomEvents.new(true, true, 1)
	var allowed := r._events_allowed()
	ck(allowed.has("dust") and allowed.has("minefield") and allowed.has("bounty") and allowed.has("fire"),
			"a town in Capture & Hold allows dust, the old minefield, the bounty and fire")
	# Fire: lit at the end of the round, then spreads once a round.
	var p := r._roll_event_params(RandomEvents.FIRE)
	r.random_events.announce(RandomEvents.FIRE, p, 1)
	r.land_random_events(ActionResult.success([]))
	var lit := _burning(r)
	ck(lit > 0, "the fire outbreak lights its zone (%d cells)" % lit)
	r.land_random_events(ActionResult.success([]))
	ck(_burning(r) >= lit, "event fire keeps spreading at round ends")
	# Dust: +1 to the roll needed beyond 3 cells, two rounds, one storm at a time.
	r.random_events.announce(RandomEvents.DUST, r._roll_event_params(RandomEvents.DUST), 1)
	r.land_random_events(ActionResult.success([]))
	ck(r.hit_need(6, 12.0) == mini(7, Combat.hit_number(6, 12.0) + 1) and r.hit_need(3, 12.0) == Combat.hit_number(3, 12.0),
			"dust storm: shots beyond 3 cells need one more")
	ck(not r._events_allowed().has("dust"), "no second dust storm while one blows")
	r.land_random_events(ActionResult.success([]))
	r.land_random_events(ActionResult.success([]))
	ck(r.random_events.dust_left == 0, "the dust storm blows over after two rounds")
	# Collapse.
	var walls := r._collapse_walls().size()
	r.random_events.announce(RandomEvents.COLLAPSE, r._roll_event_params(RandomEvents.COLLAPSE), 1)
	r.land_random_events(ActionResult.success([]))
	ck(r._collapse_walls().size() < walls, "a structural collapse brings walls down")
	# Reinforcements go to the side that is behind.
	for u: UnitInstance in r.state.living_units_of(1).slice(0, 4):
		r._kill(u, null, u.coord)
	var before := r.state.living_units_of(1).size()
	ck(int(r._reinforce_target().get("side", -1)) == 1, "reinforcements pick the weaker side")
	r.random_events.announce(RandomEvents.REINFORCE, r._roll_event_params(RandomEvents.REINFORCE), 1)
	r.land_random_events(ActionResult.success([]))
	ck(r.state.living_units_of(1).size() > before, "reinforcements land")
	# Bounty: 2 points to the enemy who kills the marked soldier.
	r._start_bounty(ActionResult.success([]))
	var target := r.state.get_unit(r.mode.bounty_unit)
	ck(target != null, "the bounty marks a soldier")
	var killer := 1 - target.owner
	var key := MatchMode.team_key(r.state.roster, killer)
	var pts := int(r.mode.scores.get(key, 0))
	r._kill(target, null, target.coord)
	r._check_bounty(ActionResult.success([]), killer)
	ck(int(r.mode.scores.get(key, 0)) == pts + 2 and r.mode.bounty_unit == -1, "a bounty kill scores 2 points")
	# Old minefield: outdoors only, hidden from everyone, no location in the report.
	var mres := ActionResult.success([])
	r._start_minefield(mres)
	var mines: Array[Vector2i] = []
	for y in r.state.grid.height:
		for x in r.state.grid.width:
			var c := r.state.grid.cell_fast(x, y)
			if c.feature_id == MCF.FEATURE_MINE and c.feature_owner == GameActionResolver.OLD_MINE_OWNER:
				mines.append(Vector2i(x, y))
	var outdoors := not mines.is_empty()
	for c in mines:
		var cell := r.state.grid.cell(c)
		outdoors = outdoors and cell.floor_type != MCF.FLOOR_FLAMMABLE \
				and r.state.grid.floor_look[c.y * r.state.grid.width + c.x] == 0
	ck(outdoors, "old mines lie outdoors (%d of them)" % mines.size())
	ck(not r.mine_visible_to(0, mines[0]) and not r.mine_visible_to(1, mines[0]), "nobody sees the old mines")
	ck(str(mres.log_lines).find("(") < 0, "the minefield report gives no location")
	var goes := 0
	for i in 60:
		r.state.grid.cell(mines[0]).set_feature(MCF.FEATURE_MINE, GameActionResolver.OLD_MINE_OWNER)
		if r._mine_on_path(null, [mines[0]]) != GameActionResolver.NOWHERE: goes += 1
	ck(goes > 5 and goes < 40, "an old mine goes off only some of the time (%d of 60)" % goes)
	# Where events may happen.
	var st := _resolver(_map(MapGen.Style.STATION, 22), MatchMode.Kind.ANNIHILATION)
	st.random_events = RandomEvents.new(true, true, 1)
	var sa := st._events_allowed()
	ck(not sa.has("dust") and not sa.has("minefield") and not sa.has("bounty"), "a station: no dust, minefield or bounty")
	var ast := _resolver(_map(MapGen.Style.ASTEROID, 23), MatchMode.Kind.ANNIHILATION)
	ast.random_events = RandomEvents.new(true, true, 1)
	ck(ast._events_allowed().has("minefield") and not ast._events_allowed().has("dust"), "an asteroid: minefield yes, dust no")

## Owner (0.12): EMP bursts target vehicles — the zone is centered on a vehicle (crewed ones
## first), and its gun takes the damage.
func _emp_vehicles() -> void:
	var arng := RandomNumberGenerator.new()
	arng.seed = 61
	var m := MapGen.generate({"style": MapGen.Style.FIELD, "size": MapGen.SIZE_CUSTOM, "width": 44, "height": 34,
			"density": 0, "seed": 61, "zones": 2, "units": 24, "civilians": 0, "civilian_count": 0})
	ArmyBuilder.populate(m, arng, 8, 1, 1)
	var r := _resolver(m, MatchMode.Kind.ANNIHILATION)
	r.random_events = RandomEvents.new(true, true, 1)
	ck(not r.state.all_vehicles().is_empty(), "the test map has a vehicle")
	ck(r._events_allowed().has("emp"), "EMP is possible with a vehicle on the field")
	var p := r._roll_event_params(RandomEvents.EMP)
	var rect := Rect2i(int(p["x"]), int(p["y"]), int(p["w"]), int(p["h"]))
	var aimed: Vehicle = null
	for veh: Vehicle in r.state.all_vehicles():
		if veh.alive() and rect.has_point(veh.center()):
			aimed = veh
	ck(aimed != null, "the EMP zone is centered on a vehicle")
	var gun_before := aimed.component(MCF.COMP_GUN) if aimed != null and aimed.has_component(MCF.COMP_GUN) else -1
	r.random_events.announce(RandomEvents.EMP, p, 1)
	r.land_random_events(ActionResult.success([]))
	if gun_before > 0:
		ck(aimed.component(MCF.COMP_GUN) < gun_before, "the EMP damages that vehicle's gun")
	var bare := _resolver(_map(MapGen.Style.FIELD, 62), MatchMode.Kind.ANNIHILATION)
	bare.random_events = RandomEvents.new(true, true, 1)
	var has_gear := not bare.state.all_vehicles().is_empty() or not bare._emp_targets().is_empty()
	ck(bare._events_allowed().has("emp") == has_gear, "with nothing electronic on the field there is no EMP")

func _burning(r: GameActionResolver) -> int:
	var n := 0
	for y in r.state.grid.height:
		for x in r.state.grid.width:
			if r.state.grid.cell_fast(x, y).on_fire: n += 1
	return n

func _roster_waves() -> void:
	var ro := Roster.default_duel(true)
	ck(ro.set_waves(2), "a waves slot fits")
	ck(ro.set_waves(3), "setting it again replaces it")
	var waves := ro.waves_side()
	ck(waves == 2 and ro.slots.size() == 3 and ro.slots[2].display_name == "Waves",
			"one waves slot, last in the roster")
	ck(ro.slots[2].ai_difficulty == 3, "AI - Learned can lead the waves")
	ck(ro.team_of(0) == 0 and ro.team_of(1) == 0 and ro.team_of(2) == 1, "players defend together")
	var back := Roster.from_dict(ro.to_dict())
	ck(back.waves_side() == 2, "the waves role travels with the roster")
	ro.strip_waves()
	ck(ro.waves_side() == -1 and ro.slots.size() == 2, "stripping removes the waves slot")

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
		cards_ok = cards_ok and text.UNIT_BLURBS.has(id) and ResourceLoader.exists("res://src/data/units/%s.tres" % id)
	ck(cards_ok, "every unit card has data and a description")
	var keys: Node = root.get_node("/root/Keybinds")
	ck(keys.codes("game_manual").has(KEY_F1) and keys.codes("editor_manual").has(KEY_F2),
			"F1 opens the Manual in the game, F2 in the editor")

func _keyboard() -> void:
	var kb: Control = load("res://src/ui/KeyboardDiagram.gd").new()
	root.add_child(kb)
	await process_frame
	kb.section = "game"
	var n: String = kb.tooltip_for(KEY_N, "N")
	ck(n.find("Lay mine") >= 0 and n.find("Build fortification") >= 0 and n.find("Launch drone") >= 0,
			"the N key lists all three of its actions")
	ck(kb._state(KEY_S) == 3, "S is used alone (pan) and in a combination (Ctrl+S)")
	ck(kb._state(KEY_CTRL) == 2 and kb.tooltip_for(KEY_CTRL, "Ctrl").find("Ctrl+S") >= 0, "Ctrl lists its combinations")
	ck(kb.tooltip_for(KEY_F11, "F11").ends_with("Not used"), "a free key says so")
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
