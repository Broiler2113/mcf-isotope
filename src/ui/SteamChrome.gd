extends RefCounted

# =====================================================================
#  SteamChrome - shared 2003-Steam window chrome for in-game surfaces.
# =====================================================================
# The editor panels and the in-game HUD are plain PanelContainers. On their
# own they read as flat slabs against the near-black map. These helpers give
# them the same framed-window treatment the main menu and dialogs use: a solid
# gunmetal body, a dark-green title bar with a bold bright caption and an accent
# pip, and consistent inner padding — so every surface looks like a deliberate
# little window rather than a raw control strip.
#
# Preloaded (not class_name) to dodge reimport ordering in fresh headless runs,
# mirroring the other ui/ helpers.

static var _bold_font: FontVariation = null

# Bold caption font, matching the emboldened titles the menus use. Cached so a
# panel full of headers doesn't rebuild the variation each time.
static func _bold() -> FontVariation:
	if _bold_font == null and Ui != null:
		var fv := FontVariation.new()
		fv.base_font = Ui.get_ui_font()
		fv.variation_embolden = 0.55
		_bold_font = fv
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

# Dark-green window title bar: an accent pip + bold bright caption, flush-left,
# with an optional trailing control (e.g. the chat collapse toggle) pinned right.
static func header_bar(title: String, trailing: Control = null) -> PanelContainer:
	var h := PanelContainer.new()
	if Ui != null:
		h.add_theme_stylebox_override("panel", Ui.header_box(0, 0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	h.add_child(pad(row, 9, 5))
	var pip := ColorRect.new()
	pip.custom_minimum_size = Vector2(3, 13)
	pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if Ui != null:
		pip.color = Ui.accent_color()
	row.add_child(pip)
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 14)
	if Ui != null:
		lbl.add_theme_color_override("font_color", Ui.TEXT_BRIGHT)
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

# A left-aligned brand chip for the toolbars: accent pip + bold bright caption,
# giving a naked control strip the same identity a menu title bar has.
static func brand_chip(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	var pip := ColorRect.new()
	pip.custom_minimum_size = Vector2(3, 15)
	pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if Ui != null:
		pip.color = Ui.accent_color()
	row.add_child(pip)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if Ui != null:
		lbl.add_theme_color_override("font_color", Ui.TEXT_BRIGHT)
		var bf := _bold()
		if bf != null:
			lbl.add_theme_font_override("font", bf)
	row.add_child(lbl)
	return row
