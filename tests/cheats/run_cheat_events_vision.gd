extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	var twin := fresh()
	for event: Array in RandomEvents.REGISTRY:
		ck(CheatCommands.parse("event queue " + event[0], r.state, 0).op == "event_queue", "registered event " + event[0])
	for line: String in ["event queue gas 10 10", "event queue mortar 10 10", "event queue dust"]:
		command(r, line)
		command(twin, line)
	ck(r.random_events.pending == twin.random_events.pending, "forced event parameters deterministic")
	ck(r.state.dice.checkpoint() == twin.state.dice.checkpoint(), "forced event shared dice stream")
	ck(not r.random_events.enabled, "forcing leaves automatic events disabled")
	for entry: Dictionary in r.random_events.pending:
		ck(entry.land == r.state.turns.round_number, "warning uses normal round-end delay")
	rejected(r, "event queue bounty")
	command(r, "event queue army 2 2")
	ck(r.random_events.pending.back().params.x == 2, "army supports a direct entry coordinate")
	ck(CheatCommands.parse("event cancel 0", r.state, 0).has("error"), "the hidden pending index is not typed")
	command(r, "event remove warning:%d" % r.random_events.pending[0].uid)
	ck(r.random_events.pending.size() == 3, "cancel one warning")
	command(r, "event cancel all")
	ck(r.random_events.pending.is_empty(), "cancel all warnings")
	r.fog_enabled = true
	r.fog_mode = MCF.Fog.STANDARD
	command(r, "unit stat 0 sight 1")
	command(r, "unit stat 1 sight 1")
	var distant := Vector2i(12, 10)
	ck(not r.team_sees(0, distant), "initial fog")
	command(r, "vision reveal A")
	ck(r.team_sees(0, distant) and r.team_knows(0, distant) and r.is_visible_to_team(0, r.state.get_unit(1)), "vision changes view and target knowledge")
	ck(not r.team_sees(1, distant), "no other-side reveal leak")
	r.state.grid.cell(distant).set_feature(MCF.FEATURE_MINE, 1)
	command(r, "vision mines A on")
	ck(r.mine_visible_to(0, distant), "mine override")
	command(r, "vision mines a off")
	ck(not r.mine_visible_to(0, distant), "mine override reset")
	command(r, "vision reset A")
	ck(not r.team_sees(0, distant) and r.fog_mode == MCF.Fog.STANDARD, "reveal reset restores original fog")
