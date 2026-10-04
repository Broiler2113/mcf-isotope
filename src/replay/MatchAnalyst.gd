class_name MatchAnalyst
extends RefCounted

## Разбор сыгранной партии обученной политикой («play vs latest»). Берёт запись матча,
## прогоняет её с самого начала и на КАЖДОМ решении ОБЕИХ сторон спрашивает политику:
## что бы сделала она и во что оценивает позицию.
##
## Политика не рассказчик — словами она ничего не объясняет. Она возвращает ровно два
## числа, и весь разбор складывается из них:
##
##   • совпал ли сыгранный ход с её выбором — «я бы сыграл иначе»;
##   • на сколько просела ЕЁ ЖЕ оценка позиции от одного решения стороны до следующего
##     её решения. Это и есть цена хода: в провал попадает и сам ход, и всё, что
##     соперник успел сделать в ответ.
##
## Спрашивается по обеим сторонам, поэтому ошибки видно и у человека, и у машины — о чём
## игрок и просил: «что сделано верно и какие ошибки были у обеих сторон».
##
## ЧЕСТНОСТЬ ТУМАНА сохраняется: наблюдение для каждой стороны собирается её же
## резолвером (Obs.encode со стороной), то есть политика судит о ходе по тому, что
## сторона ВИДЕЛА в тот момент, а не по всей доске. Иначе разбор ругал бы игрока за то,
## чего он знать не мог.
##
## Разбор НЕ играет и ничего не меняет: доска здесь своя, собранная из записи.

const Obs = preload("res://rl/ObsEncoder.gd")
const IntentBudget = preload("res://rl/IntentBudget.gd")
const EnemyMemory = preload("res://rl/EnemyMemory.gd")

const REPLY_TIMEOUT_MS := 4000
## Сколько ходов разбирается за один заход step_many(): пока идёт разбор, экран должен
## оставаться живым, а каждый вопрос политике — это сетевой round-trip.
const CHUNK := 8

## Строка разбора: один ход одной стороны.
## {round, side, played, suggested, agreed, value, swing, offered}
var rows: Array = []
var error := ""

var _player: ReplayPlayer = null
var _peer: StreamPeerTCP = null
var _rx := ""
var _round_cap := 40
var _max_actors := 0
var _max_candidates := 0
var _rng := RandomNumberGenerator.new()
var _memory := {}          # side -> EnemyMemory
var _last_value := {}      # side -> оценка на её прошлом решении
var _last_row := {}        # side -> индекс её прошлой строки в rows

static func available() -> bool:
	return LearnedController.available()

func begin(data: Dictionary, round_cap: int = 40) -> bool:
	rows = []
	error = ""
	_round_cap = round_cap
	_max_actors = int(OS.get_environment(LearnedController.ENV_MAX_ACTORS))
	_max_candidates = int(OS.get_environment(LearnedController.ENV_MAX_CANDIDATES))
	# Своё зерно на разбор, а не общий поток: тот же матч обязан разбираться одинаково
	# при каждом запуске, иначе «ошибки» будут плавать от прогона к прогону.
	_rng.seed = 20260101
	_player = ReplayPlayer.new(data)
	_player.seek(0)
	if _player.state == null:
		error = "the recording has no opening board"
		return false
	return true

func total() -> int:
	return _player.step_count() if _player != null else 0

func done() -> int:
	return _player.index if _player != null else 0

func has_next() -> bool:
	return _player != null and _player.has_next()

## Разобрать до CHUNK ходов. Возвращает false, когда запись кончилась.
func step_many() -> bool:
	for _i in CHUNK:
		if not has_next():
			return false
		_step_one()
	return has_next()

func _step_one() -> void:
	var state := _player.state
	var r := _player.resolver
	var side := state.active_player()
	var step: Dictionary = _player.steps()[_player.index]
	var played := IntentCodec.decode(step.get("i", {}))
	# Конец хода разбирать нечего: это не выбор, а его отсутствие.
	if played == null or played is EndTurnIntent or not MCF.is_player(side):
		_player.play_next()
		return
	var verdict := _ask_policy(state, r, side, played)
	_player.play_next()
	if verdict.is_empty():
		return
	var value := float(verdict["value"])
	# Качели оценки с ПРОШЛОГО решения этой же стороны — цена того хода, не этого.
	if _last_row.has(side):
		var prev: int = _last_row[side]
		rows[prev]["swing"] = value - float(_last_value[side])
	_last_value[side] = value
	_last_row[side] = rows.size()
	rows.append({
		"round": state.turns.round_number,
		"side": side,
		"played": intent_line(state, played),
		"suggested": String(verdict["suggested"]),
		"agreed": bool(verdict["agreed"]),
		"offered": bool(verdict["offered"]),
		"value": value,
		"swing": 0.0,
	})

## Подпись хода для отчёта: КТО и ЧТО сделал, человеческими словами. Один «move» без
## бойца и клетки в списке ошибок бесполезен — по нему ход не узнать.
static func intent_line(state: GameState, i: Intent) -> String:
	var wire := IntentCodec.encode(i)
	var kind := String(wire.get("t", ""))
	if kind == "":
		kind = i.get_class()
	var who := ""
	var aid := int(wire.get("a", -1))
	var u := state.get_unit(aid)
	if u != null:
		who = u.stats.display_name
	else:
		var veh := state.get_vehicle(aid)
		if veh != null:
			who = String(VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id))
	var what := kind
	if int(wire.get("tid", -1)) >= 0:
		var t := state.get_unit(int(wire["tid"]))
		if t != null:
			what = "%s %s at (%d, %d)" % [kind, t.stats.display_name, t.coord.x, t.coord.y]
	elif wire.has("x") and wire.has("y"):
		what = "%s to (%d, %d)" % [kind, int(wire["x"]), int(wire["y"])]
	return ("%s %s" % [who, what]) if who != "" else what

## Спросить политику об этой доске глазами side. {} — спросить не вышло.
func _ask_policy(state: GameState, r: GameActionResolver, side: int,
		played: Intent) -> Dictionary:
	if not _memory.has(side):
		_memory[side] = EnemyMemory.new()
	var mem: EnemyMemory = _memory[side]
	var legal: Array = IntentBudget.cap(IntentBudget.drop_blind_shots(
			r.legal_intents(side, IntentBudget.actor_subset(r, side, _max_actors, _rng)),
			r, side), _max_candidates, _rng, r, side)
	if legal.is_empty():
		return {}
	mem.observe(r, side)
	var tac: Dictionary = Obs.tactics(r, side, mem)
	var desc: Array = []
	for intent: Intent in legal:
		desc.append(Obs.describe(state, intent, tac))
	var reply := _ask({"obs": Obs.encode(r, side, _round_cap, tac), "legal": desc})
	if reply.is_empty():
		return {}
	var k := int(reply.get("action", -1))
	if k < 0 or k >= legal.size():
		return {}
	# Сыгранный ход мог не попасть в урезанный список (бюджет берёт не всех актёров).
	# Тогда «согласна ли политика» — вопрос без смысла, и мы честно это помечаем, а не
	# записываем игроку ошибку, которой он не делал.
	var key := _key(played)
	var offered := false
	for intent: Intent in legal:
		if _key(intent) == key:
			offered = true
			break
	return {
		"value": float(reply.get("value", 0.0)),
		"suggested": intent_line(state, legal[k]),
		"agreed": offered and _key(legal[k]) == key,
		"offered": offered,
	}

static func _key(i: Intent) -> String:
	return JSON.stringify(IntentCodec.encode(i))

# --- связь с сервером политики ------------------------------------------------------
## Свой сокет, а не чужой: LearnedController держит соединение под ИГРУ, и разбор, влезая
## в него, рвал бы партию, которую как раз разбирает. Двадцать строк повтора дешевле.
func _connect() -> bool:
	var addr := OS.get_environment(LearnedController.ENV_VAR)
	var parts := addr.split(":")
	if parts.size() != 2:
		error = "MCF_RL_POLICY is not host:port"
		return false
	_peer = StreamPeerTCP.new()
	if _peer.connect_to_host(parts[0], int(parts[1])) != OK:
		error = "cannot reach the policy server"
		_peer = null
		return false
	var deadline := Time.get_ticks_msec() + REPLY_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		var st := _peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			return true
		if st == StreamPeerTCP.STATUS_ERROR:
			break
	error = "the policy server did not answer"
	_peer = null
	return false

func _ask(req: Dictionary) -> Dictionary:
	if _peer == null and not _connect():
		return {}
	if _peer.put_data((JSON.stringify(req) + "\n").to_utf8_buffer()) != OK:
		error = "policy connection dropped"
		_peer = null
		return {}
	var deadline := Time.get_ticks_msec() + REPLY_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			error = "policy connection closed"
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
				error = "the policy server sent something unreadable"
				return {}
	error = "the policy server timed out"
	return {}

## Самые дорогие ходы: там, где оценка позиции просела сильнее всего. Это и есть
## «какие ошибки были» — и у той стороны, и у другой.
func worst(limit: int = 8) -> Array:
	var sorted := rows.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["swing"]) < float(b["swing"]))
	return sorted.slice(0, limit)

## Насколько часто сторона играла то же, что выбрала бы политика (по ходам, которые ей
## вообще предлагались).
func agreement(side: int) -> float:
	var seen := 0
	var same := 0
	for row: Dictionary in rows:
		if int(row["side"]) != side or not bool(row["offered"]):
			continue
		seen += 1
		if bool(row["agreed"]):
			same += 1
	return float(same) / float(maxi(1, seen))
