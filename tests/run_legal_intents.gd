extends SceneTree

## Точность перечислителя законных намерений (RL v1, spec §4.1 / 13.1).
##
## Утверждение одно: КАЖДОЕ намерение, которое LegalIntents перечислил, резолвер
## принимает. Проверяется на случайных картах (та же генерация, что в общем фаззе
## batch 15): на каждой точке решения берётся выборка перечисленных намерений, каждое
## прогоняется через снимок → resolve() → откат, и любой отказ — провал теста с
## указанием вида намерения и причины. Заодно проверяется, что список никогда не пуст
## (EndTurn есть всегда) и что откат возвращает доску в точности (по слепку).
##
## Аргументы: `-- <первое_зерно> <число_партий>` (по умолчанию 1 и 6).

const TS = preload("res://tests/TestSupport.gd")
const ROUNDS := 4
const MAX_ACTIONS := 1500
const SAMPLE := 48
const INFANTRY := [
	"light_infantry", "heavy_infantry", "machinegunner", "sniper", "anti_tank",
	"engineer", "flamethrower", "assault", "marksman", "miner", "sapper",
	"shield_bearer", "drone_operator", "commander",
]

var fails: Dictionary = {}   # "Kind: reason" -> count
var examples: PackedStringArray = []
var tested := 0
var decisions := 0
var _pending: Intent = null

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var first := int(args[0]) if args.size() > 0 else 1
	var count := int(args[1]) if args.size() > 1 else 6
	for i in count:
		_play(first + i)
	if fails.is_empty():
		print("legal intents: %d intents across %d decision points all resolve OK" % [tested, decisions])
		quit(0)
		return
	printerr("legal intents: %d refusal kind(s) over %d tested intents" % [fails.size(), tested])
	var keys: Array = fails.keys()
	keys.sort()
	for k in keys:
		printerr("  x%-4d %s" % [fails[k], k])
	for e in examples:
		printerr("    e.g. " + e)
	quit(1)

func _play(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	GameConfig.civilians_enabled = true
	var m := _random_map(rng)
	var state := m.build_state(seed_value * 7919)
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var s := state.roster.slot(side)
		if s != null:
			s.kind = Roster.SlotKind.AI   # без стека Undo — снимки делаем сами
	var r := GameActionResolver.new(state)
	var fogs: Array = [MCF.Fog.OFF, MCF.Fog.STANDARD, MCF.Fog.REALISTIC]
	r.fog_mode = fogs[rng.randi_range(0, 2)]
	r.friendly_fire_enabled = rng.randi_range(0, 1) == 1
	r.update_airlocks()
	r.play_civilian_slots()
	var brains := {}
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var ai := AIController.new(side, rng.randi_range(0, 2))
		ai.intent_ready.connect(_on_intent)
		brains[side] = ai

	var actions := 0
	while state.turns.round_number <= ROUNDS and actions < MAX_ACTIONS and _both_alive(state):
		var side: int = state.active_player()
		var legal: Array = r.legal_intents(side)
		decisions += 1
		if legal.is_empty() or not (legal[legal.size() - 1] is EndTurnIntent):
			_fail("EndTurn", "missing from the legal list", "seed %d" % seed_value)
		_probe(state, r, legal, rng, seed_value)
		# Настоящий ход: половина — решение ИИ, половина — случайное законное намерение.
		var intent: Intent = null
		if rng.randi_range(0, 1) == 0:
			_pending = null
			brains[side].begin_turn(state)
			intent = _pending
		if intent == null:
			intent = legal[rng.randi_range(0, legal.size() - 1)]
		actions += 1
		var res := r.resolve(intent)
		if not res.ok:
			brains[side].notify_intent_denied(state)

## Выборка перечисленных намерений: каждое через снимок → resolve → откат.
func _probe(state: GameState, r: GameActionResolver, legal: Array,
		rng: RandomNumberGenerator, seed_value: int) -> void:
	var idx: Array = []
	if legal.size() <= SAMPLE:
		for i in legal.size():
			idx.append(i)
	else:
		var seen := {}
		while idx.size() < SAMPLE:
			var i := rng.randi_range(0, legal.size() - 1)
			if not seen.has(i):
				seen[i] = true
				idx.append(i)
	# Шлюзы пересчитываются в НАЧАЛЕ dispatch (артефакт фазза batch 15): выравниваем
	# доску до слепка, иначе первый же resolve «изменит» высоту створки.
	r.update_airlocks()
	var before := TS.digest(state)
	var dice_seed := state.dice.current_seed()
	var dice_rolls := state.dice.own_rolls
	for i in idx:
		var intent: Intent = legal[i]
		if intent is EndTurnIntent:
			continue   # передача хода крутит нейтралов и огонь — её законность очевидна
		var snap := state.snapshot()
		var res := r.resolve(intent)
		tested += 1
		if not res.ok:
			_fail(_kind(intent), res.reason, "seed %d r%d: %s" % [
					seed_value, state.turns.round_number, TS.intent_line(intent)])
		state.restore(snap)
		state.dice.restore_position(dice_seed, dice_rolls)
		r.update_airlocks()
	var after := TS.digest(state)
	if before != after:
		var la := before.split("\n")
		var lb := after.split("\n")
		var diff := ""
		for i in maxi(la.size(), lb.size()):
			var x: String = la[i] if i < la.size() else "<eof>"
			var y: String = lb[i] if i < lb.size() else "<eof>"
			if x != y:
				diff = "%s | %s" % [x, y]
				break
		_fail("restore", "digest changed after snapshot/restore", "seed %d: %s" % [seed_value, diff])

func _kind(intent: Intent) -> String:
	return intent.get_script().resource_path.get_file().get_basename()

func _fail(kind: String, reason: String, example: String) -> void:
	var key := "%s: %s" % [kind, reason]
	fails[key] = int(fails.get(key, 0)) + 1
	if int(fails[key]) == 1 and examples.size() < 40:
		examples.append("%s — %s" % [key, example])

func _both_alive(state: GameState) -> bool:
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var alive := false
		for u in state.living_units_of(side):
			if not u.is_drone:
				alive = true
				break
		if not alive:
			return false
	return true

func _on_intent(intent: Intent) -> void:
	_pending = intent

# --- Случайная карта (рецепт общего фазза batch 15) --------------------------------
func _random_map(rng: RandomNumberGenerator) -> MapData:
	var w := rng.randi_range(20, 40)
	var h := rng.randi_range(16, 30)
	var m := MapData.new(w, h)
	var features := ["", "", "", "", "", MCF.FEATURE_WALL, MCF.FEATURE_GLASS,
			MCF.FEATURE_SANDBAGS, MCF.FEATURE_TRENCH, MCF.FEATURE_HEDGEHOG,
			MCF.FEATURE_WOOD_WALL, MCF.FEATURE_AIRLOCK, MCF.FEATURE_DPMG, MCF.FEATURE_DOT]
	for y in h:
		for x in w:
			var fl: int = [MCF.FLOOR_NORMAL, MCF.FLOOR_NORMAL, MCF.FLOOR_FLAMMABLE, MCF.FLOOR_GRASS][rng.randi_range(0, 3)]
			var f: String = features[rng.randi_range(0, features.size() - 1)] if rng.randf() < 0.18 else ""
			var space := rng.randf() < 0.02
			m.set_cell(Vector2i(x, y), fl, 0.0, space, f)
	# Стенные отрезки — чтобы были коридоры и проёмы.
	for _i in rng.randi_range(2, 6):
		var x0 := rng.randi_range(4, w - 5)
		var y0 := rng.randi_range(2, h - 3)
		var len := rng.randi_range(3, 8)
		var vertical := rng.randi_range(0, 1) == 1
		for k in len:
			var c := Vector2i(x0, y0 + k) if vertical else Vector2i(x0 + k, y0)
			if m.in_bounds(c):
				m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	# Армии: чистые колонны у краёв, зеркально. Техника рядом с колонной.
	for side_i in 2:
		var owner := MCF.Owner.PLAYER_1 if side_i == 0 else MCF.Owner.PLAYER_2
		var col := 2 if side_i == 0 else w - 3
		var n := rng.randi_range(5, 9)
		for i in n:
			var y := 1 + i * 2
			if y >= h - 1:
				break
			var c := Vector2i(col, y)
			m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, "")
			m.set_spawn(c, INFANTRY[rng.randi_range(0, INFANTRY.size() - 1)], owner)
		var vcol := 5 if side_i == 0 else w - 8
		var vehicles := ["tank", "shuttle", "borg"]
		var vy := h - 5
		for vid in vehicles:
			if rng.randf() < 0.5:
				continue
			var size := VehicleDB.size_of(vid)
			for dy in size.y:
				for dx in size.x:
					var c := Vector2i(vcol + dx, vy + dy)
					if m.in_bounds(c):
						m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, "")
			if m.in_bounds(Vector2i(vcol + size.x - 1, vy + size.y - 1)):
				m.set_spawn(Vector2i(vcol, vy), vid, owner, Vector2i(1, 0) if side_i == 0 else Vector2i(-1, 0))
			vy -= 4
	for _i in rng.randi_range(0, 5):
		var c := Vector2i(rng.randi_range(8, w - 9), rng.randi_range(1, h - 2))
		if m.get_feature(c) == "" and not m.get_space(c):
			m.set_spawn(c, "civilian", MCF.Owner.NEUTRAL)
	return m
