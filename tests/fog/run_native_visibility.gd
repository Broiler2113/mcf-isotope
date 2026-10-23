extends "res://tests/SuiteBase.gd"

func run() -> void:
	var native := NativeKernels.visibility()
	if native == null:
		ck(not OS.get_cmdline_user_args().has("--require-native"), "compiled visibility kernel loads")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 846271
	for sample in 360:
		var w := rng.randi_range(1, 42)
		var h := rng.randi_range(1, 35)
		var mask := PackedByteArray()
		mask.resize(w * h)
		var blockers := PackedInt32Array()
		for i in mask.size():
			mask[i] = 1 if rng.randf() < [0.0, 0.03, 0.2, 0.6, 1.0][sample % 5] else 0
			if mask[i] == 1: blockers.append(i)
		var transposed := GameActionResolver._transpose_reference(mask, w, h)
		ck(native.transpose(mask, w, h) == transposed, "mask transpose %d" % sample)
		for point: Vector2i in [Vector2i.ZERO, Vector2i(w - 1, h - 1), Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))]:
			for radius in [0, 1, rng.randi_range(2, 9), maxi(w, h)]:
				var original := GameActionResolver._sweep_reference(point.x, point.y, radius, mask, w, h, transposed)
				var actual: Array = native.sweep(point.x, point.y, radius, mask, w, h, transposed)
				ck(actual == original, "visible and sensitivity indices %d/%s/r%d" % [sample, point, radius])
				if not fails.is_empty(): return
			var shadow := GameActionResolver._sweep_hidden_reference(point.x, point.y, mask, w, h, transposed, blockers)
			ck(native.hidden(point.x, point.y, mask, w, h, transposed, blockers) == shadow, "ordered hidden cells %d/%s" % [sample, point])
			if not fails.is_empty(): return
	_merge_parity()
	ck(native.sweep(0, 0, 3, PackedByteArray([0]), 2, 2, PackedByteArray()).is_empty(), "malformed masks are rejected")
	print("Native visibility: 4,320 exact visible/sensitivity sweeps, 1,080 ordered shadow sweeps, and incremental merges agree.")

func _merge_parity() -> void:
	var state := MapData.blank_arena(12, 12).build_state(12)
	var resolver := GameActionResolver.new(state)
	var reference_counts := PackedInt32Array()
	reference_counts.resize(144)
	var native_counts := reference_counts.duplicate()
	var reference_visible := {}
	var native_visible := {}
	var reference_memory := {}
	var native_memory := {}
	var reference_log := []
	var native_log := []
	for cells: PackedInt32Array in [PackedInt32Array([0, 3, 25, 26, 50]), PackedInt32Array([3, 25, 42, 50, 51]), PackedInt32Array([0, 0, 3])]:
		reference_counts = resolver._vis_add_reference(cells, reference_counts, reference_visible, reference_memory, 12, reference_log)
		native_counts = NativeKernels.visibility().merge_visibility(cells, native_counts, native_visible, native_memory, 12, native_log, true)
		ck(reference_counts == native_counts and reference_visible.keys() == native_visible.keys() and reference_memory.keys() == native_memory.keys() and reference_log == native_log,
				"incremental additions preserve counts, insertion order, exploration and change log")
	for cells: PackedInt32Array in [PackedInt32Array([0, 3, 25, 26, 50]), PackedInt32Array([3, 25, 42, 50, 51]), PackedInt32Array([0, 0, 3])]:
		reference_counts = resolver._vis_drop_reference(cells, reference_counts, reference_visible, 12, reference_log)
		native_counts = NativeKernels.visibility().merge_visibility(cells, native_counts, native_visible, {}, 12, native_log, false)
		ck(reference_counts == native_counts and reference_visible.keys() == native_visible.keys() and reference_log == native_log,
				"incremental removals preserve counts, insertion order and change log")
	ck(native_visible.is_empty() and native_memory.size() == 7, "removing all eyes preserves explored memory")
