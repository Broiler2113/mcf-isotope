@abstract
extends "res://src/resolver/parts/ResolverDamage.gd"

## Moving: walking, sliding in zero-g, dragging bodies and light objects, carrying and
## capturing.

# --- Движение (§3.1, §3.2) ---
func _resolve_move(intent: MoveIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit, unit.move_credit if unit != null else 0)
	if err != "":
		return ActionResult.fail(err)
	# blocks_walk, а не is_occupied_or_wall: закрытый шлюз для пешего маршрута не
	# преграда — он разъедется, когда боец подойдёт вплотную (#100).
	if state.grid.blocks_walk(intent.target):
		return ActionResult.fail("Cell is occupied or impassable")

	# Перенос удерживаемого юнита (§3.4) или тяжёлого объекта (#34): бюджет −3 клетки.
	var carried := held_unit_of(unit)
	var dragged := dragged_cell_of(unit)
	var use_credit := unit.move_credit > 0
	# Клетка в оранжевой/красной зоне — ход за 2/3 ОД одним путём (остаток переносится).
	var tiers := move_tier_budgets(unit)
	var reach := reachable_for(unit, tiers[tiers.size() - 1])
	if not reach.can_reach(intent.target):
		return ActionResult.fail("Target out of reach (speed %d)" % tiers[tiers.size() - 1])

	var spent: int = reach.cost[intent.target]
	var extra := tier_of(tiers, spent)
	var budget: int = tiers[extra]
	unit.remaining_ap -= extra
	var path := reach.path_to(intent.target)
	var origin := unit.coord
	state.grid.move_occupant(unit.coord, intent.target)
	# Боец сдвинулся — створки шлюзов по всей карте пересчитываются сразу (#100),
	# иначе покинутый шлюз остался бы открытым до следующего действия.
	update_airlocks()
	# Списываем либо ОД (свежее движение), либо накопленный кредит (#44).
	# Волочение объекта ОД не стоит вовсе: и сам захват, и шаги с грузом бесплатны.
	if use_credit or dragged != UnitInstance.NOT_DRAGGING:
		unit.move_credit = maxi(0, budget - spent)
	else:
		unit.remaining_ap -= 1
		unit.move_credit = maxi(0, budget - spent)
	# Незавершённая стрельба (action_state) НЕ сбрасывается — дробление, §3.2.
	var lines: Array[String] = ["%s: move → (%d, %d) [AP: %d]" % [
		unit.stats.display_name, intent.target.x, intent.target.y, unit.remaining_ap]]

	# Наступил на чужую мину где-то по дороге (item 45). Проверяется ВЕСЬ маршрут,
	# а не только конечная клетка: мину ставят на пути, а не в точке назначения.
	var mine := _mine_on_path(unit, path)
	var gas_res := ActionResult.success([])
	var walk_origin := origin
	var walk_path := path
	if unit.borg_id == -1 and GridCell.gassed > 0:
		var first_fire := _fire_on_path(unit, path)
		for step: Vector2i in path:
			if step == mine or step == first_fire: break
			if state.grid.cell(step).gas:
				state.grid.move_occupant(unit.coord, step)
				_fx_steps(gas_res, unit, origin, path, step)
				_gas_survival(unit, gas_res)
				if not unit.is_alive():
					unit.move_credit = 0
					update_airlocks()
					return gas_res
				# Animate the rest after the roll; never repeat the pre-gas walk.
				walk_origin = step
				walk_path = path.slice(path.find(step) + 1)
				state.grid.move_occupant(unit.coord, intent.target)
				break
	# Борг (batch 13 B15): противопехотную мину не замечает, противотанковая снимает
	# очко корпуса и останавливает его на месте подрыва.
	if unit.borg_id != -1:
		mine = NOWHERE
		for step: Vector2i in path:
			var mc := state.grid.cell(step)
			if mc != null and mc.feature_id == MCF.FEATURE_AV_MINE:
				mine = step
				break
		if mine != NOWHERE:
			if unit.coord != mine:
				state.grid.move_occupant(unit.coord, mine)
				update_airlocks()
			unit.move_credit = 0
			var bres := ActionResult.success(lines)
			var bcell := state.grid.cell(mine)
			bcell.clear_feature()
			notify_cell_changed(mine)
			_fx(bres, {"fx": "debris", "at": NOWHERE, "cells": [mine], "blast": true})
			_mine_flash(bres, mine)
			bres.log("The borg rolls over an anti-vehicle mine at (%d, %d)!" % [mine.x, mine.y])
			_sync_borg(unit)
			var bveh := state.get_vehicle(unit.borg_id)
			if bveh != null:
				_damage_component(bveh, MCF.COMP_HULL, MCF.AV_MINE_VEHICLE_DAMAGE, "mine", bres)
			return bres
	if mine != NOWHERE:
		# Боец остаётся ТАМ, где наступил. Это не косметика: взрыв бьёт по клетке
		# мины, и не вернув его туда, мы подорвали бы пустую землю, а сам он дошёл
		# бы до цели невредимым.
		if unit.coord != mine:
			state.grid.move_occupant(unit.coord, mine)
			update_airlocks()
		lines[0] = "%s: move → (%d, %d), stopped at (%d, %d) [AP: %d]" % [
			unit.stats.display_name, intent.target.x, intent.target.y,
			mine.x, mine.y, unit.remaining_ap]
		# Дальше идти некуда — недоеденные клетки этого движения пропадают вместе с ним.
		unit.move_credit = 0
		var mine_res := gas_res
		mine_res.log_lines.append_array(lines)
		_fx_steps(mine_res, unit, walk_origin, walk_path, mine)
		_detonate_mine(mine, unit, mine_res)
		return mine_res

	# Пересёк горящую клетку — мгновенная смерть без спасброска (isotope §6.5, #1).
	# Проверяется ВЕСЬ маршрут, а не только цель: сгореть можно и на полпути.
	# Щитоносец и огнемётчик огня не боятся (#2, #50).
	var fire := _fire_on_path(unit, path)
	if fire != NOWHERE:
		# Как и с миной: боец остаётся ТАМ, где сгорел, а не доходит до цели.
		if unit.coord != fire:
			state.grid.move_occupant(unit.coord, fire)
			update_airlocks()
		unit.move_credit = 0
		var burn_res := gas_res
		burn_res.log_lines.append_array(lines)
		_fx_steps(burn_res, unit, walk_origin, walk_path, fire)
		_kill_burnt(unit)  # сгорел — крови нет (batch ui-drones)
		burn_res.log("%s burned to death at (%d, %d)!" % [
			unit.stats.display_name, fire.x, fire.y])
		return burn_res

	if carried != null:
		# Игрок может выбрать клетку для пленника (свободная, рядом с целью); иначе —
		# предпоследняя клетка пути (§3.4).
		var drop: Vector2i = origin if path.size() < 2 else path[path.size() - 2]
		if _valid_carry_drop(intent.carry_drop, intent.target):
			drop = intent.carry_drop
		var carried_from := carried.coord
		state.grid.move_occupant(carried.coord, drop)
		_carried_slide = [carried, carried_from, drop]
		lines.append("  ↳ carrying %s → (%d, %d)" % [carried.stats.display_name, drop.x, drop.y])

	# Волочимый объект переезжает на предпоследнюю клетку пути — как пленник (#34).
	if dragged != UnitInstance.NOT_DRAGGING:
		var spot: Vector2i = origin if path.size() < 2 else path[path.size() - 2]
		if _move_light_object(dragged, spot, gas_res):
			unit.dragging = spot
			lines.append("  ↳ dragging \"%s\" → (%d, %d)" % [
				MCF.feature_name(state.grid.cell(spot).feature_id, "object"), spot.x, spot.y])
		else:
			unit.dragging = UnitInstance.NOT_DRAGGING
			lines.append("  ↳ dropped the object at (%d, %d)" % [dragged.x, dragged.y])
	else:
		unit.dragging = UnitInstance.NOT_DRAGGING   # the object was lost or left behind

	var moved_res := gas_res
	moved_res.log_lines.append_array(lines)
	_fx_steps(moved_res, unit, walk_origin, walk_path, intent.target)
	# Пленник переезжает вместе с носильщиком — и так же плавно (0.9.4).
	if not _carried_slide.is_empty():
		_slide_fx(_carried_slide[0], _carried_slide[1], _carried_slide[2], moved_res)
		_gas_on_arrival(_carried_slide[0], moved_res)
		_carried_slide = []
	return moved_res

## Шаги по клеткам: маршрут до точки остановки включительно. Кровавых отпечатков ног
## здесь больше нет (0.9.3) — осталась только сама анимация хода.
func _fx_steps(res: ActionResult, unit: UnitInstance, origin: Vector2i, path: Array, stop: Vector2i) -> void:
	var cut: Array = []
	var previous := origin
	for c: Vector2i in path:
		cut.append(c)
		if _is_shield(unit):
			_knock_items(res, c, previous, false)
			_fx(res, {"fx": "sweep_props", "at": c, "from": previous})
		previous = c
		if c == stop:
			break
	# Боец идёт по клеткам на экране, а не появляется в конце (batch soil-rulers): то же
	# событие «walk», каким уже ходят жители и летают дроны, и «hold», который до начала
	# анимации держит его рисунок в стартовой клетке.
	if not cut.is_empty():
		res.dice_events.append({"kind": "hold", "units": {unit.id: origin}})
		res.dice_events.append({"kind": "walk", "unit": unit.id, "from": origin,
				"path": cut, "soldier": true})

## ЛЮБОЕ перемещение юнита — ПЛАВНОЕ (0.9.4). Игрок жаловался, что «only half of all
## possible movements actually are» смещения: пеший ход уже шёл по клеткам (_fx_steps), а
## отбрасывание в невесомости, толчок щитом, перестановка пленника и волочение трупа
## перескакивали мгновенно. Клетка меняется как и раньше — экран получает те же события
## «hold» (держать рисунок в старой клетке) и «walk» (вести по клеткам), какими уже
## идёт пеший ход.
##
## Путь — прямая по Чебышёву от старой клетки к новой: все эти смещения идут по прямой и
## не дальше нескольких клеток, так что обходить препятствия тут нечего.
func _slide_fx(unit: UnitInstance, from: Vector2i, to: Vector2i, res: ActionResult) -> void:
	if res == null or unit == null or from == to:
		return
	var path: Array[Vector2i] = []
	var p := from
	while p != to and path.size() < SLIDE_PATH_CAP:
		p += Vector2i(signi(to.x - p.x), signi(to.y - p.y))
		path.append(p)
	if path.is_empty():
		return
	res.dice_events.append({"kind": "hold", "units": {unit.id: from}})
	res.dice_events.append({"kind": "walk", "unit": unit.id, "from": from, "path": path,
			"soldier": true})

## Переставить юнита и показать это плавно (0.9.4).
func _slide(unit: UnitInstance, to: Vector2i, res: ActionResult) -> void:
	var from := unit.coord
	if from == to: return
	if res == null: res = ActionResult.success([])
	var step := from
	while step != to:
		step += Vector2i(signi(to.x - step.x), signi(to.y - step.y))
		if state.grid.cell(step).gas:
			state.grid.move_occupant(unit.coord, step)
			_slide_fx(unit, from, step, res)
			_gas_survival(unit, res)
			if not unit.is_alive(): return
			from = step
			break
	state.grid.move_occupant(unit.coord, to)
	_slide_fx(unit, from, to, res)

func _gas_on_arrival(unit: UnitInstance, res: ActionResult) -> void:
	var cell := state.grid.cell(unit.coord)
	if cell != null and cell.gas:
		_gas_survival(unit, res)

## Клетка волочимого объекта, если юнит и правда его тащит и объект ещё рядом (#34).
## A pure query: peers ask it at different moments (move previews, legal-move masks), so
## ending a lapsed drag here forked lockstep state. The next move or action ends it.
func dragged_cell_of(unit: UnitInstance) -> Vector2i:
	if unit == null or unit.dragging == UnitInstance.NOT_DRAGGING:
		return UnitInstance.NOT_DRAGGING
	if not state.grid.in_bounds(unit.dragging) \
			or Combat.distance(unit.coord, unit.dragging) > 1 \
			or not grabbable_cell(unit.dragging):
		return UnitInstance.NOT_DRAGGING
	return unit.dragging

## Переставить лёгкий объект (с его высотой/кучей) на свободную клетку. false — некуда.
func _move_light_object(src: Vector2i, dst: Vector2i, res: ActionResult = null) -> bool:
	if src == dst:
		return true
	var src_cell := state.grid.cell(src)
	var dst_cell := state.grid.cell(dst)
	if dst_cell == null or not dst_cell.is_buildable():
		return false
	var fid := src_cell.feature_id
	var fowner := src_cell.feature_owner
	var dirt := src_cell.dirt_level
	var dur := src_cell.feature_durability
	var opened := src_cell.items_off & GridCell.OPENED
	src_cell.clear_feature()
	dst_cell.set_feature(fid, fowner)
	dst_cell.feature_durability = dur
	dst_cell.items_off |= opened
	_furniture_moved(res, src, dst, fid)
	if fid == MCF.FEATURE_DIRT_PILE:
		dst_cell.dirt_level = dirt
		dst_cell.cover_height = MCF.DIRT_HEIGHT_PER_LEVEL * float(dirt)
	_extinguish_cell(dst_cell)  # объект, придвинутый на огонь, сбивает пламя (#82)
	return true

# --- Захват (§3.4) ---
func _resolve_capture(intent: CaptureIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	var target := state.get_unit(intent.target_id)
	if target == null or not target.is_alive():
		return ActionResult.fail("No target to capture")
	# Пассажира челнока из кресла не выдернешь (batch 13): он под бортом, а не на полу.
	if target.aboard_vehicle_id != -1:
		return ActionResult.fail("Can't grab someone inside a shuttle")
	if target.id == actor.id:
		return ActionResult.fail("Can't grab yourself")
	if target.captor_id != -1:
		return ActionResult.fail("Target is already held")
	# Одного бойца хватают не чаще раза за раунд (#100): иначе цепочка носильщиков
	# перекидывала бы пленника через полкарты за один ход.
	if target.carried_this_round:
		return ActionResult.fail("Target was already grabbed this round")
	if Combat.distance(actor.coord, target.coord) != 1:
		return ActionResult.fail("Target not in an adjacent cell")

	# Своего бойца берут без сопротивления (§3.4): он не отбивается.
	if target.owner == actor.owner:
		actor.remaining_ap -= 1
		target.status = MCF.Status.HELD
		target.captor_id = actor.id
		target.carried_this_round = true
		# ОД пленника НЕ сгорают (#76): пока его тащат, он ничего не тратит — действовать
		# ему всё равно не даёт сам захват (см. _validate_actor), а вырвавшись, он
		# доигрывает свой ход как обычно.
		target.action_state = null
		_grant_carry_move(actor)
		var ally_res := ActionResult.new()
		ally_res.ok = true
		ally_res.log("%s picked up %s." % [actor.stats.display_name, target.stats.display_name])
		return ally_res

	actor.remaining_ap -= 1  # попытка захвата стоит 1 ОД в любом исходе
	var a_roll := state.dice.roll_d6()
	var d_roll := state.dice.roll_d6()
	while a_roll == d_roll:  # ничья — переброс (§3.4)
		a_roll = state.dice.roll_d6()
		d_roll = state.dice.roll_d6()
	var success := a_roll > d_roll
	if success:
		target.status = MCF.Status.HELD
		target.captor_id = actor.id
		target.carried_this_round = true  # второй раз за раунд его уже не схватят (#100)
		target.action_state = null  # ОД пленника не сгорают (#76)
		_grant_carry_move(actor)

	var result := ActionResult.new()
	result.ok = true
	result.dice_events.append({
		"kind": "opposed", "attacker": actor.stats.display_name,
		"defender": target.stats.display_name, "a_roll": a_roll, "d_roll": d_roll,
		"attacker_wins": success, "def_owner": target.owner,
	})
	if success:
		result.log("%s captured %s!" % [actor.stats.display_name, target.stats.display_name])
	else:
		result.log("%s failed to capture %s (%d vs %d)" % [
			actor.stats.display_name, target.stats.display_name, a_roll, d_roll])
	return result

# --- Освобождение из захвата (§3.4): 4+ ---
func _resolve_release(intent: ReleaseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	if unit == null or not unit.is_held():
		return ActionResult.fail("Unit is not being held")
	if unit.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")

	# Своего держит союзник (#37): освобождение без броска и БЕСПЛАТНО — просто встаёт,
	# поэтому проверка ОД идёт ПОСЛЕ этой ветки.
	var captor := state.get_unit(unit.captor_id)
	if captor != null and captor.owner == unit.owner:
		unit.status = MCF.Status.ALIVE
		unit.captor_id = -1
		var ally_res := ActionResult.new()
		ally_res.ok = true
		ally_res.log("%s steps out of the friendly hold." % unit.stats.display_name)
		return ally_res

	if unit.remaining_ap <= 0:
		return ActionResult.fail("No AP left")
	unit.remaining_ap -= 1
	var roll := state.dice.roll_d6()
	var freed := roll >= 4
	if freed:
		unit.status = MCF.Status.ALIVE
		unit.captor_id = -1

	var result := ActionResult.new()
	result.ok = true
	result.dice_events.append({
		"kind": "check", "actor": unit.stats.display_name, "roll": roll, "need": 4, "ok": freed,
	})
	if freed:
		result.log("%s broke free from the grab (roll %d)!" % [unit.stats.display_name, roll])
	else:
		result.log("%s failed to break free (roll %d, need 4+)" % [unit.stats.display_name, roll])
	return result

# --- Перекладывание пленника (#100): бесплатно, на любую соседнюю с носильщиком клетку ---
## Носильщик не сходит с места и ничего не тратит — он лишь переставляет тело вокруг
## себя (закрыть собой проём, освободить линию огня, подставить пленника под удар).
func _resolve_move_held(intent: MoveHeldIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit not found")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	var carried := held_unit_of(actor)
	if carried == null:
		return ActionResult.fail("Unit is not holding anyone")
	if not _valid_carry_drop(intent.to, actor.coord):
		return ActionResult.fail("Cell is occupied or not adjacent to the carrier")
	var held_from := carried.coord
	state.grid.move_occupant(carried.coord, intent.to)
	update_airlocks()
	var res := ActionResult.new()
	res.ok = true
	_slide_fx(carried, held_from, intent.to, res)
	_gas_on_arrival(carried, res)
	res.log("%s shifts %s → (%d, %d)" % [
		actor.stats.display_name, carried.stats.display_name, intent.to.x, intent.to.y])
	# Переставленный на горящую клетку пленник сгорает — как и любой, кто туда попал.
	if state.grid.cell(intent.to).on_fire and not is_fireproof(carried):
		_kill_burnt(carried)
		res.log("%s burned to death!" % carried.stats.display_name)
		res.deaths.append(carried.id)
	return res

## Захват включает в себя перемещение (#25): сразу после удачного граба носитель
## получает кредит движения на «скорость − 3» клеток, чтобы утащить пленника тем же
## действием, не тратя второй ОД.
## Кредит именно ЗАДАЁТСЯ, а не берётся максимумом: иначе накопленный до граба остаток
## полной скорости пережил бы захват и пленника таскали бы без штрафа (#33).
func _grant_carry_move(actor: UnitInstance) -> void:
	actor.move_credit = maxi(0, actor.speed() - MCF.CAPTURE_CARRY_PENALTY)

## Юнит, которого удерживает captor (status HELD, captor_id == captor.id), или null (§3.4).
func held_unit_of(captor: UnitInstance) -> UnitInstance:
	if captor == null:
		return null
	for u in state.all_units():
		if u.is_held() and u.captor_id == captor.id:
			return u
	return null

## Пленника кладут в свободную клетку рядом с целью переноса (§3.4).
func _valid_carry_drop(drop: Vector2i, dest: Vector2i) -> bool:
	if drop == Vector2i(-999, -999) or not state.grid.in_bounds(drop):
		return false
	if drop == dest or Combat.distance(drop, dest) != 1:
		return false
	return not state.grid.blocks_walk(drop)

## Свободные соседние с целью клетки, куда можно положить пленника (для UI).
func carry_drop_cells(dest: Vector2i) -> Array:
	var out: Array = []
	for n in state.grid.neighbors(dest):
		if not state.grid.blocks_walk(n):
			out.append(n)
	return out

## Волочат мешки, ежа, кучу земли — и тяжёлую мебель (§3.15): шкаф, стол, верстак едут
## тем же волочением, без своей механики.
static func is_draggable_feature(fid: String) -> bool:
	return DRAGGABLE_FEATURES.has(fid) or Furniture.draggable(fid)

## Можно ли взять в руки (волочь) объект на этой клетке: вид волочится, и это не часть
## многоклеточного — ни клетка кровати 2×2 или стола, ни секция, приросшая к ряду (§3.15).
## Одиночная секция или одноклеточный предмет — пожалуйста.
func grabbable_cell(c: Vector2i) -> bool:
	if not state.grid.in_bounds(c):
		return false
	var fid := state.grid.cell(c).feature_id
	if not is_draggable_feature(fid):
		return false
	if Furniture.joins(fid):
		for d: Vector2i in Furniture.N4:
			var q: Vector2i = c + d
			if state.grid.in_bounds(q) and state.grid.cell(q).feature_id == fid:
				return false
	return true

func _resolve_drag(intent: DragIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	var src: Vector2i = intent.object_coord
	var dst: Vector2i = intent.dest_coord
	if not state.grid.in_bounds(src) or not state.grid.in_bounds(dst):
		return ActionResult.fail("Cell out of bounds")
	if Combat.distance(actor.coord, src) != 1:
		return ActionResult.fail("Object not in an adjacent cell")
	# Многоклеточное (кровать 2×2, стол, секция в ряду стойки) руками не берут (§3.15).
	if is_draggable_feature(state.grid.cell(src).feature_id) and not grabbable_cell(src):
		return ActionResult.fail("Too big to move — it's part of a larger piece")
	if Combat.distance(actor.coord, dst) != 1:
		return ActionResult.fail("Can only drag to an adjacent cell")
	var src_cell := state.grid.cell(src)
	var dst_cell := state.grid.cell(dst)

	# Труп (occupant со статусом CORPSE).
	var corpse := src_cell.occupant
	if corpse != null and corpse.status == MCF.Status.CORPSE:
		# Складирование в кучу: на целевой клетке уже лежат тела (§3.7). Считаем их
		# через corpses_at (#98) — куча и труп-occupant складываются в один стек.
		if corpses_at(dst) > 0:
			if corpses_at(dst) >= MCF.CORPSE_WALL_COUNT:
				return ActionResult.fail("No room for another body here")
			if not can_drop_corpse_at(dst):
				return ActionResult.fail("Can't place a corpse there")
			# Перетаскиваемый труп уходит в кучу — убираем его из игры.
			src_cell.occupant = null
			state.remove_unit(corpse.id)
			if _add_corpse_to_cell(dst):
				return ActionResult.success(["%s formed a corpse wall at (%d, %d) [AP: %d]" % [
					actor.stats.display_name, dst.x, dst.y, actor.remaining_ap]])
			return ActionResult.success(["%s piled a corpse (%d/%d) at (%d, %d) [AP: %d]" % [
				actor.stats.display_name, corpses_at(dst), MCF.CORPSE_WALL_COUNT,
				dst.x, dst.y, actor.remaining_ap]])
		if not dst_cell.is_empty():
			return ActionResult.fail("Target cell is occupied")
		state.grid.move_occupant(src, dst)
		# Постройка на горящей клетке/перенос груза на неё тушит пламя (#82).
		_extinguish_cell(dst_cell)
		var drag_res := ActionResult.success(["%s dragged a corpse → (%d, %d) [AP: %d]" % [
			actor.stats.display_name, dst.x, dst.y, actor.remaining_ap]])
		_slide_fx(corpse, src, dst, drag_res)   # тело переезжает плавно (0.9.4)
		return drag_res

	# Лёгкий объект (мешки/ёж/куча земли) — тащить может любой юнит (#30).
	if is_draggable_feature(src_cell.feature_id):
		var fid := src_cell.feature_id
		var fowner := src_cell.feature_owner
		var dirt := src_cell.dirt_level
		# Мешки на мешки и ёж на мешки складываются в стену 2 м (#31).
		var stacked := stack_onto(dst_cell, fid)
		if not dst_cell.is_buildable() and stacked == "":
			return ActionResult.fail("Target cell is occupied")
		var placed: String = stacked if stacked != "" else fid
		var dur := src_cell.feature_durability
		var opened := src_cell.items_off & GridCell.OPENED
		src_cell.clear_feature()
		dst_cell.set_feature(placed, fowner)
		if stacked == "":
			dst_cell.items_off |= opened
		if stacked == "":
			dst_cell.feature_durability = dur   # поцарапанный шкаф не чинится переездом
		if placed == MCF.FEATURE_DIRT_PILE:
			# Куча переезжает целиком, вместе с набранной высотой.
			dst_cell.dirt_level = dirt
			dst_cell.cover_height = MCF.DIRT_HEIGHT_PER_LEVEL * float(dirt)
		# Объект, поставленный на горящую клетку, сбивает пламя (#82).
		_extinguish_cell(dst_cell)
		# Объект остаётся в руках: тащить его дальше можно движением, но с тем же
		# штрафом −3 клетки, что и при переносе пленника (#34). Стопка — уже не груз.
		if stacked == "":
			actor.dragging = dst
			_grant_carry_move(actor)
		var dragged_res := ActionResult.success(["%s dragged \"%s\" → (%d, %d) [AP: %d]" % [
			actor.stats.display_name, MCF.feature_name(placed, placed),
			dst.x, dst.y, actor.remaining_ap]])
		_furniture_moved(dragged_res, src, dst, fid)
		return dragged_res

	return ActionResult.fail("Nothing here to drag")

## Соседние клетки с перетаскиваемым объектом (труп/мешки/ёж/куча земли) — для UI.
## Трупов здесь БОЛЬШЕ НЕТ (#7): в режиме «рука» тело теперь ПОДНИМАЮТ, а не волокут
## по земле — см. corpse_pickup_cells(). Само намерение DragIntent труп по-прежнему
## переносит (сеть и старые записи остаются валидными), просто UI его не предлагает.
func draggable_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	for n in state.grid.neighbors(actor.coord):
		if grabbable_cell(n):
			out.append(n)
	return out

## Клетки с телом, которое боец может взять В РУКИ из режима «рука» (#7): своя и восемь
## соседних. Пусто, если руки уже полны (#9) или нет ОД — подсветка обязана совпадать
## с тем, что примет _resolve_pickup_corpse, иначе клик «не работает».
func corpse_pickup_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null or actor.remaining_ap <= 0 \
			or actor.carried_corpses >= MCF.CORPSE_CARRY_MAX or actor.borg_id != -1 \
			or _is_shield(actor):  # щитоносец трупы не носит (item 17), борг тоже
		return out
	# Тело под стоящей машиной не достать (batch 12 #2): оно лежит там, но под днищем. Своя
	# клетка — не исключение: резолвер проверяет любую, и без этой проверки перечислитель
	# RL предлагал подъём, который тут же отклонялся («The body is under a vehicle»).
	for n in [actor.coord] + state.grid.neighbors(actor.coord):
		if has_corpse(n) and state.grid.vehicle_at(n) == -1:
			out.append(n)
	return out

## Соседние клетки, куда можно поставить перетаскиваемый объект (object_coord) — для UI.
## Труп можно ещё и складировать в кучу к другому трупу (§3.7).
func drag_dest_cells(actor: UnitInstance, object_coord: Vector2i) -> Array:
	var src := state.grid.cell(object_coord)
	var is_corpse := src != null and src.occupant != null and src.occupant.status == MCF.Status.CORPSE
	var out: Array = []
	for n in state.grid.neighbors(actor.coord):
		if n == object_coord:
			continue
		var cell := state.grid.cell(n)
		if cell.is_empty() and not cell.has_feature():
			out.append(n)
		elif is_corpse and cell.occupant != null and cell.occupant.status == MCF.Status.CORPSE:
			out.append(n)
		elif not is_corpse and src != null and stack_onto(cell, src.feature_id) != "":
			out.append(n)
	return out

## Зона хода по цене пути: первый потолок, в который цена влезла (0 — зелёная).
static func tier_of(budgets: Array[int], cost: int) -> int:
	var k := 0
	while k < budgets.size() - 1 and cost > budgets[k]:
		k += 1
	return k
