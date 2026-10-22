class_name CheatQueries
extends RefCounted

const UNIT_HEADER := "ID | Type | Player | Cell | State | AP"
const VEHICLE_HEADER := "ID | Type | Player | Cell | State | Durability"

static func players(state: GameState) -> String:
	var lines: Array[String] = ["Player | Name | Control | Cheats | Faction | Team"]
	for slot: Roster.Slot in state.roster.slots:
		lines.append("#%d | %s | %s | %s | %s | %d" % [slot.id + 1, slot.display_name,
			("human" if slot.kind == Roster.SlotKind.HUMAN else slot.ai_label() if slot.kind == Roster.SlotKind.AI else "closed") + (" (paused)" if state.cheat_ai_paused.has(slot.id) else ""),
			"allowed" if slot.cheats_allowed else "denied", Roster.faction_key(slot.color_index()), slot.team])
	return "\n".join(lines)

static func player_label(state: GameState, owner: int) -> String:
	return ("#%d " % (owner + 1) if MCF.is_player(owner) else "") + state.roster.name_of(owner)

static func unit_line(unit: UnitInstance, state: GameState) -> String:
	var at := CorpseIdentity.cell_of(state, unit)
	return "%s | %s | %s | %s | %s | %d" % [CorpseIdentity.id_label(unit), unit.stats.id,
		player_label(state, unit.owner), "(%d,%d)" % [at.x, at.y] if at.x >= 0 else "off board",
		"alive" if unit.is_alive() else "held" if unit.is_held() else "corpse", unit.remaining_ap]

static func vehicle_line(veh: Vehicle, state: GameState) -> String:
	return "V%d | %s | %s | (%d,%d) | %s | %d/%d" % [veh.id, veh.type_id,
		player_label(state, veh.owner), veh.origin.x, veh.origin.y, "intact" if veh.alive() else "wreck", veh.durability, veh.component_max(MCF.COMP_HULL)]

static func run(r: GameActionResolver, parsed: Dictionary, caller: int) -> String:
	var state := r.state
	var a: Dictionary = parsed.args
	match parsed.op:
		"help": return CheatCommands.help_text(a.get("topic", ""))
		"status": return "Master: %s. Your slot: #%d. Gameplay permission: %s." % ["enabled" if state.cheats_enabled else "disabled", caller + 1, "allowed" if CheatAccess.permitted(state, caller) else "denied"]
		"players", "permissions": return players(state)
	var denial := CheatAccess.denial(state, caller)
	if not denial.is_empty(): return denial
	match parsed.op:
		"units_status", "vehicles_status": return counts(state, parsed.op == "units_status", a.get("owner", -1))
		"units", "vehicles":
			var entities: Array = state.all_units().duplicate() if parsed.op == "units" else state.all_vehicles().duplicate()
			entities = entities.filter(func(entity): return a.get("owner", -1) == -1 or entity.owner == a.owner)
			entities.sort_custom(func(x, y): return x.id < y.id)
			var page := int(a.get("page", 1))
			var pages := maxi(1, ceili(entities.size() / 25.0))
			if page > pages: return "Page %d does not exist; use 1–%d." % [page, pages]
			var lines: Array[String] = ["%s: %d total · page %d/%d" % [parsed.op.capitalize(), entities.size(), page, pages]]
			lines.append(UNIT_HEADER if parsed.op == "units" else VEHICLE_HEADER)
			for entity in entities.slice((page - 1) * 25, page * 25):
				lines.append(unit_line(entity, state) if parsed.op == "units" else vehicle_line(entity, state))
			return "\n".join(lines)
		"inspect_unit":
			var unit := state.get_unit(a.unit)
			return UNIT_HEADER + "\n" + unit_line(unit, state) + "\nItem: %s; invulnerable: %s\nStats: speed %d, armor %d, range %s, rof %d, sight %s\nOverrides: %s\nVehicle: %d; Borg: %d; captor: %d; operator: %d; station: %s" % [unit.held_item_id, unit.cheat_invulnerable, unit.speed(), unit.armor(), unit.fire_range(), unit.rate_of_fire(), unit.sight(), unit.cheat_stats, unit.aboard_vehicle_id, unit.borg_id, unit.captor_id, unit.operator_id, unit.home_station]
		"inspect_vehicle":
			var veh := state.get_vehicle(a.vehicle)
			return VEHICLE_HEADER + "\n" + vehicle_line(veh, state) + "\n" + vehicle_stats(veh) + "\nFacing: %s; components: %s\nCrew: %s; seats: %s; bodies: %s" % [veh.facing, veh.components, veh.occupants, veh.seats, veh.corpse_slots]
		"inspect_cell":
			var at := Vector2i(a.x, a.y)
			var cell := state.grid.cell(at)
			return "Cell %s\nFloor: %d, look %s, space %s\nFeature: %s, owner #%d, durability %s\nUnit: %d, vehicle: %d, stacked bodies: %d\nFire: %s; gas: %s; smoke: %s; fixtures: %s" % [at, cell.floor_type, MCF.FLOOR_LOOK_NAMES[state.grid.look_at(at.x, at.y)], cell.is_space, cell.feature_id, cell.feature_owner + 1, cell.feature_durability, cell.occupant.id if cell.occupant != null else -1, cell.vehicle_id, cell.corpse_count, cell.on_fire, r.random_events.cloud_at(at) if r.random_events != null else false, r.random_events.smoke_at(at) if r.random_events != null else false, cell.lamps]
		"event_list": return CheatEventModel.list_text(r)
		"event_types":
			var allowed := r._events_allowed()
			var lines: Array[String] = ["ID | Event | Availability"]
			for event: Array in RandomEvents.REGISTRY:
				lines.append("%s | %s | %s" % [event[0], event[1], "available" if allowed.has(event[0]) else "unavailable: no eligible target, map or mode"])
			return "\n".join(lines)
		"wave_status":
			if not r.mode.is_holdout(): return "Wave sizing requires Holdout mode."
			var p: Dictionary = r.mode.pending_wave if r.mode.pending_wave.has("target") else r.wave_size_details(r.mode.wave + 1)
			return "Next wave: " + r.wave_size_text(p) + "\nLast landing: " + str(r.mode.wave_details.get(str(r.mode.wave), "none"))
		"event_status":
			return JSON.stringify(r.random_events.snapshot(), "  ") if r.random_events != null else "No events configured."
	return "Unknown query."

static func counts(state: GameState, units: bool, owner: int) -> String:
	var entities: Array = state.all_units() if units else state.all_vehicles()
	var out: Array[String] = []
	var scopes: Array = [owner, -1] if owner >= 0 else [-1]
	for side: int in scopes:
		out.append((state.roster.name_of(side) if side >= 0 else "Entire board") + " — " + ("units" if units else "vehicles"))
		out.append("Type | Alive | Dead | Total")
		var tally := {}
		var alive := 0
		var dead := 0
		for entity in entities:
			if side >= 0 and entity.owner != side: continue
			var type: String = entity.stats.id if units else entity.type_id
			if not tally.has(type): tally[type] = [0, 0]
			var live: bool = entity.is_on_field() if units else entity.alive()
			tally[type][0 if live else 1] += 1
			if live: alive += 1
			else: dead += 1
		var types := tally.keys()
		types.sort()
		for type: String in types:
			out.append("%s | %d | %d | %d" % [type, tally[type][0], tally[type][1], tally[type][0] + tally[type][1]])
		out.append("Total | %d | %d | %d\n" % [alive, dead, alive + dead])
	return "\n".join(out)

static func inspect_at(r: GameActionResolver, at: Vector2i, caller: int, category := "") -> String:
	var out: Array[String] = []
	for unit: UnitInstance in r.state.all_units():
		if category not in ["vehicle", "cell"] and CorpseIdentity.cell_of(r.state, unit) == at:
			out.append(run(r, {"op": "inspect_unit", "args": {"unit": unit.id}}, caller))
	for vehicle: Vehicle in r.state.all_vehicles():
		if category not in ["unit", "cell"] and vehicle.footprint().has(at):
			out.append(run(r, {"op": "inspect_vehicle", "args": {"vehicle": vehicle.id}}, caller))
	if out.is_empty() and category in ["unit", "vehicle"]: return "No %s at (%d,%d)." % [category, at.x, at.y]
	if out.is_empty(): out.append(run(r, {"op": "inspect_cell", "args": {"x": at.x, "y": at.y}}, caller))
	return "\n\n".join(out)

static func vehicle_stats(veh: Vehicle) -> String:
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var lines: Array[String] = ["Stats: speed %s · cost %s · crew capacity %s · footprint %s" % [spec.get("speed", 0), VehicleDB.buy_cost(veh.type_id), spec.get("crew_capacity", 1), VehicleDB.size_of(veh.type_id)]]
	for component: String in veh.components:
		lines.append("%s: %d / %d durability" % [MCF.COMPONENT_NAMES.get(component, component), veh.component(component), veh.component_max(component)])
	for weapon: String in spec.get("weapons", {}):
		lines.append("%s: %s" % [weapon, spec.weapons[weapon]])
	return "\n".join(lines)
