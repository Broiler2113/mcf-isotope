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
	# Отражение видно ЖИВЬЁМ (batch 13 #13): хост шлёт копии с каждым щелчком, ещё до
	# своей готовности, и гость смотрит, как его армия собирается сама.
	step("host's live mirror shows my army building up", func() -> bool:
		var pl = current_scene
		return pl._live_units.has(1) and pl._live_units[1].size() == 3 and not pl._my_ready,
		func() -> void: print("[guest-m] live mirror: 3 units in my zone"))
	step("host formation arrived, mirrored into my zone, auto-confirmed", func() -> bool:
		# Подтверждение мгновенное, и бой может открыться раньше следующего опроса.
		if scene_is("Main.gd"):
			return true
		var pl = current_scene
		return scene_is("Placement.gd") and pl._remote_units.has(1) and pl._my_ready,
		func() -> void: print("[guest-m] auto-confirmed — no stamp, no button"))
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			print("[guest-m] digest ", load("res://tests/TestSupport.gd").digest(m.state)))
	step("hold", func() -> bool: return _step_t > 2.0)
