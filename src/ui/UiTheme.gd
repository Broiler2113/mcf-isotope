extends Node

# =====================================================================
#  UiTheme - global "2003 Steam" interface skin  (autoload: Ui)
# =====================================================================
# Ported from Crazy Ball Runner 2D. Builds one Theme from the PNGs in
# res://interface_textures/ and hangs it on the root Window, so EVERY
# Control in EVERY menu inherits the gunmetal Steam look with no
# per-scene wiring. Textures come from the IMPORTED resource, with a raw
# disk read kept for a PNG the editor has not re-imported yet, so dropping
# a replacement still reskins the game from source (see _load_tex).
#
# Headless-safe: skipped entirely when there is no display server, so the
# sim/headless smoke tests are never touched.

const TEX_DIR := "res://interface_textures/"
## Подложенный игроком шрифт: ui_font.ttf или ui_font.otf (оба обещаны в
## HOW_TO_REPLACE_INTERFACE_TEXTURES.txt, §3).
const FONT_BASE := "res://interface_textures/ui_font"
const FONT_EXTS := ["ttf", "otf"]
const SLICE := 6          # 9-slice border, matches the 32px generated chrome
const FONT_FALLBACKS := ["Tahoma", "Verdana", "Geneva", "DejaVu Sans", "Arial", "Helvetica"]
## Знаковый шрифт — вторая очередь запасных (см. _font). Интерфейс рисует ✓, ✕, ▶, ◀, ▴, ▾,
## →, •, ⚠, ⟳, ░: в тексте этих знаков нет ни у Handjet, ни у Tahoma с Arial. Здесь перечислены
## шрифты, где они есть: на Windows — Segoe UI Symbol, на macOS — Apple Symbols, на Linux —
## DejaVu Sans и Noto.
const SYMBOL_FALLBACKS := ["Segoe UI Symbol", "Segoe UI", "Apple Symbols", "DejaVu Sans",
		"Noto Sans Symbols 2", "Symbola", "Arial Unicode MS"]
## Шрифт игры (0.9.2): слегка пиксельный Handjet (SIL OFL, fonts/OFL.txt). Файл — тот же
## Handjet с увеличенным на 16 % кеглем (меньше unitsPerEm): при прежних размерах (13 и
## т. д.) строчные такой же высоты, как у прежнего Tahoma, и раскладка окон не поехала.
const GAME_FONT := "res://fonts/handjet_ui.ttf"

# --- palette (gunmetal-gray "2003 Steam" skin) -----------------------
# item 8: серые части меню сделаны заметно темнее (примерно на четверть). Один и тот
# же сдвиг на всех трёх тонах сохраняет прежний контраст между окном, панелью и
# утопленным полем — темнеет вся серая гамма разом, а не отдельные её куски.
# Тёмный множитель на всю текстурную хромировку (item 8/18) — панели/кнопки/поля.
## Набор интерфейса (item 23) задаёт цвета хромировки точно — затемнять картинки больше не нужно.
const CHROME_MODULATE := Color(1, 1, 1)
const WINDOW_BG   := Color(0.170, 0.170, 0.170)
const PANEL_BG    := Color(0.235, 0.235, 0.235)
const SUNKEN_BG   := Color(0.125, 0.125, 0.125)
const HEADER_BG   := Color(0.118, 0.149, 0.125)
const TEXT        := Color(0.812, 0.812, 0.812)   # #cfcfcf — основной текст набора
const TEXT_BRIGHT := Color(0.95, 0.96, 0.93)
const TEXT_DIM    := Color(0.588, 0.588, 0.588)
const TEXT_ACCENT := Color(0.647, 0.741, 0.549)
const ACCENT      := Color(0.549, 0.635, 0.471)

## Акцентные палитры набора интерфейса (item 23): заливка прогресса (fill1/fill2), её кант
## (outline), текст и свечение строк состояния (text/glow), галочка и радио (check/checkGlow).
const PALETTES := {
	"green": {"fill1": Color("#6a9a6a"), "fill2": Color("#3a5a3a"), "outline": Color("#2a4a2a"),
		"text": Color("#8aaa8a"), "glow": Color("#2a4a2a"), "check": Color("#7a9c7a"), "check_glow": Color("#2a4a2a")},
	"blue": {"fill1": Color("#6a8aba"), "fill2": Color("#3a4a6a"), "outline": Color("#2a3a5a"),
		"text": Color("#8aaada"), "glow": Color("#2a3a6a"), "check": Color("#7a9aca"), "check_glow": Color("#2a3a6a")},
	"red": {"fill1": Color("#ba6a6a"), "fill2": Color("#6a3a3a"), "outline": Color("#5a2a2a"),
		"text": Color("#da8a8a"), "glow": Color("#6a2a2a"), "check": Color("#ca7a7a"), "check_glow": Color("#6a2a2a")},
	"yellow": {"fill1": Color("#baba6a"), "fill2": Color("#6a6a3a"), "outline": Color("#5a5a2a"),
		"text": Color("#dada8a"), "glow": Color("#6a6a2a"), "check": Color("#caca7a"), "check_glow": Color("#6a6a2a")},
	"purple": {"fill1": Color("#9a6aba"), "fill2": Color("#4a3a6a"), "outline": Color("#3a2a5a"),
		"text": Color("#ba8ada"), "glow": Color("#3a2a6a"), "check": Color("#aa7aca"), "check_glow": Color("#3a2a6a")},
	"cyan": {"fill1": Color("#6ababa"), "fill2": Color("#3a6a6a"), "outline": Color("#2a5a5a"),
		"text": Color("#8adada"), "glow": Color("#2a5a6a"), "check": Color("#7acaca"), "check_glow": Color("#2a5a6a")},
	"orange": {"fill1": Color("#ba8a6a"), "fill2": Color("#6a4a3a"), "outline": Color("#5a3a2a"),
		"text": Color("#daaa8a"), "glow": Color("#6a3a2a"), "check": Color("#ca9a7a"), "check_glow": Color("#6a3a2a")},
	"gray": {"fill1": Color("#9a9a9a"), "fill2": Color("#5a5a5a"), "outline": Color("#4a4a4a"),
		"text": Color("#b0b0b0"), "glow": Color("#4a4a4a"), "check": Color("#b0b0b0"), "check_glow": Color("#4a4a4a")},
}
const ACCENT_ORDER := ["green", "blue", "red", "yellow", "purple", "cyan", "orange", "gray"]
const ACCENT_LABELS := ["Green (default)", "Blue", "Red", "Yellow", "Purple", "Cyan", "Orange", "Gray"]
## Размер интерфейса (item 17): множитель content_scale_factor корневого окна — растёт всё
## разом, шрифты, кнопки и окна, без единого «съехавшего» элемента.
const UI_SCALE_MIN := 0.75
## Холст игры — 1280×720 (stretch canvas_items): на 150% это 853×480, больше — таблица
## слотов лобби и меню боя уже не помещаются.
const UI_SCALE_MAX := 1.5
const SETTINGS_PATH := "user://settings.cfg"

var theme: Theme
var accent_name := "green"
var ui_scale := 1.0
signal board_settings_changed
var grid_visible := true
var grid_opacity := 0.32
var fullscreen := false
var _pal: Dictionary = PALETTES["green"]

var _accent := ACCENT
var _text_accent := TEXT_ACCENT
var _header_bg := HEADER_BG

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_load_settings()
	get_tree().root.content_scale_factor = ui_scale
	if fullscreen:
		_apply_fullscreen()
	rebuild_theme()
	# Окна поверх игры (подтверждения, итог боя, оверлеи) живут на CanvasLayer, а тема по
	# цепочке владельцев за его границу не проходит. Раньше каждый такой вызов должен был
	# сам помнить про theme_canvas_layers(), и окно «Friendly units in the beam» забыло —
	# вышло со шрифтом и кнопками движка по умолчанию. Теперь тема цепляется сама к любому
	# Control, добавленному прямо под CanvasLayer.
	get_tree().node_added.connect(func(n: Node) -> void:
		if theme != null and n is Control and n.get_parent() is CanvasLayer \
				and (n as Control).theme == null:
			(n as Control).theme = theme)

## Настройки игрока (item 17/23): акцент и размер интерфейса — в user://settings.cfg.
func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	var a := str(cf.get_value("ui", "accent", "green"))
	if PALETTES.has(a):
		_set_palette(a)
	ui_scale = clampf(float(cf.get_value("ui", "scale", 1.0)), UI_SCALE_MIN, UI_SCALE_MAX)
	fullscreen = bool(cf.get_value("display", "fullscreen", false))
	grid_visible = bool(cf.get_value("board", "grid_visible", true))
	grid_opacity = clampf(float(cf.get_value("board", "grid_opacity", 0.32)), 0.0, 1.0)

func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	cf.set_value("ui", "accent", accent_name)
	cf.set_value("ui", "scale", ui_scale)
	cf.set_value("display", "fullscreen", fullscreen)
	cf.set_value("board", "grid_visible", grid_visible)
	cf.set_value("board", "grid_opacity", grid_opacity)
	cf.save(SETTINGS_PATH)

func set_grid(visible: bool, opacity: float) -> void:
	grid_visible = visible
	grid_opacity = clampf(opacity, 0.0, 1.0)
	_save_settings()
	board_settings_changed.emit()

func grid_color() -> Color:
	return Color(0, 0, 0, grid_opacity if grid_visible else 0.0)

func _set_palette(name: String) -> void:
	accent_name = name
	_pal = PALETTES[name]
	_accent = _pal["check"]
	_text_accent = _pal["text"]

## Сменить акцент (item 23): тема пересобирается, и все окна берут новый цвет сразу.
func set_accent(name: String) -> void:
	if not PALETTES.has(name):
		return
	_set_palette(name)
	_save_settings()
	rebuild_theme()

## Сменить размер интерфейса (item 17).
func set_ui_scale(s: float) -> void:
	ui_scale = clampf(s, UI_SCALE_MIN, UI_SCALE_MAX)
	_save_settings()
	if DisplayServer.get_name() != "headless":
		get_tree().root.content_scale_factor = ui_scale

## Полный экран (настройки → Display). Выключенный — обратно в развёрнутое окно, как в
## project.godot (window/size/mode=2), а не в маленькое 1280×720.
func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_save_settings()
	_apply_fullscreen()

func _apply_fullscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen
			else DisplayServer.WINDOW_MODE_MAXIMIZED)

func palette() -> Dictionary:
	return _pal

# =====================================================================
#  Фоновый прогрев сцен (ускорение запуска)
# =====================================================================
## Сцены, которые надо скомпилировать заранее, — по одной: два параллельных фоновых
## запроса компилируют общие скрипты одновременно, и раз на десяток запусков это
## заканчивалось «Parse Error» уже готовой сцены боя. Очередь живёт в автозагрузке, а не
## в меню: уйди игрок из меню на середине — прогрев доведётся до конца.
var _warm: Array = []
var _warm_resources: Dictionary = {}

func warm_up(paths: Array) -> void:
	# Headless simulations never switch visible scenes; compiling them in the
	# background only adds work and can still be running when a short test exits.
	if DisplayServer.get_name() == "headless":
		return
	for p: String in paths:
		if not _warm.has(p) and not _warm_resources.has(p):
			_warm.append(p)
	set_process(true)

func _process(_delta: float) -> void:
	if _warm.is_empty():
		set_process(false)
		return
	var p: String = _warm[0]
	match ResourceLoader.load_threaded_get_status(p):
		ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			if ResourceLoader.has_cached(p):
				_warm_resources[p] = ResourceLoader.load(p)
				_warm.pop_front()      # уже загружена обычным путём
			else:
				ResourceLoader.load_threaded_request(p)
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			pass
		ResourceLoader.THREAD_LOAD_LOADED:
			_warm_resources[p] = ResourceLoader.load_threaded_get(p)
			_warm.pop_front()
		_:
			_warm.pop_front()

func _exit_tree() -> void:
	# Finish an active request before the engine tears down script resources.
	# Waiting happens only on exit, never while the player is using the menu.
	for p: String in _warm:
		var status := ResourceLoader.load_threaded_get_status(p)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS \
				or status == ResourceLoader.THREAD_LOAD_LOADED:
			ResourceLoader.load_threaded_get(p)
	_warm.clear()

func rebuild_theme() -> void:
	if DisplayServer.get_name() == "headless":
		return
	theme = _build()
	get_tree().root.theme = theme
	theme_canvas_layers()

# Re-apply the current theme to every Control directly under a CanvasLayer
# (theme-owner chain stops at the CanvasLayer boundary). Public so freshly
# created CanvasLayer-based UIs (in-game HUD, editor toolbars) can pull the
# skin in from their own _ready.
func theme_canvas_layers() -> void:
	if theme == null or DisplayServer.get_name() == "headless":
		return
	_apply_canvas_layer_theme(get_tree().root)

func _apply_canvas_layer_theme(n: Node) -> void:
	for c in n.get_children():
		if c is CanvasLayer:
			for gc in c.get_children():
				if gc is Control:
					(gc as Control).theme = theme
		_apply_canvas_layer_theme(c)

func accent_color() -> Color:
	return _accent

func text_accent_color() -> Color:
	return _text_accent

func header_color() -> Color:
	return _header_bg

## Шапка окна набора (.window-title): серый градиент, без окраски акцентом.
func header_box(pad_h: int = 0, pad_v: int = 0) -> StyleBox:
	return _sb("header", pad_h, pad_v)

## Наведение — светлее та же серая кнопка (свой PNG), акцентом не красится: в наборе
## акцент только у галочек, прогресса и строк состояния.
func _sb_hover(name: String, pad_h: int, pad_v: int) -> StyleBox:
	return _sb(name, pad_h, pad_v)

# =====================================================================
#  Theme construction
# =====================================================================
func _build() -> Theme:
	var t := Theme.new()
	var font := _font()
	_ui_font = font
	_bold_cache = null
	t.default_font = font
	t.default_font_size = 13
	# Строки, что рисуются прямо на холсте (номера зон, метки бойцов), берут шрифт
	# движка по умолчанию — пусть и это будет шрифт игры.
	ThemeDB.fallback_font = font

	# ---- Label -------------------------------------------------------
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.55))
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)

	# ---- Panels ------------------------------------------------------
	var panel := _sb("panel", 8, 8)
	t.set_stylebox("panel", "Panel", panel)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "TabContainer", panel)
	t.set_stylebox("bg", "ScrollContainer", _sb("panel_sunken", 2, 2))

	# ---- Button ------------------------------------------------------
	var b_norm := _sb("button_normal", 14, 7)
	var b_hover := _sb_hover("button_hover", 14, 7)
	var b_press := _sb("button_pressed", 14, 7)
	var b_dis := _sb("button_disabled", 14, 7)
	for cls in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", cls, b_norm)
		t.set_stylebox("hover", cls, b_hover)
		t.set_stylebox("pressed", cls, b_press)
		t.set_stylebox("focus", cls, StyleBoxEmpty.new())
		t.set_stylebox("disabled", cls, b_dis)
		t.set_color("font_color", cls, Color("#e0e0e0"))
		t.set_color("font_hover_color", cls, TEXT_BRIGHT)
		t.set_color("font_pressed_color", cls, Color("#b0b0b0"))
		t.set_color("font_focus_color", cls, Color("#e0e0e0"))
		t.set_color("font_disabled_color", cls, TEXT_DIM)
		t.set_color("font_outline_color", cls, Color(0, 0, 0))
	# Выпадающий список набора (select) — утопленное поле, а не выпуклая кнопка.
	t.set_stylebox("normal", "OptionButton", _sb("select_normal", 8, 4))
	t.set_stylebox("hover", "OptionButton", _sb("select_hover", 8, 4))
	t.set_stylebox("pressed", "OptionButton", _sb("select_hover", 8, 4))
	t.set_stylebox("disabled", "OptionButton", _sb("select_normal", 8, 4))
	t.set_color("font_color", "OptionButton", Color("#d0d0d0"))

	# ---- CheckBox / CheckButton -------------------------------------
	# Галочка и радио — цветом акцента (item 23), рисуются здесь же под выбранную палитру.
	var chk_on := ImageTexture.create_from_image(make_check(_pal, true))
	var chk_off := _load_tex("check_off")
	var radio_on := ImageTexture.create_from_image(make_radio(_pal, true))
	var radio_off := ImageTexture.create_from_image(make_radio(_pal, false))
	for cls in ["CheckBox", "CheckButton"]:
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			t.set_stylebox(st, cls, StyleBoxEmpty.new())
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_hover_color", cls, TEXT_BRIGHT)
		t.set_color("font_pressed_color", cls, _text_accent)
		if chk_on and chk_off:
			t.set_icon("checked", cls, chk_on)
			t.set_icon("unchecked", cls, chk_off)
			t.set_icon("checked_disabled", cls, chk_on)
			t.set_icon("unchecked_disabled", cls, chk_off)
			t.set_icon("checked_mirrored", cls, chk_on)
			t.set_icon("unchecked_mirrored", cls, chk_off)
		t.set_icon("radio_checked", cls, radio_on)
		t.set_icon("radio_unchecked", cls, radio_off)
		t.set_icon("radio_checked_disabled", cls, radio_on)
		t.set_icon("radio_unchecked_disabled", cls, radio_off)
		t.set_color("font_color", cls, Color("#b8b8b8"))
		# В наборе акцентом красится только сама галочка, подпись остаётся серой.
		t.set_color("font_pressed_color", cls, Color("#b8b8b8"))
		t.set_color("font_hover_pressed_color", cls, TEXT_BRIGHT)

	# ---- LineEdit / TextEdit ----------------------------------------
	var field := _sb("field", 8, 5)
	for cls in ["LineEdit", "TextEdit", "CodeEdit"]:
		t.set_stylebox("normal", cls, field)
		t.set_stylebox("focus", cls, _sb("field", 8, 5))
		t.set_stylebox("read_only", cls, _sb("panel_sunken", 8, 5))
		t.set_color("font_color", cls, TEXT_BRIGHT)
		t.set_color("font_readonly_color", cls, TEXT_DIM)
		t.set_color("caret_color", cls, _text_accent)
		t.set_color("selection_color", cls, _accent * Color(1, 1, 1, 0.55))

	# ---- Tabs --------------------------------------------------------
	var tab_on := _sb("tab_active", 14, 6)
	var tab_off := _sb("tab_inactive", 14, 6)
	for cls in ["TabContainer", "TabBar"]:
		t.set_stylebox("tab_selected", cls, tab_on)
		t.set_stylebox("tab_hovered", cls, tab_on)
		t.set_stylebox("tab_unselected", cls, tab_off)
		t.set_stylebox("tab_disabled", cls, tab_off)
		t.set_color("font_selected_color", cls, TEXT_BRIGHT)
		t.set_color("font_unselected_color", cls, TEXT_DIM)
		t.set_color("font_hovered_color", cls, TEXT)

	# ---- ProgressBar -------------------------------------------------
	var pbg := _sb("progress_bg", 2, 2)
	t.set_stylebox("background", "ProgressBar", pbg)
	t.set_stylebox("fill", "ProgressBar", _tex_box(make_fill(_pal), 2, 0, 0))
	t.set_color("font_color", "ProgressBar", TEXT_BRIGHT)

	# ---- Tab bar ------------------------------------------------------
	var tab_bar := StyleBoxFlat.new()
	tab_bar.bg_color = Color("#252525")
	tab_bar.border_color = Color("#3a3a3a")
	tab_bar.border_width_bottom = 2
	tab_bar.content_margin_left = 6
	tab_bar.content_margin_top = 6
	t.set_stylebox("tabbar_background", "TabContainer", tab_bar)

	# ---- Sliders (набор: тонкий утопленный рельс и выпуклая ручка, без заливки) ----
	var s_track := _tex_box(_load_tex("slider_track").get_image() if _load_tex("slider_track") else null, 1, 0, 2)
	var s_fill := StyleBoxEmpty.new()
	for cls in ["HSlider", "VSlider"]:
		t.set_stylebox("slider", cls, s_track)
		t.set_stylebox("grabber_area", cls, s_fill)
		t.set_stylebox("grabber_area_highlight", cls, s_fill)
		var grab := _load_tex("slider_grabber")
		if grab:
			t.set_icon("grabber", cls, grab)
			t.set_icon("grabber_highlight", cls, grab)
			t.set_icon("grabber_disabled", cls, grab)

	# ---- ScrollBars --------------------------------------------------
	# Ширину полосе прокрутки задают поля стиля: при нулевых она выходила нулевой — видимой
	# формально, но невидимой и неуловимой мышью во всех окнах игры (item 19).
	var scroll_track := _sb("scroll_track", 6, 6)
	var grab_norm := _sb("scroll_grabber", 6, 6)
	var grab_hl := _sb("scroll_grabber_hl", 6, 6)
	for cls in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", cls, scroll_track)
		t.set_stylebox("scroll_focus", cls, scroll_track)
		t.set_stylebox("grabber", cls, grab_norm)
		t.set_stylebox("grabber_highlight", cls, grab_hl)
		t.set_stylebox("grabber_pressed", cls, grab_hl)

	# ---- Popups / lists / trees -------------------------------------
	for cls in ["PopupMenu", "ItemList", "Tree"]:
		t.set_stylebox("panel", cls, _sb("panel_sunken", 4, 4))
		t.set_color("font_color", cls, TEXT)
	var sel := make_selection(_pal)
	t.set_stylebox("hover", "PopupMenu", _tex_box(sel, 1, 4, 2))
	t.set_color("font_hover_color", "PopupMenu", TEXT_BRIGHT)
	t.set_stylebox("selected", "ItemList", _tex_box(sel, 1, 2, 2))
	t.set_stylebox("selected_focus", "ItemList", _tex_box(sel, 1, 2, 2))
	t.set_stylebox("selected", "Tree", _tex_box(sel, 1, 2, 2))

	# ---- SpinBox -----------------------------------------------------
	var up := _load_tex("arrow_up")
	var down := _load_tex("arrow_down")
	if up and down:
		t.set_icon("up", "SpinBox", up)
		t.set_icon("up_hover", "SpinBox", up)
		t.set_icon("up_pressed", "SpinBox", up)
		t.set_icon("up_disabled", "SpinBox", up)
		t.set_icon("down", "SpinBox", down)
		t.set_icon("down_hover", "SpinBox", down)
		t.set_icon("down_pressed", "SpinBox", down)
		t.set_icon("down_disabled", "SpinBox", down)
	t.set_stylebox("up_background", "SpinBox", _sb("button_normal", 2, 2))
	t.set_stylebox("up_background_hovered", "SpinBox", _sb_hover("button_hover", 2, 2))
	t.set_stylebox("up_background_pressed", "SpinBox", _sb("button_pressed", 2, 2))
	t.set_stylebox("down_background", "SpinBox", _sb("button_normal", 2, 2))
	t.set_stylebox("down_background_hovered", "SpinBox", _sb_hover("button_hover", 2, 2))
	t.set_stylebox("down_background_pressed", "SpinBox", _sb("button_pressed", 2, 2))

	# ---- Separators --------------------------------------------------
	for cls in ["HSeparator", "VSeparator"]:
		var sep := StyleBoxLine.new()
		sep.color = Color("#1a1a1a")   # .divider набора
		sep.thickness = 2
		sep.vertical = cls == "VSeparator"
		t.set_stylebox("separator", cls, sep)

	# ---- Windows / dialogs -------------------------------------------
	var dlg_panel := _sb("panel", 10, 10)
	for cls in ["AcceptDialog", "ConfirmationDialog", "FileDialog", "PopupPanel", "PopupDialog", "Window"]:
		t.set_stylebox("panel", cls, dlg_panel)
	t.set_stylebox("embedded_border", "Window", header_box(8, 8))
	t.set_stylebox("embedded_unfocused_border", "Window", header_box(8, 8))
	t.set_color("title_color", "Window", TEXT_BRIGHT)
	t.set_font_size("title_font_size", "Window", 15)
	t.set_constant("title_height", "Window", 28)
	t.set_constant("margin_left", "AcceptDialog", 12)
	t.set_constant("margin_right", "AcceptDialog", 12)
	t.set_constant("margin_top", "AcceptDialog", 12)
	t.set_constant("margin_bottom", "AcceptDialog", 12)

	# ---- Tooltips ----------------------------------------------------
	t.set_stylebox("panel", "TooltipPanel", _sb("panel_sunken", 6, 4))
	t.set_color("font_color", "TooltipLabel", TEXT_BRIGHT)

	return t

# =====================================================================
#  Helpers
# =====================================================================
func _font() -> Font:
	var dropped := _font_file()
	if dropped != null:
		return dropped
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(FONT_FALLBACKS)
	sf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	var game := load(GAME_FONT) as FontFile if ResourceLoader.exists(GAME_FONT) else null
	if game == null:
		return sf
	# Пиксельный шрифт — без хинтинга и дробных позиций: штрихи остаются на сетке.
	game.hinting = TextServer.HINTING_NONE
	game.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	# Чего в Handjet нет — системным шрифтом, и ДВУМЯ очередями. SystemFont берёт ПЕРВОЕ
	# найденное имя из списка, а не перебирает их по глифу: на Windows это Tahoma, и ✓, ✕,
	# ▶, ⚠, ⟳ в ней просто отсутствуют — на их месте пустые квадраты. У нас на Linux первой
	# в списке оказывалась DejaVu Sans, где эти знаки есть, поэтому мы ничего не замечали.
	# Поэтому за текстовым шрифтом идёт отдельный ЗНАКОВЫЙ.
	game.fallbacks = [sf, _symbol_font()]
	# Пробел у Handjet узкий — слова слипались («Turn-basedtactics»); чуть шире.
	var fv := FontVariation.new()
	fv.base_font = game
	fv.spacing_space = 2
	return fv

## Вторая очередь запасных: шрифт со знаками (см. SYMBOL_FALLBACKS). allow_system_fallback
## оставлен включённым — если в системе нет и этих, пусть движок ищет сам.
func _symbol_font() -> SystemFont:
	var sym := SystemFont.new()
	sym.font_names = PackedStringArray(SYMBOL_FALLBACKS)
	sym.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return sym

## Жирное начертание шрифта игры: у Handjet настоящая ось веса, а не обводка.
var _bold_cache: FontVariation = null
func bold_font() -> Font:
	if _bold_cache == null:
		_bold_cache = FontVariation.new()
		var base := get_ui_font()
		if base is FontVariation and (base as FontVariation).base_font is FontFile:
			# Жирный Handjet по оси веса; буквам — точку воздуха, иначе они сливаются.
			var ts := TextServerManager.get_primary_interface()
			_bold_cache.base_font = (base as FontVariation).base_font
			_bold_cache.variation_opentype = {ts.name_to_tag("wght"): 650}
			_bold_cache.spacing_space = 2
			_bold_cache.spacing_glyph = 1
		else:
			_bold_cache.base_font = base
			_bold_cache.variation_embolden = 0.55
	return _bold_cache

var _tex_cache: Dictionary = {}
var _ui_font: Font = null

func get_ui_font() -> Font:
	if _ui_font == null:
		_ui_font = _font()
	return _ui_font

func get_texture(name: String) -> Texture2D:
	return _load_tex(name)

## Подложенный игроком шрифт, если он есть. Порядок тот же, что у картинок.
##
## Раньше здесь стоял голый FileAccess.file_exists + load_dynamic_font, и в СОБРАННОЙ
## игре это значило «шрифта нет»: сырого .ttf в .pck не лежит, а импортированный
## никто не спрашивал. Игрок, подложивший свой шрифт, видел его из редактора и терял
## в сборке — молча, с откатом на системный Tahoma.
func _font_file() -> Font:
	for ext: String in FONT_EXTS:
		var path: String = FONT_BASE + "." + ext
		if _raw_is_newer(path):
			var fresh := FontFile.new()
			if fresh.load_dynamic_font(path) == OK:
				return fresh
		if ResourceLoader.exists(path):
			var res := ResourceLoader.load(path) as Font
			if res != null:
				return res
		if FileAccess.file_exists(path):
			var raw := FontFile.new()
			if raw.load_dynamic_font(path) == OK:
				return raw
	return null

## Картинка интерфейса по имени.
##
## Порядок попыток ОБРАТЕН прежнему, и это главное здесь. Раньше первым шёл сырой файл
## с диска (Image.load), а импортированный ресурс лежал в запасных. Движок на это
## честно ругался — «Loaded resource as image file, this will not work on export», —
## и работало оно лишь по случайности: в .pck сырого PNG нет, file_exists() отвечает
## «нет», и мы сваливались в запасную ветку. Стоило бы экспорту прихватить PNG как
## обычный файл, и ВЕСЬ интерфейс поехал бы мимо импорта — без сжатия, без настроек
## фильтра, с лишней распаковкой на старте.
##
## Теперь главный — импортированный ресурс. Обещание из
## HOW_TO_REPLACE_INTERFACE_TEXTURES.txt (§4: «подменил PNG, запустил из исходников —
## видно сразу, без переимпорта») при этом цело: редактор, разобрав картинку,
## переписывает её .import, поэтому «PNG новее своего .import» — это ровно «положили
## и ещё не разобрали», и такой файл читается с диска. В собранной игре рядом нет ни
## PNG, ни .import, и эта ветка не оживает никогда.
func _load_tex(name: String) -> Texture2D:
	if _tex_cache.has(name):
		return _tex_cache[name]
	var path := TEX_DIR + name + ".png"
	var tex: Texture2D = null
	if _raw_is_newer(path):
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	if tex == null and ResourceLoader.exists(path):
		var res := ResourceLoader.load(path) as Texture2D
		if res != null:
			tex = res
	# Последняя попытка: .import на месте, а разобранного файла нет (свежий клон без
	# .godot/, запуск мимо редактора). Лучше картинка без импорта, чем серый квадрат.
	if tex == null and FileAccess.file_exists(path):
		var img_raw := Image.new()
		if img_raw.load(path) == OK:
			tex = ImageTexture.create_from_image(img_raw)
	_tex_cache[name] = tex
	return tex

## Лежит ли на диске файл СВЕЖЕЕ своего разбора: сам он есть, а .import старше его
## (или .import нет вовсе). Это и значит «положили своё, редактор ещё не видел».
static func _raw_is_newer(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var imported := path + ".import"
	if not FileAccess.file_exists(imported):
		return true
	return FileAccess.get_modified_time(path) > FileAccess.get_modified_time(imported)

func _sb(name: String, pad_h: int, pad_v: int) -> StyleBox:
	var tex := _load_tex(name)
	if tex == null:
		var flat := StyleBoxFlat.new()
		flat.bg_color = PANEL_BG
		flat.border_color = Color(0.08, 0.08, 0.08)
		flat.set_border_width_all(1)
		flat.content_margin_left = pad_h
		flat.content_margin_right = pad_h
		flat.content_margin_top = pad_v
		flat.content_margin_bottom = pad_v
		return flat
	var sb := StyleBoxTexture.new()
	sb.texture = tex
	sb.set_texture_margin_all(SLICE)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	# Затемняем ВСЮ текстурную хромировку (item 8/18): панели, кнопки, поля идут
	# картинками-9-слайсами, поэтому правка цветовых констант их не трогала совсем —
	# кнопки оставались светлыми. Тёмный modulate гасит их разом. Ховер/акцент ставят
	# свой modulate позже и этот перекрывают.
	sb.modulate_color = CHROME_MODULATE
	return sb

## Картинка → StyleBoxTexture с фаской в margin пикселей (без затемнения).
func _tex_box(img: Image, margin: int, pad_h: int, pad_v: int) -> StyleBox:
	if img == null:
		return StyleBoxEmpty.new()
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	sb.set_texture_margin_all(margin)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb

# =====================================================================
#  Акцентные части набора (item 23) — рисуются под палитру
# =====================================================================
## Флажок 16×16: утопленный квадрат и, если on, галочка ✓ цветом check со свечением.
func make_check(pal: Dictionary, on: bool) -> Image:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	_bevel(img, Color("#1e1e1e"), Color("#0a0a0a"), Color("#6a6a6a"))
	if on:
		var pts := [Vector2i(3, 8), Vector2i(4, 9), Vector2i(5, 10), Vector2i(6, 11), Vector2i(7, 10),
				Vector2i(8, 9), Vector2i(9, 8), Vector2i(10, 7), Vector2i(11, 6), Vector2i(12, 5), Vector2i(13, 4)]
		for p: Vector2i in pts:
			for d in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1)]:
				var q: Vector2i = p + d
				if q.x > 0 and q.y > 0 and q.x < 15 and q.y < 15 and img.get_pixel(q.x, q.y).a > 0.0 \
						and img.get_pixel(q.x, q.y) == Color("#1e1e1e"):
					img.set_pixel(q.x, q.y, pal["check_glow"])
		for p: Vector2i in pts:
			img.set_pixel(p.x, p.y, pal["check"])
			img.set_pixel(p.x, p.y - 1, pal["check"])
	return img

## Радио 16×16: утопленный круг и точка 8 px цветом check.
func make_radio(pal: Dictionary, on: bool) -> Image:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	var c := Vector2(7.5, 7.5)
	for y in 16:
		for x in 16:
			var d := Vector2(x, y).distance_to(c)
			if d <= 7.5:
				var edge := d > 6.5
				var col := Color("#1e1e1e")
				if edge:
					col = Color("#0a0a0a") if (x + y) < 15 else Color("#6a6a6a")
				img.set_pixel(x, y, col)
			if on and d <= 4.0:
				img.set_pixel(x, y, pal["check"] if d <= 3.2 else pal["check_glow"])
	return img

## Заливка прогресса: градиент fill1 → fill2, кант outline и блик сверху (.progress-fill).
func make_fill(pal: Dictionary) -> Image:
	var img := Image.create(16, 14, false, Image.FORMAT_RGBA8)
	for y in 14:
		var col: Color = (pal["fill1"] as Color).lerp(pal["fill2"], float(y) / 13.0)
		for x in 16:
			img.set_pixel(x, y, col)
	for x in 16:
		img.set_pixel(x, 1, img.get_pixel(x, 1).lerp(Color.WHITE, 0.15))
		img.set_pixel(x, 0, pal["outline"])
		img.set_pixel(x, 13, pal["outline"])
	for y in 14:
		img.set_pixel(0, y, pal["outline"])
		img.set_pixel(15, y, pal["outline"])
	return img

## Подсветка выбранной строки списка: полупрозрачный fill2 с кантом fill1.
func make_selection(pal: Dictionary) -> Image:
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	var body: Color = pal["fill2"]
	body.a = 0.85
	img.fill(body)
	for i in 8:
		for p in [Vector2i(i, 0), Vector2i(i, 7), Vector2i(0, i), Vector2i(7, i)]:
			img.set_pixel(p.x, p.y, pal["fill1"])
	return img

func _bevel(img: Image, body: Color, tl: Color, br: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	img.fill(body)
	for x in w:
		img.set_pixel(x, 0, tl)
		img.set_pixel(x, h - 1, br)
	for y in h:
		img.set_pixel(0, y, tl)
		img.set_pixel(w - 1, y, br)

# =====================================================================
#  Готовые оформления элементов набора
# =====================================================================
## Бывший моноширинный Courier (строки состояния, окошки значений) убран из игры по
## просьбе игрока (0.9.2): там теперь жирный шрифт игры цветом акцента.
func mono_font() -> Font:
	return bold_font()

## Окошко значения у ползунка (.slider-value): утопленное, жирный моноширинный шрифт.
func style_value_box(lbl: Label) -> void:
	lbl.add_theme_stylebox_override("normal", _sb("panel_sunken", 6, 3))
	lbl.add_theme_font_override("font", mono_font())
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", _pal["text"])

## То же окошко, но в него можно ВПЕЧАТАТЬ число (batch ui-drones): Enter или уход фокуса
## ставят ползунок на введённое значение (в его пределах и с его шагом). Понимает «12»,
## «12%» и «none» (= 0). fmt — подпись значения, как у обычного окошка; on_commit — что
## сделать после ввода (у масштаба интерфейса применение идёт не по каждому сдвигу).
func slider_entry(s: Range, fmt: Callable, on_commit: Callable = Callable()) -> LineEdit:
	var e := LineEdit.new()
	for st in ["normal", "focus", "read_only"]:
		e.add_theme_stylebox_override(st, _sb("panel_sunken", 6, 3))
	e.add_theme_font_override("font", mono_font())
	e.add_theme_font_size_override("font_size", 12)
	e.add_theme_color_override("font_color", _pal["text"])
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER
	e.select_all_on_focus = true
	e.context_menu_enabled = false
	e.text = fmt.call(s.value)
	s.value_changed.connect(func(v: float) -> void:
		if not e.has_focus():
			e.text = fmt.call(v))
	var commit := func() -> void:
		var t := e.text.strip_edges().to_lower().replace("%", "").replace("×", "")
		if t == "none":
			t = "0"
		if t.is_valid_float():
			s.value = clampf(t.to_float(), s.min_value, s.max_value)
			if on_commit.is_valid():
				on_commit.call()
		e.text = fmt.call(s.value)
	e.text_submitted.connect(func(_t: String) -> void:
		commit.call()
		e.release_focus())
	e.focus_exited.connect(commit)
	return e

## Строка состояния (.status-field): утопленная, моноширинный текст цветом акцента со
## свечением.
func style_status(lbl: Label) -> void:
	lbl.add_theme_stylebox_override("normal", _sb("panel_sunken", 10, 6))
	lbl.add_theme_font_override("font", mono_font())
	lbl.add_theme_color_override("font_color", _pal["text"])
	lbl.add_theme_color_override("font_shadow_color", _pal["glow"])
	lbl.add_theme_constant_override("shadow_offset_x", 0)
	lbl.add_theme_constant_override("shadow_offset_y", 0)
	lbl.add_theme_constant_override("shadow_outline_size", 2)
