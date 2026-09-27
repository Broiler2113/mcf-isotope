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
	_flame_into_corner_is_six()
	_flame_one_sided_splash_is_six()
	_sniper_hit_ladder()
	_hull_kill_reports_its_crew()
	_capture_is_reported()
	_sealed_crew_cannot_disembark()
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

## Струя в УГОЛ. Огнемётчик в (5,5), стена идёт по колонке 6 и по строке 4: клетка
## (6,4) — внутренний угол, и обе перпендикулярные стороны от стрелка тоже заперты.
## Старый код здесь отдавал почти ничего: разлёт налево упирался в стену (l = 0), а
## добор был написан под условием l > 0 и не срабатывал никогда.
func _flame_into_corner_is_six() -> void:
	var walls: Array = []
	for y in 14:
		walls.append(Vector2i(6, y))
	for x in 30:
		walls.append(Vector2i(x, 4))
	var f := _field([[Vector2i(5, 5), "flamethrower", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ft := _u(st, Vector2i(5, 5))
	var cells: Array = r.flame_cells(ft.coord, Vector2i(1, -1))
	ck(cells.size() == MCF.FLAME_JET_LENGTH,
			"jet into a corner still burns %d cells (got %d: %s)"
			% [MCF.FLAME_JET_LENGTH, cells.size(), str(cells)])
	for c: Vector2i in cells:
		ck(not st.grid.cell(c).is_wall(), "corner splash never lands on a wall %s" % str(c))
		ck(c != ft.coord, "corner splash never burns the flamethrower's own cell")

## Разлёт, у которого сторона «налево» заперта СРАЗУ (l = 0), а «направо» обрывается
## через клетку. Прежний код добирал остаток только налево и только под условием
## l > 0 — то есть ровно здесь не добирал ничего и терял четыре клетки из шести.
func _flame_one_sided_splash_is_six() -> void:
	var walls: Array = []
	for y in 14:
		walls.append(Vector2i(6, y))
	walls.append(Vector2i(5, 6))   # «налево» от струи (1,0) — вниз: заперто сразу
	walls.append(Vector2i(5, 3))   # «направо» — вверх: одна свободная клетка (5,4)
	var f := _field([[Vector2i(5, 5), "flamethrower", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ft := _u(st, Vector2i(5, 5))
	var cells: Array = r.flame_cells(ft.coord, Vector2i(1, 0))
	ck(cells.size() == MCF.FLAME_JET_LENGTH,
			"one-sided splash still burns %d cells (got %d: %s)"
			% [MCF.FLAME_JET_LENGTH, cells.size(), str(cells)])
	var uniq := {}
	for c: Vector2i in cells:
		ck(not uniq.has(c), "splash never lists the same cell twice %s" % str(c))
		uniq[c] = true

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

## Подбитый корпус обязан отчитаться о ЭКИПАЖЕ в res.deaths, а не только о себе.
## _kill() сам в deaths ничего не кладёт, и _destroy_vehicle этого не делал: сжечь
## гружёный танк приносило ровно столько же, сколько пустой, и трое внутри не попадали
## ни в награду за убийство, ни в счётчик комбо.
func _hull_kill_reports_its_crew() -> void:
	var f := _field([[Vector2i(5, 5), "tank", MCF.Owner.PLAYER_1],
			[Vector2i(4, 4), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var veh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var crew := _u(st, Vector2i(4, 4))
	ck(r.resolve(VehicleBoardIntent.new(crew.id, veh.id)).ok, "crew boards the tank")
	ck(veh.occupants.has(crew.id), "crew is aboard")
	var res := ActionResult.new()
	res.ok = true
	r._destroy_vehicle(veh, res)
	ck(res.deaths.has(crew.id),
			"a destroyed hull reports its crew in deaths (got %s)" % str(res.deaths))
	ck(not crew.is_alive(), "the crew really died")

## Захват вражеской машины должен быть ВИДЕН в результате, а не только в строке лога:
## награда за него иначе неотличима от обычной посадки.
func _capture_is_reported() -> void:
	var f := _field([[Vector2i(5, 5), "tank", MCF.Owner.PLAYER_2],
			[Vector2i(4, 4), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var veh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var taker := _u(st, Vector2i(4, 4))
	ck(veh.owner == MCF.Owner.PLAYER_2, "the hull starts enemy-owned")
	var res := r.resolve(VehicleBoardIntent.new(taker.id, veh.id))
	ck(res.ok, "boarding an empty enemy hull is legal: " + res.reason)
	ck(veh.owner == MCF.Owner.PLAYER_1, "the hull changed hands (owner %d)" % veh.owner)
	ck(res.captured_vehicles.has(veh.id),
			"the capture is reported in captured_vehicles (got %s)" % str(res.captured_vehicles))

## disembark_enabled = false должен и НЕ ПРЕДЛАГАТЬ высадку, и ОТКАЗЫВАТЬ в ней. Одного
## фильтра в перечислителе мало: резолвер принимает намерения и не из него (встроенный ИИ,
## сеть, повтор), и запрет, живущий только в списке, обходится молча.
func _sealed_crew_cannot_disembark() -> void:
	var f := _field([[Vector2i(5, 5), "tank", MCF.Owner.PLAYER_1],
			[Vector2i(4, 4), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]])
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var veh: Vehicle = st.vehicle_on(Vector2i(5, 5))
	var crew := _u(st, Vector2i(4, 4))
	ck(r.resolve(VehicleBoardIntent.new(crew.id, veh.id)).ok, "crew boards")
	var cells: Array = r.vehicle_disembark_cells(veh)
	ck(not cells.is_empty(), "there IS somewhere to get out to")

	# Пока разрешено — высадка и предлагается, и проходит.
	var offered := 0
	for i: Intent in LegalIntents.enumerate(r, MCF.Owner.PLAYER_1):
		if i is VehicleDisembarkIntent and i.actor_id == crew.id:
			offered += 1
	ck(offered > 0, "with disembark on, the crew is offered a way out (%d)" % offered)

	r.disembark_enabled = false
	offered = 0
	for i: Intent in LegalIntents.enumerate(r, MCF.Owner.PLAYER_1):
		if i is VehicleDisembarkIntent and i.actor_id == crew.id:
			offered += 1
	ck(offered == 0, "sealed: no disembark is enumerated (got %d)" % offered)
	var res := r.resolve(VehicleDisembarkIntent.new(crew.id, cells[0]))
	ck(not res.ok, "sealed: the resolver refuses a disembark it never offered")
	ck(crew.aboard_vehicle_id == veh.id, "sealed: the crew is still aboard")

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
