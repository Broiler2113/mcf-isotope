extends "res://tests/NetSmokeBase.gd"

## Ушедшего игрока подменяет ИИ высокой сложности (batch 13 #2) — в лобби, на закупке и в
## бою, — а гость, севший в слот, который хост заранее выставил в «Player», начинает
## партию, а не остаётся за бортом (batch 13 #11). Гость здесь уходит ДВАЖДЫ: из лобби
## (слот → Hard AI, хост добавляет открытый слот, гость возвращается в него) и с закупки
## после того, как хост уже нажал Ready (хост доставляет армию за ушедшего и играет
## один против двух машин).
func _initialize() -> void:
	tag = "host-l"
	start_net(true)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null,
		func() -> void:
			# host reserves a Player seat by hand before the guest arrives (item 11)
			current_scene._on_slot_kind(2, 1))
	step("guest seated into the reserved Player slot", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() == 2 and r.slots[1].kind == Roster.SlotKind.HUMAN and r.slots[1].peer_id > 1,
		func() -> void:
			var lob = current_scene
			lob._on_add_slot()  # slot 3 open; guest 2 (the same process reconnects later) will land there
			)
	step("guest left the lobby -> hard AI", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots[1].kind == Roster.SlotKind.AI and r.slots[1].ai_difficulty == AIController.Difficulty.HARD,
		func() -> void:
			print("[host-l] slot 2 is hard AI after leave"))
	step("guest re-joined into the open slot 3", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() == 3 and r.slots[2].kind == Roster.SlotKind.HUMAN and r.slots[2].peer_id > 1,
		func() -> void: current_scene._on_start())
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(3, 3))
			pl._on_net_ready()  # -> AI side 1
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(9, 3))
			pl._on_net_ready()  # ready
			ck(pl._my_ready, "host ready"))
	step("guest left placement -> host un-readied to deploy for side 2 as AI", func() -> bool:
		var pl = current_scene
		return not pl._my_ready and pl.active_side == 2 and pl.roster.slots[2].kind == Roster.SlotKind.AI,
		func() -> void:
			var pl = current_scene
			pl.brush_unit = "light_infantry"
			pl._click_cell(Vector2i(17, 5))
			pl._on_net_ready())
	step("battle up alone (all AI opponents)", func() -> bool: return scene_is("Main.gd"),
		func() -> void:
			var m = current_scene
			ck(m.controllers[1] is AIController and m.controllers[2] is AIController, "both sides AI-driven"))
	step("a round goes by", func() -> bool:
		poke_dice()
		var m = current_scene
		if m.state.active_player() == 0 and not m._animating and not m._net_playing and m.state.turns.round_number < 2:
			m._on_intent_ready(EndTurnIntent.new())
		return m.state.turns.round_number >= 2 or m._match_over)
