extends SceneTree

## Чьими глазами смотрит экран боя (Main._viewing_side). Против ИИ во время его хода экран
## показывал обзор самого ИИ — все его бойцы были видны сквозь туман. Теперь смотрит
## человек; в горячем кресле (двое людей) взгляд по-прежнему переходит к тому, чей ход.

var fails: PackedStringArray = []
var _main: Node = null
var _case := 0
var _frames := 0
var _ai_turns_seen := 0

func _initialize() -> void:
	_open(true)

func _open(vs_ai: bool) -> void:
	var m := MapData.new(20, 10)
	for y in 10:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for x in 10:
		m.set_cell(Vector2i(10, x), MCF.FLOOR_NORMAL, 2.0, false, "")   # стена посередине
	m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(17, 5), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.STANDARD
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(vs_ai, AIController.Difficulty.EASY)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	_frames = 0

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _process(_d: float) -> bool:
	_frames += 1
	var st: GameState = _main.state
	if st == null or _frames < 3:
		return false
	var active := st.active_player()
	if _case == 0:
		# Против ИИ: во время хода ИИ смотрит человек (сторона 0), и боец ИИ за стеной не
		# попадает в то, что рисуется.
		if active == 1:
			_ai_turns_seen += 1
			ck(_main._viewing_side() == 0, "during the AI's turn the screen shows side %d, not the human's" % _main._viewing_side())
			var ai_unit: UnitInstance = st.living_units_of(1)[0]
			ck(not _main.resolver.team_visible_coords(_main._viewing_side()).has(ai_unit.coord),
					"the AI's rifleman behind the wall is drawn during its own turn")
		elif not _main._animating and _frames % 5 == 0:
			_main._on_intent_ready(EndTurnIntent.new())
		if _ai_turns_seen >= 3 or _frames > 3000:
			ck(_ai_turns_seen > 0, "the AI never got a turn")
			_main.queue_free()
			_case = 1
			_open(false)
		return false
	# Горячее кресло: двое людей — взгляд у того, чей ход.
	ck(_main._viewing_side() == active, "hot-seat: the screen shows side %d on side %d's turn" % [_main._viewing_side(), active])
	if _frames % 5 == 0 and not _main._animating:
		_main._on_intent_ready(EndTurnIntent.new())
	if _frames > 60:
		_main.queue_free()
		if fails.is_empty():
			print("fog viewer: against the AI the human's view stays on screen; hot-seat follows the turn")
			quit(0)
		else:
			printerr("fog viewer: %d failure(s)" % fails.size())
			for f in fails.slice(0, 10):
				printerr("  " + f)
			quit(1)
		return true
	return false
