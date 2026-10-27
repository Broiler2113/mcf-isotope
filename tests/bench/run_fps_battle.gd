extends "res://tests/SuiteBase.gd"

## Windowed FPS benchmark: the same large AI-vs-AI battle, first with C++ acceleration,
## then with the original GDScript, with a live FPS readout and a final comparison.
##   godot --path . --script res://tests/bench/run_fps_battle.gd -- [--scene giant] [--actions 800] [--reps 2] [--hold 30]
## Scenes are run_bench.gd's (large, giant, ...). A fixed dice seed makes every run
## play the same moves, so the rows compare equal work. Runs alternate order and each
## mode keeps its fastest, so first-run warm-up is not billed to either. Needs a window.
const Bench := preload("res://tests/bench/run_bench.gd")

var _label: Label

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_name := _arg(args, "--scene", "giant")
	var actions := int(_arg(args, "--actions", "800"))
	var hold := float(_arg(args, "--hold", "30"))
	var reps := maxi(1, int(_arg(args, "--reps", "2")))
	if DisplayServer.get_name() == "headless":
		ck(false, "FPS needs a window: run without --headless")
		return
	if not Bench.SCENES.has(scene_name):
		ck(false, "unknown scene %s; choose one of %s" % [scene_name, Bench.SCENES.keys()])
		return
	if NativeKernels.ai() == null:
		ck(false, "C++ acceleration is not loaded on this system: %s" % NativeAcceleration.status().title)
		return
	var cfg: Dictionary = Bench.SCENES[scene_name]
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 40
	GameConfig.random_events_enabled = false
	GameConfig.cheats_enabled = false
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	# Uncapped, so a fast machine cannot hide the difference behind the monitor's refresh rate.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	GameConfig.ai_speed = 64.0  # "Max": one AI step per frame, so compute shows in the frame rate
	var hud := CanvasLayer.new()
	hud.layer = 128
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.04, 0.04, 0.05, 0.85)
	box.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", box)
	_label = Label.new()
	var mono := SystemFont.new()
	mono.font_names = ["Menlo", "Consolas", "DejaVu Sans Mono", "monospace"]
	_label.add_theme_font_override("font", mono)
	_label.add_theme_font_size_override("font_size", 22)
	panel.add_child(_label)
	hud.add_child(panel)
	root.add_child(hud)
	var best := {}
	var digests := {}
	for rep in reps:
		for native: bool in ([true, false] if rep % 2 == 0 else [false, true]):
			var row := await _battle(native, scene_name, cfg, actions)
			digests[[row.actions, row.digest]] = true
			if not best.has(native) or row.seconds < best[native].seconds: best[native] = row
	var rows: Array[Dictionary] = [best[true], best[false]]
	ck(digests.size() == 1, "every run played the same battle")
	print(_table(scene_name, rows))
	_label.text = _table(scene_name, rows) + "\n\nClosing in %d s." % hold
	await create_timer(hold).timeout

func _battle(native: bool, scene_name: String, cfg: Dictionary, actions: int) -> Dictionary:
	NativeKernels.enabled = native
	NativeVisuals.enabled = native
	var mode := "C++" if native else "GDScript"
	_label.text = "%s: preparing %s battle..." % [mode, scene_name]
	await process_frame
	GameConfig.roster = Roster.default_duel(true, int(cfg.get("style", 0)))
	GameConfig.roster.slot(0).kind = Roster.SlotKind.AI
	MapHandoff.pending = Bench.build_map(cfg)
	MapHandoff.dice_seed = int(cfg.seed) * 7919
	var t0 := Time.get_ticks_usec()
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 5: await process_frame
	var load_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var view: Vector2 = main.get_viewport_rect().size
	main.zoom = clampf(minf(view.x / (cfg.w * main.CELL), view.y / (cfg.h * main.CELL)), main.ZOOM_MIN, 1.0)
	main._center_on_cell(Vector2i(cfg.w / 2, cfg.h / 2), true)
	main._paused = false
	main._kick_if_ai()
	var frames := PackedFloat64Array()
	var start := Time.get_ticks_usec()
	var last := start
	var done: int = 0
	var hitch := 0.0
	while done < actions and not main._match_over and last - start < 900_000_000:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		# Godot reports the slowest game-logic step of the last second here, not this frame's.
		hitch += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		last = now
		done = main.recorder.steps.size()
		if frames.size() % 10 == 0:
			_label.text = "%s   %d FPS   action %d / %d   %.1f s" % [mode, Engine.get_frames_per_second(), done, actions, (now - start) / 1e6]
	var seconds := (last - start) / 1e6
	var sorted := frames.duplicate()
	sorted.sort()
	var row := {"mode": mode, "actions": done, "digest": main.state.digest_hash(), "seconds": seconds,
		"fps": frames.size() / maxf(seconds, 0.001), "low": 1000.0 / maxf(sorted[int(0.99 * (sorted.size() - 1))], 0.001),
		"worst": sorted[-1], "load": load_ms, "hitch": hitch / maxf(frames.size(), 1)}
	main.queue_free()
	for i in 3: await process_frame
	return row

func _table(scene_name: String, rows: Array[Dictionary]) -> String:
	var lines := ["Same %s AI battle, %d actions" % [scene_name, rows[0].actions],
		"%-9s %9s %9s %10s %12s %10s %10s" % ["", "avg FPS", "1% low", "worst ms", "hitch ms", "battle time", "load ms"]]
	for r: Dictionary in rows:
		lines.append("%-9s %9.1f %9.1f %10.1f %12.1f %9.1fs %10.0f" % [r.mode, r.fps, r.low, r.worst, r.hitch, r.seconds, r.load])
	if rows.size() == 2:
		lines.append("C++: battle time %+.0f%%, avg FPS %+.0f%%, worst frame %+.0f%%, hitches %+.0f%%." % [
			100.0 * (rows[0].seconds / rows[1].seconds - 1.0), 100.0 * (rows[0].fps / rows[1].fps - 1.0),
			100.0 * (rows[0].worst / rows[1].worst - 1.0), 100.0 * (rows[0].hitch / rows[1].hitch - 1.0)])
		lines.append("hitch ms = slowest game-logic step in each second (AI, sight, paths), averaged; rendering excluded.")
	return "\n".join(lines)

func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
