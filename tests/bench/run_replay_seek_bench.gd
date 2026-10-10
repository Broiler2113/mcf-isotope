extends SceneTree
func _initialize() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapData.blank_arena(149, 119)
	for owner in 2:
		for i in 200:
			map.set_spawn(Vector2i(4 + (i % 20) * 3, 4 + (i / 20) * 3 + owner * 60), "light_infantry", owner)
	var s := map.build_state(951)
	s.turns.round_order.assign([0, 1])
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	r.track_undo_history = false # fixture never records undo; avoid allocating discarded history
	var rec := ReplayRecorder.new()
	rec.begin(s, r)
	r.replay_recorder = rec
	var start := Time.get_ticks_msec()
	for turn in 8:
		for u in s.all_units():
			if u.owner != s.active_player(): continue
			for dir in [Vector2i.RIGHT, Vector2i.LEFT]:
				var result := r.resolve(MoveIntent.new(u.id, u.coord + dir))
				if not result.ok:
					printerr(result.reason)
					quit(1)
					return
		r.resolve(EndTurnIntent.new(s.active_player()))
		print("recorded turn ", turn, " ms=", Time.get_ticks_msec()-start)
	var data := rec.to_dict()
	var f := FileAccess.open('user://replay-seek-benchmark.json', FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	var player := ReplayPlayer.new(data)
	for target in [3000, 1500, 3001]:
		start = Time.get_ticks_msec()
		player.seek(target)
		print("seek target=", target, " ms=", Time.get_ticks_msec()-start, " catch_up=", player.last_seek_actions, " steps=", data.steps.size())
	quit()
