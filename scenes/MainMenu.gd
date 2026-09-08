extends Control

## Лобби — точка входа (по образцу isotope lobby). Две вкладки (#54):
##   • Single Player — новая игра, редактор карт, сохранённые карты.
##   • Multiplayer   — P2P по IP: связь налаживается ЗДЕСЬ и уезжает в бой готовой
##     сессией через NetHandoff. На боковой панели боя сетевых кнопок больше нет.

const SETUP_SCENE := "res://scenes/Setup.tscn"
const LOBBY_SCENE := "res://scenes/Lobby.tscn"
const EDITOR_SCENE := "res://scenes/MapEditor.tscn"
const PLACEMENT_SCENE := "res://scenes/Placement.tscn"
const MAIN_SCENE := "res://scenes/Main.tscn"

var _saves_list: ItemList
var _map_names: PackedStringArray

# --- Сохранения и повторы (M12) ---
var _game_list: ItemList
var _game_names: PackedStringArray
var _replay_list: ItemList
var _replay_names: PackedStringArray

# --- Мультиплеер ---
var _mp_ip: LineEdit
var _mp_status: Label
var _mp_host_btn: Button
var _mp_join_btn: Button
var _mp_cancel_btn: Button
var _session: NetworkSession = null
## Автопоиск LAN (item 38): узел-обозреватель и список найденных серверов.
var _lan: LanDiscovery = null
var _lan_list: ItemList
var _lan_servers: Array = []

func _ready() -> void:
	# Уходя в меню, старую сессию не тащим — начинаем с чистого листа.
	NetHandoff.discard()
	# И недоигранный файл тоже: в меню приходят, чтобы начать заново (M12).
	SaveHandoff.discard()

	# Гарантированно чёрная подложка ПОД параллаксом (item 3): даже если звёздный слой
	# по какой-то причине не растянулся, меню всё равно чёрное, а не годотовское серое.
	var black_bg := ColorRect.new()
	black_bg.color = Color(0, 0, 0)
	black_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	black_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(black_bg)

	# Параллакс-звёзды вместо плоской заливки (M13, item 35). Фон живёт своей жизнью
	# и ввод не перехватывает — меню поверх него работает как работало.
	add_child(Starfield.new())

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	# Заголовок без эмблемы (item 1): logo.png — это логотип Crazy Ball Runner 2D,
	# оставшийся от донора интерфейса; на главном меню MCF ему не место. Оставляем
	# только надпись.
	var title_row := HBoxContainer.new()
	title_row.alignment = BoxContainer.ALIGNMENT_CENTER
	title_row.add_theme_constant_override("separation", 12)
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "MCF Tactics"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title_row.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Turn-based tactics"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.modulate = Color(0.7, 0.72, 0.78)
	vbox.add_child(subtitle)

	vbox.add_child(HSeparator.new())

	# Вкладки: одиночная игра и мультиплеер — совершенно раздельные режимы (#54).
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 340)
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(tabs)
	tabs.add_child(_build_single_tab())
	tabs.add_child(_build_multi_tab())
	tabs.add_child(_build_files_tab())

	vbox.add_child(HSeparator.new())
	# Экран настроек (item 24) ждёт исходников: порт наугад дал бы меню, которое
	# выглядит настройками, но ничего не настраивает. Кнопка стоит на своём месте
	# погашенной — так видно, что место занято, а не забыто.
	var settings := _menu_button("Settings", func() -> void: pass)
	settings.disabled = true
	settings.tooltip_text = "Not built yet — waiting on the original settings screen."
	vbox.add_child(settings)
	vbox.add_child(_menu_button("Quit", _quit))

# --- Вкладка одиночной игры ---
func _build_single_tab() -> Control:
	var page := VBoxContainer.new()
	page.name = "Single Player"
	page.add_theme_constant_override("separation", 10)

	page.add_child(_menu_button("New Game", _new_game))
	page.add_child(_menu_button("Map Editor", _open_editor))

	var saves_label := Label.new()
	saves_label.text = "Saved maps"
	page.add_child(saves_label)

	_saves_list = ItemList.new()
	_saves_list.custom_minimum_size = Vector2(0, 150)
	_saves_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_saves_list.item_activated.connect(_on_map_activated)
	page.add_child(_saves_list)
	_refresh_saves()
	return page

# --- Вкладка сохранений и повторов (M12, items 42 и 53) ---
## Сохранённая партия продолжается прямо отсюда — ролями она распоряжается сама, как
## их записали. Переназначить их (кто из сидящих за столом ведёт какую армию) можно в
## лобби: там для этого есть тот же список файлов.
func _build_files_tab() -> Control:
	var page := VBoxContainer.new()
	page.name = "Load / Replay"
	page.add_theme_constant_override("separation", 8)

	var hint := Label.new()
	hint.text = "Continue a saved match, or watch a recorded one. To hand a saved army to a different player, open the save in the multiplayer lobby instead."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(0.72, 0.74, 0.8)
	page.add_child(hint)

	var games_label := Label.new()
	games_label.text = "Saved games"
	page.add_child(games_label)
	_game_list = ItemList.new()
	_game_list.custom_minimum_size = Vector2(0, 110)
	_game_list.item_activated.connect(_on_game_activated)
	page.add_child(_game_list)

	var replays_label := Label.new()
	replays_label.text = "Replays"
	page.add_child(replays_label)
	_replay_list = ItemList.new()
	_replay_list.custom_minimum_size = Vector2(0, 110)
	_replay_list.item_activated.connect(_on_replay_activated)
	page.add_child(_replay_list)

	_refresh_files()
	return page

## Наполнить оба списка. Каждый файл читается ради подписи — они маленькие и сжатые,
## а список без «карта, раунд, когда» бесполезен: имена в нём различаются только временем.
func _refresh_files() -> void:
	_game_names = ReplayFile.saves()
	_fill_file_list(_game_list, _game_names, ReplayFile.SAVE_DIR,
			"(no saved games yet — save one from a match)")
	_replay_names = ReplayFile.replays()
	_fill_file_list(_replay_list, _replay_names, ReplayFile.REPLAY_DIR,
			"(no replays yet — they are written when you leave a match)")

func _fill_file_list(list: ItemList, names: PackedStringArray, dir: String,
		empty_text: String) -> void:
	list.clear()
	if names.is_empty():
		list.add_item(empty_text)
		list.set_item_disabled(0, true)
		return
	for name in names:
		var data := ReplayFile.read(ReplayFile.path_for(dir, name))
		var note := ReplayFile.describe(data)
		list.add_item(name.get_basename() if note == "" else "%s  —  %s" % [name.get_basename(), note])

func _on_game_activated(idx: int) -> void:
	if idx < 0 or idx >= _game_names.size():
		return
	var data := ReplayFile.read(ReplayFile.path_for(ReplayFile.SAVE_DIR, _game_names[idx]))
	if data.is_empty():
		return
	SaveHandoff.pending_save = data
	MapHandoff.pending = null
	get_tree().change_scene_to_file(MAIN_SCENE)

func _on_replay_activated(idx: int) -> void:
	if idx < 0 or idx >= _replay_names.size():
		return
	var data := ReplayFile.read(ReplayFile.path_for(ReplayFile.REPLAY_DIR, _replay_names[idx]))
	if data.is_empty():
		return
	SaveHandoff.pending_replay = data
	MapHandoff.pending = null
	get_tree().change_scene_to_file(MAIN_SCENE)

# --- Вкладка мультиплеера ---
func _build_multi_tab() -> Control:
	var page := VBoxContainer.new()
	page.name = "Multiplayer"
	page.add_theme_constant_override("separation", 10)

	var hint := Label.new()
	hint.text = "Peer-to-peer over LAN. One side hosts, the other joins by IP.\nThe host picks the map and the point budget; both sides then buy and deploy their own squad."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = Color(0.72, 0.74, 0.8)
	page.add_child(hint)

	_mp_ip = LineEdit.new()
	_mp_ip.placeholder_text = "Host IP"
	_mp_ip.text = "127.0.0.1"
	page.add_child(_mp_ip)

	_mp_host_btn = _menu_button("Host Game", _host_game)
	page.add_child(_mp_host_btn)
	_mp_join_btn = _menu_button("Join Game", _join_game)
	page.add_child(_mp_join_btn)

	# Автопоиск серверов в локальной сети (item 38). Хост объявляет о себе, а этот
	# список наполняется найденными хостами; клик по строке подключается напрямую.
	var lan_lbl := Label.new()
	lan_lbl.text = "LAN games:"
	lan_lbl.add_theme_font_size_override("font_size", 12)
	page.add_child(lan_lbl)
	_lan_list = ItemList.new()
	_lan_list.custom_minimum_size = Vector2(0, 90)
	_lan_list.item_activated.connect(_on_lan_pick)
	page.add_child(_lan_list)
	_lan = LanDiscovery.new()
	get_tree().root.add_child.call_deferred(_lan)
	_lan.servers_changed.connect(_on_lan_servers)
	_lan.start_listening.call_deferred()

	_mp_cancel_btn = _menu_button("Cancel", _cancel_net)
	_mp_cancel_btn.hide()
	page.add_child(_mp_cancel_btn)

	_mp_status = Label.new()
	_mp_status.text = "Offline"
	_mp_status.add_theme_font_size_override("font_size", 13)
	_mp_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_mp_status)
	return page

func _host_game() -> void:
	if _session != null:
		return
	_start_session()
	var err := _session.start_host(NetworkSession.DEFAULT_PORT)
	if err == OK:
		# item 10: хост открывает лобби СРАЗУ, не дожидаясь подключения. Объявление в
		# локальной сети (item 38) продолжит уже само лобби — иначе, уйдя с меню, мы бы
		# сняли маяк и клиенты перестали бы нас находить.
		_go_lobby(true)
	else:
		_fail_net("Could not host (error %d). Is the port already in use?" % err)

func _join_game() -> void:
	if _session != null:
		return
	var ip := _mp_ip.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	_start_session()
	var err := _session.start_client(ip, NetworkSession.DEFAULT_PORT)
	if err == OK:
		_set_waiting("Connecting to %s..." % ip)
	else:
		_fail_net("Could not connect (error %d)." % err)

## Обозреватель LAN живёт под /root — снимаем его при уходе из меню, чтобы не копить
## сироты и не держать порт открытым в бою.
func _exit_tree() -> void:
	if _lan != null:
		_lan.stop()
		_lan.queue_free()
		_lan = null

## Найденные в сети серверы обновились (item 38) — перерисовываем список.
func _on_lan_servers(servers: Array) -> void:
	_lan_servers = servers
	if _lan_list == null:
		return
	_lan_list.clear()
	for info: Dictionary in servers:
		_lan_list.add_item("%s @ %s (%d)" % [
			str(info.get("name", "Game")), str(info.get("ip", "?")),
			int(info.get("players", 0))])

## Клик по найденному серверу — подключаемся к его IP напрямую (item 38).
func _on_lan_pick(index: int) -> void:
	if index < 0 or index >= _lan_servers.size() or _session != null:
		return
	_mp_ip.text = str((_lan_servers[index] as Dictionary).get("ip", "127.0.0.1"))
	_join_game()

## Сессия живёт под /root с постоянным именем — так её путь одинаков у обеих
## сторон (RPC ходит по пути) и переживает смену сцены на бой.
func _start_session() -> void:
	_session = NetworkSession.new()
	_session.name = NetworkSession.NODE_NAME
	get_tree().root.add_child(_session)
	_session.peer_ready.connect(_on_peer_ready)
	_session.disconnected.connect(_on_net_lost)

func _set_waiting(text: String) -> void:
	_mp_status.text = text
	_mp_host_btn.hide()
	_mp_join_btn.hide()
	_mp_cancel_btn.show()

func _fail_net(text: String) -> void:
	_drop_session()
	_mp_status.text = text

func _cancel_net() -> void:
	_drop_session()
	_mp_status.text = "Offline"

func _drop_session() -> void:
	if _session != null:
		_session.close()
		_session.queue_free()
		_session = null
	_mp_host_btn.show()
	_mp_join_btn.show()
	_mp_cancel_btn.hide()

func _on_net_lost() -> void:
	_fail_net("Connection lost.")

## Связь есть — начинается обычная партия, просто на двоих (#99). Хост уходит на тот
## же экран подготовки, что и в одиночке: выбирает карту, бюджет очков, мирных и туман.
## Клиент условий не выбирает — он ждёт объявления хоста прямо здесь и по нему уезжает
## на закупку. Дальше как раньше (#93): каждый набирает и ставит ТОЛЬКО свою армию в
## своей зоне, стороны обмениваются ростерами и строят ОДИНАКОВОЕ начальное состояние.
## Гость подключился — уезжает в общее лобби (item 10 сдвинул сюда только КЛИЕНТА: хост
## открывает лобби сразу при нажатии «Host», не дожидаясь подключения).
func _on_peer_ready(is_host: bool) -> void:
	_go_lobby(is_host)

## Передать сессию в лобби и уйти туда. Общий путь для хоста (сразу), гостя (по связи)
## и одиночки (session == null).
func _go_lobby(is_host: bool) -> void:
	GameConfig.p2_is_ai = false
	GameConfig.free_placement = true
	MapHandoff.pending = null
	NetHandoff.session = _session
	NetHandoff.is_host = is_host
	_session = null  # узел уходит дальше, из меню его больше не трогаем
	get_tree().change_scene_to_file(LOBBY_SCENE)

# --- Общее ---
func _menu_button(text: String, handler: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 44)
	btn.add_theme_font_size_override("font_size", 18)
	btn.pressed.connect(handler)
	return btn

func _refresh_saves() -> void:
	_saves_list.clear()
	_map_names = MapData.list_maps()
	if _map_names.is_empty():
		_saves_list.add_item("(no saved maps — make one in the editor)")
		_saves_list.set_item_disabled(0, true)
		return
	for name in _map_names:
		_saves_list.add_item(name.get_basename())

## Одиночная игра теперь открывает ТО ЖЕ лобби, что и мультиплеер (item 20): единый
## экран создания партии, где противники — слоты-ИИ. Отдельного «Match Setup» и опции
## «Default squads» больше нет — расстановка всегда свободная.
func _new_game() -> void:
	SaveHandoff.discard()
	NetHandoff.discard()  # одиночка — без сессии
	GameConfig.map_path = ""
	GameConfig.p2_is_ai = false
	GameConfig.free_placement = true
	get_tree().change_scene_to_file(LOBBY_SCENE)

func _on_map_activated(idx: int) -> void:
	if idx < 0 or idx >= _map_names.size():
		return
	GameConfig.map_path = MapData.path_for(_map_names[idx])
	get_tree().change_scene_to_file(SETUP_SCENE)

func _open_editor() -> void:
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _quit() -> void:
	get_tree().quit()
