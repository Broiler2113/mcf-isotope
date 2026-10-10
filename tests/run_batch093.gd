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
	_border()
	_accents()
	_grill_and_panels()
	_doors_fill_the_tile()
	_space_has_no_tile()
	_corpse_pile_gets_cleared()
	if fails.is_empty():
		print("batch 0.9.3: accents, grill, corridors, doors, the border, empty space"
				+ " and corpse-pile clearing all hold")
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
						ok = m.is_space[i] != 0
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

## Завал из тел на единственном проходе (0.9.3). Носильщик с полными руками упирался в
## кучу и стоял так до конца боя: взять ещё тело он не может, а класть соглашался только
## когда рядом нет врага. Теперь он освобождает руки и разбирает завал по телу.
func _corpse_pile_gets_cleared() -> void:
	var w := 34
	var h := 5
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			# Коридор в одну клетку по середине, всё остальное — стены.
			var wall: bool = y != 2
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 2.0 if wall else 0.0, false,
					MCF.FEATURE_WALL if wall else "")
	m.set_spawn(Vector2i(1, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(32, 2), "light_infantry", 1)
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	# Завал ровно на дороге, и руки у бойца заняты.
	var pile := Vector2i(4, 2)
	st.grid.cell(pile).corpse_count = 3
	var me: UnitInstance = null
	for u: UnitInstance in st.all_units():
		if u.owner == 0:
			me = u
	me.carried_corpses = 1
	ck(st.grid.blocks_walk(pile), "a pile of bodies blocks the corridor to begin with")
	var ai := AIController.new(0, AIController.Difficulty.NORMAL)
	var pending: Array = []
	ai.intent_ready.connect(func(i: Intent) -> void: pending.append(i))
	var drops := 0
	var picks := 0
	var actions := 0
	while st.turns.round_number <= 10 and actions < 400:
		if st.active_player() != 0:
			r.resolve(EndTurnIntent.new())
			continue
		pending.clear()
		ai.begin_turn(st)
		if pending.is_empty():
			r.resolve(EndTurnIntent.new())
			continue
		var intent: Intent = pending[0]
		if intent is DropCorpseIntent:
			drops += 1
		elif intent is PickUpCorpseIntent:
			picks += 1
		actions += 1
		var res := r.resolve(intent)
		if not res.ok:
			ai.notify_intent_denied(st)
	var left: int = r.corpses_at(pile)
	_civilian_clears_too()
	ck(drops > 0, "the carrier puts its own body down to free its hands (%d drops)" % drops)
	ck(picks > 0, "and takes bodies out of the pile (%d pick-ups)" % picks)
	ck(left < 3, "the pile in the corridor actually shrinks (3 bodies -> %d)" % left)
	ck(left == 0 or not st.grid.blocks_walk(pile) or me.coord.x > 1,
			"and the carrier is no longer stuck where it started (at %s)" % str(me.coord))

## То же самое за НЕЙТРАЛА (0.9.3). Житель тащит тела как щит и по своей воле их не
## кладёт — поэтому перед завалом он застревал ровно так же. Единственное исключение —
## завал на дороге: ради него руки освобождаются. Спрашиваем сам набор ходов жителя:
## ход нейтрала проводит резолвер целым кругом, и гонять ради одной проверки целую
## партию тут не за чем.
func _civilian_clears_too() -> void:
	var w := 34
	var h := 5
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			var wall: bool = y != 2
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 2.0 if wall else 0.0, false,
					MCF.FEATURE_WALL if wall else "")
	m.set_spawn(Vector2i(3, 2), "civilian", MCF.Owner.NEUTRAL)
	m.set_spawn(Vector2i(32, 2), "light_infantry", 0)
	GameConfig.civilians_enabled = true
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false
	st.grid.cell(Vector2i(4, 2)).corpse_count = 2
	var civ: UnitInstance = null
	for u: UnitInstance in st.all_units():
		if MCF.is_neutral(u.owner):
			civ = u
	if civ == null:
		ck(false, "the civilian scenario actually places a civilian")
		return
	civ.civilian_active = true   # «вскрытый» житель: иначе он просто стоит (§3.10)
	var ai := AIController.new(civ.owner, AIController.Difficulty.NORMAL)
	ai._r = r   # обычно его ставит begin_turn; здесь спрашиваем генераторы напрямую
	civ.carried_corpses = 1
	var full := ai._neutral_candidates(st, r, civ)
	var frees_hands := false
	for cand: Dictionary in full:
		if cand["intent"] is DropCorpseIntent:
			frees_hands = true
	civ.carried_corpses = 0
	var empty_handed := ai._neutral_candidates(st, r, civ)
	var digs := false
	for cand: Dictionary in empty_handed:
		if cand["intent"] is PickUpCorpseIntent:
			digs = true
	ck(frees_hands, "a civilian with full hands puts its shield down to dig through a pile")
	ck(digs, "and with free hands it takes a body out of the pile blocking its way")
