extends "res://tests/SuiteBase.gd"
## Furniture in battle: one cell of a table breaks, cabinets spill once, pieces stay paired.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_cabinet_spill()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_partial_furniture()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_pairs_and_contents()

## A dragged cabinet opens and spills its contents once; it stays open where it goes.
func _cabinet_spill() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 18), "light_infantry", 1)
	m.set_cell(Vector2i(6, 5), MCF.FLOOR_NORMAL, Furniture.height_of("cabinet"), false, "cabinet")
	var st := m.build_state(4)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r := GameActionResolver.new(st)
	var u: UnitInstance = st.grid.cell(Vector2i(5, 5)).occupant
	var res := r.resolve(DragIntent.new(u.id, Vector2i(6, 5), Vector2i(6, 6)))
	ck(res.ok and st.grid.cell(Vector2i(6, 6)).feature_id == "cabinet", "the cabinet is dragged (%s)" % res.reason)
	var spill := res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "spill")
	var destination := Vector2i(6, 6)
	for attempt in 16:
		if not spill.is_empty(): break
		u.remaining_ap = 4
		u.dragging = UnitInstance.NOT_DRAGGING
		var next := Vector2i(6, 5) if destination.y == 6 else Vector2i(6, 6)
		res = r.resolve(DragIntent.new(u.id, destination, next))
		destination = next
		spill = res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "spill")
	ck(spill.size() == 1 and (st.grid.cell(destination).items_off & GridCell.OPENED) != 0, "it opens and spills")
	var fx := FxDecals.new()
	fx.apply(res.fx)
	ck(fx.flying.size() >= SmallItems.SPILL_MIN and fx.flying.all(func(f: Dictionary) -> bool:
			return SmallItems.SPILLS["cabinet"].has(str(f["kind"]).substr(5))), "with things a cabinet holds (%d)" % fx.flying.size())
	u.remaining_ap = 4
	u.dragging = UnitInstance.NOT_DRAGGING
	var next := Vector2i(6, 5) if destination.y == 6 else Vector2i(6, 6)
	var res2 := r.resolve(DragIntent.new(u.id, destination, next))
	ck(res2.ok and res2.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "spill").is_empty()
			and (st.grid.cell(next).items_off & GridCell.OPENED) != 0, "an open, empty cabinet spills nothing more")
	var res3 := ActionResult.new()
	r._blast(Vector2i(6, 5), res3, MCF.blast_square(Vector2i(6, 5), 1))
	ck((st.grid.cell(Vector2i(6, 5)).items_off & GridCell.OPENED) == 0, "a destroyed cabinet leaves no open flag behind")

## Smashing or blowing up one cell of a table destroys that cell only.
func _partial_furniture() -> void:
	var m := MapData.blank_arena(16, 10)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(15, 9), "light_infantry", 1)
	for x in range(6, 9):
		for y in range(4, 6):
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, Furniture.height_of("dining_table"), false, "dining_table")
	var st := m.build_state(3)
	var r := GameActionResolver.new(st)
	var res := ActionResult.new()
	r._destroy_furniture(st.grid.cell(Vector2i(6, 4)), res)
	var left := 0
	for x in range(6, 9):
		for y in range(4, 6):
			left += 1 if st.grid.cell(Vector2i(x, y)).feature_id == "dining_table" else 0
	ck(st.grid.cell(Vector2i(6, 4)).feature_id == "" and left == 5, "one destroyed cell leaves the other five (%d)" % left)
	var gres := ActionResult.new()
	r._blast(Vector2i(8, 5), gres, [Vector2i(8, 5)] as Array[Vector2i])
	left = 0
	for x in range(6, 9):
		for y in range(4, 6):
			left += 1 if st.grid.cell(Vector2i(x, y)).feature_id == "dining_table" else 0
	ck(st.grid.cell(Vector2i(8, 5)).feature_id == "" and left == 4, "a blast on one cell takes just that cell (%d left)" % left)

func _pairs_and_contents() -> void:
	var m := MapData.blank_arena(16, 12)
	for x in range(3, 9): m.set_cell(Vector2i(x, 4), 0, 1.0, false, "piano")
	for x in range(3, 9):
		var pair := Furniture.piece_cells(func(c: Vector2i) -> String: return m.get_feature(c), Vector2i(x, 4))
		ck(pair.size() == 2 and pair.has(Vector2i(3 + ((x - 3) / 2) * 2, 4)), "piano cell %d belongs to a consistent two-cell piece" % x)
	var long_row := func(c: Vector2i) -> String: return "piano" if c.y == 1 and c.x >= 0 and c.x < 40 else ""
	var reciprocal := true
	for x in 40:
		var c := Vector2i(x, 1)
		var pair := Furniture.piece_cells(long_row, c)
		reciprocal = reciprocal and pair == Furniture.piece_cells(long_row, Vector2i(x ^ 1, 1))
	ck(reciprocal, "piano pairing stays reciprocal beyond the whole-piece search cap")
	for item: String in SmallItems.KINDS:
		ck(Sprites.has_override("item_" + item), "item sprite exists: " + item)
	ck(Furniture.connects("storage_shelf", "storage_shelf_medical") and Furniture.connects("display_shelf_food", "display_shelf_drinks"), "different shelf contents join the same shelf structure")
	ck(not SmallItems.spills("storage_shelf_empty") and SmallItems.spill_contents("display_shelf_medical").has("medicine"), "empty shelves stay empty and filled shelves spill their displayed contents")
	var shelves := Grid.new(10, 10)
	for c: Vector2i in [Vector2i(3, 3), Vector2i(4, 3), Vector2i(4, 4), Vector2i(4, 5)]: shelves.cell(c).set_feature("display_shelf_food")
	var tiles := TerrainTiles.new(shelves, "town")
	var corner := tiles._live_look(Vector2i(4, 3), "display_shelf_food")
	var below := tiles._live_look(Vector2i(4, 4), "display_shelf_food")
	ck(corner[0] == 8 and below[0] == 2, "shelf rows cap both ends where a perpendicular row meets them")
	ck(not SmallItems.SPILLS.cabinet.has("plate") and SmallItems.SPILLS.refrigerator.has("meat"), "cabinet and refrigerator contents match their purpose")
	var old := MapData.blank_arena(8, 8)
	old.set_cell(Vector2i(2, 2), 0, 0.5, false, "toolbox")
	var migrated := MapData.from_dict(old.to_dict())
	ck(migrated.get_feature(Vector2i(2, 2)) == "" and migrated.items[0][0] == "toolbox", "old toolbox cover migrates to a loose item")
