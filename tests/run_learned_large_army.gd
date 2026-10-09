extends SceneTree
## Actual TCP policy + resolver: no accidental turn end with diffuse move scores.
func _initialize() -> void:
	if not LearnedController.available():
		quit(1)
		return
	GameConfig.civilians_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	for count: int in [20, 176]:
		var m := MapData.new(74, 62)
		for y in m.height:
			for x in m.width:
				m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
		for n in count:
			m.set_spawn(Vector2i(2 + n % 20, 2 + n / 20), "light_infantry", 0)
		m.set_spawn(Vector2i(70, 57), "light_infantry", 1)
		var state := m.build_state(7)
		var resolver := GameActionResolver.new(state)
		var learned := LearnedController.new(0)
		var actors := {}
		for decision in 60:
			if state.active_player() != 0:
				resolver.resolve(EndTurnIntent.new())
			var chosen := learned._decide(state)
			if chosen.is_empty() or chosen["intent"] is EndTurnIntent:
				printerr("large army prematurely passed at decision %d: %s" % [decision, learned._last_error])
				quit(1)
				return
			var intent: Intent = chosen["intent"]
			actors[intent.actor_id] = true
			var result := resolver.resolve(intent)
			if not result.ok:
				printerr("large-army action refused: " + result.reason)
				quit(1)
				return
			learned.notify_intent_accepted()
		if actors.size() < 12:
			printerr("large-army policy failed to use its army: " + str(actors.size()))
			quit(1)
			return
		print("large-army learned controller: %d units, 60 actions, %d actors, no premature end" % [count, actors.size()])
	quit(0)
