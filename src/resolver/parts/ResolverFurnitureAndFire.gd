@abstract
extends "res://src/resolver/parts/ResolverWeapons.gd"

## Furniture (smashing, carrying, putting down) and fire.

# --- Мебель (§3.15): разломать, унести в руках, поставить ---------------------------
## Мебель ломает ЛЮБОЙ боец, а не только шахтёр с инженером: это не укрепление, а стол.
## То же намерение BreakIntent и та же зачистка клетки, что у слома укреплений; цена в
## ОД — из таблицы мебели (1 обычное, 2 крупное, 3 тяжёлое железо). Не боец (дрон) и
## пассажир машины ломать не могут: первому нечем, второй сидит в кресле.
func can_smash_furniture(actor: UnitInstance, coord: Vector2i) -> String:
	var err := _validate_actor(actor)
	if err != "":
		return err
	if actor.is_drone:
		return "A drone can't do that"
	if actor.aboard_vehicle_id != -1:
		return "Get out of the vehicle first"
	if not state.grid.in_bounds(coord) or Combat.distance(actor.coord, coord) != 1:
		return "Can only break furniture in an adjacent cell"
	var fid := state.grid.cell(coord).feature_id
	if not Furniture.is_furniture(fid):
		return "No furniture there"
	var cost := Furniture.break_ap(fid)
	if actor.remaining_ap < cost:
		return "Need %d AP" % cost
	return ""

func _resolve_smash_furniture(actor: UnitInstance, coord: Vector2i) -> ActionResult:
	var reason := can_smash_furniture(actor, coord)
	if reason != "":
		return ActionResult.fail(reason)
	var cell := state.grid.cell(coord)
	var fid := cell.feature_id
	actor.remaining_ap -= Furniture.break_ap(fid)
	var res := ActionResult.success(["%s smashes the %s at (%d, %d) [AP: %d]" % [
		actor.stats.display_name, Furniture.name_of(fid).to_lower(), coord.x, coord.y,
		actor.remaining_ap]])
	_destroy_furniture(cell, res)
	return res

## Снести предмет мебели: пол остаётся, высота сбрасывается в ноль (clear_feature), журнал
## вида и обзора узнаёт об этом через сеттеры клетки.
## Гибнет только задетая клетка (0.12.2, владелец: «when a part of a table is destroyed, the
## whole table gets deleted»): остальной стол стоит, как стоял, — вид мебели в бою заморожен
## и не срастается заново, так что уцелевшая половина выглядит половиной.
func _destroy_furniture(cell: GridCell, res: ActionResult, from: Vector2i = NOWHERE) -> void:
	var cells: Array[Vector2i] = [cell.coord]
	if Furniture.DEFS.get(cell.feature_id, {}).get("cat", "") == "lighting":
		_lamp_shards(res, cell.coord, from)
	for c: Vector2i in cells:
		_knock_items(res, c, from if from != NOWHERE else c)
		_spill(res, c, from if from != NOWHERE else c, cell.feature_id, true)
	# It breaks into pieces of itself (owner, fix-8 #7): chunks cut from its own picture
	# fly off as a wall's do, more of them from a big piece; the floor stays as it was.
	var fid := cell.feature_id
	for c: Vector2i in cells:
		_wall_chunks(res, c, from if from != NOWHERE else c, fid, 9 if Furniture.height_of(fid) >= 1.5 else 6)
	for c: Vector2i in cells:
		state.grid.cell(c).clear_feature()
		notify_cell_changed(c)

## A lamp breaks like a window (0.11.1): its glass flies off as the same shards, away
## from whatever hit it. A wall lamp (side >= 0) sheds them onto the floor of its own side.
func _lamp_shards(res: ActionResult, c: Vector2i, from: Vector2i, side: int = -1) -> void:
	if res == null: return
	var at := c + Furniture.N4[side] if side >= 0 else c
	if not state.grid.in_bounds(at): at = c
	_fx(res, {"fx": "shards", "at": at, "from": from if from != NOWHERE else c})

## Клетки предмета мебели, которому принадлежит c (у секций и одиночных — одна клетка).
func furniture_piece(c: Vector2i) -> Array[Vector2i]:
	return Furniture.piece_cells(func(q: Vector2i) -> String:
		return state.grid.cell(q).feature_id if state.grid.in_bounds(q) else "", c)

## Соседняя мебель, которую боец может разломать прямо сейчас (для UI).
func furniture_smash_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null:
		return out
	for n in state.grid.neighbors(actor.coord):
		if can_smash_furniture(actor, n) == "":
			out.append(n)
	return out

## Поднять переносной предмет в руки (как труп или свёрнутую станцию): 1 ОД, руки должны
## быть пусты. Предмет уходит с доски в held_item_id; ставит его на место UseItemIntent.
## Вся переносная мебель — прочности 1 (проверяет run_furniture), так что держать в руках
## нечего, кроме самого id: «поцарапанного» стула, которого надо помнить, не бывает.
func can_carry_furniture(actor: UnitInstance, coord: Vector2i) -> String:
	var err := _validate_actor(actor)
	if err != "":
		return err
	if actor.is_drone or actor.borg_id != -1 or actor.aboard_vehicle_id != -1 or _is_shield(actor):
		return "This unit can't carry furniture"
	if actor.held_item_id != "" or actor.carried_corpses > 0 or held_unit_of(actor) != null:
		return "Hands are full"
	if not state.grid.in_bounds(coord) or Combat.distance(actor.coord, coord) != 1:
		return "Can only pick up from an adjacent cell"
	var cell := state.grid.cell(coord)
	if not Furniture.carriable(cell.feature_id):
		return "Nothing to carry there"
	if cell.occupant != null or cell.vehicle_id != -1:
		return "Someone is standing on it"
	return ""

func _resolve_carry(intent: CarryIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var reason := can_carry_furniture(actor, intent.coord)
	if reason != "":
		return ActionResult.fail(reason)
	var cell := state.grid.cell(intent.coord)
	var fid := cell.feature_id
	actor.remaining_ap -= 1
	actor.held_item_id = fid
	var picked := ActionResult.success(["%s picks up the %s at (%d, %d) [AP: %d]" % [
		actor.stats.display_name, Furniture.name_of(fid).to_lower(), intent.coord.x,
		intent.coord.y, actor.remaining_ap]])
	# Что стояло на предмете, падает; шкаф раскрывается и высыпает вещи (0.12.1).
	_knock_items(picked, intent.coord, actor.coord, false)
	_spill(picked, intent.coord, actor.coord, fid)
	cell.clear_feature()
	return picked

func furniture_carry_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null:
		return out
	for n in state.grid.neighbors(actor.coord):
		if can_carry_furniture(actor, n) == "":
			out.append(n)
	return out

## Поставить несомый предмет на соседнюю пустую клетку — бесплатно, как положить труп.
## Ничего не затирает: клетка обязана быть пустой под постройку (без бойца, объекта и
## высоты); в открытый космос мебель не ставят.
func can_put_down_furniture(actor: UnitInstance, coord: Vector2i) -> String:
	if actor == null or not actor.is_alive():
		return "Unit unavailable"
	if actor.owner != state.active_player():
		return "It's the other player's turn"
	if actor.is_held():
		return "Unit is being held — break free first"
	if not Furniture.is_furniture(actor.held_item_id):
		return "Not carrying furniture"
	if not state.grid.in_bounds(coord) or Combat.distance(actor.coord, coord) != 1:
		return "Put it down in an adjacent cell"
	var cell := state.grid.cell(coord)
	if not cell.is_buildable() or cell.vehicle_id != -1 or cell.corpse_count > 0:
		return "That cell is not free"
	if cell.is_space:
		return "Nothing to set it on in open space"
	return ""

func _put_down_furniture(actor: UnitInstance, coord: Vector2i) -> ActionResult:
	var reason := can_put_down_furniture(actor, coord)
	if reason != "":
		return ActionResult.fail(reason)
	var fid := actor.held_item_id
	actor.held_item_id = ""
	var cell := state.grid.cell(coord)
	cell.set_feature(fid, -1)
	_extinguish_cell(cell)   # поставленный на огонь предмет сбивает пламя, как и всё (#82)
	var put := ActionResult.success(["%s puts the %s down at (%d, %d) [AP: %d]" % [
		actor.stats.display_name, Furniture.name_of(fid).to_lower(), coord.x, coord.y,
		actor.remaining_ap]])
	_knock_items(put, coord, actor.coord, false)   # что лежало на полу, отлетает в сторону
	return put

func furniture_put_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null:
		return out
	for n in state.grid.neighbors(actor.coord):
		if can_put_down_furniture(actor, n) == "":
			out.append(n)
	return out

## Соседние клетки, которые можно сломать (для UI).
func breakable_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	var ability := actor.stats.special_ability_id
	if ability != MCF.ABILITY_MINER and ability != MCF.ABILITY_ENGINEER:
		return out
	for n in state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(n)
		if _is_breakable_fortification(cell):
			out.append(n)
	return out

# --- Огонь (§3.8) ---

## Распространение огня (как в isotope §6.5): раз за ход-сторону каждая горящая
## клетка пытается поджечь 4 ОРТОГОНАЛЬНЫХ соседа (без диагоналей). Порог розжига —
## дерево/трава 3+, прочий пол 4+. Горит почти всё, включая обычные стены; огонь
## НЕ проходит только сквозь пустоту (космос), ЛДФ и ДОТ. Огонь вечен и не гаснет сам.
## Применяется одномоментно (без цепной реакции за тик). Юнит на загоревшейся клетке
## гибнет мгновенно (как от пробития, без спасброска).
## Расползается только огонь, зажжённый стороной owner (#45); owner = -1 — весь огонь.
func advance_fire(owner: int = -1, res: ActionResult = null) -> void:
	var ignite: Dictionary = {}
	# Горящие клетки — из индекса, в том же порядке обхода, что и прежний перебор всей
	# карты: от него зависит порядок бросков. Карта 250×250 — 62 500 клеток на каждую
	# передачу хода, даже когда не горит ничего.
	for c: Vector2i in _burning_cells_of(state.grid):
		var src := state.grid.cell(c)
		if owner != -1 and src.fire_owner != owner:
			continue
		# Каждая горящая клетка бросает розжиг на своих 4 ортогональных соседей.
		for n in _ortho4(c):
			if ignite.has(n):
				continue
			var ncell := state.grid.cell(n)
			if ncell.on_fire or _fire_blocked(ncell):
				continue
			# Клетка под пожаротушительной гранатой (#19): пассивный разлив в неё
			# не идёт. Бросок при этом НЕ делается — иначе заглушённая клетка
			# съедала бы кубики и сдвигала весь дальнейший поток случайности.
			if state.turns.round_number < ncell.fire_suppressed_until:
				continue
			# Живой не-огнеупорный боец рядом с пламенем загорается СРАЗУ, без броска
			# и независимо от того, горюч ли пол под ним (issue #9): огонь перекидывается
			# на человека, а не только на траву. Клетка занимается огнём, apply-цикл
			# ниже убивает бойца тем же путём, что и на любой загоревшейся клетке.
			var occ := ncell.occupant
			if occ != null and occ.is_on_field() and not is_fireproof(occ):
				ignite[n] = src.fire_owner
				continue
			var need := fire_need(ncell)
			if need > 6:
				continue  # не горит никогда — кубик не бросаем
			if state.dice.roll_d6() >= need:
				ignite[n] = src.fire_owner
	for c: Vector2i in ignite:
		var cell := state.grid.cell(c)
		# Новая клетка наследует поджигателя — цепочка остаётся привязана к своей стороне.
		_ignite(cell, ignite[c], res)
		if cell.occupant != null and cell.occupant.is_on_field() and not is_fireproof(cell.occupant):
			var burned := cell.occupant
			# res здесь только ради кровавой косметики — _kill сам в deaths не пишет,
			# это делают вызывающие. Мы пишем в fire_deaths, но НЕ в deaths (см.
			# ActionResult): иначе автор завершённого хода получил бы чужой костёр в зачёт.
			_kill_burnt(burned)  # пожар — крови нет
			if res != null:
				res.fire_deaths.append(burned.id)

## Порог d6, с которого клетка загорается от СОСЕДНЕГО пламени (#14/#31). Шанс
## равен (7 − need)/6; значение больше шести означает «не горит никогда».
## Публичная: тем же вызовом UI подписывает клетку в инспекторе, чтобы подсказка
## не могла разойтись с настоящей таблицей.
##
## Порядок проверок важен. Куча в 2 м спрашивается ПЕРВОЙ, до объекта на клетке:
## сама куча и есть объект (add_dirt ставит FEATURE_DIRT_PILE), и по таблице #14
## она в полный рост горит как стена (2/6), а не как укрытие (3/6) — метровая.
func fire_need(cell: GridCell) -> int:
	if cell.is_tall_dirt():
		return MCF.FIRE_NEED_TALL_DIRT
	if cell.feature_id != "":
		# Furniture burns with the cell. Wood/fabric/plastic catch on 3+, metal on 6.
		if Furniture.is_furniture(cell.feature_id):
			return MCF.FIRE_NEED_WOOD if Furniture.flammable(cell.feature_id) else MCF.FIRE_NEED_METAL
		# Всё, чего в таблице нет, — рядовое укрытие: мешки, ёж, ДПМГ, куча 1 м.
		return int(MCF.FIRE_NEED_BY_FEATURE.get(cell.feature_id, MCF.FIRE_NEED_COVER))
	match cell.floor_type:
		MCF.FLOOR_GRASS:
			return MCF.FIRE_NEED_GRASS
		MCF.FLOOR_FLAMMABLE:
			return MCF.FIRE_NEED_WOOD
	return MCF.FIRE_NEED_FLOOR

## Огонь не может войти/пройти сквозь: пустоту (космос), несгораемую ЛДФ (#84), ДОТ (§6.5).
func _fire_blocked(cell: GridCell) -> bool:
	return cell.is_space or cell.feature_id == MCF.FEATURE_LDF \
			or cell.feature_id == MCF.FEATURE_DOT or cell.feature_id == MCF.FEATURE_DOT_OPEN

## 4 ортогональных соседа в пределах поля (без диагоналей) — для распространения огня.
func _ortho4(coord: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = coord + d
		if state.grid.in_bounds(n):
			out.append(n)
	return out
