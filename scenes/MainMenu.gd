extends Control

## Лобби — точка входа (по образцу isotope lobby). Две вкладки (#54):
##   • Single Player — новая игра, редактор карт, сохранённые карты.
##   • Multiplayer   — P2P по IP: связь налаживается ЗДЕСЬ и уезжает в бой готовой
##     сессией через NetHandoff. На боковой панели боя сетевых кнопок больше нет.

## Через preload, а не по class_name: скрипт добавлен без пересканирования проекта,
## и глобальный кеш классов о нём ещё не знает.
const UserDataMigrationScript = preload("res://src/data/UserDataMigration.gd")

const LOBBY_SCENE := "res://scenes/Lobby.tscn"
const EDITOR_SCENE := "res://scenes/MapEditor.tscn"
const PLACEMENT_SCENE := "res://scenes/Placement.tscn"
const MAIN_SCENE := "res://scenes/Main.tscn"
const SteamChrome = preload("res://src/ui/SteamChrome.gd")


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
## Internet lobbies (0.11): the relay's list of open games, refreshed while the page shows.
var _lobby_list: ItemList
var _lobby_rooms: Array = []
var _lobby_probe: RelayLink = null
var _lobby_timer := 0.0
var _mp_server: LineEdit
var _mp_password: LineEdit
var _mp_room_name: LineEdit
var _mp_online_btn: Button
var _mp_join_online_btn: Button
static var _vs_latest_done := false
var _lobby_broken := false
## Страницы меню. Полоса вкладок у контейнера скрыта: ходим по ним кнопками самого меню.
var _pages: TabContainer = null
## Крупная надпись и подзаголовок — только на главной странице: на страницах второго
## уровня они съедали высоту, и «Back» уезжал за край окна (editor-rework, аудит UI).
var _hero: Array[Control] = []
const PAGE_HOME := 0
const PAGE_MULTI := 1
const PAGE_FILES := 2

func _ready() -> void:
	# Пока игрок в меню, компилируем бой в фоновом потоке: скрипты игры (резолвер, ИИ,
	# экран боя) — это почти секунда компиляции при каждом запуске из исходников, и
	# платить её на щелчке «New Game» незачем. Дальнейший load() той же сцены просто
	# дождётся потока или возьмёт готовое из кеша.
	Ui.warm_up([LOBBY_SCENE, MAIN_SCENE])
	# Главное меню — первая сцена запуска, поэтому забрать сохранённое из каталога
	# прежнего имени игры надо здесь, ДО того как лобби/редактор полезут в user://
	# за картами (item 7 переименовал приложение и вместе с ним user://).
	var imported := UserDataMigrationScript.migrate_legacy()
	if imported > 0:
		print("Imported %d file(s) from the previous user data folder." % imported)
	# 0.11: saves, replays, maps and presets moved into the shared "Isotope Data" folder.
	var adopted := GameFolders.adopt_user_data()
	if adopted > 0:
		print("Moved %d file(s) into %s." % [adopted, GameFolders.root()])
	# Уходя в меню, старую сессию не тащим — начинаем с чистого листа.
	NetHandoff.discard()
	# И недоигранный файл тоже: в меню приходят, чтобы начать заново (M12).
	SaveHandoff.discard()
	# Панель обучения RL (spec §11.7) открывает повтор снаружи:
	#   godot --path . -- --replay=/abs/path.mcfr
	# «Play vs latest» (train.py play) запускает игру сразу в лобби с обученным ИИ в слоте
	# соперника. Один раз за запуск: вернувшись в меню после партии, игрок остаётся в меню.
	# LearnedController — через load(): прямая ссылка на класс компилировала бы весь
	# резолвер ещё до появления меню, а нужен он только с --vs-latest.
	if not _vs_latest_done and OS.get_cmdline_user_args().has("--vs-latest") \
			and load("res://src/controllers/LearnedController.gd").available():
		_vs_latest_done = true
		# Лобби, которое не собирается, — это СЕРЫЙ ЭКРАН: меню уже не строится, а смена
		# сцены на сломанный скрипт не показывает ничего. Так и вышло после выпуска со
		# свежим class_name (MapGen): кеш классов обновляется только импортом, а игру из
		# исходников запускают без него. Сломано — остаёмся в меню и говорим почему.
		var lobby_script: Script = load("res://scenes/Lobby.gd")
		if lobby_script != null and lobby_script.can_instantiate():
			_new_game.call_deferred()
			return
		_lobby_broken = true
		push_error("Lobby.gd does not compile — re-import the project (godot --headless --import)")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--replay="):
			var data := ReplayFile.read_replay(arg.trim_prefix("--replay="))
			if not data.is_empty():
				print("Opening replay from the command line: %s" % arg.trim_prefix("--replay="))
				SaveHandoff.pending_replay = data
				MapHandoff.pending = null
				get_tree().change_scene_to_file.call_deferred(MAIN_SCENE)
				return

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

	# Окно по набору интерфейса (item 23): вкладки и ряд кнопок справа внизу.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(480, 0)
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)

	# Середина окна прокручивается, если оно не влезает по высоте (крупный интерфейс,
	# item 23): шапка и кнопки внизу всегда на экране.
	var body := ScrollContainer.new()
	body.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(body)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	body.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)
	if _lobby_broken:
		var warn := Label.new()
		warn.text = ("The lobby failed to load: this copy of the game needs a re-import.\n"
				+ "Run:  godot --headless --path <project> --import")
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
		vbox.add_child(warn)

	# Заголовок без эмблемы (item 1): logo.png — это логотип Crazy Ball Runner 2D,
	# оставшийся от донора интерфейса; на главном меню MCF ему не место. Оставляем
	# только надпись.
	var title_row := HBoxContainer.new()
	title_row.alignment = BoxContainer.ALIGNMENT_CENTER
	title_row.add_theme_constant_override("separation", 12)
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "MCF Isotope"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title_row.add_child(title)
	_hero.append(title_row)

	var hero_sep := HSeparator.new()
	vbox.add_child(hero_sep)
	_hero.append(hero_sep)

	# ОДИН список кнопок, а не полоса вкладок плюс россыпь по углам. Раньше «New Game» и
	# «Map Editor» лежали на вкладке, мультиплеер и файлы — на соседних, а настройки с
	# выходом жили вообще отдельной строкой внизу: четыре места на шесть пунктов, и
	# половина меню — пустое поле под двумя кнопками.
	#
	# Страницы остались ровно теми же, сменилась навигация: полоса вкладок скрыта, на
	# мультиплеер и файлы ведут обычные кнопки того же списка, и с каждой есть «Back».
	var pages := TabContainer.new()
	pages.custom_minimum_size = Vector2(0, 340)
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages.tabs_visible = false
	vbox.add_child(pages)
	var version := Label.new()
	version.text = "v%s" % ProjectSettings.get_setting("application/config/version", "dev")
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version.add_theme_font_size_override("font_size", 12)
	frame.add_child(SteamChrome.pad(version, 12, 6))
	_pages = pages
	pages.add_child(_build_home_page())
	pages.add_child(_page_with_back(_build_multi_tab(), "Multiplayer"))
	pages.add_child(_page_with_back(_build_files_tab(), "Saves & Replays"))
	var fit := func() -> void:
		var chrome := panel.get_combined_minimum_size().y - body.get_combined_minimum_size().y
		body.custom_minimum_size.y = minf(margin.get_combined_minimum_size().y,
				maxf(120.0, center.size.y - chrome - 16.0))
	center.resized.connect(fit)
	fit.call_deferred()

# --- Главная страница меню ---
## Всё, с чего начинается партия, одним столбцом и в одном порядке чтения: сыграть,
## построить карту, сыграть с живым соперником, вернуться к начатому, настроить, выйти.
## Окно «Saved maps» в меню не вернулось (item 7): карты грузятся в редакторе, а
## партии — на странице «Saves & Replays».
func _build_home_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "Main"
	page.add_theme_constant_override("separation", 10)
	page.add_child(_menu_button("New Game", _new_game))
	page.add_child(_menu_button("Map Editor", _open_editor))
	page.add_child(_menu_button("Multiplayer", _show_multiplayer))
	page.add_child(_menu_button("Saves & Replays", _show_files))
	page.add_child(_menu_button("Settings", _show_settings))
	page.add_child(_menu_button("Quit", _quit))
	return page

func _show_multiplayer() -> void:
	_show_page(PAGE_MULTI)

func _show_files() -> void:
	_show_page(PAGE_FILES)

func _show_page(i: int) -> void:
	_pages.current_tab = i
	for c in _hero:
		c.visible = i == PAGE_HOME

func _show_settings() -> void:
	SettingsWindow.open(self)

func _show_home() -> void:
	_show_page(PAGE_HOME)

## Страница второго уровня: её содержимое и возврат в меню. Без «Back» единственной
## дорогой назад осталась бы полоса вкладок, которой здесь больше нет.
func _page_with_back(content: Control, title: String) -> Control:
	var page := VBoxContainer.new()
	page.name = title
	page.add_theme_constant_override("separation", 12)
	# «Back» и название страницы — сверху: так возврат виден всегда, а не после прокрутки.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var back := Button.new()
	back.text = "< Back"
	back.custom_minimum_size = Vector2(96, 30)
	back.pressed.connect(_show_home)
	row.add_child(back)
	var head := Label.new()
	head.text = title
	head.add_theme_font_size_override("font_size", 20)
	head.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(head)
	page.add_child(row)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(content)
	return page

# --- Вкладка сохранений и повторов (M12, items 42 и 53) ---
## Сохранённая партия продолжается прямо отсюда — ролями она распоряжается сама, как
## их записали. Переназначить их (кто из сидящих за столом ведёт какую армию) можно в
## лобби: там для этого есть тот же список файлов.
func _build_files_tab() -> Control:
	var page := VBoxContainer.new()
	page.name = "Saves & Replays"
	page.add_theme_constant_override("separation", 8)

	var hint := Label.new()
	hint.text = "Continue a saved match, or watch a recorded one. To hand a saved army to a different player, open the save in the multiplayer lobby instead."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(0.72, 0.74, 0.8)
	page.add_child(hint)

	var games := SteamChrome.group_box("Saved games")
	page.add_child(games)
	_game_list = ItemList.new()
	_game_list.custom_minimum_size = Vector2(0, 96)
	_game_list.item_activated.connect(_on_game_activated)
	games.body.add_child(_game_list)
	games.body.add_child(_folder_button(ReplayFile.SAVE_DIR))

	var replays := SteamChrome.group_box("Replays")
	page.add_child(replays)
	_replay_list = ItemList.new()
	_replay_list.custom_minimum_size = Vector2(0, 96)
	_replay_list.item_activated.connect(_on_replay_activated)
	replays.body.add_child(_replay_list)
	replays.body.add_child(_folder_button(ReplayFile.REPLAY_DIR))

	_refresh_files()
	# Files copied into the folders while the game runs show up as soon as it is back in
	# focus — no import step (0.11).
	if not get_window().focus_entered.is_connected(_refresh_files):
		get_window().focus_entered.connect(_refresh_files)
	return page

## "Open folder" — the plain folder where these files live, to share or drop files in.
func _folder_button(dir: String) -> Button:
	var b := Button.new()
	b.text = "Open folder"
	b.tooltip_text = dir
	b.size_flags_horizontal = Control.SIZE_SHRINK_END
	b.pressed.connect(func() -> void: OS.shell_open(ProjectSettings.globalize_path(dir)))
	return b

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
		list.add_item(name.get_basename())
	_fill_notes(list, names, dir)

## Подписи к файлам — после того как меню уже на экране, по несколько за кадр: файл без
## готовой подписи (старый, до .note) читается целиком, и меню не должно его ждать.
func _fill_notes(list: ItemList, names: PackedStringArray, dir: String) -> void:
	for i in names.size():
		if i % 4 == 3:
			await get_tree().process_frame
		if not is_instance_valid(list) or list.item_count <= i:
			return
		var note := ReplayFile.note_for(ReplayFile.path_for(dir, names[i]))
		if note != "":
			list.set_item_text(i, "%s  —  %s" % [names[i].get_basename(), note])

func _mark_unreadable(list: ItemList, idx: int, name: String) -> void:
	if is_instance_valid(list) and idx < list.item_count:
		list.set_item_text(idx, "%s  —  can't be opened (damaged, or not a %s file)" % [name.get_basename(),
				"saved game" if list == _game_list else "replay"])

func _on_game_activated(idx: int) -> void:
	if idx < 0 or idx >= _game_names.size():
		return
	var data := ReplayFile.read(ReplayFile.path_for(ReplayFile.SAVE_DIR, _game_names[idx]))
	if data.is_empty() or str(data.get("kind", "")) != ReplayFile.KIND_SAVE:
		_mark_unreadable(_game_list, idx, _game_names[idx])
		return
	SaveHandoff.pending_save = data
	MapHandoff.pending = null
	get_tree().change_scene_to_file(MAIN_SCENE)

func _on_replay_activated(idx: int) -> void:
	if idx < 0 or idx >= _replay_names.size():
		return
	var data := ReplayFile.read_replay(ReplayFile.path_for(ReplayFile.REPLAY_DIR, _replay_names[idx]))
	if data.is_empty() or str(data.get("kind", "")) != ReplayFile.KIND_REPLAY:
		_mark_unreadable(_replay_list, idx, _replay_names[idx])
		return
	SaveHandoff.pending_replay = data
	MapHandoff.pending = null
	get_tree().change_scene_to_file(MAIN_SCENE)

# --- Вкладка мультиплеера ---
## Internet first (0.11): open games from the Isotope lobby server, hosting one, and the
## direct IP connection for a LAN or a VPN underneath.
func _build_multi_tab() -> Control:
	var page := VBoxContainer.new()
	page.name = "Multiplayer"
	page.add_theme_constant_override("separation", 10)

	var hint := Label.new()
	hint.text = "Play over the internet through the Isotope lobby server, or directly over a LAN. The host picks the map and the point budget; everyone then buys and deploys their own squad."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = Color(0.72, 0.74, 0.8)
	page.add_child(hint)

	var lobbies := SteamChrome.group_box("Lobbies")
	page.add_child(lobbies)
	_lobby_list = ItemList.new()
	_lobby_list.custom_minimum_size = Vector2(0, 120)
	_lobby_list.item_activated.connect(func(_i: int) -> void: _join_online())
	lobbies.body.add_child(_lobby_list)
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 10)
	lobbies.body.add_child(join_row)
	_mp_password = LineEdit.new()
	_mp_password.placeholder_text = "Password (if the game has one)"
	_mp_password.secret = true
	_mp_password.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_row.add_child(_mp_password)
	var refresh := _menu_button("Refresh", _refresh_lobbies)
	join_row.add_child(refresh)
	_mp_join_online_btn = _menu_button("Join", _join_online)
	join_row.add_child(_mp_join_online_btn)

	var host_box := SteamChrome.group_box("Host an online game")
	page.add_child(host_box)
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 10)
	host_box.body.add_child(host_row)
	_mp_room_name = LineEdit.new()
	_mp_room_name.placeholder_text = "Game name"
	_mp_room_name.text = _net_setting("room_name", "Isotope game")
	_mp_room_name.max_length = 40
	_mp_room_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_row.add_child(_mp_room_name)
	_mp_online_btn = _menu_button("Host Online", _host_online)
	host_row.add_child(_mp_online_btn)
	var host_hint := Label.new()
	host_hint.text = "The password field above, if filled, locks your game."
	host_hint.add_theme_font_size_override("font_size", 11)
	host_hint.modulate = Color(0.6, 0.62, 0.68)
	host_box.body.add_child(host_hint)

	var direct := SteamChrome.group_box("Direct connection (LAN or VPN)")
	page.add_child(direct)
	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 10)
	direct.body.add_child(ip_row)
	_mp_ip = LineEdit.new()
	_mp_ip.placeholder_text = "Host IP"
	_mp_ip.text = "127.0.0.1"
	_mp_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_row.add_child(_mp_ip)
	_mp_host_btn = _menu_button("Host", _host_game)
	ip_row.add_child(_mp_host_btn)
	_mp_join_btn = _menu_button("Join by IP", _join_game)
	ip_row.add_child(_mp_join_btn)

	var server_row := HBoxContainer.new()
	server_row.add_theme_constant_override("separation", 10)
	page.add_child(server_row)
	var server_lbl := Label.new()
	server_lbl.text = "Lobby server"
	server_lbl.add_theme_font_size_override("font_size", 11)
	server_lbl.modulate = Color(0.6, 0.62, 0.68)
	server_row.add_child(server_lbl)
	_mp_server = LineEdit.new()
	_mp_server.text = _net_setting("server", RelayLink.DEFAULT_SERVER)
	_mp_server.placeholder_text = RelayLink.DEFAULT_SERVER
	_mp_server.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mp_server.text_submitted.connect(func(_t: String) -> void: _refresh_lobbies())
	server_row.add_child(_mp_server)

	_mp_cancel_btn = _menu_button("Cancel", _cancel_net)
	_mp_cancel_btn.hide()
	page.add_child(_mp_cancel_btn)

	_mp_status = Label.new()
	_mp_status.text = "Offline"
	_mp_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.style_status(_mp_status)   # строка состояния набора — акцентом в утопленной рамке
	page.add_child(_mp_status)
	return page

func _net_setting(key: String, fallback: String) -> String:
	var cf := ConfigFile.new()
	cf.load("user://settings.cfg")
	return str(cf.get_value("net", key, fallback))

func _save_net_setting(key: String, value: String) -> void:
	var cf := ConfigFile.new()
	cf.load("user://settings.cfg")
	cf.set_value("net", key, value)
	cf.save("user://settings.cfg")

func _server() -> String:
	var s := _mp_server.text.strip_edges() if _mp_server != null else ""
	if s == "": s = RelayLink.DEFAULT_SERVER
	_save_net_setting("server", s)
	return s

## Ask the lobby server for its open games on a short-lived connection of its own.
func _refresh_lobbies() -> void:
	if _lobby_list == null or _lobby_probe != null: return
	_lobby_timer = 0.0
	_lobby_probe = RelayLink.new()
	if _lobby_probe.connect_to(_server()) != OK:
		_lobby_probe = null
		return
	_lobby_probe.rooms.connect(func(list: Array) -> void:
		_show_lobbies(list)
		_lobby_probe.close()
		_lobby_probe = null)
	_lobby_probe.failed.connect(func(reason: String) -> void:
		_show_lobbies([], reason)
		_lobby_probe = null)
	_lobby_probe.list_rooms()

func _show_lobbies(list: Array, error: String = "") -> void:
	if _lobby_list == null: return
	var chosen := ""
	var sel := _lobby_list.get_selected_items()
	if not sel.is_empty() and sel[0] < _lobby_rooms.size(): chosen = str(_lobby_rooms[sel[0]].get("room", ""))
	_lobby_rooms = list
	_lobby_list.clear()
	if list.is_empty():
		_lobby_list.add_item(error if error != "" else "No open games right now — host one below.")
		_lobby_list.set_item_disabled(0, true)
		return
	for r: Dictionary in list:
		var same := int(r.get("protocol", NetHandoff.PROTOCOL)) == NetHandoff.PROTOCOL
		var battle := str(r.get("status", "")) == "In battle"
		var text := "%s · %s · %d/%d%s%s" % [str(r.get("name", "Game")), str(r.get("map", "?")),
				int(r.get("players", 1)), int(r.get("max_players", 2)),
				" · in battle" if battle else "", " · password" if bool(r.get("locked", false)) else ""]
		if not same: text += "  ·  version %s" % str(r.get("version", "?"))
		_lobby_list.add_item(text)
		var i := _lobby_list.item_count - 1
		_lobby_list.set_item_disabled(i, not same or battle)
		_lobby_list.set_item_tooltip(i, text)
		if str(r.get("room", "")) == chosen: _lobby_list.select(i)

func _process(delta: float) -> void:
	if _lobby_probe != null:
		_lobby_probe.poll(delta)
	if _lobby_list != null and _lobby_list.is_visible_in_tree() and _session == null:
		_lobby_timer += delta
		if _lobby_timer >= 5.0: _refresh_lobbies()

func _host_online() -> void:
	if _session != null: return
	var room_name := _mp_room_name.text.strip_edges()
	if room_name == "": room_name = "Isotope game"
	_save_net_setting("room_name", room_name)
	_start_session()
	NetHandoff.room_name = room_name
	_session.relay_room.connect(func(code: String) -> void:
		NetHandoff.room_code = code
		_go_lobby(true))
	var err := _session.start_relay_host(_server(), {"name": room_name, "map": "—", "players": 1,
			"max_players": 2, "status": "In lobby", "version": str(ProjectSettings.get_setting("application/config/version", "")),
			"protocol": NetHandoff.PROTOCOL, "password": _mp_password.text})
	if err == OK: _set_waiting("Opening your game on the lobby server...")
	else: _fail_net("Could not reach the lobby server (error %d)." % err)

func _join_online() -> void:
	if _session != null or _lobby_list == null: return
	var sel := _lobby_list.get_selected_items()
	if sel.is_empty() or sel[0] >= _lobby_rooms.size():
		_mp_status.text = "Pick a game in the list first."
		return
	var r: Dictionary = _lobby_rooms[sel[0]]
	_start_session()
	var err := _session.start_relay_client(_server(), str(r.get("room", "")), _mp_password.text)
	if err == OK: _set_waiting("Joining %s..." % str(r.get("name", "the game")))
	else: _fail_net("Could not reach the lobby server (error %d)." % err)

func _host_game() -> void:
	if _session != null:
		return
	_start_session()
	var err := _session.start_host(NetworkSession.DEFAULT_PORT)
	if err == OK:
		# item 10: хост открывает лобби СРАЗУ, не дожидаясь подключения.
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
	for b: Button in [_mp_host_btn, _mp_join_btn, _mp_online_btn, _mp_join_online_btn]: b.disabled = true
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
	for b: Button in [_mp_host_btn, _mp_join_btn, _mp_online_btn, _mp_join_online_btn]: b.disabled = false
	_mp_cancel_btn.hide()

func _on_net_lost() -> void:
	_fail_net(_session.last_error if _session != null and _session.last_error != "" else "Connection lost.")

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

func _open_editor() -> void:
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _quit() -> void:
	get_tree().quit()
