class_name CheatUnits
extends RefCounted

static func result(detail: String) -> ActionResult:
	var out := ActionResult.success()
	out.cheat_output = detail
	return out

static func refill(unit: UnitInstance) -> void:
	unit.reset_ap()
	unit.dig_credits = 0
	unit.dragging = UnitInstance.NOT_DRAGGING

static func linked(r: GameActionResolver, unit: UnitInstance) -> String:
	if unit.corpse_carrier_id >= 0: return "This body is being carried."
	if unit.corpse_stacked: return "This body is part of a corpse pile."
	if unit.captor_id != -1 or r.held_unit_of(unit) != null: return "Release captives first."
	if unit.aboard_vehicle_id != -1 or unit.borg_id != -1: return "Disembark from the vehicle first."
	if unit.carried_corpses > 0: return "Drop carried corpses first."
	if unit.is_drone: return "This operation is not supported for a linked drone."
	for drone: UnitInstance in r.state.all_units():
		if drone.is_alive() and drone.is_drone and drone.operator_id == unit.id: return "Recover this operator's active drones first."
	for cell: GridCell in r.state.grid.cells_flat():
		if cell.feature_id == MCF.FEATURE_DRONE_STATION and cell.station_operator_id == unit.id:
			return "Pack this operator's deployed station first."
	return ""

static func cell_error(state: GameState, coord: Vector2i, unit: UnitInstance = null) -> String:
	var cell := state.grid.cell(coord)
	if cell == null: return "Destination is outside the board."
	if cell.is_space or cell.is_wall() or cell.blocks_move() or Furniture.blocks_move(cell.feature_id): return "Destination is not walkable terrain."
	if cell.vehicle_id != -1 or cell.corpse_count > 0: return "Destination contains a vehicle or bodies."
	if cell.occupant != null and cell.occupant != unit: return "Destination is occupied."
	return ""

static func ring_cells(center: Vector2i, grid: Grid) -> Array[Vector2i]:
	var out: Array[Vector2i] = [center]
	# Clockwise square rings, beginning at the upper-left corner. Each cell once.
	for radius in range(1, maxi(grid.width, grid.height)):
		for x in range(center.x - radius, center.x + radius + 1):
			var at := Vector2i(x, center.y - radius)
			if grid.in_bounds(at): out.append(at)
		for y in range(center.y - radius + 1, center.y + radius + 1):
			var at := Vector2i(center.x + radius, y)
			if grid.in_bounds(at): out.append(at)
		for x in range(center.x + radius - 1, center.x - radius - 1, -1):
			var at := Vector2i(x, center.y + radius)
			if grid.in_bounds(at): out.append(at)
		for y in range(center.y + radius - 1, center.y - radius, -1):
			var at := Vector2i(center.x - radius, y)
			if grid.in_bounds(at): out.append(at)
	return out

static func spawn(r: GameActionResolver, args: Dictionary, source: UnitInstance = null) -> ActionResult:
	var state := r.state
	var type: String = source.stats.id if source != null else args.type
	var owner: int = source.owner if source != null else args.owner
	var requested := int(args.get("count", 1))
	var center := Vector2i(args.x, args.y)
	var stats: UnitStats = load("res://src/data/units/%s.tres" % type)
	var ids: Array[int] = []
	var drone_type := type in [MCF.DRONE_STATS_ID, MCF.SCOUT_DRONE_STATS_ID]
	var pilot: UnitInstance = null
	var station := Vector2i(-1, -1)
	if drone_type:
		for unit: UnitInstance in state.all_units():
			if unit.is_alive() and unit.owner == owner and unit.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR:
				var stations := r.stations_near(unit)
				if not stations.is_empty(): pilot = unit; station = stations[0]; break
		if pilot == null: return ActionResult.fail("A living operator beside an owned drone station is required.")
	var cells: Array[Vector2i] = []
	cells.assign([center] if requested == 1 else ring_cells(center, state.grid))
	for coord: Vector2i in cells:
		if ids.size() >= requested: break
		var unit: UnitInstance
		if drone_type:
			var cell := state.grid.cell(coord)
			if cell.feature_id == MCF.FEATURE_BOUNDARY or cell.is_wall() or r._drone_at(coord) != null: continue
			unit = state.spawn_unit(stats, coord, owner, false)
			unit.is_drone = true
			unit.home_station = station
			unit.operator_id = pilot.id
		else:
			if not cell_error(state, coord).is_empty(): continue
			unit = state.spawn_unit(stats, coord, owner)
		if unit == null: continue
		if source != null: unit.held_item_id = source.held_item_id
		if MCF.is_independent(owner): unit.neutral_group = MCF.independent_index(owner)
		ids.append(unit.id)
	if ids.is_empty(): return ActionResult.fail("Placed 0 of %d: no legal destination cells." % requested)
	state.roster.set_eliminated(owner, false)
	state.turns.eliminated.erase(owner)
	state.roster.assign_independent_color(owner, hash([state.turns.round_order, state.turns.round_number, state.all_units().size()]))
	if MCF.is_independent(owner) and not state.turns.round_order.has(owner):
		state.turns.insert_slot(owner, state.turns.round_order.size())
	var detail := "Placed %d of %d %s; IDs: %s." % [ids.size(), requested, stats.display_name, str(ids)]
	if ids.size() < requested: detail += " Remaining placements failed because no legal cells were available."
	return result(detail)

static func apply(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var args := intent.args
	var state := r.state
	if intent.op == "spawn_unit": return spawn(r, args)
	var unit := state.get_unit(args.unit)
	if unit == null: return ActionResult.fail("Unit ID no longer exists.")
	var name := "%d - %s" % [unit.id, unit.stats.display_name]
	match intent.op:
		"unit_remove", "unit_teleport", "unit_owner", "unit_revive":
			var error := linked(r, unit)
			if not error.is_empty(): return ActionResult.fail(error)
	match intent.op:
		"unit_clone":
			if not unit.is_alive() or not state.grid.in_bounds(unit.coord) or unit.aboard_vehicle_id != -1 or unit.borg_id != -1: return ActionResult.fail("Clone requires a living on-board unit outside a vehicle.")
			return spawn(r, args, unit)
		"unit_kill":
			if not unit.is_on_field(): return ActionResult.fail("Unit is already a corpse.")
			var out := result(name + " killed.")
			var tank := state.get_vehicle(unit.aboard_vehicle_id)
			r._kill(unit, out, r.NOWHERE, false, true)
			if tank != null and not VehicleDB.is_seated(tank.type_id):
				tank.occupants.erase(unit.id)
				tank.corpse_slots.append(unit.stats.display_name)
			out.deaths.append(unit.id)
			return out
		"unit_revive":
			if unit.status != MCF.Status.CORPSE: return ActionResult.fail("Only an existing corpse can be revived.")
			var error := cell_error(state, unit.coord, unit)
			if not error.is_empty(): return ActionResult.fail(error)
			unit.status = MCF.Status.ALIVE
			unit.burnt = false
			unit.captor_id = -1
			unit.wall_entry_from = Vector2i(-1, -1)
			unit.carried_this_round = false
			refill(unit)
			state.grid.place(unit, unit.coord)
			state.deaths[unit.owner] = maxi(0, int(state.deaths.get(unit.owner, 0)) - 1)
			state.roster.set_eliminated(unit.owner, false)
			state.turns.eliminated.erase(unit.owner)
			return result(name + " revived with %d AP." % unit.remaining_ap)
		"unit_remove":
			var cell := state.grid.cell(unit.coord)
			if cell != null and cell.occupant == unit: cell.occupant = null
			state.remove_unit(unit.id)
			UnitInstance.vision_epoch += 1
			return result(name + " removed.")
		"unit_teleport":
			if not unit.is_alive() or not state.grid.in_bounds(unit.coord): return ActionResult.fail("Teleport requires a living on-board unit.")
			var dest := Vector2i(args.x, args.y)
			var error := cell_error(state, dest, unit)
			if not error.is_empty(): return ActionResult.fail(error)
			var before := unit.coord
			state.grid.place(unit, dest)
			unit.action_state = null
			unit.move_credit = 0
			unit.dragging = UnitInstance.NOT_DRAGGING
			return result("%s: %s → %s." % [name, before, dest])
		"unit_owner":
			var old := unit.owner
			unit.owner = args.owner
			refill(unit)
			if not unit.is_alive(): unit.remaining_ap = 0
			if unit.is_alive():
				state.roster.set_eliminated(unit.owner, false)
				state.turns.eliminated.erase(unit.owner)
			else:
				state.deaths[old] = maxi(0, int(state.deaths.get(old, 0)) - 1)
				state.deaths[unit.owner] = int(state.deaths.get(unit.owner, 0)) + 1
			return result("%s owner: %s → %s." % [name, state.roster.name_of(old), state.roster.name_of(unit.owner)])
		"unit_ap":
			if not unit.is_alive() or not state.grid.in_bounds(unit.coord): return ActionResult.fail("AP requires a living on-board unit.")
			var old := unit.remaining_ap
			refill(unit)
			if args.value is int: unit.remaining_ap = args.value
			return result("%s AP: %d → %d." % [name, old, unit.remaining_ap])
		"unit_item":
			var old := unit.held_item_id
			unit.held_item_id = "" if args.item == "none" else args.item
			return result("%s item: %s → %s." % [name, old, unit.held_item_id])
		"unit_invulnerable":
			var old := unit.cheat_invulnerable
			unit.cheat_invulnerable = args.enabled
			return result("%s invulnerability: %s → %s." % [name, old, unit.cheat_invulnerable])
		"unit_stat", "unit_stat_reset":
			var old := unit.cheat_stats.duplicate()
			if intent.op == "unit_stat": unit.cheat_stats[args.field] = args.value
			elif args.has("field"): unit.cheat_stats.erase(args.field)
			else: unit.cheat_stats.clear()
			UnitInstance.vision_epoch += 1
			return result("%s stat overrides: %s → %s." % [name, old, unit.cheat_stats])
		"unit_civilian":
			if not unit.is_alive() or (unit.stats.id != "civilian" and not CivilianAI.is_npc(unit)):
				return ActionResult.fail("This requires a living civilian or neutral unit.")
			var activate: bool = args.active == "activate"
			if not activate and CivilianAI.is_npc(unit):
				if unit.neutral_group != 0:
					return ActionResult.fail("A mobilized neutral group cannot return to sleep.")
				if r._civ_sees_soldier(unit):
					return ActionResult.fail("This neutral can see a soldier and would wake immediately.")
			var old := unit.civilian_active
			unit.civilian_active = activate
			if activate and CivilianAI.is_npc(unit) and unit.neutral_group == 0 and not r._activation_frontier.has(unit.id):
				r._activation_frontier.append(unit.id)
			return result("%s active: %s → %s." % [name, old, unit.civilian_active])
	return ActionResult.fail("Unknown unit operation.")
