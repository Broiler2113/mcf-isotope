class_name StateCodec
extends RefCounted

## Дисковый формат состояния партии (M12, items 42 и 53) — ОБЩЕЕ ЯДРО сохранения и
## повтора. Сохранённый матч и ключевой кадр реплея — это один и тот же снимок; они
## различаются лишь тем, что к нему приложено (см. ReplayRecorder и ReplayFile).
##
## Почему не GameState.snapshot(). Тот снимок держит ЖИВЫЕ ССЫЛКИ на объекты
## (rec["obj"] — сам UnitInstance) и родные Vector2i: он сделан для отката внутри
## одного процесса, и на диск его не положить. Здесь всё раскладывается в
## JSON-совместимые типы, а при чтении собирается заново — но применяется снимок
## ЧЕРЕЗ ту же GameState.restore(), чтобы «что именно составляет состояние партии»
## было описано ровно в одном месте. Забытое поле ловит tests/run_codec.gd.
##
## Правила боя (туман, дружественный огонь, случайные события) живут не в GameState,
## а на резолвере, поэтому у них своя пара encode_rules/apply_rules: файл обязан
## возвращать не только доску, но и условия, при которых она сложилась.

const SCHEMA := 1
const UNIT_PATH := "res://src/data/units/%s.tres"

# --- Запись -----------------------------------------------------------------

static func encode(state: GameState) -> Dictionary:
	var units: Array = []
	var ids: Array = state.units.keys()
	ids.sort()   # порядок в файле фиксирован: одинаковая доска — одинаковый файл
	for id: int in ids:
		units.append(_encode_unit(state.units[id]))
	var vehicles: Array = []
	var vids: Array = state.vehicles.keys()
	vids.sort()
	for id: int in vids:
		vehicles.append(_encode_vehicle(state.vehicles[id]))
	return {
		"schema": SCHEMA,
		"w": state.grid.width, "h": state.grid.height,
		"dice": {"seed": state.dice.current_seed(), "rolls": state.dice.own_rolls},
		"roster": state.roster.to_dict(),
		"units": units,
		"vehicles": vehicles,
		"cells": _encode_cells(state.grid),
		"turns": {
			"order": _copy(state.turns.round_order),
			"index": state.turns.active_index,
			"round": state.turns.round_number,
			"rolled": state.turns.initiative_rolled,
			"dead": _encode_eliminated(state.turns.eliminated),
		},
		"mines": _encode_mines(state.revealed_mines),
		"next_id": state._next_id,
		"next_vehicle_id": state._next_vehicle_id,
		"combat_started": state.combat_started,
	}

static func _encode_unit(u: UnitInstance) -> Dictionary:
	var rec := {
		"id": u.id,
		"stats": u.stats.id if u.stats != null else "",
		"coord": _xy(u.coord), "owner": u.owner,
		"ap": u.remaining_ap, "status": u.status,
		"item": u.held_item_id, "captor": u.captor_id,
		"drone": u.is_drone, "station": _xy(u.home_station),
		"operator": u.operator_id, "wall_from": _xy(u.wall_entry_from),
		"civ_active": u.civilian_active, "group": u.neutral_group,
		"carried_round": u.carried_this_round,
		"aboard": u.aboard_vehicle_id, "dig": u.dig_credits,
		"ldf_wall": u.ldf_wall_used, "move_credit": u.move_credit,
		"mines": u.mine_credits, "corpses": u.carried_corpses,
		"dragging": _xy(u.dragging),
	}
	if u.action_state != null:
		rec["action"] = {"target": u.action_state.target_id,
				"shots": u.action_state.remaining_shots}
	return rec

static func _encode_vehicle(v: Vehicle) -> Dictionary:
	return {
		"id": v.id, "type": v.type_id, "owner": v.owner,
		# Узлы едут ЦЕЛИКОМ (веха «Modular tank system»): по одному durability машину
		# уже не восстановить — разбитая ходовая и заклиненная башня живут в components.
		"components": v.components.duplicate(),
		"tower_dir": _xy(v.tower_locked_dir),
		"durability": v.durability, "origin": _xy(v.origin), "size": _xy(v.size),
		"facing": _xy(v.facing), "ap": v.ap,
		"occupants": _copy(v.occupants), "corpse_slots": _copy(v.corpse_slots),
		"seats": _copy(v.seats), "wrecked": v.wrecked,
		"cannon_shots": v.cannon_shots_this_round, "move_credit": v.move_credit,
	}

## Клетки пишутся РАЗРЕЖЕННО: на карте 50×50 их две с половиной тысячи, и почти все
## — чистый пол. В файл едут только те, что отличаются от пустой клетки, с индексом
## в сетке; остальные при чтении собираются из умолчаний.
static func _encode_cells(grid: Grid) -> Array:
	var out: Array = []
	var i := -1
	for c: GridCell in grid.cells_flat():
		i += 1
		var rec := {}
		if c.floor_type != 0: rec["floor"] = c.floor_type
		if c.cover_height != 0.0: rec["cover"] = c.cover_height
		if c.on_fire: rec["fire"] = true
		if c.fire_owner != -1: rec["fire_owner"] = c.fire_owner
		if c.fire_suppressed_until != 0: rec["suppressed"] = c.fire_suppressed_until
		if c.is_space: rec["space"] = true
		if c.occupant != null: rec["occupant"] = c.occupant.id
		if c.vehicle_id != -1: rec["vehicle"] = c.vehicle_id
		if c.feature_id != "": rec["feature"] = c.feature_id
		if c.feature_owner != -1: rec["feature_owner"] = c.feature_owner
		if c.feature_durability != 0: rec["durability"] = c.feature_durability
		if c.station_operator_id != -1: rec["station_op"] = c.station_operator_id
		if c.corpse_count != 0: rec["corpses"] = c.corpse_count
		if c.dirt_level != 0: rec["dirt"] = c.dirt_level
		if c.airlock_welded: rec["welded"] = true
		if rec.is_empty():
			continue
		rec["i"] = i
		out.append(rec)
	return out

static func _encode_eliminated(dead: Dictionary) -> Array:
	var out: Array = []
	for slot: int in dead:
		if bool(dead[slot]):
			out.append(slot)
	out.sort()
	return out

## Подсветка мин — словарь словарей с ключами-Vector2i: в JSON такой ключ не живёт,
## поэтому каждая запись едет тройкой (владелец, клетка, до какого раунда).
static func _encode_mines(revealed: Dictionary) -> Array:
	var out: Array = []
	var owners: Array = revealed.keys()
	owners.sort()
	for owner: int in owners:
		var cells: Dictionary = revealed[owner]
		var keys: Array = cells.keys()
		keys.sort()
		for coord: Vector2i in keys:
			out.append([owner, coord.x, coord.y, int(cells[coord])])
	return out

## Правила боя, живущие на резолвере, — они не часть доски, но без них сохранение
## не воспроизводимо: тот же ход при другом тумане законен по-другому.
static func encode_rules(resolver: GameActionResolver) -> Dictionary:
	var out := {
		"fog": resolver.fog_mode,
		"friendly_fire": resolver.friendly_fire_enabled,
	}
	if resolver.random_events != null:
		out["events"] = resolver.random_events.snapshot()
		out["events_cfg"] = {
			"enabled": resolver.random_events.enabled,
			"mandatory": resolver.random_events.mandatory,
			"interval": resolver.random_events.interval,
			"weights": resolver.random_events.weights.duplicate(),
		}
	return out

static func apply_rules(resolver: GameActionResolver, d: Dictionary) -> void:
	resolver.fog_mode = int(d.get("fog", resolver.fog_mode))
	resolver.friendly_fire_enabled = bool(d.get("friendly_fire", true))
	var cfg: Dictionary = d.get("events_cfg", {})
	if not cfg.is_empty():
		var weights: Dictionary = {}
		for id in cfg.get("weights", {}):
			weights[str(id)] = int(cfg["weights"][id])
		resolver.random_events = RandomEvents.new(bool(cfg.get("enabled", false)),
				bool(cfg.get("mandatory", false)), int(cfg.get("interval", 3)), weights)
	if resolver.random_events != null and d.has("events"):
		resolver.random_events.restore(d["events"])

# --- Чтение -----------------------------------------------------------------

## Собрать состояние обратно. null — файл новее нас: читать его наполовину хуже,
## чем честно отказаться.
static func decode(d: Dictionary) -> GameState:
	if int(d.get("schema", 0)) > SCHEMA:
		return null
	var gs := GameState.new(int(d.get("w", 16)), int(d.get("h", 12)))
	var dice: Dictionary = d.get("dice", {})
	gs.dice.restore_position(int(dice.get("seed", 0)), int(dice.get("rolls", 0)))
	gs.roster = Roster.from_dict(d.get("roster", {}))

	# Снимок собирается в ТОЧНОСТИ той формы, какую ждёт GameState.restore():
	# объекты создаём здесь, а раскладывает их по местам общий код отката.
	var unit_recs: Array = []
	for raw in d.get("units", []):
		unit_recs.append(_decode_unit(raw))
	var veh_recs: Array = []
	for raw in d.get("vehicles", []):
		veh_recs.append(_decode_vehicle(raw))
	var turns: Dictionary = d.get("turns", {})
	var order: Array[int] = []
	for slot in turns.get("order", []):
		order.append(int(slot))
	if order.is_empty():
		order = [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]
	var dead: Dictionary = {}
	for slot in turns.get("dead", []):
		dead[int(slot)] = true
	var snap := {
		"units": unit_recs, "vehicles": veh_recs,
		"cells": _decode_cells(d.get("cells", []), gs.grid.width * gs.grid.height),
		"active_index": clampi(int(turns.get("index", 0)), 0, order.size() - 1),
		"round_number": maxi(int(turns.get("round", 1)), 1),
		"round_order": order,
		"turn_eliminated": dead,
		"next_id": int(d.get("next_id", 0)),
		"next_vehicle_id": int(d.get("next_vehicle_id", Vehicle.ID_BASE)),
		"combat_started": bool(d.get("combat_started", false)),
	}
	# roster и revealed_mines в снимок НЕ кладём намеренно: restore() умеет только
	# их изменяемую часть (кто выбит), а из файла приходит весь состав целиком.
	gs.restore(snap)
	gs.turns.initiative_rolled = bool(turns.get("rolled", true))
	gs.revealed_mines = _decode_mines(d.get("mines", []))
	return gs

static func _decode_unit(raw: Dictionary) -> Dictionary:
	var stats := load_stats(str(raw.get("stats", "")))
	var u := UnitInstance.new(int(raw.get("id", -1)), stats,
			_vec(raw.get("coord")), int(raw.get("owner", 0)))
	var action: Dictionary = {}
	if raw.has("action"):
		var a: Dictionary = raw["action"]
		action = {"target_id": int(a.get("target", -1)),
				"remaining_shots": int(a.get("shots", 0))}
	return {
		"obj": u, "id": u.id, "coord": u.coord, "owner": u.owner,
		"remaining_ap": int(raw.get("ap", 0)), "status": int(raw.get("status", 0)),
		"held_item_id": str(raw.get("item", "")), "captor_id": int(raw.get("captor", -1)),
		"is_drone": bool(raw.get("drone", false)),
		"home_station": _vec(raw.get("station"), Vector2i(-1, -1)),
		"operator_id": int(raw.get("operator", -1)),
		"wall_entry_from": _vec(raw.get("wall_from"), Vector2i(-1, -1)),
		"civilian_active": bool(raw.get("civ_active", false)),
		"neutral_group": int(raw.get("group", 0)),
		"carried_this_round": bool(raw.get("carried_round", false)),
		"aboard_vehicle_id": int(raw.get("aboard", -1)),
		"dig_credits": int(raw.get("dig", 0)),
		"ldf_wall_used": bool(raw.get("ldf_wall", false)),
		"move_credit": int(raw.get("move_credit", 0)),
		"mine_credits": int(raw.get("mines", 0)),
		"carried_corpses": int(raw.get("corpses", 0)),
		"dragging": _vec(raw.get("dragging"), UnitInstance.NOT_DRAGGING),
		"action_state": action,
	}

static func _decode_vehicle(raw: Dictionary) -> Dictionary:
	var v := Vehicle.new(int(raw.get("id", -1)), str(raw.get("type", "")),
			int(raw.get("owner", -1)), _vec(raw.get("origin")),
			_vec(raw.get("size"), Vector2i.ONE), int(raw.get("durability", 0)))
	# Типизированные массивы обязаны остаться типизированными: GameState.restore()
	# присваивает их напрямую в Array[int] / Array[String].
	var occupants: Array[int] = []
	for id in raw.get("occupants", []):
		occupants.append(int(id))
	var seats: Array[int] = []
	for id in raw.get("seats", []):
		seats.append(int(id))
	var corpses: Array[String] = []
	for type_id in raw.get("corpse_slots", []):
		corpses.append(str(type_id))
	# Старая запись (одно durability, без узлов) читается как машина с целыми узлами и
	# заданным корпусом — иначе сохранения прежних партий открывались бы с нулевой бронёй.
	var comps: Dictionary = {}
	for comp: String in raw.get("components", {}):
		comps[comp] = int(raw["components"][comp])
	if comps.is_empty():
		comps = v.components.duplicate()
		comps[MCF.COMP_HULL] = int(raw.get("durability", 0))
	# Запись с ПРЕЖНЕЙ единой ходовой (одна «tracks» на машину, до вехи 14.1) разливается
	# поровну по двум гусеницам: иначе у старого танка не оказалось бы ни одной, и он
	# грузился бы обездвиженным.
	if comps.has(MCF.COMP_TRACKS) and not v.components.has(MCF.COMP_TRACKS):
		var was: int = int(comps[MCF.COMP_TRACKS])
		comps.erase(MCF.COMP_TRACKS)
		for comp: String in [MCF.COMP_TRACKS_L, MCF.COMP_TRACKS_R]:
			if v.components.has(comp):
				comps[comp] = mini(was, int(MCF.VEHICLE_COMPONENTS.get(
					v.type_id, {}).get(comp, was)))
	return {
		"obj": v, "id": v.id, "owner": v.owner,
		"components": comps, "tower_locked_dir": _vec(raw.get("tower_dir"), Vector2i.ZERO),
		"durability": v.durability, "origin": v.origin, "size": v.size,
		"facing": _vec(raw.get("facing"), Vector2i(1, 0)), "ap": int(raw.get("ap", 0)),
		"occupants": occupants, "corpse_slots": corpses, "seats": seats,
		"wrecked": bool(raw.get("wrecked", false)),
		"cannon_shots_this_round": int(raw.get("cannon_shots", 0)),
		"move_credit": int(raw.get("move_credit", 0)),
	}

static func _decode_cells(sparse: Array, count: int) -> Array:
	var out: Array = []
	out.resize(count)
	for i in count:
		out[i] = _default_cell()
	for raw: Dictionary in sparse:
		var i := int(raw.get("i", -1))
		if i < 0 or i >= count:
			continue
		var rec: Dictionary = out[i]
		rec["floor_type"] = int(raw.get("floor", 0))
		rec["cover_height"] = float(raw.get("cover", 0.0))
		rec["on_fire"] = bool(raw.get("fire", false))
		rec["fire_owner"] = int(raw.get("fire_owner", -1))
		rec["fire_suppressed_until"] = int(raw.get("suppressed", 0))
		rec["is_space"] = bool(raw.get("space", false))
		rec["occupant_id"] = int(raw.get("occupant", -1))
		rec["vehicle_id"] = int(raw.get("vehicle", -1))
		rec["feature_id"] = str(raw.get("feature", ""))
		rec["feature_owner"] = int(raw.get("feature_owner", -1))
		rec["feature_durability"] = int(raw.get("durability", 0))
		rec["station_operator_id"] = int(raw.get("station_op", -1))
		rec["corpse_count"] = int(raw.get("corpses", 0))
		rec["dirt_level"] = int(raw.get("dirt", 0))
		rec["airlock_welded"] = bool(raw.get("welded", false))
	return out

static func _default_cell() -> Dictionary:
	return {
		"floor_type": 0, "cover_height": 0.0, "on_fire": false, "fire_owner": -1,
		"fire_suppressed_until": 0, "is_space": false, "occupant_id": -1,
		"vehicle_id": -1, "feature_id": "", "feature_owner": -1,
		"feature_durability": 0, "station_operator_id": -1, "corpse_count": 0,
		"dirt_level": 0, "airlock_welded": false,
	}

static func _decode_mines(raw: Array) -> Dictionary:
	var out: Dictionary = {}
	for entry in raw:
		if not (entry is Array) or (entry as Array).size() < 4:
			continue
		var owner := int(entry[0])
		if not out.has(owner):
			out[owner] = {}
		(out[owner] as Dictionary)[Vector2i(int(entry[1]), int(entry[2]))] = int(entry[3])
	return out

## Характеристики по id. Неизвестный id — не повод ронять загрузку: юнит встанет
## на доску без статов и будет виден как «неизвестный», а не утащит с собой партию.
static func load_stats(id: String) -> UnitStats:
	if id == "":
		return null
	var path := UNIT_PATH % id
	if not ResourceLoader.exists(path):
		return null
	return load(path)

static func _xy(v: Vector2i) -> Array:
	return [v.x, v.y]

## Настоящая КОПИЯ массива, а не другой взгляд на тот же. Array(typed) отдаёт всё тот
## же массив под другим типом, и снимок, снятый в начале матча, продолжал жить вместе
## с партией: стартовый кадр повтора приезжал на диск с порядком инициативы, сложившимся
## к концу боя. Ошибка тихая — файл выглядит правильным, а воспроизводится с чужой доски.
static func _copy(src: Array) -> Array:
	var out: Array = []
	for v in src:
		out.append(v)
	return out

static func _vec(raw: Variant, fallback: Vector2i = Vector2i.ZERO) -> Vector2i:
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return fallback
