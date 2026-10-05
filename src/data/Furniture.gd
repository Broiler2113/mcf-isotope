class_name Furniture
extends RefCounted

## Мебель и прочие предметы обстановки (§3.15) — данные. Это ОБЫЧНЫЕ объекты клетки:
## GridCell.feature_id = id из DEFS, высота — в cover_height, прочность — в
## feature_durability. Ни своей сетки, ни узлов на предмет: движение, обзор, укрытие,
## сохранение, откат, сеть и повтор работают через ту же клетку, что и мешки со стенами.
##
## Новый предмет = новая строка в _BASE (цвета — в VARIANTS) (и, по желанию, плитка textures/<id>.png из
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
##   gen   — ставит ли его генератор случайных карт;
##   join  — многоклеточность (по умолчанию нет — предмет в одну клетку):
##           "run"   — секции: стойка, стеллаж, шкафчики, верстак. Каждая клетка — своя
##                     секция, соседние того же вида срастаются плиткой (автотайл) в одну
##                     длинную стойку; сломать, сдвинуть, сжечь можно одну секцию;
##           "whole" — цельный предмет: кровать 1×2 и 2×2, стол 3×2, диван 3×1, станок
##                     2×2. Предмет — все соседние по сторонам клетки того же вида: он
##                     ломается, гибнет и сдвигается ЦЕЛИКОМ, полкровати не бывает;
##   sizes — следы цельного предмета [ширина вдоль стены, глубина от стены];
##   back  — чем встаёт к стене: "long" — длинной стороной (диван, стол-бюро), "short" —
##           короткой (кровать изголовьем), "" — посреди комнаты (обеденный стол, станок).
## У каждой клетки предмета своя высота и прочность (это всё та же клетка-объект), а общего
## id нет: предмет — это связная группа клеток одного вида (piece_cells). Поэтому
## генератор никогда не ставит два цельных предмета одного вида вплотную — иначе две
## кровати срослись бы в одну.

enum Mobility {PORTABLE, HEAVY, FIXED}

const N4: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## Сколько клеток самое большее у одного цельного предмета (4×2 стол) — и предохранитель
## обхода, если в редакторе намазали поле кроватей.
const PIECE_CAP := 16

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

## Строки таблицы без цветовых вариантов; DEFS = они же плюс варианты (VARIANTS).
const _BASE := {
	# --- Жильё -------------------------------------------------------------------------
	"chair": {"name": "Chair", "cat": "residential", "h": 0.5, "mat": "wood", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "free", "gen": true,
		"rooms": ["bedroom", "living_room", "kitchen", "dining_room", "office", "command",
			"restaurant", "hut", "ruin", "barracks"]},
	"armchair": {"name": "Armchair", "cat": "residential", "h": 0.5, "mat": "fabric", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["living_room", "office", "command"]},
	"sofa": {"join": "whole", "sizes": [[2, 1], [3, 1]], "back": "long", "name": "Sofa", "cat": "residential", "h": 1.0, "mat": "fabric", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["living_room"]},
	"bed": {"join": "whole", "sizes": [[1, 2], [2, 2]], "back": "short", "name": "Bed", "cat": "residential", "h": 0.5, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 2, "at": "corner", "gen": true,
		"rooms": ["bedroom", "medical", "barracks", "hut"]},
	"nightstand": {"name": "Nightstand", "cat": "residential", "h": 0.5, "mat": "wood", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["bedroom"]},
	"desk": {"join": "whole", "sizes": [[2, 1]], "back": "long", "name": "Desk", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["bedroom", "office"]},
	"dining_table": {"join": "whole", "sizes": [[2, 1], [2, 2], [3, 2]], "back": "", "name": "Dining Table", "cat": "residential", "h": 1.0, "mat": "wood",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 2, "at": "center", "gen": true,
		"rooms": ["kitchen", "dining_room", "restaurant", "hut"]},
	"coffee_table": {"name": "Coffee Table", "cat": "residential", "h": 0.5, "mat": "wood",
		"dur": 1, "mob": Mobility.PORTABLE, "ap": 1, "at": "center", "gen": true,
		"rooms": ["living_room"]},
	"wardrobe": {"join": "whole", "sizes": [[2, 1]], "back": "long", "name": "Wardrobe", "cat": "residential", "h": 1.5, "mat": "wood", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["bedroom", "barracks"]},
	"dresser": {"join": "whole", "sizes": [[1, 1], [2, 1]], "back": "long", "name": "Dresser", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["bedroom", "living_room"]},
	"bookshelf": {"join": "run", "name": "Bookshelf", "cat": "residential", "h": 1.5, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["living_room", "office", "bedroom", "command"]},
	"cabinet": {"name": "Cabinet", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["kitchen", "medical", "living_room", "generic_room", "utility"]},
	"kitchen_counter": {"join": "run", "name": "Kitchen Counter", "cat": "residential", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["kitchen", "dining_room", "restaurant"]},
	"refrigerator": {"name": "Refrigerator", "cat": "residential", "h": 1.5, "mat": "metal",
		"dur": 3, "mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["kitchen", "restaurant"]},
	# --- Контора и лавка ------------------------------------------------------------------
	"office_desk": {"join": "whole", "sizes": [[2, 1]], "back": "long", "name": "Office Desk", "cat": "office", "h": 1.0, "mat": "metal", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["office", "command"]},
	"conference_table": {"join": "whole", "sizes": [[3, 2], [4, 2]], "back": "", "name": "Conference Table", "cat": "office", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.HEAVY, "ap": 2, "at": "center", "gen": true,
		"rooms": ["command", "office"]},
	"filing_cabinet": {"join": "run", "name": "Filing Cabinet", "cat": "office", "h": 1.0, "mat": "metal",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["office", "command", "medical"]},
	"locker": {"join": "run", "name": "Locker", "cat": "office", "h": 1.0, "mat": "metal", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["barracks", "medical", "garage", "armory"]},
	"reception_desk": {"join": "run", "name": "Reception Desk", "cat": "office", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "free", "gen": true,
		"rooms": ["office", "medical"]},
	"display_shelf": {"join": "run", "name": "Display Shelf", "cat": "office", "h": 1.5, "mat": "wood",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["shop"]},
	"checkout_counter": {"join": "run", "name": "Checkout Counter", "cat": "office", "h": 1.0, "mat": "wood",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "free", "gen": true,
		"rooms": ["shop", "restaurant"]},
	"vending_machine": {"name": "Vending Machine", "cat": "office", "h": 2.0, "mat": "metal",
		"dur": 4, "mob": Mobility.FIXED, "ap": 3, "at": "wall", "gen": true,
		"rooms": ["dining_room", "shop", "generic_room"]},
	# --- Промышленное ---------------------------------------------------------------------
	"workbench": {"join": "run", "name": "Workbench", "cat": "industrial", "h": 1.0, "mat": "wood", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["workshop", "garage", "mining"]},
	"tool_cabinet": {"name": "Tool Cabinet", "cat": "industrial", "h": 1.0, "mat": "metal",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["workshop", "garage", "utility"]},
	"storage_shelf": {"join": "run", "name": "Storage Shelf", "cat": "industrial", "h": 2.0, "mat": "metal",
		"dur": 3, "mob": Mobility.HEAVY, "ap": 2, "at": "free", "gen": true,
		"rooms": ["storage", "warehouse", "armory"]},
	"server_rack": {"join": "run", "name": "Server Rack", "cat": "industrial", "h": 1.5, "mat": "metal",
		"dur": 4, "mob": Mobility.FIXED, "ap": 3, "at": "free", "gen": true,
		"rooms": ["server_room", "command"]},
	"industrial_cabinet": {"join": "run", "name": "Industrial Cabinet", "cat": "industrial", "h": 1.5,
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
	"generator": {"join": "whole", "sizes": [[2, 1]], "back": "long", "name": "Generator", "cat": "industrial", "h": 1.5, "mat": "metal", "dur": 5,
		"mob": Mobility.FIXED, "ap": 3, "at": "corner", "gen": true,
		"rooms": ["utility", "server_room", "mining"]},
	"toolbox": {"name": "Toolbox", "cat": "industrial", "h": 0.5, "mat": "metal", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "free", "gen": true,
		"rooms": ["workshop", "garage", "utility"]},
	"ammo_crate": {"name": "Ammo Crate", "cat": "industrial", "h": 1.0, "mat": "metal", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "free", "gen": true,
		"rooms": ["armory", "barracks"]},
	"machinery": {"join": "whole", "sizes": [[2, 2], [3, 2]], "back": "", "name": "Machinery", "cat": "industrial", "h": 2.0, "mat": "metal", "dur": 4,
		"mob": Mobility.FIXED, "ap": 3, "at": "center", "gen": true,
		"rooms": ["workshop", "mining", "garage"]},
	"exam_table": {"join": "whole", "sizes": [[1, 2]], "back": "short", "name": "Examination Table", "cat": "industrial", "h": 1.0, "mat": "metal",
		"dur": 2, "mob": Mobility.HEAVY, "ap": 1, "at": "center", "gen": true,
		"rooms": ["medical"]},
	# --- Улица ----------------------------------------------------------------------------
	"bench": {"join": "whole", "sizes": [[2, 1], [3, 1]], "back": "long", "name": "Bench", "cat": "public", "h": 0.5, "mat": "wood", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "free", "gen": true,
		"rooms": ["outdoor", "barracks"]},
	"trash_bin": {"name": "Trash Bin", "cat": "public", "h": 0.5, "mat": "plastic", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "corner", "gen": true,
		"rooms": ["outdoor", "kitchen", "office", "shop", "restaurant", "dining_room"]},
	"dumpster": {"join": "whole", "sizes": [[2, 1]], "back": "long", "name": "Dumpster", "cat": "public", "h": 1.5, "mat": "metal", "dur": 4,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["outdoor"]},
	"park_table": {"join": "whole", "sizes": [[2, 1]], "back": "", "name": "Park Table", "cat": "public", "h": 1.0, "mat": "wood", "dur": 2,
		"mob": Mobility.FIXED, "ap": 1, "at": "free", "gen": true,
		"rooms": ["outdoor"]},
	"street_cabinet": {"name": "Street Cabinet", "cat": "public", "h": 1.5, "mat": "metal",
		"dur": 3, "mob": Mobility.FIXED, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["outdoor"]},
	# --- Добавлено позже ------------------------------------------------------------------
	"potted_plant": {"name": "Potted Plant", "cat": "residential", "h": 0.5, "mat": "plastic", "dur": 1,
		"mob": Mobility.PORTABLE, "ap": 1, "at": "corner", "gen": true,
		"rooms": ["living_room", "office", "command", "shop", "restaurant"]},
	"tv_stand": {"name": "TV Stand", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 1,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["living_room", "barracks", "bedroom"]},
	"stove": {"name": "Stove", "cat": "residential", "h": 1.0, "mat": "metal", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["kitchen", "restaurant"]},
	"piano": {"join": "whole", "sizes": [[2, 1]], "back": "long", "name": "Piano", "cat": "residential", "h": 1.0, "mat": "wood", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "wall", "gen": true,
		"rooms": ["living_room", "restaurant"]},
	"bunk_bed": {"join": "whole", "sizes": [[1, 2]], "back": "short", "name": "Bunk Bed", "cat": "residential", "h": 1.5, "mat": "metal", "dur": 3,
		"mob": Mobility.HEAVY, "ap": 2, "at": "corner", "gen": true,
		"rooms": ["barracks"]},
	"water_cooler": {"name": "Water Cooler", "cat": "office", "h": 1.5, "mat": "plastic", "dur": 1,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["office", "command", "medical"]},
	"washing_machine": {"name": "Washing Machine", "cat": "industrial", "h": 1.0, "mat": "metal", "dur": 2,
		"mob": Mobility.HEAVY, "ap": 1, "at": "wall", "gen": true,
		"rooms": ["utility", "barracks"]},
	"fuel_tank": {"join": "whole", "sizes": [[2, 2]], "back": "", "name": "Fuel Tank", "cat": "industrial", "h": 2.0, "mat": "metal", "dur": 5,
		"mob": Mobility.FIXED, "ap": 3, "at": "center", "gen": true,
		"rooms": ["utility", "mining"]},
}

## Цветовые варианты: та же строка таблицы (правила те же), свой id и своя плитка, где
## основной цвет заменён. Генератор ставит базовый id и сам выбирает вариант (variant) —
## один на шаг рецепта, так что ряд коек в казарме одного цвета. Разноцветные соседи не
## срастаются: это два разных предмета.
const VARIANTS := {
	"bed": [["red", Color8(150, 58, 52)], ["green", Color8(70, 112, 72)], ["grey", Color8(120, 122, 126)],
		["yellow", Color8(186, 156, 70)]],
	"bunk_bed": [["green", Color8(70, 100, 66)]],
	"sofa": [["red", Color8(140, 62, 56)], ["green", Color8(74, 108, 78)], ["brown", Color8(120, 86, 58)]],
	"armchair": [["blue", Color8(76, 96, 140)], ["green", Color8(74, 108, 78)], ["brown", Color8(120, 86, 58)]],
	"generator": [["red", Color8(170, 52, 44)], ["green", Color8(72, 112, 70)], ["grey", Color8(120, 126, 132)]],
	"locker": [["blue", Color8(64, 88, 128)], ["grey", Color8(118, 124, 132)]],
	"tool_cabinet": [["blue", Color8(46, 82, 150)], ["green", Color8(62, 110, 70)]],
	"barrel": [["red", Color8(160, 48, 42)], ["yellow", Color8(196, 160, 40)], ["green", Color8(66, 108, 70)]],
	"vending_machine": [["blue", Color8(44, 84, 160)], ["green", Color8(50, 124, 76)]],
	"dumpster": [["blue", Color8(52, 80, 130)], ["red", Color8(140, 52, 44)]],
	"trash_bin": [["grey", Color8(110, 114, 118)], ["blue", Color8(58, 88, 140)]],
	"fuel_tank": [["red", Color8(160, 54, 46)]],
	"piano": [["white", Color8(222, 220, 214)]],
}

static var DEFS: Dictionary = _with_variants()

static func _with_variants() -> Dictionary:
	var out := {}
	for fid: String in _BASE:
		out[fid] = _BASE[fid]
		for v: Array in VARIANTS.get(fid, []):
			var d: Dictionary = (_BASE[fid] as Dictionary).duplicate(true)
			d["name"] = "%s (%s)" % [_BASE[fid]["name"], str(v[0]).capitalize()]
			d["base"] = fid
			d["tint"] = v[1]
			d["gen"] = false
			out["%s_%s" % [fid, v[0]]] = d
	return out

## Базовый id варианта («bed_red» → «bed»); у базового — он сам.
static func base_of(fid: String) -> String:
	return str(DEFS[fid].get("base", fid)) if DEFS.has(fid) else fid

## Основной цвет варианта; прозрачный — у базового предмета.
static func tint_of(fid: String) -> Color:
	return DEFS[fid].get("tint", Color(0, 0, 0, 0)) if DEFS.has(fid) else Color(0, 0, 0, 0)

## Случайный цветовой вариант базового fid (или он сам). Без вариантов поток не трогаем.
static func variant(fid: String, rng: RandomNumberGenerator) -> String:
	var vs: Array = VARIANTS.get(fid, [])
	if vs.is_empty():
		return fid
	var k := rng.randi_range(0, vs.size())
	return fid if k == 0 else "%s_%s" % [fid, vs[k - 1][0]]

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

## Срастается ли с соседями того же вида (секции или цельный предмет).
static func joins(fid: String) -> bool:
	return DEFS.has(fid) and str(DEFS[fid].get("join", "")) != ""

## Цельный многоклеточный предмет (кровать, стол…), а не секция.
static func is_whole(fid: String) -> bool:
	return DEFS.has(fid) and str(DEFS[fid].get("join", "")) == "whole"

static func sizes_of(fid: String) -> Array:
	return DEFS[fid].get("sizes", [[1, 1]]) if DEFS.has(fid) else [[1, 1]]

static func back_of(fid: String) -> String:
	return str(DEFS[fid].get("back", "")) if DEFS.has(fid) else ""

## Клетки предмета, которому принадлежит c: у цельного — вся связная по сторонам группа
## клеток того же вида (не больше PIECE_CAP), у прочих — одна клетка. fid_at(клетка) —
## id объекта на клетке, "" за краем доски. Порядок — обход от c, одинаковый у всех пиров.
static func piece_cells(fid_at: Callable, c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [c]
	var fid: String = fid_at.call(c)
	if not is_whole(fid):
		return out
	var seen := {c: true}
	var k := 0
	while k < out.size() and out.size() < PIECE_CAP:
		var p := out[k]
		k += 1
		for d: Vector2i in N4:
			var q: Vector2i = p + d
			if not seen.has(q) and fid_at.call(q) == fid:
				seen[q] = true
				out.append(q)
	return out

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
