extends SceneTree

## Учёт приращениями обязан давать то же, что пересчёт с нуля (большие карты, 250×250).
## Две одинаковые партии идут бок о бок:
##   • откат: в первой Undo/Redo идут через резолвер — журнал тронутых клеток
##     (GridCell.journal), во второй — прежним способом, полными снимками
##     state.snapshot()/restore();
##   • шлюзы: первая пересчитывает только двери-кандидаты (GameActionResolver.
##     _airlock_candidates), вторая — все двери карты на каждый вызов, как раньше.
##   • индекс объектов и горящих клеток (GameActionResolver._feature_cells_of,
##     _burning_cells_of), который правится по журналу вида клеток, совпадает с проходом по
##     карте — и составом, и порядком обхода (по нему огонь бросает кубики);
##   • ИИ: слепок проходимости рельефа (AIController._walk_mask), который правится по
##     журналу вида клеток, совпадает со свежесобранным, а геополе до врага — с полем
##     буквальной волны по grid.neighbors() и walkable_terrain().
## Ходы — вперемешку решения ИИ и случайные законные намерения (копка, стройка, мины,
## огонь, техника, будящие жителей двери), с откатами и повторами. После каждого шага
## доски сверяются целиком — каждая клетка всеми полями, — и очередь пробуждения жителей.

const SQUAD := ["light_infantry", "engineer", "flamethrower", "miner", "sapper",
		"drone_operator", "anti_tank", "heavy_infantry", "machinegunner", "shield_bearer"]
const STEPS := 260

var fails: PackedStringArray = []
var _pending: Intent = null
var _stats := {"actions": 0, "undo": 0, "redo": 0, "doors": 0, "fields": 0}

func _initialize() -> void:
	for style: int in [MapGen.Style.TOWN, MapGen.Style.STATION]:
		for seed_value: int in [5, 6]:
			_play(style, seed_value)
	if fails.is_empty():
		print("incremental: %d actions, %d undos, %d redos, %d open-door checks, %d AI field checks (%d with enemy tanks), up to %d cells ablaze — journal undo == full-copy undo, candidate doors == every door, indexes and AI fields == a fresh scan" % [
				_stats["actions"], _stats["undo"], _stats["redo"], _stats["doors"], _stats["fields"],
				int(_stats.get("vehicle fields", 0)), int(_stats.get("fire", 0))])
		quit(0)
		return
	printerr("incremental: %d failure(s)" % fails.size())
	for f in fails.slice(0, 20):
		printerr("  " + f)
	quit(1)

## Эталон шлюзов: прежний проход по всем дверям карты на каждый вызов.
class FullAirlocks extends GameActionResolver:
	func _airlock_candidates(cells: Array[GridCell]) -> Array[GridCell]:
		return cells

func _twin(m: MapData, seed_value: int, reference: bool) -> GameActionResolver:
	var st := m.build_state(seed_value)
	# По танку на сторону — корпус пишет vehicle_id по клеткам, и его тоже откатывают.
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		for c: Vector2i in m.zone_cells(side):
			if _free3(st, c):
				st.spawn_vehicle("tank", c, side)
				break
	var r: GameActionResolver = FullAirlocks.new(st) if reference else GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.update_airlocks()
	r.play_civilian_slots()
	return r

static func _free3(st: GameState, o: Vector2i) -> bool:
	for dy in 3:
		for dx in 3:
			var c := st.grid.cell(o + Vector2i(dx, dy))
			if c == null or not c.is_empty() or c.is_space or c.vehicle_id != -1 \
					or c.feature_id != "":
				return false
	return true

func _play(style: int, seed_value: int) -> void:
	var m := MapGen.generate({"style": style, "size": 1, "seed": seed_value, "civilians": 3})
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var cells := m.zone_cells(side)
		for k in SQUAD.size():
			m.set_spawn(cells[(k * 7) % cells.size()], SQUAD[k], side)
	var ra := _twin(m, seed_value, false)
	var rb := _twin(m, seed_value, true)
	var sa := ra.state
	var sb := rb.state
	var tag := "%s seed %d" % [MapGen.STYLE_NAMES[style], seed_value]
	if _full(sa) != _full(sb):
		fails.append("%s: the twins differ before the first step" % tag)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var brains := {}
	for side: int in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.intent_ready.connect(func(i: Intent) -> void: _pending = i)
		brains[side] = ai
	var b_undo: Array = []
	var b_redo: Array = []
	for step in STEPS:
		var side: int = sa.active_player()
		if not brains.has(side):
			break
		var roll := rng.randf()
		var what := ""
		if ra.can_undo() and roll < 0.3:
			what = "undo"
			ra.resolve(UndoIntent.new(side))
			b_redo.append(sb.snapshot())
			sb.restore(b_undo.pop_back())
			rb.update_airlocks()
		elif ra.can_redo() and roll < 0.55:
			what = "redo"
			ra.resolve(RedoIntent.new(side))
			b_undo.append(sb.snapshot())
			sb.restore(b_redo.pop_back())
			rb.update_airlocks()
		else:
			var intent: Intent = null
			if rng.randf() < 0.5:
				_pending = null
				brains[side].begin_turn(sa)
				intent = _pending
			if intent == null:
				var legal: Array = ra.legal_intents(side)
				intent = legal[rng.randi_range(0, legal.size() - 1)]
			what = "action %s" % intent.get_script().resource_path.get_file().get_basename()
			var copy := IntentCodec.decode(IntentCodec.encode(intent))
			var full_pre := sb.snapshot()
			var res_a := ra.resolve(intent)
			var res_b := rb.resolve(copy)
			if res_a.ok != res_b.ok:
				fails.append("%s step %d: %s — ok %s vs %s" % [tag, step, what, res_a.ok, res_b.ok])
				return
			if not res_a.ok:
				brains[side].notify_intent_denied(sa)
			# Стек второй доски повторяет стек резолвера: снимок лёг — кладём полный.
			if ra._undo_stack.size() > b_undo.size():
				b_undo.append(full_pre)
			elif ra._undo_stack.size() < b_undo.size():
				b_undo.clear()
			if ra._redo_stack.is_empty():
				b_redo.clear()
		_stats["actions" if what.begins_with("action") else what] += 1
		var fa := _full(sa)
		var fb := _full(sb)
		if fa != fb:
			fails.append("%s step %d after %s: %s" % [tag, step, what, _first_diff(fa, fb)])
			return
		if ra._activation_frontier != rb._activation_frontier:
			fails.append("%s step %d after %s: wake-up queue %s vs %s" % [tag, step, what,
					ra._activation_frontier, rb._activation_frontier])
			return
		_stats["doors"] += ra._al_open.size()
		if step % 4 == 0:
			var why := _check_ai_field(sa, ra, side)
			if why != "":
				fails.append("%s step %d after %s: %s" % [tag, step, what, why])
				return
			_stats["fields"] += 1

## Вся доска строкой: юниты, машины, КАЖДАЯ клетка всеми полями, очередь ходов.
static func _full(st: GameState) -> String:
	var snap := st.snapshot()
	var parts: PackedStringArray = []
	for key: String in ["units", "vehicles"]:
		for rec: Dictionary in snap[key]:
			var d := rec.duplicate()
			d.erase("obj")
			parts.append(str(d))
	var i := 0
	for rec: Dictionary in snap["cells"]:
		parts.append("%d %s" % [i, str(rec)])
		i += 1
	for key: String in ["units", "vehicles", "cells"]:
		snap.erase(key)
	parts.append(str(snap))
	return "\n".join(parts)

static func _first_diff(a: String, b: String) -> String:
	var la := a.split("\n")
	var lb := b.split("\n")
	for i in maxi(la.size(), lb.size()):
		var x: String = la[i] if i < la.size() else "<eof>"
		var y: String = lb[i] if i < lb.size() else "<eof>"
		if x != y:
			return "incremental: %s\n    reference:   %s" % [x, y]
	return "?"

## Слепок проходимости после правок по журналу == собранный с нуля; геополе ИИ до врага ==
## буквальная волна: источники — клетки живых немирных врагов, соседи — grid.neighbors(),
## пройти можно там, где walkable_terrain().
func _check_ai_field(st: GameState, r: GameActionResolver, side: int) -> String:
	GameActionResolver._feature_sync(st.grid)
	var scan := {}
	var fire: Array = []
	for c: GridCell in st.grid.cells_flat():
		if c.feature_id != "":
			if not scan.has(c.feature_id):
				scan[c.feature_id] = []
			scan[c.feature_id].append(c.coord)
		if c.on_fire:
			fire.append(c.coord)
	if GameActionResolver._burning != fire:
		return "burning cells: index has %d, the map %d" % [GameActionResolver._burning.size(),
				fire.size()]
	_stats["fire"] = maxi(int(_stats.get("fire", 0)), fire.size())
	for fid: String in GameActionResolver._feature_index:
		var got: Array = GameActionResolver._feature_index[fid]
		if got != scan.get(fid, []):
			return "feature index for %s: %d cells, the map has %d" % [fid, got.size(),
					(scan.get(fid, []) as Array).size()]
	for fid: String in scan:
		if not GameActionResolver._feature_index.has(fid):
			return "feature index misses %s" % fid
	var patched: PackedByteArray = AIController._walk_mask(st.grid).duplicate()
	AIController._wmask_grid = 0
	var rebuilt: PackedByteArray = AIController._walk_mask(st.grid)
	if patched != rebuilt:
		return "the patched walk mask differs from a fresh one"
	var ai := AIController.new(side, AIController.Difficulty.HARD)
	var seeds: Array[Vector2i] = []
	for e: UnitInstance in st.all_units():
		if e.owner != side and e.is_alive() and not CivilianAI.is_npc(e):
			seeds.append(e.coord)
	var why := _same_field(st.grid, ai._enemy_distance_field(st, false, r), seeds, "enemy")
	if why != "":
		return why
	var hulls: Array[Vector2i] = []
	for veh: Vehicle in ai._enemy_vehicles(st):
		hulls.append_array(veh.footprint())
	if not hulls.is_empty():
		_stats["vehicle fields"] = int(_stats.get("vehicle fields", 0)) + 1
	return _same_field(st.grid, ai._vehicle_distance_field(st), hulls, "vehicle")

func _same_field(grid: Grid, field: GeoField, seeds: Array[Vector2i], what: String) -> String:
	var dist := {}
	var queue: Array[Vector2i] = []
	for c: Vector2i in seeds:
		if not grid.in_bounds(c) or dist.has(c):
			continue
		dist[c] = 0
		queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for n: Vector2i in grid.neighbors(c):
			if dist.has(n) or not grid.cell(n).walkable_terrain():
				continue
			dist[n] = int(dist[c]) + 1
			queue.append(n)
	for y in grid.height:
		for x in grid.width:
			var c := Vector2i(x, y)
			var want: int = int(dist.get(c, GeoField.FAR))
			if field.at(c) != want:
				return "AI %s field at %s is %d, the plain wave says %d" % [what, c, field.at(c), want]
	return ""
