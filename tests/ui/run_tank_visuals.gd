extends "res://tests/SuiteBase.gd"

func run() -> void:
	# Models read from source (no import cache needed) match Godot's own import exactly.
	for path: String in ["res://assets/models/tank/hull.obj", "res://assets/models/tank/wreck_turret.obj",
			"res://assets/models/drone/kamikaze.obj", "res://assets/models/drone/scout.obj"]:
		var imported := load(path) as Mesh
		if imported == null:
			ck(false, "the import of %s exists to compare against" % path)
			continue
		ck(_same_triangles(_triangles(Sprites._read_obj(path)), _triangles(imported)), "reading %s ourselves gives Godot's triangles, winding and UVs" % path)
	var albedo := Sprites.image_at("res://assets/models/tank/source/albedo.jpg")
	ck(albedo != null and albedo.get_size() == Vector2i(512, 512), "the tank texture reads without its import")
	for mesh: Mesh in [TankModel.mesh("hull"), TankModel.mesh("turret"), TankModel.mesh("wreck_hull"), TankModel.mesh("wreck_turret")]:
		ck(mesh.get_surface_count() > 0, "SVAROG contains imported geometry")
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface) as StandardMaterial3D
			ck(material != null and material.albedo_texture != null, "every surface retains the supplied colour texture")
			var arrays := mesh.surface_get_arrays(surface)
			ck(arrays[Mesh.ARRAY_VERTEX].size() == arrays[Mesh.ARRAY_TEX_UV].size(), "UVs cover every imported vertex")
			for normal: Vector3 in arrays[Mesh.ARRAY_NORMAL]:
				ck(is_equal_approx(normal.length(), 1.0), "imported normals remain normalised")
	var bounds := TankModel.mesh("hull").get_aabb().merge(TankModel.mesh("turret").get_aabb())
	ck(absf(bounds.position.y) < 0.001 and is_equal_approx(bounds.size.x, 3.6) and bounds.size.z > 2.5 and bounds.size.z < 3.0,
			"larger tank slightly overhangs its 3x3 footprint and stands on its tracks")
	ck(VehicleDB.size_of("tank") == Vector2i(3, 3), "visual enlargement keeps the 3x3 gameplay footprint")
	var original := load("res://assets/models/tank/source/SVAROG.obj") as Mesh
	var source_size := original.get_aabb().size
	var ratios := Vector3(bounds.size.x / source_size.z, bounds.size.y / source_size.y, bounds.size.z / source_size.x)
	ck(is_equal_approx(ratios.x, ratios.z) and is_equal_approx(ratios.y, ratios.x * 1.25 / 1.125), "tank is 1.125 times shorter than 0.14.2.2 with unchanged length and width")
	var model := TankModel.create()
	ck(model.get_node("turret").position == TankModel.TURRET_PIVOT, "turret pivots around the source model's turret axis")
	model.free()
	var wreck_bounds := TankModel.mesh("wreck_hull").get_aabb()
	ck(is_equal_approx(wreck_bounds.position.x, bounds.position.x)
			and is_equal_approx(wreck_bounds.end.x, bounds.end.x) and absf(wreck_bounds.position.y) < 0.001,
			"destroyed chassis keeps the live hull's length, centre and ground plane despite its export offset")
	var wreck_model := TankModel.create(Callable(), true)
	ck(wreck_model.get_node("turret").position == TankModel.TURRET_PIVOT,
			"damaged turret and hatch rotate around the same axis as the live turret")
	wreck_model.free()
	var previous: PackedByteArray
	var previous_wreck: PackedByteArray
	for aim in 8:
		var red := TankModel.sprite(Color(1, 0.2, 0.1), false, aim).get_image()
		var blue := TankModel.sprite(Color(0.1, 0.3, 1), false, aim).get_image()
		var wreck := TankModel.sprite(Color.RED, true, aim).get_image()
		var mask := TankModel._picture("tank_mask" + ("_aim_%d" % aim if aim != 0 else ""))
		var base := TankModel._picture("tank" + ("_aim_%d" % aim if aim != 0 else ""))
		ck(red.get_size() == Vector2i(96, 96) and wreck.get_size() == Vector2i(96, 96), "every tank and wreck frame is exactly 96x96")
		var painted := 0
		var unchanged := 0
		var tones := {}
		var changed_silhouette := 0
		for y in 96:
			for x in 96:
				var r := red.get_pixel(x, y)
				var b := blue.get_pixel(x, y)
				if r.a != wreck.get_pixel(x, y).a: changed_silhouette += 1
				if r.a == 0: continue
				if mask.get_pixel(x, y).r > 0.5:
					painted += 1
					ck(y >= 78 and y <= 85, "stripe runs across the rear deck behind the turret in every aim frame")
					ck(r.r >= r.b and b.b >= b.r, "roof stripe uses its team's colour")
					tones[r.to_rgba32()] = true
				else:
					unchanged += 1
					ck(r == b and r == base.get_pixel(x, y), "armour, tracks and barrel outside the stripe keep their original texture")
		ck(painted > 80 and painted < (painted + unchanged) * 0.2 and unchanged > 1500 and tones.size() > 10,
				"team colour is a visible narrow stripe, not whole-body paint")
		for edge in TankModel.SPRITE_SIZE:
			ck(red.get_pixel(edge, 0).a == 0 and red.get_pixel(edge, 95).a == 0 \
					and red.get_pixel(0, edge).a == 0 and red.get_pixel(95, edge).a == 0,
					"every turret angle fits inside the transparent sprite padding")
			ck(wreck.get_pixel(edge, 0).a == 0 and wreck.get_pixel(edge, 95).a == 0 \
					and wreck.get_pixel(0, edge).a == 0 and wreck.get_pixel(95, edge).a == 0,
					"wreck debris and damaged turret fit inside the same sprite padding")
		ck(changed_silhouette > 30, "wreck sprite depicts damaged geometry rather than just darkened live armour")
		ck(aim == 0 or wreck.get_data() != previous_wreck, "destroyed turret retains its own directional sprite")
		ck(red.get_pixel(0, 0).a == 0.0, "sprite background stays transparent")
		ck(aim == 0 or red.get_data() != previous, "turning the turret changes the projected sprite")
		previous = red.get_data()
		previous_wreck = wreck.get_data()
	ck(TankModel.sprite(Color.RED, true) == TankModel.sprite(Color.BLUE, true), "wreck appearance is independent of its former owner")
	await camera_drag()

func camera_drag() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var map := MapData.blank_arena(24, 18)
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(21, 15), "light_infantry", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	main._paused = true
	for i in 3: await process_frame
	main.set_process(false)
	main.zoom = main.ZOOM_MIN
	main.pan = Vector2(113.25, 92.75)
	main._center_on_cell(Vector2i(23, 17))
	ck(main._pan_tween != null, "camera regression starts during automatic recentering")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = Vector2(500, 350)
	main._unhandled_input(press)
	ck(main._pan_tween == null, "RMB takes control from automatic recentering at minimum zoom")
	var start: Vector2 = main.pan
	for i in 6:
		var motion := InputEventMouseMotion.new()
		motion.position = press.position + Vector2(7, -4) * (i + 1)
		motion.relative = Vector2(7, -4)
		motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
		main._unhandled_input(motion)
		main._ensure_visible(Vector2i(23, 17))
		await process_frame
		ck(main.pan.is_equal_approx(start + Vector2(7, -4) * (i + 1)), "drag moves exactly with the pointer without recentering feedback")
	press.pressed = false
	main._input(press) # Release over a HUD control never reaches _unhandled_input.
	ck(not main._mouse_panning, "a release consumed by the HUD ends the drag")
	var stopped: Vector2 = main.pan
	var stale := InputEventMouseMotion.new()
	stale.position = Vector2(500, 350)
	stale.relative = Vector2(50, 30)
	main._unhandled_input(stale)
	ck(main.pan == stopped, "pointer motion after release does not shake the map")
	main._mouse_panning = true
	main._unhandled_input(stale)
	ck(not main._mouse_panning and main.pan == stopped, "missing button masks recover from a lost release")
	main._center_on_cell(Vector2i(2, 2))
	main._zoom_at(Vector2(500, 350), 2.0)
	ck(main._pan_tween == null, "manual zoom also stops automatic recentering")
	main.free()
	await process_frame

## Material name -> triangles as [position, UV, normal] corners, keyed by their corners to
## the centimetre whatever corner they start at: the import reorders
## triangles for the vertex cache and compresses vertices, so the two agree as sets, to a millimetre.
func _triangles(mesh: Mesh) -> Dictionary:
	var out := {}
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vtx: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vtx.size()))
		var list: Array = out.get_or_add(mesh.surface_get_material(surface).resource_name, [])
		for t in range(0, idx.size(), 3):
			var tri := []
			for k in 3:
				var i := idx[t + k]
				tri.append([vtx[i], arrays[Mesh.ARRAY_TEX_UV][i], arrays[Mesh.ARRAY_NORMAL][i], str(vtx[i].snappedf(0.01))])
			var keys := [tri[0][3], tri[1][3], tri[2][3]]
			keys.sort()
			list.append(["".join(keys), tri])
	return out

func _same_triangles(a: Dictionary, b: Dictionary) -> bool:
	if a.keys() != b.keys(): return false
	for name: String in a:
		var x: Array = a[name]
		var y: Array = b[name]
		if x.size() != y.size(): return false
		var left := {}   # coarse key -> unmatched triangles of b
		for t: Array in y: (left.get_or_add(t[0], []) as Array).append(t[1])
		for t: Array in x:
			var found := false
			for bucket: Array in ([left.get(t[0], [])] + left.values()):
				for i in bucket.size():
					if _close(t[1], bucket[i]):
						bucket.remove_at(i)
						found = true
						break
				if found: break
			if not found: return false
	return true

## The same triangle with the same winding: q may start at any of its corners.
func _close(p: Array, q: Array) -> bool:
	for r in 3:
		var same := true
		for k in 3:
			for f in 3:
				if (p[k][f] - q[(k + r) % 3][f]).length() > 0.001: same = false
		if same: return true
	return false
