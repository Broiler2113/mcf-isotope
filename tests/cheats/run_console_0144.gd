extends "res://tests/cheats/CheatSuite.gd"

## 0.14.4 console rules (owner): player letters, independent, short vehicle IDs,
## in-game names, help topics, AI pacing keeps Undo, console with cheats off.
func run() -> void:
	var r := fresh()
	r.state.roster.slots[1].display_name = "Red Team"
	# Players are letters; independent is the army hostile to everyone; self is gone.
	command(r, "spawn unit light_infantry a 5 5")
	ck(r.state.grid.cell(Vector2i(5, 5)).occupant.owner == 0, "a lowercase letter names Player A")
	command(r, "spawn unit light_infantry independent 6 5")
	ck(r.state.grid.cell(Vector2i(6, 5)).occupant.owner == MCF.CHEAT_ARMY_OWNER, "independent spawns the independent army")
	ck(CheatCommands.parse("spawn unit light_infantry self 7 5", r.state, 0).has("error"), "self is no longer a player")
	command(r, 'unit owner U0 "red team"')
	ck(r.state.get_unit(0).owner == 1, "player names match in any letter case")
	command(r, "unit owner U0 A")
	ck(not CheatCommands.parse("vision reveal all", r.state, 0).has("error"), "all still names every player")
	# Parentheses are optional; the pending index is not typed; edges and sides by name.
	command(r, "unit stat change U0 armor 5")
	command(r, "unit stat change U0 armor (4)")
	ck(r.state.get_unit(0).armor() == 4, "stat value with or without parentheses")
	command(r, "unit ap U0 (3)")
	ck(r.state.get_unit(0).remaining_ap == 3, "parentheses accepted on any number")
	command(r, "event queue army 2 2")
	var uid := int(r.random_events.pending[0].uid)
	command(r, "event set warning:%d edge west" % uid)
	ck(int(r.random_events.pending[0].params.edge) == 3, "event set takes an edge name")
	ck(CheatCommands.parse("event cancel 0", r.state, 0).has("error") and not CheatCommands.parse("event cancel all", r.state, 0).has("error"), "only event cancel all is typed")
	command(r, "event cancel all")
	# Short vehicle IDs.
	command(r, "spawn vehicle tank A 10 10")
	var tank: Vehicle = r.state.all_vehicles()[0]
	ck(CheatCommands.vehicle_label(tank.id) == "V0", "the first vehicle is V0")
	ck(CheatQueries.run(r, CheatCommands.parse("vehicles", r.state, 0), 0).contains("V0 | tank"), "lists show the short ID")
	command(r, "vehicle repair V0")
	command(r, "vehicle repair V%d" % tank.id)
	ck(CheatCommands.parse("vehicle repair 0", r.state, 0).args.vehicle == tank.id, "bare short number names the vehicle")
	# Console words and in-game names: ldf and dpmg replace bru and rsp; names work too.
	command(r, "world feature set 14 4 ldf")
	ck(r.state.grid.cell(Vector2i(14, 4)).feature_id == MCF.FEATURE_LDF, "ldf is the LDF")
	command(r, "world feature set 15 4 dpmg")
	ck(r.state.grid.cell(Vector2i(15, 4)).feature_id == MCF.FEATURE_DPMG, "dpmg is the stationary machine gun")
	ck(CheatCommands.parse("world feature set 16 4 rsp", r.state, 0).has("error") and CheatCommands.parse("unit item U0 bru", r.state, 0).has("error"), "internal ids are not console words")
	command(r, 'world feature set 16 4 "anti-tank hedgehog"')
	ck(r.state.grid.cell(Vector2i(16, 4)).feature_id == MCF.FEATURE_HEDGEHOG, "in-game names are accepted")
	command(r, "unit item U0 ldf")
	ck(r.state.get_unit(0).held_item_id == MCF.ITEM_LDF, "ldf item")
	var labels: Array = CheatCommands.complete("world feature set 1 1 ", r.state, 0).map(func(o): return o.label)
	ck(labels.has("ldf") and labels.has("dpmg - DPMG (Machine Gun)") and labels.has("hedgehog - Anti-Tank Hedgehog") and not labels.has("bru"), "completion shows console words with in-game names: %s" % [labels])
	var types := CheatCommands.unit_types()
	ck(types.size() == {}.merged(Array(types).reduce(func(acc, t): acc[t] = true; return acc, {})).size() and not types.has("assault"), "unit types are unique")
	ck(not CheatCommands.complete("event spawn army {units:{li", r.state, 0).is_empty(), "unit types complete inside units braces")
	ck(CheatCommands.complete("event spawn army {ed", r.state, 0)[0].insert.ends_with("{edge:"), "option names complete inside braces")
	# Help topics.
	ck(CheatCommands.help_text().begins_with("Topic | Commands") and CheatCommands.help_text().split("\n").size() < 20, "help lists topics")
	ck(CheatCommands.help_text("spawn").contains("Unit types:") and CheatCommands.help_text("event").contains("hx - "), "topic help names unit types and event options")
	ck(CheatCommands.help_text("time").contains("morning"), "a command word still works as a topic")
	# Admin commands are hidden from those who cannot use them.
	var guest: Array = CheatCommands.complete("cheats ", r.state, 1, null, false, false).map(func(o): return o.label)
	ck(not guest.has("grant") and guest.has("status"), "guests do not see permission commands")
	ck(CheatAccess.local_admin(r.state, 0) and not CheatAccess.local_admin(r.state, 1), "a local game's first human seat administers")
	# AI pacing keeps Undo and stays out of the shared log.
	r.state.roster.slots[1].kind = Roster.SlotKind.AI
	r.resolve(MoveIntent.new(0, r.state.get_unit(0).coord + Vector2i.RIGHT))
	ck(r.can_undo(), "a move is undoable")
	var paused := command(r, "ai pause B")
	ck(r.can_undo() and paused.log_lines.is_empty(), "AI pause keeps Undo and posts no [CHEAT] line")
	command(r, "ai speed 2")
	ck(r.can_undo(), "AI speed keeps Undo")
	GameConfig.ai_speed = 1.0
	var changed := command(r, "unit ap U0 2")
	ck(not r.can_undo() and changed.log_lines[0].begins_with("[CHEAT]"), "a gameplay cheat still clears Undo and is announced")
	# With cheats off only help and clear answer.
	r.state.cheats_enabled = false
	ck(CheatCommands.parse("players", r.state, 0).has("error") and not CheatCommands.parse("help", r.state, 0).has("error"), "disabled cheats leave help only")
	ck(CheatCommands.complete("p", r.state, 0).is_empty() and not CheatCommands.complete("h", r.state, 0).is_empty(), "disabled cheats suggest help only")
