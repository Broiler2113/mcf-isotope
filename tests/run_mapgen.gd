extends SceneTree

## Случайные карты (MapGen, строка «Random map» в лобби) держат обещания лобби. На пачке
## зёрен всех стилей и размеров, с 2–4 сторонами, с большими отрядами и с каждой снятой
## галочкой:
##
##   1. то же зерно и те же настройки — та же карта до байта (иначе «назови карту
##      числом» не работает);
##   2. по зоне на слот, все одного размера, только чистый пол, не ближе ZONE_GAP друг к
##      другу — и каждая вмещает отряд (MapGen.zone_need). Не влезли на выбранном
##      размере — карта обязана была вырасти. Только на предельном поле (MAX_DIM)
##      зонам разрешено недотянуть и сблизиться, но не касаться;
##   3. в любую клетку любой зоны можно дойти пешком из первой зоны — по НАСТОЯЩЕЙ доске
##      (MapData → Grid → GridCell.walkable_terrain), а не по предикату самого генератора;
##   4. галочки держат слово: без космоса нет ни вакуума, ни шлюзов; без горючки — ни
##      горючего пола, ни травы, ни дерева; без препятствий — ни мешков, ни ежей, ни
##      окопов; без мирных — ни одного нейтрала; с мирными они стоят на чистом полу вне
##      зон; объекты карты — только известные, с высотой из таблицы;
##   5. мирные начинают партию СПЯЩИМИ: зоны забиты бойцами до отказа, и после первого
##      действия настоящий резолвер не разбудил ни одного жителя;
##   6. на карте каждого стиля ИИ против ИИ доигрывает несколько раундов, не зависая;
##   7. отрезанного пола нет: КАЖДАЯ проходимая клетка (кроме вакуума за обшивкой)
##      достижима пешком из первой зоны, и ни один шлюз не открывается в стену;
##   8. «Symmetrical»: карта совпадает со своим отражением клетка в клетку (зеркало слева
##      направо, четверти при 4 и 8 сторонах), зона переходит в зону, мирные — в мирных;
##   9. бункер — та же станция под землёй: ни клетки вакуума даже с галочкой космоса,
##      край карты — сплошная скала, а без космоса бункер и станция на одном зерне —
##      одна и та же карта до байта. Станции и бункеры — с коридорами и десятками комнат;
##  10. размеры до 250×250 готовыми пунктами и без потолка своим размером; самая большая
##      готовая карта собирается в разумное время;
##  11. двери — шлюзы, с космосом и без; каждый мирный ЗАПЕРТ: при закрытых шлюзах от него
##      не дойти ни до одной клетки зон; число мирных растёт с уровнем (None…Crowd) и не
##      выходит за его потолок.

const ROUNDS := 3
const MAX_ACTIONS := 4000
const SQUAD := ["light_infantry", "heavy_infantry", "machinegunner", "sniper", "engineer",
		"flamethrower", "miner", "anti_tank"]

var fails: PackedStringArray = []
var maps := 0
var _pending: Intent = null

## Готовые размеры до «Huge» — полным перебором; «Giant» и «Colossal» — по разу на стиль:
## они проверяют то же, но каждая стоит секунды.
const FULL_SIZES := 4
## Самая большая карта (250×250) обязана собираться не дольше этого: лобби строит её
## заново на каждое изменение настроек. С запасом на медленную машину.
const COLOSSAL_MS := 4000

func _initialize() -> void:
	ck(MapGen.SIZE_CUSTOM == MapGen.SIZES.size(), "'Custom' follows the last preset size")
	_field_digs_trench_lines()
	ck(MapGen.SIZES[MapGen.SIZES.size() - 1] == MapGen.MAX_DIM, "the largest preset is the 250×250 cap")
	for style in MapGen.STYLE_NAMES.size():
		for size in FULL_SIZES:
			for k in 3:
				_check({"style": style, "size": size, "density": k, "seed": 1000 * k + 17 * style + size,
						"zones": 2 + (k + size) % 3})
		for key: String in ["space", "flammable", "obstacles", "civilians"]:
			_check({"style": style, "seed": 4242 + style, key: false})
		# Большие отряды на маленьком поле: зоны обязаны их вместить — поле растёт.
		_check({"style": style, "size": 0, "seed": 31 + style, "zones": 3, "units": 40})
		_check({"style": style, "size": 1, "seed": 57 + style, "zones": 6, "units": 12})
		# Зеркало: пары, пары с зоной на оси, четверти.
		for n in [2, 3, 4, 5, 6, 8]:
			_check({"style": style, "size": 2, "seed": 700 + 13 * style + n, "zones": n, "symmetric": true})
		_check({"style": style, "size": 4, "seed": 11 + style, "zones": 3})
		var t0 := Time.get_ticks_msec()
		var colossal := MapGen.generate({"style": style, "size": 5, "seed": 13 + style})
		var ms := Time.get_ticks_msec() - t0
		# Заказанный размер — ИГРОВОЙ карты; поле вокруг неё шире на кайму (0.9.3).
		var edge := MapGen.BORDER_ALL * 2
		ck(colossal.width == 250 + edge and colossal.height == 250 + edge,
				"Colossal is 250×250 of map plus the %d-cell border (%dx%d)"
				% [MapGen.BORDER_ALL, colossal.width, colossal.height])
		ck(ms < COLOSSAL_MS, "%s: a 250×250 map builds in %d ms (budget %d)" % [
				MapGen.STYLE_NAMES[style], ms, COLOSSAL_MS])
		_check({"style": style, "size": 5, "seed": 13 + style})
		_play(style)
	# Свой размер: в пределах 16…250, и поле по-прежнему растёт, если отряды не влезают.
	_check({"style": MapGen.Style.TOWN, "size": MapGen.SIZE_CUSTOM, "width": 250, "height": 120, "seed": 5})
	_check({"style": MapGen.Style.FIELD, "size": MapGen.SIZE_CUSTOM, "width": 16, "height": 16,
			"seed": 6, "zones": 3})
	var wide := MapGen.generate({"size": MapGen.SIZE_CUSTOM, "width": 400, "height": 1, "zones": 2,
			"civilians": 0})
	# Астероид: по одному зерну жителей может не быть (см. выше), но по набору — обязаны.
	var rock_civ := 0
	for seed: int in [2069, 2070, 2071, 7, 11, 23]:
		# Мирных по умолчанию больше нет (0.9.4) — уровень задаётся прямо здесь: проверяется,
		# что астероид их РАЗМЕЩАЕТ, а не что они есть без спроса.
		var am := MapGen.generate({"style": MapGen.Style.ASTEROID, "size": 2, "seed": seed,
				"zones": 2, "density": 1, "civilians": 2})
		for sp: Dictionary in am.spawns:
			if int(sp["owner"]) == MCF.Owner.NEUTRAL:
				rock_civ += 1
	ck(rock_civ > 0, "asteroids get civilians across seeds (%d over six maps)" % rock_civ)
	var edge2 := MapGen.BORDER_ALL * 2
	ck(wide.width == 400 + edge2 and wide.height >= MapGen.MIN_DIM + edge2,
			"custom size has no upper limit, only a floor of %d (%dx%d incl. border)"
			% [MapGen.MIN_DIM, wide.width, wide.height])
	_bunker_is_an_underground_station()
	_stations_have_rooms_and_hallways()
	_civilian_levels()
	if fails.is_empty():
		print("mapgen: %d random maps keep every lobby promise; AI plays each style" % maps)
		quit(0)
		return
	printerr("mapgen: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _check(overrides: Dictionary) -> void:
	var o := MapGen.default_options()
	o.merge(overrides, true)
	var tag := "%s %s" % [MapGen.STYLE_NAMES[o["style"]], overrides]
	var m := MapGen.generate(o)
	maps += 1
	ck(JSON.stringify(m.to_dict()) == JSON.stringify(MapGen.generate(o).to_dict()),
			tag + ": the same seed builds the same map")
	var dim := MapGen.dims_of(o)
	ck(m.width >= dim.x and m.height >= dim.y, tag + ": size %dx%d" % [m.width, m.height])
	var need := MapGen.zone_need(int(o["units"]))
	var tight := m.width >= MapGen.MAX_DIM.x or m.height >= MapGen.MAX_DIM.y

	var zones := {}
	var used := {}
	for y in m.height:
		for x in m.width:
			var c := Vector2i(x, y)
			var f := m.get_feature(c)
			if f != "":
				used[f] = true
				# Высота — по общей таблице объектов: укрепления и мебель (§3.15).
				if MCF.feature_height(f) < 0.0 or not is_equal_approx(m.get_cover(c), MCF.feature_height(f)):
					ck(false, tag + ": %s at %s has height %.1f" % [f, c, m.get_cover(c)])
			var z := m.get_zone(c)
			if z < 0:
				continue
			if not zones.has(z):
				zones[z] = []
			zones[z].append(c)
			if m.get_space(c) or f != "" or m.get_cover(c) > 0.0:
				ck(false, tag + ": zone %d cell %s is not clear floor" % [z, c])
	ck(zones.size() == o["zones"], tag + ": %d zone(s) for %d slot(s)" % [zones.size(), o["zones"]])
	var sizes := {}
	for z in zones:
		sizes[zones[z].size()] = true
		ck(zones[z].size() >= (1 if tight else need),
				tag + ": zone %d has %d cells, %d units need %d" % [z, zones[z].size(), o["units"], need])
	ck(sizes.size() == 1, tag + ": zones differ in size %s" % [sizes.keys()])
	for a in zones:
		for b in zones:
			if a < b and _gap(zones[a], zones[b]) <= (1 if tight else MapGen.ZONE_GAP):
				ck(false, tag + ": zones %d and %d are %d cells apart" % [a, b, _gap(zones[a], zones[b])])

	# Пеший путь — по настоящей доске. И не только до зон: отрезанного пола нет вовсе.
	if zones.has(0):
		var grid := Grid.new(m.width, m.height)
		m.apply_to_grid(grid)
		var reach := _reach(grid, zones[0][0])
		for z in zones:
			var lost := 0
			for c: Vector2i in zones[z]:
				if not reach.has(c):
					lost += 1
			ck(lost == 0, tag + ": %d cell(s) of zone %d can't be reached on foot" % [lost, z])
		var sealed := 0
		var first := Vector2i(-1, -1)
		for y in m.height:
			for x in m.width:
				var c := Vector2i(x, y)
				if not m.get_space(c) and grid.cell(c).walkable_terrain() and not reach.has(c):
					sealed += 1
					if first.x < 0:
						first = c
		ck(sealed == 0, tag + ": %d walkable cell(s) are sealed off, e.g. %s" % [sealed, first])
		# Шлюз — это дверь: по одну сторону и по другую должно быть куда шагнуть.
		for y in m.height:
			for x in m.width:
				var c := Vector2i(x, y)
				if m.get_feature(c) != MCF.FEATURE_AIRLOCK:
					continue
				var through := false
				for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
					if grid.in_bounds(c + d) and grid.in_bounds(c - d) \
							and grid.cell(c + d).walkable_terrain() and grid.cell(c - d).walkable_terrain():
						through = true
				ck(through, tag + ": the airlock at %s opens into a wall" % c)

	var civ := 0
	var level := MapGen.civ_level(o)
	for s in m.spawns:
		var c: Vector2i = s["coord"]
		ck(MCF.is_neutral(int(s["owner"])) and s["stats_id"] == "civilian",
				tag + ": only civilians are pre-placed (%s)" % s)
		ck(m.get_zone(c) < 0 and not m.get_space(c) and m.get_feature(c) == "" and m.get_cover(c) <= 0.0,
				tag + ": civilian at %s stands on clear floor outside the zones" % c)
		civ += 1
	var floors := {}
	var vacuum := false
	for i in m.width * m.height:
		floors[m.floor_type[i]] = true
		vacuum = vacuum or m.is_space[i] != 0
	if not o["space"]:
		ck(not vacuum, tag + ": no vacuum without Space")
	# Двери — шлюзы, с космосом и без. От Medium и выше у станции всегда есть комнаты с
	# дверями; на Small, порезанном на четверти для восьмерых, четверть 13×9 — это зал без
	# перегородок, и дверей (а значит, и шлюзов) там может не быть вовсе.
	if (o["style"] == MapGen.Style.STATION or o["style"] == MapGen.Style.BUNKER) and int(o["size"]) >= 1:
		ck(used.has(MCF.FEATURE_AIRLOCK), tag + ": room doors are airlocks, with or without Space")
	if not o["flammable"]:
		ck(not floors.has(MCF.FLOOR_FLAMMABLE) and not floors.has(MCF.FLOOR_GRASS)
				and not used.has(MCF.FEATURE_WOOD_WALL), tag + ": nothing flammable")
	if not o["obstacles"]:
		ck(not used.has(MCF.FEATURE_SANDBAGS) and not used.has(MCF.FEATURE_HEDGEHOG)
				and not used.has(MCF.FEATURE_TRENCH), tag + ": no obstacles")
	if level == 0:
		ck(civ == 0, tag + ": no civilians")
	elif o["zones"] == 2 and o["size"] >= 1 and o["style"] != MapGen.Style.FIELD \
			and o["style"] != MapGen.Style.ASTEROID:
		# Астероида здесь нет вместе с полем, и по той же причине: жителю нужна ЗАПЕРТАЯ
		# комната вне обзора зон, а на каменном островке её может и не остаться — вакуум
		# съедает дома по краю, а две зоны занимают добрую половину того, что уцелело.
		# Проверка «хоть где-то жители есть» на астероиде — ниже, по набору зёрен.
		ck(civ > 0, tag + ": civilians are placed")
	if civ > 0:
		_dormant(m, tag)
		_sealed(m, tag)
	ck(civ <= MapGen.CIV_CAP[level], tag + ": %d civilians, cap %d" % [civ, MapGen.CIV_CAP[level]])
	if o["style"] == MapGen.Style.BUNKER:
		ck(not vacuum, tag + ": a bunker has no vacuum anywhere")
		var open_edge := 0
		# Край поля с 0.9.3 — граница мира (MapGen.BORDER_RIM): тот же грунт на вид, но
		# непробиваемый. Для этой проверки она такая же «сплошная скала», как стена и грунт.
		var solid := {MCF.FEATURE_WALL: true, MCF.FEATURE_SOIL: true, MCF.FEATURE_BOUNDARY: true}
		for y in m.height:
			for x in m.width:
				if (x == 0 or y == 0 or x == m.width - 1 or y == m.height - 1) \
						and not solid.has(m.get_feature(Vector2i(x, y))):
					open_edge += 1
		ck(open_edge == 0, tag + ": the bunker's edge is solid rock (%d open cell(s))" % open_edge)
	if o["symmetric"]:
		_symmetric(m, o, zones, tag)

## Карта совпадает со своими отражениями: четверти при 4 и 8 сторонах, иначе зеркало
## слева направо. Клетка — в клетку, зона — в зону целиком, мирный — в мирного.
func _symmetric(m: MapData, o: Dictionary, zones: Dictionary, tag: String) -> void:
	var quad: bool = int(o["zones"]) % 4 == 0
	var imgs := func(c: Vector2i) -> Array:
		var out := [Vector2i(m.width - 1 - c.x, c.y)]
		if quad:
			out.append(Vector2i(c.x, m.height - 1 - c.y))
			out.append(Vector2i(m.width - 1 - c.x, m.height - 1 - c.y))
		return out
	var bad := 0
	for y in m.height:
		for x in m.width:
			var c := Vector2i(x, y)
			for p: Vector2i in imgs.call(c):
				if m.get_feature(c) != m.get_feature(p) or m.get_floor(c) != m.get_floor(p) \
						or m.get_space(c) != m.get_space(p) or not is_equal_approx(m.get_cover(c), m.get_cover(p)):
					bad += 1
	ck(bad == 0, tag + ": %d cell(s) differ from their mirror image" % bad)
	for z in zones:
		for k in (3 if quad else 1):
			var image := {}
			for c: Vector2i in zones[z]:
				image[m.get_zone(imgs.call(c)[k])] = true
			ck(image.size() == 1 and not image.has(-1),
					tag + ": zone %d does not mirror onto a single zone (%s)" % [z, image.keys()])
	var civ := {}
	for s in m.spawns:
		civ[s["coord"]] = true
	for c: Vector2i in civ:
		for p: Vector2i in imgs.call(c):
			ck(civ.has(p), tag + ": civilian at %s has no mirror at %s" % [c, p])

## Бункер — станция того же зерна, только под землёй: без космоса их рельеф совпадает до
## байта (разнится лишь окружение — плитки металла и скалы, item 24, — и то, что пустота
## бункера — грунт, а не стена; по правилам это одно и то же), а с космосом у бункера нет
## ни клетки вакуума.
func _bunker_is_an_underground_station() -> void:
	for seed in [3, 77, 1234]:
		for size in 3:
			# Рельеф сравнивается без мебели: её бункер и станция ставят каждый своё
			# (казармы и арсеналы против кают и контор, §20.2) — так и задумано.
			var o := {"size": size, "seed": seed, "space": false, "furniture": 0}
			o["style"] = MapGen.Style.STATION
			var sm := MapGen.generate(o)
			ck(sm.env == "station", "a station map is tagged station (%s)" % sm.env)
			sm.env = ""
			var station := JSON.stringify(sm.to_dict())
			o["style"] = MapGen.Style.BUNKER
			var bm := MapGen.generate(o)
			ck(bm.env == "bunker", "a bunker map is tagged bunker (%s)" % bm.env)
			bm.env = ""
			for i in bm.feature_id.size():
				if bm.feature_id[i] == MCF.FEATURE_SOIL:
					bm.feature_id[i] = MCF.FEATURE_WALL
			ck(station == JSON.stringify(bm.to_dict()),
					"seed %d size %d: without space, bunker and station are the same map" % [seed, size])

## «Гораздо больше комнат и коридоров»: станция и бункер нарезаны на десятки комнат, а
## коридоры — заметная доля поля, на любом размере.
func _stations_have_rooms_and_hallways() -> void:
	for style in [MapGen.Style.STATION, MapGen.Style.BUNKER]:
		for size in 3:
			for seed in [1, 2, 3, 4, 5, 6]:
				var o := MapGen.default_options()
				o.merge({"style": style, "size": size, "seed": seed, "density": 1}, true)
				var dim: Vector2i = MapGen.SIZES[size]
				var g := MapGen.new()
				g._build(o, dim, MapGen.zone_need(10), false)
				var halls := 0
				for k in g._k:
					if k == MapGen.K_HALL:
						halls += 1
				var tag := "%s %s seed %d" % [MapGen.STYLE_NAMES[style], MapGen.SIZE_NAMES[size], seed]
				# Single-cell service tunnels shift room partitions; allow one room per 150 cells.
				ck(g._rooms.size() >= dim.x * dim.y / 150,
						tag + ": %d rooms on %d cells" % [g._rooms.size(), dim.x * dim.y])
				ck(halls >= dim.x * dim.y / 25,
						tag + ": hallways are %d of %d cells" % [halls, dim.x * dim.y])

## Худший случай расстановки: каждая клетка каждой зоны занята бойцом. Партия начинается
## так же, как у боевого экрана (шлюзы, слот мирных), затем одно действие — и ни один
## житель не должен проснуться или собраться в группу (§15 «Нейтралы»).
func _dormant(src: MapData, tag: String) -> void:
	var m := MapData.from_dict(src.to_dict())
	for y in m.height:
		for x in m.width:
			var z := m.get_zone(Vector2i(x, y))
			if z >= 0:
				m.set_spawn(Vector2i(x, y), "light_infantry", z)
	var state := m.build_state(7)
	var resolver := GameActionResolver.new(state)
	resolver.fog_enabled = false
	resolver.update_airlocks()
	resolver.play_civilian_slots()
	resolver.resolve(EndTurnIntent.new())
	for u: UnitInstance in state.all_units():
		if CivilianAI.is_npc(u) and (u.civilian_active or u.neutral_group != 0):
			ck(false, tag + ": the civilian at %s is awake at the start" % u.coord)

## Каждый мирный заперт шлюзами: если закрыть ВСЕ шлюзы, от его клетки до зон не дойти.
## Проверяется по настоящей доске (walkable_terrain), шлюз считается стеной.
func _sealed(m: MapData, tag: String) -> void:
	var grid := Grid.new(m.width, m.height)
	m.apply_to_grid(grid)
	for s in m.spawns:
		var start: Vector2i = s["coord"]
		var seen := {start: true}
		var queue: Array[Vector2i] = [start]
		var head := 0
		var reached := false
		while head < queue.size() and not reached:
			var c := queue[head]
			head += 1
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var p := c + d
				if not grid.in_bounds(p) or seen.has(p):
					continue
				if m.get_feature(p) == MCF.FEATURE_AIRLOCK or not grid.cell(p).walkable_terrain():
					continue
				if m.get_zone(p) >= 0:
					reached = true
					break
				seen[p] = true
				queue.append(p)
		ck(not reached, tag + ": the civilian at %s can walk to a zone without opening an airlock" % start)

## Уровень мирных — порядок величины: больше уровень — больше жителей, каждый под своим
## потолком.
func _civilian_levels() -> void:
	for style in [MapGen.Style.TOWN, MapGen.Style.STATION]:
		var counts: Array[int] = []
		for lv in MapGen.CIV_LEVELS.size():
			var m := MapGen.generate({"style": style, "size": 3, "seed": 404, "civilians": lv})
			counts.append(m.spawns.size())
			ck(m.spawns.size() <= MapGen.CIV_CAP[lv], "%s level %s: %d civilians over the cap %d" % [
					MapGen.STYLE_NAMES[style], MapGen.CIV_LEVELS[lv], m.spawns.size(), MapGen.CIV_CAP[lv]])
		ck(counts[0] == 0 and counts[1] > 0 and counts[1] < counts[2] and counts[2] < counts[3]
				and counts[3] <= counts[4], "%s: civilians grow with the level %s" % [
				MapGen.STYLE_NAMES[style], counts])
		print("mapgen: %s Huge civilians per level %s" % [MapGen.STYLE_NAMES[style], counts])

## Ближайшее расстояние (по Чебышёву) между клетками двух зон.
func _gap(a: Array, b: Array) -> int:
	var best := 1 << 30
	for p: Vector2i in a:
		for q: Vector2i in b:
			best = mini(best, maxi(absi(p.x - q.x), absi(p.y - q.y)))
	return best

func _reach(grid: Grid, from: Vector2i) -> Dictionary:
	var seen := {from: true}
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var p := c + d
			if grid.in_bounds(p) and not seen.has(p) and grid.cell(p).walkable_terrain():
				seen[p] = true
				queue.append(p)
	return seen

## Короткая партия ИИ против ИИ: отряд каждой стороны — в её зоне, как после расстановки.
func _play(style: int) -> void:
	var o := MapGen.default_options()
	o.merge({"style": style, "seed": 77 + style}, true)
	var m := MapGen.generate(o)
	for side in 2:
		var cells := m.zone_cells(side)
		for k in mini(SQUAD.size(), cells.size()):
			m.set_spawn(cells[k * cells.size() / SQUAD.size()], SQUAD[k], side)
	var state := m.build_state(20260929)
	var resolver := GameActionResolver.new(state)
	resolver.fog_enabled = false
	resolver.play_civilian_slots()
	var brains := {}
	for side in 2:
		var ai := AIController.new(side, AIController.Difficulty.NORMAL)
		ai.intent_ready.connect(func(intent: Intent) -> void: _pending = intent)
		brains[side] = ai
	var actions := 0
	while state.turns.round_number <= ROUNDS and actions < MAX_ACTIONS:
		var ai: AIController = brains.get(state.active_player(), null)
		_pending = null
		if ai != null:
			ai.begin_turn(state)
		if _pending == null:
			resolver.resolve(EndTurnIntent.new())
			continue
		actions += 1
		if not resolver.resolve(_pending).ok:
			ai.notify_intent_denied(state)
	ck(actions < MAX_ACTIONS, "%s: the AI keeps ending its turns" % MapGen.STYLE_NAMES[style])
	ck(actions > 0, "%s: the AI finds something to do" % MapGen.STYLE_NAMES[style])

## Поле роется НИТКАМИ окопов, а не только ячейками, и роется тем гуще, чем выше
## плотность. Проверяется не «есть окопы», а длина СВЯЗНОЙ линии: короткие огрызки
## _trench() дают максимум семь клеток, поэтому цепь заметно длиннее семи может взяться
## только из _trench_line.
func _field_digs_trench_lines() -> void:
	var by_density: Array[int] = []
	var longest_at: Array[int] = []
	for dens in [0, 1, 2]:
		var cells_total := 0
		var longest := 0
		for n in 5:
			var m := MapGen.generate({"style": MapGen.Style.FIELD, "size": 2, "density": dens,
					"seed": 400 + n * 13, "zones": 2, "units": 20})
			var dug := {}
			for y in m.height:
				for x in m.width:
					if m.get_feature(Vector2i(x, y)) == MCF.FEATURE_TRENCH:
						dug[Vector2i(x, y)] = true
			cells_total += dug.size()
			longest = maxi(longest, _longest_chain(dug))
		by_density.append(cells_total)
		longest_at.append(longest)
	ck(longest_at[1] > 12,
			"a normal field grows trench lines, not just pits (longest chain %d)" % longest_at[1])
	ck(by_density[0] < by_density[1] and by_density[1] < by_density[2],
			"and density decides how much of it there is (%s)" % [by_density])
	ck(longest_at[2] >= longest_at[0],
			"a dense field digs lines at least as long as a sparse one (%s)" % [longest_at])

## Длина самой длинной СВЯЗНОЙ (по четырём сторонам) цепочки окопов.
func _longest_chain(dug: Dictionary) -> int:
	var seen := {}
	var best := 0
	for c: Vector2i in dug:
		if seen.has(c):
			continue
		var stack: Array = [c]
		seen[c] = true
		var n := 0
		while not stack.is_empty():
			var p: Vector2i = stack.pop_back()
			n += 1
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q: Vector2i = p + d
				if dug.has(q) and not seen.has(q):
					seen[q] = true
					stack.append(q)
		best = maxi(best, n)
	return best
