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

## Строка «Random map» в списке карт: пути к файлу у неё нет, карту строит MapGen.
const RANDOM_MAP := "<random>"

## Ширины колонок таблицы слотов (item 4): один и тот же набор у заголовков и у строк,
## чтобы «Type/Color/Zone/Points» стояли ровно над своими контролами, а не сбоку.
const SLOT_COL_IDX := 26
const SLOT_COL_TYPE := 124
const SLOT_COL_WHO := 96
const SLOT_COL_COLOR := 168
# SpinBox'ы имеют собственный минимум ширины ~86px (стрелки + текст). Колонка «Team»
# была уже него (64) — контрол распирал её, и все следующие столбцы (Zone/Points)
# уезжали вправо от своих заголовков (item 1). Даём запас под реальный минимум.
const SLOT_COL_TEAM := 72
const SLOT_COL_ZONE := 100
const SLOT_COL_PTS := 112

var _ui: CanvasLayer
var roster: Roster
var _is_client := false   # мы подключившийся гость (не хост)

# Ссылки на управляющие элементы хоста.
var _place_opt: OptionButton
var _fog_opt: OptionButton
var _army_opt: OptionButton
var _ff_check: CheckBox
## «Disable neutrals» (item 2): инверсия GameConfig.civilians_enabled.
## Чат лобби (item 14).
var _chat: ChatBox = null
## Сколько мирных самое большее (item 11) и темп ИИ (item 5).
var _civ_slider: HSlider = null  # только у хоста, в настройках случайной карты
var _civ_check: CheckBox
var _ai_speed_opt: OptionButton
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
var _preview_portrait: TextureRect  # портрет фракции поверх квадрата (batch 17, item 13)
var _status: Label

var _map_paths: Array[String] = []
## Карта хоста у гостя (batch 12 #8): своего списка карт у него нет — только превью.
var _client_map: MapData = null

# --- Случайная карта ---
## Настройки генератора видны, только пока в списке выбрана «Random map».
var _gen_box: VBoxContainer
var _gen_players: SpinBox
var _gen_units: SpinBox
var _gen_style: OptionButton
var _gen_size: OptionButton
var _gen_density: OptionButton
## Свой размер (пункт «Custom» в списке размеров): строка видна только при нём.
var _gen_dims_row: HBoxContainer
var _gen_w: SpinBox
var _gen_h: SpinBox
var _gen_sym: CheckBox
## Большую карту пересобираем, когда щелчки по настройкам стихнут, а не на каждый.
var _gen_timer: Timer
var _gen_space: CheckBox
var _gen_fire: CheckBox
var _gen_obstacles: CheckBox
var _gen_seed: SpinBox
var _gen_info: Label
## Собранная карта и настройки, из которых она собрана: пока они те же — не пересобираем.
var _gen_map: MapData = null
var _gen_key := ""
var _color_opt: OptionButton

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
## Гость уже попросил хоста повторить объявление матча (batch 13 #11) — один раз.
var _setup_requested: bool = false

func _ready() -> void:
	_is_client = NetHandoff.session != null and not NetHandoff.is_host
	_is_host_net = NetHandoff.session != null and NetHandoff.is_host
	_is_solo = NetHandoff.session == null
	roster = _seed_roster()
	_build_ui()
	_refresh_slots()
	_refresh_map_preview()
	if _is_solo and LearnedController.available():
		_status.text = "Opponent: AI - Learned — %s" % LearnedController.model_label()
	# Гость (item 61) сидит в лобби и ждёт, когда хост объявит условия матча (K_SETUP);
	# по ним он и уходит на закупку. До того он может трогать только свой цвет.
	if _is_client and NetHandoff.session != null:
		NetHandoff.session.message.connect(_on_client_message)
		NetHandoff.session.disconnected.connect(_on_client_lost)
		NetHandoff.session.attach()
		_status.text = "Connected — waiting for the host's lobby…"
		# Просим хоста прислать лобби ещё раз (batch 14): снимок, ушедший до того, как
		# гость открыл этот экран, мог потеряться при быстром переподключении, и гость
		# сидел бы «в ожидании» вечно. Хост усадит нас (если ещё не усадил) и вышлет всё.
		NetHandoff.session.send({"k": NetHandoff.K_LOBBY_REQ, "op": "hello"})
	# Сетевой хост открыл лобби сразу (item 10): ждём подключения, продолжая объявлять
	# партию в LAN. Гости получают снимок лобби на каждое изменение (batch 12 #8).
	if _is_host_net:
		var ses := NetHandoff.session
		ses.peer_joined.connect(_on_host_peer_joined)
		ses.peer_left.connect(_on_host_peer_left)
		ses.message.connect(_on_host_message)
		ses.attach()
		# Гости, успевшие подключиться до открытия лобби, слот ещё не получили.
		for id: int in ses.peers:
			_seat_peer(id)
		_refresh_host_status()
		_lobby_changed()
		_send_lobby_map()
		_lan_adv = LanDiscovery.new()
		get_tree().root.add_child.call_deferred(_lan_adv)
		_lan_adv.start_advertising.call_deferred({
			"name": "MCF Tactics", "players": 1, "port": NetworkSession.DEFAULT_PORT})

# --- Хост: рассадка гостей и рассылка снимка (batch 12 #8) --------------------------
func _on_host_peer_joined(id: int) -> void:
	_seat_peer(id)
	_refresh_host_status()
	_lobby_changed()
	# Новому гостю нужна ещё и карта — снимок несёт только её имя.
	_send_lobby_map()

## Ушедшего гостя подменяет ИИ высокой сложности (batch 13 #2): партия остаётся
## готовой к старту, а его место — занятым. Хост волен переключить слот обратно.
func _on_host_peer_left(id: int) -> void:
	var side := roster.side_of_peer(id)
	if side >= 0:
		var s: Roster.Slot = roster.slots[side]
		s.kind = Roster.SlotKind.AI
		s.ai_difficulty = AIController.Difficulty.HARD
		s.peer_id = -1
		s.display_name = MCF.owner_name(side)
		_status.text = "%s left — a Hard AI takes that slot." % s.display_name
	_refresh_host_status()
	_lobby_changed()

## Посадить пришедшего в первый открытый слот; если открытых нет — добавить новый.
## Слот меняется на «Player» с буквой стороны, и это видят все (batch 12 #8).
func _seat_peer(id: int) -> void:
	if roster.side_of_peer(id) >= 0:
		return
	var target: Roster.Slot = null
	# Слот, который хост уже выставил в «Player», но за которым никто не сидит, — это
	# место, приготовленное для друга (batch 13 #11): гость садится ТУДА, а не в новый
	# слот. Раньше такой слот оставался пустым, «Start Match» отказывал («nobody has
	# joined it»), и партия не начиналась вовсе.
	for s: Roster.Slot in roster.slots:
		if s.kind == Roster.SlotKind.HUMAN and s.peer_id < 0:
			target = s
			break
	if target == null:
		for s: Roster.Slot in roster.slots:
			if s.kind == Roster.SlotKind.OPEN:
				target = s
				break
	if target == null:
		var nid := roster.add_slot(Roster.SlotKind.OPEN)
		if nid < 0:
			return  # мест нет — гость останется зрителем лобби
		_assign_color(nid, _first_free_color())
		roster.slots[nid].budget = GameConfig.DEFAULT_BUDGET
		target = roster.slots[nid]
	target.kind = Roster.SlotKind.HUMAN
	target.peer_id = id
	target.display_name = MCF.owner_name(target.id)

func _refresh_host_status() -> void:
	if _status == null or NetHandoff.session == null:
		return
	var n := NetHandoff.session.peers.size()
	if n == 0:
		_status.text = "Hosting — waiting for players to join. You can also add AI slots and start now."
	else:
		_status.text = "Hosting — %d player%s connected. Start when everyone is seated." % [
			n, "" if n == 1 else "s"]

## Любое изменение лобби у хоста: перерисовать и разослать гостям.
func _lobby_changed() -> void:
	# Случайная карта держит по зоне на слот: слот добавили или убрали — карта
	# пересобирается (тем же зерном), и гостям уезжает новая.
	var regen := _is_random() and _gen_key != str(_gen_options())
	_refresh_slots()  # пересоберёт карту и превью сам — через _selected_map()
	_broadcast_lobby()
	if regen:
		_send_lobby_map()

func _broadcast_lobby() -> void:
	if not _is_host_net or NetHandoff.session == null:
		return
	_commit_config()
	NetHandoff.session.send({"k": NetHandoff.K_LOBBY, "r": NetHandoff.encode_rules(),
		"map": _map_opt.get_item_text(_map_opt.selected) if _map_opt != null else ""})

## Карта едет отдельно и только когда меняется: словарь карты велик, а снимок лобби
## летит на каждый щелчок.
func _send_lobby_map() -> void:
	if not _is_host_net or NetHandoff.session == null:
		return
	NetHandoff.session.send({"k": NetHandoff.K_LOBBY_MAP, "m": _selected_map().to_dict()})

## Просьбы гостей (batch 12 #8): цвет и пересадка в открытый слот. Решает хост.
func _on_host_message(msg: Dictionary) -> void:
	if _chat != null and _chat.receive(msg):
		return
	if str(msg.get("k", "")) != NetHandoff.K_LOBBY_REQ:
		return
	var from := int(msg.get("_from", -1))
	if str(msg.get("op", "")) == "hello":
		# Гость открыл лобби (batch 14): усадить, если ещё не усажен, и выслать всё заново.
		_seat_peer(from)
		_refresh_host_status()
		_lobby_changed()
		_send_lobby_map()
		return
	var side := roster.side_of_peer(from)
	if side < 0:
		return
	match str(msg.get("op", "")):
		"color":
			_assign_color(side, int(msg.get("c", 0)))
		"slot":
			var want := int(msg.get("s", -1))
			if want >= 0 and want < roster.slots.size() and want != side:
				var dst: Roster.Slot = roster.slots[want]
				var src: Roster.Slot = roster.slots[side]
				if dst.kind == Roster.SlotKind.OPEN:
					dst.kind = Roster.SlotKind.HUMAN
					dst.peer_id = from
					dst.display_name = MCF.owner_name(dst.id)
					# Цвет переезжает вместе с игроком — он его выбирал.
					var keep := src.color
					src.kind = Roster.SlotKind.OPEN
					src.peer_id = -1
					src.display_name = MCF.owner_name(src.id)
					src.color = dst.color
					dst.color = keep
	_lobby_changed()

# --- Гость: снимок лобби от хоста (batch 12 #8) -------------------------------------
func _apply_lobby_snapshot(msg: Dictionary) -> void:
	var rules: Variant = msg.get("r", {})
	if not (rules is Dictionary):
		return
	NetHandoff.apply_rules(rules)
	roster = GameConfig.active_roster()
	_team_mode = _roster_has_teams()
	if _place_opt != null:
		_place_opt.select(clampi(GameConfig.placement_mode, 0, 1))
		_fog_opt.select(clampi(GameConfig.fog_mode, 0, 2))
		_army_opt.select(clampi(GameConfig.army_select_mode, 0, 1))
		_team_check.set_pressed_no_signal(_team_mode)
		_ff_check.button_pressed = GameConfig.friendly_fire
		_ff_check.visible = _team_mode
		_live_check.button_pressed = GameConfig.live_placement_visible
		_civ_check.set_pressed_no_signal(GameConfig.civilian_count > 0)
		_ai_speed_opt.select(maxi(0, GameConfig.AI_SPEEDS.find(GameConfig.ai_speed)))
		_events_check.button_pressed = GameConfig.random_events_enabled
		_events_mand.button_pressed = GameConfig.random_events_mandatory
		_events_interval.value = GameConfig.random_events_interval
		for ev_id in _event_pool:
			_event_pool[ev_id] = float(GameConfig.random_events_weights.get(ev_id, 0.0)) > 0.0
	if _map_opt != null:
		var map_name := str(msg.get("map", ""))
		_map_opt.clear()
		_map_opt.add_item(map_name if map_name != "" else "(host's map)")
		_map_opt.select(0)
	_refresh_slots()
	var mine := _my_slot()
	if mine != null:
		if _color_opt != null:
			_color_opt.select(mine.color_index())
		_refresh_swatch()
		_status.text = "You are %s — waiting for the host to start the match." % mine.display_name
	else:
		_status.text = "Connected — no free slot yet. The host can add one."

## Карта хоста для превью (batch 12 #8).
func _apply_lobby_map(msg: Dictionary) -> void:
	var m: Variant = msg.get("m", {})
	if not (m is Dictionary):
		return
	_client_map = MapData.from_dict(m)
	_refresh_map_preview()
	_refresh_slots()

func _exit_tree() -> void:
	if _lan_adv != null:
		_lan_adv.stop()
		_lan_adv.queue_free()
		_lan_adv = null

func _on_client_message(msg: Dictionary) -> void:
	if _chat != null and _chat.receive(msg):
		return
	match str(msg.get("k", "")):
		NetHandoff.K_LOBBY:
			_apply_lobby_snapshot(msg)
			return
		NetHandoff.K_LOBBY_MAP:
			_apply_lobby_map(msg)
			return
	# Хост уже на закупке, а объявление матча до нас не дошло (batch 13 #11): о фазе
	# говорят пакеты расстановки. Просим хоста повторить K_SETUP, вместо того чтобы
	# сидеть в лобби до скончания века.
	if str(msg.get("k", "")) in [PlacementScript.K_LIVE_REQ, PlacementScript.K_LIVE,
			PlacementScript.K_ROSTER]:
		if not _setup_requested and NetHandoff.session != null:
			_setup_requested = true
			_status.text = "The host has started — catching up…"
			NetHandoff.session.send({"k": NetHandoff.K_SETUP_REQ})
		return
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
		# Игру запустили с обученной моделью («Play vs latest» на панели RL) — ею и играем.
		# По умолчанию здесь стоит скриптовый ИИ, и сервер политики простаивал, пока слот не
		# переключали руками: «играть против последней версии» на деле не получалось.
		if LearnedController.available():
			r.slots[1].ai_difficulty = AIController.Difficulty.LEARNED
	else:
		r.add_slot(Roster.SlotKind.OPEN)
	# Стартовый личный бюджет у каждого слота — общий по умолчанию (item 1).
	for s: Roster.Slot in r.slots:
		s.budget = GameConfig.DEFAULT_BUDGET
	# Слот хоста помечен его сетевым номером (у сервера он всегда 1): по нему и гости,
	# и бой узнают, чей это слот (batch 12 #8).
	if _is_host_net:
		r.slots[0].peer_id = 1
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
	# Отступы на всю ширину окна: иначе колонкам доставалась лишь их минимальная ширина,
	# и они переносились друг под друга даже на 100% (item 23).

	# Колонки переносятся: не хватает ширины (крупный интерфейс, item 17, или узкое окно) —
	# правая встаёт под левую, а не уезжает за край экрана (item 23).
	var cols := HFlowContainer.new()
	cols.add_theme_constant_override("h_separation", 14)
	cols.add_theme_constant_override("v_separation", 18)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cols_pad := SteamChrome.pad(cols, 14, 12)
	cols_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(cols_pad)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 18)
	# Настройки — по своей ширине, остальное отдаём таблице слотов и превью.
	left.size_flags_horizontal = Control.SIZE_FILL
	cols.add_child(left)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 18)
	right.custom_minimum_size = Vector2(560, 0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)

	_build_config(left)
	if not _is_client:
		_build_load(left)
	# Чат лобби (item 14) — только когда за столом есть кто-то по сети.
	if NetHandoff.session != null:
		_chat = ChatBox.new(_chat_label, func() -> int:
			var mine := _my_slot()
			return mine.id if mine != null else -1)
		_titled(left, "Chat").add_child(_chat)
	_build_slots(right)
	_build_personal(right)
	# Карта — справа, под слотами: там есть ширина, чтобы поставить превью рядом с
	# настройками случайной карты, и «Players» там же, где список слотов.
	_build_map(right)

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

## Раздел лобби — групповое окошко набора интерфейса (item 23): рамка с подписью на
## верхней кромке. Возвращает тело, куда кладутся строки раздела.
func _titled(parent: VBoxContainer, title: String) -> VBoxContainer:
	var g := SteamChrome.group_box(title)
	parent.add_child(g)
	return g.body

func _row(box: VBoxContainer, label_text: String, control: Control) -> HBoxContainer:
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
	return r

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
	# Мирные (item 11): ползунок «не больше N» вместо прежнего «Disable neutrals» и
	# уровня мирных у случайной карты. 0 — без мирных; готовая карта прореживается до N,
	# случайная столько и строит.
	# Число мирных у случайной карты — ползунок в её настройках (_build_generator); здесь
	# только «есть ли мирные вообще», и для готовых карт этого достаточно.
	_civ_check = CheckBox.new()
	_civ_check.text = "Civilians"
	_civ_check.tooltip_text = "Neutral civilians on the map. Untick to play without them. Random maps set how many in their own settings."
	_civ_check.button_pressed = GameConfig.civilian_count > 0
	_civ_check.toggled.connect(func(_on: bool) -> void:
		if _is_random():
			_on_gen_changed())
	box.add_child(_civ_check)
	# Темп ИИ (item 5): во сколько раз быстрее ходят и показываются ходы ИИ. В бою его же
	# меняет хост ползунком на панели.
	var speeds: Array = []
	for sp: float in GameConfig.AI_SPEEDS:
		speeds.append(GameConfig.ai_speed_label(sp))
	_ai_speed_opt = _opt(speeds, maxi(0, GameConfig.AI_SPEEDS.find(GameConfig.ai_speed)))
	_ai_speed_opt.tooltip_text = "How fast AI sides play their turns. The host can also change it during the battle."
	_row(box, "AI speed:", _ai_speed_opt)

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

	# Хост: любой щелчок по правилам сразу уезжает гостям (batch 12 #8/#9/#10).
	if _is_host_net:
		for o: OptionButton in [_place_opt, _fog_opt, _army_opt]:
			o.item_selected.connect(func(_i: int) -> void: _broadcast_lobby())
		_ai_speed_opt.item_selected.connect(func(_i: int) -> void: _broadcast_lobby())
		if _civ_slider != null:
			_civ_slider.value_changed.connect(func(_v: float) -> void: _broadcast_lobby())
		for cb: CheckBox in [_ff_check, _team_check, _live_check, _civ_check,
				_events_check, _events_mand]:
			cb.toggled.connect(func(_on: bool) -> void: _broadcast_lobby())
		_events_interval.value_changed.connect(func(_v: float) -> void: _broadcast_lobby())

	if _is_client:
		var _client_locked: Array = [_place_opt, _fog_opt, _army_opt,
				_ff_check, _team_check, _live_check, _civ_check, _ai_speed_opt, _events_check,
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

## Строка «подпись — ползунок — число» (как slider-row в наборе интерфейса). fmt — как
## показать значение в окошке справа.
func _slider_row(box: VBoxContainer, label_text: String, lo: float, hi: float, step: float,
		value: float, fmt: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(140, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Окошко значения — с вводом числа с клавиатуры.
	var val := Ui.slider_entry(s, fmt)
	val.custom_minimum_size = Vector2(56, 0)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	hb.add_child(s)
	hb.add_child(val)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row(box, label_text, hb)
	return s

## Подпись в чате лобби: имя слота, своё — с «(you)», хост — с «(host)».
func _chat_label(side: int) -> String:
	if roster == null or side < 0 or side >= roster.slots.size():
		return "Guest"
	var s: Roster.Slot = roster.slots[side]
	var name := s.display_name
	if s.peer_id == 1:
		name += " (host)"
	var mine := _my_slot()
	if mine != null and mine.id == side:
		name += " (you)"
	return name

func _opt(items: Array, selected: int) -> OptionButton:
	var o := OptionButton.new()
	for i in items.size():
		o.add_item(str(items[i]), i)
	o.select(clampi(selected, 0, items.size() - 1))
	return o

func _build_map(parent: VBoxContainer) -> void:
	var titled := _titled(parent, "Map Selection & Preview")
	# Настройки слева, превью справа: крутишь ручки случайной карты — и видишь, что
	# вышло, не пролистывая лобби вниз.
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 12)
	titled.add_child(split)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(box)
	_map_opt = OptionButton.new()
	_reload_map_items()
	# Смена карты обновляет и превью, и слоты — у зон свой предел от карты (item 6).
	_map_opt.item_selected.connect(func(_i: int) -> void:
		if _gen_box != null:
			_gen_box.visible = _is_random()
		_refresh_map_preview()
		_refresh_slots()
		_broadcast_lobby()
		_send_lobby_map())
	if _is_client:
		_map_opt.disabled = true
	# Список читается один раз при входе в лобби, а карту могли нарисовать и положить
	# рядом только что (issue 1) — кнопка перечитывает каталоги, не выходя из лобби.
	var refresh := Button.new()
	refresh.text = "⟳"
	refresh.tooltip_text = "Rescan the map folders"
	refresh.custom_minimum_size = Vector2(34, 0)
	refresh.pressed.connect(func() -> void:
		_map_cache = null  # файл могли перезаписать в редакторе — перечитать
		_reload_map_items()
		_refresh_map_preview()
		_refresh_slots())
	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 6)
	_map_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_row.add_child(_map_opt)
	map_row.add_child(refresh)
	_row(box, "Map:", map_row)
	if not _is_client:
		_build_generator(box)

	_map_preview = TextureRect.new()
	_map_preview.custom_minimum_size = Vector2(360, 260)
	_map_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	split.add_child(_map_preview)
	# Номера зон развёртывания поверх превью (gore batch) — те же, что «Zone N» у слотов.
	_preview_labels = Control.new()
	_preview_labels.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_labels.draw.connect(_draw_zone_numbers)
	_map_preview.add_child(_preview_labels)
	_map_preview.resized.connect(_preview_labels.queue_redraw)

## Перечитать каталоги карт и пересобрать выпадающий список (item 1, issue 1).
##
## ВСЕ сохранённые карты: и поставочные (res://maps), и созданные в редакторе
## (user://maps). MapData.list_maps() объединяет оба каталога без дублей.
## Выбранная карта сохраняется по ПУТИ, а не по номеру строки: после пересканирования
## список мог сдвинуться, и номер указывал бы на чужую карту.
func _reload_map_items() -> void:
	var keep := ""
	if _map_opt != null and _map_opt.selected >= 0 and _map_opt.selected < _map_paths.size():
		keep = _map_paths[_map_opt.selected]
	_map_opt.clear()
	_map_paths = []
	_map_opt.add_item("Blank arena")
	_map_paths.append("")
	_map_opt.add_item("Random map")
	_map_paths.append(RANDOM_MAP)
	for name in MapData.list_maps():
		_map_opt.add_item(name.get_basename())
		_map_paths.append(MapData.path_for(name))
	var idx := _map_paths.find(keep)
	_map_opt.select(idx if idx >= 0 else 0)

## Настройки случайной карты (строка «Random map»): стиль, размер, плотность, механики
## и зерно. Любая правка пересобирает карту, превью и рассылку гостям. То же зерно при
## тех же настройках всегда даёт ту же карту — удачную можно сохранить файлом, и дальше
## она живёт в списке карт и в редакторе.
func _build_generator(box: VBoxContainer) -> void:
	_gen_box = VBoxContainer.new()
	_gen_box.add_theme_constant_override("separation", 5)
	_gen_box.visible = _is_random()
	box.add_child(_gen_box)
	var defaults := MapGen.default_options()
	# Игроки — это слоты лобби (по зоне на каждого): спинбокс их добавляет и убирает.
	_gen_players = SpinBox.new()
	_gen_players.min_value = 2
	_gen_players.max_value = MCF.MAX_PLAYERS
	_gen_players.value = roster.slots.size()
	_gen_players.tooltip_text = "One deployment zone per player; this is the slot list above."
	_gen_players.value_changed.connect(func(v: float) -> void: _set_player_count(int(v)))
	_gen_units = SpinBox.new()
	_gen_units.min_value = 1
	_gen_units.max_value = 300
	_gen_units.value = int(defaults["units"])
	_gen_units.tooltip_text = "How many units each side deploys: every zone is made big enough for them, and the map grows if it has to."
	_gen_units.value_changed.connect(func(_v: float) -> void: _on_gen_changed())
	var units_label := Label.new()
	units_label.text = "Units per side:"
	units_label.add_theme_font_size_override("font_size", 12)
	var army := HBoxContainer.new()
	army.add_theme_constant_override("separation", 8)
	for c: Control in [_gen_players, units_label, _gen_units]:
		army.add_child(c)
	_gen_players.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gen_units.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row(_gen_box, "Players:", army)
	# Стиль, размер и плотность — одной строкой: панель короче, превью рядом видно целиком.
	_gen_style = _opt(MapGen.STYLE_NAMES, int(defaults["style"]))
	_gen_style.tooltip_text = "Station: rooms and hallways in space. Town: streets and houses. Field: open ground and ruins. Bunker: the same rooms and hallways as a station, dug into solid rock underground. Asteroid: a town on a little rock island floating in space (Density sets how built-up it is)."
	var sizes: Array = []
	for i in MapGen.SIZES.size():
		var d: Vector2i = MapGen.SIZES[i]
		sizes.append("%s (%d×%d)" % [MapGen.SIZE_NAMES[i], d.x, d.y])
	sizes.append("Custom…")
	_gen_size = _opt(sizes, int(defaults["size"]))
	_gen_size.tooltip_text = "Starting size — the map grows if the armies don't fit. Custom: any width and height, no upper limit."
	_gen_density = _opt(MapGen.DENSITY_NAMES, int(defaults["density"]))
	_gen_density.tooltip_text = "How built-up and cluttered the map is."
	var look := HBoxContainer.new()
	look.add_theme_constant_override("separation", 6)
	for o: OptionButton in [_gen_style, _gen_size, _gen_density]:
		o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		look.add_child(o)
	_row(_gen_box, "Terrain:", look)
	# Свой размер: ширина × высота, до MapGen.MAX_DIM. Видно только при «Custom…».
	_gen_w = _dim_spin(int(defaults["width"]))
	_gen_h = _dim_spin(int(defaults["height"]))
	var by := Label.new()
	by.text = "×"
	var dims := HBoxContainer.new()
	dims.add_theme_constant_override("separation", 6)
	for c: Control in [_gen_w, by, _gen_h]:
		dims.add_child(c)
	_gen_w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gen_h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gen_dims_row = _row(_gen_box, "Custom size:", dims)
	_gen_dims_row.visible = false
	_gen_sym = CheckBox.new()
	_gen_sym.text = "Symmetrical"
	_gen_sym.tooltip_text = "Mirror the map so every side gets the same ground. Four quarters for 4 or 8 players, left and right otherwise — with an odd number, one zone sits on the middle line."
	_gen_sym.toggled.connect(func(_on: bool) -> void: _on_gen_changed())
	_row(_gen_box, "Layout:", _gen_sym)
	var mech := HFlowContainer.new()
	mech.add_theme_constant_override("h_separation", 10)
	_gen_space = _gen_check(mech, "Space",
			"Vacuum you can fight in (zero-G): vented rooms and hull windows on stations, a ragged edge and holes in towns and fields. A bunker is underground and never has vacuum. Every door is an airlock either way.")
	_gen_fire = _gen_check(mech, "Flammable",
			"Grass, plank floors, wooden walls and fences — ground that fire spreads over.")
	_gen_obstacles = _gen_check(mech, "Obstacles",
			"Sandbags, trenches, hedgehogs, barricades, crates and pillars.")
	_row(_gen_box, "Mechanics:", mech)
	# Мирные случайной карты: точное число, до 1000 (готовые карты — галочка «Civilians»).
	var civ0 := GameConfig.civilian_count
	if civ0 < 0 or civ0 >= GameConfig.CIVILIANS_MAX:
		civ0 = GameConfig.CIVILIANS_DEFAULT
	_civ_slider = _slider_row(_gen_box, "Civilians:", 0, GameConfig.CIVILIANS_MAX, 1, civ0,
			func(v: float) -> String: return str(int(v)))
	_civ_slider.tooltip_text = "How many neutral civilians to build, when there is room. They live in rooms sealed by airlocks and start asleep. Untick \"Civilians\" above for none."
	_civ_slider.value_changed.connect(func(_v: float) -> void: _on_gen_changed())
	# Умолчания стиля (items 25/26): город, поле и бункер — без космоса, бункер и станция —
	# негорючие, астероид — в космосе и не горит. Выставляются при выборе стиля, дальше
	# игрок волен переключить. Подключено РАНЬШЕ пересборки карты по смене стиля.
	_apply_style_defaults(_gen_style.selected)
	_gen_style.item_selected.connect(_apply_style_defaults)
	_gen_seed = SpinBox.new()
	_gen_seed.max_value = MapGen.SEED_MAX
	_gen_seed.value = randi_range(1, MapGen.SEED_MAX)
	_gen_seed.tooltip_text = "The same seed and settings always build the same map."
	var reroll := Button.new()
	reroll.text = "Reroll"
	reroll.pressed.connect(func() -> void: _gen_seed.value = randi_range(1, MapGen.SEED_MAX))
	var save := Button.new()
	save.text = "Save as Map"
	save.tooltip_text = "Keep this map: it joins the map list and opens in the editor."
	save.pressed.connect(_save_random_map)
	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 6)
	_gen_seed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_gen_seed)
	seed_row.add_child(reroll)
	seed_row.add_child(save)
	_row(_gen_box, "Seed:", seed_row)
	_gen_info = Label.new()
	_gen_info.add_theme_font_size_override("font_size", 12)
	_gen_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gen_box.add_child(_gen_info)
	for o: OptionButton in [_gen_style, _gen_size, _gen_density]:
		o.item_selected.connect(func(_i: int) -> void: _on_gen_changed())
	_gen_seed.value_changed.connect(func(_v: float) -> void: _on_gen_changed())
	for sp: SpinBox in [_gen_w, _gen_h]:
		sp.value_changed.connect(func(_v: float) -> void: _on_gen_changed())
	_gen_timer = Timer.new()
	_gen_timer.one_shot = true
	_gen_timer.wait_time = 0.3
	_gen_timer.timeout.connect(_apply_gen_change)
	_gen_box.add_child(_gen_timer)

## Своя ширина/высота: снизу MapGen.MIN_DIM, сверху — ничего. Стрелки ходят до 1000, но
## ввести можно и больше (allow_greater).
func _dim_spin(value: int) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = MapGen.MIN_DIM
	sp.max_value = 1000
	sp.allow_greater = true
	sp.value = value
	sp.tooltip_text = "Cells, at least %d — no upper limit. Very large maps take longer to build." % MapGen.MIN_DIM
	return sp

func _apply_style_defaults(style: int) -> void:
	if style < 0 or style >= MapGen.STYLE_SPACE.size():
		return
	_gen_space.set_pressed_no_signal(MapGen.STYLE_SPACE[style])
	_gen_fire.set_pressed_no_signal(MapGen.STYLE_FLAMMABLE[style])

func _gen_check(parent: Control, text: String, tip: String) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.tooltip_text = tip
	cb.button_pressed = true
	cb.toggled.connect(func(_on: bool) -> void: _on_gen_changed())
	parent.add_child(cb)
	return cb

func _is_random() -> bool:
	return not _is_client and _map_opt != null and _map_opt.selected >= 0 \
			and _map_opt.selected < _map_paths.size() \
			and _map_paths[_map_opt.selected] == RANDOM_MAP

## Настройки генератора из контролов. Зон — по одной на слот: слот без своей зоны
## (Slot.zone() == его номер) не смог бы расставиться.
func _gen_options() -> Dictionary:
	if _gen_style == null:
		return {}
	return {"style": _gen_style.selected, "size": _gen_size.selected,
			"density": _gen_density.selected, "seed": int(_gen_seed.value),
			"zones": maxi(2, roster.slots.size()), "units": int(_gen_units.value),
			"width": int(_gen_w.value), "height": int(_gen_h.value),
			"symmetric": _gen_sym.button_pressed,
			"space": _gen_space.button_pressed,
			"flammable": _gen_fire.button_pressed, "obstacles": _gen_obstacles.button_pressed,
			"civilian_count": _civ_count()}

## Сколько мирных в партии: ноль без галочки, число ползунка у случайной карты, иначе все,
## что есть на готовой карте.
func _civ_count() -> int:
	if not _civ_check.button_pressed:
		return 0
	if _civ_slider != null and _is_random():
		return int(_civ_slider.value)
	return GameConfig.CIVILIANS_MAX

func _random_map() -> MapData:
	var options := _gen_options()
	var key := str(options)
	if _gen_map == null or key != _gen_key:
		_gen_map = MapGen.generate(options)
		_gen_key = key
		_gen_info.text = _zone_summary(_gen_map)
	return _gen_map

## Сколько места у каждой стороны. Зоны случайной карты одного размера — его и пишем,
## а если тесно, подсказываем карту побольше.
func _zone_summary(map: MapData) -> String:
	var sizes := {}
	for z in map.zone_owner:
		if z >= 0:
			sizes[z] = int(sizes.get(z, 0)) + 1
	if sizes.is_empty():
		return "No room for deployment zones — try fewer players."
	var o := _gen_options()
	var units := int(o["units"])
	var cells: int = sizes.values().min()
	var text := "%d deployment zones, %d cells each" % [sizes.size(), cells]
	if cells < MapGen.zone_need(units):
		return text + " — too tight for %d units each even at %d×%d; fewer players or units will fit." % [
				units, map.width, map.height]
	text += " — room for %d units each." % units
	var dim := MapGen.dims_of(o)
	if map.width > dim.x or map.height > dim.y:
		text += " Map enlarged to %d×%d so they fit." % [map.width, map.height]
	# Своему размеру потолка нет (MapGen.dims_of) — зато есть цена: замер 500×500 — ~3 с на
	# постройку и ~0,4 ГБ памяти в бою, 1000×1000 — ~15 с и ~1,3 ГБ.
	if map.width * map.height > MapGen.MAX_DIM.x * MapGen.MAX_DIM.y:
		text += " Beyond 250×250 building takes seconds (≈15 s at 1000×1000) and a battle needs a lot of memory (≈1.3 GB at 1000×1000)."
	return text

## «Players» случайной карты: слотов становится ровно столько. Новые — в одиночке ИИ
## (партия сразу готова к старту), в сети — открытые под гостей; лишние снимаются с
## конца, но слот, где сидит гость, не трогаем — как и крестик в списке слотов.
func _set_player_count(n: int) -> void:
	while roster.slots.size() < n:
		var id := roster.add_slot(Roster.SlotKind.AI if _is_solo else Roster.SlotKind.OPEN)
		if id < 0:
			break
		_assign_color(id, _first_free_color())
		roster.slots[id].budget = GameConfig.DEFAULT_BUDGET
	while roster.slots.size() > n:
		var last: Roster.Slot = roster.slots[roster.slots.size() - 1]
		if last.kind == Roster.SlotKind.HUMAN and last.peer_id > 1:
			_status.text = "%s is sitting in the last slot — it can't be removed." % last.display_name
			break
		roster.remove_slot(last.id)
		if roster.slots.has(last):
			break  # меньше двух слотов ростер не отдаёт
	_lobby_changed()

func _on_gen_changed() -> void:
	if _gen_dims_row != null:
		_gen_dims_row.visible = _gen_size.selected == MapGen.SIZE_CUSTOM
	# Карта до ~100×100 собирается за десятки миллисекунд — сразу. Большая (до 250×250)
	# — за полсекунды и дольше: ждём, пока щелчки по стрелкам затихнут, и строим один раз.
	# Чтение карты (_selected_map) ждать не станет — она пересобирается по требованию.
	var d := MapGen.dims_of(_gen_options())
	if d.x * d.y > 10000 and _gen_timer != null and _gen_timer.is_inside_tree():
		_gen_timer.start()
		return
	_apply_gen_change()

func _apply_gen_change() -> void:
	_refresh_slots()  # пересоберёт карту: число зон в слотах и превью — уже от новой
	_broadcast_lobby()
	_send_lobby_map()

## Сохранить случайную карту файлом в user://maps — дальше это обычная карта: она в
## списке и открывается в редакторе. Имя — стиль и зерно; чужой файл не перезаписываем.
func _save_random_map() -> void:
	var o := _gen_options()
	var base := "random-%s-%d" % [str(MapGen.STYLE_NAMES[int(o["style"])]).to_lower(),
			int(o["seed"])]
	var name := base
	var n := 2
	while FileAccess.file_exists("%s/%s.json" % [MapData.MAPS_DIR, name]):
		name = "%s-%d" % [base, n]
		n += 1
	if not _random_map().save_to("%s/%s.json" % [MapData.MAPS_DIR, name]):
		_status.text = "Could not save the map."
		return
	_reload_map_items()  # выбор хранится по пути — «Random map» остаётся выбранной
	_status.text = "Saved as '%s' — it's in the map list and the editor now." % name

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
	# Таблица слотов и «+ Add Slot» — внутри своего группового окошка (item 23).
	var box := _titled(parent, "Team Slots & Players")
	# Таблица шире колонки (крупный интерфейс, режим команд) — прокручивается вбок внутри
	# своего окошка, а не раздвигает всё лобби за край экрана (item 23).
	var table := ScrollContainer.new()
	table.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(table)
	_slots_box = VBoxContainer.new()
	_slots_box.add_theme_constant_override("separation", 4)
	_slots_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.add_child(_slots_box)
	if not _is_client:
		var add := Button.new()
		add.text = "+ Add Slot"
		add.pressed.connect(_on_add_slot)
		box.add_child(add)

func _build_personal(parent: VBoxContainer) -> void:
	var box := _titled(parent, "Personal Setup")
	var color_opt := OptionButton.new()
	for i in Roster.PALETTE.size():
		color_opt.add_item(Roster.color_name(i), i)  # имена цветов (item 3)
	color_opt.select(_my_slot().color_index() if _my_slot() != null else 0)
	color_opt.item_selected.connect(_on_my_color)
	_color_opt = color_opt
	_row(box, "Faction:", color_opt)
	_preview_swatch = ColorRect.new()
	_preview_swatch.custom_minimum_size = Vector2(64, 64)
	# Квадрат, а не полоса во всю ширину колонки (batch 14): VBox растягивал его.
	_preview_swatch.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# Портрет фракции (faction_<key>.png) поверх цветного квадрата; без картинки виден цвет.
	_preview_portrait = TextureRect.new()
	_preview_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_swatch.add_child(_preview_portrait)
	box.add_child(_preview_swatch)
	_refresh_swatch()
	var note := Label.new()
	note.text = "Your soldiers wear this faction's art (or its colour)."
	note.add_theme_font_size_override("font_size", 11)
	note.modulate = Color(0.75, 0.78, 0.85)
	box.add_child(note)

## Окно фракции (batch 17, item 13): цвет слота и, если лежит, портрет faction_<key>.png.
func _refresh_swatch() -> void:
	if _preview_swatch == null:
		return
	var mine := _my_slot()
	_preview_swatch.color = mine.color if mine != null else Color.WHITE
	if _preview_portrait != null:
		var key := Sprites.resolve("faction_" + Roster.faction_key(mine.color_index())) \
				if mine != null else ""
		_preview_portrait.texture = Sprites.texture_of(key) if key != "" else null

# --- Слоты -------------------------------------------------------------------
func _refresh_slots() -> void:
	if _slots_box == null:
		return
	# Строки пересобираются с нуля, а число, набранное в SpinBox, но не подтверждённое
	# Enter'ом или уходом фокуса, живёт только в его поле ввода (batch 13 #12): смена
	# цвета перестраивала таблицу, и набранные 500 очков молча возвращались к 300.
	# Сначала применяем всё набранное — apply() шлёт value_changed, и ростер узнаёт.
	for row in _slots_box.get_children():
		for c in row.get_children():
			if c is SpinBox:
				(c as SpinBox).apply()
	for c in _slots_box.get_children():
		c.queue_free()
	_slots_box.add_child(_slot_header())
	for s: Roster.Slot in roster.slots:
		_slots_box.add_child(_slot_row(s))
	if _gen_players != null:
		_gen_players.set_value_no_signal(roster.slots.size())
	# Зоны в превью окрашены цветами слотов — смена цвета или зоны видна сразу.
	_refresh_map_preview()

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
			[-12, "AI - Hard"], [-13, "AI - Learned"]]:
		kind.add_item(str(pair[1]))
	kind.select(_kind_index(s))
	kind.item_selected.connect(_on_slot_kind.bind(s.id))
	kind.disabled = _is_client
	kind.custom_minimum_size = Vector2(SLOT_COL_TYPE, 0)
	row.add_child(kind)

	# Кто сидит (batch 12 #8): у занятого людьми слота — имя игрока с пометкой, у
	# открытого — кнопка «Join» для гостя. Хост видит, какие места заняты, гость —
	# куда можно сесть.
	var who := Label.new()
	who.custom_minimum_size = Vector2(SLOT_COL_WHO, 0)
	who.add_theme_font_size_override("font_size", 11)
	# Длинное имя не раздвигает таблицу (item 23): обрезается с «…», целиком — в подсказке.
	who.clip_text = true
	who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	who.mouse_filter = Control.MOUSE_FILTER_PASS
	var my_peer := NetHandoff.session.my_peer_id() if NetHandoff.session != null else 1
	if s.kind == Roster.SlotKind.HUMAN:
		if s.peer_id == my_peer and NetHandoff.session != null:
			who.text = "%s (you)" % s.display_name
			who.modulate = Color(0.8, 0.95, 0.8)
		elif s.peer_id == 1:
			who.text = "%s (host)" % s.display_name
		elif s.peer_id > 1:
			who.text = s.display_name
		else:
			who.text = "%s (nobody yet)" % s.display_name if _is_host_net else s.display_name
			who.modulate = Color(0.85, 0.75, 0.6)
		who.tooltip_text = who.text
		row.add_child(who)
	elif s.kind == Roster.SlotKind.OPEN and _is_client:
		var join := Button.new()
		join.text = "Join"
		join.custom_minimum_size = Vector2(SLOT_COL_WHO, 0)
		join.pressed.connect(_on_join_slot.bind(s.id))
		row.add_child(join)
	else:
		who.text = "—" if s.kind == Roster.SlotKind.OPEN else ""
		who.modulate = Color(0.6, 0.62, 0.7)
		row.add_child(who)

	var color := OptionButton.new()
	# Настоящие названия цветов вместо «C1…C26» (item 3).
	for i in Roster.PALETTE.size():
		color.add_item(Roster.color_name(i), i)
	color.select(s.color_index())
	color.item_selected.connect(_on_slot_color.bind(s.id))
	color.disabled = _is_client
	# Ширина — по колонке, а не по самому длинному названию фракции (item 23).
	color.fit_to_longest_item = false
	color.clip_text = true
	color.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	color.tooltip_text = color.get_item_text(color.selected)
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
	# Выпадающий список вместо счётчика «Zone 0» (item 22): «Auto» — своя по номеру.
	var zone := OptionButton.new()
	zone.add_item("Auto")
	for zi in maxi(1, _map_zone_count()):
		zone.add_item("Zone %d" % (zi + 1))
	zone.select(clampi(s.deploy_zone + 1, 0, zone.item_count - 1))
	zone.item_selected.connect(func(i: int) -> void: _on_slot_zone(float(i), s.id))
	zone.disabled = _is_client
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
	# Набранное число попадает в ростер сразу, не дожидаясь Enter (batch 13 #12).
	budget.get_line_edit().text_changed.connect(func(t: String) -> void:
		if t.is_valid_int():
			(roster.slots[s.id] as Roster.Slot).budget = int(t))
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
	var cols: Array = [["#", SLOT_COL_IDX], ["Type", SLOT_COL_TYPE], ["Who", SLOT_COL_WHO],
			["Faction", SLOT_COL_COLOR]]
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
	var key := m.get_instance_id()
	var zones: int
	if _zone_count_cache.has(key):
		zones = int(_zone_count_cache[key])
	else:
		var seen := {}
		for z in m.zone_owner:
			if z >= 0:
				seen[z] = true
		zones = seen.size()
		_zone_count_cache[key] = zones
	# Нет размеченных зон — карта делится автоматически, зоны по числу игроков.
	return zones if zones > 0 else roster.slots.size()

func _on_slot_budget(value: float, slot_id: int) -> void:
	(roster.slots[slot_id] as Roster.Slot).budget = int(value)
	_broadcast_lobby()

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
			s.allowed_units[u] = on
			_broadcast_lobby())
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
		cb.toggled.connect(func(on: bool) -> void:
			_event_pool[eid] = on
			_broadcast_lobby())
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
		Roster.SlotKind.AI: return 3 + clampi(s.ai_difficulty, 0, 3)
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
	_lobby_changed()

func _on_remove_slot(slot_id: int) -> void:
	# Слот с живым гостем не убирают — сперва он должен уйти (batch 12 #8).
	var s: Roster.Slot = roster.slots[slot_id]
	if s.kind == Roster.SlotKind.HUMAN and s.peer_id > 1:
		_status.text = "%s is sitting in that slot — it can't be removed." % s.display_name
		return
	roster.remove_slot(slot_id)
	_lobby_changed()

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
	# Слот сидящего гостя хост не переназначает (batch 12 #8): игрока не выкинешь
	# щелчком по списку — только отключением.
	if s.kind == Roster.SlotKind.HUMAN and s.peer_id > 1 and index != 2:
		_status.text = "%s is sitting in that slot — it stays a Player." % s.display_name
		_refresh_slots()
		return
	match index:
		0: s.kind = Roster.SlotKind.OPEN
		1: s.kind = Roster.SlotKind.CLOSED
		2: s.kind = Roster.SlotKind.HUMAN
		_:
			s.kind = Roster.SlotKind.AI
			s.ai_difficulty = clampi(index - 3, 0, 3)
	if s.kind != Roster.SlotKind.HUMAN and s.peer_id > 1:
		s.peer_id = -1
	_lobby_changed()

func _on_slot_color(color_idx: int, slot_id: int) -> void:
	if not _assign_color(slot_id, color_idx):
		_status.text = "That faction is taken — no two players share a faction."
	_lobby_changed()

func _on_slot_zone(value: float, slot_id: int) -> void:
	# 0 → «своя зона по номеру» (deploy_zone = -1); N → Zone N (индекс N-1).
	(roster.slots[slot_id] as Roster.Slot).deploy_zone = int(value) - 1
	_refresh_map_preview()   # item 22: выбор зоны сразу виден на превью
	_broadcast_lobby()

func _on_slot_team(value: float, slot_id: int) -> void:
	(roster.slots[slot_id] as Roster.Slot).team = int(value) - 1
	_broadcast_lobby()

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
	# Хост ведёт слот 0; гость — слот, помеченный его сетевым номером (batch 12 #8).
	if not _is_client:
		return roster.slots[0] if not roster.slots.is_empty() else null
	var id := -1
	if NetHandoff.session != null:
		id = roster.side_of_peer(NetHandoff.session.my_peer_id())
	return roster.slots[id] if id >= 0 and id < roster.slots.size() else null

func _on_my_color(color_idx: int) -> void:
	var mine := _my_slot()
	if mine == null:
		return
	# Гость просит хоста: цвет общий на всех, решает тот, кто держит ростер (batch 12 #8).
	if _is_client:
		if NetHandoff.session != null:
			NetHandoff.session.send({"k": NetHandoff.K_LOBBY_REQ, "op": "color", "c": color_idx})
		return
	if not _assign_color(mine.id, color_idx):
		_status.text = "That faction is taken."
		return
	_refresh_swatch()
	_lobby_changed()

## Гость пересаживается в открытый слот (batch 12 #8): просьба хосту.
func _on_join_slot(slot_id: int) -> void:
	if NetHandoff.session != null:
		NetHandoff.session.send({"k": NetHandoff.K_LOBBY_REQ, "op": "slot", "s": slot_id})

func _refresh_personal_enabled() -> void:
	# «Host Decides» — цвет назначает хост; «Players Pick» — каждый выбирает сам.
	pass

# --- Предпросмотр карты (item 41) -------------------------------------------
## Кеш выбранной карты (batch 14): раньше КАЖДАЯ строка таблицы слотов перечитывала
## файл карты с диска ради числа зон, а превью растрировалось по 6 px на клетку — на
## большой карте лобби открывалось секундами и вздрагивало на каждом щелчке.
var _map_cache_path: String = "\u0001"
var _map_cache: MapData = null
var _zone_count_cache: Dictionary = {}  # instance id карты -> число зон

func _selected_map() -> MapData:
	# У гостя своего списка нет — карта та, что прислал хост (batch 12 #8).
	if _is_client:
		return _client_map if _client_map != null else MapData.blank_arena()
	var path: String = _map_paths[_map_opt.selected] if _map_opt != null else ""
	if path == RANDOM_MAP:
		return _random_map()
	if path == _map_cache_path and _map_cache != null:
		return _map_cache
	var m: MapData = null
	if path != "":
		m = MapData.load_from(path)
	if m == null:
		m = MapData.blank_arena()
	_map_cache_path = path
	_map_cache = m
	return m

var _preview_key := ""

func _refresh_map_preview() -> void:
	if _map_preview == null:
		return
	var map := _selected_map()
	var tints := _zone_tints()
	# Зовётся на каждую пересборку слотов, поэтому рисуем заново, только если сменилась
	# сама карта или цвета её зон: растеризация большой карты не бесплатна (batch 14).
	var bands := _band_tints(map)
	var key := "%d %s %s" % [map.get_instance_id(), tints, bands]
	if key == _preview_key:
		return
	_preview_key = key
	_map_preview.texture = _render_map_texture(map, tints, bands)
	_zone_marks = _zone_centres(map)
	_preview_size = Vector2(maxi(1, map.width), maxi(1, map.height))
	if _preview_labels != null:
		_preview_labels.queue_redraw()

## Карта без нарисованных зон (item 22): полосы развёртывания цветами слотов — те же
## полосы, что выдаст расстановка (MapData.band_of). {Vector2i(x0, x1): цвет}.
var _preview_labels: Control = null
var _zone_marks: Array = []        # [[центр в клетках, "N"], …]
var _preview_size := Vector2.ONE   # размер карты в клетках

## Центр каждой зоны развёртывания и её номер. Нарисованные зоны — по их клеткам, иначе —
## полосы по слотам (как и раскраска превью).
func _zone_centres(map: MapData) -> Array:
	var sums := {}
	for y in map.height:
		for x in map.width:
			var z := map.get_zone(Vector2i(x, y))
			if z >= 0:
				var acc: Array = sums.get(z, [Vector2.ZERO, 0])
				sums[z] = [acc[0] + Vector2(x + 0.5, y + 0.5), acc[1] + 1]
	var out: Array = []
	for z in sums:
		out.append([sums[z][0] / float(sums[z][1]), str(int(z) + 1)])
	if out.is_empty():
		var playing: Array = roster.slots.filter(func(sl: Roster.Slot) -> bool: return sl.is_playing())
		for i in playing.size():
			var sl: Roster.Slot = playing[i]
			var index := sl.deploy_zone if sl.deploy_zone >= 0 else i
			var band := MapData.band_of(index, playing.size(), map.width)
			out.append([Vector2((band.x + band.y) * 0.5, map.height * 0.5), str(index + 1)])
	return out

func _draw_zone_numbers() -> void:
	var box := _preview_labels.size
	var k := minf(box.x / _preview_size.x, box.y / _preview_size.y)
	var off := (box - _preview_size * k) * 0.5
	var font := _preview_labels.get_theme_default_font()
	var fs := 18
	for m: Array in _zone_marks:
		var txt: String = m[1]
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos: Vector2 = off + Vector2(m[0]) * k + Vector2(-w * 0.5, fs * 0.35)
		_preview_labels.draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.9))
		_preview_labels.draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1))

func _band_tints(map: MapData) -> Dictionary:
	var out := {}
	if map == null:
		return out
	for z in map.zone_owner:
		if z >= 0:
			return out   # зоны нарисованы — их и показываем
	var playing: Array = roster.slots.filter(func(sl: Roster.Slot) -> bool: return sl.is_playing())
	for i in playing.size():
		var sl: Roster.Slot = playing[i]
		var index := sl.deploy_zone if sl.deploy_zone >= 0 else i
		var band := MapData.band_of(index, playing.size(), map.width)
		if not out.has(band):
			out[band] = sl.color
	return out

## Цвет зоны в превью — цвет слота, который в ней расставляется (Slot.zone()).
func _zone_tints() -> Dictionary:
	var out := {}
	for s: Roster.Slot in roster.slots:
		if s.kind != Roster.SlotKind.CLOSED and not out.has(s.zone()):
			out[s.zone()] = s.color
	return out

## Полный верхний вид карты В КАРТИНКУ, включая нейтральные спавны (item 41) и зоны
## развёртывания цветами слотов. Рисуем по клеткам в Image — без отдельного вьюпорта,
## зато детерминированно и без сцены.
func _render_map_texture(map: MapData, tints: Dictionary = {}, bands: Dictionary = {}) -> ImageTexture:
	# Масштаб по размеру карты (batch 14): большая карта рисуется по пикселю на
	# клетку, а не по 36 на каждую — превью всё равно ужимается в 260×180.
	var sc: int = clampi(int(600 / maxi(1, maxi(map.width, map.height))), 1, 6)
	var w := maxi(1, map.width) * sc
	var h := maxi(1, map.height) * sc
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in map.height:
		for x in map.width:
			var coord := Vector2i(x, y)
			var col := _cell_color(map, coord)
			var zone := map.get_zone(coord)
			if zone >= 0:
				col = col.lerp(tints.get(zone, Color(0.85, 0.85, 0.85)), 0.4)
			else:
				for band: Vector2i in bands:
					if x >= band.x and x < band.y:
						col = col.lerp(bands[band], 0.3)
						break
			img.fill_rect(Rect2i(x * sc, y * sc, sc, sc), col)
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
	GameConfig.live_placement_visible = _live_check.button_pressed
	GameConfig.civilian_count = _civ_count()  # item 11
	GameConfig.ai_speed = GameConfig.AI_SPEEDS[_ai_speed_opt.selected]  # item 5
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
	# У случайной карты файла нет — на расстановку она уезжает готовой (_on_start).
	GameConfig.map_path = "" if _is_random() else _map_paths[_map_opt.selected]
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
		_status.text = "Two players share a faction — fix that first."
		return
	var playing := 0
	for s: Roster.Slot in roster.slots:
		if s.is_playing():
			playing += 1
	if playing < 2:
		_status.text = "Need at least two playing slots (Player or AI)."
		return
	# В сетевой партии за каждым «Player» должен сидеть человек (batch 12 #8): слот без
	# пира никто не поведёт, и бой встанет на его ходу.
	if _is_host_net:
		for s: Roster.Slot in roster.slots:
			if s.kind == Roster.SlotKind.HUMAN and s.peer_id < 0:
				_status.text = "Slot %d is 'Player' but nobody has joined it — wait for them, or set the slot to Open / AI." % (s.id + 1)
				return
	if not _save.is_empty():
		_start_loaded()
		return
	_commit_config()
	# Сетевой хост объявляет карту клиентам тем же путём, что и старый Setup. Случайная
	# карта и в одиночке едет на расстановку готовой: перечитать её неоткуда.
	var net_host := NetHandoff.session != null and NetHandoff.is_host
	if net_host or _is_random():
		var shared: MapData = _selected_map()
		if net_host:
			NetHandoff.session.send(NetHandoff.encode_setup(shared))
		NetHandoff.lobby_map = shared
	get_tree().change_scene_to_file(PLACEMENT_SCENE)

func _on_back() -> void:
	if NetHandoff.session != null:
		NetHandoff.discard()
	get_tree().change_scene_to_file(MENU_SCENE)
