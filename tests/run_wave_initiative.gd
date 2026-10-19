extends SceneTree
## Holdout waves in the initiative (2026-10-18 owner request): every wave is its own entry,
## "Wave I", "Wave II", …, placed at a random spot in the order like a raider army, and
## only that wave acts on its turn. Saves, undo and the lists in Main follow the slots.

var fails := 0
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails += 1
func _initialize() -> void: run.call_deferred()

func holdout() -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.HOLDOUT
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	GameConfig.roster = ro
	var map := MapData.blank_arena(30, 20)
	map.set_spawn(Vector2i(14, 10), "heavy_infantry", 0)
	var s := map.build_state(11, ro)
	var r := GameActionResolver.new(s)
	r.random_events = RandomEvents.new(false)
	r.prepare_mode(map)
	r.fog_enabled = false
	r.mode.defender_value = 400
	return r

func land(r: GameActionResolver, edge: int) -> void:
	r.mode.pending_wave = {"edge": edge, "along": 8}
	r._land_wave(ActionResult.success([]))

func run() -> void:
	var r := holdout()
	var tm := r.state.turns
	var side := r.mode.wave_side
	land(r, 0)
	land(r, 2)
	var w1 := MCF.wave_slot(1)
	var w2 := MCF.wave_slot(2)
	ck(tm.round_order.has(w1) and tm.round_order.has(w2), "each wave gets its own initiative slot (%s)" % [tm.round_order])
	ck(MCF.owner_name(w1) == "Wave I" and MCF.owner_name(w2) == "Wave II", "named Wave I, Wave II")
	ck(not tm.playable(side, r.state.all_units()), "the plain Waves slot holds no one and is skipped")
	ck(tm.playable(w1, r.state.all_units()) and tm.playable(w2, r.state.all_units()), "both wave slots play")
	# Positions are drawn from the shared dice: different seeds place the slots differently.
	var seen := {}
	for seed in range(1, 13):
		var q := holdout()
		q.state.dice = DiceService.new(seed)
		land(q, 0)
		seen[q.state.turns.round_order.find(w1)] = true
	ck(seen.size() >= 2, "a wave's place in the order is random (%d positions over 12 seeds)" % seen.size())

	# On Wave I's turn only Wave I acts: the AI moves just its own wave and the rules refuse Wave II.
	while tm.active_slot() != w1:
		r.resolve(EndTurnIntent.new())
	ck(tm.active_player() == side, "a wave slot plays for the waves side")
	var one: UnitInstance = r.state.all_units().filter(func(u: UnitInstance) -> bool: return u.neutral_group == 1)[0]
	var two: UnitInstance = r.state.all_units().filter(func(u: UnitInstance) -> bool: return u.neutral_group == 2)[0]
	var free := Vector2i(-1, -1)
	for n in r.state.grid.neighbors(two.coord):
		if not r.state.grid.blocks_walk(n): free = n
	var refused := r.resolve(MoveIntent.new(two.id, free))
	ck(not refused.ok and refused.reason == "It's another wave's turn", "Wave II can't move on Wave I's turn (%s)" % refused.reason)
	var legal: Array = LegalIntents.enumerate(r, side)
	ck(legal.all(func(it: Intent) -> bool: return it is EndTurnIntent or it.get("actor_id") != two.id), "legal actions offer only Wave I's soldiers")
	var ai := AIController.new(side)
	var moved := {}
	var steps := 0
	while tm.active_slot() == w1 and steps < 80:
		steps += 1
		var it: Intent = ai._decide(r.state)
		if it == null: break
		var res := r.resolve(it)
		if res.ok and it.get("actor_id") != null: moved[int(it.get("actor_id"))] = true
		if it is EndTurnIntent: break
	ck(not moved.has(two.id) and moved.keys().all(func(id: int) -> bool: return r.state.get_unit(id) == null or r.state.get_unit(id).neutral_group != 2), "the AI moves only Wave I on its turn (%d actors)" % moved.size())

	# Saves and undo keep the slots and who plays them.
	var loaded := StateCodec.decode(JSON.parse_string(JSON.stringify(StateCodec.encode(r.state))))
	ck(loaded.turns.wave_owner == side and loaded.turns.round_order.has(w2), "a save keeps the wave slots")
	var snap := r.state.snapshot(false)
	r.state.turns.wave_owner = -1
	r.state.restore(snap)
	ck(r.state.turns.wave_owner == side, "undo keeps the wave slots' owner")

	# Main lists the waves as their own entries and marks the one playing now.
	var display = load("res://scenes/Main.gd").new()
	display.state = r.state
	display.resolver = r
	var counts: Dictionary = display._army_counts()
	ck(int(counts.get(w1, {}).get("alive", 0)) > 0 and int(counts.get(side, {"alive": 0, "dead": 0}).get("alive", 0)) == 0, "counts go to each wave, not to Waves")
	ck(display._side_label(w2) == "Wave II" and display._side_color(w2) == r.state.roster.color_of(side), "Wave II carries the waves' color")
	ck(display._turn_now() == tm.active_slot(), "the active slot is what the lists highlight")
	display.free()
	print("wave initiative: %d failure(s)" % fails)
	quit(0 if fails == 0 else 1)
