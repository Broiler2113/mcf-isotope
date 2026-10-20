@abstract
extends "res://src/resolver/parts/ResolverTargeting.gd"

## Weapons: rifles and bursts, anti-tank blasts, the flamethrower, the marksman's laser,
## shield pushes, the DPMG, grenades and items.

# --- Стрельба (§3.5) с дроблением действия (§3.2) ---
func _resolve_shoot(intent: ShootIntent) -> ActionResult:
	var shooter := state.get_unit(intent.actor_id)
	if shooter == null:
		return ActionResult.fail("Unit not found")
	if not shooter.is_alive():
		return ActionResult.fail("Unit is incapacitated")
	if shooter.owner != state.active_player():
		return ActionResult.fail("It's the other player's turn")

	if intent.target_id < 0 and intent.component.begins_with("fixture"):
		# "fixture:<side>" names one wall lamp; plain "fixture" is a standing lamp, or the
		# wall lamp facing the shooter (0.10 replays).
		var side := int(intent.component.get_slice(":", 1)) if intent.component.contains(":") \
				else facing_lamp_side(shooter, intent.target_cell)
		var reason := can_shoot_fixture(shooter, intent.target_cell, side)
		if reason != "": return ActionResult.fail(reason)
		return _recoiled(_resolve_shoot_fixture(shooter, intent.target_cell, side, intent.shots), shooter, intent.target_cell)

	# Противотанкист может бить по пустой клетке пола (§3.14) — взрыв в её центре.
	if intent.target_id < 0 and shooter.attack_ability() == MCF.ABILITY_ANTI_TANK:
		var ground_reason := can_blast_cell(shooter, intent.target_cell)
		if ground_reason != "":
			return ActionResult.fail(ground_reason)
		return _recoiled(_resolve_anti_tank(shooter, intent.target_cell, intent.component), shooter, intent.target_cell)

	# Огнемётчик может пустить струю по пустой клетке пола (как противотанкист): струя
	# идёт в её направлении, поджигает пол и убивает всех на пути.
	if intent.target_id < 0 and shooter.attack_ability() == MCF.ABILITY_FLAMETHROWER:
		var flame_reason := can_flame_cell(shooter, intent.target_cell)
		if flame_reason != "":
			return ActionResult.fail(flame_reason)
		return _recoiled(_resolve_flame(shooter, intent.target_cell), shooter, intent.target_cell)

	# Марксманн стреляет в НАПРАВЛЕНИЕ (#49): целиться в конкретного бойца не обязательно,
	# луч уходит по лучу через указанную клетку и летит дальше сам.
	if intent.target_id < 0 and shooter.attack_ability() == MCF.ABILITY_MARKSMAN:
		var laser_reason := can_laser_cell(shooter, intent.target_cell)
		if laser_reason != "":
			return ActionResult.fail(laser_reason)
		return _recoiled(_resolve_laser(shooter, intent.target_cell, intent.component), shooter, intent.target_cell)

	# Выстрел по окну (batch ui-drones): обычный стрелок может разбить стекло пулей.
	if intent.target_id < 0 and state.grid.in_bounds(intent.target_cell):
		var window_reason := can_shoot_window(shooter, intent.target_cell)
		if window_reason != "":
			return ActionResult.fail(window_reason)
		return _recoiled(_resolve_shoot_window(shooter, intent.target_cell, intent.shots), shooter, intent.target_cell)

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
	if shooter.attack_ability() != MCF.ABILITY_MARKSMAN \
			and shooter.attack_ability() != MCF.ABILITY_FLAMETHROWER:
		var intercepted := first_unit_on_line(shooter.coord, target.coord)
		if intercepted != null:
			redirect_line = "%s fires through %s — the shot hits them instead!" % [
				shooter.stats.display_name, intercepted.stats.display_name]
			target = intercepted

	# Спецстрельба (§3.13, §3.14) — отдельная геометрия, без дробления действия.
	match shooter.attack_ability():
		MCF.ABILITY_ANTI_TANK:
			return _recoiled(_resolve_anti_tank(shooter, target.coord, intent.component), shooter, target.coord)
		MCF.ABILITY_FLAMETHROWER:
			return _recoiled(_resolve_flame(shooter, target.coord), shooter, target.coord)
		MCF.ABILITY_MARKSMAN:
			return _recoiled(_resolve_laser(shooter, target.coord, intent.component), shooter, target.coord)

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
	var parry_need: int = target.armor() + shooter.attack_penalty()
	if shooter.attack_penalty() != 0:
		def_mods.append({"label": "Shooter penetration", "delta": shooter.attack_penalty()})
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
	var fired := want
	# Отчёт заводится ДО очереди: стёкла на линии пишут в него свои броски и осыпаются
	# по ходу (0.9.2), а не после неё.
	var result := ActionResult.new()
	result.ok = true
	# Стёкла между стрелком и целью (#29, 0.9.2): очередь проходит их по одному — попасть
	# в стекло, стекло держит, разбилось, — и до цели долетает лишь то, что прошло все.
	# Ноль стёкол — ни одного лишнего кубика: поток случайности прежних партий цел.
	var glass_cells := _glass_cells_on_line(shooter.coord, target.coord)
	var arriving := want
	if not glass_cells.is_empty():
		hit_mods.append({"label": "Glass on the line", "delta": 0})
		arriving = _through_glass(shooter, glass_cells, want, result)
	# Очередь отстреливается ЦЕЛИКОМ: ровно один кубик на каждую долетевшую пулю (#96).
	# Пули уходят разом, поэтому смерть цели на первой из них очередь НЕ обрывает.
	# Раньше обрывала — а вместе с ней обнулялся и action_state, так что остаток
	# оплаченной одним ОД очереди пропадал, и вместо четырёх бросков игрок видел один.
	for _i in arriving:
		var hit_roll := state.dice.roll_d6()
		var is_hit := hit_roll >= need
		var det := {
			"hit_roll": hit_roll, "need": need, "hit": is_hit,
			"def_roll": 0, "armor": parry_need, "parried": true,
		}
		if is_hit:
			hits += 1
			var def_roll := state.dice.roll_d6()  # цель парирует броском на защиту (§3.5)
			det["def_roll"] = def_roll
			det["parried"] = shield_immune or def_roll >= parry_need
			if not det["parried"]:
				killed = true  # один непарированный удар = смерть (§3.5)
		shot_details.append(det)

	shooter.action_state.remaining_shots -= fired
	# A kill ends only the bullets already fired: the rest of a paid burst (a borg's
	# four, say) stays ready for another target, like any partial burst.
	if shooter.action_state.remaining_shots <= 0:
		shooter.action_state = null
	# Смерть — РАНЬШЕ невесомости: _apply_zero_g отбрасывает только живых, и переставь
	# их местами, труп в космосе начал бы улетать.
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
	_apply_zero_g(shooter, target, result)

	# Гильза на каждый ушедший выстрел (#21.3), вылетают за спину стрелка.
	if fired > 0:
		_fx_lane(result, shooter.coord, target.coord, shooter.owner, "shot", _weapon_of(shooter))  # issue 8
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
	if arriving < fired:
		summary += " — %d of %d got through the glass" % [arriving, fired]
	result.log(summary)
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
		var need := mini(7, hit_need(dist, shooter.fire_range()) + smoke_penalty(shooter.coord, center))
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
	_fx_shot(result, "rocket", shooter.coord, landing)
	# Прямое попадание в ДОТ: бетон забирает весь удар, осколочного поля нет.
	_blast_armor_wall(landing, result)
	if _pillbox_absorbs(landing, MCF.ANTI_TANK_VEHICLE_DAMAGE, result, shooter.coord):
		return result
	var area := MCF.blast_square(landing, MCF.ANTI_TANK_BLAST_RADIUS)
	var killed_names := _blast(landing, result, area, true, true)
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
## То же для главной пушки танка (0.12, самосохранение ИИ): все шесть исходов броска на
## точность — где ляжет снаряд (недолёт той же формулой, _shortfall_landing) и кого
## накроет ромб взрыва. Свои в машине не в счёт: корпус их держит.
func cannon_shot_endangers_own(veh: Vehicle, target: Vector2i) -> bool:
	if veh == null:
		return false
	var port := cannon_port(veh, target)
	if port == Vector2i(-1, -1):
		return false
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get("weapons", {}).get("main_gun", {})
	var need := hit_need(Combat.distance(port, target),
			float(int(gun.get("range", MCF.CANNON_RANGE))))
	for roll in range(1, 7):
		var landing := _shortfall_landing(port, target, roll, need)
		var area := cannon_blast_cells(veh, landing)
		area.append(landing)
		for c: Vector2i in area:
			var cell := state.grid.cell(c)
			if cell == null or cell.occupant == null or not cell.occupant.is_alive():
				continue
			var occ: UnitInstance = cell.occupant
			if occ.aboard_vehicle_id != -1:
				continue
			if occ.owner == veh.owner or state.roster.are_allies(veh.owner, occ.owner):
				return true
	return false

func anti_tank_shot_endangers_own(shooter: UnitInstance, center: Vector2i) -> bool:
	if shooter == null or not _is_anti_tank(shooter):
		return false
	# Выстрел под себя (#11) — гарантированное самоубийство, кубик там не бросается.
	if center == shooter.coord:
		return true
	var need := hit_need(
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
			if cell.feature_id == MCF.FEATURE_TRENCH or _blast_shield(occ):
				continue
		return true
	return false

## Снять «визуальный слепок» зоны ДО взрыва (item 22): прежние объекты клеток и прежняя
## прочность/целость техники в области. UI показывает их, пока крутится кубик выстрела,
## и разрушение не опережает бросок. Чисто косметика — на состояние не влияет.
func _capture_visual_hold(res: ActionResult, area: Array) -> void:
	if res == null:
		return
	if visibility_limited() and not res.visual_hold.has("visible"):
		var seen := {}
		var hidden := {}
		for side: int in state.roster.player_ids():
			seen[side] = team_visible_coords(side).duplicate()
			hidden[side] = visible_complement(side)
		res.visual_hold["visible"] = seen
		res.visual_hold["hidden"] = hidden
	var cells: Dictionary = res.visual_hold.get("cells", {})
	# Nearby doors may close when a blast kills their neighbour. Hold those too.
	var captured := {}
	for at: Vector2i in area:
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				captured[at + Vector2i(dx, dy)] = true
	for c: Vector2i in captured:
		var cell := state.grid.cell(c)
		if cell == null or cells.has(c):
			continue
		cells[c] = {
			"feature_id": cell.feature_id, "feature_durability": cell.feature_durability,
			"cover_height": cell.cover_height, "corpse_count": cell.corpse_count,
			"image": cell.image(),
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
## kills_shield (owner rule 2026-10-19): only a tank shell, an anti-tank round or a
## drone bursting right over it kills a shield bearer, and only on its own cell. Mines
## and exploding wrecks never do.
func _blast(center: Vector2i, res: ActionResult = null, cells: Array[Vector2i] = [],
		epicenter_debris: bool = true, kills_shield: bool = false) -> Array:
	var area: Array[Vector2i] = cells
	if area.is_empty():
		area = MCF.blast_square(center, MCF.ANTI_TANK_BLAST_RADIUS)
	var in_area := {}
	for c: Vector2i in area:
		in_area[c] = true

	var protectors: Array = []
	for u in state.all_units():
		if u.is_alive() and _blast_shield(u) and in_area.has(u.coord) and u.coord != center:
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
		if not u.is_on_field():
			continue
		if not in_area.has(u.coord):
			continue
		if (u.aboard_vehicle_id != -1 and seated_hit.has(u.aboard_vehicle_id)) \
				or (u.borg_id != -1 and seated_hit.has(u.borg_id)):
			continue  # уже разобран как пассажир / оператор борга
		if _blast_shield(u) and (u.coord != center or not kills_shield):
			continue  # щитоносец гибнет только при прямом попадании снаряда, ПТ или дрона
		# Окоп укрывает от взрыва по СОСЕДНЕЙ клетке (#30): осколки идут поверх
		# канавы. Прямое попадание в саму канаву по-прежнему убивает.
		if u.coord != center and state.grid.cell(u.coord).feature_id == MCF.FEATURE_TRENCH:
			continue
		# A shield shelters the soldiers beside it, never the one the blast lands on.
		if u.coord != center and _protected_by(u, protectors):
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
	_fx(res, {"fx": "debris", "at": center if epicenter_debris else NOWHERE, "cells": area,
			"blast": true})
	return killed_names

## Прямое попадание в прочное укрепление (ДОТ, §3.7): бетонная коробка принимает удар
## ЦЕЛИКОМ на себя — теряет damage прочности, а осколочного поля вокруг не возникает
## вовсе, поэтому боец на соседней клетке уцелеет. Считается только попадание ровно в
## клетку ДОТа: взрыв рядом с ним по-прежнему его не задевает.
## true — удар поглощён, вызывающему больше нечего применять.
func _pillbox_absorbs(center: Vector2i, damage: int, res: ActionResult,
		from_coord: Vector2i = NOWHERE) -> bool:
	if not state.grid.in_bounds(center):
		return false
	var cell := state.grid.cell(center)
	# Мебель тоже держит прочность, но удар на себя не принимает: стол не ДОТ, разрыв на
	# нём идёт полной волной и сам стол бьёт через _blast_destroy_terrain.
	if cell.feature_durability <= 0 or Furniture.is_furniture(cell.feature_id) \
			or cell.feature_id == MCF.FEATURE_DRONE_STATION:
		return false
	var was: String = MCF.feature_name(cell.feature_id, cell.feature_id)
	var fid := cell.feature_id
	cell.feature_durability -= damage
	# Бетон откалывается со стороны удара (0.12.1): куски летят к стрелку, по пачке на
	# каждую снятую единицу прочности; рухнувший ДОТ разлетается целиком.
	_wall_chunks(res, center, from_coord if from_coord != NOWHERE else center, fid,
			mini(damage, 4) * PILLBOX_CHUNKS_PER_POINT, true)
	if cell.feature_durability <= 0:
		_wall_chunks(res, center, center, fid)
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
	_knock_items(res, c, from_coord if from_coord != NOWHERE else c)
	for lamp: Array in cell.lamps:   # a blast takes the whole wall tile: every lamp on it, from either side
		_lamp_shards(res, c, from_coord, int(lamp[2]))
	cell.lamps = []
	var fid := cell.feature_id
	# Мебель любой разрыв сносит целиком (§3.15, 0.9.2) — и сейф, и станок.
	if Furniture.is_furniture(fid):
		_destroy_furniture(cell, res, from_coord)
		return
	if fid == MCF.FEATURE_DRONE_STATION:
		_destroy_drone_station(c)
		notify_cell_changed(c)
		return
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
		if CHUNK_WALLS.has(fid):
			_wall_chunks(res, c, from_coord if from_coord != NOWHERE else c, fid)
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
	var jet := flame_cells(shooter.coord, step)
	# Струя на экране (0.12.1): бежит от сопла клетка за клеткой. Мимо _fx(): зерна ей не
	# нужно, а номер события (fx_seq) входит в подпись доски.
	result.fx.append({"fx": "flame_jet", "from": shooter.coord, "cells": jet})
	for c: Vector2i in jet:
		var cell := state.grid.cell(c)
		var occ: UnitInstance = cell.occupant
		# Над космосом струя проходит, но никого не жжёт (editor-rework): пламени без
		# воздуха нет. Дальше, на полу за пробоиной, — жжёт как обычно.
		if occ != null and occ.is_on_field() and not cell.is_space and not is_fireproof(occ):
			_kill_burnt(occ)  # огнемёт — крови нет
			killed_names.append(occ.stats.display_name)
			result.deaths.append(occ.id)
		_ignite(cell, shooter.owner, result)  # поджог пола (§3.8)
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
	return cell.is_wall() or (occ != null and occ.is_alive() and _shield_immunity(occ))

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
## Зажечь клетку — и СЪЕСТЬ её. Всё, что на ней лежало и стояло, исчезает вместе с
## укрытием и глубиной: постройки, мешки, окоп, куча земли, ёж, ДПМГ, а с ними кровь,
## гильзы и отпечатки. Остаются ровно двое, и ни один из них не «постройка»: ТЕЛА
## (стена из пяти трупов — это тела) и МАШИНА (её огонь не трогает вовсе).
##
## Зачистка живёт ЗДЕСЬ, а не у вызывающих, и это главное. Поджечь клетку можно двумя
## путями — струёй огнемёта (§3.8) и расползанием пламени (advance_fire), — и пока
## правило лежало в одном из них, струя оставляла за собой нетронутые мешки и гильзы
## на горящем полу. Теперь путь поджога один, и правило у него одно.
func _ignite(cell: GridCell, owner: int, res: ActionResult = null) -> void:
	# В вакууме гореть нечему (editor-rework): ни струя, ни расползание, ни что-либо ещё
	# космос не поджигают — поджог у клетки один, и правило у него одно.
	if cell.is_space:
		return
	cell.on_fire = true
	cell.fire_owner = owner
	var c := cell.coord
	# Огонь подрывает обычную мину, до которой добрался (item 13). Противотанковую —
	# НЕТ: её взрыватель реагирует лишь на вес гусеницы, не на пламя, — но сама она в
	# огне всё равно гибнет, просто без взрыва, общей зачисткой ниже.
	if cell.feature_id == MCF.FEATURE_MINE and res != null:
		_detonate_mine(c, null, res)
	elif cell.feature_id == MCF.FEATURE_DRONE_STATION:
		_destroy_drone_station(c)
	elif cell.feature_id != MCF.FEATURE_CORPSE_WALL:
		# Загоревшаяся мебель выгорает — и деревянная, и металлическая (0.12.2): раз уж
		# занялась, от неё остаётся пол. Тихо, без разлёта: что стояло на ней, сгорает
		# вместе с клеткой (строкой ниже), а не разлетается из огня.
		cell.clear_feature()
	# Мелкие предметы на горящей клетке сгорают, как и кровь с гильзами (0.12.1): тихо, без разлёта.
	var n_items := mini(state.grid.items_in(c).size(), 30)
	if n_items > 0:
		cell.items_off |= (1 << n_items) - 1
	_fx(res, {"fx": "burn", "cells": [c]})
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
				if destroyed and occ != null and occ.is_on_field():
					_kill_burnt(occ)  # луч прижигает — крови нет (batch ui-drones)
					killed_names.append(occ.stats.display_name)
					result.deaths.append(occ.id)
			"feature":
				var was: String = cell.feature_id
				var cracks := int(rec["cracks"])
				if cracks > 0:
					if was == MCF.FEATURE_DOT:
						_wall_chunks(result, c, shooter.coord, was,
								mini(cracks, 4) * PILLBOX_CHUNKS_PER_POINT, true)
					cell.feature_durability -= cracks
				if destroyed:
					if cell.is_wall():
						blasted.append(c)
					if Furniture.is_furniture(was):
						_destroy_furniture(cell, result)   # только задетая клетка (0.12.2)
					else:
						cell.clear_feature()
					result.log("Beam destroys %s at (%d, %d)" % [
						MCF.feature_name(was, was), c.x, c.y])
					# Стена из трупов рассыпается вдоль траектории луча (таблица §3.13).
					if was == MCF.FEATURE_CORPSE_WALL:
						cell.corpse_count = 0
						_scatter_corpses(c, step, MCF.CORPSE_WALL_COUNT)
						result.log("… bodies scatter along the beam")
				elif cracks > 0:
					result.log("Beam cracks %s at (%d, %d) [durability %d]" % [
						MCF.feature_name(was, was), c.x, c.y, cell.feature_durability])
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
	# The lane shows the aim, not where the beam died: no spoilers before the dice (2026-10-19).
	_fx_lane(result, shooter.coord, aim, shooter.owner, "beam")  # issue 8
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
		# бы там новую стену прямо в трассе только что пробитого прохода. Living soldiers
		# and drones in the beam's path are stepped over too: bodies never land on them.
		if can_drop_corpse_at(cur):
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
		# Граница мира (0.9.3) гасит луч так же: прожечь край поля нельзя.
		if cell.feature_id == MCF.FEATURE_ARMOR_WALL or cell.feature_id == MCF.FEATURE_BOUNDARY:
			rec["kind"] = "terrain"
			rec["label"] = MCF.FEATURE_NAMES[cell.feature_id]
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
		elif occ != null and occ.is_on_field():
			if _shield_immunity(occ):
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
		elif Furniture.is_furniture(cell.feature_id):
			# Мебель луч прожигает за её текущую прочность (§3.15): стул — за единицу,
			# генератор — за пять. Не хватило — луч в ней вязнет.
			rec["kind"] = "feature"
			rec["label"] = Furniture.name_of(cell.feature_id)
			var f_cost := cell.feature_durability
			if potential >= f_cost:
				rec["cost"] = f_cost
				rec["destroyed"] = true
			else:
				rec["stop"] = true
		elif cell.has_feature() and MCF.LASER_COST.has(cell.feature_id):
			rec["kind"] = "feature"
			rec["label"] = MCF.feature_name(cell.feature_id, cell.feature_id)
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
		# Smoke and gas scatter the beam (owner, 2026-10-19): it gets through, weaker.
		if cell.obscured() and not bool(rec["stop"]):
			rec["cost"] = int(rec["cost"]) + mini(MCF.LASER_COST_OBSCURED, potential - int(rec["cost"]))
			if rec["kind"] == "empty":
				rec["label"] = "Gas" if cell.gas else "Smoke"
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
	if shooter.attack_ability() != MCF.ABILITY_MARKSMAN:
		return "Only the marksman fires a laser"
	if not state.grid.in_bounds(cell):
		return "Target out of bounds"
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	if _step_toward(shooter.coord, cell) == Vector2i.ZERO:
		return "Pick a direction to fire in"
	if shooter.remaining_ap < MCF.MARKSMAN_AP_COST:
		return "Laser needs %d AP" % MCF.MARKSMAN_AP_COST
	return ""   # smoke and gas only drain the beam (_laser_trace)

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

# --- Толчок щитом (§3.14) ---
func _resolve_push(intent: PushIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	var err := _validate_actor(actor)
	if err != "":
		return ActionResult.fail(err)
	if not _is_shield(actor):
		return ActionResult.fail("Only a shield bearer can shield-push")
	if intent.target_id == -1:
		return _push_window(actor, intent.target_cell)
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
	var push_from := target.coord
	var push_to := target.coord
	if not survived:
		_kill(target)
	else:
		var back := target.coord + step
		if not state.grid.blocks_walk(back):
			state.grid.move_occupant(target.coord, back)
			push_to = back
			pushed = true

	var result := ActionResult.new()
	result.ok = true
	# Толчок виден как толчок (0.9.4): цель отъезжает на клетку плавно, а не телепортируется.
	if pushed:
		_slide_fx(target, push_from, push_to, result)
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
	if pushed: _gas_on_arrival(target, result)
	return result

## A shield can smash an adjacent pane for 1 AP. Armored glass retains its hold roll.
func _push_window(actor: UnitInstance, coord: Vector2i) -> ActionResult:
	if not state.grid.in_bounds(coord) or Combat.distance(actor.coord, coord) != 1:
		return ActionResult.fail("Window not adjacent")
	var cell := state.grid.cell(coord)
	if not MCF.is_glass(cell.feature_id):
		return ActionResult.fail("No window there")
	actor.remaining_ap -= 1
	var result := ActionResult.success()
	var name := MCF.feature_name(cell.feature_id, "Glass")
	var need := MCF.glass_hold_need(cell.feature_id)
	if need > 0:
		var roll := state.dice.roll_d6()
		result.dice_events.append({"kind": "check", "actor": name,
				"roll": roll, "need": need, "ok": roll >= need})
		if roll >= need:
			result.log("%s strikes the %s with its shield — it holds (roll %d, need %d+)" % [
					actor.stats.display_name, name.to_lower(), roll, need])
			return result
	_capture_visual_hold(result, [coord])
	cell.clear_feature()
	notify_cell_changed(coord)
	_fx(result, {"fx": "shards", "at": coord, "from": actor.coord})
	_fx(result, {"fx": "debris", "at": NOWHERE, "cells": [coord]})
	result.log("%s smashes the %s with its shield" % [actor.stats.display_name, name.to_lower()])
	return result

func pushable_window_cells(actor: UnitInstance) -> Array:
	var out: Array = []
	if not _is_shield(actor) or not actor.is_alive() or actor.remaining_ap <= 0:
		return out
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var coord := actor.coord + Vector2i(dx, dy)
			if coord != actor.coord and state.grid.in_bounds(coord) \
					and MCF.is_glass(state.grid.cell(coord).feature_id):
				out.append(coord)
	return out

func pushable_target_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	if not _is_shield(actor):
		return out
	for u in state.all_units():
		if u.owner != actor.owner and u.is_alive() and Combat.distance(actor.coord, u.coord) == 1:
			out.append(u.id)
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
		if u.owner == actor.owner or not u.is_on_field():
			continue
		if not is_visible_to_team(actor.owner, u):
			continue
		if not Combat.is_on_firing_line(dpmg_coord, u.coord):
			continue
		if los_blocked(dpmg_coord, u.coord, true, false, false, true):
			continue
		if hit_need(Combat.distance(dpmg_coord, u.coord), MCF.DPMG_RANGE) \
				+ smoke_penalty(dpmg_coord, u.coord) >= 7:
			continue
		if _shield_immunity(u) and Combat.distance(dpmg_coord, u.coord) > 1:
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
	if target == null or not target.is_on_field():
		return ActionResult.fail("No target")
	if target.owner == actor.owner:
		return ActionResult.fail("Can't shoot your own")
	if not is_visible_to_team(actor.owner, target):
		return ActionResult.fail("Target not visible")
	if not Combat.is_on_firing_line(intent.dpmg_coord, target.coord):
		return ActionResult.fail("Target not on the firing line")
	if los_blocked(intent.dpmg_coord, target.coord, true, false, false, true):
		return ActionResult.fail("Firing line is blocked")
	if trench_protected(intent.dpmg_coord, target):
		return ActionResult.fail("Target is below the trench line")
	if _shield_immunity(target) and Combat.distance(intent.dpmg_coord, target.coord) > 1:
		return ActionResult.fail("The shield stops fire from range — get next to it")
	var need := hit_need(Combat.distance(intent.dpmg_coord, target.coord), MCF.DPMG_RANGE) \
			+ smoke_penalty(intent.dpmg_coord, target.coord)
	if need >= 7:
		return ActionResult.fail("Too far for the DPMG")

	# Owner (2026-10-19): a DPMG burst is split like a soldier's — fire some rounds now and
	# the rest later from the same gun without new AP, at the same or another target.
	if actor.action_state == null or not actor.action_state.dpmg_pending(intent.dpmg_coord):
		if actor.remaining_ap <= 0:
			return ActionResult.fail("Unit has no AP left")
		actor.remaining_ap -= 1
		actor.action_state = ActionState.new()
		actor.action_state.dpmg = intent.dpmg_coord
		actor.action_state.remaining_shots = MCF.DPMG_RATE_OF_FIRE
	actor.action_state.target_id = target.id
	_face_dpmg(intent.dpmg_coord, target.coord)
	var parry_need: int = target.armor() - _corpse_shield_bonus(target)
	var cover := cover_effect_from(intent.dpmg_coord, target)
	need += cover["hit_penalty"]
	parry_need -= cover["defense_bonus"]
	need = clampi(need, 1, 7)

	var available: int = actor.action_state.remaining_shots
	var want: int = available if intent.shots < 0 else clampi(intent.shots, 1, available)
	var shot_details: Array = []
	var hits := 0
	var killed := false
	var fired := 0
	# All the rounds asked for leave the barrel together: a kill on the first one does not
	# take the rest back (they stay in the burst only if they were never fired).
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
	actor.action_state.remaining_shots -= fired
	var left: int = actor.action_state.remaining_shots
	if left <= 0:
		actor.action_state = null

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
	_fx_lane(result, intent.dpmg_coord, target.coord, actor.owner, "shot", "dpmg")  # issue 8
	_fx_bullets(result, intent.dpmg_coord, target.coord, fired)
	result.log("DPMG (%s) → %s: %d shots, %d hits (need %d+)" % [
		actor.stats.display_name, target.stats.display_name, fired, hits, need])
	if killed:
		result.log("%s killed!" % target.stats.display_name)
	if left > 0:
		result.log("… rounds left in the DPMG burst: %d" % left)
	return result

## Turn the gun toward its target (owner, 2026-10-19). Eight directions, kept in the
## grid's display turns ([id, k] with k = 0 east, clockwise in eighths), so saves, replays
## and every peer draw it the same way.
func _face_dpmg(at: Vector2i, toward: Vector2i) -> void:
	var d := _step_toward(at, toward)
	var k: int = DPMG_DIRS.find(d)
	if k < 0:
		return
	var rec: Variant = state.grid.furniture_turn.get(at)
	if rec is Array and str(rec[0]) == MCF.FEATURE_DPMG and int(rec[1]) == k:
		return
	state.grid.furniture_turn[at] = [MCF.FEATURE_DPMG, k]
	GridCell.log_look_change(at.x, at.y)

# --- Применение предметов / гранаты (§3.6) ---
func _resolve_use_item(intent: UseItemIntent) -> ActionResult:
	var actor := state.get_unit(intent.actor_id)
	# Несомую мебель ставят бесплатно (§3.15) — до проверки ОД.
	if actor != null and Furniture.is_furniture(actor.held_item_id):
		return _put_down_furniture(actor, intent.target)
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
	if (item_id == MCF.ITEM_FRAG or item_id == MCF.ITEM_SMOKE) \
			and actor.coord.x != intent.target.x and actor.coord.y != intent.target.y:
		return ActionResult.fail("Grenades can only be thrown in straight lines")
	if throw_blocked(actor.coord, intent.target):
		return ActionResult.fail("A wall is in the way")
	actor.remaining_ap -= 1
	actor.held_item_id = ""  # предмет расходуется в любом исходе

	if item_id == MCF.ITEM_FRAG:
		return _throw_frag(actor, intent.target)
	elif item_id == MCF.ITEM_SMOKE:
		return _throw_smoke(actor, intent.target)
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
	var need := hit_need(dist, float(MCF.GRENADE_RANGE))
	var roll := state.dice.roll_d6()
	var on_target := roll >= need
	var landing := aim
	if not on_target:
		var shortfall: int = need - roll
		var land_index: int = clampi(dist - shortfall, 0, dist)
		var path := _throw_path(thrower.coord, aim)
		landing = thrower.coord if land_index <= 0 else path[land_index - 1]
	var result := _explode_frag(thrower, landing)
	_fx_shot(result, "grenade", thrower.coord, landing)
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

## Дымовая (0.12): тот же бросок на точность и тот же недолёт, что у осколочной; где легла —
## облако 3×3 (в пределах поля), которое держит взгляд и прицельный огонь до конца
## следующего раунда и никому не вредит. Облака живут рядом с газом (RandomEvents.smoke).
func _throw_smoke(thrower: UnitInstance, aim: Vector2i) -> ActionResult:
	var dist := Combat.distance(thrower.coord, aim)
	var need := hit_need(dist, float(MCF.GRENADE_RANGE))
	var roll := state.dice.roll_d6()
	var on_target := roll >= need
	var landing := aim
	if not on_target:
		var land_index: int = clampi(dist - (need - roll), 0, dist)
		var path := _throw_path(thrower.coord, aim)
		landing = thrower.coord if land_index <= 0 else path[land_index - 1]
	if random_events == null:
		random_events = RandomEvents.new(false)
	var r := MCF.SMOKE_RADIUS
	var x0 := maxi(0, landing.x - r)
	var y0 := maxi(0, landing.y - r)
	var x1 := mini(state.grid.width - 1, landing.x + r)
	var y1 := mini(state.grid.height - 1, landing.y + r)
	random_events.add_smoke(x0, y0, x1 - x0 + 1, y1 - y0 + 1, MCF.SMOKE_ROUNDS)
	_sync_gas()
	var result := ActionResult.success()
	result.dice_events.push_front({
		"kind": "check", "actor": thrower.stats.display_name,
		"roll": roll, "need": need, "ok": on_target,
	})
	if on_target:
		result.log("%s throws a smoke grenade: smoke at (%d, %d) (roll %d, need %d+)." % [
			thrower.stats.display_name, landing.x, landing.y, roll, need])
	else:
		result.log("%s throws a smoke grenade short: smoke at (%d, %d) (roll %d, need %d+)." % [
			thrower.stats.display_name, landing.x, landing.y, roll, need])
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
## со штрафом −1 каждый (щитоносец — без штрафа, 2+); выживают только если ОБА парируют. Задевает всех, включая своих.
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
		if not u.is_on_field():
			continue
		if not in_area.has(u.coord):
			continue
		var at_epicenter: bool = u.coord == center
		var det := {
			"name": u.stats.display_name, "coord": u.coord, "owner": u.owner,
			"epicenter": at_epicenter, "armor": u.armor(),
			"need": u.armor() + 1, "rolls": [], "survived": true,
		}
		var is_shield: bool = _blast_shield(u)
		if is_shield:
			det["shielded"] = true # owner rule: a frag grenade never kills a shield bearer
		elif at_epicenter:
			det["survived"] = false
		else:
			# Штраф −1 к каждому кубику; несомый труп-щит облегчает защиту (#6).
			var need_roll: int = u.armor() + 1 - _corpse_shield_bonus(u)
			det["need"] = need_roll
			for _i in 2:
				var r := state.dice.roll_d6()
				det["rolls"].append(r)
				if r < need_roll:
					det["survived"] = false
		if not det["survived"]:
			_kill(u, result, center, true)
			killed_names.append(u.stats.display_name)
		details.append(det)

	# Мебель осколочная сносит, как и любой разрыв (0.9.2): раньше она была единственным
	# взрывом, после которого стол оставался стоять.
	var smashed: Array = []
	for fc: Vector2i in area:
		if state.grid.in_bounds(fc) and state.grid.cell(fc).feature_id == MCF.FEATURE_DRONE_STATION:
			_capture_visual_hold(result, [fc])
			_destroy_drone_station(fc)
			notify_cell_changed(fc)
		if state.grid.in_bounds(fc) and Furniture.is_furniture(state.grid.cell(fc).feature_id) \
				and fixture_at(fc) == "":   # lamps roll below, like glass (0.11.1)
			smashed.append(fc)
			_destroy_furniture(state.grid.cell(fc), result, center)
	# Lamps in the blast defend like ordinary glass (0.11.1): two dice against 6+, both
	# must hold. A standing lamp anywhere in the area; a wall lamp only on the face that
	# looks at the blast (the wall shields the other side).
	for lc: Vector2i in area:
		if not state.grid.in_bounds(lc): continue
		var lcell := state.grid.cell(lc)
		var lamps: Array = [] if fixture_at(lc) == "" else [-1]
		for lamp: Array in lcell.lamps:
			if faces_lamp(lc, int(lamp[2]), center): lamps.append(int(lamp[2]))
		for side: int in lamps:
			var lid := fixture_at(lc, side)
			var ldet := {"name": Furniture.DEFS[lid].name, "coord": lc, "owner": lcell.feature_owner,
				"epicenter": false, "armor": GLASS_ARMOR, "need": GLASS_ARMOR + 1, "rolls": [], "survived": true}
			for _i in 2:
				var lr := state.dice.roll_d6()
				ldet["rolls"].append(lr)
				if lr < GLASS_ARMOR + 1: ldet["survived"] = false
			if not ldet["survived"]:
				if side >= 0:
					_lamp_shards(result, lc, center, side)
					lcell.lamps = MapData.without_lamp(lcell.lamps, side)
					notify_cell_changed(lc)
				else:
					smashed.append(lc)
					_destroy_furniture(lcell, result, center)
			details.append(ldet)
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
			"name": MCF.feature_name(gcell.feature_id, "Glass"), "coord": gc,
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
	_fx(result, {"fx": "debris", "at": center, "cells": [center] + broken_glass, "blast": true})
	result.dice_events.append({
		"kind": "grenade", "item": MCF.ITEM_FRAG,
		"thrower": thrower.stats.display_name, "center": center, "targets": details,
	})
	result.log("%s throws a frag grenade at (%d, %d)" % [
		thrower.stats.display_name, center.x, center.y])
	if not smashed.is_empty():
		result.log("Furniture blown apart (%d cell%s)" % [smashed.size(), "" if smashed.size() == 1 else "s"])
	if killed_names.is_empty() and broken_glass.is_empty() and smashed.is_empty():
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
		MCF.ITEM_SMOKE:
			return MCF.blast_square(center, MCF.SMOKE_RADIUS)
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
			if state.grid.cell(c).is_wall() or throw_blocked(actor.coord, c):
				continue
			out.append(c)
	return out

## A throw never passes a wall (playtest 2026-10-19: the AI lobbed grenades through them).
## Low cover is thrown over; a wall, closed airlock or pane on the line stops it.
func throw_blocked(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	for c: Vector2i in _throw_path(from_coord, to_coord):
		if c != to_coord and state.grid.in_bounds(c) and state.grid.cell(c).is_wall():
			return true
	return false

func capturable_target_ids(actor: UnitInstance) -> Array:
	var out: Array = []
	for u in state.all_units():
		if u.id == actor.id or u.captor_id != -1 or u.aboard_vehicle_id != -1:
			continue
		if u.is_alive() and Combat.distance(actor.coord, u.coord) == 1:
			out.append(u.id)
	return out

## A wall lamp hangs on one face of its wall: only someone on that side can see it (0.11).
static func faces_lamp(c: Vector2i, side: int, from: Vector2i) -> bool:
	var n: Vector2i = Furniture.N4[side]
	return (from.x - c.x) * n.x + (from.y - c.y) * n.y > 0
