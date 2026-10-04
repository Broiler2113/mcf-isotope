class_name TerrainTiles
extends RefCounted

## Ближний план доски — рельеф и объекты, «запечённые» в текстуры кусков (batch «team
## session», items 2/6/9/20/24).
##
## Раньше экран боя рисовал КАЖДУЮ видимую клетку КАЖДЫЙ кадр: заливка пола, тон укрытия,
## рамка объекта и его буквенная метка («WD», «##», «AL») строкой текста — по нескольку
## примитивов на клетку, а у текста ещё и по квадрату на букву. На больших картах и при
## шести сторонах это тысячи примитивов за кадр, а перерисовывается кадр на любое движение
## мыши. Здесь клетки куска рисуются в картинку ОДИН раз — плитками из res://textures, — и
## дальше кусок выводится одной текстурой. Кусок, в котором журнал вида (GridCell.
## look_changes) отметил перемену — у клетки или у соседа (от соседа зависит стык
## автотайла), — пересобирается целиком.
##
## Плитки — 32×32, у материала несколько вариантов (лента в файле, у листа автотайла —
## столбик листов), края у вариантов общие. Вариант клетки — по хешу её координаты, так что
## одинаковые плитки не складываются в повторяющийся узор.
##
## Кусок собирается в том разрешении, в каком он сейчас на экране (RES: 8/16/32 точки на
## клетку). Крупнее 32 не бывает: плитки сами 32×32, ближе их увеличивает фильтр NEAREST —
## пиксели остаются чёткими. 8 — для отъезда, где видна вся большая карта сразу.
## Сменился зум — нужные куски досбираются по нескольку за кадр, а пока их нет, выводится
## уже собранный вариант того же куска в другом разрешении.
##
## Слоёв у куска два: пол с огнём и объекты на прозрачном фоне. Между ними экран кладёт
## туман — объекты видны поверх пелены и на неразведанных клетках (планировка известна,
## бойцы — нет).
##
## Чего здесь НЕТ: мин (их видимость у каждой стороны своя), тумана (свой слой), бойцов,
## техники и эффектов — всё это, как и раньше, рисует экран боя поверх.

## Плитка в файле — T×T.
const T := 32
## Кусок — C×C клеток.
const C := 16
## Разрешения кусков: точек на клетку.
const RES := [8, 16, 32]
## Сколько кусков собирать за кадр, когда есть чем подменить недостающие.
const BUILDS_PER_FRAME := 4
## Потолок памяти под текстуры кусков; сверх него выбрасываются давно не показанные.
const MEMORY_BUDGET := 128 * 1024 * 1024

## Семейства автотайла: плитки одного семейства стыкуются друг с другом, так что стена
## переходит в окно или шлюз без шва.
const FAMILY := {
	"wall": "wall", "wood_wall": "wall", "glass": "wall", "armor_wall": "wall",
	"armor_glass": "wall", "dot": "wall", "dot_open": "wall", "bru": "wall",
	"airlock": "wall", "corpse_wall": "wall", "soil": "wall",
	"sandbags": "bags", "sandbag_wall": "bags", "hedgehog_sandbags": "bags", "rsp": "bags",
	"trench": "trench",
}

var _grid: Grid
## Объекты, которые НЕ запекаются в куски (playtest-20): экран боя прячет полевые
## укрепления под туманом и рисует их сам там, где их видят сейчас.
var skip_features: Dictionary = {}
## Окружение карты (item 24): плитка «<имя>_<окружение>» важнее общей.
var env: String = ""
var _chunks: Dictionary = {}     # Vector3i(cx, cy, res) -> {"floor", "feat": ImageTexture, "used": int, "bytes": int}
var _dirty: Dictionary = {}      # Vector2i(cx, cy) -> true: пересобрать во всех разрешениях
var _pick: Dictionary = {}       # Vector2i(cx, cy) -> ключ куска, выведенного полом в этом кадре
var _bytes := 0
var _built := 0
var _look_ver: int = -1
var _damage_ver: int = -1
var _damaged: Dictionary = {}
var _frame: int = 0
## Варианты плиток: "имя@res" -> Array[Image] (res×res); листы: "имя@res" -> Array[Image]
## (4res×4res). Пустой массив — картинки нет.
var _tiles: Dictionary = {}
var _sheets: Dictionary = {}

func _init(grid: Grid, p_env: String = "") -> void:
	_grid = grid
	env = p_env
	_look_ver = GridCell.look_version

## Имя картинки с учётом окружения: «wall» на станции — «wall_station», если такая есть.
static func env_name(name: String, p_env: String) -> String:
	if p_env != "" and (Sprites.has_override(name + "_" + p_env)
			or Sprites.has_override(name + "_" + p_env + Sprites.AUTOTILE_SUFFIX)):
		return name + "_" + p_env
	return name

## Разрешение куска для клетки в px точек на экране: с запасом, чтобы ужимать, а не
## растягивать.
static func res_for(px: float) -> int:
	if px >= 14.0:
		return 32
	if px >= 7.0:
		return 16
	return 8

## Хеш клетки → номер варианта (0..n-1).
static func variant_of(c: Vector2i, n: int) -> int:
	if n <= 1:
		return 0
	var h := (c.x * 73856093) ^ (c.y * 19349663)
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return h % n

## Варианты плитки в разрешении res (лента вариантов в файле).
func _tile(name: String, res: int) -> Array:
	var key := "%s@%d" % [name, res]
	if _tiles.has(key):
		return _tiles[key]
	var out: Array = []
	var img := _load(env_name(name, env))
	if img != null:
		var h := img.get_height()
		var n := maxi(1, img.get_width() / h) if img.get_width() % h == 0 else 1
		for v in n:
			var part := img.get_region(Rect2i(v * h, 0, h, h)) if n > 1 else img
			if part.get_width() != res or part.get_height() != res:
				part = part.duplicate()
				part.resize(res, res, Image.INTERPOLATE_LANCZOS)
			out.append(part)
	_tiles[key] = out
	return out

## Варианты листа автотайла в разрешении res (столбик листов 4×4 в файле).
func _sheet(name: String, res: int) -> Array:
	var key := "%s@%d" % [name, res]
	if _sheets.has(key):
		return _sheets[key]
	var out: Array = []
	var img := _load(env_name(name, env) + Sprites.AUTOTILE_SUFFIX)
	if img != null:
		var w := img.get_width()
		var n := maxi(1, img.get_height() / w)
		for v in n:
			var part := img.get_region(Rect2i(0, v * w, w, w)) if n > 1 else img
			if part.get_width() != res * 4:
				part = part.duplicate()
				part.resize(res * 4, res * 4, Image.INTERPOLATE_LANCZOS)
			out.append(part)
	_sheets[key] = out
	return out

func _load(name: String) -> Image:
	var tex := Sprites.texture_of(name)
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img

## Подтянуть журнал вида и копоть взрывов: пометить грязными куски тронутых клеток и
## их соседей.
func sync(fx_damage: Dictionary, damage_version: int) -> void:
	if _look_ver < GridCell.look_log_base:
		_chunks.clear()   # журнал оборвался — дешевле собрать заново, чем разбирать
		_bytes = 0
	elif _look_ver != GridCell.look_version:
		var ch := GridCell.look_changes
		var i: int = (_look_ver - GridCell.look_log_base) * 2
		while i < ch.size():
			_touch(Vector2i(ch[i], ch[i + 1]))
			i += 2
	_look_ver = GridCell.look_version
	if damage_version != _damage_ver:
		for c: Vector2i in _damaged:
			_touch(c)
		for c: Vector2i in fx_damage:
			_touch(c)
		_damaged = fx_damage.duplicate()
		_damage_ver = damage_version

func _touch(c: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dy)
			if n.x < 0 or n.y < 0 or n.x >= _grid.width or n.y >= _grid.height:
				continue
			_dirty[Vector2i(n.x / C, n.y / C)] = true

## Вывести куски слоя features=false (пол) или true (объекты), покрывающие клетки
## [x0..x1]×[y0..y1]; origin — угол доски, cell — размер клетки на холсте, res — нужное
## разрешение (res_for). Недостающие куски собираются при выводе пола; слой объектов
## выводит ровно те куски, что выбрал для этого кадра пол.
func draw(ci: CanvasItem, origin: Vector2, cell: float, x0: int, y0: int, x1: int, y1: int,
		features: bool, res: int = 32) -> void:
	if not features:
		_frame += 1
		_built = 0
		_pick.clear()
	for cy in range(y0 / C, y1 / C + 1):
		for cx in range(x0 / C, x1 / C + 1):
			var cc := Vector2i(cx, cy)
			var key: Variant = _pick.get(cc) if features else _choose(cc, res)
			if key == null:
				continue
			var chunk: Dictionary = _chunks[key]
			chunk["used"] = _frame
			var cells := Vector2(mini(C, _grid.width - cx * C), mini(C, _grid.height - cy * C))
			ci.draw_texture_rect(chunk["feat" if features else "floor"],
					Rect2(origin + Vector2(cx * C, cy * C) * cell, cells * cell), false)
	if features:
		_evict()

## Какой кусок вывести: в нужном разрешении (собрав его, если бюджет кадра позволяет), а
## иначе — уже собранный в другом. Грязный кусок выбрасывается во всех разрешениях.
func _choose(cc: Vector2i, res: int) -> Variant:
	if _dirty.has(cc):
		_dirty.erase(cc)
		for r: int in RES:
			_drop(Vector3i(cc.x, cc.y, r))
	var key := Vector3i(cc.x, cc.y, res)
	if not _chunks.has(key):
		var fallback: Variant = null
		for r: int in RES:
			if _chunks.has(Vector3i(cc.x, cc.y, r)):
				fallback = Vector3i(cc.x, cc.y, r)
		if fallback != null and _built >= BUILDS_PER_FRAME:
			_pick[cc] = fallback
			return fallback
		_build(cc, res)
		_built += 1
	_pick[cc] = key
	return key

func _drop(key: Vector3i) -> void:
	if _chunks.has(key):
		_bytes -= int(_chunks[key]["bytes"])
		_chunks.erase(key)

func _build(cc: Vector2i, res: int) -> void:
	var w := mini(C, _grid.width - cc.x * C)
	var h := mini(C, _grid.height - cc.y * C)
	var floor_img := Image.create(w * res, h * res, false, Image.FORMAT_RGBA8)
	var feat_img := Image.create(w * res, h * res, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			_paint(floor_img, feat_img, Vector2i(cc.x * C + x, cc.y * C + y),
					Vector2i(x * res, y * res), res)
	var bytes := w * h * res * res * 4 * 2
	_chunks[Vector3i(cc.x, cc.y, res)] = {"floor": ImageTexture.create_from_image(floor_img),
			"feat": ImageTexture.create_from_image(feat_img), "used": _frame, "bytes": bytes}
	_bytes += bytes

func _evict() -> void:
	if _bytes <= MEMORY_BUDGET:
		return
	var keys := _chunks.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return int(_chunks[a]["used"]) < int(_chunks[b]["used"]))
	for k: Vector3i in keys:
		if _bytes <= MEMORY_BUDGET or int(_chunks[k]["used"]) == _frame:
			break
		_drop(k)

## Клетка в картинки куска: пол и огонь — в слой пола, объект (автотайл по семейству) —
## в слой объектов. at — угол клетки в картинке, res — точек на клетку.
func _paint(img: Image, feat: Image, c: Vector2i, at: Vector2i, res: int) -> void:
	var cell := _grid.cell_fast(c.x, c.y)
	var full := Rect2i(0, 0, res, res)
	var floors := _tile(_floor_name(cell, c), res)
	if not floors.is_empty():
		img.blit_rect(floors[variant_of(c, floors.size())], full, at)
	else:
		img.fill_rect(Rect2i(at, Vector2i(res, res)), Color(0.14, 0.15, 0.18))
	if cell.on_fire:
		var fire := _tile("fire", res)
		if not fire.is_empty():
			img.blend_rect(fire[0], full, at)
	var fid := cell.feature_id
	# Бункер вырыт в скале (item 24): стена, со всех восьми сторон окружённая стеной (или
	# краем карты), — толща породы, а не обшивка; металлом облицованы только стены комнат.
	if fid == MCF.FEATURE_WALL and env == "bunker" and _buried(c):
		var rock := _tile("bedrock", res)
		if not rock.is_empty():
			feat.blit_rect(rock[variant_of(c, rock.size())], full, at)
			return
	# Станция дронов — как мина: в плитки НЕ запекается, потому что видимость у неё своя
	# у каждой стороны (туман). Её рисует поклеточный проход экрана боя.
	if fid == "" or fid == MCF.FEATURE_MINE or fid == MCF.FEATURE_AV_MINE \
			or fid == MCF.FEATURE_DRONE_STATION or skip_features.has(fid):
		return
	var name := tile_name(cell)
	var sheets := _sheet(name, res)
	if not sheets.is_empty():
		var mask := mask_at(_grid, c, fid)
		feat.blit_rect(sheets[variant_of(c, sheets.size())],
				Rect2i((mask % 4) * res, (mask / 4) * res, res, res), at)
	else:
		var singles := _tile(name, res)
		if not singles.is_empty():
			feat.blit_rect(singles[variant_of(c, singles.size())], full, at)
	if cell.airlock_welded:
		feat.blend_rect(_weld_overlay(res), full, at)

## Заваренный шлюз: поверх створок — крест из стальных полос с оранжевыми швами по
## концам и посередине. Рисуется кодом, в res×res, один раз на разрешение.
func _weld_overlay(res: int) -> Image:
	var key := "weld@%d" % res
	if _tiles.has(key):
		return _tiles[key][0]
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var w := maxi(1, res / 8)
	var steel := Color(0.36, 0.37, 0.40)
	var edge := Color(0.62, 0.63, 0.66)
	var bead := Color(1.0, 0.58, 0.16)
	for y in res:
		for x in res:
			var d1 := absi(x - y)
			var d2 := absi(x + y - (res - 1))
			var d := mini(d1, d2)
			if d <= w:
				img.set_pixel(x, y, edge if d == w else steel)
	# Швы: квадратики у четырёх углов и в центре креста.
	var b := maxi(1, res / 10)
	for p: Vector2i in [Vector2i(b, b), Vector2i(res - 1 - b, b), Vector2i(b, res - 1 - b),
			Vector2i(res - 1 - b, res - 1 - b), Vector2i(res / 2, res / 2)]:
		img.fill_rect(Rect2i(p - Vector2i(b, b) / 2, Vector2i(b + 1, b + 1)), bead)
	_tiles[key] = [img]
	return img

func _buried(c: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dy)
			if n.x < 0 or n.y < 0 or n.x >= _grid.width or n.y >= _grid.height:
				continue
			if _grid.cell_fast(n.x, n.y).feature_id != MCF.FEATURE_WALL:
				return false
	return true

func _floor_name(cell: GridCell, c: Vector2i) -> String:
	if cell.is_space:
		return "floor_space"
	var dmg := int(_damaged.get(c, 0))
	if dmg == FxDecals.DAMAGE_EPICENTER:
		return "floor_epicenter"
	if dmg == FxDecals.DAMAGE_RUBBLE:
		return "floor_destroyed"
	if cell.floor_type == MCF.FLOOR_GRASS:
		return "floor_grass"
	return "floor"

## Имя картинки объекта: id с учётом подмен (ЛДФ, ДПМГ) и состояния шлюза — открытый
## шлюз (высота ниже стены) рисуется разъехавшимися створками.
static func tile_name(cell: GridCell) -> String:
	var fid := cell.feature_id
	if fid == MCF.FEATURE_AIRLOCK and cell.cover_height < MCF.WALL_HEIGHT:
		return "airlock_open"
	return Sprites.ALIASES.get(fid, fid)

## Маска автотайла: соседи по четырём сторонам из того же семейства (Sprites.AUTOTILE_*).
static func mask_at(grid: Grid, c: Vector2i, fid: String) -> int:
	var fam: String = FAMILY.get(fid, fid)
	var mask := 0
	var dirs := [[Vector2i(0, -1), Sprites.AUTOTILE_N], [Vector2i(1, 0), Sprites.AUTOTILE_E],
			[Vector2i(0, 1), Sprites.AUTOTILE_S], [Vector2i(-1, 0), Sprites.AUTOTILE_W]]
	for d in dirs:
		var n: Vector2i = c + d[0]
		if n.x < 0 or n.y < 0 or n.x >= grid.width or n.y >= grid.height:
			continue
		var nf := grid.cell_fast(n.x, n.y).feature_id
		if nf != "" and FAMILY.get(nf, nf) == fam:
			mask |= int(d[1])
	return mask

## Плитка объекта для отдельной отрисовки поверх куска (снимок «до взрыва» на время броска).
func draw_feature_tile(ci: CanvasItem, fid: String, c: Vector2i, rect: Rect2) -> void:
	var name: String = env_name(Sprites.ALIASES.get(fid, fid), env)
	var sheet := Sprites.texture_of(name + Sprites.AUTOTILE_SUFFIX)
	if sheet != null:
		Sprites.draw_autotile(ci, sheet, rect, mask_at(_grid, c, fid), variant_of(c, 64))
	else:
		Sprites.draw_tile(ci, name, rect, variant_of(c, 64))

## Слой для экранов без своего (расстановка): рисует куски под родителем (show_behind_parent).
## Родитель задаёт position/scale своей панорамой и видимые клетки.
class Layer extends Node2D:
	var tiles: TerrainTiles = null
	var cells := Rect2i()
	var origin := Vector2.ZERO
	var cell_size := 40.0
	func _init() -> void:
		show_behind_parent = true
	func _draw() -> void:
		if tiles == null:
			return
		var res := TerrainTiles.prepare(self, cell_size)
		for features in [false, true]:
			tiles.draw(self, origin, cell_size, cells.position.x, cells.position.y,
					cells.end.x, cells.end.y, features, res)

## Разрешение кусков и фильтрация для слоя ci (его scale — зум панорамы): по тому, сколько
## точек экрана приходится на клетку. Ужатая плитка сглаживается, растянутая — нет.
static func prepare(ci: CanvasItem, cell_size: float) -> int:
	var px := cell_size * ci.get_global_transform_with_canvas().get_scale().x \
			* ci.get_viewport().get_final_transform().get_scale().x
	var res := res_for(px)
	ci.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if px >= float(res) \
			else CanvasItem.TEXTURE_FILTER_LINEAR
	return res
