class_name MapGen
extends RefCounted

## Генератор случайных карт — строка «Random map» в лобби. Три стиля (станция, город,
## поле) собираются из одного числа-зерна: удачную карту можно назвать этим числом, и
## она соберётся снова точно такой же.
##
## Карта органическая, без зеркала. Честность держится на другом: зоны развёртывания
## одного размера, разнесены как можно дальше друг от друга, и из любой зоны в любую
## есть пеший путь — это проверяется в самом конце, а где пути нет, он прорубается.
##
## Зона обязана вместить отряд: на бойца — CELLS_PER_UNIT клеток. Не влезли на
## выбранном размере — поле растёт (до MAX_DIM) и строится заново. Мирные ставятся
## туда, где их не видно ни из одной зоны: иначе они проснулись бы от первого же хода.
##
## Строит карту только хост: гостю уезжает готовая MapData (K_LOBBY_MAP), так что сети
## детерминизм генератора не нужен — он нужен зерну. Каждая фаза тянет числа из СВОЕГО
## потока, поэтому снятая галочка «Civilians» убирает мирных, а не перекраивает улицы.

enum Style {STATION, TOWN, FIELD}
const STYLE_NAMES := ["Station", "Town", "Field"]
const SIZES := [Vector2i(28, 20), Vector2i(38, 28), Vector2i(50, 38)]
const SIZE_NAMES := ["Small", "Medium", "Large"]
const DENSITY_NAMES := ["Sparse", "Normal", "Dense"]
const DENSITY_MULT := [0.55, 1.0, 1.6]
const SEED_MAX := 9999999
## Какая доля чистого пола уходит под зоны развёртывания всех сторон вместе — если
## отряды просят меньше. Больше чем вчетверо против нужного зона не раздувается.
const ZONE_SHARE := 0.3
## Клеток зоны на бойца: есть где развернуться и куда поставить технику (танк — 3×3).
const CELLS_PER_UNIT := 2
## Дальше этого поле не растёт, даже если отряды всё ещё не влезают.
const MAX_DIM := Vector2i(80, 60)
## Ближе этого (по Чебышёву) клетки разных зон друг к другу не подходят. Только если
## отряды не влезают и на самом большом поле, зазор ужимается до 2, потом до 1.
const ZONE_GAP := 3
const ZONE_MIN := 16

enum Phase {STRUCTURE, SPACE, ZONES, DRESSING, CIVILIANS}

const N4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# Разметка станции до переноса в MapData.
const K_VOID := 0
const K_ROOM := 1
const K_HALL := 2
const K_WALL := 3
const K_DOOR := 4

var opt: Dictionary
var m: MapData
var w: int
var h: int
var dens: float
var _rng: RandomNumberGenerator
## Клетки «под крышей» — комнаты станции, дома, руины. Мирные живут в основном тут.
var _indoor: PackedByteArray
## Дверные проёмы. Зона сквозь них прорастает, но их не занимает; шлюзы — только в них.
var _door: PackedByteArray
var _doors: Array[Vector2i] = []
## Комнаты станции, дома города, руины поля — прямоугольники со стенами по краю.
var _rooms: Array[Rect2i] = []
var _parks: Array[Rect2i] = []
var _street: PackedByteArray
var _k: PackedByteArray
## Номер зоны клетки (-1 — не зона) и якорь каждой зоны.
var _zone: PackedInt32Array
var _anchors: Array[Vector2i] = []
## Где украшениям не место: зоны с каймой, проёмы и подходы к ним.
var _keep: PackedByteArray
# Рабочие массивы роста зон — члены, чтобы _grow, _push и _near_other делили их, не
# передавая друг другу.
var _own: PackedInt32Array
var _seen: PackedByteArray
var _fronts: Array = []
var _claimed: Array = []  # по зоне — её клетки в порядке захвата
var _gap := ZONE_GAP
var _need := ZONE_MIN     # клеток на зону, чтобы влез отряд
var _tight := false       # поле уже предельное — можно ужимать зазор между зонами
var _zone_min := 0        # сколько клеток досталось каждой зоне

static func default_options() -> Dictionary:
	return {"style": Style.TOWN, "size": 1, "density": 1, "seed": 1, "zones": 2, "units": 10,
			"space": true, "flammable": true, "obstacles": true, "civilians": true}

## Сколько клеток нужно зоне, чтобы в неё встал отряд из `units` бойцов.
static func zone_need(units: int) -> int:
	return maxi(ZONE_MIN, units * CELLS_PER_UNIT)

## Собрать карту. Ключи настроек — как в default_options(); недостающие берутся оттуда.
## Отряды не влезли в зоны — поле растёт пропорционально нехватке и строится заново.
static func generate(options: Dictionary) -> MapData:
	var o := default_options()
	o.merge(options, true)
	var dim: Vector2i = SIZES[clampi(int(o["size"]), 0, SIZES.size() - 1)]
	var need := zone_need(int(o["units"]))
	var g: MapGen = null
	for attempt in 6:
		var last := attempt == 5 or dim.x >= MAX_DIM.x or dim.y >= MAX_DIM.y
		g = MapGen.new()
		g._build(o, dim, need, last)
		if g._zone_min >= need or last:
			break
		var grow := clampf(sqrt(float(need) / maxf(1.0, float(g._zone_min))) * 1.1, 1.15, 2.0)
		dim = Vector2i(mini(ceili(dim.x * grow), MAX_DIM.x), mini(ceili(dim.y * grow), MAX_DIM.y))
	return g.m

func _build(options: Dictionary, dim: Vector2i, need: int, tight: bool) -> void:
	opt = options
	_need = need
	_tight = tight
	w = dim.x
	h = dim.y
	dens = DENSITY_MULT[clampi(int(opt["density"]), 0, DENSITY_MULT.size() - 1)]
	m = MapData.new(w, h)
	_indoor = _bytes()
	_door = _bytes()
	_street = _bytes()
	_keep = _bytes()
	_zone = PackedInt32Array()
	_zone.resize(w * h)
	_zone.fill(-1)
	var style := int(opt["style"])
	_phase(Phase.STRUCTURE)
	match style:
		Style.STATION:
			_station()
		Style.FIELD:
			_field()
		_:
			_town()
	_phase(Phase.SPACE)
	if bool(opt["space"]):
		if style == Style.STATION:
			_vent_room()
		else:
			_open_space()
	_phase(Phase.ZONES)
	_zones(clampi(int(opt["zones"]), 2, MCF.MAX_PLAYERS))
	_phase(Phase.DRESSING)
	match style:
		Style.STATION:
			_dress_station()
		Style.FIELD:
			_dress_field()
		_:
			_dress_town()
	_connect_zones()
	_phase(Phase.CIVILIANS)
	if bool(opt["civilians"]):
		_civilians()

## Свой поток случайных чисел на каждую фазу (см. шапку).
func _phase(p: int) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = int(opt["seed"]) * 1000003 + p * 7919 + int(opt["style"]) * 131 \
			+ int(opt["size"]) * 17 + int(opt["density"])

func _bytes() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(w * h)
	return b

# --- Клетки ----------------------------------------------------------------------------
func _in(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < w and c.y < h

func _ground(c: Vector2i, floor_type: int = MCF.FLOOR_NORMAL) -> void:
	m.set_cell(c, floor_type, 0.0, false, "")

## Объект на клетку: высота — из таблицы объектов, пол под ним прежний.
func _put(c: Vector2i, feature: String) -> void:
	m.set_cell(c, m.get_floor(c), float(MCF.FEATURE_HEIGHT.get(feature, 0.0)), false, feature)

## Пустота за постройками: космос, а без космоса — сплошная скала.
func _void(c: Vector2i) -> void:
	if bool(opt["space"]):
		_space(c)
	else:
		_put(c, MCF.FEATURE_WALL)

func _space(c: Vector2i) -> void:
	if not _in(c):
		return
	m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, true, "")
	_indoor[c.y * w + c.x] = 0
	_door[c.y * w + c.x] = 0

## Чистый пол: не космос, без объекта и укрытия — тут можно и встать, и расставиться.
func _clear(c: Vector2i) -> bool:
	return _in(c) and not m.get_space(c) and m.get_feature(c) == "" and m.get_cover(c) <= 0.0

## Проходима ли клетка пешком на пустой доске — то же, что GridCell.walkable_terrain():
## всё ниже стены, космос и шлюз. Ёж не считается: его только перепрыгивают, а путь
## «через ежа» не нужен, чтобы зоны были связаны.
func _walk(c: Vector2i) -> bool:
	if not _in(c):
		return false
	var f := m.get_feature(c)
	if f == MCF.FEATURE_AIRLOCK:
		return true
	if f == MCF.FEATURE_HEDGEHOG or f == MCF.FEATURE_DRONE_STATION:
		return false
	return m.get_space(c) or m.get_cover(c) < MCF.WALL_HEIGHT

## Украшение ставится только на чистую клетку и не туда, где зона или проём.
func _try_put(c: Vector2i, feature: String) -> bool:
	if not _clear(c) or _keep[c.y * w + c.x] != 0:
		return false
	_put(c, feature)
	return true

func _mark_door(c: Vector2i) -> void:
	_door[c.y * w + c.x] = 1
	_doors.append(c)

func _near_door(c: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var p := c + Vector2i(dx, dy)
			if _in(p) and _door[p.y * w + p.x] != 0:
				return true
	return false

func _near_feature(c: Vector2i, feature: String) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if (dx != 0 or dy != 0) and m.get_feature(c + Vector2i(dx, dy)) == feature:
				return true
	return false

func _touches_space(c: Vector2i) -> bool:
	for d: Vector2i in N4:
		if _in(c + d) and m.get_space(c + d):
			return true
	return false

func _inside_room(c: Vector2i) -> bool:
	for r in _rooms:
		if r.has_point(c):
			return true
	return false

func _on_edge(r: Rect2i, c: Vector2i) -> bool:
	return c.x == r.position.x or c.y == r.position.y or c.x == r.end.x - 1 or c.y == r.end.y - 1

func _is_corner(r: Rect2i, c: Vector2i) -> bool:
	return (c.x == r.position.x or c.x == r.end.x - 1) and (c.y == r.position.y or c.y == r.end.y - 1)

func _edge_cells(r: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if _on_edge(r, Vector2i(x, y)):
				out.append(Vector2i(x, y))
	return out

## Куда смотрит наружу клетка края прямоугольника (не угловая).
func _outward(r: Rect2i, c: Vector2i) -> Vector2i:
	if c.y == r.position.y:
		return Vector2i(0, -1)
	if c.y == r.end.y - 1:
		return Vector2i(0, 1)
	if c.x == r.position.x:
		return Vector2i(-1, 0)
	return Vector2i(1, 0)

func _random_cell(margin: int = 1) -> Vector2i:
	return Vector2i(_rng.randi_range(margin, w - 1 - margin), _rng.randi_range(margin, h - 1 - margin))

# --- Станция ---------------------------------------------------------------------------
## Комнаты — листья двоичного разбиения (BSP); коридор соединяет две ветви каждого
## узла дерева, поэтому связна вся станция. Пара лишних коридоров даёт обходы: без
## них у каждой комнаты был бы ровно один подход. Всё прочее — космос за обшивкой
## (или скала, если космос выключен).
func _station() -> void:
	_k = _bytes()
	var leaves: Array[Rect2i] = []
	var pairs: Array = []
	var min_leaf: int = [10, 8, 7][clampi(int(opt["density"]), 0, 2)]
	_bsp(Rect2i(1, 1, w - 2, h - 2), min_leaf, leaves, pairs)
	var room_of: Array[int] = []
	for leaf in leaves:
		# Изредка лист пустует — у станции появляется неровный силуэт.
		var empty := _rng.randf() < 0.12 and leaves.size() >= 6
		var rw := _rng.randi_range(maxi(6, leaf.size.x * 6 / 10), leaf.size.x - 1)
		var rh := _rng.randi_range(maxi(6, leaf.size.y * 6 / 10), leaf.size.y - 1)
		var r := Rect2i(leaf.position.x + _rng.randi_range(0, leaf.size.x - 1 - rw),
				leaf.position.y + _rng.randi_range(0, leaf.size.y - 1 - rh), rw, rh)
		if empty:
			room_of.append(-1)
			continue
		room_of.append(_rooms.size())
		_rooms.append(r)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				_k[y * w + x] = K_WALL if _on_edge(r, Vector2i(x, y)) else K_ROOM
	for p in pairs:
		var a := _rooms_in(p[0], room_of)
		var b := _rooms_in(p[1], room_of)
		if a.is_empty() or b.is_empty():
			continue
		# Ближайшая пара комнат из двух ветвей — коридор не тянется через полкарты.
		var best := Vector2i(a[0], b[0])
		var best_d := 1 << 30
		for i in a:
			for j in b:
				var d := _rooms[i].get_center().distance_squared_to(_rooms[j].get_center())
				if d < best_d:
					best_d = d
					best = Vector2i(i, j)
		_hall(_rooms[best.x], _rooms[best.y])
	# Обходы: лишний коридор от случайной комнаты к одной из трёх ближайших.
	if _rooms.size() >= 3:
		for n in maxi(1, _rooms.size() / 4):
			var i := _rng.randi_range(0, _rooms.size() - 1)
			var ci := _rooms[i].get_center()
			var near := range(_rooms.size())
			near.erase(i)
			near.sort_custom(func(p: int, q: int) -> bool:
				return ci.distance_squared_to(_rooms[p].get_center()) \
						< ci.distance_squared_to(_rooms[q].get_center()))
			_hall(_rooms[i], _rooms[near[_rng.randi_range(0, mini(2, near.size() - 1))]])
	# Обшивка: всякая пустота, касающаяся пола хотя бы углом, становится стеной.
	for y in h:
		for x in w:
			if _k[y * w + x] == K_VOID and _touches_floor(x, y):
				_k[y * w + x] = K_WALL
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			match _k[y * w + x]:
				K_ROOM:
					_ground(c)
					_indoor[y * w + x] = 1
				K_HALL, K_DOOR:
					_ground(c)
				K_WALL:
					_put(c, MCF.FEATURE_WALL)
				_:
					_void(c)
	for y in h:
		for x in w:
			if _k[y * w + x] == K_DOOR and _is_doorway(x, y):
				_mark_door(Vector2i(x, y))

## Делит прямоугольник, пока есть куда; возвращает номера листьев своего поддерева.
## Каждый внутренний узел записывает пару «листья слева / листья справа» — их потом
## свяжет коридор.
func _bsp(r: Rect2i, min_leaf: int, leaves: Array[Rect2i], pairs: Array) -> Array[int]:
	var can_x := r.size.x >= min_leaf * 2
	var can_y := r.size.y >= min_leaf * 2
	# Иногда лист средней величины не делится дальше — так появляются большие залы.
	var hall_roll := _rng.randf()
	if not (can_x or can_y) \
			or (hall_roll < 0.15 and r.size.x < min_leaf * 3 and r.size.y < min_leaf * 3):
		leaves.append(r)
		var one: Array[int] = [leaves.size() - 1]
		return one
	var split_roll := _rng.randf()
	var along_x := can_x and (not can_y or split_roll < float(r.size.x) / float(r.size.x + r.size.y))
	var a: Array[int]
	var b: Array[int]
	if along_x:
		var cut := _rng.randi_range(min_leaf, r.size.x - min_leaf)
		a = _bsp(Rect2i(r.position.x, r.position.y, cut, r.size.y), min_leaf, leaves, pairs)
		b = _bsp(Rect2i(r.position.x + cut, r.position.y, r.size.x - cut, r.size.y), min_leaf,
				leaves, pairs)
	else:
		var cut := _rng.randi_range(min_leaf, r.size.y - min_leaf)
		a = _bsp(Rect2i(r.position.x, r.position.y, r.size.x, cut), min_leaf, leaves, pairs)
		b = _bsp(Rect2i(r.position.x, r.position.y + cut, r.size.x, r.size.y - cut), min_leaf,
				leaves, pairs)
	pairs.append([a, b])
	var both: Array[int] = a.duplicate()
	both.append_array(b)
	return both

func _rooms_in(leaf_ids: Array, room_of: Array[int]) -> Array[int]:
	var out: Array[int] = []
	for li: int in leaf_ids:
		if room_of[li] >= 0:
			out.append(room_of[li])
	return out

## Коридор «буквой Г» из случайной точки одной комнаты в случайную точку другой,
## шириной 1 или 2. Пробитая им стена комнаты становится проёмом.
func _hall(ra: Rect2i, rb: Rect2i) -> void:
	var a := Vector2i(_rng.randi_range(ra.position.x + 1, ra.end.x - 2),
			_rng.randi_range(ra.position.y + 1, ra.end.y - 2))
	var b := Vector2i(_rng.randi_range(rb.position.x + 1, rb.end.x - 2),
			_rng.randi_range(rb.position.y + 1, rb.end.y - 2))
	var wide := _rng.randf() < 0.4
	var bend := Vector2i(b.x, a.y) if _rng.randf() < 0.5 else Vector2i(a.x, b.y)
	_hall_leg(a, bend, wide)
	_hall_leg(bend, b, wide)

func _hall_leg(from: Vector2i, to: Vector2i, wide: bool) -> void:
	var step := (to - from).sign()
	var side := Vector2i(absi(step.y), absi(step.x))  # вторая полоса — поперёк хода
	var c := from
	while true:
		_carve(c)
		if wide:
			_carve(c + side)
		if c == to:
			break
		c += step

func _carve(c: Vector2i) -> void:
	if c.x < 1 or c.y < 1 or c.x > w - 2 or c.y > h - 2:
		return
	var i := c.y * w + c.x
	if _k[i] == K_VOID:
		_k[i] = K_HALL
	elif _k[i] == K_WALL:
		_k[i] = K_DOOR

func _kind(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= w or y >= h:
		return K_VOID
	return _k[y * w + x]

func _touches_floor(x: int, y: int) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var k := _kind(x + dx, y + dy)
			if k == K_ROOM or k == K_HALL or k == K_DOOR:
				return true
	return false

## Настоящий проём: стена слева и справа, проход спереди и сзади (или наоборот).
## Коридор, прошедший ВДОЛЬ стены, снёс её целиком — это уже не дверь, а открытый край.
func _is_doorway(x: int, y: int) -> bool:
	var wall := func(k: int) -> bool: return k == K_WALL or k == K_DOOR
	var open := func(k: int) -> bool: return k == K_ROOM or k == K_HALL
	var wall_x: bool = wall.call(_kind(x - 1, y)) and wall.call(_kind(x + 1, y))
	var wall_y: bool = wall.call(_kind(x, y - 1)) and wall.call(_kind(x, y + 1))
	var pass_x: bool = open.call(_kind(x - 1, y)) and open.call(_kind(x + 1, y))
	var pass_y: bool = open.call(_kind(x, y - 1)) and open.call(_kind(x, y + 1))
	return (wall_x and pass_y) or (wall_y and pass_x)

## Разгерметизированный отсек: одна комната (не на каждой станции) — в невесомости.
## Её проёмы потом обязательно получат шлюзы.
func _vent_room() -> void:
	if _rooms.size() < 4 or _rng.randf() > 0.7:
		return
	var r := _rooms[_rng.randi_range(0, _rooms.size() - 1)]
	for y in range(r.position.y + 1, r.end.y - 1):
		for x in range(r.position.x + 1, r.end.x - 1):
			if _k[y * w + x] == K_ROOM:
				_space(Vector2i(x, y))

func _vented(r: Rect2i) -> bool:
	return m.get_space(r.get_center())

## Станция: шлюзы в проёмах, окна и выходы в открытый космос в обшивке, деревянные
## палубы складов — и уже потом мебель: колонны в больших залах, ящики, баррикады.
func _dress_station() -> void:
	var space := bool(opt["space"])
	for d in _doors:
		var roll := _rng.randf()
		if space and (roll < 0.3 or _touches_space(d)):
			_put(d, MCF.FEATURE_AIRLOCK)
	for c in _hull():
		var roll := _rng.randf()
		if roll < 0.025 and not _near_feature(c, MCF.FEATURE_AIRLOCK):
			_put(c, MCF.FEATURE_AIRLOCK)
		elif roll < 0.11:
			_put(c, MCF.FEATURE_GLASS)
	var wooden: Array[bool] = []
	for r in _rooms:
		var wood := _rng.randf() < 0.3 and bool(opt["flammable"]) and not _vented(r)
		wooden.append(wood)
		if not wood:
			continue
		for y in range(r.position.y + 1, r.end.y - 1):
			for x in range(r.position.x + 1, r.end.x - 1):
				var c := Vector2i(x, y)
				if _k[y * w + x] == K_ROOM and not m.get_space(c):
					m.set_cell(c, MCF.FLOOR_FLAMMABLE, m.get_cover(c), false, m.get_feature(c))
	if not bool(opt["obstacles"]):
		return
	for ri in _rooms.size():
		var r := _rooms[ri]
		if _vented(r):
			continue
		var inner := r.grow(-1)
		# Колонны: четыре в большом зале, симметрично от углов.
		if inner.size.x >= 7 and inner.size.y >= 7:
			for p: Vector2i in [inner.position + Vector2i(2, 2),
					Vector2i(inner.end.x - 3, inner.position.y + 2),
					Vector2i(inner.position.x + 2, inner.end.y - 3), inner.end - Vector2i(3, 3)]:
				_try_put(p, MCF.FEATURE_WALL)
		# Ящики кучками по 1–3; на деревянной палубе часть из них — дощатые, 2 м.
		for n in roundi(inner.get_area() * 0.07 * dens):
			var c := Vector2i(_rng.randi_range(inner.position.x, inner.end.x - 1),
					_rng.randi_range(inner.position.y, inner.end.y - 1))
			var dir: Vector2i = N4[_rng.randi_range(0, 3)]
			var crate := MCF.FEATURE_SANDBAGS
			if wooden[ri] and _rng.randf() < 0.5:
				crate = MCF.FEATURE_WOOD_WALL
			for k in _rng.randi_range(1, 3):
				_try_put(c + dir * k, crate)
	# Баррикады в коридорах — мешки, через них перелезают.
	for y in h:
		for x in w:
			if _k[y * w + x] == K_HALL and _rng.randf() < 0.03 * dens:
				_try_put(Vector2i(x, y), MCF.FEATURE_SANDBAGS)

## Клетки обшивки: стена между чистым полом станции и открытым космосом по прямой,
## со стенами по бокам, — в них врезаются окна и внешние шлюзы.
func _hull() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var c := Vector2i(x, y)
			if m.get_feature(c) != MCF.FEATURE_WALL:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var side := Vector2i(d.y, d.x)
				var across := (_clear(c - d) and m.get_space(c + d)) \
						or (_clear(c + d) and m.get_space(c - d))
				if across and m.get_feature(c + side) == MCF.FEATURE_WALL \
						and m.get_feature(c - side) == MCF.FEATURE_WALL:
					out.append(c)
					break
	return out

# --- Город -----------------------------------------------------------------------------
## Сетка улиц с дрожанием шага и ширины; кварталы между ними — дома (кирпич или, при
## горючке, дерево), дворы и скверы. Большой квартал режется проулком на два дома.
func _town() -> void:
	var lawn := MCF.FLOOR_GRASS if bool(opt["flammable"]) else MCF.FLOOR_NORMAL
	for y in h:
		for x in w:
			_ground(Vector2i(x, y), lawn)
	var xs := _street_lines(w)
	var ys := _street_lines(h)
	for s in xs:
		for y in h:
			for x in range(s.x, s.x + s.y):
				_ground(Vector2i(x, y))
				_street[y * w + x] = 1
	for s in ys:
		for y in range(s.x, s.x + s.y):
			for x in w:
				_ground(Vector2i(x, y))
				_street[y * w + x] = 1
	for gx in _gaps(xs, w):
		for gy in _gaps(ys, h):
			_block(Rect2i(gx.x, gy.x, gx.y - gx.x, gy.y - gy.x))

## Улицы одного направления: [начало, ширина] с шагом 10–15 клеток.
func _street_lines(n: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var p := _rng.randi_range(4, 9)
	while p < n - 5:
		var width := 3 if _rng.randf() < 0.25 else 2
		out.append(Vector2i(p, width))
		p += width + _rng.randi_range(8, 13)
	return out

## Промежутки между улицами: [начало, конец) кварталов вдоль одной оси.
func _gaps(lines: Array[Vector2i], n: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var from := 0
	for s in lines:
		if s.x > from:
			out.append(Vector2i(from, s.x))
		from = s.x + s.y
	if from < n:
		out.append(Vector2i(from, n))
	return out

func _block(b: Rect2i) -> void:
	var roll := _rng.randf()
	var split_roll := _rng.randf()
	var cut_roll := _rng.randf()
	if b.size.x < 5 or b.size.y < 5 or roll > clampf(0.72 * dens, 0.4, 0.92):
		_parks.append(b)
		return
	# Большой квартал — два дома с проулком посередине.
	if split_roll < 0.6 and b.size.x >= 13 and b.size.x >= b.size.y:
		var cut := 6 + int(cut_roll * (b.size.x - 12))
		_house(Rect2i(b.position.x, b.position.y, cut, b.size.y))
		_house(Rect2i(b.position.x + cut + 1, b.position.y, b.size.x - cut - 1, b.size.y))
	elif split_roll < 0.6 and b.size.y >= 13:
		var cut := 6 + int(cut_roll * (b.size.y - 12))
		_house(Rect2i(b.position.x, b.position.y, b.size.x, cut))
		_house(Rect2i(b.position.x, b.position.y + cut + 1, b.size.x, b.size.y - cut - 1))
	else:
		_house(b)

## Дом на участке: отступ 0–1 клетка с каждой стороны, стены, 1–2 двери наружу, окна,
## в большом доме — перегородка с проходом.
func _house(lot: Rect2i) -> void:
	var l := _rng.randi_range(0, 1)
	var t := _rng.randi_range(0, 1)
	var r := _rng.randi_range(0, 1)
	var bt := _rng.randi_range(0, 1)
	var wooden := _rng.randf() < 0.35
	var planks := _rng.randf() < 0.5
	var house := Rect2i(lot.position.x + l, lot.position.y + t, lot.size.x - l - r,
			lot.size.y - t - bt)
	if house.size.x < 5 or house.size.y < 5:
		house = lot  # тесный участок — дом во всю ширину, без отступа
	if house.size.x < 5 or house.size.y < 5:
		_parks.append(lot)
		return
	var fire := bool(opt["flammable"])
	var wall := MCF.FEATURE_WOOD_WALL if fire and wooden else MCF.FEATURE_WALL
	var floor_type := MCF.FLOOR_FLAMMABLE if fire and planks else MCF.FLOOR_NORMAL
	_rooms.append(house)
	for y in range(house.position.y, house.end.y):
		for x in range(house.position.x, house.end.x):
			var c := Vector2i(x, y)
			if _on_edge(house, c):
				_put(c, wall)
			else:
				_ground(c, floor_type)
				_indoor[y * w + x] = 1
	for i in (2 if house.get_area() >= 64 else 1):
		_front_door(house, floor_type)
	# Окна — стекло в стене, но не в углу и не у двери.
	for c in _edge_cells(house):
		if _rng.randf() < 0.14 and not _is_corner(house, c) and not _near_door(c):
			_put(c, MCF.FEATURE_GLASS)
	# Перегородка в большом доме — внутренняя стена с одним проходом.
	var inner := house.grow(-1)
	var part_roll := _rng.randf()
	var at_roll := _rng.randf()
	var gap_roll := _rng.randf()
	if part_roll > 0.7:
		return
	var cells: Array[Vector2i] = []
	if inner.size.x >= 8:
		var px := inner.position.x + 3 + int(at_roll * (inner.size.x - 6))
		for y in range(inner.position.y, inner.end.y):
			cells.append(Vector2i(px, y))
	elif inner.size.y >= 8:
		var py := inner.position.y + 3 + int(at_roll * (inner.size.y - 6))
		for x in range(inner.position.x, inner.end.x):
			cells.append(Vector2i(x, py))
	if cells.is_empty():
		return
	var gap := cells[int(gap_roll * cells.size())]
	for c in cells:
		# Перегородка не упирается во входную дверь — у двери она просто обрывается.
		if c != gap and not _near_door(c):
			_put(c, wall)
	_mark_door(gap)

## Дверь наружу: на случайной стороне, не в углу, и ведёт на землю — не в стену соседа
## и не за край карты. Не нашлась за дюжину попыток — дом остаётся без второй двери.
func _front_door(r: Rect2i, floor_type: int) -> void:
	for attempt in 12:
		var c: Vector2i
		match _rng.randi_range(0, 3):
			0:
				c = Vector2i(_rng.randi_range(r.position.x + 1, r.end.x - 2), r.position.y)
			1:
				c = Vector2i(_rng.randi_range(r.position.x + 1, r.end.x - 2), r.end.y - 1)
			2:
				c = Vector2i(r.position.x, _rng.randi_range(r.position.y + 1, r.end.y - 2))
			_:
				c = Vector2i(r.end.x - 1, _rng.randi_range(r.position.y + 1, r.end.y - 2))
		if not _clear(c + _outward(r, c)) or _near_door(c):
			continue
		_ground(c, floor_type)
		_mark_door(c)
		return

## Город: баррикады поперёк улиц с проходом, ежи на мостовой, в скверах — окопы и
## гнёзда из мешков.
func _dress_town() -> void:
	if not bool(opt["obstacles"]):
		return
	var area := float(w * h)
	# Только свободная мостовая: улицы в зонах и у дверей берегутся (_keep).
	var paving: Array[Vector2i] = []
	for y in h:
		for x in w:
			if _street[y * w + x] != 0 and _keep[y * w + x] == 0 and _clear(Vector2i(x, y)):
				paving.append(Vector2i(x, y))
	if not paving.is_empty():
		for n in roundi(area / 200.0 * dens):
			_barricade(paving[_rng.randi_range(0, paving.size() - 1)])
		for n in roundi(area / 260.0 * dens):
			var c := paving[_rng.randi_range(0, paving.size() - 1)]
			if not _near_feature(c, MCF.FEATURE_HEDGEHOG):
				_try_put(c, MCF.FEATURE_HEDGEHOG)
	for p in _parks:
		for n in 1 + roundi(p.get_area() / 60.0 * dens):
			var c := Vector2i(_rng.randi_range(p.position.x, p.end.x - 1),
					_rng.randi_range(p.position.y, p.end.y - 1))
			if _rng.randf() < 0.5:
				_trench(c)
			else:
				_nest(c)

## Баррикада поперёк улицы: мешки через всю ширину, кроме одной клетки прохода. На
## перекрёстке поперёк не перегородить — там баррикады нет.
func _barricade(c: Vector2i) -> void:
	for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
		var run := _street_run(c, d)
		if run.size() < 2 or run.size() > 3:
			continue
		var gap := _rng.randi_range(0, run.size() - 1)
		for k in run.size():
			if k != gap:
				_try_put(run[k], MCF.FEATURE_SANDBAGS)
		return

func _street_run(c: Vector2i, d: Vector2i) -> Array[Vector2i]:
	var run: Array[Vector2i] = []
	var p := c
	while _in(p - d) and _street[(p - d).y * w + (p - d).x] != 0:
		p -= d
	while _in(p) and _street[p.y * w + p.x] != 0:
		run.append(p)
		p += d
	return run

# --- Поле ------------------------------------------------------------------------------
## Открытая местность: трава пятнами (если есть горючка), руины — коробки стен с
## выбитыми кусками, каменные глыбы.
func _field() -> void:
	var fire := bool(opt["flammable"])
	var noise := FastNoiseLite.new()
	noise.seed = _rng.randi()
	noise.frequency = 0.09
	for y in h:
		for x in w:
			var grass := noise.get_noise_2d(x, y) > -0.2
			_ground(Vector2i(x, y), MCF.FLOOR_GRASS if fire and grass else MCF.FLOOR_NORMAL)
	var area := float(w * h)
	for n in maxi(1, roundi(area / 380.0 * dens)):
		_ruin()
	for n in roundi(area / 320.0 * dens):
		_rock()

## Руина: коробка стен, от которой уцелела половина, пол внутри — голый.
func _ruin() -> void:
	var rw := _rng.randi_range(5, 9)
	var rh := _rng.randi_range(5, 8)
	var r := Rect2i(_rng.randi_range(1, w - rw - 1), _rng.randi_range(1, h - rh - 1), rw, rh)
	var keep_p := _rng.randf_range(0.45, 0.7)
	var edge := _edge_cells(r)
	var rolls: Array[float] = []
	for c in edge:
		rolls.append(_rng.randf())
	for q in _rooms:
		if q.grow(2).intersects(r):
			return
	_rooms.append(r)
	for i in edge.size():
		if rolls[i] < keep_p:
			_put(edge[i], MCF.FEATURE_WALL)
	for y in range(r.position.y + 1, r.end.y - 1):
		for x in range(r.position.x + 1, r.end.x - 1):
			_ground(Vector2i(x, y))
			_indoor[y * w + x] = 1

## Глыба: неровное пятно стены радиусом в одну-две клетки.
func _rock() -> void:
	var c := _random_cell(2)
	var rad := _rng.randf_range(0.8, 1.9)
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var p := c + Vector2i(dx, dy)
			if Vector2(dx, dy).length() + _rng.randf() * 0.6 <= rad and _in(p) \
					and not _inside_room(p):
				_put(p, MCF.FEATURE_WALL)

## Деревянная изгородь с прорехами — горит. Без горючки её нет.
func _fence() -> void:
	var c := _random_cell(2)
	var d: Vector2i = N4[_rng.randi_range(0, 3)]
	for k in _rng.randi_range(4, 9):
		if _rng.randf() < 0.8 and not _inside_room(c + d * k):
			_try_put(c + d * k, MCF.FEATURE_WOOD_WALL)

## Поле: окопы, противотанковые ежи поясами через клетку, гнёзда из мешков подковой,
## щебень в руинах и, при горючке, деревянные изгороди.
func _dress_field() -> void:
	if not bool(opt["obstacles"]):
		return
	var area := float(w * h)
	for n in roundi(area / 190.0 * dens):
		_trench(_random_cell())
	for n in roundi(area / 420.0 * dens):
		var c := _random_cell()
		var d: Vector2i = N4[_rng.randi_range(0, 3)]
		for k in _rng.randi_range(4, 8):
			if k % 2 == 0:
				_try_put(c + d * k, MCF.FEATURE_HEDGEHOG)
	for n in roundi(area / 260.0 * dens):
		_nest(_random_cell())
	for r in _rooms:
		var inner := r.grow(-1)
		for n in _rng.randi_range(1, 3):
			_try_put(Vector2i(_rng.randi_range(inner.position.x, inner.end.x - 1),
					_rng.randi_range(inner.position.y, inner.end.y - 1)), MCF.FEATURE_SANDBAGS)
	if bool(opt["flammable"]):
		for n in roundi(area / 420.0 * dens):
			_fence()

## Окоп: 3–7 клеток, иногда с поворотом.
func _trench(c: Vector2i) -> void:
	var d: Vector2i = N4[_rng.randi_range(0, 3)]
	var n := _rng.randi_range(3, 7)
	var bend := _rng.randi_range(1, n)
	var turn := Vector2i(d.y, d.x) * (1 if _rng.randf() < 0.5 else -1)
	for k in n:
		if k == bend:
			d = turn
		if not _try_put(c, MCF.FEATURE_TRENCH):
			return
		c += d

## Гнездо: подкова из пяти мешков, середина свободна — туда встаёт стрелок.
func _nest(c: Vector2i) -> void:
	var d: Vector2i = N4[_rng.randi_range(0, 3)]
	var s := Vector2i(d.y, d.x)
	for p: Vector2i in [c + d, c + d + s, c + d - s, c + s, c - s]:
		_try_put(p, MCF.FEATURE_SANDBAGS)

## Космос на поверхности (город, поле): рваный край платформы и пробоины-воронки.
func _open_space() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = _rng.randi()
	noise.frequency = 0.13
	for y in h:
		for x in w:
			var edge := mini(mini(x, y), mini(w - 1 - x, h - 1 - y))
			if float(edge) < 1.2 + 2.6 * noise.get_noise_2d(x, y):
				_space(Vector2i(x, y))
	var per := 800.0 if int(opt["style"]) == Style.TOWN else 450.0
	for n in 1 + roundi(w * h / per):
		var c := _random_cell(4)
		var rad := _rng.randf_range(1.5, 2.8)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				if Vector2(dx, dy).length() + noise.get_noise_2d(c.x + dx, c.y + dy) <= rad:
					_space(c + Vector2i(dx, dy))

# --- Зоны развёртывания ------------------------------------------------------------------
## По зоне на слот. Якоря разнесены жадно — каждый следующий как можно дальше от уже
## выбранных, — а зоны растут от якорей по очереди, по клетке за ход. Из нескольких
## попыток берётся та, где самая маленькая зона больше всех, и все зоны срезаются до
## её размера: зона, запертая в тесной комнате, не должна оставлять соседей богаче.
func _zones(n: int) -> void:
	var clear := 0
	for y in h:
		for x in w:
			if _clear(Vector2i(x, y)):
				clear += 1
	var target := clampi(int(clear * ZONE_SHARE / n), _need, _need * 4)
	var cand := _anchor_candidates(n)
	if cand.is_empty():
		return
	var best := -1
	var best_claimed: Array = []
	for gap in ([ZONE_GAP, 2, 1] if _tight else [ZONE_GAP]):
		_gap = gap
		for attempt in 6:
			var an := _pick_anchors(cand, n)
			var smallest := _grow(an, target)
			if smallest > best:
				best = smallest
				best_claimed = _claimed
				_anchors = an
			if best >= target:
				break
		if best >= _need:
			break
	_zone_min = maxi(0, best)
	# Срезаем с конца роста — с дальнего от якоря края: зона остаётся связной и круглой.
	for i in n:
		var cells: Array = best_claimed[i]
		for k in mini(best, cells.size()):
			var c: Vector2i = cells[k]
			_zone[c.y * w + c.x] = i
	m.zone_owner = _zone.duplicate()
	# Кайма в клетку вокруг зон и подходы к проёмам — украшениям туда нельзя.
	for y in h:
		for x in w:
			if _zone[y * w + x] < 0 and _door[y * w + x] == 0:
				continue
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if _in(Vector2i(x + dx, y + dy)):
						_keep[(y + dy) * w + x + dx] = 1

## Где удобно ставить якорь: чистая клетка, вокруг которой (5×5) почти всё чисто.
## Если таких мало — любая чистая.
func _anchor_candidates(n: int) -> Array[Vector2i]:
	var open: Array[Vector2i] = []
	var any: Array[Vector2i] = []
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			if not _clear(c) or _door[y * w + x] != 0:
				continue
			any.append(c)
			var k := 0
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if _clear(c + Vector2i(dx, dy)):
						k += 1
			if k >= 20:
				open.append(c)
	return open if open.size() >= n * 4 else any

func _pick_anchors(cand: Array[Vector2i], n: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	# Первый — ближе к краю карты: из тех, кто от центра дальше 0.6 от самого дальнего.
	var mid := Vector2(w - 1, h - 1) * 0.5
	var score := PackedFloat32Array()
	for c in cand:
		score.append(((Vector2(c) - mid) / Vector2(w, h)).length())
	out.append(_pick_top(cand, score, 0.6))
	while out.size() < n:
		score.clear()
		for c in cand:
			var d := INF
			for a in out:
				d = minf(d, Vector2(c).distance_to(Vector2(a)))
			score.append(d)
		out.append(_pick_top(cand, score, 0.9))
	return out

## Случайный кандидат из тех, чей счёт не ниже доли `share` от лучшего.
func _pick_top(cand: Array[Vector2i], score: PackedFloat32Array, share: float) -> Vector2i:
	var best := 0.0
	for s in score:
		best = maxf(best, s)
	var top: Array[Vector2i] = []
	for i in cand.size():
		if score[i] >= best * share:
			top.append(cand[i])
	return top[_rng.randi_range(0, top.size() - 1)]

## Растим зоны от якорей по очереди. Фронт зоны — соседи с приоритетом «расстояние до
## якоря плюс дрожание»: зона выходит округлой, но с рваным краем. Проём зона проходит
## насквозь, но не занимает — иначе дверь стала бы клеткой расстановки. Возвращает
## размер самой маленькой зоны; клетки каждой зоны — в _claimed.
func _grow(an: Array[Vector2i], target: int) -> int:
	var n := an.size()
	_own = PackedInt32Array()
	_own.resize(w * h)
	_own.fill(-1)
	_seen = PackedByteArray()
	_seen.resize(w * h * n)
	_fronts = []
	_claimed = []
	var sizes := PackedInt32Array()
	sizes.resize(n)
	for i in n:
		_fronts.append([])
		_claimed.append([])
		_push(i, an[i], an[i])
	var grew := true
	while grew:
		grew = false
		for i in n:
			if sizes[i] >= target:
				continue
			var f: Array = _fronts[i]
			while not f.is_empty():
				var bi := 0
				for k in range(1, f.size()):
					if f[k][0] < f[bi][0]:
						bi = k
				var c: Vector2i = f[bi][1]
				f[bi] = f[f.size() - 1]
				f.pop_back()
				var idx := c.y * w + c.x
				if _door[idx] != 0:
					for d: Vector2i in N4:
						_push(i, c + d, an[i])
					continue
				if _own[idx] != -1 or _near_other(c, i):
					continue
				_own[idx] = i
				_claimed[i].append(c)
				sizes[i] += 1
				for d: Vector2i in N4:
					_push(i, c + d, an[i])
				grew = true
				break
	var smallest := target
	for s in sizes:
		smallest = mini(smallest, s)
	return smallest

func _push(i: int, c: Vector2i, anchor: Vector2i) -> void:
	if not _in(c):
		return
	var idx := c.y * w + c.x
	if _seen[i * w * h + idx] != 0:
		return
	_seen[i * w * h + idx] = 1
	if _door[idx] == 0 and not _clear(c):
		return
	_fronts[i].append([Vector2(c).distance_to(Vector2(anchor)) + _rng.randf() * 1.6, c])

func _near_other(c: Vector2i, i: int) -> bool:
	for dy in range(-_gap, _gap + 1):
		for dx in range(-_gap, _gap + 1):
			var p := c + Vector2i(dx, dy)
			if _in(p):
				var z := _own[p.y * w + p.x]
				if z != -1 and z != i:
					return true
	return false

## Пеший путь между всеми зонами: волна от якоря первой зоны по проходимым клеткам.
## Зону, до которой волна не дошла, соединяем ходом «буквой Г» с ближайшей достигнутой
## клеткой. Прорубленная стена становится проёмом, скала — тоннелем.
func _connect_zones() -> void:
	for guard in _anchors.size():
		var reach := _reach(_anchors[0])
		var lost := -1
		for i in range(1, _anchors.size()):
			if reach[_anchors[i].y * w + _anchors[i].x] == 0:
				lost = i
				break
		if lost < 0:
			return
		var a := _anchors[lost]
		var best := _anchors[0]
		var best_d := INF
		for y in h:
			for x in w:
				if reach[y * w + x] != 0:
					var d := Vector2(a).distance_squared_to(Vector2(x, y))
					if d < best_d:
						best_d = d
						best = Vector2i(x, y)
		_tunnel(a, best)

func _reach(from: Vector2i) -> PackedByteArray:
	var seen := _bytes()
	seen[from.y * w + from.x] = 1
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for d: Vector2i in N4:
			var p := c + d
			if _in(p) and seen[p.y * w + p.x] == 0 and _walk(p):
				seen[p.y * w + p.x] = 1
				queue.append(p)
	return seen

func _tunnel(a: Vector2i, b: Vector2i) -> void:
	var bend := Vector2i(b.x, a.y)
	for leg in [[a, bend], [bend, b]]:
		var c: Vector2i = leg[0]
		var to: Vector2i = leg[1]
		var step := (to - c).sign()
		while true:
			if not _walk(c):
				_ground(c)
			if c == to:
				break
			c += step

# --- Мирные ------------------------------------------------------------------------------
## Мирные — кучками по 1–3, в основном «под крышей», и не ближе трёх клеток к чьей-то
## зоне: иначе расстановка упиралась бы в чужого жителя. И они должны начать партию
## СПЯЩИМИ: житель просыпается, как только видит солдата по прямой или рядом с ним
## открывается шлюз (GameActionResolver._update_breached / update_airlocks). Поэтому —
## только туда, куда не смотрит ни одна клетка зон, и не вплотную к шлюзу.
func _civilians() -> void:
	var want := maxi(2, roundi(w * h / 160.0 * dens))
	var near := _bytes()
	for y in h:
		for x in w:
			if _zone[y * w + x] < 0:
				continue
			for dy in range(-3, 4):
				for dx in range(-3, 4):
					if _in(Vector2i(x + dx, y + dy)):
						near[(y + dy) * w + x + dx] = 1
	var seen := _seen_from_zones()
	var free := func(p: Vector2i) -> bool:
		return _in(p) and near[p.y * w + p.x] == 0 and _door[p.y * w + p.x] == 0 \
				and seen[p.y * w + p.x] == 0 and _clear(p) and not _has_spawn(p) \
				and not _near_feature(p, MCF.FEATURE_AIRLOCK)
	var inside: Array[Vector2i] = []
	var outside: Array[Vector2i] = []
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			if not free.call(c):
				continue
			if _indoor[y * w + x] != 0:
				inside.append(c)
			else:
				outside.append(c)
	var placed := 0
	for attempt in want * 8:
		if placed >= want:
			break
		var pool := outside
		if not inside.is_empty() and (outside.is_empty() or _rng.randf() < 0.65):
			pool = inside
		if pool.is_empty():
			break
		var c: Vector2i = pool[_rng.randi_range(0, pool.size() - 1)]
		var group := _rng.randi_range(1, 3)
		for d: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
				Vector2i(0, -1)]:
			if group == 0 or placed >= want:
				break
			if free.call(c + d):
				m.set_spawn(c + d, "civilian", MCF.Owner.NEUTRAL)
				placed += 1
				group -= 1

## Клетки, которые видно хоть из одной клетки зоны по прямой — ряд, столбец или ровная
## диагональ, как в _civ_sees_soldier; стекло взгляду не преграда. Шлюз считаем открытым:
## боец, вставший у двери, распахнёт его ещё до первого хода.
func _seen_from_zones() -> PackedByteArray:
	var seen := _bytes()
	for y in h:
		for x in w:
			if _zone[y * w + x] < 0:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
					Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
				var c := Vector2i(x, y) + d
				while _in(c):
					seen[c.y * w + c.x] = 1
					var f := m.get_feature(c)
					if m.get_cover(c) >= MCF.WALL_HEIGHT and not MCF.is_glass(f) \
							and f != MCF.FEATURE_AIRLOCK:
						break
					c += d
	return seen

func _has_spawn(c: Vector2i) -> bool:
	for s in m.spawns:
		if s["coord"] == c:
			return true
	return false
