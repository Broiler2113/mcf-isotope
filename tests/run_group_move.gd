extends SceneTree

## Групповой приказ (GroupMovePlanner): идут ВСЕ выделенные, каждый встаёт ровно туда, где
## его показал предпросмотр, строй не разваливается, тактический приказ ведёт в укрытие.
##
## Раньше раскладка шла по неподвижной доске: середина толпы и хвост колонны в коридоре не
## находили клеток и выпадали из приказа, а до далёкой цели группу сносило к краю карты.

var fails: PackedStringArray = []

func ck(c: bool, w: String) -> void:
	if not c:
		fails.append(w)

func _initialize() -> void:
	_blob_keeps_formation()
	_corridor_column_all_move()
	_tactical_takes_cover(false)
	_tactical_takes_cover(true)
	if fails.is_empty():
		print("group move: everyone moves, plan == result, formation holds, tactical takes cover")
		quit(0)
		return
	printerr("group move: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func _field(spawns: Array, feats: Dictionary = {}, fog := false) -> Dictionary:
	var m := MapData.new(40, 20)
	for y in 20:
		for x in 40:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, feats.get(Vector2i(x, y), ""))
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(7)
	var r := GameActionResolver.new(st)
	r.fog_enabled = fog
	var guard := 0
	while st.active_player() != MCF.Owner.PLAYER_1 and guard < 8:
		r.resolve(EndTurnIntent.new())
		guard += 1
	return {"s": st, "r": r}

## Отдать приказ всем своим и проверить, что встали ровно по плану. -> {id: откуда}
func _order(f: Dictionary, dest: Vector2i, tactical: bool, what: String) -> Dictionary:
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var ids: Array[int] = []
	var from := {}
	for u in st.living_units_of(MCF.Owner.PLAYER_1):
		ids.append(u.id)
		from[u.id] = u.coord
	var plan := GroupMovePlanner.plan(r, ids, dest, tactical)
	ck(plan[0].size() == ids.size(), "%s: %d of %d units planned to move" % [what, plan[0].size(), ids.size()])
	var res := r.resolve(GroupMoveIntent.new(plan[0], plan[1]))
	ck(res.ok, "%s: order refused: %s" % [what, res.reason])
	for i in plan[0].size():
		var u := st.get_unit(plan[0][i])
		ck(u.coord == plan[1][i], "%s: unit %d at %s, preview showed %s" % [what, u.id, u.coord, plan[1][i]])
	return from

func _blob_keeps_formation() -> void:
	var spawns: Array = [[Vector2i(37, 18), "light_infantry", MCF.Owner.PLAYER_2]]
	for y in [5, 6, 7]:
		for x in [3, 4, 5]:
			spawns.append([Vector2i(x, y), "light_infantry", MCF.Owner.PLAYER_1])
	var f := _field(spawns)
	var from := _order(f, Vector2i(30, 6), false, "blob")
	var st: GameState = f["s"]
	for id: int in from:
		var u := st.get_unit(id)
		ck(u.coord - from[id] == Vector2i(u.speed(), 0),
				"blob: %s went %s -> %s, not straight east in formation" % [u.stats.display_name, from[id], u.coord])

func _corridor_column_all_move() -> void:
	var spawns: Array = [[Vector2i(37, 18), "light_infantry", MCF.Owner.PLAYER_2]]
	for x in [3, 4, 5, 6, 7]:
		spawns.append([Vector2i(x, 10), "light_infantry", MCF.Owner.PLAYER_1])
	var walls := {}
	for x in range(2, 30):
		walls[Vector2i(x, 9)] = MCF.FEATURE_WALL
		walls[Vector2i(x, 11)] = MCF.FEATURE_WALL
	var f := _field(spawns, walls)
	var from := _order(f, Vector2i(25, 10), false, "corridor")
	var st: GameState = f["s"]
	for id: int in from:
		var u := st.get_unit(id)
		ck(u.coord.y == 10 and u.coord.x > from[id].x, "corridor: unit %d %s -> %s" % [id, from[id], u.coord])

## Мешки с песком в столбце x=20, враг к востоку (или не виден в тумане — тогда укрытие
## ищется со всех сторон): тактический приказ к (18, 6) ставит всех вплотную за мешки.
func _tactical_takes_cover(fog: bool) -> void:
	var spawns: Array = [[Vector2i(34, 6), "light_infantry", MCF.Owner.PLAYER_2]]
	for y in [4, 5, 6, 7, 8]:
		spawns.append([Vector2i(10, y), "light_infantry", MCF.Owner.PLAYER_1])
	var bags := {}
	for y in range(3, 10):
		bags[Vector2i(20, y)] = MCF.FEATURE_SANDBAGS
	var f := _field(spawns, bags, fog)
	var what := "tactical (fog %s)" % fog
	var from := _order(f, Vector2i(18, 6), true, what)
	var st: GameState = f["s"]
	for id: int in from:
		var u := st.get_unit(id)
		ck(u.coord.x == 19, "%s: unit %d stopped at %s, not behind the sandbags" % [what, id, u.coord])
