extends "res://tests/SuiteBase.gd"

class SpriteBoard extends Node2D:
	var paint := Color(0.9, 0.18, 0.12)
	var face := Vector2i.UP
	var aim := Vector2i.ZERO
	func _draw() -> void:
		# Fractional pan/zoom and an animation displacement exercise transform recovery.
		draw_set_transform(Vector2(20, 20), 0.0, Vector2(2, 2))
		Sprites.set_base_transform(Vector2(20, 20), Vector2(2, 2))
		TankModel.draw(self, Rect2(0, 0, 96, 96), face, paint, false, Color.WHITE, aim)
		draw_rect(Rect2(100, 0, 2, 2), Color.MAGENTA)

class PurchaseReference extends Node2D:
	var face := Vector2i.RIGHT
	var paint := Color.WHITE
	var preview_opacity := 1.0
	func _draw() -> void:
		Sprites.set_base_transform(Vector2.ZERO, Vector2.ONE)
		TankModel.draw(self, Rect2(30, 30, 102, 102), face, paint, false, Color(1, 1, 1, preview_opacity))

func run() -> void:
	if DisplayServer.get_name() == "headless": ck(false, "requires rendered display"); return
	root.size = Vector2i(960, 640)
	var vp := SubViewport.new()
	vp.size = Vector2i(240, 240)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var board := SpriteBoard.new()
	vp.add_child(board)
	var directions := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
	var pictures := []
	for direction: Vector2i in directions:
		board.face = direction
		board.queue_redraw()
		var picture := await frame(vp)
		pictures.append(picture)
		ck(picture.get_pixel(221, 21).r > 0.9 and picture.get_pixel(221, 21).b > 0.9, "rotating the tank restores the caller's canvas transform")
	for i in range(1, 4):
		var original: Image = pictures[0].get_region(Rect2i(20, 20, 192, 192))
		for turn in i: original.rotate_90(CLOCKWISE)
		ck(original.get_data() == pictures[i].get_region(Rect2i(20, 20, 192, 192)).get_data(), "2D hull rotation matches its compass direction exactly")
	pictures[0].save_png("/tmp/isotope-tank-2d.png")
	vp.free()
	await purchase_sprites()
	var ui := root.get_node("Ui")
	ui.snowfall = false
	ui.dynamic_lighting = false
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(20, 18)
	map.env = "field"
	map.time_of_day = "day"
	map.set_spawn(Vector2i(7, 7), "tank", 0, Vector2i.RIGHT)
	map.set_spawn(Vector2i(12, 7), "tank", 1, Vector2i.LEFT)
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	var host := FirstPersonHost.new(map, TerrainTiles.new(grid, "field"))
	root.add_child(host)
	var fp: Node = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(10, 13))
	root.add_child(fp)
	fp.set_process(false)
	fp._stream_chunks(10000000)
	fp._sync_vehicles()
	var tank: Vehicle = host.state.all_vehicles()[0]
	var node: Node3D = fp._vehicles[tank.id]
	ck(node.get_child(0).mesh == TankModel.HULL, "first-person view uses the actual supplied hull mesh")
	var turret: Node3D = node.get_node("turret")
	ck(turret.get_child(0).mesh == TankModel.TURRET, "first-person gun uses the supplied turret mesh")
	var painted := 0
	for i in TankModel.HULL.get_surface_count():
		var mat: ShaderMaterial = node.get_child(0).get_surface_override_material(i)
		ck(mat.get_shader_parameter("tex") != null, "first-person surfaces bind the supplied texture")
		if mat.get_shader_parameter("team_stripe"):
			painted += 1
			ck(mat.get_shader_parameter("team_color") == host._side_color(tank.owner), "first-person roof stripe matches its team")
	ck(painted > 0, "upper armour is marked for the roof stripe")
	for direction: Vector2i in directions:
		tank.facing = direction
		for local: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i(-1, -1)]:
			tank.tower_locked_dir = local
			fp._sync_vehicles()
			var forward := turret.global_basis * Vector3.RIGHT
			var expected := Vector3(tank.gun_world_dir().x, 0, tank.gun_world_dir().y).normalized()
			ck(forward.is_equal_approx(expected), "3D turret follows the hull-relative gun direction after turns")
	tank.facing = Vector2i.RIGHT
	tank.tower_locked_dir = Vector2i.RIGHT
	fp._sync_vehicles()
	fp.pos = Vector3(10, 1.0, 13.5)
	fp.yaw = 0.0
	fp.pitch = -0.18
	fp._place_camera()
	(await frame(fp._vp)).save_png("/tmp/isotope-tank-first-person.png")
	fp._vis_img.fill(Color.BLACK)
	fp._upload_visibility()
	var dark := await frame(fp._vp)
	fp._vis_img.fill(Color.WHITE)
	fp._upload_visibility()
	ck((await frame(fp._vp)).get_data() != dark.get_data(), "textured tank materials obey the first-person visibility map")
	tank.wrecked = true
	fp._sync_vehicles()
	ck(fp._vehicles[tank.id] != node, "wrecking replaces the textured model with its burnt material")
	fp.free()
	host.free()
	await process_frame

func frame(viewport: SubViewport) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func purchase_sprites() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(164, 164)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	# Load after autoloads initialize: Placement uses the Ui singleton.
	var token: Node2D = load("res://tests/fixtures/TankPurchaseToken.gd").new()
	token.roster = Roster.default_duel(false)
	var reference := PurchaseReference.new()
	reference.paint = token.roster.color_of(0)
	vp.add_child(token)
	vp.add_child(reference)
	for direction: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
		for opacity: float in [1.0, 0.65]:
			token.face = direction
			token.preview_opacity = opacity
			token.show()
			token.queue_redraw()
			reference.hide()
			var actual := await frame(vp)
			token.hide()
			reference.face = direction
			reference.preview_opacity = opacity
			reference.show()
			reference.queue_redraw()
			ck(actual.get_data() == (await frame(vp)).get_data(),
					"purchase and live placement draw the same tank sprite without a bounding rectangle, with its facing and opacity")
	vp.free()
