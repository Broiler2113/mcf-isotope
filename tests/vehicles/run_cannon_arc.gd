extends "res://tests/SuiteBase.gd"

const NOWHERE := Vector2i(-1, -1)
const CENTER := Vector2i(11, 11)

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	for facing: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		_arcs(facing)
	_turn_and_jam()
	_ai_positioning()
	_replay_compatibility()

func field(facing := Vector2i.RIGHT) -> GameActionResolver:
	var map := MapData.blank_arena(24, 24)
	map.set_spawn(Vector2i(10, 10), "tank", 0, facing)
	map.set_spawn(Vector2i(9, 11), "light_infantry", 0)
	map.set_spawn(Vector2i(5, 11), "light_infantry", 1)
	map.set_spawn(Vector2i(21, 21), "light_infantry", 1)
	var state := map.build_state(1422)
	state.turns.round_order = [0, 1]
	state.turns.active_index = 0
	var r := GameActionResolver.new(state)
	r.fog_mode = MCF.Fog.OFF
	var tank: Vehicle = state.all_vehicles()[0]
	ck(r.resolve(VehicleBoardIntent.new(state.grid.cell(Vector2i(9, 11)).occupant.id, tank.id)).ok,
			"fixture boards a real tank crew")
	tank.ap = 4
	return r

func _arcs(facing: Vector2i) -> void:
	var r := field(facing)
	var tank: Vehicle = r.state.all_vehicles()[0]
	var highlights := r.cannon_target_cells(tank)
	var legal := LegalIntents.enumerate(r, 0, {"v%d" % tank.id: true})
	var shots := {}
	for intent: Intent in legal:
		if intent is VehicleCannonIntent: shots[intent.target] = true
	for direction: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		var sideways := Vector2i(-direction.y, direction.x)
		for lane in range(-1, 2):
			var port := CENTER + direction + sideways * lane
			var target := port + direction * 5
			var allowed := direction != -facing
			ck(r.cannon_port(tank, target) == (port if allowed else NOWHERE), "all three ports on each edge respect hull facing")
			ck(highlights.has(target) == allowed and shots.has(target) == allowed,
					"target highlights and legal actions include forward/side lanes and exclude rear lanes")
			var isolated := field(facing)
			var v: Vehicle = isolated.state.all_vehicles()[0]
			var before := StateCodec.encode(isolated.state)
			var intent := VehicleCannonIntent.new(v.id, target)
			var result := isolated.resolve(IntentCodec.decode(IntentCodec.encode(intent)))
			ck(result.ok == allowed, "wire-decoded shots enforce the same firing arc")
			if not allowed:
				ck(StateCodec.encode(isolated.state) == before, "rejected rear fire preserves AP, ammo counter, aim, dice and board")
			else:
				ck(v.ap == 3 and v.cannon_shots_this_round == 1 and v.gun_world_dir() == direction,
						"allowed fire consumes one AP and aims the cannon at the target")

func _turn_and_jam() -> void:
	var r := field()
	var tank: Vehicle = r.state.all_vehicles()[0]
	var rear := CENTER + Vector2i.LEFT * 6
	ck(not r.resolve(VehicleCannonIntent.new(tank.id, rear)).ok, "tank cannot fire backward")
	ck(r.resolve(VehicleTurnIntent.new(tank.id, Vector2i.LEFT)).ok, "tank can turn its hull toward a rear target")
	ck(r.resolve(VehicleCannonIntent.new(tank.id, rear)).ok, "turning the hull makes the former rear target legal")
	var jammed := field()
	var v: Vehicle = jammed.state.all_vehicles()[0]
	v.remember_shot_dir(Vector2i.LEFT)
	v.components[MCF.COMP_TOWER] = 0
	ck(not jammed.resolve(VehicleCannonIntent.new(v.id, rear)).ok, "an old rearward jammed turret cannot bypass the new arc")
	ck(not jammed.cannon_target_cells(v).has(rear), "rearward jammed aim is excluded from highlights")

func _ai_positioning() -> void:
	var r := field()
	var tank: Vehicle = r.state.all_vehicles()[0]
	var ai := AIController.new(0, AIController.Difficulty.HARD)
	ck(not ai._opens_cannon_line(r.state, r, tank, tank.origin + Vector2i.UP),
			"AI does not move to open an unusable rear firing lane")
	tank.facing = Vector2i.UP
	ck(ai._opens_cannon_line(r.state, r, tank, tank.origin + Vector2i.UP),
			"AI still recognizes a usable side firing lane")

func _replay_compatibility() -> void:
	var old := field()
	var tank: Vehicle = old.state.all_vehicles()[0]
	old.legacy_rear_cannon = true
	var recorder := ReplayRecorder.new()
	recorder.begin(old.state, old)
	old.replay_recorder = recorder
	ck(old.resolve(VehicleCannonIntent.new(tank.id, CENTER + Vector2i.LEFT * 6)).ok,
			"legacy fixture records a backward shot")
	old.replay_recorder = null
	var data := recorder.to_dict()
	data.rules.erase("cannon_arc") # Real pre-0.14.2.2 recordings have no marker.
	var player := ReplayPlayer.new(data)
	player.advance_random = true
	player.seek(1)
	ck(player.seek_error == "" and player.resolver.legacy_rear_cannon,
			"old recordings replay backward shots without reconstruction errors")
	ck(player.state.digest_hash() == old.state.digest_hash(), "legacy replay reconstructs the original result")
	var live := GameActionResolver.new(StateCodec.decode(StateCodec.encode(player.state)))
	StateCodec.apply_rules(live, data.rules)
	ck(not live.legacy_rear_cannon, "continuing an old save uses current live firing rules")
	var fresh := ReplayRecorder.new()
	fresh.begin(live.state, live)
	ck(fresh.to_dict().rules.cannon_arc == 1, "new recordings identify the restricted cannon arc")
	var resumed := ReplayRecorder.new()
	resumed.adopt_prefix(data, 1, live.state, live, {})
	resumed.resume_checkpoint(ReplayCheckpoint.effects(live.state))
	live.replay_recorder = resumed
	ck(live.resolve(VehicleCannonIntent.new(tank.id, CENTER + Vector2i.RIGHT * 6)).ok, "resumed match records forward fire")
	live.replay_recorder = null
	var branch := ReplayPlayer.new(resumed.to_dict())
	branch.advance_random = true
	branch.seek(0)
	for at in 3:
		ck(branch.play_next().ok, "linear playback crosses the old/new rules checkpoint")
		ck(branch.resolver.legacy_rear_cannon == (at == 0), "linear playback switches arc rules at resume")
	for at in [3, 1, 2, 0, 3]:
		branch.seek(at)
		ck(branch.seek_error == "" and branch.resolver.legacy_rear_cannon == (at < 2), "seeking restores the correct historical cannon rules")
	ck(branch.state.digest_hash() == live.state.digest_hash(), "resumed replay reconstructs the live result")
