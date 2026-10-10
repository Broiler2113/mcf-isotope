extends SceneTree

## Every wall surface offered by Demolish Fortification must be highlighted and
## accepted by the resolver. Brick, stucco, cinder block and station plating are
## visual variants of FEATURE_WALL, so they also exercise the wall-look path.

var failures: PackedStringArray = []

func _initialize() -> void:
	var cases := [
		["wall", MCF.FEATURE_WALL, -1],
		["wood", MCF.FEATURE_WOOD_WALL, -1],
		["soil", MCF.FEATURE_SOIL, -1],
		["glass", MCF.FEATURE_GLASS, -1],
		["armored wall", MCF.FEATURE_ARMOR_WALL, -1],
		["armored glass", MCF.FEATURE_ARMOR_GLASS, -1],
		["airlock", MCF.FEATURE_AIRLOCK, -1],
		["brick", MCF.FEATURE_WALL, 0],
		["stucco", MCF.FEATURE_WALL, 1],
		["cinder block", MCF.FEATURE_WALL, 2],
		["station", MCF.FEATURE_WALL, 3],
	]
	for actor_type in ["miner", "engineer"]:
		for test_case in cases:
			_check(actor_type, test_case[0], test_case[1], int(test_case[2]), true)
		_check(actor_type, "world boundary", MCF.FEATURE_BOUNDARY, -1, false)
	if failures.is_empty():
		print("demolish materials: 22 surfaces accepted; world boundary protected")
		quit(0)
		return
	for failure in failures:
		printerr(failure)
	quit(1)

func _check(actor_type: String, label: String, feature: String, look: int,
		should_break: bool) -> void:
	var target := Vector2i(6, 5)
	var map := MapData.blank_arena(12, 12)
	map.set_cell(target, MCF.FLOOR_NORMAL, 0.0, false, feature)
	if look >= 0:
		map.set_look(target.y * map.width + target.x, MCF.wall_look(look))
	map.set_spawn(Vector2i(5, 5), actor_type, MCF.Owner.PLAYER_1)
	map.set_spawn(Vector2i(10, 10), "light_infantry", MCF.Owner.PLAYER_2)
	var state := map.build_state(7)
	var resolver := GameActionResolver.new(state)
	var actor: UnitInstance = state.living_units_of(MCF.Owner.PLAYER_1)[0]
	var prefix := "%s / %s" % [actor_type, label]
	if resolver.can_break_cell(actor, target) != should_break:
		failures.append(prefix + ": eligibility mismatch")
	if resolver.breakable_cells(actor).has(target) != should_break:
		failures.append(prefix + ": UI highlight mismatch")
	if not should_break:
		return
	while state.active_player() != MCF.Owner.PLAYER_1:
		resolver.resolve(EndTurnIntent.new())
	var result := resolver.resolve(BreakIntent.new(actor.id, target))
	if not result.ok or state.grid.cell(target).feature_id != "" \
			or state.grid.cell(target).cover_height != 0.0:
		failures.append(prefix + ": demolition failed: " + result.reason)
