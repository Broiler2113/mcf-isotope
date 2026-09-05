extends Node2D

## Встроенный редактор карт (M5, §11). Рисуем рельеф, укрытия, космос и точки
## спавна кистями, сохраняем/загружаем JSON (user://maps). Работает с данными
## MapData; симуляция строится из карты через MapData.build_state().
## Запускается напрямую как сцена; «Play» открывает Main с выбранной картой.

const CELL := 40
const ORIGIN := Vector2(40, 40)

const OWNER_COLORS := {
	MCF.Owner.PLAYER_1: Color(0.3, 0.55, 1.0),
	MCF.Owner.PLAYER_2: Color(1.0, 0.4, 0.35),
	MCF.Owner.NEUTRAL: Color(0.7, 0.7, 0.7),
}

# Кисти рельефа/объектов. Спавн-кисти обрабатываются отдельно (owner + unit).
const TERRAIN_BRUSHES := [
	{"id": "erase", "label": "Erase"},
	{"id": "space", "label": "Space"},
	{"id": "floor", "label": "Floor"},
	{"id": MCF.FEATURE_WALL, "label": "Wall"},
	{"id": MCF.FEATURE_WOOD_WALL, "label": "Wooden Wall"},
	{"id": MCF.FEATURE_GLASS, "label": "Glass"},
	{"id": MCF.FEATURE_SANDBAGS, "label": "Sandbags"},
	{"id": MCF.FEATURE_HEDGEHOG, "label": "Hedgehog"},
	{"id": MCF.FEATURE_TRENCH, "label": "Trench"},
	{"id": MCF.FEATURE_BRU, "label": "BRU"},
	{"id": MCF.FEATURE_AIRLOCK, "label": "Airlock"},
	{"id": MCF.FEATURE_DOT, "label": "Pillbox"},
	{"id": MCF.FEATURE_DOT_OPEN, "label": "Pillbox (Embrasures)"},
]

## Инструменты рисования (как в редакторе Crazy Ball Runner): кисть, линия,
## прямоугольник, заливка.
enum Tool { PAINT, LINE, RECT, FILL }

var map: MapData
var brush: String = MCF.FEATURE_WALL
## Владелец кисти зоны развёртывания (#52); -1 = стирать зону.
var zone_brush_owner: int = MCF.Owner.PLAYER_1

var tool: int = Tool.PAINT
## Начало/текущая клетка перетаскивания для линии/прямоугольника (-1 = нет).
var _drag_start: Vector2i = Vector2i(-1, -1)
var _drag_cur: Vector2i = Vector2i(-1, -1)

## Смещение «камеры» (панорама) и коэффициент масштаба.
var pan: Vector2 = Vector2.ZERO
var zoom: float = 1.0
const PAN_SPEED := 700.0        # px/сек для WASD
const ZOOM_MIN := 0.35
const ZOOM_MAX := 2.5
var _mouse_panning: bool = false

var _ui: CanvasLayer
var _name_edit: LineEdit
var _status: Label
var _maps_option: OptionButton
var _w_spin: SpinBox
var _h_spin: SpinBox
var _tool_status: Label

func _ready() -> void:
	Sprites.reload_overrides()  # подменённые картинки видны и в редакторе (#55)
	map = MapData.new(16, 12)
	map.fill_all_space()  # пустая карта — сплошной космос, пол рисует игрок
	_build_ui()
	Ui.theme_canvas_layers()  # editor toolbar is on a CanvasLayer; apply Steam skin.
	_refresh_maps_list()
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

	# Рисование инструментами.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var coord := _pos_to_cell(get_global_mouse_position())
		if event.pressed:
			match tool:
				Tool.PAINT:
					_paint(coord)
				Tool.FILL:
					_flood_fill(coord)
				Tool.LINE, Tool.RECT:
					_drag_start = coord
					_drag_cur = coord
					queue_redraw()
		else:
			# Отпустили — фиксируем линию/прямоугольник.
			if tool in [Tool.LINE, Tool.RECT] and _drag_start != Vector2i(-1, -1):
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

func _paint(coord: Vector2i) -> void:
	_apply_brush(coord)
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
			map.set_cell(coord, map.get_floor(coord), map.get_cover(coord), not map.get_space(coord), map.get_feature(coord))
		"floor":
			# Обычный твёрдый пол (снимает космос).
			map.set_cell(coord, MCF.FLOOR_NORMAL, map.get_cover(coord), false, map.get_feature(coord))
		"zone":
			# Кисть зоны развёртывания (#52): красим владельца региона, не трогая рельеф.
			map.set_zone(coord, zone_brush_owner)
		_:
			# Кисть-объект: под укрытием подразумевается пол, поэтому снимаем космос.
			var h: float = MCF.FEATURE_HEIGHT.get(brush, 0.0)
			map.set_cell(coord, map.get_floor(coord), h, false, brush)

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
func _flood_fill(start: Vector2i) -> void:
	if not map.in_bounds(start):
		return
	var target := _cell_signature(start)
	var seen := {}
	var stack: Array = [start]
	var painted := 0
	while not stack.is_empty() and painted < 40000:
		var c: Vector2i = stack.pop_back()
		if seen.has(c) or not map.in_bounds(c):
			continue
		seen[c] = true
		if _cell_signature(c) != target:
			continue
		_apply_brush(c)
		painted += 1
		stack.append(c + Vector2i(1, 0))
		stack.append(c + Vector2i(-1, 0))
		stack.append(c + Vector2i(0, 1))
		stack.append(c + Vector2i(0, -1))
	queue_redraw()

## Сигнатура клетки для заливки: пол + укрытие + космос + объект.
func _cell_signature(coord: Vector2i) -> String:
	return "%d|%.2f|%s|%s" % [
		map.get_floor(coord), map.get_cover(coord),
		str(map.get_space(coord)), map.get_feature(coord)]

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

# --- Рендер ---
func _draw() -> void:
	if map == null:
		return
	var font := ThemeDB.fallback_font
	var cs := _cell_size()
	for y in map.height:
		for x in map.width:
			var coord := Vector2i(x, y)
			var rect := Rect2(_cell_origin(coord), Vector2(cs, cs))
			var ch := map.get_cover(coord)
			# В редакторе те же картинки-замены, что и в бою (#55) — карта строится
			# в том виде, в каком её потом увидят игроки.
			var floor_name := "floor"
			if map.get_space(coord):
				floor_name = "floor_space"
			elif ch >= MCF.WALL_HEIGHT:
				floor_name = "floor_wall"
			if not Sprites.draw_texture_override_rect(self, floor_name, rect):
				var base := Color(0.14, 0.15, 0.18)
				if map.get_space(coord):
					base = Color(0.03, 0.02, 0.08)  # космос — почти чёрный с фиолетовым
				if ch >= MCF.WALL_HEIGHT:
					base = Color(0.35, 0.3, 0.25)
				draw_rect(rect, base)
			if map.get_floor(coord) == MCF.FLOOR_FLAMMABLE:
				draw_rect(rect, Color(0.4, 0.5, 0.15, 0.25))
			if ch > 0.0 and ch < MCF.WALL_HEIGHT:
				draw_rect(rect, Color(0.5, 0.45, 0.2, 0.12 + 0.12 * ch))
			# Зона развёртывания (#52): полупрозрачная заливка цветом стороны.
			var zo := map.get_zone(coord)
			if zo != -1:
				var zc: Color = OWNER_COLORS.get(zo, Color.WHITE)
				zc.a = 0.22
				draw_rect(rect, zc)
			draw_rect(rect, Color(0.25, 0.27, 0.32), false, 1.0)
			var fid := map.get_feature(coord)
			if fid != "":
				var o := _cell_origin(coord)
				if not Sprites.draw_texture_override(self, fid, o, cs):
					draw_string(font, o + Vector2(4, cs - 6), _feature_tag(fid),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.8, 0.9))
	# Точки спавна.
	for s in map.spawns:
		var center := _cell_origin(s["coord"]) + Vector2(cs, cs) * 0.5
		var spawn_key := Sprites.resolve(s["stats_id"], _spawn_suffix(s["owner"]))
		if spawn_key != "":
			Sprites.draw_texture_override(self, spawn_key, _cell_origin(s["coord"]), cs)
			continue
		draw_circle(center, cs * 0.3, OWNER_COLORS.get(s["owner"], Color.WHITE))
		draw_string(font, center + Vector2(-9, 5), _initials(s["stats_id"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	# Превью линии/прямоугольника при перетаскивании.
	if _drag_start != Vector2i(-1, -1) and _drag_cur != Vector2i(-1, -1):
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
	match owner_id:
		MCF.Owner.PLAYER_1: return "_p1"
		MCF.Owner.PLAYER_2: return "_p2"
		MCF.Owner.NEUTRAL: return "_neutral"
	return ""

func _feature_tag(fid: String) -> String:
	return {
		MCF.FEATURE_WALL: "##", MCF.FEATURE_GLASS: "▢", MCF.FEATURE_SANDBAGS: "SB",
		MCF.FEATURE_HEDGEHOG: "hdg", MCF.FEATURE_TRENCH: "tr", MCF.FEATURE_BRU: "BRU",
		MCF.FEATURE_AIRLOCK: "AL", MCF.FEATURE_DRONE_STATION: "ST",
		MCF.FEATURE_WOOD_WALL: "WD",
		MCF.FEATURE_DOT: "PBX", MCF.FEATURE_DOT_OPEN: "PBX+",
	}.get(fid, "?")

func _initials(sid: String) -> String:
	return sid.substr(0, 2).to_upper()

# --- UI ---
func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)

	var panel := PanelContainer.new()
	panel.position = Vector2(700, 20)
	panel.custom_minimum_size = Vector2(540, 680)
	_ui.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Map Editor"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	_status.text = "Brush: Wall"
	vbox.add_child(_status)

	# Инструменты: кисть / линия / прямоугольник / заливка.
	_tool_status = Label.new()
	_tool_status.add_theme_font_size_override("font_size", 13)
	_tool_status.text = "Tool: Paint"
	vbox.add_child(_tool_status)
	var tool_row := HBoxContainer.new()
	vbox.add_child(tool_row)
	for pair in [[Tool.PAINT, "Paint"], [Tool.LINE, "Line"], [Tool.RECT, "Rect"], [Tool.FILL, "Fill"]]:
		var tb := Button.new()
		tb.text = pair[1]
		tb.pressed.connect(_set_tool.bind(pair[0], pair[1]))
		tool_row.add_child(tb)

	# Кисти рельефа/объектов — в сетке кнопок.
	var grid := GridContainer.new()
	grid.columns = 3
	vbox.add_child(grid)
	for b in TERRAIN_BRUSHES:
		var btn := Button.new()
		btn.text = b["label"]
		btn.pressed.connect(_set_brush.bind(b["id"], b["label"]))
		grid.add_child(btn)

	vbox.add_child(HSeparator.new())

	# Зоны развёртывания (§3.3, #52): рисуем регионы, где каждая сторона расставляет
	# отряд в пре-игре. Заменяет попиксельную расстановку конкретных юнитов.
	var zone_lbl := Label.new()
	zone_lbl.text = "Deployment Zones:"
	zone_lbl.add_theme_font_size_override("font_size", 13)
	vbox.add_child(zone_lbl)
	var zone_row := HBoxContainer.new()
	vbox.add_child(zone_row)
	for pair in [[MCF.Owner.PLAYER_1, "Zone P1"], [MCF.Owner.PLAYER_2, "Zone P2"],
			[MCF.Owner.NEUTRAL, "Zone Neut."], [-1, "No Zone"]]:
		var zb := Button.new()
		zb.text = pair[1]
		zb.pressed.connect(_set_zone_brush.bind(pair[0], pair[1]))
		zone_row.add_child(zb)

	vbox.add_child(HSeparator.new())

	# Размер карты (можно делать большие поля).
	var size_row := HBoxContainer.new()
	vbox.add_child(size_row)
	var w_lbl := Label.new()
	w_lbl.text = "W:"
	size_row.add_child(w_lbl)
	_w_spin = SpinBox.new()
	_w_spin.min_value = 1
	_w_spin.max_value = 200
	_w_spin.value = map.width
	size_row.add_child(_w_spin)
	var h_lbl := Label.new()
	h_lbl.text = "H:"
	size_row.add_child(h_lbl)
	_h_spin = SpinBox.new()
	_h_spin.min_value = 1
	_h_spin.max_value = 200
	_h_spin.value = map.height
	size_row.add_child(_h_spin)
	var resize_btn := Button.new()
	resize_btn.text = "Set Size"
	resize_btn.pressed.connect(_on_resize)
	size_row.add_child(resize_btn)

	vbox.add_child(HSeparator.new())

	# Сохранение/загрузка.
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "map name"
	_name_edit.text = "map1"
	vbox.add_child(_name_edit)

	var io_row := HBoxContainer.new()
	vbox.add_child(io_row)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_save)
	io_row.add_child(save_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.pressed.connect(_on_clear)
	io_row.add_child(clear_btn)

	_maps_option = OptionButton.new()
	vbox.add_child(_maps_option)
	var load_row := HBoxContainer.new()
	vbox.add_child(load_row)
	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.pressed.connect(_on_load)
	load_row.add_child(load_btn)
	var play_btn := Button.new()
	play_btn.text = "Play"
	play_btn.pressed.connect(_on_play)
	load_row.add_child(play_btn)

	vbox.add_child(HSeparator.new())
	var menu_btn := Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.pressed.connect(_on_main_menu)
	vbox.add_child(menu_btn)

func _set_tool(t: int, label: String) -> void:
	tool = t
	_drag_start = Vector2i(-1, -1)
	_drag_cur = Vector2i(-1, -1)
	_tool_status.text = "Tool: %s" % label
	queue_redraw()

func _set_brush(id: String, label: String) -> void:
	brush = id
	_status.text = "Brush: %s" % label

func _set_zone_brush(owner: int, label: String) -> void:
	brush = "zone"
	zone_brush_owner = owner
	_status.text = "Brush: %s" % label

func _on_save() -> void:
	var fname := _name_edit.text.strip_edges()
	if fname == "":
		_status.text = "Enter a map name"
		return
	if not fname.ends_with(".json"):
		fname += ".json"
	if map.save_to("%s/%s" % [MapData.MAPS_DIR, fname]):
		_status.text = "Saved: %s" % fname
		_refresh_maps_list()
	else:
		_status.text = "Save error"

func _on_clear() -> void:
	map.resize(map.width, map.height)
	map.fill_all_space()
	_status.text = "Map cleared (all space)"
	queue_redraw()

func _on_resize() -> void:
	var w := int(_w_spin.value)
	var h := int(_h_spin.value)
	map.resize(w, h)
	map.fill_all_space()
	_status.text = "Size: %dx%d (map cleared)" % [w, h]
	queue_redraw()

func _refresh_maps_list() -> void:
	_maps_option.clear()
	for name in MapData.list_maps():
		_maps_option.add_item(name)

func _on_load() -> void:
	if _maps_option.item_count == 0:
		_status.text = "No saved maps"
		return
	var fname := _maps_option.get_item_text(_maps_option.selected)
	var loaded := MapData.load_from(MapData.path_for(fname))
	if loaded == null:
		_status.text = "Load error"
		return
	map = loaded
	_status.text = "Loaded: %s" % fname
	queue_redraw()

func _on_play() -> void:
	# Передаём карту в Main через autoload-подобный статический слот.
	MapHandoff.pending = map
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

## Выход из редактора — в ГЛАВНОЕ МЕНЮ (#104). Раньше эта кнопка называлась «To Demo
## Game» и бросала прямо в бой на встроенном ростере: единственная дверь из редактора
## вела не туда, откуда в него вошли, и чтобы просто вернуться к настройке партии,
## приходилось сперва запустить ненужную демо-игру и выйти уже из неё.
##
## Карту из слота передачи снимаем: она предназначалась кнопке «Play», и оставить её
## висеть значило бы подсунуть нарисованную карту следующей партии, которую игрок
## заведёт из меню совсем с другими намерениями.
func _on_main_menu() -> void:
	MapHandoff.pending = null
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
