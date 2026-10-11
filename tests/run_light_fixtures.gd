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
	map.set_cell(at, 0, 2, false, MCF.FEATURE_WALL)
	map.fixtures[at.y * map.width + at.x] = ["wall_lamp", 1, 2]
	map.set_spawn(Vector2i(4, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(14, 9), "light_infantry", 1)
	var decoded := MapData.from_dict(JSON.parse_string(JSON.stringify(map.to_dict())))
	ck(decoded.fixtures == map.fixtures, "map file preserves fixture durability and orientation")
	decoded.resize_keep(20, 16)
	ck(decoded.fixtures[at.y * 20 + at.x] == ["wall_lamp", 1, 2], "resize preserves fixture on its wall")
	decoded.set_cell(at, 0, 0, false, "")
	ck(not decoded.fixtures.has(at.y * 20 + at.x), "painting away a wall removes its attachment")
	var pattern := MapPresets.capture(map, Rect2i(at, Vector2i.ONE))
	ck(load("res://src/data/RoomPresetStore.gd").to_map(pattern, "station").fixtures[0] == ["wall_lamp", 1, 2], "room preset manager retains fixture in editable map")
	ck(MapPresets.rotated(pattern).cells[0][9][2] == 3, "rotating a room preset rotates its wall fixture")
	var state := map.build_state(2)
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	var res := GameActionResolver.new(state)
	var shooter: UnitInstance = state.all_units()[0]
	shooter.remaining_ap = 100
	var frame := StateCodec.encode(state)
	var copy := StateCodec.decode(frame)
	ck(copy.grid.cell(at).fixture == state.grid.cell(at).fixture, "save/replay/network state codec preserves fixtures")
	ck(res.can_shoot_fixture(shooter, at) == "", "ordinary gun can aim at wall lamp")
	var target := Vector2i(5, 5)
	state.grid.cell(target).set_feature(MCF.FEATURE_WALL)
	ck(res.can_shoot_fixture(shooter, at) != "", "intervening wall blocks shots at fixtures")
	state.grid.cell(target).clear_feature()
	var recorder := ReplayRecorder.new()
	recorder.begin(state, res)
	res.replay_recorder = recorder
	var destroyed := false
	for i in 24:
		var result := res.resolve(ShootIntent.new(shooter.id, -1, 1, at, "fixture"))
		ck(result.ok, "fixture shot uses the normal action resolver")
		if state.grid.cell(at).fixture.is_empty():
			destroyed = true
			break
	ck(destroyed and state.grid.cell(at).feature_id == MCF.FEATURE_WALL, "shooting a lamp destroys it without destroying its wall")
	var replay := ReplayPlayer.new(recorder.to_dict())
	replay.seek(replay.step_count())
	ck(replay.state.grid.cell(at).fixture == state.grid.cell(at).fixture, "recorded fixture shots replay to the same destruction state")
	replay.seek(0)
	ck(replay.state.grid.cell(at).fixture == ["wall_lamp", 1, 2], "replay rewind restores fixture before it was shot")
	res.replay_recorder = null
	ck(not res.can_undo(), "fixture shooting is irreversible, like other dice-based shots")
	state.grid.cell(at).fixture = ["wall_lamp", 1, 2]
	var snapshot := state.snapshot()
	state.grid.cell(at).fixture = []
	state.restore(snapshot)
	ck(state.grid.cell(at).fixture == ["wall_lamp", 1, 2], "full state restoration restores a wall fixture")
	GridCell.journal = {}
	GridCell.journaling = true
	state.grid.cell(at).fixture = []
	GridCell.journaling = false
	state.grid.cell(at).apply_image(GridCell.journal[state.grid.cell(at)])
	ck(state.grid.cell(at).fixture == ["wall_lamp", 1, 2], "cell journal preserves attachment for undoable demolition")
	GridCell.journal = {}
	state.grid.cell(at).fixture = ["wall_lamp", 1, 0]
	res._blast_destroy_terrain(at)
	ck(state.grid.cell(at).fixture.is_empty(), "explosions destroy wall fixtures")
	state.grid.cell(at).set_feature(MCF.FEATURE_WALL)
	state.grid.cell(at).fixture = ["wall_lamp", 1, 0]
	state.grid.cell(at).clear_feature()
	ck(state.grid.cell(at).fixture.is_empty(), "demolishing the supporting wall removes its lamp")
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
	editor._write(i, editor._brushed(editor._tuple(i), 0))
	editor._commit()
	editor._begin()
	editor.brush = "wall_lamp"
	editor._write(i, editor._brushed(editor._tuple(i), 0))
	editor._commit()
	ck(editor.map.feature_id[i] == MCF.FEATURE_WALL and editor.map.fixtures.has(i), "editor places a lamp on a wall without replacing it")
	editor._hover = Vector2i(10, 10)
	editor._build_preview()
	editor._begin()
	editor._erase_cell(Vector2i(10, 10))
	editor._commit()
	ck(not editor.map.fixtures.has(i) and editor.map.feature_id[i] == MCF.FEATURE_WALL, "editor erases the attachment before its wall")
	editor.free()

func _generation() -> void:
	for style in 5:
		var started := Time.get_ticks_msec()
		var gen := MapGen.build({"style": style, "size": 0, "units": 16, "seed": 317, "furniture": 2})
		var map := gen.m
		var floor_count := 0
		var streets := 0
		for i in map.feature_id.size():
			if Furniture.emits_light(map.feature_id[i]):
				floor_count += 1
				ck(gen._core.has_point(Vector2i(i % gen.w, i / gen.w)) and gen._zone[i] < 0 and gen._street[i] == 0, "generated floor fixture keeps roads and deployments clear")
				if map.feature_id[i] == "streetlight": streets += 1
		for i: int in map.fixtures:
			ck(map.cover_height[i] >= 2 and not MCF.is_glass(map.feature_id[i]), "generated wall fixture has an opaque support")
		# Open ground stays dark (0.11): small field and asteroid maps only light their buildings.
		ck(floor_count + map.fixtures.size() > (0 if map.env in ["field", "asteroid"] else 5), "%s map receives distributed lighting" % map.env)
		if map.env == "town": ck(streets > 0, "town generation includes streetlights")
		print("Generated %s: %d floor lights, %d wall lights, %.2fs" % [map.env, floor_count, map.fixtures.size(), (Time.get_ticks_msec() - started) / 1000.0])

	var mirrored := MapGen.generate({"style": 1, "size": 0, "seed": 317, "furniture": 2, "symmetric": true})
	for i: int in mirrored.fixtures:
		var x := i % mirrored.width
		var y := i / mirrored.width
		var reflected := y * mirrored.width + mirrored.width - 1 - x
		var record: Array = mirrored.fixtures[i]
		var expected := [record[0], record[1], [0, 3, 2, 1][int(record[2])]]
		ck(mirrored.fixtures.get(reflected, []) == expected, "symmetric generation mirrors wall lamp facing and durability")
