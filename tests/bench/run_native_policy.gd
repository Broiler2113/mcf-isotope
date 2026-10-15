extends SceneTree
## Synchronous native call timing, including Dictionary conversion and tensor encoding.
const Obs = preload("res://rl/ObsEncoder.gd")

func _initialize() -> void:
	if not LearnedController.available() or LearnedController._load_embedded() == null:
		printerr("native benchmark needs a built MCFPolicy and a valid ONNX model")
		quit(1)
		return
	GameConfig.civilians_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	for size: Vector2i in [Vector2i(34, 26), Vector2i(160, 100)]:
		var map := MapData.blank_arena(size.x, size.y)
		var count := 120 if size.x >= 100 else 12
		for side in 2:
			for n in count:
				var x := 3 + n % 15 if side == 0 else size.x - 4 - n % 15
				var y := 3 + n / 15 if side == 0 else size.y - 4 - n / 15
				map.set_spawn(Vector2i(x, y), "light_infantry", side)
		var state := map.build_state(700 + size.x)
		var resolver := GameActionResolver.new(state)
		resolver.fog_mode = MCF.Fog.OFF
		var start := Time.get_ticks_usec()
		var side := state.active_player()
		var tac := Obs.tactics(resolver, side)
		var desc: Array = []
		for intent: Intent in resolver.legal_intents(side):
			desc.append(Obs.describe(state, intent, tac))
		var req := {"obs": Obs.encode(resolver, side, 10, tac), "legal": desc}
		var observation_ms := float(Time.get_ticks_usec() - start) / 1000.0
		var policy := LearnedController._load_embedded()
		var timings: Array[float] = []
		for iteration in 7:
			start = Time.get_ticks_usec()
			var reply: Dictionary = policy.call("infer", req)
			var elapsed := float(Time.get_ticks_usec() - start) / 1000.0
			if not LearnedController._valid_reply(reply, desc.size()):
				printerr(reply)
				quit(1)
				return
			if iteration >= 2:
				timings.append(elapsed)
		timings.sort()
		print(JSON.stringify({"width": size.x, "height": size.y, "soldiers": count * 2,
			"candidates": desc.size(), "observation_ms": observation_ms,
			"native_median_ms": timings[2], "native_max_ms": timings[4],
			"samples": timings.size(), "warmup": 2}))
	quit(0)
