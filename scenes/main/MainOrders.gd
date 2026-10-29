@abstract
extends "res://scenes/main/MainVehicles.gd"

## Giving orders: input, selection, the action menu and its modes, group moves, building.

func _advance_group_preview() -> void:
	if mode != Mode.GROUP_MOVE or _animating:
		if is_instance_valid(_group_zone_layer): _group_zone_layer.hide()
		_group_preview = null
		_group_order_pending = Vector2i(-1, -1)
		return
	if _group_order_pending != Vector2i(-1, -1) and _group_order_signature != GroupMovePreview.key(resolver, _group_ids):
		_group_order_pending = Vector2i(-1, -1)
	if _group_preview == null: _group_preview = GroupMovePreview.new()
	var dest := _group_order_pending if _group_order_pending != Vector2i(-1, -1) else _pos_to_cell(get_viewport().get_mouse_position())
	var prior: Array = [_group_preview.revision, _group_preview.target, _group_preview.job.done if _group_preview.job != null else false]
	var ready := _group_preview.sync(resolver, _group_ids, dest, _group_tactical)
	if ready and _group_order_pending != Vector2i(-1, -1):
		var plan := _group_preview.plan()
		_group_order_pending = Vector2i(-1, -1)
		_commit_group_plan(plan)
	elif prior != [_group_preview.revision, _group_preview.target, ready]:
		_redraw()

## Юнит, которым игрок может командовать ПРЯМО СЕЙЧАС как пехотинцем на поле.
## Сидящий в машине — не такой (#95): при посадке его снимают с сетки и ставят
## coord = OFFBOARD, поэтому меню пехоты для него строить нельзя — половина пунктов
## лезет в state.grid.cell(coord) и получает null. Наружу он выходит только через
## Disembark в меню самой машины.
func _is_own_active(u: UnitInstance) -> bool:
	return u != null and u.is_alive() and _on_board(u) \
			and u.owner == state.active_player() and _can_control(u.owner)

## Стоит ли юнит на сетке: экипаж танка вынесен за поле (OFFBOARD), пассажир челнока
## сидит в клетке следа (batch 13) — рисуется, выбирается и стреляет оттуда.
func _on_board(u: UnitInstance) -> bool:
	return u != null and state.grid.in_bounds(u.coord)

func _is_passenger(u: UnitInstance) -> bool:
	return u != null and resolver.seated_vehicle_of(u) != null

## Может ли ЛОКАЛЬНЫЙ игрок командовать этой стороной. Проверка только на networked
## была дырой (#60): в hotseat она пропускала всех, поэтому на ходу ИИ поле
## оставалось кликабельным. Между шагами ИИ есть пауза AI_STEP_DELAY, и чем больше
## у него юнитов, тем дольше ход — игрок успевал открыть меню чужого бойца и
## доиграть ход за компьютер. Мирные (NEUTRAL) тоже не наши: контроллера у них нет.
## Чьих бойцов этот экран выделяет: идущей стороны, если она наша, а в чужой ход — своих
## (fix-7 #18: передать бойцов можно в любой момент, значит и выбрать их — тоже). Меню
## действий в чужой ход не открывается: выбор только для просмотра и передачи.
func _selection_side() -> int:
	if state == null or _spectator or replay != null:
		return -1
	var active := state.active_player()
	if _can_control(active):
		return active
	if networked:
		return my_owner
	for side: int in state.roster.player_ids():
		if _owner_is_local_human(side):
			return side
	return -1

## Остаётся ли боец выделенным: живой, на поле, той стороны, чьих бойцов экран выделяет.
func _keeps_selection(u: UnitInstance) -> bool:
	return u != null and u.is_alive() and _on_board(u) and u.owner == _selection_side() \
			and _can_control(u.owner)

func _can_control(unit_owner: int) -> bool:
	if _spectator: return false
	if networked:
		return unit_owner == my_owner
	return _owner_is_local_human(unit_owner)

# --- Выбор и меню действий ---
func _select(unit: UnitInstance) -> void:
	_group_ids.clear()
	_regroup_ids.clear()
	selected_id = unit.id
	# Выбор пехотинца снимает выбор машины (#97). Без этого selected_vehicle_id оставался
	# от ранее выбранного танка, и _back_to_menu() после действия солдата открывал меню
	# танка вместо меню самого солдата.
	selected_vehicle_id = -1
	veh_move_targets = {}
	veh_disembark_id = -1
	mode = Mode.MENU
	reach = null
	target_ids = []
	item_cells = []
	if unit.owner == state.active_player():
		_open_menu(unit)
	else:
		_menu.hide()
	if _can_control(unit.owner): _bounce(unit.id)
	_refresh_info()
	_redraw()

func _deselect() -> void:
	selected_id = -1
	selected_vehicle_id = -1
	veh_move_targets = {}
	veh_disembark_id = -1
	_group_ids = []
	# Линейка, кисть и ластик — инструменты смотрящего, а не приказ бойцу (batch ui-drones,
	# issues-12 #6): чужой ход, действие ИИ или конец хода их не выключают, только Esc или
	# сама кнопка. Кисть и ластик раньше гасли на каждом чужом действии — посреди штриха.
	if mode not in [Mode.RULER, Mode.DRAW, Mode.ERASE, Mode.FP_PICK]:
		mode = Mode.NONE
	reach = null
	target_ids = []
	item_cells = []
	_menu.hide()
	_picker.hide()
	_clear_hint_cell()
	if _comp_panel != null:
		_comp_panel.hide()  # машину сняли с выбора — панель узлов уходит с ней
	_refresh_info()
	_redraw()

func _back_to_menu() -> void:
	if selected_vehicle_id != -1:
		_veh_back_to_menu()
		return
	var u := state.get_unit(selected_id)
	if _is_own_active(u):
		_select(u)
	else:
		_deselect()

func _selected_unit() -> UnitInstance:
	return state.get_unit(selected_id) if selected_id != -1 else null

# --- RTS-выделение и групповое движение (#18) ---
## Selection is available in neutral action modes for the locally controlled side.
func _box_selectable() -> bool:
	if state == null:
		return false
	# Рамка включается только тумблером «Multi-Select» (#21).
	if _multi_btn == null or not _multi_btn.button_pressed:
		return false
	if _selection_side() < 0:
		return false
	return mode == Mode.NONE or mode == Mode.MENU \
			or mode == Mode.GROUP_MENU or mode == Mode.GROUP_MOVE or mode == Mode.GROUP_LASER

func _on_multi_toggled(pressed: bool) -> void:
	if not pressed:
		_set_group([])
	_box_dragging = false
	_redraw()

## Shift + клик при включённом мульти-выделении: добавить бойца в отряд, а если он там
## уже есть — убрать. Рамка берёт всех подряд в прямоугольнике, и отряд из троих, стоящих
## вразнобой, иначе собирался рамкой в пол-экрана и разбором лишних.
##
## Условия отбора — ДОСЛОВНО те же, что у рамки (_finalize_box): свой, активный, живой,
## не дрон и не в машине. Иначе shift набирал бы в отряд тех, кем отряд всё равно не ходит.
func _shift_pick(coord: Vector2i) -> void:
	var u := _unit_at(coord)
	if u == null or u.owner != _selection_side() or not u.is_alive() \
			or not _can_control(u.owner) or u.is_drone or u.aboard_vehicle_id != -1:
		return
	var ids: Array[int] = _group_ids.duplicate()
	# Один уже выбранный боец — тоже начало отряда: shift по второму собирает пару, а не
	# бросает первого. Без этого собрать отряд можно было только с рамки.
	if ids.is_empty() and selected_id != -1 and selected_id != u.id:
		var cur := state.get_unit(selected_id)
		if cur != null and cur.is_alive() and not cur.is_drone and cur.aboard_vehicle_id == -1:
			ids.append(selected_id)
	if ids.has(u.id):
		ids.erase(u.id)
	else:
		ids.append(u.id)
	_set_group(ids)

## По завершении рамки — собрать своих активных пехотинцев внутри прямоугольника.
func _finalize_box() -> void:
	var a := _box_start_cell
	var b := _pos_to_cell(_box_end_screen)
	var x0 := mini(a.x, b.x)
	var x1 := maxi(a.x, b.x)
	var y0 := mini(a.y, b.y)
	var y1 := maxi(a.y, b.y)
	var ids: Array[int] = []
	if _box_additive: ids.assign(_group_ids)
	if _box_additive and selected_id >= 0 and not ids.has(selected_id):
		var selected := _selected_unit()
		if selected != null and selected.is_alive() and selected.owner == _selection_side() \
				and not selected.is_drone and selected.aboard_vehicle_id == -1:
			ids.append(selected_id)
	for u in state.all_units():
		if u.owner != _selection_side() or not u.is_alive() or not _can_control(u.owner):
			continue
		if u.is_drone or u.aboard_vehicle_id != -1:
			continue
		if u.coord.x >= x0 and u.coord.x <= x1 and u.coord.y >= y0 and u.coord.y <= y1:
			if not ids.has(u.id): ids.append(u.id)
	_set_group(ids)

## Установить выделенную группу. 0 → снять выделение; 1 → обычное меню; ≥2 → меню
## групповых действий (#19).
func _set_group(ids: Array[int]) -> void:
	if ids.is_empty():
		_group_ids = []
		if mode == Mode.GROUP_MENU or mode == Mode.GROUP_MOVE or mode == Mode.GROUP_LASER:
			_deselect()
		return
	if ids.size() == 1:
		_group_ids = []
		_select(state.get_unit(ids[0]))
		return
	_group_ids = ids
	selected_id = -1
	selected_vehicle_id = -1
	mode = Mode.GROUP_MENU
	reach = null
	target_ids = []
	item_cells = []
	_picker.hide()
	_clear_hint_cell()
	if state.get_unit(ids[0]).owner == state.active_player():
		_open_group_menu()
	else:
		_menu.hide()
	_refresh_info()
	_redraw()

## Меню действий для выделенной группы (#19). Пока в нём одно действие — движение;
## остальные приказы отдаются юнитам по отдельности.
func _open_group_menu() -> void:
	_menu_actions.clear()
	_picker.hide()
	for c in _menu.get_children():
		c.queue_free()
	var vb := _scroll_menu(_menu, "%d units selected" % _group_ids.size())

	var move_btn := Button.new()
	move_btn.text = "Move"
	move_btn.pressed.connect(_enter_group_move.bind(false))
	vb.add_child(move_btn)
	_register_menu_action(move_btn, "action_move")

	var tac_btn := Button.new()
	tac_btn.text = "Tactical Move"
	tac_btn.tooltip_text = "Each unit takes the best cover near the clicked cell"
	tac_btn.pressed.connect(_enter_group_move.bind(true))
	vb.add_child(tac_btn)
	_register_menu_action(tac_btn, "action_tactical")

	# Залп лазеров (item 12): все выделенные марксманы бьют в одну сторону.
	if not _group_marksmen().is_empty():
		var volley := Button.new()
		volley.text = "Laser Volley"
		volley.tooltip_text = "Every selected marksman fires the laser in the same direction"
		volley.pressed.connect(func() -> void:
			mode = Mode.GROUP_LASER
			_menu.hide()
			_redraw())
		vb.add_child(volley)
		_register_menu_action(volley, "action_volley")

	# Массовая посадка (item 5): если рядом с выделенными есть машина, в которую хоть
	# кто-то из них может сесть, предлагаем усадить всех разом.
	var gvs := _group_boardable_vehicles()
	if not gvs.is_empty():
		var board_btn := Button.new()
		board_btn.text = "Board Vehicle" if gvs.size() == 1 else "Board… (%d vehicles)" % gvs.size()
		if gvs.size() == 1:
			board_btn.pressed.connect(_group_embark.bind(int(gvs[0].id)))
		else:
			board_btn.pressed.connect(_enter_board_pick.bind(gvs, true))
		vb.add_child(board_btn)
		_register_menu_action(board_btn, "action_board")

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_deselect)
	vb.add_child(cancel_btn)

	_anchor_menu(_menu)
	_menu.show()

## Марксманы выделенной группы, которым хватает ОД на луч (item 12).
func _group_marksmen() -> Array:
	var out: Array = []
	for id in _group_ids:
		var u := state.get_unit(id)
		if _is_marksman(u) and u.is_alive() and u.remaining_ap >= MCF.MARKSMAN_AP_COST:
			out.append(u)
	return out

## Направление залпа (item 12): от середины марксманов к клетке, одно из восьми.
func _volley_dir(coord: Vector2i) -> Vector2i:
	var ms := _group_marksmen()
	if ms.is_empty() or not state.grid.in_bounds(coord):
		return Vector2i.ZERO
	var c := Vector2.ZERO
	for m: UnitInstance in ms:
		c += Vector2(m.coord)
	c /= ms.size()
	var d := Vector2(coord) - c
	if d.length() < 0.5:
		return Vector2i.ZERO
	# Округление угла до ближайшего из восьми направлений.
	var a := snappedf(d.angle(), PI / 4.0)
	return Vector2i(roundi(cos(a)), roundi(sin(a)))

## Залп (item 12): каждый марксман бьёт лучом в одну сторону. Свои на любом из лучей —
## сначала подтверждение (item 13).
func _fire_volley(dir: Vector2i) -> void:
	var ms := _group_marksmen()
	var friends: Array = []
	for m: UnitInstance in ms:
		for f: UnitInstance in _beam_friendlies(m, m.coord + dir):
			if not friends.has(f):
				friends.append(f)
	var fire := func() -> void:
		var ids: Array = []
		for m: UnitInstance in ms:
			ids.append(m.id)
		_regroup_ids = _group_ids.duplicate()
		_set_group([])
		for id: int in ids:
			var m := state.get_unit(id)
			if m != null and m.is_alive():
				_submit(ShootIntent.new(id, -1, -1, m.coord + dir))
	if friends.is_empty():
		fire.call()
	else:
		_confirm_dialog("Friendly units in the beams", _friendly_list_text(friends),
				"Fire anyway", fire)

## Свои и союзные бойцы, которых заденет луч марксмана в сторону aim (item 13): по той же
## трассе, что рисует предпросмотр и по которой пойдёт выстрел.
func _beam_friendlies(shooter: UnitInstance, aim: Vector2i) -> Array:
	var out: Array = []
	if shooter == null or state.roster == null:
		return out
	for rec: Dictionary in resolver.laser_preview(shooter, aim):
		var kind := String(rec["kind"])
		if kind != "unit" and kind != "shield":
			continue
		var occ := _unit_at(rec["coord"])
		if occ != null and occ.is_alive() and occ.id != shooter.id \
				and state.roster.are_allies(shooter.owner, occ.owner):
			out.append(occ)
	return out

func _friendly_list_text(units: Array, head: String = "The laser will pass through:",
		ask: String = "Fire anyway?") -> String:
	var lines: Array[String] = [head]
	for u: UnitInstance in units:
		lines.append("  • %s (%s) at %d, %d" % [u.stats.display_name, _side_label(u.owner),
				u.coord.x, u.coord.y])
	lines.append(ask)
	return "\n".join(lines)

## Подрыв дрона в center (playtest-20): свои и союзники в зоне взрыва — сначала вопрос.
## Зона — та же, что у _drone_explode; укрытия (окоп, щит) не вычитаются: лучше лишний
## раз спросить, чем молча подорвать своих.
func _confirm_blast(drone: UnitInstance, center: Vector2i, intent: Intent) -> void:
	var friends: Array = []
	if drone != null and state.roster != null:
		var area := {}
		for c: Vector2i in MCF.blast_square(center, MCF.ANTI_TANK_BLAST_RADIUS):
			area[c] = true
		for u in state.all_units():
			if u != drone and u.is_alive() and area.has(u.coord) \
					and state.roster.are_allies(drone.owner, u.owner):
				friends.append(u)
	if friends.is_empty():
		_submit(intent)
		return
	_confirm_dialog("Friendly units in the blast", _friendly_list_text(friends,
			"The explosion will hit:", "Detonate anyway?"), "Detonate", _submit.bind(intent))

func _enter_group_move(tactical: bool) -> void:
	_group_tactical = tactical
	mode = Mode.GROUP_MOVE
	_menu.hide()
	_redraw()

## Машины, в которые может сесть хоть один из выделенных юнитов (item 5): все разные,
## в порядке нахождения. Больше одной — игрок выбирает щелчком (BOARD_PICK).
func _group_boardable_vehicles() -> Array:
	var out: Array = []
	var seen := {}
	for id in _group_ids:
		var u := state.get_unit(id)
		if u == null or not u.is_alive() or u.aboard_vehicle_id != -1:
			continue
		for v: Vehicle in resolver.boardable_vehicles(u):
			if not seen.has(v.id):
				seen[v.id] = true
				out.append(v)
	return out

func _enter_board_pick(vehicles: Array, group: bool) -> void:
	_board_pick = vehicles
	_board_pick_group = group
	mode = Mode.BOARD_PICK
	reach = null
	target_ids = []
	item_cells = []
	for v: Vehicle in vehicles:
		item_cells.append_array(_veh_cells(v))
	_menu.hide()
	for child in _picker.get_children(): child.queue_free()
	var vb := _scroll_menu(_picker, "Board Which Vehicle?")
	for vehicle: Vehicle in vehicles:
		var button := Button.new()
		button.text = "%s at (%d, %d)" % [VehicleDB.get_vehicle(vehicle.type_id).get("name", vehicle.type_id), vehicle.origin.x, vehicle.origin.y]
		button.pressed.connect(func() -> void:
			_picker.hide()
			if group: _group_embark(vehicle.id)
			else: _board_into(selected_id, vehicle))
		vb.add_child(button)
	_number_picker()
	_anchor_menu(_picker)
	_picker.show()
	_redraw()

## Клетки машины на поле: след на сетке, а у борга — его клетка.
func _veh_cells(v: Vehicle) -> Array:
	return [v.origin] if v.is_borg() else v.footprint()

func _board_pick_at(coord: Vector2i) -> Vehicle:
	for v: Vehicle in _board_pick:
		if _veh_cells(v).has(coord):
			return v
	return null

## Усадить в машину vid всех выделенных, кто рядом и кому это разрешено (item 5).
## Резолвер сам проверит соседство, вместимость и запреты (щит/трупы — item 19).
func _group_embark(vid: int) -> void:
	var ids := _group_ids.duplicate()
	# Deselect first: a soldier who lands in a borg is selected after its order resolves
	# (_select_borg_pilot), and that must outlast the group order.
	_deselect()
	for id in ids:
		var u := state.get_unit(id)
		if u != null and u.is_alive() and u.aboard_vehicle_id == -1:
			_submit(VehicleBoardIntent.new(id, vid))

## Групповое движение к клетке (#18): раскладку считает GroupMovePlanner. После приказа
## выделение снимается (#19).
func _group_move_to(dest: Vector2i) -> void:
	if not state.grid.in_bounds(dest):
		return
	# Распределение считается ЗДЕСЬ и целиком, а по проводу едет готовый список
	# (item 34). Раньше приказ применялся прямо на месте, минуя namерения, — потому
	# в сети групповое выделение и было выключено: у каждого пира вышло бы своё.
	#
	# Та же раскладка, что и в предпросмотре (§18.3): игрок получает ровно те клетки,
	# кружки которых он видел под курсором.
	# Keep the UI responsive even when a click arrives before the preview is ready.
	if _group_preview == null or _group_preview.target != dest or _group_preview.job == null \
			or not _group_preview.job.done or _group_preview.signature != GroupMovePreview.key(resolver, _group_ids):
		_group_order_pending = dest
		_group_order_signature = GroupMovePreview.key(resolver, _group_ids)
		return
	_commit_group_plan(_group_preview.plan())

func _commit_group_plan(plan: Array) -> void:
	_regroup_ids = _group_ids.duplicate()
	_set_group([])
	_redraw()
	if not plan[0].is_empty():
		_submit(GroupMoveIntent.new(plan[0], plan[1]))

func _enter_push() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.PUSH
	reach = null
	item_cells = resolver.pushable_window_cells(u)
	target_ids = resolver.pushable_target_ids(u)
	_menu.hide()
	_redraw()


func _open_build_picker() -> void:
	var unit := _selected_unit()
	if unit == null or unit.stats.special_ability_id != MCF.ABILITY_ENGINEER: return
	for child in _picker.get_children(): child.queue_free()
	var vb := _scroll_menu(_picker, "Build fortification", func() -> void:
		_picker.hide()
		_back_to_menu())
	for feat in [MCF.FEATURE_SANDBAGS, MCF.FEATURE_WALL, MCF.FEATURE_DOT,
			MCF.FEATURE_DOT_OPEN, MCF.FEATURE_GLASS, MCF.FEATURE_AIRLOCK,
			MCF.FEATURE_LDF, MCF.FEATURE_DPMG, MCF.FEATURE_HEDGEHOG]:
		# Инженер в борге строит партиями (batch 13 B7): цену и остаток даёт резолвер.
		var cost: int = resolver.build_cost_for(unit, feat)
		if resolver.buildable_cells(unit, feat).is_empty():
			continue
		# ЛДФ — одна на всю игру (#40): скрываем кнопку, если уже израсходована.
		if feat == MCF.FEATURE_LDF and unit.ldf_wall_used:
			continue
		var can_afford := unit.remaining_ap >= cost or int(unit.build_credits.get(feat, 0)) > 0
		if feat == MCF.FEATURE_LDF:
			# ЛДФ — цепочка из 6 клеток, «рисуется» вручную (§3.7).
			_act_btn(vb, "Build: LDF wall (%d tiles, %d AP)" % [MCF.LDF_WALL_LENGTH, cost],
					_enter_build_wall, can_afford, "Needs %d AP" % cost)
		else:
			var label := "Build: %s (%d AP)" % [MCF.FEATURE_NAMES[feat], cost]
			if unit.borg_id != -1 and MCF.BORG_BATCH_FEATURES.has(feat):
				var left: int = int(unit.build_credits.get(feat, 0))
				label = "Build: %s (%s)" % [MCF.FEATURE_NAMES[feat],
						("%d left in batch" % left) if left > 0 else "1 AP for %d" % MCF.BORG_BUILD_BATCH]
			_act_btn(vb, label, _enter_build.bind(feat), can_afford, "Needs %d AP" % cost)
	# Прожектор (fix-7 #13): партия на 1 ОД, цвет выбирается до постройки.
	var fl := MCF.FEATURE_FLOODLIGHT
	if not resolver.buildable_cells(unit, fl).is_empty():
		var left: int = int(unit.build_credits.get(fl, 0))
		var fl_label := "Build: Floodlight (%s)" % (("%d left in batch" % left) if left > 0
				else "1 AP for %d" % resolver.build_batch(unit, fl))
		_act_btn(vb, fl_label, _open_floodlight_colors, unit.remaining_ap >= 1 or left > 0, "Needs 1 AP")
	_number_picker()
	_menu.hide()
	_anchor_menu(_picker)
	_picker.show()

## Цвет прожектора — тот же список, что у ламп в редакторе (Furniture.LIGHT_TINTS).
func _open_floodlight_colors() -> void:
	for child in _picker.get_children(): child.queue_free()
	var vb := _scroll_menu(_picker, "Floodlight color", _open_build_picker)
	for i in Furniture.LIGHT_TINTS.size():
		var swatch := Image.create_empty(14, 14, false, Image.FORMAT_RGBA8)
		swatch.fill(Furniture.light_color_of(MCF.FEATURE_FLOODLIGHT, i))
		var b := Button.new()
		b.text = str(Furniture.LIGHT_TINTS[i][0])
		b.icon = ImageTexture.create_from_image(swatch)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var tint := Furniture.make_tint(i, 0)
		b.pressed.connect(func() -> void:
			build_tint = tint
			_picker.hide()
			_enter_build(MCF.FEATURE_FLOODLIGHT))
		vb.add_child(b)
	_number_picker()
	_anchor_menu(_picker)
	_picker.show()

func _enter_build(feature_id: String) -> void:
	var u := _selected_unit()
	# Без ОД строить можно на остатке партии борга (batch 13 B7).
	if u == null or (u.remaining_ap <= 0 and int(u.build_credits.get(feature_id, 0)) <= 0):
		return
	build_feature = feature_id
	mode = Mode.BUILD
	reach = null
	target_ids = []
	# Для мешков/ежа сюда попадают и клетки под ярус поверх уже стоящих мешков (#31).
	item_cells = resolver.buildable_cells(u, feature_id)
	_menu.hide()
	_redraw()

# --- Рисование ЛДФ-стены (§3.7, ЛДФ 1×6) ---
func _enter_build_wall() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.BUILD_WALL
	reach = null
	target_ids = []
	build_feature = MCF.FEATURE_LDF
	_wall_cells = []
	_wall_drawing = false
	# Пул допустимых клеток — весь свободный пол (буду фильтровать по соединению).
	item_cells = resolver.buildable_cells(u)
	_menu.hide()
	_redraw()

## Годится ли клетка как звено формы: свободный пол, не повтор. Первое (опорное)
## звено — соседнее с инженером; каждое следующее должно примыкать ОРТОГОНАЛЬНО к
## уже поставленному (#80) — стена собирается одной связной цепью, без разрывов и
## диагональных «мостиков». Это зеркало проверки резолвера bru_cells_connected().
## ВАЖНО: клетки проверяем по самой сетке, а не по item_cells (кольцо у инженера) —
## иначе ЛДФ можно было ставить лишь вокруг инженера.
func _wall_valid_next(coord: Vector2i) -> bool:
	var u := _selected_unit()
	if u == null:
		return false
	if _wall_cells.has(coord):
		return false
	if not state.grid.in_bounds(coord) or not state.grid.cell(coord).is_buildable():
		return false
	if _wall_cells.is_empty():
		return Combat.distance(u.coord, coord) == 1
	for c: Vector2i in _wall_cells:
		if absi(c.x - coord.x) + absi(c.y - coord.y) == 1:
			return true
	return false

func _wall_try_add(coord: Vector2i) -> void:
	if _wall_cells.size() >= MCF.LDF_WALL_LENGTH:
		return
	if not _wall_valid_next(coord):
		_redraw()
		return
	_wall_cells.append(coord)
	_refresh_undo_btn()
	_redraw()
	if _wall_cells.size() >= MCF.LDF_WALL_LENGTH:
		_wall_commit()

func _wall_undo() -> void:
	if _wall_cells.is_empty():
		_back_to_menu()
		return
	_wall_cells.pop_back()
	_refresh_undo_btn()
	_redraw()

func _wall_commit() -> void:
	if _wall_cells.size() != MCF.LDF_WALL_LENGTH:
		return
	var cells := _wall_cells.duplicate()
	_wall_cells = []   # committed: Undo must undo actions again, not pop a finished drawing
	_submit(BuildWallIntent.new(selected_id, cells))

## Что из мебели стоит вплотную к бойцу: есть ли переносное и сколько ОД просит слом
## (одна цифра или «1–3», если рядом разное).
func _adjacent_furniture(u: UnitInstance) -> Dictionary:
	var out := {"carry": false, "any": false, "ap": ""}
	if u == null or u.is_drone:
		return out
	var lo := 99
	var hi := 0
	for n in state.grid.neighbors(u.coord):
		var fid: String = state.grid.cell(n).feature_id
		if not Furniture.is_furniture(fid):
			continue
		out["any"] = true
		out["carry"] = out["carry"] or Furniture.carriable(fid)
		lo = mini(lo, Furniture.break_ap(fid))
		hi = maxi(hi, Furniture.break_ap(fid))
	out["ap"] = str(lo) if lo == hi else "%d–%d" % [lo, hi]
	return out

## Выбор клетки для действия с мебелью: что подсветить, решает режим.
func _enter_furniture(m: int) -> void:
	var u := _selected_unit()
	if u == null:
		return
	match m:
		Mode.CARRY_FURN:
			item_cells = resolver.furniture_carry_cells(u)
		Mode.PUT_FURN:
			item_cells = resolver.furniture_put_cells(u)
		_:
			item_cells = resolver.furniture_smash_cells(u)
	if item_cells.is_empty():
		return
	mode = m
	reach = null
	target_ids = []
	_menu.hide()
	_redraw()

func _enter_break() -> void:
	var u := _selected_unit()
	if u == null or (u.remaining_ap <= 0 and int(u.build_credits.get(resolver.BREAK_CREDIT, 0)) <= 0):
		return
	mode = Mode.BREAK
	reach = null
	target_ids = []
	item_cells = resolver.breakable_cells(u)
	_menu.hide()
	_redraw()

## Выбор клетки, куда лечь трупу (#72). Раньше кнопка сразу роняла его под ноги, из-за
## чего тело нельзя было положить в нужное место — например, в проём как укрытие (#6).
## Действие бесплатное, поэтому проверки на ОД здесь нет.
func _enter_corpse_drop() -> void:
	var u := _selected_unit()
	if u == null or u.carried_corpses <= 0:
		return
	var cells := resolver.corpse_drop_cells(u)
	if cells.is_empty():
		return
	_pull_vehicle_id = -1
	mode = Mode.CORPSE_DROP
	reach = null
	target_ids = []
	item_cells = cells
	_menu.hide()
	_redraw()

func _enter_pull_body(vid: int) -> void:
	var u := _selected_unit()
	var veh := state.get_vehicle(vid)
	if u == null or veh == null:
		return
	var cells := resolver.unload_corpse_cells(u, veh)
	if cells.is_empty():
		return
	_pull_vehicle_id = vid
	mode = Mode.CORPSE_DROP
	reach = null
	target_ids = []
	item_cells = cells
	_menu.hide()
	_redraw()

## Выбор соседнего шлюза под заварку (#99).
func _enter_weld() -> void:
	var u := _selected_unit()
	if u == null:
		return
	var cells := resolver.weldable_cells(u) + resolver.unweldable_cells(u)
	if cells.is_empty():
		return
	mode = Mode.WELD
	reach = null
	target_ids = []
	item_cells = cells
	_menu.hide()
	_redraw()

## Rounds still in this unit's DPMG burst at that gun (0 — none; a new burst costs 1 AP).
func _dpmg_rounds_left(u: UnitInstance, dpmg_coord: Vector2i) -> int:
	return u.action_state.remaining_shots if u != null and u.action_state != null \
			and u.action_state.dpmg_pending(dpmg_coord) else 0

func _enter_rsp_fire(dpmg_coord: Vector2i) -> void:
	var u := _selected_unit()
	if u == null or (u.remaining_ap <= 0 and _dpmg_rounds_left(u, dpmg_coord) <= 0):
		return
	mode = Mode.DPMG_FIRE
	rsp_active = dpmg_coord
	reach = null
	item_cells = []
	target_ids = resolver.rsp_targets(u, dpmg_coord)
	_menu.hide()
	_redraw()

## Режим установки мин (item 45). Как и копка, живёт на кредите: первая мина тратит
## ОД, остальные бесплатны, пока кредит не кончился.
## av — класть противотанковые мины (item 13). Режим общий, отличается только тем,
## какую мину кладёт клик.
func _enter_mine(av: bool = false) -> void:
	var u := _selected_unit()
	if u == null or (u.remaining_ap <= 0 and u.mine_credits <= 0):
		return
	mode = Mode.MINE
	_mine_av = av
	reach = null
	target_ids = []
	item_cells = resolver.mine_cells(u)
	_menu.hide()
	_redraw()

## Обезвреживание подсвеченных чужих мин рядом (item 13).
func _enter_disarm() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.DISARM
	reach = null
	target_ids = []
	item_cells = resolver.disarmable_mine_cells(u)
	_menu.hide()
	_redraw()

func _enter_dig() -> void:
	var u := _selected_unit()
	if u == null or (u.remaining_ap <= 0 and u.dig_credits <= 0):
		return
	mode = Mode.DIG
	reach = null
	target_ids = []
	dig_trench = Vector2i(-1, -1)
	dig_dirt_a = Vector2i(-1, -1)
	item_cells = resolver.diggable_cells(u)
	_menu.hide()
	_redraw()

func _begin_shoot(target: UnitInstance) -> void:
	var shooter := _selected_unit()
	if shooter == null:
		return
	var available: int
	if _pending_shoot(shooter):
		available = shooter.action_state.remaining_shots
	else:
		available = shooter.rate_of_fire()
	if available <= 1:
		_submit(ShootIntent.new(selected_id, target.id, -1))
		return
	_open_picker(target, available)

## Модальное подтверждение в общем стиле (#51/#1): затемнитель + рамка SteamChrome.
## Окно одноразовое — снимается вместе с ответом, чтобы не копить сироты в слое UI.
func _confirm_dialog(title: String, message: String, ok_text: String,
		on_ok: Callable) -> void:
	var overlay := Control.new()
	overlay.add_to_group("shortcut_modal")
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar(title))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	frame.add_child(SteamChrome.pad(body, 16, 14))
	var msg := Label.new()
	msg.text = message
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size = Vector2(340, 0)
	body.add_child(msg)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(110, 34)
	cancel.pressed.connect(func() -> void: overlay.queue_free())
	row.add_child(cancel)
	var ok := Button.new()
	ok.text = ok_text
	ok.custom_minimum_size = Vector2(130, 34)
	ok.pressed.connect(func() -> void:
		overlay.queue_free()
		on_ok.call())
	row.add_child(ok)
	_ui_layer.add_child(overlay)

# --- Вид от первого лица (fix-7 #9) ---

## Кнопка «First Person»: дальше щелчок по любой знакомой свободной клетке.
func _enter_fp_pick() -> void:
	_deselect()
	mode = Mode.FP_PICK
	_menu.hide()
	state.log.add("Click a free cell your side has seen to walk there in first person (Esc leaves).")
	_redraw()

func _start_first_person(at: Vector2i) -> void:
	mode = Mode.NONE
	_fp_layer = CanvasLayer.new()
	_fp_layer.layer = 60
	add_child(_fp_layer)
	_fp = FirstPerson.new(self, at)
	_fp.left.connect(_end_first_person)
	_fp_layer.add_child(_fp)
	_ui_layer.visible = false
	_fp_board_visibility.clear()
	for child: Node in get_children():
		if child is CanvasItem:
			_fp_board_visibility[child] = child.visible
			child.hide()
	_redraw()
	_send_fp_presence(true)

func _end_first_person() -> void:
	_send_fp_presence(false)
	if _fp_layer != null:
		_fp_layer.queue_free()
	_fp_layer = null
	_fp = null
	for child: Node in _fp_board_visibility:
		if is_instance_valid(child): child.visible = _fp_board_visibility[child]
	_fp_board_visibility.clear()
	_ui_layer.visible = true
	if is_instance_valid(_lighting): _lighting._key.clear()
	_redraw()

## Где потолок: считается раз за партию по доске начала боя — снесённая стена крышу не
## снимает.
func _fp_roof(grid: Grid, env: String) -> PackedByteArray:
	if _fp_roofs.size() != grid.width * grid.height:
		_fp_roofs = FirstPersonBoard.roofed(state.grid, env)
	return _fp_roofs

# --- Передача бойцов (fix-7 #18) ---

## Выделенные бойцы, которых этот экран вправе отдать: живые, свои (одной стороны).
func _giveable_selection() -> Array[int]:
	var ids: Array[int] = []
	if _spectator or replay != null:
		return ids
	var side := -1
	for id: int in (_group_ids if not _group_ids.is_empty() else [selected_id] as Array[int]):
		var u := state.get_unit(id)
		if u == null or not u.is_alive() or u.is_drone:
			continue
		var mine := u.owner == my_owner if networked else (controllers.get(u.owner) != null
				and (controllers[u.owner] as PlayerController).is_local_human())
		if not mine or (side != -1 and u.owner != side):
			continue
		side = u.owner
		ids.append(u.id)
	return ids

## Кнопка «Give Units…»: кому отдать — затем подтверждение.
func _open_give_units() -> void:
	var ids := _giveable_selection()
	if ids.is_empty():
		state.log.add("Select your own soldiers first, then press Give Units.")
		return
	var targets := resolver.give_targets(state.get_unit(ids[0]).owner)
	if targets.is_empty():
		state.log.add("There is no other player to give soldiers to.")
		return
	var w := SteamChrome.overlay_window("Give %d soldier(s) to" % ids.size())
	var root: Control = w["root"]
	root.add_to_group("shortcut_modal")
	root.visibility_changed.connect(func() -> void:
		if not root.visible: root.queue_free())
	var body: VBoxContainer = w["body"]
	for side: int in targets:
		var swatch := Image.create_empty(14, 14, false, Image.FORMAT_RGBA8)
		swatch.fill(_side_color(side))
		var b := Button.new()
		b.text = _side_label(side)
		b.icon = ImageTexture.create_from_image(swatch)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void:
			root.hide()
			_confirm_dialog("Give soldiers", "Give %d soldier(s) to %s? You can't take them back." % [
					ids.size(), _side_label(side)], "Give", _give_units.bind(ids, side)))
		body.add_child(b)
	(w["scroll"] as ScrollContainer).custom_minimum_size = Vector2(388, minf(
			body.get_combined_minimum_size().y + 8.0, get_viewport_rect().size.y - 140.0))
	_ui_layer.add_child(root)
	root.show()

## Передать — в любой момент, и в чужой ход (владелец): мимо очереди хода, без шага ИИ.
func _give_units(ids: Array[int], to_side: int) -> void:
	var intent := GiveUnitsIntent.new(ids, to_side)
	if networked:
		if _net_request_pending or _net_playing:
			state.log.add("Wait for the current action to finish, then give the soldiers.")
			return
		_net_request_pending = not net.is_host
		_deselect()
		net.submit_local(intent)
		return
	var result := resolver.resolve(intent)
	if not result.ok:
		state.log.add("[denied] " + result.reason)
		return
	state.log.publish_result(result)
	for c: PlayerController in controllers.values():
		c.notify_state_changed(state)
	_deselect()
	_refresh_status()
	_redraw()
	_check_match_over()

func _scroll_menu(panel: PanelContainer, title: String = "Actions", back := Callable()) -> VBoxContainer:
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	var lead: Button = null
	if back.is_valid():
		lead = Button.new()
		lead.text = "‹"
		lead.focus_mode = Control.FOCUS_NONE
		lead.custom_minimum_size = Vector2(26, 22)
		lead.add_theme_font_size_override("font_size", 15)
		lead.pressed.connect(back)
		lead.tooltip_text = "Back (%s)" % Keybinds.label("game_cancel")
	frame.add_child(SteamChrome.header_bar(title, null, lead))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 4)
	scroll.add_child(vb)
	frame.add_child(SteamChrome.pad(scroll, 8, 8))
	_cap_scroll_height.call_deferred(scroll, vb)
	return vb

## Под курсором ли какое-либо видимое всплывающее меню (#8).
func _pointer_over_popup(pos: Vector2) -> bool:
	for p in [_menu, _picker, _hud_window, _chat_panel] + get_tree().get_nodes_in_group("board_input_panel"):
		if is_instance_valid(p) and p.is_visible_in_tree() and not p.is_queued_for_deletion() and p.get_global_rect().has_point(pos):
			return true
	return false

func _cap_scroll_height(scroll: ScrollContainer, vb: Control) -> void:
	if not is_instance_valid(scroll) or not is_instance_valid(vb):
		return
	# Меню закреплено в левом верхнем углу (#87): запас снизу — на рамку и поля.
	var cap := get_viewport_rect().size.y - MENU_ANCHOR.y - MENU_CHROME_H
	scroll.custom_minimum_size.y = minf(vb.get_combined_minimum_size().y, maxf(cap, 120.0))
	# Ширина меню известна только теперь — панель узлов машины встаёт правее него.
	call_deferred("_reposition_hud_grip")

## Меню действий всегда живут в левом верхнем углу экрана, а не над юнитом (#87):
## над юнитом они закрывали поле и уезжали за край при зуме.
func _anchor_menu(panel: Control) -> void:
	panel.position = MENU_ANCHOR

func _open_menu(unit: UnitInstance) -> void:
	_menu_actions.clear()
	_picker.hide()
	_clear_hint_cell()
	for c in _menu.get_children():
		c.queue_free()
	var vb := _scroll_menu(_menu, unit.stats.display_name)

	if unit.is_drone:
		# Дрон (§3.12): летать (если оператор у станции) и подрыв.
		# Кнопки есть всегда (issues-12 #10): без них меню без единой кнопки закрывалось, и
		# выбранный дрон выглядел намертво зависшим — теперь видно, ЧТО ему мешает.
		var controllable: bool = resolver.operator_controls(unit)
		var why := "" if controllable else _drone_idle_reason(unit)
		if not controllable:
			var warn := Label.new()
			warn.text = why
			vb.add_child(warn)
		_act_btn(vb, "Descend" if _drone_on_wall(unit)
				else ("Fly (%d left)" % unit.move_credit if unit.move_credit > 0 else "Fly"),
				_enter_drone_fly,
				controllable and (unit.remaining_ap > 0 or unit.move_credit > 0 or _drone_on_wall(unit)),
				why if not controllable else "Drone has no AP left", "action_move")
		if MCF.is_scout(unit):
			pass   # разведчик без заряда (fix-7 #7): подрывать нечего
		elif not controllable:
			_act_btn(vb, "Detonate", Callable(), false, why, "action_shoot")
		else:
			var det_btn := Button.new()
			det_btn.text = "Detonate"
			# Подрыв дрона узел не разыгрывает (§4): игрок указывает, и туда и приходится.
			var under := _vehicle_at_cell(unit.coord)
			if under != null:
				var did := unit.id
				det_btn.pressed.connect(func() -> void:
					_open_component_picker(under, "Detonate on", func(comp: String) -> void:
						_confirm_blast(state.get_unit(did), state.get_unit(did).coord,
								DroneDetonateIntent.new(did, comp))))
			else:
				det_btn.pressed.connect(func() -> void:
					_confirm_blast(unit, unit.coord, DroneDetonateIntent.new(unit.id)))
			vb.add_child(det_btn)
			_register_menu_action(det_btn, "action_shoot")
	elif unit.is_held():
		# Удерживаемый юнит может только пытаться освободиться (§3.4).
		if unit.remaining_ap > 0:
			var release_btn := Button.new()
			release_btn.text = "Break Free (4+)"
			release_btn.pressed.connect(_submit.bind(ReleaseIntent.new(unit.id)))
			vb.add_child(release_btn)
			_register_menu_action(release_btn, "action_shoot")
	elif _is_passenger(unit):
		# Пассажир челнока (batch 13): стреляет со своего кресла, бросает гранаты, ставит
		# станцию в соседнее кресло, пересаживается (1 ОД) и выходит (бесплатно).
		var pveh := resolver.seated_vehicle_of(unit)
		var seat_lbl := Label.new()
		seat_lbl.text = "Driver's seat" if pveh.driver_id() == unit.id else "Passenger seat"
		seat_lbl.add_theme_font_size_override("font_size", 11)
		vb.add_child(seat_lbl)
		var pshoot := "Shoot"
		# The rest of a burst is still just "Shoot" (0.11).
		if _valid_pending_shoot(unit):
			pshoot = "Shoot"
		elif unit.attack_ability() == MCF.ABILITY_MARKSMAN:
			pshoot = "Laser (2 AP)"
		elif unit.attack_ability() == MCF.ABILITY_FLAMETHROWER:
			pshoot = "Flame"
		if unit.fire_range() > 0.0:
			_act_btn(vb, pshoot, _enter_shoot,
					_valid_pending_shoot(unit) or unit.remaining_ap >= _shoot_ap_cost(unit),
					"Laser needs both AP - don't move first" if _is_marksman(unit) else "No action points left", "action_shoot")
		if unit.held_item_id != "" and MCF.ITEM_NAMES.has(unit.held_item_id):
			_act_btn(vb, MCF.ITEM_NAMES.get(unit.held_item_id, "Item"), _enter_item,
					unit.remaining_ap > 0 and resolver.can_use_item(unit) == ""
					and not (unit.held_item_id == MCF.ITEM_DRONE_STATION
						and resolver.station_place_cells(unit).is_empty()), "No action points left", "action_item")
		var pstations := resolver.stations_near(unit)
		if unit.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR \
				and not pstations.is_empty():
			_launch_buttons(vb, unit, pstations)
		_pack_station_button(vb, unit)

		# ДПМГ в кресле (fix-7 #5): инженер ставит его в соседнее свободное кресло, стреляет
		# любой сосед по креслу.
		if unit.stats.special_ability_id == MCF.ABILITY_ENGINEER \
				and not resolver.buildable_cells(unit, MCF.FEATURE_DPMG).is_empty():
			var dcost: int = resolver.build_cost_for(unit, MCF.FEATURE_DPMG)
			_act_btn(vb, "Mount DPMG in a Seat (%d AP)" % dcost, _enter_build.bind(MCF.FEATURE_DPMG),
					unit.remaining_ap >= dcost, "Needs %d AP" % dcost, "action_build")
		var seat_rsp := resolver.rsp_cells(unit, true)
		if not seat_rsp.is_empty():
			var seat_left := _dpmg_rounds_left(unit, seat_rsp[0])
			_act_btn(vb, "Fire DPMG (%d left)" % seat_left if seat_left > 0 else "Fire DPMG",
					_enter_rsp_fire.bind(seat_rsp[0]), unit.remaining_ap > 0 or seat_left > 0,
					"No action points left", "action_dpmg")
		if not resolver.seat_options(pveh).is_empty():
			_act_btn(vb, "Change Seat (1 AP)", _enter_seat_switch, unit.remaining_ap > 0, "No action points left", "action_seat")
		_act_btn(vb, "Exit Shuttle (free)", _enter_passenger_exit,
				not resolver.vehicle_disembark_cells(pveh, unit.id).is_empty(), "No free cell beside your seat", "action_move")
	else:
		# Движение — универсальное действие: кнопка есть всегда, гаснет без ОД и кредита
		# движения (item 27). Накопленный остаток тратится первым, в любой момент хода (#32).
		var move_text := "Move (%d left)" % unit.move_credit if unit.move_credit > 0 else "Move"
		_act_btn(vb, move_text, _enter_move, unit.remaining_ap > 0 or unit.move_credit > 0, "No action points left", "action_move")
		# Оператор борга (batch 13): вылезти наружу — 1 ОД, машина остаётся на клетке.
		if unit.borg_id != -1:
			_act_btn(vb, "Exit Borg (1 AP)", _enter_borg_exit, unit.remaining_ap > 0, "No action points left", "action_exit")

		# Стрельба — тоже всегда присутствует; гаснет, когда не хватает ОД на выстрел.
		var shoot_text := "Shoot"
		# The rest of a burst is still just "Shoot" (0.11).
		if _valid_pending_shoot(unit):
			shoot_text = "Shoot"
		elif unit.attack_ability() == MCF.ABILITY_MARKSMAN:
			shoot_text = "Laser (2 AP)"
		elif unit.attack_ability() == MCF.ABILITY_MINER \
				or unit.attack_ability() == MCF.ABILITY_SHIELD_BEARER:
			shoot_text = "Hit"  # ближний бой (§3.14)
		elif unit.attack_ability() == MCF.ABILITY_FLAMETHROWER:
			shoot_text = "Flame"
		_act_btn(vb, shoot_text, _enter_shoot,
				_valid_pending_shoot(unit) or unit.remaining_ap >= _shoot_ap_cost(unit),
				"Laser needs both AP - don't move first" if _is_marksman(unit) else "No action points left", "action_shoot")

		# Переложить пленника на другую соседнюю клетку — бесплатно (#100). Кнопка
		# появляется, только пока кого-то держим, и ОД не требует: носильщик просто
		# перехватывает тело, не сходя с места.
		if resolver.held_unit_of(unit) != null:
			var shift_btn := Button.new()
			shift_btn.text = "Shift Captive (free)"
			shift_btn.pressed.connect(_enter_move_held)
			vb.add_child(shift_btn)
			_register_menu_action(shift_btn, "action_shift")

		# Одна кнопка на всё, что можно взять руками (#50): боец, труп, мешки, ёж, куча земли.
		if not resolver.capturable_target_ids(unit).is_empty() \
				or not resolver.draggable_cells(unit).is_empty() \
				or not resolver.corpse_pickup_cells(unit).is_empty():
			_act_btn(vb, "Grab", _enter_grab, unit.remaining_ap > 0, "No action points left", "action_grab")

		if not resolver.pushable_target_ids(unit).is_empty():
			_act_btn(vb, "Shield Push", _enter_push, unit.remaining_ap > 0, "No action points left", "action_push")

		# Мебель (§3.15): кнопка — только когда рядом есть то, что она умеет. Тяжёлую мебель
		# волокут из «Grab», как мешки; здесь — унести в руках, поставить и разломать.
		var near_furn := _adjacent_furniture(unit)
		if near_furn["carry"]:
			_act_btn(vb, "Carry Furniture (1 AP)", _enter_furniture.bind(Mode.CARRY_FURN),
					not resolver.furniture_carry_cells(unit).is_empty(),
					"Hands full or no AP left", "action_carry")
		if Furniture.is_furniture(unit.held_item_id):
			_act_btn(vb, "Put Down %s (free)" % Furniture.name_of(unit.held_item_id),
					_enter_furniture.bind(Mode.PUT_FURN),
					not resolver.furniture_put_cells(unit).is_empty(), "No free cell beside you", "action_put")
		if near_furn["any"]:
			_act_btn(vb, "Break Furniture (%s AP)" % near_furn["ap"],
					_enter_furniture.bind(Mode.BREAK),
					not resolver.furniture_smash_cells(unit).is_empty(), "Not enough AP", "action_break")

		if unit.held_item_id != "" and MCF.ITEM_NAMES.has(unit.held_item_id):
			_act_btn(vb, MCF.ITEM_NAMES.get(unit.held_item_id, "Item"), _enter_item,
					unit.remaining_ap > 0 and resolver.can_use_item(unit) == "", "No action points left", "action_item")

		# Оператор дронов: запуск дрона со стоящей рядом станции (§3.12).
		var stations := resolver.stations_near(unit)
		if unit.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR \
				and not stations.is_empty():
			_launch_buttons(vb, unit, stations)

		# Свернуть свою станцию обратно в предмет (item 16).
		_pack_station_button(vb, unit)

		# Инженер: постройка укреплений (§3.7). Кнопка остаётся на месте весь ход (item 27) —
		# гаснет, когда не хватает ОД, а не исчезает; появляется, только если строить есть где.
		if unit.stats.special_ability_id == MCF.ABILITY_ENGINEER:
			_act_btn(vb, "Build…", _open_build_picker, true, "", "action_build")
		# Инженер: заварить соседний шлюз (#99).
		var can_weld := not resolver.weldable_cells(unit).is_empty()
		var can_cut := not resolver.unweldable_cells(unit).is_empty()
		if can_weld or can_cut:
			var weld_btn := Button.new()
			weld_btn.text = "%s Airlock (%d AP)" % ["Weld / Unweld" if can_weld and can_cut else ("Weld" if can_weld else "Unweld"),
					resolver.weld_cost_for(unit)]
			weld_btn.pressed.connect(_enter_weld)
			vb.add_child(weld_btn)
			_register_menu_action(weld_btn, "action_weld")

		# Инженер/шахтёр: слом укреплений (§3.7).
		if not resolver.breakable_cells(unit).is_empty():
			_act_btn(vb, "Demolish Fortification", _enter_break,
					unit.remaining_ap > 0 or int(unit.build_credits.get(resolver.BREAK_CREDIT, 0)) > 0, "No action points left", "action_demolish")

		# Инженер чинит свою машину (веха «Modular tank system», §8): одно очко узлу
		# за 1 ОД. Кнопка на каждую машину рядом — их редко больше одной, а выбирать
		# «какую именно» отдельным окном ради этого не стоит.
		for veh: Vehicle in resolver.repairable_vehicles(unit):
			var fix_btn := Button.new()
			fix_btn.text = "Repair %s (1 AP)" % VehicleDB.get_vehicle(veh.type_id).get(
					"name", veh.type_id)
			var uid := unit.id
			var target_veh := veh
			fix_btn.pressed.connect(func() -> void:
				_open_component_picker(target_veh, "Repair", func(comp: String) -> void:
					_submit(RepairVehicleIntent.new(uid, target_veh.id, comp)),
					resolver.repairable_components(state.get_unit(uid), target_veh)))
			vb.add_child(fix_btn)
			_register_menu_action(fix_btn, "action_repair")

		# Отдельной кнопки «подобрать труп» больше нет (#7): тело поднимается из режима
		# «рука» кликом по клетке, как и всё остальное, что можно взять.
		# Положить несомый труп на СОСЕДНЮЮ клетку (#6, #72); под себя нельзя (#10).
		if unit.carried_corpses > 0 and not resolver.corpse_drop_cells(unit).is_empty():
			var drop_btn := Button.new()
			drop_btn.text = "Drop Corpse (carrying %d/%d)" % [
					unit.carried_corpses, MCF.CORPSE_CARRY_MAX]
			drop_btn.pressed.connect(_enter_corpse_drop)
			vb.add_child(drop_btn)
			_register_menu_action(drop_btn, "action_drop")

		# ДПМГ (§3.7): стрельба из своего пулемёта рядом.
		var own_rsp := resolver.rsp_cells(unit, true)
		if not own_rsp.is_empty():
			var rsp_left := _dpmg_rounds_left(unit, own_rsp[0])
			_act_btn(vb, "Fire DPMG (%d left)" % rsp_left if rsp_left > 0 else "Fire DPMG",
					_enter_rsp_fire.bind(own_rsp[0]), unit.remaining_ap > 0 or rsp_left > 0,
					"No action points left", "action_dpmg")
		# Отобрать вражеский ДПМГ (по правилу захвата).
		var foe_rsp := resolver.rsp_cells(unit, false)
		if not foe_rsp.is_empty():
			_act_btn(vb, "Seize DPMG",
					_submit.bind(DPMGFireIntent.new(unit.id, foe_rsp[0], -1, -1)),
					unit.remaining_ap > 0, "No action points left", "action_seize")

		# Сапёр (item 45): мины и их поиск.
		if unit.stats.special_ability_id == MCF.ABILITY_SAPPER:
			if not resolver.mine_cells(unit).is_empty():
				var mine_text := "Lay Mine" if unit.mine_credits <= 0 \
					else "Lay Mine (%d left)" % unit.mine_credits
				_act_btn(vb, mine_text, _enter_mine.bind(false),
						unit.remaining_ap > 0 or unit.mine_credits > 0, "No action points left", "action_mine")
				# Противотанковая мина (item 13) — тот же кредит на серию, другая мина.
				_act_btn(vb, "Lay Anti-Vehicle Mine", _enter_mine.bind(true),
						unit.remaining_ap > 0 or unit.mine_credits > 0, "No action points left", "action_av_mine")
			_act_btn(vb, "Sweep for Mines (%d tiles)" % MCF.MINE_REVEAL_RADIUS,
					_submit.bind(RevealMinesIntent.new(unit.id)), unit.remaining_ap > 0, "No action points left", "action_sweep")
			# Обезвредить подсвеченную чужую мину рядом (item 13).
			if not resolver.disarmable_mine_cells(unit).is_empty():
				_act_btn(vb, "Disarm Mine", _enter_disarm, unit.remaining_ap > 0, "No action points left", "action_disarm")

		# Копка окопа (§3.7): пехота 3 окопа / инженер 6 за 1 ОД.
		if not resolver.diggable_cells(unit).is_empty():
			var dig_text := "Dig Trench" if unit.dig_credits <= 0 \
				else "Dig Trench (%d free)" % unit.dig_credits
			_act_btn(vb, dig_text, _enter_dig,
					unit.remaining_ap > 0 or unit.dig_credits > 0, "No action points left", "action_dig")

		# Посадка в стоящую рядом технику (свою или вражескую). Машин рядом несколько —
		# одна кнопка, а какую именно, игрок выбирает щелчком по полю (batch borg-corpses):
		# раньше выходили одинаковые «Board Tank», и не понять было, какая куда.
		var boardable: Array = resolver.boardable_vehicles(unit)
		if boardable.size() > 1:
			var any_free := false
			for bv: Vehicle in boardable:
				any_free = any_free or bv.seated() or bv.is_borg()
			_act_btn(vb, "Board… (%d vehicles)" % boardable.size(),
					_enter_board_pick.bind(boardable, false), unit.remaining_ap > 0 or any_free, "No action points left", "action_board")
		for veh: Vehicle in (boardable if boardable.size() == 1 else []):
			var vname: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
			var seat_text := "Board %s" % vname if veh.owner == unit.owner \
				else "Storm %s" % vname
			_act_btn(vb, seat_text, _board_into.bind(unit.id, veh),
					unit.remaining_ap > 0 or veh.seated() or veh.is_borg(), "No action points left", "action_board")  # бесплатно (batch 17)

		# Вытащить труп из машины, чтобы освободить место (item 18).
		for vid: int in resolver.unloadable_corpse_vehicle_ids(unit):
			var uveh: Vehicle = state.get_vehicle(vid)
			if uveh != null:
				_act_btn(vb, "Pull Corpse from %s" % VehicleDB.get_vehicle(uveh.type_id).get("name", uveh.type_id),
						_enter_pull_body.bind(vid), unit.remaining_ap > 0, "No action points left", "action_pull")

	# Выдохшемуся юниту меню не нужно (#97): когда ОД кончились и ни одного действия не
	# набралось, панель с одной кнопкой Cancel только загораживает поле. Выделение при
	# этом держим — по нему читается строка характеристик, а снимается оно щелчком мимо.
	if not _has_action_button(vb):
		_menu.hide()
		return

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_deselect)
	vb.add_child(cancel_btn)

	_anchor_menu(_menu)
	_menu.show()

## Кнопка действия с СТАБИЛЬНОЙ формой меню (item 27). Раньше каждая кнопка сама
## пряталась, как только кончались ОД, и меню на втором действии осыпалось до пары
## строк, а то и скрывалось целиком. Теперь недоступное сейчас действие остаётся
## кнопкой, но выключенной, с подсказкой-причиной — набор пунктов не «мигает» весь ход.
func _act_btn(vb: VBoxContainer, text: String, cb: Callable,
		enabled: bool, reason := "No action points left", key := "") -> void:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	if enabled:
		b.pressed.connect(cb)
	else:
		b.tooltip_text = reason
	vb.add_child(b)
	if not key.is_empty(): _register_menu_action(b, key)

func _has_action_button(vb: VBoxContainer) -> bool:
	for c in vb.get_children():
		if c is Button:
			return true
	return false

func _open_picker(target: UnitInstance, available: int) -> void:
	_open_shot_picker(target.stats.display_name, available,
			func(n: int) -> Intent: return ShootIntent.new(selected_id, target.id, n))

## Сколько пуль выпустить (по бойцу или по окну): make(n) строит намерение, n = −1 — все.
func _open_shot_picker(what: String, available: int, make: Callable) -> void:
	_menu.hide()
	for c in _picker.get_children():
		c.queue_free()
	var vb := _scroll_menu(_picker, "Shots at %s" % what)
	var row := HBoxContainer.new()
	vb.add_child(row)
	for n in range(1, available + 1):
		var b := Button.new()
		b.text = str(n)
		b.pressed.connect(func() -> void: _submit(make.call(n)))
		row.add_child(b)
	var all_btn := Button.new()
	all_btn.text = "All (%d)" % available
	all_btn.pressed.connect(func() -> void: _submit(make.call(-1)))
	vb.add_child(all_btn)
	_number_picker()
	_anchor_menu(_picker)
	_picker.show()

## Показывать ли в логе то, что сделал этот ход. Под туманом ход ВРАЖЕСКОГО бойца,
## которого игрок не видит, в лог не идёт вовсе — ни строкой, ни броском кубика: иначе
## текст рассказывает ровно то, что туман прячет («Rifleman fires at…» с именем и
## результатом), и прятать юнит на доске становится бессмысленно.
##
## Ход виден, если видна клетка, ОТКУДА он начался, или та, где боец оказался: шаг из
## темноты на свет игрок действительно видит. Строки без автора (конец хода, пожар,
## нейтралы) показываются всегда — у них actor_owner = −1.
## Видит ли зритель клетку ПРЯМО СЕЙЧАС (не «помнит»). Без тумана видно всё.
## Связать кнопку выбора с клеткой на доске: наведение зажигает её, уход — гасит.
## Годится любому списку, который выбирает КЛЕТКУ, а не только станциям.
func _hint_cell(b: Button, c: Vector2i) -> void:
	b.mouse_entered.connect(func() -> void:
		_hover_cell = c
		_redraw())
	b.mouse_exited.connect(func() -> void:
		if _hover_cell == c:
			_hover_cell = Vector2i(-1, -1)
			_redraw())

## Погасить подсветку выбора (список закрылся — наводиться больше не на что).
func _clear_hint_cell() -> void:
	if _hover_cell != Vector2i(-1, -1):
		_hover_cell = Vector2i(-1, -1)
		_redraw()

func _register_menu_action(button: Button, id: String) -> void:
	button.set_meta("action_label", button.text)
	if not _menu_actions.has(id): _menu_actions[id] = {"buttons": [], "code": 0}
	_menu_actions[id].buttons.append(button)
	_refresh_menu_hotkeys()

func _refresh_menu_hotkeys() -> void:
	if is_instance_valid(_undo_draw_shortcut_btn):
		_undo_draw_shortcut_btn.tooltip_text = "Take back your last stroke or erase (%s while drawing)." % Keybinds.label("game_undo")
	var reserved: Array = []
	for id: String in _menu_actions: reserved.append_array(Keybinds.codes(id))
	for entry: Dictionary in Keybinds.DEFINITIONS:
		if entry.section == "game" and entry.contexts.has("*"):
			reserved.append_array(Keybinds.codes(entry.id))
	var used: Array = []
	for id: String in _menu_actions:
		var code: int = Keybinds.codes(id)[0]
		if used.has(code):
			code = 0
			for letter in range(KEY_A, KEY_Z + 1):
				if not reserved.has(letter) and not used.has(letter):
					code = letter
					break
		used.append(code)
		_menu_actions[id].code = code
		for button: Button in _menu_actions[id].buttons:
			if not is_instance_valid(button): continue
			button.text = str(button.get_meta("action_label"))
			if code != 0: button.text += "  [%s]" % Keybinds.key_event(code).as_text()

func _activate_menu_action(id: String) -> void:
	var buttons: Array = _menu_actions[id].buttons
	var enabled := buttons.filter(func(b: Button) -> bool: return is_instance_valid(b) and not b.disabled)
	if enabled.is_empty(): return
	if buttons.size() == 1:
		buttons[0].pressed.emit()
		return
	_menu.hide()
	for child in _picker.get_children(): child.queue_free()
	var vb := _scroll_menu(_picker, Keybinds.definition(id).label)
	for source: Button in buttons:
		var button := Button.new()
		button.text = str(source.get_meta("action_label"))
		button.disabled = source.disabled
		button.tooltip_text = source.tooltip_text
		button.pressed.connect(func() -> void:
			_picker.hide()
			if is_instance_valid(source) and not source.disabled: source.pressed.emit())
		vb.add_child(button)
	_number_picker()
	_anchor_menu(_picker)
	_picker.show()

func _collect_picker_buttons(node: Node) -> void:
	if node.is_queued_for_deletion(): return
	if node is Button and node.text not in ["Cancel", "‹", "◢", "×"] and node.name != "ResizeGrip": _number_choices.append(node)
	for child in node.get_children(): _collect_picker_buttons(child)

func _number_picker() -> void:
	_number_choices.clear()
	_number_page = 0
	_collect_picker_buttons(_picker)
	for button: Button in _number_choices: button.set_meta("choice_label", button.text)
	if _number_choices.size() > 9:
		var row := HBoxContainer.new()
		_number_choices[0].get_parent().add_child(row)
		for direction in [-1, 1]:
			var button := Button.new()
			button.text = "Previous choices" if direction < 0 else "Next choices"
			button.tooltip_text = Keybinds.label("picker_previous" if direction < 0 else "picker_next")
			button.pressed.connect(_change_choice_page.bind(direction))
			row.add_child(button)
	_refresh_choice_labels()

func _change_choice_page(direction: int) -> void:
	_number_page = clampi(_number_page + direction, 0, maxi(0, (_number_choices.size() - 1) / 9))
	_refresh_choice_labels()

func _refresh_choice_labels() -> void:
	for i in _number_choices.size():
		var button := _number_choices[i]
		if not is_instance_valid(button): continue
		button.visible = i / 9 == _number_page
		button.text = "%d. %s" % [i % 9 + 1, button.get_meta("choice_label")]

# _input precedes GUI focus traversal: Tab and replay Space/arrows must not activate
# a previously focused HUD button. Text fields retain gameplay input; the console's
# function-key shortcut is handled explicitly below. Modal windows retain input.
func _input(event: InputEvent) -> void:
	# Keep release cleanup in the shared handler: overriding _input in Main would
	# bypass shortcuts and let F2 fall through to the editor Manual binding.
	if event is InputEventMouseButton and not event.pressed \
			and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		_mouse_panning = false
	var viewport := get_viewport()
	if event is InputEventKey and _handle_shortcut(event) and is_instance_valid(viewport):
		viewport.set_input_as_handled()

func _handle_shortcut(event: InputEventKey) -> bool:
	if not event.pressed or event.echo or _fp != null: return false
	var console_key := Keybinds.matches(event, "game_cheats")
	# Function keys can open the console from chat/search fields. Printable
	# rebound keys still belong to the field, as do all other gameplay shortcuts.
	if Keybinds.typing(get_viewport()) and not (console_key \
			and event.keycode >= KEY_F1 and event.keycode <= KEY_F35): return false
	if _quit_dialog != null and _quit_dialog.visible:
		if Keybinds.matches(event, "game_cancel"):
			_quit_dialog.hide()
			return true
		return false
	if Keybinds.modal_open(): return false
	if console_key:
		if is_instance_valid(_cheat_console):
			if _cheat_console.input.has_focus() and not _cheat_console.tool.is_empty():
				_cheat_console.cancel_tool()
			else:
				_cheat_console.queue_free()
			return true
		# Opens with cheats off too; its commands then refuse (owner, 0.14.4).
		if replay == null and not _spectator and _fp == null and CheatAccess.seated(state, CheatAccess.console_side(self)):
			_cheat_console = CheatConsole.open(self)
		return true
	if Keybinds.matches(event, "game_cancel"):
		if is_instance_valid(_cheat_console):
			if not _cheat_console.tool.is_empty(): _cheat_console.cancel_tool()
			else: _cheat_console.queue_free()
			return true
		if _init_overlay != null and _init_overlay.visible: _init_overlay.hide()
		else: _escape_pressed()
		return true
	if Keybinds.matches(event, "game_initiative"):
		_toggle_initiative_overlay()
		return true
	if _init_overlay != null and _init_overlay.visible: return false
	if Keybinds.matches(event, "game_pause_ai"):
		_toggle_pause()
		return true
	if Keybinds.matches(event, "game_heightmap"):
		_toggle_heightmap(not _heightmap)
		return true
	if replay != null:
		if Keybinds.matches(event, "replay_play_pause"): _replay_toggle(); return true
		if Keybinds.matches(event, "replay_forward"): _replay_step(); return true
		if Keybinds.matches(event, "replay_back"): _replay_seek(replay.index - 1); return true
	else:
		if Keybinds.matches(event, "game_save"): _save_game(); return true
		if Keybinds.matches(event, "game_undo"):
			if not _animating:
				if mode in [Mode.DRAW, Mode.ERASE]: _undo_my_drawing()
				else: _on_undo_pressed()
			return true
		if Keybinds.matches(event, "game_redo"):
			if mode not in [Mode.DRAW, Mode.ERASE]: _on_redo_pressed()
			return true
	if Keybinds.matches(event, "game_remove_point"):
		if mode == Mode.RULER:
			if _ruler_a != Vector2i(-1, -1): _ruler_a = Vector2i(-1, -1)
			else: _remove_my_last_ruler()
			_refresh_ruler_button()
			_redraw()
			return true
		if mode == Mode.BUILD_WALL and not _animating: _wall_undo(); return true
	if mode == Mode.BUILD_WALL and not _animating and Keybinds.matches(event, "game_confirm_wall"):
		_wall_commit()
		return true
	if _animating or replay != null or not _my_turn() or _match_over: return false
	if Keybinds.matches(event, "game_end_turn"):
		_on_end_turn_pressed()
		return true
	if Keybinds.matches(event, "game_multiselect") and not (_menu.visible and _menu_actions.has("action_seat")):
		if _multi_btn != null and not _multi_btn.disabled:
			_multi_btn.button_pressed = not _multi_btn.button_pressed
		return true
	if _picker != null and _picker.visible:
		if Keybinds.matches(event, "picker_previous"): _change_choice_page(-1); return true
		if Keybinds.matches(event, "picker_next"): _change_choice_page(1); return true
		if not event.ctrl_pressed and not event.alt_pressed and not event.shift_pressed and not event.meta_pressed:
			var number := -1
			if event.keycode >= KEY_1 and event.keycode <= KEY_9: number = event.keycode - KEY_1
			if event.keycode >= KEY_KP_1 and event.keycode <= KEY_KP_9: number = event.keycode - KEY_KP_1
			if number >= 0:
				var index := _number_page * 9 + number
				if index < _number_choices.size():
					var button := _number_choices[index]
					if is_instance_valid(button) and button.is_visible_in_tree() and not button.disabled: button.pressed.emit()
				return true
		return false
	if _menu == null or not _menu.visible: return false
	for id: String in _menu_actions:
		if event.get_keycode_with_modifiers() == _menu_actions[id].code:
			_activate_menu_action(id)
			return true
	return false

## Keep packing discoverable even when a drone is away, hands are full, or AP is spent.
func _pack_station_button(vb: VBoxContainer, unit: UnitInstance) -> void:
	if unit.stats.special_ability_id != MCF.ABILITY_DRONE_OPERATOR:
		return
	var nearby := resolver.stations_near(unit)
	if nearby.is_empty(): return
	var usable := resolver.station_pickup_cells(unit)
	var choices: Array[Vector2i] = usable if not usable.is_empty() else nearby
	var reason := resolver.can_pick_up_station(unit, choices[0])
	var label := "Pack Up Drone Station (%d)" % choices.size() if choices.size() > 1 else "Pack Up Drone Station"
	_act_btn(vb, label, _pack_station_action(unit, choices),
			not usable.is_empty(), reason, "action_pack")

func _cheat_result(intent: Intent, result: ActionResult) -> void:
	if not intent is CheatIntent: return
	var mine: bool = net == null or intent.issuer == net.my_owner
	if mine and is_instance_valid(_cheat_console):
		_cheat_console.write(result.cheat_output if result.ok else result.reason, "" if result.ok else "error")
	if not result.ok: return
	if intent.op == "ai_personality" and (net == null or net.is_host):
		_make_side(intent.args.owner)
	if intent.op in ["ai_pause", "ai_resume", "ai_step"] and (net == null or net.is_host):
		if intent.op == "ai_step": _cheat_ai_steps[int(intent.args.owner)] = 1
		else: _cheat_ai_steps.erase(int(intent.args.owner))
		_kick_if_ai.call_deferred()
	if intent.op == "ai_speed": _set_ai_speed(GameConfig.ai_speed, false)
	if intent.op.begins_with("world_") or intent.op.begins_with("vision_"):
		# Force cached floor, fog and lighting presentation to adopt edited state.
		_lod_terrain_key = []
		GridCell.reset_vision_log()
		UnitInstance.bump_world_vision()
	_redraw()
