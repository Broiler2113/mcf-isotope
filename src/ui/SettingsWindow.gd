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
## The scrolling pages, sized to the screen together.
var _pages: Array[ScrollContainer] = []
const TAB_GENERAL := 0
const TAB_GRAPHICS := 1
const TAB_GAMEPLAY := 2
const TAB_KEYS := 3
const TAB_AUDIO := 4
var _key_sections: TabContainer
var _acceleration_status: Label
var _acceleration_detail: Label
var _performance_box: Control

static func open(host: Node) -> SettingsWindow:
	var w := SettingsWindow.new()
	host.add_child(w)
	return w

func _ready() -> void:
	layer = 90
	add_to_group("shortcut_modal")
	Keybinds.changed.connect(_refresh_keys)
	_build()
	get_viewport().size_changed.connect(_resize_pages)

func _resize_pages() -> void:
	var height := get_viewport().get_visible_rect().size.y
	for p: ScrollContainer in _pages:
		if is_instance_valid(p): p.custom_minimum_size.y = clampf(height - 200.0, 160.0, 480.0)

## A tab page that scrolls when the screen is short.
func _page(tabs: TabContainer, title: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	var pad := SteamChrome.pad(page, 8, 12)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(pad)
	tabs.add_child(scroll)
	_pages.append(scroll)
	_resize_pages()
	return page

func _group(page: VBoxContainer, title: String) -> VBoxContainer:
	var box := SteamChrome.group_box(title)
	page.add_child(box)
	return box.body

func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(130, 0)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color("#b0b0b0"))
	return l

func _check(box: Control, text: String, tip: String, on: bool, apply: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.button_pressed = on
	if apply.is_valid(): c.toggled.connect(apply)
	box.add_child(c)
	return c

## Name on the left, value on the right: every slider on every page reads the same.
func _slider(box: Control, text: String, lo: float, hi: float, step: float, value: float,
		fmt: String, tip: String, apply: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	row.add_child(_row_label(text))
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.value = value
	sl.tooltip_text = tip
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(sl)
	var amount := Label.new()
	amount.text = fmt % sl.value
	amount.custom_minimum_size = Vector2(60, 0)
	amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(amount)
	sl.value_changed.connect(func(v: float) -> void:
		amount.text = fmt % v
		apply.call(v))
	return sl

func _build() -> void:
	var previous_tab := _tabs.current_tab if is_instance_valid(_tabs) else 0
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
	_pages.clear()

	# Pages by topic (issues-13): one long Interface page had become a pile of everything.
	# --- General: the interface itself ---
	var page := _page(tabs, "General")
	var size_box := _group(page, "Interface")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	size_box.add_child(row)
	row.add_child(_row_label("Scale"))
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
	# --- Акцент (item 23) ---
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 10)
	size_box.add_child(arow)
	arow.add_child(_row_label("Accent color"))
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
	size_box.add_child(demo)
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
	status.text = "[Status] Accent-colored status text."
	Ui.style_status(status)
	size_box.add_child(status)

	var performance := SteamChrome.group_box("Performance")
	_performance_box = performance
	page.add_child(performance)
	_acceleration_status = Label.new()
	_acceleration_status.name = "NativeAccelerationStatus"
	_acceleration_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.style_status(_acceleration_status)
	performance.body.add_child(_acceleration_status)
	_acceleration_detail = Label.new()
	_acceleration_detail.name = "NativeAccelerationDetail"
	_acceleration_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_acceleration_detail.add_theme_font_size_override("font_size", 12)
	_acceleration_detail.add_theme_color_override("font_color", Color("#b0b0b0"))
	performance.body.add_child(_acceleration_detail)
	_refresh_acceleration()

	# --- Graphics: what the screen shows ---
	page = _page(tabs, "Graphics")
	var window_box := _group(page, "Window")
	_check(window_box, "Fullscreen", "", Ui.fullscreen, Ui.set_fullscreen)
	_check(window_box, "Show FPS counter",
			"Frames per second in the top right corner of the battle screen, beside the side panel.",
			Ui.show_fps, Ui.set_show_fps)
	var light_box := _group(page, "Lighting")
	_check(light_box, "Dynamic lighting and shadows",
			"Soft lights and shadows from lamps, fire, explosions and muzzle flashes. Walls stop light; low furniture, glass and open doors don't. Visual only: it never changes what anyone can see.",
			Ui.dynamic_lighting, Ui.set_dynamic_lighting)
	_slider(light_box, "Darkness", 0, 100, 5, Ui.light_darkness * 100.0, "%d%%",
			"How dark unlit ground is: 0% is daylight, 100% is pitch black.",
			func(v: float) -> void: Ui.set_light_darkness(v / 100.0))
	var board_box := _group(page, "Board")
	var grid_toggle := _check(board_box, "Show grid", "", Ui.grid_visible, Callable())
	var opacity := _slider(board_box, "Grid opacity", 0, 100, 1, Ui.grid_opacity * 100.0, "%d%%", "",
			func(v: float) -> void: Ui.set_grid(grid_toggle.button_pressed, v / 100.0))
	grid_toggle.toggled.connect(func(on: bool) -> void: Ui.set_grid(on, opacity.value / 100.0))
	_slider(board_box, "Stars", 0, 100, 5, Ui.star_density * 100.0, "%d%%",
			"How many stars fill space behind the board.",
			func(v: float) -> void: Ui.set_star_density(v / 100.0))
	_check(board_box, "Falling snow on winter maps",
			"Snowflakes drifting over winter maps, on the battle screen and in first person.",
			Ui.snowfall, Ui.set_snowfall)
	var crt_box := _group(page, "CRT filter")
	var crt := _check(crt_box, "CRT terminal filter",
			"Play as if through an old computer terminal: scanlines, a phosphor grille and dark tube corners.",
			Ui.crt_filter, Callable())
	var crt_sl := _slider(crt_box, "Intensity", 10, 100, 5, Ui.crt_strength * 100.0, "%d%%",
			"How strong the CRT filter is.",
			func(v: float) -> void: Ui.set_crt_strength(v / 100.0))
	crt_sl.editable = Ui.crt_filter
	crt.toggled.connect(func(on: bool) -> void:
		Ui.set_crt_filter(on)
		crt_sl.editable = on)

	# --- Gameplay ---
	page = _page(tabs, "Gameplay")
	var battle_box := _group(page, "Battle")
	_check(battle_box, "Autoroll dice", "Your rolls start on their own: no Roll button, no Enter to confirm.",
			Ui.autoroll_dice, Ui.set_autoroll_dice)
	# First person (fix-7 #9): field of view, mouse sensitivity and how far it draws.
	var fp_box := _group(page, "First person")
	_slider(fp_box, "Field of view", 50, 120, 1, Ui.fp_fov, "%d°", "Field of view in first person.",
			func(v: float) -> void: Ui.set_fp_view(v, Ui.fp_sensitivity))
	_slider(fp_box, "Mouse sensitivity", 5, 100, 1, Ui.fp_sensitivity * 100.0, "%d%%",
			"Mouse sensitivity in first person.",
			func(v: float) -> void: Ui.set_fp_view(Ui.fp_fov, v / 100.0))
	_slider(fp_box, "Render distance", Ui.FP_DISTANCE_MIN, Ui.FP_DISTANCE_MAX, 4, Ui.fp_render_distance, "%d m",
			"How far the first-person view renders the battlefield, in meters.",
			func(v: float) -> void: Ui.set_fp_render_distance(int(v)))
	var mp_box := _group(page, "Multiplayer")
	_check(mp_box, "Send desync reports",
			"When a multiplayer board goes out of sync, quietly send the developers one report per match: the game version, your OS and graphics card, the technical log, the combat log and the state of the board.",
			Ui.desync_reports, Ui.set_desync_reports)

	_build_keybinds(tabs)
	_build_audio(tabs)
	tabs.current_tab = mini(previous_tab, tabs.get_tab_count() - 1)

	# --- Кнопки справа внизу, как у окна набора ---
	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 10)
	col.add_child(SteamChrome.pad(bottom, 16, 12))
	var reset := Button.new()
	reset.text = "Defaults"
	reset.custom_minimum_size = Vector2(100, 0)
	reset.tooltip_text = "Reset the settings on this page."
	reset.pressed.connect(func() -> void:
		match tabs.current_tab:
			TAB_GENERAL:
				Ui.set_ui_scale(1.0)
				Ui.set_accent("green")
			TAB_GRAPHICS:
				Ui.set_fullscreen(false)
				Ui.set_show_fps(false)
				Ui.set_dynamic_lighting(true)
				Ui.set_light_darkness(0.75)
				Ui.set_grid(true, 0.32)
				Ui.set_star_density(0.3)
				Ui.set_snowfall(true)
				Ui.set_crt_filter(false)
				Ui.set_crt_strength(1.0)
			TAB_GAMEPLAY:
				Ui.set_autoroll_dice(false)
				Ui.set_fp_view(80.0, 0.25)
				Ui.set_fp_render_distance(Ui.FP_DISTANCE_DEFAULT)
				Ui.set_desync_reports(true)
			TAB_KEYS:
				_capture_action = ""
				_key_message.text = Keybinds.reset_defaults()
				return
			TAB_AUDIO:
				GameAudio.set_levels(0.8, 0.8, 0.7, false, true)
		_build.call_deferred())
	bottom.add_child(reset)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(100, 0)
	close.pressed.connect(queue_free)
	bottom.add_child(close)
	Ui.theme_canvas_layers()

func _refresh_acceleration(snapshot: Dictionary = {}) -> void:
	var status := NativeAcceleration.status() if snapshot.is_empty() else snapshot
	_acceleration_status.text = str(status.get("title", "C++ acceleration unavailable"))
	_acceleration_detail.text = str(status.get("detail", "The game uses standard processing."))

func _apply_scale() -> void:
	Ui.set_ui_scale(_scale_slider.value / 100.0)

func _build_audio(tabs: TabContainer) -> void:
	var page := VBoxContainer.new()
	page.name = "Audio"
	page.add_theme_constant_override("separation", 16)
	tabs.add_child(page)
	var group := SteamChrome.group_box("Sound")
	page.add_child(group)
	for setting: String in ["master", "sfx", "voice"]:
		var row := HBoxContainer.new()
		group.body.add_child(row)
		var label := Label.new()
		label.text = {"master": "Master", "sfx": "Sound effects", "voice": "Voice (SAM)"}[setting]
		label.custom_minimum_size.x = 130
		row.add_child(label)
		var slider := HSlider.new()
		slider.name = "Audio_" + setting
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 1
		slider.value = float(GameAudio.get(setting)) * 100
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(slider)
		var amount := Label.new()
		amount.text = "%d%%" % slider.value
		amount.custom_minimum_size.x = 42
		row.add_child(amount)
		slider.value_changed.connect(func(value: float) -> void:
			amount.text = "%d%%" % value
			GameAudio.set(setting, value / 100.0)
			GameAudio.set_levels(GameAudio.master, GameAudio.sfx, GameAudio.voice, GameAudio.muted, GameAudio.turn_voice))
	var mute := CheckBox.new()
	mute.name = "Audio_mute"
	mute.text = "Mute all audio"
	mute.button_pressed = GameAudio.muted
	mute.toggled.connect(func(on: bool) -> void:
		GameAudio.set_levels(GameAudio.master, GameAudio.sfx, GameAudio.voice, on, GameAudio.turn_voice))
	group.body.add_child(mute)
	var turns := CheckBox.new()
	turns.name = "Audio_turn_voice"
	turns.text = "Announce player turns"
	turns.button_pressed = GameAudio.turn_voice
	turns.toggled.connect(func(on: bool) -> void:
		GameAudio.set_levels(GameAudio.master, GameAudio.sfx, GameAudio.voice, GameAudio.muted, on))
	group.body.add_child(turns)

func _build_keybinds(tabs: TabContainer) -> void:
	_key_buttons.clear()
	# Вкладка прокручивается сама, если экран ниже неё (крупный интерфейс, 0.12): с клавиатурой
	# страница выше прежней, а окно настроек обязано помещаться целиком, с кнопками внизу.
	var page_scroll := ScrollContainer.new()
	page_scroll.name = "Keybinds"
	page_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page_scroll.custom_minimum_size = Vector2(0, clampf(get_viewport().get_visible_rect().size.y - 300.0, 280.0, 560.0))
	tabs.add_child(page_scroll)
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_scroll.add_child(page)
	_key_message = Label.new()
	_key_message.text = "Choose a shortcut, then press a key. Escape cancels."
	_key_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_key_message.custom_minimum_size.x = 450
	page.add_child(_key_message)
	var sections := TabContainer.new()
	sections.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_key_sections = sections
	page.add_child(sections)
	for section in ["game", "editor", "fp"]:
		# Сверху — клавиатура (0.12): что занято, что в сочетаниях, что свободно, с подсказкой
		# по наведению; под ней — прежний список с переназначением.
		var section_page := VBoxContainer.new()
		section_page.name = {"game": "In-game shortcuts", "editor": "Map editor shortcuts", "fp": "First-person controls"}[section]
		section_page.add_theme_constant_override("separation", 8)
		sections.add_child(section_page)
		if section == "fp":
			var look := Label.new()
			look.text = "Move the mouse to look around. Jump also climbs ledges and ascends in space or noclip."
			look.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			section_page.add_child(look)
		var kb_box := SteamChrome.group_box("Keyboard - hover a key to see what it does")
		section_page.add_child(kb_box)
		var kb := KeyboardDiagram.new()
		kb.section = section
		kb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		kb_box.body.add_child(kb)
		kb_box.body.add_child(_key_legend())
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(490, 110)
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		section_page.add_child(scroll)
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

## Подписи цветов под клавиатурой — те же цвета, что на клавишах.
func _key_legend() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	for pair in [[Ui.accent_color().darkened(0.25), "Used"],
			[KeyboardDiagram.COMBO_COLOR.darkened(0.3), "Used with Ctrl / Shift / Alt"],
			[KeyboardDiagram.FREE_COLOR, "Free"]]:
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 6)
		# Образец с рамкой, как клавиша: иначе «свободная» сливается с фоном окна.
		var sw := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = pair[0]
		sb.border_color = Color(0, 0, 0, 0.85)
		sb.set_border_width_all(1)
		sw.add_theme_stylebox_override("panel", sb)
		sw.custom_minimum_size = Vector2(16, 16)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		item.add_child(sw)
		var l := Label.new()
		l.text = str(pair[1])
		l.add_theme_font_size_override("font_size", 11)
		item.add_child(l)
		row.add_child(item)
	return row

func show_keybinds(editor := false) -> void:
	_tabs.current_tab = TAB_KEYS
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
			_key_message.text = "Rebinding canceled."
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
