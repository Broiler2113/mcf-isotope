extends "res://tests/NetSmokeBase.gd"

func _initialize() -> void:
	tag = "guest-m"
	start_net(false)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null)
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			ck(GameConfig.placement_mode == GameConfig.Placement.MIRRORED, "mirrored synced to guest")
			ck(pl._mirrored_guest(), "guest is a mirrored guest")
			ck(pl._flow_btn.disabled, "ready is disabled until the host's formation arrives")
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(20, 5))
			ck(pl._side_unit_count(1) == 0, "guest cannot place in mirrored mode"))
	step("host formation arrived, mirrored into my zone", func() -> bool:
		var pl = current_scene
		return pl._remote_units.has(1) and pl._remote_units[1].size() == 3,
		func() -> void:
			var pl = current_scene
			ck(not pl._flow_btn.disabled, "ready enabled now")
			pl._on_net_ready())
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			print("[guest-m] digest ", load("res://tests/TestSupport.gd").digest(m.state)))
	step("hold", func() -> bool: return _step_t > 2.0)
