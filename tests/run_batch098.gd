extends SceneTree

const Rooms = preload("res://src/data/RoomPresetStore.gd")
var failures: Array[String] = []

func ck(ok: bool, message: String) -> void:
	if not ok: failures.append(message); printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await _editor_metadata()
	_tunnels()
	_neutrals()
	await _battle()
	_tiles()
	print("0.9.8 regression checks: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _editor_metadata() -> void:
	var editor: Variant = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(editor)
	editor.create_map("", "station", Vector2i(20, 20))
	editor._begin()
	editor._write(42, [0, MCF.WALL_HEIGHT, false, MCF.FEATURE_AIRLOCK, -1, -1, 0, 3, 8])
	editor.map.decals.append(["blood_pool", 2.25, 2.75, 0.0, 1.0])
	editor._sync_editor_decals()
	editor._commit()
	var restored := MapData.from_dict(JSON.parse_string(JSON.stringify(editor.map.to_dict())))
	ck(restored.get_accent(42) == 3 and restored.get_door(42) == 8, "map JSON preserves door artwork and station accents")
	ck(restored.decals[0][1] == 2.25, "blood position stays off-grid through JSON")
	editor.undo()
	ck(editor.map.get_door(42) == 0 and editor.map.decals.is_empty(), "undo restores artwork and decals together")
	editor.redo()
	ck(editor.map.get_door(42) == 8 and editor.map.decals.size() == 1, "redo restores artwork and decals together")
	var p := MapPresets.capture(editor.map, Rect2i(2, 2, 4, 3))
	var rotated := MapPresets.rotated(p)
	ck(float(rotated["decals"][0][1]) == 2.25 and float(rotated["decals"][0][2]) == 0.25, "rotated room rotates free-position decals")
	ck(Rooms.save_preset("zz_098_test", p, "station"), "custom room saves")
	var loaded := Rooms.read_preset("zz_098_test")
	ck(not loaded.is_empty() and int(loaded["pattern"]["cells"][0][8]) == 8, "custom room loads its door choice")
	var thumbnail := TerrainTiles.map_preview(Rooms.to_map(loaded["pattern"], "station"))
	ck(thumbnail != null and thumbnail.get_width() > 4, "room preview uses textured cells")
	Rooms.remove_preset("zz_098_test")
	ck(Rooms.read_preset("zz_098_test").is_empty(), "custom room deletion removes the preset")
	editor.resize_map(30, 24)
	ck(editor.map.get_door(62) == 8 and editor.map.decals.size() == 1, "map expansion preserves cells and decals")
	editor.set_preset("bunker")
	ck(editor._ground != null and editor._ground.texture != null, "editor changes to bunker soil background")
	editor.set_preset("station")
	ck(editor._ground.texture == null, "editor switches back to space background")
	editor.queue_free()
	await process_frame

func _tunnels() -> void:
	for seed in [7, 29, 1001]:
		var gen := MapGen.build({"style": 0, "size": 4, "seed": seed, "players": 2, "units": 30, "civilians": 0})
		var bad := 0
		for y in gen.h - 1:
			for x in gen.w - 1:
				if gen._kind(x, y) == MapGen.K_MAINT:
					for d: Vector2i in MapGen.N4:
						if gen._kind(x + d.x, y + d.y) in [MapGen.K_HALL, MapGen.K_DHALL]: bad += 1
					if gen._kind(x + 1, y) == MapGen.K_MAINT and gen._kind(x, y + 1) == MapGen.K_MAINT and gen._kind(x + 1, y + 1) == MapGen.K_MAINT: bad += 1
		ck(bad == 0, "service tunnels are single-width and closed by airlocks, seed %d" % seed)

func _neutrals() -> void:
	var state := GameState.new(20, 12, 9)
	var stats: UnitStats = load("res://src/data/units/light_infantry.tres")
	var neutral := state.spawn_unit(stats, Vector2i(4, 4), MCF.Owner.NEUTRAL)
	neutral.civilian_active = true
	var enemy := state.spawn_unit(stats, Vector2i(7, 4), 0)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var ai := AIController.new(MCF.Owner.NEUTRAL, AIController.Difficulty.HARD)
	var candidates := ai._neutral_candidates(state, r, neutral)
	ck(not candidates.is_empty() and candidates.all(func(c: Dictionary) -> bool: return c["intent"] is ShootIntent), "armed neutral shoots before moving or collecting corpses")
	state.grid.cell(enemy.coord).occupant = null
	enemy.coord = Vector2i(9, 5)
	state.grid.cell(enemy.coord).occupant = enemy
	var move := ai._neutral_firing_move(state, r, neutral)
	ck(not move.is_empty(), "neutral finds a firing position while keeping shooting AP")
	state.turns.round_order = [MCF.Owner.NEUTRAL, 0]
	state.turns.active_index = 0
	var result := r.advance_civilians()
	var walks := {}
	var count := 0
	for event: Dictionary in result.dice_events:
		if event.get("kind", "") != "walk": continue
		count += 1
		var key := str([event["unit"], event["from"], event["path"]])
		ck(not walks.has(key), "neutral movement is emitted only once for replay animation")
		walks[key] = true
	ck(count > 0, "neutral replay regression exercises a movement")


func _battle() -> void:
	var m := MapData.new(12, 12)
	m.env = "town"
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(9, 9), "light_infantry", 1)
	var battle: Variant = load("res://tests/fixtures/GroundBackgroundOnly.gd").new()
	battle.state = m.build_state(2)
	battle.resolver = GameActionResolver.new(battle.state)
	root.add_child(battle)
	battle._capture_opening_view()
	var unit: UnitInstance = battle.state.all_units()[0]
	var original: Vector2i = unit.coord
	var old_opening: Dictionary = battle._opening_state.duplicate(true)
	unit.coord = Vector2i(6, 6)
	battle._capture_opening_view()
	ck(battle._before_units[0][2] == original, "before/after retains the original battlefield after save capture")
	ck(battle._opening_state == old_opening, "opening snapshot does not advance with the live board")
	await battle._play_walk({"unit": unit.id, "from": original, "path": [original + Vector2i.RIGHT], "soldier": true})
	ck(battle._draw_cell(unit) == original + Vector2i.RIGHT, "walk endpoint does not snap to the simulation's final position")
	await battle._play_walk({"unit": unit.id, "from": original + Vector2i.RIGHT, "path": [original + Vector2i(2, 0)], "soldier": true})
	ck(battle._walks_running == 0 and battle._draw_cell(unit) == original + Vector2i(2, 0), "consecutive walks retain their ordered endpoints")
	ck(battle._defense_roll_speed([{"armor": 7}]) == 2.0, "impossible defense roll animates twice as fast")
	ck(battle._defense_roll_speed([{"need": 7}], "need") == 2.0, "grenade defense uses its own threshold")
	ck(battle._defense_roll_speed([{"armor": 6}]) == 1.0, "possible defense keeps normal speed")
	battle.state.turns.round_number = 9
	battle.state.deaths[0] = 4
	battle._real_start_ms = Time.get_ticks_msec() - 73000
	var payload: Dictionary = JSON.parse_string(JSON.stringify(battle._save_payload()))
	SaveHandoff.pending_save = payload
	ck(battle._adopt_save(), "saved match loads")
	battle._capture_opening_view()
	ck(battle.state.turns.round_number == 9 and int(battle.state.deaths[0]) == 4, "save preserves rounds and casualty ledger")
	ck(Time.get_ticks_msec() - battle._real_start_ms >= 73000, "real-time clock resumes at saved elapsed time")
	ck(battle._before_units[0][2] == original, "loading preserves the original Before map")
	battle._spectator = true
	battle._spectator_fog = true
	var rules: int = battle.resolver.fog_mode
	ck(not battle._can_control(0), "spectators cannot command any army")
	ck(battle._view_resolver() != battle.resolver and battle.resolver.fog_mode == rules, "spectator POV does not alter simulation rules")
	battle.state.roster.slots[0].peer_id = 1
	battle.state.roster.slots[1].peer_id = 77
	var net := NetGame.new(battle.state, battle.resolver, true)
	ck(not net._authorized(EndTurnIntent.new(1), 999), "unseated spectator cannot submit end turn")
	ck(not net._authorized(EndTurnIntent.new(0), 77), "guest cannot forge the host's end turn")
	ck(net._authorized(EndTurnIntent.new(1), 77), "seated guest can submit its own end turn")
	var guest := NetGame.new(battle.state, battle.resolver, false, 1)
	var messages: Array = []
	guest.outgoing.connect(func(msg: Dictionary) -> void: messages.append(msg))
	guest.submit_local(EndTurnIntent.new())
	guest.submit_local(EndTurnIntent.new())
	ck(messages.size() == 1 and IntentCodec.decode(messages[0]["i"]).requester == 1,
		"repeated guest end-turn clicks send one request with its authenticated seat")
	guest.receive({"k": NetGame.K_DENIED, "a": -1, "p": 1, "reason": "Not your turn"})
	guest.submit_local(EndTurnIntent.new())
	ck(messages.size() == 2, "host rejection releases the pending end-turn request")

	battle.queue_free()
	await process_frame

func _tiles() -> void:
	var doors := Grid.new(20, 2)
	for x in 12: doors.cell_fast(x, 0).set_feature(MCF.FEATURE_AIRLOCK)
	var door_tiles := TerrainTiles.new(doors, "station")
	for x in 12:
		ck(door_tiles._door_anchor(doors, Vector2i(x, 0)) == Vector2i.ZERO, "wide airlock shares a stable sprite variant")
	var g := Grid.new(4, 4)
	g.cell_fast(1, 1).set_feature(MCF.FEATURE_DIRT_PILE)
	g.cell_fast(2, 1).set_feature(MCF.FEATURE_DIRT_PILE)
	ck(TerrainTiles.mask_at(g, Vector2i(1, 1), MCF.FEATURE_DIRT_PILE) == Sprites.AUTOTILE_E, "dirt piles join their neighbors")
	ck(TerrainTiles.tile_name(g.cell_fast(1, 1)) == "soil", "dirt piles use the soil wall artwork")
	var tiles := TerrainTiles.new(g, "town")
	var fx := FxDecals.new()
	fx.track_marks.append({"from": Vector2(0.5, 0.5), "to": Vector2(3.5, 0.5)})
	fx.ground_version += 1
	tiles.sync_decals(fx)
	g.cell_fast(1, 0).set_feature(MCF.FEATURE_WALL)
	tiles._build(Vector2i.ZERO, 32)
	var with_tracks: Image = tiles._chunks[Vector3i(0, 0, 32)]["feat"].get_image()
	var clean := TerrainTiles.new(g, "town")
	clean._build(Vector2i.ZERO, 32)
	ck(with_tracks.get_data() == clean._chunks[Vector3i(0, 0, 32)]["feat"].get_image().get_data(), "track marks never alter the wall layer")
