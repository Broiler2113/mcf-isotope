extends "res://tests/SuiteBase.gd"
## Multiplayer rules: lobby rules reaching guests, presentation of network actions, the
## host answering intents for someone else's unit.

func run() -> void:
	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	await _network_presentation()

	_lobby_rules_carry_new_settings()

	_host_answers_foreign_intents()

	await _teammates_see_placement_in_fog()

	_relay_packs_big_messages()

var MainScript: GDScript

func make_main(m: MapData) -> Node:
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main.state.turns.round_order = [0, 1] as Array[int]
	main.state.turns.active_index = 0
	return main

func _network_presentation() -> void:
	var m := MapData.blank_arena(18, 12)
	m.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	m.set_spawn(Vector2i(8, 4), "light_infantry", 1)
	m.set_spawn(Vector2i(15, 9), "light_infantry", 1)
	var main := make_main(m)
	await process_frame
	var shooter: UnitInstance = main.state.grid.cell(Vector2i(3, 4)).occupant
	var victim: UnitInstance = main.state.grid.cell(Vector2i(8, 4)).occupant
	main.state.dice.feed_scripted([6, 1])
	var shot: ActionResult = main.resolver.resolve(ShootIntent.new(shooter.id, victim.id, 1))
	ck(shot.ok and shot.visual_deaths.has(victim.id), "successful shot records its visual casualty")
	root.get_node("Ui").autoroll_dice = false
	main._show_net_action(ShootIntent.new(shooter.id, victim.id, 1), shot)
	await process_frame
	ck(main._pending_death_ids.has(victim.id) and not main._corpse_map().has(victim.coord), "network victim remains alive visually before attack and defense dice")
	main.net = NetGame.new(main.state, main.resolver, false, 1)
	var other: UnitInstance = main.state.grid.cell(Vector2i(15, 9)).occupant
	var target := Vector2i(14, 9)
	var packet := {"k": NetGame.K_ACTION, "i": IntentCodec.encode(MoveIntent.new(other.id, target)), "r": []}
	main._net_playing = true
	main._on_net_message(packet)
	ck(other.coord == Vector2i(15, 9) and main._net_messages.size() == 1, "later network actions cannot mutate the board while a roll is showing")
	# Finish both manual rolls, including their timer-driven presentation.
	var deadline := Time.get_ticks_msec() + 10000
	while main._animating and Time.get_ticks_msec() < deadline:
		if main._dice._roll_btn.visible: main._dice._roll_btn.pressed.emit()
		await process_frame
	main.state.turns.active_index = 1
	main._net_playing = false
	main._drain_net_messages()
	ck(other.coord == target and main._net_messages.is_empty(), "queued network movement reaches the exact requested tile after the shot")
	main.free()
	await process_frame

## 5/11: новые правила лобби доходят до гостя.
func _lobby_rules_carry_new_settings() -> void:
	var keep_c := GameConfig.civilian_count
	var keep_s := GameConfig.ai_speed
	GameConfig.civilian_count = 17
	GameConfig.ai_speed = 2.0
	var rules := NetHandoff.encode_rules()
	GameConfig.civilian_count = 200
	GameConfig.ai_speed = 1.0
	NetHandoff.apply_rules(rules)
	ck(GameConfig.civilian_count == 17 and GameConfig.ai_speed == 2.0,
			"civilians (%d) and AI speed (%.1f) reach the guest" % [GameConfig.civilian_count, GameConfig.ai_speed])
	GameConfig.civilian_count = keep_c
	GameConfig.ai_speed = keep_s
	GameConfig.roster = null

func arena(body_under_spawn := false) -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 5), "light_infantry", 1)
	if body_under_spawn: map.corpses.append(5 * 22 + 18)
	var s := map.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

## The host answers an intent for someone else's unit, so the sender's controls unlock.
func _host_answers_foreign_intents() -> void:
	var r := arena()
	r.state.roster.slot(1).kind = Roster.SlotKind.HUMAN
	r.state.roster.slot(1).peer_id = 7
	var host := NetGame.new(r.state, r, true)
	var sent: Array = []
	host.outgoing.connect(func(m: Dictionary) -> void: sent.append(m))
	var foreign := r.state.grid.cell(Vector2i(2, 5)).occupant
	host.receive({"k": NetGame.K_INTENT, "_from": 7, "i": IntentCodec.encode(MoveIntent.new(foreign.id, Vector2i(3, 5)))})
	ck(sent.size() == 1 and sent[0].k == NetGame.K_DENIED and int(sent[0].p) == 1, "unauthorized guest request is denied to its sender")
	var guest := NetGame.new(r.state, r, false, 1)
	var unlocked := [false]
	guest.denied.connect(func(_why: String) -> void: unlocked[0] = true)
	guest.receive(sent[0])
	ck(unlocked[0], "the guest receives the denial")

class SentLog extends NetworkSession:
	var sent: Array = []
	func send(msg: Dictionary) -> void:
		sent.append(msg)

## fix-7 #3: under fog (where the lobby turns live placement off) a player's deployment
## still goes out live, and teammates draw it; enemies still don't.
func _teammates_see_placement_in_fog() -> void:
	var keep_fog := GameConfig.fog_mode
	var keep_live := GameConfig.live_placement_visible
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.live_placement_visible = false
	for teams: bool in [true, false]:
		var ro := Roster.new()
		ro.add_slot(Roster.SlotKind.HUMAN, 0 if teams else -1)
		ro.add_slot(Roster.SlotKind.HUMAN, 0 if teams else -1)
		ro.add_slot(Roster.SlotKind.HUMAN, 1 if teams else -1)
		GameConfig.roster = ro
		MapHandoff.pending = MapData.blank_arena(30, 20)
		var p = load("res://scenes/Placement.tscn").instantiate()
		root.add_child(p)
		await process_frame
		var log := SentLog.new()
		p._net = log
		p._my_side = 0
		p._send_live()
		var live := log.sent.filter(func(m: Dictionary) -> bool: return m.get("k", "") == p.K_LIVE)
		if teams:
			ck(not live.is_empty(), "with a teammate, deployment goes out live under fog")
			p.active_side = 0
			ck(not p._army_hidden(1) and p._army_hidden(2), "a teammate's army is drawn, an enemy's is not")
		else:
			ck(live.is_empty(), "without teammates nothing goes out live under fog")
		p._net = null
		log.free()
		p.free()
		await process_frame
	GameConfig.fog_mode = keep_fog
	GameConfig.live_placement_visible = keep_live
	GameConfig.roster = Roster.default_duel(false)

## 0.14.7.2: a long match's load message was ~46 MB, the relay drops frames over 32 MB and
## with them the whole room. Packed, it must fit and come back intact.
func _relay_packs_big_messages() -> void:
	var cells := PackedInt32Array()
	cells.resize(9_000_000)
	for i in cells.size(): cells[i] = i % 7
	var msg := {"k": NetHandoff.K_LOAD, "s": {"cells": Array(cells)}}
	var packed := NetworkSession._pack(msg)
	ck(var_to_bytes(msg).size() > 32 << 20 and packed.size() < 32 << 20, "a >32 MB message packs under the relay frame cap (%d bytes)" % packed.size())
	var back: Variant = NetworkSession._unpack(packed)
	ck(back is Dictionary and back.s.cells.size() == cells.size() and back.s.cells[12345] == 12345 % 7, "packed message unpacks intact")
	ck(NetworkSession._unpack(PackedByteArray([1, 2, 3, 4, 5])) == null, "garbage payload is ignored")
	# fix-12: whatever its size, a message crosses the relay in frames of at most 1 MB + 1.
	var noise := PackedByteArray()
	noise.resize(3 * NetworkSession.PIECE + 777)
	for i in noise.size(): noise[i] = (i * 2654435761) >> 13 & 0xFF
	var frames := NetworkSession._split(noise)
	var session := NetworkSession.new()
	var joined := PackedByteArray()
	for f: PackedByteArray in frames:
		ck(f.size() <= NetworkSession.PIECE + 1, "a relay frame stays within one piece")
		var got := session._join_piece(5, f)
		if not got.is_empty(): joined = got
	ck(frames.size() == 4 and joined == noise, "pieces reassemble into the exact message")
	ck(session._join_piece(5, NetworkSession._split(PackedByteArray([9, 8]))[0]) == PackedByteArray([9, 8]), "a small message is one whole frame")
	session.free()
	var save := {"state": {"a": 1}, "history": {"source": {"steps": [1, 2, 3]}}}
	var load_msg := NetHandoff.encode_load(save)
	ck(not load_msg.s.has("history") and load_msg.s.state.a == 1 and save.has("history"), "the load message leaves the host's history behind, untouched")
