extends SceneTree

## Мебель (§3.15) от таблицы до экрана боя.
##
## Таблица: высоты из четырёх классов, вся переносная мебель — прочности 1, «перегораживает»
## ровно то, что в рост стены, у каждого предмета есть плитка, рецепты генератора ссылаются
## только на существующее.
## Клетка: высота = cover_height, 2 м — стена для взгляда и прохода, на ниже — залезают по
## обычной цене подъёма, укрытие у цели −2 (1 м) и −3 (1.5 м, только мебель — тот же
## 1.5 м рельеф без мебели укрытием, как и раньше, не считается).
## Действия: унести/поставить, волочь тяжёлое (прочность едет с ним), неподвижное не
## двигается, ломать за 1–3 ОД; разрыв, луч, огонь — по прочности и материалу.
## Сохранение, откат, сеть и пересинхронизация несут id, высоту и прочность.
## Генератор: мебель есть, одно зерно — одна обстановка, «Off» и «Normal» отличаются ТОЛЬКО
## мебелью, у дверей пусто, весь свободный пол достижим даже при непроходимой мебели,
## симметричная карта обставлена зеркально, ИИ доигрывает обставленную карту.
## Экран боя: Carry / Break Furniture / Put Down — ровно тогда, когда есть что делать.

const TS = preload("res://tests/TestSupport.gd")

var fails: PackedStringArray = []
var _main: Node = null
var _frames := 0

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

func _initialize() -> void:
	GameConfig.civilians_enabled = false
	_table()
	_cell_rules()
	_actions()
	_weapons()
	_save_undo_net()
	_generation()
	_ai_plays_furnished()
	_start_screen()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 5 or _main == null or _main.state == null or _main._animating:
		return false
	_screen_checks()
	_main.queue_free()
	if fails.is_empty():
		print("furniture: table, heights, cover, carry/drag/break, weapons, saves, undo, net, generator, AI and the battle menu all hold")
		quit(0)
	else:
		printerr("furniture: %d failure(s)" % fails.size())
		for f in fails:
			printerr("  " + f)
		quit(1)
	return true

# --- Таблица -----------------------------------------------------------------------------

func _table() -> void:
	ck(Furniture.DEFS.size() >= 40, "at least forty furniture types (%d)" % Furniture.DEFS.size())
	for fid: String in Furniture.DEFS:
		var d: Dictionary = Furniture.DEFS[fid]
		ck(float(d["h"]) in [0.5, 1.0, 1.5, 2.0], "%s height is one of the four classes" % fid)
		ck(int(d["dur"]) >= 1 and int(d["ap"]) >= 1 and int(d["ap"]) <= 3, "%s durability and break AP in range" % fid)
		if Furniture.carriable(fid):
			ck(int(d["dur"]) == 1, "portable %s has durability 1 (nothing to remember while carried)" % fid)
			ck(float(d["h"]) <= 0.5, "portable %s is a low piece" % fid)
		ck(Furniture.blocks_move(fid) == (float(d["h"]) >= MCF.WALL_HEIGHT), "%s blocks movement iff wall-height" % fid)
		ck(FileAccess.file_exists("res://textures/%s.png" % fid), "%s has a texture" % fid)
		ck(not (d["rooms"] as Array).is_empty(), "%s has room preferences" % fid)
		ck(not MCF.FEATURE_HEIGHT.has(fid) and not MCF.FEATURE_NAMES.has(fid), "%s doesn't clash with a fortification id" % fid)
	for arch: String in MapFurnish.RECIPES:
		for step: Dictionary in MapFurnish.RECIPES[arch]:
			ck(Furniture.is_furniture(step["f"]), "recipe %s uses a real piece (%s)" % [arch, step["f"]])
			for sub: Dictionary in step.get("then", []):
				ck(Furniture.is_furniture(sub["f"]), "recipe %s companion is real (%s)" % [arch, sub["f"]])
	for style: String in MapFurnish.ROOMS:
		for size_list: Array in MapFurnish.ROOMS[style]:
			for o: Array in size_list:
				ck(MapFurnish.RECIPES.has(o[0]), "%s room type %s has a recipe" % [style, o[0]])
	var want := {"chair": 1, "trash_bin": 1, "desk": 2, "filing_cabinet": 2, "bookshelf": 2,
			"wardrobe": 3, "locker": 3, "workbench": 3, "server_rack": 4, "industrial_cabinet": 4,
			"generator": 5}
	for fid: String in want:
		ck(Furniture.durability_of(fid) == want[fid], "%s durability default %d" % [fid, want[fid]])
	ck(MCF.feature_name("bed") == "Bed" and MCF.feature_height("wardrobe") == 1.5,
			"names and heights reach the shared helpers")

# --- Клетка: высота, проход, обзор, укрытие ----------------------------------------------

func _board(cells: Dictionary, spawns: Array) -> GameState:
	var m := MapData.new(20, 12)
	for y in 12:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_FLAMMABLE, 0.0, false, "")
	for c: Vector2i in cells:
		var v: Variant = cells[c]
		if v is float:
			m.set_cell(c, MCF.FLOOR_FLAMMABLE, v, false, "")
		else:
			m.set_cell(c, MCF.FLOOR_FLAMMABLE, maxf(0.0, MCF.feature_height(v)), false, v)
	for s: Array in spawns:
		m.set_spawn(s[0], s[1], s[2])
	var st := m.build_state(3)
	for side in [0, 1]:
		st.roster.slot(side).kind = Roster.SlotKind.HUMAN
	return st

func _cell_rules() -> void:
	var st := _board({Vector2i(5, 2): "chair", Vector2i(6, 2): "desk", Vector2i(7, 2): "wardrobe",
			Vector2i(8, 2): "storage_shelf"}, [[Vector2i(1, 1), "light_infantry", 0], [Vector2i(18, 10), "light_infantry", 1]])
	for c: Vector2i in [Vector2i(5, 2), Vector2i(6, 2), Vector2i(7, 2), Vector2i(8, 2)]:
		var cell := st.grid.cell(c)
		ck(cell.cover_height == Furniture.height_of(cell.feature_id),
				"%s stands %.1f m tall on the board" % [cell.feature_id, cell.cover_height])
		ck(cell.feature_durability == Furniture.durability_of(cell.feature_id), "%s starts at full durability" % cell.feature_id)
	var shelf := st.grid.cell(Vector2i(8, 2))
	ck(shelf.is_wall() and shelf.blocks_sight() and not shelf.walkable_terrain(),
			"a 2 m shelf is a wall for sight and movement")
	var reach := Movement.reachable(st.grid, Vector2i(5, 3), 12)
	ck(int(reach.cost.get(Vector2i(5, 2), -1)) == MCF.CLIMB_COST[0.5], "climbing onto a chair costs the 0.5 m climb")
	ck(int(reach.cost.get(Vector2i(6, 2), -1)) == MCF.CLIMB_COST[1.0], "onto a desk costs the 1 m climb")
	var w_cost := int(Movement.reachable(st.grid, Vector2i(7, 3), 12).cost.get(Vector2i(7, 2), -1))
	ck(w_cost == MCF.CLIMB_COST[1.5], "onto a wardrobe costs the 1.5 m climb (%d)" % w_cost)
	ck(not reach.cost.has(Vector2i(8, 2)), "the 2 m shelf can't be stood on")
	# Укрытие: цель за предметом на линии к стрелку, стрелок далеко.
	for case: Array in [["chair", 0], ["desk", 2], ["wardrobe", 3]]:
		var s2 := _board({Vector2i(10, 5): case[0]}, [[Vector2i(3, 5), "light_infantry", 0],
				[Vector2i(11, 5), "light_infantry", 1]])
		var r2 := GameActionResolver.new(s2)
		var shooter := s2.grid.cell(Vector2i(3, 5)).occupant
		var target := s2.grid.cell(Vector2i(11, 5)).occupant
		var pen := int(r2.cover_effect(shooter, target)["hit_penalty"])
		ck(pen == case[1], "a target behind a %s gets −%d to be hit (got −%d)" % [case[0], case[1], pen])
	# Тот же 1.5 м без мебели — рельеф: правило не изменилось, штрафа нет.
	var s3 := _board({Vector2i(10, 5): 1.5}, [[Vector2i(3, 5), "light_infantry", 0], [Vector2i(11, 5), "light_infantry", 1]])
	var r3 := GameActionResolver.new(s3)
	ck(int(r3.cover_effect(s3.grid.cell(Vector2i(3, 5)).occupant, s3.grid.cell(Vector2i(11, 5)).occupant)["hit_penalty"]) == 0,
			"a bare 1.5 m terrain step still gives no cover (unchanged rule)")
	# А сандбэги (не мебель) — как и прежде, −2.
	var s4 := _board({Vector2i(10, 5): MCF.FEATURE_SANDBAGS}, [[Vector2i(3, 5), "light_infantry", 0], [Vector2i(11, 5), "light_infantry", 1]])
	var r4 := GameActionResolver.new(s4)
	ck(int(r4.cover_effect(s4.grid.cell(Vector2i(3, 5)).occupant, s4.grid.cell(Vector2i(11, 5)).occupant)["hit_penalty"]) == 2,
			"sandbags still give −2")
	var s5 := _board({Vector2i(7, 5): "storage_shelf"}, [[Vector2i(3, 5), "light_infantry", 0], [Vector2i(11, 5), "light_infantry", 1]])
	var r5 := GameActionResolver.new(s5)
	r5.fog_enabled = false
	ck(r5.can_shoot(s5.grid.cell(Vector2i(3, 5)).occupant, s5.grid.cell(Vector2i(11, 5)).occupant) != "",
			"nobody shoots through a 2 m shelf")

# --- Унести, поставить, волочь, сломать --------------------------------------------------

func _actions() -> void:
	var st := _board({Vector2i(6, 5): "chair", Vector2i(4, 5): "desk", Vector2i(5, 4): "kitchen_counter",
			Vector2i(5, 6): "generator", Vector2i(10, 5): "chair"},
			[[Vector2i(5, 5), "light_infantry", 0], [Vector2i(11, 5), "machinegunner", 0],
			[Vector2i(18, 10), "light_infantry", 1]])
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var u := st.grid.cell(Vector2i(5, 5)).occupant
	ck(r.furniture_carry_cells(u) == [Vector2i(6, 5)], "only the chair is offered to carry (%s)" % str(r.furniture_carry_cells(u)))
	ck(r.can_carry_furniture(u, Vector2i(4, 5)) != "", "a desk can't be picked up")
	ck(r.can_carry_furniture(u, Vector2i(5, 4)) != "", "a built-in counter can't be picked up")
	var ap := u.remaining_ap
	var res := r.resolve(CarryIntent.new(u.id, Vector2i(6, 5)))
	ck(res.ok, "carrying the chair is accepted (%s)" % res.reason)
	ck(u.held_item_id == "chair" and st.grid.cell(Vector2i(6, 5)).feature_id == "" \
			and st.grid.cell(Vector2i(6, 5)).cover_height == 0.0, "the chair is in hand and its cell is bare floor")
	ck(u.remaining_ap == ap - 1, "picking up costs 1 AP")
	ck(st.grid.cell(Vector2i(6, 5)).floor_type == MCF.FLOOR_FLAMMABLE, "the floor under it is untouched")
	ck(r.resolve(UseItemIntent.new(u.id, Vector2i(4, 5))).ok == false, "it can't be set down onto the desk")
	ap = u.remaining_ap
	res = r.resolve(UseItemIntent.new(u.id, Vector2i(6, 6)))
	ck(res.ok, "setting it down beside is accepted (%s)" % res.reason)
	ck(st.grid.cell(Vector2i(6, 6)).feature_id == "chair" and st.grid.cell(Vector2i(6, 6)).cover_height == 0.5,
			"the chair stands at its new cell with its height")
	ck(u.held_item_id == "" and u.remaining_ap == ap, "hands empty again, and putting down is free")
	var mg := st.grid.cell(Vector2i(11, 5)).occupant
	ck(mg.held_item_id != "" and r.can_carry_furniture(mg, Vector2i(10, 5)) == "Hands are full",
			"a soldier holding a grenade has no hands for a chair")
	# Волочение тяжёлого: стол едет, побитость едет с ним.
	st.grid.cell(Vector2i(4, 5)).feature_durability = 1
	ck(GameActionResolver.is_draggable_feature("desk") and not GameActionResolver.is_draggable_feature("kitchen_counter"),
			"desks drag, counters don't")
	res = r.resolve(DragIntent.new(u.id, Vector2i(4, 5), Vector2i(4, 4)))
	ck(res.ok, "dragging the desk is accepted (%s)" % res.reason)
	var moved := st.grid.cell(Vector2i(4, 4))
	ck(moved.feature_id == "desk" and moved.cover_height == 1.0 and moved.feature_durability == 1,
			"the desk moved with its height and its damage")
	ck(st.grid.cell(Vector2i(4, 5)).feature_id == "" and u.dragging == Vector2i(4, 4), "and stays in tow")
	ck(not r.resolve(DragIntent.new(u.id, Vector2i(5, 4), Vector2i(4, 5))).ok, "the counter won't budge")
	ck(not r.resolve(DragIntent.new(u.id, Vector2i(5, 6), Vector2i(4, 6))).ok, "nor will the generator")
	ck(not r.resolve(DragIntent.new(u.id, Vector2i(4, 4), Vector2i(6, 6))).ok, "and nothing is dragged onto another piece")
	# Сломать: цена из таблицы, клетка — снова пол.
	u.remaining_ap = 2
	ck(r.furniture_smash_cells(u).has(Vector2i(5, 4)) and not r.furniture_smash_cells(u).has(Vector2i(5, 6)),
			"with 2 AP the counter (2) can be smashed, the generator (3) can't")
	res = r.resolve(BreakIntent.new(u.id, Vector2i(5, 6)))
	ck(not res.ok and res.reason == "Need 3 AP", "the generator needs 3 AP (%s)" % res.reason)
	res = r.resolve(BreakIntent.new(u.id, Vector2i(5, 4)))
	ck(res.ok and u.remaining_ap == 0, "a rifleman smashes the counter for 2 AP")
	ck(st.grid.cell(Vector2i(5, 4)).feature_id == "" and st.grid.cell(Vector2i(5, 4)).cover_height == 0.0 \
			and st.grid.cell(Vector2i(5, 4)).floor_type == MCF.FLOOR_FLAMMABLE, "leaving bare floor behind")
	ck(r.breakable_cells(u).is_empty(), "furniture never shows up as a fortification to demolish")

# --- Оружие ------------------------------------------------------------------------------

func _weapons() -> void:
	var st := _board({Vector2i(8, 5): "chair", Vector2i(9, 5): "desk", Vector2i(8, 6): "generator",
			Vector2i(4, 9): "chair", Vector2i(6, 9): "wardrobe", Vector2i(12, 2): "crate",
			Vector2i(13, 2): "server_rack"},
			[[Vector2i(1, 9), "marksman", 0], [Vector2i(18, 1), "light_infantry", 1]])
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var res := ActionResult.success([])
	r._blast(Vector2i(8, 5), res)
	ck(st.grid.cell(Vector2i(8, 5)).feature_id == "", "a blast blows the chair at its centre away")
	ck(st.grid.cell(Vector2i(9, 5)).feature_id == "", "and the desk beside it (2 durability)")
	ck(st.grid.cell(Vector2i(8, 6)).feature_id == "generator" and st.grid.cell(Vector2i(8, 6)).feature_durability == 3,
			"the generator survives one blast, down to 3")
	r._blast(Vector2i(8, 5), res)
	r._blast(Vector2i(8, 5), res)
	ck(st.grid.cell(Vector2i(8, 6)).feature_id == "", "and goes with the third")
	# Луч: стул за 1, шкаф за 3 — оба сгорают, луч летит дальше.
	var mk := st.grid.cell(Vector2i(1, 9)).occupant
	var plan := r.laser_preview(mk, Vector2i(10, 9))
	var costs := {}
	for rec: Dictionary in plan:
		if rec["kind"] == "feature":
			costs[rec["coord"]] = [int(rec["cost"]), bool(rec["destroyed"])]
	ck(costs.get(Vector2i(4, 9), []) == [1, true] and costs.get(Vector2i(6, 9), []) == [3, true],
			"the beam pays each piece's durability and burns through (%s)" % str(costs))
	res = r.resolve(ShootIntent.new(mk.id, -1, -1, Vector2i(10, 9)))
	ck(res.ok and st.grid.cell(Vector2i(4, 9)).feature_id == "" and st.grid.cell(Vector2i(6, 9)).feature_id == "",
			"firing the laser clears both (%s)" % res.reason)
	# Огонь: дерево горит, железо — нет.
	ck(r.fire_need(st.grid.cell(Vector2i(12, 2))) == MCF.FIRE_NEED_WOOD, "a wooden crate catches like a wooden wall")
	ck(r.fire_need(st.grid.cell(Vector2i(13, 2))) == MCF.FIRE_NEVER, "a server rack never catches from spreading fire")
	r._ignite(st.grid.cell(Vector2i(13, 2)), 0, res)
	ck(st.grid.cell(Vector2i(13, 2)).feature_id == "server_rack", "a flame jet scorches the rack but leaves it standing")
	r._ignite(st.grid.cell(Vector2i(12, 2)), 0, res)
	ck(st.grid.cell(Vector2i(12, 2)).feature_id == "", "but burns the crate away")

# --- Сохранение, откат, сеть -------------------------------------------------------------

func _save_undo_net() -> void:
	var cells := {Vector2i(6, 5): "chair", Vector2i(4, 5): "desk", Vector2i(5, 6): "nightstand",
			Vector2i(9, 9): "generator"}
	var a := _board(cells, [[Vector2i(5, 5), "light_infantry", 0], [Vector2i(18, 10), "light_infantry", 1]])
	var b := _board(cells, [[Vector2i(5, 5), "light_infantry", 0], [Vector2i(18, 10), "light_infantry", 1]])
	var host := NetGame.new(a, GameActionResolver.new(a), true, 0)
	var guest := NetGame.new(b, GameActionResolver.new(b), false, 1)
	host.resolver.fog_enabled = false
	guest.resolver.fog_enabled = false
	var resyncs := [0]
	host.outgoing.connect(func(msg: Dictionary) -> void: guest.receive(msg))
	guest.outgoing.connect(func(_msg: Dictionary) -> void: resyncs[0] += 1)
	var uid := a.grid.cell(Vector2i(5, 5)).occupant.id
	a.grid.cell(Vector2i(9, 9)).feature_durability = 2
	b.grid.cell(Vector2i(9, 9)).feature_durability = 2
	for it: Intent in [CarryIntent.new(uid, Vector2i(6, 5)), UseItemIntent.new(uid, Vector2i(6, 6)),
			DragIntent.new(uid, Vector2i(4, 5), Vector2i(4, 4)), BreakIntent.new(uid, Vector2i(5, 6))]:
		host.submit_local(it)
	ck(resyncs[0] == 0 and TS.digest(a) == TS.digest(b), "carry, put down, drag and smash play the same on host and guest")
	ck(a.grid.cell(Vector2i(5, 6)).feature_id == "" and a.grid.cell(Vector2i(6, 6)).feature_id == "chair",
			"and actually happened")
	# Пересинхронизация и сохранение: всё через StateCodec, туда и обратно через JSON.
	var back := GameState.new(a.grid.width, a.grid.height)
	StateCodec.restore_into(back, JSON.parse_string(JSON.stringify(StateCodec.encode(a))))
	ck(TS.digest(back) == TS.digest(a), "a resync / save round-trip keeps every piece, height and dent")
	ck(back.grid.cell(Vector2i(9, 9)).feature_durability == 2, "the damaged generator stays damaged")
	# Откат и повтор.
	var r := GameActionResolver.new(a)
	r.fog_enabled = false
	var u := a.get_unit(uid)
	u.remaining_ap = 2
	var before := TS.digest(a)
	ck(r.resolve(BreakIntent.new(uid, Vector2i(6, 6))).ok, "smash the chair again")
	var after := TS.digest(a)
	ck(r.resolve(UndoIntent.new(0)).ok and TS.digest(a) == before, "undo brings the chair back exactly")
	ck(r.resolve(RedoIntent.new(0)).ok and TS.digest(a) == after, "redo smashes it again")
	ck(r.resolve(CarryIntent.new(uid, Vector2i(5, 5) + Vector2i(1, -1))).ok == false, "nothing to carry where nothing stands")
	# Карта: побитая мебель переживает «Save as map».
	var m := MapData.new(6, 4)
	m.set_cell(Vector2i(2, 2), MCF.FLOOR_NORMAL, 1.0, false, "workbench")
	m.set_feature_damage(Vector2i(2, 2), 1)
	m.set_cell(Vector2i(3, 2), MCF.FLOOR_NORMAL, 1.5, false, "wardrobe")
	var m2 := MapData.from_dict(JSON.parse_string(JSON.stringify(m.to_dict())))
	var g := Grid.new(6, 4)
	m2.apply_to_grid(g)
	ck(g.cell(Vector2i(2, 2)).feature_id == "workbench" and g.cell(Vector2i(2, 2)).feature_durability == 1,
			"a saved map keeps a cracked workbench cracked")
	ck(g.cell(Vector2i(3, 2)).feature_durability == 3 and g.cell(Vector2i(3, 2)).cover_height == 1.5,
			"and a whole wardrobe whole")
	m2.set_cell(Vector2i(2, 2), MCF.FLOOR_NORMAL, 0.5, false, "chair")
	var g2 := Grid.new(6, 4)
	m2.apply_to_grid(g2)
	ck(g2.cell(Vector2i(2, 2)).feature_durability == 1 and not m2.to_dict().has("feature_durability"),
			"a repainted cell doesn't inherit the old dent, and plain maps save as before")

# --- Генератор ---------------------------------------------------------------------------

func _gen(style: int, lv: int, seed: int, extra: Dictionary = {}) -> MapData:
	var o := {"style": style, "size": 2, "seed": seed, "furniture": lv, "civilians": 0}
	o.merge(extra, true)
	return MapGen.generate(o)

func _count(m: MapData) -> int:
	var n := 0
	for f in m.feature_id:
		if Furniture.is_furniture(f):
			n += 1
	return n

func _generation() -> void:
	for style in 5:
		var name: String = MapGen.STYLE_NAMES[style]
		var on := _gen(style, 2, 41)
		var off := _gen(style, 0, 41)
		var n := _count(on)
		if style == MapGen.Style.FIELD:
			ck(n < _count(_gen(MapGen.Style.STATION, 2, 41)), "%s: much less furniture than a station (%d)" % [name, n])
		else:
			ck(n >= 10, "%s: rooms are furnished (%d pieces)" % [name, n])
		ck(_count(off) == 0, "%s: Off places nothing" % name)
		var again := _gen(style, 2, 41)
		ck(again.feature_id == on.feature_id and again.feature_dur == on.feature_dur,
				"%s: the same seed builds the same furniture" % name)
		# «Off» и «Normal» — одна и та же карта, кроме мебели.
		var other := 0
		for i in on.feature_id.size():
			var fon: String = on.feature_id[i]
			if Furniture.is_furniture(fon):
				if off.feature_id[i] != "" or off.cover_height[i] != 0.0:
					other += 1
			elif fon != off.feature_id[i] or on.cover_height[i] != off.cover_height[i]:
				other += 1
			if on.floor_type[i] != off.floor_type[i] or on.is_space[i] != off.is_space[i]:
				other += 1
		ck(other == 0, "%s: furniture changes nothing else on the map (%d cells differ)" % [name, other])
		ck(_no_furniture_at_doors(on), "%s: no furniture next to any door or airlock" % name)
		var lost := _cut_off(off, on)
		ck(lost == 0, "%s: every floor cell stays reachable even treating furniture as solid (%d cut off)" % [name, lost])
		var st := on.build_state(1)
		var wrong := 0
		for i in on.feature_id.size():
			var f: String = on.feature_id[i]
			if Furniture.is_furniture(f) and st.grid.cell(Vector2i(i % on.width, i / on.width)).cover_height != Furniture.height_of(f):
				wrong += 1
		ck(wrong == 0, "%s: every piece stands at its table height in the battle" % name)
	var sparse := _count(_gen(MapGen.Style.STATION, 1, 7))
	var normal := _count(_gen(MapGen.Style.STATION, 2, 7))
	var dense := _count(_gen(MapGen.Style.STATION, 4, 7))
	ck(sparse < normal and normal < dense, "density grows Sparse %d < Normal %d < Very dense %d" % [sparse, normal, dense])
	var worn := _gen(MapGen.Style.BUNKER, 3, 9, {"furniture_damage": 2})
	var clean := _gen(MapGen.Style.BUNKER, 3, 9)
	ck(not worn.feature_dur.is_empty() and _count(worn) < _count(clean),
			"heavy wear leaves dents (%d) and gaps (%d of %d)" % [worn.feature_dur.size(), _count(worn), _count(clean)])
	var sym := _gen(MapGen.Style.STATION, 3, 13, {"symmetric": true})
	var asym := 0
	for y in sym.height:
		for x in sym.width:
			var f := sym.get_feature(Vector2i(x, y))
			if Furniture.is_furniture(f) and sym.get_feature(Vector2i(sym.width - 1 - x, y)) != f:
				asym += 1
	ck(_count(sym) > 0 and asym == 0, "a symmetrical map is furnished as a mirror (%d mismatches)" % asym)
	ck(not MapFurnish.DENSITY_NAMES.is_empty() and MapGen.default_options()["furniture"] == MapFurnish.DEFAULT_DENSITY,
			"Normal furniture is the generator default")
	# Проход и двери — на пачке плотных карт с износом и зеркалом (полная прогонка на 240
	# картах при разработке дала ноль нарушений; здесь — сторож от регрессии).
	var bad := 0
	for style in 5:
		for seed: int in [301, 302, 303]:
			var o := {"furniture_damage": seed % 3, "symmetric": seed == 303, "size": 1 + seed % 2}
			var packed := _gen(style, 4, seed, o)
			var bare := _gen(style, 0, seed, o)
			if _cut_off(bare, packed) > 0 or not _no_furniture_at_doors(packed):
				bad += 1
				print("     walkway broken: style %d seed %d" % [style, seed])
	ck(bad == 0, "15 very dense, worn, some mirrored maps keep every walkway and doorway (%d broken)" % bad)

func _no_furniture_at_doors(m: MapData) -> bool:
	for y in m.height:
		for x in m.width:
			if m.get_feature(Vector2i(x, y)) != MCF.FEATURE_AIRLOCK:
				continue
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if Furniture.is_furniture(m.get_feature(Vector2i(x + dx, y + dy))):
						return false
	return true

## Сколько клеток свободного пола, достижимых на карте без мебели, становятся
## недостижимыми, если всю мебель считать стеной. Источник — первая клетка зоны.
func _cut_off(off: MapData, on: MapData) -> int:
	var start := Vector2i(-1, -1)
	for i in on.zone_owner.size():
		if on.zone_owner[i] >= 0:
			start = Vector2i(i % on.width, i / on.width)
			break
	var a := _reach(off, start, false)
	var b := _reach(on, start, true)
	var lost := 0
	for c: Vector2i in a:
		var f := on.get_feature(c)
		if not Furniture.is_furniture(f) and not b.has(c):
			lost += 1
	return lost

func _reach(m: MapData, start: Vector2i, furniture_solid: bool) -> Dictionary:
	var seen := {start: true}
	var q: Array[Vector2i] = [start]
	var k := 0
	while k < q.size():
		var p := q[k]
		k += 1
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = p + d
			if seen.has(n) or not m.in_bounds(n):
				continue
			var f := m.get_feature(n)
			var walk := f == MCF.FEATURE_AIRLOCK or (m.get_cover(n) < MCF.WALL_HEIGHT
					and f != MCF.FEATURE_HEDGEHOG and f != MCF.FEATURE_DRONE_STATION)
			if furniture_solid and Furniture.is_furniture(f):
				walk = false
			if walk:
				seen[n] = true
				q.append(n)
	return seen

# --- ИИ ----------------------------------------------------------------------------------

var _pending: Intent = null

func _ai_plays_furnished() -> void:
	var m := MapGen.generate({"style": MapGen.Style.STATION, "size": 2, "seed": 5, "furniture": 3,
			"civilians": 0, "units": 8})
	var taken := {}
	for side in [0, 1]:
		var placed := 0
		for c: Vector2i in m.zone_cells(side):
			if placed >= 8:
				break
			if m.get_feature(c) == "" and m.get_cover(c) == 0.0 and not m.get_space(c) and not taken.has(c):
				m.set_spawn(c, ["light_infantry", "machinegunner", "engineer", "sniper"][placed % 4], side)
				taken[c] = true
				placed += 1
	var st := m.build_state(77)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	var brains := {}
	for side in [0, 1]:
		st.roster.slot(side).kind = Roster.SlotKind.AI
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.intent_ready.connect(func(it: Intent) -> void: _pending = it)
		brains[side] = ai
	var actions := 0
	var on_furniture := 0
	var climbed := 0
	while st.turns.round_number <= 3 and actions < 3000:
		var ai: AIController = brains.get(st.active_player())
		_pending = null
		if ai != null:
			ai.begin_turn(st)
		var it: Intent = _pending if _pending != null else EndTurnIntent.new()
		var res := r.resolve(it)
		actions += 1
		if not res.ok and ai != null:
			ai.notify_intent_denied(st)
		for u: UnitInstance in st.all_units():
			if not u.is_alive() or u.is_drone or not st.grid.in_bounds(u.coord):
				continue
			var cell := st.grid.cell(u.coord)
			if Furniture.is_furniture(cell.feature_id):
				climbed += 1
				if cell.cover_height >= MCF.WALL_HEIGHT:
					on_furniture += 1
	ck(actions > 40, "Hard vs Hard plays three rounds on a densely furnished station (%d actions)" % actions)
	ck(on_furniture == 0, "and nobody ever stands inside a wall-height piece")
	print("     (soldiers stood on low furniture %d unit-steps)" % climbed)

# --- Экран боя ---------------------------------------------------------------------------

func _start_screen() -> void:
	var m := MapData.new(20, 12)
	for y in 12:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_cell(Vector2i(4, 4), MCF.FLOOR_NORMAL, 0.5, false, "chair")
	m.set_cell(Vector2i(2, 3), MCF.FLOOR_NORMAL, 1.0, false, "desk")
	m.set_spawn(Vector2i(3, 4), "light_infantry", 0)     # стул рядом, стол по диагонали рядом
	m.set_spawn(Vector2i(10, 8), "light_infantry", 0)    # рядом ничего
	m.set_spawn(Vector2i(18, 10), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _menu_texts() -> PackedStringArray:
	var out: PackedStringArray = []
	var stack: Array = [_main._menu]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_queued_for_deletion():
			continue
		if n is Button and (n as Button).visible:
			out.append((n as Button).text)
		stack.append_array(n.get_children())
	return out

func _screen_checks() -> void:
	var st: GameState = _main.state
	while st.active_player() != 0:
		_main._on_intent_ready(EndTurnIntent.new())
	var near := st.grid.cell(Vector2i(3, 4)).occupant
	var far := st.grid.cell(Vector2i(10, 8)).occupant
	_main._select(near)
	var t := _menu_texts()
	ck("Carry Furniture (1 AP)" in t, "next to a chair the menu offers Carry (%s)" % ", ".join(t))
	ck(t.has("Break Furniture (1 AP)"), "and Break Furniture at the right price")
	ck(t.has("Grab"), "the desk drags through Grab, like sandbags")
	_main._select(far)
	t = _menu_texts()
	var junk := false
	for s in t:
		junk = junk or s.contains("Furniture") or s.begins_with("Put Down")
	ck(not junk, "with nothing nearby there are no furniture buttons (%s)" % ", ".join(t))
	_main._select(near)
	_main._enter_furniture(_main.Mode.CARRY_FURN)
	ck(_main.item_cells == [Vector2i(4, 4)], "Carry highlights the chair")
	_main._handle_click(Vector2i(4, 4))
	ck(near.held_item_id == "chair", "a click picks it up")
	_main._select(near)
	t = _menu_texts()
	ck(t.has("Put Down Chair (free)") and not t.has("Carry Furniture (1 AP)"),
			"now the menu offers Put Down instead (%s)" % ", ".join(t))
	_main._enter_furniture(_main.Mode.PUT_FURN)
	ck(not _main.item_cells.has(Vector2i(2, 3)), "the desk's cell is not offered to put the chair on")
	_main._handle_click(Vector2i(3, 5))
	ck(st.grid.cell(Vector2i(3, 5)).feature_id == "chair" and near.held_item_id == "",
			"a click sets it down")
