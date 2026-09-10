extends SceneTree

## Каждое поле намерения обязано ехать по проводу.
##
## Это ЕДИНСТВЕННЫЙ класс ошибок, который уже дважды прошёл в проект незамеченным:
## MoveIntent.carry_drop (#100) и DigIntent.dirt_a/dirt_b (AUDIT §2.2). Обе выглядят
## одинаково — поле есть в намерении, в IntentCodec его нет, клиент получает
## sentinel и молча решает по-своему. Ни компилятор, ни обычный прогон партии
## этого не видят: доски расходятся только когда игрок ВЫБРАЛ значение вручную,
## а ИИ его не выбирает никогда.
##
## Поэтому проверка не на примерах, а сплошная: каждый подкласс Intent набивается
## заметными значениями, гоняется через encode/decode и сверяется ПО ВСЕМ своим
## свойствам, какие объявлены в скрипте. Новое поле, забытое в кодеке, валит тест
## само, без дописывания проверок.

var fails: PackedStringArray = []

## По образцу на класс. Значения нарочно «странные» — sentinel и нули прошли бы
## и через сломанный кодек.
func _samples() -> Array:
	var cells: Array[Vector2i] = [Vector2i(3, 4), Vector2i(4, 4), Vector2i(5, 4)]
	return [
		EndTurnIntent.new(),
		EndTurnIntent.new(3),
		UndoIntent.new(2),
		RedoIntent.new(2),
		GroupMoveIntent.new([4, 9, 16] as Array[int],
				[Vector2i(1, 2), Vector2i(3, 4), Vector2i(5, 6)] as Array[Vector2i]),
		MoveIntent.new(7, Vector2i(11, 13), Vector2i(9, 8)),
		ShootIntent.new(7, 12, 3, Vector2i(19, 21)),
		CaptureIntent.new(7, 12),
		ReleaseIntent.new(7),
		CancelShotIntent.new(7),
		PickUpStationIntent.new(7, Vector2i(4, 9)),
		MoveHeldIntent.new(7, Vector2i(6, 5)),
		UseItemIntent.new(7, Vector2i(14, 2)),
		PushIntent.new(7, 12),
		SpawnDroneIntent.new(7, Vector2i(5, 6)),
		DroneMoveIntent.new(7, Vector2i(22, 17)),
		DroneDetonateIntent.new(7),
		BuildIntent.new(7, Vector2i(8, 9), MCF.FEATURE_SANDBAGS),
		BreakIntent.new(7, Vector2i(1, 2)),
		DragIntent.new(7, Vector2i(4, 5), Vector2i(4, 6)),
		DPMGFireIntent.new(7, Vector2i(10, 10), 12, 5),
		DigIntent.new(7, Vector2i(15, 16), Vector2i(15, 17), Vector2i(14, 16)),
		BuildWallIntent.new(7, cells),
		PickUpCorpseIntent.new(7, Vector2i(2, 3)),
		DropCorpseIntent.new(7, Vector2i(3, 2)),
		VehicleBoardIntent.new(7, 1000),
		VehicleDisembarkIntent.new(7, Vector2i(5, 5)),
		VehicleTurnIntent.new(1000, Vector2i(1, -1)),
		VehicleMoveIntent.new(1000, Vector2i(-1, 0), 4),
		VehicleCannonIntent.new(1000, Vector2i(20, 20)),
		VehicleMeleeIntent.new(7, 3000000),
		RepairVehicleIntent.new(7, 3000000, MCF.COMP_TRACKS),
		VehicleUnloadCorpseIntent.new(7, 3000000),
		WeldAirlockIntent.new(7, Vector2i(7, 7)),
		PlaceMineIntent.new(7, Vector2i(12, 3)),
		PlaceMineIntent.new(7, Vector2i(12, 4), true),
		RevealMinesIntent.new(7),
		DisarmMineIntent.new(7, Vector2i(12, 3)),
		# Копка БЕЗ выбранных куч: sentinel обязан пережить провод нетронутым,
		# иначе автоматический выбор превратится в выбор игрока (и наоборот).
		DigIntent.new(7, Vector2i(15, 16)),
		MoveIntent.new(7, Vector2i(11, 13)),
	]

func _initialize() -> void:
	var covered := {}
	for intent: Intent in _samples():
		var cls := _class_of(intent)
		covered[cls] = true
		_round_trip(intent, cls)
	_check_coverage(covered)
	_check_state_codec()
	if fails.is_empty():
		print("codec: every intent field survives the wire, every state field the file")
		quit(0)
		return
	printerr("codec: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func _round_trip(intent: Intent, cls: String) -> void:
	var wire := IntentCodec.encode(intent)
	if wire.is_empty():
		fails.append("%s: encode() produced nothing — no branch in IntentCodec" % cls)
		return
	var back := IntentCodec.decode(wire)
	if back == null:
		fails.append("%s: decode() returned null for %s" % [cls, str(wire)])
		return
	if _class_of(back) != cls:
		fails.append("%s: decoded as %s" % [cls, _class_of(back)])
		return
	for prop in intent.get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var name: String = prop["name"]
		var want: Variant = intent.get(name)
		var got: Variant = back.get(name)
		if str(want) != str(got):
			fails.append("%s.%s did not survive the wire: sent %s, got %s"
					% [cls, name, str(want), str(got)])

## Каждый подкласс Intent на диске обязан быть в образцах — иначе новое намерение
## можно добавить, забыть про кодек, и проверка этого не заметит.
func _check_coverage(covered: Dictionary) -> void:
	var d := DirAccess.open("res://src/intents")
	if d == null:
		fails.append("cannot list res://src/intents")
		return
	for f in d.get_files():
		if not f.ends_with(".gd") or f == "Intent.gd":
			continue
		var cls := f.get_basename()
		if not covered.has(cls):
			fails.append("%s has no sample in tests/run_codec.gd — add one" % cls)

func _class_of(o: Object) -> String:
	var sc: Script = o.get_script()
	return sc.resource_path.get_file().get_basename() if sc != null else "?"

# --- Состояние партии на диск и обратно (M12) --------------------------------
##
## Та же болезнь, что и у намерений, только дороже: поле есть в UnitInstance или
## GridCell, в StateCodec его нет — и сохранённая партия продолжается с чуть-чуть
## другой доски. Поймать это игрой почти невозможно (потеряется мелочь вроде
## «мина уже подсвечена»), поэтому проверка тоже сплошная и рефлексивная.
##
## Вторая проверка здесь — на ЖИВУЮ ССЫЛКУ в снимке. Массивы в Godot ссылочные, и
## encode(), положивший в словарь сам массив партии вместо копии, даёт файл, который
## продолжает меняться вместе с боем: стартовый кадр повтора уезжал на диск с
## порядком инициативы, сложившимся к концу партии.

const TS = preload("res://tests/TestSupport.gd")

## Поля-объекты сверяются отдельно: str() от объекта — это его адрес в памяти,
## он различается у любых двух копий.
const OBJECT_FIELDS := ["stats", "action_state", "occupant"]

func _check_state_codec() -> void:
	var state := TS.build_state()
	var resolver := GameActionResolver.new(state)
	_play_a_while(state, resolver)
	_touch_every_field(state)

	var wire := StateCodec.encode(state)
	var frozen := JSON.stringify(wire)
	var back := StateCodec.decode(JSON.parse_string(frozen))
	if back == null:
		fails.append("StateCodec.decode() refused its own output")
		return
	if TS.digest(back) != TS.digest(state):
		fails.append("StateCodec: the board changed on its way through the file")
	_compare_units(state, back)
	_compare_vehicles(state, back)
	_compare_cells(state, back)
	if str(state.revealed_mines) != str(back.revealed_mines):
		fails.append("StateCodec: revealed mines did not survive the file")
	if state.roster.to_dict() != back.roster.to_dict():
		fails.append("StateCodec: the roster did not survive the file")

	# Снимок обязан быть мёртвым: партия идёт дальше, а он — нет.
	state.turns.round_order.append(MCF.neutral_group_slot(9))
	state.turns.round_number += 1
	for v: Vehicle in state.all_vehicles():
		v.occupants.append(999)
		v.seats.append(999)
		v.corpse_slots.append("ghost")
	if JSON.stringify(wire) != frozen:
		fails.append("StateCodec.encode() kept a live reference into the match: "
				+ "the snapshot changed by itself while the game went on")

## Тронуть КАЖДОЕ изменяемое поле, какое бывает у юнита, машины и клетки. Без этого
## проверка сверяет в основном нули: сапёра в тестовом ростере нет, окопов за два
## раунда никто не выроет, — и поле, забытое в кодеке, совпало бы «по умолчанию».
## Значения намеренно нелепые: реальная партия таких не даст, поэтому подмена видна.
func _touch_every_field(state: GameState) -> void:
	var ids: Array = state.units.keys()
	ids.sort()
	for i in mini(4, ids.size()):
		var u: UnitInstance = state.units[ids[i]]
		u.remaining_ap = 1 + i
		u.held_item_id = MCF.ITEM_FRAG
		u.captor_id = int(ids[(i + 1) % ids.size()])
		u.is_drone = i == 0
		u.home_station = Vector2i(2 + i, 3)
		u.operator_id = int(ids[0])
		u.wall_entry_from = Vector2i(4, 5 + i)
		u.civilian_active = true
		u.neutral_group = 7 + i
		u.carried_this_round = true
		u.aboard_vehicle_id = Vehicle.ID_BASE
		u.dig_credits = 2 + i
		u.ldf_wall_used = true
		u.move_credit = 3 + i
		u.mine_credits = 4 + i
		u.carried_corpses = 1 + i
		u.dragging = Vector2i(6, 7 + i)
		var act := ActionState.new()
		act.target_id = int(ids[(i + 2) % ids.size()])
		act.remaining_shots = 2 + i
		u.action_state = act
	for v: Vehicle in state.all_vehicles():
		v.durability -= 1
		v.facing = Vector2i(-1, 1)
		v.ap = 3
		v.wrecked = true
		v.cannon_shots_this_round = 1
		v.move_credit = 2
		v.ensure_seats()
		v.corpse_slots.append("light_infantry")
	var touched := 0
	for y in state.grid.height:
		for x in state.grid.width:
			var c := state.grid.cell(Vector2i(x, y))
			if c.occupant != null or c.vehicle_id != -1 or touched >= 6:
				continue
			touched += 1
			c.floor_type = MCF.FLOOR_FLAMMABLE
			c.cover_height = 0.5 * float(1 + touched % 3)
			c.on_fire = true
			c.fire_owner = MCF.Owner.PLAYER_2
			c.fire_suppressed_until = 9 + touched
			c.is_space = true
			c.feature_id = MCF.FEATURE_SANDBAGS
			c.feature_owner = MCF.Owner.PLAYER_1
			c.feature_durability = 2
			c.station_operator_id = int(ids[0])
			c.corpse_count = touched
			c.dirt_level = 1 + touched % 4
			c.airlock_welded = true
	# Подсветка мин — вложенные словари с ключами-клетками: их формат ломается легче всего.
	state.revealed_mines = {
		MCF.Owner.PLAYER_1: {Vector2i(3, 4): 7, Vector2i(5, 6): 9},
		MCF.Owner.PLAYER_2: {Vector2i(3, 4): 8},
	}
	state.combat_started = true
	state.roster.set_eliminated(MCF.Owner.PLAYER_2, true)
	state.turns.mark_eliminated(MCF.Owner.PLAYER_2)

## Немного погонять партию, чтобы в состоянии появилось что терять: ходы, огонь,
## трупы, разбуженные нейтралы и сдвинутый порядок инициативы.
func _play_a_while(state: GameState, resolver: GameActionResolver) -> void:
	var brains := {}
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var ai := AIController.new(side, AIController.Difficulty.NORMAL)
		ai.intent_ready.connect(_on_ai_intent)
		brains[side] = ai
	var stop := state.turns.round_number + 2
	var guard := 0
	while state.turns.round_number < stop and guard < 2000:
		guard += 1
		var ai: AIController = brains.get(state.active_player(), null)
		if ai == null:
			resolver.resolve(EndTurnIntent.new())
			continue
		_ai_intent = null
		ai.begin_turn(state)
		if _ai_intent == null:
			resolver.resolve(EndTurnIntent.new())
			continue
		if not resolver.resolve(_ai_intent).ok:
			ai.notify_intent_denied(state)

var _ai_intent: Intent = null

func _on_ai_intent(intent: Intent) -> void:
	if _ai_intent == null:
		_ai_intent = intent

func _compare_units(a: GameState, b: GameState) -> void:
	if a.units.size() != b.units.size():
		fails.append("StateCodec: %d units went in, %d came out"
				% [a.units.size(), b.units.size()])
		return
	for id: int in a.units:
		var want: UnitInstance = a.units[id]
		var got: UnitInstance = b.units.get(id, null)
		if got == null:
			fails.append("StateCodec: unit %d is missing after the round trip" % id)
			continue
		_compare_fields("UnitInstance[%d]" % id, want, got)
		var want_stats := want.stats.id if want.stats != null else ""
		var got_stats := got.stats.id if got.stats != null else ""
		if want_stats != got_stats:
			fails.append("StateCodec: unit %d changed stats: %s -> %s"
					% [id, want_stats, got_stats])
		if (want.action_state == null) != (got.action_state == null):
			fails.append("StateCodec: unit %d lost its split action" % id)
		elif want.action_state != null \
				and (want.action_state.target_id != got.action_state.target_id
				or want.action_state.remaining_shots != got.action_state.remaining_shots):
			fails.append("StateCodec: unit %d split action did not survive" % id)

func _compare_vehicles(a: GameState, b: GameState) -> void:
	for id: int in a.vehicles:
		var got: Vehicle = b.vehicles.get(id, null)
		if got == null:
			fails.append("StateCodec: vehicle %d is missing after the round trip" % id)
			continue
		_compare_fields("Vehicle[%d]" % id, a.vehicles[id], got)

func _compare_cells(a: GameState, b: GameState) -> void:
	for y in a.grid.height:
		for x in a.grid.width:
			var coord := Vector2i(x, y)
			var want := a.grid.cell(coord)
			var got := b.grid.cell(coord)
			_compare_fields("GridCell%s" % str(coord), want, got)
			var want_id: int = want.occupant.id if want.occupant != null else -1
			var got_id: int = got.occupant.id if got.occupant != null else -1
			if want_id != got_id:
				fails.append("StateCodec: cell %s holds %d instead of %d"
						% [str(coord), got_id, want_id])

## Сверить ВСЕ объявленные в скрипте поля объекта. Именно сплошной перебор, а не
## список: новое поле нельзя добавить и забыть про сохранение.
func _compare_fields(label: String, want: Object, got: Object) -> void:
	for prop in want.get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var name: String = prop["name"]
		if name in OBJECT_FIELDS:
			continue
		if str(want.get(name)) != str(got.get(name)):
			fails.append("%s.%s did not survive the file: was %s, became %s"
					% [label, name, str(want.get(name)), str(got.get(name))])
