extends SceneTree
## 2026-10-18 audit of 0.12.3–0.12.8: ghost units on bodies, Holdout AI fire rules,
## burnt drone stations, silent host refusals and dice spent on an empty event pool.

var failures: Array[String] = []
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()

func arena(body_under_spawn := false) -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 5), "light_infantry", 1)
	if body_under_spawn: map.corpses.append(5 * 22 + 18)
	var s := map.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

func add(r: GameActionResolver, kind: String, c: Vector2i, side: int = 0) -> UnitInstance:
	return r.state.spawn_unit(load("res://src/data/units/%s.tres" % kind), c, side)

func ghosts(r: GameActionResolver) -> int:
	return r.state.all_units().filter(func(u: UnitInstance) -> bool:
		return u.is_on_field() and u.aboard_vehicle_id == -1 and u.borg_id == -1 \
			and r.state.grid.cell(u.coord).occupant != u).size()

func run() -> void:
	var r := arena(true)
	ck(ghosts(r) == 0 and r.state.grid.cell(Vector2i(18, 5)).occupant != null, "a map spawn on a body stands there; the body gives way")
	r.state.grid.cell(Vector2i(10, 10)).corpse_count = 1
	var before := r.state.all_units().size()
	ck(add(r, "light_infantry", Vector2i(10, 10)) == null and r.state.all_units().size() == before, "spawn_unit refuses a body cell instead of creating a ghost")

	r = arena()
	for y in 16:
		for x in range(17, 22):
			if r.state.grid.cell(Vector2i(x, y)).occupant == null: r.state.grid.cell(Vector2i(x, y)).corpse_count = 1
	r.state.grid.cell(Vector2i(21, 8)).corpse_count = 0
	r._land_army({"edge": 1, "along": 8}, ActionResult.success([]))
	var raiders := r.state.all_units().filter(func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner))
	ck(raiders.size() >= 1 and ghosts(r) == 0, "raiders land only on cells free of bodies (%d)" % raiders.size())

	r = arena()
	r.mode.kind = MatchMode.Kind.HOLDOUT
	r.mode.wave_side = 1
	r.mode.defender_value = 300
	for x in 22:
		r.state.grid.cell(Vector2i(x, 0)).corpse_count = 1
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	ck(ghosts(r) == 0, "Holdout waves never land on bodies")

	# Wave flamers and shields lost their immunity in the rules; the AI must know it too.
	var flame := add(r, "flamethrower", Vector2i(8, 8), 1)
	var shield := add(r, "shield_bearer", Vector2i(8, 9), 1)
	var mine := add(r, "flamethrower", Vector2i(4, 12), 0)
	var ai := AIController.new(1)
	ai._r = r
	ck(ai._avoids_fire(flame) and ai._avoids_fire(shield), "wave AI keeps flamers and shields away from fire")
	ck(not ai._avoids_fire(mine), "a defender's flamethrower is still fireproof to the AI")
	var planner := AIPlanner.new()
	planner._r = r
	planner._state = r.state
	r.state.grid.cell(Vector2i(12, 12)).on_fire = true
	ck(planner._score_cell(flame, Vector2i(12, 11), 0, 0, false) <= -1e8, "planner refuses fire-adjacent cells for wave flamers")
	# Fire on a mounted station frees its shuttle seat, like a blast.
	r = arena()
	var s := r.state
	var shuttle := s.spawn_vehicle("shuttle", Vector2i(6, 6), 0)
	var driver := add(r, "civilian", Vector2i(5, 5))
	var op := add(r, "drone_operator", Vector2i(8, 5))
	r.resolve(VehicleBoardIntent.new(driver.id, shuttle.id, 0))
	r.resolve(VehicleBoardIntent.new(op.id, shuttle.id, 1))
	var at := shuttle.seat_cell(3)
	ck(r.resolve(UseItemIntent.new(op.id, at)).ok, "station mounts in the fourth seat")
	r._ignite(s.grid.cell(at), 1, ActionResult.success([]))
	ck(s.grid.cell(at).feature_id == "" and shuttle.seats[3] == -1, "a burnt station releases its shuttle seat")

	# The host answers an intent for someone else's unit, so the sender's controls unlock.
	r = arena()
	r.state.roster.slot(1).kind = Roster.SlotKind.HUMAN
	r.state.roster.slot(1).peer_id = 7
	var host := NetGame.new(r.state, r, true)
	var sent: Array = []
	host.outgoing.connect(func(m: Dictionary) -> void: sent.append(m))
	var foreign := r.state.grid.cell(Vector2i(2, 5)).occupant
	host.receive({"k": NetGame.K_INTENT, "_from": 7, "i": IntentCodec.encode(MoveIntent.new(foreign.id, Vector2i(3, 5)))})
	ck(sent.size() == 1 and sent[0].k == NetGame.K_DENIED and int(sent[0].p) == 1, "unauthorized guest request is denied to its sender")
	var guest := NetGame.new(r.state, r, false, 1)
	var unlocked := [false]
	guest.denied.connect(func(_why: String) -> void: unlocked[0] = true)
	guest.receive(sent[0])
	ck(unlocked[0], "the guest receives the denial")

	# No dice for an event pool with nothing eligible; 0.12.7–0.12.8 replays keep the old tape.
	var ev := RandomEvents.new(true, true, 1, {RandomEvents.BOUNTY: 1})
	var dice := DiceService.new()
	dice.feed_scripted([])
	ck(ev._pick(dice, {RandomEvents.MORTAR: true}) == "" and dice.fallback_rolls == 0, "an empty event pool rolls no dice")
	ev.empty_pool_rolls = true
	dice.feed_scripted([1, 1, 1])
	ck(ev._pick(dice, {RandomEvents.MORTAR: true}) == "" and dice.scripted_remaining() == 0, "older uniform replays still consume their three dice")

	print("audit 0.12.8: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
