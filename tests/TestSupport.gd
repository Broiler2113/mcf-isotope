extends RefCounted

## Общая обвязка регрессионных прогонов (см. tests/README.md).
##
## Здесь нет ни одного случайного числа: карта, ростер и порядок юнитов строятся
## по жёстко заданному алгоритму, а весь разброс партии приходит из DiceService с
## фиксированным зерном. Это и есть условие, при котором след прогона вообще
## имеет смысл сравнивать.

## Зерно кубиков на все прогоны. Меняя его, меняешь всю партию — не делай этого
## ради «покрасивее», иначе эталонный след придётся пересобирать без причины.
const SEED := 20260906
const MAP_W := 34
const MAP_H := 26

## Фиксированная карта: пол, полоса стен по центру с проходами, немного стекла,
## горючего пола, мешков и окопов. Формы намеренно простые и повторяемые —
## задача карты не быть интересной, а быть ОДИНАКОВОЙ.
static func build_map() -> MapData:
	var m := MapData.new(MAP_W, MAP_H)
	for y in MAP_H:
		for x in MAP_W:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	# Центральная стена с двумя проходами — заставляет обе стороны манёврировать.
	var mid := MAP_W / 2
	for y in MAP_H:
		if y == 6 or y == 7 or y == 18 or y == 19:
			continue
		m.set_cell(Vector2i(mid, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	# Стекло в стене — путь для лазера и (после M5) для пуль.
	m.set_cell(Vector2i(mid, 12), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_GLASS)
	m.set_cell(Vector2i(mid, 13), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_GLASS)
	# Горючий пол двумя пятнами — материал для проверок огня.
	for y in range(9, 13):
		for x in range(8, 12):
			m.set_cell(Vector2i(x, y), MCF.FLOOR_FLAMMABLE, 0.0, false, "")
	for y in range(14, 18):
		for x in range(23, 27):
			m.set_cell(Vector2i(x, y), MCF.FLOOR_FLAMMABLE, 0.0, false, "")
	# Укрытия и окопы у каждой стороны.
	for y in range(8, 14):
		m.set_cell(Vector2i(5, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_SANDBAGS)
		m.set_cell(Vector2i(MAP_W - 6, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_SANDBAGS)
	for x in range(3, 7):
		m.set_cell(Vector2i(x, 20), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_TRENCH)
	for x in range(MAP_W - 7, MAP_W - 3):
		m.set_cell(Vector2i(x, 20), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_TRENCH)
	m.set_cell(Vector2i(9, 4), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_HEDGEHOG)
	m.set_cell(Vector2i(MAP_W - 10, 4), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_HEDGEHOG)
	_add_armies(m)
	return m

## Ростер обеих сторон плюс нейтралы. Порядок добавления фиксирован, а MapData
## раздаёт id по порядку spawns, поэтому id юнитов воспроизводимы.
static func _add_armies(m: MapData) -> void:
	var roster := [
		"light_infantry", "light_infantry", "heavy_infantry", "machinegunner",
		"sniper", "anti_tank", "engineer", "flamethrower",
	]
	for i in roster.size():
		var y := 4 + i * 2
		m.set_spawn(Vector2i(3, y), roster[i], MCF.Owner.PLAYER_1)
		m.set_spawn(Vector2i(MAP_W - 4, y), roster[i], MCF.Owner.PLAYER_2)
	# Нейтралы в середине — вскрываются первым же выстрелом и получают свой слот.
	for i in 4:
		m.set_spawn(Vector2i(mid_x() - 4 + i * 3, 22), "civilian", MCF.Owner.NEUTRAL)

static func mid_x() -> int:
	return MAP_W / 2

static func build_state() -> GameState:
	# Заполнение нейтральной зоны зависит от глобального флага — фиксируем его,
	# иначе прогон зависел бы от того, что осталось от предыдущей сцены.
	GameConfig.civilians_enabled = true
	return build_map().build_state(SEED)

# --- Слепок доски ------------------------------------------------------------

## Текстовый слепок ВСЕГО, что отличает одну доску от другой. Сравнение слепков —
## единственный честный способ поймать расхождение: журнал действий совпадает и
## при разъехавшихся позициях.
static func digest(state: GameState) -> String:
	var lines: PackedStringArray = []
	var ids: Array = state.units.keys()
	ids.sort()
	for id: int in ids:
		var u: UnitInstance = state.units[id]
		lines.append("U %d %s %d/%d st%d ap%d mc%d cap%d cor%d veh%d drg%s civ%d" % [
			u.id, str(u.coord), u.owner, u.stats.cost, u.status, u.remaining_ap,
			u.move_credit, u.captor_id, u.carried_corpses, u.aboard_vehicle_id,
			str(u.dragging), 1 if u.civilian_active else 0,
		])
	var vids: Array = state.vehicles.keys()
	vids.sort()
	for id: int in vids:
		var v: Vehicle = state.vehicles[id]
		lines.append("V %d %s %s dur%d ap%d wreck%d" % [
			v.id, v.type_id, str(v.origin), v.durability, v.ap,
			1 if v.wrecked else 0,
		])
	for y in state.grid.height:
		for x in state.grid.width:
			var c := state.grid.cell(Vector2i(x, y))
			if c.feature_id == "" and c.cover_height == 0.0 and not c.on_fire \
					and c.corpse_count == 0 and c.dirt_level == 0 \
					and not c.airlock_welded:
				continue
			lines.append("C %d,%d f=%s h=%.1f fire%d dur%d dirt%d corp%d weld%d" % [
				x, y, c.feature_id, c.cover_height, 1 if c.on_fire else 0,
				c.feature_durability, c.dirt_level, c.corpse_count,
				1 if c.airlock_welded else 0,
			])
	lines.append("T round%d slot%d order%s" % [
		state.turns.round_number, state.turns.active_index,
		str(state.turns.round_order),
	])
	return "\n".join(lines)

## Короткая подпись действия для следа: что именно попросили сделать.
static func intent_line(intent: Intent) -> String:
	var d := IntentCodec.encode(intent)
	var keys: Array = d.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		parts.append("%s=%s" % [k, str(d[k])])
	return "%s(%s)" % [intent.get_script().resource_path.get_file().get_basename(),
			" ".join(parts)]

## Результат действия в следе: успех, причина отказа, журнал, кубики, смерти.
static func result_lines(res: ActionResult) -> PackedStringArray:
	var out: PackedStringArray = []
	out.append("    ok=%s%s" % [str(res.ok),
			"" if res.reason == "" else " reason=" + res.reason])
	for l in res.log_lines:
		out.append("    log: " + l)
	for ev in res.dice_events:
		out.append("    dice: " + _flatten(ev))
	if not res.deaths.is_empty():
		var deaths: Array = res.deaths.duplicate()
		deaths.sort()
		out.append("    deaths: " + str(deaths))
	return out

## Словари событий кубиков печатаются с отсортированными ключами: порядок вставки
## воспроизводим, но сортировка снимает вопрос совсем.
static func _flatten(v: Variant) -> String:
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort()
		var parts: PackedStringArray = []
		for k in keys:
			parts.append("%s:%s" % [str(k), _flatten(v[k])])
		return "{" + ",".join(parts) + "}"
	if v is Array:
		var parts2: PackedStringArray = []
		for e in v:
			parts2.append(_flatten(e))
		return "[" + ",".join(parts2) + "]"
	return str(v)
