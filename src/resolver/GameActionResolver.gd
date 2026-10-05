class_name GameActionResolver
extends RefCounted

## Единственная точка изменения состояния (см. §2.2):
##   1) проверка легальности → 2) броски через DiceService →
##   3) применение к состоянию → 4) возврат ActionResult (лог/UI публикует вызывающий).
## Никаких прямых мутаций состояния вне этого класса.

var state: GameState
## Туман войны включён по умолчанию; экран Setup может его отключить (§3.9, isotope §12b).
## При выключенном тумане is_visible_to_team всегда истинно (видно всю карту).
## Режим тумана (item 46). fog_enabled остаётся как «туман вообще есть»: по нему
## устроены все быстрые выходы, и переписывать их на сравнение с OFF незачем.
var fog_mode: int = MCF.Fog.STANDARD

var fog_enabled: bool:
	get:
		return fog_mode != MCF.Fog.OFF
	set(v):
		fog_mode = MCF.Fog.STANDARD if v else MCF.Fog.OFF
## Сторона, которая «знает» позиции всех юнитов, игнорируя туман (#43): ИИ ставит
## сюда свой owner, чтобы целиться в скрытых. На отображение тумана игрока НЕ влияет
## (team_visible_coords не смотрит на этот флаг) — только на легальность прицела ИИ.
var omniscient_side: int = -1
## Дружественный огонь (#100, §6.9). Исторически он ВСЕГДА был включён: оружие не
## разбирает форму, и по своим стрелять можно. Настройка лобби (§7 «Лобби») даёт
## его выключить — и тогда ни прицелиться в союзника, ни поймать чужую пулю спиной
## союзник уже не может. По умолчанию true, то есть поведение прежнее.
##
## В партии без команд флаг не меняет ничего, кроме запрета стрелять в СВОИХ же
## юнитов: «союзник» без команд — это только ты сам.
var friendly_fire_enabled: bool = true
## Разрешено ли вообще покидать машину. Выключается ТОЛЬКО тренировочными картами, где
## весь смысл — заставить воевать корпусами (rl/maps/town_tank.json): иначе политика
## паркует танк и уходит воевать пешком, то есть ровно то, ради чего карта и делалась,
## не происходит.
##
## Живёт здесь, рядом с friendly_fire_enabled, а не в rl/: через резолвер ходят ОБЕ
## стороны, и запрет, поставленный в env_server, связал бы только обучаемого, а
## встроенный ИИ продолжил бы спешиваться. Асимметрия правил — это уже не «карта про
## танки», а «карта, где у соперника больше ходов».
var disembark_enabled: bool = true

## Случайные события (§1.5 лобби, item 61). null или выключенные — событий нет и
## ни одного лишнего кубика не бросается, поэтому старые партии идут прежним потоком.
## Живёт на резолвере, входит в снимок состояния (отсчёт до события переживает откат).
var random_events: RandomEvents = null

## Регистратор повтора матча (M12, item 53). Пока он подключён, resolve() записывает
## броски КАЖДОГО верхнеуровневого действия и отдаёт их ему вместе с намерением —
## этого достаточно, чтобы сыграть партию заново (см. ReplayRecorder).
##
## Тип намеренно нежёсткий (RefCounted, а не ReplayRecorder): резолвер — слой правил,
## и знать про запись ему незачем, он лишь зовёт on_resolved. null — записи нет, и
## тогда ни одной лишней строчки не выполняется.
var replay_recorder: RefCounted = null

func _init(p_state: GameState) -> void:
	state = p_state
	random_events = RandomEvents.from_config()

## Сколько окопов роется за 1 ОД: обычная пехота — 3, инженер — 6 (§3.7).
const DIG_TRENCHES_NORMAL := 3
const DIG_TRENCHES_ENGINEER := 6

## Стекло — единственное, что бьётся осколочной гранатой (#44), и защищается как
## обычный юнит с бронёй 5+.
const GLASS_ARMOR := 5

# --- Откат (§18.2, item 28) --------------------------------------------------
## Стек отката живёт ЗДЕСЬ, а не в боевом экране, и это главное в исправлении
## сетевого Undo. Пока он лежал в Main.gd, сетевая партия не клала в него ничего
## вовсе (_on_intent_ready уходил в сеть раньше), а если бы клала — стеки у пиров
## были бы разные, и откат развёл бы доски. В резолвере оба пира прогоняют ОДНИ И
## ТЕ ЖЕ намерения, поэтому и снимки складываются одинаковые.
var _undo_stack: Array = []
var _redo_stack: Array = []
## Глубина resolve(): слот мирных резолвит намерения ВНУТРИ чужого resolve()
## (см. play_civilian_slots), и снимок для них брать не надо — откатывают ход
## игрока целиком, а не отдельный шаг жителя.
var _resolve_depth: int = 0

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

## События потока «кубиков», которые на деле — только анимация, без броска.
const ANIMATION_ONLY_EVENTS := ["walk", "hold", "ap", "focus", "slot", "veh_walk"]

## Действие, которое нельзя откатить (#81). Любой выстрел — открытая карта: кубики
## уже брошены и результат известен, откат превратился бы в переброс. Лазер марксманна
## кубиков не бросает, но тоже необратим — он уже снёс стену и убил всех на линии.
func _is_irreversible(intent: Intent, result: ActionResult) -> bool:
	for ev: Dictionary in result.dice_events:
		# Переход по клеткам и прочие отметки анимации — не броски: шаг остаётся отменяемым.
		if not ANIMATION_ONLY_EVENTS.has(String(ev.get("kind", ""))):
			return true
	return intent is ShootIntent or intent is DPMGFireIntent \
			or intent is DroneDetonateIntent or intent is VehicleCannonIntent

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
	if intent is UndoIntent:
		return _resolve_undo(intent)
	if intent is RedoIntent:
		return _resolve_redo(intent)
	_resolve_depth += 1
	var top := _resolve_depth == 1
	var turn_before := _turn_key()
	var undoable := top and _undoable_side(state.active_player())
	# Снимок для отката — без клеток: их прежний вид собирает журнал GridCell по ходу
	# действия, ровно для тронутых. Копия всей доски 250×250 стоила ~250 мс на щелчок.
	var pre_snap: Dictionary = state.snapshot(false) if undoable else {}
	if top:
		GridCell.journal = {}
		GridCell.journaling = undoable
	# Запись повтора (M12). Пишем ровно то же, что хост шлёт клиенту, — и тем же
	# способом. Условие record_enabled здесь не формальность: в сетевой партии журнал
	# уже ведёт NetGame, и второй begin_record отобрал бы у него броски действия.
	var recording := top and replay_recorder != null and not state.dice.record_enabled
	if recording:
		state.dice.begin_record()
	var result := _dispatch(intent)
	# Борг едет за оператором (batch 13): куда бы боец ни сдвинулся — ходом, отбросом,
	# переносом, — машина стоит в его клетке.
	if result.ok:
		_sync_borgs()
	# Действие могло вскрыть квартал (§3 «Нейтралы»): соседняя клетка сменила состояние
	# или в чей-то обзор вошёл солдат. Каскад и сбор группы идут ВНУТРИ resolve(), пока
	# открыт поток записи кубиков, — иначе жребий места в очереди рассинхронил бы стороны.
	# Только на верхнем уровне: под-resolve хода жителей (depth>1) кварталов не будит.
	if top and result.ok:
		_wake_and_group(result)
	# Броски забираем ПОСЛЕ пробуждения кварталов: жребий места в очереди — такой же
	# бросок этого действия, и без него повтор поставил бы группу в другое место.
	if recording:
		var rolls := state.dice.take_log()
		state.dice.record_enabled = false
		if result.ok:
			replay_recorder.on_resolved(intent, rolls)
	_resolve_depth -= 1
	if top:
		GridCell.journaling = false
		if undoable:
			pre_snap["cells"] = GridCell.journal
		GridCell.journal = {}
	if top and result.ok:
		# Новое действие обрывает откатанную ветку — повторять больше нечего (#38).
		_redo_stack.clear()
		if _turn_key() != turn_before or _is_irreversible(intent, result):
			_undo_stack.clear()
		elif undoable:
			_undo_stack.append(pre_snap)
	return result

func _resolve_undo(intent: UndoIntent) -> ActionResult:
	if intent.requester >= 0 and intent.requester != state.active_player():
		return ActionResult.fail("Not your turn")
	if _undo_stack.is_empty():
		return ActionResult.fail("Nothing to undo")
	var snap: Dictionary = _undo_stack.pop_back()
	_redo_stack.append(_counter_snapshot(snap))
	state.restore(snap)
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
	update_airlocks()
	return ActionResult.success(["— redo —"])

## Обратный снимок к snap: доска как сейчас, а из клеток — ровно те, что snap вернёт.
## Прочие клетки между двумя снимками не менялись: каждую правку во время действия
## ловит журнал GridCell, а откат с повтором кладут клетки только из снимков.
func _counter_snapshot(snap: Dictionary) -> Dictionary:
	var now := state.snapshot(false)
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
func legal_intents(side: int, actors: Dictionary = {}) -> Array:
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
	elif intent is PlaceMineIntent:
		return _resolve_place_mine(intent)
	elif intent is RevealMinesIntent:
		return _resolve_reveal_mines(intent)
	elif intent is DisarmMineIntent:
		return _resolve_disarm_mine(intent)
	return ActionResult.fail("Unknown intent: %s" % intent)

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

# --- Движение (§3.1, §3.2) ---
func _resolve_move(intent: MoveIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit, unit.move_credit if unit != null else 0)
	if err != "":
		return ActionResult.fail(err)
	# blocks_walk, а не is_occupied_or_wall: закрытый шлюз для пешего маршрута не
	# преграда — он разъедется, когда боец подойдёт вплотную (#100).
	if state.grid.blocks_walk(intent.target):
		return ActionResult.fail("Cell is occupied or impassable")

	# Перенос удерживаемого юнита (§3.4) или тяжёлого объекта (#34): бюджет −3 клетки.
	var carried := held_unit_of(unit)
	var dragged := dragged_cell_of(unit)
	var use_credit := unit.move_credit > 0
	# Клетка в оранжевой/красной зоне — ход за 2/3 ОД одним путём (остаток переносится).
	var tiers := move_tier_budgets(unit)
	var reach := reachable_for(unit, tiers[tiers.size() - 1])
	if not reach.can_reach(intent.target):
		return ActionResult.fail("Target out of reach (speed %d)" % tiers[tiers.size() - 1])

	var spent: int = reach.cost[intent.target]
	var extra := tier_of(tiers, spent)
	var budget: int = tiers[extra]
	unit.remaining_ap -= extra
	var path := reach.path_to(intent.target)
	var origin := unit.coord
	state.grid.move_occupant(unit.coord, intent.target)
	# Боец сдвинулся — створки шлюзов по всей карте пересчитываются сразу (#100),
	# иначе покинутый шлюз остался бы открытым до следующего действия.
	update_airlocks()
	# Списываем либо ОД (свежее движение), либо накопленный кредит (#44).
	# Волочение объекта ОД не стоит вовсе: и сам захват, и шаги с грузом бесплатны.
	if use_credit or dragged != UnitInstance.NOT_DRAGGING:
		unit.move_credit = maxi(0, budget - spent)
	else:
		unit.remaining_ap -= 1
		unit.move_credit = maxi(0, budget - spent)
	# Незавершённая стрельба (action_state) НЕ сбрасывается — дробление, §3.2.
	var lines: Array[String] = ["%s: move → (%d, %d) [AP: %d]" % [
		unit.stats.display_name, intent.target.x, intent.target.y, unit.remaining_ap]]

	# Наступил на чужую мину где-то по дороге (item 45). Проверяется ВЕСЬ маршрут,
	# а не только конечная клетка: мину ставят на пути, а не в точке назначения.
	var mine := _mine_on_path(unit, path)
	# Борг (batch 13 B15): противопехотную мину не замечает, противотанковая снимает
	# очко корпуса и останавливает его на месте подрыва.
	if unit.borg_id != -1:
		mine = NOWHERE
		for step: Vector2i in path:
			var mc := state.grid.cell(step)
			if mc != null and mc.feature_id == MCF.FEATURE_AV_MINE:
				mine = step
				break
		if mine != NOWHERE:
			if unit.coord != mine:
				state.grid.move_occupant(unit.coord, mine)
				update_airlocks()
			unit.move_credit = 0
			var bres := ActionResult.success(lines)
			var bcell := state.grid.cell(mine)
			bcell.clear_feature()
			notify_cell_changed(mine)
			_fx(bres, {"fx": "debris", "at": NOWHERE, "cells": [mine]})
			bres.log("The borg rolls over an anti-vehicle mine at (%d, %d)!" % [mine.x, mine.y])
			_sync_borg(unit)
			var bveh := state.get_vehicle(unit.borg_id)
			if bveh != null:
				_damage_component(bveh, MCF.COMP_HULL, MCF.AV_MINE_VEHICLE_DAMAGE, "mine", bres)
			return bres
	if mine != NOWHERE:
		# Боец остаётся ТАМ, где наступил. Это не косметика: взрыв бьёт по клетке
		# мины, и не вернув его туда, мы подорвали бы пустую землю, а сам он дошёл
		# бы до цели невредимым.
		if unit.coord != mine:
			state.grid.move_occupant(unit.coord, mine)
			update_airlocks()
		lines[0] = "%s: move → (%d, %d), stopped at (%d, %d) [AP: %d]" % [
			unit.stats.display_name, intent.target.x, intent.target.y,
			mine.x, mine.y, unit.remaining_ap]
		# Дальше идти некуда — недоеденные клетки этого движения пропадают вместе с ним.
		unit.move_credit = 0
		var mine_res := ActionResult.success(lines)
		_fx_steps(mine_res, unit, origin, path, mine)
		_detonate_mine(mine, unit, mine_res)
		return mine_res

	# Пересёк горящую клетку — мгновенная смерть без спасброска (isotope §6.5, #1).
	# Проверяется ВЕСЬ маршрут, а не только цель: сгореть можно и на полпути.
	# Щитоносец и огнемётчик огня не боятся (#2, #50).
	var fire := _fire_on_path(unit, path)
	if fire != NOWHERE:
		# Как и с миной: боец остаётся ТАМ, где сгорел, а не доходит до цели.
		if unit.coord != fire:
			state.grid.move_occupant(unit.coord, fire)
			update_airlocks()
		unit.move_credit = 0
		var burn_res := ActionResult.success(lines)
		_fx_steps(burn_res, unit, origin, path, fire)
		_kill(unit)  # сгорел — крови нет (batch ui-drones)
		burn_res.log("%s burned to death at (%d, %d)!" % [
			unit.stats.display_name, fire.x, fire.y])
		return burn_res

	if carried != null:
		# Игрок может выбрать клетку для пленника (свободная, рядом с целью); иначе —
		# предпоследняя клетка пути (§3.4).
		var drop: Vector2i = origin if path.size() < 2 else path[path.size() - 2]
		if _valid_carry_drop(intent.carry_drop, intent.target):
			drop = intent.carry_drop
		state.grid.move_occupant(carried.coord, drop)
		lines.append("  ↳ carrying %s → (%d, %d)" % [carried.stats.display_name, drop.x, drop.y])

	# Волочимый объект переезжает на предпоследнюю клетку пути — как пленник (#34).
	if dragged != UnitInstance.NOT_DRAGGING:
		var spot: Vector2i = origin if path.size() < 2 else path[path.size() - 2]
		if _move_light_object(dragged, spot):
			unit.dragging = spot
			lines.append("  ↳ dragging \"%s\" → (%d, %d)" % [
				MCF.FEATURE_NAMES.get(state.grid.cell(spot).feature_id, "object"), spot.x, spot.y])
		else:
			unit.dragging = UnitInstance.NOT_DRAGGING
			lines.append("  ↳ dropped the object at (%d, %d)" % [dragged.x, dragged.y])

	var moved_res := ActionResult.success(lines)
	_fx_steps(moved_res, unit, origin, path, intent.target)
	return moved_res

## Шаги по клеткам для косметики (кровавые следы): маршрут до точки остановки включительно.
func _fx_steps(res: ActionResult, unit: UnitInstance, origin: Vector2i, path: Array, stop: Vector2i) -> void:
	var cut: Array = []
	for c: Vector2i in path:
		cut.append(c)
		if c == stop:
			break
	_fx(res, {"fx": "steps", "unit": unit.id, "from": origin, "path": cut})
	# Боец идёт по клеткам на экране, а не появляется в конце (batch soil-rulers): то же
	# событие «walk», каким уже ходят жители и летают дроны, и «hold», который до начала
	# анимации держит его рисунок в стартовой клетке.
	if not cut.is_empty():
		res.dice_events.append({"kind": "hold", "units": {unit.id: origin}})
		res.dice_events.append({"kind": "walk", "unit": unit.id, "from": origin,
				"path": cut, "soldier": true})

## Клетка волочимого объекта, если юнит и правда его тащит и объект ещё рядом (#34).
func dragged_cell_of(unit: UnitInstance) -> Vector2i:
	if unit == null or unit.dragging == UnitInstance.NOT_DRAGGING:
		return UnitInstance.NOT_DRAGGING
	if not state.grid.in_bounds(unit.dragging) \
			or Combat.distance(unit.coord, unit.dragging) > 1 \
			or not DRAGGABLE_FEATURES.has(state.grid.cell(unit.dragging).feature_id):
		unit.dragging = UnitInstance.NOT_DRAGGING
	return unit.dragging

## Переставить лёгкий объект (с его высотой/кучей) на свободную клетку. false — некуда.
func _move_light_object(src: Vector2i, dst: Vector2i) -> bool:
	if src == dst:
		return true
	var src_cell := state.grid.cell(src)
	var dst_cell := state.grid.cell(dst)
	if dst_cell == null or not dst_cell.is_buildable():
		return false
	var fid := src_cell.feature_id
	var fowner := src_cell.feature_owner
	var dirt := src_cell.dirt_level
	src_cell.clear_feature()
	dst_cell.set_feature(fid, fowner)
	if fid == MCF.FEATURE_DIRT_PILE:
		dst_cell.dirt_level = dirt
		dst_cell.cover_height = MCF.DIRT_HEIGHT_PER_LEVEL * float(dirt)
	_extinguish_cell(dst_cell)  # объект, придвинутый на огонь, сбивает пламя (#82)
	return true

# --- Стрельба (§3.5) с дроблением действия (§3.2) ---
func _resolve_shoot(intent: ShootIntent) -> ActionResult:
	var shooter := state.get_unit(intent.actor_id)
	if shooter == null:
		return ActionResult.fail("Unit not found")
	if not shooter.is_alive():
		return ActionResult.fail("Unit is incapacitated")
	if shooter.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")

	# Противотанкист может бить по пустой клетке пола (§3.14) — взрыв в её центре.
	if intent.target_id < 0 and shooter.stats.special_ability_id == MCF.ABILITY_ANTI_TANK:
		var ground_reason := can_blast_cell(shooter, intent.target_cell)
		if ground_reason != "":
			return ActionResult.fail(ground_reason)
		return _recoiled(_resolve_anti_tank(shooter, intent.target_cell, intent.component), shooter, intent.target_cell)

	# Огнемётчик может пустить струю по пустой клетке пола (как противотанкист): струя
	# идёт в её направлении, поджигает пол и убивает всех на пути.
	if intent.target_id < 0 and shooter.stats.special_ability_id == MCF.ABILITY_FLAMETHROWER:
		var flame_reason := can_flame_cell(shooter, intent.target_cell)
		if flame_reason != "":
			return ActionResult.fail(flame_reason)
		return _recoiled(_resolve_flame(shooter, intent.target_cell), shooter, intent.target_cell)

	# Марксманн стреляет в НАПРАВЛЕНИЕ (#49): целиться в конкретного бойца не обязательно,
	# луч уходит по лучу через указанную клетку и летит дальше сам.
	if intent.target_id < 0 and shooter.stats.special_ability_id == MCF.ABILITY_MARKSMAN:
		var laser_reason := can_laser_cell(shooter, intent.target_cell)
		if laser_reason != "":
			return ActionResult.fail(laser_reason)
		return _recoiled(_resolve_laser(shooter, intent.target_cell, intent.component), shooter, intent.target_cell)

	# Выстрел по окну (batch ui-drones): обычный стрелок может разбить стекло пулей.
	if intent.target_id < 0 and state.grid.in_bounds(intent.target_cell):
		var window_reason := can_shoot_window(shooter, intent.target_cell)
		if window_reason != "":
			return ActionResult.fail(window_reason)
		return _recoiled(_resolve_shoot_window(shooter, intent.target_cell), shooter, intent.target_cell)

	var target := state.get_unit(intent.target_id)
	var reason := can_shoot(shooter, target)
	if reason != "":
		return ActionResult.fail(reason)

	# Дружественный огонь (#100): если между стрелком и целью стоит живой человек —
	# чей угодно, свой или чужой — пуля достаётся ЕМУ. Стрелять «сквозь» спину нельзя,
	# но и запрещать выстрел незачем: игрок сам решает, стоит ли риск того.
	# Лазер марксманна и струя огнемёта телами не останавливаются — у них своя геометрия
	# (§3.13, §3.14), там всех на пути и так накрывает.
	var redirect_line := ""
	if shooter.stats.special_ability_id != MCF.ABILITY_MARKSMAN \
			and shooter.stats.special_ability_id != MCF.ABILITY_FLAMETHROWER:
		var intercepted := first_unit_on_line(shooter.coord, target.coord,
				shooter if not friendly_fire_enabled else null)
		if intercepted != null:
			redirect_line = "%s fires through %s — the shot hits them instead!" % [
				shooter.stats.display_name, intercepted.stats.display_name]
			target = intercepted

	# Спецстрельба (§3.13, §3.14) — отдельная геометрия, без дробления действия.
	match shooter.stats.special_ability_id:
		MCF.ABILITY_ANTI_TANK:
			return _recoiled(_resolve_anti_tank(shooter, target.coord, intent.component), shooter, target.coord)
		MCF.ABILITY_FLAMETHROWER:
			return _recoiled(_resolve_flame(shooter, target.coord), shooter, target.coord)
		MCF.ABILITY_MARKSMAN:
			return _recoiled(_resolve_laser(shooter, target.coord, intent.component), shooter, target.coord)
		MCF.ABILITY_ASSAULT:
			return _resolve_assault(shooter, target)

	# Продолжение начатого (дробимого) действия стрельбы по той же цели — без ОД.
	# Привязка идёт к ФАКТИЧЕСКОЙ цели: если очередь перенаправило тело на линии,
	# остаток очереди летит туда же, а не обратно в исходного противника (#100).
	var effective_tid := target.id
	var pending := shooter.action_state != null and shooter.action_state.is_pending()
	if pending and shooter.action_state.target_id != effective_tid:
		# Остаток очереди можно дострелить по ДРУГОЙ цели (#5): переносим привязку,
		# ОД не тратим — очередь уже оплачена.
		shooter.action_state.target_id = effective_tid
	if not pending:
		if shooter.remaining_ap <= 0:
			return ActionResult.fail("Unit has no AP left")
		shooter.remaining_ap -= 1  # действие «Стрельба» стоит 1 ОД целиком (§3.2)
		shooter.action_state = ActionState.new()
		shooter.action_state.target_id = effective_tid
		shooter.action_state.remaining_shots = shooter.rate_of_fire()

	var available: int = shooter.action_state.remaining_shots
	var want: int = available if intent.shots < 0 else clampi(intent.shots, 1, available)

	# Собираем ПОЛНУЮ разбивку модификаторов броска для UI (#49): каждая правка
	# попадания/защиты помечается ярлыком, чтобы показать её при броске кубика.
	var hit_mods: Array = []   # [{label, delta}] — влияют на число «нужно попасть»
	var def_mods: Array = []   # [{label, delta}] — влияют на «защиту» цели
	# Нужное число на кубике считает hit_need_for() — ОДНА формула на весь проект
	# (item 6): по ней стреляем здесь и по ней же ИИ решает, есть ли смысл стрелять.
	# Разбивку для броска она заполняет сама.
	var need := hit_need_for(shooter, target, hit_mods)
	# Штраф стрелка к защите цели (снайпер −2, щитоносец −2, шахтёр −1): цель парирует хуже.
	var parry_need: int = target.armor() + shooter.stats.target_defense_penalty
	if shooter.stats.target_defense_penalty != 0:
		def_mods.append({"label": "Shooter penetration", "delta": shooter.stats.target_defense_penalty})
	# Укрытие цели (§3.7): стрелку сложнее попасть (учтено выше), цель лучше парирует.
	var cover := cover_effect(shooter, target)
	parry_need -= cover["defense_bonus"]
	if cover["defense_bonus"] != 0:
		def_mods.append({"label": "Target cover", "delta": cover["defense_bonus"]})
	# Переносимый труп-щит (#6): +1 к защите за каждый несомый цель труп.
	var corpse_def := _corpse_shield_bonus(target)
	if corpse_def != 0:
		parry_need -= corpse_def
		def_mods.append({"label": "Corpse shield", "delta": corpse_def})
	# Борт челнока прикрывает пассажира от стрелкового оружия (batch 13 S4).
	if seated_vehicle_of(target) != null:
		parry_need -= MCF.SHUTTLE_PASSENGER_DEFENSE_BONUS
		def_mods.append({"label": "Shuttle hull", "delta": MCF.SHUTTLE_PASSENGER_DEFENSE_BONUS})
	# Щитоносец получает урон только в упор; снайпер — исключение (§3.14).
	var shield_immune := _shield_blocks_shot(shooter, target)
	var shot_details: Array = []
	var hits := 0
	var killed := false
	var fired := 0
	# Стёкла между стрелком и целью (#29). Каждая пуля пробивает КАЖДОЕ отдельным
	# броском — оттого из очереди в четыре пули сквозь одно стекло проходят обычно две.
	var glass_cells := _glass_cells_on_line(shooter.coord, target.coord)
	var panes := glass_cells.size()
	# Стекло, сквозь которое прошла хоть одна пуля, разбивается (item 4). Копим здесь,
	# бьём после очереди — чтобы порядок бросков на пробитие не сбился на полпути.
	var shattered: Dictionary = {}
	var stopped_by_glass := 0
	if panes > 0:
		hit_mods.append({"label": "Glass on the line", "delta": 0})
	# Очередь отстреливается ЦЕЛИКОМ: ровно один кубик на каждую заказанную пулю (#96).
	# Пули уходят разом, поэтому смерть цели на первой из них очередь НЕ обрывает.
	# Раньше обрывала — а вместе с ней обнулялся и action_state, так что остаток
	# оплаченной одним ОД очереди пропадал, и вместо четырёх бросков игрок видел один.
	for _i in want:
		fired += 1
		# Стекло проверяется ДО броска на попадание: застрявшая в нём пуля до цели
		# не долетает, и бросать за неё «попал/не попал» не за что.
		var glass_rolls: Array = []
		var pierced := true
		for pane_i in panes:
			var g_roll := state.dice.roll_d6()
			glass_rolls.append(g_roll)
			# У обычного стекла бросок решает, ПРОБИЛА ли его пуля (4+ — прошла).
			# У бронированного тот же бросок читается наоборот: 4+ — стекло УСТОЯЛО и
			# пуля в нём завязла. Порог совпал случайно, поэтому считаем их порознь:
			# сравняй их в одну строку, и правка одного молча поменяет другое.
			var gcell_i := state.grid.cell(glass_cells[pane_i])
			# Стекло держит пулю как броня (MCF.glass_bullet_save): обычное на 5+, бронестекло
			# на 4+; не устояло — пуля прошла, и стекло осыпалось.
			var hold: int = MCF.glass_bullet_save(gcell_i.feature_id) if gcell_i != null \
					else MCF.GLASS_BULLET_SAVE
			var through: bool = g_roll < hold
			if not through:
				pierced = false
				break
			# Пуля прошла сквозь это стекло — значит оно пробито и осыплется (item 4).
			shattered[glass_cells[pane_i]] = true
		if not pierced:
			stopped_by_glass += 1
			shot_details.append({
				"hit_roll": 0, "need": need, "hit": false,
				"def_roll": 0, "armor": parry_need, "parried": true,
				"glass_rolls": glass_rolls, "glass_need": MCF.GLASS_BULLET_SAVE,
				"stopped_by_glass": true,
			})
			continue
		var hit_roll := state.dice.roll_d6()
		var is_hit := hit_roll >= need
		var det := {
			"hit_roll": hit_roll, "need": need, "hit": is_hit,
			"def_roll": 0, "armor": parry_need, "parried": true,
		}
		# Поля стекла кладутся ТОЛЬКО когда стекло на линии есть. Иначе они попали бы
		# в каждый выстрел каждой партии — и в след регрессии, и в раскладку кубика в
		# UI, — притом что рассказывать им было бы не о чем.
		if panes > 0:
			det["glass_rolls"] = glass_rolls
			det["glass_need"] = MCF.GLASS_BULLET_SAVE
			det["stopped_by_glass"] = false
		if is_hit:
			hits += 1
			var def_roll := state.dice.roll_d6()  # цель парирует броском на защиту (§3.5)
			det["def_roll"] = def_roll
			det["parried"] = shield_immune or def_roll >= parry_need
			if not det["parried"]:
				killed = true  # один непарированный удар = смерть (§3.5)
		shot_details.append(det)

	shooter.action_state.remaining_shots -= fired
	if killed or shooter.action_state.remaining_shots <= 0:
		shooter.action_state = null
	# Отчёт собирается ДО смерти: _kill складывает в него описание крови (#21.4), а
	# сама смерть обязана случиться РАНЬШЕ невесомости — _apply_zero_g отбрасывает
	# только живых, и переставь её местами, труп в космосе начал бы улетать.
	var result := ActionResult.new()
	result.ok = true
	# Осыпаем пробитые стёкла (item 4): пуля прошла — рама больше не держит. Осколки
	# летят прочь от стрелка. Снос — повод активации нейтралов вокруг клетки (§3.1a).
	for gc: Vector2i in shattered:
		var gcell := state.grid.cell(gc)
		if gcell != null and MCF.is_glass(gcell.feature_id):
			gcell.clear_feature()
			notify_cell_changed(gc)
			_fx(result, {"fx": "shards", "at": gc, "from": shooter.coord})
			# После осыпания стекла клетка становится РАЗРУШЕННЫМ полом (item 7).
			_fx(result, {"fx": "debris", "at": NOWHERE, "cells": [gc]})
	if killed and target.is_drone:
		# Сбитый дрон падает и рвётся под собой (batch ui-drones): тот же взрыв, что и
		# подрыв оператором, — по клетке, над которой он висел.
		# Удар по технике — как у подрыва: без борта и без названного узла.
		var keep_from := _aim_from
		var keep_comp := _aimed_component
		_aim_from = NOWHERE
		_aimed_component = ""
		var boom := _drone_explode(target, target.coord, "shot down", 0)  # только клетка под ним
		_aim_from = keep_from
		_aimed_component = keep_comp
		result.log_lines.append_array(boom.log_lines)
		result.deaths.append_array(boom.deaths)
		result.dice_events.append_array(boom.dice_events)
		result.fx.append_array(boom.fx)
	elif killed:
		_kill(target, result, shooter.coord)  # труп остаётся на клетке, но не перекрывает ЛОС

	# Невесомость (§3.11): отдача стрелка и отбрасывание цели (кроме противотанкиста).
	_apply_zero_g(shooter, target)

	# Гильза на каждый ушедший выстрел (#21.3), вылетают за спину стрелка.
	if fired > 0:
		_fx_lane(result, shooter.coord, target.coord, shooter.owner)  # issue 8
		_fx(result, {"fx": "casings", "at": shooter.coord,
			"toward": target.coord, "count": fired})
		# Пуля летит от стрелка к цели (item 16) — по трассеру на выстрел.
		_fx(result, {"fx": "tracer", "at": shooter.coord,
			"from": [shooter.coord.x, shooter.coord.y],
			"to": [target.coord.x, target.coord.y], "count": fired})
	if shield_immune:
		def_mods.append({"label": "Shield blocks (immune)", "delta": 0})
	result.dice_events.append({
		"kind": "attack", "shooter": shooter.stats.display_name,
		"target": target.stats.display_name, "need": need,
		"armor": parry_need, "shots": shot_details, "killed": killed,
		"hit_mods": hit_mods, "def_mods": def_mods, "def_owner": target.owner,
		"shooter_owner": shooter.owner,  # чей бросок на попадание (item 13: игрок катит сам)
	})
	if redirect_line != "":
		result.log(redirect_line)
	var summary := "%s → %s: %d shots, %d hits (need %d+)" % [
		shooter.stats.display_name, target.stats.display_name, fired, hits, need
	]
	result.log(summary)
	if stopped_by_glass > 0:
		result.log("… %d of %d stopped by the glass (it holds on %d+)" % [
			stopped_by_glass, fired, MCF.GLASS_BULLET_SAVE])
	if killed:
		result.log("%s killed!" % target.stats.display_name)
		result.deaths.append(target.id)
	if shooter.action_state != null:
		result.log("… shots remaining in burst: %d" % shooter.action_state.remaining_shots)
	return result

## Снять незавершённую очередь (#12): игрок ткнул мимо траектории — значит стрелять
## этой очередью он передумал. ОД не возвращается (действие уже оплачено), пули просто
## пропадают. Идёт через резолвер, а не правкой action_state из UI: иначе у клиента
## очередь осталась бы висеть и следующий выстрел разошёлся бы с хостом.
func _resolve_cancel_shot(intent: CancelShotIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	if unit == null or not unit.is_alive():
		return ActionResult.fail("Unit not found")
	if unit.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if unit.action_state == null or not unit.action_state.is_pending():
		return ActionResult.fail("No burst to cancel")
	var left: int = unit.action_state.remaining_shots
	unit.action_state = null
	return ActionResult.success(["%s holds fire — %d shot(s) in the burst dropped." % [
		unit.stats.display_name, left]])

# --- Противотанкист (§3.14): выстрел-взрыв, авто-поражение в радиусе 1 ---
## center — клетка эпицентра (координата цели ИЛИ пустой клетки пола, §3.14).
## center — куда ложится заряд; aimed — узел машины, если стрелок его назвал.
func _resolve_anti_tank(shooter: UnitInstance, center: Vector2i, aimed: String = "") -> ActionResult:
	_aimed_component = aimed
	_aim_from = shooter.coord
	if shooter.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	shooter.remaining_ap -= 1
	shooter.action_state = null

	var result := ActionResult.new()
	result.ok = true
	# Крупная оранжевая гильза за спину стрелка (item 24) — та же система, что у пуль,
	# но вид «shell_casing». Направление — на цель (частица летит от неё, назад).
	_fx(result, {"fx": "casings", "at": shooter.coord, "toward": center,
		"count": 1, "shell": true})
	_fx_lane(result, shooter.coord, center, shooter.owner, "blast")  # issue 8
	# Выстрел ПОД СЕБЯ (#11): заряд кладётся в собственную клетку, и мазать тут
	# нечем — бросок не делается вовсе. Кубик здесь не просто лишний: любой
	# холостой бросок сдвигает поток случайности и разводит хост с клиентом.
	var landing := center
	if center == shooter.coord:
		result.log("%s fires at their own feet — the charge lands at (%d, %d)." % [
			shooter.stats.display_name, center.x, center.y])
	else:
		# Бросок на попадание (#7): промах НЕ отменяет взрыв — заряд ложится ближе.
		var dist := Combat.distance(shooter.coord, center)
		var need := Combat.hit_number(dist, shooter.fire_range())
		var roll := state.dice.roll_d6()
		var on_target := roll >= need
		landing = _shortfall_landing(shooter.coord, center, roll, need)
		result.dice_events.push_front({
			"kind": "check", "actor": shooter.stats.display_name,
			"roll": roll, "need": need, "ok": on_target,
		})
		if on_target:
			result.log("%s: roll %d (need %d+) — direct hit at (%d, %d)!" % [
				shooter.stats.display_name, roll, need, landing.x, landing.y])
		else:
			result.log("%s: roll %d (need %d+) — missed, charge fell short at (%d, %d)." % [
				shooter.stats.display_name, roll, need, landing.x, landing.y])
	# Снимок «до взрыва» для показа во время броска (item 22).
	var at_area := MCF.blast_square(landing, MCF.ANTI_TANK_BLAST_RADIUS)
	_capture_visual_hold(result, at_area)
	# Прямое попадание в ДОТ: бетон забирает весь удар, осколочного поля нет.
	_blast_armor_wall(landing, result)
	if _pillbox_absorbs(landing, MCF.ANTI_TANK_VEHICLE_DAMAGE, result):
		return result
	var area := MCF.blast_square(landing, MCF.ANTI_TANK_BLAST_RADIUS)
	var killed_names := _blast(landing, result, area)
	# Технике взрыв тоже вредит (#67): раньше противотанкист выкашивал пехоту вокруг
	# танка, а сам танк оставался с нетронутой прочностью. Снимаем единицу с каждой
	# машины, чей след задет взрывом.
	_damage_vehicles_in_area(area, landing, MCF.COMPONENT_DAMAGE_ANTI_TANK, -1, result,
		shooter.stats.display_name, _aimed_component)
	if killed_names.is_empty():
		result.log("… nobody destroyed")
	else:
		for n in killed_names:
			result.log("%s destroyed!" % n)
	return result

## Куда на самом деле лёг заряд (#7, #22). Попадание — точно в цель; промах кладёт
## его НЕ ДОЛЕТЕВ, на дистанции, пропорциональной броску: landing = dist · roll / need
## вдоль линии огня (18 кл., нужно 6, выпало 5 → взрыв на 15-й клетке).
##
## Общая для противотанкиста и танковой пушки — этого требует #22 («тот же механизм
## разрешения попадания, что у противотанкиста»). У пушки была своя формула недолёта
## (dist − (need − roll)), и на дальних дистанциях она давала совсем другую точку.
func _shortfall_landing(from_coord: Vector2i, target: Vector2i, roll: int, need: int) -> Vector2i:
	if roll >= need or need <= 0:
		return target
	var dist := Combat.distance(from_coord, target)
	var land_index: int = clampi(int(dist * roll / float(need)), 0, dist)
	if land_index <= 0:
		return from_coord
	return _throw_path(from_coord, target)[land_index - 1]

## Опасен ли выстрел противотанкиста ДЛЯ СВОИХ (issue 3) — «AI Anti-tank units kill
## themselves when they're shooting, it happens a lot».
##
## Заряд накрывает квадрат 3×3 вокруг ТОЧКИ ПАДЕНИЯ, а промах (#7) кладёт его НЕ ДОЛЕТЕВ:
## landing = dist · roll / need вдоль линии огня. На единице кубика заряд ложится в
## первую-вторую клетку от стрелка — то есть себе под ноги, — и осколки забирают его
## самого. Живой игрок видит это по трассе и в упор не бьёт; ИИ же брал ближайшую цель
## на луче и регулярно подрывался.
##
## Считаем ВСЕ шесть исходов кубика (их ровно шесть, и они известны заранее): попадёт
## ли хоть один взрыв на самого стрелка или на его союзника. Да — выстрел не предлагаем.
## Оценка НАМЕРЕННО осторожная: прикрытие чужим щитоносцем в расчёт не берём (он к
## следующему ходу отойдёт), а окоп и собственный щит — берём, они при бойце.
##
## Обходим не армию, а клетки взрыва: их не больше 6×9, и жильца каждой отдаёт сама
## сетка. На переборе целей ИИ это разница между сотней проверок и сотней тысяч.
func anti_tank_shot_endangers_own(shooter: UnitInstance, center: Vector2i) -> bool:
	if shooter == null or not _is_anti_tank(shooter):
		return false
	# Выстрел под себя (#11) — гарантированное самоубийство, кубик там не бросается.
	if center == shooter.coord:
		return true
	var need := Combat.hit_number(
		Combat.distance(shooter.coord, center), shooter.fire_range())
	# Клетка -> лежит ли она в ЭПИЦЕНТРЕ хоть одного из шести исходов: в эпицентре не
	# спасают ни окоп (#30), ни щит (§3.14), по соседней клетке — спасают оба.
	var risk: Dictionary = {}
	for roll in range(1, 7):
		var landing := _shortfall_landing(shooter.coord, center, roll, need)
		for c: Vector2i in MCF.blast_square(landing, MCF.ANTI_TANK_BLAST_RADIUS):
			if c == landing:
				risk[c] = true
			elif not risk.has(c):
				risk[c] = false
	var grid := state.grid
	for c: Vector2i in risk:
		var cell := grid.cell(c)
		if cell == null:
			continue
		var occ := cell.occupant
		if occ == null or not occ.is_alive():
			continue
		if occ.id != shooter.id and not is_ally_of(shooter, occ):
			continue  # чужого взрыв и должен накрывать — за этим и стреляем
		if not bool(risk[c]):
			# Не эпицентр: окоп прячет от осколков (#30), щитоносец их держит (§3.14).
			if cell.feature_id == MCF.FEATURE_TRENCH or _is_shield(occ):
				continue
		return true
	return false

## Снять «визуальный слепок» зоны ДО взрыва (item 22): прежние объекты клеток и прежняя
## прочность/целость техники в области. UI показывает их, пока крутится кубик выстрела,
## и разрушение не опережает бросок. Чисто косметика — на состояние не влияет.
func _capture_visual_hold(res: ActionResult, area: Array) -> void:
	if res == null:
		return
	var cells: Dictionary = res.visual_hold.get("cells", {})
	for c: Vector2i in area:
		var cell := state.grid.cell(c)
		if cell == null or cells.has(c):
			continue
		cells[c] = {
			"feature_id": cell.feature_id, "feature_durability": cell.feature_durability,
			"cover_height": cell.cover_height, "corpse_count": cell.corpse_count,
		}
	res.visual_hold["cells"] = cells
	var vehs: Dictionary = res.visual_hold.get("vehicles", {})
	var in_area := {}
	for c: Vector2i in area:
		in_area[c] = true
	for veh: Vehicle in state.all_vehicles():
		if vehs.has(veh.id):
			continue
		for fc in veh.footprint():
			if in_area.has(fc):
				vehs[veh.id] = {"durability": veh.durability, "wrecked": veh.wrecked}
				break
	res.visual_hold["vehicles"] = vehs

## Взрыв: авто-уничтожение всех живых в зоне поражения, кроме щитоносцев вне
## эпицентра (они прикрывают союзников рядом). Возвращает имена погибших (§3.14).
## Общий для противотанкиста и дрона (§3.12). Также сносит станции дронов в зоне.
## cells — форма взрыва; пусто = квадрат 3×3 (радиус 1 по Чебышёву), как у
## противотанкиста. Танковая пушка передаёт свой ромб радиуса 2 (#63).
func _blast(center: Vector2i, res: ActionResult = null, cells: Array[Vector2i] = [],
		epicenter_debris: bool = true) -> Array:
	var area: Array[Vector2i] = cells
	if area.is_empty():
		area = MCF.blast_square(center, MCF.ANTI_TANK_BLAST_RADIUS)
	var in_area := {}
	for c: Vector2i in area:
		in_area[c] = true

	var protectors: Array = []
	for u in state.all_units():
		if u.is_alive() and _is_shield(u) and in_area.has(u.coord) and u.coord != center:
			protectors.append(u)

	var killed_names: Array = []
	# Пассажиры челноков в зоне (batch 13 S5): тот, чьё кресло — точка разрыва, гибнет,
	# остальные бросают защиту. Разбирается по машинам, чтобы один пассажир не был
	# посчитан дважды.
	var seated_hit: Dictionary = {}
	for veh: Vehicle in state.all_vehicles():
		if not (_seated(veh) or veh.is_borg()) or not veh.alive():
			continue
		var touched := false
		for uid in veh.occupants:
			var pu := state.get_unit(uid)
			if pu != null and pu.is_alive() and in_area.has(pu.coord):
				touched = true
				break
		if touched:
			seated_hit[veh.id] = true
			killed_names.append_array(_shuttle_passengers_hit(veh, center, in_area, res))
	for u in state.all_units():
		if not u.is_alive():
			continue
		if not in_area.has(u.coord):
			continue
		if (u.aboard_vehicle_id != -1 and seated_hit.has(u.aboard_vehicle_id)) \
				or (u.borg_id != -1 and seated_hit.has(u.borg_id)):
			continue  # уже разобран как пассажир / оператор борга
		if _is_shield(u) and u.coord != center:
			continue  # щитоносец гибнет только при прямом попадании
		# Окоп укрывает от взрыва по СОСЕДНЕЙ клетке (#30): осколки идут поверх
		# канавы. Прямое попадание в саму канаву по-прежнему убивает.
		if u.coord != center and state.grid.cell(u.coord).feature_id == MCF.FEATURE_TRENCH:
			continue
		if _protected_by(u, protectors):
			continue
		_kill(u, res, center, true)
		killed_names.append(u.stats.display_name)
		if res != null:
			res.deaths.append(u.id)

	# Взрыв сносит укрепления в зоне: стены, стекло, шлюзы, ЛДФ, деревянные и
	# трупные стены, станции дронов и ДПМГ (§3.6/§3.7/§3.12). ДОТ устойчив (#17).
	# Сам взрыв — повод активации нейтралов вокруг эпицентра (§3.1a).
	notify_cell_changed(center)
	for c: Vector2i in area:
		_blast_destroy_terrain(c, res, center)
	# Побитый пол по ВСЕЙ зоне, эпицентр — отдельной текстурой (#21.1). Мина просит
	# ОБЫЧНЫЙ щебень без эпицентра (item 13): передаёт at=NOWHERE, и ни одна клетка не
	# совпадёт с «эпицентром», значит вся зона осядет рядовым разрушением.
	_fx(res, {"fx": "debris", "at": center if epicenter_debris else NOWHERE, "cells": area})
	return killed_names

## Прямое попадание в прочное укрепление (ДОТ, §3.7): бетонная коробка принимает удар
## ЦЕЛИКОМ на себя — теряет damage прочности, а осколочного поля вокруг не возникает
## вовсе, поэтому боец на соседней клетке уцелеет. Считается только попадание ровно в
## клетку ДОТа: взрыв рядом с ним по-прежнему его не задевает.
## true — удар поглощён, вызывающему больше нечего применять.
func _pillbox_absorbs(center: Vector2i, damage: int, res: ActionResult) -> bool:
	if not state.grid.in_bounds(center):
		return false
	var cell := state.grid.cell(center)
	if cell.feature_durability <= 0:
		return false
	var was: String = MCF.FEATURE_NAMES.get(cell.feature_id, cell.feature_id)
	cell.feature_durability -= damage
	if cell.feature_durability <= 0:
		cell.clear_feature()
		res.log("%s at (%d, %d) absorbs the hit and collapses!" % [was, center.x, center.y])
	else:
		res.log("%s at (%d, %d) absorbs the hit and cracks [durability %d]." % [
			was, center.x, center.y, cell.feature_durability])
	return true

## Взрыв рушит укрепления клетки: стены/стекло/шлюзы/ЛДФ/деревянные/трупные стены,
## станции дронов и ДПМГ. Прочные укрепления (ДОТ) осколками не берутся (#17, §3.7):
## им нужно прямое попадание, которое обрабатывает _pillbox_absorbs.
## from_coord — откуда пришёл удар: осколки стекла (#21.2) летят ПРОТИВ него.
func _blast_destroy_terrain(c: Vector2i, res: ActionResult = null,
		from_coord: Vector2i = NOWHERE) -> void:
	if not state.grid.in_bounds(c):
		return
	var cell := state.grid.cell(c)
	var fid := cell.feature_id
	if cell.feature_durability > 0:
		return
	var destructible := [
		MCF.FEATURE_WALL, MCF.FEATURE_SOIL, MCF.FEATURE_GLASS, MCF.FEATURE_ARMOR_GLASS,
		MCF.FEATURE_AIRLOCK, MCF.FEATURE_LDF, MCF.FEATURE_WOOD_WALL, MCF.FEATURE_CORPSE_WALL,
		MCF.FEATURE_DRONE_STATION, MCF.FEATURE_DPMG,
		MCF.FEATURE_SANDBAGS, MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS,
		# Низкие укрытия сносит той же волной (#97): ёж и куча земли переживали взрыв,
		# который валил каменную стену рядом, и поле оставалось «в клетку».
		MCF.FEATURE_HEDGEHOG, MCF.FEATURE_DIRT_PILE,
		# Взрыв подрывает и мины в зоне (item 45) — иначе после обстрела минное поле
		# оставалось бы нетронутым посреди голой земли. Противотанковую тоже сносит
		# взрывом (item 13), хотя огонь её не берёт.
		MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE,
		# БРОНЕВОЙ ПЛИТЫ здесь нет намеренно (веха 14.1): осколки её не берут, и это
		# единственное место, где её неуязвимость к чужим разрывам и записана. Добавишь
		# сюда — и она станет обычной стеной; прямой разрыв в неё сносит её отдельно,
		# через _blast_armor_wall.
	]
	if fid in destructible:
		if MCF.is_glass(fid):
			_fx(res, {"fx": "shards", "at": c,
				"from": from_coord if from_coord != NOWHERE else c})
			_fx(res, {"fx": "debris", "at": NOWHERE, "cells": [c]})  # разрушенный пол (item 7)
		cell.clear_feature()
		notify_cell_changed(c)  # снесённое укрепление будит соседей квартала (§3.1a)
		# Стену из трупов взрыв не стирает, а вскрывает (#98): пять тел вылетают из неё
		# и падают порознь вокруг. Разлёт идёт ПОСЛЕ clear_feature — иначе одно из тел
		# могло бы лечь на клетку, которую та же зачистка тут же и опустошит.
		if fid == MCF.FEATURE_CORPSE_WALL:
			cell.corpse_count = 0
			_scatter_corpses_random(c, MCF.CORPSE_WALL_COUNT, res)
	elif fid == "" and cell.is_wall():
		# Безымянная стена рельефа (высота ≥ 2 без объекта) — тоже рушится.
		cell.cover_height = 0.0

# --- Огнемётчик (§3.14): струя пламени 6×1, авто-убийство на пути ---
## target_coord — клетка цели (юнит) ИЛИ пустая клетка пола (§3.14): струя идёт
## в её направлении. Направление берётся как единичный шаг к клетке.
func _resolve_flame(shooter: UnitInstance, target_coord: Vector2i) -> ActionResult:
	if shooter.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	shooter.remaining_ap -= 1
	shooter.action_state = null
	var step := _step_toward(shooter.coord, target_coord)

	# result заводится ДО цикла: сожжённых струёй надо записать в result.deaths, иначе
	# награда за бой их не увидит (см. ниже про _blast).
	var result := ActionResult.new()
	result.ok = true
	var killed_names: Array = []
	var last := shooter.coord  # конец струи — для дорожки «кто в кого»
	for c: Vector2i in flame_cells(shooter.coord, step):
		var cell := state.grid.cell(c)
		var occ: UnitInstance = cell.occupant
		if occ != null and occ.is_alive():
			_kill(occ)  # огнемёт — крови нет
			killed_names.append(occ.stats.display_name)
			result.deaths.append(occ.id)
		_ignite(cell, shooter.owner)  # поджог пола (§3.8)
		if Combat.is_on_firing_line(shooter.coord, c) and _step_toward(shooter.coord, c) == step:
			last = c

	_fx_lane(result, shooter.coord, last, shooter.owner, "flame")  # issue 8
	result.log("%s: flame jet" % shooter.stats.display_name)
	if killed_names.is_empty():
		result.log("… nobody hit")
	else:
		for n in killed_names:
			result.log("%s burned!" % n)
	return result

## Клетки, которые накроет струя из from_coord шагом step (§3.14): ровно
## FLAME_JET_LENGTH клеток, если поле позволяет. Удар о стену/ЛДФ/щитоносца — остаток
## разлетается перпендикулярно от последней пройденной клетки, поровну на две стороны;
## сторона, упёршаяся в стену или край, отдаёт недобранное другой (batch 17, item 5:
## диагональная струя в прямую стену теряла половину разлёта о ту же стену).
## Одна геометрия для выстрела и предпросмотра — они не могут разойтись.
func flame_cells(from_coord: Vector2i, step: Vector2i) -> Array:
	var out: Array = []
	if step == Vector2i.ZERO:
		return out
	var last := from_coord
	var cur := from_coord + step
	for i in MCF.FLAME_JET_LENGTH:
		if not state.grid.in_bounds(cur) or _flame_blocked(cur):
			if state.grid.in_bounds(cur):
				_flame_splash(last, step, MCF.FLAME_JET_LENGTH - i, out, from_coord)
			break
		out.append(cur)
		last = cur
		cur += step
	return out

## Разлёт остатка струи от клетки origin. Отдаёт ВСЕ remaining клеток, если на поле
## есть куда их деть, — «шесть клеток всегда» это инвариант, а не пожелание.
##
## Прежний код раздавал остаток за один проход: половину налево, остальное направо, и
## один-единственный добор налево — да и тот под условием l > 0. Из-за этого он ТЕРЯЛ
## клетки в двух случаях. Если левая сторона упиралась сразу (l = 0), а правая
## обрывалась раньше срока, добирать было некому — условие l > 0 не пускало. Если обе
## стороны упирались (струя в угол), не появлялось вообще ничего: огнемёт бил в упор
## в угол и поджигал в лучшем случае одну клетку вместо шести.
##
## Теперь это три ступени, каждая подбирает то, что не смогла предыдущая:
##   1. поровну в обе стороны, как и раньше;
##   2. недобор одной стороны отдаётся другой — в ЛЮБУЮ сторону, а не только налево;
##   3. если и после этого мало (угол), огонь растекается волной от уже занятых
##      клеток по соседям — так же, как он потом расползается сам (§3.8).
func _flame_splash(origin: Vector2i, step: Vector2i, remaining: int, out: Array,
		from_coord: Vector2i) -> void:
	var left := Vector2i(-step.y, step.x)
	var right := Vector2i(step.y, -step.x)
	var l := _flame_walk(origin, left, int(ceil(remaining / 2.0)), out)
	var r := _flame_walk(origin, right, remaining - l, out)
	if l + r < remaining:
		l += _flame_walk(origin + left * l, left, remaining - l - r, out)
	if l + r < remaining:
		r += _flame_walk(origin + right * r, right, remaining - l - r, out)
	if l + r < remaining:
		_flame_flood(origin, remaining - l - r, out, from_coord)

## Волна по соседям от уже подожжённых клеток, пока не наберётся count штук.
## Клетку самого огнемётчика не трогаем: струя из него выходит, а не в него.
func _flame_flood(origin: Vector2i, count: int, out: Array, from_coord: Vector2i) -> void:
	var seen := {from_coord: true, origin: true}
	for c: Vector2i in out:
		seen[c] = true
	var frontier: Array[Vector2i] = [origin]
	frontier.append_array(out)
	var added := 0
	while added < count and not frontier.is_empty():
		var next: Array[Vector2i] = []
		for f: Vector2i in frontier:
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					var c := f + Vector2i(dx, dy)
					if seen.has(c) or not state.grid.in_bounds(c) or _flame_blocked(c):
						continue
					seen[c] = true
					out.append(c)
					next.append(c)
					added += 1
					if added >= count:
						return
		frontier = next

func _flame_blocked(c: Vector2i) -> bool:
	var cell := state.grid.cell(c)
	var occ: UnitInstance = cell.occupant
	return cell.is_wall() or (occ != null and occ.is_alive() and _is_shield(occ))

## Разлёт по направлению dir на count клеток от origin, до стены/щитоносца/края.
## Возвращает, сколько клеток набрано.
func _flame_walk(origin: Vector2i, dir: Vector2i, count: int, out: Array) -> int:
	var cur := origin + dir
	var n := 0
	for _i in count:
		if not state.grid.in_bounds(cur) or _flame_blocked(cur):
			return n
		out.append(cur)
		n += 1
		cur += dir
	return n

## Поджечь клетку, запомнив сторону-поджигателя: огонь расползается только на её ходу (#45).
func _ignite(cell: GridCell, owner: int) -> void:
	cell.on_fire = true
	cell.fire_owner = owner
	# Появление огня — повод активации соседних нейтралов (§3.1a).
	notify_cell_changed(cell.coord)

## Сбить пламя с клетки. Любая работа по клетке — стройка, окоп, поставленный на неё
## объект — тушит огонь: землю перекапывают, а укрепление придавливает очаг (#82).
func _extinguish_cell(cell: GridCell) -> bool:
	if cell == null or not cell.on_fire:
		return false
	cell.on_fire = false
	cell.fire_owner = -1
	return true

# --- Марксманн (§3.13): лазер с потенциалом 10, пробитие, 2 ОД ---
## Целиться можно и в бойца, и просто в НАПРАВЛЕНИЕ (#49): луч уходит по лучу от стрелка
## и летит вперёд, пока хватает потенциала, — точная клетка прицела роли не играет.
## aimed — узел машины, который марксман назвал заранее. Луч узел не разыгрывает: он
## бьёт туда, куда его навели, и снимает по очку за каждые LASER_POTENTIAL_PER_COMPONENT
## потенциала — больше, чем в узле осталось, снять нельзя.
func _resolve_laser(shooter: UnitInstance, aim: Vector2i, aimed: String = "") -> ActionResult:
	if shooter.remaining_ap < MCF.MARKSMAN_AP_COST:
		return ActionResult.fail("Laser needs %d AP" % MCF.MARKSMAN_AP_COST)
	var step := _step_toward(shooter.coord, aim)
	if step == Vector2i.ZERO:
		return ActionResult.fail("Pick a direction to fire in")
	shooter.remaining_ap -= MCF.MARKSMAN_AP_COST
	shooter.action_state = null

	var result := ActionResult.new()
	result.ok = true
	var potential := MCF.MARKSMAN_POTENTIAL
	var killed_names: Array = []
	# Докуда дотянулся луч — для следа на полу (item 10). Обновляется на каждой клетке.
	var beam_last := shooter.coord
	# Стены, которые луч разнёс, — под ними разбитый пол, как под гусеницей танка.
	var blasted: Array[Vector2i] = []
	# Трассу считает тот же код, что рисует предпросмотр (laser_path), — подсветка
	# и настоящий выстрел не могут разойтись.
	for rec: Dictionary in _laser_trace(shooter.coord, step):
		potential -= int(rec["cost"])
		var c: Vector2i = rec["coord"]
		beam_last = c
		var cell := state.grid.cell(c)
		var destroyed: bool = bool(rec["destroyed"])
		match String(rec["kind"]):
			"vehicle":
				var veh := state.get_vehicle(int(rec["vehicle_id"]))
				var dmg := int(rec["damage"])
				if veh != null and dmg > 0:
					# Луч выжигает НАЗВАННЫЙ узел, без бросков — как подрыв дрона. Но
					# видеть его марксман обязан: гусеница с дальнего борта закрыта
					# корпусом, и луч до неё не достанет. Не назвали, не видно или узла
					# уже нет — жжём корпус: в него луч упирается в любом случае.
					var reachable := _aimable_components(veh, shooter.coord)
					var comp: String = aimed if reachable.has(aimed) else MCF.COMP_HULL
					_damage_component(veh, comp, mini(dmg, veh.component(comp)),
						"laser", result)
			"shield", "unit":
				var occ: UnitInstance = cell.occupant
				if destroyed and occ != null and occ.is_alive():
					_kill(occ)  # луч прижигает — крови нет (batch ui-drones)
					killed_names.append(occ.stats.display_name)
					result.deaths.append(occ.id)
			"feature":
				var was: String = cell.feature_id
				var cracks := int(rec["cracks"])
				if cracks > 0:
					cell.feature_durability -= cracks
				if destroyed:
					if cell.is_wall():
						blasted.append(c)
					cell.clear_feature()
					result.log("Beam destroys %s at (%d, %d)" % [
						MCF.FEATURE_NAMES.get(was, was), c.x, c.y])
					# Стена из трупов рассыпается вдоль траектории луча (таблица §3.13).
					if was == MCF.FEATURE_CORPSE_WALL:
						cell.corpse_count = 0
						_scatter_corpses(c, step, MCF.CORPSE_WALL_COUNT)
						result.log("… bodies scatter along the beam")
				elif cracks > 0:
					result.log("Beam cracks %s at (%d, %d) [durability %d]" % [
						MCF.FEATURE_NAMES.get(was, was), c.x, c.y, cell.feature_durability])
			"terrain":
				if destroyed:
					cell.cover_height = 0.0
					blasted.append(c)
					result.log("Beam blows the wall at (%d, %d) apart" % [c.x, c.y])

	# Разбитый пол там, где луч снёс стену (та же метка, что кладёт переезд танка): без
	# эпицентра — луч не взрывается, он прожигает насквозь.
	if not blasted.is_empty():
		_fx(result, {"fx": "debris", "at": NOWHERE, "cells": blasted})

	# След луча на полу от стрелка до точки остановки (item 10) — чистая косметика.
	_fx(result, {"fx": "laser", "from": [shooter.coord.x, shooter.coord.y],
		"to": [beam_last.x, beam_last.y]})
	_fx_lane(result, shooter.coord, beam_last, shooter.owner, "beam")  # issue 8
	result.log_lines.push_front("%s: laser shot %s (potential left %d)" % [
		shooter.stats.display_name, _dir_name(step), maxi(0, potential)])
	if killed_names.is_empty():
		result.log("… nobody struck")
	else:
		for n in killed_names:
			result.log("%s struck by the beam!" % n)
	return result

## Разлёт трупов рухнувшей стены вдоль траектории луча: по одному телу на клетку,
## начиная с самой стены и дальше вперёд, пропуская стены и корпуса машин.
func _scatter_corpses(from_coord: Vector2i, step: Vector2i, count: int) -> void:
	var cur := from_coord
	var left := count
	while left > 0 and state.grid.in_bounds(cur):
		var cell := state.grid.cell(cur)
		# Клетку, забитую телами до предела, луч перешагивает (#98): пятое тело сложило
		# бы там новую стену прямо в трассе только что пробитого прохода.
		if not cell.is_wall() and cell.vehicle_id == -1 \
				and corpses_at(cur) < MCF.CORPSE_WALL_COUNT:
			cell.corpse_count += 1
			left -= 1
		cur += step

## Трасса лазерного луча по таблице потери потенциала (§3.13). Состояние НЕ меняется:
## возвращает упорядоченный список записей о том, что луч встретит и во что это ему
## обойдётся. Общая основа для выстрела и для предпросмотра в UI.
##   kind: empty | unit | shield | feature | terrain | vehicle
##   cost — сколько потенциала съест клетка, destroyed — уничтожит ли её луч,
##   cracks — снятая прочность (ДОТ), damage — снятая прочность техники.
func _laser_trace(from_coord: Vector2i, step: Vector2i) -> Array:
	var out: Array = []
	if step == Vector2i.ZERO:
		return out
	var potential := MCF.MARKSMAN_POTENTIAL
	var glass_hits := 0
	var cur := from_coord + step
	# Стреляет ли марксман со дна окопа (#105). Тогда луч заперт в канаве: он идёт по ней,
	# пока она идёт, и упирается в земляную стенку на первом же разрыве.
	var from_cell := state.grid.cell(from_coord)
	var from_in_trench := from_cell != null and from_cell.feature_id == MCF.FEATURE_TRENCH
	while state.grid.in_bounds(cur) and potential > 0:
		var cell := state.grid.cell(cur)
		var rec := {
			"coord": cur, "kind": "empty", "cost": 0, "destroyed": false,
			"stop": false, "cracks": 0, "damage": 0, "vehicle_id": -1,
			"label": "", "left": potential,
		}
		# Канава кончилась — дальше грунт на уровне глаз стрелка (#105). Луч гаснет здесь,
		# и всё, что стоит поверху дальше, ему недоступно.
		if from_in_trench and cell.feature_id != MCF.FEATURE_TRENCH:
			rec["kind"] = "terrain"
			rec["label"] = "Trench wall"
			rec["stop"] = true
			out.append(rec)
			break
		# Броневая плита гасит луч, сколько бы потенциала в нём ни оставалось (веха 14.1):
		# прожечь её нельзя, обойти — тем более. В LASER_COST её нет намеренно — там
		# отсутствие означало бы «пролетаем насквозь бесплатно», а тут всё наоборот.
		if cell.feature_id == MCF.FEATURE_ARMOR_WALL:
			rec["kind"] = "terrain"
			rec["label"] = MCF.FEATURE_NAMES[MCF.FEATURE_ARMOR_WALL]
			rec["stop"] = true
			out.append(rec)
			break
		var occ: UnitInstance = cell.occupant
		# Окоп — яма: луч идёт НАД ним (#99). Ни сама яма, ни залёгший в ней боец не
		# трогаются, и потенциал на них не тратится. Поблажки «вплотную достанем» у луча
		# нет (#103): опуститься в яму он не может, откуда бы ни стреляли, — достать
		# лежащего можно только с его же уровня, из окопа.
		if occ != null and occ.is_alive() and trench_protected(from_coord, occ, true):
			rec["label"] = "over the trench"
			out.append(rec)
			cur += step
			continue
		var covering := vehicle_covering(cur)
		if covering != null:
			# Броня: челнок 2 прочности = 20 потенциала, танк 6 = 60. Луч гаснет о корпус
			# в любом случае — пробил он его насквозь или только поцарапал. Борг тоже
			# (batch borg-corpses): у борга с пилотом на сетке нет следа корпуса, в клетке
			# стоит сам пилот, и луч раньше проходил его как пехотинца, насквозь.
			var veh := covering
			var dur: int = veh.durability if veh != null else 1
			var full: int = dur * MCF.POTENTIAL_PER_DURABILITY
			rec["kind"] = "vehicle"
			rec["vehicle_id"] = veh.id
			rec["stop"] = true
			rec["label"] = VehicleDB.get_vehicle(veh.type_id).get("name", "Vehicle") \
					if veh != null else "Vehicle"
			if potential >= full:
				rec["cost"] = full
				rec["damage"] = dur
				rec["destroyed"] = true
			else:
				rec["cost"] = potential
				rec["damage"] = potential / MCF.POTENTIAL_PER_DURABILITY
		elif occ != null and occ.is_alive():
			if _is_shield(occ):
				rec["kind"] = "shield"
				rec["stop"] = true  # щит полностью гасит луч
				rec["label"] = "Shield Bearer"
				rec["cost"] = mini(potential, MCF.LASER_COST_SHIELD)
				rec["destroyed"] = potential >= MCF.LASER_COST_SHIELD
			else:
				# Несомый труп-щит поднимает цену пробития с 2 до 3.
				var kill_cost: int = MCF.LASER_COST_KILL_CORPSE if occ.carried_corpses > 0 \
						else MCF.LASER_COST_KILL
				rec["kind"] = "unit"
				rec["label"] = occ.stats.display_name
				if potential >= kill_cost:
					rec["cost"] = kill_cost
					rec["destroyed"] = true
				else:
					rec["stop"] = true
		elif cell.has_feature() and MCF.LASER_COST.has(cell.feature_id):
			rec["kind"] = "feature"
			rec["label"] = MCF.FEATURE_NAMES.get(cell.feature_id, cell.feature_id)
			if cell.feature_id == MCF.FEATURE_GLASS:
				# Стекло фокусирует луч: каждое второе на пути ВОЗВРАЩАЕТ единицу (#99).
				# Отрицательная стоимость — это прибавка, её же покажет предпросмотр.
				glass_hits += 1
				rec["destroyed"] = true
				if glass_hits % MCF.LASER_GLASS_RECHARGE_EVERY == 0:
					rec["cost"] = -MCF.LASER_GLASS_RECHARGE
			elif cell.feature_durability > 0:
				# Прочная коробка (ДОТ): каждые 10 потенциала снимают 1 прочность.
				var cracks: int = mini(cell.feature_durability,
						potential / MCF.POTENTIAL_PER_DURABILITY)
				rec["cracks"] = cracks
				rec["cost"] = cracks * MCF.POTENTIAL_PER_DURABILITY
				rec["destroyed"] = cracks >= cell.feature_durability
				rec["stop"] = not rec["destroyed"]
			else:
				var f_cost: int = int(MCF.LASER_COST[cell.feature_id])
				# Куча земли — единственный объект с плавающей высотой: на втором уровне
				# она дорастает до стены и тогда стоит как стена, а не как метровое
				# укрытие (#99). Прочим объектам высота цену не меняет — у шлюза она
				# тоже 2 м, но пробивается он за единицу.
				if cell.feature_id == MCF.FEATURE_DIRT_PILE \
						and cell.cover_height >= MCF.WALL_HEIGHT:
					f_cost = MCF.LASER_COST_TERRAIN_WALL
				if potential >= f_cost:
					rec["cost"] = f_cost
					rec["destroyed"] = true
				else:
					rec["stop"] = true
		elif cell.is_wall():
			rec["kind"] = "terrain"
			rec["label"] = "Wall"
			if potential >= MCF.LASER_COST_TERRAIN_WALL:
				rec["cost"] = MCF.LASER_COST_TERRAIN_WALL
				rec["destroyed"] = true
			else:
				rec["stop"] = true
		# Потенциала не хватило даже задеть препятствие — луч гаснет ПЕРЕД клеткой.
		if bool(rec["stop"]) and int(rec["cost"]) == 0:
			break
		potential -= int(rec["cost"])
		rec["left"] = potential
		out.append(rec)
		if bool(rec["stop"]):
			break
		cur += step
	return out

## Читаемое имя направления для журнала боя (#49).
func _dir_name(step: Vector2i) -> String:
	const NAMES := {
		Vector2i(0, -1): "N", Vector2i(1, -1): "NE", Vector2i(1, 0): "E",
		Vector2i(1, 1): "SE", Vector2i(0, 1): "S", Vector2i(-1, 1): "SW",
		Vector2i(-1, 0): "W", Vector2i(-1, -1): "NW",
	}
	return NAMES.get(step, "?")

## Можно ли пустить лазер в сторону клетки (#49): целью служит не боец, а НАПРАВЛЕНИЕ,
## поэтому годится любая клетка поля, кроме той, где стоит сам стрелок.
func can_laser_cell(shooter: UnitInstance, cell: Vector2i) -> String:
	if shooter.stats.special_ability_id != MCF.ABILITY_MARKSMAN:
		return "Only the marksman fires a laser"
	if not state.grid.in_bounds(cell):
		return "Target out of bounds"
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	if _step_toward(shooter.coord, cell) == Vector2i.ZERO:
		return "Pick a direction to fire in"
	if shooter.remaining_ap < MCF.MARKSMAN_AP_COST:
		return "Laser needs %d AP" % MCF.MARKSMAN_AP_COST
	return ""

## Клетки, через которые пройдёт луч, если целиться в aim (для предпросмотра в UI).
## Геометрия та же, что в _resolve_laser, но состояние не меняется (#49).
func laser_path(shooter: UnitInstance, aim: Vector2i) -> Array:
	var out: Array = []
	for rec: Dictionary in _laser_trace(shooter.coord, _step_toward(shooter.coord, aim)):
		out.append(rec["coord"])
	return out

## Полная трасса луча для предпросмотра (#99): те же записи, по которым потом стреляет
## _resolve_laser, так что подписи «−2 потенциала» и место, где луч погаснет, не могут
## разойтись с настоящим выстрелом. Поля: coord, kind, label, cost (минус = прибавка
## от стекла), left — сколько потенциала осталось ПОСЛЕ этой клетки.
func laser_preview(shooter: UnitInstance, aim: Vector2i) -> Array:
	return _laser_trace(shooter.coord, _step_toward(shooter.coord, aim))

# --- Штурмовик (§3.14): дробовик до 3 целей по прямой, пробитие назад ---
func _resolve_assault(shooter: UnitInstance, target: UnitInstance) -> ActionResult:
	if shooter.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	shooter.remaining_ap -= 1
	shooter.action_state = null
	var step := _step_toward(shooter.coord, target.coord)

	# Цепочка: цель + стоящие впритык позади враги, максимум 3 (§3.14).
	var chain: Array = [target]
	var cur := target.coord + step
	while chain.size() < MCF.ASSAULT_MAX_TARGETS and state.grid.in_bounds(cur):
		var occ: UnitInstance = state.grid.cell(cur).occupant
		if occ != null and occ.is_alive() and occ.owner != shooter.owner:
			chain.append(occ)
			cur += step
		else:
			break

	var result := ActionResult.new()
	result.ok = true
	var any_kill := false
	for t in chain:
		var need := Combat.hit_number(Combat.distance(shooter.coord, t.coord), shooter.fire_range())
		var parry_need: int = t.armor() + MCF.ASSAULT_DEFENSE_PENALTY - _corpse_shield_bonus(t)
		var shot_details: Array = []
		var hits := 0
		var t_killed := false
		for _i in shooter.rate_of_fire():
			var hit_roll := state.dice.roll_d6()
			var is_hit := hit_roll >= need
			var det := {
				"hit_roll": hit_roll, "need": need, "hit": is_hit,
				"def_roll": 0, "armor": parry_need, "parried": true,
			}
			if is_hit:
				hits += 1
				var def_roll := state.dice.roll_d6()
				det["def_roll"] = def_roll
				det["parried"] = def_roll >= parry_need
				if not det["parried"]:
					t_killed = true
			shot_details.append(det)
			if t_killed:
				break
		result.dice_events.append({
			"kind": "attack", "shooter": shooter.stats.display_name,
			"target": t.stats.display_name, "need": need,
			"armor": parry_need, "shots": shot_details, "killed": t_killed,
			"def_owner": t.owner, "shooter_owner": shooter.owner,  # item 13
		})
		_fx_lane(result, shooter.coord, t.coord, shooter.owner)  # issue 8
		result.log("%s ⇒ %s: %d hits (need %d+, defense %d+)" % [
			shooter.stats.display_name, t.stats.display_name, hits, need, parry_need])
		if t_killed:
			_kill(t, result, shooter.coord)
			any_kill = true
			result.log("%s killed!" % t.stats.display_name)
		else:
			break  # цель уцелела — пробитие останавливается
	if not any_kill:
		result.log("… target survived")
	_apply_zero_g(shooter, target)  # невесомость (§3.11)
	return result

# --- Толчок щитом (§3.14) ---
func _resolve_push(intent: PushIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if not _is_shield(actor):
		return ActionResult.fail("Only a shield bearer can shield-push")
	var target := state.get_unit(intent.target_id)
	if target == null or not target.is_alive():
		return ActionResult.fail("No target to push")
	if target.owner == actor.owner:
		return ActionResult.fail("Can't push your own")
	if Combat.distance(actor.coord, target.coord) != 1:
		return ActionResult.fail("Target not adjacent")

	actor.remaining_ap -= 1
	var step := _step_toward(actor.coord, target.coord)
	var need: int = target.armor() + MCF.SHIELD_PUSH_DEFENSE_PENALTY
	var roll := state.dice.roll_d6()
	var survived := roll >= need
	var pushed := false
	if not survived:
		_kill(target)
	else:
		var back := target.coord + step
		if state.grid.in_bounds(back) and not state.grid.cell(back).is_wall() \
				and state.grid.cell(back).occupant == null:
			state.grid.move_occupant(target.coord, back)
			pushed = true

	var result := ActionResult.new()
	result.ok = true
	result.dice_events.append({
		"kind": "check", "actor": target.stats.display_name,
		"roll": roll, "need": need, "ok": survived,
	})
	if not survived:
		_fx(result, {"fx": "blood", "at": target.coord, "from": actor.coord})
		result.log("%s shield-pushes %s — it dies (roll %d, need %d+)" % [
			actor.stats.display_name, target.stats.display_name, roll, need])
	elif pushed:
		result.log("%s pushes %s back one cell (roll %d)" % [
			actor.stats.display_name, target.stats.display_name, roll])
	else:
		result.log("%s pushes %s, but there's nowhere to push it (roll %d)" % [
			actor.stats.display_name, target.stats.display_name, roll])
	return result

func pushable_target_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	if not _is_shield(actor):
		return out
	for u in state.all_units():
		if u.owner != actor.owner and u.is_alive() and Combat.distance(actor.coord, u.coord) == 1:
			out.append(u.id)
	return out

# --- Вспомогательные для спецстрельбы ---
func _step_toward(from_coord: Vector2i, to_coord: Vector2i) -> Vector2i:
	return Vector2i(signi(to_coord.x - from_coord.x), signi(to_coord.y - from_coord.y))

func _is_shield(u: UnitInstance) -> bool:
	return u != null and u.stats.special_ability_id == MCF.ABILITY_SHIELD_BEARER

## Не гибнет в огне и не обходит его при поиске пути (#1, #2): щитоносец и огнемётчик.
## Публичная — тем же вопросом задаётся Main, когда решает, рисовать ли крест-предупреждение.
func is_fireproof(u: UnitInstance) -> bool:
	# Борг не горит (batch 13 B10): оператор внутри огня не боится.
	return u != null and (MCF.ability_is_fireproof(u.stats.special_ability_id) or u.borg_id != -1)

func _protected_by(u: UnitInstance, protectors: Array) -> bool:
	for sb in protectors:
		if u.owner == sb.owner and Combat.distance(u.coord, sb.coord) <= MCF.ANTI_TANK_BLAST_RADIUS:
			return true
	return false

## Выстрел заведомо ничего не даст: щитоносец неуязвим не в упор (§3.14), а очередь
## всё равно спишет ОД. Резолвер такой выстрел ПРИНИМАЕТ (can_shoot молчит, попадания
## просто парируются), поэтому ИИ разряжал магазин в щит с другого конца карты (#69).
## Публичная обёртка нужна, чтобы правило жило в одном месте: исключение для снайпера
## меняется здесь и сразу подхватывается ИИ.
func shot_is_futile(shooter: UnitInstance, target: UnitInstance) -> bool:
	if _shield_blocks_shot(shooter, target):
		return true
	# Семёрки на шестиграннике не бывает (item 6). Укрытие цели и огонь на линии
	# поднимают нужное число, и на 7 выстрел перестаёт быть «плохим» — он становится
	# невозможным. ИИ раньше мерил цель одной дальностью и исправно тратил ОД на
	# бойца за бетонной стеной; теперь такая цель просто не предлагается.
	return hit_need_for(shooter, target) >= 7

## Нужное число на кубике, чтобы попасть (§3.5/§3.7/§3.8/§5) — единственная формула
## на весь проект. Её спрашивает и сам выстрел, и ИИ, прикидывая, стоит ли стрелять:
## две отдельные оценки неизбежно разошлись бы, и разошлись именно там, где дороже
## всего, — в решении «тратить ли ОД».
##
## mods (необязательный) заполняется разбивкой для броска (#49): ярлык на каждую
## правку, в том же порядке, в каком её показывает кубик.
func hit_need_for(shooter: UnitInstance, target: UnitInstance, mods: Array = []) -> int:
	if shooter == null or target == null:
		return 7
	var dist := Combat.distance(shooter.coord, target.coord)
	var is_sniper := shooter.stats.special_ability_id == MCF.ABILITY_SNIPER
	# Снайпер считается по своей лестнице (§5), остальные — по общей формуле (§3.5).
	# Раньше снайпер шёл по общей, и она мазала на каждой полосе: при дальности 40
	# давала 3+ там, где нужно автопопадание, и 3+/4+/5+/6 там, где нужно 2+/3+/4+/5+.
	var need := Combat.sniper_hit_number(dist) if is_sniper \
			else Combat.hit_number(dist, shooter.fire_range())
	if is_sniper and need == 1:
		# Автопопадание — именно АВТО: оно и раньше выставлялось ПОСЛЕ укрытия и
		# перекрывало его, и это сохранено. Снимает автопопадание только укрепление
		# на линии; полоса тогда первая неавтоматическая — 2+, а не общая формула.
		if not _fortification_between(shooter.coord, target.coord):
			mods.append({"label": "Sniper auto-hit", "delta": 0})
			return 1
		need = 2
		mods.append({"label": "Fortification on the line", "delta": 1})
	# Укрытие цели (§3.7).
	var cover := cover_effect(shooter, target)
	var pen := int(cover["hit_penalty"])
	need += pen
	if pen != 0:
		mods.append({"label": "Target cover", "delta": pen})
	# Стрельба через горящие клетки (§3.8): −1 к попаданию (кроме снайпера).
	if not is_sniper and _fire_between(shooter.coord, target.coord):
		need += MCF.FIRE_SHOOT_PENALTY
		mods.append({"label": "Fire on the line", "delta": MCF.FIRE_SHOOT_PENALTY})
	return clampi(need, 1, 7)

## Сколько выбросить пушке машины по клетке (подпись прицела) — та же формула, что бросит
## _resolve_vehicle_cannon: от порта, через который пойдёт снаряд. 7 — не выстрелить.
func cannon_aim_need(veh: Vehicle, cell: Vector2i) -> int:
	if veh == null:
		return 7
	var port := cannon_port(veh, cell)
	if port == Vector2i(-1, -1):
		return 7
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get("weapons", {}).get("main_gun", {})
	return Combat.hit_number(Combat.distance(port, cell), float(int(gun.get("range", MCF.CANNON_RANGE))))

## Сколько выбросить, целясь в клетку (для подписи прицела): та же формула, что бросит
## сам выстрел этого стрелка. 0 — броска нет (лазер, струя, ПТ себе под ноги),
## 7 — не попасть. target — юнит в клетке, если целятся в него.
func aim_need(shooter: UnitInstance, cell: Vector2i, target: UnitInstance = null) -> int:
	if shooter == null:
		return 7
	match shooter.stats.special_ability_id:
		MCF.ABILITY_MARKSMAN, MCF.ABILITY_FLAMETHROWER:
			return 0
		MCF.ABILITY_ANTI_TANK:
			if cell == shooter.coord:
				return 0
			return Combat.hit_number(Combat.distance(shooter.coord, cell), shooter.fire_range())
		MCF.ABILITY_ASSAULT:
			return Combat.hit_number(Combat.distance(shooter.coord, cell), shooter.fire_range())
	if target == null:
		# Окно: у стрелка броска нет — каждую пулю держит спасбросок стекла (glass_bullet_save).
		if state.grid.in_bounds(cell) and MCF.is_glass(state.grid.cell(cell).feature_id):
			return 0
		return Combat.hit_number(Combat.distance(shooter.coord, cell), shooter.fire_range())
	return hit_need_for(shooter, target)

func _shield_blocks_shot(shooter: UnitInstance, target: UnitInstance) -> bool:
	if not _is_shield(target):
		return false
	if shooter.stats.special_ability_id == MCF.ABILITY_SNIPER:
		return false  # снайпер бьёт щитоносца с любой дистанции (§3.14)
	return Combat.distance(shooter.coord, target.coord) > 1

## Три проверки ниже раньше делали одно и то же лишнее действие: звали
## Combat.line_cells(), которая СТРОИТ и возвращает массив клеток, чтобы тут же его
## выбросить. На каждый выстрел, на каждую оценку клетки ИИ, на каждый предпросмотр —
## новый массив. Линия проходится теми же шагами, но без единого выделения памяти.
##
## Условие «не по прямой» повторяет line_cells(): она вернула бы пустой массив, а цикл
## по нему не выполнился бы ни разу — то есть ответ «нет», как и здесь.
func _wall_between(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	if _line_off_board(from_coord, to_coord):
		return false
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		if grid.cell_fast(x, y).cover_height >= MCF.WALL_HEIGHT:
			return true
		x += sx
		y += sy
	return false

## Есть ли горящая клетка на линии огня (§3.8).
func _fire_between(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	if _line_off_board(from_coord, to_coord):
		return false
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		if grid.cell_fast(x, y).on_fire:
			return true
		x += sx
		y += sy
	return false

## Есть ли укрепление (укрытие или стена) между стрелком и целью (§5, автопопадание снайпера).
func _fortification_between(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	if _line_off_board(from_coord, to_coord):
		return false
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		# is_wall() или has_cover() — вместе это просто «высота больше нуля».
		if grid.cell_fast(x, y).cover_height > 0.0:
			return true
		x += sx
		y += sy
	return false

## Эффект укрытия цели при выстреле (§3.7): {"hit_penalty": int, "defense_bonus": int}.
## Укрытие засчитывается ТОЛЬКО когда оно стоит прямо между стрелком и целью и цель
## прижата к нему вплотную. Высота 1 м → стрелку −2 к попаданию; высота 2 м — глухая
## стена (обрабатывается в los_blocked). Если стрелок и цель прижаты к укрытию с двух
## сторон (между ними ровно одна клетка), штраф не действует.
# --- Переносимый труп-щит (#6) ---
## Живой юнит подбирает труп с соседней клетки, чтобы носить его как щит.
func _resolve_pickup_corpse(intent: PickUpCorpseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	# Щитоносец корпуса не поднимает (item 17): его руки заняты щитом. Труп-щит —
	# защита для остальных бойцов, но не для того, кто и так укрыт своей плитой.
	if _is_shield(unit):
		return ActionResult.fail("A shield-bearer can't carry corpses")
	# Борг трупов не подбирает: несущему трупы в борг нельзя, значит и в борге их не взять.
	if unit.borg_id != -1:
		return ActionResult.fail("A borg can't pick up corpses")
	if unit.carried_corpses >= MCF.CORPSE_CARRY_MAX:
		return ActionResult.fail("Hands full — %s" % ("one body is the limit"
			if MCF.CORPSE_CARRY_MAX == 1 else "%d bodies is the limit" % MCF.CORPSE_CARRY_MAX))
	if Combat.distance(unit.coord, intent.from) > 1:
		return ActionResult.fail("Corpse is out of reach")
	if not has_corpse(intent.from):
		return ActionResult.fail("No corpse there")
	if state.grid.vehicle_at(intent.from) != -1:
		return ActionResult.fail("The body is under a vehicle")
	var cell := state.grid.cell(intent.from)
	# Снимаем один труп: сперва из кучи corpse_count, иначе труп-occupant.
	if cell.corpse_count > 0:
		cell.corpse_count -= 1
	elif cell.occupant != null and cell.occupant.status == MCF.Status.CORPSE:
		state.units.erase(cell.occupant.id)
		cell.occupant = null
	unit.remaining_ap -= 1
	unit.carried_corpses += 1
	return ActionResult.success(["%s picks up a corpse — carrying %d (+%d defence) [AP: %d]" % [
		unit.stats.display_name, unit.carried_corpses, unit.carried_corpses, unit.remaining_ap]])

## Кладёт один несомый труп на свою/соседнюю проходимую клетку (бесплатно).
func _resolve_drop_corpse(intent: DropCorpseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	# Положить труп — действие БЕСПЛАТНОЕ, поэтому проверку ОД пропускаем (#99): она
	# отказывала выдохшемуся бойцу молча, а кнопка и красные клетки по-прежнему
	# предлагались — со стороны это выглядело как «клик ничего не делает».
	var err := _validate_actor(unit, 1)
	if err != "":
		return ActionResult.fail(err)
	if unit.carried_corpses <= 0:
		return ActionResult.fail("No corpse to drop")
	# Под себя тело не кладут (#10): своя клетка занята самим бойцом, и труп под
	# ногами лишь мешал бы — и ему, и разбору кучи.
	if intent.to == unit.coord:
		return ActionResult.fail("Can't drop a body under yourself")
	if Combat.distance(unit.coord, intent.to) > 1:
		return ActionResult.fail("Too far to place")
	var cell := state.grid.cell(intent.to)
	if cell == null or cell.is_wall() or cell.is_space:
		return ActionResult.fail("Can't place a corpse there")
	# Больше пяти тел на клетку не влезает (#98): на пятом куча становится стеной, а
	# стена уже отсеяна проверкой is_wall() выше.
	if corpses_at(intent.to) >= MCF.CORPSE_WALL_COUNT:
		return ActionResult.fail("No room for another body here")
	unit.carried_corpses -= 1
	if _add_corpse_to_cell(intent.to):
		return ActionResult.success(["%s stacks the fifth body — a corpse wall rises at (%d, %d)" % [
			unit.stats.display_name, intent.to.x, intent.to.y]])
	return ActionResult.success(["%s drops a corpse (%d/%d) at (%d, %d)" % [
		unit.stats.display_name, corpses_at(intent.to), MCF.CORPSE_WALL_COUNT,
		intent.to.x, intent.to.y]])

## Положить описание косметического эффекта (#21). Единственная точка, откуда они
## берутся: если res == null (внутренний вызов без отчёта), эффект просто пропадает —
## показывать его всё равно некому.
func _fx(res: ActionResult, ev: Dictionary) -> void:
	if res != null:
		# Номер события — из доски (batch mp-perf): по нему FxDecals засевает разлёт, и у
		# всех пиров он один и тот же, сколько бы событий кто ни пропустил или ни пересчитал.
		ev["seq"] = state.fx_seq
		state.fx_seq += 1
		res.fx.append(ev)

## Узел, который назвал стрелок текущего действия (веха «Modular tank system»).
##
## Живёт ровно на время одного resolve() и ставится в самом начале обработки выстрела.
## Отдельным полем, а не параметром, потому что путь от намерения до урона машине идёт
## через полдюжины функций (_blast, зачистка области, обход машин), и протаскивать
## сквозь них одну строку значило бы переписать их сигнатуры ради неё одной.
var _aimed_component: String = ""
## Откуда пришёл выстрел — по нему считается БОРТ машины (веха 14.1). NOWHERE = стрелка
## на поле нет (подрыв дрона над корпусом, детонация соседней машины): бортов тогда не
## существует, и доступны все целые узлы.
var _aim_from: Vector2i = NOWHERE

## Какую гусеницу рвёт то, что приходит СНИЗУ — мина, ёж, упёршийся щитоносец.
##
## Борта у такого удара нет: он приходит под днище, а не с какой-то стороны. Берём
## первую целую по фиксированному порядку (левая, потом правая) — порядок важен не сам
## по себе, а тем, что он ОДИН И ТОТ ЖЕ у хоста и клиента. Целых не осталось — вернём
## корпус, и _damage_component отправит удар туда.
func _a_live_track(veh: Vehicle) -> String:
	for comp: String in MCF.TRACK_COMPONENTS:
		if veh.component_alive(comp):
			return comp
	return MCF.COMP_HULL

## Прямой разрыв В БРОНЕВОЙ ПЛИТЕ (веха 14.1): единственное, что её берёт.
##
## Осколки, огонь, кирка шахтёра, гусеница танка и луч марксмана плиту не трогают — это
## и есть вся её суть. Зато заряд, легший ИМЕННО В НЕЁ, сносит целиком, с одного раза:
## взрывчатка кладётся вплотную и работает на пролом, а не на осколки.
##
## Зовётся из тех же мест, что и _pillbox_absorbs, но ведёт себя иначе: ДОТ забирает
## удар себе и ОТМЕНЯЕТ взрыв, а плита просто рушится, и взрыв идёт своим чередом —
## пехоту вокруг он положит.
func _blast_armor_wall(center: Vector2i, res: ActionResult) -> void:
	if not state.grid.in_bounds(center):
		return
	var cell := state.grid.cell(center)
	if cell == null or cell.feature_id != MCF.FEATURE_ARMOR_WALL:
		return
	cell.clear_feature()
	notify_cell_changed(center)
	_fx(res, {"fx": "debris", "at": center, "cells": [center]})
	res.log("Armored Wall at (%d, %d) is blown apart." % [center.x, center.y])

## Дорожка «кто в кого» (issue 8: «add visual clues that would tell the player who is
## shooting at who»). Кладётся КАЖДОЙ атакой — пулей, лучом, струёй, зарядом, пушкой,
## ДПМГ, — чтобы в чужой ход было видно не только «где-то стреляли», но и кто по кому.
## Как и всё в fx, на правила не влияет: слой рисует её у себя и через LANE_DUR забывает.
func _fx_lane(res: ActionResult, from_coord: Vector2i, to_coord: Vector2i,
		owner: int, kind: String = "shot") -> void:
	_fx(res, {"fx": "lane", "from": [from_coord.x, from_coord.y],
		"to": [to_coord.x, to_coord.y], "owner": owner, "kind": kind})

## Единственная точка смерти в резолвере (#8). Всё, что боец нёс в руках, обязано
## оказаться на доске: погибший с телом на руках оставляет на своей клетке ДВА трупа —
## своё и принесённое. Раньше груз просто исчезал вместе с носильщиком.
##
## Класть некуда только в двух случаях: боец не на карте (сидит в машине, coord =
## OFFBOARD) или на клетке уже собралась стена из пяти тел. Тогда груз пропадает —
## как и раньше, но теперь это редкий край, а не общее правило.
## from_coord — откуда прилетел убивший удар: брызги (#21.4) летят ПРОТИВ него.
## NOWHERE (значение по умолчанию) = источник неизвестен, тогда веер расходится кругом.
func _kill(u: UnitInstance, res: ActionResult = null, from_coord: Vector2i = NOWHERE,
		blast: bool = false) -> void:
	if u == null or not u.is_alive():
		return
	if state.grid.in_bounds(u.coord):
		# blast — разорван взрывом или раздавлен: кровь кольцом, ошмётки, лужи шире.
		_fx(res, {"fx": "blood", "at": u.coord,
			"from": from_coord if from_coord != NOWHERE else u.coord, "blast": blast})
	var load: int = u.carried_corpses
	u.carried_corpses = 0
	# Пленник погибшего носильщика освобождается сам (batch 12 #1): держать его больше
	# некому. Раньше он оставался HELD с captor_id на труп — не мог действовать и не мог
	# вырваться, потому что _resolve_release ищет живого захватчика.
	var captive := held_unit_of(u)
	u.kill()
	# Погибший пассажир челнока (batch 13 S10): выбывает из экипажа, но кресло держит
	# его тело, пока снаружи его не вытащат.
	var seat_veh := seated_vehicle_of(u)
	if seat_veh != null:
		seat_veh.occupants.erase(u.id)
	# Погибший оператор борга (batch 13): машина снова размечается корпусом на своей
	# клетке — её можно выбрать, занять (тело вытолкнется) или добить.
	var bveh := borg_of(u)
	if bveh != null:
		bveh.occupants.erase(u.id)
		if state.grid.in_bounds(u.coord):
			bveh.origin = u.coord
			if state.grid.vehicle_at(u.coord) != -1 and state.grid.vehicle_at(u.coord) != bveh.id:
				# Раздавлен чужим корпусом вместе с оператором — от борга ничего не остаётся.
				u.borg_id = -1
				state.vehicles.erase(bveh.id)
			elif not bveh.wrecked and bveh.alive():
				state.grid.set_vehicle_footprint(bveh.id, bveh.footprint())
	if captive != null:
		captive.status = MCF.Status.ALIVE
		captive.captor_id = -1
		if res != null:
			res.log("%s is free — %s is dead." % [captive.stats.display_name, u.stats.display_name])
	if load <= 0:
		return
	var cell := state.grid.cell(u.coord) if state.grid.in_bounds(u.coord) else null
	if cell == null:
		return
	for _i in load:
		# Сам погибший уже лежит на этой клетке как occupant-труп и в corpses_at
		# посчитан, поэтому под стену остаётся ровно то, что до пяти не добрано.
		if corpses_at(u.coord) >= MCF.CORPSE_WALL_COUNT:
			return
		_add_corpse_to_cell(u.coord)

## +1 к защите цели за каждый несомый ею труп (#6).
func _corpse_shield_bonus(target: UnitInstance) -> int:
	return maxi(0, target.carried_corpses)

func cover_effect(shooter: UnitInstance, target: UnitInstance) -> Dictionary:
	return cover_effect_from(shooter.coord, target)

## То же, что cover_effect, но от произвольной клетки-стрелка (для ДПМГ, §3.7).
func cover_effect_from(from_coord: Vector2i, target: UnitInstance) -> Dictionary:
	var none := {"hit_penalty": 0, "defense_bonus": 0}
	var dist := Combat.distance(from_coord, target.coord)
	if dist <= 1:
		return none  # стрельба в упор — исключение (§3.7)
	# Стрелок и цель прижаты к укрытию с двух сторон — оно не мешает никому.
	if dist == 2:
		return none
	# Укрытие засчитывается только вплотную к цели, по направлению на стрелка.
	var shield_cell := target.coord + _step_toward(target.coord, from_coord)
	if not state.grid.in_bounds(shield_cell):
		return none
	var h: float = state.grid.cell(shield_cell).cover_height
	if MCF.COVER_MOD.has(h):
		return {"hit_penalty": int(MCF.COVER_MOD[h]), "defense_bonus": 0}
	# Труп, просто лежащий на земле, укрытием не считается (#97): плашмя он ничего не
	# заслоняет. Прикрывает только сложенная из пяти трупов стена — а она уже учтена
	# выше через cover_height своего FEATURE_CORPSE_WALL.
	return none

## Цель на дне окопа (глубина 2 м) недосягаема для стрельбы, если стрелок не вплотную.
##
## flat_beam=true — стреляют не пулей, а ЛАЗЕРОМ (§3.13), и поблажка «вплотную достанем»
## не действует. Пуля летит по дуге и её можно направить вниз: подойдя к краю окопа,
## боец бьёт в яму сверху. Луч же идёт строго по прямой на высоте стрелка и опуститься
## не может — с края окопа он уходит ровно над головой лежащего. Единственный способ
## достать его лучом — самому быть на дне, то есть в окопе: тогда стрелок и цель на
## одном уровне и луч идёт вдоль канавы.
##
## Без этого различия марксман с соседней клетки убивал залёгшего в окопе, хотя весь
## смысл окопа (и подпись «over the trench» в предпросмотре луча) ровно обратный.
##
## Из окопа луч бьёт ТОЛЬКО вдоль своей канавы (#105). Стрелок на дне сам ниже линии
## поверхности: подняться его луч не может ровно так же, как не мог опуститься, — стоящий
## наверху для него недосягаем, а упирается луч в земляную стенку окопа. Поэтому достать
## можно лишь того, кто лежит в ТОЙ ЖЕ канаве, и лишь если она тянется до него без
## разрыва: луч прямой, на повороте окопа он воткнётся в грунт.
func trench_protected(from_coord: Vector2i, target: UnitInstance,
		flat_beam: bool = false) -> bool:
	var tcell := state.grid.cell(target.coord)
	if tcell == null:
		return false  # цель вне поля (в машине и т. п.) — окоп её не касается (#23)
	var target_in_trench := tcell.feature_id == MCF.FEATURE_TRENCH
	if not flat_beam:
		# Пуля летит по дуге: сверху в яму её направить можно, но только вплотную.
		return target_in_trench and Combat.distance(from_coord, target.coord) > 1
	var from_cell := state.grid.cell(from_coord)
	if from_cell == null or from_cell.feature_id != MCF.FEATURE_TRENCH:
		# Стрелок наверху: в яму луч не опустится ни с какой дистанции.
		return target_in_trench
	# Стрелок на дне: наружу луч не выйдет, и по чужой канаве — тоже.
	return not (target_in_trench and _trench_run_clear(from_coord, target.coord))

## Тянется ли окоп сплошняком по прямой от одной клетки до другой (#105). Концы —
## окопы по построению, проверяем то, что между ними: разрыв означает, что луч уходит
## в земляную стенку, а не вдоль канавы. Соседние клетки проходят сами собой.
##
## Обход без выделения массива: линия огня — одно из восьми направлений, поэтому шаг
## задаётся знаками разностей, как в _first_body_on_line.
func _trench_run_clear(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return false  # не створ — вдоль канавы такой луч не пойдёт
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		var cell := grid.cell(Vector2i(x, y))
		if cell == null or cell.feature_id != MCF.FEATURE_TRENCH:
			return false
		x += sx
		y += sy
	return true

## Бьёт ли этот стрелок плоским лучом, для которого край окопа — не преимущество.
func _fires_flat_beam(shooter: UnitInstance) -> bool:
	return shooter != null and shooter.stats.special_ability_id == MCF.ABILITY_MARKSMAN

## Почему окоп не даёт выстрелить (#105). Причина зависит от того, кто где: обычно цель
## НИЖЕ линии огня, но марксман со дна канавы упирается в ровно обратное — цель выше него
## либо в другой канаве. Одна подпись на оба случая вводила бы в заблуждение ровно в тот
## момент, когда игрок пытается понять, почему выстрел не проходит.
func _trench_block_reason(shooter: UnitInstance) -> String:
	if _fires_flat_beam(shooter):
		var from_cell := state.grid.cell(shooter.coord)
		if from_cell != null and from_cell.feature_id == MCF.FEATURE_TRENCH:
			return "The beam only runs along this trench"
	return "Target is below the trench line"

## Первая соседняя (или своя) клетка с трупом для подбора (#6); (-999,-999) если нет.
## Клетки может не быть вовсе: у сидящего в машине coord = OFFBOARD (#95).
func corpse_pickup_cell(unit: UnitInstance) -> Vector2i:
	var here := state.grid.cell(unit.coord)
	if here == null:
		return Vector2i(-999, -999)
	if here.corpse_count > 0:
		return unit.coord
	for n in state.grid.neighbors(unit.coord):
		if has_corpse(n):
			return n
	return Vector2i(-999, -999)

## Куда юнит может положить несомый труп (#72): своя клетка и соседние восемь, если
## они проходимы. Условия ДОСЛОВНО те же, что проверяет _resolve_drop_corpse, —
## подсветка в UI не должна расходиться с тем, что резолвер реально разрешает.
func corpse_drop_cells(unit: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if unit == null or unit.carried_corpses <= 0:
		return out
	# Своей клетки в списке нет (#10) — ровно как и в _resolve_drop_corpse.
	var candidates: Array = state.grid.neighbors(unit.coord)
	for c: Vector2i in candidates:
		var cell := state.grid.cell(c)
		if cell == null or cell.is_wall() or cell.is_space:
			continue
		if corpses_at(c) >= MCF.CORPSE_WALL_COUNT:
			continue
		out.append(c)
	return out

## На клетке лежит труп. Укрытием он не работает (#97) — это признак «есть что подобрать».
func has_corpse(coord: Vector2i) -> bool:  # публично: нужен ИИ (#40)
	var c := state.grid.cell(coord)
	if c == null:
		return false
	if c.corpse_count > 0:
		return true
	return c.occupant != null and c.occupant.status == MCF.Status.CORPSE

## Сколько тел лежит на клетке (#98). Труп существует в двух видах — павший на месте
## боец (occupant со статусом CORPSE) и безымянное тело, положенное из рук
## (corpse_count), — и правило «пять тел = стена» считает их вместе. Раньше каждая
## ветка складывала кучу по-своему, поэтому одна и та же клетка могла показывать «x2»
## и держать сверх того труп-occupant, а стена собиралась на разном числе тел.
func corpses_at(coord: Vector2i) -> int:  # публично: нужен UI и подсветка
	var c := state.grid.cell(coord)
	if c == null:
		return 0
	var n := maxi(0, c.corpse_count)
	if c.occupant != null and c.occupant.status == MCF.Status.CORPSE:
		n += 1
	return n

## Кладёт одно тело на клетку; пятое складывает из кучи стену (§3.7, #98).
## Возвращает true, если стена образовалась. Вызывать, только убедившись, что
## corpses_at(coord) < CORPSE_WALL_COUNT — переполнить стену нечем.
func _add_corpse_to_cell(coord: Vector2i) -> bool:
	var c := state.grid.cell(coord)
	c.corpse_count += 1
	if corpses_at(coord) < MCF.CORPSE_WALL_COUNT:
		return false
	# Тела ушли внутрь стены: и счётчик, и труп-occupant обнуляются, а сам UnitInstance
	# выбывает из игры. Наружу они вернутся только разлётом от взрыва.
	if c.occupant != null and c.occupant.status == MCF.Status.CORPSE:
		state.units.erase(c.occupant.id)
		c.occupant = null
	c.corpse_count = 0
	c.set_feature(MCF.FEATURE_CORPSE_WALL)
	return true

## Случайный индекс 0..n-1 из общего источника бросков (#98). Своего генератора в
## резолвере быть не может: в сетевой партии клиент дословно повторяет последовательность
## d6 хоста (§2.3), и любой посторонний RNG развёл бы стороны. Три кубика дают 216
## значений — остаток от деления распределён достаточно ровно для разлёта тел.
func _rand_index(n: int) -> int:
	if n <= 1:
		return 0
	var v := 0
	for _i in 3:
		v = v * 6 + (state.dice.roll_d6() - 1)
	return v % n

## Разлёт тел трупной стены, рухнувшей от взрыва (#98): пять тел выбрасывает наружу,
## и каждое падает на свою свободную клетку поблизости. По одному на клетку — иначе
## стена тут же собралась бы заново там, где её только что снесли.
func _scatter_corpses_random(center: Vector2i, count: int, res: ActionResult) -> void:
	var free: Array[Vector2i] = []
	for dy in range(-MCF.CORPSE_SCATTER_RADIUS, MCF.CORPSE_SCATTER_RADIUS + 1):
		for dx in range(-MCF.CORPSE_SCATTER_RADIUS, MCF.CORPSE_SCATTER_RADIUS + 1):
			var c: Vector2i = center + Vector2i(dx, dy)
			if not state.grid.in_bounds(c):
				continue
			var cell := state.grid.cell(c)
			if cell.is_space or cell.vehicle_id != -1 or cell.has_feature():
				continue
			if not cell.is_empty() or corpses_at(c) > 0:
				continue
			free.append(c)
	var placed := 0
	while placed < count and not free.is_empty():
		var idx := _rand_index(free.size())
		state.grid.cell(free[idx]).corpse_count = 1
		free.remove_at(idx)
		placed += 1
	if res != null:
		res.log("… the corpse wall bursts — %d bodies are thrown clear." % placed)

# --- Укрепления: постройка/слом (§3.7) ---

## Что может строить инженер и почём (ОД). Стена/стекло/шлюз/ЛДФ/сетка — 1 действие,
## противотанковый ёж — 2 (§3.7).
## Что получится, если положить new_fid поверх уже стоящего old_fid (#31).
## "" — так укладывать нельзя.
const STACK_RESULT := {
	MCF.FEATURE_SANDBAGS: {
		MCF.FEATURE_SANDBAGS: MCF.FEATURE_SANDBAG_WALL,
		MCF.FEATURE_HEDGEHOG: MCF.FEATURE_HEDGEHOG_SANDBAGS,
	},
}

## Во что превратится клетка, если положить new_fid на клетку cell; "" — нельзя.
func stack_onto(cell: GridCell, new_fid: String) -> String:
	if cell.occupant != null or cell.vehicle_id != -1:
		return ""
	var by_existing: Dictionary = STACK_RESULT.get(cell.feature_id, {})
	return by_existing.get(new_fid, "")

const ENGINEER_BUILDABLE := {
	MCF.FEATURE_SANDBAGS: MCF.BUILD_COST_SANDBAGS,
	MCF.FEATURE_WALL: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_GLASS: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_AIRLOCK: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_LDF: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_DPMG: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_HEDGEHOG: MCF.BUILD_COST_HEDGEHOG,
	MCF.FEATURE_DOT: MCF.BUILD_COST_DOT,
	MCF.FEATURE_DOT_OPEN: MCF.BUILD_COST_DOT,
}

func _resolve_build(intent: BuildIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit unavailable")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can build fortifications")
	if not ENGINEER_BUILDABLE.has(intent.feature_id):
		return ActionResult.fail("Engineer can't build this object")
	if not state.grid.in_bounds(intent.target) or Combat.distance(actor.coord, intent.target) != 1:
		return ActionResult.fail("Can only build in an adjacent cell")
	var cell := state.grid.cell(intent.target)
	# Класть можно на пустую клетку либо ярусом поверх мешков (#31).
	var stacked := stack_onto(cell, intent.feature_id)
	if not cell.is_buildable() and stacked == "":
		return ActionResult.fail("Cell is occupied")
	var cost: int = ENGINEER_BUILDABLE[intent.feature_id]
	var credit_note := ""
	if actor.borg_id != -1:
		# Инженер в борге (batch 13 B7): 1 ОД покупает BORG_BUILD_BATCH построек ОДНОГО
		# типа, ставить их можно по одной между другими действиями; ДОТ — 1 за ОД.
		# Кредиты сгорают на границе раунда (UnitInstance.reset_ap).
		if MCF.BORG_BATCH_FEATURES.has(intent.feature_id):
			var left: int = int(actor.build_credits.get(intent.feature_id, 0))
			if left > 0:
				actor.build_credits[intent.feature_id] = left - 1
				cost = 0
				credit_note = " (batch, %d left)" % (left - 1)
			else:
				if actor.remaining_ap < 1:
					return ActionResult.fail("Need 1 AP")
				cost = 1
				actor.build_credits[intent.feature_id] = MCF.BORG_BUILD_BATCH - 1
				credit_note = " (batch, %d left)" % (MCF.BORG_BUILD_BATCH - 1)
		elif intent.feature_id == MCF.FEATURE_DOT or intent.feature_id == MCF.FEATURE_DOT_OPEN:
			cost = 1
	if actor.remaining_ap < cost:
		return ActionResult.fail("Need %d AP" % cost)
	actor.remaining_ap -= cost
	var placed: String = stacked if stacked != "" else intent.feature_id
	cell.set_feature(placed, actor.owner)
	notify_cell_changed(intent.target)  # застроенная клетка будит соседей (§3.1a)
	_extinguish_cell(cell)  # стройка на горящей клетке гасит огонь (#82)
	return ActionResult.success(["%s builds: %s at (%d, %d) [AP: %d]%s" % [
		actor.stats.display_name, MCF.FEATURE_NAMES.get(placed, placed),
		intent.target.x, intent.target.y, actor.remaining_ap, credit_note]])

## Цена постройки для этого инженера (для UI): в борге партия одного типа стоит 1 ОД,
## а пока кредиты партии не кончились — ничего.
func build_cost_for(actor: UnitInstance, feature_id: String) -> int:
	var cost: int = ENGINEER_BUILDABLE.get(feature_id, 1)
	if actor != null and actor.borg_id != -1:
		if MCF.BORG_BATCH_FEATURES.has(feature_id):
			return 0 if int(actor.build_credits.get(feature_id, 0)) > 0 else 1
		if feature_id == MCF.FEATURE_DOT or feature_id == MCF.FEATURE_DOT_OPEN:
			return 1
	return cost

const WELD_AIRLOCK_AP := 1

## Клетки соседних шлюзов, которые инженер может заварить (#99) — для подсветки в UI.
func weldable_cells(unit: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if unit == null or not unit.is_alive() \
			or unit.stats.special_ability_id != MCF.ABILITY_ENGINEER \
			or unit.remaining_ap < WELD_AIRLOCK_AP:
		return out
	for c: Vector2i in state.grid.neighbors(unit.coord):
		var cell := state.grid.cell(c)
		if cell != null and cell.feature_id == MCF.FEATURE_AIRLOCK and not cell.airlock_welded \
				and corpses_at(c) == 0:
			out.append(c)
	return out

## Инженер заваривает соседний шлюз за 1 ОД (#99). Заваренный шлюз перестаёт открываться
## от подошедшего юнита и держится как обычная стена — так перекрывают проход в отсек,
## не тратя стройку на новую стену.
func _resolve_weld_airlock(intent: WeldAirlockIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can weld an airlock")
	if not state.grid.in_bounds(intent.to) or Combat.distance(actor.coord, intent.to) != 1:
		return ActionResult.fail("Can only weld an adjacent airlock")
	var cell := state.grid.cell(intent.to)
	if cell.feature_id != MCF.FEATURE_AIRLOCK:
		return ActionResult.fail("There is no airlock there")
	if cell.airlock_welded:
		return ActionResult.fail("This airlock is already welded shut")
	# Створки не сойдутся на теле (batch 13 #4) — сначала вытащить труп из проёма.
	if corpses_at(intent.to) > 0:
		return ActionResult.fail("A body is jamming the doors — drag it out first")
	if actor.remaining_ap < WELD_AIRLOCK_AP:
		return ActionResult.fail("Need %d AP" % WELD_AIRLOCK_AP)
	actor.remaining_ap -= WELD_AIRLOCK_AP
	cell.airlock_welded = true
	# Створки закрываются немедленно, даже если рядом кто-то стоит.
	cell.cover_height = MCF.WALL_HEIGHT
	return ActionResult.success(["%s welds the airlock at (%d, %d) shut [AP: %d]" % [
		actor.stats.display_name, intent.to.x, intent.to.y, actor.remaining_ap]])

## Инженер выкладывает ЛДФ-стену из 6 клеток за 1 ОД (§3.7). Клетки разные, на свободном
## полу, ОДНА обязана соседствовать с инженером, и все шесть обязаны складываться в
## ОРТОГОНАЛЬНО связную цепочку (#80): ЛДФ — секционная конструкция, секции стыкуются
## гранями, а не углами, и разбросать их по карте нельзя.
func _resolve_build_wall(intent: BuildWallIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit unavailable")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can build a LDF wall")
	if actor.ldf_wall_used:
		return ActionResult.fail("This engineer has already used their LDF wall")
	if intent.cells.size() != MCF.LDF_WALL_LENGTH:
		return ActionResult.fail("A LDF wall must be exactly %d tiles" % MCF.LDF_WALL_LENGTH)
	var cost: int = ENGINEER_BUILDABLE[MCF.FEATURE_LDF]
	if actor.remaining_ap < cost:
		return ActionResult.fail("Need %d AP" % cost)

	# Проверка формы: клетки уникальны и свободны; ОДНА соседствует с инженером.
	var seen: Dictionary = {}
	var touches_engineer := false
	for c: Vector2i in intent.cells:
		if not state.grid.in_bounds(c):
			return ActionResult.fail("Wall tile is off the board")
		if seen.has(c):
			return ActionResult.fail("Wall tiles must be distinct")
		seen[c] = true
		if not state.grid.cell(c).is_buildable():
			return ActionResult.fail("A wall tile is on an occupied cell")
		if Combat.distance(actor.coord, c) == 1:
			touches_engineer = true
	if not touches_engineer:
		return ActionResult.fail("At least one wall tile must be next to the engineer")
	if not bru_cells_connected(intent.cells):
		return ActionResult.fail("LDF tiles must form one orthogonally connected chain")

	actor.remaining_ap -= cost
	actor.ldf_wall_used = true
	for c: Vector2i in intent.cells:
		var bru_cell := state.grid.cell(c)
		bru_cell.set_feature(MCF.FEATURE_LDF, actor.owner)
		notify_cell_changed(c)  # секция стены будит соседей (§3.1a)
		_extinguish_cell(bru_cell)  # секция придавливает очаг (#82)
	return ActionResult.success(["%s raises a %d-tile LDF wall [AP: %d]" % [
		actor.stats.display_name, MCF.LDF_WALL_LENGTH, actor.remaining_ap]])

## Образуют ли клетки одну ОРТОГОНАЛЬНО связную фигуру (#80) — секции ЛДФ стыкуются
## гранями, диагональ стыком не считается. Публичная: этим же вызовом UI не даёт
## поставить оторванную секцию, так что подсветка совпадает с проверкой резолвера.
func bru_cells_connected(cells: Array) -> bool:
	if cells.size() <= 1:
		return true
	var want: Dictionary = {}
	for c: Vector2i in cells:
		want[c] = true
	var reached: Dictionary = {cells[0]: true}
	var frontier: Array = [cells[0]]
	while not frontier.is_empty():
		var cur: Vector2i = frontier.pop_back()
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if want.has(n) and not reached.has(n):
				reached[n] = true
				frontier.append(n)
	return reached.size() == want.size()

## Ломать может шахтёр (стены/стёкла/ЛДФ) и инженер (свои постройки, сетка).
const BREAKABLE := [
	MCF.FEATURE_WALL, MCF.FEATURE_SOIL, MCF.FEATURE_GLASS, MCF.FEATURE_AIRLOCK, MCF.FEATURE_LDF,
	MCF.FEATURE_CORPSE_WALL, MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN,
	MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS, MCF.FEATURE_HEDGEHOG,
]

## Есть ли в соседней клетке что-то, что этот боец может снести (для ИИ и подсветки).
func can_break_cell(actor: UnitInstance, coord: Vector2i) -> bool:
	if actor == null or not actor.is_alive():
		return false
	var ability := actor.stats.special_ability_id
	if ability != MCF.ABILITY_MINER and ability != MCF.ABILITY_ENGINEER:
		return false
	if not state.grid.in_bounds(coord) or Combat.distance(actor.coord, coord) != 1:
		return false
	var cell := state.grid.cell(coord)
	# Броневую плиту киркой не взять (веха 14.1): её берёт только прямой взрыв.
	if cell.feature_id == MCF.FEATURE_ARMOR_WALL:
		return false
	return BREAKABLE.has(cell.feature_id) or (cell.feature_id == "" and cell.is_wall())

func _resolve_break(intent: BreakIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit unavailable")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	var ability := actor.stats.special_ability_id
	if ability != MCF.ABILITY_MINER and ability != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only a miner or engineer can demolish")
	if not state.grid.in_bounds(intent.target) or Combat.distance(actor.coord, intent.target) != 1:
		return ActionResult.fail("Can only demolish in an adjacent cell")
	var cell := state.grid.cell(intent.target)
	var breakable: bool = BREAKABLE.has(cell.feature_id) \
			or (cell.feature_id == "" and cell.is_wall())
	if not breakable:
		return ActionResult.fail("Nothing to demolish")
	if actor.remaining_ap < MCF.BREAK_COST:
		return ActionResult.fail("Need %d AP" % MCF.BREAK_COST)
	actor.remaining_ap -= MCF.BREAK_COST
	var was: String = MCF.FEATURE_NAMES.get(cell.feature_id, "wall")
	cell.clear_feature()
	cell.corpse_count = 0
	return ActionResult.success(["%s demolishes: %s at (%d, %d) [AP: %d]" % [
		actor.stats.display_name, was, intent.target.x, intent.target.y, actor.remaining_ap]])

# --- Копка окопа (§3.7) ---
# Юнит роет соседнюю клетку в окоп (укрытие выс. 1); вынутая земля — 2 кучи по 0.5 м.
# Упрощение против «1 действие на 3 клетки»: копаем 1 клетку окопа за действие.

func _resolve_dig(intent: DigIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	# Бесплатные окопы текущего ОД копаются и при нулевом ОД (§3.7).
	var err := _validate_actor(actor, actor.dig_credits if actor != null else 0)
	if err != "":
		return ActionResult.fail(err)
	if actor.is_drone:
		return ActionResult.fail("A drone can't dig")
	# Копать можно ПОД собой (дистанция 0) или в соседней клетке (#60).
	if not state.grid.in_bounds(intent.target) or Combat.distance(actor.coord, intent.target) > 1:
		return ActionResult.fail("Can only dig here or in an adjacent cell")
	var cell := state.grid.cell(intent.target)
	# Окоп можно копать ПОД юнитом (#39/#60): занятость клетки не мешает, но
	# нельзя копать сквозь стену/укрепление/уже существующий окоп.
	if cell.feature_id != "" or cell.cover_height != 0.0 or cell.is_wall():
		return ActionResult.fail("Can't dig this cell (something is built here)")
	# Куда сложить землю: выбор игрока, если задан и корректен; иначе — авто (§3.7).
	var spots := _dirt_spots(intent.target, actor.coord)
	var picked := _chosen_dirt_spots(intent, spots)
	if picked.size() < 2:
		return ActionResult.fail("Nowhere to put the dug-up dirt (no room for 2 piles)")

	# За 1 ОД пехота роет 3 окопа, инженер — 6. Первый окоп серии тратит ОД и открывает
	# «кредит», следующие в той же серии бесплатны, пока кредит не исчерпан (§3.7).
	var spent_ap := false
	if actor.dig_credits <= 0:
		if actor.remaining_ap <= 0:
			return ActionResult.fail("No AP left to dig")
		actor.remaining_ap -= 1
		# Борг роет BORG_DIG_TRENCHES (9) за ОД, кто бы в нём ни сидел (batch borg-corpses).
		var per_ap: int = MCF.BORG_DIG_TRENCHES if actor.borg_id != -1 \
				else (DIG_TRENCHES_ENGINEER if actor.stats.special_ability_id == MCF.ABILITY_ENGINEER
				else DIG_TRENCHES_NORMAL)
		actor.dig_credits = per_ap
		spent_ap = true
	actor.dig_credits -= 1

	cell.set_feature(MCF.FEATURE_TRENCH, actor.owner)
	notify_cell_changed(intent.target)  # свежий окоп будит соседей (§3.1a)
	# Копка снимает горящий верхний слой — окоп гасит огонь на своей клетке, а
	# вынутая земля засыпает очаги там, куда её сложили (#82).
	_extinguish_cell(cell)
	state.grid.cell(picked[0]).add_dirt(actor.owner)
	state.grid.cell(picked[1]).add_dirt(actor.owner)
	_extinguish_cell(state.grid.cell(picked[0]))
	_extinguish_cell(state.grid.cell(picked[1]))
	var tail := "[AP: %d, %d trench(es) left this AP]" % [actor.remaining_ap, actor.dig_credits] if not spent_ap \
		else "[AP: %d, %d more trench(es) free this AP]" % [actor.remaining_ap, actor.dig_credits]
	return ActionResult.success(["%s dug a trench at (%d, %d), dirt at (%d,%d) and (%d,%d) %s" % [
		actor.stats.display_name, intent.target.x, intent.target.y,
		picked[0].x, picked[0].y, picked[1].x, picked[1].y, tail]])

## Проверить/выбрать 2 клетки под землю: сначала берём корректный выбор игрока,
## затем добираем автоматически из доступных мест (§3.7). Пара может совпадать —
## тогда на одну клетку ложатся оба уровня (растёт куча), поэтому считаем не клетки,
## а свободную ЁМКОСТЬ: пустая клетка держит DIRT_MAX_LEVEL загрузок (#51).
func _chosen_dirt_spots(intent: DigIntent, spots: Array) -> Array:
	var picked: Array = []
	var room := {}  # клетка -> сколько ещё уровней земли туда влезет
	for s in spots:
		room[s] = _dirt_capacity(s)
	for pick in [intent.dirt_a, intent.dirt_b]:
		if picked.size() >= 2:
			break
		if pick != Vector2i(-999, -999) and int(room.get(pick, 0)) > 0:
			picked.append(pick)
			room[pick] = int(room[pick]) - 1
	# Первый проход раскладывает по одной куче на клетку (растим равномерно),
	# второй — досыпает второй уровень, если свободная клетка осталась одна.
	for _pass in 2:
		for s in spots:
			if picked.size() >= 2:
				break
			if int(room[s]) > 0:
				picked.append(s)
				room[s] = int(room[s]) - 1
	return picked

## Сколько загрузок земли ещё примет клетка (0, если не принимает вовсе).
func _dirt_capacity(coord: Vector2i) -> int:
	var cell := state.grid.cell(coord)
	if cell == null or not cell.accepts_dirt():
		return 0
	return MCF.DIRT_MAX_LEVEL - cell.dirt_level

## Клетки под вынутую землю: соседи окопа (кроме копающего), пустые ИЛИ недосыпанные кучи.
# --- Мины (item 45) ---------------------------------------------------------
## Куда сапёр может поставить мину: под собой или в соседней клетке, на голый пол.
## Мина не даёт укрытия и не мешает проходу — она на то и мина, чтобы на неё
## наступили, — поэтому единственное требование к клетке в том, что на ней нет
## ничего другого.
func mine_cells(actor: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if actor == null or not _is_sapper(actor) or actor.aboard_vehicle_id != -1:
		return out
	var here := actor.coord
	for c in [here] + state.grid.neighbors(here):
		if _can_mine_cell(c):
			out.append(c)
	return out

func _is_sapper(u: UnitInstance) -> bool:
	return u != null and u.stats.special_ability_id == MCF.ABILITY_SAPPER

## Клетки с чужой ПОДСВЕЧЕННОЙ миной рядом с сапёром — их он может обезвредить (item 13).
func disarmable_mine_cells(actor: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if actor == null or not _is_sapper(actor) or actor.aboard_vehicle_id != -1:
		return out
	for c in [actor.coord] + state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(c)
		if cell == null:
			continue
		if cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE:
			continue
		if state.roster.are_allies(actor.owner, cell.feature_owner):
			continue
		if mine_visible_to(actor.owner, c):
			out.append(c)
	return out

func _can_mine_cell(coord: Vector2i) -> bool:
	if not state.grid.in_bounds(coord):
		return false
	var c := state.grid.cell(coord)
	return not c.is_space and not c.has_feature() and c.cover_height == 0.0 \
			and c.dirt_level == 0 and c.vehicle_id == -1

func _resolve_place_mine(intent: PlaceMineIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	# Мины из открытого кредита ставятся и при нулевом ОД — как окопы серии (§3.7).
	var err := _validate_actor(actor, actor.mine_credits if actor != null else 0)
	if err != "":
		return ActionResult.fail(err)
	if not _is_sapper(actor):
		return ActionResult.fail("Only a sapper can lay mines")
	if Combat.distance(actor.coord, intent.target) > 1:
		return ActionResult.fail("Can only mine this cell or an adjacent one")
	if not _can_mine_cell(intent.target):
		return ActionResult.fail("Can't lay a mine here")
	var spent_ap := false
	if actor.mine_credits <= 0:
		if actor.remaining_ap <= 0:
			return ActionResult.fail("No AP left to lay mines")
		actor.remaining_ap -= 1
		actor.mine_credits = MCF.MINES_PER_ACTION
		spent_ap = true
	actor.mine_credits -= 1
	var mine_feature: String = MCF.FEATURE_AV_MINE if intent.anti_vehicle else MCF.FEATURE_MINE
	var target_cell := state.grid.cell(intent.target)
	target_cell.set_feature(mine_feature, actor.owner)
	var kind_word := "an anti-vehicle mine" if intent.anti_vehicle else "a mine"
	var tail := "[AP: %d, %d mine(s) left to lay]" % [actor.remaining_ap, actor.mine_credits]
	var res := ActionResult.success(["%s laid %s at (%d, %d) %s" % [
		actor.stats.display_name, kind_word, intent.target.x, intent.target.y, tail]])
	# Противопехотная мина, заложенная ПОД стоящим бойцом — своим, чужим или самим
	# сапёром, — рвётся сразу (batch 12 #7): взрыватель взводится под ногой. Бросков
	# нет, это верная смерть; мина расходуется. Противотанковая под пехотой молчит —
	# ей нужен вес гусеницы.
	var under: UnitInstance = target_cell.occupant
	if not intent.anti_vehicle and under != null and under.is_alive():
		target_cell.clear_feature()
		notify_cell_changed(intent.target)
		_fx(res, {"fx": "debris", "at": intent.target, "cells": [intent.target]})
		_kill(under, res, intent.target)
		res.deaths.append(under.id)
		res.log("The mine goes off under %s's feet — killed instantly!" % under.stats.display_name)
	return res

## Сапёр обезвреживает подсвеченную его стороной чужую мину на соседней клетке (item 13).
func _resolve_disarm_mine(intent: DisarmMineIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if not _is_sapper(actor):
		return ActionResult.fail("Only a sapper can disarm mines")
	if actor.remaining_ap <= 0:
		return ActionResult.fail("No AP left")
	if Combat.distance(actor.coord, intent.target) > 1:
		return ActionResult.fail("Must be next to the mine")
	var cell := state.grid.cell(intent.target)
	if cell == null or (cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE):
		return ActionResult.fail("No mine there")
	if state.roster.are_allies(actor.owner, cell.feature_owner):
		return ActionResult.fail("That's a friendly mine")
	# Обезвредить можно лишь то, что уже нашли зачисткой: слепой сапёр чужого поля не видит.
	if not mine_visible_to(actor.owner, intent.target):
		return ActionResult.fail("Sweep for it first — you can't see that mine")
	actor.remaining_ap -= 1
	var was_av := cell.feature_id == MCF.FEATURE_AV_MINE
	cell.clear_feature()
	# Знание о снятой мине больше не нужно — чистим отметку, чтобы подсветка не висела.
	var seen: Dictionary = state.revealed_mines.get(actor.owner, {})
	seen.erase(intent.target)
	notify_cell_changed(intent.target)
	return ActionResult.success(["%s disarms %s at (%d, %d) [AP: %d]" % [
		actor.stats.display_name, "an anti-vehicle mine" if was_av else "a mine",
		intent.target.x, intent.target.y, actor.remaining_ap]])

## Подсветить чужие мины вокруг (item 45). Знание кладётся ПЕРСОНАЛЬНО той стороне,
## что его добыла: подсветка — не свойство мины, а то, что о ней узнали.
func _resolve_reveal_mines(intent: RevealMinesIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if not _is_sapper(actor):
		return ActionResult.fail("Only a sapper can sweep for mines")
	if actor.remaining_ap <= 0:
		return ActionResult.fail("No AP left")
	actor.remaining_ap -= 1
	var until: int = state.turns.round_number + MCF.MINE_REVEAL_TURNS
	var seen: Dictionary = state.revealed_mines.get(actor.owner, {})
	var found := 0
	var r := MCF.MINE_REVEAL_RADIUS
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := actor.coord + Vector2i(dx, dy)
			if not state.grid.in_bounds(c):
				continue
			var cell := state.grid.cell(c)
			if cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE:
				continue
			if state.roster.are_allies(actor.owner, cell.feature_owner):
				continue  # свои мины сапёр и так знает
			if _vision_blocked(actor.coord, c, actor.owner):
				continue
			seen[c] = until
			found += 1
	state.revealed_mines[actor.owner] = seen
	return ActionResult.success(["%s swept for mines: %d found within %d tiles [AP: %d]" % [
		actor.stats.display_name, found, r, actor.remaining_ap]])

## Подрыв мины под наступившим (item 45).
##
## Эффекта мины в источнике нет вовсе — описана только сама способность её ставить.
## Принято самое скромное толкование, какое согласуется с остальной моделью урона:
## поражается РОВНО клетка мины (никакого поля осколков), пехота на ней гибнет по
## общим правилам взрыва, техника теряет единицу прочности по единой шкале (#89),
## а сама мина расходуется. Записано в GAME_SPEC §7.9 как принятое допущение.
func _detonate_mine(coord: Vector2i, victim: UnitInstance, res: ActionResult) -> void:
	var cell := state.grid.cell(coord)
	var owner_name := MCF.owner_name(cell.feature_owner)
	cell.clear_feature()
	res.log("A mine laid by %s goes off at (%d, %d)!" % [owner_name, coord.x, coord.y])
	# Через общий _blast: щитоносец, прикрытие союзником и снос объектов на клетке
	# должны работать здесь ровно так же, как у противотанкиста, а не «почти так же».
	var area: Array[Vector2i] = [coord]
	# Клетка мины оседает ОБЫЧНЫМ разрушенным полом, а не выжженным эпицентром (item 13).
	var killed := _blast(coord, res, area, false)
	_damage_vehicles_in_area(area, coord, MCF.MINE_VEHICLE_DAMAGE, -1, res, "mine")
	if killed.is_empty():
		# victim == null — подрыв не под ногами (огонь дошёл): некому «уйти».
		if victim != null:
			res.log("… %s walked away from it." % victim.stats.display_name)
	else:
		for n in killed:
			res.log("%s killed by the mine!" % n)

## Противопехотные мины, о которых сторона ЗНАЕТ (batch 12 #3/#4): свои и союзные всегда,
## чужие — пока держится подсветка зачистки. Словарь coord → true в порядке обхода
## сетки, чтобы Movement мог класть его в ключ кеша. Маршруты этой стороны обходят
## эти клетки; противотанковые мины сюда не входят — пехоте они не страшны.
func known_mine_cells(owner: int) -> Dictionary:
	var out: Dictionary = {}
	for coord: Vector2i in _feature_cells(MCF.FEATURE_MINE):
		if mine_visible_to(owner, coord):
			out[coord] = true
	return out

## Разлив движения для бойца с обходом известных ему мин (batch 12 #4). Все, кто
## считает ход пехоты — резолвер, интерфейс, ИИ, — обязаны идти через эту функцию,
## иначе подсветка и проверка приказа разойдутся.
## Бюджет движения — ровно тот, что спишет _resolve_move (batch 17, item 2): кредит
## прошлого хода тратится ПЕРВЫМ (§3.2); с грузом потолок −3 клетки, даже на кредите.
## Экран и групповой приказ обязаны считать по нему же, иначе подсветка врёт.
func move_budget(unit: UnitInstance) -> int:
	var burdened := held_unit_of(unit) != null \
			or dragged_cell_of(unit) != UnitInstance.NOT_DRAGGING
	var carry_budget := maxi(0, unit.speed() - MCF.CAPTURE_CARRY_PENALTY)
	var budget := unit.move_credit if unit.move_credit > 0 \
			else (carry_budget if burdened else unit.speed())
	return mini(budget, carry_budget) if burdened else budget

## Бюджет СВЕЖЕГО движения за 1 ОД, без остатка прошлого (для зон 2-го и 3-го ОД).
func move_budget_fresh(unit: UnitInstance) -> int:
	var burdened := held_unit_of(unit) != null \
			or dragged_cell_of(unit) != UnitInstance.NOT_DRAGGING
	return maxi(0, unit.speed() - MCF.CAPTURE_CARRY_PENALTY) if burdened else unit.speed()

## Потолки хода за 1, 2 и 3 ОД (зелёная, оранжевая, красная зоны): [i] — сколько клеток
## пройдёт боец, потратив ещё i ОД сверх первого (на кредите первый ОД не нужен). Цена
## клетки от бюджета не зависит, поэтому один разлив по последнему потолку даёт все три
## зоны. Волочение ОД не стоит, ему дальних зон нет. Экран и _resolve_move считают по ней.
func move_tier_budgets(unit: UnitInstance) -> Array[int]:
	var budget := move_budget(unit)
	var out: Array[int] = [budget]
	if dragged_cell_of(unit) != UnitInstance.NOT_DRAGGING:
		return out
	var extra_ap := unit.remaining_ap - (0 if unit.move_credit > 0 else 1)
	var step := move_budget_fresh(unit)
	for k in range(1, mini(extra_ap, 2) + 1):
		if step <= 0:
			break
		out.append(budget + step * k)
	return out

func can_move(unit: UnitInstance) -> bool:
	return unit != null and unit.is_alive() and unit.aboard_vehicle_id == -1 \
			and not unit.is_held() and (unit.remaining_ap > 0 or unit.move_credit > 0)

## Достижимая клетка, ближайшая к dest (при равенстве — дешевле по ходу); `taken` —
## клетки, уже разобранные другими юнитами группы. Своя клетка, если идти некуда.
func nearest_reachable(u: UnitInstance, dest: Vector2i, taken: Dictionary = {}) -> Vector2i:
	var reach_r := reachable_for(u, move_budget(u))
	var best := u.coord
	var best_d := Combat.distance(u.coord, dest)
	var best_cost := 0
	for c: Vector2i in reach_r.cost:
		if taken.has(c):
			continue
		var d: int = Combat.distance(c, dest)
		var cost: int = reach_r.cost[c]
		if d < best_d or (d == best_d and cost < best_cost):
			best_d = d
			best_cost = cost
			best = c
	return best

## blocked / vacated — план группового приказа (GroupMovePlanner): клетки, куда уже
## встали товарищи, и клетки, с которых они к этому моменту ушли.
func reachable_for(unit: UnitInstance, budget: int, blocked: Dictionary = {},
		vacated: Dictionary = {}) -> Movement.Reachability:
	var avoid := known_mine_cells(unit.owner)
	# Борг в окоп не съезжает (batch 13 B11): окопы для него — не клетки.
	if unit.borg_id != -1 or not blocked.is_empty():
		var merged: Dictionary = avoid.duplicate()
		if unit.borg_id != -1:
			for c: Vector2i in _trench_cells():
				merged[c] = true
		merged.merge(blocked)
		avoid = merged
	return Movement.reachable_for(state.grid, unit, budget, avoid, vacated)

func _trench_cells() -> Array:
	return _feature_cells(MCF.FEATURE_TRENCH)

## Клетки с объектом fid в порядке обхода сетки. Индекс общий на все резолверы (static):
## ИИ заводит новый резолвер на КАЖДОЕ решение. Собирается одним проходом по карте на новой
## сетке, а дальше правится по журналу вида клеток (GridCell.look_changes) — только
## клетки, где объект сменился. Прежде known_mine_cells() перебирала все 62 500 клеток
## карты 250×250 на КАЖДЫЙ разлив хода, а шлюзы и станции пересобирались полным проходом
## на любую стройку.
##
## Заодно индекс держит горящие клетки (_burning_cells_of): огонь пишется в тот же журнал.
##
## Отдаваемый массив — сам индекс: его читают сразу и не держат через действие.
static var _feature_index: Dictionary = {}   # fid -> Array[Vector2i] в порядке обхода
static var _feature_at: Dictionary = {}      # Vector2i -> fid
static var _feature_rev: Dictionary = {}     # fid -> номер правки его списка
static var _burning: Array = []              # горящие клетки в порядке обхода
static var _feature_grid: int = 0
static var _feature_look: int = -1

static func _burning_cells_of(grid: Grid) -> Array:
	_feature_sync(grid)
	return _burning

func _feature_cells(fid: String) -> Array:
	return _feature_cells_of(state.grid, fid)

static func _feature_cells_of(grid: Grid, fid: String) -> Array:
	_feature_sync(grid)
	return _feature_index.get(fid, [])

static func _feature_sync(grid: Grid) -> void:
	var gid := grid.get_instance_id()
	if gid != _feature_grid or _feature_look < GridCell.look_log_base:
		# Правка — и у тех объектов, что исчезли с карты совсем: их списки тоже сменились.
		for fid: String in _feature_index:
			_feature_rev[fid] = int(_feature_rev.get(fid, 0)) + 1
		_feature_index = {}
		_feature_at = {}
		_burning = []
		for c: GridCell in grid.cells_flat():
			if c.feature_id != "":
				if not _feature_index.has(c.feature_id):
					_feature_index[c.feature_id] = []
				_feature_index[c.feature_id].append(c.coord)
				_feature_at[c.coord] = c.feature_id
			if c.on_fire:
				_burning.append(c.coord)
		for fid: String in _feature_index:
			_feature_rev[fid] = int(_feature_rev.get(fid, 0)) + 1
		_feature_grid = gid
		_feature_look = GridCell.look_version
		return
	if _feature_look == GridCell.look_version:
		return
	var ch := GridCell.look_changes
	var i: int = (_feature_look - GridCell.look_log_base) * 2
	while i < ch.size():
		var at := Vector2i(ch[i], ch[i + 1])
		i += 2
		if not grid.in_bounds(at):
			continue
		var cell := grid.cell(at)
		var fk := _burning.bsearch_custom(at, _grid_order)
		var listed: bool = fk < _burning.size() and _burning[fk] == at
		if cell.on_fire and not listed:
			_burning.insert(fk, at)
		elif listed and not cell.on_fire:
			_burning.remove_at(fk)
		var now := cell.feature_id
		var was: String = _feature_at.get(at, "")
		if now == was:
			continue
		if was != "":
			var list: Array = _feature_index[was]
			var k := list.bsearch_custom(at, _grid_order)
			if k < list.size() and list[k] == at:
				list.remove_at(k)
			_feature_rev[was] = int(_feature_rev.get(was, 0)) + 1
			_feature_at.erase(at)
		if now != "":
			if not _feature_index.has(now):
				_feature_index[now] = []
			var list2: Array = _feature_index[now]
			list2.insert(list2.bsearch_custom(at, _grid_order), at)
			_feature_rev[now] = int(_feature_rev.get(now, 0)) + 1
			_feature_at[at] = now
	_feature_look = GridCell.look_version

static func _grid_order(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y or (a.y == b.y and a.x < b.x)

## Видит ли сторона эту мину. Своя мина видна всегда; чужая — пока держится подсветка.
func mine_visible_to(owner: int, coord: Vector2i) -> bool:
	var cell := state.grid.cell(coord)
	if cell == null or (cell.feature_id != MCF.FEATURE_MINE and cell.feature_id != MCF.FEATURE_AV_MINE):
		return false
	if state.roster.are_allies(owner, cell.feature_owner):
		return true
	var seen: Dictionary = state.revealed_mines.get(owner, {})
	return int(seen.get(coord, -1)) >= state.turns.round_number

## «Нигде» — маркер отсутствия клетки в результате поиска по маршруту.
const NOWHERE := Vector2i(-9999, -9999)

## Первая горящая клетка на пройденном маршруте (#1). Огнеупорные бойцы (#2) сквозь
## пламя проходят невредимыми, и для них ответ всегда NOWHERE.
func _fire_on_path(unit: UnitInstance, path: Array) -> Vector2i:
	if is_fireproof(unit):
		return NOWHERE
	for step: Vector2i in path:
		var cell := state.grid.cell(step)
		if cell != null and cell.on_fire:
			return step
	return NOWHERE

## Первая чужая мина на пройденном маршруте. Мина срабатывает под ногой, а не в
## точке назначения: минное поле на то и поле, что его пересекают.
## path приходит из Reachability.path_to(), а он отдаёт только ВОЙДЕННЫЕ клетки —
## исходной в нём нет, поэтому отдельно её исключать не нужно.
func _mine_on_path(unit: UnitInstance, path: Array) -> Vector2i:
	for step: Vector2i in path:
		var cell := state.grid.cell(step)
		# Обычная противопехотная мина рвётся под ЛЮБЫМ пехотинцем — своим или чужим
		# (item 13). Раньше на свои мины не наступали; теперь наступивший гибнет, чей бы
		# ни была мина, поэтому владельцу приходится обходить своё же поле. Противотанковая
		# мина (FEATURE_AV_MINE) пехоту не трогает — под ней сюда просто не попадёт.
		if cell == null or cell.feature_id != MCF.FEATURE_MINE:
			continue
		return step
	return NOWHERE

func _dirt_spots(trench: Vector2i, digger: Vector2i) -> Array:
	var out: Array = []
	for n in state.grid.neighbors(trench):
		if n == digger:
			continue
		if state.grid.cell(n).accepts_dirt():
			out.append(n)
	return out

## Суммарная ёмкость под вынутую землю вокруг окопа (нужно 2 загрузки).
func _dirt_room(trench: Vector2i, digger: Vector2i) -> int:
	var total := 0
	for s in _dirt_spots(trench, digger):
		total += _dirt_capacity(s)
		if total >= 2:
			return total
	return total

## Можно ли копать окоп рядом (для UI): нет укрепления/стены + место под 2 загрузки земли.
## Оккупант клетки не мешает — окоп роется и под чужим бойцом (#43), как в _resolve_dig.
## Считаем ёмкость, а не число клеток: одна пустая соседняя клетка держит обе кучи (#51).
func diggable_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor.is_drone:
		return out
	var candidates: Array[Vector2i] = [actor.coord]
	candidates.append_array(state.grid.neighbors(actor.coord))
	for c in candidates:
		var cell := state.grid.cell(c)
		if cell.feature_id == "" and cell.cover_height == 0.0 and not cell.is_wall() \
				and _dirt_room(c, actor.coord) >= 2:
			out.append(c)
	return out

## Клетки под насыпь вокруг выбранного окопа (для UI выбора игроком).
func dirt_spots_for(trench: Vector2i, digger: Vector2i) -> Array:
	return _dirt_spots(trench, digger)

## Соседние клетки, где инженер может строить (для UI).
## feature_id задан — добавляем и клетки, куда его можно уложить ярусом поверх мешков (#31).
func buildable_cells(actor: UnitInstance, feature_id: String = "") -> Array:
	var out: Array = []
	if actor.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return out
	for n in state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(n)
		if cell.is_buildable() or (feature_id != "" and stack_onto(cell, feature_id) != ""):
			out.append(n)
	return out

## Соседние клетки, которые можно сломать (для UI).
func breakable_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	var ability := actor.stats.special_ability_id
	if ability != MCF.ABILITY_MINER and ability != MCF.ABILITY_ENGINEER:
		return out
	for n in state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(n)
		if BREAKABLE.has(cell.feature_id) or (cell.feature_id == "" and cell.is_wall()):
			out.append(n)
	return out

# --- Огонь (§3.8) ---

## Распространение огня (как в isotope §6.5): раз за ход-сторону каждая горящая
## клетка пытается поджечь 4 ОРТОГОНАЛЬНЫХ соседа (без диагоналей). Порог розжига —
## дерево/трава 3+, прочий пол 4+. Горит почти всё, включая обычные стены; огонь
## НЕ проходит только сквозь пустоту (космос), ЛДФ и ДОТ. Огонь вечен и не гаснет сам.
## Применяется одномоментно (без цепной реакции за тик). Юнит на загоревшейся клетке
## гибнет мгновенно (как от пробития, без спасброска).
## Расползается только огонь, зажжённый стороной owner (#45); owner = -1 — весь огонь.
func advance_fire(owner: int = -1, res: ActionResult = null) -> void:
	var ignite: Dictionary = {}
	# Горящие клетки — из индекса, в том же порядке обхода, что и прежний перебор всей
	# карты: от него зависит порядок бросков. Карта 250×250 — 62 500 клеток на каждую
	# передачу хода, даже когда не горит ничего.
	for c: Vector2i in _burning_cells_of(state.grid):
		var src := state.grid.cell(c)
		if owner != -1 and src.fire_owner != owner:
			continue
		# Каждая горящая клетка бросает розжиг на своих 4 ортогональных соседей.
		for n in _ortho4(c):
			if ignite.has(n):
				continue
			var ncell := state.grid.cell(n)
			if ncell.on_fire or _fire_blocked(ncell):
				continue
			# Клетка под пожаротушительной гранатой (#19): пассивный разлив в неё
			# не идёт. Бросок при этом НЕ делается — иначе заглушённая клетка
			# съедала бы кубики и сдвигала весь дальнейший поток случайности.
			if state.turns.round_number < ncell.fire_suppressed_until:
				continue
			# Живой не-огнеупорный боец рядом с пламенем загорается СРАЗУ, без броска
			# и независимо от того, горюч ли пол под ним (issue #9): огонь перекидывается
			# на человека, а не только на траву. Клетка занимается огнём, apply-цикл
			# ниже убивает бойца тем же путём, что и на любой загоревшейся клетке.
			var occ := ncell.occupant
			if occ != null and occ.is_alive() and not is_fireproof(occ):
				ignite[n] = src.fire_owner
				continue
			var need := fire_need(ncell)
			if need > 6:
				continue  # не горит никогда — кубик не бросаем
			if state.dice.roll_d6() >= need:
				ignite[n] = src.fire_owner
	for c: Vector2i in ignite:
		var cell := state.grid.cell(c)
		# Новая клетка наследует поджигателя — цепочка остаётся привязана к своей стороне.
		_ignite(cell, ignite[c])
		# Постройка на загоревшейся клетке сгорает дотла и оставляет открытый огонь (#83):
		# каркас стены ведёт, стекло лопается, шлюз заклинивает и выгорает.
		if BURNS_AWAY.has(cell.feature_id):
			cell.clear_feature()
		# Огонь подрывает обычную мину, до которой дополз (item 13). Противотанковую —
		# НЕТ: её взрыватель реагирует лишь на вес гусеницы, не на пламя.
		elif cell.feature_id == MCF.FEATURE_MINE and res != null:
			_detonate_mine(c, null, res)
		# Юнит, оказавшийся на загоревшейся клетке, сгорает мгновенно (§6.5).
		# Щитоносец (#50) и огнемётчик (#2) невосприимчивы к огню.
		if cell.occupant != null and cell.occupant.is_alive() and not is_fireproof(cell.occupant):
			var burned := cell.occupant
			# res здесь только ради кровавой косметики — _kill сам в deaths не пишет,
			# это делают вызывающие. Мы пишем в fire_deaths, но НЕ в deaths (см.
			# ActionResult): иначе автор завершённого хода получил бы чужой костёр в зачёт.
			_kill(burned)  # пожар — крови нет
			if res != null:
				res.fire_deaths.append(burned.id)

## Постройки, которые огонь уничтожает вместе с клеткой (#53, #83). ЛДФ здесь нет
## намеренно: несгораемая секция вообще не загорается (_fire_blocked).
const BURNS_AWAY := [
	MCF.FEATURE_WOOD_WALL, MCF.FEATURE_WALL, MCF.FEATURE_SOIL, MCF.FEATURE_GLASS,
	MCF.FEATURE_ARMOR_GLASS, MCF.FEATURE_AIRLOCK,
]

## Порог d6, с которого клетка загорается от СОСЕДНЕГО пламени (#14/#31). Шанс
## равен (7 − need)/6; значение больше шести означает «не горит никогда».
## Публичная: тем же вызовом UI подписывает клетку в инспекторе, чтобы подсказка
## не могла разойтись с настоящей таблицей.
##
## Порядок проверок важен. Куча в 2 м спрашивается ПЕРВОЙ, до объекта на клетке:
## сама куча и есть объект (add_dirt ставит FEATURE_DIRT_PILE), и по таблице #14
## она в полный рост горит как стена (2/6), а не как укрытие (3/6) — метровая.
func fire_need(cell: GridCell) -> int:
	if cell.is_tall_dirt():
		return MCF.FIRE_NEED_TALL_DIRT
	if cell.feature_id != "":
		# Всё, чего в таблице нет, — рядовое укрытие: мешки, ёж, ДПМГ, куча 1 м.
		return int(MCF.FIRE_NEED_BY_FEATURE.get(cell.feature_id, MCF.FIRE_NEED_COVER))
	match cell.floor_type:
		MCF.FLOOR_GRASS:
			return MCF.FIRE_NEED_GRASS
		MCF.FLOOR_FLAMMABLE:
			return MCF.FIRE_NEED_WOOD
	return MCF.FIRE_NEED_FLOOR

## Огонь не может войти/пройти сквозь: пустоту (космос), несгораемую ЛДФ (#84), ДОТ (§6.5).
func _fire_blocked(cell: GridCell) -> bool:
	return cell.is_space or cell.feature_id == MCF.FEATURE_LDF \
			or cell.feature_id == MCF.FEATURE_DOT or cell.feature_id == MCF.FEATURE_DOT_OPEN

## 4 ортогональных соседа в пределах поля (без диагоналей) — для распространения огня.
func _ortho4(coord: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = coord + d
		if state.grid.in_bounds(n):
			out.append(n)
	return out

# --- Туман войны (§3.9) ---

## Радиус обзора юнита (свой параметр или значение по умолчанию).
## Радиус обзора юнита. По item 46 обзор НИЧЕМ не ограничен по дальности — он идёт,
## пока луч не упрётся в стену, — поэтому по умолчанию отдаётся окно во всю карту.
## Явно прописанный в статах sight_range при этом уважается: если однажды понадобится
## близорукий юнит, менять здесь ничего не придётся.
func sight_of(unit: UnitInstance) -> int:
	var s: int = unit.stats.sight_range
	return s if s > 0 else MCF.SIGHT_UNLIMITED

## Есть ли стена на луче между a и b (концы исключены) — для глаз стороны `viewer`:
## ей закрывают обзор ещё и корпуса вражеских танков (см. _tank_sig). -1 — только рельеф.
## Брезенхэм шагает здесь ЖЕ. Раньше луч строился вспомогательной _ray_cells(), которая
## возвращала МАССИВ клеток, — а туман войны делает эту проверку по разу на каждую
## клетку в радиусе обзора каждого бойца, то есть тысячи массивов на один пересчёт.
## Порядок обхода и условие обрыва буква в букву те же, что были у _ray_cells;
## сама она удалена — других вызывающих у неё не осталось.
func _vision_blocked(a: Vector2i, b: Vector2i, viewer: int = -1) -> bool:
	if _line_off_board(a, b):
		return true
	var sig := _tank_sig(viewer)
	var tanks: PackedInt32Array = _tank_sig_cells[sig] if sig != 0 else PackedInt32Array()
	var dx: int = absi(b.x - a.x)
	var dy: int = absi(b.y - a.y)
	var sx: int = 1 if a.x < b.x else -1
	var sy: int = 1 if a.y < b.y else -1
	var err: int = dx - dy
	var cx := a.x
	var cy := a.y
	var bx := b.x
	var by := b.y
	var grid := state.grid
	while cx != bx or cy != by:
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			cx += sx
		if e2 < dx:
			err += dx
			cy += sy
		if cx == bx and cy == by:
			break
		var cell := grid.cell_fast(cx, cy)
		# Стекло прозрачно (#29). Без этого пункт 29 недостижим в принципе: сквозь
		# стекло разрешено СТРЕЛЯТЬ, но цель за ним оставалась в тумане, а невидимую
		# цель нельзя выбрать (can_shoot → "Target not visible"). Строковое сравнение
		# стоит здесь дёшево: до него доходят только клетки, уже опознанные как стена.
		# Живые обзор не перекрывают, машины — тоже, КРОМЕ вражеского танка: его корпус
		# закрывает обзор противнику (не своим). Стена и закрытый шлюз — GridCell.blocks_sight().
		if cell.cover_height >= MCF.WALL_HEIGHT and not MCF.is_glass(cell.feature_id):
			return true
		if not tanks.is_empty() and tanks.has(cy * grid.width + cx):
			return true
	return false

## Видит ли команда владельца эту клетку (общая видимость, §3.9).
##
## Ответ берётся из готового множества team_visible_coords() — это ТО ЖЕ САМОЕ объединение
## _unit_sees() по живым бойцам стороны, только посчитанное один раз и переиспользуемое.
## Прежний вариант перебирал всю армию с лучом Брезенхэма на каждого, а вызывают его из
## can_shoot() по разу НА КАЖДУЮ возможную цель: в бою на 200 бойцов один только показ
## доступных целей выливался в десятки тысяч лучей (≈6 мс на юнита).
##
## Клетки вне поля в множество не попадают, и это правильно: _unit_sees() отсеял бы их
## проверкой дальности (у сидящего в машине coord вынесен далеко за карту, §техника).
##
## Спрашивают ОДНУ клетку, а строили множество на всю армию (#106). Каждый выстрел зовёт
## сюда через can_shoot(), а к моменту выстрела кто-нибудь уже успел походить — значит
## vision_epoch сменился, и готовое множество приходилось досчитывать: проход по всей
## стороне с перестройкой обзора тем, кто сдвинулся. В бою на 300 бойцов это 10 мс НА
## ВЫСТРЕЛ и 95% всего времени резолвера.
##
## Поэтому: множество берём, только если оно и так уже актуально (те же три сверки, что
## и в team_visible_coords). Иначе отвечаем напрямую — «видит ли хоть кто-то свой эту
## клетку», с выходом на первом же увидевшем.
##
## Ответ тот же с точностью до буквы. _seen_from() кладёт клетку в обзор бойца ровно при
## двух условиях: она внутри окна радиуса r по Чебышёву и луч Брезенхэма из бойца в неё
## не встретил стены или корпуса машины. Здесь проверяются те же два, а _vision_blocked()
## — та же самая арифметика луча, что развёрнута внутри _seen_from(). Множество же
## команды — просто объединение этих обзоров, то есть «хоть один боец».
## Клетки вне поля не видит никто: их отбрасывает окно обхода в _seen_from().
## Один вопрос — один ответ: множество строит team_visible_coords(), а это просто
## взгляд в него. Здесь ЖИЛА вторая, самостоятельная реализация того же обхода — и
## именно она разошлась с первой на item 46: обзор техники добавили в множество, а
## быстрый путь по-прежнему перебирал только пеших, и танк в проёме «не видел».
## Считать одно и то же дважды нельзя; вопрос производительности закрыт кешем внутри
## team_visible_coords, который на прогретом состоянии стоит три сравнения целых.
func team_sees(owner: int, coord: Vector2i) -> bool:
	var grid := state.grid
	if coord.x < 0 or coord.y < 0 or coord.x >= grid.width or coord.y >= grid.height:
		return false
	if not fog_enabled:
		return true  # туман выключен — видно всё поле (см. team_visible_coords)
	return team_visible_coords(owner).has(coord)

## Видит ли команда владельца этого юнита. Свои — всегда видны.
func is_visible_to_team(owner: int, target: UnitInstance) -> bool:
	if not fog_enabled:
		return true
	# Всеведущая сторона (ИИ, #43) видит любого юнита сквозь туман.
	if owner == omniscient_side:
		return true
	# Свои и союзники по команде видны всегда — они на связи, а не в тумане.
	if state.roster.are_allies(owner, target.owner):
		return true
	return team_sees(owner, target.coord)

# --- Туман войны: обзор одного бойца ------------------------------------------------
## Что видно ИЗ клетки с радиусом r. Ключ — Vector3i(x, y, r), значение — Array[Vector2i]
## видимых клеток в том же порядке обхода, что был у прежнего сплошного пересчёта.
##
## Кеш ОБЩИЙ на все резолверы (static) и живёт, пока не изменится обстановка ПО ОБЗОРУ,
## то есть GridCell.vision_version. Так и надо: «что видно с клетки» — чистая функция от
## рельефа, она не зависит ни от того, чей это боец, ни от того, кто где стоит (живые
## обзор не перекрывают). AIController создаёт новый GameActionResolver на КАЖДОЕ решение,
## поэтому кеш на экземпляре ему бы ничего не дал.
## Клетки хранятся ПЛОСКИМ индексом (y * width + x) в PackedInt32Array, а не массивом
## Vector2i: в бою на сотню бойцов один пересчёт перебирает под сотню тысяч клеток, и
## упаковка каждой в Variant-вектор стоит дороже самой трассировки луча.
static var _seen_cache: Dictionary = {}
static var _seen_version: int = -1
static var _seen_grid: int = 0
## Плоская таблица «клетка рвёт луч» (1 байт на клетку, индекс y * width + x). Луч
## Брезенхэма на каждом шаге спрашивал grid.cell_fast() и два поля объекта клетки; на
## холодном пересчёте по городу 50×50 это ~80 000 вызовов на бойца — секунда на сторону
## при старте партии, загрузке и K_RESYNC. Байт из PackedByteArray вдвое дешевле, а
## результат тот же бит в бит. Собирается заново вместе с кешем — по тем же условиям.
static var _blockers: PackedByteArray = PackedByteArray()
## Та же таблица, транспонированная (x·высота + y): в ней сплошняком лежат столбцы сетки,
## по которым обход ищет стены октантов |dx| ≥ |dy| (_sweep). Правится вместе с основной.
static var _blockers_t: PackedByteArray = PackedByteArray()

## Пересобрать таблицу блокировщиков по текущему рельефу. Условие — в точности то,
## что проверяет луч: стена (высота 2), но не стекло; корпус машины луч не рвёт.
static func _rebuild_blockers(grid: Grid) -> void:
	var gw := grid.width
	var gh := grid.height
	_blockers.resize(gw * gh)
	_blockers.fill(0)
	_blockers_t.resize(gw * gh)
	_blockers_t.fill(0)
	for y in gh:
		var row := y * gw
		for x in gw:
			var cell := grid.cell_fast(x, y)
			if cell.cover_height >= MCF.WALL_HEIGHT and not MCF.is_glass(cell.feature_id):
				_blockers[row + x] = 1
				_blockers_t[x * gh + y] = 1
## Потолок кеша: за длинный бой в нём оседает по записи на каждую позицию, где кто-то
## постоял, и адресная чистка (проход по всем ключам) начинает стоить дороже пересчёта.
const SEEN_CACHE_CAP := 8192
## И потолок по объёму: на карте 250×250 с безграничным обзором одна запись — до 62 500
## клеток, и восемь тысяч таких записей — это гигабайты. 16 млн клеток — 64 МБ.
const SEEN_CELLS_CAP := 16_000_000
static var _seen_cells: int = 0
## Чувствительные клетки каждой записи кеша (см. _sweep): ключ тот же, что в _seen_cache.
static var _seen_sens: Dictionary = {}

## Положить обзор в кеш. Кеш держится в порядке давности использования (попадание
## переставляет запись в конец), и переполненный теряет самые давние записи, а не
## обнуляется целиком: иначе раз в пару сотен шагов вся армия пересчитывала бы обзор разом.
static func _store_seen(key: Vector4i, out: PackedInt32Array, sens: PackedInt32Array) -> void:
	_seen_cache[key] = out
	_seen_sens[key] = sens
	_seen_cells += out.size() + sens.size()
	if _seen_cache.size() <= SEEN_CACHE_CAP and _seen_cells <= SEEN_CELLS_CAP:
		return
	for old: Vector4i in _seen_cache.keys():
		if _seen_cache.size() <= SEEN_CACHE_CAP / 2 and _seen_cells <= SEEN_CELLS_CAP / 2:
			break
		_drop_seen(old)

static func _drop_seen(key: Vector4i) -> void:
	_seen_cells -= (_seen_cache[key] as PackedInt32Array).size() \
			+ (_seen_sens.get(key, PackedInt32Array()) as PackedInt32Array).size()
	_seen_cache.erase(key)
	_seen_sens.erase(key)

static func _clear_seen() -> void:
	_seen_cache.clear()
	_seen_sens.clear()
	_seen_cells = 0

## Попадание: запись переезжает в конец порядка давности.
static func _touch_seen(key: Vector4i, hit: PackedInt32Array) -> void:
	_seen_cache.erase(key)
	_seen_cache[key] = hit

## Поправить таблицу стен по журналу обзора: только клетки, пересекавшие порог стены
## после версии from_version. Журнал общий на все сетки, поэтому клетку перечитываем с
## НАШЕЙ сетки — чужая запись просто перепроверит свою же клетку.
static func _patch_blockers(grid: Grid, from_version: int) -> void:
	var changes := GridCell.vision_changes
	var gw := grid.width
	var i: int = (from_version - GridCell.vision_log_base) * 2
	while i < changes.size():
		var c := grid.cell(Vector2i(changes[i], changes[i + 1]))
		if c != null:
			var b := 1 if c.blocks_sight() else 0
			_blockers[c.coord.y * gw + c.coord.x] = b
			_blockers_t[c.coord.x * grid.height + c.coord.y] = b
		i += 2

## Клетки, видимые с coord при радиусе r. Порядок — dy снаружи, dx внутри, оба по
## возрастанию: тот же, в котором их складывал прежний двойной цикл team_visible_coords.
##
## Правило видимости (решение M4) не изменилось: обзор площадной, в радиусе по Чебышёву,
## стены (высота 2) и корпуса машин рвут луч Брезенхэма, живые юниты — нет. Прежняя
## _unit_sees() делала ровно эти две проверки по одной клетке; здесь дальность соблюдена
## самим окном обхода, поэтому от неё осталась только проверка луча.
## Догнать кеш до текущего рельефа. Запись «что видно из (x,y) в радиусе r» зависит
## только от клеток внутри её же окна: луч Брезенхэма из центра в клетку окна за пределы
## окна не выходит. Поэтому изменение в клетке (cx, cy) обесценивает ровно те записи,
## чьё окно её накрывает, — остальные остаются в силе. Из-за этого рухнувшая стена стоит
## пересчёта обзора нескольким бойцам, а не всей армии.
##
## Точнее окна — список чувствительных клеток записи (_sweep): при безграничном обзоре
## окно у всех — вся карта, а стену в тени чужих стен обзор просто не замечает.
static func _catch_up_seen(from_version: int, gw: int) -> void:
	var changes := GridCell.vision_changes
	var at := PackedInt32Array()
	var i: int = (from_version - GridCell.vision_log_base) * 2
	while i < changes.size():
		at.append(changes[i + 1] * gw + changes[i])
		i += 2
	var doomed: Array = []
	for key: Vector4i in _seen_cache:
		var sens: PackedInt32Array = _seen_sens.get(key, PackedInt32Array())
		for v: int in at:
			var k := sens.bsearch(v)
			if k < sens.size() and sens[k] == v:
				doomed.append(key)
				break
	for key: Vector4i in doomed:
		_drop_seen(key)

## Корпуса танков в обзоре. Танк — единственная машина, которая закрывает обзор, и
## закрывает он его только ВРАГУ (не своим и не союзникам): свой экипаж и пехота вокруг
## смотрят сквозь, противник за танком ничего не видит. Челнок и борг обзор не закрывают,
## обломки — тоже: это уже не танк. Меняется набор ровно тогда, когда танк переехал, сменил
## хозяина или сгорел, — все три двигают UnitInstance.vision_epoch (Vehicle.gd), так что
## кеш обзора стороны узнаёт об этом сам.
##
## Набор клеток «чужих танков» для стороны получает постоянный номер (_tank_sigs): номер —
## часть ключа кеша обзора. Номера не переиспользуются, поэтому запись, собранная при
## другом расположении танков, никогда не выдаст себя за нынешнюю.
static var _tank_sigs: Dictionary = {}       # PackedInt32Array (клетки) -> номер
static var _tank_sig_cells: Dictionary = {}  # номер -> PackedInt32Array
static var _tank_sig_next: int = 1
static var _tank_masks: Dictionary = {}      # номер -> [_blockers, _blockers_t] с корпусами танков

## Номер набора корпусов танков, враждебных стороне `viewer`; 0 — таких нет (или смотрит
## «никто»: только рельеф).
func _tank_sig(viewer: int) -> int:
	if viewer < 0:
		return 0
	var gw := state.grid.width
	var cells := PackedInt32Array()
	for veh: Vehicle in state.all_vehicles():
		if veh.type_id != "tank" or veh.wrecked or not veh.alive():
			continue
		if veh.owner == viewer or state.roster.are_allies(viewer, veh.owner):
			continue
		for fc: Vector2i in veh.footprint():
			if state.grid.in_bounds(fc):
				cells.append(fc.y * gw + fc.x)
	if cells.is_empty():
		return 0
	cells.sort()
	var id: Variant = _tank_sigs.get(cells)
	if id == null:
		if _tank_sigs.size() > 4096:
			_tank_sigs.clear()
			_tank_sig_cells.clear()
		id = _tank_sig_next
		_tank_sig_next += 1
		_tank_sigs[cells] = id
		_tank_sig_cells[id] = cells
	return id

## Пара [таблица, транспонированная таблица] блокировщиков для набора `sig`: рельеф плюс
## корпуса этих танков. gh — высота сетки (для транспонированных индексов).
static func _tank_masks_of(sig: int, gh: int) -> Array:
	if sig == 0:
		return [_blockers, _blockers_t]
	var hit: Variant = _tank_masks.get(sig)
	if hit != null:
		return hit
	if _tank_masks.size() > 64:
		_tank_masks.clear()
	var mask := _blockers.duplicate()
	var mask_t := _blockers_t.duplicate()
	var gw := mask.size() / gh
	for i: int in _tank_sig_cells[sig]:
		mask[i] = 1
		mask_t[(i % gw) * gh + i / gw] = 1
	var pair := [mask, mask_t]
	_tank_masks[sig] = pair
	return pair

func _seen_from(coord: Vector2i, r: int, viewer: int = -1) -> PackedInt32Array:
	# Смотрящий вне поля (сидит в машине, coord = OFFBOARD) не видит ничего: лучи из
	# такой точки уходят за край сетки. Вызывающие сидящих и так пропускают — это
	# страховка на будущих вызывающих (issue 2).
	if not state.grid.in_bounds(coord):
		return PackedInt32Array()
	_sync_seen()
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	# Неограниченный обзор (item 46) приходит сюда радиусом в тысячу клеток. Окно
	# обхода урезаем до размеров карты СРАЗУ: дальше её края смотреть некуда, а
	# перебирать четыре миллиона несуществующих клеток ради этого — нет. Обрезка
	# идёт до ключа кеша, поэтому все «безграничные» бойцы делят одну запись.
	r = mini(r, maxi(gw, gh))
	var sig := _tank_sig(viewer)
	var key := Vector4i(coord.x, coord.y, r, sig)
	var hit: Variant = _seen_cache.get(key)
	if hit != null:
		_touch_seen(key, hit)
		return hit
	var same: Variant = _reuse_under(key, viewer)
	if same != null:
		return same
	var masks := _tank_masks_of(sig, gh)
	var res := _sweep(coord.x, coord.y, r, masks[0], gw, gh, masks[1])
	_store_seen(key, res[0], res[1])
	return res[0]

## Вражеский танк переехал, сменил хозяина или сгорел — номер набора танков у стороны
## стал другим, и ключ обзора тоже. Но обзор из этой точки меняется, только если одна из
## клеток, где танк был или стал, для него чувствительна (_sweep): иначе вся перемена
## лежит в чужой тени. Тогда запись под прежним номером годится и под новым — без обхода.
## Прежние номера — несколько последних, под которыми смотрела эта сторона.
static var _sig_history: Dictionary = {}   # viewer -> Array номеров, новый последним
const SIG_HISTORY := 4

func _reuse_under(key: Vector4i, viewer: int) -> Variant:
	var hist: Array = _sig_history.get(viewer, [])
	if hist.is_empty() or hist[hist.size() - 1] != key.w:
		hist.erase(key.w)
		hist.append(key.w)
		if hist.size() > SIG_HISTORY:
			hist.pop_front()
		_sig_history[viewer] = hist
	var now: Variant = _tank_sig_cells.get(key.w, PackedInt32Array() if key.w == 0 else null)
	if now == null:
		return null
	for h in range(hist.size() - 2, -1, -1):
		var prev: int = hist[h]
		var old_key := Vector4i(key.x, key.y, key.z, prev)
		var old: Variant = _seen_cache.get(old_key)
		if old == null:
			continue
		var was: Variant = _tank_sig_cells.get(prev, PackedInt32Array() if prev == 0 else null)
		if was == null:
			continue   # реестр наборов обнулялся — разницы не узнать
		var sens: PackedInt32Array = _seen_sens.get(old_key, PackedInt32Array())
		if _touches(was, now, sens) or _touches(now, was, sens):
			continue
		_store_seen(key, old, sens)
		return old
	return null

## Есть ли среди клеток mine, которых нет в other, хоть одна из sens (все по возрастанию).
static func _touches(mine: PackedInt32Array, other: PackedInt32Array,
		sens: PackedInt32Array) -> bool:
	for c: int in mine:
		var o := other.bsearch(c)
		if o < other.size() and other[o] == c:
			continue   # клетка корпуса и там и там — не перемена
		var k := sens.bsearch(c)
		if k < sens.size() and sens[k] == c:
			return true
	return false

## Догнать кеш обзора до текущего рельефа (см. _catch_up_seen): сброс целиком — только
## когда точечная инвалидация невозможна (сменилась сетка, либо наша версия старше
## журнала — он обнулялся); иначе выкидываются ровно задетые записи.
func _sync_seen() -> void:
	var gid := state.grid.get_instance_id()
	if _seen_version == GridCell.vision_version and _seen_grid == gid:
		return
	if _seen_grid != gid or _seen_version < GridCell.vision_log_base:
		_clear_seen()
		_rebuild_blockers(state.grid)
	else:
		_catch_up_seen(_seen_version, state.grid.width)
		# Таблица стен — тоже адресно: открывшийся шлюз правит один байт, а не
		# пересобирает 62 500 клеток карты 250×250.
		_patch_blockers(state.grid, _seen_version)
	_seen_version = GridCell.vision_version
	_seen_grid = gid
	_tank_masks.clear()   # маски — рельеф плюс танки: рельеф сменился

## Что видно из (ux, uy) в радиусе r по Чебышёву при таблице блокировщиков blk. Это
## ТО ЖЕ САМОЕ множество, что давал луч Брезенхэма в каждую клетку окна (_vision_blocked),
## и в том же порядке — строки сверху вниз, в строке слева направо. Только быстрее.
##
## Почему можно. Этот Брезенхэм (err = dx − dy; шаг по x при 2·err > −dy, по y при
## 2·err < dx) зависит лишь от смещения цели, и в октанте |dx| ≥ |dy| его клетка в
## столбце i — ровно (i, ⌈i·s − ½⌉), s = |dy|/|dx|: наклон, округлённый с половиной ВНИЗ
## (в октанте |dy| > |dx| — то же с осями наоборот, знаки — зеркало). Значит, стена в
## столбце i, ряду j закрывает ровно те цели дальше столбца i, чей наклон лежит в
## ((2j−1)/2i, (2j+1)/2i]. Идём по столбцам наружу и держим отсортированный список
## закрытых промежутков наклона; цель в столбце a видна, если её b/a ни в один не попал.
## Всё — в целых числах (дроби сравниваются крест-накрест), поэтому совпадение точное, а
## не «почти»: tests/run_fog.gd сверяет с буквальным лучом на сотнях случайных полей.
##
## Цена — одна проверка на клетку вместо луча, а в застроенном месте октант обрывается, как
## только закрыты все наклоны. Поле 250×250 с безграничным обзором: десятки миллисекунд на
## бойца вместо сотен.
static func _sweep_seen(ux: int, uy: int, r: int, blk: PackedByteArray, gw: int,
		gh: int) -> PackedInt32Array:
	return _sweep(ux, uy, r, blk, gw, gh)[0]

## Сам обход: [видимые клетки, чувствительные клетки] — оба списка плоских индексов по
## возрастанию. Чувствительная — клетка, от стены на которой (или её сноса) этот обзор
## может измениться: её промежуток наклонов ((2j−1)/2a, (2j+1)/2a] не лежит целиком в
## тени ближних стен. Остальные клетки — в чужой тени целиком, и что бы с ними ни
## случилось, отсюда видно то же самое. По этому списку журнал обзора решает, чью запись
## в кеше выбрасывать (_catch_up_seen): при безграничном обзоре окно каждого бойца — вся
## карта, и без него каждый открывшийся шлюз обнулял обзор всей армии.
##
## Строго: если после смены клетки c в столбце i цель t дальше неё стала (не)видна, луч
## к t проходит через c, а всё до c на нём свободно. Тогда наклон t открыт в столбце i и
## лежит в промежутке c — промежуток не в тени, и c отмечена. Клетки за столбцом, на
## котором октант закрылся целиком, не просматриваются вовсе — и не отмечаются.
static func _sweep(ux: int, uy: int, r: int, blk: PackedByteArray, gw: int,
		gh: int, blk_t: PackedByteArray = PackedByteArray()) -> Array:
	# Столбец октанта лежит сплошняком либо в самой таблице (октанты |dy| > |dx|: столбец —
	# кусок строки сетки), либо в транспонированной (|dx| ≥ |dy|: кусок столбца сетки).
	if blk_t.is_empty():
		blk_t = _transpose(blk, gw, gh)
	var origin := uy * gw + ux
	var out := PackedInt32Array([origin])
	var parts: Array = []   # куски списка чувствительных (Packed-массив в функцию — копией)
	var shared := {}   # клетки осей и диагоналей: их просматривают два октанта сразу
	# Закрытые наклоны (lo, hi] — четыре параллельных массива: числители и знаменатели.
	var lo_n := PackedInt32Array()
	var lo_d := PackedInt32Array()
	var hi_n := PackedInt32Array()
	var hi_d := PackedInt32Array()
	for oct in 8:
		var xmajor := oct < 4
		var sx := -1 if (oct & 1) != 0 else 1
		var sy := -1 if (oct & 2) != 0 else 1
		var major_step := sx
		var minor_step := sy * gw
		var major_room := (gw - 1 - ux) if sx > 0 else ux
		var minor_room := (gh - 1 - uy) if sy > 0 else uy
		if not xmajor:
			major_step = sy * gw
			minor_step = sx
			major_room = (gh - 1 - uy) if sy > 0 else uy
			minor_room = (gw - 1 - ux) if sx > 0 else ux
		var run: PackedByteArray = blk_t if xmajor else blk
		var run_dir := sy if xmajor else sx
		# Ось (b == 0) общая у двух соседних октантов — её считает «положительный».
		var b0 := 1 if ((sy < 0) if xmajor else (sx < 0)) else 0
		lo_n.clear()
		lo_d.clear()
		hi_n.clear()
		hi_d.clear()
		var amax := mini(r, major_room)
		var a := 1
		while a <= amax:
			var col := origin + major_step * a
			# Цели столбца: в октанте |dy| > |dx| строго — диагональ досталась соседу.
			var bmax := mini(a if xmajor else a - 1, minor_room)
			var jmax := mini(a, minor_room)
			var n := lo_n.size()
			# Цель b видна, если её наклон b/a не лежит ни в одном закрытом (lo, hi]: закрытый
			# прячет ровно строки a·lo < b ≤ a·hi. Промежутки упорядочены и не касаются друг
			# друга, так что видимое — просветы между их строками; каждый просвет — одна
			# арифметическая прогрессия индексов, и выписывается она разом.
			var cur := b0
			var k := 0
			while k < n and cur <= bmax:
				var bs: int = _fdiv(a * lo_n[k], lo_d[k]) + 1
				if bs > bmax:
					break
				var be: int = _fdiv(a * hi_n[k], hi_d[k])
				if be >= cur and bs <= be:
					if bs > cur:
						out.append_array(_prog(col + minor_step * cur, minor_step, bs - cur))
					cur = be + 1
				k += 1
			if cur <= bmax:
				out.append_array(_prog(col + minor_step * cur, minor_step, bmax - cur + 1))
			# Чувствительные клетки: промежуток клетки ((2j−1)/2a, (2j+1)/2a] не внутри одного
			# закрытого (закрытые слиты — «в тени целиком» и есть «внутри одного»). Закрытый
			# (lo, hi] накрывает целиком ровно строки 2a·lo + 1 ≤ 2j ≤ 2a·hi − 1.
			var a2 := 2 * a
			var js := 0
			k = 0
			while k < n and js <= jmax:
				var cs: int = -_fdiv(-(a2 * lo_n[k] + lo_d[k]), 2 * lo_d[k])
				if cs > jmax:
					break
				var ce: int = _fdiv(a2 * hi_n[k] - hi_d[k], 2 * hi_d[k])
				if ce >= js and cs <= ce:
					if cs > js:
						_sens_rows(parts, shared, col, minor_step, js, cs - 1, a)
					js = ce + 1
				k += 1
			if js <= jmax:
				_sens_rows(parts, shared, col, minor_step, js, jmax, a)
			# Стены столбца закрывают наклоны для всего, что дальше. Все — и те, что сами
			# в тени: край чужой тени бывает шире своей. Ищутся они поиском байта по
			# сплошному куску таблицы, а не перебором клеток.
			var base: int = ((ux + sx * a) * gh + uy) if xmajor else col
			var from: int = base if run_dir > 0 else base - jmax
			var seg := run.slice(from, from + jmax + 1)
			var hit := seg.find(1)
			while hit != -1:
				var j: int = hit if run_dir > 0 else jmax - hit
				# Новый промежуток ((2j−1)/2a, (2j+1)/2a] вливается в список: всё, что с ним
				# пересекается или смыкается, сливается в один.
				var nl := 2 * j - 1
				var dl := 2 * a
				var nh := 2 * j + 1
				var dh := 2 * a
				var m := lo_n.size()
				var p := 0
				while p < m and hi_n[p] * dl < nl * hi_d[p]:
					p += 1
				var q := p
				while q < m and lo_n[q] * dh <= nh * lo_d[q]:
					if lo_n[q] * dl < nl * lo_d[q]:
						nl = lo_n[q]
						dl = lo_d[q]
					if hi_n[q] * dh > nh * hi_d[q]:
						nh = hi_n[q]
						dh = hi_d[q]
					q += 1
				if q == p:
					lo_n.insert(p, nl)
					lo_d.insert(p, dl)
					hi_n.insert(p, nh)
					hi_d.insert(p, dh)
				else:
					lo_n[p] = nl
					lo_d[p] = dl
					hi_n[p] = nh
					hi_d[p] = dh
					for t in q - p - 1:
						lo_n.remove_at(p + 1)
						lo_d.remove_at(p + 1)
						hi_n.remove_at(p + 1)
						hi_d.remove_at(p + 1)
				hit = seg.find(1, hit + 1)
			# Закрыто всё от наклона 0 до 1 — дальше в этом октанте не видно ничего.
			if lo_n.size() == 1 and lo_n[0] < 0 and hi_n[0] >= hi_d[0]:
				break
			a += 1
	out.sort()
	var sens := PackedInt32Array()
	for part: PackedInt32Array in parts:
		sens.append_array(part)
	for i: int in shared:
		sens.append(i)
	sens.sort()
	return [out, sens]

## ⌊p / q⌋ при q > 0 — точно, в целых (деление GDScript округляет к нулю).
static func _fdiv(p: int, q: int) -> int:
	return (p - posmod(p, q)) / q

## count индексов start, start + step, … одним массивом.
static func _prog(start: int, step: int, count: int) -> PackedInt32Array:
	if count == 1:
		return PackedInt32Array([start])
	return PackedInt32Array(range(start, start + step * count, step))

## Чувствительные строки p..q столбца: внутренние — прогрессией в список, а клетки оси
## (j = 0) и диагонали (j = a) — в общий словарь: их видят два октанта, и дважды в
## списке им не место.
static func _sens_rows(parts: Array, shared: Dictionary, col: int, step: int,
		p: int, q: int, a: int) -> void:
	if p == 0:
		shared[col] = true
		p = 1
	if q == a:
		shared[col + step * a] = true
		q = a - 1
	if p <= q:
		parts.append(_prog(col + step * p, step, q - p + 1))

## Таблица блокировщиков, транспонированная: индекс x·высота + y.
static func _transpose(blk: PackedByteArray, gw: int, gh: int) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(gw * gh)
	for y in gh:
		var row := y * gw
		for x in gw:
			if blk[row + x] != 0:
				t[x * gh + y] = 1
	return t

## Обзор машины — объединение обзоров со ВСЕХ клеток её следа (batch 13 #1). Раньше
## смотрели из origin (верхний-левый угол), а собственный корпус ещё и рвал луч: танк
## видел только вверх и влево, остальное закрывали его же клетки. Теперь корпус лучу
## не мешает, а бойницы есть по всему периметру — из-за угла выглядывает та кромка,
## которая к нему ближе. Порядок сбора детерминирован (клетки следа по строкам, внутри
## клетки — порядок _seen_from), поэтому сравнение «обзор не изменился» остаётся честным.
##
## Объединение кешируется отдельной записью (r < 0 в ключе — метка «след машины»): его
## спрашивают на каждом пересчёте тумана, а на карте 250×250 это девять обзоров по
## десятку тысяч клеток. Чувствительные клетки записи — объединение чувствительных клеток
## следа, так что журнал обзора выкидывает её ровно тогда же, когда любую из частей.
func _vehicle_seen(veh: Vehicle) -> PackedInt32Array:
	var cells := veh.footprint()
	if cells.size() == 1:
		return _seen_from(cells[0], MCF.SIGHT_UNLIMITED, veh.owner)
	_sync_seen()
	var grid := state.grid
	var sig := _tank_sig(veh.owner)
	var key := Vector4i(veh.origin.x, veh.origin.y, -1 - (veh.size.x * 1024 + veh.size.y), sig)
	var hit: Variant = _seen_cache.get(key)
	if hit != null:
		_touch_seen(key, hit)
		return hit
	var same: Variant = _reuse_under(key, veh.owner)
	if same != null:
		return same
	var r := mini(MCF.SIGHT_UNLIMITED, maxi(grid.width, grid.height))
	var mark := PackedByteArray()
	mark.resize(grid.width * grid.height)
	var out := PackedInt32Array()
	var sens := PackedInt32Array()
	for c: Vector2i in cells:
		for i: int in _seen_from(c, MCF.SIGHT_UNLIMITED, veh.owner):
			if mark[i] & 1 == 0:
				mark[i] = mark[i] | 1
				out.append(i)
		for i: int in _seen_sens.get(Vector4i(c.x, c.y, r, sig), PackedInt32Array()):
			if mark[i] & 2 == 0:
				mark[i] = mark[i] | 2
				sens.append(i)
	sens.sort()
	_store_seen(key, out, sens)
	return out

# --- Туман войны: обзор команды -------------------------------------------------------
## Множество клеток, видимых команде, считается ПРИРАЩЕНИЯМИ.
##
## Раньше на каждое изменение обстановки (то есть на каждое действие) множество строилось
## заново: ~(2r+1)² лучей Брезенхэма на каждого своего бойца. При r=12 и сотне бойцов это
## 62 000 лучей — 17 мс, и ровно столько же на КАЖДЫЙ кадр отрисовки, пока идёт чужой ход.
##
## Теперь на клетку хранится СЧЁТЧИК: сколько своих бойцов её видят. Шаг одного бойца
## снимает счётчики его прежнего обзора и добавляет счётчики нового — пара сотен операций
## вместо шестидесяти тысяч лучей.
##
## Счётчики живут в ОТДЕЛЬНОМ словаре с плоским целым ключом (y*width+x), а наружу
## отдаётся привычное множество Vector2i. Разделение не косметическое: пересчёт трогает
## счётчик каждой видимой клетки каждого бойца (под сотню тысяч раз), а вот НАБОР клеток
## меняется только там, где счётчик перешёл через ноль — таких клеток на порядок меньше.
## Значит Vector2i строится ровно на переходах, а не на каждом касании.
##
## Полный пересчёт не остаётся ни на один случай, кроме смены сетки и переключения самого
## тумана. Смерть бойца, посадка в машину, подкрепление и даже РУХНУВШАЯ СТЕНА разбираются
## приращениями: у каждого бойца хранится его последний обзор, и работа идёт только там,
## где он изменился. Рельеф правится точечно (GridCell.vision_changes), поэтому упавшая
## стена меняет обзор нескольким бойцам рядом, а не всей армии.
##
## Хранить сам ПРЕЖНИЙ обзор, а не позицию бойца, здесь обязательно. Снять старый вклад
## можно только тем же множеством клеток, каким он был добавлен, — а «пересчитать обзор
## из прежней клетки» после изменения рельефа дало бы уже другое множество, и счётчики
## разъехались бы навсегда.
var _vis_set: Dictionary = {}      # owner -> {Vector2i: true} — то, что отдаётся наружу
var _vis_counts: Dictionary = {}   # owner -> {плоский индекс: сколько бойцов видят}
var _vis_seen: Dictionary = {}     # owner -> {unit_id: PackedInt32Array} — учтённый вклад
var _vis_epoch: Dictionary = {}    # owner -> UnitInstance.vision_epoch на момент сборки
var _vis_vv: Dictionary = {}       # owner -> GridCell.vision_version на момент сборки
var _vis_grid: int = 0
var _vis_fog: bool = true
## Чьи глаза вливаются в обзор стороны: она сама плюс союзники по команде (§9
## «Туман войны», слияние обзора). Кешируется, потому что спрашивается в горячем
## цикле team_sees() — на КАЖДЫЙ выстрел по каждой возможной цели.
##
## Состав команд по ходу боя не меняется (его задаёт лобби до начала партии), так
## что кеш держится за экземпляр ростера и сбрасывается только вместе с ним.
var _ally_sets: Dictionary = {}
var _ally_roster: int = 0

## Множество сторон, чей обзор считается обзором этой. Без команд — она одна, и
## всё слияние обзора спит, ничего не стоя.
func _vision_sides(owner: int) -> Dictionary:
	var rid := state.roster.get_instance_id()
	if _ally_roster != rid:
		_ally_sets.clear()
		_ally_roster = rid
	var cached: Variant = _ally_sets.get(owner)
	if cached != null:
		return cached
	var out := {owner: true}
	for side in state.roster.vision_sharers(owner):
		out[side] = true
	_ally_sets[owner] = out
	return out

## Множество клеток, видимых команде (для тумана в UI).
func team_visible_coords(owner: int) -> Dictionary:
	# Самый частый случай — «с прошлого раза не изменилось вообще ничего»: его зовут из
	# can_shoot() на каждую возможную цель. Три сверки целых чисел, и мы вышли; иначе
	# пришлось бы перебирать всю армию, сверяя обзоры, только чтобы это выяснить.
	if _vis_epoch.get(owner) == UnitInstance.vision_epoch \
			and _vis_vv.get(owner) == GridCell.vision_version and _vis_fog == fog_enabled:
		return _vis_set[owner]
	var gid := state.grid.get_instance_id()
	if _vis_grid != gid or _vis_fog != fog_enabled:
		_vis_set.clear()
		_vis_counts.clear()
		_vis_seen.clear()
		_vis_epoch.clear()
		_vis_vv.clear()
		_vis_log.clear()   # всё видимое собирается заново — перерисовывать всё
		_vis_grid = gid
		_vis_fog = fog_enabled
	if not fog_enabled:
		# Туман выключен — видно всё поле. Множество не зависит ни от кого и строится
		# один раз на всю сетку.
		var full: Dictionary = _vis_set.get(owner, {})
		if full.is_empty():
			for y in state.grid.height:
				for x in state.grid.width:
					full[Vector2i(x, y)] = true
			_vis_set[owner] = full
		_vis_epoch[owner] = UnitInstance.vision_epoch
		_vis_vv[owner] = GridCell.vision_version
		return full

	var out: Dictionary = _vis_set.get(owner, {})
	var gw := state.grid.width
	# Счётчики — плоский массив по клеткам, а не словарь: на карте 250×250 обзор одного
	# бойца — десятки тысяч клеток, и шаг такого бойца стоил столько же операций словаря.
	var counts: PackedInt32Array = _vis_counts.get(owner, PackedInt32Array())
	if counts.size() != gw * state.grid.height:
		counts.resize(gw * state.grid.height)
		counts.fill(0)
	var seen: Dictionary = _vis_seen.get(owner, {})
	var memory: Dictionary = explored.get(owner, {})
	var log: Variant = _vis_log.get(owner)
	if log != null and log.size() > counts.size():
		_vis_log.erase(owner)   # никто не забирал — дешевле перерисовать всё
		log = null
	var live: Dictionary = {}
	var sides := _vision_sides(owner)
	for u in state.all_units():
		if not u.is_alive() or not sides.has(u.owner):
			continue
		# Экипаж В МАШИНЕ вынесен за карту (coord = OFFBOARD, −9999): его обзор даёт сама
		# машина ниже. Раньше пассажир всё равно попадал в _seen_from(), и луч Брезенхэма
		# из −9999 индексировал сетку по отрицательному адресу — «out of bounds get index»
		# при мультивыборе с посаженным юнитом (item 5). Пропускаем сидящих.
		if u.aboard_vehicle_id != -1:
			continue
		live[u.id] = true
		var fresh := _seen_from(u.coord, sight_of(u), u.owner)
		var was: Variant = seen.get(u.id)
		# Обзор этого бойца не изменился — его вклад уже в счётчиках, и трогать нечего.
		# На обычном ходу так отсеиваются 99 бойцов из 100.
		if was != null and was == fresh:
			continue
		counts = _vis_add(fresh, counts, out, memory, gw, log)
		if was != null:
			counts = _vis_drop(was, counts, out, gw, log)
		seen[u.id] = fresh
	# Техника тоже смотрит (item 46): обзор стороны — объединение ВСЕХ её глаз, а не
	# только пеших. Экипаж внутри вынесен за карту и своего обзора не даёт, так что
	# без этого прохода танк ехал бы вслепую. Ключ отрицательный, чтобы не столкнуться
	# с id юнитов в тех же словарях: у машин своя нумерация с нуля.
	for veh: Vehicle in state.all_vehicles():
		if veh.wrecked or not sides.has(veh.owner):
			continue
		# Смотрит ЭКИПАЖ, а не железо (batch 13 #1): пустая машина — слепая.
		if veh.occupants.is_empty():
			continue
		var vkey := -1 - veh.id
		live[vkey] = true
		var vfresh := _vehicle_seen(veh)
		var vwas: Variant = seen.get(vkey)
		if vwas != null and vwas == vfresh:
			continue
		counts = _vis_add(vfresh, counts, out, memory, gw, log)
		if vwas != null:
			counts = _vis_drop(vwas, counts, out, gw, log)
		seen[vkey] = vfresh
	# Выбывшие — погиб, сел в машину, попал в плен, машину сожгли: снимаем их вклад.
	var gone: Array = []
	for uid: int in seen:
		if not live.has(uid):
			gone.append(uid)
	for uid: int in gone:
		counts = _vis_drop(seen[uid], counts, out, gw, log)
		seen.erase(uid)
	_vis_set[owner] = out
	_vis_counts[owner] = counts
	_vis_seen[owner] = seen
	_vis_epoch[owner] = UnitInstance.vision_epoch
	_vis_vv[owner] = GridCell.vision_version
	explored[owner] = memory
	return out

## Вклад одного обзора в счётчики стороны. Сначала ПРИБАВЛЯЕТСЯ новый обзор, потом
## вычитается прежний: клетки, видные и до шага, и после, так и не падают до нуля и не
## выходят из множества, чтобы тут же вернуться. Порядок ключей множества от этого
## другой, но его никто не перебирает — все спрашивают только has().
##
## Память разведки (item 46) пополняется здесь же, на переходе клетки 0 → 1: в видимое
## клетка попадает только так, и прежний проход по ВСЕМУ видимому после каждого
## пересчёта (десятки тысяч клеток на большой карте) давал ровно то же множество.
## Packed-массив в GDScript передаётся копией, поэтому счётчики возвращаются.
func _vis_add(cells: PackedInt32Array, counts: PackedInt32Array, out: Dictionary,
		memory: Dictionary, gw: int, log: Variant) -> PackedInt32Array:
	for i: int in cells:
		var n: int = counts[i]
		counts[i] = n + 1
		if n == 0:
			var c := Vector2i(i % gw, i / gw)
			out[c] = true
			memory[c] = true
			if log != null:
				log.append(i)
	return counts

func _vis_drop(cells: PackedInt32Array, counts: PackedInt32Array, out: Dictionary,
		gw: int, log: Variant) -> PackedInt32Array:
	for i: int in cells:
		var n: int = counts[i] - 1
		counts[i] = n
		if n == 0:
			out.erase(Vector2i(i % gw, i / gw))
			if log != null:
				log.append(i)
	return counts

## Журнал смен видимости для экрана боя: owner -> Array плоских индексов клеток, чья
## видимость сменилась с прошлого take_vis_changes(). Заводится первым же вызовом — пока
## его никто не спрашивает (ИИ, обучение, тесты), он не пишется вовсе.
var _vis_log: Dictionary = {}

## Клетки, чья видимость для стороны сменилась с прошлого вызова (в любую сторону, может
## повторяться); null — «сменилось всё»: первый вызов, сброс тумана, новая сетка, журнал
## переполнился. Экран боя держит по нему туман дальнего плана — текстуру, пиксель на
## клетку, — и перекрашивает только эти пиксели.
func take_vis_changes(owner: int) -> Variant:
	var log: Variant = _vis_log.get(owner)
	_vis_log[owner] = []
	return log

## Память разведки (item 46, режим STANDARD): owner -> {Vector2i: true}, всё, что
## сторона когда-либо видела.
##
## Живёт В РЕЗОЛВЕРЕ, а не в GameState, и это осознанно. Память копится ровно тогда,
## когда кто-то СПРАШИВАЕТ обзор стороны, а спрашивают его хост и клиент про разные
## стороны — каждый про свою. Лежи она в состоянии, партия бы тихо разъезжалась:
## поле, которое ни один слепок не сверяет и ни один тест не ловит. Это ровно тот
## класс поломки, который чинил M2, и заводить его заново нельзя.
##
## Как поле показа она к тому же и не нужна в состоянии: каждый клиент рисует свою
## сторону и накапливает ровно свою память.
##
## В REALISTIC режиме память не нужна вовсе — там вне обзора не видно ничего, — но
## копим её всегда: переключить режим посреди партии дешевле, чем восстанавливать
## историю задним числом, а пополняется она только клетками, впервые вошедшими в обзор.
var explored: Dictionary = {}

## Известна ли стороне эта клетка: видна сейчас ИЛИ разведана раньше (item 46).
## В REALISTIC режиме память не учитывается — там вопрос только «видно сейчас».
func team_knows(owner: int, coord: Vector2i) -> bool:
	if not fog_enabled:
		return true
	if team_visible_coords(owner).has(coord):
		return true
	if fog_mode != MCF.Fog.STANDARD:
		return false
	return (explored.get(owner, {}) as Dictionary).has(coord)

# --- Мирные жители (§3.10) ---

func _is_civilian(u: UnitInstance) -> bool:
	return CivilianAI.is_npc(u)

## Все живые солдаты на поле — цели для мирных (обе игровые стороны, §3.10).
func _living_soldiers() -> Array:
	var out: Array = []
	for u in state.all_units():
		if CivilianAI.is_soldier(u):
			out.append(u)
	return out

## Кандидаты на пробуждение (§3 «Нейтралы»): id спящих нейтралов, к которым подобрался
## повод активации — соседняя клетка сменила состояние или в поле зрения вошёл солдат.
## Копятся между действиями и разбираются каскадом в _wake_and_group на верхнем уровне
## resolve(); пустой список — обычное состояние, обходится в один if.
var _activation_frontier: Array[int] = []

## Видит ли нейтрал солдата (§3.1b). «Видит» = по ЧИСТОЙ прямой линии взгляда: клетки
## коллинеарны (Combat.is_on_firing_line) и между ними нет стены/корпуса; стекло не
## преграда (item 29). Косой, не по лучу, взгляд «видимостью» не считается — иначе, раз
## los_blocked для непрямой линии отвечает «не перекрыто», нейтрал будил бы всех подряд
## через все стены. Это тот же примитив зрения, что был и раньше, только строже описан.
func _civ_sees_soldier(civ: UnitInstance, idx: Dictionary = {}) -> bool:
	if idx.is_empty():
		idx = _sight_index()
	var c := civ.coord
	for key: Vector3i in [Vector3i(0, c.y, 0), Vector3i(1, c.x, 0), Vector3i(2, c.x - c.y, 0), Vector3i(3, c.x + c.y, 0)]:
		for t: Vector2i in idx.get(key, []):
			if t != c and not los_blocked(c, t, true, false, true):
				return true
	return false

## Клетки, с которых нейтрала можно «увидеть» (§3.1b): живые солдаты и корпуса техники
## игроков (item 12), разложенные по линиям огня — строка, столбец, две диагонали. Раньше
## каждый спящий житель перебирал ВСЕХ солдат (и заново собирал их список): 150 жителей ×
## 90 солдат давали ~80 мс на каждое действие в большой партии. Теперь проверяются только
## те, кто с ним на одной прямой, — ровно те, кого пропускал Combat.is_on_firing_line.
## Отладка/тест: шлюзы и пробуждение жителей всегда считаются полностью, без выборки
## «что изменилось». Итог обязан совпасть — это и проверяет tests/run_mp_perf.gd.
var check_everything := false

var _wk_pos: Dictionary = {}   # солдат -> клетка на прошлой проверке пробуждения
var _wk_vv: int = -1
var _wk_vsig: int = 0
var _wk_grid: int = 0

func _sight_index() -> Dictionary:
	var targets: Array[Vector2i] = []
	for s: UnitInstance in _living_soldiers():
		targets.append(s.coord)
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and not MCF.is_neutral(veh.owner):
			targets.append_array(veh.footprint())
	return _index_lines(targets)

## Клетки, разложенные по линиям огня (строка, столбец, две диагонали).
func _index_lines(targets: Array[Vector2i]) -> Dictionary:
	var idx := {}
	for t in targets:
		for key: Vector3i in [Vector3i(0, t.y, 0), Vector3i(1, t.x, 0), Vector3i(2, t.x - t.y, 0), Vector3i(3, t.x + t.y, 0)]:
			if not idx.has(key):
				idx[key] = []
			idx[key].append(t)
	return idx

## Вскрытие жителя (§3, item 3): пробуждается, если сам видит солдата (см. _civ_sees_soldier).
## Общий бой БОЛЬШЕ не будит всех разом — повод строго локальный: соседняя клетка сменила
## состояние (notify_cell_changed) ЛИБО солдат вошёл в обзор (здесь). Обратно вскрытие не
## снимается. Ещё не сгруппированного заносим во фронт — _wake_and_group соберёт группу.
func _update_breached(civ: UnitInstance, idx: Dictionary = {}) -> void:
	if civ.civilian_active:
		return
	if _civ_sees_soldier(civ, idx):
		civ.civilian_active = true
		if civ.neutral_group == 0 and not _activation_frontier.has(civ.id):
			_activation_frontier.append(civ.id)

## Повод активации (§3.1a): соседняя клетка сменила состояние — разрушена, застроена,
## открылся шлюз, взрыв или огонь. Спящие НЕ сгруппированные нейтралы вокруг встают во
## фронт пробуждения; его разбирает _wake_and_group на верхнем уровне resolve(). Зовётся
## из путей записи резолвера (_ignite, снос рельефа взрывом, стройка, окоп, открытие шлюза).
func notify_cell_changed(coord: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var c := Vector2i(coord.x + dx, coord.y + dy)
			if not state.grid.in_bounds(c):
				continue
			var u := state.grid.cell(c).occupant
			if u != null and _is_civilian(u) and u.is_alive() and u.neutral_group == 0 \
					and not _activation_frontier.has(u.id):
				_activation_frontier.append(u.id)

## Разлить пробуждение по СОСЕДСТВУ от одного семени (§3.2): волна идёт через спящих ещё
## не сгруппированных нейтралов, пока связный кластер не замкнётся. Будит их (civilian_active)
## и возвращает ровно этот кластер. «Уже в группе» (neutral_group != 0) — граница волны.
func _flood_component(seed_id: int) -> Array:
	var woke: Array = []
	var seen: Dictionary = {}
	var stack: Array[int] = [seed_id]
	while not stack.is_empty():
		var id: int = stack.pop_back()
		if seen.has(id):
			continue
		seen[id] = true
		var u := state.get_unit(id)
		if u == null or not _is_civilian(u) or not u.is_alive() or u.neutral_group != 0:
			continue
		u.civilian_active = true
		woke.append(u)
		for n: Vector2i in state.grid.neighbors(u.coord):
			var nb := state.grid.cell(n).occupant
			if nb != null and _is_civilian(nb) and nb.is_alive() \
					and nb.neutral_group == 0 and not seen.has(nb.id):
				stack.append(nb.id)
	return woke

## Каскад пробуждения (§3.2): разбирает весь фронт, будит достижимые кластеры и
## возвращает всех поднятых на ноги в этот заход (пустой — никого нового). Группировкой
## НЕ занимается — это отдельный шаг (_wake_and_group). Оставлен как самостоятельная
## операция для сценарных проверок пробуждения.
func _cascade_activation() -> Array:
	var woke: Array = []
	var frontier: Array[int] = _activation_frontier.duplicate()
	_activation_frontier.clear()
	while not frontier.is_empty():
		var id: int = frontier.pop_back()
		var u := state.get_unit(id)
		if u == null or not _is_civilian(u) or not u.is_alive() \
				or u.neutral_group != 0 or u.civilian_active:
			continue
		woke.append_array(_flood_component(id))
	return woke

## Номер следующей активационной группы (§15): по счёту уже созданных нейтральных
## слотов в очереди инициативы, +1. Считается от состояния, а не из отдельного счётчика,
## поэтому переживает пересоздание резолвера и откат хода.
func _next_group_number() -> int:
	var n := 0
	for slot: int in state.turns.round_order:
		if slot >= MCF.NEUTRAL_GROUP_BASE:
			n += 1
	return n + 1

## Собрать активационные группы (§15). Каждый СВЯЗНЫЙ кластер из фронта становится одной
## группой: получает римский номер по порядку, каждый его боец — этот номер и владелец-слот
## группы, а сам слот встаёт в СЛУЧАЙНОЕ место очереди инициативы. Жребий берётся из общего
## потока d6 (_rand_index) — иначе хост и клиент врезали бы группу в разные места. Разные
## кварталы — разные группы, потому и разливаем каждый кластер по своему семени.
func _wake_and_group(res: ActionResult) -> void:
	_seed_sight_activation()
	while not _activation_frontier.is_empty():
		var seed_id: int = _activation_frontier.pop_back()
		var su := state.get_unit(seed_id)
		if su == null or not _is_civilian(su) or not su.is_alive() or su.neutral_group != 0:
			continue
		var woke := _flood_component(seed_id)
		if woke.is_empty():
			continue
		var num := _next_group_number()
		var slot := MCF.neutral_group_slot(num)
		for u: UnitInstance in woke:
			u.neutral_group = num
			u.owner = slot
		var idx := _rand_index(state.turns.round_order.size() + 1)
		state.turns.insert_slot(slot, idx)
		res.log("— Neutral group %s joins the fight (%d unit%s) —" % [
			MCF.roman(num), woke.size(), "" if woke.size() == 1 else "s"])
		# Свежевскрытый кластер мог открыть обзор ещё одному кварталу — проверяем снова.
		_seed_sight_activation()

## Засеять фронт теми спящими НЕ сгруппированными нейтралами, кто видит солдата (§3.1b).
## Дорого только когда на карте есть и спящие нейтралы, и солдаты, — иначе выходит сразу.
func _seed_sight_activation() -> void:
	var soldiers := _living_soldiers()
	if soldiers.is_empty():
		return
	# Проверяем только то, что могло измениться с прошлого раза (batch mp-perf). Раньше на
	# каждое действие строился индекс ВСЕЙ армии и каждый спящий житель проверялся по нему
	# заново: ~4 мс на шаг в бою на полтысячи бойцов, у хоста и у каждого гостя.
	#
	# Итог обязан быть РОВНО тем же, что у полной проверки (иначе пиры с разной историей
	# кэша разошлись бы): житель, не видевший солдата, может увидеть его, только если
	#   * солдат сдвинулся или появился — проверяем по ним;
	#   * с линии между ними ушёл заслонявший юнит (живые юниты обзор закрывают) — житель
	#     на линии через освободившуюся клетку проверяется целиком;
	#   * сменился рельеф или машины — тогда проверяется всё.
	# Видевшие солдата, но ещё не собранные в группу проверяются целиком каждый раз.
	var sleepers: Array = []
	for u in state.all_units():
		if _is_civilian(u) and u.is_alive() and u.neutral_group == 0:
			sleepers.append(u)
	var pos := {}
	for u: UnitInstance in state.units.values():
		if not u.is_drone and u.is_alive() and state.grid.in_bounds(u.coord):
			pos[u.id] = u.coord
	var vsig := 0
	for veh: Vehicle in state.all_vehicles():
		if veh.alive():
			vsig = hash([vsig, veh.id, veh.origin])
	# Смена рельефа (шлюз открылся, стену снесли) — не повод проверять всех: она записана
	# по клеткам в журнале обзора, и увидеть больше можно лишь сквозь изменившуюся клетку на
	# своей линии. Журнала не хватило (давно не проверяли) — тогда уже всех.
	var full := _wk_vsig != vsig or _wk_grid != state.grid.get_instance_id() \
			or check_everything or (_wk_vv != GridCell.vision_version and _wk_vv < GridCell.vision_log_base)
	var moved: Array[Vector2i] = []
	var vacated := {}
	if not full:
		for so: UnitInstance in soldiers:
			var c: Vector2i = so.coord
			if _wk_pos.get(so.id) != c:
				moved.append(c)
		for id: int in _wk_pos:
			var was: Vector2i = _wk_pos[id]
			if pos.get(id) != was:
				for key in _line_keys(was):
					vacated[key] = true
		if _wk_vv != GridCell.vision_version:
			var changes := GridCell.vision_changes
			var i: int = (_wk_vv - GridCell.vision_log_base) * 2
			while i < changes.size():
				for key in _line_keys(Vector2i(changes[i], changes[i + 1])):
					vacated[key] = true
				i += 2
	var prev_seen := _wk_seen
	var prev_sleepers := _wk_sleepers
	_wk_seen = {}
	_wk_sleepers = {}
	for u: UnitInstance in sleepers:
		_wk_sleepers[u.id] = true
	_wk_pos = pos
	_wk_vv = GridCell.vision_version
	_wk_vsig = vsig
	_wk_grid = state.grid.get_instance_id()
	if sleepers.is_empty():
		return
	var full_idx: Dictionary = {}
	var moved_idx := _index_lines(moved)
	for u: UnitInstance in sleepers:
		if _activation_frontier.has(u.id):
			continue
		# Новый спящий (раньше не проверялся вовсе) — тоже целиком.
		var whole := full or prev_seen.has(u.id) or not prev_sleepers.has(u.id)
		if not whole and not vacated.is_empty():
			for key in _line_keys(u.coord):
				if vacated.has(key):
					whole = true
					break
		var sees := false
		if whole:
			if full_idx.is_empty():
				full_idx = _sight_index()
			sees = _civ_sees_soldier(u, full_idx)
		elif not moved.is_empty():
			sees = _civ_sees_soldier(u, moved_idx)
		if sees:
			_wk_seen[u.id] = true
			_activation_frontier.append(u.id)

## Четыре линии огня через клетку: строка, столбец, две диагонали (ключи _index_lines).
static func _line_keys(t: Vector2i) -> Array:
	return [Vector3i(0, t.y, 0), Vector3i(1, t.x, 0), Vector3i(2, t.x - t.y, 0), Vector3i(3, t.x + t.y, 0)]

var _wk_seen: Dictionary = {}   # жители, видевшие солдата на прошлой проверке
var _wk_sleepers: Dictionary = {}   # спящие жители на прошлой проверке

## Штаб мирного квартала (#103). Ровно тот же класс, что водит армию ИИ, только с
## нейтральным владельцем: см. большой комментарий в AIController. Хранится на резолвере,
## чтобы план строился ОДИН раз на слот жителей, а не заново на каждое их действие.
var _civ_brain: AIController = null

## Потолок действий за один слот жителей. Страховка, а не правило: каждое действие
## тратит ОД или несомый труп, поэтому цикл и так конечен. Но резолвер зовут из UI-потока,
## и молчаливый вечный цикл здесь означал бы намертво зависшую игру, а не сообщение
## в консоли, — поэтому предохранитель стоит.
const CIVILIAN_ACTION_CAP := 600

## Собственный ход мирных жителей (§3.10, #42/#56, #103).
##
## РАНЬШЕ здесь жил отдельный, второй «мозг»: житель шагал по одной клетке за активацию,
## не знал ни штабного плана, ни укрытий, ни дробления действий, стрелял по собственной
## упрощённой процедуре, а трупы умел только подбирать. Получались две системы с одной
## задачей и разным поведением — ровно то, что просили свести воедино (#103).
##
## ТЕПЕРЬ жители — обычная третья армия под управлением AIController: тот же планировщик,
## те же геополя, то же дробление очереди и движения, те же приказы через resolve(). Значит:
##   * житель проходит ВСЮ свою скорость за раз, как боец ИИ, а не одну клетку;
##   * в стену он не упирается — маршрут считает Дейкстра по проходимым клеткам;
##   * стреляет он через обычный _resolve_shoot, то есть с очередями, укрытиями и теми же
##     кубиками, что и все остальные.
##
## Единственное, что остаётся местным, — «оформление» для UI: события «walk» и «ap»,
## по которым Main рисует проход по клеткам и гаснущие точки ОД. Резолвер обычных
## приказов их не выдаёт: за живого игрока и за ИИ шаги рисует сам Main.
func advance_civilians(owner: int = MCF.Owner.NEUTRAL) -> ActionResult:
	var res := ActionResult.success()
	# Слот принадлежит КОНКРЕТНОМУ владельцу-нейтралу: общему слоту (§до сбора групп) или
	# слоту активационной группы (§15). Ведём только его бойцов, чужих групп не трогаем.
	var awake := 0
	var idx := _sight_index()
	for u in state.all_units():
		if u.owner != owner or not _is_civilian(u) or not u.is_alive() or u.is_held():
			continue
		_update_breached(u, idx)
		if not u.civilian_active:
			continue
		# Слот жителей может прийтись до границы раунда — свою активацию житель всегда
		# начинает с полным запасом (иначе он простоял бы весь первый слот партии).
		if u.remaining_ap <= 0 and u.move_credit <= 0:
			u.reset_ap()
		awake += 1
	if awake == 0:
		return res

	# Мозг заводится ПОД ВЛАДЕЛЬЦА слота: для группы её слот и есть owner, иначе
	# _enemies_of посчитал бы своих же за врагов. Кэш держит один мозг на слот.
	if _civ_brain == null or _civ_brain.owner != owner:
		_civ_brain = AIController.new(owner, AIController.Difficulty.NORMAL)
	# Item 23: живой, «в порядке очереди» отыгрыш вместо «телепорт + перемотка». В res
	# первым уходит событие hold — оно ПРИКАЛЫВАЕТ каждого будущего ходока к ИСХОДНОЙ
	# клетке, чтобы Main не показал их сразу в конечных позициях, пока идёт анимация.
	# Заполняем его по ходу (кто реально пошёл), а вставляем в начало в самом конце.
	var moved_from: Dictionary = {}
	var acted: Dictionary = {}
	var guard := 0
	while guard < CIVILIAN_ACTION_CAP:
		guard += 1
		var intent: Intent = _civ_brain._decide(state)
		if intent is EndTurnIntent:
			break  # ход квартала закончен; передавать его дальше — дело play_civilian_slots
		var actor := state.get_unit(intent.actor_id)
		if actor == null:
			_civ_brain.notify_intent_denied(state)
			continue
		var from := actor.coord
		var ap_before := actor.remaining_ap
		# Маршрут считаем ДО приказа: после переезда клетка старта уже свободна, а финиш
		# занят, и путь получился бы другим.
		var route := _civilian_route(actor, intent)
		var sub := resolve(intent)
		if not sub.ok:
			# Тот же расчёт выдал бы то же намерение — снимаем актёра с очереди (#60).
			_civ_brain.notify_intent_denied(state)
			continue
		acted[actor.id] = true
		# Метка «сейчас ходит вот этот» (#103). По walk/ap событиям актёра видно не всегда:
		# житель, который просто стреляет, не делает ни шага, а очередь ему бесплатна после
		# первого ОД — в потоке кубиков игрок терял, КТО именно ведёт огонь. По метке UI
		# подводит камеру к активному жителю, как к любому другому ходящему юниту (#96).
		res.dice_events.append({"kind": "focus", "unit": actor.id, "coord": from})
		if not route.is_empty():
			# Пришпиливаем ходока к ИСХОДНОЙ клетке (item 23): первое движение бойца
			# запоминает, откуда он стартовал в этом слоте, — hold-событие вернёт его туда
			# перед анимацией, чтобы не было «телепорта в конец, потом перемотки».
			if not moved_from.has(actor.id):
				moved_from[actor.id] = from
			res.dice_events.append({
				"kind": "walk", "unit": actor.id, "from": from, "path": route,
			})
		_ap_event(res, actor, ap_before)
		res.dice_events.append_array(sub.dice_events)
		res.log_lines.append_array(sub.log_lines)
		res.deaths.append_array(sub.deaths)
		# Косметика жителя — ТА ЖЕ, что у любого другого стрелка (item 5): дорожка «кто в
		# кого», трассер, гильзы, кровь. Этой строки здесь не было, и весь список fx
		# подслота молча выбрасывался: мирные стреляли в полной тишине, и по экрану нельзя
		# было понять, откуда прилетело.
		res.fx.append_array(sub.fx)
	# hold идёт ПЕРВЫМ во всём слоте (item 23): Main по нему снимает всех ходоков в их
	# стартовые клетки разом, а уже потом проигрывает шаги и выстрелы по порядку.
	if not moved_from.is_empty():
		res.dice_events.push_front({"kind": "hold", "units": moved_from})
	if not acted.is_empty():
		res.log_lines.push_front("— Civilians take their turn (%d active) —" % acted.size())
	return res

## Клетки, по которым житель пройдёт, если приказ — движение; иначе пусто. Нужно ровно
## для анимации (#96): состояние резолвер поменяет и без этого, но игрок должен видеть
## проход, а не прыжок.
func _civilian_route(actor: UnitInstance, intent: Intent) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not (intent is MoveIntent):
		return empty
	var budget: int = actor.move_credit if actor.move_credit > 0 else actor.speed()
	if budget <= 0:
		return empty
	var reach := reachable_for(actor, budget)
	var dest: Vector2i = (intent as MoveIntent).target
	if not reach.can_reach(dest):
		return empty
	return reach.path_to(dest)

## Событие «жёлтая точка погасла» (#99). Житель отыгрывает активацию сам, и без этого
## игрок видел лишь итог: точки ОД пропадали разом, ещё до первого кубика.
func _ap_event(res: ActionResult, u: UnitInstance, before: int) -> void:
	if u.remaining_ap == before:
		return
	res.dice_events.append({
		"kind": "ap", "unit": u.id, "from": before, "left": u.remaining_ap,
	})

# --- Космос / невесомость (§3.11) ---

## Пересчёт состояния шлюзов: открыт (проходим/простреливаем), если рядом (радиус 1)
## стоит любой живой юнит, кроме дрона; иначе закрыт (работает как стена).
## Функцию зовут после КАЖДОГО действия, а шлюзов на карте единицы — поэтому список
## живых юнитов берётся один раз на всю сетку, а не заново на каждый шлюз, и клетка
## достаётся без проверки границ (координаты и так свои).
## Список клеток-шлюзов, общий на все резолверы. Берётся из индекса объектов
## (_feature_cells_of) и пересобирается, только когда сменился сам список шлюзов, а не
## после каждого действия: шлюзы строят и сносят единицы раз за бой, тогда как
## update_airlocks() зовут по разу на КАЖДОЕ действие.
static var _airlock_cells: Array[GridCell] = []
static var _airlock_index: Dictionary = {}   # GridCell -> номер в _airlock_cells
static var _airlock_version: int = -1        # правка списка шлюзов в индексе объектов
static var _airlock_grid: int = 0

static func _airlocks_of(grid: Grid) -> Array[GridCell]:
	var coords := _feature_cells_of(grid, MCF.FEATURE_AIRLOCK)
	var gid := grid.get_instance_id()
	var rev: int = _feature_rev.get(MCF.FEATURE_AIRLOCK, 0)
	if _airlock_version == rev and _airlock_grid == gid:
		return _airlock_cells
	_airlock_cells = []
	_airlock_index = {}
	for c: Vector2i in coords:
		var cell := grid.cell(c)
		_airlock_index[cell] = _airlock_cells.size()
		_airlock_cells.append(cell)
	_airlock_version = rev
	_airlock_grid = gid
	return _airlock_cells

## Шлюзы, которые МОГУТ сменить состояние, — в порядке общего списка. Дверь теперь у
## каждого дома и комнаты, и на карте 250×250 их сотни; перебирать все с осмотром
## девяти клеток на каждое действие (а ход — это два вызова) стоило ~5 мс впустую:
## закрытая дверь без никого рядом закрытой и останется.
##
## Сменить состояние может только шлюз, который (а) был открыт после прошлого прохода —
## мог закрыться; (б) стоит рядом с живым бойцом — мог открыться; (в) открылся или
## закрылся с тех пор в обход этого прохода (откат, взрыв, сварка) — такое пересечение
## порога стены пишет журнал обзора GridCell.vision_changes. Тело в проёме держит
## створки открытыми, а открытыми они стали, пока тело было живым, — это случай (а).
## Если журнал оборвался, сменилась сетка или сам список шлюзов — проходим все.
var _al_open: Array[GridCell] = []
var _al_vv: int = -1
var _al_fv: int = -1
var _al_grid: int = 0
## Живые бойцы на прошлом пересчёте шлюзов: id -> клетка (см. _airlock_candidates).
var _al_pos: Dictionary = {}

func _mark_airlocks_near(c: Vector2i, marks: Dictionary) -> void:
	var grid := state.grid
	if not grid.in_bounds(c):
		return
	var r: int = MCF.AIRLOCK_OPEN_RADIUS
	for y in range(maxi(0, c.y - r), mini(grid.height - 1, c.y + r) + 1):
		for x in range(maxi(0, c.x - r), mini(grid.width - 1, c.x + r) + 1):
			var idx: Variant = _airlock_index.get(grid.cell_fast(x, y))
			if idx != null:
				marks[idx] = true

func _airlock_candidates(cells: Array[GridCell]) -> Array[GridCell]:
	var grid := state.grid
	# Где стоят живые бойцы сейчас — и сравнение с прошлым разом (batch mp-perf): створки
	# могут поменяться только у шлюзов рядом с тем, кто сдвинулся, появился или выбыл.
	# Раньше на каждый вызов перебирались девять клеток вокруг КАЖДОГО бойца карты —
	# на армиях в полтысячи это было ~7 мс на каждый шаг каждого бойца.
	var pos := {}
	for u: UnitInstance in state.units.values():
		if not u.is_drone and u.is_alive():
			pos[u.id] = u.coord
	var prev := _al_pos
	_al_pos = pos
	if _al_grid != grid.get_instance_id() or _al_fv != _airlock_version \
			or _al_vv < GridCell.vision_log_base or check_everything:
		return cells
	var marks := {}
	for c: GridCell in _al_open:
		var idx: Variant = _airlock_index.get(c)
		if idx != null:
			marks[idx] = true
	var changes := GridCell.vision_changes
	var i: int = (_al_vv - GridCell.vision_log_base) * 2
	while i < changes.size():
		var idx: Variant = _airlock_index.get(grid.cell(Vector2i(changes[i], changes[i + 1])))
		if idx != null:
			marks[idx] = true
		i += 2
	for id: int in pos:
		var was: Variant = prev.get(id)
		var now: Vector2i = pos[id]
		if was != null and was == now:
			continue
		_mark_airlocks_near(now, marks)
		if was != null:
			_mark_airlocks_near(was, marks)
	for id: int in prev:
		if not pos.has(id):
			_mark_airlocks_near(prev[id], marks)
	var order: Array = marks.keys()
	order.sort()
	var out: Array[GridCell] = []
	for k: int in order:
		out.append(cells[k])
	return out

## Створки смотрят на СВОИХ соседей, а не перебирают армию (#106). «Кто-то стоит в
## радиусе 1» — это ровно «в одной из девяти клеток вокруг есть жилец», и клеток всегда
## девять, сколько бы народу ни было на карте. Прежний перебор стоил (шлюзы × юниты)
## дистанций на КАЖДОЕ действие: при трёх десятках дверей и трёх сотнях бойцов это
## десять тысяч замеров за ход одного человека и треть всего времени резолвера.
##
## Правило то же с точностью до буквы: жилец должен быть ЖИВ (мёртвый лежит в клетке
## трупом и дверь ему не открывают) и не дроном (машина в воздухе створок не трогает).
## Сидящий в технике сюда не попадает сам собой: у него coord = OFFBOARD и клетки нет.
func update_airlocks() -> void:
	var cells := _airlocks_of(state.grid)
	if cells.is_empty():
		return
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	var radius: int = MCF.AIRLOCK_OPEN_RADIUS
	var still_open: Array[GridCell] = []
	for cell: GridCell in _airlock_candidates(cells):
		# Заваренный инженером шлюз не открывается ни для кого (#99).
		if cell.airlock_welded:
			cell.cover_height = MCF.WALL_HEIGHT
			continue
		# Тело в проёме держит створки (batch 13 #4): шлюз не закроется, пока труп не
		# вытащат. Проверяется САМА клетка шлюза — труп рядом, за порогом, дверям не мешает.
		var open := corpses_at(cell.coord) > 0
		var cx := cell.coord.x
		var cy := cell.coord.y
		var y := maxi(0, cy - radius)
		var y_end := mini(gh - 1, cy + radius)
		var x_end := mini(gw - 1, cx + radius)
		var x0 := maxi(0, cx - radius)
		while y <= y_end and not open:
			var x := x0
			while x <= x_end:
				var occ: UnitInstance = grid.cell_fast(x, y).occupant
				if occ != null and occ.is_alive() and not occ.is_drone:
					open = true
					break
				x += 1
			y += 1
		var was_closed := cell.cover_height >= MCF.WALL_HEIGHT
		cell.cover_height = 0.0 if open else MCF.WALL_HEIGHT
		# Открывшийся шлюз — повод активации соседних нейтралов (§3.1a): именно так в
		# примере из задания игрок «вскрывает комнату», подойдя к её двери.
		if open and was_closed:
			notify_cell_changed(cell.coord)
		if open:
			still_open.append(cell)
	_al_open = still_open
	_al_vv = GridCell.vision_version
	_al_fv = _airlock_version
	_al_grid = grid.get_instance_id()

## Отдача/отбрасывание после выстрела в невесомости (§3.11). Только для юнитов,
## стоящих в клетке-космосе, и только если позади свободно на всю дистанцию.
## Пассажир челнока (batch 13) пристёгнут к креслу: его не отбрасывает ни отдачей, ни
## попаданием — иначе он вылетал бы из корпуса, оставаясь «на борту» с занятым креслом.
func _apply_zero_g(shooter: UnitInstance, target: UnitInstance) -> void:
	# Стрелка отбрасывает назад (от цели).
	_recoil_shooter(shooter, target.coord)
	# Цель отбрасывает дальше (от стрелка).
	if target.is_alive() and target.aboard_vehicle_id == -1 \
			and state.grid.cell(target.coord).is_space:
		var away := _step_toward(shooter.coord, target.coord)
		_knockback(target, away, MCF.ZEROG_TARGET_KNOCKBACK)

## Отдача стрелка в невесомости: на клетку назад, прочь от точки прицела, — если позади
## свободно. Общая для всех выстрелов (batch group-zones): раньше её получали только
## винтовка и штурмовик, а заряд ПТ, струя, лазер и выстрел по окну стрелка не двигали.
func _recoil_shooter(shooter: UnitInstance, aim: Vector2i) -> void:
	if shooter.is_alive() and shooter.aboard_vehicle_id == -1 \
			and state.grid.in_bounds(shooter.coord) and state.grid.cell(shooter.coord).is_space:
		_knockback(shooter, _step_toward(aim, shooter.coord), MCF.ZEROG_SHOOTER_KNOCKBACK)

## Результат спецвыстрела с отдачей стрелка (если выстрел состоялся).
func _recoiled(result: ActionResult, shooter: UnitInstance, aim: Vector2i) -> ActionResult:
	if result.ok:
		_recoil_shooter(shooter, aim)
	return result

## Машина, корпус которой занимает клетку: по следу на сетке, а борг — по своей клетке
## (у борга с пилотом следа на сетке нет — в клетке стоит пилот). Живая или остов.
func vehicle_covering(c: Vector2i) -> Vehicle:
	var vid := state.grid.vehicle_at(c)
	if vid != -1:
		return state.get_vehicle(vid)
	for veh: Vehicle in state.all_vehicles():
		if veh.is_borg() and veh.origin == c:
			return veh
	return null

## Сдвиг юнита на dist клеток по step, но только если ВСЕ клетки свободны (иначе нет).
func _knockback(unit: UnitInstance, step: Vector2i, dist: int) -> void:
	if step == Vector2i.ZERO:
		return
	var dest := unit.coord
	for _i in dist:
		var next := dest + step
		if not state.grid.in_bounds(next) or state.grid.is_occupied_or_wall(next):
			return  # позади не свободно — отбрасывания нет
		dest = next
	state.grid.move_occupant(unit.coord, dest)

# --- Дроны (§3.12) ---
func _resolve_spawn_drone(intent: SpawnDroneIntent) -> ActionResult:
	var operator := state.get_unit(intent.actor_id)
	var err := _validate_actor(operator)
	if err != "":
		return ActionResult.fail(err)
	if operator.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return ActionResult.fail("Only an operator can launch a drone")
	var options := stations_near(operator)
	if options.is_empty():
		return ActionResult.fail("No drone station nearby")
	# Игрок называет станцию (item 17); без указания берём первую, как раньше.
	var station: Vector2i = options[0]
	if intent.station != SpawnDroneIntent.NOWHERE:
		if not options.has(intent.station):
			return ActionResult.fail("That station is not within reach")
		station = intent.station
	# Дронов у оператора может быть несколько (batch group-zones): новый поднимается и
	# тогда, когда прежний ещё в воздухе.
	# Дрон всегда поднимается прямо над своей станцией (#22); если там уже висит
	# чужой дрон — уходит на ближайшую свободную клетку.
	var drone := _launch_drone_at(station, operator)
	if drone == null:
		return ActionResult.fail("Nowhere to place the drone")
	operator.remaining_ap -= 1
	return ActionResult.success(["%s launches a drone at (%d, %d)" % [
		operator.stats.display_name, drone.coord.x, drone.coord.y]])

func _resolve_drone_move(intent: DroneMoveIntent) -> ActionResult:
	var drone := state.get_unit(intent.actor_id)
	if drone == null or not drone.is_drone or not drone.is_alive():
		return ActionResult.fail("Drone unavailable")
	if drone.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if not operator_controls(drone):
		return ActionResult.fail("Operator not at the station")
	# Спуск со стены обратно — часть ТОГО ЖЕ подлёта, а не новое действие (#99). Дрон
	# висит над стеной, он на неё не садился; раньше подъём и спуск съедали оба ОД, и
	# заглянуть за стену стоило дрону всего хода — он возвращался ровно туда, откуда
	# взлетел, без единой клетки полёта в запасе.
	var descending := state.grid.cell(drone.coord).is_wall() \
			and intent.target == drone.wall_entry_from
	# Недолётанный остаток прошлого подлёта тратится ПЕРВЫМ и нового ОД не стоит (#13).
	var use_credit := drone.move_credit > 0
	var budget: int = drone.move_credit if use_credit else MCF.DRONE_FLIGHT_RANGE
	if drone.remaining_ap <= 0 and not descending and not use_credit:
		return ActionResult.fail("Drone has no AP left")

	var reach := _drone_reach(drone)
	# Свободная клетка в пределах полёта.
	if reach.has(intent.target):
		if not descending and not use_credit:
			drone.remaining_ap -= 1
		# Остаток дальности сохраняется до конца хода — им дрон долетит потом (#13).
		drone.move_credit = maxi(0, budget - int(reach[intent.target]))
		if state.grid.cell(intent.target).on_fire:
			# Залетел в огонь — взрыв (§3.8/§3.12).
			return _drone_explode(drone, intent.target, "flew into fire")
		# Заход на стену запоминаем ДО переезда (#96): уйти с неё можно только назад.
		var entry := Vector2i(-1, -1)
		# Над стеной у дрона один ход — назад (#96), но остаток подлёта он НЕ теряет
		# (batch borg-corpses): раньше и заход на стену, и спуск обнуляли его, и дрон,
		# заглянув за стену, оставался без полёта до конца хода. Спуск тратит из остатка
		# одну клетку; спуск без остатка бесплатен, но и нового запаса не даёт.
		if descending and not use_credit:
			drone.move_credit = 0
		if state.grid.cell(intent.target).is_wall():
			entry = _drone_entry_cell(drone, intent.target, reach)
		# Маршрут снимаем ДО переезда (item 12): восстанавливается он от СТАРОЙ клетки.
		var route := _drone_route(drone.coord, intent.target)
		var flew_from := drone.coord
		# Дрон не занимает слот клетки — просто переносим его координату (#13).
		drone.coord = intent.target
		drone.wall_entry_from = entry
		# Строку лога ставим ветвлением, а не тернарником в аргументе: success() принимает
		# ТИПИЗИРОВАННЫЙ Array[String], а тернарник отдаёт нетипизированный литерал, и
		# на таком вызове движок уходит в себя намертво. Развилка и читается лучше.
		var flight := ActionResult.new()
		flight.ok = true
		if entry != Vector2i(-1, -1):
			flight.log("Drone hovers over the wall at (%d, %d) [AP: %d]" % [
				intent.target.x, intent.target.y, drone.remaining_ap])
		else:
			flight.log("Drone flies to (%d, %d) [AP: %d]" % [
				intent.target.x, intent.target.y, drone.remaining_ap])
		# Полёт отыгрывается по клеткам тем же событием, что и пеший переход (item 12):
		# тридцать клеток за один подлёт иначе выглядели телепортом, и в чужой ход было
		# не понять, откуда дрон взялся над твоим отрядом.
		if not route.is_empty():
			flight.dice_events.append({
				"kind": "walk", "unit": drone.id, "from": flew_from, "path": route,
			})
		return flight
	# Столкновение: цель занята/стена — дрон таранит и взрывается (§3.12).
	var pre := _approach_cell(drone, intent.target, reach)
	if pre != Vector2i(-1, -1):
		if drone.remaining_ap <= 0 and not use_credit:
			return ActionResult.fail("Drone has no AP left")
		if not use_credit:
			drone.remaining_ap -= 1
		drone.move_credit = 0  # таран — конец подлёта в любом случае
		var ram_from := drone.coord
		var ram_route := _drone_route(drone.coord, pre)
		if pre != drone.coord:
			drone.coord = pre
		var boom := _drone_explode(drone, intent.target, "crashed into an obstacle")
		# Разгон перед тараном виден так же, как обычный полёт (item 12): взрыв на
		# ровном месте читается куда хуже, чем взрыв в конце разбега.
		if not ram_route.is_empty():
			boom.dice_events.push_front({
				"kind": "walk", "unit": drone.id, "from": ram_from, "path": ram_route,
			})
		return boom
	return ActionResult.fail("Target out of the drone's reach")

func _resolve_drone_detonate(intent: DroneDetonateIntent) -> ActionResult:
	var drone := state.get_unit(intent.actor_id)
	if drone == null or not drone.is_drone or not drone.is_alive():
		return ActionResult.fail("Drone unavailable")
	if drone.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	if not operator_controls(drone):
		return ActionResult.fail("Operator not at the station")
	_aimed_component = intent.component
	# Дрон рвётся НАД корпусом (§4): борта у такого удара нет, и выбор игрока ничем
	# не ограничен — ни гусеницей с той стороны, ни направлением ствола.
	_aim_from = NOWHERE
	return _drone_explode(drone, drone.coord, "detonated")

## Взрыв дрона: снимаем его с поля (не оставляет труп) и детонируем как противотанкист.
## Дрон не занимает слот клетки (#13), так что снимать occupant не нужно.
func _drone_explode(drone: UnitInstance, center: Vector2i, why: String,
		radius: int = MCF.ANTI_TANK_BLAST_RADIUS) -> ActionResult:
	drone.status = MCF.Status.CORPSE
	drone.remaining_ap = 0
	var result := ActionResult.new()
	result.ok = true
	result.log("Drone %s — explosion at (%d, %d)" % [why, center.x, center.y])
	# Дрон, влетевший прямо в ДОТ, весь свой заряд оставляет в бетоне.
	_blast_armor_wall(center, result)
	if _pillbox_absorbs(center, MCF.DRONE_EXPLOSION_DAMAGE, result):
		return result
	var area := MCF.blast_square(center, radius)
	var killed := _blast(center, result, area)
	# Дрон, подорвавшийся над техникой, снимает с неё 1 прочность (item 14): раньше
	# взрыв дрона выкашивал пехоту вокруг машины, а сам корпус не трогал вовсе.
	# Подрыв дрона узел НЕ разыгрывает (§4): игрок указал — туда и пришлось.
	_damage_vehicles_in_area(area, center, MCF.DRONE_EXPLOSION_DAMAGE, -1, result, "drone",
		_aimed_component, false)
	if killed.is_empty():
		result.log("… nobody destroyed")
	else:
		for n in killed:
			result.log("%s destroyed!" % n)
	return result

## Поднять дрон над станцией. Общая часть для ручного запуска и авто-запуска при
## развёртывании станции (#77). Возвращает дрон или null, если поднимать некуда/незачем.
## `pilot` — кто разворачивал станцию; управлять дроном всё равно сможет только
## оператор, стоящий вплотную к станции (см. operator_controls).
func _launch_drone_at(station: Vector2i, pilot: UnitInstance) -> UnitInstance:
	var op := pilot
	# Пультом владеет оператор: если станцию ставил не он, ищем своего оператора рядом.
	if op == null or op.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		for u in state.all_units():
			if u.is_alive() and not u.is_drone and u.owner == pilot.owner \
					and u.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR \
					and Combat.distance(u.coord, station) == 1:
				op = u
				break
	if op == null:
		return null
	var spawn_cell := station
	if _drone_at(station) != null:
		spawn_cell = _free_flight_cell_near(station)
	if spawn_cell == Vector2i(-1, -1):
		return null
	var drone_stats: UnitStats = load("res://src/data/units/drone.tres")
	# Дрон висит НАД клеткой и её не занимает (#103) — под ним свободно проходят.
	var drone := state.spawn_unit(drone_stats, spawn_cell, op.owner, false)
	drone.is_drone = true
	drone.home_station = station
	drone.operator_id = op.id
	return drone

## Клетка со станцией дронов, стоящей рядом с оператором (или (-1,-1)).
func station_near(operator: UnitInstance) -> Vector2i:
	var all := stations_near(operator)
	return all[0] if not all.is_empty() else Vector2i(-1, -1)

## ВСЕ свои станции вплотную к оператору (item 17). Их может быть несколько, и с
## какой поднимать дрон — решает игрок, а не порядок обхода соседей.
##
## НЕ оператор — пустой список. Проверка стоит ЗДЕСЬ, а не у звавших: её делали все четыре
## вызова (обе кнопки в Main, _resolve_spawn_drone и пеший перечислитель) и ровно один —
## пассажир челнока в LegalIntents — забыл. Политика RL честно выбирала «поднять дрон»
## тяжёлым пехотинцем из кресла, резолвер отвечал «Only an operator can launch a drone», и
## так до конца хода: жадная оценка переспрашивает один и тот же отказ, пока среда не
## оборвёт ход на восьмом (отсюда отказы кратные восьми в eval_games.jsonl у tactical-2).
func stations_near(operator: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if operator == null or operator.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return out
	for n in state.grid.neighbors(operator.coord):
		var cell := state.grid.cell(n)
		if cell.feature_id == MCF.FEATURE_DRONE_STATION and cell.feature_owner == operator.owner:
			out.append(n)
	return out

## Где стоит станция, развёрнутая ИМЕННО ЭТИМ оператором (item 16); (-1,-1) — нет такой.
## Оператор помечает свою станцию при установке, поэтому «одна станция на оператора»
## считается по метке, а не по владельцу-стороне: у команды их может быть много.
func deployed_station_of(operator: UnitInstance) -> Vector2i:
	if operator == null:
		return Vector2i(-1, -1)
	return _station_index().get(operator.id, Vector2i(-1, -1))

## «Оператор -> его станция» — по станциям из индекса объектов (_feature_cells), без
## прохода по карте: operator_has_station() зовёт _draw() на КАЖДОГО юнита каждый кадр,
## а ИИ — на каждом решении, из нового резолвера.
##
## Источник правды — метка на самой клетке, а не поле у оператора. Станцию может
## снести взрывом, и тогда она исчезает вместе с меткой сама; поле у оператора
## пришлось бы чистить из каждого места, где рушится рельеф.
func _station_index() -> Dictionary:
	var out := {}
	for c: Vector2i in _feature_cells(MCF.FEATURE_DRONE_STATION):
		var op := state.grid.cell(c).station_operator_id
		if op != -1:
			out[op] = c
	return out

## Оператор развернул станцию — над ним «!» (batch 17, item 8). Раньше знак висел,
## пока станции НЕ было; по просьбе игрока он теперь означает обратное: станция стоит,
## дрон можно поднять.
func operator_has_station(u: UnitInstance) -> bool:
	if u == null or not u.is_alive() \
			or u.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return false
	return deployed_station_of(u) != Vector2i(-1, -1)

## Единый признак «не хватает обязательного снаряжения» (item 18): по нему рисуется общий
## восклицательный знак над юнитом. Сводит вместе четыре случая — инженер истратил свою ЛДФ,
## оператор дронов С развёрнутой станцией (item 8), огнемётчик без огнетушащей гранаты и пулемётчик
## без фраг-гранаты. Последние два опознаём по стартовому предмету стороны (default_item_id):
## юнит родился с ним, а сейчас в руках его нет.
func unit_missing_equipment(u: UnitInstance) -> bool:
	if u == null or not u.is_alive():
		return false
	if u.ldf_wall_used or operator_has_station(u):
		return true
	var need: String = u.stats.default_item_id
	if need == MCF.ITEM_EXTINGUISHER or need == MCF.ITEM_FRAG:
		return u.held_item_id != need
	return false

## "" = станцию можно свернуть обратно в предмет (item 16); иначе причина отказа.
func can_pick_up_station(operator: UnitInstance, coord: Vector2i) -> String:
	if operator == null or not operator.is_alive():
		return "Unit unavailable"
	if operator.remaining_ap <= 0:
		return "Unit has no AP left"
	if operator.held_item_id != "":
		return "Hands are full"
	if not state.grid.in_bounds(coord):
		return "Out of bounds"
	if Combat.distance(operator.coord, coord) != 1:
		return "The station must be right next to you"
	var cell := state.grid.cell(coord)
	if cell.feature_id != MCF.FEATURE_DRONE_STATION:
		return "No station there"
	if cell.station_operator_id != operator.id:
		return "That station is not yours"
	if active_drone_of(operator) != null:
		return "Land the drone first"
	return ""

## Свои станции рядом, которые можно свернуть прямо сейчас — для подсветки в UI.
func station_pickup_cells(operator: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if operator == null:
		return out
	for n in state.grid.neighbors(operator.coord):
		if can_pick_up_station(operator, n) == "":
			out.append(n)
	return out

func _resolve_pickup_station(intent: PickUpStationIntent) -> ActionResult:
	var operator := state.get_unit(intent.actor_id)
	var err := _validate_actor(operator)
	if err != "":
		return ActionResult.fail(err)
	var reason := can_pick_up_station(operator, intent.coord)
	if reason != "":
		return ActionResult.fail(reason)
	var cell := state.grid.cell(intent.coord)
	cell.station_operator_id = -1
	cell.clear_feature()
	# Станция стояла в кресле челнока (batch 13 S8) — кресло снова свободно.
	var svid := state.grid.vehicle_at(intent.coord)
	if svid != -1:
		var sveh := state.get_vehicle(svid)
		if _seated(sveh):
			for i in sveh.seats.size():
				if sveh.seat_cell(i) == intent.coord and sveh.seats[i] == Vehicle.SEAT_STATION:
					sveh.seats[i] = -1
	operator.remaining_ap -= 1
	operator.held_item_id = MCF.ITEM_DRONE_STATION
	return ActionResult.success(["%s folds the drone station at (%d, %d) back up [AP: %d]" % [
		operator.stats.display_name, intent.coord.x, intent.coord.y, operator.remaining_ap]])

## Живой дрон этого оператора (или null).
func active_drone_of(operator: UnitInstance) -> UnitInstance:
	for u in state.all_units():
		if u.is_drone and u.is_alive() and u.operator_id == operator.id:
			return u
	return null

## Оператор жив и стоит вплотную к своей станции — только тогда управляет дроном (§3.12).
func operator_controls(drone: UnitInstance) -> bool:
	var op := state.get_unit(drone.operator_id)
	if op == null or not op.is_alive():
		return false
	if state.grid.cell(drone.home_station).feature_id != MCF.FEATURE_DRONE_STATION:
		return false
	return Combat.distance(op.coord, drone.home_station) == 1

func _free_cell_near(coord: Vector2i) -> Vector2i:
	for n in state.grid.neighbors(coord):
		if state.grid.cell(n).is_empty():
			return n
	return Vector2i(-1, -1)

## Живой дрон, висящий над клеткой (или null). Дроны не хранятся в occupant (#13),
## поэтому ищем по координате.
func _drone_at(coord: Vector2i) -> UnitInstance:
	for u in state.all_units():
		if u.is_drone and u.is_alive() and u.coord == coord:
			return u
	return null

## Куда можно поставить дрон рядом: в поле, не стена, без корпуса машины и другого
## дрона. Наземный жилец (труп/юнит) не мешает — дрон висит сверху (#13).
func _free_flight_cell_near(coord: Vector2i) -> Vector2i:
	for n in state.grid.neighbors(coord):
		var c := state.grid.cell(n)
		if not c.is_wall() and c.vehicle_id == -1 and _drone_at(n) == null:
			return n
	return Vector2i(-1, -1)

const DRONE_DIRS_8 := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## Клетка → откуда в неё прилетели по кратчайшему маршруту. Заполняет _drone_reach,
## читает _drone_route (item 12): по ней восстанавливается ПУТЬ, а не только цена.
## Живёт ровно до следующего запроса разлёта — это черновик одного расчёта, не состояние.
var _drone_prev: Dictionary = {}

## Маршрут дрона от его клетки до target, БЕЗ старта и включая финиш (item 12).
##
## Дрон до сих пор просто телепортировался: пехота свой переход отыгрывает по клеткам
## (событие «walk»), а полёт на тридцать клеток случался мгновенно, и в чужой ход
## игрок видел лишь «дрон был там, стал тут». Событие то же самое, что у пехоты, —
## значит и рисуется тем же кодом.
##
## Пустой массив — маршрут не восстанавливается (цель не из последнего разлёта).
## Шаги ограничены размером карты: испорченная цепочка предшественников не должна
## закручивать резолвер в вечный цикл.
func _drone_route(from_coord: Vector2i, target: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if target == from_coord:
		return out
	var cur := target
	var guard: int = state.grid.width * state.grid.height + 2
	while cur != from_coord and guard > 0:
		out.push_front(cur)
		if not _drone_prev.has(cur):
			return [] as Array[Vector2i]
		cur = _drone_prev[cur]
		guard -= 1
	return out if cur == from_coord else [] as Array[Vector2i]

## Клетки, куда дрон может долететь СВОБОДНЫМ МАРШРУТОМ (§3.12, ответ игрока «Free path,
## diag=2»): Дейкстра по 8 направлениям, ортогональный шаг = 1, диагональный = 2, бюджет
## полёта = DRONE_FLIGHT_RANGE, привязь к станции ≤ DRONE_LEASH (item 13). Корпус машины и
## чужой дрон непроходимы; горящая клетка — терминал (влететь можно, пролететь сквозь — нет).
##
## Стена — тоже терминал (#96): над ней дрон ЗАВИСАЕТ, но не пролетает. Так делается
## подрыв вплотную к стене — дрон садится сверху и детонирует, снося её. Обратно со стены
## есть ровно один путь, тем же курсом (см. wall_entry_from), иначе дрон переползал бы
## стену по клеткам и оказывался на другой стороне — а сквозь стены он не летает.
## Возвращает { клетка : стоимость пути }.
## Куда дрон может долететь ПРЯМО СЕЙЧАС. Бюджет — недолётанный остаток прошлого
## подлёта, если он есть (#13): дрон доканчивает начатое движение так же, как пехота
## доходит остаток своего (#44), и второго действия за это не платит.
##
## Привязь к станции считается ОТДЕЛЬНО и всегда по полному радиусу связи (DRONE_LEASH):
## она не «запас хода», а расстояние, на котором станция ещё держит дрон, и укоротить
## её остатком бюджета было бы неверно.
func _drone_reach(drone: UnitInstance) -> Dictionary:
	var budget: int = drone.move_credit if drone.move_credit > 0 else MCF.DRONE_FLIGHT_RANGE
	if state.grid.cell(drone.coord).is_wall():
		return _drone_wall_exit(drone)
	var dist := {drone.coord: 0}
	var out: Dictionary = {}
	var visited: Dictionary = {}
	var frontier: Array = [drone.coord]
	_drone_prev = {}
	# Дроны по клеткам — один проход вместо _drone_at() на каждого соседа каждой клетки:
	# тот перебирал всех юнитов карты, и на карте дронов поиск стоил ~60 мс. Первый
	# встреченный дрон на клетке — ровно тот, кого вернул бы _drone_at().
	var drones_at := {}
	for u in state.all_units():
		if u.is_drone and u.is_alive() and not drones_at.has(u.coord):
			drones_at[u.coord] = u
	while not frontier.is_empty():
		var best_i := 0
		for i in range(1, frontier.size()):
			if int(dist[frontier[i]]) < int(dist[frontier[best_i]]):
				best_i = i
		var cur: Vector2i = frontier[best_i]
		frontier.remove_at(best_i)
		if visited.has(cur):
			continue
		visited[cur] = true
		if cur != drone.coord:
			out[cur] = int(dist[cur])
			if state.grid.cell(cur).on_fire or state.grid.cell(cur).is_wall():
				continue  # огонь и стена — дальше не летим
		for dir: Vector2i in DRONE_DIRS_8:
			var nxt: Vector2i = cur + dir
			if not state.grid.in_bounds(nxt):
				continue
			var step_cost: int = 2 if (dir.x != 0 and dir.y != 0) else 1
			var nd: int = int(dist[cur]) + step_cost
			if nd > budget:
				continue
			if Combat.distance(nxt, drone.home_station) > MCF.DRONE_LEASH:
				continue
			var cell := state.grid.cell(nxt)
			# Дрон перелетает трупы, юнитов и технику и зависает над ними (#13; над
			# корпусом машины — batch borg-corpses): мешает лишь другой дрон.
			var od: UnitInstance = drones_at.get(nxt)
			if od != null and od != drone:
				continue
			if not dist.has(nxt) or nd < int(dist[nxt]):
				dist[nxt] = nd
				_drone_prev[nxt] = cur  # item 12: по этой цепочке строится маршрут полёта
				frontier.append(nxt)
	return out

## Единственный ход дрона, зависшего над стеной (#96): вернуться туда, откуда он зашёл.
## Пустой словарь — путь назад заняли (корпус машины, чужой дрон) или он не записан;
## тогда со стены дрону остаётся только подрыв.
func _drone_wall_exit(drone: UnitInstance) -> Dictionary:
	var back := drone.wall_entry_from
	if back == Vector2i(-1, -1) or not state.grid.in_bounds(back) or back == drone.coord:
		return {}
	if Combat.distance(back, drone.home_station) > MCF.DRONE_LEASH:
		return {}
	var od := _drone_at(back)
	if od != null and od != drone:
		return {}
	_drone_prev = {back: drone.coord}  # спуск — тоже маршрут, пусть и в один шаг (item 12)
	return {back: 1}

func drone_flight_cells(drone: UnitInstance) -> Array:
	return _drone_reach(drone).keys()

## Клетки полёта с ценой (клетка -> сколько клеток подлёта уйдёт) — для зон хода на экране.
func drone_flight_costs(drone: UnitInstance) -> Dictionary:
	return _drone_reach(drone)

## Потолок одного подлёта: остаток прошлого или полный подлёт за ОД.
func drone_flight_budget(drone: UnitInstance) -> int:
	return drone.move_credit if drone.move_credit > 0 else MCF.DRONE_FLIGHT_RANGE

## С какой клетки дрон зашёл на стену (#96) — туда же он потом и вернётся. Берём
## предшественника на кратчайшем маршруте, ничьи разрешаем по координатам: иначе хост
## и клиент записали бы РАЗНЫЕ пути отхода. (-1,-1) — зайти на стену неоткуда.
func _drone_entry_cell(drone: UnitInstance, target: Vector2i, reach: Dictionary) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_key: Array = [1 << 30, 0, 0]
	for dir: Vector2i in DRONE_DIRS_8:
		var n: Vector2i = target + dir
		if not state.grid.in_bounds(n) or state.grid.cell(n).is_wall():
			continue
		var cost := 0
		if n != drone.coord:
			if not reach.has(n):
				continue
			cost = int(reach[n])
		var key: Array = [cost, n.y, n.x]
		if key < best_key:
			best_key = key
			best = n
	return best

## Клетка, из которой дрон таранит занятую цель (или (-1,-1)).
func _approach_cell(drone: UnitInstance, target: Vector2i, reach: Dictionary) -> Vector2i:
	if not state.grid.in_bounds(target):
		return Vector2i(-1, -1)
	# Таран — только по другому дрону (#13): юнитов, трупы и технику дрон облетает и
	# зависает над ними (над машиной — batch borg-corpses; бить её — подрывом сверху), а
	# над стеной ЗАВИСАЕТ (#96).
	var other_drone := _drone_at(target)
	var blocked: bool = other_drone != null and other_drone != drone
	if not blocked:
		return Vector2i(-1, -1)
	# Дрон таранит из любой соседней клетки, куда может долететь (8 направлений).
	for dir: Vector2i in DRONE_DIRS_8:
		var n: Vector2i = target + dir
		if n == drone.coord or reach.has(n):
			return n
	return Vector2i(-1, -1)

# --- Захват (§3.4) ---
func _resolve_capture(intent: CaptureIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	var target := state.get_unit(intent.target_id)
	if target == null or not target.is_alive():
		return ActionResult.fail("No target to capture")
	# Пассажира челнока из кресла не выдернешь (batch 13): он под бортом, а не на полу.
	if target.aboard_vehicle_id != -1:
		return ActionResult.fail("Can't grab someone inside a shuttle")
	if target.id == actor.id:
		return ActionResult.fail("Can't grab yourself")
	if target.captor_id != -1:
		return ActionResult.fail("Target is already held")
	# Одного бойца хватают не чаще раза за раунд (#100): иначе цепочка носильщиков
	# перекидывала бы пленника через полкарты за один ход.
	if target.carried_this_round:
		return ActionResult.fail("Target was already grabbed this round")
	if Combat.distance(actor.coord, target.coord) != 1:
		return ActionResult.fail("Target not in an adjacent cell")

	# Своего бойца берут без сопротивления (§3.4): он не отбивается.
	if target.owner == actor.owner:
		actor.remaining_ap -= 1
		target.status = MCF.Status.HELD
		target.captor_id = actor.id
		target.carried_this_round = true
		# ОД пленника НЕ сгорают (#76): пока его тащат, он ничего не тратит — действовать
		# ему всё равно не даёт сам захват (см. _validate_actor), а вырвавшись, он
		# доигрывает свой ход как обычно.
		target.action_state = null
		_grant_carry_move(actor)
		var ally_res := ActionResult.new()
		ally_res.ok = true
		ally_res.log("%s picked up %s." % [actor.stats.display_name, target.stats.display_name])
		return ally_res

	actor.remaining_ap -= 1  # попытка захвата стоит 1 ОД в любом исходе
	var a_roll := state.dice.roll_d6()
	var d_roll := state.dice.roll_d6()
	while a_roll == d_roll:  # ничья — переброс (§3.4)
		a_roll = state.dice.roll_d6()
		d_roll = state.dice.roll_d6()
	var success := a_roll > d_roll
	if success:
		target.status = MCF.Status.HELD
		target.captor_id = actor.id
		target.carried_this_round = true  # второй раз за раунд его уже не схватят (#100)
		target.action_state = null  # ОД пленника не сгорают (#76)
		_grant_carry_move(actor)

	var result := ActionResult.new()
	result.ok = true
	result.dice_events.append({
		"kind": "opposed", "attacker": actor.stats.display_name,
		"defender": target.stats.display_name, "a_roll": a_roll, "d_roll": d_roll,
		"attacker_wins": success, "def_owner": target.owner,
	})
	if success:
		result.log("%s captured %s!" % [actor.stats.display_name, target.stats.display_name])
	else:
		result.log("%s failed to capture %s (%d vs %d)" % [
			actor.stats.display_name, target.stats.display_name, a_roll, d_roll])
	return result

# --- Освобождение из захвата (§3.4): 4+ ---
func _resolve_release(intent: ReleaseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	if unit == null or not unit.is_held():
		return ActionResult.fail("Unit is not being held")
	if unit.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")

	# Своего держит союзник (#37): освобождение без броска и БЕСПЛАТНО — просто встаёт,
	# поэтому проверка ОД идёт ПОСЛЕ этой ветки.
	var captor := state.get_unit(unit.captor_id)
	if captor != null and captor.owner == unit.owner:
		unit.status = MCF.Status.ALIVE
		unit.captor_id = -1
		var ally_res := ActionResult.new()
		ally_res.ok = true
		ally_res.log("%s steps out of the friendly hold." % unit.stats.display_name)
		return ally_res

	if unit.remaining_ap <= 0:
		return ActionResult.fail("No AP left")
	unit.remaining_ap -= 1
	var roll := state.dice.roll_d6()
	var freed := roll >= 4
	if freed:
		unit.status = MCF.Status.ALIVE
		unit.captor_id = -1

	var result := ActionResult.new()
	result.ok = true
	result.dice_events.append({
		"kind": "check", "actor": unit.stats.display_name, "roll": roll, "need": 4, "ok": freed,
	})
	if freed:
		result.log("%s broke free from the grab (roll %d)!" % [unit.stats.display_name, roll])
	else:
		result.log("%s failed to break free (roll %d, need 4+)" % [unit.stats.display_name, roll])
	return result

# --- Перекладывание пленника (#100): бесплатно, на любую соседнюю с носильщиком клетку ---
## Носильщик не сходит с места и ничего не тратит — он лишь переставляет тело вокруг
## себя (закрыть собой проём, освободить линию огня, подставить пленника под удар).
func _resolve_move_held(intent: MoveHeldIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	if actor == null or not actor.is_alive():
		return ActionResult.fail("Unit not found")
	if actor.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	var carried := held_unit_of(actor)
	if carried == null:
		return ActionResult.fail("Unit is not holding anyone")
	if not _valid_carry_drop(intent.to, actor.coord):
		return ActionResult.fail("Cell is occupied or not adjacent to the carrier")
	state.grid.move_occupant(carried.coord, intent.to)
	update_airlocks()
	var res := ActionResult.new()
	res.ok = true
	res.log("%s shifts %s → (%d, %d)" % [
		actor.stats.display_name, carried.stats.display_name, intent.to.x, intent.to.y])
	# Переставленный на горящую клетку пленник сгорает — как и любой, кто туда попал.
	if state.grid.cell(intent.to).on_fire and not is_fireproof(carried):
		_kill(carried)
		res.log("%s burned to death!" % carried.stats.display_name)
		res.deaths.append(carried.id)
	return res

## Захват включает в себя перемещение (#25): сразу после удачного граба носитель
## получает кредит движения на «скорость − 3» клеток, чтобы утащить пленника тем же
## действием, не тратя второй ОД.
## Кредит именно ЗАДАЁТСЯ, а не берётся максимумом: иначе накопленный до граба остаток
## полной скорости пережил бы захват и пленника таскали бы без штрафа (#33).
func _grant_carry_move(actor: UnitInstance) -> void:
	actor.move_credit = maxi(0, actor.speed() - MCF.CAPTURE_CARRY_PENALTY)

## Юнит, которого удерживает captor (status HELD, captor_id == captor.id), или null (§3.4).
func held_unit_of(captor: UnitInstance) -> UnitInstance:
	if captor == null:
		return null
	for u in state.all_units():
		if u.is_held() and u.captor_id == captor.id:
			return u
	return null

## Пленника кладут в свободную клетку рядом с целью переноса (§3.4).
func _valid_carry_drop(drop: Vector2i, dest: Vector2i) -> bool:
	if drop == Vector2i(-999, -999) or not state.grid.in_bounds(drop):
		return false
	if drop == dest or Combat.distance(drop, dest) != 1:
		return false
	return not state.grid.blocks_walk(drop)

## Свободные соседние с целью клетки, куда можно положить пленника (для UI).
func carry_drop_cells(dest: Vector2i) -> Array:
	var out: Array = []
	for n in state.grid.neighbors(dest):
		if not state.grid.blocks_walk(n):
			out.append(n)
	return out

# --- Перетаскивание трупов и лёгких объектов (§3.4): без броска, БЕЗ ОД, без лимита ---
# Тащить можно труп, мешки с песком, ежа, кучу земли (≤1 м) на соседнюю клетку.
const DRAGGABLE_FEATURES := [
	MCF.FEATURE_SANDBAGS, MCF.FEATURE_HEDGEHOG, MCF.FEATURE_DIRT_PILE,
]

func _resolve_drag(intent: DragIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	var src: Vector2i = intent.object_coord
	var dst: Vector2i = intent.dest_coord
	if not state.grid.in_bounds(src) or not state.grid.in_bounds(dst):
		return ActionResult.fail("Cell out of bounds")
	if Combat.distance(actor.coord, src) != 1:
		return ActionResult.fail("Object not in an adjacent cell")
	if Combat.distance(actor.coord, dst) != 1:
		return ActionResult.fail("Can only drag to an adjacent cell")
	var src_cell := state.grid.cell(src)
	var dst_cell := state.grid.cell(dst)

	# Труп (occupant со статусом CORPSE).
	var corpse := src_cell.occupant
	if corpse != null and corpse.status == MCF.Status.CORPSE:
		# Складирование в кучу: на целевой клетке уже лежат тела (§3.7). Считаем их
		# через corpses_at (#98) — куча и труп-occupant складываются в один стек.
		if corpses_at(dst) > 0:
			if corpses_at(dst) >= MCF.CORPSE_WALL_COUNT:
				return ActionResult.fail("No room for another body here")
			# Перетаскиваемый труп уходит в кучу — убираем его из игры.
			src_cell.occupant = null
			state.units.erase(corpse.id)
			if _add_corpse_to_cell(dst):
				return ActionResult.success(["%s formed a corpse wall at (%d, %d) [AP: %d]" % [
					actor.stats.display_name, dst.x, dst.y, actor.remaining_ap]])
			return ActionResult.success(["%s piled a corpse (%d/%d) at (%d, %d) [AP: %d]" % [
				actor.stats.display_name, corpses_at(dst), MCF.CORPSE_WALL_COUNT,
				dst.x, dst.y, actor.remaining_ap]])
		if not dst_cell.is_empty():
			return ActionResult.fail("Target cell is occupied")
		state.grid.move_occupant(src, dst)
		# Постройка на горящей клетке/перенос груза на неё тушит пламя (#82).
		_extinguish_cell(dst_cell)
		return ActionResult.success(["%s dragged a corpse → (%d, %d) [AP: %d]" % [
			actor.stats.display_name, dst.x, dst.y, actor.remaining_ap]])

	# Лёгкий объект (мешки/ёж/куча земли) — тащить может любой юнит (#30).
	if DRAGGABLE_FEATURES.has(src_cell.feature_id):
		var fid := src_cell.feature_id
		var fowner := src_cell.feature_owner
		var dirt := src_cell.dirt_level
		# Мешки на мешки и ёж на мешки складываются в стену 2 м (#31).
		var stacked := stack_onto(dst_cell, fid)
		if not dst_cell.is_buildable() and stacked == "":
			return ActionResult.fail("Target cell is occupied")
		var placed: String = stacked if stacked != "" else fid
		src_cell.clear_feature()
		dst_cell.set_feature(placed, fowner)
		if placed == MCF.FEATURE_DIRT_PILE:
			# Куча переезжает целиком, вместе с набранной высотой.
			dst_cell.dirt_level = dirt
			dst_cell.cover_height = MCF.DIRT_HEIGHT_PER_LEVEL * float(dirt)
		# Объект, поставленный на горящую клетку, сбивает пламя (#82).
		_extinguish_cell(dst_cell)
		# Объект остаётся в руках: тащить его дальше можно движением, но с тем же
		# штрафом −3 клетки, что и при переносе пленника (#34). Стопка — уже не груз.
		if stacked == "":
			actor.dragging = dst
			_grant_carry_move(actor)
		return ActionResult.success(["%s dragged \"%s\" → (%d, %d) [AP: %d]" % [
			actor.stats.display_name, MCF.FEATURE_NAMES.get(placed, placed),
			dst.x, dst.y, actor.remaining_ap]])

	return ActionResult.fail("Nothing here to drag")

## Соседние клетки с перетаскиваемым объектом (труп/мешки/ёж/куча земли) — для UI.
## Трупов здесь БОЛЬШЕ НЕТ (#7): в режиме «рука» тело теперь ПОДНИМАЮТ, а не волокут
## по земле — см. corpse_pickup_cells(). Само намерение DragIntent труп по-прежнему
## переносит (сеть и старые записи остаются валидными), просто UI его не предлагает.
func draggable_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	for n in state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(n)
		if DRAGGABLE_FEATURES.has(cell.feature_id):
			out.append(n)
	return out

## Клетки с телом, которое боец может взять В РУКИ из режима «рука» (#7): своя и восемь
## соседних. Пусто, если руки уже полны (#9) или нет ОД — подсветка обязана совпадать
## с тем, что примет _resolve_pickup_corpse, иначе клик «не работает».
func corpse_pickup_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null or actor.remaining_ap <= 0 \
			or actor.carried_corpses >= MCF.CORPSE_CARRY_MAX or actor.borg_id != -1 \
			or _is_shield(actor):  # щитоносец трупы не носит (item 17), борг тоже
		return out
	# Тело под стоящей машиной не достать (batch 12 #2): оно лежит там, но под днищем. Своя
	# клетка — не исключение: резолвер проверяет любую, и без этой проверки перечислитель
	# RL предлагал подъём, который тут же отклонялся («The body is under a vehicle»).
	for n in [actor.coord] + state.grid.neighbors(actor.coord):
		if has_corpse(n) and state.grid.vehicle_at(n) == -1:
			out.append(n)
	return out

## Соседние клетки, куда можно поставить перетаскиваемый объект (object_coord) — для UI.
## Труп можно ещё и складировать в кучу к другому трупу (§3.7).
func drag_dest_cells(actor: UnitInstance, object_coord: Vector2i) -> Array:
	var src := state.grid.cell(object_coord)
	var is_corpse := src != null and src.occupant != null and src.occupant.status == MCF.Status.CORPSE
	var out: Array = []
	for n in state.grid.neighbors(actor.coord):
		if n == object_coord:
			continue
		var cell := state.grid.cell(n)
		if cell.is_empty() and not cell.has_feature():
			out.append(n)
		elif is_corpse and cell.occupant != null and cell.occupant.status == MCF.Status.CORPSE:
			out.append(n)
		elif not is_corpse and src != null and stack_onto(cell, src.feature_id) != "":
			out.append(n)
	return out

# --- ДПМГ: стационарный пулемёт (§3.7) ---
# Стреляет любой юнит из соседней клетки за 1 действие; вражеский ДПМГ можно отобрать.

## Соседние клетки актора с ДПМГ (для UI). owned=true — свои (стрелять), false — чужие (отобрать).
func rsp_cells(actor: UnitInstance, owned: bool) -> Array:
	var out: Array = []
	for n in state.grid.neighbors(actor.coord):
		var cell := state.grid.cell(n)
		if cell.feature_id != MCF.FEATURE_DPMG:
			continue
		if (cell.feature_owner == actor.owner) == owned:
			out.append(n)
	return out

## Цели, по которым ДПМГ с клетки dpmg_coord может стрелять (дальность 12, ЛОС) — для UI.
func rsp_targets(actor: UnitInstance, dpmg_coord: Vector2i) -> Array:
	var out: Array = []
	for u in state.all_units():
		if u.owner == actor.owner or not u.is_alive():
			continue
		if not is_visible_to_team(actor.owner, u):
			continue
		if not Combat.is_on_firing_line(dpmg_coord, u.coord):
			continue
		if los_blocked(dpmg_coord, u.coord):
			continue
		if Combat.hit_number(Combat.distance(dpmg_coord, u.coord), MCF.DPMG_RANGE) >= 7:
			continue
		out.append(u.id)
	return out

func _resolve_dpmg(intent: DPMGFireIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if not state.grid.in_bounds(intent.dpmg_coord):
		return ActionResult.fail("Cell out of bounds")
	var rsp_cell := state.grid.cell(intent.dpmg_coord)
	if rsp_cell.feature_id != MCF.FEATURE_DPMG:
		return ActionResult.fail("No DPMG here")
	if Combat.distance(actor.coord, intent.dpmg_coord) != 1:
		return ActionResult.fail("Must stand in a cell adjacent to the DPMG")

	# Вражеский ДПМГ — отбираем по правилу захвата (§3.7).
	if rsp_cell.feature_owner != actor.owner:
		actor.remaining_ap -= 1
		rsp_cell.feature_owner = actor.owner
		return ActionResult.success(["%s seized the DPMG at (%d, %d) [AP: %d]" % [
			actor.stats.display_name, intent.dpmg_coord.x, intent.dpmg_coord.y, actor.remaining_ap]])

	# Свой ДПМГ — стрельба очередью из клетки пулемёта.
	var target := state.get_unit(intent.target_id)
	if target == null or not target.is_alive():
		return ActionResult.fail("No target")
	if target.owner == actor.owner:
		return ActionResult.fail("Can't shoot your own")
	if not is_visible_to_team(actor.owner, target):
		return ActionResult.fail("Target not visible")
	if not Combat.is_on_firing_line(intent.dpmg_coord, target.coord):
		return ActionResult.fail("Target not on the firing line")
	if los_blocked(intent.dpmg_coord, target.coord):
		return ActionResult.fail("Firing line is blocked")
	if trench_protected(intent.dpmg_coord, target):
		return ActionResult.fail("Target is below the trench line")
	var need := Combat.hit_number(Combat.distance(intent.dpmg_coord, target.coord), MCF.DPMG_RANGE)
	if need >= 7:
		return ActionResult.fail("Too far for the DPMG")

	actor.remaining_ap -= 1
	var parry_need: int = target.armor() - _corpse_shield_bonus(target)
	var cover := cover_effect_from(intent.dpmg_coord, target)
	need += cover["hit_penalty"]
	parry_need -= cover["defense_bonus"]
	if _fire_between(intent.dpmg_coord, target.coord):
		need += MCF.FIRE_SHOOT_PENALTY
	need = clampi(need, 1, 7)

	var want: int = MCF.DPMG_RATE_OF_FIRE if intent.shots < 0 else clampi(intent.shots, 1, MCF.DPMG_RATE_OF_FIRE)
	var shot_details: Array = []
	var hits := 0
	var killed := false
	var fired := 0
	for _i in want:
		fired += 1
		var hit_roll := state.dice.roll_d6()
		var is_hit := hit_roll >= need
		var det := {
			"hit_roll": hit_roll, "need": need, "hit": is_hit,
			"def_roll": 0, "armor": parry_need, "parried": true,
		}
		if is_hit:
			hits += 1
			var def_roll := state.dice.roll_d6()
			det["def_roll"] = def_roll
			det["parried"] = def_roll >= parry_need
			if not det["parried"]:
				killed = true
		shot_details.append(det)
		if killed:
			break

	if killed:
		_kill(target)

	var result := ActionResult.new()
	result.ok = true
	if killed:
		_fx(result, {"fx": "blood", "at": target.coord, "from": target.coord})
	result.dice_events.append({
		"kind": "attack", "shooter": "DPMG", "target": target.stats.display_name,
		"need": need, "armor": parry_need, "shots": shot_details, "killed": killed,
		"def_owner": target.owner, "shooter_owner": state.active_player(),  # item 13
	})
	_fx_lane(result, intent.dpmg_coord, target.coord, actor.owner)  # issue 8
	result.log("DPMG (%s) → %s: %d shots, %d hits (need %d+)" % [
		actor.stats.display_name, target.stats.display_name, fired, hits, need])
	if killed:
		result.log("%s killed!" % target.stats.display_name)
	return result

# --- Применение предметов / гранаты (§3.6) ---
func _resolve_use_item(intent: UseItemIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	var reason := can_use_item(actor)
	if reason != "":
		return ActionResult.fail(reason)
	if not state.grid.in_bounds(intent.target):
		return ActionResult.fail("Target out of bounds")

	var item_id := actor.held_item_id

	# Станция дронов ставится в соседнюю свободную клетку (§3.12) — своя геометрия.
	if item_id == MCF.ITEM_DRONE_STATION:
		if Combat.distance(actor.coord, intent.target) != 1:
			return ActionResult.fail("The station is placed in an adjacent cell")
		# Оператор в челноке ставит станцию в ПУСТОЕ соседнее кресло (batch 13 S8): кресло
		# занимается станцией, дрон поднимается над ним; забрать станцию — освободить кресло.
		var sveh := seated_vehicle_of(actor)
		if sveh != null:
			var seat := -1
			for i in sveh.seats.size():
				if sveh.seat_cell(i) == intent.target:
					seat = i
			if seat == -1:
				return ActionResult.fail("From a seat the station goes into another seat")
			if sveh.seats[seat] != -1:
				return ActionResult.fail("That seat is taken")
			if deployed_station_of(actor) != Vector2i(-1, -1):
				return ActionResult.fail("Your station is already deployed")
			actor.remaining_ap -= 1
			actor.held_item_id = ""
			sveh.seats[seat] = Vehicle.SEAT_STATION
			var scell_s := state.grid.cell(intent.target)
			scell_s.feature_id = MCF.FEATURE_DRONE_STATION
			scell_s.feature_owner = actor.owner
			scell_s.station_operator_id = actor.id
			var res_s := ActionResult.success(["%s mounts a drone station in the shuttle seat at (%d, %d)" % [
				actor.stats.display_name, intent.target.x, intent.target.y]])
			var launched_s := _launch_drone_at(intent.target, actor)
			if launched_s != null:
				res_s.log("A drone rises above the shuttle at (%d, %d)" % [
					launched_s.coord.x, launched_s.coord.y])
			return res_s
		if not state.grid.cell(intent.target).is_empty():
			return ActionResult.fail("Cell is occupied")
		# Одна развёрнутая станция на оператора (item 16): вторую не поставить, пока
		# первая стоит. Свернуть её обратно можно — PickUpStationIntent.
		var already := deployed_station_of(actor)
		if already != Vector2i(-1, -1):
			return ActionResult.fail("Your station is already deployed at (%d, %d)" % [
				already.x, already.y])
		actor.remaining_ap -= 1
		actor.held_item_id = ""
		var scell := state.grid.cell(intent.target)
		scell.feature_id = MCF.FEATURE_DRONE_STATION
		scell.feature_owner = actor.owner
		scell.station_operator_id = actor.id
		var res := ActionResult.success(["%s deploys a drone station at (%d, %d)" % [
			actor.stats.display_name, intent.target.x, intent.target.y]])
		# Станция разворачивается вместе с дроном — он сразу поднимается над ней (#77).
		var launched := _launch_drone_at(intent.target, actor)
		if launched != null:
			res.log("A drone rises above the station at (%d, %d)" % [
				launched.coord.x, launched.coord.y])
		return res

	if Combat.distance(actor.coord, intent.target) > MCF.GRENADE_RANGE:
		return ActionResult.fail("Too far to throw (max %d)" % MCF.GRENADE_RANGE)
	# Гранаты бросаются только ортогонально (#4).
	if item_id == MCF.ITEM_FRAG and actor.coord.x != intent.target.x and actor.coord.y != intent.target.y:
		return ActionResult.fail("Grenades can only be thrown in straight lines")
	actor.remaining_ap -= 1
	actor.held_item_id = ""  # предмет расходуется в любом исходе

	if item_id == MCF.ITEM_FRAG:
		return _throw_frag(actor, intent.target)
	elif item_id == MCF.ITEM_EXTINGUISHER:
		return _extinguish(actor, intent.target)
	return ActionResult.fail("Unknown item: %s" % item_id)

## Бросок осколочной гранаты (§3.6): сперва бросок на точность попадания в клетку.
## Число попадания x = ceil(дистанция / (дальность/6)); бросаем d6. Если ≥ x — граната
## ложится в цель; иначе НЕДОЛёт на (x − бросок) клеток вдоль линии броска (пример игрока:
## бросок 3 при нужном 5 → граната ложится на 4-ю клетку от цели ближе к метателю).
## Взрывается там, где легла, задевая и своих.
func _throw_frag(thrower: UnitInstance, aim: Vector2i) -> ActionResult:
	var dist := Combat.distance(thrower.coord, aim)
	var need := Combat.hit_number(dist, float(MCF.GRENADE_RANGE))
	var roll := state.dice.roll_d6()
	var on_target := roll >= need
	var landing := aim
	if not on_target:
		var shortfall: int = need - roll
		var land_index: int = clampi(dist - shortfall, 0, dist)
		var path := _throw_path(thrower.coord, aim)
		landing = thrower.coord if land_index <= 0 else path[land_index - 1]
	var result := _explode_frag(thrower, landing)
	# Показать бросок на точность перед взрывом.
	result.dice_events.push_front({
		"kind": "check", "actor": thrower.stats.display_name,
		"roll": roll, "need": need, "ok": on_target,
	})
	if on_target:
		result.log("Roll %d (need %d+): grenade on target." % [roll, need])
	else:
		result.log("Roll %d (need %d+): short throw, grenade landed at (%d, %d)." % [
			roll, need, landing.x, landing.y])
	return result

## Упорядоченный путь клеток от a к b (без a, включая b), длиной = дистанция Чебышёва.
func _throw_path(a: Vector2i, b: Vector2i) -> Array:
	var out: Array = []
	var dx := b.x - a.x
	var dy := b.y - a.y
	var steps: int = maxi(absi(dx), absi(dy))
	if steps == 0:
		return out
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		out.append(Vector2i(a.x + int(round(dx * t)), a.y + int(round(dy * t))))
	return out

## Осколочная граната (§3.6): взрыв в радиусе 1 (3x3, Чебышёв).
## В эпицентре — автосмерть (кроме щитоносца). Прочие бросают 2 кубика защиты
## со штрафом −1 каждый; выживают только если ОБА парируют. Задевает всех, включая своих.
func _explode_frag(thrower: UnitInstance, center: Vector2i) -> ActionResult:
	state.combat_started = true  # взрыв слышен всем — мирные вскрываются (§3.10, #56)
	var area := blast_cells_for_item(MCF.ITEM_FRAG, center)
	var in_area := {}
	for c: Vector2i in area:
		in_area[c] = true
	var details: Array = []
	var killed_names: Array = []
	var broken_glass: Array = []
	# Отчёт нужен уже здесь: _kill складывает в него кровь (#21.4), а строки журнала
	# дописываются ниже, как и раньше.
	var result := ActionResult.new()
	result.ok = true
	for u in state.all_units():
		if not u.is_alive():
			continue
		if not in_area.has(u.coord):
			continue
		var at_epicenter: bool = u.coord == center
		var det := {
			"name": u.stats.display_name, "coord": u.coord, "owner": u.owner,
			"epicenter": at_epicenter, "armor": u.armor(),
			"need": u.armor() + 1, "rolls": [], "survived": true,
		}
		var is_shield: bool = u.stats.special_ability_id == MCF.ABILITY_SHIELD_BEARER
		if at_epicenter and not is_shield:
			det["survived"] = false
		else:
			# Штраф −1 к каждому кубику; несомый труп-щит облегчает защиту (#6).
			var need_roll: int = u.armor() + 1 - _corpse_shield_bonus(u)
			for _i in 2:
				var r := state.dice.roll_d6()
				det["rolls"].append(r)
				if r < need_roll:
					det["survived"] = false
		if not det["survived"]:
			_kill(u, result, center, true)
			killed_names.append(u.stats.display_name)
		details.append(det)

	# Осколки не сносят укрепления (#44): единственное, что бьётся, — стекло, и оно
	# «защищается» как обычный юнит с бронёй 5+ и тем же штрафом −1 на оба кубика.
	for gc: Vector2i in area:
		if not state.grid.in_bounds(gc):
			continue
		var gcell := state.grid.cell(gc)
		if not MCF.is_glass(gcell.feature_id):
			continue
		# Бронестекло держит удар по СВОЕМУ правилу: один кубик, 4+ — устояло. Обычное
		# по-прежнему бросает два против 6+ и потому почти всегда бьётся.
		var armored: int = MCF.glass_hold_need(gcell.feature_id)
		var gdet := {
			"name": MCF.FEATURE_NAMES.get(gcell.feature_id, "Glass"), "coord": gc,
			"owner": gcell.feature_owner, "epicenter": false,
			"armor": armored - 1 if armored > 0 else GLASS_ARMOR,
			"need": armored if armored > 0 else GLASS_ARMOR + 1,
			"rolls": [], "survived": true,
		}
		for _i in (1 if armored > 0 else 2):
			var gr := state.dice.roll_d6()
			gdet["rolls"].append(gr)
			if gr < int(gdet["need"]):
				gdet["survived"] = false
		if not gdet["survived"]:
			_fx(result, {"fx": "shards", "at": gc, "from": center})
			_fx(result, {"fx": "debris", "at": NOWHERE, "cells": [gc]})  # разрушенный пол (item 7)
			gcell.clear_feature()
			broken_glass.append(gc)
		details.append(gdet)

	# Осколочная не рушит укрепления, поэтому щебень кладём только там, где реально
	# что-то разлетелось: под самим взрывом и под лопнувшими стёклами (#21.1).
	_fx(result, {"fx": "debris", "at": center, "cells": [center] + broken_glass})
	result.dice_events.append({
		"kind": "grenade", "item": MCF.ITEM_FRAG,
		"thrower": thrower.stats.display_name, "center": center, "targets": details,
	})
	result.log("%s throws a frag grenade at (%d, %d)" % [
		thrower.stats.display_name, center.x, center.y])
	if killed_names.is_empty() and broken_glass.is_empty():
		result.log("… nobody hit")
	else:
		for n in killed_names:
			result.log("%s killed by the blast!" % n)
		for g: Vector2i in broken_glass:
			result.log("Glass at (%d, %d) shattered" % [g.x, g.y])
	return result

## Зона поражения ручной гранаты (#64): «крест накрест» — эпицентр и четыре
## ДИАГОНАЛИ. Ортогональные соседи целы: боец вплотную сбоку взрыв переживает.
## Публичная — UI рисует предпросмотр этим же вызовом, чтобы подсветка не могла
## разойтись с настоящим взрывом.
func blast_cells_for_item(item_id: String, center: Vector2i) -> Array[Vector2i]:
	match item_id:
		MCF.ITEM_FRAG:
			return MCF.blast_x(center)
		MCF.ITEM_EXTINGUISHER:
			# Пожаротушительная (#19) кроет ПОЛНЫЙ квадрат 5×5, а не «косой крест»
			# осколочной: она не поражает, а гасит, и дырам в зоне взяться неоткуда.
			return MCF.blast_square(center, MCF.EXTINGUISHER_RADIUS)
	return MCF.blast_square(center, 1)

## Пожаротушительная граната (§3.6, переработана в #19): гасит ВЕСЬ огонь в квадрате
## 5×5 вокруг точки падения и на 3 раунда запирает эту зону — пассивный разлив в неё
## не идёт. Запрет односторонний: прямой выстрел огнемёта поджигает клетку зоны как
## ни в чём не бывало (см. _flame_line), тушитель глушит только самораспространение.
func _extinguish(thrower: UnitInstance, center: Vector2i) -> ActionResult:
	var cleared := 0
	var until := state.turns.round_number + MCF.EXTINGUISHER_SUPPRESS_TURNS
	for c: Vector2i in blast_cells_for_item(MCF.ITEM_EXTINGUISHER, center):
		if not state.grid.in_bounds(c):
			continue
		var cell := state.grid.cell(c)
		if _extinguish_cell(cell):
			cleared += 1
		# Продлеваем, а не перезаписываем: два тушителя подряд не должны укоротить
		# уже поставленный запрет.
		cell.fire_suppressed_until = maxi(cell.fire_suppressed_until, until)
	var result := ActionResult.new()
	result.ok = true
	result.dice_events.append({
		"kind": "grenade", "item": MCF.ITEM_EXTINGUISHER,
		"thrower": thrower.stats.display_name, "center": center, "targets": [],
	})
	result.log("%s uses a fire extinguisher at (%d, %d) [fires put out: %d, sealed for %d rounds]" % [
		thrower.stats.display_name, center.x, center.y, cleared,
		MCF.EXTINGUISHER_SUPPRESS_TURNS])
	return result

## "" = можно применить предмет; иначе причина отказа.
func can_use_item(actor: UnitInstance) -> String:
	if actor.held_item_id == "":
		return "No item"
	if not MCF.ITEM_NAMES.has(actor.held_item_id):
		return "Unknown item"
	return ""

## Куда оператор может поставить станцию (для UI): рядом на пустой пол, а из кресла
## челнока — в пустое соседнее кресло (batch 13 S8).
func station_place_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null:
		return out
	var sveh := seated_vehicle_of(actor)
	if sveh != null:
		for i in sveh.free_seats():
			var sc := sveh.seat_cell(i)
			if Combat.distance(actor.coord, sc) == 1:
				out.append(sc)
		return out
	for n in state.grid.neighbors(actor.coord):
		if state.grid.cell(n).is_empty():
			out.append(n)
	return out

## Клетки-цели для броска гранаты (в пределах дальности, в границах, не стена) — для UI.
func grenade_target_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	for dy in range(-MCF.GRENADE_RANGE, MCF.GRENADE_RANGE + 1):
		for dx in range(-MCF.GRENADE_RANGE, MCF.GRENADE_RANGE + 1):
			# Гранаты бросаются только ортогонально (#4): либо по строке, либо по столбцу.
			if dx != 0 and dy != 0:
				continue
			var c := Vector2i(actor.coord.x + dx, actor.coord.y + dy)
			if not state.grid.in_bounds(c):
				continue
			if Combat.distance(actor.coord, c) > MCF.GRENADE_RANGE:
				continue
			if state.grid.cell(c).is_wall():
				continue
			out.append(c)
	return out

func capturable_target_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	for u in state.all_units():
		if u.id == actor.id or u.captor_id != -1 or u.aboard_vehicle_id != -1:
			continue
		if u.is_alive() and Combat.distance(actor.coord, u.coord) == 1:
			out.append(u.id)
	return out

# --- Передача хода (§3.3) ---
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
	var played: Dictionary = {}
	while MCF.is_neutral(state.active_player()):
		var slot := state.turns.active_index
		if played.has(slot):
			break
		played[slot] = true
		var res := advance_civilians(state.active_player())
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
		if state.turns.active_index == slot:
			break
	return out

func _resolve_end_turn(intent: EndTurnIntent = null) -> ActionResult:
	# Единственный авторитетный переход состояния без проверки прав (AUDIT §2.4):
	# actor_id здесь −1, поэтому _validate_actor не срабатывает, и клиент мог
	# завершить чужой ход. Заполненный requester сверяем; пустой — старый вызов
	# (ИИ, мирные, внутренние), их и раньше никто не проверял.
	if intent != null and intent.requester >= 0 \
			and intent.requester != state.active_player():
		return ActionResult.fail("Not your turn")
	var prev := state.active_player()
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
			MCF.owner_name(prev), MCF.owner_name(state.active_player()), state.turns.round_number
		]
	]
	lines.append_array(civ.log_lines)
	lines.append_array(fire_res.log_lines)
	var out := ActionResult.success(lines)
	# Броски жителей едут вместе с передачей хода: UI отыграет их анимацией, а смерти
	# покажет только после кубика защиты — как и в любом другом обмене выстрелами (#96).
	out.dice_events = civ.dice_events
	out.fx.append_array(civ.fx)
	out.deaths = civ.deaths
	# Погибшие и косметика от подорвавшихся в огне мин — тоже частью передачи хода.
	out.deaths.append_array(fire_res.deaths)
	out.fire_deaths.append_array(fire_res.fire_deaths)
	out.fx.append_array(fire_res.fx)
	# Случайное событие на новый ход (item 61). Выключено по умолчанию — тогда ни одного
	# кубика не бросается и поток случайности старых партий цел.
	_maybe_random_event(out)
	return out

## Разыграть случайное событие на очередном ходу, если оно «созрело» (§1.5, item 61).
## Всё — «случится ли», «какое», «куда бьёт» — берётся из DiceService, чтобы хост и
## клиент разыграли одно и то же. Пока эффекты условны (заглушки).
func _maybe_random_event(res: ActionResult) -> void:
	if random_events == null:
		return
	# Единая точка (item 11): «созрело ли», «обязательно ли», «какое» — всё внутри
	# roll_event через DiceService, чтобы хост и клиент разыграли одно и то же.
	var id := random_events.roll_event(state.dice)
	if id == "":
		return
	res.log("⚠ Random event — %s" % RandomEvents.event_name(id))
	match id:
		RandomEvents.MORTAR:
			# Единственная заглушка с реальным эффектом: взрыв в клетке, выбранной кубиком.
			var center := Vector2i(_rand_index(state.grid.width), _rand_index(state.grid.height))
			var killed := _blast(center, res)
			var tail := "" if killed.is_empty() else " — " + ", ".join(killed) + " killed"
			res.log("Mortar shell lands at (%d, %d)%s" % [center.x, center.y, tail])
		RandomEvents.TREMOR:
			res.log("The ground shakes underfoot. (placeholder — effect pending spec)")
		RandomEvents.GAS:
			res.log("A gas cloud drifts across the battlefield. (placeholder — effect pending spec)")

# --- Запросы легальности (для подсветки целей в UI) ---
## allow_embrasure=false — стрелок не может работать через амбразуру ДОТа: заряд
## противотанкиста в узкую щель не пролезает (#86).
## ignore_units=true — считать перекрытой только НЕЖИВУЮ преграду (стена/корпус).
## Дружественный огонь (#100): чужая спина на линии не отменяет выстрел, а ловит его,
## поэтому проверка «можно ли стрелять» игнорирует людей, а попадание перенаправляет
## first_unit_on_line().
## Линия проходится ШАГАМИ, без Combat.line_cells(): та строит и возвращает массив, а
## los_blocked зовётся десятками тысяч раз за один расчёт плана ИИ — на этих
## аллокациях уходило больше времени, чем на саму проверку. Правила ниже те же
## и в том же порядке.
## glass_passable — стекло на линии НЕ отменяет выстрел (#29): пуля пробует его
## пробить, и это решается побульно уже при разрешении очереди (_glass_on_line).
## Флаг только для ПУЛЬ: заряд противотанкиста, снаряд пушки и обзор стекло по-прежнему
## считают стеной, поэтому по умолчанию он выключен.
func los_blocked(from_coord: Vector2i, to_coord: Vector2i, allow_embrasure: bool = true,
		ignore_units: bool = false, glass_passable: bool = false) -> bool:
	if _line_off_board(from_coord, to_coord):
		return false
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if dx == 0 and dy == 0:
		return false
	# Не по прямой — line_cells() вернула бы пустой массив, значит «не перекрыто».
	if dx != 0 and dy != 0 and absi(dx) != absi(dy):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	var d := 1
	while x != to_coord.x or y != to_coord.y:
		var cell := grid.cell_fast(x, y)
		if cell.cover_height >= MCF.WALL_HEIGHT:
			# Ёж поверх мешков — решётчатая стена: с соседней клетки сквозь неё стреляют.
			# ДОТ с амбразурами (#86): боец, прижавшийся к стене вплотную, стреляет
			# сквозь щель. Работает только в упор — издалека в амбразуру не попасть.
			# d == расстояние по Чебышёву от стрелка до этой клетки: шаг диагонали
			# и шаг по оси стоят одинаково, поэтому счётчик и есть дистанция.
			var fid := cell.feature_id
			if d <= 1 and (fid == MCF.FEATURE_HEDGEHOG_SANDBAGS \
					or (allow_embrasure and fid == MCF.FEATURE_DOT_OPEN)):
				pass
			elif glass_passable and MCF.is_glass(fid):
				pass  # стекло пуле не преграда, а испытание (#29)
			else:
				return true
		# Корпус машины перекрывает линию огня (§техника) — кроме своего же: линия,
		# начатая или оконченная на клетке этого корпуса, идёт по его крыше (batch 13:
		# пассажир стреляет со своего кресла, и в пассажира стреляют снаружи).
		elif cell.vehicle_id != -1 and cell.vehicle_id != grid.vehicle_at(from_coord) \
				and cell.vehicle_id != grid.vehicle_at(to_coord):
			return true
		# Живой юнит перекрывает линию огня; труп — нет (решение автора).
		elif not ignore_units and cell.occupant != null and cell.occupant.is_alive():
			return true
		x += sx
		y += sy
		d += 1
	return false

## Сколько стёкол стоит НА ЛИНИИ между стрелком и целью, концы не считая (#29).
## Каждое из них каждая пуля пробивает отдельным броском. Ноль — обычный выстрел,
## и тогда лишних кубиков не бросается вовсе: поток случайности старых партий цел.
func _glass_on_line(from_coord: Vector2i, to_coord: Vector2i) -> int:
	if _line_off_board(from_coord, to_coord):
		return 0
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return 0
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	var panes := 0
	while x != to_coord.x or y != to_coord.y:
		if MCF.is_glass(grid.cell_fast(x, y).feature_id):
			panes += 1
		x += sx
		y += sy
	return panes

## Координаты стёкол НА ЛИНИИ (концы не считая), по порядку от стрелка к цели.
## Нужны, чтобы пробитое стекло можно было РАЗБИТЬ на месте (item 4), а не только
## сосчитать. Порядок совпадает с порядком бросков на пробитие в _resolve_shoot.
func _glass_cells_on_line(from_coord: Vector2i, to_coord: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _line_off_board(from_coord, to_coord):
		return out
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return out
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		if grid.cell_fast(x, y).feature_id == MCF.FEATURE_GLASS:
			out.append(Vector2i(x, y))
		x += sx
		y += sy
	return out

## Ни один шаг по линии не имеет смысла, если её конец лежит ВНЕ ПОЛЯ, — а такой конец
## приходит сюда буднично: у бойца В МАШИНЕ координата вынесена за карту (OFFBOARD,
## −9999, §техника). Проверки «на одной ли прямой» это не ловит: от (−9999, −9999)
## диагональ проходит через половину карты, и цикл честно шагал ОТ края мира внутрь,
## индексируя _cells отрицательным адресом на первом же шаге — «Out of bounds get index
## '-509898' (on base: Array[GridCell])» в отчёте игрока (issue 2). Отсекаем такие
## линии в одном месте: каждый ходок по лучу спрашивает эту проверку первой строкой,
## и ни один из них больше не может уйти за край.
##
## Вне поля линия «пустая»: нет ни стены, ни огня, ни стекла, ни тела на пути.
func _line_off_board(a: Vector2i, b: Vector2i) -> bool:
	var g := state.grid
	return not g.in_bounds(a) or not g.in_bounds(b)

## Первый живой боец, стоящий НА ЛИНИИ между стрелком и целью (концы не считаются).
## Именно в него уходит выстрел, если стрелок бьёт сквозь чужую спину (#100).
## null = линия чистая, и пуля дойдёт до заявленной цели.
## skip_allies_of != null — пропускать союзников этого стрелка: при выключенном
## дружественном огне пуля проходит над своими, а не находит их спиной. Иначе
## «огонь по своим отключён» означало бы лишь запрет ПРИЦЕЛИТЬСЯ в союзника, а
## убивать его случайно всё так же было бы можно.
func first_unit_on_line(from_coord: Vector2i, to_coord: Vector2i,
		skip_allies_of: UnitInstance = null) -> UnitInstance:
	if _line_off_board(from_coord, to_coord):
		return null
	# Шаги по линии вместо Combat.line_cells(): массив-посредник здесь не нужен, а
	# функция стоит на пути КАЖДОГО выстрела. Проверка «конец линии» из старого цикла
	# не переносится: line_cells() концы и так не отдавала, она была холостой.
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return null
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		var cell := grid.cell(Vector2i(x, y))
		if cell == null:
			x += sx
			y += sy
			continue
		# Боец на дне окопа сидит ниже линии огня — пуля проходит над ним (§3.7).
		# Сосед по челноку перекрывает линию, как любой боец: стрелять сквозь него нельзя.
		if cell.occupant != null and cell.occupant.is_alive() \
				and not trench_protected(from_coord, cell.occupant) \
				and not (skip_allies_of != null
						and is_ally_of(skip_allies_of, cell.occupant)):
			return cell.occupant
		x += sx
		y += sy
	return null

## Свой ли это боец для стрелка — сам или союзник по команде. Единственная точка,
## через которую правила спрашивают «в него вообще можно целиться».
## Огневое покрытие клеток (RL-тактика, стиль HARD «фланг»): по каждой клетке — сколько
## попаданий за ход в неё ОЖИДАЕТСЯ от стрелков, то есть сумма P(попадания) × скорострельность.
##
## hostile = true — стрелки, ВРАЖДЕБНЫЕ viewer'у и видимые ему (туман честен: невидимый враг
## сюда не попадает, иначе карта угроз подсказывала бы, где он прячется); false — свои и
## союзные стрелки viewer'а (их он знает всех).
##
## Геометрия та же, что у can_shoot: огонь только по восьми прямым (§3.5), стена или корпус
## машины луч останавливают (стекло — нет), шанс — та же лестница hit_number/sniper.
## Марксман бьёт сквозь всё, огнемёт — на FLAME_JET_LENGTH. Пушка танка — лучами из центра
## на дальность орудия. Окопы и укрытия не учитываются: это оценка «простреливается ли
## клетка», а не точный бросок.
func fire_cover(viewer: int, hostile: bool) -> PackedFloat32Array:
	var grid := state.grid
	var w := grid.width
	var shooters: Array = []
	var key := hash([viewer, hostile, fog_enabled, GridCell.vision_version, w, grid.height])
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or u.aboard_vehicle_id != -1 or u.is_held() \
				or MCF.is_neutral(u.owner) or not grid.in_bounds(u.coord):
			continue
		var mine := state.roster.are_allies(viewer, u.owner)
		if mine == hostile:
			continue
		if hostile and not is_visible_to_team(viewer, u):
			continue
		if u.fire_range() <= 0.0 and u.stats.special_ability_id != MCF.ABILITY_MARKSMAN:
			continue
		shooters.append(u)
		key = hash([key, u.id, u.coord, u.remaining_ap > 0])
	var guns: Array = []
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or veh.is_borg() or veh.occupants.is_empty():
			continue
		var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get("weapons", {}).get("main_gun", {})
		if gun.is_empty() or state.roster.are_allies(viewer, veh.owner) == hostile:
			continue
		if hostile:
			var seen := not fog_enabled
			var vis := team_visible_coords(viewer)
			for fc: Vector2i in veh.footprint():
				if vis.has(fc):
					seen = true
					break
			if not seen:
				continue
		guns.append(veh)
		key = hash([key, -1 - veh.id, veh.origin])
	if _cover_cache.has(key):
		return _cover_cache[key]
	var out := PackedFloat32Array()
	out.resize(w * grid.height)
	for u: UnitInstance in shooters:
		var ability: String = u.stats.special_ability_id
		var pierce := ability == MCF.ABILITY_MARKSMAN
		var sniper := ability == MCF.ABILITY_SNIPER
		var reach := MCF.FLAME_JET_LENGTH if ability == MCF.ABILITY_FLAMETHROWER else 1 << 20
		var rof := float(maxi(1, u.rate_of_fire()))
		for d: Vector2i in DIR8:
			var c: Vector2i = u.coord
			var dist := 0
			while true:
				c += d
				dist += 1
				if dist > reach or not grid.in_bounds(c):
					break
				var cell := grid.cell_fast(c.x, c.y)
				if not pierce and (cell.blocks_sight() or cell.vehicle_id != -1):
					break
				var need := 1 if pierce else (Combat.sniper_hit_number(dist) if sniper
						else Combat.hit_number(dist, u.fire_range()))
				if need >= 7:
					break
				out[c.y * w + c.x] += rof * float(7 - need) / 6.0
	for veh: Vehicle in guns:
		var rng := int(VehicleDB.get_vehicle(veh.type_id)["weapons"]["main_gun"].get("range", MCF.CANNON_RANGE))
		for d: Vector2i in DIR8:
			var c: Vector2i = veh.center()
			var dist := 0
			while true:
				c += d
				dist += 1
				if dist > rng or not grid.in_bounds(c):
					break
				var cell := grid.cell_fast(c.x, c.y)
				if cell.vehicle_id == veh.id:
					continue
				if cell.blocks_sight() or cell.vehicle_id != -1:
					break
				out[c.y * w + c.x] += 1.0
	if _cover_cache.size() > 8:
		_cover_cache.clear()
	_cover_cache[key] = out
	return out

var _cover_cache: Dictionary = {}

## Прогноз на ход противника (RL-тактика): что видимые враги смогут сделать СЛЕДУЮЩИМ ходом.
##   "reach" — сколько врагов дойдут до клетки за один ход (по настоящим путям, как ходят);
##   "fire"  — ожидаемые попадания по клетке после их хода: каждый стрелок берётся в лучшей
##             для него точке из тех, куда дойдёт (решётка 3×3 его разлива плюс текущая
##             клетка), — то есть «здесь безопасно сейчас, но не через ход».
## Туман честен: только враги, видимые viewer'у. Вклад каждого врага кэшируется по его клетке
## и раунду — пока наша сторона ходит, враги стоят, и прогноз считается один раз на ход.
func enemy_forecast(viewer: int) -> Dictionary:
	var grid := state.grid
	var w := grid.width
	var n := w * grid.height
	var gid := grid.get_instance_id()
	if _fc_grid != gid:
		_fc_unit.clear()
		_fc_total.clear()
		_fc_grid = gid
	var hostiles: Array = []
	var key := hash([viewer, fog_enabled, GridCell.vision_version, state.turns.round_number, n])
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or u.aboard_vehicle_id != -1 or u.is_held() \
				or MCF.is_neutral(u.owner) or not grid.in_bounds(u.coord) \
				or state.roster.are_allies(viewer, u.owner) or not is_visible_to_team(viewer, u):
			continue
		hostiles.append(u)
		key = hash([key, u.id, u.coord])
	if _fc_total.has(key):
		return _fc_total[key]
	var reach := PackedFloat32Array()
	reach.resize(n)
	var fire := PackedFloat32Array()
	fire.resize(n)
	for u: UnitInstance in hostiles:
		var ukey := hash([u.coord, GridCell.vision_version, state.turns.round_number])
		var rec: Variant = _fc_unit.get(u.id)
		if rec == null or rec[0] != ukey:
			rec = [ukey] + _forecast_unit(u)
			_fc_unit[u.id] = rec
		for i: int in rec[1]:
			reach[i] += 1.0
		var fi: PackedInt32Array = rec[2]
		var fv: PackedFloat32Array = rec[3]
		for j in fi.size():
			fire[fi[j]] += fv[j]
	if _fc_total.size() > 8:
		_fc_total.clear()
	_fc_total[key] = {"reach": reach, "fire": fire}
	return _fc_total[key]

var _fc_unit: Dictionary = {}    # id врага -> [ключ, клетки досягаемости, клетки огня, значения]
var _fc_total: Dictionary = {}
var _fc_grid: int = 0

## Вклад одного врага в прогноз: клетки, куда он дойдёт, и лучший огонь по каждой клетке
## из точек, куда он дойдёт (максимум, а не сумма: стоять он будет в одной точке).
func _forecast_unit(u: UnitInstance) -> Array:
	var grid := state.grid
	var w := grid.width
	var cost: Dictionary = reachable_for(u, move_budget_fresh(u)).cost
	var reach_idx := PackedInt32Array()
	var spots: Array[Vector2i] = [u.coord]
	for c: Vector2i in cost:
		reach_idx.append(c.y * w + c.x)
		if c.x % 3 == 0 and c.y % 3 == 0 and c != u.coord and not grid.blocks_walk(c):
			spots.append(c)
	var best: Dictionary = {}
	var ability: String = u.stats.special_ability_id
	if u.fire_range() > 0.0 or ability == MCF.ABILITY_MARKSMAN:
		var pierce := ability == MCF.ABILITY_MARKSMAN
		var sniper := ability == MCF.ABILITY_SNIPER
		var max_d := MCF.FLAME_JET_LENGTH if ability == MCF.ABILITY_FLAMETHROWER else 1 << 20
		var rof := float(maxi(1, u.rate_of_fire()))
		for from: Vector2i in spots:
			for d: Vector2i in DIR8:
				var c: Vector2i = from
				var dist := 0
				while true:
					c += d
					dist += 1
					if dist > max_d or not grid.in_bounds(c):
						break
					var cell := grid.cell_fast(c.x, c.y)
					if not pierce and (cell.blocks_sight() or cell.vehicle_id != -1):
						break
					var need := 1 if pierce else (Combat.sniper_hit_number(dist) if sniper
							else Combat.hit_number(dist, u.fire_range()))
					if need >= 7:
						break
					var i := c.y * w + c.x
					var v := rof * float(7 - need) / 6.0
					if v > float(best.get(i, 0.0)):
						best[i] = v
	var fi := PackedInt32Array(best.keys())
	var fv := PackedFloat32Array(best.values())
	return [reach_idx, fi, fv]

func is_ally_of(a: UnitInstance, b: UnitInstance) -> bool:
	if a == null or b == null:
		return false
	return state.roster.are_allies(a.owner, b.owner)

## "" = стрелять можно; иначе причина отказа.
func can_shoot(shooter: UnitInstance, target: UnitInstance) -> String:
	if target == null or not target.is_alive():
		return "No target"
	if target.id == shooter.id:
		return "Can't shoot yourself"
	# СТРЕЛОК вне поля — зеркало проверки цели ниже (issue 2): сидящий в машине стреляет
	# из неё только орудиями машины, а его собственная координата вынесена за карту, и
	# любая линия от неё уходит за край сетки.
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	# Боец В МАШИНЕ целью быть не может (#23): его координата — OFFBOARD (-9999,-9999),
	# и она вне поля. is_on_firing_line() отвечает на неё «да» (по диагонали от почти
	# любой клетки), после чего trench_protected() дёргает cell(OFFBOARD).feature_id на
	# null — отсюда «feature_id on Nil» при нажатии «Стрельба», а los_blocked() за ним
	# уходит шагать десять тысяч клеток к краю мира. Отсекаем такие цели сразу.
	if not state.grid.in_bounds(target.coord):
		return "Target unavailable"
	# Дружественный огонь (#100): по своим стрелять МОЖНО — оружие не разбирает форму.
	# Выключенный в лобби, он запрещает и прицел в союзника (§7 «Лобби»).
	if not friendly_fire_enabled and is_ally_of(shooter, target):
		return "Friendly fire is off"
	# Свой всегда виден, поэтому проверку тумана войны он проходит сам собой.
	# Туман войны (§3.9): скрытого противника нельзя выбрать целью.
	if not is_visible_to_team(shooter.owner, target):
		return "Target not visible"
	if not Combat.is_on_firing_line(shooter.coord, target.coord):
		return "Target not on the firing line"
	# Боец на дне окопа скрыт ниже линии огня — достать его можно только вплотную (§3.7),
	# а лазером (§3.13) — только из такого же окопа: луч не гнётся вниз (#103).
	if trench_protected(shooter.coord, target, _fires_flat_beam(shooter)):
		return _trench_block_reason(shooter)

	var dist := Combat.distance(shooter.coord, target.coord)
	match shooter.stats.special_ability_id:
		MCF.ABILITY_MARKSMAN:
			# Лазер бьёт на любую дистанцию и пробивает препятствия (§3.13).
			return ""
		MCF.ABILITY_FLAMETHROWER:
			# Струя пламени 6 клеток, не проходит сквозь стену (§3.14).
			if dist > MCF.FLAME_JET_LENGTH:
				return "Too far for the flame jet"
			if _wall_between(shooter.coord, target.coord):
				return "Flame jet blocked by a wall"
			return ""

	# Люди на линии выстрел не запрещают (#100): пуля просто достанется первому из них,
	# см. first_unit_on_line(). Стена и корпус машины по-прежнему отменяют стрельбу.
	# Стекло — отдельный случай (#29): по цели ЗА стеклом стрелять можно, каждая пуля
	# пробует его пробить сама. Заряд противотанкиста в это исключение не входит.
	if los_blocked(shooter.coord, target.coord, not _is_anti_tank(shooter), true,
			not _is_anti_tank(shooter)):
		return "Firing line is blocked"
	# Стоящий за чужой спиной — не цель (batch soil-rulers): пуля и заряд ПТ всё равно
	# достались бы первому на линии (см. перехват в _resolve_shoot), а прицел, который
	# показывает заднего, обещал выстрел, которого в игре нет. Целиться — в того, кто ближе.
	if first_unit_on_line(shooter.coord, target.coord,
			shooter if not friendly_fire_enabled else null) != null:
		return "Another unit is in the way"
	if Combat.hit_number(dist, shooter.fire_range()) >= 7:
		return "Too far"
	return ""

## Окно под выстрел (batch ui-drones): видимая клетка со стеклом на линии огня и в
## пределах дальности. Спецстрелкам (противотанкист, огнемётчик, марксман) свой путь.
func can_shoot_window(shooter: UnitInstance, cell: Vector2i) -> String:
	if shooter.stats.special_ability_id in [MCF.ABILITY_ANTI_TANK, MCF.ABILITY_FLAMETHROWER,
			MCF.ABILITY_MARKSMAN, MCF.ABILITY_ASSAULT, MCF.ABILITY_MINER, MCF.ABILITY_SHIELD_BEARER]:
		return "This unit can't shoot at windows"
	if not state.grid.in_bounds(shooter.coord) or not state.grid.in_bounds(cell):
		return "No target"
	if not MCF.is_glass(state.grid.cell(cell).feature_id):
		return "No window there"
	if not Combat.is_on_firing_line(shooter.coord, cell):
		return "Target not on the firing line"
	if fog_enabled and not team_visible_coords(shooter.owner).has(cell):
		return "Target not visible"
	if los_blocked(shooter.coord, cell, true, true, true):
		return "Firing line is blocked"
	if Combat.hit_number(Combat.distance(shooter.coord, cell), shooter.fire_range()) >= 7:
		return "Too far"
	if shooter.remaining_ap <= 0:
		return "Unit has no AP left"
	return ""

## Окна, которые стрелок сейчас может разбить (для подсветки в режиме стрельбы).
func shootable_window_cells(shooter: UnitInstance) -> Array:
	var out: Array = []
	var reach := int(shooter.fire_range())
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var c := shooter.coord + Vector2i(dx, dy)
			if state.grid.in_bounds(c) and MCF.is_glass(state.grid.cell(c).feature_id) \
					and can_shoot_window(shooter, c) == "":
				out.append(c)
	return out

## Выстрел по окну: 1 ОД, очередь целиком. Обычное стекло бьётся сразу; бронестекло
## держит каждую пулю на 4+ (как и пробивая его по пути к цели, §29).
func _resolve_shoot_window(shooter: UnitInstance, cell: Vector2i) -> ActionResult:
	shooter.remaining_ap -= 1
	shooter.action_state = null
	var result := ActionResult.success()
	var gc := state.grid.cell(cell)
	var fired := maxi(1, shooter.rate_of_fire())
	# Окно держит каждую пулю спасброском (обычное 5+, бронестекло 4+), а не бьётся от
	# первой же — как раньше обычное стекло.
	var hold_need := MCF.glass_bullet_save(gc.feature_id)
	var broke := false
	for _i in fired:
		if broke:
			break
		var r := state.dice.roll_d6()
		result.dice_events.append({"kind": "check",
			"actor": MCF.FEATURE_NAMES.get(gc.feature_id, "Glass"),
			"roll": r, "need": hold_need, "ok": r >= hold_need})
		broke = r < hold_need
	_fx_lane(result, shooter.coord, cell, shooter.owner)
	_fx(result, {"fx": "casings", "at": shooter.coord, "toward": cell, "count": fired})
	_fx(result, {"fx": "tracer", "at": shooter.coord, "from": [shooter.coord.x, shooter.coord.y],
		"to": [cell.x, cell.y], "count": fired})
	if broke:
		gc.clear_feature()
		notify_cell_changed(cell)
		_fx(result, {"fx": "shards", "at": cell, "from": shooter.coord})
		_fx(result, {"fx": "debris", "at": NOWHERE, "cells": [cell]})
		result.log("%s shoots out the window at (%d, %d)" % [shooter.stats.display_name, cell.x, cell.y])
	else:
		result.log("%s fires at the %s at (%d, %d) — it holds" % [
			shooter.stats.display_name,
			String(MCF.FEATURE_NAMES.get(gc.feature_id, "glass")).to_lower(), cell.x, cell.y])
	return result

func _is_anti_tank(u: UnitInstance) -> bool:
	return u != null and u.stats.special_ability_id == MCF.ABILITY_ANTI_TANK

## Все, по кому стрелок может открыть огонь. Со времён #100 сюда попадают и СВОИ:
## дружественный огонь разрешён, и игрок должен видеть, что союзник тоже под прицелом.
## Прямая линия — необходимое условие ЛЮБОГО разрешённого выстрела: can_shoot() проверяет
## её раньше всех исключений, включая лазер марксмана и струю огнемёта. Поэтому целей,
## стоящих не на луче, можно отсеивать вычитанием векторов, не заходя в can_shoot() с её
## туманом, окопами и трассировкой. В бою на 200 бойцов так отваливаются девять из десяти.
func shootable_target_ids(shooter: UnitInstance) -> Array:
	var out: Array = []
	var from: Vector2i = shooter.coord
	var sid: int = shooter.id
	for u in state.all_units():
		if u.id == sid or not u.is_alive():
			continue
		# Экипаж танка (coord = OFFBOARD) на поле не стоит — целью не считается (#23);
		# пассажир челнока сидит в клетке следа и под прицелом (batch 13 S5).
		if not state.grid.in_bounds(u.coord):
			continue
		if not Combat.is_on_firing_line(from, u.coord):
			continue
		if can_shoot(shooter, u) == "":
			out.append(u.id)
	return out

## Только вражеские цели — то, что ищет ИИ и автонаведение. Своих сюда не пускаем,
## иначе «умный» ИИ начал бы расстреливать собственный взвод (#100).
## Своих отсеиваем ДО can_shoot(), а не после: половина армии — свои, и проверять их
## туман, окопы и линию огня только затем, чтобы тут же выбросить, значит удваивать
## работу. Отбор и порядок остаются теми же, что при фильтрации готового списка.
func hostile_target_ids(shooter: UnitInstance) -> Array:
	var out: Array = []
	var from: Vector2i = shooter.coord
	var sowner: int = shooter.owner
	var sid: int = shooter.id
	for u in state.all_units():
		if u.id == sid or not u.is_alive():
			continue
		# Не считаем целью СОЮЗНИКОВ: ни свой слот, ни товарища по команде, ни (для
		# нейтралов) другого нейтрала — ИИ не должен даже пытаться в них стрелять
		# (item 15 + запрос про ИИ-команды). is_ally_of покрывает все три случая.
		if is_ally_of(shooter, u):
			continue
		if not state.grid.in_bounds(u.coord):
			continue
		if not Combat.is_on_firing_line(from, u.coord):
			continue
		if can_shoot(shooter, u) == "":
			out.append(u.id)
	return out

## "" = противотанкист может ударить по этой клетке пола; иначе причина отказа (§3.14).
func can_blast_cell(shooter: UnitInstance, cell: Vector2i) -> String:
	if shooter.stats.special_ability_id != MCF.ABILITY_ANTI_TANK:
		return "Only the anti-tank can hit the ground"
	if not state.grid.in_bounds(cell):
		return "Target out of bounds"
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	var c := state.grid.cell(cell)
	if c.is_space:
		return "Can't hit space — no floor"
	# Выстрел под себя (#11): собственная клетка — законная цель. Проверять линию огня
	# и дистанцию до самого себя нечего, и is_on_firing_line на нулевом векторе всё
	# равно отвечает «нет», поэтому этот случай обязан отстреливаться первым.
	if cell == shooter.coord:
		return ""
	# Клетка с живым бойцом проверяется наравне с остальными. Раньше она пропускалась
	# сразу — «обычная стрельба это уже покрывает», — и мимо линии огня, стен и дальности
	# шёл любой удар по такой клетке: ИИ бил по корпусу машины через клетку пассажира
	# под любым углом и с любой дистанции, бросая заведомые 7+.
	if not Combat.is_on_firing_line(shooter.coord, cell):
		return "Target not on the firing line"
	# Заряд противотанкиста в амбразуру не пролезает (#86).
	if los_blocked(shooter.coord, cell, false):
		return "Firing line is blocked"
	if Combat.hit_number(Combat.distance(shooter.coord, cell), shooter.fire_range()) >= 7:
		return "Too far"
	return ""

## Пустые клетки пола, по которым противотанкист может ударить (для подсветки в UI).
func blastable_cells(shooter: UnitInstance) -> Array:
	var out: Array = []
	if shooter.stats.special_ability_id != MCF.ABILITY_ANTI_TANK:
		return out
	var reach := shooter.fire_range()
	# Собственная клетка — первой в списке (#11): она и есть «ударить под себя»,
	# и UI подсвечивает её наравне с остальными. Через ту же проверку, что и остальные:
	# стоящий на клетке космоса (без пола) ударить под себя не может, а список её
	# предлагал — перечислитель RL выдавал намерение, которое резолвер отклонял.
	if can_blast_cell(shooter, shooter.coord) == "":
		out.append(shooter.coord)
	for dy in range(-int(reach), int(reach) + 1):
		for dx in range(-int(reach), int(reach) + 1):
			var c := Vector2i(shooter.coord.x + dx, shooter.coord.y + dy)
			if c == shooter.coord:
				continue
			var cell := state.grid.cell(c) if state.grid.in_bounds(c) else null
			if cell == null or (cell.occupant != null and cell.occupant.is_alive()):
				continue
			if can_blast_cell(shooter, c) == "":
				out.append(c)
	return out

## "" = огнемётчик может пустить струю в направлении этой клетки; иначе причина отказа.
func can_flame_cell(shooter: UnitInstance, cell: Vector2i) -> String:
	if shooter.stats.special_ability_id != MCF.ABILITY_FLAMETHROWER:
		return "Only the flamethrower can spray the ground"
	if not state.grid.in_bounds(cell):
		return "Target out of bounds"
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	if cell == shooter.coord:
		return "Pick a cell in front"
	if state.grid.cell(cell).is_space:
		return "Can't ignite space"
	if not Combat.is_on_firing_line(shooter.coord, cell):
		return "Target not on the firing line"
	if Combat.distance(shooter.coord, cell) > MCF.FLAME_JET_LENGTH:
		return "Too far for the flame jet"
	return ""

## Пустые клетки пола, по которым огнемётчик может пустить струю (для подсветки в UI).
func flammable_cells(shooter: UnitInstance) -> Array:
	var out: Array = []
	if shooter.stats.special_ability_id != MCF.ABILITY_FLAMETHROWER:
		return out
	var reach := MCF.FLAME_JET_LENGTH
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var c := Vector2i(shooter.coord.x + dx, shooter.coord.y + dy)
			if c == shooter.coord:
				continue
			var cell := state.grid.cell(c) if state.grid.in_bounds(c) else null
			if cell == null or (cell.occupant != null and cell.occupant.is_alive()):
				continue
			if can_flame_cell(shooter, c) == "":
				out.append(c)
	return out

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
	if unit.remaining_ap <= 0 and credit <= 0:
		return "Unit has no AP left"
	return ""

# ============================================================================
#  ТЕХНИКА (§техника): экипаж, движение, пушка, лазер, уничтожение.
# ============================================================================

# --- Борг (batch 13, «Borg characteristics») ----------------------------------------
## Одноместная машина 1×1, которой управляют как бойцом. Оператор ОСТАЁТСЯ на сетке в
## клетке борга (borg_id != -1), ходит/стреляет обычными намерениями, но с числами
## борга (UnitInstance.speed()/armor()/fire_range()/rate_of_fire()/max_ap()). Пока внутри
## живой оператор, след борга на сетке НЕ размечен — машина прозрачна для линий, как
## боец (B14); пустой борг или борг с мёртвым оператором размечен как корпус, чтобы его
## можно было выбрать и в него сесть.
func _board_borg(unit: UnitInstance, veh: Vehicle) -> ActionResult:
	var err := _borg_entry_error(unit, veh)
	if err != "":
		return ActionResult.fail(err)
	var cell := state.grid.cell(veh.origin)
	# Мёртвый оператор выталкивается наружу при посадке (B12) — на свободную клетку рядом.
	if cell.occupant != null:
		var spot := _borg_push_spot(unit, veh)
		var body: UnitInstance = cell.occupant
		cell.occupant = null
		body.borg_id = -1
		body.coord = spot
		state.grid.cell(spot).occupant = body
	# Посадка бесплатна (batch 17, item 3): свежий боец садится и видит все 3 ОД борга.
	state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
	state.grid.cell(unit.coord).occupant = null
	unit.coord = veh.origin
	cell.occupant = unit
	unit.borg_id = veh.id
	veh.occupants = [unit.id]
	var captured := veh.owner != unit.owner
	veh.owner = unit.owner
	# Новая активация борга — новые очки: боец получает 3 ОД, но уже потраченные до
	# посадки не возвращаются.
	unit.remaining_ap = maxi(0, unit.remaining_ap + (unit.max_ap() - (unit.stats.action_points
			if unit.stats.action_points > 0 else MCF.AP_PER_ACTIVATION)))
	var res := ActionResult.new()
	res.ok = true
	res.log("%s %s the borg [AP: %d]" % [unit.stats.display_name,
		"seizes" if captured else "climbs into", unit.remaining_ap])
	return res

## Почему боец не сядет в борг ("" — сядет). Одна проверка и для посадки, и для списка
## boardable_vehicles: раньше список проверял только «жив ли оператор», и борг, чьего
## оператора взяли в плен (HELD — не жив, но и не труп, лежит в клетке), предлагался
## перечислителю RL, а посадку резолвер отклонял: «The borg's cell is blocked».
func _borg_entry_error(unit: UnitInstance, veh: Vehicle) -> String:
	var op := state.get_unit(veh.borg_operator())
	if op != null and op.is_alive():
		return "Someone is already at the controls"
	var cell := state.grid.cell(veh.origin)
	if cell.occupant != null:
		if cell.occupant.status != MCF.Status.CORPSE:
			return "The borg's cell is blocked"
		if _borg_push_spot(unit, veh) == NOWHERE:
			return "No room to push the body out"
	return ""

## Свободная соседняя клетка, куда при посадке выталкивается мёртвый оператор (B12).
func _borg_push_spot(unit: UnitInstance, veh: Vehicle) -> Vector2i:
	for n in state.grid.neighbors(veh.origin):
		if n == unit.coord:
			continue
		var nc := state.grid.cell(n)
		if nc != null and nc.occupant == null and not nc.is_wall() and not nc.is_space \
				and nc.vehicle_id == -1 and nc.corpse_count < MCF.CORPSE_WALL_COUNT:
			return n
	return NOWHERE

func _exit_borg(unit: UnitInstance, veh: Vehicle, target: Vector2i) -> ActionResult:
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	if Combat.distance(unit.coord, target) != 1 or state.grid.blocks_walk(target):
		return ActionResult.fail("Step out to a free cell next to the borg")
	unit.remaining_ap -= 1
	state.grid.cell(unit.coord).occupant = null
	unit.borg_id = -1
	veh.occupants = []
	veh.origin = unit.coord
	state.grid.set_vehicle_footprint(veh.id, veh.footprint())
	state.grid.place(unit, target)
	# Вне борга у бойца снова его собственный потолок ОД.
	unit.remaining_ap = mini(unit.remaining_ap, unit.max_ap())
	return ActionResult.success(["%s climbs out of the borg [AP: %d]" % [
		unit.stats.display_name, unit.remaining_ap]])

## Борг следует за своим оператором: любое перемещение бойца (ход, отброс, перенос)
## переносит и машину. Зовётся после каждого разрешённого намерения.
func _sync_borg(unit: UnitInstance) -> void:
	if unit == null or unit.borg_id == -1:
		return
	var veh := state.get_vehicle(unit.borg_id)
	if veh != null and state.grid.in_bounds(unit.coord):
		veh.origin = unit.coord

func _sync_borgs() -> void:
	for veh: Vehicle in state.all_vehicles():
		if not veh.is_borg():
			continue
		var op := state.get_unit(veh.borg_operator())
		if op != null and state.grid.in_bounds(op.coord):
			veh.origin = op.coord

## Борг, в котором сидит боец; null — не в борге.
func borg_of(u: UnitInstance) -> Vehicle:
	if u == null or u.borg_id == -1:
		return null
	return state.get_vehicle(u.borg_id)

# --- Челнок с посадочными местами (batch 13, «Shuttle changes») ---------------------
## Пассажир челнока сидит В КЛЕТКЕ следа: у него настоящая координата, он occupant
## своей клетки, виден поверх корпуса, стреляет со своего места и сам под обстрелом.
## Экипаж танка по-прежнему вынесен за поле (OFFBOARD). Что позволено из кресла:
func _aboard_allowed(intent: Intent) -> bool:
	return intent is ShootIntent or intent is CancelShotIntent or intent is UseItemIntent \
			or intent is SpawnDroneIntent or intent is PickUpStationIntent \
			or intent is VehicleSeatIntent or intent is VehicleDisembarkIntent \
			or intent is EndTurnIntent or intent is ReleaseIntent

func _seated(veh: Vehicle) -> bool:
	return veh != null and veh.seated()

## Машина, в которой юнит сидит пассажиром (челнок), либо null.
func seated_vehicle_of(u: UnitInstance) -> Vehicle:
	if u == null or u.aboard_vehicle_id == -1:
		return null
	var veh := state.get_vehicle(u.aboard_vehicle_id)
	return veh if _seated(veh) else null

## Водитель челнока: живой боец стороны-владельца в кресле водителя, иначе null.
func shuttle_driver(veh: Vehicle) -> UnitInstance:
	if not _seated(veh):
		return null
	var d := state.get_unit(veh.driver_id())
	if d == null or not d.is_alive() or d.owner != veh.owner:
		return null
	return d

## Очки действия, которыми машина располагает СЕЙЧАС: у танка — свой пул, у челнока —
## ОД водителя (машина ходит за его счёт, batch 13 S1).
func vehicle_ap(veh: Vehicle) -> int:
	if veh == null or not veh.alive():
		return 0
	if _seated(veh):
		var d := shuttle_driver(veh)
		return d.remaining_ap if d != null else 0
	return veh.ap

## Посадить пассажира в кресло seat: клетка следа становится его клеткой. Труп,
## лежавший на полу под креслом, уходит в кучу corpse_count той же клетки.
func _seat_unit(veh: Vehicle, unit: UnitInstance, seat: int) -> void:
	veh.ensure_seats()
	var cell_coord := veh.seat_cell(seat)
	var cell := state.grid.cell(cell_coord)
	if cell.occupant != null and cell.occupant.status == MCF.Status.CORPSE:
		state.units.erase(cell.occupant.id)
		cell.occupant = null
		cell.corpse_count += 1
	veh.seats[seat] = unit.id
	unit.coord = cell_coord
	unit.aboard_vehicle_id = veh.id
	cell.occupant = unit

## Клетка кресла, в котором сидит юнит; NOWHERE, если он не пассажир.
func seat_cell_of(u: UnitInstance) -> Vector2i:
	var veh := seated_vehicle_of(u)
	if veh == null:
		return NOWHERE
	var si := veh.seat_of(u.id)
	return veh.seat_cell(si) if si != -1 else NOWHERE

## Пересадка внутри челнока (S6): 1 ОД, только в свободное кресло.
func _resolve_vehicle_seat(intent: VehicleSeatIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	var veh := seated_vehicle_of(unit)
	if veh == null:
		return ActionResult.fail("Not aboard a shuttle")
	veh.ensure_seats()
	if intent.seat < 0 or intent.seat >= veh.seats.size():
		return ActionResult.fail("No such seat")
	if veh.seats[intent.seat] != -1:
		return ActionResult.fail("That seat is taken")
	var from := veh.seat_of(unit.id)
	if from == intent.seat:
		return ActionResult.fail("Already in that seat")
	unit.remaining_ap -= 1
	state.grid.cell(unit.coord).occupant = null
	veh.seats[from] = -1
	_seat_unit(veh, unit, intent.seat)
	var res := ActionResult.success(["%s moves to the %s seat [AP: %d]" % [
		unit.stats.display_name, "driver's" if intent.seat == Vehicle.DRIVER_SEAT else "next",
		unit.remaining_ap]])
	return res

## Сколько клеток челнок может проехать сейчас: остаток прошлого переезда плюс
## 15 за каждое ОД водителя (batch 13 S1). Без водителя — только остаток, и тот ноль.
func _shuttle_budget(veh: Vehicle) -> int:
	var d := shuttle_driver(veh)
	if d == null:
		return 0
	return veh.move_credit + d.remaining_ap * MCF.SHUTTLE_CELLS_PER_AP

## Оператор, чья станция стоит в кресле этой машины (первый оператор на борту).
func _station_operator_aboard(veh: Vehicle) -> int:
	for uid in veh.occupants:
		var u := state.get_unit(uid)
		if u != null and u.is_alive() and u.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR:
			return u.id
	return -1

## Кресла, в которые юнит может сесть/пересесть (для UI): индексы свободных мест.
func seat_options(veh: Vehicle) -> Array[int]:
	if not _seated(veh):
		return []
	return veh.free_seats()

## Пассажиры под ударом тяжёлого оружия (S5): тот, чья клетка — точка разрыва, гибнет
## без броска; остальные пассажиры этой машины в зоне бросают обычную защиту.
## Возвращает имена погибших; кубики пишутся в res.
func _shuttle_passengers_hit(veh: Vehicle, center: Vector2i, in_area: Dictionary,
		res: ActionResult) -> Array:
	var killed: Array = []
	for uid in veh.occupants.duplicate():
		var u := state.get_unit(uid)
		if u == null or not u.is_alive():
			continue
		if u.coord == center:
			_kill(u, res, center, true)
			killed.append(u.stats.display_name)
			if res != null:
				res.deaths.append(u.id)
			if res != null:
				res.log("%s takes the hit square on — killed." % u.stats.display_name)
			continue
		if not in_area.has(u.coord):
			continue
		var need := u.armor()
		var roll := state.dice.roll_d6()
		var ok := roll >= need
		if res != null:
			res.dice_events.append({"kind": "check", "actor": "%s (passenger)" % u.stats.display_name,
				"roll": roll, "need": need, "ok": ok, "roller": u.owner})
		if not ok:
			_kill(u, res, center, true)
			killed.append(u.stats.display_name)
			if res != null:
				res.deaths.append(u.id)
			if res != null:
				res.log("%s (passenger) fails the defence roll (%d, need %d+) — killed." % [
					u.stats.display_name, roll, need])
		elif res != null:
			res.log("%s (passenger) holds on (roll %d, need %d+)." % [u.stats.display_name, roll, need])
	return killed

const DIR8 := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## Танк ходит и целится ТОЛЬКО по четырём сторонам света (item 2): диагональные
## развороты и стрельба по диагонали убраны. Пушка и так била лишь по прямой
## (cannon_port), а фронт теперь тоже ограничен ортогональю.
const DIR4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## «Клетка» экипажа внутри машины — вне поля, чтобы любые проверки по координатам
## (обзор/дальность/цели) автоматически исключали пассажиров (§техника).
const OFFBOARD := Vector2i(-9999, -9999)

func _validate_vehicle(veh: Vehicle, credit: int = 0) -> String:
	if veh == null:
		return "Vehicle not found"
	if not veh.alive():
		return "Vehicle is destroyed"
	# Боргом (batch 13) правят намерения ОПЕРАТОРА — Move/Shoot от его имени. Машинные
	# намерения ему не адресуются: после смены раунда у борга появлялось своё «ОД
	# экипажа», VehicleMoveIntent катил корпус отдельно от бойца и оставлял на клетке
	# назначения след без машины.
	if veh.is_borg():
		return "A borg is driven by its operator"
	if veh.owner != state.active_player():
		return "It's the other player's turn"
	if vehicle_ap(veh) <= 0 and credit <= 0:
		return "Nobody at the wheel with AP left" if _seated(veh) else "Vehicle has no crew AP left"
	return ""

## Свободна ли клетка соседняя со следом машины (для посадки/высадки).
func _adjacent_to_vehicle(coord: Vector2i, veh: Vehicle) -> bool:
	for fc in veh.footprint():
		if Combat.distance(coord, fc) == 1:
			return true
	return false

func _is_miner(u: UnitInstance) -> bool:
	return u != null and u.stats.special_ability_id == MCF.ABILITY_MINER

## Шахтёр бьёт ломом по соседней вражеской машине (item 15): один бросок d6, на
## MINER_VEHICLE_HIT_NEED корпус теряет MINER_VEHICLE_DAMAGE прочности. Стоит 1 ОД
## независимо от исхода — замах уже сделан. Своих машин шахтёр не портит.
func _resolve_vehicle_melee(intent: VehicleMeleeIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if not _is_miner(unit):
		return ActionResult.fail("Only a miner can pry at a hull")
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	var veh := state.get_vehicle(intent.vehicle_id)
	if veh == null or not veh.alive():
		return ActionResult.fail("No such vehicle")
	if veh.owner == unit.owner:
		return ActionResult.fail("That's your own vehicle")
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	unit.remaining_ap -= 1
	var res := ActionResult.new()
	res.ok = true
	var veh_name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	var roll := state.dice.roll_d6()
	var hit := roll >= MCF.MINER_VEHICLE_HIT_NEED
	res.dice_events.append({
		"kind": "check", "actor": "%s pries the hull" % unit.stats.display_name,
		"roll": roll, "need": MCF.MINER_VEHICLE_HIT_NEED, "ok": hit,
	})
	if hit:
		res.log("%s wrenches the %s (roll %d, need %d+)!" % [
			unit.stats.display_name, veh_name, roll, MCF.MINER_VEHICLE_HIT_NEED])
		# Шахтёр ковыряет ИМЕННО КОРПУС (§5): ни выбора узла, ни каскада — он лезет
		# монтировкой под броневой лист, а не выцеливает башню.
		_damage_component(veh, MCF.COMP_HULL, MCF.MINER_VEHICLE_DAMAGE, "miner", res)
	else:
		res.log("%s strikes the %s but the hull holds (roll %d, need %d+)." % [
			unit.stats.display_name, veh_name, roll, MCF.MINER_VEHICLE_HIT_NEED])
	return res

## Ремонт узла машины инженером (веха «Modular tank system», §8).
##
## 1 ОД — одно очко прочности любому узлу на выбор, не выше его стартового значения.
## Узел, вернувшийся выше нуля, ТУТ ЖЕ снова работает: отдельного «включения» нет —
## починил ходовую, и машина в этот же ход поедет.
##
## Чего ремонт НЕ умеет: поднимать машину с разбитым корпусом. Корпус на нуле — это
## конец, а не поломка: экипаж погиб, машина сгорела и осталась на поле обломком.
## Чинить чужую технику тоже нельзя — инженер обслуживает свою армию, а не любую броню,
## до которой смог дойти.
func _resolve_repair_vehicle(intent: RepairVehicleIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if unit.stats.special_ability_id != MCF.ABILITY_ENGINEER:
		return ActionResult.fail("Only an engineer can repair a vehicle")
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	if unit.aboard_vehicle_id != -1:
		return ActionResult.fail("Step out of the vehicle to work on it")
	var veh := state.get_vehicle(intent.vehicle_id)
	if veh == null:
		return ActionResult.fail("No such vehicle")
	if not veh.alive():
		return ActionResult.fail("The hull is gone — nothing left to repair")
	if veh.owner != unit.owner and not state.roster.are_allies(veh.owner, unit.owner):
		return ActionResult.fail("That's not your vehicle")
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	var comp: String = intent.component
	if not veh.has_component(comp):
		return ActionResult.fail("This vehicle has no such component")
	var cap := veh.component_max(comp)
	if veh.component(comp) >= cap:
		return ActionResult.fail("%s is already sound" % MCF.COMPONENT_NAMES.get(comp, comp))
	unit.remaining_ap -= 1
	var was := veh.component(comp)
	veh.components[comp] = mini(cap, was + 1)
	var res := ActionResult.new()
	res.ok = true
	var veh_name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	var label: String = MCF.COMPONENT_NAMES.get(comp, comp)
	res.log("%s repairs the %s's %s (%d → %d) [AP: %d]" % [
		unit.stats.display_name, veh_name, label, was, veh.component(comp),
		unit.remaining_ap])
	if was == 0:
		res.log("%s: %s is back in service." % [veh_name, label])
	return res

## Узлы машины, которые инженер может починить прямо сейчас — для меню и подсветки.
## Условия ДОСЛОВНО те же, что проверяет _resolve_repair_vehicle.
func repairable_components(unit: UnitInstance, veh: Vehicle) -> Array:
	var out: Array = []
	if unit == null or veh == null or not veh.alive():
		return out
	if unit.stats.special_ability_id != MCF.ABILITY_ENGINEER or unit.remaining_ap <= 0:
		return out
	if unit.aboard_vehicle_id != -1 or not _adjacent_to_vehicle(unit.coord, veh):
		return out
	if veh.owner != unit.owner and not state.roster.are_allies(veh.owner, unit.owner):
		return out
	for comp: String in MCF.COMPONENT_ORDER:
		if veh.has_component(comp) and veh.component(comp) < veh.component_max(comp):
			out.append(comp)
	return out

## Машины рядом с инженером, которым есть что чинить (для кнопки в меню).
func repairable_vehicles(unit: UnitInstance) -> Array:
	var out: Array = []
	for veh: Vehicle in state.all_vehicles():
		if not repairable_components(unit, veh).is_empty():
			out.append(veh)
	return out

## Вытащить труп из машины на свободную соседнюю клетку (item 18): павший экипаж
## занимает место, его выгружают, чтобы освободить слот. Стоит 1 ОД.
func _resolve_vehicle_unload_corpse(intent: VehicleUnloadCorpseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	var veh := state.get_vehicle(intent.vehicle_id)
	if veh == null or not veh.alive():
		return ActionResult.fail("No such vehicle")
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	if _seated(veh):
		# Тело в кресле челнока (batch 13 S10): вытаскивают снаружи, стоя рядом с клеткой
		# этого кресла; труп ложится к ногам вытащившего.
		var seat := -1
		for i in veh.seats.size():
			var sid: int = veh.seats[i]
			if sid < 0:
				continue
			var body := state.get_unit(sid)
			if body != null and body.status == MCF.Status.CORPSE \
					and Combat.distance(unit.coord, veh.seat_cell(i)) == 1:
				seat = i
				break
		if seat == -1:
			return ActionResult.fail("No body in a seat next to you")
		var spot_s := NOWHERE
		for n in state.grid.neighbors(unit.coord):
			var nc := state.grid.cell(n)
			if nc != null and nc.occupant == null and not nc.is_wall() and not nc.is_space \
					and nc.vehicle_id == -1 and nc.corpse_count < MCF.CORPSE_WALL_COUNT:
				spot_s = n
				break
		if spot_s == NOWHERE:
			return ActionResult.fail("No room beside you to set the body down")
		unit.remaining_ap -= 1
		var corpse := state.get_unit(veh.seats[seat])
		state.grid.cell(corpse.coord).occupant = null
		veh.seats[seat] = -1
		corpse.aboard_vehicle_id = -1
		corpse.coord = spot_s
		state.grid.cell(spot_s).occupant = corpse
		notify_cell_changed(spot_s)
		return ActionResult.success(["%s pulls %s's body out of the %s to (%d, %d)." % [
			unit.stats.display_name, corpse.stats.display_name,
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), spot_s.x, spot_s.y]])
	if veh.corpse_slots.is_empty():
		return ActionResult.fail("No bodies to pull out")
	# Свободная клетка рядом с бойцом — куда положить тело.
	var spot := NOWHERE
	for n in state.grid.neighbors(unit.coord):
		var nc := state.grid.cell(n)
		if nc != null and nc.occupant == null and not nc.is_wall() and not nc.is_space \
				and nc.corpse_count < MCF.CORPSE_WALL_COUNT:
			spot = n
			break
	if spot == NOWHERE:
		return ActionResult.fail("No room beside you to set the body down")
	unit.remaining_ap -= 1
	var name: String = veh.corpse_slots.pop_back()
	state.grid.cell(spot).corpse_count += 1
	notify_cell_changed(spot)
	return ActionResult.success(["%s pulls %s's body out of the %s at (%d, %d)." % [
		unit.stats.display_name, name,
		VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), spot.x, spot.y]])

## Соседние машины, из которых боец может вытащить труп (для UI, item 18): свои/чужие
## рядом, у которых есть трупы в слотах и куда есть куда положить тело.
func unloadable_corpse_vehicle_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	if actor == null or actor.remaining_ap <= 0 or actor.aboard_vehicle_id != -1:
		return out
	var has_spot := false
	for n in state.grid.neighbors(actor.coord):
		var nc := state.grid.cell(n)
		if nc != null and nc.occupant == null and not nc.is_wall() and not nc.is_space:
			has_spot = true
			break
	if not has_spot:
		return out
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or not _adjacent_to_vehicle(actor.coord, veh):
			continue
		if _seated(veh):
			for i in veh.seats.size():
				var sid: int = veh.seats[i]
				var body := state.get_unit(sid) if sid >= 0 else null
				if body != null and body.status == MCF.Status.CORPSE \
						and Combat.distance(actor.coord, veh.seat_cell(i)) == 1:
					out.append(veh.id)
					break
		elif not veh.corpse_slots.is_empty():
			out.append(veh.id)
	return out

## Соседние вражеские машины, по которым шахтёр может ударить (для подсветки в UI).
## Возвращает id машин. Пусто для не-шахтёра или без ОД.
func meleeable_vehicle_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	if not _is_miner(actor) or actor.remaining_ap <= 0:
		return out
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and veh.owner != actor.owner and _adjacent_to_vehicle(actor.coord, veh):
			out.append(veh.id)
	return out

# --- Посадка экипажа/пассажира ---
func _resolve_vehicle_board(intent: VehicleBoardIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var veh := state.get_vehicle(intent.vehicle_id)
	# Посадка в челнок и борг бесплатна (batch 17, items 1, 3): разрешена и при 0 ОД.
	var err := _validate_actor(unit, 1 if veh != null and (_seated(veh) or veh.is_borg()) else 0)
	if err != "":
		return ActionResult.fail(err)
	if unit.aboard_vehicle_id != -1:
		return ActionResult.fail("Already aboard a vehicle")
	# Оператор борга сперва выходит из него (batch 13): иначе боец уезжал в танк с
	# borg_id на руках, борг оставался «занятым» и при высадке телепортировался к нему.
	if unit.borg_id != -1:
		return ActionResult.fail("Climb out of the borg first")
	if veh == null or not veh.alive():
		return ActionResult.fail("No such vehicle")
	# Щитоносцу и несущему трупы в машине не место (item 19): щит и груз внутрь не лезут.
	if _is_shield(unit):
		return ActionResult.fail("A shield-bearer can't fit inside a vehicle")
	if unit.carried_corpses > 0:
		return ActionResult.fail("Drop the corpses before boarding")
	# Можно садиться и во вражескую технику (§техника, захват экипажа).
	if not _adjacent_to_vehicle(unit.coord, veh):
		return ActionResult.fail("Must stand next to the vehicle")
	if veh.is_borg():
		return _board_borg(unit, veh)
	if _seated(veh):
		# Челнок (batch 13): садятся в конкретное кресло — выбранное или первое свободное.
		veh.ensure_seats()
		var seat := intent.seat if intent.seat >= 0 else veh.first_free_seat()
		if seat < 0 or seat >= veh.seats.size() or veh.seats[seat] != -1:
			return ActionResult.fail("That seat is taken — pull the body out or pick another")
		var boarding_enemy_s: bool = veh.owner != unit.owner
		state.grid.cell(unit.coord).occupant = null
		veh.occupants.append(unit.id)
		_seat_unit(veh, unit, seat)
		var captured_s := _recompute_vehicle_owner(veh)
		var res_s := ActionResult.new()
		res_s.ok = true
		var vname: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
		if captured_s:
			res_s.captured_vehicles.append(veh.id)
			res_s.log("%s seizes control of the %s!" % [unit.stats.display_name, vname])
		elif boarding_enemy_s:
			res_s.log("%s storms aboard the enemy %s!" % [unit.stats.display_name, vname])
		else:
			res_s.log("%s takes %s seat of the %s." % [unit.stats.display_name,
				"the driver's" if seat == Vehicle.DRIVER_SEAT else "a", vname])
		return res_s
	if veh.slots_used() >= veh.capacity():
		return ActionResult.fail("Vehicle is full — pull a corpse out to make room")

	var boarding_enemy: bool = veh.owner != unit.owner
	unit.remaining_ap -= 1
	# Убрать юнита с сетки — он внутри машины, «припаркован» вне поля.
	state.grid.cell(unit.coord).occupant = null
	unit.coord = OFFBOARD
	unit.aboard_vehicle_id = veh.id
	veh.occupants.append(unit.id)
	# Захват: если сторона нового экипажа теперь преобладает на борту — машина
	# переходит к ней, и она может водить/стрелять как своей (§техника).
	var captured := _recompute_vehicle_owner(veh)
	# ОД машины считаем только по экипажу-владельцу — чужаки не дают ходов машине.
	# Севший добавляет СВОЁ очко, но потраченные машиной НЕ возвращает (item 4:
	# «yellow circles on tanks don't disappear when action points are spent»). Здесь
	# стоял полный пересчёт по числу экипажа — то есть посадка посреди хода возвращала
	# танку всё, что он уже истратил: проехал, отстрелялся, подобрал пехотинца — и снова
	# полон очков, с той же гроздью жёлтых точек на борту.
	veh.ap = mini(veh.ap + 1, _vehicle_crew_ap(veh))
	var res := ActionResult.new()
	res.ok = true
	var veh_name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	if captured:
		res.captured_vehicles.append(veh.id)
		res.log("%s seizes control of the %s!" % [unit.stats.display_name, veh_name])
	elif boarding_enemy:
		res.log("%s storms aboard the enemy %s!" % [unit.stats.display_name, veh_name])
	else:
		res.log("%s boards the %s (crew %d/%d)." % [unit.stats.display_name,
			veh_name, veh.slots_used(), veh.capacity()])
	return res

## Пересчитать владельца машины по числу ЖИВЫХ членов экипажа каждой стороны.
## Сторона со строгим большинством на борту забирает машину; при равенстве
## владелец не меняется; пустая машина сохраняет прежнего владельца.
## Возвращает true, если владелец сменился (захват).
func _recompute_vehicle_owner(veh: Vehicle) -> bool:
	var counts: Dictionary = {}
	for uid in veh.occupants:
		var u := state.get_unit(uid)
		if u != null and u.is_alive():
			counts[u.owner] = int(counts.get(u.owner, 0)) + 1
	if counts.is_empty():
		return false
	var best_owner: int = veh.owner
	var best: int = int(counts.get(veh.owner, 0))
	for o in counts:
		if int(counts[o]) > best:
			best = int(counts[o])
			best_owner = o
	if best_owner != veh.owner:
		veh.owner = best_owner
		return true
	return false

## ОД машины = число ЖИВЫХ членов экипажа-владельца на борту (чужаки не в счёт).
## Остаток движения, которым машина реально может воспользоваться (#97). Без живого
## экипажа она не катится вовсе: очки скорости могли остаться с прошлого действия, но
## водить их некому — иначе подбитый экипаж «доезжал» бы уже мёртвым.
func vehicle_move_credit(veh: Vehicle) -> int:
	if veh == null or not veh.alive():
		return 0
	# Челнок докатывает остаток только пока за рулём кто-то живой (batch 13).
	if _seated(veh):
		return veh.move_credit if shuttle_driver(veh) != null else 0
	if _vehicle_crew_ap(veh) <= 0:
		return 0
	return veh.move_credit

func _vehicle_crew_ap(veh: Vehicle) -> int:
	# У челнока собственного пула нет — он ходит за ОД водителя (batch 13 S1).
	if _seated(veh):
		return 0
	var n := 0
	for uid in veh.occupants:
		var u := state.get_unit(uid)
		if u != null and u.is_alive() and u.owner == veh.owner:
			n += 1
	return n

# --- Высадка ---
func _resolve_vehicle_disembark(intent: VehicleDisembarkIntent) -> ActionResult:
	if not disembark_enabled:
		return ActionResult.fail("Crews are sealed in on this map")
	var unit := state.get_unit(intent.actor_id)
	if unit == null or not unit.is_alive():
		return ActionResult.fail("Unit not found")
	if unit.aboard_vehicle_id == -1 and unit.borg_id == -1:
		return ActionResult.fail("Not aboard a vehicle")
	if unit.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")
	var veh := state.get_vehicle(unit.aboard_vehicle_id if unit.aboard_vehicle_id != -1 else unit.borg_id)
	if veh == null:
		return ActionResult.fail("Vehicle gone")
	if veh.is_borg():
		return _exit_borg(unit, veh, intent.target)
	if _seated(veh):
		# Из челнока выходят БЕСПЛАТНО, через свой борт (batch 13 S7): на любую свободную
		# клетку рядом с клеткой своего кресла.
		var seat_c := seat_cell_of(unit)
		if seat_c == NOWHERE or Combat.distance(seat_c, intent.target) != 1:
			return ActionResult.fail("Step out next to your own seat")
		if state.grid.is_occupied_or_wall(intent.target) or state.grid.vehicle_at(intent.target) != -1:
			return ActionResult.fail("That cell is blocked")
		if unit.is_held():
			return ActionResult.fail("Unit is being held")
		veh.occupants.erase(unit.id)
		var si_s := veh.seat_of(unit.id)
		if si_s != -1:
			veh.seats[si_s] = -1
		state.grid.cell(unit.coord).occupant = null
		unit.aboard_vehicle_id = -1
		state.grid.place(unit, intent.target)
		_recompute_vehicle_owner(veh)
		var res_s := ActionResult.new()
		res_s.ok = true
		res_s.log("%s climbs out of the %s (free)." % [unit.stats.display_name,
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)])
		return res_s
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	if not _adjacent_to_vehicle(intent.target, veh):
		return ActionResult.fail("Must step out next to the vehicle")
	if state.grid.is_occupied_or_wall(intent.target):
		return ActionResult.fail("That cell is blocked")

	unit.remaining_ap -= 1
	veh.occupants.erase(unit.id)
	var si := veh.seat_of(unit.id)
	if si != -1:
		veh.seats[si] = -1
	unit.aboard_vehicle_id = -1
	state.grid.place(unit, intent.target)
	_recompute_vehicle_owner(veh)
	veh.ap = mini(veh.ap, _vehicle_crew_ap(veh))
	var res := ActionResult.new()
	res.ok = true
	res.log("%s disembarks the %s." % [unit.stats.display_name,
		VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)])
	return res

# --- Поворот танка ---
func _resolve_vehicle_turn(intent: VehicleTurnIntent) -> ActionResult:
	var veh := state.get_vehicle(intent.actor_id)
	var err := _validate_vehicle(veh)
	if err != "":
		return ActionResult.fail(err)
	if veh.facing == Vector2i.ZERO:
		return ActionResult.fail("This vehicle has no facing")
	# Развернуться можно, пока цела ХОТЬ ОДНА гусеница (веха 14.1): танк крутится на
	# месте, тормозя одной стороной. Обе порваны — машина стоит намертво.
	if not veh.can_turn():
		return ActionResult.fail("Both tracks are knocked out")
	# Только четыре стороны света (item 2): диагональный разворот запрещён.
	if not DIR4.has(intent.facing):
		return ActionResult.fail("Tanks turn only up/down/left/right")
	if intent.facing == veh.facing:
		return ActionResult.fail("Already facing that way")
	veh.ap -= VehicleRules.TURN_COST
	veh.facing = intent.facing
	var res := ActionResult.new()
	res.ok = true
	res.log("%s turns to face (%d, %d). (AP %d)" % [
		VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
		veh.facing.x, veh.facing.y, veh.ap])
	return res

# --- Движение техники ---
func _resolve_vehicle_move(intent: VehicleMoveIntent) -> ActionResult:
	var veh := state.get_vehicle(intent.actor_id)
	var credit := vehicle_move_credit(veh)
	var err := _validate_vehicle(veh, credit)
	if err != "":
		return ActionResult.fail(err)
	# А вот ЕХАТЬ нужны обе: на одной гусенице машина только крутится.
	if not veh.can_drive():
		return ActionResult.fail("A broken track — the vehicle cannot drive")
	var dir: Vector2i = intent.dir
	if veh.facing != Vector2i.ZERO and dir != veh.facing and dir != -veh.facing:
		return ActionResult.fail("Tank can only drive along its facing")
	# Недокатанные очки прошлого движения тратятся первыми и ОД не стоят (#97, §3.2).
	var use_credit := credit > 0
	var speed := credit if use_credit \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	# Челнок (batch 13 S1): бюджет — остаток плюс 15 клеток за каждое ОД водителя; за
	# один переезд можно потратить и несколько его ОД.
	var seated := _seated(veh)
	var driver := shuttle_driver(veh)
	# Танк может уехать в оранжевую/красную зону одним переездом (batch ui-drones 2):
	# бюджет — потолок дальней зоны, списание — по зоне, куда влезла цена пути.
	var tank_tiers := vehicle_tier_budgets(veh)
	if seated:
		speed = _shuttle_budget(veh)
	elif not tank_tiers.is_empty():
		speed = tank_tiers[tank_tiers.size() - 1]
	var plan := VehicleRules.plan_line_move(state, veh, dir, intent.steps, speed)
	if not plan["ok"]:
		return ActionResult.fail(String(plan["reason"]))

	# Пассажиры челнока едут в своих креслах (batch 13): на время переезда снимаем их
	# с клеток, иначе зачистка следа приняла бы их за раздавленных. Станция в кресле
	# тоже едет с машиной.
	var riders: Array = []
	var station_seats: Array[int] = []
	var station_from: Dictionary = {}  # seat -> прежняя клетка станции (для дронов)
	if seated:
		for i in veh.seats.size():
			var sid: int = veh.seats[i]
			if sid == Vehicle.SEAT_STATION:
				station_seats.append(i)
				station_from[i] = veh.seat_cell(i)
				var sc := state.grid.cell(veh.seat_cell(i))
				if sc.feature_id == MCF.FEATURE_DRONE_STATION:
					sc.feature_id = ""
					sc.cover_height = 0.0
			elif sid >= 0:
				var ru := state.get_unit(sid)
				if ru != null:
					riders.append([i, ru])
					var rc := state.grid.cell(ru.coord)
					if rc != null and rc.occupant == ru:
						rc.occupant = null
	# Снять старый след.
	state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
	var res := ActionResult.new()
	res.ok = true
	# Раздавленные юниты гибнут (§техника, таблица столкновений).
	var crushed: Array[UnitInstance] = []
	for cc in plan["crush_cells"]:
		var occ: UnitInstance = state.grid.cell(cc).occupant
		if occ != null and occ.is_alive():
			_kill(occ, res, cc, true)
			crushed.append(occ)
			res.deaths.append(occ.id)
			res.log("%s crushed under the %s!" % [occ.stats.display_name,
				VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)])
	# Наезд на мину (item 13): и противопехотная, и противотанковая рвутся под
	# гусеницей и снимают с машины 1 прочность. Считаем ДО общей зачистки следа —
	# иначе clear_feature() ниже стёр бы мину молча, без взрыва. Сканируем клетки,
	# по которым машина прошла, и конечный след, куда она встала.
	var driven: Dictionary = {}
	for cc in (plan["crush_cells"] + plan["scatter_cells"] + plan["ram_cells"]):
		driven[cc] = true
	# КАЖДАЯ клетка, которую след машины замёл по дороге, а не только раздавленные и
	# конечная стоянка. Прежний список брал лишь их — и мина, по которой танк ПРОЕХАЛ,
	# не считалась перееханной: под гусеницей она рвалась, только если машина на ней
	# останавливалась или если клетка чем-то была занята. Пустой пол с миной проезжали
	# насквозь бесплатно.
	for i in range(1, int(plan["steps"]) + 1):
		for fc in veh.footprint_from(veh.origin + dir * i):
			driven[fc] = true
	for mc: Vector2i in driven:
		var mcell := state.grid.cell(mc)
		if mcell == null:
			continue
		if mcell.feature_id != MCF.FEATURE_MINE and mcell.feature_id != MCF.FEATURE_AV_MINE:
			continue
		var av := mcell.feature_id == MCF.FEATURE_AV_MINE
		mcell.clear_feature()
		notify_cell_changed(mc)
		_fx(res, {"fx": "debris", "at": NOWHERE, "cells": [mc]})
		res.log("The %s rolls over %s at (%d, %d)!" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
			"an anti-vehicle mine" if av else "a mine", mc.x, mc.y])
		# ПРОТИВОТАНКОВАЯ мина бьёт по ходовой без всякого броска — она для того и
		# ставится. Ходовая уже разбита — заряд уходит в корпус: под днищем рвётся то же
		# самое, и пропадать ему некуда.
		# ПРОТИВОПЕХОТНАЯ машине больше не вредит вовсе: она рассчитана на человека, и
		# считать её ещё и противотанковой значило бы, что противотанковая не нужна.
		if av:
			_damage_component(veh, _a_live_track(veh), MCF.AV_MINE_VEHICLE_DAMAGE,
				"mine", res)
	# Всё под гусеницами сносится в пол (трупы, укрытия, тараненные стены).
	# Ежей считаем ЗДЕСЬ, до зачистки: clear_feature() ниже сотрёт их молча, и после
	# переезда узнать, сколько их было, стало бы неоткуда.
	# Тела под гусеницей ОСТАЮТСЯ (batch 12 #2): труп-occupant и куча corpse_count не
	# трогаются — машина проезжает поверх, а когда уедет, их можно подобрать как обычно.
	# Только сложенная из тел стена перестаёт быть стеной: конструкция смята, но сами
	# пять тел лежат на месте, отдельной кучей.
	var flattened: Array[Vector2i] = []
	var hedgehogs := 0
	var smashed := 0
	var from_c := veh.center()
	for cell_coord in (plan["crush_cells"] + plan["scatter_cells"] + plan["ram_cells"]):
		var c := state.grid.cell(cell_coord)
		if c.feature_id == MCF.FEATURE_HEDGEHOG:
			hedgehogs += 1
		var was_corpse_wall := c.feature_id == MCF.FEATURE_CORPSE_WALL
		# Окно под гусеницей бьётся (batch ui-drones) — так же, как от пули: осколки летят
		# по ходу машины. Раньше стекло исчезало молча, будто его и не было.
		if MCF.is_glass(c.feature_id):
			_fx(res, {"fx": "shards", "at": cell_coord, "from": from_c})
		if c.is_wall():
			smashed += 1
			notify_cell_changed(cell_coord)  # снос стены — повод проснуться жителям рядом
		if c.occupant != null and c.occupant.is_alive():
			c.occupant = null
		c.clear_feature()
		if was_corpse_wall:
			c.corpse_count = MCF.CORPSE_WALL_COUNT
		flattened.append(cell_coord)
	if smashed > 0:
		res.log("The %s smashes through %d wall cell(s)" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), smashed])
	# Пол под гусеницей выглядит РАЗБИТЫМ (item 1): «if a tank rams through a wall, make
	# these tiles display as destroyed». Клетка менялась и раньше — стена исчезала, — но
	# на вид оставалась чистым полом, будто там ничего и не стояло. Метка та же, что
	# кладёт взрыв, поэтому и рисуется теми же щербинами. Эпицентра у переезда нет
	# (NOWHERE): танк не взрывается, он ровняет — все клетки следа одинаковы.
	if not flattened.is_empty():
		_fx(res, {"fx": "debris", "at": NOWHERE, "cells": flattened})
	# Раздавленный не пропадает бесследно (#97): на его клетке остаётся труп — такой же,
	# как от пули, поэтому его можно подобрать или сложить в стену. Кладём ПОСЛЕ зачистки
	# следа: она идёт по тем же клеткам и иначе сама бы его и стёрла.
	for dead: UnitInstance in crushed:
		var dc := state.grid.cell(dead.coord)
		if dc != null and dc.occupant == null:
			dc.occupant = dead
	# Переместить и разметить новый след.
	# Переезд на экране — плавно, по клеткам (batch borg-corpses), как шаг бойца.
	res.dice_events.append({"kind": "veh_walk", "vehicle": veh.id, "from": veh.origin,
			"steps": int(plan["steps"])})
	veh.origin += dir * int(plan["steps"])
	state.grid.set_vehicle_footprint(veh.id, veh.footprint())
	# Пассажиры и станция садятся обратно в свои кресла на новом месте.
	for pair in riders:
		_seat_unit(veh, pair[1], int(pair[0]))
	for si in station_seats:
		var new_c := veh.seat_cell(si)
		var nc := state.grid.cell(new_c)
		nc.set_feature(MCF.FEATURE_DRONE_STATION, veh.owner)
		if driver != null:
			nc.station_operator_id = _station_operator_aboard(veh)
		# Дроны этой станции (batch 14): привязь переезжает вместе с ней, а дрон, сидевший
		# на станции, летит с челноком — раньше он оставался висеть над пустым полом.
		var old_c: Vector2i = station_from[si]
		for d in state.all_units():
			if d.is_drone and d.is_alive() and d.home_station == old_c:
				d.home_station = new_c
				if d.coord == old_c:
					d.coord = new_c
	if seated:
		# Оплата водителем (S1): сперва остаток, потом по ОД за каждые 15 клеток.
		var cost: int = int(plan["cost"])
		var from_credit := mini(cost, veh.move_credit)
		veh.move_credit -= from_credit
		var rest := cost - from_credit
		if rest > 0:
			var ap_cost := int(ceil(float(rest) / float(MCF.SHUTTLE_CELLS_PER_AP)))
			driver.remaining_ap -= ap_cost
			veh.move_credit = ap_cost * MCF.SHUTTLE_CELLS_PER_AP - rest
		res.log("%s flies %d cell(s) — %s at the wheel (AP %d, %d cells left)" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
			int(plan["steps"]), driver.stats.display_name, driver.remaining_ap, veh.move_credit])
	else:
		# Кредит списывается вместо ОД; свежее движение стоит 1 ОД и оставляет остаток (#97).
		var tk := tier_of(tank_tiers, int(plan["cost"])) if not tank_tiers.is_empty() else 0
		veh.ap -= tk + (0 if use_credit else 1)
		if not tank_tiers.is_empty():
			speed = tank_tiers[tk]
		veh.move_credit = maxi(0, speed - int(plan["cost"]))
		res.log("%s drives %d cell(s). (AP %d, %d move left)" % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id),
			int(plan["steps"]), veh.ap, veh.move_credit])
	# Щитоносец глушит машину и калечит ей ХОДОВУЮ (§таблица столкновений): плита
	# упирается в гусеницу, а не в броню, поэтому урон всегда туда и всегда 2.
	if int(plan["self_damage"]) > 0:
		res.log("Shield bearer halts the vehicle.")
		_damage_component(veh, _a_live_track(veh), MCF.COMPONENT_DAMAGE_SHIELD,
			"collision", res)
	# Противотанковый ёж рвёт гусеницу, но машину не останавливает — она проходит
	# насквозь, ломая конструкцию. Считается ОДИН раз за переезд, сколько бы ежей ни
	# смело: это одна поездка по одному ежовому полю, а не отдельная авария на каждом.
	if hedgehogs > 0:
		res.log("The %s grinds through %d hedgehog(s)." % [
			VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), hedgehogs])
		_damage_component(veh, _a_live_track(veh), MCF.COMPONENT_DAMAGE_HEDGEHOG,
			"hedgehog", res)
	return res

# --- Главная пушка танка (взрыв-ромб радиуса 2, #63) ---
func _resolve_vehicle_cannon(intent: VehicleCannonIntent) -> ActionResult:
	var veh := state.get_vehicle(intent.actor_id)
	var err := _validate_vehicle(veh)
	if err != "":
		return ActionResult.fail(err)
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var gun: Dictionary = spec.get("weapons", {}).get("main_gun", {})
	if gun.is_empty():
		return ActionResult.fail("This vehicle has no cannon")
	_aimed_component = intent.component
	# Разбитое орудие не стреляет (веха «Modular tank system»).
	if not veh.can_fire_gun():
		return ActionResult.fail("The main gun is knocked out")
	if veh.cannon_shots_this_round >= int(gun.get("max_per_turn", 2)):
		return ActionResult.fail("Cannon already fired twice this turn")
	if not state.grid.in_bounds(intent.target):
		return ActionResult.fail("Target off the board")
	# Стрелять можно с ЛЮБОЙ клетки борта, а не только со средней (#62): у танка
	# 3×3 это три амбразуры на каждую сторону. Порт — клетка корпуса, от которой
	# цель лежит строго по прямой НАРУЖУ (ствол не упирается в собственный корпус).
	var port := cannon_port(veh, intent.target)
	if port == Vector2i(-1, -1):
		return ActionResult.fail("Cannon fires only horizontally or vertically")
	var dist := Combat.distance(port, intent.target)
	if dist > int(gun.get("range", MCF.CANNON_RANGE)):
		return ActionResult.fail("Target out of cannon range")
	# Раньше пушка проверяла только чужие корпуса — и потому била сквозь стены, ЛДФ,
	# двухметровые кучи земли (#70) и сквозь живых бойцов (#58). Теперь линия огня
	# проверяется тем же los_blocked, что и у пехоты: он покрывает всё сразу.
	if los_blocked(port, intent.target):
		return ActionResult.fail("Line of fire is blocked")
	# Заклиненная башня (tower = 0) не поворачивается: стрелять можно только туда же,
	# куда смотрел последний выстрел. Направление хранится ОТНОСИТЕЛЬНО корпуса, так что
	# развернуть машину — законный способ переприцелиться, а вот выбрать новый сектор,
	# стоя на месте, уже нельзя. Не стреляла ни разу — заклинившая башня не смотрит
	# никуда, и до ремонта орудие молчит.
	var fire_dir := Vector2i(signi(intent.target.x - port.x), signi(intent.target.y - port.y))
	if veh.tower_jammed():
		var locked := veh.tower_world_dir()
		if locked == Vector2i.ZERO:
			return ActionResult.fail("The tower is jammed and has never been laid")
		if fire_dir != locked:
			return ActionResult.fail("The tower is jammed — it fires only where it last did")

	veh.ap -= int(gun.get("ap_cost", 1))
	# Снаряд приходит от БОРТА, с которого стреляли (веха 14.1): по нему цель и считает,
	# какая её гусеница открыта и виден ли ей ствол.
	_aim_from = port
	# Куда смотрел ствол в этот раз — на случай, если башню собьют следующим попаданием.
	veh.remember_shot_dir(fire_dir)
	veh.cannon_shots_this_round += 1
	var res := ActionResult.new()
	res.ok = true
	# Бросок на точность (#56): при промахе снаряд ложится с недолётом, но всё равно
	# взрывается на месте (как граната/противотанкист).
	var need := Combat.hit_number(dist, float(int(gun.get("range", MCF.CANNON_RANGE))))
	var roll := state.dice.roll_d6()
	var on_target := roll >= need
	# Недолёт считается ТОЙ ЖЕ формулой, что у противотанкиста (#22): своя, прежняя
	# (dist − (need − roll)) на дальних дистанциях уводила снаряд совсем в другое место.
	var landing := _shortfall_landing(port, intent.target, roll, need)
	res.dice_events.push_front({
		"kind": "check", "actor": spec.get("name", veh.type_id),
		"roll": roll, "need": need, "ok": on_target,
	})
	if on_target:
		res.log("%s fires its main gun at (%d, %d)! (roll %d, need %d+)" % [
			spec.get("name", veh.type_id), intent.target.x, intent.target.y, roll, need])
	else:
		res.log("%s fires — shot falls short, shell lands at (%d, %d)! (roll %d, need %d+)" % [
			spec.get("name", veh.type_id), landing.x, landing.y, roll, need])
	# Снимок «до взрыва» для показа во время броска (item 22): разрушения и снятая
	# прочность появятся только ПОСЛЕ того, как кубик докрутится.
	var pre_area := cannon_blast_cells(veh, landing)
	pre_area.append(landing)
	_capture_visual_hold(res, pre_area)
	_fx_lane(res, port, landing, veh.owner, "blast")  # issue 8: кто и куда бьёт пушкой
	# Прямое попадание в ДОТ: бетон принимает снаряд целиком (2 прочности = 1 выстрел
	# танка), осколочного поля вокруг не возникает.
	_blast_armor_wall(landing, res)
	if _pillbox_absorbs(landing, int(gun.get("vehicle_damage", 2)), res):
		return res
	# Осколочное поле снаряда — ромб радиуса 2 (#63), а не квадрат 3×3.
	var area := cannon_blast_cells(veh, landing)
	var killed: Array = _blast(landing, res, area)
	for n in killed:
		res.log("%s killed in the blast!" % n)
	# Технике — 2 прочности (§техника). Все машины, чей след задет ромбом.
	_damage_vehicles_in_area(area, landing, MCF.COMPONENT_DAMAGE_CANNON, veh.id, res,
		String(spec.get("name", veh.type_id)), _aimed_component)
	if killed.is_empty():
		res.log("… no infantry caught.")
	return res

## Зона поражения снаряда танковой пушки — ромб (#63). Публичная: тем же вызовом
## UI рисует предпросмотр, так что подсветка и реальный взрыв не могут разойтись.
func cannon_blast_cells(veh: Vehicle, center: Vector2i) -> Array[Vector2i]:
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get(
		"weapons", {}).get("main_gun", {})
	return MCF.blast_diamond(center, int(gun.get("blast_radius", MCF.CANNON_BLAST_RADIUS)))

## Клетка корпуса, из которой машина стреляет по target, или (-1,-1) если цель не
## лежит на прямой ни от одной амбразуры (#62). Внутренние клетки корпуса портами
## не считаются: из середины танка ствол смотрел бы в собственную броню.
func cannon_port(veh: Vehicle, target: Vector2i) -> Vector2i:
	var own := {}
	for fc: Vector2i in veh.footprint():
		own[fc] = true
	if own.has(target):
		return Vector2i(-1, -1)  # в собственный корпус не стреляют
	var best := Vector2i(-1, -1)
	var best_dist := 1 << 30
	for fc: Vector2i in veh.footprint():
		# Пушка бьёт только по прямой — горизонталь/вертикаль (#55).
		if fc.x != target.x and fc.y != target.y:
			continue
		var step := Vector2i(signi(target.x - fc.x), signi(target.y - fc.y))
		if step == Vector2i.ZERO or own.has(fc + step):
			continue
		var d := Combat.distance(fc, target)
		if d < best_dist:
			best_dist = d
			best = fc
	return best

## Клетки, по которым машина может отработать пушкой прямо сейчас — для подсветки
## в UI. Учитывает амбразуры (#62), дальность и перекрытие линии огня (#58, #70).
func cannon_target_cells(veh: Vehicle, limit_to: Dictionary = {}) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	# Подсветка обязана совпадать с тем, что примет резолвер: разбитое орудие не
	# стреляет вовсе, а заклиненная башня — только вдоль своего последнего сектора.
	if veh != null and (not veh.can_fire_gun()
			or (veh.tower_jammed() and veh.tower_world_dir() == Vector2i.ZERO)):
		return out
	if veh == null or not veh.alive():
		return out
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get(
		"weapons", {}).get("main_gun", {})
	if gun.is_empty():
		return out
	var rng := int(gun.get("range", MCF.CANNON_RANGE))
	var own := {}
	for fc: Vector2i in veh.footprint():
		own[fc] = true
	var seen := {}
	# Каждая клетка борта пускает луч наружу по четырём направлениям (#62). Луч
	# обрывается на первой непробиваемой клетке, поэтому подсветка совпадает с тем,
	# что резолвер реально разрешит выстрелить.
	for fc: Vector2i in veh.footprint():
		for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			if own.has(fc + d):
				continue  # это внутренняя клетка, а не амбразура
			var c := fc + d
			for _step in rng:
				if not state.grid.in_bounds(c) or Combat.distance(fc, c) > rng:
					break
				if los_blocked(fc, c):
					break  # дальше по этому лучу тоже не пробить
				if not seen.has(c) and (limit_to.is_empty() or limit_to.has(c)):
					seen[c] = true
					out.append(c)
				c += d
	return out

## Урон всем машинам (кроме source_id), чей след задет зоной взрыва area.
## Урон технике от взрыва — ТОЛЬКО ПРЯМЫМ ПОПАДАНИЕМ (item 16: «only a direct explosion
## (tank/anti-tank hit) deals damage to vehicles»).
##
## Раньше хватало того, что след машины задет осколочным полем: заряд, легший В СОСЕДНЮЮ
## клетку, снимал с танка прочность наравне с попаданием в борт. Отсюда и жалоба — броня
## таяла от всего, что рвалось поблизости: чужая мина, подрыв дрона, детонация другой
## машины, недолёт противотанкиста.
##
## Теперь условие одно и жёсткое: ЭПИЦЕНТР взрыва должен лежать НА СЛЕДЕ машины. Снаряд
## танка и заряд противотанкиста, попавшие в корпус, работают как работали; всё, что
## разорвалось рядом, машину больше не трогает. Пехоту вокруг осколки по-прежнему косят —
## это ведает _blast(), и правило её не касается.
##
## center — та самая точка разрыва (место падения заряда, а не центр области).
## aimed — узел, который назвал стрелок; "" = стрелка нет (детонация соседней машины),
## тогда узел выбирает каскад. roll_location=false — узел задан НАПРЯМУЮ, без бросков
## (подрыв дрона: игрок указывает узел, и он гарантированно его и получает).
func _damage_vehicles_in_area(area: Array[Vector2i], center: Vector2i, amount: int,
		source_id: int, res: ActionResult, source: String = "cannon",
		aimed: String = "", roll_location: bool = true) -> void:
	var in_area := {}
	for c: Vector2i in area:
		in_area[c] = true
	for veh: Vehicle in state.all_vehicles():
		if veh.id == source_id or not veh.alive():
			continue
		var direct := false
		for fc in veh.footprint():
			# Эпицентр на корпусе — это и есть прямое попадание. Проверка «клетка в
			# области» остаётся страховкой: точка разрыва обязана быть внутри своего же
			# осколочного поля, и если это вдруг не так — урона нет.
			if fc == center and in_area.has(fc):
				direct = true
				break
		if direct:
			if not roll_location:
				_damage_component(veh, aimed, amount, source, res)
			else:
				var comp := _resolve_hit_location(veh, aimed, res, source, _aim_from)
				if comp != "":
					_damage_component(veh, comp, amount, source, res)

## Разобрать ПОПАДАНИЕ по машине и решить, какой узел пострадал (веха «Modular tank
## system», §3.1).
##
## Стрелок называет узел заранее и бьёт по нему с надбавкой за прицел (+1). Не попал —
## удар не пропадает: он сходит по каскаду от самого труднопопадаемого узла к самому
## лёгкому (пушка → башня → ходовая → корпус), пропуская названный и все разбитые, и
## уже БЕЗ надбавки: премия полагается за объявленный выбор, а не за всю очередь. Если
## не прошёл ни один бросок — бьём в последний оставшийся узел: «попал по танку, но
## ничего не задел» исходом не бывает.
##
## Возвращает id узла или "" — если у машины не осталось ни одного живого узла.
## Узлы, по которым МОЖНО целиться с этой стороны (веха 14.1).
##
## До сих пор стрелок выбирал из всего, что у машины цело, откуда бы он ни бил. Но
## гусеница — вещь бортовая: с левого борта видно левую, с правого правую, а в лоб и в
## корму — обе. И ствол не всегда доступен: он смотрит туда, куда стрелял в прошлый раз,
## и подходящему СЗАДИ него не виден вовсе.
##
## from = NOWHERE — стрелка на поле нет (подрыв дрона сверху, детонация соседней машины):
## тогда борта не существует и доступно всё, что цело.
func _aimable_components(veh: Vehicle, from: Vector2i) -> Array:
	var live := veh.live_components()
	if veh == null or from == NOWHERE or not state.grid.in_bounds(from):
		return live
	var side := veh.side_facing(from)
	var out: Array = []
	for comp: String in live:
		if comp == MCF.COMP_TRACKS_L and side == "right":
			continue
		if comp == MCF.COMP_TRACKS_R and side == "left":
			continue
		if comp == MCF.COMP_GUN and _gun_hidden_from(veh, from):
			continue
		out.append(comp)
	# Совсем без целей не остаёмся: корпус виден с любой стороны, но если сложилось так,
	# что отсеклось всё, бьём по тому, что есть, — «попал и не задел» исходом не бывает.
	return out if not out.is_empty() else live

## Скрыт ли ствол от стрелка: тот стоит ПОЗАДИ сектора, в который смотрит башня.
## Сбоку ствол виден (его видно в профиль), сзади — нет.
func _gun_hidden_from(veh: Vehicle, from: Vector2i) -> bool:
	var g := veh.gun_world_dir()
	if g == Vector2i.ZERO:
		return false
	var rel := from - veh.center()
	var along := rel.x * g.x + rel.y * g.y
	var across := rel.x * -g.y + rel.y * g.x
	return along < 0 and absi(along) > absi(across)

func _resolve_hit_location(veh: Vehicle, aimed: String, res: ActionResult,
		actor_name: String, from: Vector2i = NOWHERE) -> String:
	var live := _aimable_components(veh, from)
	if live.is_empty():
		return ""
	var aimed_at := ""
	# ПРИЦЕЛЬНЫЙ бросок делается, только если узел действительно назвали и он цел.
	# Источники без стрелка (детонация соседней машины) узла не называют — им сразу
	# каскад по базовым порогам, без надбавки за прицел.
	if aimed != "" and live.has(aimed):
		aimed_at = aimed
		var need: int = clampi(
			int(MCF.COMPONENT_NEED.get(aimed_at, 6)) - MCF.COMPONENT_AIM_BONUS, 1, 6)
		var roll := state.dice.roll_d6()
		var hit := roll >= need
		res.dice_events.append({
			"kind": "check",
			"actor": "%s → %s" % [actor_name, MCF.COMPONENT_NAMES.get(aimed_at, aimed_at)],
			"roll": roll, "need": need, "ok": hit,
		})
		if hit:
			return aimed_at
	# Каскад: тот же порядок, что в правилах, без названного узла и без надбавки.
	# Идёт он по тем же ДОСТУПНЫМ узлам: снаряд, пришедший слева, не может задеть
	# правую гусеницу ни прицельно, ни случайно — её закрывает сам корпус.
	for comp: String in MCF.COMPONENT_ORDER:
		if comp == aimed_at or not live.has(comp):
			continue
		var c_need: int = int(MCF.COMPONENT_NEED.get(comp, 6))
		var c_roll := state.dice.roll_d6()
		var c_hit := c_roll >= c_need
		res.dice_events.append({
			"kind": "check",
			"actor": "%s → %s" % [actor_name, MCF.COMPONENT_NAMES.get(comp, comp)],
			"roll": c_roll, "need": c_need, "ok": c_hit,
		})
		if c_hit:
			return comp
	# Пол гарантии: не прошло вообще ничего — задет последний уцелевший узел.
	return live[live.size() - 1]

## Снять с УЗЛА очки прочности. Излишек (пушка танка бьёт на 2, а в узле остался 1)
## уходит В КОРПУС: снаряд, добивший ходовую, продолжает бить в машину, а не пропадает.
##
## Экипаж рискует ТОЛЬКО от попадания в корпус: несмертельное даёт одному человеку
## бросок на выживание, смертельное убивает весь экипаж без броска (это делает
## _destroy_vehicle). Разбитые башня, ходовая и пушка экипажу не угрожают никогда.
func _damage_component(veh: Vehicle, comp: String, amount: int, source: String,
		res: ActionResult) -> void:
	if veh == null or not veh.alive() or amount <= 0:
		return
	var target := comp
	if target == "" or not veh.has_component(target):
		target = MCF.COMP_HULL
	var name: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
	var label: String = MCF.COMPONENT_NAMES.get(target, target)
	# Узел уже выбит (или его у машины нет вовсе) — весь удар принимает корпус. Так же
	# ведёт себя противотанковая мина по разбитой ходовой: рвётся-то она всё равно, и
	# деваться её заряду некуда. Пропасть впустую урон не может ни при каких условиях.
	if veh.component(target) <= 0 and target != MCF.COMP_HULL:
		_damage_component(veh, MCF.COMP_HULL, amount, source, res)
		return
	var left: int = veh.component(target)
	var dealt: int = mini(amount, left)
	var overflow: int = amount - dealt
	if dealt > 0:
		veh.components[target] = left - dealt
		res.log("%s: %s takes %d damage (%d left)." % [
			name, label, dealt, veh.component(target)])
		if veh.component(target) == 0:
			res.log("%s: %s is knocked out!" % [name, label])
	# Корпус на нуле — машине конец, и добивать дальше нечего.
	if target == MCF.COMP_HULL and veh.component(MCF.COMP_HULL) <= 0:
		_destroy_vehicle(veh, res)
		return
	if target == MCF.COMP_HULL and not _seated(veh) and not veh.is_borg():
		# Несмертельное попадание в корпус: один человек проверяет броню (§6).
		# У челнока пассажиры разобраны самим взрывом (batch 13 S5); у борга оператор
		# страдает только вместе с машиной (B6).
		_tank_crew_hit(veh, res)
	elif overflow > 0 and dealt > 0:
		# Излишек добивает корпус — со всеми последствиями попадания в корпус.
		_damage_component(veh, MCF.COMP_HULL, overflow, source, res)

## Нанести машине урон ПО КАСКАДУ, когда узел не выбирают: детонация соседней машины,
## взрыв под гусеницей и прочие источники без стрелка. Прицела нет — значит нет и
## надбавки: каскад начинается с самого труднопопадаемого узла.
func _damage_vehicle_cascade(veh: Vehicle, amount: int, source: String,
		res: ActionResult, actor_name: String) -> void:
	if veh == null or not veh.alive():
		return
	var comp := _resolve_hit_location(veh, "", res, actor_name)
	if comp == "":
		return
	_damage_component(veh, comp, amount, source, res)

## Урон машине от источника, который узел НЕ выбирает. Разбирается каскадом
## (_damage_vehicle_cascade) — прежняя «одна общая прочность» больше не существует.
##
## Оставлено отдельным именем, потому что зовущих много и все они говорят об одном:
## «машине прилетело столько-то, куда именно — решай сам».
func _apply_vehicle_damage(veh: Vehicle, amount: int, source: String, res: ActionResult) -> void:
	_damage_vehicle_cascade(veh, amount, source, res, source)

## Попадание по экипажу танка (§техника «как от одной пули»): случайный живой
## член экипажа бросает d6 против своей брони; провал — гибнет.
func _tank_crew_hit(veh: Vehicle, res: ActionResult) -> void:
	if veh.occupants.is_empty():
		return
	# Выбор случайного члена экипажа через d6 (идёт через DiceService — сеть синхронна).
	var idx := (state.dice.roll_d6() - 1) % veh.occupants.size()
	var uid: int = veh.occupants[idx]
	var crew := state.get_unit(uid)
	if crew == null:
		veh.occupants.remove_at(idx)
		return
	# Экипаж в броне держится увереннее пехоты: +1 к защите (item 16) — порог выживания
	# на единицу ниже собственной брони, но не мягче 1+.
	var need: int = maxi(1, crew.armor() - MCF.TANK_CREW_DEFENSE_BONUS)
	var roll := state.dice.roll_d6()
	var survived := roll >= need
	res.dice_events.append({
		"kind": "check", "actor": "%s (crew)" % crew.stats.display_name,
		"roll": roll, "need": need, "ok": survived,
	})
	if not survived:
		_kill(crew)
		veh.occupants.remove_at(idx)
		veh.corpse_slots.append(crew.stats.display_name)
		res.log("%s (crew) is killed (roll %d, need %d+ with +1 armour)." % [
			crew.stats.display_name, roll, need])
	else:
		res.log("%s (crew) shrugs off the hit (roll %d, need %d+)." % [
			crew.stats.display_name, roll, need])
	veh.ap = mini(veh.ap, _vehicle_crew_ap(veh))

## Уничтожение машины: экипаж гибнет, бросок d6 на взрыв; танк остаётся обломком.
func _destroy_vehicle(veh: Vehicle, res: ActionResult) -> void:
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var name: String = spec.get("name", veh.type_id)
	var dtable: Dictionary = VehicleDB.DESTRUCTION.get(veh.type_id, {})
	# Экипаж внутри гибнет. Пассажиры челнока остаются трупами на своих клетках,
	# машина из-под них исчезает (batch 13 S12).
	#
	# ВАЖНО: _kill() сам в res.deaths НИЧЕГО не кладёт — это делает каждый вызывающий,
	# и здесь этого не делал никто. То есть подбитый танк засчитывался только корпусом,
	# а трое внутри не попадали ни в награду за убийство, ни в счётчик комбо: сжечь
    # гружёную машину стоило ровно столько же, сколько пустую. Та же поломка, что была
	# у _blast/лазера/огнемёта, и на танковой карте она особенно дорога — там ВЕСЬ отряд
	# сидит внутри корпусов, и без этой строки карта не учила бы ничему.
	for uid in veh.occupants.duplicate():
		var crew := state.get_unit(uid)
		if crew != null:
			_kill(crew, res)
			res.deaths.append(crew.id)
			# Тело оператора борга больше ни в какой машине не сидит: взорвавшийся борг
			# из state.vehicles исчезает, и borg_id указывал бы в пустоту.
			if veh.is_borg():
				crew.borg_id = -1
	veh.occupants.clear()
	if _seated(veh):
		for i in veh.seats.size():
			var sid: int = veh.seats[i]
			if sid == Vehicle.SEAT_STATION:
				var sc := state.grid.cell(veh.seat_cell(i))
				if sc != null and sc.feature_id == MCF.FEATURE_DRONE_STATION:
					sc.clear_feature()
			elif sid >= 0:
				var body := state.get_unit(sid)
				if body != null:
					body.aboard_vehicle_id = -1
			veh.seats[i] = -1
	veh.durability = 0
	var roll := state.dice.roll_d6()
	var explode := false
	# Порог взрыва по таблице разрушения: у челнока это «1-2», у танка «4+» (#68).
	var need: int = int(dtable.get("explode_min", 99))
	if dtable.has("explode_max"):
		explode = roll >= int(dtable.get("explode_min", 1)) and roll <= int(dtable["explode_max"])
	else:
		explode = roll >= need
	# Бросок на детонацию должен быть ВИДЕН игроку, как любой другой (#68): без
	# этого события кубик не выкатывался и разрушение выглядело беспричинным.
	res.dice_events.append({
		"kind": "check", "actor": "%s destruction" % name,
		"roll": roll, "need": need, "ok": explode,
	})
	res.log("%s is destroyed! (destruction roll %d)" % [name, roll])
	# Оператор борга гибнет вместе с машиной (batch 13 B6) — его тело остаётся на клетке.
	if veh.is_borg():
		var bop := state.get_unit(veh.borg_operator())
		if bop != null and bop.is_alive():
			_kill(bop, res)
			bop.borg_id = -1
		veh.occupants.clear()
	if explode:
		var r := int(dtable.get("explode_radius", 1))
		res.log("It explodes (radius %d)!" % r)
		var center := veh.center()
		# Детонация боекомплекта — такой же взрыв-ромб, как у пушки (#63): по
		# диагонали ударная волна уходит недалеко. Борг рвётся как противотанковый
		# заряд (B6) — квадрат 3×3. У детонации борта нет — рвётся сама машина.
		_aim_from = NOWHERE
		var square := bool(dtable.get("square", false))
		var area := MCF.blast_square(center, r) if square else MCF.blast_diamond(center, r)
		# Взрыв — тот же _blast, что у заряда (batch 17, item 7): гибнут все в зоне,
		# укрепления сносятся, и под машиной остаётся выжженный пол.
		if veh.is_borg():
			state.grid.clear_vehicle_footprint(veh.id, veh.footprint())
		for n in _blast(center, res, area):
			res.log("%s destroyed!" % n)
		_damage_vehicles_in_area(area, center, 1 if square else 2, veh.id, res,
				"%s detonation" % name)
	# Любая машина оставляет остов (batch 17, item 7): укрытие и блок линии огня —
	# взорвалась она или нет. Раньше челнок исчезал всегда, борг — после взрыва.
	veh.wrecked = true
	if veh.is_borg():
		state.grid.set_vehicle_footprint(veh.id, veh.footprint())

# --- Запросы для UI ---

## Машина под клеткой, которой управляет владелец owner (для выбора кликом).
func controllable_vehicle_at(coord: Vector2i, owner: int) -> Vehicle:
	var veh := state.vehicle_on(coord)
	if veh != null and veh.alive() and veh.owner == owner:
		return veh
	return null

## Машины (свои и вражеские) рядом с юнитом, в которые он может сесть.
func boardable_vehicles(unit: UnitInstance) -> Array:
	var out: Array = []
	if unit == null or not unit.is_alive() or unit.aboard_vehicle_id != -1 or unit.is_drone \
			or unit.borg_id != -1 or unit.carried_corpses > 0 or _is_shield(unit):
		return out   # то же, что отклонит _resolve_vehicle_board: меню не предлагает отказ
	var seen := {}
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or _vehicle_full(veh):
			continue
		if seen.has(veh.id) or (veh.is_borg() and _borg_entry_error(unit, veh) != ""):
			continue
		if _adjacent_to_vehicle(unit.coord, veh):
			seen[veh.id] = true
			out.append(veh)
	return out

## Мест больше нет: у челнока — ни одного свободного кресла, у прочих — все слоты заняты.
func _vehicle_full(veh: Vehicle) -> bool:
	if _seated(veh):
		return veh.free_seats().is_empty()
	if veh.is_borg():
		var op := state.get_unit(veh.borg_operator())
		return op != null and op.is_alive()
	return veh.slots_used() >= veh.capacity()

## Соседняя своя пехота, которая может сесть в машину.
func vehicle_board_candidates(veh: Vehicle) -> Array:
	var out: Array = []
	if veh == null or not veh.alive() or _vehicle_full(veh):
		return out
	for u in state.all_units():
		if u.is_alive() and u.owner == veh.owner and u.aboard_vehicle_id == -1 \
				and not u.is_drone and _adjacent_to_vehicle(u.coord, veh):
			out.append(u.id)
	return out

## Куда может доехать машина: центр итоговой позиции → { dir, steps }.
func vehicle_move_targets(veh: Vehicle, speed_bonus: int = 0) -> Dictionary:
	var out: Dictionary = {}
	var credit := vehicle_move_credit(veh)
	if veh == null or not veh.alive() or (vehicle_ap(veh) <= 0 and credit <= 0):
		return out
	if not veh.can_drive():
		return out  # разбитая ходовая — ехать некуда (веха «Modular tank system»)
	# Тот же бюджет, что спишет резолвер (#97): остаток прошлого движения — вместо ОД.
	var speed := credit if credit > 0 \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	if _seated(veh):
		speed = _shuttle_budget(veh)  # водитель платит по 15 клеток за ОД (batch 13)
	speed += speed_bonus  # предпросмотр «куда доеду за следующие ОД» (batch ui-drones)
	var dirs: Array = []
	if veh.facing != Vector2i.ZERO:
		dirs = [veh.facing, -veh.facing]
	else:
		dirs = DIR8
	for dir: Vector2i in dirs:
		var last := 0
		for steps in range(1, speed + 1):
			var plan := VehicleRules.plan_line_move(state, veh, dir, steps, speed)
			if not plan["ok"]:
				break
			var reached := int(plan["steps"])
			if reached <= last:
				break
			last = reached
			var center := Vehicle.center_of(veh.origin + dir * reached, veh.size)
			out[center] = {"dir": dir, "steps": reached, "cost": int(plan["cost"])}
			if reached < steps:
				break
	return out

## Потолки хода машины за 1/2/3 ОД — как move_tier_budgets у пехоты: [0] — остаток
## прошлого движения (тогда он и есть первая зона, без ОД) или ход за 1 ОД, дальше по
## ходу за каждое следующее ОД. Челнок платит по SHUTTLE_CELLS_PER_AP клеток за ОД.
func vehicle_tier_budgets(veh: Vehicle) -> Array[int]:
	var out: Array[int] = []
	if veh == null or not veh.alive():
		return out
	var credit := vehicle_move_credit(veh)
	var step := MCF.SHUTTLE_CELLS_PER_AP if _seated(veh) \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	var extra := vehicle_ap(veh) - (0 if credit > 0 else 1)
	if extra < 0 or step <= 0:
		return out if credit <= 0 else [credit]
	out.append(credit if credit > 0 else step)
	for k in range(1, mini(extra, 2) + 1):
		out.append(out[0] + step * k)
	return out

## Зона хода по цене пути: первый потолок, в который цена влезла (0 — зелёная).
static func tier_of(budgets: Array[int], cost: int) -> int:
	var k := 0
	while k < budgets.size() - 1 and cost > budgets[k]:
		k += 1
	return k

## Все клетки, куда машина доедет за 1-3 ОД (центр -> {dir, steps, cost}); зона клетки —
## tier_of(vehicle_tier_budgets, cost). Это и подсветка, и то, что примет клик.
func vehicle_move_targets_all(veh: Vehicle) -> Dictionary:
	var tb := vehicle_tier_budgets(veh)
	if tb.is_empty():
		return {}
	# Челнок и так считает весь запас водителя (_shuttle_budget).
	if _seated(veh):
		return vehicle_move_targets(veh)
	return vehicle_move_targets(veh, tb[tb.size() - 1] - tb[0])

## Куда машина доедет за 1, 2 и 3 ОД (batch ui-drones): массив словарей центр -> true,
## каждый следующий — только клетки, которых нет в предыдущих.
func vehicle_move_tiers(veh: Vehicle) -> Array:
	var tiers: Array = [{}, {}, {}]
	var tb := vehicle_tier_budgets(veh)
	var all := vehicle_move_targets_all(veh)
	for c: Vector2i in all:
		tiers[tier_of(tb, int(all[c]["cost"]))][c] = true
	return tiers

## Раздавит ли этот ход СВОИХ (item 7).
##
## Гусеница давит всё, что под ней. Врага — и пусть: таран пехоты противника машине
## и положен. А вот своих ИИ переезжал совершенно буднично: подбор хода мерил только
## сближение с врагом, и о том, что по дороге лежит собственный отряд, план не знал
## вовсе. Танк выкашивал полвзвода и записывал это себе в прогресс.
##
## Спрашиваем ТОТ ЖЕ планировщик, что исполнит переезд (VehicleRules.plan_line_move):
## своя, отдельная прикидка «кто попадёт под гусеницу» неизбежно разошлась бы с
## настоящей — и разошлась бы молча.
func vehicle_move_crushes_ally(veh: Vehicle, dir: Vector2i, steps: int) -> bool:
	if veh == null or not veh.alive():
		return false
	var credit := vehicle_move_credit(veh)
	var speed := credit if credit > 0 \
			else int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
	if _seated(veh):
		speed = _shuttle_budget(veh)
	var plan := VehicleRules.plan_line_move(state, veh, dir, steps, speed)
	if not plan["ok"]:
		return false
	for cc: Vector2i in plan["crush_cells"]:
		var cell := state.grid.cell(cc)
		if cell == null:
			continue
		var occ: UnitInstance = cell.occupant
		if occ == null or not occ.is_alive():
			continue
		# Мирные жители своими не считаются — они никому не союзники; но и давить их
		# незачем, поэтому ИИ обходит и их (см. вызывающего).
		if occ.owner == veh.owner or state.roster.are_allies(veh.owner, occ.owner):
			return true
	return false

## Свободные соседние со следом клетки для высадки экипажа.
func vehicle_disembark_cells(veh: Vehicle, unit_id: int = -1) -> Array:
	var out: Array = []
	if veh == null:
		return out
	var seen := {}
	var cells: Array[Vector2i] = veh.footprint()
	# Пассажир челнока выходит через СВОЙ борт (batch 13 S7): только клетки вокруг
	# клетки его кресла.
	if _seated(veh) and unit_id != -1:
		var sc := seat_cell_of(state.get_unit(unit_id))
		if sc == NOWHERE:
			return out
		cells = [sc]
	for fc in cells:
		for n in state.grid.neighbors(fc):
			if seen.has(n):
				continue
			seen[n] = true
			if state.grid.vehicle_at(n) == veh.id:
				continue
			if not state.grid.is_occupied_or_wall(n):
				out.append(n)
	return out
