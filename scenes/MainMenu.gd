extends Control

## Лобби — точка входа (по образцу isotope lobby). Две вкладки (#54):
##   • Single Player — новая игра, редактор карт, сохранённые карты.
##   • Multiplayer   — P2P по IP: связь налаживается ЗДЕСЬ и уезжает в бой готовой
##     сессией через NetHandoff. На боковой панели боя сетевых кнопок больше нет.

const SETUP_SCENE := "res://scenes/Setup.tscn"
const EDITOR_SCENE := "res://scenes/MapEditor.tscn"
const PLACEMENT_SCENE := "res://scenes/Placement.tscn"

var _saves_list: ItemList
var _map_names: PackedStringArray

# --- Мультиплеер ---
var _mp_ip: LineEdit
var _mp_status: Label
var _mp_host_btn: Button
var _mp_join_btn: Button
var _mp_cancel_btn: Button
var _session: NetworkSession = null

func _ready() -> void:
	# Уходя в меню, старую сессию не тащим — начинаем с чистого листа.
	NetHandoff.discard()

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

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

	var title := Label.new()
	title.text = "MCF Tactics"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	vbox.add_child(title)

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

	vbox.add_child(HSeparator.new())
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
		_set_waiting("Hosting on port %d — waiting for a player..." % NetworkSession.DEFAULT_PORT)
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
func _on_peer_ready(is_host: bool) -> void:
	NetHandoff.is_host = is_host
	GameConfig.p2_is_ai = false
	GameConfig.free_placement = true
	MapHandoff.pending = null
	if is_host:
		_mp_status.text = "Player joined — setting up the match..."
		NetHandoff.session = _session
		_session = null  # узел уходит дальше, из меню его больше не трогаем
		get_tree().change_scene_to_file(SETUP_SCENE)
		return
	_mp_status.text = "Connected — waiting for the host to set up the match..."
	_session.message.connect(_on_net_message)
	_session.attach()

## Клиент: пришли условия матча — принимаем их и уходим на закупку (#99).
func _on_net_message(msg: Dictionary) -> void:
	if _session == null or str(msg.get("k", "")) != NetHandoff.K_SETUP:
		return
	NetHandoff.apply_setup(msg)
	# Пока меняются сцены, входящие копятся в буфере сессии — Placement заберёт их
	# своим attach().
	_session.detach()
	_session.message.disconnect(_on_net_message)
	_session.disconnected.disconnect(_on_net_lost)
	NetHandoff.session = _session
	_session = null
	get_tree().change_scene_to_file(PLACEMENT_SCENE)

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

func _new_game() -> void:
	GameConfig.map_path = ""
	get_tree().change_scene_to_file(SETUP_SCENE)

func _on_map_activated(idx: int) -> void:
	if idx < 0 or idx >= _map_names.size():
		return
	GameConfig.map_path = MapData.path_for(_map_names[idx])
	get_tree().change_scene_to_file(SETUP_SCENE)

func _open_editor() -> void:
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _quit() -> void:
	get_tree().quit()
