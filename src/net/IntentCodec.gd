class_name IntentCodec
extends RefCounted

## Сериализация Intent'ов для сети (M7, §2.2, §2.3). Каждое намерение кодируется
## в словарь с тегом типа "t" и полями; JSON-совместимо (Vector2i → пара x/y).
## Мутации по-прежнему делает только резолвер — по сети едут лишь намерения.

const T_END := "end"
const T_MOVE := "move"
const T_SHOOT := "shoot"
const T_CAPTURE := "capture"
const T_RELEASE := "release"
const T_MOVE_HELD := "move_held"
const T_ITEM := "item"
const T_PUSH := "push"
const T_SPAWN_DRONE := "spawn_drone"
const T_DRONE_MOVE := "drone_move"
const T_DRONE_DET := "drone_det"
const T_BUILD := "build"
const T_BREAK := "break"
const T_DRAG := "drag"
const T_DPMG := "rsp"
const T_DIG := "dig"
const T_UNDO := "undo"
const T_REDO := "redo"
const T_GROUP_MOVE := "gmove"
const T_MINE := "mine"
const T_SWEEP := "sweep"
const T_DISARM := "disarm"
const T_BUILD_WALL := "build_wall"
const T_CORPSE_UP := "corpse_up"
const T_CANCEL_SHOT := "cancel_shot"
const T_STATION_UP := "station_up"
const T_CORPSE_DOWN := "corpse_down"
const T_VEH_BOARD := "veh_board"
const T_VEH_OUT := "veh_out"
const T_VEH_TURN := "veh_turn"
const T_VEH_MOVE := "veh_move"
const T_VEH_CANNON := "veh_cannon"
const T_VEH_MELEE := "veh_melee"
const T_WELD := "weld"

static func encode(intent: Intent) -> Dictionary:
	if intent is EndTurnIntent:
		return {"t": T_END, "q": intent.requester}
	if intent is PlaceMineIntent:
		return {"t": T_MINE, "a": intent.actor_id,
			"x": intent.target.x, "y": intent.target.y,
			"av": 1 if intent.anti_vehicle else 0}
	if intent is RevealMinesIntent:
		return {"t": T_SWEEP, "a": intent.actor_id}
	if intent is DisarmMineIntent:
		return {"t": T_DISARM, "a": intent.actor_id,
			"x": intent.target.x, "y": intent.target.y}
	if intent is UndoIntent:
		return {"t": T_UNDO, "q": intent.requester}
	if intent is RedoIntent:
		return {"t": T_REDO, "q": intent.requester}
	if intent is GroupMoveIntent:
		# Пары «юнит → клетка» плоским списком: распределение считается ОДИН раз,
		# у отдавшего приказ, и едет готовым (item 34).
		var flat: Array = []
		for i in intent.unit_ids.size():
			var t: Vector2i = intent.targets[i]
			flat.append(intent.unit_ids[i])
			flat.append(t.x)
			flat.append(t.y)
		return {"t": T_GROUP_MOVE, "a": intent.actor_id, "g": flat}
	if intent is MoveIntent:
		# carry_drop обязателен в пакете (#100): без него клиент клал бы пленника
		# на авто-клетку, а хост — на выбранную игроком, и состояния разошлись бы.
		return {"t": T_MOVE, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y,
			"dx": intent.carry_drop.x, "dy": intent.carry_drop.y}
	if intent is ShootIntent:
		# target_cell нужен для выстрела противотанкиста по полу (§3.14) — без него
		# клиент воспроизводил бы «выстрел в никуда» и расходился с хостом.
		return {"t": T_SHOOT, "a": intent.actor_id, "tid": intent.target_id, "s": intent.shots,
			"cx": intent.target_cell.x, "cy": intent.target_cell.y}
	if intent is CaptureIntent:
		return {"t": T_CAPTURE, "a": intent.actor_id, "tid": intent.target_id}
	if intent is ReleaseIntent:
		return {"t": T_RELEASE, "a": intent.actor_id}
	if intent is CancelShotIntent:
		return {"t": T_CANCEL_SHOT, "a": intent.actor_id}
	if intent is PickUpStationIntent:
		return {"t": T_STATION_UP, "a": intent.actor_id,
			"x": intent.coord.x, "y": intent.coord.y}
	if intent is MoveHeldIntent:
		return {"t": T_MOVE_HELD, "a": intent.actor_id, "x": intent.to.x, "y": intent.to.y}
	if intent is UseItemIntent:
		return {"t": T_ITEM, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y}
	if intent is PushIntent:
		return {"t": T_PUSH, "a": intent.actor_id, "tid": intent.target_id}
	if intent is SpawnDroneIntent:
		# Клетка станции (item 17) едет вместе с намерением: у оператора их может
		# быть несколько, и выбор игрока обязан доехать до хоста без подмены.
		return {"t": T_SPAWN_DRONE, "a": intent.actor_id,
			"x": intent.station.x, "y": intent.station.y}
	if intent is DroneMoveIntent:
		return {"t": T_DRONE_MOVE, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y}
	if intent is DroneDetonateIntent:
		return {"t": T_DRONE_DET, "a": intent.actor_id}
	if intent is BuildIntent:
		return {"t": T_BUILD, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y, "f": intent.feature_id}
	if intent is BreakIntent:
		return {"t": T_BREAK, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y}
	if intent is DragIntent:
		return {"t": T_DRAG, "a": intent.actor_id,
			"ox": intent.object_coord.x, "oy": intent.object_coord.y,
			"x": intent.dest_coord.x, "y": intent.dest_coord.y}
	if intent is DPMGFireIntent:
		return {"t": T_DPMG, "a": intent.actor_id,
			"x": intent.dpmg_coord.x, "y": intent.dpmg_coord.y,
			"tid": intent.target_id, "s": intent.shots}
	if intent is DigIntent:
		# Обе кучи вынутой земли ОБЯЗАНЫ ехать по проводу (AUDIT §2.2). Игрок
		# выбирает их третьим кликом, а в пакет они не попадали — клиент видел
		# sentinel и раскладывал землю АВТОМАТИЧЕСКИ, по своему порядку клеток.
		# Кучи меняют и стоимость прохода, и линию огня, так что доски расходились
		# и больше не сходились. Это ровно та ошибка, что #100 уже чинил для
		# MoveIntent.carry_drop, — на одно намерение дальше.
		return {"t": T_DIG, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y,
			"ax": intent.dirt_a.x, "ay": intent.dirt_a.y,
			"bx": intent.dirt_b.x, "by": intent.dirt_b.y}
	if intent is BuildWallIntent:
		var pts: Array = []
		for c: Vector2i in intent.cells:
			pts.append(c.x)
			pts.append(c.y)
		return {"t": T_BUILD_WALL, "a": intent.actor_id, "c": pts}
	if intent is PickUpCorpseIntent:
		return {"t": T_CORPSE_UP, "a": intent.actor_id, "x": intent.from.x, "y": intent.from.y}
	if intent is DropCorpseIntent:
		return {"t": T_CORPSE_DOWN, "a": intent.actor_id, "x": intent.to.x, "y": intent.to.y}
	if intent is WeldAirlockIntent:
		return {"t": T_WELD, "a": intent.actor_id, "x": intent.to.x, "y": intent.to.y}
	if intent is VehicleBoardIntent:
		return {"t": T_VEH_BOARD, "a": intent.actor_id, "v": intent.vehicle_id}
	if intent is VehicleDisembarkIntent:
		return {"t": T_VEH_OUT, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y}
	if intent is VehicleTurnIntent:
		return {"t": T_VEH_TURN, "a": intent.actor_id, "x": intent.facing.x, "y": intent.facing.y}
	if intent is VehicleMoveIntent:
		return {"t": T_VEH_MOVE, "a": intent.actor_id, "x": intent.dir.x, "y": intent.dir.y,
			"s": intent.steps}
	if intent is VehicleCannonIntent:
		return {"t": T_VEH_CANNON, "a": intent.actor_id, "x": intent.target.x, "y": intent.target.y}
	if intent is VehicleMeleeIntent:
		return {"t": T_VEH_MELEE, "a": intent.actor_id, "v": intent.vehicle_id}
	return {}

static func decode(d: Dictionary) -> Intent:
	var t: String = d.get("t", "")
	var a: int = int(d.get("a", -1))
	var coord := Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	match t:
		T_END: return EndTurnIntent.new(int(d.get("q", -1)))
		T_MINE: return PlaceMineIntent.new(a, coord, int(d.get("av", 0)) == 1)
		T_SWEEP: return RevealMinesIntent.new(a)
		T_DISARM: return DisarmMineIntent.new(a, coord)
		T_UNDO: return UndoIntent.new(int(d.get("q", -1)))
		T_REDO: return RedoIntent.new(int(d.get("q", -1)))
		T_GROUP_MOVE:
			var flat: Array = d.get("g", [])
			var ids: Array[int] = []
			var dests: Array[Vector2i] = []
			for i in range(0, flat.size() - 2, 3):
				ids.append(int(flat[i]))
				dests.append(Vector2i(int(flat[i + 1]), int(flat[i + 2])))
			return GroupMoveIntent.new(ids, dests)
		T_MOVE: return MoveIntent.new(a, coord,
			Vector2i(int(d.get("dx", -999)), int(d.get("dy", -999))))
		T_SHOOT: return ShootIntent.new(a, int(d.get("tid", -1)), int(d.get("s", -1)),
			Vector2i(int(d.get("cx", -999)), int(d.get("cy", -999))))
		T_CAPTURE: return CaptureIntent.new(a, int(d.get("tid", -1)))
		T_RELEASE: return ReleaseIntent.new(a)
		T_CANCEL_SHOT: return CancelShotIntent.new(a)
		T_STATION_UP: return PickUpStationIntent.new(a, coord)
		T_MOVE_HELD: return MoveHeldIntent.new(a, coord)
		T_ITEM: return UseItemIntent.new(a, coord)
		T_PUSH: return PushIntent.new(a, int(d.get("tid", -1)))
		T_SPAWN_DRONE: return SpawnDroneIntent.new(a,
			Vector2i(int(d.get("x", -999)), int(d.get("y", -999))))
		T_DRONE_MOVE: return DroneMoveIntent.new(a, coord)
		T_DRONE_DET: return DroneDetonateIntent.new(a)
		T_BUILD: return BuildIntent.new(a, coord, str(d.get("f", "")))
		T_BREAK: return BreakIntent.new(a, coord)
		T_DRAG: return DragIntent.new(a, Vector2i(int(d.get("ox", 0)), int(d.get("oy", 0))), coord)
		T_DPMG: return DPMGFireIntent.new(a, coord, int(d.get("tid", -1)), int(d.get("s", -1)))
		T_DIG: return DigIntent.new(a, coord,
			Vector2i(int(d.get("ax", -999)), int(d.get("ay", -999))),
			Vector2i(int(d.get("bx", -999)), int(d.get("by", -999))))
		T_BUILD_WALL:
			var pts: Array = d.get("c", [])
			var cells: Array[Vector2i] = []
			for i in range(0, pts.size() - 1, 2):
				cells.append(Vector2i(int(pts[i]), int(pts[i + 1])))
			return BuildWallIntent.new(a, cells)
		T_CORPSE_UP: return PickUpCorpseIntent.new(a, coord)
		T_CORPSE_DOWN: return DropCorpseIntent.new(a, coord)
		T_WELD: return WeldAirlockIntent.new(a, coord)
		T_VEH_BOARD: return VehicleBoardIntent.new(a, int(d.get("v", -1)))
		T_VEH_OUT: return VehicleDisembarkIntent.new(a, coord)
		T_VEH_TURN: return VehicleTurnIntent.new(a, coord)
		T_VEH_MOVE: return VehicleMoveIntent.new(a, coord, int(d.get("s", 1)))
		T_VEH_CANNON: return VehicleCannonIntent.new(a, coord)
		T_VEH_MELEE: return VehicleMeleeIntent.new(a, int(d.get("v", -1)))
	return null
