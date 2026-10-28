extends SceneTree

## Issues-12 #11–#13 on the real battle screen: a hovered unit twitches, units and vehicles
## floating in vacuum sway, an aiming tank's turret follows the cursor smoothly inside its arc.
## Requires a display: xvfb-run -a godot --script tests/render_board_motion.gd
var failures: Array[String] = []
func ck(ok: bool, label: String) -> void:
	print(("ok " if ok else "FAIL ") + label)
	if not ok: failures.append(label)
func _initialize() -> void: run.call_deferred()

var main: Node

func screen_of(c: Vector2) -> Vector2:
	return main.pan + (main.ORIGIN + c * main.CELL) * main.zoom

func frames(n: int) -> void:
	for i in n: await process_frame

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("This test needs a display: xvfb-run -a godot --script tests/render_board_motion.gd")
		quit(2)
		return
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(30, 22)
	for y in map.height:
		for x in range(20, map.width):
			map.is_space[y * map.width + x] = 1
	map.set_spawn(Vector2i(3, 3), "light_infantry", 0)
	map.set_spawn(Vector2i(24, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(4, 18), "light_infantry", 1)
	MapHandoff.pending = map
	main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	await frames(5)
	var tank: Vehicle = main.state.spawn_vehicle("tank", Vector2i(8, 8), 0)
	tank.facing = Vector2i.RIGHT
	var shuttle: Vehicle = main.state.spawn_vehicle("shuttle", Vector2i(23, 12), 0)
	main.zoom = 1.0
	main._center_on_cell(Vector2i(14, 10), true)
	main._redraw()
	await frames(5)

	# Floating in vacuum (#13): the soldier on space drifts and turns; the one on the deck does not.
	var floater: UnitInstance = main.state.grid.cell(Vector2i(24, 4)).occupant
	var grounded: UnitInstance = main.state.grid.cell(Vector2i(3, 3)).occupant
	ck(main._floaters.get(floater.id, -2) == -1, "a soldier on vacuum floats")
	ck(not main._floaters.has(grounded.id), "a soldier on the deck does not")
	ck(main._float_ids.has(shuttle.id) and not main._float_ids.has(tank.id), "the shuttle over vacuum floats, the tank on the deck does not")
	var sp = main._unit_sprites[floater.id]
	var a: Vector2 = sp.position
	var ra: float = sp.rotation
	await frames(30)
	var piv: Vector2 = main.ORIGIN + Vector2(24.5, 4.5) * main.CELL
	var drift: Vector2 = sp.position + piv.rotated(sp.rotation) - piv   # where the soldier's centre went
	ck(sp.position != a and sp.rotation != ra and drift.length() < 4.0 and absf(sp.rotation) < 0.1,
			"the floating soldier sways slightly (centre %s, turn %.3f)" % [drift, sp.rotation])
	ck(main._veh_float.visible, "floating vehicles have their own layer")

	# Hover twitch (#11): once, briefly, then still.
	Input.warp_mouse(screen_of(Vector2(3.5, 3.5)))
	var gs = main._unit_sprites[grounded.id]
	var twitched := false
	for i in 10:
		await process_frame
		if absf(gs.rotation) > 0.001: twitched = true
	ck(twitched, "hovering a soldier makes it twitch")
	await create_timer(0.6).timeout
	await frames(2)
	ck(gs.rotation == 0.0 and gs.wob == Vector2.ZERO, "the twitch settles and the soldier is still again")

	# Turret (#12): follows the cursor inside the arc, smoothly, and holds outside it.
	main.selected_vehicle_id = tank.id
	main._veh_enter_cannon()
	await frames(3)
	var center := Vector2(tank.origin) + Vector2(1.5, 1.5)
	Input.warp_mouse(screen_of(center + Vector2(0, 6)))   # straight to the tank's right side (south)
	await frames(2)
	ck(main._turret_live.has(tank.id), "aiming hands the turret to the layer over the soldiers")
	var last: float = main._turret_live.get(tank.id, 0.0)
	var worst := 0.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1500:
		var before := Time.get_ticks_usec()
		await process_frame
		var dt := (Time.get_ticks_usec() - before) / 1e6
		var now: float = main._turret_live.get(tank.id, 0.0)
		worst = maxf(worst, absf(angle_difference(last, now)) / maxf(dt, 1e-3))
		last = now
	ck(absf(angle_difference(last, PI * 0.5)) < 0.08, "the turret turns to the cursor on its right (%.2f rad)" % last)
	ck(worst <= main.TURRET_SPEED * 1.6, "it turns smoothly, never faster than %.1f rad/s (%.2f)" % [main.TURRET_SPEED, worst])
	main._redraw()
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OS.get_environment("SHOT") if OS.has_environment("SHOT") else "user://board_motion.png")
	Input.warp_mouse(screen_of(center + Vector2(-6, 0.3)))   # behind the tank: outside the arc
	await create_timer(0.8).timeout
	ck(absf(angle_difference(main._turret_live.get(tank.id, 0.0), PI * 0.5)) < 0.08, "behind the tank the turret holds its last angle")
	Input.warp_mouse(screen_of(center + Vector2(6, -6)))   # forward-left diagonal
	await create_timer(1.2).timeout
	ck(absf(angle_difference(main._turret_live.get(tank.id, 0.0), -PI * 0.25)) < 0.1, "it follows the cursor to any angle in the arc, not just eight steps")
	main.mode = main.Mode.NONE
	main._redraw()
	await create_timer(1.2).timeout
	await frames(3)
	ck(not main._turret_live.has(tank.id), "leaving the aim, the turret settles back and the board draws it again")
	ck(absf(main._turret_shown.get(tank.id, 9.0)) < 0.01, "a tank that never fired settles facing forward")
	print("board motion: %d failure(s)" % failures.size())
	quit(1 if not failures.is_empty() else 0)
