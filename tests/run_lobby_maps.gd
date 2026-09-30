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
##      указывает на существующий файл, который читается как карта;
##   4. строка «Random map» собирает карту с зоной на каждый слот, пересобирает её при
##      новом слоте или зерне (и только тогда), уходит на старт без пути к файлу, а
##      «Save as Map» кладёт её в user://maps обычной картой списка. «Players» и есть
##      число слотов (в одиночке добавляет ИИ), а «Units per side» растит зоны под отряд.
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
		# «Blank arena», «Random map» + по строке на каждую карту, и ни одной лишней.
		ck(opt.item_count == names.size() + 2,
				"the dropdown holds every saved map: %d item(s) for %d map(s) + 2 built-in" % [
					opt.item_count, names.size()])
		ck(paths.size() == opt.item_count, "each dropdown row carries its own path")
		var shown := {}
		for i in opt.item_count:
			shown[opt.get_item_text(i)] = true
		for n: String in names:
			ck(shown.has(n.get_basename()), "map '%s' is choosable in the lobby" % n)
		for i in range(2, paths.size()):
			var p: String = paths[i]
			ck(FileAccess.file_exists(p), "row %d points at an existing file (%s)" % [i, p])
			ck(MapData.load_from(p) != null, "row %d reads back as a map (%s)" % [i, p])

	# Перечитывание списка (кнопка «⟳») не теряет карты и не плодит дублей.
	if opt != null:
		var before := opt.item_count
		lobby._reload_map_items()
		ck(opt.item_count == before, "rescanning the folders keeps the list identical")
		_check_random(lobby, opt, paths)

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

func _check_random(lobby: Node, opt: OptionButton, paths: Array) -> void:
	var ri := paths.find(lobby.RANDOM_MAP)
	ck(ri == 1, "'Random map' sits right after the blank arena (row %d)" % ri)
	if ri < 0:
		return
	ck(not lobby._gen_box.visible, "the generator settings stay hidden until 'Random map' is picked")
	opt.select(ri)
	opt.item_selected.emit(ri)
	ck(lobby._gen_box.visible, "picking 'Random map' shows the generator settings")
	lobby._gen_seed.value = 4242  # лобби бросает зерно само — для повторяемости задаём своё
	var a: MapData = lobby._selected_map()
	ck(a.width == MapGen.SIZES[1].x, "the default random map is Medium (%d wide)" % a.width)
	ck(lobby._map_zone_count() == lobby.roster.slots.size(),
			"one zone per slot: %d zone(s), %d slot(s)" % [lobby._map_zone_count(), lobby.roster.slots.size()])
	ck(lobby._selected_map() == a, "the same settings don't rebuild the map on every read")
	ck(lobby._map_preview.texture != null, "the random map has a preview")
	ck(str(lobby._gen_info.text).contains("2 deployment zones"),
			"the generator reports the zones (%s)" % lobby._gen_info.text)
	lobby._on_add_slot()
	var b: MapData = lobby._selected_map()
	ck(b != a and lobby._map_zone_count() == 3, "a new slot rebuilds the map with a zone for it")
	lobby._gen_seed.value = lobby._gen_seed.value + 1
	ck(lobby._selected_map() != b, "a new seed builds a new map")
	ck(int(lobby._gen_players.value) == 3, "'Players' follows the slot list (%d)" % lobby._gen_players.value)
	lobby._gen_players.value = 4
	ck(lobby.roster.slots.size() == 4 and lobby.roster.slots[3].kind == Roster.SlotKind.AI,
			"'Players: 4' seats four, the new ones as AI in a solo lobby")
	ck(lobby._map_zone_count() == 4, "four players, four zones (%d)" % lobby._map_zone_count())
	lobby._gen_units.value = 40
	var cells := {}
	for z in lobby._selected_map().zone_owner:
		if z >= 0:
			cells[z] = int(cells.get(z, 0)) + 1
	ck(cells.size() == 4 and cells.values().min() >= MapGen.zone_need(40),
			"every zone fits 40 units (%s cells, %d needed)" % [cells.values(), MapGen.zone_need(40)])
	ck(str(lobby._gen_info.text).contains("room for 40 units"), "the readout says so (%s)" % lobby._gen_info.text)
	lobby._gen_players.value = 2
	ck(lobby.roster.slots.size() == 2, "'Players: 2' drops the extra slots")
	lobby._commit_config()
	ck(GameConfig.map_path == "", "a random map starts without a file path ('%s')" % GameConfig.map_path)
	var before := MapData.list_maps()
	lobby._save_random_map()
	var added: Array = []
	for n in MapData.list_maps():
		if not before.has(n):
			added.append(n)
	ck(added.size() == 1 and str(added[0]).begins_with("random-town-"),
			"'Save as Map' adds one file to user://maps (%s)" % [added])
	ck(lobby._is_random(), "'Random map' stays selected after saving")
	for n: String in added:
		ck(MapData.load_from(MapData.path_for(n)) != null, "the saved random map reads back")
		DirAccess.remove_absolute("%s/%s" % [MapData.MAPS_DIR, n])
	_check_bunker_custom_symmetric(lobby)

## Бункер, свой размер до 250×250 и «Symmetrical» — через сами контролы лобби.
func _check_bunker_custom_symmetric(lobby: Node) -> void:
	var style: OptionButton = lobby._gen_style
	var size: OptionButton = lobby._gen_size
	ck(style.item_count == MapGen.STYLE_NAMES.size() and style.get_item_text(MapGen.Style.BUNKER) == "Bunker",
			"the style list offers the bunker")
	ck(size.item_count == MapGen.SIZES.size() + 1, "sizes: every preset plus Custom (%d)" % size.item_count)
	ck(not lobby._gen_dims_row.visible, "the custom size row hides until Custom is picked")
	style.select(MapGen.Style.BUNKER)
	style.item_selected.emit(MapGen.Style.BUNKER)
	size.select(MapGen.SIZE_CUSTOM)
	size.item_selected.emit(MapGen.SIZE_CUSTOM)
	ck(lobby._gen_dims_row.visible, "picking Custom shows width and height")
	ck(lobby._gen_w.max_value == MapGen.MAX_DIM.x and lobby._gen_h.max_value == MapGen.MAX_DIM.y,
			"a custom map can be up to %d×%d" % [MapGen.MAX_DIM.x, MapGen.MAX_DIM.y])
	lobby._gen_w.value = 64
	lobby._gen_h.value = 40
	var c: MapData = lobby._selected_map()
	ck(c.width == 64 and c.height == 40, "a custom 64×40 map is 64×40 (%dx%d)" % [c.width, c.height])
	var vacuum := false
	for i in c.width * c.height:
		vacuum = vacuum or c.is_space[i] != 0
	ck(not vacuum, "the bunker has no vacuum even with 'Space & airlocks' ticked")
	lobby._gen_sym.button_pressed = true
	var d: MapData = lobby._selected_map()
	ck(d != c, "'Symmetrical' rebuilds the map")
	var bad := 0
	for y in d.height:
		for x in d.width:
			if d.get_feature(Vector2i(x, y)) != d.get_feature(Vector2i(d.width - 1 - x, y)):
				bad += 1
	ck(bad == 0, "the symmetrical map is its own mirror image (%d cell(s) differ)" % bad)
	# 250×250 собирается за полсекунды: превью ждёт, пока щелчки стихнут, но чтение карты —
	# сразу и уже нового размера.
	lobby._gen_w.value = 250
	lobby._gen_h.value = 250
	ck(lobby._gen_timer.time_left > 0.0, "a 250×250 map waits for the clicks to settle before redrawing")
	var big: MapData = lobby._selected_map()
	ck(big.width == 250 and big.height == 250, "reading the map builds the 250×250 one right away")
	lobby._gen_sym.button_pressed = false
	size.select(1)
	size.item_selected.emit(1)
	style.select(MapGen.Style.TOWN)
	style.item_selected.emit(MapGen.Style.TOWN)
	ck(not lobby._gen_dims_row.visible, "back to a preset size hides the custom row")

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
