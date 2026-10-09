extends SceneTree

## Seeking must choose the same frame at every boundary and reconstruct the same match.
## -- --bench also measures frame lookup in a long recording; timing is not a test gate.

const TS = preload("res://tests/TestSupport.gd")
var fails: PackedStringArray = []

func ck(ok: bool, message: String) -> void:
	if not ok:
		fails.append(message)

func _initialize() -> void:
	_frame_boundaries()
	_recorded_match()
	if "--bench" in OS.get_cmdline_user_args():
		_bench()
	for message in fails:
		printerr("FAIL " + message)
	if fails.is_empty():
		print("replay seek: frame boundaries, legacy recordings and bidirectional match reconstruction agree")
	quit(0 if fails.is_empty() else 1)

## Original forward scan, kept as an independent comparison for frame selection.
func _reference(data: Dictionary, target: int) -> Dictionary:
	var best := {"at": 0, "state": data.get("start", {}),
			"rules": data.get("rules", {}), "open": data.get("opening", [])}
	var steps: Array = data.get("steps", [])
	for s in steps.size():
		if s + 1 > target:
			break
		var step: Dictionary = steps[s]
		if step.has("k"):
			var frame: Dictionary = step["k"]
			best = {"at": s + 1, "state": frame.get("state", {}),
					"rules": frame.get("rules", {}), "open": []}
	return best

func _frame_boundaries() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9601
	for size in [0, 1, 7, 80]:
		var steps: Array = []
		for i in size:
			var step := {"i": {}, "r": []}
			if rng.randi_range(0, 3) == 0:
				step["k"] = {"state": {"marker": i}, "rules": {"marker": -i}}
			steps.append(step)
		var data := {"start": {"marker": -1}, "rules": {"initial": true},
				"opening": [2, 6], "steps": steps}
		var player := ReplayPlayer.new(data)
		for target in range(-1, size + 3):
			ck(player._frame_at_or_before(target) == _reference(data, target),
					"wrong frame at target %d of %d" % [target, size])
		# Old recordings have no keyframes at all.
		for step: Dictionary in steps:
			step.erase("k")
		ck(player._frame_at_or_before(size) == _reference(data, size),
				"recording without frames lost its opening state")

func _recorded_match() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapData.blank_arena(12, 10)
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(9, 7), "engineer", 1)
	var state := map.build_state(9602)
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.REALISTIC
	resolver.friendly_fire_enabled = false
	var recorder := ReplayRecorder.new()
	recorder.begin(state, resolver)
	resolver.replay_recorder = recorder
	for i in 35:
		ck(resolver.resolve(EndTurnIntent.new(state.active_player())).ok, "recorded turn denied")
	resolver.replay_recorder = null
	var data := recorder.to_dict()
	var plain := data.duplicate(true)
	var frames := 0
	for step: Dictionary in plain["steps"]:
		frames += 1 if step.has("k") else 0
		step.erase("k")
	ck(frames >= 3, "match did not record enough keyframes")
	var fast := ReplayPlayer.new(data)
	var from_start := ReplayPlayer.new(plain)
	for target in [0, 9, 10, 11, 34, 35, 21, 4, 20, 0, 35]:
		fast.seek(target)
		from_start.seek(target)
		ck(TS.digest(fast.state) == TS.digest(from_start.state),
				"seek to %d changed the board" % target)
		ck(StateCodec.encode_rules(fast.resolver) == StateCodec.encode_rules(from_start.resolver),
				"seek to %d changed the match rules" % target)
		ck(fast.index == target, "seek stopped at the wrong action")

func _bench() -> void:
	var steps: Array = []
	for i in 60000:
		var step := {}
		if i % 1000 == 999:
			step["k"] = {"state": {"marker": i}}
		steps.append(step)
	var data := {"steps": steps}
	var player := ReplayPlayer.new(data)
	var old_us := 1 << 60
	var new_us := 1 << 60
	for repetition in 5:
		var t := Time.get_ticks_usec()
		for i in 20:
			_reference(data, 59900 + i)
		old_us = mini(old_us, Time.get_ticks_usec() - t)
		t = Time.get_ticks_usec()
		for i in 20:
			player._frame_at_or_before(59900 + i)
		new_us = mini(new_us, Time.get_ticks_usec() - t)
	print("replay lookup, 60000 actions: reference %.1f us / current %.1f us per lookup" % [
			old_us / 20.0, new_us / 20.0])
