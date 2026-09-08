class_name FxDecals
extends RefCounted

## Косметика боя (#21): следы разрушений, осколки стекла, гильзы, кровь.
##
## НИЧЕГО ИЗ ЭТОГО НЕ ВЛИЯЕТ НА ПРАВИЛА. Здесь нет ни одной величины, которую
## спрашивает резолвер: слой живёт рядом с состоянием, а не внутри него, и партия,
## запущенная без него (headless-прогон), идёт ровно так же.
##
## Как это остаётся одинаковым у всех клиентов, ничего не пересылая.
## Резолвер, разбирая намерение, кладёт в ActionResult.fx ОПИСАНИЯ событий —
## «здесь разлетелось стекло», «отсюда вылетели три гильзы». Клиент выполняет то же
## самое намерение тем же резолвером и получает тот же список; значит достаточно,
## чтобы разброс каждой пылинки был ФУНКЦИЕЙ ОТ ОПИСАНИЯ, а не отдельным случайным
## числом. Отсюда _rng_for(): зерно собирается из координат, вида эффекта и номера
## частицы, поэтому и хост, и клиент, и будущий повтор матча (M12) построят
## побитово одну и ту же картинку.
##
## Кубики игры (DiceService) при этом НЕ ТРОГАЮТСЯ. Один брошенный ради красоты
## кубик сдвинул бы весь дальнейший поток случайности и развёл бы хост с клиентом —
## ровно та поломка, которую чинил M2.

## Уровень повреждения пола под разрушенным объектом.
const DAMAGE_NONE := 0
const DAMAGE_RUBBLE := 1     # пол в зоне взрыва
const DAMAGE_EPICENTER := 2  # клетка эпицентра — выгоревшая, сильнее побитая

## Сколько осколков даёт одно разбитое стекло (#21.2). Урезано (item 5: «гипероптимизация
## осколков») — 2..3 вместо 2..5: на бою в тысячу бойцов косметика иначе плодит тысячи точек.
const SHARDS_MIN := 2
const SHARDS_MAX := 3
## Полёт осколка/гильзы: доли клетки в секунду и длительность. «Небольшая скорость»
## из задания — осколок пролетает меньше клетки.
const SHARD_FLIGHT_SEC := 0.45
const SHARD_RANGE_MIN := 0.25
const SHARD_RANGE_MAX := 0.85
const CASING_FLIGHT_SEC := 0.35
const CASING_RANGE_MIN := 0.15
const CASING_RANGE_MAX := 0.45
## Брызги крови: капли летят против направления убившего выстрела. Урезано (item 5:
## «гипероптимизация крови») — 2..4 вместо 3..6: на 500×500 капли доминировали в кадре.
const SPLATTER_MIN := 2
const SPLATTER_MAX := 4
const SPLATTER_RANGE := 0.7

## Потолок осевших частиц. Косметика не должна расти бесконечно: длинный бой на
## большой карте иначе набирает десятки тысяч точек, и отрисовка начинает стоить
## дороже самой игры. Старые вытесняются, как в кольцевом буфере. Урезан втрое
## (item 5): на бою в тысячу бойцов 1500 осевших точек заметно роняли кадр.
const PROPS_CAP := 500

## Vector2i -> DAMAGE_*: побитый пол. Эпицентр не понижается до щебня повторным
## взрывом рядом — только повышается.
var floor_damage: Dictionary = {}
## Осевшая статика: [{kind, pos: Vector2 (в клетках), rot: float, scale: float}].
var props: Array = []
## Ещё летящие: то же плюс from/to и таймер. По приземлении переезжают в props.
var flying: Array = []

## Детерминированный генератор на одну частицу. Зерно — чистая функция от описания
## события, поэтому одинаково у всех, кто это описание получил.
static func _rng_for(kind: String, at: Vector2i, index: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	# Хеш строки Godot стабилен в пределах версии движка, а координаты и номер
	# частицы разводят соседние события между собой.
	rng.seed = hash(kind) * 1000003 + at.x * 7919 + at.y * 104729 + index * 31
	return rng

func clear() -> void:
	floor_damage.clear()
	props.clear()
	flying.clear()

## Разобрать список описаний из ActionResult.fx.
func apply(events: Array) -> void:
	for ev: Dictionary in events:
		match str(ev.get("fx", "")):
			"debris":
				_debris(ev)
			"shards":
				_shards(ev)
			"casings":
				_casings(ev)
			"blood":
				_blood(ev)

## 21.1 — пол под разрушенным объектом меняет текстуру, эпицентр сильнее прочих.
func _debris(ev: Dictionary) -> void:
	var epicenter: Vector2i = ev.get("at", Vector2i.ZERO)
	for c: Vector2i in ev.get("cells", []):
		var level: int = DAMAGE_EPICENTER if c == epicenter else DAMAGE_RUBBLE
		floor_damage[c] = maxi(int(floor_damage.get(c, DAMAGE_NONE)), level)

## 21.2 — осколки стекла: 2..5 штук, летят ПРОТИВ направления удара, у каждого свои
## скорость и вращение.
func _shards(ev: Dictionary) -> void:
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var away := _away(at, from)
	var count_rng := _rng_for("shards_n", at, 0)
	var count: int = count_rng.randi_range(SHARDS_MIN, SHARDS_MAX)
	for i in count:
		var rng := _rng_for("shard", at, i)
		_launch("shard", at, away, rng, SHARD_RANGE_MIN, SHARD_RANGE_MAX, SHARD_FLIGHT_SEC)

## 21.3 — гильзы: по одной на выстрел, вылетают ЗА спину стрелка.
func _casings(ev: Dictionary) -> void:
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var toward: Vector2i = ev.get("toward", at)
	# Гильза вылетает назад — то есть против направления стрельбы.
	var back := _away(at, toward)
	# Гильза противотанкиста (item 24): та же система, но частица «shell_casing» —
	# оранжевая и вдвое крупнее (цвет/размер задаёт отрисовка по виду частицы), и летит
	# чуть дальше обычной. Отдельный вид, чтобы не путать с пистолетной гильзой.
	var shell: bool = bool(ev.get("shell", false))
	var kind := "shell_casing" if shell else "casing"
	var r_max: float = CASING_RANGE_MAX * (1.6 if shell else 1.0)
	for i in int(ev.get("count", 0)):
		var rng := _rng_for(kind, at, i)
		_launch(kind, at, back, rng, CASING_RANGE_MIN, r_max, CASING_FLIGHT_SEC)

## 21.4 — лужа под трупом плюс веер брызг против направления убившего выстрела.
func _blood(ev: Dictionary) -> void:
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var pool_rng := _rng_for("pool", at, 0)
	props.append({
		"kind": "blood_pool", "pos": Vector2(at) + Vector2(0.5, 0.5),
		"rot": pool_rng.randf_range(0.0, TAU), "scale": pool_rng.randf_range(0.7, 1.0),
	})
	var away := _away(at, from)
	var drops_rng := _rng_for("splatter_n", at, 0)
	for i in drops_rng.randi_range(SPLATTER_MIN, SPLATTER_MAX):
		var rng := _rng_for("splatter", at, i)
		_launch("blood_drop", at, away, rng, 0.2, SPLATTER_RANGE, SHARD_FLIGHT_SEC)
	_trim()

## Направление «прочь от источника». Источник совпал с целью (взрыв под ногами,
## смерть без стрелка) — веер уходит во все стороны, и базовый угол берётся вверх.
static func _away(at: Vector2i, source: Vector2i) -> Vector2:
	var d := Vector2(at - source)
	if d == Vector2.ZERO:
		return Vector2.UP
	return d.normalized()

## Запустить одну частицу: базовое направление + разброс по углу, своя дальность и
## своё вращение. Координаты — в КЛЕТКАХ, поэтому слой не зависит от зума и размера
## клетки; в пиксели их переводит уже отрисовка.
func _launch(kind: String, at: Vector2i, dir: Vector2, rng: RandomNumberGenerator,
		r_min: float, r_max: float, flight: float) -> void:
	var spread := rng.randf_range(-0.9, 0.9)   # ±~50° от базового направления
	var d := dir.rotated(spread)
	var start := Vector2(at) + Vector2(0.5, 0.5) \
			+ Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12))
	props.resize(props.size())  # без побочных эффектов: подсказка читателю, что props — статика
	flying.append({
		"kind": kind, "from": start, "to": start + d * rng.randf_range(r_min, r_max),
		"rot0": rng.randf_range(0.0, TAU), "rot1": rng.randf_range(-TAU, TAU),
		"scale": rng.randf_range(0.6, 1.1), "t": 0.0, "dur": flight,
	})

## Продвинуть полёты. Возвращает true, если что-то изменилось и надо перерисовать.
func advance(delta: float) -> bool:
	if flying.is_empty():
		return false
	var landed: Array = []
	for i in range(flying.size() - 1, -1, -1):
		var f: Dictionary = flying[i]
		f["t"] = float(f["t"]) + delta
		if float(f["t"]) < float(f["dur"]):
			continue
		landed.append(f)
		flying.remove_at(i)
	for f: Dictionary in landed:
		props.append({
			"kind": f["kind"], "pos": f["to"],
			"rot": float(f["rot0"]) + float(f["rot1"]), "scale": f["scale"],
		})
	if not landed.is_empty():
		_trim()
	return true

## Где частица находится сейчас: линейно от from к to, с горкой по высоте, чтобы
## полёт читался как бросок, а не как скольжение.
static func flight_pos(f: Dictionary) -> Vector2:
	var k: float = clampf(float(f["t"]) / maxf(0.001, float(f["dur"])), 0.0, 1.0)
	var base: Vector2 = Vector2(f["from"]).lerp(Vector2(f["to"]), k)
	return base - Vector2(0.0, sin(k * PI) * 0.18)

static func flight_rot(f: Dictionary) -> float:
	var k: float = clampf(float(f["t"]) / maxf(0.001, float(f["dur"])), 0.0, 1.0)
	return float(f["rot0"]) + float(f["rot1"]) * k

func _trim() -> void:
	var over := props.size() - PROPS_CAP
	if over > 0:
		props = props.slice(over)

# --- Сохранение косметики (M12, item 42) ---
## Осевшая косметика — часть того, КАК выглядит бой, поэтому сохранение везёт её с
## собой: перезагруженный час боя не должен выглядеть свежевымытым. Летящее не
## сохраняется: полёт длится доли секунды и к моменту записи файла уже приземлился бы.
func to_dict() -> Dictionary:
	var damage: Array = []
	var keys: Array = floor_damage.keys()
	keys.sort()
	for c: Vector2i in keys:
		damage.append([c.x, c.y, int(floor_damage[c])])
	var settled: Array = []
	for p: Dictionary in props:
		var pos: Vector2 = p["pos"]
		settled.append([str(p["kind"]), pos.x, pos.y, float(p["rot"]), float(p["scale"])])
	return {"damage": damage, "props": settled}

func from_dict(d: Dictionary) -> void:
	clear()
	for entry in d.get("damage", []):
		if entry is Array and (entry as Array).size() >= 3:
			floor_damage[Vector2i(int(entry[0]), int(entry[1]))] = int(entry[2])
	for entry in d.get("props", []):
		if entry is Array and (entry as Array).size() >= 5:
			props.append({"kind": str(entry[0]),
					"pos": Vector2(float(entry[1]), float(entry[2])),
					"rot": float(entry[3]), "scale": float(entry[4])})
	_trim()
