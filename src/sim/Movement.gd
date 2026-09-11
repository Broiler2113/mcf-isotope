class_name Movement
extends RefCounted

## Поиск достижимых клеток за одно действие Движения (§3.1, §3.2).
## Дейкстра по очкам скорости: ровная клетка = 1, подъём — по MCF.CLIMB_COST.

class Reachability:
	var cost: Dictionary = {}       # Vector2i -> потраченные очки скорости
	var came_from: Dictionary = {}  # Vector2i -> предыдущая Vector2i

	func can_reach(coord: Vector2i) -> bool:
		return cost.has(coord)

	## Путь от старта (исключая старт) до coord, или пусто если недостижимо.
	func path_to(coord: Vector2i) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		if not cost.has(coord):
			return out
		var cur := coord
		while came_from.has(cur):
			out.push_front(cur)
			cur = came_from[cur]
		return out

## Стоимость входа в клетку to из клетки from. -1 = вход невозможен.
static func enter_cost(grid: Grid, from_coord: Vector2i, to_coord: Vector2i) -> int:
	if grid.blocks_walk(to_coord):
		return -1
	var to_cell := grid.cell(to_coord)
	# Проём шлюза ровный: створки разъезжаются, лезть наверх не надо (#100). Читать
	# cover_height закрытого шлюза как подъём на 2 м было бы неверно.
	if to_cell.airlock_opens():
		return MCF.FLAT_MOVE_COST
	var from_h: float = grid.cell(from_coord).cover_height
	var to_h: float = to_cell.cover_height
	if to_h > from_h and MCF.CLIMB_COST.has(to_h):
		return int(MCF.CLIMB_COST[to_h])
	return MCF.FLAT_MOVE_COST

## Клетка за противотанковым ежом по той же прямой (#78): на ежа не встают, его
## перепрыгивают за MCF.HEDGEHOG_JUMP_COST очков. (-1,-1) = прыжок невозможен.
static func hedgehog_landing(grid: Grid, from_coord: Vector2i, over: Vector2i) -> Vector2i:
	var landing: Vector2i = over + (over - from_coord)
	if not grid.in_bounds(landing) or grid.blocks_walk(landing):
		return Vector2i(-1, -1)
	return landing

## Кеш разливов Дейкстры. Один и тот же (сетка, старт, запас) на неизменной сетке даёт
## побитово тот же результат, а зовут reachable() пачками: подсветка группы в Main.gd
## считает разлив на КАЖДОГО выделенного юнита при каждой перерисовке, AIPlanner — на
## каждого бойца за план. Кеш целиком сбрасывается, как только GridCell.walk_version
## изменилась, то есть при любой записи в поле, влияющее на проходимость.
##
## Отдаётся ОДИН И ТОТ ЖЕ объект Reachability на все попадания в кеш — это безопасно
## ровно потому, что все потребители работают с ним только на чтение (cost.keys(),
## cost[coord], can_reach(), path_to()). Если однажды понадобится ПРАВИТЬ результат —
## правьте копию, иначе испортите его всем остальным.
static var _cache: Dictionary = {}
static var _cache_version: int = -1
static var _cache_grid: int = 0

## Разлив для КОНКРЕТНОГО бойца: сам решает, обходить ли огонь (#1). Щитоносец и
## огнемётчик огня не боятся, и для них он — обычный пол (#2).
## avoid_cells — клетки, куда боец ЗАВЕДОМО не ступит (batch 12 #3/#4): известные ему
## противопехотные мины (свои и подсвеченные чужие). Их даёт
## GameActionResolver.known_mine_cells(owner); маршрут прокладывается в обход, и сама
## клетка недостижима — на своей мине не остановишься даже нарочно.
static func reachable_for(grid: Grid, unit: UnitInstance, budget: int,
		avoid_cells: Dictionary = {}) -> Reachability:
	var avoid := not MCF.ability_is_fireproof(unit.stats.special_ability_id)
	return reachable(grid, unit.coord, budget, avoid, avoid_cells)

## avoid_fire — маршрут ОБХОДИТ горящие клетки (#1): в них можно войти, но нельзя
## ИЗ них выйти, поэтому они остаются в разливе как тупики. Это та же схема
## «достижимо, но терминально», что уже используется для дрона на стене: игрок
## по-прежнему может осознанно послать бойца в огонь (Main спросит подтверждение),
## но автоматический маршрут сквозь пламя не проложится.
static func reachable(grid: Grid, start: Vector2i, budget: int,
		avoid_fire: bool = false, avoid_cells: Dictionary = {}) -> Reachability:
	var gid := grid.get_instance_id()
	if _cache_version != GridCell.walk_version or _cache_grid != gid:
		_cache.clear()
		_cache_version = GridCell.walk_version
		_cache_grid = gid
	# Пока на карте не горит ни одной клетки, обходить нечего — и оба флага дают
	# ОДИН И ТОТ ЖЕ разлив. Сводим их к одному ключу, чтобы в самом частом случае
	# (огня нет вообще) кеш не хранил две одинаковые копии каждого разлива.
	if GridCell.burning == 0:
		avoid_fire = false
	# Без запретных клеток ключ — прежний Vector4i (самый частый случай); с ними в ключ
	# входит и сам набор: содержимое словаря хешируется по значению.
	var key: Variant = Vector4i(start.x, start.y, budget, 1 if avoid_fire else 0)
	if not avoid_cells.is_empty():
		key = [key, avoid_cells.keys()]
	var hit: Variant = _cache.get(key)
	if hit != null:
		return hit
	var result := Reachability.new()
	var cost: Dictionary = result.cost
	var came_from: Dictionary = result.came_from
	cost[start] = 0
	# Простой Дейкстра: маленькие поля, приоритет через линейный поиск минимума.
	#
	# Порядок обхода и разрешения ничьих здесь ТРОГАТЬ НЕЛЬЗЯ. Из очереди берётся
	# ПЕРВЫЙ строго минимальный элемент, соседи перебираются в порядке Grid.N8, и от
	# этого зависит порядок вставки ключей в cost — а его читает AIPlanner, чей отбор
	# клеток по равным оценкам разрешается порядком перебора. Любая «более умная»
	# очередь (кучей или корзинами) даёт тот же набор клеток, но другой порядок,
	# и армия начинает вставать иначе. Поэтому ускорение здесь чисто механическое:
	#   * стоимости фронта дублируются в ПЛОСКИЙ массив int — поиск минимума больше
	#     не хеширует Vector2i по два раза на элемент, а это и был весь профиль;
	#   * клетка достаётся из сетки ОДИН раз на соседа вместо четырёх (enter_cost
	#     звал grid.cell трижды и ещё раз звали её на проверку ежа);
	#   * высота клетки, из которой шагаем, берётся один раз на все 8 соседей.
	#
	# Извлечённые клетки не вырезаются из фронта, а помечаются ценой TOMB (#106). Две
	# причины. Во-первых, remove_at() сдвигает оба массива на каждое извлечение. Во-вторых
	# и главное: пока позиции не съезжают, «где во фронте лежит эта клетка» можно ЗАПОМНИТЬ
	# в словаре — а раньше на каждое удешевление звался frontier.find(), линейный поиск
	# Vector2i по всему фронту, и вот он и был профилем.
	# На выбор это не влияет: TOMB заведомо больше любой настоящей цены (все они ≤ budget),
	# поэтому помеченная клетка не может выиграть минимум, а живые лежат в прежнем
	# взаимном порядке — значит и «первый строго минимальный» остаётся тем же самым.
	#
	# Надгробия пробовали заменить односвязным списком живых клеток, чтобы поиск минимума
	# шёл по полусотне живых записей вместо полутора сотен всех. Выигрыша не оказалось:
	# прыжки по ссылкам с лишним чтением на шаг стоят ровно столько же, сколько подряд
	# идущие int. Второй раз этот путь протаптывать не надо.
	const TOMB := 1 << 30
	var frontier: Array[Vector2i] = [start]
	var fcost: Array[int] = [0]
	var slot: Dictionary = {start: 0}   # клетка -> её место во фронте, пока она жива
	var live := 1
	var first := 0                      # левее уже только помеченные
	var flat: int = MCF.FLAT_MOVE_COST
	var climb: Dictionary = MCF.CLIMB_COST
	var gw := grid.width
	var gh := grid.height
	# Всё, что читается внутри цикла, вынесено в локальные переменные (#106): и таблица
	# клеток, и константы MCF. Обращение к автозагрузке и вызов метода в GDScript стоят
	# заметно дороже чтения локали, а этот цикл трогает по восемь соседей на клетку.
	var cells: Array[GridCell] = grid.cells_flat()
	var wall_h: float = MCF.WALL_HEIGHT
	var f_airlock: String = MCF.FEATURE_AIRLOCK
	var f_hedgehog: String = MCF.FEATURE_HEDGEHOG
	var jump: int = MCF.HEDGEHOG_JUMP_COST
	var nowhere := Vector2i(-1, -1)
	var skip_mines := not avoid_cells.is_empty()
	# Цены извлечения у Дейкстры не убывают, поэтому цена ПРЕДЫДУЩЕГО извлечения —
	# честная нижняя граница для следующего (#106). Наткнувшись на неё, поиск минимума
	# можно обрывать: меньше уже не будет, а всё, что левее, мы только что просмотрели
	# и меньшего там не нашли — значит найденное звено и есть «первое строго минимальное»,
	# ровно то же самое, что выбрал бы полный проход. На разливе в шесть очков цен всего
	# горстка, и такая находка случается в начале списка, а не в конце.
	var lo := 0
	while live > 0:
		while fcost[first] == TOMB:
			first += 1
		var best_i := first
		var best_c: int = fcost[first]
		var i := first + 1
		var fn := fcost.size()
		# while, а не `for i in range(...)`: range() строит массив на КАЖДОЕ извлечение
		# из очереди, то есть сотни временных массивов на один расчёт хода.
		while i < fn and best_c > lo:
			if fcost[i] < best_c:
				best_c = fcost[i]
				best_i = i
			i += 1
		lo = best_c
		var current: Vector2i = frontier[best_i]
		fcost[best_i] = TOMB
		live -= 1
		slot.erase(current)
		var current_cost: int = best_c
		var cx := current.x
		var cy := current.y
		var from_cell: GridCell = cells[cy * gw + cx]
		# Горящая клетка — тупик: дойти можно, уйти дальше нельзя. Стартовая клетка
		# исключение: боец, УЖЕ стоящий в огне (или огнеупорный), из неё выходит.
		if avoid_fire and from_cell.on_fire and current != start:
			continue
		var from_h: float = from_cell.cover_height
		# Соседи перебираются прямо по константной таблице смещений: grid.neighbors()
		# возвращал бы новый массив на каждую клетку фронта. Порядок Grid.N8 совпадает
		# со старым обходом dy∈[-1,0,1] × dx∈[-1,0,1], и менять его нельзя (см. выше).
		for d: Vector2i in Grid.N8:
			var nx := cx + d.x
			var ny := cy + d.y
			if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
				continue
			var nc: GridCell = cells[ny * gw + nx]
			# --- инлайн enter_cost(grid, current, n) вместе с walkable_terrain() и
			# airlock_opens(): те же условия в том же порядке, но без трёх вызовов
			# на каждого из восьми соседей каждой клетки разлива (#106).
			var fid: String = nc.feature_id
			var step := -1
			if nc.vehicle_id == -1 and nc.occupant == null:
				var to_h: float = nc.cover_height
				var opens := fid == f_airlock and not nc.airlock_welded
				var walkable: bool
				if fid == "" and nc.dirt_level == 0:
					walkable = to_h < wall_h   # чистый пол — подавляющее большинство клеток
				elif opens:
					walkable = true
				else:
					walkable = to_h < wall_h and not nc.blocks_move()
				if walkable:
					if opens:
						step = flat   # проём шлюза ровный, лезть наверх не надо (#100)
					elif to_h > from_h:
						# get вместо has+[] — один поиск в таблице подъёмов вместо двух.
						var cc: Variant = climb.get(to_h)
						step = int(cc) if cc != null else flat
					else:
						step = flat
			var n := Vector2i(nx, ny)
			var dest := n
			# Ёж непроходим, но его перепрыгивают: боец приземляется в следующую
			# клетку по той же прямой, потратив 2 очка движения.
			if fid == f_hedgehog:
				dest = hedgehog_landing(grid, current, n)
				if dest == nowhere:
					continue
				step = jump
			elif step < 0:
				continue
			# Известная мина — не клетка, а дыра в полу (batch 12 #4): ни пройти, ни встать.
			if skip_mines and avoid_cells.has(dest):
				continue
			var new_cost := current_cost + step
			if new_cost > budget:
				continue
			var prev: Variant = cost.get(dest)
			if prev == null or new_cost < int(prev):
				cost[dest] = new_cost
				came_from[dest] = current
				var at: Variant = slot.get(dest)
				if at != null:
					# Клетка уже в очереди — правим её цену НА МЕСТЕ, не добавляя дубль.
					# Исходный код дописывал вторую запись и читал цену из словаря, то
					# есть обе записи всё равно показывали новую цену и побеждала более
					# ранняя позиция. Здесь ровно это и происходит, только без холостого
					# повторного извлечения той же клетки.
					fcost[at] = new_cost
				else:
					slot[dest] = frontier.size()
					frontier.append(dest)
					fcost.append(new_cost)
					live += 1
	cost.erase(start)
	_cache[key] = result
	return result
