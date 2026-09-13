extends Node2D

## Встроенный редактор карт (M5, §11). Рисуем рельеф, укрытия, космос и точки
## спавна кистями, сохраняем/загружаем JSON (user://maps). Работает с данными
## MapData; симуляция строится из карты через MapData.build_state().
## Запускается напрямую как сцена; «Play» открывает Main с выбранной картой.
##
## Отрисовка (batch 13 #6). Раньше _draw() обходил ВСЕ клетки карты и на каждую клал
## по 3–5 команд рисования: на поле 200×200 это 150–200 тысяч команд на кадр, а кадр
## запрашивается на каждое движение мыши с зажатой кнопкой. Теперь:
##   • подложка (пол/космос/стена/укрытие/зона) — ОДНА текстура, пиксель на клетку,
##     рисуется одним draw_texture_rect; кисть меняет пиксели точечно;
##   • всё поверх (сетка, объекты, спавны, превью) рисуется только для клеток В КАДРЕ и
##     с уровнями детализации: мелкие клетки не получают ни подписей, ни сетки.
## Стоимость кадра больше не зависит от размера карты — только от размера экрана.

const CELL := 40
const ORIGIN := Vector2(40, 40)
## Оформление панелей в общем стиле интерфейса (item 11).
const SteamChrome = preload("res://src/ui/SteamChrome.gd")

## Цвет стороны в редакторе — тот же, что и в бою: палитра ростера. Редактор не
## знает состава партии, поэтому берёт цвет прямо по номеру игрока.
static func owner_color(owner_id: int) -> Color:
	if MCF.is_neutral(owner_id):
		return Roster.NEUTRAL_COLOR
	if MCF.is_player(owner_id):
		return Roster.PALETTE[owner_id % Roster.PALETTE.size()]
	return Color.WHITE

# Кисти рельефа и объектов — двумя группами, чтобы «пол» и «что стоит на полу» не
# лежали в одной куче (batch 13 #14). Спавн-кисти обрабатываются отдельно.
const TERRAIN_BRUSHES := [
	{"id": "floor", "label": "Floor"},
	{"id": "grass", "label": "Grass Floor"},
	{"id": "space", "label": "Space"},
]
const OBJECT_BRUSHES := [
	{"id": MCF.FEATURE_WALL, "label": "Wall"},
	{"id": MCF.FEATURE_WOOD_WALL, "label": "Wooden Wall"},
	{"id": MCF.FEATURE_GLASS, "label": "Glass"},
	{"id": MCF.FEATURE_ARMOR_WALL, "label": "Armored Wall"},
	{"id": MCF.FEATURE_ARMOR_GLASS, "label": "Armored Glass"},
	{"id": MCF.FEATURE_SANDBAGS, "label": "Sandbags"},
	{"id": MCF.FEATURE_HEDGEHOG, "label": "Hedgehog"},
	{"id": MCF.FEATURE_TRENCH, "label": "Trench"},
	{"id": MCF.FEATURE_LDF, "label": "LDF"},
	{"id": MCF.FEATURE_AIRLOCK, "label": "Airlock"},
	{"id": MCF.FEATURE_DOT, "label": "Pillbox"},
	{"id": MCF.FEATURE_DOT_OPEN, "label": "Pillbox (Embrasures)"},
]

## Ширина боковых колонок редактора и отступ их содержимого от рамки. Обе колонки
## строятся по этим числам, поэтому и выглядят одинаково — на глаз подбирать нечего.
const PANEL_WIDTH := 280.0
const PANEL_PADDING := 14.0

## Инструменты рисования (как в редакторе Crazy Ball Runner): кисть, линия,
## прямоугольник, заливка.
enum Tool { PAINT, LINE, RECT, FILL }
const TOOL_NAMES := {Tool.PAINT: "Paint", Tool.LINE: "Line", Tool.RECT: "Rectangle", Tool.FILL: "Fill"}

var map: MapData
var brush: String = MCF.FEATURE_WALL
var _brush_label: String = "Wall"
## Радиус кисти (batch 13 #14): 1 = одна клетка. Действует на Paint; на большой карте
## красить пол по клетке — мучение.
var brush_size: int = 1
## Владелец кисти зоны развёртывания (#52); -1 = стирать зону.
var zone_brush_owner: int = MCF.Owner.PLAYER_1
## Псевдо-владелец кисти: «тот игрок, что выбран в списке сторон».
const ZONE_SELECTED_PLAYER := -2
var _zone_player_opt: OptionButton
## Выбранный в списке тип нейтрального юнита для кисти «spawn_neutral» (item 5).
var _neutral_unit_opt: OptionButton
## Типы юнитов, которых можно поставить нейтралом прямо на карту (item 5): любая
## существующая пехота. Порядок фиксирован — по нему список и id.
const NEUTRAL_UNIT_IDS := [
	"civilian", "light_infantry", "heavy_infantry", "assault", "machinegunner",
	"sniper", "marksman", "anti_tank", "flamethrower", "shield_bearer",
	"engineer", "miner", "sapper", "commander", "drone_operator",
]

var tool: int = Tool.PAINT
## Начало/текущая клетка перетаскивания для линии/прямоугольника (-1 = нет).
var _drag_start: Vector2i = Vector2i(-1, -1)
var _drag_cur: Vector2i = Vector2i(-1, -1)
## Клетка под курсором — для строки состояния и подсветки.
var _hover: Vector2i = Vector2i(-1, -1)

## Смещение «камеры» (панорама) и коэффициент масштаба.
var pan: Vector2 = Vector2.ZERO
var zoom: float = 1.0
const PAN_SPEED := 700.0        # px/сек для WASD
## Нижний предел отодвинут (batch 13 #6): большая карта обязана помещаться на экран
## целиком, а подложка-текстура стоит одинаково при любом масштабе.
const ZOOM_MIN := 0.06
const ZOOM_MAX := 2.5
var _mouse_panning: bool = false

## Пороги детализации по размеру клетки на экране (px).
const LOD_GRID := 7.0      # ниже — сетку не рисуем
const LOD_TAGS := 14.0     # ниже — объекты и спавны без подписей, одной меткой
const LOD_SPRITES := 18.0  # ниже — картинки-замены пола не рисуем (подложки хватает)

# --- Подложка-текстура ---
var _base_img: Image = null
var _base_tex: ImageTexture = null
## Пиксели правились с последнего кадра — текстуру надо обновить.
var _base_stale: bool = false
## Есть ли картинки-замены для пола: тогда при крупной клетке рисуем их поверх.
var _floor_sprites: bool = false

## Несохранённые правки — звёздочка в заголовке и предупреждение при выходе.
var _dirty: bool = false

## Откат/повтор (batch 14): снимки карты целиком (MapData.to_dict) по одному на
## ДЕЙСТВИЕ — мазок от нажатия до отпускания, линия, прямоугольник, заливка, размер,
## очистка, загрузка. Снимок — плоские массивы, на 200×200 это единицы мегабайт;
## глубина ограничена, чтобы долгая сессия не съела память.
const UNDO_DEPTH := 40
var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _undo_btn: Button = null
var _redo_btn: Button = null

var _ui: CanvasLayer
var _name_edit: LineEdit
var _status: Label
var _maps_option: OptionButton
var _w_spin: SpinBox
var _h_spin: SpinBox
var _title: Label
var _tool_buttons: Dictionary = {}
var _brush_buttons: Dictionary = {}
var _brush_group := ButtonGroup.new()
var _tool_group := ButtonGroup.new()
var _size_label: Label

func _ready() -> void:
	Sprites.reload_overrides()  # подменённые картинки видны и в редакторе (#55)
	# Подложка — пиксель на клетку, растянутый до размера клетки: фильтрация должна
	# быть ступенчатой, иначе границы клеток размажутся.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	map = MapData.new(16, 12)
	map.fill_all_space()  # пустая карта — сплошной космос, пол рисует игрок
	_floor_sprites = Sprites.has_override("floor") or Sprites.has_override("floor_space") \
			or Sprites.has_override("floor_wall")
	_rebuild_base()
	_build_ui()
	Ui.theme_canvas_layers()  # editor toolbar is on a CanvasLayer; apply Steam skin.
	_refresh_maps_list()
	_select_tool(Tool.PAINT)
	_select_brush(MCF.FEATURE_WALL, "Wall")
	set_process(true)
	queue_redraw()

# --- Панорама камеры по WASD (§редактор) ---
func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): dir.y += 1
	if Input.is_key_pressed(KEY_S): dir.y -= 1
	if Input.is_key_pressed(KEY_A): dir.x += 1
	if Input.is_key_pressed(KEY_D): dir.x -= 1
	if dir != Vector2.ZERO:
		pan += dir.normalized() * PAN_SPEED * delta
		queue_redraw()

# --- Ввод ---
func _unhandled_input(event: InputEvent) -> void:
	# Ctrl+Z / Ctrl+Y (и Ctrl+Shift+Z) — откат и повтор (batch 14).
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed:
		if event.keycode == KEY_Z and event.shift_pressed:
			_redo(); return
		if event.keycode == KEY_Z:
			_undo(); return
		if event.keycode == KEY_Y:
			_redo(); return
	# Горячие клавиши инструментов (batch 13 #14): 1–4, чтобы не тянуться к панели.
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: _select_tool(Tool.PAINT); return
			KEY_2: _select_tool(Tool.LINE); return
			KEY_3: _select_tool(Tool.RECT); return
			KEY_4: _select_tool(Tool.FILL); return
	# Панорама мышью: средняя или правая кнопка «тянет» карту.
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		_mouse_panning = event.pressed
		return
	# Колесо мыши: масштаб к курсору (или панорама тачпадом — см. pan-gesture ниже).
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var factor := 1.1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.1
		_zoom_at(get_global_mouse_position(), factor)
		return
	# Жест панорамы тачпадом (двумя пальцами).
	if event is InputEventPanGesture:
		pan -= event.delta * 24.0
		queue_redraw()
		return
	# Жест «щипок» тачпадом → масштаб.
	if event is InputEventMagnifyGesture:
		_zoom_at(get_global_mouse_position(), event.factor)
		return
	if event is InputEventMouseMotion and _mouse_panning:
		pan += event.relative
		queue_redraw()
		return
	if event is InputEventMouseMotion:
		var hc := _pos_to_cell(get_global_mouse_position())
		if hc != _hover:
			_hover = hc
			_refresh_status()
			# Подсветка курсора перерисовывается только при крупной клетке — мелкую
			# всё равно не разглядеть, а кадр на каждое движение мыши стоит денег.
			if _cell_size() >= LOD_GRID:
				queue_redraw()

	# Рисование инструментами.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var coord := _pos_to_cell(get_global_mouse_position())
		if event.pressed:
			match tool:
				Tool.PAINT:
					_push_undo()  # один снимок на весь мазок
					_paint(coord)
				Tool.FILL:
					_push_undo()
					_flood_fill(coord)
				Tool.LINE, Tool.RECT:
					_drag_start = coord
					_drag_cur = coord
					queue_redraw()
		else:
			# Отпустили — фиксируем линию/прямоугольник.
			if tool in [Tool.LINE, Tool.RECT] and _drag_start != Vector2i(-1, -1):
				_push_undo()
				var cells := _line_cells(_drag_start, _drag_cur) if tool == Tool.LINE else _rect_cells(_drag_start, _drag_cur)
				for c in cells:
					_apply_brush(c)
				_drag_start = Vector2i(-1, -1)
				_drag_cur = Vector2i(-1, -1)
				queue_redraw()
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var coord := _pos_to_cell(get_global_mouse_position())
		if tool == Tool.PAINT:
			_paint(coord)
		elif tool in [Tool.LINE, Tool.RECT] and _drag_start != Vector2i(-1, -1):
			if coord != _drag_cur:
				_drag_cur = coord
				queue_redraw()

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := _pos_to_cell(screen_pos)
	zoom = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	# Держим клетку под курсором на месте.
	var after := _pos_to_cell(screen_pos)
	var cs := _cell_size()
	pan += Vector2(after.x - before.x, after.y - before.y) * cs
	queue_redraw()

## Кисть с радиусом (batch 13 #14): квадрат brush_size×brush_size вокруг клетки.
func _paint(coord: Vector2i) -> void:
	if brush_size <= 1:
		_apply_brush(coord)
	else:
		var r0 := -(brush_size - 1) / 2
		var r1 := brush_size / 2
		for dy in range(r0, r1 + 1):
			for dx in range(r0, r1 + 1):
				_apply_brush(coord + Vector2i(dx, dy))
	queue_redraw()

## Применить текущую кисть к клетке без перерисовки (для инструментов).
func _apply_brush(coord: Vector2i) -> void:
	if not map.in_bounds(coord):
		return
	match brush:
		"erase":
			# Ластик убирает пол → клетка снова космос (нет пола = космос, §3.11).
			map.set_cell(coord, MCF.FLOOR_NORMAL, 0.0, true, "")
			map.clear_spawn_at(coord)
			map.set_zone(coord, -1)
		"space":
			map.set_cell(coord, map.get_floor(coord), map.get_cover(coord), true, map.get_feature(coord))
		"floor":
			# Обычный твёрдый пол (снимает космос).
			map.set_cell(coord, MCF.FLOOR_NORMAL, map.get_cover(coord), false, map.get_feature(coord))
		"grass":
			# Травяной пол (#14): такой же пол, только загорается почти наверняка (5/6).
			map.set_cell(coord, MCF.FLOOR_GRASS, map.get_cover(coord), false, map.get_feature(coord))
		"zone":
			# Кисть зоны развёртывания (#52): красим владельца региона, не трогая рельеф.
			map.set_zone(coord, zone_brush_owner)
		"spawn_neutral":
			# Нейтральный юнит (item 5): ставим на пол выбранный тип с owner == NEUTRAL.
			# Один спавн на клетку — сперва снимаем прежний, если он тут был.
			var uid: String = str(NEUTRAL_UNIT_IDS[_neutral_unit_opt.get_selected_id()]) \
					if _neutral_unit_opt != null else "civilian"
			map.set_cell(coord, MCF.FLOOR_NORMAL if map.get_space(coord) else map.get_floor(coord),
					map.get_cover(coord), false, map.get_feature(coord))
			map.clear_spawn_at(coord)
			map.set_spawn(coord, uid, MCF.Owner.NEUTRAL)
		"clear_object":
			# Снять объект, оставив пол как есть.
			map.set_cell(coord, map.get_floor(coord), 0.0, map.get_space(coord), "")
		_:
			# Кисть-объект: под укрытием подразумевается пол, поэтому снимаем космос.
			var h: float = MCF.FEATURE_HEIGHT.get(brush, 0.0)
			map.set_cell(coord, map.get_floor(coord), h, false, brush)
	_refresh_base_cell(coord)
	_mark_dirty()

# --- Инструменты рисования ---
## Клетки прямой Брезенхэма между a и b (включительно).
func _line_cells(a: Vector2i, b: Vector2i) -> Array:
	var cells: Array = []
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

## Клетки контура прямоугольника от a до b (только рамка).
func _rect_cells(a: Vector2i, b: Vector2i) -> Array:
	var cells: Array = []
	var x0 := mini(a.x, b.x)
	var x1 := maxi(a.x, b.x)
	var y0 := mini(a.y, b.y)
	var y1 := maxi(a.y, b.y)
	for x in range(x0, x1 + 1):
		cells.append(Vector2i(x, y0))
		if y1 != y0:
			cells.append(Vector2i(x, y1))
	for y in range(y0 + 1, y1):
		cells.append(Vector2i(x0, y))
		if x1 != x0:
			cells.append(Vector2i(x1, y))
	return cells

## Заливка: заменяет связную область с той же «сигнатурой», что и стартовая клетка.
## Волна идёт по плоским индексам с байтовой отметкой «был» (batch 13 #6): прежняя
## версия строила строку-сигнатуру и словарь Vector2i на КАЖДУЮ клетку, и заливка
## пустого поля 200×200 подвисала на секунды.
func _flood_fill(start: Vector2i) -> void:
	if not map.in_bounds(start):
		return
	var w := map.width
	var h := map.height
	var si := start.y * w + start.x
	var t_floor: int = map.floor_type[si]
	var t_cover: float = map.cover_height[si]
	var t_space: int = map.is_space[si]
	var t_feat: String = map.feature_id[si]
	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack := PackedInt32Array()
	stack.append(si)
	var painted := 0
	while not stack.is_empty() and painted < 200000:
		var i: int = stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		if seen[i] != 0:
			continue
		seen[i] = 1
		if map.floor_type[i] != t_floor or map.cover_height[i] != t_cover \
				or map.is_space[i] != t_space or map.feature_id[i] != t_feat:
			continue
		var x := i % w
		var y := i / w
		_apply_brush(Vector2i(x, y))
		painted += 1
		if x + 1 < w: stack.append(i + 1)
		if x > 0: stack.append(i - 1)
		if y + 1 < h: stack.append(i + w)
		if y > 0: stack.append(i - w)
	queue_redraw()

# --- Геометрия ---
func _cell_size() -> float:
	return CELL * zoom

func _cell_origin(coord: Vector2i) -> Vector2:
	var cs := _cell_size()
	return ORIGIN + pan + Vector2(coord.x * cs, coord.y * cs)

func _pos_to_cell(pos: Vector2) -> Vector2i:
	var cs := _cell_size()
	var local := pos - ORIGIN - pan
	return Vector2i(floori(local.x / cs), floori(local.y / cs))

# --- Подложка (batch 13 #6) ---
## Цвет клетки в подложке: то же, что раньше рисовалось пятью прямоугольниками —
## основа (космос/стена/пол), оттенок пола, оттенок укрытия, зона — сведено в один пиксель.
func _cell_color(i: int) -> Color:
	var ch: float = map.cover_height[i]
	var col := Color(0.14, 0.15, 0.18)
	if map.is_space[i] != 0:
		col = Color(0.03, 0.02, 0.08)  # космос — почти чёрный с фиолетовым
	elif ch >= MCF.WALL_HEIGHT:
		col = Color(0.35, 0.3, 0.25)
	match map.floor_type[i]:
		MCF.FLOOR_FLAMMABLE:
			col = col.blend(Color(0.4, 0.5, 0.15, 0.25))
		MCF.FLOOR_GRASS:
			col = col.blend(Color(0.32, 0.55, 0.18, 0.35))
	if ch > 0.0 and ch < MCF.WALL_HEIGHT:
		col = col.blend(Color(0.5, 0.45, 0.2, 0.12 + 0.12 * ch))
	var zo: int = map.zone_owner[i]
	if zo != -1:
		var zc: Color = owner_color(zo)
		zc.a = 0.22
		col = col.blend(zc)
	return col

func _rebuild_base() -> void:
	_base_img = Image.create(map.width, map.height, false, Image.FORMAT_RGBA8)
	var w := map.width
	for y in map.height:
		var row := y * w
		for x in w:
			_base_img.set_pixel(x, y, _cell_color(row + x))
	_base_tex = ImageTexture.create_from_image(_base_img)
	_base_stale = false

func _refresh_base_cell(coord: Vector2i) -> void:
	if _base_img == null or not map.in_bounds(coord):
		return
	_base_img.set_pixel(coord.x, coord.y, _cell_color(coord.y * map.width + coord.x))
	_base_stale = true

## Карта заменена целиком (загрузка, размер, очистка): подложка и подписи заново.
func _map_replaced() -> void:
	_rebuild_base()
	if _w_spin != null:
		_w_spin.value = map.width
		_h_spin.value = map.height
	_refresh_status()
	queue_redraw()

# --- Рендер ---
func _draw() -> void:
	if map == null:
		return
	# Редактор рисует БЕЗ собственного преобразования холста — сообщаем это слою замен,
	# иначе он остался бы с панорамой боя, из которого сюда пришли.
	Sprites.set_base_transform(Vector2.ZERO, Vector2.ONE)
	var font := ThemeDB.fallback_font
	var cs := _cell_size()
	var w := map.width
	var h := map.height
	var top_left := ORIGIN + pan

	# 1. Подложка — одна текстура на всю карту.
	if _base_stale:
		_base_tex.update(_base_img)
		_base_stale = false
	draw_texture_rect(_base_tex, Rect2(top_left, Vector2(w, h) * cs), false)

	# 2. Окно видимых клеток: всё, что за экраном, не рисуется вовсе.
	var vp := get_viewport_rect().size
	var x0 := maxi(0, floori((0.0 - top_left.x) / cs))
	var y0 := maxi(0, floori((0.0 - top_left.y) / cs))
	var x1 := mini(w - 1, ceili((vp.x - top_left.x) / cs))
	var y1 := mini(h - 1, ceili((vp.y - top_left.y) / cs))
	if x1 < x0 or y1 < y0:
		_draw_preview(cs)
		return

	# Размер шрифта на плитках привязан к масштабу клетки, а не фиксирован (item 25).
	var tag_fs := clampi(int(round(cs * 0.30)), 5, 22)
	var init_fs := clampi(int(round(cs * 0.36)), 6, 26)
	var draw_tags := cs >= LOD_TAGS
	var draw_floor_sprites := _floor_sprites and cs >= LOD_SPRITES
	var feats: Array[String] = map.feature_id
	var spaces: PackedByteArray = map.is_space
	var covers: PackedFloat32Array = map.cover_height

	# 3. Картинки-замены пола (#55) — только когда клетка достаточно крупная, чтобы их
	# разглядеть; иначе подложки достаточно.
	if draw_floor_sprites:
		for y in range(y0, y1 + 1):
			var row := y * w
			for x in range(x0, x1 + 1):
				var i := row + x
				var floor_name := "floor"
				if spaces[i] != 0:
					floor_name = "floor_space"
				elif covers[i] >= MCF.WALL_HEIGHT:
					floor_name = "floor_wall"
				Sprites.draw_texture_override_rect(self,
						floor_name, Rect2(top_left + Vector2(x, y) * cs, Vector2(cs, cs)))

	# 4. Сетка — линиями по строкам и столбцам окна, одной командой.
	if cs >= LOD_GRID:
		var pts := PackedVector2Array()
		var gx0 := top_left.x + x0 * cs
		var gx1 := top_left.x + (x1 + 1) * cs
		var gy0 := top_left.y + y0 * cs
		var gy1 := top_left.y + (y1 + 1) * cs
		for x in range(x0, x1 + 2):
			var px := top_left.x + x * cs
			pts.append(Vector2(px, gy0))
			pts.append(Vector2(px, gy1))
		for y in range(y0, y1 + 2):
			var py := top_left.y + y * cs
			pts.append(Vector2(gx0, py))
			pts.append(Vector2(gx1, py))
		draw_multiline(pts, Color(0.25, 0.27, 0.32), 1.0)

	# 5. Объекты в окне: подпись/картинка при крупной клетке, метка — при мелкой.
	for y in range(y0, y1 + 1):
		var row := y * w
		for x in range(x0, x1 + 1):
			var fid: String = feats[row + x]
			if fid == "":
				continue
			var o := top_left + Vector2(x, y) * cs
			if draw_tags:
				if not Sprites.draw_texture_override(self, fid, o, cs):
					draw_string(font, o + Vector2(cs * 0.12, cs - cs * 0.18), _feature_tag(fid),
						HORIZONTAL_ALIGNMENT_LEFT, -1, tag_fs, Color(0.8, 0.8, 0.9))
			elif covers[row + x] < MCF.WALL_HEIGHT:
				# Стена и так видна цветом подложки; низкие объекты — светлой точкой.
				draw_rect(Rect2(o + Vector2(cs, cs) * 0.3, Vector2(cs, cs) * 0.4), Color(0.8, 0.8, 0.9, 0.7))

	# 6. Точки спавна — только те, что в окне.
	for s in map.spawns:
		var c: Vector2i = s["coord"]
		if c.x < x0 or c.x > x1 or c.y < y0 or c.y > y1:
			continue
		var o := top_left + Vector2(c.x, c.y) * cs
		var center := o + Vector2(cs, cs) * 0.5
		if draw_tags:
			var spawn_key := Sprites.resolve(s["stats_id"], _spawn_suffix(s["owner"]))
			if spawn_key != "":
				Sprites.draw_texture_override(self, spawn_key, o, cs)
				continue
		draw_circle(center, cs * 0.3, owner_color(s["owner"]))
		if draw_tags:
			draw_string(font, center + Vector2(-init_fs * 0.6, init_fs * 0.35), _initials(s["stats_id"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, init_fs, Color.WHITE)

	# 7. Курсор: рамка кисти под мышью, чтобы было видно, куда и каким размером ляжет.
	if cs >= LOD_GRID and map.in_bounds(_hover) and _drag_start == Vector2i(-1, -1):
		var r0 := -(brush_size - 1) / 2 if tool == Tool.PAINT else 0
		var r1 := brush_size / 2 if tool == Tool.PAINT else 0
		var a := top_left + Vector2(_hover.x + r0, _hover.y + r0) * cs
		var sz := Vector2(r1 - r0 + 1, r1 - r0 + 1) * cs
		draw_rect(Rect2(a, sz), Color(1.0, 1.0, 1.0, 0.65), false, 1.5)
	_draw_preview(cs)

## Превью линии/прямоугольника при перетаскивании.
func _draw_preview(cs: float) -> void:
	if _drag_start == Vector2i(-1, -1) or _drag_cur == Vector2i(-1, -1):
		return
	var preview: Array = []
	if tool == Tool.LINE:
		preview = _line_cells(_drag_start, _drag_cur)
	elif tool == Tool.RECT:
		preview = _rect_cells(_drag_start, _drag_cur)
	for c in preview:
		if map.in_bounds(c):
			draw_rect(Rect2(_cell_origin(c), Vector2(cs, cs)), Color(1.0, 0.9, 0.2, 0.35))

## Суффикс стороны для картинок-замен — тот же, что и в бою (#55).
func _spawn_suffix(owner_id: int) -> String:
	if MCF.is_neutral(owner_id):
		return "_neutral"
	if MCF.is_player(owner_id):
		return "_p%d" % (owner_id + 1)
	return ""

func _feature_tag(fid: String) -> String:
	return {
		MCF.FEATURE_WALL: "##", MCF.FEATURE_GLASS: "▢", MCF.FEATURE_SANDBAGS: "SB",
		MCF.FEATURE_HEDGEHOG: "hdg", MCF.FEATURE_TRENCH: "tr", MCF.FEATURE_LDF: "LDF",
		MCF.FEATURE_AIRLOCK: "AL", MCF.FEATURE_DRONE_STATION: "ST",
		MCF.FEATURE_WOOD_WALL: "WD",
		MCF.FEATURE_DOT: "PBX", MCF.FEATURE_DOT_OPEN: "PBX+",
		MCF.FEATURE_ARMOR_WALL: "A##", MCF.FEATURE_ARMOR_GLASS: "A▢",
	}.get(fid, "?")

func _initials(sid: String) -> String:
	return sid.substr(0, 2).to_upper()

# --- UI ---
## Панель, прижатая к краю экрана (item 11): редактор больше не одна широкая колонка
## справа, а два узких столбца по бокам, между которыми видно карту.
## Строка кнопок во всю ширину колонки. Заводится помощником, потому что рядов много,
## и стоит одному из них забыть про растяжение — колонка сразу выглядит кривой.
func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row

## Заголовок раздела (batch 13 #14): тёмно-зелёная шапка в стиле окон меню — колонка
## читается как список окон, а не как россыпь кнопок.
func _section(parent: VBoxContainer, title: String) -> VBoxContainer:
	parent.add_child(SteamChrome.header_bar(title))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(SteamChrome.pad(box, 6, 6))
	return box

func _hint(parent: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 10)
	l.modulate = Color(0.72, 0.76, 0.85)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)

func _edge_panel(to_left: bool) -> VBoxContainer:
	# Панель во ВСЮ высоту экрана, прижата к своему краю (item 19: без якоря на низ
	# ScrollContainer схлопывался в ноль и панели пропадали). Задаём все четыре
	# смещения от краёв viewport вручную — это надёжнее пресетов на CanvasLayer.
	var panel := PanelContainer.new()
	SteamChrome.apply_panel(panel)
	var w := PANEL_WIDTH
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_top = 12.0
	panel.offset_bottom = -12.0
	if to_left:
		panel.anchor_left = 0.0
		panel.anchor_right = 0.0
		panel.offset_left = 12.0
		panel.offset_right = 12.0 + w
	else:
		panel.anchor_left = 1.0
		panel.anchor_right = 1.0
		panel.offset_left = -12.0 - w
		panel.offset_right = -12.0
	_ui.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Тело уже панели на padding с обеих сторон — иначе кнопки упираются в рамку, и
	# колонка выглядит съехавшей.
	vbox.custom_minimum_size = Vector2(w - PANEL_PADDING * 2.0, 0)
	scroll.add_child(vbox)
	return vbox

func _brush_button(id: String, label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.toggle_mode = true
	btn.button_group = _brush_group
	btn.pressed.connect(_select_brush.bind(id, label))
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Длинная подпись ПЕРЕНОСИТСЯ, а не раздвигает колонку.
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.custom_minimum_size = Vector2(0, 30)
	_brush_buttons[id] = btn
	return btn

func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)

	# ЛЕВАЯ колонка — рисование: инструменты и кисти рельефа/объектов (item 11).
	# Порядок сверху вниз повторяет порядок работы (batch 13 #14): чем рисуем →
	# как рисуем → что рисуем. Активные кнопки подсвечены — раньше выбранный
	# инструмент и кисть были видны только строчкой текста.
	var vbox := _edge_panel(true)
	_title = Label.new()
	_title.text = "Map Editor"
	_title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(_title)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)

	var tools := _section(vbox, "Tool")
	var tool_row := _row()
	tools.add_child(tool_row)
	for pair in [[Tool.PAINT, "Paint"], [Tool.LINE, "Line"], [Tool.RECT, "Rect"], [Tool.FILL, "Fill"]]:
		var tb := Button.new()
		tb.text = pair[1]
		tb.toggle_mode = true
		tb.button_group = _tool_group
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.pressed.connect(_select_tool.bind(pair[0]))
		tool_row.add_child(tb)
		_tool_buttons[pair[0]] = tb
	_hint(tools, "Keys 1–4. Paint drags; Line and Rect drag from corner to corner; Fill floods same cells.")
	var undo_row := _row()
	tools.add_child(undo_row)
	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.tooltip_text = "Ctrl+Z"
	_undo_btn.disabled = true
	_undo_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_undo_btn.pressed.connect(_undo)
	undo_row.add_child(_undo_btn)
	_redo_btn = Button.new()
	_redo_btn.text = "Redo"
	_redo_btn.tooltip_text = "Ctrl+Y"
	_redo_btn.disabled = true
	_redo_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_redo_btn.pressed.connect(_redo)
	undo_row.add_child(_redo_btn)
	var size_row := _row()
	tools.add_child(size_row)
	_size_label = Label.new()
	_size_label.text = "Brush size 1"
	_size_label.add_theme_font_size_override("font_size", 11)
	_size_label.custom_minimum_size = Vector2(84, 0)
	size_row.add_child(_size_label)
	var size_slider := HSlider.new()
	size_slider.min_value = 1
	size_slider.max_value = 9
	size_slider.step = 1
	size_slider.value = brush_size
	size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_slider.value_changed.connect(func(v: float) -> void:
		brush_size = int(v)
		_size_label.text = "Brush size %d" % brush_size
		queue_redraw())
	size_row.add_child(size_slider)

	var terrain := _section(vbox, "Floor & Eraser")
	_hint(terrain, "What the cell is: solid floor, grass (burns easily) or open space.")
	var tgrid := GridContainer.new()
	tgrid.columns = 3
	tgrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	terrain.add_child(tgrid)
	for b in TERRAIN_BRUSHES:
		tgrid.add_child(_brush_button(b["id"], b["label"]))
	var eraser := _brush_button("erase", "Eraser — back to empty space")
	eraser.tooltip_text = "Removes floor, object, zone and any unit on the cell"
	terrain.add_child(eraser)

	var objects := _section(vbox, "Objects")
	_hint(objects, "What stands on the floor. Painting an object also lays floor under it.")
	var ogrid := GridContainer.new()
	ogrid.columns = 2
	ogrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	objects.add_child(ogrid)
	for b in OBJECT_BRUSHES:
		ogrid.add_child(_brush_button(b["id"], b["label"]))
	var clear_obj := _brush_button("clear_object", "Remove Object (keep floor)")
	objects.add_child(clear_obj)

	# ПРАВАЯ колонка — обустройство и файлы: зоны, нейтралы, размер, сохранение (item 11).
	# Выходы — СВЕРХУ (batch 13 #14): «Play» и «Main Menu» искали дольше всего.
	var rbox := _edge_panel(false)
	var exits := _section(rbox, "Play & Leave")
	var exit_row := _row()
	exits.add_child(exit_row)
	var play_btn := Button.new()
	play_btn.text = "Play This Map"
	play_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	play_btn.pressed.connect(_on_play)
	exit_row.add_child(play_btn)
	var menu_btn := Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_btn.pressed.connect(_on_main_menu)
	exit_row.add_child(menu_btn)

	# Зоны развёртывания (item 7): это НУМЕРОВАННЫЕ зоны, а не «зона игрока A/B». Зона N
	# достаётся N-му игроку по порядку слотов в лобби — какие именно буквы сядут в бой,
	# карта не знает. Внутри зона по-прежнему хранится индексом (Zone 1 → индекс 0).
	var zones := _section(rbox, "Deployment Zones")
	_hint(zones, "Numbered zones; the lobby gives each one to a player. Pick a zone, then paint it like terrain.")
	var zone_row := _row()
	zones.add_child(zone_row)
	_zone_player_opt = OptionButton.new()
	for i in MCF.MAX_PLAYERS:
		_zone_player_opt.add_item("Zone %d" % (i + 1), i)
	_zone_player_opt.select(0)
	_zone_player_opt.item_selected.connect(_on_zone_player_selected)
	_zone_player_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zone_row.add_child(_zone_player_opt)
	var zb := Button.new()
	zb.text = "Paint Zone"
	zb.toggle_mode = true
	zb.button_group = _brush_group
	zb.pressed.connect(_set_zone_brush.bind(ZONE_SELECTED_PLAYER, "Paint Zone"))
	zone_row.add_child(zb)
	_brush_buttons["zone"] = zb
	var nz := Button.new()
	nz.text = "Remove Zone"
	nz.toggle_mode = true
	nz.button_group = _brush_group
	nz.pressed.connect(_set_zone_brush.bind(-1, "Remove Zone"))
	zones.add_child(nz)
	_brush_buttons["zone_clear"] = nz

	# Нейтральные юниты (item 5): выбрать тип и ставить его на карту как нейтрала. Юнит
	# уходит в map.spawns с owner == NEUTRAL и на старте боя попадает под нейтральный ИИ.
	var neutrals := _section(rbox, "Neutral Units")
	_hint(neutrals, "Neutrals that start on the map. Pick a type, then paint; the eraser removes them.")
	var nu_row := _row()
	neutrals.add_child(nu_row)
	_neutral_unit_opt = OptionButton.new()
	for i in NEUTRAL_UNIT_IDS.size():
		_neutral_unit_opt.add_item(str(NEUTRAL_UNIT_IDS[i]).capitalize(), i)
	_neutral_unit_opt.select(0)
	_neutral_unit_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nu_row.add_child(_neutral_unit_opt)
	var place_btn := _brush_button("spawn_neutral", "Place Neutral")
	place_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nu_row.add_child(place_btn)

	# Размер карты (можно делать большие поля). Содержимое СОХРАНЯЕТСЯ (batch 13 #14).
	var size := _section(rbox, "Map Size")
	_hint(size, "Resizing keeps what you drew; new cells are space.")
	var size_grid := GridContainer.new()
	size_grid.columns = 2
	size_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size.add_child(size_grid)
	var w_lbl := Label.new()
	w_lbl.text = "Width"
	size_grid.add_child(w_lbl)
	_w_spin = SpinBox.new()
	_w_spin.min_value = 1
	_w_spin.max_value = 300
	_w_spin.value = map.width
	_w_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_grid.add_child(_w_spin)
	var h_lbl := Label.new()
	h_lbl.text = "Height"
	size_grid.add_child(h_lbl)
	_h_spin = SpinBox.new()
	_h_spin.min_value = 1
	_h_spin.max_value = 300
	_h_spin.value = map.height
	_h_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_grid.add_child(_h_spin)
	var size_btns := _row()
	size.add_child(size_btns)
	var resize_btn := Button.new()
	resize_btn.text = "Apply Size"
	resize_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resize_btn.pressed.connect(_on_resize)
	size_btns.add_child(resize_btn)
	var fit_btn := Button.new()
	fit_btn.text = "Fit View"
	fit_btn.tooltip_text = "Zoom out so the whole map is on screen"
	fit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fit_btn.pressed.connect(_fit_view)
	size_btns.add_child(fit_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear Map…"
	clear_btn.pressed.connect(_on_clear)
	size.add_child(clear_btn)

	# Сохранение/загрузка.
	var files := _section(rbox, "Save & Load")
	var name_row := _row()
	files.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "Name"
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_row.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "map name"
	_name_edit.text = "map1"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_edit)
	var save_btn := Button.new()
	save_btn.text = "Save Map"
	save_btn.pressed.connect(_on_save)
	files.add_child(save_btn)
	save_btn.tooltip_text = "Saved maps appear in the lobby's map list"
	var load_row := _row()
	files.add_child(load_row)
	_maps_option = OptionButton.new()
	_maps_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_row.add_child(_maps_option)
	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.pressed.connect(_on_load)
	load_row.add_child(load_btn)

func _select_tool(t: int) -> void:
	tool = t
	_drag_start = Vector2i(-1, -1)
	_drag_cur = Vector2i(-1, -1)
	if _tool_buttons.has(t):
		(_tool_buttons[t] as Button).button_pressed = true
	_refresh_status()
	queue_redraw()

func _select_brush(id: String, label: String) -> void:
	brush = id
	_brush_label = label
	if _brush_buttons.has(id):
		(_brush_buttons[id] as Button).button_pressed = true
	_refresh_status()
	queue_redraw()

## ZONE_SELECTED_PLAYER означает «того игрока, что выбран в списке» — иначе кисть
## пришлось бы переназначать после каждой смены стороны в выпадающем списке.
func _set_zone_brush(owner: int, label: String) -> void:
	brush = "zone"
	zone_brush_owner = _selected_zone_player() if owner == ZONE_SELECTED_PLAYER else owner
	_brush_label = ("Zone %d" % (zone_brush_owner + 1)) if owner == ZONE_SELECTED_PLAYER else label
	var key := "zone" if owner == ZONE_SELECTED_PLAYER else "zone_clear"
	if _brush_buttons.has(key):
		(_brush_buttons[key] as Button).button_pressed = true
	_refresh_status()

func _selected_zone_player() -> int:
	if _zone_player_opt == null:
		return MCF.Owner.PLAYER_1
	return _zone_player_opt.get_selected_id()

## Смена стороны в списке сразу переводит на неё активную кисть зоны — иначе
## выбор в списке ничего бы не делал до следующего нажатия кнопки.
func _on_zone_player_selected(_index: int) -> void:
	if brush == "zone" and MCF.is_player(zone_brush_owner):
		_set_zone_brush(ZONE_SELECTED_PLAYER, "")

## Одна строка состояния (batch 13 #14): кисть, инструмент, размер карты и клетка под
## курсором — всё, что раньше приходилось собирать из трёх подписей.
func _refresh_status() -> void:
	if _status == null:
		return
	var where := ""
	if map != null and map.in_bounds(_hover):
		where = "   cell %d, %d" % [_hover.x, _hover.y]
	_status.text = "%s · %s   |   %d×%d%s" % [
		_brush_label, TOOL_NAMES.get(tool, "?"), map.width, map.height, where]
	if _title != null:
		_title.text = "Map Editor" + (" *" if _dirty else "")

func _mark_dirty() -> void:
	if not _dirty:
		_dirty = true
		_refresh_status()

# --- Откат / повтор (batch 14) ---
func _push_undo() -> void:
	_undo_stack.append(map.to_dict())
	while _undo_stack.size() > UNDO_DEPTH:
		_undo_stack.pop_front()
	_redo_stack.clear()
	_refresh_undo_buttons()

func _undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append(map.to_dict())
	map = MapData.from_dict(_undo_stack.pop_back())
	_mark_dirty()
	_map_replaced()
	_refresh_undo_buttons()
	_status.text = "Undo"

func _redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(map.to_dict())
	map = MapData.from_dict(_redo_stack.pop_back())
	_mark_dirty()
	_map_replaced()
	_refresh_undo_buttons()
	_status.text = "Redo"

func _refresh_undo_buttons() -> void:
	if _undo_btn != null:
		_undo_btn.disabled = _undo_stack.is_empty()
	if _redo_btn != null:
		_redo_btn.disabled = _redo_stack.is_empty()

## Показать всю карту (batch 13 #6/#14): масштаб по меньшей стороне, с полями под панели.
func _fit_view() -> void:
	var vp := get_viewport_rect().size
	var avail := Vector2(maxf(200.0, vp.x - PANEL_WIDTH * 2.0 - 60.0), maxf(200.0, vp.y - 40.0))
	zoom = clampf(minf(avail.x / (map.width * CELL), avail.y / (map.height * CELL)), ZOOM_MIN, ZOOM_MAX)
	var cs := _cell_size()
	pan = Vector2((vp.x - map.width * cs) * 0.5, (vp.y - map.height * cs) * 0.5) - ORIGIN
	queue_redraw()

## Подтверждение для необратимых действий (batch 13 #14) — рамка в общем стиле.
func _confirm(title: String, message: String, ok_text: String, on_ok: Callable) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 90
	_ui.add_child(layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := PanelContainer.new()
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar(title))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	frame.add_child(SteamChrome.pad(body, 16, 12))
	var msg := Label.new()
	msg.text = message
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size = Vector2(320, 0)
	body.add_child(msg)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: layer.queue_free())
	row.add_child(cancel)
	var ok := Button.new()
	ok.text = ok_text
	ok.pressed.connect(func() -> void:
		layer.queue_free()
		on_ok.call())
	row.add_child(ok)
	Ui.theme_canvas_layers()

func _on_save() -> void:
	var fname := _name_edit.text.strip_edges()
	if fname == "":
		_status.text = "Enter a map name first."
		return
	if not fname.ends_with(".json"):
		fname += ".json"
	if map.save_to("%s/%s" % [MapData.MAPS_DIR, fname]):
		_dirty = false
		_refresh_status()
		_status.text = "Saved: %s" % fname
		_refresh_maps_list()
	else:
		_status.text = "Save error"

func _on_clear() -> void:
	_confirm("Clear Map", "Erase everything on this map? It becomes empty space again.", "Clear",
		func() -> void:
			_push_undo()
			map.resize(map.width, map.height)
			map.fill_all_space()
			_mark_dirty()
			_map_replaced()
			_status.text = "Map cleared (all space)")

func _on_resize() -> void:
	var w := int(_w_spin.value)
	var h := int(_h_spin.value)
	if w == map.width and h == map.height:
		return
	_push_undo()
	map.resize_keep(w, h)
	_mark_dirty()
	_map_replaced()
	_status.text = "Size: %dx%d" % [w, h]

func _refresh_maps_list() -> void:
	_maps_option.clear()
	for name in MapData.list_maps():
		_maps_option.add_item(name)

func _on_load() -> void:
	if _maps_option.item_count == 0:
		_status.text = "No saved maps"
		return
	var fname := _maps_option.get_item_text(_maps_option.selected)
	var do_load := func() -> void:
		var loaded := MapData.load_from(MapData.path_for(fname))
		if loaded == null:
			_status.text = "Load error"
			return
		_push_undo()
		map = loaded
		_dirty = false
		_name_edit.text = fname.get_basename()
		_map_replaced()
		_fit_view()
		_status.text = "Loaded: %s" % fname
	if _dirty:
		_confirm("Load Map", "You have unsaved changes. Load “%s” and lose them?" % fname, "Load", do_load)
	else:
		do_load.call()

func _on_play() -> void:
	# Передаём карту в Main через autoload-подобный статический слот.
	MapHandoff.pending = map
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

## Выход из редактора — в ГЛАВНОЕ МЕНЮ (#104). Карту из слота передачи снимаем: она
## предназначалась кнопке «Play», и оставить её висеть значило бы подсунуть нарисованную
## карту следующей партии, которую игрок заведёт из меню совсем с другими намерениями.
func _on_main_menu() -> void:
	var leave := func() -> void:
		MapHandoff.pending = null
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
	if _dirty:
		_confirm("Leave Editor", "You have unsaved changes. Leave without saving?", "Leave", leave)
	else:
		leave.call()
