extends SceneTree

## Batch 17 («Isotope issues fix 8»): правила, которые видны только в игре — бесплатная
## посадка в челнок и борг, полная струя огнемёта при разлёте о стену, нейтрал стреляет
## по купленному игроком жителю, каждая машина оставляет остов, групповой приказ
## доводит бойца, чей маршрут перекрыл сосед.

var fails: PackedStringArray = []

func ck(c: bool, w: String) -> void:
	if not c:
		fails.append(w)

func _initialize() -> void:
	_free_boarding()
	_flame_splash_is_six()
	_neutral_shoots_bought_civilian()
	_every_vehicle_leaves_a_wreck()
	_group_move_falls_back()
	if fails.is_empty():
		print("batch 17: free boarding, six-cell flame, neutrals vs bought civilians, wrecks and group fallback all hold")
		quit(0)
		return
	printerr("batch 17: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

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

func _free_boarding() -> void:
	var f := _field([[Vector2i(5, 5), "shuttle", MCF.Owner.PLAYER_1],
			[Vector2i(4, 5), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(10, 5), "borg", MCF.Owner.PLAYER_1],
			[Vector2i(9, 5), "sniper", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var li := _u(st, Vector2i(4, 5))
	var sn := _u(st, Vector2i(9, 5))
	li.remaining_ap = 0
	sn.remaining_ap = 0
	var sh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var bg: Vehicle = st.vehicle_on(Vector2i(10, 5))
	var res := r.resolve(VehicleBoardIntent.new(li.id, sh.id))
	ck(res.ok and li.aboard_vehicle_id == sh.id and li.remaining_ap == 0, "shuttle boarding is free at 0 AP: " + res.reason)
	res = r.resolve(VehicleBoardIntent.new(sn.id, bg.id))
	ck(res.ok and sn.borg_id == bg.id and sn.remaining_ap == 1, "borg boarding is free at 0 AP, pool grows by the borg's extra AP (ap %d): %s" % [sn.remaining_ap, res.reason])

func _flame_splash_is_six() -> void:
	# a straight wall on column 8; the jet goes NE from (5,8) and meets it at (8,5)
	var walls: Array = []
	for y in 14:
		walls.append(Vector2i(8, y))
	var f := _field([[Vector2i(5, 8), "flamethrower", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ft := _u(st, Vector2i(5, 8))
	var cells: Array = r.flame_cells(ft.coord, Vector2i(1, -1))
	ck(cells.size() == MCF.FLAME_JET_LENGTH, "diagonal jet into a straight wall still burns %d cells (got %d: %s)" % [MCF.FLAME_JET_LENGTH, cells.size(), str(cells)])
	var res := r.resolve(ShootIntent.new(ft.id, -1, -1, Vector2i(6, 7)))
	ck(res.ok, "flame: " + res.reason)
	var burning := 0
	for c: Vector2i in cells:
		if st.grid.cell(c).on_fire:
			burning += 1
	ck(burning == cells.size(), "every listed cell is on fire (%d/%d)" % [burning, cells.size()])
	for c: Vector2i in cells:
		ck(not st.grid.cell(c).is_wall(), "fire never lands on a wall cell %s" % str(c))

func _neutral_shoots_bought_civilian() -> void:
	var f := _field([[Vector2i(5, 5), "civilian", MCF.Owner.PLAYER_1],
			[Vector2i(9, 5), "civilian", MCF.Owner.NEUTRAL],
			[Vector2i(28, 12), "light_infantry", MCF.Owner.PLAYER_2]], [], true)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var mine := _u(st, Vector2i(5, 5))
	var fired := false
	for i in 6:
		var res := r.resolve(EndTurnIntent.new())
		for l: String in res.log_lines:
			if l.find("Civilian → Civilian") >= 0:
				fired = true
		if fired or not mine.is_alive():
			break
	ck(fired or not mine.is_alive(), "a neutral civilian opens fire on a player's civilian instead of fleeing its lane")

func _every_vehicle_leaves_a_wreck() -> void:
	for kind in ["shuttle", "tank", "borg"]:
		var f := _field([[Vector2i(6, 6), kind, MCF.Owner.PLAYER_1],
				[Vector2i(2, 2), "light_infantry", MCF.Owner.PLAYER_1],
				[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
		var st: GameState = f["s"]
		var r: GameActionResolver = f["r"]
		var veh: Vehicle = st.all_vehicles()[0]
		var res := ActionResult.new()
		r._damage_component(veh, MCF.COMP_HULL, 99, "test", res)
		ck(veh.wrecked and st.vehicles.has(veh.id), "%s leaves a wreck (roll %s)" % [kind, str(res.log_lines)])
		var exploded := res.log_lines.any(func(l: String) -> bool: return l.find("explodes") >= 0)
		if exploded:
			ck(res.fx.any(func(x: Dictionary) -> bool: return x.get("fx", "") == "debris"), "%s explosion scorches the floor" % kind)

func _group_move_falls_back() -> void:
	# corridor row 5 between walls; A ahead at (6,5), B behind at (5,5); both ordered to (9,5):
	# A takes (9,5), B's only route runs through A's old cell and ends at (8,5).
	var walls: Array = []
	for x in range(3, 12):
		walls.append(Vector2i(x, 4))
		walls.append(Vector2i(x, 6))
	var f := _field([[Vector2i(6, 5), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(5, 5), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var a := _u(st, Vector2i(6, 5))
	var b := _u(st, Vector2i(5, 5))
	# order B first so its planned target (8,5) is what A would also like — then A is
	# dispatched to (9,5) fine; now the reverse: B is told to go to (9,5) itself (taken by A).
	var ids: Array[int] = [a.id, b.id]
	var dests: Array[Vector2i] = [Vector2i(9, 5), Vector2i(9, 5)]
	var res := r.resolve(GroupMoveIntent.new(ids, dests))
	ck(res.ok, "group order: " + res.reason)
	ck(a.coord == Vector2i(9, 5), "leader reached the target (%s)" % str(a.coord))
	ck(b.coord == Vector2i(8, 5), "the blocked mover fell back to the nearest reachable cell (%s)" % str(b.coord))
