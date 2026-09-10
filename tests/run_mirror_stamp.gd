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

var fails: PackedStringArray = []
var _scene: Node = null
var _checked := false

func _initialize() -> void:
	GameConfig.placement_mode = GameConfig.Placement.MIRRORED
	GameConfig.civilians_enabled = false
	_scene = load("res://scenes/Placement.tscn").instantiate()
	root.add_child(_scene)

## Сцена получает _ready не раньше первого кадра — проверяем в _process.
func _process(_delta: float) -> bool:
	if _checked:
		return true
	_checked = true
	_check()
	if fails.is_empty():
		print("mirror stamp: infantry and every vehicle cross to the mirrored side")
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

	p.active_side = guest
	p._stamp_formation()

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
