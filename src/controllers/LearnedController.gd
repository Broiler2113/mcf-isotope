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
const CONNECT_TIMEOUT_MS := 3000
const REPLY_TIMEOUT_MS := 30000
## Лимит раундов, с которым обучалась политика (Q4): наблюдение содержит round/round_cap.
const ROUND_CAP := 10

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

## Список политики точен (tests/run_legal_intents.gd): отказ резолвера здесь — признак
## расхождения досок, а не «повторить тот же расчёт». На следующем begin_turn список
## перечисляется заново с настоящей доски; запасному мозгу отказ передаём как есть.
func notify_intent_denied(state: GameState) -> void:
	if _fallback != null:
		_fallback.notify_intent_denied(state)

var _last_error := ""

func _decide(state: GameState) -> Dictionary:
	if _resolver == null or _resolver.state != state:
		# Один резолвер на партию: STANDARD-туман помнит разведанные клетки (explored), и
		# память эта должна накапливаться, как у человека за этим столом.
		_resolver = GameActionResolver.new(state)
		_resolver.fog_mode = GameConfig.fog_mode
		_resolver.friendly_fire_enabled = GameConfig.friendly_fire
		_resolver.omniscient_side = -1
	var legal: Array = _resolver.legal_intents(owner)
	if legal.is_empty():
		_last_error = "no legal intents"
		return {}
	var desc: Array = []
	for intent: Intent in legal:
		desc.append(Obs.describe(state, intent))
	var req := {"obs": Obs.encode(_resolver, owner, ROUND_CAP), "legal": desc}
	var reply := _ask(req)
	if reply.is_empty():
		return {}
	var k := int(reply.get("action", -1))
	if k < 0 or k >= legal.size():
		_last_error = "policy answered index %d of %d" % [k, legal.size()]
		return {}
	return {"intent": legal[k]}

func _engage_fallback(state: GameState, reason: String) -> void:
	_fallback = AIController.new(owner, AIController.Difficulty.HARD)
	_fallback.intent_ready.connect(func(i: Intent) -> void: intent_ready.emit(i))
	fallback_engaged.emit(reason)
	_fallback.begin_turn(state)

# --- Связь с сервером политики (JSON-строки по TCP) ---

func _connect() -> bool:
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
					return parsed
				_last_error = "policy sent something that is not JSON"
				return {}
		else:
			OS.delay_msec(2)
	_last_error = "policy did not answer within %d s" % (REPLY_TIMEOUT_MS / 1000)
	_peer = null
	return {}
