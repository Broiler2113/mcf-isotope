extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	for type: String in VehicleDB.ids():
		if type == "borg": continue
		var before := r.state.all_vehicles().size()
		var args := {"type": type, "owner": 0, "x": 8, "y": 6}
		var out := r.resolve(CheatIntent.new("spawn_vehicle", args, 0))
		ck(out.ok, "spawn real vehicle " + type)
		if not out.ok: continue
		var veh: Vehicle = r.state.all_vehicles()[before]
		command(r, "vehicle move %d 12 10" % veh.id)
		ck(r.state.grid.vehicle_at(Vector2i(8, 6)) == -1 and r.state.grid.vehicle_at(Vector2i(12, 10)) == veh.id, "footprint moves: " + type)
		rejected(r, "vehicle move %d 23 19" % veh.id)
		for comp: String in veh.components:
			command(r, "vehicle component %d %s restore" % [veh.id, comp])
		command(r, "vehicle repair %d" % veh.id)
		command(r, "vehicle clone %d 5 5" % veh.id)
		command(r, "vehicle remove %d" % r.state.all_vehicles().back().id)
		command(r, "vehicle owner %d #2" % veh.id)
		r.state.dice.begin_record()
		command(r, "vehicle destroy %d" % veh.id)
		ck(not r.state.dice.take_log().is_empty(), "destruction uses shared dice")
		r.state.dice.record_enabled = false
		command(r, "vehicle remove %d" % veh.id)
	command(r, "spawn vehicle borg #1 2 2")
	var borg: Vehicle = r.state.all_vehicles()[0]
	ck(r.state.get_unit(0).borg_id == borg.id and borg.borg_operator() == 0, "Borg operator links")
	rejected(r, "vehicle remove %d" % borg.id)
	command(r, "unit invulnerable 0 on")
	command(r, "vehicle destroy %d" % borg.id)
	ck(r.state.get_unit(0).is_alive() and r.state.get_unit(0).borg_id == -1, "protected Borg operator survives with link cleaned")
	_protected_crew()

func _protected_crew() -> void:
	for type: String in ["tank", "shuttle"]:
		var r := fresh()
		command(r, "spawn vehicle %s #1 3 2" % type)
		var vehicle: Vehicle = r.state.all_vehicles()[0]
		var crew := r.state.get_unit(0)
		command(r, "unit invulnerable 0 on")
		var boarded := r.resolve(VehicleBoardIntent.new(crew.id, vehicle.id))
		ck(boarded.ok and vehicle.occupants.has(crew.id), "protected crew boards " + type + ": " + boarded.reason)
		if not boarded.ok: continue
		crew.cheat_stats.armor = 12
		if type == "tank":
			r._tank_crew_hit(vehicle, ActionResult.success())
			ck(crew.is_alive() and vehicle.occupants.has(crew.id), "protected crew survives direct hull casualty")
		var result := command(r, "vehicle destroy %d" % vehicle.id)
		ck(crew.is_alive() and not result.deaths.has(crew.id), "protected crew survives destroyed " + type)
		ck(r.state.grid.in_bounds(crew.coord) and r.state.grid.cell(crew.coord).occupant == crew, "protected crew retains valid occupancy after " + type)
		ck(crew.aboard_vehicle_id == -1 and not vehicle.occupants.has(crew.id), "destroyed vehicle releases protected crew: " + type)
