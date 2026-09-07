extends Control

## Экран подготовки матча (между лобби и боем), по образцу isotope §12b.
## Настраивает GameConfig (карта, соперник/сложность, мирные, туман, бюджет,
## режим расстановки) и запускает Main.tscn. Свободная расстановка и point-buy —
## следующая фаза; сейчас режим Default собирает ростер как раньше.

const MAIN_SCENE := "res://scenes/Main.tscn"
const PLACEMENT_SCENE := "res://scenes/Placement.tscn"
const LOBBY_SCENE := "res://scenes/MainMenu.tscn"

var _map_opt: OptionButton
var _ai_check: CheckBox
var _ai_p1_check: CheckBox
var _diff_opt: OptionButton
var _civ_check: CheckBox
var _fog_opt: OptionButton
var _budget_spin: SpinBox
var _place_opt: OptionButton
var _place_note: Label
var _status: Label

var _map_paths: Array[String] = []   # индекс пункта → путь к карте ("" = демо)

## Строки, которые в сетевой партии прячутся: соперник — живой игрок, а расстановка
## всегда свободная (#99).
var _ai_row: Control
var _place_row: Control

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Match Setup"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	# Карта
	_map_opt = OptionButton.new()
	_populate_maps()
	vbox.add_child(_row("Map", _map_opt))

	# Соперник. Машиной может быть и первый игрок (#103) — тогда человек просто смотрит
	# бой ИИ против ИИ, что и нужно, чтобы проверять сам ИИ, а не играть с ним.
	_ai_p1_check = CheckBox.new()
	_ai_p1_check.text = "Player 1 is AI (AI vs AI)"
	_ai_p1_check.button_pressed = GameConfig.p1_is_ai
	vbox.add_child(_ai_p1_check)

	_ai_check = CheckBox.new()
	_ai_check.text = "Player 2 is AI"
	_ai_check.button_pressed = GameConfig.p2_is_ai
	_ai_check.toggled.connect(_on_ai_toggled)
	vbox.add_child(_ai_check)

	_diff_opt = OptionButton.new()
	for n in ["Easy", "Normal", "Hard"]:
		_diff_opt.add_item(n)
	_diff_opt.select(clampi(GameConfig.ai_difficulty, 0, 2))
	_ai_row = _row("AI difficulty", _diff_opt)
	vbox.add_child(_ai_row)

	# Мирные жители
	_civ_check = CheckBox.new()
	_civ_check.text = "Spawn civilians"
	_civ_check.button_pressed = GameConfig.civilians_enabled
	vbox.add_child(_civ_check)

	# Туман войны (item 46): три режима вместо прежней галочки.
	#   Off       — видно всё поле.
	#   Standard  — разведанный рельеф остаётся виден, чужие бойцы прячутся.
	#   Realistic — вне обзора не видно ничего.
	_fog_opt = OptionButton.new()
	for n in ["Off", "Standard", "Realistic"]:
		_fog_opt.add_item(n)
	_fog_opt.select(clampi(GameConfig.fog_mode, 0, 2))
	vbox.add_child(_row("Fog of war", _fog_opt))

	# Бюджет: верхний предел снят — можно ставить сколько угодно (фактически без лимита).
	_budget_spin = SpinBox.new()
	_budget_spin.min_value = 0
	_budget_spin.max_value = 1000000
	_budget_spin.allow_greater = true
	_budget_spin.step = 25
	_budget_spin.value = GameConfig.budget
	vbox.add_child(_row("Point budget per side (0 = unlimited)", _budget_spin))

	# Расстановка
	_place_opt = OptionButton.new()
	_place_opt.add_item("Default squads")
	_place_opt.add_item("Free placement")
	# Свободная расстановка — режим по умолчанию (#91).
	_place_opt.select(1)
	_place_opt.item_selected.connect(_on_place_selected)
	_place_row = _row("Placement", _place_opt)
	vbox.add_child(_place_row)

	_place_note = Label.new()
	_place_note.modulate = Color(0.7, 0.85, 1.0)
	_place_note.visible = false
	_place_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place_note.custom_minimum_size = Vector2(460, 0)
	_place_note.text = "Free placement: buy units within the point budget and deploy them by hand before the battle."
	vbox.add_child(_place_note)

	vbox.add_child(HSeparator.new())

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)
	var start_btn := Button.new()
	start_btn.text = "Start Match"
	start_btn.custom_minimum_size = Vector2(0, 44)
	start_btn.pressed.connect(_on_start)
	row.add_child(start_btn)
	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(0, 44)
	back_btn.pressed.connect(_on_back)
	row.add_child(back_btn)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.modulate = Color(0.7, 0.72, 0.78)
	vbox.add_child(_status)

	if hosting():
		# Хост объявляет условия за обоих (#99): соперник — живой игрок, а расстановка
		# всегда свободная, так что выбирать тут нечего.
		title.text = "Match Setup (Host)"
		start_btn.text = "Start Match for Both"
		back_btn.text = "Leave Match"
		_ai_check.hide()
		_ai_row.hide()
		_place_row.hide()
		_place_note.visible = true
		_status.text = "The other player is waiting for your settings."
		NetHandoff.session.disconnected.connect(_on_net_lost)

## Хост сетевой партии настраивает матч на этом же экране (#99).
func hosting() -> bool:
	return NetHandoff.session != null

func _on_net_lost() -> void:
	NetHandoff.discard()
	get_tree().change_scene_to_file(LOBBY_SCENE)

func _populate_maps() -> void:
	_map_paths = []
	_map_opt.add_item("Demo roster (built-in)")
	_map_paths.append("")
	for name in MapData.list_maps():
		_map_opt.add_item(name.get_basename())
		_map_paths.append(MapData.path_for(name))
	# Восстановить ранее выбранную карту, если она ещё есть.
	var idx := _map_paths.find(GameConfig.map_path)
	_map_opt.select(idx if idx >= 0 else 0)

func _row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(200, 0)
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

func _on_ai_toggled(_on: bool) -> void:
	pass

func _on_place_selected(idx: int) -> void:
	_place_note.visible = idx == 1

func _on_start() -> void:
	GameConfig.p1_is_ai = _ai_p1_check.button_pressed
	GameConfig.p2_is_ai = _ai_check.button_pressed
	GameConfig.ai_difficulty = _diff_opt.selected
	GameConfig.civilians_enabled = _civ_check.button_pressed
	GameConfig.fog_mode = _fog_opt.selected
	GameConfig.budget = int(_budget_spin.value)
	GameConfig.map_path = _map_paths[_map_opt.selected]
	GameConfig.free_placement = _place_opt.selected == 1

	# Сетевая партия: объявляем условия клиенту и оба уходим на закупку (#99).
	if hosting():
		# В сетевой партии обе стороны — живые люди по разные концы провода.
		GameConfig.p1_is_ai = false
		GameConfig.p2_is_ai = false
		GameConfig.free_placement = true
		var shared: MapData = MapData.blank_arena() if GameConfig.map_path == "" \
				else MapData.load_from(GameConfig.map_path)
		if shared == null:
			_status.text = "Could not load that map."
			return
		NetHandoff.session.send(NetHandoff.encode_setup(shared))
		NetHandoff.lobby_map = shared
		get_tree().change_scene_to_file(PLACEMENT_SCENE)
		return

	# Свободная расстановка: уходим на экран деплоя (он сам построит MapHandoff).
	if GameConfig.free_placement:
		if GameConfig.map_path != "" and MapData.load_from(GameConfig.map_path) == null:
			_status.text = "Could not load that map."
			return
		get_tree().change_scene_to_file(PLACEMENT_SCENE)
		return

	if GameConfig.map_path == "":
		MapHandoff.pending = null
	else:
		var map := MapData.load_from(GameConfig.map_path)
		if map == null:
			_status.text = "Could not load that map."
			return
		MapHandoff.pending = map
	get_tree().change_scene_to_file(MAIN_SCENE)

func _on_back() -> void:
	# Уйти из сетевой подготовки = разорвать связь: клиент так и ждал бы объявления (#99).
	if hosting():
		NetHandoff.discard()
	get_tree().change_scene_to_file(LOBBY_SCENE)
