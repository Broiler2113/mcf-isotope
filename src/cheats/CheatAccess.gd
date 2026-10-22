class_name CheatAccess
extends RefCounted

static func seated(state: GameState, side: int) -> bool:
	var slot := state.roster.slot(side)
	return slot != null and slot.kind == Roster.SlotKind.HUMAN

static func permitted(state: GameState, side: int) -> bool:
	return state.cheats_enabled and seated(state, side) and state.roster.slot(side).cheats_allowed

static func denial(state: GameState, side: int, admin := false, privileged := true) -> String:
	if not state.cheats_enabled: return "Cheats are disabled. Enable cheats in the lobby."
	if not seated(state, side): return "Only seated human players may use the console."
	if privileged and not admin and not state.roster.slot(side).cheats_allowed:
		return "Your slot has no gameplay cheat permission. Ask the host to grant it."
	return ""

static func set_permission(state: GameState, target: int, allowed: bool, authority: bool, online := false) -> String:
	if not authority: return "Only the host can manage cheat permissions."
	if not state.cheats_enabled: return "Enable cheats in the lobby first."
	var slot := state.roster.slot(target)
	if slot == null: return "Unknown player slot."
	if allowed and (slot.kind != Roster.SlotKind.HUMAN or (online and slot.peer_id < 1)):
		return "Grant requires a connected, seated human player."
	slot.cheats_allowed = allowed
	return ""
