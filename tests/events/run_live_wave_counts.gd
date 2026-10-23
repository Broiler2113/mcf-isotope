extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.game_mode = MatchMode.Kind.HOLDOUT
	var roster := Roster.default_duel(false)
	roster.add_slot(Roster.SlotKind.AI)
	roster.set_waves(2)
	var state := GameState.new(60, 40, 512)
	state.roster = roster
	state.turns.round_order.assign([0, 1, 2])
	var r := GameActionResolver.new(state)
	r.mode.kind = MatchMode.Kind.HOLDOUT
	r.mode.wave_side = 2
	r.mode.wave = 11
	for i in 161:
		state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(10 + i % 23, 8 + i / 23), i % 2)
	var size := r.wave_size_details(12)
	ck(size.defenders == 161 and size.target == 290 and is_equal_approx(size.multiplier, 1.8), "161 co-op survivors yield 290 enemies on wave 12")
	r._announce_wave(ActionResult.success([]))
	ck(r.mode.pending_wave.target == 290, "announcement freezes the visible target")
	r._kill(state.get_unit(0), null, state.get_unit(0).coord)
	ck(r.wave_size_details(12).defenders == 160, "later waves use surviving soldiers, not original army or corpses")
	r._land_wave(ActionResult.success([]))
	ck(r.mode.wave_sizes["12"] == 290 and r.mode.wave_details["12"].placed == 290, "full announced wave lands with varied troop costs")
	ck(r.wave_size_details(13).target == 304, "next wave uses 160 surviving defenders × 1.9")
	r.mode.wave_start = 1.2
	r.mode.wave_growth = 0.25
	ck(r.wave_size_details(3).target == 272, "custom base and growth use all surviving defenders")
	r.mode.wave_growth = 0.0
	ck(r.wave_size_details(99).target == 192, "zero growth keeps the selected multiplier constant")
	var saved := r.mode.snapshot()
	var restored := MatchMode.new()
	restored.restore(saved)
	ck(restored.wave_growth == 0.0 and restored.wave_start == 1.2, "custom wave settings survive rules snapshots")
	GameConfig.holdout_wave_growth = 0.35
	var lobby := NetHandoff.encode_rules()
	GameConfig.holdout_wave_growth = 0.1
	NetHandoff.apply_rules(lobby, false)
	ck(GameConfig.holdout_wave_growth == 0.35 and MatchMode.from_config().wave_growth == 0.35, "host growth reaches guests and new matches")
	NetHandoff.apply_rules({}, false)
	ck(GameConfig.holdout_wave_growth == MatchMode.WAVE_GROWTH, "older lobby data restores the original growth")
	ck(LobbySettings.with_rules({"hg": 0.7}, {"mode": {}}).hg == MatchMode.WAVE_GROWTH, "legacy saved rules override newer lobby defaults")
	ck(MatchMode.clean_wave_growth(NAN) == MatchMode.WAVE_GROWTH and MatchMode.clean_wave_growth(-1.0) == 0.0, "invalid growth is bounded")
	ck(not MatchMode.new().snapshot().has("wave_growth"), "default rule snapshots keep existing replay hashes")
	var old := {"mode": {"kind": MatchMode.Kind.HOLDOUT, "wave": 12, "wave_side": 2, "defender_value": 200}}
	StateCodec.apply_rules(r, old)
	ck(r.mode.live_wave_counts and r.wave_size_details(13).target == 304, "older saves adopt current-count sizing without restarting progress")
	# A narrow landing strip expands to safe cells elsewhere along the same edge.
	var small := GameActionResolver.new(GameState.new(20, 20, 82))
	small.state.roster = roster
	small.mode.kind = MatchMode.Kind.HOLDOUT
	small.mode.wave_side = 2
	small.mode.pending_wave = {"edge": 0, "from": 0, "len": 1, "target": 90, "defenders": 50, "multiplier": 1.8}
	small._land_wave(ActionResult.success([]))
	ck(small.mode.wave_sizes["1"] == 90, "landing width does not silently cap a wave")
