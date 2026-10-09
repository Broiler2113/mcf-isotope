class_name LearnedController
extends PlayerController

## Обученный противник (RL v1, spec §7, §12). Тот же шов, что у AIController: begin_turn()
## → intent_ready, notify_intent_denied(). Решение принимает политика, а не эвристика:
## контроллер перечисляет законные намерения (resolver.legal_intents), кодирует
## наблюдение так же, как при обучении (rl/ObsEncoder.gd — БЕЗ всеведения, §3.3: политика
## видит ровно то, что видел бы человек на этом месте), и спрашивает у сервера политики
## индекс выбранного намерения.
##
## v1 «сервер политики» — локальный процесс rl/policy_server.py, адрес в переменной
## окружения MCF_RL_POLICY (так запускает `train.py play`). Встроенный ONNX-рантайм (§12)
## подключится сюда же, заменив _ask(): протокол наблюдение → индекс не изменится.
##
## Если модели нет (переменная не задана, сервер не отвечает, ответ невалиден) — слот
## ведёт AIController HARD, а в журнал боя уходит сообщение (§12: «лобби говорит об
## этом»). Раз включившись, запасной мозг остаётся до конца партии: полусессия на
## политике, полусессия на эвристике была бы хуже любого из двух.

const Obs = preload("res://rl/ObsEncoder.gd")
const ENV_VAR := "MCF_RL_POLICY"
## Подпись модели для лобби («town-8 · update 3867 · step 5,939,822»), от `train.py play`.
const ENV_LABEL := "MCF_RL_MODEL_LABEL"

## Игра запущена с сервером политики — есть против кого играть «AI - Learned».
static func available() -> bool:
	return OS.get_environment(ENV_VAR) != ""

static func model_label() -> String:
	var l := OS.get_environment(ENV_LABEL)
	return l if l != "" else "served on " + OS.get_environment(ENV_VAR)
const IntentBudget = preload("res://rl/IntentBudget.gd")
const EnemyMemory = preload("res://rl/EnemyMemory.gd")
## Память о врагах, ушедших в туман, — та же, что у обучаемого в env_server.
var _memory := EnemyMemory.new()
## Потолки бюджета намерений: столько же, сколько видела политика при обучении.
## `train.py play` выставляет их из конфига чекпойнта; 0 = без ограничения (так ведут
## себя чекпойнты, обученные до появления потолков).
const ENV_MAX_ACTORS := "MCF_RL_MAX_ACTORS"
const ENV_MAX_CANDIDATES := "MCF_RL_MAX_CANDIDATES"
var _max_actors: int = int(OS.get_environment(ENV_MAX_ACTORS))
var _max_candidates: int = int(OS.get_environment(ENV_MAX_CANDIDATES))
var _budget_rng := RandomNumberGenerator.new()
const CONNECT_TIMEOUT_MS := 3000
const REPLY_TIMEOUT_MS := 30000
## Лимит раундов, с которым обучалась политика (Q4): наблюдение содержит round/round_cap,
## то есть номер раунда попадает в сеть ПОДЕЛЁННЫМ на это число. Значит оно обязано быть
## тем же, с которым училась политика, иначе один из входов systematically смещён.
##
## Раньше здесь стояла жёсткая 10, а town-7/town-8 учились с round_cap 20: в бою сеть
## получала вдвое больший «прогресс партии», чем видела при обучении, и после десятого
## раунда — значение за пределами всего, что ей вообще показывали. Приходит от
## `train.py play` из конфига самого чекпойнта, как и потолки бюджета; 10 остаётся
## запасным значением для чекпойнтов, обученных до появления переменной.
const ENV_ROUND_CAP := "MCF_RL_ROUND_CAP"
const ROUND_CAP_FALLBACK := 10
var _round_cap: int = (int(OS.get_environment(ENV_ROUND_CAP))
		if int(OS.get_environment(ENV_ROUND_CAP)) > 0 else ROUND_CAP_FALLBACK)

signal fallback_engaged(reason: String)

var _peer: StreamPeerTCP = null
var _fallback: AIController = null
var _resolver: GameActionResolver = null
var _rx := ""

func _init(p_owner: int) -> void:
	super(p_owner)

func begin_turn(state: GameState) -> void:
	if state.active_player() != owner:
		return
	if _fallback != null:
		_fallback.begin_turn(state)
		return
	var picked := _decide(state)
	if picked.is_empty():
		_engage_fallback(state, str(_last_error))
		return
	intent_ready.emit(picked["intent"])

## Действие прошло — накопленные отказы относились к прежней доске. Зовётся из Main.gd
## там же, где сбрасывается счётчик отказов.
func notify_intent_accepted() -> void:
	_denied.clear()

## Список политики точен (tests/run_legal_intents.gd): отказ резолвера здесь — признак
## расхождения досок, а не «повторить тот же расчёт». На следующем begin_turn список
## перечисляется заново с настоящей доски; запасному мозгу отказ передаём как есть.
func notify_intent_denied(state: GameState) -> void:
	if _fallback != null:
		_fallback.notify_intent_denied(state)
		return
	# Отказ при ЖИВОЙ политике раньше не делал ничего, и это было тихой ловушкой.
	#
	# Сервер политики отвечает ЖАДНО: одно и то же наблюдение — один и тот же индекс.
	# Значит, если резолвер отказал, следующий begin_turn на той же доске предложит ровно
	# то же намерение, и так до тех пор, пока Main.gd не насчитает AI_MAX_DENIED отказов
	# подряд и не завершит ход принудительно. Со стороны это выглядит буквально как «ИИ
	# пропускает ход».
	#
	# Запоминаем отказанное намерение и на следующем решении исключаем его из списка: сеть
	# вынуждена выбрать что-то другое, цикл рвётся, ход продолжается.
	_denied.append(_last_intent_key)

## Ключи намерений, отказанных на ТЕКУЩЕЙ доске. Чистится, как только решение прошло.
var _denied: Array[String] = []
var _last_intent_key := ""

static func _intent_key(i: Intent) -> String:
	return "%s|%d|%s" % [i.get_class(), i.actor_id, JSON.stringify(IntentCodec.encode(i))]

var _last_error := ""

func _decide(state: GameState) -> Dictionary:
	if _resolver == null or _resolver.state != state:
		# Один резолвер на партию: STANDARD-туман помнит разведанные клетки (explored), и
		# память эта должна накапливаться, как у человека за этим столом.
		_resolver = GameActionResolver.new(state)
		_resolver.fog_mode = GameConfig.fog_mode
		_resolver.friendly_fire_enabled = GameConfig.friendly_fire
		_resolver.omniscient_side = -1
	# Тот же бюджет намерений, что и в обучении. Иначе в настоящей партии сеть увидит
	# 8000+ кандидатов там, где училась на 512, и выберет argmax по совсем другому
	# множеству: обучение и бой обязаны показывать политике список одной формы.
	# Потолки приходят от `train.py play` из конфига самого чекпойнта.
	var legal: Array = IntentBudget.cap(IntentBudget.drop_blind_shots(_resolver.legal_intents(
			owner, IntentBudget.actor_subset(_resolver, owner, _max_actors, _budget_rng)),
			_resolver, owner), _max_candidates, _budget_rng, _resolver, owner)
	# Выкинуть то, что резолвер уже отказал на этой доске (см. notify_intent_denied).
	# Если после этого не осталось ничего — список исчерпан, и честнее сдать ход, чем
	# предлагать отказанное по кругу.
	if not _denied.is_empty():
		var kept: Array = []
		for intent: Intent in legal:
			if not _denied.has(_intent_key(intent)):
				kept.append(intent)
		legal = kept
	if legal.is_empty():
		_last_error = "no legal intents"
		return {}
	# Тот же тактический контекст (карта огня, цена хода в ОД), что и в обучении.
	_memory.observe(_resolver, owner)
	var tac: Dictionary = Obs.tactics(_resolver, owner, _memory)
	var desc: Array = []
	for intent: Intent in legal:
		desc.append(Obs.describe(state, intent, tac))
	var req := {"obs": Obs.encode(_resolver, owner, _round_cap, tac), "legal": desc}
	var reply := _ask(req)
	if reply.is_empty():
		return {}
	var k := int(reply.get("action", -1))
	if k < 0 or k >= legal.size():
		_last_error = "policy answered index %d of %d" % [k, legal.size()]
		return {}
	# Решение прошло: запоминаем ключ (вдруг откажут) и сбрасываем накопленные отказы —
	# доска после успешного действия другая, и старый список к ней уже не относится.
	_last_intent_key = _intent_key(legal[k])
	return {"intent": legal[k]}

func _engage_fallback(state: GameState, reason: String) -> void:
	_fallback = AIController.new(owner, AIController.Difficulty.HARD)
	# A lambda capturing this RefCounted controller creates a cycle through the
	# owned fallback. A method Callable forwards the same signal without retaining us.
	_fallback.intent_ready.connect(_on_fallback_intent)
	fallback_engaged.emit(reason)
	_fallback.begin_turn(state)

func _on_fallback_intent(intent: Intent) -> void:
	intent_ready.emit(intent)

# --- Связь с сервером политики (JSON-строки по TCP) ---

func _connect() -> bool:
	_rx = ""
	var addr := OS.get_environment(ENV_VAR)
	if addr == "":
		_last_error = "%s is not set" % ENV_VAR
		return false
	var parts := addr.split(":")
	var host := parts[0]
	var port := int(parts[1]) if parts.size() > 1 else 7791
	_peer = StreamPeerTCP.new()
	if _peer.connect_to_host(host, port) != OK:
		_last_error = "cannot connect to %s" % addr
		_peer = null
		return false
	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		var st := _peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			_peer.set_no_delay(true)
			return true
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			break
		OS.delay_msec(5)
	_last_error = "policy server at %s did not accept the connection" % addr
	_peer = null
	return false

func _ask(req: Dictionary) -> Dictionary:
	if _peer == null and not _connect():
		return {}
	var line := JSON.stringify(req) + "\n"
	if _peer.put_data(line.to_utf8_buffer()) != OK:
		_last_error = "policy connection dropped"
		_peer = null
		return {}
	var deadline := Time.get_ticks_msec() + REPLY_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_last_error = "policy connection closed"
			_peer = null
			return {}
		var n := _peer.get_available_bytes()
		if n > 0:
			var chunk: Array = _peer.get_data(n)
			if int(chunk[0]) == OK:
				_rx += (chunk[1] as PackedByteArray).get_string_from_utf8()
			var nl := _rx.find("\n")
			if nl >= 0:
				var text := _rx.substr(0, nl)
				_rx = _rx.substr(nl + 1)
				var parsed: Variant = JSON.parse_string(text)
				if typeof(parsed) == TYPE_DICTIONARY:
					if parsed.has("error"):
						_last_error = "policy error: " + str(parsed["error"])
						return {}
					return parsed
				_last_error = "policy sent something that is not JSON"
				return {}
		else:
			OS.delay_msec(2)
	_last_error = "policy did not answer within %d s" % (REPLY_TIMEOUT_MS / 1000)
	_peer = null
	return {}
