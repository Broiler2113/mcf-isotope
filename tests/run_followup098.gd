extends SceneTree

var failures: Array[String] = []
func ck(ok: bool, message: String) -> void:
	if not ok: failures.append(message); printerr("FAIL: " + message)
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	_gas_walk()
	_gas_visibility()
	_warning()
	_barrages()
	_roads()
	await _editor()
	print("Follow-up regressions: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _arena() -> GameState:
	var m := MapData.blank_arena(16, 12)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(12, 5), "light_infantry", 1)
	var s := m.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	return s

func _gas_walk() -> void:
	for roll in [1, 6]:
		for target in [Vector2i(4, 5), Vector2i(6, 5)]:
			var s := _arena()
			var r := GameActionResolver.new(s)
			r.random_events = RandomEvents.new(false)
			r.random_events.add_cloud(4, 1, 2, 10, 3)
			r._sync_gas()
			var u := s.grid.cell(Vector2i(2, 5)).occupant
			u.remaining_ap = 3
			s.dice.feed_scripted([roll])
			var res := r.resolve(MoveIntent.new(u.id, target))
			ck(res.ok, "movement into or through gas succeeds as an action")
			ck(s.dice.scripted_remaining() == 0 and s.dice.fallback_rolls == 0, "one roll at first gas tile, not every tile")
			ck(u.is_alive() == (roll == 6), "gas survival follows the contact roll")
			ck(u.coord == (target if roll == 6 else Vector2i(4, 5)), "failed contact stops at first gas tile")
			var checks := res.dice_events.filter(func(e: Dictionary) -> bool: return e.get("kind") == "check")
			ck(checks.size() == 1, "contact check reaches the battle/replay animation")
			if roll == 1: ck(res.deaths.has(u.id), "death is reported for delayed animation")
	var pushed_state := _arena()
	var pushed_resolver := GameActionResolver.new(pushed_state)
	var pushed := pushed_state.grid.cell(Vector2i(2, 5)).occupant
	pushed_resolver.random_events.add_cloud(3, 5, 1, 1, 3)
	pushed_resolver._sync_gas()
	pushed_state.dice.feed_scripted([1])
	var pushed_result := ActionResult.success([])
	pushed_resolver._slide(pushed, Vector2i(5, 5), pushed_result)
	ck(not pushed.is_alive() and pushed.coord == Vector2i(3, 5), "forced movement stops on first lethal gas tile")
	var s := _arena()
	var r := GameActionResolver.new(s)
	var u := s.grid.cell(Vector2i(2, 5)).occupant
	s.dice.feed_scripted([6])
	var res := ActionResult.success([])
	r._land_gas({"x": 2, "y": 5, "w": 1, "h": 1}, res)
	ck(u.is_alive() and s.dice.scripted_remaining() == 0, "gas appearing on a stationary soldier checks immediately")

	var borg_state := _arena()
	var borg_resolver := GameActionResolver.new(borg_state)
	var pilot := borg_state.grid.cell(Vector2i(2, 5)).occupant
	var borg := borg_state.spawn_vehicle("borg", Vector2i(3, 5), 0)
	ck(borg_resolver.resolve(VehicleBoardIntent.new(pilot.id, borg.id)).ok, "gas fixture boards a borg")
	borg_resolver.random_events.add_cloud(4, 5, 1, 1, 3)
	borg_resolver._sync_gas()
	borg_state.dice.feed_scripted([1])
	var exit_result := borg_resolver.resolve(VehicleDisembarkIntent.new(pilot.id, Vector2i(4, 5)))
	ck(exit_result.ok and not pilot.is_alive(), "leaving a sealed borg into gas checks exposure")

func _gas_visibility() -> void:
	var s := _arena()
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	var own := s.grid.cell(Vector2i(2, 5)).occupant
	var enemy := s.grid.cell(Vector2i(12, 5)).occupant
	s.grid.cell(Vector2i(8, 5)).set_feature(MCF.FEATURE_WALL)
	ck(r.is_visible_to_team(0, enemy), "fog off ignores ordinary walls")
	r.random_events.add_cloud(5, 1, 2, 10, 3)
	r._sync_gas()
	ck(not r.is_visible_to_team(0, enemy), "gas blocks distant enemies with fog off")
	var obs := preload("res://rl/ObsEncoder.gd").encode(r, 0, 20)
	ck(not obs["units"].any(func(u: Dictionary) -> bool: return int(u["own"]) == 1), "RLM observation cannot see enemy soldiers through gas")
	ck(r.team_sees(0, Vector2i(2, 10)), "gas mode retains unlimited range elsewhere")
	r.random_events.clouds.clear()
	r.random_events.add_cloud(2, 5, 1, 1, 3)
	r._sync_gas()
	ck(r.is_visible_to_team(0, own), "own soldier remains visible inside gas")
	ck(not r.is_visible_to_team(1, own), "enemy soldier inside gas is concealed")
	r.random_events.clouds.clear()
	r._sync_gas()
	ck(r.is_visible_to_team(0, enemy), "dissipating gas restores fog-off visibility through walls")

func _warning() -> void:
	var s := _arena()
	var r := GameActionResolver.new(s)
	r.random_events = RandomEvents.new(false)
	r.random_events.announce(RandomEvents.GAS, {"x": 2, "y": 5, "w": 1, "h": 1}, 1)
	var saved := r.random_events.snapshot()
	r.random_events.restore(saved)
	s.dice.feed_scripted([6])
	var round_before := s.turns.round_number
	var result := r.resolve(EndTurnIntent.new(-1))
	ck(s.turns.round_number == round_before, "fixture ends first player's turn, not the round")
	ck(r.random_events.pending.is_empty() and r.random_events.clouds.size() == 1, "warning lands on next end-turn even mid-round and after restore")
	ck(result.dice_events.any(func(e: Dictionary) -> bool: return e.get("kind") == "check"), "event check survives end-turn result merging")
	ck(int(r.random_events.clouds[0]["left"]) == 3, "new gas keeps full lifetime")

func _barrages() -> void:
	var r := GameActionResolver.new(_arena())
	var p := {"x": 3, "y": 3, "w": 4, "h": 4}
	r.random_events.announce(RandomEvents.MORTAR, p, 1)
	var next := r._free_barrage_zone(p, Rect2i(0, 0, 16, 12))
	ck(not next.is_empty(), "another barrage finds room")
	ck(not Rect2i(3, 3, 4, 4).intersects(Rect2i(next["x"], next["y"], next["w"], next["h"])), "barrage warning rectangles never overlap")
	ck(r._free_barrage_zone(p, Rect2i(3, 3, 4, 4)).is_empty(), "full area skips barrage rather than hiding a warning")

func _roads() -> void:
	for flammable in [true, false]:
		var g := MapGen.build({"style": MapGen.Style.TOWN, "size": 0, "seed": 97, "flammable": flammable, "units": 16, "civilians": 0})
		var core: Rect2i = g._core
		var count := 0
		for x in range(core.position.x, core.end.x):
			if g._street[core.position.y * g.w + x] == 0: continue
			count += 1
			for y in range(core.position.y - MapGen.BORDER, core.position.y):
				ck(g.m.get_floor(Vector2i(x, y)) == MCF.FLOOR_NORMAL and g.m.get_look(y * g.w + x) == 0, "north road continues across all ten border cells")
		ck(count > 0, "town fixture has roads")

func _editor() -> void:
	var e: Variant = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(e)
	e.create_map("", "town", Vector2i(20, 20))
	e._select_brush("decal:blood_pool")
	e._press(Vector2i(4, 4), false, e.pan + Vector2(4.13, 4.78) * e.cell_size())
	e._paint_decal(Vector2(4.38, 4.78))
	e._release(Vector2i(4, 4))
	ck(e.map.decals.size() == 2, "blood painting moves within one cell")
	ck(is_equal_approx(float(e.map.decals[0][1]), 4.13), "blood preserves exact cursor position")
	e.undo()
	ck(e.map.decals.is_empty(), "one undo removes entire decal stroke")
	e.redo()
	e.rotate_key()
	e._press(Vector2i(5, 5), false, e.pan + Vector2(5.13, 5.78) * e.cell_size())
	e._release(Vector2i(5, 5))
	ck(is_equal_approx(float(e.map.decals.back()[3]), PI / 2), "R rotates decal placement")
	e._select_brush("decal:corpse")
	e._press(Vector2i(6, 6), false, e.pan + Vector2(6.13, 6.78) * e.cell_size())
	e._release(Vector2i(6, 6))
	ck(Vector2(e.map.decals.back()[1], e.map.decals.back()[2]) == Vector2(6.5, 6.5), "corpse snaps to cell center")
	e._select_brush("decal:blood_drop")
	e._press(Vector2i(7, 7), false, e.pan + Vector2(7.2, 7.2) * e.cell_size())
	var count: int = e.map.decals.size()
	var motion := InputEventMouseMotion.new()
	motion.position = e.pan + Vector2(7.8, 7.8) * e.cell_size()
	motion.button_mask = 0
	e._unhandled_input(motion)
	ck(e.map.decals.size() == count and not e._decal_painting, "releasing over the UI cannot leave decal painting stuck on")
	e._select_brush(MCF.FEATURE_WALL)
	ck(e._accent_opt.visible and not e._door_opt.visible, "wall shows only accent options")
	e.brush_accent = 3
	ck(e._brushed([0, 0, false, "", -1], 0)[7] == 3, "wall painting uses chosen accent")
	e._select_brush(MCF.FEATURE_AIRLOCK)
	ck(not e._accent_opt.visible and e._door_opt.visible, "door shows only texture options")
	e.brush_door = 8
	ck(e._brushed([0, 0, false, "", -1], 0)[8] == 8, "door painting uses selected texture")
	ck(e._door_thumb(7).region != e._door_thumb(8).region, "door preview displays selected sprite variant")
	e._select_tool(e.Tool.SELECT)
	ck(not e._accent_opt.visible and not e._door_opt.visible, "selection tool hides irrelevant material options")
	e._select_brush("floor")
	ck(not e._accent_opt.visible and not e._door_opt.visible, "other brushes hide wall and door options")
	e.queue_free()
	await process_frame
