extends "res://tests/NetSmokeBase.gd"

const PORT := 18643
const PRIOR_ROLLS := 37
const TS = preload("res://tests/TestSupport.gd")
var role := ""
var initial_peer := -1
var initial_round := -1
var initial_token := ""
var solo := false

func _initialize() -> void:
	role = OS.get_cmdline_user_args()[0]
	solo = OS.get_environment("MCF_RECLAIM_SOLO") == "1"
	tag = "reclaim-" + role
	step("connect", func() -> bool: return true, _connect)
	if role == "host":
		step("two identities", func() -> bool: return session().peer_tokens.size() == (1 if solo else 2), _launch)
		step("guest disconnects", func() -> bool:
			poke_dice()
			return scene_is("Main.gd") and current_scene.state.roster.is_ai(1), func() -> void:
			ck(current_scene.networked, "host retains authority")
			ck(current_scene.controllers[1] is AIController, "dropped seat uses AI")
			current_scene._set_ai_speed(2.0, true)
			current_scene.net.broadcast_restore("Checkpoint epoch before rejoin"))
		step("declined offer removed", func() -> bool:
			return current_scene.session.claims.offers.is_empty() and current_scene.session.peers.size() == (0 if solo else 1) and _step_t > 2.0)
		step("returner accepted", func() -> bool:
			for offer in current_scene.session.claims.offers.values():
				if offer.accepted: return true
			return false, func() -> void:
			initial_round = current_scene.state.turns.round_number
			ck(current_scene.state.roster.is_ai(1), "acceptance leaves AI mid-round")
			# Keep the presentation tests quick: only EndTurn actions, no AI battles.
			current_scene._paused = true)
		step("next round", func() -> bool:
			var m = current_scene
			poke_dice()
			if not m._animating and not m._net_playing and m.state.turns.round_number == initial_round:
				m.net.submit_local(EndTurnIntent.new(m.state.active_player()))
			return m.state.turns.round_number > initial_round and m.state.roster.slot(1).kind == Roster.SlotKind.HUMAN,
			func() -> void:
				ck(current_scene.controllers[1] is NetworkController, "host yields controller")
				ck(current_scene.state.roster.slot(1).peer_id != initial_peer, "new ENet identity")
				FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/state", FileAccess.WRITE).store_string(JSON.stringify({"state": StateCodec.encode(current_scene.state), "rules": StateCodec.encode_rules(current_scene.resolver)}))
				FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/host", FileAccess.WRITE).store_string(str(current_scene.state.digest_hash())))
		step("both guests agree", func() -> bool:
			return FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/guest") and (solo or FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/observer")),
			func() -> void:
				var m = current_scene
				m.state.dice.feed_scripted([6, 6, 6, 6])
				m.net.submit_local(ShootIntent.new(0, 1, 1)))
		step("returned player rolls defense", func() -> bool:
			poke_dice()
			var m = current_scene
			return m._roll_seq > PRIOR_ROLLS and not m._animating and not m._net_playing,
			func() -> void:
				FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/combat", FileAccess.WRITE).store_string(str(current_scene.state.digest_hash())))
		step("combat acknowledged", func() -> bool:
			return FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/guest-combat") and (solo or FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/observer-combat")),
			func() -> void:
				current_scene.net.submit_local(EndTurnIntent.new(0))
				ck(current_scene.state.active_player() == 1, "returner's turn begins"))
		step("returner submits a legal intent", func() -> bool:
			return current_scene.state.active_player() != 1 and not current_scene._net_playing and not current_scene._animating,
			func() -> void:
				FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/intent", FileAccess.WRITE).store_string(str(current_scene.state.digest_hash())))
		step("intent acknowledged", func() -> bool:
			return FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/guest-intent") and (solo or FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/observer-intent")))
	elif role == "guest":
		step("battle", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
			func() -> void:
				ck(current_scene.my_owner == 1, "original seat")
				initial_peer = session().my_peer_id()
				initial_token = session().client_token)
		step("leave", func() -> bool: poke_dice(); return _step_t > 1.0, func() -> void: current_scene._to_menu())
		step("unknown identity", func() -> bool: return scene_is("MainMenu.gd") and _step_t > 1.0,
			func() -> void:
				var route := RejoinStore.read()
				route.erase("token")
				RejoinStore.remember(route, "c".repeat(48))
				current_scene._rejoin_last_match())
		step("unknown identity rejected clearly", func() -> bool:
			return current_scene._session == null and "No disconnected seat" in current_scene._mp_status.text,
			func() -> void:
				var route := RejoinStore.read()
				route.erase("token")
				RejoinStore.remember(route, initial_token))
		step("rejoin through menu", func() -> bool: return _step_t > 0.5,
			func() -> void: current_scene._rejoin_last_match())
		step("offer declined", func() -> bool: return is_instance_valid(current_scene._rejoin_prompt),
			func() -> void: current_scene._rejoin_prompt.canceled.emit())
		step("retry", func() -> bool: return _step_t > 3.0, func() -> void: current_scene._rejoin_last_match())
		step("offer accepted", func() -> bool: return is_instance_valid(current_scene._rejoin_prompt),
			func() -> void:
				ck(session().client_token == initial_token, "token survives menu round trip")
				current_scene._rejoin_prompt.confirmed.emit())
		step("reclaimed battle", func() -> bool: return scene_is("Main.gd") and FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/host"),
			func() -> void:
				ck(current_scene.my_owner == 1 and current_scene.controllers[1].is_local_human(), "returner has human controller")
				ck(session().my_peer_id() != initial_peer, "reconnected with fresh peer ID")
				ck(current_scene._roll_seq == PRIOR_ROLLS, "dice cursor restored before live combat")
				ck(GameConfig.ai_speed == 2.0, "missed host settings restored")
				_agree())
		step("combat after reclaim", _combat_done, _agree_combat)
		step("take my turn", func() -> bool:
			return current_scene.state.active_player() == 1 and not current_scene._animating and not current_scene._net_playing,
			func() -> void: current_scene._on_end_turn_pressed())
		step("reclaimed intent replicated", func() -> bool:
			return FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/intent") and current_scene.state.active_player() != 1 and not current_scene._net_playing,
			func() -> void:
				ck(str(current_scene.state.digest_hash()) == FileAccess.get_file_as_string(OS.get_environment("MCF_RECLAIM_SYNC") + "/intent").strip_edges(), "returned player's intent agrees")
				FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/" + role + "-intent", FileAccess.WRITE).store_string("ok"))
		step("hold connection", func() -> bool: return _step_t > 2.0)
	else:
		step("uninterrupted guest agrees", func() -> bool:
			poke_dice()
			return scene_is("Main.gd") and FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/host") and current_scene.state.roster.slot(1).kind == Roster.SlotKind.HUMAN and current_scene.state.turns.round_number > 1,
			_agree)
		step("combat after reclaim", _combat_done, _agree_combat)
		step("reclaimed intent replicated", func() -> bool:
			return FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/intent") and current_scene.state.active_player() != 1 and not current_scene._net_playing,
			func() -> void:
				ck(str(current_scene.state.digest_hash()) == FileAccess.get_file_as_string(OS.get_environment("MCF_RECLAIM_SYNC") + "/intent").strip_edges(), "returned player's intent agrees")
				FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/" + role + "-intent", FileAccess.WRITE).store_string("ok"))
		step("hold connection", func() -> bool: return _step_t > 2.0)

func _connect() -> void:
	var ses := NetworkSession.new()
	ses.name = NetworkSession.NODE_NAME
	ses.roll_sequence_on_join = PRIOR_ROLLS
	root.add_child(ses)
	var relay := OS.get_environment("MCF_TEST_RELAY")
	var code_file := OS.get_environment("MCF_RECLAIM_SYNC") + "/room"
	if role == "host":
		if relay.is_empty(): ck(ses.start_host(PORT) == OK, "host starts")
		else:
			ses.relay_room.connect(func(code: String) -> void: FileAccess.open(code_file, FileAccess.WRITE).store_string(code))
			ck(ses.start_relay_host(relay, {"name": "reclaim smoke", "protocol": NetHandoff.PROTOCOL}) == OK, "relay host starts")
	else:
		ses.client_token = ("a" if role == "guest" else "b").repeat(48)
		ses.message.connect(_initial_load)
		ses.peer_ready.connect(func(_h: bool) -> void: ses.attach())
		if relay.is_empty(): ck(ses.start_client("127.0.0.1", PORT) == OK, "guest connects")
		else: ck(ses.start_relay_client(relay, FileAccess.get_file_as_string(code_file)) == OK, "relay guest connects")

func _initial_load(msg: Dictionary) -> void:
	if msg.get("k") != NetHandoff.K_LOAD: return
	var ses := session()
	ses.detach()
	ses.message.disconnect(_initial_load)
	NetHandoff.apply_load(msg)
	NetHandoff.session = ses
	NetHandoff.is_host = false
	change_scene_to_file("res://scenes/Main.tscn")

func _launch() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	if not solo: GameConfig.roster.add_slot(Roster.SlotKind.HUMAN)
	GameConfig.roster.slot(0).peer_id = 1
	for peer in session().peer_tokens:
		var side := 1 if session().peer_tokens[peer].begins_with("a") else 2
		GameConfig.roster.slot(side).peer_id = peer
		if side == 1: initial_peer = peer
	var map := MapData.new(38, 28)
	map.set_spawn(Vector2i(3, 3), "heavy_infantry", 0)
	map.set_spawn(Vector2i(8, 3), "heavy_infantry", 1)
	if not solo: map.set_spawn(Vector2i(33, 23), "heavy_infantry", 2)
	var st := map.build_state(1234, GameConfig.roster)
	st.turns.round_order.assign([0, 1] if solo else [0, 1, 2])
	st.turns.active_index = 0
	st.turns.initiative_rolled = true
	var res := GameActionResolver.new(st)
	var payload := {"state": StateCodec.encode(st), "rules": StateCodec.encode_rules(res)}
	session().send(NetHandoff.encode_load(payload))
	SaveHandoff.pending_save = payload
	NetHandoff.session = session()
	NetHandoff.is_host = true
	change_scene_to_file("res://scenes/Main.tscn")

func _agree() -> void:
	var expected := FileAccess.get_file_as_string(OS.get_environment("MCF_RECLAIM_SYNC") + "/host").strip_edges()
	ck(str(current_scene.state.digest_hash()) == expected, "full live board agrees with host")
	var snapshot: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("MCF_RECLAIM_SYNC") + "/state"))
	var live: Dictionary = JSON.parse_string(JSON.stringify({"state": StateCodec.encode(current_scene.state), "rules": StateCodec.encode_rules(current_scene.resolver)}))
	# Existing peers replay host dice; only the returning guest restores the host RNG.
	if role == "observer":
		snapshot.state.erase("dice")
		live.state.erase("dice")
	ck(snapshot == live, "complete state and mode/event rules agree")
	ck(current_scene.networked, "connection remains active")
	ck(current_scene.net.history_epoch == 1, "rejoining preserves the restored match epoch")
	FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/" + role, FileAccess.WRITE).store_string("ok")

func _combat_done() -> bool:
	poke_dice()
	return FileAccess.file_exists(OS.get_environment("MCF_RECLAIM_SYNC") + "/combat") and current_scene._roll_seq > PRIOR_ROLLS and not current_scene._animating and not current_scene._net_playing

func _agree_combat() -> void:
	ck(str(current_scene.state.digest_hash()) == FileAccess.get_file_as_string(OS.get_environment("MCF_RECLAIM_SYNC") + "/combat").strip_edges(), "board agrees after post-reclaim combat")
	FileAccess.open(OS.get_environment("MCF_RECLAIM_SYNC") + "/" + role + "-combat", FileAccess.WRITE).store_string("ok")
