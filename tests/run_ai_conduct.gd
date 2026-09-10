extends SceneTree

## Как ИИ ВЕДЁТ СЕБЯ на доске — четыре жалобы игрока, каждая своим прогоном.
##
## 1. НЕ ХОДИТ ЧЕЛНОКОМ (item 1: «ping-ponging… make AIs do actual moves and not this
##    slop»). Жадная оценка считается заново на каждое решение и ничего не помнит: две
##    почти равные клетки, крошечный перевес плавает от хода к ходу — и боец всю партию
##    честно исполняет «сейчас лучше туда». Память о недавних клетках делает возврат
##    дороже; проверяем, что она держит именно возврат и не мешает продвижению.
##
## 2. НЕ СТРЕЛЯЕТ ВПУСТУЮ (item 6). Семёрки на d6 не бывает: укрытие и огонь на линии
##    поднимают нужное число до недостижимого, и такой выстрел — не «плохой», а
##    невозможный. ИИ мерил цель одной дальностью и жёг на ней ОД.
##
## 3. НЕ ДАВИТ СВОИХ (item 7). Врага гусеницей — за тем и едем; собственную пехоту —
##    нет, а подбор хода о ней не спрашивал вовсе.
##
## 4. ВОДИТ ВСЮ ТЕХНИКУ (item 10). Машина, которой жадная оценка не нашла хода, просто
##    выпадала из очереди и простаивала бой.
##
## Прогон смотрит на РЕШЕНИЯ ИИ, а не на его внутренности: гоняет настоящую партию и
## проверяет каждое намерение, которое ИИ успел выдать.

const TS = preload("res://tests/TestSupport.gd")
const ROUNDS := 5
const MAX_ACTIONS := 4000

var fails: PackedStringArray = []
var _pending: Intent = null

func _initialize() -> void:
	_no_impossible_shots_and_no_pingpong()
	_cover_can_make_a_shot_impossible()
	_tanks_spare_their_own()
	_every_tank_gets_moving()

	if fails.is_empty():
		print("ai conduct: no wasted shots, no crushed allies, every tank moves, no ping-pong")
		quit(0)
		return
	printerr("ai conduct: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _on_intent(i: Intent) -> void:
	_pending = i

# --- 1 и 2: настоящая партия, каждое намерение под лупой ------------------------------
func _no_impossible_shots_and_no_pingpong() -> void:
	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var brains := {}
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var ai := AIController.new(side, AIController.Difficulty.NORMAL)
		ai.intent_ready.connect(_on_intent)
		brains[side] = ai
	r.play_civilian_slots()

	var shots := 0
	var impossible := 0
	var hist := {}          # unit_id -> клетки на конец каждого раунда
	var actions := 0
	var last_round := 0
	while state.turns.round_number <= ROUNDS and actions < MAX_ACTIONS:
		if state.turns.round_number != last_round:
			last_round = state.turns.round_number
			_snapshot(state, hist)
		var side: int = state.active_player()
		var ai: AIController = brains.get(side, null)
		if ai == null:
			r.resolve(EndTurnIntent.new())
			continue
		_pending = null
		ai.begin_turn(state)
		if _pending == null:
			r.resolve(EndTurnIntent.new())
			continue
		var intent := _pending
		# Намерение проверяем ДО применения: после выстрела позиции те же, но цель
		# может уже быть трупом, и нужное число посчиталось бы не про то.
		if intent is ShootIntent:
			var shooter := state.get_unit(intent.actor_id)
			var target := state.get_unit((intent as ShootIntent).target_id)
			if shooter != null and target != null and target.is_alive():
				shots += 1
				if r.hit_need_for(shooter, target) >= 7:
					impossible += 1
		actions += 1
		var res := r.resolve(intent)
		if not res.ok:
			ai.notify_intent_denied(state)
	_snapshot(state, hist)

	ck(shots > 0, "the run actually contains AI shooting (otherwise it proves nothing)")
	ck(impossible == 0,
			"AI never fires a shot that needs 7+ on a d6 (%d of %d did)" % [impossible, shots])

	var moves := 0
	var returns := 0
	for id in hist:
		var seq: Array = hist[id]
		moves += maxi(0, seq.size() - 1)
		for i in range(2, seq.size()):
			if seq[i] == seq[i - 2]:
				returns += 1
	ck(returns == 0,
			"nobody walks back to where they stood a turn ago (%d of %d moves did)"
			% [returns, moves])

## Где все стоят сейчас. Повтор подряд не пишем — простоявший ход на месте не «ходил».
func _snapshot(state: GameState, hist: Dictionary) -> void:
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or u.aboard_vehicle_id != -1:
			continue
		if not MCF.is_player(u.owner):
			continue
		var seq: Array = hist.get(u.id, [])
		if seq.is_empty() or seq[seq.size() - 1] != u.coord:
			seq.append(u.coord)
		hist[u.id] = seq

## Тот самый случай из отчёта: цель В ДАЛЬНОСТИ, но за укрытием (item 6).
##
## Дальность одна её не спасает — на 9 клетках лёгкой пехоте нужно 5+. Укрытие вплотную
## к цели добавляет +2, и нужное число становится 7. Резолвер такой выстрел РАЗРЕШАЕТ
## (по дальности он законен, и человек вправе выстрелить хоть в стену), но для ИИ это
## чистая потеря очка действия — раньше он мерил цель одной дальностью и стрелял.
func _cover_can_make_a_shot_impossible() -> void:
	var m := MapData.new(20, 7)
	for y in 7:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	# Укрытие вплотную к цели, со стороны стрелка.
	m.set_cell(Vector2i(11, 3), MCF.FLOOR_NORMAL, 1.0, false, MCF.FEATURE_SANDBAGS)
	m.set_spawn(Vector2i(3, 3), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(12, 3), "light_infantry", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var state := m.build_state(9001)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	var shooter: UnitInstance = null
	var target: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.owner == MCF.Owner.PLAYER_1:
			shooter = u
		elif u.owner == MCF.Owner.PLAYER_2:
			target = u
	if shooter == null or target == null:
		ck(false, "the cover scenario has both a shooter and a target")
		return
	ck(Combat.distance(shooter.coord, target.coord) == 9, "they stand 9 cells apart")
	ck(Combat.hit_number(9, shooter.stats.fire_range) < 7,
			"range alone would allow the shot")
	ck(r.can_shoot(shooter, target) == "",
			"the rules still permit the shot (it is legal, just pointless)")
	ck(r.hit_need_for(shooter, target) == 7,
			"cover pushes the required roll to 7 (got %d)"
			% r.hit_need_for(shooter, target))
	ck(r.shot_is_futile(shooter, target), "and the AI is told the shot is futile")

	# И ИИ действительно не стреляет: за весь свой ход по этой цели ни одного выстрела.
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var ai := AIController.new(MCF.Owner.PLAYER_1, AIController.Difficulty.NORMAL)
	ai.intent_ready.connect(_on_intent)
	var wasted := 0
	for _step in 60:
		_pending = null
		ai.begin_turn(state)
		if _pending == null or _pending is EndTurnIntent:
			break
		if _pending is ShootIntent:
			var sh := state.get_unit(_pending.actor_id)
			var tg := state.get_unit((_pending as ShootIntent).target_id)
			if sh != null and tg != null and tg.is_alive() and r.hit_need_for(sh, tg) >= 7:
				wasted += 1
		var res := r.resolve(_pending)
		if not res.ok:
			ai.notify_intent_denied(state)
	ck(wasted == 0, "AI spends no AP on a shot it cannot land (%d wasted)" % wasted)

# --- 3 и 4: техника ------------------------------------------------------------------

## Собрать поле с ЗАПРАВЛЕННЫМ танком: пустая машина не ходит вовсе (ОД у неё берутся
## от экипажа), и сценарий про вождение без экипажа ничего бы не проверял.
## Возвращает {state, resolver, vehicle}.
func _tank_scenario(w: int, h: int, extra_spawns: Array,
		veh_type: String = "tank", veh_at: Vector2i = Vector2i(1, 3)) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(veh_at, veh_type, MCF.Owner.PLAYER_1, Vector2i(1, 0))
	m.set_spawn(Vector2i(0, 3), "light_infantry", MCF.Owner.PLAYER_1)   # будущий экипаж
	for sp: Dictionary in extra_spawns:
		m.set_spawn(sp["coord"], sp["id"], sp["owner"])
	GameConfig.civilians_enabled = false
	var state := m.build_state(31337)
	var r := GameActionResolver.new(state)
	r.fog_enabled = false
	while state.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var veh: Vehicle = state.all_vehicles()[0] if not state.all_vehicles().is_empty() else null
	var crew: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.is_alive() and u.owner == MCF.Owner.PLAYER_1 and u.coord == Vector2i(0, 3):
			crew = u
			break
	if veh != null and crew != null:
		var board := r.resolve(VehicleBoardIntent.new(crew.id, veh.id))
		if not board.ok:
			fails.append("scenario setup: crew could not board the tank (%s)" % board.reason)
	return {"state": state, "resolver": r, "vehicle": veh}

## Танк не переезжает собственную пехоту (item 7). Поле нарочно ставит ИИ перед
## соблазном: враг ровно по курсу, а между ним и танком — свой же боец.
func _tanks_spare_their_own() -> void:
	var sc := _tank_scenario(22, 9, [
		{"coord": Vector2i(7, 4), "id": "light_infantry", "owner": MCF.Owner.PLAYER_1},
		{"coord": Vector2i(14, 4), "id": "light_infantry", "owner": MCF.Owner.PLAYER_2},
		{"coord": Vector2i(14, 6), "id": "light_infantry", "owner": MCF.Owner.PLAYER_2},
	])
	var state: GameState = sc["state"]
	var r: GameActionResolver = sc["resolver"]
	var veh: Vehicle = sc["vehicle"]
	ck(veh != null and veh.alive(), "the scenario really has a tank")
	if veh == null:
		return
	ck(veh.ap > 0, "the tank has a crew and can actually drive")
	# Что прямой ход давит своего, прогон считает САМ — по плану переезда, а не тем же
	# методом резолвера, который и проверяется. Иначе достаточно было бы сломать метод
	# («никогда никого не давит»), и тест бы это одобрил.
	ck(_move_would_crush_ally(state, veh, veh.facing, 9),
			"driving straight ahead really would crush the friendly infantryman")

	var ai := AIController.new(MCF.Owner.PLAYER_1, AIController.Difficulty.NORMAL)
	ai.intent_ready.connect(_on_intent)
	var ran_over := 0
	for _step in 200:
		_pending = null
		ai.begin_turn(state)
		if _pending == null or _pending is EndTurnIntent:
			break
		if _pending is VehicleMoveIntent:
			var mv: VehicleMoveIntent = _pending
			var v := state.get_vehicle(mv.actor_id)
			if v != null and _move_would_crush_ally(state, v, mv.dir, mv.steps):
				ran_over += 1
		var res := r.resolve(_pending)
		if not res.ok:
			ai.notify_intent_denied(state)
	ck(ran_over == 0, "AI never drives a tank over its own men (%d such orders)" % ran_over)

## Раздавит ли этот переезд своего — считаем НЕЗАВИСИМО от резолвера: планируем ход
## правилами техники и смотрим, кто окажется под гусеницей.
func _move_would_crush_ally(state: GameState, veh: Vehicle, dir: Vector2i,
		max_steps: int) -> bool:
	var speed: int = int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	for steps in range(1, max_steps + 1):
		var plan := VehicleRules.plan_line_move(state, veh, dir, steps, speed)
		if not plan["ok"]:
			continue
		for cc: Vector2i in plan["crush_cells"]:
			var cell := state.grid.cell(cc)
			if cell == null or cell.occupant == null:
				continue
			var occ: UnitInstance = cell.occupant
			if occ.is_alive() and occ.owner == veh.owner:
				return true
	return false

## Каждая машина за ход что-то делает (item 10). Раньше та, которой жадная оценка не
## нашла хода, молча выпадала из очереди — и простаивала бой целиком.
##
## Проверяем сам ПРЕДОХРАНИТЕЛЬ, а не удачный сценарий. Жадный подбор находит машине ход
## почти всегда (враг на карте есть — значит есть и куда ехать), поэтому «прогнать бой и
## посмотреть, поехал ли танк» доказывало бы лишь то, что жадности хватило именно здесь.
## Гарантия, которую даёт правка, другая и проверяется в лоб:
##   1) машина, ещё ничего не сделавшая, ПОПАДАЕТ в добор принудительного прохода —
##      причём независимо от того, набрала ли пехота свою квоту явки;
##   2) принудительный проход действительно выдаёт ей приказ.
func _every_tank_gets_moving() -> void:
	var sc := _tank_scenario(22, 9, [
		{"coord": Vector2i(3, 8), "id": "light_infantry", "owner": MCF.Owner.PLAYER_1},
		{"coord": Vector2i(19, 1), "id": "light_infantry", "owner": MCF.Owner.PLAYER_2},
	])
	var state: GameState = sc["state"]
	var r: GameActionResolver = sc["resolver"]
	var veh: Vehicle = sc["vehicle"]
	if veh == null:
		ck(false, "the scenario really has a vehicle")
		return
	ck(veh.ap > 0, "the vehicle has a crew and can actually drive")

	var ai := AIController.new(MCF.Owner.PLAYER_1, AIController.Difficulty.NORMAL)
	ai.intent_ready.connect(_on_intent)
	# Пехота «уже отходила» — квота явки набрана, и по старому правилу добор не собрался
	# бы вовсе. Машина обязана попасть в него всё равно.
	for u: UnitInstance in state.living_units_of(MCF.Owner.PLAYER_1):
		ai._acted["u%d" % u.id] = true
	var rows: Array = ai._idle_rows(state)
	var has_vehicle := false
	for row: Dictionary in rows:
		if bool(row["vehicle"]) and int(row["id"]) == veh.id:
			has_vehicle = true
	ck(has_vehicle,
			"an idle vehicle is picked up by the forced pass even when infantry met its quota")

	# И этот добор выдаёт машине настоящий приказ, а не пустоту.
	var forced := ai._forced_action(state, r,
			{"id": veh.id, "vehicle": true})
	ck(not forced.is_empty(), "the forced pass produces an order for the vehicle")
	if not forced.is_empty():
		var intent: Intent = forced["intent"]
		ck(intent is VehicleMoveIntent or intent is VehicleTurnIntent,
				"and that order drives or turns it")
		var before_origin := veh.origin
		var before_facing := veh.facing
		var res := r.resolve(intent)
		ck(res.ok, "the resolver accepts the forced vehicle order (%s)" % res.reason)
		ck(veh.origin != before_origin or veh.facing != before_facing,
				"the vehicle actually ends up somewhere new")
