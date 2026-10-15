class_name LearnedController
extends PlayerController

## Обученный противник (RL v1, spec §7, §12). Тот же шов, что у AIController: begin_turn()
## → intent_ready, notify_intent_denied(). Решение принимает политика, а не эвристика:
## контроллер перечисляет законные намерения (resolver.legal_intents), кодирует
## наблюдение так же, как при обучении (rl/ObsEncoder.gd — БЕЗ всеведения, §3.3: политика
## видит ровно то, что видел бы человек на этом месте), и спрашивает у сервера политики
## индекс выбранного намерения.
##
## Native ONNX inference is preferred; MCF_RL_POLICY keeps the training socket path.
## Both accept the same observation/legal-intent request and return an action index.
##
## Если модели нет (переменная не задана, сервер не отвечает, ответ невалиден) — слот
## ведёт AIController HARD, а в журнал боя уходит сообщение (§12: «лобби говорит об
## этом»). Раз включившись, запасной мозг остаётся до конца партии: полусессия на
## политике, полусессия на эвристике была бы хуже любого из двух.

const Obs = preload("res://rl/ObsEncoder.gd")
const ENV_VAR := "MCF_RL_POLICY"
## Подпись модели для лобби («town-8 · update 3867 · step 5,939,822»), от `train.py play`.
const ENV_LABEL := "MCF_RL_MODEL_LABEL"
const ENV_MODEL := "MCF_RL_MODEL"
## train.py play explicitly selects its freshly started checkpoint server.
const ENV_BACKEND := "MCF_RL_BACKEND"
const BUNDLED_MODEL := "res://assets/policy/baseline.onnx"
static var _embedded: RefCounted = null
static var _embedded_metadata: Dictionary = {}
static var _embedded_key := ""
static var _embedded_error := ""

static func _load_embedded() -> RefCounted:
	if OS.get_environment(ENV_BACKEND) == "socket":
		return null
	var path := OS.get_environment(ENV_MODEL)
	if path.is_empty():
		path = BUNDLED_MODEL
	if _embedded_key == path:
		return _embedded
	_embedded_key = path
	_embedded = null
	_embedded_metadata = {}
	_embedded_error = ""
	if not ClassDB.class_exists("MCFPolicy"):
		return null
	var policy: RefCounted = ClassDB.instantiate("MCFPolicy")
	var result: Variant = policy.call("load_model", path)
	if result is Dictionary and result.get("ok", false):
		_embedded = policy
		_embedded_metadata = result
	else:
		_embedded_error = "embedded policy error: " + str(result)
	return _embedded

## A loadable embedded model or configured server makes AI - Learned available.
static func available() -> bool:
	return _load_embedded() != null or OS.get_environment(ENV_VAR) != ""

static func model_label() -> String:
	var l := OS.get_environment(ENV_LABEL)
	if _load_embedded() != null:
		return l if l != "" else str(_embedded_metadata.get("mcf.label", "ONNX · " + _embedded_key.get_file()))
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
var reply_timeout_ms := REPLY_TIMEOUT_MS
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
var _match_resolver: WeakRef = null
var _rx := ""

func bind_match(r: GameActionResolver) -> void:
	_match_resolver = weakref(r)

func _init(p_owner: int) -> void:
	super(p_owner)
	if _load_embedded() != null:
		if OS.get_environment(ENV_MAX_ACTORS).is_empty():
			_max_actors = int(_embedded_metadata.get("mcf.max_actors", 0))
		if OS.get_environment(ENV_MAX_CANDIDATES).is_empty():
			_max_candidates = int(_embedded_metadata.get("mcf.max_candidates", 0))
		if OS.get_environment(ENV_ROUND_CAP).is_empty():
			_round_cap = maxi(1, int(_embedded_metadata.get("mcf.round_cap", ROUND_CAP_FALLBACK)))

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
	if _match_resolver != null:
		var live: GameActionResolver = _match_resolver.get_ref()
		if live != null and live.state == state:
			_resolver.random_events = live.random_events
			_resolver.disembark_enabled = live.disembark_enabled
	# Тот же бюджет намерений, что и в обучении. Иначе в настоящей партии сеть увидит
	# 8000+ кандидатов там, где училась на 512, и выберет argmax по совсем другому
	# множеству: обучение и бой обязаны показывать политике список одной формы.
	# Потолки приходят от `train.py play` из конфига самого чекпойнта.
	var legal: Array = IntentBudget.cap(IntentBudget.keep_large_army_active(
			IntentBudget.drop_blind_shots(_resolver.legal_intents(
			owner, IntentBudget.actor_subset(_resolver, owner, _max_actors, _budget_rng)),
			_resolver, owner), state, owner), _max_candidates, _budget_rng, _resolver, owner)
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
	if _match_resolver != null and _match_resolver.get_ref() != null:
		_fallback.bind_match(_match_resolver.get_ref())
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

var _native_failed := false

## Kept as a method so regression fixtures can exercise broken/absent native backends.
func _embedded_infer(req: Dictionary) -> Variant:
	var policy := _load_embedded()
	return policy.call("infer", req) if policy != null else {}

static func _valid_reply(reply: Variant, count: int) -> bool:
	if not reply is Dictionary or reply.has("error") or not reply.has("action"):
		return false
	var action: Variant = reply["action"]
	if not (action is int or action is float):
		return false
	var number := float(action)
	if not is_finite(number) or number < 0 or number >= count or number != floor(number):
		return false
	if reply.has("value"):
		var value: Variant = reply["value"]
		if not (value is int or value is float) or not is_finite(float(value)):
			return false
	return true

func _ask(req: Dictionary) -> Dictionary:
	var native_reason := ""
	if not _native_failed and OS.get_environment(ENV_BACKEND) != "socket":
		var reply: Variant = _embedded_infer(req)
		if _valid_reply(reply, req.get("legal", []).size()):
			return reply
		if not (reply is Dictionary and reply.is_empty()):
			native_reason = "embedded policy error: " + str(reply)
		else:
			native_reason = _embedded_error
			if native_reason.is_empty() and _load_embedded() != null:
				native_reason = "embedded policy error: empty reply"
		_native_failed = true
	var reply := _ask_socket(req)
	if _valid_reply(reply, req.get("legal", []).size()):
		return reply
	if not reply.is_empty():
		_last_error = "policy answered an invalid action: " + str(reply)
	if native_reason != "":
		_last_error = native_reason + "; " + _last_error
	return {}

func _ask_socket(req: Dictionary) -> Dictionary:
	if _peer == null and not _connect():
		return {}
	var line := JSON.stringify(req) + "\n"
	if _peer.put_data(line.to_utf8_buffer()) != OK:
		_last_error = "policy connection dropped"
		_peer = null
		return {}
	var deadline := Time.get_ticks_msec() + reply_timeout_ms
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
	_last_error = "policy did not answer within %d s" % (reply_timeout_ms / 1000)
	_peer = null
	return {}
