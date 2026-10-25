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
## The first-person floor (fix-8): 32 px a cell like the sharpest bake, but floor only —
## no objects layer, and neither wall chunks nor knocked items, which lie there in 3D.
const FP_RES := -32
const ALL_RES := [8, 16, 32, FP_RES]
## Сколько кусков собирать за кадр, когда есть чем подменить недостающие.
const BUILDS_PER_FRAME := 1
## Потолок памяти под текстуры кусков; сверх него выбрасываются давно не показанные.
const MEMORY_BUDGET := 128 * 1024 * 1024

## Семейства автотайла: плитки одного семейства стыкуются друг с другом, так что стена
## переходит в окно или шлюз без шва.
const FAMILY := {
	"wall": "wall", "wood_wall": "wall", "glass": "wall", "armor_wall": "wall",
	"armor_glass": "wall", "dot": "wall", "dot_open": "wall", "bru": "wall",
	"airlock": "wall", "corpse_wall": "wall", "soil": "wall",
	# Граница мира (0.9.3): в бункере она — тот же грунт, и стыковаться должна с ним.
	# В прочих окружениях плитки у неё нет и семейство ни на что не влияет.
	"boundary": "wall",
	"sandbags": "bags", "sandbag_wall": "bags", "hedgehog_sandbags": "bags", "rsp": "bags",
	"trench": "trench", "dirt_pile": "dirt",
}

var _grid: Grid
## Окружение карты (item 24): плитка «<имя>_<окружение>» важнее общей.
var env: String = ""
var _floor_only := false        # baking an FP_RES chunk right now
var _chunks: Dictionary = {}     # Vector3i(cx, cy, res) -> {"floor", "feat": ImageTexture, "used": int, "bytes": int}
var _generation := 0            # invalidates in-progress first-person bakes after a full reset
var _dirty: Dictionary = {}      # Vector2i(cx, cy) -> true: пересобрать во всех разрешениях
var _pick: Dictionary = {}       # Vector2i(cx, cy) -> ключ куска, выведенного полом в этом кадре
var _bytes := 0
var _built := 0
var _deferred_rebuild := false
var _look_ver: int = -1
var _damage_ver: int = -1
var _damaged: Dictionary = {}
## Осевшая косметика по кускам (FxDecals.by_chunk) — кровь, гильзы, осколки, впечатанные
## в пол куска (0.9.3). Пусто — слоя нет (редактор, расстановка до боя).
var decals: Dictionary = {}
var map_decals: Dictionary = {}
var bake_map_decals := false
var bake_fire := true
var _map_decal_bleed := 1.5
var ground_lines: Dictionary = {}
var _ground_version := -1
var _decal_index: Dictionary = {}
var _decal_reset: int = -1
var _frame: int = 0
## Варианты плиток: "имя@res" -> Array[Image] (res×res); листы: "имя@res" -> Array[Image]
## (4res×4res). Пустой массив — картинки нет.
var _tiles: Dictionary = {}
var _source_images: Dictionary = {}
var _sheets: Dictionary = {}

## Где клетка (0,0) этой сетки лежит на настоящей карте. Не ноль только у черновика
## (scratch): хеши вариантов плиток и поворотов считаются от настоящих клеток, и
## предпросмотр выбирает ту же картинку, что ляжет на карту.
var origin := Vector2i.ZERO

## Мебель в бою заново НЕ срастается (просьба игрока): вид каждой клетки — стык, внутренние
## углы и поворот — снимается с доски один раз за партию (freeze_furniture), и дальше
## клетка рисуется так, как её собрали генератор или редактор, что бы ни стало с соседями:
## полкровати под гусеницами так и остаётся половиной, ряд стойки с выбитой секцией — двумя
## обрубками, а снесённая стена не разворачивает шкаф. Предмет, которого в снимке нет
## (приволокли, поставили), стоит сам по себе и запоминает вид, с которым лёг. null —
## снимка нет: редактор и расстановка срастаются вживую. Словарь общий у всех плиток
## партии (Main пересоздаёт их при смене доски и тумана), поэтому ни пересинхронизация, ни
## перемотка повтора вид не сбрасывают.
var furniture_look: Variant = null   # Vector2i -> [fid, mask, inner, k]

func _init(grid: Grid, p_env: String = "") -> void:
	_grid = grid
	env = p_env
	_look_ver = GridCell.look_version
	set_map_decals()

## Плитки для сетки-черновика grid (предпросмотр редактора), чья клетка (0,0) лежит на
## карте в at: те же кэши картинок, что у этих плиток, — ничего не грузится заново.
func scratch(grid: Grid, at: Vector2i) -> TerrainTiles:
	var t := TerrainTiles.new(grid, env)
	t._tiles = _tiles
	t._sheets = _sheets
	t.origin = at
	return t

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
	var key := "%s@%d%s" % [name, res, "fp" if _floor_only else ""]
	if _tiles.has(key):
		return _tiles[key]
	var out: Array = []
	# First person lays its own realistic floors (textures/first_person/floors/fp_*), unless
	# the player replaced that floor with their own picture.
	var own := env_name(name, env)
	var img := _load("fp_" + own) if _floor_only and not Sprites.has_user_override(own) else null
	if img == null:
		img = _load(env_name(name, env))
	if img == null:
		img = _atlas_part(name, Sprites.ATLAS_TURN_ROW, 1, 1)   # атлас: первый поворот
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
	if img == null:
		img = _atlas_part(name, 0, 4, 4)   # атлас (0.9.4): первые четыре строки — тот же лист
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

## Кусок атласа объекта (0.9.4): cols×rows плиток, начиная со строки row0. null — атласа
## нет. Атлас — один файл на объект: строки 0..3 — автотайл, строка 4 — четыре поворота
## (см. Sprites.ATLAS_SUFFIX). Сторона плитки берётся из самого файла, поэтому атлас может
## быть нарисован в любом разрешении — лишь бы он был 4 плитки в ширину.
func _atlas_part(name: String, row0: int, rows: int, cols: int) -> Image:
	var img := _load(env_name(name, env) + Sprites.ATLAS_SUFFIX)
	if img == null:
		return null
	var t := img.get_width() / 4
	if t <= 0 or img.get_height() < (row0 + rows) * t:
		return null
	return img.get_region(Rect2i(0, row0 * t, cols * t, rows * t))

func _load(name: String) -> Image:
	var tex := Sprites.texture_of(name)
	if tex == null:
		return null
	var cached: Array = _source_images.get(name, [])
	if not cached.is_empty() and cached[0] == tex:
		return (cached[1] as Image).duplicate()
	var img := tex.get_image()
	if img == null:
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	_source_images[name] = [tex, img]
	return img.duplicate()

## Подтянуть журнал вида и копоть взрывов: пометить грязными куски тронутых клеток и
## их соседей.
## Подтянуть осевшую косметику (0.9.3): куски, где она прибавилась, — пересобрать; если
## её откуда-то УБРАЛИ (пожар, потолок, загрузка), выбросить все куски разом.
func sync_decals(fx: FxDecals) -> void:
	decals = fx.by_chunk
	if _ground_version != fx.ground_version:
		_ground_version = fx.ground_version
		_index_ground_lines(fx)
	if _decal_reset != fx.decal_reset:
		_decal_reset = fx.decal_reset
		# A tank sweeping rubble changes a few cells, not the entire board. Keep
		# valid textures and invalidate only changed buckets (including edge bleed).
		var chunks := _decal_index.duplicate()
		chunks.merge(decals)
		for cc: Vector2i in chunks:
			if _decal_index.get(cc, []) == decals.get(cc, []): continue
			for dy in range(-1, 2):
				for dx in range(-1, 2): _dirty[cc + Vector2i(dx, dy)] = true
		_decal_index = decals.duplicate()
	if fx.decal_dirty.is_empty():
		return
	for cc: Vector2i in fx.decal_dirty:
		_dirty[cc] = true
	_decal_index = decals.duplicate()
	fx.decal_dirty.clear()

func sync(fx_damage: Dictionary, damage_version: int) -> void:
	if _look_ver < GridCell.look_log_base:
		_generation += 1
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
			if not fx_damage.has(c): _touch(c)
		for c: Vector2i in fx_damage:
			if _damaged.get(c) != fx_damage[c]: _touch(c)
		_damaged = fx_damage.duplicate()
		_damage_ver = damage_version

## Клетки, чей огонь пока не рисуется (0.12.1): струя огнемёта до них ещё не добежала.
var hidden_fire: Dictionary = {}

func hide_fire(c: Vector2i, hide: bool) -> void:
	if hide: hidden_fire[c] = true
	else: hidden_fire.erase(c)
	_touch(c)

func _touch(c: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dy)
			if n.x < 0 or n.y < 0 or n.x >= _grid.width or n.y >= _grid.height:
				continue
			_dirty[Vector2i(n.x / C, n.y / C)] = true
			# Поворот цельного предмета зависит от всех его клеток: перемена у одной (или
			# стена, снесённая у её бока) перерисовывает весь предмет, а не кусок с краю.
			# В бою вид заморожен (furniture_look) — соседям перерисовываться не с чего.
			# Ряд с поворотами (Г-стойка) тоже решает спинку по всем клеткам (_path_look).
			var nf := _grid.cell_fast(n.x, n.y).feature_id
			if furniture_look == null and Furniture.joins(nf):
				for p in group_cells(_grid, n, nf):
					_dirty[Vector2i(p.x / C, p.y / C)] = true

## Вывести куски слоя features=false (пол) или true (объекты), покрывающие клетки
## [x0..x1]×[y0..y1]; origin — угол доски, cell — размер клетки на холсте, res — нужное
## разрешение (res_for). Недостающие куски собираются при выводе пола; слой объектов
## выводит ровно те куски, что выбрал для этого кадра пол.
func draw(ci: CanvasItem, origin: Vector2, cell: float, x0: int, y0: int, x1: int, y1: int,
		features: bool, res: int = 32) -> void:
	if not features:
		_frame += 1
		_built = 0
		_deferred_rebuild = false
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
	if not features:
		draw_map_decals(ci, origin, cell, Rect2(Vector2(x0, y0), Vector2(x1 - x0 + 1, y1 - y0 + 1)))
	if not features and _deferred_rebuild:
		ci.queue_redraw.call_deferred()
	if features:
		_evict()

## Authored decals retain their floating-point position at every zoom level.
## Draw between floor and features so newly built walls cover them.
func draw_map_decals(ci: CanvasItem, origin: Vector2, cell: float, view: Rect2) -> void:
	for cy in range(floori((view.position.y - _map_decal_bleed) / C), floori((view.end.y + _map_decal_bleed) / C) + 1):
		for cx in range(floori((view.position.x - _map_decal_bleed) / C), floori((view.end.x + _map_decal_bleed) / C) + 1):
			for d: Dictionary in map_decals.get(Vector2i(cx, cy), []):
				var pos: Vector2 = d["pos"]
				if view.grow(_map_decal_bleed).has_point(pos):
					draw_decal(ci, str(d["kind"]), origin + pos * cell, cell * float(d["scale"]), float(d["rot"]))

static func draw_decal(ci: CanvasItem, kind: String, pos: Vector2, size: float, rot: float, alpha := 1.0) -> void:
	var art := "corpse" if kind == "corpse" else (FxDecals.texture_of_kind(kind) if kind.begins_with("item:") \
			else str(FxDecals.TEXTURE.get(kind, "")))
	if kind in MapData.WINTER_DECORATIONS:
		art = kind
	if kind == "corpse" and not Sprites.has_override(art):
		art = Sprites.resolve("light_infantry", "_neutral")
	var tex := Sprites.texture_of(art) if art != "" else null
	if kind == "corpse" and tex == null:
		ci.draw_circle(pos, size * 0.34, Color(0.55, 0.14, 0.14, alpha * 0.7), true, -1.0, true)
		var arm := Vector2(size * 0.18, 0).rotated(rot)
		ci.draw_line(pos - arm, pos + arm, Color(0.18, 0.05, 0.05, alpha), maxf(1.0, size * 0.06), true)
		return
	var look: Array = FxDecals.look_of(kind)
	if look.is_empty():
		look = [0.95, Color.WHITE]
	size *= float(look[0])
	if tex == null:
		var color: Color = look[1]
		color.a *= alpha
		ci.draw_circle(pos, size * 0.5, color, true, -1.0, true)
		return
	var points := PackedVector2Array()
	var uv := PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN])
	for p: Vector2 in uv:
		points.append(pos + ((p - Vector2.ONE * 0.5) * size).rotated(rot))
	ci.draw_polygon(points, PackedColorArray([Color(1, 1, 1, alpha)]), uv, tex)

## Точка пятна копоти (0.12.1) в долях половины его размера. Край у каждого вида свой —
## волнистый по углу, — к середине гуще, плюс редкая крупка; поэтому пятна не одинаковы.
static func _soot_pixel(q: Vector2, variant: int, col: Color) -> Color:
	var ang := q.angle()
	var edge := 0.72 + 0.16 * sin(ang * 3.0 + variant * 1.7) + 0.09 * sin(ang * 7.0 + variant * 4.1) \
			+ 0.05 * sin(ang * 13.0 + variant * 2.3)
	var r := q.length() / edge
	if r >= 1.0:
		return Color(0, 0, 0, 0)
	var grain := fposmod(sin(q.x * 91.7 + q.y * 47.3 + variant * 13.1) * 43758.5, 1.0)
	var a := pow(1.0 - r, 0.8) * col.a * (0.75 + 0.35 * grain)
	return Color(col.r, col.g, col.b, clampf(a, 0.0, 1.0))

## Какой кусок вывести: в нужном разрешении (собрав его, если бюджет кадра позволяет), а
## иначе — уже собранный в другом. Грязный кусок выбрасывается во всех разрешениях.
func _choose(cc: Vector2i, res: int) -> Variant:
	var key := Vector3i(cc.x, cc.y, res)
	var fallback: Variant = key if _chunks.has(key) else null
	if fallback == null:
		for r: int in RES:
			if _chunks.has(Vector3i(cc.x, cc.y, r)):
				fallback = Vector3i(cc.x, cc.y, r)
	# Keep a valid previous texture until this chunk gets its frame budget. Previously
	# dirty chunks were discarded first, so the budget never applied to explosions.
	if fallback != null and _built >= BUILDS_PER_FRAME and (_dirty.has(cc) or not _chunks.has(key)):
		_deferred_rebuild = true
		_pick[cc] = fallback
		return fallback
	if _dirty.has(cc):
		_dirty.erase(cc)
		for r: int in ALL_RES: _drop(Vector3i(cc.x, cc.y, r))
	if not _chunks.has(key):
		_build(cc, res)
		_built += 1
	_pick[cc] = key
	return key

## The first-person floor of chunk cc (FP_RES), baked now if it is missing or dirty.
func floor_3d(cc: Vector2i) -> ImageTexture:
	if _dirty.has(cc):
		_dirty.erase(cc)
		for r: int in ALL_RES: _drop(Vector3i(cc.x, cc.y, r))
	var key := Vector3i(cc.x, cc.y, FP_RES)
	if not _chunks.has(key):
		_build(cc, FP_RES)
	_chunks[key]["used"] = _frame
	return _chunks[key]["floor"]

## First-person streaming prepares a complete replacement over several frames.
## The old texture remains displayed until every cell and decal is ready.
func begin_floor_job(cc: Vector2i) -> Dictionary:
	if _dirty.has(cc):
		_dirty.erase(cc)
		for r: int in ALL_RES: _drop(Vector3i(cc.x, cc.y, r))
	var w := mini(C, _grid.width - cc.x * C)
	var h := mini(C, _grid.height - cc.y * C)
	_floor_only = true
	var marks := _decal_list(cc)
	var job := {"cc": cc, "source": self, "generation": _generation, "size": Vector2i(w, h), "next": 0, "phase": 0, "decals": marks,
		"floor": Image.create(w * 32, h * 32, false, Image.FORMAT_RGBA8),
		"features": Image.create(w * 32, h * 32, false, Image.FORMAT_RGBA8)}
	var plan := _native_floor_plan(cc, Vector2i(w, h))
	if not plan.is_empty(): job["native_plan"] = plan; job["native_tiles"] = _native_floor_images(plan, 32)
	_floor_only = false
	return job

func advance_floor_job(job: Dictionary, deadline: int) -> bool:
	var cc: Vector2i = job.cc
	var size: Vector2i = job.size
	var picture: Image = job.floor
	_floor_only = true
	while Time.get_ticks_usec() < deadline:
		var i: int = job.next
		match int(job.phase):
			0:
				if i == size.x * size.y:
					_bake_ground_lines(picture, cc, 32)
					job.phase = 1; job.next = 0
					continue
				if job.has("native_plan"):
					var native := NativeKernels.terrain()
					var count := mini(size.x, size.x * size.y - i)
					if native != null and native.paint_floor(picture, job.native_plan, job.native_tiles, i, count, 32):
						job.next += count
						continue
					job.erase("native_plan")
				var offset := Vector2i(i % size.x, i / size.x)
				_paint(picture, job.features, cc * C + offset, offset * 32, 32)
			1:
				if i == job.decals.size():
					job.phase = 2; job.next = 0
					continue
				_paint_decal(picture, cc, 32, job.decals[i])
			2:
				if not bake_fire or i == size.x * size.y:
					picture.generate_mipmaps()
					var bytes := picture.get_data_size()
					var key := Vector3i(cc.x, cc.y, FP_RES)
					_drop(key)
					_chunks[key] = {"floor": ImageTexture.create_from_image(picture), "feat": null, "used": _frame, "bytes": bytes}
					_bytes += bytes
					_floor_only = false
					return true
				var cell := cc * C + Vector2i(i % size.x, i / size.x)
				if _grid.cell(cell).on_fire and not hidden_fire.has(cell):
					var fire := _tile("fire", 32)
					if not fire.is_empty(): picture.blend_rect(fire[0], Rect2i(0, 0, 32, 32), (cell - cc * C) * 32)
		job.next += 1
	_floor_only = false
	return false

## The native plan classifies a complete chunk once, then paints bounded rows while
## the existing streaming job checks its deadline. Texture loading stays on this side.
func _native_floor_plan(cc: Vector2i, size: Vector2i) -> Dictionary:
	var native := NativeKernels.terrain()
	if native == null: return {}
	var ground_names := {}
	var winter_names := {}
	var names: Array = MCF.FLOOR_LOOKS.duplicate()
	names.append_array(["floor", "floor_space", "floor_epicenter", "floor_destroyed"])
	for name: String in names:
		var actual := env_name(name, env) if name != "" else ""
		ground_names[name] = actual
		winter_names[name] = str(WINTER_FLOORS.get(actual, name)) if winter and name != "" else name
	return native.floor_plan(_grid.cells_flat(), _grid.width, _grid.height, _grid.floor_look, _damaged,
		Rect2i(cc * C, size), origin, {"floor_names": MCF.FLOOR_LOOKS, "overlays": MCF.FLOOR_OVERLAY_LOOKS,
		"env": env, "airlock": MCF.FEATURE_AIRLOCK, "space_override": Sprites.has_user_override("floor_space"),
		"solar": MCF.Look.SOLAR, "grass_look": MCF.Look.GRASS, "dirt_look": MCF.Look.DIRT,
		"grass_type": MCF.FLOOR_GRASS, "epicenter": FxDecals.DAMAGE_EPICENTER, "rubble": FxDecals.DAMAGE_RUBBLE,
		"ground_names": ground_names, "winter_names": winter_names})

func _native_floor_images(plan: Dictionary, res: int) -> Dictionary:
	var images := {}
	for name: String in plan.needed: images[name] = _tile(name, res)
	return images

func _native_paint_floor(img: Image, cc: Vector2i, size: Vector2i, res: int) -> bool:
	var native := NativeKernels.terrain()
	if native == null: return false
	var plan := _native_floor_plan(cc, size)
	return not plan.is_empty() and native.paint_floor(img, plan, _native_floor_images(plan, res), 0, size.x * size.y, res)

func _drop(key: Vector3i) -> void:
	if _chunks.has(key):
		_bytes -= int(_chunks[key]["bytes"])
		_chunks.erase(key)

func _build(cc: Vector2i, res: int) -> void:
	var key := Vector3i(cc.x, cc.y, res)
	_floor_only = res == FP_RES
	if _floor_only:
		res = 32
	var w := mini(C, _grid.width - cc.x * C)
	var h := mini(C, _grid.height - cc.y * C)
	var floor_img := Image.create(w * res, h * res, false, Image.FORMAT_RGBA8)
	var feat_img := Image.create(w * res, h * res, false, Image.FORMAT_RGBA8)
	if not _floor_only or not _native_paint_floor(floor_img, cc, Vector2i(w, h), res):
		for y in h:
			for x in w:
				_paint(floor_img, feat_img, Vector2i(cc.x * C + x, cc.y * C + y),
						Vector2i(x * res, y * res), res)
	_bake_ground_lines(floor_img, cc, res)
	_bake_decals(floor_img, cc, res)
	# Flames over the debris, blood and brass lying in them (playtest 2026-10-19).
	if bake_fire:
		var fire := _tile("fire", res)
		if not fire.is_empty():
			for y in h:
				for x in w:
					var fc := Vector2i(cc.x * C + x, cc.y * C + y)
					if _grid.cell_fast(fc.x, fc.y).on_fire and not hidden_fire.has(fc):
						floor_img.blend_rect(fire[0], Rect2i(0, 0, res, res), Vector2i(x * res, y * res))
	if _floor_only:
		_floor_only = false
		floor_img.generate_mipmaps()
		var fbytes := floor_img.get_data_size()
		_chunks[key] = {"floor": ImageTexture.create_from_image(floor_img), "feat": null, "used": _frame, "bytes": fbytes}
		_bytes += fbytes
		return
	_bake_items(feat_img, cc, res)
	var bytes := w * h * res * res * 4 * 2
	_chunks[key] = {"floor": ImageTexture.create_from_image(floor_img),
			"feat": ImageTexture.create_from_image(feat_img), "used": _frame, "bytes": bytes}
	_bytes += bytes


# =====================================================================================
#  Осевшая косметика, впечатанная в пол (0.9.3)
# =====================================================================================
## Кровь, гильзы и осколки ни с чем не взаимодействуют и никуда не исчезают — значит им
## не место в поклеточном проходе экрана. Здесь они ложатся в картинку куска ОДИН раз, при
## его сборке, и кадр о них больше не знает. До этого экран боя шёл по всему списку каждый
## кадр: к середине партии там десятки тысяч словарей, и на каждый — обращения по ключам,
## проверка тумана и отдельный примитив; лужа и отпечаток к тому же сбивали пакетную
## отрисовку своим draw_set_transform.
##
## Раз косметика стала частью картинки доски, туман прячет её ровно так же, как рельеф под
## ней: увиденная кровь остаётся на запомненной клетке. Это та же договорённость, по
## которой уже живут стены и мебель.
## Насколько далеко частица может вылезти за свою клетку: самая крупная — лужа (0.95
## клетки) с запасом на масштаб. Ради неё куску приходится смотреть и в СОСЕДНИЕ куски:
## лужа у самой границы иначе обрезалась бы ровно по шву, и доска шла бы в клетку через
## каждые 16 клеток.
const DECAL_BLEED := 1.5

func _decal_list(cc: Vector2i) -> Array:
	var origin := Vector2(cc * C)
	var list: Array = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var chunk := cc + Vector2i(dx, dy)
			var near: Array = decals.get(chunk, []).duplicate()
			if bake_map_decals or _floor_only:
				near.append_array(map_decals.get(chunk, []))
			if near == null:
				continue
			if dx == 0 and dy == 0:
				list.append_array(near as Array)
				continue
			# От соседа берём только то, что и правда дотягивается до этого куска.
			for d: Dictionary in near:
				var p: Vector2 = (d["pos"] as Vector2) - origin
				if p.x > -DECAL_BLEED and p.y > -DECAL_BLEED \
						and p.x < C + DECAL_BLEED and p.y < C + DECAL_BLEED:
					list.append(d)
	return list

func _bake_decals(img: Image, cc: Vector2i, res: int) -> void:
	for decal: Dictionary in _decal_list(cc): _paint_decal(img, cc, res, decal)

func _paint_decal(img: Image, cc: Vector2i, res: int, d: Dictionary) -> void:
	var origin := Vector2(cc * C)
	var kind := str(d["kind"])
	if _floor_only and (kind.begins_with("chunk:") or kind.begins_with("item:") or kind in MapData.WINTER_DECORATIONS):
		return
	var look: Array = [0.95, Color(0.8, 0.1, 0.1, 0.5)] if kind == "corpse" else FxDecals.look_of(kind)
	if look.is_empty():
		return
	var pos: Vector2 = (d["pos"] as Vector2) - origin
	# Частица не оседает на стене (экран её и не рисовал): клетку-стену пропускаем.
	var cell := Vector2i(cc * C) + Vector2i(floori(pos.x), floori(pos.y))
	if not _grid.in_bounds(cell) or _grid.cell_fast(cell.x, cell.y).cover_height >= MCF.WALL_HEIGHT:
		return
	var px := maxi(1, roundi(float(look[0]) * float(d["scale"]) * res))
	var sprite := _decal_sprite(kind, px, float(d["rot"]), look)
	if sprite == null:
		return
	var at := Vector2i(roundi(pos.x * res) - px / 2, roundi(pos.y * res) - px / 2)
	img.blend_rect(sprite, Rect2i(0, 0, px, px), at)

# =====================================================================================
#  Мелкие предметы карты (0.12.1, SmallItems)
# =====================================================================================
## Стоящие предметы лежат в слое объектов, ПОВЕРХ мебели (кружка на столе, а не под ним),
## и впекаются в картинку куска при его сборке, как осевшая косметика в пол. Сбитые (бит в
## GridCell.items_off) пропускаются; правка бита — правка вида клетки, и кусок пересобирается
## сам. Список карты в бою не меняется, поэтому указатель по кускам строится один раз.
var _items_chunks: Dictionary = {}   # Vector2i кусок -> номера предметов в _grid.map_items
var _items_of: Array = []

func _index_items() -> void:
	if is_same(_items_of, _grid.map_items) and _items_of.size() == _grid.map_items.size():
		return
	_items_chunks.clear()
	for i in _grid.map_items.size():
		var cc := SmallItems.cell_of(_grid.map_items[i]) / C
		if not _items_chunks.has(cc): _items_chunks[cc] = []
		(_items_chunks[cc] as Array).append(i)
	_items_of = _grid.map_items

## Редактор поменял список предметов: пересобрать указатель и куски, где они были и стали.
func set_map_items(before: Array = []) -> void:
	for it: Array in before + _grid.map_items:
		_dirty[SmallItems.cell_of(it) / C] = true
		for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			_dirty[(SmallItems.cell_of(it) + d) / C] = true
	_items_of = []

func _bake_items(img: Image, cc: Vector2i, res: int) -> void:
	if _grid.map_items.is_empty():
		return
	_index_items()
	var origin := Vector2(cc * C)
	var px := maxi(2, roundi(SmallItems.DRAW_SCALE * res))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for i: int in _items_chunks.get(cc + Vector2i(dx, dy), []):
				var it: Array = _grid.map_items[i]
				var pos := Vector2(float(it[1]), float(it[2])) - origin
				if pos.x < -1.0 or pos.y < -1.0 or pos.x > C + 1.0 or pos.y > C + 1.0:
					continue
				var cell := SmallItems.cell_of(it)
				if not _grid.in_bounds(cell):
					continue
				var gc := _grid.cell_fast(cell.x, cell.y)
				if gc.items_off != 0 and (gc.items_off & _grid.item_bit(i)) != 0:
					continue
				if gc.cover_height >= MCF.WALL_HEIGHT and not Furniture.is_furniture(gc.feature_id):
					continue   # в стену предмет не впекается
				var sprite := _decal_sprite("item:" + str(it[0]), px, float(it[3]), [SmallItems.DRAW_SCALE, Color.WHITE])
				if sprite != null:
					img.blend_rect(sprite, Rect2i(0, 0, px, px),
							Vector2i(roundi(pos.x * res) - px / 2, roundi(pos.y * res) - px / 2))

## Картинка одной частицы размером px и под своим углом. Углов берём ANGLES штук: на
## четырёх-одиннадцати точках разницы между соседними уже не видно, а кэш не разрастается.
## Своя картинка игрока (glass_shard, blood_pool…) берётся как есть; без неё частица
## рисуется тем же, чем её рисовал экран: лужа — сплющенным кругом, прочее — четырёхугольником.
const DECAL_ANGLES := 8

## Мелкий предмет («item:<вид>», 0.12.1) — своей картинкой и с шагом угла мельче: его кладут
## под любым углом, и восемь положений на нём видны.
const ITEM_ANGLES := 32
const CHUNK_ANGLES := 16   # обломки (0.12.2): острые формы, восьми поворотов на них мало

func _decal_sprite(kind: String, px: int, rot: float, look: Array) -> Image:
	var item := kind.begins_with("item:")
	var angles := ITEM_ANGLES if item else (CHUNK_ANGLES if kind.begins_with("chunk:") else DECAL_ANGLES)
	var step := posmod(roundi(rot / TAU * angles), angles)
	var key := "decal@%s@%d@%d" % [kind, px, step]
	if _tiles.has(key):
		var hit: Array = _tiles[key]
		return hit[0] if not hit.is_empty() else null
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var a := float(step) / angles * TAU
	var chunk := kind.begins_with("chunk:")
	var soot := kind.begins_with("soot:")
	var art := "corpse" if kind == "corpse" else str(FxDecals.TEXTURE.get(kind, ""))
	if kind in MapData.WINTER_DECORATIONS:
		art = kind
	var shape: PackedVector2Array = PackedVector2Array()
	if chunk:
		var parts := FxDecals.chunk_parts(kind)
		art = parts[0]
		shape = PackedVector2Array(FxDecals.CHUNK_SHAPES[int(parts[1])])
	elif item:
		art = SmallItems.texture_name(kind.substr(5))
	if kind == "corpse" and not Sprites.has_override(art):
		art = Sprites.resolve("light_infantry", "_neutral")
	var src := _load(art) if art != "" else null
	var half := px * 0.5
	var col: Color = look[1]
	var variant := int(kind.substr(5)) if soot else 0
	for y in px:
		for x in px:
			# Точка картинки — в системе самой частицы: поворачиваем назад.
			var v := Vector2(x + 0.5 - half, y + 0.5 - half).rotated(-a)
			var c := Color(0, 0, 0, 0)
			if soot:
				c = _soot_pixel(v / half, variant, col)
			elif chunk:
				# Обломок: середина плитки стены, вырезанная острым многоугольником своей формы
				# (0.12.2), с тёмной кромкой по краю — так он читается гранёным, а не пятном.
				var q := v / half
				if Geometry2D.is_point_in_polygon(q, shape):
					# Картинка стены — лента вариантов (по плитке в высоту): середина первой.
					var side := src.get_height() if src != null else 1
					c = col if src == null else src.get_pixel(
							clampi(int((q.x * 0.2 + 0.5) * side), 0, side - 1),
							clampi(int((q.y * 0.2 + 0.5) * side), 0, side - 1))
					var step_q := 2.0 / maxf(1.0, float(px))
					for d: Vector2 in [Vector2(step_q, 0), Vector2(-step_q, 0), Vector2(0, step_q), Vector2(0, -step_q)]:
						if not Geometry2D.is_point_in_polygon(q + d.rotated(-a), shape):
							c = c.darkened(0.35)
							break
			elif src != null:
				var sx := int((v.x / px + 0.5) * src.get_width())
				var sy := int((v.y / px + 0.5) * src.get_height())
				if sx >= 0 and sy >= 0 and sx < src.get_width() and sy < src.get_height():
					c = src.get_pixel(sx, sy)
			elif kind == "corpse":
				if v.length() <= half * 0.72: c = col
			elif kind == "blood_pool":
				if Vector2(v.x, v.y / 0.62).length() <= half:
					c = col
			elif absf(v.x) <= half and absf(v.y) <= half * 0.45:
				c = col
			if c.a > 0.0:
				img.set_pixel(x, y, c)
	_tiles[key] = [img]
	return img

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
	_paint_terrain(img, feat, c, at, res)
	if _floor_only:
		return
	# Each wall lamp hangs on the half of the wall tile facing its own side (0.11).
	for lamp: Array in _grid.cell_fast(c.x, c.y).lamps:
		var id := str(lamp[0])
		var tiles := _tile(id, res)
		if tiles.is_empty(): continue
		var side := int(lamp[2])
		var picture: Image = tiles[0].duplicate()
		for k in side: picture.rotate_90(CLOCKWISE)
		if Furniture.tint_colour(int(lamp[3])) > 0: picture = tint_lamp(picture, Furniture.light_color_of(id, int(lamp[3])), Furniture.base_light_color(id))
		feat.blend_rect(picture, Rect2i(0, 0, res, res), at)
		if int(lamp[1]) < Furniture.durability_of(id):
			var half: Rect2i = [Rect2i(0, 0, res, res / 2), Rect2i(res / 2, 0, res - res / 2, res),
					Rect2i(0, res / 2, res, res - res / 2), Rect2i(0, 0, res / 2, res)][side]
			feat.blend_rect(_crack_overlay(res), half, at + half.position)

func _paint_terrain(img: Image, feat: Image, c: Vector2i, at: Vector2i, res: int) -> void:
	var cell := _grid.cell_fast(c.x, c.y)
	var full := Rect2i(0, 0, res, res)
	var fname := _floor_name(cell, c)
	if _floor_only and ground_kind(c) != 0:
		fname = ""   # the first-person view lays its own seamless turf or earth there
	fname = _winter_floor(fname)
	var floors := _tile(fname, res) if fname != "" else []
	if not floors.is_empty():
		img.blit_rect(floors[variant_of(c + origin, floors.size())], full, at)
	elif fname != "":
		img.fill_rect(Rect2i(at, Vector2i(res, res)), Color(0.14, 0.15, 0.18))
	# Пустое имя — у клетки нет пола вовсе (космос, 0.9.3): она остаётся прозрачной, и
	# сквозь неё виден параллакс звёзд за доской (Starfield). Прежде там лежала плитка
	# floor_space — звёздное небо, нарезанное на квадраты и повторяющееся клетка в клетку.
	# Настил (решётка) — поверх всего этого: пол свой, прутья сверху, между ними насквозь.
	var over := _floor_overlay_name(cell, c)
	if over != "":
		var ov := _tile(over, res)
		if not ov.is_empty():
			img.blend_rect(ov[variant_of(c + origin, ov.size())], full, at)
	if _floor_only:
		return
	var fid := cell.feature_id
	# Бункер вырыт в скале (item 24): стена, со всех восьми сторон окружённая стеной (или
	# краем карты), — толща породы, а не обшивка; металлом облицованы только стены комнат.
	if fid == MCF.FEATURE_WALL and env == "bunker" and _buried(c):
		var rock := _tile("bedrock", res)
		if not rock.is_empty():
			feat.blit_rect(rock[variant_of(c + origin, rock.size())], full, at)
			return
	# Станция дронов — как мина: в плитки НЕ запекается, потому что видимость у неё своя
	# у каждой стороны (туман). Её рисует поклеточный проход экрана боя.
	if fid == "" or fid == MCF.FEATURE_MINE or fid == MCF.FEATURE_AV_MINE \
			or fid == MCF.FEATURE_DRONE_STATION:
		return
	# Дверь и шлюз (0.9.2) — «спереди»: плитка стены окружения по маске соседей, поверх —
	# дверь в раме, закрытая или распахнутая. Стоит так в стене любого направления.
	if fid == MCF.FEATURE_AIRLOCK:
		var dimg := _door_image(_grid, c, cell, res)
		if dimg != null:
			feat.blend_rect(dimg, full, at)
		if cell.airlock_welded:
			feat.blend_rect(_weld_overlay(res, _wooden_door(c)), full, at)
		return
	var accent := _accent_of(c)
	var name := pile_art(env) if fid == MCF.FEATURE_DIRT_PILE else tile_name(cell)
	# Материал стены (0.9.4): вид клетки может назвать кирпич, штукатурку или шлакоблок —
	# правила те же, плитка другая. Семейство автотайла остаётся «wall», поэтому дом из
	# кирпича стыкуется с бетонным соседом без шва.
	if fid == MCF.FEATURE_WALL and not _grid.floor_look.is_empty():
		var wl := MCF.wall_look_tile(_grid.look_at(c.x, c.y))
		if wl != "":
			name = wl
	if Furniture.is_furniture(fid):
		# Шкаф, который уже раскрылся и высыпал вещи (0.12.1), — своим рисунком, если он есть.
		var art := fid + "_open" if (cell.items_off & GridCell.OPENED) != 0 \
				and (Sprites.has_override(fid + "_open") or Sprites.has_override(fid + "_open" + Sprites.AUTOTILE_SUFFIX)) else ""
		var fimg := _furniture_image(c, fid, res, art)
		if fimg != null and Furniture.tint_colour(_grid.tint_at(c.x, c.y)) > 0 and Furniture.emits_light(fid):
			fimg = tint_lamp(fimg, Furniture.light_color_of(fid, _grid.tint_at(c.x, c.y)), Furniture.base_light_color(fid))
		if fimg != null:
			feat.blit_rect(fimg, full, at)
			if cell.feature_durability < Furniture.durability_of(fid):
				feat.blend_rect(_crack_overlay(res), full, at)
		return
	if fid == MCF.FEATURE_DPMG:
		var gun := _dpmg_image(dpmg_turn(_grid, c), res)
		if gun != null:
			feat.blit_rect(gun, full, at)
			return
	var sheets := _sheet(name, res)
	if not sheets.is_empty():
		var mask := mask_at(_grid, c, fid)
		feat.blit_rect(sheets[variant_of(c + origin, sheets.size())],
				Rect2i((mask % 4) * res, (mask / 4) * res, res, res), at)
		if NOTCHED.has(FAMILY.get(fid, fid)):
			_fill_notches(feat, c, fid, mask, at, res)
		# Полоса службы (0.9.3): цветная линия вдоль стены отдела.
		# ПО СТЕКЛУ ПОЛОСА НЕ ИДЁТ (0.9.4, просьба игрока): окно — это окно, а не крашеная
		# стена, и полоса на нём читалась мазком поперёк витрины. Соседи-окна её тоже не
		# продолжают (_accent_mask), поэтому у рамы полоса аккуратно обрывается.
		if accent != MCF.Accent.NONE and _takes_accent(fid):
			feat.blend_rect(_accent_overlay(accent, _accent_mask(c, accent), res), full, at)
		# ДОТ, потерявший прочность, трескается прямо в плитке (0.9.2) — раньше была лишь
		# красная чёрточка в углу клетки.
		if (fid == MCF.FEATURE_DOT or fid == MCF.FEATURE_DOT_OPEN) and cell.feature_durability > 0 \
				and cell.feature_durability < MCF.feature_durability(fid):
			# Вариант — так, чтобы соседи по ряду и столбцу всегда трескались по-разному.
			var cv := c + origin
			feat.blend_rect(_pillbox_crack(res, posmod(cv.x * 2 + cv.y, 3), fid == MCF.FEATURE_DOT_OPEN),
					full, at)
	else:
		var singles := _tile(name, res)
		if not singles.is_empty():
			feat.blit_rect(singles[variant_of(c + origin, singles.size())], full, at)
	if cell.airlock_welded:
		feat.blend_rect(_weld_overlay(res, false), full, at)

## Which way a DPMG points (owner, 2026-10-19): eighths clockwise from east, set by the
## resolver when it fires (GameActionResolver._face_dpmg); east until it first fires.
static func dpmg_turn(grid: Grid, c: Vector2i) -> int:
	var rec: Variant = grid.furniture_turn.get(c)
	return int(rec[1]) if rec is Array and str(rec[0]) == MCF.FEATURE_DPMG else 0

var _dpmg_art: Dictionary = {}   # k * 4096 + res -> Image
## The gun tile turned toward k. Pixel art does not survive a 45° rotation, so the
## sandbag ring stays as drawn and only the gun turns: its grey pixels are lifted out (the
## ring under the old barrel is patched from its mirror half), then the breech and barrel
## are drawn back along the new direction by sampling the original gun pixels in a turned
## frame, so they keep their texture and the barrel its light-dark-light profile.
## Geometry is in the art's 32-pixel space: breech 6×8 centred 2 px behind the middle,
## barrel 3 px wide running from it to 14 px out.
func _dpmg_image(k: int, res: int) -> Image:
	var key := k * 4096 + res
	if _dpmg_art.has(key):
		return _dpmg_art[key]
	var tiles := _tile("dpmg", res)
	if tiles.is_empty():
		return null
	var base: Image = tiles[0]
	var w := base.get_width()
	var h := base.get_height()
	var sc := float(w) / 32.0
	var img := base.duplicate() as Image
	for y in h:
		for x in w:
			if _dpmg_gun_px(base.get_pixel(x, y)):
				var m := base.get_pixel(w - 1 - x, y)
				img.set_pixel(x, y, Color(0, 0, 0, 0) if _dpmg_gun_px(m) else m)
	var dir := Vector2(Vector2i([1, 1, 0, -1, -1, -1, 0, 1][k % 8], [0, 1, 1, 1, 0, -1, -1, -1][k % 8])).normalized()
	var side := Vector2(-dir.y, dir.x)
	for y in h:
		for x in w:
			var v := Vector2((x + 0.5) / sc - 16.0, (y + 0.5) / sc - 16.0)
			var a := v.dot(dir)
			var b := v.dot(side)
			var src := Vector2(-1, -1)
			if absf(a + 2.0) < 3.0 and absf(b) < 4.0:
				src = Vector2(16.0 + a, 16.0 + b)      # breech
			elif a >= 1.0 and a < 14.0 and b >= -1.0 and b < 2.0:
				src = Vector2(16.0 + a, 16.0 + b)      # barrel
			if src.x < 0.0:
				continue
			var px := base.get_pixel(clampi(int(src.x * sc), 0, w - 1), clampi(int(src.y * sc), 0, h - 1))
			if _dpmg_gun_px(px):
				img.set_pixel(x, y, px)
	_dpmg_art[key] = img
	return img

static func _dpmg_gun_px(c: Color) -> bool:
	return c.a > 0.5 and c.get_luminance() < 0.4 and maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) < 0.06

## Семейства, у листа которых в углу между двумя сросшимися сторонами вырезан «внутренний
## угол» (окоп, мешки). Лист про диагональ не знает, поэтому в сплошном поле окопа или
## мешков на каждом стыке четырёх клеток светилась дырка в землю (0.9.2). Если диагональ
## тоже своя, угол заделывается телом из середины той же плитки.
const NOTCHED := {"trench": true, "bags": true}
const _CORNER_DIAG := [Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1)]


func _fill_notches(feat: Image, c: Vector2i, fid: String, mask: int, at: Vector2i, res: int) -> void:
	var fam: String = FAMILY.get(fid, fid)
	var p := maxi(2, ceili(7.0 * res / 32.0))
	var patch: Image = null
	for l in 4:
		if mask & _MASK_BITS[l] == 0 or mask & _MASK_BITS[(l + 1) % 4] == 0:
			continue
		var q: Vector2i = c + _CORNER_DIAG[l]
		if not _grid.in_bounds(q):
			continue
		var qf := _grid.cell_fast(q.x, q.y).feature_id
		if qf == "" or FAMILY.get(qf, qf) != fam:
			continue
		if patch == null:
			patch = feat.get_region(Rect2i(at + Vector2i(res / 2 - p / 2, res / 2 - p / 2), Vector2i(p, p)))
		var right := l == 0 or l == 1
		var bottom := l == 1 or l == 2
		feat.blit_rect(patch, Rect2i(Vector2i.ZERO, Vector2i(p, p)),
				at + Vector2i(res - p if right else 0, res - p if bottom else 0))

## Клетка двери целиком: стена окружения (лист «wall» по маске семейства) и дверь спереди
## поверх неё. Кэш — по маске, состоянию, варианту и разрешению.
const DOOR_MATERIALS := ["station", "town", "field", "bunker", "asteroid", "docking"]

func _door_image(grid: Grid, c: Vector2i, cell: GridCell, res: int, closed := false) -> Image:
	var mask := mask_at(grid, c, MCF.FEATURE_AIRLOCK)
	var open := cell.cover_height < MCF.WALL_HEIGHT and not closed
	# Вариант картинки — по ОДНОЙ клетке на всю створку (0.9.4): широкий шлюз обшивки
	# (2–3 клетки) и пара шлюзов, вставших рядом, обязаны выглядеть одним люком, а не
	# набором разных. Раньше вариант брался от самой клетки, и соседние створки выходили
	# из разного металла с разным рисунком.
	var anchor := _door_anchor(grid, c)
	var look := clampi(grid.door_at(c.x, c.y), 0, DOOR_MATERIALS.size() * 3)
	var v := (look - 1) % 3 if look > 0 else variant_of(anchor + origin, 3)
	var walls := _sheet("wall", res)
	var wv := variant_of(anchor + origin, walls.size()) if not walls.is_empty() else 0
	var accent := _accent_of(c)
	var key := "door@%d@%d@%s@%d@%d@%d" % [res, mask, open, v, wv, accent] + "@%d" % look
	if _tiles.has(key):
		var hit: Array = _tiles[key]
		return hit[0] if not hit.is_empty() else null
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	# An open doorway is see-through (0.11.1): no wall behind it, the cell's floor shows.
	if not walls.is_empty() and not open:
		img.blit_rect(walls[wv], Rect2i((mask % 4) * res, (mask / 4) * res, res, res), Vector2i.ZERO)
	var door_name := "door_open" if open else "door"
	if look > 0:
		door_name += "_" + DOOR_MATERIALS[(look - 1) / 3]
	var doors := _tile(door_name, res)
	if not doors.is_empty():
		img.blend_rect(doors[v % doors.size()], Rect2i(0, 0, res, res), Vector2i.ZERO)
	if accent != MCF.Accent.NONE:
		_tint_door_frame(img, accent, res)
	_tiles[key] = [img]
	return img

## Cache the anchor for the entire connected door group. A capped search picked
## different variants at opposite ends of a wide airlock.
var _door_anchors: Dictionary = {}
var _door_anchor_version := -1
var _door_anchor_grid := 0

func _door_anchor(grid: Grid, c: Vector2i) -> Vector2i:
	if _door_anchor_version != GridCell.look_version or _door_anchor_grid != grid.get_instance_id():
		_door_anchors.clear()
		_door_anchor_version = GridCell.look_version
		_door_anchor_grid = grid.get_instance_id()
	if _door_anchors.has(c): return _door_anchors[c]
	var best := c
	var seen := {c: true}
	var queue: Array[Vector2i] = [c]
	var i := 0
	while i < queue.size():
		var p := queue[i]
		i += 1
		for d: Vector2i in _TURN_DIRS:
			var q: Vector2i = p + d
			if seen.has(q) or not grid.in_bounds(q):
				continue
			if grid.cell_fast(q.x, q.y).feature_id != MCF.FEATURE_AIRLOCK:
				continue
			seen[q] = true
			queue.append(q)
			if q.y < best.y or (q.y == best.y and q.x < best.x):
				best = q
	for cell: Vector2i in queue: _door_anchors[cell] = best
	return best

## Рама двери в цвет службы (0.9.3). Красится именно РАМА — кайма клетки, — а не полотно:
## по ней дверь отдела видно и закрытой, и распахнутой, а рисунок самой двери (люк, окошко,
## штурвал) остаётся читаемым. Тон сохраняется: цвет подмешивается к пикселю, а не кладётся
## плашкой, поэтому фаска и тень на раме никуда не деваются.
const ACCENT_DOOR_MIX := 0.72

func _tint_door_frame(img: Image, accent: int, res: int) -> void:
	var col: Color = MCF.ACCENT_COLORS[accent]
	# Толщина рамы та же, что у картинки двери (gen_textures: 2 точки из 32, у тяжёлой — 3).
	var fw := maxi(1, roundi(res * (3.0 if env == "bunker" or env == "asteroid" else 2.0) / 32.0))
	for y in res:
		for x in res:
			if x >= fw and x < res - fw and y >= fw and y < res - fw:
				continue
			var p := img.get_pixel(x, y)
			if p.a <= 0.0:
				continue
			# Яркость пикселя рамы задаёт яркость цвета: светлая фаска — светлее, тень — темнее.
			var k := clampf((p.r + p.g + p.b) / 3.0 * 1.9, 0.35, 1.35)
			img.set_pixel(x, y, p.lerp(Color(col.r * k, col.g * k, col.b * k, p.a), ACCENT_DOOR_MIX))

## Акцент службы на клетке (0.9.3); 0 — его нет.
func _accent_of(c: Vector2i) -> int:
	if _grid.wall_accent.is_empty():
		return MCF.Accent.NONE
	var a := _grid.accent_at(c.x, c.y)
	return a if a > 0 and a < MCF.ACCENT_COLORS.size() else MCF.Accent.NONE

## Service bands paint ordinary walls only. Glass is a window, and an LDF is a deployable
## fortification: it neither carries a band from the cell it was built on nor continues one.
func _takes_accent(fid: String) -> bool:
	return fid != "" and FAMILY.get(fid, fid) == "wall" and not MCF.is_glass(fid) \
			and fid not in [MCF.FEATURE_LDF, MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN]

## Маска полосы: соседи-стены (и шлюзы) ТОГО ЖЕ цвета. Полоса сворачивает за угол вместе
## со стеной и обрывается там, где кончается отдел.
func _accent_mask(c: Vector2i, accent: int) -> int:
	var mask := 0
	var dirs := [[Vector2i(0, -1), Sprites.AUTOTILE_N], [Vector2i(1, 0), Sprites.AUTOTILE_E],
			[Vector2i(0, 1), Sprites.AUTOTILE_S], [Vector2i(-1, 0), Sprites.AUTOTILE_W]]
	for d in dirs:
		var n: Vector2i = c + d[0]
		if n.x < 0 or n.y < 0 or n.x >= _grid.width or n.y >= _grid.height:
			continue
		var nf := _grid.cell_fast(n.x, n.y).feature_id
		if _takes_accent(nf) and _accent_of(n) == accent:
			mask |= int(d[1])
	return mask

## Полоса службы по стене: линия вдоль стены с загибами к соседям той же службы. Клетка
## со стеной сама по себе (маска 0) получает просто пятно — красить нечего.
func _accent_overlay(accent: int, mask: int, res: int) -> Image:
	var key := "accent@%d@%d@%d" % [accent, mask, res]
	if _tiles.has(key):
		return _tiles[key][0]
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var col: Color = MCF.ACCENT_COLORS[accent]
	var half := maxi(1, roundi(res * 3.0 / 32.0))
	var lo := res / 2 - half
	var hi := res / 2 + half
	var band := Color(col.r, col.g, col.b, 0.92)
	var rim := Color(col.r * 0.42, col.g * 0.42, col.b * 0.42, 0.95)
	# Полоса — центральный квадрат плюс «рукав» к каждому соседу той же службы; рукав
	# продолжается ЗА край плитки, поэтому на стыке двух клеток полоса идёт без шва.
	var inside := func(x: int, y: int) -> bool:
		var across_x: bool = x >= lo and x <= hi
		var across_y: bool = y >= lo and y <= hi
		if across_x and across_y:
			return true
		if across_x and ((y < lo and mask & int(Sprites.AUTOTILE_N) != 0)
				or (y > hi and mask & int(Sprites.AUTOTILE_S) != 0)):
			return true
		return across_y and ((x < lo and mask & int(Sprites.AUTOTILE_W) != 0)
				or (x > hi and mask & int(Sprites.AUTOTILE_E) != 0))
	for y in res:
		for x in res:
			if not inside.call(x, y):
				continue
			# Кромка — там, где полоса кончается ПОПЕРЁК себя; вдоль неё кромки нет, иначе
			# прямой участок получил бы поперечные перекладины.
			var edge: bool = not inside.call(x - 1, y) or not inside.call(x + 1, y) \
					or not inside.call(x, y - 1) or not inside.call(x, y + 1)
			img.set_pixel(x, y, rim if edge else band)
	_tiles[key] = [img]
	return img

## Заваренный шлюз: поверх створок — крест из стальных полос по
## концам и посередине. Рисуется кодом, в res×res, один раз на разрешение.
## A welded door (owner, fix-8 #8): a metal airlock shows its weld beads, a wooden door
## (town, field) the planks nailed across it — pictures of their own; a plain cross when
## those are missing.
func _wooden_door(c: Vector2i) -> bool:
	var look := clampi(_grid.door_at(c.x, c.y), 0, DOOR_MATERIALS.size() * 3)
	var material: String = DOOR_MATERIALS[(look - 1) / 3] if look > 0 else env
	return material in ["town", "field"]

func _weld_overlay(res: int, wooden := false) -> Image:
	var key := "weld@%d@%s" % [res, wooden]
	if _tiles.has(key):
		return _tiles[key][0]
	var pic := _tile("weld_wood" if wooden else "weld_metal", res)
	if not pic.is_empty():
		_tiles[key] = [pic[0]]
		return pic[0]
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var w := maxi(1, res / 8)
	var steel := Color(0.36, 0.37, 0.40)
	var edge := Color(0.62, 0.63, 0.66)
	for y in res:
		for x in res:
			var d1 := absi(x - y)
			var d2 := absi(x + y - (res - 1))
			var d := mini(d1, d2)
			if d <= w:
				img.set_pixel(x, y, edge if d == w else steel)
	_tiles[key] = [img]
	return img

## Мебель нарисована спинкой вверх (§3.15) и встаёт спинкой к стене: k четвертей оборота
## по часовой, при которых верх плитки смотрит на первую стену среди С/В/Ю/З. Стул и
## кресло прежде всего поворачиваются лицом к соседнему столу. Ни стены, ни стола —
## поворот по хешу клетки, чтобы одинаковые предметы не стояли строем.
const _TURN_DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const _TABLES := {"dining_table": true, "desk": true, "office_desk": true,
		"conference_table": true, "coffee_table": true, "park_table": true,
		"reception_desk": true, "workbench": true, "checkout_counter": true}
const _CHAIRS := {"chair": true, "armchair": true}

## Плитка мебели в клетке c: у многоклеточной — кусок листа автотайла по маске соседей
## того же вида, взятой в системе предмета (верх = спинка), и повёрнутый вместе с ним; у
## одиночной — сама плитка, повёрнутая к стене.
## art — другая картинка того же предмета (раскрытый шкаф, «<id>_open», 0.12.1): форма и
## поворот считаются по самому предмету, берётся только иной рисунок.
func _furniture_image(c: Vector2i, fid: String, res: int, art := "") -> Image:
	var pic := art if art != "" else fid
	if time_of_day == "day" and fid in ["streetlight", "bollard_light"]: pic = fid + "_off"
	if winter and (Sprites.has_override(pic + "_snow") or Sprites.has_override(pic + "_snow" + Sprites.AUTOTILE_SUFFIX)):
		pic += "_snow"
	var look := look_of(c, fid)
	var mask: int = look[0]
	var inner: int = look[1]
	var k: int = look[2]
	var corner: int = look[3] if look.size() > 3 else 0
	if not Furniture.joins(fid):
		return _turned(pic, res, k)
	var piece := _piece_image(c, fid, res, k, pic)
	if piece != null:
		return piece
	var key := "%s@%d@m%d@%d@i%d@c%d" % [pic, res, mask, k, inner, corner]
	if _tiles.has(key):
		var hit: Array = _tiles[key]
		return hit[0] if not hit.is_empty() else null
	var sheets := _sheet(pic, res)
	if sheets.is_empty():
		_tiles[key] = []
		return _turned(pic, res, k)
	var img: Image
	if corner != 0:
		img = _corner_tile(sheets[0], corner, res)
	else:
		img = (sheets[0] as Image).get_region(Rect2i((mask % 4) * res, (mask / 4) * res, res, res))
	if inner != 0:
		_carve_inner(img, inner, res)
	for i in k:
		img.rotate_90(CLOCKWISE)
	_tiles[key] = [img]
	return img

## How furniture in cell c is drawn: [mask, inner, k, corner] — the joined sides in the
## piece's own frame, its inner corners, k quarter turns (the back faces _TURN_DIRS[k]) and
## the mitred corner. The first-person view stands its models the same way (fix-8).
func look_of(c: Vector2i, fid: String) -> Array:
	if furniture_look == null:
		return _live_look(c, fid)
	var snap: Array = furniture_look.get(c, [])
	if snap.is_empty() or snap[0] != fid:
		snap = [fid, 0, 0, _single_turn(_grid, c, fid, origin), 0]
		furniture_look[c] = snap
	return snap.slice(1)

## A fixed-size piece (piano, wardrobe, desk, dumpster...) is ONE picture,
## "<id>_piece.png", sized to the whole piece with its back edge at the top (0.11). Each
## cell shows its part of that picture, turned with the piece. null — not such a piece, no
## picture, or the painted cells are not that exact shape (then the sheet or icon is used).
func _piece_image(c: Vector2i, fid: String, res: int, k: int, pic := "") -> Image:
	if not Furniture.is_whole(fid):
		return null
	var sizes: Array = Furniture.sizes_of(fid)
	if sizes.size() != 1:
		return null
	var w0 := int(sizes[0][0])
	var h0 := int(sizes[0][1])
	var turned := _piece_turned(pic if pic != "" else fid, res, k, w0, h0)
	if turned == null:
		return null
	var cells := Furniture.piece_cells(func(q: Vector2i) -> String: return _fid_at(_grid, q), c)
	if cells.size() != w0 * h0:
		return null
	var lo := cells[0]
	var hi := cells[0]
	for q: Vector2i in cells:
		lo = Vector2i(mini(lo.x, q.x), mini(lo.y, q.y))
		hi = Vector2i(maxi(hi.x, q.x), maxi(hi.y, q.y))
	if hi - lo + Vector2i.ONE != Vector2i(turned.get_width() / res, turned.get_height() / res):
		return null
	return turned.get_region(Rect2i((c - lo) * res, Vector2i(res, res)))

func _piece_turned(fid: String, res: int, k: int, w0: int, h0: int) -> Image:
	var key := "%s@piece@%d@%d" % [fid, res, k % 4]
	if _tiles.has(key):
		var hit: Array = _tiles[key]
		return hit[0] if not hit.is_empty() else null
	var img := _load(env_name(fid, env) + "_piece")
	if img == null:
		img = _load(fid + "_piece")
	if img != null:
		if img.get_width() != w0 * res or img.get_height() != h0 * res:
			img.resize(w0 * res, h0 * res, Image.INTERPOLATE_LANCZOS)
		for i in k % 4:
			img.rotate_90(CLOCKWISE)
	_tiles[key] = [img] if img != null else []
	return img

## Угол Г-образного предмета (диван углом, стойка буквой Г или кольцом), 0.9.2. Лист
## рисует спинку только сверху, поэтому угол, у которого спинка (или фасад) идёт по ДВУМ
## открытым сторонам, собирается из двух плиток листа «на ус»: у северной кромки — плитка
## со спинкой сверху, у восточной — она же, повёрнутая спинкой на восток. Своя система:
## открыты север и восток, срослись юг и запад; поворот — потом, как у всех.
## corner: 1 — спинка по обеим сторонам (наружный угол), 2 — фасад по обеим.
func _corner_tile(sheet: Image, corner: int, res: int) -> Image:
	# Берём СРЕДНИЕ секции (открыта одна сторона): у них нет торцевых деталей —
	# подлокотника, монитора, кассы, — и ус не режет их пополам.
	var only_n := Sprites.AUTOTILE_E | Sprites.AUTOTILE_S | Sprites.AUTOTILE_W
	var only_s := Sprites.AUTOTILE_N | Sprites.AUTOTILE_E | Sprites.AUTOTILE_W
	var a: Image
	var b: Image
	if corner == 1:
		a = _sheet_cell(sheet, only_n, res, 0)   # спинка на север
		b = _sheet_cell(sheet, only_n, res, 1)   # она же на восток
	else:
		a = _sheet_cell(sheet, only_s, res, 2)   # фасад на север
		b = _sheet_cell(sheet, only_s, res, 3)   # он же на восток
	for y in res:
		for x in res:
			if x + y > res - 1:
				a.set_pixel(x, y, b.get_pixel(x, y))
	return a

## Плитка листа по маске, повёрнутая на k четвертей по часовой.
func _sheet_cell(sheet: Image, mask: int, res: int, k: int) -> Image:
	var img := sheet.get_region(Rect2i((mask % 4) * res, (mask / 4) * res, res, res))
	for i in k:
		img.rotate_90(CLOCKWISE)
	return img

## Вид клетки мебели по живой доске: [маска стыка, внутренние углы, поворот, угол].
func _live_look(c: Vector2i, fid: String) -> Array:
	if Furniture.base_of(fid) in Furniture.LINEAR_RUNS:
		return _linear_look(c, fid)
	if Furniture.joins(fid) and not Furniture.is_pair(fid):
		var bent := _path_look(_grid, c, fid)
		if not bent.is_empty():
			return bent
	var k := furniture_turn(_grid, c, fid, origin)
	if not Furniture.joins(fid):
		return [0, 0, k, 0]
	var piece: Array[Vector2i] = []
	if Furniture.is_pair(fid): piece = Furniture.piece_cells(func(q: Vector2i) -> String: return _fid_at(_grid, q), c)
	var mask := 0
	for l in 4:
		var n: Vector2i = c + _TURN_DIRS[(l + k) % 4]
		if _grid.in_bounds(n) and Furniture.connects(fid, _grid.cell_fast(n.x, n.y).feature_id) and (piece.is_empty() or piece.has(n)):
			mask |= _MASK_BITS[l]
	# Внутренние углы (Г-образная стойка, диван углом): обе стороны срослись, а клетки по
	# диагонали нет — в этом углу тело должно отступить, как у соседей, иначе ступенька.
	var inner := 0
	for l in 4:
		if mask & _MASK_BITS[l] and mask & _MASK_BITS[(l + 1) % 4] \
				and _fid_at(_grid, c + _TURN_DIRS[(l + k) % 4] + _TURN_DIRS[(l + 1 + k) % 4]) != fid:
			inner |= 1 << l
	return [mask, inner, k, 0]

## Shelves are straight rows: stock varies per tile, while every section shares the
## same orientation and continuous rails. Corner slicing must never cut through goods.
func _linear_look(c: Vector2i, fid: String) -> Array:
	var axis := _linear_axis(c, fid)
	if axis < 0: return [0, 0, furniture_turn(_grid, c, fid, origin), 0]
	var horizontal := axis == 0
	var along := Vector2i.RIGHT if horizontal else Vector2i.DOWN
	var back := Vector2i.UP if horizontal else Vector2i.RIGHT
	var start := c
	while _linear_join(start - along, fid, axis): start -= along
	var score := 0
	var p := start
	while _linear_join(p, fid, axis):
		for side in [-1, 1]:
			var q: Vector2i = p + back * side
			if _grid.in_bounds(q):
				var cell := _grid.cell(q)
				if cell.is_wall() and not Furniture.is_furniture(cell.feature_id): score += side
		p += along
	var k := (0 if horizontal else 1) + (2 if score < 0 else 0)
	var mask := 0
	for l in [1, 3]:
		if _linear_join(c + _TURN_DIRS[(l + k) % 4], fid, axis): mask |= _MASK_BITS[l]
	return [mask, 0, k, 0]

func _linear_axis(c: Vector2i, fid: String) -> int:
	if Furniture.connects(fid, _fid_at(_grid, c + Vector2i.LEFT)) or Furniture.connects(fid, _fid_at(_grid, c + Vector2i.RIGHT)): return 0
	if Furniture.connects(fid, _fid_at(_grid, c + Vector2i.UP)) or Furniture.connects(fid, _fid_at(_grid, c + Vector2i.DOWN)): return 1
	return -1

func _linear_join(c: Vector2i, fid: String, axis: int) -> bool:
	return Furniture.connects(fid, _fid_at(_grid, c)) and _linear_axis(c, fid) == axis

## Снимок вида всей мебели доски для furniture_look.
func freeze_furniture() -> Dictionary:
	var out := {}
	for y in _grid.height:
		for x in _grid.width:
			var fid := _grid.cell_fast(x, y).feature_id
			if Furniture.is_furniture(fid):
				out[Vector2i(x, y)] = [fid] + _live_look(Vector2i(x, y), fid)
	return out

## Вырезать внутренние углы: квадрат с поле открытой стороны (gen_textures M = 3 точки
## из 32) — прозрачный, по его краю — тёмная кромка, как у соседей. Угол l — между
## сторонами l и l+1 (СВ, ЮВ, ЮЗ, СЗ).
func _carve_inner(img: Image, inner: int, res: int) -> void:
	var mm := maxi(1, roundi(3.0 * res / 32.0))
	for l in 4:
		if inner & (1 << l) == 0:
			continue
		var right := l == 0 or l == 1
		var bottom := l == 1 or l == 2
		for dy in mm + 1:
			for dx in mm + 1:
				var x := res - 1 - dx if right else dx
				var y := res - 1 - dy if bottom else dy
				if dx < mm and dy < mm:
					img.set_pixel(x, y, Color(0, 0, 0, 0))
				else:
					var p := img.get_pixel(x, y)
					img.set_pixel(x, y, Color(p.r * 0.5, p.g * 0.5, p.b * 0.5, p.a))

const _MASK_BITS := [Sprites.AUTOTILE_N, Sprites.AUTOTILE_E, Sprites.AUTOTILE_S, Sprites.AUTOTILE_W]

## Сколько клеток самое большее у ряда (стойки, стеллажа), который разбирается как
## «линия с поворотами»: длиннее — рисуется по-старому, секциями.
const PATH_CAP := 96

## Клетки «предмета» для вида: цельный — piece_cells, ряд — все связные клетки того же вида.
static func group_cells(grid: Grid, c: Vector2i, fid: String) -> Array[Vector2i]:
	if Furniture.is_whole(fid):
		return Furniture.piece_cells(func(q: Vector2i) -> String: return _fid_at(grid, q), c)
	var out: Array[Vector2i] = [c]
	var seen := {c: true}
	var i := 0
	while i < out.size() and out.size() <= PATH_CAP:
		for d: Vector2i in _TURN_DIRS:
			var q: Vector2i = out[i] + d
			if not seen.has(q) and Furniture.connects(fid, _fid_at(grid, q)):
				seen[q] = true
				out.append(q)
		i += 1
	return out

## Предмет-«линия» шириной в клетку, у которой есть поворот (Г, П, кольцо): у всех её
## клеток спинка смотрит в ОДНУ сторону линии — к стенам, а без стен наружу, — и на
## углах заворачивает (угловая плитка «на ус», _corner_tile). Пусто — предмет не такой
## (прямой ряд, блок 2×2, развилка): тогда работает прежний поворот по клеткам. Раньше
## каждая клетка Г-стойки поворачивалась сама, и спинка рвалась на углах (0.9.2).
static func _path_look(grid: Grid, c: Vector2i, fid: String) -> Array:
	var cells := group_cells(grid, c, fid)
	if cells.size() < 3 or cells.size() > PATH_CAP:
		return []
	var mine := {}
	for p in cells:
		mine[p] = true
	# Соседи каждой клетки по сторонам (номера направлений 0..3: С, В, Ю, З).
	var nb := {}
	var corners := 0
	var ends: Array[Vector2i] = []
	for p in cells:
		var ds: Array[int] = []
		for d in 4:
			if mine.has(p + _TURN_DIRS[d]):
				ds.append(d)
		if ds.size() > 2:
			return []
		if ds.size() == 2 and (ds[0] + ds[1]) % 2 == 1:
			# Угол; если и диагональ своя — это блок 2×2, а не линия.
			if mine.has(p + _TURN_DIRS[ds[0]] + _TURN_DIRS[ds[1]]):
				return []
			corners += 1
		if ds.size() == 1:
			ends.append(p)
		nb[p] = ds
	if corners == 0 or (ends.size() != 0 and ends.size() != 2):
		return []
	# Обход линии от конца (у кольца — с любой клетки): направление входа и выхода.
	var start: Vector2i = ends[0] if not ends.is_empty() else cells[0]
	var order: Array[Vector2i] = [start]
	var seen := {start: true}
	while true:
		var cur: Vector2i = order[order.size() - 1]
		var moved := false
		for d: int in nb[cur]:
			var q: Vector2i = cur + _TURN_DIRS[d]
			if not seen.has(q):
				seen[q] = true
				order.append(q)
				moved = true
				break
		if not moved:
			break
	if order.size() != cells.size():
		return []
	var ring := ends.is_empty()
	var n := order.size()
	# Для каждой клетки — куда идём (dir) и на какую сторону поворачиваем (turn: +1 вправо).
	var dir_of := {}
	var score := [0, 0]   # стены слева / справа по ходу
	var turns := 0        # правые минус левые
	var manual := _manual_turn(grid, c, fid)
	var want := [0, 0]
	for i in n:
		var p: Vector2i = order[i]
		var din := -1
		var dout := -1
		if i > 0 or ring:
			din = _dir_index(p - order[(i - 1 + n) % n])
		if i < n - 1 or ring:
			dout = _dir_index(order[(i + 1) % n] - p)
		if din < 0:
			din = dout
		if dout < 0:
			dout = din
		dir_of[p] = [din, dout]
		if dout == (din + 1) % 4:
			turns += 1
		elif dout == (din + 3) % 4:
			turns -= 1
		var sides := _open_sides(din, dout)
		for side in 2:
			for o: int in sides[side]:
				var q: Vector2i = p + _TURN_DIRS[o]
				if not grid.in_bounds(q) or grid.cell_fast(q.x, q.y).is_wall():
					score[side] += 1
				var rec: Variant = grid.furniture_turn.get(p)
				if rec != null and str(rec[0]) == fid and int(rec[1]) == o and din == dout:
					want[side] += 1
	var back_side: int
	if manual >= 0 and want[0] != want[1]:
		back_side = 0 if want[0] > want[1] else 1
	elif score[0] != score[1]:
		back_side = 0 if score[0] > score[1] else 1
	else:
		back_side = 0 if turns >= 0 else 1   # без стен — наружу: при правых поворотах снаружи левая сторона
	var din2: int = dir_of[c][0]
	var dout2: int = dir_of[c][1]
	var own: Array = _open_sides(din2, dout2)
	if din2 != dout2:
		# Угол: обе открытые стороны снаружи поворота.
		var outer := 0 if dout2 == (din2 + 1) % 4 else 1
		var o1: int = own[outer][0]
		var o2: int = own[outer][1]
		var k := o1 if o2 == (o1 + 1) % 4 else o2
		return [Sprites.AUTOTILE_S | Sprites.AUTOTILE_W, 1 << 2, k, 1 if outer == back_side else 2]
	var back: int = own[back_side][0]
	var mask := 0
	for d: int in nb[c]:
		mask |= _MASK_BITS[(d - back + 4) % 4]
	return [mask, 0, back, 0]

## Открытые стороны клетки линии слева и справа по ходу: [слева[], справа[]].
static func _open_sides(din: int, dout: int) -> Array:
	if din == dout:
		return [[(din + 3) % 4], [(din + 1) % 4]]
	# Угол: открыты сторона «прямо» (din) и сторона, противоположная выходу.
	var a := din
	var b := (dout + 2) % 4
	if dout == (din + 1) % 4:
		return [[a, b], []]   # поворот направо — обе открытые стороны слева
	return [[], [a, b]]

static func _dir_index(d: Vector2i) -> int:
	return _TURN_DIRS.find(d)

## Поворот, заданный руками (Grid.furniture_turn): у цельного предмета — любой его клетки.
static func _manual_turn(grid: Grid, c: Vector2i, fid: String) -> int:
	if grid.furniture_turn.is_empty():
		return -1
	var cells: Array[Vector2i] = [c]
	if Furniture.is_whole(fid):
		cells = Furniture.piece_cells(func(q: Vector2i) -> String: return _fid_at(grid, q), c)
	for p in cells:
		var rec: Variant = grid.furniture_turn.get(p)
		if rec != null and str(rec[0]) == fid:
			return int(rec[1])
	return -1

static func _fid_at(grid: Grid, q: Vector2i) -> String:
	return grid.cell_fast(q.x, q.y).feature_id if grid.in_bounds(q) else ""

static func furniture_turn(grid: Grid, c: Vector2i, fid: String, at: Vector2i = Vector2i.ZERO) -> int:
	var manual := _manual_turn(grid, c, fid)
	if manual >= 0:
		return manual
	if Furniture.is_whole(fid):
		return _piece_turn(grid, c, fid)
	if Furniture.joins(fid):
		return _run_turn(grid, c, fid, at)
	return _single_turn(grid, c, fid, at)

## Поворот предмета, стоящего самого по себе (и многоклеточного, что приволокли в бою:
## он ни с кем не срастается).
static func _single_turn(grid: Grid, c: Vector2i, fid: String, at: Vector2i) -> int:
	# Стул смотрит на стол, стол — на свой стул (место, где сидят, — низ плитки).
	var kind := Furniture.base_of(fid)
	var faces: Dictionary = _TABLES if _CHAIRS.has(kind) else (_CHAIRS if _TABLES.has(kind) else {})
	if not faces.is_empty():
		for k in 4:
			var n: Vector2i = c + _TURN_DIRS[k]
			if grid.in_bounds(n) and faces.has(Furniture.base_of(grid.cell_fast(n.x, n.y).feature_id)):
				return (k + 2) % 4
	# К СТЕНЕ, а не к соседней мебели (0.12.2, item 12): высокий шкаф рядом раньше считался
	# стеной, и уже стоявший ящик разворачивало, стоило поставить шкаф сбоку.
	for k in 4:
		var n: Vector2i = c + _TURN_DIRS[k]
		if not grid.in_bounds(n):
			return k
		var nc := grid.cell_fast(n.x, n.y)
		if nc.is_wall() and not Furniture.is_furniture(nc.feature_id):
			return k
	return variant_of(c + at, 4)

## Цельный предмет поворачивается целиком: к стене той стороной, что ему положена (кровать
## — изголовьем, т.е. короткой; диван, стол-бюро — длинной), и по возможности стороной,
## что вся у стены. Без стены — стол-бюро лицом к стулу, остальное — длинной осью поперёк
## «спинки». Считается по всем клеткам предмета, поэтому у всех его клеток один поворот.
static func _piece_turn(grid: Grid, c: Vector2i, fid: String) -> int:
	var cells := Furniture.piece_cells(func(q: Vector2i) -> String: return _fid_at(grid, q), c)
	var mine := {}
	for p in cells:
		mine[p] = true
	var side := [0, 0, 0, 0]
	var walled := [0, 0, 0, 0]
	var chair := [0, 0, 0, 0]
	for p in cells:
		for k in 4:
			var q: Vector2i = p + _TURN_DIRS[k]
			if mine.has(q):
				continue
			side[k] += 1
			if not grid.in_bounds(q) or grid.cell_fast(q.x, q.y).is_wall():
				walled[k] += 1
			elif _CHAIRS.has(Furniture.base_of(grid.cell_fast(q.x, q.y).feature_id)):
				chair[k] += 1
	var back := Furniture.back_of(fid)
	var best := -1
	var best_score := -1000000000
	var short_side: int = mini(mini(side[0], side[1]), mini(side[2], side[3]))
	var long_side: int = maxi(maxi(side[0], side[1]), maxi(side[2], side[3]))
	for k in 4:
		if walled[k] == 0:
			continue
		# Изголовье — только с короткой стороны, спинка — только с длинной: кровать, что
		# стоит вдоль стены, иначе легла бы к ней боком, с подушками во всю длину.
		if (back == "short" and side[k] != short_side) or (back == "long" and side[k] != long_side):
			continue
		var score: int = walled[k] * 10 + (1000 if walled[k] == side[k] else 0)
		if back == "short":
			score -= side[k] * 100
		elif back == "long":
			score += side[k] * 100
		if score > best_score:
			best_score = score
			best = k
	if best >= 0 and back != "":
		return best
	for k in 4:
		if chair[k] > 0 and _TABLES.has(Furniture.base_of(fid)):
			return (k + 2) % 4
	var horizontal: bool = side[0] >= side[1]   # ширина по северу ≥ высоты по востоку
	if back == "short":
		return 1 if horizontal else 0
	return 0 if horizontal else 1

## Секции ряда (стойка, стеллаж) поворачиваются согласно ряду: ось ряда задаёт пару
## поворотов, стена решает, какой из двух; угол ряда — по стене; одиночная секция — как
## одиночный предмет. Так у всего ряда одна «спинка», даже если конец упёрся в стену.
static func _run_turn(grid: Grid, c: Vector2i, fid: String, at: Vector2i = Vector2i.ZERO) -> int:
	var same := [false, false, false, false]
	var wall := [false, false, false, false]
	for k in 4:
		var q: Vector2i = c + _TURN_DIRS[k]
		same[k] = Furniture.connects(fid, _fid_at(grid, q))
		wall[k] = not grid.in_bounds(q) or grid.cell_fast(q.x, q.y).is_wall()
	var across: bool = same[1] or same[3]   # сосед восток/запад — ряд лежит по горизонтали
	var down: bool = same[0] or same[2]
	if across and not down:
		return 2 if wall[2] and not wall[0] else 0
	if down and not across:
		return 3 if wall[3] and not wall[1] else 1
	for k in 4:
		if wall[k]:
			return k
	return variant_of(c + at, 4)

## Плитка мебели в разрешении res, повёрнутая на k четвертей (кэш по трём ключам).
## Атлас объекта (0.9.4) несёт ЧЕТЫРЕ направления готовыми: если он есть, берём нужное
## как нарисовано — художник мог развернуть предмет вручную, а не просто повернуть плитку.
func _turned(name: String, res: int, k: int) -> Image:
	var key := "%s@%d@%d" % [name, res, k]
	if _tiles.has(key):
		var hit: Array = _tiles[key]
		return hit[0] if not hit.is_empty() else null
	var facing := _atlas_part(name, Sprites.ATLAS_TURN_ROW, 1, 4)
	if facing != null:
		var t := facing.get_height()
		var one := facing.get_region(Rect2i((k % 4) * t, 0, t, t))
		if t != res:
			one.resize(res, res, Image.INTERPOLATE_LANCZOS)
		_tiles[key] = [one]
		return one
	var base := _tile(name, res)
	if base.is_empty():
		_tiles[key] = []
		return null
	var img: Image = (base[0] as Image).duplicate()
	for i in k:
		img.rotate_90(CLOCKWISE)
	_tiles[key] = [img]
	return img

## A lamp's glass takes its light colour (0.11): bright, unsaturated pixels — the bulb,
## the shade's glow — are recoloured; the metal body keeps its own colours.
## Перекраска светящегося предмета (0.12.1, владелец: «the color of the sprite should change
## as well»). Белое свечение (плафон лампы) красится как раньше; цветное — экран консоли,
## телевизора, огоньки стойки — узнаётся по оттенку своего света по умолчанию (base) и
## получает новый оттенок при той же яркости. Это работа шейдера, только сделанная один раз
## при сборке плитки: мебель запечена в картинки кусков доски, лишних спрайтов не нужно.
static func tint_lamp(src: Image, colour: Color, base := Color.WHITE) -> Image:
	var img: Image = src.duplicate()
	var hued := base.s > 0.25
	var sat_k := clampf(colour.s / maxf(base.s, 0.01), 0.0, 1.2)
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a <= 0.0: continue
			if hued and p.s > 0.25 and p.v > 0.3 and _hue_gap(p.h, base.h) < 0.11:
				img.set_pixel(x, y, Color.from_hsv(colour.h, clampf(p.s * sat_k, 0.0, 1.0), p.v, p.a))
				continue
			# Белое свечение (плафон, световая панель автомата). У цветного предмета — только
			# почти белое: светло-серые клавиши консоли и корпус остаются как нарисованы.
			var hi := maxf(p.r, maxf(p.g, p.b))
			var lo := minf(p.r, minf(p.g, p.b))
			if hi < (0.85 if hued else 0.62) or (hi - lo) / hi > 0.3: continue
			var k := clampf((hi - 0.62) / 0.3, 0.0, 1.0)
			img.set_pixel(x, y, p.lerp(Color(colour.r * hi, colour.g * hi, colour.b * hi, p.a), 0.35 + 0.6 * k))
	return img

static func _hue_gap(a: float, b: float) -> float:
	var d := absf(a - b)
	return minf(d, 1.0 - d)

## Трещины по побитой мебели: два тёмных излома поперёк плитки.
func _crack_overlay(res: int) -> Image:
	var key := "crack@%d" % res
	if _tiles.has(key):
		return _tiles[key][0]
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var ink := Color(0.08, 0.06, 0.05, 0.85)
	var pts := [Vector2(0.18, 0.22), Vector2(0.42, 0.40), Vector2(0.36, 0.58), Vector2(0.62, 0.78),
			Vector2(0.84, 0.70)]
	for i in pts.size() - 1:
		var a: Vector2 = pts[i] * res
		var b: Vector2 = pts[i + 1] * res
		var steps := maxi(2, int(a.distance_to(b)))
		for t in steps + 1:
			var p := a.lerp(b, float(t) / steps)
			img.set_pixel(clampi(int(p.x), 0, res - 1), clampi(int(p.y), 0, res - 1), ink)
	_tiles[key] = [img]
	return img

## Трещины в бетоне ДОТа: ломаные с отростками, тёмный излом и светлый скол под ним.
## У амбразуры они идут от углов щели вверх и вниз, а края щели выщерблены — щель
## (строки 13–18 плитки) остаётся щелью, трещины её не перечёркивают. Точки — в системе
## плитки 32×32; v — вариант по клетке, чтобы стена ДОТа не трескалась под копирку.
const _CRACKS := [
	[[Vector2(4, 3), Vector2(9, 8), Vector2(8, 13), Vector2(14, 17), Vector2(13, 22), Vector2(18, 27)],
		[Vector2(9, 8), Vector2(15, 7), Vector2(19, 10)], [Vector2(14, 17), Vector2(21, 16)]],
	[[Vector2(28, 4), Vector2(23, 9), Vector2(24, 14), Vector2(18, 18), Vector2(19, 24), Vector2(15, 29)],
		[Vector2(23, 9), Vector2(17, 8)], [Vector2(18, 18), Vector2(12, 21), Vector2(10, 26)]],
	[[Vector2(5, 28), Vector2(10, 22), Vector2(9, 17), Vector2(15, 13), Vector2(21, 14), Vector2(27, 8)],
		[Vector2(15, 13), Vector2(14, 7), Vector2(17, 3)], [Vector2(21, 14), Vector2(24, 20)]],
]
const _SLIT_CRACKS := [
	[[Vector2(10, 13), Vector2(8, 9), Vector2(11, 5), Vector2(9, 1)], [Vector2(22, 13), Vector2(24, 9), Vector2(21, 6)],
		[Vector2(14, 18), Vector2(12, 22), Vector2(15, 26), Vector2(13, 30)]],
	[[Vector2(20, 13), Vector2(22, 8), Vector2(19, 4)], [Vector2(6, 18), Vector2(4, 23), Vector2(7, 28)],
		[Vector2(24, 18), Vector2(26, 23), Vector2(23, 27)]],
	[[Vector2(13, 13), Vector2(15, 9), Vector2(12, 6), Vector2(14, 2)], [Vector2(19, 18), Vector2(21, 23), Vector2(18, 29)],
		[Vector2(5, 13), Vector2(3, 9)]],
]

func _pillbox_crack(res: int, v: int, slit: bool) -> Image:
	var key := "pcrack@%d@%d@%s" % [res, v, slit]
	if _tiles.has(key):
		return _tiles[key][0]
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var k := res / 32.0
	var ink := Color(0.07, 0.07, 0.06, 0.92)
	var chip := Color(0.86, 0.85, 0.8, 0.45)
	var lines: Array = (_SLIT_CRACKS if slit else _CRACKS)[v % 3]
	for pts: Array in lines:
		for i in pts.size() - 1:
			var a: Vector2 = pts[i] * k
			var b: Vector2 = pts[i + 1] * k
			var steps := maxi(2, int(a.distance_to(b) * 1.5))
			for t in steps + 1:
				var p := a.lerp(b, float(t) / steps)
				var x := clampi(int(p.x), 0, res - 1)
				var y := clampi(int(p.y), 0, res - 1)
				if slit and y > int(13 * k) and y < int(18 * k):
					continue   # в самой щели — темнота, трещине там нечего делать
				if x + 1 < res and y + 1 < res and img.get_pixel(x + 1, y + 1).a == 0.0:
					img.set_pixel(x + 1, y + 1, chip)
				img.set_pixel(x, y, ink)
	if slit:
		# Выщербленные края щели: по паре сколов сверху и снизу.
		for e: Vector2i in [Vector2i(9, 13), Vector2i(10, 13), Vector2i(22, 12), Vector2i(14, 18), Vector2i(15, 19),
				Vector2i(24, 18)]:
			var q := Vector2i(int(e.x * k), int(e.y * k))
			if q.x < res and q.y < res:
				img.set_pixel(q.x, q.y, ink)
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

## Имя плитки пола клетки, или «» — если пола нет вовсе и клетка остаётся прозрачной.
## Пустую строку отдаёт только КОСМОС (0.9.3): за доской плывёт параллакс звёзд, и своя
## плитка космосу не нужна — он и есть отсутствие плитки. Подложенная игроком картинка
## floor_space рисуется по-прежнему: раз её положили, значит, её и хотят видеть.
func _floor_name(cell: GridCell, c: Vector2i) -> String:
	var look := _grid.look_at(c.x, c.y) if not _grid.floor_look.is_empty() else 0
	if cell.is_space:
		# Солнечные панели у станции (0.9.2) — вид поверх звёзд; клетка остаётся космосом.
		if look == MCF.Look.SOLAR:
			return "floor_solar"
		return "floor_space" if Sprites.has_user_override("floor_space") else ""
	var dmg := int(_damaged.get(c, 0))
	if dmg == FxDecals.DAMAGE_EPICENTER:
		return "floor_epicenter"
	if dmg == FxDecals.DAMAGE_RUBBLE:
		return "floor_destroyed"
	# Old outdoor maps also receive a proper threshold, without changing their rules.
	if cell.feature_id == MCF.FEATURE_AIRLOCK and env in ["town", "field", "asteroid"]:
		if look in [MCF.Look.DEFAULT, MCF.Look.DIRT, MCF.Look.GRASS] or look >= MCF.FLOOR_LOOKS.size():
			return "floor_plate"
		if not MCF.FLOOR_OVERLAY_LOOKS.has(look): return MCF.FLOOR_LOOKS[look]
	if cell.floor_type == MCF.FLOOR_GRASS:
		return "floor_grass"
	# Пол комнаты (0.9.2): дерево, плитка, ковёр — вид, правила те же.
	if look > 0 and look < MCF.FLOOR_LOOKS.size() and look != MCF.Look.SOLAR \
			and not MCF.FLOOR_OVERLAY_LOOKS.has(look):
		return MCF.FLOOR_LOOKS[look]
	return "floor"

## Open ground under cell c for the first-person view (fix-8): 1 grass, 2 bare earth,
## 0 anything else. On the board these are 32-pixel tiles; walked on in 3D, a grid of
## tiles showed through (owner), so there the ground is one seamless texture instead.
func ground_kind(c: Vector2i) -> int:
	var cell := _grid.cell_fast(c.x, c.y)
	if cell.is_space:
		return 0
	match env_name(_floor_name(cell, c), env):
		"floor_grass": return 1
		"floor_field": return 2
	return 0

## Настил ПОВЕРХ пола клетки (решётка, 0.9.3) или «» — настила нет. Решётка прозрачна
## между прутьями, поэтому она не заменяет пол: в космосе под ней звёзды, в помещении — его
## собственный пол.
func _floor_overlay_name(cell: GridCell, c: Vector2i) -> String:
	if _grid.floor_look.is_empty():
		return ""
	var look := _grid.look_at(c.x, c.y)
	if not MCF.FLOOR_OVERLAY_LOOKS.has(look):
		return ""
	if not cell.is_space and int(_damaged.get(c, 0)) != 0:
		return ""   # пол разворочен взрывом — решётке на нём не устоять
	return MCF.FLOOR_LOOKS[look]

## Картинка кучи из окопа: на станции и астероиде — обрезки пола и металлический лом
## (0.12.1, «rubble»), в прочих окружениях — грунт. Стена из грунта (Soil) не меняется.
static func pile_art(p_env: String) -> String:
	if MCF.rubble_env(p_env) and Sprites.has_override("rubble" + Sprites.AUTOTILE_SUFFIX):
		return "rubble"
	return "soil"

## Имя картинки объекта: id с учётом подмен (ЛДФ, ДПМГ) и состояния шлюза — открытый
## шлюз (высота ниже стены) рисуется разъехавшимися створками.
static func tile_name(cell: GridCell) -> String:
	return "soil" if cell.feature_id == MCF.FEATURE_DIRT_PILE else Sprites.ALIASES.get(cell.feature_id, cell.feature_id)

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
## closed — дверь нарисовать закрытой, как бы ни стояла (под туманом её помнят закрытой).
func draw_feature_tile(ci: CanvasItem, fid: String, c: Vector2i, rect: Rect2, closed := false) -> void:
	if fid == MCF.FEATURE_AIRLOCK and _grid.in_bounds(c):
		var dimg := _door_image(_grid, c, _grid.cell_fast(c.x, c.y), TerrainTiles.T, closed)
		if dimg != null:
			ci.draw_texture_rect(Sprites.nearest(_furniture_tex(dimg)), rect, false)
		return
	if Furniture.is_furniture(fid):
		var img := _furniture_image(c, fid, TerrainTiles.T)
		if img != null:
			ci.draw_texture_rect(Sprites.nearest(_furniture_tex(img)), rect, false)
		return
	var name: String = env_name(pile_art(env) if fid == MCF.FEATURE_DIRT_PILE else Sprites.ALIASES.get(fid, fid), env)
	var sheet := Sprites.texture_of(name + Sprites.AUTOTILE_SUFFIX)
	if sheet != null:
		Sprites.draw_autotile(ci, Sprites.nearest(sheet), rect, mask_at(_grid, c, fid), variant_of(c + origin, 64))
	else:
		Sprites.draw_tile(ci, name, rect, variant_of(c + origin, 64), true)

var _furn_tex: Dictionary = {}   # Image -> ImageTexture для отдельной отрисовки мебели
func _furniture_tex(img: Image) -> ImageTexture:
	var t: Variant = _furn_tex.get(img)
	if t == null:
		t = ImageTexture.create_from_image(img)
		_furn_tex[img] = t
	return t

## Слой для экранов без своего (расстановка): рисует куски под родителем (show_behind_parent).
## Родитель задаёт position/scale своей панорамой и видимые клетки.
class Layer extends Node2D:
	var tiles: TerrainTiles = null
	var cells := Rect2i()
	var origin := Vector2.ZERO
	var cell_size := 40.0
	## Сетка клеток (прозрачная — нет) и её толщина в точках слоя.
	var grid_color := Color(0, 0, 0, 0)
	var grid_width := 1.0
	func _init() -> void:
		show_behind_parent = true
	func _draw() -> void:
		if tiles == null:
			return
		var res := TerrainTiles.prepare(self, cell_size)
		tiles.draw(self, origin, cell_size, cells.position.x, cells.position.y,
				cells.end.x, cells.end.y, false, res)
		TerrainTiles.draw_grid(self, origin, cell_size, cells.position.x, cells.position.y,
				cells.end.x, cells.end.y, grid_color, grid_width)
		tiles.draw(self, origin, cell_size, cells.position.x, cells.position.y,
				cells.end.x, cells.end.y, true, res)

## Сетка клеток [x0..x1]×[y0..y1] — линиями по строкам и столбцам. Её рисуют МЕЖДУ полом
## и объектами: на полу клетки видны, а стену, стол или кровать в несколько клеток линия
## не режет на куски. col прозрачный — сетки нет.
static func draw_grid(ci: CanvasItem, origin: Vector2, cell: float, x0: int, y0: int, x1: int, y1: int,
		col: Color, width: float) -> void:
	if col.a <= 0.0:
		return
	var pts := PackedVector2Array()
	for x in range(x0, x1 + 2):
		pts.append(origin + Vector2(x * cell, y0 * cell))
		pts.append(origin + Vector2(x * cell, (y1 + 1) * cell))
	for y in range(y0, y1 + 2):
		pts.append(origin + Vector2(x0 * cell, y * cell))
		pts.append(origin + Vector2((x1 + 1) * cell, y * cell))
	ci.draw_multiline(pts, col, width)

## Разрешение кусков и фильтрация для слоя ci (его scale — зум панорамы): по тому, сколько
## точек экрана приходится на клетку. Ужатая плитка сглаживается, растянутая — нет.
static func prepare(ci: CanvasItem, cell_size: float) -> int:
	var px := cell_size * ci.get_global_transform_with_canvas().get_scale().x \
			* ci.get_viewport().get_final_transform().get_scale().x
	var res := res_for(px)
	ci.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if px >= float(res) \
			else CanvasItem.TEXTURE_FILTER_LINEAR
	return res

## Index authored decals separately from floor pixels, beneath walls and objects.
var time_of_day := ""
## Winter (fix-8 #3): grass, earth and street under snow, plants in their snowy pictures.
var winter := false

func set_winter(value: bool) -> bool:
	if winter == value: return false
	winter = value
	_generation += 1
	_chunks.clear()
	_bytes = 0
	return true

const WINTER_FLOORS := {"floor_grass": "floor_snow", "floor_field": "floor_snow_field", "floor_town": "floor_town_snow"}

## A floor tile's winter picture, when it has one.
func _winter_floor(fname: String) -> String:
	if not winter or fname == "":
		return fname
	return str(WINTER_FLOORS.get(env_name(fname, env), fname))

func set_time_of_day(value: String) -> bool:
	if time_of_day == value: return false
	time_of_day = value
	_generation += 1
	_chunks.clear()
	_bytes = 0
	return true

func set_map_decals() -> void:
	map_decals.clear()
	_map_decal_bleed = 1.5
	for d: Array in _grid.map_decals:
		var pos := Vector2(float(d[1]), float(d[2]))
		_map_decal_bleed = maxf(_map_decal_bleed, float(d[4]))
		var cc := Vector2i(floori(pos.x / C), floori(pos.y / C))
		if not map_decals.has(cc): map_decals[cc] = []
		map_decals[cc].append({"kind": str(d[0]), "pos": pos, "rot": float(d[3]), "scale": float(d[4])})
	if bake_map_decals:
		_generation += 1
		_chunks.clear()
		_bytes = 0

func _index_ground_lines(fx: FxDecals) -> void:
	for cc: Vector2i in ground_lines: _dirty[cc] = true
	ground_lines.clear()
	for kind in 2:
		var lines: Array = fx.track_marks if kind == 0 else fx.laser_lines
		for seg: Dictionary in lines:
			var a: Vector2 = seg["from"]
			var b: Vector2 = seg["to"]
			var lo := (a.min(b) - Vector2.ONE * 0.15) / C
			var hi := (a.max(b) + Vector2.ONE * 0.15) / C
			for y in range(floori(lo.y), floori(hi.y) + 1):
				for x in range(floori(lo.x), floori(hi.x) + 1):
					var cc := Vector2i(x, y)
					if not ground_lines.has(cc): ground_lines[cc] = []
					ground_lines[cc].append([a, b, kind])
					_dirty[cc] = true

func _bake_ground_lines(img: Image, cc: Vector2i, res: int) -> void:
	var native := NativeKernels.terrain()
	if native != null and native.paint_ground_lines(img, ground_lines.get(cc, []), Vector2(cc * C), res): return
	_bake_ground_lines_gd(img, cc, res)

func _bake_ground_lines_gd(img: Image, cc: Vector2i, res: int) -> void:
	for line: Array in ground_lines.get(cc, []):
		var a: Vector2 = (line[0] - Vector2(cc * C)) * res
		var b: Vector2 = (line[1] - Vector2(cc * C)) * res
		var radius := maxf(0.5, res * (0.11 if int(line[2]) == 0 else 0.04))
		var ink := Color(0.1, 0.08, 0.05, 0.2) if int(line[2]) == 0 else Color(0, 0, 0, 0.4)
		var lo := a.min(b) - Vector2.ONE * radius
		var hi := a.max(b) + Vector2.ONE * radius
		var dy := b.y - a.y
		for y in range(maxi(0, floori(lo.y)), mini(img.get_height(), ceili(hi.y))):
			# Only visit the strip touched by the stroke on this row. A diagonal
			# track used to test every pixel of its entire rectangular bounding box.
			var left := lo.x
			var right := hi.x
			if absf(dy) > 0.00001:
				var x0 := lerpf(a.x, b.x, clampf((y + 0.5 - radius - a.y) / dy, 0.0, 1.0))
				var x1 := lerpf(a.x, b.x, clampf((y + 0.5 + radius - a.y) / dy, 0.0, 1.0))
				left = maxf(left, minf(x0, x1) - radius)
				right = minf(right, maxf(x0, x1) + radius)
			for x in range(maxi(0, floori(left)), mini(img.get_width(), ceili(right))):
				var p := Vector2(x + 0.5, y + 0.5)
				if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) <= radius:
					img.set_pixel(x, y, img.get_pixel(x, y).blend(ink))

## Render the actual game tiles for menus and preset previews, without a scene or simulation.
static func map_preview(map: MapData, tints: Dictionary = {}, bands: Dictionary = {},
		army_colors: Dictionary = {}) -> ImageTexture:
	var saved := GridCell.logs_snapshot()
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var tiles := TerrainTiles.new(grid, map.environment())
	tiles.set_winter(map.winter and MapData.supports_winter(map.environment()))
	tiles.bake_map_decals = true
	var res := clampi(1024 / maxi(map.width, map.height), 2, 16)
	var img := Image.create(map.width * res, map.height * res, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.025, 0.035, 0.055))
	for cy in ceili(float(map.height) / C):
		for cx in ceili(float(map.width) / C):
			var cc := Vector2i(cx, cy)
			tiles._build(cc, res)
			var chunk: Dictionary = tiles._chunks[Vector3i(cx, cy, res)]
			var floor_img: Image = chunk["floor"].get_image()
			var feat_img: Image = chunk["feat"].get_image()
			var rect := Rect2i(Vector2i.ZERO, floor_img.get_size())
			img.blend_rect(floor_img, rect, cc * C * res)
			img.blend_rect(feat_img, rect, cc * C * res)
			tiles._chunks.clear()
	# Deployment zones in their faction colour (0.11.1: Conclave-NOVA red, Purifiers
	# yellow must read at a glance): a clear wash and a thin solid outline.
	var zone_of := PackedColorArray()
	zone_of.resize(map.width * map.height)
	for y in map.height:
		for x in map.width:
			var tint: Color = tints.get(map.get_zone(Vector2i(x, y)), Color.TRANSPARENT)
			if tint.a == 0:
				for band: Vector2i in bands:
					if x >= band.x and x < band.y: tint = bands[band]; break
			zone_of[y * map.width + x] = tint
	var overlay := Image.create(map.width, map.height, false, Image.FORMAT_RGBA8)
	for i in zone_of.size():
		if zone_of[i].a > 0:
			overlay.set_pixel(i % map.width, i / map.width, Color(zone_of[i], 0.35))
	overlay.resize(map.width * res, map.height * res, Image.INTERPOLATE_NEAREST)
	img.blend_rect(overlay, Rect2i(Vector2i.ZERO, overlay.get_size()), Vector2i.ZERO)
	# The rim is a thin line on the zone's own side of each border edge (user: "much thinner").
	var lw := maxi(1, res / 8)
	for y in map.height:
		for x in map.width:
			var tint := zone_of[y * map.width + x]
			if tint.a == 0: continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n := Vector2i(x, y) + d
				if n.x >= 0 and n.y >= 0 and n.x < map.width and n.y < map.height \
						and zone_of[n.y * map.width + n.x] == tint:
					continue
				var o := Vector2i(x, y) * res
				var edge := Rect2i(o + Vector2i(res - lw, 0), Vector2i(lw, res)) if d.x > 0 \
						else (Rect2i(o, Vector2i(lw, res)) if d.x < 0 \
						else (Rect2i(o + Vector2i(0, res - lw), Vector2i(res, lw)) if d.y > 0 \
						else Rect2i(o, Vector2i(res, lw))))
				img.fill_rect(edge, Color(tint, 1.0))
	# Keep map-authored civilians visible in the textured preview.
	# A saved battlefield (0.11) also shows where each army stands, in its slot colour.
	for spawn: Dictionary in map.spawns:
		var owner := int(spawn["owner"])
		var colour: Variant = Roster.NEUTRAL_COLOR if MCF.is_neutral(owner) else army_colors.get(owner)
		if colour == null: continue
		var coord: Vector2i = spawn["coord"]
		img.fill_rect(Rect2i(coord * res + Vector2i.ONE * (res / 4),
			Vector2i.ONE * maxi(1, res / 2)), colour)
	GridCell.logs_restore(saved)
	return ImageTexture.create_from_image(img)

## Heightmap mode (0.11.1): the height of a cover tile as a plain number — "0.5", "1",
## "1.5", "2". Empty for open ground and space.
static func height_text(cell_height: float, space := false, feature_id := "") -> String:
	# Окоп — яма, а не укрытие над полом (issues-12 #12): высота у него нулевая, и на
	# карте высот его не было видно вовсе.
	if feature_id == MCF.FEATURE_TRENCH and not space:
		return "-2"
	if space or cell_height <= 0.0:
		return ""
	var tenths := roundi(cell_height * 10.0)
	return str(tenths / 10) if tenths % 10 == 0 else "%d.%d" % [tenths / 10, tenths % 10]

## One label, centred on the cell (at is the cell's top-left corner, side its size). Full
## 2 m walls are drawn dimmer so the low cover between them stands out.
static func draw_height_text(ci: CanvasItem, font: Font, at: Vector2, side: float, text: String,
		wall := false) -> void:
	var fs := maxi(8, int(side * 0.36))
	var pos := at + Vector2(0, side * 0.5 + fs * 0.35)
	ci.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, side, fs, 3,
			Color(0, 0, 0, 0.5 if wall else 0.9))
	ci.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, side, fs,
			Color(0.8, 0.8, 0.8, 0.55) if wall else Color(1, 0.95, 0.6))
