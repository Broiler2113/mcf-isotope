extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	for line: String in ["inspect", "spawn unit engineer #1", "spawn vehicle tank #2"]:
		var parsed := CheatCommands.parse(line, r.state, 0)
		ck(not parsed.has("error") and parsed.access == "tool", "interactive command: " + line)
	for line: String in ["event spawn gas", "event edit gas:1 {rounds:5}", "event remove gas:1"]:
		var event := CheatCommands.parse(line, r.state, 0)
		ck(not event.has("error") and event.access == "play", "event management is a complete command: " + line)
	var parsed := CheatCommands.parse("units A status", r.state, 0)
	ck(parsed.op == "units_status", "player status grammar")
	var summary := CheatQueries.run(r, parsed, 0)
	ck(summary.contains("Entire board") and summary.contains("light_infantry | 2 | 0 | 2"), "counts include player and board totals")
	command(r, "unit kill U1")
	summary = CheatQueries.run(r, parsed, 0)
	ck(summary.contains("light_infantry | 1 | 1 | 2"), "alive/dead counts reflect corpses")
	ck(CheatCommands.parse("inspect unit U0", r.state, 0).args.unit == 0, "displayed IDs accepted verbatim")
	var veh := r.state.spawn_vehicle("tank", Vector2i(10, 10), 0)
	veh.components[MCF.COMP_HULL] = 2
	command(r, "vehicle durability V%d" % veh.id)
	ck(veh.durability == veh.component_max(MCF.COMP_HULL), "simple durability restore")
	var inspected := CheatQueries.inspect_at(r, Vector2i(11, 11), 0)
	ck(inspected.contains(CheatCommands.vehicle_label(veh.id)) and inspected.contains("Stats:"), "inspect any footprint tile includes vehicle stats")
	ck(CheatQueries.run(r, CheatCommands.parse("vehicles a status", r.state, 0), 0).contains("tank | 1 | 0 | 1"), "vehicle counts")
	r.state.roster.slots[1].kind = Roster.SlotKind.AI
	command(r, "ai pause #2")
	ck(r.state.cheat_ai_paused.has(1), "pause stored per AI player")
	rejected(r, "ai pause A")
	rejected(r, "ai step #2")
	r.state.turns.active_index = 1
	command(r, "ai step #2")
	ck(r.state.cheat_ai_paused.has(1), "single step leaves AI paused")
	var saved := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state))))
	ck(saved.cheat_ai_paused.has(1) and saved.digest_hash() == r.state.digest_hash(), "paused AI survives save/resync")
	var resumed := GameActionResolver.new(saved)
	StateCodec.apply_rules(resumed, {"cheats": false})
	ck(saved.cheat_ai_paused.is_empty(), "disabling cheats when loading releases paused AI")
	command(r, "ai resume #2")
	ck(r.state.cheat_ai_paused.is_empty(), "resume clears selected pause")
	var guest := NetGame.new(r.state, r, false, 0)
	ck(not guest.cheat_denial(CheatIntent.new("ai_pause", {"owner": 1}, 0), 0, false).is_empty(), "guests cannot pause shared AI")
	var docs: Array = load("res://src/ui/ManualText.gd").sections()
	var cheats := ""
	for section: Array in docs:
		if section[0] == "Cheats": cheats = section[1]
	for entry: Dictionary in CheatCommands.CATALOG:
		if entry.get("hidden", false): continue
		ck(cheats.contains(entry.help), "manual explains " + entry.op)
