extends "res://tests/cheats/CheatSuite.gd"

var session: NetworkSession
var phases := {}
var connected := false
var netgame: NetGame
var denials := 0

func run() -> void:
	var host := OS.get_cmdline_user_args().has("host")
	session = NetworkSession.new()
	session.name = NetworkSession.NODE_NAME
	root.add_child(session)
	session.peer_ready.connect(func(_host: bool): connected = true)
	var error := session.start_host(19595) if host else session.start_client("127.0.0.1", 19595)
	ck(error == OK, "ENet starts")
	if error != OK: return
	var deadline := Time.get_ticks_msec() + 15000
	while not connected and Time.get_ticks_msec() < deadline: await process_frame
	ck(connected, "ENet connects")
	if not connected: return
	var r := fresh()
	r.state.roster.add_slot(Roster.SlotKind.AI)
	r.state.roster.slots[1].peer_id = session.peers[0] if host else session.my_peer_id()
	r.state.roster.slots[1].cheats_allowed = false
	netgame = NetGame.new(r.state, r, host, 0 if host else 1)
	netgame.outgoing.connect(func(msg: Dictionary): session.send(msg))
	netgame.denied.connect(func(_reason: String): denials += 1)
	session.message.connect(func(msg: Dictionary):
		if msg.get("k") == "cheat_test_phase": phases[msg.phase] = msg.get("digest", 0)
		else: netgame.receive(msg))
	session.attach()
	await phase("ready")
	if not host:
		session.send({"k": NetGame.K_INTENT, "i": IntentCodec.encode(CheatIntent.new("unit_ap", {"unit": 0, "value": 9}, 0))})
	await phase("forged")
	ck(r.state.get_unit(0).remaining_ap != 9, "forged issuer rejected across transport")
	if host: ck(netgame.set_cheat_permission(1, true).is_empty(), "host grants connected seat")
	await phase("granted")
	ck(r.state.roster.slots[1].cheats_allowed, "grant synchronized")
	if not host:
		netgame.submit_local(CheatIntent.new("unit_invulnerable", {"unit": 1, "enabled": true}, 1))
		netgame.submit_local(CheatIntent.new("event_queue", {"event": "gas"}, 1))
		netgame.submit_local(CheatIntent.new("event_spawn", {"event": "gas", "x": 10, "y": 10, "properties": {"w": 3, "h": 4, "rounds": 7}}, 1))
	await phase("submitted")
	# Host may have sent the barrier before processing guest input; wait for the
	# authoritative state, not elapsed time, on both peers.
	deadline = Time.get_ticks_msec() + 15000
	while r.state.cheat_sequence < 3 and Time.get_ticks_msec() < deadline: await process_frame
	ck(r.state.cheat_sequence == 3 and r.state.get_unit(1).cheat_invulnerable, "guest gameplay actions applied")
	await phase("applied", r.state.digest_hash())
	ck(phases.applied == r.state.digest_hash(), "host/guest state matches")
	if host: netgame.submit_local(CheatIntent.new("ai_pause", {"owner": 2}, 0))
	await phase("ai_pause")
	deadline = Time.get_ticks_msec() + 10000
	while not r.state.cheat_ai_paused.has(2) and Time.get_ticks_msec() < deadline: await process_frame
	ck(r.state.cheat_ai_paused.has(2), "AI pause synchronized")
	ck(r.random_events.clouds.size() == 1 and r.random_events.clouds[0].left == 7, "event command payload synchronized")
	if not host:
		session.send({"k": NetGame.K_INTENT, "i": IntentCodec.encode(CheatIntent.new("ai_resume", {"owner": 2}, 0))})
	await phase("ai_spoof")
	ck(r.state.cheat_ai_paused.has(2), "guest cannot resume shared AI by forging issuer")
	if host: netgame.set_cheat_permission(1, false)
	await phase("revoked")
	ck(not r.state.roster.slots[1].cheats_allowed, "revocation synchronized")
	if not host:
		session.send({"k": NetGame.K_INTENT, "i": IntentCodec.encode(CheatIntent.new("unit_ap", {"unit": 1, "value": 9}, 0))})
	await phase("denied")
	ck(r.state.get_unit(1).remaining_ap != 9, "revoked command rejected")
	if not host: session.send({"k": NetGame.K_RESYNC})
	await phase("resync")
	await phase("done", r.state.digest_hash())
	ck(phases.get("done", -1) == r.state.digest_hash(), "resync preserves effects and permission")
	if host: netgame.set_cheat_permission(1, true)
	await phase("history_permission")
	var snapshot := StateCodec.encode(r.state)
	var rules := StateCodec.encode_rules(netgame.resolver)
	var baseline := r.state.digest_hash()
	await phase("history_snapshot", baseline)
	ck(phases.history_snapshot == baseline, "both peers checkpoint the same pre-edit state")
	if host: netgame.submit_local(CheatIntent.new("unit_ap", {"unit": 1, "value": 8}, 0))
	await phase("history_changed")
	deadline = Time.get_ticks_msec() + 10000
	while r.state.get_unit(1).remaining_ap != 8 and Time.get_ticks_msec() < deadline: await process_frame
	if host:
		StateCodec.restore_into(r.state, snapshot)
		netgame.resolver = GameActionResolver.new(r.state)
		StateCodec.apply_rules(netgame.resolver, rules)
		netgame.broadcast_restore("Restored test checkpoint")
	await phase("history_restored")
	deadline = Time.get_ticks_msec() + 10000
	while netgame.history_epoch != 1 and Time.get_ticks_msec() < deadline: await process_frame
	ck(r.state.digest_hash() == baseline and netgame.history_epoch == 1, "complete checkpoint restores across ENet")
	if not host:
		session.send({"k": NetGame.K_INTENT, "epoch": 0, "i": IntentCodec.encode(CheatIntent.new("unit_ap", {"unit": 1, "value": 9}, 1))})
	await phase("history_stale")
	ck(r.state.get_unit(1).remaining_ap != 9, "pre-restore request cannot alter restored ENet session")
	if not host: netgame.submit_local(CheatIntent.new("unit_ap", {"unit": 1, "value": 7}, 1))
	deadline = Time.get_ticks_msec() + 10000
	while r.state.get_unit(1).remaining_ap != 7 and Time.get_ticks_msec() < deadline: await process_frame
	await phase("history_live", r.state.digest_hash())
	ck(r.state.get_unit(1).remaining_ap == 7 and phases.history_live == r.state.digest_hash(), "fresh actions synchronize after restore")
	await create_timer(0.3).timeout # flush the final reliable barrier before closing ENet
	for connection: Dictionary in netgame.outgoing.get_connections(): netgame.outgoing.disconnect(connection.callable)
	session.close()
	session.queue_free()
	await process_frame

func phase(name: String, digest := 0) -> void:
	session.send({"k": "cheat_test_phase", "phase": name, "digest": digest})
	var deadline := Time.get_ticks_msec() + 15000
	while not phases.has(name) and Time.get_ticks_msec() < deadline: await process_frame
	ck(phases.has(name), "both peers reached " + name)
