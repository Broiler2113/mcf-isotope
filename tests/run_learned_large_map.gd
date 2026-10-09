extends SceneTree
## Live learned-controller regression on a board wider than the training canvas.
## Started by rl/test_training_fixes.py with a real policy server.

func _initialize() -> void:
	if not LearnedController.available():
		printerr("large-map regression needs MCF_RL_POLICY")
		quit(1)
		return
	var m := MapData.new(74, 62)
	for y in m.height:
		for x in m.width:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(70, 55), "light_infantry", 0)
	m.set_spawn(Vector2i(5, 5), "light_infantry", 1)
	GameConfig.civilians_enabled = false
	var state := m.build_state(7)
	var resolver := GameActionResolver.new(state)
	var learned := LearnedController.new(0)
	var decisions := 0
	while decisions < 4:
		if state.active_player() != 0:
			resolver.resolve(EndTurnIntent.new())
			continue
		var chosen := learned._decide(state)
		if chosen.is_empty():
			printerr("large-map policy failed: " + learned._last_error)
			quit(1)
			return
		var result := resolver.resolve(chosen["intent"])
		if not result.ok:
			printerr("large-map policy action refused: " + result.reason)
			quit(1)
			return
		learned.notify_intent_accepted()
		decisions += 1
	print("large-map learned controller: 4 accepted policy decisions, no fallback")
	quit(0)
