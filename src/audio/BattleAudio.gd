class_name BattleAudio
extends Node2D
## Receives cosmetic lifecycle cues, then applies THIS viewer's information boundary.
const WORLD_CAP := 12
const MERGE_MS := 40
var ceiling := WORLD_CAP
var cell_visible: Callable
var own_cell: Callable
var viewer: Callable
var enabled := true
var origin := Vector2(40, 40)
var cell_size := 40.0
var voices: Array[Dictionary] = []
var _pool: Array[AudioStreamPlayer2D] = []
var _ambient: AudioStreamPlayer
var _component_result: WeakRef
var _action_result: WeakRef
var _turn_key := ""
var _zone_states := {}
var suppress := false

func _ready() -> void:
	for i in WORLD_CAP:
		var player := AudioStreamPlayer2D.new()
		player.bus = "SFX"
		player.max_distance = 1400
		player.panning_strength = 0.8
		add_child(player)
		player.finished.connect(_finished.bind(player))
		_pool.append(player)
	_ambient = AudioStreamPlayer.new()
	_ambient.bus = "SFX"
	_ambient.volume_db = -29
	var texture := GameAudio.stream("ambience").duplicate() as AudioStreamWAV
	texture.loop_mode = AudioStreamWAV.LOOP_FORWARD
	texture.loop_end = int(texture.get_length() * texture.mix_rate)
	_ambient.stream = texture
	add_child(_ambient)
	_ambient.play()

func _exit_tree() -> void:
	GameAudio.stop_scope(self)
	for player in _pool:
		player.stop()
		player.stream = null
	voices.clear()
	_ambient.stop()
	_ambient.stream = null

func _process(_delta: float) -> void:
	for entry in voices.duplicate():
		if suppress or (cell_visible.is_valid() and not cell_visible.call(entry.cell)):
			stop_player(entry.player)

func cue(id: String, cell: Vector2i, owner := -1) -> AudioStreamPlayer2D:
	if not enabled or suppress or not GameAudio.audible("SFX") \
			or not cell_visible.is_valid() or not cell_visible.call(cell):
		return null
	var priority := 20
	if (viewer.is_valid() and owner >= 0 and owner == int(viewer.call())) \
			or (own_cell.is_valid() and own_cell.call(cell)):
		priority += 50
	if id in ["explosion", "vehicle_hull"]:
		priority += 5
	var now := Time.get_ticks_msec()
	for entry in voices:
		if entry.id == id and now - int(entry.start) <= MERGE_MS \
				and Vector2i(entry.cell - cell).length_squared() <= 2:
			entry.count = mini(4, int(entry.count) + 1)
			entry.priority = maxi(priority, entry.priority)
			entry.player.volume_db = -12.0 + minf(3.0, 10.0 * log(float(entry.count)) / log(10.0))
			return entry.player
	var player: AudioStreamPlayer2D
	if voices.size() >= clampi(ceiling, 1, WORLD_CAP):
		var lowest := 0
		for i in range(1, voices.size()):
			if voices[i].priority < voices[lowest].priority:
				lowest = i
		if priority < int(voices[lowest].priority):
			return null
		player = voices[lowest].player
		player.stop()
		voices.remove_at(lowest)
	else:
		for candidate in _pool:
			if not candidate.playing:
				player = candidate
				break
	if player == null:
		return null
	player.position = origin + (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size
	player.volume_db = -12
	player.stream = GameAudio.stream(id)
	if id == "vehicle_move":
		var engine := player.stream.duplicate() as AudioStreamWAV
		engine.loop_mode = AudioStreamWAV.LOOP_FORWARD
		engine.loop_end = int(engine.get_length() * engine.mix_rate)
		player.stream = engine
	player.set_meta("audio_generation", int(player.get_meta("audio_generation", 0)) + 1)
	player.play()
	voices.append({"id": id, "cell": cell, "priority": priority, "start": now,
		"player": player, "count": 1})
	GameAudio.cue_played.emit(id, "SFX", player.global_position)
	return player

func _finished(player: AudioStreamPlayer2D) -> void:
	voices = voices.filter(func(e: Dictionary) -> bool: return e.player != player)

func stop_player(player: AudioStreamPlayer2D, generation := -1) -> void:
	if player != null and is_instance_valid(player):
		if generation >= 0 and generation != int(player.get_meta("audio_generation", 0)):
			return
		player.stop()
		_finished(player)

func vehicle_at(player: AudioStreamPlayer2D, generation: int, cell: Vector2i, owner: int) -> AudioStreamPlayer2D:
	if player != null and generation != int(player.get_meta("audio_generation", 0)):
		player = null
	if not cell_visible.call(cell) or suppress:
		stop_player(player, generation)
		return null
	if player == null:
		return cue("vehicle_move", cell, owner)
	player.position = origin + (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size
	for entry in voices:
		if entry.player == player: entry.cell = cell
	return player

func reset() -> void:
	for player in _pool:
		player.stop()
	voices.clear()
	GameAudio.stop_scope(self)
	_turn_key = ""
	_zone_states.clear()

func turn(round_number: int, slot: int, owner: int) -> void:
	var key := "%d:%d:%d" % [round_number, slot, owner]
	if key == _turn_key or suppress:
		return
	_turn_key = key
	if owner >= 0 and owner < MCF.PLAYER_LETTERS.length():
		GameAudio.ui("turn")
		GameAudio.say("turn_" + MCF.PLAYER_LETTERS[owner], self, 10)

func turn_key_from_state(state: GameState) -> void:
	_turn_key = "%d:%d:%d" % [state.turns.round_number, state.turns.active_index, state.active_player()]

func message(text: String) -> void:
	if suppress:
		return
	for pair: Array in RandomEvents.REGISTRY:
		if text.begins_with("⚠ " + str(pair[1]) + " —"):
			_announce(str(pair[0]) + "_warn", true)
			if pair[0] in [RandomEvents.MINEFIELD, RandomEvents.BOUNTY]:
				_announce(str(pair[0]) + "_land", false)
			return
	if text.begins_with("⚠ Wave "):
		_announce("wave_warn", true)
		return
	var landings := {
		"Artillery Barrage hits": "mortar", "Gas Cloud settles": "gas",
		"Fire breaks out": "fire", "EMP Burst over": "emp",
		"A dust storm sweeps": "dust", "Structural collapse at": "collapse",
		"— Reinforcements reach": "reinforce", "— Unknown forces": "army",
	}
	for prefix: String in landings:
		if text.begins_with(prefix):
			_announce(str(landings[prefix]) + "_land", false)
			return
	if text.begins_with("— Wave ") and text.contains(" lands:"):
		_announce("wave_land", false)
	elif text.begins_with("— ") and text.contains("hostile to everyone"):
		_announce("army_land", false)
	elif text.contains("learned AI unavailable"):
		GameAudio.say("fallback", self, 60)
	elif text.begins_with("Round ") and text.contains(" score: "):
		var parts := text.split(" score: ")[1].split(". Points:")[0].split(", ")
		for part: String in parts:
			var contested := part.ends_with(" contested")
			var held := part.contains(" → ")
			var zone := part.split(" → ")[0] if held else part.trim_suffix(" contested").trim_suffix(" empty")
			if _zone_states.get(zone, "") != part:
				if contested: _announce("zone_contested", true)
				elif held: _announce("zone_secured", false)
			_zone_states[zone] = part

func _announce(line: String, warning: bool) -> void:
	GameAudio.ui("event_warn" if warning else "event_land")
	GameAudio.say(line, self, 65 if warning else 50)

func action_result(result: ActionResult, state: GameState) -> void:
	if suppress or (_action_result != null and _action_result.get_ref() == result):
		return
	_action_result = weakref(result)
	var combined := " ".join(result.log_lines).to_lower()
	var id := ""
	if combined.contains("weld"): id = "weld"
	elif combined.contains("disarm") or combined.contains("sweeps"): id = "mine_disarm"
	elif (combined.contains("laid") or combined.contains("plants")) and combined.contains("mine"): id = "mine_lay"
	elif combined.contains("builds") or combined.contains("constructs") or combined.contains("raises a") or combined.contains("dug a trench"): id = "build"
	elif combined.contains("demolishes") or combined.contains("smashes"): id = "structure"
	if id != "": cue(id, result.actor_to, result.actor_owner)
	component_damage(result, state)

func component_damage(result: ActionResult, state: GameState) -> void:
	if suppress or (_component_result != null and _component_result.get_ref() == result):
		return
	_component_result = weakref(result)
	for vid: int in result.visual_hold.get("vehicles", {}):
		var before: Dictionary = result.visual_hold.vehicles[vid]
		var vehicle := state.get_vehicle(vid)
		if vehicle == null:
			continue
		for component: String in before.get("components", {}):
			if int(before.components[component]) > 0 and vehicle.component(component) <= 0:
				var sound := "tracks" if component.begins_with("tracks") else component
				if sound in ["hull", "tracks", "tower", "gun"]:
					cue("vehicle_" + sound, vehicle.origin, vehicle.owner)
