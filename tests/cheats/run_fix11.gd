extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var precision := DiceService.new(9223372036854775701)
	precision.roll_d6_many(7)
	var precise_state := GameState.new(4, 4)
	precise_state.dice = precision
	var roundtrip := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(precise_state))))
	ck(roundtrip.dice.current_seed() == precision.current_seed() and roundtrip.dice.checkpoint().rng == precision.checkpoint().rng, "64-bit random seeds survive checkpoint/save JSON without rounding")
	var r := fresh()
	command(r, "unit stat change U0 armor (6)")
	ck(r.state.get_unit(0).armor() == 6, "armor value is the minimum defense roll")
	command(r, "unit stat change U0 armor 6")
	ck(r.state.get_unit(0).armor() == 6, "stat values need no parentheses")
	rejected(r, "unit stat change U0 armor (0)")
	rejected(r, "unit stat change U0 armor (13)")
	command(r, "event spawn army {edge:east, units:{machinegunner:15,civilian:10}}")
	var force := {}
	var army := -1
	for unit: UnitInstance in r.state.all_units():
		if MCF.is_independent(unit.owner):
			army = unit.owner
			force[unit.stats.id] = int(force.get(unit.stats.id, 0)) + 1
	ck(force == {"machinegunner": 15, "civilian": 10}, "raiders have the exact requested composition")
	command(r, "spawn unit engineer independent (8,8)")
	var self_color := r.state.roster.color_of(MCF.CHEAT_ARMY_OWNER)
	ck(self_color != r.state.roster.color_of(army), "self army and raiders have different colors")
	for side: int in [MCF.CHEAT_ARMY_OWNER, army]:
		for slot: Roster.Slot in r.state.roster.slots:
			if slot.is_playing(): ck(r.state.roster.color_of(side) != slot.color, "independent color avoids players")
	var copy := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state))))
	ck(copy.roster.color_of(MCF.CHEAT_ARMY_OWNER).is_equal_approx(self_color), "independent color survives save roundtrip")
	command(r, "event spawn reinforce {player:#1, at:(12,12), units:{machinegunner:3,civilian:2}}")
	var own := {}
	for unit: UnitInstance in r.state.all_units():
		if unit.owner == 0: own[unit.stats.id] = int(own.get(unit.stats.id, 0)) + 1
	ck(own.get("machinegunner", 0) == 3 and own.get("civilian", 0) == 2, "reinforcements use the chosen player and exact units")
	rejected(r, "event spawn army {units:{scout_drone:2}}")
	rejected(r, "event spawn army {count:25,units:{machinegunner:2}}")
	rejected(r, "event spawn army {at:(999,12),count:2}")
	var body := r.state.spawn_unit(r.state.get_unit(0).stats, Vector2i(5, 15), 1)
	r._kill(body)
	command(r, "spawn vehicle tank #1 (5,15)")
	ck(r.state.grid.cell(Vector2i(5, 15)).occupant == body, "spawning a vehicle preserves the corpse underneath")
	palette_exhausted()
	history()

func palette_exhausted() -> void:
	var roster := Roster.new()
	for color: Color in Roster.PALETTE:
		var side := roster.add_slot(Roster.SlotKind.HUMAN)
		roster.slot(side).color = color
	roster.assign_independent_color(MCF.CHEAT_ARMY_OWNER, 17)
	roster.assign_independent_color(MCF.independent_slot(1), 17)
	var a := roster.color_of(MCF.CHEAT_ARMY_OWNER)
	var b := roster.color_of(MCF.independent_slot(1))
	ck(a != b, "full palette still gives independent forces different colors")
	for color: Color in Roster.PALETTE: ck(a != color and b != color, "full palette fallback uses an unused color")

func history() -> void:
	var r := fresh()
	var recorder := ReplayRecorder.new()
	recorder.begin(r.state, r)
	r.replay_recorder = recorder
	ck(r.resolve(MoveIntent.new(0, Vector2i(3, 2))).ok, "record a move with dice")
	ck(r.resolve(UndoIntent.new()).ok and r.resolve(RedoIntent.new()).ok, "ordinary Undo and Redo remain replayable")
	command(r, "event spawn gas (15,5) (16,6) 3")
	ck(r.state.dice.own_rolls > 0, "history test has real RNG consumption")
	command(r, "unit stat change U0 armor (12)")
	var before_turn := r.state.digest_hash()
	ck(r.resolve(EndTurnIntent.new()).ok, "record a turn transition")
	command(r, "spawn unit engineer #2 (18,14)")
	var final := r.state.digest_hash()
	var dice_position := r.state.dice.checkpoint()
	var timeline := MatchHistory.new()
	var back := timeline.step(recorder, -1, true)
	ck(not back.has("error"), "undo takes back the last console command")
	apply_history(r, recorder, timeline, back)
	ck(timeline.step(recorder, -1, true).has("error"), "undo refuses to rewind an ordinary action")
	back = timeline.step(recorder, -1)
	apply_history(r, recorder, timeline, back)
	ck(r.state.digest_hash() == before_turn, "history can cross a turn boundary")
	ck(timeline.step(recorder, 1, true).has("error"), "redo refuses to replay an ordinary action")
	for i in 2:
		var forward := timeline.step(recorder, 1, i == 1)
		ck(not forward.has("error"), "forward branch remains available")
		apply_history(r, recorder, timeline, forward)
	ck(r.state.digest_hash() == final, "forward restores the original board")
	ck(r.state.dice.checkpoint().rng == dice_position.rng, "history restores the actual RNG position")
	var fx := ReplayCheckpoint.effects(r.state)
	ck(timeline.checkpoint(recorder, r.state, r, fx, "test scenario").contains("saved"), "named checkpoint is written separately")
	command(r, "unit stat change U0 armor (2)")
	var restore := timeline.restore_checkpoint(recorder, "test scenario")
	apply_history(r, recorder, timeline, restore)
	ck(r.state.digest_hash() == final, "checkpoint restore recovers the complete tested board")
	back = timeline.step(recorder, -1)
	apply_history(r, recorder, timeline, back)
	command(r, "unit stat change U0 armor (3)")
	ck(timeline.step(recorder, 1).has("error"), "new live actions replace the forward branch")
	var player := ReplayPlayer.new(JSON.parse_string(JSON.stringify(recorder.to_dict())))
	player.seek(player.step_count())
	ck(player.state.digest_hash() == r.state.digest_hash(), "edited history remains a valid replay")

func apply_history(r: GameActionResolver, recorder: ReplayRecorder, timeline: MatchHistory, result: Dictionary) -> void:
	ck(not result.has("error"), "history result is valid")
	if result.has("error"): return
	var frame := ReplayCheckpoint.unpack(result.frame)
	StateCodec.restore_into(r.state, frame.state)
	r.state.dice.resume_random()
	StateCodec.apply_rules(r, frame.rules)
	recorder.adopt_prefix(result.recording, int(result.cursor), r.state, r, frame.get("fx", {}))
	timeline.source = result.recording
	timeline.cursor = int(result.cursor)
	timeline.applied(recorder)
