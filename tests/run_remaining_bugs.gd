extends SceneTree

var fails: Array[String] = []

func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails.append(message)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_flame_immunity()
	_vacuum_debris()
	_shield_sweep()
	_decal_memory()
	_pressure_doors()
	_pairs_and_contents()
	_bodies()
	print("remaining bugs: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

func _flame_immunity() -> void:
	var m := MapData.blank_arena(18, 10)
	m.set_spawn(Vector2i(2, 5), "flamethrower", 0)
	m.set_spawn(Vector2i(4, 5), "flamethrower", 1)
	m.set_spawn(Vector2i(6, 5), "light_infantry", 1)
	m.set_cell(Vector2i(5, 5), MCF.FLOOR_NORMAL, Furniture.height_of("cabinet"), false, "cabinet")
	var st := m.build_state(9)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r := GameActionResolver.new(st)
	var target := st.grid.cell(Vector2i(4, 5)).occupant
	var victim := st.grid.cell(Vector2i(6, 5)).occupant
	var result := r.resolve(ShootIntent.new(st.grid.cell(Vector2i(2, 5)).occupant.id, target.id))
	ck(result.ok and target.is_alive() and not victim.is_alive(), "an enemy flamethrower survives the jet; ordinary infantry behind it burns")
	ck(not result.deaths.has(target.id) and result.deaths.has(victim.id), "the death list agrees with fire immunity")
	ck(st.grid.cell(Vector2i(5, 5)).feature_id == "" and st.grid.cell(Vector2i(5, 5)).on_fire, "flame consumes furniture on its path")

func _vacuum_debris() -> void:
	var fx := FxDecals.new()
	fx.bounds = Vector2(40, 40)
	fx.space_at = func(_c: Vector2i) -> bool: return true
	fx.apply([{"fx": "chunks", "at": Vector2i(20, 20), "from": Vector2i(19, 20), "seq": 7}])
	var n := fx.flying.size()
	fx.advance(0.6)
	var before := FxDecals.flight_pos(fx.flying[0])
	fx.advance(0.4)
	ck(fx.flying.size() == n and fx.props.is_empty(), "vacuum debris remains airborne after its normal landing time")
	ck(before.distance_to(FxDecals.flight_pos(fx.flying[0])) > 0.1, "vacuum debris retains momentum")
	var saved := fx.to_dict()
	var loaded := FxDecals.new()
	loaded.space_at = fx.space_at
	loaded.bounds = fx.bounds
	loaded.from_dict(saved)
	ck(loaded.flying.size() == n and loaded.props.is_empty(), "save/load preserves drifting debris without freezing it on space")
	fx.advance(100.0)
	ck(fx.flying.size() == n and fx.props.is_empty(), "debris keeps drifting beyond the edge of space")

func _shield_sweep() -> void:
	var m := MapData.blank_arena(18, 10)
	m.set_spawn(Vector2i(2, 5), "shield_bearer", 0)
	m.set_spawn(Vector2i(16, 8), "light_infantry", 1)
	m.items = [["mug", 4.5, 5.5, 0.0]]
	var st := m.build_state(3)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r := GameActionResolver.new(st)
	var fx := FxDecals.new()
	fx._settle(fx.props, {"kind": "chunk:wall_town#0", "pos": Vector2(4.4, 5.5), "rot": 0.0, "scale": 1.0})
	var result := r.resolve(MoveIntent.new(st.grid.cell(Vector2i(2, 5)).occupant.id, Vector2i(5, 5)))
	fx.apply(result.fx)
	ck(result.ok and (st.grid.cell(Vector2i(4, 5)).items_off & 1) != 0, "a shield-bearer pushes a map item crossed during a multi-cell move")
	ck(fx.props.is_empty() and fx.flying.size() >= 2, "the shield pushes settled debris and the loose item forward")

func _decal_memory() -> void:
	var fx := FxDecals.new()
	fx._settle(fx.props, {"kind": "casing", "pos": Vector2(1.5, 1.5), "rot": 0.0, "scale": 1.0})
	var memory := DecalMemory.new(fx)
	var visible := {Vector2i(1, 1): true, Vector2i(33, 1): true}
	memory.update(fx, visible, null, 64)
	fx._settle(fx.gore, {"kind": "blood_pool", "pos": Vector2(33.5, 1.5), "rot": 0.0, "scale": 1.0})
	memory.update(fx, visible, [], 64)
	ck(memory.view.by_chunk.get(Vector2i(2, 0), []).size() == 1, "new blood appears in a visible chunk even after props already exist")

func _pressure_doors() -> void:
	var m := MapData.blank_arena(18, 12)
	for c: Vector2i in [Vector2i(6, 5), Vector2i(8, 5)]: m.set_cell(c, 0, 2.0, false, MCF.FEATURE_AIRLOCK)
	for c: Vector2i in [Vector2i(7, 4), Vector2i(7, 6)]: m.set_cell(c, 0, 2.0, false, MCF.FEATURE_WALL)
	m.set_cell(Vector2i(9, 5), 0, 0.0, true, "")
	m.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	var st := m.build_state(1)
	var r := GameActionResolver.new(st)
	var unit := st.grid.cell(Vector2i(5, 5)).occupant
	var a := st.grid.cell(Vector2i(6, 5))
	var b := st.grid.cell(Vector2i(8, 5))
	r.update_airlocks()
	ck(a.cover_height == 0 and b.cover_height == 2, "approaching a pressure chamber opens only its entry door")
	st.grid.cell(unit.coord).occupant = null
	unit.coord = Vector2i(7, 5)
	st.grid.cell(unit.coord).occupant = unit
	r.update_airlocks()
	ck((a.cover_height == 0) != (b.cover_height == 0), "standing between pressure doors never opens both")
	st.grid.cell(unit.coord).occupant = null
	unit.coord = Vector2i(8, 5)
	st.grid.cell(unit.coord).occupant = unit
	r.update_airlocks()
	ck(a.cover_height == 2 and b.cover_height == 0, "the inner door seals when the outer door is occupied")

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

func _bodies() -> void:
	var m := MapData.blank_arena(10, 10)
	m.corpses = PackedInt32Array([22, 22, 22, 22, 22, 34])
	var grid := Grid.new(10, 10)
	m.apply_to_grid(grid)
	ck(grid.cell(Vector2i(2, 2)).feature_id == MCF.FEATURE_CORPSE_WALL and grid.cell(Vector2i(4, 3)).corpse_count == 1, "map bodies become real corpses and a five-body wall")
	m.apply_to_grid(grid)
	ck(grid.cell(Vector2i(4, 3)).corpse_count == 1, "applying a map twice does not duplicate its bodies")
	var captured := MapPresets.capture(m, Rect2i(1, 1, 5, 4))
	var turned := MapPresets.rotated(captured)
	ck(captured.corpses.size() == 6 and turned.corpses[-1] == [1, 3], "copying and rotating a selection preserves real bodies")
