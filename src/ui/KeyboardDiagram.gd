class_name KeyboardDiagram
extends Control

## Клавиатура на странице сочетаний клавиш (0.12, решение владельца): занятые клавиши
## подсвечены цветом акцента, клавиши в сочетаниях (с Ctrl / Shift / Alt) — своим цветом,
## свободные — тёмные. Наведение на клавишу показывает всплывашку: какие действия на ней
## висят, и сами по себе, и в сочетаниях. Раздел — "game" или "editor": у боя и редактора
## раскладки разные. Рисуется сама, одним _draw, и тянется по ширине окна.

## Ряд клавиш: [подпись, keycode, ширина в клавишах]; keycode 0 — промежуток.
## Основной блок 15 клавиш, затем навигация и цифровой блок — полноразмерная ANSI.
const MAIN := [
	[["Esc", KEY_ESCAPE, 1.0], ["", 0, 1.0], ["F1", KEY_F1, 1.0], ["F2", KEY_F2, 1.0], ["F3", KEY_F3, 1.0],
		["F4", KEY_F4, 1.0], ["", 0, 0.5], ["F5", KEY_F5, 1.0], ["F6", KEY_F6, 1.0], ["F7", KEY_F7, 1.0],
		["F8", KEY_F8, 1.0], ["", 0, 0.5], ["F9", KEY_F9, 1.0], ["F10", KEY_F10, 1.0], ["F11", KEY_F11, 1.0],
		["F12", KEY_F12, 1.0]],
	[["`", KEY_QUOTELEFT, 1.0], ["1", KEY_1, 1.0], ["2", KEY_2, 1.0], ["3", KEY_3, 1.0], ["4", KEY_4, 1.0],
		["5", KEY_5, 1.0], ["6", KEY_6, 1.0], ["7", KEY_7, 1.0], ["8", KEY_8, 1.0], ["9", KEY_9, 1.0],
		["0", KEY_0, 1.0], ["-", KEY_MINUS, 1.0], ["=", KEY_EQUAL, 1.0], ["Backspace", KEY_BACKSPACE, 2.0]],
	[["Tab", KEY_TAB, 1.5], ["Q", KEY_Q, 1.0], ["W", KEY_W, 1.0], ["E", KEY_E, 1.0], ["R", KEY_R, 1.0],
		["T", KEY_T, 1.0], ["Y", KEY_Y, 1.0], ["U", KEY_U, 1.0], ["I", KEY_I, 1.0], ["O", KEY_O, 1.0],
		["P", KEY_P, 1.0], ["[", KEY_BRACKETLEFT, 1.0], ["]", KEY_BRACKETRIGHT, 1.0], ["\\", KEY_BACKSLASH, 1.5]],
	[["Caps", KEY_CAPSLOCK, 1.75], ["A", KEY_A, 1.0], ["S", KEY_S, 1.0], ["D", KEY_D, 1.0], ["F", KEY_F, 1.0],
		["G", KEY_G, 1.0], ["H", KEY_H, 1.0], ["J", KEY_J, 1.0], ["K", KEY_K, 1.0], ["L", KEY_L, 1.0],
		[";", KEY_SEMICOLON, 1.0], ["'", KEY_APOSTROPHE, 1.0], ["Enter", KEY_ENTER, 2.25]],
	[["Shift", KEY_SHIFT, 2.25], ["Z", KEY_Z, 1.0], ["X", KEY_X, 1.0], ["C", KEY_C, 1.0], ["V", KEY_V, 1.0],
		["B", KEY_B, 1.0], ["N", KEY_N, 1.0], ["M", KEY_M, 1.0], [",", KEY_COMMA, 1.0], [".", KEY_PERIOD, 1.0],
		["/", KEY_SLASH, 1.0], ["Shift", KEY_SHIFT, 2.75]],
	[["Ctrl", KEY_CTRL, 1.25], ["Meta", KEY_META, 1.25], ["Alt", KEY_ALT, 1.25], ["Space", KEY_SPACE, 6.25],
		["Alt", KEY_ALT, 1.25], ["Meta", KEY_META, 1.25], ["Menu", KEY_MENU, 1.25], ["Ctrl", KEY_CTRL, 1.25]],
]
const NAV := [
	[["PrtSc", KEY_PRINT, 1.0], ["ScrLk", KEY_SCROLLLOCK, 1.0], ["Pause", KEY_PAUSE, 1.0]],
	[["Ins", KEY_INSERT, 1.0], ["Home", KEY_HOME, 1.0], ["PgUp", KEY_PAGEUP, 1.0]],
	[["Del", KEY_DELETE, 1.0], ["End", KEY_END, 1.0], ["PgDn", KEY_PAGEDOWN, 1.0]],
	[],
	[["", 0, 1.0], ["↑", KEY_UP, 1.0]],
	[["←", KEY_LEFT, 1.0], ["↓", KEY_DOWN, 1.0], ["→", KEY_RIGHT, 1.0]],
]
## Цифровой блок: [подпись, keycode, ширина, высота].
const PAD := [
	[1, ["Num", KEY_NUMLOCK, 1, 1], ["/", KEY_KP_DIVIDE, 1, 1], ["*", KEY_KP_MULTIPLY, 1, 1], ["-", KEY_KP_SUBTRACT, 1, 1]],
	[2, ["7", KEY_KP_7, 1, 1], ["8", KEY_KP_8, 1, 1], ["9", KEY_KP_9, 1, 1], ["+", KEY_KP_ADD, 1, 2]],
	[3, ["4", KEY_KP_4, 1, 1], ["5", KEY_KP_5, 1, 1], ["6", KEY_KP_6, 1, 1]],
	[4, ["1", KEY_KP_1, 1, 1], ["2", KEY_KP_2, 1, 1], ["3", KEY_KP_3, 1, 1], ["Enter", KEY_KP_ENTER, 1, 2]],
	[5, ["0", KEY_KP_0, 2, 1], [".", KEY_KP_PERIOD, 1, 1]],
]
const WIDTH_UNITS := 15.0 + 0.5 + 3.0 + 0.5 + 4.0
const HEIGHT_UNITS := 6.0 + 0.4
const GAP := 0.08   # зазор между клавишами, в долях клавиши
## Клавиатура держит пропорции по ширине, но не выше этой доли экрана: на крупном
## интерфейсе окно настроек обязано поместиться целиком, вместе со списком.
const HEIGHT_SHARE := 0.26
const MIN_UNIT := 16.0
## На большом экране клавиатура шире: до половины окна, клавиша не крупнее MAX_UNIT.
const WIDTH_SHARE := 0.5
const MAX_UNIT := 34.0
const COMBO_COLOR := Color(0.95, 0.68, 0.25)
const FREE_COLOR := Color(0.17, 0.17, 0.17)
const MODS := {KEY_CTRL: KEY_MASK_CTRL, KEY_SHIFT: KEY_MASK_SHIFT, KEY_ALT: KEY_MASK_ALT, KEY_META: KEY_MASK_META}
## Подписи контекстов из Keybinds.DEFINITIONS — кому принадлежит действие.
const CONTEXT_NAMES := {
	"infantry": "soldier", "sapper": "minesweeper", "engineer": "engineer", "operator": "drone operator",
	"miner": "miner", "drone": "drone", "passenger": "passenger", "group": "group", "vehicle": "vehicle",
	"held": "held soldier", "dice": "dice", "replay": "replay", "picker": "action list", "wall": "wall building",
}

var section := "game":
	set(v):
		section = v
		_rebuild()

## keycode -> [[модификаторы, подпись действия, контексты], ...]
var _uses: Dictionary = {}
## Модификаторы, которые хоть где-то участвуют в сочетаниях.
var _mods_used: Dictionary = {}
## [Rect2 в клавишах, keycode, подпись] — для рисования и наведения.
var _keys: Array = []
var _hover := -1

## Своя всплывашка над клавишей (0.12.1): движковые подсказки на macOS у владельца не
## появлялись вовсе, поэтому панель показывается сама, сразу при наведении, у курсора.
var _popup: PanelContainer = null
var _popup_text: RichTextLabel = null

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_layout()

func _ready() -> void:
	Keybinds.changed.connect(_rebuild)
	_rebuild()

func _get_minimum_size() -> Vector2:
	var floor_h := MIN_UNIT * HEIGHT_UNITS
	var budget := get_viewport_rect().size.y * HEIGHT_SHARE if is_inside_tree() else floor_h
	var by_width := size.x / WIDTH_UNITS * HEIGHT_UNITS
	var want_w := WIDTH_UNITS * MIN_UNIT
	if is_inside_tree():
		want_w = clampf(get_viewport_rect().size.x * WIDTH_SHARE, want_w, WIDTH_UNITS * MAX_UNIT)
	return Vector2(want_w, clampf(by_width, floor_h, maxf(floor_h, budget)))

func _layout() -> void:
	_keys.clear()
	var y := 0.0
	for r in MAIN.size():
		var x := 0.0
		for k: Array in MAIN[r]:
			if int(k[1]) != 0:
				_keys.append([Rect2(x, y, float(k[2]), 1.0), int(k[1]), str(k[0])])
			x += float(k[2])
		y += 1.4 if r == 0 else 1.0
	var nx := 15.5
	y = 0.0
	for r in NAV.size():
		var x := nx
		for k: Array in NAV[r]:
			if int(k[1]) != 0:
				_keys.append([Rect2(x, y, float(k[2]), 1.0), int(k[1]), str(k[0])])
			x += float(k[2])
		y += 1.4 if r == 0 else 1.0
	var px := nx + 3.5
	for row: Array in PAD:
		var py := 0.4 + float(row[0])
		var x := px
		for i in range(1, row.size()):
			var k: Array = row[i]
			_keys.append([Rect2(x, py, float(k[2]), float(k[3])), int(k[1]), str(k[0])])
			x += float(k[2])

## Перечитать назначения из Keybinds (с учётом переназначенных игроком клавиш).
func _rebuild() -> void:
	_uses.clear()
	_mods_used.clear()
	for entry: Dictionary in Keybinds.DEFINITIONS:
		if entry.section != section and entry.id != "game_fullscreen":
			continue
		for code: int in Keybinds.codes(entry.id):
			var key := code & KEY_CODE_MASK
			var mods := code & KEY_MODIFIER_MASK
			var list: Array = _uses.get(key, [])
			list.append([mods, str(entry.label), entry.contexts])
			_uses[key] = list
			for mk: int in MODS:
				if mods & int(MODS[mk]):
					_mods_used[mk] = true
	# Цифры 1–9 в бою выбирают действие из списка — их переназначить нельзя (Keybinds.rebind).
	if section == "game":
		for i in 9:
			var list: Array = _uses.get(KEY_1 + i, [])
			list.append([0, "Choose action %d in the action list" % (i + 1), ["*"]])
			_uses[KEY_1 + i] = list
	queue_redraw()

func _unit() -> float:
	return minf(size.x / WIDTH_UNITS, size.y / HEIGHT_UNITS)

func _key_rect(i: int) -> Rect2:
	var u := _unit()
	var r: Rect2 = _keys[i][0]
	var g := GAP * u * 0.5
	# Клавиатура по центру своей полосы, если по высоте она уже упёрлась в бюджет.
	var off := Vector2((size.x - WIDTH_UNITS * u) / 2.0, 0)
	return Rect2(off + r.position * u + Vector2(g, g), r.size * u - Vector2(g, g) * 2.0)

## Что на клавише: 0 — свободна, 1 — сама по себе, 2 — только в сочетаниях, 3 — и так и так.
func _state(code: int) -> int:
	if MODS.has(code):
		return 2 if _mods_used.has(code) else 0
	var plain := false
	var combo := false
	for use: Array in _uses.get(code, []):
		if int(use[0]) == 0:
			plain = true
		else:
			combo = true
	return (1 if plain else 0) + (2 if combo else 0)

func _draw() -> void:
	var accent := Ui.accent_color() if Ui != null else Color(0.55, 0.8, 0.55)
	var font := get_theme_default_font()
	var u := _unit()
	var fs := clampi(int(u * 0.36), 9, 16)
	for i in _keys.size():
		var r := _key_rect(i)
		var code: int = _keys[i][1]
		var st := _state(code)
		var fill := FREE_COLOR
		match st:
			1, 3: fill = accent.darkened(0.25)
			2: fill = COMBO_COLOR.darkened(0.3)
		draw_rect(r, fill)
		# Занята и сама, и в сочетании — полоса цвета сочетаний внизу клавиши.
		if st == 3:
			draw_rect(Rect2(r.position + Vector2(0, r.size.y * 0.78), Vector2(r.size.x, r.size.y * 0.22)),
					COMBO_COLOR.darkened(0.15))
		var edge := Color(1, 1, 1, 0.55) if i == _hover else Color(0, 0, 0, 0.8)
		draw_rect(r, edge, false, 2.0 if i == _hover else 1.0)
		# Верхняя светлая кромка — объём клавиши, как у кнопок набора.
		draw_line(r.position + Vector2(1, 1), r.position + Vector2(r.size.x - 1, 1), Color(1, 1, 1, 0.08), 1.0)
		var label: String = _keys[i][2]
		var ink := Color(0.62, 0.62, 0.62) if st == 0 else Color(0.06, 0.06, 0.06)
		# Подпись ужимается до ширины клавиши: на мелком масштабе «Backspace» иначе вылезает.
		var lfs := fs if label.length() <= 3 else maxi(8, fs - 3)
		var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs).x
		while w > r.size.x - 4.0 and lfs > 7:
			lfs -= 1
			w = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs).x
		if w > r.size.x - 4.0:
			label = label.substr(0, 3)
			w = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs).x
		draw_string(font, r.position + Vector2((r.size.x - w) / 2.0, r.size.y * 0.5 + lfs * 0.36),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs, ink)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var at := -1
		for i in _keys.size():
			if _key_rect(i).has_point(event.position):
				at = i
				break
		if at != _hover:
			_hover = at
			queue_redraw()
			if at >= 0:
				_show_popup(tooltip_for(_keys[at][1], _keys[at][2]))
			else:
				_hide_popup()
		if _popup != null and _popup.visible:
			_place_popup()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		update_minimum_size()
	if what == NOTIFICATION_MOUSE_EXIT and _hover != -1:
		_hover = -1
		_hide_popup()
		queue_redraw()

## Текст всплывашки клавиши: её действия, затем действия в сочетаниях. Для Ctrl/Shift/Alt —
## все сочетания, где они участвуют.
func tooltip_for(code: int, label: String) -> String:
	var lines: Array[String] = []
	if MODS.has(code):
		var mask: int = MODS[code]
		for key: int in _uses:
			for use: Array in _uses[key]:
				if int(use[0]) & mask:
					lines.append("%s — %s%s" % [Keybinds.key_event(int(use[0]) | key).as_text(), use[1], _ctx(use[2])])
		lines.sort()
		return "%s\n%s" % [label, "\n".join(lines) if not lines.is_empty() else "Not used in any combination"]
	var plain: Array[String] = []
	var combos: Array[String] = []
	for use: Array in _uses.get(code, []):
		if int(use[0]) == 0:
			plain.append("%s%s" % [use[1], _ctx(use[2])])
		else:
			combos.append("%s — %s%s" % [Keybinds.key_event(int(use[0]) | code).as_text(), use[1], _ctx(use[2])])
	if plain.is_empty() and combos.is_empty():
		return "%s\nNot used" % label
	var out := label
	for p: String in plain:
		out += "\n" + p
	if not combos.is_empty():
		out += "\nIn combinations:"
		for c: String in combos:
			out += "\n" + c
	return out

func _ctx(contexts: Array) -> String:
	var names: Array[String] = []
	for c in contexts:
		if CONTEXT_NAMES.has(str(c)):
			names.append(CONTEXT_NAMES[str(c)])
	if names.is_empty() or names.size() >= 6:
		return ""
	return " (%s)" % ", ".join(names)

## Всплывашка в стиле набора: тёмная панель, первая строка — клавиша цветом акцента,
## «In combinations:» — цветом сочетаний. Панель top_level: её не обрезают контейнеры окна.
func _show_popup(text: String) -> void:
	if _popup == null:
		_popup = PanelContainer.new()
		_popup.top_level = true
		_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_popup.z_index = 100
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.1, 0.1, 0.1, 0.96)
		sb.border_color = Color(0, 0, 0)
		sb.set_border_width_all(1)
		sb.set_content_margin_all(8)
		_popup.add_theme_stylebox_override("panel", sb)
		_popup_text = RichTextLabel.new()
		_popup_text.bbcode_enabled = true
		_popup_text.fit_content = true
		_popup_text.autowrap_mode = TextServer.AUTOWRAP_OFF
		_popup_text.scroll_active = false
		_popup_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_popup_text.add_theme_font_size_override("normal_font_size", 12)
		_popup_text.add_theme_font_size_override("bold_font_size", 13)
		_popup.add_child(_popup_text)
		add_child(_popup)
	var lines := text.split("\n")
	var accent := (Ui.accent_color() if Ui != null else Color(0.55, 0.8, 0.55)).to_html(false)
	var out := "[b][color=#%s]%s[/color][/b]" % [accent, lines[0]]
	for i in range(1, lines.size()):
		var l := lines[i].replace("[", "[lb]")
		if lines[i] == "In combinations:":
			l = "[color=#%s]%s[/color]" % [COMBO_COLOR.to_html(false), l]
		out += "\n" + l
	_popup_text.text = out
	_popup.reset_size()
	_popup.visible = true
	_place_popup.call_deferred()

func _hide_popup() -> void:
	if _popup != null:
		_popup.visible = false

## Справа-снизу от курсора; у края экрана — с другой стороны, чтобы не уходить за него.
func _place_popup() -> void:
	if _popup == null or not _popup.visible:
		return
	_popup.reset_size()
	var vp := get_viewport_rect().size
	var m := get_global_mouse_position()
	var sz := _popup.get_combined_minimum_size()
	var pos := m + Vector2(16, 18)
	if pos.x + sz.x > vp.x - 4.0:
		pos.x = m.x - sz.x - 12.0
	if pos.y + sz.y > vp.y - 4.0:
		pos.y = m.y - sz.y - 12.0
	_popup.global_position = pos.max(Vector2(4, 4))
