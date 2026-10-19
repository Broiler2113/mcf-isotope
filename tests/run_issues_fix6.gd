extends SceneTree
## Issues-fix-6 (2026-10-19): firing lanes before the dice, one shot sound per bullet,
## crunching hulls, smoke you can shoot through, allies in the line, thrown grenades and
## walls, DPMG bursts, wave shields, landing beside fire, digging around bodies, the HI's
## smoke, the end-of-match fog toggle and wave cameras, and the decal undo fast path.

var fails := 0
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails += 1

func _initialize() -> void: run.call_deferred()

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func run() -> void:
	lane_preview()
	shot_sound_cues()
	smoke_and_allies()
	grenades_and_walls()
	dpmg_bursts()
	wave_shields_and_fire()
	digging_and_smoke_mark()
	decal_undo()
	await board_checks()
	print("issues-fix-6: %d failure(s)" % fails)
	quit(0 if fails == 0 else 1)

func _lane(from: Vector2i, to: Vector2i, weapon := "") -> Dictionary:
	var ev := {"fx": "lane", "from": [from.x, from.y], "to": [to.x, to.y], "owner": 0, "kind": "shot"}
	if weapon != "": ev["weapon"] = weapon
	return ev

func lane_preview() -> void:
	var fx := FxDecals.new()
	var events := [_lane(Vector2i(2, 2), Vector2i(8, 2))]
	fx.preview_lanes(events)
	ck(fx.lanes.size() == 1 and fx.lanes[0].get("hold", false), "the firing lane shows (held) before the dice")
	fx.apply_lanes(events)
	ck(fx.lanes.size() == 1 and not fx.lanes[0].has("hold"), "the shot takes over its previewed lane instead of drawing a second")

func shot_sound_cues() -> void:
	var fx := FxDecals.new()
	var cues: Array = []
	var volleys: Array = []
	fx.sound_requested.connect(func(id: String, _c: Vector2i, _o: int) -> void: cues.append(id))
	fx.volley_requested.connect(func(id: String, _c: Vector2i, _o: int, n: int) -> void: volleys.append([id, n]))
	fx.apply_lanes([_lane(Vector2i(2, 2), Vector2i(8, 2), "heavy_infantry"),
		{"fx": "tracer", "at": Vector2i(2, 2), "from": [2, 2], "to": [8, 2], "count": 2}])
	ck(cues == ["rifle"] and volleys == [["rifle", 1]], "two bullets of three: two shots heard, no more")
	cues.clear(); volleys.clear()
	fx.apply_lanes([_lane(Vector2i(2, 4), Vector2i(8, 4), "machinegunner"),
		{"fx": "tracer", "at": Vector2i(2, 4), "from": [2, 4], "to": [8, 4], "count": 4}])
	ck(cues == ["mg"] and volleys == [["mg", 3]], "a four-round burst is four machine-gun shots")
	cues.clear()
	fx.apply([{"fx": "chunks", "at": Vector2i(5, 5), "from": Vector2i(4, 5), "fid": MCF.FEATURE_WALL, "crushed": true}])
	ck(cues.has("crunch") and not cues.has("structure"), "a wall pushed over by a hull crunches")
	cues.clear()
	fx.apply([{"fx": "chunks", "at": Vector2i(5, 5), "from": Vector2i(4, 5), "fid": MCF.FEATURE_WALL}])
	ck(cues.has("structure"), "a wall blown down still crashes")

func smoke_and_allies() -> void:
	var map := arena()
	map.set_spawn(Vector2i(2, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(8, 4), "light_infantry", 1)
	map.set_spawn(Vector2i(2, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(5, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(8, 8), "light_infantry", 1)
	map.set_spawn(Vector2i(14, 12), "heavy_infantry", 0)
	map.set_spawn(Vector2i(15, 11), "sniper", 1)
	var r := resolver_for(map)
	var g := r.state.grid
	var shooter: UnitInstance = g.cell(Vector2i(2, 4)).occupant
	var target: UnitInstance = g.cell(Vector2i(8, 4)).occupant
	var base := r.hit_need_for(shooter, target)
	g.cell(Vector2i(5, 4)).smoke = true
	var mods: Array = []
	ck(r.can_shoot(shooter, target) == "", "a shot through smoke is allowed")
	ck(r.hit_need_for(shooter, target, mods) == base + GameActionResolver.SMOKE_HIT_PENALTY,
		"…at a large hit penalty (%d → %d)" % [base, r.hit_need_for(shooter, target)])
	g.cell(Vector2i(5, 4)).smoke = false
	var hi: UnitInstance = g.cell(Vector2i(14, 12)).occupant
	var sniper: UnitInstance = g.cell(Vector2i(15, 11)).occupant
	for c: Vector2i in [Vector2i(14, 12), Vector2i(15, 12), Vector2i(14, 11), Vector2i(13, 12)]:
		g.cell(c).smoke = true
	ck(r.can_shoot(hi, sniper) == "", "heavy infantry in its own smoke can shoot the sniper diagonal to it")
	for c: Vector2i in [Vector2i(14, 12), Vector2i(15, 12), Vector2i(14, 11), Vector2i(13, 12)]:
		g.cell(c).smoke = false
	var back: UnitInstance = g.cell(Vector2i(2, 8)).occupant
	var enemy: UnitInstance = g.cell(Vector2i(8, 8)).occupant
	ck(r.can_shoot(back, enemy) == "Another unit is in the way", "a soldier never shoots through an ally")

func grenades_and_walls() -> void:
	var map := arena()
	map.set_spawn(Vector2i(2, 12), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 2), "light_infantry", 1)
	map.set_cell(Vector2i(4, 12), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var r := resolver_for(map)
	var actor: UnitInstance = r.state.grid.cell(Vector2i(2, 12)).occupant
	actor.held_item_id = MCF.ITEM_FRAG
	var cells := r.grenade_target_cells(actor)
	ck(cells.has(Vector2i(3, 12)) and not cells.has(Vector2i(5, 12)), "no grenade target past a wall")
	var res := r.resolve(UseItemIntent.new(actor.id, Vector2i(5, 12)))
	ck(not res.ok and actor.held_item_id == MCF.ITEM_FRAG, "a throw through a wall is refused")

func dpmg_bursts() -> void:
	var map := arena()
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(10, 5), "heavy_infantry", 1)
	map.set_spawn(Vector2i(3, 12), "heavy_infantry", 1)
	var r := resolver_for(map)
	var st := r.state
	st.grid.cell(Vector2i(3, 5)).set_feature(MCF.FEATURE_DPMG, 0)
	var gunner: UnitInstance = st.grid.cell(Vector2i(2, 5)).occupant
	var guard := 0
	while st.active_player() != 0 and guard < 10:
		r.resolve(EndTurnIntent.new())
		guard += 1
	var east: UnitInstance = st.grid.cell(Vector2i(10, 5)).occupant
	var south: UnitInstance = st.grid.cell(Vector2i(3, 12)).occupant
	gunner.remaining_ap = 2
	st.dice.feed_scripted([1, 1, 1, 1, 1, 1, 1, 1])
	var res := r.resolve(DPMGFireIntent.new(gunner.id, Vector2i(3, 5), east.id, 3))
	ck(res.ok and gunner.remaining_ap == 1 and gunner.action_state != null
			and gunner.action_state.remaining_shots == MCF.DPMG_RATE_OF_FIRE - 3,
		"a DPMG fires the chosen number of rounds and keeps the rest of the burst")
	ck(st.grid.furniture_turn.get(Vector2i(3, 5), []) == [MCF.FEATURE_DPMG, 0], "the DPMG turns to the east target")
	st.dice.feed_scripted([1, 1, 1, 1, 1, 1, 1, 1])
	res = r.resolve(DPMGFireIntent.new(gunner.id, Vector2i(3, 5), south.id))
	ck(res.ok and gunner.remaining_ap == 1 and gunner.action_state == null,
		"the rest of the burst goes at another target without spending AP")
	ck(st.grid.furniture_turn.get(Vector2i(3, 5), []) == [MCF.FEATURE_DPMG, 2], "…and the gun turns south to it")

func wave_shields_and_fire() -> void:
	GameConfig.game_mode = MatchMode.Kind.HOLDOUT
	GameConfig.random_events_enabled = false
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	GameConfig.roster = ro
	var map := MapData.blank_arena(30, 20)
	map.set_spawn(Vector2i(14, 10), "heavy_infantry", 0)
	var r := GameActionResolver.new(map.build_state(11, ro))
	r.random_events = RandomEvents.new(false)
	r.prepare_mode(map)
	r.fog_enabled = false
	var sb := r.state.spawn_unit(load("res://src/data/units/shield_bearer.tres"), Vector2i(20, 15), r.mode.wave_side)
	r._blast(Vector2i(21, 15), ActionResult.success(), [], true, true)
	ck(r._is_wave_fighter(sb) and sb.is_alive(), "a wave's shield bearer survives a drone blast beside it")
	for y in range(0, 4):
		for x in range(4, 13):
			r.state.grid.cell(Vector2i(x, y)).on_fire = true
	r.mode.defender_value = 400
	r.mode.pending_wave = {"edge": 0, "along": 8}
	r._land_wave(ActionResult.success([]))
	var landed := 0
	var burning := 0
	for u: UnitInstance in r.state.all_units():
		if u.owner == r.mode.wave_side and u != sb and u.is_on_field():
			landed += 1
			if r.state.grid.cell(u.coord).on_fire: burning += 1
	ck(landed > 0 and burning == 0, "a wave lands beside the fire, never in it (%d landed)" % landed)
	var hall := r._hallway_spawn_cells(Vector2i(8, 6))
	ck(not hall.is_empty() and hall.all(func(c: Vector2i) -> bool: return not r.state.grid.cell(c).on_fire),
		"raider landing cells skip burning floor")
	for y in range(0, 4):
		for x in range(4, 13):
			r.state.grid.cell(Vector2i(x, y)).on_fire = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

func digging_and_smoke_mark() -> void:
	var map := arena()
	map.set_spawn(Vector2i(4, 4), "heavy_infantry", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	var r := resolver_for(map)
	var cell := r.state.grid.cell(Vector2i(6, 6))
	ck(cell.accepts_dirt(), "open floor takes spoil")
	cell.corpse_count = 1
	ck(not cell.accepts_dirt(), "no dirt pile on a body")
	cell.corpse_count = 0
	var hi: UnitInstance = r.state.grid.cell(Vector2i(4, 4)).occupant
	ck(not r.unit_missing_equipment(hi), "heavy infantry holding its smoke shows no mark")
	hi.held_item_id = ""
	ck(r.unit_missing_equipment(hi), "heavy infantry that threw its smoke gets the '!' mark")

## Undo cuts the decal lists back chunk by chunk (#4): the index stays exact and chunks the
## undone action never touched keep their bucket, so nothing downstream rebuilds them.
func decal_undo() -> void:
	var fx := FxDecals.new()
	for i in 400:
		fx._settle(fx.props if i % 2 else fx.gore,
			{"kind": "casing" if i % 2 else "blood_drop", "pos": Vector2(1.5 + (i % 40), 1.5 + (i / 40) * 3), "rot": 0.0, "scale": 1.0})
	var snap := fx.capture_state()
	var untouched: Array = fx.by_chunk[Vector2i(0, 0)]
	for i in 20:
		fx._settle(fx.props, {"kind": "shard", "pos": Vector2(30.5, 20.5), "rot": 0.0, "scale": 1.0})
	fx._sweep_props({"at": Vector2i(5, 1), "from": Vector2i(4, 1)})
	fx.restore_state(snap)
	var ref := FxDecals.new()
	ref.gore = fx.gore
	ref.props = fx.props
	ref._reindex()
	var exact := ref.by_chunk.size() == fx.by_chunk.size()
	for cc: Vector2i in ref.by_chunk:
		var a: Array = fx.by_chunk.get(cc, [])
		var b: Array = ref.by_chunk[cc]
		exact = exact and a.size() == b.size() and b.all(func(q: Dictionary) -> bool: return a.has(q))
	ck(exact, "after undo the decal index matches the restored lists")
	ck(is_same(fx.by_chunk[Vector2i(0, 0)], untouched), "an untouched chunk keeps its bucket through undo")

func board_checks() -> void:
	var map := arena()
	map.set_spawn(Vector2i(3, 4), "machinegunner", 0)
	map.set_spawn(Vector2i(8, 4), "heavy_infantry", 1)
	map.set_spawn(Vector2i(3, 9), "heavy_infantry", 1)
	MapHandoff.pending = map
	var board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	board.state.turns.round_order.assign([0, 1])
	board.state.turns.active_index = 0
	board._refresh_status()
	board._fx.audio_suppressed = false
	var heard := [0]
	board._fx.sound_requested.connect(func(id: String, _c: Vector2i, _o: int) -> void:
		if id == "mg": heard[0] += 1)
	board._fx.volley_requested.connect(func(id: String, _c: Vector2i, _o: int, n: int) -> void:
		if id == "mg": heard[0] += n)
	var mg: UnitInstance = board.state.grid.cell(Vector2i(3, 4)).occupant
	mg.remaining_ap = 3
	for target_cell: Vector2i in [Vector2i(8, 4), Vector2i(3, 9)]:
		heard[0] = 0
		board.state.dice.feed_scripted([1, 1, 1, 1, 1, 1, 1, 1])
		var target: UnitInstance = board.state.grid.cell(target_cell).occupant
		board._submit(ShootIntent.new(mg.id, target.id))
		for i in 600:
			await process_frame
			if board._dice._roll_btn.visible: board._dice._roll_btn.pressed.emit()   # the defender's Roll
			if i > 5 and not board._animating and not board._fx.lanes.any(func(l: Dictionary) -> bool: return l.has("hold")): break
		ck(heard[0] == 4, "a four-round burst at %s is heard as four shots (%d)" % [target_cell, heard[0]])
	board.queue_free()
	await process_frame

	# Holdout: the end-of-match fog toggle and the wave camera buttons.
	GameConfig.game_mode = MatchMode.Kind.HOLDOUT
	GameConfig.random_events_enabled = false
	var ro := Roster.new()
	ro.add_slot(Roster.SlotKind.HUMAN)
	ro.set_waves(1)
	GameConfig.roster = ro
	var hmap := MapData.blank_arena(30, 20)
	hmap.set_spawn(Vector2i(14, 10), "heavy_infantry", 0)
	for y in 20:
		hmap.set_cell(Vector2i(24, y), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	MapHandoff.pending = hmap
	board = load("res://scenes/Main.tscn").instantiate()
	root.add_child(board)
	await process_frame
	board.resolver.fog_enabled = true
	board.resolver.fog_mode = MCF.Fog.STANDARD
	var wave: UnitInstance = board.state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(15, 10), board.resolver.mode.wave_side)
	wave.neutral_group = 1
	var far_wave: UnitInstance = board.state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(29, 0), board.resolver.mode.wave_side)
	far_wave.neutral_group = 2
	var targets: Dictionary = board._force_camera_targets(true)
	ck(targets.has(1) and not targets.has(2), "a camera button for the visible wave only, under fog")
	ck(board._force_camera_targets(false).is_empty(), "waves are not listed with the raiders")
	board._match_over = true
	board._refresh_status()
	ck(board._reveal_btn.visible, "after the match the 'Show the whole board' toggle appears")
	board._reveal_btn.button_pressed = true
	ck(not board._view_resolver().visibility_limited(), "…and turns off the fog of war")
	board.queue_free()
	await process_frame
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
