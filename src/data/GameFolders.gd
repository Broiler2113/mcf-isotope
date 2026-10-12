class_name GameFolders
extends RefCounted

## Saves, replays, editor maps and editor presets live as plain files in a visible
## "Isotope Data" folder next to the game (0.11), so they can be copied, shared and dropped
## in. Every list reads its folder each time it opens: a file put there by hand simply
## appears — there is no import step.
##
## Where: next to the executable (next to the .app on macOS); the project folder when
## running from source. If that place is read-only (an install in Program Files, a signed
## app bundle) the same layout is created inside the user data folder instead.
## MCF_DATA_DIR overrides the location (tests, portable setups).

const ROOT_NAME := "Isotope Data"
const SAVES := "Saves"
const REPLAYS := "Replays"
const MAPS := "Maps"
const PRESETS := "Presets"

static var _root := ""

static func root() -> String:
	if _root != "":
		return _root
	var custom := OS.get_environment("MCF_DATA_DIR")
	if custom != "":
		_root = custom
		DirAccess.make_dir_recursive_absolute(_root)
		return _root
	var base := ""
	if OS.has_feature("template"):
		base = OS.get_executable_path().get_base_dir()
		if base.ends_with(".app/Contents/MacOS"):
			base = base.get_base_dir().get_base_dir().get_base_dir()
	else:
		base = ProjectSettings.globalize_path("res://")
	var candidate := base.path_join(ROOT_NAME)
	_root = candidate if _writable(candidate) else OS.get_user_data_dir().path_join(ROOT_NAME)
	DirAccess.make_dir_recursive_absolute(_root)
	# Running from source the folder sits inside the project (0.11.1): without .gdignore the
	# Godot editor rescans every save and replay on each run and an export could pack them.
	if not OS.has_feature("template") and not FileAccess.file_exists(_root.path_join(".gdignore")):
		var f := FileAccess.open(_root.path_join(".gdignore"), FileAccess.WRITE)
		if f != null: f.close()
	return _root

static func dir(kind: String) -> String:
	var d := root().path_join(kind)
	DirAccess.make_dir_recursive_absolute(d)
	return d

static func _writable(path: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(path) != OK:
		return false
	var probe := path.path_join(".write-test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true

## One-time adoption of files saved before 0.11 in the hidden user folder. Copies only what
## is missing and never overwrites; the old files stay where they were.
const ADOPTED_MARKER := "user://.adopted_isotope_data"

static func adopt_user_data() -> int:
	# Once per installation: a save deleted from the shared folder must not come back.
	if FileAccess.file_exists(ADOPTED_MARKER):
		return 0
	var n := 0
	for pair: Array in [["user://saves", SAVES], ["user://replays", REPLAYS], ["user://maps", MAPS],
			["user://room_presets", PRESETS]]:
		var src := DirAccess.open(pair[0])
		if src == null:
			continue
		var dst := dir(pair[1])
		if ProjectSettings.globalize_path(pair[0]) == dst:
			continue
		for file_name: String in src.get_files():
			if file_name.ends_with(".note") or file_name.ends_with(".tmp"):
				continue
			var to := dst.path_join(file_name)
			if not FileAccess.file_exists(to) \
					and DirAccess.copy_absolute(ProjectSettings.globalize_path(pair[0]).path_join(file_name), to) == OK:
				n += 1
	var marker := FileAccess.open(ADOPTED_MARKER, FileAccess.WRITE)
	if marker != null:
		marker.store_string(root())
		marker.close()
	return n
