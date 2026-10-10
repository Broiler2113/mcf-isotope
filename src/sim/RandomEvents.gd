class_name RandomEvents
extends RefCounted

## Случайные события (§1.5 лобби, item 61; спека «Random Event System», 0.9.4). Хост в
## лобби включает события, задаёт «обязательное событие каждый ход» / «сколько ходов между
## событиями» и веса-доли по каждому событию.
##
## Each event announces its zone first and resolves when the next player ends
## their turn. Gas lifetime and repeated exposure still advance once per round.
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

const MORTAR := "mortar"
const GAS := "gas"
const ARMY := "army"

## Реестр известных событий: id -> человекочитаемое имя. Порядок фиксирован — по нему
## взвешенный выбор обходит события, поэтому у хоста и клиента он совпадает.
##
## Прежний «Tremor» убран (своего эффекта у него так и не появилось). Старые сохранённые
## веса с ключом "tremor" читаются как раньше: _pick обходит ТОЛЬКО реестр, и незнакомый
## ключ просто не участвует.
const REGISTRY := [
	[MORTAR, "Artillery Barrage"],
	[GAS, "Gas Cloud"],
	[ARMY, "Independent Army"],
]

static func event_name(id: String) -> String:
	for pair in REGISTRY:
		if pair[0] == id:
			return pair[1]
	return id

## Веса по умолчанию, если хост включил события, но не тронул доли: все три поровну.
static func default_weights() -> Dictionary:
	return {MORTAR: 1, GAS: 1, ARMY: 1}


## Состояние розыгрыша событий на весь матч. Живёт на резолвере и входит в снимок
## состояния, чтобы откат хода не «потерял» ни отсчёт ходов до следующего события, ни
## объявленное, но ещё не упавшее.
var enabled: bool = false
var mandatory: bool = false        # событие ОБЯЗАТЕЛЬНО каждый ход
var interval: int = 3              # иначе — раз в столько ходов
var weights: Dictionary = {}       # id -> вес-доля (item 1.5)
var turns_since: int = 0           # ходов прошло с прошлого события
## Объявленные события в очереди: [{"id", "params", "announced": раунд, "land": раунд}].
## Их может быть несколько сразу (обязательный режим с коротким интервалом).
var pending: Array = []
## Стоящие газовые облака: [{"x", "y", "w", "h", "left": раундов осталось}].
var clouds: Array = []
## Сколько независимых армий уже пришло — по этому числу новая получает свой слот.
var armies: int = 0

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
func roll_event(dice: DiceService) -> String:
	if not _due():
		return ""
	if not mandatory:
		if dice.roll_d6() <= NOTHING_ON:
			return ""
	return _pick(dice)

## Сумма весов — только по ИЗВЕСТНЫМ событиям (0.9.4). Прежде она считала все ключи, и
## вес выбывшего «tremor» из старых настроек съедал свою долю розыгрыша: событие выпадало
## «никакое» и ход проходил впустую. Незнакомый ключ теперь не влияет ни на что.
func _total_weight() -> int:
	var t := 0
	for pair in REGISTRY:
		var w := int(weights.get(pair[0], 0))
		if w > 0:
			t += w
	return t

## Взвешенно выбрать событие ЧЕРЕЗ DiceService (лок-степ). Возвращает id или "".
func _pick(dice: DiceService) -> String:
	var total := _total_weight()
	if total <= 0:
		return ""
	# Ролл 1..total из общего потока: три d6 дают 216 значений, берём остаток — тем же
	# приёмом, что и разлёт тел в резолвере, чтобы не заводить второй RNG.
	var v := 0
	for _i in 3:
		v = v * 6 + (dice.roll_d6() - 1)
	var pick := v % total
	# Обходим реестр в ФИКСИРОВАННОМ порядке — одинаково у хоста и клиента.
	for pair in REGISTRY:
		var id: String = pair[0]
		var w := int(weights.get(id, 0))
		if w <= 0:
			continue
		if pick < w:
			return id
		pick -= w
	return ""

# --- Очередь объявленных событий -------------------------------------------------------

## Warnings last exactly one player turn. Round metadata remains in snapshots
## for compatibility; old pending warnings also resolve on the next end-turn.
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
	return {"enabled": enabled, "mandatory": mandatory, "interval": interval,
			"weights": weights.duplicate(), "turns_since": turns_since,
			"pending": pend, "clouds": cl, "armies": armies}

func restore(d: Dictionary) -> void:
	enabled = d.get("enabled", false)
	mandatory = d.get("mandatory", false)
	interval = d.get("interval", 3)
	weights = (d.get("weights", {}) as Dictionary).duplicate()
	turns_since = d.get("turns_since", 0)
	pending = []
	for e: Dictionary in d.get("pending", []):
		pending.append({"id": str(e.get("id", "")),
				"params": (e.get("params", {}) as Dictionary).duplicate(),
				"announced": int(e.get("announced", 0)), "land": int(e.get("land", 0))})
	clouds = []
	for c: Dictionary in d.get("clouds", []):
		clouds.append((c as Dictionary).duplicate())
	armies = int(d.get("armies", 0))

static func from_config() -> RandomEvents:
	var w: Dictionary = GameConfig.random_events_weights
	return RandomEvents.new(GameConfig.random_events_enabled,
			GameConfig.random_events_mandatory, GameConfig.random_events_interval,
			w if not w.is_empty() else default_weights())
