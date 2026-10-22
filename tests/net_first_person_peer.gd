extends "res://tests/SuiteBase.gd"

var ses: NetworkSession
var phases := {}
var connected := false

func run() -> void:
	var host := OS.get_cmdline_user_args().has("host")
	ses = NetworkSession.new()
	ses.name = NetworkSession.NODE_NAME
	root.add_child(ses)
	ses.peer_ready.connect(func(_host: bool) -> void: connected = true)
	var err := ses.start_host(19594) if host else ses.start_client("127.0.0.1", 19594)
	ck(err == OK, "real ENet transport starts")
	if err != OK: return
	var deadline := Time.get_ticks_msec() + 15000
	while not connected and Time.get_ticks_msec() < deadline: await process_frame
	ck(connected, "both peers connect")
	if not connected: return
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(20, 18)
	map.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	map.set_spawn(Vector2i(17, 15), "light_infantry", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	main.set_process(false)
	main.networked = true
	main.my_owner = 0 if host else 1
	main.session = ses
	var guest := ses.peers[0] if host else ses.my_peer_id()
	var remote := guest if host else 1
	main.state.roster.slot(0).peer_id = 1
	main.state.roster.slot(1).peer_id = guest
	ses.message.connect(func(msg: Dictionary) -> void:
		if msg.get("k") == "fp_pose": main._on_net_message(msg)
		elif msg.get("k") == "fp_test_phase": phases[msg["phase"]] = true)
	ses.attach()
	await _phase("ready")
	var before := JSON.stringify(StateCodec.encode(main.state))
	main._start_first_person(Vector2i(8, 8))
	deadline = Time.get_ticks_msec() + 15000
	while not main._fp._walkers.has(remote) and Time.get_ticks_msec() < deadline: await process_frame
	ck(main._fp._walkers.has(remote), "remote first-person walker arrives over ENet")
	await _phase("visible")
	main._fp.pos = Vector3(10.5 if host else 12.5, 0, 9.5)
	main._send_fp_presence(true)
	var expected := Vector3(12.5 if host else 10.5, 0, 9.5)
	deadline = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if main._fp._walkers.has(remote) and main._fp._walkers[remote].position.distance_to(expected) < 0.05: break
		await process_frame
	ck(main._fp._walkers.has(remote) and main._fp._walkers[remote].position.distance_to(expected) < 0.05,
			"remote motion converges smoothly to its transmitted position")
	await _phase("moved")
	main._end_first_person()
	deadline = Time.get_ticks_msec() + 15000
	while main._fp_walkers.has(remote) and Time.get_ticks_msec() < deadline: await process_frame
	ck(not main._fp_walkers.has(remote), "leaving first person removes the remote walker")
	ck(JSON.stringify(StateCodec.encode(main.state)) == before, "presence leaves all simulation data unchanged")
	await _phase("left")
	main.session = null
	main.networked = false
	main.queue_free()
	await process_frame
	ses.close()
	ses.queue_free()
	await process_frame

func _phase(name: String) -> void:
	ses.send({"k": "fp_test_phase", "phase": name})
	var deadline := Time.get_ticks_msec() + 15000
	while not phases.has(name) and Time.get_ticks_msec() < deadline: await process_frame
	ck(phases.has(name), "both peers finish " + name)
