class_name FxDecals
extends RefCounted
## Emitted only by the client cosmetic lifecycle; never serialized or recorded.
signal sound_requested(id: String, cell: Vector2i, owner: int)
signal sound_reset
## The rounds after the first of a volley (playtest 2026-10-19: one recorded shot per
## bullet, at the weapon's own cadence — BattleAudio.volley).
signal volley_requested(id: String, cell: Vector2i, owner: int, count: int)
var audio_suppressed := false
## Muzzle sound by the lane's weapon (shooter unit type, or the mounted gun); anything
## else fires the service rifle. One shot is heard per bullet fired.
const WEAPON_SOUND := {"sniper": "sniper", "assault": "shotgun", "machinegunner": "mg",
	"dpmg": "heavy_mg", "borg": "heavy_mg"}

func _sound(id: String, cell: Vector2i, owner := -1) -> void:
	if not audio_suppressed:
		sound_requested.emit(id, cell, owner)

# Invisible arena boundaries constrain units, never drifting particles in vacuum.
static func solid_in(state: GameState, coord: Vector2i) -> bool:
	var cell := state.grid.cell(coord) if state != null else null
	if state != null and state.env in ["station", "asteroid"]:
		if cell == null or cell.feature_id == MCF.FEATURE_BOUNDARY: return false
	return cell == null or cell.cover_height >= MCF.WALL_HEIGHT

static func space_in(state: GameState, coord: Vector2i) -> bool:
	var cell := state.grid.cell(coord) if state != null else null
	if state != null and state.env in ["station", "asteroid"]:
		if cell == null or cell.feature_id == MCF.FEATURE_BOUNDARY: return true
	return cell != null and cell.is_space


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
## particles appear as well as glass shards»): 3..6 вместо 2..3.
## Обломки стены (0.12.1): больше осколков стекла и чуть крупнее, летят так же. Вид —
## «chunk:<картинка стены>»: кусок её же плитки, поэтому кирпич сыплется кирпичом.
const CHUNKS_MIN := 8
const CHUNKS_MAX := 14
const CHUNK_SIZE := 0.32
## Формы обломков (0.12.2, владелец: «sharper and vary in size and shape»): острые
## многоугольники в долях половины размера. Вид частицы — «chunk:<картинка>#<форма>»;
## без «#» (0.12.1) — форма 2.
const CHUNK_SHAPES := [
	[Vector2(-1.0, -0.55), Vector2(0.95, -0.9), Vector2(0.15, 1.0)],
	[Vector2(-1.0, -0.22), Vector2(1.0, -0.42), Vector2(0.85, 0.28), Vector2(-0.8, 0.2)],
	[Vector2(-0.7, -0.9), Vector2(0.6, -0.7), Vector2(1.0, 0.4), Vector2(0.1, 0.95), Vector2(-0.9, 0.3)],
	[Vector2(-0.95, -0.95), Vector2(0.95, -0.45), Vector2(-0.35, 0.95)],
	[Vector2(-0.95, -0.5), Vector2(0.3, -0.95), Vector2(0.95, 0.0), Vector2(0.45, 0.6), Vector2(-0.15, 0.25), Vector2(-0.85, 0.9)],
	[Vector2(-0.6, -1.0), Vector2(0.75, -0.55), Vector2(0.5, 0.9), Vector2(-0.85, 0.5)],
]
const CHUNK_SCALE_MIN := 0.45
const CHUNK_SCALE_MAX := 1.6

## Картинка и форма обломка по виду частицы.
static func chunk_parts(kind: String) -> Array:
	var body := kind.substr(6)
	var cut := body.rfind("#")
	if cut < 0:
		return [body, 2]
	return [body.substr(0, cut), clampi(int(body.substr(cut + 1)), 0, CHUNK_SHAPES.size() - 1)]
## Копоть на месте взрыва (0.12.1): «soot:<0..SOOT_VARIANTS-1>», у каждого вида своя форма
## пятна; эпицентр — крупное, клетки вокруг — пятна поменьше и не все.
const SOOT_VARIANTS := 4
const SOOT_COLOR := Color(0.05, 0.045, 0.04, 0.6)
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
## Потолков у осевшей косметики нет (0.12.1, владелец: «remove all decal caps»): гильзы,
## осколки, кровь, следы лазера и колеи остаются до конца боя. Отрисовке это не вредит —
## осевшее запечено в картинки кусков доски (0.9.3), кадр о нём не знает.
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
## Кровь и ошмётки — отдельно от props: экран боя и запекание обходят их первыми.
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
## Кровь на стенах (fix-7 #16): {"cell": клетка стены, "face": Vector2i — сторона, глядящая
## на тело, "rot", "scale"}. Ложится, когда боец гибнет вплотную к стене.
var wall_blood: Array = []
## Кровавых отпечатков ног больше нет (0.9.3, по просьбе игрока), а с ними и учёта «кто в
## чём испачкался». Кровь остаётся лужами и брызгами там, где пролилась.
## Ещё летящие: то же плюс from/to и таймер. По приземлении переезжают в props.
var flying: Array = []
## Отрезки лазерного следа (item 11): [{from: Vector2, to: Vector2}] в клетках.
var laser_lines: Array = []
## Short-lived beams are separate from the permanent scorches on the floor.
var beams: Array = []
## Следы гусениц танка (playtest-20): [{from, to}] в клетках, кусками не длиннее клетки —
## туман прячет их поклеточно, как и прочие следы, и чужой танк не выдаёт себя колеёй.
var track_marks: Array = []
var ground_version := 0
## Летящие пули-трассеры (item 16): [{from, to, t, dur}] в клетках. Живут доли секунды,
## по истечении исчезают. Не оседают — это мгновенный полёт снаряда от стрелка к цели.
var tracers: Array = []
## Летящие снаряды (0.12.1): ракета, снаряд танка, граната — {kind, from, to, t, dur}. Как и
## трассеры, живут доли секунды и не сохраняются.
var shots: Array = []
## Секунд на клетку полёта по виду снаряда; полёт — в пределах SHOT_MIN..SHOT_MAX.
const SHOT_PACE := {"rocket": 0.06, "shell": 0.045, "grenade": 0.09}
const SHOT_MIN := 0.18
const SHOT_MAX := 0.55
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
	sound_reset.emit()
	floor_damage.clear()
	damage_version += 1
	props.clear()
	gore.clear()
	wall_blood.clear()
	by_chunk.clear()
	decal_dirty.clear()
	decal_reset += 1
	flying.clear()
	laser_lines.clear()
	beams.clear()
	track_marks.clear()
	ground_version += 1
	tracers.clear()
	shots.clear()
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

## Снаряд в полёте (0.12.1): от клетки к клетке, за shot_dur(ev).
func _shot(ev: Dictionary) -> void:
	var a: Array = ev.get("from", [])
	var b: Array = ev.get("to", [])
	if a.size() < 2 or b.size() < 2:
		return
	_sound(str(ev.get("kind", "shell")) + "_launch", Vector2i(int(a[0]), int(a[1])))
	shots.append({"kind": str(ev.get("kind", "shell")), "t": 0.0, "dur": shot_dur(ev),
			"from": Vector2(float(a[0]) + 0.5, float(a[1]) + 0.5),
			"to": Vector2(float(b[0]) + 0.5, float(b[1]) + 0.5)})

## Сколько летит снаряд события «shot»: по дальности и виду. Этим же экран ждёт попадания.
static func shot_dur(ev: Dictionary) -> float:
	var a: Array = ev.get("from", [0, 0])
	var b: Array = ev.get("to", [0, 0])
	var cells := Vector2(float(a[0]), float(a[1])).distance_to(Vector2(float(b[0]), float(b[1])))
	return clampf(cells * float(SHOT_PACE.get(str(ev.get("kind", "")), 0.05)), SHOT_MIN, SHOT_MAX)

## Через сколько трассер события «tracer» долетает до цели (последняя пуля очереди).
static func tracer_dur(ev: Dictionary) -> float:
	return TRACER_DUR + 0.05 * float(maxi(1, int(ev.get("count", 1))) - 1)

## Firing lanes are launched after the dice, alongside projectiles and muzzle lighting.
## They use a separate pass from impact effects; both passes keep event seeds stable.
func apply_lanes(events: Array) -> void:
	_apply(events, true)
	# A previewed lane the shot did not take over still fades like any other.
	for lane: Dictionary in lanes:
		lane.erase("hold")

## Before the dice (owner, 2026-10-19): who fires at whom shows while the dice roll —
## the line only, aimed at the intended target, with no sound, no muzzle light and no
## fade. The shot (apply_lanes) takes these lanes over and starts them from there.
func preview_lanes(events: Array) -> void:
	for ev: Dictionary in events:
		if ev.get("fx") != "lane":
			continue
		var lane := _lane_entry(ev)
		if lane.is_empty():
			continue
		lane["hold"] = true
		lanes.append(lane)
	if lanes.size() > LANE_CAP:
		lanes = lanes.slice(lanes.size() - LANE_CAP)

func _lane_entry(ev: Dictionary) -> Dictionary:
	var from_arr: Array = ev.get("from", [])
	var to_arr: Array = ev.get("to", [])
	if from_arr.size() < 2 or to_arr.size() < 2:
		return {}
	return {
		"from": Vector2(float(from_arr[0]) + 0.5, float(from_arr[1]) + 0.5),
		"to": Vector2(float(to_arr[0]) + 0.5, float(to_arr[1]) + 0.5),
		"owner": int(ev.get("owner", -1)), "kind": str(ev.get("kind", "shot")), "t": 0.0,
	}

## Разобрать список описаний из ActionResult.fx (дорожки — за apply_lanes()).
func apply(events: Array, projectile_blast := false) -> void:
	_apply(events, false, projectile_blast or events.any(func(e: Dictionary) -> bool: return e.get("fx") == "shot"))

func _apply(events: Array, lanes_only: bool, projectile_blast := false) -> void:
	for ev: Dictionary in events:
		_event_seq += 1
		_seq = int(ev["seq"]) if ev.has("seq") else _event_seq
		var fx_kind := str(ev.get("fx", ""))
		if (fx_kind == "lane") != lanes_only:
			continue
		match fx_kind:
			"debris":
				_debris(ev, projectile_blast)
			"shards":
				_shards(ev)
			"chunks":
				_chunks(ev)
			"items":
				_items(ev)
			"spill":
				_spill(ev)
			"sweep_props":
				_sweep_props(ev)
			"casings":
				_casings(ev)
			"blood":
				_blood(ev)
			"burn":
				_burn(ev)
			"flash":
				# Только вспышка, без щебня и звука (fix-7 #19: мина вспыхивает, как взрыв).
				var fcells: Array[Vector2i] = []
				for c: Vector2i in ev.get("cells", []):
					if not _space(c):
						fcells.append(c)
				if not fcells.is_empty():
					flashes.append({"cells": fcells, "t": 0.0})
			"laser":
				_laser(ev)
			"tracks":
				_tracks(ev)
			"tracer":
				_tracer(ev)
			"shot":
				_shot(ev)
			"lane":
				var rounds := 1
				for e: Dictionary in events:
					if e.get("fx") == "tracer" and e.get("from") == ev.get("from"):
						rounds = maxi(rounds, int(e.get("count", 1)))
				_lane(ev, rounds)

## Дорожка боя (issue 8): от стрелка к цели, в цвете стороны стрелка.
func _lane(ev: Dictionary, rounds := 1) -> void:
	var from_arr: Array = ev.get("from", [])
	var to_arr: Array = ev.get("to", [])
	if from_arr.size() < 2 or to_arr.size() < 2:
		return
	var kind := str(ev.get("kind", "shot"))
	var gun: String = WEAPON_SOUND.get(str(ev.get("weapon", "")), "rifle")
	var sound := {"shot": gun, "beam": "laser", "flame": "flame"}
	if sound.has(kind):
		var muzzle := Vector2i(int(from_arr[0]), int(from_arr[1]))
		_sound(sound[kind], muzzle, int(ev.get("owner", -1)))
		if kind == "shot" and rounds > 1 and not audio_suppressed:
			volley_requested.emit(gun, muzzle, int(ev.get("owner", -1)), rounds - 1)
	var entry := _lane_entry(ev)
	for lane: Dictionary in lanes:
		if lane.get("hold", false) and lane["from"] == entry["from"] and lane["to"] == entry["to"] \
				and lane["kind"] == entry["kind"] and lane["owner"] == entry["owner"]:
			lane.erase("hold")   # the previewed line: the shot starts it now
			lane["t"] = 0.0
			return
	lanes.append(entry)
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
func _debris(ev: Dictionary, projectile_blast := false) -> void:
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
		# Projectiles own their arrival bang. Their flash adds no second explosion.
		if not projectile_blast:
			if epicenter.x >= 0:
				_sound("explosion", epicenter)
			else:
				for c: Vector2i in ev.get("cells", []):
					_sound("explosion", c)
		_soot(ev)
		var cells: Array[Vector2i] = []
		for c: Vector2i in ev.get("cells", []):
			if not _space(c):   # в открытом космосе вспышке гореть нечему (fix-7)
				cells.append(c)
		if not cells.is_empty():
			flashes.append({"cells": cells, "t": 0.0})
			if flashes.size() > FLASH_CAP:
				flashes = flashes.slice(flashes.size() - FLASH_CAP)

## Копоть (0.12.1): на эпицентре — крупное пятно, вокруг — пятна поменьше примерно на
## каждой второй клетке. Вид, угол, размер и сдвиг у каждого свои; над космосом — ничего.
func _soot(ev: Dictionary) -> void:
	var epicenter: Vector2i = ev.get("at", Vector2i.ZERO)
	var i := 0
	for c: Vector2i in ev.get("cells", []):
		i += 1
		if _space(c):
			continue
		var rng := _rng_for("soot", c, i, _seq)
		var big := c == epicenter
		if not big and rng.randf() > 0.55:
			continue
		var jitter := 0.12 if big else 0.3
		_settle(props, {"kind": "soot:%d" % rng.randi_range(0, SOOT_VARIANTS - 1),
				"pos": Vector2(c) + Vector2(0.5, 0.5)
						+ Vector2(rng.randf_range(-jitter, jitter), rng.randf_range(-jitter, jitter)),
				"rot": rng.randf_range(0.0, TAU),
				"scale": rng.randf_range(1.5, 2.1) if big else rng.randf_range(0.6, 1.15),
				"origin": c})

## 21.2 — осколки стекла: 2..5 штук, летят ПРОТИВ направления удара, у каждого свои
## скорость и вращение.
func _shards(ev: Dictionary) -> void:
	_sound("glass", ev.get("at", Vector2i(-1, -1)))
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var away := _away(at, from)
	var count_rng := _rng_for("shards_n", at, 0, _seq)
	var count: int = count_rng.randi_range(SHARDS_MIN, SHARDS_MAX)
	for i in count:
		var rng := _rng_for("shard", at, i, _seq)
		_launch("shard", at, away, rng, SHARD_RANGE_MIN, SHARD_RANGE_MAX, SHARD_FLIGHT_SEC, 1.25)

## Обломки стены или ДОТа (0.12.1). Стена, снесённая взрывом, разлетается ПРОТИВ удара,
## как стекло; ДОТ, потерявший прочность (toward), откалывается со стороны выстрела —
## куски летят к стрелку. Удар из своей же клетки — во все стороны.
func _chunks(ev: Dictionary) -> void:
	# A wall pushed over by a hull crunches; one blown or burnt down crashes (2026-10-19).
	_sound("crunch" if bool(ev.get("crushed", false)) else "structure", ev.get("at", Vector2i(-1, -1)))
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var art := chunk_art(str(ev.get("fid", MCF.FEATURE_WALL)), int(ev.get("look", 0)), str(ev.get("env", "")))
	var dir := _away(at, from)
	if bool(ev.get("toward", false)):
		dir = -dir
	var fan := PI if from == at else 1.25
	var count: int = int(ev["count"]) if ev.has("count") \
			else _rng_for("chunks_n", at, 0, _seq).randi_range(CHUNKS_MIN, CHUNKS_MAX)
	for i in count:
		var rng := _rng_for("chunk", at, i, _seq)
		var shape := rng.randi_range(0, CHUNK_SHAPES.size() - 1)
		var size := rng.randf_range(CHUNK_SCALE_MIN, CHUNK_SCALE_MAX)
		_launch("chunk:%s#%d" % [art, shape], at, dir, rng, SHARD_RANGE_MIN, SHARD_RANGE_MAX,
				SHARD_FLIGHT_SEC, fan, Vector2.INF, INF, size)

## Мелкие предметы слетают (0.12.1): от взрыва — далеко, как осколки; со сдвинутой мебели —
## недалеко, как гильзы. Каждый летит со своего места и ложится на пол.
func _items(ev: Dictionary) -> void:
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var far := bool(ev.get("far", true))
	var k := 0
	for it: Array in ev.get("items", []):
		var rng := _rng_for("item", at, k, _seq)
		k += 1
		var dir := _away(at, from) if from != at else Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))
		_launch("item:" + str(it[0]), at, dir, rng, 0.5 if far else CASING_RANGE_MIN,
				SHARD_RANGE_MAX if far else CASING_RANGE_MAX * 1.2,
				SHARD_FLIGHT_SEC if far else CASING_FLIGHT_SEC * 1.3, 1.0 if far else 0.8,
				Vector2(float(it[1]), float(it[2])), float(it[3]), 1.0)

## Шкаф высыпает содержимое (0.12.1): несколько вещей его рода (SmallItems.SPILLS) из его
## клетки, прочь от толчка.
func _sweep_props(ev: Dictionary) -> void:
	var at: Vector2i = ev["at"]
	var from: Vector2i = ev["from"]
	# Most traversed cells have no loose props. Use the spatial index before
	# walking the full persistent list; retain its ordering when something moves.
	var loose := false
	for p: Dictionary in by_chunk.get(at / DECAL_CHUNK, []):
		var kind := str(p["kind"])
		if Vector2i(Vector2(p["pos"]).floor()) == at and (kind.begins_with("item:") or kind.begins_with("chunk:") or kind in ["shard", "casing", "shell_casing"]):
			loose = true
			break
	if not loose: return
	var moved: Array = []
	var kept: Array = []
	for p: Dictionary in props:
		var kind := str(p["kind"])
		var cell := Vector2i(Vector2(p["pos"]).floor())
		if cell == at and (kind.begins_with("item:") or kind.begins_with("chunk:") \
				or kind in ["shard", "casing", "shell_casing"]):
			moved.append(p)
		else:
			kept.append(p)
	if moved.is_empty():
		return
	props = kept
	# Only this cell's chunk lost pieces: a fresh bucket for it (consumers spot the
	# change by comparing buckets) instead of re-indexing the whole board.
	var cc := at / DECAL_CHUNK
	var bucket: Array = (by_chunk.get(cc, []) as Array).filter(func(q: Dictionary) -> bool:
		return not moved.has(q))
	if bucket.is_empty(): by_chunk.erase(cc)
	else: by_chunk[cc] = bucket
	decal_reset += 1
	for i in moved.size():
		var p: Dictionary = moved[i]
		_launch(str(p["kind"]), at, _away(at, from), _rng_for("sweep", at, i, _seq),
				0.6, 1.2, CASING_FLIGHT_SEC, 0.6, p["pos"], float(p["rot"]), float(p["scale"]))

func _spill(ev: Dictionary) -> void:
	if bool(ev.get("burst", false)):
		_sound("structure", ev.get("at", Vector2i(-1, -1)))
	var at: Vector2i = ev.get("at", Vector2i.ZERO)
	var from: Vector2i = ev.get("from", at)
	var kinds: Array = SmallItems.spill_contents(str(ev.get("fid", "")))
	if kinds.is_empty():
		return
	var burst := bool(ev.get("burst", false))
	var n_rng := _rng_for("spill_n", at, 0, _seq)
	var n := n_rng.randi_range(SmallItems.SPILL_MIN, SmallItems.SPILL_MAX)
	if burst:
		n += 2
	for i in n:
		var rng := _rng_for("spill", at, i, _seq)
		# Разбитый шкаф (item 3): каждая вещь — в свою сторону, веером на все 360°.
		var dir := Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU)) if burst or from == at \
				else _away(at, from)
		_launch("item:" + str(kinds[rng.randi_range(0, kinds.size() - 1)]), at, dir, rng,
				0.5 if burst else 0.35, 2.0 if burst else 1.3,
				CASING_FLIGHT_SEC * (1.8 if burst else 1.4), PI if burst else 1.2,
				Vector2.INF, INF, 1.0)

## Картинка стены, которой выглядят её обломки: материал стены (кирпич, штукатурка…), а
## без него — плитка объекта в окружении карты («wall» на станции — wall_station).
static func chunk_art(fid: String, look: int, env: String) -> String:
	var name := MCF.wall_look_tile(look) if fid == MCF.FEATURE_WALL else ""
	if name == "":
		name = "soil" if fid == MCF.FEATURE_DIRT_PILE else str(Sprites.ALIASES.get(fid, fid))
	return TerrainTiles.env_name(name, env)

## [размер в долях клетки, цвет] вида частицы — LOOK плюс обломки и копоть, у которых
## вид составной. Пусто — частица неизвестна.
static var _chunk_colors: Dictionary = {}
static func look_of(kind: String) -> Array:
	if kind in MapData.WINTER_DECORATIONS:
		return [1.0, Color.WHITE]
	if kind.begins_with("chunk:"):
		var art: String = chunk_parts(kind)[0]
		if not _chunk_colors.has(art):
			_chunk_colors[art] = _average_color(art)
		return [CHUNK_SIZE, _chunk_colors[art]]
	if kind.begins_with("soot:"):
		return [1.0, SOOT_COLOR]
	if kind.begins_with("item:"):
		var tex := SmallItems.texture_name(kind.substr(5))
		if not _chunk_colors.has(tex):
			_chunk_colors[tex] = _average_color(tex)
		return [SmallItems.DRAW_SCALE, _chunk_colors[tex]]
	return LOOK.get(kind, [])

## Имя картинки вида частицы (мелкий предмет — своя, «item_<вид>»).
static func texture_of_kind(kind: String) -> String:
	if kind.begins_with("item:"):
		return SmallItems.texture_name(kind.substr(5))
	return str(TEXTURE.get(kind, kind))

static func _average_color(art: String) -> Color:
	var tex := Sprites.texture_of(art)
	var img := tex.get_image() if tex != null else null
	if img == null or img.is_empty():
		return Color(0.45, 0.43, 0.4, 0.95)
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var c := img.get_pixel(0, 0)
	c.a = 0.95
	return c

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
	_sound("laser_hit", Vector2i(int(to_arr[0]), int(to_arr[1])))
	var a := Vector2(float(from_arr[0]) + 0.5, float(from_arr[1]) + 0.5)
	var b := Vector2(float(to_arr[0]) + 0.5, float(to_arr[1]) + 0.5)
	beams.append({"from": a, "to": b, "t": 0.0, "dur": 0.18})
	# Над космосом отметины нет: пола, на котором остаётся подпалина, там нет вовсе.
	# Луч при этом летит как раньше — делится только СЛЕД, по клеткам под ним.
	for run: Array in _ground_runs(a, b):
		laser_lines.append({"from": run[0], "to": run[1]})
	ground_version += 1

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
	ground_version += 1

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
	_sound("corpse", ev.get("at", Vector2i(-1, -1)))
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

## Fire no longer wipes the decals in its cells (owner, 2026-10-19): blood, casings,
## shards and chunks stay for the whole match, like the soot under them.
func _burn(ev: Dictionary) -> void:
	for c: Vector2i in ev.get("cells", []):
		_sound("flame", c)

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
## from_pos / rot / scale (0.12.1) — для мелкого предмета: летит со своего места, со своим
## углом и в своём размере (а не из середины клетки случайной крошкой).
func _launch(kind: String, at: Vector2i, dir: Vector2, rng: RandomNumberGenerator,
		r_min: float, r_max: float, flight: float, fan: float = 0.9,
		from_pos := Vector2.INF, rot := INF, scale := -1.0) -> void:
	var spread := rng.randf_range(-fan, fan)
	var d := dir.rotated(spread)
	var start := Vector2(at) + Vector2(0.5, 0.5) \
			+ Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12))
	if from_pos != Vector2.INF:
		start = from_pos
	var to: Vector2 = _clip_solid(start, start + d * rng.randf_range(r_min, r_max), at)
	var f := {
		"kind": kind, "from": start, "to": to, "origin": at,
		"rot0": rng.randf_range(0.0, TAU) if rot == INF else rot, "rot1": rng.randf_range(-TAU, TAU),
		"scale": rng.randf_range(0.6, 1.1) if scale < 0.0 else scale, "t": 0.0, "dur": flight,
	}
	# In vacuum there is no floor or friction to stop a flying object.
	if _space(at) or _space(Vector2i(to.floor())):
		f["drift"] = true
	# Отскок от края поля (batch 12 #6): частица долетает до стенки и отражается —
	# остаток пути идёт обратно внутрь. Точка удара и доля полёта до неё запоминаются,
	# чтобы траектория на экране действительно ломалась о край.
	var b := {} if f.get("drift", false) else _bounce(start, to)
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
	for i in range(beams.size() - 1, -1, -1):
		beams[i]["t"] = float(beams[i]["t"]) + delta
		if float(beams[i]["t"]) >= float(beams[i]["dur"]):
			beams.remove_at(i)
	# Дорожки «кто в кого» (issue 8): гаснут по времени, отработавшие убираем.
	var lanes_active := not lanes.is_empty()
	if lanes_active:
		for i in range(lanes.size() - 1, -1, -1):
			if lanes[i].get("hold", false):
				continue   # previewed during the dice: waits for its shot
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
	var shots_active := not shots.is_empty()
	if shots_active:
		for i in range(shots.size() - 1, -1, -1):
			shots[i]["t"] = float(shots[i]["t"]) + delta
			if float(shots[i]["t"]) >= float(shots[i]["dur"]):
				_sound("explosion", Vector2i(Vector2(shots[i]["to"]).floor()))
				shots.remove_at(i)
	var tracers_active := not tracers.is_empty() or shots_active
	if tracers_active:
		for i in range(tracers.size() - 1, -1, -1):
			tracers[i]["t"] = float(tracers[i]["t"]) + delta
			if float(tracers[i]["t"]) >= float(tracers[i]["dur"]):
				_sound("bullet_hit", Vector2i(Vector2(tracers[i]["to"]).floor()))
				tracers.remove_at(i)
	if flying.is_empty():
		return tracers_active or lanes_active or flashes_active
	var landed: Array = []
	for i in range(flying.size() - 1, -1, -1):
		var f: Dictionary = flying[i]
		var before := flight_pos(f)
		f["t"] = float(f["t"]) + delta
		if bool(f.get("drift", false)):
			var pos := flight_pos(f)
			var clipped := _clip_solid(before, pos, Vector2i(before.floor()))
			if clipped != pos:
				f["to"] = clipped
				landed.append(f)
				flying.remove_at(i)
				continue
			if _space(Vector2i(pos.floor())) or float(f["t"]) < float(f["dur"]):
				continue
			f["to"] = pos
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
	return true

## Где частица находится сейчас: линейно от from к to, с горкой по высоте, чтобы
## полёт читался как бросок, а не как скольжение.
static func flight_pos(f: Dictionary) -> Vector2:
	if bool(f.get("drift", false)):
		return Vector2(f["from"]) + (Vector2(f["to"]) - Vector2(f["from"])) \
				* float(f["t"]) / maxf(0.001, float(f["dur"]))
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
	if bool(f.get("drift", false)):
		k = float(f["t"]) / maxf(0.001, float(f["dur"]))
	return float(f["rot0"]) + float(f["rot1"]) * k

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
	var drifting: Array = []
	for p: Dictionary in props + gore:
		var pos: Vector2 = p["pos"]
		settled.append([str(p["kind"]), pos.x, pos.y, float(p["rot"]), float(p["scale"])])
	# Ещё летящие осколки и брызги — там, где они лягут (batch mp-perf): снимок уходит гостю
	# при пересинхронизации, и без них у него недоставало бы последнего выстрела.
	for f: Dictionary in flying:
		if bool(f.get("drift", false)):
			drifting.append([str(f["kind"]), f["from"].x, f["from"].y, f["to"].x, f["to"].y,
					float(f["rot0"]), float(f["rot1"]), float(f["scale"]), float(f["t"]), float(f["dur"])])
			continue
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
	var out := {"damage": damage, "props": settled, "lasers": lasers, "tracks": tracks}
	if not wall_blood.is_empty():
		var wb: Array = []
		for b: Dictionary in wall_blood:
			wb.append([b["cell"].x, b["cell"].y, b["face"].x, b["face"].y, float(b["rot"]), float(b["scale"])])
		out["wall_blood"] = wb
	if not drifting.is_empty():
		out["drifting"] = drifting
	return out

func from_dict(d: Dictionary) -> void:
	clear()
	for e: Array in d.get("drifting", []):
		if e.size() == 10:
			flying.append({"kind": str(e[0]), "from": Vector2(float(e[1]), float(e[2])),
					"to": Vector2(float(e[3]), float(e[4])), "rot0": float(e[5]), "rot1": float(e[6]),
					"scale": float(e[7]), "t": float(e[8]), "dur": maxf(0.001, float(e[9])), "drift": true,
					"origin": Vector2i(floori(float(e[1])), floori(float(e[2])))})
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
	_reindex()
	for e in d.get("lasers", []):
		if e is Array and (e as Array).size() >= 4:
			laser_lines.append({"from": Vector2(float(e[0]), float(e[1])),
					"to": Vector2(float(e[2]), float(e[3]))})
	for e in d.get("tracks", []):
		if e is Array and (e as Array).size() >= 4:
			track_marks.append({"from": Vector2(float(e[0]), float(e[1])),
					"to": Vector2(float(e[2]), float(e[3]))})
	for e in d.get("wall_blood", []):
		if e is Array and (e as Array).size() >= 6:
			wall_blood.append({"cell": Vector2i(int(e[0]), int(e[1])), "face": Vector2i(int(e[2]), int(e[3])),
					"rot": float(e[4]), "scale": float(e[5])})

## Local undo snapshots retain animation progress; settled particle records are immutable.
## This is separate from the portable save format, which intentionally settles flights.
func capture_state() -> Dictionary:
	return {"damage": floor_damage.duplicate(), "props": props.duplicate(),
		"gore": gore.duplicate(), "flying": flying.duplicate(true), "wall_blood": wall_blood.duplicate(),
		"lasers": laser_lines.duplicate(), "tracks": track_marks.duplicate(),
		"tracers": tracers.duplicate(true), "shots": shots.duplicate(true),
		"lanes": lanes.duplicate(true), "flashes": flashes.duplicate(true),
		"event_seq": _event_seq, "seq": _seq}

func restore_state(snap: Dictionary) -> void:
	beams.clear()
	sound_reset.emit()
	floor_damage = snap["damage"].duplicate()
	var fresh := {}
	_rebase(props, snap["props"], fresh)
	_rebase(gore, snap["gore"], fresh)
	for cc: Vector2i in fresh:
		if (by_chunk[cc] as Array).is_empty(): by_chunk.erase(cc)
	props = snap["props"].duplicate()
	gore = snap["gore"].duplicate()
	flying = snap["flying"].duplicate(true)
	wall_blood = snap.get("wall_blood", []).duplicate()
	laser_lines = snap["lasers"].duplicate()
	track_marks = snap["tracks"].duplicate()
	tracers = snap["tracers"].duplicate(true)
	shots = snap["shots"].duplicate(true)
	lanes = snap["lanes"].duplicate(true)
	flashes = snap["flashes"].duplicate(true)
	_event_seq = int(snap["event_seq"])
	_seq = int(snap["seq"])
	damage_version += 1
	ground_version += 1
	decal_reset += 1

## Bring the chunk index from `list` to `keep` (an undo snapshot), touching only chunks
## that differ: pieces matching in order stay put, the rest come out, and the snapshot's
## unmatched pieces go back in. Changed chunks get fresh buckets, so the tiles and the fog
## memories (which compare buckets) redo just those — re-indexing the whole board instead
## cost ~120 ms per undo on a busy map (issues-fix-6 #4).
func _rebase(list: Array, keep: Array, fresh: Dictionary) -> void:
	var j := keep.size()
	var back: Array = []
	if list.size() < j or list.slice(0, j) != keep:
		j = 0
		for p: Dictionary in keep:
			if j < list.size() and is_same(list[j], p): j += 1
			else: back.append(p)
	for i in range(list.size() - 1, j - 1, -1):
		var bucket := _fresh_bucket(list[i], fresh)
		var k := bucket.size() - 1
		while not is_same(bucket[k], list[i]):
			k -= 1
		bucket.remove_at(k)
	for p: Dictionary in back:
		_fresh_bucket(p, fresh).append(p)

func _fresh_bucket(p: Dictionary, fresh: Dictionary) -> Array:
	var pos: Vector2 = p["pos"]
	var cc := Vector2i(floori(pos.x) / DECAL_CHUNK, floori(pos.y) / DECAL_CHUNK)
	if not fresh.has(cc):
		fresh[cc] = true
		by_chunk[cc] = (by_chunk.get(cc, []) as Array).duplicate()
	return by_chunk[cc]
