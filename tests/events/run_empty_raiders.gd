extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapData.blank_arena(32, 24)
	map.set_spawn(Vector2i(14, 10), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 14), "light_infantry", 1)
	# The announced landing band contains no ground at any depth.
	for y in map.height:
		for x in 8: map.set_cell(Vector2i(x, y), 0, 0, true, "")
	var state := map.build_state(17)
	var resolver := GameActionResolver.new(state)
	resolver.random_events = RandomEvents.new(true, true, 1)
	var arrival := {"edge": 0, "from": 0, "len": 6}
	resolver._land_army(arrival, ActionResult.success([]))
	var raiders: Array = state.all_units().filter(func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner))
	ck(not raiders.is_empty(), "raiders find the next landing band when the announced band is vacuum")
	ck(raiders.all(func(u: UnitInstance) -> bool: return not state.grid.cell(u.coord).is_space), "all raiders land on ground")
	var slot := MCF.independent_slot(1)
	for i in raiders.size():
		if i > 1: raiders[i].status = MCF.Status.CORPSE
	state.deaths[slot] = maxi(20, raiders.size() - 2)
	ck(not resolver._army_holds_field(slot), "two surviving raiders do not keep a new army away")
	var drone := state.spawn_unit(load("res://src/data/units/%s.tres" % MCF.DRONE_STATS_ID), Vector2i(20, 20), slot)
	drone.is_drone = true
	for u: UnitInstance in raiders: u.status = MCF.Status.CORPSE
	state.turns.round_order.assign([0, slot, 1])
	state.turns.active_index = 0
	ck(not state.turns.playable(slot, state.all_units()), "a drone without soldiers does not keep a slot active")
	state.turns.end_turn(state.all_units())
	ck(state.active_player() == 1, "initiative skips the empty army")
