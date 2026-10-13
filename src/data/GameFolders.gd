class_name GameFolders
extends RefCounted

## Saves, replays, editor maps and editor presets live as plain files in their own folders
## right in the game folder — "Saves", "Replays", "Maps" and "Presets" next to the game
## (0.12, owner: "in the actual game folder and not in some other one"; 0.11 kept them one
## level down in "Isotope Data"). Every list reads its folder each time it opens: a file put
## there by hand simply appears — there is no import step.
##
## The game folder: next to the executable (next to the .app on macOS); the project folder
## when running from source. Only if that place is read-only (an install in Program Files,
## a signed or translocated app) does the same layout go into the user data folder instead.
## MCF_DATA_DIR overrides the location (tests, portable setups).

const SAVES := "Saves"
const REPLAYS := "Replays"
const MAPS := "Maps"
const PRESETS := "Presets"
const KINDS := [SAVES, REPLAYS, MAPS, PRESETS]
## 0.11–0.11.3 kept the four folders inside this one; adopt_isotope_data() moves them up.
const LEGACY_ROOT := "Isotope Data"

static var _root := ""

## The game folder itself (or the override / read-only fallback).
static func root() -> String:
	if _root != "":
		return _root
	var custom := OS.get_environment("MCF_DATA_DIR")
	if custom != "":
		_root = custom
		DirAccess.make_dir_recursive_absolute(_root)
		return _root
	var base := game_dir()
	_root = base if _writable(base.path_join(SAVES)) else OS.get_user_data_dir()
	return _root

## Where the game is: the executable's folder (the .app's folder on macOS) or, from source,
## the project folder.
static func game_dir() -> String:
	if OS.has_feature("template"):
		var base := OS.get_executable_path().get_base_dir()
		if base.ends_with(".app/Contents/MacOS"):
			base = base.get_base_dir().get_base_dir().get_base_dir()
		return base
	return ProjectSettings.globalize_path("res://").rstrip("/")

static func dir(kind: String) -> String:
	var d := root().path_join(kind)
	DirAccess.make_dir_recursive_absolute(d)
	# From source the folders sit inside the project: without .gdignore the Godot editor
	# rescans every save and replay on each run, and an export could pack them.
	if not OS.has_feature("template") and not FileAccess.file_exists(d.path_join(".gdignore")):
		var f := FileAccess.open(d.path_join(".gdignore"), FileAccess.WRITE)
		if f != null: f.close()
	return d

## Move files saved by 0.11–0.11.3 from "<game>/Isotope Data/<kind>" (and the same under
## the user data folder) into "<game>/<kind>". Never overwrites; a file that already exists
## in the new place stays where it was. Emptied old folders are removed. Returns how many
## files moved.
static func adopt_isotope_data() -> int:
	var moved := 0
	for old_root: String in [game_dir().path_join(LEGACY_ROOT), OS.get_user_data_dir().path_join(LEGACY_ROOT)]:
		if not DirAccess.dir_exists_absolute(old_root) or old_root == root():
			continue
		for kind: String in KINDS:
			var src := old_root.path_join(kind)
			if not DirAccess.dir_exists_absolute(src):
				continue
			var dst := dir(kind)
			for file_name: String in _files(src):
				if file_name == ".gdignore":
					continue
				var to := dst.path_join(file_name)
				if FileAccess.file_exists(to):
					# A hidden marker (".builtins-seeded") already in the new place: the old copy
					# is redundant. A real file with the same name is kept, never overwritten.
					if file_name.begins_with("."):
						DirAccess.remove_absolute(src.path_join(file_name))
					continue
				var from := src.path_join(file_name)
				if DirAccess.rename_absolute(from, to) == OK \
						or (DirAccess.copy_absolute(from, to) == OK and DirAccess.remove_absolute(from) == OK):
					moved += 1
			_remove_if_empty(src)
		_remove_if_empty(old_root)
	return moved

## Files of a folder, hidden ones included (DirAccess.get_files_at skips them).
static func _files(path: String) -> PackedStringArray:
	var d := DirAccess.open(path)
	if d == null:
		return PackedStringArray()
	d.include_hidden = true
	return d.get_files()

## Remove a folder that holds nothing but a .gdignore.
static func _remove_if_empty(path: String) -> void:
	if not DirAccess.get_directories_at(path).is_empty():
		return
	for f: String in _files(path):
		if f != ".gdignore":
			return
	DirAccess.remove_absolute(path.path_join(".gdignore"))
	DirAccess.remove_absolute(path)

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
