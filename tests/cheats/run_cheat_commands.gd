extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	r.state.roster.slots[1].display_name = "Red Team"
	ck(CheatCommands.CATALOG.size() >= 50, "full command catalog")
	ck(CheatCommands.help_text("time").contains("morning, day, evening or night"), "time command is documented")
	ck(not CheatCommands.complete("time m", r.state, 0).is_empty(), "time values appear in suggestions")
	for entry: Dictionary in CheatCommands.CATALOG:
		if entry.get("hidden", false): continue
		ck(CheatCommands.help_text().contains(CheatCommands.syntax(entry)), "help documents " + entry.op)
	var parsed := CheatCommands.parse('SpAwN UnIt light_infantry "Red Team" 4 4', r.state, 0)
	ck(not parsed.has("error") and parsed.args.owner == 1, "case-insensitive keywords and exact quoted names")
	for bad: String in ["unknown", "unit kill 999999", "inspect cell -1 0", "spawn unit ../../file #1 2 2", "unit stat 0 armor 0", "unit stat 0 speed 1000", "unit stat 0 rof 101", "unit stat 0 sight 1025", "spawn unit light_infantry #1 0 0 101", "players; unit kill 0", 'inspect unit "0', "world gas add 23 19 2 2", "world fire clear 3", "event queue gas 3"]:
		ck(CheatCommands.parse(bad, r.state, 0).has("error"), "invalid grammar/bounds: " + bad)
	ck(CheatCommands.parse("units #2 page 3", r.state, 0).args.page == 3, "list pagination")
	ck(not CheatCommands.complete("spawn unit li", r.state, 0).is_empty(), "autocomplete from unit registry")
	ck(CheatCommands.complete("unit kill ", r.state, 0).is_empty(), "entity commands accept visible IDs without listing every unit")
	r.state.roster.slots[0].cheats_allowed = false
	ck(CheatCommands.parse("time day", r.state, 0).has("error"), "time changes require gameplay cheat permission")
	ck(CheatCommands.complete("unit kill ", r.state, 0).is_empty(), "unauthorized IDs do not leak through completion")
	ck(CheatCommands.parse("inspect unit 999999", r.state, 0).error.contains("permission"), "permission denial precedes private ID validation")
	ck(not CheatCommands.parse("players", r.state, 0).has("error"), "public roster query still available")
	ck(IntentCodec.decode({"t": "cheat", "op": "unit_ap", "args": [], "issuer": 0}) == null, "malformed wire rejected")
