class_name CheatOverlay
extends Node2D

var main: Node

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	if not is_instance_valid(main) or main.state == null or main._cheat_ids.is_empty(): return
	if main.replay != null or main._spectator or main._fp != null: return
	var side: int = main.net.my_owner if main.net != null else main._viewing_side()
	if not CheatAccess.permitted(main.state, side):
		main._cheat_ids = ""
		return
	var labels := {}
	if main._cheat_ids in ["units", "all"]:
		for unit: UnitInstance in main.state.all_units():
			if not main.state.grid.in_bounds(unit.coord): continue
			var cell: Vector2i = main._draw_cell(unit)
			if not labels.has(cell): labels[cell] = []
			labels[cell].append("U%d" % unit.id)
	if main._cheat_ids in ["vehicles", "all"]:
		for vehicle: Vehicle in main.state.all_vehicles():
			if not labels.has(vehicle.origin): labels[vehicle.origin] = []
			labels[vehicle.origin].append("V%d" % vehicle.id)
	var font := ThemeDB.fallback_font
	for cell: Vector2i in labels:
		var at: Vector2 = main.pan + (main._cell_origin(cell) + Vector2(main.CELL * 0.5, 0)) * main.zoom
		for id: String in labels[cell]:
			var width := font.get_string_size(id, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 8
			var box := Rect2(at + Vector2(-width * 0.5, -17), Vector2(width, 16))
			if get_viewport_rect().intersects(box):
				draw_rect(box, Color(0.015, 0.02, 0.03, 0.95))
				draw_string(font, box.position + Vector2(4, 12), id, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("ffda8c"))
			at.y -= 17
