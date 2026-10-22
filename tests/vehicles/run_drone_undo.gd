extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.roster = Roster.default_duel(false)
	for casualty in [false, true]:
		_check(casualty)

func _check(casualty: bool) -> void:
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(3, 3), "drone_operator", 0)
	map.set_spawn(Vector2i(19, 13), "light_infantry", 1)
	if casualty: map.set_spawn(Vector2i(10, 7), "light_infantry", 1)
	map.set_cell(Vector2i(10, 6), 0, 2.0, false, MCF.FEATURE_WALL)
	var state := map.build_state(21)
	var peer := map.build_state(21)
	for s: GameState in [state, peer]:
		s.turns.round_order.assign([0, 1])
		s.turns.active_index = 0
	var resolver := GameActionResolver.new(state)
	var other := GameActionResolver.new(peer)
	resolver.fog_mode = MCF.Fog.OFF
	other.fog_mode = MCF.Fog.OFF
	var op := state.grid.cell(Vector2i(3, 3)).occupant
	var deploy := UseItemIntent.new(op.id, Vector2i(4, 3))
	_wire(resolver, other, deploy)
	var drone := resolver.active_drone_of(op)
	ck(drone != null, "operator launches a drone")
	if drone == null: return
	_wire(resolver, other, DroneMoveIntent.new(drone.id, Vector2i(9, 7)))
	var before := _board(state)
	_wire(resolver, other, DroneDetonateIntent.new(drone.id))
	if casualty:
		var victim := state.grid.cell(Vector2i(10, 7)).occupant
		ck(victim == null or not victim.is_alive(), "the blast kills its nearby victim")
		ck(not resolver.can_undo() and not other.can_undo(), "a lethal detonation clears undo on both peers")
	else:
		ck(state.grid.cell(Vector2i(10, 6)).feature_id == "", "a nonlethal blast still destroys terrain")
		ck(resolver.can_undo() and other.can_undo(), "a nonlethal detonation is undoable on both peers")
		var after := state.digest_hash()
		_wire(resolver, other, UndoIntent.new(0))
		ck(_board(state) == before and drone.is_alive(), "undo restores the drone and terrain exactly")
		_wire(resolver, other, RedoIntent.new(0))
		ck(state.digest_hash() == after, "redo restores the same explosion")

func _wire(resolver: GameActionResolver, peer: GameActionResolver, intent: Intent) -> void:
	resolver.state.dice.begin_record()
	var result := resolver.resolve(intent)
	peer.state.dice.feed_scripted(resolver.state.dice.take_log())
	var received := peer.resolve(IntentCodec.decode(IntentCodec.encode(intent)))
	ck(result.ok and received.ok, "%s resolves on both peers: %s / %s" % [intent.get_script().resource_path, result.reason, received.reason])
	ck(resolver.state.digest_hash() == peer.state.digest_hash(), "the drone action agrees across the wire")
	ck(_board(resolver.state) == _board(peer.state), "terrain and equipment also agree across the wire")

func _board(state: GameState) -> String:
	var encoded := StateCodec.encode(state)
	# Event identifiers and the consumed dice stream remain monotonic across undo.
	encoded.erase("fx_seq")
	encoded.erase("dice")
	return JSON.stringify(encoded)
