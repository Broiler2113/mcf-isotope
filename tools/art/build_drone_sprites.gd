extends SceneTree

## Bake the board's drone sprites from the same textured models first person shows,
## straight down, nose up, with a mask of the team-coloured top plates.
## xvfb-run -a godot --path . --rendering-method gl_compatibility --script res://tools/art/build_drone_sprites.gd
func _initialize() -> void:
	_bake.call_deferred()

func _bake() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Drone sprites require the Compatibility renderer and a display (or Xvfb).")
		quit(1)
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(DroneModel.SPRITE_SIZE, DroneModel.SPRITE_SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = DroneModel.SPRITE_METRES
	camera.look_at_from_position(Vector3(0, 4, 0), Vector3.ZERO, Vector3.RIGHT)
	world.add_child(camera)
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.environment = env
	world.add_child(environment)
	var shader := Shader.new()
	shader.code = FirstPersonBoard.SHADER
	DirAccess.make_dir_recursive_absolute("res://assets/models/drone/sprites")
	for scout: bool in [false, true]:
		for mask: bool in [false, true]:
			var model := DroneModel.create(scout, func(imported: Material) -> Material:
				var source := imported as StandardMaterial3D
				return FirstPersonBoard.material(shader, {"tex": source.albedo_texture, "no_fog": true,
						"lm_on": false, "flat_light": Color.WHITE, "stripe_mask": mask,
						"stripe_center_x": 0.0, "stripe_half_width": 10.0,
						"team_stripe": mask and source.resource_name == "TeamStripe"}))
			world.add_child(model)
			await process_frame
			await RenderingServer.frame_post_draw
			var name := ("scout_drone" if scout else "drone") + ("_mask" if mask else "")
			if vp.get_texture().get_image().save_png("res://assets/models/drone/sprites/%s.png" % name) != OK:
				printerr("Could not save " + name)
				quit(1)
				return
			model.free()
	vp.free()
	print("Drones: 48x48 nose-up kamikaze and scout sprites with team masks baked.")
	quit()
