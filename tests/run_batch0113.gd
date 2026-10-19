extends SceneTree
## 0.11.3 batch: decals, corpses and far-view rubble only where the viewer has looked;
## no Flammable box on the random map; raiders play at the AI speed; gas hidden in fog;
## a drone over a wall is blind; before/after keeps the fog and the enemy's deployment.

var fails: PackedStringArray = []
func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond: fails.append(what)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_decal_memory()
	_drone_over_wall()
	_gas_sight()
	await _lobby()
	await _battle_screen()
	print("batch 0.11.3: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

func _casing(fx: FxDecals, at: Vector2) -> Dictionary:
	var p := {"kind": "casing", "pos": at, "rot": 0.0, "scale": 1.0}
	fx._settle(fx.props, p)
	return p

func _held(mem: DecalMemory, p: Dictionary) -> bool:
	for list: Array in mem.view.by_chunk.values():
		for q: Dictionary in list:
			if is_same(q, p): return true
	return false

## #1: what lands in the dark is not shown until it is seen; what goes away in the dark
## stays until it is seen. Laser marks show only the part that was in sight.
func _decal_memory() -> void:
	var gw := 40
	var live := FxDecals.new()
	var mem := DecalMemory.new(live)
	var vis := {}
	for y in 14:
		for x in 20:
			vis[Vector2i(x, y)] = true
	var near := _casing(live, Vector2(3.5, 3.5))
	var far := _casing(live, Vector2(30.5, 6.5))
	mem.update(live, vis, [], gw)
	ck(_held(mem, near) and not _held(mem, far), "a casing in the dark is not shown, one in sight is")
	vis[Vector2i(30, 6)] = true
	mem.update(live, vis, [6 * gw + 30], gw)
	ck(_held(mem, far), "once the spot is seen the casing shows")
	vis.erase(Vector2i(30, 6))
	mem.update(live, vis, [6 * gw + 30], gw)
	ck(_held(mem, far), "and stays remembered after the spot goes dark")
	live._burn({"cells": [Vector2i(30, 6)]})
	ck(live.props.has(far), "fire leaves the casing where it lies (owner, 2026-10-19)")
	live.props.erase(far)   # gone in the dark some other way: kicked aside, undone
	live._reindex()
	mem.update(live, vis, [], gw)
	ck(_held(mem, far), "gone in the dark: still remembered")
	vis[Vector2i(30, 6)] = true
	mem.update(live, vis, [6 * gw + 30], gw)
	ck(not _held(mem, far), "looked again: it is gone")
	ck(mem.view.decal_dirty.has(Vector2i(1, 0)), "the tiles are told which chunk to rebake")
	vis.erase(Vector2i(30, 6))
	live._laser({"from": [2, 5], "to": [30, 5]})
	mem.update(live, vis, [], gw)
	ck(mem.view.laser_lines.size() == 1, "one laser mark in memory (%d)" % mem.view.laser_lines.size())
	if mem.view.laser_lines.size() == 1:
		var seg: Dictionary = mem.view.laser_lines[0]
		ck(Vector2(seg["from"]).is_equal_approx(Vector2(2.5, 5.5)) and Vector2(seg["to"]).is_equal_approx(Vector2(20, 5.5)),
				"only the seen part of the laser mark shows: %s → %s" % [seg["from"], seg["to"]])
	var all := {}
	for y in 14:
		for x in gw:
			all[Vector2i(x, y)] = true
	mem.update(live, all, null, gw)
	ck(mem.view.laser_lines.size() == 1 and is_same(mem.view.laser_lines[0], live.laser_lines[0]),
			"seen whole, the laser mark is exactly the live one")
	live._laser({"from": [2, 9], "to": [12, 9]})
	live.laser_lines = live.laser_lines.slice(1)   # FxDecals trims the oldest mark at its cap
	live.ground_version += 1
	mem.update(live, all, [], gw)
	ck(mem.view.laser_lines.size() == 1 and is_same(mem.view.laser_lines[0], live.laser_lines[0]),
			"a mark trimmed off at the cap goes, the new one shows (%d)" % mem.view.laser_lines.size())

## #4: under fog the cloud shows where we would see it if gas were clear — not behind a wall.
func _gas_sight() -> void:
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	for y in 12:
		m.set_cell(Vector2i(10, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var s := m.build_state(4)
	var r := GameActionResolver.new(s)
	r.random_events = RandomEvents.new()
	r._land_gas({"x": 6, "y": 3, "w": 8, "h": 5, "rounds": 3}, ActionResult.new())
	var seen := r.team_sees_gas(0)
	ck(seen.has(Vector2i(6, 5)) and seen.has(Vector2i(8, 5)) and seen.has(Vector2i(9, 7)),
			"the whole cloud in front of us shows, its middle too")
	ck(not seen.has(Vector2i(11, 5)) and not seen.has(Vector2i(13, 4)), "the cloud behind the wall does not")
	ck(not r.team_visible_coords(0).has(Vector2i(8, 5)), "and what is inside the gas stays hidden")

## #5: a drone hovering over a wall sees nothing past its own cell.
func _drone_over_wall() -> void:
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(5, 5), "drone_operator", 0)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	m.set_cell(Vector2i(8, 5), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var s := m.build_state(4)
	s.turns.round_order.assign([0, 1])
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	var op := s.grid.cell(Vector2i(5, 5)).occupant
	op.held_item_id = MCF.ITEM_DRONE_STATION
	op.remaining_ap = 2
	ck(r.resolve(UseItemIntent.new(op.id, Vector2i(6, 5))).ok, "station deployed")
	var drone := r.active_drone_of(op)
	ck(r.sight_of(drone) > 0, "a drone over the floor sees")
	drone.coord = Vector2i(8, 5)
	ck(r.sight_of(drone) == 0, "a drone over a wall has no sight")
	var seen := r._seen_from(drone.coord, r.sight_of(drone), 0)
	ck(seen.size() == 1 and seen[0] == 5 * s.grid.width + 8, "it sees only its own cell (%d cells)" % seen.size())
	drone.coord = Vector2i(9, 5)
	ck(r._seen_from(drone.coord, r.sight_of(drone), 0).size() > 10, "past the wall it sees again")

## #2: the random map has no Flammable box; flammability follows the map style.
func _lobby() -> void:
	var lobby: Node = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(lobby)
	for i in 3: await process_frame
	var boxes: Array = lobby.find_children("*", "CheckBox", true, false).map(func(c: CheckBox) -> String: return c.text)
	ck(not boxes.has("Flammable") and boxes.has("Obstacles"), "no Flammable box, Obstacles stays: %s" % [boxes])
	if lobby._gen_style != null:
		for style in MapGen.STYLE_FLAMMABLE.size():
			lobby._gen_style.select(style)
			ck(bool(lobby._gen_options()["flammable"]) == MapGen.STYLE_FLAMMABLE[style],
					"style %d: flammable = %s" % [style, MapGen.STYLE_FLAMMABLE[style]])
	lobby.queue_free()
	await process_frame

# --- battle screen ---------------------------------------------------------------------

var _main: Node = null

func _battle_screen() -> void:
	var m := MapData.blank_arena(40, 14)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(38, 12), "light_infantry", 1)
	m.set_spawn(Vector2i(36, 2), "heavy_infantry", 1)
	for y in 14:   # a solid wall: the east half is in the dark for the west
		m.set_cell(Vector2i(20, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.roster = Roster.default_duel(false)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	for i in 6: await process_frame
	while _main.state == null or _main._animating: await process_frame
	var st: GameState = _main.state
	var r: GameActionResolver = _main.resolver
	while st.active_player() != 0:
		_main._on_intent_ready(EndTurnIntent.new())
		for i in 3: await process_frame
		while _main._animating: await process_frame
	var vis: Dictionary = r.team_visible_coords(0)
	ck(not vis.has(Vector2i(30, 6)) and vis.has(Vector2i(3, 3)), "the far east is in the dark")
	# --- #1 decals through the battle screen: tiles and far view
	var fx: FxDecals = _main._fx
	var dark := _casing(fx, Vector2(30.5, 6.5))
	var lit := _casing(fx, Vector2(3.5, 3.5))
	fx.floor_damage[Vector2i(31, 8)] = FxDecals.DAMAGE_RUBBLE   # blast in the dark
	fx.floor_damage[Vector2i(4, 8)] = FxDecals.DAMAGE_RUBBLE    # blast in sight
	fx.damage_version += 1
	_main._lod_sync(false, 0, vis, true)
	var tile_decals: Array = []
	for list: Array in _main._tiles.decals.values(): tile_decals.append_array(list)
	ck(tile_decals.any(func(p: Dictionary) -> bool: return is_same(p, lit))
			and not tile_decals.any(func(p: Dictionary) -> bool: return is_same(p, dark)),
			"the tiles bake the casing in sight, not the one in the dark")
	_main._lod_sync(true, 0, vis, true)
	var img: Image = _main._lod_terrain
	ck(img.get_pixel(31, 8) == img.get_pixel(32, 8), "far view: no rubble from a blast in the dark")
	ck(img.get_pixel(4, 8) != img.get_pixel(5, 8), "far view: rubble in sight shows")
	ck(img.get_pixel(30, 6) == img.get_pixel(32, 6), "far view: no casing tint in the dark")
	ck(img.get_pixel(3, 3) != img.get_pixel(5, 3), "far view: the casing in sight tints its cell")
	# --- #1 corpses: one falls in the dark, one in sight
	var foe: UnitInstance = st.grid.cell(Vector2i(36, 2)).occupant
	foe.status = MCF.Status.CORPSE
	st.grid.cell(Vector2i(4, 4)).corpse_count = 2
	GridCell.corpse_version += 1
	_main.queue_redraw()
	await process_frame
	var cmem: Dictionary = _main._fog_mem_corpses.get(0, {})
	ck(_main._corpse_map().has(Vector2i(36, 2)) and not cmem.has(Vector2i(36, 2)),
			"a soldier who died in the dark is not shown")
	ck(cmem.has(Vector2i(4, 4)) and int(cmem[Vector2i(4, 4)][1]) == 2, "a pile in sight is shown with its count")
	st.grid.cell(Vector2i(4, 4)).corpse_count = 0
	GridCell.corpse_version += 1
	_main.queue_redraw()
	await process_frame
	ck(not _main._fog_mem_corpses[0].has(Vector2i(4, 4)), "a pile carried off in sight disappears")
	foe.status = MCF.Status.ALIVE
	# --- #7 before/after under fog
	ck(not _main._before_known(1, [Vector2i(36, 2)], 0), "before/after: the enemy's start in the dark is hidden")
	ck(_main._before_known(0, [Vector2i(2, 2)], 0), "before/after: our own start shows")
	ck(_main._before_seen.get(0, {}).has(Vector2i(3, 3)), "before/after remembers what we saw at the start")
	r.fog_mode = MCF.Fog.OFF
	ck(_main._before_known(1, [Vector2i(36, 2)], 0), "fog off: before/after shows everyone")
	r.fog_mode = MCF.Fog.STANDARD
	# --- #3 raiders: the AI speed row appears and their turn plays at that speed
	_main._refresh_ai_speed_row()
	ck(_main._ai_speed_row != null and not _main._ai_speed_row.visible, "no AI and no raiders: no AI speed row")
	var raider: UnitInstance = st.grid.cell(Vector2i(38, 12)).occupant
	raider.owner = MCF.INDEPENDENT_BASE
	_main._refresh_ai_speed_row()
	ck(_main._ai_speed_row.visible, "raiders on the board: the AI speed row shows")
	GameConfig.ai_speed = 4.0
	_main._playing_slot = MCF.INDEPENDENT_BASE
	ck(is_equal_approx(_main._pace(), 4.0), "a raider turn plays at the AI speed (%s)" % _main._pace())
	_main._playing_slot = -1
	GameConfig.ai_speed = 1.0
	raider.owner = 1
	_main.queue_free()
	await process_frame
