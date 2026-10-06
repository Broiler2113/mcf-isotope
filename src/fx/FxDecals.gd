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
## Потолок осевших частиц. Косметика не должна расти бесконечно: длинный бой на
## большой карте иначе набирает десятки тысяч точек, и отрисовка начинает стоить
## дороже самой игры. Старые вытесняются, как в кольцевом буфере. Поднят до 1500
## вместе с щедростью осколков и брызг (issue 7): при 500 гильзы и кровь одного
## боестолкновения выдавливали следы предыдущего прямо на глазах.
## Отрисовка от этого не страдает: частицы за краем экрана отсекаются в _draw_fx_one.
## 8000 (playtest-20): игрок хочет, чтобы гильзы и осколки ОСТАВАЛИСЬ — при 1500 сетевая
## партия на четверых выдавливала первые перестрелки ещё до середины боя.
const PROPS_CAP := 8000

## Потолок отрезков лазерного следа. Считается в ОТРЕЗКАХ, а не в выстрелах: над
## космосом след не кладётся, поэтому один луч вдоль пробоины даёт несколько кусков.
const LASER_CAP := 2000
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
## Кровь и ошмётки — отдельно от props и БЕЗ вытеснения по ходу боя. Во что поле
## превратилось к концу партии —
## это и есть картина боя, и смотреть на неё игрок хочет целиком. Гильзы и осколки
## остаются в props под прежним потолком: их на порядок больше, а ценности в старых нет.
##
## Потолок здесь всё-таки есть, но заведомо выше любой партии: он страхует от
## бесконечного роста в патологическом случае, а не подчищает поле.
const GORE_CAP := 60000
const GORE_KINDS := {"blood_pool": true, "blood_drop": true, "gib": true}

## Размер частицы в долях клетки и запасной цвет, когда картинки-замены нет. Таблица
## живёт ЗДЕСЬ, а не в экране боя: по ней рисует и летящую частицу экран, и осевшую —
## TerrainTiles, когда запекает её в пол куска (0.9.3).
const LOOK := {
	"shard": [0.24, Color(0.72, 0.88, 0.95, 0.85)],
	"casing": [0.11, Color(0.85, 0.72, 0.28, 0.9)],
	# Гильза противотанкиста (item 24): оранжевая и вдвое крупнее пистолетной (0.11 → 0.22).
	"shell_casing": [0.22, Color(1.0, 0.55, 0.1, 0.95)],
	"blood_drop": [0.2, Color(0.6, 0.04, 0.04, 0.9)],
	"blood_pool": [0.95, Color(0.42, 0.03, 0.03, 0.8)],
	# Ошмётки после взрыва: тёмно-красные куски, крупнее капли.
	"gib": [0.24, Color(0.42, 0.05, 0.06, 0.95)],
}
const TEXTURE := {
	"shard": "glass_shard", "casing": "shell_casing",
	# Отдельное имя картинки, чтобы крупная оранжевая гильза при желании подменялась
	# своим png; без него сработает запасной оранжевый четырёхугольник из LOOK.
	"shell_casing": "shell_casing_big",
	"blood_drop": "blood_splatter", "blood_pool": "blood_pool",
}

## --- Осевшая косметика запекается в доску (0.9.3, по просьбе игрока) ---
## Кровь, гильзы и осколки ни с чем не взаимодействуют и никуда не денутся, поэтому
## рисовать их по точке за кадр — чистый убыток: к середине боя их десятки тысяч, и
## каждый кадр проходил по всему списку со словарными обращениями на каждую частицу.
## Теперь они ЧАСТЬ КАРТИНКИ КУСКА доски: TerrainTiles впечатывает их в пол один раз,
## при сборке куска, и дальше кадр о них вообще не знает.
##
## Отсюда — указатель «в каком куске что лежит» (by_chunk) и список кусков, которые надо
## пересобрать. Сторона куска обязана совпадать с TerrainTiles.C.
const DECAL_CHUNK := 16
var by_chunk: Dictionary = {}       # Vector2i -> Array[Dictionary]
## Куски, где косметика прибавилась с прошлого опроса.
var decal_dirty: Dictionary = {}
## Растёт на любое ИЗЪЯТИЕ осевшего (пожар, вытеснение, загрузка). Добавлением такое не
## поправить, поэтому TerrainTiles по смене этого числа выбрасывает все куски разом.
var decal_reset: int = 0

## Насколько частица может вылезти за свою клетку (см. TerrainTiles.DECAL_BLEED): у самой
## границы куска её видно и в соседнем, и пересобрать надо оба.
const DECAL_BLEED := 2

## Осевшая частица: в список и в указатель куска.
func _settle(list: Array, p: Dictionary) -> void:
	list.append(p)
	var pos: Vector2 = p["pos"]
	var cell := Vector2i(floori(pos.x), floori(pos.y))
	var cc := cell / DECAL_CHUNK
	if not by_chunk.has(cc):
		by_chunk[cc] = []
	(by_chunk[cc] as Array).append(p)
	decal_dirty[cc] = true
	# Соседние куски — только те, до которых частица и правда дотягивается.
	var lo := (cell - Vector2i(DECAL_BLEED, DECAL_BLEED)) / DECAL_CHUNK
	var hi := (cell + Vector2i(DECAL_BLEED, DECAL_BLEED)) / DECAL_CHUNK
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			decal_dirty[Vector2i(x, y)] = true

## Указатель — заново по спискам. Зовётся там, где осевшее УБЫЛО: дешевле пересобрать
## его целиком, чем искать выбывших, а случается это редко (пожар, потолок, загрузка).
func _reindex() -> void:
	by_chunk.clear()
	for list: Array in [gore, props]:
		for p: Dictionary in list:
			var pos: Vector2 = p["pos"]
			var cc := Vector2i(floori(pos.x) / DECAL_CHUNK, floori(pos.y) / DECAL_CHUNK)
			if not by_chunk.has(cc):
				by_chunk[cc] = []
			(by_chunk[cc] as Array).append(p)
	decal_dirty.clear()
	decal_reset += 1
var gore: Array = []
## Кровавых отпечатков ног больше нет (0.9.3, по просьбе игрока), а с ними и учёта «кто в
## чём испачкался». Кровь остаётся лужами и брызгами там, где пролилась.
## Ещё летящие: то же плюс from/to и таймер. По приземлении переезжают в props.
var flying: Array = []
## Отрезки лазерного следа (item 11): [{from: Vector2, to: Vector2}] в клетках.
var laser_lines: Array = []
## Следы гусениц танка (playtest-20): [{from, to}] в клетках, кусками не длиннее клетки —
## туман прячет их поклеточно, как и прочие следы, и чужой танк не выдаёт себя колеёй.
var track_marks: Array = []
const TRACKS_CAP := 6000
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

## ВСПЫШКА ВЗРЫВА (0.9.4): «explosions should turn tiles into fire for a second as an
## effect (it should be purely cosmetic)». Клетки разрыва на секунду рисуются огнём и
## гаснут. Настоящего пожара тут нет ни на одну клетку: GridCell.on_fire не трогается,
## резолвер об этом не знает, в сохранение и в снимок гостю это не едет — чистая
## декорация, как дорожки и трассеры.
##
## [{cells: Array[Vector2i], t: float}].
var flashes: Array = []
const FLASH_DUR := 1.0
## Полную силу вспышка держит эту долю времени, потом гаснет.
const FLASH_HOLD := 0.35
## Больше нескольких разрывов разом на экране не бывает — держим последние.
const FLASH_CAP := 12

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
	by_chunk.clear()
	decal_dirty.clear()
	decal_reset += 1
	flying.clear()
	laser_lines.clear()
	track_marks.clear()
	tracers.clear()
	lanes.clear()
	flashes.clear()
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
			"burn":
				_burn(ev)
			"laser":
				_laser(ev)
			"tracks":
				_tracks(ev)
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

## Насколько ярко рисовать вспышку взрыва: держится FLASH_HOLD, затем гаснет.
static func flash_alpha(flash: Dictionary) -> float:
	var t := float(flash["t"]) / FLASH_DUR
	if t <= FLASH_HOLD:
		return 1.0
	return clampf(1.0 - (t - FLASH_HOLD) / maxf(0.001, 1.0 - FLASH_HOLD), 0.0, 1.0)

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
	# Разрыв — ещё и вспышка огня на секунду (0.9.4). Только у НАСТОЯЩЕГО взрыва («blast»):
	# щебень под гусеницей танка, под снесённой лучом стеной или под разбитым окном его не
	# ставит — там ничего не рвалось.
	if bool(ev.get("blast", false)):
		var cells: Array[Vector2i] = []
		for c: Vector2i in ev.get("cells", []):
			cells.append(c)
		if not cells.is_empty():
			flashes.append({"cells": cells, "t": 0.0})
			if flashes.size() > FLASH_CAP:
				flashes = flashes.slice(flashes.size() - FLASH_CAP)

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

## Две колеи по бортам танка от старого места до нового (playtest-20). Над космосом колеи
## нет — там нечего продавить.
func _tracks(ev: Dictionary) -> void:
	var o: Array = ev.get("from", [])
	var d: Array = ev.get("dir", [])
	var sz: Array = ev.get("size", [])
	var steps := int(ev.get("steps", 0))
	if o.size() < 2 or d.size() < 2 or sz.size() < 2 or steps <= 0:
		return
	var step := Vector2(float(d[0]), float(d[1]))
	if step == Vector2.ZERO:
		return
	var dir := step.normalized()
	var perp := Vector2(-dir.y, dir.x)
	var size := Vector2(float(sz[0]), float(sz[1]))
	var c0 := Vector2(float(o[0]), float(o[1])) + size * 0.5
	var c1 := c0 + step * steps
	var half_w := (absf(perp.x) * size.x + absf(perp.y) * size.y) * 0.5 - 0.3
	var half_l := (absf(dir.x) * size.x + absf(dir.y) * size.y) * 0.5 - 0.2
	for side: float in [-1.0, 1.0]:
		var a := c0 - dir * half_l + perp * half_w * side
		var b := c1 + dir * half_l + perp * half_w * side
		for run: Array in _ground_runs(a, b):
			var ra: Vector2 = run[0]
			var rb: Vector2 = run[1]
			var n := maxi(1, ceili(ra.distance_to(rb)))
			for i in n:
				track_marks.append({"from": ra.lerp(rb, float(i) / n),
						"to": ra.lerp(rb, float(i + 1) / n)})
	if track_marks.size() > TRACKS_CAP:
		track_marks = track_marks.slice(track_marks.size() - TRACKS_CAP)

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
	_settle(gore, {
		"kind": "blood_pool", "pos": Vector2(at) + Vector2(0.5, 0.5),
		"rot": pool_rng.randf_range(0.0, TAU),
		"scale": pool_rng.randf_range(1.0, 1.3) * (1.25 if blast else 1.0),
	})
	var away := _away(at, from)
	# Подтёки вокруг главной лужи: по ходу брызг (кольцом при взрыве).
	for i in pool_rng.randi_range(2, 3) + (3 if blast else 0):
		var d := away.rotated(pool_rng.randf_range(-PI, PI) if blast else pool_rng.randf_range(-0.7, 0.7))
		var pos := Vector2(at) + Vector2(0.5, 0.5) + d * pool_rng.randf_range(0.35, 0.9 if blast else 0.7)
		pos = _clip_solid(Vector2(at) + Vector2(0.5, 0.5), pos, at)
		if _space(Vector2i(floori(pos.x), floori(pos.y))):
			continue   # подтёк не ложится на вакуум
		_settle(gore, {"kind": "blood_pool", "pos": pos, "rot": pool_rng.randf_range(0.0, TAU),
				"scale": pool_rng.randf_range(0.35, 0.6), "origin": at})
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

## Огонь съел клетку: с неё исчезает ВСЯ осевшая косметика — кровь, ошмётки, гильзы,
## осколки, отпечатки. Пламя прошло по земле, и под ним не остаётся ни лужи, ни латуни.
## Тела и машины сюда не относятся: это не косметика, и огонь их по правилам не трогает
## (см. advance_fire) — здесь их попросту нет.
##
## Копоть на полу (floor_damage) ОСТАЁТСЯ: это и есть след пожара, стирать его нечем.
func _burn(ev: Dictionary) -> void:
	var hit := {}
	for c: Vector2i in ev.get("cells", []):
		hit[c] = true
	if hit.is_empty():
		return
	props = _swept(props, hit)
	gore = _swept(gore, hit)
	_reindex()

static func _swept(list: Array, hit: Dictionary) -> Array:
	var kept: Array = []
	for p: Dictionary in list:
		var pos: Vector2 = p["pos"]
		if hit.has(Vector2i(floori(pos.x), floori(pos.y))):
			continue
		kept.append(p)
	return kept

func _space(c: Vector2i) -> bool:
	return space_at.is_valid() and bool(space_at.call(c))

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
	# Вспышки взрывов (0.9.4): гаснут по времени, отработавшие убираем.
	var flashes_active := not flashes.is_empty()
	if flashes_active:
		for i in range(flashes.size() - 1, -1, -1):
			flashes[i]["t"] = float(flashes[i]["t"]) + delta
			if float(flashes[i]["t"]) >= FLASH_DUR:
				flashes.remove_at(i)
	# Пули-трассеры (item 16): двигаем время, отработавшие убираем.
	var tracers_active := not tracers.is_empty()
	if tracers_active:
		for i in range(tracers.size() - 1, -1, -1):
			tracers[i]["t"] = float(tracers[i]["t"]) + delta
			if float(tracers[i]["t"]) >= float(tracers[i]["dur"]):
				tracers.remove_at(i)
	if flying.is_empty():
		return tracers_active or lanes_active or flashes_active
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
			_settle(gore, settled_prop)
		else:
			_settle(props, settled_prop)
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

## Запас сверх потолка, при котором вытеснение ещё не запускается (0.9.3). Вытеснение
## перебирает указатель кусков заново и выбрасывает все запечённые картинки, поэтому
## делать это на каждую осевшую гильзу нельзя: перевалив за потолок, бой пересобирал бы
## доску на каждое действие. С запасом это случается раз на SLACK частиц.
const TRIM_SLACK := 400

func _trim() -> void:
	var over := props.size() - PROPS_CAP
	var gore_over := gore.size() - GORE_CAP
	if over <= TRIM_SLACK and gore_over <= TRIM_SLACK:
		return
	if over > 0:
		props = props.slice(over)
	# Кровь вытесняется только на аварийном потолке — см. GORE_CAP.
	if gore_over > 0:
		gore = gore.slice(gore_over)
	_reindex()

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
	# Следы лазера (playtest-20): без них снимок пересинхронизации стирал гостю все подпалины.
	var lasers: Array = []
	for seg: Dictionary in laser_lines:
		var la: Vector2 = seg["from"]
		var lb: Vector2 = seg["to"]
		lasers.append([la.x, la.y, lb.x, lb.y])
	var tracks: Array = []
	for seg: Dictionary in track_marks:
		var ta: Vector2 = seg["from"]
		var tb: Vector2 = seg["to"]
		tracks.append([ta.x, ta.y, tb.x, tb.y])
	# Ключи «prints», «pools», «bloody» больше не пишутся (0.9.3): отпечатков ног нет.
	# Старые сохранения с ними читаются — лишние ключи просто никто не спрашивает.
	return {"damage": damage, "props": settled, "lasers": lasers, "tracks": tracks}

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
	_reindex()
	for e in d.get("lasers", []):
		if e is Array and (e as Array).size() >= 4:
			laser_lines.append({"from": Vector2(float(e[0]), float(e[1])),
					"to": Vector2(float(e[2]), float(e[3]))})
	for e in d.get("tracks", []):
		if e is Array and (e as Array).size() >= 4:
			track_marks.append({"from": Vector2(float(e[0]), float(e[1])),
					"to": Vector2(float(e[2]), float(e[3]))})
