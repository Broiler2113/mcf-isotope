extends SceneTree

var failures := 0
func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL reclaim: " + label)

func _initialize() -> void:
	var roster := Roster.default_duel(false)
	var claims := SeatReclaims.new()
	var token := RejoinStore.token()
	check(token.length() == 48 and token != RejoinStore.token(), "unique local identity")
	claims.reserve(token, 1)
	check(claims.offer(42, token, roster, 3, false).has("error"), "occupied human seat rejected")
	roster.slot(1).kind = Roster.SlotKind.AI
	check(claims.offer(42, "unknown", roster, 3, false).has("error"), "unknown token rejected")
	check(claims.offer(42, token, roster, 3, true).has("error"), "ended match rejected")
	check(claims.offer(42, token, roster, 3, false).get("side") == 1, "new peer offered original seat")
	check(claims.due(4).is_empty(), "ignored offer leaves AI in control")
	check(claims.offer(43, token, roster, 3, false).has("error"), "duplicate reconnect rejected")
	claims.forget(42)
	check(claims.due(4).is_empty() and roster.is_ai(1), "declining leaves AI in control")
	claims.offer(43, token, roster, 4, false)
	check(claims.accept(43, 5), "accept later offer")
	check(claims.due(5).is_empty(), "mid-round acceptance waits")
	check(claims.due(6) == [43], "next round grants correct peer")
	claims.forget(43)
	check(claims.due(6).is_empty(), "disconnected returner removed")
	var session := NetworkSession.new()
	session._is_host = true
	session.in_match = true
	session.peers.append(42)
	session.waiting_peers.append(42)
	var delivered: Array = []
	session.message.connect(func(msg: Dictionary) -> void: delivered.append(msg))
	session.attach()
	session._deliver({"k": NetHandoff.K_IDENTITY, "token": token}, 42)
	check(session.peer_tokens.get(42) == token, "identity bound to authenticated transport sender")
	session._deliver({"k": NetGame.K_INTENT}, 42)
	session._deliver({"k": NetGame.K_RESYNC}, 42)
	check(delivered.is_empty(), "waiting connection cannot act or request full state")
	session._deliver({"k": NetHandoff.K_RECLAIM, "pv": NetHandoff.PROTOCOL}, 42)
	check(delivered.size() == 1 and delivered[0]._from == 42, "reclaim reaches host")
	session.waiting_peers.clear()
	delivered.clear()
	session._deliver({"k": NetHandoff.K_SIDE_HUMAN, "side": 0, "peer": 42}, 42)
	check(delivered.is_empty(), "existing guests cannot command host ownership changes")
	session._is_host = false
	delivered.clear()
	for kind in [NetHandoff.K_SIDE_HUMAN, NetHandoff.K_RECLAIM_OFFER, NetHandoff.K_LOAD]:
		session._deliver({"k": kind}, 42)
	check(delivered.is_empty(), "guests cannot forge ownership, offers or saves")
	session.free()
	print("reclaim: %s" % ("all checks hold" if failures == 0 else "%d failures" % failures))
	quit(0 if failures == 0 else 1)
