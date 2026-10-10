class_name ReplayMigration
extends RefCounted

static func needed(data: Dictionary) -> bool:
	return str(data.get("kind", "")) == ReplayFile.KIND_REPLAY and (
		int(data.get("schema", 0)) < ReplayRecorder.SCHEMA or not data.get("bookmarks") is Array
		or int(data.get("seek_version", 0)) < 1)

## One silent pass builds bookmarks and dense seek checkpoints together.
## Failure leaves the original file intact; the replay remains usable in memory.
static func upgrade(data: Dictionary, path: String = "") -> Dictionary:
	if not needed(data) or int(data.get("schema", 0)) > ReplayRecorder.SCHEMA:
		return data
	var player := ReplayPlayer.new(data)
	player.seek(0)
	if player.state.dice.fallback_rolls > 0 or player.state.dice.scripted_remaining() > 0:
		push_warning("Replay opening differs from its recorded dice; original file preserved")
		return data
	var entries: Array = []
	var round_no := player.state.turns.round_number
	var owner := player.state.active_player()
	ReplayBookmarks.append(entries, 0, round_no, owner, -1, -1,
			player.opening_result.log_lines if player.opening_result != null else [])
	var fx := ReplayCheckpoint.effects(player.state)
	ReplayCheckpoint.apply_effects(fx, player.opening_result)
	var frames := {}
	var frame_at := 0
	while player.has_next():
		var result := player.play_next()
		if result == null or not result.ok or player.state.dice.fallback_rolls > 0 \
				or player.state.dice.scripted_remaining() > 0:
			push_warning("Replay upgrade stopped at action %d; original file preserved" % player.index)
			return data
		ReplayBookmarks.append(entries, player.index, player.state.turns.round_number,
				player.state.active_player(), round_no, owner, result.log_lines)
		round_no = player.state.turns.round_number
		owner = player.state.active_player()
		ReplayCheckpoint.apply_effects(fx, result)
		var step: Dictionary = player.steps()[player.index - 1]
		var handoff := str(step.get("i", {}).get("t", "")) == IntentCodec.T_END
		if handoff or player.index - frame_at >= ReplayCheckpoint.ACTION_INTERVAL:
			frames[player.index - 1] = ReplayCheckpoint.pack(player.state, player.resolver, fx, not handoff)
			frame_at = player.index
	# Commit only a complete scan. Do not duplicate the whole replay in memory.
	var steps: Array = data.get("steps", [])
	for i in steps.size():
		steps[i].erase("k")
		if frames.has(i):
			steps[i]["k"] = frames[i]
	data["bookmarks"] = entries
	data["schema"] = ReplayRecorder.SCHEMA
	data["seek_version"] = 1
	if path != "" and not ReplayFile.write(path, data):
		push_warning("Replay upgrade is available for this session but could not be saved")
	return data
