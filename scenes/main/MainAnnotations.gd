@abstract
extends "res://scenes/main/MainDrawing.gd"

## Drawing on the board and the ruler (item 51).

# --- Аннотации на поле (item 51) ---

## Чей это рисунок: в сетевой партии — мой слот, в локальной — активная сторона.
func _draw_author() -> int:
	if _spectator and session != null: return -100 - session.my_peer_id()
	return my_owner if networked else _viewing_side()

## Линейка (item 11): «measure distances» — включается и выключается своей кнопкой,
## как рисование. Юнит при этом снимается с выделения: мерить обычно нужно ДО того, как
## решишь, кем ходить, и открытое меню действий только мешало бы кликать по полю.
func _enter_ruler() -> void:
	if mode == Mode.RULER:
		_exit_ruler()
		return
	_deselect()
	mode = Mode.RULER
	_ruler_a = Vector2i(-1, -1)
	_rulers.clear()
	_ruler_hover = _pos_to_cell(get_viewport().get_mouse_position())
	_refresh_ruler_button()
	queue_redraw()

func _exit_ruler() -> void:
	mode = Mode.NONE
	_ruler_a = Vector2i(-1, -1)
	_rulers.clear()
	_refresh_ruler_button()
	queue_redraw()

func _draw_toggle(text: String, on_toggle: Callable) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.add_theme_font_size_override("font_size", 12)
	cb.toggled.connect(func(on: bool) -> void:
		on_toggle.call(on)
		queue_redraw())
	return cb

## Область видимости нового штриха: «для всех» сильнее «для команды».
func _draw_scope() -> int:
	if _spectator: return DrawScope.ALL
	if _draw_scope_all:
		return DrawScope.ALL
	return DrawScope.TEAM if _draw_scope_team else DrawScope.SELF

func _refresh_ruler_button() -> void:
	if _ruler_btn != null:
		if mode != Mode.RULER:
			_ruler_btn.text = "Ruler"
		else:
			_ruler_btn.text = "Ruler: on (%d)" % _rulers.size() if not _rulers.is_empty() else "Ruler: on"
		_ruler_btn.tooltip_text = "Click two cells to measure; every ruler stays until you leave. " \
				+ "Backspace removes the last one, Esc or this button clears them all."

func _enter_draw() -> void:
	# Повторное нажатие ВЫКЛЮЧАЕТ рисование (item 14): режим теперь снимается кнопкой,
	# а не только Esc — раньше выйти из «рисования» было нечем.
	if mode == Mode.DRAW:
		mode = Mode.NONE
		_stroke_drawing = false
		_cur_stroke = []
		queue_redraw()
		return
	_deselect()
	mode = Mode.DRAW
	queue_redraw()

## Ластик (item 6): режим стирания СВОИХ штрихов кистью заданного радиуса.
func _enter_erase() -> void:
	if mode == Mode.ERASE:  # повторное нажатие выключает (item 14)
		mode = Mode.NONE
		_stroke_drawing = false
		queue_redraw()
		return
	_deselect()
	mode = Mode.ERASE
	queue_redraw()

## Ластик (item 15): стирает пиксели СВОИХ рисунков там, где прошёл, — как в Paint. Ход
## ластика уходит по сети при отпускании, и у остальных стирается то же самое (раньше
## стирание было только у себя, и чужие экраны держали стёртое до конца партии).
func _erase_at(pos: Vector2) -> void:
	var last: Vector2 = _cur_stroke[-1] if not _cur_stroke.is_empty() else pos
	_erase_segment(_draw_author(), last, pos, _erase_radius())
	if _cur_stroke.is_empty() or last.distance_to(pos) >= 2.0:
		_cur_stroke.append(pos)
	queue_redraw()

func _erase_segment(author: int, a: Vector2, b: Vector2, r: float) -> void:
	for key: Vector2i in _canvases:
		if key.x == author:
			(_canvases[key] as DrawCanvas).stroke(a, b, r, Color(0, 0, 0, 0))

func _erase_commit() -> void:
	if _cur_stroke.is_empty():
		return
	if networked and session != null:
		session.send({"k": K_DRAW, "a": _draw_author(), "e": true, "c": _flat_points(_cur_stroke),
			"r": _erase_radius()})
	_cur_stroke = []

## Радиус ластика в пикселях поля: базовый + шаг за деление ползунка.
func _erase_radius() -> float:
	return (float(_erase_brush) + 1.0) * (CELL * 0.35)

func _brush_colour() -> Color:
	return _side_color(_draw_author()) if _draw_colour.a <= 0.0 else _draw_colour

## Ряд образцов цвета кисти (issues-12 #8). Щелчок по образцу выбирает цвет и сразу
## включает кисть.
func _colour_row() -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 3)
	row.add_theme_constant_override("v_separation", 3)
	var group := ButtonGroup.new()
	for col: Color in DRAW_COLOURS:
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(18, 18)
		b.tooltip_text = "Your side's color" if col.a <= 0.0 else "Draw in this color"
		for st: String in ["normal", "hover", "pressed", "hover_pressed"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.5, 0.5, 0.5) if col.a <= 0.0 else col
			var on := st.ends_with("pressed")
			sb.set_border_width_all(2 if on else 1)
			sb.border_color = Color.WHITE if on else Color(0, 0, 0, 0.7)
			b.add_theme_stylebox_override(st, sb)
		b.button_pressed = col == _draw_colour
		b.pressed.connect(func() -> void:
			_draw_colour = col
			if mode != Mode.DRAW:
				_enter_draw())
		if col.a <= 0.0:
			_side_swatch = b
		row.add_child(b)
	return row

## Радиус кисти: ползунок задаёт толщину линии, как и раньше.
static func _paint_radius(width: int) -> float:
	return maxf(1.5, float(width) * 0.5)

func _canvas(author: int, scope: int) -> DrawCanvas:
	var key := Vector2i(author, scope)
	if not _canvases.has(key):
		_canvases[key] = DrawCanvas.new()
	return _canvases[key]

static func _flat_points(pts: Array) -> Array:
	var flat: Array = []
	for c: Vector2 in pts:
		flat.append(c.x)
		flat.append(c.y)
	return flat

## Позиция курсора в ПРОСТРАНСТВЕ ОТРИСОВКИ поля (item 14): рисунок свободный, не по
## клеткам, поэтому храним пиксельные точки в той же системе, что и _cell_origin().
func _draw_world_pos() -> Vector2:
	return (get_viewport().get_mouse_position() - pan) / zoom

## Свободный штрих (item 14): кисть рисует сразу, по мере движения мыши (item 15), а точки
## копятся для рассылки — заметный сдвиг, чтобы массив не пух от микродёрганий.
func _stroke_add(pos: Vector2) -> void:
	if not _cur_stroke.is_empty() and (_cur_stroke[-1] as Vector2).distance_to(pos) < 2.0:
		return
	var last: Vector2 = _cur_stroke[-1] if not _cur_stroke.is_empty() else pos
	var me := _draw_author()
	_canvas(me, _draw_scope()).stroke(last, pos, _paint_radius(_draw_brush), _brush_colour())
	_cur_stroke.append(pos)
	queue_redraw()

func _stroke_commit() -> void:
	if _cur_stroke.is_empty():
		return
	if networked and session != null:
		var msg := {"k": K_DRAW, "a": _draw_author(), "s": _draw_scope(),
			"c": _flat_points(_cur_stroke), "w": _draw_brush}
		if _draw_colour.a > 0.0:
			msg["col"] = _draw_colour.to_html(false)
		session.send(msg)
	_cur_stroke = []

## Пришедший чужой штрих, ход ластика или «очистить свои» (item 51/15). Область видимости
## уважаем при показе — «для себя» до нас не доходит вовсе (автор его и не шлёт).
func _on_remote_stroke(msg: Dictionary) -> void:
	var from := int(msg.get("_from", -1))
	if from >= 0 and session != null:
		if session.spectators.has(from):
			if not _spectator: return
			msg["a"] = -100 - from
			msg["s"] = DrawScope.ALL
		elif int(msg.get("a", -1)) != state.roster.side_of_peer(from):
			return
	var author := int(msg.get("a", -1))
	if bool(msg.get("clear", false)):
		_drop_drawings_of(author)
		return
	if bool(msg.get("undo", false)):
		_undo_drawing_of(author)
		return
	var flat: Array = msg.get("c", [])
	var pts: Array[Vector2] = []
	var i := 0
	while i + 1 < flat.size():
		pts.append(Vector2(float(flat[i]), float(flat[i + 1])))
		i += 2
	if pts.is_empty():
		return
	if bool(msg.get("e", false)):
		var r := float(msg.get("r", CELL * 0.35))
		_draw_record_begin(author, -1)
		for k in pts.size():
			_erase_segment(author, pts[maxi(0, k - 1)], pts[k], r)
		_draw_record_end(author)
	else:
		var scope := int(msg.get("s", DrawScope.TEAM))
		var canvas := _canvas(author, scope)
		var rad := _paint_radius(int(msg.get("w", 3)))
		var col := Color.html(str(msg["col"])) if Color.html_is_valid(str(msg.get("col", ""))) \
				else _side_color(author)
		_draw_record_begin(author, scope)
		for k in pts.size():
			canvas.stroke(pts[maxi(0, k - 1)], pts[k], rad, col)
		_draw_record_end(author)
	queue_redraw()

## Начать запись отката: штрих пишет один холст (scope), ластик — все холсты автора (-1).
func _draw_record_begin(author: int, scope: int) -> void:
	_draw_rec_keys = []
	if scope >= 0:
		_canvas(author, scope)
	for key: Vector2i in _canvases:
		if key.x == author and (scope < 0 or key.y == scope):
			(_canvases[key] as DrawCanvas).begin_record()
			_draw_rec_keys.append(key)

func _draw_record_end(author: int) -> void:
	var op := {}
	for key: Vector2i in _draw_rec_keys:
		if _canvases.has(key):
			var rec := (_canvases[key] as DrawCanvas).end_record()
			if not rec.is_empty():
				op[key] = rec
	_draw_rec_keys = []
	if op.is_empty():
		return
	var hist: Array = _draw_history.get(author, [])
	hist.append(op)
	if hist.size() > DRAW_UNDO_DEPTH:
		hist.pop_front()
	_draw_history[author] = hist

## Снять последнее своё действие кистью или ластиком — у себя и у всех в сети.
func _undo_my_drawing() -> void:
	var me := _draw_author()
	if not _undo_drawing_of(me):
		return
	if networked and session != null:
		session.send({"k": K_DRAW, "a": me, "undo": true})

func _undo_drawing_of(author: int) -> bool:
	var hist: Array = _draw_history.get(author, [])
	if hist.is_empty():
		return false
	var op: Dictionary = hist.pop_back()
	for key: Vector2i in op:
		_canvas(key.x, key.y).restore(op[key])
	queue_redraw()
	return true

## Видит ли просматривающий игрок этот штрих (item 51): свои — всегда; «для команды» —
## союзникам; «для всех» — всем; фильтры «скрыть свои/чужие/все» (batch 17, item 10).
## Сторона, которую ведёт ИИ, «своих» штрихов не имеет: в горячем кресле зритель — активная
## сторона, и после ухода игрока его рисунки всплывали бы на ходу ИИ (item 11).
func _stroke_visible_to_viewer(rec: Dictionary) -> bool:
	if int(rec["author"]) <= -100:
		return _spectator and not _hide_all_draw and (not _hide_my_draw if int(rec["author"]) == _draw_author() else not _hide_others_draw)
	if _hide_all_draw:
		return false
	var viewer := _viewing_side()
	var author: int = rec["author"]
	if author == viewer and not _side_is_ai(author):
		return not _hide_my_draw
	if _hide_others_draw:
		return false
	var scope := int(rec["scope"])
	if scope == DrawScope.ALL:
		return true
	if scope == DrawScope.TEAM and state.roster != null \
			and state.roster.are_allies(author, viewer):
		return true
	return false

## Ушедший игрок уносит свои рисунки (batch 17, item 11): они и были подсказками для
## него и его команды, а на ходу подменившего его ИИ всплывали у всех.
func _drop_drawings_of(side: int) -> void:
	for key: Vector2i in _canvases.keys():
		if key.x == side:
			_canvases.erase(key)
	_draw_history.erase(side)   # стёртое целиком назад не откатывается
	queue_redraw()

func _clear_my_drawings() -> void:
	var me := _draw_author()
	_drop_drawings_of(me)
	if networked and session != null:
		session.send({"k": K_DRAW, "a": me, "clear": true})

## Нарисовать все видимые штрихи как ломаные по центрам клеток (item 51).
## Линейка на поле (item 11): отрезок между концами, кружки на концах и число клеток
## посередине. Число — это Combat.distance, то самое, по которому считается попадание:
## по диагонали «две клетки» и «две клетки наискось» равны, и линейка обязана показывать
## именно так, иначе игрок мерил бы одно, а правила считали другое.
##
## Второй конец, пока он не закреплён, берётся из-под курсора — расстояние тянется за
## мышью, и прикинуть дистанцию можно не кликая вовсе.
func _draw_ruler() -> void:
	if mode != Mode.RULER:
		return
	for seg: Array in _rulers:
		_draw_ruler_segment(seg[0], seg[1], Color(1.0, 0.86, 0.25))
	# Недотянутая линейка — за курсором, чуть светлее закреплённых.
	if _ruler_a != Vector2i(-1, -1) and state.grid.in_bounds(_ruler_hover):
		_draw_ruler_segment(_ruler_a, _ruler_hover, Color(1.0, 0.95, 0.6))

func _draw_ruler_segment(a: Vector2i, b: Vector2i, col: Color) -> void:
	var pa := _cell_origin(a) + Vector2(CELL, CELL) * 0.5
	var pb := _cell_origin(b) + Vector2(CELL, CELL) * 0.5
	draw_line(pa, pb, Color(0, 0, 0, 0.55), 5.0)
	draw_line(pa, pb, col, 2.0)
	draw_arc(pa, CELL * 0.28, 0.0, TAU, 20, col, 2.0)
	draw_arc(pb, CELL * 0.28, 0.0, TAU, 20, col, 2.0)
	var dist := Combat.distance(a, b)
	var label := "%d" % dist if dist == 1 else "%d cells" % dist
	var font := ThemeDB.fallback_font
	var mid := (pa + pb) * 0.5
	var size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
	# Подложка под числом: над светлым полом жёлтая надпись иначе теряется.
	draw_rect(Rect2(mid + Vector2(-size.x * 0.5 - 4, -14), size + Vector2(8, 6)),
			Color(0, 0, 0, 0.7))
	draw_string(font, mid + Vector2(-size.x * 0.5, 0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)

func _draw_annotation_layer() -> void:
	if state == null or _before_on: return
	_annotations.draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	_draw_annotations(_annotations)

func _draw_annotations(ci: CanvasItem) -> void:
	var view := Rect2(-pan / zoom, get_viewport_rect().size / zoom)
	for key: Vector2i in _canvases:
		if _stroke_visible_to_viewer({"author": key.x, "scope": key.y}):
			(_canvases[key] as DrawCanvas).draw(ci, view)
	# Кружок кисти/ластика под курсором — видно, какой толщины след ляжет (item 15).
	if mode == Mode.DRAW or mode == Mode.ERASE:
		var r := _paint_radius(_draw_brush) if mode == Mode.DRAW else _erase_radius()
		var col := _brush_colour() if mode == Mode.DRAW else Color(1, 1, 1, 0.8)
		ci.draw_arc(_draw_world_pos(), r, 0.0, TAU, 32, col, 1.5)
	# Образец «цвет стороны» следует за автором: в горячем кресле он меняется с ходом, а в
	# сети сторона известна лишь после подключения — позже, чем строится панель.
	if _side_swatch != null:
		var sc := _side_color(_draw_author())
		for st: String in ["normal", "hover", "pressed", "hover_pressed"]:
			var sb := _side_swatch.get_theme_stylebox(st) as StyleBoxFlat
			if sb != null and sb.bg_color != sc:
				sb.bg_color = sc
