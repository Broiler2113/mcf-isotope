extends SceneTree
const AudioRuntime = preload("res://src/audio/GameAudio.gd")
var audio_system: AudioRuntime
var AudioLayer: Script
var DiceScript: Script
var SettingsScript: Script
## Observe real presentation cues and players, not just calls to a mock mixer.
var failures: Array[String] = []
var played: Array[String] = []
var checks := 0

func _initialize() -> void:
	audio_system = root.get_node("GameAudio")
	get_tree_watchdog.call_deferred()
	_run.call_deferred()

func get_tree_watchdog() -> void:
	create_timer(30).timeout.connect(func() -> void:
		printerr("audio regression timed out")
		quit(2))

func ck(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)

func _run() -> void:
	AudioLayer = load("res://src/audio/BattleAudio.gd")
	DiceScript = load("res://scenes/DiceRoller.gd")
	SettingsScript = load("res://src/ui/SettingsWindow.gd")
	for script: Script in [AudioLayer, DiceScript, SettingsScript]:
		if script == null or not script.can_instantiate():
			printerr("audio fixture cannot load a presentation script")
			quit(2)
			return
	var old := [audio_system.master, audio_system.sfx, audio_system.voice, audio_system.muted, audio_system.turn_voice]
	var settings := ConfigFile.new()
	settings.load(audio_system.SETTINGS_PATH)
	audio_system.set_levels(0.8, 0.8, 0.7, false)
	audio_system.cue_played.connect(_heard)
	_catalog()
	_lifecycle()
	_fog_and_priority()
	await _surfaces_and_rooms()
	_component_damage()
	await _dice()
	await _settings()
	await _messages()
	await _outcomes()
	_replay()
	audio_system.cue_played.disconnect(_heard)
	audio_system.stop_scope(root)
	audio_system.set_levels(old[0], old[1], old[2], old[3], old[4])
	settings.save(audio_system.SETTINGS_PATH)
	audio_system.stop_all()
	await create_timer(0.08).timeout # Drain AudioServer's deferred playback stops.
	ck(not GameLog.text().contains("ERROR:"), "audio regression has no engine/runtime errors")
	for message in failures:
		printerr("FAIL " + message)
	print("audio: %d checks, %d failures (lifecycle, fog, voice cap, SAM, settings, dice and replay)" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _heard(id: String, bus: String, _position: Vector2) -> void:
	played.append(bus + ":" + id)

func _catalog() -> void:
	for id: String in audio_system.Catalog.SFX:
		var spec: Dictionary = audio_system.Catalog.SFX[id]
		for take in range(1, int(spec.n) + 1):
			var stream := audio_system.stream(id, false, take)
			ck(stream is AudioStreamOggVorbis and stream.get_length() > 0.02, "SFX take imported: %s_%d" % [id, take])
			ck(stream != null and stream.loop == bool(spec.loop), "loop flag matches the catalog: %s_%d" % [id, take])
		ck(audio_system.CATEGORY_DB.has(str(spec.cat)), "category has a mix level: " + id)
	var takes := {}
	for i in 12:
		takes[audio_system.stream("rifle").resource_path] = true
	ck(takes.size() > 1, "repeated shots rotate between recorded takes")
	for id: String in audio_system.Catalog.VOICE:
		var stream := audio_system.stream(id, true)
		ck(stream is AudioStreamWAV and stream.get_length() > 0, "SAM asset imported: " + id)
	for pair: Array in RandomEvents.REGISTRY:
		for phase: String in ["warn", "land"]:
			ck(audio_system.Catalog.VOICE.has(pair[0] + "_" + phase), "registry SAM line exists")
	for letter in MCF.PLAYER_LETTERS:
		ck(audio_system.Catalog.VOICE.has("turn_" + letter), "turn SAM line exists: " + letter)

func _lifecycle() -> void:
	var fx := FxDecals.new()
	var cues: Array[String] = []
	fx.sound_requested.connect(func(id: String, _cell: Vector2i, _owner: int) -> void: cues.append(id))
	var lane := {"fx": "lane", "from": [2, 2], "to": [8, 2], "owner": 0, "kind": "shot"}
	var tracer := {"fx": "tracer", "from": [2, 2], "to": [8, 2], "count": 1}
	fx.apply_lanes([lane, tracer])
	ck(cues == ["rifle"], "fast muzzle sounds once at lane creation")
	fx.apply([tracer])
	fx.advance(0.1)
	ck(cues == ["rifle"], "fast impact waits for tracer arrival")
	fx.advance(0.07)
	ck(cues == ["rifle", "bullet_hit"], "fast impact at tracer arrival")
	fx.advance(1)
	ck(cues.size() == 2, "fast impact does not repeat on later frames")
	cues.clear()
	var burst_lane := lane.duplicate(true)
	burst_lane["from"] = [3, 3]
	var burst_tracer := tracer.duplicate(true)
	burst_tracer["from"] = [3, 3]
	burst_tracer["count"] = 3
	fx.apply_lanes([lane, tracer, burst_lane, burst_tracer])
	ck(cues == ["rifle", "rifle"], "batched lanes choose the muzzle cue for their own shooter")
	for weapon: String in {"sniper": "sniper", "assault": "shotgun", "machinegunner": "mg",
			"dpmg": "heavy_mg", "borg": "heavy_mg", "light_infantry": "rifle"}:
		cues.clear()
		var armed := lane.duplicate(true)
		armed["weapon"] = weapon
		fx.apply_lanes([armed])
		ck(cues.size() == 1 and cues[0] == {"sniper": "sniper", "assault": "shotgun", "machinegunner": "mg",
			"dpmg": "heavy_mg", "borg": "heavy_mg", "light_infantry": "rifle"}[weapon], "muzzle sound follows the weapon: " + weapon)
	for kind: String in ["rocket", "shell", "grenade"]:
		fx.clear()
		cues.clear()
		var shot := {"fx": "shot", "kind": kind, "from": [2, 2], "to": [8, 2]}
		fx.apply([shot])
		ck(cues == [kind + "_launch"], kind + " launch has no premature bang")
		fx.advance(FxDecals.shot_dur(shot) * 0.5)
		ck(cues.size() == 1, kind + " remains in flight")
		fx.advance(FxDecals.shot_dur(shot) * 0.5 + 0.001)
		ck(cues == [kind + "_launch", "explosion"], kind + " bangs exactly on removal")
		fx.apply([{"fx": "debris", "at": Vector2i(8, 2), "cells": [Vector2i(8, 2)], "blast": true}], true)
		ck(cues.size() == 2 and fx.flashes.size() == 1, "projectile flash does not duplicate its arrival bang")
	fx.clear()
	cues.clear()
	fx.audio_suppressed = true
	fx.apply_lanes([lane])
	fx.apply([tracer])
	fx.advance(5)
	ck(cues.is_empty(), "replay reconstruction can rebuild all FX silently")
	fx.audio_suppressed = false

func _layer() -> Node:
	var audio: Node = AudioLayer.new()
	audio.cell_visible = func(_cell: Vector2i) -> bool: return true
	audio.own_cell = func(_cell: Vector2i) -> bool: return false
	audio.viewer = func() -> int: return 0
	root.add_child(audio)
	return audio

func _fog_and_priority() -> void:
	GameConfig.civilians_enabled = false
	var map := MapData.blank_arena(18, 12)
	for y in 12:
		map.set_cell(Vector2i(9, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(14, 4), "light_infantry", 1)
	var state := map.build_state(313)
	var before := state.digest_hash()
	var rolls := state.dice.own_rolls
	var MainScript := load("res://scenes/Main.gd")
	var client_a = MainScript.new()
	client_a.state = state
	client_a.resolver = GameActionResolver.new(state)
	client_a.resolver.fog_mode = MCF.Fog.STANDARD
	client_a.networked = true
	client_a.my_owner = 0
	var client_b = MainScript.new()
	client_b.state = state
	client_b.resolver = GameActionResolver.new(state)
	client_b.resolver.fog_mode = MCF.Fog.STANDARD
	client_b.networked = true
	client_b.my_owner = 1
	var a := _layer()
	var b := _layer()
	a.cell_visible = client_a._audio_cell_visible
	b.cell_visible = client_b._audio_cell_visible
	ck(a.cue("rifle", Vector2i(3, 4)) != null, "visible shooter is audible to client A")
	ck(b.cue("rifle", Vector2i(3, 4)) == null, "the same hidden shooter is silent for client B")
	ck(a._ambient.playing and b._ambient.playing, "non-positional ambience is independent of asymmetric fog")
	ck(state.digest_hash() == before and state.dice.own_rolls == rolls, "audio and visibility checks never alter state/dice")
	a.reset()
	a.cell_visible = func(_cell: Vector2i) -> bool: return true
	a.position = Vector2(90, -20)
	a.scale = Vector2(0.5, 0.5)
	var shot: AudioStreamPlayer2D = a.cue("rifle", Vector2i(3, 4))
	ck(shot.global_position.is_equal_approx(a.position + (a.origin + Vector2(3.5, 4.5) * 40) * 0.5), "world source follows camera pan/zoom")
	a.cue("rifle", Vector2i(3, 4))
	ck(a.voices.size() == 1 and a.voices[0].count == 2 and shot.volume_db > -12, "same-frame near duplicates merge slightly louder")
	a.reset()
	a.ceiling = 4
	for i in 300:
		a.cue("rifle", Vector2i(i * 3, 3), 1)
		ck(a.voices.size() <= a.ceiling, "Giant-board burst stays under world voice ceiling")
	ck(a._pool.size() == AudioLayer.WORLD_CAP, "voice stealing reuses a fixed player pool")
	var own: AudioStreamPlayer2D = a.cue("explosion", Vector2i(0, 20), 0)
	ck(own != null and a.voices.any(func(e: Dictionary) -> bool: return e.priority >= 70), "own-unit sound replaces lower-priority visible fire")
	for i in 4:
		a.cue("explosion", Vector2i(30 + i * 3, 20), 0)
	ck(a.cue("bullet_hit", Vector2i(80, 20), 1) == null, "lowest-priority incoming sound is dropped when all playing voices outrank it")
	a.cell_visible = func(_cell: Vector2i) -> bool: return false
	a._process(0)
	ck(a.voices.is_empty(), "playing tails stop when the viewpoint loses visibility")
	a.free()
	b.free()
	client_a.free()
	client_b.free()

## Recorded-sound routing reads the settled state: what a bullet hit, the floor under
## a step, airlocks, vacuum, burning cells and the environment's room and ambience.
func _surfaces_and_rooms() -> void:
	GameConfig.civilians_enabled = false
	var map := MapData.blank_arena(20, 12)
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(4, 2), "shield_bearer", 1)
	map.set_cell(Vector2i(6, 2), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_GLASS)
	map.set_cell(Vector2i(7, 2), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WOOD_WALL)
	map.set_cell(Vector2i(8, 2), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	map.set_cell(Vector2i(10, 6), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_AIRLOCK)
	map.set_cell(Vector2i(15, 8), MCF.FLOOR_NORMAL, 0.0, true, "")
	map.set_look(5 * 20 + 3, MCF.Look.WOOD)
	map.set_look(5 * 20 + 4, MCF.Look.GRATE)
	var state := map.build_state(77)
	state.grid.cell(Vector2i(9, 9)).corpse_count = 1
	var audio := _layer()
	audio.world = func() -> GameState: return state
	ck(audio._impact(Vector2i(4, 2)) == "shield_block", "bullets on a living Shield Bearer ring off the shield")
	ck(audio._impact(Vector2i(9, 9)) == "hit_flesh", "bullets into a body sound like flesh")
	ck(audio._impact(Vector2i(6, 2)) == "hit_glass", "glass impact")
	ck(audio._impact(Vector2i(7, 2)) == "hit_wood", "wood wall impact")
	state.env = "town"
	ck(audio._impact(Vector2i(8, 2)) == "hit_stone", "town wall is masonry")
	state.env = "station"
	ck(audio._impact(Vector2i(8, 2)) == "hit_metal", "station wall is plating")
	ck(audio._impact(Vector2i(12, 9)) == "hit_metal", "station deck is metal")
	state.env = "field"
	ck(audio._impact(Vector2i(12, 9)) == "hit_dirt", "open field ground is dirt")
	var walker := state.grid.cell(Vector2i(2, 2)).occupant
	played.clear()
	audio.step(walker, Vector2i(3, 4), Vector2i(3, 5))
	audio.step(walker, Vector2i(3, 5), Vector2i(4, 5))
	ck(played.has("SFX:step_wood") and played.has("SFX:step_metal"), "steps follow the floor look")
	played.clear()
	audio.step(walker, Vector2i(10, 3), Vector2i(10, 5))
	ck(played.has("SFX:door_open"), "an airlock opens as a soldier comes within reach")
	played.clear()
	audio.step(walker, Vector2i(10, 5), Vector2i(10, 3))
	ck(played.has("SFX:door_close"), "an airlock shuts behind a soldier who leaves")
	walker.is_drone = true
	played.clear()
	audio.step(walker, Vector2i(10, 3), Vector2i(10, 5))
	ck(played.is_empty(), "drones make no steps and open no airlocks")
	walker.is_drone = false
	audio.reset()
	state.env = "station"
	var space: AudioStreamPlayer2D = audio.cue("explosion", Vector2i(15, 8), 1)
	var hall: AudioStreamPlayer2D = audio.cue("rifle", Vector2i(12, 9), 1)
	ck(space != null and space.bus == "Vacuum" and hall != null and hall.bus == "World", "vacuum muffles, a hall rings")
	audio._process(0.0)
	ck(audio._env == "station" and audio._ambient.stream.resource_path.contains("amb_station"), "ambience follows the environment")
	var reverb := AudioServer.get_bus_effect(AudioServer.get_bus_index("World"), 0) as AudioEffectReverb
	ck(reverb != null and reverb.wet > 0.1, "station corridors get room reverb")
	state.grid.cell(Vector2i(5, 9)).on_fire = true
	audio._update_fire()
	ck(audio._fire.playing and audio._fire.position.is_equal_approx(audio.origin + Vector2(5.5, 9.5) * audio.cell_size), "visible fire crackles where it burns")
	state.grid.cell(Vector2i(5, 9)).on_fire = false
	audio._update_fire()
	ck(not audio._fire.playing, "fire loop stops when the flames are out")
	played.clear()
	audio_system.say("gas_warn", audio)
	await _flush_voice()
	ck(played.has("SFX:radio_in") and played.has("Voice:gas_warn"), "announcements are keyed over the radio")
	audio_system.stop_scope(audio)
	audio.free()

func _dice() -> void:
	var dice: Node = DiceScript.new()
	root.add_child(dice)
	played.clear()
	dice.play([{"value": 3, "good": true, "tag": "test"}], false, "", 100)
	await dice.finished
	ck(played.count("SFX:dice_roll") == 1 and played.count("SFX:dice_land") == 1, "automatic dice has one roll and one landing cue")
	played.clear()
	dice.play([{"value": 4, "good": true, "tag": "remote"}], false, "", 100, true)
	await process_frame
	ck(not played.has("SFX:dice_roll"), "remote dice is silent until released")
	dice.release()
	await dice.finished
	ck(played.count("SFX:dice_roll") == 1 and played.count("SFX:dice_land") == 1, "remote roll also sounds exactly once")
	dice.queue_free()
	await process_frame

func _component_damage() -> void:
	var audio := _layer()
	for component: String in ["hull", "tracks_l", "tower", "gun"]:
		var map := MapData.blank_arena(22, 14)
		map.set_spawn(Vector2i(3, 4), "tank", 0)
		map.set_spawn(Vector2i(18, 10), "light_infantry", 1)
		var state := map.build_state(914)
		var resolver := GameActionResolver.new(state)
		var vehicle: Vehicle = state.all_vehicles()[0]
		var result := ActionResult.success()
		resolver._damage_component(vehicle, component, vehicle.component(component), "fixture", result)
		var digest := state.digest_hash()
		var rolls := state.dice.own_rolls
		played.clear()
		audio.component_damage(result, state)
		var id := "vehicle_" + ("tracks" if component == "tracks_l" else component)
		ck(played.has("SFX:" + id), "actual component destruction emits " + id)
		audio.component_damage(result, state)
		ck(played.count("SFX:" + id) == 1, "component cue is not repeated at action completion")
		ck(state.digest_hash() == digest and state.dice.own_rolls == rolls, "component audio preserves state/dice")
		audio.reset()
	audio.free()

func _settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(audio_system.SETTINGS_PATH)
	cfg.set_value("ui", "audio_test_preserved", "yes")
	cfg.save(audio_system.SETTINGS_PATH)
	audio_system.set_levels(0.5, 0.6, 0, false, false)
	ck(AudioServer.is_bus_mute(AudioServer.get_bus_index("Voice")), "Voice slider at zero mutes the Voice bus")
	ck(not AudioServer.is_bus_mute(AudioServer.get_bus_index("SFX")), "Voice mute leaves SFX available")
	played.clear()
	audio_system.say("mortar_warn", root)
	audio_system.ui("ui_click")
	ck(not played.has("Voice:mortar_warn") and played.has("SFX:ui_click"), "muted voice never starts while effects still play")
	audio_system.load_settings()
	ck(is_equal_approx(audio_system.master, 0.5) and is_equal_approx(audio_system.sfx, 0.6) \
		and audio_system.voice == 0 and not audio_system.turn_voice, "audio levels survive settings reload")
	cfg.load(audio_system.SETTINGS_PATH)
	ck(cfg.get_value("ui", "audio_test_preserved") == "yes", "audio saves preserve other settings sections")
	var window: CanvasLayer = SettingsScript.open(root)
	await process_frame
	ck(window._tabs.get_tab_title(window.TAB_AUDIO) == "Audio", "Settings has an Audio tab")
	var slider: HSlider = window.find_child("Audio_voice", true, false)
	ck(slider != null, "Voice slider exists")
	if slider != null:
		slider.value = 40
		ck(is_equal_approx(audio_system.voice, 0.4), "Voice slider is wired to saved bus settings")
	window.free()
	audio_system.set_levels(0.8, 0.8, 0.7, false)

func _messages() -> void:
	var audio := _layer()
	played.clear()
	audio.message("⚠ Artillery Barrage — zone (1, 1), landing at the end of this round")
	await _flush_voice()
	ck(played.has("Voice:mortar_warn") and played.has("SFX:event_warn"), "public warning triggers matching SAM and SFX")
	audio_system.stop_scope(audio)
	played.clear()
	audio.message("Artillery Barrage hits zone (1, 1) 3×3: 4 cells destroyed")
	await _flush_voice()
	ck(played.has("Voice:mortar_land"), "public landing triggers its separate SAM line")
	audio_system.stop_scope(audio)
	played.clear()
	audio.message("— Player B: learned AI unavailable (fixture) — AI - Tactician takes the seat —")
	await _flush_voice()
	ck(played.has("Voice:fallback"), "fallback line narrates the existing battle-log message")
	audio_system.stop_scope(audio)
	played.clear()
	audio.turn(1, 0, 0)
	audio.turn(1, 0, 0)
	await _flush_voice()
	ck(played.count("Voice:turn_A") == 1, "refreshing the same turn never repeats its line")
	audio_system.stop_scope(audio)
	played.clear()
	audio.message("Round 1 score: Zone A contested. Points: Team 1 0 (to 12)")
	await _flush_voice()
	ck(played.has("Voice:zone_contested"), "contested-zone line narrates the public score message")
	audio_system.stop_scope(audio)
	played.clear()
	audio.message("Round 2 score: Zone A contested. Points: Team 1 0 (to 12)")
	await _flush_voice()
	ck(not played.has("Voice:zone_contested"), "unchanged contested status is not announced again")
	for pair: Array in RandomEvents.REGISTRY:
		audio_system.stop_scope(audio)
		played.clear()
		audio.message("⚠ %s — test warning" % pair[1])
		await _flush_voice()
		ck(played.has("Voice:" + pair[0] + "_warn"), "announcement mapping: " + pair[0])
	var landings := {
		"Artillery Barrage hits zone": "mortar", "Gas Cloud settles over zone": "gas",
		"— Unknown forces land, hostile to everyone": "army", "Fire breaks out in zone": "fire",
		"EMP Burst over zone": "emp", "A dust storm sweeps the battlefield": "dust",
		"Structural collapse at zone": "collapse", "— Reinforcements reach Player A": "reinforce",
		"— Wave 1 lands: 12 fighters —": "wave", "⚠ Wave 2 — landing this round": "wave_warn",
	}
	for text: String in landings:
		audio_system.stop_scope(audio)
		played.clear()
		audio.message(text)
		await _flush_voice()
		var expected: String = landings[text] if landings[text] == "wave_warn" else landings[text] + "_land"
		ck(played.has("Voice:" + expected), "landing/mode mapping: " + expected)
	audio.free()

func _outcomes() -> void:
	var MainScript := load("res://scenes/Main.gd")
	for key: String in ["victory", "defeat", "draw"]:
		var map := MapData.blank_arena(16, 12)
		if key != "draw": map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
		var state := map.build_state(5181)
		var main = MainScript.new()
		main.state = state
		main.resolver = GameActionResolver.new(state)
		main.networked = true
		main.my_owner = 1 if key == "defeat" else 0
		var audio := _layer()
		main._audio = audio
		played.clear()
		main._play_victory_audio()
		main._play_victory_audio()
		await _flush_voice()
		ck(played.count("SFX:" + key) == 1 and played.count("Voice:" + key) == 1, "one distinct sting/SAM line for " + key)
		audio.free()
		main._audio = null
		main.free()

func _flush_voice() -> void:
	await process_frame
	await process_frame

func _trace_result(result: ActionResult) -> Array[String]:
	var sounds: Array[String] = []
	var fx := FxDecals.new()
	fx.sound_requested.connect(func(id: String, _cell: Vector2i, _owner: int) -> void: sounds.append(id))
	fx.apply_lanes(result.fx)
	var launch := result.fx.filter(func(e: Dictionary) -> bool: return e.get("fx") in ["tracer", "shot", "casings"])
	var hit := result.fx.filter(func(e: Dictionary) -> bool: return not e.get("fx") in ["tracer", "shot", "casings", "lane"])
	fx.apply(launch)
	fx.advance(1)
	fx.apply(hit, result.fx.any(func(e: Dictionary) -> bool: return e.get("fx") == "shot"))
	return sounds

func _replay() -> void:
	var map := MapData.blank_arena(16, 10)
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(6, 4), "light_infantry", 1)
	var state := map.build_state(9301)
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.OFF
	var recorder := ReplayRecorder.new()
	recorder.begin(state, resolver)
	resolver.replay_recorder = recorder
	recorder.capture_opening()
	var live: Array = []
	for i in 6:
		var legal := resolver.legal_intents(state.active_player())
		var action: Intent = EndTurnIntent.new(state.active_player())
		for candidate: Intent in legal:
			if candidate is ShootIntent:
				action = candidate
				break
		var result := resolver.resolve(action)
		if result.ok: live.append(_trace_result(result))
	var replay := ReplayPlayer.new(recorder.to_dict())
	replay.seek(0)
	var replayed: Array = []
	while replay.has_next():
		var result := replay.play_next()
		if result != null and result.ok: replayed.append(_trace_result(result))
	ck(live == replayed and live.any(func(a: Array) -> bool: return not a.is_empty()), "recorded gameplay reproduces the same ordered weapon/impact cues")
	ck(replay.state.digest_hash() == state.digest_hash(), "audio-equipped replay preserves the simulation digest")
