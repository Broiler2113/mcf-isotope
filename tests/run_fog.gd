extends SceneTree

## Туман войны: обзор одного бойца и танки.
##
##   1. Быстрый обзор (GameActionResolver._sweep_seen — проход по октантам с закрытыми
##      наклонами) даёт ТО ЖЕ множество и в том же порядке, что буквальный луч Брезенхэма в
##      каждую клетку окна (_ray_seen ниже — прежний код _seen_from слово в слово). Сверка на
##      сотнях случайных полей любой застройки и на настоящих картах генератора.
##   2. Танк закрывает обзор ТОЛЬКО врагу: противник за ним ничего не видит (и не может
##      выбрать цель), свои смотрят сквозь. Челнок и борг обзор не закрывают, обломки танка —
##      тоже; захваченный танк закрывает обзор уже прежнему хозяину; уехавший — никому.
##   3. Обзор на поле 250×250 с безграничной дальностью укладывается в десятки миллисекунд.
##   3а. Клетка, которую обход не отметил чувствительной, обзора не меняет: стена на ней
##      появляется или исчезает — видно ровно то же. По этому списку кеш выбрасывает
##      записи, и промах здесь значил бы устаревший туман.
##   4. Обзор стороны ведётся ПРИРАЩЕНИЯМИ (счётчики по клеткам, таблица стен правится по
##      журналу): после каждого хода настоящей партии со шлюзами он совпадает с обзором,
##      собранным с нуля, а память разведки накрывает всё, что было видно.

const TS = preload("res://tests/TestSupport.gd")
## Обзор одного бойца на 250×250 не дольше этого (с запасом на медленную машину; замер —
## ~25 мс против ~360 мс у прежнего луча).
const BIG_SIGHT_MS := 150.0

var fails: PackedStringArray = []

func _initialize() -> void:
	_sweep_matches_the_ray()
	_ranges_match_the_cells()
	_insensitive_cells_do_not_matter()
	_real_maps_match_the_ray()
	_tanks_block_enemy_sight_only()
	_big_map_sight_is_fast()
	_incremental_matches_fresh()
	_results_say_who_acted_and_where()
	if fails.is_empty():
		print("fog: sweep == ray on every board; tanks hide only from the enemy; 250×250 sight is fast; incremental == fresh; results name their actor")
		quit(0)
		return
	printerr("fog: %d failure(s)" % fails.size())
	for f in fails.slice(0, 30):
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

## Прежний обход по клеткам (до перехода на полосы строк) — эталон для нынешнего
## GameActionResolver._sweep: оба списка, видимые и чувствительные клетки, обязаны
## совпасть. Сам он сверен с буквальным лучом ниже.
static func _sweep_reference(ux: int, uy: int, r: int, blk: PackedByteArray, gw: int,
		gh: int) -> Array:
	var vis := PackedByteArray()
	vis.resize(gw * gh)
	var origin := uy * gw + ux
	vis[origin] = 1
	# Закрытые наклоны (lo, hi] — четыре параллельных массива: числители и знаменатели.
	var lo_n := PackedInt32Array()
	var lo_d := PackedInt32Array()
	var hi_n := PackedInt32Array()
	var hi_d := PackedInt32Array()
	var reach := 0   # дальше этого столбца ни один октант не дошёл — видимое внутри
	for oct in 8:
		var xmajor := oct < 4
		var sx := -1 if (oct & 1) != 0 else 1
		var sy := -1 if (oct & 2) != 0 else 1
		var major_step := sx
		var minor_step := sy * gw
		var major_room := (gw - 1 - ux) if sx > 0 else ux
		var minor_room := (gh - 1 - uy) if sy > 0 else uy
		if not xmajor:
			major_step = sy * gw
			minor_step = sx
			major_room = (gh - 1 - uy) if sy > 0 else uy
			minor_room = (gw - 1 - ux) if sx > 0 else ux
		# Ось (b == 0) общая у двух соседних октантов — её считает «положительный».
		var b0 := 1 if ((sy < 0) if xmajor else (sx < 0)) else 0
		lo_n.clear()
		lo_d.clear()
		hi_n.clear()
		hi_d.clear()
		var amax := mini(r, major_room)
		var a := 1
		while a <= amax:
			reach = maxi(reach, a)
			var col := origin + major_step * a
			# Цели столбца: в октанте |dy| > |dx| строго — диагональ досталась соседу.
			var bmax := mini(a if xmajor else a - 1, minor_room)
			var n := lo_n.size()
			var k := 0
			var b := b0
			while b <= bmax:
				while k < n and hi_n[k] * a < b * hi_d[k]:
					k += 1
				if k >= n or lo_n[k] * a >= b * lo_d[k]:
					var t := col + minor_step * b
					vis[t] = vis[t] | 1
				b += 1
			# Чувствительные клетки столбца (бит 2): промежуток клетки не внутри одного
			# закрытого — закрытые слиты, так что «в тени целиком» и есть «внутри одного».
			var jmax := mini(a, minor_room)
			var a2 := 2 * a
			var ks := 0
			var js := 0
			var sc := col
			while js <= jmax:
				var hn := 2 * js + 1
				while ks < n and hi_n[ks] * a2 < hn * hi_d[ks]:
					ks += 1
				if ks >= n or lo_n[ks] * a2 > (hn - 2) * lo_d[ks]:
					vis[sc] = vis[sc] | 2
				js += 1
				sc += minor_step
			# Стены столбца закрывают наклоны для всего, что дальше. Все — и те, что сами
			# в тени: край чужой тени бывает шире своей.
			var j := 0
			var cell := col
			while j <= jmax:
				if blk[cell] != 0:
					# Новый промежуток ((2j−1)/2a, (2j+1)/2a] вливается в список: всё, что с ним
					# пересекается или смыкается, сливается в один.
					var nl := 2 * j - 1
					var dl := 2 * a
					var nh := 2 * j + 1
					var dh := 2 * a
					var m := lo_n.size()
					var p := 0
					while p < m and hi_n[p] * dl < nl * hi_d[p]:
						p += 1
					var q := p
					while q < m and lo_n[q] * dh <= nh * lo_d[q]:
						if lo_n[q] * dl < nl * lo_d[q]:
							nl = lo_n[q]
							dl = lo_d[q]
						if hi_n[q] * dh > nh * hi_d[q]:
							nh = hi_n[q]
							dh = hi_d[q]
						q += 1
					if q == p:
						lo_n.insert(p, nl)
						lo_d.insert(p, dl)
						hi_n.insert(p, nh)
						hi_d.insert(p, dh)
					else:
						lo_n[p] = nl
						lo_d[p] = dl
						hi_n[p] = nh
						hi_d[p] = dh
						for t in q - p - 1:
							lo_n.remove_at(p + 1)
							lo_d.remove_at(p + 1)
							hi_n.remove_at(p + 1)
							hi_d.remove_at(p + 1)
				j += 1
				cell += minor_step
			# Закрыто всё от наклона 0 до 1 — дальше в этом октанте не видно ничего.
			if lo_n.size() == 1 and lo_n[0] < 0 and hi_n[0] >= hi_d[0]:
				break
			a += 1
	# Выписываем по строкам окна — но только в пределах того, докуда дошёл обход: в тесной
	# комнате это десяток клеток, а не всё поле 250×250.
	var out := PackedInt32Array()
	var sens := PackedInt32Array()
	var rr := mini(r, reach)
	var y0 := maxi(0, uy - rr)
	var y1 := mini(gh - 1, uy + rr)
	var x0 := maxi(0, ux - rr)
	var x1 := mini(gw - 1, ux + rr)
	var y := y0
	while y <= y1:
		var i := y * gw + x0
		var end := y * gw + x1
		while i <= end:
			var v := vis[i]
			if v != 0:
				if v & 1:
					out.append(i)
				if v & 2:
					sens.append(i)
			i += 1
		y += 1
	return [out, sens]

## Прежний _seen_from дословно: луч Брезенхэма в каждую клетку окна, концы не в счёт.
static func _ray_seen(ux: int, uy: int, r: int, blk: PackedByteArray, gw: int, gh: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for dy in range(-r, r + 1):
		var cy := uy + dy
		if cy < 0 or cy >= gh:
			continue
		for dx in range(-r, r + 1):
			var cx := ux + dx
			if cx < 0 or cx >= gw:
				continue
			var adx := absi(cx - ux)
			var ady := absi(cy - uy)
			var sx := 1 if ux < cx else -1
			var sy := 1 if uy < cy else -1
			var err := adx - ady
			var px := ux
			var py := uy
			var blocked := false
			while px != cx or py != cy:
				var e2 := 2 * err
				if e2 > -ady:
					err -= ady
					px += sx
				if e2 < adx:
					err += adx
					py += sy
				if px == cx and py == cy:
					break
				if blk[py * gw + px] != 0:
					blocked = true
					break
			if not blocked:
				out.append(cy * gw + cx)
	return out

## Нынешний обход полосами строк == прежний обход по клеткам — оба списка.
func _ranges_match_the_cells() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 918273
	var bad := 0
	for t in 800:
		var gw := rng.randi_range(1, 45)
		var gh := rng.randi_range(1, 45)
		var dens: float = [0.0, 0.02, 0.08, 0.2, 0.45, 0.75][rng.randi_range(0, 5)]
		var blk := PackedByteArray()
		blk.resize(gw * gh)
		for i in gw * gh:
			blk[i] = 1 if rng.randf() < dens else 0
		if rng.randf() < 0.3:
			var x := rng.randi_range(0, gw - 1)
			for y in gh:
				blk[y * gw + x] = 0 if rng.randf() < 0.15 else 1
		var ux := rng.randi_range(0, gw - 1)
		var uy := rng.randi_range(0, gh - 1)
		var r: int = [1, 2, 3, 5, 8, 13, 1000][rng.randi_range(0, 6)]
		r = mini(r, maxi(gw, gh))
		var want: Array = _sweep_reference(ux, uy, r, blk, gw, gh)
		var got: Array = GameActionResolver._sweep(ux, uy, r, blk, gw, gh)
		if want[0] != got[0] or want[1] != got[1]:
			bad += 1
			if bad <= 3:
				ck(false, "board %dx%d density %.2f from (%d,%d) r=%d: cells %d/%d visible, %d/%d sensitive" % [
						gw, gh, dens, ux, uy, r, (want[0] as PackedInt32Array).size(),
						(got[0] as PackedInt32Array).size(), (want[1] as PackedInt32Array).size(),
						(got[1] as PackedInt32Array).size()])
	ck(bad == 0, "the row-range sweep matches the cell sweep on all 800 boards (%d differ)" % bad)

func _sweep_matches_the_ray() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260930
	var bad := 0
	for t in 600:
		var gw := rng.randi_range(1, 40)
		var gh := rng.randi_range(1, 40)
		var dens: float = [0.0, 0.03, 0.1, 0.25, 0.45, 0.7][rng.randi_range(0, 5)]
		var blk := PackedByteArray()
		blk.resize(gw * gh)
		for i in gw * gh:
			blk[i] = 1 if rng.randf() < dens else 0
		# Иногда — длинные стены с проёмами: то, на чём ломаются упрощённые тени.
		if rng.randf() < 0.3:
			var x := rng.randi_range(0, gw - 1)
			for y in gh:
				blk[y * gw + x] = 0 if rng.randf() < 0.15 else 1
		var ux := rng.randi_range(0, gw - 1)
		var uy := rng.randi_range(0, gh - 1)
		var r: int = [1, 2, 3, 5, 8, 13, 1000][rng.randi_range(0, 6)]
		r = mini(r, maxi(gw, gh))
		var want := _ray_seen(ux, uy, r, blk, gw, gh)
		var got := GameActionResolver._sweep_seen(ux, uy, r, blk, gw, gh)
		if want != got:
			bad += 1
			if bad <= 3:
				ck(false, "board %dx%d density %.2f from (%d,%d) r=%d: ray sees %d cells, sweep %d" % [
						gw, gh, dens, ux, uy, r, want.size(), got.size()])
	ck(bad == 0, "the sweep matches the ray on all 600 random boards (%d differ)" % bad)

func _insensitive_cells_do_not_matter() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var flips := 0
	var bad := 0
	var saved := 0
	for t in 500:
		var gw := rng.randi_range(2, 36)
		var gh := rng.randi_range(2, 36)
		var dens: float = [0.02, 0.1, 0.25, 0.45][rng.randi_range(0, 3)]
		var blk := PackedByteArray()
		blk.resize(gw * gh)
		for i in gw * gh:
			blk[i] = 1 if rng.randf() < dens else 0
		var ux := rng.randi_range(0, gw - 1)
		var uy := rng.randi_range(0, gh - 1)
		var r: int = [2, 5, 9, 1000][rng.randi_range(0, 3)]
		r = mini(r, maxi(gw, gh))
		var res: Array = GameActionResolver._sweep(ux, uy, r, blk, gw, gh)
		var seen: PackedInt32Array = res[0]
		var sens: PackedInt32Array = res[1]
		for k in 12:
			var c := rng.randi_range(0, gw * gh - 1)
			var at := sens.bsearch(c)
			if at < sens.size() and sens[at] == c:
				continue
			blk[c] = 1 - blk[c]
			var again := GameActionResolver._sweep_seen(ux, uy, r, blk, gw, gh)
			blk[c] = 1 - blk[c]
			flips += 1
			if again != seen:
				bad += 1
		saved += gw * gh - sens.size()
	ck(flips > 1000, "the check flipped enough unmarked cells (%d)" % flips)
	ck(bad == 0, "flipping a cell the sweep did not mark never changes the view (%d did)" % bad)
	ck(saved > 0, "the sweep leaves some cells unmarked at all (%d)" % saved)

## Настоящие карты генератора и настоящий _seen_from: рельеф плюс вражеские танки.
func _real_maps_match_the_ray() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for style in [MapGen.Style.STATION, MapGen.Style.TOWN, MapGen.Style.FIELD]:
		var m := MapGen.generate({"style": style, "size": 1, "seed": 31 + style, "civilians": false})
		var st := m.build_state(3)
		var r := GameActionResolver.new(st)
		# Пара танков стороны 1 на чистом полу — для стороны 0 это стены.
		var placed := 0
		for i in 400:
			if placed >= 2:
				break
			var c := Vector2i(rng.randi_range(1, m.width - 4), rng.randi_range(1, m.height - 4))
			var free := true
			for dy in 3:
				for dx in 3:
					var p := c + Vector2i(dx, dy)
					free = free and not st.grid.cell(p).is_wall() and not st.grid.cell(p).is_space \
							and st.grid.vehicle_at(p) == -1 and st.grid.cell(p).occupant == null
			if free:
				st.spawn_vehicle("tank", c, 1)
				placed += 1
		var tank_cells := {}
		for veh: Vehicle in st.all_vehicles():
			for fc: Vector2i in veh.footprint():
				tank_cells[fc.y * m.width + fc.x] = true
		var bad := 0
		for k in 30:
			var from := Vector2i(rng.randi_range(0, m.width - 1), rng.randi_range(0, m.height - 1))
			if st.grid.vehicle_at(from) != -1:
				continue
			for side in [0, 1]:
				var got := r._seen_from(from, MCF.SIGHT_UNLIMITED, side)
				var blk: PackedByteArray = GameActionResolver._blockers.duplicate()
				if side == 0:
					for i: int in tank_cells:
						blk[i] = 1
				var want := _ray_seen(from.x, from.y, maxi(m.width, m.height), blk, m.width, m.height)
				if got != want:
					bad += 1
		ck(bad == 0, "%s: _seen_from matches the ray (walls + enemy tanks) — %d viewer(s) differ" % [
				MapGen.STYLE_NAMES[style], bad])

func _tanks_block_enemy_sight_only() -> void:
	var m := MapData.new(24, 11)
	for y in 11:
		for x in 24:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(20, 5), "light_infantry", 1)
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	var a: UnitInstance = null
	var b: UnitInstance = null
	for u: UnitInstance in st.all_units():
		if u.owner == 0:
			a = u
		else:
			b = u
	var behind := Vector2i(20, 5)
	var here := Vector2i(2, 5)
	ck(r.team_visible_coords(0).has(behind), "on open ground side 0 sees the far rifleman")

	var tank: Vehicle = st.spawn_vehicle("tank", Vector2i(9, 4), 1)   # клетки 9..11 × 4..6
	ck(not r.team_visible_coords(0).has(behind), "an enemy tank hides the rifleman behind it")
	ck(r.team_visible_coords(0).has(Vector2i(9, 5)), "…but the tank itself is in plain sight")
	ck(r.team_visible_coords(1).has(here), "the tank's own side sees straight through it")
	ck(r.can_shoot(a, b) == "Target not visible", "the hidden rifleman can't be targeted (%s)" % r.can_shoot(a, b))
	ck(r._vision_blocked(here, behind, 0), "the single-line check agrees: blocked for the enemy")
	ck(not r._vision_blocked(here, behind, 1), "…and open for the tank's side")
	ck(not r._vision_blocked(here, behind), "…and for terrain-only questions")

	tank.owner = 0   # захвачен
	ck(r.team_visible_coords(0).has(behind), "a captured tank no longer hides anything from its new owner")
	ck(not r.team_visible_coords(1).has(here), "…and now hides the other way")
	tank.owner = 1

	tank.wrecked = true
	ck(r.team_visible_coords(0).has(behind), "a wreck blocks no one — it is not a tank any more")
	tank.wrecked = false
	ck(not r.team_visible_coords(0).has(behind), "repaired back into a tank, it hides again")

	st.grid.clear_vehicle_footprint(tank.id, tank.footprint())
	tank.origin = Vector2i(9, 0)   # отъехал с линии
	st.grid.set_vehicle_footprint(tank.id, tank.footprint())
	ck(r.team_visible_coords(0).has(behind), "once the tank drives off the line, the rifleman is visible")
	st.grid.clear_vehicle_footprint(tank.id, tank.footprint())
	st.vehicles.erase(tank.id)

	for kind: String in ["shuttle", "borg"]:
		var veh: Vehicle = st.spawn_vehicle(kind, Vector2i(10, 5) if kind == "borg" else Vector2i(10, 4), 1)
		ck(r.team_visible_coords(0).has(behind), "an enemy %s does not block sight" % kind)
		st.grid.clear_vehicle_footprint(veh.id, veh.footprint())
		st.vehicles.erase(veh.id)
		UnitInstance.vision_epoch += 1

func _big_map_sight_is_fast() -> void:
	var m := MapGen.generate({"style": MapGen.Style.FIELD, "size": 5, "seed": 21, "civilians": false})
	var st := m.build_state(3)
	var r := GameActionResolver.new(st)
	var cells := m.zone_cells(0)
	var total := 0.0
	for k in 5:
		GameActionResolver._clear_seen()
		var t0 := Time.get_ticks_usec()
		r._seen_from(cells[k * cells.size() / 5], MCF.SIGHT_UNLIMITED, 0)
		total += (Time.get_ticks_usec() - t0) / 1000.0
	ck(total / 5.0 < BIG_SIGHT_MS, "one unit's sight on 250×250 takes %.1f ms (budget %.0f)" % [
			total / 5.0, BIG_SIGHT_MS])
	print("fog: unlimited sight on a 250×250 field — %.1f ms per unit" % (total / 5.0))

var _pending: Intent = null

## Партия с дверями-шлюзами: шаги открывают и закрывают створки (обзор меняется), бойцы
## гибнут и садятся в машины. После каждого действия обзор каждой стороны сверяется с
## обзором свежего резолвера при сброшенных кешах.
func _incremental_matches_fresh() -> void:
	_incremental_game(false)
	_incremental_game(true)

func _incremental_game(tanks: bool) -> void:
	var m := MapGen.generate({"style": MapGen.Style.TOWN, "size": 1, "seed": 8, "civilians": 2})
	var squad := ["light_infantry", "engineer", "sniper", "drone_operator", "flamethrower"]
	for side in [0, 1]:
		var cells := m.zone_cells(side)
		for k in squad.size():
			m.set_spawn(cells[(k * 11) % cells.size()], squad[k], side)
	var st := m.build_state(4)
	# По танку на сторону: переезд вражеского танка меняет обзор, и кеш должен это видеть.
	for side in ([0, 1] if tanks else []):
		for c: Vector2i in m.zone_cells(side):
			var free := true
			for dy in 3:
				for dx in 3:
					var cc := st.grid.cell(c + Vector2i(dx, dy))
					free = free and cc != null and cc.is_empty() and not cc.is_space \
							and cc.vehicle_id == -1 and cc.feature_id == ""
			if free:
				st.spawn_vehicle("tank", c, side)
				break
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	r.update_airlocks()
	r.play_civilian_slots()
	var brains := {}
	for side in [0, 1]:
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.intent_ready.connect(func(i: Intent) -> void: _pending = i)
		brains[side] = ai
	var seen_ever := {0: {}, 1: {}}
	var bad := 0
	var toggles := 0
	var tank_moves := 0
	for step in 160:
		var side: int = st.active_player()
		if not brains.has(side):
			break
		_pending = null
		brains[side].begin_turn(st)
		var vv := GridCell.vision_version
		tank_moves += 1 if _pending is VehicleMoveIntent else 0
		r.resolve(_pending if _pending != null else EndTurnIntent.new())
		toggles += 1 if GridCell.vision_version != vv else 0
		for s2 in [0, 1]:
			var got: Dictionary = r.team_visible_coords(s2)
			var want := _fresh_sight(st, s2)
			seen_ever[s2].merge(want)
			if got.size() != want.size() or not got.keys().all(func(c): return want.has(c)):
				bad += 1
			var mem: Dictionary = r.explored.get(s2, {})
			if not seen_ever[s2].keys().all(func(c): return mem.has(c)):
				bad += 1
	if tanks:
		ck(tank_moves > 0, "the tanks moved at least once (%d)" % tank_moves)
	else:
		ck(toggles > 0, "the game opened or closed at least one airlock (%d)" % toggles)
	ck(bad == 0, "incremental sight == fresh sight after every action%s (%d mismatches)" % [
			" with tanks" if tanks else "", bad])

## Обзор стороны, собранный с нуля свежим резолвером — при пустом общем кеше обзора. Сам
## кеш партии при этом откладывается и возвращается на место: иначе его записи жили бы не
## дольше одного хода, и выборочная чистка по чувствительным клеткам осталась бы без
## проверки.
func _fresh_sight(st: GameState, side: int) -> Dictionary:
	var R := GameActionResolver
	var saved := [R._seen_cache, R._seen_sens, R._seen_cells, R._seen_version, R._seen_grid,
			R._blockers, R._tank_masks]
	R._seen_cache = {}
	R._seen_sens = {}
	R._seen_cells = 0
	R._seen_grid = 0
	R._blockers = PackedByteArray()
	R._tank_masks = {}
	var fresh := GameActionResolver.new(st)
	fresh.fog_mode = MCF.Fog.STANDARD
	var want: Dictionary = fresh.team_visible_coords(side)
	R._seen_cache = saved[0]
	R._seen_sens = saved[1]
	R._seen_cells = saved[2]
	R._seen_version = saved[3]
	R._seen_grid = saved[4]
	R._blockers = saved[5]
	R._tank_masks = saved[6]
	return want

## 5. Каждый итог действия знает, ЧЕЙ он и откуда куда. На правила это не влияет (как fx
##    и visual_hold, по сети не едет) — на этом экран боя решает, печатать ли строку в
##    лог: ход врага, которого не видно, рассказывать текстом нельзя, иначе лог выдаёт
##    ровно то, что прячет туман.
func _results_say_who_acted_and_where() -> void:
	var m := MapData.new(20, 10)
	for y in 10:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(3, 3), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(16, 7), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(31)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	r.fog_enabled = false
	while st.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var u: UnitInstance = st.grid.cell(Vector2i(3, 3)).occupant
	var res := r.resolve(MoveIntent.new(u.id, Vector2i(4, 3)))
	ck(res.ok, "the move resolves: %s" % res.reason)
	ck(res.actor_owner == MCF.Owner.PLAYER_1, "the result names its side (%d)" % res.actor_owner)
	ck(res.actor_from == Vector2i(3, 3), "and where the mover started (%s)" % str(res.actor_from))
	ck(res.actor_to == Vector2i(4, 3), "and where it ended (%s)" % str(res.actor_to))
	# Конец хода автора не имеет — такие строки показываются всегда.
	var done := r.resolve(EndTurnIntent.new())
	ck(done.actor_owner == -1, "end of turn belongs to nobody (%d)" % done.actor_owner)
