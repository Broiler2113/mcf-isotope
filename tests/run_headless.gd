extends SceneTree

## Регрессионный прогон: партия ИИ против ИИ на фиксированной карте с фиксированным
## зерном, весь её след — в текстовый файл.
##
## Чего этот прогон НЕ утверждает: что игра играется правильно. Он утверждает
## ровно две вещи — что партия доигрывается без падений и что её след не изменился
## незаметно. Правила в этих майлстоунах меняются намеренно, поэтому эталон
## пересобирается осознанно (`-- --update`), а причина записывается в коммит.

const TS = preload("res://tests/TestSupport.gd")

const ROUNDS := 6
## Предохранитель от зацикливания: настоящая партия укладывается на порядок меньше.
const MAX_ACTIONS := 20000
const BASELINE := "res://tests/baseline/headless_trace.txt"
const OUT := "user://headless_trace.txt"

var _pending: Intent = null

func _initialize() -> void:
	var update := "--update" in OS.get_cmdline_user_args()
	var trace := _run()
	var ok := _compare(trace, update)
	quit(0 if ok else 1)

func _run() -> String:
	var state := TS.build_state()
	var resolver := GameActionResolver.new(state)
	resolver.fog_enabled = false  # прогону не нужен туман: он ничего не решает в исходе
	var lines: PackedStringArray = []
	lines.append("map %dx%d seed %d" % [state.grid.width, state.grid.height, TS.SEED])
	lines.append("initiative %s" % state.turns.order_names())

	var brains := {}
	for side in [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]:
		var ai := AIController.new(side, AIController.Difficulty.NORMAL)
		ai.intent_ready.connect(_on_intent)
		brains[side] = ai

	# Открывающий слот мирных играется до первого хода армий — так же, как это
	# делает боевой экран (§14.1). Без этого первый ход шёл бы не с той доски.
	resolver.play_civilian_slots()

	var actions := 0
	while state.turns.round_number <= ROUNDS and actions < MAX_ACTIONS:
		var side: int = state.active_player()
		var ai: AIController = brains.get(side, null)
		if ai == null:
			# Слот без мозгов (нейтралы играются внутри end_turn) — просто закрываем.
			resolver.resolve(EndTurnIntent.new())
			continue
		_pending = null
		ai.begin_turn(state)
		if _pending == null:
			resolver.resolve(EndTurnIntent.new())
			continue
		var intent := _pending
		actions += 1
		lines.append("[r%d s%d p%d] %s" % [state.turns.round_number,
				state.turns.active_index, side, TS.intent_line(intent)])
		var res := resolver.resolve(intent)
		lines.append_array(TS.result_lines(res))
		if not res.ok:
			ai.notify_intent_denied(state)

	if actions >= MAX_ACTIONS:
		lines.append("!! action cap reached — the AI never ended its turn")
	lines.append("actions %d" % actions)
	lines.append("--- digest ---")
	lines.append(TS.digest(state))
	return "\n".join(lines) + "\n"

func _on_intent(intent: Intent) -> void:
	_pending = intent

func _compare(trace: String, update: bool) -> bool:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(trace)
	f.close()
	if update or not FileAccess.file_exists(BASELINE):
		DirAccess.make_dir_recursive_absolute(
				ProjectSettings.globalize_path("res://tests/baseline"))
		var b := FileAccess.open(BASELINE, FileAccess.WRITE)
		b.store_string(trace)
		b.close()
		print("headless: baseline written (%d lines)" % trace.split("\n").size())
		return true
	var want := FileAccess.get_file_as_string(BASELINE)
	if want == trace:
		print("headless: trace matches baseline (%d lines)" % trace.split("\n").size())
		return true
	printerr("headless: TRACE CHANGED vs %s" % BASELINE)
	printerr(_first_diff(want, trace))
	printerr("  full run written to: %s" % ProjectSettings.globalize_path(OUT))
	return false

## Первое расхождение с контекстом — читать целиком двадцатитысячестрочный файл
## глазами незачем.
func _first_diff(a: String, b: String) -> String:
	var la := a.split("\n")
	var lb := b.split("\n")
	for i in maxi(la.size(), lb.size()):
		var x: String = la[i] if i < la.size() else "<eof>"
		var y: String = lb[i] if i < lb.size() else "<eof>"
		if x != y:
			return "  line %d\n    baseline: %s\n    now:      %s" % [i + 1, x, y]
	return "  (files differ only in trailing bytes)"
