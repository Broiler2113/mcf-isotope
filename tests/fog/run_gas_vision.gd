extends SceneTree

## Fog off with gas or smoke on the board (mode 2 of team_visible_coords).
##
##   1. A shadow (GameActionResolver._sweep_hidden) is exactly the cells a literal Bresenham
##      ray from the eye cannot reach past a cloud, on hundreds of random boards.
##   2. Through a real AI game with clouds coming and going, the side's view equals the
##      per-soldier union the old path built (each eye's _sweep under the cloud mask, cloud
##      cells dropped, an eye inside a cloud sees its own cell), after every action, from
##      the long-lived resolver and from a fresh one; explored memory covers everything seen,
##      and the change log names every cell that flipped.
##   3. 250×250, 150 eyes, three clouds: the first view and a move cost milliseconds, not seconds.

const BIG_FIRST_MS := 1500.0
const BIG_MOVE_MS := 60.0

var fails: PackedStringArray = []
var _pending: Intent = null

func _initialize() -> void:
	_shadow_matches_ray()
	_team_matches_per_soldier()
	_eyes_come_and_go()
	_big_board_is_fast()
	if fails.is_empty():
		print("gas vision: shadows == rays; team view == per-soldier union through a game; 250×250 is fast")
		quit(0)
		return
	printerr("gas vision: %d failure(s)" % fails.size())
	for f in fails.slice(0, 30):
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

## Cells hidden from (ux, uy) by blockers: a Bresenham ray (the one _vision_blocked walks)
## meets a blocker strictly between the eye and the cell.
static func _ray_hidden(ux: int, uy: int, blk: PackedByteArray, gw: int, gh: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for by in gh:
		for bx in gw:
			if bx == ux and by == uy:
				continue
			var dx := absi(bx - ux)
			var dy := absi(by - uy)
			var sx := 1 if ux < bx else -1
			var sy := 1 if uy < by else -1
			var err := dx - dy
			var cx := ux
			var cy := uy
			while true:
				var e2 := 2 * err
				if e2 > -dy:
					err -= dy
					cx += sx
				if e2 < dx:
					err += dx
					cy += sy
				if cx == bx and cy == by:
					break
				if blk[cy * gw + cx] != 0:
					out.append(by * gw + bx)
					break
	return out

func _shadow_matches_ray() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var bad := 0
	for trial in 300:
		var gw := rng.randi_range(1, 34)
		var gh := rng.randi_range(1, 26)
		var blk := PackedByteArray()
		blk.resize(gw * gh)
		var density := rng.randf_range(0.0, 0.25) if trial % 5 != 0 else 0.6
		for i in gw * gh:
			if rng.randf() < density:
				blk[i] = 1
		var ux := rng.randi_range(0, gw - 1)
		var uy := rng.randi_range(0, gh - 1)
		blk[uy * gw + ux] = 0   # an eye inside a cloud is handled before any sweep
		var blockers := PackedInt32Array()
		for i in gw * gh:
			if blk[i] != 0:
				blockers.append(i)
		var got := GameActionResolver._sweep_hidden(ux, uy, blk, gw, gh,
				GameActionResolver._transpose(blk, gw, gh), blockers)
		got.sort()
		var want := _ray_hidden(ux, uy, blk, gw, gh)
		want.sort()
		if got != want:
			bad += 1
			if bad <= 3:
				fails.append("shadow %dx%d from (%d,%d): %d cells, ray says %d" % [gw, gh, ux, uy, got.size(), want.size()])
	ck(bad == 0, "every shadow equals the ray (%d of 300 differ)" % bad)

## The side's view the way the per-soldier path built it before mode 2 got its own path.
func _per_soldier(r: GameActionResolver, side: int) -> Dictionary:
	var st := r.state
	var grid := st.grid
	var gw := grid.width
	var full_r := maxi(gw, grid.height)
	var masks: Array = r._gas_masks()
	var eyes: Array = []
	var sides := r._vision_sides(side)
	for u in st.all_units():
		if u.is_alive() and sides.has(u.owner) and u.aboard_vehicle_id == -1:
			eyes.append([u.coord, mini(r.sight_of(u), full_r)])
	for veh: Vehicle in st.all_vehicles():
		if not veh.wrecked and sides.has(veh.owner) and not veh.occupants.is_empty():
			for c: Vector2i in veh.footprint():
				eyes.append([c, full_r])
	var out := {}
	for e: Array in eyes:
		var c: Vector2i = e[0]
		if not grid.in_bounds(c):
			continue
		if grid.cell(c).obscured():
			out[c] = true
			continue
		for i: int in GameActionResolver._sweep(c.x, c.y, e[1], masks[0], gw, grid.height, masks[1])[0]:
			var q := Vector2i(i % gw, i / gw)
			if q == c or not grid.cell(q).obscured():
				out[q] = true
	return out

func _team_matches_per_soldier() -> void:
	var m := MapGen.generate({"style": MapGen.Style.TOWN, "size": 0, "seed": 31, "civilians": 2})
	var squad := ["light_infantry", "heavy_infantry", "sniper", "drone_operator", "machinegunner", "engineer"]
	for side in [0, 1]:
		var cells := m.zone_cells(side)
		for k in squad.size():
			m.set_spawn(cells[(k * 7) % cells.size()], squad[k], side)
	var st := m.build_state(9)
	for c: Vector2i in m.zone_cells(0):
		var free := true
		for dy in 3:
			for dx in 3:
				var cc := st.grid.cell(c + Vector2i(dx, dy))
				free = free and cc != null and cc.is_empty() and not cc.is_space \
						and cc.vehicle_id == -1 and cc.feature_id == ""
		if free:
			st.spawn_vehicle("tank", c, 0)
			break
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.update_airlocks()
	r.play_civilian_slots()
	var brains := {}
	for side in [0, 1]:
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.intent_ready.connect(func(i: Intent) -> void: _pending = i)
		brains[side] = ai
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var gw := st.grid.width
	var clouds: Array = []   # [cells, kind]
	var seen_ever := {0: {}, 1: {}}
	var before := {0: {}, 1: {}}
	for s in [0, 1]:
		r.take_vis_changes(s)   # start the change log
	var bad := 0
	var bad_fresh := 0
	var bad_mem := 0
	var bad_log := 0
	var limited_steps := 0
	var inside := 0
	for step in 140:
		# Clouds come and go: a gas or smoke patch every few actions, the oldest lifts.
		if step % 6 == 0:
			var w := rng.randi_range(1, 6)
			var h := rng.randi_range(1, 6)
			var at := Vector2i(rng.randi_range(0, gw - w), rng.randi_range(0, st.grid.height - h))
			var cells: Array = []
			var smoke := rng.randf() < 0.4
			for y in h:
				for x in w:
					var cell := st.grid.cell(at + Vector2i(x, y))
					if smoke: cell.smoke = true
					else: cell.gas = true
					cells.append(cell)
			clouds.append([cells, smoke])
		if clouds.size() > 3 or (step % 23 == 22 and not clouds.is_empty()):
			var gone: Array = clouds.pop_front()
			for cell: GridCell in gone[0]:
				if gone[1]: cell.smoke = false
				else: cell.gas = false
		var side: int = st.active_player()
		if brains.has(side):
			_pending = null
			brains[side].begin_turn(st)
			r.resolve(_pending if _pending != null else EndTurnIntent.new())
		else:
			r.resolve(EndTurnIntent.new())
		if not r.visibility_limited():
			continue
		limited_steps += 1
		for s2 in [0, 1]:
			var want := _per_soldier(r, s2)
			var got: Dictionary = r.team_visible_coords(s2)
			if got.size() != want.size() or not want.keys().all(func(c): return got.has(c)):
				bad += 1
				if bad <= 3:
					fails.append("step %d side %d: %d visible, per-soldier union %d" % [step, s2, got.size(), want.size()])
			var fresh := GameActionResolver.new(st)
			fresh.fog_mode = MCF.Fog.OFF
			var got2: Dictionary = fresh.team_visible_coords(s2)
			if got2.size() != want.size() or not want.keys().all(func(c): return got2.has(c)):
				bad_fresh += 1
			seen_ever[s2].merge(want)
			var mem: Dictionary = r.explored.get(s2, {})
			if not seen_ever[s2].keys().all(func(c): return mem.has(c)):
				bad_mem += 1
			var log: Variant = r.take_vis_changes(s2)
			if log != null:
				var named := {}
				for i: int in log:
					named[Vector2i(i % gw, i / gw)] = true
				var prev: Dictionary = before[s2]
				for c: Vector2i in want:
					if not prev.has(c) and not named.has(c): bad_log += 1
				for c: Vector2i in prev:
					if not want.has(c) and not named.has(c): bad_log += 1
			before[s2] = want.duplicate()
			for u in st.all_units():
				if u.is_alive() and u.owner == s2 and u.aboard_vehicle_id == -1 \
						and st.grid.in_bounds(u.coord) and st.grid.cell(u.coord).obscured():
					inside += 1
	ck(limited_steps > 60, "clouds were on the board for most of the game (%d steps)" % limited_steps)
	ck(inside > 0, "someone stood inside a cloud at least once (%d)" % inside)
	ck(bad == 0, "the long-lived view equals the per-soldier union after every action (%d differ)" % bad)
	ck(bad_fresh == 0, "a fresh resolver's view equals it too (%d differ)" % bad_fresh)
	ck(bad_mem == 0, "explored memory covers everything seen (%d short)" % bad_mem)
	ck(bad_log == 0, "the change log names every cell that flipped (%d missed)" % bad_log)
	for cl: Array in clouds:
		for cell: GridCell in cl[0]:
			cell.gas = false
			cell.smoke = false

## Eyes join, leave and swap on a small board with two clouds, the view checked after each
## change: a cell hidden from every remaining eye must turn hidden when the one eye that saw
## it falls, though that eye's shadow never held it.
func _eyes_come_and_go() -> void:
	var st := GameState.new(24, 14)
	st.roster = Roster.default_duel(false)
	var stats: UnitStats = load("res://src/data/units/light_infantry.tres")
	var gassed: Array = []
	for at in [Vector2i(11, 4), Vector2i(5, 10)]:
		for y in 3:
			for x in 2:
				var cell := st.grid.cell(at + Vector2i(x, y))
				cell.gas = true
				gassed.append(cell)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var squad: Array[UnitInstance] = []
	var bad := 0
	var fell := 0
	for step in 120:
		var roll := rng.randi_range(0, 9)
		var alive := squad.filter(func(u: UnitInstance) -> bool: return u.is_alive())
		if roll < 3 or alive.size() < 2:
			var c := Vector2i(rng.randi_range(0, 23), rng.randi_range(0, 13))
			if st.grid.cell(c).occupant == null and st.grid.cell(c).corpse_count == 0:
				var u := st.spawn_unit(stats, c, 0)
				if u != null: squad.append(u)
		elif roll < 6:
			var u: UnitInstance = alive[rng.randi_range(0, alive.size() - 1)]
			u.status = MCF.Status.CORPSE
			st.grid.cell(u.coord).occupant = null
			fell += 1
		else:
			var u: UnitInstance = alive[rng.randi_range(0, alive.size() - 1)]
			var c := Vector2i(rng.randi_range(0, 23), rng.randi_range(0, 13))
			if st.grid.cell(c).occupant == null and st.grid.cell(c).corpse_count == 0:
				st.grid.move_occupant(u.coord, c)
		var want := _per_soldier(r, 0)
		var got: Dictionary = r.team_visible_coords(0)
		if got.size() != want.size() or not want.keys().all(func(c): return got.has(c)):
			bad += 1
	ck(fell > 20, "soldiers fell during the shuffle (%d)" % fell)
	ck(bad == 0, "the view follows eyes joining, leaving and moving (%d differ)" % bad)
	for cell: GridCell in gassed:
		cell.gas = false

func _big_board_is_fast() -> void:
	var st := GameState.new(250, 250)
	st.roster = Roster.default_duel(false)
	var stats: UnitStats = load("res://src/data/units/light_infantry.tres")
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var mine: Array[UnitInstance] = []
	for k in 150:
		mine.append(st.spawn_unit(stats, Vector2i(rng.randi_range(0, 249), rng.randi_range(0, 249)), 0))
	for k in 20:
		st.spawn_unit(stats, Vector2i(rng.randi_range(0, 249), rng.randi_range(0, 249)), 1)
	var gassed: Array = []
	for cloud in [Vector2i(60, 70), Vector2i(150, 120), Vector2i(200, 40)]:
		for y in 8:
			for x in 10:
				var cell := st.grid.cell(cloud + Vector2i(x, y))
				cell.gas = true
				gassed.append(cell)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	var t := Time.get_ticks_usec()
	var vis: Dictionary = r.team_visible_coords(0)
	var first_ms := (Time.get_ticks_usec() - t) / 1000.0
	var walker: UnitInstance = null
	for u in mine:
		if u != null and not st.grid.cell(u.coord).obscured() and st.grid.in_bounds(u.coord + Vector2i(1, 0)) and st.grid.cell(u.coord + Vector2i(1, 0)).is_empty():
			walker = u
			break
	t = Time.get_ticks_usec()
	st.grid.move_occupant(walker.coord, walker.coord + Vector2i(1, 0))
	r.team_visible_coords(0)
	var move_ms := (Time.get_ticks_usec() - t) / 1000.0
	print("gas vision 250x250, 150 eyes, 3 clouds: first view %.0f ms (%d cells), one move %.1f ms" % [first_ms, vis.size(), move_ms])
	ck(vis.size() > 60000, "almost the whole board is visible (%d)" % vis.size())
	ck(first_ms < BIG_FIRST_MS, "first view on 250×250 under %.0f ms (%.0f)" % [BIG_FIRST_MS, first_ms])
	ck(move_ms < BIG_MOVE_MS, "one soldier's move under %.0f ms (%.1f)" % [BIG_MOVE_MS, move_ms])
	for cell: GridCell in gassed:
		cell.gas = false
