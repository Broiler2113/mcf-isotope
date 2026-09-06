extends SceneTree

## Лок-степ на ДЕЙСТВИЯХ ИГРОКА, которых ИИ не совершает никогда.
##
## Обычный прогон партии (run_headless/run_lockstep) ведёт ИИ, а он не выбирает
## руками, куда сложить землю, не отдаёт групповых приказов и не жмёт «Отменить».
## Ровно поэтому три ошибки из майлстоуна 08 и жили в проекте незамеченными: они
## проявляются только тогда, когда значение ВЫБРАЛ человек.
##
## Сценарий прогоняется как настоящая сетевая партия: ведущая сторона резолвит и
## записывает броски, ведомая получает то же намерение через IntentCodec и те же
## броски, и после КАЖДОГО действия доски сверяются целиком.

const TS = preload("res://tests/TestSupport.gd")

var fails: PackedStringArray = []
var host: GameState
var client: GameState
var r_host: GameActionResolver
var r_client: GameActionResolver

func _initialize() -> void:
	host = TS.build_state()
	client = TS.build_state()
	r_host = GameActionResolver.new(host)
	r_client = GameActionResolver.new(client)
	r_host.fog_enabled = false
	r_client.fog_enabled = false
	# Слот мирных может стоять первым — доигрываем его на обеих сторонах, иначе
	# ход начнётся с разных досок.
	_sync("opening civilians",
			func(): return r_host.play_civilian_slots(),
			func(): return r_client.play_civilian_slots())
	_ensure_player_turn()

	_dig_with_chosen_dirt()
	_group_move()
	_undo_redo()
	_end_turn_authority()

	if fails.is_empty():
		print("player actions: dig, group move, undo/redo and authority all agree")
		quit(0)
		return
	printerr("player actions: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

## Довести обе стороны до хода первого игрока, ничем больше их не трогая.
func _ensure_player_turn() -> void:
	var guard := 0
	while host.active_player() != MCF.Owner.PLAYER_1 and guard < 8:
		guard += 1
		_apply(EndTurnIntent.new())

## Одно действие, как в сети: хост решает и пишет броски, клиент воспроизводит.
func _apply(intent: Intent) -> ActionResult:
	var wire := IntentCodec.encode(intent)
	var decoded := IntentCodec.decode(wire)
	if decoded == null:
		fails.append("IntentCodec lost %s entirely" % str(wire))
		return ActionResult.fail("codec")
	var label := TS.intent_line(intent)
	host.dice.begin_record()
	var res := r_host.resolve(intent)
	var rolls := host.dice.take_log()
	client.dice.fallback_rolls = 0
	client.dice.feed_scripted(rolls)
	r_client.resolve(decoded)
	_compare(label, rolls)
	return res

## Слот мирных отыгрывается не намерением, а вызовом резолвера — отсюда отдельный
## путь с двумя замыканиями.
func _sync(label: String, host_call: Callable, client_call: Callable) -> void:
	host.dice.begin_record()
	host_call.call()
	var rolls := host.dice.take_log()
	client.dice.fallback_rolls = 0
	client.dice.feed_scripted(rolls)
	client_call.call()
	_compare(label, rolls)

func _compare(label: String, rolls: Array) -> void:
	if client.dice.scripted_remaining() != 0:
		fails.append("%s: client left %d of %d dice unused"
				% [label, client.dice.scripted_remaining(), rolls.size()])
	if client.dice.fallback_rolls != 0:
		fails.append("%s: client rolled its own dice %d time(s)"
				% [label, client.dice.fallback_rolls])
	var dh := TS.digest(host)
	var dc := TS.digest(client)
	if dh != dc:
		fails.append("%s: BOARDS DIVERGED\n%s" % [label, _first_diff(dh, dc)])

## Item 6: игрок выбирает третьим кликом, куда лягут две кучи вынутой земли.
## Кучи — это укрытие 0.5 м: они меняют и стоимость прохода, и линию огня, так что
## разъехавшись однажды, доски не сходятся уже никогда.
func _dig_with_chosen_dirt() -> void:
	var digger := _unit_at(Vector2i(3, 16))  # инженер первого игрока
	if digger == null:
		fails.append("no engineer at (3,16) — the fixed map moved")
		return
	var trench := Vector2i(4, 16)
	# Две клетки, соседние с окопом, но НЕ те, что выбрал бы автоматический проход.
	# Он берёт их в порядке Grid.neighbors(), то есть сверху; берём нижние.
	var a := Vector2i(3, 17)
	var b := Vector2i(5, 17)
	var res := _apply(DigIntent.new(digger.id, trench, a, b))
	ck(res.ok, "dig refused: %s" % res.reason)
	ck(host.grid.cell(trench).feature_id == MCF.FEATURE_TRENCH, "trench was dug")
	ck(host.grid.cell(a).dirt_level > 0, "host put dirt where the player clicked (a)")
	ck(host.grid.cell(b).dirt_level > 0, "host put dirt where the player clicked (b)")
	ck(client.grid.cell(a).dirt_level > 0, "client put dirt where the player clicked (a)")
	ck(client.grid.cell(b).dirt_level > 0, "client put dirt where the player clicked (b)")

## Item 34: групповой приказ. Клетки распределяет отдавший приказ, по проводу едет
## готовый список — пересчитай его резолвер, и у пиров вышло бы разное.
func _group_move() -> void:
	var ids: Array[int] = []
	var dests: Array[Vector2i] = []
	for y in [4, 6, 8]:
		var u := _unit_at(Vector2i(3, y))
		if u == null or u.remaining_ap <= 0:
			continue
		ids.append(u.id)
		dests.append(Vector2i(7, y))
	if ids.size() < 2:
		fails.append("not enough movable units for a group order")
		return
	var res := _apply(GroupMoveIntent.new(ids, dests))
	ck(res.ok, "group move refused: %s" % res.reason)
	for i in ids.size():
		var u := host.get_unit(ids[i])
		ck(u.coord == dests[i], "unit %d went exactly where it was sent (at %s, wanted %s)"
				% [ids[i], str(u.coord), str(dests[i])])

## Item 28: откат. Стек живёт в резолвере, поэтому он одинаков у обеих сторон, и
## одно намерение возвращает ОБЕ доски в прежнее положение.
func _undo_redo() -> void:
	var u := _unit_at(Vector2i(3, 10))
	if u == null:
		fails.append("no unit at (3,10) for the undo test")
		return
	var before := TS.digest(host)
	ck(r_host.can_undo() and r_client.can_undo(),
			"both sides have something to undo after the moves above")
	var moved := _apply(MoveIntent.new(u.id, Vector2i(6, 10)))
	ck(moved.ok, "move before undo refused: %s" % moved.reason)
	ck(TS.digest(host) != before, "the board actually changed")
	var undone := _apply(UndoIntent.new(MCF.Owner.PLAYER_1))
	ck(undone.ok, "undo refused: %s" % undone.reason)
	ck(TS.digest(host) == before, "undo put the board back exactly")
	var redone := _apply(RedoIntent.new(MCF.Owner.PLAYER_1))
	ck(redone.ok, "redo refused: %s" % redone.reason)
	ck(host.get_unit(u.id).coord == Vector2i(6, 10), "redo replayed the move")
	# Откат чужого хода не принимается — это и есть проверка прав.
	var foreign := r_host.resolve(UndoIntent.new(MCF.Owner.PLAYER_2))
	ck(not foreign.ok and foreign.reason == "Not your turn",
			"an undo from the side that is not acting is refused (got '%s')" % foreign.reason)

## AUDIT §2.4: завершение хода — единственный авторитетный переход без проверки
## прав, и клиент мог закончить ЧУЖОЙ ход, заодно проиграв слот мирных и продвинув
## огонь.
func _end_turn_authority() -> void:
	var acting := host.active_player()
	var other := MCF.Owner.PLAYER_2 if acting == MCF.Owner.PLAYER_1 else MCF.Owner.PLAYER_1
	var bad := r_host.resolve(EndTurnIntent.new(other))
	ck(not bad.ok and bad.reason == "Not your turn",
			"ending someone else's turn is refused (got '%s')" % bad.reason)
	ck(host.active_player() == acting, "the refused end-turn changed nothing")
	var good := _apply(EndTurnIntent.new(acting))
	ck(good.ok, "the acting side can still end its own turn: %s" % good.reason)
	# Старый вызов без указания стороны по-прежнему проходит: так ходят ИИ и мирные.
	ck(r_host.resolve(EndTurnIntent.new()).ok,
			"an unattributed end-turn still works (AI, civilians, internal calls)")

func _unit_at(coord: Vector2i) -> UnitInstance:
	var c := host.grid.cell(coord)
	return c.occupant if c != null and c.occupant != null and c.occupant.is_alive() else null

func _first_diff(a: String, b: String) -> String:
	var la := a.split("\n")
	var lb := b.split("\n")
	for i in maxi(la.size(), lb.size()):
		var x: String = la[i] if i < la.size() else "<eof>"
		var y: String = lb[i] if i < lb.size() else "<eof>"
		if x != y:
			return "    host:   %s\n    client: %s" % [x, y]
	return "    (digests differ only in trailing bytes)"
