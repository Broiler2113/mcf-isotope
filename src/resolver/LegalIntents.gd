class_name LegalIntents
extends RefCounted

## Перечислитель ЗАКОННЫХ намерений стороны (RL v1, spec §4.1). Отдаёт список Intent,
## каждый из которых обязан пройти resolver.resolve() — это и есть маска легальности для
## обучаемой политики: нелегальные действия получают нулевую вероятность, а не штраф
## постфактум. Точность проверяет tests/run_legal_intents.gd: снимок → каждое намерение
## → откат, и любой отказ резолвера — провал теста.
##
## Что здесь НЕ перечисляется, и почему:
##   * Undo/Redo — удобство человека, у политики они лишь сжигают шаги (C6).
##   * GroupMove — сумма одиночных MoveIntent, посчитанная на клиенте; политика ходит по одному.
##   * BuildWallIntent (ЛДФ-цепь из 6 клеток) — комбинаторный параметр; v1 без него.
##   * Стрельба ПО СВОИМ — резолвер разрешает (#100), но ценность нулевая; hostile_target_ids.
##   * Лазер марксмана «в направление» (target_id < 0) — есть та же стрельба по цели.
##   * Узел машины при прицеливании — пустая строка (резолвер выбирает сам).
##   * Чат, рисование, сохранение, сдача, выход — вне пространства действий целиком (§4.1).
##
## Порядок списка детерминирован (юниты по id, клетки в порядке обхода резолвера): хост и
## обучение обязаны видеть один и тот же индекс у одного и того же намерения.

const SENT := Vector2i(-999, -999)

## Все законные намерения стороны side на текущем состоянии r.state.
static func enumerate(r: GameActionResolver, side: int) -> Array:
	var out: Array = []
	var state := r.state
	if state.active_player() != side:
		return out
	var ids: Array = state.units.keys()
	ids.sort()
	for id: int in ids:
		var u: UnitInstance = state.units[id]
		if u.owner != side or not u.is_alive():
			continue
		_for_unit(r, u, out)
	var vids: Array = state.vehicles.keys()
	vids.sort()
	for vid: int in vids:
		var veh: Vehicle = state.vehicles[vid]
		if veh.owner != side or not veh.alive() or veh.is_borg():
			continue
		_for_vehicle(r, veh, out)
	out.append(EndTurnIntent.new(side))
	return out

static func _for_unit(r: GameActionResolver, u: UnitInstance, out: Array) -> void:
	var state := r.state
	if u.is_drone:
		_for_drone(r, u, out)
		return
	# Пленник: только рывок (свой держит — бесплатно, чужой — за ОД).
	if u.is_held():
		var captor := state.get_unit(u.captor_id)
		if (captor != null and captor.owner == u.owner) or u.remaining_ap > 0:
			out.append(ReleaseIntent.new(u.id))
		return
	# Экипаж танка (за картой): может только выйти.
	if u.aboard_vehicle_id != -1 and not state.grid.in_bounds(u.coord):
		var tv := state.get_vehicle(u.aboard_vehicle_id)
		if tv != null and u.remaining_ap > 0:
			for c: Vector2i in r.vehicle_disembark_cells(tv):
				out.append(VehicleDisembarkIntent.new(u.id, c))
		return
	# Пассажир челнока: стреляет из кресла, пересаживается, выходит бесплатно.
	var sveh := r.seated_vehicle_of(u)
	if u.aboard_vehicle_id != -1 and sveh != null:
		_shots(r, u, out)
		_items(r, u, out, true)
		if u.remaining_ap > 0:
			for seat: int in r.seat_options(sveh):
				out.append(VehicleSeatIntent.new(u.id, seat))
			for st: Vector2i in r.stations_near(u):
				if r.active_drone_of(u) == null:
					out.append(SpawnDroneIntent.new(u.id, st))
			for c: Vector2i in r.station_pickup_cells(u):
				out.append(PickUpStationIntent.new(u.id, c))
		var seat_c := r.seat_cell_of(u)
		if seat_c != GameActionResolver.NOWHERE:
			for n: Vector2i in state.grid.neighbors(seat_c):
				if not state.grid.is_occupied_or_wall(n) and state.grid.vehicle_at(n) == -1:
					out.append(VehicleDisembarkIntent.new(u.id, n))
		return
	if u.aboard_vehicle_id != -1:
		return
	var ap := u.remaining_ap
	# --- Движение (та же арифметика бюджета, что в _resolve_move) ---
	if ap > 0 or u.move_credit > 0:
		var carried := r.held_unit_of(u)
		var dragged := r.dragged_cell_of(u)
		var burdened := carried != null or dragged != UnitInstance.NOT_DRAGGING
		var carry_budget := maxi(0, u.speed() - MCF.CAPTURE_CARRY_PENALTY)
		var budget: int
		if u.move_credit > 0:
			budget = u.move_credit
		elif burdened:
			budget = carry_budget
		else:
			budget = u.speed()
		if burdened:
			budget = mini(budget, carry_budget)
		if budget > 0:
			var reach := r.reachable_for(u, budget)
			for c: Vector2i in reach.cost.keys():
				if c == u.coord or state.grid.blocks_walk(c):
					continue
				out.append(MoveIntent.new(u.id, c, SENT))
	# --- Стрельба и всё, что стоит ОД ---
	_shots(r, u, out)
	_items(r, u, out, false)
	if ap > 0:
		for tid: int in r.capturable_target_ids(u):
			var t := state.get_unit(tid)
			if t != null and not t.carried_this_round:
				out.append(CaptureIntent.new(u.id, tid))
		for tid: int in r.pushable_target_ids(u):
			out.append(PushIntent.new(u.id, tid))
		if r.active_drone_of(u) == null \
				and u.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR:
			for st: Vector2i in r.stations_near(u):
				out.append(SpawnDroneIntent.new(u.id, st))
		for c: Vector2i in r.station_pickup_cells(u):
			out.append(PickUpStationIntent.new(u.id, c))
		if u.stats.special_ability_id == MCF.ABILITY_ENGINEER:
			for fid: String in GameActionResolver.ENGINEER_BUILDABLE.keys():
				if ap < r.build_cost_for(u, fid):
					continue
				for c: Vector2i in r.buildable_cells(u, fid):
					out.append(BuildIntent.new(u.id, c, fid))
			for c: Vector2i in r.weldable_cells(u):
				out.append(WeldAirlockIntent.new(u.id, c))
			for veh: Vehicle in r.repairable_vehicles(u):
				for comp: String in r.repairable_components(u, veh):
					out.append(RepairVehicleIntent.new(u.id, veh.id, comp))
		if ap >= MCF.BREAK_COST:
			for c: Vector2i in r.breakable_cells(u):
				out.append(BreakIntent.new(u.id, c))
		for c: Vector2i in r.draggable_cells(u):
			for d: Vector2i in r.drag_dest_cells(u, c):
				out.append(DragIntent.new(u.id, c, d))
		for c: Vector2i in r.corpse_pickup_cells(u):
			out.append(PickUpCorpseIntent.new(u.id, c))
		for rc: Vector2i in r.rsp_cells(u, false):
			out.append(DPMGFireIntent.new(u.id, rc, -1, -1))
		for rc: Vector2i in r.rsp_cells(u, true):
			for tid: int in r.rsp_targets(u, rc):
				var t := state.get_unit(tid)
				if t != null and not r.trench_protected(rc, t):
					out.append(DPMGFireIntent.new(u.id, rc, tid, -1))
		if u.stats.special_ability_id == MCF.ABILITY_SAPPER:
			out.append(RevealMinesIntent.new(u.id))
		for c: Vector2i in r.disarmable_mine_cells(u):
			out.append(DisarmMineIntent.new(u.id, c))
		for vid: int in r.meleeable_vehicle_ids(u):
			out.append(VehicleMeleeIntent.new(u.id, vid))
		for vid: int in r.unloadable_corpse_vehicle_ids(u):
			out.append(VehicleUnloadCorpseIntent.new(u.id, vid))
		if u.borg_id == -1 and not r._is_shield(u) and u.carried_corpses == 0:
			for veh: Vehicle in r.boardable_vehicles(u):
				if veh.is_borg():
					out.append(VehicleBoardIntent.new(u.id, veh.id))
				elif r.seat_options(veh).is_empty():
					out.append(VehicleBoardIntent.new(u.id, veh.id))
				else:
					for seat: int in r.seat_options(veh):
						out.append(VehicleBoardIntent.new(u.id, veh.id, seat))
		if u.borg_id != -1:
			for n: Vector2i in state.grid.neighbors(u.coord):
				if not state.grid.blocks_walk(n):
					out.append(VehicleDisembarkIntent.new(u.id, n))
	# --- Бесплатное и кредитное ---
	if ap > 0 or u.dig_credits > 0:
		for c: Vector2i in r.diggable_cells(u):
			out.append(DigIntent.new(u.id, c, SENT, SENT))
	if ap > 0 or u.mine_credits > 0:
		for c: Vector2i in r.mine_cells(u):
			out.append(PlaceMineIntent.new(u.id, c, false))
			out.append(PlaceMineIntent.new(u.id, c, true))
	for c: Vector2i in r.corpse_drop_cells(u):
		out.append(DropCorpseIntent.new(u.id, c))
	if r.held_unit_of(u) != null:
		for c: Vector2i in r.carry_drop_cells(u.coord):
			out.append(MoveHeldIntent.new(u.id, c))

## Выстрелы бойца: по врагам (обычная очередь, целиком или по одной пуле), взрыв
## противотанкиста по клетке, струя огнемёта по клетке. Дострел начатой очереди — без ОД.
static func _shots(r: GameActionResolver, u: UnitInstance, out: Array) -> void:
	var state := r.state
	var pending := u.action_state != null and u.action_state.is_pending()
	var ability := u.stats.special_ability_id
	var need_ap := MCF.MARKSMAN_AP_COST if ability == MCF.ABILITY_MARKSMAN else 1
	if pending:
		out.append(CancelShotIntent.new(u.id))
	if not pending and u.remaining_ap < need_ap:
		return
	if not state.grid.in_bounds(u.coord):
		return
	var burst := u.rate_of_fire()
	if pending:
		burst = u.action_state.remaining_shots
	var splittable := burst > 1 and ability != MCF.ABILITY_ANTI_TANK \
			and ability != MCF.ABILITY_FLAMETHROWER and ability != MCF.ABILITY_MARKSMAN \
			and ability != MCF.ABILITY_ASSAULT
	for tid: int in r.hostile_target_ids(u):
		out.append(ShootIntent.new(u.id, tid, -1))
		if splittable:
			out.append(ShootIntent.new(u.id, tid, 1))
	if pending:
		return
	if ability == MCF.ABILITY_ANTI_TANK:
		for c: Vector2i in r.blastable_cells(u):
			out.append(ShootIntent.new(u.id, -1, -1, c))
	elif ability == MCF.ABILITY_FLAMETHROWER:
		for c: Vector2i in r.flammable_cells(u):
			out.append(ShootIntent.new(u.id, -1, -1, c))

## Предметы: граната (ортогонально), огнетушитель (куда угодно в радиусе), станция
## (в соседнюю пустую клетку / свободное кресло).
static func _items(r: GameActionResolver, u: UnitInstance, out: Array, seated: bool) -> void:
	if u.remaining_ap <= 0 or r.can_use_item(u) != "":
		return
	var state := r.state
	match u.held_item_id:
		MCF.ITEM_FRAG:
			for c: Vector2i in r.grenade_target_cells(u):
				out.append(UseItemIntent.new(u.id, c))
		MCF.ITEM_EXTINGUISHER:
			var rg := MCF.GRENADE_RANGE
			for dy in range(-rg, rg + 1):
				for dx in range(-rg, rg + 1):
					var c := Vector2i(u.coord.x + dx, u.coord.y + dy)
					if state.grid.in_bounds(c):
						out.append(UseItemIntent.new(u.id, c))
		MCF.ITEM_DRONE_STATION:
			if r.deployed_station_of(u) == Vector2i(-1, -1):
				for c: Vector2i in r.station_place_cells(u):
					out.append(UseItemIntent.new(u.id, c))
		_:
			pass  # ЛДФ («bru») кладётся BuildWallIntent, не UseItem — см. шапку

static func _for_drone(r: GameActionResolver, u: UnitInstance, out: Array) -> void:
	if not r.operator_controls(u):
		return
	out.append(DroneDetonateIntent.new(u.id))
	var on_wall := r.state.grid.cell(u.coord).is_wall()
	var can_fly := u.remaining_ap > 0 or u.move_credit > 0
	for c: Vector2i in r.drone_flight_cells(u):
		if c == u.coord:
			continue
		if can_fly or (on_wall and c == u.wall_entry_from):
			out.append(DroneMoveIntent.new(u.id, c))

static func _for_vehicle(r: GameActionResolver, veh: Vehicle, out: Array) -> void:
	var ap := r.vehicle_ap(veh)
	if ap >= VehicleRules.TURN_COST and veh.facing != Vector2i.ZERO and veh.can_turn():
		for d: Vector2i in GameActionResolver.DIR4:
			if d != veh.facing:
				out.append(VehicleTurnIntent.new(veh.id, d))
	var targets := r.vehicle_move_targets(veh)
	for center: Vector2i in targets.keys():
		var mv: Dictionary = targets[center]
		out.append(VehicleMoveIntent.new(veh.id, mv["dir"], int(mv["steps"])))
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get("weapons", {}).get("main_gun", {})
	if not gun.is_empty() and ap >= int(gun.get("ap_cost", 1)) \
			and veh.cannon_shots_this_round < int(gun.get("max_per_turn", 2)):
		for c: Vector2i in r.cannon_target_cells(veh):
			out.append(VehicleCannonIntent.new(veh.id, c))
