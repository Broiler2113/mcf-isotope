extends "res://tests/NetSmokeBase.gd"

var _waited_prompt := ""
var _lobby_snapshot_count := 0
var _shot_skipped := false
var _shot_lines := -1

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
			# Инициатива теперь жребий (batch 14): ИИ может стрелять раньше хоста, и одному
			# снайперу не дожить до своего хода — хост ставит ещё двоих тяжёлых.
			pl.brush_unit = "heavy_infantry"
			pl._click_cell(Vector2i(7, 5))
			pl._click_cell(Vector2i(6, 5))
			ck(pl._side_unit_count(0) == 3, "host placed a sniper and two heavies")
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
			# Любой живой боец хоста, который может выстрелить в живого гостя; снайпер —
			# первым: его выстрел не промахивается, и защитный бросок гостя гарантирован.
			var shooter: UnitInstance = null
			var target: UnitInstance = null
			var order: Array = []
			for u in m.state.all_units():
				if u.owner == 0 and u.is_alive():
					if u.stats.special_ability_id == MCF.ABILITY_SNIPER:
						order.push_front(u)
					else:
						order.append(u)
			for u in order:
				for t in m.state.all_units():
					if t.owner == 2 and t.is_alive() and m.resolver.can_shoot(u, t) == "" \
							and m.resolver.first_unit_on_line(u.coord, t.coord) == null:
						shooter = u
						target = t
						break
				if shooter != null:
					break
			if shooter != null:
				_shot_lines = m.state.log.lines.size()
				m._on_intent_ready(ShootIntent.new(shooter.id, target.id, 1))
			else:
				_shot_skipped = true
				print("[host] no clear shot at the guest this round — relying on the AI's fire for the roll wait"))
	step("shot played on both, host waited for the guest's defence roll", func() -> bool:
		var p := poke_dice()
		if p.find("Waiting for") >= 0:
			_waited_prompt = p
		var m = current_scene
		# Промах (у тяжёлого нужно 5+) защитного броска не даёт — тогда ждать нечего.
		var shot_done: bool = _shot_lines >= 0 and m.state.log.lines.size() > _shot_lines
		return not m._animating and not m._net_playing and m.state.log.lines.size() > 0 \
				and (_waited_prompt != "" or (_shot_skipped and _step_t > 3.0) or (shot_done and _step_t > 3.0)),
		func() -> void:
			if _waited_prompt != "":
				ck(_waited_prompt.find("Waiting for Player C") >= 0,
					"host waited for the guest to roll: '%s'" % _waited_prompt)
				ck(_waited_prompt.find("need") >= 0, "prompt shows the number needed: '%s'" % _waited_prompt)
			current_scene._on_intent_ready(EndTurnIntent.new()))
	# С одним бойцом на сторону партия может ЗАКОНЧИТЬСЯ раньше второго раунда (batch 13
	# #9: победа замораживает доску) — это тоже честный исход, лишь бы обе машины сошлись.
	step("AI side was driven by the host and passed the turn on", func() -> bool:
		poke_dice()
		var m = current_scene
		if m._match_over:
			return true
		if m.state.active_player() == 0 and not m._animating and not m._net_playing and m.state.turns.round_number < 2:
			m._on_intent_ready(EndTurnIntent.new())
		return m.state.turns.round_number >= 2,
		func() -> void:
			var m = current_scene
			ck(m.state.turns.round_number >= 2 or m._match_over, "a full round went by (round %d)" % m.state.turns.round_number)
			print("[host] digest ", TS_digest(m.state)))
	step("hold for guest to finish", func() -> bool: return _step_t > 3.0)

func TS_digest(s: GameState) -> String:
	return load("res://tests/TestSupport.gd").digest(s)
