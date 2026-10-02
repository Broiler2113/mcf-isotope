extends RefCounted
## Армии для обучения (RL tactical env). Две вещи, обе — ради того, чтобы политика училась
## пользоваться ВСЕМИ родами войск, а не одним любимым составом:
##
##   shuffle() — на готовой карте часть родов пехоты подменяется другими. Подмена одна на
##               обе стороны (тот же род → тот же род), так что честность карты не страдает,
##               а состав каждой партии — новый.
##   populate() — на сгенерированной карте (MapGen) расставляет случайную армию в зоны
##               развёртывания. Состав ОДИН на обе стороны, места — свои у каждой.
##
## Всё от одного RandomNumberGenerator, засеянного сидом эпизода: партия воспроизводима.

## Роды, которые могут встретиться, с весами жребия. Мирных, дронов и технику здесь нет:
## дрон рождается со станции, техника ставится отдельно, мирные — не армия.
const POOL := {
	"light_infantry": 3.0, "heavy_infantry": 2.0, "machinegunner": 2.0, "sniper": 1.0,
	"anti_tank": 2.0, "engineer": 1.0, "flamethrower": 1.0, "assault": 2.0,
	"marksman": 1.0, "miner": 0.5, "sapper": 1.0, "shield_bearer": 1.0,
	"drone_operator": 1.0, "commander": 0.5,
}
## Доля родов, которые shuffle() подменяет.
const SHUFFLE_SHARE := 0.5
## Экипаж танка — столько пехотинцев встают вплотную к машине, чтобы _crew_vehicles
## env_server'а посадил их до начала записи.
const TANK_CREW := 3

static func _pick(rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for k: String in POOL:
		total += float(POOL[k])
	var x := rng.randf() * total
	for k: String in POOL:
		x -= float(POOL[k])
		if x <= 0.0:
			return k
	return "light_infantry"

## Подменить роды пехоты на готовой карте — одинаково для всех сторон.
static func shuffle(m: MapData, rng: RandomNumberGenerator) -> void:
	var swap := {}
	for k: String in POOL:
		if rng.randf() < SHUFFLE_SHARE:
			swap[k] = _pick(rng)
	for s: Dictionary in m.spawns:
		if MCF.is_player(int(s["owner"])) and swap.has(s["stats_id"]):
			s["stats_id"] = swap[s["stats_id"]]

## Свободна ли клетка карты под бойца: пол, не космос, без объекта и укрытия.
static func _free(m: MapData, c: Vector2i, taken: Dictionary) -> bool:
	return m.in_bounds(c) and not taken.has(c) and not m.get_space(c) \
			and m.get_feature(c) == "" and m.get_cover(c) <= 0.0

## Расставить по зонам одинаковый для всех сторон состав: `units` бойцов и до `tanks_max`
## танков (каждый со своим экипажем). Возвращает false, если зона не вместила армию.
static func populate(m: MapData, rng: RandomNumberGenerator, units: int, tanks_max: int) -> bool:
	var sides: Array[int] = [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]
	var comp: Array[String] = []
	for i in units:
		comp.append(_pick(rng))
	var tanks := 0
	for i in tanks_max:
		if rng.randf() < 0.45:
			tanks += 1
	m.spawns = m.spawns.filter(func(s: Dictionary) -> bool: return not MCF.is_player(int(s["owner"])))
	var taken := {}
	for s: Dictionary in m.spawns:
		taken[s["coord"]] = true
	var tsize := VehicleDB.size_of("tank")
	for side: int in sides:
		var zone: Array = m.zone_cells(side)
		if zone.is_empty():
			return false
		var in_zone := {}
		for c: Vector2i in zone:
			in_zone[c] = true
		# Танки первыми — им нужен целый квадрат; потом экипаж вплотную, потом остальные.
		var order := zone.duplicate()
		_shuffle(order, rng)
		var placed_tanks := 0
		for c: Vector2i in order:
			if placed_tanks >= tanks:
				break
			var foot: Array[Vector2i] = []
			var ok := true
			for dy in tsize.y:
				for dx in tsize.x:
					var f := c + Vector2i(dx, dy)
					if not in_zone.has(f) or not _free(m, f, taken):
						ok = false
					foot.append(f)
			if not ok:
				continue
			var crew: Array[Vector2i] = []
			for f: Vector2i in foot:
				for n: Vector2i in [f + Vector2i(1, 0), f + Vector2i(-1, 0), f + Vector2i(0, 1), f + Vector2i(0, -1)]:
					if not foot.has(n) and not crew.has(n) and _free(m, n, taken):
						crew.append(n)
			if crew.size() < TANK_CREW:
				continue
			for f: Vector2i in foot:
				taken[f] = true
			m.set_spawn(c, "tank", side)
			for i in TANK_CREW:
				taken[crew[i]] = true
				m.set_spawn(crew[i], "light_infantry", side)
			placed_tanks += 1
		var placed := 0
		for c: Vector2i in order:
			if placed >= comp.size():
				break
			if not _free(m, c, taken):
				continue
			taken[c] = true
			m.set_spawn(c, comp[placed], side)
			placed += 1
		if placed < comp.size() or placed_tanks < tanks:
			return false
	return true

static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
