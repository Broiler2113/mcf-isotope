class_name SettingsWindow
extends CanvasLayer

## Окно настроек (items 17 и 23): размер интерфейса и цвет акцента. Собрано по набору
## «MCF: Alert! UI kit» — окно с шапкой, вкладка, групповые окошки, ползунок с окошком
## значения, выпадающий список с образцом цвета и ряд кнопок справа внизу. Открывается
## из главного меню и из боя; настройки сохраняет Ui (user://settings.cfg) и применяет
## сразу — размер по отпусканию ползунка, чтобы окно не росло под курсором.

const SteamChrome = preload("res://src/ui/SteamChrome.gd")

var _scale_slider: HSlider
var _scale_value: LineEdit
var _accent_opt: OptionButton
var _body: Control = null
var _capture_action := ""
var _key_buttons: Dictionary = {}
var _key_message: Label
var _tabs: TabContainer
var _key_sections: TabContainer

static func open(host: Node) -> SettingsWindow:
	var w := SettingsWindow.new()
	host.add_child(w)
	return w

func _ready() -> void:
	layer = 90
	add_to_group("shortcut_modal")
	Keybinds.changed.connect(_refresh_keys)
	_build()

func _build() -> void:
	if _body != null:
		_body.queue_free()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_body = root
	# Затемнение под окном — и модальность: щелчок мимо окна никуда не проходит.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var win := PanelContainer.new()
	SteamChrome.apply_panel(win)
	win.custom_minimum_size = Vector2(520, 0)
	center.add_child(win)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	win.add_child(col)
	col.add_child(SteamChrome.header_bar("Settings"))

	var tabs := TabContainer.new()
	_tabs = tabs
	col.add_child(SteamChrome.pad(tabs, 8, 8))
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 18)
	var page_pad := SteamChrome.pad(page, 8, 12)
	page_pad.name = "Interface"   # имя ребёнка — подпись вкладки
	tabs.add_child(page_pad)

	# --- Размер интерфейса (item 17) ---
	var size_box := SteamChrome.group_box("Interface size")
	page.add_child(size_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 15)
	size_box.body.add_child(row)
	var lbl := Label.new()
	lbl.text = "Scale"
	lbl.custom_minimum_size = Vector2(110, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color("#b0b0b0"))
	row.add_child(lbl)
	_scale_slider = HSlider.new()
	_scale_slider.min_value = Ui.UI_SCALE_MIN * 100.0
	_scale_slider.max_value = Ui.UI_SCALE_MAX * 100.0
	_scale_slider.step = 5
	_scale_slider.value = Ui.ui_scale * 100.0
	_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scale_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_scale_slider)
	_scale_value = Ui.slider_entry(_scale_slider, func(v: float) -> String: return "%d%%" % int(v),
			_apply_scale)
	_scale_value.custom_minimum_size = Vector2(60, 0)
	row.add_child(_scale_value)
	# Применяем по отпусканию (и по клавиатуре): иначе окно росло бы прямо под мышью.
	_scale_slider.drag_ended.connect(func(_changed: bool) -> void: _apply_scale())
	_scale_slider.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventKey and e.pressed:
			_apply_scale.call_deferred())
	var hint := Label.new()
	hint.text = "Grows or shrinks every window, button and text together."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color("#8a8a8a"))
	size_box.body.add_child(hint)

	# --- Экран ---
	var disp_box := SteamChrome.group_box("Display")
	page.add_child(disp_box)
	var fs := CheckBox.new()
	fs.text = "Fullscreen"
	fs.button_pressed = Ui.fullscreen
	fs.toggled.connect(Ui.set_fullscreen)
	disp_box.body.add_child(fs)
	var lighting := CheckBox.new()
	lighting.text = "Dynamic lighting and shadows"
	lighting.tooltip_text = "Dark ambient lighting with destructible lamps, fire and effect lights. Visual only."
	lighting.button_pressed = Ui.dynamic_lighting
	lighting.toggled.connect(Ui.set_dynamic_lighting)
	disp_box.body.add_child(lighting)

	# --- Акцент (item 23) ---
	var acc_box := SteamChrome.group_box("Accent colour")
	page.add_child(acc_box)
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 12)
	acc_box.body.add_child(arow)
	var albl := Label.new()
	albl.text = "Colour"
	albl.custom_minimum_size = Vector2(110, 0)
	albl.add_theme_font_size_override("font_size", 12)
	albl.add_theme_color_override("font_color", Color("#b0b0b0"))
	arow.add_child(albl)
	_accent_opt = OptionButton.new()
	for t: String in Ui.ACCENT_LABELS:
		_accent_opt.add_item(t)
	_accent_opt.select(maxi(0, Ui.ACCENT_ORDER.find(Ui.accent_name)))
	_accent_opt.custom_minimum_size = Vector2(200, 0)
	_accent_opt.item_selected.connect(func(i: int) -> void:
		Ui.set_accent(Ui.ACCENT_ORDER[i])
		_build.call_deferred())   # образцы ниже окрашены при сборке — пересобираем окно
	arow.add_child(_accent_opt)
	var swatch := Panel.new()
	swatch.custom_minimum_size = Vector2(18, 18)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sw := StyleBoxTexture.new()
	sw.texture = ImageTexture.create_from_image(Ui.make_fill(Ui.palette()))
	sw.set_texture_margin_all(1)
	swatch.add_theme_stylebox_override("panel", sw)
	arow.add_child(swatch)
	# Образцы: всё, что красится акцентом, — сразу видно, как ляжет выбранный цвет.
	var demo := HBoxContainer.new()
	demo.add_theme_constant_override("separation", 20)
	acc_box.body.add_child(demo)
	var cb := CheckBox.new()
	cb.text = "Checkbox"
	cb.button_pressed = true
	demo.add_child(cb)
	var radio := CheckBox.new()
	radio.text = "Radio"
	radio.button_group = ButtonGroup.new()
	radio.button_pressed = true
	demo.add_child(radio)
	var bar := ProgressBar.new()
	bar.value = 68
	bar.custom_minimum_size = Vector2(150, 18)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	demo.add_child(bar)
	var status := Label.new()
	status.text = "[Status] Accent-coloured status text."
	Ui.style_status(status)
	acc_box.body.add_child(status)

	var grid_box := SteamChrome.group_box("Map grid")
	page.add_child(grid_box)
	var grid_toggle := CheckBox.new()
	grid_toggle.text = "Show grid"
	grid_toggle.button_pressed = Ui.grid_visible
	grid_box.body.add_child(grid_toggle)
	var grid_row := HBoxContainer.new()
	grid_box.body.add_child(grid_row)
	var opacity := HSlider.new()
	opacity.min_value = 0
	opacity.max_value = 100
	opacity.step = 1
	opacity.value = Ui.grid_opacity * 100.0
	opacity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_row.add_child(opacity)
	var amount := Label.new()
	amount.text = "Opacity: %d%%" % opacity.value
	grid_row.add_child(amount)
	grid_toggle.toggled.connect(func(on: bool) -> void: Ui.set_grid(on, opacity.value / 100.0))
	opacity.value_changed.connect(func(value: float) -> void:
		amount.text = "Opacity: %d%%" % value
		Ui.set_grid(grid_toggle.button_pressed, value / 100.0))

	_build_keybinds(tabs)

	# --- Кнопки справа внизу, как у окна набора ---
	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 10)
	col.add_child(SteamChrome.pad(bottom, 16, 12))
	var reset := Button.new()
	reset.text = "Defaults"
	reset.custom_minimum_size = Vector2(100, 0)
	reset.pressed.connect(func() -> void:
		if tabs.current_tab == 1:
			_capture_action = ""
			_key_message.text = Keybinds.reset_defaults()
			return
		Ui.set_dynamic_lighting(false)
		Ui.set_grid(true, 0.32)
		Ui.set_ui_scale(1.0)
		Ui.set_accent("green")
		Ui.set_fullscreen(false)
		_build.call_deferred())
	bottom.add_child(reset)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(100, 0)
	close.pressed.connect(queue_free)
	bottom.add_child(close)
	Ui.theme_canvas_layers()

func _apply_scale() -> void:
	Ui.set_ui_scale(_scale_slider.value / 100.0)

func _build_keybinds(tabs: TabContainer) -> void:
	_key_buttons.clear()
	var page := VBoxContainer.new()
	page.name = "Keybinds"
	tabs.add_child(page)
	_key_message = Label.new()
	_key_message.text = "Choose a shortcut, then press a key. Escape cancels."
	_key_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_key_message.custom_minimum_size.x = 450
	page.add_child(_key_message)
	var sections := TabContainer.new()
	_key_sections = sections
	page.add_child(sections)
	for section in ["game", "editor"]:
		var scroll := ScrollContainer.new()
		scroll.name = "In-game shortcuts" if section == "game" else "Map editor shortcuts"
		scroll.custom_minimum_size = Vector2(490, 350)
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sections.add_child(scroll)
		var box := SteamChrome.group_box("Actions" if section == "game" else "Tools and commands")
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(box)
		for entry: Dictionary in Keybinds.DEFINITIONS:
			if entry.section != section: continue
			var row := HBoxContainer.new()
			box.body.add_child(row)
			var title := Label.new()
			title.text = entry.label
			title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(title)
			var button := Button.new()
			button.custom_minimum_size.x = 155
			button.pressed.connect(func() -> void:
				_capture_action = entry.id
				_key_message.text = "Press a key for %s. Escape cancels." % entry.label
				_refresh_keys())
			row.add_child(button)
			_key_buttons[entry.id] = button
	_refresh_keys()

func show_keybinds(editor := false) -> void:
	_tabs.current_tab = 1
	_key_sections.current_tab = 1 if editor else 0

func _refresh_keys() -> void:
	for id: String in _key_buttons:
		var button: Button = _key_buttons[id]
		if is_instance_valid(button):
			button.text = "Press a key…" if id == _capture_action else Keybinds.label(id)

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if not _capture_action.is_empty():
		get_viewport().set_input_as_handled()
		if event.keycode == KEY_ESCAPE:
			_capture_action = ""
			_key_message.text = "Rebinding cancelled."
		else:
			var error := Keybinds.rebind(_capture_action, event)
			if error.is_empty():
				_capture_action = ""
				_key_message.text = "Shortcut saved."
			else:
				_key_message.text = error
		_refresh_keys()
	elif event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		queue_free()
