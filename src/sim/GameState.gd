class_name GameState
extends RefCounted

## Всё состояние партии: сетка, юниты, ходы, кубики, лог.
## Слой симуляции — не знает, кто управляет сторонами (§2.1).

var grid: Grid
var dice: DiceService
var turns: TurnManager
var log: CombatLog

var units: Dictionary = {}  # id -> UnitInstance
var _next_id: int = 0

var vehicles: Dictionary = {}  # id -> Vehicle
var _next_vehicle_id: int = Vehicle.ID_BASE

## Защёлка «бой начался» (§3.10, #56): взводится первым же выстрелом/взрывом где угодно
## на карте и больше не снимается. Мирные жители по ней вскрываются ВСЕ разом —
## выстрел слышен всем, а не только тем, кто его видел.
var combat_started: bool = false

func _init(width: int, height: int, dice_seed: int = -1) -> void:
	grid = Grid.new(width, height)
	dice = DiceService.new(dice_seed)
	turns = TurnManager.new()
	log = CombatLog.new()

## occupy=false — юнит появляется НАД клеткой, не занимая её (дрон, §3.12: он висит в
## воздухе, под ним спокойно стоит боец). Раньше это делалось так: дрона клали жильцом
## клетки, а сразу после — возвращали прежнего жильца поверх. При строгой сетке (#103)
## затирать чужого жильца нельзя, да и раньше это работало по случайности; теперь
## исключение названо своим именем и живёт в одном месте.
func spawn_unit(stats: UnitStats, coord: Vector2i, owner: int,
		occupy: bool = true) -> UnitInstance:
	var unit := UnitInstance.new(_next_id, stats, coord, owner)
	_next_id += 1
	units[unit.id] = unit
	if occupy:
		grid.place(unit, coord)
	return unit

func get_unit(id: int) -> UnitInstance:
	return units.get(id, null)

func all_units() -> Array:
	return units.values()

## Создать машину (танк/челнок) по типу из VehicleDB и разметить её след на сетке.
## coord = верхний-левый угол следа. Возвращает Vehicle или null, если тип неизвестен.
func spawn_vehicle(type_id: String, coord: Vector2i, owner: int) -> Vehicle:
	var spec := VehicleDB.get_vehicle(type_id)
	if spec.is_empty():
		return null
	var size := VehicleDB.size_of(type_id)
	var veh := Vehicle.new(_next_vehicle_id, type_id, owner, coord, size,
			int(spec.get("durability", 0)))
	if not bool(spec.get("has_facing", false)):
		veh.facing = Vector2i.ZERO
	_next_vehicle_id += 1
	vehicles[veh.id] = veh
	grid.set_vehicle_footprint(veh.id, veh.footprint())
	return veh

func get_vehicle(id: int) -> Vehicle:
	return vehicles.get(id, null)

func all_vehicles() -> Array:
	return vehicles.values()

func vehicle_on(coord: Vector2i) -> Vehicle:
	var vid := grid.vehicle_at(coord)
	return vehicles.get(vid, null) if vid != -1 else null

func living_units_of(owner: int) -> Array:
	var out: Array = []
	for u in units.values():
		if u.owner == owner and u.is_alive():
			out.append(u)
	return out

func active_player() -> int:
	return turns.active_player()

# --- Undo: полный снимок изменяемого состояния (#47) -----------------------
## Глубокий снимок ВСЕГО изменяемого состояния партии для отката (Undo).
## Восстановление мутирует ТЕ ЖЕ объекты (units/vehicles/cells), чтобы внешние
## ссылки (выбранный юнит в UI и т. п.) оставались валидными. Ссылки на юнитов
## в клетках восстанавливаются по id.
func snapshot() -> Dictionary:
	var us: Array = []
	for u: UnitInstance in units.values():
		var ast: Dictionary = {}
		if u.action_state != null:
			ast = {"target_id": u.action_state.target_id,
					"remaining_shots": u.action_state.remaining_shots}
		us.append({
			"obj": u, "id": u.id, "coord": u.coord, "owner": u.owner,
			"remaining_ap": u.remaining_ap, "status": u.status,
			"held_item_id": u.held_item_id, "captor_id": u.captor_id,
			"is_drone": u.is_drone, "home_station": u.home_station,
			"operator_id": u.operator_id, "wall_entry_from": u.wall_entry_from,
				"civilian_active": u.civilian_active,
			"carried_this_round": u.carried_this_round,
			"aboard_vehicle_id": u.aboard_vehicle_id, "dig_credits": u.dig_credits,
			"bru_wall_used": u.bru_wall_used, "move_credit": u.move_credit,
			"carried_corpses": u.carried_corpses, "dragging": u.dragging,
			"action_state": ast,
		})
	var vs: Array = []
	for v: Vehicle in vehicles.values():
		vs.append({
			"obj": v, "id": v.id, "owner": v.owner, "durability": v.durability,
			"origin": v.origin, "size": v.size, "facing": v.facing, "ap": v.ap,
			"occupants": v.occupants.duplicate(),
			"corpse_slots": v.corpse_slots.duplicate(),
			"seats": v.seats.duplicate(), "wrecked": v.wrecked,
			"cannon_shots_this_round": v.cannon_shots_this_round,
			"move_credit": v.move_credit,
		})
	var cs: Array = []
	for c: GridCell in grid._cells:
		cs.append({
			"floor_type": c.floor_type, "cover_height": c.cover_height,
			"on_fire": c.on_fire, "fire_owner": c.fire_owner, "is_space": c.is_space,
			"occupant_id": c.occupant.id if c.occupant != null else -1,
			"vehicle_id": c.vehicle_id, "feature_id": c.feature_id,
			"feature_owner": c.feature_owner, "feature_durability": c.feature_durability,
			"corpse_count": c.corpse_count, "dirt_level": c.dirt_level,
			"airlock_welded": c.airlock_welded,
		})
	return {
		"units": us, "vehicles": vs, "cells": cs,
		"active_index": turns.active_index, "round_number": turns.round_number,
		"next_id": _next_id, "next_vehicle_id": _next_vehicle_id,
		"combat_started": combat_started,
	}

## Откатить состояние к ранее взятому снимку (см. snapshot()).
func restore(snap: Dictionary) -> void:
	units.clear()
	for rec: Dictionary in snap["units"]:
		var u: UnitInstance = rec["obj"]
		u.coord = rec["coord"]
		u.owner = rec["owner"]
		u.remaining_ap = rec["remaining_ap"]
		u.status = rec["status"]
		u.held_item_id = rec["held_item_id"]
		u.captor_id = rec["captor_id"]
		u.is_drone = rec["is_drone"]
		u.home_station = rec["home_station"]
		u.operator_id = rec["operator_id"]
		u.wall_entry_from = rec["wall_entry_from"]
		u.civilian_active = rec["civilian_active"]
		u.carried_this_round = rec["carried_this_round"]
		u.aboard_vehicle_id = rec["aboard_vehicle_id"]
		u.dig_credits = rec["dig_credits"]
		u.bru_wall_used = rec["bru_wall_used"]
		u.move_credit = rec["move_credit"]
		u.carried_corpses = rec["carried_corpses"]
		u.dragging = rec["dragging"]
		var ast: Dictionary = rec["action_state"]
		if ast.is_empty():
			u.action_state = null
		else:
			var a := ActionState.new()
			a.target_id = ast["target_id"]
			a.remaining_shots = ast["remaining_shots"]
			u.action_state = a
		units[u.id] = u
	vehicles.clear()
	for rec: Dictionary in snap["vehicles"]:
		var v: Vehicle = rec["obj"]
		v.owner = rec["owner"]
		v.durability = rec["durability"]
		v.origin = rec["origin"]
		v.size = rec["size"]
		v.facing = rec["facing"]
		v.ap = rec["ap"]
		v.occupants = rec["occupants"].duplicate()
		v.corpse_slots = rec["corpse_slots"].duplicate()
		v.seats = rec["seats"].duplicate()
		v.wrecked = rec["wrecked"]
		v.cannon_shots_this_round = rec["cannon_shots_this_round"]
		v.move_credit = rec["move_credit"]
		vehicles[v.id] = v
	var cells: Array = snap["cells"]
	for i in cells.size():
		var rec: Dictionary = cells[i]
		var c: GridCell = grid._cells[i]
		c.floor_type = rec["floor_type"]
		c.cover_height = rec["cover_height"]
		c.on_fire = rec["on_fire"]
		c.fire_owner = rec["fire_owner"]
		c.is_space = rec["is_space"]
		var oid: int = rec["occupant_id"]
		c.occupant = units.get(oid, null) if oid != -1 else null
		c.vehicle_id = rec["vehicle_id"]
		c.feature_id = rec["feature_id"]
		c.feature_owner = rec["feature_owner"]
		c.feature_durability = rec["feature_durability"]
		c.corpse_count = rec["corpse_count"]
		c.dirt_level = rec["dirt_level"]
		c.airlock_welded = rec["airlock_welded"]
	turns.active_index = snap["active_index"]
	turns.round_number = snap["round_number"]
	_next_id = snap["next_id"]
	_next_vehicle_id = snap["next_vehicle_id"]
	combat_started = snap.get("combat_started", combat_started)
