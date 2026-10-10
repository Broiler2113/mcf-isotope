class_name ReplayBookmarks
extends RefCounted

## One registry for live recording and legacy migration. No kill/combat bookmarks.
const EVENTS := {
	"mortar": {"announce": "⚠ Artillery Barrage —", "land": "Artillery Barrage hits zone", "label": "Artillery Barrage"},
	"gas": {"announce": "⚠ Gas Cloud —", "land": "Gas Cloud settles over zone", "label": "Gas Cloud"},
	"army": {"announce": "⚠ Independent Army —", "land": "— Raiders ", "label": "Independent Army"},
}

static func append(out: Array, index: int, round_no: int, owner: int,
		previous_round: int, previous_owner: int, lines: Array) -> void:
	if round_no != previous_round:
		out.append({"index": index, "round": round_no, "label": "Round %d begins" % round_no})
	if MCF.is_player(owner) and (owner != previous_owner or round_no != previous_round):
		out.append({"index": index, "round": round_no,
				"label": "%s's turn - round %d" % [MCF.owner_name(owner), round_no]})
	for line: String in lines:
		for event: Dictionary in EVENTS.values():
			var label := ""
			if line.begins_with(event.announce):
				label = event.label + " incoming"
			elif line.begins_with(event.land) and (event.label != "Independent Army" or line.contains(" land on the ")):
				label = event.label + " lands"
			if label != "":
				out.append({"index": index, "round": round_no, "label": "%s - round %d" % [label, round_no]})

static func neighbor(entries: Array, index: int, direction: int, total: int) -> int:
	if direction < 0:
		for i in range(entries.size() - 1, -1, -1):
			if int(entries[i].index) < index:
				return clampi(int(entries[i].index), 0, total)
		return 0
	for entry: Dictionary in entries:
		if int(entry.index) > index:
			return clampi(int(entry.index), 0, total)
	return total
