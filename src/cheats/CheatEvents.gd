class_name CheatEvents
extends RefCounted

static func apply(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var a := intent.args
	if r.random_events == null: r.random_events = RandomEvents.new(false)
	var events := r.random_events
	if intent.op not in ["event_cancel", "event_queue"]: return manage(r, intent)
	if intent.op == "event_cancel":
		if a.index is String:
			var count := events.pending.size()
			events.pending.clear()
			return CheatUnits.result("Canceled %d pending warnings; active effects remain." % count)
		if a.index >= events.pending.size(): return ActionResult.fail("No pending event has that index.")
		var old: Dictionary = events.pending[a.index]
		events.pending.remove_at(a.index)
		return CheatUnits.result("Canceled warning %d: %s." % [a.index, old.id])
	var id: String = a.event
	if a.has("x") and id not in [RandomEvents.MORTAR, RandomEvents.GAS, RandomEvents.FIRE, RandomEvents.EMP, RandomEvents.COLLAPSE, RandomEvents.ARMY, RandomEvents.REINFORCE]:
		return ActionResult.fail("This event does not support a target coordinate.")
	if not _eligible(r, id, a.get("properties", {})): return ActionResult.fail("This event has no eligible targets in the current map or mode.")
	if id == RandomEvents.ARMY:
		var armies := 0
		for side: int in r.state.turns.round_order:
			if MCF.is_independent(side) and r._army_holds_field(side): armies += 1
		if armies >= r.ARMY_MAX: return ActionResult.fail("Two independent armies are already active.")
		if r._independent_roster().is_empty() and not a.get("properties", {}).has("units"): return ActionResult.fail("All independent army unit types are restricted.")
	var out := CheatUnits.result("Forced event: " + RandomEvents.event_name(id) + ".")
	if id == RandomEvents.MINEFIELD: r._start_minefield(out); return out
	if id == RandomEvents.BOUNTY: r._start_bounty(out); return out
	var checkpoint := r.state.dice.checkpoint()
	var params := _roll_params(r, id, a.get("properties", {}))
	if params.is_empty():
		r.state.dice.restore_checkpoint(checkpoint)
		return ActionResult.fail("No eligible area is available for this event.")
	if a.has("properties"):
		params.merge(a.properties, true)
		_normalize_entry(params, a.properties, r)
		var error := CheatEventModel.validate(id, params, r)
		if error.is_empty() and id == RandomEvents.MORTAR and _overlaps(r, params): error = "The artillery area overlaps a pending barrage."
		if not error.is_empty():
			r.state.dice.restore_checkpoint(checkpoint)
			return ActionResult.fail(error)
	if a.has("x") and id in [RandomEvents.ARMY, RandomEvents.REINFORCE]:
		params.x = a.x
		params.y = a.y
		params.erase("hx"); params.erase("hy")
	elif a.has("x") and not a.has("properties"):
		params.x = clampi(a.x - int(params.w) / 2, 0, r.state.grid.width - int(params.w))
		params.y = clampi(a.y - int(params.h) / 2, 0, r.state.grid.height - int(params.h))
		if id == RandomEvents.MORTAR:
			params = r._free_barrage_zone(params, Rect2i(0, 0, r.state.grid.width, r.state.grid.height))
			if params.is_empty():
				r.state.dice.restore_checkpoint(checkpoint)
				return ActionResult.fail("No non-overlapping barrage area is available.")
	events.announce(id, params, r.state.turns.round_number)
	out.log("⚠ %s - %s, landing at the end of this round" % [RandomEvents.event_name(id), r._event_where(id, params)])
	out.cheat_output += " " + r._event_where(id, params)
	return out

static func manage(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var a := intent.args
	var events := r.random_events
	match intent.op:
		"event_automatic": events.enabled = a.enabled
		"event_interval": events.interval = a.rounds; events.turns_since = mini(events.turns_since, events.interval)
		"event_guaranteed": events.mandatory = a.enabled
		"event_enabled": events.weights[a.event] = 1 if a.enabled else 0
		"event_spawn", "event_trigger": return _spawn_now(r, intent)
		"event_remove", "event_set", "event_update": return _edit(r, intent)
		_: return ActionResult.fail("Unknown event operation.")
	return CheatUnits.result("Automatic events: %s; every %d rounds; %s." % ["enabled" if events.enabled else "disabled", events.interval, "guaranteed" if events.mandatory else "normal random chance"])

static func _overlaps(r: GameActionResolver, p: Dictionary, except_uid := -1) -> bool:
	var area := Rect2i(p.x, p.y, p.w, p.h)
	for entry: Dictionary in r.random_events.pending:
		if entry.id != RandomEvents.MORTAR or int(entry.uid) == except_uid: continue
		var other: Dictionary = entry.params
		if area.intersects(Rect2i(other.x, other.y, other.w, other.h)): return true
	return false

static func _spawn_now(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var a := intent.args
	var id: String = a.event
	if not _eligible(r, id, a.get("properties", {})): return ActionResult.fail("This event has no eligible targets in this map or mode.")
	if id == RandomEvents.ARMY:
		var armies := 0
		for side: int in r.state.turns.round_order:
			if MCF.is_independent(side) and r._army_holds_field(side): armies += 1
		if armies >= r.ARMY_MAX or r._independent_roster().is_empty() and not a.get("properties", {}).has("units"): return ActionResult.fail("No independent army can land: two active armies or all unit types excluded.")
	var out := CheatUnits.result("Triggered " + RandomEvents.event_name(id) + ".")
	var properties: Dictionary = a.get("properties", {})
	var error := CheatEventModel.validate(id, properties, r)
	if not error.is_empty(): return ActionResult.fail(error)
	if id == RandomEvents.MINEFIELD:
		var at := Vector2i(a.x, a.y) if a.has("x") else Vector2i(-1, -1)
		if at.x >= 0 and not r._minefield_cells().has(at): return ActionResult.fail("Choose unoccupied ground for the minefield center.")
		r._start_minefield(out, at)
		return out
	if id == RandomEvents.BOUNTY:
		var unit: UnitInstance = null
		if a.has("x"): unit = r.state.grid.cell(Vector2i(a.x, a.y)).occupant
		if a.has("x") and (unit == null or not unit.is_alive() or unit.is_drone or not MCF.is_player(unit.owner)): return ActionResult.fail("Click a living player soldier to mark a bounty.")
		if unit != null:
			r.mode.bounty_unit = unit.id
			r.mode.bounty_side = unit.owner
			r.mode.bounty_until = r.state.turns.round_number + int(properties.get("rounds", r.BOUNTY_ROUNDS)) - 1
		else:
			r._start_bounty(out)
		return out
	var checkpoint := r.state.dice.checkpoint()
	var p := _roll_params(r, id, a.get("properties", {}))
	if p.is_empty():
		r.state.dice.restore_checkpoint(checkpoint)
		return ActionResult.fail("No eligible event area is available.")
	p.merge(properties, true)
	_normalize_entry(p, properties, r)
	if a.has("x"):
		if p.has("w") and not properties.has("x"):
			p.x = clampi(a.x - int(p.w) / 2, 0, r.state.grid.width - int(p.w))
			p.y = clampi(a.y - int(p.h) / 2, 0, r.state.grid.height - int(p.h))
		elif id in [RandomEvents.ARMY, RandomEvents.REINFORCE]:
			p.x = a.x; p.y = a.y
			p.erase("hx"); p.erase("hy")
		elif p.has("edge"):
			if r.state.env == "bunker": p.hx = a.x; p.hy = a.y
			else:
				var distances := [a.y, r.state.grid.width - 1 - a.x, r.state.grid.height - 1 - a.y, a.x]
				var edge: int = distances.find(distances.min())
				var along := r.state.grid.width if edge % 2 == 0 else r.state.grid.height
				p.edge = edge
				p.len = mini(int(p.len), along)
				p["from"] = clampi((a.x if edge % 2 == 0 else a.y) - int(p.len) / 2, 0, along - int(p.len))
	error = CheatEventModel.validate(id, p, r)
	if error.is_empty() and id == RandomEvents.MORTAR and _overlaps(r, p): error = "The artillery area overlaps a pending barrage."
	if not error.is_empty():
		r.state.dice.restore_checkpoint(checkpoint)
		return ActionResult.fail(error)
	r.land_event(id, p, out)
	out.cheat_output += " " + r._event_where(id, p)
	if id in [RandomEvents.ARMY, RandomEvents.REINFORCE] and not out.log_lines.is_empty(): out.cheat_output += "\n" + "\n".join(out.log_lines)
	return out

static func _edit(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var ref: String = intent.args.target
	var entry := CheatEventModel.find(r, ref)
	if entry.is_empty(): return ActionResult.fail("That event no longer exists. Refresh event list.")
	var remove := intent.op == "event_remove"
	var p: Dictionary = entry.properties.duplicate()
	if not remove:
		var changed: Dictionary = intent.args.get("properties", {})
		if intent.op == "event_set": changed = {intent.args.property: intent.args.value}
		for key: String in changed:
			if not CheatEventModel.schema(entry.event, r, p).has(key): return ActionResult.fail("This event has no editable '%s' property." % key)
		p.merge(changed, true)
		var error := CheatEventModel.validate(entry.event, p, r)
		if not error.is_empty(): return ActionResult.fail(error)
	var events := r.random_events
	if ref.begins_with("warning:"):
		for index in events.pending.size():
			var current: Dictionary = events.pending[index]
			if "warning:%d" % current.uid != ref: continue
			if not remove and entry.event == RandomEvents.MORTAR and _overlaps(r, p, current.uid): return ActionResult.fail("The area overlaps another pending barrage.")
			if remove: events.pending.remove_at(index)
			else: current.params = p
			break
	elif ref.begins_with("gas:") or ref.begins_with("smoke:"):
		var clouds: Array = events.clouds if ref.begins_with("gas:") else events.smoke
		for index in clouds.size():
			if int(clouds[index].uid) != int(ref.get_slice(":", 1)): continue
			if remove: clouds.remove_at(index)
			else:
				clouds[index].merge({"x": p.x, "y": p.y, "w": p.w, "h": p.h, "left": p.rounds}, true)
			break
	elif ref == "dust": events.dust_left = 0 if remove else int(p.rounds)
	elif ref == "bounty":
		if remove: r.mode.bounty_unit = -1
		else:
			r.mode.bounty_unit = p.unit
			r.mode.bounty_side = r.state.get_unit(p.unit).owner
			r.mode.bounty_until = r.state.turns.round_number + int(p.rounds) - 1
	elif ref in ["fire", "minefield"]:
		if not remove: return ActionResult.fail("This persistent effect has no editable numeric properties. It can be removed.")
		for cell: GridCell in r.state.grid.cells_flat():
			if ref == "fire" and cell.on_fire and cell.fire_owner == r.EVENT_FIRE_OWNER:
				cell.on_fire = false
				cell.fire_owner = -1
			if ref == "minefield" and cell.feature_id in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE] and cell.feature_owner == r.OLD_MINE_OWNER:
				cell.set_feature("", -1)
	elif ref.begins_with("army:"):
		if not remove: return ActionResult.fail("This army has landed. Inspect or edit its individual units; event remove withdraws the force.")
		var army: Array[UnitInstance] = []
		for unit: UnitInstance in r.state.all_units():
			if unit.owner == int(ref.get_slice(":", 1)): army.append(unit)
		for unit: UnitInstance in army:
			var error := CheatUnits.linked(r, unit)
			if not error.is_empty(): return ActionResult.fail("Cannot withdraw linked army unit U%d: %s" % [unit.id, error])
		for unit: UnitInstance in army: CheatUnits.apply(r, CheatIntent.new("unit_remove", {"unit": unit.id}, intent.issuer))
	r._sync_gas()
	UnitInstance.bump_world_vision()
	return CheatUnits.result(("Removed " if remove else "Updated ") + ref + ("." if remove else ": " + str(p)))

static func _normalize_entry(params: Dictionary, options: Dictionary, r: GameActionResolver) -> void:
	if not params.has("edge"): return
	if options.has("x") or options.has("edge"):
		params.erase("hx")
		params.erase("hy")
	if options.has("edge"):
		var along := r.state.grid.width if int(params.edge) % 2 == 0 else r.state.grid.height
		params.len = mini(int(params.get("len", 1)), along)
		if not options.has("from"): params["from"] = (along - int(params.len)) / 2

static func _eligible(r: GameActionResolver, id: String, options: Dictionary) -> bool:
	if id == RandomEvents.REINFORCE and options.has("side"):
		return r.state.roster.player_ids().has(int(options.side))
	if id == RandomEvents.ARMY and options.has("units"):
		return r.mode.kind != MatchMode.Kind.HOLDOUT
	return r._events_allowed().has(id)

static func _roll_params(r: GameActionResolver, id: String, options: Dictionary) -> Dictionary:
	if id == RandomEvents.REINFORCE and options.has("side"):
		var params := r._roll_event_params(RandomEvents.ARMY)
		params.side = options.side
		params.budget = int(options.get("budget", 1))
		return params
	return r._roll_event_params(id)
