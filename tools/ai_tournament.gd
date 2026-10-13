extends SceneTree
## AI personality tournament (0.12). Plays HARD-vs-HARD matches between personalities on
## generated maps with the same random army on both sides, swaps sides, and prints win
## rates plus what each personality actually DID: how fast it closed in, how much of its
## army stood in cover, and how often it used every kind of action. The action table is
## also the ability audit — anything that stays at zero is something the AI never does.
##
## A measuring tool, not a test. Run it before and after changing the AI and compare.
##   godot --headless --script res://tools/ai_tournament.gd -- [--games N] [--rounds R]
##       [--seed S] [--styles 0,1,2] [--sizes 0,1] [--units 8-16] [--out file.json]

const ArmyBuilder := preload("res://rl/ArmyBuilder.gd")
const NAMES := {0: "Tactician", 1: "Aggressor", 2: "Fortifier", 3: "Flank(legacy)"}
## A match that runs to the round cap is decided on army value, as the RL env does: a lead
## worth more than this share of one starting army wins, anything closer is a draw.
const VALUE_LEAD := 0.1

var _pending: Intent = null
var _why := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var games := int(_arg(args, "--games", "2"))
	var rounds := int(_arg(args, "--rounds", "12"))
	var seed0 := int(_arg(args, "--seed", "1"))
	var styles: Array = Array(_arg(args, "--styles", "0,1,2").split(",")).map(func(s: String) -> int: return int(s))
	var sizes: Array = Array(_arg(args, "--sizes", "0,1").split(",")).map(func(s: String) -> int: return int(s))
	var units_s := _arg(args, "--units", "8-16")
	var out_path := _arg(args, "--out", "")
	_why = "--why" in args
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var pairs: Array = []
	for a in styles.size():
		for b in range(a, styles.size()):
			pairs.append([styles[a], styles[b]])
	var table := {}   # "A vs B" -> {w, l, d}
	var behaviour := {}   # style -> accumulated metrics
	var t_start := Time.get_ticks_msec()
	var match_no := 0
	for g in games:
		for size: int in sizes:
			var map_seed := seed0 * 1000 + g * 10 + size
			for pair: Array in pairs:
				# Both orders on the same map and army: whoever starts first, or stands on
				# the better half of the map, does it for both personalities once.
				for swap in 2:
					var a: int = pair[swap]
					var b: int = pair[1 - swap]
					match_no += 1
					var res := _play(map_seed, size, units_s, rounds, a, b)
					if res.is_empty():
						print("  map %d size %d: no map" % [map_seed, size])
						continue
					var key := "%s vs %s" % [NAMES[pair[0]], NAMES[pair[1]]]
					var row: Dictionary = table.get(key, {"w": 0, "l": 0, "d": 0, "games": 0})
					var winner: int = res["winner"]   # 0 = side A, 1 = side B, -1 draw
					var a_is_first := swap == 0
					row["games"] += 1
					if winner == -1:
						row["d"] += 1
					elif (winner == 0) == a_is_first:
						row["w"] += 1
					else:
						row["l"] += 1
					table[key] = row
					for side in 2:
						var st: int = a if side == 0 else b
						_accumulate(behaviour, st, res["sides"][side])
					print("  #%d %s(A) vs %s(B) map %d/%d: %s in %d rounds, kills %d-%d, %.1fs" % [
						match_no, NAMES[a], NAMES[b], map_seed, size,
						"draw" if winner == -1 else ("A" if winner == 0 else "B") + " wins (" + str(res["by"]) + ")",
						res["rounds"], res["sides"][0]["kills"], res["sides"][1]["kills"],
						float(res["ms"]) / 1000.0])
	print("\n== Results (row personality's record against the column) ==")
	for key: String in table:
		var r: Dictionary = table[key]
		print("%-28s  games %3d   W %3d  L %3d  D %3d" % [key, r["games"], r["w"], r["l"], r["d"]])
	print("\n== Behaviour per personality (per side-match averages) ==")
	for st: int in behaviour:
		var m: Dictionary = behaviour[st]
		var n := float(maxi(1, int(m["matches"])))
		print("%s  (%d side-matches)" % [NAMES[st], int(m["matches"])])
		print("   kills %.1f  losses %.1f (own fault %.2f)  K/L %.2f  rounds %.1f  enemy-distance %.1f  safe %.0f%%  decide %.0f ms/action" % [
			m["kills"] / n, m["losses"] / n, m["self_kills"] / n, m["kills"] / maxf(1.0, m["losses"]),
			m["rounds"] / n, m["dist"] / n,
			100.0 * m["cover"] / n, m["think_ms"] / maxf(1.0, m["actions_total"])])
		var dk: Array = (m["deaths_by"] as Dictionary).keys()
		dk.sort()
		var dparts: PackedStringArray = []
		for k: String in dk:
			dparts.append("%s %.1f" % [k, float(m["deaths_by"][k]) / n])
		print("   deaths by: " + ", ".join(dparts))
		var kinds: Array = (m["actions"] as Dictionary).keys()
		kinds.sort()
		var parts: PackedStringArray = []
		for k: String in kinds:
			parts.append("%s %.1f" % [k, float(m["actions"][k]) / n])
		print("   actions/match: " + ", ".join(parts))
	print("\n%d matches in %.0f s" % [match_no, float(Time.get_ticks_msec() - t_start) / 1000.0])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"table": table, "behaviour": behaviour}, "  "))
	quit()

func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else default

func _accumulate(acc: Dictionary, st: int, side: Dictionary) -> void:
	var m: Dictionary = acc.get(st, {"matches": 0, "kills": 0.0, "losses": 0.0, "rounds": 0.0,
			"dist": 0.0, "cover": 0.0, "think_ms": 0.0, "actions_total": 0.0, "actions": {},
			"deaths_by": {}, "self_kills": 0.0})
	m["matches"] += 1
	for k in ["kills", "losses", "rounds", "dist", "cover", "think_ms", "actions_total", "self_kills"]:
		m[k] += float(side[k])
	for k: String in side["actions"]:
		m["actions"][k] = float(m["actions"].get(k, 0.0)) + float(side["actions"][k])
	for k: String in side["deaths_by"]:
		m["deaths_by"][k] = float(m["deaths_by"].get(k, 0.0)) + float(side["deaths_by"][k])
	acc[st] = m

## One match. Side A is PLAYER_1 with personality a, side B is PLAYER_2 with b.
func _play(map_seed: int, size: int, units_s: String, rounds: int, a: int, b: int) -> Dictionary:
	var arng := RandomNumberGenerator.new()
	arng.seed = map_seed
	var units := _range(units_s, arng)
	var m: MapData = null
	for attempt in 6:
		var style := arng.randi_range(0, MapGen.STYLE_NAMES.size() - 1)
		var dim: Vector2i = MapGen.SIZES[size]
		var opts := {"style": style, "size": MapGen.SIZE_CUSTOM, "width": dim.x, "height": dim.y,
				"density": arng.randi_range(0, 2), "seed": arng.randi_range(1, MapGen.SEED_MAX),
				"zones": 2, "units": units + 12, "symmetric": arng.randf() < 0.5,
				"civilians": 0, "civilian_count": 0}
		m = MapGen.generate(opts)
		if m != null and ArmyBuilder.populate(m, arng, units, 1 if size >= 1 else 0):
			break
		m = null
	if m == null:
		return {}
	var st := m.build_state(map_seed * 7919)
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		st.roster.slot(side).kind = Roster.SlotKind.AI
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	r.random_events = RandomEvents.new(false)
	r.update_airlocks()
	_crew(st, r)
	r.open_match()
	var brains := {}
	var styles := {MCF.Owner.PLAYER_1: a, MCF.Owner.PLAYER_2: b}
	for side: int in styles:
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.style = styles[side]
		ai.bind_match(r)
		ai.intent_ready.connect(func(it: Intent) -> void: _pending = it)
		brains[side] = ai
	var start_value := {}
	var start_units := {}
	for side: int in styles:
		start_value[side] = _army_value(st, side)
		start_units[side] = _alive(st, side)
	var metrics := {}
	for side: int in styles:
		metrics[side] = {"kills": 0, "losses": 0, "rounds": 0, "dist": 0.0, "cover": 0.0,
				"think_ms": 0.0, "actions_total": 0, "actions": {}, "_turns": 0,
				"deaths_by": {}, "self_kills": 0}
	var t0 := Time.get_ticks_msec()
	var actions := 0
	var last_side := -1
	var winner := -2
	var by := ""
	while actions < 30000:
		var side: int = st.active_player()
		var ai: AIController = brains.get(side)
		if ai == null:
			r.resolve(EndTurnIntent.new())
			continue
		if side != last_side:
			last_side = side
			_sample_turn(st, r, side, metrics[side])
		_pending = null
		var tt := Time.get_ticks_usec()
		ai.begin_turn(st)
		metrics[side]["think_ms"] += float(Time.get_ticks_usec() - tt) / 1000.0
		var it: Intent = _pending if _pending != null else EndTurnIntent.new()
		var alive_before := {}
		for u: UnitInstance in st.all_units():
			if u.is_alive() and not u.is_drone:
				alive_before[u.id] = u.owner
		var res := r.resolve(it)
		# Кто и чем погиб: по намерению, после которого боец перестал быть живым.
		var killer := _kind(it, st)
		for id: int in alive_before:
			var dead := st.get_unit(id)
			if dead != null and dead.is_alive():
				continue
			var victim_side: int = alive_before[id]
			if not metrics.has(victim_side):
				continue
			var vm: Dictionary = metrics[victim_side]
			var tag := ("own " if victim_side == side else "") + killer
			vm["deaths_by"][tag] = int(vm["deaths_by"].get(tag, 0)) + 1
			if victim_side == side:
				vm["self_kills"] += 1
				if _why:
					var actor_id: int = int(it.get("actor_id")) if "actor_id" in it else -1
					var actor := st.get_unit(actor_id)
					var ctx := ""
					if dead != null and it is EndTurnIntent:
						var fires := 0
						for dy in range(-2, 3):
							for dx in range(-2, 3):
								var fc := st.grid.cell(dead.coord + Vector2i(dx, dy))
								if fc != null and fc.on_fire:
									fires += 1
						ctx = " [at %s burnt=%s fire-nearby=%d captor=%d held=%s]" % [
							dead.coord, dead.burnt, fires, dead.captor_id, dead.is_held()]
					print("    OWN LOSS r%d %s by %s (%s)%s: %s" % [st.turns.round_number,
						dead.stats.id if dead != null else "?", killer,
						actor.stats.id if actor != null else "-", ctx, " | ".join(res.log_lines)])
		actions += 1
		metrics[side]["actions_total"] += 1
		if res.ok:
			var k := _kind(it, st)
			metrics[side]["actions"][k] = int(metrics[side]["actions"].get(k, 0)) + 1
		else:
			ai.notify_intent_denied(st)
		var p1 := _alive(st, MCF.Owner.PLAYER_1)
		var p2 := _alive(st, MCF.Owner.PLAYER_2)
		if p1 == 0 or p2 == 0:
			winner = -1 if p1 == p2 else (0 if p2 == 0 else 1)
			by = "rout"
			break
		if st.turns.round_number > rounds:
			var lead := (_army_value(st, MCF.Owner.PLAYER_1) - _army_value(st, MCF.Owner.PLAYER_2)) \
					/ maxf(1.0, float(start_value[MCF.Owner.PLAYER_1]))
			winner = 0 if lead > VALUE_LEAD else (1 if lead < -VALUE_LEAD else -1)
			by = "value"
			break
	var out_sides: Array = []
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var other := MCF.Owner.PLAYER_2 if side == MCF.Owner.PLAYER_1 else MCF.Owner.PLAYER_1
		var mm: Dictionary = metrics[side]
		mm["losses"] = int(start_units[side]) - _alive(st, side)
		mm["kills"] = int(start_units[other]) - _alive(st, other)
		mm["rounds"] = st.turns.round_number
		var turns := float(maxi(1, int(mm["_turns"])))
		mm["dist"] = float(mm["dist"]) / turns
		mm["cover"] = float(mm["cover"]) / turns
		out_sides.append(mm)
	return {"winner": winner, "by": by, "rounds": st.turns.round_number, "sides": out_sides,
			"ms": Time.get_ticks_msec() - t0}

## At the start of each own turn: how far the army stands from the enemy, and how much of
## it is in cover. Averaged over the match these say "closes in fast" / "digs in".
func _sample_turn(st: GameState, r: GameActionResolver, side: int, mm: Dictionary) -> void:
	var mine: Array = []
	var theirs: Array = []
	for u: UnitInstance in st.all_units():
		if not u.is_alive() or u.is_drone or not st.grid.in_bounds(u.coord):
			continue
		if u.owner == side:
			mine.append(u)
		elif MCF.is_player(u.owner):
			theirs.append(u)
	if mine.is_empty() or theirs.is_empty():
		return
	var dist := 0.0
	var covered := 0
	for u: UnitInstance in mine:
		var best := 1 << 20
		for e: UnitInstance in theirs:
			best = mini(best, Combat.distance(u.coord, e.coord))
		dist += float(best)
		if _safe(st, r, u, theirs):
			covered += 1
	mm["dist"] += dist / float(mine.size())
	mm["cover"] += float(covered) / float(mine.size())
	mm["_turns"] += 1

## Никто из врагов прямо сейчас не может в бойца попасть: не на прямой, линия закрыта, окоп
## (с дистанции), или укрытие рядом по направлению на стрелка делает попадание невозможным.
func _safe(st: GameState, r: GameActionResolver, u: UnitInstance, enemies: Array) -> bool:
	for e: UnitInstance in enemies:
		if e.is_drone or not Combat.is_on_firing_line(e.coord, u.coord):
			continue
		var d := Combat.distance(e.coord, u.coord)
		var marksman := e.stats.special_ability_id == MCF.ABILITY_MARKSMAN
		var need := 3 if marksman else Combat.hit_number(d, e.fire_range())
		if need >= 7:
			continue
		if r.trench_protected(e.coord, u, marksman):
			continue
		if not marksman and r.los_blocked(e.coord, u.coord, true, true):
			continue
		if not marksman:
			need += int(r.cover_effect_from(e.coord, u)["hit_penalty"])
		if need < 7:
			return false
	return true

func _kind(it: Intent, st: GameState) -> String:
	var n: String = it.get_script().get_global_name()
	if it is UseItemIntent:
		var u := st.get_unit((it as UseItemIntent).actor_id)
		# The item is already spent (held_item_id cleared) — name what was thrown by what
		# the unit started with.
		return "UseItem:" + (u.stats.default_item_id if u != null else "?")
	if it is ShootIntent and (it as ShootIntent).target_cell != Vector2i(-999, -999):
		return "ShootCell"
	return n.trim_suffix("Intent")

func _alive(st: GameState, side: int) -> int:
	var n := 0
	for u: UnitInstance in st.all_units():
		if u.owner == side and u.is_alive() and not u.is_drone:
			n += 1
	return n

func _army_value(st: GameState, side: int) -> float:
	var v := 0.0
	for u: UnitInstance in st.all_units():
		if u.owner == side and u.is_alive() and not u.is_drone:
			v += float(u.stats.cost)
	for veh: Vehicle in st.all_vehicles():
		if veh.owner == side and veh.alive():
			v += float(VehicleDB.get_vehicle(veh.type_id).get("cost", 0))
	return v

func _range(s: String, rng: RandomNumberGenerator) -> int:
	if "-" in s:
		var ab := s.split("-")
		return rng.randi_range(int(ab[0]), int(ab[1]))
	return int(s)

## Seat neighbouring infantry in every vehicle before the match, as the RL env does.
func _crew(st: GameState, r: GameActionResolver) -> void:
	var saved := st.turns.active_index
	for veh: Vehicle in st.all_vehicles():
		if not veh.alive():
			continue
		var idx := st.turns.round_order.find(veh.owner)
		if idx < 0:
			continue
		st.turns.active_index = idx
		for guard in 8:
			if veh.living_crew_count() >= veh.capacity():
				break
			var cands: Array = r.vehicle_board_candidates(veh)
			if cands.is_empty() or not r.resolve(VehicleBoardIntent.new(int(cands[0]), veh.id)).ok:
				break
	st.turns.active_index = saved
