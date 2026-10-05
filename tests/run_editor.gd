extends SceneTree

## Редактор карт (editor-rework): пресеты и их заливка, кисть, ластик, линия, прямоугольник,
## заливка, симметрия (и чьи в отражении зоны), выделение с копированием, вырезанием,
## переносом и вставкой с поворотом, заготовки, пипетка, нейтралы, размер, очистка,
## откат разностями, сохранение и открытие, старт из генератора, возврат из пробной партии.
## Мышь — настоящими событиями ввода в _unhandled_input, а не прямыми вызовами.

var fails: PackedStringArray = []
var ed: Node = null
const SAVE_NAME := "zz_editor_test_tmp"

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

var _frames := 0

func _initialize() -> void:
	ed = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(ed)

## Проверки — на втором кадре: в _initialize дерево ещё не живое, и у редактора нет вьюпорта.
func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	_run()
	return true

func _run() -> void:
	_presets()
	_brush_and_undo()
	_shapes_and_fill()
	_symmetry()
	_selection()
	_stamps()
	_preview()
	_picker_units_zones()
	_resize_clear()
	_files_and_generator()
	_furniture()
	_session()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s.json" % [MapData.MAPS_DIR, SAVE_NAME]))
	ed.queue_free()
	if fails.is_empty():
		print("editor: presets, tools, symmetry, clipboard, stamps, undo and files all hold")
		quit(0)
		return
	printerr("editor: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

# --- Помощники: мышь по клеткам ---
func _screen(c: Vector2i) -> Vector2:
	return ed.pan + (Vector2(c) + Vector2(0.5, 0.5)) * ed.cell_size()

func _press(c: Vector2i, pressed: bool = true, alt: bool = false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.alt_pressed = alt
	e.position = _screen(c)
	ed._unhandled_input(e)

func _move(c: Vector2i) -> void:
	var e := InputEventMouseMotion.new()
	e.position = _screen(c)
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	ed._unhandled_input(e)

func _drag(a: Vector2i, b: Vector2i) -> void:
	_press(a)
	_move(b)
	_press(b, false)

func _key(k: Key, ctrl: bool = false, shift: bool = false) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.pressed = true
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	ed._unhandled_input(e)

func _feat(c: Vector2i) -> String:
	return ed.map.get_feature(c)

func _fresh(env: String, w: int = 40, h: int = 30) -> void:
	ed.create_map("", env, Vector2i(w, h))
	ed.pan = Vector2(60, 50)
	ed.zoom = 0.5
	ed.symmetry = 0

# --- Пресеты ---
func _presets() -> void:
	_fresh("station")
	var m: MapData = ed.map
	ck(m.env == "station" and m.get_space(Vector2i(0, 0)) and not m.get_space(Vector2i(20, 15)),
			"Station: a deck with a rim of space")
	_fresh("field")
	var grass := 0
	for i in ed.map.width * ed.map.height:
		grass += 1 if ed.map.floor_type[i] == MCF.FLOOR_GRASS else 0
	ck(grass > ed.map.width * ed.map.height / 2 and grass < ed.map.width * ed.map.height,
			"Field: grass with patches of bare ground (%d grass)" % grass)
	_fresh("bunker")
	ck(_feat(Vector2i(0, 0)) == MCF.FEATURE_WALL and _feat(Vector2i(20, 15)) == MCF.FEATURE_WALL,
			"Bunker: solid rock")
	_fresh("asteroid")
	ck(ed.map.get_space(Vector2i(0, 0)) and not ed.map.get_space(Vector2i(20, 15)), "Asteroid: an island in space")
	_fresh("town")
	ck(not ed.map.get_space(Vector2i(0, 0)) and ed.map.get_floor(Vector2i(0, 0)) == MCF.FLOOR_NORMAL, "Town: street")
	ck(ed._tiles.env == "town", "the tiles follow the preset")
	ed.set_preset("bunker")
	ck(ed.map.env == "bunker" and ed._tiles.env == "bunker", "Map > Preset re-skins the map")
	ed.undo()
	ck(ed.map.env == "town" and ed._tiles.env == "town", "the preset change undoes")

# --- Кисть, ластик, откат ---
func _brush_and_undo() -> void:
	_fresh("station")
	ed._select_brush(MCF.FEATURE_WALL)
	ed.brush_size = 1
	_drag(Vector2i(5, 5), Vector2i(12, 5))
	var gap := false
	for x in range(5, 13):
		gap = gap or _feat(Vector2i(x, 5)) != MCF.FEATURE_WALL
	ck(not gap, "a fast drag paints every cell between the two mouse events")
	ck(ed._grid.cell(Vector2i(8, 5)).feature_id == MCF.FEATURE_WALL, "the tile mirror follows the map")
	var entry: Dictionary = ed._undo_stack[-1]
	ck(entry["cells"].size() == 8, "the undo entry holds just the 8 touched cells (%d)" % entry["cells"].size())
	_key(KEY_Z, true)
	ck(_feat(Vector2i(8, 5)) == "", "Ctrl+Z takes the stroke back")
	_key(KEY_Y, true)
	ck(_feat(Vector2i(8, 5)) == MCF.FEATURE_WALL, "Ctrl+Y brings it back")
	ed._set_brush_size(3)
	_drag(Vector2i(20, 20), Vector2i(20, 20))
	ck(_feat(Vector2i(19, 19)) == MCF.FEATURE_WALL and _feat(Vector2i(21, 21)) == MCF.FEATURE_WALL,
			"size 3 paints a 3×3 block")
	_key(KEY_E)
	ck(ed.tool == 1, "E picks the eraser")
	ed._set_brush_size(1)
	_drag(Vector2i(20, 20), Vector2i(20, 20))
	ck(ed.map.get_space(Vector2i(20, 20)) and _feat(Vector2i(20, 20)) == "", "the Station eraser leaves space")
	_fresh("field")
	_key(KEY_B)
	ed._select_brush(MCF.FEATURE_SANDBAGS)
	_drag(Vector2i(3, 3), Vector2i(3, 3))
	_key(KEY_E)
	_drag(Vector2i(3, 3), Vector2i(3, 3))
	ck(not ed.map.get_space(Vector2i(3, 3)) and ed.map.get_floor(Vector2i(3, 3)) == MCF.FLOOR_GRASS,
			"the Field eraser leaves grass")

# --- Линия, прямоугольник, заливка ---
func _shapes_and_fill() -> void:
	_fresh("town")
	ed._select_brush(MCF.FEATURE_WALL)
	_key(KEY_R)
	ed.rect_filled = false
	_drag(Vector2i(4, 4), Vector2i(14, 12))
	ck(_feat(Vector2i(4, 8)) == MCF.FEATURE_WALL and _feat(Vector2i(9, 8)) == "", "Rectangle: an outline")
	ed._select_brush("grass")
	_key(KEY_F)
	_press(Vector2i(9, 8))
	_press(Vector2i(9, 8), false)
	ck(ed.map.get_floor(Vector2i(9, 8)) == MCF.FLOOR_GRASS and ed.map.get_floor(Vector2i(2, 2)) != MCF.FLOOR_GRASS,
			"Fill stays inside the walls")
	ed._select_brush(MCF.FEATURE_SANDBAGS)
	_key(KEY_R)
	ed.rect_filled = true
	_drag(Vector2i(20, 4), Vector2i(23, 6))
	ck(_feat(Vector2i(21, 5)) == MCF.FEATURE_SANDBAGS, "Rectangle + Filled: a solid block")
	_key(KEY_L)
	ed._select_brush(MCF.FEATURE_TRENCH)
	_drag(Vector2i(2, 20), Vector2i(12, 25))
	ck(_feat(Vector2i(2, 20)) == MCF.FEATURE_TRENCH and _feat(Vector2i(12, 25)) == MCF.FEATURE_TRENCH,
			"Line: both ends and the cells between")

# --- Симметрия ---
func _symmetry() -> void:
	_fresh("town", 40, 30)
	ed.symmetry = 1
	ed._select_brush(MCF.FEATURE_WALL)
	_key(KEY_B)
	_drag(Vector2i(2, 3), Vector2i(2, 3))
	ck(_feat(Vector2i(37, 3)) == MCF.FEATURE_WALL, "Left/Right mirrors a stroke")
	ed._select_brush("zone:0")
	_drag(Vector2i(4, 4), Vector2i(4, 4))
	ck(ed.map.get_zone(Vector2i(4, 4)) == 0 and ed.map.get_zone(Vector2i(35, 4)) == 1,
			"a mirrored zone goes to the other player")
	ed.symmetry = 3
	ed._select_brush("zone:0")
	_drag(Vector2i(6, 6), Vector2i(6, 6))
	ck(ed.map.get_zone(Vector2i(33, 6)) == 1 and ed.map.get_zone(Vector2i(6, 23)) == 2
			and ed.map.get_zone(Vector2i(33, 23)) == 3, "four quarters hand out zones 1–4")
	ed._select_brush("unit:sniper")
	_drag(Vector2i(8, 8), Vector2i(8, 8))
	ck(ed._spawn_at.has(Vector2i(31, 21)) and int(ed._spawn_at[Vector2i(31, 21)]["owner"]) == MCF.Owner.NEUTRAL,
			"a neutral stays neutral in the mirror")
	ed.symmetry = 0

# --- Выделение, копия, вставка, перенос ---
func _selection() -> void:
	_fresh("town")
	ed._select_brush(MCF.FEATURE_WALL)
	_key(KEY_B)
	_drag(Vector2i(2, 2), Vector2i(4, 2))   # три стены в ряд
	_key(KEY_M)
	_drag(Vector2i(2, 2), Vector2i(4, 3))
	ck(ed._selection == Rect2i(2, 2, 3, 2), "Select drags a 3×2 box (%s)" % str(ed._selection))
	_key(KEY_C, true)
	_key(KEY_V, true)
	ck(not ed._float.is_empty(), "Ctrl+V picks the copy up")
	_key(KEY_R)
	ck(int(ed._float["w"]) == 2 and int(ed._float["h"]) == 3, "R rotates the paste")
	ed._hover = Vector2i(20, 20)
	_press(Vector2i(20, 20))
	var vertical := 0
	for y in range(18, 23):
		for x in range(18, 23):
			vertical += 1 if _feat(Vector2i(x, y)) == MCF.FEATURE_WALL else 0
	ck(vertical == 3 and ed._float.is_empty(), "the rotated wall lands as a vertical run of 3")
	_key(KEY_M)
	_drag(Vector2i(2, 2), Vector2i(4, 2))
	_press(Vector2i(3, 2))
	_move(Vector2i(3, 10))
	_press(Vector2i(3, 10), false)
	ck(_feat(Vector2i(3, 2)) == "" and _feat(Vector2i(3, 10)) == MCF.FEATURE_WALL,
			"dragging a selection moves it")
	_key(KEY_Z, true)
	ck(_feat(Vector2i(3, 2)) == MCF.FEATURE_WALL and _feat(Vector2i(3, 10)) == "", "one undo puts the move back")
	_drag(Vector2i(2, 2), Vector2i(4, 2))
	_key(KEY_X, true)
	ck(_feat(Vector2i(2, 2)) == "" and not ed._clipboard.is_empty(), "Ctrl+X cuts")
	_key(KEY_DELETE)
	_key(KEY_A, true)
	ck(ed._selection.size == Vector2i(ed.map.width, ed.map.height), "Ctrl+A selects the whole map")

# --- Заготовки ---
func _stamps() -> void:
	_fresh("station")
	ed._pick_stamp("small_room")
	ck(ed.tool == 7 and not ed._float.is_empty(), "a stamp from the palette is in hand")
	ed._hover = Vector2i(10, 10)
	_press(Vector2i(10, 10))
	ck(_feat(Vector2i(8, 8)) == MCF.FEATURE_WALL and _feat(Vector2i(10, 12)) == MCF.FEATURE_AIRLOCK
			and _feat(Vector2i(10, 10)) == "" and not ed.map.get_space(Vector2i(10, 10)),
			"Small room: walls, an airlock door, floor inside")
	ck(not ed._float.is_empty(), "the stamp stays in hand for the next one")
	ed.symmetry = 1
	_press(Vector2i(10, 20))
	ck(_feat(Vector2i(ed.map.width - 1 - 8, 18)) == MCF.FEATURE_WALL, "stamps follow symmetry")
	ed.symmetry = 0
	_key(KEY_H)
	_key(KEY_ESCAPE)
	ck(ed._float.is_empty(), "Esc drops the stamp")

# --- Предпросмотр под курсором ---
## Плитка под курсором у каждого инструмента. Прежде любой инструмент, кроме кисти и
## ластика, падал на присваивании нетипизированного массива при каждой отрисовке.
func _preview() -> void:
	_fresh("station")
	ed._select_brush(MCF.FEATURE_WALL)
	ed._hover = Vector2i(10, 10)
	for t: int in [0, 2, 3, 4]:   # кисть, линия, прямоугольник, заливка
		ed._select_tool(t)
		ed._build_preview()
		ck(ed._pv.size() == 1 and ed._pv[0][0] == Vector2i(10, 10) and ed._pv[0][3],
				"tool %d shows the wall tile under the cursor" % t)
	for t: int in [1, 5, 6]:   # ластик, выделение, пипетка
		ed._select_tool(t)
		ed._build_preview()
		ck(ed._pv.is_empty() and ed._pv_thumbs.is_empty(), "tool %d draws no tile ghost" % t)
	ed._select_tool(0)
	ed._set_brush_size(3)
	ed._build_preview()
	ck(ed._pv.size() == 9 and ed._pv_tint.a == 0.5, "a size-3 brush shows nine tiles at half opacity")
	ed._set_brush_size(1)
	ed._select_tool(2)
	ed._drag_start = Vector2i(3, 3)
	ed._drag_cur = Vector2i(7, 3)
	ed._build_preview()
	ck(ed._pv.size() == 5, "a line being dragged shows its five tiles")
	ed._drag_cur = Vector2i(35, 27)
	ed._build_preview()
	ck(ed._pv.size() == ed.line_cells(Vector2i(3, 3), Vector2i(35, 27)).size() and ed._pv_thumbs.is_empty(),
			"a long diagonal line still previews in real tiles (%d)" % ed._pv.size())
	ed._drag_start = Vector2i(-1, -1)
	ed._select_tool(0)
	ed._select_brush("floor")
	ed._build_preview()
	ck(ed._pv.is_empty(), "floor over floor changes nothing, so nothing is drawn")
	# Узор в руке — плитками; черновик не трогает журналы вида, по которым живёт кэш карты.
	var ver := GridCell.look_version
	var base := GridCell.look_log_base
	ed._pick_stamp("house")
	ed._build_preview()
	var walls := 0
	for e: Array in ed._pv:
		walls += 1 if e[3] else 0
	ck(walls == 22 and ed._pv_tint.a == 0.75, "the house stamp shows its 22 wall, window and door tiles (%d)" % walls)
	ck(GridCell.look_version == ver and GridCell.look_log_base == base,
			"building a preview leaves the map's tile cache alone")
	_key(KEY_ESCAPE)
	# Цвета мебели: кнопка на предмет, цвета — строкой под кистью.
	ck(ed._brush_buttons.has("bed") and not ed._brush_buttons.has("bed_red"),
			"colour variants are not separate palette buttons")
	ed._select_brush("bed_red")
	ck(ed._colour_row.visible and ed._colour_row.get_child_count() == 1 + Furniture.colours_of("bed").size()
			and (ed._brush_buttons["bed"] as Button).button_pressed,
			"a coloured bed lights the Bed button and shows the colour row")
	_drag(Vector2i(4, 4), Vector2i(4, 4))
	ed._select_brush("chair")
	ck(not ed._colour_row.visible, "a piece with one colour hides the row")
	_key(KEY_I)
	_press(Vector2i(4, 4))
	ck(ed.brush == "bed_red", "the eyedropper picks the colour too")

# --- Пипетка, нейтралы, зоны ---
func _picker_units_zones() -> void:
	_fresh("town")
	ed._select_brush("unit:marksman")
	_key(KEY_B)
	_drag(Vector2i(5, 5), Vector2i(5, 5))
	ck(ed.map.spawns.size() == 1 and ed.map.spawns[0]["stats_id"] == "marksman", "a neutral marksman is placed")
	ed._select_brush(MCF.FEATURE_GLASS)
	_drag(Vector2i(7, 7), Vector2i(7, 7))
	ed._select_brush("floor")
	_press(Vector2i(7, 7), true, true)
	ck(ed.brush == MCF.FEATURE_GLASS, "Alt+click picks the glass")
	_key(KEY_I)
	_press(Vector2i(5, 5))
	ck(ed.brush == "unit:marksman" and ed.tool == 0, "the eyedropper picks the unit and returns to the brush")
	_key(KEY_E)
	_drag(Vector2i(5, 5), Vector2i(5, 5))
	ck(ed.map.spawns.is_empty(), "the eraser removes the unit")
	_key(KEY_Z, true)
	ck(ed.map.spawns.size() == 1, "undo restores the unit")

# --- Размер, очистка ---
func _resize_clear() -> void:
	_fresh("field", 30, 20)
	ed._select_brush(MCF.FEATURE_WALL)
	_key(KEY_B)
	_drag(Vector2i(3, 3), Vector2i(3, 3))
	ed.resize_map(50, 35)
	ck(ed.map.width == 50 and _feat(Vector2i(3, 3)) == MCF.FEATURE_WALL
			and ed.map.get_floor(Vector2i(45, 30)) == MCF.FLOOR_GRASS and not ed.map.get_space(Vector2i(45, 30)),
			"resize keeps the drawing; new cells are Field grass, not space")
	ck(ed._grid.width == 50 and ed._mini_img.get_width() == 50, "the tile mirror and minimap follow the size")
	_key(KEY_Z, true)
	ck(ed.map.width == 30 and _feat(Vector2i(3, 3)) == MCF.FEATURE_WALL, "undo restores the old size")
	ed.clear_map()
	ck(_feat(Vector2i(3, 3)) == "", "Clear Map wipes the drawing")
	_key(KEY_Z, true)
	ck(_feat(Vector2i(3, 3)) == MCF.FEATURE_WALL, "and undoes")

# --- Файлы и генератор ---
func _files_and_generator() -> void:
	_fresh("asteroid", 36, 28)
	ed._select_brush(MCF.FEATURE_HEDGEHOG)
	_key(KEY_B)
	_drag(Vector2i(18, 14), Vector2i(18, 14))
	ed._save_named(SAVE_NAME)
	ck(not ed._dirty and ed.map_name == SAVE_NAME, "Save clears the unsaved mark")
	_fresh("town")
	ck(ed.open_map(SAVE_NAME + ".json"), "the saved map opens")
	ck(ed.map.env == "asteroid" and _feat(Vector2i(18, 14)) == MCF.FEATURE_HEDGEHOG and ed._undo_stack.is_empty(),
			"it comes back with its preset and drawing, and a fresh undo history")
	ed.create_map("gen", "bunker", Vector2i(40, 30), {"seed": 1234, "zones": 2, "density": 1})
	var zones := 0
	for i in ed.map.width * ed.map.height:
		zones += 1 if ed.map.zone_owner[i] >= 0 else 0
	ck(ed.map.env == "bunker" and zones > 0, "New Map from the generator: a Bunker map with zones (%d cells)" % zones)
	ck(ed._dirty and ed.map_name == "gen", "a generated map is unsaved until saved")

# --- Пробная партия и возврат ---
func _session() -> void:
	var m := MapData.new(20, 20)
	MapPresets.prefill(m, "field")
	m.set_cell(Vector2i(5, 5), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	MapHandoff.editor_session = {"map": m, "name": "trial", "dirty": true, "pan": Vector2(10, 10), "zoom": 0.7}
	var again: Node = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(again)
	ck(again.map == m and again.map_name == "trial" and again._dirty and is_equal_approx(again.zoom, 0.7),
			"back from Play This Map: the same map, name, view and unsaved mark")
	ck(MapHandoff.editor_session.is_empty(), "the session is used once")
	again.free()

## Мебель (§3.15) в палитре: кнопки с именем и высотой, мазок ставит предмет с его высотой,
## пипетка его узнаёт, карта с ним сохраняется и открывается.
func _furniture() -> void:
	_fresh("town")
	ck(ed._brush_buttons.has("bed") and ed._brush_buttons.has("storage_shelf"),
			"the palette has furniture buttons")
	ck(String((ed._brush_buttons["wardrobe"] as Button).text) == "Wardrobe 1.5",
			"a furniture button shows name and height (%s)" % (ed._brush_buttons["wardrobe"] as Button).text)
	ck(String((ed._brush_buttons["wardrobe"] as Button).tooltip_text).contains("durability 3"),
			"and its tooltip the rest")
	ed._select_brush("bed")
	ed.brush_size = 1
	_drag(Vector2i(6, 6), Vector2i(6, 6))
	ck(_feat(Vector2i(6, 6)) == "bed" and ed.map.get_cover(Vector2i(6, 6)) == 0.5, "painting places a bed at 0.5 m")
	ck(ed._brush_name("bed") == "Bed — 0.5 m", "the brush label names it with its height")
	ed._select_brush("floor")
	ed.pick_at(Vector2i(6, 6))
	ck(ed.brush == "bed", "the eyedropper picks furniture up as a brush")
	var back := MapData.from_dict(JSON.parse_string(JSON.stringify(ed.map.to_dict())))
	ck(back.get_feature(Vector2i(6, 6)) == "bed" and back.get_cover(Vector2i(6, 6)) == 0.5,
			"a map with furniture saves and loads")
	_key(KEY_E)
	_drag(Vector2i(6, 6), Vector2i(6, 6))
	ck(_feat(Vector2i(6, 6)) == "", "the eraser removes it")
	_key(KEY_B)
