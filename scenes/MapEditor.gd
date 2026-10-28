extends Node2D

## Редактор карт (editor-rework): устроен «как Paint», по выбору владельца.
##
##   • сверху — меню (File / Edit / View / Map), настройки инструмента и кнопка Play;
##   • слева — инструменты: кисть, ластик, линия, прямоугольник, заливка, выделение,
##     пипетка, заготовка;
##   • справа — палитра с настоящими картинками плиток в окружении пресета: пол, стены,
##     объекты, нейтральные бойцы, зоны развёртывания, заготовки;
##   • снизу — строка состояния и миникарта (щелчок по ней переносит взгляд).
##
## Карта рисуется ТЕМИ ЖЕ плитками, что и бой (TerrainTiles на сетке-зеркале _grid): что
## нарисовал, то и увидишь в партии. Правка клетки пишет в MapData и в зеркало; журнал
## вида GridCell помечает грязные куски, и пересобираются только они.
##
## Откат — разностями, а не снимками: действие помнит клетки, которых коснулось, «до» и
## «после». Прежний редактор на каждый мазок сохранял всю карту в словарь (на 250×250 —
## мегабайты на щелчок). Снимок целиком остался только для размера и очистки.
##
## Узор (MapPresets.pattern) — общий формат буфера обмена, перенесённого выделения и
## заготовок. Его можно повернуть (R) и отразить (H/V), и ставится он с той же
## симметрией, что и мазок кисти.

const RoomPresets = preload("res://src/data/RoomPresetStore.gd")
const SteamChrome = preload("res://src/ui/SteamChrome.gd")

const CELL := 40.0
const ZOOM_MIN := 0.04
const ZOOM_MAX := 3.0
const PAN_SPEED := 900.0
const UNDO_DEPTH := 100
## Потолок полей «ширина/высота». Генератор умеет и больше, но рисовать руками поле
## крупнее 500×500 незачем, а плитки и миникарта рассчитаны на такое.
const MAX_DIM := 500
const DEFAULT_SIZE := Vector2i(48, 32)

## Раскладка (в точках холста — до множителя размера интерфейса).
const MENU_H := 36.0
const TOOLBAR_W := 48.0
const PALETTE_W := 280.0
const STATUS_H := 26.0
const MINI_MAX := 120.0

enum Tool { BRUSH, ERASER, LINE, RECT, FILL, SELECT, PICK, STAMP, CIRCLE }
const TOOLS := [
	{"tool": Tool.BRUSH, "name": "Brush", "action": "editor_brush", "hint": "Paint with the chosen tile. Drag to draw."},
	{"tool": Tool.ERASER, "name": "Eraser", "action": "editor_eraser", "hint": "Take off the top thing: the object on a cell first (the floor under it stays), then a unit, then the cell goes back to the preset's empty ground."},
	{"tool": Tool.LINE, "name": "Line", "action": "editor_line", "hint": "Drag a straight line of the chosen tile."},
	{"tool": Tool.RECT, "name": "Rectangle", "action": "editor_rect", "hint": "Drag a rectangle. Tick Filled for a solid one."},
	{"tool": Tool.CIRCLE, "name": "Circle", "action": "editor_circle", "hint": "Drag a box and get the circle (or oval) inside it. Tick Filled for a solid one."},
	{"tool": Tool.FILL, "name": "Fill", "action": "editor_fill", "hint": "Flood a connected area of identical cells."},
	{"tool": Tool.SELECT, "name": "Select", "action": "editor_select", "hint": "Drag to select. Drag the selection to move it. See Edit for copy, cut, paste and delete shortcuts."},
	{"tool": Tool.PICK, "name": "Eyedropper", "action": "editor_pick", "hint": "Click a cell to pick its tile, unit or zone (Alt+click works with any tool)."},
	{"tool": Tool.STAMP, "name": "Presets", "action": "editor_stamp", "hint": "Place the chosen room or building. See Edit for rotate and flip shortcuts."},
]

enum Sym { OFF, X, Y, QUAD }
const SYM_NAMES := ["Off", "Left / Right", "Top / Bottom", "Four quarters"]

const TERRAIN := [["floor", "Floor"], ["grass", "Grass"], ["space", "Space"]]
## Виды пола (0.9.2): кисть «floor:N» кладёт пол окружения с видом MCF.FLOOR_LOOKS[N].
## Панели и решётка (10, 11) — виды КОСМОСА: своего пола у них нет, они висят снаружи
## станции, и кисть кладёт их на космос (см. _brush_cell).
const FLOOR_LOOK_BRUSHES := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
## Виды, которые кисть кладёт на КОСМОС, а не на пол.
const SPACE_LOOK_BRUSHES := {MCF.Look.SOLAR: true, MCF.Look.GRILL: true}
const WALLS := [
	[MCF.FEATURE_WALL, "Wall"], [MCF.FEATURE_WOOD_WALL, "Wood wall"],
	[MCF.FEATURE_SOIL, "Soil"], [MCF.FEATURE_GLASS, "Glass"],
	[MCF.FEATURE_ARMOR_WALL, "Armor wall"], [MCF.FEATURE_ARMOR_GLASS, "Armor glass"],
	[MCF.FEATURE_AIRLOCK, "Airlock"], [MCF.FEATURE_LDF, "LDF wall"],
	[MCF.FEATURE_DOT, "Pillbox"], [MCF.FEATURE_DOT_OPEN, "Embrasure"],
]
const OBJECTS := [
	[MCF.FEATURE_SANDBAGS, "Sandbags"], [MCF.FEATURE_HEDGEHOG, "Hedgehog"],
	[MCF.FEATURE_TRENCH, "Trench"], ["clear_object", "No object"],
]
## Кого можно поставить на карту нейтралом (item 5): любая пехота.
const NEUTRAL_UNIT_IDS := [
	"civilian", "light_infantry", "heavy_infantry", "machinegunner",
	"sniper", "marksman", "anti_tank", "flamethrower", "shield_bearer",
	"engineer", "miner", "sapper", "commander", "drone_operator",
]
## Сколько зон показывать в палитре сразу; остальные — по «More zones».
const ZONES_SHOWN := 8

# --- Документ ---
var map: MapData
var map_name := ""
var _dirty := false

# --- Инструмент и кисть ---
var tool: int = Tool.BRUSH
var _prev_tool: int = Tool.BRUSH
var brush := MCF.FEATURE_WALL
var brush_size := 1
var rect_filled := false
## Поворот мебели под кистью (R, 0.9.2): −1 — сам (к стене), 0..3 — четверти по часовой.
var brush_turn := -1
var symmetry: int = Sym.OFF
var stamp_id := "small_room"

# --- Вид ---
var pan := Vector2.ZERO:
	set(value):
		pan = value
		if is_inside_tree():
			_fit_background()
			_sync_camera_layer()
var zoom := 1.0:
	set(value):
		zoom = value
		if is_inside_tree():
			_fit_background()
			_sync_camera_layer()
## The editor's own lighting switch (0.11): independent of the battle setting, toggled by
## the top-bar button, View menu or editor_lighting (Shift+L). Starts as the setting is.
var _lighting_preview := false
var _lighting_btn: Button
## Heightmap view (0.11.1): TerrainTiles.HEIGHT_SCALE over the tiles, View menu / Shift+H.
var _heightmap := false
var _height_btn: Button = null
var show_grid := true
var show_zones := true
var _mouse_panning := false
var _hover := Vector2i(-1, -1)

# --- Отрисовка ---
## Окружение карты, посчитанное один раз: у старых карт без пресета environment()
## выводит его обходом всей карты, и звать его на каждую клетку значило бы O(N²).
var _env := ""
var _grid: Grid = null
var _tiles: TerrainTiles = null
## Walking the map in first person (owner, fix-8 #17): pick a cell, then the 3D view.
var _fp_pick := false
var _fp: FirstPerson = null
var _fp_layer: CanvasLayer = null
var _fp_host: FirstPersonHost = null
var _layer: TerrainTiles.Layer = null
var _zone_img: Image = null
var _zone_tex: ImageTexture = null
var _zone_stale := false
## Номера зон на холсте: середина каждой зоны, пересчёт только когда зоны менялись.
var _zone_centers: Dictionary = {}
var _zone_centers_dirty := true
var _mini_img: Image = null
var _mini_tex: ImageTexture = null
var _mini_stale := false
## Спавны по клеткам — для отрисовки и пипетки без прохода по всему списку.
var _spawn_at: Dictionary = {}
## Счётчик правок карты: предпросмотр под курсором пересобирается, когда карта менялась.
var _map_ver := 0

# --- Откат ---
var _undo_stack: Array = []
var _redo_stack: Array = []
## Текущее действие: {"cells": {i: до}, "spawns": копия до или null}. Пусто — не пишем.
var _act: Dictionary = {}

# --- Перетаскивание, выделение, узоры ---
var _drag_start := Vector2i(-1, -1)
var _drag_cur := Vector2i(-1, -1)
var _stroke_last := Vector2i(-1, -1)
var _selection := Rect2i()
var _clipboard: Dictionary = {}
## Узор «в руке»: вставка, перенос выделения или заготовка. Ставится щелчком.
var _float: Dictionary = {}
var _float_grab := Vector2i.ZERO
## Узор держит перенос выделения: отпускание кнопки кладёт его.
var _float_moving := false

# --- Интерфейс ---
var _ui: CanvasLayer
var _modal: CanvasLayer = null
var _title_label: Label
var _status_label: Label
var _zoom_label: Label
var _size_slider: HSlider
var _size_value: Label
var _filled_check: CheckBox
var _sym_opt: OptionButton
var _tool_buttons: Dictionary = {}
var _tool_group := ButtonGroup.new()
var _brush_group := ButtonGroup.new()
var _brush_buttons: Dictionary = {}
var _palette_box: VBoxContainer
var _current_icon: TextureRect
var _current_label: Label
var _variant_row: HBoxContainer
var _set_row: HBoxContainer
var _set_label: Label
var _variant_icon: TextureRect
var _variant_label: Label
var _more_zones := false
var _mini_rect: TextureRect
var _mini_view: Control
var _menus: Dictionary = {}

func _ready() -> void:
	_lighting_preview = Ui.dynamic_lighting
	Keybinds.changed.connect(_refresh_shortcut_labels)
	Ui.board_settings_changed.connect(queue_redraw)
	Ui.board_settings_changed.connect(_sync_lighting)
	Sprites.reload_overrides()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Вернулись из пробной партии — та же карта, имя, взгляд и несохранённые правки.
	var s := MapHandoff.editor_session
	if not s.is_empty():
		map = s["map"]
		map_name = s["name"]
		_dirty = s["dirty"]
		pan = s["pan"]
		zoom = s["zoom"]
		MapHandoff.editor_session = {}
	else:
		map = MapData.new(DEFAULT_SIZE.x, DEFAULT_SIZE.y)
		MapPresets.prefill(map, "town")
	_build_sky()
	_build_ui()
	_map_replaced()
	if pan == Vector2.ZERO:
		_fit_view.call_deferred()
	_select_tool(Tool.BRUSH)
	_select_brush(MCF.FEATURE_WALL)
	set_process(true)

# ============================================================================
# Документ: замена карты, зеркало для плиток, миникарта, зоны
# ============================================================================

## Карта заменена целиком (новая, открытая, размер, очистка, откат снимка).
func _map_replaced() -> void:
	_env = map.environment()
	MCF.display_env = _env
	_sync_background()
	_grid = Grid.new(map.width, map.height)
	map.apply_to_grid(_grid)
	_tiles = TerrainTiles.new(_grid, _env)
	if _layer == null:
		_layer = TerrainTiles.Layer.new()
		_layer.origin = Vector2.ZERO
		_layer.cell_size = CELL
		add_child(_layer)
	_layer.tiles = _tiles
	_spawn_at.clear()
	for s: Dictionary in map.spawns:
		_spawn_at[s["coord"]] = s
	_zone_img = Image.create(map.width, map.height, false, Image.FORMAT_RGBA8)
	_mini_img = Image.create(map.width, map.height, false, Image.FORMAT_RGBA8)
	for i in map.width * map.height:
		var c := Vector2i(i % map.width, i / map.width)
		_zone_img.set_pixelv(c, _zone_color(map.zone_owner[i]))
		_mini_img.set_pixelv(c, map_color(map, i, _env))
	_zone_tex = ImageTexture.create_from_image(_zone_img)
	_mini_tex = ImageTexture.create_from_image(_mini_img)
	if _mini_rect != null:
		_mini_rect.texture = _mini_tex
	_zone_stale = false
	_mini_stale = false
	_zone_centers_dirty = true
	_selection = Rect2i()
	_float = {}
	_map_ver += 1
	_refresh_palette()
	_layout_minimap()
	_refresh_status()
	queue_redraw()

## Окружение сменилось — плитки и палитра в новом наряде, клетки те же.
func _env_changed() -> void:
	_env = map.environment()
	MCF.display_env = _env
	_sync_background()
	_tiles = TerrainTiles.new(_grid, _env)
	_layer.tiles = _tiles
	for i in map.width * map.height:
		_mini_img.set_pixelv(Vector2i(i % map.width, i / map.width), map_color(map, i, _env))
	_mini_stale = true
	_refresh_palette()
	_refresh_status()
	queue_redraw()

func _zone_color(owner: int) -> Color:
	if owner < 0:
		return Color(0, 0, 0, 0)
	var c := owner_color(owner)
	c.a = 0.34
	return c

static func owner_color(owner_id: int) -> Color:
	if MCF.is_neutral(owner_id):
		return Roster.NEUTRAL_COLOR
	if MCF.is_player(owner_id):
		return Roster.PALETTE[owner_id % Roster.PALETTE.size()]
	return Color.WHITE

## Тона миникарты по окружению — константами: словарь-литерал внутри map_color строился
## бы заново на каждую клетку.
const WALL_TONE := {"station": Color(0.42, 0.45, 0.5), "town": Color(0.5, 0.32, 0.26),
		"field": Color(0.45, 0.43, 0.38), "bunker": Color(0.38, 0.37, 0.35),
		"asteroid": Color(0.46, 0.36, 0.28)}
const FLOOR_TONE := {"station": Color(0.22, 0.24, 0.27), "town": Color(0.3, 0.29, 0.27),
		"field": Color(0.36, 0.3, 0.22), "bunker": Color(0.25, 0.25, 0.24),
		"asteroid": Color(0.33, 0.28, 0.24)}

## Тон пола комнаты (MCF.FLOOR_LOOKS) — средний цвет его плитки, как на холсте и на
## дальнем плане боя. Считается один раз; без картинок (headless) — пусто, тон окружения.
static var _look_tone: Array = []

static func look_tone(look: int) -> Variant:
	if _look_tone.is_empty():
		for n: String in MCF.FLOOR_LOOKS:
			var tex := Sprites.texture_of(n) if n != "" else null
			var img := tex.get_image() if tex != null else null
			if img == null or img.is_empty():
				_look_tone.append(null)
				continue
			if img.is_compressed():
				img.decompress()
			img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
			_look_tone.append(img.get_pixel(0, 0))
	return _look_tone[look] if look > 0 and look < _look_tone.size() else null

## Цвет клетки на миникарте и в превью открываемой карты: окружение задаёт тон стен и
## пола, зона подмешивается поверх.
static func map_color(m: MapData, i: int, env: String) -> Color:
	var col: Color
	var feat: String = m.feature_id[i]
	var tone: Variant = look_tone(m.get_look(i))
	if m.is_space[i] != 0:
		col = Color(0.03, 0.03, 0.07)
		if tone != null and m.get_look(i) == MCF.Look.SOLAR:
			col = tone
		elif m.get_look(i) == MCF.Look.GRILL:
			col = Color(0.26, 0.28, 0.30)   # мостки: сталь поверх пустоты (0.9.3)
	elif Furniture.is_furniture(feat):
		# Мебель (§3.15) — свой тёплый тон, высокая темнее: план комнат читается сразу.
		col = Color(0.40, 0.30, 0.22) if m.cover_height[i] >= MCF.WALL_HEIGHT \
				else Color(0.55, 0.42, 0.28)
	elif feat == MCF.FEATURE_BOUNDARY:
		# Граница мира (0.9.3) — не стена, а край карты: на миникарте показываем то, что
		# под ней (грунт бункера, трава, космос), чуть притушив.
		col = (Color(0.03, 0.03, 0.07) if m.is_space[i] != 0
				else FLOOR_TONE.get(env, Color(0.28, 0.28, 0.28))).darkened(0.35)
	elif m.cover_height[i] >= MCF.WALL_HEIGHT:
		col = WALL_TONE.get(env, Color(0.45, 0.42, 0.38))
		if MCF.is_glass(feat):
			col = Color(0.45, 0.65, 0.75)
		elif feat == MCF.FEATURE_AIRLOCK:
			col = Color(0.8, 0.65, 0.25)
		elif feat == MCF.FEATURE_WOOD_WALL:
			col = Color(0.55, 0.38, 0.2)
	else:
		# Объект виден и на траве: раньше трава проверялась первой, и окоп, мешки, ежи на
		# траве миникарта не показывала вовсе.
		col = Color(0.28, 0.45, 0.2) if m.floor_type[i] == MCF.FLOOR_GRASS \
				else FLOOR_TONE.get(env, Color(0.28, 0.28, 0.28))
		# Настил поверх пола (решётка) прозрачен — его средний цвет тоном не берём.
		if tone != null and m.floor_type[i] != MCF.FLOOR_GRASS \
				and not MCF.FLOOR_OVERLAY_LOOKS.has(m.get_look(i)):
			col = tone
		if m.winter and MapData.supports_winter(env) \
				and (m.floor_type[i] == MCF.FLOOR_GRASS or m.get_look(i) in [MCF.Look.DEFAULT, MCF.Look.GRASS]):
			col = Color(0.85, 0.89, 0.94)
		if feat == MCF.FEATURE_TRENCH:
			col = Color(0.2, 0.16, 0.12)
		elif feat != "":
			col = Color(0.62, 0.55, 0.35)
	var zo: int = m.zone_owner[i]
	if zo >= 0:
		col = col.lerp(owner_color(zo), 0.35)
	return col

# ============================================================================
# Правка клеток с записью отката
# ============================================================================

## Клетка карты кортежем: [пол, высота, космос, объект, зона, поворот мебели (−1 — сам),
## вид пола (MCF.FLOOR_LOOKS, 0 — пол окружения)].
func _tuple(i: int) -> Array:
	return [int(map.floor_type[i]), float(map.cover_height[i]), map.is_space[i] != 0,
			String(map.feature_id[i]), int(map.zone_owner[i]), map.get_turn(i), map.get_look(i), map.get_accent(i), map.get_door(i), map.fixtures.get(i, []).duplicate(true), map.get_tint(i)]

## Записать клетку: в карту, в зеркало плиток, в миникарту и слой зон.
func _write(i: int, t: Array) -> void:
	var fl := int(t[0])
	var cover := float(t[1])
	var sp := bool(t[2])
	var feat := String(t[3])
	var zone := int(t[4])
	var turn := int(t[5]) if t.size() > 5 and Furniture.is_furniture(feat) else -1
	var look := int(t[6]) if t.size() > 6 else 0
	var accent := int(t[7]) if t.size() > 7 else 0
	var door := int(t[8]) if t.size() > 8 else 0
	var fixture := MapData.valid_lamps(t[9]) if t.size() > 9 and cover >= MCF.WALL_HEIGHT and not MCF.is_glass(feat) and feat != MCF.FEATURE_AIRLOCK else []
	# The cell's light colour belongs to a standing lamp (0.11); wall lamps carry their own.
	var tint := int(t[10]) if t.size() > 10 and Furniture.emits_light(feat) else 0
	# Клетка уже такая — ни записи, ни отката: повторный мазок по тем же клеткам бесплатен.
	if map.floor_type[i] == fl and map.cover_height[i] == cover and (map.is_space[i] != 0) == sp \
			and map.feature_id[i] == feat and map.zone_owner[i] == zone and map.get_turn(i) == turn \
			and map.get_look(i) == look and map.get_accent(i) == accent and map.get_door(i) == door \
			and map.fixtures.get(i, []) == fixture and map.get_tint(i) == tint:
		return
	if _act.has("cells") and not _act["cells"].has(i):
		_act["cells"][i] = _tuple(i)
	_map_ver += 1
	map.floor_type[i] = fl
	map.cover_height[i] = cover
	map.is_space[i] = 1 if sp else 0
	map.feature_id[i] = feat
	if fixture.is_empty(): map.fixtures.erase(i)
	else: map.fixtures[i] = fixture
	var zone_changed := zone != map.zone_owner[i]
	map.zone_owner[i] = zone
	var turn_changed := map.get_turn(i) != turn
	map.set_turn(i, turn)
	var look_changed := map.get_look(i) != look
	map.set_look(i, look)
	var decor_changed := map.get_accent(i) != accent or map.get_door(i) != door or map.get_tint(i) != tint
	map.set_accent(i, accent)
	map.set_door(i, door)
	map.set_tint(i, tint)
	var x := i % map.width
	var y := i / map.width
	if decor_changed:
		_grid.wall_accent = map.wall_accent.duplicate()
		_grid.door_look = map.door_look.duplicate()
		_grid.light_tint = map.light_tint.duplicate()
		GridCell.log_look_change(x, y)
	if look_changed:
		if _grid.floor_look.is_empty():
			_grid.floor_look.resize(map.width * map.height)
		_grid.floor_look[i] = look
		GridCell.log_look_change(x, y)
	if turn_changed:
		if turn >= 0:
			_grid.furniture_turn[Vector2i(x, y)] = [feat, turn]
		else:
			_grid.furniture_turn.erase(Vector2i(x, y))
		GridCell.log_look_change(x, y)   # поворот — тоже вид: кусок плиток пересобрать
	# Зеркало плиток — только изменившиеся поля: у каждого сеттера GridCell свой журнал, и
	# лишний вызов на заливке в четверть миллиона клеток стоил больше самой правки.
	var gc := _grid.cell_fast(x, y)
	if gc.floor_type != fl:
		gc.floor_type = fl
	if gc.is_space != sp:
		gc.is_space = sp
	if gc.feature_id != feat:
		if feat != "":
			gc.set_feature(feat)
		else:
			gc.clear_feature()
	if gc.cover_height != cover:
		gc.cover_height = cover
	gc.lamps = fixture
	if zone_changed:
		_zone_img.set_pixel(x, y, _zone_color(int(t[4])))
		_zone_stale = true
		_zone_centers_dirty = true
	_mini_img.set_pixel(x, y, map_color(map, i, _env))
	_mini_stale = true

func _begin() -> void:
	_act = {"cells": {}, "spawns": null, "decals": map.decals.duplicate(true),
			"items": map.items.duplicate(true), "corpses": map.corpses.duplicate()}

## Спавны трогает действие — запомнить их «до» (один раз за действие).
func _touch_spawns() -> void:
	if _act.has("spawns") and _act["spawns"] == null:
		_act["spawns"] = _spawns_copy()

func _spawns_copy() -> Array:
	var out: Array = []
	for s: Dictionary in map.spawns:
		out.append(s.duplicate())
	return out

func _commit() -> void:
	if _act.is_empty():
		return
	_furnish_new_tables()
	var entry := {"cells": {}, "spawns": null}
	if _act.get("decals", map.decals) != map.decals:
		entry["decals"] = [_act["decals"], map.decals.duplicate(true)]
	if _act.get("items", map.items) != map.items:
		entry["items"] = [_act["items"], map.items.duplicate(true)]
	if _act.get("corpses", map.corpses) != map.corpses:
		entry["corpses"] = [_act["corpses"], map.corpses.duplicate()]
	for i: int in _act["cells"]:
		var before: Array = _act["cells"][i]
		var after := _tuple(i)
		if before != after:
			entry["cells"][i] = [before, after]
	if _act["spawns"] != null:
		entry["spawns"] = [_act["spawns"], _spawns_copy()]
	_act = {}
	if entry["cells"].is_empty() and entry["spawns"] == null and not entry.has("decals") \
			and not entry.has("items") and not entry.has("corpses"):
		return
	_push(entry)

func _push(entry: Dictionary) -> void:
	_undo_stack.append(entry)
	while _undo_stack.size() > UNDO_DEPTH:
		_undo_stack.pop_front()
	_redo_stack.clear()
	_mark_dirty()

## Действие целиком снимком: размер, очистка. before — map.to_dict() до правки.
func _push_full(before: Dictionary) -> void:
	_push({"full": [before, map.to_dict()]})

func _apply_entry(entry: Dictionary, forward: bool) -> void:
	var k := 1 if forward else 0
	if entry.has("full"):
		map = MapData.from_dict(entry["full"][k])
		_map_replaced()
		return
	if entry.has("env"):
		map.env = entry["env"][k]
		_env_changed()
		return
	if entry.has("time"):
		map.time_of_day = entry["time"][k]
		_sync_lighting()
		_refresh_menu_checks()
		return
	if entry.has("winter"):
		map.winter = entry["winter"][k]
		_winter_changed()
		return
	if entry.has("overcast"):
		map.overcast = entry["overcast"][k]
		_refresh_menu_checks()
		return
	if entry.has("decals"):
		map.decals = entry["decals"][k].duplicate(true)
		_sync_editor_decals()
	if entry.has("items"):
		map.items = entry["items"][k].duplicate(true)
		_sync_editor_items()
	if entry.has("corpses"):
		map.corpses = entry["corpses"][k].duplicate()
		_mark_dirty()
		queue_redraw()
	for i: int in entry["cells"]:
		_write(i, entry["cells"][i][k])
	if entry["spawns"] != null:
		map.spawns = []
		for s: Dictionary in entry["spawns"][k]:
			map.spawns.append(s.duplicate())
		_spawn_at.clear()
		for s: Dictionary in map.spawns:
			_spawn_at[s["coord"]] = s
	queue_redraw()

func undo() -> void:
	if _undo_stack.is_empty():
		return
	var e: Dictionary = _undo_stack.pop_back()
	_apply_entry(e, false)
	_redo_stack.append(e)
	_mark_dirty()
	_flash("Undo")

func redo() -> void:
	if _redo_stack.is_empty():
		return
	var e: Dictionary = _redo_stack.pop_back()
	_apply_entry(e, true)
	_undo_stack.append(e)
	_mark_dirty()
	_flash("Redo")

func _set_spawn(c: Vector2i, id: String, owner: int) -> void:
	_touch_spawns()
	_clear_spawn(c)
	var s := {"stats_id": id, "owner": owner, "coord": c, "facing": Vector2i.ZERO}
	map.spawns.append(s)
	_spawn_at[c] = s
	# A unit placed on bodies clears them: nobody stands on a body.
	var ci := c.y * map.width + c.x
	if map.corpses.has(ci):
		var kept := PackedInt32Array()
		for q: int in map.corpses:
			if q != ci: kept.append(q)
		map.corpses = kept

func _clear_spawn(c: Vector2i) -> void:
	if not _spawn_at.has(c):
		return
	_touch_spawns()
	map.spawns.erase(_spawn_at[c])
	_spawn_at.erase(c)

# ============================================================================
# Симметрия
# ============================================================================

## Отражения, в которые уходит каждая правка: маска (бит 1 — по X, бит 2 — по Y).
func _sym_masks() -> Array[int]:
	match symmetry:
		Sym.X: return [0, 1]
		Sym.Y: return [0, 2]
		Sym.QUAD: return [0, 1, 2, 3]
	return [0]

func _mirror(c: Vector2i, mask: int) -> Vector2i:
	return Vector2i(map.width - 1 - c.x if mask & 1 else c.x,
			map.height - 1 - c.y if mask & 2 else c.y)

## Чья зона/боец в отражении: при зеркале на двоих — соседняя пара (0↔1, 2↔3…), при
## четырёх четвертях — номер с той же маской (0→1 по X, 0→2 по Y, 0→3 по обеим). Так
## зеркальная карта сразу делится между игроками поровну. Нейтралы остаются нейтралами.
func _mirror_owner(owner: int, mask: int) -> int:
	if mask == 0 or not MCF.is_player(owner):
		return owner
	var k := mask if symmetry == Sym.QUAD else 1
	var o := owner ^ k
	return o if o < MCF.MAX_PLAYERS else owner

# ============================================================================
# Кисть
# ============================================================================

## Клетки квадратной кисти вокруг c (brush_size×brush_size).
func _brush_cells(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var r0 := -(brush_size - 1) / 2
	var r1 := brush_size / 2
	for dy in range(r0, r1 + 1):
		for dx in range(r0, r1 + 1):
			out.append(c + Vector2i(dx, dy))
	return out

## Нанести кисть (или ластик) на набор клеток со всеми отражениями.
func _paint_cells(cells: Array, erase: bool) -> void:
	var masks := _sym_masks()
	var done := {}
	var dedupe := masks.size() > 1   # без симметрии клетки и так свои — словарь не нужен
	for mask: int in masks:
		for c: Vector2i in cells:
			var m := c if mask == 0 else _mirror(c, mask)
			if not map.in_bounds(m):
				continue
			if dedupe:
				if done.has(m):
					continue
				done[m] = true
			if erase:
				if tool == Tool.SELECT and map.fixtures.has(m.y * map.width + m.x):
					var i := m.y * map.width + m.x
					var t := _tuple(i)
					t[9] = []
					_write(i, t)
				_erase_cell(m)
			else:
				_brush_cell(m, mask)
	queue_redraw()

## Ластик снимает ВЕРХНЕЕ (0.9.4): сперва объект на клетке — и ТОЛЬКО его, не трогая пол
## под ним («deleting a wall in the map editor shouldn\'t also delete the floor beneath it»),
## а снятая стена оставляет и материал (вид клетки), чтобы на её место легла такая же.
## Нет объекта — убирается боец; нет и его — клетка возвращается к пустой земле пресета
## (пол, вид, зона). Прежде один щелчок сносил сразу всё.
func _erase_cell(c: Vector2i) -> void:
	if not map.corpses.is_empty():
		var ci := c.y * map.width + c.x
		var kept_bodies := PackedInt32Array()
		for q: int in map.corpses:
			if q != ci:
				kept_bodies.append(q)
		if kept_bodies.size() != map.corpses.size():
			map.corpses = kept_bodies
			_mark_dirty()
	if not map.items.is_empty():
		var left := map.items.filter(func(it: Array) -> bool: return SmallItems.cell_of(it) != c)
		if left.size() != map.items.size():
			map.items = left
			_sync_editor_items()
	if not map.decals.is_empty():
		var kept := map.decals.filter(func(d: Array) -> bool:
			return Vector2i(floori(float(d[1])), floori(float(d[2]))) != c)
		if kept.size() != map.decals.size():
			map.decals = kept
			_sync_editor_decals()
	var i := c.y * map.width + c.x
	if map.fixtures.has(i):
		var t := _tuple(i)
		t[9] = []
		_write(i, t)
		return
	if map.feature_id[i] != "":
		var t := _tuple(i)
		t[3] = ""
		t[1] = 0.0
		t[5] = -1
		_write(i, t)
		return
	if _spawn_at.has(c):
		_clear_spawn(c)
		return
	var b := MapPresets.blank_cell(_env)
	_write(i, [b[0], b[1], b[2], b[3], -1])
	_clear_spawn(c)

func _brush_cell(c: Vector2i, mask: int) -> void:
	var i := c.y * map.width + c.x
	if brush.begins_with("unit:"):
		_set_spawn(c, brush.substr(5), MCF.Owner.NEUTRAL)
	elif brush == "space":
		_clear_spawn(c)
	_write(i, _brushed(_tuple(i), mask, i))

## Какой станет клетка t (кортеж _tuple) под кистью в отражении mask — без записи: этим же
## рисуется предпросмотр под курсором.
func _brushed(t: Array, mask: int, i: int = -1) -> Array:
	t = t.duplicate()
	while t.size() < 9:
		t.append(-1 if t.size() == 5 else 0)
	if t.size() < 10: t.append([])
	if Furniture.is_wall_light(brush):
		if float(t[1]) >= MCF.WALL_HEIGHT and not MCF.is_glass(str(t[3])) and str(t[3]) != MCF.FEATURE_AIRLOCK:
			# One lamp per side (0.11): the brush hangs it on the side R picked (or the
			# wall's open side), and lamps on the other sides stay.
			var side := mirror_turn(brush_turn, mask) if brush_turn >= 0 else _auto_lamp_side(i)
			var lamps := MapData.valid_lamps(t[9])
			var old := MapData.lamp_on(lamps, side)
			var tint := int(old[3]) if not old.is_empty() and str(old[0]) == brush else 0
			t[9] = MapData.with_lamp(lamps, [brush, Furniture.durability_of(brush), side, tint])
		return t
	if brush.begins_with("accent:"):
		t[7] = int(brush.substr(7))
	elif brush.begins_with("door:"):
		t[3] = MCF.FEATURE_AIRLOCK
		t[1] = MCF.WALL_HEIGHT
		t[2] = false
		t[8] = int(brush.substr(5))
	elif brush.begins_with("zone:"):
		t[4] = _mirror_owner(int(brush.substr(5)), mask)
	elif brush.begins_with("unit:"):
		t[2] = false
	elif brush.begins_with("floor:"):
		var lk := int(brush.substr(6))
		t[0] = MCF.FLOOR_NORMAL
		t[2] = SPACE_LOOK_BRUSHES.has(lk)
		t = _with_look(t, lk)
	elif brush.begins_with("wallmat:"):
		# Стена с материалом (0.9.4): объект — обычная стена, вид клетки называет облик.
		t[3] = MCF.FEATURE_WALL
		t[1] = MCF.WALL_HEIGHT
		t[2] = false
		t = _with_look(t, MCF.wall_look(int(brush.substr(8))))
	else:
		match brush:
			"floor":
				t[0] = MCF.FLOOR_NORMAL
				t[2] = false
				t = _with_look(t, 0)
			"grass":
				t[0] = MCF.FLOOR_GRASS
				t[2] = false
				t = _with_look(t, 0)
			"space":
				t[2] = true
				t[3] = ""
				t[1] = 0.0
				t = _with_look(t, 0)
			"clear_object":
				t[3] = ""
				t[1] = 0.0
			_:
				# Ёж на мешки и мешки на мешки складываются (0.12.2, item 25) — той же
				# таблицей, по которой их складывают бойцы в бою.
				var stacked := MCF.stacked(String(t[3]), brush)
				t[3] = stacked if stacked != "" else brush
				t[1] = maxf(0.0, MCF.feature_height(String(t[3])))
				t[2] = false
				if t.size() < 6:
					t.append(-1)
				t[5] = mirror_turn(brush_turn, mask) if Furniture.is_furniture(String(t[3])) else -1
	if _wall_brush(): t[7] = brush_accent
	if brush == MCF.FEATURE_AIRLOCK: t[8] = brush_door
	if float(t[1]) < MCF.WALL_HEIGHT or str(t[3]) == MCF.FEATURE_AIRLOCK or MCF.is_glass(str(t[3])): t[9] = []
	return t

## Кортеж с видом пола (7-й элемент дописывается, если его нет).
static func _with_look(t: Array, look: int) -> Array:
	while t.size() < 7:
		t.append(-1 if t.size() == 5 else 0)
	t[6] = look
	return t

## Поворот в отражении симметрии: по X меняются восток и запад, по Y — север и юг.
static func mirror_turn(k: int, mask: int) -> int:
	if k < 0:
		return k
	if mask & 1 and k % 2 == 1:
		k = 4 - k
	if mask & 2 and k % 2 == 0:
		k = 2 - k
	return k

## Кисть с большим радиусом: ВСЕ клетки отрезка от прошлой до текущей — быстрый мазок
## мышью не оставляет пропусков.
func _stroke_to(c: Vector2i, erase: bool) -> void:
	var from := _stroke_last if _stroke_last != Vector2i(-1, -1) else c
	var cells: Array = []
	for p: Vector2i in line_cells(from, c):
		cells.append_array(_brush_cells(p))
	_paint_cells(cells, erase)
	_stroke_last = c

static func line_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var x := a.x
	var y := a.y
	while true:
		cells.append(Vector2i(x, y))
		if x == b.x and y == b.y:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy
	return cells

static func rect_cells(a: Vector2i, b: Vector2i, filled: bool) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			if filled or x == a.x or x == b.x or y == a.y or y == b.y:
				cells.append(Vector2i(x, y))
	return cells

## Круг (овал), вписанный в прямоугольник a–b. Контур — клетки круга, у которых хоть
## один сосед по стороне снаружи: линия без дыр и без двойной толщины.
static func ellipse_cells(a: Vector2i, b: Vector2i, filled: bool) -> Array[Vector2i]:
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	var c := (Vector2(lo) + Vector2(hi)) * 0.5
	var r := (Vector2(hi - lo) + Vector2.ONE) * 0.5
	var inside := func(x: int, y: int) -> bool:
		var d := Vector2((x - c.x) / r.x, (y - c.y) / r.y)
		return d.length_squared() <= 1.0
	var cells: Array[Vector2i] = []
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if not inside.call(x, y):
				continue
			if filled or not (inside.call(x + 1, y) and inside.call(x - 1, y)
					and inside.call(x, y + 1) and inside.call(x, y - 1)):
				cells.append(Vector2i(x, y))
	return cells

## Заливка связной области одинаковых клеток (пол, высота, космос, объект). Волна по
## плоским индексам с байтовой отметкой — заливка поля 500×500 не подвисает.
func _flood(start: Vector2i, erase: bool) -> void:
	if not map.in_bounds(start):
		return
	var w := map.width
	var si := start.y * w + start.x
	var target := _tuple(si)
	var seen := PackedByteArray()
	seen.resize(w * map.height)
	var stack := PackedInt32Array([si])
	var region: Array = []
	while not stack.is_empty():
		var i: int = stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		if seen[i] != 0:
			continue
		seen[i] = 1
		if map.floor_type[i] != target[0] or map.cover_height[i] != target[1] \
				or (map.is_space[i] != 0) != target[2] or map.feature_id[i] != target[3] \
				or map.get_look(i) != target[6]:
			continue
		var x := i % w
		var y := i / w
		region.append(Vector2i(x, y))
		if x + 1 < w: stack.append(i + 1)
		if x > 0: stack.append(i - 1)
		if y + 1 < map.height: stack.append(i + w)
		if y > 0: stack.append(i - w)
	_paint_cells(region, erase)

# ============================================================================
# Узоры: вставка, перенос, заготовки
# ============================================================================

## Поставить узор p левым верхним углом в at — со всеми отражениями симметрии.
func _place_pattern(p: Dictionary, at: Vector2i) -> void:
	for mask: int in _sym_masks():
		var q := p
		if mask & 1:
			q = MapPresets.flipped(q, true)
		if mask & 2:
			q = MapPresets.flipped(q, false)
		var pos := at
		if mask & 1:
			pos.x = map.width - at.x - int(q["w"])
		if mask & 2:
			pos.y = map.height - at.y - int(q["h"])
		_stamp_once(q, pos, mask)
	queue_redraw()

func _stamp_once(p: Dictionary, at: Vector2i, mask: int) -> void:
	var w: int = p["w"]
	for y in int(p["h"]):
		for x in w:
			var cell: Variant = p["cells"][y * w + x]
			var c := at + Vector2i(x, y)
			if cell == null or not map.in_bounds(c):
				continue
			var i := c.y * map.width + c.x
			var t: Array = (cell as Array).duplicate()
			t[4] = map.zone_owner[i] if int(t[4]) == MapPresets.KEEP else _mirror_owner(int(t[4]), mask)
			_write(i, t)   # узор уже отражён целиком (_place_pattern), поворот — вместе с ним
			_clear_spawn(c)
	for s: Array in p["spawns"]:
		var c := at + Vector2i(int(s[0]), int(s[1]))
		if map.in_bounds(c):
			_set_spawn(c, String(s[2]), _mirror_owner(int(s[3]), mask))

	if p.has("corpses"):
		var kept := PackedInt32Array()
		var area := Rect2i(at, Vector2i(p["w"], p["h"]))
		for ci: int in map.corpses:
			if not area.has_point(Vector2i(ci % map.width, ci / map.width)): kept.append(ci)
		map.corpses = kept
		for body: Array in p["corpses"]:
			var c := at + Vector2i(int(body[0]), int(body[1]))
			if map.in_bounds(c) and not _spawn_at.has(c): map.corpses.append(c.y * map.width + c.x)
	for d: Array in p.get("decals", []):
		var pos := Vector2(float(d[1]), float(d[2])) + Vector2(at)
		if Rect2(0, 0, map.width, map.height).has_point(pos):
			map.decals.append([d[0], pos.x, pos.y, d[3], d[4]])
	_sync_editor_decals()
	if p.has("items"):
		var area := Rect2(Vector2(at), Vector2(int(p["w"]), int(p["h"])))
		map.items = map.items.filter(func(it: Array) -> bool: return not area.has_point(Vector2(float(it[1]), float(it[2]))))
		for it: Array in p["items"]:
			var pos := Vector2(float(it[1]), float(it[2])) + Vector2(at)
			if map.in_bounds(Vector2i(pos.floor())):
				map.items.append([it[0], pos.x, pos.y, it[3]])
		_sync_editor_items()

func copy_selection() -> void:
	if not _has_selection():
		return
	_clipboard = MapPresets.capture(map, _selection)
	_flash("Copied %d×%d" % [_selection.size.x, _selection.size.y])

func cut_selection() -> void:
	if not _has_selection():
		return
	copy_selection()
	delete_selection()

func delete_selection() -> void:
	if not _has_selection():
		return
	_begin()
	var cells: Array = []
	for y in range(_selection.position.y, _selection.end.y):
		for x in range(_selection.position.x, _selection.end.x):
			cells.append(Vector2i(x, y))
	_paint_cells(cells, true)
	_commit()

func paste() -> void:
	if _clipboard.is_empty():
		_flash("Nothing to paste - copy a selection first")
		return
	if tool != Tool.SELECT:
		_select_tool(Tool.SELECT)
	_float = _clipboard.duplicate(true)
	_float_grab = Vector2i(int(_float["w"]) / 2, int(_float["h"]) / 2)
	_float_moving = false
	_refresh_status()
	queue_redraw()

func _has_selection() -> bool:
	return _selection.size.x > 0 and _selection.size.y > 0

## Поднять выделение «в руку» для переноса: на месте остаётся пустая земля пресета.
func _lift_selection(grab: Vector2i) -> void:
	_begin()
	_float = MapPresets.capture(map, _selection)
	var cells: Array = []
	for y in range(_selection.position.y, _selection.end.y):
		for x in range(_selection.position.x, _selection.end.x):
			cells.append(Vector2i(x, y))
	var sym := symmetry
	symmetry = Sym.OFF   # подъём — только самого выделения, без отражений
	_paint_cells(cells, true)
	symmetry = sym
	_float_grab = grab - _selection.position
	_float_moving = true

func _drop_float(at_cursor: Vector2i) -> void:
	if _float.is_empty():
		return
	if _act.is_empty():
		_begin()
	var at := at_cursor - _float_grab
	# Перенос — только самого выделения: его и подняли без отражений.
	var sym := symmetry
	if _float_moving:
		symmetry = Sym.OFF
	_place_pattern(_float, at)
	symmetry = sym
	_commit()
	if _float_moving or tool != Tool.STAMP:
		_selection = Rect2i(at, Vector2i(int(_float["w"]), int(_float["h"]))).intersection(
				Rect2i(Vector2i.ZERO, Vector2i(map.width, map.height)))
		_float = {}
		_float_moving = false
	queue_redraw()

## R (0.9.2): поворачивает то, что сейчас «в руке». Узор (вставка, перенос, заготовка) —
## на четверть; выделение без узора — вместе с содержимым на месте; кисть мебели —
## следующий поворот (Shift+R — снова «сам, к стене»).
##
## 0.9.4: а если в руке НЕ мебель (ластик, пипетка, кисть стены), R разворачивает предмет
## ПОД КУРСОРОМ — стоящий на карте диван больше не нужно выделять или класть заново.
var decal_rotation := 0.0
## Мелкие предметы (0.12.1): угол следующего, шаг R — 15° (их кладут под любым углом), и
## набор, которым кисть стола раскладывает предметы ("" — набор этого стола по умолчанию).
var item_rotation := 0.0
const ITEM_TURN := PI / 12
const ITEM_ERASE := "item:erase"
const CORPSE_BRUSH := "corpse_body"
var brush_table_set := ""
var _decal_painting := false
var _decal_last := Vector2.INF
var brush_accent := 0
var brush_door := 0

func rotate_key(back_to_auto: bool = false) -> void:
	if not _float.is_empty():
		rotate_float()
	elif tool == Tool.SELECT and _has_selection():
		rotate_selection()
	elif brush.begins_with("decal:"):
		decal_rotation = 0.0 if back_to_auto else fposmod(decal_rotation + PI / 2, TAU)
		queue_redraw()
	elif brush.begins_with("item:"):
		item_rotation = 0.0 if back_to_auto else fposmod(item_rotation + ITEM_TURN, TAU)
		_flash("%s turned to %d°" % [_brush_name(brush), roundi(rad_to_deg(item_rotation))])
		queue_redraw()
	elif Furniture.is_wall_light(brush):
		brush_turn = -1 if back_to_auto else (brush_turn + 1) % 4
		_flash("%s goes on the %s" % [_brush_name(brush),
				"open side of the wall (auto)" if brush_turn < 0 else SIDE_NAMES[brush_turn] + " side of the wall"])
		_refresh_status()
		queue_redraw()
	elif Furniture.is_furniture(brush):
		if back_to_auto:
			brush_turn = -1
		elif brush_turn < 0:
			brush_turn = (maxi(0, _pv_auto_turn) + 1) % 4
		else:
			brush_turn = (brush_turn + 1) % 4
		_flash("%s faces %s" % [_brush_name(brush), turn_name(brush_turn)])
		_refresh_status()
	elif _rotate_hovered(back_to_auto):
		pass   # под курсором стоит предмет — развернули ЕГО (0.9.4)
	else:
		_flash("R turns the piece under the cursor, a selection, or the furniture brush")

## R НАД УЖЕ ПОСТАВЛЕННЫМ предметом (0.9.4) разворачивает ЕГО, а не кисть: игрок жаловался,
## что «object orientation calculation in the map editor is extremely clunky» — развернуть
## стоящий диван можно было только выделением или перекладкой заново. Цельный предмет
## (кровать, стол) поворачивается ЦЕЛИКОМ, одной записью отката. Shift+R возвращает клетке
## поворот «сам, к стене». false — под курсором не мебель, и R работает как прежде.
func _rotate_hovered(back_to_auto: bool) -> bool:
	if not map.in_bounds(_hover):
		return false
	var i := _hover.y * map.width + _hover.x
	if map.fixtures.has(i):
		# The lamp nearest the cursor moves to the next free side of its wall.
		var side := _hover_lamp_side(i)
		var lamps: Array = map.fixtures[i]
		var rec := MapData.lamp_on(lamps, side).duplicate()
		var to := _auto_lamp_side(i) if back_to_auto else -1
		for step in range(1, 4):
			if to >= 0: break
			if MapData.lamp_on(lamps, (side + step) % 4).is_empty(): to = (side + step) % 4
		if to < 0 or to == side or not MapData.lamp_on(lamps, to).is_empty(): return true
		rec[2] = to
		_begin()
		var t := _tuple(i)
		t[9] = MapData.with_lamp(MapData.without_lamp(lamps, side), rec)
		_write(i, t)
		_commit()
		_flash("%s moved to the %s side" % [Furniture.DEFS[str(rec[0])].name, SIDE_NAMES[to]])
		_sync_lighting()
		queue_redraw()
		return true
	var fid := String(map.feature_id[i])
	if not Furniture.is_furniture(fid):
		return false
	var cells := Furniture.piece_cells(func(q: Vector2i) -> String:
		return String(map.feature_id[q.y * map.width + q.x]) if map.in_bounds(q) else "", _hover)
	var k := -1
	if not back_to_auto:
		var now := map.get_turn(i)
		k = (TerrainTiles.furniture_turn(_grid, _hover, fid) + 1) % 4 if now < 0 else (now + 1) % 4
	_begin()
	for q in cells:
		var qi := q.y * map.width + q.x
		var t := _tuple(qi)
		t[5] = k
		_write(qi, t)
	_commit()
	_flash("%s faces %s" % [_brush_name(fid), turn_name(k)])
	queue_redraw()
	return true

const SIDE_NAMES := ["top", "right", "bottom", "left"]

## The side a lamp brush picks by itself: the first open face of the wall without a lamp,
## so a lamp painted along a corridor wall hangs into the corridor.
func _auto_lamp_side(i: int) -> int:
	if i < 0 or map == null: return 2
	var c := Vector2i(i % map.width, i / map.width)
	var lamps: Array = map.fixtures.get(i, [])
	var fallback := -1
	for k in 4:
		var q: Vector2i = c + Furniture.N4[k]
		if not map.in_bounds(q): continue
		var qi := q.y * map.width + q.x
		if map.cover_height[qi] >= MCF.WALL_HEIGHT or map.is_space[qi] != 0: continue
		if MapData.lamp_on(lamps, k).is_empty(): return k
		if fallback < 0: fallback = k
	return fallback if fallback >= 0 else 2

## Of the lamps on wall cell i, the one on the face nearest the mouse; -1: none.
func _hover_lamp_side(i: int) -> int:
	var lamps: Array = map.fixtures.get(i, [])
	if lamps.is_empty(): return -1
	var c := Vector2i(i % map.width, i / map.width)
	var f := (get_viewport().get_mouse_position() - pan) / cell_size() - Vector2(c)
	var best := int(lamps[0][2])
	for rec: Array in lamps:
		var face := Vector2(0.5, 0.5) + Vector2(Furniture.N4[int(rec[2])]) * 0.5
		if f.distance_to(face) < f.distance_to(Vector2(0.5, 0.5) + Vector2(Furniture.N4[best]) * 0.5):
			best = int(rec[2])
	return best

static func turn_name(k: int) -> String:
	return "the nearest wall (auto)" if k < 0 else ["up", "right", "down", "left"][k % 4]

## Повернуть выделение на месте (вокруг его середины), одной записью отката: предмет
## мебели разворачивается целиком — и следом, и спинкой.
func rotate_selection() -> void:
	if not _has_selection():
		return
	var center := _selection.position + _selection.size / 2
	_lift_selection(center)
	_float = MapPresets.rotated(_float)
	_float_grab = Vector2i(int(_float["w"]) / 2, int(_float["h"]) / 2)
	_drop_float(center)
	_flash("Rotated the selection")

func rotate_float() -> void:
	if _float.is_empty():
		return
	_float = MapPresets.rotated(_float)
	_float_grab = Vector2i(int(_float["w"]) / 2, int(_float["h"]) / 2)
	queue_redraw()

func flip_float(horizontal: bool) -> void:
	if _float.is_empty():
		return
	_float = MapPresets.flipped(_float, horizontal)
	queue_redraw()

func _pick_stamp(id: String) -> void:
	stamp_id = id
	_float = MapPresets.stamp(id)
	_float_grab = Vector2i(int(_float["w"]) / 2, int(_float["h"]) / 2)
	_float_moving = false
	_select_tool(Tool.STAMP, true)
	for sid in _brush_buttons:
		if sid == "stamp:" + id:
			(_brush_buttons[sid] as Button).button_pressed = true

# ============================================================================
# Пипетка
# ============================================================================

func pick_at(c: Vector2i) -> void:
	if not map.in_bounds(c):
		return
	var i := c.y * map.width + c.x
	if _spawn_at.has(c) and MCF.is_neutral(int(_spawn_at[c]["owner"])):
		_select_brush("unit:" + String(_spawn_at[c]["stats_id"]))
	elif map.feature_id[i] != "":
		brush_accent = map.get_accent(i)
		brush_door = map.get_door(i)
		# Стена с материалом (0.9.4) берётся вместе с ним — пипетка даёт ту же стену.
		if map.feature_id[i] == MCF.FEATURE_WALL and MCF.wall_look_tile(map.get_look(i)) != "":
			_select_brush("wallmat:%d" % (map.get_look(i) - MCF.WALL_LOOK_BASE))
			return
		_select_brush(String(map.feature_id[i]))
		brush_turn = map.get_turn(i)
	elif map.is_space[i] != 0:
		_select_brush("space")
	elif map.floor_type[i] == MCF.FLOOR_GRASS:
		_select_brush("grass")
	elif map.get_look(i) > 0:
		_select_brush("floor:%d" % map.get_look(i))
	else:
		_select_brush("floor")

# ============================================================================
# Ввод
# ============================================================================

## Небо за холстом (0.9.3): клетка космоса ничего не рисует, и под ней виден параллакс
## звёзд — ровно то, что игрок увидит в бою. Здесь оно есть всегда: редактор начинает
## с пустой карты, то есть со сплошного космоса, и «пусто» обязано читаться как пусто.
var _sky: Starfield = null
var _ground: GroundBackdrop = null

func _sync_background() -> void:
	if not is_inside_tree():
		return
	if _ground == null:
		_ground = GroundBackdrop.new()
		_ground.z_index = -20
		add_child(_ground)
	_ground.texture = GroundBackdrop.wallpaper(_env, map != null and map.winter) if _env in ["town", "field", "bunker"] else null
	_ground.visible = _ground.texture != null
	_fit_background()

func _fit_background() -> void:
	if _sky != null:
		_sky.camera = pan
	if _ground == null or _ground.texture == null or map == null:
		return
	var pixels := float(_ground.texture.get_height()) / GroundBackdrop.GROUND_TILES
	_ground.fit_view(pan, zoom * CELL / pixels, Vector2(map.width, map.height) * pixels,
			get_viewport_rect().size)


func _build_sky() -> void:
	var layer := CanvasLayer.new()
	layer.layer = -10
	add_child(layer)
	_sky = Starfield.new()
	_sky.drift = false
	layer.add_child(_sky)

var _lighting: LightManager

## Время суток (0.12.1) видно и без предпросмотра света — ровным оттенком, как в бою.
var _time_mod: CanvasModulate = null
func _sync_time_tint() -> void:
	var tint := Color.WHITE if _lighting_preview or map == null else LightManager.flat_tint(_env, map.time_of_day)
	if tint == Color.WHITE:
		if is_instance_valid(_time_mod):
			_time_mod.queue_free()
		_time_mod = null
		return
	if not is_instance_valid(_time_mod):
		_time_mod = CanvasModulate.new()
		add_child(_time_mod)
	_time_mod.color = tint

func _sync_lighting() -> void:
	if _tiles != null and _tiles.set_time_of_day(map.time_of_day if map != null else ""): queue_redraw()
	if _tiles != null and map != null and _tiles.set_winter(map.winter and MapData.supports_winter(map.environment())): queue_redraw()
	_sync_time_tint()
	if not _lighting_preview:
		if is_instance_valid(_lighting):
			_lighting.free()
			_lighting = null
		return
	if _grid == null: return
	if not is_instance_valid(_lighting):
		_lighting = LightManager.new()
		add_child(_lighting)
	_lighting.update_view(_grid, pan, zoom, Vector2.ZERO, CELL, _env, {}, false, null, _layer,
			-1.0, map.time_of_day if map != null else "")

func _process(delta: float) -> void:
	if _fp != null:
		return   # WASD walk the first-person view, they don't pan the map
	# Куски плиток собираются по нескольку за кадр: пока бюджет кадра выбран до дна,
	# перерисовываемся, иначе часть карты осталась бы в грубом разрешении до первого жеста.
	if _tiles != null and _tiles._built >= TerrainTiles.BUILDS_PER_FRAME:
		queue_redraw()
	if _sky != null:
		_sky.camera = pan
	if _modal != null or Keybinds.modal_open() or _menu_popup_open():
		_sync_lighting()
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		_sync_lighting()
		return
	var dir := Vector2.ZERO
	if Keybinds.down("editor_pan_up"): dir.y += 1
	if Keybinds.down("editor_pan_down"): dir.y -= 1
	if Keybinds.down("editor_pan_left"): dir.x += 1
	if Keybinds.down("editor_pan_right"): dir.x -= 1
	if dir != Vector2.ZERO:
		pan += dir.normalized() * PAN_SPEED * delta
		queue_redraw()
	_sync_lighting()

func _unhandled_input(event: InputEvent) -> void:
	if Keybinds.modal_open() or _fp != null: return
	if _fp_pick:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_start_first_person(cell_at(event.position))
			get_viewport().set_input_as_handled()
			return
		if event is InputEventKey and event.pressed and Keybinds.matches(event, "editor_cancel"):
			_fp_pick = false
			_refresh_status()
			get_viewport().set_input_as_handled()
			return
	if _modal != null:
		if event is InputEventKey and event.pressed and Keybinds.matches(event, "editor_cancel"):
			_close_modal()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var viewport := get_viewport()
		if _shortcut(event):
			viewport.set_input_as_handled()
		return
	# Right-click (a two-finger click on a Mac touchpad) or Ctrl+click on a lamp opens its
	# colour menu (0.11); a right-drag still pans.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed \
			and event.ctrl_pressed and _open_light_menu(event.position):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_right_press = event.position
		elif event.position.distance_to(_right_press) < 6.0 and _open_light_menu(event.position):
			_mouse_panning = false
			return
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		_mouse_panning = event.pressed
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		zoom_at(event.position, 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
		return
	if event is InputEventPanGesture:
		pan -= event.delta * 24.0
		queue_redraw()
		return
	if event is InputEventMagnifyGesture:
		zoom_at(event.position, event.factor)
		return
	if event is InputEventMouseMotion:
		if _mouse_panning:
			pan += event.relative
			queue_redraw()
			return
		if brush.begins_with("item:") and tool == Tool.BRUSH:
			queue_redraw()
			if _decal_painting and brush == ITEM_ERASE and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				_erase_items((event.position - pan) / cell_size())
		if brush.begins_with("decal:") and tool == Tool.BRUSH:
			queue_redraw()
			if _decal_painting:
				if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
					_paint_decal((event.position - pan) / cell_size())
				else:
					_decal_painting = false
					_commit()
			return
		var hc := cell_at(event.position)
		if hc != _hover:
			_hover = hc
			_refresh_status()
			queue_redraw()
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_drag_to(hc)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var c := cell_at(event.position)
		if event.pressed:
			_press(c, event.alt_pressed, event.position)
		else:
			_release(c)

func _press(c: Vector2i, alt: bool, screen := Vector2.INF) -> void:
	# Мелкий предмет (0.12.1): щелчок кладёт один ровно под курсор, под углом item_rotation;
	# «Erase items» стирает их кистью, как ластик декалей. Действие закрывает _release().
	# Тело на клетку (0.12.2): щелчок кладёт одно, до CORPSE_WALL_COUNT в стопке.
	if brush == CORPSE_BRUSH and tool == Tool.BRUSH and map.in_bounds(c) and not alt:
		_begin()
		_decal_painting = true
		var ci := c.y * map.width + c.x
		var here := 0
		for q: int in map.corpses:
			here += 1 if q == ci else 0
		if _spawn_at.has(c):
			_flash("A unit stands here - bodies can't be placed on it")
		elif here < MCF.CORPSE_WALL_COUNT:
			map.corpses.append(ci)
			_mark_dirty()
		else:
			_flash("Five bodies already lie here")
		queue_redraw()
		return
	if brush.begins_with("item:") and tool == Tool.BRUSH and map.in_bounds(c) and not alt:
		_begin()
		# Тот же флаг, что у декалей: пока он поднят, протяжка не красит клетки (0.12.2).
		# Без него один сдвиг мыши с зажатой кнопкой закрашивал стол кистью «item:…».
		_decal_painting = true
		var at := ((get_viewport().get_mouse_position() if screen == Vector2.INF else screen) - pan) / cell_size()
		if brush == ITEM_ERASE:
			_erase_items(at)
		else:
			map.items.append([SmallItems.random_kind(brush.substr(5), randi()), at.x, at.y, item_rotation])
			_sync_editor_items()
		queue_redraw()
		return
	if brush.begins_with("decal:") and tool == Tool.BRUSH and map.in_bounds(c) and not alt:
		_begin()
		_decal_painting = true
		_decal_last = Vector2.INF
		var pointer := get_viewport().get_mouse_position() if screen == Vector2.INF else screen
		_paint_decal((pointer - pan) / cell_size())
		return
	if not _float.is_empty() and not _float_moving:
		_drop_float(c)
		return
	if alt and tool != Tool.SELECT:
		pick_at(c)
		return
	match tool:
		Tool.BRUSH, Tool.ERASER:
			_begin()
			_stroke_last = Vector2i(-1, -1)
			_stroke_to(c, tool == Tool.ERASER)
		Tool.LINE, Tool.RECT, Tool.CIRCLE:
			_drag_start = c
			_drag_cur = c
		Tool.FILL:
			_begin()
			_flood(c, false)
			_commit()
		Tool.PICK:
			pick_at(c)
			_select_tool(_prev_tool)
		Tool.SELECT:
			if _has_selection() and _selection.has_point(c):
				_lift_selection(c)
			else:
				_selection = Rect2i()
				_drag_start = c
				_drag_cur = c
		Tool.STAMP:
			if _float.is_empty():
				_pick_stamp(stamp_id)
			_drop_float(c)
	queue_redraw()

func _paint_decal(pos: Vector2) -> void:
	if not map.in_bounds(Vector2i(pos.floor())): return
	var kind := brush.substr(6)
	if kind == "corpse": pos = pos.floor() + Vector2.ONE * 0.5
	var spacing := float(brush_size) if kind in MapData.WINTER_DECORATIONS else maxf(0.08, brush_size * 0.15)
	if _decal_last != Vector2.INF and pos.distance_to(_decal_last) < spacing: return
	if kind == "erase":
		map.decals = map.decals.filter(func(d: Array) -> bool:
			return Vector2(float(d[1]), float(d[2])).distance_to(pos) > float(brush_size) * 0.5)
	else:
		map.decals.append([kind, pos.x, pos.y, decal_rotation, float(brush_size)])
	_decal_last = pos
	_sync_editor_decals()
	queue_redraw()

func _drag_to(c: Vector2i) -> void:
	if _decal_painting: return
	match tool:
		Tool.BRUSH, Tool.ERASER:
			if not _act.is_empty():
				_stroke_to(c, tool == Tool.ERASER)
		Tool.LINE, Tool.RECT, Tool.CIRCLE, Tool.SELECT:
			if _drag_start != Vector2i(-1, -1) and c != _drag_cur:
				_drag_cur = c
				queue_redraw()

func _release(c: Vector2i) -> void:
	_decal_painting = false
	match tool:
		Tool.BRUSH, Tool.ERASER:
			_commit()
			_stroke_last = Vector2i(-1, -1)
		Tool.LINE, Tool.RECT, Tool.CIRCLE:
			if _drag_start != Vector2i(-1, -1):
				_begin()
				var cells: Array = []
				for p: Vector2i in _drag_shape():
					if tool == Tool.LINE:
						cells.append_array(_brush_cells(p))
					else:
						cells.append(p)
				_paint_cells(cells, false)
				_commit()
		Tool.SELECT:
			if _float_moving:
				_drop_float(c)
			elif _drag_start != Vector2i(-1, -1):
				var r := Rect2i(Vector2i(mini(_drag_start.x, _drag_cur.x), mini(_drag_start.y, _drag_cur.y)),
						(_drag_start - _drag_cur).abs() + Vector2i.ONE)
				# Щелчок без протяжки по мебели выделяет весь предмет (или ряд) — его можно
				# сразу повернуть R или перенести (0.9.2).
				if _drag_start == _drag_cur and map.in_bounds(c) \
						and Furniture.is_furniture(map.get_feature(_drag_start)):
					var fid := map.get_feature(_drag_start)
					for p: Vector2i in TerrainTiles.group_cells(_grid, _drag_start, fid):
						r = r.merge(Rect2i(p, Vector2i.ONE))
				_selection = r.intersection(Rect2i(Vector2i.ZERO, Vector2i(map.width, map.height)))
	_drag_start = Vector2i(-1, -1)
	_drag_cur = Vector2i(-1, -1)
	_refresh_status()
	queue_redraw()

## Клавиши. true — нажатие разобрано.
func _menu_popup_open() -> bool:
	for menu: PopupMenu in _menus.values():
		if menu.visible: return true
	return false

func _input(event: InputEvent) -> void:
	if _fp != null or Keybinds.modal_open() or _menu_popup_open() or not event is InputEventKey or not event.pressed or event.echo: return
	# A shortcut can leave the scene immediately. Capture the viewport first.
	var viewport := get_viewport()
	if _modal != null:
		if Keybinds.matches(event, "editor_cancel"):
			viewport.set_input_as_handled()
			_close_modal()
	elif _shortcut(event) and is_instance_valid(viewport): viewport.set_input_as_handled()

func _shortcut(e: InputEventKey) -> bool:
	if Keybinds.typing(get_viewport()) or Keybinds.modal_open() or _menu_popup_open() or _modal != null: return false
	var commands := {
		"editor_undo": undo, "editor_redo": redo, "editor_copy": copy_selection,
		"editor_cut": cut_selection, "editor_paste": paste, "editor_select_all": select_all,
		"editor_save": save, "editor_new": _new_map_dialog, "editor_open": _open_dialog,
		"editor_fit": fit_view, "editor_rotate": rotate_key.bind(false),
		"editor_rotate_auto": rotate_key.bind(true), "editor_zoom_in": zoom_in,
		"editor_zoom_out": zoom_out, "editor_delete": delete_selection,
		"editor_smaller": _set_brush_size.bind(brush_size - 1),
		"editor_larger": _set_brush_size.bind(brush_size + 1),
		"editor_variant_prev": _cycle_variant.bind(-1), "editor_variant_next": _cycle_variant.bind(1),
		"editor_play": play, "editor_help": _shortcuts_dialog, "editor_cancel": _cancel_tool,
	}
	for id: String in commands:
		if Keybinds.matches(e, id):
			commands[id].call()
			queue_redraw()
			return true
	if Keybinds.matches(e, "editor_lighting"):
		_toggle_lighting()
		return true
	if Keybinds.matches(e, "editor_heightmap"):
		_toggle_heightmap()
		return true
	if Keybinds.matches(e, "editor_grid"):
		show_grid = not show_grid
		_refresh_menu_checks()
		queue_redraw()
		return true
	if not _float.is_empty():
		if Keybinds.matches(e, "editor_flip_h"): flip_float(true); return true
		if Keybinds.matches(e, "editor_flip_v"): flip_float(false); return true
	for entry: Dictionary in TOOLS:
		if Keybinds.matches(e, entry.action):
			_select_tool(entry.tool)
			return true
	return false

func _cancel_tool() -> void:
	if not _float.is_empty():
		if _float_moving:
			_commit()
			undo()
			_redo_stack.clear()
		_float = {}
		_float_moving = false
	elif _drag_start != Vector2i(-1, -1): _drag_start = Vector2i(-1, -1)
	elif _has_selection(): _selection = Rect2i()
	else: exit_to_menu()

# ============================================================================
# Вид
# ============================================================================

func cell_size() -> float:
	return CELL * zoom

func cell_at(screen: Vector2) -> Vector2i:
	var local := (screen - pan) / cell_size()
	return Vector2i(floori(local.x), floori(local.y))

func zoom_at(screen: Vector2, factor: float) -> void:
	var before := (screen - pan) / zoom
	zoom = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	pan = screen - before * zoom
	_refresh_status()
	queue_redraw()

## Прямоугольник холста — то, что не закрыто панелями.
func canvas_rect() -> Rect2:
	var vp := get_viewport_rect().size
	return Rect2(Vector2(TOOLBAR_W, MENU_H), vp - Vector2(TOOLBAR_W + PALETTE_W, MENU_H + STATUS_H))

func zoom_in() -> void:
	zoom_at(canvas_rect().get_center(), 1.25)

func zoom_out() -> void:
	zoom_at(canvas_rect().get_center(), 0.8)

func select_all() -> void:
	_select_tool(Tool.SELECT)
	_selection = Rect2i(Vector2i.ZERO, Vector2i(map.width, map.height))
	_refresh_status()
	queue_redraw()

func fit_view() -> void:
	var r := canvas_rect().grow(-16.0)
	zoom = clampf(minf(r.size.x / (map.width * CELL), r.size.y / (map.height * CELL)), ZOOM_MIN, ZOOM_MAX)
	pan = r.position + (r.size - Vector2(map.width, map.height) * cell_size()) * 0.5
	_refresh_status()
	queue_redraw()

func _fit_view() -> void:
	fit_view()

## Взгляд на клетку c — по щелчку миникарты.
func center_on(c: Vector2) -> void:
	var r := canvas_rect()
	pan = r.position + r.size * 0.5 - c * cell_size()
	queue_redraw()

# ============================================================================
# Отрисовка
# ============================================================================

func _draw() -> void:
	if map == null or _grid == null:
		return
	var cs := cell_size()
	var w := map.width
	var h := map.height
	var vp := get_viewport_rect().size
	var x0 := clampi(floori(-pan.x / cs), 0, w - 1)
	var y0 := clampi(floori(-pan.y / cs), 0, h - 1)
	var x1 := clampi(ceili((vp.x - pan.x) / cs), 0, w - 1)
	var y1 := clampi(ceili((vp.y - pan.y) / cs), 0, h - 1)
	# Плитки — слой под нами, кусками TerrainTiles; правки подтягиваются из журнала вида.
	_tiles.sync({}, 0)
	_layer.position = pan
	_layer.scale = Vector2(zoom, zoom)
	_layer.cells = Rect2i(x0, y0, x1 - x0, y1 - y0)
	# Сетка — в слое плиток, между полом и объектами: поперёк стены или кровати её нет.
	_layer.grid_color = Ui.grid_color() if show_grid and cs >= 8.0 else Color(0, 0, 0, 0)
	_layer.grid_width = 1.0 / zoom
	_layer.queue_redraw()
	if _zone_stale:
		_zone_tex.update(_zone_img)
		_zone_stale = false
	if _mini_stale and _mini_tex != null:
		_mini_tex.update(_mini_img)
		_mini_stale = false
	if _mini_view != null:
		_mini_view.queue_redraw()
	Sprites.set_base_transform(pan, Vector2(zoom, zoom))
	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	var full := Rect2(Vector2.ZERO, Vector2(w, h) * CELL)
	if show_zones:
		draw_texture_rect(_zone_tex, full, false)
	draw_rect(full, Color(0.85, 0.85, 0.85, 0.6), false, 2.0 / zoom)
	# Нейтральные бойцы — картинкой своей фракции, иначе кружком с меткой.
	var font := ThemeDB.fallback_font
	if _heightmap and cs >= 10:
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var i := y * w + x
				var ht := TerrainTiles.height_text(map.cover_height[i], map.get_space(Vector2i(x, y)),
						map.feature_id[i])
				if ht != "":
					TerrainTiles.draw_height_text(self, font, Vector2(x, y) * CELL, CELL, ht,
							map.cover_height[i] >= MCF.WALL_HEIGHT and not Furniture.is_furniture(map.feature_id[i]))
	elif cs >= 18:
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var i := y * w + x
				if map.feature_id[i] == MCF.FEATURE_DIRT_PILE:
					draw_string(font, Vector2(x * CELL + 3, (y + 1) * CELL - 3), "%.1f" % map.cover_height[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.95, 0.85, 0.6))
	# Тела на клетках (0.12.2): рисуются той же картинкой, что и в бою, стопкой до пяти.
	if not map.corpses.is_empty():
		var pile := {}
		for q: int in map.corpses:
			pile[q] = int(pile.get(q, 0)) + 1
		for q: int in pile:
			var cc := Vector2i(q % w, q / w)
			if cc.x < x0 or cc.x > x1 or cc.y < y0 or cc.y > y1:
				continue
			var n: int = pile[q]
			for k in n:
				var off := Vector2(CELL * 0.5 + (k - (n - 1) * 0.5) * CELL * 0.12,
						CELL * 0.5 + (k % 2) * CELL * 0.08)
				TerrainTiles.draw_decal(self, "corpse", Vector2(cc) * CELL + off, CELL * 0.9,
						float(k) * 0.7)
			if n > 1:
				draw_string(font, Vector2(cc) * CELL + Vector2(CELL * 0.62, CELL - 4),
						"x%d" % n, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.85, 0.85))
	for c: Vector2i in _spawn_at:
		if c.x < x0 or c.x > x1 or c.y < y0 or c.y > y1:
			continue
		var s: Dictionary = _spawn_at[c]
		var o := Vector2(c) * CELL
		var key := Sprites.resolve(s["stats_id"], "_neutral" if MCF.is_neutral(s["owner"]) \
				else "_" + Roster.faction_key(s["owner"]))
		if key != "" and cs >= 10.0:
			Sprites.draw_texture_override(self, key, o, CELL)
		else:
			draw_circle(o + Vector2(CELL, CELL) * 0.5, CELL * 0.32, owner_color(s["owner"]))
			if cs >= 14.0:
				draw_string(font, o + Vector2(0, CELL * 0.5 + 5), Sprites.unit_tag(s["stats_id"]),
						HORIZONTAL_ALIGNMENT_CENTER, CELL, 14, Color.WHITE)
	if show_zones:
		_draw_zone_numbers(font)
	_draw_symmetry_axes()
	if cs >= 8.0: _draw_lamp_sides(Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1))
	_draw_overlays()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Which side of its wall every lamp is on (0.11): a bar of its light colour along that face
## and an arrow pointing where it shines. The lamp brush shows the same mark under the cursor.
func _draw_lamp_sides(view: Rect2i) -> void:
	for i: int in map.fixtures:
		var c := Vector2i(i % map.width, i / map.width)
		if not view.has_point(c): continue
		for lamp: Array in map.fixtures[i]:
			_draw_lamp_mark(c, int(lamp[2]), Furniture.light_color_of(str(lamp[0]), int(lamp[3])), 1.0)
	if tool == Tool.BRUSH and Furniture.is_wall_light(brush) and map.in_bounds(_hover):
		var hi := _hover.y * map.width + _hover.x
		if map.cover_height[hi] >= MCF.WALL_HEIGHT and not MCF.is_glass(map.feature_id[hi]) \
				and map.feature_id[hi] != MCF.FEATURE_AIRLOCK:
			var side := brush_turn if brush_turn >= 0 else _auto_lamp_side(hi)
			_draw_lamp_mark(_hover, side, Ui.accent_color(), 0.5 + 0.4 * absf(sin(Time.get_ticks_msec() * 0.006)))
			queue_redraw()   # the brush mark pulses

func _draw_lamp_mark(c: Vector2i, side: int, colour: Color, alpha: float) -> void:
	var n := Vector2(Furniture.N4[side])
	var t := Vector2(-n.y, n.x)
	var mid := (Vector2(c) + Vector2(0.5, 0.5) + n * 0.5) * CELL
	var bar := CELL * 0.36
	var ink := Color(0.05, 0.05, 0.06, 0.8 * alpha)
	draw_line(mid - t * bar, mid + t * bar, ink, CELL * 0.16)
	draw_line(mid - t * bar, mid + t * bar, Color(colour, alpha), CELL * 0.09)
	var tip := mid + n * CELL * 0.3
	var arrow := PackedVector2Array([mid + n * CELL * 0.06 - t * CELL * 0.14, tip, mid + n * CELL * 0.06 + t * CELL * 0.14])
	draw_colored_polygon(arrow, Color(colour, 0.85 * alpha))
	draw_polyline(arrow + PackedVector2Array([arrow[0]]), ink, maxf(1.0, CELL * 0.03))

## Номер зоны крупно в её середине — какая из цветных областей кому достанется.
func _draw_zone_numbers(font: Font) -> void:
	if _zone_centers_dirty:
		var sums := {}
		for i in map.width * map.height:
			var z: int = map.zone_owner[i]
			if z < 0:
				continue
			var acc: Array = sums.get(z, [Vector2.ZERO, 0])
			acc[0] += Vector2(i % map.width, i / map.width)
			acc[1] += 1
			sums[z] = acc
		_zone_centers.clear()
		for z: int in sums:
			_zone_centers[z] = (sums[z][0] / float(sums[z][1]) + Vector2(0.5, 0.5)) * CELL
		_zone_centers_dirty = false
	var fs := int(clampf(28.0 / zoom, 16.0, 400.0))
	for z: int in _zone_centers:
		var txt := str(z + 1)
		var at: Vector2 = _zone_centers[z] + Vector2(-fs * 0.3 * txt.length(), fs * 0.35)
		draw_string_outline(font, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(2, fs / 6), Color(0, 0, 0, 0.85))
		draw_string(font, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))

func _draw_symmetry_axes() -> void:
	var col := Ui.accent_color()
	col.a = 0.75
	var w := map.width * CELL
	var h := map.height * CELL
	if symmetry == Sym.X or symmetry == Sym.QUAD:
		draw_dashed_line(Vector2(w * 0.5, 0), Vector2(w * 0.5, h), col, 2.0 / zoom, 10.0 / zoom)
	if symmetry == Sym.Y or symmetry == Sym.QUAD:
		draw_dashed_line(Vector2(0, h * 0.5), Vector2(w, h * 0.5), col, 2.0 / zoom, 10.0 / zoom)

func _draw_overlays() -> void:
	var accent := Ui.accent_color()
	# То, что ляжет на карту: кисть под курсором, тянущаяся линия или прямоугольник, узор в руке.
	_draw_preview()
	# Линия или прямоугольник в процессе — рамкой (и у каждого отражения).
	if _drag_start != Vector2i(-1, -1) and tool in [Tool.LINE, Tool.RECT, Tool.CIRCLE]:
		var r := Rect2i(_drag_start, Vector2i.ONE).merge(Rect2i(_drag_cur, Vector2i.ONE))
		if tool == Tool.LINE:
			r = r.grow_individual((brush_size - 1) / 2, (brush_size - 1) / 2, brush_size / 2, brush_size / 2)
		for mask: int in _sym_masks():
			var a0 := _mirror(r.position, mask)
			var a1 := _mirror(r.end - Vector2i.ONE, mask)
			var lo := Vector2i(mini(a0.x, a1.x), mini(a0.y, a1.y))
			var hi := Vector2i(maxi(a0.x, a1.x), maxi(a0.y, a1.y)) + Vector2i.ONE
			_dashed_rect(Rect2(Vector2(lo) * CELL, Vector2(hi - lo) * CELL), Color(accent, 0.8 if mask == 0 else 0.4))
	# Рамка выделения в процессе и готовая.
	if tool == Tool.SELECT and _drag_start != Vector2i(-1, -1) and not _float_moving:
		var a := Vector2(mini(_drag_start.x, _drag_cur.x), mini(_drag_start.y, _drag_cur.y)) * CELL
		var b := Vector2(maxi(_drag_start.x, _drag_cur.x) + 1, maxi(_drag_start.y, _drag_cur.y) + 1) * CELL
		_dashed_rect(Rect2(a, b - a), accent)
	elif _has_selection() and _float.is_empty():
		draw_rect(Rect2(Vector2(_selection.position) * CELL, Vector2(_selection.size) * CELL),
				Color(accent, 0.12))
		_dashed_rect(Rect2(Vector2(_selection.position) * CELL, Vector2(_selection.size) * CELL), accent)
	# Узор в руке — рамкой каждого отражения.
	if not _float.is_empty() and map.in_bounds(_hover):
		for e: Array in _pattern_places():
			var q: Dictionary = e[0]
			_dashed_rect(Rect2(Vector2(e[1]) * CELL, Vector2(int(q["w"]), int(q["h"])) * CELL), accent)
		return
	# Курсор: кисть нужного размера (и её отражения).
	if map.in_bounds(_hover) and _drag_start == Vector2i(-1, -1):
		var cells: Array[Vector2i] = [_hover]
		if tool in [Tool.BRUSH, Tool.ERASER, Tool.LINE]:
			cells = _brush_cells(_hover)
		for mask: int in _sym_masks():
			var col := Color(1, 1, 1, 0.8 if mask == 0 else 0.4)
			var mn := Vector2i(1 << 30, 1 << 30)
			var mx := Vector2i(-(1 << 30), -(1 << 30))
			for c: Vector2i in cells:
				var m := _mirror(c, mask)
				mn = Vector2i(mini(mn.x, m.x), mini(mn.y, m.y))
				mx = Vector2i(maxi(mx.x, m.x), maxi(mx.y, m.y))
			draw_rect(Rect2(Vector2(mn) * CELL, Vector2(mx - mn + Vector2i.ONE) * CELL), col, false, 2.0 / zoom)

func _dashed_rect(r: Rect2, col: Color) -> void:
	var wdt := 2.0 / zoom
	var dash := 8.0 / zoom
	draw_dashed_line(r.position, Vector2(r.end.x, r.position.y), col, wdt, dash)
	draw_dashed_line(Vector2(r.end.x, r.position.y), r.end, col, wdt, dash)
	draw_dashed_line(r.end, Vector2(r.position.x, r.end.y), col, wdt, dash)
	draw_dashed_line(Vector2(r.position.x, r.end.y), r.position, col, wdt, dash)

## Узор в руке и все его отражения: [узор, левый верхний угол]. Перенос выделения кладётся
## без отражений (_drop_float) — и показывается так же.
func _pattern_places() -> Array:
	var out: Array = []
	var at := _hover - _float_grab
	for mask: int in ([0] if _float_moving else _sym_masks()):
		var q := _float
		if mask & 1:
			q = MapPresets.flipped(q, true)
		if mask & 2:
			q = MapPresets.flipped(q, false)
		var pos := at
		if mask & 1:
			pos.x = map.width - at.x - int(q["w"])
		if mask & 2:
			pos.y = map.height - at.y - int(q["h"])
		out.append([q, pos])
	return out

## Клетки линии или прямоугольника, что тянут сейчас.
func _drag_shape() -> Array[Vector2i]:
	if tool == Tool.LINE:
		return line_cells(_drag_start, _drag_cur)
	if tool == Tool.CIRCLE:
		return ellipse_cells(_drag_start, _drag_cur, rect_filled)
	return rect_cells(_drag_start, _drag_cur, rect_filled)

# --- Предпросмотр ---
# Под курсором — ровно то, что ляжет на карту, ТЕМИ ЖЕ плитками: клетки рисует сам
# TerrainTiles на сетке-черновике (кусок карты вокруг с наложенными клетками). Поэтому
# стены срастаются с соседними, дверь встаёт по стене, мебель срастается в один предмет и
# поворачивается к стене — как после щелчка. Пол рисуется там, где он меняется (или где
# объект убирают), объект — где меняется. Собирается заново, только когда сменилось
# что-то из _preview_key (курсор, кисть, карта…), а не каждый кадр.

## Кисть — вполпрозрачности (так просил владелец); узор крупнее, его — плотнее.
const GHOST := Color(1, 1, 1, 0.5)
const GHOST_PATTERN := Color(1, 1, 1, 0.75)
## Поле карты вокруг клеток предпросмотра в черновике: соседи для автотайла и поворота
## мебели (цельный предмет поворачивается по всем своим клеткам).
const PREVIEW_MARGIN := 3
## Потолки точного предпросмотра: клеток узора и изменённых клеток. Больше — картинками
## палитры, без автотайла: сборка идёт на каждый сдвиг курсора на клетку и стоит ~30 мкс
## (мебель ~90 мкс) на клетку; 450 — кисть 15×15 с отражением на две стороны, ~15 мс.
const PREVIEW_MAX_CELLS := 2500
const PREVIEW_MAX_EXACT := 450

var _pv_key := ""
## Куда сам повернулся бы предмет под курсором (для первого R: «следующий от этого»).
var _pv_auto_turn := -1
var _pv_src: Dictionary = {}
var _pv_tint := GHOST
## Точные клетки: [клетка карты, кусок атласа, рисовать пол, рисовать объект].
var _pv: Array = []
var _pv_floor: ImageTexture = null
var _pv_feat: ImageTexture = null
## Картинки поверх: бойцы узора, кисть зоны или бойца, черновик сверх потолка. [клетка, картинка].
var _pv_thumbs: Array = []
## Узоры сверх потолка — рисуются картинками палитры по видимой части (_draw_pattern).
var _pv_patterns: Array = []

func _preview_key() -> String:
	return "%d|%s|%d|%s|%s|%s|%s|%d|%d|%s|%d|%s|%d" % [tool, brush, brush_size, _hover, _drag_start,
			_drag_cur, rect_filled, symmetry, _map_ver, _env, TerrainTiles.res_for(cell_size()),
			_float_moving, brush_turn]

func _draw_preview() -> void:
	if brush == CORPSE_BRUSH and tool == Tool.BRUSH:
		var hc := Vector2(_hover) + Vector2(0.5, 0.5)
		TerrainTiles.draw_decal(self, "corpse", hc * CELL, CELL * 0.9, 0.0, 0.5)
		return
	if brush.begins_with("item:") and tool == Tool.BRUSH:
		var at := (get_viewport().get_mouse_position() - pan) / cell_size()
		if brush == ITEM_ERASE:
			draw_circle(at * CELL, CELL * brush_size * 0.5, Color(1, 1, 1, 0.4), false, 1.0, true)
		else:
			TerrainTiles.draw_decal(self, "item:" + brush.substr(5), at * CELL, CELL, item_rotation, 0.7)
		return
	if brush.begins_with("decal:") and tool == Tool.BRUSH:
		var pos := (get_viewport().get_mouse_position() - pan) / cell_size()
		var kind := brush.substr(6)
		if kind == "corpse": pos = pos.floor() + Vector2.ONE * 0.5
		if kind == "erase":
			draw_circle(pos * CELL, CELL * brush_size * 0.5, Color(1, 1, 1, 0.4), false, 1.0, true)
		else:
			TerrainTiles.draw_decal(self, kind, pos * CELL, CELL * brush_size, decal_rotation, 0.5)
		return
	var key := _preview_key()
	if key != _pv_key or not is_same(_float, _pv_src):
		_pv_key = key
		_pv_src = _float
		_build_preview()
	var cellv := Vector2(CELL, CELL)
	for e: Array in _pv_patterns:
		_draw_pattern(e[0], e[1])
	for e: Array in _pv:
		var r := Rect2(Vector2(e[0]) * CELL, cellv)
		if e[2]:
			draw_texture_rect_region(_pv_floor, r, e[1], _pv_tint)
		if e[3]:
			draw_texture_rect_region(_pv_feat, r, e[1], _pv_tint)
	for e: Array in _pv_thumbs:
		draw_texture_rect(e[1], Rect2(Vector2(e[0]) * CELL, cellv), false, _pv_tint)

## Клетки под курсором, на которые ляжет кисть (без отражений); пусто — кисти нет.
func _preview_base() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _drag_start != Vector2i(-1, -1):
		if tool in [Tool.LINE, Tool.RECT, Tool.CIRCLE]:
			for p: Vector2i in _drag_shape():
				if tool == Tool.LINE:
					out.append_array(_brush_cells(p))
				else:
					out.append(p)
	elif map.in_bounds(_hover):
		if tool in [Tool.BRUSH, Tool.LINE]:
			out = _brush_cells(_hover)
		elif tool in [Tool.RECT, Tool.CIRCLE, Tool.FILL]:
			out.append(_hover)
	return out

func _build_preview() -> void:
	_pv.clear()
	_pv_thumbs.clear()
	_pv_patterns.clear()
	_pv_floor = null
	_pv_feat = null
	_pv_tint = GHOST_PATTERN if not _float.is_empty() else GHOST
	# Клетка -> кортеж, каким она станет, со всеми отражениями (одним набором: у оси
	# отражения срастаются друг с другом, как и на карте).
	var cells := {}
	if not _float.is_empty():
		if not map.in_bounds(_hover):
			return
		for e: Array in _pattern_places():
			var q: Dictionary = e[0]
			var pos: Vector2i = e[1]
			var w: int = q["w"]
			for sp: Array in q["spawns"]:
				var c := pos + Vector2i(int(sp[0]), int(sp[1]))
				if map.in_bounds(c):
					_pv_thumbs.append([c, _ghost("unit:" + String(sp[2]))])
			if w * int(q["h"]) > PREVIEW_MAX_CELLS:
				_pv_patterns.append(e)
				continue
			for y in int(q["h"]):
				for x in w:
					var cell: Variant = q["cells"][y * w + x]
					var c := pos + Vector2i(x, y)
					if cell != null and map.in_bounds(c):
						cells[c] = cell   # следующее отражение ложится поверх, как в _place_pattern
	else:
		var base := _preview_base()
		if base.size() * _sym_masks().size() > PREVIEW_MAX_CELLS * 4:
			return   # прямоугольник в полкарты — только рамка (_draw_overlays)
		var flat := brush.begins_with("zone:") or brush.begins_with("unit:")
		for mask: int in _sym_masks():
			for c: Vector2i in base:
				var m := _mirror(c, mask)
				if not map.in_bounds(m) or cells.has(m):
					continue   # первое отражение выигрывает, как в _paint_cells
				if flat:
					# Зона и боец — не плитки: их картинка палитры (цвет зоны, фигурка).
					cells[m] = null
					_pv_thumbs.append([m, _ghost(brush)])
				else:
					cells[m] = _brushed(_tuple(m.y * map.width + m.x), mask, m.y * map.width + m.x)
	# Что на самом деле меняется: пол (или объект убирают) — и объект.
	var changed: Array = []   # [клетка, пол?, объект?]
	for c: Vector2i in cells:
		if cells[c] == null:
			continue
		var t: Array = cells[c]
		var i := c.y * map.width + c.x
		var sp := bool(t[2])
		var feat := "" if sp else String(t[3])
		var feat_new: bool = (feat != "" and feat != map.feature_id[i]) or (t.size() > 9 and t[9] != map.fixtures.get(i, []))
		var ground_new := int(t[0]) != map.floor_type[i] or sp != (map.is_space[i] != 0) \
				or (int(t[6]) if t.size() > 6 else 0) != map.get_look(i) or brush.begins_with("floor:") \
				or (feat == "" and map.feature_id[i] != "")
		if ground_new or feat_new:
			changed.append([c, ground_new, feat_new])
	if changed.is_empty():
		return
	var res := TerrainTiles.res_for(cell_size())
	if changed.size() > PREVIEW_MAX_EXACT:
		# Слишком много для черновика — картинками палитры, без автотайла.
		for e: Array in changed:
			var t: Array = cells[e[0]]
			if e[1]:
				_pv_thumbs.append([e[0], _ghost("space" if bool(t[2]) else
						("grass" if int(t[0]) == MCF.FLOOR_GRASS else "floor"))])
			if e[2]:
				_pv_thumbs.append([e[0], _ghost(String(t[3]))])
		return
	# Черновик — по куску 32×32 на занятый кусок карты: длинная косая линия не тянет за
	# собой сетку во всю свою рамку. Соседи берутся из ВСЕХ клеток предпросмотра.
	var blocks := {}   # кусок -> [мин, макс] изменённых клеток в нём
	for e: Array in changed:
		var c: Vector2i = e[0]
		var k := Vector2i(c.x >> 5, c.y >> 5)
		var b: Array = blocks.get(k, [c, c])
		blocks[k] = [Vector2i(mini(b[0].x, c.x), mini(b[0].y, c.y)), Vector2i(maxi(b[1].x, c.x), maxi(b[1].y, c.y))]
	var saved := GridCell.logs_snapshot()   # черновик не должен задеть журналы карты
	var tiles := {}   # кусок -> [плитки черновика, его угол на карте]
	for k: Vector2i in blocks:
		var bb := Rect2i(blocks[k][0], blocks[k][1] - blocks[k][0] + Vector2i.ONE).grow(PREVIEW_MARGIN) \
				.intersection(Rect2i(Vector2i.ZERO, Vector2i(map.width, map.height)))
		var g := Grid.new(bb.size.x, bb.size.y)
		for y in bb.size.y:
			for x in bb.size.x:
				var c := bb.position + Vector2i(x, y)
				var t: Variant = cells.get(c)
				_set_scratch(g, Vector2i(x, y), t if t != null else _tuple(c.y * map.width + c.x))
		tiles[k] = [_tiles.scratch(g, bb.position), bb.position]
		if Furniture.is_furniture(brush) and bb.has_point(_hover):
			_pv_auto_turn = TerrainTiles.furniture_turn(g, _hover - bb.position, brush, bb.position)
	# Все клетки — в один атлас по 64 в ряд: две текстуры на весь предпросмотр.
	var size := Vector2i(mini(changed.size(), 64), (changed.size() + 63) / 64) * res
	var fimg := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var oimg := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for n in changed.size():
		var e: Array = changed[n]
		var c: Vector2i = e[0]
		var tt: Array = tiles[Vector2i(c.x >> 5, c.y >> 5)]
		var slot := Vector2i(n % 64, n / 64) * res
		(tt[0] as TerrainTiles)._paint(fimg, oimg, c - tt[1], slot, res)
		_pv.append([c, Rect2(slot, Vector2(res, res)), e[1], e[2]])
	_pv_floor = ImageTexture.create_from_image(fimg)
	_pv_feat = ImageTexture.create_from_image(oimg)
	GridCell.logs_restore(saved)

## Клетка черновика — как _write пишет клетку зеркала карты.
func _set_scratch(g: Grid, at: Vector2i, t: Array) -> void:
	var gc := g.cell_fast(at.x, at.y)
	gc.floor_type = int(t[0])
	gc.is_space = bool(t[2])
	if String(t[3]) != "":
		gc.set_feature(String(t[3]))
		if t.size() > 5 and int(t[5]) >= 0:
			g.furniture_turn[at] = [String(t[3]), int(t[5])]
	gc.cover_height = float(t[1])
	gc.lamps = t[9] if t.size() > 9 else []
	if t.size() > 6 and int(t[6]) != 0:
		if g.floor_look.is_empty():
			g.floor_look.resize(g.width * g.height)
		g.floor_look[at.y * g.width + at.x] = int(t[6])

	if t.size() > 7 and int(t[7]) != 0:
		if g.wall_accent.is_empty():
			g.wall_accent.resize(g.width * g.height)
		g.wall_accent[at.y * g.width + at.x] = int(t[7])
	if t.size() > 8 and int(t[8]) != 0:
		if g.door_look.is_empty():
			g.door_look.resize(g.width * g.height)
		g.door_look[at.y * g.width + at.x] = int(t[8])
	if t.size() > 10 and int(t[10]) != 0:
		if g.light_tint.is_empty():
			g.light_tint.resize(g.width * g.height)
		g.light_tint[at.y * g.width + at.x] = int(t[10])

## Узор сверх потолка черновика — картинками палитры, только видимая часть: вставка всей
## карты 500×500 не рисует четверть миллиона клеток.
func _draw_pattern(p: Dictionary, at: Vector2i) -> void:
	var w: int = p["w"]
	var vis0 := cell_at(Vector2.ZERO) - at
	var vis1 := cell_at(get_viewport_rect().size) - at
	for y in range(maxi(0, vis0.y), mini(int(p["h"]), vis1.y + 1)):
		for x in range(maxi(0, vis0.x), mini(w, vis1.x + 1)):
			var cell: Variant = p["cells"][y * w + x]
			if cell == null:
				continue
			var t: Array = cell
			var r := Rect2(Vector2(at + Vector2i(x, y)) * CELL, Vector2(CELL, CELL))
			var ground := "space" if bool(t[2]) else ("grass" if int(t[0]) == MCF.FLOOR_GRASS else "floor")
			draw_texture_rect(_ghost(ground), r, false, _pv_tint)
			if String(t[3]) != "" and not bool(t[2]):
				draw_texture_rect(_ghost(String(t[3])), r, false, _pv_tint)

## Картинка палитры для предпросмотра без черновика: мебель — своей одиночной плиткой,
## прочее — как на кнопке. Кэш по окружению: пресет меняет наряд.
var _ghost_cache: Dictionary = {}
func _ghost(id: String) -> Texture2D:
	var key := _env + "|" + id
	var t: Texture2D = _ghost_cache.get(key)
	if t == null:
		if Furniture.is_furniture(id):
			t = Sprites.texture_of(id)
		if t == null:
			t = _thumb(id)
		_ghost_cache[key] = t
	return t

# ============================================================================
# Интерфейс
# ============================================================================

func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)
	_build_menu_bar()
	_build_toolbar()
	_build_palette()
	_build_status_bar()
	_build_minimap()
	Ui.theme_canvas_layers()

## Панель-полоса в стиле набора, прижатая к краям экрана.
func _strip(anchor_l: float, anchor_t: float, anchor_r: float, anchor_b: float,
		off: Rect2) -> PanelContainer:
	var p := PanelContainer.new()
	SteamChrome.apply_panel(p)
	p.anchor_left = anchor_l
	p.anchor_top = anchor_t
	p.anchor_right = anchor_r
	p.anchor_bottom = anchor_b
	p.offset_left = off.position.x
	p.offset_top = off.position.y
	p.offset_right = off.size.x
	p.offset_bottom = off.size.y
	_ui.add_child(p)
	return p

func _build_menu_bar() -> void:
	var bar := _strip(0, 0, 1, 0, Rect2(0, 0, 0, MENU_H))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	bar.add_child(row)
	for spec in [
		["File", [["New…", _new_map_dialog, "editor_new"], ["Open…", _open_dialog, "editor_open"],
			["Save", save, "editor_save"], [],
			["Open Maps Folder", func() -> void: OS.shell_open(ProjectSettings.globalize_path(MapData.MAPS_DIR))], [],
			["Play This Map", play, "editor_play"], [], ["Exit to Main Menu", exit_to_menu]]],
		["Edit", [["Undo", undo, "editor_undo"], ["Redo", redo, "editor_redo"], [],
			["Cut", cut_selection, "editor_cut"], ["Copy", copy_selection, "editor_copy"],
			["Paste", paste, "editor_paste"], ["Delete", delete_selection, "editor_delete"], [],
			["Select All", select_all, "editor_select_all"],
			["Rotate", rotate_key, "editor_rotate"], ["Flip Pasted Horizontally", flip_float.bind(true), "editor_flip_h"],
			["Flip Pasted Vertically", flip_float.bind(false), "editor_flip_v"], [],
			["Clear Map…", _clear_dialog]]],
		["View", [["Zoom In", zoom_in, "editor_zoom_in"], ["Zoom Out", zoom_out, "editor_zoom_out"],
			["Fit Map", fit_view, "editor_fit"], [],
			["Walk in First Person", _enter_fp_pick], [],
			["check:lighting", "Lighting", "editor_lighting"], ["check:heightmap", "Heightmap", "editor_heightmap"], ["check:grid", "Grid", "editor_grid"], ["check:zones", "Deployment Zones"], ["check:mini", "Minimap"], [],
			["Keyboard Shortcuts…", _shortcuts_dialog, "editor_help"],
			["Manual", func() -> void: ManualWindow.toggle(self), "editor_manual"],
			["Report a Bug…", func() -> void: BugReportWindow.open(self)]]],
		["Presets", [["Save Selection…", _save_room_dialog], ["Manage Rooms & Structures…", _room_manager],
			["Open Presets Folder", func() -> void: OS.shell_open(ProjectSettings.globalize_path(RoomPresets.DIR))]]],
		["Map", [["Resize…", _resize_dialog], [], ["label", "Preset"]] + _preset_items()
			+ [[], ["label", "Time of Day"]] + _time_items() + [[], ["check:winter", "Winter (snow)"], ["check:overcast", "Overcast sky"]]],
	]:
		var mb := MenuButton.new()
		mb.text = spec[0]
		mb.flat = false
		mb.custom_minimum_size = Vector2(58, 0)
		var pm := mb.get_popup()
		var actions: Array = []
		for item: Array in spec[1]:
			if item.is_empty():
				pm.add_separator()
				actions.append(Callable())
			elif String(item[0]).begins_with("check:"):
				pm.add_check_item(item[1])
				actions.append(String(item[0]))
			elif String(item[0]) == "label":
				pm.add_separator(item[1])
				actions.append(Callable())
			elif String(item[0]).begins_with("radio:"):
				pm.add_radio_check_item(item[1])
				actions.append(String(item[0]))
			else:
				pm.add_item(item[0])
				actions.append(item[1])
			if item.size() >= 3 and String(item[2]).begins_with("editor_"):
				var title: String = item[1] if String(item[0]).begins_with("check:") else item[0]
				pm.set_item_metadata(pm.item_count - 1, {"title": title, "key_action": item[2]})
				pm.set_item_text(pm.item_count - 1, "%s  (%s)" % [title, Keybinds.label(item[2])])
		pm.index_pressed.connect(func(idx: int) -> void: _menu_action(actions[idx]))
		if spec[0] == "Edit":
			pm.about_to_popup.connect(_refresh_edit_menu.bind(pm))
		row.add_child(mb)
		_menus[spec[0]] = pm
	row.add_child(VSeparator.new())
	# Настройки инструмента — прямо в полосе меню.
	var sz := Label.new()
	sz.text = "Size"
	row.add_child(sz)
	_size_slider = HSlider.new()
	_size_slider.min_value = 1
	_size_slider.max_value = 15
	_size_slider.step = 1
	_size_slider.value = brush_size
	_size_slider.custom_minimum_size = Vector2(90, 0)
	_size_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_size_slider.focus_mode = Control.FOCUS_NONE
	_size_slider.tooltip_text = "Brush size ([ and ])"
	_size_slider.value_changed.connect(func(v: float) -> void: _set_brush_size(int(v)))
	row.add_child(_size_slider)
	_size_value = Label.new()
	_size_value.custom_minimum_size = Vector2(22, 0)
	row.add_child(_size_value)
	_filled_check = CheckBox.new()
	_filled_check.text = "Filled"
	_filled_check.focus_mode = Control.FOCUS_NONE
	_filled_check.tooltip_text = "Rectangle tool draws a solid block instead of an outline"
	_filled_check.toggled.connect(func(on: bool) -> void: rect_filled = on)
	row.add_child(_filled_check)
	row.add_child(VSeparator.new())
	var sl := Label.new()
	sl.text = "Symmetry"
	row.add_child(sl)
	_sym_opt = OptionButton.new()
	for n: String in SYM_NAMES:
		_sym_opt.add_item(n)
	_sym_opt.focus_mode = Control.FOCUS_NONE
	_sym_opt.tooltip_text = "Mirror every stroke, preset and paste. Mirrored zones go to the matching player."
	_sym_opt.item_selected.connect(func(i: int) -> void:
		symmetry = i
		_refresh_status()
		queue_redraw())
	row.add_child(_sym_opt)
	row.add_child(VSeparator.new())
	_lighting_btn = Button.new()
	_lighting_btn.text = "Lighting"
	_lighting_btn.toggle_mode = true
	_lighting_btn.focus_mode = Control.FOCUS_NONE
	_lighting_btn.tooltip_text = "Preview dynamic lighting on this map (%s)" % Keybinds.label("editor_lighting")
	_lighting_btn.toggled.connect(func(on: bool) -> void:
		if on != _lighting_preview: _toggle_lighting())
	row.add_child(_lighting_btn)
	_height_btn = Button.new()
	_height_btn.text = "Heightmap"
	_height_btn.toggle_mode = true
	_height_btn.focus_mode = Control.FOCUS_NONE
	_height_btn.tooltip_text = "Show the height of every cover tile (%s)" % Keybinds.label("editor_heightmap")
	_height_btn.toggled.connect(func(on: bool) -> void:
		if on != _heightmap: _toggle_heightmap())
	row.add_child(_height_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_title_label = Label.new()
	_title_label.clip_text = true
	_title_label.custom_minimum_size = Vector2(80, 0)
	_title_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.add_child(_title_label)
	var play_btn := Button.new()
	play_btn.text = "Play"
	play_btn.tooltip_text = "Try this map in a battle (F5). The editor keeps it for when you come back."
	play_btn.focus_mode = Control.FOCUS_NONE
	play_btn.pressed.connect(play)
	row.add_child(play_btn)
	_set_brush_size(brush_size)
	_lighting_btn.set_pressed_no_signal(_lighting_preview)
	_refresh_menu_checks()

## Пункты «Правки», которым сейчас нечего делать, гаснут: откат без истории, вставка без
## буфера, копия без выделения.
func _refresh_edit_menu(pm: PopupMenu) -> void:
	for i in pm.item_count:
		var t := pm.get_item_text(i)
		var off := false
		if t.begins_with("Undo"):
			off = _undo_stack.is_empty()
		elif t.begins_with("Redo"):
			off = _redo_stack.is_empty()
		elif t.begins_with("Cut") or t.begins_with("Copy") or t.begins_with("Delete"):
			off = not _has_selection()
		elif t.begins_with("Paste"):
			off = _clipboard.is_empty()
		elif t.begins_with("Rotate"):
			off = _float.is_empty() and not (tool == Tool.SELECT and _has_selection()) \
					and not Furniture.is_furniture(brush)
		elif t.begins_with("Flip"):
			off = _float.is_empty()
		pm.set_item_disabled(i, off)

## Время суток карты (0.12.1, владелец): радио-пункты «time:<id>» в меню Map.
func _time_items() -> Array:
	var out: Array = []
	for i in MapData.TIMES.size():
		out.append(["radio:time:" + String(MapData.TIMES[i]), MapData.TIME_NAMES[i]])
	return out

func set_time_of_day(t: String) -> void:
	if not MapData.supports_time_of_day(map.environment()) or not MapData.TIMES.has(t):
		return
	var before := map.time_of_day if map.time_of_day != "" else "night"
	if t == before:
		return
	map.time_of_day = t
	_push({"time": [before, t]})
	_sync_lighting()
	_refresh_menu_checks()

## First person in the editor (owner, fix-8 #17): click a free cell and walk the map in 3D
## as it stands — no fog, every placed soldier where he was put. Esc comes back.
func _enter_fp_pick() -> void:
	_fp_pick = true
	_refresh_status()

func _start_first_person(at: Vector2i) -> void:
	if not map.in_bounds(at):
		_refresh_status()
		return
	_fp_host = FirstPersonHost.new(map, _tiles)
	add_child(_fp_host)
	if not FirstPerson.walkable_start(_fp_host, at):
		_fp_host.queue_free()
		_fp_host = null
		_status_label.text = "That cell is not free to stand on - pick floor, not a wall or a soldier."
		return
	_fp_pick = false
	_fp_layer = CanvasLayer.new()
	_fp_layer.layer = 60
	add_child(_fp_layer)
	_fp = FirstPerson.new(_fp_host, at)
	_fp.left.connect(_end_first_person)
	_fp_layer.add_child(_fp)
	_ui.visible = false

func _end_first_person() -> void:
	if _fp_layer != null:
		_fp_layer.queue_free()
	if _fp_host != null:
		_fp_host.queue_free()
	_fp_layer = null
	_fp = null
	_fp_host = null
	_ui.visible = true
	_refresh_status()
	queue_redraw()

## Overcast sky (issues-12 #20): first person's clouds close in; only looks, undoable.
func set_overcast(on: bool) -> void:
	if not MapData.supports_winter(map.environment()) or on == map.overcast:
		return
	_push({"overcast": [map.overcast, on]})
	map.overcast = on
	_refresh_menu_checks()

## Winter (owner, fix-8 #3): snow on a town or a field, only looks; undoable like the hour.
func set_winter(on: bool) -> void:
	if not MapData.supports_winter(map.environment()) or on == map.winter:
		return
	_push({"winter": [map.winter, on]})
	map.winter = on
	_winter_changed()

func _winter_changed() -> void:
	_sync_lighting()
	_sync_background()
	for i in map.width * map.height:
		_mini_img.set_pixelv(Vector2i(i % map.width, i / map.width), map_color(map, i, _env))
	_mini_stale = true
	_refresh_menu_checks()
	queue_redraw()

func _preset_items() -> Array:
	var out: Array = []
	for i in MapPresets.IDS.size():
		out.append(["radio:" + String(MapPresets.IDS[i]), MapPresets.NAMES[i]])
	return out

var _right_press := Vector2(-1000, -1000)
var _light_menu: PopupMenu = null

## The lamp under the mouse — a standing light or one mounted on the wall — gets a small
## colour menu right where it was clicked. false: no lamp there.
func _open_light_menu(screen: Vector2) -> bool:
	if map == null: return false
	var c := Vector2i(((screen - pan) / cell_size()).floor())
	if not map.in_bounds(c): return false
	var i := c.y * map.width + c.x
	if not map.fixtures.has(i) and not Furniture.emits_light(map.feature_id[i]): return false
	if _light_menu == null:
		_light_menu = PopupMenu.new()
		_light_menu.theme = Ui.theme
		_light_menu.id_pressed.connect(func(id: int) -> void:
			var cell := int(_light_menu.get_meta("cell"))
			var side := int(_light_menu.get_meta("side"))
			var was := int(_light_menu.get_meta("tint"))
			# Снятие лампы — отдельная команда, не значение оттенка (0.12.1): байт 300 % с
			# красным цветом равнялся прежнему LIGHT_REMOVE, и лампа сама исчезала.
			if id == LIGHT_REMOVE:
				_remove_lamp(cell, side)
				return
			if id == LIGHT_TYPE_ID:
				_intensity_dialog(cell, side, was)
				return
			var tint := id
			if id >= LIGHT_LEVEL_ID:
				tint = Furniture.make_tint(Furniture.tint_colour(was), id - LIGHT_LEVEL_ID)
			else:
				tint = Furniture.make_tint(id, Furniture.tint_level(was))
			_light_menu.set_meta("tint", tint)
			_set_light_tint(cell, side, tint))
		add_child(_light_menu)
	_light_menu.clear()
	# A wall lamp: the one on the face nearest the click (a wall can carry one per side).
	var side := -1
	var f := (screen - pan) / cell_size() - Vector2(c)
	for lamp: Array in map.fixtures.get(i, []):
		var face := Vector2(0.5, 0.5) + Vector2(Furniture.N4[int(lamp[2])]) * 0.5
		if side < 0 or f.distance_to(face) < f.distance_to(Vector2(0.5, 0.5) + Vector2(Furniture.N4[side]) * 0.5):
			side = int(lamp[2])
	var lamp := MapData.lamp_on(map.fixtures.get(i, []), side) if side >= 0 else []
	var id := str(lamp[0]) if side >= 0 else map.feature_id[i]
	var current := int(lamp[3]) if side >= 0 else map.get_tint(i)
	if side >= 0:
		_light_menu.add_separator("%s · %s side" % [Furniture.DEFS[id].name, SIDE_NAMES[side]])
	for t in Furniture.LIGHT_TINTS.size():
		var swatch_colour: Color = Furniture.LIGHT_TINTS[t][1] if t > 0 else Furniture.light_color_of(id, 0)
		_light_menu.add_radio_check_item("Light color · %s" % Furniture.LIGHT_TINTS[t][0], t)
		var at := _light_menu.get_item_index(t)
		_light_menu.set_item_icon(at, _swatch(swatch_colour))
		_light_menu.set_item_checked(at, Furniture.tint_colour(current) == t)
	# Brightness (0.11.1): listed dimmest first; "100 %" is the lamp as designed.
	_light_menu.add_separator()
	# Короткий список частых ступеней; любое другое значение — числом (0.12.1).
	var levels := [1, 2, 3, 0, 4, 5, 6]
	var cur_level := Furniture.tint_level(current)
	for l: int in levels:
		_light_menu.add_radio_check_item("Intensity · %s" % Furniture.LIGHT_LEVELS[l][0], LIGHT_LEVEL_ID + l)
		_light_menu.set_item_checked(_light_menu.get_item_index(LIGHT_LEVEL_ID + l), cur_level == l)
	var typed := "Intensity · Type a value…"
	if not levels.has(cur_level) and cur_level < Furniture.LIGHT_LEVELS.size():
		typed = "Intensity · %s (type a value…)" % Furniture.LIGHT_LEVELS[cur_level][0]
	_light_menu.add_item(typed, LIGHT_TYPE_ID)
	if side >= 0:
		_light_menu.add_separator()
		_light_menu.add_item("Remove this lamp", LIGHT_REMOVE)
	_light_menu.set_meta("cell", i)
	_light_menu.set_meta("side", side)
	_light_menu.set_meta("tint", current)
	_light_menu.popup(Rect2i(Vector2i(get_screen_transform() * screen), Vector2i.ZERO))
	return true

const LIGHT_REMOVE := 100
const LIGHT_LEVEL_ID := 200
const LIGHT_TYPE_ID := 300

## Яркость числом (0.12.1, владелец): окно с полем; значение ложится на ближайшую ступень
## Furniture.LIGHT_LEVELS (10–500 %), и окно показывает, на какую.
func _intensity_dialog(cell: int, side: int, was: int) -> void:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	var spin := _spin(roundi(Furniture.light_scale_of(was) * 100.0), 10, 500)
	spin.suffix = "%"
	_field_row(body, "Intensity", spin)
	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color("#8a8a8a"))
	var refresh := func(v: float) -> void:
		hint.text = "Lamps take one of %d steps between 10 %% and 500 %%: this one will be %s." % [
				Furniture.LIGHT_LEVELS.size(), Furniture.LIGHT_LEVELS[Furniture.level_for_percent(v)][0]]
	spin.value_changed.connect(refresh)
	refresh.call(spin.value)
	body.add_child(hint)
	_dialog("Light Intensity", body, [["Cancel", null], ["Apply", func() -> void:
		spin.apply()
		_set_light_tint(cell, side, Furniture.make_tint(Furniture.tint_colour(was),
				Furniture.level_for_percent(spin.value)))]])
	spin.get_line_edit().grab_focus.call_deferred()
	spin.get_line_edit().select_all.call_deferred()

## side >= 0: the wall lamp on that side (LIGHT_REMOVE takes it down); -1: the standing lamp.
## tint: the whole tint byte (Furniture.make_tint: colour and brightness).
func _remove_lamp(i: int, side: int) -> void:
	if side < 0:
		return
	var t := _tuple(i)
	t[9] = MapData.without_lamp(t[9], side)
	_begin()
	_write(i, t)
	_commit()
	_sync_lighting()
	queue_redraw()

func _set_light_tint(i: int, side: int, tint: int) -> void:
	var t := _tuple(i)
	if side < 0:
		t[10] = tint
	else:
		var rec := MapData.lamp_on(t[9], side).duplicate()
		if rec.is_empty(): return
		rec[3] = tint
		t[9] = MapData.with_lamp(t[9], rec)
	_begin()
	_write(i, t)
	_commit()
	_sync_lighting()
	queue_redraw()

func _toggle_heightmap() -> void:
	_heightmap = not _heightmap
	if _height_btn != null: _height_btn.set_pressed_no_signal(_heightmap)
	_refresh_menu_checks()
	queue_redraw()

func _toggle_lighting() -> void:
	_lighting_preview = not _lighting_preview
	if _lighting_btn != null: _lighting_btn.set_pressed_no_signal(_lighting_preview)
	_sync_lighting()
	_refresh_menu_checks()

func _menu_action(a: Variant) -> void:
	if a is Callable:
		if (a as Callable).is_valid():
			(a as Callable).call()
	elif a is String:
		var s: String = a
		if s == "check:lighting":
			_toggle_lighting()
		elif s == "check:heightmap":
			_toggle_heightmap()
		elif s == "check:grid":
			show_grid = not show_grid
		elif s == "check:zones":
			show_zones = not show_zones
		elif s == "check:winter":
			set_winter(not map.winter)
		elif s == "check:overcast":
			set_overcast(not map.overcast)
		elif s == "check:mini":
			_mini_rect.get_parent().visible = not _mini_rect.get_parent().visible
		elif s.begins_with("radio:time:"):
			set_time_of_day(s.substr(11))
		elif s.begins_with("radio:"):
			set_preset(s.substr(6))
		_refresh_menu_checks()
	queue_redraw()

func _refresh_menu_checks() -> void:
	if not _menus.has("View"):
		return
	var v: PopupMenu = _menus["View"]
	for i in v.item_count:
		if v.get_item_text(i).begins_with("Lighting"):
			v.set_item_checked(i, _lighting_preview)
		if v.get_item_text(i).begins_with("Heightmap"):
			v.set_item_checked(i, _heightmap)
		match v.get_item_text(i):
			"Grid  (G)": v.set_item_checked(i, show_grid)
			"Deployment Zones": v.set_item_checked(i, show_zones)
			"Minimap": v.set_item_checked(i, _mini_rect == null or _mini_rect.get_parent().visible)
	var m: PopupMenu = _menus["Map"]
	var tod := map.time_of_day if map.time_of_day != "" else "night"
	for i in m.item_count:
		var idx := MapPresets.NAMES.find(m.get_item_text(i))
		if idx >= 0 and m.is_item_radio_checkable(i):
			m.set_item_checked(i, MapPresets.IDS[idx] == map.environment())
		if m.get_item_text(i).begins_with("Overcast"):
			m.set_item_disabled(i, not MapData.supports_winter(map.environment()))
			m.set_item_checked(i, map.overcast and MapData.supports_winter(map.environment()))
		if m.get_item_text(i).begins_with("Winter"):
			m.set_item_disabled(i, not MapData.supports_winter(map.environment()))
			m.set_item_checked(i, map.winter and MapData.supports_winter(map.environment()))
		var t := MapData.TIME_NAMES.find(m.get_item_text(i))
		if t >= 0 and m.is_item_radio_checkable(i):
			var available := MapData.supports_time_of_day(map.environment())
			m.set_item_disabled(i, not available)
			m.set_item_checked(i, available and MapData.TIMES[t] == tod)

## Пресет карты: окружение, а с ним плитки (откат — одной записью).
func set_preset(env: String) -> void:
	if env == map.environment() and map.env != "":
		return
	var before := map.env
	map.env = env
	_push({"env": [before, env]})
	_env_changed()
	_refresh_menu_checks()

func _build_toolbar() -> void:
	var p := _strip(0, 0, 0, 1, Rect2(0, MENU_H, TOOLBAR_W, -STATUS_H))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.alignment = BoxContainer.ALIGNMENT_BEGIN
	p.add_child(SteamChrome.pad(col, 7, 6))
	for t: Dictionary in TOOLS:
		var b := Button.new()
		b.icon = _tool_icon(t["tool"])
		b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # крупный пиксель при любом масштабе
		b.toggle_mode = true
		b.button_group = _tool_group
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(34, 34)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.tooltip_text = "%s  (%s)\n%s" % [t["name"], Keybinds.label(t["action"]), t["hint"]]
		b.pressed.connect(_select_tool.bind(t["tool"]))
		col.add_child(b)
		_tool_buttons[t["tool"]] = b

func _build_palette() -> void:
	var p := _strip(1, 0, 1, 1, Rect2(-PALETTE_W, MENU_H, 0, -STATUS_H))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	# Поля внутри панели (0.9.2): у панели набора своих полей нет, и значок текущей кисти
	# прилипал к рамке, а на крупной мебели (мусорный бак) вылезал за неё.
	p.add_child(SteamChrome.pad(outer, 6, 6))
	# Текущая кисть — крупно, сверху: что сейчас ляжет на карту.
	var cur := HBoxContainer.new()
	cur.add_theme_constant_override("separation", 8)
	outer.add_child(cur)
	_current_icon = TextureRect.new()
	_current_icon.custom_minimum_size = Vector2(32, 32)
	_current_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_current_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_current_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cur.add_child(_current_icon)
	_current_label = Label.new()
	_current_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_current_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cur.add_child(_current_label)
	# Варианты (цвета мебели, текстуры дверей, акценты стен) — стрелками под текущей
	# кистью (0.12.1, владелец: всплывающая полоска значков была неудобной). Клавиши — , и .
	_variant_row = HBoxContainer.new()
	_variant_row.add_theme_constant_override("separation", 4)
	outer.add_child(_variant_row)
	var prev := Button.new()
	prev.text = "◀"
	prev.focus_mode = Control.FOCUS_NONE
	prev.custom_minimum_size = Vector2(28, 28)
	prev.pressed.connect(_cycle_variant.bind(-1))
	_variant_row.add_child(prev)
	_variant_icon = TextureRect.new()
	_variant_icon.custom_minimum_size = Vector2(24, 24)
	_variant_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_variant_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_variant_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_variant_row.add_child(_variant_icon)
	_variant_label = Label.new()
	_variant_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_variant_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_variant_label.clip_text = true
	_variant_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_variant_label.add_theme_font_size_override("font_size", 11)
	_variant_row.add_child(_variant_label)
	var nxt := Button.new()
	nxt.text = "▶"
	nxt.focus_mode = Control.FOCUS_NONE
	nxt.custom_minimum_size = Vector2(28, 28)
	nxt.pressed.connect(_cycle_variant.bind(1))
	_variant_row.add_child(nxt)
	_variant_row.visible = false
	# Набор предметов стола (0.12.1): чем кисть стола его накрывает — те же стрелки.
	_set_row = HBoxContainer.new()
	_set_row.add_theme_constant_override("separation", 4)
	outer.add_child(_set_row)
	var sprev := Button.new()
	sprev.text = "◀"
	sprev.focus_mode = Control.FOCUS_NONE
	sprev.custom_minimum_size = Vector2(28, 28)
	sprev.pressed.connect(_cycle_table_set.bind(-1))
	_set_row.add_child(sprev)
	_set_label = Label.new()
	_set_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_set_label.clip_text = true
	_set_label.add_theme_font_size_override("font_size", 11)
	_set_label.tooltip_text = "Which small items this table is laid with when you place it."
	_set_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_set_row.add_child(_set_label)
	var snext := Button.new()
	snext.text = "▶"
	snext.focus_mode = Control.FOCUS_NONE
	snext.custom_minimum_size = Vector2(28, 28)
	snext.pressed.connect(_cycle_table_set.bind(1))
	_set_row.add_child(snext)
	_set_row.visible = false
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	_palette_box = VBoxContainer.new()
	_palette_box.add_theme_constant_override("separation", 10)
	_palette_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_palette_box)

## Палитра заново — картинки зависят от окружения карты.
func _refresh_palette() -> void:
	if _palette_box == null:
		return
	for c in _palette_box.get_children():
		_palette_box.remove_child(c)
		c.queue_free()
	_brush_buttons.clear()
	_palette_group("Decals", [["decal:blood_pool", "Blood pool"], ["decal:blood_drop", "Blood drop"], ["decal:erase", "Erase decals"]])
	_palette_group("Winter decorations", [["decal:snowman", "Snowman"], ["decal:snowdrift", "Snowdrift"]])
	# Тело — не декаль (0.12.2, item 20): это настоящее тело на клетке, его в бою можно
	# оттащить и сложить в стену из тел; кистью кладётся по одному, до пяти на клетку.
	_palette_group("Bodies", [[CORPSE_BRUSH, "Corpse"]])
	# Мелкие предметы (0.12.1): кладутся куда угодно и под любым углом (R — поворот на 15°).
	var small: Array = []
	for kind: String in SmallItems.KINDS:
		small.append(["item:" + kind, SmallItems.name_of(kind), "%s - click to place, R turns it 15°" % SmallItems.name_of(kind)])
	small.append([ITEM_ERASE, "Erase items"])
	_palette_group("Small items", small)
	var terrain: Array = TERRAIN.duplicate()
	for lk: int in FLOOR_LOOK_BRUSHES:
		terrain.append(["floor:%d" % lk, MCF.FLOOR_LOOK_NAMES[lk]])
	_palette_group("Terrain", terrain)
	# Материалы стены (0.9.4): та же стена, другой облик — кисть «wallmat:N».
	var walls: Array = WALLS.duplicate()
	for mi in MCF.WALL_LOOKS.size():
		walls.append(["wallmat:%d" % mi, MCF.WALL_LOOK_NAMES[mi]])
	_palette_group("Walls & doors", walls)
	_palette_group("Objects", OBJECTS)
	# Мебель (§3.15) — по разделам, а в разделе по высоте (0.9.2): высота решает, укрытие
	# это или стена, и подписью «Стол 1.0» на каждой кнопке её искать было неудобно.
	for cat: String in Furniture.CATEGORIES:
		if cat == "lighting":
			var wall_items: Array = []
			var floor_items: Array = []
			for fid: String in Furniture.ids():
				if Furniture.DEFS[fid].cat != "lighting": continue
				var item := [fid, Furniture.name_of(fid), _furniture_hint(fid)]
				if Furniture.is_wall_light(fid): wall_items.append(item)
				else: floor_items.append(item)
			_palette_group("Lighting", [], 2, [["Wall-mounted · place on solid walls", wall_items], ["Freestanding", floor_items]])
			continue
		var by_h := {}
		for fid: String in Furniture.ids():
			if Furniture.DEFS[fid]["cat"] == cat and Furniture.base_of(fid) == fid:
				var hh := Furniture.height_of(fid)
				if not by_h.has(hh):
					by_h[hh] = []
				by_h[hh].append([fid, Furniture.name_of(fid), _furniture_hint(fid)])
		var heights := by_h.keys()
		heights.sort()
		var sections: Array = []
		for hh: float in heights:
			sections.append([HEIGHT_NAMES.get(hh, "%.1f m" % hh), by_h[hh]])
		_palette_group("Furniture: %s" % Furniture.CATEGORY_NAMES[cat], [], 2, sections)
	var units: Array = []
	for id: String in NEUTRAL_UNIT_IDS:
		units.append(["unit:" + id, id.capitalize()])
	_palette_group("Neutral units", units, 1)
	_zone_group()
	var stamps: Array = []
	RoomPresets.seed_builtins()
	for name: String in RoomPresets.names():
		stamps.append(["preset:" + name, name, "Place this saved room or structure; R rotates."])
	_palette_group("Presets", stamps)
	_mark_brush_button()

## Кнопки палитры — с узкими полями, иначе в две колонки не влезают названия.
var _tight_styles: Dictionary = {}

func _tight(b: Button) -> void:
	if _tight_styles.is_empty():
		for st: String in ["normal", "hover", "pressed", "disabled", "hover_pressed"]:
			var src := Ui.theme.get_stylebox(st if st != "hover_pressed" else "pressed", "Button") \
					if Ui.theme != null else null
			if src == null:
				continue
			var sb := src.duplicate() as StyleBox
			sb.content_margin_left = 6
			sb.content_margin_right = 4
			_tight_styles[st] = sb
	for st: String in _tight_styles:
		b.add_theme_stylebox_override(st, _tight_styles[st])

## Подзаголовки высот мебели в палитре.
const HEIGHT_NAMES := {0.5: "Low - 0.5 m", 1.0: "Waist - 1 m", 1.5: "Chest - 1.5 m",
		2.0: "Tall - 2 m, blocks sight"}

## Группа палитры: items — кнопки одной сеткой; sections — [[подзаголовок, items], …]
## (мебель по высоте), каждая своей сеткой под своей подписью.
func _palette_group(title: String, items: Array, columns: int = 2, sections: Array = []) -> void:
	var box := SteamChrome.group_box(title)
	_palette_box.add_child(box)
	if sections.is_empty():
		sections = [["", items]]
	for sec: Array in sections:
		if String(sec[0]) != "":
			var sub := Label.new()
			sub.text = sec[0]
			sub.add_theme_font_size_override("font_size", 11)
			sub.add_theme_color_override("font_color", Ui.text_accent_color())
			box.body.add_child(sub)
		_palette_grid(box.body, sec[1], columns)

func _palette_grid(parent: Control, items: Array, columns: int) -> void:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	parent.add_child(grid)
	for it: Array in items:
		var id: String = it[0]
		var b := Button.new()
		b.text = it[1]
		b.icon = _thumb(id)
		b.expand_icon = false
		b.toggle_mode = true
		b.button_group = _brush_group
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# Длинное имя («Examination Table 1.0») — в две строки, а не обрезком.
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_constant_override("icon_max_width", 22)
		b.custom_minimum_size = Vector2(100, 30)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tight(b)
		b.tooltip_text = it[2] if it.size() > 2 else it[1]
		if id.begins_with("preset:"):
			b.pressed.connect(_pick_custom_preset.bind(id.substr(7)))
		elif id.begins_with("stamp:"):
			b.pressed.connect(_pick_stamp.bind(id.substr(6)))
		else:
			b.pressed.connect(_select_brush.bind(id))
		grid.add_child(b)
		_brush_buttons[id] = b

func _zone_group() -> void:
	var box := SteamChrome.group_box("Deployment zones")
	_palette_box.add_child(box)
	var hint := Label.new()
	hint.text = "The lobby gives each numbered zone to a player."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color("#8a8a8a"))
	box.body.add_child(hint)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	box.body.add_child(grid)
	var n := MCF.MAX_PLAYERS if _more_zones else ZONES_SHOWN
	for i in n:
		var b := Button.new()
		b.text = str(i + 1)
		b.icon = _swatch(owner_color(i))
		b.toggle_mode = true
		b.button_group = _brush_group
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(48, 26)
		b.add_theme_font_size_override("font_size", 11)
		b.tooltip_text = "Paint zone %d" % (i + 1)
		b.pressed.connect(_select_brush.bind("zone:%d" % i))
		grid.add_child(b)
		_brush_buttons["zone:%d" % i] = b
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.body.add_child(row)
	var none := Button.new()
	none.text = "No zone"
	none.toggle_mode = true
	none.button_group = _brush_group
	none.focus_mode = Control.FOCUS_NONE
	none.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	none.add_theme_font_size_override("font_size", 11)
	none.tooltip_text = "Remove the zone from cells"
	none.pressed.connect(_select_brush.bind("zone:-1"))
	row.add_child(none)
	_brush_buttons["zone:-1"] = none
	var more := Button.new()
	more.text = "Fewer zones" if _more_zones else "More zones"
	more.focus_mode = Control.FOCUS_NONE
	more.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	more.add_theme_font_size_override("font_size", 11)
	more.pressed.connect(func() -> void:
		_more_zones = not _more_zones
		_refresh_palette.call_deferred())
	row.add_child(more)

func _build_status_bar() -> void:
	var p := _strip(0, 1, 1, 1, Rect2(0, -STATUS_H, 0, 0))
	var row := HBoxContainer.new()
	p.add_child(SteamChrome.pad(row, 8, 0))
	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.clip_text = true
	_status_label.add_theme_font_size_override("font_size", 11)
	row.add_child(_status_label)
	_zoom_label = Label.new()
	_zoom_label.add_theme_font_size_override("font_size", 11)
	row.add_child(_zoom_label)

## Миникарта: картинка карты пиксель-в-клетку и рамка того, что сейчас на экране.
## Щелчок или протяжка по ней переносит взгляд.
class MiniView extends Control:
	var editor = null   # без типа: зовём методы редактора, которых нет у Node
	func _draw() -> void:
		if editor == null or editor.map == null:
			return
		var m: MapData = editor.map
		var k := size / Vector2(m.width, m.height)
		var r: Rect2 = editor.canvas_rect()
		var cs: float = editor.cell_size()
		var a: Vector2 = (r.position - editor.pan) / cs * k
		var b: Vector2 = (r.end - editor.pan) / cs * k
		var view := Rect2(a, b - a).intersection(Rect2(Vector2.ZERO, size))
		draw_rect(view, Color(1, 1, 1, 0.9), false, 1.5)
	func _gui_input(e: InputEvent) -> void:
		var drag: bool = e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		var click: bool = e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT
		if drag or click:
			var m: MapData = editor.map
			editor.center_on(e.position / size * Vector2(m.width, m.height))
			accept_event()

func _build_minimap() -> void:
	var frame := PanelContainer.new()
	SteamChrome.apply_panel(frame)
	_ui.add_child(frame)
	_mini_rect = TextureRect.new()
	_mini_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_mini_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mini_rect.stretch_mode = TextureRect.STRETCH_SCALE
	frame.add_child(_mini_rect)
	_mini_view = MiniView.new()
	_mini_view.editor = self
	_mini_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mini_rect.add_child(_mini_view)

## Миникарта в правом нижнем углу холста; сторона — по пропорциям карты.
func _layout_minimap() -> void:
	if _mini_rect == null or map == null:
		return
	var k := MINI_MAX / maxf(map.width, map.height)
	var sz := Vector2(map.width, map.height) * k
	_mini_rect.custom_minimum_size = sz
	var frame := _mini_rect.get_parent() as Control
	frame.anchor_left = 1.0
	frame.anchor_top = 1.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_right = -PALETTE_W - 8.0
	frame.offset_bottom = -STATUS_H - 8.0
	frame.offset_left = frame.offset_right - sz.x - 16.0
	frame.offset_top = frame.offset_bottom - sz.y - 16.0
	_mini_rect.texture = _mini_tex

# --- Выбор инструмента и кисти ---

func _select_tool(t: int, keep_float: bool = false) -> void:
	if _decal_painting:
		_decal_painting = false
		_commit()
	if t != Tool.PICK:
		_prev_tool = t
	if t != tool and not keep_float and not _float_moving:
		_float = {}   # смена инструмента отменяет вставку и заготовку в руке
	tool = t
	_drag_start = Vector2i(-1, -1)
	if t == Tool.STAMP and _float.is_empty():
		_float = MapPresets.stamp(stamp_id)
		_float_grab = Vector2i(int(_float["w"]) / 2, int(_float["h"]) / 2)
	if _tool_buttons.has(t):
		(_tool_buttons[t] as Button).button_pressed = true
	_refresh_variants()
	_refresh_status()
	queue_redraw()

func _select_brush(id: String) -> void:
	# Другой предмет — поворот снова «сам»; цветной вариант того же предмета его сохраняет.
	if Furniture.base_of(id) != Furniture.base_of(brush):
		brush_turn = -1
		brush_table_set = ""
	brush = id
	if tool in [Tool.ERASER, Tool.SELECT, Tool.PICK, Tool.STAMP]:
		_select_tool(Tool.BRUSH)
	_mark_brush_button()
	_refresh_status()

func _mark_brush_button() -> void:
	# Цветной вариант мебели — на кнопке своего предмета.
	var key := Furniture.base_of(brush) if Furniture.is_furniture(brush) else brush
	if _brush_buttons.has(key):
		(_brush_buttons[key] as Button).button_pressed = true
	if _current_icon != null:
		_current_icon.texture = _thumb(brush)
		_current_label.text = _brush_name(brush)
	_refresh_variants()

func _wall_brush() -> bool:
	return brush.begins_with("wallmat:") or brush in [MCF.FEATURE_WALL, MCF.FEATURE_WOOD_WALL, MCF.FEATURE_ARMOR_WALL, MCF.FEATURE_GLASS, MCF.FEATURE_ARMOR_GLASS, MCF.FEATURE_SOIL]

## The current brush's variants (0.11): furniture colours, door textures or wall accents.
## Each entry: [icon, tooltip, action, selected].
func _variant_entries() -> Array:
	var out: Array = []
	var ids: Array = Furniture.colours_of(brush) if Furniture.is_furniture(brush) else []
	if ids.size() > 1:
		for fid: String in ids:
			out.append([_ghost(fid), Furniture.name_of(fid), _select_brush.bind(fid), fid == brush])
	elif brush == MCF.FEATURE_AIRLOCK or brush.begins_with("door:"):
		var current := int(brush.substr(5)) if brush.begins_with("door:") else brush_door
		out.append([_door_thumb(0), "Automatic door texture", _set_door.bind(0), current == 0])
		for material: String in TerrainTiles.DOOR_MATERIALS:
			for v in 3:
				var look := TerrainTiles.DOOR_MATERIALS.find(material) * 3 + v + 1
				out.append([_door_thumb(look), "%s · %d" % [material.capitalize(), v + 1], _set_door.bind(look), current == look])
	elif _wall_brush():
		for i in MCF.ACCENT_COLORS.size():
			out.append([_swatch(MCF.ACCENT_COLORS[i]), "Accent · " + MCF.ACCENT_NAMES[i], _set_accent.bind(i), brush_accent == i])
	return out

func _set_door(look: int) -> void:
	brush_door = look
	if brush.begins_with("door:"): brush = MCF.FEATURE_AIRLOCK
	_pv_key = ""
	_mark_brush_button()
	queue_redraw()

func _set_accent(i: int) -> void:
	brush_accent = i
	_pv_key = ""
	_refresh_variants()
	queue_redraw()

## Стрелки вариантов под текущей кистью: видны, когда у кисти больше одного варианта;
## подпись — имя выбранного и «номер / сколько».
func _refresh_variants() -> void:
	if _set_row != null:
		_set_row.visible = SmallItems.is_table(brush) and tool != Tool.ERASER
		if _set_row.visible:
			_set_label.text = "Items: " + SmallItems.SET_NAMES[SmallItems.SET_IDS.find(_table_set())]
	if _variant_row == null: return
	var entries := _variant_entries()
	_variant_row.visible = entries.size() > 1
	if not _variant_row.visible: return
	var sel := _variant_index(entries)
	_variant_icon.texture = entries[sel][0]
	_variant_label.text = "%s · %d/%d" % [entries[sel][1], sel + 1, entries.size()]
	_variant_label.tooltip_text = "%s (%s / %s)" % [entries[sel][1],
			Keybinds.label("editor_variant_prev"), Keybinds.label("editor_variant_next")]

func _variant_index(entries: Array) -> int:
	for i in entries.size():
		if bool(entries[i][3]):
			return i
	return 0

## Набор, которым кисть стола накрывает его сейчас.
func _table_set() -> String:
	return brush_table_set if brush_table_set != "" else SmallItems.default_set(brush)

func _cycle_table_set(d: int) -> void:
	brush_table_set = SmallItems.SET_IDS[posmod(SmallItems.SET_IDS.find(_table_set()) + d, SmallItems.SET_IDS.size())]
	_refresh_variants()

## Соседний вариант по кругу: d = −1 назад, +1 вперёд.
func _cycle_variant(d: int) -> void:
	var entries := _variant_entries()
	if entries.size() < 2: return
	var next: Array = entries[posmod(_variant_index(entries) + d, entries.size())]
	(next[2] as Callable).call()
	_refresh_variants()
	queue_redraw()

func _set_brush_size(n: int) -> void:
	brush_size = clampi(n, 1, 15)
	if _size_slider != null:
		_size_slider.set_value_no_signal(brush_size)
		_size_value.text = str(brush_size)
	_refresh_status()
	queue_redraw()

func _brush_name(id: String) -> String:
	if id == CORPSE_BRUSH: return "Corpse"
	if id == ITEM_ERASE: return "Erase items"
	if id.begins_with("item:"): return SmallItems.name_of(id.substr(5))
	if id.begins_with("decal:"): return id.substr(6).replace("_", " ").capitalize()
	if id.begins_with("accent:"): return MCF.ACCENT_NAMES[int(id.substr(7))] + " wall accent"
	if id.begins_with("door:"): return "Door texture %s" % id.substr(5)
	if id.begins_with("zone:"):
		var n := int(id.substr(5))
		return "No zone" if n < 0 else "Zone %d" % (n + 1)
	if id.begins_with("unit:"):
		return "%s (neutral)" % id.substr(5).capitalize()
	if id.begins_with("floor:"):
		return MCF.FLOOR_LOOK_NAMES[clampi(int(id.substr(6)), 0, MCF.FLOOR_LOOK_NAMES.size() - 1)]
	if id.begins_with("wallmat:"):
		return MCF.WALL_LOOK_NAMES[clampi(int(id.substr(8)), 0, MCF.WALL_LOOK_NAMES.size() - 1)]
	for group: Array in [TERRAIN, WALLS, OBJECTS]:
		for it: Array in group:
			if it[0] == id:
				return it[1]
	if Furniture.is_furniture(id):
		return "%s - %.1f m" % [Furniture.name_of(id), Furniture.height_of(id)]
	return id

## Подсказка кнопки мебели: высота, материал, прочность, подвижность, цена слома.
static func _furniture_hint(fid: String) -> String:
	var d: Dictionary = Furniture.def_of(fid)
	if Furniture.is_wall_light(fid):
		return "%s - attaches to a solid wall; R rotates\nShoot to destroy · durability %d\nLight strength %.2f · range %.1f tiles" % [Furniture.name_of(fid), int(d.dur), float(d.light_energy), float(d.light_range)]
	var move: String = {"portable": "carried by hand", "drag": "dragged",
			"fixed": "immovable"}[Furniture.mobility_name(fid)]
	if Furniture.joins(fid):
		# Соседние клетки того же вида срастаются в один предмет — а такой не берут в руки.
		move = "joins neighbors into one piece; " + ("dragged only as a single cell"
				if Furniture.draggable(fid) else "immovable")
	var cover := "wall-height" if Furniture.blocks_move(fid) \
			else ("cover −%d" % Furniture.cover_penalty(float(d["h"])) if Furniture.cover_penalty(float(d["h"])) > 0
			else "climbable, no cover")
	var colours := Furniture.colours_of(fid).size()
	var hint := "%s - %.1f m, %s, %s\n%s, durability %d, breaks for %d AP%s" % [Furniture.name_of(fid),
			float(d["h"]), d["mat"], cover, move[0].to_upper() + move.substr(1), int(d["dur"]), int(d["ap"]),
			"\n%d colors - pick one under the brush name" % colours if colours > 1 else ""]
	if Furniture.emits_light(fid): hint += "\nLight strength %.2f · range %.1f tiles" % [float(d.light_energy), float(d.light_range)]
	return hint

# --- Строка состояния и заголовок ---

func _refresh_status() -> void:
	if _status_label == null or map == null:
		return
	if _fp_pick:
		_status_label.text = "First person: click any free cell to walk there (Esc cancels; Esc in 3D comes back)."
		return
	var tname := ""
	for t: Dictionary in TOOLS:
		if t["tool"] == tool:
			tname = t["name"]
	var what := _brush_name(brush)
	if tool == Tool.STAMP:
		what = MapPresets.STAMPS[maxi(0, MapPresets.STAMPS.map(func(s): return s["id"]).find(stamp_id))]["name"]
	var parts: Array[String] = ["%s · %s" % [tname, what]]
	if tool in [Tool.BRUSH, Tool.ERASER, Tool.LINE]:
		parts[0] += " · size %d" % brush_size
	if Furniture.is_wall_light(brush) and tool != Tool.STAMP:
		parts[0] += " · %s (%s)" % ["open side of the wall" if brush_turn < 0 else SIDE_NAMES[brush_turn] + " side of the wall",
				Keybinds.label("editor_rotate")]
	elif Furniture.is_furniture(brush) and tool != Tool.STAMP:
		parts[0] += " · faces %s (%s)" % [turn_name(brush_turn), Keybinds.label("editor_rotate")]
	parts.append("%d×%d %s" % [map.width, map.height, MapPresets.name_of(_env)])
	if map.in_bounds(_hover):
		parts.append("(%d, %d) %s" % [_hover.x, _hover.y, _describe(_hover)])
	if symmetry != Sym.OFF:
		parts.append("Symmetry: " + SYM_NAMES[symmetry])
	if _has_selection():
		parts.append("Selection %d×%d" % [_selection.size.x, _selection.size.y])
	if not _float.is_empty():
		parts.append("Click to place · R rotate · H/V flip · Esc cancel")
	_status_label.text = "   |   ".join(parts)
	_zoom_label.text = "%d%%" % int(round(zoom * 100.0))
	_title_label.text = "%s%s" % [map_name if map_name != "" else "Untitled", " *" if _dirty else ""]

func _describe(c: Vector2i) -> String:
	var i := c.y * map.width + c.x
	var s: String = "Space" if map.is_space[i] != 0 else ("Grass" if map.floor_type[i] == MCF.FLOOR_GRASS
			else MCF.FLOOR_LOOK_NAMES[clampi(map.get_look(i), 0, MCF.FLOOR_LOOK_NAMES.size() - 1)])
	if map.feature_id[i] != "":
		s += " + " + _brush_name(map.feature_id[i])
	for lamp: Array in map.fixtures.get(i, []):
		s += " · %s on the %s side" % [Furniture.DEFS[str(lamp[0])].name, SIDE_NAMES[int(lamp[2])]]
	if map.zone_owner[i] >= 0:
		s += " · Zone %d" % (map.zone_owner[i] + 1)
	if _spawn_at.has(c):
		s += " · " + String(_spawn_at[c]["stats_id"]).capitalize()
	return s

## Короткое сообщение в строке состояния (сохранено, скопировано, ошибка…).
func _flash(text: String) -> void:
	_refresh_status()
	if _status_label != null:
		_status_label.text = text + "   |   " + _status_label.text

func _mark_dirty() -> void:
	_dirty = true
	_refresh_status()

# --- Картинки палитры и инструментов ---

## Значок мелкого предмета (0.12.1): картинка обрезана по самому предмету — в натуральную
## величину кружка на значке палитры была бы точкой.
var _item_thumbs: Dictionary = {}
func _item_thumb(kind: String) -> Texture2D:
	if _item_thumbs.has(kind):
		return _item_thumbs[kind]
	var tex := Sprites.texture_of(SmallItems.texture_name(kind))
	var img := tex.get_image() if tex != null else null
	var out: Texture2D = tex
	if img != null and not img.is_empty():
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		var r := img.get_used_rect()
		if r.size.x > 0 and r.size.y > 0:
			var side := maxi(r.size.x, r.size.y) + 2
			var sq := Image.create(side, side, false, Image.FORMAT_RGBA8)
			sq.blit_rect(img, r, Vector2i((side - r.size.x) / 2, (side - r.size.y) / 2))
			sq.resize(22, 22, Image.INTERPOLATE_NEAREST if side < 22 else Image.INTERPOLATE_LANCZOS)
			out = ImageTexture.create_from_image(sq)
	_item_thumbs[kind] = out
	return out

## Картинка кисти — та же плитка, что ляжет на карту, в окружении пресета.
func _thumb(id: String) -> Texture2D:
	if id.begins_with("accent:"): return _swatch(MCF.ACCENT_COLORS[clampi(int(id.substr(7)), 0, MCF.ACCENT_COLORS.size() - 1)])
	if id.begins_with("door:"): return _door_thumb(int(id.substr(5)))
	if id == MCF.FEATURE_AIRLOCK: return _door_thumb(brush_door)
	if id.begins_with("decal:"): return Sprites.texture_of("blood_splatter" if id == "decal:blood_drop" else id.substr(6))
	if id.begins_with("item:"): return _item_thumb(id.substr(5)) if id != ITEM_ERASE else null
	if id == CORPSE_BRUSH: return Sprites.texture_of("corpse")
	var env := _env
	if id.begins_with("unit:"):
		var key := Sprites.resolve(id.substr(5), "_neutral")
		return Sprites.texture_of(key) if key != "" else _swatch(Roster.NEUTRAL_COLOR)
	if id.begins_with("zone:"):
		var n := int(id.substr(5))
		return _swatch(owner_color(n) if n >= 0 else Color(0.2, 0.2, 0.2))
	if id.begins_with("preset:"):
		var data: Dictionary = RoomPresets.read_preset(id.substr(7))
		return _stamp_thumb(data["pattern"]) if not data.is_empty() else null
	if id.begins_with("stamp:"):
		return _stamp_thumb(MapPresets.stamp(id.substr(6)))
	var name: String = {"floor": "floor", "grass": "floor_grass", "space": "floor_space"}.get(id,
			Sprites.ALIASES.get(id, id))
	if id.begins_with("floor:"):
		name = MCF.FLOOR_LOOKS[clampi(int(id.substr(6)), 0, MCF.FLOOR_LOOKS.size() - 1)]
	if id.begins_with("wallmat:"):
		name = MCF.WALL_LOOKS[clampi(int(id.substr(8)), 0, MCF.WALL_LOOKS.size() - 1)]
	if id == "clear_object":
		name = "floor"
	elif id == MCF.FEATURE_AIRLOCK:
		name = "door"   # дверь спереди (0.9.2) — своя картинка окружения, без листа автотайла
	var full := TerrainTiles.env_name(name, env)
	var sheet := Sprites.texture_of(full + Sprites.AUTOTILE_SUFFIX)
	if sheet != null:
		var tw := sheet.get_width() / 4.0
		var at := AtlasTexture.new()
		at.atlas = sheet
		at.region = Rect2(2 * tw, 2 * tw, tw, tw)   # маска «восток+запад»: кусок стены
		return at
	var tex := Sprites.texture_of(full)
	if tex != null:
		var h := tex.get_height()
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(0, 0, h, h)
		return at
	return _swatch(Color(0.5, 0.5, 0.5))

func _door_thumb(look: int) -> Texture2D:
	var material := _env if look == 0 else str(TerrainTiles.DOOR_MATERIALS[(look - 1) / 3])
	var tex := Sprites.texture_of("door_" + material)
	if tex == null: return null
	var at := AtlasTexture.new()
	at.atlas = tex
	var side := tex.get_height()
	at.region = Rect2((0 if look == 0 else (look - 1) % 3) * side, 0, side, side)
	return at

func _pick_custom_preset(name: String) -> void:
	var data: Dictionary = RoomPresets.read_preset(name)
	if data.is_empty(): return
	_clipboard = data["pattern"].duplicate(true)
	paste()

func _swatch(c: Color) -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.08, 0.08, 0.08))
	img.fill_rect(Rect2i(1, 1, 14, 14), c)
	return ImageTexture.create_from_image(img)

func _stamp_thumb(p: Dictionary) -> ImageTexture:
	var w: int = p["w"]
	var h: int = p["h"]
	var s := maxi(w, h)
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var ox := (s - w) / 2
	var oy := (s - h) / 2
	for y in h:
		for x in w:
			var cell: Variant = p["cells"][y * w + x]
			if cell == null:
				continue
			var t: Array = cell
			var col := Color(0.55, 0.55, 0.52)
			if String(t[3]) == MCF.FEATURE_AIRLOCK:
				col = Color(0.85, 0.7, 0.25)
			elif MCF.is_glass(String(t[3])):
				col = Color(0.5, 0.75, 0.85)
			elif String(t[3]) == MCF.FEATURE_WOOD_WALL:
				col = Color(0.6, 0.4, 0.2)
			elif float(t[1]) >= MCF.WALL_HEIGHT:
				col = Color(0.32, 0.33, 0.36)
			elif String(t[3]) != "":
				col = Color(0.75, 0.62, 0.35)
			img.set_pixel(ox + x, oy + y, col)
	return ImageTexture.create_from_image(img)

## Значки инструментов — пиксель-арт 12×12, увеличенный вдвое без сглаживания: крупный
## «пиксель» (0.9.2: «сделать кнопки инструментов пиксельнее»). # — штрих, + — полутон,
## a — цвет акцента.
const TOOL_ART := {
	Tool.BRUSH: [
		"..........##", ".........#++", "........#++#", ".......#++#.",
		"......#++#..", ".....#++#...", "....#++#....", "...#++#.....",
		"..#a+#......", "..aa#.......", ".aaa........", "aa.........."],
	Tool.ERASER: [
		"............", "......####..", ".....#++++#.", "....#++++#..",
		"...#++++#...", "..####+#....", ".#...##.....", ".#..##......",
		"..###.......", "............", ".##########.", "............"],
	Tool.LINE: [
		"..........aa", "..........aa", ".........##.", "........##..",
		".......##...", "......##....", ".....##.....", "....##......",
		"...##.......", "..##........", "aa..........", "aa.........."],
	Tool.RECT: [
		"............", ".##########.", ".#........#.", ".#........#.",
		".#........#.", ".#........#.", ".#........#.", ".#........#.",
		".#........#.", ".##########.", "............", "............"],
	Tool.CIRCLE: [
		"....####....", "..##....##..", ".#........#.", ".#........#.",
		"#..........#", "#..........#", "#..........#", "#..........#",
		".#........#.", ".#........#.", "..##....##..", "....####...."],
	Tool.FILL: [
		"....##......", "...#..#.....", "..#....#....", ".########...",
		".#++++++#a..", ".#++++++#a..", "..#++++#.aa.", "...####..aa.",
		"............", "............", "............", "............"],
	Tool.SELECT: [
		"##.##.##.##.", "#..........#", "............", "#..........#",
		"#..........#", "............", "#..........#", "#..........#",
		"............", "#..........#", ".##.##.##.##", "............"],
	Tool.PICK: [
		".........aa.", "........aaaa", ".......#aaa.", "......#+#a..",
		".....#+#....", "....#+#.....", "...#+#......", "..#+#.......",
		".#+#........", ".##.........", "a...........", "............"],
	Tool.STAMP: [
		"....####....", "....####....", ".....##.....", ".....##.....",
		"..########..", "..########..", "..########..", "............",
		".aaaaaaaaaa.", ".aaaaaaaaaa.", "............", "............"],
}

func _tool_icon(t: int) -> ImageTexture:
	var art: Array = TOOL_ART.get(t, [])
	var img := Image.create(24, 24, false, Image.FORMAT_RGBA8)
	var cols := {"#": Color(0.9, 0.9, 0.9), "+": Color(0.55, 0.55, 0.58), "a": Ui.accent_color()}
	for y in art.size():
		var row: String = art[y]
		for x in row.length():
			var ch := row[x]
			if cols.has(ch):
				img.fill_rect(Rect2i(x * 2, y * 2, 2, 2), cols[ch])
	return ImageTexture.create_from_image(img)

# ============================================================================
# Файлы и сцены
# ============================================================================

func save() -> void:
	if map_name == "":
		_name_dialog()   # безымянная карта: имя спрашиваем один раз, при первом сохранении
		return
	_save_named(map_name)

func _save_named(name: String) -> bool:
	var fname := name if name.ends_with(".json") else name + ".json"
	if map.save_to("%s/%s" % [MapData.MAPS_DIR, fname]):
		map_name = fname.get_basename()
		_dirty = false
		_flash("Saved %s - it appears in the lobby's map list" % fname)
		return true
	_flash("Could not save %s" % fname)
	return false

func play() -> void:
	MapHandoff.editor_session = {"map": map, "name": map_name, "dirty": _dirty, "pan": pan, "zoom": zoom}
	# Бою — копию: правки боя (если когда-нибудь появятся) не должны вернуться в редактор.
	MapHandoff.pending = MapData.from_dict(map.to_dict())
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

## Выход в главное меню (#104): слот передачи пуст, иначе нарисованная карта ушла бы в
## следующую партию из меню.
func exit_to_menu() -> void:
	var leave := func() -> void:
		MapHandoff.editor_session = {}
		MapHandoff.pending = null
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
	if _dirty:
		_confirm("Leave Editor", "You have unsaved changes. Leave without saving?", "Leave", leave)
	else:
		leave.call()

## Новый документ: откат начинается с чистого листа, как в любом редакторе.
func _adopt(m: MapData, name: String) -> void:
	map = m
	map_name = name
	_dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	_map_replaced()
	_refresh_menu_checks()
	fit_view()

## Создать карту из настроек диалога (или напрямую — из теста).
func create_map(name: String, env: String, size: Vector2i, generator: Dictionary = {}) -> void:
	var m: MapData
	if generator.is_empty():
		m = MapData.new(clampi(size.x, 8, MAX_DIM), clampi(size.y, 8, MAX_DIM))
		MapPresets.prefill(m, env)
	else:
		var style := MapPresets.index_of(env)
		var o := {"style": style, "size": MapGen.SIZE_CUSTOM,
				"width": clampi(size.x, MapGen.MIN_DIM, MAX_DIM), "height": clampi(size.y, MapGen.MIN_DIM, MAX_DIM),
				"space": MapGen.STYLE_SPACE[style], "flammable": MapGen.STYLE_FLAMMABLE[style]}
		o.merge(generator, true)
		m = MapGen.generate(o)
		m.env = env
	_adopt(m, name)
	_dirty = true
	_refresh_status()

func resize_map(w: int, h: int) -> void:
	w = clampi(w, 8, MAX_DIM)
	h = clampi(h, 8, MAX_DIM)
	if w == map.width and h == map.height:
		return
	var before := map.to_dict()
	var old := Vector2i(map.width, map.height)
	map.resize_keep(w, h)
	# Новые клетки — пустая земля пресета, а не всегда космос.
	var b := MapPresets.blank_cell(map.environment())
	for y in h:
		for x in w:
			if x >= old.x or y >= old.y:
				map.set_cell(Vector2i(x, y), b[0], b[1], b[2], b[3])
	_map_replaced()
	_push_full(before)

func clear_map() -> void:
	var before := map.to_dict()
	MapPresets.prefill(map, map.environment())
	_map_replaced()
	_push_full(before)

# ============================================================================
# Диалоги в стиле набора
# ============================================================================

## Окно поверх редактора: затемнение, рамка с заголовком, содержимое и кнопки справа
## внизу. buttons: [[текст, Callable или null — просто закрыть]]; Esc закрывает.
func _dialog(title: String, content: Control, buttons: Array, width: float = 380.0) -> void:
	_close_modal()
	_modal = CanvasLayer.new()
	_modal.layer = 90
	add_child(_modal)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = Ui.theme
	_modal.add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	SteamChrome.apply_panel(panel)
	panel.custom_minimum_size = Vector2(width, 0)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	panel.add_child(col)
	col.add_child(SteamChrome.header_bar(title))
	col.add_child(SteamChrome.pad(content, 16, 12))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	col.add_child(SteamChrome.pad(row, 16, 12))
	for spec: Array in buttons:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(96, 0)
		var act: Variant = spec[1]
		b.pressed.connect(func() -> void:
			if act is Callable:
				if (act as Callable).call() == false:
					return   # действие отказалось (например, пустое имя) — окно остаётся
			_close_modal())
		row.add_child(b)

func _close_modal() -> void:
	if _modal != null:
		_modal.queue_free()
		_modal = null

func _confirm(title: String, message: String, ok_text: String, on_ok: Callable) -> void:
	var l := Label.new()
	l.text = message
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(320, 0)
	_dialog(title, l, [["Cancel", null], [ok_text, func() -> void: on_ok.call_deferred()]])

func _field_row(parent: Container, label: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(96, 0)
	l.add_theme_color_override("font_color", Color("#b0b0b0"))
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)

func _spin(v: int, lo: int, hi: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = v
	return s

func _preset_option(env: String) -> OptionButton:
	var o := OptionButton.new()
	for n: String in MapPresets.NAMES:
		o.add_item(n)
	o.select(MapPresets.index_of(env))
	return o

func _new_map_dialog() -> void:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "map name"
	_field_row(body, "Name", name_edit)
	var preset := _preset_option(map.environment())
	preset.tooltip_text = "Sets the tiles (walls, floors, doors) and how a new map starts."
	_field_row(body, "Preset", preset)
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 6)
	var w := _spin(DEFAULT_SIZE.x, 8, MAX_DIM)
	var h := _spin(DEFAULT_SIZE.y, 8, MAX_DIM)
	size_row.add_child(w)
	var x := Label.new()
	x.text = "×"
	size_row.add_child(x)
	size_row.add_child(h)
	_size_presets(body, w, h)
	_field_row(body, "Size", size_row)
	var start := SteamChrome.group_box("Start from")
	body.add_child(start)
	var group := ButtonGroup.new()
	var blank := CheckBox.new()
	blank.text = "The preset's ground (Station deck, Town street, Field grass, Bunker rock, Asteroid island)"
	blank.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blank.button_group = group
	blank.button_pressed = true
	start.body.add_child(blank)
	var gen := CheckBox.new()
	gen.text = "A random map from the generator, to edit further"
	gen.button_group = group
	start.body.add_child(gen)
	var gbox := VBoxContainer.new()
	gbox.add_theme_constant_override("separation", 8)
	start.body.add_child(gbox)
	var dens := OptionButton.new()
	for d: String in MapGen.DENSITY_NAMES:
		dens.add_item(d)
	dens.select(1)
	_field_row(gbox, "Density", dens)
	var players := _spin(2, 2, 8)
	_field_row(gbox, "Zones", players)
	var seed_row := HBoxContainer.new()
	var seed := _spin(randi_range(1, MapGen.SEED_MAX), 1, MapGen.SEED_MAX)
	seed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(seed)
	var roll := Button.new()
	roll.text = "Roll"
	roll.pressed.connect(func() -> void: seed.value = randi_range(1, MapGen.SEED_MAX))
	seed_row.add_child(roll)
	_field_row(gbox, "Seed", seed_row)
	var sym := CheckBox.new()
	sym.text = "Symmetrical"
	gbox.add_child(sym)
	var civ := CheckBox.new()
	civ.text = "Civilians"
	civ.button_pressed = true
	gbox.add_child(civ)
	var sync_gen := func() -> void:
		for c in gbox.find_children("*", "Control", true, false):
			if c is BaseButton:
				(c as BaseButton).disabled = not gen.button_pressed
			elif c is SpinBox:
				(c as SpinBox).editable = gen.button_pressed
		gbox.modulate = Color(1, 1, 1, 1.0 if gen.button_pressed else 0.45)
	gen.toggled.connect(func(_on: bool) -> void: sync_gen.call())
	sync_gen.call()
	var create := func() -> Variant:
		var nm := name_edit.text.strip_edges()
		var env: String = MapPresets.IDS[preset.selected]
		var o := {}
		if gen.button_pressed:
			o = {"density": dens.selected, "zones": int(players.value), "seed": int(seed.value),
					"symmetric": sym.button_pressed, "civilians": 2 if civ.button_pressed else 0}
		# Размер — сейчас, а не в замыкании: подтверждение «потерять правки» срабатывает уже
		# после того, как это окно закрыто и его поля освобождены (0.9.2: Nil 'value').
		var size := Vector2i(int(w.value), int(h.value))
		var go := func() -> void: create_map(nm, env, size, o)
		if _dirty:
			_confirm("New Map", "You have unsaved changes. Start a new map and lose them?", "New Map", go)
			return false
		go.call()
		return true
	_dialog("New Map", body, [["Cancel", null], ["Create", create]], 440.0)
	name_edit.grab_focus.call_deferred()

func _open_dialog() -> void:
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(220, 260)
	body.add_child(list)
	var names := MapData.list_maps()
	for n in names:
		list.add_item(n.get_basename())
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 8)
	body.add_child(side)
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(200, 150)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	side.add_child(preview)
	var info := Label.new()
	info.add_theme_color_override("font_color", Color("#b0b0b0"))
	side.add_child(info)
	var chosen := [-1]
	list.item_selected.connect(func(i: int) -> void:
		chosen[0] = i
		var m := MapData.load_from(MapData.path_for(names[i]))
		if m == null:
			info.text = "Can't read this map"
			preview.texture = null
			return
		var img := Image.create(m.width, m.height, false, Image.FORMAT_RGBA8)
		var menv := m.environment()
		for k in m.width * m.height:
			img.set_pixel(k % m.width, k / m.width, map_color(m, k, menv))
		preview.texture = ImageTexture.create_from_image(img)
		info.text = "%d×%d · %s" % [m.width, m.height, MapPresets.name_of(m.environment())])
	var do_open := func() -> Variant:
		if chosen[0] < 0:
			return false
		var fname: String = names[chosen[0]]
		var go := func() -> void: open_map(fname)
		if _dirty:
			_confirm("Open Map", "You have unsaved changes. Open “%s” and lose them?" % fname.get_basename(),
					"Open", go)
			return false
		go.call()
		return true
	list.item_activated.connect(func(_i: int) -> void:
		if do_open.call() == true:
			_close_modal())
	if names.is_empty():
		info.text = "No saved maps yet."
	else:
		list.select(0)
		list.item_selected.emit(0)
	_dialog("Open Map", body, [["Cancel", null], ["Open", do_open]], 470.0)

func open_map(fname: String) -> bool:
	var m := MapData.load_from(MapData.path_for(fname))
	if m == null:
		_flash("Could not open %s" % fname)
		return false
	_adopt(m, fname.get_basename())
	_flash("Opened %s" % fname.get_basename())
	return true

## Имя для первого сохранения. «Сохранить как» больше нет (0.9.2): оно делало то же, что
## «Сохранить»; копию под другим именем даёт New + Paste или переименование файла.
func _name_dialog() -> void:
	var body := VBoxContainer.new()
	var name_edit := LineEdit.new()
	name_edit.text = map_name
	name_edit.placeholder_text = "map name"
	_field_row(body, "Name", name_edit)
	var do_save := func() -> Variant:
		var nm := name_edit.text.strip_edges().replace("/", "_").replace("\\", "_")
		if nm == "":
			_flash("Enter a map name first")
			return false
		if nm != map_name and MapData.list_maps().has(nm + ".json"):
			_confirm("Replace Map", "A map called “%s” already exists. Replace it?" % nm, "Replace",
					func() -> void: _save_named(nm))
			return false
		return _save_named(nm)
	name_edit.text_submitted.connect(func(_t: String) -> void:
		if do_save.call() == true:
			_close_modal())
	_dialog("Save Map", body, [["Cancel", null], ["Save", do_save]])
	name_edit.grab_focus.call_deferred()

func _resize_dialog() -> void:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	var w := _spin(map.width, 8, MAX_DIM)
	var h := _spin(map.height, 8, MAX_DIM)
	_size_presets(body, w, h)
	_field_row(body, "Width", w)
	_field_row(body, "Height", h)
	var hint := Label.new()
	hint.text = "The top-left corner stays put; new cells are the preset's empty ground."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color("#8a8a8a"))
	body.add_child(hint)
	_dialog("Resize Map", body, [["Cancel", null], ["Resize", func() -> void:
		resize_map(int(w.value), int(h.value))
		fit_view()]])

func _shortcuts_dialog() -> void:
	var window := SettingsWindow.open(self)
	window.show_keybinds(true)

func _refresh_shortcut_labels() -> void:
	for entry: Dictionary in TOOLS:
		if _tool_buttons.has(entry.tool):
			_tool_buttons[entry.tool].tooltip_text = "%s (%s)\n%s" % [entry.name, Keybinds.label(entry.action), entry.hint]
	for menu: PopupMenu in _menus.values():
		for index in menu.item_count:
			var meta: Variant = menu.get_item_metadata(index)
			if meta is Dictionary and meta.has("key_action"):
				menu.set_item_text(index, "%s  (%s)" % [meta.title, Keybinds.label(meta.key_action)])
	if _size_slider != null:
		_size_slider.tooltip_text = "Brush size (%s / %s)" % [Keybinds.label("editor_smaller"), Keybinds.label("editor_larger")]
	_refresh_status()

func _clear_dialog() -> void:
	_confirm("Clear Map", "Erase everything and start again from the %s preset's ground? You can undo this."
			% MapPresets.name_of(map.environment()), "Clear", clear_map)

func _size_presets(body: Container, w: SpinBox, h: SpinBox) -> void:
	var choice := OptionButton.new()
	for label: String in ["Custom", "Small · 52 × 44", "Medium · 74 × 62", "Large · 104 × 84", "Giant · 149 × 119"]:
		choice.add_item(label)
	var sizes := [Vector2i.ZERO, Vector2i(52, 44), Vector2i(74, 62), Vector2i(104, 84), Vector2i(149, 119)]
	choice.item_selected.connect(func(i: int) -> void:
		if i > 0:
			w.value = sizes[i].x
			h.value = sizes[i].y
			choice.select(i))
	w.value_changed.connect(func(_v: float) -> void: choice.select(0))
	h.value_changed.connect(func(_v: float) -> void: choice.select(0))
	_field_row(body, "Size preset", choice)

func _sync_editor_decals() -> void:
	_grid.map_decals = map.decals.duplicate(true)
	_tiles.set_map_decals()

func _sync_editor_items() -> void:
	var before := _grid.map_items
	_grid.map_items = map.items.duplicate(true)
	_tiles.set_map_items(before)
	_mark_dirty()

## Стереть предметы в круге кисти вокруг pos.
func _erase_items(pos: Vector2) -> void:
	var r := float(brush_size) * 0.5
	var left := map.items.filter(func(it: Array) -> bool: return Vector2(float(it[1]), float(it[2])).distance_to(pos) > r)
	if left.size() != map.items.size():
		map.items = left
		_sync_editor_items()

## Стол, поставленный этим действием, получает предметы своего набора (0.12.1); со снятого
## стола они уходят вместе с ним. Раскладка — по каждому новому столу целиком.
func _furnish_new_tables() -> void:
	# Вставка, заготовка и пресет несут свои предметы — раскладывает только рисование и ластик.
	if not _float.is_empty() or not (tool in [Tool.BRUSH, Tool.ERASER, Tool.LINE, Tool.RECT, Tool.CIRCLE, Tool.FILL]):
		return
	var placed: Dictionary = {}   # клетка -> id стола
	var cleared: Dictionary = {}
	for i: int in _act.get("cells", {}):
		var before := String((_act["cells"][i] as Array)[3])
		var after := String(map.feature_id[i])
		if before == after:
			continue
		var c := Vector2i(i % map.width, i / map.width)
		if SmallItems.is_table(before):
			cleared[c] = true
		if SmallItems.is_table(after):
			placed[c] = after
	if placed.is_empty() and cleared.is_empty():
		return
	var items := map.items.filter(func(it: Array) -> bool:
		var c := SmallItems.cell_of(it)
		return not cleared.has(c) and not placed.has(c))
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var done: Dictionary = {}
	for c: Vector2i in placed:
		if done.has(c):
			continue
		var fid: String = placed[c]
		var piece := Furniture.piece_cells(func(q: Vector2i) -> String:
			return String(map.feature_id[q.y * map.width + q.x]) if map.in_bounds(q) else "", c)
		for q: Vector2i in piece:
			done[q] = true
		var set_id := _table_set() if Furniture.base_of(brush) == Furniture.base_of(fid) else SmallItems.default_set(fid)
		var fresh := piece.filter(func(q: Vector2i) -> bool: return placed.has(q))
		items.append_array(SmallItems.arrange(set_id, fresh, SmallItems.turn_on_map(map, piece[0]), rng))
	map.items = items
	_sync_editor_items()

func _save_room_dialog() -> void:
	if not _has_selection():
		_flash("Select the room or structure first.")
		return
	var body := VBoxContainer.new()
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Room or structure name"
	body.add_child(name_edit)
	var hint := Label.new()
	hint.text = "An existing name updates that preset. Map cells stay unchanged."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	_dialog("Save Selection as Preset", body, [["Cancel", null], ["Save", func() -> void:
		var pattern := MapPresets.capture(map, _selection)
		if RoomPresets.save_preset(name_edit.text, pattern, _env):
			_refresh_palette()
			_flash("Preset saved. Find it under Presets → Manage Rooms & Structures.")
		else: _flash("Could not save preset; use a non-empty name.")]])

func _room_manager() -> void:
	var body := VBoxContainer.new()
	var names: Array = RoomPresets.names()
	var pick := OptionButton.new()
	for name: String in names: pick.add_item(name)
	body.add_child(pick)
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(400, 250)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	body.add_child(preview)
	var note := Label.new()
	note.text = "Place a preset, edit its cells, then select it and save under the same name to update it." if not names.is_empty() else "No presets. Select a room, then use Presets → Save Selection."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)
	var selected := func() -> Dictionary:
		return RoomPresets.read_preset(names[pick.selected]) if pick.selected >= 0 else {}
	var refresh := func(_i: int = 0) -> void:
		var data: Dictionary = selected.call()
		if not data.is_empty():
			preview.texture = TerrainTiles.map_preview(RoomPresets.to_map(data["pattern"], str(data.get("env", "station"))))
	pick.item_selected.connect(refresh)
	refresh.call()
	var rename_row := HBoxContainer.new()
	var new_name := LineEdit.new()
	new_name.placeholder_text = "New name"
	new_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rename_row.add_child(new_name)
	var rename := Button.new()
	rename.text = "Rename"
	rename.pressed.connect(func() -> void:
		if pick.selected >= 0 and RoomPresets.rename_preset(names[pick.selected], new_name.text.strip_edges()):
			_refresh_palette()
			_room_manager.call_deferred())
	rename_row.add_child(rename)
	body.add_child(rename_row)
	_dialog("Room & Structure Presets", body, [["Close", null], ["Delete", func() -> void:
		if pick.selected >= 0: RoomPresets.remove_preset(names[pick.selected])
		_refresh_palette()
		_room_manager.call_deferred()], ["Place / Edit", func() -> void:
		var data: Dictionary = selected.call()
		if not data.is_empty():
			_clipboard = data["pattern"].duplicate(true)
			paste()]], 460.0)

func _sync_camera_layer() -> void:
	if _layer != null:
		_layer.position = pan
		_layer.scale = Vector2(zoom, zoom)
	queue_redraw()
