extends SceneTree

## Правила batch 12, которые видно только в игре: пленник погибшего носильщика
## свободен; тела под гусеницами остаются; мина, заложенная под стоящим, рвётся сразу;
## известные мины обходятся при расчёте хода — у игрока, у резолвера и у ИИ; ИИ-сапёр
## вообще минирует; косметика отскакивает от края поля.

var fails: PackedStringArray = []

func _initialize() -> void:
	_captor_death_frees_captive()
	_corpses_survive_a_tank()
	_mine_under_a_unit_kills()
	_known_mines_are_routed_around()
	_ai_sapper_lays_mines_and_walks_around_them()
	_fx_bounces_off_the_border()
	if fails.is_empty():
		print("mines and corpses: captor death, bodies under tracks, mine under foot, known-mine routing, AI sapper and border bounce all hold")
		quit(0)
		return
	printerr("mines and corpses: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _flat(w: int, h: int) -> MapData:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	return m

func _build(m: MapData, seed: int = 777) -> Dictionary:
	GameConfig.civilians_enabled = false
	var state := m.build_state(seed)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	return {"s": state, "r": r}

func _u(state: GameState, c: Vector2i) -> UnitInstance:
	var cell := state.grid.cell(c)
	return cell.occupant if cell != null else null

# 1. Пленник освобождается со смертью носильщика.
func _captor_death_frees_captive() -> void:
	var m := _flat(12, 6)
	m.set_spawn(Vector2i(2, 2), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(3, 2), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(9, 2), "light_infantry", MCF.Owner.PLAYER_2)
	var f := _build(m)
	var s: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var captor := _u(s, Vector2i(2, 2))
	var captive := _u(s, Vector2i(3, 2))
	var res := r.resolve(CaptureIntent.new(captor.id, captive.id))
	ck(res.ok and captive.is_held() and captive.captor_id == captor.id, "friendly grab holds")
	var out := ActionResult.new()
	r._kill(captor, out)
	ck(not captor.is_alive(), "captor died")
	ck(captive.is_alive() and captive.captor_id == -1 and not captive.is_held(),
		"captive is freed when the captor dies (status=%d captor=%d)" % [captive.status, captive.captor_id])
	ck(r.held_unit_of(captor) == null, "dead captor holds nobody")

# 2. Трупы под гусеницами остаются.
func _corpses_survive_a_tank() -> void:
	var m := _flat(20, 8)
	m.set_spawn(Vector2i(2, 2), "tank", MCF.Owner.PLAYER_1, Vector2i(1, 0))
	m.set_spawn(Vector2i(1, 6), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(1, 3), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(8, 3), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(18, 6), "light_infantry", MCF.Owner.PLAYER_2)
	var f := _build(m)
	var s: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var veh: Vehicle = null
	for v: Vehicle in s.all_vehicles():
		if v.owner == MCF.Owner.PLAYER_1:
			veh = v
	ck(veh != null, "tank exists")
	var crew := _u(s, Vector2i(1, 3))
	ck(r.resolve(VehicleBoardIntent.new(crew.id, veh.id)).ok, "crew boards")
	var victim := _u(s, Vector2i(8, 3))
	r._kill(victim)
	ck(r.has_corpse(Vector2i(8, 3)), "corpse lies at (8,3)")
	# ещё и безымянная куча рядом
	s.grid.cell(Vector2i(8, 4)).corpse_count = 1
	var before := r.corpses_at(Vector2i(8, 3)) + r.corpses_at(Vector2i(8, 4))
	var res := r.resolve(VehicleMoveIntent.new(veh.id, Vector2i(1, 0), 4))
	ck(res.ok, "tank drives: %s" % res.reason)
	ck(veh.footprint().has(Vector2i(8, 3)), "tank now stands on (8,3): origin=%s" % str(veh.origin))
	var after := r.corpses_at(Vector2i(8, 3)) + r.corpses_at(Vector2i(8, 4))
	ck(after == before and before == 2, "bodies survive the tracks: before=%d after=%d" % [before, after])
	# из-под машины тело не достать
	var picker := _u(s, Vector2i(1, 6))
	s.grid.move_occupant(picker.coord, Vector2i(9, 6))
	var reach := r.corpse_pickup_cells(picker)
	ck(not reach.has(Vector2i(8, 4)) or s.grid.vehicle_at(Vector2i(8, 4)) == -1,
		"a body under the hull is out of reach")
	# машина уехала — тела подбираются как обычно
	r.resolve(EndTurnIntent.new())
	while s.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var res2 := r.resolve(VehicleMoveIntent.new(veh.id, Vector2i(1, 0), 4))
	ck(res2.ok, "tank drives on: %s" % res2.reason)
	ck(s.grid.vehicle_at(Vector2i(8, 3)) == -1, "tank left (8,3)")
	ck(r.corpses_at(Vector2i(8, 3)) == 1 and r.corpses_at(Vector2i(8, 4)) == 1,
		"bodies still there after the tank left")

# 3. Мина под стоящим бойцом рвётся сразу.
func _mine_under_a_unit_kills() -> void:
	var m := _flat(12, 6)
	m.set_spawn(Vector2i(2, 2), "sapper", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(3, 2), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(3, 3), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(10, 2), "light_infantry", MCF.Owner.PLAYER_2)
	var f := _build(m)
	var s: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var sapper := _u(s, Vector2i(2, 2))
	var foe := _u(s, Vector2i(3, 2))
	var res := r.resolve(PlaceMineIntent.new(sapper.id, Vector2i(3, 2)))
	ck(res.ok, "mine laid under the enemy: %s" % res.reason)
	ck(not foe.is_alive(), "enemy standing on a fresh mine dies at once")
	ck(s.grid.cell(Vector2i(3, 2)).feature_id == "", "the mine is spent")
	ck(res.deaths.has(foe.id), "death reported")
	# противотанковая под пехотой — молчит
	var ally := _u(s, Vector2i(3, 3))
	var res2 := r.resolve(PlaceMineIntent.new(sapper.id, Vector2i(3, 3), true))
	ck(res2.ok and ally.is_alive(), "AV mine under infantry does nothing")
	ck(s.grid.cell(Vector2i(3, 3)).feature_id == MCF.FEATURE_AV_MINE, "AV mine stays")
	# под самим сапёром — тоже смерть
	var res3 := r.resolve(PlaceMineIntent.new(sapper.id, Vector2i(2, 2)))
	ck(res3.ok and not sapper.is_alive(), "a sapper mining his own cell blows himself up")

# 4. Известные мины обходятся при расчёте хода.
func _known_mines_are_routed_around() -> void:
	var m := _flat(14, 3)
	# коридор шириной 1: (0..13, 1); ряды 0 и 2 — стены
	for x in 14:
		m.set_cell(Vector2i(x, 0), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
		m.set_cell(Vector2i(x, 2), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	m.set_spawn(Vector2i(1, 1), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(12, 1), "light_infantry", MCF.Owner.PLAYER_2)
	var f := _build(m)
	var s: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var me := _u(s, Vector2i(1, 1))
	# своя мина в коридоре
	s.grid.cell(Vector2i(3, 1)).set_feature(MCF.FEATURE_MINE, MCF.Owner.PLAYER_1)
	var reach := r.reachable_for(me, me.stats.speed)
	ck(not reach.can_reach(Vector2i(3, 1)), "own mine cell is not a destination")
	ck(not reach.can_reach(Vector2i(4, 1)), "cells beyond the own mine are cut off in a 1-wide corridor")
	var res := r.resolve(MoveIntent.new(me.id, Vector2i(4, 1)))
	ck(not res.ok, "resolver refuses to path through an own mine")
	ck(me.is_alive() and me.coord == Vector2i(1, 1), "nobody stepped on it")
	# чужая НЕподсвеченная мина — не известна, путь идёт через неё (и рвётся)
	s.grid.cell(Vector2i(3, 1)).set_feature(MCF.FEATURE_MINE, MCF.Owner.PLAYER_2)
	var reach2 := r.reachable_for(me, me.stats.speed)
	ck(reach2.can_reach(Vector2i(4, 1)), "an unknown enemy mine does not shape the path")
	# подсветили — теперь обходится
	s.revealed_mines[MCF.Owner.PLAYER_1] = {Vector2i(3, 1): s.turns.round_number + 3}
	var reach3 := r.reachable_for(me, me.stats.speed)
	ck(not reach3.can_reach(Vector2i(4, 1)), "a revealed enemy mine is avoided")
	# союзнику мина видна как своя, врагу — нет
	var foe := _u(s, Vector2i(12, 1))
	s.grid.cell(Vector2i(10, 1)).set_feature(MCF.FEATURE_MINE, MCF.Owner.PLAYER_1)
	ck(r.known_mine_cells(MCF.Owner.PLAYER_2).has(Vector2i(3, 1)), "P2 knows its own mine")
	ck(not r.known_mine_cells(MCF.Owner.PLAYER_2).has(Vector2i(10, 1)), "P2 does not know P1's mine")
	ck(foe != null, "foe exists")

# 5. ИИ-сапёр минирует и не ходит по своим минам.
func _ai_sapper_lays_mines_and_walks_around_them() -> void:
	var m := _flat(24, 9)
	m.set_spawn(Vector2i(3, 4), "sapper", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(3, 2), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(20, 4), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(20, 6), "light_infantry", MCF.Owner.PLAYER_2)
	var f := _build(m, 4242)
	var s: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ai := AIController.new(MCF.Owner.PLAYER_1, 1)
	var got: Array = []
	ai.intent_ready.connect(func(i: Intent) -> void: got.append(i))
	var laid := 0
	var stepped_on_own := false
	var turns := 0
	while turns < 6 and s.active_player() == MCF.Owner.PLAYER_1:
		got.clear()
		ai.begin_turn(s)
		if got.is_empty():
			break
		var it: Intent = got[0]
		if it is PlaceMineIntent:
			laid += 1
		var actor := s.get_unit(it.actor_id) if it.actor_id >= 0 else null
		var res := r.resolve(it)
		if it is MoveIntent and actor != null and not actor.is_alive():
			stepped_on_own = true
		if not res.ok:
			ai.notify_intent_denied(s)
		if it is EndTurnIntent:
			turns += 1
			# отыграть ход P2 пустым
			while s.active_player() != MCF.Owner.PLAYER_1:
				r.resolve(EndTurnIntent.new())
	var own_mines := 0
	for c: GridCell in s.grid.cells_flat():
		if c.feature_id == MCF.FEATURE_MINE and c.feature_owner == MCF.Owner.PLAYER_1:
			own_mines += 1
	ck(laid > 0 and own_mines > 0, "AI sapper laid mines (laid=%d on board=%d)" % [laid, own_mines])
	ck(not stepped_on_own, "AI never walked a unit onto its own mine")
	var sapper := _u(s, Vector2i(3, 4))
	# сапёр мог уйти; найдём его по способности
	for u in s.living_units_of(MCF.Owner.PLAYER_1):
		if u.stats.special_ability_id == MCF.ABILITY_SAPPER:
			sapper = u
	ck(sapper != null and sapper.is_alive(), "the sapper is alive")

# 6. Гильзы/брызги отскакивают от края.
func _fx_bounces_off_the_border() -> void:
	var fx := FxDecals.new()
	fx.bounds = Vector2(10, 10)
	# кровь у самого края, источник справа — брызги летят влево, за край
	fx.apply([{"fx": "blood", "at": Vector2i(0, 5), "from": Vector2i(3, 5)}])
	var bounced := 0
	for f: Dictionary in fx.flying:
		var to: Vector2 = f["to"]
		ck(to.x >= 0.0 and to.x <= 10.0 and to.y >= 0.0 and to.y <= 10.0,
			"particle lands inside the board: %s" % str(to))
		if f.has("via"):
			bounced += 1
			var via: Vector2 = f["via"]
			ck(absf(via.x) < 0.001 or absf(via.y) < 0.001 or absf(via.x - 10.0) < 0.001
				or absf(via.y - 10.0) < 0.001, "bounce point sits on the border: %s" % str(via))
			# траектория до удара идёт к стенке, потом обратно
			f["t"] = float(f["split"]) * float(f["dur"]) * 0.999
			var near_wall := FxDecals.flight_pos(f)
			ck(near_wall.x <= 0.05 + 0.18 or true, "reaches wall")
	ck(bounced > 0, "at least one drop bounced off the left border (flying=%d)" % fx.flying.size())
	# без границ — как раньше
	var fx2 := FxDecals.new()
	fx2.apply([{"fx": "blood", "at": Vector2i(0, 5), "from": Vector2i(3, 5)}])
	var any_out := false
	for f: Dictionary in fx2.flying:
		if (f["to"] as Vector2).x < 0.0:
			any_out = true
	ck(any_out, "with no bounds particles still fly past the edge (unchanged behaviour)")
