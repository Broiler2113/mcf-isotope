class_name BattleAudio
extends Node2D
## Receives cosmetic lifecycle cues, then applies THIS viewer's information boundary.
const WORLD_CAP := 12
const MERGE_MS := 40
const FIRE_SCAN_S := 0.75
## Map material -> bullet impact and footstep takes.
const HIT := {"metal": "hit_metal", "wood": "hit_wood", "glass": "hit_glass", "dirt": "hit_dirt",
	"grass": "hit_dirt", "soft": "hit_dirt", "stone": "hit_stone"}
const STEP := {"metal": "step_metal", "wood": "step_wood", "soft": "step_carpet", "grass": "step_grass",
	"dirt": "step_dirt", "stone": "step_concrete", "glass": "step_concrete"}
## Random-event lines that also get a sound of the event itself: [effect, dB offset].
const EVENT_SOUND := {"mortar_warn": ["mortar_fire", -14.0], "mortar_land": ["incoming", 0.0],
	"gas_land": ["gas", 0.0], "emp_land": ["emp", 0.0], "dust_land": ["dust", 0.0],
	"collapse_land": ["collapse", -4.0], "fire_land": ["flame", -8.0]}
var ceiling := WORLD_CAP
var cell_visible: Callable
var own_cell: Callable
var viewer: Callable
## The live GameState, read-only: environment, surfaces, vacuum and fires. Optional.
var world: Callable
var enabled := true
var origin := Vector2(40, 40)
var cell_size := 40.0
var voices: Array[Dictionary] = []
var _pool: Array[AudioStreamPlayer2D] = []
var _ambient: AudioStreamPlayer
var _fire: AudioStreamPlayer2D
var _fire_clock := 0.0
var _env := ""
var _component_result: WeakRef
var _action_result: WeakRef
var _turn_key := ""
var _zone_states := {}
var suppress := false
## Seconds between rounds of one volley, by gun (FxDecals.volley_requested).
const VOLLEY_GAP := {"rifle": 0.13, "mg": 0.085, "heavy_mg": 0.11, "shotgun": 0.45, "sniper": 1.0}
var _volley_gen := 0

func _ready() -> void:
	for i in WORLD_CAP:
		var player := AudioStreamPlayer2D.new()
		player.bus = GameAudio.WORLD_BUS
		player.max_distance = 1400
		player.panning_strength = 0.8
		add_child(player)
		player.finished.connect(_finished.bind(player))
		_pool.append(player)
	_fire = AudioStreamPlayer2D.new()
	_fire.bus = GameAudio.WORLD_BUS
	_fire.max_distance = 1400
	add_child(_fire)
	_ambient = AudioStreamPlayer.new()
	_ambient.bus = "SFX"
	add_child(_ambient)
	_set_env(_current_env())

func _exit_tree() -> void:
	GameAudio.stop_scope(self)
	for player in _pool:
		player.stop()
		player.stream = null
	voices.clear()
	_fire.stop()
	_fire.stream = null
	_ambient.stop()
	_ambient.stream = null

func _process(delta: float) -> void:
	for entry in voices.duplicate():
		if suppress or (cell_visible.is_valid() and not cell_visible.call(entry.cell)):
			stop_player(entry.player)
	if _current_env() != _env:
		_set_env(_current_env())
	_fire_clock -= delta
	if _fire_clock <= 0:
		_fire_clock = FIRE_SCAN_S
		_update_fire()

func _state() -> GameState:
	return world.call() if world.is_valid() else null

func _current_env() -> String:
	var state := _state()
	return state.env if state != null and state.env != "" else "town"

## Ambience bed and room acoustics follow the map's environment.
func _set_env(env: String) -> void:
	_env = env
	GameAudio.set_room(env)
	var id := "amb_" + env
	if not GameAudio.Catalog.SFX.has(id):
		id = "amb_town"
	_ambient.stream = GameAudio.stream(id)
	_ambient.volume_db = GameAudio.level_db(id)
	_ambient.play()

func cue(id: String, cell: Vector2i, owner := -1) -> AudioStreamPlayer2D:
	if not enabled or suppress or not GameAudio.audible("SFX") \
			or not cell_visible.is_valid() or not cell_visible.call(cell):
		return null
	if id == "bullet_hit":
		id = _impact(cell)
	var minor := id.begins_with("step_") or id.begins_with("door_")
	var own: bool = (viewer.is_valid() and owner >= 0 and owner == int(viewer.call())) \
			or (own_cell.is_valid() and own_cell.call(cell))
	# Steps and doors never crowd out gunfire, even the viewer's own.
	var priority := (4 if minor else 20) + ((10 if minor else 50) if own else 0)
	if id in ["explosion", "vehicle_hull"]:
		priority += 10
	if id in ["structure", "glass"]:
		priority += 9 if id == "glass" else 8
	var now := Time.get_ticks_msec()
	var merge_radius_squared := 16 if id in ["structure", "glass"] else 2
	for entry in voices:
		if entry.id == id and now - int(entry.start) <= MERGE_MS \
				and Vector2i(entry.cell - cell).length_squared() <= merge_radius_squared:
			entry.count = mini(4, int(entry.count) + 1)
			entry.priority = maxi(priority, entry.priority)
			entry.player.volume_db = float(entry.db) + minf(3.0, 10.0 * log(float(entry.count)) / log(10.0))
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
	# In vacuum only what reaches you through hull and suit is left: low and dull, and
	# quieter still for the other side's business.
	var vacuum := _vacuum(cell)
	player.bus = GameAudio.VACUUM_BUS if vacuum else GameAudio.WORLD_BUS
	if not GameAudio.prime(player, id, -8.0 if vacuum and not own else 0.0):
		return null
	player.position = origin + (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size
	player.set_meta("audio_generation", int(player.get_meta("audio_generation", 0)) + 1)
	player.play()
	voices.append({"id": id, "cell": cell, "priority": priority, "start": now,
		"player": player, "count": 1, "db": player.volume_db})
	GameAudio.cue_played.emit(id, "SFX", player.global_position)
	return player

## The rest of a volley: one shot per bullet, spaced by the gun's cadence. A reset (undo,
## seek, new match) drops the rounds still waiting.
func volley(id: String, cell: Vector2i, owner: int, count: int) -> void:
	var gen := _volley_gen
	var gap: float = VOLLEY_GAP.get(id, 0.12)
	for i in range(1, count + 1):
		get_tree().create_timer(gap * i).timeout.connect(func() -> void:
			if gen == _volley_gen and is_inside_tree():
				cue(id, cell, owner))

func _finished(player: AudioStreamPlayer2D) -> void:
	voices = voices.filter(func(e: Dictionary) -> bool: return e.player != player)

func stop_player(player: AudioStreamPlayer2D, generation := -1) -> void:
	if player != null and is_instance_valid(player):
		if generation >= 0 and generation != int(player.get_meta("audio_generation", 0)):
			return
		player.stop()
		_finished(player)

## Keep a moving vehicle's (or drone's) engine loop on it, or start one.
func vehicle_at(player: AudioStreamPlayer2D, generation: int, cell: Vector2i, owner: int,
		id := "vehicle_move") -> AudioStreamPlayer2D:
	if player != null and generation != int(player.get_meta("audio_generation", 0)):
		player = null
	if not cell_visible.call(cell) or suppress:
		stop_player(player, generation)
		return null
	if player == null:
		return cue(id, cell, owner)
	player.position = origin + (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size
	for entry in voices:
		if entry.player == player: entry.cell = cell
	return player

## A soldier's step from one cell to the next: a footstep on that floor, and airlock
## doors that open as it comes within reach or shut behind it.
func step(unit: UnitInstance, from: Vector2i, to: Vector2i) -> void:
	var state := _state()
	if suppress or unit == null or state == null or not state.grid.in_bounds(to):
		return
	if unit.is_drone:
		return # drones neither step nor open airlocks
	cue(STEP.get(_material(state, to), "step_concrete"), to, unit.owner)
	for door: Vector2i in _airlocks_near(state, to):
		if Combat.distance(from, door) > MCF.AIRLOCK_OPEN_RADIUS and not _others_near(state, door, unit):
			cue("door_open", door, unit.owner)
	for door: Vector2i in _airlocks_near(state, from):
		if Combat.distance(to, door) > MCF.AIRLOCK_OPEN_RADIUS and not _others_near(state, door, unit):
			cue("door_close", door, unit.owner)

func _airlocks_near(state: GameState, at: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var r := MCF.AIRLOCK_OPEN_RADIUS
	for y in range(at.y - r, at.y + r + 1):
		for x in range(at.x - r, at.x + r + 1):
			var c := Vector2i(x, y)
			if state.grid.in_bounds(c):
				var cell := state.grid.cell_fast(x, y)
				if cell.feature_id == MCF.FEATURE_AIRLOCK and not cell.airlock_welded:
					out.append(c)
	return out

func _others_near(state: GameState, door: Vector2i, walker: UnitInstance) -> bool:
	var r := MCF.AIRLOCK_OPEN_RADIUS
	for y in range(door.y - r, door.y + r + 1):
		for x in range(door.x - r, door.x + r + 1):
			if state.grid.in_bounds(Vector2i(x, y)):
				var occ: UnitInstance = state.grid.cell_fast(x, y).occupant
				if occ != null and occ != walker and occ.is_alive() and not occ.is_drone:
					return true
	return false

## What a bullet hits at the end of its tracer, read from the settled state: a body,
## a Shield Bearer's plate, a hull, else the wall or floor material there.
func _impact(at: Vector2i) -> String:
	var state := _state()
	if state == null or not state.grid.in_bounds(at):
		return "hit_stone"
	var cell := state.grid.cell(at)
	if cell.vehicle_id >= 0:
		return "hit_metal"
	var unit := cell.occupant
	if unit != null and unit.is_alive() and unit.stats.special_ability_id == MCF.ABILITY_SHIELD_BEARER:
		return "shield_block"
	if (unit == null or not unit.is_alive()) and (cell.corpse_count > 0 or cell.feature_id == MCF.FEATURE_CORPSE_WALL):
		return "hit_flesh"
	return HIT.get(_material(state, at), "hit_stone")

## Surface material of a cell for sound: its feature, else its floor, else the
## environment's default ground.
func _material(state: GameState, at: Vector2i) -> String:
	var cell := state.grid.cell(at)
	var look := state.grid.look_at(at.x, at.y)
	var fid := cell.feature_id
	if Furniture.is_furniture(fid):
		return {"metal": "metal", "wood": "wood", "plastic": "wood"}.get(str(Furniture.def_of(fid).get("mat", "")), "soft")
	match fid:
		MCF.FEATURE_GLASS, MCF.FEATURE_ARMOR_GLASS:
			return "glass"
		MCF.FEATURE_WOOD_WALL:
			return "wood"
		MCF.FEATURE_ARMOR_WALL, MCF.FEATURE_AIRLOCK, MCF.FEATURE_LDF, MCF.FEATURE_DPMG, \
				MCF.FEATURE_DRONE_STATION, MCF.FEATURE_HEDGEHOG:
			return "metal"
		MCF.FEATURE_SANDBAGS, MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS, \
				MCF.FEATURE_DIRT_PILE, MCF.FEATURE_TRENCH, MCF.FEATURE_SOIL:
			return "dirt"
		MCF.FEATURE_WALL, MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN:
			if look >= MCF.WALL_LOOK_BASE:
				return "metal" if look == MCF.wall_look(MCF.WALL_LOOK_STATION) else "stone"
			return "metal" if state.env in ["station", "asteroid"] else "stone"
	match look:
		MCF.Look.WOOD, MCF.Look.PARQUET:
			return "wood"
		MCF.Look.CARPET_RED, MCF.Look.CARPET_BLUE:
			return "soft"
		MCF.Look.PLATE, MCF.Look.GRATE, MCF.Look.GRILL, MCF.Look.SOLAR:
			return "metal"
		MCF.Look.TILE, MCF.Look.CHECKER, MCF.Look.LINO:
			return "stone"
		MCF.Look.GRASS:
			return "grass"
		MCF.Look.DIRT:
			return "dirt"
	if cell.floor_type == MCF.FLOOR_GRASS:
		return "grass"
	return {"station": "metal", "asteroid": "metal", "field": "dirt"}.get(state.env, "stone")

func _vacuum(at: Vector2i) -> bool:
	var state := _state()
	return state != null and state.grid.in_bounds(at) and FxDecals.space_in(state, at)

## One crackling loop for the fires this viewer can see, centred on them and louder
## the more cells burn. Scans only while something is burning anywhere.
func _update_fire() -> void:
	var state := _state()
	var count := 0
	var sum := Vector2.ZERO
	if state != null and GridCell.burning > 0 and enabled and not suppress \
			and GameAudio.audible("SFX") and cell_visible.is_valid():
		for cell: GridCell in state.grid.cells_flat():
			if cell.on_fire and cell_visible.call(cell.coord):
				count += 1
				sum += Vector2(cell.coord)
	if count == 0:
		_fire.stop()
		return
	_fire.position = origin + (sum / count + Vector2(0.5, 0.5)) * cell_size
	_fire.volume_db = GameAudio.level_db("fire_loop") + minf(6.0, 3.0 * log(float(count)) / log(2.0))
	if not _fire.playing:
		_fire.stream = GameAudio.stream("fire_loop")
		_fire.play()

func reset() -> void:
	_volley_gen += 1
	for player in _pool:
		player.stop()
	voices.clear()
	_fire.stop()
	GameAudio.stop_scope(self)
	_turn_key = ""
	_zone_states.clear()

func turn(round_number: int, slot: int, owner: int) -> void:
	var key := "%d:%d:%d" % [round_number, slot, owner]
	if key == _turn_key or suppress:
		return
	_turn_key = key
	if owner >= 0 and owner < MCF.PLAYER_LETTERS.length():
		# A spoken handoff keys the radio itself; the bare click is for when nobody speaks.
		if not (GameAudio.turn_voice and GameAudio.audible("Voice")):
			GameAudio.ui("turn")
		GameAudio.say("turn_" + MCF.PLAYER_LETTERS[owner], self, 10)

func turn_key_from_state(state: GameState) -> void:
	_turn_key = "%d:%d:%d" % [state.turns.round_number, state.turns.active_index, state.active_player()]

func message(text: String) -> void:
	text = text.replace(char(0x2014), "-")
	if suppress:
		return
	for pair: Array in RandomEvents.REGISTRY:
		if text.begins_with("⚠ " + str(pair[1]) + " -"):
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
		"- Reinforcements reach": "reinforce", "- Unknown forces": "army",
	}
	for prefix: String in landings:
		if text.begins_with(prefix):
			_announce(str(landings[prefix]) + "_land", false)
			return
	if text.begins_with("- Raiders ") and (text.contains(" land on the ") or text.contains(" land at (")):
		_announce("army_land", false)
		return
	if text.begins_with("- Wave ") and text.contains(" lands:"):
		_announce("wave_land", false)
	elif text.begins_with("- ") and text.contains("hostile to everyone"):
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
	if EVENT_SOUND.has(line):
		GameAudio.ui(EVENT_SOUND[line][0], EVENT_SOUND[line][1])
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
	elif combined.contains("dug a trench"): id = "dig"
	elif combined.contains("builds") or combined.contains("constructs") or combined.contains("raises a"): id = "build"
	elif combined.contains("with its shield") or combined.contains("shield-pushes"): id = "shield_block"
	elif combined.contains("demolishes") or combined.contains("smashes"): id = "structure"
	elif combined.contains("picked up") or result.dice_events.any(func(e: Dictionary) -> bool: return e.get("kind") == "opposed"):
		id = "grab"
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
