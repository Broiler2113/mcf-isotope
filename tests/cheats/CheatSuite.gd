extends "res://tests/SuiteBase.gd"

func fresh() -> GameActionResolver:
	GameConfig.cheats_enabled = true
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	var state := GameState.new(24, 20, 132)
	state.roster.slots[0].cheats_allowed = true
	state.roster.slots[1].cheats_allowed = true
	state.roster.slots[0].peer_id = 1
	state.roster.slots[1].peer_id = 2
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	state.turns.initiative_rolled = true
	state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(2, 2), 0)
	state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(21, 17), 1)
	var resolver := GameActionResolver.new(state)
	resolver.fog_enabled = false
	return resolver

func command(r: GameActionResolver, line: String, side := 0) -> ActionResult:
	var parsed := CheatCommands.parse(line, r.state, side)
	if parsed.has("error"):
		ck(false, "parse %s: %s" % [line, parsed.error])
		return ActionResult.fail(parsed.error)
	var wire := IntentCodec.encode(CheatIntent.new(parsed.op, parsed.args, side))
	var decoded := IntentCodec.decode(JSON.parse_string(JSON.stringify(wire)))
	ck(decoded is CheatIntent, "typed JSON roundtrip: " + line)
	var result := r.resolve(decoded)
	ck(result.ok, "%s: %s" % [line, result.reason])
	return result

func rejected(r: GameActionResolver, line: String) -> void:
	var before := JSON.stringify(StateCodec.encode(r.state))
	var dice := r.state.dice.checkpoint()
	var parsed := CheatCommands.parse(line, r.state, 0)
	if not parsed.has("error"):
		var result := r.resolve(CheatIntent.new(parsed.op, parsed.args, 0))
		ck(not result.ok, "reject " + line)
	ck(JSON.stringify(StateCodec.encode(r.state)) == before, "rejection does not mutate state: " + line)
	ck(r.state.dice.checkpoint() == dice, "rejection does not consume dice: " + line)
