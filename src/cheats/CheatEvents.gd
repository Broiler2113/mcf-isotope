class_name CheatEvents
extends RefCounted

static func apply(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var a := intent.args
	if r.random_events == null: r.random_events = RandomEvents.new(false)
	var events := r.random_events
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
	if a.has("x") and id not in [RandomEvents.MORTAR, RandomEvents.GAS, RandomEvents.FIRE, RandomEvents.EMP, RandomEvents.COLLAPSE]:
		return ActionResult.fail("This event does not support a target coordinate.")
	if not r._events_allowed().has(id): return ActionResult.fail("This event has no eligible targets in the current map or mode.")
	if id == RandomEvents.ARMY:
		var armies := 0
		for side: int in r.state.turns.round_order:
			if MCF.is_independent(side) and r._army_holds_field(side): armies += 1
		if armies >= r.ARMY_MAX: return ActionResult.fail("Two independent armies are already active.")
		if r._independent_roster().is_empty(): return ActionResult.fail("All independent army unit types are restricted.")
	var out := CheatUnits.result("Forced event: " + RandomEvents.event_name(id) + ".")
	if id == RandomEvents.MINEFIELD: r._start_minefield(out); return out
	if id == RandomEvents.BOUNTY: r._start_bounty(out); return out
	var checkpoint := r.state.dice.checkpoint()
	var params := r._roll_event_params(id)
	if params.is_empty():
		r.state.dice.restore_checkpoint(checkpoint)
		return ActionResult.fail("No eligible area is available for this event.")
	if a.has("x"):
		params.x = clampi(a.x - int(params.w) / 2, 0, r.state.grid.width - int(params.w))
		params.y = clampi(a.y - int(params.h) / 2, 0, r.state.grid.height - int(params.h))
		if id == RandomEvents.MORTAR:
			params = r._free_barrage_zone(params, Rect2i(0, 0, r.state.grid.width, r.state.grid.height))
			if params.is_empty():
				r.state.dice.restore_checkpoint(checkpoint)
				return ActionResult.fail("No non-overlapping barrage area is available.")
	events.announce(id, params, r.state.turns.round_number)
	out.log("⚠ %s — %s, landing at the end of this round" % [RandomEvents.event_name(id), r._event_where(id, params)])
	out.cheat_output += " " + r._event_where(id, params)
	return out
