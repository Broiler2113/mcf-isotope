extends "res://tests/SuiteBase.gd"
## Smoke and gas: walking through gas, smoke hiding units with fog off, shooting through
## smoke and past allies.

func run() -> void:
	_gas_walk()

	smoke_and_allies()

	smoke()

func _arena() -> GameState:
	var m := MapData.blank_arena(16, 12)
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(12, 5), "light_infantry", 1)
	var s := m.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	return s

func _gas_walk() -> void:
	for roll in [1, 6]:
		for target in [Vector2i(4, 5), Vector2i(6, 5)]:
			var s := _arena()
			var r := GameActionResolver.new(s)
			r.random_events = RandomEvents.new(false)
			r.random_events.add_cloud(4, 1, 2, 10, 3)
			r._sync_gas()
			var u := s.grid.cell(Vector2i(2, 5)).occupant
			u.remaining_ap = 3
			s.dice.feed_scripted([roll])
			var res := r.resolve(MoveIntent.new(u.id, target))
			ck(res.ok, "movement into or through gas succeeds as an action")
			ck(s.dice.scripted_remaining() == 0 and s.dice.fallback_rolls == 0, "one roll at first gas tile, not every tile")
			ck(u.is_alive() == (roll == 6), "gas survival follows the contact roll")
			ck(u.coord == (target if roll == 6 else Vector2i(4, 5)), "failed contact stops at first gas tile")
			var checks := res.dice_events.filter(func(e: Dictionary) -> bool: return e.get("kind") == "check")
			ck(checks.size() == 1, "contact ck reaches the battle/replay animation")
			if roll == 1: ck(res.deaths.has(u.id), "death is reported for delayed animation")
	var pushed_state := _arena()
	var pushed_resolver := GameActionResolver.new(pushed_state)
	var pushed := pushed_state.grid.cell(Vector2i(2, 5)).occupant
	pushed_resolver.random_events.add_cloud(3, 5, 1, 1, 3)
	pushed_resolver._sync_gas()
	pushed_state.dice.feed_scripted([1])
	var pushed_result := ActionResult.success([])
	pushed_resolver._slide(pushed, Vector2i(5, 5), pushed_result)
	ck(not pushed.is_alive() and pushed.coord == Vector2i(3, 5), "forced movement stops on first lethal gas tile")
	var s := _arena()
	var r := GameActionResolver.new(s)
	var u := s.grid.cell(Vector2i(2, 5)).occupant
	s.dice.feed_scripted([6])
	var res := ActionResult.success([])
	r._land_gas({"x": 2, "y": 5, "w": 1, "h": 1}, res)
	ck(u.is_alive() and s.dice.scripted_remaining() == 0, "gas appearing on a stationary soldier checks immediately")

	var borg_state := _arena()
	var borg_resolver := GameActionResolver.new(borg_state)
	var pilot := borg_state.grid.cell(Vector2i(2, 5)).occupant
	var borg := borg_state.spawn_vehicle("borg", Vector2i(3, 5), 0)
	ck(borg_resolver.resolve(VehicleBoardIntent.new(pilot.id, borg.id)).ok, "gas fixture boards a borg")
	borg_resolver.random_events.add_cloud(4, 5, 1, 1, 3)
	borg_resolver._sync_gas()
	borg_state.dice.feed_scripted([1])
	var exit_result := borg_resolver.resolve(VehicleDisembarkIntent.new(pilot.id, Vector2i(4, 5)))
	ck(exit_result.ok and not pilot.is_alive(), "leaving a sealed borg into gas checks exposure")

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func smoke_and_allies() -> void:
	var map := arena()
	map.set_spawn(Vector2i(2, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(8, 4), "light_infantry", 1)
	map.set_spawn(Vector2i(2, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(5, 8), "light_infantry", 0)
	map.set_spawn(Vector2i(8, 8), "light_infantry", 1)
	map.set_spawn(Vector2i(14, 12), "heavy_infantry", 0)
	map.set_spawn(Vector2i(15, 11), "sniper", 1)
	var r := resolver_for(map)
	var g := r.state.grid
	var shooter: UnitInstance = g.cell(Vector2i(2, 4)).occupant
	var target: UnitInstance = g.cell(Vector2i(8, 4)).occupant
	var base := r.hit_need_for(shooter, target)
	g.cell(Vector2i(5, 4)).smoke = true
	var mods: Array = []
	ck(r.can_shoot(shooter, target) == "", "a shot through smoke is allowed")
	ck(r.hit_need_for(shooter, target, mods) == base + GameActionResolver.SMOKE_HIT_PENALTY,
		"…at a large hit penalty (%d → %d)" % [base, r.hit_need_for(shooter, target)])
	g.cell(Vector2i(5, 4)).smoke = false
	var hi: UnitInstance = g.cell(Vector2i(14, 12)).occupant
	var sniper: UnitInstance = g.cell(Vector2i(15, 11)).occupant
	for c: Vector2i in [Vector2i(14, 12), Vector2i(15, 12), Vector2i(14, 11), Vector2i(13, 12)]:
		g.cell(c).smoke = true
	ck(r.can_shoot(hi, sniper) == "", "heavy infantry in its own smoke can shoot the sniper diagonal to it")
	for c: Vector2i in [Vector2i(14, 12), Vector2i(15, 12), Vector2i(14, 11), Vector2i(13, 12)]:
		g.cell(c).smoke = false
	var back: UnitInstance = g.cell(Vector2i(2, 8)).occupant
	var enemy: UnitInstance = g.cell(Vector2i(8, 8)).occupant
	ck(r.can_shoot(back, enemy) == "Another unit is in the way", "a soldier never shoots through an ally")

func arena__player_reports() -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(22, 16)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(18, 5), "light_infantry", 1)
	var s := map.build_state(17)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

func smoke() -> void:
	var r := arena__player_reports()
	var s := r.state
	var u := s.grid.cell(Vector2i(2, 5)).occupant
	var enemy := s.grid.cell(Vector2i(18, 5)).occupant
	s.grid.cell(Vector2i(12, 5)).set_feature(MCF.FEATURE_WALL)
	r.random_events.add_smoke(4, 10, 3, 3, 3)
	r._sync_gas()
	ck(not r.fog_enabled and r.is_visible_to_team(0, enemy), "smoke elsewhere does not enable wall fog")
	r.random_events.add_smoke(7, 4, 2, 3, 3)
	r._sync_gas()
	ck(not r.is_visible_to_team(0, enemy), "smoke itself hides units behind it with global fog off")
	u.remaining_ap = 3
	var res := r.resolve(MoveIntent.new(u.id, Vector2i(10, 5)))
	ck(res.ok and u.is_alive() and u.coord == Vector2i(10, 5), "soldier walks through smoke without a damage roll")
	ck(res.dice_events.all(func(e: Dictionary) -> bool: return e.get("kind") in ["hold", "walk", "ap"]), "smoke movement is harmless")
