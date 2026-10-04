extends "res://tests/NetSmokeBase.gd"
var _phase := 0
var _shot := false
var _hull0 := -1

func _initialize() -> void:
	tag = "guest-u"
	start_net(false)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null)
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			ck(pl._my_side == 1, "guest is side 1")
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(20, 14))
			pl._on_net_flow()
			ck(pl._my_ready and pl._flow_btn.text == "Unready" and not pl._flow_btn.disabled,
					"ready guest gets an Unready button ('%s')" % pl._flow_btn.text))
	step("unready", func() -> bool: return _step_t > 1.5, func() -> void:
		var pl = current_scene
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		pl._unhandled_input(ev)
		ck(pl._side_unit_count(1) == 1 and pl._status.text.find("Unready") >= 0,
				"a ready guest cannot touch the board ('%s')" % pl._status.text)
		pl._on_net_flow()
		ck(pl._unready_pending and pl._flow_btn.disabled, "unready waits for the host"))
	step("host confirmed", func() -> bool: return not current_scene._my_ready,
		func() -> void:
			var pl = current_scene
			ck(pl._flow_btn.text == "Ready" and not pl._flow_btn.disabled, "Ready again ('%s')" % pl._flow_btn.text)
			pl.brush_unit = "marksman"
			pl._click_cell(Vector2i(17, 2))
			ck(pl._side_unit_count(1) == 2, "guest added a marksman")
			pl._on_net_flow())
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			_hull0 = m.state.all_vehicles()[0].durability
			ck(m.state.all_vehicles()[0].living_crew_count() == 0, "the host's tank is empty"))
	step("laser the empty tank", func() -> bool:
		poke_dice()
		var m = current_scene
		if m.state.active_player() == 1 and not m._animating and not m._net_playing and _step_t > 0.5:
			if not _shot:
				var mk: UnitInstance = null
				for u in m.state.all_units():
					if u.owner == 1 and u.stats.id == "marksman":
						mk = u
				m._on_intent_ready(ShootIntent.new(mk.id, -1, -1, Vector2i(10, 2)))
				_shot = true
			else:
				m._on_intent_ready(EndTurnIntent.new())
		return _shot and m.state.all_vehicles()[0].durability < _hull0 and not m._net_playing,
		func() -> void:
			print("[guest] hull %d -> %d" % [_hull0, current_scene.state.all_vehicles()[0].durability]))
	step("stay online", func() -> bool:
		poke_dice()
		return _step_t > 6.0)
