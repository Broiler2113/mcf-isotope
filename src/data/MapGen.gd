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
## Кайма вокруг карты (0.9.3, по просьбе игрока). Поле шире заказанного на BORDER клеток в
## каждую сторону: у бункера это грунт, который копают, у города и поля — трава, у станции
## и астероида — космос. За ней ещё BORDER_RIM клеток того же вида, но уже НЕПРОХОДИМЫХ и
## неразрушимых (MCF.FEATURE_BOUNDARY): мир не обрывается по краю доски, а дальше десяти
## клеток от карты ни боец, ни машина не уйдут.
##
## Кайма одинакова у ВСЕХ стилей и не зависит от настроек: от неё зависит размер поля, а
## бункер и станция одного зерна обязаны совпадать клетка в клетку (run_mapgen).
const BORDER := 10
const BORDER_RIM := 2
const BORDER_ALL := BORDER + BORDER_RIM
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
## Технический туннель (0.9.2): узкий проход между отделами — глубокие линии раздела.
const K_MAINT := 5
## Свой коридор отдела: за приёмной, на него выходят комнаты отдела.
const K_DHALL := 6

## Отделы станции и бункера (0.9.2, по замыслу игрока). front — помещение у главного
## коридора (приёмная, у мостика — командный пункт, у жилого — кают-компания); rooms — по
## важности (на малой карте лишние отпадают); hall — вид пола своего коридора; extra —
## чем заполнять лишние комнаты.
## Раздевалка (0.9.4) есть у КАЖДОГО отдела — игрок просил «each department needs its own
## small changing rooms», — и стоит в списке сразу после самого нужного: на тесной карте
## отпадают комнаты с конца списка, и раздевалка не должна улетать первой.
const DEPARTMENTS := {
	"bridge": {"front": "command", "rooms": ["captain", "hidden_storage", "changing", "server_room", "office"],
		"hall": MCF.Look.CARPET_BLUE, "extra": ["office", "server_room"]},
	"service": {"front": "lounge", "rooms": ["kitchen", "mess", "restroom", "quarters", "changing", "quarters",
		"laundry", "quarters", "quarters"], "hall": MCF.Look.TILE, "extra": ["quarters", "storage"]},
	"engineering": {"front": "reception", "rooms": ["power", "water", "air", "changing", "dock", "supply"],
		"hall": MCF.Look.PLATE, "extra": ["utility", "storage"]},
	# Морг и вирусология (0.9.4) — в медотсеке; оба вперёд склада, но после палаты с операционной.
	"medical": {"front": "reception", "rooms": ["ward", "surgery", "morgue", "virology", "changing", "supply",
		"restroom"], "hall": MCF.Look.LINO, "extra": ["office", "ward"]},
	# Карцер (0.9.4) — отдельная камера-одиночка сверх общих камер.
	"security": {"front": "reception", "rooms": ["briefing", "armory", "changing", "cell", "cell", "solitary",
		"cell"], "hall": 0, "extra": ["office", "cell"]},
	"supply": {"front": "reception", "rooms": ["warehouse", "dock", "changing", "storage"], "hall": MCF.Look.PLATE,
		"extra": ["storage", "office"]},
	"production": {"front": "reception", "rooms": ["machine_shop", "assembly", "changing", "warehouse", "dock",
		"machine_shop"], "hall": MCF.Look.PLATE, "extra": ["storage", "workshop"]},
	# Полигон у лабораторий стоит ОТДЕЛЬНО от станции (0.9.4, _annex): в списке комнат его
	# больше нет — он пристраивается снаружи и соединяется коротким коридором.
	"research": {"front": "reception", "rooms": ["laboratory", "changing", "assembly", "supply"],
		"hall": MCF.Look.LINO, "extra": ["laboratory", "office"]},
	"misc": {"front": "lounge", "rooms": ["storage", "quarters", "changing", "office", "server_room"], "hall": 0,
		"extra": ["storage", "quarters"]},
}
## Порядок важности: на карте с N отсеками строятся первые N (мостик, жилой, инженерный…).
const DEPT_ORDER := ["bridge", "service", "engineering", "medical", "security", "supply", "production",
		"research"]
## Сверх списка — повторы того, без чего большой станции не обойтись.
## Без второго жилого и второго производства: «производство дальше всех от жилого» должно
## читаться однозначно; жилые каюты больших станций — в «прочих» отсеках (misc).
const DEPT_EXTRA := ["misc", "supply", "research", "misc", "medical", "engineering", "security"]
## Акцент отдела (0.9.3): цвет, которым размечены его стены и двери. Жилой блок,
## производство и «прочее» игрок цветом не называл — они остаются серыми.
const DEPT_ACCENT := {
	"bridge": MCF.Accent.COMMAND,
	"security": MCF.Accent.SECURITY,
	"medical": MCF.Accent.MEDICAL,
	"research": MCF.Accent.SCIENCE,
	"engineering": MCF.Accent.ENGINEERING,
	"supply": MCF.Accent.CARGO,
}
## Акцент по НАЗНАЧЕНИЮ комнаты. Он ГЛАВНЕЕ отдела: игрок просил красить «всё, что
## относится к…», а не отделы целиком, — поэтому серверная и на мостике белая, а склад
## остаётся оранжевым, в чьём бы отсеке ни стоял. Цвет отдела достаётся всему прочему:
## его коридору, приёмной, кабинетам.
const KIND_ACCENT := {
	"command": MCF.Accent.COMMAND, "captain": MCF.Accent.COMMAND,
	"server_room": MCF.Accent.CONTROL, "comms": MCF.Accent.CONTROL,
	"armory": MCF.Accent.SECURITY, "cell": MCF.Accent.SECURITY, "briefing": MCF.Accent.SECURITY,
	"ward": MCF.Accent.MEDICAL, "surgery": MCF.Accent.MEDICAL,
	"morgue": MCF.Accent.MEDICAL, "virology": MCF.Accent.MEDICAL,
	"solitary": MCF.Accent.SECURITY,
	"laboratory": MCF.Accent.SCIENCE, "testing_range": MCF.Accent.SCIENCE,
	"power": MCF.Accent.ENGINEERING, "water": MCF.Accent.ENGINEERING, "air": MCF.Accent.ENGINEERING,
	"utility": MCF.Accent.ENGINEERING, "recycling": MCF.Accent.ENGINEERING,
	"machine_shop": MCF.Accent.ENGINEERING, "workshop": MCF.Accent.ENGINEERING,
	"warehouse": MCF.Accent.CARGO, "dock": MCF.Accent.CARGO, "storage": MCF.Accent.CARGO,
	"supply": MCF.Accent.CARGO,
}
## Комнаты, которым нужен выход прямо в космос: причал и испытательный полигон.
const HULL_KINDS := {"dock": true, "testing_range": true}
## Комнаты, которые нельзя отдать под технические (их отдел без них — не отдел).
const KEY_KINDS := {"reception": true, "command": true, "lounge": true, "captain": true, "hidden_storage": true,
		"dock": true, "testing_range": true, "ward": true, "briefing": true, "kitchen": true,
		# Раздевалка, морг, вирусология и камеры — тоже лицо отдела: под техничку их не отдают.
		"changing": true, "morgue": true, "virology": true, "cell": true, "solitary": true}

## Комнаты, в стенах которых НЕ РЕЖУТСЯ ни окна, ни внешние шлюзы (0.9.4). Санузел с
## видом в космос — ровно то, на что жаловался игрок («windows shouldn\'t generate in
## bathrooms»); карцер и раздевалка по той же причине глухие, а тайник был таким и раньше.
const NO_WINDOW_KINDS := {"hidden_storage": true, "restroom": true, "bathroom": true,
		"changing": true, "cell": true, "solitary": true, "morgue": true}

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
## Игровая карта внутри поля: всё, что снаружи, — кайма (BORDER_ALL). Зоны, украшения,
## мирные и сама застройка живут только здесь.
var _core := Rect2i()
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
## Назначение каждой комнаты (0.9.2): прямоугольник из _rooms → вид помещения (у станции —
## комната отдела, у города — здание, у поля — хижина/руина). По нему мебель и вид пола.
var _room_kind: Dictionary = {}
## Вид пола коридоров станции: отдела — свой, техтуннели — решётка (и то не всякий).
var _hall_look: PackedByteArray
## Акцент службы по клеткам (0.9.3); читается только на стенах и дверях.
var _accent: PackedByteArray
## Клетки космоса, где лежат решётчатые мостки от станции к панелям (MCF.Look.GRILL).
var _grill: Array[Vector2i] = []
## Клетки стены, где прорубить шлюз наружу: причалы, полигон, выходы техтуннелей к панелям.
var _space_doors: Array[Vector2i] = []
## Клетки космоса, где висят солнечные панели (вид, MCF.Look.SOLAR).
var _solar: Array[Vector2i] = []
## Отделы станции: [отсек, отдел] — для проверок (run_batch092).
var _dept_sectors: Array = []
## Проёмы, которым шлюз ставится НАСИЛЬНО (0.9.4): устья техтуннелей бывают в две клетки
## шириной, и обычная проверка «стены по бокам» (_is_doorway) их не признаёт.
var _forced_doors: Dictionary = {}
## Пристройки снаружи станции (0.9.4): их комнаты не отдаются под технические.
var _annex_rects: Dictionary = {}

## Чем бывают пристройки-протуберанцы (0.9.4). Всё это модули, которым снаружи самое
## место: причал, воздух, вода, реактор, узел связи, склад.
const PROTRUSION_KINDS := ["dock", "air", "water", "power", "server_room", "storage"]
## Чем бывают чуланы, висящие на техтуннеле (0.9.4), и насколько тесной должна быть
## комната, чтобы её отдали под такой чулан (клеток пола).
const MAINT_KINDS := ["utility", "water", "air", "power", "storage", "utility"]
const MAINT_ROOM_MAX := 24
## Обвод станции (0.9.4): суперэллипс по игровой карте. Показатель 3 даёт «прямоугольник
## со скруглёнными углами» — ровно то, что просил игрок, а не круг.
const HULL_POWER := 3.0
const HULL_MARGIN := 1.06

static func default_options() -> Dictionary:
	return {"style": Style.TOWN, "size": 1, "density": 1, "seed": 1, "zones": 2, "units": 10,
			"width": 80, "height": 60, "symmetric": false,
			"space": true, "flammable": true, "obstacles": true, "civilians": 0,
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

## Размер ИГРОВОЙ карты готового поля: поле шире её на кайму с каждой стороны (BORDER_ALL).
## Лобби называет игроку именно его — «Colossal 250×250» — а не ширину доски.
static func map_size(m: MapData) -> Vector2i:
	return Vector2i(maxi(1, m.width - BORDER_ALL * 2), maxi(1, m.height - BORDER_ALL * 2))

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
	return build(options).m

## То же, но весь генератор целиком — с разметкой отделов и назначениями (для проверок).
static func build(options: Dictionary) -> MapGen:
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
	return g

func _build(options: Dictionary, dim: Vector2i, need: int, tight: bool) -> void:
	opt = options
	_need = need
	_tight = tight
	# Заказан размер ИГРОВОЙ карты; поле вокруг неё шире на кайму с каждой стороны.
	_core = Rect2i(BORDER_ALL, BORDER_ALL, dim.x, dim.y)
	w = dim.x + BORDER_ALL * 2
	h = dim.y + BORDER_ALL * 2
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
	_border_rim()
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
## Кайма (0.9.3) чистой не считается НИГДЕ: ни зона, ни житель, ни ящик за карту не выходят —
## туда можно только зайти ногами. Поэтому проверка на _core стоит здесь, в одном месте, а
## не у каждого, кто спрашивает про свободную клетку.
func _clear(c: Vector2i) -> bool:
	return _core.has_point(c) and not m.get_space(c) and m.get_feature(c) == "" \
			and m.get_cover(c) <= 0.0

## То же, что _clear, для всего поля разом.
func _clear_mask() -> PackedByteArray:
	var out := _bytes()
	for y in range(_core.position.y, _core.end.y):
		for x in range(_core.position.x, _core.end.x):
			var i := y * w + x
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

## Случайная клетка ИГРОВОЙ карты (кайма не в счёт): margin — отступ от её края.
func _random_cell(margin: int = 1) -> Vector2i:
	return Vector2i(_rng.randi_range(_core.position.x + margin, _core.end.x - 1 - margin),
			_rng.randi_range(_core.position.y + margin, _core.end.y - 1 - margin))

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
	var has_look := m.floor_look.size() == w * h
	for y in h:
		for x in w:
			var i := y * w + x
			var s := _src_index(x, y)
			if s == i:
				continue
			if has_look:
				m.floor_look[i] = m.floor_look[s]
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
					if _room_kind.has(r) and not _room_kind.has(q):
						_room_kind[q] = _room_kind[r]   # отражение комнаты — того же назначения
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
## (BSP), а каждая линия раздела — проход: верхние — широкие главные коридоры, глубже —
## узкие технические туннели, что вьются между отделами (0.9.2). Раз каждый проход тянется
## через весь свой кусок, сеть связна сама собой. Каждый отсек — ОТДЕЛ станции (мостик,
## жилой, инженерный, медотсек, охрана, снабжение, производство, лаборатории; на малой
## карте — только первые): приёмная выходит на главный коридор, за ней свой коридор отдела,
## на него — комнаты; во внутренние комнаты с главного коридора не попасть, только через
## приёмную или с техтуннеля. Часть отсеков пустует — у краёв чаще: там космос (или скала
## бункера), и коридор идёт мимо, как труба с окнами.
##
## Бункер — та же станция из тех же чисел, только вместо космоса скала (см. _void).
func _station() -> void:
	_k = _bytes()
	_hall_look = _bytes()
	_accent = _bytes()
	var di := clampi(int(opt["density"]), 0, 2)
	var sector_min: int = [15, 12, 10][di]
	# Хотя бы один коридор на любом поле: отсек не больше, чем влезает два поперёк самой
	# длинной стороны (иначе маленькая станция была бы одним отсеком без коридоров).
	sector_min = mini(sector_min, (maxi(_core.size.x, _core.size.y) - 5) / 2)
	_room_min = [7, 6, 5][di]
	var sectors: Array[Rect2i] = []
	_split_sectors(_core.grow(-1), sector_min, 0, sectors)
	# Пустые отсеки — у краёв чаще, но не больше пятой части: на карте из шести отсеков,
	# где все у края, прежний бросок «каждому по 20%» оставлял от станции скелет коридоров.
	#
	# И не больше EMPTY_SECTORS_MAX штук на карту (item 3): доля от числа отсеков хороша на
	# маленькой станции, а на большой отсеков под сотню — и дырок выходило два десятка
	# («on larger maps there's just too many of them»). Станция от размера дырявее не станет.
	var empty_left := mini(EMPTY_SECTORS_MAX, sectors.size() / 5)
	# Скруглённый силуэт (0.9.4): отсек, вылезающий за обвод станции, отдаётся пустоте —
	# углы срезаются, и прямоугольник во всю карту превращается в сглаженную по углам
	# фигуру. Отсеков должно быть на это достаточно: на карте из трёх-четырёх срезать углы
	# нечем, да и незаметно.
	var round_off := sectors.size() >= 6
	var round_left := sectors.size() / 3
	var kept: Array[Rect2i] = []
	for s in sectors:
		var edge := s.position.x <= _core.position.x + 1 or s.position.y <= _core.position.y + 1 \
				or s.end.x >= _core.end.x - 1 or s.end.y >= _core.end.y - 1
		var empty_roll := _rng.randf()
		if round_off and round_left > 0 and _outside_hull(s):
			round_left -= 1
			continue
		if empty_left > 0 and empty_roll < (0.25 if edge else 0.08):
			empty_left -= 1
			continue
		kept.append(s)
	_prune_orphan_halls(kept)
	var depts := _assign_departments(kept)
	for k in kept.size():
		_department(kept[k], depts[k])
		_dept_sectors.append([kept[k], depts[k]])
	# Полигон (0.9.4) — ОТДЕЛЬНО от станции, коротким коридором: «the research department\'s
	# testing range should be separate from the rest of the station but connected by a small
	# corridor». Заодно пристройки-протуберанцы: станция обрастает модулями снаружи, а не
	# стоит глухим кирпичом.
	if depts.has("research"):
		_annex("testing_range", _rng.randi_range(5, 7), _rng.randi_range(7, 10))
	for n in 1 + int(_core.size.x * _core.size.y / 2600):
		_annex(PROTRUSION_KINDS[_rng.randi_range(0, PROTRUSION_KINDS.size() - 1)],
				_rng.randi_range(4, 6), _rng.randi_range(4, 6))
	_maintenance_rooms()
	_accent_rooms()
	if _sym > 0:
		for y in h:
			for x in w:
				_k[y * w + x] = _k[_src_index(x, y)]
				_hall_look[y * w + x] = _hall_look[_src_index(x, y)]
				_accent[y * w + x] = _accent[_src_index(x, y)]
		_rooms = _mirror_rects(_rooms)
	# Обшивка: всякая пустота, касающаяся пола хотя бы углом, становится стеной.
	for y in h:
		for x in w:
			if _k[y * w + x] == K_VOID and _touches_floor(x, y):
				_k[y * w + x] = K_WALL
	_maintenance_exits()
	_maintenance_mouths()
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			match _k[y * w + x]:
				K_ROOM:
					_ground(c)
					_indoor[y * w + x] = 1
				K_HALL, K_DOOR, K_MAINT, K_DHALL:
					_ground(c)
					if _hall_look[y * w + x] != 0:
						m.set_look(y * w + x, _hall_look[y * w + x])
					# Проём — тоже стена отдела: шлюз встанет сюда в _seal_doors, и рама
					# у него будет цвета службы (TerrainTiles), как и полоса на стенах.
					if _k[y * w + x] == K_DOOR:
						m.set_accent(y * w + x, _accent[y * w + x])
				K_WALL:
					_put(c, MCF.FEATURE_WALL)
					m.set_accent(y * w + x, _accent[y * w + x])
				_:
					_void(c)
	for y in h:
		for x in w:
			var dc := Vector2i(x, y)
			if _k[y * w + x] == K_DOOR and (_is_doorway(x, y) or _forced_doors.has(dc)):
				_mark_door(dc)
	# Выходы наружу: причалы и полигон — широким шлюзом, техтуннели — шлюзом к панелям.
	# Только в открытый космос: в бункере и без космоса за стеной скала, и причал остаётся
	# запертым грузовым отсеком (шлюз в камень был бы дверью в никуда).
	for c in _space_doors:
		if not _in(c) or m.get_feature(c) != MCF.FEATURE_WALL:
			continue
		var outside := false
		var inside := false
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q := c + d
			if _in(q) and m.get_space(q):
				outside = true
				var back := c - d
				inside = _in(back) and not m.get_space(back) and m.get_cover(back) < MCF.WALL_HEIGHT
		if outside and inside:
			_put(c, MCF.FEATURE_AIRLOCK)
	# Страховка: причал или полигон, которому шлюз не достался (стена вышла не на ту сторону),
	# получает его там, где за стеной правда космос.
	for r: Rect2i in _room_kind:
		if not HULL_KINDS.has(_room_kind[r]) or not bool(opt["space"]) or _style != Style.STATION:
			continue
		var cand: Array[Vector2i] = []
		var has := false
		for c in _edge_cells(r):
			if _is_corner(r, c) or not _in(c):
				continue
			var d := _outward(r, c)
			var out_ok := _in(c + d) and m.get_space(c + d)
			if out_ok and m.get_feature(c) == MCF.FEATURE_AIRLOCK:
				has = true
			elif out_ok and m.get_feature(c) == MCF.FEATURE_WALL and _in(c - d) and not m.get_space(c - d) \
					and m.get_cover(c - d) < MCF.WALL_HEIGHT:
				cand.append(c)
		if not has and not cand.is_empty():
			cand.sort()
			_put(cand[cand.size() / 2], MCF.FEATURE_AIRLOCK)
	if bool(opt["space"]) and _style == Style.STATION:
		# Мостки от шлюза к панелям и сами панели: и то и другое — вид на клетке КОСМОСА.
		for c in _grill:
			if _in(c) and m.get_space(c):
				m.set_look(c.y * w + c.x, MCF.Look.GRILL)
		for c in _solar:
			if _in(c) and m.get_space(c):
				m.set_look(c.y * w + c.x, MCF.Look.SOLAR)

## Отделы по отсекам (0.9.2). Мостик — ближе всех к середине станции; жилой — рядом с
## мостиком; производство — как можно дальше от жилого (требование игрока); отделам с
## причалом и полигону — отсеки у края (оттуда шлюз ведёт прямо в космос). Отсеков меньше,
## чем отделов, — строятся первые по важности; больше — сверх списка (DEPT_EXTRA).
## На зеркальной карте делятся только отсеки исходной половины: остальные — их отражения.
func _assign_departments(kept: Array[Rect2i]) -> Array[String]:
	var out: Array[String] = []
	out.resize(kept.size())
	out.fill("misc")
	var free: Array[int] = []
	for k in kept.size():
		if _in_f(kept[k].get_center()):
			free.append(k)
	var wanted: Array[String] = []
	for k in free.size():
		wanted.append(DEPT_ORDER[k] if k < DEPT_ORDER.size() else DEPT_EXTRA[(k - DEPT_ORDER.size()) % DEPT_EXTRA.size()])
	var mid := Vector2((w - 1) * 0.5, (h - 1) * 0.5)
	if _sym >= 1:
		mid.x = (w - 1) * 0.25
	if _sym >= 2:
		mid.y = (h - 1) * 0.25
	var take := func(k: int, d: String) -> void:
		out[k] = d
		free.erase(k)
	var dist := func(a: int, b: Vector2) -> float:
		return Vector2(kept[a].get_center()).distance_to(b)
	# Мостик, жилой и сразу производство: «дальше всех от жилого» — это пока все отсеки
	# свободны, а не тот, что останется после прочих отделов.
	var order: Array[String] = []
	for d: String in ["bridge", "service", "production"]:
		if wanted.has(d):
			order.append(d)
	for d: String in wanted:
		if not order.has(d) or wanted.count(d) > order.count(d):
			order.append(d)
	var service_at := mid
	for d: String in order:
		if free.is_empty():
			break
		var best := free[0]
		match d:
			"bridge":
				for k in free:
					if dist.call(k, mid) < dist.call(best, mid):
						best = k
			"service":
				# Рядом с мостиком: из трёх ближайших к середине — случайный.
				var near := free.duplicate()
				near.sort_custom(func(a: int, b: int) -> bool: return dist.call(a, mid) < dist.call(b, mid))
				best = near[_rng.randi_range(0, mini(2, near.size() - 1))]
				service_at = Vector2(kept[best].get_center())
			"production":
				for k in free:
					if dist.call(k, service_at) > dist.call(best, service_at):
						best = k
			"engineering", "supply", "research":
				var edges: Array[int] = []
				for k in free:
					if _sector_on_hull(kept[k]):
						edges.append(k)
				var pool: Array[int] = edges if not edges.is_empty() else free
				best = pool[_rng.randi_range(0, pool.size() - 1)]
			_:
				best = free[_rng.randi_range(0, free.size() - 1)]
		# ОДИН ОТДЕЛ — ОДИН КУСОК СТАНЦИИ (0.9.4). На большой станции отсеков хватает с
		# избытком, и отдел повторяется (DEPT_EXTRA); прежде второй такой же отсек выпадал
		# где угодно — медотсек оказывался зажат посреди производства, ровно то, на что
		# жаловался игрок. Повтор берёт отсек, БЛИЖАЙШИЙ к уже отданному этому же отделу.
		var twin := -1
		for k in out.size():
			if out[k] == d:
				twin = k
				break
		if twin >= 0:
			var at := Vector2(kept[twin].get_center())
			var near: int = free[0]
			for k in free:
				if dist.call(k, at) < dist.call(near, at):
					near = k
			best = near
		take.call(best, d)
	return out

## Отсек у края станции: за его стеной — пустота (край поля или пустой отсек).
func _sector_on_hull(s: Rect2i) -> bool:
	for c in _edge_cells(s):
		var d := _outward(s, c)
		if _kind(c.x + d.x, c.y + d.y) == K_VOID:
			return true
	return false

## Отдел в отсеке s (0.9.2). Лицевая сторона — та, за которой главный коридор (нет —
## техтуннель, нет и его — к середине карты). В местных осях: u — вдоль лица, v — вглубь
## от него. Ряды: передние комнаты с приёмной посередине (дверь в главный коридор),
## стена, коридор отдела, стена, задние комнаты. Всё внутреннее — только в коридор отдела;
## задние комнаты, упёршиеся в техтуннель, получают и дверь туда.
func _department(s: Rect2i, dept: String) -> void:
	var accent: int = DEPT_ACCENT.get(dept, MCF.Accent.NONE)
	for y in range(s.position.y, s.end.y):
		for x in range(s.position.x, s.end.x):
			_k[y * w + x] = K_WALL if _on_edge(s, Vector2i(x, y)) else K_ROOM
			_accent[y * w + x] = accent
	var spec: Dictionary = DEPARTMENTS.get(dept, DEPARTMENTS["misc"])
	var f := _front_side(s)
	var L := s.size.x - 2 if f % 2 == 0 else s.size.y - 2
	var D := s.size.y - 2 if f % 2 == 0 else s.size.x - 2
	var lc := func(u: int, v: int) -> Vector2i: return _lc(s, f, u, v)
	var rooms: Array = []   # [Rect2i, сторона: 0 — перед, 1 — зад, u0, u1]
	if D < 5 or L < 7:
		# Тесный отсек — одно помещение: лицо отдела, дверь в коридор.
		var r := s
		_rooms.append(r)
		_room_kind[r] = spec["front"]
		_reception_door(s, f, 0, L, lc)
		return
	var fd := clampi(D * 2 / 5, 3, 6)
	var cw := 2 if L >= 24 and D >= 16 else 1
	var back := D - (fd + 2 + cw)
	if back < 3:
		cw = D - fd - 1
		back = 0
	# Стена за передним рядом и коридор отдела (и стена за ним, если есть задний ряд).
	for u in L:
		_kset(lc.call(u, fd), K_WALL)
		for k in cw:
			var c: Vector2i = lc.call(u, fd + 1 + k)
			_kset(c, K_DHALL)
			_hall_look[c.y * w + c.x] = int(spec["hall"])
		if back > 0:
			_kset(lc.call(u, fd + 1 + cw), K_WALL)
	# Передний ряд: приёмная посередине, по бокам — комнаты (узкий бок отходит приёмной).
	var rw := clampi(L / 4, 3, 7)
	var r0 := (L - rw) / 2
	var r1 := r0 + rw
	if r0 - 1 < 3:
		r0 = 0
	if L - r1 - 1 < 3:
		r1 = L
	var front_parts: Array = []
	if r0 > 0:
		_kcol(lc, r0 - 1, 0, fd)
		front_parts.append_array(_cut_strip(lc, 0, r0 - 1, 0, fd, 3, 7))
	if r1 < L:
		_kcol(lc, r1, 0, fd)
		front_parts.append_array(_cut_strip(lc, r1 + 1, L, 0, fd, 3, 7))
	var reception := _local_rect(s, f, r0, r1, 0, fd)
	_rooms.append(reception)
	_room_kind[reception] = spec["front"]
	_reception_door(s, f, r0, r1, lc)
	_kset(lc.call((r0 + r1) / 2, fd), K_DOOR)   # приёмная — в коридор отдела
	for p: Array in front_parts:
		rooms.append([_local_rect(s, f, p[0], p[1], 0, fd), 0, p[0], p[1]])
	if back > 0:
		# Камеры (0.9.4) — ТЕСНЫЕ: у охраны задний ряд режется полосами в три-четыре клетки,
		# «prison cells should be very small and contain a bed». Прочие отделы — как было.
		var cells_small := dept == "security"
		for p: Array in _cut_strip(lc, 0, L, fd + 2 + cw, D, 3, 4 if cells_small else 8):
			rooms.append([_local_rect(s, f, p[0], p[1], fd + 2 + cw, D), 1, p[0], p[1]])
	_assign_rooms(s, f, rooms, spec, lc, fd, cw, back, D)
	# Коридор отдела в торцах — дверь в техтуннель (в главный коридор — только приёмная).
	for u: int in [-1, L]:
		var c: Vector2i = lc.call(u, fd + 1)
		var o: Vector2i = lc.call(u - 1 if u < 0 else u + 1, fd + 1)
		if _kind(o.x, o.y) == K_MAINT and _door_ok(c):
			_kset(c, K_DOOR)

## Комнатам отдела — назначения; двери — в коридор отдела (тайник — только в каюту капитана),
## задним — ещё и в техтуннель за спиной; причал и полигон — шлюзом в космос.
func _assign_rooms(s: Rect2i, f: int, rooms: Array, spec: Dictionary, lc: Callable, fd: int, cw: int,
		back: int, D: int) -> void:
	var kinds: Array = (spec["rooms"] as Array).duplicate()
	var free: Array = rooms.duplicate()
	var plan := {}   # индекс в rooms → вид
	# Причал и полигон — в самую большую комнату у пустоты.
	for kind: String in kinds.duplicate():
		if not HULL_KINDS.has(kind):
			continue
		var best := -1
		for k in free.size():
			var r: Rect2i = free[k][0]
			if _hull_side(r) >= 0 and (best < 0 or r.get_area() > (free[best][0] as Rect2i).get_area()):
				best = k
		if best >= 0:
			plan[rooms.find(free[best])] = kind
			free.remove_at(best)
		# Нет ни одной комнаты у пустоты — значит в этом отсеке причала (или полигона) не
		# будет вовсе: оба живут выходом НАРУЖУ, и вглубь станции их ставить нельзя. Прежде
		# такой причал всё равно получал комнату — обычным перебором ниже — и оказывался
		# запертым посреди коридоров, без шлюза и без смысла.
		kinds.erase(kind)
	# Камеры — в самые маленькие, прочее — по важности в самые большие.
	free.sort_custom(func(a: Array, b: Array) -> bool:
		return (a[0] as Rect2i).get_area() > (b[0] as Rect2i).get_area())
	for kind: String in kinds.duplicate():
		if free.is_empty():
			break
		if kind == "cell":
			plan[rooms.find(free[free.size() - 1])] = kind
			free.remove_at(free.size() - 1)
		elif kind == "hidden_storage":
			continue   # ниже: рядом с каютой
		else:
			plan[rooms.find(free[0])] = kind
			free.remove_at(0)
		kinds.erase(kind)
	# Тайник — соседняя с каютой капитана комната того же ряда.
	if kinds.has("hidden_storage"):
		for k in rooms.size():
			if plan.get(k, "") != "captain":
				continue
			for q in free:
				var qi := rooms.find(q)
				if q[1] == rooms[k][1] and (int(q[2]) == int(rooms[k][3]) + 1 or int(q[3]) + 1 == int(rooms[k][2])):
					plan[qi] = "hidden_storage"
					free.erase(q)
					break
	var extra: Array = spec["extra"]
	var n := 0
	for q in free:
		plan[rooms.find(q)] = extra[n % extra.size()]
		n += 1
	for k in rooms.size():
		var r: Rect2i = rooms[k][0]
		var kind: String = plan.get(k, extra[0])
		_rooms.append(r)
		_room_kind[r] = kind
		var u0: int = rooms[k][2]
		var u1: int = rooms[k][3]
		var mid := (u0 + u1 - 1) / 2
		if kind == "hidden_storage":
			# Дверь — в перегородку с каютой, не в коридор: снаружи тайника не видно.
			var cap := -1
			for j in rooms.size():
				if plan.get(j, "") == "captain":
					cap = j
			if cap >= 0:
				var wall_u := u1 if int(rooms[cap][2]) == u1 + 1 else u0 - 1
				var v0 := 0 if rooms[k][1] == 0 else fd + 2 + cw
				var v1 := fd if rooms[k][1] == 0 else D
				_kset(lc.call(wall_u, (v0 + v1) / 2), K_DOOR)
				continue
		if rooms[k][1] == 0:
			_kset(lc.call(mid, fd), K_DOOR)
		else:
			_kset(lc.call(mid, fd + 1 + cw), K_DOOR)
			# Задняя стена — техтуннель за ней? Дверь и туда.
			var o: Vector2i = lc.call(mid, D + 1)
			var c: Vector2i = lc.call(mid, D)
			if _kind(o.x, o.y) == K_MAINT and _door_ok(c):
				_kset(c, K_DOOR)
		if HULL_KINDS.has(kind):
			_hull_doors(r)

## Сторона прямоугольника комнаты (0 С, 1 В, 2 Ю, 3 З), за стеной которой пустота, или −1.
func _hull_side(r: Rect2i) -> int:
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for side in 4:
		var d: Vector2i = dirs[side]
		var cells: Array[Vector2i] = []
		for c in _edge_cells(r):
			if _outward(r, c) == d and not _is_corner(r, c):
				cells.append(c)
		var open := 0
		for c in cells:
			if _kind(c.x + d.x, c.y + d.y) == K_VOID:
				open += 1
		if cells.size() >= 3 and open >= cells.size() - 1:
			return side
	return -1

## Широкий шлюз наружу посреди стены комнаты, глядящей в пустоту (2–3 клетки).
func _hull_doors(r: Rect2i) -> void:
	var side := _hull_side(r)
	if side < 0:
		return
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var cells: Array[Vector2i] = []
	for c in _edge_cells(r):
		if _outward(r, c) == dirs[side] and not _is_corner(r, c):
			cells.append(c)
	cells.sort()
	var n := 3 if cells.size() >= 6 else 2
	var start := (cells.size() - n) / 2
	for k in n:
		if start + k < cells.size():
			_space_doors.append(cells[start + k])

## Лицевая сторона отсека: больше всего главного коридора за стеной (0 С, 1 В, 2 Ю, 3 З).
func _front_side(s: Rect2i) -> int:
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var best := -1
	var best_score := -1
	for side in 4:
		var hall := 0
		var maint := 0
		for c in _edge_cells(s):
			if _outward(s, c) != dirs[side] or _is_corner(s, c):
				continue
			var k := _kind(c.x + dirs[side].x, c.y + dirs[side].y)
			if k == K_HALL:
				hall += 1
			elif k == K_MAINT:
				maint += 1
		var score := hall * 100 + maint
		if score > best_score:
			best_score = score
			best = side
	if best_score <= 0:
		var to_mid := Vector2((w - 1) * 0.5, (h - 1) * 0.5) - Vector2(s.get_center())
		if absf(to_mid.x) > absf(to_mid.y):
			best = 1 if to_mid.x > 0 else 3
		else:
			best = 2 if to_mid.y > 0 else 0
	return best

## Клетка в местных осях отсека: u вдоль лицевой стороны, v вглубь (v = −1 — сама лицевая
## стена, v = D — задняя).
func _lc(s: Rect2i, f: int, u: int, v: int) -> Vector2i:
	match f:
		0: return Vector2i(s.position.x + 1 + u, s.position.y + 1 + v)
		2: return Vector2i(s.position.x + 1 + u, s.end.y - 2 - v)
		3: return Vector2i(s.position.x + 1 + v, s.position.y + 1 + u)
		_: return Vector2i(s.end.x - 2 - v, s.position.y + 1 + u)

## Прямоугольник комнаты (со стенами) по местным полосам [u0, u1) × [v0, v1).
func _local_rect(s: Rect2i, f: int, u0: int, u1: int, v0: int, v1: int) -> Rect2i:
	var a := _lc(s, f, u0, v0)
	var b := _lc(s, f, u1 - 1, v1 - 1)
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	return Rect2i(lo - Vector2i.ONE, hi - lo + Vector2i(3, 3))

## Нарезать полосу [u0, u1) × [v0, v1) на комнаты шириной mn..mx стенками-столбцами.
## Возвращает [[u0, u1], …] — внутренности комнат.
func _cut_strip(lc: Callable, u0: int, u1: int, v0: int, v1: int, mn: int, mx: int) -> Array:
	var out: Array = []
	var u := u0
	while u < u1:
		var left := u1 - u
		var width := left if left <= mx else _rng.randi_range(mn, mini(mx, left - mn - 1))
		out.append([u, u + width])
		u += width
		if u < u1:
			_kcol(lc, u, v0, v1)
			u += 1
	return out

func _kcol(lc: Callable, u: int, v0: int, v1: int) -> void:
	for v in range(v0, v1):
		_kset(lc.call(u, v), K_WALL)

func _kset(c: Vector2i, k: int) -> void:
	if _in(c):
		_k[c.y * w + c.x] = k

## Дверь приёмной в главный коридор (нет его — в техтуннель): ближе к середине лица.
func _reception_door(s: Rect2i, f: int, u0: int, u1: int, lc: Callable) -> void:
	var mid := (u0 + u1 - 1) / 2
	for span in maxi(1, u1 - u0):
		for sgn: int in [1, -1]:
			var u := mid + sgn * ((span + 1) / 2)
			if u < u0 or u >= u1:
				continue
			var c: Vector2i = lc.call(u, -1)
			var o: Vector2i = lc.call(u, -2)
			var k := _kind(o.x, o.y)
			if (k == K_HALL or k == K_MAINT) and _door_ok(c):
				_kset(c, K_DOOR)
				return

## Отсек ВЫЛЕЗ за обвод станции (0.9.4): его дальний от середины угол лежит снаружи
## суперэллипса. Считается по углу, а не по центру: отсек, лишь задевший обвод, станция
## сохраняет — иначе срезалась бы половина застройки.
func _outside_hull(s: Rect2i) -> bool:
	var mid := Vector2(_core.position) + Vector2(_core.size) * 0.5
	var half := Vector2(_core.size) * 0.5
	var far := Vector2(
			float(s.position.x) if absf(s.position.x - mid.x) > absf(s.end.x - 1 - mid.x) else float(s.end.x - 1),
			float(s.position.y) if absf(s.position.y - mid.y) > absf(s.end.y - 1 - mid.y) else float(s.end.y - 1))
	var dx := absf(far.x - mid.x) / maxf(1.0, half.x)
	var dy := absf(far.y - mid.y) / maxf(1.0, half.y)
	return pow(dx, HULL_POWER) + pow(dy, HULL_POWER) > HULL_MARGIN

## ПРИСТРОЙКА (0.9.4): комната ЗА обшивкой, соединённая со станцией узким коридором.
## Так стоит полигон лабораторий (игрок просил вынести его из станции) и так же станция
## обрастает модулями — причалом, воздухом, реактором, — а не остаётся глухим кирпичом.
##
## Садится на любой коридор, за которым сразу пустота, и строится ЦЕЛИКОМ в пустоте внутри
## игровой карты: ни одна клетка станции при этом не трогается. false — места не нашлось
## (тесная карта, застройка вплотную к краю), и тогда пристройки просто нет.
func _annex(kind: String, rw: int, rh: int) -> bool:
	var mounts: Array = []
	for y in range(_core.position.y, _core.end.y):
		for x in range(_core.position.x, _core.end.x):
			var k := _k[y * w + x]
			if k != K_HALL and k != K_MAINT:
				continue
			var c := Vector2i(x, y)
			if not _in_f(c):
				continue   # на зеркальной карте пристройка растёт в исходной части
			for d: Vector2i in N4:
				if _kind(c.x + d.x, c.y + d.y) == K_VOID:
					mounts.append([c, d])
	if mounts.is_empty():
		return false
	# Обход в случайном порядке — чтобы пристройка не садилась всегда на первый коридор.
	var start := _rng.randi_range(0, mounts.size() - 1)
	var link := _rng.randi_range(2, 4)
	for i in mounts.size():
		var m_at: Array = mounts[(start + i) % mounts.size()]
		if _try_annex(m_at[0], m_at[1], kind, rw, rh, link):
			return true
	return false

func _try_annex(c: Vector2i, d: Vector2i, kind: String, rw: int, rh: int, link: int) -> bool:
	var side := Vector2i(d.y, d.x)
	var half := rw / 2
	link = maxi(2, link)
	# Расклад вдоль d от коридора станции: 1 — дверь наружу, 2..link — коридорчик,
	# link+1 — ближняя стена комнаты (в ней дверь), link+2.. — сама комната.
	# Стена комнаты обязана начинаться СРАЗУ за коридорчиком, иначе она встаёт на его
	# последнюю клетку, и дверь открывается в стену.
	var a := c + d * (link + 2) - side * half
	var b := c + d * (link + 1 + rh) + side * (rw - 1 - half)
	var room := Rect2i(Vector2i(mini(a.x, b.x), mini(a.y, b.y)),
			Vector2i(absi(b.x - a.x) + 1, absi(b.y - a.y) + 1)).grow(1)
	var need: Array[Vector2i] = []
	for k in range(1, link + 1):
		need.append(c + d * k)
		need.append(c + d * k + side)      # бока коридора станут обшивкой — тоже должны быть пусты
		need.append(c + d * k - side)
	need.append_array(_rect_cells(room))
	for q in need:
		if not _core.has_point(q) or _kind(q.x, q.y) != K_VOID:
			return false
	# Дверь в станцию, коридор, комната, дверь в комнату.
	_kset(c + d, K_DOOR)
	_forced_doors[c + d] = true
	# Связка — СВОЙ коридорчик (K_DHALL), а не техтуннель: на вид это короткий переход в
	# пристройку, и считать его шириной техтуннеля (проверка 0.9.3) было бы неверно.
	for k in range(2, link + 1):
		_kset(c + d * k, K_DHALL)
	for q in _rect_cells(room):
		_kset(q, K_WALL if _on_edge(room, q) else K_ROOM)
	var door := c + d * (link + 1)
	_kset(door, K_DOOR)
	_forced_doors[door] = true
	_rooms.append(room)
	_room_kind[room] = kind
	_annex_rects[room] = true
	return true

## УСТЬЯ ТЕХТУННЕЛЕЙ (0.9.4): «tech tunnels should have airlocks on both ends». Устье —
## клетка туннеля, за которой начинается ШИРОКИЙ коридор (главный или коридор отдела);
## таких у туннеля ровно два, по концам. Туннель с туннелем стыкуется без дверей: это одна
## и та же служебная сеть.
##
## Шлюз ставится насильно (_forced_doors): у двухклеточного туннеля в устье стоят две
## клетки рядом, и обычная проверка проёма (стены по бокам) их не признаёт.
func _maintenance_mouths() -> void:
	var mouths: Array[Vector2i] = []
	for y in h:
		for x in w:
			if _k[y * w + x] != K_MAINT:
				continue
			for d: Vector2i in N4:
				var k := _kind(x + d.x, y + d.y)
				if k != K_HALL and k != K_DHALL:
					continue
				# Устье — это ПРОХОД: за ним туннель должен продолжаться. Тупиковая клетка
				# у обшивки (её оставил после себя срез бесхозных проходов, item 2) шлюза не
				# получает — иначе створка открывалась бы в глухую стену.
				var back := _kind(x - d.x, y - d.y)
				if back != K_MAINT and back != K_ROOM and back != K_DOOR:
					continue
				mouths.append(Vector2i(x, y))
				break
	for c in mouths:
		_kset(c, K_DOOR)
		_forced_doors[c] = true
		# В устье теперь дверь, а не настил: решётка — примета САМОГО туннеля (0.9.3), и под
		# створкой шлюза ей делать нечего.
		_hall_look[c.y * w + c.x] = 0

## Проходы, которым некого обслуживать (item 2, item 3). Коридоры и техтуннели режут
## станцию ЦЕЛИКОМ и до того, как часть отсеков отдаётся пустоте: проход через выброшенный
## отсек оставался висеть и уходил из станции прямо в космос ниткой в клетку шириной.
## Оставляем клетку прохода, если рядом ОСТАВЛЕННЫЙ отсек (grow(3): проход идёт по его
## кайме) или если она упирается в комнату, дверь или переход к пристройке. Остальное —
## обратно в пустоту; связность потом восстановит _join_pockets.
func _prune_orphan_halls(kept: Array[Rect2i]) -> void:
	var near_kept := _bytes()
	for s: Rect2i in kept:
		var g := s.grow(3)
		for y in range(maxi(0, g.position.y), mini(h, g.end.y)):
			for x in range(maxi(0, g.position.x), mini(w, g.end.x)):
				near_kept[y * w + x] = 1
	for y in h:
		for x in w:
			var k := _k[y * w + x]
			if (k != K_HALL and k != K_MAINT) or near_kept[y * w + x] != 0:
				continue
			var serves := false
			for d: Vector2i in DIRS8:
				var nk := _kind(x + d.x, y + d.y)
				if nk == K_ROOM or nk == K_DOOR or nk == K_DHALL:
					serves = true
					break
			if not serves:
				_k[y * w + x] = K_VOID
				_hall_look[y * w + x] = 0

## Технические комнаты (0.9.2): пара задних комнат, упёршихся в техтуннель, отходит под
## техслужбы — дверь у них только в туннель. Первая — переработка отходов (обязательна на
## любой станции; туннелей нет — ею становится маленькая комната инженерного).
func _maintenance_rooms() -> void:
	var cands: Array[Rect2i] = []
	for r in _rooms:
		if KEY_KINDS.has(_room_kind.get(r, "")) or not _in_f(r.get_center()) or _annex_rects.has(r):
			continue
		# Только ТЕСНАЯ комната (0.9.4): кладовка со щитками — это чулан, а не зал. Так отдел
		# не теряет под служебную сеть большую комнату, и его планировка остаётся цельной.
		if r.grow(-1).get_area() > MAINT_ROOM_MAX:
			continue
		if _maint_wall(r) != Vector2i(-1, -1):
			cands.append(r)
	# Чуланов по туннелям стало больше и они разные (0.9.4): игрок просил, чтобы туннели
	# были «more branching and varied» и несли «small rooms featuring technical equipment».
	var want := maxi(1, _rooms.size() / 9)
	var placed := 0
	for r in cands:
		if placed >= want:
			break
		# Двери в коридор отдела — заделать; дверь — в туннель.
		for c in _edge_cells(r):
			if _kind(c.x, c.y) == K_DOOR:
				_kset(c, K_WALL)
		_kset(_maint_wall(r), K_DOOR)
		# Первой — переработка (она обязательна), дальше по кругу: щитовая, вода, воздух,
		# реактор, кладовая.
		_room_kind[r] = "recycling" if placed == 0 else MAINT_KINDS[(placed - 1) % MAINT_KINDS.size()]
		placed += 1
	if placed == 0:
		# Ни одного туннеля рядом с комнатами — переработка в самой маленькой некл. комнате.
		var best := Rect2i()
		for r in _rooms:
			if KEY_KINDS.has(_room_kind.get(r, "")) or not _in_f(r.get_center()):
				continue
			if best.size == Vector2i.ZERO or r.get_area() < best.get_area():
				best = r
		if best.size != Vector2i.ZERO:
			_room_kind[best] = "recycling"

## Акценты по назначению комнаты (0.9.3) — поверх цвета отдела. Отдел красит свой коридор
## и всё, у чего своего цвета нет; комната с ясной службой перебивает его: серверная белая
## и на мостике, склад оранжевый и в медотсеке, щитовая жёлтая везде. Красятся стены
## комнаты (её кайма) — пол ни при чём.
func _accent_rooms() -> void:
	for r: Rect2i in _room_kind:
		var accent: int = KIND_ACCENT.get(_room_kind[r], MCF.Accent.NONE)
		if accent == MCF.Accent.NONE:
			continue
		for c in _edge_cells(r):
			if _in(c):
				_accent[c.y * w + c.x] = accent

## Стены комнат, которые обязаны остаться глухими (тайник капитана, санузел, раздевалка,
## камеры, морг — NO_WINDOW_KINDS): ни окна, ни внешнего шлюза. Ключи — клетки, чтобы
## проверка на обшивке стоила поиск по словарю.
func _sealed_room_walls() -> Dictionary:
	var out := {}
	for r: Rect2i in _room_kind:
		if not NO_WINDOW_KINDS.has(_room_kind[r]):
			continue
		for c in _edge_cells(r):
			out[c] = true
	return out

## Клетка стены комнаты, за которой техтуннель (середина такого куска), или (−1, −1).
func _maint_wall(r: Rect2i) -> Vector2i:
	var cells: Array[Vector2i] = []
	for c in _edge_cells(r):
		if _is_corner(r, c):
			continue
		var d := _outward(r, c)
		if _kind(c.x + d.x, c.y + d.y) == K_MAINT and _kind(c.x - d.x, c.y - d.y) == K_ROOM:
			cells.append(c)
	if cells.is_empty():
		return Vector2i(-1, -1)
	cells.sort()
	for k in cells.size():
		var c := cells[(cells.size() / 2 + k) % cells.size()]
		if _door_ok(c):
			return c
	return Vector2i(-1, -1)

## Выходы техтуннелей наружу (0.9.2): туннель, упёршийся в обшивку, за которой пустота на
## несколько клеток, получает шлюз — а за ним наружу уходят решётчатые мостки, и на них
## стоят солнечные панели (0.9.3).
##
## Мостки начинаются ВПЛОТНУЮ к обшивке (k = 1) и идут одной полосой: решётка держится за
## станцию, а не висит сама по себе в пустоте. Панели — по обе стороны от мостка, так что
## до любой из них можно дойти по решётке.
func _maintenance_exits() -> void:
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var used: Array[Vector2i] = []
	# Наружу служебная сеть выходит РЕДКО (item 2): «tech tunnels … should branch out into
	# space very rarely». Чаще всего станция обходится без мостков вовсе, изредка выход
	# один, совсем редко — два.
	var roll := _rng.randf()
	var limit := 0 if roll < SOLAR_EXIT_NONE else (1 if roll < SOLAR_EXIT_ONE else SOLAR_EXITS_MAX)
	if limit == 0:
		return
	for y in h:
		for x in w:
			if _k[y * w + x] != K_MAINT or not _in_f(Vector2i(x, y)):
				continue
			if used.size() >= limit:
				return
			for d: Vector2i in dirs:
				var wall := Vector2i(x, y) + d
				if _kind(wall.x, wall.y) != K_WALL:
					continue
				# ТОЛЬКО НАРУЖНАЯ ОБШИВКА (0.9.4): пустота за стеной обязана тянуться до края
				# игровой карты. Прежде хватало четырёх пустых клеток — и этому условию
				# отвечал ПУСТОЙ ОТСЕК внутри станции: мостки с панелями вырастали в дырке
				# посреди станции, хотя игрок просил держать их «only on the station's outer
				# hull».
				if not _looks_outside(wall, d):
					continue
				var near := false
				for u in used:
					if u.distance_to(wall) < SOLAR_EXIT_GAP:
						near = true
						break
				if near:
					continue
				used.append(wall)
				_space_doors.append(wall)
				var side := Vector2i(d.y, d.x)
				# Мостки — своей длины у каждого выхода, панели по обе стороны — своего
				# размера (item 4: «make solar panels vary in size»). Панель шириной pw
				# вдоль мостка и глубиной pd от него: от одинокой клетки до площадки 3×2.
				var span := _rng.randi_range(SOLAR_WALK_MIN, SOLAR_WALK_MAX)
				for k in range(1, span + 1):
					_grill.append(wall + d * k)            # мостки от самой обшивки
				for t: int in [-1, 1]:
					var pw := _rng.randi_range(1, mini(SOLAR_PANEL_MAX, span - 1))
					var pd := _rng.randi_range(1, SOLAR_PANEL_DEPTH)
					var at := _rng.randi_range(2, maxi(2, span - pw + 1))
					for a in pw:
						for b in range(1, pd + 1):
							_solar.append(wall + d * (at + a) + side * (t * b))
				break
## Пустота за клеткой обшивки тянется НАРУЖУ до края игровой карты (0.9.4): по этому луч
## и отличает настоящий борт станции от пустого отсека внутри неё.
func _looks_outside(wall: Vector2i, d: Vector2i) -> bool:
	var q := wall + d
	while _core.has_point(q):
		if _kind(q.x, q.y) != K_VOID:
			return false
		q += d
	return true

## Делит кусок коридором, пока обе стороны не меньше `mn`. Листья — отсеки.
##
## Ширина прохода (0.9.3, по просьбе игрока). Станцию насквозь режет ОДИН главный ход в три
## клетки — по нему она и читается. Все прочие коридоры — две: широкий коридор нужен там,
## где по нему и правда ходят, а не «огромные коридоры без смысла» в каждом отсеке. Узкими
## остаются технические туннели — клетка, изредка две.
##
## Решётчатый пол (MCF.Look.GRATE) — тоже примета техтуннеля, и не всякого: он достаётся
## примерно трети, остальные идут по обычному полу станции, иначе решётка лезет из каждой
## щели и перестаёт что-либо значить.
const MAINT_WIDE_CHANCE := 0.25
const MAINT_GRATE_CHANCE := 0.35
## Мельче этого кусок станции техтуннелем не делится (0.9.4).
const MAINT_SPLIT_MIN := 9
## Сколько самое большее выходов техтуннелей наружу с панелями бывает на станции (0.9.4) и
## как далеко они стоят друг от друга. Сам выход — редкость (item 2): доли броска ниже.
const SOLAR_EXITS_MAX := 2
const SOLAR_EXIT_GAP := 10.0
const SOLAR_EXIT_NONE := 0.62   # станция вообще без мостков
const SOLAR_EXIT_ONE := 0.94    # ниже этого — один выход, выше — SOLAR_EXITS_MAX
## Мостки и панели на них разного размера (item 4): длина мостка и предельная площадка.
const SOLAR_WALK_MIN := 3
const SOLAR_WALK_MAX := 6
const SOLAR_PANEL_MAX := 3
const SOLAR_PANEL_DEPTH := 2
## Самое большее пустых отсеков на станцию (item 3) — сколько бы их ни было всего.
const EMPTY_SECTORS_MAX := 3

func _split_sectors(r: Rect2i, mn: int, depth: int, out: Array[Rect2i]) -> void:
	var tech := depth >= 2
	var width_roll := _rng.randf()
	var grate_roll := _rng.randf()
	var hall_w := 3
	if tech:
		hall_w = 2 if width_roll < MAINT_WIDE_CHANCE else 1
	elif depth > 0:
		hall_w = 2
	var hall_k := K_HALL if not tech else K_MAINT
	var hall_look := MCF.Look.GRATE if tech and grate_roll < MAINT_GRATE_CHANCE else 0
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
	# Чем глубже, тем мельче кусок, который ещё стоит делить (0.9.4): техтуннели от этого
	# ВЕТВЯТСЯ — «technical tunnels should be more branching and varied», — а отсеки отделов
	# остаются жилыми: ниже MAINT_SPLIT_MIN деление не идёт, иначе отдел выродился бы в одну
	# комнату.
	var mn_next := mn if depth < 1 else maxi(MAINT_SPLIT_MIN, mn * 4 / 5)
	if along_x:
		var cut := _rng.randi_range(mn, r.size.x - mn - hall_w)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x + cut, r.position.x + cut + hall_w):
				_k[y * w + x] = hall_k
				if hall_look != 0:
					_hall_look[y * w + x] = hall_look
		_split_sectors(Rect2i(r.position.x, r.position.y, cut, r.size.y), mn_next, depth + 1, out)
		_split_sectors(Rect2i(r.position.x + cut + hall_w, r.position.y,
				r.size.x - cut - hall_w, r.size.y), mn_next, depth + 1, out)
	else:
		var cut := _rng.randi_range(mn, r.size.y - mn - hall_w)
		for y in range(r.position.y + cut, r.position.y + cut + hall_w):
			for x in range(r.position.x, r.end.x):
				_k[y * w + x] = hall_k
				if hall_look != 0:
					_hall_look[y * w + x] = hall_look
		_split_sectors(Rect2i(r.position.x, r.position.y, r.size.x, cut), mn_next, depth + 1, out)
		_split_sectors(Rect2i(r.position.x, r.position.y + cut + hall_w, r.size.x,
				r.size.y - cut - hall_w), mn_next, depth + 1, out)

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
			if k == K_ROOM or k == K_HALL or k == K_DOOR or k == K_MAINT or k == K_DHALL:
				return true
	return false

## Настоящий проём: стена слева и справа, проход спереди и сзади (или наоборот).
## Проход, прошедший ВДОЛЬ стены, снёс её целиком — это уже не дверь, а открытый край.
func _is_doorway(x: int, y: int) -> bool:
	var wall := func(k: int) -> bool: return k == K_WALL or k == K_DOOR
	var open := func(k: int) -> bool: return k == K_ROOM or k == K_HALL or k == K_MAINT or k == K_DHALL
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
	# В стену ТАЙНИКА не режется ни то ни другое: вход у него ровно один — из каюты
	# капитана, — и люк наружу (или окно) выдавал бы его с первого взгляда. Прежде такой
	# шлюз изредка выпадал и открывал в тайник второй вход, прямо из космоса.
	var sealed := _sealed_room_walls()
	for c in _hull():
		if sealed.has(c):
			continue
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
	# Газон кладётся на ВСЁ поле — он же и кайма вокруг города (0.9.3): за последней улицей
	# трава просто продолжается ещё на BORDER клеток.
	for y in h:
		for x in w:
			_ground(Vector2i(x, y), lawn)
	var ox := _core.position.x
	var oy := _core.position.y
	var xs := _street_lines(_core.size.x)
	var ys := _street_lines(_core.size.y)
	for s in xs:
		for y in range(oy, _core.end.y):
			for x in range(ox + s.x, ox + s.x + s.y):
				_ground(Vector2i(x, y))
				_street[y * w + x] = 1
	for s in ys:
		for y in range(oy + s.x, oy + s.x + s.y):
			for x in range(ox, _core.end.x):
				_ground(Vector2i(x, y))
				_street[y * w + x] = 1
	_pick_districts()
	for gx in _gaps(xs, _core.size.x):
		for gy in _gaps(ys, _core.size.y):
			_block(Rect2i(ox + gx.x, oy + gy.x, gx.y - gx.x, gy.y - gy.x))

# --- Районы города (0.9.2) ---------------------------------------------------------------
## Город делится на районы: у одного края — промзона (склады, цеха, гаражи; на астероиде —
## шахтные постройки), в середине — деловой центр (лавки, конторы, закусочные), на большой
## карте — пара общественных зданий (участок полиции, клиника), остальное — жилые дома.
## Вид здания задаёт его комнаты: мебель и пол (MapFurnish).
var _industrial_side := 0
var _civic_left := 0

func _pick_districts() -> void:
	_industrial_side = _rng.randi_range(0, 3)
	var area := _core.size.x * _core.size.y
	_civic_left = 0 if area < 1600 else (1 if area < 4000 else 2)

func _district(b: Rect2i) -> String:
	# Район меряется по ГОРОДУ, а не по всему полю: кайма вокруг него (0.9.3) не должна
	# сдвигать промзону к середине, а центр — размывать.
	var c := Vector2(b.get_center() - _core.position)
	var cw := float(_core.size.x)
	var chh := float(_core.size.y)
	var big := _core.size.x * _core.size.y >= 900
	var edge: float = [c.y / chh, 1.0 - c.x / cw, 1.0 - c.y / chh, c.x / cw][_industrial_side]
	if big and edge < 0.22:
		return "industrial"
	var mid := Vector2(cw * 0.5, chh * 0.5)
	# Деловой центр (0.9.4) стал шире: прежней доли 0.22 на средней карте хватало на
	# один-два квартала, и лавки с конторами почти не появлялись отдельными зданиями —
	# ровно то, о чём просил игрок («shops and offices as separate buildings»).
	if (c - mid).length() < minf(cw, chh) * 0.34:
		if _civic_left > 0:
			_civic_left -= 1
			return "civic"
		return "commercial"
	# И ещё: отдельная лавка или контора нет-нет да встанет прямо в жилом квартале, как в
	# настоящем городе на углу улицы.
	if _rng.randf() < 0.14:
		return "commercial"
	return "residential"

func _building_kind(district: String, lot: Rect2i) -> String:
	var roll := _rng.randf()
	match district:
		"industrial":
			if _style == Style.ASTEROID:
				return "mining"
			return "warehouse" if roll < 0.4 else ("factory" if roll < 0.75 else "garage")
		"commercial":
			return "shop" if roll < 0.4 else ("office" if roll < 0.7 else "restaurant")
		"civic":
			return "police" if roll < 0.5 else "clinic"
	return "apartments" if lot.get_area() >= 120 and roll < 0.5 else "house"

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
	var district := _district(b)
	# Большой квартал — два дома с проулком посередине (промзона — одно большое здание).
	if district != "industrial" and split_roll < 0.6 and b.size.x >= 13 and b.size.x >= b.size.y:
		var cut := 6 + int(cut_roll * (b.size.x - 12))
		_house(Rect2i(b.position.x, b.position.y, cut, b.size.y), district)
		_house(Rect2i(b.position.x + cut + 1, b.position.y, b.size.x - cut - 1, b.size.y), district)
	elif district != "industrial" and split_roll < 0.6 and b.size.y >= 13:
		var cut := 6 + int(cut_roll * (b.size.y - 12))
		_house(Rect2i(b.position.x, b.position.y, b.size.x, cut), district)
		_house(Rect2i(b.position.x, b.position.y + cut + 1, b.size.x, b.size.y - cut - 1), district)
	else:
		_house(b, district)

## Дом на участке: отступ 0–1 клетка с каждой стороны, стены, 1–2 двери наружу, окна,
## в большом доме — перегородка с проходом.
func _house(lot: Rect2i, district: String = "residential") -> void:
	var kind := _building_kind(district, lot)
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
	# МАТЕРИАЛ СТЕНЫ (0.9.4): у каждого дома свой — кирпич, штукатурка, шлакоблок или бетон
	# окружения, — чтобы улица не стояла под одну гребёнку («multiple different wall types on
	# town maps»). Это ЧИСТЫЙ ВИД: правила у всех одни (MCF.WALL_LOOKS). Промзона кладётся из
	# блоков, деловой центр — штукатурка и кирпич, жильё — кирпич.
	var mat := -1
	if wall == MCF.FEATURE_WALL and _style == Style.ASTEROID:
		# Постройки на астероиде — из обшивки станции (item 11): кирпичный квартал посреди
		# вакуума читался как кусок города, случайно оказавшийся в космосе.
		mat = MCF.WALL_LOOK_STATION
	elif wall == MCF.FEATURE_WALL:
		var mat_roll := _rng.randf()
		match district:
			"industrial":
				mat = 2 if mat_roll < 0.7 else -1
			"commercial":
				mat = 1 if mat_roll < 0.45 else (0 if mat_roll < 0.8 else -1)
			"civic":
				mat = 1 if mat_roll < 0.6 else -1
			_:
				mat = 0 if mat_roll < 0.55 else (1 if mat_roll < 0.8 else -1)
	_rooms.append(house)
	_room_kind[house] = kind
	for y in range(house.position.y, house.end.y):
		for x in range(house.position.x, house.end.x):
			var c := Vector2i(x, y)
			if _on_edge(house, c):
				_put(c, wall)
				if mat >= 0:
					m.set_look(y * w + x, MCF.wall_look(mat))
			else:
				_ground(c, floor_type)
				_indoor[y * w + x] = 1
				if _style == Style.ASTEROID:
					m.set_look(y * w + x, MCF.Look.PLATE)   # пол модуля — палуба, а не паркет
	for i in (2 if house.get_area() >= 64 else 1):
		_front_door(house, floor_type)
	# Окна — стекло в стене, но не в углу и не у двери. Лавки и конторы — витринами,
	# склады и цеха — почти глухие.
	var glass_p := 0.14
	if district == "commercial":
		glass_p = 0.32
	elif district == "industrial":
		glass_p = 0.05
	for c in _edge_cells(house):
		if _rng.randf() < glass_p and not _is_corner(house, c) and not _near_door(c):
			_put(c, MCF.FEATURE_GLASS)
	_partition(house, wall, mat)
	# Санузел (0.9.2): в жилом доме, лавке, конторе, закусочной, участке, клинике — тесная
	# комнатка в углу с дверью внутрь дома. После перегородки — чтобы она его не разрезала.
	if district != "industrial" or kind == "garage":
		_bathroom(house, wall, mat)

## Перегородка в большом доме — внутренняя стена с одним проходом.
func _partition(house: Rect2i, wall: String, mat: int = -1) -> void:
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
			if mat >= 0:
				m.set_look(c.y * w + c.x, MCF.wall_look(mat))
	_mark_door(gap)

## Санузел в углу дома: внутренности 2×2 (в большом доме 2×3), Г-образная стенка с дверью.
## Только если угол свободен: не у входной двери, не на перегородке.
func _bathroom(house: Rect2i, wall: String, mat: int = -1) -> void:
	var inner := house.grow(-1)
	if inner.size.x < 6 or inner.size.y < 6:
		return
	var corner := _rng.randi_range(0, 3)
	var tall := 3 if inner.size.y >= 9 and _rng.randf() < 0.5 else 2
	for attempt in 4:
		var k := (corner + attempt) % 4
		var right := k == 1 or k == 2
		var down := k >= 2
		var x0 := inner.end.x - 2 if right else inner.position.x
		var y0 := inner.end.y - tall if down else inner.position.y
		var room := Rect2i(x0, y0, 2, tall)
		var wx := x0 - 1 if right else x0 + 2              # стенка-столбец
		var wy := y0 - 1 if down else y0 + tall           # стенка-строка
		var walls: Array[Vector2i] = []
		for y in range(room.position.y, room.end.y):
			walls.append(Vector2i(wx, y))
		for x in range(room.position.x, room.end.x):
			walls.append(Vector2i(x, wy))
		walls.append(Vector2i(wx, wy))
		var door := Vector2i(wx, room.position.y + room.size.y / 2)
		var hallway := door + Vector2i(-1 if right else 1, 0)   # куда дверь выходит в доме
		var ok := _clear(hallway) and not _near_door(hallway)
		for c in walls + _rect_cells(room):
			if not ok or not _clear(c) or _near_door(c) or _door[c.y * w + c.x] != 0:
				ok = false
				break
		if not ok:
			continue
		for c in walls:
			_put(c, wall)
			if mat >= 0:
				m.set_look(c.y * w + c.x, MCF.wall_look(mat))
		_ground(door, m.get_floor(door))
		_mark_door(door)
		# ОКНАМ В САНУЗЛЕ НЕ МЕСТО (0.9.4, просьба игрока). Стёкла в наружной стене дома
		# прорезаются ДО санузла (комнатка выгораживается последней, чтобы перегородка её не
		# разрезала), поэтому те, что попали в его стены, заделываются обратно стеной.
		for c in _edge_cells(room.grow(1)):
			if MCF.is_glass(m.get_feature(c)):
				_put(c, wall)
				if mat >= 0:
					m.set_look(c.y * w + c.x, MCF.wall_look(mat))
		return

func _rect_cells(r: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			out.append(Vector2i(x, y))
	return out

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
	var area := float(_core.size.x * _core.size.y)
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
			# Кайма (0.9.3) — ровное травяное поле без пятен и построек: за картой мир
			# продолжается, но воевать там негде.
			var grass := not _core.has_point(Vector2i(x, y)) or noise.get_noise_2d(x, y) > -0.2
			_ground(Vector2i(x, y), MCF.FLOOR_GRASS if fire and grass else MCF.FLOOR_NORMAL)
	var area := float(_core.size.x * _core.size.y)
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
	var r := Rect2i(_rng.randi_range(_core.position.x + 1, _core.end.x - rw - 1),
			_rng.randi_range(_core.position.y + 1, _core.end.y - rh - 1), rw, rh)
	var keep_p := _rng.randf_range(0.45, 0.7)
	var edge := _edge_cells(r)
	var rolls: Array[float] = []
	for c in edge:
		rolls.append(_rng.randf())
	for q in _rooms:
		if q.grow(2).intersects(r):
			return
	_rooms.append(r)
	_room_kind[r] = "ruin"
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
	var r := Rect2i(_rng.randi_range(_core.position.x + 2, _core.end.x - rw - 2),
			_rng.randi_range(_core.position.y + 2, _core.end.y - rh - 2), rw, rh)
	var wooden := _rng.randf() < 0.4 and bool(opt["flammable"])
	var door_side := _rng.randi_range(0, 3)
	var window_roll := _rng.randi_range(0, 9999)
	if r.position.x < 2 or r.position.y < 2:
		return
	for q in _rooms:
		if q.grow(2).intersects(r):
			return
	_rooms.append(r)
	_room_kind[r] = "hut"
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
	var area := float(_core.size.x * _core.size.y)
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
	var half := Vector2(_core.size) * 0.5
	var mid := Vector2(_core.position) + half - Vector2(0.5, 0.5)
	# Сперва РАЗМЕТКА, потом пустота (0.9.4). Прежде край острова прорезался прямо по
	# клеткам, и дом, на который он пришёлся, оставался половиной дома с комнатами,
	# обрубленными по стене, — «asteroid maps generate weirdly and rooms get cut on edges».
	# Теперь здание либо целиком на острове, либо его нет вовсе: задетый край дом уносит с
	# собой, и обвод получается чистым.
	var kill := _bytes()
	for y in h:
		for x in w:
			# Эллипс по размеру КАРТЫ: остров вписан в неё, сколько бы её ни вытянули, а
			# кайма вокруг (0.9.3) остаётся открытым космосом.
			var d := Vector2((x - mid.x) / half.x, (y - mid.y) / half.y).length()
			if d > 0.88 + 0.14 * noise.get_noise_2d(x, y):
				kill[y * w + x] = 1
	var kept_rooms: Array[Rect2i] = []
	for r in _rooms:
		var cut := false
		for c in _rect_cells(r):
			if not _in(c) or kill[c.y * w + c.x] != 0:
				cut = true
				break
		if not cut:
			kept_rooms.append(r)
			continue
		for c in _rect_cells(r):
			if _in(c):
				kill[c.y * w + c.x] = 1
				_room_mask[c.y * w + c.x] = 0
				_indoor[c.y * w + c.x] = 0
		_room_kind.erase(r)
	_rooms = kept_rooms
	for y in h:
		for x in w:
			if kill[y * w + x] != 0:
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
	for n in 1 + roundi(_core.size.x * _core.size.y / 1600.0):
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
	for n in 1 + roundi(_core.size.x * _core.size.y / per):
		var c := _random_cell(4)
		var rad := _rng.randf_range(1.5, 2.8)
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				if Vector2(dx, dy).length() + noise.get_noise_2d(c.x + dx, c.y + dy) <= rad:
					_space(c + Vector2i(dx, dy))

## Непроходимая кайма по краю поля (0.9.3). Внутри — BORDER клеток, куда можно выйти:
## грунт бункера копают, по траве города и поля ходят, в космосе станции летают. Снаружи —
## BORDER_RIM клеток того же вида, но в них уже не войти и там ничего не сломать: это
## MCF.FEATURE_BOUNDARY, стена в 2 м, которой нет ни в одном списке разрушимого.
##
## Пол и вакуум клетки сохраняются — меняется только объект на ней. Поэтому за каймой
## бункера видно грунт (у объекта есть плитка «boundary_bunker»), а за каймой станции,
## города и поля — звёзды или трава: своей плитки у объекта там нет, и он не рисуется
## вовсе. Так граница ЧИТАЕТСЯ как продолжение мира, а не как стена вокруг доски.
func _border_rim() -> void:
	var inner := _core.grow(BORDER)
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			if inner.has_point(c):
				continue
			m.set_cell(c, m.get_floor(c), MCF.WALL_HEIGHT, m.get_space(c), MCF.FEATURE_BOUNDARY)

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
				# Сквозь границу мира (0.9.3) пролом не идёт: её не пробить ничем, и
				# закуток, до которого иначе не добраться, вскрывается в другую сторону.
				if walk[j] == 0 and dist[j] > level + 1 \
						and m.feature_id[j] != MCF.FEATURE_BOUNDARY:
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
	# Зоне на оси нужна клетка ровно на оси; просторных там может не быть (у отделов
	# станции ось нередко идёт по узким коридорам, 0.9.2) — тогда годится любая чистая.
	if fold.is_empty() and _sym == 1:
		var clear := _clear_mask()
		for y in h:
			var i := y * w + fx
			if clear[i] != 0 and _door[i] == 0:
				fold.append(Vector2i(fx, y))
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
	var want := mini(CIV_CAP[lv], maxi(CIV_MIN[lv],
			roundi(_core.size.x * _core.size.y / 160.0 * dens * CIV_MULT[lv])))
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
