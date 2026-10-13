extends SceneTree
var failures: Array[String] = []
var checks := 0
func ck(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); printerr("FAIL " + label)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	_persistence_and_combat()
	await _editor()
	_generation()
	print("Light fixtures: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _persistence_and_combat() -> void:
	var map := MapData.blank_arena(16, 12)
	var at := Vector2i(6, 5)
	var ai := at.y * map.width + at.x
	map.set_cell(at, 0, 2, false, MCF.FEATURE_WALL)
	# One lamp per side (0.11): the west face looks at the shooter, the east face away.
	map.fixtures[ai] = MapData.valid_lamps([["wall_lamp", 1, 3, 0], ["wall_strip", 2, 1, 4]])
	map.set_spawn(Vector2i(4, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(14, 9), "light_infantry", 1)
	var decoded := MapData.from_dict(JSON.parse_string(JSON.stringify(map.to_dict())))
	ck(decoded.fixtures == map.fixtures, "map file keeps both lamps of a wall with side, durability and colour")
	var old := map.to_dict()
	old["fixtures"] = {str(ai): ["wall_lamp", 1, 2]}
	ck(MapData.from_dict(old).fixtures[ai] == [["wall_lamp", 1, 2, 0]], "0.10 maps with one lamp per wall still load")
	decoded.resize_keep(20, 16)
	ck(decoded.fixtures[at.y * 20 + at.x] == map.fixtures[ai], "resize preserves lamps on their wall")
	decoded.set_cell(at, 0, 0, false, "")
	ck(not decoded.fixtures.has(at.y * 20 + at.x), "painting away a wall removes its lamps")
	var pattern := MapPresets.capture(map, Rect2i(at, Vector2i.ONE))
	ck(load("res://src/data/RoomPresetStore.gd").to_map(pattern, "station").fixtures[0] == map.fixtures[ai], "room preset keeps every lamp")
	var turned: Array = MapPresets.rotated(pattern).cells[0][9]
	# A quarter turn clockwise: west -> north, east -> south.
	ck(turned.size() == 2 and str(MapData.lamp_on(turned, 0)[0]) == "wall_lamp" and int(MapData.lamp_on(turned, 2)[3]) == 4,
			"rotating a room preset turns every lamp to its new side")
	var state := map.build_state(2)
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	var res := GameActionResolver.new(state)
	var shooter: UnitInstance = state.all_units()[0]
	shooter.remaining_ap = 100
	var both: Array = state.grid.cell(at).lamps.duplicate(true)
	var copy := StateCodec.decode(StateCodec.encode(state))
	ck(copy.grid.cell(at).lamps == both, "save/replay/network state codec preserves every lamp")
	ck(res.can_shoot_fixture(shooter, at, 3) == "", "ordinary gun can aim at the lamp on its side of the wall")
	ck(res.can_shoot_fixture(shooter, at, 1) != "", "the lamp on the far side of the wall cannot be shot")
	ck(res.shootable_lamp_sides(shooter, at) == [3], "only the near lamp is offered")
	ck(not res.resolve(ShootIntent.new(shooter.id, -1, 1, at, "fixture:1")).ok, "an order to shoot the far lamp is refused")
	var target := Vector2i(5, 5)
	state.grid.cell(target).set_feature(MCF.FEATURE_WALL)
	ck(res.can_shoot_fixture(shooter, at, 3) != "", "intervening wall blocks shots at lamps")
	state.grid.cell(target).clear_feature()
	var recorder := ReplayRecorder.new()
	recorder.begin(state, res)
	res.replay_recorder = recorder
	var destroyed := false
	for i in 24:
		var result := res.resolve(ShootIntent.new(shooter.id, -1, 1, at, "fixture:3"))
		ck(result.ok, "lamp shot uses the normal action resolver")
		if MapData.lamp_on(state.grid.cell(at).lamps, 3).is_empty():
			destroyed = true
			break
	ck(destroyed and state.grid.cell(at).feature_id == MCF.FEATURE_WALL, "shooting a lamp destroys it without destroying its wall")
	ck(MapData.lamp_on(state.grid.cell(at).lamps, 1) == both[0] if int(both[0][2]) == 1 else MapData.lamp_on(state.grid.cell(at).lamps, 1) == both[1],
			"the lamp on the other side keeps shining")
	var replay := ReplayPlayer.new(recorder.to_dict())
	replay.seek(replay.step_count())
	ck(replay.state.grid.cell(at).lamps == state.grid.cell(at).lamps, "recorded lamp shots replay to the same state")
	replay.seek(0)
	ck(replay.state.grid.cell(at).lamps == both, "replay rewind restores the lamp before it was shot")
	res.replay_recorder = null
	ck(not res.can_undo(), "lamp shooting is irreversible, like other dice-based shots")
	state.grid.cell(at).lamps = both
	var snapshot := state.snapshot()
	state.grid.cell(at).lamps = []
	state.restore(snapshot)
	ck(state.grid.cell(at).lamps == both, "full state restoration restores wall lamps")
	GridCell.journal = {}
	GridCell.journaling = true
	state.grid.cell(at).lamps = []
	GridCell.journaling = false
	state.grid.cell(at).apply_image(GridCell.journal[state.grid.cell(at)])
	ck(state.grid.cell(at).lamps == both, "cell journal preserves lamps for undoable demolition")
	GridCell.journal = {}
	res._blast_destroy_terrain(at)
	ck(state.grid.cell(at).lamps.is_empty(), "a blast takes every lamp on the wall tile, on both sides")
	state.grid.cell(at).set_feature(MCF.FEATURE_WALL)
	state.grid.cell(at).lamps = both
	state.grid.cell(at).clear_feature()
	ck(state.grid.cell(at).lamps.is_empty(), "demolishing the supporting wall removes its lamps")
	ck(Furniture.DEFS.floodlight.light_energy > Furniture.DEFS.desk_lamp.light_energy,
		"floodlights are stronger than desk lamps")
	ck(Furniture.DEFS.streetlight.light_range > Furniture.DEFS.bollard_light.light_range,
		"streetlights reach farther than bollards")

func _editor() -> void:
	var editor = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	var i: int = 10 * editor.map.width + 10
	editor._begin()
	editor.brush = MCF.FEATURE_WALL
	for x in range(9, 12): editor._write(10 * editor.map.width + x, editor._brushed(editor._tuple(10 * editor.map.width + x), 0))
	editor._commit()
	editor._begin()
	editor.brush = "wall_lamp"
	editor.brush_turn = -1
	editor._write(i, editor._brushed(editor._tuple(i), 0, i))
	editor._commit()
	ck(editor.map.feature_id[i] == MCF.FEATURE_WALL and editor.map.fixtures.has(i), "editor places a lamp on a wall without replacing it")
	var first: Array = editor.map.fixtures[i]
	ck(first.size() == 1 and int(first[0][2]) in [0, 2], "the auto side is an open face, never one against the next wall")
	editor._begin()
	editor.brush_turn = 2 - int(first[0][2])
	editor._write(i, editor._brushed(editor._tuple(i), 0, i))
	editor._commit()
	ck(editor.map.fixtures[i].size() == 2, "R puts a second lamp on the other side of the same wall")
	editor._set_light_tint(i, 2, 3)
	ck(int(MapData.lamp_on(editor.map.fixtures[i], 2)[3]) == 3 and int(MapData.lamp_on(editor.map.fixtures[i], 0)[3]) == 0,
			"each lamp has its own colour")
	editor._remove_lamp(i, 0)   # 0.12.1: Remove is its own command, not a tint value
	ck(editor.map.fixtures[i].size() == 1 and not MapData.lamp_on(editor.map.fixtures[i], 2).is_empty(),
			"the right-click menu removes just that lamp")
	ck(editor._describe(Vector2i(10, 10)).contains("bottom side"), "the status bar names the lamp's side")
	editor._hover = Vector2i(10, 10)
	editor._build_preview()
	editor._begin()
	editor._erase_cell(Vector2i(10, 10))
	editor._commit()
	ck(not editor.map.fixtures.has(i) and editor.map.feature_id[i] == MCF.FEATURE_WALL, "editor erases the lamps before their wall")
	editor.free()

func _generation() -> void:
	for style in 5:
		var started := Time.get_ticks_msec()
		var gen := MapGen.build({"style": style, "size": 0, "units": 16, "seed": 317, "furniture": 2})
		var map := gen.m
		var plan := MapLighting.new()
		plan.g = gen
		plan.map = map
		var floor_count := 0
		var streets := 0
		var wall_lamps := 0
		for i in map.feature_id.size():
			if Furniture.emits_light(map.feature_id[i]):
				floor_count += 1
				ck(gen._core.has_point(Vector2i(i % gen.w, i / gen.w)) and gen._zone[i] < 0 and gen._street[i] == 0, "generated floor fixture keeps roads and deployments clear")
				if map.feature_id[i] == "streetlight": streets += 1
		for i: int in map.fixtures:
			ck(map.cover_height[i] >= 2 and not MCF.is_glass(map.feature_id[i]), "generated wall lamp has an opaque support")
			for lamp: Array in map.fixtures[i]:
				wall_lamps += 1
				var f: Vector2i = Vector2i(i % gen.w, i / gen.w) + Furniture.N4[int(lamp[2])]
				var fi := f.y * gen.w + f.x
				ck(map.in_bounds(f) and map.is_space[fi] == 0 and (map.cover_height[fi] < 2 or Furniture.is_furniture(map.feature_id[fi])),
						"%s: a wall lamp faces open floor, never the next wall or space" % map.env)
				ck(plan._target(fi) > 0.0, "%s: a wall lamp faces somewhere that wants light (never a station's outside)" % map.env)
		# Open ground stays dark (0.11): small field and asteroid maps only light their buildings.
		ck(floor_count + wall_lamps > (0 if map.env in ["field", "asteroid"] else 5), "%s map receives distributed lighting" % map.env)
		if map.env == "town": ck(streets > 0, "town generation includes streetlights")
		print("Generated %s: %d floor lights, %d wall lights, %.2fs" % [map.env, floor_count, wall_lamps, (Time.get_ticks_msec() - started) / 1000.0])

	var mirrored := MapGen.generate({"style": 1, "size": 0, "seed": 317, "furniture": 2, "symmetric": true})
	for i: int in mirrored.fixtures:
		var x := i % mirrored.width
		var y := i / mirrored.width
		var reflected := y * mirrored.width + mirrored.width - 1 - x
		var expected: Array = []
		for record: Array in mirrored.fixtures[i]:
			var turned := record.duplicate()
			turned[2] = [0, 3, 2, 1][int(record[2])]
			expected = MapData.with_lamp(expected, turned)
		ck(mirrored.fixtures.get(reflected, []) == expected, "symmetric generation mirrors every wall lamp's side")
