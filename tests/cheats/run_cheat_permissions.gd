extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	GameConfig.cheats_enabled = false
	ck(not GameState.new(2, 2).cheats_enabled, "master defaults off")
	ck(not Roster.Slot.new().cheats_allowed, "legacy/new generic slots default denied")
	var r := fresh()
	ck(not CheatAccess.set_permission(r.state, 1, true, false, true).is_empty(), "guest cannot grant")
	r.state.roster.slots[0].cheats_allowed = false
	ck(CheatAccess.set_permission(r.state, 1, true, true, true).is_empty(), "host can administer with own rights off")
	ck(not CheatAccess.permitted(r.state, 0), "host has no implicit gameplay bypass")
	ck(CheatAccess.set_permission(r.state, 1, false, true).is_empty(), "revoke permitted")
	ck(not CheatAccess.permitted(r.state, 1), "revocation immediate")
	for kind in [Roster.SlotKind.AI, Roster.SlotKind.CLOSED, Roster.SlotKind.OPEN]:
		r.state.roster.slots[1].kind = kind
		r.state.roster.slots[1].cheats_allowed = true
		ck(not CheatAccess.permitted(r.state, 1), "non-human cannot use gameplay cheats")
		ck(not CheatAccess.set_permission(r.state, 1, true, true).is_empty(), "cannot grant non-human")
	r.state.roster.slots[1].kind = Roster.SlotKind.HUMAN
	r.state.roster.slots[1].peer_id = -1
	ck(not CheatAccess.set_permission(r.state, 1, true, true, true).is_empty(), "cannot grant disconnected online slot")
	r.state.cheats_enabled = false
	ck(not CheatAccess.set_permission(r.state, 1, true, true).is_empty(), "master disabled blocks grants")
	ck(not CheatAccess.permitted(r.state, -2), "spectator denied")
