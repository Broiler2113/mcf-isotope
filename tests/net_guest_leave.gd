extends "res://tests/NetSmokeBase.gd"
var _phase := 0
func _initialize() -> void:
	tag = "guest-l"
	start_net(false)
	step("lobby up, seated", func() -> bool:
		return scene_is("Lobby.gd") and current_scene._my_slot() != null and current_scene._my_slot().id == 1,
		func() -> void:
			print("[guest-l] seated in slot 2 — leaving")
			# leave: close the session like the Disconnect button does
			NetHandoff.discard()
			change_scene_to_file("res://scenes/MainMenu.tscn"))
	step("rejoin after a moment", func() -> bool: return _step_t > 1.5,
		func() -> void:
			var ses := NetworkSession.new()
			ses.name = NetworkSession.NODE_NAME
			root.add_child(ses)
			ses.start_client("127.0.0.1", NetworkSession.DEFAULT_PORT)
			NetHandoff.session = ses
			NetHandoff.is_host = false
			ses.peer_ready.connect(func(_h: bool) -> void:
				change_scene_to_file("res://scenes/Lobby.tscn")))
	step("lobby again, seated in slot 3", func() -> bool:
		return scene_is("Lobby.gd") and current_scene._my_slot() != null and current_scene._my_slot().id == 2)
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void: ck(current_scene._my_side == 2, "guest is side 2"))
	step("host is ready; now leave placement", func() -> bool:
		var pl = current_scene
		return pl._ready_sides.has(0),
		func() -> void:
			print("[guest-l] leaving placement")
			var pl = current_scene
			pl._drop_session()
			change_scene_to_file("res://scenes/MainMenu.tscn"))
	step("done", func() -> bool: return _step_t > 6.0)
