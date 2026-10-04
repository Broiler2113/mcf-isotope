extends SceneTree
## Batch ui-drones: window shots, vehicles shattering glass, vehicle move tiers, drone
## leftover flight at 0 AP, a shot-down drone exploding its own cell, no blood from fire.
var fails := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1
func field(spawns: Array, glass: Array = []) -> Dictionary:
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for g: Vector2i in glass:
		m.set_cell(g, MCF.FLOOR_NORMAL, MCF.WALL_HEIGHT, false, MCF.FEATURE_GLASS)
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r}
func _initialize() -> void:
	# Window shot.
	var f := field([[Vector2i(5, 5), "light_infantry", 0], [Vector2i(25, 10), "light_infantry", 1]], [Vector2i(8, 5)])
	var st: GameState = f["s"]; var r: GameActionResolver = f["r"]
	var li := st.grid.cell(Vector2i(5, 5)).occupant
	ck(r.shootable_window_cells(li).has(Vector2i(8, 5)), "window is offered as a target")
	var res := r.resolve(ShootIntent.new(li.id, -1, -1, Vector2i(8, 5)))
	ck(res.ok and st.grid.cell(Vector2i(8, 5)).feature_id == "", "window shot out (%s)" % res.reason)
	ck(res.fx.any(func(e): return e["fx"] == "shards"), "shards fly")
	# Tank over glass.
	f = field([[Vector2i(4, 5), "light_infantry", 0], [Vector2i(5, 4), "tank", 0], [Vector2i(25, 10), "light_infantry", 1]], [Vector2i(10, 5)])
	st = f["s"]; r = f["r"]
	var veh: Vehicle = st.all_vehicles()[0]
	var crew := st.grid.cell(Vector2i(4, 5)).occupant
	r.resolve(VehicleBoardIntent.new(crew.id, veh.id))
	var tiers := r.vehicle_move_tiers(veh)
	ck(not tiers[0].is_empty(), "tank has a 1-AP zone (%d cells)" % tiers[0].size())
	print("     tank tiers: ", tiers.map(func(t): return t.size()), " ap=", r.vehicle_ap(veh))
	res = r.resolve(VehicleMoveIntent.new(veh.id, veh.facing if veh.facing != Vector2i.ZERO else Vector2i(1, 0), 6))
	ck(res.ok and st.grid.cell(Vector2i(10, 5)).feature_id == "", "tank drives through the window (%s)" % res.reason)
	ck(res.fx.any(func(e): return e["fx"] == "shards"), "the window shatters under the tank")
	# Drone: leftover flight with 0 AP, then shot down -> explodes.
	f = field([[Vector2i(5, 5), "drone_operator", 0], [Vector2i(14, 5), "light_infantry", 1], [Vector2i(14, 7), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	var op := st.grid.cell(Vector2i(5, 5)).occupant
	var station := Vector2i(6, 5)
	st.grid.cell(station).feature_id = MCF.FEATURE_DRONE_STATION
	st.grid.cell(station).feature_owner = 0
	var drone := r._launch_drone_at(station, op)
	drone.remaining_ap = 1
	res = r.resolve(DroneMoveIntent.new(drone.id, station + Vector2i(3, 0)))
	ck(res.ok and drone.remaining_ap == 0 and drone.move_credit > 0, "first hop leaves credit (%d)" % drone.move_credit)
	res = r.resolve(DroneMoveIntent.new(drone.id, station + Vector2i(6, 0)))
	ck(res.ok, "second hop on leftover flight with 0 AP (%s)" % res.reason)
	drone.coord = Vector2i(14, 6)
	r.resolve(EndTurnIntent.new())
	while st.active_player() != 1:
		r.resolve(EndTurnIntent.new())
	var shooter := st.grid.cell(Vector2i(14, 5)).occupant
	var killed := false
	for i in 20:
		shooter.remaining_ap = 1
		shooter.action_state = null
		res = r.resolve(ShootIntent.new(shooter.id, drone.id))
		if not drone.is_alive():
			killed = true
			break
	ck(killed, "drone shot down")
	ck(res.log_lines.any(func(l): return l.find("shot down") >= 0), "shot-down drone explodes: %s" % [res.log_lines])
	# Fire death: no blood.
	f = field([[Vector2i(5, 5), "light_infantry", 0], [Vector2i(25, 10), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	li = st.grid.cell(Vector2i(5, 5)).occupant
	st.grid.cell(Vector2i(7, 5)).on_fire = true
	res = r.resolve(MoveIntent.new(li.id, Vector2i(7, 5)))
	ck(not li.is_alive() and not res.fx.any(func(e): return e["fx"] == "blood"), "burned without blood")
	# Orange / red zone: one move spends 2 / 3 AP, leftover becomes credit.
	f = field([[Vector2i(2, 5), "light_infantry", 0], [Vector2i(28, 12), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	li = st.grid.cell(Vector2i(2, 5)).occupant
	li.remaining_ap = 3
	var sp := li.speed()
	var tb := r.move_tier_budgets(li)
	ck(tb == [sp, sp * 2, sp * 3], "tier budgets %s (speed %d)" % [tb, sp])
	res = r.resolve(MoveIntent.new(li.id, Vector2i(2 + sp + 1, 5)))
	ck(res.ok and li.remaining_ap == 1 and li.move_credit == sp - 1,
		"orange move costs 2 AP (%s, ap %d, credit %d)" % [res.reason, li.remaining_ap, li.move_credit])
	f = field([[Vector2i(2, 5), "light_infantry", 0], [Vector2i(28, 12), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	li = st.grid.cell(Vector2i(2, 5)).occupant
	li.remaining_ap = 3
	res = r.resolve(MoveIntent.new(li.id, Vector2i(2 + sp * 2 + 1, 5)))
	ck(res.ok and li.remaining_ap == 0, "red move costs 3 AP (%s, ap %d)" % [res.reason, li.remaining_ap])
	li.remaining_ap = 0
	res = r.resolve(MoveIntent.new(li.id, Vector2i(li.coord.x + li.move_credit + 1, 5)))
	ck(not res.ok, "no AP: beyond the credit is out of reach")
	# Tank: orange zone drives in one go and spends 2 crew AP.
	f = field([[Vector2i(2, 5), "light_infantry", 0], [Vector2i(3, 4), "tank", 0], [Vector2i(28, 12), "light_infantry", 1]])
	st = f["s"]; r = f["r"]
	veh = st.all_vehicles()[0]
	crew = st.grid.cell(Vector2i(2, 5)).occupant
	r.resolve(VehicleBoardIntent.new(crew.id, veh.id))
	veh.ap = 3
	var vtb := r.vehicle_tier_budgets(veh)
	var vall := r.vehicle_move_targets_all(veh)
	var orange := -1
	for c: Vector2i in vall:
		if GameActionResolver.tier_of(vtb, int(vall[c]["cost"])) == 1:
			orange = c.x if orange == -1 else orange
			var mv: Dictionary = vall[c]
			res = r.resolve(VehicleMoveIntent.new(veh.id, mv["dir"], int(mv["steps"])))
			ck(res.ok and veh.ap == 1 and veh.center() == c,
				"tank orange move costs 2 AP (%s, ap %d, budgets %s)" % [res.reason, veh.ap, vtb])
			break
	ck(orange != -1, "tank has an orange zone (budgets %s, %d targets)" % [vtb, vall.size()])
	_the_flight_preview_shows_the_real_route()
	print("rules: %d failure(s)" % fails)
	quit(1 if fails else 0)

## Предпросмотр полёта показывает МАРШРУТ, а не отрезок до курсора.
##
## У пехоты путь рисуется по настоящему маршруту (reach.path_to), у дрона рисовалась
## прямая от него к наведённой клетке — а дрон летит не по прямой: корпуса, чужие дроны и
## огонь он обходит. Линия обещала путь, которым он не полетит.
##
## Проверяется не «линия есть», а то, что это именно маршрут: стена посреди поля, цель за
## ней, и путь обязан быть ДЛИННЕЕ прямой, идти по соседним клеткам, кончаться в цели и
## нигде не проходить сквозь стену.
func _the_flight_preview_shows_the_real_route() -> void:
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	# Глухая стена с проходом только поверху.
	for y in range(4, 14):
		m.set_cell(Vector2i(12, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	m.set_cell(Vector2i(9, 8), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_DRONE_STATION)
	m.set_spawn(Vector2i(8, 8), "drone_operator", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(25, 12), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(11)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	st.grid.cell(Vector2i(9, 8)).feature_owner = MCF.Owner.PLAYER_1
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	var op: UnitInstance = st.grid.cell(Vector2i(8, 8)).occupant
	ck(r.resolve(SpawnDroneIntent.new(op.id, Vector2i(9, 8))).ok, "a drone goes up for the preview")
	var dr := r.active_drone_of(op)
	ck(dr != null, "and it is airborne")
	var target := Vector2i(14, 8)   # прямо за стеной
	var route := r.drone_route_to(dr, target)
	ck(route.size() > 0, "the preview has a route to the far side")
	ck(route[route.size() - 1] == target, "that ends on the hovered cell")
	ck(route.size() > Combat.distance(dr.coord, target),
			"and is LONGER than the straight line, because it goes around (%d vs %d)"
			% [route.size(), Combat.distance(dr.coord, target)])
	var prev := dr.coord
	var stepwise := true
	var through_wall := false
	for c: Vector2i in route:
		if Combat.distance(prev, c) != 1:
			stepwise = false
		if st.grid.cell(c).is_wall():
			through_wall = true
		prev = c
	ck(stepwise, "every leg is one cell, so it is a flight path and not a chord (%s)" % [route])
	ck(not through_wall, "and it never passes through the wall")
