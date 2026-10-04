class_name MapData
extends RefCounted

## Данные карты (M5, §11): рельеф, укрытия, космос и точки спавна как ДАННЫЕ,
## а не код. Сохраняется/загружается в JSON (user://maps/*.json). Редактируется
## встроенным редактором карт (scenes/MapEditor.tscn). Слой симуляции строит из
## MapData готовый GameState через build_state().

const MAPS_DIR := "user://maps"
## Карты, поставляемые с игрой (#57). Только чтение: редактор всегда сохраняет в
## user://, поэтому правка встроенной карты создаёт пользовательскую копию, которая
## перекрывает оригинал по имени. Сам файл в res:// при этом остаётся нетронутым.
const BUNDLED_DIR := "res://maps"

var width: int = 16
var height: int = 12
## Плоские массивы размера width*height (индекс = y*width + x).
var floor_type: PackedInt32Array = PackedInt32Array()
var cover_height: PackedFloat32Array = PackedFloat32Array()
var is_space: PackedByteArray = PackedByteArray()
var feature_id: Array[String] = []
## Точки спавна: [{"stats_id": String, "owner": int, "coord": Vector2i}, ...].
var spawns: Array = []
## Зоны развёртывания (§3.3): владелец клетки для расстановки в пре-игре. Плоский
## массив width*height; -1 = не зона, иначе MCF.Owner.*. Заменяет попиксельный спавн
## юнитов в редакторе — игрок сам расставляет отряд внутри своей зоны (#52).
var zone_owner: PackedInt32Array = PackedInt32Array()
## Окружение карты (item 24): от него зависят плитки пола и стен — металл станции и
## бункера, кирпич города и астероида, камень поля. Пусто — карта нарисована в редакторе
## или старше этого поля: окружение выводится из самой карты (environment()).
var env: String = ""
## Побитая мебель (§3.15) — редкие клетки, у которых прочность ниже табличной: индекс →
## [id объекта, прочность]. Запись действует, только пока на клетке тот же объект, так что
## перекрашенная в редакторе клетка старую прочность не наследует. Пусто почти всегда.
var feature_dur: Dictionary = {}

func _init(p_width: int = 16, p_height: int = 12) -> void:
	resize(p_width, p_height)

## Пересоздать пустые слои под размер. Существующее содержимое сбрасывается.
func resize(p_width: int, p_height: int) -> void:
	width = maxi(1, p_width)
	height = maxi(1, p_height)
	var n := width * height
	floor_type = PackedInt32Array()
	cover_height = PackedFloat32Array()
	is_space = PackedByteArray()
	feature_id = []
	floor_type.resize(n)
	cover_height.resize(n)
	is_space.resize(n)
	zone_owner = PackedInt32Array()
	zone_owner.resize(n)
	for i in n:
		feature_id.append("")
		zone_owner[i] = -1
	spawns = []
	feature_dur = {}

## Изменить размер, СОХРАНИВ содержимое (batch 13 #14): клетки в пересечении старого и
## нового поля остаются как были, новые — космос, спавны за краем отбрасываются. Раньше
## единственный способ сменить размер стирал всю карту — «Set Size» был ловушкой.
func resize_keep(p_width: int, p_height: int) -> void:
	var old_w := width
	var old_h := height
	var old_floor := floor_type
	var old_cover := cover_height
	var old_space := is_space
	var old_feat := feature_id
	var old_zone := zone_owner
	var old_spawns := spawns
	var old_dur := feature_dur
	resize(p_width, p_height)
	fill_all_space()
	for y in mini(old_h, height):
		for x in mini(old_w, width):
			var src := y * old_w + x
			var dst := y * width + x
			floor_type[dst] = old_floor[src]
			cover_height[dst] = old_cover[src]
			is_space[dst] = old_space[src]
			feature_id[dst] = old_feat[src]
			zone_owner[dst] = old_zone[src]
			if old_dur.has(src):
				feature_dur[dst] = old_dur[src]
	for s in old_spawns:
		if in_bounds(s["coord"]):
			spawns.append(s)

## Заполнить всю карту космосом (нет пола = космос, §3.11). Стартовое состояние
## редактора: игрок сам «прокрашивает» пол там, где нужна твёрдая поверхность.
func fill_all_space() -> void:
	for i in width * height:
		is_space[i] = 1

func _index(coord: Vector2i) -> int:
	return coord.y * width + coord.x

func in_bounds(coord: Vector2i) -> bool:
	return coord.x >= 0 and coord.y >= 0 and coord.x < width and coord.y < height

func set_cell(coord: Vector2i, p_floor: int, p_cover: float, p_space: bool, p_feature: String) -> void:
	if not in_bounds(coord):
		return
	var i := _index(coord)
	floor_type[i] = p_floor
	cover_height[i] = p_cover
	is_space[i] = 1 if p_space else 0
	feature_id[i] = p_feature

func get_feature(coord: Vector2i) -> String:
	return feature_id[_index(coord)] if in_bounds(coord) else ""

func get_cover(coord: Vector2i) -> float:
	return cover_height[_index(coord)] if in_bounds(coord) else 0.0

func get_space(coord: Vector2i) -> bool:
	return is_space[_index(coord)] != 0 if in_bounds(coord) else false

func get_floor(coord: Vector2i) -> int:
	return floor_type[_index(coord)] if in_bounds(coord) else MCF.FLOOR_NORMAL

## Убрать все точки спавна на клетке (перед постановкой новой — одна на клетку).
func clear_spawn_at(coord: Vector2i) -> void:
	var kept: Array = []
	for s in spawns:
		if s["coord"] != coord:
			kept.append(s)
	spawns = kept

func set_spawn(coord: Vector2i, stats_id: String, owner: int,
		facing: Vector2i = Vector2i.ZERO) -> void:
	clear_spawn_at(coord)
	# facing (item 21) значим только для техники с фронтом; для пехоты — ZERO и игнор.
	spawns.append({"stats_id": stats_id, "owner": owner, "coord": coord, "facing": facing})

## Зона развёртывания клетки (§3.3): владелец или -1, если клетка не в зоне.
func get_zone(coord: Vector2i) -> int:
	return zone_owner[_index(coord)] if in_bounds(coord) else -1

## Пометить клетку зоной владельца (или -1, чтобы снять зону).
func set_zone(coord: Vector2i, owner: int) -> void:
	if in_bounds(coord):
		zone_owner[_index(coord)] = owner

## Все клетки зоны данной стороны (для пре-игровой расстановки, §3.3).
func zone_cells(owner: int) -> Array:
	var out: Array = []
	for y in height:
		for x in width:
			if zone_owner[y * width + x] == owner:
				out.append(Vector2i(x, y))
	return out

# --- Применение к симуляции (§3.1) ---

## Перенести рельеф карты на существующую сетку такого же размера.
func apply_to_grid(grid: Grid) -> void:
	for y in mini(height, grid.height):
		for x in mini(width, grid.width):
			var coord := Vector2i(x, y)
			var c := grid.cell(coord)
			var i := _index(coord)
			c.floor_type = floor_type[i]
			c.is_space = is_space[i] != 0
			var fid := feature_id[i]
			if fid != "":
				c.set_feature(fid)
				var dmg: Variant = feature_dur.get(i)
				if dmg != null and str(dmg[0]) == fid:
					c.feature_durability = clampi(int(dmg[1]), 1, c.feature_durability)
			else:
				c.cover_height = cover_height[i]

## Прочность предмета на клетке ниже табличной (§3.15); dur ≥ табличной снимает запись.
func set_feature_damage(coord: Vector2i, dur: int) -> void:
	if not in_bounds(coord):
		return
	var i := _index(coord)
	var fid := feature_id[i]
	if fid == "" or dur >= MCF.feature_durability(fid):
		feature_dur.erase(i)
	else:
		feature_dur[i] = [fid, maxi(1, dur)]

func get_feature_damage(coord: Vector2i) -> int:
	var i := _index(coord)
	var dmg: Variant = feature_dur.get(i)
	if dmg != null and str(dmg[0]) == feature_id[i]:
		return int(dmg[1])
	return MCF.feature_durability(feature_id[i])

## Полоса развёртывания на карте без нарисованных зон (item 22): поле делится на count
## вертикальных полос, index — номер полосы. [x, y) — столбцы. На двоих — прежние
## половинки. Одна формула и для расстановки, и для превью в лобби.
static func band_of(index: int, count: int, map_width: int) -> Vector2i:
	var n := maxi(1, count)
	var i := clampi(index, 0, n - 1)
	if n == 2:
		var half := map_width / 2
		return Vector2i(0, half) if i == 0 else Vector2i(map_width - half, map_width)
	var w := maxi(1, map_width / n)
	return Vector2i(i * w, map_width if i == n - 1 else i * w + w)

## Окружение для плиток (item 24): записанное, а без него — по самой карте. Деревянные
## дома и трава — город; космос без них — станция; прочее — город.
func environment() -> String:
	if env != "":
		return env
	var space := false
	for i in width * height:
		if feature_id[i] == MCF.FEATURE_WOOD_WALL or floor_type[i] == MCF.FLOOR_GRASS:
			return "town"
		space = space or is_space[i] != 0
	return "station" if space else "town"

## Построить готовый GameState: сетка + рельеф + заспавненные по карте юниты.
## roster — состав партии из лобби; null означает «выведи стороны из самой карты»
## (демо-ростер, редакторская проба, старое сохранение).
func build_state(dice_seed: int = -1, roster: Roster = null) -> GameState:
	var st := GameState.new(width, height, dice_seed)
	if roster != null:
		st.roster = roster
	else:
		st.roster = Roster.for_sides(_spawn_sides())
	apply_to_grid(st.grid)
	st.env = environment()
	# Мирных не больше, чем задано ползунком лобби (item 11). Лишних прореживаем РАВНОМЕРНО
	# по порядку карты — у каждого пира тот же порядок, значит и тот же выбор, и жители не
	# сбиваются в одну половину поля.
	var n_civ := 0
	for s in spawns:
		if MCF.is_neutral(int(s["owner"])):
			n_civ += 1
	var keep_civ := mini(n_civ, GameConfig.civilian_count)
	var civ_i := 0
	for s in spawns:
		var sid: String = s["stats_id"]
		if MCF.is_neutral(int(s["owner"])):
			var take := (civ_i + 1) * keep_civ / maxi(1, n_civ) > civ_i * keep_civ / maxi(1, n_civ)
			civ_i += 1
			if not take:
				continue
		# Техника (§техника): id из VehicleDB — ставим машину, а не пехотинца (#10).
		if VehicleDB.is_vehicle(sid):
			var veh := st.spawn_vehicle(sid, s["coord"], s["owner"])
			# Фронт, заданный на закупке (item 21), — если у машины он вообще есть.
			var face: Vector2i = s.get("facing", Vector2i.ZERO)
			if veh != null and face != Vector2i.ZERO and veh.facing != Vector2i.ZERO:
				veh.facing = face
			continue
		var path := "res://src/data/units/%s.tres" % sid
		if not ResourceLoader.exists(path):
			continue
		var stats: UnitStats = load(path)
		st.spawn_unit(stats, s["coord"], s["owner"])
	# Инициатива бросается один раз — когда все юниты уже на карте (#53).
	st.turns.begin_match(st.all_units(), st.dice, st.roster.player_ids())
	return st

## Номера игроков, за которых на карте кто-то стоит.
func _spawn_sides() -> Array:
	var seen := {}
	for s in spawns:
		var o := int(s["owner"])
		if MCF.is_player(o):
			seen[o] = true
	var out: Array = seen.keys()
	out.sort()
	return out

## Миграция item 5: «нейтральная зона» больше не заселяется на лету. Каждая стоячая
## клетка бывшей нейтральной зоны РАЗ переводится в явный спавн мирного при загрузке
## карты, а сама зона гасится. Так нейтралы едут в файле как обычные юниты (owner ==
## NEUTRAL) — редактор видит и правит их поштучно, а заливки зоны больше нет.
func _materialize_neutral_zones() -> void:
	for coord: Vector2i in zone_cells(MCF.Owner.NEUTRAL):
		set_zone(coord, -1)
		# На стену/космос/объект жителя не сажаем — как и старая заливка.
		if get_space(coord) or get_feature(coord) != "" or get_cover(coord) > 0.0:
			continue
		var taken := false
		for s in spawns:
			if s["coord"] == coord:
				taken = true
				break
		if not taken:
			spawns.append({"stats_id": "civilian",
					"owner": MCF.Owner.NEUTRAL, "coord": coord})

## Пустая твёрдая арена — поле «без карты» (#99). Вынесена сюда, потому что в сетевой
## партии её строит хост и шлёт клиенту: размеры и пол обязаны совпасть до клетки.
static func blank_arena(w: int = 24, h: int = 18) -> MapData:
	var arena := MapData.new(w, h)
	for y in arena.height:
		for x in arena.width:
			arena.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	return arena

# --- Сериализация (JSON) ---

## Версия 1 писала нейтралов числом 2 — тем самым, каким тогда было
## MCF.Owner.NEUTRAL. С переходом на 26 игроков двойка стала законным номером
## ТРЕТЬЕГО ИГРОКА, поэтому старые файлы надо переводить при чтении, иначе жители
## города молча превратились бы в чужую армию. Версия 2 пишет нейтралов уже новым
## значением.
const MAP_VERSION := 2
const LEGACY_NEUTRAL := 2


func to_dict() -> Dictionary:
	var spawn_out: Array = []
	for s in spawns:
		var co: Vector2i = s["coord"]
		spawn_out.append({"stats_id": s["stats_id"], "owner": s["owner"], "x": co.x, "y": co.y})
	var out := {
		"version": MAP_VERSION,
		"width": width,
		"height": height,
		"floor_type": Array(floor_type),
		"cover_height": Array(cover_height),
		"is_space": Array(is_space),
		"feature_id": feature_id.duplicate(),
		"spawns": spawn_out,
		"zone_owner": Array(zone_owner),
		"env": env,
	}
	# Только если есть побитая мебель: обычная карта пишется байт в байт как раньше.
	var dur_out := {}
	for i: int in feature_dur:
		if i < feature_id.size() and str(feature_dur[i][0]) == feature_id[i]:
			dur_out[str(i)] = feature_dur[i]
	if not dur_out.is_empty():
		out["feature_durability"] = dur_out
	return out

static func from_dict(d: Dictionary) -> MapData:
	var m := MapData.new(int(d.get("width", 16)), int(d.get("height", 12)))
	var version := int(d.get("version", 1))
	var n := m.width * m.height
	var ft: Array = d.get("floor_type", [])
	var ch: Array = d.get("cover_height", [])
	var sp: Array = d.get("is_space", [])
	var fi: Array = d.get("feature_id", [])
	for i in n:
		if i < ft.size():
			m.floor_type[i] = int(ft[i])
		if i < ch.size():
			m.cover_height[i] = float(ch[i])
		if i < sp.size():
			m.is_space[i] = int(sp[i])
		if i < fi.size():
			m.feature_id[i] = str(fi[i])
	m.env = str(d.get("env", ""))
	var fd: Dictionary = d.get("feature_durability", {})
	for k: String in fd:
		var rec: Array = fd[k]
		if int(k) < n and rec.size() == 2:
			m.feature_dur[int(k)] = [str(rec[0]), int(rec[1])]
	var zo: Array = d.get("zone_owner", [])
	for i in n:
		if i < zo.size():
			m.zone_owner[i] = _migrate_owner(int(zo[i]), version)
	for s in d.get("spawns", []):
		m.spawns.append({
			"stats_id": str(s.get("stats_id", "")),
			"owner": _migrate_owner(int(s.get("owner", 0)), version),
			"coord": Vector2i(int(s.get("x", 0)), int(s.get("y", 0))),
		})
	# item 5: старые карты с «нейтральной зоной» переводим в явные спавны мирных.
	m._materialize_neutral_zones()
	return m

## Перевод номера стороны из формата карты в текущий. Трогает только версию 1 и
## только двойку: −1 («не зона») и номера игроков 0/1 в обоих форматах совпадают.
static func _migrate_owner(owner: int, version: int) -> int:
	if version < 2 and owner == LEGACY_NEUTRAL:
		return MCF.Owner.NEUTRAL
	return owner

func save_to(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(MAPS_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	return true

static func load_from(path: String) -> MapData:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	return from_dict(parsed)

## Список доступных карт (имена файлов без пути): встроенные + пользовательские.
## Имя встречается один раз, даже если карта есть в обоих местах — путь к ней
## разрешает path_for(), и пользовательская версия там побеждает.
static func list_maps() -> PackedStringArray:
	var seen := {}
	var out := PackedStringArray()
	for dir_path in [BUNDLED_DIR, MAPS_DIR]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for name in dir.get_files():
			if name.ends_with(".json") and not seen.has(name):
				seen[name] = true
				out.append(name)
	out.sort()
	return out

## Полный путь к карте по имени файла. Пользовательская копия имеет приоритет над
## встроенной, поэтому сохранённая в редакторе правка подменяет поставочную карту.
static func path_for(name: String) -> String:
	var user_path := "%s/%s" % [MAPS_DIR, name]
	if FileAccess.file_exists(user_path):
		return user_path
	var bundled := "%s/%s" % [BUNDLED_DIR, name]
	if FileAccess.file_exists(bundled):
		return bundled
	return user_path
