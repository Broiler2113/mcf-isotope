extends "res://tests/NetSmokeBase.gd"
## Playtest-20: guest readies, unreadies (host confirms), changes army, readies again;
## only then does the host start. In battle the guest's marksman lasers the host's EMPTY tank.
var _saw_ready := false
var _saw_unready := false
var _hull0 := -1
var _placement_ms := 0

func _initialize() -> void:
	tag = "host-u"
	start_net(true)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null)
	step("guest seated", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() >= 2 and r.slots[1].kind == Roster.SlotKind.HUMAN and r.slots[1].peer_id > 1,
		func() -> void:
			current_scene._on_slot_budget(900.0, 0)
			current_scene._on_slot_budget(900.0, 1))
	step("start match", func() -> bool: return _step_t > 1.5, func() -> void: current_scene._on_start())
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			_placement_ms = Time.get_ticks_msec()
			pl.brush_unit = "tank"
			pl._click_cell(Vector2i(4, 1))
			pl.brush_unit = "sniper"
			pl._click_cell(Vector2i(2, 14))
			ck(pl._side_unit_count(0) == 2, "host placed a tank and a sniper (%d)" % pl._side_unit_count(0)))
	step("guest ready, then unready, then ready with a marksman", func() -> bool:
		var pl = current_scene
		if not scene_is("Placement.gd"):
			return false
		if pl._ready_sides.has(1):
			_saw_ready = true
		if _saw_ready and not pl._ready_sides.has(1):
			_saw_unready = true
		return _saw_unready and pl._ready_sides.has(1) and pl._remote_units.get(1, []).size() == 2,
		func() -> void:
			var pl = current_scene
			ck(scene_is("Placement.gd"), "host did not start while the guest was unready")
			pl._on_net_flow()
			ck(pl._my_ready, "host ready"))
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			var ids: Array = []
			for u in m.state.all_units():
				if u.owner == 1:
					ids.append(u.stats.id)
			ids.sort()
			ck(ids == ["light_infantry", "marksman"], "host sees the guest's NEW army: %s" % str(ids))
			_hull0 = m.state.all_vehicles()[0].durability
			ck(m._real_start_ms >= _placement_ms, "real clock started with the battle, not the app (%d < %d)" % [m._real_start_ms, _placement_ms]))
	step("guest's laser burns the empty tank", func() -> bool:
		poke_dice()
		var m = current_scene
		if m.state.active_player() == 0 and not m._animating and not m._net_playing and _step_t > 0.5:
			m._on_intent_ready(EndTurnIntent.new())
		return m.state.all_vehicles()[0].durability < _hull0,
		func() -> void:
			print("[host] hull %d -> %d" % [_hull0, current_scene.state.all_vehicles()[0].durability]))
	step("hold for guest", func() -> bool: return _step_t > 4.0)
