extends SceneTree
## Shields, drones and captives (2026-10-18 owner report): a blast's epicentre is a direct
## hit no neighbouring shield can shelter, a drone over a shield bearer kills it, and a
## grabbed (HELD) soldier dies to blasts, fire and bullets like anyone else.

var fails := 0
func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails += 1
func _initialize() -> void: run.call_deferred()

func arena() -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(24, 14)
	map.set_spawn(Vector2i(1, 1), "light_infantry", 0)
	map.set_spawn(Vector2i(22, 12), "light_infantry", 1)
	var s := map.build_state(5)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

func add(r: GameActionResolver, kind: String, c: Vector2i, side: int = 0, occupy := true) -> UnitInstance:
	return r.state.spawn_unit(load("res://src/data/units/%s.tres" % kind), c, side, occupy)

func drone_over(r: GameActionResolver, c: Vector2i) -> UnitInstance:
	var d := add(r, "drone", c, 0, false)
	d.is_drone = true
	return d

func grab(captor: UnitInstance, captive: UnitInstance) -> void:
	captive.status = MCF.Status.HELD
	captive.captor_id = captor.id

func run() -> void:
	var r := arena()
	var sb := add(r, "shield_bearer", Vector2i(10, 7), 1)
	var sb2 := add(r, "shield_bearer", Vector2i(11, 7), 1)
	var d := drone_over(r, sb.coord)
	r._drone_explode(d, d.coord, "detonated")
	ck(not sb.is_alive(), "a drone over a shield bearer kills it, even beside another shield")
	ck(sb2.is_alive(), "the shield bearer beside it survives outside the epicentre")

	r = arena()
	var li := add(r, "light_infantry", Vector2i(10, 7), 1)
	add(r, "shield_bearer", Vector2i(11, 7), 1)
	var near := add(r, "light_infantry", Vector2i(10, 8), 1)
	r._blast(li.coord, ActionResult.success([]))
	ck(not li.is_alive(), "the soldier a blast lands on dies though a friendly shield stands beside him")
	ck(near.is_alive(), "a shield still shelters the soldiers next to it outside the epicentre")

	r = arena()
	var captor := add(r, "light_infantry", Vector2i(10, 7), 1)
	var captive := add(r, "light_infantry", Vector2i(11, 7), 0)
	grab(captor, captive)
	r._blast(captive.coord, ActionResult.success([]))
	ck(captive.status == MCF.Status.CORPSE and captive.captor_id == -1, "a grabbed soldier dies in a blast")
	ck(r.held_unit_of(captor) == null, "and the captor is left holding nobody")

	r = arena()
	captor = add(r, "light_infantry", Vector2i(10, 7), 1)
	captive = add(r, "light_infantry", Vector2i(11, 7), 0)
	grab(captor, captive)
	r.state.grid.cell(Vector2i(12, 7)).on_fire = true
	r.state.grid.cell(Vector2i(12, 7)).fire_owner = 1
	r.state.dice.feed_scripted([6, 6, 6, 6, 6, 6, 6, 6])
	r.advance_fire(1, ActionResult.success([]))
	ck(captive.status == MCF.Status.CORPSE, "spreading fire burns a grabbed soldier")

	r = arena()
	captor = add(r, "light_infantry", Vector2i(10, 7), 0)
	captive = add(r, "light_infantry", Vector2i(9, 7), 1)
	grab(captor, captive)
	var shooter := add(r, "machinegunner", Vector2i(4, 7), 1)
	r.state.turns.active_index = 1
	shooter.remaining_ap = 3
	ck(r.first_unit_on_line(shooter.coord, captor.coord) == captive, "a captive held in the line of fire takes the bullets")
	ck(r.can_shoot(shooter, captor) != "" and r.can_shoot(shooter, captive) == "", "a captive is a human shield: the shot goes to him, not past him to the captor")
	var enemy_captive := add(r, "light_infantry", Vector2i(4, 9), 0)
	grab(add(r, "light_infantry", Vector2i(5, 9), 1), enemy_captive)
	ck(r.can_shoot(shooter, enemy_captive) == "", "a grabbed enemy can be shot")
	r.state.dice.feed_scripted([6, 1, 6, 1, 6, 1, 6, 1, 6, 1])
	var shot := r.resolve(ShootIntent.new(shooter.id, enemy_captive.id))
	ck(shot.ok and enemy_captive.status == MCF.Status.CORPSE, "and dies to the shots (%s)" % shot.reason)

	frag_on_shield()
	ranged_fire()
	print("shield blasts: %d failure(s)" % fails)
	quit(0 if fails == 0 else 1)

## Owner rule (2026-10-18): a shield bearer is fired at only from a neighbouring cell, except
## by a sniper, a marksman, an anti-tank soldier or a tank's cannon.
func ranged_fire() -> void:
	for kind in ["light_infantry", "heavy_infantry", "machinegunner", "flamethrower", "engineer"]:
		var r := arena()
		var shield := add(r, "shield_bearer", Vector2i(10, 7), 1)
		var far := add(r, kind, Vector2i(6, 7), 0)
		var near := add(r, kind, Vector2i(9, 8), 0)
		ck(r.can_shoot(far, shield) != "" and not r.hostile_target_ids(far).has(shield.id), "%s can't fire at a shield bearer from range" % kind)
		ck(r.can_shoot(near, shield) == "", "%s can fire at an adjacent shield bearer" % kind)
	for kind in ["sniper", "marksman", "anti_tank"]:
		var r := arena()
		var shield := add(r, "shield_bearer", Vector2i(10, 7), 1)
		var far := add(r, kind, Vector2i(6, 7), 0)
		ck(r.can_shoot(far, shield) == "", "%s may fire at a shield bearer from range" % kind)
	var r := arena()
	var shield := add(r, "shield_bearer", Vector2i(10, 7), 1)
	var borg_rider := add(r, "sniper", Vector2i(6, 7), 0)
	borg_rider.borg_id = 999
	ck(r.shield_out_of_reach(borg_rider, shield), "a sniper inside a borg fires its mounted gun, not a rifle")
	r.mode.kind = MatchMode.Kind.HOLDOUT
	r.mode.wave_side = 1
	ck(not r.shield_out_of_reach(add(r, "light_infantry", Vector2i(6, 9), 0), shield), "Holdout wave shields carry no shield")

## Owner rule (2026-10-19, later the same day): a frag grenade never kills a shield
## bearer, epicentre included — only a tank shell, an anti-tank round or a drone right
## over it does (run_playtest21). No dice are rolled for it.
func frag_on_shield() -> void:
	for rolls in [[2, 2], [1, 1]]:
		var r := arena()
		var thrower := add(r, "machinegunner", Vector2i(4, 7), 0)
		var sb := add(r, "shield_bearer", Vector2i(10, 7), 1)
		r.state.dice.feed_scripted(rolls)
		r._explode_frag(thrower, sb.coord)
		ck(sb.is_alive(), "a grenade on a shield bearer (dice %s): it holds" % [rolls])
