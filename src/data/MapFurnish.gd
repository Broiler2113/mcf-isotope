class_name MapFurnish
extends RefCounted

## Обстановка случайной карты (§3.15): мебель по комнатам, мелочь по коридорам и улицам,
## износ. Отдельная фаза генератора (MapGen.Phase.FURNITURE) со своим потоком случайных
## чисел — карта без мебели («Off») строится байт в байт такой же, как до мебели.
##
## Мебель не сыплется по клеткам наугад. Каждое помещение — связный кусок пола внутри
## прямоугольника комнаты (перегородка дома делит его на два) — получает назначение
## (спальня, кухня, склад…) по стилю карты и своему размеру, а назначение — рецепт:
## кровать в угол и тумбочку рядом, стол посередине и стулья вокруг, стеллажи рядами с
## проходами, шкафчики вдоль стены. Плотность решает, сколько пунктов рецепта успеет
## встать: на «Sparse» в спальне только кровать, на «Very dense» — всё.
##
## Проход сохраняется по построению, а не чинится потом. Вплотную к двери и шлюзу (и в
## саму «прихожую» комнаты без дверей) не встаёт ничего; зоны развёртывания пусты. Каждый
## предмет ставится, только если весь свободный пол комнаты по-прежнему связан с её
## входами — даже считая всю мебель непроходимой, хотя на всё ниже 2 м можно залезть.
## Обычно хватает проверки восьми соседей (не рвёт ли клетка кольцо вокруг себя); где
## не хватает — обход комнаты целиком.

const DENSITY_NAMES := ["Off", "Sparse", "Normal", "Dense", "Very dense"]
## Сколько «обставляемых» клеток помещения занимает мебель — ориентир, а не норма:
## рецепт и проходы срезают его сами.
const DENSITY_SHARE := [0.0, 0.15, 0.32, 0.48, 0.62]
## Мелочь второго прохода (ящики, урны, тележки) — доля от того же.
const CLUTTER_SHARE := [0.0, 0.03, 0.05, 0.07, 0.09]
const DAMAGE_NAMES := ["None", "Light", "Heavy"]
const DAMAGE_SHARE := [0.0, 0.12, 0.30]
const DEFAULT_DENSITY := 2

const N4: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## Кольцо восьми соседей по часовой, с севера; чётные — по сторонам, нечётные — углы.
const RING: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
		Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1)]

## Назначения помещений по стилю и размеру (мало < 20 клеток пола, средне < 50, много).
## [назначение, вес].
const ROOMS := {
	"station": [
		[["bedroom", 4], ["utility", 2], ["storage", 2], ["server_room", 1], ["medical", 1]],
		[["office", 3], ["medical", 2], ["workshop", 2], ["storage", 2], ["bedroom", 2],
			["server_room", 1], ["kitchen", 1], ["dining_room", 1]],
		[["storage", 2], ["warehouse", 1], ["workshop", 2], ["dining_room", 2], ["command", 1],
			["office", 1], ["medical", 1]],
	],
	"bunker": [
		[["barracks", 3], ["utility", 2], ["armory", 2], ["storage", 1]],
		[["barracks", 2], ["command", 1], ["armory", 2], ["workshop", 2], ["storage", 2], ["medical", 1]],
		[["armory", 2], ["storage", 2], ["command", 1], ["barracks", 2], ["workshop", 1]],
	],
	"town": [
		[["bedroom", 3], ["kitchen", 2], ["living_room", 1]],
		[["living_room", 3], ["kitchen", 2], ["bedroom", 2], ["office", 1], ["shop", 1]],
		[["shop", 2], ["restaurant", 2], ["warehouse", 1], ["garage", 1], ["office", 1],
			["living_room", 1]],
	],
	"asteroid": [
		[["bedroom", 2], ["utility", 2], ["storage", 2]],
		[["workshop", 2], ["mining", 2], ["storage", 2], ["kitchen", 1], ["bedroom", 1]],
		[["mining", 2], ["warehouse", 2], ["workshop", 1], ["dining_room", 1]],
	],
}

## Рецепты: шаги по порядку важности. f — предмет; at — правило места (см. _cells_for);
## n — сколько ([от, до] или число); p — вероятность шага; then — что ставится к КАЖДОМУ
## поставленному (тумбочка к кровати, стулья к столу).
const RECIPES := {
	"bedroom": [
		{"f": "bed", "at": "corner", "then": [{"f": "nightstand", "at": "next", "p": 0.7}]},
		{"f": "wardrobe", "at": "wall", "p": 0.8},
		{"f": "desk", "at": "wall", "p": 0.5, "then": [{"f": "chair", "at": "front"}]},
		{"f": "dresser", "at": "wall", "p": 0.5},
		{"f": "bookshelf", "at": "wall", "p": 0.3},
		{"f": "chair", "at": "free", "p": 0.3},
	],
	"living_room": [
		{"f": "sofa", "at": "wall", "then": [{"f": "coffee_table", "at": "front", "p": 0.8}]},
		{"f": "armchair", "at": "free", "n": [1, 2], "p": 0.7},
		{"f": "bookshelf", "at": "wall", "n": [1, 2]},
		{"f": "cabinet", "at": "wall", "p": 0.5},
		{"f": "dresser", "at": "wall", "p": 0.3},
	],
	"kitchen": [
		{"f": "kitchen_counter", "at": "row", "n": [2, 4]},
		{"f": "refrigerator", "at": "wall"},
		{"f": "dining_table", "at": "center", "then": [{"f": "chair", "at": "around", "n": [2, 4]}]},
		{"f": "cabinet", "at": "wall", "p": 0.5},
		{"f": "trash_bin", "at": "corner", "p": 0.6},
	],
	"dining_room": [
		{"f": "dining_table", "at": "grid", "n": [1, 4], "then": [{"f": "chair", "at": "around", "n": [2, 4]}]},
		{"f": "kitchen_counter", "at": "row", "n": [2, 3], "p": 0.6},
		{"f": "vending_machine", "at": "wall", "p": 0.4},
		{"f": "trash_bin", "at": "corner", "p": 0.5},
	],
	"restaurant": [
		{"f": "dining_table", "at": "grid", "n": [2, 5], "then": [{"f": "chair", "at": "around", "n": [2, 4]}]},
		{"f": "kitchen_counter", "at": "row", "n": [2, 4]},
		{"f": "refrigerator", "at": "wall", "p": 0.7},
		{"f": "checkout_counter", "at": "free", "p": 0.6},
		{"f": "trash_bin", "at": "corner", "p": 0.4},
	],
	"office": [
		{"f": "office_desk", "at": "grid", "n": [1, 6], "then": [{"f": "chair", "at": "front"}]},
		{"f": "filing_cabinet", "at": "row", "n": [1, 3]},
		{"f": "bookshelf", "at": "wall", "p": 0.5},
		{"f": "reception_desk", "at": "free", "p": 0.2},
		{"f": "trash_bin", "at": "corner", "p": 0.5},
		{"f": "armchair", "at": "free", "p": 0.2},
	],
	"command": [
		{"f": "conference_table", "at": "center", "then": [{"f": "chair", "at": "around", "n": [3, 4]}]},
		{"f": "server_rack", "at": "wall", "n": [1, 2]},
		{"f": "filing_cabinet", "at": "wall", "n": [1, 2]},
		{"f": "office_desk", "at": "wall", "n": [1, 2], "then": [{"f": "chair", "at": "front"}]},
		{"f": "bookshelf", "at": "wall", "p": 0.3},
	],
	"storage": [
		{"f": "storage_shelf", "at": "aisles"},
		{"f": "crate", "at": "free", "n": [1, 4]},
		{"f": "pallet", "at": "free", "n": [0, 2]},
		{"f": "barrel", "at": "free", "n": [0, 2]},
	],
	"warehouse": [
		{"f": "storage_shelf", "at": "aisles"},
		{"f": "pallet", "at": "free", "n": [1, 3]},
		{"f": "crate", "at": "free", "n": [2, 5]},
		{"f": "barrel", "at": "free", "n": [1, 3]},
	],
	"workshop": [
		{"f": "workbench", "at": "row", "n": [1, 3]},
		{"f": "tool_cabinet", "at": "wall", "n": [1, 2]},
		{"f": "machinery", "at": "center", "p": 0.7, "big": true},
		{"f": "equipment_cart", "at": "free", "p": 0.6},
		{"f": "toolbox", "at": "free", "p": 0.5},
		{"f": "industrial_cabinet", "at": "wall", "p": 0.3},
		{"f": "barrel", "at": "free", "p": 0.3},
	],
	"garage": [
		{"f": "workbench", "at": "row", "n": [1, 2]},
		{"f": "tool_cabinet", "at": "wall"},
		{"f": "locker", "at": "row", "n": [1, 3], "p": 0.4},
		{"f": "barrel", "at": "free", "n": [1, 2]},
		{"f": "pallet", "at": "free", "p": 0.6},
		{"f": "equipment_cart", "at": "free", "p": 0.5},
		{"f": "machinery", "at": "center", "p": 0.3, "big": true},
	],
	"server_room": [
		{"f": "server_rack", "at": "aisles"},
		{"f": "industrial_cabinet", "at": "wall", "p": 0.6},
		{"f": "generator", "at": "corner", "p": 0.4},
		{"f": "equipment_cart", "at": "free", "p": 0.3},
	],
	"medical": [
		{"f": "bed", "at": "row", "n": [2, 4]},
		{"f": "exam_table", "at": "center"},
		{"f": "cabinet", "at": "wall", "n": [1, 2]},
		{"f": "locker", "at": "wall", "p": 0.4},
		{"f": "equipment_cart", "at": "free", "p": 0.5},
		{"f": "filing_cabinet", "at": "wall", "p": 0.3},
	],
	"utility": [
		{"f": "generator", "at": "corner", "p": 0.8},
		{"f": "industrial_cabinet", "at": "wall", "n": [1, 2]},
		{"f": "tool_cabinet", "at": "wall", "p": 0.5},
		{"f": "barrel", "at": "free", "n": [1, 2]},
		{"f": "crate", "at": "free", "p": 0.5},
		{"f": "toolbox", "at": "free", "p": 0.3},
	],
	"barracks": [
		{"f": "bed", "at": "row", "n": [2, 5]},
		{"f": "locker", "at": "row", "n": [2, 4]},
		{"f": "dining_table", "at": "center", "p": 0.4, "then": [{"f": "chair", "at": "around", "n": [2, 3]}]},
		{"f": "ammo_crate", "at": "free", "p": 0.3},
		{"f": "bench", "at": "free", "p": 0.3},
		{"f": "wardrobe", "at": "wall", "p": 0.2},
	],
	"armory": [
		{"f": "storage_shelf", "at": "aisles", "p": 0.6},
		{"f": "ammo_crate", "at": "free", "n": [2, 5]},
		{"f": "locker", "at": "row", "n": [1, 3]},
		{"f": "crate", "at": "free", "p": 0.5},
	],
	"mining": [
		{"f": "machinery", "at": "center"},
		{"f": "workbench", "at": "wall"},
		{"f": "equipment_cart", "at": "free"},
		{"f": "crate", "at": "free", "n": [1, 3]},
		{"f": "barrel", "at": "free", "n": [1, 2]},
		{"f": "industrial_cabinet", "at": "wall", "p": 0.5},
		{"f": "generator", "at": "corner", "p": 0.4},
	],
	"shop": [
		{"f": "display_shelf", "at": "aisles"},
		{"f": "checkout_counter", "at": "free"},
		{"f": "trash_bin", "at": "corner", "p": 0.5},
		{"f": "vending_machine", "at": "wall", "p": 0.3},
	],
	"hut": [
		{"f": "bed", "at": "corner", "p": 0.8},
		{"f": "dining_table", "at": "center", "p": 0.5, "then": [{"f": "chair", "at": "around", "n": [1, 2]}]},
		{"f": "crate", "at": "free", "n": [1, 2]},
		{"f": "barrel", "at": "free", "p": 0.4},
		{"f": "cabinet", "at": "wall", "p": 0.3},
	],
	"ruin": [
		{"f": "crate", "at": "free", "n": [1, 3]},
		{"f": "barrel", "at": "free", "p": 0.6},
		{"f": "pallet", "at": "free", "p": 0.5},
		{"f": "chair", "at": "free", "p": 0.4},
		{"f": "cabinet", "at": "wall", "p": 0.2},
	],
	"generic_room": [
		{"f": "cabinet", "at": "wall"},
		{"f": "chair", "at": "free"},
		{"f": "crate", "at": "free", "p": 0.5},
		{"f": "dining_table", "at": "center", "p": 0.3, "then": [{"f": "chair", "at": "around", "n": [1, 2]}]},
	],
}

## Мелочь второго прохода по стилю.
const CLUTTER := {
	"station": ["crate", "toolbox", "equipment_cart", "trash_bin", "barrel"],
	"bunker": ["crate", "ammo_crate", "barrel", "toolbox"],
	"town": ["trash_bin", "crate", "cabinet", "pallet"],
	"asteroid": ["crate", "barrel", "pallet", "toolbox"],
	"field": ["crate", "barrel", "pallet"],
}

var g: MapGen
var m: MapData
var rng: RandomNumberGenerator
var w := 0
var h := 0
var level := 0
var env := "town"
## Поставленные предметы в порядке постановки — {"fid", "cells"} (для износа).
var placed: Array = []
## Текущее помещение: его клетки (индекс -> true), входы и сколько ещё можно поставить.
var _room: Dictionary = {}
var _entries: Dictionary = {}
var _budget := 0
var _area := 0
var _rect := Rect2i()
## Кандидаты помещения, собранные один раз (перемешаны потоком фазы): все годные клетки,
## у стены, в углу, посередине (ближе к центру — раньше).
var _cand_all: Array[Vector2i] = []
var _cand_wall: Array[Vector2i] = []
var _cand_corner: Array[Vector2i] = []
var _cand_center: Array[Vector2i] = []

## Обставить карту генератора g. Поток случайных чисел — уже выставленный фазой.
static func run(gen: MapGen) -> void:
	var lv := clampi(int(gen.opt.get("furniture", DEFAULT_DENSITY)), 0, DENSITY_NAMES.size() - 1)
	if lv == 0:
		return
	var f := MapFurnish.new()
	f.g = gen
	f.m = gen.m
	f.rng = gen._rng
	f.w = gen.w
	f.h = gen.h
	f.level = lv
	f.env = gen.m.env
	f._furnish()

## Клетки, куда мебель не встаёт ни в одной комнате: три на три вокруг каждой двери и
## шлюза, зоны развёртывания и всё, что генератор бережёт (_keep). Один проход по карте.
var _no_go: PackedByteArray

func _furnish() -> void:
	_no_go = PackedByteArray()
	_no_go.resize(w * h)
	for i in w * h:
		if g._zone[i] >= 0 or g._keep[i] != 0:
			_no_go[i] = 1
		if g._door[i] != 0 or m.feature_id[i] == MCF.FEATURE_AIRLOCK:
			var x := i % w
			var y := i / w
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if x + dx >= 0 and y + dy >= 0 and x + dx < w and y + dy < h:
						_no_go[(y + dy) * w + x + dx] = 1
	for r: Rect2i in g._rooms:
		# Симметричная карта: обставляется исходная часть, остальное — её зеркало (ниже).
		# Комната поперёк оси остаётся пустой: обставить её зеркально по половинкам значило
		# бы проверять проход дважды через ось.
		if g._sym > 0 and not (g._in_f(r.position) and g._in_f(r.end - Vector2i.ONE)):
			continue
		var comps := _components(r)
		var main := 0
		for ci in comps.size():
			if (comps[ci] as Array).size() > (comps[main] as Array).size():
				main = ci
		for ci in comps.size():
			_furnish_room(comps[ci], ci == main, comps.size(), r)
	_outdoor_clutter()
	_wear()
	if g._sym > 0:
		g._mirror()
		_mirror_damage()

# --- Помещения ---------------------------------------------------------------------------

## Связные куски свободного пола внутри прямоугольника комнаты (по четырём сторонам).
func _components(r: Rect2i) -> Array:
	var seen := {}
	var out: Array = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := Vector2i(x, y)
			if seen.has(c) or not _room_floor(c, r):
				continue
			var cells: Array[Vector2i] = [c]
			seen[c] = true
			var k := 0
			while k < cells.size():
				var p := cells[k]
				k += 1
				for d: Vector2i in N4:
					var q := p + d
					if not seen.has(q) and _room_floor(q, r):
						seen[q] = true
						cells.append(q)
			out.append(cells)
	return out

## Пол помещения — всё, по чему внутри ходят: голый пол, но и мешки, окоп, ящики ниже
## стены, что поставило убранство. Мебель встаёт только на голый пол (_base_ok), но
## проход обязан сохраниться и к мешкам: их тоже нельзя замуровать.
func _room_floor(c: Vector2i, r: Rect2i) -> bool:
	if not r.has_point(c) or not g._in(c):
		return false
	var i := c.y * w + c.x
	var f: String = m.feature_id[i]
	return g._indoor[i] != 0 and m.is_space[i] == 0 and m.cover_height[i] < MCF.WALL_HEIGHT \
			and f != MCF.FEATURE_HEDGEHOG and f != MCF.FEATURE_DRONE_STATION \
			and f != MCF.FEATURE_AIRLOCK and not Furniture.is_furniture(f)

func _furnish_room(cells: Array[Vector2i], main: bool, count: int, r: Rect2i) -> void:
	_room = {}
	for c in cells:
		_room[c] = true
	_rect = r
	_area = cells.size()
	# Входы: клетки помещения, от которых шаг ведёт наружу (у руин дверей нет — только
	# проломы). Сюда мебель не встаёт никогда.
	_entries = {}
	for c in cells:
		for d: Vector2i in N4:
			var q: Vector2i = c + d
			if _room.has(q) or not g._in(q):
				continue
			# Вход — шаг наружу на что угодно проходимое: дверь, шлюз, пол, пролом в космос
			# (дом, обрезанный вакуумом, бывает доступен только через него).
			if g._door[q.y * w + q.x] != 0 or _walk_free(q):
				_entries[c] = true
	_cand_all = []
	for c in cells:
		if _base_ok(c):
			_cand_all.append(c)
	var free := _cand_all.size()
	_budget = roundi(free * DENSITY_SHARE[level])
	if _budget <= 0:
		return
	_cand_all = _shuffled(_cand_all)
	_cand_wall = []
	_cand_corner = []
	_cand_center = []
	var mid := Vector2.ZERO
	for c in cells:
		mid += Vector2(c)
	mid /= maxf(1.0, cells.size())
	for c in _cand_all:
		if _wall_dir(c) != Vector2i.ZERO:
			_cand_wall.append(c)
			if _is_corner(c):
				_cand_corner.append(c)
		else:
			_cand_center.append(c)
	_cand_center.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := Vector2(a).distance_squared_to(mid)
		var db := Vector2(b).distance_squared_to(mid)
		return da < db or (da == db and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	var arch := _archetype(r, main, count)
	for step: Dictionary in RECIPES.get(arch, RECIPES["generic_room"]):
		if _budget <= 0:
			break
		_run_step(step, {})
	# Мелочь второго прохода — поверх рецепта, своей долей.
	var extra := roundi(free * CLUTTER_SHARE[level])
	var pool: Array = CLUTTER.get(_style_key(), CLUTTER["town"])
	for k in extra:
		var fid: String = pool[rng.randi_range(0, pool.size() - 1)]
		_budget = maxi(_budget, 1)
		_place_one(fid, "free", {})

## Назначение помещения: поле — хижина или руина; прочее — по таблице ROOMS. В доме
## с перегородкой большая половина — общая комната, меньшая — спальня или кухня.
func _archetype(r: Rect2i, main: bool, count: int) -> String:
	var style := _style_key()
	if style == "field":
		return "hut" if _has_door(r) else "ruin"
	var table: Array = ROOMS.get(style, ROOMS["town"])
	var size_class := 0 if _area < 20 else (1 if _area < 50 else 2)
	if style == "town" and count > 1:
		size_class = 1 if main else 0
	var opts: Array = table[size_class]
	var total := 0
	for o: Array in opts:
		total += int(o[1])
	var roll := rng.randi_range(0, total - 1)
	for o: Array in opts:
		roll -= int(o[1])
		if roll < 0:
			return o[0]
	return "generic_room"

func _style_key() -> String:
	return env if env in ["station", "bunker", "town", "asteroid", "field"] else "town"

func _has_door(r: Rect2i) -> bool:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if g._door[y * w + x] != 0:
				return true
	return false

## Шаг рецепта: сколько предметов, где — и что приставить к каждому. Предмет здесь —
## {"cells": клетки, "back": сторона стены за ним (ZERO — посреди комнаты)}.
func _run_step(step: Dictionary, anchor: Dictionary) -> Array:
	var got: Array = []
	if rng.randf() >= float(step.get("p", 1.0)):
		return got
	if bool(step.get("big", false)) and _area < 40:
		return got
	var n_raw: Variant = step.get("n", 1)
	var n: int = rng.randi_range(int(n_raw[0]), int(n_raw[1])) if n_raw is Array else int(n_raw)
	var fid: String = step["f"]
	var rule: String = step["at"]
	var subs: Array = step.get("then", [])
	match rule:
		"row":
			got = _place_row(fid, n)
		"aisles":
			got = _place_aisles(fid)
		"grid":
			var around := false
			for sub: Dictionary in subs:
				around = around or sub["at"] == "around"
			got = _place_grid(fid, n, around)
		_:
			for k in n:
				if _budget <= 0:
					break
				var piece := _place_one(fid, rule, anchor)
				if not piece.is_empty():
					got.append(piece)
	for piece: Dictionary in got:
		for sub: Dictionary in subs:
			if _budget <= 0:
				break
			_run_step(sub, piece)
	return got

## Один предмет по правилу места; {} — места не нашлось.
func _place_one(fid: String, rule: String, anchor: Dictionary) -> Dictionary:
	if _budget <= 0:
		return {}
	for c in _cells_for(rule, anchor):
		for shape: Dictionary in _shapes_at(fid, rule, c):
			if _try_piece(fid, shape):
				return shape
	return {}

## Кандидаты под правило, в порядке предпочтения:
##   corner — угол (стены с двух соседних сторон); wall — спиной к стене; center — ближе
##   к середине помещения, не у стены; free — где угодно; next — рядом с якорем, у его
##   изголовья вдоль стены (тумбочка у кровати); front — перед якорем, со стороны,
##   противоположной его стене (стул к столу-бюро); around — по всему периметру якоря
##   (стулья вокруг обеденного стола).
func _cells_for(rule: String, anchor: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	match rule:
		"next", "around", "front":
			var cells: Array = anchor.get("cells", [])
			var back: Vector2i = anchor.get("back", Vector2i.ZERO)
			var mine := {}
			for p: Vector2i in cells:
				mine[p] = true
			var first: Array[Vector2i] = []
			var rest: Array[Vector2i] = []
			for p: Vector2i in cells:
				if rule == "front":
					var f: Vector2i = p - back if back != Vector2i.ZERO else p + Vector2i(0, 1)
					if not mine.has(f) and _room.has(f):
						first.append(f)
					continue
				for d: Vector2i in N4:
					var q: Vector2i = p + d
					if mine.has(q) or not _room.has(q) or first.has(q) or rest.has(q):
						continue
					# Тумбочка — у изголовья: сбоку от клетки, что стоит у стены, и сама у стены.
					var head := back != Vector2i.ZERO and d != back and d != -back \
							and _is_wallish(p + back)
					(first if rule == "next" and head and _wall_dir(q) != Vector2i.ZERO else rest).append(q)
			out = _shuffled(first) + _shuffled(rest)
		"corner":
			out = _cand_corner
		"wall":
			out = _cand_wall
		"center":
			out = _cand_center
		_:
			out = _cand_all
	return out

## Формы предмета с якорной клеткой c. Одиночный — сама клетка. Цельный — каждый его след
## [ширина вдоль стены, глубина от стены]: у стены — спинкой к ней, якорь в одном из углов
## (в обе стороны вдоль стены); посреди комнаты — вокруг якоря, длинной осью вдоль длинной
## стороны помещения.
func _shapes_at(fid: String, rule: String, c: Vector2i) -> Array:
	if not Furniture.is_whole(fid):
		return [{"cells": [c], "back": _wall_dir(c)}]
	var out: Array = []
	var sizes: Array = Furniture.sizes_of(fid).duplicate()
	sizes = sizes.slice(0, sizes.size())
	for i in range(sizes.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = sizes[i]
		sizes[i] = sizes[j]
		sizes[j] = t
	var dv := _wall_dir(c)
	var against := Furniture.back_of(fid) != "" and dv != Vector2i.ZERO \
			and rule in ["wall", "corner", "row", "next", "front", "free"]
	for sz: Array in sizes:
		var sw: int = sz[0]
		var sd: int = sz[1]
		if against:
			var along := Vector2i(dv.y, dv.x)
			for sgn: int in ([1, -1] if rng.randf() < 0.5 else [-1, 1]):
				var cells: Array[Vector2i] = []
				for i in sw:
					for j in sd:
						cells.append(c + along * sgn * i - dv * j)
				out.append({"cells": cells, "back": dv})
		else:
			var dims: Array = [Vector2i(sw, sd), Vector2i(sd, sw)]
			if _rect.size.y > _rect.size.x:
				dims.reverse()
			for dm: Vector2i in dims:
				var start := c - Vector2i((dm.x - 1) / 2, (dm.y - 1) / 2)
				var cells: Array[Vector2i] = []
				for j in dm.y:
					for i in dm.x:
						cells.append(start + Vector2i(i, j))
				out.append({"cells": cells, "back": Vector2i.ZERO})
				if dm.x == dm.y:
					break
	return out

## Ряд вдоль одной стены. Секции (стойка, шкафчики) — сплошным рядом, срастаясь в одну;
## цельные предметы (кровати в казарме) — через клетку, чтобы не срослись друг с другом.
func _place_row(fid: String, n: int) -> Array:
	var got: Array = []
	var whole := Furniture.is_whole(fid)
	for start in _cells_for("wall", {}):
		if _budget <= 0 or not _ok(fid, start):
			continue
		var wd := _wall_dir(start)
		var along := Vector2i(wd.y, wd.x)
		if not whole:
			var run: Array[Vector2i] = [start]
			for sgn: int in [1, -1]:
				var c := start + along * sgn
				while run.size() < n and _room.has(c) and _wall_dir(c) == wd and _ok(fid, c):
					run.append(c)
					c += along * sgn
			for c in run:
				var one := {"cells": [c], "back": wd}
				if _budget > 0 and _try_piece(fid, one):
					got.append(one)
		else:
			var sz: Array = Furniture.sizes_of(fid)[0]
			var stride: int = int(sz[0]) + 1
			for sgn: int in [1, -1]:
				var c := start
				while got.size() < n and _budget > 0 and _room.has(c) and _wall_dir(c) == wd:
					var placed_one := false
					for shape: Dictionary in _shapes_at(fid, "row", c):
						var cells: Array = shape["cells"]
						var tail: Vector2i = cells[cells.size() - 1] - c
						if (tail.x * along.x + tail.y * along.y) * sgn < 0 and int(sz[0]) > 1:
							continue   # ряд растёт в одну сторону
						if _try_piece(fid, shape):
							got.append(shape)
							placed_one = true
							break
					c += along * sgn * (stride if placed_one else 1)
				if not got.is_empty():
					break
		if not got.is_empty():
			return got
	return got

## Стеллажи рядами вдоль длинной стороны помещения: ряд через два (проход в две клетки),
## концы рядов свободны — поперечный проход. Секции срастаются в сплошной стеллаж.
func _place_aisles(fid: String) -> Array:
	var got: Array = []
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := Vector2i(-1, -1)
	for c: Vector2i in _room:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	var horizontal := hi.x - lo.x >= hi.y - lo.y
	var across := (hi.y - lo.y) if horizontal else (hi.x - lo.x)
	var span := (hi.x - lo.x) if horizontal else (hi.y - lo.y)
	if span < 3:
		return got
	var off := rng.randi_range(0, 1)
	for k in range(1 + off, across, 3):
		for t in range(1, span):
			if _budget <= 0:
				return got
			var c := Vector2i(lo.x + t, lo.y + k) if horizontal else Vector2i(lo.x + k, lo.y + t)
			var one := {"cells": [c], "back": Vector2i.ZERO}
			if _room.has(c) and _try_piece(fid, one):
				got.append(one)
	return got

## Столы и рабочие места сеткой: между ними проходы, у каждого место для стула (за столом-
## бюро — ряд стульев, вокруг обеденного — кольцо). Шаг — по самому следу предмета.
func _place_grid(fid: String, n: int, around: bool) -> Array:
	var got: Array = []
	var lo := Vector2i(1 << 20, 1 << 20)
	for c: Vector2i in _room:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
	var sz: Array = Furniture.sizes_of(fid)[rng.randi_range(0, Furniture.sizes_of(fid).size() - 1)]
	var dm := Vector2i(int(sz[0]), int(sz[1]))
	if not Furniture.is_whole(fid):
		dm = Vector2i.ONE
	var period := Vector2i(dm.x + 3, dm.y + 3) if around else Vector2i(dm.x + 1, dm.y + 2)
	var origin := lo + (Vector2i(2, 2) if around else Vector2i(1, 1))
	var spots: Array[Vector2i] = []
	for c: Vector2i in _room:
		var d := c - origin
		if d.x >= 0 and d.y >= 0 and d.x % period.x == 0 and d.y % period.y == 0:
			spots.append(c)
	spots.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for c in spots:
		if got.size() >= n or _budget <= 0:
			break
		var cells: Array[Vector2i] = []
		for j in dm.y:
			for i in dm.x:
				cells.append(c + Vector2i(i, j))
		var shape := {"cells": cells, "back": Vector2i.ZERO}
		if _try_piece(fid, shape):
			got.append(shape)
	return got

# --- Проверки места ----------------------------------------------------------------------

## Можно ли вообще ставить мебель на клетку (без учёта самого предмета).
func _base_ok(c: Vector2i) -> bool:
	if not _room.has(c) or _entries.has(c):
		return false
	var i := c.y * w + c.x
	return m.feature_id[i] == "" and m.cover_height[i] <= 0.0 and _no_go[i] == 0

func _ok(fid: String, c: Vector2i) -> bool:
	if not _base_ok(c):
		return false
	# Высокое (от 1.5 м) не встаёт к окну — стекло остаётся окном.
	if Furniture.height_of(fid) >= 1.5:
		for d: Vector2i in N4:
			if MCF.is_glass(m.get_feature(c + d)):
				return false
	return true

## Поставить предмет, если все его клетки годятся и проход не рвётся. Клетки ставятся по
## одной, каждая с проверкой прохода (уже стоящие клетки предмета для неё — стена); не
## прошла одна — снимаются все. Цельный предмет не встаёт вплотную к другому того же вида:
## иначе они срослись бы в один.
func _try_piece(fid: String, shape: Dictionary) -> bool:
	if _budget <= 0:
		return false
	var cells: Array = shape["cells"]
	var mine := {}
	for c: Vector2i in cells:
		mine[c] = true
		if not _free(c) or not _ok(fid, c):
			return false
	# Крупное не жмётся к крупному: кровать, стол, диван, стойка, стеллаж не встают вплотную
	# друг к другу (и цельный предмет — к такому же, иначе они срослись бы в один). Рядом с
	# ними — только мелочь, что для того и ставится: стул, тумбочка, урна, ящик.
	var big := Furniture.joins(fid) or not Furniture.carriable(fid)
	for c: Vector2i in cells:
		for d: Vector2i in N4:
			var q: Vector2i = c + d
			if mine.has(q):
				continue
			var fq := m.get_feature(q)
			if not Furniture.is_furniture(fq):
				continue
			if fq == fid and Furniture.is_whole(fid):
				return false
			if big and fq != fid and (Furniture.is_whole(fid) or Furniture.is_whole(fq)) \
					and not Furniture.carriable(fq):
				return false
	var done: Array[Vector2i] = []
	for c: Vector2i in cells:
		if not _keeps_passage(c):
			for u in done:
				g._ground(u, m.get_floor(u))
			return false
		g._put(c, fid)
		done.append(c)
	placed.append({"fid": fid, "cells": done})
	_budget -= cells.size()
	return true

func _keeps_passage(c: Vector2i) -> bool:
	return _ring_one_arc(c) or _reconnects(c)

## Свободные стороны кольца связаны друг с другом через свободные углы — одной дугой.
## Тогда любой путь через c обходится по кольцу, и занять c безопасно. Считается без
## выделений: F свободных сторон, L связок между соседними свободными сторонами.
func _ring_one_arc(c: Vector2i) -> bool:
	var f := 0
	var l := 0
	var prev := _free(c + RING[6])
	for k in range(0, 8, 2):
		var side := _free(c + RING[k])
		if side:
			f += 1
			if prev and _free(c + RING[(k + 7) % 8]):
				l += 1
		prev = side
	return f <= 1 or (f < 4 and l >= f - 1) or l >= 3

## Точная проверка, если кольцо разорвано: при занятой c все её свободные соседи по
## сторонам по-прежнему связаны друг с другом. До этой клетки пол помещения был связан
## со входами, значит, раз соседи c связаны и без неё, связано и всё. Поиск идёт от
## одного соседа и обрывается, как только найдены остальные, — обычно за пару шагов
## в обход предмета, а не по всей комнате.
func _reconnects(c: Vector2i) -> bool:
	var need: Array[Vector2i] = []
	for k in range(0, 8, 2):
		if _free(c + RING[k]):
			need.append(c + RING[k])
	if need.size() <= 1:
		return true
	var left := need.size() - 1
	var want := {}
	for k in range(1, need.size()):
		want[need[k]] = true
	var seen := {c: true, need[0]: true}
	var queue: Array[Vector2i] = [need[0]]
	var i := 0
	while i < queue.size():
		var p := queue[i]
		i += 1
		for d: Vector2i in N4:
			var q: Vector2i = p + d
			if seen.has(q) or not _free(q):
				continue
			seen[q] = true
			if want.has(q):
				left -= 1
				if left == 0:
					return true
			queue.append(q)
	return false

## То же кольцо, но по всей карте, а не по помещению: снаружи (сквер, улица, коридор,
## поле) и при сдвиге износом. Проходима любая клетка ниже стены, кроме мебели, ежа и
## станции; шлюз — проход. Здесь кольцо — единственная проверка: не прошло — не ставим.
func _ring_ok_map(c: Vector2i) -> bool:
	var f := 0
	var l := 0
	var prev := _walk_free(c + RING[6])
	for k in range(0, 8, 2):
		var side := _walk_free(c + RING[k])
		if side:
			f += 1
			if prev and _walk_free(c + RING[(k + 7) % 8]):
				l += 1
		prev = side
	return f <= 1 or (f < 4 and l >= f - 1) or l >= 3

func _walk_free(c: Vector2i) -> bool:
	if not g._in(c):
		return false
	var i := c.y * w + c.x
	var fid: String = m.feature_id[i]
	if fid == MCF.FEATURE_AIRLOCK:
		return true
	return m.cover_height[i] < MCF.WALL_HEIGHT and fid != MCF.FEATURE_HEDGEHOG \
			and fid != MCF.FEATURE_DRONE_STATION and not Furniture.is_furniture(fid)

func _free(c: Vector2i) -> bool:
	if not _room.has(c):
		return false
	var i := c.y * w + c.x
	return not Furniture.is_furniture(m.feature_id[i]) and m.cover_height[i] < MCF.WALL_HEIGHT

## Сторона, с которой у клетки стена (первая по часовой с севера); ZERO — стены рядом нет.
func _wall_dir(c: Vector2i) -> Vector2i:
	for d: Vector2i in N4:
		if _is_wallish(c + d):
			return d
	return Vector2i.ZERO

func _walls_around(c: Vector2i) -> int:
	var n := 0
	for d: Vector2i in N4:
		if _is_wallish(c + d):
			n += 1
	return n

## Угол: стены с двух СОСЕДНИХ сторон (а не напротив друг друга, как в коридорчике).
func _is_corner(c: Vector2i) -> bool:
	for k in 4:
		if _is_wallish(c + N4[k]) and _is_wallish(c + N4[(k + 1) % 4]):
			return true
	return false

func _is_wallish(c: Vector2i) -> bool:
	return not g._in(c) or (not _room.has(c) and m.get_cover(c) >= MCF.WALL_HEIGHT)

func _shuffled(a: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for x in a:
		out.append(x)
	for i in range(out.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := out[i]
		out[i] = out[j]
		out[j] = t
	return out

# --- Улицы, коридоры, поле ---------------------------------------------------------------

## Мелочь снаружи помещений: скамьи, урны и столы в скверах, урны и баки у стен на
## широких улицах, ящики и тележки вдоль стен широких коридоров станции, ящики и бочки
## у хижин в поле. Только у стены, только там, где рядом остаётся проход в две клетки.
func _outdoor_clutter() -> void:
	var style := _style_key()
	var share: float = [0.0, 0.004, 0.008, 0.013, 0.02][level]
	_room = {}
	_entries = {}
	if style == "town" or style == "asteroid":
		for p: Rect2i in g._parks:
			if g._sym > 0 and not (g._in_f(p.position) and g._in_f(p.end - Vector2i.ONE)):
				continue
			for k in 1 + roundi(p.get_area() / 40.0 * DENSITY_SHARE[level]):
				var c := Vector2i(rng.randi_range(p.position.x, p.end.x - 1),
						rng.randi_range(p.position.y, p.end.y - 1))
				var pick: String = ["bench", "bench", "park_table", "trash_bin"][rng.randi_range(0, 3)]
				_outdoor_put(c, pick, false)
	for y in h:
		for x in w:
			if rng.randf() >= share:
				continue
			var c := Vector2i(x, y)
			if g._sym > 0 and not g._in_f(c):
				continue
			var i := y * w + x
			var pick := ""
			if style == "town" or style == "asteroid":
				if g._street[i] != 0:
					pick = ["trash_bin", "dumpster", "street_cabinet", "trash_bin"][rng.randi_range(0, 3)]
			elif style == "field":
				if g._indoor[i] == 0 and g._room_mask[i] == 0 and _near_room(c):
					pick = ["crate", "barrel", "pallet", "bench"][rng.randi_range(0, 3)]
			elif g._k.size() == w * h and g._k[i] == MapGen.K_HALL:
				pick = ["crate", "equipment_cart", "barrel", "trash_bin"][rng.randi_range(0, 3)]
			if pick != "":
				_outdoor_put(c, pick, style != "field")

## У хижины или руины (в двух клетках) — там в поле и лежит брошенное.
func _near_room(c: Vector2i) -> bool:
	for r: Rect2i in g._rooms:
		if r.grow(2).has_point(c) and not r.has_point(c):
			return true
	return false

func _outdoor_put(c: Vector2i, fid: String, need_wall: bool) -> void:
	if not _outdoor_ok(c):
		return
	var wd := Vector2i.ZERO
	if need_wall:
		# К стене спиной, и напротив — две свободные клетки: проход не сужается до одной.
		for d: Vector2i in N4:
			if m.get_cover(c + d) >= MCF.WALL_HEIGHT:
				wd = d
				break
		if wd == Vector2i.ZERO or not g._clear(c - wd) or not g._clear(c - wd * 2):
			return
	# Скамья, стол в сквере, бак — цельные предметы в две-три клетки: вдоль стены, а в
	# сквере — по случайной оси.
	var cells: Array[Vector2i] = [c]
	if Furniture.is_whole(fid):
		var sz: Array = Furniture.sizes_of(fid)[rng.randi_range(0, Furniture.sizes_of(fid).size() - 1)]
		var along := Vector2i(wd.y, wd.x) if wd != Vector2i.ZERO \
				else (Vector2i(1, 0) if rng.randf() < 0.5 else Vector2i(0, 1))
		for i in range(1, int(sz[0])):
			var q: Vector2i = c + along * i
			if not _outdoor_ok(q) or (need_wall and (m.get_cover(q + wd) < MCF.WALL_HEIGHT
					or not g._clear(q - wd) or not g._clear(q - wd * 2))):
				return
			cells.append(q)
		for q in cells:
			for d: Vector2i in N4:
				if not cells.has(q + d) and m.get_feature(q + d) == fid:
					return   # вплотную к такому же — срослись бы
	var done: Array[Vector2i] = []
	for q in cells:
		if not _ring_ok_map(q):
			for u in done:
				g._ground(u, m.get_floor(u))
			return
		g._put(q, fid)
		done.append(q)
	placed.append({"fid": fid, "cells": done})

## Клетка снаружи, куда вообще можно что-то поставить.
func _outdoor_ok(c: Vector2i) -> bool:
	if not g._in(c):
		return false
	var i := c.y * w + c.x
	if m.is_space[i] != 0 or m.feature_id[i] != "" or m.cover_height[i] > 0.0 \
			or g._zone[i] >= 0 or g._keep[i] != 0 or g._indoor[i] != 0 or g._near_door(c):
		return false
	for d: Vector2i in RING:
		var q := c + d
		if m.get_feature(q) == MCF.FEATURE_AIRLOCK:
			return false
	return true

# --- Износ -------------------------------------------------------------------------------

## Износ (None/Light/Heavy): часть мебели пропала, разбита в щепки, побита (прочность
## ниже табличной — в MapData.feature_dur) или сдвинута на соседнюю клетку. Цельный предмет
## пропадает или бьётся целиком; сдвигается только одноклеточное (то, что можно взять в
## руки) и только туда, где это не рвёт проход. Ничто не освобождает клетку, от которой
## уже не дойти до пола.
func _wear() -> void:
	var dmg := clampi(int(g.opt.get("furniture_damage", 0)), 0, DAMAGE_NAMES.size() - 1)
	if dmg == 0:
		return
	for piece: Dictionary in placed:
		if rng.randf() >= DAMAGE_SHARE[dmg]:
			continue
		var cells: Array = piece["cells"]
		var fid: String = piece["fid"]
		if m.get_feature(cells[0]) != fid:
			continue
		var roll := rng.randf()
		var dur := Furniture.durability_of(fid)
		if roll < 0.3 or (roll < 0.5 and dur <= 1):
			if _piece_touches_open(cells):
				for c: Vector2i in cells:
					g._ground(c, m.get_floor(c))
		elif roll < 0.75 and dur >= 2:
			var left := rng.randi_range(1, dur - 1)
			for c: Vector2i in cells:
				m.set_feature_damage(c, left)
		elif not Furniture.joins(fid) and Furniture.mobility_of(fid) != Furniture.Mobility.FIXED:
			_displace(piece)   # сдвигается только то, что в одну клетку

func _displace(piece: Dictionary) -> void:
	var c: Vector2i = piece["cells"][0]
	var fid: String = piece["fid"]
	var floor_t := m.get_floor(c)
	for d: Vector2i in _shuffled(N4):
		var q: Vector2i = c + d
		if not g._clear(q) or _no_go[q.y * w + q.x] != 0 or g._indoor[q.y * w + q.x] != g._indoor[c.y * w + c.x] \
				or g._in_f(q) != g._in_f(c):
			continue
		# Сдвиг не должен перекрыть проход: клетка-цель проверяется кольцом по карте —
		# уже без самого предмета на старом месте.
		g._ground(c, floor_t)
		if _ring_ok_map(q):
			g._put(q, fid)
			if _touches_open(c):
				piece["cells"] = [q]
				return
			g._ground(q, m.get_floor(q))   # старое место осталось бы замурованным
		g._put(c, fid)
		return

## Есть ли у клетки свободный проходимый сосед — освободившись, она не станет закутком.
func _touches_open(c: Vector2i) -> bool:
	for d: Vector2i in N4:
		if _walk_free(c + d):
			return true
	return false

## То же для целого предмета: хоть одна его клетка выходит на свободный пол (сам предмет
## связен, поэтому, освободившись, выйдет весь).
func _piece_touches_open(cells: Array) -> bool:
	for c: Vector2i in cells:
		for d: Vector2i in N4:
			if not cells.has(c + d) and _walk_free(c + d):
				return true
	return false

## Зеркало побитой мебели: MapGen._mirror() копирует клетки, но не прочность.
func _mirror_damage() -> void:
	for y in h:
		for x in w:
			var i := y * w + x
			var s := g._src_index(x, y)
			if s == i:
				continue
			if m.feature_dur.has(s):
				m.feature_dur[i] = [m.feature_id[i], int(m.feature_dur[s][1])]
			else:
				m.feature_dur.erase(i)
