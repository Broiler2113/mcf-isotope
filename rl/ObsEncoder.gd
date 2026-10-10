extends RefCounted

## Наблюдение обучаемой политики (RL v1, spec §3). Кодируется ЗДЕСЬ, а не в Python,
## ровно по одной причине: сторона видит только то, что ей положено (§3.3 — паритет с
## человеком, туман войны), и фильтр обязан стоять до того, как данные покинут процесс.
## Python собирает из этого тензор 64×64×C и плоский вектор; он не может «случайно»
## подсмотреть скрытого врага, потому что скрытый враг сюда не попадает.
##
## Формат — плотные массивы по клеткам (row-major, w*h) плюс списки сущностей. Коды
## ниже фиксированы: менять порядок = переобучать сеть.

const UNIT_TYPES := [
	"light_infantry", "heavy_infantry", "machinegunner", "sniper", "anti_tank",
	"engineer", "flamethrower", "assault", "marksman", "miner", "sapper",
	"shield_bearer", "drone_operator", "commander", "civilian", "drone",
]
const VEHICLE_TYPES := ["tank", "shuttle", "borg"]
const FEATURES := [
	MCF.FEATURE_WALL, MCF.FEATURE_WOOD_WALL, MCF.FEATURE_GLASS, MCF.FEATURE_ARMOR_WALL,
	MCF.FEATURE_ARMOR_GLASS, MCF.FEATURE_LDF, MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN,
	MCF.FEATURE_TRENCH, MCF.FEATURE_DIRT_PILE, MCF.FEATURE_SANDBAGS, MCF.FEATURE_HEDGEHOG,
	MCF.FEATURE_HEDGEHOG_SANDBAGS, MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_DPMG,
	MCF.FEATURE_AIRLOCK, MCF.FEATURE_CORPSE_WALL, MCF.FEATURE_DRONE_STATION,
	MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE,
]
const ITEMS := [MCF.ITEM_FRAG, MCF.ITEM_EXTINGUISHER, MCF.ITEM_DRONE_STATION, MCF.ITEM_LDF]

## Относительный владелец: 0 — свой/союзник, 1 — враг, 2 — нейтрал.
static func rel_owner(r: GameActionResolver, side: int, owner: int) -> int:
	if MCF.is_neutral(owner):
		return 2
	if owner == side or r.state.roster.are_allies(side, owner):
		return 0
	return 1

static func unit_type(u: UnitInstance) -> int:
	if u.is_drone:
		return UNIT_TYPES.size() - 1
	return maxi(0, UNIT_TYPES.find(u.stats.id))

## Стоимость живой армии стороны: пехота по cost, техника — цена × доля очков ВСЕХ узлов.
## Это и есть «army value» из награды §6.1; дрон и станции ничего не стоят.
##
## Раньше техника стоила цену × долю одного КОРПУСА. Но у танка корпус — 8 очков из 26, а
## промах по узлу уходит каскадом пушка → башня → гусеницы → корпус: 18 очков урона
## (и выбитая пушка, и порванные гусеницы) не стоили в награде ничего, пока танк не умрёт.
## tactical-1 так и не стал стрелять противотанкистом по технике (0 раз из 26 показанных
## случаев), а танк HARD'а делал 30% его убийств и доживал до конца в 94% партий.
static func army_value(state: GameState, side: int) -> float:
	var v := 0.0
	for u in state.all_units():
		if u.owner == side and u.is_alive() and not u.is_drone:
			v += float(u.stats.cost)
	for veh: Vehicle in state.all_vehicles():
		if veh.owner != side or not veh.alive():
			continue
		v += vehicle_worth(veh)
	return v

## Чего стоит МАШИНА в её нынешнем виде: цена корпуса, умноженная на долю уцелевших узлов.
## Вынесено отдельно, чтобы «сколько мы потеряли на технике» считалось той же арифметикой,
## что и общая стоимость армии, — иначе подбитая гусеница стоила бы в двух местах по-разному.
static func vehicle_worth(veh: Vehicle) -> float:
	if veh == null or not veh.alive():
		return 0.0
	var have := 0
	var full := 0
	for comp: String in veh.components:
		var top := veh.component_max(comp)
		if top > 0:
			have += mini(veh.component(comp), top)
			full += top
	return float(VehicleDB.buy_cost(veh.type_id)) * float(have) / float(maxi(1, full))

## Тактический контекст точки решения (RL tactical env): карта огня врага по клеткам,
## своё огневое покрытие и кэши ходов. Считается ОДИН раз на ответ и отдаётся и в encode,
## и в describe каждого кандидата. Туман честен: fire_cover(…, true) видит только тех
## врагов, что видны стороне.
## Прогноз (enemy_forecast) — что видимые враги смогут следующим ходом: куда дойдут и куда
## достанут огнём. memory — EnemyMemory этой стороны (null — без памяти о скрытых врагах).
static func tactics(r: GameActionResolver, side: int, memory: RefCounted = null) -> Dictionary:
	var fc: Dictionary = r.enemy_forecast(side)
	return {"r": r, "side": side, "w": r.state.grid.width,
			"threat": r.fire_cover(side, true), "cover": r.fire_cover(side, false),
			"fnext": fc["fire"], "ereach": fc["reach"],
			"vcrush": vehicle_crush_threat(r, side),
			"lastseen": memory.layer(r, side) if memory != null else PackedInt32Array(),
			"dthreat": drone_threat(r, side),
			"reach": {}, "vt": {}, "hazards": hazards(r)}

## Cells a visible, driveable enemy vehicle could sweep next turn. This is an
## intentionally conservative lane forecast: the opponent will get fresh AP, and a
## tank may turn before driving. Only visible vehicles and known terrain contribute.
## In particular, hidden occupants never shorten a lane and reveal their location.
static func vehicle_crush_threat(r: GameActionResolver, side: int) -> PackedFloat32Array:
	var sight_limited := r.visibility_limited()
	var grid := r.state.grid
	var out := PackedFloat32Array()
	out.resize(grid.width * grid.height)
	var visible: Dictionary = r.team_visible_coords(side) if sight_limited else {}
	for veh: Vehicle in r.state.all_vehicles():
		if not veh.alive() or veh.is_borg() or not veh.can_drive() \
				or veh.living_crew_count() == 0 or rel_owner(r, side, veh.owner) != 1:
			continue
		var seen := not sight_limited
		for fc: Vector2i in veh.footprint():
			if visible.has(fc):
				seen = true
				break
		if not seen:
			continue
		var dirs: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
		if veh.facing == Vector2i.ZERO:
			dirs.append_array([Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)])
		elif not dirs.has(veh.facing):
			dirs.append(veh.facing)
			dirs.append(-veh.facing)
		var per_ap := MCF.SHUTTLE_CELLS_PER_AP if veh.facing == Vector2i.ZERO \
				else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
		for dir: Vector2i in dirs:
			var straight := veh.facing == Vector2i.ZERO or dir == veh.facing or dir == -veh.facing
			var reach := mini(48, per_ap * (3 if straight else 2))
			var weight := 1.0 if straight else 0.5
			for step in range(1, reach + 1):
				var footprint := veh.footprint_from(veh.origin + dir * step)
				var blocked := false
				for c: Vector2i in footprint:
					if not grid.in_bounds(c):
						blocked = true
						break
					if (not sight_limited or r.team_knows(side, c)) and grid.cell(c).is_space \
							and veh.type_id == "tank":
						blocked = true
						break
				if blocked:
					break
				for c: Vector2i in footprint:
					var i := c.y * grid.width + c.x
					out[i] = maxf(out[i], weight)
	return out

## Event rectangles are announced publicly, including under fog. Never expose
## future dice outcomes or a hidden unit through these layers. All warnings resolve at the next player end-turn; active gas has its own channel.
static func hazards(r: GameActionResolver) -> Dictionary:
	var grid := r.state.grid
	var out := {}
	for key: String in ["gas", "gas_warning", "artillery_warning"]:
		var layer := PackedFloat32Array()
		layer.resize(grid.width * grid.height)
		out[key] = layer
	var events := r.random_events
	if events == null:
		return out
	for cloud: Dictionary in events.clouds:
		_hazard_rect(out["gas"], grid, cloud, 1.0)
	for event: Dictionary in events.pending:
		var key := "gas_warning" if event["id"] == RandomEvents.GAS else "artillery_warning"
		if event["id"] != RandomEvents.GAS and event["id"] != RandomEvents.MORTAR:
			continue
		_hazard_rect(out[key], grid, event["params"], 1.0)
	return out

static func _hazard_rect(layer: PackedFloat32Array, grid: Grid, rect: Dictionary, risk: float) -> void:
	var x0 := int(rect.get("x", 0))
	var y0 := int(rect.get("y", 0))
	for y in range(maxi(0, y0), mini(grid.height, y0 + int(rect.get("h", 0)))):
		for x in range(maxi(0, x0), mini(grid.width, x0 + int(rect.get("w", 0)))):
			layer[y * grid.width + x] = maxf(layer[y * grid.width + x], risk)

## Угроза вражеского дрона (§3.12). Дрон не уходит от своей станции дальше DRONE_LEASH
## и рвётся по площади ANTI_TANK_BLAST_RADIUS — значит всё, что ближе их суммы к ЧУЖОЙ
## станции, может быть накрыто за один чужой ход. Без этого слоя станция для политики —
## рядовой предмет на полу, и она спокойно сводила роту внутрь её радиуса.
##
## Берутся только те станции, которые СТОРОНЕ ВИДНЫ и у которых рядом живой вражеский
## оператор: без оператора пульт мёртв (operator_controls), а о невидимой станции знать
## не положено — тот же честный туман, что и у остальных слоёв.
##
## Значение: 1 у самой станции и плавно к нулю на краю радиуса, чтобы «впритирку» и
## «в эпицентре» не читались одинаково.
static func drone_threat(r: GameActionResolver, side: int) -> PackedFloat32Array:
	var sight_limited := r.visibility_limited()
	var grid := r.state.grid
	var out := PackedFloat32Array()
	out.resize(grid.width * grid.height)
	out.fill(0.0)
	var reach: int = MCF.DRONE_LEASH + MCF.ANTI_TANK_BLAST_RADIUS
	var visible := r.team_visible_coords(side)
	for y in grid.height:
		for x in grid.width:
			var cell := grid.cell_fast(x, y)
			if cell.feature_id != MCF.FEATURE_DRONE_STATION:
				continue
			if rel_owner(r, side, cell.feature_owner) != 1:
				continue
			if sight_limited and not visible.has(Vector2i(x, y)):
				continue
			if not _station_is_manned(r, Vector2i(x, y), cell.feature_owner):
				continue
			for dy in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var tx := x + dx
					var ty := y + dy
					if tx < 0 or ty < 0 or tx >= grid.width or ty >= grid.height:
						continue
					var d: int = maxi(absi(dx), absi(dy))
					var i := ty * grid.width + tx
					out[i] = maxf(out[i], 1.0 - float(d) / float(reach + 1))
	return out

## Есть ли у станции живой оператор вплотную — то же условие, по которому дрон вообще
## слушается пульта (operator_controls).
static func _station_is_manned(r: GameActionResolver, at: Vector2i, owner: int) -> bool:
	for u: UnitInstance in r.state.all_units():
		if not u.is_alive() or u.is_drone or u.owner != owner:
			continue
		if u.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
			continue
		if Combat.distance(u.coord, at) == 1:
			return true
	return false

## Карта огня в провод: целыми четвертями ожидаемого попадания (JSON легче и точности
## хватает с запасом), с потолком — десять стволов на клетку и так «смертельно».
static func _quarters(a: PackedFloat32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(a.size())
	for i in a.size():
		out[i] = mini(int(round(a[i] * 4.0)), 40)
	return out

static func encode(r: GameActionResolver, side: int, round_cap: int, tac: Dictionary = {}) -> Dictionary:
	var sight_limited := r.visibility_limited()
	if tac.is_empty():
		tac = tactics(r, side)
	var state := r.state
	var grid := state.grid
	var w := grid.width
	var h := grid.height
	var n := w * h
	var floor_a := PackedInt32Array()
	var feat_a := PackedInt32Array()
	var feat_own := PackedInt32Array()
	var cover_a := PackedInt32Array()
	var fire_a := PackedInt32Array()
	var corpse_a := PackedInt32Array()
	var dirt_a := PackedInt32Array()
	var fog_a := PackedInt32Array()
	var veh_a := PackedInt32Array()
	for arr in [floor_a, feat_a, feat_own, cover_a, fire_a, corpse_a, dirt_a, fog_a, veh_a]:
		arr.resize(n)
	var visible := r.team_visible_coords(side)
	for y in h:
		for x in w:
			var i := y * w + x
			var c := Vector2i(x, y)
			var cell := grid.cell_fast(x, y)
			var sees := not sight_limited or visible.has(c)
			var knows := sees or r.team_knows(side, c)
			fog_a[i] = 2 if sees else (1 if knows else 0)
			if not knows:
				continue   # REALISTIC: неизвестная клетка — нули везде
			floor_a[i] = 3 if cell.is_space else cell.floor_type + 1
			var fid := cell.feature_id
			if fid == MCF.FEATURE_MINE or fid == MCF.FEATURE_AV_MINE:
				# Мина видна лишь своей стороне или после подсветки сапёром (item 13).
				if not (cell.feature_owner == side or r.mine_visible_to(side, c)):
					fid = ""
			var fi := FEATURES.find(fid)
			if fi < 0 and (fid == MCF.FEATURE_SOIL or (fid == "" and cell.is_wall())):
				fi = 0   # стена рельефа без имени объекта и грунт — как обычная стена
			feat_a[i] = fi + 1
			if fid != "" and cell.feature_owner >= 0:
				feat_own[i] = rel_owner(r, side, cell.feature_owner) + 1
			cover_a[i] = int(round(cell.cover_height * 2.0))
			if sees:
				fire_a[i] = 1 if cell.on_fire else 0
				corpse_a[i] = mini(cell.corpse_count + (1 if cell.occupant != null
						and cell.occupant.status == MCF.Status.CORPSE else 0), 5)
			dirt_a[i] = cell.dirt_level
			if cell.vehicle_id != -1 and sees:
				veh_a[i] = 1

	var units: Array = []
	var ids: Array = state.units.keys()
	ids.sort()
	for id: int in ids:
		var u: UnitInstance = state.units[id]
		if not u.is_alive():
			continue
		var own := rel_owner(r, side, u.owner)
		if own != 0 and not r.is_visible_to_team(side, u):
			continue
		var rec := {
			"id": u.id, "x": u.coord.x, "y": u.coord.y, "own": own,
			"type": unit_type(u), "ap": u.remaining_ap, "max_ap": u.max_ap(),
			"held": 1 if u.is_held() else 0, "corpses": u.carried_corpses,
			"item": ITEMS.find(u.held_item_id) + 1,
			"aboard": 1 if u.aboard_vehicle_id != -1 else 0,
			"borg": 1 if u.borg_id != -1 else 0,
			"civ": 1 if u.civilian_active else 0,
			"mc": u.move_credit, "cost": u.stats.cost,
		}
		if own == 0 and u.action_state != null and u.action_state.is_pending():
			rec["pending"] = u.action_state.remaining_shots
		units.append(rec)

	var vehicles: Array = []
	var vids: Array = state.vehicles.keys()
	vids.sort()
	for vid: int in vids:
		var veh: Vehicle = state.vehicles[vid]
		var own := rel_owner(r, side, veh.owner)
		if own != 0:
			var seen := not sight_limited
			for fc: Vector2i in veh.footprint():
				if visible.has(fc):
					seen = true
					break
			if not seen:
				continue
		var comps := {}
		for comp: String in veh.components.keys():
			comps[comp] = [veh.component(comp), veh.component_max(comp)]
		vehicles.append({
			"id": veh.id, "type": maxi(0, VEHICLE_TYPES.find(veh.type_id)), "own": own,
			"x": veh.origin.x, "y": veh.origin.y, "w": veh.size.x, "h": veh.size.y,
			"fx": veh.facing.x, "fy": veh.facing.y, "alive": 1 if veh.alive() else 0,
			"wrecked": 1 if veh.wrecked else 0, "ap": r.vehicle_ap(veh),
			"crew": veh.living_crew_count(), "cap": veh.capacity(),
			"comps": comps, "cost": VehicleDB.buy_cost(veh.type_id),
		})

	var my_value := army_value(state, side)
	var enemy_value := 0.0
	for e: int in state.roster.player_ids():
		if rel_owner(r, side, e) == 1:
			enemy_value += army_value(state, e)
	return {
		"w": w, "h": h, "side": side,
		"floor": floor_a, "feat": feat_a, "feat_own": feat_own, "cover": cover_a,
		"fire": fire_a, "corpse": corpse_a, "dirt": dirt_a, "fog": fog_a, "veh": veh_a,
		"units": units, "vehicles": vehicles,
		"round": state.turns.round_number, "round_cap": round_cap,
		"slot": state.turns.active_index, "slots": state.turns.round_order.size(),
		"fog_mode": r.fog_mode,
		"my_value": my_value, "enemy_value": enemy_value,
		"combat_started": 1 if state.combat_started else 0,
		"threat": _quarters(tac["threat"]), "fcover": _quarters(tac["cover"]),
		"fnext": _quarters(tac["fnext"]), "ereach": _quarters(tac["ereach"]),
		"vcrush": _quarters(tac["vcrush"]),
		"dthreat": _quarters(tac["dthreat"]),
		"lastseen": tac["lastseen"],
		"gas": tac["hazards"]["gas"], "gas_warning": tac["hazards"]["gas_warning"],
		"artillery_warning": tac["hazards"]["artillery_warning"],
	}

## Подпись кандидата для сети: провод IntentCodec плюс координаты актёра/цели, чтобы
## Python не восстанавливал их по id.
static func describe(state: GameState, intent: Intent, tac: Dictionary = {}) -> Dictionary:
	var d := {"i": IntentCodec.encode(intent), "ax": -1, "ay": -1, "tx": -1, "ty": -1, "tt": -1}
	var actor := state.get_unit(intent.actor_id)
	if actor != null:
		d["ax"] = actor.coord.x
		d["ay"] = actor.coord.y
		d["at"] = unit_type(actor)
	else:
		var veh := state.get_vehicle(intent.actor_id)
		if veh != null:
			var c := veh.center()
			d["ax"] = c.x
			d["ay"] = c.y
			d["at"] = UNIT_TYPES.size() + maxi(0, VEHICLE_TYPES.find(veh.type_id))
	var tgt: Vector2i = Vector2i(-1, -1)
	if intent is ShootIntent:
		var t := state.get_unit(intent.target_id)
		if t != null:
			tgt = t.coord
			d["tt"] = unit_type(t)
		else:
			tgt = intent.target_cell
	elif intent is CaptureIntent or intent is PushIntent:
		var t2 := state.get_unit(intent.target_id)
		if t2 != null:
			tgt = t2.coord
			d["tt"] = unit_type(t2)
	elif intent is DPMGFireIntent:
		var t3 := state.get_unit(intent.target_id)
		tgt = t3.coord if t3 != null else intent.dpmg_coord
	elif intent is MoveIntent or intent is DroneMoveIntent or intent is UseItemIntent \
			or intent is BuildIntent or intent is BreakIntent or intent is DigIntent \
			or intent is PlaceMineIntent or intent is DisarmMineIntent \
			or intent is VehicleDisembarkIntent or intent is VehicleCannonIntent:
		tgt = intent.target
	elif intent is DragIntent:
		tgt = intent.dest_coord
	elif intent is PickUpCorpseIntent:
		tgt = intent.from
	elif intent is DropCorpseIntent or intent is MoveHeldIntent or intent is WeldAirlockIntent:
		tgt = intent.to
	elif intent is PickUpStationIntent:
		tgt = intent.coord
	elif intent is SpawnDroneIntent:
		tgt = intent.station
	elif intent is VehicleMoveIntent:
		var mv := state.get_vehicle(intent.actor_id)
		if mv != null:
			tgt = mv.center() + intent.dir * intent.steps
	elif intent is VehicleTurnIntent:
		tgt = Vector2i(d["ax"], d["ay"]) + intent.facing
	elif intent is VehicleBoardIntent or intent is VehicleMeleeIntent \
			or intent is RepairVehicleIntent or intent is VehicleUnloadCorpseIntent:
		var bv := state.get_vehicle(intent.vehicle_id)
		if bv != null:
			tgt = bv.center()
	if state.grid.in_bounds(tgt):
		d["tx"] = tgt.x
		d["ty"] = tgt.y
	# Дрон (batch ui-drones): поводок и техника. «lf» — насколько клетка полёта близка к
	# пределу в DRONE_LEASH клеток от своей станции (1 = дальше не улетит); «vh» — сколько
	# клеток вражеской техники накроет подрыв дрона там (дрон снимает прочность корпуса).
	if actor != null and actor.is_drone:
		var at_cell: Vector2i = tgt if intent is DroneMoveIntent else actor.coord
		if intent is DroneMoveIntent or intent is DroneDetonateIntent:
			d["lf"] = float(Combat.distance(at_cell, actor.home_station)) / float(MCF.DRONE_LEASH)
			var hit := 0
			for c: Vector2i in MCF.blast_square(at_cell, MCF.ANTI_TANK_BLAST_RADIUS):
				if not state.grid.in_bounds(c):
					continue
				var v := state.get_vehicle(state.grid.vehicle_at(c))
				if v != null and v.alive() and v.owner != actor.owner \
						and not state.roster.are_allies(actor.owner, v.owner):
					hit += 1
			d["vh"] = hit
	# Поводок станции (§3.12) в тот момент, когда выбирают МЕСТО под неё. Дрон не уходит
	# дальше DRONE_LEASH клеток от своей станции, а оператор не отходит от станции, не
	# потеряв управление, — поэтому станция, поставленная дальше поводка от врага, просто
	# вычитает оператора из боя до конца партии. «lf» выше этого случая НЕ покрывает: там
	# актёр — САМ ДРОН, то есть он уже в воздухе, а место станции давно выбрано.
	#
	# 1 — враг вплотную к станции, 0 — на поводке его не достать. Столько же и когда врага
	# не видно: по умолчанию признак НИЧЕГО не обещает (в отличие от «lf», у которого ноль
	# значит «поводок цел»).
	if not tac.is_empty() and _is_station_choice(state, intent):
		var at: Vector2i = tgt if state.grid.in_bounds(tgt) else Vector2i(int(d["ax"]), int(d["ay"]))
		if state.grid.in_bounds(at):
			d["rh"] = snappedf(_station_reach(tac["r"], int(tac["side"]), at), 0.01)
	if not tac.is_empty() and state.grid.in_bounds(tgt):
		_describe_tactics(state, intent, tgt, d, tac)
	if not tac.is_empty():
		var at := Vector2i(int(d["ax"]), int(d["ay"]))
		d["hazard"] = _hazard_at(tac, at) + _hazard_at(tac, tgt)
		d["vc"] = [_vehicle_risk_at(tac, at), _vehicle_risk_at(tac, tgt)]
	return d

static func _vehicle_risk_at(tac: Dictionary, at: Vector2i) -> float:
	var r: GameActionResolver = tac["r"]
	if not r.state.grid.in_bounds(at):
		return 0.0
	return tac["vcrush"][at.y * int(tac["w"]) + at.x]

static func _hazard_at(tac: Dictionary, at: Vector2i) -> Array:
	var r: GameActionResolver = tac["r"]
	if not r.state.grid.in_bounds(at):
		return [0.0, 0.0, 0.0]
	var i := at.y * int(tac["w"]) + at.x
	var hz: Dictionary = tac["hazards"]
	return [hz["gas"][i], hz["gas_warning"][i], hz["artillery_warning"][i]]

## Кандидат выбирает МЕСТО под станцию дронов: либо разворачивает её из рук, либо
## поднимает дрон с уже стоящей. Прочих намерений поводок не касается.
static func _is_station_choice(state: GameState, intent: Intent) -> bool:
	if intent is SpawnDroneIntent:
		return true
	if intent is UseItemIntent:
		var u := state.get_unit(intent.actor_id)
		return u != null and u.held_item_id == MCF.ITEM_DRONE_STATION
	return false

## Запас поводка до ближайшего ВИДИМОГО врага из клетки станции: 1 — враг у самой станции,
## 0 — дальше DRONE_LEASH или врага не видно. Туман соблюдается, как и всюду в наблюдении:
## спрашивать о том, чего команда не видит, политике нельзя. Дроны в расчёт не идут — за
## ними не охотятся станцией.
static func _station_reach(r: GameActionResolver, side: int, at: Vector2i) -> float:
	var sight_limited := r.visibility_limited()
	var best := -1
	for u: UnitInstance in r.state.all_units():
		if not u.is_alive() or u.is_drone or rel_owner(r, side, u.owner) != 1:
			continue
		if sight_limited and not r.is_visible_to_team(side, u):
			continue
		var dist := Combat.distance(at, u.coord)
		if best < 0 or dist < best:
			best = dist
	if best < 0:
		return 0.0
	# Делится на LEASH + 1, а не на LEASH: тогда РОВНО на поводке (враг в 15 клетках —
	# дрон его ещё достаёт, но без запаса) выходит не ноль, а 1/16, и «дотянуться в упор»
	# не путается с «не дотянуться вовсе». Ноль остаётся ровно за тем, кого не достать.
	var span := float(MCF.DRONE_LEASH + 1)
	return clampf((span - float(best)) / span, 0.0, 1.0)

## Тактика кандидата: огонь врага и своё покрытие в клетке цели, укрытие там же и, для хода,
## сколько ОД он спишет (1-3, зоны move_tier_budgets). Ровно то, что отличает «выйти под
## пулемёт» от «перебежать за мешки».
static func _describe_tactics(state: GameState, intent: Intent, tgt: Vector2i, d: Dictionary,
		tac: Dictionary) -> void:
	var r: GameActionResolver = tac["r"]
	var i: int = tgt.y * int(tac["w"]) + tgt.x
	d["th"] = snappedf(tac["threat"][i], 0.01)
	d["tn"] = snappedf(tac["fnext"][i], 0.01)
	d["er"] = int(tac["ereach"][i])
	d["fc"] = snappedf(tac["cover"][i], 0.01)
	d["cv"] = state.grid.cell(tgt).cover_height
	if intent is MoveIntent:
		var u := state.get_unit(intent.actor_id)
		if u == null:
			return
		var memo: Dictionary = tac["reach"]
		if not memo.has(u.id):
			var tiers := r.move_tier_budgets(u)
			memo[u.id] = [tiers, r.reachable_for(u, tiers[tiers.size() - 1]).cost]
		var cost: Dictionary = memo[u.id][1]
		if cost.has(tgt):
			var k := GameActionResolver.tier_of(memo[u.id][0], int(cost[tgt]))
			d["apc"] = k + (0 if u.move_credit > 0 else 1)
	elif intent is VehicleMoveIntent:
		var veh := state.get_vehicle(intent.actor_id)
		if veh == null:
			return
		var vmemo: Dictionary = tac["vt"]
		if not vmemo.has(veh.id):
			vmemo[veh.id] = [r.vehicle_tier_budgets(veh), r.vehicle_move_targets_all(veh)]
		var all: Dictionary = vmemo[veh.id][1]
		if all.has(tgt) and not vmemo[veh.id][0].is_empty():
			var vk := GameActionResolver.tier_of(vmemo[veh.id][0], int(all[tgt]["cost"]))
			d["apc"] = vk + (0 if r.vehicle_move_credit(veh) > 0 else 1)
