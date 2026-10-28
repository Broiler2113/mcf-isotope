extends "res://tests/SuiteBase.gd"

## The soldier layer (MainDrawing._sync_unit_layer) skips soldiers whose look did not change:
## only a changed look stamp, cell or board-wide input builds a key again, and a frame where
## nothing but a walk plays visits only the walkers. Every sprite must still end up exactly
## as a full pass from scratch draws it — after AI actions and on the frames of a walk.
const Bench := preload("res://tests/bench/run_bench.gd")

func run() -> void:
	var cfg: Dictionary = Bench.SCENES.large
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 40
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.roster = Roster.default_duel(false)
	MapHandoff.pending = Bench.build_map(cfg)
	MapHandoff.dice_seed = int(cfg.seed) * 7919
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 10: await process_frame
	main.zoom = 0.8
	var ai := {}
	for side: int in main.state.roster.player_ids():
		ai[side] = AIController.new(side, AIController.Difficulty.HARD)
	var picked: Array = []
	for side: int in ai:
		(ai[side] as AIController).intent_ready.connect(func(it: Intent) -> void: picked.append(it))
	for action in 40:
		var side: int = main.state.active_player()
		picked.clear()
		if ai.has(side): (ai[side] as AIController).begin_turn(main.state)
		var it: Intent = picked[0] if not picked.is_empty() else EndTurnIntent.new()
		var u: UnitInstance = main.state.get_unit(it.actor_id) if it.actor_id >= 0 else null
		if u != null: main._center_on_cell(u.coord, true)
		await _pass(main)   # the camera moved: settle before the action
		main.resolver.resolve(it)
		await _pass(main)
		await _compare(main, "after action %d (%s)" % [action, it.get_script().resource_path.get_file()])
	# What only the look stamp tells: bodies carried, an item thrown, a civilian woken into a group.
	var soldier: UnitInstance = null
	var civilian: UnitInstance = null
	for u: UnitInstance in main.state.all_units():
		if not u.is_alive() or u.is_drone or u.aboard_vehicle_id != -1: continue
		if soldier == null and u.owner == main._viewing_side(): soldier = u
		if civilian == null and MCF.is_neutral(u.owner) and not u.civilian_active \
				and main._visible_before_impact(main._viewing_side()).has(u.coord): civilian = u
	main._center_on_cell(soldier.coord, true)
	await _pass(main)
	soldier.carried_corpses += 1
	await _pass(main)
	await _compare(main, "body picked up")
	soldier.held_item_id = MCF.ITEM_SMOKE if soldier.held_item_id == "" else ""
	await _pass(main)
	await _compare(main, "item changed")
	ck(civilian != null, "a sleeping civilian in sight")
	if civilian == null: return
	main._center_on_cell(civilian.coord, true)
	await _pass(main)
	civilian.civilian_active = true
	civilian.neutral_group = 3
	await _pass(main)
	await _compare(main, "civilian woken")
	var walkers: Array = []
	for u: UnitInstance in main.state.all_units():
		if u.is_alive() and not u.is_drone and u.aboard_vehicle_id == -1 and walkers.size() < 6:
			walkers.append(u)
	main._center_on_cell(walkers[0].coord, true)
	await _pass(main)
	for step in 3:
		for u: UnitInstance in walkers:
			main._walk_cells[u.id] = u.coord + Vector2i(step + 1, 0)
			main._walk_offset[u.id] = Vector2.ZERO
		await _pass(main)
		for sub in 3:
			# Between cell steps only the offsets move (a walk-only pass); one walker lands.
			for u: UnitInstance in walkers:
				main._walk_offset[u.id] = Vector2(4.0 * (sub + 1), -2.0)
			if sub == 2: main._walk_offset.erase(walkers[0].id)
			await _pass(main)
			await _compare(main, "walk step %d frame %d" % [step, sub])
	main._walk_cells.clear()
	main._walk_offset.clear()
	await _pass(main)
	await _compare(main, "walk ended")
	main.queue_free()

func _pass(main: Node) -> void:
	main.queue_redraw()
	await process_frame
	await process_frame

## The layer as it stands against the same board drawn from scratch.
func _compare(main: Node, label: String) -> void:
	var now := _snap(main)
	main._forget_unit_keys()
	await _pass(main)
	var full := _snap(main)
	var bad := 0
	for id: int in full:
		if str(now.get(id)) != str(full[id]): bad += 1
	ck(bad == 0, "%s: %d of %d sprites differ from a full pass" % [label, bad, full.size()])

func _snap(main: Node) -> Dictionary:
	var out := {}
	for id: int in main._unit_sprites:
		var sp: Node2D = main._unit_sprites[id]
		# A hidden sprite's key is whatever it last showed: only what is on screen counts.
		out[id] = [sp.key, sp.position] if sp.visible else ["hidden"]
	return out
