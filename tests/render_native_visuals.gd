extends "res://tests/SuiteBase.gd"

func run() -> void:
	if DisplayServer.get_name() == "headless": ck(false, "requires rendered display"); return
	ck(NativeVisuals.mesh_builder() != null, "native extension is loaded for rendered comparison")
	if not fails.is_empty(): return
	root.size = Vector2i(960, 640)
	var ui := root.get_node("Ui")
	ui.fp_render_distance = 160
	ui.snowfall = false
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	for style in [MapGen.Style.TOWN, MapGen.Style.STATION]:
		var map := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM,
			"width": 32, "height": 24, "seed": 83, "units": 24, "furniture": 3, "winter": false})
		NativeVisuals.enabled = false
		FirstPersonModels._cache.clear()
		var grid := Grid.new(map.width, map.height)
		map.apply_to_grid(grid)
		var host := FirstPersonHost.new(map, TerrainTiles.new(grid, map.environment()))
		host.state.time_of_day = "day"
		root.add_child(host)
		var before := host.state.digest_hash()
		var fp: Node = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(map.width / 2, map.height / 2))
		root.add_child(fp)
		fp.set_process(false)
		fp._stream_chunks(60000000)
		fp.pos = Vector3(map.width * 0.5, 3.0, map.height * 0.5)
		fp.yaw = 0.37
		fp.pitch = -0.24
		fp._place_camera()
		var reference := await picture(fp)
		reference.save_png("/tmp/isotope-native-%d-gdscript.png" % style)
		NativeVisuals.enabled = true
		FirstPersonModels._cache.clear()
		# Keep the same viewport, lights and instance order. Recreating a whole
		# world can change coplanar/shadow edge pixels even between two GDScript runs.
		# Replace each mesh with an independently generated native mesh instead.
		for cc: Vector2i in fp._chunks:
			var ctx: Dictionary = fp._chunk_context()
			var tcc := Vector2i(cc.x * FirstPersonBoard.CH / TerrainTiles.C, cc.y * FirstPersonBoard.CH / TerrainTiles.C)
			ctx["decals"] = host._tiles.decals.get(tcc, [])
			ctx["map_decals"] = host._tiles.map_decals.get(tcc, [])
			var native := FirstPersonBoard.build(grid, cc, fp._roof, ctx)
			var expected: Array = fp._chunks[cc].node.find_children("*", "MeshInstance3D", true, false)
			var actual: Array = native.node.find_children("*", "MeshInstance3D", true, false)
			ck(expected.size() == actual.size(), "chunk instance count is unchanged")
			for i in mini(expected.size(), actual.size()):
				compare_meshes(expected[i].mesh, actual[i].mesh, "%s/%s/%d" % [style, cc, i])
				expected[i].mesh = actual[i].mesh
			native.node.free()
		var current := await picture(fp)
		current.save_png("/tmp/isotope-native-%d-cpp.png" % style)
		ck(reference.get_data() == current.get_data(), "complete %s scene matches pixel-for-pixel" % MapGen.STYLE_NAMES[style])
		ck(host.state.digest_hash() == before, "rendering preserves simulation state")
		fp.free()
		host.free()
		await process_frame
	NativeVisuals.enabled = true

func picture(fp: Node) -> Image:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	return fp._vp.get_texture().get_image()

func compare_meshes(expected: Mesh, actual: Mesh, label: String) -> void:
	ck((expected == null) == (actual == null), "empty meshes agree: " + label)
	if expected == null or actual == null: return
	ck(expected.get_surface_count() == actual.get_surface_count(), "surface count agrees: " + label)
	for surface in mini(expected.get_surface_count(), actual.get_surface_count()):
		var a := expected.surface_get_arrays(surface)
		var b := actual.surface_get_arrays(surface)
		for channel in Mesh.ARRAY_MAX:
			if a[channel] == null or b[channel] == null:
				ck(a[channel] == b[channel], "empty mesh channel agrees: " + label)
			else:
				ck(a[channel].to_byte_array() == b[channel].to_byte_array(), "mesh channel agrees: %s/%d" % [label, channel])
