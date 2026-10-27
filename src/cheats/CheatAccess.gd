class_name CheatAccess
extends RefCounted

static func seated(state: GameState, side: int) -> bool:
	var slot := state.roster.slot(side)
	return slot != null and slot.kind == Roster.SlotKind.HUMAN

static func permitted(state: GameState, side: int) -> bool:
	return state.cheats_enabled and seated(state, side) and state.roster.slot(side).cheats_allowed

static func denial(state: GameState, side: int, admin := false, privileged := true) -> String:
	if not state.cheats_enabled: return "Cheats are disabled for this match. The host can enable them in the lobby."
	if not seated(state, side): return "Only seated human players may use the console."
	if privileged and not admin and not state.roster.slot(side).cheats_allowed:
		return "Your slot has no gameplay cheat permission. Ask the host to grant it."
	return ""

## The side typing into the console on this machine (Main as host).
static func console_side(host: Node) -> int:
	if host.net != null: return host.net.my_owner
	# A local hotseat keeps each seated human's own permissions. During AI turns,
	# keep the local lobby seat instead of borrowing the active AI's identity.
	var side: int = host.state.active_player()
	if seated(host.state, side): return side
	for slot: Roster.Slot in host.state.roster.slots:
		if slot.kind == Roster.SlotKind.HUMAN: return slot.id
	return -1

## A local game has no network host: its first human seat administers cheats (owner, 0.14.4).
static func local_admin(state: GameState, side: int) -> bool:
	for slot: Roster.Slot in state.roster.slots:
		if slot.kind == Roster.SlotKind.HUMAN: return slot.id == side
	return false

static func set_permission(state: GameState, target: int, allowed: bool, authority: bool, online := false) -> String:
	if not authority: return "Only the host can manage cheat permissions."
	if not state.cheats_enabled: return "Enable cheats in the lobby first."
	var slot := state.roster.slot(target)
	if slot == null: return "Unknown player slot."
	if allowed and (slot.kind != Roster.SlotKind.HUMAN or (online and slot.peer_id < 1)):
		return "Grant requires a connected, seated human player."
	slot.cheats_allowed = allowed
	return ""
