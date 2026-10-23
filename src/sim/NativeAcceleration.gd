class_name NativeAcceleration
extends Node

## Load the bundled, matching desktop library before any simulation or worker runs.
## The ignored bundle is loaded explicitly so unsupported systems still open normally.
const BUNDLE_ROOT := "res://addons/mcf_visuals/prebuilt"
const CLASSES := ["MCFMeshBuilder", "MCFTerrain", "MCFAI", "MCFPathfinding", "MCFVisibility"]
const LIBRARIES := {"windows": "mcf_visuals.dll", "macos": "mcf_visuals.dylib"}
const SOURCE_CONFIG := ["native/visuals/CMakeLists.txt", "native/visuals/build_profile.json",
	"native/visuals/build.py", "native/policy/dependencies.json", "addons/mcf_visuals/mcf_visuals.gdextension.in"]
const REQUIRED_SOURCES := ["native/visuals/src/mesh_builder.cpp", "native/visuals/src/terrain_kernel.cpp",
	"native/visuals/src/ai_kernel.cpp", "native/visuals/src/pathfinding_kernel.cpp", "native/visuals/src/visibility_kernel.cpp"]

static var _initialized := false
static var _available: Dictionary = {}
static var _source := "none"
static var _reason := "missing"

func _init() -> void:
	initialize()

static func platform_target(system: String = OS.get_name(), architecture: String = Engine.get_architecture_name()) -> String:
	var platform: String = {"Windows": "windows", "macOS": "macos"}.get(system, "")
	if platform.is_empty() or architecture not in ["x86_64", "arm64"]: return ""
	return platform + "-" + architecture

static func initialize() -> void:
	if _initialized or Engine.is_editor_hint(): return
	_initialized = true
	# A locally compiled extension may already have been registered by Godot. Never
	# register another copy, even if an old developer build only supplies some classes.
	for type_name: String in CLASSES:
		if ClassDB.class_exists(type_name):
			_source = "local"
			_probe()
			return
	if OS.get_environment("MCF_NATIVE_VISUALS") == "off" and OS.get_environment("MCF_NATIVE_KERNELS") == "off":
		_reason = "disabled"
		return
	var target := platform_target()
	var checked := validate_bundle(BUNDLE_ROOT, target)
	_reason = checked.code
	if not checked.valid: return
	var extension_path := ProjectSettings.globalize_path(checked.extension)
	var result := GDExtensionManager.load_extension(extension_path)
	if result not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
		_reason = "restart" if result == GDExtensionManager.LOAD_STATUS_NEEDS_RESTART else "load"
		return
	_source = "bundled"
	_probe()

static func _probe() -> void:
	for type_name: String in CLASSES:
		var available := false
		if ClassDB.class_exists(type_name) and ClassDB.can_instantiate(type_name):
			var instance: RefCounted = ClassDB.instantiate(type_name)
			available = instance != null and instance.has_method("api_version") and instance.call("api_version") == 1
		_available[type_name] = available
	_reason = "api" if _available.values().has(false) else "ok"

## Read-only snapshot used by Settings. It never downloads or loads executable code.
static func status() -> Dictionary:
	var count := 0
	for type_name: String in CLASSES:
		var enabled: bool = NativeVisuals.enabled if type_name == "MCFMeshBuilder" else NativeKernels.enabled
		if enabled and _available.get(type_name, false): count += 1
	var state := "fallback"
	var title := "C++ acceleration unavailable"
	var detail := "The game is using its standard implementation."
	if count == CLASSES.size():
		state = "active"
		title = "C++ acceleration active"
		detail = "All performance improvements are enabled automatically."
	elif count > 0:
		state = "partial"
		title = "C++ acceleration partly active"
		detail = "%d of %d accelerated systems are available. The remaining systems use their standard implementation." % [count, CLASSES.size()]
	elif not NativeVisuals.enabled and not NativeKernels.enabled:
		state = "disabled"
		title = "C++ acceleration disabled"
		detail = "Acceleration was disabled for this launch. The game uses its standard implementation."
	elif _reason == "unsupported":
		detail = "This device uses the standard implementation. Gameplay remains available."
	elif _reason == "restart":
		detail = "Close and reopen the game to finish enabling acceleration."
	elif _reason in ["missing", "invalid", "corrupt", "source"]:
		detail = "Performance files are missing or do not match this copy of the game. Download a fresh copy to restore acceleration."
	elif _reason in ["load", "api"]:
		detail = "The performance library could not be used on this device. The game continues with its standard implementation."
	return {"state": state, "title": title, "detail": detail, "active_count": count,
		"total_count": CLASSES.size(), "source": _source, "target": platform_target(), "reason": _reason}

static func _failure(code: String) -> Dictionary:
	return {"valid": false, "code": code, "extension": ""}

static func _sha256(value: Variant) -> bool:
	if not value is String or value.length() != 64: return false
	for letter: String in value:
		if letter not in "0123456789abcdef": return false
	return true

static func _source_path(path: String) -> bool:
	if path in SOURCE_CONFIG: return true
	if not path.begins_with("native/visuals/src/"): return false
	if path.contains("\\") or path.contains(":") or path.contains("//"): return false
	for component: String in path.split("/"):
		if component in [".", "..", ""]: return false
	return path.ends_with(".cpp") or path.ends_with(".h") or path.ends_with(".hpp")

## Validation is separate from loading so malformed or incomplete downloads can be
## tested without ever passing them to the native loader. Source hashes normalize
## CRLF checkouts; binary and extension-manifest hashes always use the exact bytes.
static func validate_bundle(root: String, target: String, source_root: String = "res://") -> Dictionary:
	if target not in ["windows-x86_64", "macos-x86_64", "macos-arm64"]:
		return _failure("unsupported")
	var manifest_path := root.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path): return _failure("missing")
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null: return _failure("missing")
	if file.get_length() > 131072: return _failure("invalid")
	var json := JSON.new()
	var parse_result := json.parse(file.get_as_text())
	file.close()
	if parse_result != OK: return _failure("invalid")
	var parsed: Variant = json.data
	if not parsed is Dictionary: return _failure("invalid")
	var manifest: Dictionary = parsed
	if manifest.get("schema") != 1 or not _sha256(manifest.get("source_fingerprint")):
		return _failure("invalid")
	if not manifest.get("source_files") is Dictionary or not manifest.get("platforms") is Dictionary:
		return _failure("invalid")
	var sources: Dictionary = manifest.source_files
	if sources.size() > 128: return _failure("invalid")
	for path: String in SOURCE_CONFIG + REQUIRED_SOURCES:
		if not sources.has(path): return _failure("invalid")
	var paths: Array = sources.keys()
	for path: Variant in paths:
		if not path is String or not _source_path(path) or not _sha256(sources[path]): return _failure("invalid")
	paths.sort()
	var fingerprint := HashingContext.new()
	fingerprint.start(HashingContext.HASH_SHA256)
	for path: String in paths:
		var source := FileAccess.open(source_root.path_join(path), FileAccess.READ)
		if source == null or source.get_length() > 4194304: return _failure("source")
		var text := source.get_as_text().replace("\r\n", "\n")
		source.close()
		if text.sha256_text() != sources[path]: return _failure("source")
		fingerprint.update(path.to_utf8_buffer())
		fingerprint.update(PackedByteArray([0]))
		fingerprint.update((str(sources[path]) + "\n").to_utf8_buffer())
	if fingerprint.finish().hex_encode() != manifest.source_fingerprint: return _failure("invalid")
	if not manifest.platforms.get(target) is Dictionary: return _failure("missing")
	var platform: Dictionary = manifest.platforms[target]
	var library_name: String = LIBRARIES[target.get_slice("-", 0)]
	var library := target.path_join(library_name)
	var extension := target.path_join("mcf_visuals.gdextension")
	if platform.get("library") != library or platform.get("extension") != extension:
		return _failure("invalid")
	if not _sha256(platform.get("sha256")) or not _sha256(platform.get("extension_sha256")):
		return _failure("invalid")
	var library_path := root.path_join(library)
	var extension_path := root.path_join(extension)
	if not FileAccess.file_exists(library_path) or not FileAccess.file_exists(extension_path): return _failure("missing")
	if FileAccess.get_sha256(library_path) != platform.sha256 or FileAccess.get_sha256(extension_path) != platform.extension_sha256:
		return _failure("corrupt")
	# The only permissible executable path is the verified sibling library. Do not
	# accept extra library entries, dependencies, or a modified initialization symbol.
	var config := ConfigFile.new()
	if config.load(extension_path) != OK: return _failure("invalid")
	if config.get_sections().size() != 2 or not config.has_section("configuration") or not config.has_section("libraries"):
		return _failure("invalid")
	if config.get_value("configuration", "entry_symbol", "") != "mcf_visuals_init" or config.get_value("configuration", "reloadable", true) != false:
		return _failure("invalid")
	var feature := target.replace("-", ".")
	if config.get_section_keys("libraries").size() != 1 or config.get_value("libraries", feature, "") != library_name:
		return _failure("invalid")
	return {"valid": true, "code": "ok", "extension": extension_path}
