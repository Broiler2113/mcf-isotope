extends SceneTree

## Три правила боя, каждое — по отчёту игрока (issues 2, 3, 7/8).
##
## 1. БОЕЦ ВНЕ ПОЛЯ НЕ ЛОМАЕТ ЛУЧИ. У сидящего в машине координата вынесена за карту
##    (OFFBOARD, −9999). Проверки «на одной ли прямой» такую точку пропускают — от
##    (−9999, −9999) диагональ накрывает пол-карты, — и ходок по лучу шагал в сетку с
##    отрицательным адресом: «Out of bounds get index '-509898' (on base:
##    Array[GridCell])» на ходу ИИ. Здесь проверяется, что КАЖДЫЙ вход резолвера,
##    считающий линию, отвечает на такую точку безопасно.
##
## 2. ПРОТИВОТАНКИСТ ИИ НЕ ПОДРЫВАЕТ СЕБЯ. Его выстрел — взрыв радиусом 1 вокруг точки
##    падения, а промах кладёт заряд НЕДОЛЁТОМ (#7). По цели вплотную это гарантированная
##    смерть стрелка; ИИ брал такую цель как любую другую.
##
## 3. КОСМЕТИКА СЧИТАЕТ ВЫСТРЕЛЫ. Гильза на каждый ушедший патрон, и повторная очередь
##    С ТОЙ ЖЕ КЛЕТКИ кладёт НОВЫЕ гильзы, а не те же самые поверх старых. Плюс каждая
##    атака оставляет дорожку «кто в кого» — по ней игрок читает чужой ход.

const TS = preload("res://tests/TestSupport.gd")
const OFFBOARD := Vector2i(-9999, -9999)

var fails: PackedStringArray = []

func _initialize() -> void:
	_offboard_lines()
	_anti_tank_never_blasts_itself()
	_fx_counts_every_shot()

	if fails.is_empty():
		print("combat safety: off-board lines, anti-tank self-blast and shot cosmetics all hold")
		quit(0)
		return
	printerr("combat safety: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

# --- 1. Линии от точки вне поля (issue 2) -------------------------------------------
func _offboard_lines() -> void:
	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	# Диагональ от OFFBOARD проходит через клетки, у которых x == y: именно так игрок и
	# поймал падение. Берём такую цель, чтобы луч заведомо «начинался» за краем карты.
	var on_board := Vector2i(9, 9)
	ck(not r.los_blocked(OFFBOARD, on_board), "a line of sight from off the board is empty")
	ck(not r.los_blocked(on_board, OFFBOARD), "a line of sight to off the board is empty")
	ck(r.first_unit_on_line(OFFBOARD, on_board) == null,
			"nobody stands on a line that starts off the board")
	ck(r.first_unit_on_line(on_board, OFFBOARD) == null,
			"nobody stands on a line that ends off the board")

	# Тот же случай в живом виде: боец посажен в машину, и его спрашивают как стрелка.
	var passenger: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.is_alive() and u.owner == MCF.Owner.PLAYER_1:
			passenger = u
			break
	var target: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.is_alive() and u.owner == MCF.Owner.PLAYER_2:
			target = u
			break
	ck(passenger != null and target != null, "the fixture has a soldier on each side")
	if passenger == null or target == null:
		return
	state.grid.cell(passenger.coord).occupant = null
	passenger.coord = OFFBOARD
	passenger.aboard_vehicle_id = 1
	ck(r.can_shoot(passenger, target) != "",
			"a soldier inside a vehicle cannot open fire with his own weapon")
	ck(r.hostile_target_ids(passenger).is_empty(),
			"a soldier inside a vehicle sees no targets of his own")
	ck(r.shootable_target_ids(passenger).is_empty(),
			"…and offers none to the interface either")
	# Обратная сторона: по сидящему внутри стрелять тоже нельзя.
	ck(r.can_shoot(target, passenger) != "", "and nobody can shoot him back through the hull")

# --- 2. Противотанкист не подрывает себя (issue 3) ----------------------------------
func _anti_tank_never_blasts_itself() -> void:
	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var at := _spawn(state, "anti_tank", Vector2i(10, 10), MCF.Owner.PLAYER_1)
	var near := _spawn(state, "light_infantry", Vector2i(11, 10), MCF.Owner.PLAYER_2)
	var far := _spawn(state, "light_infantry", Vector2i(10, 20), MCF.Owner.PLAYER_2)
	ck(at != null and near != null and far != null, "the anti-tank fixture is built")
	if at == null:
		return
	ck(r.anti_tank_shot_endangers_own(at, near.coord),
			"a point-blank charge is seen as deadly to the shooter himself")
	ck(r.anti_tank_shot_endangers_own(at, at.coord),
			"a charge at one's own feet is deadly too (it is still a legal shot for a human)")
	ck(not r.anti_tank_shot_endangers_own(at, far.coord),
			"a charge across the map is not")
	# Союзник рядом с целью — тот же запрет: взрыв не разбирает форму.
	var ally := _spawn(state, "light_infantry", Vector2i(10, 19), MCF.Owner.PLAYER_1)
	ck(ally != null and r.anti_tank_shot_endangers_own(at, far.coord),
			"a charge that would catch a squadmate is refused as well")

	# И то же самое глазами ИИ: цель вплотную он больше не выбирает.
	var ai := AIController.new(MCF.Owner.PLAYER_1)
	var shot: Dictionary = ai._best_shoot(state, r, at)
	if not shot.is_empty():
		var intent: ShootIntent = shot["intent"]
		ck(intent.target_id != near.id,
				"the AI anti-tank does not fire at a target standing next to him")

# --- 3. Гильзы, кровь и дорожки (issues 7, 8) ---------------------------------------
func _fx_counts_every_shot() -> void:
	var fx := FxDecals.new()
	# Две ОДИНАКОВЫЕ очереди с одной клетки: гильзы второй не имеют права лечь ровно
	# в те же точки, что и первой, иначе на доске так и останется три гильзы вместо шести.
	var burst := [{"fx": "casings", "at": Vector2i(4, 4), "toward": Vector2i(9, 4), "count": 3}]
	fx.apply(burst)
	ck(fx.flying.size() == 3, "three rounds leave three casings (got %d)" % fx.flying.size())
	var first: Array = []
	for f: Dictionary in fx.flying:
		first.append(f["to"])
	fx.apply(burst)
	ck(fx.flying.size() == 6, "a second burst adds three more (got %d)" % fx.flying.size())
	var same := 0
	for i in range(3, fx.flying.size()):
		if first.has(fx.flying[i]["to"]):
			same += 1
	ck(same == 0, "…and they land in their own spots, not on top of the first three")

	# Кровь и осколки — щедрее прежнего (просьба игрока), но всё так же детерминированы.
	var fx2 := FxDecals.new()
	fx2.apply([{"fx": "blood", "at": Vector2i(6, 6), "from": Vector2i(5, 6)}])
	var drops := fx2.flying.size()
	ck(drops >= FxDecals.SPLATTER_MIN and drops <= FxDecals.SPLATTER_MAX,
			"a death splatters %d..%d drops (got %d)" % [
				FxDecals.SPLATTER_MIN, FxDecals.SPLATTER_MAX, drops])
	var fx3 := FxDecals.new()
	fx3.apply([{"fx": "shards", "at": Vector2i(7, 7), "from": Vector2i(6, 7)}])
	var shards := fx3.flying.size()
	ck(shards >= FxDecals.SHARDS_MIN and shards <= FxDecals.SHARDS_MAX,
			"a broken pane throws %d..%d shards (got %d)" % [
				FxDecals.SHARDS_MIN, FxDecals.SHARDS_MAX, shards])

	# Детерминированность: тот же список описаний — та же картинка у всех.
	var a := FxDecals.new()
	var b := FxDecals.new()
	a.apply(burst)
	a.apply(burst)
	b.apply(burst)
	b.apply(burst)
	var equal := a.flying.size() == b.flying.size()
	if equal:
		for i in a.flying.size():
			if a.flying[i]["to"] != b.flying[i]["to"]:
				equal = false
				break
	ck(equal, "two clients replaying the same fx list draw the same particles")

	# Дорожка «кто в кого» ставится каждой атакой и разбирается отдельным заходом.
	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var shooter := _spawn(state, "light_infantry", Vector2i(12, 12), MCF.Owner.PLAYER_1)
	var victim := _spawn(state, "light_infantry", Vector2i(12, 16), MCF.Owner.PLAYER_2)
	if shooter == null or victim == null:
		return
	# Стреляет тот, чей сейчас ход: доводим очередь до стороны стрелка.
	var guard := 0
	while state.active_player() != shooter.owner and guard < 8:
		guard += 1
		r.resolve(EndTurnIntent.new())
	ck(state.active_player() == shooter.owner, "the shooter's side is on turn")
	shooter.remaining_ap = 2
	var res := r.resolve(ShootIntent.new(shooter.id, victim.id, 1))
	ck(res.ok, "the fixture shot resolves: %s" % res.reason)
	var lane_events := 0
	for ev: Dictionary in res.fx:
		if str(ev.get("fx", "")) == "lane":
			lane_events += 1
	ck(lane_events == 1, "a shot leaves exactly one 'who shot whom' lane (got %d)" % lane_events)
	var fx4 := FxDecals.new()
	fx4.apply(res.fx)
	ck(fx4.lanes.is_empty(), "the ordinary fx pass does not draw the lane")
	fx4.apply_lanes(res.fx)
	ck(fx4.lanes.size() == 1, "the lane pass does — it runs before the dice roll")
	if fx4.lanes.size() == 1:
		ck(int(fx4.lanes[0]["owner"]) == shooter.owner, "the lane is painted in the shooter's colour")
		fx4.advance(FxDecals.LANE_DUR + 0.1)
		ck(fx4.lanes.is_empty(), "and it fades away on its own")

func _spawn(state: GameState, stats_id: String, coord: Vector2i, owner: int) -> UnitInstance:
	var stats: UnitStats = load("res://src/data/units/%s.tres" % stats_id)
	if stats == null:
		fails.append("could not load unit stats '%s'" % stats_id)
		return null
	var cell := state.grid.cell(coord)
	if cell == null or (cell.occupant != null and cell.occupant.is_alive()):
		fails.append("cell %s is not free for the fixture" % coord)
		return null
	return state.spawn_unit(stats, coord, owner)
