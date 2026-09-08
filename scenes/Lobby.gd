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
const MAIN_SCENE := "res://scenes/Main.tscn"
const SteamChrome = preload("res://src/ui/SteamChrome.gd")
## Списки покупаемых юнитов/техники берём из самого экрана расстановки (item 12) —
## один источник правды, чтобы ограничения и палитра не разъехались.
const PlacementScript = preload("res://scenes/Placement.gd")

const GAME_MODES := ["domination"]

## Ширины колонок таблицы слотов (item 4): один и тот же набор у заголовков и у строк,
## чтобы «Type/Color/Zone/Points» стояли ровно над своими контролами, а не сбоку.
const SLOT_COL_IDX := 26
const SLOT_COL_TYPE := 124
const SLOT_COL_COLOR := 124
const SLOT_COL_TEAM := 64
const SLOT_COL_ZONE := 100
const SLOT_COL_PTS := 124

var _ui: CanvasLayer
var roster: Roster
var _is_client := false   # мы подключившийся гость (не хост)

# Ссылки на управляющие элементы хоста.
var _place_opt: OptionButton
var _fog_opt: OptionButton
var _army_opt: OptionButton
var _mode_opt: OptionButton
var _ff_check: CheckBox
## «Disable neutrals» (item 2): инверсия GameConfig.civilians_enabled.
var _no_neutrals_check: CheckBox
## Командный режим (item 4): пока выключен — колонка «Team» и «дружественный огонь»
## скрыты. Отдельные команды появляются только по этому тумблеру.
var _team_mode: bool = false
var _team_check: CheckBox
var _live_check: CheckBox
var _events_check: CheckBox
## Выбор событий в пул (item 3/5): ev_id -> bool. Правится в отдельном окне.
var _event_pool: Dictionary = {}
var _events_mand: CheckBox
var _events_interval: SpinBox
var _map_opt: OptionButton
var _map_preview: TextureRect
var _slots_box: VBoxContainer
var _preview_swatch: ColorRect
var _status: Label

var _map_paths: Array[String] = []

# --- Загруженная партия (M12, item 42) ---
## Содержимое `.mcfs`, если хост открыл сохранение. Пусто — обычный матч с закупкой.
var _save: Dictionary = {}
var _save_names: PackedStringArray
var _save_opt: OptionButton
## Сколько живых юнитов в сохранении у каждой стороны — по ним хост и понимает,
## какую армию кому отдаёт.
var _save_armies: Dictionary = {}

## Роль лобби: гость (подключился к хосту), сетевой хост, либо одиночка (без сессии).
var _is_host_net: bool = false
var _is_solo: bool = false
## Маяк локальной сети хоста (item 10): пока хост сидит в лобби, он продолжает
## объявлять партию — иначе клиенты перестали бы его находить.
var _lan_adv: LanDiscovery = null

func _ready() -> void:
	_is_client = NetHandoff.session != null and not NetHandoff.is_host
	_is_host_net = NetHandoff.session != null and NetHandoff.is_host
	_is_solo = NetHandoff.session == null
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
	# Сетевой хост открыл лобби сразу (item 10): ждём подключения, продолжая объявлять
	# партию в LAN. Когда гость подключится — обновим статус.
	if _is_host_net:
		NetHandoff.session.peer_ready.connect(_on_host_peer_joined)
		NetHandoff.session.disconnected.connect(_on_host_peer_left)
		_status.text = "Hosting — waiting for a player to join. You can also add AI slots and start now."
		_lan_adv = LanDiscovery.new()
		get_tree().root.add_child.call_deferred(_lan_adv)
		_lan_adv.start_advertising.call_deferred({
			"name": "MCF Tactics", "players": 1, "port": NetworkSession.DEFAULT_PORT})

func _on_host_peer_joined(_is_host: bool) -> void:
	if _status != null:
		_status.text = "A player joined — set their slot to Player, then Start Match."
	# Свободный слот отдаём подключившемуся человеку, чтобы «playing >= 2» выполнилось.
	for s: Roster.Slot in roster.slots:
		if s.kind == Roster.SlotKind.OPEN:
			s.kind = Roster.SlotKind.HUMAN
			break
	_refresh_slots()

func _on_host_peer_left() -> void:
	if _status != null:
		_status.text = "The other player disconnected. Waiting for a new one…"

func _exit_tree() -> void:
	if _lan_adv != null:
		_lan_adv.stop()
		_lan_adv.queue_free()
		_lan_adv = null

func _on_client_message(msg: Dictionary) -> void:
	# Хост открыл сохранение (M12): доска приезжает целиком, и закупка пропускается.
	if str(msg.get("k", "")) == NetHandoff.K_LOAD:
		NetHandoff.apply_load(msg)
		NetHandoff.session.detach()
		NetHandoff.session.message.disconnect(_on_client_message)
		get_tree().change_scene_to_file(MAIN_SCENE)
		return
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
	r.add_slot(Roster.SlotKind.HUMAN)   # слот 0 — этот игрок (хост/одиночка)
	# В одиночке второй слот — ИИ (item 20): партия готова к старту сразу, без соперника-
	# человека. В сетевой игре он ОТКРЫТ и ждёт гостя.
	if _is_solo:
		r.add_slot(Roster.SlotKind.AI)
	else:
		r.add_slot(Roster.SlotKind.OPEN)
	# Стартовый личный бюджет у каждого слота — общий по умолчанию (item 1).
	for s: Roster.Slot in r.slots:
		s.budget = GameConfig.DEFAULT_BUDGET
	return r

# --- UI ----------------------------------------------------------------------
func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)

	var root := PanelContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	SteamChrome.apply_panel(root)
	_ui.add_child(root)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	root.add_child(outer)
	# Одно окно и для одиночки, и для сети (item 20) — заголовок под роль.
	outer.add_child(SteamChrome.header_bar("New Game" if _is_solo else "Multiplayer Lobby"))

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
	if not _is_client:
		_build_load(left)
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
	# Тема применяется ПОСЛЕ сборки (item 2): раньше вызов стоял до создания _ui, и слой
	# лобби оставался с дефолтным скином Godot вместо общего стиля игры.
	Ui.theme_canvas_layers()

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
	# «Max Players» убран (item 4): игроки добавляются кнопкой «+ Add Slot» и убираются
	# «✕» в списке слотов; потолок — MCF.MAX_PLAYERS, но задавать его вручную не нужно.

	_place_opt = _opt(["Asymmetric", "Mirrored"], GameConfig.placement_mode)
	_row(box, "Placement:", _place_opt)

	_fog_opt = _opt(["Off", "Standard", "Realistic"], GameConfig.fog_mode)
	_row(box, "Fog of War:", _fog_opt)

	_army_opt = _opt(["Host Decides", "Players Pick"], GameConfig.army_select_mode)
	_army_opt.item_selected.connect(func(_i: int) -> void: _refresh_personal_enabled())
	_row(box, "Army Select:", _army_opt)

	_mode_opt = _opt(["Domination"], 0)
	_row(box, "Game Mode:", _mode_opt)

	# Командный режим (item 4): тумблер. Пока выключен — «дружественный огонь» и колонка
	# команд в слотах скрыты. Включение перерисовывает слоты, чтобы показать колонку.
	# По умолчанию командный режим ВЫКЛЮЧЕН (item 4); включается тумблером или если
	# в ростере уже заданы команды (например, из сохранения).
	_team_mode = _roster_has_teams()
	_team_check = CheckBox.new()
	_team_check.text = "Team mode"
	_team_check.button_pressed = _team_mode
	_team_check.toggled.connect(func(on: bool) -> void:
		_team_mode = on
		_ff_check.visible = on
		if not on:
			for s: Roster.Slot in roster.slots:
				s.team = -1
		_refresh_slots())
	box.add_child(_team_check)

	_ff_check = CheckBox.new()
	_ff_check.text = "Friendly fire"
	_ff_check.button_pressed = GameConfig.friendly_fire
	_ff_check.visible = _team_mode
	box.add_child(_ff_check)

	_live_check = CheckBox.new()
	_live_check.text = "Live placement visibility"
	_live_check.button_pressed = GameConfig.live_placement_visible
	box.add_child(_live_check)

	# «Disable neutrals» (item 2): выключает мирных/нейтралов на карте. Инвертируем
	# GameConfig.civilians_enabled — галочка «выключить» удобнее, чем «включить».
	_no_neutrals_check = CheckBox.new()
	_no_neutrals_check.text = "Disable neutrals"
	_no_neutrals_check.button_pressed = not GameConfig.civilians_enabled
	box.add_child(_no_neutrals_check)

	# --- Случайные события (item 5/11) ---
	# Раскладка: заголовок → «Enable» → «Mandatory» → интервал → список из трёх событий
	# с галочками (выбранный пул). Семантика «Mandatory» новая (item 11): на «созревший»
	# ход при включённом флаге ОБЯЗАТЕЛЬНО происходит одно из выбранных событий; при
	# выключенном — есть шанс, что не случится ничего.
	var ev_box := _titled(parent, "Random Events")
	_events_check = CheckBox.new()
	_events_check.text = "Enable random events"
	_events_check.button_pressed = GameConfig.random_events_enabled
	ev_box.add_child(_events_check)
	_events_mand = CheckBox.new()
	_events_mand.text = "Mandatory (a due turn always fires one)"
	_events_mand.button_pressed = GameConfig.random_events_mandatory
	ev_box.add_child(_events_mand)
	_events_interval = SpinBox.new()
	_events_interval.min_value = 1
	_events_interval.max_value = 20
	_events_interval.value = GameConfig.random_events_interval
	_row(ev_box, "Turns between events:", _events_interval)
	# Пул событий — в ОТДЕЛЬНОМ окне (item 3), а не длинным списком прямо в конфиге.
	var cur_weights: Dictionary = GameConfig.random_events_weights
	if cur_weights.is_empty():
		cur_weights = RandomEvents.default_weights()
	_event_pool = {}
	for pair in RandomEvents.REGISTRY:
		_event_pool[pair[0]] = float(cur_weights.get(pair[0], 0.0)) > 0.0
	var pool_btn := Button.new()
	pool_btn.text = "Choose Events…"
	pool_btn.disabled = _is_client
	pool_btn.pressed.connect(_open_events_window)
	ev_box.add_child(pool_btn)

	if _is_client:
		var _client_locked: Array = [_place_opt, _fog_opt, _army_opt, _mode_opt,
				_ff_check, _team_check, _live_check, _no_neutrals_check, _events_check,
				_events_mand, _events_interval]
		for c in _client_locked:
			# У кнопок (в т. ч. OptionButton/CheckBox — все наследники BaseButton) есть
			# .disabled; у SpinBox её нет, он глохнет через .editable. Присваивать
			# .disabled всем подряд нельзя (item 18): на SpinBox это роняло клиента с
			# «Invalid assignment of property 'disabled' … on SpinBox» при входе в лобби.
			if c is BaseButton:
				(c as BaseButton).disabled = true
			elif c is SpinBox:
				(c as SpinBox).editable = false
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
	# ВСЕ сохранённые карты (item 1): и поставочные (res://maps), и созданные в редакторе
	# (user://maps). MapData.list_maps() объединяет оба каталога без дублей.
	for name in MapData.list_maps():
		_map_opt.add_item(name.get_basename())
		_map_paths.append(MapData.path_for(name))
	_map_opt.select(0)
	# Смена карты обновляет и превью, и слоты — у зон свой предел от карты (item 6).
	_map_opt.item_selected.connect(func(_i: int) -> void:
		_refresh_map_preview()
		_refresh_slots())
	if _is_client:
		_map_opt.disabled = true
	_row(box, "Map:", _map_opt)

	_map_preview = TextureRect.new()
	_map_preview.custom_minimum_size = Vector2(260, 180)
	_map_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(_map_preview)

## Открыть сохранённую партию прямо в лобби (item 42). Смысл именно здесь, а не в
## меню: доска и армии в файле уже есть, а вот КТО их ведёт — вопрос сегодняшнего
## стола. Ростер в лобби правится как обычно, и на старте он просто подменяет
## сохранённый; ни одного владельца юнита при этом переписывать не нужно.
func _build_load(parent: VBoxContainer) -> void:
	var box := _titled(parent, "Saved Game")
	_save_names = ReplayFile.saves()
	_save_opt = OptionButton.new()
	if _save_names.is_empty():
		_save_opt.add_item("(no saved games)")
		_save_opt.disabled = true
	else:
		for name in _save_names:
			_save_opt.add_item(name.get_basename())
	_row(box, "File:", _save_opt)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.pressed.connect(_on_load_save)
	load_btn.disabled = _save_names.is_empty()
	row.add_child(load_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.pressed.connect(_on_clear_save)
	row.add_child(clear_btn)
	var note := Label.new()
	note.text = "Loading a save skips deployment: the armies are already on the board. Assign each of them to a player or an AI in the slot list."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.modulate = Color(0.75, 0.78, 0.85)
	box.add_child(note)

func _on_load_save() -> void:
	if _save_opt == null or _save_names.is_empty():
		return
	var name := _save_names[clampi(_save_opt.selected, 0, _save_names.size() - 1)]
	var data := ReplayFile.read(ReplayFile.path_for(ReplayFile.SAVE_DIR, name))
	if data.is_empty():
		_status.text = "Could not read %s." % name
		return
	var saved: Dictionary = data.get("state", {})
	_save = data
	_save_armies = _count_armies(saved)
	# Ростер файла становится основой: слоты, цвета и команды в нём уже те, что были в
	# бою. Хост дальше правит их как обычно — это и есть переназначение ролей.
	roster = Roster.from_dict(saved.get("roster", {}))
	_refresh_slots()
	_status.text = "Loaded %s — %d armies on the board." % [name, _save_armies.size()]

func _on_clear_save() -> void:
	_save = {}
	_save_armies = {}
	_status.text = "Saved game cleared — the match will start from deployment."

## Живые юниты по сторонам прямо из файла: разбирать его в GameState ради счётчика
## незачем, а показать «Player B: 11 units» надо до старта.
func _count_armies(saved: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for raw in saved.get("units", []):
		var rec: Dictionary = raw
		if int(rec.get("status", 0)) == MCF.Status.CORPSE:
			continue
		var owner := int(rec.get("owner", -1))
		out[owner] = int(out.get(owner, 0)) + 1
	return out

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
		color_opt.add_item(Roster.color_name(i), i)  # имена цветов (item 3)
	color_opt.select(_my_slot().color_index() if _my_slot() != null else 0)
	color_opt.item_selected.connect(_on_my_color)
	_row(box, "Selected Color:", color_opt)
	_preview_swatch = ColorRect.new()
	_preview_swatch.custom_minimum_size = Vector2(64, 64)
	_preview_swatch.color = _my_slot().color if _my_slot() != null else Color.WHITE
	box.add_child(_preview_swatch)
	var note := Label.new()
	note.text = "Your soldiers show as circles in this colour."
	note.add_theme_font_size_override("font_size", 11)
	note.modulate = Color(0.75, 0.78, 0.85)
	box.add_child(note)

# --- Слоты -------------------------------------------------------------------
func _refresh_slots() -> void:
	if _slots_box == null:
		return
	for c in _slots_box.get_children():
		c.queue_free()
	_slots_box.add_child(_slot_header())
	for s: Roster.Slot in roster.slots:
		_slots_box.add_child(_slot_row(s))

func _slot_row(s: Roster.Slot) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var idx := Label.new()
	idx.text = "%d." % (s.id + 1)
	idx.custom_minimum_size = Vector2(SLOT_COL_IDX, 0)
	row.add_child(idx)

	var kind := OptionButton.new()
	for pair in [[Roster.SlotKind.OPEN, "Open"], [Roster.SlotKind.CLOSED, "Closed"],
			[Roster.SlotKind.HUMAN, "Player"], [-10, "AI - Easy"], [-11, "AI - Medium"],
			[-12, "AI - Hard"]]:
		kind.add_item(str(pair[1]))
	kind.select(_kind_index(s))
	kind.item_selected.connect(_on_slot_kind.bind(s.id))
	kind.disabled = _is_client
	kind.custom_minimum_size = Vector2(SLOT_COL_TYPE, 0)
	row.add_child(kind)

	var color := OptionButton.new()
	# Настоящие названия цветов вместо «C1…C26» (item 3).
	for i in Roster.PALETTE.size():
		color.add_item(Roster.color_name(i), i)
	color.select(s.color_index())
	color.item_selected.connect(_on_slot_color.bind(s.id))
	color.disabled = _is_client
	color.custom_minimum_size = Vector2(SLOT_COL_COLOR, 0)
	row.add_child(color)

	# Колонка команды показывается ТОЛЬКО в командном режиме (item 4).
	if _team_mode:
		var team := SpinBox.new()
		team.min_value = 0
		team.max_value = MCF.MAX_TEAMS
		team.value = s.team + 1  # 0 = «сам за себя»
		team.prefix = "T"
		team.value_changed.connect(_on_slot_team.bind(s.id))
		team.editable = not _is_client
		team.custom_minimum_size = Vector2(SLOT_COL_TEAM, 0)
		row.add_child(team)

	# Зона развёртывания (item 10): в какой нарисованной зоне слот ставит отряд.
	# 0 = «своя по номеру», 1..N = конкретная Zone N. Диапазон ограничен зонами,
	# которые РЕАЛЬНО есть на выбранной карте (item 6).
	var zone := SpinBox.new()
	zone.min_value = 0
	zone.max_value = maxi(1, _map_zone_count())
	zone.value = (s.deploy_zone + 1) if s.deploy_zone >= 0 else 0
	zone.prefix = "Zone "
	zone.value_changed.connect(_on_slot_zone.bind(s.id))
	zone.editable = not _is_client
	zone.custom_minimum_size = Vector2(SLOT_COL_ZONE, 0)
	row.add_child(zone)

	# Личный бюджет очков (item 1): без жёсткого потолка. 0 = безлимит.
	var budget := SpinBox.new()
	budget.min_value = 0
	budget.max_value = 1000000
	budget.step = 25
	budget.value = s.budget
	budget.prefix = "Pts "
	budget.value_changed.connect(_on_slot_budget.bind(s.id))
	budget.editable = not _is_client
	budget.custom_minimum_size = Vector2(SLOT_COL_PTS, 0)
	row.add_child(budget)

	# Ограничение состава ДЛЯ ЭТОГО ИГРОКА (item 2): открывает окно с галочками.
	if not _is_client:
		var restrict := Button.new()
		restrict.text = "Units"
		restrict.pressed.connect(_open_unit_restrict_window.bind(s.id))
		row.add_child(restrict)

	# Из загруженного файла: какая армия достанется этому слоту (item 42).
	if _save_armies.has(s.id):
		var army := Label.new()
		army.text = "%d units" % int(_save_armies[s.id])
		army.add_theme_font_size_override("font_size", 11)
		army.modulate = Color(0.75, 0.85, 0.75)
		row.add_child(army)

	# Удаление слота (item 4): «✕» справа. Нельзя убрать последние два — партии нужен
	# хотя бы дуэт. Хост правит список, клиент только смотрит.
	if not _is_client and roster.slots.size() > 2:
		var del := Button.new()
		del.text = "✕"
		del.pressed.connect(_on_remove_slot.bind(s.id))
		row.add_child(del)
	return row

## Заголовки колонок над списком слотов (item 9): что означает каждый столбец. Колонка
## «Team» появляется только в командном режиме (item 4).
func _slot_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	# Ширины СТРОГО совпадают с контролами строк, иначе заголовки съезжают вбок (item 4).
	var cols: Array = [["#", SLOT_COL_IDX], ["Type", SLOT_COL_TYPE], ["Color", SLOT_COL_COLOR]]
	if _team_mode:
		cols.append(["Team", SLOT_COL_TEAM])
	cols.append_array([["Zone", SLOT_COL_ZONE], ["Points", SLOT_COL_PTS]])
	for pair in cols:
		var l := Label.new()
		l.text = str(pair[0])
		l.custom_minimum_size = Vector2(float(pair[1]), 0)
		l.add_theme_font_size_override("font_size", 11)
		l.modulate = Color(0.72, 0.76, 0.85)
		row.add_child(l)
	return row

func _roster_has_teams() -> bool:
	if roster == null:
		return false
	for s: Roster.Slot in roster.slots:
		if s.team >= 0:
			return true
	return false

## Сколько РАЗНЫХ зон нарисовано на выбранной карте (item 6). По нему ограничиваем
## выбор зоны в слотах: нельзя посадить игрока в несуществующую зону.
func _map_zone_count() -> int:
	var m := _selected_map()
	if m == null:
		return MCF.MAX_PLAYERS
	var seen := {}
	for y in m.height:
		for x in m.width:
			var z := m.get_zone(Vector2i(x, y))
			if z >= 0:
				seen[z] = true
	# Нет размеченных зон — карта делится автоматически, зоны по числу игроков.
	return seen.size() if seen.size() > 0 else roster.slots.size()

func _on_slot_budget(value: float, slot_id: int) -> void:
	(roster.slots[slot_id] as Roster.Slot).budget = int(value)

## Окно ограничения состава ДЛЯ КОНКРЕТНОГО слота (item 2).
func _open_unit_restrict_window(slot_id: int) -> void:
	var s := roster.slots[slot_id] as Roster.Slot
	var body := _modal_window("Allowed Units — %s" % Roster.color_name(s.color_index()))
	var hint := Label.new()
	hint.text = "Unchecked units can't be bought by this player."
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.75, 0.78, 0.85)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	var all_buyable: Array = []
	all_buyable.append_array(PlacementScript.PURCHASABLE)
	all_buyable.append_array(PlacementScript.PURCHASABLE_VEHICLES)
	for uid: String in all_buyable:
		var cb := CheckBox.new()
		cb.text = uid.capitalize()
		cb.add_theme_font_size_override("font_size", 11)
		cb.button_pressed = s.unit_allowed(uid)
		var u := uid
		cb.toggled.connect(func(on: bool) -> void:
			# Первое снятие галочки заводит явный список (иначе пусто = «всё можно»).
			if s.allowed_units.is_empty():
				for x: String in all_buyable:
					s.allowed_units[x] = true
			s.allowed_units[u] = on)
		body.add_child(cb)

## Окно выбора пула случайных событий (item 3).
func _open_events_window() -> void:
	var body := _modal_window("Random Events Pool")
	var hint := Label.new()
	hint.text = "Only checked events can occur."
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.75, 0.78, 0.85)
	body.add_child(hint)
	for pair in RandomEvents.REGISTRY:
		var ev_id: String = pair[0]
		var cb := CheckBox.new()
		cb.text = str(pair[1])
		cb.button_pressed = bool(_event_pool.get(ev_id, false))
		var eid := ev_id
		cb.toggled.connect(func(on: bool) -> void: _event_pool[eid] = on)
		body.add_child(cb)

## Общее модальное окно в стиле игры: затемнение + рамка SteamChrome + кнопка «Close».
## Возвращает VBox для содержимого. Клиенту окна тоже открываются, но правки не едут по
## сети — это конфиг хоста, и клиент их не касается (кнопки открытия у него отключены).
func _modal_window(title: String) -> VBoxContainer:
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
	var close := Button.new()
	close.text = "✕"
	close.pressed.connect(func() -> void: layer.queue_free())
	frame.add_child(SteamChrome.header_bar(title, close))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(SteamChrome.pad(scroll, 12, 10))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	Ui.theme_canvas_layers()
	return body

func _kind_index(s: Roster.Slot) -> int:
	match s.kind:
		Roster.SlotKind.OPEN: return 0
		Roster.SlotKind.CLOSED: return 1
		Roster.SlotKind.HUMAN: return 2
		Roster.SlotKind.AI: return 3 + clampi(s.ai_difficulty, 0, 2)
	return 0

func _on_add_slot() -> void:
	# Потолок — MCF.MAX_PLAYERS; отдельного «Max Players» больше нет (item 4).
	if roster.slots.size() >= MCF.MAX_PLAYERS:
		_status.text = "That's the maximum number of players."
		return
	var id := roster.add_slot(Roster.SlotKind.OPEN)
	if id >= 0:
		_assign_color(id, _first_free_color())  # уникальный цвет новому слоту (item 6)
		roster.slots[id].budget = GameConfig.DEFAULT_BUDGET  # личный бюджет (item 1)
	_refresh_slots()

func _on_remove_slot(slot_id: int) -> void:
	roster.remove_slot(slot_id)
	_refresh_slots()

## Первый ещё не занятый цвет палитры — чтобы новые слоты не дублировали цвета (item 6).
func _first_free_color() -> int:
	for i in Roster.PALETTE.size():
		var taken := false
		for s: Roster.Slot in roster.slots:
			if s.color_index() == i:
				taken = true
				break
		if not taken:
			return i
	return 0

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

func _on_slot_zone(value: float, slot_id: int) -> void:
	# 0 → «своя зона по номеру» (deploy_zone = -1); N → Zone N (индекс N-1).
	(roster.slots[slot_id] as Roster.Slot).deploy_zone = int(value) - 1

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
	# Лобби — единственный путь создания партии (item 20): расстановка всегда свободная.
	GameConfig.free_placement = true
	GameConfig.placement_mode = _place_opt.selected
	GameConfig.fog_mode = _fog_opt.selected
	GameConfig.army_select_mode = _army_opt.selected
	GameConfig.game_mode = GAME_MODES[clampi(_mode_opt.selected, 0, GAME_MODES.size() - 1)]
	GameConfig.live_placement_visible = _live_check.button_pressed
	GameConfig.civilians_enabled = not _no_neutrals_check.button_pressed  # item 2
	GameConfig.random_events_enabled = _events_check.button_pressed
	GameConfig.random_events_mandatory = _events_mand.button_pressed
	GameConfig.random_events_interval = int(_events_interval.value)
	# Пул событий из окна (item 3/5): вес 1 у выбранных, 0 у прочих.
	var weights: Dictionary = {}
	for ev_id: String in _event_pool:
		weights[ev_id] = 1.0 if bool(_event_pool[ev_id]) else 0.0
	GameConfig.random_events_weights = weights
	# Общее ограничение состава больше не задаётся глобально — оно ПЕРСОНАЛЬНО у слотов
	# (item 2). Глобальный список чистим, чтобы старое значение не перебивало личные.
	GameConfig.allowed_units = {}
	GameConfig.friendly_fire = _team_mode and _ff_check.button_pressed
	GameConfig.map_path = _map_paths[_map_opt.selected]
	GameConfig.roster = roster

## Старт с загруженной партии: ростер лобби подменяет сохранённый прямо в словаре
## файла — ровно та «правка одного словаря», ради которой ростер и отделён от
## владельцев юнитов. Расстановка пропускается: армии уже на доске.
func _start_loaded() -> void:
	_commit_config()
	var saved: Dictionary = _save.get("state", {})
	saved["roster"] = roster.to_dict()
	_save["state"] = saved
	if NetHandoff.session != null and NetHandoff.is_host:
		NetHandoff.session.send(NetHandoff.encode_load(_save))
	SaveHandoff.pending_save = _save
	MapHandoff.pending = null
	get_tree().change_scene_to_file(MAIN_SCENE)

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
	if not _save.is_empty():
		_start_loaded()
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
