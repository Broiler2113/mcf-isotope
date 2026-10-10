extends "res://tests/NetSmokeBase.gd"
func _initialize() -> void:
	tag = "kick-host"
	start_net(true)
	step("guest seated", func() -> bool:
		return scene_is("Lobby.gd") and current_scene.roster.slots[1].peer_id > 1,
		func() -> void:
			current_scene._on_remove_slot(1)
			ck(current_scene.roster.slots[1].kind == Roster.SlotKind.OPEN, "kick reopens the seat"))
	step("guest disconnected", func() -> bool: return session().peers.is_empty())
	step("finish", func() -> bool: return _step_t > 2.0)
