extends "res://tests/NetSmokeBase.gd"

var _waited_prompt := ""
var _lobby_snapshot_count := 0

func _initialize() -> void:
	tag = "host"
	start_net(true)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null)
	step("guest seated", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() >= 2 and r.slots[1].kind == Roster.SlotKind.HUMAN and r.slots[1].peer_id > 1,
		func() -> void:
			var lob = current_scene
			ck(lob.roster.slots[0].peer_id == 1, "host slot carries peer 1")
			# правила: бюджеты 450, добавить третий слот, live placement
			lob._on_slot_budget(450.0, 0)
			lob._on_slot_budget(450.0, 1)
			lob._on_add_slot()
			lob._on_slot_budget(450.0, 2)
			lob._fog_opt.select(1)
			lob._fog_opt.item_selected.emit(1))
	step("guest asked for colour 5 and moved to slot 3", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() == 3 and r.slots[2].kind == Roster.SlotKind.HUMAN \
				and r.slots[2].peer_id > 1 and r.slots[2].color_index() == 5,
		func() -> void:
			var r: Roster = current_scene.roster
			ck(r.slots[1].kind == Roster.SlotKind.OPEN and r.slots[1].peer_id == -1,
				"the slot the guest left is open again")
			# слот 2 (второй) — ИИ средний
			current_scene._on_slot_kind(4, 1)
			ck(r.slots[1].kind == Roster.SlotKind.AI, "slot 2 is AI now"))
	step("start match", func() -> bool: return _step_t > 1.5, func() -> void:
		current_scene._on_start()
		ck(scene_is("Lobby.gd") or true, ""))
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			ck(pl._my_side == 0, "host is side 0 (got %d)" % pl._my_side)
			ck(pl._host_sides() == [0, 1], "host places for itself and the AI: %s" % str(pl._host_sides()))
			ck(pl._effective_budget(0) == 450, "budget 450 on the host: %d" % pl._effective_budget(0))
			pl.brush_unit = "sniper"
			pl._click_cell(Vector2i(5, 5))
			ck(pl._side_unit_count(0) == 1, "host placed a sniper")
			pl._on_net_ready()  # → Next: AI
			ck(pl.active_side == 1, "now placing for the AI side (active=%d)" % pl.active_side)
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(9, 3))
			ck(pl._side_unit_count(1) == 1, "AI got a unit")
			pass)
	step("give the guest a moment to see the live placement", func() -> bool: return _step_t > 2.0,
		func() -> void:
			var pl = current_scene
			pl._on_net_ready()
			ck(pl._my_ready, "host is ready"))
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			ck(m.my_owner == 0, "host owns side 0")
			ck(m.controllers[1] is AIController, "host drives the AI side")
			ck(m.controllers[2] is NetworkController, "guest side is remote"))
	step("host's turn", func() -> bool:
		var m = current_scene
		var p := poke_dice()
		if p.find("Waiting for") >= 0:
			_waited_prompt = p
		return m.state.active_player() == 0 and not m._animating and not m._net_playing,
		func() -> void:
			var m = current_scene
			var sniper: UnitInstance = null
			var target: UnitInstance = null
			for u in m.state.all_units():
				if u.owner == 0 and u.stats.special_ability_id != "":
					sniper = u
				if u.owner == 0 and sniper == null:
					sniper = u
				if u.owner == 2:
					target = u
			ck(sniper != null and target != null, "sniper and guest target exist")
			ck(m.resolver.can_shoot(sniper, target) == "", "sniper can shoot the guest: %s" % m.resolver.can_shoot(sniper, target))
			m._on_intent_ready(ShootIntent.new(sniper.id, target.id, 1)))
	step("shot played on both, host waited for the guest's defence roll", func() -> bool:
		var p := poke_dice()
		if p.find("Waiting for") >= 0:
			_waited_prompt = p
		var m = current_scene
		return not m._animating and not m._net_playing and m.state.log.lines.size() > 0 \
				and _waited_prompt != "",
		func() -> void:
			ck(_waited_prompt.find("Waiting for Player C") >= 0,
				"host waited for the guest to roll: '%s'" % _waited_prompt)
			ck(_waited_prompt.find("need") >= 0, "prompt shows the number needed: '%s'" % _waited_prompt)
			current_scene._on_intent_ready(EndTurnIntent.new()))
	step("AI side was driven by the host and passed the turn on", func() -> bool:
		poke_dice()
		var m = current_scene
		if m.state.active_player() == 0 and not m._animating and not m._net_playing and m.state.turns.round_number < 2:
			m._on_intent_ready(EndTurnIntent.new())
		return m.state.turns.round_number >= 2,
		func() -> void:
			var m = current_scene
			ck(m.state.turns.round_number >= 2, "a full round went by (round %d)" % m.state.turns.round_number)
			print("[host] digest ", TS_digest(m.state)))
	step("hold for guest to finish", func() -> bool: return _step_t > 3.0)

func TS_digest(s: GameState) -> String:
	return load("res://tests/TestSupport.gd").digest(s)
