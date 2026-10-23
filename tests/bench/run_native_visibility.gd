extends SceneTree

func _initialize() -> void:
	if NativeKernels.visibility() == null:
		printerr("Build native kernels before benchmarking.")
		quit(1)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 61824
	for density: float in [0.0, 0.08]:
		var mask := PackedByteArray()
		mask.resize(180 * 160)
		for i in mask.size(): mask[i] = 1 if rng.randf() < density else 0
		var transposed := GameActionResolver._transpose_reference(mask, 180, 160)
		var timings := [[], []]
		for run in 6:
			for use_native in [run % 2 == 0, run % 2 != 0]:
				NativeKernels.enabled = use_native
				var start := Time.get_ticks_usec()
				var checksum := 0
				for eye in 20:
					var result := GameActionResolver._sweep(60 + eye, 60 + eye % 7, 180, mask, 180, 160, transposed)
					checksum += result[0].size() + result[1].size()
				if run > 0: timings[int(use_native)].append((Time.get_ticks_usec() - start) / 1000.0)
				if checksum <= 0: quit(1); return
		for values: Array in timings: values.sort()
		print("Visibility 20 full-board eyes, density %.2f: GDScript %.2f ms, C++ %.2f ms (%.2fx)" % [density, timings[0][2], timings[1][2], timings[0][2] / timings[1][2]])
	NativeKernels.enabled = true
	quit()
