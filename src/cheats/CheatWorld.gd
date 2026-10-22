class_name CheatWorld
extends RefCounted

static func _piece(r: GameActionResolver, at: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if Furniture.is_furniture(r.state.grid.cell(at).feature_id): out.assign(r.furniture_piece(at))
	else: out.append(at)
	return out

static func _removal_error(r: GameActionResolver, cells: Array[Vector2i]) -> String:
	for at: Vector2i in cells:
		var cell := r.state.grid.cell(at)
		if cell.feature_id == MCF.FEATURE_BOUNDARY: return "Map boundaries cannot be edited."
		if cell.vehicle_id != -1: return "Move the vehicle or pack its mounted objects first."
		if cell.feature_id == MCF.FEATURE_DRONE_STATION:
			for drone: UnitInstance in r.state.all_units():
				if drone.is_alive() and drone.is_drone and drone.home_station == at: return "Recover this station's active drones first."
	return ""

static func _clear(r: GameActionResolver, cells: Array[Vector2i]) -> void:
	for at: Vector2i in cells:
		r.state.grid.cell(at).clear_feature()
		r.state.grid.furniture_turn.erase(at)
	r.state.grid.map_items = r.state.grid.map_items.filter(func(item: Array): return not cells.has(SmallItems.cell_of(item)))

static func apply(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var a := intent.args
	var state := r.state
	var grid := state.grid
	var at := Vector2i(int(a.get("x", 0)), int(a.get("y", 0)))
	var cell := grid.cell(at)
	var out := CheatUnits.result(intent.op.replace("_", " ") + " applied.")
	match intent.op:
		"world_winter":
			if not MapData.supports_winter(state.env): return ActionResult.fail("Winter is available on town and field maps.")
			out.cheat_output = "Winter: %s → %s." % [state.winter, a.enabled]
			state.winter = a.enabled
			GridCell.reset_vision_log()
			return out
		"world_time":
			if not MapData.supports_time_of_day(state.env): return ActionResult.fail("This environment has no time-of-day cycle.")
			out.cheat_output = "Time: %s → %s." % [state.time_of_day, a.time]
			state.time_of_day = a.time
			return out
		"world_gas_add", "world_smoke_add", "world_gas_clear", "world_smoke_clear":
			if r.random_events == null: r.random_events = RandomEvents.new(false)
			match intent.op:
				"world_gas_add":
					r._land_gas({"x": a.x, "y": a.y, "w": a.width, "h": a.height, "rounds": a.get("rounds", 3)}, out)
				"world_smoke_add": r.random_events.add_smoke(a.x, a.y, a.width, a.height, a.get("rounds", 3))
				"world_gas_clear": r.random_events.clouds.clear()
				"world_smoke_clear": r.random_events.smoke.clear()
			r._sync_gas()
			return out
		"world_fire_clear":
			var radius := int(a.get("radius", maxi(grid.width, grid.height)))
			var rect := Rect2i(at - Vector2i.ONE * radius, Vector2i.ONE * (radius * 2 + 1)).intersection(Rect2i(0, 0, grid.width, grid.height))
			var count := 0
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					var c := grid.cell_fast(x, y)
					if c.on_fire: count += 1
					c.on_fire = false
					c.fire_owner = -1
			out.cheat_output = "Extinguished %d fire cells (Chebyshev radius)." % count
			return out
	if cell == null: return ActionResult.fail("Cell is outside the board.")
	if cell.feature_id == MCF.FEATURE_BOUNDARY: return ActionResult.fail("Map boundaries cannot be edited.")
	match intent.op:
		"world_floor":
			var old := cell.floor_type
			cell.floor_type = {"normal": MCF.FLOOR_NORMAL, "flammable": MCF.FLOOR_FLAMMABLE, "grass": MCF.FLOOR_GRASS}[a.floor]
			out.cheat_output = "Floor at %s: %d → %s." % [at, old, a.floor]
		"world_floor_look":
			var old := grid.look_at(at.x, at.y)
			grid.floor_look.resize(grid.width * grid.height)
			grid.floor_look[at.y * grid.width + at.x] = a.look
			GridCell.log_look_change(at.x, at.y)
			out.cheat_output = "Floor appearance at %s: %s → %s." % [at, MCF.FLOOR_LOOK_NAMES[old], MCF.FLOOR_LOOK_NAMES[a.look]]
		"world_space":
			if a.enabled and (cell.occupant != null or cell.vehicle_id != -1 or not cell.feature_id.is_empty() or cell.corpse_count > 0):
				return ActionResult.fail("Clear occupants, vehicles, bodies and structures before creating space.")
			out.cheat_output = "Space at %s: %s → %s." % [at, cell.is_space, a.enabled]
			cell.is_space = a.enabled
			if a.enabled: cell.on_fire = false; cell.fire_owner = -1
			r._sync_gas()
		"world_fire":
			if a.enabled:
				if cell.is_space or r._fire_blocked(cell): return ActionResult.fail("Fire cannot be placed on this terrain.")
				r._ignite(cell, intent.issuer, out)
			else: cell.on_fire = false; cell.fire_owner = -1
		"world_feature", "world_clear_cell", "world_furniture":
			var fid: String = a.get("feature", a.get("furniture", "none"))
			if intent.op == "world_furniture" and Furniture.is_wall_light(fid):
				if not cell.is_wall() or MCF.is_glass(cell.feature_id) or cell.feature_id == MCF.FEATURE_AIRLOCK:
					return ActionResult.fail("A wall fixture requires a solid supporting wall.")
				var side := int(a.get("rotation", 0))
				var lamps := cell.lamps.duplicate(true)
				for lamp: Array in lamps:
					if int(lamp[2]) == side: return ActionResult.fail("That wall side already has a fixture.")
				lamps.append([fid, Furniture.durability_of(fid), side, 0])
				cell.lamps = lamps
				return out
			var removed := _piece(r, at)
			var error := _removal_error(r, removed)
			if not error.is_empty(): return ActionResult.fail(error)
			var placed: Array[Vector2i] = []
			var rotation := int(a.get("rotation", 0))
			if fid != "none":
				var size := Vector2i.ONE
				if intent.op == "world_furniture":
					var dimensions: Array = Furniture.sizes_of(fid)[0]
					size = Vector2i(dimensions[0], dimensions[1])
					if rotation % 2 == 1: size = Vector2i(size.y, size.x)
				for y in size.y:
					for x in size.x:
						var q := at + Vector2i(x, y)
						var c := grid.cell(q)
						if c == null or c.is_space or c.occupant != null or c.vehicle_id != -1 or c.corpse_count > 0 \
								or (not c.feature_id.is_empty() and not removed.has(q)):
							return ActionResult.fail("The complete object needs free, non-space cells.")
						placed.append(q)
			var operator: UnitInstance = null
			var owner := int(a.get("owner", intent.issuer))
			if fid == MCF.FEATURE_DRONE_STATION:
				for unit: UnitInstance in state.all_units():
					if unit.is_alive() and unit.owner == owner and unit.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR \
							and Combat.distance(unit.coord, at) <= 1: operator = unit; break
				if operator == null: return ActionResult.fail("A living operator of the chosen owner must be beside the station.")
			_clear(r, removed)
			out.cheat_cells.assign(removed)
			for q: Vector2i in placed:
				if not out.cheat_cells.has(q): out.cheat_cells.append(q)
				if fid == MCF.FEATURE_DIRT_PILE: grid.cell(q).add_dirt(owner)
				else: grid.cell(q).set_feature(fid, owner)
				if fid == MCF.FEATURE_CORPSE_WALL: grid.cell(q).corpse_count = 0 # the wall itself represents five bodies
				if Furniture.is_furniture(fid): grid.furniture_turn[q] = [fid, rotation]
			if operator != null: cell.station_operator_id = operator.id
			if intent.op == "world_clear_cell": cell.on_fire = false; cell.fire_owner = -1; cell.lamps = []
			r.update_airlocks()
			r._sync_gas()
			out.cheat_output = "Cell %s: removed %d cell(s), placed %s on %d cell(s)." % [at, removed.size(), fid, placed.size()]
		_:
			return ActionResult.fail("Unknown world operation.")
	return out
