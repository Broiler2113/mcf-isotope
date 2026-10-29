extends SceneTree
var failures: Array[String] = []
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	_solar()
	_uniform_events()
	await _lobby()
	_decal_cache()
	await _camera_and_materials()
	root.get_node("GameAudio").stop_all()
	await create_timer(0.15).timeout
	print("Source fixes: %d failure(s)" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _solar() -> void:
	for seed_value in [1, 4, 8]:
		var g := MapGen.build({"style": MapGen.Style.STATION, "size": 0, "seed": seed_value})
		var cells := {}
		for c: Vector2i in g._solar:
			if g.m.get_look(c.y * g.w + c.x) == MCF.Look.SOLAR: cells[c] = true
		var smallest := 9999
		var count := 0
		while not cells.is_empty():
			var todo := [cells.keys()[0]]
			cells.erase(todo[0])
			var area := 0
			while not todo.is_empty():
				var c: Vector2i = todo.pop_back()
				area += 1
				for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
					if cells.has(c + d): cells.erase(c + d); todo.append(c + d)
			smallest = mini(smallest, area)
			count += 1
		ck(count >= 1 and smallest >= 6, "station seed %d has solar structures of at least six cells (%d arrays, smallest %d)" % [seed_value, count, smallest])
	# Issues-13 #4 (undoes issues-12 #14): panels hang all around the station, not only on top.
	for opt: Dictionary in [{"seed": 1}, {"seed": 4}, {"seed": 8}, {"seed": 3, "symmetric": true, "zones": 4}]:
		var o := {"style": MapGen.Style.STATION, "size": 0}
		o.merge(opt)
		var g := MapGen.build(o)
		var hull := Rect2i()
		for i in g.w * g.h:
			if not g.m.get_space(Vector2i(i % g.w, i / g.w)) and g.m.get_look(i) != MCF.Look.SOLAR:
				var c := Vector2i(i % g.w, i / g.w)
				hull = Rect2i(c, Vector2i.ONE) if hull.size == Vector2i.ZERO else hull.expand(c)
		var sides := {}
		for i in g.w * g.h:
			if g.m.get_look(i) != MCF.Look.SOLAR: continue
			var c := Vector2i(i % g.w, i / g.w)
			if c.y < hull.position.y: sides["top"] = true
			elif c.y > hull.end.y: sides["bottom"] = true
			elif c.x < hull.position.x: sides["left"] = true
			elif c.x > hull.end.x: sides["right"] = true
		ck(sides.size() == 4, "solar panels hang off every side of the station %s (%s)" % [opt, sides.keys()])

func rolls(v: int) -> Array:
	return [v / 36 + 1, (v / 6) % 6 + 1, v % 6 + 1]
func _uniform_events() -> void:
	for count in range(1, 11):
		var events := RandomEvents.new()
		var allowed := {}
		var tally := {}
		for i in count:
			var id: String = RandomEvents.REGISTRY[i][0]
			events.weights[id] = 0.25 if i == 0 else 100 * i
			allowed[id] = true
			tally[id] = 0
		events.weights["unknown"] = 999
		var limit := 216 - 216 % count
		var dice := DiceService.new(7)
		for v in limit:
			dice.feed_scripted(rolls(v))
			var id := events._pick(dice, allowed)
			tally[id] += 1
		var uniform := true
		for n: int in tally.values(): uniform = uniform and n == limit / count
		ck(uniform and dice.fallback_rolls == 0, "%d enabled events have exactly equal probability despite legacy weights" % count)
		for v in range(limit, 216):
			dice.feed_scripted(rolls(v) + rolls(0))
			ck(events._pick(dice, allowed) == RandomEvents.MORTAR and dice.scripted_remaining() == 0, "rejection consumes shared dice without bias")
	var events := RandomEvents.new(true, true, 1, RandomEvents.default_weights())
	var host := DiceService.new(123)
	host.begin_record()
	var choices := []
	for i in 100: choices.append(events.roll_event(host))
	var guest := DiceService.new(999)
	guest.feed_scripted(host.take_log())
	var replayed := []
	for i in 100: replayed.append(events.roll_event(guest))
	ck(choices == replayed and guest.scripted_remaining() == 0 and guest.fallback_rolls == 0, "uniform choices replay identically from recorded dice")
	var st := MapData.blank_arena(12, 10).build_state(1)
	var resolver := GameActionResolver.new(st)
	resolver.random_events = events
	var recorder := ReplayRecorder.new()
	recorder.begin(st, resolver)
	var data := recorder.to_dict()
	var player := ReplayPlayer.new(data)
	player.seek(0)
	ck(not player.resolver.random_events.legacy_selection, "new replay header selects uniform events")
	data.erase("event_selection")
	player = ReplayPlayer.new(data)
	player.seek(0)
	player.state.dice.feed_scripted([6, 6, 6])
	ck(player.resolver.random_events.legacy_selection and player.resolver.random_events._pick(player.state.dice) == RandomEvents.DUST and player.state.dice.fallback_rolls == 0, "old replay uses its original modulo result and consumes only its recorded dice")
	var restored := GameActionResolver.new(st)
	StateCodec.apply_rules(restored, data.rules)
	ck(not restored.random_events.legacy_selection, "loading old match rules outside replay still uses equal chances")
	ck(NetHandoff.protocol_mismatch({"pv": 16}) != "", "previous network rules cannot join the new event rules")

func _lobby() -> void:
	GameConfig.random_events_enabled = true
	GameConfig.random_events_weights = RandomEvents.default_weights()
	GameConfig.roster = Roster.default_duel(false)
	var lobby = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	ck(lobby._army_difficulty_row.visible, "army difficulty appears when army event is enabled")
	lobby._events_check.button_pressed = false
	ck(not lobby._army_difficulty_row.visible, "disabling events hides the whole difficulty row")
	lobby._events_check.button_pressed = true
	lobby._event_pool[RandomEvents.ARMY] = false
	lobby._sync_event_rows()
	ck(not lobby._army_difficulty_row.visible, "removing army from pool hides difficulty")
	lobby._event_pool[RandomEvents.ARMY] = true
	lobby._sync_event_rows()
	ck(lobby._army_difficulty_row.visible, "re-enabling army restores difficulty")
	lobby._on_slot_color(3, 0)
	ck(lobby._color_opt.selected == 3 and lobby._preview_swatch.color == lobby.roster.slots[0].color, "slot faction updates personal selector and portrait swatch")
	lobby._on_slot_color(lobby.roster.slots[1].color_index(), 0)
	ck(lobby._color_opt.selected == 3, "rejected duplicate faction keeps personal setup synchronized")
	lobby.free()

func _decal_cache() -> void:
	var grid := Grid.new(64, 32)
	var tiles := TerrainTiles.new(grid, "town")
	var fx := FxDecals.new()
	fx._settle(fx.props, {"kind": "shard", "pos": Vector2(4.5, 4.5), "rot": 0.0, "scale": 1.0})
	tiles.sync_decals(fx)
	for x in 4: tiles._build(Vector2i(x, 0), 8)
	tiles._dirty.clear()
	var remote: ImageTexture = tiles._chunks[Vector3i(3, 0, 8)].floor
	fx.apply([{"fx": "sweep_props", "at": Vector2i(4, 4), "from": Vector2i(3, 4)}])
	tiles.sync_decals(fx)
	ck(tiles._chunks.size() == 4 and not tiles._dirty.has(Vector2i(3, 0)) and tiles._dirty.has(Vector2i.ZERO), "swept rubble invalidates local chunks and retains all cached textures")
	tiles._built = 0
	for x in 4: tiles._choose(Vector2i(x, 0), 8)
	ck(tiles._built == 1 and tiles._chunks[Vector3i(3, 0, 8)].floor == remote, "drive frame keeps its one-chunk rebuild budget")
	ck(fx.flying.size() == 1 and fx.props.is_empty(), "optimization preserves the scattered particle")
	fx.advance(2.0)
	tiles.sync_decals(fx)
	fx.clear()
	tiles.sync_decals(fx)
	ck(tiles._dirty.has(Vector2i.ZERO) and tiles.decals.is_empty(), "clearing effects still removes baked debris")

func _camera_and_materials() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var map := MapData.blank_arena(24, 18)
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(21, 15), "light_infantry", 1)
	MapHandoff.pending = map
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var neutral: UnitInstance = main.state.spawn_unit(StateCodec.load_stats("light_infantry"), Vector2i(10, 10), MCF.neutral_group_slot(1))
	main._refresh_neutral_camera()
	ck(not main._neutral_camera_row.visible, "sleeping neutrals have no camera buttons")
	neutral.civilian_active = true
	neutral.neutral_group = 1
	main._refresh_neutral_camera()
	ck(main._neutral_camera_row.visible and main._neutral_camera_buttons.get_child_count() == 1, "activated neutral group gets a separate camera row")
	ck(main._home_focus(neutral.owner) == neutral.coord, "neutral camera targets its active forces")
	# A separate viewer cannot use the camera to locate hidden activated groups.
	main.resolver.fog_mode = MCF.Fog.STANDARD
	main.networked = true
	main.my_owner = 0
	for y in 18: main.state.grid.cell(Vector2i(7, y)).set_feature(MCF.FEATURE_WALL)
	main._refresh_neutral_camera()
	ck(not main._neutral_camera_row.visible and main._neutral_camera_targets().is_empty(), "neutral camera cannot reveal groups behind fog")
	main.resolver.fog_mode = MCF.Fog.OFF
	main.networked = false
	neutral.kill()
	main._refresh_neutral_camera()
	ck(not main._neutral_camera_row.visible, "eliminated neutral group no longer has a camera target")
	var sounds := []
	var fx := FxDecals.new()
	fx.sound_requested.connect(func(id: String, _c: Vector2i, _owner: int) -> void: sounds.append(id))
	var result := ActionResult.success()
	var wall := Vector2i(8, 7)
	main.state.grid.cell(wall).set_feature(MCF.FEATURE_WALL)
	main.resolver._blast_destroy_terrain(wall, result, Vector2i(7, 7))
	var glass := Vector2i(9, 7)
	main.state.grid.cell(glass).set_feature(MCF.FEATURE_GLASS)
	main.resolver._blast_destroy_terrain(glass, result, Vector2i(7, 7))
	main.state.grid.cell(Vector2i(10, 7)).set_feature("streetlight")
	main.resolver._blast_destroy_terrain(Vector2i(10, 7), result, Vector2i(7, 7))
	fx.apply(result.fx)
	ck(sounds.has("structure") and sounds.count("glass") == 2, "blast-destroyed wall, window and light each request the material sound")
	var audio = load("res://src/audio/BattleAudio.gd").new()
	audio.cell_visible = func(_c: Vector2i) -> bool: return true
	audio.own_cell = func(_c: Vector2i) -> bool: return false
	root.add_child(audio)
	var game_audio := root.get_node("GameAudio")
	var old_levels := [game_audio.master, game_audio.sfx, game_audio.muted]
	game_audio.master = 1.0
	game_audio.sfx = 1.0
	game_audio.muted = false
	for y in 8:
		for x in 8: audio.cue("structure", Vector2i(x, y))
	audio.cue("glass", Vector2i(4, 4))
	audio.cue("explosion", Vector2i(4, 4))
	var active := []
	for entry: Dictionary in audio.voices: active.append(entry.id)
	ck(active.has("structure") and active.has("glass") and active.has("explosion") and audio.voices.size() <= audio.WORLD_CAP, "large blast retains wall, glass and explosion voices within the cap")
	game_audio.master = old_levels[0]
	game_audio.sfx = old_levels[1]
	game_audio.muted = old_levels[2]
	audio.free()
	main.free()
