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
	if fails.is_empty():
		print("fire: the cell is swept bare — bodies and hulls aside")
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
