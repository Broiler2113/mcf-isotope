extends SceneTree

## The deployment eraser takes our own soldiers off and refunds their points; the map
## editor resizes a map without wiping it, and its fill stops at walls. Both scenes get
## _ready only on the first frame, so the checks run from _process.

var fails: PackedStringArray = []
var _placement: Node = null
var _editor: Node = null
var _frame := 0

func ck(c: bool, w: String) -> void:
	if not c:
		fails.append(w)

func _initialize() -> void:
	# Сцены закупки и редактора получают _ready не раньше первого кадра — их проверяем
	# из _process.
	GameConfig.placement_mode = GameConfig.Placement.ASYMMETRIC
	GameConfig.civilians_enabled = false
	GameConfig.roster = null
	NetHandoff.session = null
	_placement = load("res://scenes/Placement.tscn").instantiate()
	root.add_child(_placement)
	_editor = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(_editor)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false
	_eraser()
	_editor_checks()
	if fails.is_empty():
		print("editor/run_eraser_and_resize: the eraser refunds, the editor resizes without wiping")
		quit(0)
	else:
		printerr("editor/run_eraser_and_resize: %d failure(s)" % fails.size())
		for f in fails:
			printerr("  " + f)
		quit(1)
	return true

func _eraser() -> void:
	var p = _placement
	p.brush_unit = "light_infantry"
	p._click_cell(Vector2i(2, 2)); p._click_cell(Vector2i(3, 2)); p._click_cell(Vector2i(4, 2))
	ck(p._side_unit_count(0) == 3, "placed 3")
	var spent0: int = p.spent[0]
	p._eraser_btn.button_pressed = true  # toggled -> _toggle_eraser
	ck(p._erasing and p.brush_unit == "", "eraser on clears the brush")
	ck(p._erase_at(Vector2i(2, 2)), "erase one")
	ck(p._side_unit_count(0) == 2 and p.spent[0] == spent0 - p._cost("light_infantry"), "count 2 and refund")
	p._ptool = p.PTool.RECT
	p._erase_many(p._rect_fill_cells(Vector2i(0, 0), Vector2i(10, 10)))
	ck(p._side_unit_count(0) == 0 and p.spent[0] == 0, "rect erase clears all")
	p._on_pick_unit("sniper")
	ck(not p._erasing and not p._eraser_btn.button_pressed, "picking a unit turns eraser off")

func _editor_checks() -> void:
	# Редактор переписан (editor-rework); здесь — прежние проверки batch 13/14 на новом API:
	# размер, кисть 5×5, стены прямоугольником, заливка внутри, размер сохраняет рисунок,
	# откат и повтор, новый мазок после отката обрывает ветку повтора.
	var ed = _editor
	ed.create_map("", "station", Vector2i(16, 12))
	ed.resize_map(120, 90)
	ck(ed.map.width == 120 and ed.map.height == 90, "editor resized")
	ed._select_brush("floor")
	ed._set_brush_size(5)
	ed._begin()
	ed._stroke_to(Vector2i(50, 50), false)
	ed._commit()
	ck(not ed.map.get_space(Vector2i(52, 52)) and not ed.map.get_space(Vector2i(48, 48)),
			"brush size 5 paints a 5x5 block")
	ed._select_brush(MCF.FEATURE_WALL)
	ed._begin()
	ed._paint_cells(ed.rect_cells(Vector2i(10, 10), Vector2i(60, 60), false), false)
	ed._commit()
	ed._select_brush("grass")
	ed._begin()
	ed._flood(Vector2i(30, 30), false)
	ed._commit()
	ck(ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS
			and ed.map.get_floor(Vector2i(5, 5)) != MCF.FLOOR_GRASS, "flood fill stays inside the walls")
	ed.resize_map(130, 70)
	ck(ed.map.get_feature(Vector2i(10, 30)) == MCF.FEATURE_WALL
			and ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS, "resize keeps what was drawn")
	ck(ed._mini_img.get_width() == 130 and ed._mini_img.get_height() == 70, "minimap follows the size")
	ed.undo()
	ck(ed.map.width == 120 and ed.map.height == 90 and ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS,
			"undo restores the previous size and keeps earlier strokes")
	ed.undo()
	ck(ed.map.get_floor(Vector2i(30, 30)) != MCF.FLOOR_GRASS and ed.map.get_feature(Vector2i(10, 30)) == MCF.FEATURE_WALL,
			"second undo takes the flood fill back but keeps the walls")
	ed.redo()
	ck(ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS, "redo brings the fill back")
	ed._select_brush(MCF.FEATURE_SANDBAGS)
	ed._set_brush_size(1)
	ed._stroke_last = Vector2i(-1, -1)
	ed._begin()
	ed._stroke_to(Vector2i(30, 30), false)
	ed._commit()
	ck(ed._redo_stack.is_empty() and ed.map.get_feature(Vector2i(30, 30)) == MCF.FEATURE_SANDBAGS,
			"a new stroke after undo clears the redo branch")
