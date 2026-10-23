class_name MatchHistory
extends RefCounted

## Host testing history edits the replay prefix; ordinary Undo rules stay independent.
var source: Dictionary = {}
var cursor := -1
var revision := -1
var session_id := ""

func _sync(recorder: ReplayRecorder) -> void:
	if source.is_empty() or revision != recorder.revision:
		source = recorder.to_dict().duplicate(true)
		cursor = recorder.steps.size()
		revision = recorder.revision
	if session_id.is_empty():
		session_id = (JSON.stringify(recorder.start.get("dice", {})) + str(recorder.meta.get("saved_at", "")) + str(Time.get_ticks_usec())).sha256_text().left(24)

func position(recorder: ReplayRecorder) -> String:
	_sync(recorder)
	var before := 0
	var total := 0
	var steps: Array = source.get("steps", [])
	for i in steps.size():
		if steps[i].get("i", {}).get("t", "") == "checkpoint": continue
		total += 1
		if i < cursor: before += 1
	return "Match history: action %d of %d." % [before, total]

func step(recorder: ReplayRecorder, direction: int) -> Dictionary:
	_sync(recorder)
	var steps: Array = source.get("steps", [])
	var from := cursor
	if direction < 0:
		while from > 0 and steps[from - 1].get("i", {}).get("t", "") == "checkpoint": from -= 1
	var target := from + direction
	if direction > 0:
		while target <= steps.size() and steps[target - 1].get("i", {}).get("t", "") == "checkpoint": target += 1
	if target < 0: return {"error": "Already at the beginning of the recorded match."}
	if target > source.get("steps", []).size(): return {"error": "No forward action. New live actions replace the forward branch."}
	var player := ReplayPlayer.new(source)
	player.advance_random = true
	player.seek(target)
	if player.state == null or not player.seek_error.is_empty(): return {"error": "Could not restore this history position. " + player.seek_error}
	var fx := ReplayCheckpoint.effects(player.state)
	fx.from_dict(player.seek_decals)
	fx.apply(player.seek_fx)
	fx.advance(10.0)
	var frame := ReplayCheckpoint.pack(player.state, player.resolver, fx, false)
	return {"frame": frame, "recording": source, "cursor": target}

func applied(recorder: ReplayRecorder) -> void:
	revision = recorder.revision

func to_dict(recorder: ReplayRecorder) -> Dictionary:
	_sync(recorder)
	return {"source": source, "cursor": cursor, "session": session_id}

static func valid_recording(data: Variant) -> bool:
	return data is Dictionary and data.get("start") is Dictionary and not data.start.is_empty() and data.get("steps") is Array and data.get("rules") is Dictionary

func load_data(data: Dictionary, recorder: ReplayRecorder) -> void:
	source = data.source if valid_recording(data.get("source")) else {}
	cursor = clampi(int(data.get("cursor", 0)), 0, source.get("steps", []).size())
	session_id = str(data.get("session", ""))
	if session_id.length() != 24 or not session_id.is_valid_hex_number(false): session_id = ""
	revision = recorder.revision

func checkpoint(recorder: ReplayRecorder, state: GameState, resolver: GameActionResolver, fx: FxDecals, name: String) -> String:
	_sync(recorder)
	var filename := _filename(name)
	if filename.is_empty(): return "Choose a checkpoint name without path separators or reserved filename characters."
	var data := {"kind": "checkpoint", "session": session_id, "frame": ReplayCheckpoint.pack(state, resolver, fx, false),
		"recording": recorder.to_dict(), "cursor": recorder.steps.size()}
	return "Checkpoint '%s' saved." % name if ReplayFile.write(_directory().path_join(filename), data) else "Could not write the test checkpoint."

func restore_checkpoint(recorder: ReplayRecorder, name: String) -> Dictionary:
	_sync(recorder)
	var filename := _filename(name)
	if filename.is_empty(): return {"error": "Invalid checkpoint name."}
	var data := ReplayFile.read(_directory().path_join(filename))
	if data.get("kind", "") != "checkpoint" or data.get("session", "") != session_id: return {"error": "No checkpoint named '%s' in this match." % name}
	var packed: Variant = data.get("frame", {})
	var recording: Variant = data.get("recording", {})
	if not packed is Dictionary or not valid_recording(recording): return {"error": "This checkpoint is incomplete or unreadable."}
	var frame := ReplayCheckpoint.unpack(packed)
	if not frame.get("state") is Dictionary or not frame.get("rules") is Dictionary or not recording.get("steps") is Array: return {"error": "This checkpoint is incomplete or unreadable."}
	return {"frame": data.frame, "recording": data.get("recording", {}), "cursor": clampi(int(data.get("cursor", 0)), 0, recording.steps.size())}

func checkpoint_list(recorder: ReplayRecorder) -> String:
	_sync(recorder)
	var names := ReplayFile.list_files(_directory(), "mcfc")
	return "No test checkpoints in this match." if names.is_empty() else "Test checkpoints: " + ", ".join(Array(names).map(func(name: String) -> String: return name.get_basename()))

func _directory() -> String:
	return GameFolders.dir("Checkpoints").path_join(session_id)

static func _filename(name: String) -> String:
	var clean := name.strip_edges()
	if clean.is_empty() or clean.length() > 80: return ""
	for ch in clean:
		if ch.unicode_at(0) < 32 or ch in "/\\:*?\"<>|.": return ""
	return clean.to_lower() + ".mcfc"
