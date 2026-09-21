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

## Стоимость живой армии стороны: пехота по cost, техника — цена × доля корпуса.
## Это и есть «army value» из награды §6.1; дрон и станции ничего не стоят.
static func army_value(state: GameState, side: int) -> float:
	var v := 0.0
	for u in state.all_units():
		if u.owner == side and u.is_alive() and not u.is_drone:
			v += float(u.stats.cost)
	for veh: Vehicle in state.all_vehicles():
		if veh.owner != side or not veh.alive():
			continue
		var cap := maxi(1, veh.component_max(MCF.COMP_HULL))
		v += float(VehicleDB.buy_cost(veh.type_id)) * float(veh.component(MCF.COMP_HULL)) / float(cap)
	return v

static func encode(r: GameActionResolver, side: int, round_cap: int) -> Dictionary:
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
			var sees := not r.fog_enabled or visible.has(c)
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
			if fi < 0 and fid == "" and cell.is_wall():
				fi = 0   # стена рельефа без имени объекта — как обычная стена
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
			var seen := not r.fog_enabled
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
		"fog_mode": r.fog_mode if r.fog_enabled else MCF.Fog.OFF,
		"my_value": my_value, "enemy_value": enemy_value,
		"combat_started": 1 if state.combat_started else 0,
	}

## Подпись кандидата для сети: провод IntentCodec плюс координаты актёра/цели, чтобы
## Python не восстанавливал их по id.
static func describe(state: GameState, intent: Intent) -> Dictionary:
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
	return d
