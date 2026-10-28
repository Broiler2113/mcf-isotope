extends "res://tests/SuiteBase.gd"

## Hotseat handoffs copy and compare only the cells where a fog memory can be out of date
## (MainFogMemory._fog_mem_dirty). That rests on one invariant, checked here after every
## handoff of a hotseat match: outside its out-of-date cells a memory looks exactly like the
## live board, and the viewer's memory matches the board everywhere the viewer sees.
const Bench := preload("res://tests/bench/run_bench.gd")

func run() -> void:
	var cfg: Dictionary = Bench.SCENES.large
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 40
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.roster = Roster.default_duel(false)   # two local humans: hotseat
	MapHandoff.pending = Bench.build_map(cfg)
	MapHandoff.dice_seed = int(cfg.seed) * 7919
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 10: await process_frame
	var ai := {}
	var picked: Array = []
	for side: int in main.state.roster.player_ids():
		ai[side] = AIController.new(side, AIController.Difficulty.HARD)
		(ai[side] as AIController).intent_ready.connect(func(it: Intent) -> void: picked.append(it))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for turn in 6:
		for j in 20:
			var side: int = main.state.active_player()
			picked.clear()
			if (ai[side] as AIController).wants_plan(main.state):
				await (ai[side] as AIController).think_ahead(main.state, 1 << 30)
			(ai[side] as AIController).begin_turn(main.state)
			var it: Intent = picked[0] if not picked.is_empty() else EndTurnIntent.new()
			if it is EndTurnIntent: break
			main.resolver.resolve(it)
			main._redraw()
			await process_frame
		# Changes nobody is watching: what the other side must find when it looks again.
		var seen: Dictionary = main._visible_before_impact(main._viewing_side())
		for k in 40:
			var c := Vector2i(rng.randi_range(0, main.state.grid.width - 1), rng.randi_range(0, main.state.grid.height - 1))
			var cell: GridCell = main.state.grid.cell(c)
			if seen.has(c) or cell.occupant != null or cell.is_wall(): continue
			if k % 2 == 0: cell.on_fire = not cell.on_fire
			else: cell.dirt_level = (cell.dirt_level + 1) % 3
		main._redraw()
		await process_frame
		main._on_intent_ready(EndTurnIntent.new(main.state.active_player()))
		for i in 3: await process_frame
		_check(main, "handoff %d" % turn)
	main.queue_free()

func _check(main: Node, label: String) -> void:
	var live: Grid = main.state.grid
	var lc := live.cells_flat()
	var viewer: int = main._viewing_side()
	var seen: Dictionary = main._visible_before_impact(viewer)
	ck(not main._fog_mem.is_empty(), "%s: no fog memories" % label)
	for side: int in main._fog_mem:
		var mem: Grid = main._fog_mem[side]
		var dirty: Variant = main._fog_mem_dirty.get(mem)
		var stale := 0
		var behind := 0
		var mc := mem.cells_flat()
		for i in lc.size():
			var differs: bool = main._looks_differ(mc[i], lc[i]) \
					or mem.look_at(lc[i].coord.x, lc[i].coord.y) != live.look_at(lc[i].coord.x, lc[i].coord.y)
			if not differs: continue
			if dirty != null and not (dirty as Dictionary).has(i): stale += 1
			if side == viewer and seen.has(lc[i].coord): behind += 1
		ck(stale == 0, "%s: side %d's memory differs from the board at %d untracked cells" % [label, side, stale])
		ck(behind == 0, "%s: viewer %d's memory is behind the board at %d cells in view" % [label, side, behind])
