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
	_airlock_is_no_shelter()
	_only_direct_hits_hurt_vehicles()
	_hands_hold_one_body()
	_drone_stays_near_its_station()
	_tracks_leave_wreckage()
	_boarding_is_not_a_refuel()
	_neutrals_shoot_in_plain_sight()

	if fails.is_empty():
		print("combat safety: off-board lines, self-blast, cosmetics, airlocks,"
				+ " direct-hit armour, one-body hands, the drone leash, track marks,"
				+ " vehicle AP and visible neutral fire all hold")
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

# --- 4. Шлюз — не убежище от гусеницы (item 9) ---------------------------------------
##
## «When a unit is standing in an airlock and gets run over by a tank, they don't die.
## Also, for some reason, airlocks don't get destroyed». Разбор клетки обрывался на
## первой же подходящей ветке: увидев шлюз, правила техники возвращали «проезд стоит 1»
## и до жильца не доходили вовсе — а сам шлюз при этом не помечался тараном и потому
## оставался цел под танком.
func _airlock_is_no_shelter() -> void:
	var state := TS.build_state()
	var grid := state.grid
	var victim: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.is_alive() and MCF.is_player(u.owner) \
				and u.stats.special_ability_id != MCF.ABILITY_SHIELD_BEARER:
			victim = u
			break
	if victim == null:
		fails.append("no victim for the airlock fixture")
		return
	grid.cell(victim.coord).feature_id = MCF.FEATURE_AIRLOCK
	var e := VehicleRules.cell_entry(state, victim.coord, -1)
	ck(bool(e["ok"]), "a vehicle may drive into an airlock cell")
	ck(bool(e["crush"]), "the man standing in the airlock is crushed")
	ck(bool(e["ram"]), "the airlock is rammed, so the move clears it")

	var empty := _free_plain_cell(state)
	if empty != Vector2i(-1, -1):
		grid.cell(empty).feature_id = MCF.FEATURE_AIRLOCK
		var e2 := VehicleRules.cell_entry(state, empty, -1)
		ck(bool(e2["ram"]), "an empty airlock is destroyed too")
		ck(not bool(e2["crush"]), "…without claiming anybody who is not there")

## Первая свободная клетка без объектов — площадка под приспособление.
func _free_plain_cell(state: GameState) -> Vector2i:
	for y in state.grid.height:
		for x in state.grid.width:
			var c := state.grid.cell(Vector2i(x, y))
			if c != null and c.occupant == null and c.feature_id == "" \
					and not c.is_wall() and not c.is_space and c.vehicle_id == -1:
				return Vector2i(x, y)
	return Vector2i(-1, -1)

# --- 5. Броню пробивает только ПРЯМОЕ попадание (item 16) ----------------------------
##
## «Only a direct explosion (tank/anti-tank hit) deals damage to vehicles». Прежде
## хватало того, что след машины задет осколочным полем: заряд в соседней клетке снимал
## прочность наравне с попаданием в борт.
func _only_direct_hits_hurt_vehicles() -> void:
	var m := MapData.new(24, 12)
	for y in 12:
		for x in 24:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(10, 5), "tank", MCF.Owner.PLAYER_2, Vector2i(1, 0))
	m.set_spawn(Vector2i(2, 5), "anti_tank", MCF.Owner.PLAYER_1)
	GameConfig.civilians_enabled = false
	var state := m.build_state(555)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var veh: Vehicle = state.all_vehicles()[0] if not state.all_vehicles().is_empty() else null
	if veh == null:
		fails.append("no vehicle for the direct-hit fixture")
		return
	var hull := veh.footprint()
	var on_hull: Vector2i = hull[0]
	# Клетка вплотную к корпусу, но НЕ на нём: соседний взрыв.
	var beside := Vector2i(-1, -1)
	for d: Vector2i in [Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
		var c: Vector2i = on_hull + d
		if state.grid.in_bounds(c) and not hull.has(c):
			beside = c
			break
	if beside == Vector2i(-1, -1):
		fails.append("no cell beside the hull for the direct-hit fixture")
		return
	var area := MCF.blast_square(beside, MCF.ANTI_TANK_BLAST_RADIUS)
	ck(area.has(on_hull),
			"the fixture is honest: the near-miss blast really does cover the hull")

	var before := veh.durability
	var res := ActionResult.new()
	res.ok = true
	r._damage_vehicles_in_area(area, beside, MCF.ANTI_TANK_VEHICLE_DAMAGE, -1, res, "anti-tank")
	ck(veh.durability == before,
			"a blast NEXT TO the hull leaves the armour alone (%d -> %d)"
			% [before, veh.durability])

	var direct_area := MCF.blast_square(on_hull, MCF.ANTI_TANK_BLAST_RADIUS)
	r._damage_vehicles_in_area(direct_area, on_hull, MCF.ANTI_TANK_VEHICLE_DAMAGE, -1,
			res, "anti-tank")
	ck(veh.durability < before,
			"a blast ON the hull still takes durability off (%d -> %d)"
			% [before, veh.durability])

# --- 6. В руках одно тело (item 15) --------------------------------------------------
func _hands_hold_one_body() -> void:
	ck(MCF.CORPSE_CARRY_MAX == 1, "one body is the carrying limit")
	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var carrier: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.is_alive() and MCF.is_player(u.owner) \
				and u.stats.special_ability_id != MCF.ABILITY_SHIELD_BEARER:
			carrier = u
			break
	if carrier == null:
		fails.append("no carrier for the corpse fixture")
		return
	while state.active_player() != carrier.owner:
		r.resolve(EndTurnIntent.new())
	var a := carrier.coord + Vector2i(1, 0)
	var b := carrier.coord + Vector2i(0, 1)
	state.grid.cell(a).corpse_count = 2
	state.grid.cell(b).corpse_count = 2
	carrier.remaining_ap = 4
	ck(r.resolve(PickUpCorpseIntent.new(carrier.id, a)).ok, "the first body goes into the hands")
	ck(not r.resolve(PickUpCorpseIntent.new(carrier.id, b)).ok, "the second one is refused")
	ck(carrier.carried_corpses == 1, "and the carrier is still holding exactly one")
	# Подсветка обязана совпадать с отказом, иначе клик «не работает» молча.
	ck(r.corpse_pickup_cells(carrier).is_empty(),
			"no cell is offered for a second pickup")

# --- 7. Дрон: привязь к станции (item 13) и видимый полёт (item 12) -------------------
func _drone_stays_near_its_station() -> void:
	ck(MCF.DRONE_LEASH == 15, "the leash is 15 tiles")
	ck(MCF.DRONE_FLIGHT_RANGE == 30, "a full action point still buys 30 tiles of flight")
	ck(MCF.DRONE_LEASH < MCF.DRONE_FLIGHT_RANGE,
			"the leash, not the fuel, is what limits how far the drone gets")

	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var pilot: UnitInstance = null
	for u: UnitInstance in state.living_units_of(MCF.Owner.PLAYER_1):
		pilot = u
		break
	if pilot == null:
		fails.append("no pilot for the drone fixture")
		return
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var station := pilot.coord + Vector2i(1, 0)
	state.grid.cell(station).feature_id = MCF.FEATURE_DRONE_STATION
	state.grid.cell(station).feature_owner = pilot.owner
	var drone := r._launch_drone_at(station, pilot)
	if drone == null:
		fails.append("the drone would not launch")
		return
	drone.remaining_ap = 2
	drone.move_credit = 0

	# Ни одна достижимая клетка не лежит дальше привязи — это и есть правило item 13.
	var beyond := 0
	var farthest := 0
	for c: Vector2i in r.drone_flight_cells(drone):
		var d := Combat.distance(c, drone.home_station)
		farthest = maxi(farthest, d)
		if d > MCF.DRONE_LEASH:
			beyond += 1
	ck(beyond == 0, "no cell beyond the leash is offered (%d were)" % beyond)
	ck(farthest > 1, "the drone can still get somewhere (farthest %d)" % farthest)

	# Полёт отыгрывается ПО КЛЕТКАМ (item 12): тем же событием, что и пеший переход.
	var target := drone.coord
	for c: Vector2i in r.drone_flight_cells(drone):
		if Combat.distance(c, drone.coord) > Combat.distance(target, drone.coord):
			target = c
	var from := drone.coord
	var res := r.resolve(DroneMoveIntent.new(drone.id, target))
	ck(res.ok, "the drone flies (%s)" % res.reason)
	var walk: Dictionary = {}
	for ev: Dictionary in res.dice_events:
		if String(ev.get("kind", "")) == "walk":
			walk = ev
	ck(not walk.is_empty(), "the flight comes back as a walk event, not a teleport")
	if walk.is_empty():
		return
	ck(int(walk["unit"]) == drone.id, "the walk event belongs to the drone")
	ck(walk["from"] == from, "it starts where the drone stood")
	var path: Array = walk["path"]
	ck(path.size() >= 1 and path[path.size() - 1] == target,
			"and its path ends on the target cell")
	# Каждый шаг маршрута — соседняя клетка: путь, а не отрезок между концами.
	var jumps := 0
	var prev: Vector2i = from
	for step: Vector2i in path:
		if Combat.distance(prev, step) != 1:
			jumps += 1
		prev = step
	ck(jumps == 0, "the path is a real cell-by-cell route (%d jumps in it)" % jumps)

# --- 8. Гусеница оставляет след (item 1) ---------------------------------------------
##
## «If a tank rams through a wall, make these tiles display as destroyed». Клетка
## менялась и раньше — стена исчезала, — но на вид оставалась чистым полом, будто там
## ничего и не стояло: переезд не сообщал КОСМЕТИКЕ ни слова, и слой следов о нём не
## знал. Метка та же, что кладёт взрыв, поэтому и рисуется теми же щербинами.
func _tracks_leave_wreckage() -> void:
	var m := MapData.new(16, 8)
	for y in 8:
		for x in 16:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for y in 8:
		m.set_cell(Vector2i(8, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	m.set_spawn(Vector2i(1, 2), "tank", MCF.Owner.PLAYER_1, Vector2i(1, 0))
	m.set_spawn(Vector2i(0, 2), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(14, 2), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var state := m.build_state(77)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var veh: Vehicle = state.all_vehicles()[0] if not state.all_vehicles().is_empty() else null
	if veh == null:
		fails.append("no tank for the track fixture")
		return
	var crew: UnitInstance = null
	for u: UnitInstance in state.living_units_of(MCF.Owner.PLAYER_1):
		crew = u
		break
	r.resolve(VehicleBoardIntent.new(crew.id, veh.id))
	ck(state.grid.cell(Vector2i(8, 2)).is_wall(), "the wall is standing before the ram")
	var res := r.resolve(VehicleMoveIntent.new(veh.id, Vector2i(1, 0), 8))
	ck(res.ok, "the tank drives through it (%s)" % res.reason)
	ck(not state.grid.cell(Vector2i(8, 2)).is_wall(), "and the wall is gone afterwards")
	var debris: Dictionary = {}
	for ev: Dictionary in res.fx:
		if String(ev.get("fx", "")) == "debris":
			debris = ev
	ck(not debris.is_empty(), "the move reports the flattened tiles to the cosmetics layer")
	if debris.is_empty():
		return
	ck((debris["cells"] as Array).has(Vector2i(8, 2)),
			"the rammed wall tile is among them")
	# И слой следов действительно помечает пол разбитым — это и рисуется игроку.
	var fx := FxDecals.new()
	fx.apply(res.fx)
	ck(int(fx.floor_damage.get(Vector2i(8, 2), 0)) > 0,
			"the tile now reads as damaged floor")

# --- 9. Посадка не заправляет машину (item 4) ----------------------------------------
##
## «Yellow circles on tanks don't disappear when action points are spent». Точек на
## борту ровно столько, сколько у машины ОД, — а посадка пересчитывала их по числу
## экипажа с нуля, то есть возвращала всё потраченное: проехал, отстрелялся, подобрал
## пехотинца — и снова полон очков.
func _boarding_is_not_a_refuel() -> void:
	var m := MapData.new(22, 9)
	for y in 9:
		for x in 22:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(4, 3), "tank", MCF.Owner.PLAYER_1, Vector2i(1, 0))
	m.set_spawn(Vector2i(3, 3), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(3, 4), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(3, 5), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(19, 3), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var state := m.build_state(4242)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var veh: Vehicle = state.all_vehicles()[0] if not state.all_vehicles().is_empty() else null
	if veh == null:
		fails.append("no tank for the AP fixture")
		return
	var crew: Array = []
	for u: UnitInstance in state.living_units_of(MCF.Owner.PLAYER_1):
		crew.append(u)
	ck(r.resolve(VehicleBoardIntent.new(crew[0].id, veh.id)).ok, "the first crewman boards")
	ck(r.resolve(VehicleBoardIntent.new(crew[1].id, veh.id)).ok, "the second boards")
	ck(veh.ap == 2, "two crew give the tank two action points (got %d)" % veh.ap)
	ck(r.resolve(VehicleMoveIntent.new(veh.id, veh.facing, 2)).ok, "the tank drives")
	ck(veh.ap == 1, "which spends one of them (got %d)" % veh.ap)
	# Третий садится вплотную к борту: очко добавляется, потраченное НЕ возвращается.
	var spare: UnitInstance = crew[2]
	var beside: Vector2i = veh.footprint()[0] + Vector2i(0, -1)
	if state.grid.in_bounds(beside) and state.grid.cell(beside).occupant == null:
		# place() сам снимает юнита с прежней клетки — отдельного remove у сетки нет.
		state.grid.place(spare, beside)
		var b := r.resolve(VehicleBoardIntent.new(spare.id, veh.id))
		if b.ok:
			ck(veh.ap <= 2, "a third crewman does not refund the spent point (ap=%d)" % veh.ap)
			ck(veh.ap == 2, "he adds his own, though (ap=%d, crew=%d)"
					% [veh.ap, veh.living_crew_count()])

# --- 10. Мирные стреляют на виду (items 5 и 6) ---------------------------------------
##
## «Make the shooting indication also appear when neutrals are shooting at players'
## soldiers and add the same shooting animation». Косметика жителя собиралась как у
## всех, но при сборке слота её просто выбрасывали — список fx подытога никуда не
## копировался. Житель стрелял в полной тишине: боец падал, и найти стрелявшего было
## нечем. Заодно слот сообщает о себе (item 6), чтобы список инициативы мог подсветить
## идущую группу: своего active_player у неё нет — резолвер проводит все нейтральные
## слоты внутри одной передачи хода.
func _neutrals_shoot_in_plain_sight() -> void:
	var m := MapData.new(16, 8)
	for y in 8:
		for x in 16:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	# Мирные дерутся, только когда их БОЛЬШЕ, чем солдат рядом (§нейтралы): один житель
	# против взвода честно убегает, и выстрела в такой сцене не дождёшься.
	for i in 5:
		m.set_spawn(Vector2i(2 + i, 5), "civilian", MCF.Owner.NEUTRAL)
	m.set_spawn(Vector2i(4, 3), "light_infantry", MCF.Owner.PLAYER_1)
	GameConfig.civilians_enabled = true
	var state := m.build_state(31)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	for u: UnitInstance in state.all_units():
		if MCF.is_neutral(u.owner):
			u.civilian_active = true
	var lanes := 0
	var slot_marks := 0
	var shots := 0
	for i in 8:
		var res := r.resolve(EndTurnIntent.new())
		for ev: Dictionary in res.fx:
			if String(ev.get("fx", "")) == "lane":
				lanes += 1
		for ev: Dictionary in res.dice_events:
			if String(ev.get("kind", "")) == "slot":
				slot_marks += 1
		for line: String in res.log_lines:
			if line.findn("hits (need") != -1:
				shots += 1
	ck(shots > 0, "the fixture really does get civilians shooting (%d volleys)" % shots)
	ck(lanes > 0,
			"a civilian shooting a player's soldier leaves a who-shot-whom lane (%d)" % lanes)
	ck(slot_marks > 0,
			"and the civilian slot announces itself so the initiative list can mark it")
