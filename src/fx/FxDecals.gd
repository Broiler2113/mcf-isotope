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

## Сколько осколков даёт одно разбитое стекло (#21.2). Урезание «гипероптимизации»
## (item 5) откачено по прямой просьбе игрока (issue 7: «make more blood splatter
## particles appear as well as glass shards»): 3..6 вместо 2..3. Потолок осевших
## частиц (PROPS_CAP) поднят соразмерно, чтобы прибавка не выдавливала старые следы.
const SHARDS_MIN := 5
const SHARDS_MAX := 9
## Полёт осколка/гильзы: доли клетки в секунду и длительность. «Небольшая скорость»
## из задания — осколок пролетает меньше клетки.
const SHARD_FLIGHT_SEC := 0.45
## Осколки разлетаются на 0.7..2.4 клетки (item 7: «barely spread») — заметный веер, а не
## кучка у окна; о стену они останавливаются (solid_at).
const SHARD_RANGE_MIN := 0.7
const SHARD_RANGE_MAX := 2.4
const CASING_FLIGHT_SEC := 0.35
## Гильза обязана ВЫЛЕТЕТЬ ИЗ-ПОД БОЙЦА (issue 7). Кружок юнита занимает 0.34 клетки от
## центра, а гильзы ложились в 0.15..0.45 — то есть почти все оседали под ним, и на
## доске от очереди оставалась одна-две видимые. Теперь ближняя граница ЗАВЕДОМО дальше
## кружка: три патрона — три гильзы, которые видно.
const CASING_RANGE_MIN := 0.42
const CASING_RANGE_MAX := 0.85
## Брызги крови: капли летят против направления убившего выстрела. Тоже вернули щедрость
## (issue 7) и добавили сверх прежнего: 5..9 вместо 2..4.
## Ещё раз щедрее (gore batch): 10..16, и летят дальше — кровь видна издалека.
const SPLATTER_MIN := 10
const SPLATTER_MAX := 16
## Ближняя граница — тоже за кружком юнита: под телом брызги не видны, а лужа под ним
## и без того есть.
const SPLATTER_RANGE_MIN := 0.4
const SPLATTER_RANGE := 1.5
## Разорван взрывом или раздавлен (blast): брызги кольцом вдвое гуще и дальше, плюс ошмётки.
const GIBS_MIN := 4
const GIBS_MAX := 7
## Кровавые следы: прошёл по луже — ещё столько клеток оставляет отпечатки.
const BLOODY_STEPS := 6

## Потолок осевших частиц. Косметика не должна расти бесконечно: длинный бой на
## большой карте иначе набирает десятки тысяч точек, и отрисовка начинает стоить
## дороже самой игры. Старые вытесняются, как в кольцевом буфере. Поднят до 1500
## вместе с щедростью осколков и брызг (issue 7): при 500 гильзы и кровь одного
## боестолкновения выдавливали следы предыдущего прямо на глазах.
## Отрисовка от этого не страдает: частицы за краем экрана отсекаются в _draw_fx_one.
const PROPS_CAP := 1500

## Потолок отрезков лазерного следа. Считается в ОТРЕЗКАХ, а не в выстрелах: над
## космосом след не кладётся, поэтому один луч вдоль пробоины даёт несколько кусков.
const LASER_CAP := 200
## Шаг проверки «над чем идёт луч» в долях клетки. Мельче клетки, иначе граница куска
## встала бы по её середине и след заезжал бы в космос на пол-клетки.
const LASER_STEP := 0.25

## Край поля в клетках (batch 12 #6): гильзы, брызги и осколки ОТСКАКИВАЮТ от него,
## а не улетают в пустоту за карту. Ставит сцена боя по размеру сетки; нулевые границы
## означают «без края» — тогда всё летит как раньше (тесты без сцены).
var bounds: Vector2 = Vector2.ZERO
## Глухая ли клетка (стена) — частица до неё долетает и останавливается (item 7). Задаёт
## экран боя; без него частицы летят как раньше.
var solid_at: Callable = Callable()
## Клетка — открытый космос (batch borg-corpses): ни луж, ни брызг; взрыв даёт только куски.
var space_at: Callable = Callable()

## Vector2i -> DAMAGE_*: побитый пол. Эпицентр не понижается до щебня повторным
## взрывом рядом — только повышается.
var floor_damage: Dictionary = {}
## Растёт на каждую правку floor_damage: экран боя по нему перекрашивает дальний план.
var damage_version: int = 0
## Осевшая статика: [{kind, pos: Vector2 (в клетках), rot: float, scale: float}].
var props: Array = []
## Кровь и ошмётки — отдельно от props и БЕЗ вытеснения по ходу боя. Та же мысль, что
## развела props и prints, доведённая до конца: во что поле превратилось к концу партии —
## это и есть картина боя, и смотреть на неё игрок хочет целиком. Гильзы и осколки
## остаются в props под прежним потолком: их на порядок больше, а ценности в старых нет.
##
## Потолок здесь всё-таки есть, но заведомо выше любой партии: он страхует от
## бесконечного роста в патологическом случае, а не подчищает поле.
const GORE_CAP := 60000
const GORE_KINDS := {"blood_pool": true, "blood_drop": true, "gib": true}
var gore: Array = []
## Кровавые отпечатки ног — отдельно от props со своим потолком, чтобы длинные цепочки
## следов не вытесняли лужи. Те же поля, что у props.
var prints: Array = []
## Клетки с лужей крови (по ним считаются следы) и id бойца -> сколько клеток ещё следить.
var pool_cells: Dictionary = {}
var bloody: Dictionary = {}
## Ещё летящие: то же плюс from/to и таймер. По приземлении переезжают в props.
var flying: Array = []
## Отрезки лазерного следа (item 11): [{from: Vector2, to: Vector2}] в клетках.
var laser_lines: Array = []
## Летящие пули-трассеры (item 16): [{from, to, t, dur}] в клетках. Живут доли секунды,
## по истечении исчезают. Не оседают — это мгновенный полёт снаряда от стрелка к цели.
var tracers: Array = []
const TRACER_DUR := 0.16

## Дорожки боя «кто в кого» (issue 8: «add visual clues that would tell the player who is
## shooting at who»). Трассер длится 0.16 с — этого хватает, чтобы заметить выстрел, но
## не хватает, чтобы РАЗОБРАТЬ, кто по кому работает, особенно в чужой ход, когда стреляют
## сразу несколько бойцов. Дорожка живёт заметно дольше пули: широкая линия в цвете
## стороны стрелка, кольцо у стрелка и прицел у цели.
##
## [{from: Vector2, to: Vector2, owner: int, kind: String, t: float}] — в клетках, как и
## всё в этом слое; в пиксели переводит отрисовка.
var lanes: Array = []
## Держится в полную силу LANE_HOLD, затем гаснет к LANE_DUR. Пережить бросок кубика
## обязана: дорожка ставится ДО броска, чтобы игрок видел прицел ещё до результата.
const LANE_HOLD := 1.4
const LANE_DUR := 3.0
## Больше десятка дорожек на экране — уже каша: держим последние.
const LANE_CAP := 12

## Порядковый номер разобранного события — «соль» к зерну частиц (issue 7).
##
## Зерно собиралось из вида, клетки и номера частицы, и этого не хватало: пулемётчик,
## стреляющий с ОДНОЙ клетки, каждую очередь получал ТЕ ЖЕ гильзы в ТЕХ ЖЕ точках —
## новые ложились ровно поверх старых, и вместо трёх гильз на три патрона игрок видел
## одну («make casings appear every time a shot happens, it's not true for now»).
## Счётчик разводит повторные события между собой.
##
## Детерминированность не страдает: хост, клиент и повтор разбирают ОДИН И ТОТ ЖЕ
## список описаний в ОДНОМ И ТОМ ЖЕ порядке, значит и счётчик у них идёт одинаково.
## Кубики игры (DiceService) он по-прежнему не трогает.
var _event_seq: int = 0
## Зерно текущего события: номер из доски (ev["seq"], ставит резолвер — один у всех пиров);
## у событий без номера (старые записи) — местный счётчик, как раньше.
var _seq: int = 0

## Детерминированный генератор на одну частицу. Зерно — чистая функция от описания
## события и его порядкового номера, поэтому одинаково у всех, кто это описание получил.
static func _rng_for(kind: String, at: Vector2i, index: int,
		salt: int = 0) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	# Хеш строки Godot стабилен в пределах версии движка, а координаты и номер
	# частицы разводят соседние события между собой.
	rng.seed = hash(kind) * 1000003 + at.x * 7919 + at.y * 104729 + index * 31 \
			+ salt * 2654435761
	return rng

func clear() -> void:
	floor_damage.clear()
	damage_version += 1
	props.clear()
	gore.clear()
	prints.clear()
	pool_cells.clear()
	bloody.clear()
	flying.clear()
	laser_lines.clear()
	tracers.clear()
	lanes.clear()
	_event_seq = 0

## Пуля-трассер (item 16): короткий полёт от стрелка к цели. По одному следу на выстрел,
## но чуть разнесённые по времени, чтобы очередь читалась как несколько пуль.
func _tracer(ev: Dictionary) -> void:
	var from_arr: Array = ev.get("from", [])
	var to_arr: Array = ev.get("to", [])
	if from_arr.size() < 2 or to_arr.size() < 2:
		return
	var a := Vector2(float(from_arr[0]) + 0.5, float(from_arr[1]) + 0.5)
	var b := Vector2(float(to_arr[0]) + 0.5, float(to_arr[1]) + 0.5)
	var n: int = maxi(1, int(ev.get("count", 1)))
	for i in n:
		tracers.append({"from": a, "to": b, "t": -0.05 * i, "dur": TRACER_DUR})

## Дорожки «кто в кого» (issue 8) разбираются ОТДЕЛЬНЫМ заходом — до броска кубика,
## тогда как остальная косметика ложится после него (иначе кровь опережала бы решение
## кубика). Счётчик событий ведут оба захода, поэтому порядок зерна одинаков у всех,
## кто разбирает тот же список.
func apply_lanes(events: Array) -> void:
	_apply(events, true)

## Разобрать список описаний из ActionResult.fx (дорожки — за apply_lanes()).
func apply(events: Array) -> void:
	_apply(events, false)

func _apply(events: Array, lanes_only: bool) -> void:
	for ev: Dictionary in events:
		_event_seq += 1
		_seq = int(ev["seq"]) if ev.has("seq") else _event_seq
		var fx_kind := str(ev.get("fx", ""))
		if (fx_kind == "lane") != lanes_only:
			continue
		match fx_kind:
			"debris":
				_debris(ev)
			"shards":
				_shards(ev)
			"casings":
				_casings(ev)
			"blood":
				_blood(ev)
			"steps":
				_steps(ev)
			"laser":
				_laser(ev)
			"tracer":
				_tracer(ev)
			"lane":
				_lane(ev)

## Дорожка боя (issue 8): от стрелка к цели, в цвете стороны стрелка.
func _lane(ev: Dictionary) -> void:
	var from_arr: Array = ev.get("from", [])
	var to_arr: Array = ev.get("to", [])
	if from_arr.size() < 2 or to_arr.size() < 2:
		return
	lanes.append({
		"from": Vector2(float(from_arr[0]) + 0.5, float(from_arr[1]) + 0.5),
		"to": Vector2(float(to_arr[0]) + 0.5, float(to_arr[1]) + 0.5),
		"owner": int(ev.get("owner", -1)), "kind": str(ev.get("kind", "shot")), "t": 0.0,
	})
	if lanes.size() > LANE_CAP:
		lanes = lanes.slice(lanes.size() - LANE_CAP)

## Насколько ярко рисовать дорожку: полная сила, пока держится, потом гаснет.
static func lane_alpha(lane: Dictionary) -> float:
	var t := float(lane["t"])
	if t <= LANE_HOLD:
		return 1.0
	return clampf(1.0 - (t - LANE_HOLD) / maxf(0.001, LANE_DUR - LANE_HOLD), 0.0, 1.0)

## 21.1 — пол под разрушенным объектом меняет текстуру, эпицентр сильнее прочих.
func _debris(ev: Dictionary) -> void:
	var epicenter: Vector2i = ev.get("at", Vector2i.ZERO)
	for c: Vector2i in ev.get("cells", []):
		# В открытом космосе щебню не на чем лежать — там нет пола, который можно побить
		# (batch borg-corpses: по той же причине там нет ни луж, ни брызг). Экраны боя
		# космическую клетку и так рисуют как космос, но запись о ней уезжала в to_dict()
		# и гостю при пересинхронизации, и каждая такая клетка зря перекрашивала чанк.
		if _space(c):
			continue
		var level: int = DAMAGE_EPICENTER if c == epicenter else DAMAGE_RUBBLE
		floor_damage[c] = maxi(int(floor_damage.get(c, DAMAGE_NONE)), level)
	damage_version += 1

## 21.2 — осколки стекла: 2..5 штук, летят ПРОТИВ направления удара, у каждого свои
## скорость и вращение.
func _shards(ev: Dictionary) -> void:
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var away := _away(at, from)
	var count_rng := _rng_for("shards_n", at, 0, _seq)
	var count: int = count_rng.randi_range(SHARDS_MIN, SHARDS_MAX)
	for i in count:
		var rng := _rng_for("shard", at, i, _seq)
		_launch("shard", at, away, rng, SHARD_RANGE_MIN, SHARD_RANGE_MAX, SHARD_FLIGHT_SEC, 1.25)

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
	var r_max: float = CASING_RANGE_MAX * (1.3 if shell else 1.0)
	for i in int(ev.get("count", 0)):
		var rng := _rng_for(kind, at, i, _seq)
		_launch(kind, at, back, rng, CASING_RANGE_MIN, r_max, CASING_FLIGHT_SEC)

## След лазера на полу (item 10/11): непрерывная ПОЛУПРОЗРАЧНАЯ ЧЁРНАЯ ЛИНИЯ от стрелка
## прямо до точки остановки — единым отрезком, поэтому диагонали рисуются как есть, без
## лесенки из точек. Детерминированно, DiceService не трогаем.
func _laser(ev: Dictionary) -> void:
	var from_arr: Array = ev.get("from", [])
	var to_arr: Array = ev.get("to", [])
	if from_arr.size() < 2 or to_arr.size() < 2:
		return
	var a := Vector2(float(from_arr[0]) + 0.5, float(from_arr[1]) + 0.5)
	var b := Vector2(float(to_arr[0]) + 0.5, float(to_arr[1]) + 0.5)
	# Над космосом отметины нет: пола, на котором остаётся подпалина, там нет вовсе.
	# Луч при этом летит как раньше — делится только СЛЕД, по клеткам под ним.
	for run: Array in _ground_runs(a, b):
		laser_lines.append({"from": run[0], "to": run[1]})
	# Не копим бесконечно — держим последние отрезки, как и осевшие частицы.
	if laser_lines.size() > LASER_CAP:
		laser_lines = laser_lines.slice(laser_lines.size() - LASER_CAP)

## Куски отрезка a→b, идущие НАД ПОЛОМ, в виде [[начало, конец], …]. Космические клетки
## выбрасываются, соседние клетки с полом склеиваются в один кусок — ровная линия там, где
## пол непрерывен, и разрыв ровно над пробоиной.
func _ground_runs(a: Vector2, b: Vector2) -> Array:
	if not space_at.is_valid():
		return [[a, b]]   # без сцены (headless-тесты) — как раньше, одним отрезком
	var out: Array = []
	var dist := a.distance_to(b)
	if dist <= 0.0:
		return [] if _space(Vector2i(floori(a.x), floori(a.y))) else [[a, b]]
	var steps := maxi(2, int(ceil(dist / LASER_STEP)))
	var start := -1.0
	for i in steps + 1:
		var t := float(i) / float(steps)
		var p := a.lerp(b, t)
		var over_floor := not _space(Vector2i(floori(p.x), floori(p.y)))
		if over_floor and start < 0.0:
			start = t
		elif not over_floor and start >= 0.0:
			out.append([a.lerp(b, start), a.lerp(b, t)])
			start = -1.0
	if start >= 0.0:
		out.append([a.lerp(b, start), b])
	return out

## 21.4 — лужа под трупом плюс веер брызг против направления убившего выстрела.
func _blood(ev: Dictionary) -> void:
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var blast: bool = bool(ev.get("blast", false))
	if _space(at):
		# В вакууме кровь не растекается и не брызжет; от взрыва летят только куски.
		if blast:
			var srng := _rng_for("splatter_n", at, 0, _seq)
			for i in srng.randi_range(GIBS_MIN, GIBS_MAX):
				_launch("gib", at, _away(at, from), _rng_for("gib", at, i, _seq), 0.5, 2.2,
						SHARD_FLIGHT_SEC * 1.4, PI)
			_trim()
		return
	var pool_rng := _rng_for("pool", at, 0, _seq)
	gore.append({
		"kind": "blood_pool", "pos": Vector2(at) + Vector2(0.5, 0.5),
		"rot": pool_rng.randf_range(0.0, TAU),
		"scale": pool_rng.randf_range(1.0, 1.3) * (1.25 if blast else 1.0),
	})
	pool_cells[at] = true
	var away := _away(at, from)
	# Подтёки вокруг главной лужи: по ходу брызг (кольцом при взрыве).
	for i in pool_rng.randi_range(2, 3) + (3 if blast else 0):
		var d := away.rotated(pool_rng.randf_range(-PI, PI) if blast else pool_rng.randf_range(-0.7, 0.7))
		var pos := Vector2(at) + Vector2(0.5, 0.5) + d * pool_rng.randf_range(0.35, 0.9 if blast else 0.7)
		pos = _clip_solid(Vector2(at) + Vector2(0.5, 0.5), pos, at)
		if _space(Vector2i(floori(pos.x), floori(pos.y))):
			continue   # подтёк не ложится на вакуум
		gore.append({"kind": "blood_pool", "pos": pos, "rot": pool_rng.randf_range(0.0, TAU),
				"scale": pool_rng.randf_range(0.35, 0.6), "origin": at})
		if blast:
			pool_cells[Vector2i(floori(pos.x), floori(pos.y))] = true
	var fan := PI if blast else 0.9
	var reach := 1.6 if blast else 1.0
	var drops_rng := _rng_for("splatter_n", at, 0, _seq)
	for i in drops_rng.randi_range(SPLATTER_MIN, SPLATTER_MAX) * (2 if blast else 1):
		var rng := _rng_for("splatter", at, i, _seq)
		_launch("blood_drop", at, away, rng, SPLATTER_RANGE_MIN, SPLATTER_RANGE * reach,
				SHARD_FLIGHT_SEC, fan)
	if blast:
		for i in drops_rng.randi_range(GIBS_MIN, GIBS_MAX):
			var rng := _rng_for("gib", at, i, _seq)
			_launch("gib", at, away, rng, 0.5, 2.2, SHARD_FLIGHT_SEC * 1.4, PI)
	_trim()

func _space(c: Vector2i) -> bool:
	return space_at.is_valid() and bool(space_at.call(c))

## Шаги бойца (gore batch): наступил в лужу — следующие BLOODY_STEPS клеток оставляет
## отпечатки, всё бледнее. Чистая косметика: только из описания хода, без кубиков.
func _steps(ev: Dictionary) -> void:
	var id := int(ev.get("unit", -1))
	var prev: Vector2i = ev.get("from", Vector2i.ZERO)
	if pool_cells.has(prev):
		bloody[id] = BLOODY_STEPS
	for c: Vector2i in ev.get("path", []):
		var left := int(bloody.get(id, 0))
		if left > 0:
			var dir := Vector2(c - prev)
			prints.append({"kind": "footprint", "pos": Vector2(c) + Vector2(0.5, 0.5),
					"rot": dir.angle(), "scale": float(left) / BLOODY_STEPS, "origin": c})
			left -= 1
			if left > 0:
				bloody[id] = left
			else:
				bloody.erase(id)
		if pool_cells.has(c):
			bloody[id] = BLOODY_STEPS
		prev = c
	# Отпечатки — тоже кровь, и живут столько же: вытесняются лишь на аварийном потолке.
	if prints.size() > GORE_CAP:
		prints = prints.slice(prints.size() - GORE_CAP)

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
## fan — полуширина веера в радианах (0.9 ≈ ±50°, у осколков шире).
func _launch(kind: String, at: Vector2i, dir: Vector2, rng: RandomNumberGenerator,
		r_min: float, r_max: float, flight: float, fan: float = 0.9) -> void:
	var spread := rng.randf_range(-fan, fan)
	var d := dir.rotated(spread)
	var start := Vector2(at) + Vector2(0.5, 0.5) \
			+ Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12))
	var to: Vector2 = _clip_solid(start, start + d * rng.randf_range(r_min, r_max), at)
	var f := {
		"kind": kind, "from": start, "to": to, "origin": at,
		"rot0": rng.randf_range(0.0, TAU), "rot1": rng.randf_range(-TAU, TAU),
		"scale": rng.randf_range(0.6, 1.1), "t": 0.0, "dur": flight,
	}
	# Отскок от края поля (batch 12 #6): частица долетает до стенки и отражается —
	# остаток пути идёт обратно внутрь. Точка удара и доля полёта до неё запоминаются,
	# чтобы траектория на экране действительно ломалась о край.
	var b := _bounce(start, to)
	if not b.is_empty():
		f["to"] = b["to"]
		f["via"] = b["via"]
		f["split"] = b["split"]
	flying.append(f)

## Отражение отрезка полёта от края поля (batch 12 #6). Пусто — край не задет.
## {via: точка удара, split: доля полёта до неё, to: конец после отскока}.
## Путь частицы обрывается перед первой глухой клеткой (item 7): осколок, улетевший в
## стену рядом с окном, лежит у её подножия, а не «внутри» стены, где его не видно.
## Своя клетка (окно, которое только что разбилось) не считается.
func _clip_solid(from: Vector2, to: Vector2, own: Vector2i) -> Vector2:
	if not solid_at.is_valid():
		return to
	var steps := maxi(1, int(ceil(from.distance_to(to) / 0.2)))
	var last := from
	for i in range(1, steps + 1):
		var p := from.lerp(to, float(i) / steps)
		var c := Vector2i(floori(p.x), floori(p.y))
		if c != own and bool(solid_at.call(c)):
			return last
		last = p
	return to

func _bounce(from: Vector2, to: Vector2) -> Dictionary:
	if bounds.x <= 0.0 or bounds.y <= 0.0:
		return {}
	var d := to - from
	var best_t := 2.0
	var axis := -1
	# Первая из четырёх стенок, которую пересекает отрезок.
	for cand in [[0.0, 0], [bounds.x, 0], [0.0, 1], [bounds.y, 1]]:
		var wall: float = cand[0]
		var ax: int = cand[1]
		var comp := d.x if ax == 0 else d.y
		if absf(comp) < 0.0001:
			continue
		var origin := from.x if ax == 0 else from.y
		var t := (wall - origin) / comp
		if t > 0.0 and t <= 1.0 and t < best_t:
			best_t = t
			axis = ax
	if axis < 0:
		return {}
	var via := from + d * best_t
	var rest := d * (1.0 - best_t)
	if axis == 0:
		rest.x = -rest.x
	else:
		rest.y = -rest.y
	var end := via + rest
	# Угол поля: второй стенки не считаем, просто не даём вылететь.
	end.x = clampf(end.x, 0.02, bounds.x - 0.02)
	end.y = clampf(end.y, 0.02, bounds.y - 0.02)
	return {"via": via, "split": best_t, "to": end}

## Продвинуть полёты. Возвращает true, если что-то изменилось и надо перерисовать.
func advance(delta: float) -> bool:
	# Дорожки «кто в кого» (issue 8): гаснут по времени, отработавшие убираем.
	var lanes_active := not lanes.is_empty()
	if lanes_active:
		for i in range(lanes.size() - 1, -1, -1):
			lanes[i]["t"] = float(lanes[i]["t"]) + delta
			if float(lanes[i]["t"]) >= LANE_DUR:
				lanes.remove_at(i)
	# Пули-трассеры (item 16): двигаем время, отработавшие убираем.
	var tracers_active := not tracers.is_empty()
	if tracers_active:
		for i in range(tracers.size() - 1, -1, -1):
			tracers[i]["t"] = float(tracers[i]["t"]) + delta
			if float(tracers[i]["t"]) >= float(tracers[i]["dur"]):
				tracers.remove_at(i)
	if flying.is_empty():
		return tracers_active or lanes_active
	var landed: Array = []
	for i in range(flying.size() - 1, -1, -1):
		var f: Dictionary = flying[i]
		f["t"] = float(f["t"]) + delta
		if float(f["t"]) < float(f["dur"]):
			continue
		landed.append(f)
		flying.remove_at(i)
	for f: Dictionary in landed:
		# Капля, долетевшая до вакуума, не ложится пятном (batch borg-corpses).
		if f["kind"] == "blood_drop" and _space(Vector2i(floori(f["to"].x), floori(f["to"].y))):
			continue
		var settled_prop := {
			"kind": f["kind"], "pos": f["to"],
			"rot": float(f["rot0"]) + float(f["rot1"]), "scale": f["scale"],
			"origin": f.get("origin", Vector2i(floori(f["to"].x), floori(f["to"].y))),
		}
		if GORE_KINDS.has(str(f["kind"])):
			gore.append(settled_prop)
		else:
			props.append(settled_prop)
	if not landed.is_empty():
		_trim()
	return true

## Где частица находится сейчас: линейно от from к to, с горкой по высоте, чтобы
## полёт читался как бросок, а не как скольжение.
static func flight_pos(f: Dictionary) -> Vector2:
	var k: float = clampf(float(f["t"]) / maxf(0.001, float(f["dur"])), 0.0, 1.0)
	var base: Vector2
	if f.has("via"):
		# Ломаная: до стенки — и обратно от неё (batch 12 #6).
		var split: float = clampf(float(f["split"]), 0.001, 0.999)
		if k < split:
			base = Vector2(f["from"]).lerp(Vector2(f["via"]), k / split)
		else:
			base = Vector2(f["via"]).lerp(Vector2(f["to"]), (k - split) / (1.0 - split))
	else:
		base = Vector2(f["from"]).lerp(Vector2(f["to"]), k)
	return base - Vector2(0.0, sin(k * PI) * 0.18)

static func flight_rot(f: Dictionary) -> float:
	var k: float = clampf(float(f["t"]) / maxf(0.001, float(f["dur"])), 0.0, 1.0)
	return float(f["rot0"]) + float(f["rot1"]) * k

func _trim() -> void:
	var over := props.size() - PROPS_CAP
	if over > 0:
		props = props.slice(over)
	# Кровь вытесняется только на аварийном потолке — см. GORE_CAP.
	var gore_over := gore.size() - GORE_CAP
	if gore_over > 0:
		gore = gore.slice(gore_over)

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
	# Кровь едет тем же списком "props", что и гильзы: формат на проводе не меняется, и
	# сверка декалей у хоста с гостем (batch mp-perf) остаётся побайтово той же. Обратно
	# from_dict() разводит записи по виду частицы.
	var settled: Array = []
	for p: Dictionary in props + gore:
		var pos: Vector2 = p["pos"]
		settled.append([str(p["kind"]), pos.x, pos.y, float(p["rot"]), float(p["scale"])])
	# Ещё летящие осколки и брызги — там, где они лягут (batch mp-perf): снимок уходит гостю
	# при пересинхронизации, и без них у него недоставало бы последнего выстрела.
	for f: Dictionary in flying:
		var to: Vector2 = f["to"]
		if f["kind"] == "blood_drop" and _space(Vector2i(floori(to.x), floori(to.y))):
			continue
		settled.append([str(f["kind"]), to.x, to.y, float(f["rot0"]) + float(f["rot1"]), float(f["scale"])])
	var steps: Array = []
	for p: Dictionary in prints:
		var pos: Vector2 = p["pos"]
		steps.append([pos.x, pos.y, float(p["rot"]), float(p["scale"])])
	var pools: Array = []
	for c: Vector2i in pool_cells:
		pools.append([c.x, c.y])
	var feet: Array = []
	for id in bloody:
		feet.append([int(id), int(bloody[id])])
	return {"damage": damage, "props": settled, "prints": steps, "pools": pools, "bloody": feet}

func from_dict(d: Dictionary) -> void:
	clear()
	for entry in d.get("damage", []):
		if entry is Array and (entry as Array).size() >= 3:
			floor_damage[Vector2i(int(entry[0]), int(entry[1]))] = int(entry[2])
	damage_version += 1
	for entry in d.get("props", []):
		if entry is Array and (entry as Array).size() >= 5:
			var loaded := {"kind": str(entry[0]),
					"pos": Vector2(float(entry[1]), float(entry[2])),
					"rot": float(entry[3]), "scale": float(entry[4])}
			if GORE_KINDS.has(str(entry[0])):
				gore.append(loaded)
			else:
				props.append(loaded)
	_trim()
	for e in d.get("prints", []):
		if e is Array and (e as Array).size() >= 4:
			var pos := Vector2(float(e[0]), float(e[1]))
			prints.append({"kind": "footprint", "pos": pos, "rot": float(e[2]),
					"scale": float(e[3]), "origin": Vector2i(floori(pos.x), floori(pos.y))})
	for e in d.get("pools", []):
		if e is Array and (e as Array).size() >= 2:
			pool_cells[Vector2i(int(e[0]), int(e[1]))] = true
	for e in d.get("bloody", []):
		if e is Array and (e as Array).size() >= 2:
			bloody[int(e[0])] = int(e[1])
