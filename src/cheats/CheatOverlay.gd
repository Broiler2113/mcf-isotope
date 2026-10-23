class_name CheatOverlay
extends Node2D

const FONT_SIZE := 12
const LABEL_HEIGHT := 16
const COORD_FONT_SIZE := 10
const COORD_LABEL_HEIGHT := 14
var main: Node

func _process(_delta: float) -> void:
	queue_redraw()

func labels() -> Dictionary:
	var out := {}
	if main._cheat_ids in ["units", "all"]:
		for unit: UnitInstance in main.state.all_units():
			var cell := CorpseIdentity.cell_of(main.state, unit)
			# Follow living walkers (including the bodies in their arms). A loose
			# corpse is drawn on its actual tile, never at an old walk-animation cell.
			if unit.status != MCF.Status.CORPSE:
				cell = main._walk_cells.get(unit.id, cell)
			elif unit.corpse_carrier_id >= 0:
				cell = main._walk_cells.get(unit.corpse_carrier_id, cell)
			if not main.state.grid.in_bounds(cell): continue
			if not out.has(cell): out[cell] = []
			out[cell].append(CorpseIdentity.id_label(unit))
	if main._cheat_ids in ["vehicles", "all"]:
		for vehicle: Vehicle in main.state.all_vehicles():
			if not out.has(vehicle.origin): out[vehicle.origin] = []
			out[vehicle.origin].append("V%d" % vehicle.id)
	return out

func label_box(cell: Vector2i, text: String, row := 0) -> Rect2:
	var at: Vector2 = main.pan + (main._cell_origin(cell) + Vector2(main.CELL * 0.5, 0)) * main.zoom
	var width := ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + 8
	return Rect2(at + Vector2(-width * 0.5, -17 * (row + 1)), Vector2(width, LABEL_HEIGHT))

func coordinate_box(cell: Vector2i) -> Rect2:
	var text := "(%d,%d)" % [cell.x, cell.y]
	var width := ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, COORD_FONT_SIZE).x + 6
	return Rect2(main._cell_screen(cell) + Vector2(2, 1), Vector2(width, COORD_LABEL_HEIGHT))

func _draw() -> void:
	if not is_instance_valid(main) or main.state == null: return
	if main.replay != null or main._spectator or main._fp != null: return
	var side: int = main.net.my_owner if main.net != null else main._viewing_side()
	if not CheatAccess.permitted(main.state, side):
		main._cheat_ids = ""
		main._cheat_coords = false
		return
	var font := ThemeDB.fallback_font
	# Both kinds of labels draw in screen pixels; zoom affects their anchors only.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var by_cell := labels()
	for cell: Vector2i in by_cell:
		for row in by_cell[cell].size():
			var id: String = by_cell[cell][row]
			var box := label_box(cell, id, row)
			if get_viewport_rect().intersects(box):
				draw_rect(box, Color(0.015, 0.02, 0.03, 0.95))
				draw_string(font, box.position + Vector2(4, 12), id, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color("ffda8c"))
	if main._cheat_coords:
		var first: Vector2i = main._pos_to_cell(Vector2.ZERO).max(Vector2i.ZERO)
		var last: Vector2i = main._pos_to_cell(get_viewport_rect().size).min(Vector2i(main.state.grid.width - 1, main.state.grid.height - 1))
		var widest := coordinate_box(Vector2i(main.state.grid.width - 1, main.state.grid.height - 1)).size
		var step_x := maxi(1, ceili((widest.x + 2) / (main.CELL * main.zoom)))
		var step_y := maxi(1, ceili((widest.y + 2) / (main.CELL * main.zoom)))
		for y in range(first.y + posmod(-first.y, step_y), last.y + 1, step_y):
			for x in range(first.x + posmod(-first.x, step_x), last.x + 1, step_x):
				var text := "(%d,%d)" % [x, y]
				var box := coordinate_box(Vector2i(x, y))
				draw_rect(box, Color(0.01, 0.015, 0.025, 0.78))
				draw_string(font, box.position + Vector2(3, 11), text, HORIZONTAL_ALIGNMENT_LEFT, -1, COORD_FONT_SIZE, Color("b9d9e9"))
