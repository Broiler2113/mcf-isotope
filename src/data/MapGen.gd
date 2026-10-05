class_name MapGen
extends RefCounted

## Генератор случайных карт — строка «Random map» в лобби. Четыре стиля (станция, город,
## поле, бункер) собираются из одного числа-зерна: удачную карту можно назвать этим числом, и
## она соберётся снова точно такой же.
##
## По умолчанию карта органическая, без зеркала. Честность держится на другом: зоны
## развёртывания одного размера, разнесены как можно дальше друг от друга, и из любой зоны в
## любую есть пеший путь. С галочкой «Symmetrical» карта зеркальная (_sym): строится левая
## половина (или левая верхняя четверть) и отражается, а зоны растут сразу вместе со своими
## отражениями — у каждой стороны та же местность, что у соседа, только в зеркале.
##
## Зона обязана вместить отряд: на бойца — CELLS_PER_UNIT клеток. Не влезли на выбранном
## размере — поле растёт (до MAX_DIM) и строится заново. Мирные ставятся туда, где их не
## видно ни из одной зоны: иначе они проснулись бы от первого же хода.
##
## Отрезанного пола на готовой карте нет: дом без двери, комната за зеркальной осью, закуток
## за ящиками соединяются с остальной картой самым коротким проломом (_join_pockets).
##
## Двери — шлюзы. Каждый проём дома, комнаты станции и бункера, хижины в поле — шлюз, с
## космосом или без: закрытый шлюз держит взгляд, как стена, и открывается перед бойцом.
## Поэтому мирные живут только в таких запертых помещениях и начинают партию спящими.
##
## Строит карту только хост: гостю уезжает готовая MapData (K_LOBBY_MAP), так что сети
## детерминизм генератора не нужен — он нужен зерну. Каждая фаза тянет числа из СВОЕГО
## потока, поэтому снятая галочка «Civilians» убирает мирных, а не перекраивает улицы.
##
## Поле бывает до 250×250 (MAX_DIM), а лобби пересобирает карту на каждый щелчок настроек:
## всё, что проходит по полю целиком, здесь линейно по числу клеток.

enum Style {STATION, TOWN, FIELD, BUNKER, ASTEROID}
const STYLE_NAMES := ["Station", "Town", "Field", "Bunker", "Asteroid"]
## Окружение карты по стилю (item 24) — им MapData выбирает плитки пола и стен.
const STYLE_ENV := ["station", "town", "field", "bunker", "asteroid"]
## Что включено по умолчанию у стиля (items 25/26): у города, поля и бункера космоса нет,
## у бункера и станции нечему гореть, астероид — город в космосе, но не горит.
const STYLE_SPACE := [true, false, false, false, true]
const STYLE_FLAMMABLE := [false, true, true, false, false]
const SIZES := [Vector2i(28, 20), Vector2i(38, 28), Vector2i(50, 38), Vector2i(80, 60),
		Vector2i(125, 95), Vector2i(250, 250)]
const SIZE_NAMES := ["Small", "Medium", "Large", "Huge", "Giant", "Colossal"]
## Пункт размера «свой»: ширина и высота берутся из настроек "width"/"height". Всегда
## следующий за последним готовым размером (== SIZES.size()).
const SIZE_CUSTOM := 6
const MIN_DIM := 16
const DENSITY_NAMES := ["Sparse", "Normal", "Dense"]
const DENSITY_MULT := [0.55, 1.0, 1.6]
const SEED_MAX := 9999999
## Какая доля чистого пола уходит под зоны развёртывания всех сторон вместе — если
## отряды просят меньше. Больше чем вчетверо против нужного зона не раздувается.
const ZONE_SHARE := 0.3
## Клеток зоны на бойца: есть где развернуться и куда поставить технику (танк — 3×3).
const CELLS_PER_UNIT := 2
## Дальше этого поле не растёт — ни по выбору игрока, ни когда отряды не влезают.
const MAX_DIM := Vector2i(250, 250)
## Ближе этого (по Чебышёву) клетки разных зон друг к другу не подходят. Только если
## отряды не влезают и на самом большом поле, зазор ужимается до 2, потом до 1.
const ZONE_GAP := 3
const ZONE_MIN := 16
## Сколько мирных: порядок величины, а не точное число. Базовая норма — житель на 160
## клеток при обычной застройке; уровень множит её и ограничивает сверху (слот жителей
## играется весь за один ход, так что без потолка поле 250×250 получило бы сотни жителей).
## Старое значение настройки — true/false — читается как Normal/None.
const CIV_LEVELS := ["None", "Few", "Normal", "Many", "Crowd"]
const CIV_MULT := [0.0, 0.35, 1.0, 2.5, 6.0]
const CIV_MIN := [0, 1, 2, 4, 8]
const CIV_CAP := [0, 12, 32, 80, 200]
## Больше этого мирных не бывает ни на каком уровне.
const CIV_MAX := 1000
## Якорей-кандидатов не больше этого: на большой карте берётся каждый k-й. Якорь нужен
## «где-то здесь», а перебор всех 60 000 клеток поля 250×250 — секунды на каждую попытку.
const CAND_MAX := 6000

## FURNITURE — последней в перечне: номер фазы входит в зерно её потока, и новая фаза не
## должна сдвигать номера прежних (иначе все карты прежних зёрен перекроились бы).
enum Phase {STRUCTURE, SPACE, ZONES, DRESSING, CIVILIANS, FURNITURE}

const N4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const DIRS8 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]

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
var _style := Style.TOWN
## Симметрия: 0 — нет, 1 — зеркало слева направо, 2 — ещё и сверху вниз (четыре четверти).
var _sym := 0
## Клетки «под крышей» — комнаты станции, дома, руины. Мирные живут в основном тут.
var _indoor: PackedByteArray
## Дверные проёмы. Зона сквозь них прорастает, но их не занимает; шлюзы — только в них.
var _door: PackedByteArray
var _doors: Array[Vector2i] = []
## Комнаты станции, дома города, руины поля — прямоугольники со стенами по краю.
var _rooms: Array[Rect2i] = []
var _room_mask: PackedByteArray   # клетки прямоугольников _rooms (для поля)
var _parks: Array[Rect2i] = []
var _street: PackedByteArray
var _k: PackedByteArray
var _room_min := 6                # сторона самой маленькой комнаты станции, со стенами
## Номер зоны клетки (-1 — не зона) и якорь каждой зоны.
var _zone: PackedInt32Array
var _anchors: Array[Vector2i] = []
## Где украшениям не место: зоны с каймой, проёмы и подходы к ним.
var _keep: PackedByteArray
# Рабочие массивы роста зон — члены, чтобы _grow, _push, _claim и _near_other делили их,
# не передавая друг другу.
var _own: PackedInt32Array
var _seen: PackedByteArray
var _fronts: Array = []           # по представителю — куча [приоритет, клетка]
var _claimed: Array = []          # по представителю — его клетки в порядке захвата
var _gap := ZONE_GAP
var _need := ZONE_MIN             # клеток на зону, чтобы влез отряд
var _tight := false               # поле уже предельное — можно ужимать зазор между зонами
var _zone_min := 0                # сколько клеток досталось каждой зоне
var _zone_n := 2
## Зоны растут «представителями»: представитель — это зона вместе со всеми её отражениями
## (или одна зона на оси, которая отражается сама в себя). Без симметрии представитель и
## есть зона. По представителю — номер зоны для каждого преобразования группы (_img).
var _rep_ids: Array = []
var _rep_fold: Array[bool] = []

static func default_options() -> Dictionary:
	return {"style": Style.TOWN, "size": 1, "density": 1, "seed": 1, "zones": 2, "units": 10,
			"width": 80, "height": 60, "symmetric": false,
			"space": true, "flammable": true, "obstacles": true, "civilians": 2,
			"furniture": MapFurnish.DEFAULT_DENSITY}

## Уровень мирных по настройке: число 0…4 или прежнее true/false.
## Будут ли на карте мирные: число с ползунка лобби (item 11), а без него — уровень.
static func civ_wanted(options: Dictionary) -> bool:
	if int(options.get("civilian_count", -1)) >= 0:
		return int(options["civilian_count"]) > 0
	return civ_level(options) > 0

static func civ_level(options: Dictionary) -> int:
	var v: Variant = options.get("civilians", 2)
	if v is bool:
		return 2 if v else 0
	return clampi(int(v), 0, CIV_LEVELS.size() - 1)

## Сколько клеток нужно зоне, чтобы в неё встал отряд из `units` бойцов.
static func zone_need(units: int) -> int:
	return maxi(ZONE_MIN, units * CELLS_PER_UNIT)

## Размер поля по настройкам: готовый пункт списка или свой (SIZE_CUSTOM). У своего
## потолка нет — только нижняя граница MIN_DIM; MAX_DIM ограничивает лишь авто-рост поля,
## когда отряды не влезают.
static func dims_of(options: Dictionary) -> Vector2i:
	var s := int(options.get("size", 1))
	if s >= 0 and s < SIZES.size():
		return SIZES[s]
	return Vector2i(maxi(MIN_DIM, int(options.get("width", 80))),
			maxi(MIN_DIM, int(options.get("height", 60))))

## Собрать карту. Ключи настроек — как в default_options(); недостающие берутся оттуда.
## Отряды не влезли в зоны — поле растёт пропорционально нехватке и строится заново.
static func generate(options: Dictionary) -> MapData:
	var o := default_options()
	o.merge(options, true)
	var dim := dims_of(o)
	var need := zone_need(int(o["units"]))
	var g: MapGen = null
	for attempt in 6:
		var last := attempt == 5 or (dim.x >= MAX_DIM.x and dim.y >= MAX_DIM.y) \
				or dim.x * dim.y >= MAX_DIM.x * MAX_DIM.y
		g = MapGen.new()
		g._build(o, dim, need, last)
		if g._zone_min >= need or last:
			break
		var grow := clampf(sqrt(float(need) / maxf(1.0, float(g._zone_min))) * 1.1, 1.15, 2.0)
		dim = Vector2i(maxi(dim.x, mini(ceili(dim.x * grow), MAX_DIM.x)),
				maxi(dim.y, mini(ceili(dim.y * grow), MAX_DIM.y)))
	return g.m

func _build(options: Dictionary, dim: Vector2i, need: int, tight: bool) -> void:
	opt = options
	_need = need
	_tight = tight
	w = dim.x
	h = dim.y
	dens = DENSITY_MULT[clampi(int(opt["density"]), 0, DENSITY_MULT.size() - 1)]
	_style = int(opt["style"])
	var n := clampi(int(opt["zones"]), 2, MCF.MAX_PLAYERS)
	# Четыре четверти — когда стороны делятся на них поровну (по стороне на четверть);
	# иначе зеркало слева направо, и при нечётном числе одна зона стоит на оси.
	_sym = 0 if not bool(opt.get("symmetric", false)) else (2 if n % 4 == 0 else 1)
	m = MapData.new(w, h)
	m.env = STYLE_ENV[clampi(_style, 0, STYLE_ENV.size() - 1)]
	_indoor = _bytes()
	_door = _bytes()
	_street = _bytes()
	_keep = _bytes()
	_room_mask = _bytes()
	_zone = PackedInt32Array()
	_zone.resize(w * h)
	_zone.fill(-1)
	_phase(Phase.STRUCTURE)
	match _style:
		Style.STATION, Style.BUNKER:
			_station()
		Style.FIELD:
			_field()
		_:
			_town()
	_mirror()
	_join_pockets(Vector2i(-1, -1))
	_seal_doors()
	_phase(Phase.SPACE)
	# Бункер под землёй: ни вакуума в отсеке, ни рваного края — только шлюзы-двери.
	if _style == Style.ASTEROID:
		_asteroid()   # остров — и с космосом, и без (тогда вокруг сплошная скала)
	elif bool(opt["space"]) and _style != Style.BUNKER:
		if _style == Style.STATION:
			_vent_room()
		else:
			_open_space()
	_mirror()
	_phase(Phase.ZONES)
	_zones(n)
	_phase(Phase.DRESSING)
	match _style:
		Style.STATION, Style.BUNKER:
			_dress_station()
		Style.FIELD:
			_dress_field()
		_:
			_dress_town()
	_mirror()
	# После украшений ещё раз: ящики и глыбы тоже могут отрезать кусок пола, а зоны должны
	# быть связаны пешком — главная часть теперь та, где стоит первая зона.
	if not _anchors.is_empty():
		_join_pockets(_anchors[0])
	# Мебель (§3.15) — после всех проломов: двери и проходы уже окончательные, и
	# обстановка их обходит сама. Своим потоком: «Off» не трогает ни одной клетки.
	_phase(Phase.FURNITURE)
	MapFurnish.run(self)
	_phase(Phase.CIVILIANS)
	if civ_wanted(opt):
		_civilians()
		_mirror_spawns()

## Свой поток случайных чисел на каждую фазу (см. шапку). Бункер тянет из потоков станции:
## то же зерно — та же станция, только под землёй.
func _phase(p: int) -> void:
	var style_seed := Style.STATION if _style == Style.BUNKER else _style
	_rng = RandomNumberGenerator.new()
	_rng.seed = int(opt["seed"]) * 1000003 + p * 7919 + style_seed * 131 \
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
	m.set_cell(c, m.get_floor(c), maxf(0.0, MCF.feature_height(feature)), false, feature)

## Пустота за постройками: космос, а без космоса — сплошная скала; бункер вырыт в грунте.
func _void(c: Vector2i) -> void:
	if _style == Style.BUNKER:
		_put(c, MCF.FEATURE_SOIL)
	elif bool(opt["space"]):
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

## То же, что _clear, для всего поля разом.
func _clear_mask() -> PackedByteArray:
	var out := _bytes()
	for i in w * h:
		if m.is_space[i] == 0 and m.feature_id[i] == "" and m.cover_height[i] <= 0.0:
			out[i] = 1
	return out

## Проходима ли клетка пешком на пустой доске — то же, что GridCell.walkable_terrain():
## всё ниже стены, космос и шлюз. Ёж не считается: его только перепрыгивают, а путь
## «через ежа» не нужен, чтобы части карты были связаны.
func _walk_mask() -> PackedByteArray:
	var out := _bytes()
	for i in w * h:
		var f: String = m.feature_id[i]
		if f == MCF.FEATURE_AIRLOCK:
			out[i] = 1
		elif f != MCF.FEATURE_HEDGEHOG and f != MCF.FEATURE_DRONE_STATION \
				and (m.is_space[i] != 0 or m.cover_height[i] < MCF.WALL_HEIGHT):
			out[i] = 1
	return out

## Каждый проём — шлюз (см. шапку). Двери размечены ещё при постройке (_door), шлюз
## встаёт в каждую, пол под ним прежний.
func _seal_doors() -> void:
	for d in _doors:
		if m.get_feature(d) == "":
			_put(d, MCF.FEATURE_AIRLOCK)

## Клетка-стена (или стекло, или шлюз): через неё не ходят и не смотрят поперёк.
func _is_wallish(c: Vector2i) -> bool:
	if not _in(c):
		return true
	return m.get_cover(c) >= MCF.WALL_HEIGHT

## Проход «как дверь»: стены с двух противоположных сторон, проходимо с двух других.
func _door_shaped(c: Vector2i, walk: PackedByteArray) -> bool:
	var open := func(p: Vector2i) -> bool: return _in(p) and walk[p.y * w + p.x] != 0
	return (_is_wallish(c + Vector2i(1, 0)) and _is_wallish(c - Vector2i(1, 0))
			and open.call(c + Vector2i(0, 1)) and open.call(c - Vector2i(0, 1))) \
			or (_is_wallish(c + Vector2i(0, 1)) and _is_wallish(c - Vector2i(0, 1))
			and open.call(c + Vector2i(1, 0)) and open.call(c - Vector2i(1, 0)))

## Украшение ставится только на чистую клетку и не туда, где зона или проём, — и никогда
## вплотную к шлюзу: ящик за внешним шлюзом обшивки (он встаёт уже после разметки проёмов)
## превращал дверь в тупик.
func _try_put(c: Vector2i, feature: String) -> bool:
	if not _clear(c) or _keep[c.y * w + c.x] != 0:
		return false
	for d: Vector2i in N4:
		if m.get_feature(c + d) == MCF.FEATURE_AIRLOCK:
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
	return _in(c) and _room_mask[c.y * w + c.x] != 0

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

# --- Симметрия ---------------------------------------------------------------------------
## Преобразований в группе симметрии: 1, 2 (зеркало) или 4 (четверти).
func _group() -> int:
	return [1, 2, 4][_sym]

## Образ клетки при g-м преобразовании: 0 — сама клетка, 1 — отражение по ширине,
## 2 — по высоте, 3 — по обеим сразу.
func _img(c: Vector2i, g: int) -> Vector2i:
	return Vector2i(w - 1 - c.x if (g & 1) != 0 else c.x, h - 1 - c.y if (g & 2) != 0 else c.y)

## Клетка «исходной» части — левой половины (или левой верхней четверти): строится
## она, всё остальное — её отражения. Без симметрии исходное — всё поле.
func _in_f(c: Vector2i) -> bool:
	return (_sym == 0 or c.x <= (w - 1) / 2) and (_sym < 2 or c.y <= (h - 1) / 2)

## Индекс клетки исходной части, отражением которой является (x, y).
func _src_index(x: int, y: int) -> int:
	var sx := mini(x, w - 1 - x) if _sym >= 1 else x
	var sy := mini(y, h - 1 - y) if _sym >= 2 else y
	return sy * w + sx

## Переписать всё вне исходной части её отражением: клетки карты, служебные разметки и
## списки комнат. Зоны и мирных это не касается — у них свой симметричный путь.
func _mirror() -> void:
	if _sym == 0:
		return
	var has_k := _k.size() == w * h
	for y in h:
		for x in w:
			var i := y * w + x
			var s := _src_index(x, y)
			if s == i:
				continue
			m.floor_type[i] = m.floor_type[s]
			m.cover_height[i] = m.cover_height[s]
			m.is_space[i] = m.is_space[s]
			m.feature_id[i] = m.feature_id[s]
			_indoor[i] = _indoor[s]
			_door[i] = _door[s]
			_street[i] = _street[s]
			_room_mask[i] = _room_mask[s]
			if has_k:
				_k[i] = _k[s]
	_doors.clear()
	for i in w * h:
		if _door[i] != 0:
			_doors.append(Vector2i(i % w, i / w))
	_rooms = _mirror_rects(_rooms)
	_parks = _mirror_rects(_parks)

## Прямоугольники после отражения: целиком в исходной части — он и его образы; через
## ось — растянутый до симметричного (такой он теперь на карте); целиком за осью —
## пропадает: его место заняло отражение другого.
func _mirror_rects(list: Array[Rect2i]) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var have := {}
	for r in list:
		var xs := _fold_span(r.position.x, r.end.x, w, _sym >= 1)
		var ys := _fold_span(r.position.y, r.end.y, h, _sym >= 2)
		for sx: Vector2i in xs:
			for sy: Vector2i in ys:
				var q := Rect2i(sx.x, sy.x, sx.y - sx.x, sy.y - sy.x)
				if not have.has(q):
					have[q] = true
					out.append(q)
	return out

## Отрезок [a, b) одной оси после отражения этой оси — его образы.
func _fold_span(a: int, b: int, n: int, on: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not on:
		out.append(Vector2i(a, b))
		return out
	var last := (n - 1) / 2          # последняя клетка исходной части
	if a > last:
		return out
	if b - 1 <= last:
		out.append(Vector2i(a, b))
		out.append(Vector2i(n - b, n - a))
	else:
		out.append(Vector2i(a, n - a))
	return out

## Мирные симметрично: стоящие в исходной части остаются и отражаются, прочие уходят.
func _mirror_spawns() -> void:
	if _sym == 0:
		return
	var out: Array = []
	var taken := {}
	for s in m.spawns:
		var c: Vector2i = s["coord"]
		if not _in_f(c):
			continue
		for g in _group():
			var p := _img(c, g)
			if taken.has(p):
				continue
			taken[p] = true
			var copy: Dictionary = s.duplicate()
			copy["coord"] = p
			out.append(copy)
	m.spawns = out

# --- Станция и бункер ------------------------------------------------------------------
## Отсеки и коридоры. Всё поле делится пополам, половины — снова пополам, и так далее
## (BSP), а каждая линия раздела становится коридором: сверху широкий, 2–3 клетки, глубже
## уже. Раз каждый коридор тянется через весь свой кусок, он упирается концами в коридор
## уровнем выше — сеть связна сама собой. Получившиеся блоки — отсеки: каждый делится
## стенами на комнаты (стена общая, в каждой перегородке дверь, иногда две), и у каждого
## отсека есть хотя бы одна дверь в коридор. Часть отсеков пустует — у краёв чаще: там
## космос (или скала бункера), и коридор идёт мимо, как труба с окнами.
##
## Бункер — та же станция из тех же чисел, только вместо космоса скала (см. _void).
func _station() -> void:
	_k = _bytes()
	var di := clampi(int(opt["density"]), 0, 2)
	var sector_min: int = [15, 12, 10][di]
	# Хотя бы один коридор на любом поле: отсек не больше, чем влезает два поперёк самой
	# длинной стороны (иначе маленькая станция была бы одним отсеком без коридоров).
	sector_min = mini(sector_min, (maxi(w, h) - 5) / 2)
	_room_min = [7, 6, 5][di]
	var sectors: Array[Rect2i] = []
	_split_sectors(Rect2i(1, 1, w - 2, h - 2), sector_min, 0, sectors)
	# Пустые отсеки — у краёв чаще, но не больше пятой части: на карте из шести отсеков,
	# где все у края, прежний бросок «каждому по 20%» оставлял от станции скелет коридоров.
	var empty_left := sectors.size() / 5
	for s in sectors:
		var edge := s.position.x <= 1 or s.position.y <= 1 or s.end.x >= w - 1 or s.end.y >= h - 1
		var empty_roll := _rng.randf()
		if empty_left > 0 and empty_roll < (0.25 if edge else 0.08):
			empty_left -= 1
			continue
		_sector_rooms(s)
	if _sym > 0:
		for y in h:
			for x in w:
				_k[y * w + x] = _k[_src_index(x, y)]
		_rooms = _mirror_rects(_rooms)
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

## Делит кусок коридором, пока обе стороны не меньше `mn`. Листья — отсеки.
func _split_sectors(r: Rect2i, mn: int, depth: int, out: Array[Rect2i]) -> void:
	var hall_w := 2
	var width_roll := _rng.randf()
	if depth == 0:
		hall_w = 3 if width_roll < 0.5 else 2
	elif depth >= 2:
		hall_w = 1 if width_roll < 0.45 else 2
	var can_x := r.size.x >= mn * 2 + hall_w
	var can_y := r.size.y >= mn * 2 + hall_w
	# Иногда средний кусок не делится дальше — отсек выходит большим, в нём больше комнат.
	var stop_roll := _rng.randf()
	var split_roll := _rng.randf()
	if not (can_x or can_y) \
			or (depth > 0 and stop_roll < 0.12 and r.size.x < mn * 3 and r.size.y < mn * 3):
		out.append(r)
		return
	var along_x := can_x and (not can_y or split_roll < float(r.size.x) / float(r.size.x + r.size.y))
	if along_x:
		var cut := _rng.randi_range(mn, r.size.x - mn - hall_w)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x + cut, r.position.x + cut + hall_w):
				_k[y * w + x] = K_HALL
		_split_sectors(Rect2i(r.position.x, r.position.y, cut, r.size.y), mn, depth + 1, out)
		_split_sectors(Rect2i(r.position.x + cut + hall_w, r.position.y,
				r.size.x - cut - hall_w, r.size.y), mn, depth + 1, out)
	else:
		var cut := _rng.randi_range(mn, r.size.y - mn - hall_w)
		for y in range(r.position.y + cut, r.position.y + cut + hall_w):
			for x in range(r.position.x, r.end.x):
				_k[y * w + x] = K_HALL
		_split_sectors(Rect2i(r.position.x, r.position.y, r.size.x, cut), mn, depth + 1, out)
		_split_sectors(Rect2i(r.position.x, r.position.y + cut + hall_w, r.size.x,
				r.size.y - cut - hall_w), mn, depth + 1, out)

## Отсек: стены по краю, комнаты внутри, двери в коридоры. Каждая комната, выходящая
## стеной на коридор, получает дверь с вероятностью ~половина — но отсек без двери не
## остаётся: не выпало ни одной — дверь ставится принудительно.
func _sector_rooms(s: Rect2i) -> void:
	for y in range(s.position.y, s.end.y):
		for x in range(s.position.x, s.end.x):
			_k[y * w + x] = K_WALL if _on_edge(s, Vector2i(x, y)) else K_ROOM
	var leaves: Array[Rect2i] = []
	_split_room(s, leaves)
	_rooms.append_array(leaves)
	var spare: Array[Vector2i] = []
	var doors := 0
	for r in leaves:
		var cands := _hall_door_cells(r)
		var roll := _rng.randf()
		var pick := _rng.randi()
		if cands.is_empty():
			continue
		spare.append_array(cands)
		var c := cands[pick % cands.size()]
		if roll < 0.55 and _door_ok(c):
			_k[c.y * w + c.x] = K_DOOR
			doors += 1
	if doors == 0 and not spare.is_empty():
		var start := _rng.randi_range(0, spare.size() - 1)
		for k in spare.size():
			var c := spare[(start + k) % spare.size()]
			if _door_ok(c):
				_k[c.y * w + c.x] = K_DOOR
				break

## Делит комнату общей стеной, пока обе части не меньше _room_min; в стене — дверь.
## Новая стена не должна упереться торцом в дверь на периметре: та вела бы в стену.
func _split_room(r: Rect2i, leaves: Array[Rect2i]) -> void:
	var mn := _room_min
	var can_x := r.size.x >= mn * 2 - 1
	var can_y := r.size.y >= mn * 2 - 1
	var big_roll := _rng.randf()
	var split_roll := _rng.randf()
	if not (can_x or can_y) or (big_roll < 0.12 and r.size.x < mn * 3 and r.size.y < mn * 3):
		leaves.append(r)
		return
	var along_x := can_x and (not can_y or split_roll < float(r.size.x) / float(r.size.x + r.size.y))
	for attempt in 4:
		if along_x:
			var cx := r.position.x + _rng.randi_range(mn - 1, r.size.x - mn)
			if _kind(cx, r.position.y) == K_DOOR or _kind(cx, r.end.y - 1) == K_DOOR:
				continue
			for y in range(r.position.y + 1, r.end.y - 1):
				_k[y * w + cx] = K_WALL
			_wall_doors(Vector2i(cx, r.position.y + 1), Vector2i(0, 1), r.size.y - 2)
			_split_room(Rect2i(r.position.x, r.position.y, cx - r.position.x + 1, r.size.y), leaves)
			_split_room(Rect2i(cx, r.position.y, r.end.x - cx, r.size.y), leaves)
			return
		var cy := r.position.y + _rng.randi_range(mn - 1, r.size.y - mn)
		if _kind(r.position.x, cy) == K_DOOR or _kind(r.end.x - 1, cy) == K_DOOR:
			continue
		for x in range(r.position.x + 1, r.end.x - 1):
			_k[cy * w + x] = K_WALL
		_wall_doors(Vector2i(r.position.x + 1, cy), Vector2i(1, 0), r.size.x - 2)
		_split_room(Rect2i(r.position.x, r.position.y, r.size.x, cy - r.position.y + 1), leaves)
		_split_room(Rect2i(r.position.x, cy, r.size.x, r.end.y - cy), leaves)
		return
	leaves.append(r)

## Дверь в перегородке длиной `n` от `start` по `dir`; в длинной — иногда вторая, не
## рядом с первой: у комнаты два выхода, и бой не упирается в одну дверь.
func _wall_doors(start: Vector2i, dir: Vector2i, n: int) -> void:
	var a := _rng.randi_range(0, n - 1)
	var second_roll := _rng.randf()
	var b := _rng.randi_range(0, n - 1)
	var p := start + dir * a
	_k[p.y * w + p.x] = K_DOOR
	if n >= 7 and second_roll < 0.25 and absi(b - a) >= 3:
		var q := start + dir * b
		_k[q.y * w + q.x] = K_DOOR

## Клетки стены комнаты, где может быть дверь в коридор: не угол, снаружи коридор, внутри
## комната (а не торец перегородки).
func _hall_door_cells(r: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in _edge_cells(r):
		if _is_corner(r, c):
			continue
		var d := _outward(r, c)
		if _kind(c.x + d.x, c.y + d.y) == K_HALL and _kind(c.x - d.x, c.y - d.y) == K_ROOM:
			out.append(c)
	return out

## Двери не ставятся вплотную друг к другу — двойной проём читается как дыра в стене.
func _door_ok(c: Vector2i) -> bool:
	for d: Vector2i in DIRS8:
		if _kind(c.x + d.x, c.y + d.y) == K_DOOR:
			return false
	return true

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
## Проход, прошедший ВДОЛЬ стены, снёс её целиком — это уже не дверь, а открытый край.
func _is_doorway(x: int, y: int) -> bool:
	var wall := func(k: int) -> bool: return k == K_WALL or k == K_DOOR
	var open := func(k: int) -> bool: return k == K_ROOM or k == K_HALL
	var wall_x: bool = wall.call(_kind(x - 1, y)) and wall.call(_kind(x + 1, y))
	var wall_y: bool = wall.call(_kind(x, y - 1)) and wall.call(_kind(x, y + 1))
	var pass_x: bool = open.call(_kind(x - 1, y)) and open.call(_kind(x + 1, y))
	var pass_y: bool = open.call(_kind(x, y - 1)) and open.call(_kind(x, y + 1))
	return (wall_x and pass_y) or (wall_y and pass_x)

## Разгерметизированные отсеки: комната на ~40 (не на каждой станции) — в невесомости.
## Их проёмы потом обязательно получат шлюзы. При симметрии — из исходной части, чтобы
## у отсека было отражение.
func _vent_room() -> void:
	var pool: Array[Rect2i] = []
	for r in _rooms:
		if _in_f(r.get_center()):
			pool.append(r)
	if pool.size() < 4:
		return
	for n in maxi(1, pool.size() / 40):
		var roll := _rng.randf()
		var r := pool[_rng.randi_range(0, pool.size() - 1)]
		if roll > 0.7:
			continue
		for y in range(r.position.y + 1, r.end.y - 1):
			for x in range(r.position.x + 1, r.end.x - 1):
				if _k[y * w + x] == K_ROOM:
					_space(Vector2i(x, y))

func _vented(r: Rect2i) -> bool:
	return m.get_space(r.get_center())

## Станция и бункер: окна и выходы в открытый космос в обшивке (шлюзы в проёмах уже
## стоят — _seal_doors), деревянные палубы складов — и уже потом мебель: колонны в больших
## залах, ящики, баррикады в коридорах.
func _dress_station() -> void:
	# Шлюзы в проёмах уже стоят (_seal_doors); здесь — обшивка: окна и выходы наружу.
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
		# Ящики кучками по 1–3; на деревянной палубе часть из них — дощатые, 2 м. Когда
		# комнаты обставлены мебелью (§3.15), куч мешков в них нет — ящики там свои; числа
		# при этом тянутся те же, чтобы всё прочее на карте легло как без мебели.
		var furnished := int(opt.get("furniture", 0)) > 0
		for n in roundi(inner.get_area() * 0.07 * dens):
			var c := Vector2i(_rng.randi_range(inner.position.x, inner.end.x - 1),
					_rng.randi_range(inner.position.y, inner.end.y - 1))
			var dir: Vector2i = N4[_rng.randi_range(0, 3)]
			var crate := MCF.FEATURE_SANDBAGS
			if wooden[ri] and _rng.randf() < 0.5:
				crate = MCF.FEATURE_WOOD_WALL
			for k in _rng.randi_range(1, 3):
				if not furnished:
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
	if not m.is_space.has(1):
		return out
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
## и не за край карты. Не нашлась за дюжину попыток — дом остаётся без этой двери (а дом
## совсем без дверей потом получит пролом — см. _join_pockets).
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
	for n in maxi(1, roundi(area / 650.0 * dens)):
		_hut()
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
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_room_mask[y * w + x] = 1
	for i in edge.size():
		if rolls[i] < keep_p:
			_put(edge[i], MCF.FEATURE_WALL)
	for y in range(r.position.y + 1, r.end.y - 1):
		for x in range(r.position.x + 1, r.end.x - 1):
			_ground(Vector2i(x, y))
			_indoor[y * w + x] = 1

## Хижина: маленький дом со шлюзом вместо двери и окошком — единственное в поле место,
## где могут жить мирные (они селятся только за шлюзами). Стены — камень, а при горючке
## иногда доски.
func _hut() -> void:
	var rw := _rng.randi_range(5, 7)
	var rh := _rng.randi_range(5, 6)
	var r := Rect2i(_rng.randi_range(2, w - rw - 2), _rng.randi_range(2, h - rh - 2), rw, rh)
	var wooden := _rng.randf() < 0.4 and bool(opt["flammable"])
	var door_side := _rng.randi_range(0, 3)
	var window_roll := _rng.randi_range(0, 9999)
	if r.position.x < 2 or r.position.y < 2:
		return
	for q in _rooms:
		if q.grow(2).intersects(r):
			return
	_rooms.append(r)
	var wall := MCF.FEATURE_WOOD_WALL if wooden else MCF.FEATURE_WALL
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_room_mask[y * w + x] = 1
			var c := Vector2i(x, y)
			if _on_edge(r, c):
				_put(c, wall)
			else:
				_ground(c)
				_indoor[y * w + x] = 1
	var mid := Vector2i((r.position.x + r.end.x - 1) / 2, (r.position.y + r.end.y - 1) / 2)
	var door: Vector2i = [Vector2i(mid.x, r.position.y), Vector2i(mid.x, r.end.y - 1),
			Vector2i(r.position.x, mid.y), Vector2i(r.end.x - 1, mid.y)][door_side]
	_ground(door)
	_mark_door(door)
	# Перед дверью — свободно: глыбы и изгороди ставятся уже после хижин и обходят
	# _room_mask, так что три клетки перед порогом метим как часть хижины.
	var out_dir := _outward(r, door)
	var side_dir := Vector2i(out_dir.y, out_dir.x)
	for k: int in [-1, 0, 1]:
		var front := door + out_dir + side_dir * k
		if _in(front):
			_room_mask[front.y * w + front.x] = 1
	# Окно — на стене напротив двери: изнутри видно поле, но из зоны мирного не видно
	# (_seen_from_zones стекло не останавливает, и такие клетки им не достанутся).
	var edge := _edge_cells(r)
	for k in edge.size():
		var c := edge[(window_roll + k) % edge.size()]
		if not _is_corner(r, c) and c != door and not _near_door(c):
			_put(c, MCF.FEATURE_GLASS)
			break

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
	# Нитки окопов — главная черта поля. Их число и длина растут с плотностью: на редкой
	# карте это пара линий у складок местности, на плотной — сплошная система позиций.
	for n in roundi(area / 420.0 * dens):
		_trench_line(_random_cell(), roundi(float(w + h) * 0.25 * (0.6 + 0.4 * dens)))
	# Одиночные ячейки остались, но их втрое меньше: поле и так изрыто линиями, а стакан
	# коротких огрызков поверх них читался как мусор, а не как позиция.
	for n in roundi(area / 430.0 * dens):
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

## Нитка окопов через поле: длинные прямые участки вдоль одного направления, разбитые
## короткими изломами вбок. Излом здесь не для красоты — он и в жизни затем, чтобы окоп
## не простреливался насквозь во всю длину, и в игре работает так же.
##
## Упор в занятую клетку нитку НЕ обрывает: она шагает дальше и ложится там, где свободно.
## Иначе каждая линия умирала бы о первый же куст мешков, и «длинных» их не бывало бы
## вовсе. Шаги считаются отдельно от уложенных клеток и ограничены сверху, поэтому нитка
## не может ни зациклиться, ни блуждать по карте бесконечно.
func _trench_line(c: Vector2i, length: int) -> void:
	if length <= 0:
		return
	var main: Vector2i = N4[_rng.randi_range(0, 3)]
	var side := Vector2i(main.y, main.x)
	var left := length
	var steps := 0
	var cap := length * 3
	while left > 0 and steps < cap:
		for _k in _rng.randi_range(3, 6):
			if left <= 0 or steps >= cap:
				return
			steps += 1
			if not _in(c):
				return
			if _try_put(c, MCF.FEATURE_TRENCH):
				left -= 1
			c += main
		var s := side * (1 if _rng.randf() < 0.5 else -1)
		for _k in _rng.randi_range(1, 2):
			if left <= 0 or steps >= cap:
				return
			steps += 1
			if not _in(c):
				return
			if _try_put(c, MCF.FEATURE_TRENCH):
				left -= 1
			c += s

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
## Астероид (item 26): город на островке посреди космоса. Всё дальше неровного края
## острова — пустота (_void: открытый космос, а без него — скала); край рваный, и дома, на
## которые он пришёлся, остаются разломанными, будто кусок города оторвало. Плотность
## застройки — та же «Density», что у города.
func _asteroid() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = _rng.randi()
	noise.frequency = 0.06
	var half := Vector2((w - 1) * 0.5, (h - 1) * 0.5)
	for y in h:
		for x in w:
			# Эллипс по размеру поля: остров вписан в доску, сколько бы её ни вытянули.
			var d := Vector2((x - half.x) / half.x, (y - half.y) / half.y).length()
			if d > 0.88 + 0.14 * noise.get_noise_2d(x, y):
				_void(Vector2i(x, y))
	# Дверь, за которой теперь скала (космос выключен), — уже не дверь: заделываем. Комнату
	# за ней, если она отрезана, вскроет _join_pockets — как и любой другой закуток.
	var walk := _walk_mask()
	for i in w * h:
		if m.feature_id[i] != MCF.FEATURE_AIRLOCK:
			continue
		var c := Vector2i(i % w, i / w)
		var through := false
		for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var a := c + d
			var b := c - d
			if _in(a) and _in(b) and walk[a.y * w + a.x] != 0 and walk[b.y * w + b.x] != 0:
				through = true
		if not through:
			_put(c, MCF.FEATURE_WALL)
	# Пара кратеров внутри — каменный остров, а не ровная площадка.
	for n in 1 + roundi(w * h / 1600.0):
		var c := _random_cell(6)
		var rad := _rng.randf_range(1.4, 2.4)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				var q := c + Vector2i(dx, dy)
				if _in(q) and Vector2(dx, dy).length() <= rad and m.get_feature(q) == "" \
						and not m.get_space(q):
					_put(q, MCF.FEATURE_DIRT_PILE)

func _open_space() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = _rng.randi()
	noise.frequency = 0.13
	for y in h:
		for x in w:
			var edge := mini(mini(x, y), mini(w - 1 - x, h - 1 - y))
			if float(edge) < 1.2 + 2.6 * noise.get_noise_2d(x, y):
				_space(Vector2i(x, y))
	var per := 800.0 if _style == Style.TOWN else 450.0
	for n in 1 + roundi(w * h / per):
		var c := _random_cell(4)
		var rad := _rng.randf_range(1.5, 2.8)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				if Vector2(dx, dy).length() + noise.get_noise_2d(c.x + dx, c.y + dy) <= rad:
					_space(c + Vector2i(dx, dy))

# --- Связность -----------------------------------------------------------------------------
## Всё, по чему можно ходить, — одна часть. Пол, отрезанный от остального (дом, чья
## дверь не нашла места; комната, чья дверь осталась за зеркальной осью; закуток за
## ящиками), соединяется с главной частью самым коротким проломом — через наименьшее число
## стен, скалы или ящиков. Главная часть — та, где стоит `from` (якорь первой зоны), а
## без него — самая большая по полу. Куски из одного космоса не в счёт: открытый вакуум
## за обшивкой и не должен вести внутрь.
##
## Один проход «0-1 BFS» от главной части сразу до всех отрезанных: шаг по проходимому
## стоит 0, по стене — 1. Путь от ближайшей клетки каждого куска назад к главной части и
## есть пролом. При симметрии пробиваются и все его отражения — карта остаётся зеркальной.
func _join_pockets(from: Vector2i) -> void:
	var n := w * h
	var walk := _walk_mask()
	var comp := PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var floor_of := PackedInt32Array()
	var queue := PackedInt32Array()
	queue.resize(n)
	var nb := PackedInt32Array()
	nb.resize(4)
	var count := 0
	for s in n:
		if walk[s] == 0 or comp[s] != -1:
			continue
		comp[s] = count
		queue[0] = s
		var head := 0
		var tail := 1
		var fl := 0
		while head < tail:
			var i := queue[head]
			head += 1
			if m.is_space[i] == 0:
				fl += 1
			var k := _neighbours(i, n, nb)
			for t in k:
				var j := nb[t]
				if walk[j] != 0 and comp[j] == -1:
					comp[j] = count
					queue[tail] = j
					tail += 1
		floor_of.append(fl)
		count += 1
	var main := -1
	if _in(from) and walk[from.y * w + from.x] != 0:
		main = comp[from.y * w + from.x]
	else:
		for c in count:
			if main < 0 or floor_of[c] > floor_of[main]:
				main = c
	var pockets := false
	for c in count:
		if c != main and floor_of[c] > 0:
			pockets = true
			break
	if main < 0 or not pockets:
		return
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(1 << 30)
	var par := PackedInt32Array()
	par.resize(n)
	par.fill(-1)
	var cur := PackedInt32Array()
	for i in n:
		if comp[i] == main:
			dist[i] = 0
			cur.append(i)
	var level := 0
	while not cur.is_empty():
		# Всё, что достижимо без новых проломов, — тот же уровень.
		var q := 0
		while q < cur.size():
			var i := cur[q]
			q += 1
			var k := _neighbours(i, n, nb)
			for t in k:
				var j := nb[t]
				if walk[j] != 0 and dist[j] > level:
					dist[j] = level
					par[j] = i
					cur.append(j)
		var nxt := PackedInt32Array()
		for i in cur:
			var k := _neighbours(i, n, nb)
			for t in k:
				var j := nb[t]
				if walk[j] == 0 and dist[j] > level + 1:
					dist[j] = level + 1
					par[j] = i
					nxt.append(j)
		cur = nxt
		level += 1
	# Ближайшая к главной части клетка каждого отрезанного куска — и путь от неё назад.
	var entry := {}
	for i in n:
		var c := comp[i]
		if c < 0 or c == main or floor_of[c] == 0:
			continue
		if not entry.has(c) or dist[i] < dist[entry[c]]:
			entry[c] = i
	var carved: Array[Vector2i] = []
	for c: int in entry:
		var j: int = entry[c]
		while j >= 0 and dist[j] > 0:
			if walk[j] == 0:
				for g in _group():
					var cell := _img(Vector2i(j % w, j / w), g)
					_ground(cell)
					carved.append(cell)
			j = par[j]
	# Пролом ведёт в комнату — значит, это новая дверь, а двери здесь шлюзы: иначе комнату
	# с проломом уже не назвать запертой. Шлюз встаёт на каждый конец пролома, похожий на
	# дверной проём (стены по бокам, проход насквозь); середина длинного тоннеля в скале —
	# просто ход.
	var open := _walk_mask()
	var cut := {}
	for cell in carved:
		cut[cell] = true
	for cell in carved:
		var ends := 0
		for d: Vector2i in N4:
			if not cut.has(cell + d):
				ends += 1
		if ends >= 3 and _door_shaped(cell, open):
			_put(cell, MCF.FEATURE_AIRLOCK)
			_mark_door(cell)

## Соседи клетки i по четырём сторонам — в nb; возвращает, сколько их.
func _neighbours(i: int, n: int, nb: PackedInt32Array) -> int:
	var k := 0
	var x := i % w
	if x > 0:
		nb[k] = i - 1
		k += 1
	if x < w - 1:
		nb[k] = i + 1
		k += 1
	if i >= w:
		nb[k] = i - w
		k += 1
	if i + w < n:
		nb[k] = i + w
		k += 1
	return k

# --- Зоны развёртывания ------------------------------------------------------------------
## По зоне на слот. Якоря разнесены жадно — каждый следующий как можно дальше от уже
## выбранных, — а зоны растут от якорей по очереди, по клетке за ход. Из нескольких
## попыток берётся та, где самая маленькая зона больше всех, и все зоны срезаются до
## её размера: зона, запертая в тесной комнате, не должна оставлять соседей богаче.
##
## При симметрии растут представители (_rep_ids): клетка, взятая в исходной части,
## берётся сразу со всеми отражениями, каждое — в свою зону.
func _zones(n: int) -> void:
	_zone_n = n
	_setup_reps(n)
	var clear := 0
	var mask := _clear_mask()
	for i in w * h:
		clear += mask[i]
	var target := clampi(int(clear * ZONE_SHARE / n), _need, _need * 4)
	var cand := _anchor_candidates(n)
	if cand.is_empty():
		return
	var best := -1
	var best_claimed: Array = []
	var best_an: Array[Vector2i] = []
	for gap in ([ZONE_GAP, 2, 1] if _tight else [ZONE_GAP]):
		_gap = gap
		var pools := _anchor_pools(cand)
		for attempt in 6:
			var an := _pick_anchors(pools)
			if an.is_empty():
				break
			var smallest := _grow(an, target)
			if smallest > best:
				best = smallest
				best_claimed = _claimed
				best_an = an
			if best >= target:
				break
		if best >= _need:
			break
	if best < 0:
		return
	# Срезаем с конца роста — с дальнего от якоря края: зона остаётся связной и круглой.
	_zone_min = _paint_zones(best_claimed, best)
	_anchors.clear()
	for z in n:
		_anchors.append(Vector2i(-1, -1))
	for r in best_an.size():
		var ids: PackedInt32Array = _rep_ids[r]
		for g in ids.size():
			if _anchors[ids[g]] == Vector2i(-1, -1):
				_anchors[ids[g]] = _img(best_an[r], g)
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

## Представители: без симметрии — по одному на зону; с зеркалом — пара «зона и её
## отражение» (а при нечётном числе ещё одна зона на оси, сама себе отражение); с
## четвертями — четвёрка.
func _setup_reps(n: int) -> void:
	_rep_ids.clear()
	_rep_fold.clear()
	var g := _group()
	for r in n / g:
		var ids := PackedInt32Array()
		for k in g:
			ids.append(r * g + k)
		_rep_ids.append(ids)
		_rep_fold.append(false)
	if n % g != 0:
		_rep_ids.append(PackedInt32Array([n - 1, n - 1]))
		_rep_fold.append(true)

## Где удобно ставить якорь: чистая клетка, вокруг которой (5×5) почти всё чисто.
## Если таких мало — любая чистая. Окно считается по суммам прямоугольников — четыре
## обращения на клетку вместо двадцати пяти.
func _anchor_candidates(n: int) -> Array[Vector2i]:
	var clear := _clear_mask()
	var sw := w + 1
	var sat := PackedInt32Array()
	sat.resize(sw * (h + 1))
	for y in h:
		var row := 0
		for x in w:
			row += clear[y * w + x]
			sat[(y + 1) * sw + x + 1] = sat[y * sw + x + 1] + row
	var open: Array[Vector2i] = []
	var any: Array[Vector2i] = []
	for y in h:
		var y0 := maxi(0, y - 2)
		var y1 := mini(h, y + 3)
		for x in w:
			var i := y * w + x
			if clear[i] == 0 or _door[i] != 0:
				continue
			any.append(Vector2i(x, y))
			var x0 := maxi(0, x - 2)
			var x1 := mini(w, x + 3)
			if sat[y1 * sw + x1] - sat[y0 * sw + x1] - sat[y1 * sw + x0] + sat[y0 * sw + x0] >= 20:
				open.append(Vector2i(x, y))
	var out := open if open.size() >= n * 4 else any
	if out.size() <= CAND_MAX:
		return out
	var step := ceili(float(out.size()) / CAND_MAX)
	var thin: Array[Vector2i] = []
	for i in range(0, out.size(), step):
		thin.append(out[i])
	return thin

## Кандидаты по видам представителей: [обычные, на оси]. При симметрии обычный якорь
## берётся в исходной части и подальше от своих отражений — иначе зоне некуда расти, не
## подходя к собственному зеркалу; якорь зоны на оси — в клетке у самой оси.
func _anchor_pools(cand: Array[Vector2i]) -> Array:
	var fold: Array[Vector2i] = []
	if _sym == 0:
		return [cand, fold]
	var generic: Array[Vector2i] = []
	var loose: Array[Vector2i] = []
	var fx := (w - 1) / 2
	for c in cand:
		if not _in_f(c):
			continue
		if _sym == 1 and c.x == fx:
			fold.append(c)
		var sep := 1 << 30
		for g in range(1, _group()):
			var p := _img(c, g)
			sep = mini(sep, maxi(absi(p.x - c.x), absi(p.y - c.y)))
		if sep > 2 * _gap + 2:
			generic.append(c)
		elif sep > _gap:
			loose.append(c)
	return [generic if not generic.is_empty() else loose, fold]

## Якоря представителей: первый — ближе к краю карты (из тех, кто от центра дальше 0.6
## от самого дальнего), каждый следующий — подальше от уже выбранных и всех их отражений.
## Расстояние до ближайшего выбранного копится по мере выбора, а не пересчитывается.
func _pick_anchors(pools: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var mid := Vector2(w - 1, h - 1) * 0.5
	var mind: Array = []
	for p in 2:
		var d := PackedFloat32Array()
		d.resize((pools[p] as Array).size())
		d.fill(INF)
		mind.append(d)
	for r in _rep_ids.size():
		var which := 1 if _rep_fold[r] else 0
		var pool: Array[Vector2i] = pools[which]
		if pool.is_empty():
			return []
		var a: Vector2i
		if out.is_empty():
			var score := PackedFloat32Array()
			score.resize(pool.size())
			for i in pool.size():
				score[i] = ((Vector2(pool[i]) - mid) / Vector2(w, h)).length()
			a = _pick_top(pool, score, 0.6)
		else:
			a = _pick_top(pool, mind[which], 0.9)
		out.append(a)
		for p in 2:
			var ps: Array[Vector2i] = pools[p]
			var d: PackedFloat32Array = mind[p]
			for g in _group():
				var ag := Vector2(_img(a, g))
				for i in ps.size():
					d[i] = minf(d[i], Vector2(ps[i]).distance_to(ag))
			mind[p] = d
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

## Растим зоны от якорей по очереди. Фронт зоны — куча соседей с приоритетом «расстояние
## до якоря плюс дрожание»: зона выходит округлой, но с рваным краем. Проём зона проходит
## насквозь, но не занимает — иначе дверь стала бы клеткой расстановки. Возвращает
## размер самой маленькой зоны; клетки каждого представителя — в _claimed.
func _grow(an: Array[Vector2i], target: int) -> int:
	var reps := an.size()
	_own = PackedInt32Array()
	_own.resize(w * h)
	_own.fill(-1)
	_seen = PackedByteArray()
	_seen.resize(w * h * reps)
	_fronts = []
	_claimed = []
	var sizes := PackedInt32Array()
	sizes.resize(_zone_n)
	for r in reps:
		_fronts.append([])
		_claimed.append([])
		_push(r, an[r], an[r])
	var grew := true
	while grew:
		grew = false
		for r in reps:
			if sizes[(_rep_ids[r] as PackedInt32Array)[0]] >= target:
				continue
			var f: Array = _fronts[r]
			while not f.is_empty():
				var c: Vector2i = _heap_pop(f)[1]
				var idx := c.y * w + c.x
				if _door[idx] != 0:
					for d: Vector2i in N4:
						_push(r, c + d, an[r])
					continue
				if not _claim(r, c, sizes):
					continue
				_claimed[r].append(c)
				for d: Vector2i in N4:
					_push(r, c + d, an[r])
				grew = true
				break
	var smallest := target
	for s in sizes:
		smallest = mini(smallest, s)
	return smallest

## Взять клетку представителю — вместе со всеми её отражениями. Каждое отражение обязано
## быть свободным и не ближе зазора к чужой зоне, включая другие отражения этой же клетки.
func _claim(r: int, c: Vector2i, sizes: PackedInt32Array) -> bool:
	var ids: PackedInt32Array = _rep_ids[r]
	var cells: Array[Vector2i] = []
	var zids: Array[int] = []
	for g in ids.size():
		var p := _img(c, g)
		if cells.has(p):
			continue
		var z := ids[g]
		if _own[p.y * w + p.x] != -1 or _near_other(p, z):
			return false
		for k in cells.size():
			if zids[k] != z and maxi(absi(cells[k].x - p.x), absi(cells[k].y - p.y)) <= _gap:
				return false
		cells.append(p)
		zids.append(z)
	for k in cells.size():
		_own[cells[k].y * w + cells[k].x] = zids[k]
		sizes[zids[k]] += 1
	return true

func _push(r: int, c: Vector2i, anchor: Vector2i) -> void:
	if not _in(c) or not _in_f(c):
		return
	var idx := c.y * w + c.x
	if _seen[r * w * h + idx] != 0:
		return
	_seen[r * w * h + idx] = 1
	if _door[idx] == 0 and not _clear(c):
		return
	_heap_push(_fronts[r], [Vector2(c).distance_to(Vector2(anchor)) + _rng.randf() * 1.6, c])

func _near_other(c: Vector2i, i: int) -> bool:
	for dy in range(-_gap, _gap + 1):
		for dx in range(-_gap, _gap + 1):
			var p := c + Vector2i(dx, dy)
			if _in(p):
				var z := _own[p.y * w + p.x]
				if z != -1 and z != i:
					return true
	return false

## Двоичная куча по приоритету [0] — фронт зоны. Раньше фронт перебирался целиком на
## каждой клетке, и на большом отряде рост зон стоил секунды.
func _heap_push(f: Array, item: Array) -> void:
	f.append(item)
	var i := f.size() - 1
	while i > 0:
		var p := (i - 1) / 2
		if f[p][0] <= item[0]:
			break
		f[i] = f[p]
		i = p
	f[i] = item

func _heap_pop(f: Array) -> Array:
	var top: Array = f[0]
	var last: Array = f.pop_back()
	if f.is_empty():
		return top
	var size := f.size()
	var i := 0
	while true:
		var l := i * 2 + 1
		if l >= size:
			break
		var s := l + 1 if l + 1 < size and f[l + 1][0] < f[l][0] else l
		if f[s][0] >= last[0]:
			break
		f[i] = f[s]
		i = s
	f[i] = last
	return top

## Зоны на карту — первые клетки роста каждого представителя, поровну. Зона на оси
## растёт по две клетки (клетка и отражение), поэтому её размер подбирается первым, и под
## него срезаются остальные. Возвращает размер каждой зоны.
func _paint_zones(claimed: Array, best: int) -> int:
	var size := maxi(0, best)
	for r in _rep_ids.size():
		if _rep_fold[r]:
			size = mini(size, _fold_prefix(claimed[r], size, -1))
	for r in _rep_ids.size():
		var ids: PackedInt32Array = _rep_ids[r]
		if _rep_fold[r]:
			_fold_prefix(claimed[r], size, ids[0])
			continue
		var cells: Array = claimed[r]
		for k in mini(size, cells.size()):
			for g in ids.size():
				var p := _img(cells[k], g)
				_zone[p.y * w + p.x] = ids[g]
	return size

## Сколько клеток даёт зона на оси, если брать её рост по порядку, не превышая `limit`.
## zone >= 0 — заодно разметить эту зону.
func _fold_prefix(cells: Array, limit: int, zone: int) -> int:
	var size := 0
	for c: Vector2i in cells:
		var p := _img(c, 1)
		var inc := 1 if p == c else 2
		if size + inc > limit:
			break
		size += inc
		if zone >= 0:
			_zone[c.y * w + c.x] = zone
			_zone[p.y * w + p.x] = zone
	return size

# --- Мирные ------------------------------------------------------------------------------
## Мирные — кучками по 1–3, в основном «под крышей», и не ближе трёх клеток к чьей-то
## зоне: иначе расстановка упиралась бы в чужого жителя. И они должны начать партию
## СПЯЩИМИ: житель просыпается, как только видит солдата по прямой или рядом с ним
## открывается шлюз (GameActionResolver._update_breached / update_airlocks). Поэтому —
## только туда, куда не смотрит ни одна клетка зон, и не вплотную к шлюзу. Не больше
## CIV_MAX на карту; при симметрии — в исходной части, остальные — её отражения.
func _civilians() -> void:
	var lv := civ_level(opt)
	var want := mini(CIV_CAP[lv], maxi(CIV_MIN[lv], roundi(w * h / 160.0 * dens * CIV_MULT[lv])))
	# Точное число с ползунка лобби (item 11) важнее уровня.
	if int(opt.get("civilian_count", -1)) >= 0:
		want = mini(int(opt["civilian_count"]), CIV_MAX)
	if _sym > 0:
		want = maxi(1, want / _group())
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
	var ok := _clear_mask()
	for i in w * h:
		if m.feature_id[i] == MCF.FEATURE_AIRLOCK:   # не вплотную к шлюзу
			var ax := i % w
			var ay := i / w
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if _in(Vector2i(ax + dx, ay + dy)) and (dx != 0 or dy != 0):
						ok[(ay + dy) * w + ax + dx] = 0
	for s in m.spawns:
		var c: Vector2i = s["coord"]
		ok[c.y * w + c.x] = 0
	# Только за шлюзами: помещение, от которого до любой зоны не дойти, не открыв шлюз.
	var sealed := _sealed_rooms()
	var inside: Array[Vector2i] = []
	var outside: Array[Vector2i] = []
	for y in h:
		for x in w:
			var i := y * w + x
			if near[i] != 0 or _door[i] != 0 or seen[i] != 0 or sealed[i] == 0:
				ok[i] = 0
			elif ok[i] != 0 and _in_f(Vector2i(x, y)):
				inside.append(Vector2i(x, y))
			else:
				ok[i] = 0
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
			var p := c + d
			if _in(p) and ok[p.y * w + p.x] != 0:
				m.set_spawn(p, "civilian", MCF.Owner.NEUTRAL)
				ok[p.y * w + p.x] = 0
				placed += 1
				group -= 1

## Клетки запертых помещений: под крышей и в такой части карты, что при ЗАКРЫТЫХ шлюзах
## от неё не дойти ни до одной клетки зон. Живущий здесь мирный отрезан шлюзами и до
## первого открытого шлюза никого не встретит.
func _sealed_rooms() -> PackedByteArray:
	var walk := _walk_mask()
	for i in w * h:
		if m.feature_id[i] == MCF.FEATURE_AIRLOCK:
			walk[i] = 0
	var comp := _components(walk)
	var exposed := {}
	for i in w * h:
		if _zone[i] >= 0 and comp[i] >= 0:
			exposed[comp[i]] = true
	var out := _bytes()
	for i in w * h:
		if _indoor[i] != 0 and comp[i] >= 0 and not exposed.has(comp[i]):
			out[i] = 1
	return out

## Связные куски проходимого (по четырём сторонам): номер куска на клетку, -1 — не ходят.
func _components(walk: PackedByteArray) -> PackedInt32Array:
	var n := w * h
	var comp := PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(n)
	var nb := PackedInt32Array()
	nb.resize(4)
	var count := 0
	for s in n:
		if walk[s] == 0 or comp[s] != -1:
			continue
		comp[s] = count
		queue[0] = s
		var head := 0
		var tail := 1
		while head < tail:
			var i := queue[head]
			head += 1
			var k := _neighbours(i, n, nb)
			for t in k:
				var j := nb[t]
				if walk[j] != 0 and comp[j] == -1:
					comp[j] = count
					queue[tail] = j
					tail += 1
		count += 1
	return comp

## Клетки, которые видно хоть из одной клетки зоны по прямой — ряд, столбец или ровная
## диагональ, как в _civ_sees_soldier; стекло взгляду не преграда. Шлюз считаем открытым:
## боец, вставший у двери, распахнёт его ещё до первого хода.
##
## Не луч из каждой клетки зоны (на большом отряде — миллионы шагов), а проход по полю
## в каждом из восьми направлений: клетку видно по d, если её сосед со стороны -d — клетка
## зоны или сам виден по d и взгляд не держит.
func _seen_from_zones() -> PackedByteArray:
	var seen := _bytes()
	var block := _bytes()
	for i in w * h:
		var f: String = m.feature_id[i]
		if m.cover_height[i] >= MCF.WALL_HEIGHT and not MCF.is_glass(f) and f != MCF.FEATURE_AIRLOCK:
			block[i] = 1
	for d: Vector2i in DIRS8:
		var ray := _bytes()
		var xs: Array = range(w) if d.x >= 0 else range(w - 1, -1, -1)
		var ys: Array = range(h) if d.y >= 0 else range(h - 1, -1, -1)
		for y: int in ys:
			var py := y - d.y
			if py < 0 or py >= h:
				continue
			for x: int in xs:
				var px := x - d.x
				if px < 0 or px >= w:
					continue
				var p := py * w + px
				if _zone[p] >= 0 or (ray[p] != 0 and block[p] == 0):
					ray[y * w + x] = 1
					seen[y * w + x] = 1
	return seen
