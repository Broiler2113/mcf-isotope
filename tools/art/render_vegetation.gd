extends SceneTree

## Renders the plant scans listed in .cache/vegetation/jobs.json (written by
## tools/art/build_vegetation.py, which runs this) into transparent pictures there: three side
## views 60° apart in a row, or one view from above. Orthographic, lit from above-left like the
## rest of the art, PX_PER_M pixels a metre; build_vegetation.py shrinks them.

const PX_PER_M := 256
const MAX_PX := 2048
var _dir := ProjectSettings.globalize_path("res://.cache/")
var _cut := {}   # material -> its albedo with the alpha map in it

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var jobs: Array = JSON.parse_string(FileAccess.get_file_as_string(_dir + "vegetation/jobs.json"))
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(-35), 0)
	sun.light_energy = 1.15
	vp.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.7)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var rendered := {}
	for job: Dictionary in jobs:
		var plant := _load(str(job.model), job.nodes)
		vp.add_child(plant)
		var box := _bounds(plant)
		var top := str(job.view) == "top"
		var reach := maxf(box.size.x, box.size.z) * 0.75 if not top else maxf(box.size.x, box.size.z) * 0.5
		var centre := box.get_center()
		var ppm := mini(PX_PER_M, int(MAX_PX / maxf(box.size.y, reach * 2.0)))
		ppm = PX_PER_M / int(ceil(float(PX_PER_M) / ppm))   # a whole share of PX_PER_M
		var shots: Array[Image] = []
		if top:
			vp.size = Vector2i(ceili(reach * 2.0 * ppm), ceili(reach * 2.0 * ppm))
			cam.size = reach * 2.0
			cam.position = Vector3(centre.x, box.end.y + 5.0, centre.z)
			cam.rotation = Vector3(-PI / 2, 0, 0)
			shots.append(await _shot(vp))
		else:
			vp.size = Vector2i(ceili(reach * 2.0 * ppm), ceili(box.size.y * ppm))
			cam.size = box.size.y
			cam.rotation = Vector3.ZERO
			for k in 3:
				var a := k * PI / 3.0
				plant.rotation.y = 0.0
				plant.position = Vector3.ZERO
				var turn := Transform3D(Basis(Vector3.UP, a), Vector3.ZERO)
				plant.transform = Transform3D(Basis.IDENTITY, Vector3(centre.x, 0, centre.z)) * turn \
						* Transform3D(Basis.IDENTITY, -Vector3(centre.x, 0, centre.z))
				cam.position = Vector3(centre.x, centre.y, centre.z + reach + 10.0)
				shots.append(await _shot(vp))
		var w := shots[0].get_width()
		var strip := Image.create(w * shots.size(), shots[0].get_height(), false, Image.FORMAT_RGBA8)
		for i in shots.size():
			strip.blit_rect(shots[i], Rect2i(Vector2i.ZERO, shots[i].get_size()), Vector2i(i * w, 0))
		strip.save_png(_dir + "vegetation/%s.png" % job.name)
		rendered[job.name] = ppm
		print("%s: %s, %.2f m tall" % [job.name, strip.get_size(), box.size.y])
		plant.free()
	var f := FileAccess.open(_dir + "vegetation/rendered.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(rendered))
	f.close()
	quit()

## The model with only `nodes` of its roots shown (all when empty); every material cut out by its
## own alpha map, both sides drawn.
func _load(model: String, nodes: Array) -> Node3D:
	var dir := _dir + "polyhaven/" + model + "/"
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_file(dir + model + "_1k.gltf", state)
	var scene: Node3D = doc.generate_scene(state)
	if not nodes.is_empty():
		for child: Node in scene.get_children():
			if child is Node3D:
				(child as Node3D).visible = nodes.has(str(child.name))
	for mi: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if m == null: continue
			m = m.duplicate()
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			var key := dir + str(m.resource_name)
			if _cut.has(key):
				m.albedo_texture = _cut[key]
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				m.alpha_scissor_threshold = 0.5
				mi.set_surface_override_material(s, m)
				continue
			var alpha := _alpha_of(dir, str(m.resource_name))
			if alpha != null and m.albedo_texture != null:
				var img := m.albedo_texture.get_image()
				if img.is_compressed(): img.decompress()
				img.convert(Image.FORMAT_RGBA8)
				alpha.resize(img.get_width(), img.get_height())
				for y in img.get_height():
					for x in img.get_width():
						var c := img.get_pixel(x, y)
						c.a = alpha.get_pixel(x, y).r
						img.set_pixel(x, y, c)
				m.albedo_texture = ImageTexture.create_from_image(img)
				_cut[key] = m.albedo_texture
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				m.alpha_scissor_threshold = 0.5
			mi.set_surface_override_material(s, m)
	return scene

func _alpha_of(dir: String, material: String) -> Image:
	for ext: String in ["png", "jpg"]:
		var path: String = dir + "alpha/" + material + "." + ext
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			img.convert(Image.FORMAT_RGBA8)
			return img
	return null

## The world box of every shown mesh.
func _bounds(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		if not mi.is_visible_in_tree(): continue
		var b := mi.global_transform * mi.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out

func _shot(vp: SubViewport) -> Image:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()
