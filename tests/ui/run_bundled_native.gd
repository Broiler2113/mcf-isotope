extends "res://tests/SuiteBase.gd"

func run() -> void:
	var report := NativeAcceleration.status()
	var args := OS.get_cmdline_user_args()
	if "--expect-disabled" in args:
		ck(report.state == "disabled" and report.active_count == 0, "reference switches disable all native dispatch")
		ck(NativeKernels.pathfinding() == null and NativeVisuals.mesh_builder() == null, "disabled mode uses the original algorithms")
		return
	if "--expect-fallback" in args:
		ck(report.state == "fallback" and report.active_count == 0, "missing or invalid bundle keeps the game playable through the reference path")
		return
	ck(report.state == "active" and report.active_count == NativeAcceleration.CLASSES.size(),
			"all %d native systems activate automatically at startup" % NativeAcceleration.CLASSES.size())
	if "--require-bundled" in args:
		ck(report.source == "bundled", "a fresh download uses the shipped library without a local build")
	if "--require-local" in args:
		ck(report.source == "local", "a locally built extension takes precedence without duplicate registration")
	var kernels: Array = [NativeVisuals.mesh_builder(), NativeKernels.terrain(), NativeKernels.ai(), NativeKernels.pathfinding(), NativeKernels.visibility()]
	for kernel: Variant in kernels:
		ck(kernel != null and kernel.call("api_version") == 1, "native dispatcher returns a compatible loaded kernel")
	var paths := GDExtensionManager.get_loaded_extensions()
	var count := 0
	for path: String in paths:
		if path.get_file() == "mcf_visuals.gdextension": count += 1
	ck(count == 1, "exactly one game-kernel library is loaded")
	var before := paths.duplicate()
	NativeAcceleration.initialize()
	ck(GDExtensionManager.get_loaded_extensions() == before, "initialization is idempotent")
	print("Automatic native startup: %s, %d/%d systems, source=%s" % [report.target, report.active_count, report.total_count, report.source])
