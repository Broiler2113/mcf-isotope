class_name SettingsWindow
extends CanvasLayer

## Окно настроек (items 17 и 23): размер интерфейса и цвет акцента. Собрано по набору
## «MCF: Alert! UI kit» — окно с шапкой, вкладка, групповые окошки, ползунок с окошком
## значения, выпадающий список с образцом цвета и ряд кнопок справа внизу. Открывается
## из главного меню и из боя; настройки сохраняет Ui (user://settings.cfg) и применяет
## сразу — размер по отпусканию ползунка, чтобы окно не росло под курсором.

const SteamChrome = preload("res://src/ui/SteamChrome.gd")

var _scale_slider: HSlider
var _scale_value: Label
var _accent_opt: OptionButton
var _body: Control = null

static func open(host: Node) -> SettingsWindow:
	var w := SettingsWindow.new()
	host.add_child(w)
	return w

func _ready() -> void:
	layer = 90
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
	_scale_value = Label.new()
	_scale_value.custom_minimum_size = Vector2(52, 0)
	_scale_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.style_value_box(_scale_value)
	row.add_child(_scale_value)
	_scale_value.text = "%d%%" % int(_scale_slider.value)
	_scale_slider.value_changed.connect(func(v: float) -> void:
		_scale_value.text = "%d%%" % int(v))
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

	# --- Кнопки справа внизу, как у окна набора ---
	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 10)
	col.add_child(SteamChrome.pad(bottom, 16, 12))
	var reset := Button.new()
	reset.text = "Defaults"
	reset.custom_minimum_size = Vector2(100, 0)
	reset.pressed.connect(func() -> void:
		Ui.set_ui_scale(1.0)
		Ui.set_accent("green")
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

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		queue_free()
