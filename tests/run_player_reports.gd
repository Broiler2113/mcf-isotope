extends SceneTree

var failures: Array[String] = []
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func arena() -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 5), "light_infantry", 1)
	var s := map.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r
func add(r: GameActionResolver, kind: String, c: Vector2i, side: int = 0) -> UnitInstance:
	return r.state.spawn_unit(load("res://src/data/units/%s.tres" % kind), c, side)
func run() -> void:
	smoke()
	capture()
	stations()
	fire_exits()
	borg_weapons()
	corpse_rules()
	waves()
	await save_and_walk()
	await heavy_capture_ui()
	await spawn_controls()
	print("Player reports: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)

func smoke() -> void:
	var r := arena()
	var s := r.state
	var u := s.grid.cell(Vector2i(2, 5)).occupant
	var enemy := s.grid.cell(Vector2i(18, 5)).occupant
	s.grid.cell(Vector2i(12, 5)).set_feature(MCF.FEATURE_WALL)
	r.random_events.add_smoke(4, 10, 3, 3, 3)
	r._sync_gas()
	ck(not r.fog_enabled and r.is_visible_to_team(0, enemy), "smoke elsewhere does not enable wall fog")
	r.random_events.add_smoke(7, 4, 2, 3, 3)
	r._sync_gas()
	ck(not r.is_visible_to_team(0, enemy), "smoke itself hides units behind it with global fog off")
	u.remaining_ap = 3
	var res := r.resolve(MoveIntent.new(u.id, Vector2i(10, 5)))
	ck(res.ok and u.is_alive() and u.coord == Vector2i(10, 5), "soldier walks through smoke without a damage roll")
	ck(res.dice_events.all(func(e: Dictionary) -> bool: return e.get("kind") in ["hold", "walk", "ap"]), "smoke movement is harmless")

func capture() -> void:
	for scenario in range(16):
		var carry := bool(scenario & 1)
		var r := arena()
		r.fog_enabled = bool(scenario & 2)
		var s := r.state
		var captive := s.grid.cell(Vector2i(2, 5)).occupant
		var captor := s.grid.cell(Vector2i(18, 5)).occupant
		captive.stats = load("res://src/data/units/heavy_infantry.tres")
		if scenario & 4: captor.stats = captive.stats
		if scenario & 8:
			captive.action_state = ActionState.new()
			captive.action_state.remaining_shots = 2
		s.grid.move_occupant(captor.coord, Vector2i(3, 5))
		r.team_visible_coords(0)
		s.turns.active_index = 1
		s.dice.feed_scripted([6, 1])
		ck(r.resolve(CaptureIntent.new(captor.id, captive.id)).ok and captive.is_held(), "enemy grabs soldier")
		if carry:
			ck(r.resolve(MoveIntent.new(captor.id, Vector2i(5, 5))).ok, "captor carries soldier")
		r.team_visible_coords(0)  # Warm the no-sight cache while the sole friendly is held.
		s.turns.active_index = 0
		captive.remaining_ap = 3
		s.dice.feed_scripted([6])
		ck(r.resolve(ReleaseIntent.new(captive.id)).ok and captive.is_alive(), "soldier breaks free")
		ck(r.can_shoot(captive, captor) == "" and r.shootable_target_ids(captive).has(captor.id), "freed soldier can target their captor")
		s.dice.feed_scripted([6, 1, 6, 1, 6, 1, 6, 1])
		ck(r.resolve(ShootIntent.new(captive.id, captor.id)).ok, "freed soldier fires at former captor")

func stations() -> void:
	var r := arena()
	var s := r.state
	var shuttle := s.spawn_vehicle("shuttle", Vector2i(6, 6), 0)
	var driver := add(r, "civilian", Vector2i(5, 5))
	var op := add(r, "drone_operator", Vector2i(8, 5))
	var op2 := add(r, "drone_operator", Vector2i(5, 8))
	ck(r.resolve(VehicleBoardIntent.new(driver.id, shuttle.id, 0)).ok, "civilian boards driver seat")
	ck(r.resolve(VehicleBoardIntent.new(op.id, shuttle.id, 1)).ok, "first drone operator boards")
	ck(r.resolve(VehicleBoardIntent.new(op2.id, shuttle.id, 2)).ok, "second drone operator boards")
	var at := shuttle.seat_cell(3)
	ck(r.resolve(UseItemIntent.new(op.id, at)).ok, "station mounts in fourth seat")
	r._kill(driver)
	ck(r.stations_near(op).has(at) and r.stations_near(op2).has(at), "driver death does not disconnect either operator")
	s.grid.cell(at).feature_durability = 5
	var rocketeer := add(r, "anti_tank", Vector2i(at.x + 4, at.y))
	s.dice.feed_scripted([6, 6, 6, 6, 6, 6, 6, 6])
	var rocket := r.resolve(ShootIntent.new(rocketeer.id, -1, -1, at))
	ck(rocket.ok, "AT round hits the mounted drone station: " + rocket.reason)
	ck(s.grid.cell(at).feature_id == "" and shuttle.seats[3] == -1, "blast deletes station and releases its shuttle seat")
	ck(r.deployed_station_of(op) == Vector2i(-1, -1), "destroyed station no longer blocks replacement")
	# A station outside a shuttle must also disappear in a frag explosion.
	var floor_station := Vector2i(12, 10)
	s.grid.cell(floor_station).set_feature(MCF.FEATURE_DRONE_STATION, 0)
	r._explode_frag(op, floor_station)
	ck(s.grid.cell(floor_station).feature_id == "", "frag explosion deletes drone stations")

func fire_exits() -> void:
	for kind in ["tank", "shuttle", "borg"]:
		var r := arena()
		var u := r.state.grid.cell(Vector2i(2, 5)).occupant
		var v := r.state.spawn_vehicle(kind, Vector2i(3, 5), 0)
		ck(r.resolve(VehicleBoardIntent.new(u.id, v.id)).ok, "boards " + kind)
		if kind == "shuttle":
			r.state.grid.cell(u.coord).on_fire = true
			ck(r.is_fireproof(u), "shuttle passenger is immune to fire")
		var target: Vector2i = r.vehicle_disembark_cells(v, u.id)[0]
		r.state.grid.cell(target).on_fire = true
		var res := r.resolve(VehicleDisembarkIntent.new(u.id, target))
		ck(res.ok and not u.is_alive() and u.burnt and res.deaths.has(u.id), "exiting " + kind + " into fire kills immediately and reports death: " + res.reason + " " + str(res.deaths) + " alive=" + str(u.is_alive()))

func borg_weapons() -> void:
	for kind in ["civilian", "miner", "shield_bearer", "engineer", "marksman", "sniper", "flamethrower", "anti_tank", "drone_operator"]:
		var r := arena()
		var u := add(r, kind, Vector2i(6, 8))
		var v := r.state.spawn_vehicle("borg", Vector2i(7, 8), 0)
		var target := add(r, "light_infantry", Vector2i(11, 8), 1)
		ck(r.resolve(VehicleBoardIntent.new(u.id, v.id)).ok, kind + " boards borg")
		ck(u.fire_range() == 12 and u.rate_of_fire() == 4 and u.attack_ability() == "", kind + " uses borg weapon stats")
		r.state.dice.feed_scripted([6, 6, 6, 6, 6, 6, 6, 6])
		var shot := r.resolve(ShootIntent.new(u.id, target.id))
		var tracers := shot.fx.filter(func(e: Dictionary) -> bool: return e.get("fx") == "tracer")
		ck(shot.ok and tracers.size() == 1 and int(tracers[0].get("count", 0)) == 4, kind + " fires four bullets, no personal special attack")
		u.remaining_ap = 2
		ck(r.resolve(VehicleDisembarkIntent.new(u.id, Vector2i(6, 8))).ok and u.attack_ability() == u.stats.special_ability_id, kind + " regains personal weapon on exit")

func corpse_rules() -> void:
	var r := arena()
	var u := r.state.grid.cell(Vector2i(2, 5)).occupant
	var buddy := add(r, "light_infantry", Vector2i(3, 5))
	u.carried_corpses = 1
	ck(not r.resolve(DropCorpseIntent.new(u.id, buddy.coord)).ok, "cannot drop a corpse underneath another living soldier")
	ck(not r.corpse_drop_cells(u).has(buddy.coord), "corpse drop preview excludes living soldiers")
	var pile := Vector2i(3, 6)
	r.state.grid.cell(pile).corpse_count = 1
	ck(not r.reachable_for(u, 20).can_reach(pile), "path planner never walks onto corpse piles")
	var v := r.state.spawn_vehicle("borg", Vector2i(7, 8), 0)
	var pilot := add(r, "light_infantry", Vector2i(6, 8))
	var helper := add(r, "light_infantry", Vector2i(6, 9))
	r.resolve(VehicleBoardIntent.new(pilot.id, v.id))
	r.state.dice.feed_scripted([1])
	r._destroy_vehicle(v, ActionResult.success([]))
	ck(v.wrecked and r.unloadable_corpse_vehicle_ids(helper).has(v.id), "destroyed borg offers corpse extraction")
	var res := r.resolve(VehicleUnloadCorpseIntent.new(helper.id, v.id))
	ck(res.ok and pilot.coord != v.origin and r.state.grid.cell(v.origin).occupant == null, "body is pulled out without removing borg wreck")

func waves() -> void:
	var r := arena()
	r.mode.kind = MatchMode.Kind.HOLDOUT
	r.mode.wave_side = 1
	var shield := add(r, "shield_bearer", Vector2i(8, 5), 1)
	var shooter := r.state.grid.cell(Vector2i(2, 5)).occupant
	ck(not r._shield_blocks_shot(shooter, shield) and not r.is_fireproof(shield), "Holdout soldiers have no shield or fire immunity")
	var flame := add(r, "flamethrower", Vector2i(9, 5), 1)
	ck(not r.is_fireproof(flame), "Holdout flamethrowers have no fire immunity")
	ck(not r._flame_blocked(shield.coord), "Holdout shields do not stop flame spread")
	r.mode.excluded_units.assign(GameActionResolver.ARMY_ROSTER)
	r.mode.excluded_units.erase("light_infantry")
	r.mode.defender_value = 300
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	var first := r.state.all_units().filter(func(u: UnitInstance) -> bool: return u.neutral_group == 1)
	ck(not first.is_empty() and first.all(func(u: UnitInstance) -> bool: return u.stats.id == "light_infantry"), "Holdout restrictions apply to actual arrivals")
	r.random_events.excluded_units.assign(GameActionResolver.ARMY_ROSTER)
	ck(r._independent_roster().is_empty(), "all raider types can be excluded without fallback spawns")
	r.mode.pending_wave = {"edge": 2, "along": 8}
	r._land_wave(ActionResult.success([]))
	var display = load("res://scenes/Main.gd").new()
	display.state = r.state
	display.resolver = r
	var w1 := MCF.wave_slot(1)
	var w2 := MCF.wave_slot(2)
	ck(r.state.turns.round_order.has(w1) and r.state.turns.round_order.has(w2)
			and display._side_label(w1) == "Wave I" and display._side_label(w2) == "Wave II",
			"Initiative lists waves separately by arrival")
	display.free()
	r.random_events.excluded_units.erase("light_infantry")
	r._land_army({"edge": 1, "along": 10}, ActionResult.success([]))
	var raiders := r.state.all_units().filter(func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner))
	ck(not raiders.is_empty() and raiders.all(func(u: UnitInstance) -> bool: return u.stats.id == "light_infantry" and u.neutral_group == 1), "raider arrivals respect exclusions and receive Roman group numbers")
	var rules := StateCodec.encode_rules(r)
	var loaded := GameActionResolver.new(StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state)))) )
	StateCodec.apply_rules(loaded, JSON.parse_string(JSON.stringify(rules)))
	ck(loaded.mode.wave_sizes == r.mode.wave_sizes and loaded.mode.excluded_units == r.mode.excluded_units and loaded.random_events.excluded_units == r.random_events.excluded_units, "wave groups and independent restrictions survive JSON save/load")

func save_and_walk() -> void:
	var r := arena()
	MapHandoff.pending = null
	SaveHandoff.pending_save = {"state": StateCodec.encode(r.state), "rules": StateCodec.encode_rules(r),
		"combat_log": ["A saved combat line"], "chat": [{"side": 0, "text": "Saved [b]chat"}]}
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	main._paused = true
	ck(main.state.log.lines.has("A saved combat line") and main._log_label.text.contains("A saved combat line"), "loaded combat log restores its model and panel")
	ck(NetHandoff.chat_history.size() == 1 and main._chat_log.get_parsed_text().contains("Saved [b]chat"), "loaded chat restores literal text safely")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(main._save_payload()))
	ck(saved.combat_log.has("A saved combat line") and saved.chat[0].text == "Saved [b]chat", "saving again retains both histories")
	# An L-shaped route: the midpoint sees a side room neither endpoint can see.
	main.resolver.fog_enabled = true
	var u: UnitInstance = main.state.grid.cell(Vector2i(2, 5)).occupant
	for y in range(1, 15): main.state.grid.cell(Vector2i(6, y)).set_feature(MCF.FEATURE_WALL)
	main.state.grid.cell(Vector2i(6, 8)).clear_feature()
	var target := Vector2i(8, 8)
	main._walk_cells[u.id] = Vector2i(3, 5)
	ck(not main._visible_before_impact(0).has(target), "walk presentation initially hides side room")
	main._walk_cells[u.id] = Vector2i(5, 8)
	ck(main._visible_before_impact(0).has(target), "fog reveals side room at intermediate walk cell")
	ck(u.coord == Vector2i(2, 5), "animated sight never changes authoritative unit position")
	main._walk_cells.clear()
	ck(not main._visible_before_impact(0).has(target), "final sight returns to simulation position")
	main.recorder = null
	main.queue_free()
	await process_frame

func heavy_capture_ui() -> void:
	var r := arena()
	var s := r.state
	var captive := s.grid.cell(Vector2i(2, 5)).occupant
	var captor := s.grid.cell(Vector2i(18, 5)).occupant
	captive.stats = load("res://src/data/units/heavy_infantry.tres")
	captor.stats = captive.stats
	s.grid.move_occupant(captor.coord, Vector2i(3, 5))
	s.turns.active_index = 1
	s.dice.feed_scripted([6, 1])
	r.resolve(CaptureIntent.new(captor.id, captive.id))
	s.turns.active_index = 0
	SaveHandoff.pending_save = {"state": StateCodec.encode(s), "rules": StateCodec.encode_rules(r)}
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._paused = true
	main._select(main.state.get_unit(captive.id))
	main.state.dice.feed_scripted([6])
	# Exercise the combat UI's actual resolve/animation/menu refresh path.
	main._fast_playback = true
	main._submit(ReleaseIntent.new(captive.id))
	for i in 600:
		if not main._animating: break
		if main._dice._roll_btn.visible: main._dice._roll_btn.pressed.emit()
		await create_timer(0.01).timeout
	ck(not main._animating, "break-free animation finishes and restores combat controls")
	ck(main.state.get_unit(captive.id).is_alive(), "heavy infantry breaks free through the combat UI")
	main._enter_shoot()
	ck(main.target_ids.has(captor.id), "combat UI offers former heavy infantry captor as a shooting target")
	main.recorder = null
	main.queue_free()
	await process_frame

func spawn_controls() -> void:
	GameConfig.holdout_excluded_units = []
	GameConfig.raider_excluded_units = []
	var lobby = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	for waves in [true, false]:
		lobby._open_spawn_restrictions(waves)
		var dialog := lobby.get_child(lobby.get_child_count() - 1) as AcceptDialog
		var checks := dialog.find_children("*", "CheckBox", true, false)
		ck(checks.size() == GameActionResolver.ARMY_ROSTER.size(), "spawn restriction dialog lists all soldier types")
		(checks[0] as CheckBox).button_pressed = false
		ck((GameConfig.holdout_excluded_units if waves else GameConfig.raider_excluded_units).has(GameActionResolver.ARMY_ROSTER[0]), "unticking a soldier excludes it from this mode")
		dialog.free()
	var encoded := NetHandoff.encode_rules()
	GameConfig.holdout_excluded_units = []
	GameConfig.raider_excluded_units = []
	NetHandoff.apply_rules(JSON.parse_string(JSON.stringify(encoded)))
	ck(GameConfig.holdout_excluded_units == [GameActionResolver.ARMY_ROSTER[0]] and GameConfig.raider_excluded_units == GameConfig.holdout_excluded_units, "spawn restrictions reach network guests")
	GameConfig.holdout_excluded_units = []
	GameConfig.raider_excluded_units = []
	lobby.queue_free()
	await process_frame
