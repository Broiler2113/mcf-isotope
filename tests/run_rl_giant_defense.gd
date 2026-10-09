extends SceneTree

const Obs = preload("res://rl/ObsEncoder.gd")
const Budget = preload("res://rl/IntentBudget.gd")

func _initialize() -> void:
	GameConfig.civilians_enabled = false
	var m := MapData.new(80, 60)
	for y in m.height:
		for x in m.width:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for n in 80:
		m.set_spawn(Vector2i(9 + n % 12, 9 + n / 12),
				"anti_tank" if n == 23 else "light_infantry", 0)
	m.set_spawn(Vector2i(25, 11), "tank", 1, Vector2i(-1, 0))
	m.set_spawn(Vector2i(55, 50), "light_infantry", 1)
	var state := m.build_state(37)
	var tank: Vehicle = state.all_vehicles()[0]
	var crew: UnitInstance = state.living_units_of(1)[0]
	tank.occupants.append(crew.id)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var risk := Obs.vehicle_crush_threat(r, 0)
	if risk[12 * m.width + 18] <= 0.0 or risk[35 * m.width + 18] != 0.0:
		_fail("the visible tank's swept lane was not marked")
		return
	var tac := Obs.tactics(r, 0)
	var wire := Obs.encode(r, 0, 40, tac)
	if int(wire["vcrush"][12 * m.width + 18]) <= 0:
		_fail("the policy observation lost the drive lane")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var subset := Budget.actor_subset(r, 0, 2, rng)
	var anti_tank: UnitInstance = null
	for u: UnitInstance in state.living_units_of(0):
		if u.stats.special_ability_id == MCF.ABILITY_ANTI_TANK:
			anti_tank = u
			break
	if anti_tank == null or not subset.has(anti_tank.id):
		_fail("anti-tank responder was hidden by the actor budget")
		return
	var candidates: Array = [EndTurnIntent.new(), MoveIntent.new(anti_tank.id,
			anti_tank.coord + Vector2i(1, 0))]
	var active := Budget.keep_large_army_active(candidates, state, 0)
	if active.size() != 1 or active[0] is EndTurnIntent:
		_fail("large army could end with almost all AP unused")
		return
	for u: UnitInstance in state.living_units_of(0):
		u.remaining_ap = 0
	if Budget.keep_large_army_active(candidates, state, 0).size() != 2:
		_fail("EndTurn remained blocked after all AP was spent")
		return
	tank.components[MCF.COMP_TRACKS_L] = 0
	if Obs.vehicle_crush_threat(r, 0)[12 * m.width + 18] != 0.0:
		_fail("a disabled tank still threatened to drive")
		return
	tank.components[MCF.COMP_TRACKS_L] = tank.component_max(MCF.COMP_TRACKS_L)
	state.grid.clear_vehicle_footprint(tank.id, tank.footprint())
	tank.origin = Vector2i(65, 11)
	state.grid.set_vehicle_footprint(tank.id, tank.footprint())
	for y in state.grid.height:
		state.grid.cell(Vector2i(40, y)).cover_height = MCF.WALL_HEIGHT
	r.fog_mode = MCF.Fog.STANDARD
	if r.team_visible_coords(0).has(tank.center()) or \
			Obs.vehicle_crush_threat(r, 0)[12 * m.width + 58] != 0.0:
		_fail("a hidden tank leaked its drive lane through fog")
		return
	print("giant defense: visible drive lane, anti-tank offer, AP gate, disabled tracks and fog OK")
	quit(0)

func _fail(message: String) -> void:
	printerr(message)
	quit(1)
