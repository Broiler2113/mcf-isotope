extends RefCounted

## Reusable editor selections use the same cell tuples as the clipboard.
const DIR := "user://room_presets"

static func _path(name: String) -> String:
	return DIR.path_join(name.strip_edges().validate_filename() + ".json")

static func names() -> Array:
	var out: Array = []
	var dir := DirAccess.open(DIR)
	if dir != null:
		for file: String in dir.get_files():
			if file.ends_with(".json"): out.append(file.get_basename())
	out.sort()
	return out

static func save_preset(name: String, pattern: Dictionary, env: String) -> bool:
	if name.strip_edges().is_empty(): return false
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(_path(name), FileAccess.WRITE)
	if f == null: return false
	f.store_string(JSON.stringify({"schema": 1, "env": env, "pattern": pattern}, "\t"))
	return f.get_error() == OK

static func read_preset(name: String) -> Dictionary:
	var f := FileAccess.open(_path(name), FileAccess.READ)
	if f == null: return {}
	var value: Variant = JSON.parse_string(f.get_as_text())
	if not value is Dictionary: return {}
	var p: Dictionary = value.get("pattern", {})
	var w := int(p.get("w", 0))
	var h := int(p.get("h", 0))
	if w <= 0 or h <= 0 or w > 500 or h > 500 or p.get("cells", []).size() != w * h: return {}
	for cell in p["cells"]:
		if cell != null and (not cell is Array or cell.size() < 5): return {}
	return value

static func remove_preset(name: String) -> Error:
	return DirAccess.remove_absolute(_path(name))

static func to_map(p: Dictionary, env: String) -> MapData:
	var m := MapData.new(int(p["w"]), int(p["h"]))
	m.env = env
	for i in m.width * m.height:
		var t: Variant = p["cells"][i]
		if t == null:
			m.is_space[i] = 1
			continue
		m.floor_type[i] = int(t[0])
		m.cover_height[i] = float(t[1])
		m.is_space[i] = int(bool(t[2]))
		m.feature_id[i] = str(t[3])
		if t.size() > 5: m.set_turn(i, int(t[5]))
		if t.size() > 6: m.set_look(i, int(t[6]))
		if t.size() > 7: m.set_accent(i, int(t[7]))
		if t.size() > 8: m.set_door(i, int(t[8]))
	for spawn: Array in p.get("spawns", []):
		m.set_spawn(Vector2i(int(spawn[0]), int(spawn[1])), str(spawn[2]), int(spawn[3]))
	m.decals = p.get("decals", []).duplicate(true)
	return m
