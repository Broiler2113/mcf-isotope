class_name CheatQueries
extends RefCounted

const UNIT_HEADER := "ID | Type | Player | Cell | State | AP"
const VEHICLE_HEADER := "ID | Type | Player | Cell | State | Durability"
const FLOOR_WORDS := {MCF.FLOOR_NORMAL: "normal", MCF.FLOOR_FLAMMABLE: "flammable", MCF.FLOOR_GRASS: "grass"}

static func players(state: GameState) -> String:
	var lines: Array[String] = ["Player | Name | Control | Cheats | Faction | Team"]
	for slot: Roster.Slot in state.roster.slots:
		lines.append("%s | %s | %s | %s | %s | %d" % [CheatCommands.player_letter(slot.id), slot.display_name,
			("human" if slot.kind == Roster.SlotKind.HUMAN else slot.ai_label() if slot.kind == Roster.SlotKind.AI else "closed") + (" (paused)" if state.cheat_ai_paused.has(slot.id) else ""),
			"allowed" if slot.cheats_allowed else "denied", Roster.faction_key(slot.color_index()), slot.team])
	return "\n".join(lines)

## "A" for Player A, "B (Red Team)" for a renamed slot, the side's name otherwise.
static func player_label(state: GameState, owner: int) -> String:
	var name := state.roster.name_of(owner)
	if not MCF.is_player(owner): return name
	var letter := CheatCommands.player_letter(owner)
	return letter if name == MCF.owner_name(owner) else "%s (%s)" % [letter, name]

static func unit_line(unit: UnitInstance, state: GameState) -> String:
	var at := CorpseIdentity.cell_of(state, unit)
	return "%s | %s | %s | %s | %s | %d" % [CorpseIdentity.id_label(unit), unit.stats.id,
		player_label(state, unit.owner), "(%d,%d)" % [at.x, at.y] if at.x >= 0 else "off board",
		"alive" if unit.is_alive() else "held" if unit.is_held() else "corpse", unit.remaining_ap]

static func vehicle_line(veh: Vehicle, state: GameState) -> String:
	return "%s | %s | %s | (%d,%d) | %s | %d/%d" % [CheatCommands.vehicle_label(veh.id), veh.type_id,
		player_label(state, veh.owner), veh.origin.x, veh.origin.y, "intact" if veh.alive() else "wreck", veh.durability, veh.component_max(MCF.COMP_HULL)]

static func _yes(value: bool) -> String:
	return "yes" if value else "no"

static func feature_name(fid: String) -> String:
	if fid.is_empty(): return "none"
	return str(MCF.FEATURE_NAMES.get(fid, Furniture.name_of(fid)))

static func run(r: GameActionResolver, parsed: Dictionary, caller: int) -> String:
	var state := r.state
	var a: Dictionary = parsed.args
	match parsed.op:
		"help": return CheatCommands.help_text(a.get("topic", ""))
		"status": return "Cheats: %s. Your player: %s. Gameplay permission: %s." % ["enabled" if state.cheats_enabled else "disabled for this match", player_label(state, caller), "allowed" if CheatAccess.permitted(state, caller) else "denied"]
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
			var links: Array[String] = []
			if unit.aboard_vehicle_id != -1: links.append("aboard " + CheatCommands.vehicle_label(unit.aboard_vehicle_id))
			if unit.borg_id != -1: links.append("operating Borg " + CheatCommands.vehicle_label(unit.borg_id))
			if unit.captor_id != -1: links.append("held by U%d" % unit.captor_id)
			if unit.operator_id != -1: links.append("drone of U%d" % unit.operator_id)
			if unit.home_station.x >= 0: links.append("station at (%d,%d)" % [unit.home_station.x, unit.home_station.y])
			var overrides: Array[String] = []
			for key: String in unit.cheat_stats: overrides.append("%s %s" % [key, unit.cheat_stats[key]])
			return UNIT_HEADER + "\n" + unit_line(unit, state) + "\nItem: %s · invulnerable: %s\nStats: speed %d · armor %d (lower is tougher) · range %s · rof %d · sight %s\nOverrides: %s\nLinks: %s" % [
				MCF.ITEM_NAMES.get(unit.held_item_id, "none"), _yes(unit.cheat_invulnerable),
				unit.speed(), unit.armor(), unit.fire_range(), unit.rate_of_fire(), unit.sight(),
				", ".join(overrides) if not overrides.is_empty() else "none", ", ".join(links) if not links.is_empty() else "none"]
		"inspect_vehicle":
			var veh := state.get_vehicle(a.vehicle)
			var crew: Array[String] = []
			for id: int in veh.occupants: crew.append("U%d" % id)
			for id: int in veh.seats:
				if id >= 0 and not crew.has("U%d" % id): crew.append("U%d" % id)
			return VEHICLE_HEADER + "\n" + vehicle_line(veh, state) + "\n" + vehicle_stats(veh) + "\nFacing: %s · crew: %s · bodies: %d" % [
				{Vector2i.UP: "north", Vector2i.RIGHT: "east", Vector2i.DOWN: "south", Vector2i.LEFT: "west"}.get(veh.facing, "none"),
				", ".join(crew) if not crew.is_empty() else "none", veh.corpse_slots.size()]
		"inspect_cell":
			var at := Vector2i(a.x, a.y)
			var cell := state.grid.cell(at)
			var fixtures: Array[String] = []
			for lamp: Array in cell.lamps: fixtures.append(Furniture.name_of(str(lamp[0])))
			return "Cell (%d,%d)\nFloor: %s · look %s · space %s\nFeature: %s · owner %s · durability %d\nUnit: %s · vehicle: %s · stacked bodies: %d\nFire %s · gas %s · smoke %s · wall fixtures: %s" % [
				at.x, at.y, FLOOR_WORDS.get(cell.floor_type, str(cell.floor_type)), MCF.FLOOR_LOOK_NAMES[state.grid.look_at(at.x, at.y)], _yes(cell.is_space),
				feature_name(cell.feature_id), player_label(state, cell.feature_owner) if cell.feature_owner >= 0 else "none", cell.feature_durability,
				CorpseIdentity.id_label(cell.occupant) if cell.occupant != null else "none",
				CheatCommands.vehicle_label(cell.vehicle_id) if cell.vehicle_id != -1 else "none", cell.corpse_count,
				_yes(cell.on_fire), _yes(r.random_events != null and r.random_events.cloud_at(at)), _yes(r.random_events != null and r.random_events.smoke_at(at)),
				", ".join(fixtures) if not fixtures.is_empty() else "none"]
		"event_list": return CheatEventModel.list_text(r)
		"event_types":
			var allowed := r._events_allowed()
			var lines: Array[String] = ["ID | Event | Target | Options | Availability"]
			for event: Array in RandomEvents.REGISTRY:
				var target := "area (x1,y1) (x2,y2)" if event[0] in CheatEventModel.AREA_EVENTS else "cell (x,y)" if event[0] in CheatEventModel.POINT_EVENTS else "whole map"
				var options: Array = CheatEventModel.schema(event[0], r, {}).keys()
				lines.append("%s | %s | %s | %s | %s" % [event[0], event[1], target, ", ".join(options) if not options.is_empty() else "none",
					"available" if allowed.has(event[0]) else "unavailable here"])
			lines.append("Type help event for what each option means.")
			return "\n".join(lines)
		"wave_status":
			if not r.mode.is_holdout(): return "Wave sizing requires Holdout mode."
			var p: Dictionary = r.mode.pending_wave if r.mode.pending_wave.has("target") else r.wave_size_details(r.mode.wave + 1)
			return "Next wave: " + r.wave_size_text(p) + "\nLast landing: " + str(r.mode.wave_details.get(str(r.mode.wave), "none"))
		"event_status":
			if r.random_events == null: return "No events configured."
			var events := r.random_events
			var enabled: Array[String] = []
			for event: Array in RandomEvents.REGISTRY:
				if float(events.weights.get(event[0], 0)) > 0.0: enabled.append(event[0])
			return "Automatic events: %s · every %d rounds · %s\nIn the automatic pool: %s\nGas clouds: %d · smoke clouds: %d · dust storm rounds left: %d\n%s" % [
				"enabled" if events.enabled else "disabled", events.interval, "guaranteed" if events.mandatory else "normal random chance",
				", ".join(enabled) if not enabled.is_empty() else "none", events.clouds.size(), events.smoke.size(), events.dust_left,
				CheatEventModel.list_text(r)]
	return "Unknown query."

static func counts(state: GameState, units: bool, owner: int) -> String:
	var entities: Array = state.all_units() if units else state.all_vehicles()
	var out: Array[String] = []
	var scopes: Array = [owner, -1] if owner >= 0 else [-1]
	for side: int in scopes:
		out.append((player_label(state, side) if side >= 0 else "Entire board") + " - " + ("units" if units else "vehicles"))
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
	var lines: Array[String] = ["Stats: speed %s · cost %s · crew capacity %s · footprint %dx%d" % [spec.get("speed", 0), VehicleDB.buy_cost(veh.type_id), spec.get("crew_capacity", 1), VehicleDB.size_of(veh.type_id).x, VehicleDB.size_of(veh.type_id).y]]
	for component: String in veh.components:
		lines.append("%s: %d / %d durability" % [MCF.COMPONENT_NAMES.get(component, component), veh.component(component), veh.component_max(component)])
	for weapon: String in spec.get("weapons", {}):
		lines.append("%s: %s" % [weapon, spec.weapons[weapon]])
	return "\n".join(lines)
