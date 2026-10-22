extends "res://tests/SuiteBase.gd"

var session: NetworkSession
var connected := false
var disconnected := false
var messages := {}
var joins := 0

func attach_session(host: bool, token: String) -> void:
	connected = false
	disconnected = false
	if is_instance_valid(session):
		session.close()
		session.free()
	session = NetworkSession.new()
	session.name = NetworkSession.NODE_NAME
	session.client_token = token
	root.add_child(session)
	session.peer_ready.connect(func(_host: bool): connected = true)
	session.disconnected.connect(func(): disconnected = true)
	session.peer_joined.connect(func(_peer: int): joins += 1)
	session.message.connect(func(msg: Dictionary): messages[str(msg.get("k", ""))] = msg)
	session.attach()
	var error := session.start_host(19601) if host else session.start_client("127.0.0.1", 19601)
	ck(error == OK, "session transport starts")

func until(condition: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	ck(condition.call(), "network condition completed")

func run() -> void:
	var host := OS.get_cmdline_user_args().has("host")
	attach_session(host, "a".repeat(48))
	await until(func(): return connected)
	if host:
		await until(func(): return messages.has("ready") and not session.peer_tokens.is_empty())
		var peer: int = session.peers[0]
		ck(session.ban_player(peer).is_empty(), "host bans connected player")
		ck(session.banned_tokens.has("a".repeat(48)), "session remembers reconnect identity")
		await until(func(): return messages.has("other_ready"))
		ck(joins == 3, "initial guest, banned retry, and different guest reached transport")
		ck(session.peers.size() == 1 and session.peer_tokens.values().has("b".repeat(48)), "banned identity rejected; different player on same address allowed")
		session.send({"k": "done"})
		await create_timer(0.3).timeout
	else:
		session.send_to(1, {"k": "ready"})
		await until(func(): return disconnected)
		attach_session(false, "a".repeat(48))
		await until(func(): return disconnected)
		attach_session(false, "b".repeat(48))
		await until(func(): return connected)
		session.send_to(1, {"k": "other_ready"})
		await until(func(): return messages.has("done"))
	session.close()
	ck(session.banned_tokens.is_empty(), "closing hosted session clears bans")
	session.free()
	await process_frame
