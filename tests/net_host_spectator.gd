extends "res://tests/NetSmokeBase.gd"

var initial_turn := -1
var _draw_messages := 0

func _initialize() -> void:
	tag = "spectator-host"
	start_net(true)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null)
	step("two spectators seated", func() -> bool: return NetHandoff.spectators.size() == 2, func() -> void:
		var lobby = current_scene
		while lobby.roster.slots.size() > 2: lobby._on_remove_slot(lobby.roster.slots.size() - 1)
		lobby._on_slot_kind(3, 1)
		lobby._civ_check.button_pressed = false)
	step("start", func() -> bool: return _step_t > 1.0, func() -> void: current_scene._on_start())
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null, func() -> void:
		var pl = current_scene
		for side in [0, 1]:
			pl.brush_unit = "heavy_infantry"
			for cell: Vector2i in pl._zone_cells_of(side):
				if pl._footprint_placeable("heavy_infantry", cell, side):
					pl._click_cell(cell)
					break
			ck(pl._side_unit_count(side) > 0, "side %d deployed" % side)
			pl._on_net_ready())
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null, func() -> void:
		initial_turn = current_scene.state.active_player()
		session().message.connect(func(msg: Dictionary) -> void:
			if str(msg.get("k", "")) == "draw": _draw_messages += 1))
	step("spectator permissions and private drawings", func() -> bool:
		poke_dice()
		return _step_t > 12.0, func() -> void:
		ck(_draw_messages == 0, "spectator drawings never reach a player")
		ck(current_scene._canvases.is_empty(), "player board contains no spectator drawings"))
