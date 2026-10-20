@abstract
extends "res://src/resolver/parts/ResolverState.gd"

## Sight: one soldier's view (the octant sweep), the side's view, fog of war, gas and smoke
## in the way.

# --- Туман войны (§3.9) ---

## Радиус обзора юнита (свой параметр или значение по умолчанию).
## Радиус обзора юнита. По item 46 обзор НИЧЕМ не ограничен по дальности — он идёт,
## пока луч не упрётся в стену, — поэтому по умолчанию отдаётся окно во всю карту.
## Явно прописанный в статах sight_range при этом уважается: если однажды понадобится
## близорукий юнит, менять здесь ничего не придётся.
func sight_of(unit: UnitInstance) -> int:
	# Дрон над стеной (0.11.3, просьба игрока) не видит ничего, кроме своей клетки: он
	# в толще стены, и обзор закрыт во все стороны. Обход окна радиуса 0 — одна клетка.
	if unit.is_drone and state.grid.in_bounds(unit.coord) \
			and state.grid.cell_fast(unit.coord.x, unit.coord.y).blocks_sight():
		return 0
	var s: int = unit.stats.sight_range
	return s if s > 0 else MCF.SIGHT_UNLIMITED

## Есть ли стена на луче между a и b (концы исключены) — для глаз стороны `viewer`:
## ей закрывают обзор ещё и корпуса вражеских танков (см. _tank_sig). -1 — только рельеф.
## Брезенхэм шагает здесь ЖЕ. Раньше луч строился вспомогательной _ray_cells(), которая
## возвращала МАССИВ клеток, — а туман войны делает эту проверку по разу на каждую
## клетку в радиусе обзора каждого бойца, то есть тысячи массивов на один пересчёт.
## Порядок обхода и условие обрыва буква в букву те же, что были у _ray_cells;
## сама она удалена — других вызывающих у неё не осталось.
func _vision_blocked(a: Vector2i, b: Vector2i, viewer: int = -1, through_gas: bool = false) -> bool:
	if _line_off_board(a, b):
		return true
	if not through_gas and a != b and (state.grid.cell_fast(a.x, a.y).obscured() or state.grid.cell_fast(b.x, b.y).obscured()):
		return true
	var sig := _tank_sig(viewer)
	var tanks: PackedInt32Array = _tank_sig_cells[sig] if sig != 0 else PackedInt32Array()
	var dx: int = absi(b.x - a.x)
	var dy: int = absi(b.y - a.y)
	var sx: int = 1 if a.x < b.x else -1
	var sy: int = 1 if a.y < b.y else -1
	var err: int = dx - dy
	var cx := a.x
	var cy := a.y
	var bx := b.x
	var by := b.y
	var grid := state.grid
	while cx != bx or cy != by:
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			cx += sx
		if e2 < dx:
			err += dx
			cy += sy
		if cx == bx and cy == by:
			break
		var cell := grid.cell_fast(cx, cy)
		# Стекло прозрачно (#29). Без этого пункт 29 недостижим в принципе: сквозь
		# стекло разрешено СТРЕЛЯТЬ, но цель за ним оставалась в тумане, а невидимую
		# цель нельзя выбрать (can_shoot → "Target not visible"). Строковое сравнение
		# стоит здесь дёшево: до него доходят только клетки, уже опознанные как стена.
		# Живые обзор не перекрывают, машины — тоже, КРОМЕ вражеского танка: его корпус
		# закрывает обзор противнику (не своим). Стена и закрытый шлюз — GridCell.blocks_sight().
		if (cell.obscured() and not through_gas) \
				or (cell.cover_height >= MCF.WALL_HEIGHT and not MCF.is_glass(cell.feature_id)):
			return true
		if not tanks.is_empty() and tanks.has(cy * grid.width + cx):
			return true
	return false
func team_sees_gas(owner: int) -> Dictionary:
	var hit: Array = _gas_seen.get(owner, [])
	if not hit.is_empty() and hit[0] == UnitInstance.vision_epoch and hit[1] == GridCell.vision_version:
		return hit[2]
	_sync_seen()
	var out := {}
	if not _sight_gas.is_empty():
		var gw := state.grid.width
		var sides := _vision_sides(owner)
		var eyes: Array = []   # [клетка, дальность по Чебышёву]
		for u in state.all_units():
			if u.is_alive() and sides.has(u.owner) and u.aboard_vehicle_id == -1:
				eyes.append([u.coord, sight_of(u)])
		for veh: Vehicle in state.all_vehicles():
			if not veh.wrecked and sides.has(veh.owner) and not veh.occupants.is_empty():
				for c: Vector2i in veh.footprint():
					eyes.append([c, MCF.SIGHT_UNLIMITED])
		for i: int in _sight_gas:
			var g := Vector2i(i % gw, i / gw)
			for e: Array in eyes:
				var at: Vector2i = e[0]
				if maxi(absi(at.x - g.x), absi(at.y - g.y)) <= int(e[1]) \
						and not _vision_blocked(at, g, owner, true):
					out[g] = true
					break
	_gas_seen[owner] = [UnitInstance.vision_epoch, GridCell.vision_version, out]
	return out

## Видит ли команда владельца эту клетку (общая видимость, §3.9).
##
## Ответ берётся из готового множества team_visible_coords() — это ТО ЖЕ САМОЕ объединение
## _unit_sees() по живым бойцам стороны, только посчитанное один раз и переиспользуемое.
## Прежний вариант перебирал всю армию с лучом Брезенхэма на каждого, а вызывают его из
## can_shoot() по разу НА КАЖДУЮ возможную цель: в бою на 200 бойцов один только показ
## доступных целей выливался в десятки тысяч лучей (≈6 мс на юнита).
##
## Клетки вне поля в множество не попадают, и это правильно: _unit_sees() отсеял бы их
## проверкой дальности (у сидящего в машине coord вынесен далеко за карту, §техника).
##
## Спрашивают ОДНУ клетку, а строили множество на всю армию (#106). Каждый выстрел зовёт
## сюда через can_shoot(), а к моменту выстрела кто-нибудь уже успел походить — значит
## vision_epoch сменился, и готовое множество приходилось досчитывать: проход по всей
## стороне с перестройкой обзора тем, кто сдвинулся. В бою на 300 бойцов это 10 мс НА
## ВЫСТРЕЛ и 95% всего времени резолвера.
##
## Поэтому: множество берём, только если оно и так уже актуально (те же три сверки, что
## и в team_visible_coords). Иначе отвечаем напрямую — «видит ли хоть кто-то свой эту
## клетку», с выходом на первом же увидевшем.
##
## Ответ тот же с точностью до буквы. _seen_from() кладёт клетку в обзор бойца ровно при
## двух условиях: она внутри окна радиуса r по Чебышёву и луч Брезенхэма из бойца в неё
## не встретил стены или корпуса машины. Здесь проверяются те же два, а _vision_blocked()
## — та же самая арифметика луча, что развёрнута внутри _seen_from(). Множество же
## команды — просто объединение этих обзоров, то есть «хоть один боец».
## Клетки вне поля не видит никто: их отбрасывает окно обхода в _seen_from().
## Один вопрос — один ответ: множество строит team_visible_coords(), а это просто
## взгляд в него. Здесь ЖИЛА вторая, самостоятельная реализация того же обхода — и
## именно она разошлась с первой на item 46: обзор техники добавили в множество, а
## быстрый путь по-прежнему перебирал только пеших, и танк в проёме «не видел».
## Считать одно и то же дважды нельзя; вопрос производительности закрыт кешем внутри
## team_visible_coords, который на прогретом состоянии стоит три сравнения целых.
## Gas obscures vision even with ordinary fog disabled. Reuse the incremental
## sight index so checking this never scans the whole board per target.
func visibility_limited() -> bool:
	if fog_enabled: return true
	if GridCell.obscurants() <= 0: return false
	_sync_seen()
	return not _sight_gas.is_empty()
func _gas_masks() -> Array:
	_sync_seen()   # _sight_gas is static: make sure it describes this board
	var grid := state.grid
	if _gas_masks_version != GridCell.vision_version or _gas_masks_grid != grid.get_instance_id():
		var mask := PackedByteArray()
		mask.resize(grid.width * grid.height)
		for i: int in _sight_gas: mask[i] = 1
		_gas_masks_cache = [mask, _transpose(mask, grid.width, grid.height)]
		_gas_masks_version = GridCell.vision_version
		_gas_masks_grid = grid.get_instance_id()
	return _gas_masks_cache

func team_sees(owner: int, coord: Vector2i) -> bool:
	if not state.grid.in_bounds(coord): return false
	if state.grid.cell(coord).obscured(): return false
	if not visibility_limited(): return true
	return team_visible_coords(owner).has(coord)

## Radio contact keeps our own soldiers visible, including those inside gas.
func is_visible_to_team(owner: int, target: UnitInstance) -> bool:
	if owner == target.owner or state.roster.are_allies(owner, target.owner): return true
	if not state.grid.in_bounds(target.coord): return false
	if state.grid.cell(target.coord).obscured(): return false
	# The scripted AI ignores fog: one cloud anywhere must not blind it to the whole
	# board. It still can't see into gas (above) or shoot through it (can_shoot).
	if owner == omniscient_side: return true
	return team_sees(owner, target.coord)

## Пересобрать таблицу блокировщиков по текущему рельефу. Условие — в точности то,
## что проверяет луч: стена (высота 2), но не стекло; корпус машины луч не рвёт.
static func _rebuild_blockers(grid: Grid) -> void:
	_sight_gas.clear()
	var gw := grid.width
	var gh := grid.height
	_blockers.resize(gw * gh)
	_blockers.fill(0)
	_blockers_t.resize(gw * gh)
	_blockers_t.fill(0)
	for y in gh:
		var row := y * gw
		for x in gw:
			var cell := grid.cell_fast(x, y)
			# Ровно то же условие, что у поправки по журналу (_patch_blockers) — одним
			# вопросом к клетке, чтобы газ (0.9.4) не выпал из холодной сборки таблицы.
			if cell.obscured():
				_sight_gas[row + x] = true
			if cell.blocks_sight():
				_blockers[row + x] = 1
				_blockers_t[x * gh + y] = 1

## Положить обзор в кеш. Кеш держится в порядке давности использования (попадание
## переставляет запись в конец), и переполненный теряет самые давние записи, а не
## обнуляется целиком: иначе раз в пару сотен шагов вся армия пересчитывала бы обзор разом.
static func _store_seen(key: Vector4i, out: PackedInt32Array, sens: PackedInt32Array) -> void:
	_seen_cache[key] = out
	_seen_sens[key] = sens
	_seen_cells += out.size() + sens.size()
	if _seen_cache.size() <= SEEN_CACHE_CAP and _seen_cells <= SEEN_CELLS_CAP:
		return
	for old: Vector4i in _seen_cache.keys():
		if _seen_cache.size() <= SEEN_CACHE_CAP / 2 and _seen_cells <= SEEN_CELLS_CAP / 2:
			break
		_drop_seen(old)

static func _drop_seen(key: Vector4i) -> void:
	_seen_cells -= (_seen_cache[key] as PackedInt32Array).size() \
			+ (_seen_sens.get(key, PackedInt32Array()) as PackedInt32Array).size()
	_seen_cache.erase(key)
	_seen_sens.erase(key)

static func _clear_seen() -> void:
	_seen_cache.clear()
	_seen_sens.clear()
	_seen_cells = 0

## Попадание: запись переезжает в конец порядка давности.
static func _touch_seen(key: Vector4i, hit: PackedInt32Array) -> void:
	_seen_cache.erase(key)
	_seen_cache[key] = hit

## Поправить таблицу стен по журналу обзора: только клетки, пересекавшие порог стены
## после версии from_version. Журнал общий на все сетки, поэтому клетку перечитываем с
## НАШЕЙ сетки — чужая запись просто перепроверит свою же клетку.
static func _patch_blockers(grid: Grid, from_version: int) -> void:
	var changes := GridCell.vision_changes
	var gw := grid.width
	var i: int = (from_version - GridCell.vision_log_base) * 2
	while i < changes.size():
		var c := grid.cell(Vector2i(changes[i], changes[i + 1]))
		if c != null:
			var idx := c.coord.y * gw + c.coord.x
			if c.obscured():
				_sight_gas[idx] = true
			else:
				_sight_gas.erase(idx)
			var b := 1 if c.blocks_sight() else 0
			_blockers[c.coord.y * gw + c.coord.x] = b
			_blockers_t[c.coord.x * grid.height + c.coord.y] = b
		i += 2

## Клетки, видимые с coord при радиусе r. Порядок — dy снаружи, dx внутри, оба по
## возрастанию: тот же, в котором их складывал прежний двойной цикл team_visible_coords.
##
## Правило видимости (решение M4) не изменилось: обзор площадной, в радиусе по Чебышёву,
## стены (высота 2) и корпуса машин рвут луч Брезенхэма, живые юниты — нет. Прежняя
## _unit_sees() делала ровно эти две проверки по одной клетке; здесь дальность соблюдена
## самим окном обхода, поэтому от неё осталась только проверка луча.
## Догнать кеш до текущего рельефа. Запись «что видно из (x,y) в радиусе r» зависит
## только от клеток внутри её же окна: луч Брезенхэма из центра в клетку окна за пределы
## окна не выходит. Поэтому изменение в клетке (cx, cy) обесценивает ровно те записи,
## чьё окно её накрывает, — остальные остаются в силе. Из-за этого рухнувшая стена стоит
## пересчёта обзора нескольким бойцам, а не всей армии.
##
## Точнее окна — список чувствительных клеток записи (_sweep): при безграничном обзоре
## окно у всех — вся карта, а стену в тени чужих стен обзор просто не замечает.
static func _catch_up_seen(from_version: int, gw: int) -> void:
	var changes := GridCell.vision_changes
	var at := PackedInt32Array()
	var i: int = (from_version - GridCell.vision_log_base) * 2
	while i < changes.size():
		at.append(changes[i + 1] * gw + changes[i])
		i += 2
	var doomed: Array = []
	for key: Vector4i in _seen_cache:
		var sens: PackedInt32Array = _seen_sens.get(key, PackedInt32Array())
		for v: int in at:
			var k := sens.bsearch(v)
			if k < sens.size() and sens[k] == v:
				doomed.append(key)
				break
	for key: Vector4i in doomed:
		_drop_seen(key)

## Номер набора корпусов танков, враждебных стороне `viewer`; 0 — таких нет (или смотрит
## «никто»: только рельеф).
func _tank_sig(viewer: int) -> int:
	if viewer < 0:
		return 0
	var gw := state.grid.width
	var cells := PackedInt32Array()
	for veh: Vehicle in state.all_vehicles():
		if veh.type_id != "tank" or veh.wrecked or not veh.alive():
			continue
		if veh.owner == viewer or state.roster.are_allies(viewer, veh.owner):
			continue
		for fc: Vector2i in veh.footprint():
			if state.grid.in_bounds(fc):
				cells.append(fc.y * gw + fc.x)
	if cells.is_empty():
		return 0
	cells.sort()
	var id: Variant = _tank_sigs.get(cells)
	if id == null:
		if _tank_sigs.size() > 4096:
			_tank_sigs.clear()
			_tank_sig_cells.clear()
		id = _tank_sig_next
		_tank_sig_next += 1
		_tank_sigs[cells] = id
		_tank_sig_cells[id] = cells
	return id

## Пара [таблица, транспонированная таблица] блокировщиков для набора `sig`: рельеф плюс
## корпуса этих танков. gh — высота сетки (для транспонированных индексов).
static func _tank_masks_of(sig: int, gh: int) -> Array:
	if sig == 0:
		return [_blockers, _blockers_t]
	var hit: Variant = _tank_masks.get(sig)
	if hit != null:
		return hit
	if _tank_masks.size() > 64:
		_tank_masks.clear()
	var mask := _blockers.duplicate()
	var mask_t := _blockers_t.duplicate()
	var gw := mask.size() / gh
	for i: int in _tank_sig_cells[sig]:
		mask[i] = 1
		mask_t[(i % gw) * gh + i / gw] = 1
	var pair := [mask, mask_t]
	_tank_masks[sig] = pair
	return pair

func _seen_from(coord: Vector2i, r: int, viewer: int = -1, gas_only: bool = false) -> PackedInt32Array:
	# Смотрящий вне поля (сидит в машине, coord = OFFBOARD) не видит ничего: лучи из
	# такой точки уходят за край сетки. Вызывающие сидящих и так пропускают — это
	# страховка на будущих вызывающих (issue 2).
	if not state.grid.in_bounds(coord):
		return PackedInt32Array()
	_sync_seen()
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	# Неограниченный обзор (item 46) приходит сюда радиусом в тысячу клеток. Окно
	# обхода урезаем до размеров карты СРАЗУ: дальше её края смотреть некуда, а
	# перебирать четыре миллиона несуществующих клеток ради этого — нет. Обрезка
	# идёт до ключа кеша, поэтому все «безграничные» бойцы делят одну запись.
	r = mini(r, maxi(gw, gh))
	var sig := -1 if gas_only else _tank_sig(viewer)
	var key := Vector4i(coord.x, coord.y, r, sig)
	var hit: Variant = _seen_cache.get(key)
	if hit != null:
		_touch_seen(key, hit)
		return hit
	var same: Variant = null if gas_only else _reuse_under(key, viewer)
	if same != null:
		return same
	var origin := coord.y * gw + coord.x
	if grid.cell_fast(coord.x, coord.y).obscured():
		var own := PackedInt32Array([origin])
		_store_seen(key, own, own)
		return own
	var masks := _gas_masks() if gas_only else _tank_masks_of(sig, gh)
	var res := _sweep(coord.x, coord.y, r, masks[0], gw, gh, masks[1])
	# A wall face is visible; a gas-filled cell conceals its occupants. Keep the
	# sweep and its incremental invalidation, filtering only while gas exists.
	if not _sight_gas.is_empty():
		var clear := PackedInt32Array()
		var cells := grid.cells_flat()
		for i: int in res[0]:
			if not cells[i].obscured():
				clear.append(i)
		res[0] = clear
	# Gas arriving on the observer must invalidate an otherwise unchanged view.
	var sens: PackedInt32Array = res[1]
	sens.insert(sens.bsearch(origin), origin)
	_store_seen(key, res[0], sens)
	return res[0]

func _reuse_under(key: Vector4i, viewer: int) -> Variant:
	var hist: Array = _sig_history.get(viewer, [])
	if hist.is_empty() or hist[hist.size() - 1] != key.w:
		hist.erase(key.w)
		hist.append(key.w)
		if hist.size() > SIG_HISTORY:
			hist.pop_front()
		_sig_history[viewer] = hist
	var now: Variant = _tank_sig_cells.get(key.w, PackedInt32Array() if key.w == 0 else null)
	if now == null:
		return null
	for h in range(hist.size() - 2, -1, -1):
		var prev: int = hist[h]
		var old_key := Vector4i(key.x, key.y, key.z, prev)
		var old: Variant = _seen_cache.get(old_key)
		if old == null:
			continue
		var was: Variant = _tank_sig_cells.get(prev, PackedInt32Array() if prev == 0 else null)
		if was == null:
			continue   # реестр наборов обнулялся — разницы не узнать
		var sens: PackedInt32Array = _seen_sens.get(old_key, PackedInt32Array())
		if _touches(was, now, sens) or _touches(now, was, sens):
			continue
		_store_seen(key, old, sens)
		return old
	return null

## Есть ли среди клеток mine, которых нет в other, хоть одна из sens (все по возрастанию).
static func _touches(mine: PackedInt32Array, other: PackedInt32Array,
		sens: PackedInt32Array) -> bool:
	for c: int in mine:
		var o := other.bsearch(c)
		if o < other.size() and other[o] == c:
			continue   # клетка корпуса и там и там — не перемена
		var k := sens.bsearch(c)
		if k < sens.size() and sens[k] == c:
			return true
	return false

## Догнать кеш обзора до текущего рельефа (см. _catch_up_seen): сброс целиком — только
## когда точечная инвалидация невозможна (сменилась сетка, либо наша версия старше
## журнала — он обнулялся); иначе выкидываются ровно задетые записи.
func _sync_seen() -> void:
	var gid := state.grid.get_instance_id()
	if _seen_version == GridCell.vision_version and _seen_grid == gid:
		return
	if _seen_grid != gid or _seen_version < GridCell.vision_log_base:
		_clear_seen()
		_rebuild_blockers(state.grid)
	else:
		_catch_up_seen(_seen_version, state.grid.width)
		# Таблица стен — тоже адресно: открывшийся шлюз правит один байт, а не
		# пересобирает 62 500 клеток карты 250×250.
		_patch_blockers(state.grid, _seen_version)
	_seen_version = GridCell.vision_version
	_seen_grid = gid
	_tank_masks.clear()   # маски — рельеф плюс танки: рельеф сменился

## Что видно из (ux, uy) в радиусе r по Чебышёву при таблице блокировщиков blk. Это
## ТО ЖЕ САМОЕ множество, что давал луч Брезенхэма в каждую клетку окна (_vision_blocked),
## и в том же порядке — строки сверху вниз, в строке слева направо. Только быстрее.
##
## Почему можно. Этот Брезенхэм (err = dx − dy; шаг по x при 2·err > −dy, по y при
## 2·err < dx) зависит лишь от смещения цели, и в октанте |dx| ≥ |dy| его клетка в
## столбце i — ровно (i, ⌈i·s − ½⌉), s = |dy|/|dx|: наклон, округлённый с половиной ВНИЗ
## (в октанте |dy| > |dx| — то же с осями наоборот, знаки — зеркало). Значит, стена в
## столбце i, ряду j закрывает ровно те цели дальше столбца i, чей наклон лежит в
## ((2j−1)/2i, (2j+1)/2i]. Идём по столбцам наружу и держим отсортированный список
## закрытых промежутков наклона; цель в столбце a видна, если её b/a ни в один не попал.
## Всё — в целых числах (дроби сравниваются крест-накрест), поэтому совпадение точное, а
## не «почти»: tests/run_fog.gd сверяет с буквальным лучом на сотнях случайных полей.
##
## Цена — одна проверка на клетку вместо луча, а в застроенном месте октант обрывается, как
## только закрыты все наклоны. Поле 250×250 с безграничным обзором: десятки миллисекунд на
## бойца вместо сотен.
static func _sweep_seen(ux: int, uy: int, r: int, blk: PackedByteArray, gw: int,
		gh: int) -> PackedInt32Array:
	return _sweep(ux, uy, r, blk, gw, gh)[0]

## Сам обход: [видимые клетки, чувствительные клетки] — оба списка плоских индексов по
## возрастанию. Чувствительная — клетка, от стены на которой (или её сноса) этот обзор
## может измениться: её промежуток наклонов ((2j−1)/2a, (2j+1)/2a] не лежит целиком в
## тени ближних стен. Остальные клетки — в чужой тени целиком, и что бы с ними ни
## случилось, отсюда видно то же самое. По этому списку журнал обзора решает, чью запись
## в кеше выбрасывать (_catch_up_seen): при безграничном обзоре окно каждого бойца — вся
## карта, и без него каждый открывшийся шлюз обнулял обзор всей армии.
##
## Строго: если после смены клетки c в столбце i цель t дальше неё стала (не)видна, луч
## к t проходит через c, а всё до c на нём свободно. Тогда наклон t открыт в столбце i и
## лежит в промежутке c — промежуток не в тени, и c отмечена. Клетки за столбцом, на
## котором октант закрылся целиком, не просматриваются вовсе — и не отмечаются.
static func _sweep(ux: int, uy: int, r: int, blk: PackedByteArray, gw: int,
		gh: int, blk_t: PackedByteArray = PackedByteArray()) -> Array:
	# Столбец октанта лежит сплошняком либо в самой таблице (октанты |dy| > |dx|: столбец —
	# кусок строки сетки), либо в транспонированной (|dx| ≥ |dy|: кусок столбца сетки).
	if blk_t.is_empty():
		blk_t = _transpose(blk, gw, gh)
	var origin := uy * gw + ux
	var out := PackedInt32Array([origin])
	var parts: Array = []   # куски списка чувствительных (Packed-массив в функцию — копией)
	var shared := {}   # клетки осей и диагоналей: их просматривают два октанта сразу
	# Закрытые наклоны (lo, hi] — четыре параллельных массива: числители и знаменатели.
	var lo_n := PackedInt32Array()
	var lo_d := PackedInt32Array()
	var hi_n := PackedInt32Array()
	var hi_d := PackedInt32Array()
	for oct in 8:
		var xmajor := oct < 4
		var sx := -1 if (oct & 1) != 0 else 1
		var sy := -1 if (oct & 2) != 0 else 1
		var major_step := sx
		var minor_step := sy * gw
		var major_room := (gw - 1 - ux) if sx > 0 else ux
		var minor_room := (gh - 1 - uy) if sy > 0 else uy
		if not xmajor:
			major_step = sy * gw
			minor_step = sx
			major_room = (gh - 1 - uy) if sy > 0 else uy
			minor_room = (gw - 1 - ux) if sx > 0 else ux
		var run: PackedByteArray = blk_t if xmajor else blk
		var run_dir := sy if xmajor else sx
		# Ось (b == 0) общая у двух соседних октантов — её считает «положительный».
		var b0 := 1 if ((sy < 0) if xmajor else (sx < 0)) else 0
		lo_n.clear()
		lo_d.clear()
		hi_n.clear()
		hi_d.clear()
		var amax := mini(r, major_room)
		var a := 1
		while a <= amax:
			var col := origin + major_step * a
			# Цели столбца: в октанте |dy| > |dx| строго — диагональ досталась соседу.
			var bmax := mini(a if xmajor else a - 1, minor_room)
			var jmax := mini(a, minor_room)
			var n := lo_n.size()
			# Цель b видна, если её наклон b/a не лежит ни в одном закрытом (lo, hi]: закрытый
			# прячет ровно строки a·lo < b ≤ a·hi. Промежутки упорядочены и не касаются друг
			# друга, так что видимое — просветы между их строками; каждый просвет — одна
			# арифметическая прогрессия индексов, и выписывается она разом.
			var cur := b0
			var k := 0
			while k < n and cur <= bmax:
				var bs: int = _fdiv(a * lo_n[k], lo_d[k]) + 1
				if bs > bmax:
					break
				var be: int = _fdiv(a * hi_n[k], hi_d[k])
				if be >= cur and bs <= be:
					if bs > cur:
						out.append_array(_prog(col + minor_step * cur, minor_step, bs - cur))
					cur = be + 1
				k += 1
			if cur <= bmax:
				out.append_array(_prog(col + minor_step * cur, minor_step, bmax - cur + 1))
			# Чувствительные клетки: промежуток клетки ((2j−1)/2a, (2j+1)/2a] не внутри одного
			# закрытого (закрытые слиты — «в тени целиком» и есть «внутри одного»). Закрытый
			# (lo, hi] накрывает целиком ровно строки 2a·lo + 1 ≤ 2j ≤ 2a·hi − 1.
			var a2 := 2 * a
			var js := 0
			k = 0
			while k < n and js <= jmax:
				var cs: int = -_fdiv(-(a2 * lo_n[k] + lo_d[k]), 2 * lo_d[k])
				if cs > jmax:
					break
				var ce: int = _fdiv(a2 * hi_n[k] - hi_d[k], 2 * hi_d[k])
				if ce >= js and cs <= ce:
					if cs > js:
						_sens_rows(parts, shared, col, minor_step, js, cs - 1, a)
					js = ce + 1
				k += 1
			if js <= jmax:
				_sens_rows(parts, shared, col, minor_step, js, jmax, a)
			# Стены столбца закрывают наклоны для всего, что дальше. Все — и те, что сами
			# в тени: край чужой тени бывает шире своей. Ищутся они поиском байта по
			# сплошному куску таблицы, а не перебором клеток.
			var base: int = ((ux + sx * a) * gh + uy) if xmajor else col
			var from: int = base if run_dir > 0 else base - jmax
			var seg := run.slice(from, from + jmax + 1)
			var hit := seg.find(1)
			while hit != -1:
				var j: int = hit if run_dir > 0 else jmax - hit
				# Новый промежуток ((2j−1)/2a, (2j+1)/2a] вливается в список: всё, что с ним
				# пересекается или смыкается, сливается в один.
				var nl := 2 * j - 1
				var dl := 2 * a
				var nh := 2 * j + 1
				var dh := 2 * a
				var m := lo_n.size()
				var p := 0
				while p < m and hi_n[p] * dl < nl * hi_d[p]:
					p += 1
				var q := p
				while q < m and lo_n[q] * dh <= nh * lo_d[q]:
					if lo_n[q] * dl < nl * lo_d[q]:
						nl = lo_n[q]
						dl = lo_d[q]
					if hi_n[q] * dh > nh * hi_d[q]:
						nh = hi_n[q]
						dh = hi_d[q]
					q += 1
				if q == p:
					lo_n.insert(p, nl)
					lo_d.insert(p, dl)
					hi_n.insert(p, nh)
					hi_d.insert(p, dh)
				else:
					lo_n[p] = nl
					lo_d[p] = dl
					hi_n[p] = nh
					hi_d[p] = dh
					for t in q - p - 1:
						lo_n.remove_at(p + 1)
						lo_d.remove_at(p + 1)
						hi_n.remove_at(p + 1)
						hi_d.remove_at(p + 1)
				hit = seg.find(1, hit + 1)
			# Закрыто всё от наклона 0 до 1 — дальше в этом октанте не видно ничего.
			if lo_n.size() == 1 and lo_n[0] < 0 and hi_n[0] >= hi_d[0]:
				break
			a += 1
	out.sort()
	var sens := PackedInt32Array()
	for part: PackedInt32Array in parts:
		sens.append_array(part)
	for i: int in shared:
		sens.append(i)
	sens.sort()
	return [out, sens]

## The cells _sweep would leave out of a whole-board window (r at least the board's size):
## the same octant walk and the same closed slope intervals, emitting the shadowed rows of
## each column instead of the open ones. Columns before an octant's first blocker cast no
## shadow, so the walk starts there (`blockers` lists them all); a closed octant emits its
## remaining columns whole. Cost follows the shadow, not the board.
static func _sweep_hidden(ux: int, uy: int, blk: PackedByteArray, gw: int, gh: int,
		blk_t: PackedByteArray, blockers: PackedInt32Array) -> PackedInt32Array:
	var origin := uy * gw + ux
	var out := PackedInt32Array()
	# First column holding a blocker per octant, in the walk's own search range 0 ≤ j ≤ a.
	var first := PackedInt32Array()
	first.resize(8)
	first.fill(0x7FFFFFFF)
	for g: int in blockers:
		var dx := g % gw - ux
		var dy := g / gw - uy
		for oct in 8:
			var sx := -1 if (oct & 1) != 0 else 1
			var sy := -1 if (oct & 2) != 0 else 1
			var a := dx * sx if oct < 4 else dy * sy
			var j := dy * sy if oct < 4 else dx * sx
			if a >= 1 and j >= 0 and j <= a and a < first[oct]:
				first[oct] = a
	var lo_n := PackedInt32Array()
	var lo_d := PackedInt32Array()
	var hi_n := PackedInt32Array()
	var hi_d := PackedInt32Array()
	for oct in 8:
		var xmajor := oct < 4
		var sx := -1 if (oct & 1) != 0 else 1
		var sy := -1 if (oct & 2) != 0 else 1
		var major_step := sx
		var minor_step := sy * gw
		var major_room := (gw - 1 - ux) if sx > 0 else ux
		var minor_room := (gh - 1 - uy) if sy > 0 else uy
		if not xmajor:
			major_step = sy * gw
			minor_step = sx
			major_room = (gh - 1 - uy) if sy > 0 else uy
			minor_room = (gw - 1 - ux) if sx > 0 else ux
		if first[oct] > major_room:
			continue
		var run: PackedByteArray = blk_t if xmajor else blk
		var run_dir := sy if xmajor else sx
		var b0 := 1 if ((sy < 0) if xmajor else (sx < 0)) else 0
		lo_n.clear()
		lo_d.clear()
		hi_n.clear()
		hi_d.clear()
		var closed := false
		var a: int = first[oct]
		while a <= major_room:
			var col := origin + major_step * a
			var bmax := mini(a if xmajor else a - 1, minor_room)
			if closed:
				if bmax >= b0:
					out.append_array(_prog(col + minor_step * b0, minor_step, bmax - b0 + 1))
				a += 1
				continue
			var jmax := mini(a, minor_room)
			var n := lo_n.size()
			var cur := b0
			var k := 0
			while k < n and cur <= bmax:
				var bs: int = _fdiv(a * lo_n[k], lo_d[k]) + 1
				if bs > bmax:
					break
				var be: int = _fdiv(a * hi_n[k], hi_d[k])
				if be >= cur and bs <= be:
					var hs := maxi(bs, cur)
					var he := mini(be, bmax)
					if he >= hs:
						out.append_array(_prog(col + minor_step * hs, minor_step, he - hs + 1))
					cur = be + 1
				k += 1
			var base: int = ((ux + sx * a) * gh + uy) if xmajor else col
			var from: int = base if run_dir > 0 else base - jmax
			var seg := run.slice(from, from + jmax + 1)
			var hit := seg.find(1)
			while hit != -1:
				var j: int = hit if run_dir > 0 else jmax - hit
				var nl := 2 * j - 1
				var dl := 2 * a
				var nh := 2 * j + 1
				var dh := 2 * a
				var m := lo_n.size()
				var p := 0
				while p < m and hi_n[p] * dl < nl * hi_d[p]:
					p += 1
				var q := p
				while q < m and lo_n[q] * dh <= nh * lo_d[q]:
					if lo_n[q] * dl < nl * lo_d[q]:
						nl = lo_n[q]
						dl = lo_d[q]
					if hi_n[q] * dh > nh * hi_d[q]:
						nh = hi_n[q]
						dh = hi_d[q]
					q += 1
				if q == p:
					lo_n.insert(p, nl)
					lo_d.insert(p, dl)
					hi_n.insert(p, nh)
					hi_d.insert(p, dh)
				else:
					lo_n[p] = nl
					lo_d[p] = dl
					hi_n[p] = nh
					hi_d[p] = dh
					for t in q - p - 1:
						lo_n.remove_at(p + 1)
						lo_d.remove_at(p + 1)
						hi_n.remove_at(p + 1)
						hi_d.remove_at(p + 1)
				hit = seg.find(1, hit + 1)
			if lo_n.size() == 1 and lo_n[0] < 0 and hi_n[0] >= hi_d[0]:
				closed = true
			a += 1
	return out

## ⌊p / q⌋ при q > 0 — точно, в целых (деление GDScript округляет к нулю).
static func _fdiv(p: int, q: int) -> int:
	return (p - posmod(p, q)) / q

## count индексов start, start + step, … одним массивом.
static func _prog(start: int, step: int, count: int) -> PackedInt32Array:
	if count == 1:
		return PackedInt32Array([start])
	return PackedInt32Array(range(start, start + step * count, step))

## Чувствительные строки p..q столбца: внутренние — прогрессией в список, а клетки оси
## (j = 0) и диагонали (j = a) — в общий словарь: их видят два октанта, и дважды в
## списке им не место.
static func _sens_rows(parts: Array, shared: Dictionary, col: int, step: int,
		p: int, q: int, a: int) -> void:
	if p == 0:
		shared[col] = true
		p = 1
	if q == a:
		shared[col + step * a] = true
		q = a - 1
	if p <= q:
		parts.append(_prog(col + step * p, step, q - p + 1))

## Таблица блокировщиков, транспонированная: индекс x·высота + y.
static func _transpose(blk: PackedByteArray, gw: int, gh: int) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(gw * gh)
	for y in gh:
		var row := y * gw
		for x in gw:
			if blk[row + x] != 0:
				t[x * gh + y] = 1
	return t

## Обзор машины — объединение обзоров со ВСЕХ клеток её следа (batch 13 #1). Раньше
## смотрели из origin (верхний-левый угол), а собственный корпус ещё и рвал луч: танк
## видел только вверх и влево, остальное закрывали его же клетки. Теперь корпус лучу
## не мешает, а бойницы есть по всему периметру — из-за угла выглядывает та кромка,
## которая к нему ближе. Порядок сбора детерминирован (клетки следа по строкам, внутри
## клетки — порядок _seen_from), поэтому сравнение «обзор не изменился» остаётся честным.
##
## Объединение кешируется отдельной записью (r < 0 в ключе — метка «след машины»): его
## спрашивают на каждом пересчёте тумана, а на карте 250×250 это девять обзоров по
## десятку тысяч клеток. Чувствительные клетки записи — объединение чувствительных клеток
## следа, так что журнал обзора выкидывает её ровно тогда же, когда любую из частей.
func _vehicle_seen(veh: Vehicle, gas_only: bool = false) -> PackedInt32Array:
	var cells := veh.footprint()
	if cells.size() == 1:
		return _seen_from(cells[0], MCF.SIGHT_UNLIMITED, veh.owner, gas_only)
	_sync_seen()
	var grid := state.grid
	var sig := -1 if gas_only else _tank_sig(veh.owner)
	var key := Vector4i(veh.origin.x, veh.origin.y, -1 - (veh.size.x * 1024 + veh.size.y), sig)
	var hit: Variant = _seen_cache.get(key)
	if hit != null:
		_touch_seen(key, hit)
		return hit
	var same: Variant = null if gas_only else _reuse_under(key, veh.owner)
	if same != null:
		return same
	var r := mini(MCF.SIGHT_UNLIMITED, maxi(grid.width, grid.height))
	var mark := PackedByteArray()
	mark.resize(grid.width * grid.height)
	var out := PackedInt32Array()
	var sens := PackedInt32Array()
	for c: Vector2i in cells:
		for i: int in _seen_from(c, MCF.SIGHT_UNLIMITED, veh.owner, gas_only):
			if mark[i] & 1 == 0:
				mark[i] = mark[i] | 1
				out.append(i)
		for i: int in _seen_sens.get(Vector4i(c.x, c.y, r, sig), PackedInt32Array()):
			if mark[i] & 2 == 0:
				mark[i] = mark[i] | 2
				sens.append(i)
	sens.sort()
	_store_seen(key, out, sens)
	return out

## Множество сторон, чей обзор считается обзором этой. Без команд — она одна, и
## всё слияние обзора спит, ничего не стоя.
func _vision_sides(owner: int) -> Dictionary:
	var rid := state.roster.get_instance_id()
	if _ally_roster != rid:
		_ally_sets.clear()
		_ally_roster = rid
	var cached: Variant = _ally_sets.get(owner)
	if cached != null:
		return cached
	var out := {owner: true}
	for side in state.roster.vision_sharers(owner):
		out[side] = true
	_ally_sets[owner] = out
	return out
func set_sight_positions(positions: Dictionary) -> void:
	if sight_positions == positions: return
	sight_positions = positions.duplicate()
	_vis_epoch.clear()

func team_visible_coords(owner: int) -> Dictionary:
	var mode := 1 if fog_enabled else (2 if visibility_limited() else 0)
	# Самый частый случай — «с прошлого раза не изменилось вообще ничего»: его зовут из
	# can_shoot() на каждую возможную цель. Три сверки целых чисел, и мы вышли; иначе
	# пришлось бы перебирать всю армию, сверяя обзоры, только чтобы это выяснить.
	if _vis_epoch.get(owner) == UnitInstance.vision_epoch \
			and _vis_vv.get(owner) == GridCell.vision_version and _vis_mode == mode:
		return _vis_set[owner]
	var gid := state.grid.get_instance_id()
	if _vis_grid != gid or _vis_mode != mode:
		_vis_set.clear()
		_vis_counts.clear()
		_vis_seen.clear()
		_vis_epoch.clear()
		_vis_vv.clear()
		_vis_log.clear()   # всё видимое собирается заново — перерисовывать всё
		_gas_view.clear()
		_vis_grid = gid
		_vis_mode = mode
	if mode == 0:
		# Туман выключен — видно всё поле. Множество не зависит ни от кого и строится
		# один раз на всю сетку.
		var full: Dictionary = _vis_set.get(owner, {})
		if full.is_empty():
			for y in state.grid.height:
				for x in state.grid.width:
					full[Vector2i(x, y)] = true
			_vis_set[owner] = full
		_vis_epoch[owner] = UnitInstance.vision_epoch
		_vis_vv[owner] = GridCell.vision_version
		return full
	if mode == 2:
		var by_shadows: Variant = _team_visible_gas(owner)
		if by_shadows != null:
			return by_shadows
		if _gas_view.has(owner):
			# Someone's window got smaller than the board: start the per-soldier path afresh.
			_gas_view.erase(owner)
			_vis_set.erase(owner)
			_vis_counts.erase(owner)
			_vis_seen.erase(owner)
			_vis_log.erase(owner)

	var out: Dictionary = _vis_set.get(owner, {})
	var gw := state.grid.width
	# Счётчики — плоский массив по клеткам, а не словарь: на карте 250×250 обзор одного
	# бойца — десятки тысяч клеток, и шаг такого бойца стоил столько же операций словаря.
	var counts: PackedInt32Array = _vis_counts.get(owner, PackedInt32Array())
	if counts.size() != gw * state.grid.height:
		counts.resize(gw * state.grid.height)
		counts.fill(0)
	var seen: Dictionary = _vis_seen.get(owner, {})
	var memory: Dictionary = explored.get(owner, {})
	var log: Variant = _vis_log.get(owner)
	if log != null and log.size() > counts.size():
		_vis_log.erase(owner)   # никто не забирал — дешевле перерисовать всё
		log = null
	var live: Dictionary = {}
	var sides := _vision_sides(owner)
	for u in state.all_units():
		if not u.is_alive() or not sides.has(u.owner):
			continue
		# Экипаж В МАШИНЕ вынесен за карту (coord = OFFBOARD, −9999): его обзор даёт сама
		# машина ниже. Раньше пассажир всё равно попадал в _seen_from(), и луч Брезенхэма
		# из −9999 индексировал сетку по отрицательному адресу — «out of bounds get index»
		# при мультивыборе с посаженным юнитом (item 5). Пропускаем сидящих.
		if u.aboard_vehicle_id != -1:
			continue
		live[u.id] = true
		var fresh := _seen_from(sight_positions.get(u.id, u.coord), sight_of(u), u.owner, mode == 2)
		var was: Variant = seen.get(u.id)
		# Обзор этого бойца не изменился — его вклад уже в счётчиках, и трогать нечего.
		# На обычном ходу так отсеиваются 99 бойцов из 100.
		if was != null and was == fresh:
			continue
		counts = _vis_add(fresh, counts, out, memory, gw, log)
		if was != null:
			counts = _vis_drop(was, counts, out, gw, log)
		seen[u.id] = fresh
	# Техника тоже смотрит (item 46): обзор стороны — объединение ВСЕХ её глаз, а не
	# только пеших. Экипаж внутри вынесен за карту и своего обзора не даёт, так что
	# без этого прохода танк ехал бы вслепую. Ключ отрицательный, чтобы не столкнуться
	# с id юнитов в тех же словарях: у машин своя нумерация с нуля.
	for veh: Vehicle in state.all_vehicles():
		if veh.wrecked or not sides.has(veh.owner):
			continue
		# Смотрит ЭКИПАЖ, а не железо (batch 13 #1): пустая машина — слепая.
		if veh.occupants.is_empty():
			continue
		var vkey := -1 - veh.id
		live[vkey] = true
		var vfresh := _vehicle_seen(veh, mode == 2)
		var vwas: Variant = seen.get(vkey)
		if vwas != null and vwas == vfresh:
			continue
		counts = _vis_add(vfresh, counts, out, memory, gw, log)
		if vwas != null:
			counts = _vis_drop(vwas, counts, out, gw, log)
		seen[vkey] = vfresh
	# Выбывшие — погиб, сел в машину, попал в плен, машину сожгли: снимаем их вклад.
	var gone: Array = []
	for uid: int in seen:
		if not live.has(uid):
			gone.append(uid)
	for uid: int in gone:
		counts = _vis_drop(seen[uid], counts, out, gw, log)
		seen.erase(uid)
	_vis_set[owner] = out
	_vis_counts[owner] = counts
	_vis_seen[owner] = seen
	_vis_epoch[owner] = UnitInstance.vision_epoch
	_vis_vv[owner] = GridCell.vision_version
	explored[owner] = memory
	return out

## Вклад одного обзора в счётчики стороны. Сначала ПРИБАВЛЯЕТСЯ новый обзор, потом
## вычитается прежний: клетки, видные и до шага, и после, так и не падают до нуля и не
## выходят из множества, чтобы тут же вернуться. Порядок ключей множества от этого
## другой, но его никто не перебирает — все спрашивают только has().
##
## Память разведки (item 46) пополняется здесь же, на переходе клетки 0 → 1: в видимое
## клетка попадает только так, и прежний проход по ВСЕМУ видимому после каждого
## пересчёта (десятки тысяч клеток на большой карте) давал ровно то же множество.
## Packed-массив в GDScript передаётся копией, поэтому счётчики возвращаются.
func _vis_add(cells: PackedInt32Array, counts: PackedInt32Array, out: Dictionary,
		memory: Dictionary, gw: int, log: Variant) -> PackedInt32Array:
	for i: int in cells:
		var n: int = counts[i]
		counts[i] = n + 1
		if n == 0:
			var c := Vector2i(i % gw, i / gw)
			out[c] = true
			memory[c] = true
			if log != null:
				log.append(i)
	return counts

func _vis_drop(cells: PackedInt32Array, counts: PackedInt32Array, out: Dictionary,
		gw: int, log: Variant) -> PackedInt32Array:
	for i: int in cells:
		var n: int = counts[i] - 1
		counts[i] = n
		if n == 0:
			out.erase(Vector2i(i % gw, i / gw))
			if log != null:
				log.append(i)
	return counts

func _team_visible_gas(owner: int) -> Variant:
	var grid := state.grid
	var gw := grid.width
	var full_r := maxi(gw, grid.height)
	# The same eyes as the per-soldier path, with the same windows (_seen_from, _vehicle_seen).
	var eyes: Array = []   # [cell, window radius]
	var sides := _vision_sides(owner)
	for u in state.all_units():
		if u.is_alive() and sides.has(u.owner) and u.aboard_vehicle_id == -1:
			eyes.append([sight_positions.get(u.id, u.coord), mini(sight_of(u), full_r)])
	for veh: Vehicle in state.all_vehicles():
		if not veh.wrecked and sides.has(veh.owner) and not veh.occupants.is_empty():
			for c: Vector2i in veh.footprint():
				eyes.append([c, full_r])
	var big := PackedInt32Array()   # eyes that see the whole board but for their shadows
	var small := {}   # eyes that see only their own cell: inside a cloud, or a drone over a wall
	for e: Array in eyes:
		var c: Vector2i = e[0]
		if not grid.in_bounds(c):
			continue
		var r: int = e[1]
		if r > 0 and r < full_r:
			return null
		if r == 0 or grid.cell_fast(c.x, c.y).obscured():
			small[c.y * gw + c.x] = true
		else:
			big.append(c.y * gw + c.x)
	big.sort()
	var gas := _gas_cells()
	var hidden: Dictionary = _gas_team(owner, gas, big)
	var any := not big.is_empty()
	var out: Dictionary = _vis_set.get(owner, {})
	var memory: Dictionary = explored.get(owner, {})
	var last: Dictionary = _gas_view.get(owner, {})
	if last.is_empty() or last["any"] != any:
		out.clear()
		if any:
			out.merge(_all_cells(grid))
			for i: int in gas:
				out.erase(Vector2i(i % gw, i / gw))
			for i: int in hidden:
				out.erase(Vector2i(i % gw, i / gw))
		for i: int in small:
			out[Vector2i(i % gw, i / gw)] = true
		memory.merge(out)
		_vis_log.erase(owner)   # everything changed
		_vis_counts.erase(owner)
		_vis_seen.erase(owner)
	elif not is_same(last["hidden"], hidden) or last["small"] != small or last["gas"] != gas:
		# Only cells hidden or clouded before or now, and the lone eyes, can have changed.
		var log: Variant = _vis_log.get(owner)
		var check := {}
		for part: Dictionary in [last["hidden"], hidden, last["small"], small]:
			check.merge(part)
		if last["gas"] != gas:
			for cells: PackedInt32Array in [last["gas"], gas]:
				for i: int in cells:
					check[i] = true
		for i: int in check:
			var c := Vector2i(i % gw, i / gw)
			var vis := small.has(i) or (any and not _sight_gas.has(i) and not hidden.has(i))
			if vis == out.has(c):
				continue
			if vis:
				out[c] = true
				memory[c] = true
			else:
				out.erase(c)
			if log != null:
				log.append(i)
	_gas_view[owner] = {"gas": gas, "any": any, "hidden": hidden, "small": small}
	_vis_set[owner] = out
	explored[owner] = memory
	_vis_epoch[owner] = UnitInstance.vision_epoch
	_vis_vv[owner] = GridCell.vision_version
	return out

## The cells team_visible_coords(owner) leaves out when that is a short list known without a
## pass over the board: {} while nothing is hidden, the clouds and the team's shadows with fog
## off (mode 2); null otherwise. The returned set is never edited afterwards.
func visible_complement(owner: int) -> Variant:
	if not visibility_limited():
		return {}
	if fog_enabled:
		return null
	team_visible_coords(owner)
	var v: Dictionary = _gas_view.get(owner, {})
	if v.is_empty() or not v["any"]:
		return null
	if not v.has("complement"):
		var gw := state.grid.width
		var small: Dictionary = v["small"]
		var out := {}
		for cells: Variant in [v["gas"], v["hidden"]]:
			for i: int in cells:
				if not small.has(i):
					out[Vector2i(i % gw, i / gw)] = true
		v["complement"] = out
	return v["complement"]

func _gas_team(owner: int, gas: PackedInt32Array, big: PackedInt32Array) -> Dictionary:
	var key := [state.grid.get_instance_id(), owner]
	var t: Dictionary = _gas_teams.get(key, {})
	if not t.is_empty() and t["gas"] == gas and t["eyes"] == big:
		return t["hidden"]
	var n := big.size()
	var counts: PackedInt32Array
	var check := {}
	if t.is_empty() or t["gas"] != gas:
		counts = PackedInt32Array()
		counts.resize(state.grid.width * state.grid.height)
		for o: int in big:
			for i: int in _shadow(o, gas):
				counts[i] += 1
		if n > 0:
			for i: int in _shadow(big[0], gas):
				check[i] = true
	else:
		counts = t["counts"]
		var old: PackedInt32Array = t["eyes"]
		var gone := PackedInt32Array()
		var came := PackedInt32Array()
		var a := 0
		var b := 0
		while a < old.size() or b < n:
			if a < old.size() and b < n and old[a] == big[b]:
				a += 1
				b += 1
			elif b >= n or (a < old.size() and old[a] < big[b]):
				gone.append(old[a])
				a += 1
			else:
				came.append(big[b])
				b += 1
		for o: int in gone:
			for i: int in _shadow(o, gas):
				counts[i] -= 1
				check[i] = true
		for o: int in came:
			for i: int in _shadow(o, gas):
				counts[i] += 1
				check[i] = true
		check.merge(t["hidden"])
		# Fewer eyes: a cell no changed shadow touched can now be hidden from all the rest,
		# and every such cell lies in the shadow of any one of them.
		if n < old.size() and n > 0:
			for i: int in _shadow(big[0], gas):
				check[i] = true
	var hidden := {}
	if n > 0:
		for i: int in check:
			if counts[i] == n:
				hidden[i] = true
	if not _gas_teams.has(key) and _gas_teams.size() >= 16:
		_gas_teams.clear()   # forked boards (lockstep twins, replays) come and go
	_gas_teams[key] = {"gas": gas, "eyes": big, "counts": counts, "hidden": hidden}
	return hidden

func _gas_cells() -> PackedInt32Array:
	_sync_seen()
	var key := [GridCell.vision_version, state.grid.get_instance_id()]
	if key != _gas_cells_key:
		var cells := PackedInt32Array(_sight_gas.keys())
		cells.sort()
		_gas_cells_now = cells
		_gas_cells_key = key
	return _gas_cells_now

func _shadow(o: int, gas: PackedInt32Array) -> PackedInt32Array:
	var grid := state.grid
	var of := [grid.get_instance_id(), gas]
	if of != _shadows_of or _shadow_cells > SHADOW_CELLS_CAP:
		_shadows.clear()
		_shadow_cells = 0
		_shadows_of = of
	var hit: Variant = _shadows.get(o)
	if hit != null:
		return hit
	var masks := _gas_masks()
	var s := _sweep_hidden(o % grid.width, o / grid.width, masks[0], grid.width, grid.height,
			masks[1], gas)
	_shadows[o] = s
	_shadow_cells += s.size()
	return s

static func _all_cells(grid: Grid) -> Dictionary:
	if _all_cells_grid != grid.get_instance_id() or _all_cells_set.size() != grid.width * grid.height:
		_all_cells_set = {}
		for y in grid.height:
			for x in grid.width:
				_all_cells_set[Vector2i(x, y)] = true
		_all_cells_grid = grid.get_instance_id()
	return _all_cells_set

## Клетки, чья видимость для стороны сменилась с прошлого вызова (в любую сторону, может
## повторяться); null — «сменилось всё»: первый вызов, сброс тумана, новая сетка, журнал
## переполнился. Экран боя держит по нему туман дальнего плана — текстуру, пиксель на
## клетку, — и перекрашивает только эти пиксели.
func take_vis_changes(owner: int) -> Variant:
	var log: Variant = _vis_log.get(owner)
	_vis_log[owner] = []
	return log

## Известна ли стороне эта клетка: видна сейчас ИЛИ разведана раньше (item 46).
## В REALISTIC режиме память не учитывается — там вопрос только «видно сейчас».
func team_knows(owner: int, coord: Vector2i) -> bool:
	if not fog_enabled:
		return true
	if team_visible_coords(owner).has(coord):
		return true
	if fog_mode != MCF.Fog.STANDARD:
		return false
	return (explored.get(owner, {}) as Dictionary).has(coord)
