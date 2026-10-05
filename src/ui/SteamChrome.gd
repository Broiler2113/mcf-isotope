extends RefCounted

# =====================================================================
#  SteamChrome - shared 2003-Steam window chrome for in-game surfaces.
# =====================================================================
# The editor panels and the in-game HUD are plain PanelContainers. On their
# own they read as flat slabs against the near-black map. These helpers give
# them the same framed-window treatment the main menu and dialogs use: a solid
# gunmetal body, the UI kit's grey gradient title bar with a bold bright caption,
# and consistent inner padding — so every surface looks like a deliberate
# little window rather than a raw control strip.
#
# Preloaded (not class_name) to dodge reimport ordering in fresh headless runs,
# mirroring the other ui/ helpers.

static var _bold_font: FontVariation = null

# Bold caption font, matching the emboldened titles the menus use. Cached so a
# panel full of headers doesn't rebuild the variation each time.
static func _bold() -> FontVariation:
	if _bold_font == null and Ui != null:
		_bold_font = Ui.bold_font() as FontVariation
	return _bold_font

# Opaque gunmetal body (with the baked chrome border) so a panel frames its
# controls over the dark playfield instead of letting the map show through.
static func apply_panel(pc: Control) -> void:
	if Ui != null:
		pc.add_theme_stylebox_override("panel", Ui._sb("panel", 0, 0))

# Sunken well body — a recessed content area matching the menus' inner panes.
static func apply_sunken(pc: Control) -> void:
	if Ui != null:
		pc.add_theme_stylebox_override("panel", Ui._sb("panel_sunken", 0, 0))

# Consistent inner padding so content never sits flush against the frame edge.
static func pad(inner: Control, h: int = 8, v: int = 8) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left", h)
	mc.add_theme_constant_override("margin_right", h)
	mc.add_theme_constant_override("margin_top", v)
	mc.add_theme_constant_override("margin_bottom", v)
	mc.add_child(inner)
	return mc

# Window title bar of the UI kit (.window-title): grey gradient, bold bright 13px caption
# with a black text shadow, flush-left, and an optional trailing control (e.g. the chat
# collapse toggle) pinned right.
static func header_bar(title: String, trailing: Control = null) -> PanelContainer:
	var h := PanelContainer.new()
	if Ui != null:
		h.add_theme_stylebox_override("panel", Ui.header_box(0, 0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	h.add_child(pad(row, 12, 5))
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 13)
	if Ui != null:
		lbl.add_theme_color_override("font_color", Color("#e0e0e0"))
		lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
		var bf := _bold()
		if bf != null:
			lbl.add_theme_font_override("font", bf)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	if trailing != null:
		trailing.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(trailing)
	return h

# Group box of the UI kit (.group-box): a bevelled #2a2a2a frame with its caption sitting
# ON the top border (.group-box-title). Returns the box; put content into box.body.
static func group_box(title: String) -> GroupBox:
	var g := GroupBox.new()
	g.title = title
	return g

## Групповое окошко с узкими полями — для боковых панелей (правое меню боя, закупка), где
## стандартные 16 точек с каждой стороны съедали треть ширины и выталкивали кнопки за край.
static func group_box_compact(title: String) -> GroupBox:
	var g := group_box(title)
	var mc := g._frame.get_child(0) as MarginContainer
	mc.add_theme_constant_override("margin_left", 8)
	mc.add_theme_constant_override("margin_right", 8)
	mc.add_theme_constant_override("margin_top", 12)
	mc.add_theme_constant_override("margin_bottom", 10)
	return g

class GroupBox extends Container:
	var title := "":
		set(v):
			title = v
			if _caption != null:
				_caption.text = v
	var body := VBoxContainer.new()
	var _frame := PanelContainer.new()
	var _caption := Label.new()
	const CAPTION_H := 16
	func _init() -> void:
		body.add_theme_constant_override("separation", 6)
		_frame.add_child(SteamChrome_pad(body))
		add_child(_frame)
		_caption.text = title
		_caption.add_theme_font_size_override("font_size", 12)
		_caption.add_theme_color_override("font_color", Color("#c0c0c0"))
		_caption.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
		add_child(_caption)
		if Ui != null:
			_frame.add_theme_stylebox_override("panel", Ui._sb("group", 0, 0))
			var cap := StyleBoxFlat.new()
			cap.bg_color = Color("#2a2a2a")
			cap.content_margin_left = 8
			cap.content_margin_right = 8
			_caption.add_theme_stylebox_override("normal", cap)
	static func SteamChrome_pad(inner: Control) -> MarginContainer:
		var mc := MarginContainer.new()
		mc.add_theme_constant_override("margin_left", 16)
		mc.add_theme_constant_override("margin_right", 16)
		mc.add_theme_constant_override("margin_top", 14)
		mc.add_theme_constant_override("margin_bottom", 16)
		mc.add_child(inner)
		return mc
	func _get_minimum_size() -> Vector2:
		var f := _frame.get_combined_minimum_size()
		var c := _caption.get_combined_minimum_size()
		return Vector2(maxf(f.x, c.x + 24), f.y + CAPTION_H / 2.0)
	func _notification(what: int) -> void:
		if what == NOTIFICATION_SORT_CHILDREN:
			var top := CAPTION_H / 2.0
			fit_child_in_rect(_frame, Rect2(0, top, size.x, size.y - top))
			var c := _caption.get_combined_minimum_size()
			fit_child_in_rect(_caption, Rect2(12, top - c.y / 2.0, c.x, c.y))

# A left-aligned brand chip for the toolbars: accent pip + bold bright caption,
# giving a naked control strip the same identity a menu title bar has.
static func brand_chip(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if Ui != null:
		lbl.add_theme_color_override("font_color", Ui.TEXT_BRIGHT)
		var bf := _bold()
		if bf != null:
			lbl.add_theme_font_override("font", bf)
	row.add_child(lbl)
	return row
