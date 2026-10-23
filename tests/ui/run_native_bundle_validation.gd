extends "res://tests/SuiteBase.gd"

var fixture_root := "user://native-bundle-validation"
var source_root := fixture_root.path_join("project")
var bundle_root := fixture_root.path_join("bundle")
var target := "linux-x86_64"
var manifest: Dictionary
var sources: Dictionary

func run() -> void:
	_build_fixture()
	ck(_validate().valid, "a complete matching bundle validates before loading")
	var source_path: String = NativeAcceleration.REQUIRED_SOURCES[0]
	_write(source_root.path_join(source_path), "fixture\r\nsecond line\r\n")
	ck(_validate().valid, "Windows CRLF checkout hashes match the same source")
	_write(source_root.path_join(source_path), "changed source\n")
	ck(_validate().code == "source", "stale binaries are rejected when native source changes")
	_write(source_root.path_join(source_path), "fixture\nsecond line\n")

	_write(bundle_root.path_join(target + "/mcf_visuals.so"), "corrupt bytes")
	ck(_validate().code == "corrupt", "corrupted libraries never reach the extension loader")
	_write(bundle_root.path_join(target + "/mcf_visuals.so"), "test library - never executed")
	var original_extension := FileAccess.get_file_as_string(bundle_root.path_join(target + "/mcf_visuals.gdextension"))
	_write(bundle_root.path_join(target + "/mcf_visuals.gdextension"), original_extension + "# edited\n")
	ck(_validate().code == "corrupt", "modified extension manifests are rejected")
	_write(bundle_root.path_join(target + "/mcf_visuals.gdextension"), original_extension)

	var original: Dictionary = manifest.duplicate(true)
	manifest.platforms[target].library = "../outside.so"
	_save_manifest()
	ck(_validate().code == "invalid", "library paths cannot escape the selected platform")
	manifest = original.duplicate(true)
	manifest.source_files["../outside.cpp"] = "a".repeat(64)
	_save_manifest()
	ck(_validate().code == "invalid", "source paths cannot escape the project")
	manifest = original.duplicate(true)
	manifest.source_fingerprint = "b".repeat(64)
	_save_manifest()
	ck(_validate().code == "invalid", "combined provenance fingerprint must match all source files")
	manifest = original.duplicate(true)
	manifest.source_files.erase(source_path)
	_save_manifest()
	ck(_validate().code == "invalid", "a manifest cannot omit a required native source")
	manifest = original.duplicate(true)
	manifest.platforms.erase(target)
	_save_manifest()
	ck(_validate().code == "missing", "missing architecture uses fallback without loading a different one")
	manifest = original.duplicate(true)
	manifest.schema = 99
	_save_manifest()
	ck(_validate().code == "invalid", "unknown bundle schemas cannot execute")
	manifest = original.duplicate(true)
	manifest.source_files = []
	_save_manifest()
	ck(_validate().code == "invalid", "malformed manifest types are rejected")
	_write(bundle_root.path_join("manifest.json"), "not JSON")
	ck(_validate().code == "invalid", "invalid JSON cleanly falls back")
	_write(bundle_root.path_join("manifest.json"), " ".repeat(131073))
	ck(_validate().code == "invalid", "oversized metadata is rejected before parsing")
	manifest = original.duplicate(true)
	_save_manifest()

	# Even a manifest with an updated checksum cannot load an unrelated executable.
	for change: String in ["path", "extra_library", "dependency", "entry"]:
		var config := ConfigFile.new()
		config.load(bundle_root.path_join(target + "/mcf_visuals.gdextension"))
		match change:
			"path": config.set_value("libraries", "linux.x86_64", "../other.so")
			"extra_library": config.set_value("libraries", "linux", "other.so")
			"dependency": config.set_value("dependencies", "linux.x86_64", {"other.so": ""})
			"entry": config.set_value("configuration", "entry_symbol", "other_init")
		config.save(bundle_root.path_join(target + "/mcf_visuals.gdextension"))
		manifest.platforms[target].extension_sha256 = FileAccess.get_sha256(bundle_root.path_join(target + "/mcf_visuals.gdextension"))
		_save_manifest()
		ck(_validate().code == "invalid", "reject unsafe extension configuration: " + change)
		_write(bundle_root.path_join(target + "/mcf_visuals.gdextension"), original_extension)
		manifest = original.duplicate(true)
		_save_manifest()
	ck(NativeAcceleration.validate_bundle(bundle_root, "windows-arm64", source_root).code == "unsupported", "unsupported CPUs use the standard implementation")
	ck(NativeAcceleration.platform_target("macOS", "arm64") == "macos-arm64", "native Apple Silicon selects its own binary")
	ck(NativeAcceleration.platform_target("macOS", "x86_64") == "macos-x86_64", "Intel or Rosetta Godot selects the Intel binary")
	ck(NativeAcceleration.platform_target("Web", "wasm32") == "", "web platforms cannot select desktop code")
	DirAccess.remove_absolute(bundle_root.path_join("manifest.json"))
	ck(_validate().code == "missing", "missing bundle metadata cleanly falls back")
	_remove_fixture(fixture_root)

func _validate() -> Dictionary:
	return NativeAcceleration.validate_bundle(bundle_root, target, source_root)

func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _save_manifest() -> void:
	_write(bundle_root.path_join("manifest.json"), JSON.stringify(manifest))

func _build_fixture() -> void:
	sources = {}
	for path: String in NativeAcceleration.SOURCE_CONFIG + NativeAcceleration.REQUIRED_SOURCES:
		_write(source_root.path_join(path), "fixture\nsecond line\n")
		sources[path] = "fixture\nsecond line\n".sha256_text()
	var ordered: Array = sources.keys()
	ordered.sort()
	var fingerprint := HashingContext.new()
	fingerprint.start(HashingContext.HASH_SHA256)
	for path: String in ordered:
		fingerprint.update(path.to_utf8_buffer())
		fingerprint.update(PackedByteArray([0]))
		fingerprint.update((str(sources[path]) + "\n").to_utf8_buffer())
	_write(bundle_root.path_join(target + "/mcf_visuals.so"), "test library - never executed")
	var config := ConfigFile.new()
	config.set_value("configuration", "entry_symbol", "mcf_visuals_init")
	config.set_value("configuration", "compatibility_minimum", "4.5")
	config.set_value("configuration", "reloadable", false)
	config.set_value("libraries", "linux.x86_64", "mcf_visuals.so")
	config.save(bundle_root.path_join(target + "/mcf_visuals.gdextension"))
	manifest = {"schema": 1, "source_files": sources, "source_fingerprint": fingerprint.finish().hex_encode(),
		"platforms": {target: {"library": target + "/mcf_visuals.so", "extension": target + "/mcf_visuals.gdextension",
			"sha256": FileAccess.get_sha256(bundle_root.path_join(target + "/mcf_visuals.so")),
			"extension_sha256": FileAccess.get_sha256(bundle_root.path_join(target + "/mcf_visuals.gdextension"))}}}
	_save_manifest()

func _remove_fixture(path: String) -> void:
	for child: String in DirAccess.get_directories_at(path): _remove_fixture(path.path_join(child))
	for child: String in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(child))
	DirAccess.remove_absolute(path)
