extends "res://tests/SuiteBase.gd"
## Movement: group moves fall back, pressure doors, undo after building an LDF wall.

func run() -> void:
	_group_move_falls_back()

	await undo_after_ldf()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_pressure_doors()

func _field(spawns: Array, walls: Array = [], civ := false) -> Dictionary:
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for w: Vector2i in walls:
		m.set_cell(w, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = civ
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var guard := 0  # сторона может быть выбита первым же слотом жителей — не зацикливаемся
	while st.active_player() != MCF.Owner.PLAYER_1 and guard < 8:
		r.resolve(EndTurnIntent.new())
		guard += 1
	return {"s": st, "r": r}

func _u(st: GameState, c: Vector2i) -> UnitInstance:
	return st.grid.cell(c).occupant

func _group_move_falls_back() -> void:
	# corridor row 5 between walls; A ahead at (6,5), B behind at (5,5); both ordered to (9,5):
	# A takes (9,5), B's only route runs through A's old cell and ends at (8,5).
	var walls: Array = []
	for x in range(3, 12):
		walls.append(Vector2i(x, 4))
		walls.append(Vector2i(x, 6))
	var f := _field([[Vector2i(6, 5), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(5, 5), "light_infantry", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var a := _u(st, Vector2i(6, 5))
	var b := _u(st, Vector2i(5, 5))
	# order B first so its planned target (8,5) is what A would also like — then A is
	# dispatched to (9,5) fine; now the reverse: B is told to go to (9,5) itself (taken by A).
	var ids: Array[int] = [a.id, b.id]
	var dests: Array[Vector2i] = [Vector2i(9, 5), Vector2i(9, 5)]
	var res := r.resolve(GroupMoveIntent.new(ids, dests))
	ck(res.ok, "group order: " + res.reason)
	ck(a.coord == Vector2i(9, 5), "leader reached the target (%s)" % str(a.coord))
	ck(b.coord == Vector2i(8, 5), "the blocked mover fell back to the nearest reachable cell (%s)" % str(b.coord))

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func undo_after_ldf() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	map.set_spawn(Vector2i(10, 8), "engineer", 0)
	MapHandoff.pending = map
	var board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	board.state.turns.round_order.assign([0, 1])
	board.state.turns.active_index = 0
	board._refresh_status()
	var eng: UnitInstance = board.state.grid.cell(Vector2i(10, 8)).occupant
	eng.held_item_id = MCF.ITEM_LDF
	eng.remaining_ap = 6
	board._select(eng)
	board._enter_build_wall()
	for x in range(11, 17):
		board._wall_try_add(Vector2i(x, 8))
	for i in 120:
		await process_frame
		if not board._animating: break
	ck(board.state.grid.cell(Vector2i(12, 8)).feature_id == MCF.FEATURE_LDF and board._wall_cells.is_empty(),
		"a built LDF wall leaves no drawing behind")
	board._deselect()
	var u: UnitInstance = board.state.grid.cell(Vector2i(3, 4)).occupant
	board._submit(MoveIntent.new(u.id, Vector2i(5, 4)))
	for i in 120:
		await process_frame
		if not board._animating: break
	board._on_undo_pressed()
	for i in 30:
		await process_frame
	ck(u.coord == Vector2i(3, 4), "Undo takes back the move made after building an LDF wall")
	board.queue_free()
	await process_frame

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
