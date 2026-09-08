class_name VehicleRules
extends RefCounted

## Легальность и стоимость движения техники (раздел «Техника» + «Таблица потери
## скорости при столкновении»). Чистые предикаты: резолвер применяет результат.
##
## Стоимость входа в клетку (очки скорости), по таблице правил:
##   обычный ход .............. 1
##   стекло / деревянная стена  1  (таранится → уничтожается)
##   шлюз ..................... 1
##   стена (бетон) ............ 3  (таранится → в пол)
##   стена из трупов .......... 3  (трупы разлетаются по ходу движения)
##   юнит (пехота) ............ 4  (давится)
##   ЛДФ ...................... 6  (таранится)
##   щитоносец ................ 8  (машина ОСТАНАВЛИВАЕТСЯ и получает 1 урон)
## Поворот (для танка) стоит 2 очка скорости за шаг (учитывается отдельно).
## Полностью блокируют: ДОТ, другой корпус, край поля.

const COST_NORMAL := 1
const COST_GLASS := 1
const COST_AIRLOCK := 1
const COST_WALL := 3
const COST_CORPSE_WALL := 3
const COST_UNIT := 1  # item 9: техника «проезжает сквозь» людей — давит их без доплаты хода
const COST_LDF := 6
const COST_SHIELD := 8
const TURN_COST := 1

const SHIELD_STOP_DAMAGE := 1  # щитоносец наносит машине 1 урон и глушит движение

## Что произойдёт при входе части следа в клетку.
## { ok, cost, crush, scatter, ram, stop, self_damage, reason }
static func cell_entry(state: GameState, cell: Vector2i, self_id: int) -> Dictionary:
	var blocked := func(why: String) -> Dictionary:
		return {"ok": false, "cost": 0, "crush": false, "scatter": false,
			"ram": false, "stop": false, "self_damage": 0, "reason": why}
	var ok := func(cost: int, opts: Dictionary = {}) -> Dictionary:
		var d := {"ok": true, "cost": cost, "crush": false, "scatter": false,
			"ram": false, "stop": false, "self_damage": 0, "reason": "ok"}
		for k in opts:
			d[k] = opts[k]
		return d

	if not state.grid.in_bounds(cell):
		return blocked.call("out of bounds")

	var vid := state.grid.vehicle_at(cell)
	if vid != -1 and vid != self_id:
		return blocked.call("blocked by another vehicle")

	var c := state.grid.cell(cell)

	# ДОТ (армированный бетон) — непроходим для техники.
	if c.feature_id == MCF.FEATURE_DOT:
		return blocked.call("pillbox blocks vehicles")
	if c.feature_id == MCF.FEATURE_LDF:
		return ok.call(COST_LDF, {"ram": true})
	if c.feature_id == MCF.FEATURE_GLASS:
		return ok.call(COST_GLASS, {"ram": true})
	if c.feature_id == MCF.FEATURE_CORPSE_WALL:
		return ok.call(COST_CORPSE_WALL, {"scatter": true, "ram": true})
	if c.feature_id == MCF.FEATURE_AIRLOCK:
		return ok.call(COST_AIRLOCK)

	# Живой юнит: давится. Щитоносец — особый случай (стоп + урон машине).
	if c.occupant != null and c.occupant.is_alive():
		if c.occupant.stats.special_ability_id == MCF.ABILITY_SHIELD_BEARER:
			return ok.call(COST_SHIELD, {"crush": true, "stop": true,
				"self_damage": SHIELD_STOP_DAMAGE})
		return ok.call(COST_UNIT, {"crush": true})

	# Труп на клетке — разлетается, не мешает (одиночный, не стена).
	if c.occupant != null:  # status CORPSE
		return ok.call(COST_NORMAL, {"scatter": true})

	# Каменная стена (высота >= 2, не спецобъект) — таранится в пол.
	if c.is_wall():
		return ok.call(COST_WALL, {"ram": true})

	# Низкое укрытие давится и игнорируется; пустой пол/космос — обычный ход.
	return ok.call(COST_NORMAL, {"crush": c.has_cover()})


## Может ли весь след при new_origin быть занят машиной veh (без учёта пути).
## { ok, cost, crush_cells, scatter_cells, ram_cells, stop, self_damage, reason }
static func can_occupy(state: GameState, veh: Vehicle, new_origin: Vector2i) -> Dictionary:
	var total := 0
	var crush_cells: Array[Vector2i] = []
	var scatter_cells: Array[Vector2i] = []
	var ram_cells: Array[Vector2i] = []
	var stop := false
	var self_damage := 0
	for cell in veh.footprint_from(new_origin):
		var e := cell_entry(state, cell, veh.id)
		if not e["ok"]:
			return {"ok": false, "cost": 0, "crush_cells": [], "scatter_cells": [],
				"ram_cells": [], "stop": false, "self_damage": 0, "reason": String(e["reason"])}
		total += int(e["cost"])
		if e["crush"]:
			crush_cells.append(cell)
		if e["scatter"]:
			scatter_cells.append(cell)
		if e["ram"]:
			ram_cells.append(cell)
		if e["stop"]:
			stop = true
		self_damage += int(e["self_damage"])
	return {"ok": true, "cost": total, "crush_cells": crush_cells,
		"scatter_cells": scatter_cells, "ram_cells": ram_cells,
		"stop": stop, "self_damage": self_damage, "reason": "ok"}


## Спланировать ход техники по прямой линии в направлении dir на до `speed` очков.
## Танк: dir = ±facing. Челнок: любое из 8 направлений. Шаги считаются по одной
## клетке; таран/давка/разлёт на клетке считаются ОДИН раз. Возврат:
## { ok, reason, steps, cost, crush_cells, scatter_cells, ram_cells, self_damage, stopped }
static func plan_line_move(state: GameState, veh: Vehicle, dir: Vector2i,
		steps: int, speed: int) -> Dictionary:
	var fail := func(why: String) -> Dictionary:
		return {"ok": false, "reason": why, "steps": 0, "cost": 0, "crush_cells": [],
			"scatter_cells": [], "ram_cells": [], "self_damage": 0, "stopped": false}
	if dir == Vector2i.ZERO or steps <= 0:
		return fail.call("no movement requested")

	# Каждый шаг: база 1 очко + «доплата» (cost-1) за каждую впервые задетую особую
	# клетку (стена/юнит/щитоносец/…), считается один раз за всё движение.
	var seen: Dictionary = {}
	var crush_cells: Array[Vector2i] = []
	var scatter_cells: Array[Vector2i] = []
	var ram_cells: Array[Vector2i] = []
	var cost := 0
	var self_damage := 0
	var reached := 0
	var stopped := false
	for i in range(1, steps + 1):
		# Клетки, впервые попавшие под след на этом шаге.
		var new_cells: Array[Vector2i] = []
		for cell in veh.footprint_from(veh.origin + dir * i):
			if not seen.has(cell):
				new_cells.append(cell)
		var step_extra := 0
		var step_crush: Array[Vector2i] = []
		var step_scatter: Array[Vector2i] = []
		var step_ram: Array[Vector2i] = []
		var step_selfdmg := 0
		var step_stop := false
		var step_blocked := false
		for cell in new_cells:
			var e := cell_entry(state, cell, veh.id)
			if not e["ok"]:
				step_blocked = true
				break
			step_extra += int(e["cost"]) - COST_NORMAL
			if e["crush"]:
				step_crush.append(cell)
			if e["scatter"]:
				step_scatter.append(cell)
			if e["ram"]:
				step_ram.append(cell)
			step_selfdmg += int(e["self_damage"])
			if e["stop"]:
				step_stop = true
		if step_blocked:
			break
		var step_cost := COST_NORMAL + step_extra
		if cost + step_cost > speed:
			break
		cost += step_cost
		self_damage += step_selfdmg
		crush_cells.append_array(step_crush)
		scatter_cells.append_array(step_scatter)
		ram_cells.append_array(step_ram)
		for cell in new_cells:
			seen[cell] = true
		reached = i
		if step_stop:
			stopped = true
			break
	if reached == 0:
		return fail.call("not enough movement or blocked")
	return {"ok": true, "reason": "ok", "steps": reached, "cost": cost,
		"crush_cells": crush_cells, "scatter_cells": scatter_cells,
		"ram_cells": ram_cells, "self_damage": self_damage, "stopped": stopped}
