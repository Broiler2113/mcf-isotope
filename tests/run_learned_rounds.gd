extends SceneTree

## Меняется ли поведение обученного ИИ с номером раунда.
##
## Наблюдение содержит round/round_cap, и LearnedController подставляет туда СВОЙ
## ROUND_CAP. Если он не равен тому, с которым политика училась, то с какого-то раунда
## признак выходит за диапазон, который сеть вообще видела, — и вести себя она может как
## угодно. Этот прогон меряет долю «конца хода» по раундам: ровно то, что игрок опишет
## словами «он просто пропускает ходы».
##
##   MCF_RL_POLICY=127.0.0.1:7791 godot --headless --script res://tests/run_learned_rounds.gd

const RL_SIDE := MCF.Owner.PLAYER_2
const DECISIONS_PER_ROUND := 12

func _initialize() -> void:
	# Без сервера политики проверять нечего: это не провал, а отсутствие условий.
	# Так прогон живёт в общем наборе и не валит его на машине, где сервер не поднят.
	if OS.get_environment("MCF_RL_POLICY") == "":
		print("%s: skipped (MCF_RL_POLICY not set)" % _name())
		quit(0)
		return
	var probe := [1, 5, 9, 11, 15, 19]
	print("round | decisions | end | shoot | move | end-turn share")
	var bad: Array = []
	for rnd: int in probe:
		var res := _sample_at_round(rnd)
		var share: float = res["share"]
		print("%5d | %9d | %3d | %5d | %4d | %.0f%%" % [rnd, res["n"], res["end"],
				res["shoot"], res["move"], share * 100.0])
		if share >= 0.9:
			bad.append(rnd)
	if not bad.is_empty():
		printerr("learned-rounds: policy skips its turn at rounds %s" % str(bad))
		quit(1)
		return
	print("learned-rounds: the policy keeps acting at every round probed")
	quit(0)

func _sample_at_round(target_round: int) -> Dictionary:
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	var roster := ["light_infantry", "heavy_infantry", "machinegunner", "sniper",
			"light_infantry", "engineer"]
	for i in roster.size():
		m.set_spawn(Vector2i(4 + i, 4), roster[i], MCF.Owner.PLAYER_1)
		m.set_spawn(Vector2i(4 + i, 9), roster[i], RL_SIDE)
	GameConfig.civilians_enabled = false
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	# Докрутить доску до нужного раунда, ничего не разыгрывая: только концы хода.
	var guard := 0
	while st.turns.round_number < target_round and guard < 200:
		guard += 1
		r.resolve(EndTurnIntent.new(st.active_player()))

	var ctrl := LearnedController.new(RL_SIDE)
	var picked: Array = []
	ctrl.intent_ready.connect(func(i: Intent) -> void: picked.append(i))
	var counts := {"end": 0, "shoot": 0, "move": 0}
	var g2 := 0
	while picked.size() < DECISIONS_PER_ROUND and g2 < 200:
		g2 += 1
		if st.active_player() != RL_SIDE:
			r.resolve(EndTurnIntent.new(st.active_player()))
			continue
		var before := picked.size()
		ctrl.begin_turn(st)
		if picked.size() == before:
			break
		var intent: Intent = picked[-1]
		if intent is EndTurnIntent: counts["end"] += 1
		elif intent is ShootIntent: counts["shoot"] += 1
		elif intent is MoveIntent: counts["move"] += 1
		var rr := r.resolve(intent)
		if not rr.ok:
			r.resolve(EndTurnIntent.new(RL_SIDE))
	var n: int = picked.size()
	return {"n": n, "end": counts["end"], "shoot": counts["shoot"], "move": counts["move"],
			"share": 0.0 if n == 0 else float(counts["end"]) / float(n)}

func _name() -> String:
	return "run_learned_rounds"
