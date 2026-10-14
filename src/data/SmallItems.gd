class_name SmallItems
## Мелкие предметы (0.12.1, «Isotope issues fix 5», п. 8–9): кружки, бумаги, мониторы,
## инструменты. Чистая косметика (решение владельца): лежат НЕ по сетке — в любой точке и
## под любым углом, на столах и на полу, на правила не влияют. От взрыва и когда мебель
## тащат, разлетаются как гильзы; шкафы при этом раскрываются и высыпают содержимое.
##
## В карте предмет — [вид, x, y, угол]: x, y в клетках (дробные), угол в радианах.
## Стол сам ничего не рисует: «набор» стола (офис, обед, лаборатория…) только раскладывает
## предметы при постановке — дальше это обычные предметы, их можно двигать и удалять.
## Картинка вида — textures/items/item_<вид>/item_<вид>.png (tools/art/build_items.py).

const KINDS := {
	"papers": "Papers", "folder": "Folder", "book": "Book", "magazine": "Magazine",
	"mug": "Mug", "plate": "Plate", "cup": "Glass", "bottle": "Bottle", "can": "Can",
	"monitor": "Monitor", "keyboard": "Keyboard", "mouse": "Mouse", "phone": "Phone",
	"laptop": "Laptop", "radio": "Radio", "headset": "Headset", "wrench": "Wrench",
	"screwdriver": "Screwdriver", "flask": "Flask", "test_tubes": "Test Tubes",
	"clipboard": "Clipboard", "tray": "Tray", "remote": "Remote", "shirt": "Clothes",
	"box": "Box", "map_sheet": "Map",
	"newspaper": "Newspaper",
	"newspaper_local": "Newspaper Local",
	"newspaper_science": "Newspaper Science",
	"toolbox": "Toolbox",
	"cash_register": "Cash Register",
	"apple": "Apple",
	"orange": "Orange",
	"bread": "Bread",
	"sandwich": "Sandwich",
	"milk_carton": "Milk Carton",
	"meat": "Meat",
	"vegetables": "Vegetables",
	"cheese": "Cheese",
	"first_aid": "First Aid",
	"bandages": "Bandages",
	"medicine": "Medicine",
	"syringe": "Syringe",
	"stethoscope": "Stethoscope",
	"sample_vial": "Sample Vial",
	"guitar": "Guitar",
	"violin": "Violin",
	"flute": "Flute",
	"hammer": "Hammer",
	"pliers": "Pliers",
	"drill": "Drill",
	"saw": "Saw",
	"handcuffs": "Handcuffs",
	"rifle": "Rifle",
	"pistol": "Pistol",
	"ammunition": "Ammunition",
	"helmet": "Helmet",
	"hard_hat": "Hard Hat",
	"boots": "Boots",
	"gloves": "Gloves",
	"backpack": "Backpack",
	"fire_extinguisher": "Fire Extinguisher",
	"flashlight": "Flashlight",
	"keys": "Keys",
	"suitcase": "Suitcase",
	"microscope": "Microscope",
	"petri_dish": "Petri Dish",
	"multimeter": "Multimeter",
}

## Предметы рисуются чуть крупнее настоящего: в натуральную величину кружка — три точки.
const DRAW_SCALE := 1.3

## Наборы столов: по клетке стола — [виды на выбор, x, y (в клетке, спинка стола сверху),
## поворот в градусах, вероятность].
const SET_IDS := ["bare", "office", "dining", "coffee", "meeting", "workshop", "lab", "medical", "command"]
const SET_NAMES := ["Bare", "Office", "Dining", "Coffee", "Meeting", "Workshop", "Lab", "Medical", "Command"]
const SETS := {
	"bare": [],
	"office": [[["monitor", "laptop"], 0.5, 0.22, 0, 0.9], [["keyboard"], 0.5, 0.52, 0, 0.85], [["mouse"], 0.82, 0.55, 0, 0.6],
			[["mug", "cup"], 0.15, 0.3, 0, 0.45], [["papers", "folder", "clipboard", "newspaper"], 0.2, 0.7, 15, 0.5],
			[["phone"], 0.84, 0.25, 10, 0.3]],
	"dining": [[["plate", "sandwich", "bread", "apple"], 0.5, 0.5, 0, 0.9], [["cup", "mug"], 0.8, 0.25, 0, 0.5], [["bottle"], 0.2, 0.2, 0, 0.2]],
	"coffee": [[["magazine", "book", "newspaper", "newspaper_local", "newspaper_science"], 0.4, 0.5, 20, 0.7], [["mug", "cup"], 0.72, 0.45, 0, 0.5], [["remote"], 0.3, 0.3, 35, 0.4]],
	"meeting": [[["papers", "folder"], 0.5, 0.55, 0, 0.7], [["mug", "cup"], 0.78, 0.3, 0, 0.5], [["phone", "laptop"], 0.3, 0.35, 0, 0.3]],
	"workshop": [[["wrench", "screwdriver", "hammer", "pliers", "drill", "multimeter"], 0.35, 0.5, 30, 0.7], [["can", "bottle"], 0.75, 0.35, 0, 0.4],
			[["radio", "box"], 0.7, 0.68, 0, 0.35], [["papers"], 0.25, 0.75, 10, 0.2]],
	"lab": [[["flask", "microscope", "petri_dish", "sample_vial"], 0.3, 0.4, 0, 0.7], [["test_tubes"], 0.6, 0.3, 0, 0.6], [["clipboard", "papers"], 0.65, 0.7, 10, 0.5]],
	"medical": [[["tray", "first_aid", "syringe", "bandages", "stethoscope"], 0.5, 0.45, 0, 0.7], [["bottle", "flask"], 0.82, 0.28, 0, 0.4], [["clipboard"], 0.25, 0.72, 10, 0.3]],
	"command": [[["laptop", "map_sheet"], 0.45, 0.45, 0, 0.8], [["radio", "headset"], 0.8, 0.28, 0, 0.6],
			[["mug"], 0.18, 0.25, 0, 0.4], [["papers"], 0.25, 0.74, 15, 0.35]],
}

## Набор по умолчанию у каждого стола; чего здесь нет — не стол.
const TABLES := {
	"desk": "office", "office_desk": "office", "dining_table": "dining", "coffee_table": "coffee",
	"conference_table": "meeting", "steel_table": "medical", "lab_bench": "lab",
	"workbench": "workshop", "plastic_table": "dining", "park_table": "bare",
}

## Комната генератора → набор её столов (иначе — набор стола по умолчанию).
const ROOM_SETS := {
	"command": "command", "captain": "command", "briefing": "meeting", "office": "office",
	"reception": "office", "server_room": "office", "laboratory": "lab", "virology": "lab",
	"testing_range": "lab", "medical": "medical", "surgery": "medical", "morgue": "medical",
	"workshop": "workshop", "machine_shop": "workshop", "assembly": "workshop", "garage": "workshop",
	"power": "workshop", "kitchen": "dining", "dining_room": "dining", "restaurant": "dining",
	"living_room": "coffee",
}

## Что высыпается из шкафа, когда его тащат или взрывают.
## Что высыпается, когда хранилище разбивают или тащат. 0.12.2: посуды в шкафу больше нет
## (владелец, item 15) — только хозяйственная мелочь; список пополнен прочими хранилищами
## (item 24): ящики, стеллажи, холодильники, тумбочки.
const SPILLS := {
	"cabinet": ["box", "folder", "bottle", "can"], "wardrobe": ["shirt", "shirt", "box"],
	"dresser": ["shirt", "book", "remote"], "bookshelf": ["book", "book", "magazine"],
	"filing_cabinet": ["papers", "folder", "clipboard", "newspaper"], "locker": ["shirt", "can", "bottle", "box"],
	"tool_cabinet": ["wrench", "screwdriver", "can"], "industrial_cabinet": ["box", "can", "wrench"],
	"biohazard_cabinet": ["flask", "test_tubes", "bottle"],
	"kitchen_counter": ["plate", "mug", "cup", "bottle"],
	"nightstand": ["book", "phone", "remote"], "crate": ["box", "can", "papers"],
	"ammo_crate": ["ammunition", "ammunition", "pistol"], "toolbox": ["wrench", "screwdriver", "hammer", "pliers", "drill", "multimeter"],
	"storage_shelf": ["box", "box", "can"], "display_shelf": ["can", "bottle", "box"],
	"refrigerator": ["milk_carton", "apple", "meat", "vegetables", "cheese", "sandwich"], "specimen_fridge": ["flask", "test_tubes"],
	"server_rack": ["box", "headset"], "morgue_drawers": ["clipboard", "shirt"],
}
const SPILL_MIN := 3
const SPILL_MAX := 6
## Шанс, что содержимое высыплется, когда хранилище ТАЩАТ (0.12.2, item 24). Разбитое
## высыпается всегда.
const SPILL_DRAG_CHANCE := 0.5

static func is_kind(kind: String) -> bool:
	return KINDS.has(kind)

static func name_of(kind: String) -> String:
	return str(KINDS.get(kind, kind.capitalize()))

static func texture_name(kind: String) -> String:
	return "item_" + kind

static func is_table(fid: String) -> bool:
	return TABLES.has(Furniture.base_of(fid))

static func default_set(fid: String) -> String:
	return str(TABLES.get(Furniture.base_of(fid), "bare"))

static func spills(fid: String) -> bool:
	return not spill_contents(fid).is_empty()

static func spill_contents(fid: String) -> Array:
	var base := Furniture.base_of(fid)
	if base in Furniture.CONTENT_SHELVES:
		match str(Furniture.DEFS.get(fid, {}).get("contents", "")):
			"empty": return []
			"tools": return ["hammer", "pliers", "wrench", "screwdriver", "drill"]
			"medical": return ["medicine", "bandages", "first_aid", "syringe"]
			"food": return ["bread", "apple", "sandwich", "cheese", "can"]
			"drinks": return ["bottle", "can", "milk_carton"]
	return SPILLS.get(base, [])

## Раскрывается ли (дверцы, ящики) — у книжной полки дверец нет, она только роняет книги.
static func opens(fid: String) -> bool:
	return Furniture.base_of(fid) in ["cabinet", "wardrobe", "dresser", "filing_cabinet", "locker", "tool_cabinet", "industrial_cabinet", "biohazard_cabinet", "refrigerator", "specimen_fridge"]

## Предмет из карты, проверенный: [вид, x, y, угол] или пусто.
static func clean(entry: Variant) -> Array:
	if not (entry is Array) or (entry as Array).size() < 4 or not is_kind(str(entry[0])):
		return []
	return [str(entry[0]), float(entry[1]), float(entry[2]), fposmod(float(entry[3]), TAU)]

static func cell_of(item: Array) -> Vector2i:
	return Vector2i(floori(float(item[1])), floori(float(item[2])))

## Разложить набор set_id по клеткам стола. turn — куда смотрит спинка стола (0 север,
## 1 восток, 2 юг, 3 запад): раскладка поворачивается вместе со столом.
static func arrange(set_id: String, cells: Array, turn: int, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for c: Vector2i in cells:
		for slot: Array in SETS.get(set_id, []):
			if rng.randf() > float(slot[4]):
				continue
			var kinds: Array = slot[0]
			var kind: String = kinds[rng.randi_range(0, kinds.size() - 1)]
			var local := Vector2(float(slot[1]), float(slot[2])) \
					+ Vector2(rng.randf_range(-0.05, 0.05), rng.randf_range(-0.05, 0.05))
			var p := Vector2(c) + Vector2(0.5, 0.5) + (local - Vector2(0.5, 0.5)).rotated(turn * PI / 2.0)
			var rot := deg_to_rad(float(slot[3]) + rng.randf_range(-12.0, 12.0)) + turn * PI / 2.0
			out.append([kind, p.x, p.y, fposmod(rot, TAU)])
	return out

## Куда смотрит спинка стола на карте: к первой стене по сторонам (север, восток, юг,
## запад); у стола посреди комнаты — его ручной поворот или север.
static func turn_on_map(m: MapData, c: Vector2i) -> int:
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for k in 4:
		var q: Vector2i = c + dirs[k]
		if not m.in_bounds(q):
			continue
		var fid := m.get_feature(q)
		if m.get_cover(q) >= MCF.WALL_HEIGHT and not Furniture.is_furniture(fid):
			return k
	var t := m.get_turn(c.y * m.width + c.x)
	return t if t >= 0 else 0

## Предметы на клетках стола по его набору: для генератора и для кисти редактора.
static func furnish(m: MapData, cells: Array, set_id: String, rng: RandomNumberGenerator) -> Array:
	if cells.is_empty() or set_id == "bare":
		return []
	return arrange(set_id, cells, turn_on_map(m, cells[0]), rng)

## The newspaper brush varies printed editions; choosing an explicit edition is stable.
static func random_kind(kind: String, roll: int) -> String:
	return ["newspaper", "newspaper_local", "newspaper_science"][posmod(roll, 3)] if kind == "newspaper" else kind
