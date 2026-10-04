class_name Furniture
extends RefCounted

## Мебель и прочие предметы обстановки (§3.15) — данные. Это ОБЫЧНЫЕ объекты клетки:
## GridCell.feature_id = id из DEFS, высота — в cover_height, прочность — в
## feature_durability. Ни своей сетки, ни узлов на предмет: движение, обзор, укрытие,
## сохранение, откат, сеть и повтор работают через ту же клетку, что и мешки со стенами.
##
## Новый предмет = новая строка в DEFS (и, по желанию, плитка textures/<id>.png из
## tools/gen_textures.gd). Резолвер, редактор и генератор берут всё отсюда.
##
## Поля строки:
##   name  — подпись в журнале, подсказке и палитре редактора;
##   cat   — раздел палитры (CATEGORIES);
##   h     — высота класса 0.5 / 1.0 / 1.5 / 2.0 м: она и есть cover_height. 2.0 — стена во
##           всём (обзор, проход, выстрел), ниже — укрытие, на которое залезают по CLIMB_COST;
##   mat   — материал: дерево, ткань и пластик горят (FLAMMABLE), металл — нет;
##   dur   — прочность по единой шкале урона (§3.7, #89);
##   mob   — PORTABLE (несут в руках), HEAVY (волокут), FIXED (не сдвинуть);
##   ap    — сколько ОД стоит разломать вручную (1 обычное, 2 крупное, 3 тяжёлое железо);
##   rooms — в каких комнатах генератор его ставит (архетипы MapFurnish);
##   at    — как встаёт: "wall" спиной к стене, "corner" в угол, "center" посреди
##           комнаты, "free" куда угодно;
##   gen   — ставит ли его генератор случайных карт.
## Размер следа у всех 1×1 (FOOTPRINT): клетка держит один объект, и многоклеточная
## мебель потребовала бы общего id на клетки — без неё шкаф не разорвётся пополам.

enum Mobility {PORTABLE, HEAVY, FIXED}

const FOOTPRINT := Vector2i(1, 1)

const CATEGORIES := ["residential", "office", "industrial", "public"]
const CATEGORY_NAMES := {"residential": "Home", "office": "Office & shop",
		"industrial": "Industrial", "public": "Outdoor"}

const FLAMMABLE := {"wood": true, "fabric": true, "plastic": true}

## Штраф попадания от мебели-укрытия у цели (§3.15). Отдельная таблица, а не правка
## MCF.COVER_MOD: обычная таблица знает только 1 м (−2), и полутораметрового укрытия на
## картах до мебели не было — правило «1.5 м даёт −3» касается ТОЛЬКО мебели, чтобы ни
## одна прежняя клетка (рельеф, насыпь) не стала укрытием иначе, чем была.
## 0.5 м не мешает стрелку вовсе; 2.0 м — стена, сквозь неё не стреляют.
const COVER_MOD := {1.0: 2, 1.5: 3}

## Сколько прочности снимает мебели разрыв, задевший её клетку (граната, заряд, снаряд,
## дрон, мина). Стул, стол и тумбочка разлетаются с одного взрыва, шкаф и верстак — со
## второго, генератор переживает два.
const BLAST_DAMAGE := 2

const DEFS := {
	# --- Жильё -------------------------------------------------------------------------
	"chair": {"name": "Chair", "cat": "residential", "h": 0.5, "mat": "wood", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "free", "gen": true,
		"rooms": ["bedroom", "living_room", "kitchen", "dining_room", "office", "command",
			"restaurant", "hut", "ruin", "barracks"]},
	"armchair": {"name": "Armchair", "cat": "residential", "h": 0.5, "mat": "fabric", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["living_room", "office", "command"]},
	"sofa": {"name": "Sofa", "cat": "residential", "h": 1.0, "mat": "fabric", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["living_room"]},
	"bed": {"name": "Bed", "cat": "residential", "h": 0.5, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 2, "at": "corner", "gen": true,
		"rooms": ["bedroom", "medical", "barracks", "hut"]},
	"nightstand": {"name": "Nightstand", "cat": "residential", "h": 0.5, "mat": "wood", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["bedroom"]},
	"desk": {"name": "Desk", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["bedroom", "office"]},
	"dining_table": {"name": "Dining Table", "cat": "residential", "h": 1.0, "mat": "wood",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 2, "at": "center", "gen": true,
		"rooms": ["kitchen", "dining_room", "restaurant", "hut"]},
	"coffee_table": {"name": "Coffee Table", "cat": "residential", "h": 0.5, "mat": "wood",
		"dur": 1, "mob": Mobility.PORTABLE, "ap": 1, "at": "center", "gen": true,
		"rooms": ["living_room"]},
	"wardrobe": {"name": "Wardrobe", "cat": "residential", "h": 1.5, "mat": "wood", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["bedroom", "barracks"]},
	"dresser": {"name": "Dresser", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["bedroom", "living_room"]},
	"bookshelf": {"name": "Bookshelf", "cat": "residential", "h": 1.5, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["living_room", "office", "bedroom", "command"]},
	"cabinet": {"name": "Cabinet", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["kitchen", "medical", "living_room", "generic_room", "utility"]},
	"kitchen_counter": {"name": "Kitchen Counter", "cat": "residential", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["kitchen", "dining_room", "restaurant"]},
	"refrigerator": {"name": "Refrigerator", "cat": "residential", "h": 1.5, "mat": "metal",
		"dur": 3, "mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["kitchen", "restaurant"]},
	# --- Контора и лавка ------------------------------------------------------------------
	"office_desk": {"name": "Office Desk", "cat": "office", "h": 1.0, "mat": "metal", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["office", "command"]},
	"conference_table": {"name": "Conference Table", "cat": "office", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.HEAVY, "ap": 2, "at": "center", "gen": true,
		"rooms": ["command", "office"]},
	"filing_cabinet": {"name": "Filing Cabinet", "cat": "office", "h": 1.0, "mat": "metal",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["office", "command", "medical"]},
	"locker": {"name": "Locker", "cat": "office", "h": 1.0, "mat": "metal", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["barracks", "medical", "garage", "armory"]},
	"reception_desk": {"name": "Reception Desk", "cat": "office", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "free", "gen": true,
		"rooms": ["office", "medical"]},
	"display_shelf": {"name": "Display Shelf", "cat": "office", "h": 1.5, "mat": "wood",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["shop"]},
	"checkout_counter": {"name": "Checkout Counter", "cat": "office", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "free", "gen": true,
		"rooms": ["shop", "restaurant"]},
	"vending_machine": {"name": "Vending Machine", "cat": "office", "h": 2.0, "mat": "metal",
		"dur": 4, "mob": Mobility.FIXED, "ap": 3, "at": "wall", "gen": true,
		"rooms": ["dining_room", "shop", "generic_room"]},
	# --- Промышленное ---------------------------------------------------------------------
	"workbench": {"name": "Workbench", "cat": "industrial", "h": 1.0, "mat": "wood", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["workshop", "garage", "mining"]},
	"tool_cabinet": {"name": "Tool Cabinet", "cat": "industrial", "h": 1.0, "mat": "metal",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["workshop", "garage", "utility"]},
	"storage_shelf": {"name": "Storage Shelf", "cat": "industrial", "h": 2.0, "mat": "metal",
		"dur": 3, "mob": Mobility.HEAVY, "ap": 2, "at": "free", "gen": true,
		"rooms": ["storage", "warehouse", "armory"]},
	"server_rack": {"name": "Server Rack", "cat": "industrial", "h": 1.5, "mat": "metal",
		"dur": 4, "mob": Mobility.FIXED, "ap": 3, "at": "free", "gen": true,
		"rooms": ["server_room", "command"]},
	"industrial_cabinet": {"name": "Industrial Cabinet", "cat": "industrial", "h": 1.5,
		"mat": "metal", "dur": 4, "mob": Mobility.FIXED, "ap": 3, "at": "wall", "gen": true,
		"rooms": ["utility", "server_room", "workshop", "mining"]},
	"pallet": {"name": "Pallet", "cat": "industrial", "h": 0.5, "mat": "wood", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "free", "gen": true,
		"rooms": ["storage", "warehouse", "garage", "ruin"]},
	"crate": {"name": "Crate", "cat": "industrial", "h": 0.5, "mat": "wood", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "free", "gen": true,
		"rooms": ["storage", "warehouse", "workshop", "mining", "hut", "ruin", "armory"]},
	"barrel": {"name": "Barrel", "cat": "industrial", "h": 1.0, "mat": "metal", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["storage", "warehouse", "garage", "utility", "mining", "ruin"]},
	"equipment_cart": {"name": "Equipment Cart", "cat": "industrial", "h": 1.0, "mat": "metal",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["workshop", "medical", "mining", "server_room"]},
	"generator": {"name": "Generator", "cat": "industrial", "h": 1.5, "mat": "metal", "dur": 5,
		"mob": Mobility.FIXED, "ap": 3, "at": "corner", "gen": true,
		"rooms": ["utility", "server_room", "mining"]},
	"toolbox": {"name": "Toolbox", "cat": "industrial", "h": 0.5, "mat": "metal", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "free", "gen": true,
		"rooms": ["workshop", "garage", "utility"]},
	"ammo_crate": {"name": "Ammo Crate", "cat": "industrial", "h": 1.0, "mat": "metal", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "free", "gen": true,
		"rooms": ["armory", "barracks"]},
	"machinery": {"name": "Machinery", "cat": "industrial", "h": 2.0, "mat": "metal", "dur": 4,
		"mob": Mobility.FIXED, "ap": 3, "at": "center", "gen": true,
		"rooms": ["workshop", "mining", "garage"]},
	"exam_table": {"name": "Examination Table", "cat": "industrial", "h": 1.0, "mat": "metal",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 1, "at": "center", "gen": true,
		"rooms": ["medical"]},
	# --- Улица ----------------------------------------------------------------------------
	"bench": {"name": "Bench", "cat": "public", "h": 0.5, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["outdoor", "barracks"]},
	"trash_bin": {"name": "Trash Bin", "cat": "public", "h": 0.5, "mat": "plastic", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "corner", "gen": true,
		"rooms": ["outdoor", "kitchen", "office", "shop", "restaurant", "dining_room"]},
	"dumpster": {"name": "Dumpster", "cat": "public", "h": 1.5, "mat": "metal", "dur": 4,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["outdoor"]},
	"park_table": {"name": "Park Table", "cat": "public", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.FIXED, "ap": 1, "at": "free", "gen": true,
		"rooms": ["outdoor"]},
	"street_cabinet": {"name": "Street Cabinet", "cat": "public", "h": 1.5, "mat": "metal",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["outdoor"]},
}

static func is_furniture(fid: String) -> bool:
	return DEFS.has(fid)

static func def_of(fid: String) -> Dictionary:
	return DEFS.get(fid, {})

static func name_of(fid: String) -> String:
	return str(DEFS[fid]["name"]) if DEFS.has(fid) else fid

static func height_of(fid: String) -> float:
	return float(DEFS[fid]["h"]) if DEFS.has(fid) else 0.0

static func durability_of(fid: String) -> int:
	return int(DEFS[fid]["dur"]) if DEFS.has(fid) else 0

static func mobility_of(fid: String) -> int:
	return int(DEFS[fid]["mob"]) if DEFS.has(fid) else Mobility.FIXED

## Несут в руках (подобрать → поставить рядом).
static func carriable(fid: String) -> bool:
	return DEFS.has(fid) and int(DEFS[fid]["mob"]) == Mobility.PORTABLE

## Волокут тем же волочением, что мешки и ежа (§3.4).
static func draggable(fid: String) -> bool:
	return DEFS.has(fid) and int(DEFS[fid]["mob"]) == Mobility.HEAVY

static func flammable(fid: String) -> bool:
	return DEFS.has(fid) and FLAMMABLE.has(str(DEFS[fid]["mat"]))

static func break_ap(fid: String) -> int:
	return int(DEFS[fid]["ap"]) if DEFS.has(fid) else 0

## Перегораживает ли проход: ровно когда предмет в рост стены. Ниже — на него залезают
## по обычной цене подъёма (MCF.CLIMB_COST), как на мешки; отдельного правила нет.
static func blocks_move(fid: String) -> bool:
	return height_of(fid) >= MCF.WALL_HEIGHT

## Штраф попадания от мебели высотой h (см. COVER_MOD).
static func cover_penalty(h: float) -> int:
	return int(COVER_MOD.get(h, 0))

static func mobility_name(fid: String) -> String:
	match mobility_of(fid):
		Mobility.PORTABLE:
			return "portable"
		Mobility.HEAVY:
			return "drag"
	return "fixed"

## Все id в порядке палитры: по разделам, внутри — как в таблице.
static func ids() -> Array:
	var out: Array = []
	for cat: String in CATEGORIES:
		for fid: String in DEFS:
			if DEFS[fid]["cat"] == cat:
				out.append(fid)
	return out

## Что генератор ставит в комнату такого вида — в порядке таблицы.
static func for_room(room: String) -> Array:
	var out: Array = []
	for fid: String in DEFS:
		if bool(DEFS[fid]["gen"]) and (DEFS[fid]["rooms"] as Array).has(room):
			out.append(fid)
	return out
