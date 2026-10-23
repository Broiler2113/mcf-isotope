extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	var recorder := ReplayRecorder.new()
	recorder.begin(r.state, r)
	recorder.capture_opening()
	r.replay_recorder = recorder
	for line: String in ["spawn unit engineer #1 6 6 3", "unit stat 0 sight 7", "unit invulnerable 0 on", "vision reveal #2", "vision mines #1 on", "world floor-look 8 8 4", "world smoke add 8 8 3 3 2", "event queue gas", "world time night", "unit ap 1 7"]:
		command(r, line)
	# Administration is deliberately outside gameplay history.
	r.state.roster.slots[0].cheats_allowed = false
	r.state.roster.slots[1].cheats_allowed = false
	var saved: Dictionary = JSON.parse_string(JSON.stringify(StateCodec.encode(r.state)))
	var loaded := StateCodec.decode(saved)
	ck(loaded.digest_hash() == r.state.digest_hash(), "save preserves all persistent cheat effects")
	ck(not loaded.roster.slots[0].cheats_allowed, "save preserves revocation")
	ck(loaded.get_unit(0).cheat_invulnerable and loaded.get_unit(0).sight() == 7, "protected stats roundtrip")
	var data: Dictionary = JSON.parse_string(JSON.stringify(recorder.to_dict()))
	var playback := ReplayPlayer.new(data)
	playback.seek(playback.step_count())
	ck(playback.state.digest_hash() == r.state.digest_hash(), "replay reproduces authorized actions despite later revoked rights")
	ck(playback.state.dice.fallback_rolls == 0 and playback.state.dice.scripted_remaining() == 0, "replay consumes exact recorded dice")
	ck(JSON.parse_string(JSON.stringify(playback.resolver.random_events.snapshot())) == JSON.parse_string(JSON.stringify(r.random_events.snapshot())), "replay restores clouds and pending events")
	for key: String in ["cheats_enabled", "cheat_sequence", "cheat_vision", "cheat_mines"]: saved.erase(key)
	for unit: Dictionary in saved.units: unit.erase("cheat_stats"); unit.erase("cheat_invulnerable")
	var legacy := StateCodec.decode(saved)
	ck(not legacy.cheats_enabled and legacy.cheat_vision.is_empty() and not legacy.get_unit(0).cheat_invulnerable, "legacy saves default to no cheat effects")
	saved.cheats_enabled = "true"
	saved.cheat_sequence = {}
	saved.cheat_vision = {"0": true, "-99": true, "2": "true"}
	saved.units[0].cheat_stats = {"speed": 99999, "armor": -20, "sight": "bad", "unknown": 10}
	saved.units[0].cheat_invulnerable = "true"
	var malformed := StateCodec.decode(saved)
	ck(not malformed.cheats_enabled and malformed.cheat_sequence == 0, "malformed optional state safely disabled")
	ck(malformed.get_unit(0).speed() == 999 and malformed.get_unit(0).armor() == 1 and malformed.get_unit(0).cheat_stats.size() == 2, "malformed stats clamped and filtered")
