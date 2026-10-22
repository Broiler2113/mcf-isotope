extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapData.blank_arena(16, 14)
	map.set_spawn(Vector2i(5, 5), "borg", 0)
	map.set_spawn(Vector2i(4, 5), "engineer", 0)
	map.set_spawn(Vector2i(12, 10), "light_infantry", 1)
	var state := map.build_state(9)
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	var r := GameActionResolver.new(state)
	var engineer := state.grid.cell(Vector2i(4, 5)).occupant
	var borg: Vehicle = state.all_vehicles()[0]
	ck(r.resolve(VehicleBoardIntent.new(engineer.id, borg.id)).ok, "engineer boards the borg")
	engineer.remaining_ap = 1
	var cells := [Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4), Vector2i(6, 5)]
	var kinds := [MCF.FEATURE_WALL, MCF.FEATURE_GLASS, MCF.FEATURE_AIRLOCK, MCF.FEATURE_WALL]
	for i in 4: state.grid.cell(cells[i]).set_feature(kinds[i])
	for i in 3:
		var result := r.resolve(BreakIntent.new(engineer.id, cells[i]))
		ck(result.ok and engineer.remaining_ap == 0, "demolition %d uses one three-part AP batch: %s" % [i + 1, result.reason])
	ck(not r.resolve(BreakIntent.new(engineer.id, cells[3])).ok, "a fourth demolition needs another AP")
	ck(r.resolve(UndoIntent.new(0)).ok and state.grid.cell(cells[2]).feature_id == MCF.FEATURE_AIRLOCK, "undo restores the third structure and its batch credit")
	ck(r.resolve(BreakIntent.new(engineer.id, cells[2])).ok, "the restored credit can be used again")
	engineer.remaining_ap = 1
	var door := state.grid.cell(cells[0])
	door.set_feature(MCF.FEATURE_AIRLOCK)
	ck(r.resolve(WeldAirlockIntent.new(engineer.id, cells[0])).ok and door.airlock_welded, "engineer welds a door")
	ck(r.unweldable_cells(engineer).has(cells[0]), "cutting a welded door is offered with batch credit at zero AP")
	ck(r.resolve(WeldAirlockIntent.new(engineer.id, cells[0])).ok and not door.airlock_welded, "engineer cuts the weld using the same batch")
	ck(door.cover_height < MCF.WALL_HEIGHT, "cut door opens for the adjacent engineer")
