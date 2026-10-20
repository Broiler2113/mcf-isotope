class_name DesyncReport
extends RefCounted

## Automatic desync report (2026-10, owner: sent silently, at most once per match, and
## Settings can switch it off). A guest whose board drifts from the host's heals itself with
## a full snapshot, so without this every desync — a rules bug — went unnoticed. The guest
## reports the board it drifted to; the host, asked for a snapshot, reports its own. Both
## carry the same match key, so the two boards can be decoded and diffed side by side.
##
## It goes to the bug-report server (NetHandoff.BUG_REPORTS) as an ordinary report: the
## description says what drifted, the log and combat log ride along, and the "replay" field
## holds JSON with the recent actions and the board as a packed checkpoint
## (ReplayCheckpoint.unpack reads it back).

static var endpoint := NetHandoff.BUG_REPORTS
const COMBAT_LINES := 300
const TIMEOUT := 40.0

## role: "guest" (its board drifted) or "host" (a guest asked it for a snapshot).
static func payload(role: String, state: GameState, resolver: GameActionResolver,
		fx: FxDecals, recent: Array, match_key: String) -> Dictionary:
	var last: Dictionary = recent.back() if not recent.is_empty() else {}
	var what := ""
	if role == "guest":
		if not bool(last.get("ok", true)):
			what = "the host's action was refused here: %s" % str(last.get("reason", ""))
		elif int(last.get("rolls_left", 0)) > 0:
			what = "%d of the host's dice were left unused" % int(last["rolls_left"])
		else:
			what = "board fingerprint %d here, %d on the host" % [int(last.get("h", 0)), int(last.get("want", 0))]
	else:
		what = "a guest asked for a full snapshot; board fingerprint here %d" % state.digest_hash()
	var data := {
		"kind": "desync", "role": role, "match": match_key, "protocol": NetHandoff.PROTOCOL,
		"round": state.turns.round_number, "active": state.active_player(),
		"digest": state.digest_hash(), "recent": recent,
		"board": ReplayCheckpoint.pack(state, resolver, fx, true),
	}
	var lines: Array = state.log.lines
	return {
		"description": "Automatic desync report (%s side), match %s, round %d: %s." % [
				role, match_key, state.turns.round_number, what],
		"version": str(ProjectSettings.get_setting("application/config/version", "dev")),
		"os": "%s %s · %s" % [OS.get_name(), OS.get_version(), RenderingServer.get_video_adapter_name()],
		"scene": "Desync (automatic)",
		"log": GameLog.text(),
		"combat_log": "\n".join(lines.slice(maxi(0, lines.size() - COMBAT_LINES))),
		"replay": JSON.stringify(data),
	}

## Send in the background. The request hangs off the scene tree's root, so leaving the
## battle does not cut it short; it frees itself when done. Failures only reach the log.
static func send(tree: SceneTree, doc: Dictionary) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("Desync report not delivered (result %d, HTTP %d)" % [result, code])
		http.queue_free())
	var start := func() -> void:
		if http.request(endpoint, ["Content-Type: application/json"], HTTPClient.METHOD_POST,
				JSON.stringify(doc)) != OK:
			push_warning("Desync report could not be sent")
			http.queue_free()
	http.tree_entered.connect(start, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	tree.root.add_child.call_deferred(http)
