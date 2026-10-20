@abstract
extends "res://src/resolver/parts/ResolverMovement.gd"

## Building, digging, breaking and mines: fortifications, trenches, LDF walls, welding,
## minefields and movement budgets around them.

# --- Укрепления: постройка/слом (§3.7) ---

## Что может строить инженер и почём (ОД). Стена/стекло/шлюз/ЛДФ/сетка — 1 действие,
## противотанковый ёж — 2 (§3.7).
## Что получится, если положить new_fid поверх уже стоящего old_fid (#31).
## "" — так укладывать нельзя.
## Во что превратится клетка, если положить new_fid на клетку cell; "" — нельзя.
func stack_onto(cell: GridCell, new_fid: String) -> String:
	if cell.occupant != null or cell.vehicle_id != -1:
		return ""
	return MCF.stacked(cell.feature_id, new_fid)

func _resolve_build(intent: BuildIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit unavailable")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can build fortifications")
	if not ENGINEER_BUILDABLE.has(intent.feature_id):
		return ActionResult.fail("Engineer can't build this object")
	if not state.grid.in_bounds(intent.target) or Combat.distance(actor.coord, intent.target) != 1:
		return ActionResult.fail("Can only build in an adjacent cell")
	var cell := state.grid.cell(intent.target)
	# Класть можно на пустую клетку либо ярусом поверх мешков (#31).
	var stacked := stack_onto(cell, intent.feature_id)
	if not cell.is_buildable() and stacked == "":
		return ActionResult.fail("Cell is occupied")
	var cost: int = ENGINEER_BUILDABLE[intent.feature_id]
	var credit_note := ""
	if actor.borg_id != -1:
		# Инженер в борге (batch 13 B7): 1 ОД покупает BORG_BUILD_BATCH построек ОДНОГО
		# типа, ставить их можно по одной между другими действиями; ДОТ — 1 за ОД.
		# Кредиты сгорают на границе раунда (UnitInstance.reset_ap).
		if MCF.BORG_BATCH_FEATURES.has(intent.feature_id):
			var left: int = int(actor.build_credits.get(intent.feature_id, 0))
			if left > 0:
				actor.build_credits[intent.feature_id] = left - 1
				cost = 0
				credit_note = " (batch, %d left)" % (left - 1)
			else:
				if actor.remaining_ap < 1:
					return ActionResult.fail("Need 1 AP")
				cost = 1
				actor.build_credits[intent.feature_id] = MCF.BORG_BUILD_BATCH - 1
				credit_note = " (batch, %d left)" % (MCF.BORG_BUILD_BATCH - 1)
		elif intent.feature_id == MCF.FEATURE_DOT or intent.feature_id == MCF.FEATURE_DOT_OPEN:
			cost = 1
	if actor.remaining_ap < cost:
		return ActionResult.fail("Need %d AP" % cost)
	actor.remaining_ap -= cost
	var placed: String = stacked if stacked != "" else intent.feature_id
	cell.set_feature(placed, actor.owner)
	notify_cell_changed(intent.target)  # застроенная клетка будит соседей (§3.1a)
	_extinguish_cell(cell)  # стройка на горящей клетке гасит огонь (#82)
	return ActionResult.success(["%s builds: %s at (%d, %d) [AP: %d]%s" % [
		actor.stats.display_name, MCF.feature_name(placed, placed),
		intent.target.x, intent.target.y, actor.remaining_ap, credit_note]])

## Цена постройки для этого инженера (для UI): в борге партия одного типа стоит 1 ОД,
## а пока кредиты партии не кончились — ничего.
func build_cost_for(actor: UnitInstance, feature_id: String) -> int:
	var cost: int = ENGINEER_BUILDABLE.get(feature_id, 1)
	if actor != null and actor.borg_id != -1:
		if MCF.BORG_BATCH_FEATURES.has(feature_id):
			return 0 if int(actor.build_credits.get(feature_id, 0)) > 0 else 1
		if feature_id == MCF.FEATURE_DOT or feature_id == MCF.FEATURE_DOT_OPEN:
			return 1
	return cost

## Клетки соседних шлюзов, которые инженер может заварить (#99) — для подсветки в UI.
func weldable_cells(unit: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if unit == null or not unit.is_alive() \
			or unit.stats.special_ability_id != MCF.ABILITY_ENGINEER \
			or unit.remaining_ap < WELD_AIRLOCK_AP:
		return out
	for c: Vector2i in state.grid.neighbors(unit.coord):
		var cell := state.grid.cell(c)
		if cell != null and cell.feature_id == MCF.FEATURE_AIRLOCK and not cell.airlock_welded \
				and corpses_at(c) == 0:
			out.append(c)
	return out

## Инженер заваривает соседний шлюз за 1 ОД (#99). Заваренный шлюз перестаёт открываться
## от подошедшего юнита и держится как обычная стена — так перекрывают проход в отсек,
## не тратя стройку на новую стену.
func _resolve_weld_airlock(intent: WeldAirlockIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can weld an airlock")
	if not state.grid.in_bounds(intent.to) or Combat.distance(actor.coord, intent.to) != 1:
		return ActionResult.fail("Can only weld an adjacent airlock")
	var cell := state.grid.cell(intent.to)
	if cell.feature_id != MCF.FEATURE_AIRLOCK:
		return ActionResult.fail("There is no airlock there")
	if cell.airlock_welded:
		return ActionResult.fail("This airlock is already welded shut")
	# Створки не сойдутся на теле (batch 13 #4) — сначала вытащить труп из проёма.
	if corpses_at(intent.to) > 0:
		return ActionResult.fail("A body is jamming the doors — drag it out first")
	if actor.remaining_ap < WELD_AIRLOCK_AP:
		return ActionResult.fail("Need %d AP" % WELD_AIRLOCK_AP)
	actor.remaining_ap -= WELD_AIRLOCK_AP
	cell.airlock_welded = true
	# Створки закрываются немедленно, даже если рядом кто-то стоит.
	cell.cover_height = MCF.WALL_HEIGHT
	return ActionResult.success(["%s welds the airlock at (%d, %d) shut [AP: %d]" % [
		actor.stats.display_name, intent.to.x, intent.to.y, actor.remaining_ap]])

## Инженер выкладывает ЛДФ-стену из 6 клеток за 1 ОД (§3.7). Клетки разные, на свободном
## полу, ОДНА обязана соседствовать с инженером, и все шесть обязаны складываться в
## ОРТОГОНАЛЬНО связную цепочку (#80): ЛДФ — секционная конструкция, секции стыкуются
## гранями, а не углами, и разбросать их по карте нельзя.
func _resolve_build_wall(intent: BuildWallIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit unavailable")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can build a LDF wall")
	if actor.ldf_wall_used:
		return ActionResult.fail("This engineer has already used their LDF wall")
	if intent.cells.size() != MCF.LDF_WALL_LENGTH:
		return ActionResult.fail("A LDF wall must be exactly %d tiles" % MCF.LDF_WALL_LENGTH)
	var cost: int = ENGINEER_BUILDABLE[MCF.FEATURE_LDF]
	if actor.remaining_ap < cost:
		return ActionResult.fail("Need %d AP" % cost)

	# Проверка формы: клетки уникальны и свободны; ОДНА соседствует с инженером.
	var seen: Dictionary = {}
	var touches_engineer := false
	for c: Vector2i in intent.cells:
		if not state.grid.in_bounds(c):
			return ActionResult.fail("Wall tile is off the board")
		if seen.has(c):
			return ActionResult.fail("Wall tiles must be distinct")
		seen[c] = true
		if not state.grid.cell(c).is_buildable():
			return ActionResult.fail("A wall tile is on an occupied cell")
		if Combat.distance(actor.coord, c) == 1:
			touches_engineer = true
	if not touches_engineer:
		return ActionResult.fail("At least one wall tile must be next to the engineer")
	if not bru_cells_connected(intent.cells):
		return ActionResult.fail("LDF tiles must form one orthogonally connected chain")

	actor.remaining_ap -= cost
	actor.ldf_wall_used = true
	for c: Vector2i in intent.cells:
		var bru_cell := state.grid.cell(c)
		bru_cell.set_feature(MCF.FEATURE_LDF, actor.owner)
		notify_cell_changed(c)  # секция стены будит соседей (§3.1a)
		_extinguish_cell(bru_cell)  # секция придавливает очаг (#82)
	return ActionResult.success(["%s raises a %d-tile LDF wall [AP: %d]" % [
		actor.stats.display_name, MCF.LDF_WALL_LENGTH, actor.remaining_ap]])

## Образуют ли клетки одну ОРТОГОНАЛЬНО связную фигуру (#80) — секции ЛДФ стыкуются
## гранями, диагональ стыком не считается. Публичная: этим же вызовом UI не даёт
## поставить оторванную секцию, так что подсветка совпадает с проверкой резолвера.
func bru_cells_connected(cells: Array) -> bool:
	if cells.size() <= 1:
		return true
	var want: Dictionary = {}
	for c: Vector2i in cells:
		want[c] = true
	var reached: Dictionary = {cells[0]: true}
	var frontier: Array = [cells[0]]
	while not frontier.is_empty():
		var cur: Vector2i = frontier.pop_back()
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if want.has(n) and not reached.has(n):
				reached[n] = true
				frontier.append(n)
	return reached.size() == want.size()

func _is_breakable_fortification(cell: GridCell) -> bool:
	return BREAKABLE.has(cell.feature_id) or (cell.feature_id == "" and cell.is_wall())

## Есть ли в соседней клетке что-то, что этот боец может снести (для ИИ и подсветки).
func can_break_cell(actor: UnitInstance, coord: Vector2i) -> bool:
	if actor == null or not actor.is_alive():
		return false
	var ability := actor.stats.special_ability_id
	if ability != MCF.ABILITY_MINER and ability != MCF.ABILITY_ENGINEER:
		return false
	if not state.grid.in_bounds(coord) or Combat.distance(actor.coord, coord) != 1:
		return false
	var cell := state.grid.cell(coord)
	return _is_breakable_fortification(cell)

func _resolve_break(intent: BreakIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit unavailable")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if state.grid.in_bounds(intent.target) \
			and Furniture.is_furniture(state.grid.cell(intent.target).feature_id):
		return _resolve_smash_furniture(actor, intent.target)
	var ability := actor.stats.special_ability_id
	if ability != MCF.ABILITY_MINER and ability != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only a miner or engineer can demolish")
	if not state.grid.in_bounds(intent.target) or Combat.distance(actor.coord, intent.target) != 1:
		return ActionResult.fail("Can only demolish in an adjacent cell")
	var cell := state.grid.cell(intent.target)
	if not _is_breakable_fortification(cell):
		return ActionResult.fail("Nothing to demolish")
	if actor.remaining_ap < MCF.BREAK_COST:
		return ActionResult.fail("Need %d AP" % MCF.BREAK_COST)
	actor.remaining_ap -= MCF.BREAK_COST
	var was: String = MCF.feature_name(cell.feature_id, "wall")
	cell.clear_feature()
	cell.corpse_count = 0
	return ActionResult.success(["%s demolishes: %s at (%d, %d) [AP: %d]" % [
		actor.stats.display_name, was, intent.target.x, intent.target.y, actor.remaining_ap]])

# --- Копка окопа (§3.7) ---
# Юнит роет соседнюю клетку в окоп (укрытие выс. 1); вынутая земля — 2 кучи по 0.5 м.
# Упрощение против «1 действие на 3 клетки»: копаем 1 клетку окопа за действие.

func _resolve_dig(intent: DigIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	# Бесплатные окопы текущего ОД копаются и при нулевом ОД (§3.7).
	var err := _validate_actor(actor, actor.dig_credits if actor != null else 0)
	if err != "":
		return ActionResult.fail(err)
	if actor.is_drone:
		return ActionResult.fail("A drone can't dig")
	# Копать можно ПОД собой (дистанция 0) или в соседней клетке (#60).
	if not state.grid.in_bounds(intent.target) or Combat.distance(actor.coord, intent.target) > 1:
		return ActionResult.fail("Can only dig here or in an adjacent cell")
	var cell := state.grid.cell(intent.target)
	# Окоп можно копать ПОД юнитом (#39/#60): занятость клетки не мешает, но
	# нельзя копать сквозь стену/укрепление/уже существующий окоп.
	if cell.feature_id != "" or cell.cover_height != 0.0 or cell.is_wall():
		return ActionResult.fail("Can't dig this cell (something is built here)")
	# В космосе копать нечего: под ногами не грунт, а пустота — ни окопа, ни земли под
	# насыпь. Перечислитель такую клетку и не предлагает (diggable_cells); проверка здесь
	# — для намерений не из UI: сеть, повтор, политика RL.
	if cell.is_space:
		return ActionResult.fail("There is nothing to dig in open space")
	# Куда сложить землю: выбор игрока, если задан и корректен; иначе — авто (§3.7).
	var spots := _dirt_spots(intent.target, actor.coord)
	var picked := _chosen_dirt_spots(intent, spots)
	if picked.size() < 2:
		return ActionResult.fail("Nowhere to put the dug-up %s (no room for 2 piles)" % _spoil_word())

	# За 1 ОД пехота роет 3 окопа, инженер — 6. Первый окоп серии тратит ОД и открывает
	# «кредит», следующие в той же серии бесплатны, пока кредит не исчерпан (§3.7).
	var spent_ap := false
	if actor.dig_credits <= 0:
		if actor.remaining_ap <= 0:
			return ActionResult.fail("No AP left to dig")
		actor.remaining_ap -= 1
		# Борг роет BORG_DIG_TRENCHES (9) за ОД, кто бы в нём ни сидел (batch borg-corpses).
		var per_ap: int = MCF.BORG_DIG_TRENCHES if actor.borg_id != -1 \
				else (DIG_TRENCHES_ENGINEER if actor.stats.special_ability_id == MCF.ABILITY_ENGINEER
				else DIG_TRENCHES_NORMAL)
		actor.dig_credits = per_ap
		spent_ap = true
	actor.dig_credits -= 1

	cell.set_feature(MCF.FEATURE_TRENCH, actor.owner)
	notify_cell_changed(intent.target)  # свежий окоп будит соседей (§3.1a)
	# Копка снимает горящий верхний слой — окоп гасит огонь на своей клетке, а
	# вынутая земля засыпает очаги там, куда её сложили (#82).
	_extinguish_cell(cell)
	state.grid.cell(picked[0]).add_dirt(actor.owner)
	state.grid.cell(picked[1]).add_dirt(actor.owner)
	_extinguish_cell(state.grid.cell(picked[0]))
	_extinguish_cell(state.grid.cell(picked[1]))
	var tail := "[AP: %d, %d trench(es) left this AP]" % [actor.remaining_ap, actor.dig_credits] if not spent_ap \
		else "[AP: %d, %d more trench(es) free this AP]" % [actor.remaining_ap, actor.dig_credits]
	return ActionResult.success(["%s dug a trench at (%d, %d), %s at (%d,%d) and (%d,%d) %s" % [
		actor.stats.display_name, intent.target.x, intent.target.y, _spoil_word(),
		picked[0].x, picked[0].y, picked[1].x, picked[1].y, tail]])

## Проверить/выбрать 2 клетки под землю: сначала берём корректный выбор игрока,
## затем добираем автоматически из доступных мест (§3.7). Пара может совпадать —
## тогда на одну клетку ложатся оба уровня (растёт куча), поэтому считаем не клетки,
## а свободную ЁМКОСТЬ: пустая клетка держит DIRT_MAX_LEVEL загрузок (#51).
func _chosen_dirt_spots(intent: DigIntent, spots: Array) -> Array:
	var picked: Array = []
	var room := {}  # клетка -> сколько ещё уровней земли туда влезет
	for s in spots:
		room[s] = _dirt_capacity(s)
	for pick in [intent.dirt_a, intent.dirt_b]:
		if picked.size() >= 2:
			break
		if pick != Vector2i(-999, -999) and int(room.get(pick, 0)) > 0:
			picked.append(pick)
			room[pick] = int(room[pick]) - 1
	# Первый проход раскладывает по одной куче на клетку (растим равномерно),
	# второй — досыпает второй уровень, если свободная клетка осталась одна.
	for _pass in 2:
		for s in spots:
			if picked.size() >= 2:
				break
			if int(room[s]) > 0:
				picked.append(s)
				room[s] = int(room[s]) - 1
	return picked

## Сколько загрузок земли ещё примет клетка (0, если не принимает вовсе).
func _dirt_capacity(coord: Vector2i) -> int:
	var cell := state.grid.cell(coord)
	if cell == null or not cell.accepts_dirt():
		return 0
	return MCF.DIRT_MAX_LEVEL - cell.dirt_level

## Клетки под вынутую землю: соседи окопа (кроме копающего), пустые ИЛИ недосыпанные кучи.
# --- Мины (item 45) ---------------------------------------------------------
## Куда сапёр может поставить мину: под собой или в соседней клетке, на голый пол.
## Мина не даёт укрытия и не мешает проходу — она на то и мина, чтобы на неё
## наступили, — поэтому единственное требование к клетке в том, что на ней нет
## ничего другого.
func mine_cells(actor: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if actor == null or not _is_sapper(actor) or actor.aboard_vehicle_id != -1:
		return out
	var here := actor.coord
	for c in [here] + state.grid.neighbors(here):
		if _can_mine_cell(c):
			out.append(c)
	return out

func _is_sapper(u: UnitInstance) -> bool:
	return u != null and u.stats.special_ability_id == MCF.ABILITY_SAPPER

## Клетки с чужой ПОДСВЕЧЕННОЙ миной рядом с сапёром — их он может обезвредить (item 13).
func disarmable_mine_cells(actor: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if actor == null or not _is_sapper(actor) or actor.aboard_vehicle_id != -1:
		return out
	for c in [actor.coord] + state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(c)
		if cell == null:
			continue
		if cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE:
			continue
		if state.roster.are_allies(actor.owner, cell.feature_owner):
			continue
		if mine_visible_to(actor.owner, c):
			out.append(c)
	return out

func _can_mine_cell(coord: Vector2i) -> bool:
	if not state.grid.in_bounds(coord):
		return false
	var c := state.grid.cell(coord)
	return not c.is_space and not c.has_feature() and c.cover_height == 0.0 \
			and c.dirt_level == 0 and c.vehicle_id == -1

func _resolve_place_mine(intent: PlaceMineIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	# Мины из открытого кредита ставятся и при нулевом ОД — как окопы серии (§3.7).
	var err := _validate_actor(actor, actor.mine_credits if actor != null else 0)
	if err != "":
		return ActionResult.fail(err)
	if not _is_sapper(actor):
		return ActionResult.fail("Only a minesweeper can lay mines")
	if Combat.distance(actor.coord, intent.target) > 1:
		return ActionResult.fail("Can only mine this cell or an adjacent one")
	if not _can_mine_cell(intent.target):
		return ActionResult.fail("Can't lay a mine here")
	var spent_ap := false
	if actor.mine_credits <= 0:
		if actor.remaining_ap <= 0:
			return ActionResult.fail("No AP left to lay mines")
		actor.remaining_ap -= 1
		actor.mine_credits = MCF.MINES_PER_ACTION
		spent_ap = true
	actor.mine_credits -= 1
	var mine_feature: String = MCF.FEATURE_AV_MINE if intent.anti_vehicle else MCF.FEATURE_MINE
	var target_cell := state.grid.cell(intent.target)
	target_cell.set_feature(mine_feature, actor.owner)
	var kind_word := "an anti-vehicle mine" if intent.anti_vehicle else "a mine"
	var tail := "[AP: %d, %d mine(s) left to lay]" % [actor.remaining_ap, actor.mine_credits]
	var res := ActionResult.success(["%s laid %s at (%d, %d) %s" % [
		actor.stats.display_name, kind_word, intent.target.x, intent.target.y, tail]])
	# Противопехотная мина, заложенная ПОД стоящим бойцом — своим, чужим или самим
	# сапёром, — рвётся сразу (batch 12 #7): взрыватель взводится под ногой. Бросков
	# нет, это верная смерть; мина расходуется. Противотанковая под пехотой молчит —
	# ей нужен вес гусеницы.
	var under: UnitInstance = target_cell.occupant
	if not intent.anti_vehicle and under != null and under.is_alive():
		target_cell.clear_feature()
		notify_cell_changed(intent.target)
		_fx(res, {"fx": "debris", "at": intent.target, "cells": [intent.target]})
		_kill(under, res, intent.target)
		res.deaths.append(under.id)
		res.log("The mine goes off under %s's feet — killed instantly!" % under.stats.display_name)
	return res

## Сапёр обезвреживает подсвеченную его стороной чужую мину на соседней клетке (item 13).
func _resolve_disarm_mine(intent: DisarmMineIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if not _is_sapper(actor):
		return ActionResult.fail("Only a minesweeper can disarm mines")
	if actor.remaining_ap <= 0:
		return ActionResult.fail("No AP left")
	if Combat.distance(actor.coord, intent.target) > 1:
		return ActionResult.fail("Must be next to the mine")
	var cell := state.grid.cell(intent.target)
	if cell == null or (cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE):
		return ActionResult.fail("No mine there")
	if state.roster.are_allies(actor.owner, cell.feature_owner):
		return ActionResult.fail("That's a friendly mine")
	# Обезвредить можно лишь то, что уже нашли зачисткой: слепой сапёр чужого поля не видит.
	if not mine_visible_to(actor.owner, intent.target):
		return ActionResult.fail("Sweep for it first — you can't see that mine")
	actor.remaining_ap -= 1
	var was_av := cell.feature_id == MCF.FEATURE_AV_MINE
	cell.clear_feature()
	# Знание о снятой мине больше не нужно — чистим отметку, чтобы подсветка не висела.
	var seen: Dictionary = state.revealed_mines.get(actor.owner, {})
	seen.erase(intent.target)
	notify_cell_changed(intent.target)
	return ActionResult.success(["%s disarms %s at (%d, %d) [AP: %d]" % [
		actor.stats.display_name, "an anti-vehicle mine" if was_av else "a mine",
		intent.target.x, intent.target.y, actor.remaining_ap]])

## Подсветить чужие мины вокруг (item 45). Знание кладётся ПЕРСОНАЛЬНО той стороне,
## что его добыла: подсветка — не свойство мины, а то, что о ней узнали.
func _resolve_reveal_mines(intent: RevealMinesIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if not _is_sapper(actor):
		return ActionResult.fail("Only a minesweeper can sweep for mines")
	if actor.remaining_ap <= 0:
		return ActionResult.fail("No AP left")
	actor.remaining_ap -= 1
	var until: int = state.turns.round_number + MCF.MINE_REVEAL_TURNS
	var seen: Dictionary = state.revealed_mines.get(actor.owner, {})
	var found := 0
	var r := MCF.MINE_REVEAL_RADIUS
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := actor.coord + Vector2i(dx, dy)
			if not state.grid.in_bounds(c):
				continue
			var cell := state.grid.cell(c)
			if cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE:
				continue
			if state.roster.are_allies(actor.owner, cell.feature_owner):
				continue  # свои мины сапёр и так знает
			if _vision_blocked(actor.coord, c, actor.owner):
				continue
			seen[c] = until
			found += 1
	state.revealed_mines[actor.owner] = seen
	return ActionResult.success(["%s swept for mines: %d found within %d tiles [AP: %d]" % [
		actor.stats.display_name, found, r, actor.remaining_ap]])

## Подрыв мины под наступившим (item 45).
##
## Эффекта мины в источнике нет вовсе — описана только сама способность её ставить.
## Принято самое скромное толкование, какое согласуется с остальной моделью урона:
## поражается РОВНО клетка мины (никакого поля осколков), пехота на ней гибнет по
## общим правилам взрыва, техника теряет единицу прочности по единой шкале (#89),
## а сама мина расходуется. Записано в GAME_SPEC §7.9 как принятое допущение.
func _detonate_mine(coord: Vector2i, victim: UnitInstance, res: ActionResult) -> void:
	var cell := state.grid.cell(coord)
	var owner_name := MCF.owner_name(cell.feature_owner)
	var old := cell.feature_owner == OLD_MINE_OWNER
	cell.clear_feature()
	if old:
		res.log("An old mine goes off at (%d, %d)!" % [coord.x, coord.y])
		if victim != null:
			res.dice_events.append({"kind": "check", "actor": "Old mine", "roll": _old_mine_roll,
				"need": OLD_MINE_GOES_OFF, "ok": true, "roller": victim.owner})
	else:
		res.log("A mine laid by %s goes off at (%d, %d)!" % [owner_name, coord.x, coord.y])
	# Через общий _blast: щитоносец, прикрытие союзником и снос объектов на клетке
	# должны работать здесь ровно так же, как у противотанкиста, а не «почти так же».
	var area: Array[Vector2i] = [coord]
	# Клетка мины оседает ОБЫЧНЫМ разрушенным полом, а не выжженным эпицентром (item 13).
	var killed := _blast(coord, res, area, false)
	_damage_vehicles_in_area(area, coord, MCF.MINE_VEHICLE_DAMAGE, -1, res, "mine")
	if killed.is_empty():
		# victim == null — подрыв не под ногами (огонь дошёл): некому «уйти».
		if victim != null:
			res.log("… %s walked away from it." % victim.stats.display_name)
	else:
		for n in killed:
			res.log("%s killed by the mine!" % n)

## Противопехотные мины, о которых сторона ЗНАЕТ (batch 12 #3/#4): свои и союзные всегда,
## чужие — пока держится подсветка зачистки. Словарь coord → true в порядке обхода
## сетки, чтобы Movement мог класть его в ключ кеша. Маршруты этой стороны обходят
## эти клетки; противотанковые мины сюда не входят — пехоте они не страшны.
func known_mine_cells(owner: int) -> Dictionary:
	var out: Dictionary = {}
	for coord: Vector2i in _feature_cells(MCF.FEATURE_MINE):
		if mine_visible_to(owner, coord):
			out[coord] = true
	return out

## Разлив движения для бойца с обходом известных ему мин (batch 12 #4). Все, кто
## считает ход пехоты — резолвер, интерфейс, ИИ, — обязаны идти через эту функцию,
## иначе подсветка и проверка приказа разойдутся.
## Бюджет движения — ровно тот, что спишет _resolve_move (batch 17, item 2): кредит
## прошлого хода тратится ПЕРВЫМ (§3.2); с грузом потолок −3 клетки, даже на кредите.
## Экран и групповой приказ обязаны считать по нему же, иначе подсветка врёт.
func move_budget(unit: UnitInstance) -> int:
	var burdened := held_unit_of(unit) != null \
			or dragged_cell_of(unit) != UnitInstance.NOT_DRAGGING
	var carry_budget := maxi(0, unit.speed() - MCF.CAPTURE_CARRY_PENALTY)
	var budget := unit.move_credit if unit.move_credit > 0 \
			else (carry_budget if burdened else unit.speed())
	return mini(budget, carry_budget) if burdened else budget

## Бюджет СВЕЖЕГО движения за 1 ОД, без остатка прошлого (для зон 2-го и 3-го ОД).
func move_budget_fresh(unit: UnitInstance) -> int:
	var burdened := held_unit_of(unit) != null \
			or dragged_cell_of(unit) != UnitInstance.NOT_DRAGGING
	return maxi(0, unit.speed() - MCF.CAPTURE_CARRY_PENALTY) if burdened else unit.speed()

## Потолки хода за 1, 2 и 3 ОД (зелёная, оранжевая, красная зоны): [i] — сколько клеток
## пройдёт боец, потратив ещё i ОД сверх первого (на кредите первый ОД не нужен). Цена
## клетки от бюджета не зависит, поэтому один разлив по последнему потолку даёт все три
## зоны. Волочение ОД не стоит, ему дальних зон нет. Экран и _resolve_move считают по ней.
func move_tier_budgets(unit: UnitInstance) -> Array[int]:
	var budget := move_budget(unit)
	var out: Array[int] = [budget]
	if dragged_cell_of(unit) != UnitInstance.NOT_DRAGGING:
		return out
	var extra_ap := unit.remaining_ap - (0 if unit.move_credit > 0 else 1)
	var step := move_budget_fresh(unit)
	for k in range(1, mini(extra_ap, 2) + 1):
		if step <= 0:
			break
		out.append(budget + step * k)
	return out

func can_move(unit: UnitInstance) -> bool:
	return unit != null and unit.is_alive() and unit.aboard_vehicle_id == -1 \
			and not unit.is_held() and state.grid.in_bounds(unit.coord) and (unit.remaining_ap > 0 or unit.move_credit > 0)

## Достижимая клетка, ближайшая к dest (при равенстве — дешевле по ходу); `taken` —
## клетки, уже разобранные другими юнитами группы. Своя клетка, если идти некуда.
func nearest_reachable(u: UnitInstance, dest: Vector2i, taken: Dictionary = {}) -> Vector2i:
	var reach_r := reachable_for(u, move_budget(u))
	var best := u.coord
	var best_d := Combat.distance(u.coord, dest)
	var best_cost := 0
	for c: Vector2i in reach_r.cost:
		if taken.has(c):
			continue
		var d: int = Combat.distance(c, dest)
		var cost: int = reach_r.cost[c]
		if d < best_d or (d == best_d and cost < best_cost):
			best_d = d
			best_cost = cost
			best = c
	return best

## blocked / vacated — план группового приказа (GroupMovePlanner): клетки, куда уже
## встали товарищи, и клетки, с которых они к этому моменту ушли.
func reachable_for(unit: UnitInstance, budget: int, blocked: Dictionary = {},
		vacated: Dictionary = {}) -> Movement.Reachability:
	var avoid := known_mine_cells(unit.owner)
	# Борг в окоп не съезжает (batch 13 B11): окопы для него — не клетки.
	if unit.borg_id != -1 or not blocked.is_empty():
		var merged: Dictionary = avoid.duplicate()
		if unit.borg_id != -1:
			for c: Vector2i in _trench_cells():
				merged[c] = true
		merged.merge(blocked)
		avoid = merged
	return Movement.reachable(state.grid, unit.coord, budget, not is_fireproof(unit), avoid, vacated)

func _trench_cells() -> Array:
	return _feature_cells(MCF.FEATURE_TRENCH)

static func _burning_cells_of(grid: Grid) -> Array:
	_feature_sync(grid)
	return _burning

func _feature_cells(fid: String) -> Array:
	return _feature_cells_of(state.grid, fid)

static func _feature_cells_of(grid: Grid, fid: String) -> Array:
	_feature_sync(grid)
	return _feature_index.get(fid, [])

static func _feature_sync(grid: Grid) -> void:
	var gid := grid.get_instance_id()
	if gid != _feature_grid or _feature_look < GridCell.look_log_base:
		# Правка — и у тех объектов, что исчезли с карты совсем: их списки тоже сменились.
		for fid: String in _feature_index:
			_feature_rev[fid] = int(_feature_rev.get(fid, 0)) + 1
		_feature_index = {}
		_feature_at = {}
		_burning = []
		for c: GridCell in grid.cells_flat():
			if c.feature_id != "":
				if not _feature_index.has(c.feature_id):
					_feature_index[c.feature_id] = []
				_feature_index[c.feature_id].append(c.coord)
				_feature_at[c.coord] = c.feature_id
			if c.on_fire:
				_burning.append(c.coord)
		for fid: String in _feature_index:
			_feature_rev[fid] = int(_feature_rev.get(fid, 0)) + 1
		_feature_grid = gid
		_feature_look = GridCell.look_version
		return
	if _feature_look == GridCell.look_version:
		return
	var ch := GridCell.look_changes
	var i: int = (_feature_look - GridCell.look_log_base) * 2
	while i < ch.size():
		var at := Vector2i(ch[i], ch[i + 1])
		i += 2
		if not grid.in_bounds(at):
			continue
		var cell := grid.cell(at)
		var fk := _burning.bsearch_custom(at, _grid_order)
		var listed: bool = fk < _burning.size() and _burning[fk] == at
		if cell.on_fire and not listed:
			_burning.insert(fk, at)
		elif listed and not cell.on_fire:
			_burning.remove_at(fk)
		var now := cell.feature_id
		var was: String = _feature_at.get(at, "")
		if now == was:
			continue
		if was != "":
			var list: Array = _feature_index[was]
			var k := list.bsearch_custom(at, _grid_order)
			if k < list.size() and list[k] == at:
				list.remove_at(k)
			_feature_rev[was] = int(_feature_rev.get(was, 0)) + 1
			_feature_at.erase(at)
		if now != "":
			if not _feature_index.has(now):
				_feature_index[now] = []
			var list2: Array = _feature_index[now]
			list2.insert(list2.bsearch_custom(at, _grid_order), at)
			_feature_rev[now] = int(_feature_rev.get(now, 0)) + 1
			_feature_at[at] = now
	_feature_look = GridCell.look_version

static func _grid_order(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y or (a.y == b.y and a.x < b.x)

## Видит ли сторона эту мину. Своя мина видна всегда; чужая — пока держится подсветка.
func mine_visible_to(owner: int, coord: Vector2i) -> bool:
	var cell := state.grid.cell(coord)
	if cell == null or (cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE):
		return false
	if state.roster.are_allies(owner, cell.feature_owner):
		return true
	var seen: Dictionary = state.revealed_mines.get(owner, {})
	return int(seen.get(coord, -1)) >= state.turns.round_number

## Первая горящая клетка на пройденном маршруте (#1). Огнеупорные бойцы (#2) сквозь
## пламя проходят невредимыми, и для них ответ всегда NOWHERE.
func _hazards_on_arrival(unit: UnitInstance, res: ActionResult) -> void:
	if unit != null and unit.is_alive() and state.grid.in_bounds(unit.coord) \
			and state.grid.cell(unit.coord).on_fire and not is_fireproof(unit):
		unit.burnt = true
		_kill(unit, res)
		res.deaths.append(unit.id)
		res.log("%s burned to death on leaving the vehicle!" % unit.stats.display_name)
		return
	_gas_on_arrival(unit, res)

func _fire_on_path(unit: UnitInstance, path: Array) -> Vector2i:
	if is_fireproof(unit):
		return NOWHERE
	for step: Vector2i in path:
		var cell := state.grid.cell(step)
		if cell != null and cell.on_fire:
			return step
	return NOWHERE

## Первая чужая мина на пройденном маршруте. Мина срабатывает под ногой, а не в
## точке назначения: минное поле на то и поле, что его пересекают.
## path приходит из Reachability.path_to(), а он отдаёт только ВОЙДЕННЫЕ клетки —
## исходной в нём нет, поэтому отдельно её исключать не нужно.
func _mine_on_path(unit: UnitInstance, path: Array) -> Vector2i:
	for step: Vector2i in path:
		var cell := state.grid.cell(step)
		# Обычная противопехотная мина рвётся под ЛЮБЫМ пехотинцем — своим или чужим
		# (item 13). Раньше на свои мины не наступали; теперь наступивший гибнет, чей бы
		# ни была мина, поэтому владельцу приходится обходить своё же поле. Противотанковая
		# мина (FEATURE_AV_MINE) пехоту не трогает — под ней сюда просто не попадёт.
		if cell == null or cell.feature_id != MCF.FEATURE_MINE:
			continue
		# Старая мина (событие Old Minefield, 0.12) срабатывает не всегда. Не сработала —
		# ни строки в журнале: о том, что она здесь, никто не узнаёт.
		if cell.feature_owner == OLD_MINE_OWNER:
			_old_mine_roll = state.dice.roll_d6()
			if _old_mine_roll < OLD_MINE_GOES_OFF:
				continue
		return step
	return NOWHERE

func _dirt_spots(trench: Vector2i, digger: Vector2i) -> Array:
	var out: Array = []
	for n in state.grid.neighbors(trench):
		if n == digger:
			continue
		if state.grid.cell(n).accepts_dirt():
			out.append(n)
	return out

## Суммарная ёмкость под вынутую землю вокруг окопа (нужно 2 загрузки).
func _dirt_room(trench: Vector2i, digger: Vector2i) -> int:
	var total := 0
	for s in _dirt_spots(trench, digger):
		total += _dirt_capacity(s)
		if total >= 2:
			return total
	return total

## Можно ли копать окоп рядом (для UI): нет укрепления/стены + место под 2 загрузки земли.
## Оккупант клетки не мешает — окоп роется и под чужим бойцом (#43), как в _resolve_dig.
## Считаем ёмкость, а не число клеток: одна пустая соседняя клетка держит обе кучи (#51).
func diggable_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor.is_drone:
		return out
	var candidates: Array[Vector2i] = [actor.coord]
	candidates.append_array(state.grid.neighbors(actor.coord))
	for c in candidates:
		var cell := state.grid.cell(c)
		if cell.feature_id == "" and cell.cover_height == 0.0 and not cell.is_wall() \
				and not cell.is_space and _dirt_room(c, actor.coord) >= 2:
			out.append(c)
	return out

## Клетки под насыпь вокруг выбранного окопа (для UI выбора игроком).
func dirt_spots_for(trench: Vector2i, digger: Vector2i) -> Array:
	return _dirt_spots(trench, digger)

## Соседние клетки, где инженер может строить (для UI).
## feature_id задан — добавляем и клетки, куда его можно уложить ярусом поверх мешков (#31).
func buildable_cells(actor: UnitInstance, feature_id: String = "") -> Array:
	var out: Array = []
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return out
	for n in state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(n)
		if cell.is_buildable() or (feature_id != "" and stack_onto(cell, feature_id) != ""):
			out.append(n)
	return out
