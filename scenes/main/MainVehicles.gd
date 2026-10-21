@abstract
extends "res://scenes/main/MainPresentation.gd"

## Vehicles, drones and stations: their menus, modes and pickers.

# --- Машины (§техника) ---
func _selected_vehicle() -> Vehicle:
	return state.get_vehicle(selected_vehicle_id) if selected_vehicle_id != -1 else null

func _select_vehicle(veh: Vehicle) -> void:
	_group_ids.clear()
	_regroup_ids.clear()
	selected_id = -1
	selected_vehicle_id = veh.id
	veh_move_targets = {}
	veh_disembark_id = -1
	mode = Mode.VEH_MENU
	reach = null
	target_ids = []
	item_cells = []
	_open_vehicle_menu(veh)
	_refresh_info()
	_refresh_component_panel()
	queue_redraw()

func _veh_back_to_menu() -> void:
	var veh := _selected_vehicle()
	if veh != null and veh.alive() and _can_control(veh.owner):
		_select_vehicle(veh)
	elif selected_id != -1:
		# Режим высадки открыт из меню БОЙЦА (пассажир челнока, оператор борга, batch 13):
		# отмена возвращает его меню, а не снимает выделение.
		_back_to_menu()
	else:
		_deselect()

func _open_vehicle_menu(veh: Vehicle) -> void:
	_menu_actions.clear()
	_picker.hide()
	_clear_hint_cell()
	for c in _menu.get_children():
		c.queue_free()
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var vb := _scroll_menu(_menu, spec.get("name", veh.type_id))
	var acting: bool = resolver.vehicle_ap(veh) > 0 and _can_control(veh.owner)

	# Докатить остаток прошлого движения можно и без ОД (#97) — как у пехоты.
	var veh_credit := resolver.vehicle_move_credit(veh)
	if (acting or (veh_credit > 0 and _can_control(veh.owner))) \
			and not veh_move_targets_preview(veh).is_empty():
		var move_btn := Button.new()
		move_btn.text = "Move (%d left)" % veh_credit if veh_credit > 0 else "Move"
		move_btn.pressed.connect(_veh_enter_move)
		vb.add_child(move_btn)
		_register_menu_action(move_btn, "action_move")

	if acting and veh.facing != Vector2i.ZERO:
		var turn_btn := Button.new()
		turn_btn.text = "Turn (%d AP)" % VehicleRules.TURN_COST
		turn_btn.pressed.connect(_veh_enter_turn)
		vb.add_child(turn_btn)
		_register_menu_action(turn_btn, "action_tactical")

	var gun: Dictionary = spec.get("weapons", {}).get("main_gun", {})
	if acting and not gun.is_empty() and resolver.vehicle_ap(veh) >= int(gun.get("ap_cost", 1)) \
			and veh.cannon_shots_this_round < int(gun.get("max_per_turn", 2)):
		var cannon_btn := Button.new()
		cannon_btn.text = "Fire Cannon (%d AP)" % int(gun.get("ap_cost", 1))
		cannon_btn.pressed.connect(_veh_enter_cannon)
		vb.add_child(cannon_btn)
		_register_menu_action(cannon_btn, "action_shoot")

	# Посадка соседней пехоты.
	if _can_control(veh.owner):
		for uid in resolver.vehicle_board_candidates(veh):
			var u := state.get_unit(uid)
			if u == null:
				continue
			var board_btn := Button.new()
			board_btn.text = "Board: %s" % u.stats.display_name
			board_btn.pressed.connect(_veh_board.bind(uid))
			vb.add_child(board_btn)
			_register_menu_action(board_btn, "action_board")

	# Высадка экипажа. Из челнока — бесплатно и через свой борт (batch 13 S7).
	if _can_control(veh.owner) and not veh.occupants.is_empty():
		for uid in veh.occupants:
			var u := state.get_unit(uid)
			if u == null or resolver.vehicle_disembark_cells(veh, uid).is_empty():
				continue
			var dis_btn := Button.new()
			dis_btn.text = "%s: %s" % ["Exit (free)" if veh.seated() else "Disembark", u.stats.display_name]
			dis_btn.pressed.connect(_veh_enter_disembark.bind(uid))
			vb.add_child(dis_btn)
			_register_menu_action(dis_btn, "action_exit")
	# Тела в креслах челнока (batch 13 S10): напоминание, кто держит место.
	if veh.seated():
		for i in veh.seats.size():
			var sid: int = veh.seats[i]
			if sid == Vehicle.SEAT_STATION or sid == Vehicle.SEAT_DPMG:
				var st := Label.new()
				st.text = "Seat %d: %s" % [i + 1, "drone station" if sid == Vehicle.SEAT_STATION else "DPMG"]
				vb.add_child(st)
			elif sid >= 0:
				var b := state.get_unit(sid)
				if b != null and b.status == MCF.Status.CORPSE:
					var bl := Label.new()
					bl.text = "Seat %d: %s's body (drag out from outside)" % [i + 1, b.stats.display_name]
					vb.add_child(bl)

	if not _has_action_button(vb):
		_menu.hide()
		return

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_deselect)
	vb.add_child(cancel_btn)

	_anchor_menu(_menu)
	_menu.show()

## Есть ли куда ехать (для показа кнопки Move без мутаций).
func veh_move_targets_preview(veh: Vehicle) -> Dictionary:
	# Все три зоны, а не одна первая: после хода с остатком первая зона — это сам остаток
	# (пара клеток), и стоило им упереться в стену или край, кнопка Move пропадала при
	# полных ОД экипажа — «танк не ходит в третий раз».
	return resolver.vehicle_move_targets_all(veh)

func _veh_enter_move() -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	# Все три зоны кликабельны (batch ui-drones 2): резолвер спишет 1/2/3 ОД по зоне.
	veh_move_targets = resolver.vehicle_move_targets_all(veh)
	_veh_tiers = resolver.vehicle_tier_budgets(veh)
	mode = Mode.VEH_MOVE
	item_cells = []
	_menu.hide()
	queue_redraw()

func _veh_enter_turn() -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	mode = Mode.VEH_TURN
	item_cells = []
	veh_move_targets = {}
	_menu.hide()
	queue_redraw()

func _veh_enter_cannon() -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	# Подсветку считает сам резолвер (#58, #62, #70): амбразуры со всех трёх клеток
	# борта, дальность и перекрытие линии огня. Дублировать правила здесь нельзя —
	# именно так подсветка когда-то и разошлась с тем, что выстрел реально может.
	var vis := _view_resolver().team_visible_coords(_viewing_side())
	item_cells = resolver.cannon_target_cells(veh, vis)
	mode = Mode.VEH_CANNON
	veh_move_targets = {}
	_menu.hide()
	queue_redraw()

## Индекс кресла челнока по клетке следа; −1 — не кресло.
func _seat_index_at(veh: Vehicle, coord: Vector2i) -> int:
	veh.ensure_seats()
	for i in veh.seats.size():
		if veh.seat_cell(i) == coord:
			return i
	return -1

## Посадка (batch 13 S6): в танк — как раньше; в челнок — игрок выбирает кресло, если
## свободных больше одного, иначе садится в единственное.
func _veh_board(unit_id: int) -> void:
	var veh := _selected_vehicle()
	if veh != null:
		_board_into(unit_id, veh)

## Посадка бойца в машину (batch 14): в танк — сразу; в челнок — ВСЕГДА через выбор
## кресла, чтобы игрок сам решал, садиться за руль или нет (кресло водителя подписано).
func _board_into(unit_id: int, veh: Vehicle) -> void:
	_picker.hide()
	if not veh.seated():
		_submit(VehicleBoardIntent.new(unit_id, veh.id))
		return
	var free := resolver.seat_options(veh)
	if free.is_empty():
		return
	veh_board_id = unit_id
	veh_board_vid = veh.id
	item_cells = []
	for i in free:
		item_cells.append(veh.seat_cell(i))
	mode = Mode.VEH_BOARD_SEAT
	veh_move_targets = {}
	_menu.hide()
	queue_redraw()

## Пересадка пассажира внутри челнока (batch 13 S6, 1 ОД).
func _enter_seat_switch() -> void:
	var u := _selected_unit()
	var veh := resolver.seated_vehicle_of(u)
	if u == null or veh == null or u.remaining_ap <= 0:
		return
	item_cells = []
	for i in resolver.seat_options(veh):
		item_cells.append(veh.seat_cell(i))
	if item_cells.is_empty():
		return
	mode = Mode.VEH_SEAT
	reach = null
	target_ids = []
	_menu.hide()
	queue_redraw()

## Оператор вылезает из борга (batch 13): на свободную соседнюю клетку, 1 ОД.
func _enter_borg_exit() -> void:
	var u := _selected_unit()
	if u == null or u.borg_id == -1 or u.remaining_ap <= 0:
		return
	veh_disembark_id = u.id
	item_cells = []
	for n in state.grid.neighbors(u.coord):
		if not state.grid.blocks_walk(n):
			item_cells.append(n)
	if item_cells.is_empty():
		return
	mode = Mode.VEH_DISEMBARK
	reach = null
	target_ids = []
	_menu.hide()
	queue_redraw()

## Выход пассажира из челнока (batch 13 S7): бесплатно, через свой борт.
func _enter_passenger_exit() -> void:
	var u := _selected_unit()
	var veh := resolver.seated_vehicle_of(u)
	if u == null or veh == null:
		return
	veh_disembark_id = u.id
	item_cells = resolver.vehicle_disembark_cells(veh, u.id)
	if item_cells.is_empty():
		return
	mode = Mode.VEH_DISEMBARK
	reach = null
	target_ids = []
	_menu.hide()
	queue_redraw()

func _veh_enter_disembark(unit_id: int) -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	veh_disembark_id = unit_id
	item_cells = resolver.vehicle_disembark_cells(veh, unit_id)
	mode = Mode.VEH_DISEMBARK
	veh_move_targets = {}
	_menu.hide()
	queue_redraw()

func _pending_shoot(u: UnitInstance) -> bool:
	return u.action_state != null and u.action_state.is_pending()

## A burst with bullets left (0.11): they may go at any valid target, so the Shoot
## button stays available even when the first target is dead or out of sight.
func _valid_pending_shoot(u: UnitInstance) -> bool:
	return _pending_shoot(u) and u.action_state.remaining_shots > 0

func _enter_move() -> void:
	var u := _selected_unit()
	# Двигаться можно за новый ОД, либо доходя остаток текущего действия (#44).
	if u == null or (u.remaining_ap <= 0 and u.move_credit <= 0):
		return
	mode = Mode.MOVE
	# Бюджет обязан совпадать с резолвером, иначе подсвеченные клетки не совпадут
	# с тем, что он примет, и движение «не работает» (§3.4, #42/#44/#65).
	# Один разлив по потолку красной зоны (batch ui-drones): цена клетки от бюджета не
	# зависит, а зона — это первый потолок из move_tier_budgets, в который цена влезла.
	# Клик по оранжевой/красной клетке — тот же MoveIntent, резолвер спишет 2/3 ОД.
	_reach_tiers = resolver.move_tier_budgets(u)
	reach = resolver.reachable_for(u, _reach_tiers[_reach_tiers.size() - 1])
	target_ids = []
	_menu.hide()
	queue_redraw()

func _enter_shoot() -> void:
	var u := _selected_unit()
	if u == null:
		return
	mode = Mode.SHOOT
	reach = null
	item_cells = []
	_melee_veh_ids = []
	# И при незавершённой очереди, и при свежей стрельбе показываем ВСЕ доступные
	# цели: остаток очереди можно дострелить по другой цели (#5).
	if _valid_pending_shoot(u) or u.remaining_ap > 0:
		target_ids = resolver.shootable_target_ids(u)
		# Противотанкист (§3.14) может ещё и ударить по пустой клетке пола.
		if u.attack_ability() == MCF.ABILITY_ANTI_TANK:
			item_cells = resolver.blastable_cells(u)
		# Огнемётчик может пустить струю по пустой клетке пола (в её направлении).
		elif u.attack_ability() == MCF.ABILITY_FLAMETHROWER:
			item_cells = resolver.flammable_cells(u)
		# Шахтёр может ломом бить по соседней вражеской машине (item 15).
		elif u.attack_ability() == MCF.ABILITY_MINER:
			_melee_veh_ids = resolver.meleeable_vehicle_ids(u)
		# Обычный стрелок может разбить окно (batch ui-drones) — клик по стеклу.
		elif (u.remaining_ap > 0 or _pending_shoot(u)) and not _is_marksman(u):
			item_cells = resolver.shootable_window_cells(u)
			item_cells.append_array(resolver.shootable_fixture_cells(u))
	else:
		target_ids = []
	_menu.hide()
	queue_redraw()

func _shoot_ap_cost(u: UnitInstance) -> int:
	return MCF.MARKSMAN_AP_COST if u.attack_ability() == MCF.ABILITY_MARKSMAN else 1

func _is_marksman(u: UnitInstance) -> bool:
	return u != null and u.attack_ability() == MCF.ABILITY_MARKSMAN

## Единая «рука» (#50): в одном режиме и бойцы под захват, и объекты под волочение —
## труп, мешки, ёж, куча земли. Отдельной кнопки Drag больше нет.
func _enter_grab() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.GRAB
	reach = null
	drag_object = Vector2i(-1, -1)
	target_ids = resolver.capturable_target_ids(u)
	# Тела и объекты подсвечиваются вместе — рука одна (#50), — но обрабатываются
	# по-разному: тело поднимается в руки одним кликом (#7), объект волочится за два.
	_corpse_cells = resolver.corpse_pickup_cells(u)
	item_cells = resolver.draggable_cells(u)
	item_cells.append_array(_corpse_cells)
	_menu.hide()
	queue_redraw()

## Перекладывание пленника вокруг носильщика (#100). Свободные соседние клетки
## подсвечиваются теми же средствами, что и клетка сброса при переносе.
func _enter_move_held() -> void:
	var u := _selected_unit()
	if u == null or resolver.held_unit_of(u) == null:
		return
	var cells := resolver.carry_drop_cells(u.coord)
	if cells.is_empty():
		return
	mode = Mode.MOVE_HELD
	reach = null
	target_ids = []
	item_cells = cells
	_menu.hide()
	queue_redraw()

func _enter_item() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0 or resolver.can_use_item(u) != "":
		return
	mode = Mode.ITEM
	reach = null
	target_ids = []
	if u.held_item_id == MCF.ITEM_DRONE_STATION:
		# Станция ставится в соседнюю свободную клетку (§3.12) или в пустое соседнее
		# кресло челнока (batch 13 S8) — список даёт резолвер.
		item_cells = resolver.station_place_cells(u)
	else:
		item_cells = resolver.grenade_target_cells(u)
	_menu.hide()
	queue_redraw()

## Почему дрон сейчас не слушается (issues-12 #10) — та же проверка, что operator_controls.
func _drone_idle_reason(drone: UnitInstance) -> String:
	var op := state.get_unit(drone.operator_id)
	if op == null or not op.is_alive():
		return "Its operator is dead"
	var home := state.grid.cell(drone.home_station)
	if home == null or home.feature_id != MCF.FEATURE_DRONE_STATION:
		return "Its station is gone"
	return "The operator must stand next to the station"

## Дрон завис над стеной (#96/#99) — единственный его ход отсюда бесплатен и ведёт
## обратно на клетку захода.
func _drone_on_wall(u: UnitInstance) -> bool:
	return u != null and u.is_drone and state.grid.in_bounds(u.coord) \
			and state.grid.cell(u.coord).is_wall()

func _enter_drone_fly() -> void:
	var u := _selected_unit()
	if u == null or not u.is_drone:
		return
	# Спуск со стены бесплатен (#99), поэтому «Fly» открывается и на нулевых ОД —
	# иначе дрон оставался бы сидеть на стене до конца раунда.
	# Недолётанный остаток (до 30 клеток за подлёт) тратится без нового ОД.
	if u.remaining_ap <= 0 and u.move_credit <= 0 and not _drone_on_wall(u):
		return
	mode = Mode.DRONE_FLY
	reach = null
	target_ids = []
	item_cells = resolver.drone_flight_cells(u)
	_drone_costs = resolver.drone_flight_costs(u)
	_drone_budget = resolver.drone_flight_budget(u)
	_menu.hide()
	queue_redraw()

## Всё, что стоит на клетке, сверху вниз: дрон висит НАД наземным юнитом (#13, он не
## занимает слот клетки), под ним — живой юнит или труп.
func _stack_at(coord: Vector2i) -> Array[UnitInstance]:
	var out: Array[UnitInstance] = []
	if not state.grid.in_bounds(coord):
		return out
	var drone := _drone_at(coord)
	if drone != null:
		out.append(drone)
	var occ: UnitInstance = state.grid.cell(coord).occupant
	if occ != null:
		out.append(occ)
	return out

## Юнит на клетке для кликов: верхний в стопке — дрон, если он там есть (#23).
func _unit_at(coord: Vector2i) -> UnitInstance:
	var stack := _stack_at(coord)
	return stack[0] if not stack.is_empty() else null

## Кого из стопки берём при повторных кликах: сначала дрон, следующим кликом — тот,
## кто под ним (#23). Только свои активные — иначе выделение снимается.
func _cycle_pick(coord: Vector2i) -> UnitInstance:
	var pickable: Array[UnitInstance] = []
	for u in _stack_at(coord):
		if u.owner == _selection_side() and u.is_on_field() and _can_control(u.owner):
			pickable.append(u)
	if pickable.is_empty():
		return null
	for i in pickable.size():
		if pickable[i].id == selected_id:
			return pickable[(i + 1) % pickable.size()]
	return pickable[0]

func _drone_at(coord: Vector2i) -> UnitInstance:
	for u in state.all_units():
		if u.is_drone and u.is_alive() and u.coord == coord:
			return u
	return null

func _drone_can_ram(coord: Vector2i) -> bool:
	var u := _selected_unit()
	if u == null or not u.is_drone or MCF.is_scout(u) or not state.grid.in_bounds(coord):
		return false
	# Таран — только по другому дрону (как у резолвера, _approach_cell): над стеной и над
	# машиной дрон зависает.
	var other := _drone_at(coord)
	var blocked: bool = other != null and other != u
	if not blocked:
		return false
	if _adjacent8(coord, u.coord):
		return true
	for fc in item_cells:
		if _adjacent8(coord, fc):
			return true
	return false

func _adjacent8(a: Vector2i, b: Vector2i) -> bool:
	var d := (a - b).abs()
	return maxi(d.x, d.y) == 1

## Панель прочности узлов машины (веха «Modular tank system», §9).
##
## Постоянно на экране этих чисел нет: четыре шкалы на каждую машину — это шум, а нужны
## они ровно в тот момент, когда машину выбрали и решают, куда бить или что чинить.
## Поэтому панель живёт скрытой и всплывает над журналом боя при выборе машины.
func _build_component_panel() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(240, 0)
	SteamChrome.apply_panel(panel)
	panel.hide()
	_ui_layer.add_child(panel)
	_comp_panel = panel
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	var header := SteamChrome.header_bar("Vehicle")
	_make_panel_draggable(panel, header, func() -> void: _comp_moved = true)
	frame.add_child(header)
	_comp_body = VBoxContainer.new()
	_comp_body.add_theme_constant_override("separation", 3)
	frame.add_child(SteamChrome.pad(_comp_body, 8, 6))

## Перерисовать панель узлов под текущий выбор. Машина не выбрана — панель прячется.
func _refresh_component_panel() -> void:
	if _comp_panel == null or _comp_body == null:
		return
	var veh := _selected_vehicle()
	if veh == null or state == null:
		_comp_panel.hide()
		return
	for c in _comp_body.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "%s — %s" % [
		VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id), _side_label(veh.owner)]
	title.add_theme_font_size_override("font_size", 12)
	_comp_body.add_child(title)
	for comp: String in MCF.COMPONENT_ORDER:
		if not veh.has_component(comp):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_lbl := Label.new()
		name_lbl.text = String(MCF.COMPONENT_NAMES.get(comp, comp))
		name_lbl.custom_minimum_size = Vector2(74, 0)
		name_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(name_lbl)
		var left: int = veh.component(comp)
		var cap: int = maxi(1, veh.component_max(comp))
		var bar := ProgressBar.new()
		bar.max_value = cap
		bar.value = left
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(80, 12)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bar)
		var num := Label.new()
		num.text = "%d/%d" % [left, cap]
		num.add_theme_font_size_override("font_size", 11)
		# Выбитый узел подписан красным и словом, а не только пустой шкалой: по цвету
		# одному игрок не обязан догадываться, ЧТО именно сломалось.
		if left == 0:
			num.text = "OUT"
			num.add_theme_color_override("font_color", Color(0.95, 0.35, 0.3))
		row.add_child(num)
		_comp_body.add_child(row)
	# Что именно отвалилось — словами, чтобы не держать таблицу в голове.
	var notes: Array[String] = []
	# Разница между «стоит намертво» и «только не едет» для игрока существенная: во
	# втором случае машина ещё разворачивается и может навести орудие.
	if not veh.can_turn():
		notes.append("immobilized")
	elif not veh.can_drive():
		notes.append("cannot drive, can still turn")
	if veh.has_component(MCF.COMP_GUN) and not veh.can_fire_gun():
		notes.append("gun out")
	if veh.tower_jammed():
		notes.append("tower jammed")
	if not notes.is_empty():
		var note := Label.new()
		note.text = ", ".join(notes)
		note.add_theme_font_size_override("font_size", 11)
		note.add_theme_color_override("font_color", Color(0.95, 0.6, 0.35))
		_comp_body.add_child(note)
	_comp_panel.show()
	if not _comp_moved:
		_comp_panel.call_deferred("reset_size")
		call_deferred("_reposition_hud_grip")

## Спросить, по какому УЗЛУ машины бить (веха «Modular tank system», §3.1b).
##
## Выбор обязателен: прицельный выстрел идёт с +1, и «просто выстрелить» — это тот же
## выстрел с названным узлом. Разбитые узлы в список не попадают: по ним нельзя целиться
## и каскад их всё равно пропустит.
##
## on_pick принимает id узла. Панель — та же, что для числа выстрелов: игрок уже знает
## это окно, и второй такой же незачем.
## only — список узлов, которые показывать. Пустой = все ЖИВЫЕ (так стреляют: по
## разбитому узлу целиться нельзя). Ремонт передаёт свой список — там как раз выбитые
## узлы и нужны, иначе чинить было бы нечего.
## from — откуда бьют. Задана, значит список узлов урезается ПО БОРТУ (веха 14.1):
## предлагать прицел в гусеницу, закрытую корпусом, нельзя — резолвер всё равно отдаст
## такой выстрел каскаду, и игрок решил бы, что кнопка врёт.
func _open_component_picker(veh: Vehicle, title: String, on_pick: Callable,
		only: Array = [], from: Vector2i = Vector2i(-9999, -9999)) -> void:
	_menu.hide()
	for c in _picker.get_children():
		c.queue_free()
	var vb := _scroll_menu(_picker, title)
	var visible: Array = resolver._aimable_components(veh, from) if only.is_empty() else only
	for comp: String in MCF.COMPONENT_ORDER:
		if not visible.has(comp):
			continue
		var b := Button.new()
		if only.is_empty():
			var need: int = clampi(
				int(MCF.COMPONENT_NEED.get(comp, 6)) - MCF.COMPONENT_AIM_BONUS, 1, 6)
			b.text = "%s  %d/%d  (%d+)" % [
				MCF.COMPONENT_NAMES.get(comp, comp), veh.component(comp),
				veh.component_max(comp), need]
		else:
			b.text = "%s  %d/%d" % [MCF.COMPONENT_NAMES.get(comp, comp),
				veh.component(comp), veh.component_max(comp)]
		b.pressed.connect(func() -> void:
			_picker.hide()
			_clear_hint_cell()
			on_pick.call(comp))
		vb.add_child(b)
	_number_picker()
	_anchor_menu(_picker)
	_picker.show()

## Первая машина на трассе луча марксмана, до которой он дотянется с уроном (batch 12 #5),
## или null. Трасса — та же, что у предпросмотра и у настоящего выстрела.
func _vehicle_on_beam(shooter: UnitInstance, aim: Vector2i) -> Vehicle:
	if shooter == null or state == null or not state.grid.in_bounds(aim):
		return null
	for rec: Dictionary in resolver.laser_preview(shooter, aim):
		if String(rec["kind"]) != "vehicle":
			continue
		if int(rec["damage"]) <= 0:
			return null
		var veh := state.get_vehicle(int(rec["vehicle_id"]))
		if veh == null or not veh.alive() or veh.live_components().is_empty():
			return null
		return veh
	return null

## Машина под клеткой, если по ней вообще есть смысл выбирать узел.
func _vehicle_at_cell(coord: Vector2i) -> Vehicle:
	if state == null or not state.grid.in_bounds(coord):
		return null
	var vid := state.grid.vehicle_at(coord)
	if vid == -1:
		return null
	var veh := state.get_vehicle(vid)
	return veh if veh != null and veh.alive() and not veh.live_components().is_empty() else null

## Выбор станции для запуска дрона (item 17). Клеток немного (максимум восемь
## соседей), поэтому список — просто кнопки с координатами; подсветка на доске
## показывает те же клетки, что и кнопки.
## Свернуть станцию: одна рядом — сразу, несколько — игрок выбирает какую (issues-12 #3).
## Запуск дрона (fix-7 #7): камикадзе или разведчик. Станций рядом несколько — выбирает
## игрок, а не порядок обхода (item 17).
func _launch_buttons(vb: VBoxContainer, unit: UnitInstance, stations: Array[Vector2i]) -> void:
	var uid := unit.id
	for scout: bool in [false, true]:
		var label := "Launch Scout Drone" if scout else "Launch Kamikaze Drone"
		var act: Callable
		if stations.size() > 1:
			label += " (%d stations)…" % stations.size()
			act = _open_station_picker.bind(stations, "Launch %s From Which Station?" % (
					"Scout Drone" if scout else "Kamikaze Drone"),
					func(st: Vector2i) -> Intent: return SpawnDroneIntent.new(uid, st, scout))
		else:
			act = _submit.bind(SpawnDroneIntent.new(uid, stations[0], scout))
		_act_btn(vb, label, act, unit.remaining_ap > 0, "No action points left",
				"action_launch_scout" if scout else "action_launch")

func _pack_station_action(unit: UnitInstance, cells: Array[Vector2i]) -> Callable:
	if cells.size() == 1:
		return _submit.bind(PickUpStationIntent.new(unit.id, cells[0]))
	var uid := unit.id
	return _open_station_picker.bind(cells, "Pack Up Which Station?",
			func(st: Vector2i) -> Intent: return PickUpStationIntent.new(uid, st))

func _open_station_picker(stations: Array, title := "Launch From Which Station?",
		make := Callable()) -> void:
	_menu.hide()
	for c in _picker.get_children():
		c.queue_free()
	var vb := _scroll_menu(_picker, title)
	for st: Vector2i in stations:
		var b := Button.new()
		b.text = "Station at (%d, %d)" % [st.x, st.y]
		b.pressed.connect(_submit.bind(make.call(st) if make.is_valid()
				else SpawnDroneIntent.new(selected_id, st)))
		_hint_cell(b, st)
		vb.add_child(b)
	_number_picker()
	_anchor_menu(_picker)
	_picker.show()


## A soldier who climbs into a borg is selected at once, and the borg with it (owner,
## 2026-10-20): the pilot stands on the borg's cell and its menu is the borg's. Covers every
## way in — the soldier's menu, the vehicle's, a board pick, a group embark, the network.
func _select_borg_pilot(intent: Intent, result: ActionResult) -> bool:
	if replay != null or not result.ok or not intent is VehicleBoardIntent or _spectator:
		return false
	var pilot := state.get_unit(intent.actor_id)
	if pilot == null or pilot.borg_id == -1 or not _is_own_active(pilot) \
			or not _owner_is_local_human(pilot.owner):
		return false
	_select(pilot)
	return true

func _select_spawned_drone(intent: Intent, result: ActionResult) -> bool:
	if replay != null or not result.ok or not intent is SpawnDroneIntent or _spectator:
		return false
	var drone := state.get_unit(result.spawned_unit_id)
	if not _is_own_active(drone) or not _owner_is_local_human(drone.owner): return false
	_select(drone)
	return true
