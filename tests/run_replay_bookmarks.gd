extends SceneTree

const TS = preload("res://tests/TestSupport.gd")
var failures: Array[String] = []
func ck(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		printerr("FAIL: " + message)
func _initialize() -> void:
	_run.call_deferred()

func _fixture(interval: int = 1) -> Array:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var map := MapData.blank_arena(24, 20)
	map.set_spawn(Vector2i(1, 1), "light_infantry", 0)
	map.set_spawn(Vector2i(22, 18), "light_infantry", 1)
	var state := map.build_state(412)
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	var resolver := GameActionResolver.new(state)
	resolver.random_events = RandomEvents.new(interval > 0, true, maxi(1, interval), {RandomEvents.GAS: 1})
	var recorder := ReplayRecorder.new()
	recorder.begin(state, resolver)
	recorder.capture_opening()
	return [state, resolver, recorder]

func _run() -> void:
	var pair := _fixture()
	var state: GameState = pair[0]
	var resolver: GameActionResolver = pair[1]
	var recorder: ReplayRecorder = pair[2]
	ck(recorder.bookmarks.any(func(e): return e.index == 0 and e.label == "Gas Cloud incoming - round 1"), "opening event is bookmarked at zero")
	ck(recorder.bookmarks.any(func(e): return e.index == 0 and e.label == "Player A's turn - round 1"), "opening player's turn is bookmarked")
	resolver.resolve(EndTurnIntent.new(0))
	ck(recorder.bookmarks.any(func(e): return e.index == 1 and e.label == "Gas Cloud lands - round 1"), "gas landing is bookmarked after its action")
	ck(recorder.bookmarks.any(func(e): return e.index == 1 and e.label == "Player B's turn - round 1"), "next player's turn has its own bookmark")
	resolver.resolve(EndTurnIntent.new(1))
	ck(recorder.bookmarks.any(func(e): return e.index == 2 and e.label == "Round 2 begins"), "round bookmark uses completed-step index")
	var labels: Array = []
	ReplayBookmarks.append(labels, 12, 7, 0, 7, 0, [
		"⚠ Artillery Barrage — zone", "Artillery Barrage hits zone (1, 1)",
		"⚠ Independent Army — north", "— Raiders II land on the north edge: 4 fighters, hostile to everyone —",
		"light infantry killed", "Unknown forces turn back — nowhere to land on that edge"])
	ck(labels.size() == 4 and labels[1].label == "Artillery Barrage lands - round 7", "registry matches artillery and army triggers, excluding kills and failed landings")
	var quiet := _fixture(0)
	for i in 4: quiet[1].resolve(EndTurnIntent.new(-1))
	var quiet_marks: Array = quiet[2].bookmarks
	ck(quiet_marks.filter(func(e): return e.label.begins_with("Round ")).size() == 3, "events-off recordings still bookmark each round")
	ck(quiet_marks.filter(func(e): return e.label.begins_with("Player ")).size() == 5, "events-off recordings bookmark player turns")
	_migration(recorder.to_dict())
	_neighbors(quiet_marks, 4)
	await _ui(quiet[2].to_dict())
	print("replay bookmarks: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _migration(fresh: Dictionary) -> void:
	var legacy := fresh.duplicate(true)
	legacy.schema = 1
	legacy.erase("bookmarks")
	legacy.erase("seek_version")
	for step: Dictionary in legacy.steps: step.erase("k")
	var path := "user://replays/bookmarks-migration-test.mcfr"
	ck(ReplayFile.write(path, legacy), "legacy fixture writes")
	var migrated := ReplayFile.read_replay(path)
	ck(migrated.get("bookmarks", []) == fresh.bookmarks, "migration and live recording produce identical bookmarks")
	var disk := ReplayFile.read(path)
	ck(int(disk.schema) == ReplayRecorder.SCHEMA and disk.has("bookmarks"), "migration rewrites the compressed replay")
	ck(not ReplayMigration.needed(disk), "second load skips migration")
	var before := FileAccess.get_file_as_bytes(path)
	ReplayFile.read_replay(path)
	ck(before == FileAccess.get_file_as_bytes(path), "second load leaves the file unchanged")
	var unwritable := ReplayMigration.upgrade(legacy.duplicate(true), "/proc/isotope-bookmarks-test.mcfr")
	ck(unwritable.has("bookmarks"), "failed persistence still exposes bookmarks this session")
	var invalid := legacy.duplicate(true)
	invalid.steps.append({"i": {"t": "unknown_action"}, "r": []})
	ck(ReplayFile.write(path, invalid), "invalid replay fixture writes")
	var original := FileAccess.get_file_as_bytes(path)
	ReplayFile.read_replay(path)
	ck(FileAccess.get_file_as_bytes(path) == original, "failed replay scan never replaces original file")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path + ReplayFile.NOTE_EXT)

func _neighbors(entries: Array, total: int) -> void:
	ck(ReplayBookmarks.neighbor(entries, 0, -1, total) == 0, "previous clamps at start")
	ck(ReplayBookmarks.neighbor(entries, total, 1, total) == total, "next clamps at end")
	ck(ReplayBookmarks.neighbor(entries, 1, 1, total) == 2, "next skips entries at the same action")
	ck(ReplayBookmarks.neighbor(entries, 2, -1, total) == 1, "previous skips entries at the same action")

func _ui(data: Dictionary) -> void:
	SaveHandoff.pending_replay = data
	var board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	var row := -1
	for i in data.bookmarks.size():
		if int(data.bookmarks[i].index) == 2: row = i
	board._on_replay_bookmark(row)
	var digest: String = TS.digest(board.state)
	ck(board.replay.index == 2, "clicking bookmark seeks to its step")
	board._replay_seek(0)
	board._on_replay_slider(2)
	await create_timer(0.18).timeout
	ck(board.replay.index == 2 and TS.digest(board.state) == digest, "slider and bookmark produce the same board")
	ck(board._replay_bookmarks.get_selected_items().size() == 1, "bookmark selection follows timeline")
	# A long visual walk must not make a bookmark click disappear or keep playing.
	var unit: UnitInstance = board.state.all_units()[0]
	var path: Array[Vector2i] = []
	for i in 40: path.append(unit.coord + Vector2i(i % 2, 0))
	board._play_dice([{"kind": "walk", "unit": unit.id, "from": unit.coord, "path": path, "soldier": true}])
	ck(board._animating, "fixture starts a long playback animation")
	board._replay_seek(0)
	board._replay_seek(4)
	await create_timer(0.3).timeout
	ck(not board._animating and board.replay.index == 4, "seeking during animation finishes it and honors latest destination")
	board.queue_free()
	await process_frame
