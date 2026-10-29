extends "res://tests/SuiteBase.gd"

func run() -> void:
	_art()
	_meshes()
	await _view()
	await _loaded_settings()

## The shipped first-person art (tools/art/build_first_person.py, build_drone_meshes.py).
func _art() -> void:
	ck(FirstPersonArt.materials().get_layers() == FirstPersonArt.M_COUNT, "every material layer is shipped")
	for kind: String in FirstPersonArt.WALL_MATS + ["dot_open"]:
		ck(FirstPersonArt.picture("wall_" + kind).get_size() == Vector2i(128, FirstPersonArt.H), "4 m wall picture: " + kind)
	for art: String in ["wall_brick", "wall_station", "wood_wall", "bru", "sandbag_wall", "wall_asteroid"]:
		ck(FirstPersonArt.chunk_kind(art) in FirstPersonArt.WALL_MATS, "wall chunk wears its wall: " + art)
	ck(FirstPersonArt.chunk_kind("bed") == "", "furniture chunks keep their own material")
	var plain := FirstPersonArt.wall_texture("station", Color(0, 0, 0, 0)).get_image()
	var band := FirstPersonArt.wall_texture("station", Color.RED).get_image()
	var rows := {}
	for y in plain.get_height():
		for x in plain.get_width():
			if plain.get_pixel(x, y) != band.get_pixel(x, y): rows[y] = true
	ck(rows.has(FirstPersonArt.H - 38) and rows.keys().all(func(y: int) -> bool: return y >= FirstPersonArt.H - 41 and y <= FirstPersonArt.H - 35),
			"a department colour paints only its band at hand height")
	# Seen from the open side, each wall face continues its left neighbour's pattern.
	for d: Vector2i in Grid.N4:
		var right := Vector2i(d.y, -d.x)
		var a := FirstPersonModels.Sink.new()
		var b := FirstPersonModels.Sink.new()
		FirstPersonBoard._wall_face(a, Vector2i(5, 5), d, 0.0, 2.3)
		FirstPersonBoard._wall_face(b, Vector2i(5, 5) + right, d, 0.0, 2.3)
		var ua := Array(a.uv)
		var ub := Array(b.uv)
		ua.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
		ub.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
		ck(is_equal_approx(ua[ua.size() - 1].x, ub[0].x) and is_equal_approx(ua[ua.size() - 1].x - ua[0].x, 0.25),
				"wall texture runs on unbroken, a quarter of its 4 m width a cell, facing %s" % d)
	for scout: bool in [false, true]:
		var mesh: Mesh = DroneModel.mesh(scout)
		var stripes := 0
		for surface in mesh.get_surface_count():
			var mat := mesh.surface_get_material(surface) as StandardMaterial3D
			ck(mat != null and mat.albedo_texture != null, "drone surfaces carry the atlas")
			if mat != null and mat.resource_name == "TeamStripe": stripes += 1
		ck(stripes == 1, "drone top plates take the side's colour")
		var base := DroneModel._picture("scout_drone" if scout else "drone")
		var mask := DroneModel._picture(("scout_drone" if scout else "drone") + "_mask")
		var painted := (DroneModel.sprite(Color.RED, scout) as CanvasTexture).diffuse_texture.get_image()
		var changed := 0
		var stray := 0
		for y in base.get_height():
			for x in base.get_width():
				if base.get_pixel(x, y).is_equal_approx(painted.get_pixel(x, y)): continue
				if mask.get_pixel(x, y).r > 0.5: changed += 1
				else: stray += 1
		ck(changed > 20 and stray == 0, "only the drone's marked plates and arms are painted")

func _meshes() -> void:
	for reverse in [false, true]:
		var poly := PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])
		if reverse: poly.reverse()
		var sink := FirstPersonModels.Sink.new()
		sink.prism(poly, 0, 0.3, FirstPersonArt.M_CONCRETE, Color.WHITE)
		for i in range(0, sink.v.size(), 3):
			var center := (sink.v[i] + sink.v[i + 1] + sink.v[i + 2]) / 3.0
			if absf(sink.n[i].y) < 0.1:
				ck(Vector3(center.x, 0, center.z).dot(sink.n[i]) > 0.0, "rubble sides point outward in either polygon order")
			ck((sink.v[i + 1] - sink.v[i]).cross(sink.v[i + 2] - sink.v[i]).dot(sink.n[i]) < 0,
					"rubble winding agrees with Godot's front faces")
	var ldf := FirstPersonArt.picture("wall_ldf")
	ldf.generate_mipmaps()
	ck(FirstPersonArt.wall_texture("ldf", Color.GREEN).get_image().get_data() == ldf.get_data(),
			"LDF uses its first-person texture without a color band")
	for fid: String in [MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN]:
		var grid := Grid.new(3, 3)
		grid.cell(Vector2i(1, 1)).set_feature(fid)
		grid.wall_accent.resize(9)
		var tiles := TerrainTiles.new(grid, "station")
		var floor_img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		var plain := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		tiles._paint(floor_img, plain, Vector2i.ONE, Vector2i.ZERO, 32)
		grid.wall_accent[4] = 1
		var painted := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		tiles._paint(floor_img, painted, Vector2i.ONE, Vector2i.ZERO, 32)
		ck(plain.get_data() == painted.get_data(), "pillbox art ignores an inherited accent: " + fid)
		ck(FirstPersonArt.accent_of(grid, Vector2i.ONE).a == 0, "3D pillboxes also reject accents")

func _view() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(24, 20)
	map.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	map.set_spawn(Vector2i(21, 17), "light_infantry", 1)
	for x in range(8, 11):
		map.set_cell(Vector2i(x, 5), 0, 0, false, MCF.FEATURE_AIRLOCK if x == 9 else MCF.FEATURE_WALL)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 6: await process_frame
	main._enter_fp_pick()
	main._deselect()
	ck(main.mode == main.Mode.FP_PICK, "enemy action does not cancel first-person placement")
	main._animating = true
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = main._cell_screen(Vector2i(9, 10))
	main._unhandled_input(click)
	ck(main._fp != null, "first person opens while another action animates")
	main._animating = false
	if main._fp == null:
		main.free()
		return
	var fp = main._fp
	fp.set_process(false)
	var before := JSON.stringify(StateCodec.encode(main.state))
	# Door opening survives a rebuilt chunk; leaves retract beyond the shared wall face.
	var start: Vector3 = fp.pos
	fp.pos = Vector3(9.5, 0, 6.2)
	fp._doors(1.0)
	var cc := Vector2i(1, 0)
	var door: Node3D = fp._chunks[cc]["doors"][Vector2i(9, 5)]
	var open_at: Transform3D = (door.get_child(0) as Node3D).transform
	if door.has_meta("swing"):
		# A town or field door turns on its hinge, square to the wall, away from you (issues-14 #3).
		ck(absf(absf(open_at.basis.get_euler().y) - PI / 2) < 0.01, "an open door stands square to its wall")
		var tip := door.to_global((door.get_child(0) as Node3D).transform * Vector3(0.98, 1, 0))
		ck(tip.z < 5.0, "the door swung away from the walker at z 6.2")
	else:
		ck(open_at.origin.x < 0, "open door retracts completely into its wall")
	fp._build_chunk(cc)
	fp._doors(0.016)
	ck((fp._chunks[cc]["doors"][Vector2i(9, 5)].get_child(0) as Node3D).transform.is_equal_approx(open_at),
			"rebuilding a chunk keeps the existing door opening")
	fp.pos = start
	_movement(fp)
	# All projectile families reach a visible 3D mesh; laser is transient.
	main._fx.apply([{"fx": "laser", "from": [8, 8], "to": [12, 8]},
			{"fx": "tracer", "from": [8, 8], "to": [12, 8]},
			{"fx": "shot", "kind": "rocket", "from": [8, 8], "to": [12, 8]},
			{"fx": "shot", "kind": "shell", "from": [8, 8], "to": [12, 8]}])
	main._fx.advance(0.04)
	fp._sync_combat_fx()
	ck(fp._fx_mm.multimesh.visible_instance_count >= 5, "bullets, rockets, shells and laser produce visible geometry")
	ck(main._fx.beams.size() == 1, "a laser has one live beam")
	main._fx.advance(0.3)
	ck(main._fx.beams.is_empty(), "the beam expires, independently of its floor scorch")
	main._fx.flashes.append({"cells": [Vector2i(10, 9)], "t": 0.04})
	fp._sync_combat_fx()
	ck(fp._blast_mm.multimesh.visible_instance_count == 5, "an explosion has a hot core and four expanding lobes")
	main._fx.advance(2.0)
	fp._sync_combat_fx()
	ck(fp._blast_mm.multimesh.visible_instance_count == 0, "explosion geometry retires when its flash ends")
	# Network identity comes from the transport, not any claimed side in the payload.
	main.session = NetworkSession.new()
	main.session._is_host = true
	main.state.roster.slot(1).peer_id = 42
	main._receive_fp_presence({"_from": 42, "active": true, "side": 0, "p": [10.5, 0.0, 10.5, 0.0]})
	ck(main._fp_walkers[42]["side"] == 1, "remote walker ownership is authenticated")
	fp._sync_walkers(0.1)
	ck(fp._walkers.has(42), "another player's first-person avatar appears")
	main._receive_fp_presence({"_from": 42, "active": true, "p": [NAN, 0.0, 10.5, 0.0]})
	ck(main._fp_walkers[42]["pos"] == Vector3(10.5, 0, 10.5), "non-finite positions are rejected")
	fp._vis_img.fill(Color.BLACK)
	fp._sync_walkers(0.1)
	ck(fp._walkers.is_empty(), "walkers never reveal an unseen cell")
	fp._vis_img.fill(Color.WHITE)
	main._receive_fp_presence({"_from": 42, "active": false})
	fp._sync_walkers(0.1)
	ck(main._fp_walkers.is_empty(), "leaving first person removes presence")
	main.session.free()
	main.session = null
	# Rulers can be hidden without deleting marks or hiding ordinary drawing strokes.
	main._place_ruler(Vector2i(4, 4), Vector2i(8, 4))
	main._hide_rulers = true
	ck(main._rulers.size() == 1 and not main._hide_all_draw, "ruler visibility is independent and retains the measure")
	# The cosmetic presence tests changed only the roster's transport selector.
	main.state.roster.slot(1).peer_id = -1
	ck(JSON.stringify(StateCodec.encode(main.state)) == before, "walking and combat visuals do not alter simulation")
	main._end_first_person()
	main.queue_free()
	await process_frame

func _movement(fp) -> void:
	var origin := Vector3(9.5, 0, 14.5)
	fp.yaw = 0
	for running in [false, true]:
		fp.pos = origin
		fp._walked = 0.0
		for i in 50: fp._walk(0.02, Vector3.FORWARD, running)
		var distance: float = fp.pos.distance_to(origin)
		ck(absf(distance - (fp.RUN_SPEED if running else fp.SPEED)) < 0.01, "walking/running covers the advertised distance")
	fp.pos = origin
	fp._walked = 0.0
	for i in 50: fp._walk(0.02, Vector3(1, 0, -1), false)
	ck(absf(fp.pos.distance_to(origin) - fp.SPEED) < 0.01 and absf(fp._walked - 0.4) < 0.01,
			"diagonal walking keeps both speed and footstep spacing")
	fp.pos = origin

func _loaded_settings() -> void:
	var lobby: Node = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	var rules := {"mode": {"kind": MatchMode.Kind.HOLDOUT, "wave": 4, "wave_spawned": 200,
			"next_wave_round": 12, "waves_total": 20, "wave_every": 3, "wave_start": 0.8, "wave_growth": 0.25,
			"excluded_units": ["sniper"], "pending_wave": {"target": 42, "multiplier": 1.4}}, "events": {"enabled": true, "armies": 3, "turns_since": 2,
			"pending": [{"id": "army", "land": 9}], "excluded_units": ["miner"]}}
	lobby._save = {"rules": rules}
	lobby._load_spawn_settings(rules)
	ck(lobby._waves_spin.value == 20 and lobby._wave_every_spin.value == 3, "resuming shows saved wave controls")
	ck(is_equal_approx(lobby._wave_start_spin.value, 0.8) and is_equal_approx(lobby._wave_growth_spin.value, 0.25) and lobby._wave_growth_spin.editable,
			"resuming exposes saved multiplier and growth (%s, %s, editable %s)" % [lobby._wave_start_spin.value, lobby._wave_growth_spin.value, lobby._wave_growth_spin.editable])
	GameConfig.holdout_waves = 30
	GameConfig.holdout_wave_every = 5
	GameConfig.holdout_wave_start = 1.2
	GameConfig.holdout_wave_growth = 0.3
	GameConfig.holdout_excluded_units.assign(["miner"])
	GameConfig.raider_excluded_units.assign(["sniper"])
	lobby._store_spawn_settings()
	var written: Dictionary = lobby._save["rules"]
	ck(written["mode"]["waves_total"] == 30 and written["mode"]["wave_every"] == 5, "new wave settings apply to resumed games")
	ck(written["mode"]["wave_start"] == 1.2 and written["mode"]["wave_growth"] == 0.3, "edited multiplier and growth apply to resumed games")
	ck(written["mode"]["pending_wave"] == rules["mode"]["pending_wave"], "editing future growth preserves the already-announced wave")
	ck(written["mode"]["wave"] == 4 and written["mode"]["wave_spawned"] == 200 and written["mode"]["next_wave_round"] == 12,
			"changing future waves preserves saved progress and announced timing")
	ck(written["events"]["armies"] == 3 and written["events"]["pending"].size() == 1, "raider changes retain queued events")
	lobby.queue_free()
	await process_frame
