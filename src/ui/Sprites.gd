class_name Sprites
extends RefCounted

## Замена спрайтов картинками пользователя (#55) — перенос системы из marble_race
## (Crazy Ball Runner 2D) без изменения правил игры.
##
## Идея та же: у каждой рисуемой сущности есть ИМЯ. Если в папке текстур лежит
## файл с таким именем — вместо векторной отрисовки кладётся картинка; если нет —
## рисуется как раньше. Никаких настроек в редакторе, только файлы на диске.
##
## Где искать картинки:
##   • res://textures  — то, что поставляется с игрой;
##   • user://textures — то, что подкинул игрок (перекрывает res://).
## Список всех допустимых имён игра генерирует сама — см. MANIFEST_FILE.

## Кэш «имя → текстура». Заполняется один раз, дальше только чтение.
static var _overrides: Dictionary = {}
static var _overrides_loaded := false

const SUPPORTED_IMG := ["png", "jpg", "jpeg", "webp", "bmp", "tga", "svg"]

const USER_DIR := "user://textures"
const RES_DIR := "res://textures"
const MANIFEST_FILE := "user://textures/TEXTURE_NAMES.txt"
const RES_MANIFEST_FILE := "res://textures/all_textures.txt"

## Полный перечень заменяемых спрайтов, сгруппированный для читаемости файла-справки.
## Имена совпадают с идентификаторами из MCF/VehicleDB и файлами src/data/units/*.tres,
## поэтому «что вижу в игре — то и называю» работает без таблицы соответствий.
const MANIFEST := [
	["Floors (the tile itself)", [
		"floor", "floor_space", "floor_wall", "floor_cover", "fire",
	]],
	["Terrain features (one per object on a tile)", [
		"drone_station", "sandbags", "hedgehog", "dirt_pile", "trench",
		"wall", "glass", "bru", "corpse_wall", "airlock",
		"rsp", "dot", "wood_wall", "sandbag_wall", "hedgehog_sandbags",
	]],
	["Soldiers (add _p1 / _p2 / _neutral for a side-specific look)", [
		"anti_tank", "assault", "civilian", "commander", "drone",
		"drone_operator", "engineer", "flamethrower", "heavy_infantry",
		"light_infantry", "machinegunner", "marksman", "miner",
		"shield_bearer", "sniper",
	]],
	["Vehicles (stretched over the whole footprint)", [
		"tank", "shuttle", "tank_wreck", "shuttle_wreck",
	]],
	["Misc", [
		"corpse",
	]],
]

# --- Загрузка ---
## Перечитать папки текстур с нуля. Зовётся при входе в бой/редактор, чтобы
## подменённый файл подхватывался без перезапуска игры.
static func reload_overrides() -> void:
	_overrides.clear()
	_overrides_loaded = true
	DirAccess.make_dir_recursive_absolute(USER_DIR)
	_write_manifest()
	# Порядок важен: user:// сканируется последним и перекрывает res://.
	for dir_path in [RES_DIR, USER_DIR]:
		_scan_override_dir(dir_path)

static func ensure_overrides() -> void:
	if not _overrides_loaded:
		reload_overrides()

static func _scan_override_dir(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var fname := d.get_next()
	while fname != "":
		var ext := fname.get_extension().to_lower()
		if not d.current_is_dir() and SUPPORTED_IMG.has(ext):
			var key := fname.get_basename().to_lower()
			# PNG выигрывает у прочих форматов при совпадении имени; user://
			# сканируется последним, поэтому перебивает res:// — но не меняет PNG
			# на формат хуже.
			var better := not _overrides.has(key) or ext == "png"
			if better:
				var img := Image.new()
				if img.load(dir_path + "/" + fname) == OK:
					_overrides[key] = ImageTexture.create_from_image(img)
		fname = d.get_next()
	d.list_dir_end()

static func has_override(name: String) -> bool:
	ensure_overrides()
	return _overrides.has(name.to_lower())

## Имя с учётом стороны: сначала ищем «boec_p1», потом общее «boec» (#55).
## Пустая строка — картинки нет ни в каком виде, рисуем вектор как раньше.
static func resolve(name: String, suffix: String = "") -> String:
	ensure_overrides()
	if suffix != "" and _overrides.has((name + suffix).to_lower()):
		return name + suffix
	if _overrides.has(name.to_lower()):
		return name
	return ""

# --- Отрисовка ---
## Нарисовать картинку в клетку. Возвращает false, если замены нет — тогда
## вызывающий рисует свою векторную версию (ровно как в marble_race).
static func draw_texture_override(ci: CanvasItem, name: String, o: Vector2,
		tile: float, rot_deg := 0.0, tint := Color.WHITE) -> bool:
	return draw_texture_override_rect(ci, name, Rect2(o, Vector2(tile, tile)), rot_deg, tint)

## То же самое, но на произвольный прямоугольник — техника занимает несколько клеток.
static func draw_texture_override_rect(ci: CanvasItem, name: String, rect: Rect2,
		rot_deg := 0.0, tint := Color.WHITE) -> bool:
	if not _overrides_loaded:
		reload_overrides()
	# Функция стоит в поклеточном цикле _draw(): до трёх вызовов на клетку, тысячи на
	# кадр. Поэтому сначала два дешёвых выхода — «замен вообще нет» и «имя уже в нижнем
	# регистре» (а так его пишут все вызывающие: это литералы и id из MCF). to_lower()
	# строит новую строку и остаётся только для регистронезависимой подстраховки.
	if _overrides.is_empty():
		return false
	var tex: Texture2D = _overrides.get(name)
	if tex == null:
		tex = _overrides.get(name.to_lower())
		if tex == null:
			return false
	if is_zero_approx(rot_deg):
		ci.draw_texture_rect(tex, rect, false, tint)
	else:
		var center := rect.position + rect.size * 0.5
		ci.draw_set_transform(center, deg_to_rad(rot_deg), Vector2.ONE)
		ci.draw_texture_rect(tex, Rect2(-rect.size * 0.5, rect.size), false, tint)
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	return true

# --- Файл-справка ---
## Игра САМА пишет список имён рядом с папкой текстур: игроку не нужно лезть в код,
## чтобы узнать, как назвать файл. res:// в собранной игре только для чтения —
## поэтому неудачная запись туда молча пропускается.
static func _write_manifest() -> void:
	var text := _manifest_text()
	for path in [MANIFEST_FILE, RES_MANIFEST_FILE]:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			continue
		f.store_string(text)
		f.close()

static func _manifest_text() -> String:
	var lines: Array[String] = [
		"MCF TACTICS -- TEXTURE REPLACEMENT",
		"",
		"Drop an image in this folder named after any entry below and it replaces",
		"that sprite everywhere in the game. Delete the file to get the original back.",
		"",
		"Supported image formats: png, jpg, jpeg, webp, bmp, tga, svg.",
		"PNG is preferred -- it wins if two files share the same name.",
		"Images are stretched to the tile, so square art looks best.",
		"",
		"Two folders are scanned: res://textures (shipped) and user://textures (yours).",
		"Yours wins. Changes are picked up when a battle or the map editor opens.",
		"",
	]
	for group in MANIFEST:
		lines.append("-- %s --" % group[0])
		for entry in group[1]:
			lines.append("  %s.png" % entry)
		lines.append("")
	lines.append("Soldiers also accept a side suffix: light_infantry_p1.png,")
	lines.append("light_infantry_p2.png, light_infantry_neutral.png. A plain")
	lines.append("light_infantry.png is used for any side that has no suffixed file.")
	lines.append("")
	return "\n".join(lines) + "\n"
