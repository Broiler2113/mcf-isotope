class_name CheatOverlay
extends Node2D

const FONT_SIZE := 12
const LABEL_HEIGHT := 16
const COORD_FONT_SIZE := 10
const COORD_LABEL_HEIGHT := 14
var main: Node
var _coordinates: Node2D
var _coordinate_cells := Rect2i()
var _coordinate_zoom := -1.0
var _widths := {}

func _ready() -> void:
	# Retain coordinate drawing between camera changes. A distant map still has
	# one label per tile; rebuilding thousands of strings every frame is wasteful.
	_coordinates = Node2D.new()
	_coordinates.draw.connect(_draw_coordinates)
	add_child(_coordinates)

func _process(_delta: float) -> void:
	if not is_instance_valid(main) or main.state == null: return
	var enabled := _enabled()
	_coordinates.visible = enabled and main._cheat_coords
	_coordinates.position = main.pan
	if _coordinates.visible:
		var cells := visible_coordinate_cells()
		if cells != _coordinate_cells or main.zoom != _coordinate_zoom:
			_coordinate_cells = cells
			_coordinate_zoom = main.zoom
			_coordinates.queue_redraw()
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

func _text_width(text: String, font_size: int) -> float:
	var key := "%d:%s" % [font_size, text]
	if not _widths.has(key):
		_widths[key] = ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	return _widths[key]

func label_box(cell: Vector2i, text: String, row := 0, count := 1) -> Rect2:
	var tile: float = main.CELL * main.zoom
	var margin: float = 2.0 * main.zoom
	var width := _text_width(text, FONT_SIZE) + 8
	# Coordinates occupy the top of the tile; IDs stack upward from its bottom.
	# Fit even long vehicle IDs and a pile of corpses inside that same tile.
	var available: float = tile - 2 * margin
	if main._cheat_coords: available -= COORD_LABEL_HEIGHT * main.zoom
	var slot := available / maxi(count, row + 1)
	var gap := minf(main.zoom, slot * 0.1)
	var fit := minf(minf(main.zoom, 1.0), minf((tile - 2 * margin) / width, (slot - gap) / LABEL_HEIGHT))
	var size := Vector2(width, LABEL_HEIGHT) * fit
	return Rect2(main._cell_screen(cell) + Vector2((tile - size.x) * 0.5, tile - margin - row * slot - size.y), size)

func coordinate_box(cell: Vector2i) -> Rect2:
	var text := "(%d,%d)" % [cell.x, cell.y]
	var width := _text_width(text, COORD_FONT_SIZE) + 6
	var fit := minf(minf(main.zoom, 1.0), (main.CELL - 4) * main.zoom / width)
	return Rect2(main._cell_screen(cell) + Vector2(2, 1) * main.zoom, Vector2(width, COORD_LABEL_HEIGHT) * fit)

func visible_coordinate_cells() -> Rect2i:
	var first: Vector2i = main._pos_to_cell(Vector2.ZERO).max(Vector2i.ZERO)
	var last: Vector2i = main._pos_to_cell(get_viewport_rect().size).min(Vector2i(main.state.grid.width - 1, main.state.grid.height - 1))
	return Rect2i(first, (last - first + Vector2i.ONE).max(Vector2i.ZERO))

func _enabled() -> bool:
	if main.replay != null or main._spectator or main._fp != null: return false
	var side: int = main.net.my_owner if main.net != null else main._viewing_side()
	if not CheatAccess.permitted(main.state, side):
		main._cheat_ids = ""
		main._cheat_coords = false
		return false
	return true

func _draw() -> void:
	if not is_instance_valid(main) or main.state == null or not _enabled(): return
	var by_cell := labels()
	for cell: Vector2i in by_cell:
		for row in by_cell[cell].size():
			var id: String = by_cell[cell][row]
			var box := label_box(cell, id, row, by_cell[cell].size())
			if get_viewport_rect().intersects(box):
				_draw_label(self, box, id, FONT_SIZE, LABEL_HEIGHT, Vector2(4, 12), Color(0.015, 0.02, 0.03, 0.95), Color("ffda8c"))

func _draw_coordinates() -> void:
	for y in range(_coordinate_cells.position.y, _coordinate_cells.end.y):
		for x in range(_coordinate_cells.position.x, _coordinate_cells.end.x):
			var text := "(%d,%d)" % [x, y]
			var box := coordinate_box(Vector2i(x, y))
			box.position -= main.pan
			_draw_label(_coordinates, box, text, COORD_FONT_SIZE, COORD_LABEL_HEIGHT, Vector2(3, 11), Color(0.01, 0.015, 0.025, 0.78), Color("b9d9e9"))

func _draw_label(canvas: Node2D, box: Rect2, text: String, font_size: int, height: float, inset: Vector2, background: Color, color: Color) -> void:
	var fit := box.size.y / height
	if fit <= 0: return
	canvas.draw_set_transform(box.position, 0, Vector2.ONE * fit)
	canvas.draw_rect(Rect2(Vector2.ZERO, box.size / fit), background)
	canvas.draw_string(ThemeDB.fallback_font, inset, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
