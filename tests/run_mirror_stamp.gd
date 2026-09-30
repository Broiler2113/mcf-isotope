extends SceneTree

## Зеркальная расстановка обязана переносить ТЕХНИКУ (item 8).
##
## Игрок: «in mirrored game mode, when I stamp a formation, tanks don't transfer, and
## shuttles too sometimes». «Sometimes» здесь — самая ценная часть отчёта: она и указала
## на след, а не на технику как таковую.
##
## Координата в записи расстановки — это ЛЕВЫЙ ВЕРХНИЙ угол следа, растущего вправо-вниз.
## Отражение через центр карты переносило этот угол туда, где должен оказаться
## ПРОТИВОПОЛОЖНЫЙ, поэтому копия съезжала на (размер−1) по обеим осям. У пехоты след
## 1×1 и съезд нулевой — оттого баг годами не замечали. Танк 3×3 уезжал на две клетки,
## вылезал из зоны высадки и молча не ставился совсем; челнок 2×2 — на одну, и попадал
## или не попадал в зависимости от карты.
##
## Прогон строит НАСТОЯЩУЮ сцену расстановки и штампует формацию, как это делает игрок.
##
## И второе: «in symmetrical placement every player gets the same units — rn if spawns are
## not directly in front of each other, mirrored placement doesn't work». Прежний перенос
## поворачивал формацию на 180° вокруг центра карты, и копии улетали мимо зон, стоящих
## слева-справа на одной высоте, по четвертям или втроём. Здесь — именно такие карты
## генератора: у каждой стороны та же армия, целиком в своей зоне, а на зеркальной карте —
## ровно в отражённых клетках.

var fails: PackedStringArray = []
var _scene: Node = null
var _stage := 0
## Сценарии после исходного (пустая арена): [настройки генератора, сколько игроков,
## ждать ли точного отражения].
const MAPS := [
	[{"style": 1, "size": 2, "seed": 404, "zones": 2, "symmetric": true, "civilians": 0}, 2, true],
	[{"style": 1, "size": 2, "seed": 505, "zones": 4, "symmetric": true, "civilians": 0}, 4, true],
	[{"style": 2, "size": 2, "seed": 606, "zones": 3, "symmetric": true, "civilians": 0}, 3, false],
	[{"style": 1, "size": 2, "seed": 707, "zones": 3, "civilians": 0}, 3, false],
]

func _initialize() -> void:
	GameConfig.placement_mode = GameConfig.Placement.MIRRORED
	GameConfig.civilians_enabled = false
	_open()

func _open() -> void:
	if _stage > 0:
		var spec: Array = MAPS[_stage - 1]
		NetHandoff.lobby_map = MapGen.generate(spec[0])
		var r := Roster.new()
		for i in int(spec[1]):
			r.add_slot(Roster.SlotKind.HUMAN)
		GameConfig.roster = r
	_scene = load("res://scenes/Placement.tscn").instantiate()
	root.add_child(_scene)

## Сцена получает _ready не раньше первого кадра — проверяем в _process.
func _process(_delta: float) -> bool:
	if _stage == 0:
		_check()
	else:
		var spec: Array = MAPS[_stage - 1]
		_check_same_army(spec[0], bool(spec[2]))
	_scene.queue_free()
	_stage += 1
	if _stage <= MAPS.size():
		_open()
		return false
	if fails.is_empty():
		print("mirror stamp: every vehicle crosses; on mirrored, quartered and 3-player maps every side gets the same army")
		quit(0)
		return true
	printerr("mirror stamp: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)
	return true

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _check() -> void:
	var p: Node = _scene
	var sides: Array = p.roster.player_ids()
	if sides.size() < 2:
		fails.append("the placement scene has fewer than two sides")
		return
	var host: int = sides[0]
	var guest: int = sides[1]

	# По одному предмету каждого вида: пехотинец и вся техника из справочника.
	var wanted: Array = ["light_infantry"]
	wanted.append_array(VehicleDB.ids())
	var staged: Array = []
	for id: String in wanted:
		var spot := _room_for(p, id, host)
		if spot == Vector2i(-1, -1):
			fails.append("%s does not fit in the host zone — fixture is broken" % id)
			continue
		p.placed.append({"stats_id": id, "owner": host, "coord": spot, "paid_by": host})
		staged.append(id)
	ck(staged.size() == wanted.size(), "every kind was staged on the host side")

	# Зеркало живёт само (batch 13 #13): любое изменение отряда хоста пересобирает
	# отражения во все остальные зоны — штамповать вручную больше нечего.
	p._placement_changed()

	for id: String in staged:
		var copy: Dictionary = {}
		for rec: Dictionary in p.placed:
			if int(rec["owner"]) == guest and String(rec["stats_id"]) == id:
				copy = rec
				break
		ck(not copy.is_empty(), "%s crosses to the mirrored side" % id)
		if copy.is_empty():
			continue
		# Копия обязана стоять ЦЕЛИКОМ в зоне гостя. Спрашивать _footprint_placeable
		# уже нельзя — клетки заняты ею же самой; проверяем именно зону, ведь ровно на
		# ней прежняя формула и спотыкалась.
		var outside := 0
		for c: Vector2i in p._footprint(id, copy["coord"]):
			if not p.map.in_bounds(c) or not p._in_zone(c, guest):
				outside += 1
		ck(outside == 0,
				"%s lands fully inside the guest's deployment zone (%d cells outside)"
				% [id, outside])
		# Отражение на 180° разворачивает и фронт машины.
		if VehicleDB.is_vehicle(id) \
				and bool(VehicleDB.get_vehicle(id).get("has_facing", false)):
			ck(copy.get("facing", Vector2i.ZERO) != Vector2i.ZERO,
					"%s keeps a facing after the stamp" % id)

## Первая клетка в зоне хоста, куда предмет целиком помещается.
func _room_for(p: Node, id: String, host: int) -> Vector2i:
	var size: Vector2i = VehicleDB.size_of(id) if VehicleDB.is_vehicle(id) else Vector2i.ONE
	for x in range(0, int(p.map.width) - size.x):
		for y in range(0, int(p.map.height) - size.y):
			var c := Vector2i(x, y)
			if p._footprint_placeable(id, c, host) and p._placed_at(c) == -1:
				return c
	return Vector2i(-1, -1)

## Каждая сторона получает ту же армию, что хост: тот же состав, целиком в своей зоне. На
## зеркальной карте — ещё и в точности в отражённых клетках (симметрия самой карты).
func _check_same_army(spec: Dictionary, exact: bool) -> void:
	var p: Node = _scene
	var tag := "%s %s" % [MapGen.STYLE_NAMES[spec["style"]], spec]
	var sides: Array = p.roster.player_ids()
	var host: int = sides[0]
	var army: Array = ["light_infantry", "light_infantry", "heavy_infantry", "machinegunner",
			"sniper", "light_infantry", "tank", "shuttle"]
	var want := {}
	for id: String in army:
		var spot := _room_for(p, id, host)
		if spot == Vector2i(-1, -1):
			fails.append(tag + ": %s does not fit in the host zone — fixture is broken" % id)
			continue
		p.placed.append({"stats_id": id, "owner": host, "coord": spot, "paid_by": host})
		want[id] = int(want.get(id, 0)) + 1
	p._placement_changed()
	var w: int = p.map.width
	var h: int = p.map.height
	for k in range(1, sides.size()):
		var side: int = sides[k]
		var got := {}
		for rec: Dictionary in p.placed:
			if int(rec["owner"]) != side:
				continue
			var id := String(rec["stats_id"])
			got[id] = int(got.get(id, 0)) + 1
			for c: Vector2i in p._footprint(id, rec["coord"]):
				if not p._in_zone(c, side):
					fails.append(tag + ": side %d's %s at %s sticks out of its zone" % [side, id, rec["coord"]])
					break
		ck(got == want, tag + ": side %d gets the host's army %s, got %s" % [side, want, got])
		if not exact:
			continue
		# Какое отражение переводит зону хоста в зону этой стороны: зоны генератора
		# пронумерованы так, что бит 1 номера — зеркало по ширине, бит 2 — по высоте.
		var fx := (k & 1) != 0
		var fy := (k & 2) != 0
		for rec: Dictionary in p.placed:
			if int(rec["owner"]) != host:
				continue
			var id := String(rec["stats_id"])
			var size: Vector2i = VehicleDB.size_of(id) if VehicleDB.is_vehicle(id) else Vector2i.ONE
			var c: Vector2i = rec["coord"]
			var expect := Vector2i(w - c.x - size.x if fx else c.x, h - c.y - size.y if fy else c.y)
			var found := false
			for other: Dictionary in p.placed:
				if int(other["owner"]) == side and String(other["stats_id"]) == id and other["coord"] == expect:
					found = true
					if id == "tank":
						var f: Vector2i = p._placed_facing(rec)
						var ef := Vector2i(-f.x if fx else f.x, -f.y if fy else f.y)
						ck(other.get("facing", Vector2i.ZERO) == ef,
								tag + ": side %d's tank faces %s, the mirror of %s" % [side, other.get("facing"), f])
			ck(found, tag + ": side %d has the host's %s at the mirrored cell %s" % [side, id, expect])
