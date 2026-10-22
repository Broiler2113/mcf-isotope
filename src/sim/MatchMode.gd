class_name MatchMode
extends RefCounted

## Режим партии (0.12, решения владельца):
##
##   Annihilation   — как было: побеждает последняя живая команда.
##   Capture & Hold — гонка очков. В конце каждого раунда зона принадлежит той команде,
##                    у которой в ней больше бойцов (ничья — никому), и каждая удержанная
##                    зона даёт 1 очко. Первая команда, набравшая цель (по умолчанию 12),
##                    побеждает; уничтожение противника по-прежнему побеждает сразу.
##   Holdout        — игроки (вместе) против волн: каждые два раунда с объявленного края
##                    приходит волна, каждая больше прежней. 5 / 10 / 15 волн или
##                    бесконечно (тогда счёт — сколько волн пережили и сколько убили).
##
## Состояние режима живёт на резолвере рядом со случайными событиями и едет тем же
## путём: снимок в сохранение, гостю по сети, в откат хода и в повтор (StateCodec.
## encode_rules). Всё — числа и строки: снимок уходит через JSON.

enum Kind {ANNIHILATION, CAPTURE, HOLDOUT}
const NAMES := ["Annihilation", "Capture & Hold", "Holdout"]
const BLURBS := [
	"The last team with soldiers standing wins.",
	"Hold the zones. At the end of every round each zone scores 1 point for the team with more soldiers in it. First to the target wins; wiping out the enemy still wins outright.",
	"All players defend together against waves, each bigger than the last. A wave lands every few rounds (set below) — or right after the previous one is wiped out. Survive them all, or as long as you can.",
]

const ZONE_COUNTS := [1, 3, 5]
const DEFAULT_ZONES := 3
const DEFAULT_TARGET := 12
const TARGET_MIN := 3
const TARGET_MAX := 99
## Число волн Holdout вводится числом (fix-7 #1); 0 — бесконечно.
const WAVES_MAX := 999
const DEFAULT_WAVES := 10
## Раундов между волнами: волна объявляется в начале раунда и приходит в его конце.
## Выбитая волна зовёт следующую сразу (GameActionResolver._maybe_wave_cleared).
const WAVE_EVERY := 2
## Rounds between waves, typed in the lobby (owner, 2026-10-20; was a 1-5 list);
## WAVE_EVERY is the default.
const WAVE_EVERY_MAX := 50
## Wave k uses all surviving defending soldiers at announcement: 0.7 initially,
## then +0.1 per wave. Legacy point budgets remain only for older replay playback.
const WAVE_BASE := 0.7
const WAVE_GROWTH := 0.1
const WAVE_START_MIN := 0.1
const WAVE_START_MAX := 5.0
## Подписи зон на карте.
const ZONE_LETTERS := "ABCDE"

var kind: int = Kind.ANNIHILATION

# --- Capture & Hold ---
var zone_count: int = DEFAULT_ZONES
var target: int = DEFAULT_TARGET
## Зоны: [[x, y, w, h], ...] — ставятся в начале партии (из карты или автоматически).
var zones: Array = []
## Очки: ключ команды (team_key) -> очки.
var scores: Dictionary = {}
## Кто держал зону на последней границе раунда (ключ команды или ""). Это и рисуется на
## карте: живое положение под туманом выдавало бы невидимых.
var holders: Array = []
## Награда за голову (событие Bounty, только в Capture & Hold): id бойца или −1.
var bounty_unit: int = -1
## Чей это боец (тело может уйти из списка юнитов) и последний раунд метки.
var bounty_side: int = -1
var bounty_until: int = 0
const BOUNTY_POINTS := 2

# --- Holdout ---
var waves_total: int = DEFAULT_WAVES
var wave_every: int = WAVE_EVERY
## First-wave multiplier of the defending team’s current surviving soldiers.
var wave_start: float = WAVE_BASE
## Сколько волн уже пришло.
var wave: int = 0
## Слот ростера, который ведёт волны (Roster.Slot.role == ROLE_WAVES).
var wave_side: int = -1
## Раунд, в начале которого объявится следующая волна.
var next_wave_round: int = 1
## Объявленная волна: параметры высадки (как у независимой армии) или пусто.
var pending_wave: Dictionary = {}
## Сколько бойцов волн пришло всего — для счёта убитых в бесконечном режиме.
var wave_spawned: int = 0
var excluded_units: Array[String] = []
## Counts include removed corpses, so the initiative breakdown survives cleanup.
var wave_sizes: Dictionary = {}
## Средняя армия игрока-защитника в начале партии (очки закупки) — мерило волн.
var defender_value: int = 0 # Legacy replay point budget only.
var live_wave_counts := true
var wave_details: Dictionary = {}

func is_capture() -> bool:
	return kind == Kind.CAPTURE

func is_holdout() -> bool:
	return kind == Kind.HOLDOUT

func endless() -> bool:
	return waves_total <= 0

static func name_of(k: int) -> String:
	return NAMES[k] if k >= 0 and k < NAMES.size() else NAMES[0]

static func from_config() -> MatchMode:
	var m := MatchMode.new()
	m.kind = clampi(GameConfig.game_mode, 0, NAMES.size() - 1)
	m.zone_count = GameConfig.capture_zones if ZONE_COUNTS.has(GameConfig.capture_zones) else DEFAULT_ZONES
	m.target = clampi(GameConfig.capture_target, TARGET_MIN, TARGET_MAX)
	m.waves_total = clampi(GameConfig.holdout_waves, 0, WAVES_MAX)
	m.wave_every = clampi(GameConfig.holdout_wave_every, 1, WAVE_EVERY_MAX)
	m.wave_start = clampf(GameConfig.holdout_wave_start, WAVE_START_MIN, WAVE_START_MAX)
	m.excluded_units = GameConfig.holdout_excluded_units.duplicate()
	return m

## Ключ команды: настоящая команда — "t<номер>", сторона вне команд — "s<номер>". Тот же
## смысл, что у Main._winning_team (−100 − сторона), только годный для JSON.
static func team_key(roster: Roster, side: int) -> String:
	var t := roster.team_of(side) if roster != null else -1
	return "t%d" % t if t >= 0 else "s%d" % side

func snapshot() -> Dictionary:
	return {
		"kind": kind, "zone_count": zone_count, "target": target,
		"zones": zones.duplicate(true), "scores": scores.duplicate(), "holders": holders.duplicate(),
		"bounty": bounty_unit, "bounty_side": bounty_side, "bounty_until": bounty_until,
		"waves_total": waves_total, "wave_every": wave_every, "wave_start": wave_start, "wave": wave, "wave_side": wave_side,
		"next_wave_round": next_wave_round, "pending_wave": pending_wave.duplicate(true),
		"wave_spawned": wave_spawned, "defender_value": defender_value,
		"live_wave_counts": live_wave_counts, "wave_details": wave_details.duplicate(true),
		"excluded_units": excluded_units.duplicate(), "wave_sizes": wave_sizes.duplicate(),
	}

func restore(d: Dictionary) -> void:
	kind = clampi(int(d.get("kind", 0)), 0, NAMES.size() - 1)
	zone_count = int(d.get("zone_count", DEFAULT_ZONES))
	target = int(d.get("target", DEFAULT_TARGET))
	zones = []
	for z in d.get("zones", []):
		if z is Array and (z as Array).size() == 4:
			zones.append([int(z[0]), int(z[1]), int(z[2]), int(z[3])])
	scores = {}
	var sc: Variant = d.get("scores", {})
	if sc is Dictionary:
		for k in sc:
			scores[str(k)] = int(sc[k])
	holders = []
	for h in d.get("holders", []):
		holders.append(str(h))
	bounty_unit = int(d.get("bounty", -1))
	bounty_side = int(d.get("bounty_side", -1))
	bounty_until = int(d.get("bounty_until", 0))
	waves_total = int(d.get("waves_total", DEFAULT_WAVES))
	wave_every = clampi(int(d.get("wave_every", WAVE_EVERY)), 1, WAVE_EVERY_MAX)
	wave_start = clampf(float(d.get("wave_start", WAVE_BASE)), WAVE_START_MIN, WAVE_START_MAX)
	wave = int(d.get("wave", 0))
	wave_side = int(d.get("wave_side", -1))
	next_wave_round = int(d.get("next_wave_round", 1))
	var pw: Variant = d.get("pending_wave", {})
	pending_wave = (pw as Dictionary).duplicate(true) if pw is Dictionary else {}
	wave_spawned = int(d.get("wave_spawned", 0))
	excluded_units.assign(d.get("excluded_units", []))
	wave_sizes = {}
	for k in d.get("wave_sizes", {}):
		wave_sizes[str(k)] = int(d["wave_sizes"][k])
	defender_value = int(d.get("defender_value", 0))
	live_wave_counts = bool(d.get("live_wave_counts", true))
	wave_details = (d.get("wave_details", {}) as Dictionary).duplicate(true)

## Нарисованные хостом зоны (GameConfig.capture_drawn), обрезанные по доске w×h; пусто —
## «Auto». Не больше, чем есть букв для подписей.
static func drawn_zones(w: int, h: int) -> Array:
	return clean_drawn(GameConfig.capture_drawn, w, h)

static func clean_drawn(list: Variant, w: int, h: int) -> Array:
	var out: Array = []
	if not (list is Array):
		return out
	var board := Rect2i(0, 0, w, h)
	for z in list:
		if not (z is Array) or (z as Array).size() != 4 or out.size() >= ZONE_LETTERS.length():
			continue
		var r := Rect2i(int(z[0]), int(z[1]), int(z[2]), int(z[3])).intersection(board)
		if r.size.x > 0 and r.size.y > 0:
			out.append([r.position.x, r.position.y, r.size.x, r.size.y])
	return out

func zone_rect(i: int) -> Rect2i:
	var z: Array = zones[i]
	return Rect2i(int(z[0]), int(z[1]), int(z[2]), int(z[3]))

func zone_name(i: int) -> String:
	return "Zone " + ZONE_LETTERS[i] if i < ZONE_LETTERS.length() else "Zone %d" % (i + 1)

## Индекс зоны, в которой лежит клетка, или −1.
func zone_at(c: Vector2i) -> int:
	for i in zones.size():
		if zone_rect(i).has_point(c):
			return i
	return -1

## Сила волны k (с единицы) в очках закупки.
func wave_budget(k: int) -> int:
	return maxi(1, roundi(float(defender_value) * (wave_start + WAVE_GROWTH * float(k - 1))))

## Зоны Capture & Hold для карты: count штук, честно между зонами развёртывания sides.
## grid — доска, собранная из этой же карты (проходимость клеток берётся у неё: грунт
## бункера, мебель, шлюзы считаются ровно так, как ходят бойцы). Расстановка — чистая
## функция карты, поэтому у хоста и гостя она одна и та же.
##
## Зона должна быть ЧЕСТНОЙ: от зон развёртывания
## всех сторон до неё примерно одинаково идти (по проходимым клеткам, в обход стен), — и
## зоны не должны жаться друг к другу. Первая — посередине пути между сторонами, каждая
## следующая — как можно дальше от уже стоящих, но в пределах той же честности.
static func zones_for(map: MapData, count: int, sides: Array, grid: Grid) -> Array:
	var w := map.width
	var h := map.height
	var n := w * h
	# walk — где бойцы ходят (по ней меряется путь), open — где может лежать зона: не в
	# вакууме. Мебель зоной не считается: на столе не постоишь.
	var walk := PackedByteArray()
	walk.resize(n)
	var open_cell := PackedByteArray()
	open_cell.resize(n)
	for y in h:
		for x in w:
			var c := grid.cell_fast(x, y)
			if c.walkable_terrain() and not Furniture.is_furniture(c.feature_id):
				walk[y * w + x] = 1
				open_cell[y * w + x] = 0 if c.is_space else 1
	# Расстояние от зон развёртывания каждой стороны (8 соседей, шаг — 1, как ходят бойцы).
	var dists: Array = []
	for side: int in sides:
		var seeds: Array[int] = []
		for c: Vector2i in map.zone_cells(side):
			var i := c.y * w + c.x
			if walk[i] == 1:
				seeds.append(i)
		if seeds.is_empty():
			continue
		dists.append(_bfs(walk, w, h, seeds))
	if dists.size() < 2:
		return _fallback_zones(map, count)
	# Размер зоны — по тому, сколько на карте места, а не по её рамке: бункер 62×52 — это
	# пара сотен клеток коридоров, и зона 5×5 закрыла бы его половину.
	var open_total := 0
	for i in n:
		open_total += open_cell[i]
	var size := 5 if open_total >= 2000 else 3
	var half := size / 2
	# Доля проходимых клеток в квадрате зоны — по таблице сумм, за O(1) на кандидата.
	var sat := PackedInt32Array()
	sat.resize((w + 1) * (h + 1))
	for y in h:
		var row := 0
		for x in w:
			row += open_cell[y * w + x]
			sat[(y + 1) * (w + 1) + x + 1] = sat[y * (w + 1) + x + 1] + row
	var cands: Array = []   # [x, y, разброс, средний путь, путь от ближайшей стороны]
	for y in range(half, h - half):
		for x in range(half, w - half):
			var i := y * w + x
			if open_cell[i] == 0:
				continue
			var x0 := x - half
			var y0 := y - half
			var open := sat[(y0 + size) * (w + 1) + x0 + size] - sat[y0 * (w + 1) + x0 + size] \
					- sat[(y0 + size) * (w + 1) + x0] + sat[y0 * (w + 1) + x0]
			if open * 10 < size * size * 6:
				continue
			var lo := 1 << 30
			var hi := -1
			var sum := 0
			var ok := true
			for d: PackedInt32Array in dists:
				var v := d[i]
				if v < 0:
					ok = false
					break
				lo = mini(lo, v)
				hi = maxi(hi, v)
				sum += v
			if not ok:
				continue
			cands.append([x, y, hi - lo, float(sum) / float(dists.size()), lo])
	if cands.is_empty():
		return _fallback_zones(map, count)
	var chosen: Array = []   # центры [x, y]
	var out: Array = []
	var first_mean := -1.0
	for _k in count:
		# Правила смягчаются по ступеням (relax), пока место не найдётся: сперва простор между
		# зонами и отступ от зон развёртывания, и только потом — честность. На тесной карте
		# (бункер) пусть зоны стоят плотнее, но до них одинаково идти обеим сторонам.
		# Честность не отдаётся никогда, кроме первой зоны (без неё режима нет): не нашлось
		# честного места — на тесной карте зон будет меньше, чем просили.
		var best: Array = []
		for relax in (6 if chosen.is_empty() else 5):
			var best_s := -INF
			var gap := maxi(0, 2 - relax)        # клеток между зоной и зоной развёртывания
			var spacing := maxi(size, size + 2 - relax)
			var slack := 2 if relax >= 3 else 0  # и тогда — не больше чем на пару шагов
			for c: Array in cands:
				var spread: int = c[2]
				var mean: float = c[3]
				if int(c[4]) < half + 1 + gap:
					continue
				# Честность почти точная (на дальних зонах — шаг-другой форы).
				if relax < 5 and spread > 1 + int(mean * 0.06) + slack:
					continue
				var s: float
				if chosen.is_empty():
					# Первая зона: самая честная, а среди равных — ближе к середине пути.
					s = -float(spread) * 4.0 - mean * 0.25
				else:
					# Остальные: не дальше от сторон, чем первая, заметно, и как можно
					# дальше от прочих.
					var md := 1 << 30
					for p: Array in chosen:
						md = mini(md, maxi(absi(int(c[0]) - int(p[0])), absi(int(c[1]) - int(p[1]))))
					if md < spacing:
						continue
					var far := maxf(0.0, mean - first_mean * 1.4) if first_mean >= 0.0 else 0.0
					s = float(md) - float(spread) * 2.0 - far * 1.5
				if s > best_s:
					best_s = s
					best = c
			if not best.is_empty():
				break
		if best.is_empty():
			break
		if first_mean < 0.0:
			first_mean = float(best[3])
		chosen.append([best[0], best[1]])
		out.append([int(best[0]) - half, int(best[1]) - half, size, size])
	return out

## Мультиисточниковая волна: шаги до ближайшего источника, −1 — не дойти.
static func _bfs(walk: PackedByteArray, w: int, h: int, seeds: Array[int]) -> PackedInt32Array:
	var d := PackedInt32Array()
	d.resize(w * h)
	d.fill(-1)
	var q := PackedInt32Array()
	for s in seeds:
		if d[s] == -1:
			d[s] = 0
			q.append(s)
	var head := 0
	while head < q.size():
		var i := q[head]
		head += 1
		var x := i % w
		var y := i / w
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx := x + dx
				var ny := y + dy
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var j := ny * w + nx
				if walk[j] == 0 or d[j] != -1:
					continue
				d[j] = d[i] + 1
				q.append(j)
	return d

## Зон развёртывания нет (старая карта, демо) — зоны по центру и по диагонали.
static func _fallback_zones(map: MapData, count: int) -> Array:
	var out: Array = []
	var size := 3
	var spots := [Vector2i(map.width / 2, map.height / 2),
			Vector2i(map.width / 4, map.height / 4), Vector2i(map.width * 3 / 4, map.height * 3 / 4),
			Vector2i(map.width * 3 / 4, map.height / 4), Vector2i(map.width / 4, map.height * 3 / 4)]
	for i in mini(count, spots.size()):
		var c: Vector2i = spots[i]
		out.append([c.x - 1, c.y - 1, size, size])
	return out
