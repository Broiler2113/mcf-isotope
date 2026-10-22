@abstract
extends "res://scenes/main/MainAnnotations.gd"

## Playing results out: dice, walks, vehicle moves, shots, flame jets and effects.

## Показать отыгранный слот мирных (#96): сначала анимация их шагов и бросков, и лишь
## затем строки в журнал — иначе лог сообщал бы об убитом раньше, чем упадёт кубик.
func _play_civilian_result(res: ActionResult) -> void:
	if not res.dice_events.is_empty():
		_pending_death_ids.clear()
		for id: int in res.deaths:
			_pending_death_ids[id] = true
		queue_redraw()
		_fast_playback = true  # item 32: нейтральный слот идёт ускоренно
		_fx.preview_lanes(res.fx)   # who fires at whom shows while the dice roll
		await _play_dice(res.dice_events)
		_fast_playback = false
		queue_redraw()
	# Остальная косметика ложится ПОСЛЕ броска (иначе кровь опережала бы решение кубика), а
	# труп и кровь — когда пуля долетела (0.12.1).
	await _show_effects(res)
	# Слот отыгран — подсветку «сейчас ходит» снимаем (item 6).
	_playing_slot = -1
	if _init_overlay != null and _init_overlay.visible:
		_refresh_initiative_overlay()
	if _result_is_audible(res):
		state.log.publish_result(res)
	_refresh_status()

## Проиграть все броски результата по одному. Броски попадания идут автоматически,
## броски защиты ждут ручного нажатия «Roll» защищающимся игроком (§3.5).
## hidden — действие чужого бойца, которого зритель не видит (issues-12 #4): его броски
## не показываются вовсе, а свою защиту игрок катит без чужих подробностей.
func _play_dice(events: Array, hidden := false) -> void:
	_animating = true
	var fast_before := _fast_playback
	# Точки ОД отматываем к тому, что было ДО хода: дальше события гасят их по одной.
	for ev in events:
		if ev.get("kind", "") == "ap" and not _ap_display.has(int(ev["unit"])):
			_ap_display[int(ev["unit"])] = int(ev["from"])
	# Item 23: hold идёт первым и СНИМАЕТ всех будущих ходоков в их стартовые клетки,
	# чтобы во время анимации никто не «стоял уже в конце». Состояние менять не надо —
	# только рисуемую позицию (_walk_cells), поэтому рассинхрона тут быть не может.
	for ev in events:
		if ev.get("kind", "") == "hold":
			for id in ev["units"]:
				if not _walk_cells.has(int(id)):
					_walk_cells[int(id)] = ev["units"][id]
		elif ev.get("kind", "") == "veh_walk":
			# Машина (и пассажиры в креслах) рисуется на старте, пока до неё не дошла очередь.
			_set_veh_offset(ev, 1.0)
	queue_redraw()  # (состояние уже применено; кадр обновится после анимации)
	for ev in events:
		# Игрок вышел из партии прямо посреди показа (item 10): смена сцены уже забрала
		# узел, get_tree() ниже вернул бы null. Обрываем показ — показывать некому.
		if not is_inside_tree():
			_animating = false
			return
		if replay != null and _replay_skip_animations:
			break
		if ev.get("kind", "") == "hold":
			continue
		if ev.get("kind", "") == "slot":
			# Начался ход нейтральной группы (item 6) — подсвечиваем её в списке.
			_playing_slot = int(ev.get("owner", -1))
			# Ходы жителей после конца хода — ускоренно, как и открывающий слот (batch
			# ui-drones: «конец раунда тянется»). Раньше ускорялся лишь слот в начале боя.
			_fast_playback = true
			_refresh_status()   # и строка хода, и окно инициативы — на ходящую группу
			continue
		if ev.get("kind", "") == "focus":
			# Камеру за ходящими нейтралами БОЛЬШЕ НЕ ВОДИМ (item 8): игрока раздражало,
			# что вид дёргается к каждому активному жителю. Событие оставляем (оно ещё
			# помечает, чьи кубики крутятся), но камеру не трогаем — панорама за игроком.
			continue
		if ev.get("kind", "") == "veh_walk":
			await _await_walks()
			await _play_veh_walk(ev)
			continue
		if ev.get("kind", "") == "effects":
			# One raider's or civilian's action, shown where it happened in the turn.
			await _await_walks()
			var part := ActionResult.success()
			part.fx = ev["fx"]
			part.deaths.assign(ev.get("deaths", []))
			part.visual_deaths.assign(ev.get("visual_deaths", []))
			await _show_effects(part, true)
			for fx_ev: Dictionary in part.fx:
				fx_ev["_shown"] = true
			continue
		if ev.get("kind", "") == "walk":
			# One actor cannot run two interpolation jobs simultaneously.
			if _walk_jobs.has(int(ev["unit"])):
				await _await_walks()
			# Подряд идущие переходы (групповой приказ) играются ОДНОВРЕМЕННО: отряд
			# идёт вместе, а не бойцы по очереди.
			_play_walk(ev)
			if not ev.get("soldier", false):
				await _await_walks()
			continue
		await _await_walks()
		# Выход из партии во время ожидания перехода (item 10): узел ушёл из дерева, и
		# любой get_tree() ниже (пауза точки AP, таймер стекла) упал бы на null.
		if not is_inside_tree():
			_animating = false
			return
		if ev.get("kind", "") == "ap":
			_ap_display[int(ev["unit"])] = int(ev["left"])
			queue_redraw()
			await get_tree().create_timer(
					(NEUTRAL_AP_DOT_DELAY if _fast_playback else AP_DOT_DELAY) / _pace()).timeout
			continue
		for step in _dice_steps(ev):
			if replay != null and _replay_skip_animations:
				break
			# Ручной бросок ждёт нажатия только у защитника-человека; мирные (NEUTRAL)
			# и ИИ кидают защиту автоматически, но анимация всё же видна (#64).
			# В сети (batch 12 #14) нажатия ждут ВСЕ: свой бросок — кнопкой, чужой — пока
			# его хозяин не нажмёт у себя. Броски ИИ и мирных крутятся сами.
			var roller := int(step.get("roller", MCF.Owner.NEUTRAL))
			var remote_human: bool = networked and not bool(step["manual"]) and not step.get("auto", false) \
					and state.roster != null and state.roster.is_networked_human(roller)
			if hidden:
				if not bool(step["manual"]):
					if remote_human:
						_roll_seq += 1   # счёт бросков общий у всех пиров — шаг занимает номер
					continue
				# Осталась только последняя строка — «бросай защиту (нужно N+)».
				var lines := str(step["prompt"]).split("\n")
				step["prompt"] = lines[lines.size() - 1]
			if networked and (bool(step["manual"]) or remote_human):
				var seq := _roll_seq
				_roll_seq += 1
				if step["manual"]:
					_dice.play(step["faces"], true, step["prompt"], step.get("speed", 1.0) * _pace())
					await _dice.rolled
					session.send({"k": K_ROLL, "n": seq})
					await _dice.finished
				else:
					_dice.play(step["faces"], false, "%s\nWaiting for %s to roll…" % [
						step["prompt"], state.roster.name_of(roller)], step.get("speed", 1.0) * _pace(), true)
					# Ушедший игрок не нажмёт никогда (batch 13 #2): как только ростер
					# перестаёт считать его живым человеком за сетью, ждать нечего.
					while not _roll_inbox.has(seq) and state.roster.is_networked_human(roller):
						await _roll_arrived
					_roll_inbox.erase(seq)
					_dice.release()
					await _dice.finished
				continue
			# 8× и быстрее (кнопка «быстрее» для ИИ) и ход жителей: автоматический бросок не
			# показываем — итог всё равно в журнале, а кубики съедали почти весь ход.
			if not step["manual"] and (_pace() >= 8.0 or _fast_playback):
				continue
			_dice.play(step["faces"], step["manual"], step["prompt"], step.get("speed", 1.0) * _pace())
			await _dice.finished
		# Стекло осыпается сразу после своих бросков (0.9.2) — до бросков по цели за ним.
		if ev.get("kind", "") == "glass" and bool(ev.get("broke", false)):
			_hold_visual.get("cells", {}).erase(ev["cell"])
			_fx.apply(ev["fx"])
			queue_redraw()
			if _pace() < 8.0 and not _fast_playback and is_inside_tree():
				await get_tree().create_timer(GLASS_BREAK_PAUSE / _pace()).timeout
	await _await_walks()
	_walk_cells.clear()
	_walk_offset.clear()
	_veh_offset.clear()
	_ap_display.clear()
	_animating = false
	_fast_playback = fast_before
	# Ходы нейтральных групп отыграны — окно инициативы снова показывает настоящую
	# активную сторону. Без сброса «▶» навсегда оставался на последней группе жителей.
	if _playing_slot != -1:
		_playing_slot = -1
		_refresh_status()
	queue_redraw()

func _await_walks() -> void:
	var t0 := Time.get_ticks_msec()
	# is_inside_tree(): выход из партии посреди перехода забирает узел, и process_frame
	# ниже ждать уже негде (item 10).
	while _walks_running > 0 and is_inside_tree():
		if Time.get_ticks_msec() - t0 > WALK_WAIT_LIMIT_MS:
			push_warning("walk animation did not finish in %d ms (%d running) - continuing"
					% [WALK_WAIT_LIMIT_MS, _walks_running])
			_walks_running = 0
			_walk_jobs.clear()
			_walk_cells.clear()
			_walk_offset.clear()
			break
		await get_tree().process_frame

## Переезд машины (batch borg-corpses): корпус и пассажиры в креслах скользят от старта к
## концу с той же скоростью на клетку, что и бойцы. k — сколько пути ещё впереди (1..0).
func _set_veh_offset(ev: Dictionary, k: float) -> void:
	var veh := state.get_vehicle(int(ev["vehicle"]))
	if veh == null:
		return
	var off := Vector2(Vector2i(ev["from"]) - veh.origin) * CELL * k
	_veh_offset[veh.id] = off
	for u: UnitInstance in _veh_riders(veh):
		_walk_offset[u.id] = off

## Кто летит вместе с челноком: пассажиры в креслах и дрон, сидящий на станции в кресле
## (issues-12 #7) — раньше дрон и станция оказывались в конце пути раньше машины.
func _veh_riders(veh: Vehicle) -> Array[UnitInstance]:
	var out: Array[UnitInstance] = []
	var fp := veh.footprint()
	for u: UnitInstance in state.all_units():
		if not state.grid.in_bounds(u.coord):
			continue
		if u.aboard_vehicle_id == veh.id \
				or (u.is_drone and u.is_alive() and u.coord == u.home_station and fp.has(u.coord)):
			out.append(u)
	return out

func _play_veh_walk(ev: Dictionary) -> void:
	var engine: AudioStreamPlayer2D = null
	var engine_generation := -1
	if _audio != null:
		var moving := state.get_vehicle(int(ev["vehicle"]))
		engine = _audio.cue("vehicle_move", ev["from"], moving.owner if moving != null else -1)
		if engine != null: engine_generation = int(engine.get_meta("audio_generation", 0))
	var steps := maxi(1, int(ev.get("steps", 1)))
	var cell_time := maxf(SOLDIER_WALK_STEP_DELAY / _pace(), 0.12) if _fp != null else SOLDIER_WALK_STEP_DELAY / _pace()
	var dur_ms := cell_time * steps * 1000.0
	var t0 := Time.get_ticks_msec()
	var stages := _vehicle_presentation_stages(ev)
	var shown_step := -1
	while is_inside_tree():
		if replay != null and _replay_skip_animations:
			break
		var k := minf(1.0, float(Time.get_ticks_msec() - t0) / maxf(1.0, dur_ms))
		_set_veh_offset(ev, 1.0 - k)
		var moving := state.get_vehicle(int(ev["vehicle"]))
		if _audio != null and moving != null:
			var audio_cell := Vector2i(Vector2(ev["from"]).lerp(Vector2(moving.origin), k).floor())
			engine = _audio.vehicle_at(engine, engine_generation, audio_cell, moving.owner)
			if engine != null: engine_generation = int(engine.get_meta("audio_generation", 0))
		var reached := mini(steps, floori(k * steps + 0.5))
		while shown_step < reached:
			shown_step += 1
			_reveal_vehicle_stage(stages.get(shown_step, {}))
		queue_redraw()
		if k >= 1.0:
			break
		await get_tree().process_frame
	for step: int in stages:
		if step > shown_step: _reveal_vehicle_stage(stages[step])
	var veh := state.get_vehicle(int(ev["vehicle"]))
	if veh != null:
		_veh_offset.erase(veh.id)
		for u: UnitInstance in _veh_riders(veh):
			_walk_offset.erase(u.id)
	if _audio != null:
		_audio.stop_player(engine, engine_generation)
	queue_redraw()

func _play_walk(ev: Dictionary) -> void:
	var id := int(ev["unit"])
	_walk_serial += 1
	var serial := _walk_serial
	_walk_jobs[id] = serial
	_walks_running += 1
	var u := state.get_unit(id)
	var base: float = DRONE_FLY_STEP_DELAY if u != null and u.is_drone \
			else (SOLDIER_WALK_STEP_DELAY if ev.get("soldier", false)
			else (NEUTRAL_WALK_STEP_DELAY if _fast_playback else WALK_STEP_DELAY))
	var cell_time := maxf(base / _pace(), 0.16) if _fp != null else base / _pace()
	var step_us := maxf(1.0, cell_time * 1000000.0)
	var prev: Vector2i = ev["from"]
	_walk_cells[id] = prev
	var buzz: AudioStreamPlayer2D = null
	var buzz_generation := -1
	var path: Array = ev["path"]
	var t0 := Time.get_ticks_usec()
	var completed := 0
	# One clock for the whole path: rounding a separate clock for every cell added a
	# pause at each corner and made speed depend on how many frames a cell took.
	while is_inside_tree() and completed < path.size():
		if replay != null and _replay_skip_animations:
			break
		if _walk_jobs.get(id, -1) != serial:
			_walks_running = maxi(0, _walks_running - 1)
			if _audio != null: _audio.stop_player(buzz, buzz_generation)
			return
		var progress := minf(float(path.size()), (Time.get_ticks_usec() - t0) / step_us)
		while completed < floori(progress):
			var cell: Vector2i = path[completed]
			if _audio != null and u != null:
				if not u.is_drone: _step_sounds.append([u, prev, cell])
				else:
					buzz = _audio.vehicle_at(buzz, buzz_generation, cell, u.owner, "drone_move")
					if buzz != null: buzz_generation = int(buzz.get_meta("audio_generation", 0))
			prev = cell
			_walk_cells[id] = cell
			completed += 1
		if completed < path.size():
			_walk_offset[id] = Vector2(Vector2i(path[completed]) - prev) * CELL * (progress - completed)
		else:
			_walk_offset.erase(id)
		queue_redraw()
		if completed < path.size(): await get_tree().process_frame

	if _audio != null: _audio.stop_player(buzz, buzz_generation)
	if _walk_jobs.get(id, -1) != serial:
		_walks_running = maxi(0, _walks_running - 1)
		return
	_walk_jobs.erase(id)
	# Keep the visual endpoint until the whole action has finished.
	_walk_offset.erase(id)
	_walks_running = maxi(0, _walks_running - 1)
	queue_redraw()

## Only soldiers walking — no dice, deaths, mines, gas or vehicles (0.11).
func _walks_only(events: Array) -> bool:
	var walked := false
	for ev: Dictionary in events:
		match str(ev.get("kind", "")):
			"walk":
				if not ev.get("soldier", false): return false
				walked = true
			"hold", "ap": pass
			_: return false
	return walked

func _play_walks_free(events: Array) -> void:
	for ev: Dictionary in events:
		if str(ev.get("kind", "")) == "walk":
			_free_walk(ev)

func _free_walk(ev: Dictionary) -> void:
	var id := int(ev["unit"])
	await _play_walk(ev)
	# The unit was ordered on again, or a blocking show took over: they own the drawing.
	if not _walk_jobs.has(id) and not _animating and is_inside_tree():
		_walk_cells.erase(id)
		_walk_offset.erase(id)
		queue_redraw()

## Юнит этого владельца управляется локальным человеком (значит, его броски защиты
## ждут ручного нажатия)? Мирные (NEUTRAL) и ИИ — нет: у них нет контроллера-человека.
func _owner_is_local_human(owner_id: int) -> bool:
	# В сетевой игре бросок защиты кидает ТОТ, КОГО бьют, на своём экране (#93).
	# Исход уже определён (у клиента броски подставные), кнопка — только жест игрока,
	# поэтому рассинхрона не будет, а у противника кубик крутится сам.
	if networked:
		return owner_id == my_owner
	var ctrl: PlayerController = controllers.get(owner_id)
	return ctrl != null and ctrl.is_local_human()

## Разбить событие бросков на отдельные шаги: {faces, manual, prompt}.
## Каждый шаг — один кубик, чтобы попадание и пробитие крутились по очереди.
## Цвет кубика с точки зрения смотрящего (batch ui-drones): удача бросавшего — зелёная,
## если бросал свой или союзник, и красная, если бросал противник (его неудачная защита —
## зелёная для нас). Хозяин броска неизвестен (-1) — как раньше, по самому броску.
func _good_for_viewer(success: bool, roller: int) -> bool:
	if roller < 0 or state == null or state.roster == null:
		return success
	var me := _viewing_side()
	var mine: bool = roller == me or (MCF.is_player(roller) and state.roster.are_allies(me, roller))
	return success if mine else not success

func _dice_steps(ev: Dictionary) -> Array:
	var steps: Array = []
	match ev["kind"]:
		"glass", "fixture":
			# Стекло на пути очереди (0.9.2): стрелок бросает попадание в стекло, стекло —
			# спасбросок за каждую попавшую пулю; осыпается оно после этих бросков.
			var g_own := int(ev.get("shooter_owner", -1))
			var g_faces: Array = []
			for h: Dictionary in ev["hits"]:
				g_faces.append({"value": h["roll"], "good": _good_for_viewer(h["hit"], g_own), "need": int(ev["need"]),
					"tag": ("Light %d+" if ev["kind"] == "fixture" else "Glass %d+") % int(ev["need"])})
			var g_manual := _owner_is_local_human(g_own)
			var g_name := String(ev["name"]).to_lower()
			steps.append({"faces": g_faces, "manual": g_manual, "roller": g_own,
				"speed": FAST_ROLL_SPEED if int(ev["need"]) <= 1 else 1.0,
				"prompt": ("Your shot — roll to hit the %s (need %d+)" if g_manual
						else "To hit the %s (need %d+)") % [g_name, int(ev["need"])]})
			if not (ev["saves"] as Array).is_empty():
				var s_faces: Array = []
				for sv: Dictionary in ev["saves"]:
					s_faces.append({"value": sv["roll"], "good": _good_for_viewer(not sv["held"], g_own),
						"need": int(ev["save"]), "tag": "Holds %d+" % int(ev["save"])})
				steps.append({"faces": s_faces, "manual": false, "roller": MCF.Owner.NEUTRAL,
					"speed": FAST_ROLL_SPEED if int(ev["save"]) > 6 else 1.0,
					"prompt": "The %s holds on %d+" % [g_name, int(ev["save"])]})
		"attack":
			# Ни одна пуля не прошла стёкла — бросать по цели нечего.
			if (ev["shots"] as Array).is_empty():
				return steps
			# Сначала ВСЕ броски попадания разом, затем ВСЕ броски пробитии разом (§3.5).
			var hit_faces: Array = []
			var pen_faces: Array = []
			for det in ev["shots"]:
				var s_own := int(ev.get("shooter_owner", -1))
				var d_own := int(ev.get("def_owner", -1))
				hit_faces.append({"value": det["hit_roll"], "need": int(det["need"]),
					"good": _good_for_viewer(det["hit"], s_own), "tag": "Hit %d+" % det["need"]})
				if det["hit"]:
					# Зелёный — то, что хорошо для СМОТРЯЩЕГО (batch ui-drones): своя защита не
					# выдержала — красный, вражеская — зелёный.
					pen_faces.append({"value": det["def_roll"], "need": int(det["armor"]),
						"good": _good_for_viewer(det["parried"], d_own), "tag": "Pen %d+" % det["armor"]})
			# Разбивка бонусов/штрафов к попаданию и защите (#49): показываем в подсказке.
			var hit_note := _mods_text("To-hit", ev.get("hit_mods", []))
			# Бросок на попадание катит САМ стрелок, если это местный человек (item 13):
			# ждём его нажатия, как и бросок защиты у защищающегося.
			var shooter_owner := int(ev.get("shooter_owner", MCF.Owner.NEUTRAL))
			var hit_manual := _owner_is_local_human(shooter_owner)
			# Сколько нужно выкинуть — в подсказке ДО броска (batch 12 #14).
			var hit_need := _need_text(ev["shots"], "need")
			var hit_prompt := hit_note
			if hit_manual:
				hit_prompt = (hit_note + "\n" if hit_note != "" else "") \
						+ "Your shot — roll to hit" + hit_need
			elif hit_need != "":
				hit_prompt = (hit_note + "\n" if hit_note != "" else "") + "To hit" + hit_need
			steps.append({"faces": hit_faces, "manual": hit_manual, "prompt": hit_prompt,
				"speed": _roll_speed(ev["shots"], "need"), "roller": shooter_owner})
			if not pen_faces.is_empty():
				var def_note := _mods_text("Defense", ev.get("def_mods", []))
				var def_owner := int(ev.get("def_owner", MCF.Owner.NEUTRAL))
				var def_need := _need_text(_hit_shots(ev["shots"]), "armor")
				var prompt: String = DEFENSE_PROMPT + def_need
				if def_note != "":
					prompt = def_note + "\n" + prompt
				var manual := _owner_is_local_human(def_owner)
				steps.append({"faces": pen_faces, "manual": manual, "prompt": prompt,
					"roller": def_owner, "speed": _defense_roll_speed(_hit_shots(ev["shots"]))})
		"opposed":
			steps.append(_step({"value": ev["a_roll"], "good": ev["attacker_wins"], "tag": "Grab"}))
			var resist := _step(
				{"value": ev["d_roll"], "good": not ev["attacker_wins"], "tag": "Def"},
				_owner_is_local_human(ev.get("def_owner", MCF.Owner.NEUTRAL)),
				RESIST_PROMPT + " (beat %d)" % int(ev["a_roll"]))
			resist["roller"] = int(ev.get("def_owner", MCF.Owner.NEUTRAL))
			steps.append(resist)
		"check":
			var chk := _step({"value": ev["roll"], "need": int(ev["need"]),
				"good": _good_for_viewer(ev["ok"], int(ev.get("roller", -1))), "tag": "%d+" % ev["need"]})
			chk["speed"] = FAST_ROLL_SPEED if int(ev["need"]) <= 1 else 1.0
			steps.append(chk)
		"grenade":
			# Все броски защиты по осколкам — одним общим броском (§3.6).
			var frag_faces: Array = []
			for det in ev["targets"]:
				if det["epicenter"] and det["rolls"].is_empty():
					continue  # эпицентр: автосмерть без броска
				for r in det["rolls"]:
					frag_faces.append({"value": r, "need": int(det["need"]),
						"good": _good_for_viewer(r >= det["need"], int(det.get("owner", -1))),
						"tag": "R%d+" % det["need"]})
			if not frag_faces.is_empty():
				# Ручной бросок — только если под осколки попал юнит-человек; если это
				# лишь мирные/ИИ, защита катится сама (но видна).
				var manual := false
				var roller := MCF.Owner.NEUTRAL
				for det in ev["targets"]:
					if _owner_is_local_human(det.get("owner", MCF.Owner.NEUTRAL)):
						manual = true
						roller = int(det.get("owner", MCF.Owner.NEUTRAL))
						break
				# В сети кидает первый человек под осколками (batch 12 #14).
				if networked and not manual:
					for det in ev["targets"]:
						var o := int(det.get("owner", MCF.Owner.NEUTRAL))
						if state.roster != null and state.roster.is_networked_human(o):
							roller = o
							break
				steps.append({"faces": frag_faces, "manual": manual, "speed": _defense_roll_speed(ev["targets"], "need"),
					"prompt": DEFENSE_PROMPT + _need_text(ev["targets"], "need"),
					"roller": roller})
	for step: Dictionary in steps:
		if _impossible(step["faces"]):
			# Nothing to decide: no Roll button here, and no peer waits for one either.
			step["manual"] = false
			step["auto"] = true
			step["speed"] = FAST_ROLL_SPEED
			step["prompt"] = (str(step.get("prompt", "")) + "\n").lstrip("\n") + "Cannot succeed — needs 7+"
	return steps

## Every die of the step needs more than 6 (0.11): an automatic failure, never a prompt.
func _impossible(faces: Array) -> bool:
	if faces.is_empty():
		return false
	for f: Dictionary in faces:
		if int(f.get("need", 0)) <= 6:
			return false
	return true

## «(need 4+)» по списку записей с полем-порогом (batch 12 #14); при разных порогах —
## все через запятую. Пусто, если порогов нет или все заведомо проходят.
func _need_text(entries: Array, key: String) -> String:
	var seen: Array[int] = []
	for e in entries:
		var n := int(e.get(key, 0))
		if n > 0 and not seen.has(n):
			seen.append(n)
	if seen.is_empty():
		return ""
	seen.sort()
	var parts: Array[String] = []
	for n in seen:
		parts.append("%d+" % n)
	return " (need %s)" % ", ".join(parts)

func _hit_shots(shots: Array) -> Array:
	var out: Array = []
	for det in shots:
		if det.get("hit", false) and not det.get("stopped_by_glass", false):
			out.append(det)
	return out

func _step(face: Dictionary, manual: bool = false, prompt: String = "") -> Dictionary:
	return {"faces": [face], "manual": manual, "prompt": prompt}

func _defense_roll_speed(entries: Array, key: String = "armor") -> float:
	if entries.is_empty():
		return 1.0
	for entry: Dictionary in entries:
		if int(entry.get(key, 6)) <= 6:
			return 1.0
	return FAST_ROLL_SPEED

func _roll_speed(entries: Array, key: String) -> float:
	if entries.is_empty():
		return 1.0
	for e in entries:
		if int(e.get(key, 7)) > 1:
			return 1.0
	return FAST_ROLL_SPEED

## Человекочитаемая строка со всеми бонусами/штрафами броска (#49). Пусто — если нет.
## delta 0 = особый эффект (авто-попадание, иммунитет щита) без числа.
func _mods_text(header: String, mods: Array) -> String:
	if mods.is_empty():
		return ""
	var parts: Array[String] = []
	for m in mods:
		var d: int = m.get("delta", 0)
		if d == 0:
			parts.append(str(m.get("label", "")))
		else:
			parts.append("%s %+d" % [m.get("label", ""), d])
	return "%s: %s" % [header, ", ".join(parts)]

## Всё, что идёт ПОСЛЕ бросков (0.12.1): струя огнемёта, полёт пуль и снарядов, и только по
## попаданию — трупы, кровь, осколки, взрыв и снесённые стены. Здесь же снимаются держатели
## «до броска» (_pending_death_ids, _hold_visual), а остаток косметики ложится разом.
## partial — one action out of a neutral turn, shown mid-stream: it releases only its own
## dead and leaves the turn's "before impact" view to the whole result.
func _show_effects(result: ActionResult, partial := false) -> void:
	if not result.cheat_cells.is_empty():
		var live := TerrainTiles.new(state.grid, state.env)
		for at: Vector2i in result.cheat_cells:
			_furniture_look.erase(at)
			var cell := state.grid.cell(at)
			if cell != null and Furniture.is_furniture(cell.feature_id):
				_furniture_look[at] = [cell.feature_id] + live._live_look(at, cell.feature_id)
			if _tiles != null: _tiles._touch(at)
		_lod_terrain_key = []
	# Пока летит пуля или струя, экран занят, как во время броска: ни щелчок игрока, ни шаг
	# ИИ не должны начать следующее действие посреди полёта.
	var was_animating := _animating
	_animating = true
	# Lanes also drive muzzle lighting: launch them with the shot, after the dice. Effects
	# already shown mid-turn ("effects" events) are not launched twice.
	_fx.apply_lanes(result.fx.filter(func(e: Dictionary) -> bool: return not e.has("_shown")))
	await _play_flame_jets(result)
	await _play_shots(result)
	_animating = was_animating
	if partial:
		for id: int in result.deaths + result.visual_deaths:
			_pending_death_ids.erase(id)
	else:
		_pending_death_ids.clear()
		_hold_visual = {}
	var rest := result.fx.filter(func(e: Dictionary) -> bool: return not e.has("_shown"))
	if not rest.is_empty():
		_fx.apply(rest, result.fx.any(func(e: Dictionary) -> bool: return e.get("fx") == "shot"))
	if _audio != null:
		_audio.action_result(result, state)
	queue_redraw()

## Пули и снаряды летят, а жертвы держатся живыми, пока их не настигнет попадание: трассер
## отпускает убитых в своей клетке-цели и косметику этой клетки (кровь, осколки), снаряд —
## всех убитых и всю косметику действия (взрыв). Гильзы вылетают сразу, с выстрелом.
## На 8× и быстрее и в пропущенном показе повтора — без ожидания, как и кубики.
func _play_shots(result: ActionResult) -> void:
	var flights: Array = []   # [время попадания, клетка, взрыв?]
	var launch: Array = []
	for ev: Dictionary in result.fx:
		if ev.has("_shown"):
			continue   # already shown mid-turn ("effects")
		match str(ev.get("fx", "")):
			"tracer":
				var to: Array = ev.get("to", [])
				if to.size() >= 2:
					launch.append(ev)
					flights.append([FxDecals.tracer_dur(ev), Vector2i(int(to[0]), int(to[1])), false])
			"shot":
				var to: Array = ev.get("to", [])
				if to.size() >= 2:
					launch.append(ev)
					flights.append([FxDecals.shot_dur(ev), Vector2i(int(to[0]), int(to[1])), true])
			"casings":
				launch.append(ev)
	if flights.is_empty():
		return
	for ev: Dictionary in launch:
		ev["_shown"] = true
	_fx.apply(launch)
	queue_redraw()
	if not is_inside_tree() or _pace() >= 8.0 or (replay != null and _replay_skip_animations):
		return
	# Выстрел без бросков (заряд себе под ноги) — убитых тоже держим до разрыва.
	for id: int in result.visual_deaths:
		_pending_death_ids[id] = true
	flights.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var t := 0.0
	var k := 0
	while k < flights.size():
		await get_tree().process_frame
		if not is_inside_tree():
			return
		t += get_process_delta_time()
		while k < flights.size() and float(flights[k][0]) <= t:
			_land_shot(result, flights[k][1], bool(flights[k][2]))
			k += 1
		queue_redraw()

func _land_shot(result: ActionResult, cell: Vector2i, blast: bool) -> void:
	if _audio != null and blast:
		_audio.component_damage(result, state)
	var hit: Array = []
	for ev: Dictionary in result.fx:
		if ev.has("_shown") or str(ev.get("fx", "")) == "lane":
			continue
		var at: Variant = ev.get("at", null)
		if blast or (at is Vector2i and at == cell):
			ev["_shown"] = true
			hit.append(ev)
	if not hit.is_empty():
		_fx.apply(hit, blast)
	if blast:
		_pending_death_ids.clear()
		_hold_visual = {}
		return
	for id: int in _pending_death_ids.keys():
		var u := state.get_unit(id)
		if u == null or u.coord == cell:
			_pending_death_ids.erase(id)

func _play_flame_jets(result: ActionResult) -> void:
	for ev: Dictionary in result.fx:
		if ev.has("_shown") or str(ev.get("fx", "")) != "flame_jet" or (ev["cells"] as Array).is_empty():
			continue
		if not is_inside_tree() or _pace() >= 8.0 or _fast_playback \
				or (replay != null and _replay_skip_animations) or _tiles == null:
			return
		var cells: Array = ev["cells"]
		var burnt_at := {}
		for id: int in result.visual_deaths:
			var u := state.get_unit(id)
			if u != null and cells.has(u.coord):
				burnt_at[id] = u.coord
				_pending_death_ids[id] = true
		for c: Vector2i in cells:
			_tiles.hide_fire(c, true)
		_jet = {"from": ev["from"], "cells": cells, "t": 0.0}
		var reached := 0
		var dur := cells.size() * FLAME_STEP + FLAME_TAIL
		while float(_jet["t"]) < dur:
			await get_tree().process_frame
			if not is_inside_tree():
				return
			_jet["t"] = float(_jet["t"]) + get_process_delta_time() * _pace()
			var front := mini(cells.size(), int(float(_jet["t"]) / FLAME_STEP) + 1)
			while reached < front:
				var c: Vector2i = cells[reached]
				_tiles.hide_fire(c, false)
				for id: int in burnt_at:
					if burnt_at[id] == c:
						_pending_death_ids.erase(id)
				reached += 1
			queue_redraw()
		for id: int in burnt_at:
			_pending_death_ids.erase(id)
		_jet = {}
		queue_redraw()

## Первая горящая клетка на маршруте до dst, которая убьёт этого бойца (#1);
## NOWHERE — пути через огонь нет либо боец огнеупорен (#2).
## Считается по ТОМУ ЖЕ разливу, что подсвечен на экране, поэтому предупреждение
## не может разойтись с тем, что произойдёт на самом деле.
func _lethal_fire_step(u: UnitInstance, dst: Vector2i) -> Vector2i:
	if u == null or reach == null or resolver.is_fireproof(u):
		return NOWHERE
	if not reach.can_reach(dst):
		return NOWHERE
	for step: Vector2i in reach.path_to(dst):
		if state.grid.cell(step).on_fire:
			return step
	return NOWHERE

## Невысокая кнопка мелким шрифтом — из таких собрана компактная панель (#54).
## Темп показа (item 5): ход стороны, которую ведёт ИИ, идёт с выставленной хостом
## скоростью — и пауза между его действиями, и шаги, и кубики.
func _pace() -> float:
	# Ход налётчиков (0.11.3) — тоже с темпом ИИ: их ведёт тот же мозг, что и армию ИИ.
	if MCF.is_independent(_playing_slot):
		return GameConfig.ai_speed
	if state == null or state.roster == null or not state.roster.is_ai(state.active_player()):
		return 1.0
	return GameConfig.ai_speed

func _result_is_audible(res: ActionResult) -> bool:
	if res == null or not _view_resolver().visibility_limited() or res.actor_owner == -1:
		return true
	var viewer := _viewing_side()
	if res.actor_owner == viewer or state.roster.are_allies(res.actor_owner, viewer):
		return true
	# Свои, убитые ЭТИМ действием, ещё видели стрелка, когда он стрелял: без них
	# последний боец стороны умирал бы под скрытыми кубиками.
	var revived: Array[UnitInstance] = []
	for id: int in res.deaths:
		var u := state.get_unit(id)
		if u != null and u.status == MCF.Status.CORPSE \
				and (u.owner == viewer or state.roster.are_allies(u.owner, viewer)):
			u.status = MCF.Status.ALIVE
			revived.append(u)
	var seen := _view_resolver().team_visible_coords(viewer)
	var audible := seen.has(res.actor_from) or seen.has(res.actor_to)
	for u in revived:
		u.status = MCF.Status.CORPSE
	return audible


## Build an impact schedule without changing the already resolved board.
func _vehicle_presentation_stages(ev: Dictionary) -> Dictionary:
	var stages := {}
	var veh := state.get_vehicle(int(ev["vehicle"]))
	if veh == null: return stages
	var start: Vector2i = ev["from"]
	var steps := maxi(1, int(ev["steps"]))
	var dir := Vector2i((veh.origin - start) / steps)
	var effects: Array = ev.get("effects", [])
	for c: Vector2i in _hold_visual.get("cells", {}):
		_vehicle_stage(stages, _vehicle_cell_step(c, start, veh.size, dir, steps))["cells"].append(c)
	for id: int in ev.get("deaths", []):
		var u := state.get_unit(id)
		if u != null:
			_vehicle_stage(stages, _vehicle_cell_step(u.coord, start, veh.size, dir, steps))["deaths"].append(id)
	for fx: Dictionary in effects:
		if fx.get("fx", "") == "tracks":
			var tracks := FxDecals.new()
			tracks.space_at = _fx.space_at
			tracks._tracks(fx)
			for mark: Dictionary in tracks.track_marks:
				var mid: Vector2 = (mark["from"] + mark["to"]) * 0.5
				var at := Vector2i(floori(mid.x), floori(mid.y))
				_vehicle_stage(stages, _vehicle_cell_step(at, start, veh.size, dir, steps))["tracks"].append(mark)
		elif fx.get("fx", "") == "debris" and not fx.get("blast", false):
			for c: Vector2i in fx.get("cells", []):
				var piece := fx.duplicate()
				piece["cells"] = [c]
				_vehicle_stage(stages, _vehicle_cell_step(c, start, veh.size, dir, steps))["fx"].append(piece)
		else:
			var at: Vector2i = fx.get("at", veh.center())
			_vehicle_stage(stages, _vehicle_cell_step(at, start, veh.size, dir, steps))["fx"].append(fx)
		fx["_shown"] = true
	return stages

func _vehicle_stage(stages: Dictionary, step: int) -> Dictionary:
	if not stages.has(step): stages[step] = {"cells": [], "deaths": [], "fx": [], "tracks": []}
	return stages[step]

func _vehicle_cell_step(c: Vector2i, start: Vector2i, size: Vector2i, dir: Vector2i, steps: int) -> int:
	var best := steps
	var distance := INF
	for i in steps + 1:
		var origin := start + dir * i
		if Rect2i(origin, size).has_point(c): return i
		var d := Vector2(c).distance_squared_to(Vector2(origin) + Vector2(size) * 0.5)
		if d < distance:
			distance = d
			best = i
	return best

func _reveal_vehicle_stage(stage: Dictionary) -> void:
	for c: Vector2i in stage.get("cells", []): _hold_visual.get("cells", {}).erase(c)
	for id: int in stage.get("deaths", []): _pending_death_ids.erase(id)
	if not stage.get("fx", []).is_empty(): _fx.apply(stage["fx"])
	if not stage.get("tracks", []).is_empty():
		_fx.track_marks.append_array(stage["tracks"])
		_fx.ground_version += 1
