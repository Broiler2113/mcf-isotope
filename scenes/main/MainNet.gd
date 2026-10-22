@abstract
extends "res://scenes/main/MainReplay.gd"

## Multiplayer: the session, the host's and guests' messages, reclaims, sides handed to
## the AI or back, desync reports.

func _on_net_applied(intent: Intent, result: ActionResult) -> void:
	_cheat_result(intent, result)
	_net_request_pending = false
	_menu.hide()
	_picker.hide()
	_clear_hint_cell()
	if not result.ok:
		if _result_is_audible(result):   # issues-12 #5
			state.log.add("[denied] " + result.reason)
		# Отказ ИИ-стороне на хосте (batch 12 #15): снять актёра с очереди и вести дальше,
		# иначе ИИ подал бы то же намерение снова.
		var denied_ctrl: PlayerController = controllers.get(state.active_player())
		if denied_ctrl != null and denied_ctrl is AIController:
			_ai_denied_streak += 1
			denied_ctrl.notify_intent_denied(state)
			if _ai_denied_streak >= AI_MAX_DENIED:
				_ai_denied_streak = 0
				_on_intent_ready(EndTurnIntent.new())
				return
			_queue_ai_step(denied_ctrl)
			return
		_after_action()
		return
	# По одному (batch 12 #15): пока крутятся кубики предыдущего действия, следующее
	# ждёт — состояние уже применено резолвером, задерживается только показ.
	_net_queue.append([intent, result])
	if _net_playing:
		return
	_net_playing = true
	while not _net_queue.is_empty():
		var item: Array = _net_queue.pop_front()
		await _show_net_action(item[0], item[1])
	_net_playing = false
	_grant_reclaims()
	_drain_net_messages.call_deferred()
	# Ход мог перейти к ИИ-слоту, которого ведёт хост.
	_kick_if_ai()

## Показ одного сетевого действия — тем же порядком, что и местного в _on_intent_ready
## (batch 12 #15): сначала кубики, затем вспышки, полёт и попадание; откат/повтор
## переставляют доску целиком. Раньше сетевой путь ничего из этого не делал, и по сети
## бой шёл без единой капли крови.
func _show_net_action(intent: Intent, result: ActionResult) -> void:
	_ai_denied_streak = 0
	if intent is UndoIntent or intent is RedoIntent:
		_resync_after_restore()
		return
	if not result.dice_events.is_empty():
		# Убитых мирными держим на карте живыми до конца анимации (#46, #96): передача
		# хода везёт с собой весь слот жителей, и без этого трупы легли бы разом,
		# ещё до первого кубика.
		_pending_death_ids.clear()
		for id: int in result.visual_deaths:
			_pending_death_ids[id] = true
		_hold_visual = result.visual_hold
		queue_redraw()
		var walker := state.get_unit(intent.actor_id) if intent != null else null
		var own_ctrl: PlayerController = controllers.get(walker.owner) if walker != null else null
		if own_ctrl != null and own_ctrl.is_local_human() and _walks_only(result.dice_events):
			_play_walks_free(result.dice_events)   # your own soldier walking: stay live (0.11)
		else:
			_fx.preview_lanes(result.fx)   # who fires at whom shows while the dice roll
			await _play_dice(result.dice_events, not _result_is_audible(result))
	await _show_effects(result)
	if _result_is_audible(result):
		state.log.publish_result(result)
	for c in controllers.values():
		c.notify_state_changed(state)
	_refresh_status()
	queue_redraw()
	if _check_match_over():
		return
	if not _select_spawned_drone(intent, result) and not _select_borg_pilot(intent, result):
		_after_action()

## Подхватить связь, налаженную во вкладке Multiplayer главного меню (#54).
## Своих кнопок Host/Join у боя больше нет: сюда приезжает уже готовая сессия.
## Пакеты, пришедшие пока сцена строилась, лежат в буфере сессии — attach() их отдаёт.
func _adopt_network() -> void:
	var s := NetHandoff.take()
	if s == null:
		return
	session = s
	session.in_match = true
	_roll_seq = session.roll_sequence_on_join
	_roll_inbox = session.roll_acks_on_join.duplicate()
	session.roll_acks_on_join.clear()
	if not NetHandoff.is_host and not _spectator:
		RejoinStore.remember(session.join_route, session.client_token)
	session.message.connect(_on_net_message)
	session.disconnected.connect(_on_net_disconnected)
	if NetHandoff.is_host:
		session.peer_left.connect(_on_peer_left)
	_on_peer_ready(NetHandoff.is_host)
	session.attach()

func _on_peer_ready(is_host: bool) -> void:
	networked = true
	# Своя сторона — слот с моим сетевым номером из ростера лобби (batch 12 #8);
	# дуэльная раскладка «хост — первый, гость — второй» остаётся запасной.
	var mine := state.roster.side_of_peer(session.my_peer_id()) if state.roster != null else -1
	if _spectator:
		mine = -2
	elif mine < 0:
		mine = MCF.Owner.PLAYER_1 if is_host else MCF.Owner.PLAYER_2
	my_owner = mine
	net = NetGame.new(state, resolver, is_host, my_owner)
	if is_host:
		recorder = ReplayRecorder.new()
		recorder.begin(state, resolver, _match_meta().merged({"network": true}))
		net.recorder = recorder
	net.outgoing.connect(func(msg: Dictionary) -> void: session.send(msg))
	net.action_applied.connect(_on_net_applied)
	net.denied.connect(func(reason: String) -> void:
		if is_instance_valid(_cheat_console): _cheat_console.write(reason)
		_net_request_pending = false
		_after_action()
		state.log.add("[denied] " + reason)
		_refresh_status())
	net.initiative_synced.connect(_on_initiative_synced)
	# Рассинхрон (batch 14): гость просит снимок и, получив его, перечитывает доску.
	net.desync_detected.connect(func() -> void:
		state.log.add("[net] Board out of sync with the host — resynchronizing…")
		_report_desync("guest"))
	net.resync_requested.connect(func(_from: int) -> void: _report_desync("host"))
	# Снимок хоста везёт и косметику поля — её гость кладёт вместо своей.
	net.fx_snapshot = func() -> Dictionary: return _fx.to_dict()
	net.resynced.connect(func() -> void:
		_net_request_pending = false
		if not net.restored_fx.is_empty():
			_fx.from_dict(net.restored_fx)
		_resync_after_restore()
		for c in controllers.values():
			c.notify_state_changed(state)
		state.log.add("[net] Board resynchronized with the host.")
		_kick_if_ai())
	# Порядок инициативы бросается локально у каждой стороны, поэтому хост тут же
	# объявляет свой — он и есть авторитетный (#53).
	_capture_opening_view()
	net.announce_initiative()
	_setup_network_controllers()
	_kick_if_ai()
	_deselect()
	if _net_status != null:
		var slot := state.roster.slot(my_owner)
		_net_status.text = "Network: you are %s (%s)%s" % [
			state.roster.name_of(my_owner),
			Roster.color_name(slot.color_index()) if slot != null else "?",
			" — host" if is_host else ""]
		if _spectator: _net_status.text = "Spectating · drawings shared with spectators only"
		_net_status.show()
	_refresh_status()

## Порядок инициативы согласован (#53, #19). Сам ход мирных уже отыгран внутри
## NetGame — одинаково у обеих сторон; здесь только показываем итог.
func _on_initiative_synced() -> void:
	state.log.add("— Initiative this match: %s —" % _order_labels())
	_refresh_status()
	queue_redraw()
	await _play_civilian_result(net.opening_civilians)
	_drain_net_messages.call_deferred()
	queue_redraw()
	# Первым может ходить ИИ-слот — его ведёт хост (batch 12 #15).
	_kick_if_ai()

func _on_net_message(msg: Dictionary) -> void:
	var kind := str(msg.get("k", ""))
	if kind == "fp_pose":
		_receive_fp_presence(msg)
		return
	if kind in [NetHandoff.K_RECLAIM, NetHandoff.K_RECLAIM_ACCEPT]:
		_on_reclaim_message(msg)
		return
	if kind == NetHandoff.K_SIDE_HUMAN:
		if _net_playing or _animating: _net_messages.append(msg)
		else: _apply_side_human(msg)
		return
	# Несимуляционные сообщения (item 50/51) обрабатываем здесь и НЕ передаём в netcode:
	# они никогда не касаются резолвера и лок-степа.
	match msg.get("k", ""):
		K_CHAT:
			# Подпись строит ПОЛУЧАТЕЛЬ по номеру стороны: отправитель раньше слал готовую
			# строку со своим «(you)», и у всех остальных чужие реплики шли как «(you)».
			var who: String = _side_label(int(msg["side"])) if msg.has("side") \
					else str(msg.get("who", "?"))
			NetHandoff.chat_history.append({"side": int(msg.get("side", -1)),
					"text": str(msg.get("text", ""))})
			_chat_append(who, str(msg.get("text", "")))
			return
		K_DRAW:
			_on_remote_stroke(msg)
			return
		K_AI_SPEED:
			_set_ai_speed(float(msg.get("v", 1.0)), false)
			return
		K_ROLL:
			var seq := int(msg.get("n", -1))
			_roll_inbox[seq] = true
			_roll_arrived.emit(seq)
			return
		K_SIDE_AI:
			_apply_side_ai(msg)
			return
		K_OVER:
			if not _match_over:
				_declare_match_over(str(msg.get("t", "The match is over")))
			return
	if net != null:
		if str(msg.get("k", "")) in [NetGame.K_INTENT, NetGame.K_ACTION, NetGame.K_STATE, NetGame.K_INIT] and (_net_playing or _animating):
			_net_messages.append(msg)
		else:
			net.receive(msg)

func _drain_net_messages() -> void:
	while net != null and not _net_playing and not _animating and not _net_messages.is_empty():
		_on_net_message(_net_messages.pop_front())

func _on_net_disconnected() -> void:
	# Keep authority alive even with no guests: the listening host can accept a reclaim.
	if session != null and session.is_host() and session.is_active():
		_refresh_status()
		return
	_net_request_pending = false
	_net_messages.clear()
	if _spectator:
		_to_lobby()
		return
	if _net_status != null:
		_net_status.text = "Connection lost"
	_autosave()
	networked = false
	net = null
	# Хост остался один (batch 13 #2): ушедшие уже подменены ИИ в _on_peer_left, а
	# «удалённых» сторон больше нет — их ход никто не пришлёт. Бой продолжается
	# локально; если сейчас ход машины, будим её.
	if state != null and state.roster != null:
		for side: int in controllers.keys():
			if controllers[side] is NetworkController:
				_take_side_as_ai(side)
	_refresh_status()
	_kick_if_ai()

func _report_desync(role: String) -> void:
	if not _desync_report.is_empty() or not Ui.desync_reports or net == null:
		return
	# The same key on every peer of this match, so the host's and a guest's reports pair up.
	var key := "%08x" % (hash([state.roster.to_dict(), state.grid.width, state.grid.height]) & 0xFFFFFFFF)
	_desync_report = DesyncReport.payload(role, state, resolver, _fx, net.recent.duplicate(true), key)
	# Players never run headless; the network tests and training servers do, and their
	# deliberate drifts must not land on the real report server.
	if DisplayServer.get_name() != "headless":
		DesyncReport.send(get_tree(), _desync_report)

func _on_peer_left(id: int) -> void:
	_fp_walkers.erase(id)
	if state == null or state.roster == null:
		return
	var side := state.roster.side_of_peer(id)
	if side < 0:
		return
	_autosave()
	if session != null: session.claims.reserve(str(session.peer_tokens.get(id, "")), side)
	_take_side_as_ai(side)
	if session != null:
		session.send({"k": K_SIDE_AI, "side": side, "ai": AIController.Difficulty.HARD,
				"st": AIPersonality.TACTICIAN})
	state.log.add("— %s left the match; a Tactician AI takes over their army —" % state.roster.name_of(side))
	_refresh_status()
	_kick_if_ai()

## Walking avatars travel on the cosmetic channel, independently of turns.
func _send_fp_presence(active: bool) -> void:
	if not networked or session == null or _spectator:
		return
	var msg := {"k": "fp_pose", "active": active}
	if active and _fp != null:
		msg["p"] = [_fp.pos.x, _fp.pos.y, _fp.pos.z, _fp.yaw]
	session.send(msg)

func _receive_fp_presence(msg: Dictionary) -> void:
	if session == null or state == null:
		return
	var peer := int(msg.get("_from", -1))
	var side := state.roster.side_of_peer(peer)
	if side < 0 or peer == session.my_peer_id():
		return
	if not bool(msg.get("active", false)):
		_fp_walkers.erase(peer)
		return
	var raw: Variant = msg.get("p")
	if not raw is Array or raw.size() != 4:
		return
	for v: Variant in raw:
		if not (v is float or v is int) or not is_finite(float(v)):
			return
	var p := Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	if p.x < 0 or p.z < 0 or p.x >= state.grid.width or p.z >= state.grid.height \
			or p.y < -FirstPersonBoard.TRENCH or p.y > FirstPerson.SPACE_CEIL:
		return
	_fp_walkers[peer] = {"side": side, "pos": p, "yaw": float(raw[3]), "time": Time.get_ticks_msec()}

func _on_reclaim_message(msg: Dictionary) -> void:
	if session == null or not session.is_host(): return
	var peer := int(msg.get("_from", -1))
	if not session.waiting_peers.has(peer): return
	if str(msg.k) == NetHandoff.K_RECLAIM:
		var error := NetHandoff.protocol_mismatch(msg)
		if error != "":
			session.send_to(peer, {"k": NetHandoff.K_RECLAIM_STATUS, "error": error})
			return
		var reply := session.claims.offer(peer, str(session.peer_tokens.get(peer, "")),
				state.roster, state.turns.round_number, _match_over)
		reply["k"] = NetHandoff.K_RECLAIM_STATUS if reply.has("error") else NetHandoff.K_RECLAIM_OFFER
		session.send_to(peer, reply)
	elif not _match_over and session.claims.accept(peer, state.turns.round_number):
		session.send_to(peer, {"k": NetHandoff.K_RECLAIM_STATUS, "text": "Seat reserved. Waiting for the next round..."})
	else:
		session.send_to(peer, {"k": NetHandoff.K_RECLAIM_STATUS, "error": "The reclaim offer is no longer available."})

func _grant_reclaims() -> void:
	if session == null or not session.is_host() or _match_over or _animating or _net_playing: return
	for peer: int in session.claims.due(state.turns.round_number):
		var side := int(session.claims.offers[peer].side)
		var slot := state.roster.slot(side)
		if slot == null or slot.kind != Roster.SlotKind.AI or not session.peers.has(peer):
			session.claims.forget(peer)
			continue
		var update := {"k": NetHandoff.K_SIDE_HUMAN, "side": side, "peer": peer}
		_apply_side_human(update)
		# Existing players receive only the ordered ownership change. The returning
		# player gets a complete current save, followed by subsequent action messages.
		session.send(update)
		var snapshot := NetHandoff.encode_load(_save_payload())
		snapshot["pv"] = NetHandoff.PROTOCOL
		snapshot["roll_seq"] = _roll_seq
		snapshot["settings"] = NetHandoff.encode_rules()
		session.send_to(peer, snapshot)
		session.waiting_peers.erase(peer)
		session.claims.forget(peer)
		_autosave()

func _apply_side_human(msg: Dictionary) -> void:
	var side := int(msg.get("side", -1))
	var slot := state.roster.slot(side)
	if slot == null: return
	var old: PlayerController = controllers.get(side)
	if old != null and old.intent_ready.is_connected(_on_intent_ready):
		old.intent_ready.disconnect(_on_intent_ready)
	slot.kind = Roster.SlotKind.HUMAN
	slot.peer_id = int(msg.get("peer", -1))
	controllers[side] = NetworkController.new(side)
	state.log.add("— %s returned and reclaimed their army —" % state.roster.name_of(side))
	_refresh_omniscience()
	_refresh_status()

func _take_side_as_ai(side: int) -> void:
	var slot := state.roster.slot(side)
	if slot == null:
		return
	slot.kind = Roster.SlotKind.AI
	slot.ai_difficulty = AIController.Difficulty.HARD
	slot.ai_style = AIPersonality.TACTICIAN
	slot.peer_id = -1
	_drop_drawings_of(side)
	# Только хост (или оставшийся в одиночестве хост) ведёт машину сам; у гостя сторона
	# остаётся NetworkController — её ходы придут от хоста.
	if not networked or (net != null and net.is_host):
		var old: PlayerController = controllers.get(side)
		if old != null and old.intent_ready.is_connected(_on_intent_ready):
			old.intent_ready.disconnect(_on_intent_ready)
		var ai := _ai_controller_for(side, slot)
		ai.intent_ready.connect(_on_intent_ready)
		controllers[side] = ai
	_refresh_omniscience()
	# Кто-то мог ждать броска ушедшего — будим ожидание, оно перепроверит ростер.
	_roll_arrived.emit(-1)

## Гость узнал от хоста, что сторона перешла к ИИ (batch 13 #2).
func _apply_side_ai(msg: Dictionary) -> void:
	if state == null or state.roster == null:
		return
	var side := int(msg.get("side", -1))
	var slot := state.roster.slot(side)
	if slot == null:
		return
	_autosave()
	slot.kind = Roster.SlotKind.AI
	slot.ai_difficulty = int(msg.get("ai", AIController.Difficulty.HARD))
	slot.ai_style = int(msg.get("st", AIPersonality.TACTICIAN))
	slot.peer_id = -1
	_drop_drawings_of(side)
	state.log.add("— %s left the match; a Tactician AI takes over their army —" % state.roster.name_of(side))
	_refresh_status()
	_roll_arrived.emit(-1)

func _setup_network_controllers() -> void:
	for c in controllers.values():
		if c.intent_ready.is_connected(_on_intent_ready):
			c.intent_ready.disconnect(_on_intent_ready)
	controllers.clear()
	if not _spectator:
		var mine := LocalHumanController.new(my_owner)
		mine.intent_ready.connect(_on_intent_ready)
		controllers[my_owner] = mine
	# Удалённых сторон теперь может быть больше одной: каждой — свой контроллер.
	# ИИ-слоты в сетевой партии водит ХОСТ (batch 12 #15): его AIController подаёт
	# намерения в тот же net.submit_local, что и человек, — хост резолвит и рассылает.
	# У гостей эти стороны — обычные удалённые.
	for remote in net.remote_owners():
		if net.is_host and state.roster.is_ai(remote):
			var slot := state.roster.slot(remote)
			var ai := _ai_controller_for(remote, slot)
			ai.intent_ready.connect(_on_intent_ready)
			controllers[remote] = ai
		else:
			controllers[remote] = NetworkController.new(remote)

func _build_spectator_controls(parent: Container) -> void:
	var fog := CheckBox.new()
	fog.text = "Spectator fog of war"
	fog.toggled.connect(func(on: bool) -> void:
		_spectator_fog = on
		queue_redraw())
	parent.add_child(fog)
	var pov := OptionButton.new()
	var sides := state.roster.player_ids()
	for side in sides: pov.add_item(state.roster.name_of(side), side)
	if not sides.is_empty(): _spectator_side = sides[0]
	pov.item_selected.connect(func(i: int) -> void:
		_spectator_side = pov.get_item_id(i)
		queue_redraw())
	parent.add_child(pov)
