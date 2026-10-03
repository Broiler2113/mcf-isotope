extends SceneTree

## Бюджет намерений обучения (rl/IntentBudget.gd): то, что НЕ дошло до политики, она не
## выучит никогда. Три дыры, найденные на карте дронов и танков:
##   1. Выдохшийся дрон (одно ОД ушло на подлёт) проигрывал жеребьёвку актёров, и его
##      бесплатный подрыв почти не предлагался — дрон висел над врагом до следующего хода.
##   2. Из сотен клеток полёта до списка доходили случайные, а не клетка над скоплением.
##   3. Экипаж, запертый в танке, считался «готовым» и занимал места пехоты.
##   4. Боец, которому есть в кого стрелять, проигрывал жеребьёвку праздным (оценка tactical-1).

const TS = preload("res://tests/TestSupport.gd")
const Budget = preload("res://rl/IntentBudget.gd")

var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _initialize() -> void:
	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var side := MCF.Owner.PLAYER_1
	var pilot: UnitInstance = state.living_units_of(side)[0]
	var station := pilot.coord + Vector2i(1, 0)
	state.grid.cell(station).feature_id = MCF.FEATURE_DRONE_STATION
	state.grid.cell(station).feature_owner = side
	var drone := r._launch_drone_at(station, pilot)
	ck(drone != null, "the drone launches")
	if drone == null:
		_finish()
		return
	# Одиночка ближе, скопление из трёх дальше: «ближайший» и «лучший» — разные клетки.
	var inf: UnitStats = load("res://src/data/units/light_infantry.tres")
	state.spawn_unit(inf, pilot.coord + Vector2i(3, 2), MCF.Owner.PLAYER_2, false)
	for c: Vector2i in [Vector2i(10, 6), Vector2i(11, 6), Vector2i(10, 7)]:
		state.spawn_unit(inf, c, MCF.Owner.PLAYER_2, false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7

	# 1. Выдохшийся дрон над скоплением: в подмножестве и с подрывом, даже при двух местах.
	drone.remaining_ap = 0
	drone.move_credit = 0
	var home := drone.coord
	drone.coord = Vector2i(10, 6)
	for i in 20:
		var sub := Budget.actor_subset(r, side, 2, rng)
		ck(sub.has(drone.id), "a spent drone is always among the actors (try %d)" % i)
		var det := false
		for it: Intent in Budget.cap(r.legal_intents(side, sub), 64, rng, r, side):
			det = det or (it is DroneDetonateIntent and it.actor_id == drone.id)
		ck(det, "its free detonation is offered (try %d)" % i)
	drone.coord = home

	# 2. С ОД: первой из клеток полёта в списке идёт та, что накрывает больше всех врагов.
	drone.remaining_ap = 1
	var zone := Budget.hostile_zone(r, side)
	var best := 0
	for c: Vector2i in r.drone_flight_cells(drone):
		best = maxi(best, int(zone.get(c, 0)))
	ck(best == 3, "the fixture has a cell over all three of the cluster (best %d)" % best)
	for i in 20:
		var first := -1
		for it: Intent in Budget.cap(r.legal_intents(side, {}), 40, rng, r, side):
			if it is DroneMoveIntent and it.actor_id == drone.id:
				first = int(zone.get(it.target, 0))
				break
		ck(first == best, "the best blast cell comes first, not a random one (got %d, try %d)"
				% [first, i])

	# 3. Экипаж за картой при запрете высадки не «готов»; с разрешённой — готов.
	var crew: UnitInstance = state.living_units_of(side)[1]
	var at := crew.coord
	crew.aboard_vehicle_id = 999
	crew.coord = Vector2i(-5, -5)
	r.disembark_enabled = false
	ck(not Budget.can_act(r, crew, {}), "a sealed crewman has nothing to do")
	r.disembark_enabled = true
	ck(Budget.can_act(r, crew, {}), "a crewman who may disembark can act")
	crew.aboard_vehicle_id = -1
	crew.coord = at

	# 4. Кому есть в кого стрелять — первым в жребии. На оценке tactical-1 жребий 16 из ~46
	#    показывал выстрел снайпера лишь в 46% точек, где он был законен.
	var sniper := state.spawn_unit(load("res://src/data/units/sniper.tres"),
			Vector2i(10, 10), side, false)
	for i in 6:
		state.spawn_unit(inf, Vector2i(1 + i, 1), side, false)
	var foes := Budget._foe_cells(r, side)
	ck(Budget.in_contact(sniper, foes), "the fixture sniper has the cluster on its line")
	var hot := {}
	var cold := 0
	for u: UnitInstance in state.living_units_of(side):
		if u.is_drone or not Budget.can_act(r, u, {}):
			continue
		if Budget.in_contact(u, foes):
			hot[u.id] = true
		else:
			cold += 1
	ck(cold >= 3, "the fixture also has idle units for the draw (%d)" % cold)
	var always := Budget.actor_subset(r, side, 1, rng).size()  # дрон: вне жребия
	for i in 30:
		var sub := Budget.actor_subset(r, side, always + hot.size(), rng)
		for id: int in hot:
			ck(sub.has(id), "a unit with a target is drawn before idle ones (try %d)" % i)
	_finish()

func _finish() -> void:
	if fails.is_empty():
		print("intent budget: spent drones detonate, best blast first, sealed crews skipped, "
				+ "shooters with a target drawn first")
		quit(0)
		return
	printerr("intent budget: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)
