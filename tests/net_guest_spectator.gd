extends "res://tests/NetSmokeBase.gd"

func _initialize() -> void:
	tag = "spectator-guest"
	start_net(false)
	step("lobby joined", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null,
		func() -> void: session().send({"k": NetHandoff.K_LOBBY_REQ, "op": "spectate"}))
	step("spectator role received", func() -> bool: return session().spectators.has(session().my_peer_id()))
	step("spectator deployment", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			ck(current_scene._spectator, "deployment knows spectator role")
			ck(current_scene._host_sides().is_empty(), "spectator has no army to deploy")
			ck(current_scene._ready_locked(), "deployment edits locked for spectators"))
	step("spectator battle", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			ck(m._spectator and m.my_owner == -2, "battle retains spectator role")
			for c in m.controllers.values(): ck(c is NetworkController, "spectator has only network controllers")
			for side in m.state.roster.player_ids(): ck(not m._can_control(side), "spectator cannot control side %d" % side)
			# Deliberately bypass the UI: the transport/host must reject a forged order.
			session().send({"k": NetGame.K_INTENT, "i": IntentCodec.encode(EndTurnIntent.new(0))}))
	step("other spectator receives drawing", func() -> bool:
		if _step_t < 2.0: return false
		var m = current_scene
		m._cur_stroke = [Vector2(30, 30), Vector2(90, 90)]
		m._stroke_commit()
		return not m._canvases.is_empty(), func() -> void:
			ck(not current_scene._canvases.is_empty(), "spectators share drawings"))
	step("stay connected for host checks", func() -> bool: return _step_t > 10.0)
