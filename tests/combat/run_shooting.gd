extends "res://tests/SuiteBase.gd"
## Shooting: bursts finished at other targets, glass panes and windows, the sniper's ladder,
## shots through fire, recoil in space, lanes held before the dice, DPMG bursts, projectiles.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_burst()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_projectiles()

	_window_burst()
	_through_panes()

	_sniper_hit_ladder()

	MainScript = load("res://scenes/Main.gd")
	ManualWindowScript = load("res://src/ui/ManualWindow.gd")
	ManualTextScript = load("res://src/ui/ManualText.gd")
	BugReportScript = load("res://src/ui/BugReportWindow.gd")
	SettingsScript = load("res://src/ui/SettingsWindow.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.fog_mode = MCF.Fog.OFF
	_fire()

	lane_preview()
	dpmg_bursts()

	_glass_saves_bullets()
	_recoil_in_space()

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

## Shots show a flying projectile and their effects on impact (0.12.1 follow-up): the tank's
## lane points at the clicked cell (not where the shell will fall); the shell, the anti-tank
## rocket and the frag grenade fly to where they really land; the shotgun and the DPMG get
## bullet tracers. None of these take a board effect number.
func _projectiles() -> void:
	var tm := MapData.blank_arena(24, 12)
	tm.set_spawn(Vector2i(3, 5), "tank", 0, Vector2i(1, 0))
	tm.set_spawn(Vector2i(20, 10), "light_infantry", 1)
	var ts := tm.build_state(5)
	ts.turns.round_order = [0, 1]
	ts.turns.active_index = 0
	var r := GameActionResolver.new(ts)
	var tank: Vehicle = ts.all_vehicles()[0]
	var aim := Vector2i(14, 5)
	var short_seen := false
	var lanes_ok := true
	var shots_ok := true
	var reason := ""
	for attempt in 40:
		tank.ap = 9
		tank.cannon_shots_this_round = 0
		var seq := ts.fx_seq
		var res := r.resolve(VehicleCannonIntent.new(tank.id, aim))
		if not res.ok:
			reason = res.reason
			break
		var lane := res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "lane")
		var shot := res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "shot")
		lanes_ok = lanes_ok and lane.size() == 1 and Vector2i(int(lane[0]["to"][0]), int(lane[0]["to"][1])) == aim
		shots_ok = shots_ok and shot.size() == 1 and shot[0]["kind"] == "shell" and not shot[0].has("seq")
		if not shot.is_empty() and Vector2i(int(shot[0]["to"][0]), int(shot[0]["to"][1])) != aim:
			short_seen = true
		if short_seen and attempt > 5:
			break
	ck(reason == "", "the tank fires (%s)" % reason)
	ck(lanes_ok, "the tank's lane always points at the clicked cell")
	ck(shots_ok, "each cannon shot flies a shell, without a board effect number")
	ck(short_seen, "a short shell flies to where it really lands, not to the aim")
	# Anti-tank rocket, frag grenade, shotgun and DPMG.
	var m := MapData.blank_arena(20, 14)
	m.set_spawn(Vector2i(3, 3), "anti_tank", 0)
	m.set_spawn(Vector2i(3, 6), "assault", 0)
	m.set_spawn(Vector2i(3, 10), "heavy_infantry", 0)
	m.set_spawn(Vector2i(6, 6), "light_infantry", 1)
	m.set_spawn(Vector2i(18, 13), "light_infantry", 1)
	var st := m.build_state(6)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r2 := GameActionResolver.new(st)
	var at: UnitInstance = st.grid.cell(Vector2i(3, 3)).occupant
	var ares := r2.resolve(ShootIntent.new(at.id, -1, -1, Vector2i(8, 3)))
	var rocket := ares.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "shot")
	ck(ares.ok and rocket.size() == 1 and rocket[0]["kind"] == "rocket", "the anti-tank shot flies a rocket")
	var asl: UnitInstance = st.grid.cell(Vector2i(3, 6)).occupant
	var sres := r2.resolve(ShootIntent.new(asl.id, st.grid.cell(Vector2i(6, 6)).occupant.id))
	ck(sres.ok and sres.fx.any(func(f: Dictionary) -> bool: return f.get("fx", "") == "tracer"), "the shotgun shows bullet tracers (%s)" % sres.reason)
	var hv: UnitInstance = st.grid.cell(Vector2i(3, 10)).occupant
	hv.held_item_id = MCF.ITEM_FRAG
	var gres := r2.resolve(UseItemIntent.new(hv.id, Vector2i(6, 10)))
	var lob := gres.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "shot")
	ck(gres.ok and lob.size() == 1 and lob[0]["kind"] == "grenade", "a frag grenade is lobbed (%s)" % gres.reason)
	ck(FxDecals.shot_dur({"kind": "rocket", "from": [0, 0], "to": [30, 0]}) <= FxDecals.SHOT_MAX
			and FxDecals.shot_dur({"kind": "grenade", "from": [0, 0], "to": [1, 0]}) >= FxDecals.SHOT_MIN, "flights stay short")
	var fx := FxDecals.new()
	fx.apply(ares.fx)
	ck(fx.shots.size() == 1, "the effects layer flies the rocket")
	for _i in 10:
		fx.advance(0.1)
	ck(fx.shots.is_empty(), "and lets it go once it lands")

func field(w: int, h: int, spawns: Array, feats: Dictionary = {}) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for c: Vector2i in feats:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, feats[c])
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r}

func _events(res: ActionResult, kind: String) -> Array:
	return res.dice_events.filter(func(e: Dictionary) -> bool: return e.get("kind", "") == kind)

## По окну — обычная очередь: игрок выбирает число пуль, остаток дострелить без ОД.
func _window_burst() -> void:
	var f := field(16, 6, [[Vector2i(2, 2), "heavy_infantry", 0], [Vector2i(14, 5), "light_infantry", 1]],
			{Vector2i(6, 2): MCF.FEATURE_ARMOR_GLASS})
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var hi := st.grid.cell(Vector2i(2, 2)).occupant
	var ap0 := hi.remaining_ap
	var rof := hi.rate_of_fire()
	var res := r.resolve(ShootIntent.new(hi.id, -1, 1, Vector2i(6, 2)))
	var g := _events(res, "glass")
	ck(res.ok and g.size() == 1 and (g[0]["hits"] as Array).size() == 1,
			"a window shot fires the chosen number of bullets (1 of %d)" % rof)
	ck(hi.remaining_ap == ap0 - 1 and hi.action_state != null and hi.action_state.remaining_shots == rof - 1,
			"…for 1 AP, and the rest of the burst stays")
	ck(int(g[0]["need"]) == r.pane_hit_need(hi, Vector2i(6, 2)) and int(g[0]["save"]) == 4,
			"the bullet rolls to hit the window by distance, armored glass saves on 4+")
	var saves := (g[0]["saves"] as Array).size()
	var hit_n := (g[0]["hits"] as Array).filter(func(h: Dictionary) -> bool: return h["hit"]).size()
	ck(saves == hit_n, "the glass saves only against bullets that hit it (%d hits, %d saves)" % [hit_n, saves])
	if MCF.is_glass(st.grid.cell(Vector2i(6, 2)).feature_id):
		var res2 := r.resolve(ShootIntent.new(hi.id, -1, -1, Vector2i(6, 2)))
		var g2 := _events(res2, "glass")
		ck(res2.ok and hi.remaining_ap == ap0 - 1 and g2.size() == 1 and (g2[0]["hits"] as Array).size() == rof - 1,
				"the rest of the burst goes at the window without another AP")
	# Окно бьётся, только если прошла хоть одна пуля; осколки — в событии броска.
	var broke := 0
	var held := 0
	for i in 40:
		var f2 := field(16, 6, [[Vector2i(2, 2), "heavy_infantry", 0], [Vector2i(14, 5), "light_infantry", 1]],
				{Vector2i(6, 2): MCF.FEATURE_GLASS})
		var st2: GameState = f2["s"]
		st2.dice = DiceService.new(500 + i)
		var u := st2.grid.cell(Vector2i(2, 2)).occupant
		var rr: ActionResult = f2["r"].resolve(ShootIntent.new(u.id, -1, -1, Vector2i(6, 2)))
		var ev: Dictionary = _events(rr, "glass")[0]
		var through := (ev["saves"] as Array).filter(func(sv: Dictionary) -> bool: return not sv["held"]).size()
		var gone := not MCF.is_glass(st2.grid.cell(Vector2i(6, 2)).feature_id)
		if gone != (through > 0) or bool(ev["broke"]) != gone or (gone and (ev["fx"] as Array).is_empty()):
			ck(false, "seed %d: the window breaks exactly when a bullet gets through" % (500 + i))
			return
		if gone:
			broke += 1
		else:
			held += 1
	ck(broke > 0 and held > 0, "the window breaks exactly when a bullet gets through (%d broke, %d held)" % [broke, held])

## Сквозь два стекла к цели: стекло за стеклом, промахи и удержанные пули теряются.
func _through_panes() -> void:
	var seen_two := false
	var seen_lost := false
	for i in 60:
		var f := field(20, 6, [[Vector2i(2, 2), "heavy_infantry", 0], [Vector2i(12, 2), "light_infantry", 1]],
				{Vector2i(5, 2): MCF.FEATURE_GLASS, Vector2i(8, 2): MCF.FEATURE_ARMOR_GLASS})
		var st: GameState = f["s"]
		st.dice = DiceService.new(900 + i)
		var r: GameActionResolver = f["r"]
		var hi := st.grid.cell(Vector2i(2, 2)).occupant
		var foe := st.grid.cell(Vector2i(12, 2)).occupant
		var res := r.resolve(ShootIntent.new(hi.id, foe.id))
		if not res.ok:
			ck(false, "shot through two panes resolves (%s)" % res.reason)
			return
		var g := _events(res, "glass")
		var atk: Array = _events(res, "attack")
		var order_ok: bool = not g.is_empty() and g[0]["cell"] == Vector2i(5, 2)
		var flying := hi.rate_of_fire()
		var chain_ok := true
		for ev: Dictionary in g:
			chain_ok = chain_ok and (ev["hits"] as Array).size() == flying
			flying = (ev["saves"] as Array).filter(func(sv: Dictionary) -> bool: return not sv["held"]).size()
		if g.size() == 1:
			chain_ok = chain_ok and flying == 0   # второе стекло не встретило ни одной пули
		var shots_at_target: int = (atk[0]["shots"] as Array).size() if not atk.is_empty() else -1
		if not (order_ok and chain_ok and shots_at_target == flying):
			ck(false, "seed %d: panes in order, each gets only the bullets the last let through, the target only the rest"
					% (900 + i))
			return
		if g.size() == 2:
			if not seen_two:
				ck(int(g[1]["save"]) == 4, "armored glass on the line now stops bullets too (saves 4+)")
			seen_two = true
		if flying < hi.rate_of_fire():
			seen_lost = true
		# Целое стекло — только если ни одна пуля его не прошла.
		for ev: Dictionary in g:
			var whole := MCF.is_glass(st.grid.cell(ev["cell"]).feature_id)
			if whole == bool(ev["broke"]):
				ck(false, "seed %d: a pane breaks exactly when a bullet passes it" % (900 + i))
				return
	ck(seen_two and seen_lost,
			"bullets reach the second pane only through the first, and the target only through both (60 seeds)")

func _field(spawns: Array, walls: Array = [], civ := false) -> Dictionary:
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for w: Vector2i in walls:
		m.set_cell(w, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = civ
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var guard := 0  # сторона может быть выбита первым же слотом жителей — не зацикливаемся
	while st.active_player() != MCF.Owner.PLAYER_1 and guard < 8:
		r.resolve(EndTurnIntent.new())
		guard += 1
	return {"s": st, "r": r}

func _u(st: GameState, c: Vector2i) -> UnitInstance:
	return st.grid.cell(c).occupant

## Лестница снайпера (§5): авто до 15, потом 2+/3+/4+/5+/6 по пятёркам, за 40 — никак.
## Границы полос ВЕРХНИЕ, поэтому проверяем и саму границу, и клетку за ней.
func _sniper_hit_ladder() -> void:
	var want := {1: 1, 10: 1, 15: 1, 16: 2, 20: 2, 21: 3, 25: 3, 26: 4, 30: 4,
			31: 5, 35: 5, 36: 6, 40: 6, 41: 7, 50: 7}
	for d: int in want:
		var got := Combat.sniper_hit_number(d)
		ck(got == want[d], "sniper needs %d+ at %d tiles (got %d)" % [want[d], d, got])
	# И то же через боевой путь, которым реально стреляют: цель на 20 клетках по прямой,
	# без укрытия и укреплений — 2+, а общая формула дала бы 3+.
	var f := _field([[Vector2i(2, 7), "sniper", MCF.Owner.PLAYER_1],
			[Vector2i(22, 7), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var sn := _u(st, Vector2i(2, 7))
	var tg := _u(st, Vector2i(22, 7))
	ck(r.hit_need_for(sn, tg) == 2,
			"sniper at 20 tiles needs 2+ (got %d)" % r.hit_need_for(sn, tg))
	var near := _field([[Vector2i(2, 7), "sniper", MCF.Owner.PLAYER_1],
			[Vector2i(16, 7), "light_infantry", MCF.Owner.PLAYER_2]])
	var st2: GameState = near["s"]
	var r2: GameActionResolver = near["r"]
	ck(r2.hit_need_for(_u(st2, Vector2i(2, 7)), _u(st2, Vector2i(16, 7))) == 1,
			"sniper auto-hits at 14 tiles")

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

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func _lane(from: Vector2i, to: Vector2i, weapon := "") -> Dictionary:
	var ev := {"fx": "lane", "from": [from.x, from.y], "to": [to.x, to.y], "owner": 0, "kind": "shot"}
	if weapon != "": ev["weapon"] = weapon
	return ev

func lane_preview() -> void:
	var fx := FxDecals.new()
	var events := [_lane(Vector2i(2, 2), Vector2i(8, 2))]
	fx.preview_lanes(events)
	ck(fx.lanes.size() == 1 and fx.lanes[0].get("hold", false), "the firing lane shows (held) before the dice")
	fx.apply_lanes(events)
	ck(fx.lanes.size() == 1 and not fx.lanes[0].has("hold"), "the shot takes over its previewed lane instead of drawing a second")

func dpmg_bursts() -> void:
	var map := arena()
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(10, 5), "heavy_infantry", 1)
	map.set_spawn(Vector2i(3, 12), "heavy_infantry", 1)
	var r := resolver_for(map)
	var st := r.state
	st.grid.cell(Vector2i(3, 5)).set_feature(MCF.FEATURE_DPMG, 0)
	var gunner: UnitInstance = st.grid.cell(Vector2i(2, 5)).occupant
	var guard := 0
	while st.active_player() != 0 and guard < 10:
		r.resolve(EndTurnIntent.new())
		guard += 1
	var east: UnitInstance = st.grid.cell(Vector2i(10, 5)).occupant
	var south: UnitInstance = st.grid.cell(Vector2i(3, 12)).occupant
	gunner.remaining_ap = 2
	st.dice.feed_scripted([1, 1, 1, 1, 1, 1, 1, 1])
	var res := r.resolve(DPMGFireIntent.new(gunner.id, Vector2i(3, 5), east.id, 3))
	ck(res.ok and gunner.remaining_ap == 1 and gunner.action_state != null
			and gunner.action_state.remaining_shots == MCF.DPMG_RATE_OF_FIRE - 3,
		"a DPMG fires the chosen number of rounds and keeps the rest of the burst")
	ck(st.grid.furniture_turn.get(Vector2i(3, 5), []) == [MCF.FEATURE_DPMG, 0], "the DPMG turns to the east target")
	st.dice.feed_scripted([1, 1, 1, 1, 1, 1, 1, 1])
	res = r.resolve(DPMGFireIntent.new(gunner.id, Vector2i(3, 5), south.id))
	ck(res.ok and gunner.remaining_ap == 1 and gunner.action_state == null,
		"the rest of the burst goes at another target without spending AP")
	ck(st.grid.furniture_turn.get(Vector2i(3, 5), []) == [MCF.FEATURE_DPMG, 2], "…and the gun turns south to it")

func field__batch_zones(w: int, h: int, spawns: Array, feats: Dictionary = {}, space: Array = []) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for c: Vector2i in feats:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, feats[c])
	for c: Vector2i in space:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, true, "")
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r}

## glass saves each bullet (5+), so a window can survive a burst
func _glass_saves_bullets() -> void:
	ck(MCF.glass_bullet_save(MCF.FEATURE_GLASS) == 5 and MCF.glass_bullet_save(MCF.FEATURE_ARMOR_GLASS) == 4,
			"glass holds on 5+, armored glass on 4+")
	var survived := 0
	var broke := 0
	for i in 30:
		var f := field__batch_zones(16, 6, [[Vector2i(2, 2), "light_infantry", 0], [Vector2i(14, 5), "light_infantry", 1]],
				{Vector2i(6, 2): MCF.FEATURE_GLASS})
		var st: GameState = f["s"]
		st.dice = DiceService.new(1000 + i)
		var li := st.grid.cell(Vector2i(2, 2)).occupant
		var res: ActionResult = f["r"].resolve(ShootIntent.new(li.id, -1, -1, Vector2i(6, 2)))
		if not res.ok:
			continue
		if st.grid.cell(Vector2i(6, 2)).feature_id == MCF.FEATURE_GLASS:
			survived += 1
		else:
			broke += 1
	ck(survived > 0 and broke > 0, "a window sometimes holds and sometimes breaks (%d held, %d broke)" % [survived, broke])

## recoil in space for every kind of shot, blocked when something is behind
func _recoil_in_space() -> void:
	for kind in ["light_infantry", "anti_tank", "flamethrower", "marksman"]:
		var sp: Array = []
		for x in range(0, 8):   # the shooter's end is space; the target cells are floor
			sp.append(Vector2i(x, 3))
		var f := field__batch_zones(16, 7, [[Vector2i(6, 3), kind, 0], [Vector2i(11, 3), "light_infantry", 1]], {}, sp)
		var st: GameState = f["s"]
		var u := st.grid.cell(Vector2i(6, 3)).occupant
		var res: ActionResult = f["r"].resolve(ShootIntent.new(u.id, -1, -1, Vector2i(9, 3)) if kind != "light_infantry"
				else ShootIntent.new(u.id, st.grid.cell(Vector2i(11, 3)).occupant.id))
		ck(res.ok and u.coord == Vector2i(5, 3), "%s in space recoils one cell back (%s, at %s)" % [kind, res.reason, u.coord])
	var spb: Array = []
	for x in range(0, 8):
		spb.append(Vector2i(x, 3))
	var fb := field__batch_zones(16, 7, [[Vector2i(6, 3), "anti_tank", 0], [Vector2i(5, 3), "light_infantry", 0],
			[Vector2i(11, 3), "light_infantry", 1]], {}, spb)
	var atb: UnitInstance = fb["s"].grid.cell(Vector2i(6, 3)).occupant
	var bres: ActionResult = fb["r"].resolve(ShootIntent.new(atb.id, -1, -1, Vector2i(9, 3)))
	ck(bres.ok and atb.coord == Vector2i(6, 3), "no recoil when someone stands behind (%s)" % bres.reason)
