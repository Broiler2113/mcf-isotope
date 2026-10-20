extends SceneTree

## Large-battle speedups that must not change a thing (2026-10 perf pass).
##
##   1. StateCodec reuses the record of every cell whose rev has not moved. Through an AI
##      game with fire, blasts and lamps shot out, the cached encoding is byte-for-byte the
##      encoding of a cold cache, and records handed out earlier never change afterwards.
##   2. _sync_gas visits only clouded cells and cells inside a cloud; after random clouds,
##      smoke, stray gas and lifted clouds, every cell matches the whole-board rule.

var fails: PackedStringArray = []
var _pending: Intent = null

func _initialize() -> void:
	_encode_cache_matches_cold()
	_gas_sync_matches_full_pass()
	if fails.is_empty():
		print("large battles: cached cell encoding == cold encoding through a game; gas sync == full pass")
		quit(0)
		return
	printerr("large battles: %d failure(s)" % fails.size())
	for f in fails.slice(0, 30):
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _cold_encode(st: GameState) -> Dictionary:
	StateCodec._rec_grid = 0
	return StateCodec.encode(st)

func _encode_cache_matches_cold() -> void:
	var m := MapGen.generate({"style": MapGen.Style.TOWN, "size": 1, "seed": 12, "civilians": 2})
	var squad := ["light_infantry", "heavy_infantry", "flamethrower", "anti_tank", "engineer", "sapper"]
	for side in [0, 1]:
		var cells := m.zone_cells(side)
		for k in squad.size():
			m.set_spawn(cells[(k * 5) % cells.size()], squad[k], side)
	var st := m.build_state(3)
	var r := GameActionResolver.new(st)
	r.update_airlocks()
	r.play_civilian_slots()
	var brains := {}
	for side in [0, 1]:
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.intent_ready.connect(func(i: Intent) -> void: _pending = i)
		brains[side] = ai
	var first := StateCodec.encode(st)
	var first_bytes := var_to_bytes(first)
	var bad := 0
	var changed := 0
	var last := var_to_bytes(first)
	for step in 150:
		var side: int = st.active_player()
		_pending = null
		if brains.has(side):
			brains[side].begin_turn(st)
		r.resolve(_pending if _pending != null else EndTurnIntent.new())
		if step % 3 != 0:
			continue
		var warm := var_to_bytes(StateCodec.encode(st))
		var cold := var_to_bytes(_cold_encode(st))
		if warm != cold:
			bad += 1
		if warm != last:
			changed += 1
		last = warm
	ck(changed > 10, "the board changed during the game (%d encodings differed)" % changed)
	ck(bad == 0, "warm encoding == cold encoding at every check (%d differ)" % bad)
	ck(var_to_bytes(first) == first_bytes, "an encoding handed out earlier never changes afterwards")

func _gas_sync_matches_full_pass() -> void:
	var m := MapGen.generate({"style": MapGen.Style.STATION, "size": 1, "seed": 4})
	var st := m.build_state(2)
	var r := GameActionResolver.new(st)
	r.random_events = RandomEvents.new(true, false, 1, RandomEvents.default_weights())
	var grid := st.grid
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var bad := 0
	var gassed := 0
	for step in 40:
		var ev := r.random_events
		if rng.randf() < 0.5:
			ev.add_cloud(rng.randi_range(-3, grid.width), rng.randi_range(-3, grid.height),
					rng.randi_range(1, 9), rng.randi_range(1, 9), 2)
		if rng.randf() < 0.4:
			ev.add_smoke(rng.randi_range(0, grid.width - 1), rng.randi_range(0, grid.height - 1), 3, 3, 1)
		if rng.randf() < 0.3:
			ev.age_clouds()
		if rng.randf() < 0.3:
			ev.age_smoke()
		if rng.randf() < 0.2:
			var stray := grid.cell(Vector2i(rng.randi_range(0, grid.width - 1), rng.randi_range(0, grid.height - 1)))
			stray.gas = true   # left over from a cloud that has since lifted
		r._sync_gas()
		for c: GridCell in grid.cells_flat():
			var want_gas := c.can_hold_gas() and ev.cloud_at(c.coord)
			var want_smoke := c.can_hold_gas() and ev.smoke_at(c.coord)
			if c.gas != want_gas or c.smoke != want_smoke:
				bad += 1
			if c.gas:
				gassed += 1
	ck(gassed > 100, "clouds covered cells during the check (%d)" % gassed)
	ck(bad == 0, "every cell matches the whole-board gas rule after each sync (%d differ)" % bad)
	r.random_events.clouds.clear()
	r.random_events.smoke.clear()
	r._sync_gas()
