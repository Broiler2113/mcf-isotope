class_name GameActionResolver
extends "res://src/resolver/parts/ResolverEvents.gd"

## Rules engine: an Intent in, an ActionResult out (resolve), undo and redo, legal intents
## and the hand-over between turns. The rules themselves sit below it in parts/
## (ResolverState.gd lists the chain).

func _init(p_state: GameState) -> void:
	state = p_state
	MCF.display_env = state.env   # «Rubble Pile» на станции и астероиде (0.12.1)
	random_events = RandomEvents.from_config()
	mode = MatchMode.from_config()

## Что выбрасывает окоп: на станции и астероиде — лом палубы (0.12.1), иначе — земля.
func _spoil_word() -> String:
	return "rubble" if MCF.rubble_env(state.env) else "dirt"

func can_undo() -> bool:
	return not _undo_stack.is_empty()

func can_redo() -> bool:
	return not _redo_stack.is_empty()

## Идентификатор ХОДА: раунд + слот инициативы (#94). Откат живёт только внутри
## одного хода, а сменой активной стороны его не поймать — если вторая сторона
## выбита, её слот пропускается, круг замыкается обратно на нас, и active_player()
## остаётся ТЕМ ЖЕ. По владельцу такой переход неотличим от продолжения хода, и
## Undo уезжал в прошлый раунд — уже после того, как всем восстановили ОД.
func _turn_key() -> Vector2i:
	return Vector2i(state.turns.round_number, state.turns.active_index)

## Действие, которое нельзя откатить (#81). Любой выстрел — открытая карта: кубики
## уже брошены и результат известен, откат превратился бы в переброс. Лазер марксманна
## кубиков не бросает, но тоже необратим — он уже снёс стену и убил всех на линии.
func _is_irreversible(intent: Intent, result: ActionResult) -> bool:
	for ev: Dictionary in result.dice_events:
		# Переход по клеткам и прочие отметки анимации — не броски: шаг остаётся отменяемым.
		if not ANIMATION_ONLY_EVENTS.has(String(ev.get("kind", ""))):
			return true
	# Переданных бойцов не забрать откатом (fix-7 #18): отдал — значит отдал.
	return intent is ShootIntent or intent is DPMGFireIntent \
			or intent is DroneDetonateIntent or intent is VehicleCannonIntent \
			or intent is GiveUnitsIntent

## Пишем ли снимок за эту сторону. Ходы ИИ и мирных в стек не идут (#94): чужой ход
## откатывать не вправе никто, а снимок стоит копии всей доски (§27.12).
##
## Условие СПЕЦИАЛЬНО выведено из ростера, а не из «могу ли я этим управлять»:
## второе у каждого пира своё, и стеки разъехались бы по построению.
func _undoable_side(side: int) -> bool:
	return MCF.is_player(side) and not state.roster.is_ai(side)

func resolve(intent: Intent) -> ActionResult:
	if intent == null:
		return ActionResult.fail("No intent")
	if intent is UndoIntent or intent is RedoIntent:
		var undone := _resolve_undo(intent) if intent is UndoIntent else _resolve_redo(intent)
		if undone.ok and replay_recorder != null and not state.dice.record_enabled:
			replay_recorder.on_resolved(intent, [], undone)
		return undone
	_resolve_depth += 1
	var top := _resolve_depth == 1
	var turn_before := _turn_key()
	var undoable := top and track_undo_history and _undoable_side(state.active_player())
	# Снимок для отката — без клеток: их прежний вид собирает журнал GridCell по ходу
	# действия, ровно для тронутых. Копия всей доски 250×250 стоила ~250 мс на щелчок.
	var pre_snap: Dictionary = state.snapshot(false) if undoable else {}
	if undoable and capture_cosmetics.is_valid():
		pre_snap["cosmetics"] = capture_cosmetics.call()
	if top:
		GridCell.journal = {}
		GridCell.journaling = undoable or intent is ShootIntent or intent is VehicleCannonIntent or intent is VehicleMoveIntent
	# Запись повтора (M12). Пишем ровно то же, что хост шлёт клиенту, — и тем же
	# способом. Условие record_enabled здесь не формальность: в сетевой партии журнал
	# уже ведёт NetGame, и второй begin_record отобрал бы у него броски действия.
	var recording := top and replay_recorder != null and not state.dice.record_enabled
	if recording:
		state.dice.begin_record()
	var actor_owner := -1
	var actor_from := Vector2i(-1, -1)
	var au := state.get_unit(intent.actor_id)
	var av := state.get_vehicle(intent.actor_id) if au == null else null
	if au != null:
		actor_owner = au.owner
		actor_from = au.coord
	elif av != null:
		actor_owner = av.owner
		actor_from = av.center()
	var items_before := state.grid.map_items.duplicate() if top and intent is VehicleMoveIntent else []
	var alive_before := {}
	if top:
		for u: UnitInstance in state.all_units():
			if u.is_alive(): alive_before[u.id] = true
	var result := _dispatch(intent)
	if top and result.ok:
		_credit_kills(intent, au, av, result)
	if top:
		result.actor_owner = actor_owner
		result.actor_from = actor_from
		result.actor_to = actor_from
		if au != null:
			result.actor_to = au.coord
		elif av != null:
			result.actor_to = av.center()
	# Борг едет за оператором (batch 13): куда бы боец ни сдвинулся — ходом, отбросом,
	# переносом, — машина стоит в его клетке.
	if result.ok:
		_sync_borgs()
		_sync_seat_guns()
	# Действие могло вскрыть квартал (§3 «Нейтралы»): соседняя клетка сменила состояние
	# или в чей-то обзор вошёл солдат. Каскад и сбор группы идут ВНУТРИ resolve(), пока
	# открыт поток записи кубиков, — иначе жребий места в очереди рассинхронил бы стороны.
	# Только на верхнем уровне: под-resolve хода жителей (depth>1) кварталов не будит.
	if top and result.ok:
		_free_orphaned_captives()
		_wake_and_group(result)
	# Holdout (0.12, решение владельца): волна выбита — следующая идёт сразу, не дожидаясь
	# своих двух раундов. Броски места высадки — броски этого действия (запись, сеть).
	var wave_called := top and result.ok and _maybe_wave_cleared(result)
	if top and result.ok and mode.bounty_unit >= 0:
		_check_bounty(result, actor_owner)
	# Броски забираем ПОСЛЕ пробуждения кварталов: жребий места в очереди — такой же
	# бросок этого действия, и без него повтор поставил бы группу в другое место.
	if recording:
		var rolls := state.dice.take_log()
		state.dice.record_enabled = false
		if result.ok:
			replay_recorder.on_resolved(intent, rolls, result)
	_resolve_depth -= 1
	if top:
		# Include secondary explosions and door changes outside the original blast.
		if intent is VehicleMoveIntent and result.ok and result.visual_hold.is_empty():
			result.visual_hold = {"cells": {}}
		if intent is VehicleMoveIntent and result.ok:
			result.visual_hold["map_items"] = items_before
		if not result.visual_hold.is_empty():
			var held: Dictionary = result.visual_hold.get("cells", {})
			for cell: GridCell in GridCell.journal:
				if held.has(cell.coord): continue
				var im: Array = GridCell.journal[cell]
				held[cell.coord] = {"image": im, "feature_id": im[8],
					"feature_durability": im[11], "cover_height": im[1], "corpse_count": im[12]}
			result.visual_hold["cells"] = held
		GridCell.journaling = false
		if undoable:
			pre_snap["cells"] = GridCell.journal
		GridCell.journal = {}
	if top and result.ok:
		for u: UnitInstance in state.all_units():
			if alive_before.has(u.id) and not u.is_alive(): result.visual_deaths.append(u.id)
		for ev: Dictionary in result.dice_events:
			if ev.get("kind", "") == "veh_walk":
				ev["effects"] = result.fx
				ev["deaths"] = result.visual_deaths
		# Новое действие обрывает откатанную ветку — повторять больше нечего (#38).
		_redo_stack.clear()
		if _turn_key() != turn_before or _is_irreversible(intent, result) or wave_called:
			_undo_stack.clear()
		elif undoable:
			_undo_stack.append(pre_snap)
	return result

## Счёт таблицы итогов (playtest-20): убитые этим действием записываются тому, кто
## действовал, — бойцу, дрону или машине; раздавленные гусеницей — отдельной колонкой.
## Своих и союзников в счёт не берём, как и смерти от шага: идущий на мину или в огонь
## не «убил» тех, кого задело.
func _credit_kills(intent: Intent, au: UnitInstance, av: Vehicle, result: ActionResult) -> void:
	if result.deaths.is_empty() or intent is MoveIntent or intent is GroupMoveIntent \
			or intent is EndTurnIntent:
		return
	if au == null and av == null:
		return
	var killer_owner := au.owner if au != null else av.owner
	var key := au.id if au != null else av.id
	var crushed := av != null and intent is VehicleMoveIntent
	for vid: int in result.deaths:
		var victim := state.get_unit(vid)
		if victim == null or victim == au or state.roster.are_allies(killer_owner, victim.owner):
			continue
		var rec: Array = state.kills.get(key, [0, 0])
		rec[0] += 1
		if crushed:
			rec[1] += 1
		state.kills[key] = rec

func _resolve_undo(intent: UndoIntent) -> ActionResult:
	if intent.requester >= 0 and intent.requester != state.active_player():
		return ActionResult.fail("Not your turn")
	if _undo_stack.is_empty():
		return ActionResult.fail("Nothing to undo")
	var snap: Dictionary = _undo_stack.pop_back()
	_redo_stack.append(_counter_snapshot(snap))
	state.restore(snap)
	if snap.has("cosmetics") and restore_cosmetics.is_valid():
		restore_cosmetics.call(snap["cosmetics"])
	update_airlocks()
	return ActionResult.success(["— undo —"])

func _resolve_redo(intent: RedoIntent) -> ActionResult:
	if intent.requester >= 0 and intent.requester != state.active_player():
		return ActionResult.fail("Not your turn")
	if _redo_stack.is_empty():
		return ActionResult.fail("Nothing to redo")
	var snap: Dictionary = _redo_stack.pop_back()
	_undo_stack.append(_counter_snapshot(snap))
	state.restore(snap)
	if snap.has("cosmetics") and restore_cosmetics.is_valid():
		restore_cosmetics.call(snap["cosmetics"])
	update_airlocks()
	return ActionResult.success(["— redo —"])

## Обратный снимок к snap: доска как сейчас, а из клеток — ровно те, что snap вернёт.
## Прочие клетки между двумя снимками не менялись: каждую правку во время действия
## ловит журнал GridCell, а откат с повтором кладут клетки только из снимков.
func _counter_snapshot(snap: Dictionary) -> Dictionary:
	var now := state.snapshot(false)
	if capture_cosmetics.is_valid(): now["cosmetics"] = capture_cosmetics.call()
	var cells := {}
	for c: GridCell in snap["cells"]:
		cells[c] = c.image()
	now["cells"] = cells
	return now

func _dispatch(intent: Intent) -> ActionResult:
	update_airlocks()  # состояние шлюзов зависит от текущих позиций (§3.11)
	# Пассажир челнока (batch 13) действует со своего места: стреляет, бросает гранаты,
	# ставит станцию в соседнее кресло, пересаживается и выходит. Всё, что требует стоять
	# на полу — ходить, хватать, строить, копать, чинить, — из кресла недоступно.
	var _rider := state.get_unit(intent.actor_id)
	if _rider != null and _rider.aboard_vehicle_id != -1 and _rider.is_alive() \
			and not _aboard_allowed(intent):
		return ActionResult.fail("Not possible from inside the shuttle — disembark first")
	var result := _route(intent)
	# Побочные эффекты действия — ТОЛЬКО когда оно состоялось. Раньше они шли до проверок,
	# и отвергнутое намерение (нет линии огня, цель вне досягаемости) всё равно сжигало
	# инженеру серию окопов и роняло волочимый объект; в сетевой партии хост такой отказ
	# гостю не шлёт, и доски разъезжались на первом же следующем окопе.
	if not result.ok:
		return result
	# Любое НЕ-копательное действие завершает начатую серию окопов (§3.7).
	# ИСКЛЮЧЕНИЕ (#65): ДВИЖЕНИЕ серию не рвёт. Окоп роют линией — шаг вдоль траншеи
	# и есть часть копки, а не «другое действие». Раньше один шаг сжигал инженеру все
	# 5 оставшихся бесплатных окопов и, вместе с потраченным на шаг ОД, делал копку
	# дальше вообще невозможной.
	if not (intent is DigIntent or intent is MoveIntent):
		var _diguer := state.get_unit(intent.actor_id)
		if _diguer != null:
			_diguer.dig_credits = 0
	# Волочимый объект остаётся в руках только пока юнит тащит его или идёт (#34).
	if not (intent is MoveIntent or intent is DragIntent):
		var _hauler := state.get_unit(intent.actor_id)
		if _hauler != null:
			_hauler.dragging = UnitInstance.NOT_DRAGGING
	# Остаток движения (#44/#65) НЕ сбрасывается другими действиями: юнит может походить,
	# выстрелить и доходить остаток тем же ОД. Кредит гаснет лишь на границе раунда (reset_ap).
	# Первый же выстрел где угодно на карте вскрывает ВСЕХ мирных жителей (§3.10, #56).
	# Гранату защёлкивает сам взрыв: предмет — не всегда оружие (огнетушитель).
	if intent is ShootIntent or intent is DPMGFireIntent or intent is DroneDetonateIntent \
			or intent is VehicleCannonIntent:
		state.combat_started = true
	return result

## Все ЗАКОННЫЕ намерения стороны прямо сейчас (RL v1, spec §4): маска легальности для
## обучаемой политики. Сам перечислитель живёт в LegalIntents.gd — этот файл и так велик;
## здесь лишь точка входа, о которой говорит спецификация. Точность (каждое
## перечисленное намерение проходит resolve()) проверяет tests/run_legal_intents.gd.
## actors — необязательный фильтр по актёрам (см. LegalIntents.enumerate); пусто = все.
## Шлюзы — сначала (playtest-20): dispatch пересчитывает их в НАЧАЛЕ действия, и после
## прошлого хода створка могла ещё стоять открытой. Перечислитель видел открытый шлюз и
## предлагал дрону лететь сквозь него, а резолвер, закрыв створку, отказывал «Target out
## of the drone's reach» (run_legal_intents, seed 5). Доска перечисления = доска действия.
func legal_intents(side: int, actors: Dictionary = {}) -> Array:
	update_airlocks()
	return LegalIntents.enumerate(self, side, actors)

## Маршрутизация намерения к его резолверу — без побочных эффектов (см. _dispatch).
func _route(intent: Intent) -> ActionResult:
	if intent is EndTurnIntent:
		return _resolve_end_turn(intent)
	elif intent is MoveIntent:
		return _resolve_move(intent)
	elif intent is VehicleSeatIntent:
		return _resolve_vehicle_seat(intent)
	elif intent is ShootIntent:
		return _resolve_shoot(intent)
	elif intent is CaptureIntent:
		return _resolve_capture(intent)
	elif intent is ReleaseIntent:
		return _resolve_release(intent)
	elif intent is CancelShotIntent:
		return _resolve_cancel_shot(intent)
	elif intent is MoveHeldIntent:
		return _resolve_move_held(intent)
	elif intent is UseItemIntent:
		return _resolve_use_item(intent)
	elif intent is PushIntent:
		return _resolve_push(intent)
	elif intent is SpawnDroneIntent:
		return _resolve_spawn_drone(intent)
	elif intent is PickUpStationIntent:
		return _resolve_pickup_station(intent)
	elif intent is DroneMoveIntent:
		return _resolve_drone_move(intent)
	elif intent is DroneDetonateIntent:
		return _resolve_drone_detonate(intent)
	elif intent is BuildIntent:
		return _resolve_build(intent)
	elif intent is BuildWallIntent:
		return _resolve_build_wall(intent)
	elif intent is WeldAirlockIntent:
		return _resolve_weld_airlock(intent)
	elif intent is CarryIntent:
		return _resolve_carry(intent)
	elif intent is BreakIntent:
		return _resolve_break(intent)
	elif intent is DragIntent:
		return _resolve_drag(intent)
	elif intent is PickUpCorpseIntent:
		return _resolve_pickup_corpse(intent)
	elif intent is DropCorpseIntent:
		return _resolve_drop_corpse(intent)
	elif intent is DPMGFireIntent:
		return _resolve_dpmg(intent)
	elif intent is DigIntent:
		return _resolve_dig(intent)
	elif intent is VehicleBoardIntent:
		return _resolve_vehicle_board(intent)
	elif intent is VehicleDisembarkIntent:
		return _resolve_vehicle_disembark(intent)
	elif intent is VehicleTurnIntent:
		return _resolve_vehicle_turn(intent)
	elif intent is VehicleMoveIntent:
		return _resolve_vehicle_move(intent)
	elif intent is VehicleCannonIntent:
		return _resolve_vehicle_cannon(intent)
	elif intent is RepairVehicleIntent:
		return _resolve_repair_vehicle(intent)
	elif intent is VehicleMeleeIntent:
		return _resolve_vehicle_melee(intent)
	elif intent is VehicleUnloadCorpseIntent:
		return _resolve_vehicle_unload_corpse(intent)
	elif intent is GroupMoveIntent:
		return _resolve_group_move(intent)
	elif intent is GiveUnitsIntent:
		return _resolve_give_units(intent)
	elif intent is PlaceMineIntent:
		return _resolve_place_mine(intent)
	elif intent is RevealMinesIntent:
		return _resolve_reveal_mines(intent)
	elif intent is DisarmMineIntent:
		return _resolve_disarm_mine(intent)
	return ActionResult.fail("Unknown intent: %s" % intent)

## Кому можно передать бойцов (fix-7 #18): любому другому игроку за столом, пока он в
## игре; волнам Holdout, мирным и рейдерам — нет.
func give_targets(from_side: int) -> Array[int]:
	var out: Array[int] = []
	for side: int in state.roster.player_ids():
		if side != from_side and MCF.is_player(side) and not state.turns.is_eliminated(side) \
				and not (mode.is_holdout() and side == mode.wave_side):
			out.append(side)
	return out

## Передача бойцов (fix-7 #18): в любой момент, не только в свой ход, — бойцы сохраняют
## ОД, раны и всё, что несут. В машине (кресло, борг, экипаж танка) передать нельзя:
## машина осталась бы чужой.
func _resolve_give_units(intent: GiveUnitsIntent) -> ActionResult:
	if intent.unit_ids.is_empty():
		return ActionResult.fail("No units to give")
	var first := state.get_unit(intent.unit_ids[0])
	if first == null:
		return ActionResult.fail("Unit unavailable")
	var from_side := first.owner
	if not give_targets(from_side).has(intent.to_side):
		return ActionResult.fail("Can't give units to that side")
	var units: Array[UnitInstance] = []
	for id: int in intent.unit_ids:
		var u := state.get_unit(id)
		if u == null or not u.is_alive() or u.owner != from_side or u.is_drone:
			return ActionResult.fail("Only your own soldiers can be given")
		if u.aboard_vehicle_id != -1 or u.borg_id != -1:
			return ActionResult.fail("%s is in a vehicle — climb out first" % u.stats.display_name)
		units.append(u)
	for u in units:
		u.owner = intent.to_side
	return ActionResult.success(["%s gives %d unit(s) to %s" % [
		state.roster.name_of(from_side), units.size(), state.roster.name_of(intent.to_side)]])

## Групповой приказ движения (item 34): готовый список «кому куда», посчитанный на
## машине отдавшего приказ. Резолвер его НЕ пересчитывает — иначе распределение у
## пиров снова разошлось бы, а игрок увидел бы не то, что показал предпросмотр.
##
## Отдельные движения применяются по очереди, и неудача одного не отменяет
## остальных: юнит, чью клетку успел занять сосед, просто остаётся на месте — ровно
## то же, что делал прежний локальный вариант приказа.
func _resolve_group_move(intent: GroupMoveIntent) -> ActionResult:
	if intent.unit_ids.size() != intent.targets.size():
		return ActionResult.fail("Malformed group order")
	if intent.unit_ids.is_empty():
		return ActionResult.fail("Nobody selected")
	var out := ActionResult.success()
	var moved := false
	for i in intent.unit_ids.size():
		var u := state.get_unit(intent.unit_ids[i])
		if u == null or not u.is_alive() or u.coord == intent.targets[i]:
			continue
		var one := _dispatch(MoveIntent.new(u.id, intent.targets[i]))
		if not one.ok:
			# Сосед по группе успел встать на маршрут или бюджет был меньше показанного
			# (batch 17, item 2): идём в ближайшую к цели достижимую клетку по ЖИВОЙ
			# сетке — считается в резолвере, поэтому у всех пиров одинаково.
			var alt := nearest_reachable(u, intent.targets[i])
			if alt != u.coord:
				one = _dispatch(MoveIntent.new(u.id, alt))
		if one.ok:
			moved = true
			out.log_lines.append_array(one.log_lines)
			out.dice_events.append_array(one.dice_events)
			out.deaths.append_array(one.deaths)
			out.fx.append_array(one.fx)
	if not moved:
		return ActionResult.fail("Nobody could move")
	return out

# --- Передача хода (§3.3) ---
## Opening is shared by local games, networking, training and replay capture.
## Announce before the first player can act, after automatic neutral slots finish.
func open_match() -> ActionResult:
	var out := play_civilian_slots()
	_maybe_random_event(out)
	_mode_round_start(out)
	return out

## Отыграть слот мирных, если сейчас их очередь по инициативе (#42, #53).
## Контроллера у нейтральной стороны нет: свой ход она проводит здесь и сразу
## передаёт дальше, поэтому наружу активным игроком всегда виден P1 или P2.
## Цикл конечен: end_turn либо сдвигает слот, либо (живых не осталось) оставляет
## его на месте — на этот случай выходим по неизменившемуся индексу.
func play_civilian_slots() -> ActionResult:
	var out := ActionResult.success()
	# Играем ЛЮБОЙ нейтральный слот: общий (§до сбора групп) и слот каждой группы (§15) —
	# у нейтральной стороны контроллера нет, её ход всегда проводит резолвер.
	# Каждый нейтральный слот играется не больше раза за передачу хода (batch 14): когда
	# обе армии перебиты, очередь состоит из одних жителей, и без этой памяти круг
	# 0 → 1 → 2 → 0 … не кончался никогда — бой зависал на первом же EndTurn.
	# Память ведётся по ВЛАДЕЛЬЦУ, а не по индексу в очереди (0.9.4): независимая армия
	# встаёт в очередь прямо во время передачи хода, и вставка СДВИГАЕТ индексы — по индексу
	# цикл обрывался на полпути и оставлял активным слот, за который играть некому.
	var played: Dictionary = {}
	# Независимая армия (0.9.4) ходит здесь же: командира у неё нет, её ход ведёт резолвер
	# ровно так же, как ход жителей, — и значит он одинаков у хоста и клиента без единого
	# сетевого сообщения.
	while MCF.is_npc_side(state.active_player()):
		var slot := state.active_player()
		if played.has(slot):
			break
		played[slot] = true
		var res := advance_civilians(slot)
		out.log_lines.append_array(res.log_lines)
		# Метка «сейчас ходит вот этот слот» (item 6): по ней экран подсвечивает нейтральную
		# группу в списке инициативы, пока её ход отыгрывается. Своего active_player у неё в
		# этот момент нет — резолвер проводит все нейтральные слоты внутри ОДНОЙ передачи
		# хода, и очередь снаружи показывает уже следующего игрока.
		if not res.dice_events.is_empty() or not res.fx.is_empty():
			out.dice_events.append({"kind": "slot", "owner": state.active_player()})
		out.dice_events.append_array(res.dice_events)
		out.fx.append_array(res.fx)
		out.deaths.append_array(res.deaths)
		state.turns.end_turn(state.all_units())
		if state.active_player() == slot:
			break   # играть больше некому — очередь стоит на месте
	return out

## Пленник, чьего захватчика больше нет, отпускается сам.
##
## Смерть захватчика пленника освобождает — это делает _kill, и делает во всех случаях,
## какие удалось построить: свой и чужой захват, перенос, переложенный пленник, пожар,
## взрыв, раунд спустя. И всё же игрок видел бойца, оставшегося схваченным после гибели
## того, кто его держал.
##
## Поэтому страховка стоит не на пути смерти, а на переходе хода: любая ссылка на
## захватчика, которого нет в живых, разрывается здесь. Освобождение перестаёт зависеть
## от того, каким путём захватчик выбыл, — а «схвачен покойником» перестаёт быть
## состоянием, которое доска вообще может держать.
## A captor that is still alive but no longer beside its captive lets go too: one
## stopped short on a mine it survived, or grabbed in turn (playtest: raiders left
## "grabbed" by nobody). Runs after every action as well as at the handoff.
func _free_orphaned_captives() -> void:
	for u: UnitInstance in state.all_units():
		if u.captor_id == -1:
			continue
		var captor := state.get_unit(u.captor_id)
		if captor != null and captor.is_alive() and captor.is_on_field() \
				and state.grid.in_bounds(captor.coord) and Combat.distance(captor.coord, u.coord) <= 1:
			continue
		u.captor_id = -1
		# Труп так трупом и остаётся: воскрешать освобождением нельзя.
		if u.is_held():
			u.status = MCF.Status.ALIVE

func _resolve_end_turn(intent: EndTurnIntent = null) -> ActionResult:
	# Единственный авторитетный переход состояния без проверки прав (AUDIT §2.4):
	# actor_id здесь −1, поэтому _validate_actor не срабатывает, и клиент мог
	# завершить чужой ход. Заполненный requester сверяем; пустой — старый вызов
	# (ИИ, мирные, внутренние), их и раньше никто не проверял.
	if intent != null and intent.requester >= 0 \
			and intent.requester != state.active_player():
		return ActionResult.fail("Not your turn")
	var prev := state.active_player()
	var previous_round := state.turns.round_number
	_free_orphaned_captives()
	# Pending warnings land at this player end-turn; standing gas ages only
	# when the handoff also closes a round, before AP refresh.
	var round_res := ActionResult.new()
	round_res.ok = true
	# Warnings land when the round closes (0.11): announced at its opening, so every
	# player gets exactly one turn to react — not only whoever moves first.
	if _handoff_closes_round():
		land_random_events(round_res)
		_mode_round_end(round_res)
	state.turns.end_turn(state.all_units())
	var civ := play_civilian_slots()
	# Огонь ползёт в начале хода той стороны, которая его устроила (#45). Дошедшее до
	# обычной мины пламя её подрывает (item 13) — смерти и косметику копим в fire_res.
	var fire_res := ActionResult.new()
	fire_res.ok = true
	advance_fire(state.active_player(), fire_res)
	# Серия копки не переносится между ходами (§3.7).
	for u in state.all_units():
		u.dig_credits = 0
	# В начале активации техника получает ОД = числу живого экипажа (§техника),
	# главная пушка снова доступна (не чаще 2×/ход).
	for veh: Vehicle in state.all_vehicles():
		veh.ap = _vehicle_crew_ap(veh)
		veh.cannon_shots_this_round = 0
		veh.move_credit = 0  # недокатанные клетки через ход не переносятся (#97)
	var lines: Array[String] = [
		"— %s ended their turn. %s to move (round %d) —" % [
			state.roster.name_of(prev), state.roster.name_of(state.active_player()),
			state.turns.round_number
		]
	]
	# Журнал события идёт ПЕРВЫМ: по времени оно и случилось раньше хода жителей и огня.
	lines.append_array(round_res.log_lines)
	lines.append_array(civ.log_lines)
	lines.append_array(fire_res.log_lines)
	var out := ActionResult.success(lines)
	out.dice_events.append_array(round_res.dice_events)
	out.fx.append_array(round_res.fx)
	out.deaths.append_array(round_res.deaths)
	# Броски жителей едут вместе с передачей хода: UI отыграет их анимацией, а смерти
	# покажет только после кубика защиты — как и в любом другом обмене выстрелами (#96).
	out.dice_events.append_array(civ.dice_events)
	out.fx.append_array(civ.fx)
	out.deaths.append_array(civ.deaths)
	# Погибшие и косметика от подорвавшихся в огне мин — тоже частью передачи хода.
	out.deaths.append_array(fire_res.deaths)
	out.fire_deaths.append_array(fire_res.fire_deaths)
	out.fx.append_array(fire_res.fx)
	# A new round can also begin inside the automatic neutral slots.
	# Ordinary player handoffs must neither announce nor advance the event interval.
	if state.turns.round_number > previous_round:
		_maybe_random_event(out)
		_mode_round_start(out)
	return out

## Кончится ли раунд ЭТОЙ передачей хода (0.9.4). Прямо — если после активного слота
## играющих больше нет; а ещё — если все оставшиеся играющие слоты ничьи (жители,
## независимые армии): их ход резолвер отыграет здесь же, внутри этой самой передачи
## (play_civilian_slots), и границу раунда перейдёт тоже он. Без второго условия события
## на карте с жителями не падали бы вовсе: раунд всегда кончался «внутри» передачи.
func _handoff_closes_round() -> bool:
	var units := state.all_units()
	if state.turns.closes_round(units):
		return true
	var order := state.turns.round_order
	for i in range(state.turns.active_index + 1, order.size()):
		var slot: int = order[i]
		if state.turns.playable(slot, units) and not MCF.is_npc_side(slot):
			return false
	return true

# --- Общие проверки ---
## credit > 0 — у юнита есть незакрытый «кредит» текущего действия (остаток движения
## #44/#65 или бесплатные окопы §3.7): такое действие разрешено и без ОД.
func _validate_actor(unit: UnitInstance, credit: int = 0) -> String:
	if unit == null:
		return "Unit not found"
	if not unit.is_alive():
		return "Unit is incapacitated"
	# Пленник ничего не делает, кроме попытки вырваться (#76): раньше его сковывали
	# обнулением ОД, но тогда он терял и весь свой ход после освобождения.
	if unit.is_held():
		return "Unit is being held — break free first"
	if unit.owner != state.active_player():
		return "It's the other player's turn"
	if not state.turns.slot_has(state.turns.active_slot(), unit):
		return "It's another wave's turn"
	if unit.remaining_ap <= 0 and credit <= 0:
		return "Unit has no AP left"
	return ""
