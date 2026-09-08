extends Node

# =====================================================================
#  UiTheme - global "2003 Steam" interface skin  (autoload: Ui)
# =====================================================================
# Ported from Crazy Ball Runner 2D. Builds one Theme from the PNGs in
# res://interface_textures/ and hangs it on the root Window, so EVERY
# Control in EVERY menu inherits the gunmetal Steam look with no
# per-scene wiring. Textures are read straight off disk (Image.load), so
# dropping a replacement PNG reskins the game with no re-import.
#
# Headless-safe: skipped entirely when there is no display server, so the
# sim/headless smoke tests are never touched.

const TEX_DIR := "res://interface_textures/"
const FONT_TTF := "res://interface_textures/ui_font.ttf"
const SLICE := 6          # 9-slice border, matches the 32px generated chrome
const FONT_FALLBACKS := ["Tahoma", "Verdana", "Geneva", "DejaVu Sans", "Arial", "Helvetica"]

# --- palette (gunmetal-gray "2003 Steam" skin) -----------------------
# item 8: серые части меню сделаны заметно темнее (примерно на четверть). Один и тот
# же сдвиг на всех трёх тонах сохраняет прежний контраст между окном, панелью и
# утопленным полем — темнеет вся серая гамма разом, а не отдельные её куски.
const WINDOW_BG   := Color(0.170, 0.170, 0.170)
const PANEL_BG    := Color(0.235, 0.235, 0.235)
const SUNKEN_BG   := Color(0.125, 0.125, 0.125)
const HEADER_BG   := Color(0.118, 0.149, 0.125)
const TEXT        := Color(0.847, 0.847, 0.847)
const TEXT_BRIGHT := Color(0.95, 0.96, 0.93)
const TEXT_DIM    := Color(0.588, 0.588, 0.588)
const TEXT_ACCENT := Color(0.647, 0.741, 0.549)
const ACCENT      := Color(0.549, 0.635, 0.471)
const ACCENT_BASE := Color(0.549, 0.635, 0.471)

var theme: Theme

# Static green accent (no per-user theme switching in this project).
var _accent := ACCENT
var _text_accent := TEXT_ACCENT
var _header_bg := HEADER_BG

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	rebuild_theme()

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

func _accent_modulate() -> Color:
	return Color(
		_accent.r / ACCENT_BASE.r,
		_accent.g / ACCENT_BASE.g,
		_accent.b / ACCENT_BASE.b,
		1.0)

func _header_modulate() -> Color:
	return Color(
		_header_bg.r / HEADER_BG.r,
		_header_bg.g / HEADER_BG.g,
		_header_bg.b / HEADER_BG.b,
		1.0)

func accent_color() -> Color:
	return _accent

func text_accent_color() -> Color:
	return _text_accent

func header_color() -> Color:
	return _header_bg

func header_box(pad_h: int = 0, pad_v: int = 0) -> StyleBox:
	var sb := _sb("header", pad_h, pad_v)
	if sb is StyleBoxTexture:
		(sb as StyleBoxTexture).modulate_color = _header_modulate()
	elif sb is StyleBoxFlat:
		(sb as StyleBoxFlat).bg_color = _header_bg
	return sb

func _hover_modulate() -> Color:
	var m: float = maxf(_accent.r, maxf(_accent.g, _accent.b))
	if m <= 0.0:
		return Color(1, 1, 1, 1)
	return Color(_accent.r / m, _accent.g / m, _accent.b / m, 1.0)

func _sb_hover(name: String, pad_h: int, pad_v: int) -> StyleBox:
	var sb := _sb(name, pad_h, pad_v)
	if sb is StyleBoxTexture:
		(sb as StyleBoxTexture).modulate_color = _hover_modulate()
	elif sb is StyleBoxFlat:
		(sb as StyleBoxFlat).bg_color = _accent
	return sb

# =====================================================================
#  Theme construction
# =====================================================================
func _build() -> Theme:
	var t := Theme.new()
	var font := _font()
	_ui_font = font
	t.default_font = font
	t.default_font_size = 14

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
		t.set_stylebox("focus", cls, b_hover)
		t.set_stylebox("disabled", cls, b_dis)
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_hover_color", cls, TEXT_BRIGHT)
		t.set_color("font_pressed_color", cls, _text_accent)
		t.set_color("font_focus_color", cls, TEXT_BRIGHT)
		t.set_color("font_disabled_color", cls, TEXT_DIM)

	# ---- CheckBox / CheckButton -------------------------------------
	var chk_on := _load_tex("check_on")
	var chk_off := _load_tex("check_off")
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
	var tab_on := _sb_accent("tab_active", 14, 6)
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
	t.set_stylebox("background", "ProgressBar", _sb("progress_bg", 0, 0))
	t.set_stylebox("fill", "ProgressBar", _sb_accent("progress_fill", 0, 0))
	t.set_color("font_color", "ProgressBar", TEXT_BRIGHT)

	# ---- Sliders -----------------------------------------------------
	var s_track := _sb("slider_track", 0, 0)
	var s_fill := _sb_accent("progress_fill", 0, 0)
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
	var scroll_track := _sb("scroll_track", 0, 0)
	var grab_norm := _sb("scroll_grabber", 0, 0)
	var grab_hl := _sb("scroll_grabber_hl", 0, 0)
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
	t.set_stylebox("hover", "PopupMenu", _sb_accent("selection", 4, 2))
	t.set_color("font_hover_color", "PopupMenu", TEXT_BRIGHT)
	t.set_stylebox("selected", "ItemList", _sb_accent("selection", 2, 2))
	t.set_stylebox("selected", "Tree", _sb_accent("selection", 2, 2))

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
		sep.color = Color(0, 0, 0, 0.4)
		sep.thickness = 1
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
	if FileAccess.file_exists(FONT_TTF):
		var ff := FontFile.new()
		if ff.load_dynamic_font(FONT_TTF) == OK:
			return ff
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(FONT_FALLBACKS)
	sf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return sf

var _tex_cache: Dictionary = {}
var _ui_font: Font = null

func get_ui_font() -> Font:
	if _ui_font == null:
		_ui_font = _font()
	return _ui_font

func get_texture(name: String) -> Texture2D:
	return _load_tex(name)

func _load_tex(name: String) -> Texture2D:
	if _tex_cache.has(name):
		return _tex_cache[name]
	var path := TEX_DIR + name + ".png"
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	if tex == null and ResourceLoader.exists(path):
		var r := load(path)
		if r is Texture2D:
			tex = r
	_tex_cache[name] = tex
	return tex

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
	return sb

func _sb_accent(name: String, pad_h: int, pad_v: int) -> StyleBox:
	var sb := _sb(name, pad_h, pad_v)
	if sb is StyleBoxTexture:
		(sb as StyleBoxTexture).modulate_color = _accent_modulate()
	elif sb is StyleBoxFlat:
		(sb as StyleBoxFlat).bg_color = _accent
	return sb
