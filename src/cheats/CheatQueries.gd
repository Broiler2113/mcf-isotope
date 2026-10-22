class_name CheatQueries
extends RefCounted

static func players(state: GameState) -> String:
	var lines: Array[String] = []
	for slot: Roster.Slot in state.roster.slots:
		lines.append("#%d  %s  %s  cheats: %s | faction %s, team %d, color %s" % [slot.id + 1, slot.display_name,
			"human" if slot.kind == Roster.SlotKind.HUMAN else slot.ai_label() if slot.kind == Roster.SlotKind.AI else "closed", "allowed" if slot.cheats_allowed else "denied", Roster.faction_key(slot.color_index()), slot.team, slot.color.to_html()])
	return "\n".join(lines)

static func unit_line(unit: UnitInstance, state: GameState) -> String:
	return "%d — %s | #%d %s | (%d, %d) | %s | AP %d" % [unit.id, unit.stats.id, unit.owner + 1,
		state.roster.name_of(unit.owner), unit.coord.x, unit.coord.y, "alive" if unit.is_alive() else "held" if unit.is_held() else "corpse", unit.remaining_ap] + " | item %s | protected %s | overrides %s" % [unit.held_item_id, unit.cheat_invulnerable, unit.cheat_stats]

static func vehicle_line(veh: Vehicle, state: GameState) -> String:
	return "%d — %s | #%d %s | (%d, %d) | %s" % [veh.id, veh.type_id, veh.owner + 1,
		state.roster.name_of(veh.owner), veh.origin.x, veh.origin.y, "intact" if veh.alive() else "wreck"] + " | facing %s | components %s | crew %s | seats %s" % [veh.facing, veh.components, veh.occupants, veh.seats]

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
		"units", "vehicles":
			var entities: Array = state.all_units().duplicate() if parsed.op == "units" else state.all_vehicles().duplicate()
			entities = entities.filter(func(entity): return a.get("owner", -1) == -1 or entity.owner == a.owner)
			entities.sort_custom(func(x, y): return x.id < y.id)
			var page := int(a.get("page", 1))
			var pages := maxi(1, ceili(entities.size() / 25.0))
			if page > pages: return "Page %d does not exist; use 1–%d." % [page, pages]
			var lines: Array[String] = ["%s: %d total · page %d/%d" % [parsed.op.capitalize(), entities.size(), page, pages]]
			for entity in entities.slice((page - 1) * 25, page * 25):
				lines.append(unit_line(entity, state) if parsed.op == "units" else vehicle_line(entity, state))
			return "\n".join(lines)
		"inspect_unit":
			var unit := state.get_unit(a.unit)
			return unit_line(unit, state) + "\nItem: %s; invulnerable: %s\nStats: speed %d, armor %d, range %s, rof %d, sight %s\nOverrides: %s\nVehicle: %d; Borg: %d; captor: %d; operator: %d; station: %s" % [unit.held_item_id, unit.cheat_invulnerable, unit.speed(), unit.armor(), unit.fire_range(), unit.rate_of_fire(), unit.sight(), unit.cheat_stats, unit.aboard_vehicle_id, unit.borg_id, unit.captor_id, unit.operator_id, unit.home_station]
		"inspect_vehicle":
			var veh := state.get_vehicle(a.vehicle)
			return vehicle_line(veh, state) + "\nFacing: %s; components: %s\nCrew: %s; seats: %s; bodies: %s" % [veh.facing, veh.components, veh.occupants, veh.seats, veh.corpse_slots]
		"inspect_cell":
			var at := Vector2i(a.x, a.y)
			var cell := state.grid.cell(at)
			return "Cell %s | floor %d, look %s, space %s\nFeature: %s, owner #%d, durability %s\nUnit: %d, vehicle: %d, stacked bodies: %d\nFire: %s; gas: %s; smoke: %s; fixtures: %s" % [at, cell.floor_type, MCF.FLOOR_LOOK_NAMES[state.grid.look_at(at.x, at.y)], cell.is_space, cell.feature_id, cell.feature_owner + 1, cell.feature_durability, cell.occupant.id if cell.occupant != null else -1, cell.vehicle_id, cell.corpse_count, cell.on_fire, r.random_events.cloud_at(at) if r.random_events != null else false, r.random_events.smoke_at(at) if r.random_events != null else false, cell.lamps]
		"event_list":
			var allowed := r._events_allowed()
			var lines: Array[String] = []
			for event: Array in RandomEvents.REGISTRY:
				lines.append("%s — %s | %s" % [event[0], event[1], "available" if allowed.has(event[0]) else "unavailable: no eligible target, map or mode"] + " — " + RandomEvents.NOTES.get(event[0], ""))
			return "\n".join(lines)
		"event_status":
			return JSON.stringify(r.random_events.snapshot(), "  ") if r.random_events != null else "No events configured."
	return "Unknown query."
