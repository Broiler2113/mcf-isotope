extends SceneTree

## МОДУЛЬНАЯ БРОНЯ: машина — не один пул прочности, а несколько независимых узлов.
##
## Проверяется вся веха разом, потому что её части держатся друг за друга: порог
## попадания по узлу бессмыслен без каскада, каскад — без пропуска разбитых узлов, а
## «ноль на узле» — без той способности, которую он отнимает.
##
## Разбор попадания идёт через кубики, поэтому все прогоны с бросками используют
## ФИКСИРОВАННОЕ зерно и сравнивают ИНВАРИАНТЫ («урон куда-то лёг», «узел не ушёл ниже
## нуля»), а не конкретные числа: иначе тест ловил бы смену порядка бросков, а не
## смену правил.

const TS = preload("res://tests/TestSupport.gd")

var fails: PackedStringArray = []
var _pending: Intent = null

func _initialize() -> void:
	_pools_are_independent()
	_zero_takes_the_capability_away()
	_aimed_shot_and_cascade()
	_overkill_runs_into_the_hull()
	_fixed_target_sources()
	_crew_only_risked_by_hull_hits()
	_engineer_repairs()
	_capture_keeps_the_damage()
	_a_real_gunner_wears_a_tank_down()
	_the_side_you_shoot_from_decides()
	_the_barrel_hides_from_behind()
	_armored_materials()

	if fails.is_empty():
		print("modular tank: pools, thresholds, cascade, overkill, fixed targets, crew,"
				+ " repair, capture, hit sides, gun cover and armored materials all hold")
		quit(0)
		return
	printerr("modular tank: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _on_intent(i: Intent) -> void:
	_pending = i

## Поле с одним танком игрока 1 и одним игрока 2, оба с экипажем.
func _field(w: int = 26, h: int = 12) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(2, 4), "tank", MCF.Owner.PLAYER_1, Vector2i(1, 0))
	m.set_spawn(Vector2i(1, 4), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(1, 7), "engineer", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(1, 9), "anti_tank", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(18, 4), "tank", MCF.Owner.PLAYER_2, Vector2i(-1, 0))
	m.set_spawn(Vector2i(22, 9), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var state := m.build_state(12345)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var mine: Vehicle = null
	var theirs: Vehicle = null
	for v: Vehicle in state.all_vehicles():
		if v.owner == MCF.Owner.PLAYER_1:
			mine = v
		else:
			theirs = v
	return {"s": state, "r": r, "mine": mine, "theirs": theirs}

func _unit_at(state: GameState, coord: Vector2i) -> UnitInstance:
	var c := state.grid.cell(coord)
	return c.occupant if c != null else null

# --- 1. Четыре независимых пула ------------------------------------------------------
func _pools_are_independent() -> void:
	var f := _field()
	var tank: Vehicle = f["theirs"]
	ck(tank.component(MCF.COMP_HULL) == 8, "tank hull starts at 8")
	ck(tank.component(MCF.COMP_TOWER) == 6, "tank tower starts at 6")
	ck(tank.component(MCF.COMP_TRACKS_L) == 4, "the tank's left track starts at 4")
	ck(tank.component(MCF.COMP_TRACKS_R) == 4, "and the right one too")
	ck(not tank.has_component(MCF.COMP_TRACKS),
			"a tank has no single shared track pool any more")
	ck(tank.component(MCF.COMP_GUN) == 4, "tank main gun starts at 4")
	ck(tank.durability == tank.component(MCF.COMP_HULL),
			"durability and hull are the same number, not two")
	# Челнок — только корпус и ходовая, обе по 4.
	var m := MapData.new(10, 8)
	for y in 8:
		for x in 10:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(2, 2), "shuttle", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(8, 6), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(3)
	var sh: Vehicle = st.all_vehicles()[0]
	# У челнока фронта нет, а значит нет и бортов: ходовая у него осталась ОДНИМ узлом.
	ck(sh.component(MCF.COMP_HULL) == 4 and sh.component(MCF.COMP_TRACKS) == 4,
			"shuttle carries hull 4 and one shared track pool of 4")
	ck(not sh.has_component(MCF.COMP_TRACKS_L),
			"and no left/right split, having no front to measure sides from")
	ck(not sh.has_component(MCF.COMP_TOWER) and not sh.has_component(MCF.COMP_GUN),
			"and has neither tower nor main gun")

# --- 2. Ноль на узле отнимает способность --------------------------------------------
func _zero_takes_the_capability_away() -> void:
	var f := _field()
	var state: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["mine"]
	var crew := _unit_at(state, Vector2i(1, 4))
	r.resolve(VehicleBoardIntent.new(crew.id, tank.id))
	ck(tank.ap > 0, "the tank has a crew and can act")

	# ОДНА гусеница: ехать нельзя, разворачиваться можно.
	tank.components[MCF.COMP_TRACKS_L] = 0
	ck(not r.resolve(VehicleMoveIntent.new(tank.id, tank.facing, 1)).ok,
			"one broken track stops the tank driving")
	ck(r.vehicle_move_targets(tank).is_empty(),
			"and the movement highlight offers it nothing")
	ck(r.resolve(VehicleTurnIntent.new(tank.id, Vector2i(0, 1))).ok,
			"but it can still turn on the track it has left")
	# ОБЕ: стоит намертво.
	tank.ap = 3
	tank.components[MCF.COMP_TRACKS_R] = 0
	ck(not r.resolve(VehicleMoveIntent.new(tank.id, tank.facing, 1)).ok,
			"with both tracks gone it cannot drive")
	ck(not r.resolve(VehicleTurnIntent.new(tank.id, Vector2i(1, 0))).ok,
			"and cannot turn either")
	tank.components[MCF.COMP_TRACKS_L] = 4
	tank.components[MCF.COMP_TRACKS_R] = 4
	tank.ap = 3
	# Направление НОВОЕ: повторный разворот в ту же сторону резолвер отклоняет сам,
	# и тест мерил бы этот отказ, а не починку.
	ck(r.resolve(VehicleTurnIntent.new(tank.id, Vector2i(-1, 0))).ok,
			"repairing the tracks lets it turn again at once")

	# Орудие: не стреляет вовсе.
	tank.components[MCF.COMP_GUN] = 0
	var target: Vector2i = f["theirs"].footprint()[0]
	ck(not r.resolve(VehicleCannonIntent.new(tank.id, target)).ok,
			"a tank with a dead gun cannot fire")
	ck(r.cannon_target_cells(tank).is_empty(), "and nothing is highlighted for it")
	tank.components[MCF.COMP_GUN] = 4

# --- 3. Прицельный бросок и каскад ---------------------------------------------------
func _aimed_shot_and_cascade() -> void:
	var f := _field()
	var state: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["theirs"]
	var res := ActionResult.new()
	res.ok = true

	# По корпусу с прицелом промахнуться нельзя: 2+ с надбавкой становится 1+.
	for i in 12:
		var comp := r._resolve_hit_location(tank, MCF.COMP_HULL, res, "test")
		ck(comp == MCF.COMP_HULL, "an aimed hull shot never misses (got %s)" % comp)

	# Разбитый узел не выбирается и каскадом пропускается.
	tank.components[MCF.COMP_TRACKS_L] = 0
	var seen := {}
	for i in 40:
		var comp := r._resolve_hit_location(tank, MCF.COMP_TRACKS_L, res, "test")
		seen[comp] = true
	ck(not seen.has(MCF.COMP_TRACKS_L),
			"a knocked-out component is never the one that gets hit")
	ck(seen.size() > 0, "something else takes the hit instead")

	# Каскад никогда не отвечает «мимо всего»: пол гарантии.
	tank.components[MCF.COMP_TOWER] = 0
	tank.components[MCF.COMP_GUN] = 0
	tank.components[MCF.COMP_TRACKS_R] = 0
	for i in 20:
		var comp := r._resolve_hit_location(tank, MCF.COMP_GUN, res, "test")
		ck(comp == MCF.COMP_HULL,
				"with only the hull left, every hit lands on it (got %s)" % comp)

# --- 4. Излишек уходит в корпус ------------------------------------------------------
func _overkill_runs_into_the_hull() -> void:
	var f := _field()
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["theirs"]
	var res := ActionResult.new()
	res.ok = true
	tank.components[MCF.COMP_TRACKS_L] = 1
	var hull_before: int = tank.component(MCF.COMP_HULL)
	r._damage_component(tank, MCF.COMP_TRACKS_L, MCF.COMPONENT_DAMAGE_CANNON, "cannon", res)
	ck(tank.component(MCF.COMP_TRACKS_L) == 0, "the cannon finishes that track")
	ck(tank.component(MCF.COMP_HULL) == hull_before - 1,
			"and its second point carries into the hull (%d -> %d)"
			% [hull_before, tank.component(MCF.COMP_HULL)])
	# Ниже нуля узел не уходит.
	r._damage_component(tank, MCF.COMP_TRACKS_L, 5, "cannon", res)
	ck(tank.component(MCF.COMP_TRACKS_L) == 0, "a dead component never goes negative")

# --- 5. Источники с фиксированной целью ----------------------------------------------
func _fixed_target_sources() -> void:
	var f := _field()
	var state: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["mine"]
	var crew := _unit_at(state, Vector2i(1, 4))
	r.resolve(VehicleBoardIntent.new(crew.id, tank.id))

	# Противотанковая мина бьёт по ходовой.
	var ahead: Vector2i = tank.footprint()[0] + tank.facing * 3
	state.grid.cell(ahead).feature_id = MCF.FEATURE_AV_MINE
	var tracks_before := _tracks_total(tank)
	r.resolve(VehicleMoveIntent.new(tank.id, tank.facing, 4))
	ck(_tracks_total(tank) < tracks_before,
			"an anti-vehicle mine goes straight into the running gear (%d -> %d)"
			% [tracks_before, _tracks_total(tank)])

	# Противопехотная машине больше не вредит вовсе.
	var f2 := _field()
	var st2: GameState = f2["s"]
	var r2: GameActionResolver = f2["r"]
	var t2: Vehicle = f2["mine"]
	var crew2 := _unit_at(st2, Vector2i(1, 4))
	r2.resolve(VehicleBoardIntent.new(crew2.id, t2.id))
	var spot: Vector2i = t2.footprint()[0] + t2.facing * 3
	st2.grid.cell(spot).feature_id = MCF.FEATURE_MINE
	var armour_before := _armour(t2)
	r2.resolve(VehicleMoveIntent.new(t2.id, t2.facing, 4))
	ck(_armour(t2) == armour_before,
			"a personnel mine leaves a vehicle untouched (%d -> %d)"
			% [armour_before, _armour(t2)])

	# Шахтёр ковыряет корпус, и только корпус.
	var f3 := _field()
	var st3: GameState = f3["s"]
	var r3: GameActionResolver = f3["r"]
	var t3: Vehicle = f3["theirs"]
	var miner := st3.spawn_unit(load("res://src/data/units/miner.tres"),
			_free_beside(st3, t3), MCF.Owner.PLAYER_1)
	var hull_before: int = t3.component(MCF.COMP_HULL)
	var others_before: int = _armour(t3) - hull_before
	for i in 30:
		miner.remaining_ap = 1
		r3.resolve(VehicleMeleeIntent.new(miner.id, t3.id))
		if not t3.alive():
			break
	ck(t3.component(MCF.COMP_HULL) < hull_before,
			"the miner eventually gets through to the hull")
	ck(_armour(t3) - t3.component(MCF.COMP_HULL) == others_before,
			"and never touches tower, tracks or gun")

# --- 6. Экипаж рискует только от попаданий в корпус ----------------------------------
func _crew_only_risked_by_hull_hits() -> void:
	var f := _field()
	var state: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["mine"]
	var crew := _unit_at(state, Vector2i(1, 4))
	r.resolve(VehicleBoardIntent.new(crew.id, tank.id))
	var res := ActionResult.new()
	res.ok = true
	var before := tank.living_crew_count()
	ck(before > 0, "the tank has a crew to risk")
	# Бьём ТОЛЬКО по живым узлам: удар по уже выбитому по правилам уходит в корпус, и
	# тест мерил бы тогда совсем другое.
	for i in 15:
		for comp: String in [MCF.COMP_TRACKS_L, MCF.COMP_TRACKS_R, MCF.COMP_TOWER, MCF.COMP_GUN]:
			if tank.component_alive(comp):
				r._damage_component(tank, comp, 1, "test", res)
	ck(tank.living_crew_count() == before,
			"tower, tracks and gun hits never touch the crew (%d -> %d)"
			% [before, tank.living_crew_count()])
	# Смертельное попадание в корпус убивает экипаж без всякого броска.
	r._damage_component(tank, MCF.COMP_HULL, 99, "test", res)
	ck(not tank.alive(), "a hull taken to zero ends the tank")
	ck(tank.living_crew_count() == 0, "and kills the crew outright")

# --- 7. Ремонт -----------------------------------------------------------------------
func _engineer_repairs() -> void:
	var f := _field()
	var state: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["mine"]
	var eng := _unit_at(state, Vector2i(1, 7))
	ck(eng != null and eng.stats.special_ability_id == MCF.ABILITY_ENGINEER,
			"the fixture has an engineer")
	if eng == null:
		return
	# Инженера ставим вплотную к корпусу.
	state.grid.place(eng, _free_beside(state, tank))
	tank.components[MCF.COMP_TRACKS_L] = 0
	eng.remaining_ap = 3
	ck(r.repairable_components(eng, tank).has(MCF.COMP_TRACKS_L),
			"a knocked-out component is offered for repair")
	var fix := r.resolve(RepairVehicleIntent.new(eng.id, tank.id, MCF.COMP_TRACKS_L))
	ck(fix.ok, "the engineer repairs it (%s)" % fix.reason)
	ck(tank.component(MCF.COMP_TRACKS_L) == 1, "one point comes back")
	ck(tank.can_drive(), "and the tank can move again immediately")
	# Выше стартового значения не чинится.
	tank.components[MCF.COMP_TRACKS_L] = tank.component_max(MCF.COMP_TRACKS_L)
	eng.remaining_ap = 2
	ck(not r.resolve(RepairVehicleIntent.new(eng.id, tank.id, MCF.COMP_TRACKS_L)).ok,
			"a sound component cannot be repaired past its maximum")
	# Чужую машину чинить нельзя.
	var theirs: Vehicle = f["theirs"]
	state.grid.place(eng, _free_beside(state, theirs))
	theirs.components[MCF.COMP_TRACKS_L] = 1
	eng.remaining_ap = 2
	ck(not r.resolve(RepairVehicleIntent.new(eng.id, theirs.id, MCF.COMP_TRACKS_L)).ok,
			"an engineer will not service an enemy vehicle")

# --- 8. Захват сохраняет повреждения --------------------------------------------------
func _capture_keeps_the_damage() -> void:
	var f := _field()
	var state: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["theirs"]
	tank.components[MCF.COMP_TRACKS_L] = 1
	tank.components[MCF.COMP_TOWER] = 2
	tank.components[MCF.COMP_HULL] = 5
	var snapshot := tank.components.duplicate()
	var taker := _unit_at(state, Vector2i(1, 9))
	state.grid.place(taker, _free_beside(state, tank))
	taker.remaining_ap = 2
	var before_ap := taker.remaining_ap
	var res := r.resolve(VehicleBoardIntent.new(taker.id, tank.id))
	ck(res.ok, "an empty enemy tank can be boarded (%s)" % res.reason)
	ck(taker.remaining_ap == before_ap - 1, "which costs exactly 1 AP")
	ck(tank.owner == MCF.Owner.PLAYER_1, "and hands the tank to the captor")
	ck(tank.components == snapshot,
			"the captured tank keeps every component exactly as it was")

# --- 9. Настоящий бой: противотанкист разбирает танк по узлам -------------------------
##
## Сквозная проверка всей цепочки — намерение с названным узлом, бросок на попадание,
## разбор места попадания, снятие очков — на живом резолвере, а не на отдельных
## функциях. Кубики настоящие, поэтому утверждения ИНВАРИАНТНЫЕ: столько-то выстрелов
## обязаны где-то оставить след, названный узел обязан страдать чаще прочих, и ни один
## узел не имеет права уйти ниже нуля.
func _a_real_gunner_wears_a_tank_down() -> void:
	var f := _field()
	var state: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["theirs"]
	var gunner := _unit_at(state, Vector2i(1, 9))
	if gunner == null or gunner.stats.special_ability_id != MCF.ABILITY_ANTI_TANK:
		ck(false, "the fixture has an anti-tank gunner")
		return
	# Ставим стрелка на одну линию с корпусом, но не вплотную: в упор он подорвётся сам.
	var hull_cell: Vector2i = tank.footprint()[0]
	state.grid.place(gunner, Vector2i(hull_cell.x - 7, hull_cell.y))
	var start := _armour(tank)
	var tracks_start: int = tank.component(MCF.COMP_TRACKS_L)
	var shots := 0
	var landed := 0
	for i in 40:
		if not tank.alive():
			break
		gunner.remaining_ap = 1
		gunner.action_state = ActionState.new()
		var before := _armour(tank)
		var res := r.resolve(ShootIntent.new(gunner.id, -1, -1, hull_cell, MCF.COMP_TRACKS_L))
		if not res.ok:
			ck(false, "the gunner can fire at the hull (%s)" % res.reason)
			return
		shots += 1
		if _armour(tank) < before:
			landed += 1
	ck(shots > 0, "the gunner actually fired")
	ck(landed > 0, "some of those %d shots got through and cost the tank armour" % shots)
	ck(_armour(tank) < start, "the tank is worn down overall (%d -> %d)" % [start, _armour(tank)])
	ck(tank.component(MCF.COMP_TRACKS_L) < tracks_start,
			"and the tracks he kept aiming at took some of it (%d -> %d)"
			% [tracks_start, tank.component(MCF.COMP_TRACKS_L)])
	for comp: String in tank.components:
		ck(int(tank.components[comp]) >= 0, "%s never goes below zero" % comp)

## Сумма очков всех узлов.
func _armour(veh: Vehicle) -> int:
	var n := 0
	for comp: String in veh.components:
		n += int(veh.components[comp])
	return n

## Свободная клетка вплотную к корпусу — куда поставить приспособление.
func _free_beside(state: GameState, veh: Vehicle) -> Vector2i:
	for fc: Vector2i in veh.footprint():
		for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var c: Vector2i = fc + d
			if not state.grid.in_bounds(c):
				continue
			var cell := state.grid.cell(c)
			if cell.occupant == null and cell.vehicle_id == -1 and not cell.is_wall():
				return c
	return Vector2i(-1, -1)

# --- 10. С какого борта бьёшь — ту гусеницу и достанешь (веха 14.1) -------------------
##
## Гусеница бортовая: с левого борта видно левую, с правого — правую, а в лоб и в корму
## открыты обе. Правило действует и на ПРИЦЕЛ, и на КАСКАД: снаряд, пришедший слева,
## не может задеть правую гусеницу даже случайно — её закрывает корпус.
func _the_side_you_shoot_from_decides() -> void:
	var f := _field()
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["theirs"]
	tank.facing = Vector2i(1, 0)   # смотрит вправо (на восток)
	var c := tank.center()
	# Поле рисуется с осью Y ВНИЗ, поэтому у машины, смотрящей вправо, «левый борт» —
	# это сверху (север), а «правый» — снизу (юг).
	# Смещения НЕБОЛЬШИЕ намеренно: клетка за краем карты не считается бортом вовсе
	# (стрелка там быть не может), и проба из неё вернула бы «доступно всё».
	var from_front := c + Vector2i(4, 0)
	var from_back := c + Vector2i(-4, 0)
	var from_left := c + Vector2i(0, -3)
	var from_right := c + Vector2i(0, 3)
	ck(tank.side_facing(from_front) == "front", "a shooter ahead of it is on the front")
	ck(tank.side_facing(from_back) == "back", "one behind is on the back")
	ck(tank.side_facing(from_left) == "left", "one above is on the left flank")
	ck(tank.side_facing(from_right) == "right", "one below is on the right flank")
	# Ровно по диагонали засчитывается БОРТ — более строгий ответ.
	ck(tank.side_facing(c + Vector2i(4, 4)) == "right",
			"an exact diagonal counts as the flank, not the front")

	var front_set := r._aimable_components(tank, from_front)
	ck(front_set.has(MCF.COMP_TRACKS_L) and front_set.has(MCF.COMP_TRACKS_R),
			"from the front both tracks can be aimed at")
	var back_set := r._aimable_components(tank, from_back)
	ck(back_set.has(MCF.COMP_TRACKS_L) and back_set.has(MCF.COMP_TRACKS_R),
			"from behind, both as well")
	var left_set := r._aimable_components(tank, from_left)
	ck(left_set.has(MCF.COMP_TRACKS_L) and not left_set.has(MCF.COMP_TRACKS_R),
			"from the left flank, only the left track")
	var right_set := r._aimable_components(tank, from_right)
	ck(right_set.has(MCF.COMP_TRACKS_R) and not right_set.has(MCF.COMP_TRACKS_L),
			"from the right flank, only the right one")

	# И каскад тоже: сотня разборов слева не имеет права ни разу задеть правую.
	var res := ActionResult.new()
	res.ok = true
	var touched_far := 0
	for i in 60:
		var comp := r._resolve_hit_location(tank, MCF.COMP_TRACKS_L, res, "test", from_left)
		if comp == MCF.COMP_TRACKS_R:
			touched_far += 1
	ck(touched_far == 0,
			"the cascade never reaches the track on the far side (%d times it did)"
			% touched_far)

	# Подрыв дрона борта не знает вовсе — он рвётся СВЕРХУ (§4).
	var overhead := r._aimable_components(tank, GameActionResolver.NOWHERE)
	ck(overhead.has(MCF.COMP_TRACKS_L) and overhead.has(MCF.COMP_TRACKS_R),
			"a drone detonating overhead may pick either track")

# --- 11. Ствол не виден с той стороны, куда он не смотрит (веха 14.1) -----------------
func _the_barrel_hides_from_behind() -> void:
	var f := _field()
	var r: GameActionResolver = f["r"]
	var tank: Vehicle = f["theirs"]
	tank.facing = Vector2i(1, 0)
	tank.tower_locked_dir = Vector2i.ZERO   # ещё не стреляла
	var c := tank.center()
	ck(tank.gun_world_dir() == Vector2i(1, 0),
			"an unfired tank's gun is taken to point along the hull")
	ck(not r._aimable_components(tank, c + Vector2i(-4, 0)).has(MCF.COMP_GUN),
			"so a shooter behind it cannot aim at the gun")
	ck(r._aimable_components(tank, c + Vector2i(4, 0)).has(MCF.COMP_GUN),
			"one in front of the barrel can")
	ck(r._aimable_components(tank, c + Vector2i(0, 3)).has(MCF.COMP_GUN),
			"and so can one off to the side, who sees it in profile")

	# Башня повернулась выстрелом — вместе с ней переезжает и слепая зона.
	tank.remember_shot_dir(Vector2i(0, 1))
	ck(tank.gun_world_dir() == Vector2i(0, 1), "after firing, the gun points where it fired")
	ck(not r._aimable_components(tank, c + Vector2i(0, -3)).has(MCF.COMP_GUN),
			"and now it is the shooter on the other side who cannot see it")
	ck(r._aimable_components(tank, c + Vector2i(-4, 0)).has(MCF.COMP_GUN),
			"while the one behind the hull can, the barrel having turned across him")

# --- 12. Броневые стена и стекло (веха 14.1) ------------------------------------------
func _armored_materials() -> void:
	var m := MapData.new(20, 10)
	for y in 10:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_cell(Vector2i(9, 4), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_ARMOR_WALL)
	m.set_cell(Vector2i(9, 6), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_ARMOR_GLASS)
	m.set_spawn(Vector2i(2, 4), "anti_tank", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(2, 6), "miner", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(17, 4), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var state := m.build_state(808)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var wall := Vector2i(9, 4)
	var glass := Vector2i(9, 6)

	# Плита — стена: перекрывает и ход, и линию огня.
	ck(state.grid.cell(wall).is_wall(), "an armored wall is a wall")
	ck(r.los_blocked(Vector2i(2, 4), Vector2i(17, 4)),
			"and it blocks the line of fire like one")
	# Бронестекло — стекло: сквозь него видно и стреляют.
	ck(not r.los_blocked(Vector2i(2, 6), Vector2i(17, 6), true, false, true),
			"armored glass is still shot through, like ordinary glass")

	# Осколки рядом её не берут — проверяем НАСТОЯЩИМ выстрелом, а не вызовом одной
	# внутренней функции: плиту защищает то, что её нет в списке разрушаемого, и
	# обойти этот список можно только сыграв взрыв целиком.
	var res := ActionResult.new()
	res.ok = true
	var gunner: UnitInstance = null
	for u: UnitInstance in state.living_units_of(MCF.Owner.PLAYER_1):
		if u.stats.special_ability_id == MCF.ABILITY_ANTI_TANK:
			gunner = u
	if gunner == null:
		fails.append("no anti-tank gunner for the armored-wall fixture")
		return
	var beside := wall + Vector2i(-1, 0)
	for i in 8:
		gunner.remaining_ap = 1
		gunner.action_state = ActionState.new()
		r.resolve(ShootIntent.new(gunner.id, -1, -1, beside))
	ck(state.grid.cell(wall).feature_id == MCF.FEATURE_ARMOR_WALL,
			"eight blasts going off right beside it leave it standing")
	# Кирка — тоже.
	var miner: UnitInstance = null
	for u: UnitInstance in state.living_units_of(MCF.Owner.PLAYER_1):
		if u.stats.special_ability_id == MCF.ABILITY_MINER:
			miner = u
	if miner != null:
		state.grid.place(miner, wall + Vector2i(-1, 0))
		ck(not r.can_break_cell(miner, wall), "and a miner cannot demolish it")
	# Гусеница — тоже: для машины это край поля.
	var entry := VehicleRules.cell_entry(state, wall, -1)
	ck(not bool(entry["ok"]), "and a vehicle cannot ram through it")
	# А прямой разрыв — берёт, с одного раза.
	r._blast_armor_wall(wall, res)
	ck(state.grid.cell(wall).feature_id == "",
			"a direct explosion on it blows it apart")

	# Бронестекло держит пулю на 4+ — проверяем само правило, а не везение кубика.
	ck(MCF.glass_hold_need(MCF.FEATURE_ARMOR_GLASS) == 4,
			"armored glass holds on 4+")
	ck(MCF.glass_hold_need(MCF.FEATURE_GLASS) == 0,
			"ordinary glass has no hold roll of its own")
	ck(MCF.is_glass(MCF.FEATURE_ARMOR_GLASS) and MCF.is_glass(MCF.FEATURE_GLASS),
			"both count as glass everywhere glass is special")

## Сколько очков осталось во всей ходовой — обе гусеницы вместе.
func _tracks_total(veh: Vehicle) -> int:
	var n := 0
	for comp: String in veh.track_components():
		n += veh.component(comp)
	return n
