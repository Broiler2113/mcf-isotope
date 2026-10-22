@abstract
extends "res://src/resolver/parts/ResolverDrones.gd"

## Vehicles: tanks, shuttles and borgs — boarding, seats, moving, turning, the main gun,
## damage to components, and the queries the screen asks about them.

# ============================================================================
#  ТЕХНИКА (§техника): экипаж, движение, пушка, лазер, уничтожение.
# ============================================================================

# --- Борг (batch 13, «Borg characteristics») ----------------------------------------
## Одноместная машина 1×1, которой управляют как бойцом. Оператор ОСТАЁТСЯ на сетке в
## клетке борга (borg_id != -1), ходит/стреляет обычными намерениями, но с числами
## борга (UnitInstance.speed()/armor()/fire_range()/rate_of_fire()/max_ap()). Пока внутри
## живой оператор, след борга на сетке НЕ размечен — машина прозрачна для линий, как
## боец (B14); пустой борг или борг с мёртвым оператором размечен как корпус, чтобы его
## можно было выбрать и в него сесть.
func _board_borg(unit: UnitInstance, veh: Vehicle) -> ActionResult:
	var err := _borg_entry_error(unit, veh)
	if err != "":
		return ActionResult.fail(err)
	unit.action_state = null
	var cell := state.grid.cell(veh.origin)
	# Мёртвый оператор выталкивается наружу при посадке (B12) — на свободную клетку рядом.
	if cell.occupant != null:
		var spot := _borg_push_spot(unit, veh)
		var body: UnitInstance = cell.occupant
		cell.occupant = null
		body.borg_id = -1
		body.coord = spot
		state.grid.cell(spot).occupant = body
	# Посадка бесплатна (batch 17, item 3): свежий боец садится и видит все 3 ОД борга.
	state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
	state.grid.cell(unit.coord).occupant = null
	unit.coord = veh.origin
	cell.occupant = unit
	unit.borg_id = veh.id
	veh.occupants = [unit.id]
	var captured := veh.owner != unit.owner
	veh.owner = unit.owner
	# Новая активация борга — новые очки: боец получает 3 ОД, но уже потраченные до
	# посадки не возвращаются.
	unit.remaining_ap = maxi(0, unit.remaining_ap + (unit.max_ap() - (unit.stats.action_points
			if unit.stats.action_points > 0 else MCF.AP_PER_ACTIVATION)))
	var res := ActionResult.new()
	res.ok = true
	res.log("%s %s the borg [AP: %d]" % [unit.stats.display_name,
		"seizes" if captured else "climbs into", unit.remaining_ap])
	return res

## Почему боец не сядет в борг ("" — сядет). Одна проверка и для посадки, и для списка
## boardable_vehicles: раньше список проверял только «жив ли оператор», и борг, чьего
## оператора взяли в плен (HELD — не жив, но и не труп, лежит в клетке), предлагался
## перечислителю RL, а посадку резолвер отклонял: «The borg's cell is blocked».
func _borg_entry_error(unit: UnitInstance, veh: Vehicle) -> String:
	var op := state.get_unit(veh.borg_operator())
	if op != null and op.is_alive():
		return "Someone is already at the controls"
	var cell := state.grid.cell(veh.origin)
	if cell.occupant != null:
		if cell.occupant.status != MCF.Status.CORPSE:
			return "The borg's cell is blocked"
		if _borg_push_spot(unit, veh) == NOWHERE:
			return "No room to push the body out"
	return ""

## Свободная соседняя клетка, куда при посадке выталкивается мёртвый оператор (B12).
func _borg_push_spot(unit: UnitInstance, veh: Vehicle) -> Vector2i:
	for n in state.grid.neighbors(veh.origin):
		if n == unit.coord:
			continue
		var nc := state.grid.cell(n)
		if nc != null and nc.occupant == null and not nc.is_wall() and not nc.is_space \
				and nc.vehicle_id == -1 and nc.corpse_count < MCF.CORPSE_WALL_COUNT:
			return n
	return NOWHERE

func _exit_borg(unit: UnitInstance, veh: Vehicle, target: Vector2i) -> ActionResult:
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	if Combat.distance(unit.coord, target) != 1 or state.grid.blocks_walk(target):
		return ActionResult.fail("Step out to a free cell next to the borg")
	unit.remaining_ap -= 1
	state.grid.cell(unit.coord).occupant = null
	unit.borg_id = -1
	unit.action_state = null
	veh.occupants = []
	veh.origin = unit.coord
	state.grid.set_vehicle_footprint(veh.id, veh.footprint())
	state.grid.place(unit, target)
	# Вне борга у бойца снова его собственный потолок ОД.
	unit.remaining_ap = mini(unit.remaining_ap, unit.max_ap())
	var res := ActionResult.success(["%s climbs out of the borg [AP: %d]" % [
		unit.stats.display_name, unit.remaining_ap]])
	_hazards_on_arrival(unit, res)
	return res

## Борг следует за своим оператором: любое перемещение бойца (ход, отброс, перенос)
## переносит и машину. Зовётся после каждого разрешённого намерения.
func _sync_borg(unit: UnitInstance) -> void:
	if unit == null or unit.borg_id == -1:
		return
	var veh := state.get_vehicle(unit.borg_id)
	if veh != null and state.grid.in_bounds(unit.coord):
		veh.origin = unit.coord

func _sync_borgs() -> void:
	for veh: Vehicle in state.all_vehicles():
		if not veh.is_borg():
			continue
		var op := state.get_unit(veh.borg_operator())
		if op != null and state.grid.in_bounds(op.coord):
			veh.origin = op.coord

## Борг, в котором сидит боец; null — не в борге.
func borg_of(u: UnitInstance) -> Vehicle:
	if u == null or u.borg_id == -1:
		return null
	return state.get_vehicle(u.borg_id)

# --- Челнок с посадочными местами (batch 13, «Shuttle changes») ---------------------
## Пассажир челнока сидит В КЛЕТКЕ следа: у него настоящая координата, он occupant
## своей клетки, виден поверх корпуса, стреляет со своего места и сам под обстрелом.
## Экипаж танка по-прежнему вынесен за поле (OFFBOARD). Что позволено из кресла:
func _aboard_allowed(intent: Intent) -> bool:
	return intent is ShootIntent or intent is CancelShotIntent or intent is UseItemIntent \
			or intent is SpawnDroneIntent or intent is PickUpStationIntent \
			or intent is VehicleSeatIntent or intent is VehicleDisembarkIntent \
			or intent is EndTurnIntent or intent is ReleaseIntent \
			or intent is DPMGFireIntent \
			or (intent is BuildIntent and intent.feature_id == MCF.FEATURE_DPMG)   # fix-7 #5

func _seated(veh: Vehicle) -> bool:
	return veh != null and veh.seated()

## Машина, в которой юнит сидит пассажиром (челнок), либо null.
func seated_vehicle_of(u: UnitInstance) -> Vehicle:
	if u == null or u.aboard_vehicle_id == -1:
		return null
	var veh := state.get_vehicle(u.aboard_vehicle_id)
	return veh if _seated(veh) else null

## Водитель челнока: живой боец стороны-владельца в кресле водителя, иначе null.
func shuttle_driver(veh: Vehicle) -> UnitInstance:
	if not _seated(veh):
		return null
	var d := state.get_unit(veh.driver_id())
	if d == null or not d.is_alive() or d.owner != veh.owner:
		return null
	return d

## Очки действия, которыми машина располагает СЕЙЧАС: у танка — свой пул, у челнока —
## ОД водителя (машина ходит за его счёт, batch 13 S1).
func vehicle_ap(veh: Vehicle) -> int:
	if veh == null or not veh.alive():
		return 0
	if _seated(veh):
		var d := shuttle_driver(veh)
		return d.remaining_ap if d != null else 0
	return veh.ap

## Посадить пассажира в кресло seat: клетка следа становится его клеткой. Труп,
## лежавший на полу под креслом, уходит в кучу corpse_count той же клетки.
func _seat_unit(veh: Vehicle, unit: UnitInstance, seat: int) -> void:
	veh.ensure_seats()
	var cell_coord := veh.seat_cell(seat)
	var cell := state.grid.cell(cell_coord)
	if cell.occupant != null and cell.occupant.status == MCF.Status.CORPSE:
		if legacy_corpse_rules: state.remove_unit(cell.occupant.id)
		else: cell.occupant.corpse_stacked = true
		cell.occupant = null
		cell.corpse_count += 1
	veh.seats[seat] = unit.id
	unit.coord = cell_coord
	unit.aboard_vehicle_id = veh.id
	cell.occupant = unit

## Клетка кресла, в котором сидит юнит; NOWHERE, если он не пассажир.
func seat_cell_of(u: UnitInstance) -> Vector2i:
	var veh := seated_vehicle_of(u)
	if veh == null:
		return NOWHERE
	var si := veh.seat_of(u.id)
	return veh.seat_cell(si) if si != -1 else NOWHERE

## Пересадка внутри челнока (S6): 1 ОД, только в свободное кресло.
func _resolve_vehicle_seat(intent: VehicleSeatIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	var veh := seated_vehicle_of(unit)
	if veh == null:
		return ActionResult.fail("Not aboard a shuttle")
	veh.ensure_seats()
	if intent.seat < 0 or intent.seat >= veh.seats.size():
		return ActionResult.fail("No such seat")
	if veh.seats[intent.seat] != -1:
		return ActionResult.fail("That seat is taken")
	var from := veh.seat_of(unit.id)
	if from == intent.seat:
		return ActionResult.fail("Already in that seat")
	unit.remaining_ap -= 1
	state.grid.cell(unit.coord).occupant = null
	veh.seats[from] = -1
	_seat_unit(veh, unit, intent.seat)
	var res := ActionResult.success(["%s moves to the %s seat [AP: %d]" % [
		unit.stats.display_name, "driver's" if intent.seat == Vehicle.DRIVER_SEAT else "next",
		unit.remaining_ap]])
	return res

## Сколько клеток челнок может проехать сейчас: остаток прошлого переезда плюс
## 15 за каждое ОД водителя (batch 13 S1). Без водителя — только остаток, и тот ноль.
func _shuttle_budget(veh: Vehicle) -> int:
	var d := shuttle_driver(veh)
	if d == null:
		return 0
	return veh.move_credit + d.remaining_ap * MCF.SHUTTLE_CELLS_PER_AP

## Кресла, в которые юнит может сесть/пересесть (для UI): индексы свободных мест.
func seat_options(veh: Vehicle) -> Array[int]:
	if not _seated(veh):
		return []
	return veh.free_seats()

## Пассажиры под ударом тяжёлого оружия (S5): тот, чья клетка — точка разрыва, гибнет
## без броска; остальные пассажиры этой машины в зоне бросают обычную защиту.
## Возвращает имена погибших; кубики пишутся в res.
func _shuttle_passengers_hit(veh: Vehicle, center: Vector2i, in_area: Dictionary,
		res: ActionResult) -> Array:
	var killed: Array = []
	for uid in veh.occupants.duplicate():
		var u := state.get_unit(uid)
		if u == null or not u.is_alive() or u.cheat_invulnerable:
			continue
		if u.coord == center:
			_kill(u, res, center, true)
			killed.append(u.stats.display_name)
			if res != null:
				res.deaths.append(u.id)
			if res != null:
				res.log("%s takes the hit square on — killed." % u.stats.display_name)
			continue
		if not in_area.has(u.coord):
			continue
		var need := u.armor()
		var roll := state.dice.roll_d6()
		var ok := roll >= need
		if res != null:
			res.dice_events.append({"kind": "check", "actor": "%s (passenger)" % u.stats.display_name,
				"roll": roll, "need": need, "ok": ok, "roller": u.owner})
		if not ok:
			_kill(u, res, center, true)
			killed.append(u.stats.display_name)
			if res != null:
				res.deaths.append(u.id)
			if res != null:
				res.log("%s (passenger) fails the defense roll (%d, need %d+) — killed." % [
					u.stats.display_name, roll, need])
		elif res != null:
			res.log("%s (passenger) holds on (roll %d, need %d+)." % [u.stats.display_name, roll, need])
	return killed

func _validate_vehicle(veh: Vehicle, credit: int = 0) -> String:
	if veh == null:
		return "Vehicle not found"
	if not veh.alive():
		return "Vehicle is destroyed"
	# Боргом (batch 13) правят намерения ОПЕРАТОРА — Move/Shoot от его имени. Машинные
	# намерения ему не адресуются: после смены раунда у борга появлялось своё «ОД
	# экипажа», VehicleMoveIntent катил корпус отдельно от бойца и оставлял на клетке
	# назначения след без машины.
	if veh.is_borg():
		return "A borg is driven by its operator"
	if veh.owner != state.active_player():
		return "It's the other player's turn"
	if vehicle_ap(veh) <= 0 and credit <= 0:
		return "Nobody at the wheel with AP left" if _seated(veh) else "Vehicle has no crew AP left"
	return ""

## Свободна ли клетка соседняя со следом машины (для посадки/высадки).
func _adjacent_to_vehicle(coord: Vector2i, veh: Vehicle) -> bool:
	for fc in veh.footprint():
		if Combat.distance(coord, fc) == 1:
			return true
	return false

func _is_miner(u: UnitInstance) -> bool:
	return u != null and u.attack_ability() == MCF.ABILITY_MINER

## Шахтёр бьёт ломом по соседней вражеской машине (item 15): один бросок d6, на
## MINER_VEHICLE_HIT_NEED корпус теряет MINER_VEHICLE_DAMAGE прочности. Стоит 1 ОД
## независимо от исхода — замах уже сделан. Своих машин шахтёр не портит.
func _resolve_vehicle_melee(intent: VehicleMeleeIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if not _is_miner(unit):
		return ActionResult.fail("Only a miner can pry at a hull")
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	var veh := state.get_vehicle(intent.vehicle_id)
	if veh == null or not veh.alive():
		return ActionResult.fail("No such vehicle")
	if veh.owner == unit.owner:
		return ActionResult.fail("That's your own vehicle")
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	unit.remaining_ap -= 1
	var res := ActionResult.new()
	res.ok = true
	var veh_name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	var roll := state.dice.roll_d6()
	var hit := roll >= MCF.MINER_VEHICLE_HIT_NEED
	res.dice_events.append({
		"kind": "check", "actor": "%s pries the hull" % unit.stats.display_name,
		"roll": roll, "need": MCF.MINER_VEHICLE_HIT_NEED, "ok": hit,
	})
	if hit:
		res.log("%s wrenches the %s (roll %d, need %d+)!" % [
			unit.stats.display_name, veh_name, roll, MCF.MINER_VEHICLE_HIT_NEED])
		# Шахтёр ковыряет ИМЕННО КОРПУС (§5): ни выбора узла, ни каскада — он лезет
		# монтировкой под броневой лист, а не выцеливает башню.
		_damage_component(veh, MCF.COMP_HULL, MCF.MINER_VEHICLE_DAMAGE, "miner", res)
	else:
		res.log("%s strikes the %s but the hull holds (roll %d, need %d+)." % [
			unit.stats.display_name, veh_name, roll, MCF.MINER_VEHICLE_HIT_NEED])
	return res

## Ремонт узла машины инженером (веха «Modular tank system», §8).
##
## 1 ОД — одно очко прочности любому узлу на выбор, не выше его стартового значения.
## Узел, вернувшийся выше нуля, ТУТ ЖЕ снова работает: отдельного «включения» нет —
## починил ходовую, и машина в этот же ход поедет.
##
## Чего ремонт НЕ умеет: поднимать машину с разбитым корпусом. Корпус на нуле — это
## конец, а не поломка: экипаж погиб, машина сгорела и осталась на поле обломком.
## Чинить чужую технику тоже нельзя — инженер обслуживает свою армию, а не любую броню,
## до которой смог дойти.
func _resolve_repair_vehicle(intent: RepairVehicleIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if unit.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can repair a vehicle")
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	if unit.aboard_vehicle_id != -1:
		return ActionResult.fail("Step out of the vehicle to work on it")
	var veh := state.get_vehicle(intent.vehicle_id)
	if veh == null:
		return ActionResult.fail("No such vehicle")
	if not veh.alive():
		return ActionResult.fail("The hull is gone — nothing left to repair")
	if veh.owner != unit.owner and not state.roster.are_allies(veh.owner, unit.owner):
		return ActionResult.fail("That's not your vehicle")
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	var comp: String = intent.component
	if not veh.has_component(comp):
		return ActionResult.fail("This vehicle has no such component")
	var cap := veh.component_max(comp)
	if veh.component(comp) >= cap:
		return ActionResult.fail("%s is already sound" % MCF.COMPONENT_NAMES.get(comp, comp))
	unit.remaining_ap -= 1
	var was := veh.component(comp)
	veh.components[comp] = mini(cap, was + 1)
	var res := ActionResult.new()
	res.ok = true
	var veh_name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	var label: String = MCF.COMPONENT_NAMES.get(comp, comp)
	res.log("%s repairs the %s's %s (%d → %d) [AP: %d]" % [
		unit.stats.display_name, veh_name, label, was, veh.component(comp),
		unit.remaining_ap])
	if was == 0:
		res.log("%s: %s is back in service." % [veh_name, label])
	return res

## Узлы машины, которые инженер может починить прямо сейчас — для меню и подсветки.
## Условия ДОСЛОВНО те же, что проверяет _resolve_repair_vehicle.
func repairable_components(unit: UnitInstance, veh: Vehicle) -> Array:
	var out: Array = []
	if unit == null or veh == null or not veh.alive():
		return out
	if unit.stats.special_ability_id != MCF.ABILITY_ENGINEER or unit.remaining_ap <= 0:
		return out
	if unit.aboard_vehicle_id != -1 or not _adjacent_to_vehicle(unit.coord, veh):
		return out
	if veh.owner != unit.owner and not state.roster.are_allies(veh.owner, unit.owner):
		return out
	for comp: String in MCF.COMPONENT_ORDER:
		if veh.has_component(comp) and veh.component(comp) < veh.component_max(comp):
			out.append(comp)
	return out

## Машины рядом с инженером, которым есть что чинить (для кнопки в меню).
func repairable_vehicles(unit: UnitInstance) -> Array:
	var out: Array = []
	for veh: Vehicle in state.all_vehicles():
		if not repairable_components(unit, veh).is_empty():
			out.append(veh)
	return out

## Вытащить труп из машины на свободную соседнюю клетку (item 18): павший экипаж
## занимает место, его выгружают, чтобы освободить слот. Стоит 1 ОД.
func _borg_body(veh: Vehicle) -> UnitInstance:
	if veh == null or not veh.is_borg(): return null
	var cell := state.grid.cell(veh.origin)
	if cell != null and cell.occupant != null and cell.occupant.status == MCF.Status.CORPSE:
		return cell.occupant
	return null

## Where a body pulled out of veh may go (owner, 2026-10-19): any free cell beside the
## puller that takes a body, and the puller's own cell when it can carry one — clicking
## yourself means "take it in my arms".
func unload_corpse_cells(unit: UnitInstance, veh: Vehicle) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if unit == null or veh == null:
		return out
	# A borg or shuttle-seat body is a unit of its own and needs a cell to itself.
	var whole := _borg_body(veh) != null or _seated(veh)
	for n in state.grid.neighbors(unit.coord):
		if can_drop_corpse_at(n) and (not whole or state.grid.cell(n).occupant == null):
			out.append(n)
	if unit.borg_id == -1 and not _is_shield(unit) and unit.carried_corpses < MCF.CORPSE_CARRY_MAX:
		out.append(unit.coord)
	return out

## The body leaves the vehicle: onto the chosen cell, or into the puller's arms.
func _place_pulled_body(unit: UnitInstance, body: UnitInstance, spot: Vector2i, pile := false) -> void:
	if body != null:
		var at := state.grid.cell(body.coord)
		if at != null and at.occupant == body:
			at.occupant = null
		if spot == unit.coord:
			if legacy_corpse_rules: state.remove_unit(body.id)
			else: CorpseIdentity.take(body, unit)
		elif pile:
			body.aboard_vehicle_id = -1
			_add_corpse_to_cell(spot, body)
		else:
			body.coord = spot
			state.grid.cell(spot).occupant = body
	elif spot != unit.coord:
		if legacy_corpse_rules: state.grid.cell(spot).corpse_count += 1
		else: _add_corpse_to_cell(spot)
	if spot == unit.coord:
		unit.carried_corpses += 1
	else:
		notify_cell_changed(spot)

func _resolve_vehicle_unload_corpse(intent: VehicleUnloadCorpseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	var veh := state.get_vehicle(intent.vehicle_id)
	if veh == null or (not veh.alive() and _borg_body(veh) == null):
		return ActionResult.fail("No such vehicle")
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	var cells := unload_corpse_cells(unit, veh)
	var spot := intent.to
	if spot == VehicleUnloadCorpseIntent.NOWHERE:
		spot = NOWHERE
		for c: Vector2i in cells:
			if c != unit.coord:
				spot = c
				break
		if spot == NOWHERE:
			return ActionResult.fail("No room beside you to set the body down")
	elif not cells.has(spot):
		return ActionResult.fail("Can't put the body there" if spot != unit.coord else "Can't carry another body")
	var where := "into %s's arms" % unit.stats.display_name if spot == unit.coord else "to (%d, %d)" % [spot.x, spot.y]
	var borg_body := _borg_body(veh)
	if borg_body != null:
		unit.remaining_ap -= 1
		borg_body.borg_id = -1
		veh.occupants.erase(borg_body.id)
		_place_pulled_body(unit, borg_body, spot)
		return ActionResult.success(["%s pulls the body out of the borg %s." % [unit.stats.display_name, where]])
	if _seated(veh):
		# Тело в кресле челнока (batch 13 S10): вытаскивают снаружи, стоя рядом с клеткой
		# этого кресла; труп ложится к ногам вытащившего.
		var seat := -1
		for i in veh.seats.size():
			var sid: int = veh.seats[i]
			if sid < 0:
				continue
			var body := state.get_unit(sid)
			if body != null and body.status == MCF.Status.CORPSE \
					and Combat.distance(unit.coord, veh.seat_cell(i)) == 1:
				seat = i
				break
		if seat == -1:
			return ActionResult.fail("No body in a seat next to you")
		unit.remaining_ap -= 1
		var corpse := state.get_unit(veh.seats[seat])
		veh.seats[seat] = -1
		corpse.aboard_vehicle_id = -1
		_place_pulled_body(unit, corpse, spot)
		return ActionResult.success(["%s pulls %s's body out of the %s %s." % [
			unit.stats.display_name, corpse.stats.display_name,
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), where]])
	if veh.corpse_slots.is_empty():
		return ActionResult.fail("No bodies to pull out")
	unit.remaining_ap -= 1
	var name: String = veh.corpse_slots.pop_back()
	var body: UnitInstance = null
	if not legacy_corpse_rules:
		for candidate: UnitInstance in state.all_units():
			if candidate.status == MCF.Status.CORPSE and candidate.aboard_vehicle_id == veh.id and candidate.stats.display_name == name:
				if body == null or candidate.id < body.id: body = candidate
	_place_pulled_body(unit, body, spot, true)
	return ActionResult.success(["%s pulls %s's body out of the %s %s." % [
		unit.stats.display_name, name,
		VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), where]])

## Соседние машины, из которых боец может вытащить труп (для UI, item 18): свои/чужие
## рядом, у которых есть трупы в слотах и куда есть куда положить тело.
func unloadable_corpse_vehicle_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null or actor.remaining_ap <= 0 or actor.aboard_vehicle_id != -1:
		return out
	for veh: Vehicle in state.all_vehicles():
		if (not veh.alive() and _borg_body(veh) == null) or not _adjacent_to_vehicle(actor.coord, veh):
			continue
		if unload_corpse_cells(actor, veh).is_empty():
			continue
		if _seated(veh):
			for i in veh.seats.size():
				var sid: int = veh.seats[i]
				var body := state.get_unit(sid) if sid >= 0 else null
				if body != null and body.status == MCF.Status.CORPSE \
						and Combat.distance(actor.coord, veh.seat_cell(i)) == 1:
					out.append(veh.id)
					break
		elif _borg_body(veh) != null:
			out.append(veh.id)
		elif not veh.corpse_slots.is_empty():
			out.append(veh.id)
	return out

## Соседние вражеские машины, по которым шахтёр может ударить (для подсветки в UI).
## Возвращает id машин. Пусто для не-шахтёра или без ОД.
func meleeable_vehicle_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	if not _is_miner(actor) or actor.remaining_ap <= 0:
		return out
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and veh.owner != actor.owner and _adjacent_to_vehicle(actor.coord, veh):
			out.append(veh.id)
	return out

# --- Посадка экипажа/пассажира ---
func _resolve_vehicle_board(intent: VehicleBoardIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var veh := state.get_vehicle(intent.vehicle_id)
	# Посадка в челнок и борг бесплатна (batch 17, items 1, 3): разрешена и при 0 ОД.
	var err := _validate_actor(unit, 1 if veh != null and (_seated(veh) or veh.is_borg()) else 0)
	if err != "":
		return ActionResult.fail(err)
	if unit.aboard_vehicle_id != -1:
		return ActionResult.fail("Already aboard a vehicle")
	# Оператор борга сперва выходит из него (batch 13): иначе боец уезжал в танк с
	# borg_id на руках, борг оставался «занятым» и при высадке телепортировался к нему.
	if unit.borg_id != -1:
		return ActionResult.fail("Climb out of the borg first")
	if veh == null or not veh.alive():
		return ActionResult.fail("No such vehicle")
	# Щитоносцу и несущему трупы в машине не место (item 19): щит и груз внутрь не лезут.
	if _is_shield(unit) and not veh.is_borg():
		return ActionResult.fail("A shield-bearer can't fit inside a vehicle")
	if unit.carried_corpses > 0:
		return ActionResult.fail("Drop the corpses before boarding")
	# Можно садиться и во вражескую технику (§техника, захват экипажа).
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	if veh.is_borg():
		return _board_borg(unit, veh)
	if _seated(veh):
		# Челнок (batch 13): садятся в конкретное кресло — выбранное или первое свободное.
		veh.ensure_seats()
		var seat := intent.seat if intent.seat >= 0 else veh.first_free_seat()
		if seat < 0 or seat >= veh.seats.size() or veh.seats[seat] != -1:
			return ActionResult.fail("That seat is taken — pull the body out or pick another")
		var boarding_enemy_s: bool = veh.owner != unit.owner
		state.grid.cell(unit.coord).occupant = null
		veh.occupants.append(unit.id)
		_seat_unit(veh, unit, seat)
		var captured_s := _recompute_vehicle_owner(veh)
		var res_s := ActionResult.new()
		res_s.ok = true
		var vname: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
		if captured_s:
			res_s.captured_vehicles.append(veh.id)
			res_s.log("%s seizes control of the %s!" % [unit.stats.display_name, vname])
		elif boarding_enemy_s:
			res_s.log("%s storms aboard the enemy %s!" % [unit.stats.display_name, vname])
		else:
			res_s.log("%s takes %s seat of the %s." % [unit.stats.display_name,
				"the driver's" if seat == Vehicle.DRIVER_SEAT else "a", vname])
		return res_s
	if veh.slots_used() >= veh.capacity():
		return ActionResult.fail("Vehicle is full — pull a corpse out to make room")

	var boarding_enemy: bool = veh.owner != unit.owner
	unit.remaining_ap -= 1
	# Убрать юнита с сетки — он внутри машины, «припаркован» вне поля.
	state.grid.cell(unit.coord).occupant = null
	unit.coord = OFFBOARD
	unit.aboard_vehicle_id = veh.id
	veh.occupants.append(unit.id)
	# Захват: если сторона нового экипажа теперь преобладает на борту — машина
	# переходит к ней, и она может водить/стрелять как своей (§техника).
	var captured := _recompute_vehicle_owner(veh)
	# ОД машины считаем только по экипажу-владельцу — чужаки не дают ходов машине.
	# Севший добавляет СВОЁ очко, но потраченные машиной НЕ возвращает (item 4:
	# «yellow circles on tanks don't disappear when action points are spent»). Здесь
	# стоял полный пересчёт по числу экипажа — то есть посадка посреди хода возвращала
	# танку всё, что он уже истратил: проехал, отстрелялся, подобрал пехотинца — и снова
	# полон очков, с той же гроздью жёлтых точек на борту.
	veh.ap = mini(veh.ap + 1, _vehicle_crew_ap(veh))
	var res := ActionResult.new()
	res.ok = true
	var veh_name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	if captured:
		res.captured_vehicles.append(veh.id)
		res.log("%s seizes control of the %s!" % [unit.stats.display_name, veh_name])
	elif boarding_enemy:
		res.log("%s storms aboard the enemy %s!" % [unit.stats.display_name, veh_name])
	else:
		res.log("%s boards the %s (crew %d/%d)." % [unit.stats.display_name,
			veh_name, veh.slots_used(), veh.capacity()])
	return res

## Пересчитать владельца машины по числу ЖИВЫХ членов экипажа каждой стороны.
## Сторона со строгим большинством на борту забирает машину; при равенстве
## владелец не меняется; пустая машина сохраняет прежнего владельца.
## Возвращает true, если владелец сменился (захват).
func _recompute_vehicle_owner(veh: Vehicle) -> bool:
	var counts: Dictionary = {}
	for uid in veh.occupants:
		var u := state.get_unit(uid)
		if u != null and u.is_alive():
			counts[u.owner] = int(counts.get(u.owner, 0)) + 1
	if counts.is_empty():
		return false
	var best_owner: int = veh.owner
	var best: int = int(counts.get(veh.owner, 0))
	for o in counts:
		if int(counts[o]) > best:
			best = int(counts[o])
			best_owner = o
	if best_owner != veh.owner:
		veh.owner = best_owner
		return true
	return false

## ОД машины = число ЖИВЫХ членов экипажа-владельца на борту (чужаки не в счёт).
## Остаток движения, которым машина реально может воспользоваться (#97). Без живого
## экипажа она не катится вовсе: очки скорости могли остаться с прошлого действия, но
## водить их некому — иначе подбитый экипаж «доезжал» бы уже мёртвым.
func vehicle_move_credit(veh: Vehicle) -> int:
	if veh == null or not veh.alive():
		return 0
	# Челнок докатывает остаток только пока за рулём кто-то живой (batch 13).
	if _seated(veh):
		return veh.move_credit if shuttle_driver(veh) != null else 0
	if _vehicle_crew_ap(veh) <= 0:
		return 0
	return veh.move_credit

func _vehicle_crew_ap(veh: Vehicle) -> int:
	# У челнока собственного пула нет — он ходит за ОД водителя (batch 13 S1).
	if _seated(veh):
		return 0
	var n := 0
	for uid in veh.occupants:
		var u := state.get_unit(uid)
		if u != null and u.is_alive() and u.owner == veh.owner:
			n += 1
	return n

# --- Высадка ---
func _resolve_vehicle_disembark(intent: VehicleDisembarkIntent) -> ActionResult:
	if not disembark_enabled:
		return ActionResult.fail("Crews are sealed in on this map")
	var unit := state.get_unit(intent.actor_id)
	if unit == null or not unit.is_alive():
		return ActionResult.fail("Unit not found")
	if unit.aboard_vehicle_id == -1 and unit.borg_id == -1:
		return ActionResult.fail("Not aboard a vehicle")
	if unit.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	var veh := state.get_vehicle(unit.aboard_vehicle_id if unit.aboard_vehicle_id != -1 else unit.borg_id)
	if veh == null:
		return ActionResult.fail("Vehicle gone")
	if veh.is_borg():
		return _exit_borg(unit, veh, intent.target)
	if _seated(veh):
		# Из челнока выходят БЕСПЛАТНО, через свой борт (batch 13 S7): на любую свободную
		# клетку рядом с клеткой своего кресла.
		var seat_c := seat_cell_of(unit)
		if seat_c == NOWHERE or Combat.distance(seat_c, intent.target) != 1:
			return ActionResult.fail("Step out next to your own seat")
		if state.grid.is_occupied_or_wall(intent.target) or state.grid.vehicle_at(intent.target) != -1:
			return ActionResult.fail("That cell is blocked")
		if unit.is_held():
			return ActionResult.fail("Unit is being held")
		veh.occupants.erase(unit.id)
		var si_s := veh.seat_of(unit.id)
		if si_s != -1:
			veh.seats[si_s] = -1
		state.grid.cell(unit.coord).occupant = null
		unit.aboard_vehicle_id = -1
		state.grid.place(unit, intent.target)
		_recompute_vehicle_owner(veh)
		var res_s := ActionResult.new()
		res_s.ok = true
		res_s.log("%s climbs out of the %s (free)." % [unit.stats.display_name,
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)])
		_hazards_on_arrival(unit, res_s)
		return res_s
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	if not _adjacent_to_vehicle(intent.target, veh):
		return ActionResult.fail("Must step out next to the vehicle")
	if state.grid.is_occupied_or_wall(intent.target):
		return ActionResult.fail("That cell is blocked")

	unit.remaining_ap -= 1
	veh.occupants.erase(unit.id)
	var si := veh.seat_of(unit.id)
	if si != -1:
		veh.seats[si] = -1
	unit.aboard_vehicle_id = -1
	state.grid.place(unit, intent.target)
	_recompute_vehicle_owner(veh)
	veh.ap = mini(veh.ap, _vehicle_crew_ap(veh))
	var res := ActionResult.new()
	res.ok = true
	res.log("%s disembarks the %s." % [unit.stats.display_name,
		VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)])
	_hazards_on_arrival(unit, res)
	return res

# --- Поворот танка ---
func _resolve_vehicle_turn(intent: VehicleTurnIntent) -> ActionResult:
	var veh := state.get_vehicle(intent.actor_id)
	var err := _validate_vehicle(veh)
	if err != "":
		return ActionResult.fail(err)
	if veh.facing == Vector2i.ZERO:
		return ActionResult.fail("This vehicle has no facing")
	# Развернуться можно, пока цела ХОТЬ ОДНА гусеница (веха 14.1): танк крутится на
	# месте, тормозя одной стороной. Обе порваны — машина стоит намертво.
	if not veh.can_turn():
		return ActionResult.fail("Both tracks are knocked out")
	# Только четыре стороны света (item 2): диагональный разворот запрещён.
	if not DIR4.has(intent.facing):
		return ActionResult.fail("Tanks turn only up/down/left/right")
	if intent.facing == veh.facing:
		return ActionResult.fail("Already facing that way")
	veh.ap -= VehicleRules.TURN_COST
	veh.facing = intent.facing
	var res := ActionResult.new()
	res.ok = true
	res.log("%s turns to face (%d, %d). (AP %d)" % [
		VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
		veh.facing.x, veh.facing.y, veh.ap])
	return res

# --- Движение техники ---
func _resolve_vehicle_move(intent: VehicleMoveIntent) -> ActionResult:
	var veh := state.get_vehicle(intent.actor_id)
	var credit := vehicle_move_credit(veh)
	var err := _validate_vehicle(veh, credit)
	if err != "":
		return ActionResult.fail(err)
	# А вот ЕХАТЬ нужны обе: на одной гусенице машина только крутится.
	if not veh.can_drive():
		return ActionResult.fail("A broken track — the vehicle cannot drive")
	var dir: Vector2i = intent.dir
	if veh.facing != Vector2i.ZERO and dir != veh.facing and dir != -veh.facing:
		return ActionResult.fail("Tank can only drive along its facing")
	# Недокатанные очки прошлого движения тратятся первыми и ОД не стоят (#97, §3.2).
	var use_credit := credit > 0
	var speed := credit if use_credit \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	# Челнок (batch 13 S1): бюджет — остаток плюс 15 клеток за каждое ОД водителя; за
	# один переезд можно потратить и несколько его ОД.
	var seated := _seated(veh)
	var driver := shuttle_driver(veh)
	# Танк может уехать в оранжевую/красную зону одним переездом (batch ui-drones 2):
	# бюджет — потолок дальней зоны, списание — по зоне, куда влезла цена пути.
	var tank_tiers := vehicle_tier_budgets(veh)
	if seated:
		speed = _shuttle_budget(veh)
	elif not tank_tiers.is_empty():
		speed = tank_tiers[tank_tiers.size() - 1]
	var plan := VehicleRules.plan_line_move(state, veh, dir, intent.steps, speed)
	if not plan["ok"]:
		return ActionResult.fail(String(plan["reason"]))

	# Пассажиры челнока едут в своих креслах (batch 13): на время переезда снимаем их
	# с клеток, иначе зачистка следа приняла бы их за раздавленных. Станция в кресле
	# тоже едет с машиной.
	var riders: Array = []
	var station_seats: Array[int] = []
	var station_from: Dictionary = {}  # seat -> прежняя клетка станции (для дронов)
	var station_op: Dictionary = {}    # seat -> оператор, развернувший станцию (едет с ней)
	var gun_seats: Dictionary = {}     # seat -> [владелец, прочность, разворот] ДПМГ (fix-7 #5)
	if seated:
		for i in veh.seats.size():
			var sid: int = veh.seats[i]
			if sid == Vehicle.SEAT_DPMG:
				var gc_at := veh.seat_cell(i)
				var gc := state.grid.cell(gc_at)
				if gc == null or gc.feature_id != MCF.FEATURE_DPMG:
					veh.seats[i] = -1
					continue
				gun_seats[i] = [gc.feature_owner, gc.feature_durability, state.grid.furniture_turn.get(gc_at)]
				state.grid.furniture_turn.erase(gc_at)
				gc.clear_feature()
			elif sid == Vehicle.SEAT_STATION:
				var sc := state.grid.cell(veh.seat_cell(i))
				# Repair stale seats from older saves; never resurrect a destroyed station.
				if sc == null or sc.feature_id != MCF.FEATURE_DRONE_STATION:
					veh.seats[i] = -1
					continue
				station_seats.append(i)
				station_from[i] = veh.seat_cell(i)
				station_op[i] = sc.station_operator_id
				if sc.feature_id == MCF.FEATURE_DRONE_STATION:
					sc.station_operator_id = -1
					sc.feature_id = ""
					sc.cover_height = 0.0
			elif sid >= 0:
				var ru := state.get_unit(sid)
				if ru != null:
					riders.append([i, ru])
					var rc := state.grid.cell(ru.coord)
					if rc != null and rc.occupant == ru:
						rc.occupant = null
	# Снять старый след.
	state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
	var res := ActionResult.new()
	res.ok = true
	# Раздавленные юниты гибнут (§техника, таблица столкновений).
	var crushed: Array[UnitInstance] = []
	for cc in plan["crush_cells"]:
		var occ: UnitInstance = state.grid.cell(cc).occupant
		if occ != null and occ.is_on_field():
			_kill(occ, res, cc, true)
			crushed.append(occ)
			res.deaths.append(occ.id)
			res.log("%s crushed under the %s!" % [occ.stats.display_name,
				VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)])
	# Наезд на мину (item 13): и противопехотная, и противотанковая рвутся под
	# гусеницей и снимают с машины 1 прочность. Считаем ДО общей зачистки следа —
	# иначе clear_feature() ниже стёр бы мину молча, без взрыва. Сканируем клетки,
	# по которым машина прошла, и конечный след, куда она встала.
	var driven: Dictionary = {}
	for cc in (plan["crush_cells"] + plan["scatter_cells"] + plan["ram_cells"]):
		driven[cc] = true
	# КАЖДАЯ клетка, которую след машины замёл по дороге, а не только раздавленные и
	# конечная стоянка. Прежний список брал лишь их — и мина, по которой танк ПРОЕХАЛ,
	# не считалась перееханной: под гусеницей она рвалась, только если машина на ней
	# останавливалась или если клетка чем-то была занята. Пустой пол с миной проезжали
	# насквозь бесплатно.
	for i in range(1, int(plan["steps"]) + 1):
		for fc in veh.footprint_from(veh.origin + dir * i):
			driven[fc] = true
	for mc: Vector2i in driven:
		var mcell := state.grid.cell(mc)
		if mcell == null:
			continue
		# Станция дронов под гусеницей ломается: это ящик с пультом на полу, а не укрытие.
		# Считается по ПОЛНОМУ следу, ровно как мина и по той же причине: станция на чистом
		# полу, через которую машина лишь ПРОЕХАЛА, в crush_cells не попадает, и зачистка
		# следа ниже её бы не тронула — танк проезжал по ней бесплатно.
		# Дрон с этой станции остаётся в воздухе, но управление теряет сам (operator_controls
		# не находит станции на клетке) — отдельно сбивать его незачем.
		if mcell.feature_id == MCF.FEATURE_DRONE_STATION:
			mcell.station_operator_id = -1
			mcell.clear_feature()
			notify_cell_changed(mc)
			_fx(res, {"fx": "debris", "at": NOWHERE, "cells": [mc]})
			res.log("The %s crushes a drone station at (%d, %d)!" % [
				VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), mc.x, mc.y])
			continue
		if mcell.feature_id != MCF.FEATURE_MINE and mcell.feature_id != MCF.FEATURE_AV_MINE:
			continue
		var av := mcell.feature_id == MCF.FEATURE_AV_MINE
		mcell.clear_feature()
		notify_cell_changed(mc)
		_fx(res, {"fx": "debris", "at": NOWHERE, "cells": [mc]})
		res.log("The %s rolls over %s at (%d, %d)!" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
			"an anti-vehicle mine" if av else "a mine", mc.x, mc.y])
		# ПРОТИВОТАНКОВАЯ мина бьёт по ходовой без всякого броска — она для того и
		# ставится. Ходовая уже разбита — заряд уходит в корпус: под днищем рвётся то же
		# самое, и пропадать ему некуда.
		# ПРОТИВОПЕХОТНАЯ машине больше не вредит вовсе: она рассчитана на человека, и
		# считать её ещё и противотанковой значило бы, что противотанковая не нужна.
		if av:
			_damage_component(veh, _a_live_track(veh), MCF.AV_MINE_VEHICLE_DAMAGE,
				"mine", res)
	# Всё под гусеницами сносится в пол (трупы, укрытия, тараненные стены).
	# Ежей считаем ЗДЕСЬ, до зачистки: clear_feature() ниже сотрёт их молча, и после
	# переезда узнать, сколько их было, стало бы неоткуда.
	# Тела под гусеницей ОСТАЮТСЯ (batch 12 #2): труп-occupant и куча corpse_count не
	# трогаются — машина проезжает поверх, а когда уедет, их можно подобрать как обычно.
	# Только сложенная из тел стена перестаёт быть стеной: конструкция смята, но сами
	# пять тел лежат на месте, отдельной кучей.
	var flattened: Array[Vector2i] = []
	var hedgehogs := 0
	var smashed := 0
	var from_c := veh.center()
	for cell_coord in (plan["crush_cells"] + plan["scatter_cells"] + plan["ram_cells"]):
		var c := state.grid.cell(cell_coord)
		if c.feature_id == MCF.FEATURE_HEDGEHOG:
			hedgehogs += 1
		var was_corpse_wall := c.feature_id == MCF.FEATURE_CORPSE_WALL
		# Окно под гусеницей бьётся (batch ui-drones) — так же, как от пули: осколки летят
		# по ходу машины. Раньше стекло исчезало молча, будто его и не было.
		if MCF.is_glass(c.feature_id):
			_fx(res, {"fx": "shards", "at": cell_coord, "from": from_c})
		elif CHUNK_WALLS.has(c.feature_id):
			_wall_chunks(res, cell_coord, from_c, c.feature_id, 0, false, true)
		if c.is_wall():
			smashed += 1
			notify_cell_changed(cell_coord)  # снос стены — повод проснуться жителям рядом
		if c.occupant != null and c.occupant.is_alive():
			c.occupant = null
		_knock_items(res, cell_coord, from_c)
		# Fixtures crushed with their supporting wall shed glass too.
		for lamp: Array in c.lamps:
			_lamp_shards(res, cell_coord, from_c, int(lamp[2]))
		if Furniture.DEFS.get(c.feature_id, {}).get("cat", "") == "lighting":
			_lamp_shards(res, cell_coord, from_c)
		c.clear_feature()
		if was_corpse_wall:
			c.corpse_count = MCF.CORPSE_WALL_COUNT
		flattened.append(cell_coord)
	if smashed > 0:
		res.log("The %s smashes through %d wall cell(s)" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), smashed])
	# Пол под гусеницей выглядит РАЗБИТЫМ (item 1): «if a tank rams through a wall, make
	# these tiles display as destroyed». Клетка менялась и раньше — стена исчезала, — но
	# на вид оставалась чистым полом, будто там ничего и не стояло. Метка та же, что
	# кладёт взрыв, поэтому и рисуется теми же щербинами. Эпицентра у переезда нет
	# (NOWHERE): танк не взрывается, он ровняет — все клетки следа одинаковы.
	if not flattened.is_empty():
		_fx(res, {"fx": "debris", "at": NOWHERE, "cells": flattened})
	# Раздавленный не пропадает бесследно (#97): на его клетке остаётся труп — такой же,
	# как от пули, поэтому его можно подобрать или сложить в стену. Кладём ПОСЛЕ зачистки
	# следа: она идёт по тем же клеткам и иначе сама бы его и стёрла.
	for dead: UnitInstance in crushed:
		var dc := state.grid.cell(dead.coord)
		if dc != null and dc.occupant == null:
			dc.occupant = dead
	# Переместить и разметить новый след.
	# Переезд на экране — плавно, по клеткам (batch borg-corpses), как шаг бойца.
	res.dice_events.append({"kind": "veh_walk", "vehicle": veh.id, "from": veh.origin,
			"steps": int(plan["steps"])})
	# Следы гусениц (playtest-20) — только у танка: челнок летит, борг шагает. Кладём
	# мимо _fx(): зерна им не нужно, а номер события (fx_seq) входит в подпись доски.
	if not seated and not veh.is_borg():
		res.fx.append({"fx": "tracks", "from": [veh.origin.x, veh.origin.y],
				"dir": [dir.x, dir.y], "steps": int(plan["steps"]),
				"size": [veh.size.x, veh.size.y]})
	veh.origin += dir * int(plan["steps"])
	state.grid.set_vehicle_footprint(veh.id, veh.footprint())
	# Пассажиры и станция садятся обратно в свои кресла на новом месте.
	for pair in riders:
		_seat_unit(veh, pair[1], int(pair[0]))
	for gi: int in gun_seats:
		var g_at := veh.seat_cell(gi)
		var gcell := state.grid.cell(g_at)
		var rec: Array = gun_seats[gi]
		gcell.set_feature(MCF.FEATURE_DPMG, int(rec[0]))
		gcell.feature_durability = int(rec[1])
		if rec[2] != null:
			state.grid.furniture_turn[g_at] = rec[2]
	for si in station_seats:
		var new_c := veh.seat_cell(si)
		var nc := state.grid.cell(new_c)
		nc.set_feature(MCF.FEATURE_DRONE_STATION, veh.owner)
		# Метка оператора едет со станцией (issues-12 #14). Раньше её переписывали на
		# «любого оператора на борту» или -1 — и хозяин больше не мог свернуть станцию.
		nc.station_operator_id = int(station_op.get(si, -1))
		# Дроны этой станции (batch 14): привязь переезжает вместе с ней, а дрон, сидевший
		# на станции, летит с челноком — раньше он оставался висеть над пустым полом.
		var old_c: Vector2i = station_from[si]
		for d in state.all_units():
			if d.is_drone and d.is_alive() and d.home_station == old_c:
				d.home_station = new_c
				if d.coord == old_c:
					d.coord = new_c
	if seated:
		# Оплата водителем (S1): сперва остаток, потом по ОД за каждые 15 клеток.
		var cost: int = int(plan["cost"])
		var from_credit := mini(cost, veh.move_credit)
		veh.move_credit -= from_credit
		var rest := cost - from_credit
		if rest > 0:
			var ap_cost := int(ceil(float(rest) / float(MCF.SHUTTLE_CELLS_PER_AP)))
			driver.remaining_ap -= ap_cost
			veh.move_credit = ap_cost * MCF.SHUTTLE_CELLS_PER_AP - rest
		res.log("%s flies %d cell(s) — %s at the wheel (AP %d, %d cells left)" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
			int(plan["steps"]), driver.stats.display_name, driver.remaining_ap, veh.move_credit])
	else:
		# Кредит списывается вместо ОД; свежее движение стоит 1 ОД и оставляет остаток (#97).
		var tk := tier_of(tank_tiers, int(plan["cost"])) if not tank_tiers.is_empty() else 0
		veh.ap -= tk + (0 if use_credit else 1)
		if not tank_tiers.is_empty():
			speed = tank_tiers[tk]
		veh.move_credit = maxi(0, speed - int(plan["cost"]))
		res.log("%s drives %d cell(s). (AP %d, %d move left)" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
			int(plan["steps"]), veh.ap, veh.move_credit])
	# Щитоносец глушит машину и калечит ей ХОДОВУЮ (§таблица столкновений): плита
	# упирается в гусеницу, а не в броню, поэтому урон всегда туда и всегда 2.
	if int(plan["self_damage"]) > 0:
		res.log("Shield bearer halts the vehicle.")
		_damage_component(veh, _a_live_track(veh), MCF.COMPONENT_DAMAGE_SHIELD,
			"collision", res)
	# Противотанковый ёж рвёт гусеницу, но машину не останавливает — она проходит
	# насквозь, ломая конструкцию. Считается ОДИН раз за переезд, сколько бы ежей ни
	# смело: это одна поездка по одному ежовому полю, а не отдельная авария на каждом.
	if hedgehogs > 0:
		res.log("The %s grinds through %d hedgehog(s)." % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), hedgehogs])
		_damage_component(veh, _a_live_track(veh), MCF.COMPONENT_DAMAGE_HEDGEHOG,
			"hedgehog", res)
	return res

# --- Главная пушка танка (взрыв-ромб радиуса 2, #63) ---
func _resolve_vehicle_cannon(intent: VehicleCannonIntent) -> ActionResult:
	var veh := state.get_vehicle(intent.actor_id)
	var err := _validate_vehicle(veh)
	if err != "":
		return ActionResult.fail(err)
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var gun: Dictionary = spec.get("weapons", {}).get("main_gun", {})
	if gun.is_empty():
		return ActionResult.fail("This vehicle has no cannon")
	_aimed_component = intent.component
	# Разбитое орудие не стреляет (веха «Modular tank system»).
	if not veh.can_fire_gun():
		return ActionResult.fail("The main gun is knocked out")
	if veh.cannon_shots_this_round >= int(gun.get("max_per_turn", 2)):
		return ActionResult.fail("Cannon already fired twice this turn")
	if not state.grid.in_bounds(intent.target):
		return ActionResult.fail("Target off the board")
	# Стрелять можно с ЛЮБОЙ клетки борта, а не только со средней (#62): у танка
	# 3×3 это три амбразуры на каждую сторону. Порт — клетка корпуса, от которой
	# цель лежит строго по прямой НАРУЖУ (ствол не упирается в собственный корпус).
	var port := cannon_port(veh, intent.target)
	if port == Vector2i(-1, -1):
		return ActionResult.fail("Cannon fires only horizontally or vertically")
	var dist := Combat.distance(port, intent.target)
	if dist > int(gun.get("range", MCF.CANNON_RANGE)):
		return ActionResult.fail("Target out of cannon range")
	# Раньше пушка проверяла только чужие корпуса — и потому била сквозь стены, ЛДФ,
	# двухметровые кучи земли (#70) и сквозь живых бойцов (#58). Теперь линия огня
	# проверяется тем же los_blocked, что и у пехоты: он покрывает всё сразу.
	if los_blocked(port, intent.target):
		return ActionResult.fail("Line of fire is blocked")
	# Заклиненная башня (tower = 0) не поворачивается: стрелять можно только туда же,
	# куда смотрел последний выстрел. Направление хранится ОТНОСИТЕЛЬНО корпуса, так что
	# развернуть машину — законный способ переприцелиться, а вот выбрать новый сектор,
	# стоя на месте, уже нельзя. Не стреляла ни разу — заклинившая башня не смотрит
	# никуда, и до ремонта орудие молчит.
	var fire_dir := Vector2i(signi(intent.target.x - port.x), signi(intent.target.y - port.y))
	if veh.tower_jammed():
		var locked := veh.tower_world_dir()
		if locked == Vector2i.ZERO:
			return ActionResult.fail("The tower is jammed and has never been laid")
		if fire_dir != locked:
			return ActionResult.fail("The tower is jammed — it fires only where it last did")

	veh.ap -= int(gun.get("ap_cost", 1))
	# Снаряд приходит от БОРТА, с которого стреляли (веха 14.1): по нему цель и считает,
	# какая её гусеница открыта и виден ли ей ствол.
	_aim_from = port
	# Куда смотрел ствол в этот раз — на случай, если башню собьют следующим попаданием.
	veh.remember_shot_dir(fire_dir)
	veh.cannon_shots_this_round += 1
	var res := ActionResult.new()
	res.ok = true
	# Бросок на точность (#56): при промахе снаряд ложится с недолётом, но всё равно
	# взрывается на месте (как граната/противотанкист).
	var need := hit_need(dist, float(int(gun.get("range", MCF.CANNON_RANGE))))
	var roll := state.dice.roll_d6()
	var on_target := roll >= need
	# Недолёт считается ТОЙ ЖЕ формулой, что у противотанкиста (#22): своя, прежняя
	# (dist − (need − roll)) на дальних дистанциях уводила снаряд совсем в другое место.
	var landing := _shortfall_landing(port, intent.target, roll, need)
	res.dice_events.push_front({
		"kind": "check", "actor": spec.get("name", veh.type_id),
		"roll": roll, "need": need, "ok": on_target,
	})
	if on_target:
		res.log("%s fires its main gun at (%d, %d)! (roll %d, need %d+)" % [
			spec.get("name", veh.type_id), intent.target.x, intent.target.y, roll, need])
	else:
		res.log("%s fires — shot falls short, shell lands at (%d, %d)! (roll %d, need %d+)" % [
			spec.get("name", veh.type_id), landing.x, landing.y, roll, need])
	# Снимок «до взрыва» для показа во время броска (item 22): разрушения и снятая
	# прочность появятся только ПОСЛЕ того, как кубик докрутится.
	var pre_area := cannon_blast_cells(veh, landing)
	pre_area.append(landing)
	_capture_visual_hold(res, pre_area)
	# Дорожка — на НАЗНАЧЕННУЮ клетку, как у противотанкиста (0.12.1): прежде она шла в
	# место падения и до броска выдавала, будет ли недолёт. Куда лёг снаряд, видно по
	# его полёту после броска.
	_fx_lane(res, port, intent.target, veh.owner, "blast")  # issue 8: кто и куда бьёт пушкой
	_fx_shot(res, "shell", port, landing)
	# Прямое попадание в ДОТ: бетон принимает снаряд целиком (2 прочности = 1 выстрел
	# танка), осколочного поля вокруг не возникает.
	_blast_armor_wall(landing, res)
	if _pillbox_absorbs(landing, int(gun.get("vehicle_damage", 2)), res, port):
		return res
	# Осколочное поле снаряда — ромб радиуса 2 (#63), а не квадрат 3×3.
	var area := cannon_blast_cells(veh, landing)
	var killed: Array = _blast(landing, res, area, true, true)
	for n in killed:
		res.log("%s killed in the blast!" % n)
	# Технике — 2 прочности (§техника). Все машины, чей след задет ромбом.
	_damage_vehicles_in_area(area, landing, MCF.COMPONENT_DAMAGE_CANNON, veh.id, res,
		String(spec.get("name", veh.type_id)), _aimed_component)
	if killed.is_empty():
		res.log("… no infantry caught.")
	return res

## Зона поражения снаряда танковой пушки — ромб (#63). Публичная: тем же вызовом
## UI рисует предпросмотр, так что подсветка и реальный взрыв не могут разойтись.
func cannon_blast_cells(veh: Vehicle, center: Vector2i) -> Array[Vector2i]:
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get(
		"weapons", {}).get("main_gun", {})
	return MCF.blast_diamond(center, int(gun.get("blast_radius", MCF.CANNON_BLAST_RADIUS)))

## Клетка корпуса, из которой машина стреляет по target, или (-1,-1) если цель не
## лежит на прямой ни от одной амбразуры (#62). Внутренние клетки корпуса портами
## не считаются: из середины танка ствол смотрел бы в собственную броню.
func cannon_port(veh: Vehicle, target: Vector2i) -> Vector2i:
	var own := {}
	for fc: Vector2i in veh.footprint():
		own[fc] = true
	if own.has(target):
		return Vector2i(-1, -1)  # в собственный корпус не стреляют
	var best := Vector2i(-1, -1)
	var best_dist := 1 << 30
	for fc: Vector2i in veh.footprint():
		# Пушка бьёт только по прямой — горизонталь/вертикаль (#55).
		if fc.x != target.x and fc.y != target.y:
			continue
		var step := Vector2i(signi(target.x - fc.x), signi(target.y - fc.y))
		if step == Vector2i.ZERO or own.has(fc + step):
			continue
		var d := Combat.distance(fc, target)
		if d < best_dist:
			best_dist = d
			best = fc
	return best

## Клетки, по которым машина может отработать пушкой прямо сейчас — для подсветки
## в UI. Учитывает амбразуры (#62), дальность и перекрытие линии огня (#58, #70).
func cannon_target_cells(veh: Vehicle, limit_to: Dictionary = {}) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	# Подсветка обязана совпадать с тем, что примет резолвер: разбитое орудие не
	# стреляет вовсе, а заклиненная башня — только вдоль своего последнего сектора.
	if veh != null and (not veh.can_fire_gun()
			or (veh.tower_jammed() and veh.tower_world_dir() == Vector2i.ZERO)):
		return out
	if veh == null or not veh.alive():
		return out
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get(
		"weapons", {}).get("main_gun", {})
	if gun.is_empty():
		return out
	var rng := int(gun.get("range", MCF.CANNON_RANGE))
	var own := {}
	for fc: Vector2i in veh.footprint():
		own[fc] = true
	var seen := {}
	# Каждая клетка борта пускает луч наружу по четырём направлениям (#62). Луч
	# обрывается на первой непробиваемой клетке, поэтому подсветка совпадает с тем,
	# что резолвер реально разрешит выстрелить.
	for fc: Vector2i in veh.footprint():
		for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			if own.has(fc + d):
				continue  # это внутренняя клетка, а не амбразура
			var c := fc + d
			for _step in rng:
				if not state.grid.in_bounds(c) or Combat.distance(fc, c) > rng:
					break
				if los_blocked(fc, c):
					break  # дальше по этому лучу тоже не пробить
				if not seen.has(c) and (limit_to.is_empty() or limit_to.has(c)):
					seen[c] = true
					out.append(c)
				c += d
	return out

## Урон всем машинам (кроме source_id), чей след задет зоной взрыва area.
## Урон технике от взрыва — ТОЛЬКО ПРЯМЫМ ПОПАДАНИЕМ (item 16: «only a direct explosion
## (tank/anti-tank hit) deals damage to vehicles»).
##
## Раньше хватало того, что след машины задет осколочным полем: заряд, легший В СОСЕДНЮЮ
## клетку, снимал с танка прочность наравне с попаданием в борт. Отсюда и жалоба — броня
## таяла от всего, что рвалось поблизости: чужая мина, подрыв дрона, детонация другой
## машины, недолёт противотанкиста.
##
## Теперь условие одно и жёсткое: ЭПИЦЕНТР взрыва должен лежать НА СЛЕДЕ машины. Снаряд
## танка и заряд противотанкиста, попавшие в корпус, работают как работали; всё, что
## разорвалось рядом, машину больше не трогает. Пехоту вокруг осколки по-прежнему косят —
## это ведает _blast(), и правило её не касается.
##
## center — та самая точка разрыва (место падения заряда, а не центр области).
## aimed — узел, который назвал стрелок; "" = стрелка нет (детонация соседней машины),
## тогда узел выбирает каскад. roll_location=false — узел задан НАПРЯМУЮ, без бросков
## (подрыв дрона: игрок указывает узел, и он гарантированно его и получает).
func _damage_vehicles_in_area(area: Array[Vector2i], center: Vector2i, amount: int,
		source_id: int, res: ActionResult, source: String = "cannon",
		aimed: String = "", roll_location: bool = true) -> void:
	var in_area := {}
	for c: Vector2i in area:
		in_area[c] = true
	for veh: Vehicle in state.all_vehicles():
		if veh.id == source_id or not veh.alive():
			continue
		var direct := false
		for fc in veh.footprint():
			# Эпицентр на корпусе — это и есть прямое попадание. Проверка «клетка в
			# области» остаётся страховкой: точка разрыва обязана быть внутри своего же
			# осколочного поля, и если это вдруг не так — урона нет.
			if fc == center and in_area.has(fc):
				direct = true
				break
		if direct:
			if not roll_location:
				_damage_component(veh, aimed, amount, source, res)
			else:
				var comp := _resolve_hit_location(veh, aimed, res, source, _aim_from)
				if comp != "":
					_damage_component(veh, comp, amount, source, res)

## Разобрать ПОПАДАНИЕ по машине и решить, какой узел пострадал (веха «Modular tank
## system», §3.1).
##
## Стрелок называет узел заранее и бьёт по нему с надбавкой за прицел (+1). Не попал —
## удар не пропадает: он сходит по каскаду от самого труднопопадаемого узла к самому
## лёгкому (пушка → башня → ходовая → корпус), пропуская названный и все разбитые, и
## уже БЕЗ надбавки: премия полагается за объявленный выбор, а не за всю очередь. Если
## не прошёл ни один бросок — бьём в последний оставшийся узел: «попал по танку, но
## ничего не задел» исходом не бывает.
##
## Возвращает id узла или "" — если у машины не осталось ни одного живого узла.
## Узлы, по которым МОЖНО целиться с этой стороны (веха 14.1).
##
## До сих пор стрелок выбирал из всего, что у машины цело, откуда бы он ни бил. Но
## гусеница — вещь бортовая: с левого борта видно левую, с правого правую, а в лоб и в
## корму — обе. И ствол не всегда доступен: он смотрит туда, куда стрелял в прошлый раз,
## и подходящему СЗАДИ него не виден вовсе.
##
## from = NOWHERE — стрелка на поле нет (подрыв дрона сверху, детонация соседней машины):
## тогда борта не существует и доступно всё, что цело.
func _aimable_components(veh: Vehicle, from: Vector2i) -> Array:
	var live := veh.live_components()
	if veh == null or from == NOWHERE or not state.grid.in_bounds(from):
		return live
	var side := veh.side_facing(from)
	var out: Array = []
	for comp: String in live:
		if comp == MCF.COMP_TRACKS_L and side == "right":
			continue
		if comp == MCF.COMP_TRACKS_R and side == "left":
			continue
		if comp == MCF.COMP_GUN and _gun_hidden_from(veh, from):
			continue
		out.append(comp)
	# Совсем без целей не остаёмся: корпус виден с любой стороны, но если сложилось так,
	# что отсеклось всё, бьём по тому, что есть, — «попал и не задел» исходом не бывает.
	return out if not out.is_empty() else live

## Скрыт ли ствол от стрелка: тот стоит ПОЗАДИ сектора, в который смотрит башня.
## Сбоку ствол виден (его видно в профиль), сзади — нет.
func _gun_hidden_from(veh: Vehicle, from: Vector2i) -> bool:
	var g := veh.gun_world_dir()
	if g == Vector2i.ZERO:
		return false
	var rel := from - veh.center()
	var along := rel.x * g.x + rel.y * g.y
	var across := rel.x * -g.y + rel.y * g.x
	return along < 0 and absi(along) > absi(across)

func _resolve_hit_location(veh: Vehicle, aimed: String, res: ActionResult,
		actor_name: String, from: Vector2i = NOWHERE) -> String:
	var live := _aimable_components(veh, from)
	if live.is_empty():
		return ""
	var aimed_at := ""
	# ПРИЦЕЛЬНЫЙ бросок делается, только если узел действительно назвали и он цел.
	# Источники без стрелка (детонация соседней машины) узла не называют — им сразу
	# каскад по базовым порогам, без надбавки за прицел.
	if aimed != "" and live.has(aimed):
		aimed_at = aimed
		var need: int = clampi(
			int(MCF.COMPONENT_NEED.get(aimed_at, 6)) - MCF.COMPONENT_AIM_BONUS, 1, 6)
		var roll := state.dice.roll_d6()
		var hit := roll >= need
		res.dice_events.append({
			"kind": "check",
			"actor": "%s → %s" % [actor_name, MCF.COMPONENT_NAMES.get(aimed_at, aimed_at)],
			"roll": roll, "need": need, "ok": hit,
		})
		if hit:
			return aimed_at
	# Каскад: тот же порядок, что в правилах, без названного узла и без надбавки.
	# Идёт он по тем же ДОСТУПНЫМ узлам: снаряд, пришедший слева, не может задеть
	# правую гусеницу ни прицельно, ни случайно — её закрывает сам корпус.
	for comp: String in MCF.COMPONENT_ORDER:
		if comp == aimed_at or not live.has(comp):
			continue
		var c_need: int = int(MCF.COMPONENT_NEED.get(comp, 6))
		var c_roll := state.dice.roll_d6()
		var c_hit := c_roll >= c_need
		res.dice_events.append({
			"kind": "check",
			"actor": "%s → %s" % [actor_name, MCF.COMPONENT_NAMES.get(comp, comp)],
			"roll": c_roll, "need": c_need, "ok": c_hit,
		})
		if c_hit:
			return comp
	# Пол гарантии: не прошло вообще ничего — задет последний уцелевший узел.
	return live[live.size() - 1]

## Снять с УЗЛА очки прочности. Излишек (пушка танка бьёт на 2, а в узле остался 1)
## уходит В КОРПУС: снаряд, добивший ходовую, продолжает бить в машину, а не пропадает.
##
## Экипаж рискует ТОЛЬКО от попадания в корпус: несмертельное даёт одному человеку
## бросок на выживание, смертельное убивает весь экипаж без броска (это делает
## _destroy_vehicle). Разбитые башня, ходовая и пушка экипажу не угрожают никогда.
func _damage_component(veh: Vehicle, comp: String, amount: int, source: String,
		res: ActionResult) -> void:
	if veh == null or not veh.alive() or amount <= 0:
		return
	var target := comp
	if target == "" or not veh.has_component(target):
		target = MCF.COMP_HULL
	var name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	var label: String = MCF.COMPONENT_NAMES.get(target, target)
	# Узел уже выбит (или его у машины нет вовсе) — весь удар принимает корпус. Так же
	# ведёт себя противотанковая мина по разбитой ходовой: рвётся-то она всё равно, и
	# деваться её заряду некуда. Пропасть впустую урон не может ни при каких условиях.
	if veh.component(target) <= 0 and target != MCF.COMP_HULL:
		_damage_component(veh, MCF.COMP_HULL, amount, source, res)
		return
	var left: int = veh.component(target)
	# Local presentation snapshot, like visual_hold's hull/cell values; no state or wire data.
	if res != null:
		var held: Dictionary = res.visual_hold.get("vehicles", {})
		if not held.has(veh.id):
			held[veh.id] = {"durability": veh.durability, "wrecked": veh.wrecked}
		if not held[veh.id].has("components"):
			held[veh.id]["components"] = veh.components.duplicate()
		res.visual_hold["vehicles"] = held
	var dealt: int = mini(amount, left)
	var overflow: int = amount - dealt
	if dealt > 0:
		veh.components[target] = left - dealt
		res.log("%s: %s takes %d damage (%d left)." % [
			name, label, dealt, veh.component(target)])
		if veh.component(target) == 0:
			res.log("%s: %s is knocked out!" % [name, label])
	# Корпус на нуле — машине конец, и добивать дальше нечего.
	if target == MCF.COMP_HULL and veh.component(MCF.COMP_HULL) <= 0:
		_destroy_vehicle(veh, res)
		return
	if target == MCF.COMP_HULL and not _seated(veh) and not veh.is_borg():
		# Несмертельное попадание в корпус: один человек проверяет броню (§6).
		# У челнока пассажиры разобраны самим взрывом (batch 13 S5); у борга оператор
		# страдает только вместе с машиной (B6).
		_tank_crew_hit(veh, res)
	elif overflow > 0 and dealt > 0:
		# Излишек добивает корпус — со всеми последствиями попадания в корпус.
		_damage_component(veh, MCF.COMP_HULL, overflow, source, res)

## Нанести машине урон ПО КАСКАДУ, когда узел не выбирают: детонация соседней машины,
## взрыв под гусеницей и прочие источники без стрелка. Прицела нет — значит нет и
## надбавки: каскад начинается с самого труднопопадаемого узла.
func _damage_vehicle_cascade(veh: Vehicle, amount: int, source: String,
		res: ActionResult, actor_name: String) -> void:
	if veh == null or not veh.alive():
		return
	var comp := _resolve_hit_location(veh, "", res, actor_name)
	if comp == "":
		return
	_damage_component(veh, comp, amount, source, res)

## Урон машине от источника, который узел НЕ выбирает. Разбирается каскадом
## (_damage_vehicle_cascade) — прежняя «одна общая прочность» больше не существует.
##
## Оставлено отдельным именем, потому что зовущих много и все они говорят об одном:
## «машине прилетело столько-то, куда именно — решай сам».
func _apply_vehicle_damage(veh: Vehicle, amount: int, source: String, res: ActionResult) -> void:
	_damage_vehicle_cascade(veh, amount, source, res, source)

## Попадание по экипажу танка (§техника «как от одной пули»): случайный живой
## член экипажа бросает d6 против своей брони; провал — гибнет.
func _tank_crew_hit(veh: Vehicle, res: ActionResult) -> void:
	if veh.occupants.is_empty():
		return
	# Выбор случайного члена экипажа через d6 (идёт через DiceService — сеть синхронна).
	var idx := (state.dice.roll_d6() - 1) % veh.occupants.size()
	var uid: int = veh.occupants[idx]
	var crew := state.get_unit(uid)
	if crew == null:
		veh.occupants.remove_at(idx)
		return
	# Экипаж в броне держится увереннее пехоты: +1 к защите (item 16) — порог выживания
	# на единицу ниже собственной брони, но не мягче 1+.
	var need: int = maxi(1, crew.armor() - MCF.TANK_CREW_DEFENSE_BONUS)
	var roll := state.dice.roll_d6()
	var survived := crew.cheat_invulnerable or roll >= need
	res.dice_events.append({
		"kind": "check", "actor": "%s (crew)" % crew.stats.display_name,
		"roll": roll, "need": need, "ok": survived,
	})
	if not survived:
		_kill(crew)
		veh.occupants.remove_at(idx)
		veh.corpse_slots.append(crew.stats.display_name)
		res.log("%s (crew) is killed (roll %d, need %d+ with +1 armor)." % [
			crew.stats.display_name, roll, need])
	else:
		res.log("%s (crew) shrugs off the hit (roll %d, need %d+)." % [
			crew.stats.display_name, roll, need])
	veh.ap = mini(veh.ap, _vehicle_crew_ap(veh))

## Уничтожение машины: экипаж гибнет, бросок d6 на взрыв; танк остаётся обломком.
func _destroy_vehicle(veh: Vehicle, res: ActionResult) -> void:
	var protected: Array[UnitInstance] = []
	for uid: int in veh.occupants:
		var unit := state.get_unit(uid)
		if unit != null and unit.is_on_field() and unit.cheat_invulnerable: protected.append(unit)
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var name: String = spec.get("name", veh.type_id)
	var dtable: Dictionary = VehicleDB.DESTRUCTION.get(veh.type_id, {})
	# Экипаж внутри гибнет. Пассажиры челнока остаются трупами на своих клетках,
	# машина из-под них исчезает (batch 13 S12).
	#
	# ВАЖНО: _kill() сам в res.deaths НИЧЕГО не кладёт — это делает каждый вызывающий,
	# и здесь этого не делал никто. То есть подбитый танк засчитывался только корпусом,
	# а трое внутри не попадали ни в награду за убийство, ни в счётчик комбо: сжечь
    # гружёную машину стоило ровно столько же, сколько пустую. Та же поломка, что была
	# у _blast/лазера/огнемёта, и на танковой карте она особенно дорога — там ВЕСЬ отряд
	# сидит внутри корпусов, и без этой строки карта не учила бы ничему.
	for uid in veh.occupants.duplicate():
		var crew := state.get_unit(uid)
		if crew != null:
			_kill(crew, res)
			res.deaths.append(crew.id)
			# Тело оператора борга больше ни в какой машине не сидит: взорвавшийся борг
			# из state.vehicles исчезает, и borg_id указывал бы в пустоту.
			if veh.is_borg():
				crew.borg_id = -1
	veh.occupants.clear()
	if _seated(veh):
		for i in veh.seats.size():
			var sid: int = veh.seats[i]
			if sid == Vehicle.SEAT_STATION or sid == Vehicle.SEAT_DPMG:
				var sc := state.grid.cell(veh.seat_cell(i))
				if sc != null and (sc.feature_id == MCF.FEATURE_DRONE_STATION or sc.feature_id == MCF.FEATURE_DPMG):
					sc.clear_feature()
			elif sid >= 0:
				var body := state.get_unit(sid)
				if body != null:
					body.aboard_vehicle_id = -1
			veh.seats[i] = -1
	veh.durability = 0
	var roll := state.dice.roll_d6()
	var explode := false
	# Порог взрыва по таблице разрушения: у челнока это «1-2», у танка «4+» (#68).
	var need: int = int(dtable.get("explode_min", 99))
	if dtable.has("explode_max"):
		explode = roll >= int(dtable.get("explode_min", 1)) and roll <= int(dtable["explode_max"])
	else:
		explode = roll >= need
	# Бросок на детонацию должен быть ВИДЕН игроку, как любой другой (#68): без
	# этого события кубик не выкатывался и разрушение выглядело беспричинным.
	res.dice_events.append({
		"kind": "check", "actor": "%s destruction" % name,
		"roll": roll, "need": need, "ok": explode,
	})
	res.log("%s is destroyed! (destruction roll %d)" % [name, roll])
	# Оператор борга гибнет вместе с машиной (batch 13 B6) — его тело остаётся на клетке.
	if veh.is_borg():
		var bop := state.get_unit(veh.borg_operator())
		if bop != null and bop.is_alive():
			_kill(bop, res)
			bop.borg_id = -1
		veh.occupants.clear()
	if explode:
		var r := int(dtable.get("explode_radius", 1))
		res.log("It explodes (radius %d)!" % r)
		var center := veh.center()
		# Детонация боекомплекта — такой же взрыв-ромб, как у пушки (#63): по
		# диагонали ударная волна уходит недалеко. Борг рвётся как противотанковый
		# заряд (B6) — квадрат 3×3. У детонации борта нет — рвётся сама машина.
		_aim_from = NOWHERE
		var square := bool(dtable.get("square", false))
		var area := MCF.blast_square(center, r) if square else MCF.blast_diamond(center, r)
		# Взрыв — тот же _blast, что у заряда (batch 17, item 7): гибнут все в зоне,
		# укрепления сносятся, и под машиной остаётся выжженный пол.
		if veh.is_borg():
			state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
		for n in _blast(center, res, area):
			res.log("%s destroyed!" % n)
		_damage_vehicles_in_area(area, center, 1 if square else 2, veh.id, res,
				"%s detonation" % name)
	# Любая машина оставляет остов (batch 17, item 7): укрытие и блок линии огня —
	# взорвалась она или нет. Раньше челнок исчезал всегда, борг — после взрыва.
	veh.wrecked = true
	for unit: UnitInstance in protected:
		unit.borg_id = -1
		unit.aboard_vehicle_id = -1
		if not state.grid.in_bounds(unit.coord):
			var placed := false
			for at: Vector2i in CheatUnits.ring_cells(veh.origin, state.grid):
				if CheatUnits.cell_error(state, at).is_empty():
					state.grid.place(unit, at)
					placed = true
					break
			if not placed:
				# Retain a real crew link, never an inaccessible floating entity.
				veh.occupants.append(unit.id)
				unit.aboard_vehicle_id = veh.id
		res.log("%s survives the destruction through invulnerability." % unit.stats.display_name)
	if veh.is_borg():
		state.grid.set_vehicle_footprint(veh.id, veh.footprint())

# --- Запросы для UI ---

## Машина под клеткой, которой управляет владелец owner (для выбора кликом).
func controllable_vehicle_at(coord: Vector2i, owner: int) -> Vehicle:
	var veh := state.vehicle_on(coord)
	if veh != null and veh.alive() and veh.owner == owner:
		return veh
	return null

## Машины (свои и вражеские) рядом с юнитом, в которые он может сесть.
func boardable_vehicles(unit: UnitInstance) -> Array:
	var out: Array = []
	if unit == null or not unit.is_alive() or unit.aboard_vehicle_id != -1 or unit.is_drone \
			or unit.borg_id != -1 or unit.carried_corpses > 0:
		return out   # то же, что отклонит _resolve_vehicle_board: меню не предлагает отказ
	var seen := {}
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or _vehicle_full(veh) or (_is_shield(unit) and not veh.is_borg()):
			continue
		if seen.has(veh.id) or (veh.is_borg() and _borg_entry_error(unit, veh) != ""):
			continue
		if _adjacent_to_vehicle(unit.coord, veh):
			seen[veh.id] = true
			out.append(veh)
	return out

## Мест больше нет: у челнока — ни одного свободного кресла, у прочих — все слоты заняты.
func _vehicle_full(veh: Vehicle) -> bool:
	if _seated(veh):
		return veh.free_seats().is_empty()
	if veh.is_borg():
		var op := state.get_unit(veh.borg_operator())
		return op != null and op.is_alive()
	return veh.slots_used() >= veh.capacity()

## Соседняя своя пехота, которая может сесть в машину.
func vehicle_board_candidates(veh: Vehicle) -> Array:
	var out: Array = []
	if veh == null or not veh.alive() or _vehicle_full(veh):
		return out
	for u in state.all_units():
		if u.is_alive() and u.owner == veh.owner and u.aboard_vehicle_id == -1 \
				and not u.is_drone and _adjacent_to_vehicle(u.coord, veh):
			out.append(u.id)
	return out

## Куда может доехать машина: центр итоговой позиции → { dir, steps }.
func vehicle_move_targets(veh: Vehicle, speed_bonus: int = 0) -> Dictionary:
	var out: Dictionary = {}
	var credit := vehicle_move_credit(veh)
	if veh == null or not veh.alive() or (vehicle_ap(veh) <= 0 and credit <= 0):
		return out
	if not veh.can_drive():
		return out  # разбитая ходовая — ехать некуда (веха «Modular tank system»)
	# Тот же бюджет, что спишет резолвер (#97): остаток прошлого движения — вместо ОД.
	var speed := credit if credit > 0 \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	if _seated(veh):
		speed = _shuttle_budget(veh)  # водитель платит по 15 клеток за ОД (batch 13)
	speed += speed_bonus  # предпросмотр «куда доеду за следующие ОД» (batch ui-drones)
	var dirs: Array = []
	if veh.facing != Vector2i.ZERO:
		dirs = [veh.facing, -veh.facing]
	else:
		dirs = DIR8
	for dir: Vector2i in dirs:
		var last := 0
		for steps in range(1, speed + 1):
			var plan := VehicleRules.plan_line_move(state, veh, dir, steps, speed)
			if not plan["ok"]:
				break
			var reached := int(plan["steps"])
			if reached <= last:
				break
			last = reached
			var center := Vehicle.center_of(veh.origin + dir * reached, veh.size)
			out[center] = {"dir": dir, "steps": reached, "cost": int(plan["cost"])}
			if reached < steps:
				break
	return out

## Потолки хода машины за 1/2/3 ОД — как move_tier_budgets у пехоты: [0] — остаток
## прошлого движения (тогда он и есть первая зона, без ОД) или ход за 1 ОД, дальше по
## ходу за каждое следующее ОД. Челнок платит по SHUTTLE_CELLS_PER_AP клеток за ОД.
func vehicle_tier_budgets(veh: Vehicle) -> Array[int]:
	var out: Array[int] = []
	if veh == null or not veh.alive():
		return out
	var credit := vehicle_move_credit(veh)
	var step := MCF.SHUTTLE_CELLS_PER_AP if _seated(veh) \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	var extra := vehicle_ap(veh) - (0 if credit > 0 else 1)
	if extra < 0 or step <= 0:
		return out if credit <= 0 else [credit]
	out.append(credit if credit > 0 else step)
	for k in range(1, mini(extra, 2) + 1):
		out.append(out[0] + step * k)
	return out

## Все клетки, куда машина доедет за 1-3 ОД (центр -> {dir, steps, cost}); зона клетки —
## tier_of(vehicle_tier_budgets, cost). Это и подсветка, и то, что примет клик.
func vehicle_move_targets_all(veh: Vehicle) -> Dictionary:
	var tb := vehicle_tier_budgets(veh)
	if tb.is_empty():
		return {}
	# Челнок и так считает весь запас водителя (_shuttle_budget).
	if _seated(veh):
		return vehicle_move_targets(veh)
	return vehicle_move_targets(veh, tb[tb.size() - 1] - tb[0])

## Куда машина доедет за 1, 2 и 3 ОД (batch ui-drones): массив словарей центр -> true,
## каждый следующий — только клетки, которых нет в предыдущих.
func vehicle_move_tiers(veh: Vehicle) -> Array:
	var tiers: Array = [{}, {}, {}]
	var tb := vehicle_tier_budgets(veh)
	var all := vehicle_move_targets_all(veh)
	for c: Vector2i in all:
		tiers[tier_of(tb, int(all[c]["cost"]))][c] = true
	return tiers

## Раздавит ли этот ход СВОИХ (item 7).
##
## Гусеница давит всё, что под ней. Врага — и пусть: таран пехоты противника машине
## и положен. А вот своих ИИ переезжал совершенно буднично: подбор хода мерил только
## сближение с врагом, и о том, что по дороге лежит собственный отряд, план не знал
## вовсе. Танк выкашивал полвзвода и записывал это себе в прогресс.
##
## Спрашиваем ТОТ ЖЕ планировщик, что исполнит переезд (VehicleRules.plan_line_move):
## своя, отдельная прикидка «кто попадёт под гусеницу» неизбежно разошлась бы с
## настоящей — и разошлась бы молча.
func vehicle_move_crushes_ally(veh: Vehicle, dir: Vector2i, steps: int) -> bool:
	if veh == null or not veh.alive():
		return false
	var credit := vehicle_move_credit(veh)
	var speed := credit if credit > 0 \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	if _seated(veh):
		speed = _shuttle_budget(veh)
	var plan := VehicleRules.plan_line_move(state, veh, dir, steps, speed)
	if not plan["ok"]:
		return false
	for cc: Vector2i in plan["crush_cells"]:
		var cell := state.grid.cell(cc)
		if cell == null:
			continue
		var occ: UnitInstance = cell.occupant
		if occ == null or not occ.is_alive():
			continue
		# Мирные жители своими не считаются — они никому не союзники; но и давить их
		# незачем, поэтому ИИ обходит и их (см. вызывающего).
		if occ.owner == veh.owner or state.roster.are_allies(veh.owner, occ.owner):
			return true
	return false

## Свои и союзники, которых раздавит ЭТОТ переезд (playtest-20: игрок подтверждает наезд).
## Тот же планировщик и тот же бюджет клеток, что у _resolve_vehicle_move, — иначе
## переезд в оранжевую/красную зону танка не спросил бы ни о ком. Пассажиры челнока едут
## в своих креслах и в список не попадают.
func vehicle_move_crushed_friends(veh: Vehicle, dir: Vector2i, steps: int) -> Array:
	var out: Array = []
	if veh == null or not veh.alive() or state.roster == null:
		return out
	var speed := vehicle_move_credit(veh)
	if speed <= 0:
		speed = int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	var tiers := vehicle_tier_budgets(veh)
	if _seated(veh):
		speed = _shuttle_budget(veh)
	elif not tiers.is_empty():
		speed = tiers[tiers.size() - 1]
	var plan := VehicleRules.plan_line_move(state, veh, dir, steps, speed)
	if not plan["ok"]:
		return out
	for cc: Vector2i in plan["crush_cells"]:
		var occ: UnitInstance = state.grid.cell(cc).occupant
		if occ != null and occ.is_alive() and occ.aboard_vehicle_id != veh.id \
				and state.roster.are_allies(veh.owner, occ.owner):
			out.append(occ)
	return out

## Свободные соседние со следом клетки для высадки экипажа.
func vehicle_disembark_cells(veh: Vehicle, unit_id: int = -1) -> Array:
	var out: Array = []
	if veh == null:
		return out
	var seen := {}
	var cells: Array[Vector2i] = veh.footprint()
	# Пассажир челнока выходит через СВОЙ борт (batch 13 S7): только клетки вокруг
	# клетки его кресла.
	if _seated(veh) and unit_id != -1:
		var sc := seat_cell_of(state.get_unit(unit_id))
		if sc == NOWHERE:
			return out
		cells = [sc]
	for fc in cells:
		for n in state.grid.neighbors(fc):
			if seen.has(n):
				continue
			seen[n] = true
			if state.grid.vehicle_at(n) == veh.id:
				continue
			if not state.grid.is_occupied_or_wall(n):
				out.append(n)
	return out

# Mounted lamps are separately targetable. Shooting one does not damage its wall.
## The light on c: with side >= 0 the wall lamp hanging on that side; with side < 0 a
## standing lamp. "" — none.
func fixture_at(c: Vector2i, side: int = -1) -> String:
	if not state.grid.in_bounds(c): return ""
	var cell := state.grid.cell(c)
	if side >= 0:
		var rec := MapData.lamp_on(cell.lamps, side)
		return str(rec[0]) if not rec.is_empty() else ""
	# Only actual lamps are shot out as lights; a glowing rack or vending machine is
	# ordinary furniture (it only glows on screen).
	return cell.feature_id if Furniture.DEFS.get(cell.feature_id, {}).get("cat", "") == "lighting" else ""

## The side of the wall lamp on c that faces the shooter most squarely, -1 if none does.
func facing_lamp_side(shooter: UnitInstance, c: Vector2i) -> int:
	if shooter == null or not state.grid.in_bounds(c): return -1
	var best := -1
	var best_dot := 0
	for rec: Array in state.grid.cell(c).lamps:
		var n: Vector2i = Furniture.N4[int(rec[2])]
		var d := (shooter.coord.x - c.x) * n.x + (shooter.coord.y - c.y) * n.y
		if d > best_dot:
			best_dot = d
			best = int(rec[2])
	return best

## Sides of the wall lamps on c this unit could shoot at.
func shootable_lamp_sides(shooter: UnitInstance, c: Vector2i) -> Array[int]:
	var out: Array[int] = []
	if not state.grid.in_bounds(c): return out
	for rec: Array in state.grid.cell(c).lamps:
		if can_shoot_fixture(shooter, c, int(rec[2])) == "": out.append(int(rec[2]))
	return out

func can_shoot_fixture(shooter: UnitInstance, c: Vector2i, side: int = -1) -> String:
	if shooter == null or not shooter.is_alive() or shooter.is_drone or shooter.captor_id >= 0:
		return "Unit cannot fire"
	if shooter.attack_ability() in [MCF.ABILITY_ANTI_TANK, MCF.ABILITY_FLAMETHROWER,
			MCF.ABILITY_MARKSMAN, MCF.ABILITY_MINER, MCF.ABILITY_SHIELD_BEARER]:
		return "Use this unit's normal attack"
	if side < 0 and not state.grid.cell(c).lamps.is_empty() and fixture_at(c) == "":
		return "The lamp is on the other side of the wall"
	if fixture_at(c, side) == "": return "No light fixture there"
	if side >= 0 and not faces_lamp(c, side, shooter.coord): return "The lamp is on the other side of the wall"
	if not Combat.is_on_firing_line(shooter.coord, c): return "Target not on the firing line"
	if fog_enabled and not team_visible_coords(shooter.owner).has(c): return "Target not visible"
	if los_blocked(shooter.coord, c, true, true, true): return "Firing line is blocked"
	if pane_hit_need(shooter, c) > 6: return "Too far"
	if shooter.remaining_ap <= 0 and not (shooter.action_state != null and shooter.action_state.is_pending()):
		return "Unit has no AP left"
	return ""

func shootable_fixture_cells(shooter: UnitInstance) -> Array:
	var out: Array = []
	var reach := int(shooter.fire_range())
	for direction: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT,
			Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		for distance in range(1, reach + 1):
			var c := shooter.coord + direction * distance
			if not state.grid.in_bounds(c): break
			if (fixture_at(c) != "" and can_shoot_fixture(shooter, c) == "") \
					or not shootable_lamp_sides(shooter, c).is_empty(): out.append(c)
	return out

func _resolve_shoot_fixture(shooter: UnitInstance, c: Vector2i, side: int, shots: int) -> ActionResult:
	if shooter.action_state == null or not shooter.action_state.is_pending():
		shooter.remaining_ap -= 1
		shooter.action_state = ActionState.new()
		shooter.action_state.remaining_shots = maxi(1, shooter.rate_of_fire())
	shooter.action_state.target_id = ActionState.WINDOW
	var want := shooter.action_state.remaining_shots if shots < 0 else clampi(shots, 1, shooter.action_state.remaining_shots)
	var result := ActionResult.success()
	var cell := state.grid.cell(c)
	var id := fixture_at(c, side)
	var label: String = Furniture.DEFS[id].name
	var bullets := _through_glass(shooter, _glass_cells_on_line(shooter.coord, c), want, result)
	var need := pane_hit_need(shooter, c)
	var hits: Array = []
	var damage := 0
	for i in bullets:
		var roll := state.dice.roll_d6()
		hits.append({"roll": roll, "hit": roll >= need})
		if roll >= need: damage += 1
	result.dice_events.append({"kind": "fixture", "name": label, "cell": c, "need": need,
		"hits": hits, "saves": [], "shooter_owner": shooter.owner})
	if damage > 0:
		if side >= 0:
			var rec := MapData.lamp_on(cell.lamps, side).duplicate()
			rec[1] = int(rec[1]) - damage
			cell.lamps = MapData.with_lamp(cell.lamps, rec) if int(rec[1]) > 0 else MapData.without_lamp(cell.lamps, side)
			if int(rec[1]) <= 0: _lamp_shards(result, c, shooter.coord, side)
		else:
			cell.feature_durability -= damage
			if cell.feature_durability <= 0: _destroy_furniture(cell, result, shooter.coord)
	result.log("%s fires %d at %s (%d, %d): %d hits%s" % [shooter.stats.display_name, want,
		label, c.x, c.y, damage, " — light destroyed" if fixture_at(c, side) == "" else ""])
	shooter.action_state.remaining_shots -= want
	if shooter.action_state.remaining_shots <= 0: shooter.action_state = null
	_fx_lane(result, shooter.coord, c, shooter.owner, "shot", _weapon_of(shooter))
	_fx(result, {"fx": "casings", "at": shooter.coord, "toward": c, "count": want})
	_fx(result, {"fx": "tracer", "at": shooter.coord, "from": [shooter.coord.x, shooter.coord.y],
		"to": [c.x, c.y], "count": want})
	notify_cell_changed(c)
	return result
