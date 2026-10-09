extends "res://rl/env_server.gd"
## Exercise the actual round clock, public hazard source, and network replay file.
var failures: Array[String] = []
func ck(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

func _initialize() -> void:
	var m := MapData.new(30, 20)
	for y in m.height:
		for x in m.width:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	m.set_spawn(Vector2i(26, 16), "light_infantry", 1)
	m.save_to("user://rl_learning_fixture.json")
	_reset({"map": "user://rl_learning_fixture.json", "seed": 71, "side": 0,
		"opponent": -1, "round_cap": 20, "max_steps": 100,
		"discount_unit": "round", "gamma": 0.97, "fog": MCF.Fog.STANDARD,
		"potential_coef": 0.5, "hazard_coef": 0.5})
	while state.active_player() != 0:
		resolver.resolve(EndTurnIntent.new())
	_potential_pending = false
	var r := _response(0, true)
	var moved := false
	for k in _legal.size():
		if _legal[k] is MoveIntent:
			r = _step({"action": k})
			ck(r["info"]["discount_steps"] == 0, "within-turn action must not discount future rewards")
			moved = true
			break
	ck(moved, "fixture offers movement")
	var crossed := 0
	var ended := false
	for n in 3:
		if ended and state.active_player() == 0:
			break
		for k in _legal.size():
			if _legal[k] is EndTurnIntent:
				r = _step({"action": k})
				crossed += int(r["info"]["discount_steps"])
				ended = true
				break
	ck(crossed == 1, "pool opponent response discounts exactly one completed round")
	# The private policy resolver must see live public hazards without UI omniscience.
	var learned := LearnedController.new(0)
	learned.bind_match(resolver)
	resolver.random_events.announce(RandomEvents.MORTAR,
		{"x": 1, "y": 1, "w": 2, "h": 2}, state.turns.round_number)
	# Call with no policy endpoint; it prepares observations then fails to connect.
	learned._decide(state)
	ck(learned._resolver.random_events == resolver.random_events, "live hazard source is shared")
	ck(learned._resolver.omniscient_side == -1, "policy remains fog limited")
	# Network host records the SAME dice stream used for lockstep.
	var hs := m.build_state(741)
	var hr := GameActionResolver.new(hs)
	hr.fog_mode = MCF.Fog.STANDARD
	hr.random_events = RandomEvents.new(false)
	for side_id in hs.roster.player_ids():
		hs.roster.slot(side_id).kind = Roster.SlotKind.HUMAN
	var rec := ReplayRecorder.new()
	rec.begin(hs, hr, {"map": "human-fixture", "network": true})
	var host := NetGame.new(hs, hr, true)
	host.recorder = rec
	host.announce_initiative()
	for n in 8:
		if n % 2 == 0:
			for intent: Intent in hr.legal_intents(hs.active_player()):
				if intent is MoveIntent:
					host.submit_local(intent)
					break
		host.submit_local(EndTurnIntent.new())
	var data := rec.to_dict()
	var replay := ReplayPlayer.new(data)
	replay.seek(0)
	while replay.has_next():
		var result := replay.play_next()
		ck(result != null and result.ok, "network replay action accepted")
		ck(replay.state.dice.fallback_rolls == 0 and replay.state.dice.scripted_remaining() == 0,
			"network replay uses exactly the recorded dice")
	ck(replay.state.digest_hash() == hs.digest_hash(), "network replay reproduces final board")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		ReplayFile.write(args[0], data)
		data["steps"][0]["r"].append(6)
		ReplayFile.write(args[0] + ".bad.mcfr", data)
	if failures.is_empty():
		print("RL learning: round clock, live hazards, network replay determinism passed")
	else:
		for message in failures:
			printerr(message)
	quit(0 if failures.is_empty() else 1)
