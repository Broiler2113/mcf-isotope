extends SceneTree

const Obs = preload("res://rl/ObsEncoder.gd")
var failures: Array[String] = []

class StubController extends LearnedController:
	var native_reply: Variant = {}
	var socket_reply: Dictionary = {}
	var native_calls := 0
	var socket_calls := 0
	func _embedded_infer(_req: Dictionary) -> Variant:
		native_calls += 1
		return native_reply
	func _ask_socket(_req: Dictionary) -> Dictionary:
		socket_calls += 1
		_last_error = "MCF_RL_POLICY is not set"
		return socket_reply

func ck(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

func _initialize() -> void:
	OS.unset_environment(LearnedController.ENV_BACKEND)
	OS.unset_environment(LearnedController.ENV_VAR)
	var req := {"obs": {}, "legal": [{}, {}]}
	for bad: Variant in [{}, {"error": "broken model"}, {"action": 2}, {"action": -1},
			{"action": 0.5}, {"action": "0"}, {"action": null}, {"action": NAN},
			{"action": 0, "value": INF}, {"action": true}, "invalid"]:
		var stub := StubController.new(0)
		stub.native_reply = bad
		stub.socket_reply = {"action": 1}
		ck(stub._ask(req).get("action") == 1, "invalid/absent native backend tries socket: " + str(bad))
		ck(stub.socket_calls == 1, "socket tried once")
		stub._ask(req)
		ck(stub.native_calls == 1, "failed native backend is not retried each turn")
	var healthy := StubController.new(0)
	healthy.native_reply = {"action": 0, "value": 0.125}
	ck(healthy._ask(req).get("action") == 0 and healthy.socket_calls == 0, "healthy native policy takes priority")
	var broken := StubController.new(0)
	broken.native_reply = {"error": "bad ONNX"}
	ck(broken._ask(req).is_empty(), "both failed backends report failure")
	ck(broken._last_error.contains("embedded policy error") and broken._last_error.contains("MCF_RL_POLICY"), "failure names both attempted backends")
	OS.set_environment(LearnedController.ENV_BACKEND, "socket")
	var socket_only := StubController.new(0)
	socket_only.native_reply = {"action": 0}
	socket_only.socket_reply = {"action": 1}
	ck(socket_only._ask(req).get("action") == 1 and socket_only.native_calls == 0, "explicit socket backend selects training server")
	OS.unset_environment(LearnedController.ENV_BACKEND)
	var present := ClassDB.class_exists("MCFPolicy")
	ck(present or not OS.get_cmdline_user_args().has("--require-native"), "release contains MCFPolicy")
	if present:
		_native_checks()
	for failure in failures:
		printerr("FAIL " + failure)
	print("native policy: backend priority, invalid replies, socket fallback, model loading, labels and legal decisions checked")
	quit(0 if failures.is_empty() else 1)

func _native_checks() -> void:
	ck(LearnedController.available(), "bundled model is available without Python/server")
	ck(LearnedController.model_label().contains("update"), "bundled checkpoint label reaches the lobby helper")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--expected-label="):
			ck(LearnedController.model_label() == arg.trim_prefix("--expected-label="), "local override supplies its own lobby label: got '%s', expected '%s'" % [LearnedController.model_label(), arg.trim_prefix("--expected-label=")])
	var raw: RefCounted = ClassDB.instantiate("MCFPolicy")
	ck(raw.call("infer", {}).has("error"), "unloaded session reports error")
	ck(raw.call("load_model", "res://missing.onnx").has("error"), "missing override reports error")
	var corrupt := "user://corrupt-policy.onnx"
	var file := FileAccess.open(corrupt, FileAccess.WRITE)
	file.store_string("not an ONNX model")
	file.close()
	ck(raw.call("load_model", corrupt).has("error"), "corrupt model reports error")
	var original := OS.get_environment(LearnedController.ENV_MODEL)
	OS.set_environment(LearnedController.ENV_MODEL, "res://missing.onnx")
	ck(not LearnedController.available(), "invalid explicit override does not silently load bundled weights")
	OS.set_environment(LearnedController.ENV_MODEL, original)
	ck(LearnedController.available(), "returning to valid model reloads the native session")
	GameConfig.civilians_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var map := MapData.blank_arena(20, 14)
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(15, 9), "light_infantry", 1)
	var state := map.build_state(93)
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.OFF
	var controller := LearnedController.new(state.active_player())
	var fallbacks: Array = []
	controller.fallback_engaged.connect(func(reason: String) -> void: fallbacks.append(reason))
	var chosen := controller._decide(state)
	ck(not chosen.is_empty(), "actual ObsEncoder packed arrays reach native inference: " + controller._last_error)
	if not chosen.is_empty():
		ck(resolver.resolve(chosen["intent"]).ok, "native action is accepted by live resolver")
	ck(fallbacks.is_empty() and controller._fallback == null, "healthy native model never engages HARD")
	ck(controller._round_cap == int(LearnedController._embedded_metadata.get("mcf.round_cap", 10)), "checkpoint round cap is used")
	# Actual fallback signal remains permanent and forwards one legal intent per call.
	var fail_ctrl := StubController.new(state.active_player())
	fail_ctrl.native_reply = {"error": "fixture failure"}
	var signals: Array = []
	var intents: Array = []
	fail_ctrl.fallback_engaged.connect(func(reason: String) -> void: signals.append(reason))
	fail_ctrl.intent_ready.connect(func(intent: Intent) -> void: intents.append(intent))
	fail_ctrl.begin_turn(state)
	fail_ctrl.begin_turn(state)
	ck(signals.size() == 1 and fail_ctrl._fallback != null, "HARD fallback engages permanently exactly once")
	ck(intents.size() == 2, "HARD fallback continues emitting intents")
