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
		MoveHeldIntent.new(7, Vector2i(6, 5)),
		UseItemIntent.new(7, Vector2i(14, 2)),
		PushIntent.new(7, 12),
		SpawnDroneIntent.new(7),
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
		WeldAirlockIntent.new(7, Vector2i(7, 7)),
		PlaceMineIntent.new(7, Vector2i(12, 3)),
		RevealMinesIntent.new(7),
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
	if fails.is_empty():
		print("codec: every intent field survives the wire")
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
