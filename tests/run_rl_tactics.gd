extends SceneTree
## Tactical RL environment: fire map, multi-AP legal moves, tactical candidate order,
## army builder, HARD play styles.
const Budget = preload("res://rl/IntentBudget.gd")
const Obs = preload("res://rl/ObsEncoder.gd")
const AB = preload("res://rl/ArmyBuilder.gd")
var fails := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1

func field(spawns: Array, walls: Array = [], sandbags: Array = []) -> Dictionary:
	var m := MapData.new(30, 16)
	for y in 16:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for c: Vector2i in walls:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	for c: Vector2i in sandbags:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_SANDBAGS)
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(3)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r}

func _initialize() -> void:
	# --- fire map ---
	var f := field([[Vector2i(4, 8), "light_infantry", 0], [Vector2i(14, 8), "machinegunner", 1]],
			[Vector2i(14, 5)])
	var st: GameState = f["s"]; var r: GameActionResolver = f["r"]
	var w := st.grid.width
	var th := r.fire_cover(0, true)
	ck(th[8 * w + 10] > 0.0, "cell on the MG's firing line is under fire (%.2f)" % th[8 * w + 10])
	ck(th[9 * w + 11] == 0.0, "cell off every firing line is not")
	ck(th[4 * w + 14] == 0.0, "a wall stops the line (cell behind it is safe)")
	ck(th[8 * w + 13] > th[8 * w + 6], "fire is heavier close in")
	var own := r.fire_cover(0, false)
	ck(own[8 * w + 7] > 0.0 and own[8 * w + 14] > 0.0, "own coverage reaches the enemy")
	# Fog is honest: a hidden enemy adds nothing.
	var g := field([[Vector2i(2, 8), "light_infantry", 0], [Vector2i(27, 8), "light_infantry", 1]],
			[Vector2i(14, 7), Vector2i(14, 8), Vector2i(14, 9)])
	var gr: GameActionResolver = g["r"]
	var hidden := not gr.is_visible_to_team(0, g["s"].grid.cell(Vector2i(27, 8)).occupant)
	var gth := gr.fire_cover(0, true)
	var any := false
	for v in gth:
		any = any or v > 0.0
	ck(hidden and not any, "an enemy we cannot see puts nothing on the fire map")

	# --- forecast of the enemy's next turn ---
	f = field([[Vector2i(4, 8), "light_infantry", 0], [Vector2i(16, 8), "machinegunner", 1]],
			[Vector2i(16, 4), Vector2i(17, 4), Vector2i(15, 4)])
	st = f["s"]; r = f["r"]
	w = st.grid.width
	var fc: Dictionary = r.enemy_forecast(0)
	var mg := st.grid.cell(Vector2i(16, 8)).occupant
	var step := mg.speed()
	ck(fc["reach"][8 * w + 16 - step] > 0.0 and fc["reach"][8 * w + 16 - step - 2] == 0.0,
			"enemy reach covers exactly one move (speed %d)" % step)
	var now := r.fire_cover(0, true)
	# (10, 3): off every firing line of the MG where it stands, but on one after it moves.
	ck(now[3 * w + 10] == 0.0 and fc["fire"][3 * w + 10] > 0.0,
			"next-turn fire reaches a cell that is safe right now")
	ck(r.enemy_forecast(0) == fc, "the forecast is cached while nothing moved")

	# --- memory of enemies that went out of sight ---
	var EM = load("res://rl/EnemyMemory.gd")
	var mem = EM.new()
	g = field([[Vector2i(2, 8), "light_infantry", 0], [Vector2i(9, 8), "light_infantry", 1]],
			[Vector2i(12, 6), Vector2i(12, 7), Vector2i(12, 8), Vector2i(12, 9), Vector2i(12, 10)])
	gr = g["r"]
	var gs: GameState = g["s"]
	var foe := gs.grid.cell(Vector2i(9, 8)).occupant
	mem.observe(gr, 0)
	var lay: PackedInt32Array = mem.layer(gr, 0)
	ck(lay[8 * gs.grid.width + 9] == 0, "a visible enemy leaves no memory mark")
	gs.grid.move_occupant(foe.coord, Vector2i(14, 8))
	gr.update_airlocks()
	var hidden_now := not gr.is_visible_to_team(0, foe)
	lay = mem.layer(gr, 0)
	ck(hidden_now and lay[8 * gs.grid.width + 9] == 100, "a hidden enemy is remembered where it was last seen")

	# --- multi-AP legal moves ---
	f = field([[Vector2i(2, 8), "light_infantry", 0], [Vector2i(28, 2), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	var li := st.grid.cell(Vector2i(2, 8)).occupant
	li.remaining_ap = 2
	# Дальняя зона прорежена до решётки 2×2 (LegalIntents._far_worthy): берём чётную клетку.
	var fx := 2 + li.speed() + 2
	var far := Vector2i(fx + fx % 2, 8)
	var legal: Array = r.legal_intents(0)
	var has_far := false
	for it: Intent in legal:
		if it is MoveIntent and it.target == far:
			has_far = true
	ck(has_far, "an orange-zone move is a legal candidate")
	var res := r.resolve(MoveIntent.new(li.id, far))
	ck(res.ok and li.remaining_ap == 0, "and it resolves for 2 AP (%s)" % res.reason)

	# --- tactical order inside a unit's move bucket ---
	f = field([[Vector2i(4, 8), "light_infantry", 0], [Vector2i(16, 8), "machinegunner", 1]],
			[], [Vector2i(6, 11)])
	st = f["s"]; r = f["r"]
	li = st.grid.cell(Vector2i(4, 8)).occupant
	var moves: Array = []
	for it: Intent in r.legal_intents(0):
		if it is MoveIntent and it.actor_id == li.id:
			moves.append(it)
	var ordered: Array = Budget._tactical_order(moves, r, 0)
	var first: Vector2i = ordered[0].target
	var thr := r.fire_cover(0, true)
	var best := 1e9
	for it: Intent in moves:
		best = minf(best, thr[it.target.y * st.grid.width + it.target.x])
	ck(thr[first.y * st.grid.width + first.x] == best, "the first kept move is one of the least exposed")
	ck(ordered.size() == moves.size(), "ordering keeps every move")

	# --- describe carries the tactics ---
	var tac := Obs.tactics(r, 0)
	var d: Dictionary = Obs.describe(st, MoveIntent.new(li.id, Vector2i(4 + li.speed() + 1, 8)), tac)
	ck(d.has("th") and d.has("fc") and d.has("cv") and int(d.get("apc", 0)) == 2,
			"candidate carries threat/cover/AP cost: %s" % d)
	var enc := Obs.encode(r, 0, 10, tac)
	ck(enc["threat"].size() == st.grid.width * st.grid.height, "obs carries the threat layer")

	# --- the station-reach feature ("rh"): the leash, at the moment the CELL is chosen ---
	# A station tethers its drone to DRONE_LEASH cells and pins the operator beside it, so
	# one planted out of the enemy's reach costs the operator the rest of the game. "lf"
	# above cannot answer this: there the actor is the drone, already in the air, and the
	# station's cell was settled long before. Absent on every other kind of candidate.
	var rm := MapData.new(60, 9)
	for y in 9:
		for x in 60:
			rm.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	rm.set_spawn(Vector2i(3, 4), "drone_operator", MCF.Owner.PLAYER_1)
	rm.set_spawn(Vector2i(19, 4), "light_infantry", MCF.Owner.PLAYER_2)
	var rst := rm.build_state(5)
	var rr := GameActionResolver.new(rst)
	rr.fog_mode = MCF.Fog.OFF
	rr.fog_enabled = false
	while rst.active_player() != MCF.Owner.PLAYER_1:
		rr.resolve(EndTurnIntent.new())
	var rop: UnitInstance = rst.grid.cell(Vector2i(3, 4)).occupant
	var rtac := Obs.tactics(rr, MCF.Owner.PLAYER_1)
	# (4,4) is 15 from the enemy — the drone just reaches, with no slack.
	var edge: Dictionary = Obs.describe(rst, UseItemIntent.new(rop.id, Vector2i(4, 4)), rtac)
	# (2,4) is 17 — one step too far, and the drone never gets there.
	var over: Dictionary = Obs.describe(rst, UseItemIntent.new(rop.id, Vector2i(2, 4)), rtac)
	ck(float(edge.get("rh", 0.0)) > 0.0,
			"a station right on the leash still reads as reachable (%s)" % str(edge.get("rh", "absent")))
	ck(float(over.get("rh", -1.0)) == 0.0,
			"and past the leash it reads as out of reach (%s)" % str(over.get("rh", "absent")))
	ck(float(edge["rh"]) < 0.5, "reaching with no slack is near the bottom of the scale")
	ck(not Obs.describe(rst, MoveIntent.new(rop.id, Vector2i(4, 5)), rtac).has("rh"),
			"a plain move carries no reach feature at all")
	# Fog is respected: an enemy in reach but WALLED OUT OF SIGHT promises nothing, or the
	# feature would leak knowledge the team has not earned. Same cell, same 15 cells of
	# distance — only the seeing differs, so fog off must still read as reachable.
	var wm := MapData.new(60, 9)
	for y in 9:
		for x in 60:
			wm.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for c: Vector2i in [Vector2i(18, 3), Vector2i(18, 4), Vector2i(18, 5), Vector2i(19, 3),
			Vector2i(19, 5), Vector2i(20, 3), Vector2i(20, 4), Vector2i(20, 5)]:
		wm.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	wm.set_spawn(Vector2i(3, 4), "drone_operator", MCF.Owner.PLAYER_1)
	wm.set_spawn(Vector2i(19, 4), "light_infantry", MCF.Owner.PLAYER_2)
	var wst := wm.build_state(5)
	var wr := GameActionResolver.new(wst)
	wr.fog_mode = MCF.Fog.OFF
	wr.fog_enabled = false
	while wst.active_player() != MCF.Owner.PLAYER_1:
		wr.resolve(EndTurnIntent.new())
	var wop: UnitInstance = wst.grid.cell(Vector2i(3, 4)).occupant
	var seen: Dictionary = Obs.describe(wst, UseItemIntent.new(wop.id, Vector2i(4, 4)),
			Obs.tactics(wr, MCF.Owner.PLAYER_1))
	ck(float(seen.get("rh", 0.0)) > 0.0,
			"with fog off the walled enemy is still counted (%s)" % str(seen.get("rh", "absent")))
	wr.fog_mode = MCF.Fog.STANDARD
	wr.fog_enabled = true
	var unseen: Dictionary = Obs.describe(wst, UseItemIntent.new(wop.id, Vector2i(4, 4)),
			Obs.tactics(wr, MCF.Owner.PLAYER_1))
	ck(float(unseen.get("rh", -1.0)) == 0.0,
			"an enemy out of sight promises no reach (%s)" % str(unseen.get("rh", "absent")))

	# --- army builder ---
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var gm := MapGen.generate({"style": 1, "size": 0, "seed": 77, "zones": 2, "units": 30,
			"civilians": 0, "civilian_count": 0})
	ck(AB.populate(gm, rng, 10, 1), "populate fits a random army into the zones")
	var per := {0: [], 1: []}
	for s in gm.spawns:
		if MCF.is_player(int(s["owner"])):
			per[int(s["owner"])].append(s["stats_id"])
	per[0].sort(); per[1].sort()
	ck(per[0] == per[1] and per[0].size() >= 10, "both sides field the same composition (%d)" % per[0].size())
	var am := MapData.load_from(ProjectSettings.globalize_path("res://rl/maps/arena_34x26.json"))
	AB.shuffle(am, rng)
	var a0 := {0: [], 1: []}
	for s in am.spawns:
		if MCF.is_player(int(s["owner"])):
			a0[int(s["owner"])].append(s["stats_id"])
	a0[0].sort(); a0[1].sort()
	ck(a0[0] == a0[1], "a shuffled fixed map stays mirrored")

	# --- HARD styles ---
	var picks := {}
	for style in [AIController.Style.RUSH, AIController.Style.TURTLE]:
		f = field([[Vector2i(4, 8), "light_infantry", 0], [Vector2i(20, 8), "machinegunner", 1]],
				[], [Vector2i(7, 10), Vector2i(7, 6)])
		st = f["s"]; r = f["r"]
		var ai := AIController.new(0, AIController.Difficulty.HARD)
		ai.style = style
		ai._r = r
		var mv: Dictionary = ai._best_move(st, r, st.grid.cell(Vector2i(4, 8)).occupant)
		picks[style] = mv["intent"].target if not mv.is_empty() else Vector2i(-1, -1)
	var t_rush: Vector2i = picks[AIController.Style.RUSH]
	var t_turtle: Vector2i = picks[AIController.Style.TURTLE]
	ck(t_rush != t_turtle, "rush and turtle pick different cells (%s vs %s)" % [t_rush, t_turtle])
	ck(t_rush.x >= t_turtle.x, "rush goes at least as far forward")

	# --- army value: every component of a vehicle counts, not only the hull ---
	f = field([[Vector2i(5, 5), "tank", 0], [Vector2i(3, 12), "light_infantry", 0],
			[Vector2i(20, 8), "light_infantry", 1]])
	st = f["s"]
	var tank: Vehicle = st.all_vehicles()[0]
	var parts: Dictionary = MCF.VEHICLE_COMPONENTS["tank"]
	var points := 0
	for p: int in parts.values():
		points += p
	var full := Obs.army_value(st, 0)
	tank.components[MCF.COMP_GUN] = 0
	var lost := full - Obs.army_value(st, 0)
	var want := float(VehicleDB.buy_cost("tank")) * float(parts[MCF.COMP_GUN]) / float(points)
	ck(absf(lost - want) < 0.01, "a knocked-out gun costs its share of the tank (%.1f, want %.1f)"
			% [lost, want])
	print("rl tactics: %d failure(s)" % fails)
	quit(1 if fails else 0)
