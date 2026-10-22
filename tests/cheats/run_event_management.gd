extends "res://tests/cheats/CheatSuite.gd"

func run() -> void:
	var r := fresh()
	r.state.env = "field"
	ck(CheatEventModel.validate("gas", {"w": 3}, r).is_empty(), "partial event properties do not require an unrelated height")
	r.mode.bounty_unit = 9999
	ck(CheatEventModel.at_cell(r, Vector2i(1, 1)).is_empty(), "click inspection tolerates a removed bounty target")
	r.mode.bounty_unit = -1
	var recorder := ReplayRecorder.new()
	recorder.begin(r.state, r)
	recorder.capture_opening()
	r.replay_recorder = recorder
	command(r, "event queue gas 8 8")
	command(r, "event queue mortar 18 15")
	var refs := CheatEventModel.entries(r)
	ck(refs.size() == 2 and refs[0].ref != refs[1].ref, "stable pending references")
	var second: String = refs[1].ref
	command(r, "event remove " + refs[0].ref)
	ck(CheatEventModel.find(r, second).event == "mortar", "removing earlier entry does not renumber others")
	command(r, "event set %s w 2" % second)
	ck(r.random_events.pending[0].params.w == 2, "edit supported area property")
	var before := r.random_events.snapshot()
	rejected(r, "event set %s rounds 10" % second)
	ck(r.random_events.snapshot() == before, "unsupported property does not mutate event")
	command(r, "event trigger dust")
	ck(r.random_events.dust_left == r.DUST_ROUNDS and r.random_events.pending.size() == 1, "trigger applies immediately without landing unrelated warnings")
	command(r, "event set dust rounds 8")
	ck(r.random_events.dust_left == 8, "edit real duration")
	command(r, "event remove dust")
	command(r, "event place gas 7 7 '{\"w\":3,\"h\":4,\"rounds\":9}'")
	ck(r.random_events.clouds.size() == 1 and r.random_events.clouds[0].left == 9, "place uses chosen area and duration")
	var cloud: Dictionary = r.random_events.clouds[0]
	var ref := "gas:%d" % cloud.uid
	ck(CheatEventModel.at_cell(r, Vector2i(cloud.x, cloud.y)).has(ref), "click selection finds active cloud")
	command(r, "event update %s '{\"x\":10,\"y\":9,\"w\":4,\"h\":5,\"rounds\":7}'" % ref)
	ck(cloud.x == 10 and cloud.left == 7 and r.state.grid.cell(Vector2i(10, 9)).gas, "atomic location/area/duration update refreshes gas")
	before = r.random_events.snapshot()
	rejected(r, "event update %s '{\"x\":23,\"w\":4}'" % ref)
	ck(r.random_events.snapshot() == before, "invalid area leaves active event intact")
	command(r, "event automatic on")
	command(r, "event interval 5")
	command(r, "event guaranteed on")
	command(r, "event enabled mortar off")
	ck(r.random_events.enabled and r.random_events.interval == 5 and r.random_events.mandatory and r.random_events.weights.mortar == 0, "existing scheduler controls")
	var rules: Dictionary = JSON.parse_string(JSON.stringify(StateCodec.encode_rules(r)))
	var restored := GameActionResolver.new(StateCodec.decode(StateCodec.encode(r.state)))
	StateCodec.apply_rules(restored, rules)
	ck(not CheatEventModel.find(restored, ref).is_empty(), "references persist across save/load")
	var playback := ReplayPlayer.new(JSON.parse_string(JSON.stringify(recorder.to_dict())))
	playback.seek(playback.step_count())
	ck(playback.state.digest_hash() == r.state.digest_hash(), "event operations replay identically")
	ck(JSON.parse_string(JSON.stringify(playback.resolver.random_events.snapshot())) == JSON.parse_string(JSON.stringify(r.random_events.snapshot())), "event parameters and IDs replay identically")
	command(r, "event remove " + ref)
	ck(r.random_events.clouds.is_empty() and not r.state.grid.cell(Vector2i(10, 9)).gas, "remove clears effect and gas mask")
	rejected(r, "event remove " + ref)
	# Editor metadata is read-only and consumes no dice.
	var checkpoint := r.state.dice.checkpoint()
	for pair: Array in RandomEvents.REGISTRY:
		load("res://src/cheats/CheatEventEditor.gd").defaults(pair[0], r)
		CheatEventModel.schema(pair[0], r)
	ck(r.state.dice.checkpoint() == checkpoint, "opening editor does not advance shared RNG")
