@abstract
extends "res://scenes/main/MainHud.gd"

## Recording, saving and loading a match, replays and the Before view.

# --- Запись матча (item 53) --------------------------------------------------
## Пишем только НЕсетевую партию: в сетевой журнал бросков уже ведёт хост (NetGame),
## и второй писатель отобрал бы у него броски действия. Запись стоит один хук в
## резолвере и ничего не меняет в правилах — при выключенной записи её просто нет.
func _begin_recording() -> void:
	if replay != null or networked or recorder != null:
		return
	recorder = ReplayRecorder.new()
	recorder.begin(state, resolver, _match_meta())
	resolver.replay_recorder = recorder

## Подпись матча для списков в меню: карта, раунд, время.
func _match_meta() -> Dictionary:
	var map_name := GameConfig.map_path.get_file().get_basename()
	if map_name == "":
		map_name = "arena"
	var t := Time.get_datetime_string_from_system(false, true)
	return {"map": map_name, "saved_at": t, "round": state.turns.round_number}

## Дописать запись на диск. Зовётся на выходе из боя: до этого момента неизвестно,
## где партия кончилась, а держать файл открытым весь бой незачем.
func _flush_replay() -> void:
	if recorder == null:
		return
	if resolver != null:
		resolver.replay_recorder = null
	if net != null:
		net.recorder = null
	var path := recorder.save(str(_match_meta().get("map", "match")))
	if path != "":
		print("replay saved: ", path)
	recorder = null

## Сохранить партию (item 42). Косметика едет вместе с доской — иначе перезагруженный
## час боя выглядел бы свежевымытым.
func _save_game() -> void:
	if replay != null or state == null:
		return
	# Спрашиваем имя сохранения (item 19): игрок сам называет партию, а не получает
	# файл с одной лишь меткой времени. Пустое поле откатывается на метку времени.
	_prompt_save_name()

## Модальное окошко ввода имени сохранения (item 19).
func _prompt_save_name() -> void:
	var layer := CanvasLayer.new()
	layer.add_to_group("shortcut_modal")
	layer.layer = 80
	add_child(layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := PanelContainer.new()
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Save Game"))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	frame.add_child(SteamChrome.pad(box, 16, 12))
	var lbl := Label.new()
	lbl.text = "Name this save:"
	box.add_child(lbl)
	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(280, 0)
	edit.text = str(_match_meta().get("map", "match"))
	box.add_child(edit)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var cancel := Button.new()
	cancel.text = "Cancel"
	row.add_child(cancel)
	var ok := Button.new()
	ok.text = "Save"
	row.add_child(ok)
	Ui.theme_canvas_layers()
	var close := func() -> void: layer.queue_free()
	cancel.pressed.connect(close)
	var commit := func() -> void:
		_do_save_game(edit.text)
		layer.queue_free()
	ok.pressed.connect(commit)
	edit.text_submitted.connect(func(_t: String) -> void: commit.call())
	edit.grab_focus()
	edit.select_all()

func _do_save_game(chosen_name: String) -> void:
	if replay != null or state == null:
		return
	var data := _save_payload()
	var name := ReplayFile.named(chosen_name, ReplayFile.SAVE_EXT)
	var path := ReplayFile.path_for(ReplayFile.SAVE_DIR, name)
	if ReplayFile.write(path, data):
		state.log.add("— Game saved as %s —" % name)
	else:
		state.log.add("[denied] Could not write the save file.")
	_refresh_status()

## Сетевая партия сохраняется сама, когда из неё уходит игрок (issues-12 #15): у каждого
## оставшегося — файл в папке сохранений, и партию можно продолжить с того же места,
## пока ушедшего ещё не подменил ИИ. Одно имя на карту и раунд: свежий уход перезаписывает.
func _autosave() -> void:
	if _spectator or replay != null or state == null:
		return
	_do_save_game("autosave %s round %d" % [str(_match_meta().get("map", "match")),
			state.turns.round_number])

func _save_payload() -> Dictionary:
	var meta := _match_meta()
	# Сохранение собирается здесь, а не в ReplayFile: тот читает список сохранений ещё в
	# главном меню, и ссылка на StateCodec/резолвер тащила бы в меню компиляцию всей игры.
	# Косметика (FxDecals) ни на что не влияет, но без неё перезагруженный бой выглядел бы
	# стерильно-чистым после часа стрельбы (item 42).
	var data := {
		"schema": StateCodec.SCHEMA,
		"kind": ReplayFile.KIND_SAVE,
		"meta": meta.duplicate(true),
		"state": StateCodec.encode(state),
		"rules": StateCodec.encode_rules(resolver),
		"opening": _opening_state,
		"combat_log": state.log.lines.duplicate(),
		"chat": NetHandoff.chat_history.duplicate(true),
		"clock_stopped": _real_stop_ms >= 0,
		"elapsed_ms": maxi(0, (_real_stop_ms if _real_stop_ms >= 0 else Time.get_ticks_msec()) - _real_start_ms),
	}
	var fx := _fx.to_dict()
	if not fx.is_empty():
		data["fx"] = fx
	return data

# --- Загрузка сохранённой партии и повтора (M12) ------------------------------

## Продолжить сохранённую партию. Ростер приезжает из файла — в нём уже учтено
## переназначение ролей, сделанное в лобби (item 42).
func _adopt_save() -> bool:
	var data := SaveHandoff.take_save()
	if data.is_empty():
		return false
	var loaded := StateCodec.decode(data.get("state", {}))
	if loaded == null:
		push_warning("save file is newer than this build — starting a normal match")
		return false
	state = loaded
	state.log.lines.assign(data.get("combat_log", []))
	NetHandoff.chat_history.assign(data.get("chat", []))
	resolver = GameActionResolver.new(state)
	StateCodec.apply_rules(resolver, data.get("rules", {}))
	resolver.update_airlocks()
	if data.has("fx"):
		_fx.from_dict(data["fx"])
	# Настройки партии обязаны совпасть с сохранёнными: экраны и HUD читают их из
	# GameConfig, и разъехавшийся туман показал бы игроку не ту доску.
	GameConfig.roster = state.roster
	GameConfig.fog_mode = resolver.fog_mode
	GameConfig.friendly_fire = resolver.friendly_fire_enabled
	_opening_state = data.get("opening", {}).duplicate(true)
	_real_start_ms = Time.get_ticks_msec() - maxi(0, int(data.get("elapsed_ms", 0)))
	_real_stop_ms = Time.get_ticks_msec() if bool(data.get("clock_stopped", false)) else -1
	_loaded_from_save = true
	state.log.line_added.connect(_on_log_line)
	return true

func _adopt_replay() -> bool:
	var data := SaveHandoff.take_replay()
	if data.is_empty():
		return false
	replay = ReplayPlayer.new(data)
	replay.seek(0)
	_take_replay_state()
	return true

## Забрать доску у проигрывателя. Перемотка НАЗАД пересобирает состояние с нуля, то
## есть подменяет и GameState, и резолвер — значит всё, что на них подписано, надо
## перевесить, а накопленную косметику сбросить: она относилась к прежней доске.
func _take_replay_state() -> void:
	_fx.audio_suppressed = true
	if state != null and state.log.line_added.is_connected(_on_log_line):
		state.log.line_added.disconnect(_on_log_line)
	state = replay.state
	resolver = replay.resolver
	# Зритель смотрит бой целиком: прятать от него нечего, стороны в записи не его.
	# Снятый туман не может сделать записанное действие незаконным — он только
	# разрешает больше, — поэтому воспроизведение от этого не съедет.
	resolver.fog_mode = MCF.Fog.OFF
	state.log.line_added.connect(_on_log_line)
	# Косметику пересобираем из фаст-форварда перемотки (item 9): после прыжка по
	# таймлайну кровь, гильзы и разрушенный пол остаются на доске, а не пропадают.
	_fx.clear()
	if replay != null:
		_fx.from_dict(replay.seek_decals)
		_fx.apply(replay.seek_fx)
		_fx.advance(10.0)
	_fx.audio_suppressed = false
	if _audio != null:
		_audio.reset()
		_audio.turn_key_from_state(state)
	_audio_victory_played = bool(resolver.match_outcome().get("over", false))
	selected_id = -1
	selected_vehicle_id = -1
	mode = Mode.NONE

## Открыть просмотр записи: те же вступительные строки, что и у живой партии.
func _open_replay() -> void:
	state.log.add("— Replay: %s —" % ReplayFile.describe(replay.data))
	state.log.add("— Initiative this match: %s —" % _initiative_names())
	if replay.opening_result != null:
		await _play_civilian_result(replay.opening_result)
	_refresh_replay_bar()
	_refresh_status()

## Показать результат действия так же, как его показывает живая партия: кубики,
## отложенные смерти, косметика, журнал. Отдельная функция, потому что у повтора нет
## ни контроллеров, ни сети — а показ должен быть тот же самый.
func _show_result(result: ActionResult) -> void:
	if result == null:
		return
	if not result.ok:
		state.log.add("[denied] " + result.reason)
		return
	if not result.dice_events.is_empty():
		_pending_death_ids.clear()
		for id: int in result.visual_deaths:
			_pending_death_ids[id] = true
		_hold_visual = result.visual_hold  # item 22
		queue_redraw()
		_fx.preview_lanes(result.fx)   # who fires at whom shows while the dice roll
		await _play_dice(result.dice_events)
	await _show_effects(result)
	if _result_is_audible(result):
		state.log.publish_result(result)
	_refresh_status()
	if replay != null and not _audio_victory_played:
		var outcome := resolver.match_outcome()
		if bool(outcome.get("over", false)):
			# A local caption, not a new recorded log/state mutation; replay stays seekable.
			_on_log_line("— %s —" % _outcome_title(outcome))
			_play_victory_audio()
	queue_redraw()

func _replay_step() -> void:
	if replay == null or _animating or not replay.has_next():
		return
	await _show_result(replay.play_next())
	_refresh_replay_bar()

## Шаг назад и любая перемотка — это пересборка доски из ближайшего ключевого кадра
## (см. ReplayPlayer.seek). Показывать промежуточные броски при этом нельзя: их сотни,
## и перемотка превратилась бы в ещё один просмотр.
func _replay_seek(target: int) -> void:
	if replay == null:
		return
	_replay_playing = false
	if _animating:
		# Keep the latest destination and finish the current presentation promptly.
		# Never replace the board while an old animation coroutine still owns it.
		_replay_seek_target = target
		_replay_skip_animations = true
		_replay_seek_timer.start(0.02)
		return
	_replay_skip_animations = false
	if _replay_seek_timer != null:
		_replay_seek_timer.stop()
	replay.seek(target)
	_take_replay_state()
	_refresh_replay_bar()
	_refresh_status()
	queue_redraw()

func _replay_toggle() -> void:
	if replay == null:
		return
	_replay_playing = not _replay_playing
	_refresh_replay_bar()
	if _replay_playing:
		_replay_loop()

func _replay_loop() -> void:
	while _replay_playing and replay != null and replay.has_next() and is_inside_tree():
		if _animating:
			await get_tree().process_frame
			continue
		await _show_result(replay.play_next())
		_refresh_replay_bar()
		# _show_result мог увести узел из дерева (выход из повтора) — тогда таймер ниже
		# упал бы на get_tree() == null (item 10).
		if not _replay_playing or not is_inside_tree():
			break
		await get_tree().create_timer(REPLAY_STEP_DELAY / _replay_speed).timeout
	_replay_playing = false
	_refresh_replay_bar()

func _replay_cycle_speed() -> void:
	var i := REPLAY_SPEEDS.find(_replay_speed)
	_replay_speed = REPLAY_SPEEDS[(i + 1) % REPLAY_SPEEDS.size()]
	_refresh_replay_bar()

func _refresh_replay_bar() -> void:
	if _replay_bar == null or replay == null:
		return
	_replay_label.text = replay.position_text()
	if _replay_bookmarks != null:
		var entries: Array = replay.data.get("bookmarks", [])
		var nearest := -1
		for i in entries.size():
			if int(entries[i].index) <= replay.index:
				nearest = i
			else:
				break
		if nearest >= 0 and not _replay_bookmarks.is_selected(nearest):
			_replay_bookmarks.select(nearest)
			_replay_bookmarks.ensure_current_is_visible()
	_replay_play_btn.text = "❚❚" if _replay_playing else "▶"
	_replay_speed_btn.text = "%dx" % int(_replay_speed)
	# Таймлайн (item 7) отражает позицию, не вызывая seek: обновляем под флагом.
	if _replay_slider != null:
		_replay_slider_syncing = true
		_replay_slider.max_value = maxi(1, replay.step_count())
		_replay_slider.value = clampi(replay.index, 0, replay.step_count())
		_replay_slider_syncing = false

## Перенести выбор экрана подготовки (кто машина, какая сложность) в ростер.
## Ростер, пришедший из лобби, уже всё это знает — тогда эта синхронизация просто
## подтверждает то же самое; она нужна для хот-сита и демо-ростера, где лобби нет.
func _sync_roster_from_config() -> void:
	var flags := [p1_is_ai, p2_is_ai]
	for side in state.roster.player_ids():
		var slot := state.roster.slot(side)
		if slot == null:
			continue
		if side < flags.size():
			slot.kind = Roster.SlotKind.AI if flags[side] else Roster.SlotKind.HUMAN

func _build_controllers() -> void:
	# Любая сторона переключается человек/ИИ (§2.1, #103). Раньше первый игрок был жёстко
	# прошит локальным человеком, и посмотреть бой ИИ против ИИ было нельзя вообще.
	# Список сторон берётся из ростера: их может быть и две, и двадцать шесть.
	for side in state.roster.player_ids():
		_make_side(side)

## Кто ведёт сторону — решает РОСТЕР, а не пара флагов. Флаги p1_is_ai/p2_is_ai
## остались как удобство хот-сита на двоих (кнопки в HUD) и пишут в тот же ростер.
func _side_is_ai(side: int) -> bool:
	return state != null and state.roster != null and state.roster.is_ai(side)

func _make_side(side: int) -> void:
	var old: PlayerController = controllers.get(side)
	if old != null and old.intent_ready.is_connected(_on_intent_ready):
		old.intent_ready.disconnect(_on_intent_ready)
	var c: PlayerController
	if _side_is_ai(side):
		var slot := state.roster.slot(side)
		c = _ai_controller_for(side, slot)
	else:
		c = LocalHumanController.new(side)
	c.intent_ready.connect(_on_intent_ready)
	controllers[side] = c
	_refresh_omniscience()

## Мозг для ИИ-слота (RL v1, §7): «AI - Learned» — обученная политика, остальные —
## AIController силы HARD с личностью слота (0.12). Если модели нет, LearnedController сам
## переключается на HARD и говорит об этом в журнал боя (§12) — партия не встаёт.
func _ai_controller_for(side: int, slot: Roster.Slot) -> PlayerController:
	if slot != null and slot.ai_difficulty == AIController.Difficulty.LEARNED:
		var learned := LearnedController.new(side)
		learned.bind_match(resolver)
		learned.fallback_engaged.connect(func(reason: String) -> void:
			state.log.add("— %s: learned AI unavailable (%s) — AI - Tactician takes the seat —" % [
				MCF.owner_name(side), reason])
			_refresh_status())
		return learned
	var ai := AIController.new(side, AIController.Difficulty.HARD)
	ai.style = slot.ai_style if slot != null else AIPersonality.TACTICIAN
	ai.bind_match(resolver)   # announced event zones (0.11.1)
	return ai

## Кто видит поле насквозь. ИИ знает позиции всех юнитов сквозь туман (#43): его прицел
## легален и по скрытым.
##
## Поле в резолвере одно, а сторон-всеведущих теперь может быть две (#103). Разводится это
## так: у КАЖДОГО решения ИИ свой резолвер, и он сам ставит туда себя (AIController._decide),
## поэтому общий резолвер Main отвечает лишь за то, что видно на экране. Отсюда и правило —
## если человека за столом не осталось, тумана нет вовсе: зритель смотрит бой целиком, а
## прятать от него нечего.
func _refresh_omniscience() -> void:
	if resolver == null:
		return
	var sides := state.roster.player_ids()
	var ai_sides: Array[int] = []
	for side in sides:
		if _side_is_ai(side):
			ai_sides.append(side)
	if not sides.is_empty() and ai_sides.size() == sides.size():
		# За столом не осталось человека — прятать не от кого, зритель смотрит бой целиком.
		resolver.fog_mode = MCF.Fog.OFF
		resolver.omniscient_side = -1
		return
	resolver.fog_mode = GameConfig.fog_mode
	# Всеведущей может быть только ОДНА сторона: поле в резолвере одно. Когда машин
	# несколько, общий резолвер не отдаётся никому — каждый ИИ и так ставит себя
	# всеведущим в СВОЙ резолвер на время решения (AIController._decide).
	resolver.omniscient_side = ai_sides[0] if ai_sides.size() == 1 else -1

## Окно исхода в общем стиле SteamChrome (batch 13 #9). «Look at the Board» убирает окно,
## но доску не размораживает: посмотреть на поле можно, играть дальше — нет.
## Снимок доски в начале боя для «было / стало». Черновая сетка — в тихом окне журналов
## (GridCell.logs_snapshot): Grid.new иначе заставил бы туман, ИИ и плитки боя пересчитать
## всё. Мебель рисуется тем же замороженным видом, что и в бою.
## The opening board's look, copied for the Before view.
static func _opening_grid(src: Grid) -> Grid:
	var g := Grid.new(src.width, src.height)
	for y in src.height:
		for x in src.width:
			var a := src.cell_fast(x, y)
			var b := g.cell_fast(x, y)
			b.floor_type = a.floor_type
			b.is_space = a.is_space
			if a.feature_id != "":
				b.set_feature(a.feature_id)
				b.feature_durability = a.feature_durability
			b.cover_height = a.cover_height
			b.airlock_welded = a.airlock_welded
			b.lamps = a.lamps
			b.items_off = a.items_off
	g.furniture_turn = src.furniture_turn.duplicate(true)
	g.wall_accent = src.wall_accent.duplicate()
	g.door_look = src.door_look.duplicate()
	g.map_decals = src.map_decals.duplicate(true)
	g.map_items = src.map_items
	g.floor_look = src.floor_look.duplicate()   # полы комнат (0.9.2) — и в «было» тоже
	return g

func _capture_opening_view() -> void:
	var saved := GridCell.logs_snapshot()
	var opening := state
	if _opening_state.is_empty():
		_opening_state = StateCodec.encode(state)
	else:
		var decoded := StateCodec.decode(_opening_state)
		if decoded != null: opening = decoded
	var src := opening.grid
	var g := _opening_grid(src)
	GridCell.logs_restore(saved)
	_before_grid = g
	_before_tiles = TerrainTiles.new(g, state.env)
	# A new match opens on the board the battle froze its furniture from a moment ago, and
	# the copy holds everything freezing reads: same result, no second pass over the board.
	var fresh_board := opening == state and _furniture_look_of == [state.grid, GridCell.look_version]
	_before_tiles.furniture_look = _furniture_look if fresh_board else _before_tiles.freeze_furniture()
	_before_units.clear()
	for u: UnitInstance in opening.all_units():
		if u.is_alive() and src.in_bounds(u.coord):
			_before_units.append([u.stats.id, u.owner, u.coord, u])
	_before_vehicles.clear()
	for veh: Vehicle in opening.all_vehicles():
		if not veh.wrecked:
			_before_vehicles.append([veh.type_id, veh.owner, veh.origin, veh.size, veh.facing])
	_before_seen.clear()
	if resolver != null and resolver.fog_enabled and state.roster != null:
		var vr := resolver
		if opening != state:
			# Загруженная партия: обзор стартовой доски считает свой резолвер. Кеш обзора
			# общий, но привязан к сетке — живой резолвер просто пересоберёт его.
			if opening.roster == null:
				opening.roster = state.roster
			vr = GameActionResolver.new(opening)
			vr.fog_mode = resolver.fog_mode
		for side: int in state.roster.player_ids():
			_before_seen[side] = vr.team_visible_coords(side).duplicate()

## Показывать ли на «было» бойца или машину стороны owner на клетках cells зрителю viewer:
## без тумана — всегда; свои и союзники — всегда; чужие — если их клетку видели в начале.
func _before_known(owner: int, cells: Array, viewer: int) -> bool:
	if not _view_resolver().fog_enabled or state.roster.are_allies(viewer, owner):
		return true
	var seen: Dictionary = _before_seen.get(viewer, {})
	for c: Vector2i in cells:
		if seen.has(c):
			return true
	return false

func _toggle_before() -> void:
	if _before_grid == null:
		return
	_before_on = not _before_on
	if _lod != null: _lod.visible = not _before_on
	if _before_btn != null:
		_before_btn.set_pressed_no_signal(_before_on)
	if _before_on:
		if _before_layer == null:
			_before_layer = BeforeLayer.new()
			_before_layer.host = self
			_before_layer.z_index = 1   # над бойцами и косметикой, но под светом (0.12.2)
			_before_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			add_child(_before_layer)
		if _before_note == null:
			_before_note = Label.new()
			_before_note.text = "The battlefield as it was at the start  ·  press Before / After or click the map to return"
			_before_note.add_theme_color_override("font_color", Ui.text_accent_color() if Ui != null else Color.WHITE)
			_before_note.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
			_before_note.add_theme_constant_override("outline_size", 4)
			_before_note.position = Vector2(16, 44)
			_ui_layer.add_child(_before_note)
	if _before_layer != null:
		_before_layer.visible = _before_on
	if _before_note != null:
		_before_note.visible = _before_on
	queue_redraw()

## Полоса управления повтором (item 53) внизу экрана: в начало, шаг назад,
## пуск/пауза, шаг вперёд, скорость, в конец. Строится только в режиме просмотра —
## в живой партии её нет вовсе.
func _build_replay_bar() -> void:
	var panel := PanelContainer.new()
	SteamChrome.apply_panel(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Replay"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	frame.add_child(SteamChrome.pad(row, 12, 8))
	row.add_child(_replay_btn("|◀", func() -> void: _replay_seek(0)))
	row.add_child(_replay_btn("◀", func() -> void: _replay_seek(replay.index - 1)))
	_replay_play_btn = _replay_btn("▶", _replay_toggle)
	row.add_child(_replay_play_btn)
	row.add_child(_replay_btn("▶|", _replay_step))
	_replay_speed_btn = _replay_btn("1x", _replay_cycle_speed)
	row.add_child(_replay_speed_btn)
	row.add_child(_replay_btn("▶▶|", func() -> void: _replay_seek(replay.step_count())))
	var previous := _replay_btn("‹ Mark", func() -> void: _replay_bookmark_jump(-1))
	previous.tooltip_text = "Previous bookmark"
	row.add_child(previous)
	var following := _replay_btn("Mark ›", func() -> void: _replay_bookmark_jump(1))
	following.tooltip_text = "Next bookmark"
	row.add_child(following)
	_replay_label = Label.new()
	_replay_label.add_theme_font_size_override("font_size", 12)
	_replay_label.custom_minimum_size = Vector2(180, 0)
	_replay_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_replay_label)
	# Кем играла обучаемая политика. Пусто для обычных записей — метка появляется только
	# у записей из обучения, где иначе не отличить её ходы от ходов ИИ.
	var rl_text := replay.rl_side_text()
	if rl_text != "":
		var rl_label := Label.new()
		rl_label.text = rl_text
		rl_label.add_theme_font_size_override("font_size", 12)
		# Тем же цветом, каким сторона нарисована на доске (Roster.color_of, item 16), —
		# иначе подпись пришлось бы сверять с полем глазами.
		var rl_side := int(replay.data.get("meta", {}).get("side", 0))
		if replay.state != null:
			rl_label.add_theme_color_override("font_color",
					replay.state.roster.color_of(rl_side))
		rl_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(rl_label)
	# Таймлайн (item 7): тянешь ползунок — прыгаешь в любую точку записи, минуя всё
	# между. Перемотка идёт через seek(), тем же путём, что и кнопки шага.
	var slider_wrap := HBoxContainer.new()
	frame.add_child(SteamChrome.pad(slider_wrap, 12, 4))
	_replay_slider = HSlider.new()
	_replay_slider.min_value = 0
	_replay_slider.step = 1
	_replay_slider.custom_minimum_size = Vector2(360, 18)
	_replay_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_replay_slider(_replay_slider)  # чёрная дорожка под ползунком (item 7)
	_replay_slider.value_changed.connect(_on_replay_slider)
	_replay_slider.drag_started.connect(func() -> void:
		_replay_dragging = true
		_replay_playing = false
		_replay_seek_timer.stop())
	_replay_slider.drag_ended.connect(func(changed: bool) -> void:
		_replay_dragging = false
		if changed: _replay_seek(int(_replay_slider.value)))
	slider_wrap.add_child(_replay_slider)
	_replay_seek_timer = Timer.new()
	_replay_seek_timer.one_shot = true
	_replay_seek_timer.wait_time = 0.12
	_replay_seek_timer.timeout.connect(func() -> void: _replay_seek(_replay_seek_target))
	panel.add_child(_replay_seek_timer)
	var marks := VBoxContainer.new()
	marks.custom_minimum_size.x = 270
	marks.add_child(SteamChrome.header_bar("Bookmarks"))
	_replay_bookmarks = ItemList.new()
	_replay_bookmarks.custom_minimum_size = Vector2(270, 100)
	_replay_bookmarks.add_theme_font_size_override("font_size", 12)
	_replay_bookmarks.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	for entry: Dictionary in replay.data.get("bookmarks", []):
		_replay_bookmarks.add_item(str(entry.label))
	_replay_bookmarks.item_selected.connect(_on_replay_bookmark)
	marks.add_child(_replay_bookmarks)
	slider_wrap.add_child(marks)
	_replay_bar = panel
	_ui_layer.add_child(_replay_bar)
	_refresh_replay_bar()

## Игрок потянул таймлайн (item 7). Программные обновления ползунка идут с поднятым
## флагом, чтобы не спутать их с ручной перемоткой и не зациклить seek.
func _on_replay_slider(value: float) -> void:
	if _replay_slider_syncing or replay == null:
		return
	_replay_playing = false
	_replay_seek_target = int(round(value))
	if not _replay_dragging:
		_replay_seek_timer.start(0.12)

func _on_replay_bookmark(row: int) -> void:
	var entries: Array = replay.data.get("bookmarks", [])
	if row >= 0 and row < entries.size():
		_replay_seek(int(entries[row].index))

func _replay_bookmark_jump(direction: int) -> void:
	_replay_seek(ReplayBookmarks.neighbor(replay.data.get("bookmarks", []),
			replay.index, direction, replay.step_count()))

func _replay_btn(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(46, 30)
	b.pressed.connect(handler)
	return b

func _replay_chat_history() -> void:
	if _chat_log == null:
		return
	_chat_log.clear()
	for rec: Dictionary in NetHandoff.chat_history:
		_chat_log.append_text("[b]%s:[/b] %s\n" % [ChatBox.escape(_side_label(int(rec["side"]))),
				ChatBox.escape(str(rec["text"]))])
