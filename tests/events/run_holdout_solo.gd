extends SceneTree
## Holdout alone (2026-10-18 owner request): one defender, no second player or AI ally.
## Drives the real Lobby → Placement → Main scenes, then plays rounds until a wave lands.

var fails: PackedStringArray = []
var _frame := 0
var _stage := 0
var _lobby: Node = null

func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails.append(message)

func _initialize() -> void:
	NetHandoff.session = null
	GameConfig.roster = null
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_lobby = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(_lobby)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 3:
		return false
	match _stage:
		0: _lobby_checks()
		1: _placement()
		2: _battle()
		3: _waves_play()
		_: return _finish()
	return false

func _pick_mode(kind: int) -> void:
	_lobby._mode_opt.select(kind)
	_lobby._mode_opt.item_selected.emit(kind)

func _lobby_checks() -> void:
	var roster: Roster = _lobby.roster
	ck(roster.slots.size() == 2, "a solo lobby opens with two slots")
	_lobby._on_remove_slot(1)
	ck(roster.slots.size() == 2, "Annihilation still needs two slots")
	_pick_mode(MatchMode.Kind.HOLDOUT)
	_lobby._on_remove_slot(1)
	ck(roster.slots.size() == 1, "Holdout lets the second slot go")
	_pick_mode(MatchMode.Kind.ANNIHILATION)
	ck(roster.slots.size() == 2, "leaving Holdout brings the opponent slot back")
	_pick_mode(MatchMode.Kind.HOLDOUT)
	_lobby._on_remove_slot(1)
	ck(roster.slots.size() == 1 and roster.slots[0].kind == Roster.SlotKind.HUMAN, "one human defender is left")
	_lobby._on_start()
	_stage = 1
	_frame = 0

func _placement() -> void:
	var p: Node = current_scene
	if p == null or p.name != "Placement":
		ck(false, "Start opens deployment (scene: %s, status: %s)" % [p.name if p else "none", _lobby._status.text if is_instance_valid(_lobby) else "?"])
		_stage = 9
		return
	ck(p._sides() == [0], "only the defender deploys (sides %s)" % [p._sides()])
	# Five defenders, so two small waves are unlikely to end the match before both have played.
	var spots: Array[Vector2i] = []
	for y in p.map.height:
		for x in p.map.width:
			if spots.size() < 5 and (x + y) % 3 == 0 and p._in_zone(Vector2i(x, y), 0) and p._cell_placeable(Vector2i(x, y)):
				spots.append(Vector2i(x, y))
	ck(not spots.is_empty(), "the defender has a deployment zone")
	for spot in spots:
		p.placed.append({"coord": spot, "stats_id": "heavy_infantry", "owner": 0})
	p._on_flow()
	_stage = 2
	_frame = 0

func _battle() -> void:
	var m: Node = current_scene
	if m == null or m.name != "Main" or m.state == null:
		if _frame < 30: return
		ck(false, "deployment starts the battle")
		_stage = 9
		return
	var r: GameActionResolver = m.resolver
	ck(r.mode.is_holdout() and r.state.roster.player_ids().size() == 2, "battle has the defender and the waves (sides %s)" % [r.state.roster.player_ids()])
	ck(not r.match_outcome()["over"], "a lone defender is not an instant win or loss")
	for _i in 12:
		if r.mode.wave >= 1: break
		r.resolve(EndTurnIntent.new())
	ck(r.mode.wave >= 1 and r.wave_fighters_left() > 0, "a wave lands against the lone defender (wave %d)" % r.mode.wave)
	# A second wave, so two wave turns (same AI side) follow each other in the order.
	r.mode.pending_wave = {"edge": 2, "along": 8}
	r._land_wave(ActionResult.success([]))
	for u: UnitInstance in r.state.all_units():
		if u.owner == r.mode.wave_side: _start[u.id] = u.coord
	_round0 = r.state.turns.round_number
	m._paused = false
	root.get_node("Ui").autoroll_dice = true   # nobody is here to click Roll on defence rolls (not saved)
	m._refresh_status()
	m._kick_if_ai()   # the turns above went straight through the resolver
	_deadline = Time.get_ticks_msec() + 90000   # AI steps run on real-time timers (AI speed)
	_stage = 3
	_frame = 0

var _start := {}
var _round0 := 0
var _slots_seen := {}
var _deadline := 0
var _acted := {}
func _waves_play() -> void:
	var m: Node = current_scene
	var r: GameActionResolver = m.resolver
	var now := r.state.turns.active_slot()
	_slots_seen[now] = true
	# A wave acted on its own turn: spent AP, moved or fell while its slot was up.
	for id: int in _start:
		var u := r.state.get_unit(id)
		if u != null and now == MCF.wave_slot(u.neutral_group) \
				and (u.remaining_ap < u.max_ap() or u.coord != _start[id] or not u.is_alive()):
			_acted[u.neutral_group] = true
	if r.state.active_player() == 0 and not m._animating:
		m._on_intent_ready(EndTurnIntent.new(0))
	if r.state.turns.round_number < _round0 + 2 and Time.get_ticks_msec() < _deadline:
		return
	var w1 := MCF.wave_slot(1)
	var w2 := MCF.wave_slot(2)
	# The match is random (lobby map and dice), and two waves can wipe five defenders who only
	# end their turns: that is a fair result once both waves have played. Ending before
	# that is the failure this guards against.
	ck(not m._match_over or (_acted.has(1) and _acted.has(2)),
			"the match lasts until both waves have played (over: %s, acted %s)" % [m._match_over, _acted.keys()])
	ck(_slots_seen.has(w1) and _slots_seen.has(w2), "the battle plays Wave I and Wave II as their own turns (%s)" % [_slots_seen.keys()])
	ck(_acted.has(1) and _acted.has(2), "the waves' AI plays each wave on its own turn (%s)" % [_acted.keys()])
	_stage = 9

func _finish() -> bool:
	print("holdout solo: %d failure(s)" % fails.size())
	quit(0 if fails.is_empty() else 1)
	return true
