extends SceneTree
## Batch 0.9.3: service accents on station and bunker walls, the grill walkway with its solar
## panels, corridor widths (main 3, tech 1-2), grating only in tech tunnels, doors that fill
## the whole tile, and space that draws no tile at all.
var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

func _initialize() -> void:
	_corridors_and_grating()
	_accents()
	_grill_and_panels()
	_doors_fill_the_tile()
	_space_has_no_tile()
	if fails.is_empty():
		print("batch 0.9.3: accents, grill, corridors, doors and empty space all hold")
	else:
		print("batch 0.9.3: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

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
func _corridors_and_grating() -> void:
	var main_bad := 0
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
					# Пробег кончился: короткий (не длиннее 3) — это поперечник прохода.
					if kind == MapGen.K_HALL and run > 0 and run < 4 and run != 3:
						main_bad += 1
					elif kind == MapGen.K_MAINT and run > 0 and run < 4:
						tech_runs += 1
						if run > 2:
							tech_bad += 1
						elif run == 2:
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
	ck(main_bad == 0, "every main corridor is 3 cells wide (%d narrower ones)" % main_bad)
	ck(tech_bad == 0 and tech_runs > 0, "tech tunnels are 1 or 2 cells wide (%d of %d broke it)"
			% [tech_bad, tech_runs])
	ck(tech_wide > 0 and tech_wide * 3 < tech_runs,
			"2-cell tech tunnels are the exception, not the rule (%d of %d)" % [tech_wide, tech_runs])
	ck(grate_elsewhere == 0, "grating is laid in tech tunnels and nowhere else (%d cells elsewhere)"
			% grate_elsewhere)
	ck(grate_tech > 0 and grate_tech * 2 < tech_cells,
			"and not even in every tech tunnel (%d of %d cells)" % [grate_tech, tech_cells])

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
		for r: Rect2i in g._room_kind:
			if g._room_kind[r] != "armory":
				continue
			armories += 1
			for c in g._edge_cells(r):
				if m.get_accent(c.y * m.width + c.x) != MCF.Accent.SECURITY:
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
			"an armoury is red wherever it stands, department or not (%d walls broke it)" % armory_bad)
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

## Дверь занимает клетку целиком: у плитки нет ни одного полностью прозрачного столбца или
## ряда по краям — раньше по бокам оставались поля, и в проёме просвечивала стена.
func _doors_fill_the_tile() -> void:
	Sprites.reload_overrides()
	var thin: Array[String] = []
	for name: String in ["door", "door_station", "door_bunker", "door_town", "door_field",
			"door_asteroid", "door_open", "door_open_station", "door_open_bunker"]:
		var tex := Sprites.texture_of(name)
		if tex == null:
			thin.append(name + " (missing)")
			continue
		var img := tex.get_image()
		if img.is_compressed():
			img.decompress()
		var t := img.get_height()
		for v in img.get_width() / t:
			for edge in 4:
				var opaque := 0
				for k in t:
					var p := Vector2i(v * t + (0 if edge == 0 else (t - 1 if edge == 1 else k)),
							k if edge < 2 else (0 if edge == 2 else t - 1))
					if img.get_pixel(p.x, p.y).a > 0.0:
						opaque += 1
				if opaque < t:
					thin.append("%s[%d] edge %d: %d of %d" % [name, v, edge, opaque, t])
	ck(thin.is_empty(), "doors and airlocks fill the whole tile (%s)" % str(thin.slice(0, 4)))

## Космос не рисует плитки вовсе: за доской параллакс, и своя картинка ему не нужна.
func _space_has_no_tile() -> void:
	var m := MapData.new(6, 6)
	m.fill_all_space()
	m.set_cell(Vector2i(1, 1), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_look(2 * 6 + 2, MCF.Look.SOLAR)
	m.set_look(3 * 6 + 3, MCF.Look.GRILL)
	var g := Grid.new(6, 6)
	m.apply_to_grid(g)
	var t := TerrainTiles.new(g, "station")
	ck(t._floor_name(g.cell(Vector2i(0, 0)), Vector2i(0, 0)) == "",
			"plain space draws no tile at all")
	ck(t._floor_name(g.cell(Vector2i(2, 2)), Vector2i(2, 2)) == "floor_solar",
			"a solar panel still draws itself over the stars")
	ck(t._floor_overlay_name(g.cell(Vector2i(3, 3)), Vector2i(3, 3)) == "floor_grill",
			"the grill is an overlay, so the stars show through its bars")
	ck(t._floor_name(g.cell(Vector2i(1, 1)), Vector2i(1, 1)) == "floor",
			"solid floor is unaffected")
