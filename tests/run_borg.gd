extends SceneTree

## Борг (batch 13, «Borg characteristics»): одноместная машина 1×1, которой играют как
## бойцом. Проверяется: посадка и выход, числа оператора (3 ОД, 9 хода, 12/4, +2 к
## броне), особые способности остаются, инженер без бортового оружия, но со всем
## остальным и партиями построек, огонь не вредит, окоп недоступен, мины, ремонт корпуса
## только тяжёлым оружием, гибель и взрыв/остов, выталкивание тела при захвате.

var fails: PackedStringArray = []

func ck(c: bool, w: String) -> void:
	if not c:
		fails.append(w)

func _initialize() -> void:
	_board_stats_and_exit()
	_engineer_batches()
	_fire_trench_and_mines()
	_destruction()
	_overtake_a_dead_operator()
	_operator_stays_a_unit()
	_ai_uses_a_borg()
	if fails.is_empty():
		print("borg: boarding, stats, engineer batches, fire, trenches, mines, destruction, overtaking, one-vehicle-at-a-time and the AI all hold")
		quit(0)
		return
	printerr("borg: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func _field(extra: Array = []) -> Dictionary:
	var m := MapData.new(30, 12)
	for y in 12:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(5, 5), "borg", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(4, 5), "sniper", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(4, 6), "engineer", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(20, 5), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(25, 8), "anti_tank", MCF.Owner.PLAYER_2)
	for e in extra:
		m.set_spawn(e[0], e[1], e[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(99)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	while st.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r, "b": st.all_vehicles()[0]}

func _u(st: GameState, c: Vector2i) -> UnitInstance:
	return st.grid.cell(c).occupant

func _board_stats_and_exit() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var b: Vehicle = f["b"]
	ck(b.is_borg() and b.durability == 2 and b.live_components() == [MCF.COMP_HULL], "borg: hull 2, nothing else")
	ck(st.grid.vehicle_at(Vector2i(5, 5)) == b.id, "empty borg is on the grid as a hull")
	var sn := _u(st, Vector2i(4, 5))
	ck(r.boardable_vehicles(sn).has(b), "sniper next to the borg can board it")
	var res := r.resolve(VehicleBoardIntent.new(sn.id, b.id))
	ck(res.ok, "board: " + res.reason)
	ck(sn.borg_id == b.id and sn.coord == Vector2i(5, 5) and st.grid.cell(Vector2i(5, 5)).occupant == sn,
			"operator stands in the borg's cell")
	ck(st.grid.vehicle_at(Vector2i(5, 5)) == -1, "manned borg is not a hull on the grid (transparent)")
	ck(sn.max_ap() == 3 and sn.remaining_ap == 3, "3 AP pool, boarding is free (%d)" % sn.remaining_ap)
	ck(sn.speed() == 9 and sn.fire_range() == 12.0 and sn.rate_of_fire() == 4, "borg numbers: 9 move, 12 range, RoF 4")
	ck(sn.armor() == 2, "sniper armour 4+ becomes 2+ (%d)" % sn.armor())
	ck(sn.stats.special_ability_id == MCF.ABILITY_SNIPER, "ability stays")
	# move 9 cells with one AP; the borg follows
	res = r.resolve(MoveIntent.new(sn.id, Vector2i(14, 5)))
	ck(res.ok, "move 9: " + res.reason)
	ck(sn.coord == Vector2i(14, 5) and b.origin == Vector2i(14, 5), "borg rode with the operator (origin %s)" % str(b.origin))
	# shoot with the borg gun: 4 shots
	var foe := _u(st, Vector2i(20, 5))
	ck(r.can_shoot(sn, foe) == "", "can shoot at 6: " + r.can_shoot(sn, foe))
	res = r.resolve(ShootIntent.new(sn.id, foe.id, -1))
	ck(res.ok, "shoot: " + res.reason)
	var ev: Dictionary = res.dice_events[0]
	ck((ev.get("shots", []) as Array).size() == 4, "borg gun fires 4 (%d)" % (ev.get("shots", []) as Array).size())
	# enemy shooting the operator rolls against 2+
	r.resolve(EndTurnIntent.new())
	var at := _u(st, Vector2i(25, 8))
	if foe.is_alive():
		var shot := r.resolve(ShootIntent.new(foe.id, sn.id, 1))
		ck(shot.ok, "enemy shoots the operator: " + shot.reason)
		ck(int(shot.dice_events[0].get("armor", 0)) == 2, "operator defends at 2+ (%d)" % int(shot.dice_events[0].get("armor", 0)))
	ck(b.durability == 2, "small arms never touch the hull")
	# exit: 1 AP, borg stays behind as a hull
	r.resolve(EndTurnIntent.new())
	if sn.is_alive():
		res = r.resolve(VehicleDisembarkIntent.new(sn.id, Vector2i(15, 5)))
		ck(res.ok, "exit: " + res.reason)
		ck(sn.borg_id == -1 and sn.coord == Vector2i(15, 5) and st.grid.vehicle_at(Vector2i(14, 5)) == b.id,
				"operator out, borg left as a hull at (14,5)")
		ck(sn.remaining_ap <= sn.max_ap() and sn.max_ap() == 2, "AP cap back to the unit's own")

func _engineer_batches() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var b: Vehicle = f["b"]
	var en := _u(st, Vector2i(4, 6))
	var res := r.resolve(VehicleBoardIntent.new(en.id, b.id))
	ck(res.ok, "engineer boards: " + res.reason)
	ck(en.fire_range() == en.stats.fire_range and en.rate_of_fire() == en.stats.rate_of_fire,
			"engineer keeps its own gun")
	ck(en.speed() == 9 and en.armor() == en.stats.armor_threshold - 2 and en.max_ap() == 3, "engineer gets move/armour/AP")
	ck(r.build_cost_for(en, MCF.FEATURE_WALL) == 1 and r.build_cost_for(en, MCF.FEATURE_DOT) == 1, "wall batch 1 AP, pillbox 1 AP")
	var ap0 := en.remaining_ap
	res = r.resolve(BuildIntent.new(en.id, Vector2i(6, 5), MCF.FEATURE_WALL))
	ck(res.ok and en.remaining_ap == ap0 - 1 and int(en.build_credits.get(MCF.FEATURE_WALL, 0)) == 2,
			"first wall costs 1 AP and opens 2 credits (%s)" % str(en.build_credits))
	# другое действие между постройками партию не рвёт
	var ap_mid := en.remaining_ap
	res = r.resolve(BuildIntent.new(en.id, Vector2i(6, 6), MCF.FEATURE_WALL))
	ck(res.ok and en.remaining_ap == ap_mid and int(en.build_credits.get(MCF.FEATURE_WALL, 0)) == 1,
			"second wall is free from the batch: " + res.reason)
	res = r.resolve(BuildIntent.new(en.id, Vector2i(6, 4), MCF.FEATURE_WALL))
	ck(res.ok and int(en.build_credits.get(MCF.FEATURE_WALL, 0)) == 0, "third wall spends the last credit")
	# glass is a different batch: needs its own AP
	var ap1 := en.remaining_ap
	res = r.resolve(BuildIntent.new(en.id, Vector2i(5, 4), MCF.FEATURE_GLASS))
	ck(res.ok and en.remaining_ap == ap1 - 1, "a different type starts a new batch")
	# credits expire at the end of the round
	r.resolve(EndTurnIntent.new()); r.resolve(EndTurnIntent.new())
	ck(en.build_credits.is_empty(), "batch credits expired with the round")
	ck(en.remaining_ap == 3, "fresh round: 3 AP in the borg")

func _fire_trench_and_mines() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var b: Vehicle = f["b"]
	var sn := _u(st, Vector2i(4, 5))
	r.resolve(VehicleBoardIntent.new(sn.id, b.id))
	st.grid.cell(Vector2i(8, 5)).on_fire = true
	st.grid.cell(Vector2i(10, 5)).set_feature(MCF.FEATURE_TRENCH)
	st.grid.cell(Vector2i(12, 5)).set_feature(MCF.FEATURE_AV_MINE, MCF.Owner.PLAYER_2)
	var reach := r.reachable_for(sn, 9)
	ck(reach.can_reach(Vector2i(8, 5)) and reach.can_reach(Vector2i(9, 5)), "fire is no obstacle to a borg")
	ck(not reach.can_reach(Vector2i(10, 5)), "a trench is not enterable by a borg")
	var res := r.resolve(MoveIntent.new(sn.id, Vector2i(9, 5)))
	ck(res.ok and sn.is_alive() and sn.coord == Vector2i(9, 5), "drove through fire unharmed: " + res.reason)
	# AV mine: hull -1, stops there; personnel mine ignored
	st.grid.cell(Vector2i(11, 6)).set_feature(MCF.FEATURE_MINE, MCF.Owner.PLAYER_2)
	res = r.resolve(MoveIntent.new(sn.id, Vector2i(13, 6)))
	ck(res.ok, "move over mines: " + res.reason)
	# path (9,5)->(13,6): may pass (11,6) or (12,5) depending on Dijkstra; assert the invariants
	ck(sn.is_alive(), "a personnel mine never hurts the borg")
	if b.durability == 1:
		ck(sn.coord == Vector2i(12, 5) and st.grid.cell(Vector2i(12, 5)).feature_id == "", "AV mine stopped it and blew up")
	ck(b.durability >= 1, "hull survives one AV mine")

func _destruction() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var b: Vehicle = f["b"]
	var sn := _u(st, Vector2i(4, 5))
	r.resolve(VehicleBoardIntent.new(sn.id, b.id))
	var res := ActionResult.new()
	r._damage_component(b, MCF.COMP_HULL, 2, "test", res)
	ck(not sn.is_alive(), "operator dies with the borg")
	var exploded := res.log_lines.filter(func(l): return l.find("explodes") >= 0).size() > 0
	ck(b.wrecked and st.grid.vehicle_at(Vector2i(5, 5)) == b.id, "borg leaves a wreck on its cell, exploded or not (batch 17)")
	if exploded:
		ck(res.fx.any(func(f): return f.get("fx", "") == "debris"), "exploded borg scorches the floor")
	# The body is not «in» a vehicle any more, and a dangling borg_id would point at nothing.
	ck(sn.borg_id == -1, "dead operator's borg_id is cleared (%d)" % sn.borg_id)

func _overtake_a_dead_operator() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var b: Vehicle = f["b"]
	var sn := _u(st, Vector2i(4, 5))
	var en := _u(st, Vector2i(4, 6))
	r.resolve(VehicleBoardIntent.new(sn.id, b.id))
	r._kill(sn)
	ck(st.grid.vehicle_at(Vector2i(5, 5)) == b.id and st.grid.cell(Vector2i(5, 5)).occupant == sn,
			"dead operator: hull back on the grid, body still inside")
	ck(r.boardable_vehicles(en).has(b), "the engineer can take the borg over")
	var res := r.resolve(VehicleBoardIntent.new(en.id, b.id))
	ck(res.ok, "overtake: " + res.reason)
	ck(en.borg_id == b.id and en.coord == Vector2i(5, 5), "engineer at the controls")
	ck(st.grid.in_bounds(sn.coord) and sn.coord != Vector2i(5, 5) and st.grid.cell(sn.coord).occupant == sn
			and Combat.distance(sn.coord, Vector2i(5, 5)) == 1, "the body was pushed out next to the borg (%s)" % str(sn.coord))

## Борг — это боец, а не машина: оператор не пересаживается из него прямо в танк (борг
## оставался «занятым», а при высадке телепортировался к бойцу), а машинные намерения
## (VehicleMove/Turn/Cannon) к боргу не применяются — после смены раунда у него
## появлялось своё ОД экипажа, и VehicleMoveIntent катил корпус отдельно от оператора,
## оставляя след без машины на клетке назначения.
func _operator_stays_a_unit() -> void:
	var f := _field([[Vector2i(8, 4), "tank", MCF.Owner.PLAYER_1]])  # hull (8,4)-(10,6)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var b: Vehicle = f["b"]
	var tank := st.vehicle_on(Vector2i(8, 4))
	var sn := _u(st, Vector2i(4, 5))
	var res := r.resolve(VehicleBoardIntent.new(sn.id, b.id))
	ck(res.ok, "board borg: " + res.reason)
	res = r.resolve(MoveIntent.new(sn.id, Vector2i(7, 5)))  # next to the tank
	ck(res.ok and sn.coord == Vector2i(7, 5) and b.origin == Vector2i(7, 5), "borg walks up to the tank")
	res = r.resolve(VehicleBoardIntent.new(sn.id, tank.id))
	ck(not res.ok, "operator cannot board a tank from inside the borg")
	ck(sn.borg_id == b.id and sn.aboard_vehicle_id == -1 and sn.coord == Vector2i(7, 5),
			"refused boarding changes nothing")
	# a new round gives the borg a crew-AP pool; vehicle intents must still be refused
	r.resolve(EndTurnIntent.new())
	r.resolve(EndTurnIntent.new())
	ck(st.active_player() == MCF.Owner.PLAYER_1, "back to P1")
	res = r.resolve(VehicleMoveIntent.new(b.id, Vector2i(0, 1), 3))
	ck(not res.ok, "VehicleMoveIntent on an operated borg is refused")
	ck(b.origin == Vector2i(7, 5) and st.grid.vehicle_at(Vector2i(7, 8)) == -1
			and st.grid.vehicle_at(Vector2i(7, 5)) == -1,
			"no hull tag is left anywhere (origin %s)" % str(b.origin))
	res = r.resolve(VehicleTurnIntent.new(b.id, Vector2i(0, 1)))
	ck(not res.ok, "VehicleTurnIntent on a borg is refused")
	res = r.resolve(VehicleCannonIntent.new(b.id, Vector2i(20, 5)))
	ck(not res.ok, "VehicleCannonIntent on a borg is refused")
	# and after climbing out the soldier boards the tank normally
	res = r.resolve(VehicleDisembarkIntent.new(sn.id, Vector2i(7, 4)))
	ck(res.ok and sn.borg_id == -1, "climbs out: " + res.reason)
	res = r.resolve(VehicleBoardIntent.new(sn.id, tank.id))
	ck(res.ok and sn.aboard_vehicle_id == tank.id, "then boards the tank: " + res.reason)

var _pending: Intent = null
func _on_intent(i: Intent) -> void:
	_pending = i

func _ai_uses_a_borg() -> void:
	var f := _field()
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var b: Vehicle = f["b"]
	var ai := AIController.new(MCF.Owner.PLAYER_1, AIController.Difficulty.NORMAL)
	ai.intent_ready.connect(_on_intent)
	var boarded := false
	var moved_in_borg := false
	var actions := 0
	while st.turns.round_number <= 3 and actions < 120:
		if st.active_player() != MCF.Owner.PLAYER_1:
			r.resolve(EndTurnIntent.new())
			continue
		_pending = null
		ai.begin_turn(st)
		if _pending == null:
			r.resolve(EndTurnIntent.new())
			continue
		actions += 1
		var intent := _pending
		var res := r.resolve(intent)
		if not res.ok:
			ai.notify_intent_denied(st)
			continue
		if intent is VehicleBoardIntent and st.get_vehicle((intent as VehicleBoardIntent).vehicle_id) == b:
			boarded = true
		if intent is MoveIntent and st.get_unit(intent.actor_id) != null and st.get_unit(intent.actor_id).borg_id == b.id:
			moved_in_borg = true
	ck(boarded, "AI boarded the empty borg")
	ck(moved_in_borg, "AI drove the borg as a unit")
