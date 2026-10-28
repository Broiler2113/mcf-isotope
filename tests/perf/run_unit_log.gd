extends "res://tests/SuiteBase.gd"

## What reads UnitInstance.vision_log instead of the whole army must equal a whole-army pass:
##   • GameState.unit_xy() == every unit's coord, in all_units() order;
##   • team fog (ResolverVision.team_visible_coords, which looks only at logged units) == the
##     same question asked of a second resolver on the same board whose per-soldier pass is
##     forced whole every time;
##   • the wake-up check's kept input (ResolverWorld._sync_wake_rows) == what the whole-army
##     pass collected: each unit's kind and the cells a living unit holds;
##   • hostile_target_ids / capturable_target_ids == the whole-army scans they replaced;
##   • alive_rows, captives(), tracked_bodies() and each action's visual_deaths == a whole pass;
##   • no sleeper the wake-up check left unasked (nothing on its lines changed) sees a soldier.
## Steps mix AI decisions, random legal intents, undo/redo (a restore: a new unit list), side
## swaps and spawns (cheats do both), on town and station maps with civilians, tanks, shuttles
## and drones; now and then a cell's occupant is lifted with no unit logged (the walk log path).

const SQUAD := ["light_infantry", "engineer", "flamethrower", "miner", "sapper",
		"drone_operator", "anti_tank", "heavy_infantry", "machinegunner", "shield_bearer", "marksman"]
const STEPS := 220

var _pending: Intent = null
var _n := {"steps": 0, "fog": 0, "partial": 0, "wake": 0, "targets": 0, "pokes": 0,
		"deaths": 0, "captives": 0, "bodies": 0, "quiet": 0}

func run() -> void:
	for style: int in [MapGen.Style.TOWN, MapGen.Style.STATION]:
		for seed_value: int in [11, 12, 15]:
			_play(style, seed_value)
	print("unit log: %d steps, %d fog checks (%d on the unit list of the last pass), %d wake-up rows, %d target lists, %d occupant pokes, %d deaths, %d captive and %d body rows, %d unasked sleepers re-checked" % [
			_n["steps"], _n["fog"], _n["partial"], _n["wake"], _n["targets"], _n["pokes"],
			_n["deaths"], _n["captives"], _n["bodies"], _n["quiet"]])

func _play(style: int, seed_value: int) -> void:
	GameConfig.random_events_enabled = false   # a wave landing after the check is seen next action
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 14
	var m := MapGen.generate({"style": style, "size": 1, "seed": seed_value, "civilians": 6})
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var cells := m.zone_cells(side)
		for k in SQUAD.size():
			m.set_spawn(cells[(k * 7) % cells.size()], SQUAD[k], side)
	var st := m.build_state(seed_value)
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		for type: String in ["tank", "shuttle"]:
			for c: Vector2i in m.zone_cells(side):
				if st.spawn_vehicle(type, c, side) != null:
					break
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	r.update_airlocks()
	r.play_civilian_slots()
	var ref := GameActionResolver.new(st)
	ref.fog_mode = MCF.Fog.STANDARD
	var tag := "%s seed %d" % [MapGen.STYLE_NAMES[style], seed_value]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var brains := {}
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.intent_ready.connect(func(i: Intent) -> void: _pending = i)
		brains[side] = ai
	for step in STEPS:
		var side: int = st.active_player()
		if not brains.has(side):
			break
		var roll := rng.randf()
		var what := ""
		if r.can_undo() and roll < 0.12:
			what = "undo"
			r.resolve(UndoIntent.new(side))
		elif r.can_redo() and roll < 0.2:
			what = "redo"
			r.resolve(RedoIntent.new(side))
		elif roll < 0.24:
			# A cheat's side swap: no move, no death, only the owner setter.
			var u: UnitInstance = st.all_units()[rng.randi_range(0, st.all_units().size() - 1)]
			if u.is_alive() and MCF.is_player(u.owner):
				what = "side swap"
				u.owner = MCF.Owner.PLAYER_2 if u.owner == MCF.Owner.PLAYER_1 else MCF.Owner.PLAYER_1
		elif roll < 0.26:
			var at := Vector2i(rng.randi_range(0, st.grid.width - 1), rng.randi_range(0, st.grid.height - 1))
			if st.grid.cell(at).is_empty() and not st.grid.cell(at).is_space:
				what = "spawn"
				st.spawn_unit(load("res://src/data/units/light_infantry.tres"), at, side)
		if what == "":
			var intent: Intent = null
			if rng.randf() < 0.5:
				_pending = null
				brains[side].begin_turn(st)
				intent = _pending
			if intent == null:
				var legal: Array = r.legal_intents(side)
				intent = legal[rng.randi_range(0, legal.size() - 1)]
			what = intent.get_script().resource_path.get_file().get_basename()
			var was := {}
			for u: UnitInstance in st.all_units():
				if u.is_alive(): was[u.id] = true
			var res := r.resolve(intent)
			if not res.ok:
				brains[side].notify_intent_denied(st)
			else:
				var fell: Array[int] = []
				for u: UnitInstance in st.all_units():
					if was.has(u.id) and not u.is_alive(): fell.append(u.id)
				ck(res.visual_deaths == fell, "%s step %d after %s: visual deaths %s, a whole pass %s" % [
						tag, step, what, res.visual_deaths, fell])
				_n["deaths"] += fell.size()
				var missed := _quiet_but_seeing(st, r)
				ck(missed.is_empty(), "%s step %d after %s: sleepers %s were not asked but see a soldier" % [
						tag, step, what, missed])
		_n["steps"] += 1
		var why := _check(st, r, ref)
		if why == "" and step % 9 == 0:
			# A cell losing its living occupant with no unit logged (only GridCell's walk log
			# says so), checked, then given back.
			var u: UnitInstance = st.all_units()[rng.randi_range(0, st.all_units().size() - 1)]
			var cell := st.grid.cell(u.coord) if st.grid.in_bounds(u.coord) else null
			if u.is_alive() and cell != null and cell.occupant == u:
				cell.occupant = null
				why = _check(st, r, ref)
				cell.occupant = u
				_n["pokes"] += 1
		if why != "":
			ck(false, "%s step %d after %s: %s" % [tag, step, what, why])
			return

func _check(st: GameState, r: GameActionResolver, ref: GameActionResolver) -> String:
	var units := st.all_units()
	var xy := PackedInt32Array()
	for u: UnitInstance in units:
		xy.append_array([u.coord.x, u.coord.y])
	if st.unit_xy() != xy:
		return "unit_xy differs from the units' coords"
	var alive := PackedByteArray()
	var captives: Array = []
	var bodies: Array = []
	for u: UnitInstance in units:
		alive.append(1 if u.is_alive() else 0)
		if u.captor_id != -1: captives.append(u)
		if u.corpse_stacked or u.corpse_carrier_id >= 0: bodies.append(u)
	if st.alive_rows() != alive:
		return "alive_rows differs from the units' statuses"
	if st.captives() != captives:
		return "captives() differs from a whole pass"
	if st.tracked_bodies() != bodies:
		return "tracked_bodies() differs from a whole pass"
	_n["captives"] += captives.size()
	_n["bodies"] += bodies.size()
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var partial: bool = is_same(r._vis_units_of.get(side), units) \
				and int(r._vis_pos.get(side, -1)) >= UnitInstance.vision_log_start
		var got := (r.team_visible_coords(side) as Dictionary).keys()
		ref._vis_world.clear()   # since = -1: the whole army, every time
		var want := (ref.team_visible_coords(side) as Dictionary).keys()
		got.sort()
		want.sort()
		if got != want:
			return "side %d sees %d cells, a whole pass %d" % [side, got.size(), want.size()]
		_n["fog"] += 1
		if partial:
			_n["partial"] += 1
	r._sync_wake_rows()
	var gw := st.grid.width
	var gh := st.grid.height
	var occ := {}
	for i in units.size():
		var u: UnitInstance = units[i]
		var c := u.coord
		var on_board := c.x >= 0 and c.y >= 0 and c.x < gw and c.y < gh
		var kind := 0
		if u.status == MCF.Status.ALIVE:
			if MCF.is_player(u.owner):
				kind = 1 if not u.is_drone and on_board else 0
			elif MCF.is_neutral(u.owner) and u.neutral_group == 0:
				kind = 2
			if on_board and st.grid.cell(c).occupant == u:
				occ[c.y * gw + c.x] = true
		if r._wa_kind[i] != kind:
			return "wake-up kind of unit %d is %d, a whole pass %d" % [u.id, r._wa_kind[i], kind]
		_n["wake"] += 1
	var kept: Array = r._wa_occ.keys()
	var full: Array = occ.keys()
	kept.sort()
	full.sort()
	if kept != full:
		return "wake-up occupied cells: %d kept, %d by a whole pass" % [kept.size(), full.size()]
	for u: UnitInstance in units:
		if r.hostile_target_ids(u) != _hostile_whole(r, u):
			return "hostile_target_ids of unit %d" % u.id
		if r.capturable_target_ids(u) != _capturable_whole(st, u):
			return "capturable_target_ids of unit %d" % u.id
		_n["targets"] += 1
	return ""

## The sleepers the last wake-up check did not ask again (ResolverWorld._wq_quiet: they saw no
## one and nothing on their lines changed) that a whole check, built from scratch, says see a
## soldier or a hull. Right after an action's check that must be none.
func _quiet_but_seeing(st: GameState, r: GameActionResolver) -> Array:
	var scorer := r._native_wake_scorer()
	if scorer == null:
		return []
	var gw := st.grid.width
	var targets := PackedInt32Array()
	var occupied := PackedInt32Array()
	var quiet: Array = []
	var xy := PackedInt32Array()
	for u: UnitInstance in st.all_units():
		if not u.is_alive():
			continue
		var on_board := st.grid.in_bounds(u.coord)
		if on_board and st.grid.cell(u.coord).occupant == u:
			occupied.append(u.coord.y * gw + u.coord.x)
		if MCF.is_player(u.owner) and not u.is_drone and on_board:
			targets.append_array([u.coord.x, u.coord.y])
		elif MCF.is_neutral(u.owner) and u.neutral_group == 0 and r._wq_quiet.has(u.id):
			quiet.append(u.id)
			xy.append_array([u.coord.x, u.coord.y])
	for veh: Vehicle in st.all_vehicles():
		if veh.alive() and not MCF.is_neutral(veh.owner):
			for fc: Vector2i in veh.footprint():
				targets.append_array([fc.x, fc.y])
	if quiet.is_empty() or targets.is_empty():
		return []
	_n["quiet"] += quiet.size()
	var sees: PackedByteArray = scorer.civilians_seeing(xy, targets, occupied)
	var out: Array = []
	for i in quiet.size():
		if sees[i] != 0: out.append(quiet[i])
	return out

## The scans as they were before unit_xy.
func _hostile_whole(r: GameActionResolver, shooter: UnitInstance) -> Array:
	var out: Array = []
	var from := shooter.coord
	for u: UnitInstance in r.state.all_units():
		var dx: int = u.coord.x - from.x
		var dy: int = u.coord.y - from.y
		if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
			continue
		if u.id == shooter.id or not u.is_on_field() or r.is_ally_of(shooter, u):
			continue
		if not r.state.grid.in_bounds(u.coord) or not Combat.is_on_firing_line(from, u.coord):
			continue
		if r.can_shoot(shooter, u) == "":
			out.append(u.id)
	return out

func _capturable_whole(st: GameState, actor: UnitInstance) -> Array:
	var out: Array = []
	for u: UnitInstance in st.all_units():
		var dx := absi(u.coord.x - actor.coord.x)
		var dy := absi(u.coord.y - actor.coord.y)
		if dx > 1 or dy > 1 or (dx == 0 and dy == 0):
			continue
		if u.id == actor.id or u.captor_id != -1 or u.aboard_vehicle_id != -1:
			continue
		if u.is_alive():
			out.append(u.id)
	return out
