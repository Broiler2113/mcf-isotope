extends "res://tests/SuiteBase.gd"

func run() -> void:
	var probe := NativeVisuals.mesh_builder()
	if probe == null:
		ck(not OS.get_cmdline_user_args().has("--require-native"), "native visual library must load")
		var fallback := FirstPersonModels.Sink.new()
		fallback.box(Vector3.ZERO, Vector3.ONE, 0, Color.WHITE)
		ck(fallback.v.size() == 36, "source-only checkout builds geometry through GDScript")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 823719
	for i in 128:
		var basis := Basis.from_euler(Vector3(rng.randf_range(-PI, PI), rng.randf_range(-PI, PI), rng.randf_range(-PI, PI)))
		basis = basis.scaled(Vector3(-1.0 if i % 5 == 0 else 0.7, 1.3, 0.9))
		var transform := Transform3D(basis, Vector3(rng.randf_range(-200, 200), rng.randf_range(-2, 2), rng.randf_range(-200, 200)))
		var color := Color(rng.randf(), rng.randf(), rng.randf(), [0.25, 0.5, 0.51, 1.0][i % 4])
		var pair := [FirstPersonModels.Sink.new(false), FirstPersonModels.Sink.new(true)]
		for sink: FirstPersonModels.Sink in pair:
			sink.xf = transform
			sink.shade_floor = i % 3 != 0
			sink.box(Vector3(-0.3, -0.2, 0.1), Vector3(0.7, 1.5, 0.6), i % 29, color, i % 64)
			sink.face([Vector3(0, 0, 0), Vector3(1, 0.32, 0), Vector3(1, 0.32, 1), Vector3(0, 0, 1)], Vector3.UP, 4, color)
			sink.face_uv([Vector3.ZERO, Vector3.RIGHT, Vector3.BACK], Vector3.UP, [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE], color)
			sink.cyl(Vector3.ZERO, 0.5, 0.3, 1.2, 2, color, 3 + i % 9, i % 4, 0.7)
			sink.blob(Vector3.ZERO, Vector3(0.6, 0.4, 0.7), 3, color, i)
			var poly := PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(0.8, 1), Vector2(-1, 0.6)])
			if i % 2 == 0: poly.reverse()
			sink.prism(poly, -0.1, 0.4, 5, color)
		compare(pair[0].arrays(), pair[1].arrays(), "transformed primitives %d" % i)
		if not fails.is_empty(): break
	for fid: String in Furniture.ids():
		var dims: Array = Furniture.sizes_of(fid)[0]
		for variant in 2:
			var reference := [FirstPersonModels.Sink.new(false), FirstPersonModels.Sink.new(false)]
			var native := [FirstPersonModels.Sink.new(true), FirstPersonModels.Sink.new(true)]
			var ctx := {"seed": variant * 719, "art": Color(0.31, 0.67, 0.84), "cap": 3.0,
				"jl": variant == 1, "jr": variant == 1, "lit": variant == 0, "opened": variant == 1}
			FirstPersonModels.furniture(reference[0], reference[1], fid, dims[0], dims[1], ctx)
			FirstPersonModels.furniture(native[0], native[1], fid, dims[0], dims[1], ctx)
			for channel in 2: compare(reference[channel].arrays(), native[channel].arrays(), "furniture %s/%d/%d" % [fid, variant, channel])
		if not fails.is_empty(): break
	var source := FirstPersonModels.Sink.new(false)
	source.box(Vector3.ZERO, Vector3(2, 1, 2), 4, Color(0.4, 0.7, 0.9))
	var mesh := source.mesh()
	for rect: Rect2 in [Rect2(0.3, 0.2, 1.0, 1.0), Rect2(0, 0, 1, 2), Rect2(8, 8, 1, 1)]:
		NativeVisuals.enabled = false
		var reference := FirstPersonModels.clipped(mesh, rect)
		NativeVisuals.enabled = true
		var native := FirstPersonModels.clipped(mesh, rect)
		ck((reference == null) == (native == null), "clipped empty geometry agrees")
		if reference != null and native != null: compare(reference.surface_get_arrays(0), native.surface_get_arrays(0), "damaged-piece clipping")
	var before: Array = probe.arrays()
	ck(not probe.face([Vector3.ZERO, "invalid", Vector3.ONE], Vector3.UP, 0, Color.WHITE, Transform3D.IDENTITY, true), "invalid native input is rejected")
	compare(before, probe.arrays(), "rejected call cannot partially change geometry")
	NativeVisuals.enabled = false
	ck(FirstPersonModels.Sink.new()._native == null, "reference backend can be explicitly selected")
	NativeVisuals.enabled = true
	print("Compared raw vertex, normal, UV, material and color bytes across 128 transformed primitive sets and the furniture catalog.")

func compare(expected: Array, actual: Array, label: String) -> void:
	for channel in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR]:
		var same: bool = expected[channel].to_byte_array() == actual[channel].to_byte_array()
		ck(same, "%s channel %d matches byte-for-byte" % [label, channel])
		if not same:
			for i in mini(expected[channel].size(), actual[channel].size()):
				if expected[channel][i] != actual[channel][i]:
					print("  first mismatch %d: %s / %s" % [i, expected[channel][i], actual[channel][i]])
					break
