extends SceneTree

## Разбор ВСЕХ скриптов проекта за один заход.
##
## `godot --check-only --script X.gd` для сценных скриптов не годится: он не видит
## автозагрузку (`Ui`), и любой файл, который её упоминает, «падает» на ровном
## месте. Здесь проект уже запущен по-настоящему, поэтому и автозагрузка на месте,
## и глобальные классы зарегистрированы.

func _initialize() -> void:
	var bad: PackedStringArray = []
	var n := 0
	for path in _scripts("res://"):
		n += 1
		if load(path) == null:
			bad.append(path)
	if bad.is_empty():
		print("check: %d scripts parsed clean" % n)
		quit(0)
		return
	printerr("check: %d of %d scripts failed to load" % [bad.size(), n])
	for b in bad:
		printerr("  " + b)
	quit(1)

func _scripts(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir.path_join(name)
		if d.current_is_dir():
			out.append_array(_scripts(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()
	return out
