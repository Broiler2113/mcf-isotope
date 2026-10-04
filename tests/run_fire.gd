extends SceneTree

## Что огонь оставляет после себя.
##
## Раньше пламя сносило только постройки из BURNS_AWAY — стены, стёкла, шлюз, — а мешки,
## окоп, куча земли и ёж стояли посреди пожара как ни в чём не бывало, и под ними
## оставались лужи крови и гильзы. Теперь огонь съедает КЛЕТКУ: всё, что на ней лежало и
## стояло, исчезает.
##
## Ровно два исключения, и оба — не «постройка»:
##   • ТЕЛА. Стена из пяти трупов в пепел не обращается.
##   • МАШИНА. Корпус огню не по зубам — он его и не касается.

var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

func _initialize() -> void:
	_fire_eats_the_cell()
	_a_flame_jet_sweeps_too()
	_space_never_burns()
	if fails.is_empty():
		print("fire: the cell is swept bare by spreading flame and by the jet alike — bodies and hulls aside")
		quit(0)
		return
	printerr("fire: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func _fire_eats_the_cell() -> void:
	var m := MapData.new(20, 9)
	for y in 9:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_FLAMMABLE, 0.0, false, "")
	var eaten := [Vector2i(4, 3), Vector2i(5, 3), Vector2i(6, 3), Vector2i(7, 3)]
	m.set_cell(eaten[0], MCF.FLOOR_FLAMMABLE, 0.0, false, MCF.FEATURE_SANDBAGS)
	m.set_cell(eaten[1], MCF.FLOOR_FLAMMABLE, 0.0, false, MCF.FEATURE_TRENCH)
	m.set_cell(eaten[2], MCF.FLOOR_FLAMMABLE, 0.0, false, MCF.FEATURE_DIRT_PILE)
	m.set_cell(eaten[3], MCF.FLOOR_FLAMMABLE, 0.0, false, MCF.FEATURE_HEDGEHOG)
	var bodies := Vector2i(8, 3)
	m.set_cell(bodies, MCF.FLOOR_FLAMMABLE, 0.0, false, MCF.FEATURE_CORPSE_WALL)
	m.set_spawn(Vector2i(1, 7), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(18, 8), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(14, 1), "tank", MCF.Owner.PLAYER_1, Vector2i(1, 0))
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false

	# Кровь и гильзы на клетке с мешками — им тоже гореть.
	var fx := FxDecals.new()
	fx.apply([{"fx": "blood", "at": eaten[0], "from": Vector2i(1, 3)}])
	fx.apply([{"fx": "casings", "at": eaten[0], "toward": Vector2i(9, 3), "count": 6}])
	for _i in 40:
		fx.advance(1.0)
	ck(_decals_at(fx, eaten[0]) > 0, "blood and brass settle on the sandbags first (%d)"
			% _decals_at(fx, eaten[0]))

	var tank_cell: Vector2i = st.all_vehicles()[0].footprint()[0]
	ck(st.grid.vehicle_at(tank_cell) != -1, "and a tank stands on the field")

	# Поджигаем соседнюю клетку и даём пламени разойтись по горючему полу.
	st.grid.cell(Vector2i(3, 3)).on_fire = true
	st.grid.cell(Vector2i(3, 3)).fire_owner = MCF.Owner.PLAYER_1
	var res := ActionResult.new()
	for _i in 10:
		r.advance_fire(MCF.Owner.PLAYER_1, res)

	for c: Vector2i in eaten:
		ck(st.grid.cell(c).feature_id == "",
				"fire eats what stood at %s (left '%s')" % [c, st.grid.cell(c).feature_id])
		ck(st.grid.cell(c).cover_height == 0.0, "and the cover it gave at %s" % c)
	ck(st.grid.cell(bodies).feature_id == MCF.FEATURE_CORPSE_WALL,
			"but a wall of bodies is still bodies (left '%s')" % st.grid.cell(bodies).feature_id)
	ck(st.grid.vehicle_at(tank_cell) != -1, "and the tank is untouched by any of it")

	fx.apply(res.fx)
	ck(_decals_at(fx, eaten[0]) == 0,
			"nothing is left on the burnt ground — no pools, no brass (%d)"
			% _decals_at(fx, eaten[0]))

func _decals_at(fx: FxDecals, c: Vector2i) -> int:
	var n := 0
	for list: Array in [fx.props, fx.gore, fx.prints]:
		for p: Dictionary in list:
			var pos: Vector2 = p["pos"]
			if Vector2i(floori(pos.x), floori(pos.y)) == c:
				n += 1
	return n

## Струя огнемёта съедает клетку ТАК ЖЕ, как расползающееся пламя.
##
## Это и был второй случай той же дыры: правило «огонь съедает клетку» лежало в
## расползании (advance_fire), а поджечь клетку можно двумя путями, и второй — струя
## (§3.8). Игрок видел ровно это: огнемёт заливает позицию огнём, а мешки и гильзы на ней
## стоят целыми. Теперь зачистка живёт в самом поджоге (_ignite), и путь к ней один.
func _a_flame_jet_sweeps_too() -> void:
	var m := MapData.new(20, 9)
	for y in 9:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	var at := Vector2i(8, 4)
	m.set_cell(at, MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_SANDBAGS)
	m.set_spawn(Vector2i(4, 4), "flamethrower", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(18, 8), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(9)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false
	while st.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var fx := FxDecals.new()
	fx.apply([{"fx": "casings", "at": at, "toward": Vector2i(12, 4), "count": 6}])
	for _i in 40:
		fx.advance(1.0)
	ck(_decals_at(fx, at) > 0, "brass is lying on the sandbags (%d)" % _decals_at(fx, at))
	var ft: UnitInstance = st.grid.cell(Vector2i(4, 4)).occupant
	var res := r.resolve(ShootIntent.new(ft.id, -1, -1, at))
	ck(res.ok, "the flame jet fires: %s" % res.reason)
	ck(st.grid.cell(at).on_fire, "the cell is alight")
	ck(st.grid.cell(at).feature_id == "",
			"the jet eats the sandbags, not just the ground (left '%s')" % st.grid.cell(at).feature_id)
	ck(st.grid.cell(at).cover_height == 0.0, "and the cover they gave")
	fx.apply(res.fx)
	ck(_decals_at(fx, at) == 0, "and the brass with them (%d left)" % _decals_at(fx, at))

## В вакууме гореть нечему (editor-rework): струя проходит над космосом, не поджигая его
## и не трогая того, кто там висит, а пол за пробоиной горит как обычно. Расползание в
## космос тоже не идёт.
func _space_never_burns() -> void:
	var m := MapData.new(20, 9)
	for y in 9:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_FLAMMABLE, 0.0, false, "")
	for x in [6, 7]:
		m.set_cell(Vector2i(x, 4), MCF.FLOOR_NORMAL, 0.0, true, "")
	m.set_spawn(Vector2i(4, 4), "flamethrower", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(7, 4), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(8, 4), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(18, 8), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(9)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false
	while st.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var floater: UnitInstance = st.grid.cell(Vector2i(7, 4)).occupant
	var beyond: UnitInstance = st.grid.cell(Vector2i(8, 4)).occupant
	var ft: UnitInstance = st.grid.cell(Vector2i(4, 4)).occupant
	var res := r.resolve(ShootIntent.new(ft.id, -1, -1, Vector2i(9, 4)))
	ck(res.ok, "the jet fires across the gap: %s" % res.reason)
	ck(not st.grid.cell(Vector2i(6, 4)).on_fire and not st.grid.cell(Vector2i(7, 4)).on_fire,
			"space cells under the jet stay unlit")
	ck(floater.is_alive(), "a soldier floating in the vacuum is not burned")
	ck(not beyond.is_alive() and st.grid.cell(Vector2i(8, 4)).on_fire,
			"the floor beyond the gap burns, and so does the soldier on it")
	ck(st.grid.cell(Vector2i(5, 4)).on_fire, "the floor before the gap burns")
	for _i in 6:
		r.advance_fire(MCF.Owner.PLAYER_1, ActionResult.new())
	ck(not st.grid.cell(Vector2i(6, 4)).on_fire and not st.grid.cell(Vector2i(7, 4)).on_fire,
			"spreading flame never enters space either")
