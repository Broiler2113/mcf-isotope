extends SceneTree

## Что на самом деле делает обученный ИИ, когда за него играют в НАСТОЯЩЕЙ партии.
##
## Проверяется ровно тот путь, по которому идёт игра: LearnedController.begin_turn() →
## политика → intent_ready. Не среда обучения, не оценка — боевой шов, тот самый, про
## который пришла жалоба «он просто пропускает ходы».
##
## Запуск (сервер политики должен уже слушать):
##   MCF_RL_POLICY=127.0.0.1:7791 MCF_RL_MAX_ACTORS=16 MCF_RL_MAX_CANDIDATES=512 \
##     godot --headless --script res://tests/run_learned_play.gd

const RL_SIDE := MCF.Owner.PLAYER_2

func _initialize() -> void:
	# Без сервера политики проверять нечего: это не провал, а отсутствие условий.
	# Так прогон живёт в общем наборе и не валит его на машине, где сервер не поднят.
	if OS.get_environment("MCF_RL_POLICY") == "":
		print("%s: skipped (MCF_RL_POLICY not set)" % _name())
		quit(0)
		return
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	# Небольшой, но не игрушечный отряд с обеих сторон: и стрелять есть чем, и цели есть.
	var roster := ["light_infantry", "heavy_infantry", "machinegunner", "sniper",
			"light_infantry", "engineer"]
	for i in roster.size():
		m.set_spawn(Vector2i(4 + i, 4), roster[i], MCF.Owner.PLAYER_1)
		m.set_spawn(Vector2i(4 + i, 9), roster[i], RL_SIDE)
	GameConfig.civilians_enabled = false
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false

	var ctrl := LearnedController.new(RL_SIDE)
	var picked: Array = []
	var fell_back := ""
	ctrl.fallback_engaged.connect(func(reason: String) -> void: fell_back = reason)
	ctrl.intent_ready.connect(func(i: Intent) -> void: picked.append(i))

	# Гоним ходы, пока не наберём решений: каждый begin_turn — одно решение политики.
	var kinds := {}
	var guard := 0
	while picked.size() < 40 and guard < 400:
		guard += 1
		if st.active_player() != RL_SIDE:
			r.resolve(EndTurnIntent.new(st.active_player()))
			continue
		var before := picked.size()
		ctrl.begin_turn(st)
		if picked.size() == before:
			break                      # контроллер ничего не предложил
		var intent: Intent = picked[-1]
		var kind := _kind(intent)
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		var res := r.resolve(intent)
		if not res.ok:
			kinds["DENIED:" + kind] = int(kinds.get("DENIED:" + kind, 0)) + 1
			r.resolve(EndTurnIntent.new(RL_SIDE))

	print("learned-play: %d decisions, fallback=%s" % [picked.size(),
			fell_back if fell_back != "" else "no"])
	var keys: Array = kinds.keys()
	keys.sort()
	for k: String in keys:
		print("   %-16s %d" % [k, kinds[k]])
	var ends := int(kinds.get("end", 0))
	var share := 0.0 if picked.is_empty() else float(ends) / float(picked.size())
	print("learned-play: end-turn share %.0f%%" % (share * 100.0))
	if fell_back != "":
		printerr("learned-play: FELL BACK to the heuristic (%s)" % fell_back)
		quit(1)
		return
	if picked.is_empty():
		printerr("learned-play: the controller produced no intent at all")
		quit(1)
		return
	# «Пропускает ходы» — это и есть вот это: политика почти всегда выбирает конец хода.
	if share >= 0.9:
		printerr("learned-play: policy ends its turn in %.0f%% of decisions — it is skipping turns"
				% (share * 100.0))
		quit(1)
		return
	print("learned-play: the learned AI acts (end-turn share under 90%)")
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
	return i.get_class()

func _name() -> String:
	return "run_learned_play"
