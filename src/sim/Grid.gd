class_name Grid
extends RefCounted

## Квадратная сетка клеток (см. §3.1). Слой симуляции, ничего не знает об UI.

## Смещения соседей — КОНСТАНТЫ, а не литералы внутри цикла. Массив-литерал в теле
## функции GDScript строит заново при каждом вызове, а neighbors() — самая горячая
## функция симуляции (её зовёт каждый шаг любого BFS и Дейкстры). Порядок обхода
## сохранён ровно тот же, что был у вложенных циклов dy∈[-1,0,1] × dx∈[-1,0,1]:
## от него зависит порядок вставки клеток в словари маршрутов, а значит и то,
## какую из равноценных клеток выберет ИИ.
const N8: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]
const N4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

var width: int
var height: int
var _cells: Array[GridCell] = []

func _init(p_width: int, p_height: int) -> void:
	width = p_width
	height = p_height
	for y in height:
		for x in width:
			_cells.append(GridCell.new(Vector2i(x, y)))
	# Новая сетка — заведомо новая обстановка. Movement.reachable() и кеш обзора
	# различают сетки по instance_id, а его Godot теоретически может выдать повторно
	# после освобождения старой; сдвиг версий закрывает этот случай раз и навсегда,
	# ничего не стоя.
	GridCell.walk_version += 1
	GridCell.feature_version += 1
	GridCell.reset_vision_log()

func in_bounds(coord: Vector2i) -> bool:
	return coord.x >= 0 and coord.y >= 0 and coord.x < width and coord.y < height

func cell(coord: Vector2i) -> GridCell:
	# Границы проверяются здесь же, без вызова in_bounds(): это самая горячая функция
	# сетки, и лишний вызов на неё заметен в профиле.
	var x := coord.x
	var y := coord.y
	if x < 0 or y < 0 or x >= width or y >= height:
		return null
	return _cells[y * width + x]

## Клетка БЕЗ проверки границ — только для вызывающих, которые уже проверили
## in_bounds() сами (внутренние циклы BFS ходят по заранее отфильтрованным соседям).
func cell_fast(x: int, y: int) -> GridCell:
	return _cells[y * width + x]

## Плоский массив клеток (индекс y * width + x) — для САМЫХ горячих циклов (#106).
## Берётся один раз перед циклом и индексируется напрямую: даже cell_fast() остаётся
## вызовом функции, а Дейкстра трогает по восемь соседей на каждую клетку разлива.
## Отдаётся только на чтение: правки клеток идут через сеттеры GridCell — они ведут
## версии (walk_version, vision_version), без которых поедут все кеши.
func cells_flat() -> Array[GridCell]:
	return _cells

## Клетку нельзя занять: вне поля, стена, труп/юнит или блокирующий объект (§3.1).
func is_occupied_or_wall(coord: Vector2i) -> bool:
	var c := cell(coord)
	if c == null or c.is_wall() or c.blocks_move():
		return true
	if c.vehicle_id != -1:
		return true
	return c.occupant != null

## То же самое, но для ПЕШЕГО маршрута (#100): закрытый шлюз здесь не преграда —
## он разъедется перед подошедшим бойцом, поэтому путь сквозь него планировать можно.
func blocks_walk(coord: Vector2i) -> bool:
	var c := cell(coord)
	if c == null or not c.walkable_terrain():
		return true
	if c.vehicle_id != -1:
		return true
	return c.occupant != null

## Есть ли на клетке корпус машины; -1 = нет.
func vehicle_at(coord: Vector2i) -> int:
	var c := cell(coord)
	return c.vehicle_id if c != null else -1

## Разметить прямоугольный след машины (footprint) её id.
func set_vehicle_footprint(vehicle_id: int, cells: Array) -> void:
	for coord: Vector2i in cells:
		var c := cell(coord)
		if c != null:
			c.vehicle_id = vehicle_id

## Снять след машины с указанных клеток (сбросить только совпадающий id).
func clear_vehicle_footprint(vehicle_id: int, cells: Array) -> void:
	for coord: Vector2i in cells:
		var c := cell(coord)
		if c != null and c.vehicle_id == vehicle_id:
			c.vehicle_id = -1

## Соседи по 4 ортогональным направлениям (для полёта дрона — без диагоналей, §3.12).
func orthogonal_neighbors(coord: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d: Vector2i in N4:
		var n: Vector2i = coord + d
		if n.x >= 0 and n.y >= 0 and n.x < width and n.y < height:
			out.append(n)
	return out

## Соседи по всем 8 направлениям (диагонали разрешены, §3.1).
## Внутри поля — быстрый путь без единой проверки: у клетки заведомо все 8 соседей.
func neighbors(coord: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x := coord.x
	var y := coord.y
	if x > 0 and y > 0 and x < width - 1 and y < height - 1:
		out.append(Vector2i(x - 1, y - 1))
		out.append(Vector2i(x, y - 1))
		out.append(Vector2i(x + 1, y - 1))
		out.append(Vector2i(x - 1, y))
		out.append(Vector2i(x + 1, y))
		out.append(Vector2i(x - 1, y + 1))
		out.append(Vector2i(x, y + 1))
		out.append(Vector2i(x + 1, y + 1))
		return out
	for d: Vector2i in N8:
		var n := coord + d
		if n.x >= 0 and n.y >= 0 and n.x < width and n.y < height:
			out.append(n)
	return out

## «Один жилец на клетку» — инвариант СЕТКИ, а не договорённость вызывающих (#103).
##
## Раньше обе функции ниже писали в cell.occupant вслепую. Тот, кто уже стоял на клетке,
## из неё не убирался: ссылка на него просто затиралась, а его собственный unit.coord
## продолжал указывать сюда же. Формально в словаре клеток он больше не значился, но
## жив, стрелял, рисовался и считался соседом — и на экране два бойца (два жителя, боец
## и труп) стояли в одном квадрате. Хуже того, следующий же Дейкстра считал клетку
## занятой ОДНИМ юнитом, так что расхождение не лечилось само.
##
## Проверять это в каждом из полутора десятков мест, которые двигают юнитов, бессмысленно:
## одно забытое место возвращает баг целиком. Поэтому отказ живёт здесь, в единственной
## двери на запись, и обе функции возвращают bool: «переезд состоялся». Вызывающему не
## обязательно смотреть на ответ — при отказе состояние просто остаётся прежним, что
## всегда лучше двух тел в одной клетке.
##
## Труп — тоже occupant, и он тоже никого не пускает: через него нельзя пройти, его
## оттаскивают или подбирают. Это уже было правилом (Grid.blocks_walk), теперь оно
## перестало зависеть от аккуратности вызывающего.
func place(unit: UnitInstance, coord: Vector2i) -> bool:
	if unit == null:
		return false
	var c := cell(coord)
	if c == null:
		return false
	if c.occupant != null and c.occupant != unit:
		push_error("Grid.place: cell (%d, %d) is taken by %s, refusing to stack %s" % [
			coord.x, coord.y, c.occupant.stats.display_name, unit.stats.display_name])
		return false
	# Юнит мог уже стоять на другой клетке (перестановка) — снимаем его оттуда, иначе
	# он остался бы «жильцом» сразу двух клеток.
	var prev := cell(unit.coord)
	if prev != null and prev != c and prev.occupant == unit:
		prev.occupant = null
	c.occupant = unit
	unit.coord = coord
	return true

func move_occupant(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	if from_coord == to_coord:
		return true
	var from_cell := cell(from_coord)
	var to_cell := cell(to_coord)
	if from_cell == null or to_cell == null:
		return false
	var unit: UnitInstance = from_cell.occupant
	if unit == null:
		return false
	if to_cell.occupant != null:
		push_error("Grid.move_occupant: (%d, %d) is taken by %s, %s stays put" % [
			to_coord.x, to_coord.y, to_cell.occupant.stats.display_name,
			unit.stats.display_name])
		return false
	from_cell.occupant = null
	to_cell.occupant = unit
	unit.coord = to_coord
	return true
