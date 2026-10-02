class_name GroupMovePlanner
extends RefCounted

## Раскладка группового приказа движения (#18, item 34): кто куда встаёт и в каком
## порядке идёт. Считается на машине отдавшего приказ — ею же рисуется предпросмотр, —
## а по проводу едет готовый список GroupMoveIntent; резолвер исполняет его по порядку.
##
## Прежняя раскладка давала каждому бойцу «ближайшую к цели клетку» по НЕПОДВИЖНОЙ
## доске, и группа мешала сама себе: боец, зажатый товарищами (середина толпы, хвост
## колонны в коридоре), не находил ни одной свободной клетки и из приказа выпадал. А
## ближайшая по Чебышёву клетка до далёкой цели — целый столбец равных, и ничья уводила
## всю группу по диагонали к краю карты.
##
## Здесь раскладка повторяет исполнение: первым идёт ближний к цели, и каждый следующий
## планируется по доске, где ушедшие раньше уже освободили свои клетки и заняли новые.
## Близость к цели — шаги в обход стен (геополе), при равенстве — прямая до цели, затем
## прямота собственного пути.
##
## Тактический приказ (tactical) выбирает среди клеток у цели самую укрытую от видимых
## врагов: окоп, стена или корпус машины на линии к стрелку, мешки/насыпь вплотную.

## Укрытие ищется не дальше стольких клеток от места, куда боец встал бы обычным приказом.
const TACTICAL_RADIUS := 3
## ponytail: в оценку укрытия идут только ближайшие к точке видимые враги — на больших
## картах хватает; учитывать всех, если группе понадобится держать круговую оборону.
const MAX_THREATS := 8
## Стены на линии к стрелку ищутся не дальше стольких клеток от бойца.
const RAY_CAP := 24
## Врагов не видно — условные стрелки со всех восьми сторон на этой дистанции.
const VIRTUAL_DIST := 6

## [ids, targets] в порядке исполнения — ровно то, что везёт GroupMoveIntent. Стоящие на
## месте в список не попадают.
##
## max_tier — сколько ОД сверх первого отряд вправе потратить на этот ход (0 — зелёная зона,
## 1 — оранжевая, 2 — красная): столько, во сколько обошлась клетка, по которой щёлкнули,
## как и у одиночного бойца. Дальше своей зоны (move_tier_budgets) никто не идёт.
static func plan(r: GameActionResolver, ids: Array[int], dest: Vector2i,
		tactical: bool = false, max_tier: int = 0) -> Array:
	var out_ids: Array[int] = []
	var out_targets: Array[Vector2i] = []
	var grid := r.state.grid
	var movers: Array[UnitInstance] = []
	for id in ids:
		var u := r.state.get_unit(id)
		if r.can_move(u):
			movers.append(u)
	if movers.is_empty() or not grid.in_bounds(dest):
		return [out_ids, out_targets]
	# Шаги до точки нужны только там, куда отряд дойдёт: дальше любого бойца на его запас
	# хода волну не пускаем.
	var pw := grid.width + 2
	var at_movers := PackedInt32Array()
	var reach_extra := 0
	for u: UnitInstance in movers:
		at_movers.append((u.coord.y + 1) * pw + u.coord.x + 1)
		reach_extra = maxi(reach_extra, budget_for(r, u, max_tier))
	var geo := AIController.wave(grid, PackedInt32Array([(dest.y + 1) * pw + dest.x + 1]), {},
			at_movers, reach_extra)
	# Первым ходит ближний к цели: он и освобождает дорогу тем, кто за ним.
	movers.sort_custom(func(a: UnitInstance, b: UnitInstance) -> bool:
		return _less([_approach(geo, a.coord, dest), _d2(a.coord, dest), a.id],
				[_approach(geo, b.coord, dest), _d2(b.coord, dest), b.id]))
	var threats: Array = _threats(r, movers[0].owner, dest) if tactical else []
	var exposure: Dictionary = {}   # клетка -> оценка открытости (те же враги на весь план)
	var claimed: Dictionary = {}    # куда уже встали шедшие раньше
	var vacated: Dictionary = {}    # откуда они ушли
	for u: UnitInstance in movers:
		var fireproof := r.is_fireproof(u)
		var cands: Array = [u.coord]
		for c: Vector2i in r.reachable_for(u, budget_for(r, u, max_tier), claimed, vacated).cost:
			if fireproof or not grid.cell(c).on_fire:   # в огонь приказом не заводим
				cands.append(c)
		var from := u.coord
		var place := func(c: Vector2i) -> Array:
			return [_approach(geo, c, dest), _d2(c, dest), _d2(c, from)]
		var best := _argmin(cands, place)
		if tactical:
			# Укрытие ищется вокруг клетки, куда боец встал бы обычным приказом: так он не
			# уходит в сторону от точки и не теряет больше TACTICAL_RADIUS шагов хода.
			var natural := best
			var cover := func(c: Vector2i) -> Array:
				if not exposure.has(c):
					exposure[c] = _exposure(grid, c, threats)
				return [exposure[c]] + place.call(c)
			best = _argmin(cands.filter(func(c: Vector2i) -> bool:
				return Combat.distance(c, natural) <= TACTICAL_RADIUS), cover)
		if best != u.coord:
			out_ids.append(u.id)
			out_targets.append(best)
			vacated[u.coord] = true
			claimed[best] = true
	return [out_ids, out_targets]

## Запас хода бойца в пределах зоны max_tier (меньше ОД — его последняя зона).
static func budget_for(r: GameActionResolver, u: UnitInstance, max_tier: int) -> int:
	var tiers := r.move_tier_budgets(u)
	return tiers[clampi(max_tier, 0, tiers.size() - 1)]

## Шаги до цели в обход стен; куда волна не дошла (цель замурована) — после всех
## достижимых, по прямой.
static func _approach(geo: GeoField, c: Vector2i, dest: Vector2i) -> int:
	var g := geo.at(c)
	return g if g != GeoField.FAR else GeoField.FAR + Combat.distance(c, dest)

static func _d2(a: Vector2i, b: Vector2i) -> int:
	return (a - b).length_squared()

## Клетка с наименьшим ключом; при равенстве — первая (в полном списке это своя клетка
## бойца, так что без выгоды он остаётся на месте).
static func _argmin(cells: Array, key: Callable) -> Vector2i:
	var best: Vector2i = cells[0]
	var best_key: Array = key.call(best)
	for c: Vector2i in cells:
		var k: Array = key.call(c)
		if _less(k, best_key):
			best_key = k
			best = c
	return best

static func _less(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return a[i] < b[i]
	return false

## Видимые этой стороне враги на поле, ближайшие к точке приказа. Туман уважается:
## раскладка не должна выдавать игроку тех, кого он не видит.
static func _threats(r: GameActionResolver, owner: int, dest: Vector2i) -> Array:
	var out: Array = []
	for e: UnitInstance in r.state.all_units():
		if not e.is_alive() or e.is_drone or e.is_held() or not r.state.grid.in_bounds(e.coord):
			continue
		if r.state.roster.are_allies(owner, e.owner) or (CivilianAI.is_npc(e) and not e.civilian_active):
			continue
		if r.is_visible_to_team(owner, e):
			out.append(e)
	out.sort_custom(func(a: UnitInstance, b: UnitInstance) -> bool:
		return Combat.distance(a.coord, dest) < Combat.distance(b.coord, dest))
	return out.slice(0, MAX_THREATS)

## Насколько клетка открыта: сумма по стрелкам, 0 — сторона закрыта, 0.5 — укрытие
## вплотную, 1 — чисто. Направление на стрелка округляется до одного из восьми — по
## ним и идёт огонь (Combat.is_on_firing_line), а враг ещё успеет встать на линию.
static func _exposure(grid: Grid, c: Vector2i, threats: Array) -> float:
	var trench := grid.cell(c).feature_id == MCF.FEATURE_TRENCH
	var total := 0.0
	if threats.is_empty():
		for d: Vector2i in Grid.N8:
			total += _side(grid, c, d, VIRTUAL_DIST, false, trench)
		return total
	for e: UnitInstance in threats:
		var off: Vector2i = e.coord - c
		var dist := Combat.distance(c, e.coord)
		var dir := Vector2i(roundi(float(off.x) / dist), roundi(float(off.y) / dist))
		total += _side(grid, c, dir, dist, e.stats.special_ability_id == MCF.ABILITY_MARKSMAN, trench)
	return total

## Правила те же, что у выстрела: окоп спасает от пули издалека и от луча всегда
## (trench_protected), стена или корпус на линии её рвут (los_blocked; стекло — нет, лазер
## марксмана бьёт сквозь всё), укрытие 1 м засчитывается только вплотную к цели и не в
## упор (cover_effect_from).
static func _side(grid: Grid, c: Vector2i, dir: Vector2i, dist: int, beam: bool,
		trench: bool) -> float:
	if trench and (beam or dist > 1):
		return 0.0
	if not beam:
		var p := c
		for _k in mini(dist - 1, RAY_CAP):
			p += dir
			if not grid.in_bounds(p):
				break
			var pc := grid.cell_fast(p.x, p.y)
			if pc.vehicle_id != -1 \
					or (pc.cover_height >= MCF.WALL_HEIGHT and not MCF.is_glass(pc.feature_id)):
				return 0.0
	var front := grid.cell(c + dir)
	if dist > 2 and front != null and MCF.COVER_MOD.has(front.cover_height):
		return 0.5
	return 1.0
