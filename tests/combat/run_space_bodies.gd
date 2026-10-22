extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(24, 16)
	map.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	map.set_cell(Vector2i(6, 5), MCF.FLOOR_NORMAL, 0, true, "")
	var r := GameActionResolver.new(map.build_state(9))
	r.state.turns.round_order.assign([0, 1])
	r.state.turns.active_index = 0
	var u := r.state.grid.cell(Vector2i(5, 5)).occupant
	u.carried_corpses = 1
	u.remaining_ap = 3
	var space := Vector2i(6, 5)
	ck(r.corpse_drop_cells(u).has(space), "space is offered as a corpse drop target")
	var twin := GameActionResolver.new(StateCodec.decode(StateCodec.encode(r.state)))
	var intent := DropCorpseIntent.new(u.id, space)
	var result := r.resolve(intent)
	var other := twin.resolve(IntentCodec.decode(IntentCodec.encode(intent)))
	ck(result.ok and other.ok, "host and guest both accept a drop into space")
	ck(r.state.grid.cell(space).corpse_count == 1 and u.carried_corpses == 0, "the body stays on the space cell")
	ck(JSON.stringify(StateCodec.encode(r.state)) == JSON.stringify(StateCodec.encode(twin.state)), "space drops remain deterministic")
	var loaded := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state))))
	ck(loaded.grid.cell(space).corpse_count == 1 and loaded.grid.cell(space).is_space, "a save retains the body and vacuum")
	ck(r.resolve(UndoIntent.new(0)).ok and r.state.grid.cell(space).corpse_count == 0,
			"undo removes a dropped body from space")
	ck(r.resolve(RedoIntent.new(0)).ok and r.state.grid.cell(space).corpse_count == 1,
			"redo returns the same body to space")
	# Pull an actual crew body out through a hull door onto the same space tile.
	var vehicle := r.state.spawn_vehicle("tank", Vector2i(2, 2), 0)
	ck(vehicle != null, "vehicle fixture exists")
	ck(r.unload_corpse_cells(u, vehicle).has(space), "unloading a crew corpse also offers space")
	vehicle.corpse_slots.append("light_infantry")
	var pulled := r.resolve(VehicleUnloadCorpseIntent.new(u.id, vehicle.id, space))
	ck(pulled.ok and vehicle.corpse_slots.is_empty() and r.state.grid.cell(space).corpse_count == 2,
			"a corpse can be pulled out of a vehicle onto a space tile")
	var body := r.state.spawn_unit(u.stats, Vector2i(4, 5), 0)
	body.status = MCF.Status.CORPSE
	var target := Vector2i(5, 6)
	r.state.grid.cell(target).is_space = true
	ck(r.drag_dest_cells(u, body.coord).has(target), "direct dragging offers adjacent space")
	var dragged := r.resolve(DragIntent.new(u.id, body.coord, target))
	ck(dragged.ok and r.state.grid.cell(target).occupant == body, "a corpse can also be dragged directly into space")
