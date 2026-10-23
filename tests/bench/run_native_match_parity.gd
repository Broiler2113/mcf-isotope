extends "res://tests/bench/run_bench.gd"

## Compare every signature field on the same engine build, including cosmetics.
## The original Linux effects hash differs on Windows even when gameplay matches.
func _run() -> void:
	if NativeKernels.pathfinding() == null or NativeKernels.ai() == null or NativeKernels.visibility() == null:
		printerr("Build native kernels before running match parity.")
		quit(1)
		return
	var expected := _read_expected()
	for name: String in ["small", "medium"]:
		NativeKernels.enabled = false
		NativeVisuals.enabled = false
		seed(731846)
		var reference := _run_scene(name, SCENES[name])
		NativeKernels.enabled = true
		NativeVisuals.enabled = true
		seed(731846)
		var native := _run_scene(name, SCENES[name])
		if reference.sig != native.sig or reference.rules_hash != native.rules_hash:
			_fails.append("%s native/reference mismatch\n    reference %s\n    native    %s" % [name, reference.sig, native.sig])
		# Keep the historical gameplay baseline, while comparing Windows' own full
		# effects hash above. Never regenerate or weaken the checked-in fixtures.
		var baseline: String = expected.get(name, "")
		var actual: String = reference.sig
		if OS.get_name() == "Windows":
			baseline = _without_fx(baseline)
			actual = _without_fx(actual)
		if baseline != actual:
			_fails.append("%s original gameplay baseline changed\n    expected %s\n    got      %s" % [name, baseline, actual])
		print("Native/reference %s: %s" % [name, reference.sig])
	if _fails.is_empty():
		print("Native and GDScript matches agree on every signature field, including local effects; historical gameplay baselines unchanged.")
	else:
		for failure in _fails: printerr("FAIL " + failure)
	quit(0 if _fails.is_empty() else 1)

func _without_fx(signature: String) -> String:
	var field := RegEx.new()
	field.compile(" fx=[0-9]+")
	return field.sub(signature, " fx=<platform>")
