class_name CheatEventModel
extends RefCounted

## What each event option means, for help and completion.
const OPTION_HELP := {
	"at": "target cell as (x,y)",
	"x": "left column of the area, or the entry column",
	"y": "top row of the area, or the entry row",
	"w": "area width in cells",
	"h": "area height in cells",
	"rounds": "duration in rounds",
	"edge": "landing edge: north, east, south or west",
	"from": "first cell of the landing strip along the edge",
	"len": "landing strip length in cells",
	"hx": "bunker hallway entry column",
	"hy": "bunker hallway entry row",
	"units": "exact force, such as units:{machinegunner:15,civilian:10}",
	"count": "number of soldiers",
	"player": "player letter that receives reinforcements",
	"side": "player letter that receives reinforcements",
	"budget": "reinforcement points to spend",
	"unit": "U-ID of the bounty target",
}
## How an event is aimed when spawned or queued.
const AREA_EVENTS := ["mortar", "gas", "fire", "emp", "collapse"]
const POINT_EVENTS := ["army", "reinforce", "minefield", "bounty"]

## Commands expose only properties consumed by ResolverEvents and RandomEvents.
static func schema(id: String, r: GameActionResolver, props: Dictionary = {}) -> Dictionary:
	var w := r.state.grid.width
	var h := r.state.grid.height
	var fields := {}
	if id in [RandomEvents.MORTAR, RandomEvents.GAS, RandomEvents.FIRE, RandomEvents.EMP, RandomEvents.COLLAPSE, "smoke"]:
		fields = {"x": [0, w - 1], "y": [0, h - 1], "w": [1, w], "h": [1, h]}
	if id in [RandomEvents.GAS, RandomEvents.DUST, "smoke", RandomEvents.BOUNTY]: fields.rounds = [1, 100]
	if id in [RandomEvents.ARMY, RandomEvents.REINFORCE]:
		fields = {"edge": [0, 3], "from": [0, maxi(w, h) - 1], "len": [1, maxi(w, h)],
			"x": [0, w - 1], "y": [0, h - 1], "count": [1, 10000], "units": []}
		if props.has("hx"): fields.merge({"hx": [0, w - 1], "hy": [0, h - 1]})
		if id == RandomEvents.REINFORCE:
			fields.merge({"side": [0, MCF.MAX_PLAYERS - 1], "budget": [1, 1000000]})
	if id == RandomEvents.BOUNTY: fields.unit = [0, Vehicle.ID_BASE - 1]
	return fields

static func validate(id: String, props: Dictionary, r: GameActionResolver) -> String:
	var fields := schema(id, r, props)
	for key: String in props:
		if not fields.has(key): return "%s does not support '%s'." % [RandomEvents.event_name(id), key]
		if key == "units":
			if not props.units is Dictionary or props.units.is_empty(): return "Supply unit types and counts."
			var total := 0
			for type: String in props.units:
				if type in [MCF.DRONE_STATS_ID, MCF.SCOUT_DRONE_STATS_ID]: return "Deploy drones through spawn unit with a linked operator and station."
				if r._army_stats(type) == null or not CheatCommands._integer(props.units[type]) or props.units[type] < 1: return "Invalid unit type or count: " + type
				total += int(props.units[type])
			if total > 10000 or (props.has("count") and total != props.count): return "The force composition must match its count and contain at most 10000 units."
			continue
		if not CheatCommands._integer(props[key]) or props[key] < fields[key][0] or props[key] > fields[key][1]:
			return "%s must be %d–%d." % [key, fields[key][0], fields[key][1]]
	if (props.has("w") and int(props.get("x", 0)) + int(props.w) > r.state.grid.width) or (props.has("h") and int(props.get("y", 0)) + int(props.h) > r.state.grid.height):
		return "The complete event area must fit on the board."
	if props.has("edge"):
		var along := r.state.grid.width if int(props.edge) % 2 == 0 else r.state.grid.height
		if int(props.get("from", 0)) + int(props.get("len", 1)) > along: return "The landing segment extends beyond the selected edge."
	if props.has("hx") != props.has("hy"): return "Supply both hallway coordinates."
	if id in [RandomEvents.ARMY, RandomEvents.REINFORCE] and props.has("x") != props.has("y"): return "Supply both entry coordinates."
	if props.has("hx") and not r._open_floor(Vector2i(props.hx, props.hy)): return "The hallway entry must be on open ground."
	if props.has("side") and not r.state.roster.player_ids().has(int(props.side)): return "Reinforcements require a playable side."
	if props.has("unit"):
		var unit := r.state.get_unit(props.unit)
		if unit == null or not unit.is_alive() or unit.is_drone or not MCF.is_player(unit.owner): return "The bounty target must be a living player soldier."
	return ""

static func entries(r: GameActionResolver) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var events := r.random_events
	if events == null: return out
	for entry: Dictionary in events.pending:
		out.append({"ref": "warning:%d" % entry.uid, "event": entry.id, "phase": "pending", "properties": entry.params.duplicate()})
	for pair: Array in [["gas", events.clouds], ["smoke", events.smoke]]:
		for cloud: Dictionary in pair[1]:
			out.append({"ref": "%s:%d" % [pair[0], cloud.uid], "event": pair[0], "phase": "active", "properties": {"x": cloud.x, "y": cloud.y, "w": cloud.w, "h": cloud.h, "rounds": cloud.left}})
	if events.dust_left > 0: out.append({"ref": "dust", "event": "dust", "phase": "active", "properties": {"rounds": events.dust_left}})
	if r.mode.bounty_unit >= 0:
		out.append({"ref": "bounty", "event": "bounty", "phase": "active", "properties": {"unit": r.mode.bounty_unit, "rounds": maxi(1, r.mode.bounty_until - r.state.turns.round_number + 1)}})
	var armies := {}
	for unit: UnitInstance in r.state.all_units():
		if unit.is_alive() and MCF.is_independent(unit.owner): armies[unit.owner] = true
	var sides := armies.keys()
	sides.sort()
	for side: int in sides:
		out.append({"ref": "army:%d" % side, "event": "army", "phase": "active force", "properties": {}})
	var fires := 0
	var mines := 0
	for cell: GridCell in r.state.grid.cells_flat():
		if cell.on_fire and cell.fire_owner == r.EVENT_FIRE_OWNER: fires += 1
		if cell.feature_id in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE] and cell.feature_owner == r.OLD_MINE_OWNER: mines += 1
	if fires > 0: out.append({"ref": "fire", "event": "fire", "phase": "all %d event-fire cells" % fires, "properties": {}})
	if mines > 0: out.append({"ref": "minefield", "event": "minefield", "phase": "all %d old mines" % mines, "properties": {}})
	return out

static func find(r: GameActionResolver, ref: String) -> Dictionary:
	for entry: Dictionary in entries(r):
		if entry.ref == ref: return entry
	return {}

static func list_text(r: GameActionResolver) -> String:
	var out: Array[String] = ["Reference | Event | State | Supported properties"]
	for entry: Dictionary in entries(r):
		out.append("%s | %s | %s | %s" % [entry.ref, RandomEvents.event_name(entry.event), entry.phase, entry.properties])
	if out.size() == 1: return "No active events or pending warnings. Use event types to browse available events."
	out.append("Use event edit <reference> {options} or event remove <reference>. Completed instant effects are not reversible.")
	return "\n".join(out)

static func at_cell(r: GameActionResolver, at: Vector2i) -> Array[String]:
	var refs: Array[String] = []
	if not r.state.grid.in_bounds(at): return refs
	for entry: Dictionary in entries(r):
		var p: Dictionary = entry.properties
		if p.has("w") and Rect2i(p.x, p.y, p.w, p.h).has_point(at): refs.append(entry.ref)
		elif p.has("edge") and r.army_landing_rect(p).has_point(at): refs.append(entry.ref)
		elif p.has("unit"):
			var target := r.state.get_unit(p.unit)
			if target != null and target.coord == at: refs.append(entry.ref)
		elif entry.ref.begins_with("army:"):
			var cell := r.state.grid.cell(at)
			if cell.occupant != null and cell.occupant.owner == int(entry.ref.get_slice(":", 1)): refs.append(entry.ref)
		elif entry.ref == "fire":
			var cell := r.state.grid.cell(at)
			if cell.on_fire and cell.fire_owner == r.EVENT_FIRE_OWNER: refs.append(entry.ref)
		elif entry.ref == "minefield":
			var cell := r.state.grid.cell(at)
			if cell.feature_id in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE] and cell.feature_owner == r.OLD_MINE_OWNER: refs.append(entry.ref)
	# Global dust is selected only when no smaller event occupies the cell.
	if refs.is_empty() and r.random_events.dust_left > 0: refs.append("dust")
	return refs
