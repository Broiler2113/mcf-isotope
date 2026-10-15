extends SceneTree
## Real AI actions on a Giant board, deliberately presented in one burst.
var picked: Intent

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var script := load("res://src/audio/BattleAudio.gd")
	var audio: Node = script.new()
	audio.cell_visible = func(_cell: Vector2i) -> bool: return true
	audio.own_cell = func(_cell: Vector2i) -> bool: return false
	audio.viewer = func() -> int: return 0
	root.add_child(audio)
	var map := MapData.blank_arena(149, 119)
	for side in 2:
		for i in 120:
			map.set_spawn(Vector2i(50 + i % 10, 10 + (i / 10) * 4 + side * 2), "light_infantry", side)
	GameConfig.civilians_enabled = false
	var state := map.build_state(5109)
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.OFF
	var brains := {}
	for side in 2:
		var brain := AIController.new(side, AIController.Difficulty.HARD)
		brain.intent_ready.connect(func(intent: Intent) -> void: picked = intent)
		brains[side] = brain
	var fx := FxDecals.new()
	fx.bounds = Vector2(149, 119)
	var cues := [0]
	fx.sound_requested.connect(func(id: String, cell: Vector2i, owner: int) -> void:
		cues[0] += 1
		audio.cue(id, cell, owner))
	var start := Time.get_ticks_usec()
	var peak := 0
	var decisions := 0
	for i in 100:
		picked = null
		brains[state.active_player()].begin_turn(state)
		if picked == null:
			break
		var result := resolver.resolve(picked)
		if not result.ok:
			brains[state.active_player()].notify_intent_denied(state)
			continue
		decisions += 1
		var digest := state.digest_hash()
		var rolls := state.dice.own_rolls
		fx.apply_lanes(result.fx)
		fx.apply(result.fx)
		fx.advance(1)
		peak = maxi(peak, audio.voices.size())
		if state.digest_hash() != digest or state.dice.own_rolls != rolls or peak > script.WORLD_CAP:
			printerr("audio stress: simulation/dice changed or voice ceiling exceeded")
			quit(1)
			return
	print(JSON.stringify({"board": "149x119", "soldiers": 240, "decisions": decisions,
		"requested_world_cues": cues[0], "peak_world_voices": peak, "ceiling": script.WORLD_CAP,
		"elapsed_ms": float(Time.get_ticks_usec() - start) / 1000.0}))
	audio.free()
	quit(0 if decisions > 20 and cues[0] > script.WORLD_CAP else 1)
