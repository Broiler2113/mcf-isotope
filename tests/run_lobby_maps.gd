extends SceneTree

## Сохранённые карты обязаны быть ВИДНЫ в лобби (issue 1).
##
## Игрок дважды сообщал одно и то же: «карты, которые можно выбрать, не видны — сделай
## так, чтобы в настройках лобби выбиралась ЛЮБАЯ сохранённая карта, и чтобы этот баг
## больше не появлялся никогда». Первый раз причина была в переименовании приложения
## (user:// уехал в другую папку), и починка жила в UserDataMigration — то есть в коде,
## который никто не проверял. Этот прогон закрывает саму ЦЕПОЧКУ, а не одну её причину:
##
##   1. карта, сохранённая в user://maps (так пишет редактор), попадает в MapData.list_maps();
##   2. карта, поставляемая в res://maps, попадает туда же;
##   3. КАЖДОЕ имя из list_maps() есть в выпадающем списке лобби, и путь рядом с ним
##      указывает на существующий файл, который читается как карта.
##
## Проверяется настоящая сцена лобби, а не её отдельные функции: между «файл на диске»
## и «строка в списке» стоял именно этот код.

const PROBE := "__lobby_probe_map.json"

var fails: PackedStringArray = []
var _lobby: Node = null
var _probe_path := ""

## Сцена входит в дерево (и получает _ready) не раньше первого кадра, поэтому её
## строим здесь, а проверяем в _process — иначе лобби осталось бы непостроенным.
func _initialize() -> void:
	_probe_path = "%s/%s" % [MapData.MAPS_DIR, PROBE]
	_write_probe_map(_probe_path)
	_lobby = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(_lobby)

func _process(_delta: float) -> bool:
	_check()
	return true

func _check() -> void:
	var probe_path := _probe_path

	var names := MapData.list_maps()
	ck(names.has(PROBE), "a map saved in user://maps is listed (list_maps: %s)" % [names])
	ck(_bundled_names().all(func(n: String) -> bool: return names.has(n)),
			"every map shipped in res://maps is listed (bundled: %s, listed: %s)" % [
				_bundled_names(), names])

	var lobby: Node = _lobby
	var opt: OptionButton = lobby._map_opt
	var paths: Array = lobby._map_paths
	ck(opt != null, "the lobby built its map dropdown")
	if opt != null:
		# «Blank arena» + по строке на каждую карту, и ни одной лишней.
		ck(opt.item_count == names.size() + 1,
				"the dropdown holds every saved map: %d item(s) for %d map(s) + blank arena" % [
					opt.item_count, names.size()])
		ck(paths.size() == opt.item_count, "each dropdown row carries its own path")
		var shown := {}
		for i in opt.item_count:
			shown[opt.get_item_text(i)] = true
		for n: String in names:
			ck(shown.has(n.get_basename()), "map '%s' is choosable in the lobby" % n)
		for i in range(1, paths.size()):
			var p: String = paths[i]
			ck(FileAccess.file_exists(p), "row %d points at an existing file (%s)" % [i, p])
			ck(MapData.load_from(p) != null, "row %d reads back as a map (%s)" % [i, p])

	# Перечитывание списка (кнопка «⟳») не теряет карты и не плодит дублей.
	if opt != null:
		var before := opt.item_count
		lobby._reload_map_items()
		ck(opt.item_count == before, "rescanning the folders keeps the list identical")

	lobby.free()
	DirAccess.remove_absolute(probe_path)

	if fails.is_empty():
		print("lobby maps: every saved map is choosable in the lobby")
		quit(0)
		return
	printerr("lobby maps: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

## Маленькая, но НАСТОЯЩАЯ карта: пишется тем же save_to, что и редактор.
func _write_probe_map(path: String) -> void:
	var m := MapData.new(8, 6)
	for y in 6:
		for x in 8:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	if not m.save_to(path):
		fails.append("could not write the probe map to %s" % path)

func _bundled_names() -> Array:
	var out: Array = []
	var d := DirAccess.open(MapData.BUNDLED_DIR)
	if d == null:
		return out
	for n: String in d.get_files():
		if n.ends_with(".json"):
			out.append(n)
	return out
