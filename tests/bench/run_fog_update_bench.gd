extends SceneTree

## Cold and moving-army CPU timings; the visible-set hash guards semantic drift.
func _initialize() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var m := MapData.blank_arena(120, 100)
	for i in 100:
		m.set_spawn(Vector2i(8 + i % 10 * 3, 8 + i / 10 * 3), "light_infantry", 0)
	var state := m.build_state(49)
	var r := GameActionResolver.new(state)
	r.fog_enabled = true
	var start := Time.get_ticks_usec()
	r.team_visible_coords(0)
	print("fog cold: %.2f ms" % ((Time.get_ticks_usec() - start) / 1000.0))
	var times: Array[float] = []
	var result := 0
	for step in 20:
		var positions := {}
		for u: UnitInstance in state.all_units():
			positions[u.id] = u.coord + Vector2i(step % 2, 0)
		r.set_sight_positions(positions)
		start = Time.get_ticks_usec()
		var visible := r.team_visible_coords(0)
		times.append((Time.get_ticks_usec() - start) / 1000.0)
		result = visible.size()
	times.sort()
	print("fog moving 100 soldiers, 120x100: median %.2f ms, p95 %.2f ms, visible %d" % [times[10], times[18], result])
	var main: Node = load("res://scenes/Main.gd").new()
	main.state = state
	main.resolver = r
	times.clear()
	for step in 10:
		main._walk_cells = {state.all_units()[0].id: Vector2i(9 + step % 2, 8)}
		start = Time.get_ticks_usec()
		main._view_resolver().team_visible_coords(0)
		times.append((Time.get_ticks_usec() - start) / 1000.0)
		main._walk_cells.clear()
		main._view_resolver().team_visible_coords(0)
	times.sort()
	print("fog repeated walk entry: median %.2f ms, p95 %.2f ms" % [times[5], times[9]])
	main.free()
	quit()
