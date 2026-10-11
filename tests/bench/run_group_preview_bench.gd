extends SceneTree
## Informational wall-clock benchmark; no machine-dependent pass/fail threshold.
func _initialize() -> void: run.call_deferred()
func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	for count in [20, 100, 200]:
		var map := MapData.blank_arena(149, 119)
		for i in count: map.set_spawn(Vector2i(10 + i % 20, 10 + i / 20), "light_infantry", 0)
		map.set_spawn(Vector2i(140, 110), "light_infantry", 1)
		var state := map.build_state(12)
		state.turns.round_order.assign([0, 1])
		state.turns.active_index = 0
		var resolver := GameActionResolver.new(state)
		var ids: Array[int] = []
		for u in state.all_units():
			if u.owner == 0: ids.append(u.id)
		var preview := GroupMovePreview.new()
		for target in [Vector2i(34, 24), Vector2i(35, 25), Vector2i(80, 80)]:
			var slices := 0
			var longest := 0
			var cpu := 0
			while slices < 1000:
				var start := Time.get_ticks_usec()
				var ready := preview.sync(resolver, ids, target, false)
				var elapsed := Time.get_ticks_usec() - start
				cpu += elapsed
				longest = maxi(longest, elapsed)
				slices += 1
				if ready: break
				await process_frame
			print("%d soldiers target %s: %d frames, %.1f ms CPU, longest slice %.2f ms" % [count, target, slices, cpu/1000.0, longest/1000.0])
			if slices >= 1000:
				quit(1)
				return
	quit()
