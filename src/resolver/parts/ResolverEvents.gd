@abstract
extends "res://src/resolver/parts/ResolverVehicles.gd"

## Random events and match modes: barrages, gas, raiders, fire, EMP, collapses,
## reinforcements, minefields, Capture & Hold zones, Holdout waves and bounties.

## Случайный индекс 0..n−1 ШИРОКИМ броском: пять d6 дают 7776 значений, и на любой
## стороне карты (до 270 клеток) перекос остатка — меньше процента. Обычный _rand_index
## берёт три кубика (216 значений) и для размеров карты уже не годится.
func _rand_wide(n: int) -> int:
	if n <= 1:
		return 0
	var v := 0
	for _i in 5:
		v = v * 6 + (state.dice.roll_d6() - 1)
	return v % n

## Announce only at match opening or the beginning of a new round.
## Interval/probability and all event parameters use the shared dice stream.
func _maybe_random_event(res: ActionResult) -> void:
	if random_events == null or not random_events.enabled:
		return
	if random_events.last_checked_round >= state.turns.round_number:
		return
	random_events.last_checked_round = state.turns.round_number
	var id := random_events.roll_event(state.dice, _events_allowed)
	if id == "":
		return
	# Мгновенные события (0.12): мины уже лежат, метка уже стоит — объявлять нечего.
	if id == RandomEvents.MINEFIELD:
		_start_minefield(res)
		return
	if id == RandomEvents.BOUNTY:
		_start_bounty(res)
		return
	var params := _roll_event_params(id)
	if params.is_empty():
		return
	random_events.announce(id, params, state.turns.round_number)
	res.log("⚠ %s — %s, landing at the end of this round" % [
		RandomEvents.event_name(id), _event_where(id, params)])

## Полезный участок карты — рамка по всем клеткам, которые НЕ космос и не голая земля
## за краем застройки (item 6). Событиям незачем падать в пустоту: на станции край карты —
## это вакуум, и газ там травил только самого себя. Считается по доске, без кубиков,
## значит у хоста и клиента совпадает.
## ponytail: проход по всей сетке, зато всегда верен; событий за партию единицы.
func _useful_rect() -> Rect2i:
	var grid := state.grid
	var lo := Vector2i(grid.width, grid.height)
	var hi := Vector2i(-1, -1)
	for y in grid.height:
		for x in grid.width:
			var c := grid.cell_fast(x, y)
			if c.is_space or not c.walkable_terrain():
				continue
			lo.x = mini(lo.x, x)
			lo.y = mini(lo.y, y)
			hi.x = maxi(hi.x, x)
			hi.y = maxi(hi.y, y)
	if hi.x < lo.x:
		return Rect2i(0, 0, grid.width, grid.height)   # проходимого нет вовсе — вся карта
	return Rect2i(lo, hi - lo + Vector2i.ONE)

## Зона w×h внутри полезного участка: угол катается по рамке, а не по всей карте.
func _zone_in(area: Rect2i, w: int, h: int) -> Dictionary:
	var zw := mini(w, area.size.x)
	var zh := mini(h, area.size.y)
	return {"x": area.position.x + _rand_wide(area.size.x - zw + 1),
			"y": area.position.y + _rand_wide(area.size.y - zh + 1), "w": zw, "h": zh}

## Центр самого плотного скопления бойцов — куда и ляжет наводящийся обстрел. Плотность
## меряется в окне того же размера, что и зона огня. Vector2i(-1,-1) — мерить нечего.
## ponytail: O(n²) по бойцам (их десятки), хватает с запасом; сетка-хеш — если не хватит.
func _densest_spot(w: int, h: int) -> Vector2i:
	var pts: Array[Vector2i] = []
	for u: UnitInstance in state.all_units():
		# Спящие жители (общий слот мирных) — не цель (issues-12 #9): батарея наводится
		# на бойцов и на ПРОСНУВШИЕСЯ группы, а не на мирный квартал, где никто не воюет.
		if u.is_alive() and not u.is_drone and u.owner != MCF.Owner.NEUTRAL \
				and state.grid.in_bounds(u.coord):
			pts.append(u.coord)
	if pts.is_empty():
		return Vector2i(-1, -1)
	var best := pts[0]
	var best_n := -1
	for p: Vector2i in pts:
		var n := 0
		for q: Vector2i in pts:
			if absi(q.x - p.x) * 2 <= w and absi(q.y - p.y) * 2 <= h:
				n += 1
		if n > best_n:
			best_n = n
			best = p
	return best

## Параметры события — катаются ОДИН раз, при объявлении, и дальше не меняются.
func _roll_event_params(id: String) -> Dictionary:
	var gw := state.grid.width
	var gh := state.grid.height
	var area := _useful_rect()
	match id:
		RandomEvents.MORTAR:
			var bw := BARRAGE_SIDE_MIN + _rand_wide(mini(BARRAGE_SIDE_MAX, gw) - BARRAGE_SIDE_MIN + 1)
			var bh := BARRAGE_SIDE_MIN + _rand_wide(mini(BARRAGE_SIDE_MAX, gh) - BARRAGE_SIDE_MIN + 1)
			bw = mini(bw, gw)
			bh = mini(bh, gh)
			# Батарея чаще бьёт по скоплению, чем в чистое поле (item 6), но не всегда:
			# предсказуемый обстрел перестал бы быть событием. Бросок — из общего потока.
			var seek := state.dice.roll_d6() <= BARRAGE_SEEK_ON
			var aim := _densest_spot(bw, bh) if seek else Vector2i(-1, -1)
			if aim.x < 0:
				return _free_barrage_zone(_zone_in(area, bw, bh), area)
			return _free_barrage_zone({"x": clampi(aim.x - bw / 2, area.position.x, maxi(area.position.x, area.end.x - bw)),
					"y": clampi(aim.y - bh / 2, area.position.y, maxi(area.position.y, area.end.y - bh)), "w": mini(bw, area.size.x), "h": mini(bh, area.size.y)}, area)
		RandomEvents.GAS:
			var side_w := clampi(gw / 3, GAS_SIDE_MIN, GAS_SIDE_MAX)
			var side_h := clampi(gh / 3, GAS_SIDE_MIN, GAS_SIDE_MAX)
			var cw := mini(gw, GAS_SIDE_MIN + _rand_wide(maxi(1, side_w - GAS_SIDE_MIN + 1)))
			var ch := mini(gh, GAS_SIDE_MIN + _rand_wide(maxi(1, side_h - GAS_SIDE_MIN + 1)))
			var z := _zone_in(area, cw, ch)
			z["rounds"] = GAS_ROUNDS
			return z
		RandomEvents.ARMY:
			var edge := _rand_wide(4)                      # 0 С, 1 В, 2 Ю, 3 З
			var along := gw if edge % 2 == 0 else gh
			var seg := mini(along, ARMY_SEGMENT_MIN + _rand_wide(ARMY_SEGMENT_MAX - ARMY_SEGMENT_MIN + 1))
			var army := {"edge": edge, "from": _rand_wide(along - seg + 1), "len": seg}
			# Announce where it will really land: a stretch of bare vacuum slides to ground.
			var band := _army_band(edge, int(army["from"]), seg)
			if not band.is_empty():
				army = {"edge": band[0], "from": band[1], "len": band[2]}
			# В бункере за краем — толща грунта (issues-12 #13): армия входит в САМ бункер,
			# с конца коридора, ближайшего к объявленному участку края.
			if state.env == "bunker":
				var entry := _hallway_entry(army)
				if entry.x >= 0:
					army["hx"] = entry.x
					army["hy"] = entry.y
			return army
		RandomEvents.FIRE:
			var spots := _burnable_cells(area)
			if spots.is_empty():
				return {}
			return _rect_around(spots[_rand_wide(spots.size())], FIRE_SIDE)
		RandomEvents.EMP:
			var targets := _emp_targets()
			if targets.is_empty():
				return {}
			return _rect_around(targets[_rand_wide(targets.size())], EMP_SIDE)
		RandomEvents.DUST:
			return {"rounds": DUST_ROUNDS}
		RandomEvents.COLLAPSE:
			var walls := _collapse_walls()
			if walls.is_empty():
				return {}
			return _rect_around(walls[_rand_wide(walls.size())], COLLAPSE_SIDE)
		RandomEvents.REINFORCE:
			return _reinforce_target()
	return {}

## Keep simultaneous warnings distinct. Stable nearest-fit search uses no extra dice.
func _free_barrage_zone(preferred: Dictionary, area: Rect2i) -> Dictionary:
	var occupied: Array[Rect2i] = []
	if random_events != null:
		for e: Dictionary in random_events.pending:
			if e["id"] == RandomEvents.MORTAR:
				var p: Dictionary = e["params"]
				occupied.append(Rect2i(int(p["x"]), int(p["y"]), int(p["w"]), int(p["h"])))
	var size := Vector2i(int(preferred["w"]), int(preferred["h"]))
	var wanted := Vector2i(int(preferred["x"]), int(preferred["y"]))
	var best := Vector2i(-1, -1)
	var score := INF
	for y in range(area.position.y, area.end.y - size.y + 1):
		for x in range(area.position.x, area.end.x - size.x + 1):
			var at := Vector2i(x, y)
			var distance := at.distance_squared_to(wanted)
			if distance >= score: continue
			var free := true
			for other: Rect2i in occupied:
				if other.intersects(Rect2i(at, size)):
					free = false
					break
			if free:
				best = at
				score = distance
	if best.x < 0: return {}
	return {"x": best.x, "y": best.y, "w": size.x, "h": size.y}

## Где именно — строкой для журнала и подсказки на карте.
func _event_where(id: String, p: Dictionary) -> String:
	if id == RandomEvents.DUST:
		return "across the whole battlefield"
	if id == RandomEvents.REINFORCE:
		var names_r := ["north", "east", "south", "west"]
		var whom := state.roster.name_of(int(p.get("side", -1)))
		if p.has("hx"):
			return "%s's reinforcements entering the hallway at (%d, %d)" % [whom, int(p["hx"]), int(p["hy"])]
		return "%s's reinforcements approaching from the %s edge" % [whom, names_r[int(p.get("edge", 0)) % 4]]
	if id == RandomEvents.ARMY:
		if p.has("hx"):
			return "unknown forces tunneling into the hallway at (%d, %d)" % [int(p["hx"]), int(p["hy"])]
		var names := ["north", "east", "south", "west"]
		return "unknown forces approaching from the %s edge" % names[int(p.get("edge", 0)) % 4]
	return "zone (%d, %d) %d×%d" % [int(p.get("x", 0)), int(p.get("y", 0)),
			int(p.get("w", 0)), int(p.get("h", 0))]

## Resolve pending warnings at the next player end-turn, before AP refresh.
##
## Порядок: сперва травит стоящий газ (он был на доске весь этот раунд), потом падает
## объявленное — в порядке очереди. Порядок фиксирован, значит одинаков у хоста и клиента.
func land_random_events(res: ActionResult) -> void:
	if random_events == null:
		return
	_gas_tick(res)
	# Дым дымовых гранат стоит до конца следующего раунда (0.12).
	if not random_events.smoke.is_empty():
		random_events.age_smoke()
	# Пожар события своего хода не имеет — он расползается раз в раунд, здесь (0.12).
	advance_fire(EVENT_FIRE_OWNER, res)
	if random_events.dust_left > 0:
		random_events.dust_left -= 1
		if random_events.dust_left == 0:
			res.log("The dust storm blows over")
	for e: Dictionary in random_events.take_landing(state.turns.round_number):
		var p: Dictionary = e["params"]
		match str(e["id"]):
			RandomEvents.MORTAR:
				_land_barrage(p, res)
			RandomEvents.GAS:
				_land_gas(p, res)
			RandomEvents.ARMY:
				_land_army(p, res)
			RandomEvents.FIRE:
				_land_fire(p, res)
			RandomEvents.EMP:
				_land_emp(p, res)
			RandomEvents.DUST:
				random_events.dust_left = int(p.get("rounds", DUST_ROUNDS))
				res.log("A dust storm sweeps the battlefield: for %d rounds every shot beyond %d cells needs one more" % [
						random_events.dust_left, DUST_CLEAR])
			RandomEvents.COLLAPSE:
				_land_collapse(p, res)
			RandomEvents.REINFORCE:
				_land_reinforce(p, res)
	_sync_gas()

## Обстрел: зона делится на столбцы по клетке, столбцы идут с запада на восток, клетки в
## столбце — с севера на юг. По клетке один d6: 1–3 мимо, 4–6 разрушена. Столбец за
## столбцом — то же самое, что независимые 1/2 на клетку, зато порядок бросков (и порядок
## разрывов на экране) задан жёстко.
func _land_barrage(p: Dictionary, res: ActionResult) -> void:
	var x0 := int(p.get("x", 0))
	var y0 := int(p.get("y", 0))
	var bw := int(p.get("w", 0))
	var bh := int(p.get("h", 0))
	var hit: Array[Vector2i] = []
	var killed: Array[String] = []
	for x in range(x0, x0 + bw):
		for y in range(y0, y0 + bh):
			if state.dice.roll_d6() < BARRAGE_HIT_MIN:
				continue
			var c := Vector2i(x, y)
			if not state.grid.in_bounds(c):
				continue
			hit.append(c)
			killed.append_array(_destroy_cell(c, res))
	if not hit.is_empty():
		# Один пакет косметики на весь обстрел, а не событие на клетку: клетки в нём идут
		# в том же порядке, в каком разрешались, — экран так и показывает разрывы.
		_fx(res, {"fx": "debris", "at": NOWHERE, "cells": hit, "blast": true})
	var tail := "" if killed.is_empty() else " — " + ", ".join(killed) + " killed"
	res.log("Artillery Barrage hits zone (%d, %d) %d×%d: %d of %d cells destroyed%s" % [
		x0, y0, bw, bh, hit.size(), bw * bh, tail])

## Разрушить ОДНУ клетку (обстрел). Не взрыв: ни осколочного поля, ни радиуса — что было
## на клетке, то и снесло, а кто на ней стоял, тот погиб (решение по открытому вопросу
## спеки: разрушенная клетка с живым бойцом на ней читалась бы странно). Снос рельефа —
## тем же кодом, что у взрыва (_blast_destroy_terrain), чтобы правила были одни.
func _destroy_cell(c: Vector2i, res: ActionResult) -> Array[String]:
	var names: Array[String] = []
	var cell := state.grid.cell(c)
	if cell == null:
		return names
	var occ := cell.occupant
	if occ != null and occ.is_on_field() and not _blast_shield(occ):
		_kill(occ, res, c, true)
		names.append(occ.stats.display_name)
		if res != null:
			res.deaths.append(occ.id)
	# Машина под разрывом теряет корпус — ту же единицу прочности, что от заряда ПТ.
	var veh := vehicle_covering(c)
	if veh != null and veh.alive():
		_damage_component(veh, MCF.COMP_HULL, MCF.ANTI_TANK_VEHICLE_DAMAGE, "barrage", res)
	_blast_destroy_terrain(c, res, c)
	notify_cell_changed(c)
	return names

## Gas arriving on a soldier causes immediate exposure, then persists for round ticks.
func _land_gas(p: Dictionary, res: ActionResult) -> void:
	var cl := random_events.add_cloud(int(p.get("x", 0)), int(p.get("y", 0)),
			int(p.get("w", 0)), int(p.get("h", 0)), int(p.get("rounds", GAS_ROUNDS)))
	res.log("Gas Cloud settles over zone (%d, %d) %d×%d for %d round(s)" % [
		int(cl["x"]), int(cl["y"]), int(cl["w"]), int(cl["h"]), int(cl["left"])])

	_sync_gas()
	var area := Rect2i(int(cl["x"]), int(cl["y"]), int(cl["w"]), int(cl["h"]))
	var ids := state.units.keys()
	ids.sort()
	for id: int in ids:
		var u := state.get_unit(id)
		if area.has_point(u.coord) and state.grid.cell(u.coord).gas:
			_gas_survival(u, res)

## Газ травит и выдыхается: по бойцу один d6 в порядке id (лок-степ), 1–2 — смерть.
## Техника и те, кто внутри неё, газом не берутся: корпус герметичен.
func _gas_tick(res: ActionResult) -> void:
	if random_events.clouds.is_empty():
		return
	var ids: Array = []
	for u: UnitInstance in state.all_units():
		if u.is_on_field() and u.aboard_vehicle_id == -1 and u.borg_id == -1 \
				and state.grid.cell(u.coord) != null and state.grid.cell(u.coord).can_hold_gas() \
				and random_events.cloud_at(u.coord):
			ids.append(u.id)
	ids.sort()
	for id: int in ids:
		var u := state.get_unit(id)
		if u == null or not u.is_on_field():
			continue
		_gas_survival(u, res)
	random_events.age_clouds()


func _gas_survival(u: UnitInstance, res: ActionResult) -> void:
	if not u.is_on_field() or u.aboard_vehicle_id != -1 or u.borg_id != -1:
		return
	var roll := state.dice.roll_d6()
	res.dice_events.append({"kind": "check", "actor": u.stats.display_name,
		"roll": roll, "need": GAS_SURVIVE_MIN, "ok": roll >= GAS_SURVIVE_MIN,
		"roller": u.owner})
	if roll >= GAS_SURVIVE_MIN:
		res.log("%s holds their breath in the gas (roll %d)" % [u.stats.display_name, roll])
		return
	_kill(u, res, u.coord)
	res.deaths.append(u.id)
	res.log("%s chokes in the gas (roll %d, needed %d+)" % [
		u.stats.display_name, roll, GAS_SURVIVE_MIN])

## Клетки облаков — на доску (и снять те, где газа больше нет). Проход по всей сетке: он
## случается от силы несколько раз за партию, зато всегда верен — и после загрузки, и
## после отката хода, когда списка «что было отмечено» уже нет.
func _sync_gas() -> void:
	if random_events == null:
		return
	# Only a cell inside a cloud, or one clouded right now (_sight_gas lists every cell with gas
	# or smoke on this board), can change; the rest stay clear. The whole-board pass cost
	# ~150 ms per round on 274×274 even with no cloud anywhere. Row order, as that pass had.
	_sync_seen()
	var grid := state.grid
	var gw := grid.width
	var check := _sight_gas.duplicate()
	for cl: Dictionary in random_events.clouds + random_events.smoke:
		for y in range(maxi(0, int(cl["y"])), mini(grid.height, int(cl["y"]) + int(cl["h"]))):
			for x in range(maxi(0, int(cl["x"])), mini(gw, int(cl["x"]) + int(cl["w"]))):
				check[y * gw + x] = true
	var cells := check.keys()
	cells.sort()
	for i: int in cells:
		var cell := grid.cell_fast(i % gw, i / gw)
		cell.gas = cell.can_hold_gas() and random_events.cloud_at(Vector2i(i % gw, i / gw))
		cell.smoke = cell.can_hold_gas() and random_events.smoke_at(Vector2i(i % gw, i / gw))

## Независимая армия (0.9.4): у края карты высаживается ничья сила, враждебная всем.
## Сила — по средней армии ЖИВЫХ игроков (по цене закупки); слот встаёт в случайное место
## очереди инициативы, и ходит армия сама — её ход ведёт резолвер, как ход жителей.
func _independent_roster() -> Array:
	var pool := _weighted_raider_roster()
	if random_events != null:
		pool = pool.filter(func(id: String) -> bool: return not random_events.excluded_units.has(id))
	return pool

func _weighted_raider_roster() -> Array:
	var level := random_events.army_difficulty if random_events != null else 1
	if level == 0:
		return ["light_infantry", "light_infantry", "light_infantry", "light_infantry",
				"heavy_infantry", "heavy_infantry", "heavy_infantry", "heavy_infantry",
				"light_infantry", "heavy_infantry",
				"machinegunner", "anti_tank", "sapper"]
	if level == 2:
		return ["light_infantry", "heavy_infantry", "anti_tank", "anti_tank", "anti_tank",
				"anti_tank", "sniper", "marksman", "flamethrower", "shield_bearer",
				"engineer", "miner", "sapper", "machinegunner"]
	return ARMY_ROSTER

func _land_army(p: Dictionary, res: ActionResult) -> void:
	var budget := _army_budget()
	var slot := MCF.independent_slot(random_events.armies + 1)
	if not MCF.is_independent(slot):
		return
	# Больше ARMY_MAX армий на карту не приходит (0.9.4): событие может выпасть и десять
	# раз подряд, а десять ничьих сторон в очереди — это уже не «событие», а другая игра.
	# Выпавшее сверх потолка событие просто проходит мимо, как и прежние «ничего».
	var alive := 0
	for s_id: int in state.turns.round_order:
		if MCF.is_independent(s_id) and _army_holds_field(s_id):
			alive += 1
	if alive >= ARMY_MAX:
		res.log("Unknown forces hold off — the field is crowded enough")
		return
	var spots := _army_spawn_cells(p)
	if spots.is_empty():
		res.log("Unknown forces turn back — nowhere to land on that edge")
		return
	var roster := _independent_roster()
	if roster.is_empty():
		res.log("Unknown forces hold off — all raider unit types are restricted")
		return
	var spent := 0
	var placed := 0
	var guard := 0
	while guard < ARMY_UNIT_CAP and placed < spots.size():
		guard += 1
		var sid: String = roster[_rand_wide(roster.size())]
		var stats: UnitStats = _army_stats(sid)
		if stats == null:
			continue
		if budget > 0 and spent + stats.cost > budget and placed > 0:
			break
		if budget <= 0 and placed >= ARMY_FALLBACK_UNITS:
			break
		var raider := state.spawn_unit(stats, spots[placed], slot)
		if raider == null:
			break
		raider.neutral_group = random_events.armies + 1
		spent += stats.cost
		placed += 1
	if placed == 0:
		res.log("Unknown forces turn back — nowhere to land on that edge")
		return
	random_events.armies += 1
	# Слот — в СЛУЧАЙНОЕ место очереди. События падают в конце раунда, активный слот уже
	# обошёл круг, поэтому вставка не может ни пропустить, ни повторить чей-то ход.
	var at := _rand_wide(state.turns.round_order.size() + 1)
	state.turns.insert_slot(slot, at)
	var names := ["north", "east", "south", "west"]
	if p.has("hx"):
		res.log("— %s break into the hallway at (%d, %d): %d fighters, hostile to everyone —" % [
			MCF.owner_name(slot), int(p["hx"]), int(p["hy"]), placed])
	else:
		res.log("— %s land on the %s edge: %d fighters, hostile to everyone —" % [
			MCF.owner_name(slot), names[int(p.get("edge", 0)) % 4], placed])
	notify_cell_changed(spots[0])

## Does this raider army still hold the field (it crowds a new one out)? Only while it is
## a force: at least five fighters and three in ten of those it landed with. A handful of
## stragglers kept every later army away (owner, fix-8 #11: "raiders just don't spawn").
func _army_holds_field(slot: int) -> bool:
	var alive := 0
	for u: UnitInstance in state.all_units():
		if u.owner == slot and u.is_alive() and not u.is_drone:
			alive += 1
	var fallen := int(state.deaths.get(slot, state.deaths.get(str(slot), 0)))
	return alive >= maxi(5, ceili((alive + fallen) * 0.3))

func _army_stats(id: String) -> UnitStats:
	if _army_stats_cache.has(id):
		return _army_stats_cache[id]
	var path := "res://src/data/units/%s.tres" % id
	var st: UnitStats = load(path) if ResourceLoader.exists(path) else null
	_army_stats_cache[id] = st
	return st

## Средняя армия живого игрока в очках закупки — по ней и мерится независимая.
## Независимые армии в среднее не входят. Нечего мерить — ноль, и армия приходит
## фиксированной (ARMY_FALLBACK_UNITS бойцов).
func _army_budget() -> int:
	var cost := {}
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or not MCF.is_player(u.owner):
			continue
		cost[u.owner] = int(cost.get(u.owner, 0)) + u.stats.cost
	if cost.is_empty():
		return 0
	var total := 0
	for own: int in cost:
		total += int(cost[own])
	return roundi(float(total) / float(cost.size()) * ARMY_STRENGTH)

## Свободные клетки участка края, на который высаживается армия: сперва по самому краю,
## потом глубже внутрь карты. Порядок строгий — он же порядок расстановки.
## A stretch of edge with nothing but vacuum or wall across the whole map (a station's
## margin) used to turn the army back (owner, fix-8 #11): the landing slides along the edge
## to the nearest stretch with ground, then tries the other edges.
func _army_spawn_cells(p: Dictionary) -> Array[Vector2i]:
	if p.has("hx"):
		return _hallway_spawn_cells(Vector2i(int(p["hx"]), int(p["hy"])))
	var found: Array = _army_band(int(p.get("edge", 0)) % 4, int(p.get("from", 0)), maxi(1, int(p.get("len", ARMY_SEGMENT_MIN))))
	return found[3] if not found.is_empty() else ([] as Array[Vector2i])

## The nearest stretch of edge an army can land on: [edge, from, len, cells], or [] when the
## whole map has nowhere.
func _army_band(edge: int, from: int, seg: int) -> Array:
	for e in 4:
		var ed := (edge + e) % 4
		var along := state.grid.width if ed % 2 == 0 else state.grid.height
		var start := from if e == 0 else (along - seg) / 2
		for k in range(0, along / seg + 2):
			for sgn: int in ([1] if k == 0 else [1, -1]):
				var f := start + sgn * k * seg
				if f < 0 or f > along - 1:
					continue
				var cells := _army_band_cells(ed, f, mini(seg, along - f))
				if not cells.is_empty():
					return [ed, f, mini(seg, along - f), cells]
	return []

func _army_band_cells(edge: int, from: int, seg: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var gw := state.grid.width
	var gh := state.grid.height
	# Идём вглубь, пока не наберём, на что высаживаться (item 6). Прежде вглубь смотрели
	# ровно на длину участка — и на станции, где у края один вакуум, а жилое начинается
	# клеток через двадцать, армия не находила НИ ОДНОЙ клетки и всегда «поворачивала
	# назад». Отсюда и «армии не приходят, особенно на космических картах».
	var depth := gh if edge % 2 == 0 else gw
	for d in depth:
		if out.size() >= ARMY_UNIT_CAP:
			break
		for k in seg:
			var c: Vector2i
			match edge:
				0: c = Vector2i(from + k, d)
				1: c = Vector2i(gw - 1 - d, from + k)
				2: c = Vector2i(from + k, gh - 1 - d)
				_: c = Vector2i(d, from + k)
			if not state.grid.in_bounds(c):
				continue
			# Never into fire (playtest 2026-10-19): the search goes on to the cells beyond.
			if state.grid.blocks_walk(c) or state.grid.cell(c).is_space or state.grid.cell(c).on_fire:
				continue
			out.append(c)
	return out

## Клетка, по которой можно пройти и на которой можно стоять: не стена, не вакуум.
func _open_floor(c: Vector2i) -> bool:
	var cell := state.grid.cell(c)
	return cell != null and cell.walkable_terrain() and not cell.is_space
func hallway_ends() -> Array[Vector2i]:
	var w := state.grid.width
	var h := state.grid.height
	var open := PackedByteArray()   # 0 — не пройти, 1 — пол, 2 — дверь
	open.resize(w * h)
	var i := 0
	for cell: GridCell in state.grid.cells_flat():
		if cell.walkable_terrain() and not cell.is_space:
			open[i] = 2 if cell.feature_id == MCF.FEATURE_AIRLOCK else 1
		i += 1
	var at := func(x: int, y: int) -> int:
		return open[y * w + x] if x >= 0 and y >= 0 and x < w and y < h else 0
	# Ширина прохода через (x, y) поперёк направления d, до 4.
	var across := func(x: int, y: int, d: Vector2i) -> int:
		var n := 1
		for s: Vector2i in [Vector2i(d.y, d.x), Vector2i(-d.y, -d.x)]:
			var q := Vector2i(x, y) + s
			while n <= 4 and at.call(q.x, q.y) == 1:
				n += 1
				q += s
		return n
	var out: Array[Vector2i] = []
	for y in h:
		for x in w:
			if open[y * w + x] == 0:
				continue
			for d: Vector2i in Grid.N4:
				if at.call(x + d.x, y + d.y) != 0 or across.call(x, y, d) > 3:
					continue
				var run := true
				for k in range(1, HALL_MIN_RUN + 1):
					var bx := x - d.x * k
					var by := y - d.y * k
					if at.call(bx, by) == 0 or across.call(bx, by, d) > 3:
						run = false
						break
				if run:
					out.append(Vector2i(x, y))
					break
	return out

## Конец коридора, ближайший к середине объявленного участка края; (-1,-1) — коридоров нет.
## ponytail: полный обход доски на объявление события (их за партию единицы).
func _hallway_entry(p: Dictionary) -> Vector2i:
	var gw := state.grid.width
	var gh := state.grid.height
	var mid := int(p.get("from", 0)) + int(p.get("len", 1)) / 2
	var anchor: Vector2i
	match int(p.get("edge", 0)) % 4:
		0: anchor = Vector2i(mid, 0)
		1: anchor = Vector2i(gw - 1, mid)
		2: anchor = Vector2i(mid, gh - 1)
		_: anchor = Vector2i(0, mid)
	var best := Vector2i(-1, -1)
	var best_d := -1
	for c: Vector2i in hallway_ends():
		var dd := c.distance_squared_to(anchor)
		if best_d < 0 or dd < best_d:
			best = c
			best_d = dd
	return best

## Куда встают бойцы, вошедшие с конца коридора: разлив от него по проходимому полу —
## сперва сам коридор, дальше вглубь. Занятые клетки разлив проходит, но не берёт.
func _hallway_spawn_cells(entry: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not _open_floor(entry):
		return out
	var seen := {entry: true}
	var queue: Array[Vector2i] = [entry]
	var i := 0
	while i < queue.size() and out.size() < ARMY_UNIT_CAP:
		var c := queue[i]
		i += 1
		var cell := state.grid.cell(c)
		if cell.occupant == null and cell.vehicle_id == -1 and not cell.blocks_move() and not cell.on_fire:
			out.append(c)
		for d: Vector2i in Grid.N4:
			var n := c + d
			if not seen.has(n) and _open_floor(n):
				seen[n] = true
				queue.append(n)
	return out

## Gas obscures aim even for weapons that can penetrate solid cover. Include
## both endpoints and support arbitrary sight directions without allocating a ray.
func gas_blocks_line(a: Vector2i, b: Vector2i) -> bool:
	if GridCell.obscurants() <= 0 or a == b or _line_off_board(a, b):
		return false
	var dx := absi(b.x - a.x)
	var dy := absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx - dy
	var c := a
	while true:
		if state.grid.cell_fast(c.x, c.y).obscured():
			return true
		if c == b:
			return false
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			c.x += sx
		if e2 < dx:
			err += dx
			c.y += sy
	return false

## Отказ по застилающему линию облаку — с правильным названием (0.12): дым дымовой гранаты
## или газ. Сама проверка — gas_blocks_line; здесь только слово для журнала.
func obscured_line_reason(a: Vector2i, b: Vector2i) -> String:
	var dx := absi(b.x - a.x)
	var dy := absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx - dy
	var c := a
	var smoke := false
	while true:
		if state.grid.in_bounds(c):
			var cell := state.grid.cell_fast(c.x, c.y)
			if cell.gas:
				return "Gas blocks line of sight"
			smoke = smoke or cell.smoke
		if c == b:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			c.x += sx
		if e2 < dx:
			err += dx
			c.y += sy
	return "Smoke blocks line of sight" if smoke else "Gas blocks line of sight"

# =====================================================================================
#  Режимы партии (0.12): Capture & Hold и Holdout
# =====================================================================================
## Всё, что меняет доску, идёт здесь через общий поток кубиков (лок-степ): зоны считаются
## из карты чистой функцией, волны катаются теми же кубиками, что и независимая армия.

## Подготовить режим к партии: зоны и счёт (Capture & Hold), сторона волн и мерило их силы
## (Holdout). map — карта партии; без неё (демо, тесты) зоны встают по центру.
func prepare_mode(map: MapData) -> void:
	mode.scores = {}
	mode.holders = []
	mode.bounty_unit = -1
	if mode.is_capture():
		var sides: Array = []
		for side: int in state.roster.player_ids():
			sides.append(side)
			mode.scores[MatchMode.team_key(state.roster, side)] = 0
		var drawn := MatchMode.drawn_zones(state.grid.width, state.grid.height)
		if not drawn.is_empty():
			mode.zones = drawn   # нарисованы хостом в лобби (0.12.1)
		elif map != null:
			mode.zones = MatchMode.zones_for(map, mode.zone_count, sides, state.grid)
		else:
			var m := MapData.new(state.grid.width, state.grid.height)
			mode.zones = MatchMode._fallback_zones(m, mode.zone_count)
		for i in mode.zones.size():
			mode.holders.append("")
	elif mode.is_holdout():
		if mode.wave_side < 0:
			mode.wave_side = state.roster.waves_side()
		mode.wave = 0
		mode.wave_spawned = 0
		mode.pending_wave = {}
		mode.next_wave_round = state.turns.round_number
		var value := 0
		var defenders := {}
		for u: UnitInstance in state.all_units():
			if u.is_alive() and not u.is_drone and MCF.is_player(u.owner) and u.owner != mode.wave_side:
				value += u.stats.cost
				defenders[u.owner] = true
		# Средняя армия на игрока (fix-7 #17): волна меряется по ней, а не по сумме.
		mode.defender_value = roundi(float(value) / float(maxi(1, defenders.size())))

## Живые бойцы волн Holdout (дроны не в счёт).
func wave_fighters_left() -> int:
	var n := 0
	for u: UnitInstance in state.all_units():
		if u.owner == mode.wave_side and u.is_alive() and not u.is_drone:
			n += 1
	return n

## Сколько волн Holdout отбито: пришедшие, кроме той, что ещё на поле.
func waves_beaten() -> int:
	return maxi(0, mode.wave - (1 if wave_fighters_left() > 0 else 0))

## Есть ли у стороны армия: живой боец (в машине тоже), дроны — не армия.
func side_has_army(side: int) -> bool:
	for u: UnitInstance in state.all_units():
		if u.owner == side and u.is_alive() and not u.is_drone:
			return true
	return false

## Исход партии по правилам режима: {"over": bool, "winner": ключ команды ("" — ничья
## или нет исхода), "reason": "rout" | "points" | "held" | "overrun" | "draw"}.
func match_outcome() -> Dictionary:
	var alive := {}
	for side: int in state.roster.player_ids():
		if state.turns.is_eliminated(side) or not side_has_army(side):
			continue
		alive[MatchMode.team_key(state.roster, side)] = true
	if mode.is_holdout() and mode.wave_side >= 0:
		var waves := MatchMode.team_key(state.roster, mode.wave_side)
		var defenders := ""
		for k: String in alive:
			if k != waves:
				defenders = k
				break
		if defenders == "":
			return {"over": true, "winner": waves, "reason": "overrun"}
		if not mode.endless() and mode.wave >= mode.waves_total and mode.pending_wave.is_empty() \
				and not alive.has(waves):
			return {"over": true, "winner": defenders, "reason": "held"}
		return {"over": false, "winner": "", "reason": ""}
	if mode.is_capture():
		var best := ""
		var best_pts := -1
		var tie := false
		for k: String in mode.scores:
			var pts := int(mode.scores[k])
			if pts < mode.target:
				continue
			if pts > best_pts:
				best = k
				best_pts = pts
				tie = false
			elif pts == best_pts:
				tie = true
		if best != "" and not tie:
			return {"over": true, "winner": best, "reason": "points"}
	if alive.size() >= 2:
		return {"over": false, "winner": "", "reason": ""}
	if alive.is_empty():
		return {"over": true, "winner": "", "reason": "draw"}
	return {"over": true, "winner": alive.keys()[0], "reason": "rout"}

## Сколько бойцов каждой команды стоит в зоне i ПРЯМО СЕЙЧАС: ключ команды → число.
## Боец в зоне — живой, не дрон, не пленник; машина с живым экипажем, чей корпус задевает
## зону, — ещё один (экипаж танка вынесен за карту и сам по себе не считается).
func zone_counts(i: int) -> Dictionary:
	var out := {}
	var rect := mode.zone_rect(i)
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or u.is_held() or not MCF.is_player(u.owner):
			continue
		if not state.grid.in_bounds(u.coord) or not rect.has_point(u.coord):
			continue
		var k := MatchMode.team_key(state.roster, u.owner)
		out[k] = int(out.get(k, 0)) + 1
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or veh.living_crew_count() <= 0 or not MCF.is_player(veh.owner):
			continue
		for fc: Vector2i in veh.footprint():
			if rect.has_point(fc):
				var vk := MatchMode.team_key(state.roster, veh.owner)
				out[vk] = int(out.get(vk, 0)) + 1
				break
	return out

## Кто держит зону по числу бойцов: ключ команды или "" (никого / поровну).
static func zone_holder(counts: Dictionary) -> String:
	var best := ""
	var best_n := 0
	var tie := false
	for k: String in counts:
		var n := int(counts[k])
		if n > best_n:
			best = k
			best_n = n
			tie = false
		elif n == best_n and n > 0:
			tie = true
	return "" if tie else best

func _mode_round_end(res: ActionResult) -> void:
	if mode.is_capture():
		_score_zones(res)
		if mode.bounty_unit >= 0 and state.turns.round_number >= mode.bounty_until:
			mode.bounty_unit = -1
			res.log("The bounty expires unclaimed")
	elif mode.is_holdout() and not mode.pending_wave.is_empty():
		_land_wave(res)

func _mode_round_start(res: ActionResult) -> void:
	if mode.is_holdout():
		_maybe_announce_wave(res)

## Конец раунда в Capture & Hold: каждая удержанная зона — очко её команде.
func _score_zones(res: ActionResult) -> void:
	var parts: Array[String] = []
	for i in mode.zones.size():
		var holder := zone_holder(zone_counts(i))
		while mode.holders.size() <= i:
			mode.holders.append("")
		mode.holders[i] = holder
		if holder == "":
			parts.append("%s contested" % mode.zone_name(i) if not zone_counts(i).is_empty()
					else "%s empty" % mode.zone_name(i))
			continue
		mode.scores[holder] = int(mode.scores.get(holder, 0)) + 1
		parts.append("%s → %s" % [mode.zone_name(i), team_label(holder)])
	var board: Array[String] = []
	for k: String in mode.scores:
		board.append("%s %d" % [team_label(k), int(mode.scores[k])])
	res.log("Round %d score: %s. Points: %s (to %d)" % [state.turns.round_number,
			", ".join(parts), ", ".join(board), mode.target])

## Подпись команды по ключу: имя стороны, а у команды из нескольких — «Team 2 (A, B)».
func team_label(key: String) -> String:
	var sides := team_sides(key)
	if sides.size() == 1:
		return state.roster.name_of(sides[0])
	var names: Array[String] = []
	for s: int in sides:
		names.append(state.roster.name_of(s))
	return "Team %d (%s)" % [int(key.substr(1)) + 1, ", ".join(names)]

## Стороны команды по ключу (MatchMode.team_key).
func team_sides(key: String) -> Array[int]:
	var out: Array[int] = []
	for side: int in state.roster.player_ids():
		if MatchMode.team_key(state.roster, side) == key:
			out.append(side)
	return out

## Начало раунда в Holdout: пора — объявить следующую волну (где высадится — сразу,
## приходит в конце раунда, как и независимая армия: у защитников ровно один ход).
func _maybe_announce_wave(res: ActionResult) -> void:
	if _waves_remain() and state.turns.round_number >= mode.next_wave_round:
		_announce_wave(res)

## Будет ли ещё волна, и не объявлена ли она уже.
func _waves_remain() -> bool:
	return mode.wave_side >= 0 and mode.pending_wave.is_empty() \
			and (mode.endless() or mode.wave < mode.waves_total)

## Последний боец волны пал — следующая объявляется сейчас же и приходит в конце этого
## раунда (волны идут раз в два раунда ИЛИ сразу за выбитой — что раньше). true — объявили.
func _maybe_wave_cleared(res: ActionResult) -> bool:
	if not mode.is_holdout() or mode.wave <= 0 or not _waves_remain() or wave_fighters_left() > 0:
		return false
	_announce_wave(res)
	return not mode.pending_wave.is_empty()

func _announce_wave(res: ActionResult) -> void:
	var p := _roll_wave_params()
	if p.is_empty():
		return
	mode.pending_wave = p
	var k := mode.wave + 1
	var label := "Wave %d" % k if mode.endless() else "Wave %d of %d" % [k, mode.waves_total]
	if not mode.endless() and k == mode.waves_total:
		label += " (final)"
	res.log("⚠ %s — %s, landing at the end of this round" % [label, _event_where(RandomEvents.ARMY, p)])

## Участок высадки армии или волны в клетках: полоса глубиной 2 у края, а в бункере —
## квадрат 3×3 у конца коридора. Его рисует бой и видит обучаемая политика.
func army_landing_rect(p: Dictionary) -> Rect2i:
	if p.has("hx"):
		return Rect2i(int(p["hx"]) - 1, int(p["hy"]) - 1, 3, 3)
	var seg := int(p.get("len", 1))
	var from := int(p.get("from", 0))
	var gw := state.grid.width
	var gh := state.grid.height
	match int(p.get("edge", 0)) % 4:
		0: return Rect2i(from, 0, seg, 2)
		1: return Rect2i(gw - 2, from, 2, seg)
		2: return Rect2i(from, gh - 2, seg, 2)
	return Rect2i(0, from, 2, seg)
func _roll_wave_params() -> Dictionary:
	var defenders: Array[Vector2i] = []
	for u: UnitInstance in state.all_units():
		if u.is_alive() and MCF.is_player(u.owner) and u.owner != mode.wave_side \
				and state.grid.in_bounds(u.coord):
			defenders.append(u.coord)
	var best := {}
	var best_d := -1
	for _k in WAVE_EDGE_ROLLS:
		var p := _roll_event_params(RandomEvents.ARMY)
		if p.is_empty():
			continue
		var spots := _army_spawn_cells(p)
		if spots.is_empty():
			continue
		var d := 1 << 20
		for c: Vector2i in defenders:
			d = mini(d, Combat.distance(c, spots[0]))
		if d > best_d:
			best_d = d
			best = p
	return best

## Высадка объявленной волны: та же раскладка по краю (или из конца коридора в бункере),
## что у независимой армии, но за сторону волн и по нарастающему бюджету.
func _land_wave(res: ActionResult) -> void:
	var p := mode.pending_wave
	mode.pending_wave = {}
	var k := mode.wave + 1
	var spots := _army_spawn_cells(p)
	var placed := _spawn_budget(spots, mode.wave_budget(k), mode.wave_side, mode.excluded_units, k)
	mode.wave = k
	mode.wave_spawned += placed
	mode.wave_sizes[str(k)] = placed
	# Слот волн обязан стоять в очереди: лобби ставит его туда с начала боя, а тем, кто
	# собирает ростер позже (среда RL, инструменты), — место в конце круга.
	state.turns.insert_slot(mode.wave_side, state.turns.round_order.size())
	# Each wave plays its own turn at a random place in the initiative, like a raider army
	# (2026-10-18 owner request). Its soldiers stay on the waves side.
	state.turns.wave_owner = mode.wave_side
	var ws := MCF.wave_slot(k)
	if placed > 0 and ws >= 0:
		state.turns.insert_slot(ws, _rand_wide(state.turns.round_order.size() + 1))
	mode.next_wave_round = state.turns.round_number + mode.wave_every
	var label := "Wave %d" % k if mode.endless() else "Wave %d of %d" % [k, mode.waves_total]
	if placed == 0:
		res.log("%s finds nowhere to land" % label)
		return
	res.log("— %s lands: %d fighters —" % [label, placed])
	notify_cell_changed(spots[0])

## Нужный бросок с поправкой на пыльную бурю. Все выстрелы резолвера считаются через неё.
func hit_need(dist: int, fire_range: float) -> int:
	return _dusty(Combat.hit_number(dist, fire_range), dist)

func sniper_need(dist: int) -> int:
	return _dusty(Combat.sniper_hit_number(dist), dist)

func _dusty(need: int, dist: int) -> int:
	if random_events != null and random_events.dust_left > 0 and dist > DUST_CLEAR:
		return mini(7, need + 1)
	return need

## Какие события возможны здесь и сейчас: карта (буря — город и поле, мины — астероид,
## город и поле), режим (награда — только Capture & Hold) и сама доска (есть стены, есть
## отстающая сторона, есть где лечь минам).
func _events_allowed() -> Dictionary:
	var ok := {RandomEvents.MORTAR: true, RandomEvents.GAS: true, RandomEvents.ARMY: true}
	if not _emp_targets().is_empty():
		ok[RandomEvents.EMP] = true
	if not _burnable_cells(_useful_rect()).is_empty():
		ok[RandomEvents.FIRE] = true
	if RandomEvents.available_for_map(RandomEvents.DUST, state.env, mode.kind) and random_events.dust_left <= 0:
		ok[RandomEvents.DUST] = true
	if not _collapse_walls().is_empty():
		ok[RandomEvents.COLLAPSE] = true
	if not _reinforce_target().is_empty():
		ok[RandomEvents.REINFORCE] = true
	if mode.is_capture() and mode.bounty_unit < 0 and _bounty_pick() != null:
		ok[RandomEvents.BOUNTY] = true
	if RandomEvents.available_for_map(RandomEvents.MINEFIELD, state.env, mode.kind) and not _minefield_cells().is_empty():
		ok[RandomEvents.MINEFIELD] = true
	return ok

## Куда бьёт ЭМИ (владелец, 0.12: «по технике»): в центр машины — сперва машины с живым
## экипажем, иначе любые уцелевшие; техники нет — в дроны и станции дронов. Пусто — ЭМИ
## бить не во что, и событие не выпадает. Порядок — по id и по строкам: у пиров одинаков.
func _emp_targets() -> Array[Vector2i]:
	var crewed: Array[Vector2i] = []
	var empty: Array[Vector2i] = []
	var ids: Array = state.vehicles.keys()
	ids.sort()
	for vid: int in ids:
		var veh: Vehicle = state.vehicles[vid]
		if not veh.alive():
			continue
		if veh.living_crew_count() > 0:
			crewed.append(veh.center())
		else:
			empty.append(veh.center())
	if not crewed.is_empty():
		return crewed
	if not empty.is_empty():
		return empty
	var gear: Array[Vector2i] = []
	for u: UnitInstance in state.all_units():
		if u.is_alive() and u.is_drone and state.grid.in_bounds(u.coord):
			gear.append(u.coord)
	gear.append_array(_feature_cells(MCF.FEATURE_DRONE_STATION))
	return gear

## Квадрат side×side вокруг клетки, прижатый к карте.
func _rect_around(c: Vector2i, side: int) -> Dictionary:
	var gw := state.grid.width
	var gh := state.grid.height
	var w := mini(side, gw)
	var h := mini(side, gh)
	return {"x": clampi(c.x - side / 2, 0, gw - w), "y": clampi(c.y - side / 2, 0, gh - h), "w": w, "h": h}

## Клетки участка, которые могут заняться огнём (порядок — по строкам).
func _burnable_cells(area: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var cell := state.grid.cell_fast(x, y)
			if not cell.is_space and not cell.on_fire and cell.walkable_terrain() \
					and not _fire_blocked(cell) and fire_need(cell) <= 6:
				out.append(Vector2i(x, y))
	return out

## Стены построек, у которых хоть с одной стороны пол, — что может рухнуть.
func _collapse_walls() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in state.grid.height:
		for x in state.grid.width:
			var cell := state.grid.cell_fast(x, y)
			if not COLLAPSIBLE.has(cell.feature_id):
				continue
			for n: Vector2i in _ortho4(Vector2i(x, y)):
				var nc := state.grid.cell(n)
				if nc != null and not nc.is_space and nc.walkable_terrain():
					out.append(Vector2i(x, y))
					break
	return out

## Пожар: в зоне загорается всё, что может гореть; кто стоял там — сгорает (объявлено за
## раунд). Дальше огонь расползается раз в раунд, как любой другой.
func _land_fire(p: Dictionary, res: ActionResult) -> void:
	var rect := Rect2i(int(p.get("x", 0)), int(p.get("y", 0)), int(p.get("w", 0)), int(p.get("h", 0)))
	var lit := 0
	var burned: Array[String] = []
	for c: Vector2i in _burnable_cells(rect):
		var cell := state.grid.cell(c)
		_ignite(cell, EVENT_FIRE_OWNER, res)
		lit += 1
		var occ := cell.occupant
		if occ != null and occ.is_on_field() and not is_fireproof(occ):
			_kill_burnt(occ)
			res.fire_deaths.append(occ.id)
			burned.append(occ.stats.display_name)
		notify_cell_changed(c)
	var tail := "" if burned.is_empty() else " — " + ", ".join(burned) + " burned"
	res.log("Fire breaks out in zone (%d, %d) %d×%d: %d cell(s) ablaze%s" % [
		rect.position.x, rect.position.y, rect.size.x, rect.size.y, lit, tail])

## ЭМИ: дроны падают, станции дронов и ЛДФ выгорают, у машин страдает пушка.
func _land_emp(p: Dictionary, res: ActionResult) -> void:
	var rect := Rect2i(int(p.get("x", 0)), int(p.get("y", 0)), int(p.get("w", 0)), int(p.get("h", 0)))
	var fried: Array[String] = []
	var ids: Array = state.units.keys()
	ids.sort()
	for id: int in ids:
		var u := state.get_unit(id)
		if u != null and u.is_alive() and u.is_drone and rect.has_point(u.coord):
			_kill(u, res, u.coord)
			res.deaths.append(u.id)
			fried.append("a drone")
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, y)
			var cell := state.grid.cell(c)
			if cell == null:
				continue
			if cell.feature_id == MCF.FEATURE_DRONE_STATION or cell.feature_id == MCF.FEATURE_LDF:
				fried.append("a drone station" if cell.feature_id == MCF.FEATURE_DRONE_STATION else "an LDF wall")
				cell.clear_feature()
				notify_cell_changed(c)
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or not veh.has_component(MCF.COMP_GUN):
			continue
		for fc: Vector2i in veh.footprint():
			if rect.has_point(fc):
				_damage_component(veh, MCF.COMP_GUN, 1, "emp", res)
				fried.append("a vehicle gun")
				break
	res.log("EMP Burst over zone (%d, %d) %d×%d: %s" % [rect.position.x, rect.position.y,
		rect.size.x, rect.size.y, ", ".join(fried) if not fried.is_empty() else "nothing electronic was caught"])

## Обрушение: стены построек в зоне рушатся в обломки; каждый в зоне бросает d6 —
## ниже COLLAPSE_SURVIVE_MIN, и его завалило.
func _land_collapse(p: Dictionary, res: ActionResult) -> void:
	var rect := Rect2i(int(p.get("x", 0)), int(p.get("y", 0)), int(p.get("w", 0)), int(p.get("h", 0)))
	var fell: Array[Vector2i] = []
	for x in range(rect.position.x, rect.end.x):
		for y in range(rect.position.y, rect.end.y):
			var c := Vector2i(x, y)
			var cell := state.grid.cell(c)
			if cell == null or not COLLAPSIBLE.has(cell.feature_id):
				continue
			cell.feature_durability = 0
			_blast_destroy_terrain(c, res, c)
			notify_cell_changed(c)
			fell.append(c)
	if not fell.is_empty():
		_fx(res, {"fx": "debris", "at": NOWHERE, "cells": fell, "blast": true})
	res.log("Structural collapse at zone (%d, %d) %d×%d: %d wall section(s) come down" % [
		rect.position.x, rect.position.y, rect.size.x, rect.size.y, fell.size()])
	var ids: Array = state.units.keys()
	ids.sort()
	for id: int in ids:
		var u := state.get_unit(id)
		if u == null or not u.is_on_field() or u.is_drone or u.aboard_vehicle_id != -1 \
				or not rect.has_point(u.coord):
			continue
		var roll := state.dice.roll_d6()
		res.dice_events.append({"kind": "check", "actor": u.stats.display_name,
			"roll": roll, "need": COLLAPSE_SURVIVE_MIN, "ok": roll >= COLLAPSE_SURVIVE_MIN,
			"roller": u.owner})
		if roll >= COLLAPSE_SURVIVE_MIN:
			res.log("%s dodges the falling debris (roll %d)" % [u.stats.display_name, roll])
			continue
		_kill(u, res, u.coord)
		res.deaths.append(u.id)
		res.log("%s is crushed by the collapse (roll %d, needed %d+)" % [
			u.stats.display_name, roll, COLLAPSE_SURVIVE_MIN])

## Кому подкрепление: слабейшей по стоимости бойцов стороне, если она отстаёт от сильнейшей
## хотя бы на REINFORCE_GAP. Высадка — у ближайшего к её бойцам края (в бункере — из конца
## коридора). Пусто — подкреплять некого. Без кубиков: решает доска.
func _reinforce_target() -> Dictionary:
	var value := {}
	var sum := {}
	var cnt := {}
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or not MCF.is_player(u.owner):
			continue
		if mode.is_holdout() and u.owner == mode.wave_side:
			continue
		value[u.owner] = int(value.get(u.owner, 0)) + u.stats.cost
		if state.grid.in_bounds(u.coord):
			sum[u.owner] = (sum.get(u.owner, Vector2i.ZERO) as Vector2i) + u.coord
			cnt[u.owner] = int(cnt.get(u.owner, 0)) + 1
	if value.size() < 2:
		return {}
	var sides: Array = value.keys()
	sides.sort()
	var weak: int = sides[0]
	var strong: int = sides[0]
	for s: int in sides:
		if int(value[s]) < int(value[weak]):
			weak = s
		if int(value[s]) > int(value[strong]):
			strong = s
	var gap := int(value[strong]) - int(value[weak])
	if float(gap) < float(value[strong]) * REINFORCE_GAP:
		return {}
	var gw := state.grid.width
	var gh := state.grid.height
	var c := Vector2i(gw / 2, gh / 2)
	if int(cnt.get(weak, 0)) > 0:
		c = (sum[weak] as Vector2i) / int(cnt[weak])
	var d := [c.y, gw - 1 - c.x, gh - 1 - c.y, c.x]
	var edge := 0
	for i in 4:
		if int(d[i]) < int(d[edge]):
			edge = i
	var along := gw if edge % 2 == 0 else gh
	var seg := mini(along, ARMY_SEGMENT_MIN + 2)
	var pos := c.x if edge % 2 == 0 else c.y
	var p := {"side": weak, "budget": maxi(1, int(float(gap) * REINFORCE_SHARE)),
			"edge": edge, "from": clampi(pos - seg / 2, 0, along - seg), "len": seg}
	if state.env == "bunker":
		var entry := _hallway_entry(p)
		if entry.x >= 0:
			p["hx"] = entry.x
			p["hy"] = entry.y
	return p

func _land_reinforce(p: Dictionary, res: ActionResult) -> void:
	var side := int(p.get("side", -1))
	if not side_has_army(side):
		res.log("Reinforcements turn back — nobody is left to reinforce")
		return
	var spots := _army_spawn_cells(p)
	var placed := _spawn_budget(spots, int(p.get("budget", 1)), side)
	if placed == 0:
		res.log("Reinforcements find nowhere to land")
		return
	res.log("— Reinforcements reach %s: %d fighters —" % [state.roster.name_of(side), placed])
	notify_cell_changed(spots[0])

## Высадить бойцов из ARMY_ROSTER на клетки spots, пока хватает бюджета (первый — всегда).
## Кубики выбирают тип; порядок клеток задан. Возвращает, сколько встало.
func _spawn_budget(spots: Array[Vector2i], budget: int, owner: int,
		excluded: Array[String] = [], group: int = 0) -> int:
	var pool := ARMY_ROSTER.filter(func(id: String) -> bool: return not excluded.has(id))
	if pool.is_empty(): return 0
	var spent := 0
	var placed := 0
	var guard := 0
	while guard < ARMY_UNIT_CAP and placed < spots.size():
		guard += 1
		var sid: String = pool[_rand_wide(pool.size())]
		var stats: UnitStats = _army_stats(sid)
		if stats == null:
			continue
		if spent + stats.cost > budget and placed > 0:
			break
		var fighter := state.spawn_unit(stats, spots[placed], owner)
		if fighter == null:
			break
		fighter.neutral_group = group
		spent += stats.cost
		placed += 1
	return placed

## Награда (только Capture & Hold): самый дорогой боец команды, что ведёт по очкам (при
## равенстве очков — по стоимости армии). Убивший его враг получает BOUNTY_POINTS.
func _bounty_pick() -> UnitInstance:
	var team_val := {}
	for u: UnitInstance in state.all_units():
		if u.is_alive() and not u.is_drone and MCF.is_player(u.owner):
			var k := MatchMode.team_key(state.roster, u.owner)
			team_val[k] = int(team_val.get(k, 0)) + u.stats.cost
	var keys: Array = team_val.keys()
	if keys.size() < 2:
		return null
	keys.sort()
	var lead: String = keys[0]
	for k: String in keys:
		var pk := int(mode.scores.get(k, 0))
		var pl := int(mode.scores.get(lead, 0))
		if pk > pl or (pk == pl and int(team_val[k]) > int(team_val[lead])):
			lead = k
	var best: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or u.is_held() or not state.grid.in_bounds(u.coord) \
				or not MCF.is_player(u.owner) or MatchMode.team_key(state.roster, u.owner) != lead:
			continue
		if best == null or u.stats.cost > best.stats.cost or (u.stats.cost == best.stats.cost and u.id < best.id):
			best = u
	return best

func _start_bounty(res: ActionResult) -> void:
	var u := _bounty_pick()
	if u == null:
		return
	mode.bounty_unit = u.id
	mode.bounty_side = u.owner
	mode.bounty_until = state.turns.round_number + BOUNTY_ROUNDS - 1
	res.log("⚠ Bounty — %s's %s is marked: kill it within %d rounds for %d points" % [
		state.roster.name_of(u.owner), u.stats.display_name, BOUNTY_ROUNDS, MatchMode.BOUNTY_POINTS])

## Цель награды пала: убил враг — его команде очки; иначе (огонь, событие, свои) — сгорела.
func _check_bounty(res: ActionResult, killer: int) -> void:
	var u := state.get_unit(mode.bounty_unit)
	if u != null and u.is_alive():
		return
	mode.bounty_unit = -1
	if killer >= 0 and MCF.is_player(killer) and not state.roster.are_allies(killer, mode.bounty_side):
		var k := MatchMode.team_key(state.roster, killer)
		mode.scores[k] = int(mode.scores.get(k, 0)) + MatchMode.BOUNTY_POINTS
		res.log("Bounty claimed — %s scores %d points" % [team_label(k), MatchMode.BOUNTY_POINTS])
	else:
		res.log("The bounty lapses — its target fell, but not to an enemy")

## Old mines can appear on traversable ground in every environment, including
## decorated station/bunker floors and the asteroid surface. Never occupy a unit,
## vehicle, structure, body or burning cell.
func _minefield_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in state.grid.height:
		for x in state.grid.width:
			var c := state.grid.cell_fast(x, y)
			if c.feature_id != "" or c.occupant != null or c.vehicle_id != -1 or c.on_fire \
					or c.corpse_count > 0 or not c.walkable_terrain():
				continue
			# Open vacuum on a station has no ground to hide a mine in.
			if c.is_space and state.env != "asteroid":
				continue
			out.append(Vector2i(x, y))
	return out

## Старое минное поле: случается сразу, в начале раунда. Где — не говорится никому.
func _start_minefield(res: ActionResult) -> void:
	var cells := _minefield_cells()
	if cells.is_empty():
		return
	var centre: Vector2i = cells[_rand_wide(cells.size())]
	var placed := 0
	for c: Vector2i in cells:
		if placed >= MINEFIELD_MAX:
			break
		if absi(c.x - centre.x) > MINEFIELD_RADIUS or absi(c.y - centre.y) > MINEFIELD_RADIUS:
			continue
		if state.dice.roll_d6() < MINEFIELD_LAY_ON:
			continue
		var kind := MCF.FEATURE_AV_MINE if state.dice.roll_d6() >= 5 else MCF.FEATURE_MINE
		state.grid.cell(c).set_feature(kind, OLD_MINE_OWNER)
		notify_cell_changed(c)
		placed += 1
	if placed == 0:
		var kind := MCF.FEATURE_AV_MINE if state.dice.roll_d6() >= 5 else MCF.FEATURE_MINE
		state.grid.cell(centre).set_feature(kind, OLD_MINE_OWNER)
		notify_cell_changed(centre)
	res.log("⚠ Old Minefield — scouts report forgotten mines somewhere on the map. Watch your step.")
