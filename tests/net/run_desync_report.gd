extends SceneTree

## Automatic desync reports (DesyncReport, 2026-10).
##
##   1. Host and guest NetGames in one process keep their last actions with the board
##      fingerprints; in step they agree.
##   2. A guest whose board drifted raises desync_detected while the drifted board is still
##      there, then asks for a snapshot; the host raises resync_requested; afterwards the
##      boards agree again.
##   3. The guest's report says what drifted and carries the drifted board (it unpacks to a
##      state with the drifted fingerprint) and the recent actions; the host's report too.
##   4. Sent to a local copy of the bug server, the report is accepted and stored.

const TS = preload("res://tests/TestSupport.gd")
const PORT := 18651

var fails: PackedStringArray = []
var _pending: Intent = null
var _server_pid := -1
var _dir := ""
var _wait := 0.0
var _sent := false

func _initialize() -> void:
	_check_reports()
	if not fails.is_empty():
		_finish()
		return
	_start_server()

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _check_reports() -> void:
	var hs := TS.build_state()
	var gs := TS.build_state()
	var host := NetGame.new(hs, GameActionResolver.new(hs), true, 0)
	var guest := NetGame.new(gs, GameActionResolver.new(gs), false, 1)
	host.outgoing.connect(func(msg: Dictionary) -> void:
		var m := msg.duplicate()
		m["_from"] = 1
		guest.receive(m))
	guest.outgoing.connect(func(msg: Dictionary) -> void:
		var m := msg.duplicate()
		m["_from"] = 2
		host.receive(m))
	var guest_reports: Array = []
	var host_reports: Array = []
	var drifted_digest := [0]
	guest.desync_detected.connect(func() -> void:
		drifted_digest[0] = gs.digest_hash()
		guest_reports.append(DesyncReport.payload("guest", gs, guest.resolver, FxDecals.new(), guest.recent.duplicate(true), "test")))
	var asked_by: Array = []
	host.resync_requested.connect(func(from: int) -> void:
		asked_by.append(from)
		host_reports.append(DesyncReport.payload("host", hs, host.resolver, FxDecals.new(), host.recent.duplicate(true), "test")))
	var ai := {}
	for side in [0, 1]:
		var brain := AIController.new(side, AIController.Difficulty.NORMAL)
		brain.intent_ready.connect(func(i: Intent) -> void: _pending = i)
		ai[side] = brain
	var played := 0
	for step in 40:
		_pending = null
		var side: int = hs.active_player()
		if ai.has(side):
			ai[side].begin_turn(hs)
		host.submit_local(_pending if _pending != null else EndTurnIntent.new())
		played += 1
		if step == 24:
			ck(guest_reports.is_empty() and asked_by.is_empty(), "no report while the boards agree")
			var last: Dictionary = guest.recent.back()
			ck(int(last["want"]) == int(last["h"]) and last["ok"], "in step, the guest's fingerprint is the host's")
			ck(host.recent.size() == NetGame.RECENT_MAX and guest.recent.size() == NetGame.RECENT_MAX,
					"both sides keep the last %d actions" % NetGame.RECENT_MAX)
			# Drift the guest: one of its soldiers stands somewhere else.
			for u: UnitInstance in gs.all_units():
				if not u.is_alive() or not gs.grid.in_bounds(u.coord):
					continue
				var to := u.coord + Vector2i(1, 0)
				if gs.grid.in_bounds(to) and gs.grid.cell(to).is_empty() and gs.grid.cell(to).corpse_count == 0:
					gs.grid.move_occupant(u.coord, to)
					break
	ck(guest_reports.size() == 1, "the drifted guest reported once (%d)" % guest_reports.size())
	ck(asked_by == [2], "the host heard the guest ask for a snapshot (%s)" % str(asked_by))
	ck(gs.digest_hash() == hs.digest_hash(), "after the snapshot the boards agree again")
	if guest_reports.is_empty() or host_reports.is_empty():
		return
	var doc: Dictionary = guest_reports[0]
	ck(str(doc["description"]).begins_with("Automatic desync report (guest side)"), "the description says what it is")
	ck(str(doc["scene"]) == "Desync (automatic)", "reports are marked as automatic desyncs")
	var data: Variant = JSON.parse_string(str(doc["replay"]))
	ck(data is Dictionary and data.get("kind") == "desync" and data.get("role") == "guest", "the replay field is the desync record")
	if data is Dictionary:
		var recent: Array = data["recent"]
		ck(not recent.is_empty() and int(recent.back()["want"]) != int(recent.back()["h"]),
				"the last action shows the host's and the drifted fingerprint")
		# The fingerprint the guest computed as it applied the action, before any snapshot.
		var drifted := int(recent.back()["h"]) if not recent.is_empty() else 0
		var frame := ReplayCheckpoint.unpack(data["board"])
		var board: GameState = StateCodec.decode(frame.get("state", {})) if not frame.is_empty() else null
		ck(board != null and board.digest_hash() == drifted, "the packed board is the drifted one")
		ck(int(data["digest"]) == drifted and drifted_digest[0] == drifted, "the record names the drifted fingerprint")
	var hdoc: Dictionary = host_reports[0]
	var hdata: Variant = JSON.parse_string(str(hdoc["replay"]))
	ck(hdata is Dictionary and hdata.get("role") == "host" and hdata.get("match") == "test", "the host files its own board under the same match key")
	_doc = doc

var _doc: Dictionary = {}

func _start_server() -> void:
	_dir = OS.get_cache_dir().path_join("mcf_desync_test_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_dir)
	var script := ProjectSettings.globalize_path("res://tools/bugs/isotope_bugs.py")
	_server_pid = OS.create_process("python3", [script, "--host", "127.0.0.1", "--port", str(PORT), "--dir", _dir])
	ck(_server_pid > 0, "the local bug server started")
	DesyncReport.endpoint = "http://127.0.0.1:%d/report" % PORT

func _process(delta: float) -> bool:
	if _server_pid <= 0:
		return false
	_wait += delta
	if not _sent and _wait > 1.0:
		_sent = true
		DesyncReport.send(self, _doc)
	var stored := _stored_replays()
	if not stored.is_empty() or _wait > 20.0:
		ck(stored.size() == 1, "the server stored the report (%d)" % stored.size())
		if stored.size() == 1:
			ck(FileAccess.get_file_as_string(stored[0]).contains("\"desync\""), "its replay.json is the desync record")
		OS.kill(_server_pid)
		_server_pid = -1
		_finish()
	return false

func _stored_replays() -> Array:
	var out: Array = []
	for day in DirAccess.get_directories_at(_dir):
		for report in DirAccess.get_directories_at(_dir.path_join(day)):
			var path := _dir.path_join(day).path_join(report).path_join("replay.json")
			if FileAccess.file_exists(path):
				out.append(path)
	return out

func _finish() -> void:
	if _dir != "":
		_remove_tree(_dir)
	if fails.is_empty():
		print("desync report: fingerprints kept; drift reported once from each side with the drifted board; the server stores it")
		quit(0)
		return
	printerr("desync report: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func _remove_tree(path: String) -> void:
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
