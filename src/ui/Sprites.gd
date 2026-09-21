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
##
## Два исключения — ЛДФ и ДПМГ (item 43). Объекты переименованы, а их id на диске
## остались прежними ради читаемости старых карт, так что здесь единственное место,
## где имя файла и id расходятся. Разводит их ALIASES ниже: игрок кладёт ldf.png,
## как и подписано в игре, а код по-прежнему спрашивает "bru".
const MANIFEST := [
	["Floors (the tile itself)", [
		"floor", "floor_space", "floor_wall", "floor_cover", "fire",
		# Трава (item 14) и следы разрушений (item 21): floor_epicenter — та же
		# побитая плита, но выгоревшая, для самой клетки взрыва.
		"floor_grass", "floor_destroyed", "floor_epicenter",
	]],
	["Combat decoration (cosmetic only, never affects the rules)", [
		"glass_shard", "shell_casing", "blood_pool", "blood_splatter",
	]],
	["Terrain features (one per object on a tile)", [
		"drone_station", "sandbags", "hedgehog", "dirt_pile", "trench",
		"wall", "glass", "ldf", "corpse_wall", "airlock",
		"dpmg", "dot", "wood_wall", "sandbag_wall", "hedgehog_sandbags", "mine",
	]],
	["Soldiers (add a faction suffix for a faction-specific look, see below)", [
		"anti_tank", "assault", "civilian", "commander", "drone",
		"drone_operator", "engineer", "flamethrower", "heavy_infantry",
		"light_infantry", "machinegunner", "marksman", "miner", "sapper",
		"shield_bearer", "sniper",
	]],
	["Faction portraits (shown in the lobby instead of the colour square)", [
		"faction_nova", "faction_purifiers", "faction_prometheus", "faction_alliance",
		"faction_league", "faction_martian", "faction_barbarians",
	]],
	["Vehicles (stretched over the whole footprint)", [
		"tank", "shuttle", "borg", "tank_wreck", "shuttle_wreck", "borg_wreck",
	]],
	["Misc", [
		"corpse",
	]],
]

## Автотайл (batch 17, item 12): лист «<объект>_autotile.png» из 16 плиток 4×4. Плитка
## выбирается по четырём соседям с ТЕМ ЖЕ объектом: индекс = N·1 + E·2 + S·4 + W·8,
## колонка = индекс % 4, строка = индекс / 4. Плитка 0 — одиночный столб, 15 — крест.
const AUTOTILE_SUFFIX := "_autotile"
const AUTOTILE_N := 1
const AUTOTILE_E := 2
const AUTOTILE_S := 4
const AUTOTILE_W := 8

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
		# В СОБРАННОЙ игре картинка из res:// лежит уже импортированной, а рядом с ней
		# указатель «имя.png.remap». Снимаем суффикс — дальше всё как с обычным файлом
		# (загрузку разводит _load_texture_at). Без этого поставочные текстуры (танк,
		# issue 4) были бы видны в редакторе и пропадали в экспорте.
		var base_name := fname
		if base_name.ends_with(".remap"):
			base_name = base_name.substr(0, base_name.length() - 6)
		var ext := base_name.get_extension().to_lower()
		if not d.current_is_dir() and SUPPORTED_IMG.has(ext):
			var key := base_name.get_basename().to_lower()
			# PNG выигрывает у прочих форматов при совпадении имени; user://
			# сканируется последним, поэтому перебивает res:// — но не меняет PNG
			# на формат хуже.
			var better := not _overrides.has(key) or ext == "png"
			if better:
				var tex := _load_texture_at(dir_path + "/" + base_name)
				if tex != null:
					_overrides[key] = tex
		fname = d.get_next()
	d.list_dir_end()

## Картинка по пути. Порядок попыток разный для разных каталогов:
##   • res:// — сперва ЗАГРУЗЧИК РЕСУРСОВ: поставочный png импортирован движком, и в
##     собранной игре доступен только так (Image.load там честно предупреждает
##     «will not work on export»);
##   • user:// — сперва ФАЙЛ: картинку игрока никто не импортировал, её и нет в
##     реестре ресурсов.
## Вторая попытка идёт как запасная — на случай неимпортированного png в проекте.
static func _load_texture_at(path: String) -> Texture2D:
	if path.begins_with("res://") and ResourceLoader.exists(path):
		var res := ResourceLoader.load(path) as Texture2D
		if res != null:
			return res
	var img := Image.new()
	if img.load(path) == OK:
		return ImageTexture.create_from_image(img)
	return null

## id объекта → имя файла-замены. Нужен ровно для переименованных объектов.
const ALIASES := {
	"bru": "ldf",
	"rsp": "dpmg",
}

## Сама текстура по имени (для виджетов вроде TextureRect); null — замены нет.
static func texture_of(name: String) -> Texture2D:
	ensure_overrides()
	return _overrides.get(ALIASES.get(name, name).to_lower())

static func has_override(name: String) -> bool:
	ensure_overrides()
	return _overrides.has(ALIASES.get(name, name).to_lower())

## Имя с учётом стороны: сначала ищем «boec_nova», потом общее «boec» (#55, batch 17).
## Пустая строка — картинки нет ни в каком виде, рисуем вектор как раньше.
static func resolve(name: String, suffix: String = "") -> String:
	ensure_overrides()
	name = ALIASES.get(name, name)
	if suffix != "" and _overrides.has((name + suffix).to_lower()):
		return name + suffix
	if _overrides.has(name.to_lower()):
		return name
	return ""

# --- Отрисовка ---
## Собственное преобразование холста вызывающего (панорама и зум карты).
##
## Повёрнутая картинка рисуется через draw_set_transform, и вернуть его надо в ТО, что
## стояло у вызывающего, а не в единицу: сцена боя рисует всё поле в draw_set_transform(
## pan, 0, zoom), и сброс в единицу посреди кадра увёл бы всё нарисованное ПОСЛЕ
## повёрнутой картинки в другой угол экрана с другим масштабом. Пока повёрнутых замен
## никто не подкладывал, это не всплывало; с поставочной текстурой танка (issue 4),
## которая поворачивается по фронту, всплыло бы первым же кадром.
static var _base_offset: Vector2 = Vector2.ZERO
static var _base_scale: Vector2 = Vector2.ONE

## Вызывающий сообщает своё преобразование сразу после draw_set_transform в _draw().
static func set_base_transform(offset: Vector2, scale: Vector2) -> void:
	_base_offset = offset
	_base_scale = scale

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
	name = ALIASES.get(name, name)
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
		ci.draw_set_transform(_base_offset + center * _base_scale,
				deg_to_rad(rot_deg), _base_scale)
		ci.draw_texture_rect(tex, Rect2(-rect.size * 0.5, rect.size), false, tint)
		ci.draw_set_transform(_base_offset, 0.0, _base_scale)
	return true

## Объект на клетке: автотайл, если для него лежит лист, иначе обычная картинка.
## same(dx, dy) → стоит ли на соседней клетке тот же объект. false — замены нет вовсе,
## вызывающий рисует вектор.
static func draw_feature(ci: CanvasItem, name: String, rect: Rect2, same: Callable) -> bool:
	ensure_overrides()
	var key: String = ALIASES.get(name, name)
	var sheet: Texture2D = _overrides.get(key + AUTOTILE_SUFFIX)
	if sheet == null:
		return draw_texture_override_rect(ci, key, rect)
	var mask := 0
	if same.call(0, -1):
		mask |= AUTOTILE_N
	if same.call(1, 0):
		mask |= AUTOTILE_E
	if same.call(0, 1):
		mask |= AUTOTILE_S
	if same.call(-1, 0):
		mask |= AUTOTILE_W
	draw_autotile(ci, sheet, rect, mask)
	return true

static func draw_autotile(ci: CanvasItem, sheet: Texture2D, rect: Rect2, mask: int) -> void:
	var tw := sheet.get_width() / 4.0
	var th := sheet.get_height() / 4.0
	ci.draw_texture_rect_region(sheet, rect,
			Rect2((mask % 4) * tw, (mask / 4) * th, tw, th))

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
	lines.append_array([
		"== Factions ==",
		"Sides are factions, not colours. Soldiers accept a faction suffix:",
		"  light_infantry_nova.png, light_infantry_purifiers.png, ... light_infantry_neutral.png",
		"Suffixes: " + ", ".join(Roster.FACTION_KEYS) + ", neutral.",
		"A plain light_infantry.png is used for any faction that has no suffixed file.",
		"Soldier art is drawn facing UP in a square; a corpse is the same picture turned",
		"90 degrees clockwise, so no separate corpse art is needed per soldier",
		"(corpse.png is the fallback for piles and for soldiers without art).",
		"faction_<key>.png is the portrait shown in the lobby's faction window.",
		"",
		"== Autotiling walls ==",
		"Any terrain feature may ship as a 4x4 tile sheet named <feature>_autotile.png",
		"(wall_autotile.png, glass_autotile.png, wood_wall_autotile.png, ...).",
		"The game looks at the four orthogonal neighbours that carry the SAME feature",
		"and picks tile index = N*1 + E*2 + S*4 + W*8; column = index % 4, row = index / 4:",
		"",
		"  row 0:  0 alone     1 N          2 E          3 N+E",
		"  row 1:  4 S         5 N+S (|)    6 E+S        7 N+E+S",
		"  row 2:  8 W         9 N+W       10 E+W (-)   11 N+E+W",
		"  row 3: 12 S+W      13 N+S+W     14 E+S+W     15 all four (+)",
		"",
		"Each tile is square; the sheet is 4 tiles wide and 4 tall (e.g. 256x256 for 64px",
		"tiles). If a sheet exists it wins over the plain <feature>.png. Diagonal",
		"neighbours are ignored on purpose: 16 tiles are enough for corridors and rooms.",
		"",
		"== Preparing a graphical update ==",
		"1. Author every sprite as a square PNG with transparency (64x64 or 128x128).",
		"   Art is stretched to the cell, so keep the subject inside the square.",
		"2. Name files exactly as listed above, lower case. Drop them into user://textures",
		"   to test without touching the project, then move them into res://textures to",
		"   ship them. Open the project once in the Godot editor so it imports them.",
		"3. Vehicles are drawn nose-up over their whole footprint (tank 3x3, shuttle 2x2).",
		"4. Floors: floor, floor_grass, floor_wall (under a wall), floor_space,",
		"   floor_cover, floor_destroyed, floor_epicenter, fire.",
		"5. Missing files fall back to the built-in vector look, so you can replace the",
		"   game piece by piece.",
		"",
	])
	return "\n".join(lines) + "\n"
