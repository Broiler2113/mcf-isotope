extends SceneTree
## Playtest 21 (2026-10-19): undo after an LDF wall, borg bursts, shield-bearer blasts,
## orphaned captives, drone stations, Holdout wave frequency, flamethrower armor, pulled
## bodies, fire and decals, the drawing panel, and the AI around vehicles and the beam.

var fails := 0
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails += 1

func _initialize() -> void: run.call_deferred()

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func turn_to(r: GameActionResolver, side: int) -> void:
	var guard := 0
	while r.state.active_player() != side and guard < 10:
		r.resolve(EndTurnIntent.new())
		guard += 1

func run() -> void:
	await undo_after_ldf()
	borg_burst()
	shield_blasts()
	captives()
	stations()
	waves()
	flamer_armor()
	pulled_bodies()
	fire_keeps_decals()
	await drawing_panel()
	ai_vehicles_and_beam()
	print("playtest21: %d failure(s)" % fails)
	quit(0 if fails == 0 else 1)

func undo_after_ldf() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	map.set_spawn(Vector2i(10, 8), "engineer", 0)
	MapHandoff.pending = map
	var board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	board.state.turns.round_order.assign([0, 1])
	board.state.turns.active_index = 0
	board._refresh_status()
	var eng: UnitInstance = board.state.grid.cell(Vector2i(10, 8)).occupant
	eng.held_item_id = MCF.ITEM_LDF
	eng.remaining_ap = 6
	board._select(eng)
	board._enter_build_wall()
	for x in range(11, 17):
		board._wall_try_add(Vector2i(x, 8))
	for i in 120:
		await process_frame
		if not board._animating: break
	ck(board.state.grid.cell(Vector2i(12, 8)).feature_id == MCF.FEATURE_LDF and board._wall_cells.is_empty(),
		"a built LDF wall leaves no drawing behind")
	board._deselect()
	var u: UnitInstance = board.state.grid.cell(Vector2i(3, 4)).occupant
	board._submit(MoveIntent.new(u.id, Vector2i(5, 4)))
	for i in 120:
		await process_frame
		if not board._animating: break
	board._on_undo_pressed()
	for i in 30:
		await process_frame
	ck(u.coord == Vector2i(3, 4), "Undo takes back the move made after building an LDF wall")
	board.queue_free()
	await process_frame

func borg_burst() -> void:
	var map := arena()
	map.set_spawn(Vector2i(6, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(14, 8), "light_infantry", 1)
	map.set_spawn(Vector2i(7, 14), "light_infantry", 1)
	var r := resolver_for(map)
	var s := r.state
	var u: UnitInstance = s.grid.cell(Vector2i(6, 8)).occupant
	var borg := s.spawn_vehicle("borg", Vector2i(7, 8), 0)
	turn_to(r, 0)
	r.resolve(VehicleBoardIntent.new(u.id, borg.id))
	var t1: UnitInstance = s.grid.cell(Vector2i(14, 8)).occupant
	var t2: UnitInstance = s.grid.cell(Vector2i(7, 14)).occupant
	s.dice.feed_scripted([6, 1, 6, 1, 6, 1, 6, 1])
	var first := r.resolve(ShootIntent.new(u.id, t1.id, 1))
	ck(first.ok and not t1.is_alive() and u.action_state != null and u.action_state.remaining_shots == 3,
		"a borg that kills with one round keeps the other three")
	var ap := u.remaining_ap
	var second := r.resolve(ShootIntent.new(u.id, t2.id))
	ck(second.ok and u.remaining_ap == ap and not t2.is_alive(), "the rest of the burst goes to another target without AP")

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

func captives() -> void:
	var map := arena()
	map.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(5, 4), "heavy_infantry", 1)
	var r := resolver_for(map, 3)
	var s := r.state
	var a: UnitInstance = s.grid.cell(Vector2i(5, 5)).occupant
	var raider := s.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(6, 5), MCF.independent_slot(1))
	raider.status = MCF.Status.HELD
	raider.captor_id = a.id
	turn_to(r, 1)
	var hv: UnitInstance = s.grid.cell(Vector2i(5, 4)).occupant
	s.dice.feed_scripted([6, 1, 6, 1, 6, 1])
	r.resolve(CaptureIntent.new(hv.id, a.id))
	ck(a.is_held() and not raider.is_held() and raider.captor_id == -1,
		"a captor that is grabbed lets its own captive go at once")
	var b := arena()
	b.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	b.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	var r2 := resolver_for(b, 4)
	var a2: UnitInstance = r2.state.grid.cell(Vector2i(5, 5)).occupant
	var held := r2.state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(12, 12), MCF.independent_slot(1))
	held.status = MCF.Status.HELD
	held.captor_id = a2.id
	turn_to(r2, 0)
	r2.resolve(MoveIntent.new(a2.id, Vector2i(6, 5)))
	ck(not held.is_held(), "a captive left far from a living captor is freed after the next action")

func stations() -> void:
	var map := arena()
	map.set_spawn(Vector2i(5, 5), "drone_operator", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	var r := resolver_for(map, 3)
	var s := r.state
	var op: UnitInstance = s.grid.cell(Vector2i(5, 5)).occupant
	var st := Vector2i(6, 5)
	for cycle in 3:
		turn_to(r, 0)
		r.resolve(UseItemIntent.new(op.id, st))
		r.resolve(SpawnDroneIntent.new(op.id, st))   # a second drone hovers beside the pad
		turn_to(r, 1)
		turn_to(r, 0)
		var res := r.resolve(PickUpStationIntent.new(op.id, st))
		ck(res.ok and op.held_item_id == MCF.ITEM_DRONE_STATION, "cycle %d: the station packs up with both drones" % cycle)

func waves() -> void:
	GameConfig.holdout_wave_every = 3
	var md := MatchMode.from_config()
	ck(md.wave_every == 3, "the lobby's wave frequency reaches the match")
	var back := MatchMode.new()
	back.restore(md.snapshot())
	ck(back.wave_every == 3, "wave frequency survives saves")
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
	r.mode.defender_value = 400
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	ck(r.mode.next_wave_round == r.state.turns.round_number + 3, "the next wave is due three rounds later")
	GameConfig.holdout_wave_every = MatchMode.WAVE_EVERY
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

func flamer_armor() -> void:
	ck((load("res://src/data/units/flamethrower.tres") as UnitStats).armor_threshold == 4, "flamethrowers have 4+ armor")

func pulled_bodies() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 9), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 14), "light_infantry", 1)
	var r := resolver_for(map, 5)
	var s := r.state
	var u: UnitInstance = s.grid.cell(Vector2i(3, 9)).occupant
	var tank := s.spawn_vehicle("tank", Vector2i(4, 8), 0)
	tank.corpse_slots.append("Crewman A")
	tank.corpse_slots.append("Crewman B")
	var cells: Array[Vector2i] = r.unload_corpse_cells(u, tank)
	ck(cells.has(u.coord) and cells.has(Vector2i(2, 9)), "the body can go beside the puller or into its arms")
	var drop := r.resolve(VehicleUnloadCorpseIntent.new(u.id, tank.id, Vector2i(2, 9)))
	ck(drop.ok and s.grid.cell(Vector2i(2, 9)).corpse_count == 1, "the pulled body lands on the chosen cell")
	var carry := r.resolve(VehicleUnloadCorpseIntent.new(u.id, tank.id, u.coord))
	ck(carry.ok and u.carried_corpses == 1 and tank.corpse_slots.is_empty(), "clicking the puller makes it carry the body")
	var wire := IntentCodec.decode(IntentCodec.encode(VehicleUnloadCorpseIntent.new(u.id, tank.id, Vector2i(2, 9))))
	ck(wire is VehicleUnloadCorpseIntent and wire.to == Vector2i(2, 9), "the chosen cell travels over the network")
	var plain := IntentCodec.decode(IntentCodec.encode(VehicleUnloadCorpseIntent.new(u.id, tank.id)))
	ck(plain.to == VehicleUnloadCorpseIntent.NOWHERE, "an unaimed pull stays unaimed")

func fire_keeps_decals() -> void:
	var fx := FxDecals.new()
	fx._settle(fx.props, {"kind": "casing", "pos": Vector2(3.5, 3.5), "rot": 0.0, "scale": 1.0})
	fx._settle(fx.gore, {"kind": "blood_pool", "pos": Vector2(3.4, 3.6), "rot": 0.0, "scale": 1.0})
	fx.audio_suppressed = true
	fx.apply([{"fx": "burn", "cells": [Vector2i(3, 3)]}])
	ck(fx.props.size() == 1 and fx.gore.size() == 1, "fire no longer deletes the decals on its cells")

func drawing_panel() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	MapHandoff.pending = map
	var board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	ck(board.DRAW_COLOURS[0].a > 0.0 and board._draw_colour == board.DRAW_COLOURS[0], "the first and default colour is not the faction colour")
	var crosses: Array = board._draw_panel.find_children("*", "Button", true, false).filter(
		func(b: Button) -> bool: return b.text == "×")
	ck(crosses.is_empty(), "the drawing panel has no close cross")
	board._draw_panel.visible = true
	board._menu.position = Vector2(12, 44)
	board._menu.size = Vector2(220, 300)
	board._menu.visible = true
	board._reposition_hud_grip()
	ck(board._draw_panel.position.x >= board._menu.position.x + board._menu.size.x, "the drawing panel steps right of an open action menu")
	board._menu.visible = false
	board._reposition_hud_grip()
	ck(is_equal_approx(board._draw_panel.position.x, 12.0), "and comes back when the menu closes")
	board.queue_free()
	await process_frame

func ai_vehicles_and_beam() -> void:
	# A marksman whose beam would die in the walls does not fire; with a clear line it does.
	var map := arena()
	map.set_spawn(Vector2i(2, 5), "marksman", 0)
	map.set_spawn(Vector2i(12, 5), "light_infantry", 1)
	for x in range(4, 9):
		map.set_cell(Vector2i(x, 5), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var r := resolver_for(map, 9)
	var s := r.state
	var mk: UnitInstance = s.grid.cell(Vector2i(2, 5)).occupant
	var ai := AIController.new(0, AIController.Difficulty.HARD)
	ai.bind_match(r)
	var beam: Dictionary = ai._laser_outcome(s, r, mk, Vector2i(12, 5))
	ck((beam["kills"] as Array).is_empty(), "five walls drain the beam before the target")
	var shot: Dictionary = ai._best_shoot(s, r, mk)
	ck(shot.is_empty(), "the AI marksman does not waste a shot the walls would swallow")
	for x in range(4, 9):
		s.grid.cell(Vector2i(x, 5)).clear_feature()
		s.grid.cell(Vector2i(x, 5)).cover_height = 0.0
	shot = ai._best_shoot(s, r, mk)
	ck(not shot.is_empty(), "with a clear line the AI marksman fires")
	# Marksmen and anti-tank soldiers deal with tanks; nobody else hugs the hull.
	var vmap := arena(30, 20)
	vmap.set_spawn(Vector2i(2, 10), "marksman", 0)
	vmap.set_spawn(Vector2i(4, 16), "anti_tank", 0)
	vmap.set_spawn(Vector2i(6, 4), "light_infantry", 0)
	vmap.set_spawn(Vector2i(27, 2), "light_infantry", 1)
	var vr := resolver_for(vmap, 13)
	var vs := vr.state
	var tank := vs.spawn_vehicle("tank", Vector2i(14, 9), 1)
	var mk2: UnitInstance = vs.grid.cell(Vector2i(2, 10)).occupant
	var at: UnitInstance = vs.grid.cell(Vector2i(4, 16)).occupant
	var vai := AIController.new(0, AIController.Difficulty.HARD)
	vai.bind_match(vr)
	var vshot: Dictionary = vai._best_vehicle_shot(vs, vr, mk2)
	ck(not vshot.is_empty(), "the AI marksman burns an enemy tank on its line")
	vai._r = vr
	var approach: Dictionary = vai._move_to_vehicle(vs, at)
	if not approach.is_empty():
		var dest: Vector2i = approach["intent"].target
		var nearest := 99
		for fc: Vector2i in tank.footprint():
			nearest = mini(nearest, Combat.distance(dest, fc))
		ck(nearest >= AIPlanner.AT_MIN_RANGE, "the anti-tank soldier stops at firing distance (%d)" % nearest)
	else:
		ck(true, "the anti-tank soldier has no approach to make")
	turn_to(vr, 0)
	vai.begin_turn(vs)
	var close: float = float(vai._planner._veh_close.get(tank.footprint()[0] + Vector2i(-1, 0), 0.0))
	ck(vai._planner._gun_spread and close > 0.0, "the plan sees the tank's gun and the danger beside its hull")
