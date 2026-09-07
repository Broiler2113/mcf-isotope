extends Node2D

## Экран свободной расстановки + point-buy (§6, §7). Каждая сторона тратит бюджет
## GameConfig.budget на покупку юнитов и ставит их в своей зоне развёртывания.
## Сначала расставляет Player 1, затем Player 2; по кнопке «Start Battle» собирает
## MapData со спавнами и передаёт бой в Main через MapHandoff.

const MAIN_SCENE := "res://scenes/Main.tscn"
const SETUP_SCENE := "res://scenes/Setup.tscn"
const MENU_SCENE := "res://scenes/MainMenu.tscn"
## Хелпер оформления окон в стиле «2003 Steam» (preload, без class_name).
const SteamChrome = preload("res://src/ui/SteamChrome.gd")
const CELL := 34
const ORIGIN := Vector2(30, 30)
const PAN_SPEED := 700.0
const ZOOM_MIN := 0.5
const ZOOM_MAX := 2.5
const ZOOM_STEP := 1.1

## Покупаемая техника (§техника, #10): танк и челнок.
const PURCHASABLE_VEHICLES := ["tank", "shuttle"]

## Покупаемые юниты (дрона в списке нет — его призывает оператор).
## Купленный мирный житель — обычный дешёвый боец СВОЕЙ стороны (#96): игрок им
## командует, и по своим он не стреляет. Нейтральные жители-НПС берутся только из
## разметки самой карты (preserved_neutral) — вот они и враждебны обоим.
const PURCHASABLE := [
	"light_infantry", "heavy_infantry", "assault", "machinegunner",
	"sniper", "marksman", "anti_tank", "flamethrower",
	"commander", "engineer", "miner", "sapper", "drone_operator", "shield_bearer",
	"civilian",
]

## Перспективные цвета дуэли (#93); цвета конкретных игроков живут в ростере.
const OWN_COLOR := Color(0.3, 0.55, 1.0)
const FOE_COLOR := Color(1.0, 0.4, 0.35)
const NEUTRAL_COLOR := Color(0.7, 0.7, 0.7)

var map: MapData
var budget: int = 300
## Потрачено очков по сторонам: side -> сумма. Заполняется по составу партии.
var spent: Dictionary = {}
var active_side: int = MCF.Owner.PLAYER_1
## Состав партии: кто вообще расставляется и в каком порядке (хот-сит идёт по нему).
var roster: Roster
var brush_unit: String = ""
## Расставленные игроками юниты: [{"stats_id", "owner", "coord"}].
var placed: Array = []
## Нейтральные спавны исходной карты (мирные), которые сохраняем.
var preserved_neutral: Array = []
## Карта сама размечает зоны развёртывания кистью зон (#52) — тогда играем по ним,
## а не по половинкам поля. На «городе» (#57) это и не пускает игроков в дома.
var _map_zones: bool = false
var _stats_cache: Dictionary = {}

var pan: Vector2 = Vector2.ZERO
var zoom: float = 1.0
var _mouse_panning: bool = false
## Рисование расстановки перетаскиванием (#11): держим ЛКМ и ведём мышью.
var _painting: bool = false
var _paint_last: Vector2i = Vector2i(-9999, -9999)

var _ui: CanvasLayer
var _panel: PanelContainer
var _budget_label: Label
var _phase_label: Label
var _status: Label
var _palette: VBoxContainer
var _palette_buttons: Dictionary = {}
var _flow_btn: Button

# --- Сетевая расстановка (#93) ---
## Экран работает и в сетевой партии: каждый игрок набирает ТОЛЬКО свою армию и
## ставит её ТОЛЬКО в своей зоне. По «Ready» стороны обмениваются ростерами и,
## получив оба, строят одинаковый MapData и уходят в бой.
const K_ROSTER := "roster"
var _net: NetworkSession = null
var _net_is_host: bool = false
var _my_side: int = MCF.Owner.PLAYER_1
var _my_ready: bool = false
var _remote_roster: Array = []
var _remote_ready: bool = false
## Общее зерно кубиков, чтобы у обеих сторон совпал локальный бросок инициативы.
var _shared_seed: int = -1

func _ready() -> void:
	budget = GameConfig.budget
	roster = GameConfig.active_roster()
	for side in _sides():
		spent[side] = 0
	active_side = _sides()[0]
	map = _load_or_blank_map()
	_map_zones = _map_defines_zones()
	# Сохранить нейтральные спавны карты (мирные), сбросить игровые.
	if GameConfig.civilians_enabled:
		for s in map.spawns:
			if int(s["owner"]) == MCF.Owner.NEUTRAL:
				preserved_neutral.append(s)
	map.spawns = []
	_adopt_network()
	_build_ui()
	set_process(true)
	_refresh_labels()
	queue_redraw()
	# Подписываемся на входящие только когда UI готов: attach() сразу же отдаёт
	# всё, что накопилось в буфере, а обработчик трогает метки панели.
	if _net != null:
		_net.attach()

func networked() -> bool:
	return _net != null

## Подхватить связь, налаженную во вкладке Multiplayer главного меню.
func _adopt_network() -> void:
	if NetHandoff.session == null:
		return
	_net_is_host = NetHandoff.is_host
	_net = NetHandoff.take()
	_my_side = MCF.Owner.PLAYER_1 if _net_is_host else MCF.Owner.PLAYER_2
	active_side = _my_side
	# Зерно назначает хост — оно едет вместе с его ростером.
	if _net_is_host:
		_shared_seed = randi() & 0x7FFFFFFF
	_net.message.connect(_on_net_message)
	_net.disconnected.connect(_on_net_lost)

func _on_net_lost() -> void:
	if _status != null:
		_status.text = "Connection lost — returning to the menu."
	_drop_session()
	get_tree().change_scene_to_file(MENU_SCENE)

## Закрыть и снять узел сессии: он живёт под /root и сменой сцены сам не убирается.
func _drop_session() -> void:
	if _net == null:
		return
	_net.close()
	_net.queue_free()
	_net = null

func _on_net_message(msg: Dictionary) -> void:
	if str(msg.get("k", "")) != K_ROSTER:
		return
	_remote_roster = msg.get("u", [])
	_remote_ready = true
	if int(msg.get("seed", -1)) >= 0:
		_shared_seed = int(msg["seed"])
	_refresh_labels()
	if _my_ready:
		_start_battle()
	elif _status != null:
		_status.text = "The other player is ready. Deploy your squad and press Ready."

## Ростер в JSON-совместимом виде (Vector2i → пара x/y).
func _encode_roster() -> Array:
	var out: Array = []
	for p in placed:
		var c: Vector2i = p["coord"]
		out.append({"id": p["stats_id"], "o": int(p["owner"]), "x": c.x, "y": c.y})
	return out

func _on_net_ready() -> void:
	if _my_ready:
		return
	if _side_unit_count(_my_side) == 0:
		_status.text = "Deploy at least one unit before you're ready."
		return
	_my_ready = true
	var msg := {"k": K_ROSTER, "u": _encode_roster()}
	if _net_is_host:
		msg["seed"] = _shared_seed
	_net.send(msg)
	_flow_btn.disabled = true
	_status.text = "Waiting for the other player..."
	_refresh_labels()
	if _remote_ready:
		_start_battle()

func _load_or_blank_map() -> MapData:
	# Сетевая партия играется на карте ХОСТА, пришедшей целиком (#99) — у клиента
	# такого файла может и не быть, а поле обязано совпасть до клетки.
	var shared := NetHandoff.take_lobby_map()
	if shared != null:
		return shared
	if GameConfig.map_path != "":
		var m := MapData.load_from(GameConfig.map_path)
		if m != null:
			return m
	# Демо/без карты: пустая твёрдая арена, чтобы было куда ставить.
	return MapData.blank_arena()

# --- Данные юнитов ---
func _stats(id: String) -> UnitStats:
	if _stats_cache.has(id):
		return _stats_cache[id]
	var path := "res://src/data/units/%s.tres" % id
	var s: UnitStats = load(path) if ResourceLoader.exists(path) else null
	_stats_cache[id] = s
	return s

func _cost(id: String) -> int:
	if VehicleDB.is_vehicle(id):
		return VehicleDB.buy_cost(id)
	var s := _stats(id)
	return s.cost if s != null else 0

func _display_name(id: String) -> String:
	if VehicleDB.is_vehicle(id):
		return String(VehicleDB.get_vehicle(id).get("name", id))
	var s := _stats(id)
	return s.display_name if s != null else id

## След предмета расстановки: техника занимает несколько клеток, пехота — одну (#10).
func _footprint(id: String, coord: Vector2i) -> Array:
	var out: Array = []
	var size := VehicleDB.size_of(id) if VehicleDB.is_vehicle(id) else Vector2i.ONE
	for dy in size.y:
		for dx in size.x:
			out.append(coord + Vector2i(dx, dy))
	return out

## Все клетки следа свободны, в границах и внутри зоны развёртывания стороны.
func _footprint_placeable(id: String, coord: Vector2i, side: int) -> bool:
	for c in _footprint(id, coord):
		if not _cell_placeable(c) or not _in_zone(c, side):
			return false
	return true

# --- Зона развёртывания (§ свободная расстановка). ---
## Размечены ли на карте зоны хотя бы одной ИГРОВОЙ стороны. Нейтральная разметка
## сама по себе зоной высадки не считается: жилой квартал — не плацдарм.
func _map_defines_zones() -> bool:
	for z in map.zone_owner:
		if MCF.is_player(z):
			return true
	return false

## Стороны партии в порядке расстановки.
func _sides() -> Array[int]:
	var ids := roster.player_ids()
	return ids if not ids.is_empty() else [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]

## Карта со своей разметкой играется по ней; иначе — старое правило половинок:
## P1 слева, P2 справа. Нейтральные клетки не подходят никому, поэтому мирные
## кварталы остаются недоступны обоим игрокам.
## Карта со своей разметкой играется по ней; иначе поле делится на вертикальные
## полосы по числу сторон. На двоих это ровно прежнее правило половинок (P1 слева,
## P2 справа) — просто записанное так, чтобы работать и на троих, и на шестерых.
func _in_zone(coord: Vector2i, side: int) -> bool:
	if _map_zones:
		return map.get_zone(coord) == side
	var sides := _sides()
	var n := sides.size()
	var slot := sides.find(side)
	if slot < 0:
		return false
	if n == 2:
		var half := map.width / 2
		return coord.x < half if slot == 0 else coord.x >= map.width - half
	var band := maxi(1, map.width / n)
	var lo := slot * band
	var hi := map.width if slot == n - 1 else lo + band
	return coord.x >= lo and coord.x < hi

func _cell_placeable(coord: Vector2i) -> bool:
	if not map.in_bounds(coord):
		return false
	if map.get_space(coord):
		return false
	if map.get_cover(coord) >= MCF.WALL_HEIGHT:
		return false
	# Объект-препятствие (кроме мягких укрытий) не мешает — но занятые клетки нельзя.
	return _placed_at(coord) == -1 and _neutral_at(coord) == -1

func _placed_at(coord: Vector2i) -> int:
	for i in placed.size():
		if _footprint(placed[i]["stats_id"], placed[i]["coord"]).has(coord):
			return i
	return -1

func _neutral_at(coord: Vector2i) -> int:
	for i in preserved_neutral.size():
		if preserved_neutral[i]["coord"] == coord:
			return i
	return -1

# --- Ввод ---
func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): dir.y += 1
	if Input.is_key_pressed(KEY_S): dir.y -= 1
	if Input.is_key_pressed(KEY_A): dir.x += 1
	if Input.is_key_pressed(KEY_D): dir.x -= 1
	if dir != Vector2.ZERO:
		pan += dir.normalized() * PAN_SPEED * delta
		queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	# Ввод над палитрой принадлежит панели — не панорамируем/зумим/ставим под ней.
	if event is InputEventMouseButton and _pointer_over_panel(event.position):
		return
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		_mouse_panning = event.pressed
		return
	if event is InputEventMouseMotion and _mouse_panning:
		pan += event.relative
		queue_redraw()
		return
	# Масштаб как в бою (#9): колесо мыши и щипок тачпада, сохраняя точку под курсором.
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, ZOOM_STEP)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
			return
	if event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		return
	if event is InputEventPanGesture:
		pan -= event.delta * 24.0
		queue_redraw()
		return
	# Расстановка перетаскиванием (#11): зажать ЛКМ и вести мышью — красим клетки.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_painting = true
			_paint_last = _pos_to_cell(get_global_mouse_position())
			_click_cell(_paint_last)
		else:
			_painting = false
		return
	if event is InputEventMouseMotion and _painting:
		var cell := _pos_to_cell(get_global_mouse_position())
		if cell != _paint_last:
			_paint_last = cell
			_paint_at(cell)
		return

## Под курсором ли панель палитры (#9/#11): её ввод не трогает поле/камеру.
func _pointer_over_panel(pos: Vector2) -> bool:
	return _panel != null and _panel.get_global_rect().has_point(pos)

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var new_zoom: float = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_zoom, zoom):
		return
	var local := (screen_pos - pan) / zoom
	zoom = new_zoom
	pan = screen_pos - local * zoom
	queue_redraw()

## Красим клетку при перетаскивании — только СТАВИМ (не возвращаем), чтобы протяжка
## по своим юнитам их не снимала (#11).
func _paint_at(coord: Vector2i) -> void:
	if brush_unit == "" or _placed_at(coord) != -1:
		return
	if not _footprint_placeable(brush_unit, coord, active_side):
		return
	var c := _cost(brush_unit)
	if budget > 0 and spent[active_side] + c > budget:
		return
	placed.append({"stats_id": brush_unit, "owner": active_side,
			"coord": coord, "paid_by": active_side})
	spent[active_side] += c
	_refresh_labels()
	queue_redraw()

func _paid_by(rec: Dictionary) -> int:
	return int(rec.get("paid_by", rec["owner"]))

func _click_cell(coord: Vector2i) -> void:
	# Клик по своему расставленному юниту — снять и вернуть очки.
	var idx := _placed_at(coord)
	if idx != -1:
		if _paid_by(placed[idx]) == active_side:
			spent[active_side] -= _cost(placed[idx]["stats_id"])
			placed.remove_at(idx)
			_refresh_labels()
			queue_redraw()
		else:
			_status.text = "That unit belongs to the other side."
		return
	# Иначе — поставить выбранного юнита/технику.
	if brush_unit == "":
		_status.text = "Pick a unit from the palette first."
		return
	if not _footprint_placeable(brush_unit, coord, active_side):
		_status.text = "Can't deploy there — blocked or outside your zone."
		return
	var c := _cost(brush_unit)
	# Бюджет <= 0 — безлимит (§Setup «0 = unlimited»); иначе соблюдаем заданный предел.
	if budget > 0 and spent[active_side] + c > budget:
		_status.text = "Not enough points (need %d, have %d)." % [c, budget - spent[active_side]]
		return
	placed.append({"stats_id": brush_unit, "owner": active_side,
			"coord": coord, "paid_by": active_side})
	spent[active_side] += c
	_refresh_labels()
	queue_redraw()

# --- Геометрия (локальные координаты; pan/zoom добавляет draw_set_transform) ---
func _cell_origin(coord: Vector2i) -> Vector2:
	return ORIGIN + Vector2(coord.x * CELL, coord.y * CELL)

func _pos_to_cell(pos: Vector2) -> Vector2i:
	var local := (pos - pan) / zoom - ORIGIN
	return Vector2i(floori(local.x / CELL), floori(local.y / CELL))

# --- Рендер ---
func _draw() -> void:
	if map == null:
		return
	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	var font := ThemeDB.fallback_font
	# Поле рисуется ТЕМИ ЖЕ спрайтами и цветами, что и в бою (#100): раньше расстановка
	# показывала лишь серые квадраты, и игрок расставлял отряд вслепую — мешки, окопы,
	# шлюзы и ДОТы проявлялись только после старта. Логика повторяет проход Main._draw().
	for y in map.height:
		for x in map.width:
			var coord := Vector2i(x, y)
			var rect := Rect2(_cell_origin(coord), Vector2(CELL, CELL))
			var fid := map.get_feature(coord)
			# Высота укрытия объекта задаётся справочником, а не слоем cover_height:
			# редактор хранит объект и рельеф раздельно (см. MapData.apply_to_grid).
			var ch := map.get_cover(coord)
			if fid != "" and MCF.FEATURE_HEIGHT.has(fid):
				ch = float(MCF.FEATURE_HEIGHT[fid])
			var is_space := map.get_space(coord)
			var is_wall := ch >= MCF.WALL_HEIGHT
			var floor_name := "floor"
			if is_space:
				floor_name = "floor_space"
			elif is_wall:
				floor_name = "floor_wall"
			if not Sprites.draw_texture_override_rect(self, floor_name, rect):
				var base := Color(0.14, 0.15, 0.18)
				if is_space:
					base = Color(0.03, 0.02, 0.08)
				if is_wall:
					base = Color(0.35, 0.3, 0.25)
				draw_rect(rect, base)
			if ch > 0.0 and not is_wall:
				if not Sprites.draw_texture_override_rect(self, "floor_cover", rect):
					draw_rect(rect, Color(0.5, 0.45, 0.2, 0.12 + 0.12 * ch))
			if fid != "":
				_draw_feature(coord, fid, ch, font)
			# Подсветка зоны развёртывания активной стороны.
			if _in_zone(coord, active_side) and not is_space and not is_wall:
				draw_rect(rect, Color(_side_color(active_side), 0.10))
			draw_rect(rect, Color(0.25, 0.27, 0.32), false, 1.0)
	# Сохранённые мирные.
	for s in preserved_neutral:
		_draw_token(s["coord"], MCF.Owner.NEUTRAL, s["stats_id"], font)
	# Расставленные юниты.
	for p in placed:
		_draw_token(p["coord"], int(p["owner"]), p["stats_id"], font)

## Ярлыки объектов — те же, что в бою (Main._draw): игрок должен видеть одну и ту же
## карту до и после старта, иначе расстановка превращается в угадайку.
const FEATURE_TAGS := {
	MCF.FEATURE_DRONE_STATION: "ST", MCF.FEATURE_SANDBAGS: "SB",
	MCF.FEATURE_HEDGEHOG: "hdg", MCF.FEATURE_TRENCH: "tr",
	MCF.FEATURE_WALL: "##", MCF.FEATURE_GLASS: "▢", MCF.FEATURE_LDF: "LDF",
	MCF.FEATURE_CORPSE_WALL: "††", MCF.FEATURE_AIRLOCK: "AL",
	MCF.FEATURE_DIRT_PILE: "drt", MCF.FEATURE_DPMG: "MG",
	MCF.FEATURE_DOT: "PBX", MCF.FEATURE_WOOD_WALL: "WD",
	MCF.FEATURE_SANDBAG_WALL: "SB", MCF.FEATURE_HEDGEHOG_SANDBAGS: "hSB",
	MCF.FEATURE_DOT_OPEN: "PBX+",
}

func _draw_feature(coord: Vector2i, fid: String, height: float, font: Font) -> void:
	var o := _cell_origin(coord)
	# Имя картинки совпадает с id объекта (sandbags.png, trench.png...) (#55).
	if Sprites.draw_texture_override(self, fid, o, float(CELL)):
		return
	var tag: String = FEATURE_TAGS.get(fid, "?")
	if fid == MCF.FEATURE_LDF:
		draw_rect(Rect2(o + Vector2(3, 3), Vector2(CELL - 6, CELL - 6)), Color(0.06, 0.06, 0.07))
		draw_rect(Rect2(o + Vector2(3, 3), Vector2(CELL - 6, CELL - 6)),
			Color(0.35, 0.35, 0.4), false, 1.0)
	else:
		draw_rect(Rect2(o + Vector2(8, 8), Vector2(CELL - 16, CELL - 16)),
			Color(0.6, 0.6, 0.7), false, 2.0)
	draw_string(font, o + Vector2(6, CELL - 15), tag,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.75, 0.85))
	if height > 0.0:
		draw_string(font, o + Vector2(6, CELL - 4), "%.1fm" % height,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.9, 0.78, 0.5))

func _draw_token(coord: Vector2i, owner: int, stats_id: String, font: Font) -> void:
	# Техника (#10) рисуется прямоугольником по всему следу.
	if VehicleDB.is_vehicle(stats_id):
		var size := VehicleDB.size_of(stats_id)
		var rect := Rect2(_cell_origin(coord) + Vector2(3, 3),
			Vector2(size.x * CELL - 6, size.y * CELL - 6))
		draw_rect(rect, Color(_side_color(owner), 0.85))
		draw_rect(rect, Color(0, 0, 0, 0.7), false, 2.0)
		var vname := String(VehicleDB.get_vehicle(stats_id).get("name", "??"))
		draw_string(font, rect.position + Vector2(6, 22), _initials(vname),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		return
	var center := _cell_origin(coord) + Vector2(CELL, CELL) * 0.5
	draw_circle(center, CELL * 0.33, _side_color(owner))
	var s := _stats(stats_id)
	var tag := _initials(s.display_name) if s != null else "??"
	draw_string(font, center + Vector2(-9, 5), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)

func _initials(name: String) -> String:
	var parts := name.split(" ", false)
	if parts.size() >= 2:
		return (parts[0].substr(0, 1) + parts[1].substr(0, 1)).to_upper()
	return name.substr(0, 2).to_upper()

# --- UI ---
func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)

	_panel = PanelContainer.new()
	_panel.position = Vector2(940, 20)
	_panel.custom_minimum_size = Vector2(320, 720)
	SteamChrome.apply_panel(_panel)
	_ui.add_child(_panel)

	# Оконная рамка со стилем интерфейса: шапка + прокручиваемое тело (#59).
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	_panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Deploy Your Force"))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(300, 660)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(SteamChrome.pad(scroll, 8, 8))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	_phase_label = Label.new()
	_phase_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_phase_label)

	_budget_label = Label.new()
	_budget_label.add_theme_font_size_override("font_size", 15)
	vbox.add_child(_budget_label)

	vbox.add_child(HSeparator.new())

	# Инициатива видна уже на расстановке (item 44): показываем порядок сторон с их
	# цветами и командами. Точная позиция нейтральных групп бросается в бою (§15) — здесь
	# лишь оговорка, что нейтралы вклиниваются в очередь при активации.
	var init_title := Label.new()
	init_title.text = "Initiative"
	init_title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(init_title)
	for sid: int in roster.player_ids():
		var irow := HBoxContainer.new()
		irow.add_theme_constant_override("separation", 6)
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(12, 12)
		sw.color = _side_color(sid)
		irow.add_child(sw)
		var nm := roster.name_of(sid)
		if roster.has_teams() and roster.team_of(sid) >= 0:
			nm += " · %s" % MCF.team_name(roster.team_of(sid))
		var il := Label.new()
		il.text = nm
		il.add_theme_font_size_override("font_size", 12)
		irow.add_child(il)
		vbox.add_child(irow)
	if GameConfig.civilians_enabled:
		var neut := Label.new()
		neut.text = "+ Neutrals join initiative when activated"
		neut.add_theme_font_size_override("font_size", 11)
		neut.modulate = Color(0.75, 0.78, 0.85)
		vbox.add_child(neut)

	vbox.add_child(HSeparator.new())

	var hint := Label.new()
	hint.text = "Pick a unit or vehicle, then click — or hold and drag — to deploy across your zone. Click a deployed unit to refund. WASD / drag to pan, wheel to zoom."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(290, 0)
	hint.modulate = Color(0.75, 0.78, 0.85)
	vbox.add_child(hint)

	_palette = VBoxContainer.new()
	_palette.add_theme_constant_override("separation", 3)
	vbox.add_child(_palette)
	for id in PURCHASABLE:
		var s := _stats(id)
		if s == null:
			continue
		_add_palette_button(id, "%s  -  %d pts" % [s.display_name, s.cost])

	# Раздел техники (#10).
	var mach_lbl := Label.new()
	mach_lbl.text = "— Machinery —"
	mach_lbl.modulate = Color(0.75, 0.78, 0.85)
	_palette.add_child(mach_lbl)
	for vid in PURCHASABLE_VEHICLES:
		if not VehicleDB.is_vehicle(vid):
			continue
		_add_palette_button(vid, "%s  -  %d pts" % [_display_name(vid), _cost(vid)])

	vbox.add_child(HSeparator.new())

	_flow_btn = Button.new()
	_flow_btn.custom_minimum_size = Vector2(0, 42)
	_flow_btn.pressed.connect(_on_net_ready if networked() else _on_flow)
	vbox.add_child(_flow_btn)

	var back_btn := Button.new()
	# В сетевой партии «назад» рвёт связь, поэтому ведём в меню, а не в Setup (#93).
	back_btn.text = "Leave Match" if networked() else "Back to Setup"
	back_btn.pressed.connect(_on_back)
	vbox.add_child(back_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(290, 0)
	_status.modulate = Color(1, 0.85, 0.4)
	vbox.add_child(_status)

	# UI живёт на CanvasLayer — подтянуть общий скин Steam (#59).
	Ui.theme_canvas_layers()

func _add_palette_button(id: String, label: String) -> void:
	var btn := Button.new()
	btn.text = label
	btn.toggle_mode = true
	btn.pressed.connect(_on_pick_unit.bind(id))
	_palette.add_child(btn)
	_palette_buttons[id] = btn

func _on_pick_unit(id: String) -> void:
	brush_unit = id
	for bid in _palette_buttons:
		_palette_buttons[bid].button_pressed = (bid == id)
	_status.text = ""

func _refresh_labels() -> void:
	_phase_label.text = "Deploying: %s" % _side_label(active_side)
	_phase_label.modulate = _side_color(active_side)
	var count := 0
	for p in placed:
		if _paid_by(p) == active_side:
			count += 1
	_budget_label.text = "Points spent: %d   (units: %d)" % [spent[active_side], count]
	if networked():
		_flow_btn.text = "Waiting..." if _my_ready else "Ready"
	else:
		var sides := _sides()
		var at := sides.find(active_side)
		if at >= 0 and at < sides.size() - 1:
			_flow_btn.text = "Next: %s  >" % _side_label(sides[at + 1])
		else:
			_flow_btn.text = "Start Battle"

## Подпись стороны: в сетевой партии игрок видит себя как «Player A/B (you)» (#93).
func _side_label(side: int) -> String:
	var base := roster.name_of(side)
	if networked():
		if side == MCF.Owner.PLAYER_1:
			base += " (host)"
		if side == _my_side:
			base += " (you)"
	return base

## Свои — синие, чужие — красные, у обеих сторон одинаково (#93). В горячем стуле
## цвет остаётся привязан к номеру игрока.
func _side_color(side: int) -> Color:
	if MCF.is_neutral(side):
		return NEUTRAL_COLOR
	# Перспектива работает, только пока противник ОДИН: на троих она слила бы двух
	# разных соперников в один цвет.
	if networked() and _sides().size() == 2:
		return OWN_COLOR if side == _my_side else FOE_COLOR
	return roster.color_of(side)

func _side_unit_count(side: int) -> int:
	var n := 0
	for p in placed:
		if int(p["owner"]) == side:
			n += 1
	return n

## Хот-сит: стороны расставляются по очереди, последняя запускает бой.
func _on_flow() -> void:
	if _side_unit_count(active_side) == 0:
		_status.text = "Deploy at least one unit for %s." % _side_label(active_side)
		return
	var sides := _sides()
	var at := sides.find(active_side)
	if at >= 0 and at < sides.size() - 1:
		active_side = sides[at + 1]
		brush_unit = ""
		for c in _palette.get_children():
			if c is Button:
				c.button_pressed = false
		_status.text = ""
		_refresh_labels()
		queue_redraw()
		return
	_start_battle()

func _start_battle() -> void:
	# Собираем спавны: расставленные игроками + сохранённые мирные.
	map.spawns = []
	for p in placed:
		map.set_spawn(p["coord"], p["stats_id"], int(p["owner"]))
	# Армия соперника приходит по сети — обе стороны собирают ОДИН И ТОТ ЖЕ ростер (#93).
	for e in _remote_roster:
		map.set_spawn(Vector2i(int(e["x"]), int(e["y"])), str(e["id"]), int(e["o"]))
	for s in preserved_neutral:
		map.set_spawn(s["coord"], s["stats_id"], MCF.Owner.NEUTRAL)
	if networked():
		# Своя армия у сторон идёт в списке первой, а id юнитов раздаются по порядку
		# спавна — без канонической сортировки id хоста и клиента разъехались бы, и
		# намерения (они ссылаются на id) применялись бы не к тем юнитам.
		_sort_spawns()
	MapHandoff.pending = map
	if networked():
		# Одно зерно на двоих: локальный бросок инициативы обязан совпасть.
		MapHandoff.dice_seed = _shared_seed
		_hand_session_to_battle()
	get_tree().change_scene_to_file(MAIN_SCENE)

func _sort_spawns() -> void:
	map.spawns.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ao := int(a["owner"])
		var bo := int(b["owner"])
		if ao != bo:
			return ao < bo
		var ac: Vector2i = a["coord"]
		var bc: Vector2i = b["coord"]
		if ac.y != bc.y:
			return ac.y < bc.y
		if ac.x != bc.x:
			return ac.x < bc.x
		return str(a["stats_id"]) < str(b["stats_id"]))

## Сессия переезжает в бой: пока сцены меняются, входящие пакеты копятся в буфере
## NetworkSession, а Main подхватит их своим attach().
func _hand_session_to_battle() -> void:
	_net.detach()
	if _net.message.is_connected(_on_net_message):
		_net.message.disconnect(_on_net_message)
	NetHandoff.session = _net
	NetHandoff.is_host = _net_is_host
	_net = null

func _on_back() -> void:
	if _net != null:
		_drop_session()
		get_tree().change_scene_to_file(MENU_SCENE)
		return
	get_tree().change_scene_to_file(SETUP_SCENE)
