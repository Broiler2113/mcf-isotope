extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	command(r, "world feature set 8 8 airlock")
	ck(r.state.grid.cell(Vector2i(8, 8)).feature_id == MCF.FEATURE_AIRLOCK, "real feature registry")
	command(r, "world clear-cell 8 8")
	for fid: String in Furniture.ids():
		if Furniture.is_wall_light(fid): continue
		command(r, "world furniture set 8 8 %s 1" % fid)
		var piece := r.furniture_piece(Vector2i(8, 8))
		ck(not piece.is_empty(), "complete furniture " + fid)
		var last: Vector2i = piece.back()
		command(r, "world furniture set %d %d none" % [last.x, last.y])
		for at: Vector2i in piece: ck(r.state.grid.cell(at).feature_id.is_empty(), "pair cleanup " + fid)
	command(r, "world floor 8 8 flammable")
	command(r, "world floor-look 8 8 2")
	ck(r.state.grid.cell(Vector2i(8, 8)).floor_type == MCF.FLOOR_FLAMMABLE, "appearance preserves flammability")
	command(r, "world fire set 8 8 on")
	ck(r.state.grid.cell(Vector2i(8, 8)).on_fire, "ignite uses shared rules")
	command(r, "world fire clear 8 8 0")
	ck(not r.state.grid.cell(Vector2i(8, 8)).on_fire, "bounded fire clear")
	command(r, "world space 8 8 on")
	ck(r.state.grid.cell(Vector2i(8, 8)).is_space, "space state applied")
	rejected(r, "world feature set 8 8 wall")
	rejected(r, "world space 2 2 on")
	rejected(r, "world feature set 2 2 wall")
	r.state.grid.cell(Vector2i(1, 1)).set_feature(MCF.FEATURE_BOUNDARY)
	rejected(r, "world clear-cell 1 1")
	command(r, "world gas add 10 10 2 3 5")
	command(r, "world smoke add 12 12 2 2 2")
	ck(r.state.grid.cell(Vector2i(10, 10)).gas and r.state.grid.cell(Vector2i(12, 12)).smoke, "clouds refresh visibility flags")
	command(r, "world gas clear")
	command(r, "world smoke clear")
	ck(not r.state.grid.cell(Vector2i(10, 10)).gas and not r.state.grid.cell(Vector2i(12, 12)).smoke, "clearing refreshes flags")
	command(r, "world winter on")
	command(r, "world time night")
	ck(r.state.winter and r.state.time_of_day == "night", "world presentation state")
	for environment: String in ["town", "field"]:
		r.state.env = environment
		for time: String in MapData.TIMES:
			command(r, "time " + time)
			ck(r.state.time_of_day == time, "simple time command: " + environment + "/" + time)
			var restored := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state))))
			ck(restored.time_of_day == time, "time survives saved state")
	for environment: String in ["station", "bunker", "asteroid"]:
		r.state.env = environment
		rejected(r, "time day")
	rejected(r, "time midnight")
	r.state.env = "asteroid"
	rejected(r, "world winter on")
