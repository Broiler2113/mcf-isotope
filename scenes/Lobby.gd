extends Control

## Лобби мультиплеера / сборки партии (item 4, §1 «Лобби»). Заменяет старый Setup для
## сетевой и локальной настройки: собирает Roster (кто играет, команда, цвет) и словарь
## правил в GameConfig, затем передаёт бой тем же путём, что и Setup — через NetHandoff.
##
## Хост распоряжается всеми правилами, картой и слотами. Подключившийся клиент попадает
## сюда же (item 61), но из всего управления ему доступен ТОЛЬКО выбор своего цвета —
## остальное только для чтения, пока хост не начнёт партию.

const PLACEMENT_SCENE := "res://scenes/Placement.tscn"
const MENU_SCENE := "res://scenes/MainMenu.tscn"
const SteamChrome = preload("res://src/ui/SteamChrome.gd")

const GAME_MODES := ["domination"]

var _ui: CanvasLayer
var roster: Roster
var _is_client := false   # мы подключившийся гость (не хост)

# Ссылки на управляющие элементы хоста.
var _max_spin: SpinBox
var _place_opt: OptionButton
var _fog_opt: OptionButton
var _army_opt: OptionButton
var _mode_opt: OptionButton
var _ff_check: CheckBox
var _live_check: CheckBox
var _events_check: CheckBox
var _events_mand: CheckBox
var _events_interval: SpinBox
var _map_opt: OptionButton
var _map_preview: TextureRect
var _slots_box: VBoxContainer
var _preview_swatch: ColorRect
var _status: Label

var _map_paths: Array[String] = []

func _ready() -> void:
	_is_client = NetHandoff.session != null and not NetHandoff.is_host
	roster = _seed_roster()
	_build_ui()
	_refresh_slots()
	_refresh_map_preview()
	# Гость (item 61) сидит в лобби и ждёт, когда хост объявит условия матча (K_SETUP);
	# по ним он и уходит на закупку. До того он может трогать только свой цвет.
	if _is_client and NetHandoff.session != null:
		NetHandoff.session.message.connect(_on_client_message)
		NetHandoff.session.disconnected.connect(_on_client_lost)
		NetHandoff.session.attach()
		_status.text = "Connected — waiting for the host to start the match…"

func _on_client_message(msg: Dictionary) -> void:
	if str(msg.get("k", "")) != NetHandoff.K_SETUP:
		return
	NetHandoff.apply_setup(msg)
	# Буфер входящих переедет с сессией — Placement заберёт его своим attach().
	NetHandoff.session.detach()
	NetHandoff.session.message.disconnect(_on_client_message)
	get_tree().change_scene_to_file(PLACEMENT_SCENE)

func _on_client_lost() -> void:
	if _status != null:
		_status.text = "Connection lost — returning to the menu."
	NetHandoff.discard()
	get_tree().change_scene_to_file(MENU_SCENE)

## Начальный ростер: дуэль из двух слотов (хост-человек + открытый), как минимум для игры.
func _seed_roster() -> Roster:
	var r := Roster.new()
	r.add_slot(Roster.SlotKind.HUMAN)   # слот 0 — хост
	r.add_slot(Roster.SlotKind.OPEN)    # слот 1
	return r

# --- UI ----------------------------------------------------------------------
func _build_ui() -> void:
	Ui.theme_canvas_layers()
	_ui = CanvasLayer.new()
	add_child(_ui)

	var root := PanelContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	SteamChrome.apply_panel(root)
	_ui.add_child(root)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	root.add_child(outer)
	outer.add_child(SteamChrome.header_bar("Multiplayer Lobby"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(SteamChrome.pad(cols, 14, 12))

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)

	_build_config(left)
	_build_map(left)
	_build_slots(right)
	_build_personal(right)

	# Нижняя полоса действий.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	outer.add_child(SteamChrome.pad(bar, 14, 10))
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.add_theme_font_size_override("font_size", 12)
	bar.add_child(_status)
	var back := Button.new()
	back.text = "Disconnect" if _is_client else "Back"
	back.pressed.connect(_on_back)
	bar.add_child(back)
	if not _is_client:
		var start := Button.new()
		start.text = "Start Match"
		start.pressed.connect(_on_start)
		bar.add_child(start)

func _titled(parent: VBoxContainer, title: String) -> VBoxContainer:
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 15)
	parent.add_child(lbl)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	parent.add_child(box)
	parent.add_child(HSeparator.new())
	return box

func _row(box: VBoxContainer, label_text: String, control: Control) -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(130, 0)
	l.add_theme_font_size_override("font_size", 12)
	r.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(control)
	box.add_child(r)

func _build_config(parent: VBoxContainer) -> void:
	var box := _titled(parent, "Lobby Configuration")
	_max_spin = SpinBox.new()
	_max_spin.min_value = 2
	_max_spin.max_value = MCF.MAX_PLAYERS
	_max_spin.value = 2
	_row(box, "Max Players:", _max_spin)

	_place_opt = _opt(["Asymmetric", "Mirrored"], GameConfig.placement_mode)
	_row(box, "Placement:", _place_opt)

	_fog_opt = _opt(["Off", "Standard", "Realistic"], GameConfig.fog_mode)
	_row(box, "Fog of War:", _fog_opt)

	_army_opt = _opt(["Host Decides", "Players Pick"], GameConfig.army_select_mode)
	_army_opt.item_selected.connect(func(_i: int) -> void: _refresh_personal_enabled())
	_row(box, "Army Select:", _army_opt)

	_mode_opt = _opt(["Domination"], 0)
	_row(box, "Game Mode:", _mode_opt)

	_ff_check = CheckBox.new()
	_ff_check.text = "Friendly fire (team mode)"
	_ff_check.button_pressed = GameConfig.friendly_fire
	box.add_child(_ff_check)

	_live_check = CheckBox.new()
	_live_check.text = "Live placement visibility"
	_live_check.button_pressed = GameConfig.live_placement_visible
	box.add_child(_live_check)

	_events_check = CheckBox.new()
	_events_check.text = "Random events"
	_events_check.button_pressed = GameConfig.random_events_enabled
	box.add_child(_events_check)
	_events_mand = CheckBox.new()
	_events_mand.text = "…mandatory every turn"
	_events_mand.button_pressed = GameConfig.random_events_mandatory
	box.add_child(_events_mand)
	_events_interval = SpinBox.new()
	_events_interval.min_value = 1
	_events_interval.max_value = 20
	_events_interval.value = GameConfig.random_events_interval
	_row(box, "Turns between events:", _events_interval)

	if _is_client:
		for c in [_max_spin, _place_opt, _fog_opt, _army_opt, _mode_opt,
				_ff_check, _live_check, _events_check, _events_mand, _events_interval]:
			(c as Control).disabled = true if c is Button else false
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

func _opt(items: Array, selected: int) -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		o.add_item(str(items[i]), i)
	o.select(clampi(selected, 0, items.size() - 1))
	return o

func _build_map(parent: VBoxContainer) -> void:
	var box := _titled(parent, "Map Selection & Preview")
	_map_opt = OptionButton.new()
	_map_paths = []
	_map_opt.add_item("Blank arena")
	_map_paths.append("")
	var dir := DirAccess.open("res://maps")
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if f.ends_with(".json"):
				_map_opt.add_item(f.get_basename())
				_map_paths.append("res://maps/" + f)
			f = dir.get_next()
	_map_opt.select(0)
	_map_opt.item_selected.connect(func(_i: int) -> void: _refresh_map_preview())
	if _is_client:
		_map_opt.disabled = true
	_row(box, "Map:", _map_opt)

	_map_preview = TextureRect.new()
	_map_preview.custom_minimum_size = Vector2(260, 180)
	_map_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(_map_preview)

func _build_slots(parent: VBoxContainer) -> void:
	_titled(parent, "Team Slots & Players")
	_slots_box = VBoxContainer.new()
	_slots_box.add_theme_constant_override("separation", 4)
	parent.add_child(_slots_box)
	if not _is_client:
		var add := Button.new()
		add.text = "+ Add Slot"
		add.pressed.connect(_on_add_slot)
		parent.add_child(add)
	parent.add_child(HSeparator.new())

func _build_personal(parent: VBoxContainer) -> void:
	var box := _titled(parent, "Personal Setup")
	var color_opt := OptionButton.new()
	for i in Roster.PALETTE.size():
		color_opt.add_item("Color %d" % (i + 1), i)
	color_opt.select(_my_slot().color_index() if _my_slot() != null else 0)
	color_opt.item_selected.connect(_on_my_color)
	_row(box, "Selected Color:", color_opt)
	_preview_swatch = ColorRect.new()
	_preview_swatch.custom_minimum_size = Vector2(64, 64)
	_preview_swatch.color = _my_slot().color if _my_slot() != null else Color.WHITE
	box.add_child(_preview_swatch)
	var note := Label.new()
	note.text = "Live soldier preview (tinted to your color)."
	note.add_theme_font_size_override("font_size", 11)
	note.modulate = Color(0.75, 0.78, 0.85)
	box.add_child(note)

# --- Слоты -------------------------------------------------------------------
func _refresh_slots() -> void:
	if _slots_box == null:
		return
	for c in _slots_box.get_children():
		c.queue_free()
	for s: Roster.Slot in roster.slots:
		_slots_box.add_child(_slot_row(s))

func _slot_row(s: Roster.Slot) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var idx := Label.new()
	idx.text = "%d." % (s.id + 1)
	idx.custom_minimum_size = Vector2(24, 0)
	row.add_child(idx)

	var kind := OptionButton.new()
	for pair in [[Roster.SlotKind.OPEN, "Open"], [Roster.SlotKind.CLOSED, "Closed"],
			[Roster.SlotKind.HUMAN, "Player"], [-10, "AI - Easy"], [-11, "AI - Medium"],
			[-12, "AI - Hard"]]:
		kind.add_item(str(pair[1]))
	kind.select(_kind_index(s))
	kind.item_selected.connect(_on_slot_kind.bind(s.id))
	kind.disabled = _is_client
	row.add_child(kind)

	var color := OptionButton.new()
	for i in Roster.PALETTE.size():
		color.add_item("C%d" % (i + 1), i)
	color.select(s.color_index())
	color.item_selected.connect(_on_slot_color.bind(s.id))
	color.disabled = _is_client
	row.add_child(color)

	var team := SpinBox.new()
	team.min_value = 0
	team.max_value = MCF.MAX_TEAMS
	team.value = s.team + 1  # 0 = «сам за себя»
	team.prefix = "T"
	team.value_changed.connect(_on_slot_team.bind(s.id))
	team.editable = not _is_client
	row.add_child(team)
	return row

func _kind_index(s: Roster.Slot) -> int:
	match s.kind:
		Roster.SlotKind.OPEN: return 0
		Roster.SlotKind.CLOSED: return 1
		Roster.SlotKind.HUMAN: return 2
		Roster.SlotKind.AI: return 3 + clampi(s.ai_difficulty, 0, 2)
	return 0

func _on_add_slot() -> void:
	if roster.slots.size() >= int(_max_spin.value):
		_status.text = "Raise Max Players to add more slots."
		return
	roster.add_slot(Roster.SlotKind.OPEN)
	_refresh_slots()

func _on_slot_kind(index: int, slot_id: int) -> void:
	var s := roster.slots[slot_id] as Roster.Slot
	match index:
		0: s.kind = Roster.SlotKind.OPEN
		1: s.kind = Roster.SlotKind.CLOSED
		2: s.kind = Roster.SlotKind.HUMAN
		_:
			s.kind = Roster.SlotKind.AI
			s.ai_difficulty = clampi(index - 3, 0, 2)

func _on_slot_color(color_idx: int, slot_id: int) -> void:
	if not _assign_color(slot_id, color_idx):
		_status.text = "That colour is taken — no two players share a colour."
	_refresh_slots()

func _on_slot_team(value: float, slot_id: int) -> void:
	(roster.slots[slot_id] as Roster.Slot).team = int(value) - 1

## Назначить цвет слоту, если он свободен (item 25/37 — цвета уникальны по всему лобби).
func _assign_color(slot_id: int, color_idx: int) -> bool:
	var col: Color = Roster.PALETTE[color_idx % Roster.PALETTE.size()]
	for s: Roster.Slot in roster.slots:
		if s.id != slot_id and s.color.is_equal_approx(col):
			return false
	(roster.slots[slot_id] as Roster.Slot).color = col
	return true

# --- Личный цвет (доступен и клиенту) ---------------------------------------
func _my_slot() -> Roster.Slot:
	# Хост ведёт слот 0; гость — слот по порядку подключения (упрощённо — слот 1).
	var id := 0 if not _is_client else 1
	return roster.slots[id] if id < roster.slots.size() else null

func _on_my_color(color_idx: int) -> void:
	var mine := _my_slot()
	if mine == null:
		return
	if not _assign_color(mine.id, color_idx):
		_status.text = "That colour is taken."
		return
	_preview_swatch.color = mine.color
	_refresh_slots()

func _refresh_personal_enabled() -> void:
	# «Host Decides» — цвет назначает хост; «Players Pick» — каждый выбирает сам.
	pass

# --- Предпросмотр карты (item 41) -------------------------------------------
func _selected_map() -> MapData:
	var path: String = _map_paths[_map_opt.selected] if _map_opt != null else ""
	if path == "":
		return MapData.blank_arena()
	var m := MapData.load_from(path)
	return m if m != null else MapData.blank_arena()

func _refresh_map_preview() -> void:
	if _map_preview == null:
		return
	_map_preview.texture = _render_map_texture(_selected_map())

## Полный верхний вид карты В КАРТИНКУ, включая нейтральные спавны (item 41). Рисуем
## по клеткам в Image — без отдельного вьюпорта, зато детерминированно и без сцены.
func _render_map_texture(map: MapData) -> ImageTexture:
	var sc := 6
	var w := maxi(1, map.width) * sc
	var h := maxi(1, map.height) * sc
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in map.height:
		for x in map.width:
			img.fill_rect(Rect2i(x * sc, y * sc, sc, sc), _cell_color(map, Vector2i(x, y)))
	# Нейтралы карты — жёлтые точки поверх (item 41: превью включает нейтралов).
	for s in map.spawns:
		if MCF.is_neutral(int(s["owner"])):
			var c: Vector2i = s["coord"]
			img.fill_rect(Rect2i(c.x * sc + 1, c.y * sc + 1, maxi(1, sc - 2), maxi(1, sc - 2)),
					Roster.NEUTRAL_COLOR)
	return ImageTexture.create_from_image(img)

func _cell_color(map: MapData, coord: Vector2i) -> Color:
	if map.get_space(coord):
		return Color(0.05, 0.06, 0.10)               # космос/пустота
	var feat := map.get_feature(coord)
	if feat != "" or map.get_cover(coord) >= MCF.WALL_HEIGHT:
		return Color(0.45, 0.45, 0.48)               # стены/объекты
	if map.get_cover(coord) > 0.0:
		return Color(0.55, 0.50, 0.35)               # низкое укрытие
	if map.get_floor(coord) == MCF.FLOOR_GRASS:
		return Color(0.28, 0.45, 0.24)               # трава
	return Color(0.34, 0.30, 0.26)                   # обычный пол

# --- Старт / выход -----------------------------------------------------------
func _commit_config() -> void:
	GameConfig.placement_mode = _place_opt.selected
	GameConfig.fog_mode = _fog_opt.selected
	GameConfig.army_select_mode = _army_opt.selected
	GameConfig.game_mode = GAME_MODES[clampi(_mode_opt.selected, 0, GAME_MODES.size() - 1)]
	GameConfig.friendly_fire = _ff_check.button_pressed
	GameConfig.live_placement_visible = _live_check.button_pressed
	GameConfig.random_events_enabled = _events_check.button_pressed
	GameConfig.random_events_mandatory = _events_mand.button_pressed
	GameConfig.random_events_interval = int(_events_interval.value)
	if GameConfig.random_events_weights.is_empty():
		GameConfig.random_events_weights = RandomEvents.default_weights()
	GameConfig.map_path = _map_paths[_map_opt.selected]
	GameConfig.roster = roster

func _on_start() -> void:
	if roster.has_duplicate_colors():
		_status.text = "Two players share a colour — fix that first."
		return
	var playing := 0
	for s: Roster.Slot in roster.slots:
		if s.is_playing():
			playing += 1
	if playing < 2:
		_status.text = "Need at least two playing slots (Player or AI)."
		return
	_commit_config()
	# Сетевой хост объявляет карту клиентам тем же путём, что и старый Setup.
	if NetHandoff.session != null and NetHandoff.is_host:
		var shared: MapData = _selected_map()
		NetHandoff.session.send(NetHandoff.encode_setup(shared))
		NetHandoff.lobby_map = shared
	get_tree().change_scene_to_file(PLACEMENT_SCENE)

func _on_back() -> void:
	if NetHandoff.session != null:
		NetHandoff.discard()
	get_tree().change_scene_to_file(MENU_SCENE)
