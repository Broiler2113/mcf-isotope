class_name CheatCommands
extends RefCounted

## Explicit grammar and typed payload validation shared by UI and authority.
const CATALOG: Array = [
	{"op": "help", "pattern": "help {topic:text?}", "access": "safe", "help": "Show command categories, syntax and bounds."},
	{"op": "status", "pattern": "cheats status", "access": "safe", "help": "Show master setting and your current rights."},
	{"op": "players", "pattern": "players", "access": "safe", "help": "List roster metadata and permissions."},
	{"op": "units", "pattern": "units {owner:players?} page {page:page?}", "access": "inspect", "help": "List units by permanent U-ID, 25 per page; player and page are optional."},
	{"op": "vehicles", "pattern": "vehicles {owner:players?} page {page:page?}", "access": "inspect", "help": "List vehicles by permanent V-ID, 25 per page; player and page are optional."},
	{"op": "units_status", "pattern": "units {owner:players} status", "access": "inspect", "help": "Count each soldier/drone type alive and dead for a player, then the entire board."},
	{"op": "vehicles_status", "pattern": "vehicles {owner:players} status", "access": "inspect", "help": "Count each vehicle type intact and wrecked for a player, then the entire board."},
	{"op": "inspect_tool", "pattern": "inspect", "access": "tool", "help": "Click battlefield cells to inspect units, vehicles and their stats; Esc stops the tool."},
	{"op": "spawn_unit_tool", "pattern": "spawn unit {type:unit_type} {owner:player}", "access": "tool", "help": "Click cells to place this unit repeatedly; Esc stops placement."},
	{"op": "spawn_vehicle_tool", "pattern": "spawn vehicle {type:vehicle_type} {owner:player}", "access": "tool", "help": "Click cells to place this vehicle repeatedly; Esc stops placement."},
	{"op": "ids_on", "pattern": "ids on {category:entities?}", "access": "inspect", "help": "Show local battlefield IDs; default all."},
	{"op": "ids_off", "pattern": "ids off", "access": "safe", "help": "Hide local battlefield IDs."},
	{"op": "inspect_unit", "pattern": "inspect unit {unit:unit}", "access": "inspect", "help": "Inspect a unit, including its overrides."},
	{"op": "inspect_vehicle", "pattern": "inspect vehicle {vehicle:vehicle}", "access": "inspect", "help": "Inspect a vehicle and crew."},
	{"op": "inspect_cell", "pattern": "inspect cell {x:x} {y:y}", "access": "inspect", "help": "Inspect terrain, occupants and environmental effects."},
	{"op": "clear", "pattern": "clear", "access": "safe", "help": "Clear console output."},
	{"op": "spawn_unit", "pattern": "spawn unit {type:unit_type} {owner:player} {x:x} {y:y} {count:count?}", "access": "play", "help": "Spawn 1–100 units in deterministic expanding rings; reports partial placement."},
	{"op": "spawn_vehicle", "pattern": "spawn vehicle {type:vehicle_type} {owner:player} {x:x} {y:y} {facing:facing?}", "access": "play", "help": "Spawn an intact vehicle; Borg requires an eligible operator at the cell."},
	{"op": "unit_clone", "pattern": "unit clone {unit:unit} {x:x} {y:y} {count:count?}", "access": "play", "help": "Clone base type, owner and held item into fresh units (1–100)."},
	{"op": "unit_kill", "pattern": "unit kill {unit:unit}", "access": "play", "help": "Explicit death, bypassing invulnerability."},
	{"op": "unit_revive", "pattern": "unit revive {unit:unit}", "access": "play", "help": "Revive an existing corpse at a legal free cell."},
	{"op": "unit_remove", "pattern": "unit remove {unit:unit}", "access": "play", "help": "Remove an entity; unsafe linked entities are refused."},
	{"op": "unit_teleport", "pattern": "unit teleport {unit:unit} {x:x} {y:y}", "access": "play", "help": "Move an on-board unit without spending AP; spatial invariants still apply."},
	{"op": "unit_owner", "pattern": "unit owner {unit:unit} {owner:player}", "access": "play", "help": "Transfer a unit to a playable side; unsafe links are refused."},
	{"op": "unit_ap", "pattern": "unit ap {unit:unit} {value:ap}", "access": "play", "help": "Set AP to 0–99 or refill; clears partial actions."},
	{"op": "unit_item", "pattern": "unit item {unit:unit} {item:item}", "access": "play", "help": "Set a registered held item, or none."},
	{"op": "unit_invulnerable", "pattern": "unit invulnerable {unit:unit} {enabled:bool}", "access": "play", "help": "Prevent ordinary deaths until switched off."},
	{"op": "unit_stat_reset", "pattern": "unit stat reset {unit:unit} {field:stat?}", "access": "play", "help": "Remove one or all per-instance stat overrides."},
	{"op": "unit_stat", "pattern": "unit stat {unit:unit} {field:stat} {value:stat_value}", "access": "play", "help": "Override speed 0–999, armor 1–12 (lower is tougher), range/sight 0–1024 or rof 0–100."},
	{"op": "unit_civilian", "pattern": "unit civilian {unit:unit} {active:civilian}", "access": "play", "help": "Activate or sleep an eligible civilian."},
	{"op": "vehicle_clone", "pattern": "vehicle clone {vehicle:vehicle} {x:x} {y:y}", "access": "play", "help": "Spawn a fresh, intact copy without passengers."},
	{"op": "vehicle_move", "pattern": "vehicle move {vehicle:vehicle} {x:x} {y:y} {facing:facing?}", "access": "play", "help": "Move a vehicle footprint to legal terrain without AP."},
	{"op": "vehicle_owner", "pattern": "vehicle owner {vehicle:vehicle} {owner:player}", "access": "play", "help": "Transfer an empty vehicle to a playable side."},
	{"op": "vehicle_repair", "pattern": "vehicle repair {vehicle:vehicle}", "access": "play", "help": "Restore all durability and components of a living vehicle to maximum."},
	{"op": "vehicle_durability", "pattern": "vehicle durability {vehicle:vehicle} {value:component_value?}", "access": "play", "help": "Restore hull durability (omit value or use restore), or set 0..maximum. Wrecks cannot be revived."},
	{"op": "vehicle_component", "pattern": "vehicle component {vehicle:vehicle} {component:component} {value:component_value}", "access": "play", "help": "Set an existing component to restore or 0..its maximum."},
	{"op": "vehicle_destroy", "pattern": "vehicle destroy {vehicle:vehicle}", "access": "play", "help": "Use normal destruction and crew cleanup with shared dice."},
	{"op": "vehicle_remove", "pattern": "vehicle remove {vehicle:vehicle}", "access": "play", "help": "Remove an empty vehicle without explosion."},
	{"op": "world_feature", "pattern": "world feature set {x:x} {y:y} {feature:feature} {owner:player?}", "access": "play", "help": "Set a registered static feature or none, preserving boundaries and occupancy."},
	{"op": "world_furniture", "pattern": "world furniture set {x:x} {y:y} {furniture:furniture} {rotation:rotation?}", "access": "play", "help": "Place a complete furniture piece, or remove the whole piece with none. Rotation is 0–3 quarter-turns."},
	{"op": "world_floor", "pattern": "world floor {x:x} {y:y} {floor:floor}", "access": "play", "help": "Set normal, flammable or grass gameplay floor."},
	{"op": "world_floor_look", "pattern": "world floor-look {x:x} {y:y} {look:look}", "access": "play", "help": "Set decorative floor by its numeric ID or quoted registry name; preserves flammability."},
	{"op": "world_space", "pattern": "world space {x:x} {y:y} {enabled:bool}", "access": "play", "help": "Toggle space on a safe unoccupied cell."},
	{"op": "world_fire", "pattern": "world fire set {x:x} {y:y} {enabled:bool}", "access": "play", "help": "Ignite or extinguish a cell using ordinary fire rules."},
	{"op": "world_fire_clear", "pattern": "world fire clear {x:x?} {y:y?} {radius:radius?}", "access": "play", "help": "Clear all fire, or a Chebyshev (square) radius. Supply all three area arguments."},
	{"op": "world_gas_add", "pattern": "world gas add {x:x} {y:y} {width:width} {height:height} {rounds:rounds?}", "access": "play", "help": "Create an ordinary gas cloud for 1–100 rounds (default 3)."},
	{"op": "world_gas_clear", "pattern": "world gas clear", "access": "play", "help": "Clear active gas clouds."},
	{"op": "world_smoke_add", "pattern": "world smoke add {x:x} {y:y} {width:width} {height:height} {rounds:rounds?}", "access": "play", "help": "Create a harmless smoke cloud for 1–100 rounds (default 3)."},
	{"op": "world_smoke_clear", "pattern": "world smoke clear", "access": "play", "help": "Clear active smoke clouds."},
	{"op": "world_winter", "pattern": "world winter {enabled:bool}", "access": "play", "help": "Toggle existing winter presentation."},
	{"op": "world_time", "pattern": "world time {time:time}", "access": "play", "help": "Set morning, day, evening or night."},
	{"op": "world_clear_cell", "pattern": "world clear-cell {x:x} {y:y}", "access": "play", "help": "Remove terrain objects and fire safely; preserves units, vehicles and boundaries."},
	{"op": "event_list", "pattern": "event list", "access": "inspect", "help": "List active effects and pending warnings with stable references for editing or removal."},
	{"op": "event_types", "pattern": "event types", "access": "inspect", "help": "List registered event types and their availability on this map."},
	{"op": "event_spawn_tool", "pattern": "event spawn {event:event?}", "access": "tool", "help": "Open the event editor, then click to place an event with its supported properties."},
	{"op": "event_edit_tool", "pattern": "event edit {target:event_ref?}", "access": "tool", "help": "Open an adaptive editor for an active effect or pending warning from event list."},
	{"op": "event_remove_tool", "pattern": "event remove", "access": "tool", "help": "Click an event area to select and cancel it; Esc stops the tool."},
	{"op": "event_remove", "pattern": "event remove {target:event_ref}", "access": "play", "help": "Cancel a warning or active effect by its stable reference. Past damage is not reversed."},
	{"op": "event_trigger", "pattern": "event trigger {event:event}", "access": "play", "help": "Immediately trigger an eligible event using its normal parameters and shared dice."},
	{"op": "event_spawn", "pattern": "event place {event:event} {x:x} {y:y} {properties:event_properties?}", "access": "play", "help": "Immediately place an event at a cell. The event spawn editor supplies supported properties."},
	{"op": "event_set", "pattern": "event set {target:event_ref} {property:event_property} {value:event_value}", "access": "play", "help": "Edit one supported integer property of an existing warning or effect."},
	{"op": "event_update", "pattern": "event update {target:event_ref} {properties:event_properties}", "access": "play", "help": "Apply the editor's complete property set atomically; properties use a quoted JSON object."},
	{"op": "event_automatic", "pattern": "event automatic {enabled:bool}", "access": "play", "help": "Enable or disable automatic event scheduling; existing effects remain."},
	{"op": "event_interval", "pattern": "event interval {rounds:event_interval}", "access": "play", "help": "Set rounds between automatic event checks (1–20)."},
	{"op": "event_guaranteed", "pattern": "event guaranteed {enabled:bool}", "access": "play", "help": "Guarantee an event at each due check, or use the normal random chance."},
	{"op": "event_enabled", "pattern": "event enabled {event:event} {enabled:bool}", "access": "play", "help": "Include or exclude this type from the automatic event pool; selected types have equal probability."},
	{"op": "event_status", "pattern": "event status", "access": "inspect", "help": "Inspect pending events, clouds and automatic event configuration."},
	{"op": "event_queue", "pattern": "event queue {event:event} {x:x?} {y:y?}", "access": "play", "help": "Queue an existing event with normal timing and shared dice; optional center for supported zones."},
	{"op": "event_cancel", "pattern": "event cancel {index:event_index}", "access": "play", "help": "Cancel a zero-based pending event index or all warnings."},
	{"op": "vision_reveal", "pattern": "vision reveal {owner:players}", "access": "play", "help": "Give selected side(s) omniscient view and targeting knowledge."},
	{"op": "vision_reset", "pattern": "vision reset {owner:players}", "access": "play", "help": "Remove omniscience while preserving explored map memory."},
	{"op": "vision_mines", "pattern": "vision mines {owner:players} {enabled:bool}", "access": "play", "help": "Reveal all mines for selected side(s), or remove the override."},
	{"op": "turn_end", "pattern": "turn end", "access": "play", "help": "End the currently active turn using normal round and event rules."},
	{"op": "turn_refill", "pattern": "turn refill {owner:players}", "access": "play", "help": "Refill eligible living units and clear partial action counters."},
	{"op": "ai_pause", "pattern": "ai pause {owner:player}", "access": "host_play", "help": "Pause an AI player after its current action; host only."},
	{"op": "ai_resume", "pattern": "ai resume {owner:player}", "access": "host_play", "help": "Resume a paused AI player; host only."},
	{"op": "ai_step", "pattern": "ai step {owner:player}", "access": "host_play", "help": "Pause the active AI and permit exactly one decision/action; host only."},
	{"op": "ai_speed", "pattern": "ai speed {speed:ai_speed}", "access": "host_play", "help": "Set shared AI pace to 0.5, 1, 2, 4, 8, 16 or 64; host only."},
	{"op": "ai_personality", "pattern": "ai personality {owner:player} {personality:personality}", "access": "host_play", "help": "Set an AI slot to tactician, aggressor, fortifier or learned at its next safe decision boundary."},
	{"op": "match_score", "pattern": "match score {owner:player} {points:points}", "access": "play", "help": "Set a Capture & Hold team score (0–1000000)."},
	{"op": "wave_status", "pattern": "wave status", "access": "inspect", "help": "Show surviving defenders, the next wave multiplier and target, and the last landing count."},
	{"op": "match_waves", "pattern": "match waves {waves:waves}", "access": "play", "help": "Set Holdout total waves (0–999; 0 is endless)."},
	{"op": "kick", "pattern": "kick {owner:player}", "access": "admin", "help": "Disconnect a connected human player; host only. The normal AI takeover/rejoin rules apply."},
	{"op": "ban", "pattern": "ban {owner:player}", "access": "admin", "help": "Disconnect a human player and block their reconnect identity for this hosted session; host only."},
	{"op": "permissions", "pattern": "cheats permissions", "access": "admin", "help": "List slot permissions; host administration only."},
	{"op": "grant", "pattern": "cheats grant {owner:player}", "access": "admin", "help": "Grant a connected human slot gameplay permission; host only."},
	{"op": "revoke", "pattern": "cheats revoke {owner:player}", "access": "admin", "help": "Revoke slot permission immediately; existing effects remain."},
]

static var _units: Array[String] = []

static func unit_types() -> Array[String]:
	if _units.is_empty():
		for file in DirAccess.get_files_at("res://src/data/units"):
			if file.ends_with(".tres"):
				var resource := load("res://src/data/units/" + file)
				if resource is UnitStats: _units.append(resource.id)
		_units.sort()
	return _units.duplicate()

static func definition(op: String) -> Dictionary:
	for entry: Dictionary in CATALOG:
		if entry.op == op: return entry
	return {}

static func syntax(entry: Dictionary) -> String:
	if entry.op in ["units", "vehicles"]: return entry.op + " [player|all] [page <number>]"
	var out: Array[String] = []
	for word in str(entry.pattern).split(" "):
		if word.begins_with("{"):
			var field := _field(word)
			out.append(("[%s]" if field.optional else "<%s>") % field.name)
		else: out.append(word)
	return " ".join(out)

static func help_text(topic := "") -> String:
	var lines: Array[String] = []
	var category := topic.to_lower().strip_edges()
	category = {"units": "unit", "vehicles": "vehicle", "events": "event", "admin": "cheats"}.get(category, category)
	for entry: Dictionary in CATALOG:
		if category.is_empty() or str(entry.pattern).begins_with(category + " ") or str(entry.pattern) == category \
				or (category == "unit" and entry.op == "spawn_unit") or (category == "vehicle" and entry.op == "spawn_vehicle"):
			lines.append(syntax(entry) + " — " + entry.help)
	return "\n".join(lines) if not lines.is_empty() else "Unknown help topic. Use help for the command catalog."

static func tokenize(line: String, incomplete := false) -> Dictionary:
	if line.length() > 1024: return {"error": "Command is too long (maximum 1024 characters)."}
	if line.contains(";") or line.contains("\n") or line.contains("\r"):
		return {"error": "Submit one command per line; command batches are not supported."}
	var words: Array[String] = []
	var word := ""
	var quote := ""
	var started := false
	for ch in line:
		if not quote.is_empty():
			if ch == quote: quote = ""
			else: word += ch
		elif ch == '"' or ch == "'":
			if started: return {"error": "Quotes must enclose an entire argument."}
			quote = ch
			started = true
		elif ch == " " or ch == "\t":
			if started: words.append(word)
			word = ""
			started = false
		else:
			word += ch
			started = true
	if not quote.is_empty() and not incomplete: return {"error": "Unclosed quote."}
	if started: words.append(word)
	return {"words": words}

static func _field(token: String) -> Dictionary:
	var pair := token.trim_prefix("{").trim_suffix("}").split(":")
	return {"name": pair[0], "type": pair[1].trim_suffix("?"), "optional": pair[1].ends_with("?")}

static func parse(line: String, state: GameState, caller: int) -> Dictionary:
	var lex := tokenize(line)
	if lex.has("error"): return lex
	var words: Array = lex.words
	if words.is_empty(): return {"error": "Enter a command. Type help for the catalog."}
	var first := str(words[0]).to_lower()
	if not CheatAccess.permitted(state, caller) and first not in ["help", "players", "cheats", "clear", "kick", "ban"] and not (words.size() == 2 and first == "ids" and str(words[1]).to_lower() == "off"):
		return {"error": CheatAccess.denial(state, caller)}
	if first == "help": return {"op": "help", "args": {"topic": " ".join(words.slice(1)).to_lower()}, "access": "safe"}
	if first in ["units", "vehicles"]: return _parse_list(first, words.slice(1), state, caller)
	var best := "Unknown command. Type help for the catalog."
	var best_prefix := 0
	for entry: Dictionary in CATALOG:
		var pattern := str(entry.pattern).split(" ")
		var prefix := 0
		for i in mini(words.size(), pattern.size()):
			if pattern[i].begins_with("{"): break
			if str(words[i]).to_lower() != pattern[i]: break
			prefix += 1
		if prefix == 0: continue
		var args := {}
		var error := ""
		for i in pattern.size():
			var token: String = pattern[i]
			if not token.begins_with("{"):
				if i >= words.size() or str(words[i]).to_lower() != token: error = "Expected '%s'." % token; break
				continue
			var field := _field(token)
			if i >= words.size():
				if not field.optional: error = "Missing %s." % field.name; break
				continue
			var value := _atom(words[i], field.type, state, caller, false)
			if value.has("error"): error = "%s: %s" % [field.name, value.error]; break
			args[field.name] = value.value
		if error.is_empty() and words.size() > pattern.size(): error = "Too many arguments."
		if error.is_empty():
			var checked := validate_payload(entry.op, args, state, caller)
			if checked.has("error"): checked.error += " Syntax: " + syntax(entry)
			return checked
		if prefix > best_prefix:
			best_prefix = prefix
			best = error + " Syntax: " + syntax(entry)
	return {"error": best}

static func _parse_list(op: String, words: Array, state: GameState, caller: int) -> Dictionary:
	var args := {"owner": -1, "page": 1}
	var index := 0
	if not words.is_empty() and str(words[0]).to_lower() != "page":
		var owner := _atom(words[0], "players", state, caller, false)
		if owner.has("error"): return owner
		args.owner = owner.value
		index = 1
	if index < words.size() and str(words[index]).to_lower() == "status":
		if words.size() != index + 1: return {"error": "Syntax: %s <player|all> status" % op}
		return {"op": op + "_status", "args": {"owner": args.owner}, "access": "inspect"}
	if index < words.size():
		if words.size() != index + 2 or str(words[index]).to_lower() != "page":
			return {"error": "Syntax: %s [player|all] [page <number>]" % op}
		var page := _atom(words[index + 1], "page", state, caller, false)
		if page.has("error"): return page
		args.page = page.value
	return {"op": op, "args": args, "access": "inspect"}

## Validate again at execution, including arguments supplied directly over the wire.
static func validate_payload(op: String, payload: Variant, state: GameState, caller: int) -> Dictionary:
	var entry := definition(op)
	if entry.is_empty(): return {"error": "Unknown cheat operation."}
	if not payload is Dictionary or payload.size() > 8: return {"error": "Invalid cheat payload."}
	var args := {}
	for token in str(entry.pattern).split(" "):
		if not token.begins_with("{"): continue
		var field := _field(token)
		if not payload.has(field.name):
			if field.optional: continue
			return {"error": "Missing %s." % field.name}
		var value := _atom(payload[field.name], field.type, state, caller, true)
		if value.has("error"): return {"error": "%s: %s" % [field.name, value.error]}
		args[field.name] = value.value
	if args.size() != payload.size(): return {"error": "Unexpected argument in cheat payload."}
	if op == "unit_stat":
		var bounds: Array = UnitInstance.CHEAT_STAT_BOUNDS[args.field]
		if args.value < bounds[0] or args.value > bounds[1]: return {"error": "%s must be %d–%d." % [args.field, bounds[0], bounds[1]]}
	if op == "world_fire_clear" and args.size() not in [0, 3]: return {"error": "Supply x, y and radius together, or omit all three."}
	if op == "event_queue" and args.has("x") != args.has("y"): return {"error": "Supply both x and y, or omit both."}
	if args.has("width") and (args.x + args.width > state.grid.width or args.y + args.height > state.grid.height):
		return {"error": "Cloud rectangle extends outside the board."}
	return {"op": op, "args": args, "access": entry.access}

static func _atom(raw: Variant, type: String, state: GameState, caller: int, typed: bool) -> Dictionary:
	var text := str(raw)
	var lower := text.to_lower()
	if type in ["player", "players"]:
		var side := -99
		if typed:
			if not _integer(raw): return {"error": "Expected a numeric player slot."}
			side = int(raw)
		elif lower == "self": side = caller
		elif lower == "all" and type == "players": side = -1
		elif lower.begins_with("#") and lower.substr(1).is_valid_int(): side = int(lower.substr(1)) - 1
		else:
			for slot: Roster.Slot in state.roster.slots:
				if slot.display_name == text:
					if side != -99: return {"error": "Ambiguous player name; use #slot."}
					side = slot.id
		if side == -1 and type == "players": return {"value": -1}
		var target := state.roster.slot(side)
		if target == null or not target.is_playing(): return {"error": "Choose a playable #1–#26 slot, self, or an exact quoted player name."}
		return {"value": side}
	if type == "bool":
		if typed: return {"value": raw} if raw is bool else {"error": "Expected on or off."}
		return {"value": lower == "on"} if lower in ["on", "off"] else {"error": "Expected on or off."}
	if type == "event_properties":
		var props: Variant = raw if typed else JSON.parse_string(text)
		if not props is Dictionary or props.size() > 8: return {"error": "Expected a quoted JSON object of supported event properties."}
		var cleaned := {}
		for key in props:
			if not key is String or not key in ["x", "y", "w", "h", "rounds", "edge", "from", "len", "hx", "hy", "side", "budget", "unit"] or not _integer(props[key]) or absf(float(props[key])) > 1000000: return {"error": "Unsupported event property or non-integer value."}
			cleaned[key] = int(props[key])
		return {"value": cleaned}
	if type == "event_ref":
		if not raw is String or text.length() > 40: return {"error": "Expected an event reference from event list."}
		return {"value": lower}
	if type == "text": return {"value": text} if raw is String and text.length() <= 100 else {"error": "Invalid text."}
	if type in ["ap", "component_value", "event_index"]:
		var keyword: String = {"ap": "refill", "component_value": "restore", "event_index": "all"}[type]
		if lower == keyword and raw is String: return {"value": keyword}
	if type == "ai_speed":
		if not (raw is int or raw is float or (not typed and text.is_valid_float())): return {"error": "Expected an AI speed."}
		var speed := float(raw)
		return {"value": speed} if GameConfig.AI_SPEEDS.has(speed) else {"error": "Use 0.5, 1, 2, 4, 8, 16 or 64."}
	var ranges := {"x": [0, state.grid.width - 1], "y": [0, state.grid.height - 1],
		"unit": [0, Vehicle.ID_BASE - 1], "vehicle": [Vehicle.ID_BASE, 2147483647],
		"count": [1, 100], "ap": [0, 99], "stat_value": [0, 1024], "rotation": [0, 3],
		"radius": [0, maxi(state.grid.width, state.grid.height)], "width": [1, state.grid.width],
		"height": [1, state.grid.height], "event_value": [0, 1000000], "event_interval": [1, 20], "rounds": [1, 100], "page": [1, 1000000],
		"points": [0, 1000000], "waves": [0, 999], "component_value": [0, 1000000], "event_index": [0, 1000000]}
	if ranges.has(type):
		if not typed and ((type == "unit" and lower.begins_with("u")) or (type == "vehicle" and lower.begins_with("v"))):
			text = text.substr(1)
			raw = text
		if not (_integer(raw) if typed else text.is_valid_int()): return {"error": "Expected an integer."}
		if float(raw) < ranges[type][0] or float(raw) > ranges[type][1]: return {"error": "Value outside allowed bounds."}
		var value := int(raw)
		if value < ranges[type][0] or value > ranges[type][1]: return {"error": "Expected %d–%d." % [ranges[type][0], ranges[type][1]]}
		if type == "unit" and state.get_unit(value) == null: return {"error": "Unit ID does not exist."}
		if type == "vehicle" and state.get_vehicle(value) == null: return {"error": "Vehicle ID does not exist."}
		return {"value": value}
	if type == "look":
		if (_integer(raw) if typed else text.is_valid_int()):
			var look := int(raw)
			return {"value": look} if look >= 0 and look < MCF.FLOOR_LOOK_NAMES.size() else {"error": "Unknown floor look."}
		for i in MCF.FLOOR_LOOK_NAMES.size():
			if str(MCF.FLOOR_LOOK_NAMES[i]).to_lower() == lower: return {"value": i}
		return {"error": "Unknown floor look. Use a quoted registry name or its numeric ID."}
	if not raw is String: return {"error": "Expected a registered identifier."}
	var values := choices(type, state, caller, false)
	for value: Dictionary in values:
		if str(value.value).to_lower() == lower: return {"value": value.value}
	return {"error": "Unknown %s '%s'. Use Tab or help for valid values." % [type, text.left(80)]}

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value))

static func choices(type: String, state: GameState, caller: int, entities: bool) -> Array:
	var ids: Array = []
	match type:
		"unit_type": ids = unit_types()
		"vehicle_type": ids = VehicleDB.ids()
		"feature":
			ids = MCF.FEATURE_NAMES.keys()
			ids.erase(MCF.FEATURE_BOUNDARY)
			ids.append("none")
		"furniture": ids = Furniture.ids(); ids.append("none")
		"item": ids = MCF.ITEM_NAMES.keys(); ids.append("none")
		"event":
			for entry: Array in RandomEvents.REGISTRY: ids.append(entry[0])
		"event_property": ids = ["x", "y", "w", "h", "rounds", "edge", "from", "len", "hx", "hy", "side", "budget", "unit"]
		"time": ids = MapData.TIMES.duplicate()
		"stat": ids = UnitInstance.CHEAT_STAT_BOUNDS.keys()
		"facing": ids = ["n", "e", "s", "w"]
		"floor": ids = ["normal", "flammable", "grass"]
		"civilian": ids = ["activate", "sleep"]
		"personality": ids = ["tactician", "aggressor", "fortifier", "learned"]
		"entities": ids = ["units", "vehicles", "all"]
		"bool": ids = ["on", "off"]
		"look": ids = MCF.FLOOR_LOOK_NAMES.duplicate()
		"ap": ids = ["refill"]
		"component_value": ids = ["restore"]
		"event_index": ids = ["all"]
		"ai_speed": ids = ["0.5", "1", "2", "4", "8", "16", "64"]
		"component":
			for vehicle: Vehicle in state.all_vehicles():
				for component: String in vehicle.components:
					if not ids.has(component): ids.append(component)
		"player", "players":
			ids = ["self"]
			if type == "players": ids.append("all")
			for slot: Roster.Slot in state.roster.slots:
				if slot.is_playing(): ids.append("#%d" % (slot.id + 1))
		"unit", "vehicle":
			if not entities or not CheatAccess.permitted(state, caller): return []
			var out: Array = []
			var units := state.all_units() if type == "unit" else state.all_vehicles()
			units = units.duplicate()
			units.sort_custom(func(a, b): return a.id < b.id)
			for entity in units:
				var at: Vector2i = entity.coord if type == "unit" else entity.origin
				var name: String = entity.stats.display_name if type == "unit" else entity.type_id
				out.append({"value": str(entity.id), "label": "%s%d — %s, %s, (%d, %d)" % ["U" if type == "unit" else "V", entity.id, name, state.roster.name_of(entity.owner), at.x, at.y]})
			return out
	ids.sort()
	var out: Array = []
	for value in ids:
		var label := str(value)
		if label.begins_with("#"): label += " — " + state.roster.name_of(int(label.substr(1)) - 1)
		out.append({"value": value, "label": label})
	return out

static func complete(line: String, state: GameState, caller: int, resolver: GameActionResolver = null) -> Array:
	var lex := tokenize(line, true)
	if lex.has("error"): return []
	var words: Array = lex.words
	if line.ends_with(" ") or words.is_empty(): words.append("")
	var index := words.size() - 1
	var prefix := str(words[index]).to_lower()
	var out: Array = []
	var used := {}
	for entry: Dictionary in CATALOG:
		if entry.access in ["inspect", "play", "host_play", "tool"] and not CheatAccess.permitted(state, caller): continue
		var tokens := str(entry.pattern).split(" ")
		if index >= tokens.size(): continue
		var match_prefix := true
		for i in index:
			if not tokens[i].begins_with("{") and str(words[i]).to_lower() != tokens[i]: match_prefix = false; break
		if not match_prefix: continue
		var values := choices(_field(tokens[index]).type, state, caller, true) if tokens[index].begins_with("{") else [{"value": tokens[index], "label": tokens[index]}]
		if resolver != null and tokens[index].begins_with("{"):
			var type: String = _field(tokens[index]).type
			if type == "event_ref":
				values = []
				for event: Dictionary in CheatEventModel.entries(resolver):
					values.append({"value": event.ref, "label": "%s · %s · %s" % [event.ref, RandomEvents.event_name(event.event), event.phase]})
			elif type == "event_property" and words.size() > 2:
				var event := CheatEventModel.find(resolver, str(words[2]))
				if not event.is_empty():
					values = []
					for key: String in event.properties: values.append({"value": key, "label": key})
		for value: Dictionary in values:
			var insert := str(value.value)
			if not insert.to_lower().begins_with(prefix) or used.has(insert): continue
			used[insert] = true
			var before: Array = words.slice(0, index)
			for i in before.size():
				if str(before[i]).contains(" "): before[i] = '"' + before[i] + '"'
			if insert.contains(" "): insert = '"' + insert + '"'
			before.append(insert)
			out.append({"insert": " ".join(before) + " ", "label": value.label + "  —  " + entry.help, "syntax": syntax(entry)})
	return out
