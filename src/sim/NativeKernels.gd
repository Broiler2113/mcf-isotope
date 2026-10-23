class_name NativeKernels
extends RefCounted

## Pure CPU kernels. Missing libraries use the original algorithms without changing rules.
## Set MCF_NATIVE_KERNELS=off to compare a whole match with the GDScript reference.
static var enabled := OS.get_environment("MCF_NATIVE_KERNELS") != "off"
static var _terrain: RefCounted
static var _pathfinding: RefCounted
static var _ai: RefCounted
static var _visibility: RefCounted
static var _terrain_checked := false
static var _pathfinding_checked := false
static var _ai_checked := false
static var _visibility_checked := false

static func _load_kernel(type_name: String) -> RefCounted:
	if not ClassDB.class_exists(type_name): return null
	var kernel: RefCounted = ClassDB.instantiate(type_name)
	if kernel != null and kernel.has_method("api_version") and kernel.call("api_version") == 1:
		return kernel
	push_warning("Native kernel %s has an incompatible API; using GDScript." % type_name)
	return null

static func terrain() -> RefCounted:
	if not enabled: return null
	if not _terrain_checked:
		_terrain = _load_kernel("MCFTerrain")
		_terrain_checked = true
	return _terrain

static func pathfinding() -> RefCounted:
	if not enabled: return null
	if not _pathfinding_checked:
		_pathfinding = _load_kernel("MCFPathfinding")
		_pathfinding_checked = true
	return _pathfinding

static func ai() -> RefCounted:
	if not enabled: return null
	if not _ai_checked:
		_ai = _load_kernel("MCFAI")
		_ai_checked = true
	return _ai

static func visibility() -> RefCounted:
	if not enabled: return null
	if not _visibility_checked:
		_visibility = _load_kernel("MCFVisibility")
		_visibility_checked = true
	return _visibility
