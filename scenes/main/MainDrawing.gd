@abstract
extends "res://scenes/main/MainFogMemory.gd"

## Drawing the battle: the board, units, vehicles, effects, previews, gas, objectives.

## Слой «было»: рельеф стартовой доски плитками и стартовые места поверх. Слой — дочерний
## узел над самим экраном боя, поэтому закрывает и бойцов, и следы, и туман.
func _draw_before(ci: Node2D) -> void:
	var g := _before_grid
	if g == null or _before_tiles == null:
		return
	ci.position = pan
	ci.scale = Vector2(zoom, zoom)
	var vp := get_viewport_rect().size
	var x0 := clampi(floori((-pan.x / zoom - ORIGIN.x) / CELL), 0, g.width - 1)
	var y0 := clampi(floori((-pan.y / zoom - ORIGIN.y) / CELL), 0, g.height - 1)
	var x1 := clampi(ceili(((vp.x - pan.x) / zoom - ORIGIN.x) / CELL), 0, g.width - 1)
	var y1 := clampi(ceili(((vp.y - pan.y) / zoom - ORIGIN.y) / CELL), 0, g.height - 1)
	var res := TerrainTiles.prepare(ci, float(CELL))
	_before_tiles.draw(ci, ORIGIN, float(CELL), x0, y0, x1, y1, false, res)
	TerrainTiles.draw_grid(ci, ORIGIN, float(CELL), x0, y0, x1, y1, Ui.grid_color(), 1.0 / zoom)
	_before_tiles.draw(ci, ORIGIN, float(CELL), x0, y0, x1, y1, true, res)
	# Туман (0.11.3): на «было» та же завеса, что и в бою, — открыто только то, что видно
	# сейчас (обычный туман — серая вуаль, реалистичный — чернота). Текстура та же, что у
	# дальнего плана: её держит в согласии с обзором _lod_sync на каждом кадре боя.
	var viewer := _viewing_side()
	if _view_resolver().fog_enabled and _lod != null and _lod.fog != null:
		ci.draw_texture_rect(_lod.fog, Rect2(ORIGIN, Vector2(g.width, g.height) * CELL), false)
	# Картинки бойцов и машин — в системе самого слоя (у него уже pan и zoom).
	Sprites.set_base_transform(Vector2.ZERO, Vector2.ONE)
	var font := ThemeDB.fallback_font
	for v: Array in _before_vehicles:
		if not _before_known(int(v[1]), Vehicle.footprint_at(v[2], v[3]), viewer):
			continue
		var org := ORIGIN + Vector2(v[2]) * CELL
		var vsize := Vector2(v[3]) * CELL
		var col := _side_color(int(v[1]))
		var key := Sprites.resolve(String(v[0]))
		if key == "" or not Sprites.draw_texture_override_rect(ci, key, Rect2(org, vsize), _facing_degrees(v[4])):
			ci.draw_rect(Rect2(org + Vector2(3, 3), vsize - Vector2(6, 6)), col.darkened(0.35))
		ci.draw_rect(Rect2(org + Vector2(2, 2), vsize - Vector2(4, 4)), col, false, 2.0)
		ci.draw_string(font, org + Vector2(8, 18), String(VehicleDB.get_vehicle(String(v[0])).get("name", v[0])),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _ink(col.darkened(0.35)))
	# Units exactly as the battle draws them (0.11): faction sprite, or the side-coloured
	# disc with its outline and role tag — no extra ring.
	var details := zoom >= UNIT_DETAIL_ZOOM
	for u: Array in _before_units:
		if not _before_known(int(u[1]), [u[2]], viewer):
			continue
		var unit: UnitInstance = u[3]
		var o := ORIGIN + Vector2(u[2]) * CELL
		var c := o + Vector2(CELL, CELL) * 0.5
		var skey := _sprite_key(unit)
		if skey == "" or not Sprites.draw_texture_override(ci, skey, o, CELL):
			var col := _side_color(int(u[1]))
			ci.draw_circle(c, CELL * 0.34, col)
			if details:
				ci.draw_arc(c, CELL * 0.34, 0, TAU, 20, col.darkened(0.45), 1.5)
				_tag_line(unit).draw(ci.get_canvas_item(), c + Vector2(-9, 5 - 16 * 0.8), _ink(col))
	Sprites.set_base_transform(pan, Vector2(zoom, zoom))

## Клетка, на которой юнит рисуется ПРЯМО СЕЙЧАС: обычно его настоящая координата,
## а во время проигрывания перехода — промежуточная клетка маршрута.
func _draw_cell(unit: UnitInstance) -> Vector2i:
	return _walk_cells.get(unit.id, unit.coord)

## Сколько точек ОД показать сейчас: обычно настоящий остаток, а во время чужой
## анимации — то, что уже отыграно (#99).
func _draw_ap(unit: UnitInstance) -> int:
	return int(_ap_display.get(unit.id, unit.remaining_ap))

## Зона клетки: 0 — зелёная (1 ОД), 1 — оранжевая, 2 — красная.
func _move_tier(spent: int) -> int:
	return GameActionResolver.tier_of(_reach_tiers, spent)

func _draw_move_preview() -> void:
	var font := ThemeDB.fallback_font
	var cvec := Vector2(CELL, CELL)
	var half := cvec * 0.5
	var hover := _pos_to_cell(get_viewport().get_mouse_position())
	# Путь считаем ОДИН раз и держим множеством: подсветка маршрута идёт внутри общего
	# прохода по клеткам, а искать в массиве на каждую клетку — квадрат.
	var on_path: Dictionary = {}
	var path: Array[Vector2i] = []
	if reach.can_reach(hover):
		path = reach.path_to(hover)
		for p: Vector2i in path:
			on_path[p] = true
	var labels: bool = zoom >= MOVE_LABEL_MIN_ZOOM
	# Горящие клетки разлива помечаются чёрным крестом (#1): дойти до них можно, но
	# это смерть. Огнеупорному бойцу (#2) огонь не вредит — ему крестов не рисуем.
	var mark_fire: bool = GridCell.burning > 0 and not resolver.is_fireproof(_selected_unit())
	# Все три зоны рисуются одинаково (batch ui-drones 2): заливка, подпись «цена/потолок
	# зоны», контур по краю. Подпись в оранжевой — «9/12»: 12 клеток дают два ОД.
	for coord: Vector2i in reach.cost:
		var origin := _cell_origin(coord)
		var lit: bool = on_path.has(coord)
		var spent: int = reach.cost[coord]
		var k := _move_tier(spent)
		draw_rect(Rect2(origin, cvec), MOVE_TIER_COLS[k][1 if lit else 0])
		if mark_fire and state.grid.cell(coord).on_fire:
			# Наведённая клетка — крест в полную силу, остальные приглушены, иначе
			# пожар в полкарты забивает собой всю подсветку хода.
			_draw_black_cross(origin, float(CELL), 0.95 if lit else 0.5)
		# Контур зоны: сторона клетки, за которой соседа этой же или более близкой зоны нет.
		for d: Vector2i in GameActionResolver.DIR4:
			var n: Vector2i = coord + d
			if reach.cost.has(n) and _move_tier(reach.cost[n]) <= k:
				continue
			var a := origin + half + (Vector2(d) + Vector2(-d.y, d.x)) * half
			var b := origin + half + (Vector2(d) - Vector2(-d.y, d.x)) * half
			draw_line(a, b, MOVE_TIER_COLS[k][2], 2.0)
		if not labels:
			continue
		draw_string(font, origin + Vector2(4, 13), "%d/%d" % [spent, _reach_tiers[k]],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			Color(0.95, 1.0, 0.95) if lit else Color(0.92, 0.95, 0.9, 0.85))
	# Сам маршрут поверх заливки: ломаная от бойца через каждую клетку пути.
	if path.is_empty():
		return
	var u := _selected_unit()
	if u == null:
		return
	var hk := _move_tier(reach.cost[hover])
	var line_col: Color = MOVE_TIER_COLS[hk][3]
	var pts := PackedVector2Array()
	pts.append(_cell_origin(u.coord) + half)
	for p: Vector2i in path:
		pts.append(_cell_origin(p) + half)
	draw_polyline(pts, Color(0.05, 0.1, 0.05, 0.65), 5.0)
	draw_polyline(pts, line_col, 2.5)
	for i in range(1, pts.size()):
		draw_circle(pts[i], CELL * 0.09, line_col)
	# Финиш — кольцо и итоговая цена крупнее, её игрок и ищет глазами; за пределами
	# зелёной зоны — ещё и сколько ОД уйдёт на ход.
	var last: Vector2 = pts[pts.size() - 1]
	draw_arc(last, CELL * 0.36, 0.0, TAU, 24, line_col, 2.0)
	if labels:
		var txt := "%d/%d" % [reach.cost[hover], _reach_tiers[hk]]
		if hk > 0 or u.move_credit <= 0:
			txt += " · %d AP" % (hk + (0 if u.move_credit > 0 else 1))
		draw_string(font, last + Vector2(-CELL, -CELL * 0.42), txt,
			HORIZONTAL_ALIGNMENT_CENTER, CELL * 2, 13, Color(0.08, 0.08, 0.08))
		draw_string(font, last + Vector2(-CELL, -CELL * 0.45), txt,
			HORIZONTAL_ALIGNMENT_CENTER, CELL * 2, 13, line_col.lightened(0.3))

## Предпросмотр хода машины — как у пехоты (batch ui-drones 2): заливка по зоне,
## контур, подпись «цена/потолок зоны», а под курсором — линия от машины и сколько ОД уйдёт.
func _draw_veh_move_preview() -> void:
	var veh := _selected_vehicle()
	if veh == null or _veh_tiers.is_empty():
		return
	var costs: Dictionary = {}
	for c: Vector2i in veh_move_targets:
		costs[c] = int(veh_move_targets[c]["cost"])
	_draw_zone_preview(costs, _veh_tiers, veh.center(),
			0 if resolver.vehicle_move_credit(veh) > 0 else 1)
	var hover := _pos_to_cell(get_viewport().get_mouse_position())
	if veh_move_targets.has(hover):
		var move: Dictionary = veh_move_targets[hover]
		var origin: Vector2i = veh.origin + Vector2i(move["dir"]) * int(move["steps"])
		var rect := Rect2(_cell_origin(origin), Vector2(veh.size) * CELL)
		if not Sprites.draw_texture_override_rect(self, veh.type_id, rect,
				_facing_degrees(veh.facing), Color(1, 1, 1, 0.4)):
			draw_rect(rect, Color(_side_color(veh.owner), 0.3))
		draw_rect(rect, Color(0.65, 1.0, 0.7, 0.85), false, 2.0)

## Клетки зон хода: заливка по зоне (подсвеченная под курсором), контур по краю зоны и
## подпись клетки. Общая часть для техники, дрона и отряда.
## Маршрут полёта до наведённой клетки. Считается, только когда курсор или сам дрон
## сдвинулись: рисуется путь каждый кадр, а разлёт — это Дейкстра.
func _drone_path_to(dr: UnitInstance, hover: Vector2i) -> Array[Vector2i]:
	if dr == null:
		return [] as Array[Vector2i]
	if hover != _drone_path_for or dr.coord != _drone_path_from:
		_drone_path_for = hover
		_drone_path_from = dr.coord
		_drone_path = resolver.drone_route_to(dr, hover)
	return _drone_path

func _draw_cached_group_zone(zone: Dictionary) -> void:
	if not is_instance_valid(_group_zone_layer):
		_group_zone_layer = Node2D.new()
		_group_zone_layer.show_behind_parent = true
		add_child(_group_zone_layer)
		_group_zone_layer.draw.connect(func() -> void:
			if _group_preview != null and _group_preview.zone_ready:
				_draw_zone_cells(_group_preview.zone.tier, _group_preview.zone.label, {}, _group_zone_layer))
	_group_zone_layer.visible = not zone.tier.is_empty()
	_group_zone_layer.position = pan
	_group_zone_layer.scale = Vector2(zoom, zoom)
	var key := [_group_preview.get_instance_id() if _group_preview != null else 0, _group_preview.revision if _group_preview != null else -1,
		_pos_to_cell(Vector2.ZERO), _pos_to_cell(get_viewport_rect().size), zoom >= MOVE_LABEL_MIN_ZOOM]
	if key != _group_zone_draw_key:
		_group_zone_draw_key = key
		_group_zone_layer.queue_redraw()

func _draw_zone_cells(tier_at: Dictionary, label_at: Dictionary, on_path: Dictionary = {}, canvas: Node2D = null) -> void:
	var painter := self if canvas == null else canvas
	var font := ThemeDB.fallback_font
	var cvec := Vector2(CELL, CELL)
	var half := cvec * 0.5
	var hover := _pos_to_cell(get_viewport().get_mouse_position()) if canvas == null else Vector2i(-1, -1)
	var labels: bool = zoom >= MOVE_LABEL_MIN_ZOOM
	var top := _pos_to_cell(Vector2.ZERO) - Vector2i.ONE
	var bottom := _pos_to_cell(get_viewport_rect().size) + Vector2i.ONE
	for c: Vector2i in tier_at:
		if c.x < top.x or c.y < top.y or c.x > bottom.x or c.y > bottom.y: continue
		var origin := _cell_origin(c)
		var k: int = tier_at[c]
		painter.draw_rect(Rect2(origin, cvec), MOVE_TIER_COLS[k][1 if c == hover or on_path.has(c) else 0])
		for d: Vector2i in GameActionResolver.DIR4:
			if tier_at.has(c + d) and int(tier_at[c + d]) <= k:
				continue
			var a := origin + half + (Vector2(d) + Vector2(-d.y, d.x)) * half
			var b := origin + half + (Vector2(d) - Vector2(-d.y, d.x)) * half
			painter.draw_line(a, b, MOVE_TIER_COLS[k][2], 2.0)
		if labels and label_at.has(c):
			painter.draw_string(font, origin + Vector2(4, 13), label_at[c],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.92, 0.95, 0.9, 0.85))

## Зоны хода по цене клеток (техника, дрон): заливка по зоне (1/2/3 ОД — зелёная,
## оранжевая, красная), контур, подпись «цена/потолок зоны», а под курсором — линия от
## from_cell и сколько ОД уйдёт. ap_base — ОД за первую зону (0, если ход на остатке).
func _draw_zone_preview(costs: Dictionary, budgets: Array[int], from_cell: Vector2i,
		ap_base: int, path: Array[Vector2i] = [] as Array[Vector2i]) -> void:
	if budgets.is_empty():
		return
	var font := ThemeDB.fallback_font
	var cvec := Vector2(CELL, CELL)
	var half := cvec * 0.5
	var hover := _pos_to_cell(get_viewport().get_mouse_position())
	var labels: bool = zoom >= MOVE_LABEL_MIN_ZOOM
	var tier_at: Dictionary = {}
	var label_at: Dictionary = {}
	for c: Vector2i in costs:
		tier_at[c] = GameActionResolver.tier_of(budgets, int(costs[c]))
		label_at[c] = "%d/%d" % [int(costs[c]), budgets[int(tier_at[c])]]
	var on_path: Dictionary = {}
	for p: Vector2i in path:
		on_path[p] = true
	_draw_zone_cells(tier_at, label_at, on_path)
	if not costs.has(hover):
		return
	var hk: int = tier_at[hover]
	var col: Color = MOVE_TIER_COLS[hk][3]
	var from := _cell_origin(from_cell) + half
	var to := _cell_origin(hover) + half
	# Ломаная по НАСТОЯЩЕМУ маршруту, если он дан (дрон): прямая от дрона к курсору
	# показывала путь, которым он не полетит — он обходит корпуса, чужих дронов и
	# огонь. Техника линию не передаёт и остаётся с прямой: она и едет по прямой
	# (plan_line_move), так что прямая для неё — не упрощение, а правда.
	var pts := PackedVector2Array([from])
	for p: Vector2i in path:
		pts.append(_cell_origin(p) + half)
	if pts.size() < 2:
		pts = PackedVector2Array([from, to])
	# Тёмная обводка целиком, затем цвет: иначе обводка каждого звена ложилась бы
	# поверх соседнего и ломаная выходила бы пунктиром.
	for i in range(1, pts.size()):
		draw_line(pts[i - 1], pts[i], Color(0.05, 0.1, 0.05, 0.65), 5.0)
	for i in range(1, pts.size()):
		draw_line(pts[i - 1], pts[i], col, 2.5)
	draw_arc(to, CELL * 0.36, 0.0, TAU, 24, col, 2.0)
	if labels:
		var txt := "%d/%d · %d AP" % [int(costs[hover]), budgets[hk], hk + ap_base]
		draw_string(font, to + Vector2(-CELL, -CELL * 0.42), txt,
			HORIZONTAL_ALIGNMENT_CENTER, CELL * 2, 13, Color(0.08, 0.08, 0.08))
		draw_string(font, to + Vector2(-CELL, -CELL * 0.45), txt,
			HORIZONTAL_ALIGNMENT_CENTER, CELL * 2, 13, col.lightened(0.3))

## Подпись броска (как у целей-юнитов): жёлтая с обводкой, под курсором крупнее.
func _draw_need(pos: Vector2, txt: String, big: bool) -> void:
	var font := ThemeDB.fallback_font
	var fs := 16 if big else 12
	draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.9))
	draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.92, 0.5))

## Бросок над каждой вражеской машиной, корпус которой можно накрыть (клетки корпуса в
## item_cells): одна подпись над корпусом, по ближайшей доступной клетке. need_at(c) —
## сколько выбросить по клетке c (0 — без броска).
func _draw_vehicle_needs(owner: int, need_at: Callable) -> void:
	var hov := _pos_to_cell(get_viewport().get_mouse_position())
	for v: Vehicle in state.all_vehicles():
		if not v.alive() or v.owner == owner or state.roster.are_allies(owner, v.owner):
			continue
		var cells: Array = [v.origin] if v.is_borg() else v.footprint()
		var best := Vector2i(-1, -1)
		var lit := false
		for c: Vector2i in cells:
			if item_cells.has(c):
				lit = lit or c == hov
				if best == Vector2i(-1, -1) or c == v.center():
					best = c
		if best == Vector2i(-1, -1):
			continue
		var n: int = need_at.call(best)
		var top := _cell_origin(Vector2i(v.center().x, v.origin.y)) + Vector2(CELL * 0.3, -CELL * 0.08)
		_draw_need(top, "auto" if n <= 0 else ("%d+" % n if n <= 6 else "—"), lit)

## Клетки, которые накроет струя огнемёта из from к цели (для предпросмотра) — та же
## геометрия, что у выстрела, включая разлёт о стену (batch 17, item 5).
func _flame_jet_preview(from_coord: Vector2i, toward: Vector2i) -> Array:
	var d := toward - from_coord
	return resolver.flame_cells(from_coord, Vector2i(signi(d.x), signi(d.y)))

func _draw() -> void:
	if _annotations != null: _annotations.queue_redraw()
	if state == null:
		return
	if _before_on and _before_layer != null:
		_before_layer.queue_redraw()   # слой «было» идёт за панорамой и зумом
	# Панорама + масштаб «камеры»: всё поле рисуется в локальных координатах.
	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	# То же преобразование — слою замены спрайтов: повёрнутая картинка (танк по фронту,
	# осколки, лежащий труп) обязана вернуть холст в НАШУ панораму, а не в единицу.
	Sprites.set_base_transform(pan, Vector2(zoom, zoom))
	var font := ThemeDB.fallback_font
	# Множество видимых клеток нужно и дальше по функции (юниты, трупы, техника), поэтому
	# берётся всегда — резолвер отдаёт его из кеша, пока обстановка не изменилась.
	# А вот САМА заливка тумана при выключенном тумане не нужна ни на одной клетке:
	# флаг гасит 2500 лишних обращений к словарю за кадр.
	var fog_on: bool = _view_resolver().visibility_limited()
	var viewer := _viewing_side()
	var visible := _visible_before_impact(viewer)
	# Локальные копии полей и констант: тело цикла выполняется до 2500 раз за кадр,
	# и каждое обращение к свойству узла/автозагрузки там заметно.
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	# Полупрозрачная тёмная сетка читается на любой плитке — светлом бетоне и тёмной стали.
	var grid_col := Ui.grid_color()
	var label_off := Vector2(6, CELL - 4)
	# Отсечение по вьюпорту (item 5): на большой карте (город 50×50, бой 500×500) или
	# крупном зуме рисуем ТОЛЬКО клетки, попадающие на экран, а не всю сетку целиком —
	# это снимает основную нагрузку кадра. Границы с запасом в клетку.
	var _vp := get_viewport_rect().size
	var _tl := _pos_to_cell(Vector2.ZERO)
	var _br := _pos_to_cell(_vp)
	var vx0 := clampi(_tl.x - 1, 0, gw - 1)
	var vx1 := clampi(_br.x + 1, 0, gw - 1)
	var vy0 := clampi(_tl.y - 1, 0, gh - 1)
	var vy1 := clampi(_br.y + 1, 0, gh - 1)
	# Тот же диапазон членами — для функций отрисовки трупов и косметики (item 5).
	_cull_x0 = _tl.x - 1; _cull_x1 = _br.x + 1
	_cull_y0 = _tl.y - 1; _cull_y1 = _br.y + 1
	# Дальний план (большие карты): рельеф, объекты и туман — текстурами слоя под нами.
	var far := zoom < LOD_ZOOM
	_lod_sync(far, viewer, visible, fog_on)
	# Vacuum tiles are transparent. Covering the live board with the opening board
	# cannot hide debris there; stop drawing the live layers while Before is shown.
	if _before_on:
		return
	_draw_fx_flashes(visible)
	_draw_flame_jet(visible)
	# Труп существует в ДВУХ видах: погибший на месте боец — это occupant клетки со
	# статусом CORPSE, а положенный из рук (#6) — безымянная куча cell.corpse_count.
	# Кучи не рисовались вовсе: тело давало +1 к защите, но на карте его не было.
	# Реалистичный туман прячет вне обзора всё (issues-12 #16) — и тела тоже.
	var blackout: bool = fog_on and _view_resolver().fog_mode == MCF.Fog.REALISTIC
	# Обычный туман (0.11.3): тела — как их видел зритель. Упавший в темноте не виден,
	# пока туда не посмотрят; унесённый в темноте лежит, пока туда не посмотрят. Прежнее
	# правило playtest-20 «тела видны и под туманом» этим заменено.
	var corpses := _corpse_map()
	if fog_on and not blackout and _fog_mem_corpses.has(viewer):
		var cmem: Dictionary = _fog_mem_corpses[viewer]
		for c: Vector2i in corpses:
			if visible.has(c):
				cmem[c] = corpses[c]
		for c: Vector2i in cmem.keys():
			if visible.has(c) and not corpses.has(c):
				cmem.erase(c)
		corpses = cmem
	for c: Vector2i in corpses:
		if c.x < vx0 or c.x > vx1 or c.y < vy0 or c.y > vy1 or not _cell_on_screen(c.x, c.y) \
				or (blackout and not visible.has(c)):
			continue
		var e: Array = corpses[c]
		_draw_corpse(c, int(e[1]), e[0])

	if not far:
		# Пол, объекты, огонь и туман вблизи рисует слой под нами плитками (TerrainTiles,
		# _lod_sync): здесь остаются подписи высоты насыпей — у кучи земли она бывает
		# разной, и картинкой её не прочесть. Мелким шрифтом их не разглядеть на отъезде.
		if zoom >= HEIGHT_LABEL_ZOOM and not _heightmap:   # the heightmap labels them too
			for dc: Vector2i in _display_feature_cells(MCF.FEATURE_DIRT_PILE):
				if not _cell_on_screen(dc.x, dc.y):
					continue
				if fog_on and not visible.has(dc):
					continue
				var dh: float = _shown_grid.cell(dc).cover_height
				draw_string(font, _cell_origin(dc) + label_off, HEIGHT_LABELS.get(dh, "%.1fm" % dh),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.95, 0.85, 0.6))
		# Сетку рисует слой плиток (_lod) между полом и объектами — линиями по строкам и
		# столбцам видимых клеток. На дальнем отъезде линии сливаются в серую пелену — нет.
		_lod.grid_col = grid_col if zoom >= 0.3 else Color(0, 0, 0, 0)

	if mode == Mode.MOVE and reach != null:
		_draw_move_preview()

	# Групповое движение (#88): зелёным — куда группа вообще дотягивается, а под
	# курсором жёлтыми кружками — куда конкретно встанет каждый выделенный юнит.
	# Залп марксманов (item 12): лучи всех в сторону курсора — те же трассы, что у выстрела.
	if mode == Mode.GROUP_LASER:
		var vdir := _volley_dir(_pos_to_cell(get_viewport().get_mouse_position()))
		if vdir != Vector2i.ZERO:
			for mm: UnitInstance in _group_marksmen():
				_draw_laser_preview(mm, mm.coord + vdir)

	if mode == Mode.GROUP_MOVE:
		# Как у одиночного бойца (batch group-zones): зелёная/оранжевая/красная зоны с
		# контуром и ценой клетки; под курсором — путь каждого бойца в цвет его зоны,
		# кружок места и сколько ОД он потратит.
		var gz: Dictionary = _group_preview.zone if _group_preview != null and _group_preview.zone_ready else {"tier": {}, "label": {}, "reach": {}}
		_draw_cached_group_zone(gz)
		var ghov := _pos_to_cell(get_viewport().get_mouse_position())
		if state.grid.in_bounds(ghov):
			draw_rect(Rect2(_cell_origin(ghov), Vector2(CELL, CELL)), Color(0.95, 0.85, 0.2, 0.20))
			var half := Vector2(CELL, CELL) * 0.5
			# Тактический приказ — голубые кружки, обычный — жёлтые.
			var dot := Color(0.35, 0.85, 1.0, 0.85) if _group_tactical else Color(1.0, 0.9, 0.25, 0.85)
			var plan: Array = _group_preview.plan() if _group_preview != null and _group_preview.target == ghov else [[], []]
			var reaches: Dictionary = gz["reach"]
			for i in plan[0].size():
				var gid: int = plan[0][i]
				var spot: Vector2i = plan[1][i]
				var gu := state.get_unit(gid)
				var c := _cell_origin(spot) + half
				if gu != null and reaches.has(gid):
					var tiers: Array[int] = reaches[gid][0]
					var rc: Movement.Reachability = reaches[gid][1]
					if rc.can_reach(spot):
						var k := GameActionResolver.tier_of(tiers, int(rc.cost[spot]))
						var col: Color = MOVE_TIER_COLS[k][3]
						var pts := PackedVector2Array([_cell_origin(gu.coord) + half])
						for p: Vector2i in rc.path_to(spot):
							pts.append(_cell_origin(p) + half)
						draw_polyline(pts, Color(0.05, 0.1, 0.05, 0.6), 4.0)
						draw_polyline(pts, col, 2.0)
						if zoom >= MOVE_LABEL_MIN_ZOOM:
							var ap_txt := "%d AP" % (k + (0 if gu.move_credit > 0 else 1))
							draw_string_outline(font, c + Vector2(-CELL * 0.5, -CELL * 0.28), ap_txt,
								HORIZONTAL_ALIGNMENT_CENTER, CELL, 11, 3, Color(0, 0, 0, 0.85))
							draw_string(font, c + Vector2(-CELL * 0.5, -CELL * 0.28), ap_txt,
								HORIZONTAL_ALIGNMENT_CENTER, CELL, 11, col.lightened(0.3))
				draw_circle(c, CELL * 0.18, dot)
				draw_arc(c, CELL * 0.18, 0.0, TAU, 16, dot.darkened(0.6), 1.5)

	if mode == Mode.SHOOT or mode == Mode.DPMG_FIRE:
		if mode == Mode.DPMG_FIRE and rsp_active != Vector2i(-1, -1):
			draw_rect(Rect2(_cell_origin(rsp_active), Vector2(CELL, CELL)), Color(1, 0.5, 0.2, 0.30))
		# Клетки пола под спецудар (противотанкист — взрыв, огнемётчик — струя).
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.9, 0.5, 0.1, 0.16))
		# Anti-tank (0.11): the roll to hit is written on EVERY cell it can blast, not only
		# the hovered one, so spots can be compared before the shell is spent.
		var at_unit := _selected_unit()
		if mode == Mode.SHOOT and at_unit != null and at_unit.attack_ability() == MCF.ABILITY_ANTI_TANK \
				and zoom >= MOVE_LABEL_MIN_ZOOM:
			var at_hover := _pos_to_cell(get_viewport().get_mouse_position())
			for coord in item_cells:
				if coord == at_hover or not _cell_on_screen(coord.x, coord.y):
					continue
				var an: int = resolver.aim_need(at_unit, coord)
				var at := "auto" if an <= 0 else ("%d+" % an if an <= 6 else "—")
				var ap := _cell_origin(coord) + Vector2(CELL * 0.08, CELL * 0.62)
				draw_string_outline(font, ap, at, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color(0, 0, 0, 0.85))
				draw_string(font, ap, at, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.92, 0.5, 0.9))
		# Соседние вражеские машины под удар шахтёра (item 15) — обводим их след.
		for mvid in _melee_veh_ids:
			var mveh: Vehicle = state.get_vehicle(mvid)
			if mveh != null:
				for fc: Vector2i in mveh.footprint():
					draw_rect(Rect2(_cell_origin(fc), Vector2(CELL, CELL)),
						Color(0.95, 0.55, 0.15, 0.28))
		var shov := _pos_to_cell(get_viewport().get_mouse_position())
		var su := _selected_unit()
		# Марксманн (#49): под курсором рисуем сам луч — куда он долетит и кого заденет.
		if mode == Mode.SHOOT and _is_marksman(su) and state.grid.in_bounds(shov):
			_draw_laser_preview(su, shov)
		if item_cells.has(shov) and su != null:
			if su.attack_ability() == MCF.ABILITY_FLAMETHROWER:
				# Предпросмотр струи 6×1 в направлении наведённой клетки.
				for jc in _flame_jet_preview(su.coord, shov):
					if state.grid.cell(jc).is_space:
						continue   # над космосом струя проходит, не поджигая (editor-rework)
					draw_rect(Rect2(_cell_origin(jc), Vector2(CELL, CELL)), Color(1, 0.4, 0.05, 0.34))
			elif su.attack_ability() == MCF.ABILITY_ANTI_TANK:
				# Предпросмотр радиуса взрыва (3x3) вокруг наведённой клетки.
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var bc := Vector2i(shov.x + dx, shov.y + dy)
						if state.grid.in_bounds(bc):
							draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(1, 0.35, 0.1, 0.32))
			# Бросок и для выстрела по клетке пола (окно, разрыв ПТ) — как у целей-юнитов.
			if mode == Mode.SHOOT and _unit_at(shov) == null:
				var cneed: int = resolver.aim_need(su, shov)
				var ctxt := "auto" if cneed <= 0 else ("%d+" % cneed if cneed <= 6 else "—")
				# Окно: бросает не стрелок, а стекло — его спасбросок против каждой пули.
				var gfid := state.grid.cell(shov).feature_id
				# Only an anti-tank shell skips the pane's "glass N+" (0.11.1, user rule): it does
				# not roll per bullet against the glass; everyone else sees the pane's save.
				if MCF.is_glass(gfid) and su.attack_ability() != MCF.ABILITY_ANTI_TANK:
					ctxt = "glass %d+" % MCF.glass_bullet_save(gfid)
				var ctp := _cell_origin(shov) + Vector2(CELL * 0.8, CELL * 0.2)
				draw_string_outline(font, ctp, ctxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color(0, 0, 0, 0.9))
				draw_string(font, ctp, ctxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 0.92, 0.5))
		# Сколько нужно выбросить на попадание — у каждой цели и у каждого стрелка.
		# У всех стрелков (batch soil-rulers): ПТ — свой бросок без укрытия, у лазера и
		# струи броска нет — «auto». Число берёт resolver.aim_need — то же, что бросит выстрел.
		var show_need: bool = mode == Mode.SHOOT and su != null
		for tid in target_ids:
			var t := state.get_unit(tid)
			if t != null:
				var c := _cell_origin(t.coord) + Vector2(CELL, CELL) * 0.5
				draw_arc(c, CELL * 0.46, 0, TAU, 28, Color(1, 0.3, 0.3), 2.5)
				draw_line(c - Vector2(CELL * 0.5, 0), c + Vector2(CELL * 0.5, 0), Color(1, 0.3, 0.3, 0.7), 1.5)
				draw_line(c - Vector2(0, CELL * 0.5), c + Vector2(0, CELL * 0.5), Color(1, 0.3, 0.3, 0.7), 1.5)
				if show_need:
					var need: int = resolver.aim_need(su, t.coord, t)
					var txt := "auto" if need <= 0 else ("%d+" % need if need <= 6 else "—")
					var big: bool = t.coord == shov
					var fs := 16 if big else 12
					var tp := c + Vector2(CELL * 0.3, -CELL * 0.3)
					draw_string_outline(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.9))
					draw_string(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.92, 0.5))
		# И над вражескими машинами, по которым этот стрелок может ударить (ПТ, лазер, струя).
		if show_need and not item_cells.is_empty():
			_draw_vehicle_needs(su.owner, func(c: Vector2i) -> int: return resolver.aim_need(su, c))

	if mode == Mode.GRAB:
		# Бойцы под захват — оранжевые круги; объекты (труп/мешки/ёж/куча) — жёлтые клетки,
		# после выбора объекта те же клетки показывают, куда его можно оттащить (#50).
		if drag_object == Vector2i(-1, -1):
			for tid in target_ids:
				var t := state.get_unit(tid)
				if t != null:
					var c := _cell_origin(t.coord) + Vector2(CELL, CELL) * 0.5
					draw_arc(c, CELL * 0.46, 0, TAU, 28, Color(1, 0.7, 0.2), 2.5)
		var grab_col := Color(0.9, 0.8, 0.2, 0.28) if drag_object == Vector2i(-1, -1) \
			else Color(0.3, 0.8, 0.4, 0.28)
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), grab_col)
		if drag_object != Vector2i(-1, -1):
			draw_rect(Rect2(_cell_origin(drag_object), Vector2(CELL, CELL)), Color(0.9, 0.8, 0.2, 0.40))

	if mode == Mode.PUSH:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.4, 0.7, 1.0, 0.28))
		for tid in target_ids:
			var t := state.get_unit(tid)
			if t != null:
				var c := _cell_origin(t.coord) + Vector2(CELL, CELL) * 0.5
				draw_arc(c, CELL * 0.46, 0, TAU, 28, Color(0.4, 0.7, 1.0), 2.5)

	if mode == Mode.ITEM:
		var hover := _pos_to_cell(get_viewport().get_mouse_position())
		var is_station: bool = _selected_unit() != null and _selected_unit().held_item_id == MCF.ITEM_DRONE_STATION
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.9, 0.5, 0.1, 0.16))
		# Станция дронов (batch ui-drones): под курсором — квадрат поводка, дальше
		# DRONE_LEASH клеток от станции её дрон не улетит.
		if is_station and item_cells.has(hover):
			var lr := MCF.DRONE_LEASH
			var tl := Vector2i(maxi(0, hover.x - lr), maxi(0, hover.y - lr))
			var br := Vector2i(mini(state.grid.width - 1, hover.x + lr), mini(state.grid.height - 1, hover.y + lr))
			var rect := Rect2(_cell_origin(tl), Vector2(br - tl + Vector2i.ONE) * CELL)
			draw_rect(rect, Color(0.38, 0.7, 0.85, 0.08))
			draw_rect(rect, Color(0.38, 0.7, 0.85, 0.85), false, 2.0)
			draw_string(ThemeDB.fallback_font, rect.position + Vector2(6, 16),
				"Drone range %d" % lr, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.85, 0.95))
		if item_cells.has(hover) and not is_station:
			# Предпросмотр зоны взрыва вокруг наведённой клетки (#64): у осколочной и
			# у пожаротушительной это «косой крест», а не квадрат 3×3. Форму берём у
			# резолвера, чтобы подсветка и сам взрыв не могли разойтись.
			var iu := _selected_unit()
			var iid: String = iu.held_item_id if iu != null else MCF.ITEM_FRAG
			for bc: Vector2i in resolver.blast_cells_for_item(iid, hover):
				if state.grid.in_bounds(bc):
					draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(1, 0.35, 0.1, 0.32))

	if mode == Mode.DRONE_FLY:
		# Как у пехоты и техники (batch soil-rulers): зелёная зона с контуром, цена клетки
		# «сколько/потолок», под курсором — линия от дрона и сколько ОД уйдёт.
		var dr := _selected_unit()
		if dr != null and dr.is_drone:
			var budgets: Array[int] = [_drone_budget]
			_draw_zone_preview(_drone_costs, budgets, dr.coord,
					0 if dr.move_credit > 0 else 1,
					_drone_path_to(dr, _pos_to_cell(get_viewport().get_mouse_position())))

	if mode == Mode.BUILD:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.3, 0.8, 0.4, 0.28))

	if mode == Mode.BUILD_WALL:
		# Уже выложенные звенья цепочки (сплошной зелёный) с номерами.
		for i in _wall_cells.size():
			var wc: Vector2i = _wall_cells[i]
			draw_rect(Rect2(_cell_origin(wc), Vector2(CELL, CELL)), Color(0.3, 0.85, 0.45, 0.55))
			draw_string(font, _cell_origin(wc) + Vector2(6, 16), str(i + 1),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.05, 0.15, 0.05))
		# Пока не выложено ни одного звена — подсвечиваем кольцо клеток у инженера
		# (единственная обязательная привязка). Дальше звенья ставятся куда угодно,
		# поэтому весь пол не красим — вместо этого показываем предпросмотр под курсором.
		if _wall_cells.size() < MCF.LDF_WALL_LENGTH:
			var hov := _pos_to_cell(get_viewport().get_mouse_position())
			if _wall_cells.is_empty():
				for coord in item_cells:
					if _wall_valid_next(coord):
						var col := Color(0.9, 0.85, 0.3, 0.35) if coord == hov else Color(0.3, 0.8, 0.4, 0.16)
						draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), col)
			# Предпросмотр клетки под курсором: зелёная — можно поставить, красная — нельзя.
			if state.grid.in_bounds(hov) and not _wall_cells.has(hov):
				var ok := _wall_valid_next(hov)
				draw_rect(Rect2(_cell_origin(hov), Vector2(CELL, CELL)),
					Color(0.3, 0.85, 0.45, 0.42) if ok else Color(0.9, 0.3, 0.2, 0.32))

	if mode == Mode.BREAK:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.9, 0.3, 0.2, 0.30))

	if mode == Mode.CARRY_FURN or mode == Mode.PUT_FURN:
		var fcol := Color(0.35, 0.6, 0.95, 0.32) if mode == Mode.CARRY_FURN else Color(0.4, 0.85, 0.5, 0.32)
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), fcol)

	if mode == Mode.MINE:
		var mhov := _pos_to_cell(get_viewport().get_mouse_position())
		# Противотанковые мины подсвечиваем синевой, противопехотные — оранжевым (item 13).
		var lay_col := Color(0.3, 0.55, 0.9, 0.28) if _mine_av else Color(0.85, 0.35, 0.15, 0.28)
		var lay_hi := Color(0.4, 0.65, 1.0, 0.5) if _mine_av else Color(0.95, 0.45, 0.2, 0.5)
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), lay_col)
		if item_cells.has(mhov):
			draw_rect(Rect2(_cell_origin(mhov), Vector2(CELL, CELL)), lay_hi)

	if mode == Mode.DISARM:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.3, 0.85, 0.5, 0.35))

	if mode == Mode.DIG:
		var dhov := _pos_to_cell(get_viewport().get_mouse_position())
		if dig_trench == Vector2i(-1, -1):
			# Шаг 1: клетки под окоп (коричневый).
			for coord in item_cells:
				draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.6, 0.45, 0.2, 0.32))
			if item_cells.has(dhov):
				draw_rect(Rect2(_cell_origin(dhov), Vector2(CELL, CELL)), Color(0.75, 0.55, 0.25, 0.5))
		else:
			# Шаги 2–3: выбранный окоп (тёмный) + места под кучи вынутой земли (песочный).
			draw_rect(Rect2(_cell_origin(dig_trench), Vector2(CELL, CELL)), Color(0.45, 0.32, 0.15, 0.55))
			for coord in item_cells:
				draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.85, 0.7, 0.35, 0.30))
			if dig_dirt_a != Vector2i(-1, -1):
				draw_rect(Rect2(_cell_origin(dig_dirt_a), Vector2(CELL, CELL)), Color(0.9, 0.75, 0.3, 0.55))
			if item_cells.has(dhov):
				draw_rect(Rect2(_cell_origin(dhov), Vector2(CELL, CELL)), Color(0.95, 0.8, 0.4, 0.5))

	if mode == Mode.CARRY_DROP:
		# Цель переноса (синий) и свободные клетки под пленника (голубой).
		if move_dest != Vector2i(-1, -1):
			draw_rect(Rect2(_cell_origin(move_dest), Vector2(CELL, CELL)), Color(0.3, 0.5, 0.9, 0.30))
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.4, 0.7, 1.0, 0.28))

	if mode == Mode.CORPSE_DROP:
		# Клетки под труп — в цвет самого трупа (#59), чтобы связь читалась сразу.
		var chov_c := _pos_to_cell(get_viewport().get_mouse_position())
		for coord: Vector2i in item_cells:
			var tint := Color(CORPSE_COLOR, 0.55) if coord == chov_c else Color(CORPSE_COLOR, 0.28)
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), tint)

	if mode == Mode.MOVE_HELD:
		# Куда можно переставить пленника (#100) — тот же голубой, что у сброса переноса.
		var mhov := _pos_to_cell(get_viewport().get_mouse_position())
		for coord: Vector2i in item_cells:
			var mt := Color(0.4, 0.7, 1.0, 0.55) if coord == mhov else Color(0.4, 0.7, 1.0, 0.28)
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), mt)

	if mode == Mode.WELD:
		# Шлюзы под заварку — в цвет сварочной дуги (#99).
		var whov := _pos_to_cell(get_viewport().get_mouse_position())
		for coord: Vector2i in item_cells:
			var wt := Color(1.0, 0.65, 0.2, 0.55) if coord == whov else Color(1.0, 0.65, 0.2, 0.28)
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), wt)

	if mode == Mode.VEH_MOVE:
		_draw_veh_move_preview()


	if mode == Mode.VEH_TURN:
		var vt := _selected_vehicle()
		if vt != null:
			var vc := _cell_origin(vt.center()) + Vector2(CELL, CELL) * 0.5
			draw_arc(vc, CELL * 1.1, 0, TAU, 40, Color(0.9, 0.8, 0.3, 0.6), 2.0)
			# Четыре стрелки = четыре стороны света (item 2): диагональных разворотов у
			# танка больше нет. Клик в любую клетку по лучу поворачивает корпус туда.
			var thov := _pos_to_cell(get_viewport().get_mouse_position())
			var thd := thov - vt.center()
			var thdir := _ortho_dir(thd)
			for d: Vector2i in GameActionResolver.DIR4:
				var v := Vector2(d).normalized()
				var col := Color(0.55, 0.5, 0.35, 0.7)
				if d == vt.facing:
					col = Color(0.4, 0.9, 0.5, 0.9)
				elif d == thdir:
					col = Color(1.0, 0.9, 0.35, 1.0)
				var tip := vc + v * (CELL * 1.7)
				draw_line(vc + v * (CELL * 1.15), tip, col, 2.0)
				var perp := Vector2(-v.y, v.x) * (CELL * 0.16)
				draw_colored_polygon(PackedVector2Array([
					tip, tip - v * (CELL * 0.3) + perp, tip - v * (CELL * 0.3) - perp]), col)

	if mode == Mode.VEH_CANNON:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(1, 0.4, 0.1, 0.18))
		var chov := _pos_to_cell(get_viewport().get_mouse_position())
		var cveh_sel := _selected_vehicle()
		if item_cells.has(chov) and cveh_sel != null:
			# Предпросмотр берём у резолвера — ромб радиуса 2 (#63), а не квадрат 3×3.
			for bc: Vector2i in resolver.cannon_blast_cells(cveh_sel, chov):
				if state.grid.in_bounds(bc):
					draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(1, 0.35, 0.1, 0.32))
		# Бросок пушки (batch group-zones) — как у пехоты: у каждого видимого врага в секторе
		# и крупно под курсором.
		if cveh_sel != null:
			for coord: Vector2i in item_cells:
				var occ := _unit_at(coord)
				if coord == chov or (occ != null and occ.owner != cveh_sel.owner):
					var cn: int = resolver.cannon_aim_need(cveh_sel, coord)
					_draw_need(_cell_origin(coord) + Vector2(CELL * 0.62, CELL * 0.22),
							"%d+" % cn if cn <= 6 else "—", coord == chov)
			# Над вражескими машинами — один бросок на корпус, а не по цифре на клетку.
			_draw_vehicle_needs(cveh_sel.owner, func(c: Vector2i) -> int:
				return resolver.cannon_aim_need(cveh_sel, c))

	if mode == Mode.VEH_DISEMBARK:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.4, 0.7, 1.0, 0.28))

	# Статические объекты вблизи — в плитках TerrainTiles. Поверх них здесь только то, что
	# у каждого своё или живёт мгновение: мины (видимость своя у каждой стороны, item 45),
	# снимок «до взрыва» на время броска (item 22) и трещина на побитом ДОТе (#89).
	if not far:
		var fcell_size := Vector2(CELL, CELL)
		# Станция дронов — только там, где игрок СЕЙЧАС видит (туман). Из плиток она
		# исключена ровно за этим: запечённая, она светила бы сквозь пелену и выдавала
		# чужого оператора вернее, чем он сам.
		for sc: Vector2i in _display_feature_cells(MCF.FEATURE_DRONE_STATION):
			# Станцию в кресле челнока рисует сам корпус (issues-12 #7).
			if _cell_on_screen(sc.x, sc.y) and _cell_seen_now(sc, visible) \
					and grid.cell_fast(sc.x, sc.y).vehicle_id == -1:
				_tiles.draw_feature_tile(self, MCF.FEATURE_DRONE_STATION, sc,
						Rect2(_cell_origin(sc), fcell_size))
		# Створка шлюза вне обзора — ЗАКРЫТА: открывшийся в темноте шлюз рассказывал о чужом
		# ходе ровно то, что туман и прячет. Рисуется поверх слоя плиток, поэтому и пелену
		# над ней кладём сами (обычный туман; в реалистичном клетку и так закрывает чёрное).
		if _view_resolver().visibility_limited() and _view_resolver().fog_mode == MCF.Fog.STANDARD:
			for ac: Vector2i in _display_feature_cells(MCF.FEATURE_AIRLOCK):
				if not _cell_on_screen(ac.x, ac.y) or visible.has(ac):
					continue
				var acell := _shown_grid.cell_fast(ac.x, ac.y)
				if acell.feature_id == MCF.FEATURE_AIRLOCK and not acell.is_wall():
					_tiles.draw_feature_tile(self, MCF.FEATURE_AIRLOCK, ac,
							Rect2(_cell_origin(ac), fcell_size), true)
					draw_rect(Rect2(_cell_origin(ac), fcell_size), FOG_COL)
		for mk: String in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE]:
			for mc: Vector2i in _display_feature_cells(mk):
				if _cell_on_screen(mc.x, mc.y) and resolver.mine_visible_to(viewer, mc):
					if not Sprites.draw_texture_override_rect(self, mk, Rect2(_cell_origin(mc), fcell_size)):
						draw_string(font, _cell_origin(mc) + Vector2(6, CELL - 15), FEATURE_TAGS[mk],
							HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.9, 0.3, 0.25))
		# Побитый ДОТ трескается в самой плитке (TerrainTiles._pillbox_crack, 0.9.2).
	else:
		# На дальнем плане объекты — в текстуре рельефа, кроме мин: их видимость своя у
		# каждой стороны (item 45). Мин на карте единицы — точкой в цвет тега.
		for mk: String in [MCF.FEATURE_MINE, MCF.FEATURE_AV_MINE]:
			for mc: Vector2i in _display_feature_cells(mk):
				if _cell_on_screen(mc.x, mc.y) and resolver.mine_visible_to(viewer, mc):
					draw_rect(Rect2(_cell_origin(mc) + Vector2(CELL * 0.25, CELL * 0.25),
							Vector2(CELL * 0.5, CELL * 0.5)), Color(0.85, 0.25, 0.2))
		for sc: Vector2i in _display_feature_cells(MCF.FEATURE_DRONE_STATION):
			if _cell_on_screen(sc.x, sc.y) and _cell_seen_now(sc, visible):
				draw_rect(Rect2(_cell_origin(sc) + Vector2(CELL * 0.25, CELL * 0.25),
						Vector2(CELL * 0.5, CELL * 0.5)), Color(0.5, 0.8, 0.95))
	# Карта высот — поверх объектов (issues-12 #12): под туманом окопы, мешки и насыпи
	# рисуются этим же проходом и закрывали свои числа.
	if _heightmap and zoom >= HEIGHTMAP_MIN_ZOOM:
		_draw_heights(font, visible, fog_on, vx0, vy0, vx1, vy1)

	if state.grid.in_bounds(_inspected_station) and grid.cell(_inspected_station).feature_id == MCF.FEATURE_DRONE_STATION \
			and _cell_seen_now(_inspected_station, visible):
		var leash := MCF.DRONE_LEASH
		var top := (_inspected_station - Vector2i(leash, leash)).max(Vector2i.ZERO)
		var bottom := (_inspected_station + Vector2i(leash + 1, leash + 1)).min(Vector2i(gw, gh))
		var zone := Rect2(_cell_origin(top), Vector2(bottom - top) * CELL)
		draw_rect(zone, Color(0.38, 0.7, 0.85, 0.08))
		draw_rect(zone, Color(0.38, 0.7, 0.85, 0.8), false, 2.0)

	# Объект под наведённой кнопкой выбора — поверх рельефа и объектов, чтобы его было
	# видно сразу. Для станции заодно показываем поводок её дрона: выбор «с какой
	# запускать» — это и есть выбор, докуда дрон дотянется.
	if state.grid.in_bounds(_hover_cell):
		var ho := _cell_origin(_hover_cell)
		var hsz := Vector2(CELL, CELL)
		if grid.cell(_hover_cell).feature_id == MCF.FEATURE_DRONE_STATION:
			var hl := MCF.DRONE_LEASH
			var htl := Vector2i(maxi(0, _hover_cell.x - hl), maxi(0, _hover_cell.y - hl))
			var hbr := Vector2i(mini(grid.width - 1, _hover_cell.x + hl),
					mini(grid.height - 1, _hover_cell.y + hl))
			var hrect := Rect2(_cell_origin(htl), Vector2(hbr - htl + Vector2i.ONE) * CELL)
			draw_rect(hrect, Color(0.38, 0.7, 0.85, 0.08))
			draw_rect(hrect, Color(0.38, 0.7, 0.85, 0.7), false, 2.0)
		draw_rect(Rect2(ho, hsz), Color(0.45, 0.85, 1.0, 0.25))
		draw_rect(Rect2(ho, hsz), Color(0.6, 0.92, 1.0), false, 3.0)

	# Косметика поверх пола, но ПОД телами и бойцами (#21): лужи, осколки, гильзы.
	_draw_fx_props(visible)
	# Случайные события (0.9.4): объявленные зоны с отсчётом и стоящий газ.
	_draw_random_events(font)
	_draw_objectives(font, visible, fog_on, viewer)


	# Корпуса машин (§техника): прямоугольник по всему следу, цвет владельца.
	for veh: Vehicle in state.all_vehicles():
		# Плавный переезд: рисунок машины сдвинут к ещё не пройденной части пути; борг
		# идёт вместе со своим пилотом (его шаг — шаг бойца).
		var voff: Vector2 = _veh_offset.get(veh.id, Vector2.ZERO)
		if veh.is_borg():
			var pilot := state.get_unit(veh.borg_operator())
			if pilot != null and state.grid.in_bounds(pilot.coord):
				voff = _cell_origin(_draw_cell(pilot)) - _cell_origin(veh.origin) \
						+ _walk_offset.get(pilot.id, Vector2.ZERO)
		draw_set_transform(pan + voff * zoom, 0.0, Vector2(zoom, zoom))
		var fp := veh.footprint()
		var vseen := false
		for fc in fp:
			if visible.has(fc):
				vseen = true
				break
		if not vseen:
			continue
		# item 22: во время броска выстрела показываем ПРЕЖНЮЮ прочность/целость машины —
		# снятие прочности и превращение в обломок не должны опережать кубик.
		var disp_wrecked := veh.wrecked
		var disp_dur := veh.durability
		if not _hold_visual.is_empty():
			var _hv: Dictionary = _hold_visual.get("vehicles", {})
			if _hv.has(veh.id):
				disp_wrecked = _hv[veh.id]["wrecked"]
				disp_dur = _hv[veh.id]["durability"]
		var org := _cell_origin(veh.origin)
		var vsize := Vector2(veh.size.x * CELL, veh.size.y * CELL)
		var hull := Rect2(org + Vector2(3, 3), vsize - Vector2(6, 6))
		var hull_col: Color = _side_color(veh.owner)
		if disp_wrecked:
			hull_col = Color(0.3, 0.3, 0.32)
		var vcenter := org + vsize * 0.5
		if veh.is_borg():
			_draw_borg(veh, org, hull_col, disp_wrecked, disp_dur, font)
			continue
		# Картинка машины растягивается на весь след и поворачивается по фронту (#55).
		var veh_name := (veh.type_id + "_wreck") if disp_wrecked else veh.type_id
		var veh_key := Sprites.resolve(veh_name)
		if veh_key == "" and disp_wrecked:
			veh_key = Sprites.resolve(veh.type_id)
		if veh_key != "":
			Sprites.draw_texture_override_rect(self, veh_key, Rect2(org, vsize),
				_facing_degrees(veh.facing), Color(1, 1, 1,
					0.4 if mode == Mode.VEH_MOVE and veh.id == selected_vehicle_id else 1.0))
			# Рамка в цвете стороны поверх картинки (issue 4): поставочная текстура
			# танка одна на всех, и без рамки два вражеских танка выглядели бы
			# одинаково — а принадлежность машины игрок обязан читать с доски.
			draw_rect(Rect2(org + Vector2(2, 2), vsize - Vector2(4, 4)), hull_col, false, 2.0)
		else:
			draw_rect(hull, Color(hull_col.darkened(0.35), 0.4 if mode == Mode.VEH_MOVE and veh.id == selected_vehicle_id else 1.0))
			draw_rect(hull, hull_col, false, 3.0)
			# Направление (стрелка фронта) — у танка.
			if veh.facing != Vector2i.ZERO and not disp_wrecked:
				var dir := Vector2(veh.facing.x, veh.facing.y).normalized()
				draw_line(vcenter, vcenter + dir * (CELL * 0.6), Color.WHITE, 3.0)
		var label: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
		if disp_wrecked:
			label = "WRECK"
		draw_string(font, org + Vector2(8, 18), "%s" % label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _ink(hull_col.darkened(0.35)))
		if not disp_wrecked:
			draw_string(font, org + Vector2(8, vsize.y - 8),
				"DUR %d  CREW %d" % [disp_dur, veh.living_crew_count()],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.9, 0.9, 0.6))
			# Жёлтые точки ОД машины (item 3): та же метка, что у пехоты, — по одной точке
			# на очко действия, в правом-верхнем углу следа, чтобы не спорить с подписью.
			# У челнока пула нет (batch 13): его водит пассажир за свои очки, и точки
			# рисуются у него самого.
			var vap: int = 0 if veh.seated() else maxi(0, veh.ap)
			for i in vap:
				draw_circle(org + Vector2(vsize.x - 8 - i * 8, 8), 3, Color(1, 1, 0.4))
			# Станция в кресле (issues-12 #7) — поверх корпуса и в полёте вместе с ним; под
			# корпусом её не было видно, а в переезде она прыгала в конец пути раньше машины.
			if veh.seated():
				for si in veh.seats.size():
					var stc := veh.seat_cell(si)
					if veh.seats[si] == Vehicle.SEAT_STATION and _cell_seen_now(stc, visible):
						_tiles.draw_feature_tile(self, MCF.FEATURE_DRONE_STATION, stc,
								Rect2(_cell_origin(stc), Vector2(CELL, CELL)))

	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	# Выбор машины для посадки — поверх корпусов, иначе подсветку закрывала сама машина.
	if mode == Mode.BOARD_PICK:
		var bhov := _board_pick_at(_pos_to_cell(get_viewport().get_mouse_position()))
		for bv: Vehicle in _board_pick:
			var lit: bool = bv == bhov
			for bc: Vector2i in _veh_cells(bv):
				draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)),
						Color(0.4, 0.7, 1.0, 0.45 if lit else 0.2))
				draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(0.55, 0.8, 1.0, 0.9), false, 2.0)
			if lit:
				var bname: String = VehicleDB.get_vehicle(bv.type_id).get("name", bv.type_id)
				draw_string_outline(font, _cell_origin(bv.origin) + Vector2(2, -6), "Board %s" % bname,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, Color(0, 0, 0, 0.9))
				draw_string(font, _cell_origin(bv.origin) + Vector2(2, -6), "Board %s" % bname,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.75, 0.88, 1.0))
	var _drones_pending: Array = []
	var shifted := false
	var walking := not _walk_cells.is_empty()
	# Раз на кадр (batch mp-perf): цвета сторон, есть ли выделенная группа, ведётся ли показ
	# старых ОД, и мелкие подробности (обводка, метка, точки ОД) — только когда их видно.
	var side_cols: Dictionary = {}
	var has_group := not _group_ids.is_empty()
	var ap_held := not _ap_display.is_empty()
	var details := zoom >= UNIT_DETAIL_ZOOM
	var canvas := get_canvas_item()
	for unit: UnitInstance in state.all_units():
		# Экипаж танка на поле не рисуется (§техника): он за краем поля, и отсечение по окну
		# ниже его отбрасывает. Пассажир челнока — поверх корпуса, в клетке своего кресла.
		# Во время проигрывания шагов житель рисуется на промежуточной клетке (#96),
		# а не там, где он уже стоит по состоянию.
		var at: Vector2i = _walk_cells.get(unit.id, unit.coord) if walking else unit.coord
		# Отсечение по вьюпорту — первым и без вызовов функций (batch mp-perf): на большой
		# карте почти вся армия за краем экрана.
		if at.x < vx0 or at.x > vx1 or at.y < vy0 or at.y > vy1:
			continue
		# Плавный шаг: рисунок бойца сдвинут на долю пути к следующей клетке. Смена
		# преобразования — команда отрисовки, поэтому только у тех, кто сейчас идёт
		# (batch mp-perf): раньше её получал каждый боец каждый кадр.
		var woff: Variant = _walk_offset.get(unit.id)
		if woff != null:
			draw_set_transform(pan + Vector2(woff) * zoom, 0.0, Vector2(zoom, zoom))
			shifted = true
		elif shifted:
			draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
			shifted = false
		# Отсечение по вьюпорту (item 5): бойца за краем экрана не рисуем — на 500×500 это
		# главный выигрыш, ведь армия почти всегда шире окна.
		if at.x < vx0 or at.x > vx1 or at.y < vy0 or at.y > vy1:
			continue
		# Туман войны (§3.9): чужой юнит виден, только если его клетку видит команда.
		var uown := unit.owner
		if uown != viewer and not state.roster.are_allies(viewer, uown) and fog_on \
				and (state.grid.cell(at).obscured() or not visible.has(at)):
			continue
		# Смерть в текущем действии показываем лишь ПОСЛЕ анимации броска (#46):
		# пока крутится кубик, погибший рисуется как живой юнит.
		# Corpses are drawn in the final ground pass, above fire.
		if unit.status == MCF.Status.CORPSE and not _pending_death_ids.has(unit.id):
			continue
		if unit.is_drone:
			# Дроны рисуем ПОСЛЕ всех наземных юнитов и машин (item 14): собираем их
			# здесь, а сам разлёт — отдельным проходом ниже, чтобы дрон гарантированно
			# был поверх корпуса, над которым висит.
			_drones_pending.append({"unit": unit, "at": at})
			continue
		# Тело цикла — без лишних вызовов (batch mp-perf): на отъезде на экране сотни
		# бойцов, и вызовы функций на каждого стоили больше самих команд отрисовки.
		# Угол клетки считается здесь же, цвета стороны — раз на кадр (side_cols).
		var corner := ORIGIN + Vector2(at.x * CELL, at.y * CELL)
		var center := corner + Vector2(CELL, CELL) * 0.5
		var cols: Array = side_cols.get(uown, [])
		if cols.is_empty():
			var sc := _side_color(uown)
			cols = [sc, sc.darkened(0.45), _ink(sc)]
			side_cols[uown] = cols
		# Картинка бойца своей фракции (batch 17, item 13): light_infantry_nova.png, иначе
		# общая light_infantry.png; без картинки — кружок цвета стороны с инициалами (item 6).
		var skey := _sprite_key(unit)
		# Боец в окопе (gore batch) стоит В канаве: чуть меньше и ниже, ноги скрыты
		# тенью земляной стенки — не «висит» над окопом.
		var in_trench := grid.cell_fast(at.x, at.y).feature_id == MCF.FEATURE_TRENCH
		var usz := CELL * (0.8 if in_trench else 1.0)
		var uorg := corner + Vector2((CELL - usz) * 0.5, (CELL - usz) * 0.75)
		var ucenter := uorg + Vector2(usz, usz) * 0.5
		if skey != "":
			Sprites.draw_texture_override(self, skey, uorg, usz)
		else:
			draw_circle(ucenter, usz * 0.34, cols[0])
			if details:
				draw_arc(ucenter, usz * 0.34, 0, TAU, 20, cols[1], 1.5)
				_tag_line(unit).draw(canvas, ucenter + Vector2(-9, 5 - 16 * 0.8), cols[2])
		if in_trench:
			draw_rect(Rect2(uorg + Vector2(usz * 0.12, usz * 0.72), Vector2(usz * 0.76, usz * 0.2)),
					Color(0.1, 0.07, 0.04, 0.55))
		if unit.id == selected_id:
			draw_arc(center, CELL * 0.42, 0, TAU, 32, Color(1, 0.9, 0.2), 3.0)
		# Водитель челнока — тонкая рамка по клетке кресла: видно, кто ведёт машину.
		if unit.aboard_vehicle_id != -1:
			var dveh := state.get_vehicle(unit.aboard_vehicle_id)
			if dveh != null and dveh.driver_id() == unit.id:
				draw_rect(Rect2(corner + Vector2(2, 2), Vector2(CELL - 4, CELL - 4)),
						Color(1.0, 0.95, 0.7, 0.9), false, 1.5)
		if MCF.is_neutral(uown):
			# Вскрытый мирный житель охотится — красное кольцо тревоги (§3.10, #56).
			if unit.civilian_active:
				draw_arc(center, CELL * 0.45, 0, TAU, 22, Color(0.85, 0.15, 0.15, 0.95), 2.0)
			# Бейдж активационной группы (item 15): чёрный квадратик с римской цифрой в
			# правом-нижнем углу — по нему видно, что инициатива изменилась.
		var group := unit.neutral_group
		if MCF.is_independent(uown): group = uown - MCF.INDEPENDENT_BASE + 1
		if group > 0: _draw_group_badge(corner, group, font)
		# Кольцо принадлежности к RTS-группе (#18).
		if has_group and _group_set.has(unit.id):
			draw_arc(center, CELL * 0.46, 0, TAU, 32, Color(0.4, 1.0, 0.5), 2.5)
		if unit.is_held():
			draw_arc(center, CELL * 0.48, 0, TAU, 32, Color(0.8, 0.3, 1.0), 3.0)
		if unit.action_state != null and unit.action_state.is_pending():
			draw_arc(center, CELL * 0.5, 0, TAU, 32, Color(1, 0.6, 0.1), 2.0)
		if details:
			var ap: int = unit.remaining_ap if not ap_held else int(_ap_display.get(unit.id, unit.remaining_ap))
			for i in ap:
				draw_circle(corner + Vector2(6 + i * 8, CELL - 6), 3, Color(1, 1, 0.4))
		# Снаряжения не хватает — общий пиксельный «!» (item 18): инженер без ЛДФ,
		# оператор без станции, огнемётчик без огнетушителя, пулемётчик без фраги. Спрашиваем
		# только тех, у кого это вообще бывает (gear_check по роду).
		if _gear_checked(unit) and resolver.unit_missing_equipment(unit):
			_draw_pixel_bang(corner + Vector2(CELL - 12, 4))
		# Юнит тащит на себе труп-щит (#6) — без метки это видно только в подсказке (#71).
		if unit.carried_corpses > 0:
			_draw_corpse_marker(corner + Vector2(9, 9),
				unit.carried_corpses, font)

	# Дроны — верхний слой (item 14): рисуются поверх машин и наземных юнитов.
	for d: Dictionary in _drones_pending:
		draw_set_transform(pan + _walk_offset.get(d["unit"].id, Vector2.ZERO) * zoom, 0.0, Vector2(zoom, zoom))
		_draw_drone(d["unit"], d["at"])
	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	# A thin second pass puts wisps in front of occupants without hiding their sprites; it
	# drifts on its own layer (GasDrift).
	_sync_gas_drift()
	_draw_seat_grid(font)


	# Рамка выделения (#18): сетка-выровненный зелёный прямоугольник поверх поля.
	if _box_dragging:
		var ba := _box_start_cell
		var bb := _pos_to_cell(_box_end_screen)
		var bx0 := mini(ba.x, bb.x)
		var by0 := mini(ba.y, bb.y)
		var bw := absi(bb.x - ba.x) + 1
		var bh := absi(bb.y - ba.y) + 1
		var brect := Rect2(_cell_origin(Vector2i(bx0, by0)), Vector2(bw * CELL, bh * CELL))
		draw_rect(brect, Color(0.3, 0.9, 0.4, 0.12))
		draw_rect(brect, Color(0.4, 1.0, 0.5, 0.8), false, 2.0)

	# Аннотации игроков поверх поля (item 51).
	_draw_ruler()

func _draw_drone(unit: UnitInstance, at: Vector2i) -> void:
	var center := _cell_origin(at) + Vector2(CELL, CELL) * 0.5
	# Дрон висит над клеткой (#13): рисуем со сдвигом в верхний-правый угол,
	# чтобы был виден наземный юнит/труп под ним.
	var dc := _cell_origin(at) + Vector2(CELL * 0.72, CELL * 0.28)
	# Тень под дроном по центру клетки — подсказка, что он парит.
	draw_circle(center, CELL * 0.1, Color(0, 0, 0, 0.25))
	var s := CELL * 0.2
	var drone_key := Sprites.resolve("drone", _owner_suffix(unit.owner))
	if drone_key != "":
		var dsz := Vector2(CELL, CELL) * 0.5
		Sprites.draw_texture_override_rect(self, drone_key, Rect2(dc - dsz * 0.5, dsz))
	else:
		var pts := PackedVector2Array([
			dc + Vector2(0, -s), dc + Vector2(s, 0),
			dc + Vector2(0, s), dc + Vector2(-s, 0)])
		draw_colored_polygon(pts, _side_color(unit.owner))
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.3, 0.9, 0.9), 2.0)
	if unit.id == selected_id:
		draw_arc(dc, CELL * 0.3, 0, TAU, 24, Color(1, 0.9, 0.2), 3.0)
	for i in _draw_ap(unit):
		draw_circle(_cell_origin(at) + Vector2(6 + i * 8, CELL - 6), 3, Color(1, 1, 0.4))

## Труп на земле (#59): красный круг на половинной прозрачности — того же размера,
## что и живой боец, но полупрозрачный, поэтому тело сразу отличимо от бойца и не
## закрывает клетку. Подложенная картинка "corpse" (#55), если она есть, важнее.
## count — сколько тел в клетке: у кучи из нескольких рядом стоит число.
## Предпросмотр лазера (#99). Над каждым объектом на пути стоит его цена в потенциале,
## а там, где потенциал кончится, луч обрывается заметной поперечной чертой — иначе
## нельзя было понять, добьёт выстрел до цели или заглохнет на второй стене.
## Разметку даёт resolver.laser_preview — тот же расчёт, по которому пойдёт выстрел.
func _draw_laser_preview(shooter: UnitInstance, aim: Vector2i) -> void:
	var trace: Array = resolver.laser_preview(shooter, aim)
	if trace.is_empty():
		return
	var half := Vector2(CELL, CELL) * 0.5
	var font := ThemeDB.fallback_font
	for rec: Dictionary in trace:
		var bc: Vector2i = rec["coord"]
		draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(0.4, 0.9, 1.0, 0.22))
	var last: Vector2i = trace[trace.size() - 1]["coord"]
	draw_line(_cell_origin(shooter.coord) + half, _cell_origin(last) + half,
			Color(0.5, 0.95, 1.0, 0.85), 2.0)
	# Метки цены — вторым проходом, чтобы подсветка клеток их не перекрывала.
	for rec: Dictionary in trace:
		var cost := int(rec["cost"])
		if String(rec["kind"]) == "empty" and cost == 0:
			continue
		var at := _cell_origin(rec["coord"]) + Vector2(CELL * 0.5, 4.0)
		# Стекло возвращает потенциал — такую метку показываем со знаком плюс.
		var text := ("+%d" % -cost) if cost < 0 else ("−%d" % cost)
		var col := Color(0.55, 1.0, 0.6) if cost < 0 else Color(1.0, 0.85, 0.4)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, -1, 13, 3,
				Color(0, 0, 0, 0.9))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, -1, 13, col)
	# Где луч гаснет: поперечная черта на дальней стороне последней клетки.
	var end_org := _cell_origin(last)
	var dir: Vector2i = trace[0]["coord"] - shooter.coord
	var edge := end_org + half + Vector2(dir.x, dir.y) * (CELL * 0.5)
	var across := Vector2(-dir.y, dir.x) * (CELL * 0.42)
	draw_line(edge - across, edge + across, Color(1.0, 0.4, 0.35, 0.95), 3.0)
	var left := int(trace[trace.size() - 1]["left"])
	draw_string_outline(font, end_org + Vector2(CELL * 0.5, CELL - 4), "%d left" % left,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 11, 3, Color(0, 0, 0, 0.9))
	draw_string(font, end_org + Vector2(CELL * 0.5, CELL - 4), "%d left" % left,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 11, Color(0.8, 0.95, 1.0))

## Косметические частицы (#21): осевшие и ещё летящие. Ни одна из них не влияет на
## правила — это чистая декорация, и она же первой отваливается под туманом войны:
## того, чего команда не видит, ей и знать незачем.
##
## Картинки-замены имеют приоритет (glass_shard.png и т. п.); без них рисуются
## векторные примитивы, как и всё остальное в этой игре.
func _draw_fx_props(visible: Dictionary) -> void:
	_draw_fx_lanes(visible)
	# Пули-трассеры (item 16): жёлтый штрих летит от стрелка к цели. Под туманом —
	# только там, где голова пули в обзоре (0.11.3): трассер из темноты выдавал стрелка.
	var tr_fog: bool = _view_resolver().visibility_limited()
	for tr: Dictionary in _fx.tracers:
		var k: float = clampf(float(tr["t"]) / maxf(0.001, float(tr["dur"])), 0.0, 1.0)
		if k <= 0.0:
			continue
		var head_cell: Vector2 = Vector2(tr["from"]).lerp(Vector2(tr["to"]), k)
		if tr_fog and not visible.has(Vector2i(floori(head_cell.x), floori(head_cell.y))):
			continue
		var tf: Vector2 = ORIGIN + Vector2(tr["from"]) * CELL
		var tt: Vector2 = ORIGIN + Vector2(tr["to"]) * CELL
		var head: Vector2 = tf.lerp(tt, k)
		_draw_projectile_sprite("bullet", head, (tt - tf).angle(), 0.65)
		var source: Vector2 = tr["from"]
		if k < 0.2 and (not tr_fog or visible.has(Vector2i(floori(source.x), floori(source.y)))):
			_draw_projectile_sprite("muzzle", tf, (tt - tf).angle(), 0.6)

	_draw_shots(visible, tr_fog)
	# ОСЕВШЕЙ косметики здесь больше нет (0.9.3): кровь, гильзы и осколки впечатаны в
	# картинку куска доски (TerrainTiles._bake_decals) и кадру ничего не стоят. Осталось
	# только то, что ещё в воздухе, — его и правда надо двигать каждый кадр.
	_sync_fly_layer(visible)

func _sync_fly_layer(visible: Dictionary) -> void:
	if _fly == null:
		_fly = FlyLayer.new()
		_fly.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_fly)
	_fly.position = pan
	_fly.scale = Vector2(zoom, zoom)
	var had := not _fly.items.is_empty()
	_fly.items = []
	if _fx.flying.is_empty():
		if had:
			_fly.queue_redraw()
		return
	var fog_on: bool = _view_resolver().visibility_limited()
	var res := TerrainTiles.res_for(CELL * zoom * get_viewport().get_final_transform().get_scale().x)
	if _fly_tiles != _tiles:
		_fly_tex.clear()
		_fly_tiles = _tiles
	for f: Dictionary in _fx.flying:
		var kind := str(f["kind"])
		var pos := FxDecals.flight_pos(f)
		var origin: Vector2i = f.get("origin", Vector2i(-1, -1))
		if _tiles == null or zoom < LOD_ZOOM:
			_draw_fx_one(kind, pos, FxDecals.flight_rot(f), f["scale"], visible, fog_on, origin)
			continue
		var c := Vector2i(floori(pos.x), floori(pos.y))
		if not _cell_on_screen(c.x, c.y):
			continue
		var wcell := state.grid.cell(c)
		if wcell != null and wcell.cover_height >= MCF.WALL_HEIGHT and wcell.feature_id != MCF.FEATURE_BOUNDARY:
			continue
		if fog_on and not visible.has(c) and not visible.has(origin):
			continue
		var look := FxDecals.look_of(kind)
		if look.is_empty():
			continue
		var px := maxi(1, roundi(float(look[0]) * float(f["scale"]) * res))
		var img: Image = _tiles._decal_sprite(kind, px, FxDecals.flight_rot(f), look)
		if img == null:
			continue
		if not _fly_tex.has(img):
			_fly_tex[img] = ImageTexture.create_from_image(img)
		var at := Vector2(roundi(pos.x * res) - px / 2, roundi(pos.y * res) - px / 2) / float(res)
		_fly.items.append([_fly_tex[img], Rect2(ORIGIN + at * CELL, Vector2(px, px) / float(res) * CELL)])
	_fly.queue_redraw()

## Снаряды в полёте (0.12.1): ракета — тёмный корпус с факелом и дымным следом, снаряд танка —
## раскалённый штрих, граната — по дуге, с тенью на земле. Под туманом — только там, где
## снаряд в обзоре.
func _draw_shots(visible: Dictionary, fog_on: bool) -> void:
	for sh: Dictionary in _fx.shots:
		var k: float = clampf(float(sh["t"]) / maxf(0.001, float(sh["dur"])), 0.0, 1.0)
		var a: Vector2 = sh["from"]
		var b: Vector2 = sh["to"]
		var p := a.lerp(b, k)
		if fog_on and not visible.has(Vector2i(floori(p.x), floori(p.y))):
			continue
		var dir := (b - a).normalized() if b != a else Vector2.RIGHT
		var at := ORIGIN + p * CELL
		match str(sh["kind"]):
			"rocket":
				for i in range(1, 5):
					var q := a.lerp(b, maxf(0.0, k - 0.06 * i))
					if fog_on and not visible.has(Vector2i(floori(q.x), floori(q.y))): continue
					_draw_projectile_sprite("smoke", ORIGIN + q * CELL, 0.3 * i, 0.25 + i * 0.08, Color(1, 1, 1, 0.5 - i * 0.08))
				_draw_projectile_sprite("exhaust", at - dir * CELL * 0.23, dir.angle(), 0.35)
				_draw_projectile_sprite("rocket", at, dir.angle(), 0.65)
			"shell":
				_draw_projectile_sprite("shell", at, dir.angle(), 0.7)
			_:
				_draw_projectile_sprite("grenade", at - Vector2(0, sin(k * PI) * CELL * 0.6), k * TAU, 0.5)

func _draw_projectile_sprite(kind: String, at: Vector2, angle: float, scale_: float, tint := Color.WHITE) -> void:
	var size_ := Vector2.ONE * CELL * scale_
	Sprites.draw_texture_override_rect(self, "fx_" + kind, Rect2(at - size_ * 0.5, size_), rad_to_deg(angle), tint)

func _draw_random_events(font: Font) -> void:
	if resolver == null or resolver.random_events == null:
		return
	var ev: RandomEvents = resolver.random_events
	if ev.dust_left > 0:
		draw_rect(Rect2(ORIGIN, Vector2(state.grid.width, state.grid.height) * CELL), DUST_TINT)
	_draw_gas_tiles(0.65, true)
	for cl: Dictionary in ev.clouds:
		var rect := Rect2(ORIGIN + Vector2(int(cl["x"]), int(cl["y"])) * CELL,
				Vector2(int(cl["w"]), int(cl["h"])) * CELL)
		var col: Color = EVENT_COLORS["gas"]
		# The outlined zone and its timer remain visible even under fog of war.
		draw_rect(rect, Color(col.r, col.g, col.b, 1.0), false, 3.0)
		var tag := "GAS %d" % int(cl["left"])
		var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_rect(Rect2(rect.position + Vector2(2, 2), Vector2(tw + 8, 18)), Color(0, 0, 0, 0.55))
		draw_string(font, rect.position + Vector2(6, 16), tag,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.95, 0.95, 0.95, 1.0))
	for e: Dictionary in ev.pending:
		var id := str(e["id"])
		var p: Dictionary = e["params"]
		var col: Color = EVENT_COLORS.get(id, Color(1, 1, 1, 1))
		var rect := Rect2()
		if id == RandomEvents.DUST:
			continue   # буря на всё поле: зоны нет, предупреждение — в журнале
		if id == RandomEvents.ARMY or id == RandomEvents.REINFORCE:
			rect = _army_rect(p)
		else:
			rect = Rect2(ORIGIN + Vector2(int(p.get("x", 0)), int(p.get("y", 0))) * CELL,
					Vector2(int(p.get("w", 1)), int(p.get("h", 1))) * CELL)
		draw_rect(rect, Color(col.r, col.g, col.b, 0.14))
		draw_rect(rect, Color(col.r, col.g, col.b, 0.85), false, 2.0)
		var label := "%s · END OF ROUND" % RandomEvents.event_name(id).to_upper()
		draw_string(font, rect.position + Vector2(4, 16), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(col.r, col.g, col.b, 0.95))

## Участок высадки армии или волны: полоса у края, а в бункере — конец коридора.
func _army_rect(p: Dictionary) -> Rect2:
	var r := resolver.army_landing_rect(p)
	return Rect2(ORIGIN + Vector2(r.position) * CELL, Vector2(r.size) * CELL)

## Цвет команды по ключу режима — цвет первой её стороны.
func _team_key_color(key: String) -> Color:
	var sides := resolver.team_sides(key)
	return _side_color(sides[0]) if not sides.is_empty() else ZONE_IDLE

## Зоны Capture & Hold и объявленная волна Holdout. Зоны — правило партии, а не разведка:
## видны всем и под любым туманом. Цвет — команда, державшая зону на последней границе
## раунда; живой подсчёт под туманом выдал бы невидимых.
func _draw_objectives(font: Font, visible: Dictionary, fog_on: bool, viewer: int) -> void:
	if resolver == null or resolver.mode == null:
		return
	var md := resolver.mode
	# Метка награды (0.12) — над бойцом, но только если зритель его видит: туман не выдаёт.
	if md.bounty_unit >= 0:
		var bu := state.get_unit(md.bounty_unit)
		if bu != null and bu.is_alive() and state.grid.in_bounds(bu.coord) and (not fog_on \
				or bu.owner == viewer or state.roster.are_allies(viewer, bu.owner) \
				or (visible.has(bu.coord) and not state.grid.cell(bu.coord).obscured())):
			var r := Rect2(_cell_origin(bu.coord), Vector2(CELL, CELL))
			draw_rect(r.grow(2.0), BOUNTY_COLOR, false, 2.0)
			var tag := "BOUNTY +%d" % MatchMode.BOUNTY_POINTS
			var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			var at := r.position + Vector2((CELL - tw) / 2.0 - 4, -18)
			draw_rect(Rect2(at, Vector2(tw + 8, 16)), Color(0, 0, 0, 0.65))
			draw_string(font, at + Vector2(4, 12), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, BOUNTY_COLOR)
	for i in md.zones.size():
		var r := md.zone_rect(i)
		var rect := Rect2(ORIGIN + Vector2(r.position) * CELL, Vector2(r.size) * CELL)
		var h: String = md.holders[i] if i < md.holders.size() else ""
		var col := _team_key_color(h) if h != "" else ZONE_IDLE
		draw_rect(rect, Color(col.r, col.g, col.b, 0.10))
		draw_rect(rect, Color(col.r, col.g, col.b, 0.9), false, 3.0)
		var tag := md.zone_name(i).to_upper()
		var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_rect(Rect2(rect.position + Vector2(2, 2), Vector2(tw + 8, 18)), Color(0, 0, 0, 0.55))
		draw_string(font, rect.position + Vector2(6, 16), tag,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(col.r, col.g, col.b, 1.0))
	if md.is_holdout() and not md.pending_wave.is_empty():
		var col: Color = EVENT_COLORS["army"]
		var rect := _army_rect(md.pending_wave)
		draw_rect(rect, Color(col.r, col.g, col.b, 0.14))
		draw_rect(rect, Color(col.r, col.g, col.b, 0.85), false, 2.0)
		draw_string(font, rect.position + Vector2(4, 16), "WAVE %d · END OF ROUND" % (md.wave + 1),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(col.r, col.g, col.b, 0.95))

## Панель режима: счёт и зоны (Capture & Hold) или волны (Holdout). Строки пересобираются,
## только когда что-то в них изменилось.
func _refresh_objective() -> void:
	if _objective_group == null or resolver == null or resolver.mode == null:
		return
	var md := resolver.mode
	_objective_group.visible = md.kind != MatchMode.Kind.ANNIHILATION
	if not _objective_group.visible:
		return
	_objective_group.title = MatchMode.name_of(md.kind)
	var rows: Array = []   # [цвет или null, подпись, значение]
	if md.is_capture():
		rows.append([null, "First to %d points" % md.target, ""])
		for k: String in md.scores:
			rows.append([_team_key_color(k), resolver.team_label(k), str(int(md.scores[k]))])
		for i in md.zones.size():
			var h: String = md.holders[i] if i < md.holders.size() else ""
			rows.append([_team_key_color(h) if h != "" else ZONE_IDLE, md.zone_name(i),
					resolver.team_label(h) if h != "" else "nobody"])
		if md.bounty_unit >= 0:
			var bu := state.get_unit(md.bounty_unit)
			if bu != null:
				rows.append([BOUNTY_COLOR, "Bounty: %s's %s" % [state.roster.name_of(bu.owner),
						bu.stats.display_name], "+%d" % MatchMode.BOUNTY_POINTS])
	else:
		var left := resolver.wave_fighters_left()
		rows.append([null, "Waves landed", "%d / %s" % [md.wave, "∞" if md.endless() else str(md.waves_total)]])
		var next := "—"
		if not md.pending_wave.is_empty():
			next = "end of this round"
		elif md.endless() or md.wave < md.waves_total:
			next = "round %d" % maxi(md.next_wave_round, state.turns.round_number + 1)
		rows.append([null, "Next wave", next])
		rows.append([EVENT_COLORS["army"], "Enemies left", str(left)])
		rows.append([null, "Killed", str(md.wave_spawned - left)])
	var key := var_to_str(rows)
	if key == _objective_key:
		return
	_objective_key = key
	var body := _objective_group.body
	for c in body.get_children():
		c.queue_free()
	for row: Array in rows:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		if row[0] != null:
			var sw := ColorRect.new()
			sw.color = row[0]
			sw.custom_minimum_size = Vector2(10, 10)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			hb.add_child(sw)
		var l := Label.new()
		l.text = str(row[1])
		l.add_theme_font_size_override("font_size", 12)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		hb.add_child(l)
		if str(row[2]) != "":
			var v := Label.new()
			v.text = str(row[2])
			v.add_theme_font_size_override("font_size", 12)
			hb.add_child(v)
		body.add_child(hb)

## Gas reads as poison, not gravel (owner, 2026-10): a sickly yellow-green, sampled smoothly
## instead of pixel by pixel, and the light pass over units drifts (GasDrift). Smoke stays
## the dark gray below, still.
const GAS_TINT := Color(0.74, 0.88, 0.3)
## The drifting wisps are lighter than the cloud under them, or their motion would not show.
const GAS_WISP := Color(0.93, 1.0, 0.55)
const SMOKE_WISP := Color(0.66, 0.68, 0.72)

## The light pass over units: the same tiles on their own layer, whose shader slides two
## layers of the cloud texture across them. It moves on the GPU, so a cloud on screen never
## makes the battle screen redraw. Last in paint order, where that pass was drawn.
class GasDrift extends Node2D:
	const SHADER := """
shader_type canvas_item;
uniform sampler2D wisps : repeat_enable, filter_linear;
uniform float span = 1600.0;   // board pixels per repeat of the cloud texture (40 cells)
varying vec2 world;
void vertex() {
	world = VERTEX;
}
void fragment() {
	vec4 shape = texture(TEXTURE, UV);
	// The cloud texture's alpha holds its billows (about 0.47 to 0.68): two copies sliding
	// different ways at a third of a cell a second, stretched to full strength.
	float a = texture(wisps, world / span + TIME * vec2(0.0075, 0.003)).a;
	float b = texture(wisps, world / (span * 1.6) + TIME * vec2(-0.004, 0.006)).a;
	float drift = smoothstep(0.5, 0.62, (a + b) * 0.5);
	COLOR = vec4(COLOR.rgb * shape.rgb, COLOR.a * shape.a * drift);
}
"""
	var host: Node
	func _ready() -> void:
		var mat := ShaderMaterial.new()
		mat.shader = Shader.new()
		mat.shader.code = SHADER
		mat.set_shader_parameter("wisps", Sprites.texture_of("gas"))
		material = mat
	func _draw() -> void:
		if host != null:
			host._draw_gas_tiles(0.45, false, self)

var _gas_drift: GasDrift = null

func _sync_gas_drift() -> void:
	if _gas_drift == null:
		_gas_drift = GasDrift.new()
		_gas_drift.host = self
		add_child(_gas_drift)
	_gas_drift.position = pan
	_gas_drift.scale = Vector2(zoom, zoom)
	_gas_drift.queue_redraw()

func _draw_gas_tiles(alpha: float, fill: bool, ci: CanvasItem = null) -> void:
	if resolver == null or resolver.random_events == null:
		return
	if ci == null:
		ci = self
	var ev: RandomEvents = resolver.random_events
	if ev.clouds.is_empty() and ev.smoke.is_empty():
		return
	var tex := GasTiles.texture()
	if tex != null and (_gas_canvas_texture == null or _gas_canvas_texture.diffuse_texture != tex):
		_gas_canvas_texture = CanvasTexture.new()
		_gas_canvas_texture.diffuse_texture = tex
		_gas_canvas_texture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# Туман войны (0.11.3): газ виден только там, куда смотрят (Resolver.team_sees_gas —
	# в обзор сама газовая клетка не входит: газ прячет то, что внутри). Без тумана газ
	# виден весь, как и раньше. Рамка и счётчик зоны — объявленное событие, они остаются.
	# Дым дымовых гранат (0.12) — то же облако своим тоном и по тем же правилам тумана.
	var view := _view_resolver()
	var seen: Dictionary = view.team_sees_gas(_viewing_side()) if view.fog_enabled else {}
	var gas: Color = GAS_WISP if ci != self else GAS_TINT
	var smoke: Color = SMOKE_WISP if ci != self else SMOKE_TINT
	_draw_cloud_tiles(ci, ev.clouds, false, Color(gas.r, gas.g, gas.b, alpha), fill, tex,
			view.fog_enabled, seen)
	_draw_cloud_tiles(ci, ev.smoke, true, Color(smoke.r, smoke.g, smoke.b, alpha), fill, tex,
			view.fog_enabled, seen)

func _draw_cloud_tiles(ci: CanvasItem, clouds: Array, smoke: bool, tint: Color, fill: bool,
		tex: Texture2D, fogged: bool, seen: Dictionary) -> void:
	var drawn := {}
	for cl: Dictionary in clouds:
		var x0 := maxi(_cull_x0, int(cl["x"]))
		var x1 := mini(_cull_x1, int(cl["x"]) + int(cl["w"]) - 1)
		var y0 := maxi(_cull_y0, int(cl["y"]))
		var y1 := mini(_cull_y1, int(cl["y"]) + int(cl["h"]) - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var coord := Vector2i(x, y)
				if drawn.has(coord) or not GasTiles.at(state.grid, coord, smoke):
					continue
				drawn[coord] = true
				if fogged and not seen.has(coord):
					continue
				var cell_rect := Rect2(ORIGIN + Vector2(x, y) * CELL, Vector2(CELL, CELL))
				if tex != null:
					# Half a texel in from the tile's edge: smooth sampling must not pick up
					# the neighbouring tile of the sheet.
					var src := GasTiles.source_rect(tex, coord, GasTiles.mask_at(state.grid, coord, smoke)).grow(-0.5)
					ci.draw_texture_rect_region(_gas_canvas_texture, cell_rect, src, tint)
				elif fill:
					ci.draw_rect(cell_rect, Color(tint.r * 0.9, tint.g * 0.9, tint.b * 0.9, 0.36))

## ВСПЫШКА ВЗРЫВА (0.9.4): клетки разрыва на секунду горят и гаснут. Чистая косметика —
## пламенем это не становится ни на одну клетку: ни резолвер, ни правила огня об этих
## клетках не знают, и на следующий ход от вспышки не остаётся ничего, кроме обычного
## щебня. Рисуется плиткой огня (как и настоящий пожар), а без неё — оранжевой заливкой.
## Туман войны вспышка не протекает: чего команда не видит, того ей и не показывают.
func _draw_fx_flashes(visible: Dictionary) -> void:
	if _fx.flashes.is_empty():
		return
	var fog_on: bool = _view_resolver().visibility_limited()
	for flash: Dictionary in _fx.flashes:
		var a := FxDecals.flash_alpha(flash)
		if a <= 0.0:
			continue
		for c: Vector2i in flash["cells"]:
			if not _cell_on_screen(c.x, c.y) or (fog_on and not visible.has(c)) \
					or not state.grid.in_bounds(c) or state.grid.cell(c).is_space:
				continue
			var rect := Rect2(ORIGIN + Vector2(c) * CELL, Vector2(CELL, CELL))
			if not Sprites.draw_texture_override_rect(self, "fire", rect, 0.0,
					Color(1, 1, 1, a)):
				draw_rect(rect, Color(1.0, 0.45, 0.08, 0.55 * a))
				draw_rect(Rect2(rect.position + Vector2(CELL, CELL) * 0.25,
						Vector2(CELL, CELL) * 0.5), Color(1.0, 0.86, 0.35, 0.7 * a))

## Рисунок струи: ядро и ореол от сопла до фронта, у каждой достигнутой клетки — языки
## пламени с мерцанием. В тумане — только видимые клетки.
func _draw_flame_jet(visible: Dictionary) -> void:
	if _jet.is_empty():
		return
	var cells: Array = _jet["cells"]
	var t := float(_jet["t"])
	var reached := mini(cells.size(), int(t / FLAME_STEP) + 1)
	var fog_on: bool = _view_resolver().visibility_limited()
	# The same crisp fire tile as the burning floor, revealed rapidly along the jet.
	# Clip every tile, including the leading one, to the viewer's sight.
	for i in reached:
		var c: Vector2i = cells[i]
		if fog_on and not visible.has(c):
			continue
		var cell := state.grid.cell(c)
		if cell == null or cell.is_space:
			continue
		Sprites.draw_texture_override_rect(self, "fire", Rect2(_cell_origin(c), Vector2.ONE * CELL))

## Дорожки боя (issue 8): «кто в кого стреляет». Трассер живёт 0.16 с — увидеть его
## можно, разобрать перестрелку нельзя, особенно в ход ИИ, когда за один заход стреляют
## десятки бойцов. Дорожка держится секунды: линия в цвете СТОРОНЫ СТРЕЛКА, кольцо у
## стрелка и прицел у цели, всё гаснет само.
##
## Туман войны при этом не протекает (§3.9): невидимого стрелка дорожка не выдаёт —
## у цели остаётся только прицел, то есть «по этому бойцу работают», а откуда — ищи сам.
func _draw_fx_lanes(visible: Dictionary) -> void:
	if _fx.lanes.is_empty():
		return
	var fog_on: bool = _view_resolver().visibility_limited()
	for lane: Dictionary in _fx.lanes:
		var la := FxDecals.lane_alpha(lane)
		if la <= 0.0:
			continue
		var from_cell := Vector2(lane["from"])
		var to_cell := Vector2(lane["to"])
		var a: Vector2 = ORIGIN + from_cell * CELL
		var b: Vector2 = ORIGIN + to_cell * CELL
		var col: Color = _side_color(int(lane["owner"]))
		var kind := str(lane["kind"])
		var wide: float = 3.0 if kind == "shot" else 5.0
		var shooter_seen: bool = not fog_on \
				or visible.has(Vector2i(floori(from_cell.x), floori(from_cell.y)))
		if shooter_seen:
			# Сама дорожка: широкий полупрозрачный след и яркая нить по центру.
			draw_line(a, b, Color(col.r, col.g, col.b, 0.22 * la), wide + 4.0)
			draw_line(a, b, Color(col.r, col.g, col.b, 0.80 * la), wide)
			# Кольцо у стрелка — «отсюда стреляли».
			draw_arc(a, CELL * 0.46, 0.0, TAU, 24, Color(col.r, col.g, col.b, 0.85 * la), 2.0)
		# Прицел у цели — «по этому месту работают» игрок вправе видеть, но только там, куда
		# сам смотрит: прицел в темноте выдавал чужую стрельбу по туману (issues-12 #4).
		if not shooter_seen and not visible.has(Vector2i(floori(to_cell.x), floori(to_cell.y))):
			continue
		var rr := CELL * 0.40
		var tcol := Color(col.r, col.g, col.b, 0.95 * la)
		draw_arc(b, rr, 0.0, TAU, 28, tcol, 2.5)
		for d: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			draw_line(b + d * rr * 0.55, b + d * rr * 1.45, tcol, 2.0)

## origin — клетка, откуда частица вылетела (разбитое окно): видел, как оно разбилось, —
## видишь и все его осколки, даже долетевшие в туман (item 7).
func _draw_fx_one(kind: String, cell_pos: Vector2, rot: float, scale: float,
		visible: Dictionary, fog_on: bool, origin: Vector2i = Vector2i(-1, -1)) -> void:
	# Частицы за краем экрана не рисуем (item 5): на большой карте их накапливаются сотни.
	var _fxc := Vector2i(floori(cell_pos.x), floori(cell_pos.y))
	if not _cell_on_screen(_fxc.x, _fxc.y):
		return
	# Осколки/частицы не оседают на стенах — они от них отскакивают (item 7). Клетку-стену
	# просто не рисуем: обломок туда «не долетел».
	var _wcell := state.grid.cell(_fxc)
	if _wcell != null and _wcell.cover_height >= MCF.WALL_HEIGHT and _wcell.feature_id != MCF.FEATURE_BOUNDARY:
		return
	if fog_on and not visible.has(_fxc) and not visible.has(origin):
		return
	var look: Array = FxDecals.look_of(kind)
	if look.is_empty():
		look = [0.12, Color(0.8, 0.8, 0.8, 0.8)]
	var center := ORIGIN + cell_pos * CELL
	var half: float = float(look[0]) * CELL * float(scale) * 0.5
	var rect := Rect2(center - Vector2(half, half), Vector2(half, half) * 2.0)
	# Обломок стены (0.12.1) — неровный кусок её же плитки.
	if kind.begins_with("chunk:"):
		var parts := FxDecals.chunk_parts(kind)
		var tex := Sprites.texture_of(parts[0])
		if tex != null:
			var pts := PackedVector2Array()
			var uvs := PackedVector2Array()
			# Картинка стены — лента вариантов: середина ПЕРВОЙ плитки, не всей ленты.
			var span := float(tex.get_height()) / maxf(1.0, float(tex.get_width()))
			for q: Vector2 in FxDecals.CHUNK_SHAPES[int(parts[1])]:
				pts.append(center + (q * half).rotated(rot))
				uvs.append(Vector2((0.5 + q.x * 0.2) * span, 0.5 + q.y * 0.2))
			draw_polygon(pts, PackedColorArray([Color.WHITE]), uvs, tex)
			return
	if Sprites.draw_texture_override_rect(self, FxDecals.texture_of_kind(kind), rect,
			rad_to_deg(rot)):
		return
	if kind == "blood_pool":
		# Лужа — овал, а не прямоугольник: рисуем окружностью со сплющиванием.
		draw_set_transform(pan + center * zoom, rot, Vector2(zoom, zoom * 0.62))
		draw_circle(Vector2.ZERO, half, look[1])
		draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
		return
	# Осколок/гильза/капля — вытянутый четырёхугольник, повёрнутый на свой угол.
	var a := Vector2(half, half * 0.45).rotated(rot)
	var b := Vector2(-half, half * 0.45).rotated(rot)
	draw_colored_polygon(PackedVector2Array([
		center + a, center + b, center - a, center - b]), look[1])

## count > 1 — куча тел. Павший боец — СВОЯ картинка, повёрнутая на 90° по часовой
## (batch 17, item 13); без неё — общий corpse.png набок (#21.4), без него — красный круг.
func _draw_corpse(coord: Vector2i, count: int, who: UnitInstance = null) -> void:
	var org := _cell_origin(coord)
	var center := org + Vector2(CELL, CELL) * 0.5
	var own_key := Sprites.resolve(who.stats.id, _owner_suffix(who.owner)) if who != null else ""
	# Сгоревший в огне или прижжённый лучом — обугленный, в бурых тонах (playtest-20).
	var tint := BURNT_TINT if who != null and who.burnt else Color.WHITE
	if own_key != "":
		Sprites.draw_texture_override(self, own_key, org, float(CELL), 90.0, tint)
	elif not Sprites.draw_texture_override(self, "corpse", org, float(CELL), CORPSE_LIE_DEG, tint):
		draw_circle(center, CELL * 0.34, CORPSE_COLOR * tint)
	if count > 1:
		draw_string(ThemeDB.fallback_font, center + Vector2(CELL * 0.16, CELL * 0.3),
			"x%d" % count, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 0.85, 0.85))

## Метка «несёт труп» (#71): кружок цвета трупа (#59) в углу клетки, непрозрачный и
## с чёрной обводкой — иначе на тёмной картинке юнита его не разглядеть. Если трупов
## больше одного, рядом стоит их число (щит даёт +1 к защите за каждый, #6).
func _draw_corpse_marker(at: Vector2, count: int, font: Font) -> void:
	draw_circle(at, 5.0, Color(CORPSE_COLOR, 0.95))
	draw_arc(at, 5.0, 0, TAU, 14, Color(0, 0, 0, 0.85), 1.5)
	if count > 1:
		draw_string(font, at + Vector2(7, 4), str(count),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.9, 0.9))

## Бейдж активационной группы нейтралов (item 15): маленький чёрный квадрат с римской
## цифрой в правом-нижнем углу клетки юнита.
func _draw_group_badge(cell_origin: Vector2, group: int, font: Font) -> void:
	var sz := CELL * 0.34
	var pos := cell_origin + Vector2(CELL - sz - 2.0, CELL - sz - 2.0)
	draw_rect(Rect2(pos, Vector2(sz, sz)), Color(0.05, 0.05, 0.05, 0.92))
	draw_rect(Rect2(pos, Vector2(sz, sz)), Color(0.9, 0.9, 0.9, 0.75), false, 1.0)
	draw_string(font, pos + Vector2(2.0, sz - 3.0), MCF.roman(group),
		HORIZONTAL_ALIGNMENT_CENTER, sz - 3.0, 11, Color(1, 1, 1))

func _draw_pixel_bang(top_left: Vector2) -> void:
	# Пиксель-арт восклицательного знака: столбик + точка. p = размер «пикселя».
	var p := 3.0
	var col := Color(1.0, 0.85, 0.1)
	var shadow := Color(0, 0, 0, 0.6)
	# Тень со сдвигом для читаемости на любом фоне.
	for off in [Vector2(1, 1), Vector2.ZERO]:
		var c: Color = shadow if off != Vector2.ZERO else col
		var b: Vector2 = top_left + off
		# Ствол: 3 «пикселя» по вертикали.
		for i in 3:
			draw_rect(Rect2(b + Vector2(0, i * p), Vector2(p, p)), c)
		# Точка внизу с зазором.
		draw_rect(Rect2(b + Vector2(0, 4 * p), Vector2(p, p)), c)

## Борг (batch 13 B17): квадратная рамка в цвете стороны с оператором внутри (его кружок
## рисует общий проход бойцов поверх), пустой — серая рамка с точкой; бейдж «B» в углу,
## прочность — точками у нижней кромки. Остов — серая рамка с крестом.
## Choosing a shuttle seat (owner, 2026-10-20): the seats are drawn as a grid OVER the hull
## (before, their highlight lay under the shuttle's picture and could not be seen). Free
## seats are lit, the driver's in amber and labelled; taken seats keep a thin outline.
const SEAT_FREE_COLOR := Color(0.4, 0.7, 1.0)
const SEAT_DRIVER_COLOR := Color(1.0, 0.76, 0.22)

func _draw_seat_grid(font: Font) -> void:
	if mode != Mode.VEH_SEAT and mode != Mode.VEH_BOARD_SEAT:
		return
	var pv := state.get_vehicle(veh_board_vid) if mode == Mode.VEH_BOARD_SEAT \
			else resolver.seated_vehicle_of(_selected_unit())
	if pv == null or not pv.seated():
		return
	pv.ensure_seats()
	for i in pv.seats.size():
		var c := pv.seat_cell(i)
		var r := Rect2(_cell_origin(c), Vector2(CELL, CELL)).grow(-2)
		if not item_cells.has(c):
			draw_rect(r, Color(0.75, 0.75, 0.75, 0.55), false, 1.0)
			continue
		var col := SEAT_DRIVER_COLOR if i == Vehicle.DRIVER_SEAT else SEAT_FREE_COLOR
		draw_rect(r, Color(col.r, col.g, col.b, 0.42))
		draw_rect(r, col, false, 2.0)
		if i == Vehicle.DRIVER_SEAT:
			draw_string(font, r.position + Vector2(3, 12), "DRIVER", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(1, 0.95, 0.75))

func _draw_borg(veh: Vehicle, org: Vector2, col: Color, wrecked: bool, dur: int, font: Font) -> void:
	var frame := Rect2(org + Vector2(2, 2), Vector2(CELL - 4, CELL - 4))
	var op := state.get_unit(veh.borg_operator())
	var manned := op != null and op.is_alive()
	var key := Sprites.resolve("borg_wreck" if wrecked else "borg")
	if key != "":
		Sprites.draw_texture_override(self, key, org, float(CELL))
	elif wrecked:
		draw_rect(frame, Color(0.22, 0.22, 0.25))
		draw_rect(frame, Color(0.45, 0.45, 0.5), false, 2.0)
		draw_line(frame.position, frame.end, Color(0.6, 0.3, 0.3), 2.0)
		draw_line(Vector2(frame.position.x, frame.end.y), Vector2(frame.end.x, frame.position.y),
			Color(0.6, 0.3, 0.3), 2.0)
		return
	else:
		var body := col if manned else Color(0.45, 0.47, 0.52)
		draw_rect(frame, body.darkened(0.55))
		draw_rect(frame, body, false, 3.0)
		if not manned:
			draw_circle(org + Vector2(CELL, CELL) * 0.5, 4.0, Color(0.7, 0.72, 0.78))
	draw_string(font, org + Vector2(CELL - 12, 12), "B", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
		Color(1, 1, 1, 0.9))
	for i in maxi(0, dur):
		draw_circle(org + Vector2(6 + i * 7, CELL - 5), 2.5, Color(0.9, 0.9, 0.6))

## Может ли у бойца быть «!» нехватки снаряжения: истративший ЛДФ, оператор (станция) и
## те, кто родился с предметом (то же условие, что в unit_missing_equipment). Остальным незачем спрашивать резолвер каждый кадр.
func _gear_checked(u: UnitInstance) -> bool:
	return u.ldf_wall_used or u.stats.default_item_id != "" \
			or u.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR
func _tag_line(unit: UnitInstance) -> TextLine:
	var tl: Variant = _tag_lines.get(unit.stats.id)
	if tl == null:
		tl = TextLine.new()
		tl.add_string(Sprites.unit_tag(unit.stats.id, unit.stats.display_name), ThemeDB.fallback_font, 16)
		_tag_lines[unit.stats.id] = tl
	return tl
func _sprite_key(unit: UnitInstance) -> String:
	var k := Vector2i(unit.stats.get_instance_id(), unit.owner)
	var hit: Variant = _skey_cache.get(k)
	if hit == null:
		hit = Sprites.resolve(unit.stats.id, _owner_suffix(unit.owner))
		_skey_cache[k] = hit
	return hit

func _owner_suffix(owner_id: int) -> String:
	if state != null and state.roster != null:
		return state.roster.faction_suffix_of(owner_id)
	return "_neutral" if MCF.is_neutral(owner_id) else "_" + Roster.faction_key(owner_id)

## Поворот картинки техники под её фронт. Картинка рисуется «носом вверх»,
## поэтому вправо — это +90°. Без заданного фронта не поворачиваем вовсе.
##
## Угол считаем, а не берём из таблицы четырёх сторон (#96): фронт выбирается из всех
## ВОСЬМИ направлений, и раньше любая диагональ проваливалась в 0° — танк, повёрнутый
## на северо-восток, рисовался смотрящим строго на север. Со стороны это выглядело
## так, будто поворот списал ОД и оставил корпус в прежнем направлении.
func _facing_degrees(facing: Vector2i) -> float:
	if facing == Vector2i.ZERO:
		return 0.0
	return rad_to_deg(Vector2(facing).angle()) + 90.0

## Прижать вектор к ближайшей стороне света (item 2): танк смотрит только
## вверх/вниз/влево/вправо, диагонали не бывает. По доминирующей оси; при равенстве
## приоритет у горизонтали.
func _ortho_dir(d: Vector2i) -> Vector2i:
	if d == Vector2i.ZERO:
		return Vector2i.ZERO
	if absi(d.x) >= absi(d.y):
		return Vector2i(signi(d.x), 0)
	return Vector2i(0, signi(d.y))

## Цвет стороны с точки зрения того, кто смотрит на экран (#93). В сетевой партии
## СВОЯ армия всегда синяя, чужая — красная, кем бы ты ни был — Player A или B;
## в hotseat перспективы нет, поэтому остаётся жёсткая раскладка P1/P2.
func _side_color(side: int) -> Color:
	if MCF.is_neutral(side):
		return NEUTRAL_COLOR
	if MCF.is_wave_slot(side):
		side = state.turns.wave_owner
	# Каждая сторона носит СВОЙ цвет из ростера — всегда (item 16). Прежняя перспектива
	# «своё синее, чужое красное» в сетевой игре на двоих перекрашивала стороны под
	# зрителя и путала, чей это на самом деле цвет (особенно после захвата чужого танка);
	# теперь цвет юнита/машины один и тот же на всех экранах.
	return state.roster.color_of(side)

## Цвет подписи поверх заливки: на светлой (белая сторона) — чёрный, иначе белый.
static func _ink(bg: Color) -> Color:
	return Color.BLACK if bg.get_luminance() > 0.6 else Color.WHITE

func _toggle_heightmap(on: bool) -> void:
	_heightmap = on
	if _height_btn != null: _height_btn.set_pressed_no_signal(on)
	queue_redraw()
