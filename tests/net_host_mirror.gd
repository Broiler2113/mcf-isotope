extends "res://tests/NetSmokeBase.gd"

func _initialize() -> void:
	tag = "host-m"
	start_net(true)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null)
	step("guest seated", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() >= 2 and r.slots[1].kind == Roster.SlotKind.HUMAN and r.slots[1].peer_id > 1,
		func() -> void:
			var lob = current_scene
			lob._place_opt.select(1)
			lob._place_opt.item_selected.emit(1)
			lob._on_slot_budget(1000.0, 0)
			lob._on_slot_budget(1000.0, 1))
	step("start match", func() -> bool: return _step_t > 1.5, func() -> void: current_scene._on_start())
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			ck(GameConfig.placement_mode == GameConfig.Placement.MIRRORED, "mirrored on host")
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(3, 5))
			pl._click_cell(Vector2i(4, 6))
			pl.brush_unit = "tank"
			pl._click_cell(Vector2i(2, 9))
			ck(pl._side_unit_count(0) == 3, "host placed 3 (got %d)" % pl._side_unit_count(0)))
	step("ready", func() -> bool: return _step_t > 1.0, func() -> void:
		var pl = current_scene
		pl._on_net_ready()
		ck(pl._my_ready, "host ready")
		ck(pl._side_unit_count(1) == 3, "guest zone stamped with 3 (got %d)" % pl._side_unit_count(1)))
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			print("[host-m] digest ", load("res://tests/TestSupport.gd").digest(m.state))
			ck(m.state.all_units().size() >= 4, "units on board: %d" % m.state.all_units().size())
			ck(m.state.all_vehicles().size() == 2, "two tanks: %d" % m.state.all_vehicles().size()))
	step("hold", func() -> bool: return _step_t > 3.0)
