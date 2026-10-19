extends Node
## Client presentation only. No simulation RNG, network messages, or state writes.
signal cue_played(id: String, bus: String, position: Vector2)

const Catalog = preload("res://src/audio/AudioCatalog.gd")
const SETTINGS_PATH := "user://settings.cfg"
const UI_CAP := 4
const VOICE_QUEUE_CAP := 6
## Mix level of each catalog category. The bake already levels every take within its
## category, so one number per category balances the whole game.
const CATEGORY_DB := {"gun": -9.0, "heavy": -5.0, "impact": -13.0, "debris": -9.0, "foley": -12.0,
	"event": -14.0, "radio": -12.0, "ui": -14.0, "engine": -10.0, "fire": -8.0, "ambience": -6.0}
## Per-play variation (pitch fraction, dB) so repeats never sound copied.
const JITTER := {"gun": Vector2(0.04, 1.0), "heavy": Vector2(0.03, 1.0), "impact": Vector2(0.07, 1.5),
	"debris": Vector2(0.05, 1.0), "foley": Vector2(0.08, 2.0)}
## Battle sources go through World (room reverb per environment) or Vacuum (sound carried
## only through the hull and suits); both feed the user's SFX slider.
const WORLD_BUS := "World"
const VACUUM_BUS := "Vacuum"
var master := 0.8
var sfx := 0.8
var voice := 0.7
var muted := false
var turn_voice := true
var _streams := {}
var _ui: Array[AudioStreamPlayer] = []
var _ui_frame := -1
var _ui_ids := {}
var _speaker: AudioStreamPlayer
var _voice_queue: Array[Dictionary] = []
var _voice_scope: WeakRef
var _voice_priority := -1
var _voice_id := ""
var _voice_order := 0
var _rng := RandomNumberGenerator.new() # presentation only, never the game's dice
var _last_variant := {}

func _ready() -> void:
	_rng.randomize()
	for pair: Array in [["SFX", "Master"], ["Voice", "Master"], [WORLD_BUS, "SFX"], [VACUUM_BUS, "SFX"]]:
		if AudioServer.get_bus_index(pair[0]) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, pair[0])
			AudioServer.set_bus_send(AudioServer.bus_count - 1, pair[1])
	if AudioServer.get_bus_effect_count(0) == 0:
		var limiter := AudioEffectLimiter.new()
		limiter.ceiling_db = -1.0
		AudioServer.add_bus_effect(0, limiter)
	var world := AudioServer.get_bus_index(WORLD_BUS)
	if AudioServer.get_bus_effect_count(world) == 0:
		AudioServer.add_bus_effect(world, AudioEffectReverb.new())
		set_room("")
	var vacuum := AudioServer.get_bus_index(VACUUM_BUS)
	if AudioServer.get_bus_effect_count(vacuum) == 0:
		var muffle := AudioEffectLowPassFilter.new()
		muffle.cutoff_hz = 380
		AudioServer.add_bus_effect(vacuum, muffle)
		AudioServer.set_bus_volume_db(vacuum, -9)
	# SAM speaks over the field radio: telephone band plus a little grit, so the
	# synthetic voice reads as a transmission rather than a different quality tier.
	var voice_bus := AudioServer.get_bus_index("Voice")
	if AudioServer.get_bus_effect_count(voice_bus) == 0:
		var low := AudioEffectHighPassFilter.new()
		low.cutoff_hz = 320
		var high := AudioEffectLowPassFilter.new()
		high.cutoff_hz = 3400
		var grit := AudioEffectDistortion.new()
		grit.mode = AudioEffectDistortion.MODE_OVERDRIVE
		grit.drive = 0.18
		grit.post_gain = -2
		for effect: AudioEffect in [low, high, grit]:
			AudioServer.add_bus_effect(voice_bus, effect)
	for i in UI_CAP:
		var player := AudioStreamPlayer.new()
		player.bus = "SFX"
		player.volume_db = -16
		add_child(player)
		_ui.append(player)
	_speaker = AudioStreamPlayer.new()
	_speaker.bus = "Voice"
	_speaker.volume_db = -5
	_speaker.finished.connect(_line_finished)
	add_child(_speaker)
	load_settings()
	get_tree().node_added.connect(_watch_ui)

## One recorded take of an effect (a random one unless variant >= 1; never the same
## take twice running) or a SAM line. Loop takes come back looping.
func stream(id: String, spoken := false, variant := 0) -> AudioStream:
	var path := "res://audio/voice/%s.wav" % id
	if not spoken:
		var count := int(Catalog.SFX.get(id, {}).get("n", 0))
		if count <= 0:
			push_error("Unknown sound effect: " + id)
			return null
		if variant <= 0:
			variant = _rng.randi_range(1, count)
			if count > 1 and variant == int(_last_variant.get(id, 0)):
				variant = variant % count + 1
			_last_variant[id] = variant
		path = "res://audio/sfx/%s_%d.ogg" % [id, mini(variant, count)]
	if not _streams.has(path):
		if not ResourceLoader.exists(path):
			push_error("Missing audio asset: " + path)
			return null
		var loaded: AudioStream = load(path)
		if loaded is AudioStreamOggVorbis and bool(Catalog.SFX.get(id, {}).get("loop", false)):
			loaded.loop = true
		_streams[path] = loaded
	return _streams[path]

static func category(id: String) -> String:
	return str(Catalog.SFX.get(id, {}).get("cat", "ui"))

## Base mix level of an effect, before any per-play variation.
static func level_db(id: String) -> float:
	return float(CATEGORY_DB.get(category(id), -12.0))

## Start player on a fresh take of id at its category level, with a little random
## pitch/level so a burst or a walk never repeats one sample verbatim.
func prime(player: Node, id: String, extra_db := 0.0) -> bool:
	var take := stream(id)
	if take == null:
		return false
	var spread: Vector2 = JITTER.get(category(id), Vector2.ZERO)
	player.set("stream", take)
	player.set("pitch_scale", 1.0 + _rng.randf_range(-spread.x, spread.x))
	player.set("volume_db", level_db(id) + extra_db + _rng.randf_range(-spread.y, spread.y))
	return true

## Room acoustics of the World bus for a map environment ("" = open ground).
func set_room(env: String) -> void:
	var world := AudioServer.get_bus_index(WORLD_BUS)
	if world < 0 or AudioServer.get_bus_effect_count(world) == 0:
		return
	var reverb := AudioServer.get_bus_effect(world, 0) as AudioEffectReverb
	# [room size, damping, wet, predelay ms]: steel corridors ring, concrete is dense,
	# streets give a short slap and an open field almost nothing.
	var room: Array = {"station": [0.42, 0.35, 0.16, 18.0], "bunker": [0.55, 0.6, 0.2, 25.0],
		"asteroid": [0.6, 0.45, 0.18, 30.0], "town": [0.3, 0.7, 0.07, 40.0]}.get(env, [0.2, 0.8, 0.03, 60.0])
	reverb.room_size = room[0]
	reverb.damping = room[1]
	reverb.wet = room[2]
	reverb.predelay_msec = room[3]
	reverb.dry = 1.0
	reverb.spread = 0.6

func stop_all() -> void:
	_voice_queue.clear()
	_voice_id = ""
	if _speaker != null:
		_speaker.stop()
		_speaker.stream = null
	for player in _ui:
		player.stop()
		player.stream = null

func _exit_tree() -> void:
	stop_all()
	_streams.clear()

func audible(bus: String) -> bool:
	return not muted and master > 0 and (voice > 0 if bus == "Voice" else sfx > 0)

func load_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	master = clampf(float(cfg.get_value("audio", "master", 0.8)), 0, 1)
	sfx = clampf(float(cfg.get_value("audio", "sfx", 0.8)), 0, 1)
	voice = clampf(float(cfg.get_value("audio", "voice", 0.7)), 0, 1)
	muted = bool(cfg.get_value("audio", "mute", false))
	turn_voice = bool(cfg.get_value("audio", "turn_voice", true))
	_apply_buses()

func set_levels(p_master: float, p_sfx: float, p_voice: float, p_muted: bool, p_turn_voice := true) -> void:
	master = clampf(p_master, 0, 1)
	sfx = clampf(p_sfx, 0, 1)
	voice = clampf(p_voice, 0, 1)
	muted = p_muted
	turn_voice = p_turn_voice
	_apply_buses()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # Preserve Interface and Keybinds sections.
	for key: String in ["master", "sfx", "voice", "mute", "turn_voice"]:
		cfg.set_value("audio", key, get(key if key != "mute" else "muted"))
	cfg.save(SETTINGS_PATH)

func _apply_buses() -> void:
	for pair: Array in [["Master", master], ["SFX", sfx], ["Voice", voice]]:
		var index := AudioServer.get_bus_index(pair[0])
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(0.00001, pair[1])))
		AudioServer.set_bus_mute(index, bool(pair[1] <= 0) or (pair[0] == "Master" and muted))
	if not audible("Voice") and _speaker != null:
		_speaker.stop()
		_voice_queue.clear()
		_voice_id = ""
	elif not turn_voice and _speaker != null:
		_voice_queue = _voice_queue.filter(func(e: Dictionary) -> bool: return not str(e.id).begins_with("turn_"))
		if _voice_id.begins_with("turn_"):
			_speaker.stop()
			_voice_id = ""

func ui(id := "ui_click", extra_db := 0.0) -> void:
	if not audible("SFX"):
		return
	var frame := Engine.get_process_frames()
	if frame != _ui_frame:
		_ui_ids.clear()
		_ui_frame = frame
	if _ui_ids.has(id):
		return
	_ui_ids[id] = true
	var player := _ui[0]
	for candidate in _ui:
		if not candidate.playing:
			player = candidate
			break
	if not prime(player, id, extra_db):
		return
	player.play()
	cue_played.emit(id, "SFX", Vector2.INF)

func say(id: String, scope: Node, priority := 50) -> void:
	if not Catalog.VOICE.has(id) or not audible("Voice") or not is_instance_valid(scope):
		return
	if priority >= 100:
		_voice_queue.clear()
	if id.begins_with("turn_"):
		if not turn_voice:
			return
		_voice_queue = _voice_queue.filter(func(e: Dictionary) -> bool: return not str(e.id).begins_with("turn_"))
		if _voice_id.begins_with("turn_") and _voice_id != id:
			_speaker.stop()
	if _voice_id == id and _speaker.playing:
		return
	for entry in _voice_queue:
		if entry.id == id and entry.scope.get_ref() == scope:
			return
	_voice_order += 1
	_voice_queue.append({"id": id, "scope": weakref(scope), "priority": priority, "order": _voice_order})
	_voice_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.order < b.order if a.priority == b.priority else a.priority > b.priority)
	if _voice_queue.size() > VOICE_QUEUE_CAP:
		_voice_queue.resize(VOICE_QUEUE_CAP)
	if _speaker.playing and priority > _voice_priority:
		_speaker.stop() # Urgent warnings replace a low-priority turn handoff.
	# Start at the next process boundary: a same-frame burst should queue/collapse
	# before creating playback handles, rather than repeatedly start/stop the mixer.

func stop_scope(scope: Node) -> void:
	_voice_queue = _voice_queue.filter(func(e: Dictionary) -> bool: return e.scope.get_ref() != scope)
	if _voice_scope != null and _voice_scope.get_ref() == scope:
		_speaker.stop()
		_voice_id = ""

func _process(_delta: float) -> void:
	if _speaker == null:
		return
	if _speaker.playing and (_voice_scope == null or not is_instance_valid(_voice_scope.get_ref()) \
			or not _voice_scope.get_ref().is_inside_tree()):
		_speaker.stop()
	if _speaker.playing or not audible("Voice"):
		return
	_voice_id = ""
	while not _voice_queue.is_empty():
		var entry: Dictionary = _voice_queue.pop_front()
		var scope: Node = entry.scope.get_ref()
		if not is_instance_valid(scope) or not scope.is_inside_tree():
			continue
		_voice_scope = entry.scope
		_voice_priority = entry.priority
		_voice_id = entry.id
		_speaker.stream = stream(entry.id, true)
		_speaker.play()
		ui("radio_in") # keying the handset
		cue_played.emit(entry.id, "Voice", Vector2.INF)
		break

func _line_finished() -> void:
	if _voice_queue.is_empty():
		ui("radio_out") # end of transmission

func _watch_ui(node: Node) -> void:
	if node is BaseButton:
		node.pressed.connect(_button_pressed.bind(weakref(node)))
	elif node is TabContainer:
		node.tab_changed.connect(func(_index: int) -> void:
			if node.get_tab_bar().has_focus(): ui("ui_nav"))

func _button_pressed(button_ref: WeakRef) -> void:
	var button: BaseButton = button_ref.get_ref()
	if button == null or button.get_meta("audio_silent", false):
		return
	ui("ui_end" if button is Button and button.text.begins_with("End Turn") else "ui_click")
