extends "res://tests/SuiteBase.gd"
## Shield bearers: Shield Push on glass, sweeping items, surviving blasts beside them,
## wave shields against fire.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	_shield_glass()

	wave_shields_and_fire()

	shield_blasts()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_shield_sweep()

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

func wave_shields_and_fire() -> void:
	GameConfig.game_mode = MatchMode.Kind.HOLDOUT
	GameConfig.random_events_enabled = false
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	GameConfig.roster = ro
	var map := MapData.blank_arena(30, 20)
	map.set_spawn(Vector2i(14, 10), "heavy_infantry", 0)
	var r := GameActionResolver.new(map.build_state(11, ro))
	r.random_events = RandomEvents.new(false)
	r.prepare_mode(map)
	r.fog_enabled = false
	var sb := r.state.spawn_unit(load("res://src/data/units/shield_bearer.tres"), Vector2i(20, 15), r.mode.wave_side)
	r._blast(Vector2i(21, 15), ActionResult.success(), [], true, true)
	ck(r._is_wave_fighter(sb) and sb.is_alive(), "a wave's shield bearer survives a drone blast beside it")
	for y in range(0, 4):
		for x in range(4, 13):
			r.state.grid.cell(Vector2i(x, y)).on_fire = true
	r.mode.defender_value = 400
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	var landed := 0
	var burning := 0
	for u: UnitInstance in r.state.all_units():
		if u.owner == r.mode.wave_side and u != sb and u.is_on_field():
			landed += 1
			if r.state.grid.cell(u.coord).on_fire: burning += 1
	ck(landed > 0 and burning == 0, "a wave lands beside the fire, never in it (%d landed)" % landed)
	var hall := r._hallway_spawn_cells(Vector2i(8, 6))
	ck(not hall.is_empty() and hall.all(func(c: Vector2i) -> bool: return not r.state.grid.cell(c).on_fire),
		"raider landing cells skip burning floor")
	for y in range(0, 4):
		for x in range(4, 13):
			r.state.grid.cell(Vector2i(x, y)).on_fire = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func shield_blasts() -> void:
	var map := arena()
	map.set_spawn(Vector2i(5, 5), "shield_bearer", 1)
	map.set_spawn(Vector2i(10, 5), "light_infantry", 0)
	var r := resolver_for(map)
	var s := r.state
	var sb: UnitInstance = s.grid.cell(Vector2i(5, 5)).occupant
	var thrower: UnitInstance = s.grid.cell(Vector2i(10, 5)).occupant
	r._explode_frag(thrower, sb.coord)
	ck(sb.is_alive(), "a frag grenade on its cell never kills a shield bearer")
	r._blast(sb.coord, ActionResult.success(), [], true)
	ck(sb.is_alive(), "mines and exploding wrecks spare a shield bearer even on its cell")
	r._destroy_cell(sb.coord, ActionResult.success())
	ck(sb.is_alive(), "an artillery shell on its cell spares a shield bearer")
	r._blast(Vector2i(6, 5), ActionResult.success(), [], true, true)
	ck(sb.is_alive(), "a shell or AT round beside it does not kill a shield bearer")
	r._blast(sb.coord, ActionResult.success(), [], true, true)
	ck(not sb.is_alive(), "a direct tank, AT or drone hit kills it")

func _shield_sweep() -> void:
	var m := MapData.blank_arena(18, 10)
	m.set_spawn(Vector2i(2, 5), "shield_bearer", 0)
	m.set_spawn(Vector2i(16, 8), "light_infantry", 1)
	m.items = [["mug", 4.5, 5.5, 0.0]]
	var st := m.build_state(3)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r := GameActionResolver.new(st)
	var fx := FxDecals.new()
	fx._settle(fx.props, {"kind": "chunk:wall_town#0", "pos": Vector2(4.4, 5.5), "rot": 0.0, "scale": 1.0})
	var result := r.resolve(MoveIntent.new(st.grid.cell(Vector2i(2, 5)).occupant.id, Vector2i(5, 5)))
	fx.apply(result.fx)
	ck(result.ok and (st.grid.cell(Vector2i(4, 5)).items_off & 1) != 0, "a shield-bearer pushes a map item crossed during a multi-cell move")
	ck(fx.props.is_empty() and fx.flying.size() >= 2, "the shield pushes settled debris and the loose item forward")
