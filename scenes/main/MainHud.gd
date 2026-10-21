@abstract
extends "res://scenes/main/MainOrders.gd"

## The interface around the board: panels, buttons, status, clocks, initiative, cameras,
## chat and the end-of-match screens.

## Можно ли вообще ставить на паузу (item 4): когда КАЖДУЮ сторону ведёт машина.
## В сети и в просмотре повтора паузы нет: там темпом распоряжается не эта сессия.
func _pause_available() -> bool:
	if networked or replay != null or state == null or state.roster == null:
		return false
	var sides := state.roster.player_ids()
	if sides.is_empty():
		return false
	for side: int in sides:
		if not _side_is_ai(side):
			return false
	return true

## Строка темпа ИИ видна, пока есть кем его менять: ИИ в составе или налётчики на поле.
func _refresh_ai_speed_row() -> void:
	if _ai_speed_row == null or state == null or state.roster == null:
		return
	_ai_speed_row.visible = state.roster.slots.any(
			func(sl: Roster.Slot) -> bool: return sl.kind == Roster.SlotKind.AI) \
			or state.all_units().any(
			func(u: UnitInstance) -> bool: return MCF.is_independent(u.owner) and u.is_alive())

## Кнопка паузы видна только там, где пауза имеет смысл, и всегда говорит, что сделает.
func _refresh_pause_button() -> void:
	if _pause_btn == null:
		return
	var can := _pause_available()
	_pause_btn.visible = can
	_pause_btn.text = "Resume" if _paused else "Pause"
	# Сторону мог взять человек, пока стояла пауза, — тогда держать бой больше нечем.
	if not can and _paused:
		_paused = false
		_kick_if_ai()

## Заголовок итога партии по исходу резолвера (match_outcome): кто и как победил.
func _outcome_title(out: Dictionary) -> String:
	var md := resolver.mode
	var key := str(out["winner"])
	match str(out["reason"]):
		"draw":
			return "Everyone is dead — the match is a draw"
		"held":
			return "All %d waves held — the defenders win!" % md.waves_total
		"overrun":
			if md.endless():
				return "Overrun — held out %d round(s), %d wave(s) beaten, %d fighter(s) killed" % [
						state.turns.round_number, resolver.waves_beaten(), md.wave_spawned - resolver.wave_fighters_left()]
			return "Overrun on wave %d of %d — the waves win" % [md.wave, md.waves_total]
		"points":
			var runner := 0
			for k: String in md.scores:
				if k != key:
					runner = maxi(runner, int(md.scores[k]))
			return "%s wins on points, %d–%d!" % [resolver.team_label(key), int(md.scores[key]), runner]
	return "%s wins the match!" % resolver.team_label(key)

## Разбор партии обученной политикой (item: «play vs latest»). Прогоняет записанный матч
## и на каждом решении обеих сторон спрашивает политику, что сделала бы она и во что
## оценивает позицию; из расхождений и провалов оценки складывается список ошибок.
##
## Идёт порциями с возвратом кадра: каждый вопрос — это обращение к серверу политики, и
## матч на триста ходов иначе подвесил бы экран на минуты.
func _show_match_analysis() -> void:
	if recorder == null or recorder.is_empty():
		return
	var analyst := MatchAnalyst.new()
	if not analyst.begin(recorder.to_dict(), _round_cap_for_analysis()):
		_toast_analysis("The recording could not be opened: " + analyst.error)
		return
	var overlay := Control.new()
	overlay.add_to_group("shortcut_modal")
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("What the Model Makes of It"))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	frame.add_child(SteamChrome.pad(body, 16, 14))
	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(520, 0)
	status.text = "Going back through the match…"
	body.add_child(status)
	var report := RichTextLabel.new()
	report.custom_minimum_size = Vector2(520, 300)
	report.bbcode_enabled = false
	report.scroll_following = false
	body.add_child(report)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	body.add_child(row)
	var shut := Button.new()
	shut.text = "Close"
	shut.custom_minimum_size = Vector2(120, 34)
	shut.pressed.connect(overlay.queue_free)
	row.add_child(shut)
	_ui_layer.add_child(overlay)
	Ui.theme_canvas_layers()
	while analyst.has_next():
		if not is_instance_valid(overlay):
			return   # окно закрыли — разбор никому не нужен
		analyst.step_many()
		status.text = "Going back through the match… %d of %d" % [analyst.done(), analyst.total()]
		await get_tree().process_frame
	if not is_instance_valid(overlay):
		return
	if analyst.rows.is_empty():
		status.text = "No verdict: " + (analyst.error if analyst.error != ""
				else "the model had nothing to say about this match.")
		return
	status.text = _analysis_summary(analyst)
	report.text = _analysis_body(analyst)

## Шапка разбора: насколько часто каждая сторона играла то же, что выбрала бы политика.
func _analysis_summary(analyst: MatchAnalyst) -> String:
	var out := "Agreement with the model, move by move:\n"
	for side: int in state.roster.player_ids():
		if not MCF.is_player(side):
			continue
		out += "  %s — %d%%\n" % [state.roster.name_of(side),
				roundi(analyst.agreement(side) * 100.0)]
	out += "\nBelow: the moves after which the model's own read of the position fell "
	out += "the furthest. That drop covers the move AND whatever the opponent did next."
	return out

func _analysis_body(analyst: MatchAnalyst) -> String:
	var out := ""
	for row: Dictionary in analyst.worst(10):
		if float(row["swing"]) >= 0.0:
			continue
		out += "Round %d · %s\n" % [int(row["round"]), state.roster.name_of(int(row["side"]))]
		out += "    played      %s\n" % String(row["played"])
		if not bool(row["offered"]):
			out += "    (the model was not shown this move, so it does not judge it)\n"
		elif not bool(row["agreed"]):
			out += "    would play  %s\n" % String(row["suggested"])
		else:
			out += "    the model would have played the same and still lost ground\n"
		out += "    position    %+.3f after it\n\n" % float(row["swing"])
	if out == "":
		out = "Nothing stands out: the model never saw the position swing hard against either side."
	return out

## Потолок раундов, с которым политика училась. Для разбора важно лишь, чтобы он был тем
## же самым, что в бою, — иначе «сколько осталось» читается иначе.
func _round_cap_for_analysis() -> int:
	var env := int(OS.get_environment("MCF_RL_ROUND_CAP"))
	return env if env > 0 else 40

func _toast_analysis(text: String) -> void:
	state.log.add(text)

func _show_victory(title: String) -> void:
	_play_victory_audio()
	# Бой кончился — секундомер стола встаёт здесь и дальше не бежит.
	if _real_stop_ms < 0:
		_real_stop_ms = Time.get_ticks_msec()
	if _victory_overlay != null:
		_victory_overlay.queue_free()
	var overlay := Control.new()
	overlay.add_to_group("shortcut_modal")
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Match Over"))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	frame.add_child(SteamChrome.pad(body, 16, 14))
	var msg := Label.new()
	msg.text = title + "\nThe battle is frozen — nothing else will happen on the board."
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size = Vector2(340, 0)
	body.add_child(msg)
	body.add_child(_kills_table())
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	if MatchAnalyst.available() and recorder != null and not recorder.is_empty():
		var study := Button.new()
		study.text = "Ask the Model"
		study.custom_minimum_size = Vector2(130, 34)
		study.pressed.connect(_show_match_analysis)
		row.add_child(study)
	var close := Button.new()
	close.text = "Look at the Board"
	close.custom_minimum_size = Vector2(130, 34)
	close.pressed.connect(func() -> void: overlay.hide())
	row.add_child(close)
	var menu := Button.new()
	menu.text = "Return to Menu"
	menu.custom_minimum_size = Vector2(130, 34)
	menu.pressed.connect(_to_lobby)
	row.add_child(menu)
	_victory_overlay = overlay
	_ui_layer.add_child(overlay)
	Ui.theme_canvas_layers()

## Таблица итогов (playtest-20): сколько убил каждый боец и каждая машина — пулей,
## взрывом, лучом или гусеницей (state.kills ведёт резолвер). Лучшие — сверху.
func _kills_table() -> Control:
	var box := SteamChrome.group_box("Unit efficiency")
	var ids: Array = state.kills.keys()
	ids.sort_custom(func(a: int, b: int) -> bool:
		var ka: int = state.kills[a][0]
		var kb: int = state.kills[b][0]
		return ka > kb if ka != kb else a < b)
	if ids.is_empty():
		var none := Label.new()
		none.text = "Nobody was killed this match."
		box.body.add_child(none)
		return box
	var table := GridContainer.new()
	table.columns = 4
	table.add_theme_constant_override("h_separation", 18)
	table.add_theme_constant_override("v_separation", 3)
	for h: String in ["Unit", "Player", "Kills", "Run over"]:
		var hl := Label.new()
		hl.text = h
		hl.add_theme_font_size_override("font_size", 12)
		hl.add_theme_color_override("font_color", Color("#b0b0b0"))
		table.add_child(hl)
	for id: int in ids:
		var rec: Array = state.kills[id]
		var who := ""
		var side := -1
		var alive := true
		var u := state.get_unit(id)
		var v := state.get_vehicle(id) if u == null else null
		if u != null:
			who = u.stats.display_name
			side = u.owner
			alive = u.is_alive()
		elif v != null:
			who = VehicleDB.get_vehicle(v.type_id).get("name", v.type_id)
			side = v.owner
			alive = v.alive()
		else:
			continue
		var cells: Array[String] = [who + ("" if alive else "  †"), _side_label(side),
				str(rec[0]), str(rec[1]) if v != null else "—"]
		for i in cells.size():
			var l := Label.new()
			l.text = cells[i]
			l.add_theme_font_size_override("font_size", 12)
			if i == 1:
				l.add_theme_color_override("font_color", _side_color(side).lightened(0.25))
			table.add_child(l)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, mini(240, 22 + ids.size() * 20))
	scroll.add_child(table)
	box.body.add_child(scroll)
	return box

## Отрисовка одного дрона (item 14): вынесена из общего прохода, чтобы дрон рисовался
## верхним слоем — поверх корпусов машин, над которыми он висит.
## Чёрная полоса-дорожка под «булавкой» ползунка кисти (item 13): без неё грабер висел
## на пустом месте и не читался. Даём слайдеру видимую тёмную дорожку и высоту.
## Чёрная дорожка под ползунком повтора (item 7).
func _style_replay_slider(s: HSlider) -> void:
	s.custom_minimum_size = Vector2(0, 18)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0, 0, 0, 0.85)
	track.set_corner_radius_all(3)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	s.add_theme_stylebox_override("slider", track)

## Ползунок кисти в строку с окошком значения, куда можно вписать число (оформление —
## общий набор интерфейса, как у ползунков лобби).
func _brush_row(s: HSlider) -> HBoxContainer:
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(s)
	var e := Ui.slider_entry(s, func(v: float) -> String: return str(int(v)))
	e.custom_minimum_size = Vector2(40, 0)
	row.add_child(e)
	return row

## «Report a Bug» (0.12): к отчёту можно приложить журнал боя и запись матча.
func _open_bug_report() -> void:
	var combat := ""
	if state != null:
		var tail: Array[String] = state.log.lines.slice(maxi(0, state.log.lines.size() - 400))
		combat = "\n".join(tail)
	var rec := ""
	if recorder != null and not recorder.is_empty():
		rec = JSON.stringify(recorder.to_dict())
	BugReportWindow.open(self, combat, rec)

# --- Правое меню боя: только горизонтальный размер, окно неподвижно (item 6) ---
## Тянем ЛЕВЫЙ край панели: влево — шире, вправо — уже. Панель остаётся приклеенной к
## правому краю экрана (offset_right = 0), меняется лишь offset_left = -ширина.
func _on_hud_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_hud_resizing = true
			_hud_resize_start = event.global_position
			_hud_resize_origin = Vector2(_hud_width, 0)
		else:
			_hud_resizing = false
	elif event is InputEventMouseMotion and _hud_resizing:
		var dx: float = event.global_position.x - _hud_resize_start.x
		_hud_width = clampf(_hud_resize_origin.x - dx, HUD_WIDTH_MIN, HUD_WIDTH_MAX)
		if _hud_window != null:
			_hud_window.offset_left = -_hud_width
		_reposition_hud_grip()

func _reposition_hud_grip() -> void:
	if _hud_grip == null or _hud_window == null:
		return
	# Грип — тонкая полоса на левом крае панели, во всю её высоту.
	var vp := get_viewport_rect().size
	_hud_grip.position = Vector2(vp.x - _hud_width - _hud_grip.custom_minimum_size.x, 0)
	_hud_grip.size = Vector2(_hud_grip.custom_minimum_size.x, vp.y)
	# Чат приколот к правому-нижнему углу, но левее правого меню — пока игрок его не
	# перетащил сам (item 8): после ручного переноса автопозиционирование отключается.
	if _chat_panel != null and not _chat_moved:
		_chat_panel.position = Vector2(vp.x - _hud_width - _chat_panel.size.x - 20.0,
				vp.y - _chat_panel.size.y - 12.0)
	# Журнал боя — в левом-нижнем углу (item 6), тоже до первого ручного переноса (item 8).
	if _log_panel != null and not _log_moved:
		_log_panel.position = Vector2(12.0, vp.y - _log_panel.size.y - 12.0)
	# Не помещаются рядом (крупный интерфейс, item 23, или раздвинутый журнал) — чат встаёт
	# над журналом, а не поверх него.
	if _chat_panel != null and _log_panel != null and not _chat_moved \
			and _chat_panel.get_rect().intersects(_log_panel.get_rect()):
		_chat_panel.position.y = maxf(0.0, _log_panel.position.y - _chat_panel.size.y - 8.0)
	# Панель узлов машины (веха «Modular tank system») — СПРАВА от меню действий, на той
	# же верхней линии (batch 13 #13). Раньше она стояла над журналом боя в левом-нижнем
	# углу, и длинное меню машины, растущее из левого-верхнего, накрывало её. Меню и
	# панель открываются вместе с выбором машины, так что рядом им и место; когда меню
	# спрятано (машине нечего предложить), панель прижимается к самому углу.
	# После ручного переноса её больше не двигаем (item 8).
	if _comp_panel != null and _comp_panel.visible and not _comp_moved:
		var left: float = MENU_ANCHOR.x
		if _menu != null and _menu.visible:
			left = _menu.position.x + _menu.size.x + 12.0
		_comp_panel.position = Vector2(left, MENU_ANCHOR.y)
	# The drawing panel steps right of an open action menu (and the vehicle panel beside
	# it) instead of lying on top of it, and comes back when they close.
	if _draw_panel != null and _draw_panel.visible:
		var draw_left := 12.0
		for other: Control in [_menu, _comp_panel]:
			if other != null and other.visible and Rect2(Vector2(draw_left, _draw_panel.position.y),
					_draw_panel.size).intersects(other.get_rect()):
				draw_left = other.position.x + other.size.x + 12.0
		_draw_panel.position.x = draw_left
	# Полоса повтора (M12) — по центру внизу, как у любого проигрывателя.
	if _replay_bar != null:
		_replay_bar.position = Vector2((vp.x - _replay_bar.size.x) * 0.5,
				vp.y - _replay_bar.size.y - 14.0)

# --- UI ---
func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	add_child(_ui_layer)

	# --- Правое меню боя (item 6): приклеено к правому краю, не двигается, тянется
	# ТОЛЬКО по горизонтали. Содержит строго заданный набор: ход/раунд, конец хода,
	# отмена/повтор, возврат в меню, мульти-выбор, рисование/стирание с размерами кистей,
	# «показывать команде» и «скрыть чужие рисунки» — и ничего больше.
	var panel := PanelContainer.new()
	SteamChrome.apply_panel(panel)
	PanelInteraction.sidebar(panel, _hud_width)
	_ui_layer.add_child(panel)
	_hud_window = panel

	# Ручка ширины — узкая вертикальная полоса на ЛЕВОМ крае панели. Тянешь влево/вправо —
	# меняешь только ширину; окно с места не сдвигается.
	_hud_grip = Control.new()
	_hud_grip.custom_minimum_size = Vector2(8, 0)
	_hud_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_hud_grip.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_hud_grip.gui_input.connect(_on_hud_grip_input)
	_ui_layer.add_child(_hud_grip)
	var grip_mark := ColorRect.new()
	grip_mark.color = Ui.accent_color()
	grip_mark.set_anchors_preset(Control.PRESET_FULL_RECT)
	grip_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_grip.add_child(grip_mark)

	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("MCF Isotope"))
	var body := ScrollContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(body)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vpad := SteamChrome.pad(vbox, 8, 6)
	vpad.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # иначе разделы ужимались до своего минимума
	body.add_child(vpad)

	# Текущий ход + номер раунда, и отдельной строкой — кто ходит до и после игрока.
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)
	_turn_neighbors_label = Label.new()
	_turn_neighbors_label.add_theme_font_size_override("font_size", 11)
	_turn_neighbors_label.modulate = Color(0.78, 0.81, 0.88)
	_turn_neighbors_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_turn_neighbors_label)
	_clock_label = Label.new()
	_clock_label.add_theme_font_size_override("font_size", 11)
	_clock_label.modulate = Color(0.78, 0.81, 0.88)
	vbox.add_child(_clock_label)
	# Режим партии (0.12): счёт Capture & Hold или волны Holdout. В обычном бою скрыт.
	_objective_group = SteamChrome.group_box_compact("Objective")
	_objective_group.body.add_theme_constant_override("separation", 3)
	vbox.add_child(_objective_group)

	# Разделы — групповые окошки набора (аудит UI, editor-rework): «ход», «партия»,
	# «инструменты», «рисование». Состав кнопок тот же, что задан в item 6.
	var turn_box := _hud_group(vbox, "Turn")
	var end_btn := Button.new()
	end_btn.text = "End Turn"
	end_btn.focus_mode = Control.FOCUS_NONE
	end_btn.custom_minimum_size = Vector2(0, 32)
	end_btn.pressed.connect(_on_end_turn_pressed)
	turn_box.add_child(end_btn)
	_undo_btn = _compact_button("Undo", _on_undo_pressed)
	_undo_btn.disabled = true
	_redo_btn = _compact_button("Redo", _on_redo_pressed)
	_redo_btn.disabled = true
	turn_box.add_child(_button_row([_undo_btn, _redo_btn]))
	# Сохранение вернулось в правое меню (batch 13 #3): Ctrl+S остаётся, но кнопка
	# нужна тем, кто горячих клавиш не знает. В просмотре повтора сохранять нечего.
	# Пауза боя машин (item 4). Кнопка живёт рядом с управлением ходом и показывается
	# только когда обе стороны ведёт ИИ — в остальных случаях останавливать нечего.
	_pause_btn = _compact_button("Pause", _toggle_pause)
	turn_box.add_child(_pause_btn)
	_refresh_pause_button()

	var match_box := _hud_group(vbox, "Match")
	_save_btn = _compact_button("Save Game", _save_game)
	_save_btn.visible = replay == null
	# «Возврат в меню» — единая кнопка: в сети уводит из партии, в одиночке — в главное меню.
	match_box.add_child(_button_row([_save_btn, _compact_button("Return to Menu", _to_lobby)]))
	# Настройки (items 17/23): размер интерфейса и акцент — не выходя из боя.
	# «Было / стало» (0.9.2) — рядом: доска, какой она была в начале боя, и обратно.
	_before_btn = _compact_button("Before / After", _toggle_before)
	_before_btn.toggle_mode = true
	_before_btn.tooltip_text = "Show the battlefield as it was at the start (press again to come back)."
	match_box.add_child(_button_row([_compact_button("Settings", func() -> void: SettingsWindow.open(self)),
			_before_btn]))
	# Справочник (0.12) — в любой момент боя, и кнопкой, и клавишей.
	var manual_btn := _compact_button("Manual", func() -> void: ManualWindow.toggle(self))
	manual_btn.tooltip_text = "Rules, tactics and unit cards (%s)" % Keybinds.label("game_manual")
	var bug_btn := _compact_button("Report a Bug", _open_bug_report)
	bug_btn.tooltip_text = "Send a bug report with a screenshot, the log and this match's replay."
	match_box.add_child(_button_row([manual_btn, bug_btn]))

	var panel_buttons := HBoxContainer.new()
	panel_buttons.position = Vector2(12, 8)
	panel_buttons.add_theme_constant_override("separation", 6)
	_ui_layer.add_child(panel_buttons)
	var tools_box := _hud_group(vbox, "Tools")
	_multi_btn = CheckBox.new()
	_multi_btn.text = "Multi-Select"
	_multi_btn.add_theme_font_size_override("font_size", 12)
	_multi_btn.toggled.connect(_on_multi_toggled)
	tools_box.add_child(_multi_btn)
	# Линейка (item 11) — зрительский инструмент, ничего не меняющий на доске.
	_ruler_btn = _compact_button("Ruler", _enter_ruler)
	tools_box.add_child(_ruler_btn)
	_height_btn = CheckBox.new()
	_height_btn.text = "Heightmap"
	_height_btn.tooltip_text = "Show the height of every cover tile (%s)" % Keybinds.label("game_heightmap")
	_height_btn.add_theme_font_size_override("font_size", 12)
	_height_btn.button_pressed = _heightmap
	_height_btn.toggled.connect(_toggle_heightmap)
	tools_box.add_child(_height_btn)
	_reveal_btn = CheckBox.new()
	_reveal_btn.text = "Show the whole board"
	_reveal_btn.tooltip_text = "The match is over: lift the fog of war and see everything."
	_reveal_btn.add_theme_font_size_override("font_size", 12)
	_reveal_btn.visible = false
	_reveal_btn.toggled.connect(func(on: bool) -> void:
		_reveal_board = on
		queue_redraw())
	tools_box.add_child(_reveal_btn)
	# Камера к своим (item 10): «Me» всегда, а в командной игре — и к каждому союзнику.
	tools_box.add_child(_camera_row())
	if _spectator: _build_spectator_controls(tools_box)
	# Темп ИИ (item 5): видно, если в партии есть ИИ или пришли налётчики (0.11.3: их
	# ход идёт с тем же темпом), а менять может хост (или игрок в одиночной партии) —
	# гостям скорость приходит от хоста. Строка строится всегда: налётчики появляются
	# посреди боя, и показывает её _refresh_ai_speed_row.
	if state != null and state.roster != null:
		var sp_row := HBoxContainer.new()
		_ai_speed_row = sp_row
		var sp_lbl := Label.new()
		sp_lbl.text = "AI speed"
		sp_lbl.add_theme_font_size_override("font_size", 11)
		sp_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp_row.add_child(sp_lbl)
		_ai_speed_opt = OptionButton.new()
		for sp: float in GameConfig.AI_SPEEDS:
			_ai_speed_opt.add_item(GameConfig.ai_speed_label(sp))
		_ai_speed_opt.select(maxi(0, GameConfig.AI_SPEEDS.find(GameConfig.ai_speed)))
		_ai_speed_opt.add_theme_font_size_override("font_size", 12)
		# Панель строится ДО подключения сети (_adopt_network) — роль берём из передачи лобби.
		_ai_speed_opt.disabled = NetHandoff.session != null and not NetHandoff.is_host
		_ai_speed_opt.tooltip_text = "How fast AI sides and raiders play. Only the host can change it."
		_ai_speed_opt.item_selected.connect(func(i: int) -> void:
			_set_ai_speed(GameConfig.AI_SPEEDS[i], true))
		sp_row.add_child(_ai_speed_opt)
		match_box.add_child(sp_row)
		_refresh_ai_speed_row()
	# Рисование и стирание (item 6/51) с размерами кистей.
	var draw_box := _floating_hud_panel("Drawing", panel_buttons, Vector2(12, 44))
	_draw_btn = _compact_button("Draw", _enter_draw)
	_erase_btn = _compact_button("Erase", _enter_erase)
	draw_box.add_child(_button_row([_draw_btn, _erase_btn]))
	draw_box.add_child(_colour_row())
	var undo_draw := _compact_button("Undo drawing", _undo_my_drawing)
	undo_draw.tooltip_text = "Take back your last stroke or erase (%s while drawing)." % Keybinds.label("game_undo")
	_undo_draw_shortcut_btn = undo_draw
	draw_box.add_child(undo_draw)
	var draw_lbl := Label.new()
	draw_lbl.text = "Draw brush"
	draw_lbl.add_theme_font_size_override("font_size", 11)
	draw_box.add_child(draw_lbl)
	var draw_slider := HSlider.new()
	draw_slider.min_value = 1
	draw_slider.max_value = 12
	draw_slider.step = 1
	draw_slider.value = _draw_brush
	draw_slider.value_changed.connect(func(v: float) -> void: _draw_brush = int(v))
	draw_box.add_child(_brush_row(draw_slider))
	var erase_lbl := Label.new()
	erase_lbl.text = "Erase brush"
	erase_lbl.add_theme_font_size_override("font_size", 11)
	draw_box.add_child(erase_lbl)
	var erase_slider := HSlider.new()
	erase_slider.min_value = 0
	erase_slider.max_value = 8
	erase_slider.step = 1
	erase_slider.value = _erase_brush
	erase_slider.value_changed.connect(func(v: float) -> void: _erase_brush = int(v))
	draw_box.add_child(_brush_row(erase_slider))
	# Кому видны штрихи и какие прятать (item 51, batch 17 item 10) — простые флажки.
	if _spectator:
		var scope_note := Label.new()
		scope_note.text = "Shared with spectators only"
		scope_note.add_theme_font_size_override("font_size", 12)
		draw_box.add_child(scope_note)
	else:
		draw_box.add_child(_draw_toggle("Share with team", func(on: bool) -> void: _draw_scope_team = on))
		draw_box.add_child(_draw_toggle("Share with everyone", func(on: bool) -> void: _draw_scope_all = on))
	draw_box.add_child(_draw_toggle("Hide others' drawings", func(on: bool) -> void: _hide_others_draw = on))
	draw_box.add_child(_draw_toggle("Hide my drawings", func(on: bool) -> void: _hide_my_draw = on))
	draw_box.add_child(_draw_toggle("Hide all drawings", func(on: bool) -> void: _hide_all_draw = on))

	# Убрано из правого меню по item 6 — обновляющие функции этих ссылок уже
	# null-безопасны. Журнал боя переехал в свою панель (снизу слева), чат остаётся
	# отдельной панелью (Enter), сохранение — по Ctrl+S; ИИ/сложность задаются в лобби.
	_info_label = null
	_init_label = null
	_p1_btn = null
	_p2_btn = null
	_net_status = null

	_build_log_panel()
	_build_component_panel()

	# Всплывающее меню действий и выбор числа выстрелов — в общем оконном стиле
	# SteamChrome (рамка + шапка), как остальной интерфейс. Тело красим один раз,
	# внутренняя начинка перестраивается в _scroll_menu при каждом открытии.
	_menu = PanelContainer.new()
	SteamChrome.apply_panel(_menu)
	_menu.hide()
	_ui_layer.add_child(_menu)

	_picker = PanelContainer.new()
	SteamChrome.apply_panel(_picker)
	_picker.hide()
	_clear_hint_cell()
	_ui_layer.add_child(_picker)

	_dice = DiceRoller.new()
	_ui_layer.add_child(_dice)

	_build_quit_dialog()
	_build_initiative_overlay()
	_build_chat_panel()
	if replay != null:
		_build_replay_bar()

## Раздел правого меню — групповое окошко набора с подписью на рамке; возвращает тело.
func _hud_group(parent: Container, title: String) -> VBoxContainer:
	var g := SteamChrome.group_box_compact(title)
	parent.add_child(g)
	g.body.add_theme_constant_override("separation", 5)
	return g.body

## Журнал боя (item 6) — своя панель внизу слева, а не строка в правом меню. Тот же
## _log_label, что и раньше, поэтому publish_result/_on_log_line работают без правок.
func _build_log_panel() -> void:
	var panel := PanelContainer.new()
	# Высоту в минимум НЕ пишем (issue 6): свёрнутая панель обязана ужаться до шапки,
	# а заданный минимум держал бы её прежней. Тело задаёт высоту само, пока открыто.
	panel.custom_minimum_size = Vector2(360, 0)
	SteamChrome.apply_panel(panel)
	# Полупрозрачный, как чат (item 18): self_modulate гасит только фон, не текст.
	panel.self_modulate = Color(1, 1, 1, PANEL_GLASS_ALPHA)
	_ui_layer.add_child(panel)
	_log_panel = panel
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	# Журнал сворачивается и разворачивается той же стрелкой, что и чат (issue 6).
	var log_toggle := Button.new()
	log_toggle.text = "▴"
	log_toggle.pressed.connect(_toggle_log)
	_log_toggle_btn = log_toggle
	var log_tools := HBoxContainer.new()
	log_tools.add_theme_constant_override("separation", 4)
	var log_header := SteamChrome.header_bar("Combat Log", log_tools)
	log_header.self_modulate = Color(1, 1, 1, PANEL_GLASS_ALPHA)  # item 18
	_make_panel_draggable(panel, log_header, func() -> void: _log_moved = true)  # item 8
	frame.add_child(log_header)
	_log_label = RichTextLabel.new()
	_log_label.custom_minimum_size = Vector2(360, 130)
	_style_panel_scroll(_log_label)
	# Размер — ручкой в шапке (item 18): вверх — выше, вправо — шире.
	log_tools.add_child(_resize_grip(panel, _log_label, 1.0, func() -> void: pass))
	log_tools.add_child(log_toggle)
	_log_label.add_theme_font_size_override("normal_font_size", 11)
	_log_label.scroll_following = true
	if state != null:
		_log_label.text = "\n".join(state.log.lines) + ("\n" if not state.log.lines.is_empty() else "")
	_log_body_wrap = SteamChrome.pad(_log_label, 8, 6)
	frame.add_child(_log_body_wrap)

## Чат в правом-нижнем углу (item 50): рамка SteamChrome с заголовком-переключателем,
## прокручиваемым журналом и строкой ввода. Позиция подгоняется в _reposition_hud_grip.
func _build_chat_panel() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 0)
	SteamChrome.apply_panel(panel)
	# Полупрозрачное окно чата (issue 5). Красим self_modulate, а не modulate: первый
	# гасит ТОЛЬКО фон самой панели, второй утянул бы за собой и текст с кнопками.
	panel.self_modulate = Color(1, 1, 1, PANEL_GLASS_ALPHA)
	_ui_layer.add_child(panel)
	_chat_panel = panel
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	var toggle := Button.new()
	toggle.text = "▾"
	toggle.pressed.connect(_toggle_chat)
	_chat_toggle_btn = toggle
	var chat_tools := HBoxContainer.new()
	chat_tools.add_theme_constant_override("separation", 4)
	var chat_header := SteamChrome.header_bar("Chat", chat_tools)
	chat_header.self_modulate = Color(1, 1, 1, PANEL_GLASS_ALPHA)  # issue 5
	_make_panel_draggable(panel, chat_header, func() -> void: _chat_moved = true)  # item 8
	frame.add_child(chat_header)
	_chat_body = VBoxContainer.new()
	_chat_body.add_theme_constant_override("separation", 4)
	# Сворачиваем ОБЁРТКУ-отступ, а не сам _chat_body (item 15): прятать только внутренний
	# VBox оставляло пустую padding-рамку, и окно не «уезжало» вниз — сжимается вся обёртка.
	_chat_body_wrap = SteamChrome.pad(_chat_body, 8, 8)
	_chat_body_wrap.visible = false
	frame.add_child(_chat_body_wrap)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.custom_minimum_size = Vector2(260, 120)
	_chat_log.add_theme_font_size_override("normal_font_size", 11)
	_chat_log.scroll_following = true
	_style_panel_scroll(_chat_log)
	_chat_body.add_child(_chat_log)
	# Размер — ручкой в шапке (item 18): вверх — выше, влево — шире (чат стоит у правого края).
	chat_tools.add_child(_resize_grip(panel, _chat_log, -1.0, func() -> void:
		if _chat_body_wrap != null and not _chat_body_wrap.visible:
			_set_panel_collapsed(_chat_panel, _chat_body_wrap, _chat_toggle_btn, false)))
	chat_tools.add_child(toggle)
	# Разговор из лобби и закупки (item 14) продолжается здесь. Отложенно: «(you)» в
	# подписи зависит от своей стороны, а её знает только подключённая сеть.
	_replay_chat_history.call_deferred()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_chat_body.add_child(row)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Message…"
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.text_submitted.connect(func(_t: String) -> void: _chat_send())
	row.add_child(_chat_input)
	var send := Button.new()
	send.text = "Send"
	send.pressed.connect(_chat_send)
	row.add_child(send)

## Модальное окно «выход в меню» в общем стиле (#51): затемнитель на весь экран
## и центрированная рамка SteamChrome с заголовком, текстом и кнопками.
func _build_quit_dialog() -> void:
	var overlay := Control.new()
	overlay.add_to_group("shortcut_modal")
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.hide()
	# Затемнение фона.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)
	# Центрирующий контейнер.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	# Рамка окна.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Quit to Main Menu"))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	frame.add_child(SteamChrome.pad(body, 16, 14))
	var msg := Label.new()
	msg.text = "Return to the main menu? Current game progress will be lost."
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size = Vector2(320, 0)
	body.add_child(msg)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(110, 34)
	cancel.pressed.connect(func() -> void: _quit_dialog.hide())
	row.add_child(cancel)
	var ok := Button.new()
	ok.text = "Main Menu"
	ok.custom_minimum_size = Vector2(110, 34)
	ok.pressed.connect(_to_menu)
	row.add_child(ok)
	_quit_dialog = overlay
	_ui_layer.add_child(_quit_dialog)

## Полный разбор инициативы по центру экрана (item 49): затемнитель + рамка со всеми
## слотами по порядку, цветами сторон, группировкой по командам, группами нейтралов и
## живым счётом каждого. Тело перезаполняется при каждом открытии из _refresh_initiative.
func _build_initiative_overlay() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.hide()
	var dim := ColorRect.new()
	# Полупрозрачный оверлей (item 6): доску за инициативой видно, но затемнение
	# ЗАМЕТНОЕ — чтобы игрок сразу понимал, что оверлей открыт и потому клики по полю
	# сейчас не проходят (item 17). Клик по фону закрывает, как и клавиша инициативы или Esc.
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			_init_overlay.hide())
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	SteamChrome.apply_panel(panel)
	panel.modulate = Color(1, 1, 1, 0.82)  # само окно инициативы — полупрозрачное (item 6)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	var close := Button.new()
	close.text = "✕"
	close.pressed.connect(func() -> void: _init_overlay.hide())
	frame.add_child(SteamChrome.header_bar("Initiative", close))
	_init_overlay_body = VBoxContainer.new()
	_init_overlay_body.add_theme_constant_override("separation", 6)
	# Прокрутка (playtest-20): групп жителей бывают десятки, и без неё список уходил за
	# край экрана — нижние строки, в том числе нейтралы, просто не было видно.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(_init_overlay_body)
	_init_overlay_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_init_overlay_scroll = scroll
	frame.add_child(SteamChrome.pad(scroll, 16, 14))
	_init_overlay = overlay
	_ui_layer.add_child(_init_overlay)

func _toggle_initiative_overlay() -> void:
	if _init_overlay == null:
		return
	if _init_overlay.visible:
		_init_overlay.hide()
	else:
		_refresh_initiative_overlay()
		_init_overlay.show()

## Свод по каждому владельцу-слоту (item 20, переделан в item 1):
## owner -> {alive, dead, veh, veh_dead}.
##
## ЖИВЫЕ считаются по доске, ПАВШИЕ — из state.deaths, а не по трупам на поле. Трупы
## выбывают из партии (поднял щитом, сложил в кучу, задвинул под кресло), и счёт
## «мёртвых» по ним полз назад — отсюда и шли прыгающие числа.
## Пленный (HELD) — живой: он ранен не больше, чем до захвата, и вернётся в строй.
## Дрон не в своде вовсе: ни бойцом, ни машиной — это расходная техника станции.
func _army_counts() -> Dictionary:
	var out: Dictionary = {}
	var tm := state.turns
	for u: UnitInstance in state.all_units():
		if u.is_drone or u.status == MCF.Status.CORPSE:
			continue
		var key := tm.slot_of(u)
		var rec: Dictionary = out.get(key, _EMPTY_COUNT.duplicate())
		rec["alive"] += 1
		out[key] = rec
	for owner: Variant in state.deaths:
		var rec: Dictionary = out.get(int(owner), _EMPTY_COUNT.duplicate())
		rec["dead"] = int(state.deaths[owner])
		out[int(owner)] = rec
	# Holdout: each wave with its own slot counts its own fallen (arrivals minus survivors);
	# the plain waves slot keeps only what no wave slot claims.
	if tm.wave_owner >= 0 and resolver != null and resolver.mode != null:
		var claimed := 0
		for k: Variant in resolver.mode.wave_sizes:
			var ws := MCF.wave_slot(int(k))
			if ws < 0 or not tm.round_order.has(ws):
				continue
			var rec: Dictionary = out.get(ws, _EMPTY_COUNT.duplicate())
			rec["dead"] = maxi(0, int(resolver.mode.wave_sizes[k]) - int(rec["alive"]))
			claimed += int(rec["dead"])
			out[ws] = rec
		var plain: Dictionary = out.get(tm.wave_owner, _EMPTY_COUNT.duplicate())
		plain["dead"] = maxi(0, int(plain["dead"]) - claimed)
		out[tm.wave_owner] = plain
	for v: Vehicle in state.all_vehicles():
		var rec: Dictionary = out.get(v.owner, _EMPTY_COUNT.duplicate())
		if v.alive():
			rec["veh"] += 1
		else:
			rec["veh_dead"] += 1
		out[v.owner] = rec
	return out

func _count_str(counts: Dictionary, owner: int) -> String:
	var rec: Dictionary = counts.get(owner, _EMPTY_COUNT)
	var s := "%d alive / %d dead" % [rec["alive"], rec["dead"]]
	if int(rec["veh"]) + int(rec["veh_dead"]) > 0:
		s += "   ·   %d vehicles / %d destroyed" % [rec["veh"], rec["veh_dead"]]
	return s

## Компактная сводка для боковой панели (item 20): текущий ход и команда, номер раунда,
## кто ходит непосредственно до и после ПРОСМАТРИВАЮЩЕГО игрока.
func _refresh_initiative() -> void:
	if _init_label == null or state == null:
		return
	var me := _viewing_side()
	var tm := state.turns
	var lines: Array[String] = []
	var cur := "[b]Turn:[/b] %s" % _side_label(_turn_now())
	if state.roster != null and state.roster.has_teams():
		var t := state.roster.team_of(tm.active_player())
		if t >= 0:
			cur += "  (%s)" % MCF.team_name(t)
	lines.append(cur)
	lines.append("[b]Round:[/b] %d" % tm.round_number)
	var prev := tm.neighbor_slot(me, -1, state.all_units())
	var nxt := tm.neighbor_slot(me, 1, state.all_units())
	if prev >= 0:
		lines.append("Before you: %s" % _side_label(prev))
	if nxt >= 0:
		lines.append("After you: %s" % _side_label(nxt))
	# Живой счёт по каждому слоту очереди (item 20) — компактно, полный разбор в оверлее.
	var counts := _army_counts()
	for slot: int in tm.round_order:
		var rec: Dictionary = counts.get(slot, _EMPTY_COUNT)
		# Живые / павшие (item 1) — раньше здесь стояло «живые/всего», и две строки одного
		# окна считали по-разному. Машины приписываются сзади, только если они есть.
		var line := "%s: %d live, %d dead" % [_side_label(slot), rec["alive"], rec["dead"]]
		if int(rec["veh"]) + int(rec["veh_dead"]) > 0:
			line += " (%d veh, %d wrecked)" % [rec["veh"], rec["veh_dead"]]
		lines.append(line)
	_init_label.text = "\n".join(lines)

## Полный разбор инициативы для оверлея (item 49): каждый слот по порядку со своим цветом,
## живым счётом и пометкой активного/выбитого; игроки сгруппированы по командам, если те есть.
func _refresh_initiative_overlay() -> void:
	if _init_overlay_body == null or state == null:
		return
	for c in _init_overlay_body.get_children():
		_init_overlay_body.remove_child(c)   # сразу из дерева: высота ниже — по новым строкам
		c.queue_free()
	var counts := _army_counts()
	var tm := state.turns
	for slot: int in tm.round_order:
		var rec: Dictionary = counts.get(slot, _EMPTY_COUNT)
		# Слот, в котором НИКОГО НЕ БЫЛО (ни живых, ни павших), в очереди не показываем
		# (item 2). Берётся он так: общий нейтральный слот («Neutral», без номера) держит
		# спящих жителей, но стоит кварталу проснуться — §15 переводит весь кластер в
		# СОБСТВЕННЫЙ слот группы (Neutral I, II, …), и исходный остаётся пустой
		# навсегда. Из очереди он не вычёркивается намеренно — по ней читается история
		# партии, — но показывать «Neutral — 0 alive / 0 dead» в каждом раунде незачем.
		# Слот с павшими (все жители погибли) — другое дело: это уже история, она остаётся.
		if int(rec["alive"]) == 0 and int(rec["dead"]) == 0 and int(rec["veh"]) == 0:
			continue
		# Вырезанная группа жителей больше не ходит (end_turn её пропускает) — в списке ей
		# не место (playtest-20): иначе десятки мёртвых групп вытесняли живые.
		if MCF.is_npc_side(slot) and int(rec["alive"]) == 0:
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		# «Сейчас ходит» — либо активный слот очереди, либо нейтральная группа, чей ход
		# отыгрывается прямо сейчас (item 6). Правило одно на всех: игрок, общий слот
		# мирных и любая их группа помечаются одинаково.
		var active: bool = slot == _turn_now()
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.color = _side_color(slot)
		row.add_child(swatch)
		var name_txt := _side_label(slot)
		if state.roster != null and state.roster.has_teams() and MCF.is_player(slot):
			var t := state.roster.team_of(slot)
			if t >= 0:
				name_txt += " · %s" % MCF.team_name(t)
		var lbl := Label.new()
		lbl.text = "%s — %s" % [name_txt, _count_str(counts, slot)]
		# Чей ход ИДЁТ ПРЯМО СЕЙЧАС — стрелка и зелёный (item 5). Правило одно на всех:
		# слот мирных и слот активированной группы жителей помечаются ровно так же, как
		# игрок, — по очереди ходят и они, и по ней же игрок сверяется, чей сейчас ход.
		if active:
			lbl.text = "▶ " + lbl.text
			lbl.add_theme_color_override("font_color", TURN_ACTIVE_COLOR)
		if tm.is_eliminated(slot):
			lbl.text += "  (eliminated)"
			lbl.modulate = Color(1, 1, 1, 0.45)
		row.add_child(lbl)
		_init_overlay_body.add_child(row)
	# Высота по содержимому, но не выше экрана — дальше прокрутка.
	if _init_overlay_scroll != null:
		_init_overlay_scroll.custom_minimum_size = Vector2(388, minf(
				_init_overlay_body.get_combined_minimum_size().y, get_viewport_rect().size.y - 140.0))

# --- Чат (item 50) ---

func _toggle_chat() -> void:
	if _chat_body_wrap == null:
		return
	# Стрелка вниз (▾) = свёрнуто, остаётся одна шапка; вверх (▴) = развёрнуто.
	_set_panel_collapsed(_chat_panel, _chat_body_wrap, _chat_toggle_btn,
			_chat_body_wrap.visible)

## Свернуть/развернуть журнал боя (issue 6) — ровно тем же способом, что и чат.
func _toggle_log() -> void:
	if _log_body_wrap == null:
		return
	_set_panel_collapsed(_log_panel, _log_body_wrap, _log_toggle_btn,
			_log_body_wrap.visible)

## Свернуть (collapsed) или раскрыть панель с шапкой.
##
## Спрятать одно тело НЕДОСТАТОЧНО (issue 5: «chat still isn't closeable, just make that
## entire gray rectangle completely disappear»). Панель здесь — верхнеуровневый Control
## на CanvasLayer, а такой узел свой размер сам не уменьшает: минимальный размер упал,
## но size остался прежним, и на месте свёрнутого чата продолжал висеть тот же серый
## прямоугольник. reset_size() возвращает панели её МИНИМАЛЬНЫЙ размер — от свёрнутого
## окна остаётся одна шапка со стрелкой.
##
## Вызов отложенный: тело спрятано только что, и контейнер пересчитает свой минимум
## лишь к концу кадра — reset_size() здесь же взял бы ещё старое значение.
func _set_panel_collapsed(panel: Control, body: Control, btn: Button,
		collapsed: bool) -> void:
	if panel == null or body == null:
		return
	body.visible = not collapsed
	if btn != null:
		btn.text = "▾" if collapsed else "▴"
	panel.call_deferred("reset_size")
	# Панель приколота к нижнему краю — после смены высоты её надо переставить,
	# иначе свёрнутая шапка уедет от угла на высоту прежнего тела.
	call_deferred("_reposition_hud_grip")

## Ручка размера панели (item 18): тянешь вверх — панель выше, в сторону grow_x (1 — вправо,
## −1 — влево) — шире. Нижняя кромка стоит на месте: панели живут у нижнего края экрана,
## и расти им некуда, кроме как вверх. Меняется минимальный размер тела (body), панель
## подстраивается под него.
func _resize_grip(panel: Control, body: Control, grow_x: float, on_start: Callable) -> Control:
	return PanelInteraction.resize_grip(panel, body, grow_x, on_start)

## Полоса прокрутки журнала и чата (item 19): прокрутка включена, а ширину полосе даёт
## тема (UiTheme: поля стиля полосы), так что её можно взять мышью и тащить.
func _style_panel_scroll(rtl: RichTextLabel) -> void:
	rtl.scroll_active = true

## Сделать панель перетаскиваемой за её шапку (item 8). on_move помечает панель как
## сдвинутую вручную, чтобы _reposition_hud_grip перестал возвращать её в угол.
func _make_panel_draggable(panel: Control, header: Control, on_move: Callable) -> void:
	PanelInteraction.draggable(panel, header, on_move)

func _chat_append(who: String, text: String) -> void:
	if _chat_log == null:
		return
	_chat_log.append_text("[b]%s:[/b] %s\n" % [ChatBox.escape(who), ChatBox.escape(text)])
	# Пришло сообщение — чат разворачивается сам, вместе со стрелкой и размером панели.
	if _chat_body_wrap != null and not _chat_body_wrap.visible:
		_set_panel_collapsed(_chat_panel, _chat_body_wrap, _chat_toggle_btn, false)

func _chat_send() -> void:
	if _chat_input == null:
		return
	var text := _chat_input.text.strip_edges()
	if text == "":
		return
	_chat_input.text = ""
	var side := _draw_author()
	NetHandoff.chat_history.append({"side": side, "text": text})
	_chat_append(_side_label(side), text)
	if networked and session != null:
		session.send({"k": K_CHAT, "side": side, "text": text})

## Чёрный крест «здесь смерть» (#1) — предупреждение на горящей клетке в разливе.
func _draw_black_cross(origin: Vector2, size: float, alpha: float = 0.95) -> void:
	var m := size * 0.22
	var a := origin + Vector2(m, m)
	var b := origin + Vector2(size - m, size - m)
	var c := origin + Vector2(size - m, m)
	var d := origin + Vector2(m, size - m)
	var w := maxf(2.0, size * 0.11)
	draw_line(a, b, Color(0, 0, 0, alpha), w)
	draw_line(c, d, Color(0, 0, 0, alpha), w)

func _hsep() -> HSeparator:
	return HSeparator.new()

## Сменить темп ИИ (item 5). broadcast — сменил сам (хост или одиночная игра), а не пришло
## от хоста по сети.
func _set_ai_speed(v: float, broadcast: bool) -> void:
	GameConfig.ai_speed = v if GameConfig.AI_SPEEDS.has(v) else 1.0
	if _ai_speed_opt != null:
		_ai_speed_opt.select(maxi(0, GameConfig.AI_SPEEDS.find(GameConfig.ai_speed)))
	if broadcast and networked and session != null and net != null and net.is_host:
		session.send({"k": K_AI_SPEED, "v": GameConfig.ai_speed})

func _neutral_camera_targets() -> Dictionary:
	var targets := {}
	if state == null or resolver == null: return targets
	var limited := _view_resolver().visibility_limited()
	var visible := _visible_before_impact(_viewing_side()) if limited else {}
	for u: UnitInstance in state.all_units():
		if not MCF.is_neutral(u.owner) or not u.civilian_active or not u.is_on_field() or not _on_board(u): continue
		if limited and not visible.has(u.coord): continue
		if not targets.has(u.owner): targets[u.owner] = []
		targets[u.owner].append(u.coord)
	return targets

func _refresh_neutral_camera() -> void:
	if _neutral_camera_row == null: return
	var sides := _neutral_camera_targets().keys()
	sides.sort()
	_neutral_camera_row.visible = not sides.is_empty()
	if sides == _neutral_camera_sides: return
	_neutral_camera_sides = sides
	for child in _neutral_camera_buttons.get_children():
		_neutral_camera_buttons.remove_child(child)
		child.queue_free()
	for side: int in sides:
		var button := Button.new()
		button.text = MCF.roman(MCF.neutral_group_index(side)) if side >= MCF.NEUTRAL_GROUP_BASE else "N"
		button.tooltip_text = "Center on visible forces of " + MCF.owner_name(side)
		button.custom_minimum_size = Vector2(40, 40)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func() -> void:
			# Recheck visibility when clicked, including during movement animations.
			if _neutral_camera_targets().has(side): _center_on_side(side))
		_neutral_camera_buttons.add_child(button)

func _camera_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var lbl := Label.new()
	lbl.text = "Camera"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var me := NetHandoff.my_side_hint(state.roster if state != null else null)
	var sides: Array[int] = []
	# Все стороны — машины (batch ui-drones): зритель свой у всех, камера ездит к любой
	# армии, как к союзнику.
	var all_ai := false
	if state != null and state.roster != null:
		all_ai = not state.roster.player_ids().is_empty()
		for sid: int in state.roster.player_ids():
			if not state.roster.is_ai(sid):
				all_ai = false
		for sid: int in state.roster.player_ids():
			if _spectator or all_ai or sid == me or (state.roster.has_teams() and me >= 0 and state.roster.are_allies(me, sid)):
				sides.append(sid)
	if all_ai:
		me = -1
	if sides.is_empty():
		sides.append(me if me >= 0 else 0)
	# Кнопки переносятся на новую строку: при восьми армиях ряд не влез бы в панель.
	var flow := GridContainer.new()
	flow.columns = 3
	flow.size_flags_horizontal = Control.SIZE_SHRINK_END
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	row.add_child(flow)
	for sid in sides:
		var b := Button.new()
		b.text = "Me" if sid == me else MCF.PLAYER_LETTERS[sid]
		b.tooltip_text = "Center the camera on %s" % ("your forces" if sid == me
				else state.roster.name_of(sid) + "'s forces")
		b.add_theme_font_size_override("font_size", 12)
		b.custom_minimum_size = Vector2(40, 40)
		# Not clipped (fix-7 #15): "Me" was cut down to "M" in a 40 px button.
		b.focus_mode = Control.FOCUS_NONE
		var side := sid
		b.pressed.connect(func() -> void: _center_on_side(side))
		flow.add_child(b)
	var group := VBoxContainer.new()
	group.add_child(row)
	_neutral_camera_row = HBoxContainer.new()
	var neutral_label := Label.new()
	neutral_label.text = "Neutral camera"
	neutral_label.add_theme_font_size_override("font_size", 11)
	neutral_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_neutral_camera_row.add_child(neutral_label)
	_neutral_camera_buttons = GridContainer.new()
	_neutral_camera_buttons.columns = 3
	_neutral_camera_row.add_child(_neutral_camera_buttons)
	group.add_child(_neutral_camera_row)
	_refresh_neutral_camera()
	# Raiders and Holdout waves (playtest 2026-10-19): their own rows, apart from the
	# players, with a button per army or wave you can see (all of them without fog).
	for kind: String in ["raiders", "waves"]:
		var frow := HBoxContainer.new()
		var flabel := Label.new()
		flabel.text = "Raider camera" if kind == "raiders" else "Wave camera"
		flabel.add_theme_font_size_override("font_size", 11)
		flabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		frow.add_child(flabel)
		var fgrid := GridContainer.new()
		fgrid.columns = 3
		frow.add_child(fgrid)
		group.add_child(frow)
		_force_rows[kind] = [frow, fgrid, []]
	_refresh_force_cameras()
	return group

## Visible raider armies (key: their slot) or Holdout waves (key: wave number) -> cells.
func _force_camera_targets(waves: bool) -> Dictionary:
	var targets := {}
	if state == null or resolver == null: return targets
	var limited := _view_resolver().visibility_limited()
	var visible := _visible_before_impact(_viewing_side()) if limited else {}
	var md := resolver.mode
	for u: UnitInstance in state.all_units():
		if not u.is_on_field() or u.is_drone or not _on_board(u): continue
		var key := -1
		if waves:
			if md != null and md.is_holdout() and u.owner == md.wave_side and u.neutral_group > 0:
				key = u.neutral_group
		elif MCF.is_independent(u.owner):
			key = u.owner
		if key < 0 or (limited and not visible.has(u.coord)): continue
		if not targets.has(key): targets[key] = []
		targets[key].append(u.coord)
	return targets

func _refresh_force_cameras() -> void:
	for kind: String in _force_rows:
		var rec: Array = _force_rows[kind]
		var waves := kind == "waves"
		var keys := _force_camera_targets(waves).keys()
		keys.sort()
		(rec[0] as Control).visible = not keys.is_empty()
		if keys == rec[2]: continue
		rec[2] = keys
		var grid_box: GridContainer = rec[1]
		for child in grid_box.get_children():
			grid_box.remove_child(child)
			child.queue_free()
		for key: int in keys:
			var n: int = key if waves else key - MCF.INDEPENDENT_BASE + 1
			var button := Button.new()
			button.text = MCF.roman(n)
			button.tooltip_text = ("Center on Wave %s" if waves else "Center on raider army %s") % MCF.roman(n)
			button.custom_minimum_size = Vector2(40, 40)
			button.focus_mode = Control.FOCUS_NONE
			button.pressed.connect(func() -> void:
				# Recheck when clicked: they may have moved out of sight since.
				var cells: Array = _force_camera_targets(waves).get(key, [])
				if not cells.is_empty(): _center_on_cells(cells))
			grid_box.add_child(button)

func _compact_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 26)
	b.add_theme_font_size_override("font_size", 12)
	# clip_text здесь стоять НЕ должно: с ним кнопка не учитывает ширину надписи в
	# своём минимальном размере, и в узкой панели (#54) от «AI Difficulty: Normal»
	# оставалось две буквы. Пусть лучше панель раздвинется, чем текст исчезнет.
	b.clip_text = false
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(handler)
	return b

## Ряд кнопок в одну строку — вдвое экономит высоту панели (#54).
func _button_row(buttons: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for b: Button in buttons:
		row.add_child(b)
	return row

## Оборачивает вертикальное меню в ScrollContainer с ограничением высоты по экрану,
## чтобы длинные меню не уходили за край и прокручивались.
## Строит начинку всплывающего меню в оконном стиле SteamChrome: шапка с
## заголовком + прокручиваемый столбец кнопок с отступами. Возвращает VBox для
## кнопок. Вызывающий сперва очищает детей панели — рамка пересобирается заново.
## back (0.12.2) — «‹» в левом верхнем углу шапки: у меню постройки инженера это отдельная
## кнопка возврата, а не ещё один пункт списка (владелец, item 49).
## The Drawing panel. Its own toolbar button opens and closes it (no × of its own).
func _floating_hud_panel(title: String, buttons: HBoxContainer, at: Vector2) -> VBoxContainer:
	var panel := PanelContainer.new()
	SteamChrome.apply_panel(panel)
	panel.position = at
	panel.size = Vector2(264, 380)
	panel.visible = false
	_ui_layer.add_child(panel)
	_draw_panel = panel
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar(title, null))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(scroll)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := SteamChrome.pad(body, 8, 6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)
	var button := _compact_button(title, func() -> void: panel.visible = not panel.visible)
	buttons.add_child(button)
	return body

func _toggle_p2_ai() -> void:
	if _animating or networked:
		return
	p2_is_ai = not p2_is_ai
	_set_side_ai(MCF.Owner.PLAYER_2, p2_is_ai)
	_deselect()
	_make_side(MCF.Owner.PLAYER_2)
	_refresh_ai_buttons()
	_refresh_pause_button()
	_kick_if_ai()

## Тот же переключатель для первого игрока (#103) — так бой ИИ против ИИ включается прямо
## посреди партии, не выходя в меню.
func _toggle_p1_ai() -> void:
	if _animating or networked:
		return
	p1_is_ai = not p1_is_ai
	_set_side_ai(MCF.Owner.PLAYER_1, p1_is_ai)
	_deselect()
	_make_side(MCF.Owner.PLAYER_1)
	_refresh_ai_buttons()
	_refresh_pause_button()
	queue_redraw()
	_kick_if_ai()

## Записать «эта сторона — машина» в ростер. Кнопки хот-сита на двоих остаются
## кнопками на двоих, но единственным источником правды стал ростер.
func _set_side_ai(side: int, value: bool) -> void:
	if replay != null:
		return
	var slot := state.roster.slot(side)
	if slot != null:
		slot.kind = Roster.SlotKind.AI if value else Roster.SlotKind.HUMAN


func _refresh_ai_buttons() -> void:
	if _p1_btn != null:
		_p1_btn.text = "Player 1: %s" % ("AI" if p1_is_ai else "Human")
	if _p2_btn != null:
		_p2_btn.text = "Player 2: %s" % ("AI" if p2_is_ai else "Human")

func _refresh_undo_btn() -> void:
	if _undo_btn == null:
		return
	var mine := _my_turn()
	_undo_btn.disabled = not mine or (not resolver.can_undo() and (mode != Mode.BUILD_WALL or _wall_cells.is_empty()))
	if _redo_btn != null:
		_redo_btn.disabled = not mine or not resolver.can_redo()

## Имя стороны на экране. В сетевой партии стороны зовутся Player A (хост) и
## Player B (присоединившийся), а своя помечается «(you)» (#93).
func _side_label(side: int) -> String:
	if MCF.is_neutral(side) or MCF.is_wave_slot(side):
		return MCF.owner_name(side)
	var base := state.roster.name_of(side)
	if state.turns.is_eliminated(side):
		base += " (out)"
	if networked and side == my_owner:
		base += " (you)"
	return base

## Порядок инициативы именами из ростера: у волн Holdout — «Waves», у сетевых игроков —
## их имена. Одинаков на всех пирах (ростер общий), поэтому годится и для журнала.
func _initiative_names() -> String:
	var parts: Array[String] = []
	for s: int in state.turns.round_order:
		parts.append(MCF.owner_name(s) if MCF.is_wave_slot(s) else state.roster.name_of(s))
	return " → ".join(parts)

func _order_labels() -> String:
	if not networked:
		return _initiative_names()
	var parts: Array[String] = []
	for s in state.turns.round_order:
		parts.append(_side_label(s))
	return " → ".join(parts)

## Обновить обе строки часов. Текст пересобирается каждый кадр, а в Label уходит только
## когда ИЗМЕНИЛСЯ: секунда меняется раз в шестьдесят кадров, а перерисовка подписи не
## бесплатна.
func _refresh_clocks() -> void:
	if _clock_label == null or state == null:
		return
	var now: int = _real_stop_ms if _real_stop_ms >= 0 else Time.get_ticks_msec()
	# Строки собираем, только когда сменилась показанная секунда или раунд (perf pass #3):
	# иначе три новые строки на каждый кадр ради надписи, что меняется раз в секунду.
	var key := Vector2i(state.turns.round_number, maxi(0, now - _real_start_ms) / 1000)
	if key == _clock_key:
		return
	_clock_key = key
	var text := "In-game %s   |   Real %s" % [
			_clock_text(key.x * IN_GAME_SECONDS_PER_ROUND), _clock_text(key.y)]
	if text != _clock_shown:
		_clock_shown = text
		_clock_label.text = text

## Секунды в «м:сс», а за час — в «ч:мм:сс».
static func _clock_text(total_seconds: int) -> String:
	var t: int = maxi(0, total_seconds)
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]

func _refresh_status() -> void:
	_refresh_neutral_camera()
	_refresh_force_cameras()
	if _reveal_btn != null:
		_reveal_btn.visible = _match_over and not _spectator and resolver != null and resolver.fog_enabled
	# Пауза (item 4) появляется и исчезает вместе с составом стола: сторону может взять
	# человек, и наоборот. Дешевле сверять её здесь, на каждом обновлении строки хода,
	# чем помнить про кнопку в каждой точке, где меняется ростер.
	_refresh_pause_button()
	_refresh_ai_speed_row()
	if _status_label != null:
		_status_label.text = "Turn: %s   |   Round: %d" % [
			_side_label(_turn_now()), state.turns.round_number]
		if _audio != null and not _match_over and not _audio_victory_played:
			_audio.turn(state.turns.round_number, state.turns.active_index, _turn_now())
		# Пыльная буря (0.12) — на виду, пока дует: она меняет каждый дальний выстрел.
		if resolver != null and resolver.random_events != null and resolver.random_events.dust_left > 0:
			_status_label.text += "   |   Dust storm: %d round(s)" % resolver.random_events.dust_left
	# Кто ходит до и после игрока (item 6) — отдельной строкой под текущим ходом.
	if _turn_neighbors_label != null and state != null:
		var me := _turn_now()
		var prev := state.turns.neighbor_slot(me, -1, state.all_units())
		var nxt := state.turns.neighbor_slot(me, 1, state.all_units())
		var parts: Array[String] = []
		if prev >= 0:
			parts.append("Prev: %s" % _side_label(prev))
		if nxt >= 0:
			parts.append("Next: %s" % _side_label(nxt))
		_turn_neighbors_label.text = "   ".join(parts)
	_refresh_clocks()
	_refresh_objective()
	_refresh_initiative()
	if _init_overlay != null and _init_overlay.visible:
		_refresh_initiative_overlay()
	_refresh_undo_btn()

## Чей ход ИДЁТ сейчас: пока отыгрывается группа жителей — она, иначе активный слот.
## Одно правило для строки хода и для окна инициативы (playtest-20: они расходились).
func _turn_now() -> int:
	return _playing_slot if _playing_slot != -1 else state.turns.active_slot()

func _refresh_info() -> void:
	if _info_label == null:
		return
	var u := _selected_unit()
	if u == null:
		_info_label.text = "%d units selected." % _group_ids.size() if not _group_ids.is_empty() \
			else "Click to select a unit."
		return
	var range_text := "∞" if is_inf(u.fire_range()) else (
		"—" if u.fire_range() <= 0 else str(int(u.fire_range())))
	var bonus := ""
	if u.stats.target_defense_penalty > 0:
		bonus = "  (−%d to target defense)" % u.stats.target_defense_penalty
	if Furniture.is_furniture(u.held_item_id):
		bonus += "  — carrying a %s" % Furniture.name_of(u.held_item_id).to_lower()
	_info_label.text = "%s - range %s, RoF %d, armor %d+, speed %d%s" % [
		u.stats.display_name, range_text,
		u.rate_of_fire(), u.armor(), u.speed(), bonus,
	]

func _draw_heights(font: Font, visible: Dictionary, fog_on: bool, x0: int, y0: int, x1: int, y1: int) -> void:
	var grid := _shown_grid if _shown_grid != null else state.grid
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var cell := grid.cell_fast(x, y)
			var t := TerrainTiles.height_text(cell.cover_height, cell.is_space, cell.feature_id)
			# A tank hull stands 2 m tall like a wall (playtest 2026-10-19).
			var hull := cell.vehicle_id != -1 and state.get_vehicle(cell.vehicle_id) != null \
					and state.get_vehicle(cell.vehicle_id).type_id == "tank"
			if hull:
				t = TerrainTiles.height_text(MCF.WALL_HEIGHT, false, "")
			if t == "" or (fog_on and not visible.has(cell.coord)):
				continue
			TerrainTiles.draw_height_text(self, font, _cell_origin(cell.coord), CELL, t,
					hull or (cell.cover_height >= MCF.WALL_HEIGHT and not Furniture.is_furniture(cell.feature_id)))
