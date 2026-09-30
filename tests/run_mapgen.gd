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
##   6. на карте каждого стиля ИИ против ИИ доигрывает несколько раундов, не зависая.

const ROUNDS := 3
const MAX_ACTIONS := 4000
const SQUAD := ["light_infantry", "heavy_infantry", "machinegunner", "sniper", "engineer",
		"flamethrower", "miner", "anti_tank"]

var fails: PackedStringArray = []
var maps := 0
var _pending: Intent = null

func _initialize() -> void:
	for style in MapGen.STYLE_NAMES.size():
		for size in MapGen.SIZES.size():
			for k in 3:
				_check({"style": style, "size": size, "density": k, "seed": 1000 * k + 17 * style + size,
						"zones": 2 + (k + size) % 3})
		for key: String in ["space", "flammable", "obstacles", "civilians"]:
			_check({"style": style, "seed": 4242 + style, key: false})
		# Большие отряды на маленьком поле: зоны обязаны их вместить — поле растёт.
		_check({"style": style, "size": 0, "seed": 31 + style, "zones": 3, "units": 40})
		_check({"style": style, "size": 1, "seed": 57 + style, "zones": 6, "units": 12})
		_play(style)
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
	var tag := "%s %s %s" % [MapGen.STYLE_NAMES[o["style"]], MapGen.SIZE_NAMES[o["size"]], overrides]
	var m := MapGen.generate(o)
	maps += 1
	ck(JSON.stringify(m.to_dict()) == JSON.stringify(MapGen.generate(o).to_dict()),
			tag + ": the same seed builds the same map")
	var dim: Vector2i = MapGen.SIZES[o["size"]]
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
				if not MCF.FEATURE_HEIGHT.has(f) or not is_equal_approx(m.get_cover(c), MCF.FEATURE_HEIGHT[f]):
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

	# Пеший путь — по настоящей доске.
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

	var civ := 0
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
		ck(not vacuum and not used.has(MCF.FEATURE_AIRLOCK), tag + ": no vacuum or airlocks")
	if not o["flammable"]:
		ck(not floors.has(MCF.FLOOR_FLAMMABLE) and not floors.has(MCF.FLOOR_GRASS)
				and not used.has(MCF.FEATURE_WOOD_WALL), tag + ": nothing flammable")
	if not o["obstacles"]:
		ck(not used.has(MCF.FEATURE_SANDBAGS) and not used.has(MCF.FEATURE_HEDGEHOG)
				and not used.has(MCF.FEATURE_TRENCH), tag + ": no obstacles")
	if not o["civilians"]:
		ck(civ == 0, tag + ": no civilians")
	elif o["zones"] == 2 and o["size"] >= 1:
		ck(civ > 0, tag + ": civilians are placed")
	if civ > 0:
		_dormant(m, tag)

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
