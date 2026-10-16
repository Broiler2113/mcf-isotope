class_name RandomEvents
extends RefCounted

## Случайные события (§1.5 лобби, item 61; спека «Random Event System», 0.9.4). Хост в
## лобби включает события, задаёт «обязательное событие каждый ход» / «сколько ходов между
## событиями» и пул равновероятных событий.
##
## Event intervals count rounds, with announcements at round opening.
## Each event announces its zone at a round's opening and resolves when that round
## ends, so every player gets one turn to react (0.11). Gas lifetime and repeated exposure still advance once per round.
##
##   • «Artillery Barrage» (id на диске остался mortar) — прямоугольную зону накрывает
##     обстрел: каждая клетка с вероятностью 1/2 разрушена;
##   • «Gas Cloud» — зона стоит несколько раундов, травит всех внутри и держит взгляд;
##   • «Independent Army» — у края карты появляется ничья армия, враждебная всем.
##
## Главный инвариант — лок-степ (§2.3): и «случится ли событие», и «какое именно», и куда
## оно бьёт, берётся ТОЛЬКО из DiceService. Хост и клиент прокатывают один и тот же поток
## d6, значит выберут одно и то же событие в одном и том же месте. Ни одного постороннего
## RNG здесь быть не должно.
##
## ПАРАМЕТРЫ катаются при ОБЪЯВЛЕНИИ, исход по клеткам (куда попал снаряд, кто задохнулся) —
## при ПАДЕНИИ. Оба порядка зафиксированы, поэтому хост и клиент сходятся и на том, и на
## другом. Само содержимое очереди и облаков входит в снимок состояния (snapshot), так что
## откат хода и загрузка сохранения возвращают и предупреждения, и стоящий газ.

static func available_for_map(id: String, env: String, game_mode: int) -> bool:
	match id:
		DUST: return env in ["town", "field"]
		BOUNTY: return game_mode == MatchMode.Kind.CAPTURE
	return true

const MORTAR := "mortar"
const GAS := "gas"
const ARMY := "army"
## 0.12 (решения владельца). FIRE, EMP, COLLAPSE, REINFORCE и DUST объявляются в начале
## раунда и падают в его конце, как прежние. MINEFIELD и BOUNTY случаются СРАЗУ: о минах
## говорят, что они есть, но не где; метка на бойца просто ставится.
const FIRE := "fire"
const EMP := "emp"
const DUST := "dust"
const COLLAPSE := "collapse"
const REINFORCE := "reinforce"
const BOUNTY := "bounty"
const MINEFIELD := "minefield"

## Реестр известных событий: id -> человекочитаемое имя. Порядок фиксирован — по нему
## равномерный выбор обходит события, поэтому у хоста и клиента он совпадает.
##
## Прежний «Tremor» убран (своего эффекта у него так и не появилось). Старые сохранённые
## веса с ключом "tremor" читаются как раньше: _pick обходит ТОЛЬКО реестр, и незнакомый
## ключ просто не участвует.
const REGISTRY := [
	[MORTAR, "Artillery Barrage"],
	[GAS, "Gas Cloud"],
	[ARMY, "Independent Army"],
	[FIRE, "Fire Outbreak"],
	[EMP, "EMP Burst"],
	[DUST, "Dust Storm"],
	[COLLAPSE, "Structural Collapse"],
	[REINFORCE, "Reinforcements"],
	[BOUNTY, "Bounty"],
	[MINEFIELD, "Old Minefield"],
]

## Что делает событие и где оно бывает — для окна выбора событий в лобби.
const NOTES := {
	MORTAR: "A zone is shelled at the end of the round: every cell has an even chance to be destroyed.",
	GAS: "A gas cloud settles over a zone for a few rounds and chokes anyone inside.",
	ARMY: "Hostile raiders land at a map edge and fight everyone.",
	FIRE: "A fire breaks out in a zone at the end of the round and keeps spreading every round.",
	EMP: "Strikes a vehicle (crewed ones first): its gun takes damage, drones in the zone drop, drone stations and LDF walls burn out. With no vehicles on the field it hits drones instead.",
	DUST: "Town and field maps only. For two rounds every shot beyond 3 cells needs one more.",
	COLLAPSE: "Walls in a zone come down at the end of the round; anyone inside may be crushed.",
	REINFORCE: "The weakest side gets fresh troops at its nearest map edge.",
	BOUNTY: "Capture & Hold only. The leader's most valuable soldier is marked: kill it within 3 rounds for 2 points.",
	MINEFIELD: "All maps. Hidden personnel and anti-vehicle mines appear on unoccupied ground; old mines can fail to detonate.",
}

static func event_name(id: String) -> String:
	for pair in REGISTRY:
		if pair[0] == id:
			return pair[1]
	return id

## Default pool: every known event enabled with equal probability.
static func default_weights() -> Dictionary:
	var w := {}
	for pair in REGISTRY:
		w[pair[0]] = 1
	return w


## Состояние розыгрыша событий на весь матч. Живёт на резолвере и входит в снимок
## состояния, чтобы откат хода не «потерял» ни отсчёт ходов до следующего события, ни
## объявленное, но ещё не упавшее.
## Playback compatibility only; new matches and loaded saves use uniform selection.
var legacy_selection := false
var enabled: bool = false
var mandatory: bool = false        # guarantee an event on each due round
var interval: int = 3              # rounds between event checks
var weights: Dictionary = {}       # saved legacy field: positive = selected
var last_checked_round: int = 0    # prevents another roll when reopening a saved round
var turns_since: int = 0           # rounds since last event check; saved key kept for compatibility
## Объявленные события в очереди: [{"id", "params", "announced": раунд, "land": раунд}].
## Их может быть несколько сразу (обязательный режим с коротким интервалом).
var pending: Array = []
## Стоящие газовые облака: [{"x", "y", "w", "h", "left": раундов осталось}].
var clouds: Array = []
## Сколько независимых армий уже пришло — по этому числу новая получает свой слот.
var armies: int = 0
var army_difficulty: int = 1
const ARMY_DIFFICULTIES := ["Easy", "Normal", "Hard"]
## Пыльная буря (0.12): сколько раундов ещё держится; 0 — ясно.
var dust_left: int = 0

func _init(cfg_enabled := false, cfg_mandatory := false, cfg_interval := 3,
		cfg_weights: Dictionary = {}) -> void:
	enabled = cfg_enabled
	mandatory = cfg_mandatory
	interval = maxi(1, cfg_interval)
	weights = cfg_weights.duplicate() if not cfg_weights.is_empty() else default_weights()

## Бросок «а случится ли вообще» в необязательном режиме: событие проходит на 3+.
const NOTHING_ON := 2

## Пора ли разыгрывать событие на очередном ходу. Частоту задаёт ТОЛЬКО интервал —
## «обязательность» больше не значит «каждый ход» (item 11). Продвигает счётчик и,
## дозрев, сбрасывает его и отвечает true.
func _due() -> bool:
	if not enabled or _total_weight() <= 0:
		return false
	turns_since += 1
	if turns_since >= interval:
		turns_since = 0
		return true
	return false

## Итог хода по событиям (item 11): "" — ничего, иначе id случившегося события.
## На «созревший» ход: если режим обязательный — одно из выбранных событий гарантированно;
## иначе сперва бросок «а случится ли вообще», и есть шанс, что не случится ничего.
## Все броски — через DiceService: и хост, и клиент прокатывают один поток (лок-степ).
func roll_event(dice: DiceService, allowed: Callable = Callable()) -> String:
	if not _due():
		return ""
	if not mandatory:
		if dice.roll_d6() <= NOTHING_ON:
			return ""
	# Какие события вообще возможны здесь и сейчас (карта, режим) — спрашиваем, только
	# когда событие созрело: проверки ходят по всей доске.
	return _pick(dice, allowed.call() if allowed.is_valid() else {})

## The saved weights field remains compatible with old settings: positive means enabled.
## Magnitudes never bias the chosen pool.
func _total_weight() -> int:
	var count := 0
	for pair in REGISTRY:
		if float(weights.get(pair[0], 0)) > 0.0:
			count += maxi(0, int(weights[pair[0]])) if legacy_selection else 1
	return count

## Uniform selection from the stable registry, using only the shared dice stream.
## Reject the incomplete tail of 216 outcomes; modulo alone favors some events.
func _pick(dice: DiceService, allowed: Dictionary = {}) -> String:
	if legacy_selection: return _pick_legacy(dice, allowed)
	var pool: Array[String] = []
	for pair in REGISTRY:
		if float(weights.get(pair[0], 0)) > 0.0 and (allowed.is_empty() or allowed.has(pair[0])):
			pool.append(pair[0])
	while true:
		var v := 0
		for _i in 3:
			v = v * 6 + (dice.roll_d6() - 1)
		if pool.is_empty():
			return ""
		if v < 216 - (216 % pool.size()):
			return pool[v % pool.size()]
	return ""

## Existing replay dice tapes used weighted modulo selection without rejection.
func _pick_legacy(dice: DiceService, allowed: Dictionary = {}) -> String:
	var total := 0
	for pair in REGISTRY:
		if allowed.is_empty() or allowed.has(pair[0]):
			total += maxi(0, int(weights.get(pair[0], 0)))
	# Ролл 1..total из общего потока: три d6 дают 216 значений, берём остаток — тем же
	# приёмом, что и разлёт тел в резолвере, чтобы не заводить второй RNG.
	var v := 0
	for _i in 3:
		v = v * 6 + (dice.roll_d6() - 1)
	if total <= 0:
		return ""
	var pick := v % total
	# Обходим реестр в ФИКСИРОВАННОМ порядке — одинаково у хоста и клиента.
	for pair in REGISTRY:
		var id: String = pair[0]
		var w := int(weights.get(id, 0))
		if w <= 0 or not (allowed.is_empty() or allowed.has(id)):
			continue
		if pick < w:
			return id
		pick -= w
	return ""

# --- Очередь объявленных событий -------------------------------------------------------

## A warning lands when its round closes. Round metadata stays in snapshots for
## compatibility; pending warnings from older saves land at the next round end.
func announce(id: String, params: Dictionary, round_number: int) -> Dictionary:
	var entry := {"id": id, "params": params, "announced": round_number, "land": round_number}
	pending.append(entry)
	return entry

func take_landing(_round_number: int) -> Array:
	var out := pending
	pending = []
	return out

## Поставить газовое облако (при падении события).
func add_cloud(x: int, y: int, w: int, h: int, rounds: int) -> Dictionary:
	var cloud := {"x": x, "y": y, "w": w, "h": h, "left": rounds}
	clouds.append(cloud)
	return cloud

## Дым дымовых гранат (0.12): [{"x", "y", "w", "h", "left"}] — те же облака, что у газа,
## только безвредные. Живут здесь, потому что здесь и газ: снимок, загрузка, сеть и откат
## хода уже умеют это хранить.
var smoke: Array = []

func add_smoke(x: int, y: int, w: int, h: int, rounds: int) -> Dictionary:
	var cloud := {"x": x, "y": y, "w": w, "h": h, "left": rounds}
	smoke.append(cloud)
	return cloud

## Дыму — раунд меньше; рассеявшиеся убрать.
func age_smoke() -> void:
	var left: Array = []
	for c: Dictionary in smoke:
		c["left"] = int(c["left"]) - 1
		if int(c["left"]) > 0:
			left.append(c)
	smoke = left

func smoke_at(c: Vector2i) -> bool:
	for cl: Dictionary in smoke:
		if c.x >= int(cl["x"]) and c.y >= int(cl["y"]) \
				and c.x < int(cl["x"]) + int(cl["w"]) and c.y < int(cl["y"]) + int(cl["h"]):
			return true
	return false

## Отсчитать газу раунд: у всех облаков минус один, выдохшиеся убрать.
func age_clouds() -> void:
	var left: Array = []
	for c: Dictionary in clouds:
		c["left"] = int(c["left"]) - 1
		if int(c["left"]) > 0:
			left.append(c)
	clouds = left

## Лежит ли клетка в каком-нибудь облаке. Поклеточную проверку в бою делает НЕ это (там
## маска, см. GameActionResolver._gas_mask): здесь — для журнала, тестов и подсказок.
func cloud_at(c: Vector2i) -> bool:
	for cl: Dictionary in clouds:
		if c.x >= int(cl["x"]) and c.y >= int(cl["y"]) \
				and c.x < int(cl["x"]) + int(cl["w"]) and c.y < int(cl["y"]) + int(cl["h"]):
			return true
	return false

## Снимок/восстановление для отката хода (счётчик ходов, очередь объявленного и стоящий
## газ обязаны переживать undo и загрузку). Всё — числа и строки: снимок уезжает через
## JSON в файл сохранения и гостю по сети, поэтому ни Vector2i, ни Rect2i тут нет.
func snapshot() -> Dictionary:
	var pend: Array = []
	for e: Dictionary in pending:
		pend.append({"id": e["id"], "params": (e["params"] as Dictionary).duplicate(),
				"announced": e["announced"], "land": e["land"]})
	var cl: Array = []
	for c: Dictionary in clouds:
		cl.append(c.duplicate())
	var sm: Array = []
	for c: Dictionary in smoke:
		sm.append(c.duplicate())
	return {"enabled": enabled, "mandatory": mandatory, "interval": interval,
			"weights": weights.duplicate(), "turns_since": turns_since,
			"army_difficulty": army_difficulty,
			"last_checked_round": last_checked_round,
			"pending": pend, "clouds": cl, "smoke": sm, "armies": armies, "dust": dust_left}

func restore(d: Dictionary) -> void:
	enabled = d.get("enabled", false)
	mandatory = d.get("mandatory", false)
	interval = d.get("interval", 3)
	weights = (d.get("weights", {}) as Dictionary).duplicate()
	turns_since = d.get("turns_since", 0)
	last_checked_round = int(d.get("last_checked_round", 0))
	pending = []
	for e: Dictionary in d.get("pending", []):
		pending.append({"id": str(e.get("id", "")),
				"params": (e.get("params", {}) as Dictionary).duplicate(),
				"announced": int(e.get("announced", 0)), "land": int(e.get("land", 0))})
	clouds = []
	for c: Dictionary in d.get("clouds", []):
		clouds.append((c as Dictionary).duplicate())
	smoke = []
	for c: Dictionary in d.get("smoke", []):
		smoke.append((c as Dictionary).duplicate())
	armies = int(d.get("armies", 0))
	army_difficulty = clampi(int(d.get("army_difficulty", 1)), 0, 2)
	dust_left = int(d.get("dust", 0))

static func from_config() -> RandomEvents:
	var w: Dictionary = GameConfig.random_events_weights
	var events := RandomEvents.new(GameConfig.random_events_enabled,
			GameConfig.random_events_mandatory, GameConfig.random_events_interval,
			w if not w.is_empty() else default_weights())
	events.army_difficulty = clampi(GameConfig.independent_army_difficulty, 0, 2)
	return events
