class_name RandomEvents
extends RefCounted

## Каркас случайных событий (§1.5 лобби, item 61). Хост в лобби включает события,
## задаёт «обязательное событие каждый ход» / «сколько ходов между событиями» и веса-доли
## по каждому событию. РЕАЛЬНЫХ спеков эффектов пока нет — поэтому здесь ровно три
## ЗАГЛУШКИ (Mortar, Tremor, Gas): они объявляются в журнале и наносят условный,
## полностью детерминированный эффект.
##
## Главный инвариант — лок-степ (§2.3): и «случится ли событие», и «какое именно», и куда
## оно бьёт, берётся ТОЛЬКО из DiceService. Хост и клиент прокатывают один и тот же поток
## d6, значит выберут одно и то же событие в одном и том же месте. Ни одного постороннего
## RNG здесь быть не должно.

const MORTAR := "mortar"
const TREMOR := "tremor"
const GAS := "gas"

## Реестр известных событий: id -> человекочитаемое имя. Порядок фиксирован — по нему
## взвешенный выбор обходит события, поэтому у хоста и клиента он совпадает.
const REGISTRY := [
	[MORTAR, "Mortar Strike"],
	[TREMOR, "Tremor"],
	[GAS, "Gas Cloud"],
]

static func event_name(id: String) -> String:
	for pair in REGISTRY:
		if pair[0] == id:
			return pair[1]
	return id

## Веса по умолчанию, если хост включил события, но не тронул доли: все три поровну.
static func default_weights() -> Dictionary:
	return {MORTAR: 1, TREMOR: 1, GAS: 1}


## Состояние розыгрыша событий на весь матч. Живёт на резолвере и входит в снимок
## состояния, чтобы откат хода не «терял» отсчёт ходов до следующего события.
var enabled: bool = false
var mandatory: bool = false        # событие ОБЯЗАТЕЛЬНО каждый ход
var interval: int = 3              # иначе — раз в столько ходов
var weights: Dictionary = {}       # id -> вес-доля (item 1.5)
var turns_since: int = 0           # ходов прошло с прошлого события

func _init(cfg_enabled := false, cfg_mandatory := false, cfg_interval := 3,
		cfg_weights: Dictionary = {}) -> void:
	enabled = cfg_enabled
	mandatory = cfg_mandatory
	interval = maxi(1, cfg_interval)
	weights = cfg_weights.duplicate() if not cfg_weights.is_empty() else default_weights()

## d6, на котором и ниже ничего не происходит на «созревшем» ходу, когда режим НЕ
## обязательный (item 11): 1–2 из шести ≈ треть — заметный, но не доминирующий шанс тишины.
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

func _total_weight() -> int:
	var t := 0
	for id in weights:
		if int(weights[id]) > 0:
			t += int(weights[id])
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

## Снимок/восстановление для отката хода (счётчик ходов обязан переживать undo).
func snapshot() -> Dictionary:
	return {"enabled": enabled, "mandatory": mandatory, "interval": interval,
			"weights": weights.duplicate(), "turns_since": turns_since}

func restore(d: Dictionary) -> void:
	enabled = d.get("enabled", false)
	mandatory = d.get("mandatory", false)
	interval = d.get("interval", 3)
	weights = (d.get("weights", {}) as Dictionary).duplicate()
	turns_since = d.get("turns_since", 0)

static func from_config() -> RandomEvents:
	var w: Dictionary = GameConfig.random_events_weights
	return RandomEvents.new(GameConfig.random_events_enabled,
			GameConfig.random_events_mandatory, GameConfig.random_events_interval,
			w if not w.is_empty() else default_weights())
