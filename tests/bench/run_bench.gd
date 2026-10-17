extends SceneTree

## Производительность и неизменность поведения (perf pass, §27): воспроизводимый стенд.
##
## Сцены разного масштаба — small / medium / large и giant — на сгенерированных картах с
## фиксированным зерном, HARD против HARD, с мирными и туманом. Хост ведёт партию через
## NetGame, гость принимает её так же, как по сети (броски — подстановкой, подпись доски —
## на каждом действии), а в конце партия проходит сохранение/загрузку и проигрывается как
## повтор с самого начала.
##
## Поведение сверяется хешами, а не глазами: итоговая доска, упорядоченный след действий,
## живые по сторонам, косметика и число пересинхронизаций гостя. Хеши лежат в
## tests/bench/expected.txt; любое расхождение — провал (exit 1). `-- --update` пишет их
## заново, и делать это можно ТОЛЬКО при осознанном изменении правил. Пишутся строки лишь
## тех сцен, что прогнаны: run_all.sh гоняет small и medium, так что после правки правил
## large пересобирается отдельно (`-- large --update`).
##
## Время печатается отдельно и ни с чем не сравнивается: оно зависит от машины. Каждая
## сцена гоняется `-- --reps N` раз (по умолчанию 2), в таблицу идёт лучший прогон.
##
##   godot --headless --script res://tests/bench/run_bench.gd -- [small|medium|large|all] [--reps N] [--update]
##   godot --headless --script res://tests/bench/run_bench.gd -- modern --timings /tmp/modern.json
##   godot --headless --script res://tests/bench/run_bench.gd -- event_matrix
##   python3 tests/bench/compare_timings.py baseline.json current.json
##   godot --headless --script res://tests/bench/run_bench.gd -- render
## Режим render: экран боя на большой карте, вся карта в кадре, весь отряд стороны A
## выделен группой; меряются _process и _draw экрана на 240 кадрах.

const EXPECTED := "res://tests/bench/expected.txt"
const TS = preload("res://tests/TestSupport.gd")
const ROSTER := ["light_infantry", "heavy_infantry", "machinegunner", "sniper",
		"marksman", "anti_tank", "flamethrower", "engineer", "miner", "shield_bearer",
		"commander", "drone_operator", "sapper"]
const SCENES := {
	"small": {"w": 38, "h": 28, "units": 12, "tanks": 0, "rounds": 6, "seed": 4101},
	"medium": {"w": 56, "h": 40, "units": 50, "tanks": 1, "rounds": 3, "seed": 4202},
	"large": {"w": 80, "h": 60, "units": 150, "tanks": 2, "rounds": 2, "seed": 4303},
	"giant": {"w": 120, "h": 96, "units": 200, "tanks": 2, "rounds": 2, "seed": 4404, "furniture": 2, "style": AIPersonality.TACTICIAN, "mode": 0, "modern": true},
	"giant_capture": {"w": 120, "h": 96, "units": 200, "tanks": 2, "rounds": 2, "seed": 4505, "furniture": 2, "style": AIPersonality.TACTICIAN, "mode": 1, "modern": true},
	"giant_holdout": {"w": 120, "h": 96, "units": 200, "tanks": 2, "rounds": 2, "seed": 4606, "furniture": 2, "style": AIPersonality.TACTICIAN, "mode": 2, "modern": true},
}

var _pending: Intent = null
var _fails: PackedStringArray = []

var _render := {}
var _fog_delay_ms := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if "render" in args:
		_start_render()
		return
	var delay_arg := args.find("--inject-fog-delay-ms")
	if delay_arg >= 0 and delay_arg + 1 < args.size(): _fog_delay_ms = maxi(0, int(args[delay_arg + 1]))
	var update := "--update" in args
	var reps := 2
	var i := args.find("--reps")
	if i >= 0 and i + 1 < args.size():
		reps = maxi(1, int(args[i + 1]))
	var which: Array = []
	for a in args:
		if SCENES.has(a):
			which.append(a)
	if which.is_empty(): which = ["small", "medium", "large"]
	if "all" in args: which = SCENES.keys()
	if "modern" in args: which = ["giant", "giant_capture", "giant_holdout"]
	if "event_matrix" in args:
		for entry in RandomEvents.REGISTRY:
			var only := args.find("--event")
			if only >= 0 and args[only + 1] != entry[0]: continue
			var cfg: Dictionary = SCENES.giant_capture.duplicate(true)
			cfg["events"] = {entry[0]: 1}
			cfg["weak_side"] = entry[0] == RandomEvents.REINFORCE
			cfg["turns_only"] = true
			cfg["rounds"] = 1
			var result := _run_scene("event_" + entry[0], cfg)
			print("event %s: %s; host %.1f ms, fog %.1f ms, lighting %.1f ms" % [entry[0], result.sig, result.t_host, result.t_fog, result.t_lighting])
		for failure in _fails: printerr(failure)
		quit(0 if _fails.is_empty() else 1)
		return
	var report := {"machine": {"os": OS.get_name(), "cpu": OS.get_processor_name(),
			"threads": OS.get_processor_count(), "godot": Engine.get_version_info().string,
			"renderer": DisplayServer.get_name()}, "scenes": {}}
	var expected := _read_expected()
	var lines: PackedStringArray = []
	print("scene   actions   total ms   AI ms   host ms   guest ms   digest ms   fog ms   fx ms   save+load ms   replay ms")
	for name: String in which:
		var best: Dictionary = {}
		var runs: Array = []
		for _r in reps:
			print("bench: %s run %d/%d" % [name, _r + 1, reps])
			var res := _run_scene(name, SCENES[name])
			if not runs.is_empty() and res.sig != runs[0].sig:
				_fails.append("%s: repeated runs differ" % name)
			runs.append(res)
			if best.is_empty() or float(res["t_total"]) < float(best["t_total"]):
				best = res
		print("%-7s %7d %10.0f %7.0f %9.0f %10.0f %11.0f %8.0f %7.0f %14.0f %11.0f" % [name,
				best["actions"], best["t_total"], best["t_ai"], best["t_host"], best["t_guest"],
				best["t_digest"], best["t_fog"], best["t_fx"], best["t_save"], best["t_replay"]])
		report.scenes[name] = {"config": SCENES[name], "runs": runs}
		print("  presentation: memory %.1f ms, lighting CPU %.1f ms; rules=%s" % [best.t_memory, best.t_lighting, best.get("rules_hash", "legacy")])
		var sig: String = best["sig"]
		lines.append("%s %s" % [name, sig])
		if not update:
			if not expected.has(name):
				_fails.append("%s: no expected line (run with --update once)" % name)
			elif expected[name] != sig:
				_fails.append("%s: behaviour changed\n    expected %s\n    got      %s" % [name, expected[name], sig])
	var report_arg := args.find("--timings")
	if report_arg >= 0 and report_arg + 1 < args.size():
		var output := FileAccess.open(args[report_arg + 1], FileAccess.WRITE)
		if output == null: _fails.append("Could not write timing report")
		else: output.store_string(JSON.stringify(report, "  "))
	if update and _fails.is_empty():
		var f := FileAccess.open(EXPECTED, FileAccess.WRITE)
		f.store_line("# Nongating timing baseline: tests/bench/baseline-current.json; see audit-current.txt")
		for name in SCENES:
			var line := ""
			for l in lines:
				if l.begins_with(name + " "):
					line = l
			if line == "" and expected.has(name):
				line = "%s %s" % [name, expected[name]]
			if line != "":
				f.store_line(line)
		f.close()
		print("bench: expected hashes written")
		quit(0)
		return
	if _fails.is_empty():
		print("bench: behaviour identical to expected for %s" % ", ".join(which))
		quit(0)
	else:
		for f in _fails:
			printerr("FAIL " + f)
		quit(1)

func _read_expected() -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(EXPECTED):
		return out
	for line in FileAccess.get_file_as_string(EXPECTED).split("\n", false):
		if line.begins_with("#"): continue
		var sp := line.find(" ")
		if sp > 0:
			out[line.substr(0, sp)] = line.substr(sp + 1).strip_edges()
	return out

# --- Сцена ---

static func build_map(cfg: Dictionary) -> MapData:
	var m := MapGen.generate({"style": 1, "size": MapGen.SIZE_CUSTOM, "width": cfg["w"],
			"height": cfg["h"], "seed": cfg["seed"], "zones": 2, "units": cfg["units"],
			"civilians": 2, "density": 1, "space": false, "flammable": true,
			"furniture": cfg.get("furniture", 0)})
	var taken := {}
	for s: Dictionary in m.spawns:
		taken[s["coord"]] = true
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var cells: Array = m.zone_cells(side)
		var free := func(c: Vector2i) -> bool:
			return m.in_bounds(c) and m.get_zone(c) == side and not m.get_space(c) \
					and m.get_feature(c) == "" and m.get_cover(c) == 0.0 and not taken.has(c)
		var tanks := 0
		for c: Vector2i in cells:
			if tanks >= int(cfg["tanks"]):
				break
			var ok := true
			for dy in 3:
				for dx in 3:
					ok = ok and free.call(c + Vector2i(dx, dy))
			if ok:
				m.set_spawn(c, "tank", side, Vector2i(1, 0) if side == 0 else Vector2i(-1, 0))
				for dy in 3:
					for dx in 3:
						taken[c + Vector2i(dx, dy)] = true
				tanks += 1
		var placed := 0
		for c: Vector2i in cells:
			if placed >= int(cfg["units"]):
				break
			if free.call(c):
				m.set_spawn(c, "light_infantry" if cfg.get("weak_side", false) and side == 1 else ROSTER[placed % ROSTER.size()], side)
				taken[c] = true
				placed += 1
	return m

func _on_intent(it: Intent) -> void:
	_pending = it

func _run_scene(name: String, cfg: Dictionary) -> Dictionary:
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 40
	var modern := bool(cfg.get("modern", false))
	GameConfig.random_events_enabled = modern
	GameConfig.random_events_mandatory = modern
	GameConfig.random_events_interval = 1
	GameConfig.random_events_weights = cfg.get("events", RandomEvents.default_weights())
	GameConfig.game_mode = int(cfg.get("mode", 0))
	GameConfig.capture_drawn = []
	GameConfig.roster = Roster.default_duel(false)
	if GameConfig.game_mode == MatchMode.Kind.HOLDOUT: GameConfig.roster.set_waves(AIPersonality.AGGRESSOR)
	var m := build_map(cfg)
	var hs := m.build_state(int(cfg["seed"]) * 7919, Roster.from_dict(GameConfig.roster.to_dict()) if modern else null)
	var gs := m.build_state(int(cfg["seed"]) * 7919, Roster.from_dict(GameConfig.roster.to_dict()) if modern else null)
	for st: GameState in [hs, gs]:
		for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
			st.roster.slot(side).kind = Roster.SlotKind.AI
	var host := NetGame.new(hs, GameActionResolver.new(hs), true, 0)
	var guest := NetGame.new(gs, GameActionResolver.new(gs), false, 1)
	for r: GameActionResolver in [host.resolver, guest.resolver]:
		r.fog_mode = MCF.Fog.STANDARD
		r.update_airlocks()
		if modern: r.prepare_mode(m)
	if modern:
		for side in [0, 1]:
			if hs.living_units_of(side).size() < int(cfg.units): _fails.append("%s: undersized army %d" % [name, side])
	if cfg.has("events"):
		for event in cfg.events:
			if not host.resolver._events_allowed().has(event): _fails.append("%s: event is not eligible in fixture" % event)
	var initial_counts := [hs.living_units_of(0).size(), hs.living_units_of(1).size()]
	var start := StateCodec.encode(hs)
	var rules := StateCodec.encode_rules(host.resolver)
	# Хост и гость — разные процессы в настоящей игре. Статические кэши (индекс объектов,
	# кэш разливов) держат ОДНУ сетку, и гость, отвечающий после каждого действия хоста,
	# сбрасывал бы их на каждом шаге — а у игрока этого не бывает. Поэтому гость получает
	# провод хоста целиком ПОСЛЕ партии, и время каждой стороны меряется честно.
	var steps: Array = []
	var wire: Array = []
	var resyncs := [0]
	host.outgoing.connect(func(msg: Dictionary) -> void:
		if msg.get("k", "") == NetGame.K_ACTION:
			steps.append({"i": msg["i"], "r": (msg["r"] as Array).duplicate()})
		wire.append(msg.duplicate(true)))
	guest.outgoing.connect(func(_msg: Dictionary) -> void:
		resyncs[0] += 1)
	var hfx := FxDecals.new()
	var gfx := FxDecals.new()
	host.action_applied.connect(func(_i, r: ActionResult) -> void: hfx.apply(r.fx))
	guest.action_applied.connect(func(_i, r: ActionResult) -> void: gfx.apply(r.fx))
	var opening: Array = []
	if modern:
		host.announce_initiative()
		opening = wire[0].get("r", []).duplicate()
		hfx.apply(host.opening_civilians.fx)
	var probe: Node2D = null
	var lighting: LightManager = null
	if modern:
		probe = load("res://scenes/Main.gd").new()
		probe.state = hs
		probe.resolver = host.resolver
		probe._fx = hfx
		lighting = LightManager.new()
		root.add_child(lighting)
	var brains := {}
	for side in hs.roster.player_ids():
		var ai := AIController.new(side, AIController.Difficulty.HARD)
		ai.style = int(cfg.get("style", AIController.Style.STANDARD))
		ai.intent_ready.connect(_on_intent)
		brains[side] = ai
	var trace := PackedStringArray()
	var t_ai := 0
	var t_host := 0
	var t_digest := 0
	var t_fog := 0
	var t_fx := 0
	var t_memory := 0
	var t_lighting := 0
	var actions := 0
	var t0 := Time.get_ticks_usec()
	while hs.turns.round_number <= int(cfg["rounds"]) and actions < 20000:
		var side: int = hs.active_player()
		var ai: AIController = brains.get(side)
		_pending = null
		var ta := Time.get_ticks_usec()
		if ai != null and not cfg.get("turns_only", false):
			ai.begin_turn(hs)
		t_ai += Time.get_ticks_usec() - ta
		var it: Intent = _pending if _pending != null else EndTurnIntent.new()
		actions += 1
		if modern and actions % 500 == 0: print("  %s: %d actions, round %d" % [name, actions, hs.turns.round_number])
		var th := Time.get_ticks_usec()
		var ok := [false]
		var conn := func(_i, r: ActionResult) -> void: ok[0] = r.ok
		host.action_applied.connect(conn)
		host.submit_local(it)
		host.action_applied.disconnect(conn)
		t_host += Time.get_ticks_usec() - th
		if not ok[0] and ai != null:
			ai.notify_intent_denied(hs)
		trace.append("%s %s" % [JSON.stringify(IntentCodec.encode(it)), "ok" if ok[0] else "no"])
		var td := Time.get_ticks_usec()
		hs.digest_hash()
		t_digest += Time.get_ticks_usec() - td
		var tf := Time.get_ticks_usec()
		var visible := host.resolver.team_visible_coords(MCF.Owner.PLAYER_1)
		if _fog_delay_ms > 0: OS.delay_msec(_fog_delay_ms)
		t_fog += Time.get_ticks_usec() - tf
		if modern:
			var tm := Time.get_ticks_usec()
			var changes: Variant = host.resolver.take_vis_changes(0)
			var shown: Grid = probe._board_memory(0, visible, changes)
			var memory: DecalMemory = probe._fog_mem_fx[0]
			memory.update(hfx, visible, changes, hs.grid.width)
			hfx.decal_dirty.clear()
			t_memory += Time.get_ticks_usec() - tm
			var tl := Time.get_ticks_usec()
			lighting.update_view(shown, Vector2.ZERO, 0.25, Vector2.ZERO, 32.0, hs.env, visible, true, memory.view)
			t_lighting += Time.get_ticks_usec() - tl
		var tx := Time.get_ticks_usec()
		hfx.advance(0.5)
		t_fx += Time.get_ticks_usec() - tx
		wire.append({"k": "_tick"})   # гость шагнёт косметику ровно там же
	var t_total := Time.get_ticks_usec() - t0
	# Гость: тот же провод, по одному сообщению, с тем же шагом косметики.
	var tg := Time.get_ticks_usec()
	for msg: Dictionary in wire:
		if msg["k"] == "_tick":
			gfx.advance(0.5)
		else:
			guest.receive(msg)
			if msg["k"] == NetGame.K_INIT: gfx.apply(guest.opening_civilians.fx)
	var t_guest := Time.get_ticks_usec() - tg
	# Сохранение и загрузка: та же доска после круга через файл.
	var ts := Time.get_ticks_usec()
	var saved := JSON.stringify(StateCodec.encode(hs))
	# Состояние под размер доски: restore_into раскладывает клетки в готовую сетку.
	var back := GameState.new(hs.grid.width, hs.grid.height)
	StateCodec.restore_into(back, JSON.parse_string(saved))
	var restored := GameActionResolver.new(back)
	StateCodec.apply_rules(restored, JSON.parse_string(JSON.stringify(StateCodec.encode_rules(host.resolver))))
	var t_save := Time.get_ticks_usec() - ts
	# Полная подпись (юниты, машины, КАЖДАЯ непустая клетка, очередь), а не сетевая.
	var save_ok := TS.digest(back) == TS.digest(hs)
	# Повтор с начала: стартовая доска + все действия с их бросками.
	var tr := Time.get_ticks_usec()
	var player := ReplayPlayer.new({"start": start, "rules": rules, "opening": opening, "opening_processed": modern, "steps": steps,
			"event_selection": "uniform", "meta": {}})
	player.seek(player.step_count())
	var t_replay := Time.get_ticks_usec() - tr
	var replay_ok := player.state != null and TS.digest(player.state) == TS.digest(hs)
	var rules_hash := JSON.stringify(StateCodec.encode_rules(host.resolver))
	if modern:
		save_ok = save_ok and JSON.parse_string(JSON.stringify(StateCodec.encode_rules(restored))) == JSON.parse_string(rules_hash)
		replay_ok = replay_ok and JSON.parse_string(JSON.stringify(StateCodec.encode_rules(player.resolver))) == JSON.parse_string(rules_hash)
	var guest_ok := gs.digest_hash() == hs.digest_hash()
	if modern: guest_ok = guest_ok and TS.digest(gs) == TS.digest(hs)
	if modern: guest_ok = guest_ok and JSON.parse_string(JSON.stringify(StateCodec.encode_rules(guest.resolver))) == JSON.parse_string(rules_hash)
	if not save_ok or not replay_ok or not guest_ok or resyncs[0] != 0:
		_fails.append("%s: save/replay/guest invariant failed" % name)
	if actions >= 20000: _fails.append("%s: action limit reached before completing rounds" % name)
	if probe != null: probe.free()
	if lighting != null: lighting.free()
	var alive := [0, 0, 0]
	for u: UnitInstance in hs.all_units():
		if u.is_alive():
			alive[0 if u.owner == 0 else (1 if u.owner == 1 else 2)] += 1
	var fx_same := JSON.stringify(hfx.to_dict()) == JSON.stringify(gfx.to_dict())
	var sig := "actions=%d board=%d trace=%d alive=%d/%d/%d fx=%d guest_same=%s resyncs=%d save=%s replay=%s" % [
			actions, hs.digest_hash(), "\n".join(trace).hash(), alive[0], alive[1], alive[2],
			JSON.stringify(hfx.to_dict()).hash(), str(guest_ok and fx_same),
			resyncs[0], str(save_ok), str(replay_ok)]
	if not fx_same: _fails.append("%s: guest cosmetics differ" % name)
	if modern: sig += " rules=%d" % rules_hash.hash()
	return {"actions": actions, "sig": sig, "rules_hash": rules_hash.hash(),
			"board_size": [hs.grid.width, hs.grid.height], "initial_units": initial_counts,
			"t_memory": t_memory / 1000.0, "t_lighting": t_lighting / 1000.0, "t_total": t_total / 1000.0, "t_ai": t_ai / 1000.0,
			"t_host": t_host / 1000.0, "t_guest": t_guest / 1000.0, "t_digest": t_digest / 1000.0,
			"t_fog": t_fog / 1000.0, "t_fx": t_fx / 1000.0, "t_save": t_save / 1000.0,
			"t_replay": t_replay / 1000.0}

# --- Экран боя ---

func _start_render() -> void:
	GameConfig.civilians_enabled = true
	GameConfig.civilian_count = 40
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.roster = Roster.default_duel(false)
	MapHandoff.pending = build_map(SCENES["large"])
	change_scene_to_file("res://scenes/Main.tscn")
	_render = {"frame": 0, "proc": 0, "draw": 0, "n": 0, "t_draw0": 0}

func _process(_d: float) -> bool:
	if _render.is_empty():
		return false
	_render["frame"] += 1
	var f: int = _render["frame"]
	var main := current_scene
	if main == null or not main.has_method("_reposition_hud_grip") or main.state == null:
		return false
	if f == 20:
		var ids: Array[int] = []
		for u: UnitInstance in main.state.all_units():
			if u.owner == main.state.active_player() and u.is_alive():
				ids.append(u.id)
		main._set_group(ids)
		main.zoom = 0.28
		main.pan = Vector2(20, 20)
		main.draw.connect(func() -> void:
			_render["t_draw0"] = Time.get_ticks_usec()
			(func() -> void:
				_render["draw"] += Time.get_ticks_usec() - int(_render["t_draw0"])).call_deferred())
	if f > 30 and f <= 270:
		var t := Time.get_ticks_usec()
		main._process(0.016)
		_render["proc"] += Time.get_ticks_usec() - t
		_render["n"] += 1
		main.queue_redraw()
	if f == 272:
		_micro(main)
	if f == 275:
		var n: int = _render["n"]
		print("render: %d frames, _process %.1f us/frame, _draw %.2f ms/frame (large map, %d units, group of %d)" % [
				n, float(_render["proc"]) / n, float(_render["draw"]) / n / 1000.0,
				main.state.all_units().size(), main._group_ids.size()])
		quit(0)
		return true
	return false

## Цена отдельных выражений из _process/_draw — на живом экране, по 200 повторов, в мкс
## на кадр. «Пустой цикл» — цена самого перебора бойцов, от неё и считать остальное.
func _micro(main: Node) -> void:
	const N := 200
	var units: Array = main.state.all_units()
	var hits := 0
	var t := Time.get_ticks_usec()
	for k in N:
		for u: UnitInstance in units:
			pass
	var t_loop := float(Time.get_ticks_usec() - t) / N
	t = Time.get_ticks_usec()
	for k in N:
		for u: UnitInstance in units:
			if main._group_set.has(u.id):
				hits += 1
	var t_group := float(Time.get_ticks_usec() - t) / N
	t = Time.get_ticks_usec()
	for k in N:
		for u: UnitInstance in units:
			if main._gear_checked(u) and main.resolver.unit_missing_equipment(u):
				hits += 1
	var t_gear := float(Time.get_ticks_usec() - t) / N
	t = Time.get_ticks_usec()
	for k in N:
		main._reposition_hud_grip()
	var t_grip := float(Time.get_ticks_usec() - t) / N
	t = Time.get_ticks_usec()
	for k in N:
		main._refresh_clocks()
	var t_clock := float(Time.get_ticks_usec() - t) / N
	t = Time.get_ticks_usec()
	for k in N:
		for v: Vehicle in main.state.all_vehicles():
			var key := Sprites.resolve(v.type_id)
			var label: String = VehicleDB.get_vehicle(v.type_id).get("name", v.type_id)
	var t_veh := float(Time.get_ticks_usec() - t) / N
	print("micro, us per frame: unit loop %.1f | group ring check %.1f | gear check %.1f | hud grip %.1f | clocks %.1f | vehicle lookups %.1f (%d vehicles)" % [
			t_loop, t_group, t_gear, t_grip, t_clock, t_veh, main.state.all_vehicles().size()])
