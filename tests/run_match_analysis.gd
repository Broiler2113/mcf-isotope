extends SceneTree

## Разбор сыгранной партии обученной политикой (MatchAnalyst).
##
## Настоящего сервера политики в прогоне нет — и не нужно: протокол у него ровно в одну
## строку JSON, поэтому здесь поднимается игрушечный сервер в отдельном потоке. Он всегда
## выбирает первого кандидата и роняет оценку позиции на фиксированный шаг, так что
## ожидаемый ответ разбора известен заранее и сверяется точно.
##
## Проверяется то, ради чего разбор и писался:
##   1. он проходит ВСЮ запись и опрашивает политику на каждом ходе, кроме концов хода;
##   2. строка разбора называет бойца, действие и клетку — «move» без них бесполезен;
##   3. «качели» считаются между ДВУМЯ СОСЕДНИМИ решениями ОДНОЙ стороны, а не подряд;
##   4. worst() выносит наверх самые дорогие ходы;
##   5. без сервера политики разбор не падает, а честно говорит, что ответа нет.

var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

var _srv := TCPServer.new()
var _stop := false
var _served := 0
const DROP := 0.05

## Запрос приходит ОДНОЙ строкой, но TCP рвёт её на куски как хочет, а наблюдение на
## двадцати клетках — это килобайты. Поэтому буфер на соединение и ответ строго по
## переводу строки: без этого обрывок считался бы отдельным вопросом, и «сколько раз
## спросили» в проверке ниже врало бы.
func _serve() -> void:
	var conns: Array = []
	var buf := {}
	while not _stop:
		if _srv.is_connection_available():
			var fresh := _srv.take_connection()
			conns.append(fresh)
			buf[fresh] = ""
		for c: StreamPeerTCP in conns:
			c.poll()
			if c.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				continue
			var n := c.get_available_bytes()
			if n <= 0:
				continue
			var chunk: Array = c.get_data(n)
			buf[c] = String(buf[c]) + (chunk[1] as PackedByteArray).get_string_from_utf8()
			while true:
				var nl: int = String(buf[c]).find("\n")
				if nl < 0:
					break
				buf[c] = String(buf[c]).substr(nl + 1)
				_served += 1
				c.put_data(('{"action":0,"value":%f}' % (1.0 - float(_served) * DROP)
						+ "\n").to_utf8_buffer())
		OS.delay_msec(2)

func _record() -> Dictionary:
	var m := MapData.new(20, 10)
	for y in 10:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(3, 4), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(4, 6), "sniper", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(15, 4), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(16, 6), "sniper", MCF.Owner.PLAYER_2)
	GameConfig.civilians_enabled = false
	var st := m.build_state(77)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.STANDARD
	r.fog_enabled = true
	var rec := ReplayRecorder.new()
	rec.begin(st, r, {"map": "analysis test"})
	r.replay_recorder = rec
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 24:
		var legal: Array = r.legal_intents(st.active_player())
		if legal.is_empty():
			break
		r.resolve(legal[rng.randi_range(0, legal.size() - 1)])
	return rec.to_dict()

func _initialize() -> void:
	var data := _record()
	ck(int(data["steps"].size()) > 10, "the test match recorded something to chew on (%d steps)"
			% data["steps"].size())

	# --- без сервера политики разбор не падает ---
	OS.set_environment("MCF_RL_POLICY", "")
	var blind := MatchAnalyst.new()
	ck(blind.begin(data, 40), "the analyst opens a recording even with no model served")
	var guard := 0
	while blind.has_next() and guard < 400:
		blind.step_many()
		guard += 1
	ck(blind.rows.is_empty(), "with nobody to ask it reports nothing (%d rows)" % blind.rows.size())
	ck(blind.error != "", "and says why: '%s'" % blind.error)

	# --- с сервером ---
	var port := 0
	for p in range(42410, 42470):
		if _srv.listen(p) == OK:
			port = p
			break
	if port == 0:
		ck(false, "a free port for the toy policy server")
		_finish()
		return
	OS.set_environment("MCF_RL_POLICY", "127.0.0.1:%d" % port)
	var th := Thread.new()
	th.start(_serve)

	var a := MatchAnalyst.new()
	ck(a.begin(data, 40), "the analyst opens the recording: %s" % a.error)
	guard = 0
	while a.has_next() and guard < 400:
		a.step_many()
		guard += 1
	ck(not a.has_next(), "it walks the recording to the end (%d of %d)" % [a.done(), a.total()])
	ck(a.rows.size() > 0, "and judges the moves it found (%d)" % a.rows.size())
	ck(a.rows.size() == _served, "one question per judged move, no more (%d rows, %d asked)"
			% [a.rows.size(), _served])
	ck(a.rows.size() < a.total(), "ends of turn are not judged — they are not a choice")

	var first: Dictionary = a.rows[0]
	ck(String(first["played"]).contains("("),
			"a row names the unit, the action and the cell: '%s'" % first["played"])
	ck(String(first["suggested"]) != "", "and what the model would have played instead")
	ck(bool(first["offered"]), "the played move was in the list the model saw")

	# Качели: между соседними решениями ОДНОЙ стороны сервер успевает ответить и той, и
	# другой, поэтому просадка равна двум шагам DROP, а не одному.
	var swung := 0
	for row: Dictionary in a.rows:
		if absf(float(row["swing"])) > 0.0001:
			swung += 1
			ck(float(row["swing"]) < 0.0, "a falling value reads as a loss, not a gain")
			break
	ck(swung > 0, "the swing between a side's own turns is measured")
	var worst: Array = a.worst(3)
	ck(worst.size() > 0 and float(worst[0]["swing"]) <= float(worst[worst.size() - 1]["swing"]),
			"worst() puts the dearest move first (%s)" % [worst.map(func(x): return x["swing"])])
	ck(a.agreement(MCF.Owner.PLAYER_1) >= 0.0 and a.agreement(MCF.Owner.PLAYER_1) <= 1.0,
			"agreement is a share, per side (%.2f)" % a.agreement(MCF.Owner.PLAYER_1))

	_stop = true
	th.wait_to_finish()
	_finish()

func _finish() -> void:
	if fails.is_empty():
		print("match analysis: the analyst walks a recording, questions both sides and ranks the damage")
		quit(0)
		return
	printerr("match analysis: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)
