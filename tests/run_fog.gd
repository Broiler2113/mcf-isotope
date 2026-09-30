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

const TS = preload("res://tests/TestSupport.gd")
## Обзор одного бойца на 250×250 не дольше этого (с запасом на медленную машину; замер —
## ~25 мс против ~360 мс у прежнего луча).
const BIG_SIGHT_MS := 150.0

var fails: PackedStringArray = []

func _initialize() -> void:
	_sweep_matches_the_ray()
	_real_maps_match_the_ray()
	_tanks_block_enemy_sight_only()
	_big_map_sight_is_fast()
	if fails.is_empty():
		print("fog: sweep == ray on every board; tanks hide only from the enemy; 250×250 sight is fast")
		quit(0)
		return
	printerr("fog: %d failure(s)" % fails.size())
	for f in fails.slice(0, 30):
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

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
		GameActionResolver._seen_cache.clear()
		var t0 := Time.get_ticks_usec()
		r._seen_from(cells[k * cells.size() / 5], MCF.SIGHT_UNLIMITED, 0)
		total += (Time.get_ticks_usec() - t0) / 1000.0
	ck(total / 5.0 < BIG_SIGHT_MS, "one unit's sight on 250×250 takes %.1f ms (budget %.0f)" % [
			total / 5.0, BIG_SIGHT_MS])
	print("fog: unlimited sight on a 250×250 field — %.1f ms per unit" % (total / 5.0))
