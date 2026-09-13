extends "res://tests/NetSmokeBase.gd"
var _host_units := 0
func _initialize() -> void:
	tag = "guest-t"
	start_net(false)
	step("lobby up, seated in slot 2", func() -> bool:
		return scene_is("Lobby.gd") and current_scene._my_slot() != null and current_scene._my_slot().id == 1)
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			ck(pl._my_side == 1, "guest is side 1 (%d)" % pl._my_side)
			var zone: Array = pl._zone_cells(1)
			var placed := 0
			pl.brush_unit = "light_infantry"
			for c in zone:
				if placed < 4 and pl._placed_at(c) == -1 and pl._footprint_placeable("light_infantry", c, 1):
					pl._click_cell(c); placed += 1
			ck(pl._side_unit_count(1) == 4, "guest placed 4"))
	step("host army arrived, ready", func() -> bool:
		var pl = current_scene
		return pl._remote_units.has(0) and pl._remote_units[0].size() == 6,
		func() -> void: current_scene._on_net_ready())
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			for u in m.state.all_units():
				if u.owner == 0 and u.is_alive(): _host_units += 1
			print("[guest-t] units=%d vehicles=%d host_units=%d" % [m.state.all_units().size(), m.state.all_vehicles().size(), _host_units])
			ck(_host_units == 5, "guest's state holds the host's 5 soldiers (%d)" % _host_units)
			print("[guest-t] digest ", load("res://tests/TestSupport.gd").digest(m.state).hash())
			# Портим свою доску (batch 14): один солдат хоста «умирает» только у нас. Первое
			# же действие хоста обязано вскрыть расхождение и подтянуть его доску целиком.
			for u in m.state.all_units():
				if u.owner == 0 and u.is_alive():
					u.status = MCF.Status.CORPSE
					break)
	step("host's turn played through, no victory, nothing denied", func() -> bool:
		poke_dice()
		var m = current_scene
		var host_moves := 0
		for l in m.state.log.lines:
			if str(l).find(": move →") >= 0: host_moves += 1
		# Жребий инициативы (batch 14): гость может ходить первым — тогда сдаёт ход и
		# ждёт, пока хост походит.
		if host_moves < 3 and m.state.active_player() == 1 and not m._animating and not m._net_playing:
			m._on_intent_ready(EndTurnIntent.new())
			return false
		return host_moves >= 3 and m.state.active_player() == 1 and not m._animating and not m._net_playing,
		func() -> void:
			var m = current_scene
			ck(not m._match_over, "guest did not declare a victory")
			var denied := 0
			for l in m.state.log.lines:
				if str(l).find("[denied]") >= 0: denied += 1
			var resynced := false
			for l in m.state.log.lines:
				if str(l).find("resynchronised with the host") >= 0: resynced = true
			ck(resynced, "the guest noticed the drift and pulled the host's board")
			var alive_host := 0
			for u in m.state.all_units():
				if u.owner == 0 and u.is_alive(): alive_host += 1
			ck(alive_host == 5, "after the resync all 5 host soldiers are alive again (%d)" % alive_host)
			var vis = m.resolver.team_visible_coords(1)
			var seen := 0
			for u in m.state.living_units_of(0):
				if vis.has(u.coord): seen += 1
			print("[guest-t] host soldiers visible to the guest: %d of %d" % [seen, m.state.living_units_of(0).size()])
			print("[guest-t] digest ", load("res://tests/TestSupport.gd").digest(m.state).hash()))
	step("hold", func() -> bool: return _step_t > 1.0)
