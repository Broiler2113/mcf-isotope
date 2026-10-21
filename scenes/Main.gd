extends "res://scenes/main/MainNet.gd"

## The battle screen (Main.tscn): starting and running a match, the flow of intents, turns,
## undo and the way out. The rest of the class sits below it in scenes/main/ (MainState.gd
## lists the chain).

func _ready() -> void:
	_annotations = Node2D.new()
	_annotations.z_index = 3
	var annotation_material := CanvasItemMaterial.new()
	annotation_material.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	_annotations.material = annotation_material
	_annotations.draw.connect(_draw_annotation_layer)
	add_child(_annotations)
	Keybinds.changed.connect(_refresh_menu_hotkeys)
	_spectator = NetHandoff.session != null and NetHandoff.spectators.has(NetHandoff.session.my_peer_id())
	Ui.board_settings_changed.connect(queue_redraw)
	Ui.board_settings_changed.connect(_sync_lighting)
	p1_is_ai = GameConfig.p1_is_ai
	p2_is_ai = GameConfig.p2_is_ai
	# Картинки-замены перечитываются при входе в бой (#55): подменил файл — видно
	# со следующей партии, перезапускать игру не нужно.
	Sprites.reload_overrides()
	_build_state()
	resolver.capture_cosmetics = _fx.capture_state
	resolver.restore_cosmetics = _fx.restore_state
	_furniture_look = TerrainTiles.new(state.grid, state.env).freeze_furniture()
	_furniture_look_of = [state.grid, GridCell.look_version]
	# Край поля для косметики (batch 12 #6): гильзы, брызги и осколки отскакивают от него.
	_fx.bounds = Vector2(state.grid.width, state.grid.height)
	# Частицы останавливаются о стены (item 7), а не «проваливаются» в них.
	_fx.solid_at = func(c: Vector2i) -> bool: return FxDecals.solid_in(state, c)
	_fx.space_at = func(c: Vector2i) -> bool: return FxDecals.space_in(state, c)
	_audio = BattleAudio.new()
	_audio.origin = ORIGIN
	_audio.cell_size = CELL
	_audio.cell_visible = _audio_cell_visible
	_audio.own_cell = _audio_own_cell
	_audio.viewer = _viewing_side
	_audio.world = func() -> GameState: return state
	add_child(_audio)
	_fx.sound_requested.connect(_audio.cue)
	_fx.volley_requested.connect(_audio.volley)
	_fx.sound_reset.connect(_audio.reset)
	_sync_camera_layers()
	# У записи нет игроков: смотреть — не играть, поэтому контроллеров не заводим
	# вовсе. Ровно это и делает просмотр безопасным: подать намерение некому.
	if replay == null and not _spectator:
		# Раньше здесь _sync_roster_from_config() перезаписывал вид слотов из флагов
		# p1_is_ai/p2_is_ai — а лобби эти флаги не трогает (item 12). Из-за этого слот,
		# выбранный в лобби как AI, снова становился HUMAN, и ИИ никем не управлял.
		# Ростер (и из лобби, и из демо-пути через default_duel) уже несёт верный вид
		# слотов, поэтому синхронизация не нужна и только мешала.
		_build_controllers()
	_build_sky()
	_build_ground()
	_build_ui()
	Ui.theme_canvas_layers()  # HUD lives on a CanvasLayer; pull in the Steam skin.
	# Связь налажена во вкладке Multiplayer главного меню (#54) — подхватываем её.
	# ДО открытия партии: в сети стартовый слот мирных отыгрывает хост и высылает
	# его броски клиенту (#93), иначе каждая сторона сыграла бы его по-своему.
	_adopt_network()
	# После UI — иначе первые строки боя (порядок инициативы) уйдут в никуда.
	if replay != null:
		_open_replay()
	elif not networked:
		_open_match()
	_refresh_status()
	set_process(true)
	# Камера — на свои войска, а не в угол доски: с каймой вокруг карты (0.9.3) угол поля
	# это десяток клеток пустого грунта, травы или космоса.
	_center_on_side.call_deferred(my_owner if networked else state.active_player(), true)
	queue_redraw()

func _process(delta: float) -> void:
	if _audio != null:
		_audio.suppress = replay != null and _replay_skip_animations
	_advance_group_preview()
	_update_screen_shake()
	# Не двигаем камеру, пока игрок печатает в текстовом поле (например, IP хоста).
	_reposition_hud_grip()
	_refresh_clocks()
	if _sky != null:
		_sky.camera = pan   # параллакс за доской едет вслед за панорамой (0.9.3)
	_fit_ground()
	# Полёт осколков и гильз (#21): пока что-то летит — перерисовываем, потом слой
	# засыпает и кадры снова ничего не стоят. До проверки фокуса (fix-7): пока игрок
	# печатает в чате, вспышки и пули не должны замирать на экране.
	if _fx.advance(delta):
		queue_redraw()
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit or Keybinds.modal_open() or _quit_dialog.visible:
		_sync_lighting()
		return
	var dir := Vector2.ZERO
	if Keybinds.down("game_pan_up"): dir.y += 1
	if Keybinds.down("game_pan_down"): dir.y -= 1
	if Keybinds.down("game_pan_left"): dir.x += 1
	if Keybinds.down("game_pan_right"): dir.x -= 1
	if dir != Vector2.ZERO:
		_kill_pan_tween()  # ручная панорама важнее плавного доводки камеры (item 52)
		pan += dir.normalized() * PAN_SPEED * delta
		queue_redraw()
	_sync_lighting()

func _build_state() -> void:
	# Загруженная партия и запись матча (M12) приезжают сюда из меню уже готовой
	# доской: ни карту раскладывать, ни ростер собирать больше не нужно.
	if _adopt_replay() or _adopt_save():
		return
	if MapHandoff.pending != null:
		state = MapHandoff.pending.build_state(MapHandoff.take_seed(),
				GameConfig.active_roster())
		resolver = GameActionResolver.new(state)
		resolver.fog_mode = GameConfig.fog_mode
		resolver.friendly_fire_enabled = GameConfig.friendly_fire
		resolver.update_airlocks()
		# Режим партии (0.12): зоны — из карты, мерило волн — из расставленных армий.
		resolver.prepare_mode(MapHandoff.pending)
		MapHandoff.pending = null
		state.log.line_added.connect(_on_log_line)
		return
	state = GameState.new(GRID_W, GRID_H)
	resolver = GameActionResolver.new(state)
	resolver.fog_mode = GameConfig.fog_mode
	resolver.friendly_fire_enabled = GameConfig.friendly_fire

	# Демо-ростер: показываем спецстрелков. Слева P1, справа P2 (зеркально).
	# Смещения от края к центру для каждой стороны.
	var roster := [
		["light_infantry", Vector2i(0, 1)],
		["heavy_infantry", Vector2i(0, 3)],
		["sniper", Vector2i(0, 5)],
		["machinegunner", Vector2i(0, 7)],
		["anti_tank", Vector2i(0, 9)],
		["heavy_infantry", Vector2i(2, 2)],
		["marksman", Vector2i(2, 4)],
		["shield_bearer", Vector2i(2, 6)],
		["miner", Vector2i(2, 8)],
		["commander", Vector2i(2, 10)],
		["drone_operator", Vector2i(2, 0)],
		["engineer", Vector2i(4, 5)],
	]
	for entry in roster:
		var stats: UnitStats = load("res://src/data/units/%s.tres" % entry[0])
		var off: Vector2i = entry[1]
		state.spawn_unit(stats, Vector2i(1 + off.x, off.y), MCF.Owner.PLAYER_1)
		state.spawn_unit(stats, Vector2i(GRID_W - 2 - off.x, off.y), MCF.Owner.PLAYER_2)

	# Мирные жители — нейтральная сторона в центре карты (§3.10). Экран Setup может отключить.
	if GameConfig.civilians_enabled:
		var civ_stats: UnitStats = load("res://src/data/units/civilian.tres")
		for c in [Vector2i(GRID_W / 2, 4), Vector2i(GRID_W / 2, 7)]:
			state.spawn_unit(civ_stats, c, MCF.Owner.NEUTRAL)

	# Демо-техника (§техника): танк 3×3 у P1, челнок 2×2 у P2.
	state.spawn_vehicle("tank", Vector2i(6, 1), MCF.Owner.PLAYER_1)
	state.spawn_vehicle("shuttle", Vector2i(GRID_W - 8, 8), MCF.Owner.PLAYER_2)

	# Инициатива бросается один раз — когда все юниты уже на карте (#53).
	state.roster = GameConfig.active_roster()
	state.turns.begin_match(state.all_units(), state.dice, state.roster.player_ids())

	state.log.line_added.connect(_on_log_line)

## Начало боя (#53): объявляем выпавший на всю партию порядок инициативы и, если
## первым в нём стоит слот мирных, сразу отыгрываем его — контроллера у
## нейтральной стороны нет, её ход проводит сам резолвер.
func _open_match() -> void:
	_begin_recording()
	_capture_opening_view()
	state.log.add("— Initiative this match: %s —" % _initiative_names())
	# Открывающий слот мирных играется ВНЕ потока намерений, но кубики бросает —
	# поэтому под запись он уходит через сам регистратор (см. ReplayRecorder).
	await _play_civilian_result(recorder.capture_opening() if recorder != null
			else resolver.open_match())
	# Ходящий первым может оказаться машиной (#103): до этого ИИ запускался только ПОСЛЕ
	# чужого действия, и партия «ИИ против ИИ» просто стояла на месте, пока человек не
	# нажмёт что-нибудь — а нажимать ему нечем, своих юнитов у него нет.
	_kick_if_ai()

## Отдать ход текущей стороне, если ею управляет не человек.
func _kick_if_ai() -> void:
	# В сети (batch 12 #15) ИИ ведёт хост, и шаг ему даётся только когда очередь показа
	# пуста — иначе два таймера подняли бы его дважды за одно действие.
	if state == null or _animating or _paused or _net_playing or _match_over:
		return
	var ac: PlayerController = controllers.get(state.active_player())
	if ac == null or ac.is_local_human():
		return
	# Удалённую сторону «пинать» некому и незачем — её ход придёт по сети.
	if ac is NetworkController:
		return
	_queue_ai_step(ac)

# --- Ввод по сетке ---
func _unhandled_input(event: InputEvent) -> void:
	if Keybinds.modal_open(): return
	if event is InputEventKey:
		if _handle_shortcut(event): get_viewport().set_input_as_handled()
		return
	# Ввод над всплывающим меню принадлежит меню (#8): не панорамируем, не зумим
	# и не кликаем по полю под ним. Прокрутку колесом уже получил сам ScrollContainer;
	# всё, что «просочилось» сюда (например, докрутка на границе), просто гасим, чтобы
	# камера не ехала вместе с меню.
	if event is InputEventMouseButton and _pointer_over_popup(event.position):
		return
	# Панорама мышью (средняя/правая кнопка) и жестом тачпада — работает всегда.
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		_mouse_panning = event.pressed
		return
	if event is InputEventMouseMotion and _mouse_panning:
		if _box_dragging: _box_end_screen = event.position
		pan += event.relative
		queue_redraw()
		return
	if event is InputEventPanGesture:
		pan -= event.delta * 24.0
		queue_redraw()
		return
	# Масштаб: колесо мыши и жест щипка тачпада — сохраняем клетку под курсором.
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, ZOOM_STEP)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
			return
	if event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		return
	# Линейка (item 11). Первый клик ставит начало, дальше расстояние тянется за курсором,
	# второй клик закрепляет отрезок; следующий клик начинает НОВЫЙ, а прежние остаются на
	# поле — линеек сколько угодно. Backspace снимает последнюю (или недотянутую), выход
	# из режима (Esc/кнопка) убирает все. Правая кнопка панорамирует камеру — ею не мерим.
	if mode == Mode.RULER:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
				and event.pressed:
			var at := _pos_to_cell(get_viewport().get_mouse_position())
			if not state.grid.in_bounds(at):
				return
			if _ruler_a == Vector2i(-1, -1):
				_ruler_a = at
			else:
				_rulers.append([_ruler_a, at])
				_ruler_a = Vector2i(-1, -1)
			_refresh_ruler_button()
			queue_redraw()
			return
		if event is InputEventMouseMotion:
			var hov := _pos_to_cell(get_viewport().get_mouse_position())
			if hov != _ruler_hover:
				_ruler_hover = hov
				queue_redraw()
			return
	# Рисование аннотаций (item 51): тянем штрих левой кнопкой; отпускание фиксирует его
	# и, в сетевой партии, рассылает. Симуляции это не касается — чистый клиентский слой,
	# поэтому и идёт ДО запрета на время анимации (issues-12 #6): в чужой ход анимации
	# идут почти без перерыва, и нажатия/отпускания кисти терялись через раз.
	if mode == Mode.DRAW:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_stroke_drawing = true
				_cur_stroke = []
				_draw_record_begin(_draw_author(), _draw_scope())
				_stroke_add(_draw_world_pos())
			else:
				_stroke_drawing = false
				_stroke_commit()
				_draw_record_end(_draw_author())
			return
		if event is InputEventMouseMotion:
			if _stroke_drawing:
				_stroke_add(_draw_world_pos())
			queue_redraw()  # кружок кисти под курсором
			return
	# Ластик (item 6): тем же жестом стираем СВОИ штрихи в радиусе кисти под курсором.
	if mode == Mode.ERASE:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_stroke_drawing = true
				_cur_stroke = []
				_draw_record_begin(_draw_author(), -1)
				_erase_at(_draw_world_pos())
			else:
				_stroke_drawing = false
				_erase_commit()
				_draw_record_end(_draw_author())
			return
		if event is InputEventMouseMotion:
			if _stroke_drawing:
				_erase_at(_draw_world_pos())
			queue_redraw()  # кружок ластика под курсором
			return
	if _animating:
		return
	# Рисование ЛДФ-стены: тянем цепочку клеток левой кнопкой; Backspace — отмена
	# последней/выход, Enter — подтвердить, когда набрано 6 клеток (§3.7).
	if mode == Mode.BUILD_WALL:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_wall_drawing = true
				_wall_try_add(_pos_to_cell(get_viewport().get_mouse_position()))
			else:
				_wall_drawing = false
			return
		if event is InputEventMouseMotion:
			if _wall_drawing:
				_wall_try_add(_pos_to_cell(get_viewport().get_mouse_position()))
			else:
				queue_redraw()
			return
	if HOVER_PREVIEW_MODES.has(mode) and event is InputEventMouseMotion:
		queue_redraw()  # обновляем предпросмотр радиуса/струи/окопа под курсором
		return
	# Групповое движение: под курсором показываем, кто куда встанет (#88). Рамку
	# выделения не ломаем — перерисовываем только при отпущенной ЛКМ.
	if mode == Mode.GROUP_MOVE and event is InputEventMouseMotion \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
		var cell := _pos_to_cell(get_viewport().get_mouse_position())
		if cell != _group_mouse_cell:
			_group_mouse_cell = cell
			queue_redraw()
		return
	# Drag a world-anchored selection rectangle; Shift adds to the current group.
	# Двойной щелчок по пассажиру — сам челнок. Одиночные щелчки чередуют «пассажир ↔
	# машина», и если пассажир уже был выбран, двойной приходил обратно к нему.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_click_double = event.double_click
	if _box_selectable() and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_box_start_cell = _pos_to_cell(event.position)
			_box_additive = event.shift_pressed
			_box_start_screen = event.position
			_box_end_screen = event.position
			_box_dragging = false
		else:
			_box_end_screen = event.position
			if _box_dragging:
				_box_dragging = false
				_finalize_box()
			elif event.shift_pressed:
				_shift_pick(_pos_to_cell(event.position))
			else:
				_handle_click(_pos_to_cell(event.position))
		return
	if _box_selectable() and event is InputEventMouseMotion \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_box_end_screen = event.position
		if not _box_dragging and event.position.distance_to(_box_start_screen) >= BOX_DRAG_THRESHOLD:
			_box_dragging = true
		if _box_dragging:
			queue_redraw()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_click(_pos_to_cell(event.position))

func _handle_click(coord: Vector2i) -> void:
	# Пока показана стартовая доска, щелчок по полю лишь возвращает настоящую: приказ по
	# невидимой сейчас доске был бы ловушкой.
	if _before_on:
		_toggle_before()
		return
	if not state.grid.in_bounds(coord):
		_deselect()
		return
	# В повторе клик только РАССМАТРИВАЕТ юнита: меню действий не открывается, потому
	# что действовать в записанной партии нельзя — она уже сыграна.
	if replay != null or _spectator:
		var seen := _unit_at(coord)
		selected_id = seen.id if seen != null else -1
		_refresh_info()
		queue_redraw()
		return
	_inspected_station = coord if state.grid.cell(coord).feature_id == MCF.FEATURE_DRONE_STATION \
			and _cell_seen_now(coord, _view_resolver().team_visible_coords(_viewing_side())) else Vector2i(-1, -1)
	queue_redraw()
	var occupant: UnitInstance = _unit_at(coord)
	# Прицеливание: из стопки «дрон над юнитом» берём того, кто реально доступен как
	# цель, иначе по клетке с дроном нельзя было бы достать наземного бойца (#23).
	if not target_ids.is_empty():
		for u in _stack_at(coord):
			if target_ids.has(u.id):
				occupant = u
				break

	match mode:
		Mode.MOVE:
			if reach != null and reach.can_reach(coord):
				# Если несём пленника — сперва выбираем, куда его положить (§3.4).
				var carried := resolver.held_unit_of(_selected_unit())
				if carried != null:
					move_dest = coord
					item_cells = resolver.carry_drop_cells(coord)
					mode = Mode.CARRY_DROP
					queue_redraw()
					return
				# Огонь на маршруте убивает наповал (#1). Маршрут его уже обходит, так
				# что попасть сюда можно только приказом ИДТИ ПРЯМО В ПЛАМЯ — и такой
				# приказ игрок подтверждает вслух, а не отдаёт промахом мыши.
				var burn := _lethal_fire_step(_selected_unit(), coord)
				if burn != NOWHERE:
					var id := selected_id
					_confirm_dialog("Move Into Fire",
						"%s will burn to death at (%d, %d). Give the order anyway?"
							% [_selected_unit().stats.display_name, burn.x, burn.y],
						"Move Anyway",
						func() -> void: _submit(MoveIntent.new(id, coord)))
					return
				_submit(MoveIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.CARRY_DROP:
			if item_cells.has(coord):
				_submit(MoveIntent.new(selected_id, move_dest, coord))
				return
			_back_to_menu()
		Mode.CORPSE_DROP:
			# Труп кладётся на выбранную клетку, а не молча под ноги (#72). Body pulled out
			# of a vehicle: a chosen cell, or the puller itself to carry it (2026-10-19).
			if item_cells.has(coord):
				if _pull_vehicle_id >= 0:
					_submit(VehicleUnloadCorpseIntent.new(selected_id, _pull_vehicle_id, coord))
				else:
					_submit(DropCorpseIntent.new(selected_id, coord))
				return
			_back_to_menu()
		Mode.WELD:
			if item_cells.has(coord):
				_submit(WeldAirlockIntent.new(selected_id, coord))
				return
			_back_to_menu()
		Mode.MOVE_HELD:
			# Пленника переставляем на соседнюю с носильщиком клетку бесплатно (#100).
			if item_cells.has(coord):
				_submit(MoveHeldIntent.new(selected_id, coord))
				return
			_back_to_menu()
		Mode.SHOOT:
			# The rest of a paid burst may go at ANY valid target (0.11; it was tied to
			# the first firing line by #12). A click on nothing simply leaves shoot mode
			# below — it no longer throws the remaining bullets away.
			if occupant != null and target_ids.has(occupant.id):
				_begin_shoot(occupant)
				return
			var lamp_side := _lamp_side_under_mouse(_selected_unit(), coord)
			if item_cells.has(coord) and (lamp_side >= 0 or resolver.can_shoot_fixture(_selected_unit(), coord) == ""):
				var shooter := _selected_unit()
				var count: int = shooter.action_state.remaining_shots if _pending_shoot(shooter) else shooter.rate_of_fire()
				var sid := selected_id
				var component := "fixture:%d" % lamp_side if lamp_side >= 0 else "fixture"
				if count > 1:
					_open_shot_picker(Furniture.DEFS[resolver.fixture_at(coord, lamp_side)].name, count,
						func(n: int) -> Intent: return ShootIntent.new(sid, -1, n, coord, component))
				else: _submit(ShootIntent.new(sid, -1, -1, coord, component))
				return
			# Шахтёр (item 15): клик по соседней вражеской машине — удар ломом по корпусу.
			if not _melee_veh_ids.is_empty():
				var mvid := state.grid.vehicle_at(coord)
				if _melee_veh_ids.has(mvid):
					_submit(VehicleMeleeIntent.new(selected_id, mvid))
					return
			# Марксманн: клик по ЛЮБОЙ клетке задаёт направление, луч уходит вперёд (#49).
			# Отказ (мало ОД, клик по себе) отдаём резолверу — он объяснит причину в журнале.
			if _is_marksman(_selected_unit()) and coord != _selected_unit().coord:
				# Луч выжигает НАЗВАННЫЙ узел (веха «Modular tank system»): если по трассе
				# луча стоит машина, спрашиваем какой. Раньше вопрос задавался, только когда
				# клик пришёлся ТОЧНО в клетку корпуса; клик за танк или перед ним посылал
				# луч в ту же машину, но молча — в корпус (batch 12 #5). Берём ту же трассу,
				# что рисует предпросмотр, и первую машину на ней, до которой луч дотянется.
				# Свои и союзники на трассе (item 13): спросить, прежде чем стрелять.
				var friends := _beam_friendlies(_selected_unit(), coord)
				if not friends.is_empty() and not _beam_confirmed:
					var aim := coord
					_confirm_dialog("Friendly units in the beam", _friendly_list_text(friends),
							"Fire anyway", func() -> void:
								_beam_confirmed = true
								_handle_click(aim)
								_beam_confirmed = false)
					return
				var beam_foe := _vehicle_on_beam(_selected_unit(), coord)
				var from_c: Vector2i = _selected_unit().coord
				# Список — только видимые с этой стороны узлы; подписи без «(N+)»: луч
				# не бросает кубик, он выжигает названное. Нечего выбирать (с этого борта
				# не виден ни один живой узел) — луч идёт как есть, в корпус.
				var burnable: Array = resolver._aimable_components(beam_foe, from_c) \
						if beam_foe != null else []
				if beam_foe != null and not burnable.is_empty():
					var sid := selected_id
					_open_component_picker(beam_foe, "Burn through", func(comp: String) -> void:
						_submit(ShootIntent.new(sid, -1, -1, coord, comp)), burnable, from_c)
					return
				_submit(ShootIntent.new(selected_id, -1, -1, coord))
				return
			# Противотанкист: удар по пустой клетке пола (§3.14).
			if item_cells.has(coord):
				# Заряд в борт машины наводится на узел — за этим противотанкист и нужен.
				var at_foe := _vehicle_at_cell(coord)
				if at_foe != null and at_foe.owner != _viewing_side():
					var sid2 := selected_id
					_open_component_picker(at_foe, "Aim at", func(comp: String) -> void:
						_submit(ShootIntent.new(sid2, -1, -1, coord, comp)),
						[], _selected_unit().coord)
					return
				# Окно — обычная очередь (0.9.2): сколько пуль, выбирает игрок.
				var wsh := _selected_unit()
				if MCF.is_glass(state.grid.cell(coord).feature_id) and wsh != null:
					var avail: int = wsh.action_state.remaining_shots if _pending_shoot(wsh) else wsh.rate_of_fire()
					if avail > 1:
						_open_shot_picker(String(MCF.feature_name(state.grid.cell(coord).feature_id, "window")),
								avail, func(n: int) -> Intent: return ShootIntent.new(selected_id, -1, n, coord))
						return
				_submit(ShootIntent.new(selected_id, -1, -1, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.GRAB:
			# Единая «рука» (#50): шаг 1 — боец, ТЕЛО или объект; для объекта шаг 2 —
			# куда тащить. Тело берётся в руки сразу, без второго клика (#7): у него
			# нет «куда», оно едет на самом бойце.
			if drag_object == Vector2i(-1, -1):
				if occupant != null and target_ids.has(occupant.id):
					_submit(CaptureIntent.new(selected_id, occupant.id))
					return
				if _corpse_cells.has(coord):
					_submit(PickUpCorpseIntent.new(selected_id, coord))
					return
				if item_cells.has(coord):
					drag_object = coord
					item_cells = resolver.drag_dest_cells(_selected_unit(), coord)
					queue_redraw()
					return
				if _is_own_active(occupant):
					_select(occupant)
					return
				_back_to_menu()
			else:
				if item_cells.has(coord):
					_submit(DragIntent.new(selected_id, drag_object, coord))
					return
				_back_to_menu()
		Mode.ITEM:
			if item_cells.has(coord):
				_submit(UseItemIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.PUSH:
			if item_cells.has(coord):
				_submit(PushIntent.new(selected_id, -1, coord))
				return
			if occupant != null and target_ids.has(occupant.id):
				_submit(PushIntent.new(selected_id, occupant.id))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.DRONE_FLY:
			if _drone_can_ram(coord):
				# Таран — это подрыв на клетке цели (playtest-20: спросить про своих).
				_confirm_blast(_selected_unit(), coord, DroneMoveIntent.new(selected_id, coord))
				return
			if item_cells.has(coord):
				_submit(DroneMoveIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.BUILD:
			if item_cells.has(coord):
				_submit(BuildIntent.new(selected_id, coord, build_feature,
						build_tint if build_feature == MCF.FEATURE_FLOODLIGHT else 0))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.BREAK:
			if item_cells.has(coord):
				_submit(BreakIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.CARRY_FURN, Mode.PUT_FURN:
			if item_cells.has(coord):
				_submit(CarryIntent.new(selected_id, coord) if mode == Mode.CARRY_FURN
						else UseItemIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.DPMG_FIRE:
			if occupant != null and target_ids.has(occupant.id):
				# How many rounds (owner, 2026-10-19): the rest of the burst stays for later.
				var gun := rsp_active
				var tid := occupant.id
				var rounds := _dpmg_rounds_left(_selected_unit(), gun)
				_open_shot_picker(occupant.stats.display_name, rounds if rounds > 0 else MCF.DPMG_RATE_OF_FIRE,
						func(n: int) -> Intent: return DPMGFireIntent.new(selected_id, gun, tid, n))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.DIG:
			# Копка в 3 шага (#16): 1) клетка под окоп, 2) первая куча земли, 3) вторая
			# куча — сразу роем. Игрок сам выбирает, куда лечь вынутой земле.
			if dig_trench == Vector2i(-1, -1):
				if item_cells.has(coord):
					dig_trench = coord
					dig_dirt_a = Vector2i(-1, -1)
					item_cells = resolver.dirt_spots_for(coord, _selected_unit().coord)
					queue_redraw()
					return
				if _is_own_active(occupant):
					_select(occupant)
					return
				_back_to_menu()
			elif dig_dirt_a == Vector2i(-1, -1):
				# Первая куча (можно затем выбрать ту же клетку второй — вырастет выше).
				if item_cells.has(coord):
					dig_dirt_a = coord
					queue_redraw()
					return
				_enter_dig()  # клик мимо — начинаем выбор окопа заново
			else:
				if item_cells.has(coord):
					_submit(DigIntent.new(selected_id, dig_trench, dig_dirt_a, coord))
					return
				_enter_dig()
		Mode.MINE:
			# Мины ставятся по одной, и режим НЕ закрывается: за одно действие их
			# кладут до пяти, и выходить в меню после каждой было бы мучением.
			if item_cells.has(coord):
				_submit(PlaceMineIntent.new(selected_id, coord, _mine_av))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.DISARM:
			# Клик по подсвеченной чужой мине рядом — обезвредить её (item 13).
			if item_cells.has(coord):
				_submit(DisarmMineIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.GROUP_MENU:
			# Меню группы открыто: клик по полю снимает выделение (или берёт другой юнит).
			if occupant != null and _is_own_active(occupant):
				_set_group([])
				_select(occupant)
				return
			_set_group([])
		Mode.GROUP_LASER:
			var dir := _volley_dir(coord)
			if dir != Vector2i.ZERO:
				_fire_volley(dir)
		Mode.GROUP_MOVE:
			# Клик по своему юниту вне группы — обычное выделение; иначе двигаем группу.
			if occupant != null and _is_own_active(occupant) and not _group_ids.has(occupant.id):
				_set_group([])
				_select(occupant)
				return
			_group_move_to(coord)
		Mode.BOARD_PICK:
			var pick := _board_pick_at(coord)
			if pick != null:
				if _board_pick_group:
					_group_embark(pick.id)
				else:
					_board_into(selected_id, pick)
				return
			_back_to_menu()
		Mode.VEH_MOVE:
			if veh_move_targets.has(coord):
				var mt: Dictionary = veh_move_targets[coord]
				var mv := VehicleMoveIntent.new(selected_vehicle_id, mt["dir"], mt["steps"])
				# Свои под гусеницей (playtest-20) — давить только с подтверждения.
				var run_over := resolver.vehicle_move_crushed_friends(_selected_vehicle(),
						mt["dir"], mt["steps"])
				if not run_over.is_empty():
					_confirm_dialog("Friendly units in the way", _friendly_list_text(run_over,
							"The vehicle will run over:", "Drive anyway?"), "Run them over",
							_submit.bind(mv))
					return
				_submit(mv)
				return
			_veh_back_to_menu()
		Mode.VEH_TURN:
			var veh := _selected_vehicle()
			if veh != null:
				var d := coord - veh.center()
				# Только ортогональ (item 2): клик прижимается к доминирующей оси, так что
				# танк не встаёт по диагонали.
				var dir := _ortho_dir(d)
				if dir != Vector2i.ZERO and dir != veh.facing:
					_submit(VehicleTurnIntent.new(selected_vehicle_id, dir))
					return
			_veh_back_to_menu()
		Mode.VEH_CANNON:
			if item_cells.has(coord):
				# По вражеской машине снаряд наводится на УЗЕЛ (веха «Modular tank
				# system»): спрашиваем куда, и лишь потом отдаём приказ. По земле и по
				# пехоте выбирать нечего — там узлов нет.
				var foe := _vehicle_at_cell(coord)
				if foe != null and foe.owner != _viewing_side():
					var vid := selected_vehicle_id
					var port := resolver.cannon_port(_selected_vehicle(), coord)
					_open_component_picker(foe, "Aim at", func(comp: String) -> void:
						_submit(VehicleCannonIntent.new(vid, coord, comp)), [], port)
					return
				_submit(VehicleCannonIntent.new(selected_vehicle_id, coord))
				return
			_veh_back_to_menu()
		Mode.VEH_DISEMBARK:
			if item_cells.has(coord) and veh_disembark_id != -1:
				_submit(VehicleDisembarkIntent.new(veh_disembark_id, coord))
				return
			_veh_back_to_menu()
		Mode.VEH_SEAT:
			# Пересадка пассажира (batch 13 S6): клик по подсвеченному креслу.
			var pu := _selected_unit()
			var pveh := resolver.seated_vehicle_of(pu)
			if pu != null and pveh != null and item_cells.has(coord):
				_submit(VehicleSeatIntent.new(pu.id, _seat_index_at(pveh, coord)))
				return
			_back_to_menu()
		Mode.VEH_BOARD_SEAT:
			# Посадка в выбранное кресло (batch 13 S6).
			var bveh := state.get_vehicle(veh_board_vid)
			if bveh != null and veh_board_id != -1 and item_cells.has(coord):
				_submit(VehicleBoardIntent.new(veh_board_id, bveh.id, _seat_index_at(bveh, coord)))
				return
			_veh_back_to_menu()
		_:
			# Клик по корпусу своей машины — выбрать её. Если в этой клетке сидит свой
			# пассажир (batch 13), первый клик берёт его, повторный — саму машину.
			var cveh := resolver.controllable_vehicle_at(coord, state.active_player())
			if cveh != null and _can_control(cveh.owner):
				# Кликами по очереди: свой дрон над корпусом (issues-12 #7: его было не
				# выбрать — клик брал машину), пассажир в кресле, и лишь затем машина.
				var aboard: Array[UnitInstance] = []
				for su: UnitInstance in _stack_at(coord):
					if su.is_alive() and su.owner == state.active_player() \
							and (su.is_drone or su.aboard_vehicle_id == cveh.id):
						aboard.append(su)
				var at := -1
				for i in aboard.size():
					if aboard[i].id == selected_id:
						at = i
				if not _click_double and at + 1 < aboard.size():
					_select(aboard[at + 1])
					return
				_select_vehicle(cveh)
				return
			var pick := _cycle_pick(coord)
			if pick != null:
				_select(pick)
			else:
				_deselect()

## Контекстная отмена по Esc (#54). Приоритет: закрыть диалог → отменить рисование
## ЛДФ → выйти из под-режима действия в меню (unchoose) → снять выделение → выход.
func _escape_pressed() -> void:
	if _picker.visible and not _animating:
		_picker.hide()
		if selected_vehicle_id != -1:
			mode = Mode.VEH_MENU
			_open_vehicle_menu(_selected_vehicle())
		elif not _group_ids.is_empty():
			mode = Mode.GROUP_MENU
			_open_group_menu()
		else:
			_back_to_menu()
		return
	if _quit_dialog.visible:
		_quit_dialog.hide()
		return
	# Выход из линейки (item 11) — с очисткой отрезка; и во время чужой анимации тоже.
	if mode == Mode.RULER:
		_exit_ruler()
		return
	# Выход из режима рисования/стирания аннотаций (item 14/51): бросаем незавершённый штрих.
	if mode == Mode.DRAW or mode == Mode.ERASE:
		# Недотянутый штрих уже на холсте — доводим его, как при отпускании кнопки: иначе
		# он остался бы только у себя, не ушёл бы по сети и не откатывался бы.
		if _stroke_drawing:
			_stroke_drawing = false
			if mode == Mode.DRAW:
				_stroke_commit()
			else:
				_erase_commit()
			_draw_record_end(_draw_author())
		_cur_stroke = []
		mode = Mode.NONE
		queue_redraw()
		return
	if _animating:
		return
	# Отмена незакоммиченного рисования ЛДФ-стены.
	if mode == Mode.BUILD_WALL:
		_wall_cells = []
		_refresh_undo_btn()
		_back_to_menu()
		return
	# Групповое движение (#19) — вернуться в меню группы.
	if mode == Mode.GROUP_MOVE or mode == Mode.GROUP_LASER:
		mode = Mode.GROUP_MENU
		_open_group_menu()
		queue_redraw()
		return
	# Групповое выделение (#18) — снять его.
	if mode == Mode.GROUP_MENU:
		_set_group([])
		return
	# Выбрано действие машины — вернуть меню машины.
	if selected_vehicle_id != -1 and mode != Mode.VEH_MENU:
		_veh_back_to_menu()
		return
	# Выбрано действие пехотинца — вернуть меню юнита (отменить выбор действия).
	if selected_id != -1 and mode != Mode.MENU and mode != Mode.NONE:
		_back_to_menu()
		return
	# Юнит/машина выбраны, но мы в меню — снять выделение.
	if selected_id != -1 or selected_vehicle_id != -1:
		_deselect()
		return
	# Ничего не выбрано — открыть выход в главное меню.
	_quit_dialog.show()

# --- Поток намерений (с анимацией кубиков) ---
func _submit(intent: Intent) -> void:
	if replay != null:
		return   # запись только смотрят: подавать за неё намерения некому
	if networked and (state.active_player() != my_owner or _net_request_pending):
		return
	# Ход ведёт машина — намерения игрока не принимаются (item 8). Между шагами ИИ
	# _animating опущен, поэтому кнопка «конец хода» в этот момент доходила сюда и
	# роняла партию на присваивании AIController в переменную человека.
	var ctrl := controllers[state.active_player()] as LocalHumanController
	if ctrl == null:
		return
	ctrl.submit(intent)

func _on_intent_ready(intent: Intent) -> void:
	if _spectator: return
	# После победы доска стоит (batch 13 #9): намерения не принимаются ни от людей,
	# ни от ИИ. В сети хост точно так же не передаёт их дальше.
	if _match_over:
		return
	if networked:
		if _net_request_pending or _net_playing: return
		_net_request_pending = not net.is_host
		_menu.hide()
		_picker.hide()
		_clear_hint_cell()
		net.submit_local(intent)
		return
	_menu.hide()
	_picker.hide()
	_clear_hint_cell()
	# Снимки для отката берёт РЕЗОЛВЕР (item 28) — он один делает это одинаково у
	# всех пиров. Здесь остаётся только показ.
	# Смерть показываем только ПОСЛЕ анимации броска защиты (#46): снимок живых
	# до применения, чтобы отрисовать погибших ещё живыми, пока крутится кубик.
	var alive_before := {}
	for _u in state.all_units():
		if _u.status != MCF.Status.CORPSE:
			alive_before[_u.id] = true
	# Сколько ОД было у действующего юнита ДО хода (#99): пока крутится кубик, точки
	# рисуем по старому значению, и игрок видит, как одна из них гаснет за действие.
	var ap_actor := state.get_unit(intent.actor_id) if intent.actor_id >= 0 else null
	var ap_before := ap_actor.remaining_ap if ap_actor != null else 0
	var result := resolver.resolve(intent)
	if not result.ok:
		# Отказ невидимому чужому бойцу или машине в журнал не идёт (issues-12 #5).
		if _result_is_audible(result):
			state.log.add("[denied] " + result.reason)
		# Отказ на ходу ИИ раньше просто обрывал цепочку: следующий шаг никто не
		# заказывал. Пока поле было кликабельным (#60), это выглядело как «ИИ отдал
		# ход игроку»; теперь ввод закрыт, и обрыв означал бы намертво зависший ход.
		# Поэтому ведём ИИ дальше, а от зацикливания страхуемся счётчиком подряд идущих
		# отказов — упёршись, сдаём ход принудительно.
		var denied_ctrl: PlayerController = controllers.get(state.active_player())
		if denied_ctrl != null and not denied_ctrl.is_local_human():
			_ai_denied_streak += 1
			denied_ctrl.notify_intent_denied(state)
			if _ai_denied_streak >= AI_MAX_DENIED:
				state.log.add("[ai] stuck after %d refusals - ending turn." % _ai_denied_streak)
				_ai_denied_streak = 0
				_on_intent_ready(EndTurnIntent.new())
				return
			_queue_ai_step(denied_ctrl)
			return
		_back_to_menu()
		return
	_ai_denied_streak = 0
	# Действие прошло — контроллеру, который копит отказы, пора их забыть (иначе
	# LearnedController продолжит исключать намерения, отказанные на ПРЕЖНЕЙ доске).
	var ok_ctrl: PlayerController = controllers.get(state.active_player())
	if ok_ctrl != null and ok_ctrl.has_method("notify_intent_accepted"):
		ok_ctrl.notify_intent_accepted()
	# Откат и повтор переставляют всю доску разом: выделение и подсветка после них
	# указывают в пустоту, а контроллеры держат устаревшую картину.
	if intent is UndoIntent or intent is RedoIntent:
		_resync_after_restore()
		return
	if not result.dice_events.is_empty():
		# Кто погиб в этом действии — рисуем живым до конца броска.
		_pending_death_ids.clear()
		for _u in state.all_units():
			if _u.status == MCF.Status.CORPSE and alive_before.has(_u.id):
				_pending_death_ids[_u.id] = true
		if ap_actor != null and ap_actor.remaining_ap != ap_before:
			_ap_display[ap_actor.id] = ap_before
			result.dice_events.append({
				"kind": "ap", "unit": ap_actor.id,
				"from": ap_before, "left": ap_actor.remaining_ap,
			})
		_hold_visual = result.visual_hold  # item 22: держим «до взрыва», пока крутится кубик
		queue_redraw()
		var mover: PlayerController = controllers.get(state.active_player())
		if mover != null and mover.is_local_human() and replay == null and _walks_only(result.dice_events):
			# Your own soldiers just walking (0.11): the walk plays on its own and the screen
			# stays live — select another unit and give it orders while this one moves.
			_ap_display.erase(ap_actor.id if ap_actor != null else -1)
			_play_walks_free(result.dice_events)
		else:
			_fx.preview_lanes(result.fx)   # who fires at whom shows while the dice roll
			await _play_dice(result.dice_events, not _result_is_audible(result))
		queue_redraw()
	# Косметика (#21) добавляется ПОСЛЕ анимации броска, а смерть, кровь и взрыв — когда
	# пуля или снаряд долетели (0.12.1).
	await _show_effects(result)
	if _result_is_audible(result):
		state.log.publish_result(result)
	for c in controllers.values():
		c.notify_state_changed(state)
	# Победа (batch 13 #9): партия замирает, следующий шаг ИИ не заказывается.
	if _check_match_over():
		return
	var active_ctrl: PlayerController = controllers[state.active_player()]
	if not active_ctrl.is_local_human():
		_refresh_status()
		_deselect()
		_queue_ai_step(active_ctrl)
		return
	if not _select_spawned_drone(intent, result) and not _select_borg_pilot(intent, result):
		_after_action()

## Следующий шаг ИИ — через короткую паузу (#52). Без неё вся армия отрабатывает
## за считаные кадры, и вместо хода видно только мгновенный итог; с паузой бойцы
## заметно ходят ОДИН ЗА ДРУГИМ. Пауза же не даёт кадру «залипнуть» на расчётах.
func _queue_ai_step(ctrl: PlayerController) -> void:
	# Выход из партии во время хода ИИ (item 10): узел уже вне дерева, get_tree() вернул
	# бы null прямо на этом create_timer. Планировать нечего — некому ходить.
	if not is_inside_tree():
		return
	await get_tree().create_timer(AI_STEP_DELAY / GameConfig.ai_speed).timeout
	# Пауза (item 4) держится здесь, в единственной точке, откуда ИИ вообще получает
	# ход. Снятие паузы само зовёт _kick_if_ai(), и бой продолжается с того же места.
	if _paused:
		return
	# За время паузы ход мог смениться (сдача хода, загрузка, конец боя).
	if is_inside_tree() and state != null and state.active_player() == ctrl.owner and controllers.get(ctrl.owner) == ctrl:
		ctrl.begin_turn(state)

func _toggle_pause() -> void:
	if not _pause_available():
		return
	_paused = not _paused
	_refresh_pause_button()
	state.log.add("[paused]" if _paused else "[resumed]")
	if not _paused:
		_kick_if_ai()

## Проверить исход и, если он есть, остановить партию. Возвращает true, когда бой окончен.
## В просмотре повтора исход не объявляется: там доской правит запись, а не игроки.
func _check_match_over() -> bool:
	if _match_over:
		return true
	if replay != null:
		return false
	# В сети исход объявляет хост (batch 14): гость ждёт K_OVER.
	if networked and net != null and not net.is_host:
		return false
	var out := resolver.match_outcome()
	if not out["over"]:
		return false
	_match_over = true
	var title := _outcome_title(out)
	if networked and session != null:
		session.send({"k": K_OVER, "t": title})
	_declare_match_over(title)
	return true

func _declare_match_over(title: String) -> void:
	if session != null and session.is_host():
		for peer in session.waiting_peers:
			session.send_to(peer, {"k": NetHandoff.K_RECLAIM_STATUS, "error": "This match has ended."})
		session.claims.offers.clear()
	_match_over = true
	state.log.add("— %s —" % title)
	_deselect()
	_menu.hide()
	_picker.hide()
	_clear_hint_cell()
	_show_victory(title)
	_refresh_status()
	queue_redraw()

func _after_action() -> void:
	_refresh_status()
	_refresh_component_panel()
	# Цепочка действий машины: переоткрыть её меню, пока она жива.
	if selected_vehicle_id != -1:
		var veh := _selected_vehicle()
		if veh != null and veh.alive() and _can_control(veh.owner):
			_select_vehicle(veh)
		else:
			_deselect()
		return
	var u := _selected_unit()
	# Копка окопов подряд (#16): пока есть кредит/ОД и куда копать — остаёмся в режиме
	# DIG, не отвлекая игрока меню. Иначе — обычная цепочка действий через меню.
	if mode == Mode.MINE and _is_own_active(u) and (u.remaining_ap > 0 or u.mine_credits > 0) \
			and not resolver.mine_cells(u).is_empty():
		_enter_mine()
		return
	if mode == Mode.DIG and _is_own_active(u) and (u.remaining_ap > 0 or u.dig_credits > 0) \
			and not resolver.diggable_cells(u).is_empty():
		_enter_dig()
		return
	# Партия борга (batch borg-corpses): три постройки за ОД кладутся подряд, как окопы, —
	# режим остаётся, пока в партии что-то есть и есть куда ставить.
	if mode == Mode.BUILD and _is_own_active(u) and u.borg_id != -1 \
			and int(u.build_credits.get(build_feature, 0)) > 0 \
			and not resolver.buildable_cells(u, build_feature).is_empty():
		_enter_build(build_feature)
		return
	# Выделенная группа остаётся выделенной после приказа (batch ui-drones): раньше её
	# снимало, и для следующего шага отряд приходилось обводить заново.
	if _group_ids.is_empty() and not _regroup_ids.is_empty():
		_group_ids = _regroup_ids
	_regroup_ids = []
	if not _group_ids.is_empty():
		var keep: Array[int] = []
		for gid: int in _group_ids:
			if _is_own_active(state.get_unit(gid)):
				keep.append(gid)
		_set_group(keep)
		return
	# Один боец тоже остаётся выделенным, даже без ОД: меню просто показывает погашенные
	# кнопки. Снимается выделение лишь с погибшего или когда ход ушёл.
	if _is_own_active(u):
		_select(u)  # переоткрываем меню для цепочки действий
	else:
		_deselect()

## Возврат в лобби (item 20). В сетевой партии — на экран лобби (если он есть), иначе
## та же дорога, что и в главное меню.
func _to_lobby() -> void:
	_to_menu()

func _open_editor() -> void:
	if networked:
		return
	get_tree().change_scene_to_file("res://scenes/MapEditor.tscn")

func _to_menu() -> void:
	# Запись матча дописывается на выходе — до этого момента неизвестно, чем он кончился.
	_replay_playing = false
	_flush_replay()
	# Сессия висит под /root (#54), поэтому её надо закрыть руками: смена сцены
	# сама её не заберёт, а живой ENet-пир помешал бы завести новую партию.
	if session != null:
		session.close()
		session.queue_free()
		session = null
	networked = false
	net = null
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

func _on_end_turn_pressed() -> void:
	GameAudio.ui()
	if _animating or _match_over:
		return
	_deselect()
	_submit(EndTurnIntent.new(state.active_player()))

## Откат (#47). Отменяет даже мельчайшие шаги: если сейчас рисуется ЛДФ-стена —
## снимает последнюю выложенную клетку; иначе восстанавливает состояние из стека.
func _on_undo_pressed() -> void:
	if replay != null or _animating or not _my_turn():
		return
	# Незакоммиченное рисование ЛДФ-стены: убираем последнюю клетку (как Backspace).
	if mode == Mode.BUILD_WALL and not _wall_cells.is_empty():
		_wall_undo()
		return
	if not resolver.can_undo():
		return
	_submit(UndoIntent.new(state.active_player()))

## Повтор отменённого действия (#38): зеркало Undo.
func _on_redo_pressed() -> void:
	if replay != null or _animating or not _my_turn() or not resolver.can_redo():
		return
	_submit(RedoIntent.new(state.active_player()))

## Доска переставлена откатом/повтором внутри резолвера — привести к ней экран.
func _resync_after_restore() -> void:
	if _audio != null:
		_audio.reset()
		_audio.turn_key_from_state(state)
	# Resolver restores the matching cosmetic checkpoint; earlier battle debris remains.
	_walk_jobs.clear()
	_walks_running = 0
	_walk_cells.clear()
	_walk_offset.clear()
	_veh_offset.clear()
	_pending_death_ids.clear()
	_hold_visual = {}
	_deselect()
	for c in controllers.values():
		c.notify_state_changed(state)
	_refresh_status()
	queue_redraw()

## Откат доступен ТОЛЬКО на своём ходу (#94): на ходу ИИ, мирных или соперника по
## сети кнопка гаснет — переигрывать чужой ход нельзя.
func _my_turn() -> bool:
	return state != null and _can_control(state.active_player())

func _on_log_line(text: String) -> void:
	if _log_label != null:
		_log_label.append_text(text + "\n")
		if _audio != null:
			_audio.message(text)

func _play_victory_audio() -> void:
	if _audio == null or _audio_victory_played:
		return
	_audio_victory_played = true
	var outcome := resolver.match_outcome()
	var winner := str(outcome.get("winner", ""))
	var key := "draw" if winner == "" else ("victory" if winner == MatchMode.team_key(state.roster, _viewing_side()) else "defeat")
	GameAudio.ui(key)
	GameAudio.say(key, _audio, 100)

func _audio_cell_visible(cell: Vector2i) -> bool:
	if state == null or not state.grid.in_bounds(cell):
		return false
	return not _view_resolver().visibility_limited() or _visible_before_impact(_viewing_side()).has(cell)

func _audio_own_cell(cell: Vector2i) -> bool:
	if state == null or not state.grid.in_bounds(cell):
		return false
	var at := state.grid.cell(cell)
	var own := _viewing_side()
	return (at.occupant != null and state.roster.are_allies(at.occupant.owner, own)) \
		or (at.vehicle_id >= 0 and state.get_vehicle(at.vehicle_id) != null \
			and state.roster.are_allies(state.get_vehicle(at.vehicle_id).owner, own))
