extends SceneTree

## Bake the very same textured model used in first person, vertically from above.
## xvfb-run -a godot --path . --script res://tools/art/build_tank_sprites.gd [-- split]
func _initialize() -> void:
	_bake.call_deferred()

func _bake() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Tank sprites require the Compatibility renderer and a display (or Xvfb).")
		quit(1)
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(TankModel.SPRITE_SIZE, TankModel.SPRITE_SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = TankModel.SPRITE_METRES
	camera.position = Vector3(0, 8, 0)
	# The game's models face +X. Project +X to the top of the sprite (nose-up).
	camera.look_at_from_position(camera.position, Vector3.ZERO, Vector3.RIGHT)
	world.add_child(camera)
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.environment = env
	world.add_child(environment)
	var shader := Shader.new()
	shader.code = FirstPersonBoard.SHADER
	DirAccess.make_dir_recursive_absolute("res://textures/vehicles/tank")
	# -- split: only the hull without its turret and the turret alone (issues-12 #12: the board
	# turns the turret smoothly instead of picking one of eight whole-tank frames).
	var split_only := OS.get_cmdline_user_args().has("split")
	for kind: String in ["tank", "tank_mask"]:
		for part: String in ["hull", "turret"]:
			var model := TankModel.create(func(imported: Material) -> Material:
				var source := imported as StandardMaterial3D
				return FirstPersonBoard.material(shader, {"tex": source.albedo_texture,
						"no_fog": true, "lm_on": false, "flat_light": Color.WHITE, "tint": source.albedo_color,
						"stripe_mask": kind == "tank_mask",
						"team_stripe": kind == "tank_mask" and source.resource_name == "TeamStripe"}))
			world.add_child(model)
			if part == "hull": model.get_node("turret").visible = false
			else: model.get_child(0).visible = false
			await process_frame
			await RenderingServer.frame_post_draw
			var name := ("tank_" + part) + ("_mask" if kind == "tank_mask" else "")
			if vp.get_texture().get_image().save_png("res://textures/vehicles/tank/%s.png" % name) != OK:
				printerr("Could not save ", name)
				quit(1)
				return
			model.free()
	if split_only:
		vp.free()
		print("SVAROG: hull and turret baked separately.")
		quit()
		return
	for frame in 8:
		var suffix := "_aim_%d" % frame if frame != 0 else ""
		for kind: String in ["tank", "tank_wreck", "tank_mask"]:
			var model := TankModel.create(func(imported: Material) -> Material:
				var source := imported as StandardMaterial3D
				var tint := source.albedo_color
				if kind == "tank_wreck": tint *= TankModel.WRECK_TINT
				return FirstPersonBoard.material(shader, {"tex": source.albedo_texture,
						"no_fog": true, "lm_on": false, "flat_light": Color.WHITE, "tint": tint,
						"stripe_mask": kind == "tank_mask",
						"team_stripe": kind == "tank_mask" and source.resource_name == "TeamStripe"}), kind == "tank_wreck")
			world.add_child(model)
			model.get_node("turret").rotation.y = -frame * PI / 4.0
			await process_frame
			await RenderingServer.frame_post_draw
			var picture := vp.get_texture().get_image()
			var err := picture.save_png("res://textures/vehicles/tank/%s%s.png" % [kind, suffix])
			if err != OK:
				printerr("Could not save tank sprite: ", err)
				quit(1)
				return
			model.free()
	vp.free()
	print("SVAROG: 96x96 nose-up tank, wreck and roof-stripe masks baked for eight gun angles.")
	quit()
