class_name GameState
extends RefCounted

## Всё состояние партии: сетка, юниты, ходы, кубики, лог.
## Слой симуляции — не знает, кто управляет сторонами (§2.1).

var grid: Grid
var dice: DiceService
var turns: TurnManager
var log: CombatLog
## Кто играет: стороны, команды, цвета, выбитость (см. Roster). До сборки лобби
## это дуэль на двоих — то, чем игра была всегда.
## Время суток карты (MapData.time_of_day, 0.12.1) — только свет.
var time_of_day := ""
## Winter map (MapData.winter, fix-8) — only looks.
var winter := false
var roster: Roster

var units: Dictionary = {}  # id -> UnitInstance
var _next_id: int = 0

var vehicles: Dictionary = {}  # id -> Vehicle
## Списки для all_units()/all_vehicles() (perf pass #1). values() собирал новый массив на
## КАЖДЫЙ вызов, а зовут их десятки раз за действие. Теперь список один и пересобирается
## лениво — после правки словаря через spawn_*/remove_*/restore(); размер сверяется ещё и
## на случай, если словарь поправят в обход них. Порядок прежний — порядок вставки, тот
## же, что отдаёт values(). Список только для чтения: правка вызывающим дала бы ошибку, а
## не испортила бы его всем. При правке словаря старый список не меняется, а заменяется
## новым, поэтому цикл, в котором кто-то погиб или родился, идёт по снимку — как раньше.
var _unit_list: Array = []
var _units_dirty := true
var _vehicle_list: Array = []
var _vehicles_dirty := true
var _next_vehicle_id: int = Vehicle.ID_BASE

## Защёлка «бой начался» (§3.10, #56): взводится первым же выстрелом/взрывом где угодно
## на карте и больше не снимается. Мирные жители по ней вскрываются ВСЕ разом —
## выстрел слышен всем, а не только тем, кто его видел.
var combat_started: bool = false
## Сквозной номер косметического события (batch mp-perf): им засевается разлёт крови,
## осколков и гильз (FxDecals). Он — часть доски, а не счётчик экрана, поэтому у хоста и
## каждого гостя одинаков, переживает пересинхронизацию и сохранение.
var fx_seq: int = 0
## Счёт для таблицы итогов боя (playtest-20): id бойца или машины -> [убито, из них
## раздавлено]. В подпись доски не входит — на правила не влияет; в снимок отката входит,
## чтобы отменённый наезд вернул и счёт.
var kills: Dictionary = {}
## Павшие по сторонам (item 1): владелец -> сколько его бойцов погибло за партию.
## Считать трупы на доске нельзя: тело уходит из партии, когда его подняли щитом,
## сложили в кучу или задвинули под кресло (remove_unit) — и счёт «мёртвых» полз
## обратно. Ледж растёт только вперёд; откат возвращает его вместе с доской.
var deaths: Dictionary = {}
## Окружение карты (item 24) — вид плиток пола и стен; правил не касается.
var env: String = "town"

## Подсвеченные сапёром чужие мины (item 45): владелец → {клетка: до какого раунда}.
## Хранится ПО ВЛАДЕЛЬЦАМ, а не одним флагом на клетке: подсветить одну и ту же мину
## могут двое, и у каждого свой срок. Ни в какие пакеты не едет — это знание стороны
## о поле, а не само поле.
var revealed_mines: Dictionary = {}
var cheats_enabled := false
var cheat_vision: Dictionary = {}
var cheat_mines: Dictionary = {}
var cheat_sequence := 0
var cheat_ai_paused: Dictionary = {}

static func clean_cheat_sides(raw: Variant) -> Dictionary:
	var out := {}
	if raw is Dictionary:
		for key in raw:
			var text := str(key)
			if text.is_valid_int() and MCF.is_player(int(text)) and raw[key] is bool and raw[key]:
				out[int(text)] = true
	return out

func _init(width: int, height: int, dice_seed: int = -1) -> void:
	cheats_enabled = GameConfig.cheats_enabled
	grid = Grid.new(width, height)
	dice = DiceService.new(dice_seed)
	turns = TurnManager.new()
	log = CombatLog.new()
	roster = Roster.default_duel()

## occupy=false — юнит появляется НАД клеткой, не занимая её (дрон, §3.12: он висит в
## воздухе, под ним спокойно стоит боец). Раньше это делалось так: дрона клали жильцом
## клетки, а сразу после — возвращали прежнего жильца поверх. При строгой сетке (#103)
## затирать чужого жильца нельзя, да и раньше это работало по случайности; теперь
## исключение названо своим именем и живёт в одном месте.
func spawn_unit(stats: UnitStats, coord: Vector2i, owner: int,
		occupy: bool = true) -> UnitInstance:
	var unit := UnitInstance.new(_next_id, stats, coord, owner)
	_next_id += 1
	# A refused cell (taken, or a body lies there) must not leave an off-board "ghost".
	if occupy and not grid.place(unit, coord):
		return null
	units[unit.id] = unit
	_units_dirty = true
	return unit

func get_unit(id: int) -> UnitInstance:
	return units.get(id, null)

## The unit captor_id holds (the first in all_units() order), or null. The index is rebuilt
## only after a status or captor change (UnitInstance.hold_epoch) or a new unit list: the
## scan it replaces ran on every move budget, O(army) per soldier of a group order.
func held_by(captor_id: int) -> UnitInstance:
	var list := all_units()
	if _held_epoch != UnitInstance.hold_epoch or not is_same(list, _held_list):
		_held_epoch = UnitInstance.hold_epoch
		_held_list = list
		_held_by.clear()
		for u: UnitInstance in list:
			if u.is_held() and not _held_by.has(u.captor_id): _held_by[u.captor_id] = u
	return _held_by.get(captor_id)

var _held_by: Dictionary = {}
var _held_epoch := -1
var _held_list: Array = []

## Units with a captor (captor_id != -1), in all_units() order: what the per-action captive
## check walks instead of the whole army. Rebuilt on the same signal as held_by's index.
func captives() -> Array:
	var list := all_units()
	if _captive_epoch != UnitInstance.hold_epoch or not is_same(list, _captive_list):
		_captive_epoch = UnitInstance.hold_epoch
		_captive_list = list
		_captives = []
		for u: UnitInstance in list:
			if u.captor_id != -1: _captives.append(u)
	return _captives

var _captives: Array = []
var _captive_epoch := -1
var _captive_list: Array = []

## Bodies stacked in a pile or carried (corpse_stacked or corpse_carrier_id >= 0), in all_units()
## order: CorpseIdentity.cleanup's candidates after every action. Rebuilt when either field of
## any unit changes (UnitInstance.corpse_epoch) or the unit list does.
func tracked_bodies() -> Array:
	var list := all_units()
	if _bodies_epoch != UnitInstance.corpse_epoch or not is_same(list, _bodies_list):
		_bodies_epoch = UnitInstance.corpse_epoch
		_bodies_list = list
		_bodies = []
		for u: UnitInstance in list:
			if u.corpse_stacked or u.corpse_carrier_id >= 0: _bodies.append(u)
	return _bodies

var _bodies: Array = []
var _bodies_epoch := -1
var _bodies_list: Array = []

func all_units() -> Array:
	if _units_dirty or _unit_list.size() != units.size():
		_unit_list = units.values()
		_unit_list.make_read_only()
		_units_dirty = false
	return _unit_list

## Unit coordinates as flat ints in all_units() order (x, y per unit). Scans that reject almost
## the whole army on position alone (firing lines, adjacency) read these instead of every unit.
## Kept by UnitInstance.vision_log: only the units logged since the last call are rewritten.
func unit_xy() -> PackedInt32Array:
	var list := _sync_unit_rows()
	var log := UnitInstance.vision_log
	var k := _xy_pos - UnitInstance.vision_log_start
	while k < log.size():
		var u: UnitInstance = log[k]
		var i: int = _xy_slot.get(u.id, -1)
		if i >= 0 and is_same(list[i], u):
			_xy[i * 2] = u.coord.x
			_xy[i * 2 + 1] = u.coord.y
			_alive[i] = 1 if u.status == MCF.Status.ALIVE else 0
		k += 1
	_xy_pos = UnitInstance.vision_log_end()
	return _xy

## 1 per living unit, 0 otherwise, in all_units() order; kept like unit_xy. Packed arrays are
## shared, not copied: a caller keeping the statuses of a moment duplicates them.
func alive_rows() -> PackedByteArray:
	unit_xy()
	return _alive

## Indices in all_units() of the units on a firing line from `from` (its row, column or a
## diagonal; a unit on `from` itself is not), ascending: what target scans test first, on the
## flat coordinates and natively when the kernel is there.
func slots_on_lines(from: Vector2i) -> PackedInt32Array:
	var xy := unit_xy()
	var native := NativeKernels.ai()
	if native != null:
		return native.line_slots(from, xy)
	var out := PackedInt32Array()
	for i in xy.size() / 2:
		var dx: int = xy[i * 2] - from.x
		var dy: int = xy[i * 2 + 1] - from.y
		if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
			continue
		out.append(i)
	return out

## Indices in all_units() of the units within `radius` cells of `at` (Chebyshev; a unit on `at`
## itself is not), ascending; natively when the kernel is there.
func slots_near(at: Vector2i, radius: int) -> PackedInt32Array:
	var xy := unit_xy()
	var native := NativeKernels.ai()
	if native != null:
		return native.near_slots(at, xy, radius)
	var out := PackedInt32Array()
	for i in xy.size() / 2:
		var dx := absi(xy[i * 2] - at.x)
		var dy := absi(xy[i * 2 + 1] - at.y)
		if dx > radius or dy > radius or (dx == 0 and dy == 0):
			continue
		out.append(i)
	return out

## Indices in all_units() of this state's units logged (UnitInstance.vision_log) since log
## position pos, ascending and unique; null when the log no longer reaches back to pos or the
## unit list is another one than at pos (the caller then looks at everyone).
func units_logged_since(pos: int, list: Array) -> Variant:
	if pos < UnitInstance.vision_log_start or not is_same(list, all_units()):
		return null
	_sync_unit_rows()
	var log := UnitInstance.vision_log
	var out := PackedInt32Array()
	var k := pos - UnitInstance.vision_log_start
	while k < log.size():
		var u: UnitInstance = log[k]
		var i: int = _xy_slot.get(u.id, -1)
		if i >= 0 and is_same(list[i], u):
			out.append(i)
		k += 1
	if out.size() > 1:
		out.sort()
		var w := 1
		for r in range(1, out.size()):
			if out[r] != out[w - 1]:
				out[w] = out[r]
				w += 1
		out.resize(w)
	return out

## u's index in all_units(), or -1 when u is not one of this state's units.
func unit_slot(u: UnitInstance) -> int:
	var list := _sync_unit_rows()
	var i: int = _xy_slot.get(u.id, -1)
	return i if i >= 0 and is_same(list[i], u) else -1

## The slot index and coordinate rows for the current unit list, rebuilt whole when the list
## changes or the log dropped entries this state had not read yet.
func _sync_unit_rows() -> Array:
	var list := all_units()
	if is_same(list, _xy_list) and _xy_pos >= UnitInstance.vision_log_start:
		return list
	_xy_list = list
	_xy_slot.clear()
	_xy.resize(list.size() * 2)
	_alive.resize(list.size())
	for i in list.size():
		var u: UnitInstance = list[i]
		_xy_slot[u.id] = i
		_xy[i * 2] = u.coord.x
		_xy[i * 2 + 1] = u.coord.y
		_alive[i] = 1 if u.status == MCF.Status.ALIVE else 0
	_xy_pos = UnitInstance.vision_log_end()
	return list

var _xy := PackedInt32Array()
var _alive := PackedByteArray()
var _xy_slot: Dictionary = {}   # unit id -> index in _xy_list
var _xy_list: Array = []
var _xy_pos := -1

## Убрать юнита из партии совсем (тело ушло в кучу, переработано боргом и т. п.).
func remove_unit(id: int) -> void:
	units.erase(id)
	_units_dirty = true

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
	_vehicles_dirty = true
	grid.set_vehicle_footprint(veh.id, veh.footprint())
	return veh

func get_vehicle(id: int) -> Vehicle:
	return vehicles.get(id, null)

func all_vehicles() -> Array:
	if _vehicles_dirty or _vehicle_list.size() != vehicles.size():
		_vehicle_list = vehicles.values()
		_vehicle_list.make_read_only()
		_vehicles_dirty = false
	return _vehicle_list

func remove_vehicle(id: int) -> void:
	vehicles.erase(id)
	_vehicles_dirty = true

func vehicle_on(coord: Vector2i) -> Vehicle:
	var vid := grid.vehicle_at(coord)
	return vehicles.get(vid, null) if vid != -1 else null

func living_units_of(owner: int) -> Array:
	var out: Array = []
	for u in all_units():
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
## Короткая подпись доски (batch 14): по ней гость сверяет свою доску с доской хоста
## после каждого действия. Юниты, машины и очередь ходов; клетки не включены — они
## меняются только действиями, а их расхождение всё равно всплывёт через юнитов.
##
## Строки собираются через str(…) с перечнем частей, а не форматом "%d:%d…" % [...]
## (perf pass #11): текст выходит тот же байт в байт — все поля int, а для int "%d" и str()
## пишут одно и то же, — но без массива аргументов и разбора формата на каждого юнита.
## Подпись зовётся на каждом действии у обеих сторон сети.
func digest_hash() -> int:
	var parts: PackedStringArray = []
	var ids: Array = units.keys()
	ids.sort()
	for id: int in ids:
		var u: UnitInstance = units[id]
		var at := u.coord
		parts.append(str(u.id, ":", at.x, ",", at.y, ":", u.owner, ":", u.status, ":",
				u.remaining_ap, ":", u.move_credit, ":", u.aboard_vehicle_id, ":", u.borg_id))
		if u.cheat_invulnerable or not u.cheat_stats.is_empty():
			parts.append(str("uc", u.id, ":", u.cheat_invulnerable, ":", UnitInstance.clean_cheat_stats(u.cheat_stats)))
		if u.corpse_carrier_id >= 0 or u.corpse_stacked:
			parts.append(str("body", u.id, ":", u.corpse_carrier_id, ":", u.corpse_stacked))
	if cheat_sequence != 0 or not cheat_vision.is_empty() or not cheat_mines.is_empty():
		var vision_sides := cheat_vision.keys()
		var mine_sides := cheat_mines.keys()
		vision_sides.sort()
		mine_sides.sort()
		parts.append(str("c", cheat_sequence, ":", vision_sides, ":", mine_sides))
	if not cheat_ai_paused.is_empty():
		var paused := cheat_ai_paused.keys()
		paused.sort()
		parts.append("ai_paused:" + str(paused))
	var vids: Array = vehicles.keys()
	vids.sort()
	for id: int in vids:
		var v: Vehicle = vehicles[id]
		parts.append(str("v", v.id, ":", v.origin.x, ",", v.origin.y, ":", v.owner, ":",
				v.durability, ":", v.ap, ":", 1 if v.wrecked else 0))
	parts.append("t%d:%d:%s" % [turns.round_number, turns.active_index, str(turns.round_order)])
	# Номер косметического события тоже — разойдись он, у гостя полетели бы другие брызги.
	parts.append("f%d" % fx_seq)
	return "|".join(parts).hash()

## with_cells=false — снимок без клеток: откат действия берёт их из журнала клеток
## (GridCell.journal), а не копией всей доски (см. GameActionResolver.resolve()).
func snapshot(with_cells: bool = true) -> Dictionary:
	var us: Array = []
	for u: UnitInstance in all_units():
		var ast: Dictionary = {}
		if u.action_state != null:
			ast = {"target_id": u.action_state.target_id,
					"remaining_shots": u.action_state.remaining_shots, "dpmg": u.action_state.dpmg}
		us.append({
			"obj": u, "id": u.id, "coord": u.coord, "owner": u.owner,
			"remaining_ap": u.remaining_ap, "status": u.status,
			"held_item_id": u.held_item_id, "captor_id": u.captor_id,
			"is_drone": u.is_drone, "home_station": u.home_station,
			"operator_id": u.operator_id, "wall_entry_from": u.wall_entry_from,
				"civilian_active": u.civilian_active,
			"neutral_group": u.neutral_group,
			"carried_this_round": u.carried_this_round,
			"aboard_vehicle_id": u.aboard_vehicle_id, "dig_credits": u.dig_credits,
			"borg_id": u.borg_id, "build_credits": u.build_credits.duplicate(),
			"ldf_wall_used": u.ldf_wall_used, "move_credit": u.move_credit,
			"mine_credits": u.mine_credits,
			"carried_corpses": u.carried_corpses, "dragging": u.dragging, "burnt": u.burnt,
			"corpse_carrier_id": u.corpse_carrier_id, "corpse_stacked": u.corpse_stacked,
			"action_state": ast, "cheat_stats": u.cheat_stats.duplicate(), "cheat_invulnerable": u.cheat_invulnerable,
		})
	var vs: Array = []
	for v: Vehicle in all_vehicles():
		vs.append({
			"obj": v, "id": v.id, "owner": v.owner, "durability": v.durability,
			"components": v.components.duplicate(), "tower_locked_dir": v.tower_locked_dir,
			"origin": v.origin, "size": v.size, "facing": v.facing, "ap": v.ap,
			"occupants": v.occupants.duplicate(),
			"corpse_slots": v.corpse_slots.duplicate(),
			"seats": v.seats.duplicate(), "wrecked": v.wrecked,
			"cannon_shots_this_round": v.cannon_shots_this_round,
			"move_credit": v.move_credit,
		})
	var cs: Array = []
	for c: GridCell in grid._cells if with_cells else []:
		cs.append({
			"floor_type": c.floor_type, "cover_height": c.cover_height,
			"on_fire": c.on_fire, "fire_owner": c.fire_owner, "is_space": c.is_space,
			"fire_suppressed_until": c.fire_suppressed_until,
			"occupant_id": c.occupant.id if c.occupant != null else -1,
			"vehicle_id": c.vehicle_id, "feature_id": c.feature_id,
			"feature_owner": c.feature_owner, "feature_durability": c.feature_durability,
			"station_operator_id": c.station_operator_id,
			"corpse_count": c.corpse_count, "dirt_level": c.dirt_level,
			"airlock_welded": c.airlock_welded, "fixture": c.lamps.duplicate(true),
		})
	return {
		"units": us, "vehicles": vs, "cells": cs,
		"active_index": turns.active_index, "round_number": turns.round_number,
		"round_order": turns.round_order.duplicate(),
		"wave_owner": turns.wave_owner,
		"turn_eliminated": turns.eliminated.duplicate(),
		"roster": roster.snapshot(),
		"revealed_mines": _snapshot_revealed_mines(),
		"cheat_vision": cheat_vision.duplicate(), "cheat_mines": cheat_mines.duplicate(),
		"cheat_ai_paused": cheat_ai_paused.duplicate(),
		"cheat_sequence": cheat_sequence, "cheats_enabled": cheats_enabled,
		"next_id": _next_id, "next_vehicle_id": _next_vehicle_id,
		"combat_started": combat_started,
		"kills": kills.duplicate(true),
		"deaths": deaths.duplicate(true),
	}

## Moves on every resolve() and restore(): the battle screen redoes per-soldier work only
## when the battle could have changed (MainDrawing._sync_unit_layer).
var revision := 0

## Откатить состояние к ранее взятому снимку (см. snapshot()).
func restore(snap: Dictionary) -> void:
	revision += 1
	cheats_enabled = snap.get("cheats_enabled", false) is bool and snap.get("cheats_enabled", false)
	cheat_vision = clean_cheat_sides(snap.get("cheat_vision", {}))
	cheat_ai_paused = clean_cheat_sides(snap.get("cheat_ai_paused", {}))
	cheat_mines = clean_cheat_sides(snap.get("cheat_mines", {}))
	cheat_sequence = clampi(int(snap.get("cheat_sequence", 0)), 0, 2147483647) if CheatCommands._integer(snap.get("cheat_sequence", 0)) else 0
	kills = (snap.get("kills", {}) as Dictionary).duplicate(true)
	deaths = (snap.get("deaths", {}) as Dictionary).duplicate(true)
	units.clear()
	_units_dirty = true
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
		u.neutral_group = rec.get("neutral_group", 0)
		u.carried_this_round = rec["carried_this_round"]
		u.aboard_vehicle_id = rec["aboard_vehicle_id"]
		u.borg_id = int(rec.get("borg_id", -1))
		u.build_credits = (rec.get("build_credits", {}) as Dictionary).duplicate()
		u.dig_credits = rec["dig_credits"]
		u.ldf_wall_used = rec["ldf_wall_used"]
		u.move_credit = rec["move_credit"]
		u.mine_credits = rec.get("mine_credits", 0)
		u.carried_corpses = rec["carried_corpses"]
		u.corpse_carrier_id = int(rec.get("corpse_carrier_id", -1))
		u.corpse_stacked = bool(rec.get("corpse_stacked", false))
		u.burnt = bool(rec.get("burnt", false))
		u.cheat_invulnerable = rec.get("cheat_invulnerable", false) is bool and rec.get("cheat_invulnerable", false)
		u.cheat_stats = UnitInstance.clean_cheat_stats(rec.get("cheat_stats", {}))
		u.dragging = rec["dragging"]
		var ast: Dictionary = rec["action_state"]
		if ast.is_empty():
			u.action_state = null
		else:
			var a := ActionState.new()
			a.target_id = ast["target_id"]
			a.remaining_shots = ast["remaining_shots"]
			a.dpmg = ast.get("dpmg", ActionState.NO_DPMG)
			u.action_state = a
		units[u.id] = u
	vehicles.clear()
	_vehicles_dirty = true
	for rec: Dictionary in snap["vehicles"]:
		var v: Vehicle = rec["obj"]
		v.owner = rec["owner"]
		# Узлы восстанавливаем ДО корпуса: durability — это ячейка components, и запись
		# в него после присвоения словаря иначе затёрлась бы старым значением.
		if rec.has("components"):
			v.components = (rec["components"] as Dictionary).duplicate()
		v.tower_locked_dir = rec.get("tower_locked_dir", Vector2i.ZERO)
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
	# Клетки из журнала отката: {GridCell: image()} — только те, что трогало действие.
	var images: Variant = snap.get("cells")
	if images is Dictionary:
		for c: GridCell in images:
			c.apply_image(images[c])
	var cells: Array = images if images is Array else []
	for i in cells.size():
		var rec: Dictionary = cells[i]
		var c: GridCell = grid._cells[i]
		c.floor_type = rec["floor_type"]
		c.cover_height = rec["cover_height"]
		c.on_fire = rec["on_fire"]
		c.fire_owner = rec["fire_owner"]
		c.fire_suppressed_until = int(rec.get("fire_suppressed_until", 0))
		c.is_space = rec["is_space"]
		var oid: int = rec["occupant_id"]
		c.occupant = units.get(oid, null) if oid != -1 else null
		c.vehicle_id = rec["vehicle_id"]
		c.feature_id = rec["feature_id"]
		c.station_operator_id = int(rec.get("station_operator_id", -1))
		c.feature_owner = rec["feature_owner"]
		c.feature_durability = rec["feature_durability"]
		c.corpse_count = rec["corpse_count"]
		c.dirt_level = rec["dirt_level"]
		c.airlock_welded = rec["airlock_welded"]
		c.lamps = rec.get("fixture", [])
		c.items_off = int(rec.get("items_off", 0))
	turns.active_index = snap["active_index"]
	turns.round_number = snap["round_number"]
	# Порядок инициативы теперь ИЗМЕНЯЕМ по ходу боя: группы нейтралов встают в
	# очередь по мере активации (§15). Значит откат обязан возвращать и его —
	# иначе Undo оставил бы в очереди группу, которой на доске уже нет.
	if snap.has("round_order"):
		turns.round_order = (snap["round_order"] as Array[int]).duplicate()
	if snap.has("wave_owner"):
		turns.wave_owner = int(snap["wave_owner"])
	if snap.has("turn_eliminated"):
		turns.eliminated = (snap["turn_eliminated"] as Dictionary).duplicate()
	if snap.has("roster"):
		roster.restore(snap["roster"])
	if snap.has("revealed_mines"):
		revealed_mines = _restore_revealed_mines(snap["revealed_mines"])
	_next_id = snap["next_id"]
	_next_vehicle_id = snap["next_vehicle_id"]
	combat_started = snap.get("combat_started", combat_started)

## Подсветка мин — вложенные словари, поэтому duplicate() их бы не отвязал: копия
## первого уровня продолжила бы делить внутренние словари со снимком, и откат вернул
## бы ровно то, что откатывает.
func _snapshot_revealed_mines() -> Dictionary:
	var out := {}
	for owner: int in revealed_mines:
		out[owner] = (revealed_mines[owner] as Dictionary).duplicate()
	return out

func _restore_revealed_mines(snap: Dictionary) -> Dictionary:
	var out := {}
	for owner: int in snap:
		out[owner] = (snap[owner] as Dictionary).duplicate()
	return out
