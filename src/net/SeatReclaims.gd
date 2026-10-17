class_name SeatReclaims
extends RefCounted

## Host-only, match-scoped identity and handback queue. No simulation changes here.
var seats: Dictionary = {}  # token -> formerly human side
var offers: Dictionary = {} # peer -> {side, round, accepted}

func reserve(identity: String, side: int) -> void:
	if not identity.is_empty(): seats[identity] = side

func offer(peer: int, identity: String, roster: Roster, round_number: int, ended: bool) -> Dictionary:
	if ended: return {"error": "This match has ended."}
	var side := int(seats.get(identity, -1))
	var slot := roster.slot(side)
	if slot == null or slot.kind != Roster.SlotKind.AI:
		return {"error": "No disconnected seat matches this connection. The host may have started another match."}
	for other in offers:
		if int(other) != peer and int(offers[other].side) == side:
			return {"error": "Your seat already has a pending reconnect."}
	offers[peer] = {"side": side, "round": round_number, "accepted": false}
	return {"side": side, "name": roster.name_of(side)}

func accept(peer: int, round_number: int) -> bool:
	if not offers.has(peer): return false
	offers[peer].accepted = true
	offers[peer].round = round_number
	return true

func due(round_number: int) -> Array[int]:
	var out: Array[int] = []
	for peer in offers:
		if offers[peer].accepted and round_number > int(offers[peer].round): out.append(int(peer))
	return out

func forget(peer: int) -> void:
	offers.erase(peer)
