extends "res://tests/NetSmokeBase.gd"

var _waited_prompt := ""
var _live_seen := false

func _initialize() -> void:
	tag = "guest"
	start_net(false)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null)
	step("snapshot with 3 slots and budgets 450 arrived", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() == 3 and r.slots[1].budget == 450 and current_scene._my_slot() != null,
		func() -> void:
			var lob = current_scene
			ck(lob._my_slot().id == 1, "guest sits in slot 2 (id 1): %d" % lob._my_slot().id)
			ck(lob._fog_opt.selected == 1, "fog option mirrored from the host: %d" % lob._fog_opt.selected)
			ck(GameConfig.fog_mode == 1, "GameConfig.fog_mode synced")
			lob._on_my_color(5)
			lob._on_join_slot(2))
	step("moved to slot 3 with colour 5", func() -> bool:
		var lob = current_scene
		return lob._my_slot() != null and lob._my_slot().id == 2 and lob._my_slot().color_index() == 5)
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			ck(pl._my_side == 2, "guest is side 2 (got %d)" % pl._my_side)
			ck(pl._effective_budget(2) == 450, "budget 450 on the guest: %d" % pl._effective_budget(2))
			ck(GameConfig.roster.slots[1].kind == Roster.SlotKind.AI, "guest knows slot 2 is AI")
			ck(pl._side_color(2).is_equal_approx(Roster.PALETTE[5]), "guest places in its chosen colour")
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(17, 5))
			ck(pl._side_unit_count(2) == 1, "guest placed a unit"))
	step("host's live/ready units visible, then ready", func() -> bool:
		var pl = current_scene
		if not pl._live_units.is_empty():
			_live_seen = true
		return pl._remote_units.has(0) and pl._remote_units.has(1),
		func() -> void:
			var pl = current_scene
			ck(pl._remote_units[0].size() == 1 and pl._remote_units[1].size() == 1,
				"host's and AI's armies arrived")
			pl._on_net_ready())
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			ck(m.my_owner == 2, "guest owns side 2 (got %d)" % m.my_owner)
			ck(m.controllers[1] is NetworkController, "AI side is remote for the guest"))
	step("saw the host's shot: waited for host's hit roll, rolled own defence", func() -> bool:
		var p := poke_dice()
		if p.find("Waiting for") >= 0:
			_waited_prompt = p
		var m = current_scene
		return _waited_prompt != "" and not m._animating and not m._net_playing \
				and m.state.turns.active_index > 0,
		func() -> void:
			ck(_waited_prompt.find("Waiting for Player A") >= 0,
				"guest waited for the host's hit roll: '%s'" % _waited_prompt)
			ck(_waited_prompt.find("need") >= 0, "prompt shows the number needed: '%s'" % _waited_prompt))
	step("round went by", func() -> bool:
		poke_dice()
		var m = current_scene
		if m.state.active_player() == 2 and not m._animating and not m._net_playing and m.state.turns.round_number < 2:
			m._on_intent_ready(EndTurnIntent.new())
		return m.state.turns.round_number >= 2,
		func() -> void:
			var m = current_scene
			print("[guest] digest ", TS_digest(m.state))
			ck(_live_seen, "guest saw the host's placement live"))

func TS_digest(s: GameState) -> String:
	return load("res://tests/TestSupport.gd").digest(s)
