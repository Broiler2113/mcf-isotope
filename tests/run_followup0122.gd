extends SceneTree

var fails: Array[String] = []
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	_shield_glass()
	_vehicle_chunks()
	_time_choices()
	await _shot_timing()
	print("0.12.2 follow-up: %d failure(s)" % fails.size())
	quit(0 if fails.is_empty() else 1)

func state_of(m: MapData) -> GameState:
	var st := m.build_state(77)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

func _shield_glass() -> void:
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(4, 5), "shield_bearer", 0)
	m.set_spawn(Vector2i(3, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(4, 6), "light_infantry", 1)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	m.set_cell(Vector2i(5, 5), 0, 2.0, false, MCF.FEATURE_GLASS)
	m.set_cell(Vector2i(5, 4), 0, 2.0, false, MCF.FEATURE_ARMOR_GLASS)
	m.set_cell(Vector2i(6, 5), 0, 2.0, false, MCF.FEATURE_GLASS)
	var st := state_of(m)
	var peer := state_of(m)
	var r := GameActionResolver.new(st)
	var other := GameActionResolver.new(peer)
	var u := st.grid.cell(Vector2i(4, 5)).occupant
	var ap := u.remaining_ap
	ck(r.pushable_window_cells(u).size() == 2, "Shield Push offers adjacent ordinary and armored glass, but not distant glass")
	for coord in [Vector2i(6, 5), Vector2i(-1, 5), Vector2i(4, 4)]:
		ck(not r.resolve(PushIntent.new(u.id, -1, coord)).ok and u.remaining_ap == ap,
				"invalid glass strike leaves AP intact: " + str(coord))
	var infantry := st.grid.cell(Vector2i(3, 5)).occupant
	ck(not r.resolve(PushIntent.new(infantry.id, -1, Vector2i(5, 5))).ok, "infantry cannot shield-strike glass")
	var old := IntentCodec.decode({"t": "push", "a": u.id, "tid": 7}) as PushIntent
	ck(old.target_id == 7 and old.target_cell == Vector2i(-999, -999), "older unit-push records keep their target and absent cell")
	# Ordinary pane, armored pane holds, armored pane breaks, then the original unit push.
	var intents := [PushIntent.new(u.id, -1, Vector2i(5, 5)),
		PushIntent.new(u.id, -1, Vector2i(5, 4)), PushIntent.new(u.id, -1, Vector2i(5, 4)),
		PushIntent.new(u.id, st.grid.cell(Vector2i(4, 6)).occupant.id)]
	for i in intents.size():
		u.remaining_ap = 3
		peer.get_unit(u.id).remaining_ap = 3
		st.dice.feed_scripted([6 if i == 1 or i == 3 else 1])
		st.dice.begin_record()
		var res := r.resolve(intents[i])
		var rolls := st.dice.take_log()
		peer.dice.feed_scripted(rolls)
		var mirrored := other.resolve(IntentCodec.decode(IntentCodec.encode(intents[i])))
		ck(res.ok and mirrored.ok and st.digest_hash() == peer.digest_hash() and res.fx == mirrored.fx,
				"shield action %d stays identical across the wire" % i)
		ck(u.remaining_ap == 2, "shield action %d costs one AP" % i)
		if i == 0 or i == 2:
			ck(st.grid.cell(intents[i].target_cell).feature_id == "" and res.fx.any(func(e): return e.fx == "shards"), "broken glass emits shards")
		elif i == 1:
			ck(st.grid.cell(Vector2i(5, 4)).feature_id == MCF.FEATURE_ARMOR_GLASS and res.fx.is_empty(), "armored glass retains its 4+ hold roll")
		else:
			ck(st.get_unit(intents[i].target_id).coord == Vector2i(4, 7), "existing push still moves a surviving enemy")
	u.remaining_ap = 0
	ck(r.pushable_window_cells(u).is_empty() and not r.resolve(PushIntent.new(u.id, -1, Vector2i(6, 5))).ok, "no shield strike without AP")

func _vehicle_chunks() -> void:
	var m := MapData.blank_arena(20, 10)
	m.env = "town"
	m.set_spawn(Vector2i(1, 2), "tank", 0, Vector2i.RIGHT)
	m.set_spawn(Vector2i(0, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 8), "light_infantry", 1)
	var walls := [MCF.FEATURE_WALL, MCF.FEATURE_WOOD_WALL, MCF.FEATURE_SANDBAG_WALL]
	for i in walls.size():
		m.set_cell(Vector2i(8, 2 + i), 0, 2.0, false, walls[i])
	m.set_look(2 * m.width + 8, MCF.wall_look(1))
	var st := state_of(m)
	var peer := state_of(m)
	var r := GameActionResolver.new(st)
	var other := GameActionResolver.new(peer)
	var v: Vehicle = st.all_vehicles()[0]
	var crew := st.grid.cell(Vector2i(0, 2)).occupant
	for intent in [VehicleBoardIntent.new(crew.id, v.id), VehicleMoveIntent.new(v.id, Vector2i.RIGHT, 8)]:
		st.dice.begin_record()
		var res := r.resolve(intent)
		peer.dice.feed_scripted(st.dice.take_log())
		var mirrored := other.resolve(IntentCodec.decode(IntentCodec.encode(intent)))
		ck(res.ok and mirrored.ok and st.digest_hash() == peer.digest_hash() and res.fx == mirrored.fx, "vehicle action and debris agree across the wire")
		if intent is VehicleMoveIntent:
			var chunks: Array = res.fx.filter(func(e): return e.fx == "chunks")
			ck(chunks.size() == 3, "one chunk burst per rammed wall tile")
			ck(chunks.any(func(e): return e.at == Vector2i(8, 2) and e.look == MCF.wall_look(1)), "wall chunks retain an explicitly chosen wall texture")
			for i in walls.size():
				var coord := Vector2i(8, 2 + i)
				ck(st.grid.cell(coord).feature_id == "" and chunks.any(func(e): return e.at == coord and e.fid == walls[i] and e.env == "town" and e.from.x < coord.x), "rammed " + walls[i] + " preserves its material and impact direction")
			var fx := FxDecals.new()
			fx.apply(res.fx)
			ck(fx.flying.any(func(f): return str(f.kind).begins_with("chunk:")), "vehicle wall destruction launches visible chunks")

func _time_choices() -> void:
	for style in MapGen.STYLE_ENV.size():
		var outdoor := style in [MapGen.Style.TOWN, MapGen.Style.FIELD]
		for time in MapData.TIMES + ["random"]:
			var value := MapGen.time_choice({"style": style, "time": time, "seed": 7})
			ck(MapData.TIMES.has(value) if outdoor else value == "", "%s accepts time=%s only outdoors" % [MapGen.STYLE_NAMES[style], time])

func _shot_timing() -> void:
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	root.get_node("Ui").autoroll_dice = false
	var m := MapData.blank_arena(20, 12)
	m.set_spawn(Vector2i(3, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(8, 5), "light_infantry", 1)
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	var shooter: UnitInstance = main.state.grid.cell(Vector2i(3, 5)).occupant
	var target: UnitInstance = main.state.grid.cell(Vector2i(8, 5)).occupant
	# Exercise actual local actions plus the replay and queued network presentation paths.
	for path in ["local", "replay", "network"]:
		shooter.remaining_ap = 3
		shooter.action_state = null
		main.state.dice.feed_scripted([6, 6])
		main._fx.clear()
		var intent := ShootIntent.new(shooter.id, target.id, 1)
		if path == "local":
			main._on_intent_ready(intent)
		else:
			var res: ActionResult = main.resolver.resolve(intent)
			ck(res.ok, path + " shot resolves")
			if path == "replay": main._show_result(res)
			else: main._show_net_action(intent, res)
		await process_frame
		ck(main._dice._roll_btn.visible, path + " waits for the attack roll")
		ck(_only_held_lane_to(main._fx, target.coord) and main._fx.tracers.is_empty() and main._fx.shots.is_empty(), path + " shows only a held lane to the target (no flash, no bullets) before attack dice")
		main._dice._roll_btn.pressed.emit()
		await main._dice.finished
		await process_frame
		ck(main._dice._roll_btn.visible, path + " waits for the defense roll")
		ck(_only_held_lane_to(main._fx, target.coord) and main._fx.tracers.is_empty(), path + " shows only a held lane to the target (no flash, no bullets) before defense dice")
		main._dice._roll_btn.pressed.emit()
		var seen := false
		var deadline := Time.get_ticks_msec() + 10000
		while main._animating and Time.get_ticks_msec() < deadline:
			if not main._fx.tracers.is_empty():
				seen = true
				ck(not main._dice.visible and not main._fx.lanes.is_empty(), path + " launches muzzle flash and bullets together after dice")
				break
			await process_frame
		ck(seen, path + " eventually launches its bullet")
		while main._animating and Time.get_ticks_msec() < deadline: await process_frame
		ck(not main._animating, path + " presentation finishes")
	main.free()
	await process_frame

## Issues-fix-6 #1: who fires at whom shows before the dice — a held lane (no muzzle light)
## ending at the aimed target, never at where the bullets will land.
func _only_held_lane_to(fx: FxDecals, at: Vector2i) -> bool:
	return fx.lanes.size() == 1 and fx.lanes[0].get("hold", false) \
			and fx.lanes[0]["to"] == Vector2(at) + Vector2(0.5, 0.5)
