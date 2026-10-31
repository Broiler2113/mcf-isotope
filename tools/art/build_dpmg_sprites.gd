extends SceneTree

## Bake the board's DPMG from the model first person shows (owner, fix-13 #18: "in 2D it should
## look how it looks in 3D"): straight down, north up, one 64 px picture of its cell for each
## of the eight directions it can face (TerrainTiles.dpmg_turn).
## xvfb-run -a godot --path . --rendering-method gl_compatibility --script res://tools/art/build_dpmg_sprites.gd
const SIZE := 64
const OUT := "res://assets/models/dpmg"

func _initialize() -> void:
	_bake.call_deferred()

func _bake() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("DPMG sprites require the Compatibility renderer and a display (or Xvfb).")
		quit(1)
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.0
	camera.look_at_from_position(Vector3(0.5, 4, 0.5), Vector3(0.5, 0, 0.5), Vector3.FORWARD)
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
	var sink := FirstPersonModels.Sink.new()
	FirstPersonModels.dpmg(sink)
	var model := MeshInstance3D.new()
	model.mesh = sink.mesh()
	# Lit a little brighter than the floor light first person gives it, so the dark gun reads
	# on a dark deck; a drop shadow sets it off a pale one.
	model.material_override = FirstPersonBoard.material(shader, {"use_mats": true, "mats": FirstPersonArt.materials(),
			"no_fog": true, "lm_on": false, "flat_light": Color(1.6, 1.6, 1.6)})
	world.add_child(model)
	DirAccess.make_dir_recursive_absolute(OUT)
	for k in 8:
		# As FirstPersonBoard turns it: about the cell's centre, k eighths of a turn.
		model.transform = Transform3D(Basis(Vector3.UP, -k * PI / 4.0), Vector3(0.5, 0, 0.5)) \
				* Transform3D(Basis.IDENTITY, Vector3(-0.5, 0, -0.5))
		await process_frame
		await RenderingServer.frame_post_draw
		var gun := vp.get_texture().get_image()
		gun.convert(Image.FORMAT_RGBA8)
		var pic := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
		for y in range(2, SIZE):
			for x in range(2, SIZE):
				pic.set_pixel(x, y, Color(0, 0, 0, 0.45 * gun.get_pixel(x - 2, y - 2).a))
		pic.blend_rect(gun, Rect2i(0, 0, SIZE, SIZE), Vector2i.ZERO)
		if pic.save_png("%s/dpmg_%d.png" % [OUT, k]) != OK:
			printerr("Could not save dpmg_%d" % k)
			quit(1)
			return
	vp.free()
	print("DPMG: eight %d px top-down board pictures baked." % SIZE)
	quit()
