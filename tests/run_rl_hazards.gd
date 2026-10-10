extends "res://rl/env_server.gd"
## Exercise actual observations, movement rewards, and event RNG without a policy.
var failures: Array[String] = []
const Budget = preload("res://rl/IntentBudget.gd")

func ck(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)

func setup_field() -> void:
	var m := MapData.new(30, 20)
	for y in m.height:
		for x in m.width:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(4, 4), "light_infantry", 0)
	m.set_spawn(Vector2i(27, 17), "light_infantry", 1)
	m.save_to("user://rl_hazard_fixture.json")
	_reset({"map": "user://rl_hazard_fixture.json", "seed": 7, "side": 0,
			"opponent": -1, "round_cap": 30, "max_steps": 500,
			"fog": MCF.Fog.STANDARD, "civilians": false, "random_events": true,
			"random_event_interval": 6, "potential_coef": 0.0, "hazard_coef": 0.5,
			"gamma": 0.9})
	while state.active_player() != 0:
		resolver.resolve(EndTurnIntent.new())
	resolver.random_events.pending = []
	resolver.random_events.clouds = []
	resolver.random_events.turns_since = 0
	_potential_pending = false

func select_move(target: Vector2i) -> int:
	for k in _legal.size():
		if _legal[k] is MoveIntent and _legal[k].target == target:
			return k
	return -1

func _initialize() -> void:
	setup_field()
	var u: UnitInstance = state.living_units_of(0)[0]
	var origin := u.coord
	var safe := origin + Vector2i(2, 0)
	# Announced rectangles remain public even when the terrain/units are hidden.
	resolver.random_events.announce(RandomEvents.MORTAR,
			{"x": 24, "y": 15, "w": 2, "h": 2}, state.turns.round_number)
	var hz := Obs.hazards(resolver)
	ck(hz["artillery_warning"][15 * 30 + 24] == 1.0, "one-turn public warning survives fog")
	ck(hz["gas"][15 * 30 + 24] == 0.0, "artillery is separate from gas")
	resolver.random_events.pending = []
	for kind: String in ["active_gas", RandomEvents.GAS, RandomEvents.MORTAR]:
		setup_field()
		u = state.living_units_of(0)[0]
		if kind == "active_gas":
			resolver.random_events.add_cloud(origin.x, origin.y, 2, 1, 3)
		else:
			resolver.random_events.announce(kind,
					{"x": origin.x, "y": origin.y, "w": 2, "h": 1}, state.turns.round_number)
		var r := _response(0.0, true)
		var obs: Dictionary = r["obs"]
		ck(obs["gas"][origin.y * 30 + origin.x] == (1.0 if kind == "active_gas" else 0.0),
				"active gas layer: " + kind)
		# A large army must expose threatened actors and escape cells through both caps.
		for n in 20:
			state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(10 + n % 10, 10 + n / 10), 0, false)
		var rng := RandomNumberGenerator.new()
		rng.seed = 10
		ck(Budget.actor_subset(resolver, 0, 1, rng).has(u.id), "endangered actor survives the actor cap")
		var moves: Array = []
		for intent: Intent in resolver.legal_intents(0, {u.id: true}):
			if intent is MoveIntent:
				moves.append(intent)
		var ordered := Budget._tactical_order(moves, resolver, 0)
		var best: Vector2i = ordered[0].target
		var best_risk := Obs._hazard_at(Obs.tactics(resolver, 0), best)
		ck(best_risk[0] + best_risk[1] + best_risk[2] == 0.0, "hazard-aware cap retains a safe escape")
		_last_hazard_phi = _hazard_phi(Obs.hazards(resolver))
		var phi_before := _last_hazard_phi
		ck(phi_before < 0.0, "unsafe position has negative potential: " + kind)
		var k := select_move(safe)
		ck(k >= 0, "escape is legal: " + kind)
		if k < 0:
			continue
		ck(r["legal"][k]["hazard"][0] + r["legal"][k]["hazard"][1]
				+ r["legal"][k]["hazard"][2] > 0.0, "candidate knows actor danger")
		ck(r["legal"][k]["hazard"][3] + r["legal"][k]["hazard"][4]
				+ r["legal"][k]["hazard"][5] == 0.0, "candidate knows destination is safe")
		r = _step({"action": k})
		var escape: float = r["info"]["hazard_reward"]
		ck(r["info"]["action_ok"] and escape > 0.0, "successful escape pays: " + kind)
		ck(is_equal_approx(escape, -0.5 * phi_before), "exact escape potential payment")
		k = select_move(origin)
		ck(k >= 0, "re-entry is legal")
		if k >= 0:
			r = _step({"action": k})
			var reentry: float = r["info"]["hazard_reward"]
			ck(reentry < 0.0, "re-entry costs reward: " + kind)
			ck(is_equal_approx(escape + _gamma * reentry,
					0.5 * (_gamma * _gamma - 1.0) * phi_before), "discounted loop telescopes")
	# Sealed vehicles/crew ignore gas, but artillery checks the ENTIRE footprint.
	setup_field()
	state.spawn_vehicle("tank", Vector2i(10, 10), 0)
	resolver.random_events.add_cloud(10, 10, 3, 3, 3)
	ck(_hazard_phi(Obs.hazards(resolver)) == 0.0, "sealed vehicle is safe from gas")
	resolver.random_events.announce(RandomEvents.MORTAR,
			{"x": 10, "y": 10, "w": 1, "h": 1}, state.turns.round_number)
	ck(_hazard_phi(Obs.hazards(resolver)) < 0.0, "artillery on a footprint edge threatens vehicle")
	# Normal seeded events actually announce/land in the headless environment.
	setup_field()
	resolver.random_events.weights = {RandomEvents.GAS: 1, RandomEvents.MORTAR: 0, RandomEvents.ARMY: 0}
	var warnings := 0
	var clouds := 0
	for step in 35:
		var r := _response(0.0, true)
		if r["done"]:
			break
		warnings += r["info"]["event_pending"]
		clouds += r["info"]["gas_clouds"]
		var end := -1
		for k in _legal.size():
			if _legal[k] is EndTurnIntent:
				end = k
		_step({"action": end})
	ck(warnings > 0, "normal seed produces occasional warnings")
	ck(clouds > 0, "normal seed lands gas clouds")
	ck(resolver.random_events.weights[RandomEvents.ARMY] == 0, "hazard training keeps two player seats")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://rl_hazard_fixture.json"))
	if not failures.is_empty():
		for f in failures:
			printerr(f)
		quit(1)
		return
	print("RL hazards: public warnings, escape rewards, re-entry costs, vehicle immunity, seeded events passed")
	quit(0)
