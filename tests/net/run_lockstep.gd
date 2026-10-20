extends SceneTree

## Проверка лок-степа: две независимые партии из одной карты и одного зерна.
##
## Ведущая («хост») решает и ЗАПИСЫВАЕТ броски; ведомая («клиент») получает то же
## намерение и те же броски и обязана прийти к побайтово той же доске. Это ровно
## контракт §22.1, только без сети — сеть здесь ничего не добавила бы, кроме
## задержки.
##
## Проверяется три вещи, и третья — та, которой в проекте не хватало (AUDIT §2.3):
##   1) слепки досок совпадают после КАЖДОГО действия;
##   2) клиент израсходовал ровно столько кубиков, сколько прислал хост;
##   3) клиент ни разу не сходил в собственный RNG.
## Без (2) и (3) расхождение начинается молча и обнаруживается ходов через двадцать.

const TS = preload("res://tests/TestSupport.gd")

const ROUNDS := 4
const MAX_ACTIONS := 20000

var _pending: Intent = null
var _failures: PackedStringArray = []

func _initialize() -> void:
	var ok := _run()
	quit(0 if ok else 1)

func _run() -> bool:
	var host := TS.build_state()
	var client := TS.build_state()
	var r_host := GameActionResolver.new(host)
	var r_client := GameActionResolver.new(client)
	r_host.fog_enabled = false
	r_client.fog_enabled = false

	if host.turns.round_order != client.turns.round_order:
		_fail("initiative diverged at build: %s vs %s" % [
				str(host.turns.round_order), str(client.turns.round_order)])
		return _report(0)
	_step("opening civilian slot", host, client,
			func(): return r_host.play_civilian_slots(),
			func(): return r_client.play_civilian_slots())

	var brains := {}
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var ai := AIController.new(side, AIController.Difficulty.NORMAL)
		ai.intent_ready.connect(_on_intent)
		brains[side] = ai

	var actions := 0
	while host.turns.round_number <= ROUNDS and actions < MAX_ACTIONS \
			and _failures.is_empty():
		var side: int = host.active_player()
		var ai: AIController = brains.get(side, null)
		var intent: Intent
		if ai == null:
			intent = EndTurnIntent.new()
		else:
			_pending = null
			ai.begin_turn(host)
			intent = _pending if _pending != null else EndTurnIntent.new()
		actions += 1
		# Через кодек — и обратно. Намерение обязано пережить провод целиком:
		# именно потерянное при кодировании поле и есть классический рассинхрон
		# этого проекта (AUDIT §2.2).
		var wire := IntentCodec.encode(intent)
		var decoded := IntentCodec.decode(wire)
		if decoded == null:
			_fail("action %d: IntentCodec.decode returned null for %s"
					% [actions, TS.intent_line(intent)])
			break
		_step("action %d %s" % [actions, TS.intent_line(intent)], host, client,
				func(): return r_host.resolve(intent),
				func(): return r_client.resolve(decoded))
		if not _last_ok and ai != null:
			ai.notify_intent_denied(host)
	return _report(actions)

## Успех последнего действия у хоста — по нему решается, снимать ли актёра с
## очереди ИИ, ровно как это делает боевой экран.
var _last_ok := true

## Одно синхронное действие: хост пишет броски, клиент их проигрывает, сверяем.
func _step(label: String, host: GameState, client: GameState,
		host_call: Callable, client_call: Callable) -> void:
	host.dice.begin_record()
	var res: ActionResult = host_call.call()
	var rolls := host.dice.take_log()
	_last_ok = res.ok

	client.dice.fallback_rolls = 0
	client.dice.feed_scripted(rolls)
	client_call.call()

	var left := client.dice.scripted_remaining()
	if left != 0:
		_fail("%s: client left %d of %d supplied dice unconsumed"
				% [label, left, rolls.size()])
	if client.dice.fallback_rolls != 0:
		_fail("%s: client fell back to its own RNG %d time(s)"
				% [label, client.dice.fallback_rolls])
	var dh := TS.digest(host)
	var dc := TS.digest(client)
	if dh != dc:
		_fail("%s: BOARDS DIVERGED\n%s" % [label, _first_diff(dh, dc)])

func _on_intent(intent: Intent) -> void:
	_pending = intent

func _fail(msg: String) -> void:
	_failures.append(msg)

func _report(actions: int) -> bool:
	if _failures.is_empty():
		print("lockstep: %d actions, host and client agree throughout" % actions)
		return true
	printerr("lockstep: %d failure(s) after %d actions" % [_failures.size(), actions])
	for f in _failures:
		printerr("  " + f)
	return false

func _first_diff(a: String, b: String) -> String:
	var la := a.split("\n")
	var lb := b.split("\n")
	for i in maxi(la.size(), lb.size()):
		var x: String = la[i] if i < la.size() else "<eof>"
		var y: String = lb[i] if i < lb.size() else "<eof>"
		if x != y:
			return "    host:   %s\n    client: %s" % [x, y]
	return "    (digests differ only in trailing bytes)"
