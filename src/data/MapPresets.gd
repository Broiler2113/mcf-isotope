class_name MapPresets
extends RefCounted

## Пресеты карт и заготовки редактора (editor-rework).
##
## Пресет — это ОКРУЖЕНИЕ карты (MapData.env): по нему TerrainTiles берёт плитки стен,
## пола и дверей — металл станции, кирпич города, камень поля и т. д. Те же пять, что у
## генератора (MapGen.STYLE_ENV). Кроме плиток пресет решает ровно две вещи (так решил
## владелец): чем заполнена НОВАЯ карта и во что ластик превращает клетку. Правил игры,
## набора кистей и лобби он не касается.
##
## Заготовки (stamps) — готовые куски карты: комнаты, дом, ДОТ, гнездо из мешков, окоп.
## Это тот же «узор», что у буфера обмена редактора, поэтому ставятся они тем же путём:
## с поворотом, отражением и симметрией.

const IDS := ["station", "town", "field", "bunker", "asteroid"]
const NAMES := ["Station", "Town", "Field", "Bunker", "Asteroid"]

## Клетка узора: [пол, высота, космос, объект, зона]. Зона KEEP — «зону не трогать».
const KEEP := -2

static func index_of(env: String) -> int:
	return maxi(0, IDS.find(env))

static func name_of(env: String) -> String:
	return NAMES[index_of(env)]

## Пустая клетка пресета — во что её превращает ластик: на станции и астероиде это
## космос, в поле — трава, в городе и бункере — голый пол (в бункере ластик «прорубает»
## скалу, которой залита новая карта).
static func blank_cell(env: String) -> Array:
	match env:
		"station", "asteroid":
			return [MCF.FLOOR_NORMAL, 0.0, true, ""]
		"field":
			return [MCF.FLOOR_GRASS, 0.0, false, ""]
	return [MCF.FLOOR_NORMAL, 0.0, false, ""]

## Новая карта под пресет: станция — палуба с кромкой космоса, город — мостовая, поле —
## трава с проплешинами земли, бункер — сплошная скала, астероид — остров в космосе.
## Зерно — от размера: та же карта того же размера всегда выглядит одинаково.
static func prefill(m: MapData, env: String) -> void:
	m.env = env
	var w := m.width
	var h := m.height
	var rng := RandomNumberGenerator.new()
	rng.seed = w * 7919 + h * 104729 + index_of(env)
	m.spawns = []
	m.zone_owner.fill(-1)
	for i in w * h:
		m.floor_type[i] = MCF.FLOOR_NORMAL
		m.cover_height[i] = 0.0
		m.is_space[i] = 0
		m.feature_id[i] = ""
	match env:
		"station":
			var edge := mini(2, mini(w, h) / 6)
			for y in h:
				for x in w:
					if x < edge or y < edge or x >= w - edge or y >= h - edge:
						m.is_space[y * w + x] = 1
		"field":
			for i in w * h:
				m.floor_type[i] = MCF.FLOOR_GRASS
			# Проплешины земли — несколько неровных пятен голого пола.
			for _k in maxi(2, w * h / 180):
				var c := Vector2(rng.randf_range(0, w), rng.randf_range(0, h))
				var r := rng.randf_range(1.5, 3.5)
				for y in range(maxi(0, int(c.y - r - 1)), mini(h, int(c.y + r + 2))):
					for x in range(maxi(0, int(c.x - r - 1)), mini(w, int(c.x + r + 2))):
						if Vector2(x + 0.5, y + 0.5).distance_to(c) <= r + rng.randf_range(-0.6, 0.6):
							m.floor_type[y * w + x] = MCF.FLOOR_NORMAL
		"bunker":
			for i in w * h:
				m.feature_id[i] = MCF.FEATURE_WALL
				m.cover_height[i] = MCF.WALL_HEIGHT
		"asteroid":
			# Остров: эллипс с неровной кромкой (три гармоники со случайными фазами).
			var phases: Array[float] = [rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU]
			var center := Vector2(w, h) * 0.5
			var radii := Vector2(w, h) * 0.38
			for y in h:
				for x in w:
					var d := (Vector2(x + 0.5, y + 0.5) - center) / radii
					var a := d.angle()
					var edge := 1.0 + 0.10 * sin(3.0 * a + phases[0]) + 0.06 * sin(5.0 * a + phases[1]) \
							+ 0.04 * sin(9.0 * a + phases[2])
					m.is_space[y * w + x] = 0 if d.length() <= edge else 1

# --- Заготовки ---

const STAMPS := [
	{"id": "small_room", "name": "Small room", "hint": "5×5 walls with an airlock door"},
	{"id": "large_room", "name": "Large room", "hint": "9×7 walls, airlock doors front and back"},
	{"id": "corridor", "name": "Corridor", "hint": "9×3 hallway, open at both ends"},
	{"id": "house", "name": "House", "hint": "7×6 wooden house with a door and two windows"},
	{"id": "pillbox", "name": "Pillbox", "hint": "5×5 concrete pillbox with an embrasure"},
	{"id": "sandbag_nest", "name": "Sandbag nest", "hint": "3×3 sandbags open at the back"},
	{"id": "trench", "name": "Trench line", "hint": "7 cells of trench"},
	{"id": "hedgehogs", "name": "Hedgehog row", "hint": "Four hedgehogs a cell apart"},
]

## Пустой узор w×h: все клетки прозрачные (null — «не трогать»).
static func pattern(w: int, h: int) -> Dictionary:
	var cells: Array = []
	cells.resize(w * h)
	return {"w": w, "h": h, "cells": cells, "spawns": []}

static func _put(p: Dictionary, x: int, y: int, feature: String = "",
		floor_t: int = MCF.FLOOR_NORMAL) -> void:
	p["cells"][y * int(p["w"]) + x] = [floor_t, maxf(0.0, MCF.feature_height(feature)),
			false, feature, KEEP]

## Коробка: стены по контуру, пол внутри.
static func _box(p: Dictionary, wall: String) -> void:
	var w: int = p["w"]
	var h: int = p["h"]
	for y in h:
		for x in w:
			var edge := x == 0 or y == 0 or x == w - 1 or y == h - 1
			_put(p, x, y, wall if edge else "")

static func stamp(id: String) -> Dictionary:
	var p: Dictionary
	match id:
		"small_room":
			p = pattern(5, 5)
			_box(p, MCF.FEATURE_WALL)
			_put(p, 2, 4, MCF.FEATURE_AIRLOCK)
		"large_room":
			p = pattern(9, 7)
			_box(p, MCF.FEATURE_WALL)
			_put(p, 4, 0, MCF.FEATURE_AIRLOCK)
			_put(p, 4, 6, MCF.FEATURE_AIRLOCK)
		"corridor":
			p = pattern(9, 3)
			for x in 9:
				_put(p, x, 0, MCF.FEATURE_WALL)
				_put(p, x, 1)
				_put(p, x, 2, MCF.FEATURE_WALL)
		"house":
			p = pattern(7, 6)
			_box(p, MCF.FEATURE_WOOD_WALL)
			_put(p, 3, 5, MCF.FEATURE_AIRLOCK)
			_put(p, 0, 2, MCF.FEATURE_GLASS)
			_put(p, 6, 2, MCF.FEATURE_GLASS)
		"pillbox":
			p = pattern(5, 5)
			_box(p, MCF.FEATURE_DOT)
			_put(p, 2, 0, MCF.FEATURE_DOT_OPEN)
			_put(p, 2, 4, MCF.FEATURE_AIRLOCK)
		"sandbag_nest":
			p = pattern(3, 3)
			for x in 3:
				_put(p, x, 0, MCF.FEATURE_SANDBAGS)
			_put(p, 0, 1, MCF.FEATURE_SANDBAGS)
			_put(p, 1, 1)
			_put(p, 2, 1, MCF.FEATURE_SANDBAGS)
			_put(p, 0, 2, MCF.FEATURE_SANDBAGS)
			_put(p, 1, 2)
			_put(p, 2, 2, MCF.FEATURE_SANDBAGS)
		"trench":
			p = pattern(7, 1)
			for x in 7:
				_put(p, x, 0, MCF.FEATURE_TRENCH)
		"hedgehogs":
			p = pattern(7, 1)
			for x in range(0, 7, 2):
				_put(p, x, 0, MCF.FEATURE_HEDGEHOG)
		_:
			p = pattern(1, 1)
	return p

# --- Преобразования узора (буфер обмена и заготовки) ---

## Поворот на 90° по часовой: (x, y) → (h−1−y, x).
static func rotated(p: Dictionary) -> Dictionary:
	var w: int = p["w"]
	var h: int = p["h"]
	var out := pattern(h, w)
	for y in h:
		for x in w:
			out["cells"][x * h + (h - 1 - y)] = _turned_cell(p["cells"][y * w + x], [1, 2, 3, 0])
	for s: Array in p["spawns"]:
		out["spawns"].append([h - 1 - int(s[1]), int(s[0]), s[2], s[3]])
	return out

## Отражение: по горизонтали (x → w−1−x) или по вертикали (y → h−1−y).
static func flipped(p: Dictionary, horizontal: bool) -> Dictionary:
	var w: int = p["w"]
	var h: int = p["h"]
	var out := pattern(w, h)
	for y in h:
		for x in w:
			var nx := w - 1 - x if horizontal else x
			var ny := y if horizontal else h - 1 - y
			out["cells"][ny * w + nx] = _turned_cell(p["cells"][y * w + x],
					[0, 3, 2, 1] if horizontal else [2, 1, 0, 3])
	for s: Array in p["spawns"]:
		out["spawns"].append([w - 1 - int(s[0]) if horizontal else int(s[0]),
				int(s[1]) if horizontal else h - 1 - int(s[1]), s[2], s[3]])
	return out

## Клетка узора с поворотом мебели (6-й элемент, 0.9.2), переставленным по таблице map
## (k → map[k]). Без поворота клетка та же самая.
static func _turned_cell(cell: Variant, map: Array) -> Variant:
	if cell == null or (cell as Array).size() < 6 or int(cell[5]) < 0:
		return cell
	var t: Array = (cell as Array).duplicate()
	t[5] = map[int(t[5]) % 4]
	return t

## Вырезать узор из карты: прямоугольник r целиком, со спавнами и зонами.
static func capture(m: MapData, r: Rect2i) -> Dictionary:
	var p := pattern(r.size.x, r.size.y)
	for y in r.size.y:
		for x in r.size.x:
			var i := (r.position.y + y) * m.width + r.position.x + x
			p["cells"][y * r.size.x + x] = [int(m.floor_type[i]), float(m.cover_height[i]),
					m.is_space[i] != 0, String(m.feature_id[i]), int(m.zone_owner[i]), m.get_turn(i)]
	for s: Dictionary in m.spawns:
		var c: Vector2i = s["coord"]
		if r.has_point(c):
			p["spawns"].append([c.x - r.position.x, c.y - r.position.y, s["stats_id"], int(s["owner"])])
	return p
