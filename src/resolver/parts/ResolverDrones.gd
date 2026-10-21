@abstract
extends "res://src/resolver/parts/ResolverWorld.gd"

## Drones and drone stations.

# --- Дроны (§3.12) ---
func _resolve_spawn_drone(intent: SpawnDroneIntent) -> ActionResult:
	var operator := state.get_unit(intent.actor_id)
	var err := _validate_actor(operator)
	if err != "":
		return ActionResult.fail(err)
	if operator.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return ActionResult.fail("Only an operator can launch a drone")
	var options := stations_near(operator)
	if options.is_empty():
		return ActionResult.fail("No drone station nearby")
	# Игрок называет станцию (item 17); без указания берём первую, как раньше.
	var station: Vector2i = options[0]
	if intent.station != SpawnDroneIntent.NOWHERE:
		if not options.has(intent.station):
			return ActionResult.fail("That station is not within reach")
		station = intent.station
	# Дронов у оператора может быть несколько (batch group-zones): новый поднимается и
	# тогда, когда прежний ещё в воздухе.
	# Дрон всегда поднимается прямо над своей станцией (#22); если там уже висит
	# чужой дрон — уходит на ближайшую свободную клетку.
	var drone := _launch_drone_at(station, operator, intent.scout)
	if drone == null:
		return ActionResult.fail("Nowhere to place the drone")
	operator.remaining_ap -= 1
	var result := ActionResult.success(["%s launches a %s at (%d, %d)" % [
		operator.stats.display_name, "scout drone" if intent.scout else "kamikaze drone",
		drone.coord.x, drone.coord.y]])
	result.spawned_unit_id = drone.id
	return result

func _resolve_drone_move(intent: DroneMoveIntent) -> ActionResult:
	var drone := state.get_unit(intent.actor_id)
	if drone == null or not drone.is_drone or not drone.is_alive():
		return ActionResult.fail("Drone unavailable")
	if drone.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if not operator_controls(drone):
		return ActionResult.fail("Operator not at the station")
	# Спуск со стены обратно — часть ТОГО ЖЕ подлёта, а не новое действие (#99). Дрон
	# висит над стеной, он на неё не садился; раньше подъём и спуск съедали оба ОД, и
	# заглянуть за стену стоило дрону всего хода — он возвращался ровно туда, откуда
	# взлетел, без единой клетки полёта в запасе.
	var descending := state.grid.cell(drone.coord).is_wall() \
			and intent.target == drone.wall_entry_from
	# Недолётанный остаток прошлого подлёта тратится ПЕРВЫМ и нового ОД не стоит (#13).
	var use_credit := drone.move_credit > 0
	var budget: int = drone.move_credit if use_credit else MCF.drone_range(drone)
	if drone.remaining_ap <= 0 and not descending and not use_credit:
		return ActionResult.fail("Drone has no AP left")

	var reach := _drone_reach(drone)
	# Свободная клетка в пределах полёта.
	if reach.has(intent.target):
		if not descending and not use_credit:
			drone.remaining_ap -= 1
		# Остаток дальности сохраняется до конца хода — им дрон долетит потом (#13).
		drone.move_credit = maxi(0, budget - int(reach[intent.target]))
		if state.grid.cell(intent.target).on_fire:
			# Залетел в огонь — взрыв (§3.8/§3.12); разведчик просто сгорает.
			drone.coord = intent.target
			return _drone_destroyed(drone, intent.target, "flew into fire")
		# Заход на стену запоминаем ДО переезда (#96): уйти с неё можно только назад.
		var entry := Vector2i(-1, -1)
		# Над стеной у дрона один ход — назад (#96), но остаток подлёта он НЕ теряет
		# (batch borg-corpses): раньше и заход на стену, и спуск обнуляли его, и дрон,
		# заглянув за стену, оставался без полёта до конца хода. Спуск тратит из остатка
		# одну клетку; спуск без остатка бесплатен, но и нового запаса не даёт.
		if descending and not use_credit:
			drone.move_credit = 0
		if state.grid.cell(intent.target).is_wall():
			entry = _drone_entry_cell(drone, intent.target, reach)
		# Маршрут снимаем ДО переезда (item 12): восстанавливается он от СТАРОЙ клетки.
		var route := _drone_route(drone.coord, intent.target)
		var flew_from := drone.coord
		# Дрон не занимает слот клетки — просто переносим его координату (#13).
		drone.coord = intent.target
		drone.wall_entry_from = entry
		# Строку лога ставим ветвлением, а не тернарником в аргументе: success() принимает
		# ТИПИЗИРОВАННЫЙ Array[String], а тернарник отдаёт нетипизированный литерал, и
		# на таком вызове движок уходит в себя намертво. Развилка и читается лучше.
		var flight := ActionResult.new()
		flight.ok = true
		if entry != Vector2i(-1, -1):
			flight.log("Drone hovers over the wall at (%d, %d) [AP: %d]" % [
				intent.target.x, intent.target.y, drone.remaining_ap])
		else:
			flight.log("Drone flies to (%d, %d) [AP: %d]" % [
				intent.target.x, intent.target.y, drone.remaining_ap])
		# Полёт отыгрывается по клеткам тем же событием, что и пеший переход (item 12):
		# тридцать клеток за один подлёт иначе выглядели телепортом, и в чужой ход было
		# не понять, откуда дрон взялся над твоим отрядом.
		if not route.is_empty():
			flight.dice_events.append({
				"kind": "walk", "unit": drone.id, "from": flew_from, "path": route,
			})
		return flight
	# Столкновение: цель занята/стена — дрон таранит и взрывается (§3.12).
	var pre := _approach_cell(drone, intent.target, reach)
	if pre != Vector2i(-1, -1) and MCF.is_scout(drone):
		return ActionResult.fail("A scout drone can't ram")
	if pre != Vector2i(-1, -1):
		if drone.remaining_ap <= 0 and not use_credit:
			return ActionResult.fail("Drone has no AP left")
		if not use_credit:
			drone.remaining_ap -= 1
		drone.move_credit = 0  # таран — конец подлёта в любом случае
		var ram_from := drone.coord
		var ram_route := _drone_route(drone.coord, pre)
		if pre != drone.coord:
			drone.coord = pre
		var boom := _drone_explode(drone, intent.target, "crashed into an obstacle")
		# Разгон перед тараном виден так же, как обычный полёт (item 12): взрыв на
		# ровном месте читается куда хуже, чем взрыв в конце разбега.
		if not ram_route.is_empty():
			boom.dice_events.push_front({
				"kind": "walk", "unit": drone.id, "from": ram_from, "path": ram_route,
			})
		return boom
	return ActionResult.fail("Target out of the drone's reach")

func _resolve_drone_detonate(intent: DroneDetonateIntent) -> ActionResult:
	var drone := state.get_unit(intent.actor_id)
	if drone == null or not drone.is_drone or not drone.is_alive():
		return ActionResult.fail("Drone unavailable")
	if drone.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if not operator_controls(drone):
		return ActionResult.fail("Operator not at the station")
	if MCF.is_scout(drone):
		return ActionResult.fail("A scout drone carries no charge")
	_aimed_component = intent.component
	# Дрон рвётся НАД корпусом (§4): борта у такого удара нет, и выбор игрока ничем
	# не ограничен — ни гусеницей с той стороны, ни направлением ствола.
	_aim_from = NOWHERE
	return _drone_explode(drone, drone.coord, "detonated")

## Гибель дрона: камикадзе рвётся (_drone_explode), разведчик просто падает — ни взрыва,
## ни урона (fix-7 #7).
func _drone_destroyed(drone: UnitInstance, center: Vector2i, why: String,
		radius: int = MCF.ANTI_TANK_BLAST_RADIUS) -> ActionResult:
	if not MCF.is_scout(drone):
		return _drone_explode(drone, center, why, radius)
	drone.status = MCF.Status.CORPSE
	drone.remaining_ap = 0
	var result := ActionResult.new()
	result.ok = true
	result.log("Scout drone %s at (%d, %d) — it falls apart" % [why, center.x, center.y])
	return result

## Взрыв дрона: снимаем его с поля (не оставляет труп) и детонируем как противотанкист.
## Дрон не занимает слот клетки (#13), так что снимать occupant не нужно.
func _drone_explode(drone: UnitInstance, center: Vector2i, why: String,
		radius: int = MCF.ANTI_TANK_BLAST_RADIUS) -> ActionResult:
	drone.status = MCF.Status.CORPSE
	drone.remaining_ap = 0
	var result := ActionResult.new()
	result.ok = true
	result.log("Drone %s — explosion at (%d, %d)" % [why, center.x, center.y])
	# Дрон, влетевший прямо в ДОТ, весь свой заряд оставляет в бетоне.
	_blast_armor_wall(center, result)
	if _pillbox_absorbs(center, MCF.DRONE_EXPLOSION_DAMAGE, result):
		return result
	var area := MCF.blast_square(center, radius)
	var killed := _blast(center, result, area, true, true)
	# Дрон, подорвавшийся над техникой, снимает с неё 1 прочность (item 14): раньше
	# взрыв дрона выкашивал пехоту вокруг машины, а сам корпус не трогал вовсе.
	# Подрыв дрона узел НЕ разыгрывает (§4): игрок указал — туда и пришлось.
	_damage_vehicles_in_area(area, center, MCF.DRONE_EXPLOSION_DAMAGE, -1, result, "drone",
		_aimed_component, false)
	if killed.is_empty():
		result.log("… nobody destroyed")
	else:
		for n in killed:
			result.log("%s destroyed!" % n)
	return result

## Поднять дрон над станцией. Общая часть для ручного запуска и авто-запуска при
## развёртывании станции (#77). Возвращает дрон или null, если поднимать некуда/незачем.
## `pilot` — кто разворачивал станцию; управлять дроном всё равно сможет только
## оператор, стоящий вплотную к станции (см. operator_controls).
func _launch_drone_at(station: Vector2i, pilot: UnitInstance, scout := false) -> UnitInstance:
	var op := pilot
	# Пультом владеет оператор: если станцию ставил не он, ищем своего оператора рядом.
	if op == null or op.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		for u in state.all_units():
			if u.is_alive() and not u.is_drone and u.owner == pilot.owner \
					and u.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR \
					and Combat.distance(u.coord, station) == 1:
				op = u
				break
	if op == null:
		return null
	var spawn_cell := station
	if _drone_at(station) != null:
		spawn_cell = _free_flight_cell_near(station)
	if spawn_cell == Vector2i(-1, -1):
		return null
	var drone_stats: UnitStats = load("res://src/data/units/%s.tres" % (
			MCF.SCOUT_DRONE_STATS_ID if scout else MCF.DRONE_STATS_ID))
	# Дрон висит НАД клеткой и её не занимает (#103) — под ним свободно проходят.
	var drone := state.spawn_unit(drone_stats, spawn_cell, op.owner, false)
	drone.is_drone = true
	drone.home_station = station
	drone.operator_id = op.id
	return drone

## Клетка со станцией дронов, стоящей рядом с оператором (или (-1,-1)).
func station_near(operator: UnitInstance) -> Vector2i:
	var all := stations_near(operator)
	return all[0] if not all.is_empty() else Vector2i(-1, -1)

## ВСЕ свои станции вплотную к оператору (item 17). Их может быть несколько, и с
## какой поднимать дрон — решает игрок, а не порядок обхода соседей.
##
## НЕ оператор — пустой список. Проверка стоит ЗДЕСЬ, а не у звавших: её делали все четыре
## вызова (обе кнопки в Main, _resolve_spawn_drone и пеший перечислитель) и ровно один —
## пассажир челнока в LegalIntents — забыл. Политика RL честно выбирала «поднять дрон»
## тяжёлым пехотинцем из кресла, резолвер отвечал «Only an operator can launch a drone», и
## так до конца хода: жадная оценка переспрашивает один и тот же отказ, пока среда не
## оборвёт ход на восьмом (отсюда отказы кратные восьми в eval_games.jsonl у tactical-2).
func _destroy_drone_station(coord: Vector2i) -> void:
	var cell := state.grid.cell(coord)
	if cell == null or cell.feature_id != MCF.FEATURE_DRONE_STATION: return
	var veh := state.get_vehicle(cell.vehicle_id)
	if veh != null and _seated(veh):
		for i in veh.seats.size():
			if veh.seats[i] == Vehicle.SEAT_STATION and veh.seat_cell(i) == coord:
				veh.seats[i] = -1
	cell.clear_feature()

func stations_near(operator: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if operator == null or operator.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return out
	for n in state.grid.neighbors(operator.coord):
		var cell := state.grid.cell(n)
		if cell.feature_id == MCF.FEATURE_DRONE_STATION and cell.feature_owner == operator.owner:
			out.append(n)
	return out

## Где стоит станция, развёрнутая ИМЕННО ЭТИМ оператором (item 16); (-1,-1) — нет такой.
## Оператор помечает свою станцию при установке, поэтому «одна станция на оператора»
## считается по метке, а не по владельцу-стороне: у команды их может быть много.
func deployed_station_of(operator: UnitInstance) -> Vector2i:
	if operator == null:
		return Vector2i(-1, -1)
	return _station_index().get(operator.id, Vector2i(-1, -1))

## «Оператор -> его станция» — по станциям из индекса объектов (_feature_cells), без
## прохода по карте: operator_has_station() зовёт _draw() на КАЖДОГО юнита каждый кадр,
## а ИИ — на каждом решении, из нового резолвера.
##
## Источник правды — метка на самой клетке, а не поле у оператора. Станцию может
## снести взрывом, и тогда она исчезает вместе с меткой сама; поле у оператора
## пришлось бы чистить из каждого места, где рушится рельеф.
func _station_index() -> Dictionary:
	var out := {}
	for c: Vector2i in _feature_cells(MCF.FEATURE_DRONE_STATION):
		var op := state.grid.cell(c).station_operator_id
		if op != -1:
			out[op] = c
	return out

## Оператор развернул станцию — над ним «!» (batch 17, item 8). Раньше знак висел,
## пока станции НЕ было; по просьбе игрока он теперь означает обратное: станция стоит,
## дрон можно поднять.
func operator_has_station(u: UnitInstance) -> bool:
	if u == null or not u.is_alive() \
			or u.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return false
	return deployed_station_of(u) != Vector2i(-1, -1)

## Единый признак «не хватает обязательного снаряжения» (item 18): по нему рисуется общий
## восклицательный знак над юнитом. Сводит вместе четыре случая — инженер истратил свою ЛДФ,
## оператор дронов С развёрнутой станцией (item 8), огнемётчик без огнетушащей гранаты и пулемётчик
## без фраг-гранаты. Последние два опознаём по стартовому предмету стороны (default_item_id):
## юнит родился с ним, а сейчас в руках его нет.
func unit_missing_equipment(u: UnitInstance) -> bool:
	if u == null or not u.is_alive():
		return false
	if u.ldf_wall_used or operator_has_station(u):
		return true
	var need: String = u.stats.default_item_id
	# A heavy infantryman who has thrown his smoke is out of it too (playtest 2026-10-19).
	if need == MCF.ITEM_EXTINGUISHER or need == MCF.ITEM_FRAG or need == MCF.ITEM_SMOKE:
		return u.held_item_id != need
	return false

## "" = станцию можно свернуть обратно в предмет (item 16); иначе причина отказа.
func can_pick_up_station(operator: UnitInstance, coord: Vector2i) -> String:
	if operator == null or not operator.is_alive():
		return "Unit unavailable"
	if operator.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return "Only a drone operator packs up a station"
	if operator.remaining_ap <= 0:
		return "Unit has no AP left"
	if operator.held_item_id != "":
		return "Hands are full"
	if not state.grid.in_bounds(coord):
		return "Out of bounds"
	if Combat.distance(operator.coord, coord) != 1:
		return "The station must be right next to you"
	var cell := state.grid.cell(coord)
	if cell.feature_id != MCF.FEATURE_DRONE_STATION:
		return "No station there"
	# Любую СВОЮ станцию рядом (issues-12 #3/#14), а не только поставленную этим же
	# оператором: метка оператора теряется (челнок, редактор), и станцию было не убрать.
	if cell.feature_owner != operator.owner:
		return "That station is not yours"
	# Дрон, сидящий на станции, сворачивается вместе с ней; улетевший — сперва вернуть.
	# Раньше требовалось «посадить» дрон, а посадки в игре нет: станция с живым дроном
	# не сворачивалась никогда.
	# Only one drone fits on the pad: a second one launched from it hovers beside it and
	# could never "land". Drones on the pad or right next to it fold up with it.
	for d in state.all_units():
		if d.is_drone and d.is_alive() and d.home_station == coord and Combat.distance(d.coord, coord) > 1:
			return "Fly the drone back to the station first"
	return ""

## Свои станции рядом, которые можно свернуть прямо сейчас — для подсветки в UI.
func station_pickup_cells(operator: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if operator == null:
		return out
	for n in state.grid.neighbors(operator.coord):
		if can_pick_up_station(operator, n) == "":
			out.append(n)
	return out

func _resolve_pickup_station(intent: PickUpStationIntent) -> ActionResult:
	var operator := state.get_unit(intent.actor_id)
	var err := _validate_actor(operator)
	if err != "":
		return ActionResult.fail(err)
	var reason := can_pick_up_station(operator, intent.coord)
	if reason != "":
		return ActionResult.fail(reason)
	var cell := state.grid.cell(intent.coord)
	cell.station_operator_id = -1
	cell.clear_feature()
	var docked := false
	for d in state.all_units():
		if d.is_drone and d.is_alive() and d.home_station == intent.coord:
			state.remove_unit(d.id)
			docked = true
	# Станция стояла в кресле челнока (batch 13 S8) — кресло снова свободно.
	var svid := state.grid.vehicle_at(intent.coord)
	if svid != -1:
		var sveh := state.get_vehicle(svid)
		if _seated(sveh):
			for i in sveh.seats.size():
				if sveh.seat_cell(i) == intent.coord and sveh.seats[i] == Vehicle.SEAT_STATION:
					sveh.seats[i] = -1
	operator.remaining_ap -= 1
	operator.held_item_id = MCF.ITEM_DRONE_STATION
	return ActionResult.success(["%s folds the drone station at (%d, %d) back up%s [AP: %d]" % [
		operator.stats.display_name, intent.coord.x, intent.coord.y,
		" with its drone" if docked else "", operator.remaining_ap]])

## Живой дрон этого оператора (или null).
func active_drone_of(operator: UnitInstance) -> UnitInstance:
	for u in state.all_units():
		if u.is_drone and u.is_alive() and u.operator_id == operator.id:
			return u
	return null

## Оператор жив и стоит вплотную к своей станции — только тогда управляет дроном (§3.12).
func operator_controls(drone: UnitInstance) -> bool:
	var op := state.get_unit(drone.operator_id)
	if op == null or not op.is_alive():
		return false
	if state.grid.cell(drone.home_station).feature_id != MCF.FEATURE_DRONE_STATION:
		return false
	return Combat.distance(op.coord, drone.home_station) == 1

func _free_cell_near(coord: Vector2i) -> Vector2i:
	for n in state.grid.neighbors(coord):
		if state.grid.cell(n).is_empty():
			return n
	return Vector2i(-1, -1)

## Живой дрон, висящий над клеткой (или null). Дроны не хранятся в occupant (#13),
## поэтому ищем по координате.
func _drone_at(coord: Vector2i) -> UnitInstance:
	for u in state.all_units():
		if u.is_drone and u.is_alive() and u.coord == coord:
			return u
	return null

## Куда можно поставить дрон рядом: в поле, не стена, без корпуса машины и другого
## дрона. Наземный жилец (труп/юнит) не мешает — дрон висит сверху (#13).
func _free_flight_cell_near(coord: Vector2i) -> Vector2i:
	for n in state.grid.neighbors(coord):
		var c := state.grid.cell(n)
		if not c.is_wall() and c.vehicle_id == -1 and _drone_at(n) == null:
			return n
	return Vector2i(-1, -1)

## Маршрут дрона от его клетки до target, БЕЗ старта и включая финиш (item 12).
##
## Дрон до сих пор просто телепортировался: пехота свой переход отыгрывает по клеткам
## (событие «walk»), а полёт на тридцать клеток случался мгновенно, и в чужой ход
## игрок видел лишь «дрон был там, стал тут». Событие то же самое, что у пехоты, —
## значит и рисуется тем же кодом.
##
## Пустой массив — маршрут не восстанавливается (цель не из последнего разлёта).
## Шаги ограничены размером карты: испорченная цепочка предшественников не должна
## закручивать резолвер в вечный цикл.
func _drone_route(from_coord: Vector2i, target: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if target == from_coord:
		return out
	var cur := target
	var guard: int = state.grid.width * state.grid.height + 2
	while cur != from_coord and guard > 0:
		out.push_front(cur)
		if not _drone_prev.has(cur):
			return [] as Array[Vector2i]
		cur = _drone_prev[cur]
		guard -= 1
	return out if cur == from_coord else [] as Array[Vector2i]

## Клетки, куда дрон может долететь СВОБОДНЫМ МАРШРУТОМ (§3.12, ответ игрока «Free path,
## diag=2»): Дейкстра по 8 направлениям, ортогональный шаг = 1, диагональный = 2, бюджет
## полёта = DRONE_FLIGHT_RANGE, привязь к станции ≤ DRONE_LEASH (item 13). Корпус машины и
## чужой дрон непроходимы; горящая клетка — терминал (влететь можно, пролететь сквозь — нет).
##
## Стена — тоже терминал (#96): над ней дрон ЗАВИСАЕТ, но не пролетает. Так делается
## подрыв вплотную к стене — дрон садится сверху и детонирует, снося её. Обратно со стены
## есть ровно один путь, тем же курсом (см. wall_entry_from), иначе дрон переползал бы
## стену по клеткам и оказывался на другой стороне — а сквозь стены он не летает.
## Возвращает { клетка : стоимость пути }.
## Куда дрон может долететь ПРЯМО СЕЙЧАС. Бюджет — недолётанный остаток прошлого
## подлёта, если он есть (#13): дрон доканчивает начатое движение так же, как пехота
## доходит остаток своего (#44), и второго действия за это не платит.
##
## Привязь к станции считается ОТДЕЛЬНО и всегда по полному радиусу связи (DRONE_LEASH):
## она не «запас хода», а расстояние, на котором станция ещё держит дрон, и укоротить
## её остатком бюджета было бы неверно.
func _drone_reach(drone: UnitInstance) -> Dictionary:
	var budget: int = drone.move_credit if drone.move_credit > 0 else MCF.drone_range(drone)
	var leash := MCF.drone_leash(drone)
	if state.grid.cell(drone.coord).is_wall():
		return _drone_wall_exit(drone)
	var dist := {drone.coord: 0}
	var out: Dictionary = {}
	var visited: Dictionary = {}
	var frontier: Array = [drone.coord]
	_drone_prev = {}
	# Дроны по клеткам — один проход вместо _drone_at() на каждого соседа каждой клетки:
	# тот перебирал всех юнитов карты, и на карте дронов поиск стоил ~60 мс. Первый
	# встреченный дрон на клетке — ровно тот, кого вернул бы _drone_at().
	var drones_at := {}
	for u in state.all_units():
		if u.is_drone and u.is_alive() and not drones_at.has(u.coord):
			drones_at[u.coord] = u
	while not frontier.is_empty():
		var best_i := 0
		for i in range(1, frontier.size()):
			if int(dist[frontier[i]]) < int(dist[frontier[best_i]]):
				best_i = i
		var cur: Vector2i = frontier[best_i]
		frontier.remove_at(best_i)
		if visited.has(cur):
			continue
		visited[cur] = true
		if cur != drone.coord:
			out[cur] = int(dist[cur])
			if state.grid.cell(cur).on_fire or state.grid.cell(cur).is_wall():
				continue  # огонь и стена — дальше не летим
		for dir: Vector2i in DRONE_DIRS_8:
			var nxt: Vector2i = cur + dir
			if not state.grid.in_bounds(nxt):
				continue
			var step_cost: int = 2 if (dir.x != 0 and dir.y != 0) else 1
			var nd: int = int(dist[cur]) + step_cost
			if nd > budget:
				continue
			if Combat.distance(nxt, drone.home_station) > leash:
				continue
			var cell := state.grid.cell(nxt)
			# Дрон перелетает трупы, юнитов и технику и зависает над ними (#13; над
			# корпусом машины — batch borg-corpses): мешает лишь другой дрон.
			var od: UnitInstance = drones_at.get(nxt)
			if od != null and od != drone:
				continue
			if not dist.has(nxt) or nd < int(dist[nxt]):
				dist[nxt] = nd
				_drone_prev[nxt] = cur  # item 12: по этой цепочке строится маршрут полёта
				frontier.append(nxt)
	return out

## Единственный ход дрона, зависшего над стеной (#96): вернуться туда, откуда он зашёл.
## Пустой словарь — путь назад заняли (корпус машины, чужой дрон) или он не записан;
## тогда со стены дрону остаётся только подрыв.
func _drone_wall_exit(drone: UnitInstance) -> Dictionary:
	var back := drone.wall_entry_from
	if back == Vector2i(-1, -1) or not state.grid.in_bounds(back) or back == drone.coord:
		return {}
	if Combat.distance(back, drone.home_station) > MCF.drone_leash(drone):
		return {}
	var od := _drone_at(back)
	if od != null and od != drone:
		return {}
	_drone_prev = {back: drone.coord}  # спуск — тоже маршрут, пусть и в один шаг (item 12)
	return {back: 1}

func drone_flight_cells(drone: UnitInstance) -> Array:
	return _drone_reach(drone).keys()

## Клетки полёта с ценой (клетка -> сколько клеток подлёта уйдёт) — для зон хода на экране.
func drone_flight_costs(drone: UnitInstance) -> Dictionary:
	return _drone_reach(drone)

## Маршрут полёта дрона до клетки — для предпросмотра (item 12). Это ТОТ ЖЕ путь, по
## которому дрон потом полетит: цепочку предшественников строит сам разлёт, и другого
## маршрута у него нет.
##
## Разлёт пересчитывается здесь намеренно: _drone_prev живёт ровно до следующего чужого
## расчёта, а между двумя кадрами отрисовки резолвер успевает посчитать что угодно —
## взять «последний» _drone_prev и понадеяться, что он про этого дрона, нельзя.
func drone_route_to(drone: UnitInstance, target: Vector2i) -> Array[Vector2i]:
	if drone == null or not drone.is_drone or not state.grid.in_bounds(target):
		return [] as Array[Vector2i]
	_drone_reach(drone)
	return _drone_route(drone.coord, target)

## Потолок одного подлёта: остаток прошлого или полный подлёт за ОД.
func drone_flight_budget(drone: UnitInstance) -> int:
	return drone.move_credit if drone.move_credit > 0 else MCF.drone_range(drone)

## С какой клетки дрон зашёл на стену (#96) — туда же он потом и вернётся. Берём
## предшественника на кратчайшем маршруте, ничьи разрешаем по координатам: иначе хост
## и клиент записали бы РАЗНЫЕ пути отхода. (-1,-1) — зайти на стену неоткуда.
func _drone_entry_cell(drone: UnitInstance, target: Vector2i, reach: Dictionary) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_key: Array = [1 << 30, 0, 0]
	for dir: Vector2i in DRONE_DIRS_8:
		var n: Vector2i = target + dir
		if not state.grid.in_bounds(n) or state.grid.cell(n).is_wall():
			continue
		var cost := 0
		if n != drone.coord:
			if not reach.has(n):
				continue
			cost = int(reach[n])
		var key: Array = [cost, n.y, n.x]
		if key < best_key:
			best_key = key
			best = n
	return best

## Клетка, из которой дрон таранит занятую цель (или (-1,-1)).
func _approach_cell(drone: UnitInstance, target: Vector2i, reach: Dictionary) -> Vector2i:
	if not state.grid.in_bounds(target):
		return Vector2i(-1, -1)
	# Таран — только по другому дрону (#13): юнитов, трупы и технику дрон облетает и
	# зависает над ними (над машиной — batch borg-corpses; бить её — подрывом сверху), а
	# над стеной ЗАВИСАЕТ (#96).
	var other_drone := _drone_at(target)
	var blocked: bool = other_drone != null and other_drone != drone
	if not blocked:
		return Vector2i(-1, -1)
	# Дрон таранит из любой соседней клетки, куда может долететь (8 направлений).
	for dir: Vector2i in DRONE_DIRS_8:
		var n: Vector2i = target + dir
		if n == drone.coord or reach.has(n):
			return n
	return Vector2i(-1, -1)
