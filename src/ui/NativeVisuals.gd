class_name NativeVisuals
extends RefCounted

## Native geometry loads automatically from the bundled desktop library at startup.
## Missing or incompatible libraries retain the original GDScript implementation.
## MCF_NATIVE_VISUALS=off selects the reference implementation for comparison.
static var enabled := OS.get_environment("MCF_NATIVE_VISUALS") != "off"
static var _checked := false
static var _available := false

static func mesh_builder() -> RefCounted:
	if not enabled: return null
	if not _checked:
		_checked = true
		_available = ClassDB.class_exists("MCFMeshBuilder")
		if _available:
			var probe: RefCounted = ClassDB.instantiate("MCFMeshBuilder")
			_available = probe.has_method("api_version") and probe.call("api_version") == 1
			if not _available: push_warning("Native visuals have an incompatible API; using GDScript geometry.")
	return ClassDB.instantiate("MCFMeshBuilder") if _available else null
