class_name ManualWindow
extends CanvasLayer

## «Manual» (0.12): справочник по правилам и карточки бойцов и техники. Открывается в любой
## момент - из главного меню, из боя и из редактора (кнопкой и клавишей, Keybinds
## game_manual / editor_manual). Окно собрано из набора интерфейса, как и настройки:
## шапка, слева список разделов, справа групповое окошко с текстом или карточками.

const SteamChrome = preload("res://src/ui/SteamChrome.gd")
const UNITS_TITLE := "Unit Cards"
## Порядок карточек - как в закупке: от пехоты к специалистам.
const UNIT_ORDER := ["light_infantry", "heavy_infantry", "machinegunner", "sniper",
	"marksman", "anti_tank", "flamethrower", "commander", "engineer", "miner", "sapper",
	"shield_bearer", "drone_operator", "civilian"]
const VEHICLE_BLURBS := {
	"tank": "Heavy armor with a main gun. Crew of three; its AP is the number of living crew. Tower, tracks and gun can each be knocked out - only the hull ends it.",
	"shuttle": "Fast transport. Passengers sit in its cells, fire from their seats and can be shot there. A Drone Operator can place a station on a seat and operate its drone from an adjacent seat.",
	"borg": "One-man walker. An Engineer inside spends 1 AP on three constructions of the same type, one pillbox, or nine trench digs. See Vehicles for details.",
}

## Ширина карточки: две в ряд на 100 %, одна, когда места меньше.
const CARD_MIN_W := 330.0

## Последний открытый раздел - окно открывается там, где его закрыли.
static var _last := 0

var window: FloatingPanel
var _sections: Array = []
var _buttons: Array[Button] = []
var _content: VBoxContainer = null
var _nav_scroll: ScrollContainer = null

## Открыть справочник; если он уже открыт - закрыть (одна клавиша и открывает, и прячет).
static func toggle(host: Node) -> void:
	for n: Node in host.get_tree().get_nodes_in_group("manual_window"):
		n.queue_free()
		return
	host.add_child(ManualWindow.new())

func _ready() -> void:
	layer = 95
	add_to_group("manual_window")
	_sections = ManualText.sections()
	# Карточки - сразу под «Getting Started»: к ним возвращаются чаще всего.
	_sections.insert(1, [UNITS_TITLE, ""])
	_build()
	_show(clampi(_last, 0, _sections.size() - 1))

func _build() -> void:
	window = FloatingPanel.new()
	add_child(window)
	window.setup("Manual", "Manual", Vector2(960, 640), Vector2(600, 350))
	window.close_requested.connect(queue_free)
	var col := window.body

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var body_pad := SteamChrome.pad(body, 12, 10)
	body_pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body_pad)

	# Разделы - столбик кнопок-переключателей, как вкладки набора, только вертикально.
	var nav_scroll := ScrollContainer.new()
	_nav_scroll = nav_scroll
	nav_scroll.custom_minimum_size = Vector2(190, 0)
	nav_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(nav_scroll)
	var nav := VBoxContainer.new()
	nav.add_theme_constant_override("separation", 3)
	nav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_scroll.add_child(nav)
	var group := ButtonGroup.new()
	for i in _sections.size():
		var b := Button.new()
		b.text = str(_sections[i][0])
		b.toggle_mode = true
		b.button_group = group
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(_show.bind(i))
		nav.add_child(b)
		_buttons.append(b)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_content)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	col.add_child(SteamChrome.pad(bottom, 16, 10))
	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = "Open or close the Manual at any time: %s (%s in the map editor)." % [
			Keybinds.label("game_manual"), Keybinds.label("editor_manual")]
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.72, 0.75, 0.82)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(hint)
	# Слой CanvasLayer сам тему не наследует (feedback: оверлеи обязаны выглядеть как набор).
	Ui.theme_canvas_layers()

func _show(i: int) -> void:
	_last = i
	# set_pressed_no_signal группу кнопок обходит - гасим остальные сами.
	for j in _buttons.size():
		_buttons[j].set_pressed_no_signal(j == i)
	_nav_scroll.ensure_control_visible.call_deferred(_buttons[i])
	for c in _content.get_children():
		c.queue_free()
	var title := str(_sections[i][0])
	var box := SteamChrome.group_box(title)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(box)
	if title == UNITS_TITLE:
		box.body.add_child(_unit_cards())
		return
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.scroll_active = true
	rt.selection_enabled = true
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rt.add_theme_font_size_override("normal_font_size", 13)
	rt.add_theme_font_size_override("bold_font_size", 13)
	rt.text = format(str(_sections[i][1]))
	box.body.add_child(rt)

## [h]…[/h] - подзаголовок цветом акцента; сам текст - как есть.
static func format(text: String) -> String:
	var accent := Ui.accent_color().to_html(false) if Ui != null else "8fd18f"
	var out := text.replace("[h]", "[font_size=15][b][color=#%s]" % accent).replace("[/h]", "[/color][/b][/font_size]")
	return out.replace("\u2014", "-").strip_edges()

# --- Карточки --------------------------------------------------------------------------

func _unit_cards() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Поток, а не сетка: на крупном интерфейсе карточки встают в один столбец, а не
	# раздвигают окно за край экрана.
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for id: String in UNIT_ORDER:
		var path := "res://src/data/units/%s.tres" % id
		if not ResourceLoader.exists(path):
			continue
		var st: UnitStats = load(path)
		grid.add_child(_unit_card(st))
	for vid: String in ["tank", "shuttle", "borg"]:
		grid.add_child(_vehicle_card(vid))
	return scroll

func _unit_card(st: UnitStats) -> Control:
	var range_text := "∞" if is_inf(st.fire_range) else ("-" if st.fire_range <= 0.0 else str(int(st.fire_range)))
	var ap := st.action_points if st.action_points > 0 else MCF.AP_PER_ACTIVATION
	var rows := [
		["Cost", "%d pts" % st.cost], ["Range", range_text], ["Rate of fire", str(st.rate_of_fire)],
		["Armor", "%d+" % st.armor_threshold], ["Speed", str(st.speed)], ["AP", str(ap)],
	]
	if st.target_defense_penalty > 0:
		rows.append(["Defense penalty", "−%d" % st.target_defense_penalty])
	if st.default_item_id != "":
		rows.append(["Item", str(MCF.ITEM_NAMES.get(st.default_item_id, st.default_item_id))])
	return _card(st.display_name, Sprites.unit_tag(st.id, st.display_name),
			Sprites.texture_of(Sprites.resolve(st.id)), rows, str(ManualText.UNIT_BLURBS.get(st.id, "")))

func _vehicle_card(vid: String) -> Control:
	var v := VehicleDB.get_vehicle(vid)
	var sz := VehicleDB.size_of(vid)
	var rows := [
		["Cost", "%d pts" % VehicleDB.buy_cost(vid)], ["Size", "%d×%d" % [sz.x, sz.y]],
		["Crew", str(int(v.get("crew_capacity", 1)))], ["Speed", str(int(v.get("speed", 0)))],
		["Hull", str(int(v.get("durability", 1)))],
	]
	var gun: Dictionary = (v.get("weapons", {}) as Dictionary).get("main_gun", {})
	if not gun.is_empty():
		rows.append(["Gun range", str(int(gun.get("range", 0)))])
	var name := str(v.get("name", vid))
	return _card(name, name.substr(0, 2).to_upper(), Sprites.texture_of(Sprites.resolve(vid)),
			rows, str(VEHICLE_BLURBS.get(vid, "")), true)

## Карточка в стиле набора: групповое окошко с именем на кромке, слева значок (картинка,
## если игрок её положил, иначе тот же кружок с меткой, что и на поле), справа цифры,
## под ними - что боец умеет.
func _card(title: String, tag: String, tex: Texture2D, rows: Array, blurb: String, vehicle := false) -> Control:
	var box := SteamChrome.group_box_compact(title)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.custom_minimum_size = Vector2(CARD_MIN_W, 0)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	box.body.add_child(top)
	var badge := UnitBadge.new()
	badge.tag = tag
	badge.vehicle = vehicle
	badge.tex = tex
	badge.custom_minimum_size = Vector2(52, 52)
	badge.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.add_child(badge)
	var stats := GridContainer.new()
	stats.columns = 4
	stats.add_theme_constant_override("h_separation", 10)
	stats.add_theme_constant_override("v_separation", 2)
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(stats)
	for r: Array in rows:
		var k := Label.new()
		k.text = str(r[0])
		k.add_theme_font_size_override("font_size", 11)
		k.modulate = Color(0.72, 0.75, 0.82)
		stats.add_child(k)
		var v := Label.new()
		v.text = str(r[1])
		v.add_theme_font_size_override("font_size", 12)
		stats.add_child(v)
	if blurb != "":
		var b := Label.new()
		b.text = blurb
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 12)
		box.body.add_child(b)
	return box

## Escape закрывает; клавиша самого справочника - в Keybinds (она и открывает, и закрывает).
func _input(event: InputEvent) -> void:
	if Keybinds.typing(get_viewport()) or Keybinds.modal_open(): return
	for console in get_tree().get_nodes_in_group("cheat_console"):
		if not console.tool.is_empty(): return
	if Keybinds.matches(event, "game_cancel") or Keybinds.matches(event, "editor_cancel"):
		get_viewport().set_input_as_handled()
		queue_free()

## Значок бойца: картинка игрока, если есть, иначе кружок цвета акцента с меткой, как на поле.
class UnitBadge extends Control:
	var tag := ""
	var vehicle := false
	var tex: Texture2D = null
	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0, 0, 0, 0.35))
		draw_rect(r, Color(1, 1, 1, 0.12), false, 1.0)
		if tex != null:
			draw_texture_rect(tex, r.grow(-4), false)
			return
		var c := size / 2.0
		var rad := minf(size.x, size.y) * 0.36
		var col := Ui.accent_color() if Ui != null else Color(0.55, 0.8, 0.55)
		if vehicle:
			draw_rect(Rect2(c - Vector2.ONE * rad, Vector2.ONE * rad * 2), col)
		else:
			draw_circle(c, rad, col)
		var font := get_theme_default_font()
		var fs := 16
		var w := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, c + Vector2(-w / 2.0, fs * 0.36), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Color(0.08, 0.08, 0.08))
