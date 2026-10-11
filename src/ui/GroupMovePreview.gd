class_name GroupMovePreview
extends RefCounted

## Cooperative, main-thread preview. Yield only between complete unit searches;
## discarded whenever the selection, AP, visibility or board changes.
var signature: Array = []
var ids: Array[int] = []
var zone := {"tier": {}, "label": {}, "reach": {}}
var best: Dictionary = {}
var cursor := 0
var zone_ready := false
var target := Vector2i(-1, -1)
var tactical := false
var job: GroupMovePlanner.Job
var revision := 0

static func key(r: GameActionResolver, selected: Array[int]) -> Array:
	var units: Array = []
	for id in selected:
		var u := r.state.get_unit(id)
		if u != null: units.append([id, u.coord, u.remaining_ap, u.move_credit, u.borg_id, u.status, u.captor_id, u.aboard_vehicle_id])
	return [r.state.grid.get_instance_id(), GridCell.walk_version, GridCell.vision_version, r.fog_mode,
		r.state.turns.round_number, r.state.turns.active_index, units]

func sync(r: GameActionResolver, selected: Array[int], destination: Vector2i,
		cover: bool, budget_usec: int = 4000) -> bool:
	var current := key(r, selected)
	if signature != current:
		signature = current
		ids = selected.duplicate()
		zone = {"tier": {}, "label": {}, "reach": {}}
		best.clear()
		cursor = 0
		zone_ready = false
		job = null
		revision += 1
	if destination != target or tactical != cover:
		target = destination
		tactical = cover
		job = null
	var deadline := Time.get_ticks_usec() + budget_usec
	while cursor < ids.size():
		var u := r.state.get_unit(ids[cursor])
		cursor += 1
		if r.can_move(u):
			var tiers := r.move_tier_budgets(u)
			var reach := r.reachable_for(u, tiers[-1])
			zone.reach[u.id] = [tiers, reach]
			for c: Vector2i in reach.cost:
				var cost := int(reach.cost[c])
				var tier := GameActionResolver.tier_of(tiers, cost)
				var prior: Variant = best.get(c)
				if prior == null or tier < prior[0] or (tier == prior[0] and cost < prior[1]):
					best[c] = [tier, cost]
					zone.tier[c] = tier
					zone.label[c] = "%d/%d" % [cost, tiers[tier]]
		if Time.get_ticks_usec() >= deadline: return false
	if not zone_ready:
		zone_ready = true
		revision += 1
	if not r.state.grid.in_bounds(target): return false
	if job == null:
		job = GroupMovePlanner.Job.new(r, ids, target, tactical, int(zone.tier.get(target, 0)))
	if Time.get_ticks_usec() < deadline: job.advance(deadline)
	return job.done

func plan() -> Array:
	return [job.out_ids, job.out_targets] if job != null and job.done else [[], []]
