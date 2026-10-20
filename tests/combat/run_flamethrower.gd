extends "res://tests/SuiteBase.gd"
## The flamethrower: six-cell splash in corners and against walls, the jet shown cell by cell,
## immunity and armor, fire exits from vehicles, fire leaving decals alone.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_flame_jet()

	_flame_splash_is_six()
	_flame_into_corner_is_six()
	_flame_one_sided_splash_is_six()

	flamer_armor()
	fire_keeps_decals()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_flame_immunity()

	fire_exits()

func _events_of(res: ActionResult, kind: String) -> Array:
	return res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == kind)

## The flame is shown as a jet running out of the nozzle cell by cell: the resolver hands the
## screen the jet's cells in order, without spending a board fx number on it.
func _flame_jet() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(5, 10), "flamethrower", 0)
	m.set_spawn(Vector2i(8, 10), "light_infantry", 1)
	var st := m.build_state(2)
	var r := GameActionResolver.new(st)
	var shooter: UnitInstance = st.grid.cell(Vector2i(5, 10)).occupant
	var want := r.flame_cells(shooter.coord, Vector2i(1, 0))
	var seq := st.fx_seq
	var res := r._resolve_flame(shooter, Vector2i(9, 10))
	var jets := _events_of(res, "flame_jet")
	ck(jets.size() == 1 and jets[0]["cells"] == want and jets[0]["from"] == Vector2i(5, 10),
			"the flame hands the screen its jet, nozzle first (%d cells)" % want.size())
	ck(not jets.is_empty() and not jets[0].has("seq"), "the jet takes no board fx number")
	ck(st.fx_seq - seq == res.fx.filter(func(f: Dictionary) -> bool: return f.has("seq")).size(), "fx numbers count only seeded effects")
	ck(res.deaths.size() == 1, "the target in the jet still burns")
	var fx := FxDecals.new()
	fx.apply(res.fx)
	ck(fx.flying.is_empty() and fx.props.is_empty(), "the jet leaves no particles of its own")

func _field(spawns: Array, walls: Array = [], civ := false) -> Dictionary:
	var m := MapData.new(30, 14)
	for y in 14:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for w: Vector2i in walls:
		m.set_cell(w, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = civ
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var guard := 0  # сторона может быть выбита первым же слотом жителей — не зацикливаемся
	while st.active_player() != MCF.Owner.PLAYER_1 and guard < 8:
		r.resolve(EndTurnIntent.new())
		guard += 1
	return {"s": st, "r": r}

func _u(st: GameState, c: Vector2i) -> UnitInstance:
	return st.grid.cell(c).occupant

func _flame_splash_is_six() -> void:
	# a straight wall on column 8; the jet goes NE from (5,8) and meets it at (8,5)
	var walls: Array = []
	for y in 14:
		walls.append(Vector2i(8, y))
	var f := _field([[Vector2i(5, 8), "flamethrower", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ft := _u(st, Vector2i(5, 8))
	var cells: Array = r.flame_cells(ft.coord, Vector2i(1, -1))
	ck(cells.size() == MCF.FLAME_JET_LENGTH, "diagonal jet into a straight wall still burns %d cells (got %d: %s)" % [MCF.FLAME_JET_LENGTH, cells.size(), str(cells)])
	var res := r.resolve(ShootIntent.new(ft.id, -1, -1, Vector2i(6, 7)))
	ck(res.ok, "flame: " + res.reason)
	var burning := 0
	for c: Vector2i in cells:
		if st.grid.cell(c).on_fire:
			burning += 1
	ck(burning == cells.size(), "every listed cell is on fire (%d/%d)" % [burning, cells.size()])
	for c: Vector2i in cells:
		ck(not st.grid.cell(c).is_wall(), "fire never lands on a wall cell %s" % str(c))

## Струя в УГОЛ. Огнемётчик в (5,5), стена идёт по колонке 6 и по строке 4: клетка
## (6,4) — внутренний угол, и обе перпендикулярные стороны от стрелка тоже заперты.
## Старый код здесь отдавал почти ничего: разлёт налево упирался в стену (l = 0), а
## добор был написан под условием l > 0 и не срабатывал никогда.
func _flame_into_corner_is_six() -> void:
	var walls: Array = []
	for y in 14:
		walls.append(Vector2i(6, y))
	for x in 30:
		walls.append(Vector2i(x, 4))
	var f := _field([[Vector2i(5, 5), "flamethrower", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ft := _u(st, Vector2i(5, 5))
	var cells: Array = r.flame_cells(ft.coord, Vector2i(1, -1))
	ck(cells.size() == MCF.FLAME_JET_LENGTH,
			"jet into a corner still burns %d cells (got %d: %s)"
			% [MCF.FLAME_JET_LENGTH, cells.size(), str(cells)])
	for c: Vector2i in cells:
		ck(not st.grid.cell(c).is_wall(), "corner splash never lands on a wall %s" % str(c))
		ck(c != ft.coord, "corner splash never burns the flamethrower's own cell")

## Разлёт, у которого сторона «налево» заперта СРАЗУ (l = 0), а «направо» обрывается
## через клетку. Прежний код добирал остаток только налево и только под условием
## l > 0 — то есть ровно здесь не добирал ничего и терял четыре клетки из шести.
func _flame_one_sided_splash_is_six() -> void:
	var walls: Array = []
	for y in 14:
		walls.append(Vector2i(6, y))
	walls.append(Vector2i(5, 6))   # «налево» от струи (1,0) — вниз: заперто сразу
	walls.append(Vector2i(5, 3))   # «направо» — вверх: одна свободная клетка (5,4)
	var f := _field([[Vector2i(5, 5), "flamethrower", MCF.Owner.PLAYER_1],
			[Vector2i(25, 10), "light_infantry", MCF.Owner.PLAYER_2]], walls)
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ft := _u(st, Vector2i(5, 5))
	var cells: Array = r.flame_cells(ft.coord, Vector2i(1, 0))
	ck(cells.size() == MCF.FLAME_JET_LENGTH,
			"one-sided splash still burns %d cells (got %d: %s)"
			% [MCF.FLAME_JET_LENGTH, cells.size(), str(cells)])
	var uniq := {}
	for c: Vector2i in cells:
		ck(not uniq.has(c), "splash never lists the same cell twice %s" % str(c))
		uniq[c] = true

func flamer_armor() -> void:
	ck((load("res://src/data/units/flamethrower.tres") as UnitStats).armor_threshold == 4, "flamethrowers have 4+ armor")

func fire_keeps_decals() -> void:
	var fx := FxDecals.new()
	fx._settle(fx.props, {"kind": "casing", "pos": Vector2(3.5, 3.5), "rot": 0.0, "scale": 1.0})
	fx._settle(fx.gore, {"kind": "blood_pool", "pos": Vector2(3.4, 3.6), "rot": 0.0, "scale": 1.0})
	fx.audio_suppressed = true
	fx.apply([{"fx": "burn", "cells": [Vector2i(3, 3)]}])
	ck(fx.props.size() == 1 and fx.gore.size() == 1, "fire no longer deletes the decals on its cells")

func _flame_immunity() -> void:
	var m := MapData.blank_arena(18, 10)
	m.set_spawn(Vector2i(2, 5), "flamethrower", 0)
	m.set_spawn(Vector2i(4, 5), "flamethrower", 1)
	m.set_spawn(Vector2i(6, 5), "light_infantry", 1)
	m.set_cell(Vector2i(5, 5), MCF.FLOOR_NORMAL, Furniture.height_of("cabinet"), false, "cabinet")
	var st := m.build_state(9)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r := GameActionResolver.new(st)
	var target := st.grid.cell(Vector2i(4, 5)).occupant
	var victim := st.grid.cell(Vector2i(6, 5)).occupant
	var result := r.resolve(ShootIntent.new(st.grid.cell(Vector2i(2, 5)).occupant.id, target.id))
	ck(result.ok and target.is_alive() and not victim.is_alive(), "an enemy flamethrower survives the jet; ordinary infantry behind it burns")
	ck(not result.deaths.has(target.id) and result.deaths.has(victim.id), "the death list agrees with fire immunity")
	ck(st.grid.cell(Vector2i(5, 5)).feature_id == "" and st.grid.cell(Vector2i(5, 5)).on_fire, "flame consumes furniture on its path")

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
