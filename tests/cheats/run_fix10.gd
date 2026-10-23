extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	for line: String in ["inspect unit", "inspect vehicle", "inspect cell"]:
		ck(CheatCommands.parse(line, r.state, 0).get("access") == "tool", "click tool " + line)
	ck(CheatCommands.complete("inspect unit ", r.state, 0).is_empty(), "no long unit-name picker")
	var at := CheatCommands.parse("inspect cell (3, 4)", r.state, 0)
	ck(at.args == {"x": 3, "y": 4}, "coordinates accept whitespace inside parentheses")
	var options := CheatCommands.complete("world floor (3, 4) gr", r.state, 0)
	ck(options.size() == 1 and options[0].insert == "world floor (3, 4) grass ", "completion keeps coordinate pairs intact")
	if options.size() == 1:
		ck(CheatCommands.parse(options[0].insert, r.state, 0).get("op") == "world_floor", "completed coordinate command parses")
	r.state.roster.slots[0].display_name = "(Red Team)"
	ck(CheatCommands.parse('units "(Red Team)" status', r.state, 0).get("args", {}).get("owner") == 0, "quoted player names are not mistaken for coordinates")
	for line: String in ["inspect cell (9999999999999999999999,2)", "inspect cell (3,4", "inspect cell (1.5,2)", "inspect cell (-1,2)", "world gas add (1,2) (24,4)"]:
		ck(CheatCommands.parse(line, r.state, 0).has("error"), "reject invalid coordinates " + line)
	command(r, "world smoke add (7,8) (5,6) 4")
	var cloud: Dictionary = r.random_events.smoke[0]
	ck(cloud.x == 5 and cloud.y == 6 and cloud.w == 3 and cloud.h == 3 and cloud.left == 4, "reversed corners define inclusive smoke rectangle")
	command(r, "event place gas (4,5) (6,8) 7")
	cloud = r.random_events.clouds[0]
	ck(cloud.x == 4 and cloud.y == 5 and cloud.w == 3 and cloud.h == 4 and cloud.left == 7, "explicit gas area is not recentered or resized")
	command(r, "event queue gas (8,9) (10,12) 6")
	var area: Dictionary = r.random_events.pending[0].params
	ck(area.x == 8 and area.y == 9 and area.w == 3 and area.h == 4 and area.rounds == 6, "queued event uses same corner convention")
	for cell: Vector2i in [Vector2i(4, 4), Vector2i(5, 5), Vector2i(6, 6)]: r._ignite(r.state.grid.cell(cell), 0)
	command(r, "world fire clear (4,4) (5,5)")
	ck(not r.state.grid.cell(Vector2i(5, 5)).on_fire and r.state.grid.cell(Vector2i(6, 6)).on_fire, "fire clearing uses inclusive area only")
	r.state.roster.slots[1].cheats_allowed = false
	ck(CheatCommands.parse("event place gas (4,5) (6,8)", r.state, 1).has("error"), "coordinate shortcut still enforces permission")
	command(r, "spawn unit engineer self (12,12)")
	command(r, "spawn unit light_infantry self (13,12)")
	var independent: UnitInstance = r.state.grid.cell(Vector2i(12, 12)).occupant
	ck(independent.owner == MCF.CHEAT_ARMY_OWNER and r.state.grid.cell(Vector2i(13, 12)).occupant.owner == independent.owner, "self spawns share one independent army")
	ck(not r.state.roster.are_allies(0, independent.owner) and not r.state.roster.are_allies(1, independent.owner), "independent army hostile to every player")
	ck(r.state.turns.round_order.count(independent.owner) == 1, "independent army has one AI turn slot")
	command(r, "spawn unit engineer #1 (14,12)")
	ck(r.state.grid.cell(Vector2i(14, 12)).occupant.owner == 0, "explicit player spawn remains available")
	await bodies()
	vehicle_bodies()
	corpse_replays()
	independent_turn()
	for feature: String in [MCF.FEATURE_CORPSE_WALL, MCF.FEATURE_LDF, MCF.FEATURE_DOT]:
		var cell := r.state.grid.cell(Vector2i(15, 15))
		cell.set_feature(feature)
		ck(r.fire_need(cell) == MCF.FIRE_NEVER, "fire cannot spread into " + feature)
		r._ignite(cell, 0)
		ck(not cell.on_fire and cell.feature_id == feature, "direct fire preserves " + feature)

func bodies() -> void:
	var r := fresh()
	var carrier := r.state.get_unit(0)
	var body := r.state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(3, 2), 1)
	r._kill(body)
	var id := body.id
	ck(r.resolve(PickUpCorpseIntent.new(carrier.id, body.coord)).ok, "pick up named body")
	ck(r.state.get_unit(id) == body and CorpseIdentity.id_label(body) == "U%d-" % id, "carried corpse keeps ID with dash")
	ck(r.resolve(MoveIntent.new(carrier.id, Vector2i(2, 4))).ok, "carrier moves")
	ck(CorpseIdentity.cell_of(r.state, body) == carrier.coord, "ID follows carrier instead of old corpse position")
	var copy := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state))))
	ck(copy.digest_hash() == r.state.digest_hash() and CorpseIdentity.cell_of(copy, copy.get_unit(id)) == carrier.coord, "carried identity survives save and network snapshot")
	ck(CheatQueries.inspect_at(r, carrier.coord, 0, "unit").contains("U%d-" % id), "click inspection includes carried body")
	ck(CheatCommands.parse("inspect unit U%d-" % id, r.state, 0).args.unit == id, "corpse ID can be typed directly")
	var dest := Vector2i(3, 4)
	r.state.grid.cell(dest).is_space = true
	ck(r.resolve(DropCorpseIntent.new(carrier.id, dest)).ok, "named body drops onto space")
	ck(CorpseIdentity.cell_of(r.state, body) == dest and body.corpse_carrier_id == -1, "dropped ID follows body")
	ck(r.resolve(UndoIntent.new()).ok and body.corpse_carrier_id == carrier.id, "undo restores carried identity")
	ck(r.resolve(RedoIntent.new()).ok and CorpseIdentity.cell_of(r.state, body) == dest, "redo restores dropped identity")
	carrier.remaining_ap = 3
	ck(r.resolve(PickUpCorpseIntent.new(carrier.id, dest)).ok, "pick body from pile again")
	r._kill(carrier)
	ck(CorpseIdentity.cell_of(r.state, body) == carrier.coord and body.corpse_carrier_id == -1, "carrier death drops named body")

func vehicle_bodies() -> void:
	for in_arms in [false, true]:
		var r := fresh()
		var carrier := r.state.get_unit(0)
		var tank := r.state.spawn_vehicle("tank", Vector2i(3, 2), 0)
		var crew := r.state.spawn_unit(carrier.stats, tank.origin, 0, false)
		crew.aboard_vehicle_id = tank.id
		tank.occupants.append(crew.id)
		r.state.dice.feed_scripted([1, 1])
		r._tank_crew_hit(tank, ActionResult.success())
		ck(crew.status == MCF.Status.CORPSE and tank.corpse_slots.size() == 1, "tank crew leaves an identified body")
		var dest := carrier.coord if in_arms else Vector2i(1, 2)
		r.state.grid.cell(Vector2i(1, 2)).is_space = true
		ck(r.resolve(VehicleUnloadCorpseIntent.new(carrier.id, tank.id, dest)).ok, "unload named tank body")
		ck(CorpseIdentity.cell_of(r.state, crew) == dest and crew.aboard_vehicle_id == -1, "unloaded tank ID follows body")
		ck(crew.corpse_carrier_id == (carrier.id if in_arms else -1), "tank body preserves carrying relationship")
		ck(r.state.grid.cell(dest).occupant == (carrier if in_arms else null), "unloaded pile cannot overwrite an occupant")
		var copy := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state))))
		ck(CorpseIdentity.cell_of(copy, copy.get_unit(crew.id)) == dest, "unloaded tank identity survives save")

func corpse_replays() -> void:
	for legacy in [false, true]:
		var r := fresh()
		r.legacy_corpse_rules = legacy
		var carrier := r.state.get_unit(0)
		var body := r.state.spawn_unit(carrier.stats, Vector2i(3, 2), 1)
		r._kill(body)
		var recorder := ReplayRecorder.new()
		recorder.begin(r.state, r)
		r.replay_recorder = recorder
		ck(r.resolve(PickUpCorpseIntent.new(carrier.id, body.coord)).ok, "record corpse pickup")
		ck(r.resolve(DropCorpseIntent.new(carrier.id, Vector2i(3, 3))).ok, "record corpse drop")
		var data: Dictionary = JSON.parse_string(JSON.stringify(recorder.to_dict()))
		ck(data.corpse_rules == 1, "new recordings declare corpse identity rules")
		if legacy: data.erase("corpse_rules")
		var playback := ReplayPlayer.new(data)
		playback.seek(playback.step_count())
		ck(playback.state.digest_hash() == r.state.digest_hash(), "new and historical corpse replays keep exact state")
		ck((playback.state.get_unit(body.id) == null) == legacy, "historical replays retain their original anonymous bodies")
		var cell := playback.state.grid.cell(Vector2i(5, 5))
		cell.set_feature(MCF.FEATURE_CORPSE_WALL)
		ck(playback.resolver.fire_need(cell) == (MCF.FIRE_NEED_WALL if legacy else MCF.FIRE_NEVER), "replay fire rules match recording version")

func independent_turn() -> void:
	var r := fresh()
	command(r, "spawn unit light_infantry self (4,2)")
	var soldier: UnitInstance = r.state.grid.cell(Vector2i(4, 2)).occupant
	r.state.turns.active_index = r.state.turns.round_order.find(MCF.CHEAT_ARMY_OWNER)
	var result := r.play_civilian_slots()
	ck(result.dice_events.any(func(event: Dictionary): return event.get("kind") == "focus" and event.get("unit") == soldier.id), "independent spawn takes AI actions on its own turn")
	ck(r.state.active_player() != MCF.CHEAT_ARMY_OWNER, "independent turn returns control to a player")
