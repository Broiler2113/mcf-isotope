@abstract
extends "res://src/resolver/parts/ResolverFurnitureAndFire.gd"

## The world around the armies: civilians waking up, airlocks, vacuum and zero-g.

# --- Мирные жители (§3.10) ---

func _is_civilian(u: UnitInstance) -> bool:
	return CivilianAI.is_npc(u)

## Все живые солдаты на поле — цели для мирных (обе игровые стороны, §3.10).
func _living_soldiers() -> Array:
	var out: Array = []
	for u in state.all_units():
		if CivilianAI.is_soldier(u):
			out.append(u)
	return out

## Видит ли нейтрал солдата (§3.1b). «Видит» = по ЧИСТОЙ прямой линии взгляда: клетки
## коллинеарны (Combat.is_on_firing_line) и между ними нет стены/корпуса; стекло не
## преграда (item 29). Косой, не по лучу, взгляд «видимостью» не считается — иначе, раз
## los_blocked для непрямой линии отвечает «не перекрыто», нейтрал будил бы всех подряд
## через все стены. Это тот же примитив зрения, что был и раньше, только строже описан.
func _civ_sees_soldier(civ: UnitInstance, idx: Dictionary = {}) -> bool:
	if idx.is_empty():
		idx = _sight_index()
	var c := civ.coord
	for key: Vector3i in [Vector3i(0, c.y, 0), Vector3i(1, c.x, 0), Vector3i(2, c.x - c.y, 0), Vector3i(3, c.x + c.y, 0)]:
		for t: Vector2i in idx.get(key, []):
			if t != c and not los_blocked(c, t, true, false, true):
				return true
	return false

func _sight_index(soldiers: Variant = null) -> Dictionary:
	var targets: Array[Vector2i] = []
	for s: UnitInstance in (_living_soldiers() if soldiers == null else soldiers):
		if state.grid.in_bounds(s.coord):   # crew inside a tank are off the board: unseen
			targets.append(s.coord)
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and not MCF.is_neutral(veh.owner):
			targets.append_array(veh.footprint())
	return _index_lines(targets)

## Клетки, разложенные по линиям огня (строка, столбец, две диагонали).
func _index_lines(targets: Array[Vector2i]) -> Dictionary:
	var idx := {}
	for t in targets:
		for key: Vector3i in [Vector3i(0, t.y, 0), Vector3i(1, t.x, 0), Vector3i(2, t.x - t.y, 0), Vector3i(3, t.x + t.y, 0)]:
			if not idx.has(key):
				idx[key] = []
			idx[key].append(t)
	return idx

## Вскрытие жителя (§3, item 3): пробуждается, если сам видит солдата (см. _civ_sees_soldier).
## Общий бой БОЛЬШЕ не будит всех разом — повод строго локальный: соседняя клетка сменила
## состояние (notify_cell_changed) ЛИБО солдат вошёл в обзор (здесь). Обратно вскрытие не
## снимается. Ещё не сгруппированного заносим во фронт — _wake_and_group соберёт группу.
func _update_breached(civ: UnitInstance, idx: Dictionary = {}) -> void:
	if civ.civilian_active:
		return
	if _civ_sees_soldier(civ, idx):
		civ.civilian_active = true
		if civ.neutral_group == 0 and not _activation_frontier.has(civ.id):
			_activation_frontier.append(civ.id)

## Повод активации (§3.1a): соседняя клетка сменила состояние — разрушена, застроена,
## открылся шлюз, взрыв или огонь. Спящие НЕ сгруппированные нейтралы вокруг встают во
## фронт пробуждения; его разбирает _wake_and_group на верхнем уровне resolve(). Зовётся
## из путей записи резолвера (_ignite, снос рельефа взрывом, стройка, окоп, открытие шлюза).
func notify_cell_changed(coord: Vector2i) -> void:
	# Construction/destruction inside a cloud immediately updates its footprint.
	if random_events != null and (not random_events.clouds.is_empty() or not random_events.smoke.is_empty()):
		var changed := state.grid.cell(coord)
		if changed != null:
			changed.gas = changed.can_hold_gas() and random_events.cloud_at(coord)
			changed.smoke = changed.can_hold_gas() and random_events.smoke_at(coord)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var c := Vector2i(coord.x + dx, coord.y + dy)
			if not state.grid.in_bounds(c):
				continue
			var u := state.grid.cell(c).occupant
			if u != null and _is_civilian(u) and u.is_alive() and u.neutral_group == 0 \
					and not _activation_frontier.has(u.id):
				_activation_frontier.append(u.id)

## Разлить пробуждение по СОСЕДСТВУ от одного семени (§3.2): волна идёт через спящих ещё
## не сгруппированных нейтралов, пока связный кластер не замкнётся. Будит их (civilian_active)
## и возвращает ровно этот кластер. «Уже в группе» (neutral_group != 0) — граница волны.
func _flood_component(seed_id: int) -> Array:
	var woke: Array = []
	var seen: Dictionary = {}
	var stack: Array[int] = [seed_id]
	while not stack.is_empty():
		var id: int = stack.pop_back()
		if seen.has(id):
			continue
		seen[id] = true
		var u := state.get_unit(id)
		if u == null or not _is_civilian(u) or not u.is_alive() or u.neutral_group != 0:
			continue
		u.civilian_active = true
		woke.append(u)
		for n: Vector2i in state.grid.neighbors(u.coord):
			var nb := state.grid.cell(n).occupant
			if nb != null and _is_civilian(nb) and nb.is_alive() \
					and nb.neutral_group == 0 and not seen.has(nb.id):
				stack.append(nb.id)
	return woke

## Каскад пробуждения (§3.2): разбирает весь фронт, будит достижимые кластеры и
## возвращает всех поднятых на ноги в этот заход (пустой — никого нового). Группировкой
## НЕ занимается — это отдельный шаг (_wake_and_group). Оставлен как самостоятельная
## операция для сценарных проверок пробуждения.
func _cascade_activation() -> Array:
	var woke: Array = []
	var frontier: Array[int] = _activation_frontier.duplicate()
	_activation_frontier.clear()
	while not frontier.is_empty():
		var id: int = frontier.pop_back()
		var u := state.get_unit(id)
		if u == null or not _is_civilian(u) or not u.is_alive() \
				or u.neutral_group != 0 or u.civilian_active:
			continue
		woke.append_array(_flood_component(id))
	return woke

## Номер следующей активационной группы (§15): по счёту уже созданных нейтральных
## слотов в очереди инициативы, +1. Считается от состояния, а не из отдельного счётчика,
## поэтому переживает пересоздание резолвера и откат хода.
func _next_group_number() -> int:
	var n := 0
	for slot: int in state.turns.round_order:
		if slot >= MCF.NEUTRAL_GROUP_BASE and not MCF.is_wave_slot(slot):
			n += 1
	return n + 1

## Собрать активационные группы (§15). Каждый СВЯЗНЫЙ кластер из фронта становится одной
## группой: получает римский номер по порядку, каждый его боец — этот номер и владелец-слот
## группы, а сам слот встаёт в СЛУЧАЙНОЕ место очереди инициативы. Жребий берётся из общего
## потока d6 (_rand_index) — иначе хост и клиент врезали бы группу в разные места. Разные
## кварталы — разные группы, потому и разливаем каждый кластер по своему семени.
func _wake_and_group(res: ActionResult) -> void:
	_seed_sight_activation()
	while not _activation_frontier.is_empty():
		var seed_id: int = _activation_frontier.pop_back()
		var su := state.get_unit(seed_id)
		if su == null or not _is_civilian(su) or not su.is_alive() or su.neutral_group != 0:
			continue
		var woke := _flood_component(seed_id)
		if woke.is_empty():
			continue
		_wake_by_sight(woke)
		var num := _next_group_number()
		var slot := MCF.neutral_group_slot(num)
		for u: UnitInstance in woke:
			u.neutral_group = num
			u.owner = slot
		var idx := _rand_index(state.turns.round_order.size() + 1)
		state.turns.insert_slot(slot, idx)
		res.log("- Neutral group %s joins the fight (%d unit%s) -" % [
			MCF.roman(num), woke.size(), "" if woke.size() == 1 else "s"])
		# Свежевскрытый кластер мог открыть обзор ещё одному кварталу — проверяем снова.
		_seed_sight_activation()

## Owner rule (2026-10-27): a sleeping civilian who sees another civilian wake up wakes too,
## with the civilians around it, and so on down the line. "Sees" is _civ_sees_soldier's clear
## row, column or diagonal. They join the group being formed: one wake-up stays one group and
## one initiative slot, however far it spreads. Grows woke in place, in a fixed order (units
## by the order of state.all_units(), each one's neighbours as _flood_component takes them).
func _wake_by_sight(woke: Array) -> void:
	var taken := {}
	for u: UnitInstance in woke:
		taken[u.id] = true
	var fresh := woke.duplicate()
	while not fresh.is_empty():
		var targets: Array[Vector2i] = []
		for u: UnitInstance in fresh:
			targets.append(u.coord)
		var idx := _index_lines(targets)
		fresh = []
		for u: UnitInstance in state.all_units():
			if taken.has(u.id) or not _is_civilian(u) or not u.is_alive() or u.neutral_group != 0:
				continue
			if not _civ_sees_soldier(u, idx):
				continue
			for w: UnitInstance in _flood_component(u.id):
				if not taken.has(w.id):
					taken[w.id] = true
					woke.append(w)
					fresh.append(w)

## Засеять фронт теми спящими НЕ сгруппированными нейтралами, кто видит солдата (§3.1b).
## Дорого только когда на карте есть и спящие нейтралы, и солдаты, — иначе выходит сразу.
func _seed_sight_activation() -> void:
	var native := _native_wake_scorer()
	if native != null:
		_native_sight_activation(native)
		return
	# One pass over the army collects the soldiers and the sleepers. Positions: while the unit
	# list is the one of the last check, only units stamped since can stand elsewhere, and only
	# their entries are compared; otherwise every position is collected and compared.
	var soldiers: Array = []
	var sleepers: Array = []
	var units := state.all_units()
	var incremental := is_same(units, _wk_units) and _wk_world == UnitInstance.vision_world
	var pos := {}
	var stamped: Array = []
	var in_grid := state.grid
	for u: UnitInstance in units:
		if incremental:
			if u.vision_stamp > _wk_epoch:
				stamped.append(u)
		elif not u.is_drone and u.is_alive() and in_grid.in_bounds(u.coord):
			pos[u.id] = u.coord
		if not u.is_alive():
			continue
		if CivilianAI.is_soldier(u):
			# Tank crew sit off the board (OFFBOARD), and an off-board line counts as clear in
			# los_blocked: a sleeper on the x == y diagonal used to "see" every crew member.
			if in_grid.in_bounds(u.coord):
				soldiers.append(u)
		elif _is_civilian(u) and u.neutral_group == 0:
			sleepers.append(u)
	if soldiers.is_empty():
		return
	# [клетка до или null, клетка после или null, юнит] for every entry that differs.
	var shifts: Array = []
	if incremental:
		for u: UnitInstance in stamped:
			var now: Variant = u.coord if not u.is_drone and u.is_alive() and in_grid.in_bounds(u.coord) else null
			var was: Variant = _wk_pos.get(u.id)
			if was != now:
				shifts.append([was, now, u])
	_wk_units = units
	_wk_world = UnitInstance.vision_world
	_wk_epoch = UnitInstance.vision_epoch
	# Проверяем только то, что могло измениться с прошлого раза (batch mp-perf). Раньше на
	# каждое действие строился индекс ВСЕЙ армии и каждый спящий житель проверялся по нему
	# заново: ~4 мс на шаг в бою на полтысячи бойцов, у хоста и у каждого гостя.
	#
	# Итог обязан быть РОВНО тем же, что у полной проверки (иначе пиры с разной историей
	# кэша разошлись бы): житель, не видевший солдата, может увидеть его, только если
	#   * солдат сдвинулся или появился — проверяем по ним;
	#   * с линии между ними ушёл заслонявший юнит (живые юниты обзор закрывают) — житель
	#     на линии через освободившуюся клетку проверяется целиком;
	#   * сменился рельеф или машины — тогда проверяется всё.
	# Видевшие солдата, но ещё не собранные в группу проверяются целиком каждый раз.
	var vsig := 0
	for veh: Vehicle in state.all_vehicles():
		if veh.alive():
			vsig = hash([vsig, veh.id, veh.origin])
	# Смена рельефа (шлюз открылся, стену снесли) — не повод проверять всех: она записана
	# по клеткам в журнале обзора, и увидеть больше можно лишь сквозь изменившуюся клетку на
	# своей линии. Журнала не хватило (давно не проверяли) — тогда уже всех.
	var full := _wk_vsig != vsig or _wk_grid != state.grid.get_instance_id() \
			or check_everything or (_wk_vv != GridCell.vision_version and _wk_vv < GridCell.vision_log_base)
	var moved: Array[Vector2i] = []
	var vacated := {}
	if not full and incremental:
		for sh: Array in shifts:
			var u: UnitInstance = sh[2]
			if sh[1] != null and u.is_alive() and CivilianAI.is_soldier(u):
				moved.append(sh[1])
			if sh[0] != null:
				for key in _line_keys(sh[0]):
					vacated[key] = true
	elif not full:
		for so: UnitInstance in soldiers:
			var c: Vector2i = so.coord
			if _wk_pos.get(so.id) != c:
				moved.append(c)
		for id: int in _wk_pos:
			var was: Vector2i = _wk_pos[id]
			if pos.get(id) != was:
				for key in _line_keys(was):
					vacated[key] = true
	if not full:
		if _wk_vv != GridCell.vision_version:
			var changes := GridCell.vision_changes
			var i: int = (_wk_vv - GridCell.vision_log_base) * 2
			while i < changes.size():
				for key in _line_keys(Vector2i(changes[i], changes[i + 1])):
					vacated[key] = true
				i += 2
	var prev_seen := _wk_seen
	var prev_sleepers := _wk_sleepers
	_wk_seen = {}
	_wk_sleepers = {}
	for u: UnitInstance in sleepers:
		_wk_sleepers[u.id] = true
	if incremental:
		for sh: Array in shifts:
			if sh[1] == null:
				_wk_pos.erase((sh[2] as UnitInstance).id)
			else:
				_wk_pos[(sh[2] as UnitInstance).id] = sh[1]
	else:
		_wk_pos = pos
	_wk_vv = GridCell.vision_version
	_wk_vsig = vsig
	_wk_grid = state.grid.get_instance_id()
	if sleepers.is_empty():
		return
	var full_idx: Dictionary = {}
	var moved_idx := _index_lines(moved)
	for u: UnitInstance in sleepers:
		if _activation_frontier.has(u.id):
			continue
		# Новый спящий (раньше не проверялся вовсе) — тоже целиком.
		var whole := full or prev_seen.has(u.id) or not prev_sleepers.has(u.id)
		if not whole and not vacated.is_empty():
			for key in _line_keys(u.coord):
				if vacated.has(key):
					whole = true
					break
		var sees := false
		if whole:
			if full_idx.is_empty():
				full_idx = _sight_index(soldiers)
			sees = _civ_sees_soldier(u, full_idx)
		elif not moved.is_empty():
			sees = _civ_sees_soldier(u, moved_idx)
		if sees:
			_wk_seen[u.id] = true
			_activation_frontier.append(u.id)

## The wake-up check in C++ (MCFPlanScorer.civilians_seeing): every sleeper not yet queued,
## against every soldier on the board and every hull. Its input comes from _sync_wake_rows,
## kept between actions. The incremental records of the GDScript check below do not follow
## these calls, so a later GDScript pass starts full (_wk_grid).
##
## A sleeper checked before that saw no one is asked again only if a cell on its row, column or
## diagonal changed since (_wa_dirty: a logged unit's old or new cell, an occupant change):
## sight runs along those four lines only, and the rest of what it depends on (the board, its
## look and the hulls) is the scorer's key, compared whole. Everyone else is asked as before,
## so the frontier grows exactly as the whole check grows it. check_everything asks everyone.
func _native_sight_activation(scorer: RefCounted) -> void:
	_sync_wake_rows()
	_wk_grid = 0
	var units := state.all_units()
	var xy := _wa_xy
	var targets := PackedInt32Array()
	var waiting: Array = []
	var sleepers := PackedInt32Array()
	var hulls := PackedInt32Array()
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and not MCF.is_neutral(veh.owner):
			for fc: Vector2i in veh.footprint():
				hulls.append(fc.x)
				hulls.append(fc.y)
	var keep := not _wa_fresh and not check_everything and is_same(scorer, _wq_scorer) \
			and _wq_key == _wake_scorer_key and _wq_hulls == hulls
	if not keep:
		_wq_quiet.clear()
	var dirty := {}
	if keep:
		var gw := state.grid.width
		for idx: int in _wa_dirty:
			var x := idx % gw
			var y := idx / gw
			dirty[Vector2i(0, y)] = true
			dirty[Vector2i(1, x)] = true
			dirty[Vector2i(2, x - y)] = true
			dirty[Vector2i(3, x + y)] = true
	_wa_dirty.clear()
	_wa_fresh = false
	_wq_scorer = scorer
	_wq_key = _wake_scorer_key.duplicate()
	_wq_hulls = hulls
	for i in _wa_kind.size():
		var kind: int = _wa_kind[i]
		if kind == _WA_TARGET:
			targets.append(xy[i * 2])
			targets.append(xy[i * 2 + 1])
		elif kind == _WA_SLEEPER:
			var u: UnitInstance = units[i]
			if _activation_frontier.has(u.id):
				continue
			var x: int = xy[i * 2]
			var y: int = xy[i * 2 + 1]
			if _wq_quiet.has(u.id) and not dirty.has(Vector2i(0, y)) and not dirty.has(Vector2i(1, x)) \
					and not dirty.has(Vector2i(2, x - y)) and not dirty.has(Vector2i(3, x + y)):
				continue   # saw no one, and nothing on its lines changed since
			waiting.append(u)
			sleepers.append(x)
			sleepers.append(y)
	if targets.is_empty() or waiting.is_empty():
		return   # no soldier on the board, or nobody to ask: nothing to wake
	targets.append_array(hulls)
	var sees: PackedByteArray = scorer.civilians_seeing(sleepers, targets, PackedInt32Array(_wa_occ.keys()))
	if sees.size() != waiting.size():
		push_error("Native wake-up check refused its input")
		_wq_quiet.clear()
		return
	for i in waiting.size():
		var id: int = (waiting[i] as UnitInstance).id
		if sees[i] != 0:
			_activation_frontier.append(id)
			_wq_quiet.erase(id)
		else:
			_wq_quiet[id] = true

## The wake-up check's input, kept per all_units() slot between actions (it is asked after every
## action, over the whole army): what each unit is to the check, and the cells whose occupant is
## a living unit of this state (living units block a civilian's sight). Only the units in
## UnitInstance.vision_log and the cells in GridCell's walk log since the last call are looked
## at again; another unit list or grid, or a log that no longer reaches back, rebuilds it all.
const _WA_TARGET := 1    # a living player soldier, not a drone, on the board
const _WA_SLEEPER := 2   # a living neutral not in an activation group yet
var _wa_list: Array = []
var _wa_pos := -1
var _wa_walk := -1
var _wa_grid := 0
var _wa_kind := PackedByteArray()
var _wa_xy := PackedInt32Array()   # each slot's cell when its kind was taken
var _wa_occ: Dictionary = {}       # flat cell index -> true
var _wa_dirty: Dictionary = {}     # flat cells touched since the last check (see above)
var _wa_fresh := true              # the rows were rebuilt whole: no earlier check to build on
var _wq_quiet: Dictionary = {}     # sleeper id -> true: asked, saw no one
var _wq_scorer: RefCounted = null  # the scorer, its key and the hulls of that check
var _wq_key: Array = []
var _wq_hulls := PackedInt32Array()

func _sync_wake_rows() -> void:
	var units := state.all_units()
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	var cells := grid.cells_flat()
	var xy := state.unit_xy()
	var picks: Variant = null
	if is_same(units, _wa_list) and _wa_grid == grid.get_instance_id() and not check_everything \
			and _wa_walk >= GridCell.walk_log_base and _wa_walk <= GridCell.walk_version:
		picks = state.units_logged_since(_wa_pos, _wa_list)
	_wa_pos = UnitInstance.vision_log_end()
	if picks == null:
		_wa_list = units
		_wa_grid = grid.get_instance_id()
		_wa_walk = GridCell.walk_version
		_wa_xy = xy.duplicate()
		_wa_kind.resize(units.size())
		_wa_occ.clear()
		_wa_dirty.clear()
		_wa_fresh = true
		for i in units.size():
			var u: UnitInstance = units[i]
			_wa_kind[i] = _wake_kind(u, gw, gh)
			var c := u.coord
			if u.status == MCF.Status.ALIVE and c.x >= 0 and c.y >= 0 and c.x < gw and c.y < gh \
					and cells[c.y * gw + c.x].occupant == u:
				_wa_occ[c.y * gw + c.x] = true
		return
	# The cells whose "a living unit of ours holds it" may have turned: where a logged unit
	# stood and stands, and every cell whose occupant changed.
	var touched := {}
	for i: int in picks:
		for c in [Vector2i(_wa_xy[i * 2], _wa_xy[i * 2 + 1]), Vector2i(xy[i * 2], xy[i * 2 + 1])]:
			if c.x >= 0 and c.y >= 0 and c.x < gw and c.y < gh:
				touched[c.y * gw + c.x] = true
		_wa_xy[i * 2] = xy[i * 2]
		_wa_xy[i * 2 + 1] = xy[i * 2 + 1]
		_wa_kind[i] = _wake_kind(units[i], gw, gh)
	var changes := GridCell.walk_changes
	var k: int = (_wa_walk - GridCell.walk_log_base) * 2
	while k < changes.size():
		touched[changes[k + 1] * gw + changes[k]] = true
		k += 2
	_wa_walk = GridCell.walk_version
	_wa_dirty.merge(touched)
	for idx: int in touched:
		var occ: UnitInstance = cells[idx].occupant
		if occ != null and occ.status == MCF.Status.ALIVE and occ.coord == Vector2i(idx % gw, idx / gw) \
				and state.unit_slot(occ) >= 0:
			_wa_occ[idx] = true
		else:
			_wa_occ.erase(idx)

func _wake_kind(u: UnitInstance, gw: int, gh: int) -> int:
	if u.status != MCF.Status.ALIVE:
		return 0
	if MCF.is_player(u.owner):
		var c := u.coord
		return _WA_TARGET if not u.is_drone and c.x >= 0 and c.y >= 0 and c.x < gw and c.y < gh else 0
	if MCF.is_neutral(u.owner) and u.neutral_group == 0:
		return _WA_SLEEPER
	return 0

## For each civilian, 1 if it sees a soldier on the board or a hull, natively (the parity
## test's view of the same check); null without the kernel.
func _civilians_seeing_native(soldiers: Array, civilians: Array) -> Variant:
	var scorer := _native_wake_scorer()
	if scorer == null:
		return null
	var grid := state.grid
	var targets := PackedInt32Array()
	for so: UnitInstance in soldiers:
		targets.append_array([so.coord.x, so.coord.y])
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and not MCF.is_neutral(veh.owner):
			for fc: Vector2i in veh.footprint():
				targets.append_array([fc.x, fc.y])
	var xy := PackedInt32Array()
	for u: UnitInstance in civilians:
		xy.append_array([u.coord.x, u.coord.y])
	var occupied := PackedInt32Array()
	for u: UnitInstance in state.all_units():
		if u.is_alive() and grid.in_bounds(u.coord) and grid.cell_fast(u.coord.x, u.coord.y).occupant == u:
			occupied.append(u.coord.y * grid.width + u.coord.x)
	var sees: PackedByteArray = scorer.civilians_seeing(xy, targets, occupied)
	return sees if sees.size() == civilians.size() else null

## This resolver's native scorer with the board loaded, kept while the board, its look and the
## hull layer (compared whole: footprints come and go with borg pilots, not only with vehicle
## fields) stand. Null without the kernel.
var _wake_scorer: RefCounted = null
var _wake_scorer_key: Array = []

func _native_wake_scorer() -> RefCounted:
	var layer := NativeBoard.vehicle_layer(state)
	var key := [state.grid.get_instance_id(), GridCell.look_version, legacy_corpse_rules, layer[0], layer[1]]
	if _wake_scorer != null and key == _wake_scorer_key:
		return _wake_scorer
	_wake_scorer = NativeBoard.scorer(state, self, layer)
	_wake_scorer_key = key
	return _wake_scorer

## Четыре линии огня через клетку: строка, столбец, две диагонали (ключи _index_lines).
static func _line_keys(t: Vector2i) -> Array:
	return [Vector3i(0, t.y, 0), Vector3i(1, t.x, 0), Vector3i(2, t.x - t.y, 0), Vector3i(3, t.x + t.y, 0)]

## Собственный ход мирных жителей (§3.10, #42/#56, #103).
##
## РАНЬШЕ здесь жил отдельный, второй «мозг»: житель шагал по одной клетке за активацию,
## не знал ни штабного плана, ни укрытий, ни дробления действий, стрелял по собственной
## упрощённой процедуре, а трупы умел только подбирать. Получались две системы с одной
## задачей и разным поведением — ровно то, что просили свести воедино (#103).
##
## ТЕПЕРЬ жители — обычная третья армия под управлением AIController: тот же планировщик,
## те же геополя, то же дробление очереди и движения, те же приказы через resolve(). Значит:
##   * житель проходит ВСЮ свою скорость за раз, как боец ИИ, а не одну клетку;
##   * в стену он не упирается — маршрут считает Дейкстра по проходимым клеткам;
##   * стреляет он через обычный _resolve_shoot, то есть с очередями, укрытиями и теми же
##     кубиками, что и все остальные.
##
## Единственное, что остаётся местным, — «оформление» для UI: события «walk» и «ap»,
## по которым Main рисует проход по клеткам и гаснущие точки ОД. Резолвер обычных
## приказов их не выдаёт: за живого игрока и за ИИ шаги рисует сам Main.
func advance_civilians(owner: int = MCF.Owner.NEUTRAL) -> ActionResult:
	var res := ActionResult.success()
	# Слот принадлежит КОНКРЕТНОМУ владельцу-нейтралу: общему слоту (§до сбора групп) или
	# слоту активационной группы (§15). Ведём только его бойцов, чужих групп не трогаем.
	var awake := 0
	var idx := _sight_index()
	# Независимая армия (0.9.4) не спит и не «вскрывается»: она пришла воевать и готова
	# с первого же своего хода. Всё прочее у неё как у жителей — тот же мозг, тот же
	# отыгрыш внутри передачи хода.
	var raiders := MCF.is_independent(owner)
	for u in state.all_units():
		if u.owner != owner or not u.is_alive() or u.is_held():
			continue
		if not raiders:
			if not _is_civilian(u):
				continue
			_update_breached(u, idx)
			if not u.civilian_active:
				continue
		# Слот жителей может прийтись до границы раунда — свою активацию житель всегда
		# начинает с полным запасом (иначе он простоял бы весь первый слот партии).
		if u.remaining_ap <= 0 and u.move_credit <= 0:
			u.reset_ap()
		awake += 1
	if awake == 0:
		return res

	# Мозг заводится ПОД ВЛАДЕЛЬЦА слота: для группы её слот и есть owner, иначе
	# _enemies_of посчитал бы своих же за врагов. Кэш держит один мозг на слот.
	if _civ_brain == null or _civ_brain.owner != owner:
		# Налётчики (0.12): ИИ в игре всегда HARD, у налётчиков — личность Aggressor. Мирные
		# остаются при своём простом мозге.
		if raiders:
			_civ_brain = AIController.new(owner, AIController.Difficulty.HARD)
			_civ_brain.style = AIPersonality.AGGRESSOR
			_civ_brain.bind_match(self)
		else:
			_civ_brain = AIController.new(owner, AIController.Difficulty.NORMAL)
	# Item 23: живой, «в порядке очереди» отыгрыш вместо «телепорт + перемотка». В res
	# первым уходит событие hold — оно ПРИКАЛЫВАЕТ каждого будущего ходока к ИСХОДНОЙ
	# клетке, чтобы Main не показал их сразу в конечных позициях, пока идёт анимация.
	# Заполняем его по ходу (кто реально пошёл), а вставляем в начало в самом конце.
	var moved_from: Dictionary = {}
	var acted: Dictionary = {}
	var guard := 0
	while guard < CIVILIAN_ACTION_CAP:
		guard += 1
		var intent: Intent = _civ_brain._decide(state)
		if intent is EndTurnIntent:
			break  # ход квартала закончен; передавать его дальше — дело play_civilian_slots
		var actor := state.get_unit(intent.actor_id)
		if actor == null:
			_civ_brain.notify_intent_denied(state)
			continue
		var from := actor.coord
		var ap_before := actor.remaining_ap
		# Маршрут считаем ДО приказа: после переезда клетка старта уже свободна, а финиш
		# занят, и путь получился бы другим.
		var route := _civilian_route(actor, intent)
		var sub := resolve(intent)
		if not sub.ok:
			# Тот же расчёт выдал бы то же намерение — снимаем актёра с очереди (#60).
			_civ_brain.notify_intent_denied(state)
			continue
		acted[actor.id] = true
		# Метка «сейчас ходит вот этот» (#103). По walk/ap событиям актёра видно не всегда:
		# житель, который просто стреляет, не делает ни шага, а очередь ему бесплатна после
		# первого ОД — в потоке кубиков игрок терял, КТО именно ведёт огонь. По метке UI
		# подводит камеру к активному жителю, как к любому другому ходящему юниту (#96).
		res.dice_events.append({"kind": "focus", "unit": actor.id, "coord": from})
		if not route.is_empty():
			# Пришпиливаем ходока к ИСХОДНОЙ клетке (item 23): первое движение бойца
			# запоминает, откуда он стартовал в этом слоте, — hold-событие вернёт его туда
			# перед анимацией, чтобы не было «телепорта в конец, потом перемотки».
			if not moved_from.has(actor.id):
				moved_from[actor.id] = from
			res.dice_events.append({
				"kind": "walk", "unit": actor.id, "from": from, "path": route,
			})
		_ap_event(res, actor, ap_before)
		for event: Dictionary in sub.dice_events:
			# The neutral turn already supplies this walk, at neutral playback speed.
			# Appending the resolver walk again rewinds the unit to the same start.
			if not route.is_empty() and event.get("kind", "") == "walk" and int(event.get("unit", -1)) == actor.id:
				continue
			res.dice_events.append(event)
		res.log_lines.append_array(sub.log_lines)
		res.deaths.append_array(sub.deaths)
		# Косметика жителя — ТА ЖЕ, что у любого другого стрелка (item 5): дорожка «кто в
		# кого», трассер, гильзы, кровь. Этой строки здесь не было, и весь список fx
		# подслота молча выбрасывался: мирные стреляли в полной тишине, и по экрану нельзя
		# было понять, откуда прилетело.
		res.fx.append_array(sub.fx)
		# Shown right here in the stream (playtest 2026-10-19): a raider's shot plays from
		# where it stood, before its next move, not after the whole turn has walked past.
		if not sub.fx.is_empty():
			res.dice_events.append({"kind": "effects", "fx": sub.fx,
					"deaths": sub.deaths.duplicate(), "visual_deaths": sub.visual_deaths.duplicate()})
	# hold идёт ПЕРВЫМ во всём слоте (item 23): Main по нему снимает всех ходоков в их
	# стартовые клетки разом, а уже потом проигрывает шаги и выстрелы по порядку.
	if not moved_from.is_empty():
		res.dice_events.push_front({"kind": "hold", "units": moved_from})
	if not acted.is_empty():
		res.log_lines.push_front("- %s take their turn (%d active) -" % [
			MCF.owner_name(owner) if raiders else "Civilians", acted.size()])
	return res

## Клетки, по которым житель пройдёт, если приказ — движение; иначе пусто. Нужно ровно
## для анимации (#96): состояние резолвер поменяет и без этого, но игрок должен видеть
## проход, а не прыжок.
func _civilian_route(actor: UnitInstance, intent: Intent) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not (intent is MoveIntent):
		return empty
	var budget: int = actor.move_credit if actor.move_credit > 0 else actor.speed()
	if budget <= 0:
		return empty
	var reach := reachable_for(actor, budget)
	var dest: Vector2i = (intent as MoveIntent).target
	if not reach.can_reach(dest):
		return empty
	return reach.path_to(dest)

## Событие «жёлтая точка погасла» (#99). Житель отыгрывает активацию сам, и без этого
## игрок видел лишь итог: точки ОД пропадали разом, ещё до первого кубика.
func _ap_event(res: ActionResult, u: UnitInstance, before: int) -> void:
	if u.remaining_ap == before:
		return
	res.dice_events.append({
		"kind": "ap", "unit": u.id, "from": before, "left": u.remaining_ap,
	})

static func _airlocks_of(grid: Grid) -> Array[GridCell]:
	var coords := _feature_cells_of(grid, MCF.FEATURE_AIRLOCK)
	var gid := grid.get_instance_id()
	var rev: int = _feature_rev.get(MCF.FEATURE_AIRLOCK, 0)
	if _airlock_version == rev and _airlock_grid == gid:
		return _airlock_cells
	_airlock_cells = []
	_airlock_index = {}
	for c: Vector2i in coords:
		var cell := grid.cell(c)
		_airlock_index[cell] = _airlock_cells.size()
		_airlock_cells.append(cell)
	_airlock_version = rev
	_airlock_grid = gid
	return _airlock_cells

func _mark_airlocks_near(c: Vector2i, marks: Dictionary) -> void:
	var grid := state.grid
	if not grid.in_bounds(c):
		return
	var r: int = MCF.AIRLOCK_OPEN_RADIUS
	for y in range(maxi(0, c.y - r), mini(grid.height - 1, c.y + r) + 1):
		for x in range(maxi(0, c.x - r), mini(grid.width - 1, c.x + r) + 1):
			var idx: Variant = _airlock_index.get(grid.cell_fast(x, y))
			if idx != null:
				marks[idx] = true

func _airlock_candidates(cells: Array[GridCell]) -> Array[GridCell]:
	var grid := state.grid
	# Где стоят живые бойцы сейчас — и сравнение с прошлым разом (batch mp-perf): створки
	# могут поменяться только у шлюзов рядом с тем, кто сдвинулся, появился или выбыл.
	# Раньше на каждый вызов перебирались девять клеток вокруг КАЖДОГО бойца карты —
	# на армиях в полтысячи это было ~7 мс на каждый шаг каждого бойца.
	var moved: Array = []   # [клетка до или null, клетка после или null]
	var units := state.all_units()
	if is_same(units, _al_units) and _al_world == UnitInstance.vision_world:
		for u: UnitInstance in units:
			if u.vision_stamp <= _al_epoch:
				continue
			var was: Variant = _al_pos.get(u.id)
			var now: Variant = u.coord if not u.is_drone and u.is_alive() else null
			if was == now:
				continue
			moved.append([was, now])
			if now == null:
				_al_pos.erase(u.id)
			else:
				_al_pos[u.id] = now
	else:
		var pos := {}
		for u: UnitInstance in units:
			if not u.is_drone and u.is_alive():
				pos[u.id] = u.coord
		for id: int in pos:
			var was: Variant = _al_pos.get(id)
			if was == null or was != pos[id]:
				moved.append([was, pos[id]])
		for id: int in _al_pos:
			if not pos.has(id):
				moved.append([_al_pos[id], null])
		_al_pos = pos
	_al_units = units
	_al_world = UnitInstance.vision_world
	_al_epoch = UnitInstance.vision_epoch
	if _al_grid != grid.get_instance_id() or _al_fv != _airlock_version \
			or _al_vv < GridCell.vision_log_base or check_everything:
		return cells
	var marks := {}
	for c: GridCell in _al_open:
		var idx: Variant = _airlock_index.get(c)
		if idx != null:
			marks[idx] = true
	var changes := GridCell.vision_changes
	var i: int = (_al_vv - GridCell.vision_log_base) * 2
	while i < changes.size():
		var idx: Variant = _airlock_index.get(grid.cell(Vector2i(changes[i], changes[i + 1])))
		if idx != null:
			marks[idx] = true
		i += 2
	for m: Array in moved:
		if m[1] != null:
			_mark_airlocks_near(m[1], marks)
		if m[0] != null:
			_mark_airlocks_near(m[0], marks)
	var order: Array = marks.keys()
	order.sort()
	var out: Array[GridCell] = []
	for k: int in order:
		out.append(cells[k])
	return out

## Створки смотрят на СВОИХ соседей, а не перебирают армию (#106). «Кто-то стоит в
## радиусе 1» — это ровно «в одной из девяти клеток вокруг есть жилец», и клеток всегда
## девять, сколько бы народу ни было на карте. Прежний перебор стоил (шлюзы × юниты)
## дистанций на КАЖДОЕ действие: при трёх десятках дверей и трёх сотнях бойцов это
## десять тысяч замеров за ход одного человека и треть всего времени резолвера.
##
## Правило то же с точностью до буквы: жилец должен быть ЖИВ (мёртвый лежит в клетке
## трупом и дверь ему не открывают) и не дроном (машина в воздухе створок не трогает).
## Сидящий в технике сюда не попадает сам собой: у него coord = OFFBOARD и клетки нет.
## Pair only the enclosed, one-tile chambers leading to vacuum. Interior doors retain
## their usual proximity behavior; the pairing survives save/load without hidden state.
func _pressure_partner(cell: GridCell) -> GridCell:
	var grid := state.grid
	for d: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		var other := grid.cell(cell.coord + d * 2)
		var middle := grid.cell(cell.coord + d)
		if other == null or other.feature_id != MCF.FEATURE_AIRLOCK or middle == null or middle.is_space: continue
		var side := Vector2i(d.y, -d.x)
		var a := grid.cell(middle.coord + side)
		var b := grid.cell(middle.coord - side)
		if a == null or b == null or a.cover_height < MCF.WALL_HEIGHT or b.cover_height < MCF.WALL_HEIGHT: continue
		var outside := grid.cell(other.coord + d)
		var behind := grid.cell(cell.coord - d)
		if (outside != null and outside.is_space) or (behind != null and behind.is_space): return other
	return null

func _door_distance(cell: GridCell) -> int:
	var nearest := 999999
	for y in range(maxi(0, cell.coord.y - 2), mini(state.grid.height, cell.coord.y + 3)):
		for x in range(maxi(0, cell.coord.x - 2), mini(state.grid.width, cell.coord.x + 3)):
			var unit := state.grid.cell_fast(x, y).occupant
			if unit != null and unit.is_alive() and not unit.is_drone:
				nearest = mini(nearest, absi(x - cell.coord.x) + absi(y - cell.coord.y))
	return nearest

func update_airlocks() -> void:
	var cells := _airlocks_of(state.grid)
	if cells.is_empty():
		return
	if not check_everything and _al_done == _airlock_inputs() and is_same(_al_done_units, state.all_units()):
		return
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	var radius: int = MCF.AIRLOCK_OPEN_RADIUS
	var still_open: Array[GridCell] = []
	var candidates := _airlock_candidates(cells)
	for cell in candidates.duplicate():
		var partner := _pressure_partner(cell)
		if partner != null and not candidates.has(partner): candidates.append(partner)
	for cell: GridCell in candidates:
		# Заваренный инженером шлюз не открывается ни для кого (#99).
		if cell.airlock_welded:
			cell.cover_height = MCF.WALL_HEIGHT
			cell.gas = false
			cell.smoke = false
			continue
		# Тело в проёме держит створки (batch 13 #4): шлюз не закроется, пока труп не
		# вытащат. Проверяется САМА клетка шлюза — труп рядом, за порогом, дверям не мешает.
		var open := corpses_at(cell.coord) > 0
		var cx := cell.coord.x
		var cy := cell.coord.y
		var y := maxi(0, cy - radius)
		var y_end := mini(gh - 1, cy + radius)
		var x_end := mini(gw - 1, cx + radius)
		var x0 := maxi(0, cx - radius)
		while y <= y_end and not open:
			var x := x0
			while x <= x_end:
				var occ: UnitInstance = grid.cell_fast(x, y).occupant
				if occ != null and occ.is_alive() and not occ.is_drone:
					open = true
					break
				x += 1
			y += 1
		var partner := _pressure_partner(cell)
		if open and partner != null and not partner.airlock_welded and corpses_at(cell.coord) == 0 and cell.occupant == null:
			var mine := _door_distance(cell)
			var theirs := _door_distance(partner)
			var earlier := cell.coord.y < partner.coord.y or (cell.coord.y == partner.coord.y and cell.coord.x < partner.coord.x)
			open = corpses_at(partner.coord) == 0 and partner.occupant == null and (mine < theirs or (mine == theirs and earlier))
		var was_closed := cell.cover_height >= MCF.WALL_HEIGHT
		cell.cover_height = 0.0 if open else MCF.WALL_HEIGHT
		if not open:
			cell.gas = false
			cell.smoke = false
		# Открывшийся шлюз — повод активации соседних нейтралов (§3.1a): именно так в
		# примере из задания игрок «вскрывает комнату», подойдя к её двери.
		if open and was_closed:
			notify_cell_changed(cell.coord)
		if open:
			still_open.append(cell)
	_al_open = still_open
	_al_vv = GridCell.vision_version
	_al_fv = _airlock_version
	_al_grid = grid.get_instance_id()
	_al_done = _airlock_inputs()
	_al_done_units = state.all_units()

## What the doors read: occupants, bodies, features and heights (walk_version), space (look),
## who is alive where (the units' vision epochs and list), on this grid.
func _airlock_inputs() -> Array:
	return [state.grid.get_instance_id(), GridCell.walk_version, GridCell.look_version,
		GridCell.vision_version, UnitInstance.vision_epoch, UnitInstance.vision_world, _airlock_version]

## Отдача/отбрасывание после выстрела в невесомости (§3.11). Только для юнитов,
## стоящих в клетке-космосе, и только если позади свободно на всю дистанцию.
## Пассажир челнока (batch 13) пристёгнут к креслу: его не отбрасывает ни отдачей, ни
## попаданием — иначе он вылетал бы из корпуса, оставаясь «на борту» с занятым креслом.
func _apply_zero_g(shooter: UnitInstance, target: UnitInstance, res: ActionResult = null) -> void:
	# Стрелка отбрасывает назад (от цели).
	_recoil_shooter(shooter, target.coord, res)
	# Цель отбрасывает дальше (от стрелка).
	if target.is_alive() and target.aboard_vehicle_id == -1 \
			and state.grid.cell(target.coord).is_space:
		var away := _step_toward(shooter.coord, target.coord)
		_knockback(target, away, MCF.ZEROG_TARGET_KNOCKBACK, res)

## Отдача стрелка в невесомости: на клетку назад, прочь от точки прицела, — если позади
## свободно. Общая для всех выстрелов (batch group-zones): раньше её получали только
## винтовка и штурмовик, а заряд ПТ, струя, лазер и выстрел по окну стрелка не двигали.
func _recoil_shooter(shooter: UnitInstance, aim: Vector2i, res: ActionResult = null) -> void:
	if shooter.is_alive() and shooter.aboard_vehicle_id == -1 \
			and state.grid.in_bounds(shooter.coord) and state.grid.cell(shooter.coord).is_space:
		_knockback(shooter, _step_toward(aim, shooter.coord), MCF.ZEROG_SHOOTER_KNOCKBACK, res)

## Результат спецвыстрела с отдачей стрелка (если выстрел состоялся).
func _recoiled(result: ActionResult, shooter: UnitInstance, aim: Vector2i) -> ActionResult:
	if result.ok:
		_recoil_shooter(shooter, aim, result)
	return result

## Машина, корпус которой занимает клетку: по следу на сетке, а борг — по своей клетке
## (у борга с пилотом следа на сетке нет — в клетке стоит пилот). Живая или остов.
func vehicle_covering(c: Vector2i) -> Vehicle:
	var vid := state.grid.vehicle_at(c)
	if vid != -1:
		return state.get_vehicle(vid)
	for veh: Vehicle in state.all_vehicles():
		if veh.is_borg() and veh.origin == c:
			return veh
	return null

## Сдвиг юнита на dist клеток по step, но только если ВСЕ клетки свободны (иначе нет).
func _knockback(unit: UnitInstance, step: Vector2i, dist: int, res: ActionResult = null) -> void:
	if step == Vector2i.ZERO:
		return
	var dest := unit.coord
	for _i in dist:
		var next := dest + step
		if not state.grid.in_bounds(next) or state.grid.is_occupied_or_wall(next):
			return  # позади не свободно — отбрасывания нет
		dest = next
	_slide(unit, dest, res)
