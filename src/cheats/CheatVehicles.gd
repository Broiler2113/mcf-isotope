class_name CheatVehicles
extends RefCounted

static func _facing(value: String) -> Vector2i:
	return {"n": Vector2i.UP, "e": Vector2i.RIGHT, "s": Vector2i.DOWN, "w": Vector2i.LEFT}.get(value, Vector2i.RIGHT)

static func _empty(veh: Vehicle) -> bool:
	return veh.occupants.is_empty() and veh.corpse_slots.is_empty() and veh.seats.all(func(id: int): return id == -1)

static func _placement(state: GameState, type: String, at: Vector2i, current: Vehicle = null, pilot: UnitInstance = null) -> String:
	var size := VehicleDB.size_of(type)
	for y in size.y:
		for x in size.x:
			var cell := state.grid.cell(at + Vector2i(x, y))
			if cell == null: return "The complete vehicle footprint must fit on the board."
			if cell.is_space or cell.is_wall() or cell.blocks_move() or Furniture.blocks_move(cell.feature_id) or cell.corpse_count > 0:
				return "The footprint overlaps blocked terrain, space or bodies."
			if cell.vehicle_id != -1 and (current == null or cell.vehicle_id != current.id): return "The footprint overlaps another vehicle."
			if cell.occupant != null and cell.occupant != pilot and (current == null or not current.occupants.has(cell.occupant.id)):
				return "The footprint overlaps a unit or corpse."
	return ""

static func spawn(r: GameActionResolver, args: Dictionary) -> ActionResult:
	var type: String = args.type
	var at := Vector2i(args.x, args.y)
	var spec := VehicleDB.get_vehicle(type)
	if args.has("facing") and not spec.get("has_facing", false): return ActionResult.fail("This vehicle has no facing; omit that argument.")
	var pilot: UnitInstance = null
	if type == "borg":
		var cell := r.state.grid.cell(at)
		pilot = cell.occupant if cell != null else null
		if pilot == null or not pilot.is_alive() or pilot.is_drone or pilot.owner != args.owner \
				or pilot.borg_id != -1 or pilot.aboard_vehicle_id != -1 or r.held_unit_of(pilot) != null:
			return ActionResult.fail("A Borg requires a living, unbound soldier of the chosen owner at its origin.")
	var error := _placement(r.state, type, at, null, pilot)
	if not error.is_empty(): return ActionResult.fail(error)
	var veh := r.state.spawn_vehicle(type, at, args.owner)
	if args.has("facing"): veh.facing = _facing(args.facing)
	if pilot != null:
		# Same invariant as boarding: the operator occupies the cell, the Borg follows.
		r.state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
		pilot.borg_id = veh.id
		veh.occupants.assign([pilot.id])
		CheatUnits.refill(pilot)
	return CheatUnits.result("Created %d — %s for %s at %s." % [veh.id, spec.get("name", type), r.state.roster.name_of(veh.owner), at])

static func apply(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var args := intent.args
	if intent.op == "spawn_vehicle": return spawn(r, args)
	var veh := r.state.get_vehicle(args.vehicle)
	if veh == null: return ActionResult.fail("Vehicle ID no longer exists.")
	var label := "%d — %s" % [veh.id, VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)]
	match intent.op:
		"vehicle_clone":
			var copy := {"type": veh.type_id, "owner": veh.owner, "x": args.x, "y": args.y}
			if veh.facing != Vector2i.ZERO:
				copy.facing = ["n", "e", "s", "w"][[Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT].find(veh.facing)]
			return spawn(r, copy)
		"vehicle_owner", "vehicle_remove":
			if not _empty(veh): return ActionResult.fail("Empty the vehicle, including bodies and mounted stations, first.")
			for unit: UnitInstance in r.state.all_units():
				if unit.borg_id == veh.id or unit.aboard_vehicle_id == veh.id: return ActionResult.fail("Remove linked crew or bodies first.")
			if intent.op == "vehicle_owner":
				var old := veh.owner
				veh.owner = args.owner
				return CheatUnits.result("%s owner: %s → %s." % [label, r.state.roster.name_of(old), r.state.roster.name_of(veh.owner)])
			r.state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
			r.state.remove_vehicle(veh.id)
			UnitInstance.vision_epoch += 1
			return CheatUnits.result(label + " removed.")
		"vehicle_repair":
			if veh.wrecked or not veh.alive(): return ActionResult.fail("The hull is gone; ordinary rules do not permit restoring this wreck.")
			var old := veh.components.duplicate()
			for component: String in veh.components: veh.components[component] = veh.component_max(component)
			veh.tower_locked_dir = Vector2i.ZERO
			return CheatUnits.result("%s components: %s → %s." % [label, old, veh.components])
		"vehicle_component":
			if veh.wrecked or not veh.alive(): return ActionResult.fail("A destroyed hull cannot be restored by component repair.")
			if not veh.has_component(args.component): return ActionResult.fail("This vehicle does not have that component.")
			var maximum := veh.component_max(args.component)
			var value := maximum if args.value is String else int(args.value)
			if value > maximum: return ActionResult.fail("Component maximum is %d." % maximum)
			var old := veh.component(args.component)
			var out := CheatUnits.result("%s %s: %d → %d." % [label, args.component, old, value])
			if value < old:
				r._damage_component(veh, args.component, old - value, "cheat", out)
			else:
				veh.components[args.component] = value
				if args.component == MCF.COMP_TOWER and value > 0: veh.tower_locked_dir = Vector2i.ZERO
			return out
		"vehicle_destroy":
			if veh.wrecked: return ActionResult.fail("Vehicle is already a wreck.")
			var out := CheatUnits.result(label + " destroyed.")
			r._destroy_vehicle(veh, out)
			return out
		"vehicle_move":
			if args.has("facing") and veh.facing == Vector2i.ZERO: return ActionResult.fail("This vehicle has no facing; omit that argument.")
			if not veh.corpse_slots.is_empty(): return ActionResult.fail("Unload vehicle bodies before teleporting it.")
			for sid: int in veh.seats:
				if sid < -1: return ActionResult.fail("Pack mounted stations or guns before teleporting the shuttle.")
				var occupant := r.state.get_unit(sid)
				if occupant != null and not occupant.is_alive(): return ActionResult.fail("Unload seated bodies first.")
			var at := Vector2i(args.x, args.y)
			var error := _placement(r.state, veh.type_id, at, veh)
			if not error.is_empty(): return ActionResult.fail(error)
			var old := veh.origin
			var riders: Array[UnitInstance] = []
			for id: int in veh.occupants:
				var unit := r.state.get_unit(id)
				if unit != null and r.state.grid.in_bounds(unit.coord): riders.append(unit)
			for unit: UnitInstance in riders:
				if r.state.grid.cell(unit.coord).occupant == unit: r.state.grid.cell(unit.coord).occupant = null
			r.state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
			veh.origin = at
			if args.has("facing"): veh.facing = _facing(args.facing)
			veh.move_credit = 0
			if not veh.is_borg() or riders.is_empty(): r.state.grid.set_vehicle_footprint(veh.id, veh.footprint())
			for unit: UnitInstance in riders:
				unit.coord += at - old
				r.state.grid.cell(unit.coord).occupant = unit
				unit.move_credit = 0
				unit.action_state = null
			return CheatUnits.result("%s origin: %s → %s." % [label, old, at])
	return ActionResult.fail("Unknown vehicle operation.")
