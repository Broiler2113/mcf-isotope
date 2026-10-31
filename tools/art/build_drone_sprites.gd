extends SceneTree

## Bake the board's drone sprites from the same textured models first person shows,
## straight down, nose up, with a mask of the team-coloured top plates and a rotor strip.
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
	# Use a fixed blade angle instead of elapsed time for reproducible animation frames.
	shader.code = FirstPersonBoard.SHADER.replace("TIME * spin *", "spin *")
	DirAccess.make_dir_recursive_absolute("res://assets/models/drone/sprites")
	for scout: bool in [false, true]:
		for mask: bool in [false, true]:
			var model := DroneModel.create(scout, func(imported: Material) -> Material:
				var source := imported as StandardMaterial3D
				return FirstPersonBoard.material(shader, {"tex": source.albedo_texture, "no_fog": true,
						"lm_on": false, "flat_light": Color.WHITE, "stripe_mask": mask,
						"spin_arm": Vector2(0.19, deg_to_rad(38.0)) if scout else Vector2(0.2, PI / 4.0),
						"stripe_center_x": 0.0, "stripe_half_width": 10.0,
						"team_stripe": mask and source.resource_name == "TeamStripe"}))
			world.add_child(model)
			var name := "scout_drone" if scout else "drone"
			var suffix := "_mask" if mask else ""
			var strip := Image.create(DroneModel.SPRITE_SIZE * DroneModel.ANIMATION_FRAMES,
					DroneModel.SPRITE_SIZE, false, Image.FORMAT_RGBA8)
			for frame in DroneModel.ANIMATION_FRAMES:
				# Three blades repeat after a third of a revolution; neighbouring motors counter-rotate.
				var phase := TAU * frame / (3.0 * DroneModel.ANIMATION_FRAMES)
				for surface in model.mesh.get_surface_count():
					(model.get_surface_override_material(surface) as ShaderMaterial).set_shader_parameter("spin", phase)
				await process_frame
				await RenderingServer.frame_post_draw
				var image := vp.get_texture().get_image()
				strip.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i(frame * DroneModel.SPRITE_SIZE, 0))
				if frame == 0:
					if not _save(image, name + suffix):
						quit(1)
						return
			if not _save(strip, name + "_spin" + suffix):
				quit(1)
				return
			model.free()
	vp.free()
	print("Drones: 48x48 kamikaze and scout sprites, team masks and eight-frame rotor strips baked.")
	quit()

## These are source Images, like the existing drone pictures, for runtime team recolouring.
func _save(image: Image, name: String) -> bool:
	var path := "res://assets/models/drone/sprites/%s.png" % name
	if image.save_png(path) != OK:
		printerr("Could not save " + name)
		return false
	if not FileAccess.file_exists(path + ".import"):
		var dest := "res://.godot/imported/%s.png-%s.image" % [name, path.md5_text()]
		var file := FileAccess.open(path + ".import", FileAccess.WRITE)
		if file == null: return false
		file.store_string('[remap]\n\nimporter="image"\ntype="Image"\nuid="%s"\npath="%s"\n\n[deps]\n\nsource_file="%s"\ndest_files=["%s"]\n\n[params]\n' % [
				ResourceUID.id_to_text(ResourceUID.create_id()), dest, path, dest])
	return true
