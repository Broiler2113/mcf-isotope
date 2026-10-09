extends SceneTree

## Recording and learned-AI fallback must not retain a finished match through callbacks.
## Weak references observe actual destruction, rather than only checking field values.

var fails: PackedStringArray = []
const TS = preload("res://tests/TestSupport.gd")

func ck(ok: bool, message: String) -> void:
	if not ok:
		fails.append(message)

func _initialize() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	OS.set_environment(LearnedController.ENV_VAR, "")
	for i in 8:
		var recording := _recorded_match()
		for name: String in ["state", "resolver", "recorder"]:
			ck(recording[name].get_ref() == null, "recorded match retained " + name)
		# The recording itself is plain data and remains playable after its owners die.
		var replay := ReplayPlayer.new(recording["data"])
		replay.seek(replay.step_count())
		ck(replay.state.digest_hash() == recording["digest"], "released match no longer replays")
		var refs := _fallback_match()
		ck(refs[0].get_ref() == null, "learned controller retained by fallback callback")
		ck(refs[1].get_ref() == null, "fallback controller retained after match closes")
	_recorded_battle()
	for message in fails:
		printerr("FAIL " + message)
	if fails.is_empty():
		print("match lifetime: recordings/fallbacks release their owners; recorded battle and dice replay identically")
	quit(0 if fails.is_empty() else 1)

func _state() -> GameState:
	var map := MapData.blank_arena(12, 10)
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(9, 7), "light_infantry", 1)
	return map.build_state(9604)

func _recorded_match() -> Dictionary:
	var state := _state()
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.OFF
	var recorder := ReplayRecorder.new()
	recorder.begin(state, resolver)
	resolver.replay_recorder = recorder
	recorder.capture_opening()
	for i in 12:
		ck(resolver.resolve(EndTurnIntent.new(state.active_player())).ok, "recorded action denied")
	return {"state": weakref(state), "resolver": weakref(resolver),
			"recorder": weakref(recorder), "data": recorder.to_dict(), "digest": state.digest_hash()}

func _fallback_match() -> Array:
	var state := _state()
	var learned := LearnedController.new(state.active_player())
	var picked: Array = []
	learned.intent_ready.connect(func(intent: Intent) -> void: picked.append(intent))
	learned.begin_turn(state)
	ck(learned._fallback != null, "fallback was not engaged")
	ck(picked.size() == 1, "fallback intent was not forwarded exactly once")
	return [weakref(learned), weakref(learned._fallback)]

func _recorded_battle() -> void:
	var state := TS.build_state()
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.STANDARD
	var recorder := ReplayRecorder.new()
	recorder.begin(state, resolver)
	resolver.replay_recorder = recorder
	recorder.capture_opening()
	var pending: Array = [null]
	var brains := {}
	for side in [0, 1]:
		var brain := AIController.new(side, AIController.Difficulty.HARD)
		brain.intent_ready.connect(func(intent: Intent) -> void: pending[0] = intent)
		brains[side] = brain
	var actions := 0
	while state.turns.round_number <= 4 and actions < 500:
		pending[0] = null
		var brain: AIController = brains.get(state.active_player())
		if brain != null:
			brain.begin_turn(state)
		var intent: Intent = pending[0] if pending[0] != null else EndTurnIntent.new()
		if not resolver.resolve(intent).ok and brain != null:
			brain.notify_intent_denied(state)
		actions += 1
	var data := recorder.to_dict()
	var rolls := 0
	for step: Dictionary in data["steps"]:
		rolls += step["r"].size()
	ck(rolls > 0, "recorded battle did not exercise dice")
	var expected := TS.digest(state)
	var player := ReplayPlayer.new(data)
	player.seek(player.step_count())
	ck(TS.digest(player.state) == expected, "recorded battle diverged during replay")
	ck(player.state.dice.fallback_rolls == 0 and player.state.dice.scripted_remaining() == 0,
			"recorded battle consumed a different dice stream")
