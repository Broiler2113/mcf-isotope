extends SceneTree
## Batch mp-perf: the incremental airlock and civilian-wake checks give EXACTLY the full
## checks' result (two resolvers, same game, board compared after every action), and the
## effects' random seeds come from the game state, so every peer draws the same decals.
const AB = preload("res://rl/ArmyBuilder.gd")
var fails := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1

func _initialize() -> void:
	var total_groups := 0
	for seed in [3, 8, 21]:
		# Open field, civilians scattered between two armies, a few wall stubs: soldiers walk
		# into their view and keep stepping in and out of each other's lines of sight.
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var m := MapData.new(36, 20)
		for y in 20:
			for x in 36:
				m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
		for i in 14:
			m.set_cell(Vector2i(rng.randi_range(8, 27), rng.randi_range(1, 18)), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
		for i in 18:
			m.set_spawn(Vector2i(rng.randi_range(12, 23), rng.randi_range(1, 18)), "civilian", MCF.Owner.NEUTRAL)
		for y in range(2, 18, 2):
			m.set_spawn(Vector2i(1, y), "light_infantry", 0)
			m.set_spawn(Vector2i(3, y + 1), "machinegunner", 0)
			m.set_spawn(Vector2i(34, y), "light_infantry", 1)
			m.set_spawn(Vector2i(32, y + 1), "machinegunner", 1)
		GameConfig.civilians_enabled = true
		GameConfig.civilian_count = 18
		var a := m.build_state(seed)
		var b := m.build_state(seed)
		var ra := GameActionResolver.new(a)
		var rb := GameActionResolver.new(b)
		rb.check_everything = true
		ra.update_airlocks()
		rb.update_airlocks()
		var ais := {}
		var pend := [null]
		for pid in a.roster.player_ids():
			var ai := AIController.new(pid, AIController.Difficulty.HARD)
			ai.intent_ready.connect(func(i): pend[0] = i)
			ais[pid] = ai
		var same := true
		var woke := 0
		var n := 0
		while n < 1200 and a.turns.round_number <= 12:
			var ai: AIController = ais.get(a.active_player())
			pend[0] = null
			if ai != null:
				ai.begin_turn(a)
			var it: Intent = pend[0] if pend[0] != null else EndTurnIntent.new()
			var wire := IntentCodec.encode(it)
			var ia := ra.resolve(it)
			var ib := rb.resolve(IntentCodec.decode(wire))
			n += 1
			if a.digest_hash() != b.digest_hash() or ia.ok != ib.ok:
				same = false
				print("   diverged at action %d (%s)" % [n, wire])
				break
		var groups := 0
		for u in a.all_units():
			if u.neutral_group > 0:
				groups += 1
		total_groups += groups
		ck(same, "seed %d: incremental checks == full checks over %d actions (%d woken civilians)" % [seed, n, groups])
	ck(total_groups > 0, "civilians actually woke during these games (%d)" % total_groups)
	_fx_identical_on_every_peer()
	print("mp perf: %d failure(s)" % fails)
	quit(1 if fails else 0)

## Host and guest NetGame back to back, HARD vs HARD. Each side's decal layer applies the
## effects of every action it plays; the guest's starts with a different local event count
## (as after a late join or resync). Blood, shards, casings and rubble must still match.
func _fx_identical_on_every_peer() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var m := MapData.new(30, 16)
	for y in 16:
		for x in 30:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for y in range(3, 13, 3):
		m.set_cell(Vector2i(14, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_GLASS)
	for y in range(1, 15, 2):
		m.set_spawn(Vector2i(4, y), "machinegunner" if y % 4 == 1 else "anti_tank", 0)
		m.set_spawn(Vector2i(25, y), "light_infantry" if y % 4 == 1 else "anti_tank", 1)
	GameConfig.civilians_enabled = false
	var hs := m.build_state(9)
	var gs := m.build_state(9)
	var host := NetGame.new(hs, GameActionResolver.new(hs), true, 0)
	var guest := NetGame.new(gs, GameActionResolver.new(gs), false, 1)
	host.resolver.fog_mode = MCF.Fog.OFF
	guest.resolver.fog_mode = MCF.Fog.OFF
	var hfx := FxDecals.new()
	var gfx := FxDecals.new()
	gfx._event_seq = 777
	host.action_applied.connect(func(_i, r: ActionResult) -> void: hfx.apply(r.fx))
	guest.action_applied.connect(func(_i, r: ActionResult) -> void: gfx.apply(r.fx))
	# Method forwarding avoids retaining both RefCounted peers through opposing lambdas.
	host.outgoing.connect(guest.receive)
	var resyncs := [0]
	guest.outgoing.connect(func(msg: Dictionary) -> void:
		resyncs[0] += 1
		host.receive(msg))
	var ais := {}
	var pend := [null]
	for pid in hs.roster.player_ids():
		var ai := AIController.new(pid, AIController.Difficulty.HARD)
		ai.intent_ready.connect(func(i): pend[0] = i)
		ais[pid] = ai
	for n in 250:
		var ai: AIController = ais.get(hs.active_player())
		pend[0] = null
		if ai != null:
			ai.begin_turn(hs)
		host.submit_local(pend[0] if pend[0] != null else EndTurnIntent.new())
		hfx.advance(10.0)
		gfx.advance(10.0)
	var hd := hfx.to_dict()
	ck(hd["props"].size() > 10, "the battle left decals (%d)" % hd["props"].size())
	ck(resyncs[0] == 0 and JSON.stringify(hd) == JSON.stringify(gfx.to_dict()),
			"blood, shards, casings and rubble are identical on host and guest")
	var late := FxDecals.new()
	late.from_dict(hd)
	ck(JSON.stringify(late.to_dict()) == JSON.stringify(hd), "a resync copies the host's decals exactly")
