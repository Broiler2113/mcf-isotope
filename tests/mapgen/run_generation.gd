extends "res://tests/SuiteBase.gd"
## Map generation: symmetric zones, departments and towns, corridors, borders, accents,
## grill walkways and solar arrays, tunnels and roads, items on tables, environments,
## civilians, deployment bands, stations, parks and room lights.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_symmetric_zones()
	_items_generator()

	_departments()
	_towns()

	_corridors_and_grating()
	_border()
	_accents()
	_grill_and_panels()
	if fails.is_empty():
		print("batch 0.9.3: accents, grill, corridors, doors, the border, empty space"
				+ " and corpse-pile clearing all hold")
	else:
		print("batch 0.9.3: %d failure(s)" % fails.size())

	_no_orphan_tunnels()
	_asteroid_is_built_of_station_plating()
	if fails.is_empty():
		print("batch 0.9.4: counts, events, raiders, tunnels, asteroid plating and texture"
				+ " folders all hold")
	else:
		print("batch 0.9.4: %d failure(s)" % fails.size())

	_tunnels()

	_roads()

	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_solar()

	_civilians_are_thinned_evenly()
	_bands_follow_chosen_zone()
	_generated_maps_know_their_environment()

	for size in [0, 1, 2]:
		for seed in range(1, 9):
			var g := MapGen.build({"style": MapGen.Style.TOWN, "size": size, "seed": seed, "furniture": 2})
			for house: Rect2i in g._rooms:
				if str(g._room_kind.get(house, "")) not in ["house", "apartments"]: continue
				var has_room := false
				var has_toilet := false
				for room: Rect2i in g._bathrooms:
					if not house.encloses(room): continue
					has_room = true
					for c in g._rect_cells(room):
						if Furniture.base_of(g.m.get_feature(c)) == "toilet": has_toilet = true
				ck(has_room and has_toilet, "town size %d seed %d house %s has restroom and toilet (room=%s toilet=%s)" % [size, seed, house, has_room, has_toilet])
			for i in g.w * g.h:
				if not MCF.is_glass(g.m.feature_id[i]): continue
				ck(g.m.get_look(i) < MCF.WALL_LOOK_BASE and g.m.floor_type[i] != MCF.FLOOR_GRASS, "windows have interior floor, seed %d cell %d" % [seed, i])
			_verify_room_lights(g, seed)
			_verify_parks(g, seed)
			var station := MapGen.build({"style": MapGen.Style.STATION, "size": size, "seed": seed, "furniture": 2})
			_verify_station(station, seed)
	for options in [{"size": 0, "seed": 21, "obstacles": false}, {"size": 2, "seed": 22, "symmetric": true, "zones": 4}, {"size": 3, "seed": 13},
			{"size": MapGen.SIZE_CUSTOM, "width": 16, "height": 16, "units": 1, "seed": 24}, {"size": 4, "seed": 25}, {"size": 5, "seed": 26}]:
		options["style"] = MapGen.Style.STATION
		_verify_station(MapGen.build(options), options.seed)
	ck(not LightManager.source_on({"id": "streetlight"}, "day"), "streetlights off by day")
	ck(LightManager.source_on({"id": "streetlight"}, "night"), "streetlights on at night")

## A symmetric random map puts the two deployment zones at opposite ends of the playable
## area (a station's hull floats in space, so its ends are the hull's, not the map's).
func _symmetric_zones() -> void:
	for style in [MapGen.Style.FIELD, MapGen.Style.TOWN, MapGen.Style.STATION]:
		for seed in [3, 11]:
			var m := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": 48, "height": 32,
					"density": 1, "seed": seed, "zones": 2, "symmetric": true, "civilians": 0, "civilian_count": 0})
			var lo := m.width
			var hi := 0
			for i in m.width * m.height:
				if m.is_space[i] == 0:
					lo = mini(lo, i % m.width)
					hi = maxi(hi, i % m.width)
			var mid: Array[float] = []
			for owner in 2:
				var cells: Array = m.zone_cells(owner)
				var sx := 0.0
				for c: Vector2i in cells:
					sx += c.x
				mid.append(sx / maxi(1, cells.size()))
			var span := float(hi - lo + 1)
			var ends := minf(mid[0], mid[1]) - lo < span * 0.3 and hi - maxf(mid[0], mid[1]) < span * 0.3
			ck(ends, "%s seed %d: zones sit at opposite ends (x %.0f and %.0f of %d..%d)" % [
					MapGen.STYLE_NAMES[style], seed, mid[0], mid[1], lo, hi])

## Generated maps lay their tables (office desks, dining tables…) and mirror the items on
## symmetric maps.
func _items_generator() -> void:
	var total := 0
	for style in [MapGen.Style.TOWN, MapGen.Style.STATION]:
		var m := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": 60, "height": 44,
				"density": 2, "seed": 21, "zones": 2, "civilians": 0, "civilian_count": 0})
		total += m.items.size()
		var on_tables := m.items.all(func(it: Array) -> bool:
			var c := SmallItems.cell_of(it)
			return SmallItems.is_kind(str(it[0])) and m.in_bounds(c) and not m.get_space(c) and m.get_cover(c) < MCF.WALL_HEIGHT)
		ck(on_tables, "%s: generated items lie on accessible tables, counters or floors (%d)" % [MapGen.STYLE_NAMES[style], m.items.size()])
		var again := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": 60, "height": 44,
				"density": 2, "seed": 21, "zones": 2, "civilians": 0, "civilian_count": 0})
		ck(again.items == m.items, "%s: the same seed lays the same items" % MapGen.STYLE_NAMES[style])
	ck(total > 0, "generated towns and stations have items on their tables (%d)" % total)
	var sym := MapGen.generate({"style": MapGen.Style.TOWN, "size": MapGen.SIZE_CUSTOM, "width": 60, "height": 44,
			"density": 2, "seed": 5, "zones": 2, "symmetric": true, "civilians": 0, "civilian_count": 0})
	var left := sym.items.filter(func(it: Array) -> bool: return float(it[1]) < sym.width / 2.0).size()
	var right := sym.items.filter(func(it: Array) -> bool: return float(it[1]) > sym.width / 2.0).size()
	ck(left == right, "a symmetric map mirrors its items (%d | %d)" % [left, right])

## Станция и бункер по отделам (замысел игрока): внутренние комнаты медотсека и охраны не
## выходят в главный коридор; производство — дальше всех от жилого; переработка отходов
## есть всегда; причал — шлюзом прямо в космос; тайник — только из каюты капитана.
func _departments() -> void:
	var inner := {"ward": true, "surgery": true, "briefing": true, "armory": true, "cell": true}
	var hall_breaks := 0
	var far_breaks := 0
	var no_recycling := 0
	var docks := 0
	var docks_open := 0
	var hidden_bad := 0
	var toilets := 0
	var looks := 0
	var maps := 0
	for style: int in [MapGen.Style.STATION, MapGen.Style.BUNKER]:
		for seed: int in [11, 23, 57, 101]:
			for size: int in [1, 2, 3]:
				var g := MapGen.build({"style": style, "size": size, "seed": seed, "civilians": 0})
				var m := g.m
				maps += 1
				if not g._room_kind.values().has("recycling"):
					no_recycling += 1
				for r: Rect2i in g._room_kind:
					var kind: String = g._room_kind[r]
					for c in g._edge_cells(r):
						if m.get_feature(c) != MCF.FEATURE_AIRLOCK:
							continue
						var out := c + g._outward(r, c)
						if inner.has(kind) and g._kind(out.x, out.y) == MapGen.K_HALL:
							hall_breaks += 1
						if kind == "hidden_storage":
							var into := ""
							for q: Rect2i in g._room_kind:
								if q != r and q.has_point(out) and g._room_kind[q] == "captain":
									into = "captain"
							if into != "captain":
								hidden_bad += 1
					if kind == "dock" and style == MapGen.Style.STATION:
						docks += 1
						for c in g._edge_cells(r):
							var o2 := c + g._outward(r, c)
							if m.get_feature(c) == MCF.FEATURE_AIRLOCK and g._in(o2) and (m.get_space(o2) or (not m.get_space(o2) and m.get_feature(o2 + g._outward(r, c)) == MCF.FEATURE_AIRLOCK and m.get_space(o2 + g._outward(r, c) * 2))):
								docks_open += 1
								break
				var service := Vector2(-1, -1)
				var prod := Vector2(-1, -1)
				for e: Array in g._dept_sectors:
					if e[1] == "service":
						service = Vector2((e[0] as Rect2i).get_center())
					elif e[1] == "production":
						prod = Vector2((e[0] as Rect2i).get_center())
				if service.x >= 0 and prod.x >= 0:
					for e: Array in g._dept_sectors:
						if e[1] != "production" and e[1] != "service" \
								and Vector2((e[0] as Rect2i).get_center()).distance_to(service) > prod.distance_to(service) + 0.01:
							far_breaks += 1
							break
				for i in m.width * m.height:
					if m.feature_id[i] == "toilet":
						toilets += 1
					if m.get_look(i) != 0:
						looks += 1
	ck(hall_breaks == 0, "no ward, surgery, briefing room, armory or cell opens onto a main corridor (%d)" % hall_breaks)
	ck(far_breaks == 0, "production is the department farthest from the service department (%d maps broke it)" % far_breaks)
	ck(no_recycling == 0, "every station and bunker has a waste recycling room (%d of %d lack it)" % [no_recycling, maps])
	ck(docks > 0 and docks_open == docks, "station docks have a chamber and a second door to space (%d of %d)" % [docks_open, docks])
	ck(hidden_bad == 0, "the hidden storage opens only into the captain's quarters (%d)" % hidden_bad)
	ck(toilets > 0 and looks > 0, "stations and bunkers get toilets (%d) and room floors (%d cells)" % [toilets, looks])

## Город по районам: жилые дома с санузлами (унитаз в маленькой комнате), промзона, центр.
func _towns() -> void:
	var kinds := {}
	var toilets := 0
	var looks := 0
	for seed: int in [5, 9, 13]:
		var g := MapGen.build({"style": MapGen.Style.TOWN, "size": 3, "seed": seed, "civilians": 0})
		for r: Rect2i in g._room_kind:
			kinds[g._room_kind[r]] = true
		for i in g.m.width * g.m.height:
			if g.m.feature_id[i] == "toilet":
				toilets += 1
			if g.m.get_look(i) != 0:
				looks += 1
	ck(kinds.has("house") and (kinds.has("warehouse") or kinds.has("factory") or kinds.has("garage"))
			and (kinds.has("shop") or kinds.has("office") or kinds.has("restaurant")),
			"a Huge town has homes, an industrial zone and a commercial centre (%s)" % str(kinds.keys()))
	ck(toilets > 0, "town bathrooms get toilets (%d)" % toilets)
	ck(looks > 0, "town rooms get wood, tile and carpet floors (%d cells)" % looks)
	var g2 := MapGen.build({"style": MapGen.Style.STATION, "size": 2, "seed": 3, "civilians": 0})
	var back := MapData.from_dict(g2.m.to_dict())
	ck(back.floor_look == g2.m.floor_look, "floor looks survive save and load")

## Карты для проверок: станция и бункер, несколько зёрен и размеров.
func _maps() -> Array:
	var out: Array = []
	for style: int in [MapGen.Style.STATION, MapGen.Style.BUNKER]:
		for seed: int in [11, 23, 57, 101, 7]:
			for size: int in [2, 3]:
				out.append(MapGen.build({"style": style, "size": size, "seed": seed, "civilians": 0}))
	return out

## Ширина прохода: пробеги одного вида поперёк его направления. Главный коридор — ровно 3
## клетки, технический туннель — 1, изредка 2. Меряем в обе стороны: пробег ВДОЛЬ коридора
## длинный, поперёк — это и есть ширина, поэтому берём наименьший пробег каждого вида.
##
## Короткий пробег — ещё не поперечник: так же читается и ТУПИКОВЫЙ ОТРОСТОК в пару клеток
## (0.9.4: срез бесхозных проходов оставляет такие у обвода станции). Поперечник отличается
## тем, что проход ПРОДОЛЖАЕТСЯ вбок: у средней клетки пробега соседи с обеих сторон того же
## вида. У отростка с одной стороны стена — его и не считаем.
func _corridors_and_grating() -> void:
	var main_bad := 0
	var main_runs := 0
	var main_wide := 0
	var tech_bad := 0
	var tech_wide := 0
	var tech_runs := 0
	var grate_tech := 0
	var tech_cells := 0
	var grate_elsewhere := 0
	for g: MapGen in _maps():
		var m: MapData = g.m
		for axis in 2:
			var outer: int = m.height if axis == 0 else m.width
			var inner: int = m.width if axis == 0 else m.height
			for a in outer:
				var run := 0
				var kind := -1
				for b in inner + 1:
					var c := Vector2i(b, a) if axis == 0 else Vector2i(a, b)
					var k: int = g._kind(c.x, c.y) if b < inner else -1
					if k == kind and (k == MapGen.K_HALL or k == MapGen.K_MAINT):
						run += 1
						continue
					# Пробег кончился: короткий (не длиннее 3) и сквозной — это поперечник.
					var mid_ok := run > 0 and run < 4 and _crosses(g, axis, a, b - run + run / 2, kind)
					if kind == MapGen.K_HALL and mid_ok:
						main_runs += 1
						if run < 2:
							main_bad += 1
						elif run == 3:
							main_wide += 1
					elif kind == MapGen.K_MAINT and mid_ok:
						tech_runs += 1
						if run > 1:
							tech_bad += 1
						if run == 2:
							tech_wide += 1
					kind = k
					run = 1 if (k == MapGen.K_HALL or k == MapGen.K_MAINT) else 0
		for i in m.width * m.height:
			var c2 := Vector2i(i % m.width, i / m.width)
			var tech: bool = g._kind(c2.x, c2.y) == MapGen.K_MAINT
			if tech:
				tech_cells += 1
			if m.get_look(i) != MCF.Look.GRATE:
				continue
			if tech:
				grate_tech += 1
			else:
				grate_elsewhere += 1
	ck(main_bad == 0 and main_runs > 0,
			"no main corridor is narrower than 2 cells (%d of %d)" % [main_bad, main_runs])
	# Считаем поперечники, а не коридоры: главный ход тянется через всю карту, поэтому
	# трёхклеточных сечений у него много. Важно, что есть и те и другие.
	ck(main_wide > 0 and main_runs - main_wide > 0,
			"a 3-wide main drag and 2-wide corridors besides it (%d of %d sections)"
			% [main_wide, main_runs])
	ck(tech_bad == 0 and tech_runs > 0, "tech tunnels are one cell wide (%d of %d broke it)"
			% [tech_bad, tech_runs])
	ck(tech_wide == 0,
			"2-cell tech tunnels are no longer generated (%d of %d)" % [tech_wide, tech_runs])
	ck(grate_elsewhere == 0, "grating is laid in tech tunnels and nowhere else (%d cells elsewhere)"
			% grate_elsewhere)
	ck(grate_tech > 0 and grate_tech * 2 < tech_cells,
			"and not even in every tech tunnel (%d of %d cells)" % [grate_tech, tech_cells])

## Проход и правда идёт вбок от этой клетки (а не упирается в стену): проверка «это
## поперечник, а не тупик».
func _crosses(g: MapGen, axis: int, a: int, b: int, kind: int) -> bool:
	var c := Vector2i(b, a) if axis == 0 else Vector2i(a, b)
	var d := Vector2i(0, 1) if axis == 0 else Vector2i(1, 0)
	return g._kind(c.x + d.x, c.y + d.y) == kind and g._kind(c.x - d.x, c.y - d.y) == kind

## Акценты: каждая служба встречается, цвет лежит ТОЛЬКО на стенах и шлюзах, переживает
## сохранение, и у комнаты со своей службой он её, а не отдела.
func _accents() -> void:
	var seen := {}
	var off_wall := 0
	var armory_bad := 0
	var armories := 0
	for g: MapGen in _maps():
		var m: MapData = g.m
		for i in m.width * m.height:
			var a := m.get_accent(i)
			if a == MCF.Accent.NONE:
				continue
			seen[a] = int(seen.get(a, 0)) + 1
			var fid: String = m.feature_id[i]
			if fid != MCF.FEATURE_WALL and fid != MCF.FEATURE_AIRLOCK and fid != MCF.FEATURE_GLASS:
				off_wall += 1
		# Какие службы вправе претендовать на клетку: все комнаты, чья кайма её задевает.
		# Общая стена двух цветных комнат — одна, и цвет у неё может быть любой из двух.
		var claims := {}
		for r: Rect2i in g._room_kind:
			var a: int = MapGen.KIND_ACCENT.get(g._room_kind[r], MCF.Accent.NONE)
			if a == MCF.Accent.NONE:
				continue
			for c in g._edge_cells(r):
				var key := c.y * m.width + c.x
				if not claims.has(key):
					claims[key] = {}
				claims[key][a] = true
		for r: Rect2i in g._room_kind:
			if g._room_kind[r] != "armory":
				continue
			armories += 1
			var own_red := 0
			for c in g._edge_cells(r):
				# Кайма прямоугольника комнаты — не обязательно стена: у комнаты, вплотную
				# примыкающей к коридору отдела, в неё попадает и пол коридора. Цвет живёт
				# на стенах, их и спрашиваем.
				var fid: String = m.get_feature(c)
				if fid != MCF.FEATURE_WALL and fid != MCF.FEATURE_AIRLOCK and fid != MCF.FEATURE_GLASS:
					continue
				var got := m.get_accent(c.y * m.width + c.x)
				if got == MCF.Accent.SECURITY:
					own_red += 1
					continue
				if not (claims.get(c.y * m.width + c.x, {}) as Dictionary).has(got):
					armory_bad += 1   # цвет, на который эту стену не заявляла ни одна комната
			if own_red == 0:
				armory_bad += 1
	var want: Array[int] = [MCF.Accent.COMMAND, MCF.Accent.CONTROL, MCF.Accent.SECURITY,
			MCF.Accent.MEDICAL, MCF.Accent.SCIENCE, MCF.Accent.ENGINEERING, MCF.Accent.CARGO]
	var missing: Array[String] = []
	for a: int in want:
		if not seen.has(a):
			missing.append(MCF.ACCENT_NAMES[a])
	ck(missing.is_empty(), "every service gets its colour somewhere (missing: %s)" % str(missing))
	ck(off_wall == 0, "the accent sits on walls, windows and airlocks only (%d loose cells)" % off_wall)
	ck(armories > 0 and armory_bad == 0,
			"an armoury is red wherever it stands; a wall it shares with another service may take"
			+ " that one's colour, nothing else (%d broke it)" % armory_bad)
	var g2 := MapGen.build({"style": MapGen.Style.STATION, "size": 2, "seed": 3, "civilians": 0})
	var back := MapData.from_dict(g2.m.to_dict())
	ck(back.wall_accent == g2.m.wall_accent, "accents survive save and load")

## Мостки: решётка лежит на космосе, держится за станцию (цепочка от клетки у обшивки) и
## панели стоят рядом с ней.
func _grill_and_panels() -> void:
	var maps := 0
	var with_grill := 0
	var floating := 0
	var lone_panels := 0
	for g: MapGen in _maps():
		var m: MapData = g.m
		if m.env != "station":
			continue
		maps += 1
		var grill: Array[Vector2i] = []
		var solar: Array[Vector2i] = []
		for i in m.width * m.height:
			var c := Vector2i(i % m.width, i / m.width)
			if m.get_look(i) == MCF.Look.GRILL:
				grill.append(c)
			elif m.get_look(i) == MCF.Look.SOLAR:
				solar.append(c)
		if grill.is_empty():
			continue
		with_grill += 1
		for c in grill:
			if not m.get_space(c):
				floating += 1   # решётка — настил над пустотой, не поверх пола станции
		# Каждая решётка должна дотягиваться до станции по другим решёткам.
		var open: Array[Vector2i] = []
		var reached := {}
		for c in grill:
			for d: Vector2i in MapGen.N4:
				var q := c + d
				if m.in_bounds(q) and not m.get_space(q):
					open.append(c)
					reached[c] = true
					break
		while not open.is_empty():
			var c: Vector2i = open.pop_back()
			for d: Vector2i in MapGen.N4:
				var q: Vector2i = c + d
				if not reached.has(q) and grill.has(q):
					reached[q] = true
					open.append(q)
		floating += grill.size() - reached.size()
		for c in solar:
			var near := false
			for d: Vector2i in MapGen.N4:
				if grill.has(c + d) or solar.has(c + d):
					near = true
			if not near:
				lone_panels += 1
	ck(with_grill > 0, "stations grow grill walkways outside the hull (%d of %d maps)"
			% [with_grill, maps])
	ck(floating == 0, "every grill cell is open space and holds on to the station (%d loose)" % floating)
	ck(lone_panels == 0, "no solar panel hangs on its own, away from the walkway (%d)" % lone_panels)

## Кайма вокруг карты (0.9.3): BORDER клеток своего вида в каждую сторону, за ними
## BORDER_RIM клеток границы мира — туда не войти и там ничего не сломать.
func _border() -> void:
	var cases := [
		[MapGen.Style.BUNKER, false, "soil"],
		[MapGen.Style.STATION, true, "space"],
		[MapGen.Style.ASTEROID, true, "space"],
		[MapGen.Style.TOWN, false, "grass"],
		[MapGen.Style.FIELD, false, "grass"],
	]
	var size_bad := 0
	var rim_bad := 0
	var ring_bad: Array[String] = []
	var zone_outside := 0
	var spawn_outside := 0
	var walk_rim := 0
	var breakable := 0
	for case: Array in cases:
		for seed: int in [5, 41, 96]:
			var dim: Vector2i = MapGen.SIZES[1]
			var g := MapGen.build({"style": case[0], "size": 1, "seed": seed, "civilians": 2,
					"space": case[1], "zones": 2})
			var m: MapData = g.m
			if m.width != dim.x + MapGen.BORDER_ALL * 2 or m.height != dim.y + MapGen.BORDER_ALL * 2:
				size_bad += 1
			var core := Rect2i(MapGen.BORDER_ALL, MapGen.BORDER_ALL, dim.x, dim.y)
			var reach := core.grow(MapGen.BORDER)
			var want: String = case[2]
			for i in m.width * m.height:
				var c := Vector2i(i % m.width, i / m.width)
				if not reach.has_point(c):
					# Граница мира: её объект и ничего больше.
					if m.feature_id[i] != MCF.FEATURE_BOUNDARY:
						rim_bad += 1
					continue
				if core.has_point(c):
					continue
				# Кольцо, куда можно выйти: у каждого стиля свой вид.
				var ok := false
				match want:
					"soil":
						ok = m.feature_id[i] == MCF.FEATURE_SOIL
					"space":
						ok = m.is_space[i] != 0 or (core.grow(2).has_point(c) and m.feature_id[i] in [MCF.FEATURE_WALL, MCF.FEATURE_AIRLOCK, ""])
					_:
						ok = m.feature_id[i] == "" and m.is_space[i] == 0
				if not ok and ring_bad.size() < 4:
					ring_bad.append("%s at %s: feature=%s space=%s" % [want, str(c),
							m.feature_id[i], str(m.is_space[i] != 0)])
				if m.zone_owner[i] >= 0:
					zone_outside += 1
			for sp: Dictionary in m.spawns:
				if not core.has_point(sp["coord"] as Vector2i):
					spawn_outside += 1
			# По-настоящему: собрать сетку и спросить правила движения и слома.
			var grid := Grid.new(m.width, m.height)
			m.apply_to_grid(grid)
			for x in m.width:
				for y: int in [0, m.height - 1]:
					if not grid.blocks_walk(Vector2i(x, y)):
						walk_rim += 1
			var probe := Vector2i(0, m.height / 2)
			if GameActionResolver.BREAKABLE.has(grid.cell(probe).feature_id):
				breakable += 1
	ck(size_bad == 0, "every style gets a %d-cell border around the map it asked for (%d wrong)"
			% [MapGen.BORDER_ALL, size_bad])
	ck(rim_bad == 0, "past the %d walkable cells the world's edge takes over (%d cells broke it)"
			% [MapGen.BORDER, rim_bad])
	ck(ring_bad.is_empty(), "the ring you can reach is soil, grass or space by style (%s)"
			% str(ring_bad))
	ck(zone_outside == 0, "no deployment zone reaches outside the map (%d cells)" % zone_outside)
	ck(spawn_outside == 0, "nobody starts outside the map, civilians included (%d)" % spawn_outside)
	ck(walk_rim == 0, "the world's edge is impassable for everyone (%d open cells)" % walk_rim)
	ck(breakable == 0, "and no miner can demolish it (%d)" % breakable)

# --- items 2 и 3: ни хвостов в космос, ни решета из пустых отсеков -------------------------
## Проход, у которого ВСЕ четыре соседа — пустота или обшивка, никуда не ведёт: это та самая
## нитка, уходившая из станции в космос. Пустых отсеков — считаем дырки: прямоугольные
## каверны внутри обвода станции больше не десятками.
func _no_orphan_tunnels() -> void:
	var dead_ends := 0
	var halls := 0
	for seed_value: int in [11, 23, 57, 101, 7]:
		for size: int in [3, 4]:
			var g := MapGen.build({"style": MapGen.Style.STATION, "size": size,
					"seed": seed_value, "civilians": 0})
			for y in g.h:
				for x in g.w:
					var k: int = g._k[y * g.w + x]
					if k != MapGen.K_HALL and k != MapGen.K_MAINT:
						continue
					halls += 1
					var open := 0
					for d: Vector2i in MapGen.N4:
						var nk: int = g._kind(x + d.x, y + d.y)
						if nk != MapGen.K_VOID and nk != MapGen.K_WALL:
							open += 1
					if open == 0:
						dead_ends += 1
	ck(halls > 0 and dead_ends == 0,
			"no corridor cell leads nowhere (%d of %d)" % [dead_ends, halls])

# --- item 11: постройки астероида — из обшивки станции ------------------------------------
func _asteroid_is_built_of_station_plating() -> void:
	var station := 0
	var other := 0
	for seed_value: int in [11, 23, 57]:
		var m := MapGen.generate({"style": MapGen.Style.ASTEROID, "size": 2, "seed": seed_value,
				"civilians": 0})
		for i in m.width * m.height:
			if m.feature_id[i] != MCF.FEATURE_WALL:
				continue
			var look := m.get_look(i)
			if MCF.wall_look_tile(look) == "wall_station":
				station += 1
			elif MCF.wall_look_tile(look) != "":
				other += 1
	ck(station > 0 and other == 0,
			"asteroid buildings are plated like a station (%d station, %d other)" % [station, other])

func _tunnels() -> void:
	for seed in [7, 29, 1001]:
		var gen := MapGen.build({"style": 0, "size": 4, "seed": seed, "players": 2, "units": 30, "civilians": 0})
		var bad := 0
		for y in gen.h - 1:
			for x in gen.w - 1:
				if gen._kind(x, y) == MapGen.K_MAINT:
					for d: Vector2i in MapGen.N4:
						if gen._kind(x + d.x, y + d.y) in [MapGen.K_HALL, MapGen.K_DHALL]: bad += 1
					if gen._kind(x + 1, y) == MapGen.K_MAINT and gen._kind(x, y + 1) == MapGen.K_MAINT and gen._kind(x + 1, y + 1) == MapGen.K_MAINT: bad += 1
		ck(bad == 0, "service tunnels are single-width and closed by airlocks, seed %d" % seed)

func _roads() -> void:
	for flammable in [true, false]:
		var g := MapGen.build({"style": MapGen.Style.TOWN, "size": 0, "seed": 97, "flammable": flammable, "units": 16, "civilians": 0})
		var core: Rect2i = g._core
		var count := 0
		for x in range(core.position.x, core.end.x):
			if g._street[core.position.y * g.w + x] == 0: continue
			count += 1
			for y in range(core.position.y - MapGen.BORDER, core.position.y):
				ck(g.m.get_floor(Vector2i(x, y)) == MCF.FLOOR_NORMAL and g.m.get_look(y * g.w + x) == 0, "north road continues across all ten border cells")
		ck(count > 0, "town fixture has roads")

var MainScript: GDScript

func _solar() -> void:
	for size in [0, 2]:
		for seed_value in [1, 4, 8]:
			var options := {"style": MapGen.Style.STATION, "size": size, "seed": seed_value}
			var g := MapGen.build(options)
			var repeat := MapGen.build(options)
			var panels := 0
			for i in g.w * g.h:
				if g.m.get_look(i) == MCF.Look.SOLAR: panels += 1
			ck(g._space_doors.size() >= 3 and panels >= 6, "station size %d seed %d has several solar arrays (%d panels)" % [size, seed_value, panels])
			ck(g.m.to_dict() == repeat.m.to_dict(), "solar generation is repeatable")

## 11: на карте 9 мирных, ползунок — 3: остаются ровно 3, по одному из каждой трети.
func _civilians_are_thinned_evenly() -> void:
	var m := MapData.new(20, 6)
	for y in 6:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(0, 0), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(19, 0), "light_infantry", MCF.Owner.PLAYER_2)
	for i in 9:
		m.set_spawn(Vector2i(1 + i * 2, 4), "civilian", MCF.Owner.NEUTRAL)
	var keep := GameConfig.civilian_count
	GameConfig.civilian_count = 3
	var st := m.build_state(3)
	var xs: Array = []
	for u in st.all_units():
		if MCF.is_neutral(u.owner):
			xs.append(u.coord.x)
	xs.sort()
	ck(xs.size() == 3, "the civilians slider caps a prepared map (%d left)" % xs.size())
	ck(xs.size() == 3 and xs[0] < 7 and xs[1] >= 7 and xs[1] < 13 and xs[2] >= 13,
			"the kept civilians are spread over the map: %s" % str(xs))
	GameConfig.civilian_count = 0
	var none := 0
	for u in m.build_state(3).all_units():
		if MCF.is_neutral(u.owner):
			none += 1
	ck(none == 0, "zero on the slider means no civilians (%d)" % none)
	GameConfig.civilian_count = keep

## 22: полосы на карте без зон — половинки на двоих, на троих три подряд без зазоров.
func _bands_follow_chosen_zone() -> void:
	ck(MapData.band_of(0, 2, 30) == Vector2i(0, 15) and MapData.band_of(1, 2, 30) == Vector2i(15, 30),
			"two sides split the board in halves")
	var b0 := MapData.band_of(0, 3, 30)
	var b1 := MapData.band_of(1, 3, 30)
	var b2 := MapData.band_of(2, 3, 30)
	ck(b0.x == 0 and b0.y == b1.x and b1.y == b2.x and b2.y == 30, "three bands tile the board: %s %s %s" % [b0, b1, b2])
	ck(MapData.band_of(9, 3, 30) == b2, "an out-of-range zone falls into the last band")

## 24: стиль → окружение, а окружение → своя плитка стены.
func _generated_maps_know_their_environment() -> void:
	for st in MapGen.STYLE_ENV.size():
		var m := MapGen.generate({"style": st, "seed": 7, "size": 0})
		ck(m.env == MapGen.STYLE_ENV[st], "style %d is tagged %s (got %s)" % [st, MapGen.STYLE_ENV[st], m.env])
		ck(MapData.from_dict(m.to_dict()).env == m.env, "the environment survives saving the map")
	ck(TerrainTiles.env_name("wall", "station") == "wall_station", "a station wall uses the station tiles")
	ck(TerrainTiles.env_name("glass", "station") == "glass", "a tile without an environment variant stays generic")
	var v := TerrainTiles.variant_of(Vector2i(3, 9), 6)
	ck(v >= 0 and v < 6 and v == TerrainTiles.variant_of(Vector2i(3, 9), 6), "a cell's variant is stable")

func _verify_station(g: MapGen, seed: int) -> void:
	var production := false
	var engineering := false
	for sector in g._dept_sectors:
		if sector[1] == "production": production = true
		if sector[1] == "engineering": engineering = true
	ck(engineering, "station %s seed %d has engineering" % [g._core.size, seed])
	var workstations := 0
	var solar := 0
	var docking := 0
	for i in g.w * g.h:
		if g.m.get_look(i) == MCF.Look.SOLAR: solar += 1
		if g.m.feature_id[i] == "machine_workstation": workstations += 1
		if g.m.feature_id[i] != MCF.FEATURE_AIRLOCK: continue
		if g.m.get_door(i) >= 16: docking += 1
		var c := Vector2i(i % g.w, i / g.w)
		for direction: Vector2i in MapGen.N4:
			if not g.m.get_space(c + direction): continue
			var inside := c - direction
			var inner := c - direction * 2
			ck(g.m.get_door(i) >= 16 and not g.m.get_space(inside) and g.m.get_cover(inside) < MCF.WALL_HEIGHT and g.m.get_feature(inner) == MCF.FEATURE_AIRLOCK and g.m.get_door(inner.y * g.w + inner.x) >= 16,
					"station seed %d exterior door %s has one-tile chamber and secondary docking door" % [seed, c])
	if production:
		ck(workstations > 0, "station seed %d with production has machine workstations" % seed)
	ck(solar > 0, "station %s seed %d has solar panels" % [g._core.size, seed])
	ck(docking >= 2, "station %s seed %d has paired docking doors" % [g._core.size, seed])

func _verify_parks(g: MapGen, seed: int) -> void:
	var full_parks := 0
	for park in g._parks:
		var found := {}
		for c in g._rect_cells(park):
			found[Furniture.base_of(g.m.get_feature(c))] = true
			if g.m.get_look(c.y * g.w + c.x) == MCF.Look.DIRT: found["path"] = true
		if found.has("bench") and found.has("park_tree") and found.has("vending_machine") and found.has("path"): full_parks += 1
	ck(full_parks > 0, "town %s seed %d has a park with paths, trees, benches and vending" % [g._core, seed])

func _verify_room_lights(g: MapGen, seed: int) -> void:
	var lights := MapLighting.new()
	lights.g = g
	lights.map = g.m
	lights.coverage.resize(g.w * g.h)
	lights._index_geometry()
	for i in g.w * g.h:
		var c := Vector2i(i % g.w, i / g.w)
		var fid := g.m.feature_id[i]
		if Furniture.emits_light(fid): lights._illuminate(c, fid)
		for lamp: Array in g.m.fixtures.get(i, []): lights._illuminate(c, lamp[0], int(lamp[2]))
	for room in g._bathrooms:
		var brightest := 0.0
		for c in g._rect_cells(room): brightest = maxf(brightest, lights.coverage[c.y * g.w + c.x])
		ck(brightest >= MapLighting.ROOM_TARGET, "town seed %d restroom %s has light on its own side of the wall" % [seed, room])
