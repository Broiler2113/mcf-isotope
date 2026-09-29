extends SceneTree

## Обученный ИИ на ТОЙ САМОЙ карте, на которой в него играют, и с подсчётом ОТКАЗОВ.
##
## Главное здесь — отказы. Main.gd на отказ зовёт notify_intent_denied() и заказывает шаг
## заново, а после AI_MAX_DENIED подряд принудительно завершает ход («[ai] stuck after N
## refusals»). Политика на сервере работает ЖАДНО: одно и то же наблюдение даёт один и тот
## же индекс. Значит отказанное намерение будет предлагаться снова и снова, пока счётчик не
## упрётся, — и игрок увидит ровно то, о чём сообщил: ИИ пропускает ход.
##
##   MCF_RL_POLICY=127.0.0.1:7791 [MCF_RL_MAX_ACTORS=16 MCF_RL_MAX_CANDIDATES=512] \
##     godot --headless --script res://tests/run_learned_town.gd [--map res://...]

const RL_SIDE := MCF.Owner.PLAYER_2
const MAX_DENIED := 12          # то же число, что AI_MAX_DENIED в Main.gd

func _initialize() -> void:
	# Без сервера политики проверять нечего: это не провал, а отсутствие условий.
	# Так прогон живёт в общем наборе и не валит его на машине, где сервер не поднят.
	if OS.get_environment("MCF_RL_POLICY") == "":
		print("%s: skipped (MCF_RL_POLICY not set)" % _name())
		quit(0)
		return
	var path := "res://rl/maps/town_50x50_s25.json"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			path = a.substr(6)
	var m := MapData.load_from(path)
	if m == null:
		printerr("learned-town: cannot load %s" % path)
		quit(2)
		return
	GameConfig.civilians_enabled = false
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false

	var ctrl := LearnedController.new(RL_SIDE)
	var fell_back := ""
	ctrl.fallback_engaged.connect(func(reason: String) -> void: fell_back = reason)
	var picked: Array = []
	ctrl.intent_ready.connect(func(i: Intent) -> void: picked.append(i))

	var kinds := {}
	var denied := 0
	var denied_reasons := {}
	var streak := 0
	var worst_streak := 0
	var forced_ends := 0
	var guard := 0
	# Противник — обычный скриптовый ИИ, а не «сразу конец хода». С пассивной стороной
	# доска не меняется: никто не сближается, никто не стреляет, и доля «конца хода» у
	# политики меряется на положении, которого в настоящей партии не бывает.
	var foe := AIController.new(MCF.Owner.PLAYER_1, AIController.Difficulty.HARD)
	var foe_intent: Array = []
	foe.intent_ready.connect(func(i: Intent) -> void: foe_intent.append(i))
	while picked.size() < 120 and guard < 4000:
		guard += 1
		if st.active_player() != RL_SIDE:
			foe_intent.clear()
			foe.begin_turn(st)
			if foe_intent.is_empty():
				r.resolve(EndTurnIntent.new(st.active_player()))
			else:
				var fr := r.resolve(foe_intent[0])
				if not fr.ok:
					r.resolve(EndTurnIntent.new(st.active_player()))
			continue
		var before := picked.size()
		ctrl.begin_turn(st)
		if picked.size() == before:
			break
		var intent: Intent = picked[-1]
		var kind := _kind(intent)
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		var res := r.resolve(intent)
		if res.ok:
			streak = 0
			continue
		denied += 1
		streak += 1
		worst_streak = maxi(worst_streak, streak)
		var why := "%s: %s" % [kind, res.reason]
		denied_reasons[why] = int(denied_reasons.get(why, 0)) + 1
		# Ровно то, что делает Main.gd.
		ctrl.notify_intent_denied(st)
		if streak >= MAX_DENIED:
			forced_ends += 1
			streak = 0
			r.resolve(EndTurnIntent.new(RL_SIDE))

	print("learned-town: %s" % path)
	print("  decisions %d | denied %d | worst denial streak %d | FORCED turn ends %d"
			% [picked.size(), denied, worst_streak, forced_ends])
	var keys: Array = kinds.keys()
	keys.sort()
	for k: String in keys:
		print("    %-16s %d" % [k, kinds[k]])
	if not denied_reasons.is_empty():
		print("  denial reasons:")
		for why: String in denied_reasons:
			print("    %-60s x%d" % [why, denied_reasons[why]])
	if fell_back != "":
		printerr("learned-town: FELL BACK to the heuristic (%s)" % fell_back)
		quit(1)
		return
	if forced_ends > 0:
		printerr("learned-town: %d turns were force-ended after %d refusals in a row — "
				% [forced_ends, MAX_DENIED] + "this is the 'AI skips its turn' bug")
		quit(1)
		return
	print("learned-town: no forced turn ends")
	quit(0)

func _kind(i: Intent) -> String:
	if i is EndTurnIntent: return "end"
	if i is ShootIntent: return "shoot"
	if i is MoveIntent: return "move"
	if i is DigIntent: return "dig"
	if i is DragIntent: return "drag"
	if i is VehicleMoveIntent: return "veh_move"
	if i is VehicleBoardIntent: return "board"
	if i is VehicleDisembarkIntent: return "veh_out"
	if i is VehicleCannonIntent: return "veh_cannon"
	return i.get_class()

func _name() -> String:
	return "run_learned_town"
