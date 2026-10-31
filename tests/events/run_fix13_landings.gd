extends "res://tests/SuiteBase.gd"

## Issues-fix-13: waves, raiders and reinforcements land past bodies and taken cells instead of
## stopping at the first refused cell (#22); the outline shows where they really land and gives
## no hidden soldier away (#19); a wall built in battle takes no service band (#21).

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var r := GameActionResolver.new(MapData.blank_arena(30, 20).build_state(5))
	var li: UnitStats = r._army_stats("light_infantry")
	var body := r.state.spawn_unit(li, Vector2i(10, 0), 1)
	body.kill()
	var spots: Array[Vector2i] = [Vector2i(10, 0), Vector2i(20, 10), Vector2i(21, 10)]
	var others: Array[String] = []
	for id: String in r.ARMY_ROSTER:
		if id != "light_infantry": others.append(id)
	ck(r._spawn_budget(spots, li.cost * 2, 0, others) == 2, "a cell with a body is skipped, not the end of the landing")
	# A forced landing at a point covered in bodies lands beside them.
	for x in range(4, 7):
		for y in range(4, 7):
			r.state.spawn_unit(li, Vector2i(x, y), 1).kill()
	var res := ActionResult.success([])
	ck(r._spawn_force(r._army_spawn_cells({"x": 5, "y": 5, "count": 4}), {"count": 4}, 0, 0, ["light_infantry"], res) == 4,
			"a forced landing on bodies still lands all four")
	# Bunker hallways: a pile of bodies is not a landing cell.
	r.state.grid.cell(Vector2i(15, 15)).corpse_count = 3
	ck(not r._hallway_spawn_cells(Vector2i(15, 14)).has(Vector2i(15, 15)), "hallway landings skip piled bodies")
	# The outline: exactly the cells the landing takes, and under fog a hidden soldier's cell
	# still counts as free.
	var p := {"edge": 2, "from": 20, "len": 4}
	var hidden := r.state.spawn_unit(li, Vector2i(21, 19), 1)
	var exact := r.landing_preview(p, false, null)
	var fogged := r.landing_preview(p, false, {})
	ck(not exact.has(hidden.coord) and fogged.has(hidden.coord), "the outline never reveals a hidden soldier")
	ck(exact.size() == r.landing_need(p) and r.landing_cells(p, exact.size()).slice(0, exact.size()) == exact,
			"the outline is the landing's own first cells")
	# A raider army whose stretch is packed with bodies lands deeper in.
	for x in range(0, 30):
		if r.state.grid.cell(Vector2i(x, 19)).occupant == null:
			r.state.spawn_unit(li, Vector2i(x, 19), 1).kill()
	r.random_events = RandomEvents.new(true)
	var before := r.state.all_units().size()
	r._land_army({"edge": 2, "from": 10, "len": 6}, ActionResult.success([]))
	ck(r.state.all_units().size() > before, "raiders land past a row of bodies on their edge")
	# fix-13 #21: built in battle, a wall in a department's cell has no band; the map's has.
	ck(_band(1, -1) != _band(0, -1), "a map wall carries its department's band")
	ck(_band(1, 0) == _band(0, 0), "a wall an engineer built has none")

func _band(accent: int, owner: int) -> PackedByteArray:
	var grid := Grid.new(5, 3)
	grid.wall_accent = PackedByteArray()
	grid.wall_accent.resize(15)
	grid.cell(Vector2i(2, 1)).set_feature(MCF.FEATURE_WALL, owner)
	grid.wall_accent[1 * 5 + 2] = accent
	var tiles := TerrainTiles.new(grid, "station")
	var floor_img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var feat := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	tiles._paint(floor_img, feat, Vector2i(2, 1), Vector2i.ZERO, 32)
	return feat.get_data()
