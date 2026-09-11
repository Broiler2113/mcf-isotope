extends SceneTree

## Общая обвязка временного сетевого прогона batch 12: шаги «жди условие → действуй».

var fails: PackedStringArray = []
var _steps: Array = []
var _step := 0
var _t := 0.0
var _step_t := 0.0
const STEP_TIMEOUT := 25.0
var tag := "?"
var _done := false

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)
		printerr("[%s] FAIL: %s" % [tag, what])

func step(name: String, cond: Callable, act: Callable = Callable()) -> void:
	_steps.append({"n": name, "c": cond, "a": act})

func scene_is(cls: String) -> bool:
	var cs := current_scene
	if cs == null or cs.get_script() == null:
		return false
	return (cs.get_script() as Script).resource_path.ends_with(cls)

func session() -> NetworkSession:
	return root.get_node_or_null(NetworkSession.NODE_NAME) as NetworkSession

## Кубик на экране боя: нажать «Roll», если он ждёт нас; вернуть текст подсказки.
func poke_dice() -> String:
	if not scene_is("Main.gd"):
		return ""
	var dice = current_scene._dice
	if dice == null or not dice.visible:
		return ""
	if dice._roll_btn.visible:
		dice._roll_btn.pressed.emit()
	return dice._prompt.text if dice._prompt.visible else ""

func _process(delta: float) -> bool:
	if _done:
		return true
	_t += delta
	_step_t += delta
	if _step >= _steps.size():
		_finish()
		return true
	_tick()
	return false

func _tick() -> void:
	var s: Dictionary = _steps[_step]
	var ok: bool = (s["c"] as Callable).call()
	if ok:
		print("[%s] step %d ok: %s (t=%.1f)" % [tag, _step, s["n"], _t])
		if (s["a"] as Callable).is_valid():
			(s["a"] as Callable).call()
		_step += 1
		_step_t = 0.0
	elif _step_t > STEP_TIMEOUT:
		ck(false, "timeout on step %d: %s" % [_step, s["n"]])
		_finish()

func _finish() -> void:
	_done = true
	var ses := session()
	if ses != null:
		ses.close()
	if fails.is_empty():
		print("[%s] net smoke: all hold" % tag)
		quit(0)
	else:
		printerr("[%s] net smoke: %d failure(s)" % [tag, fails.size()])
		for f in fails:
			printerr("  " + f)
		quit(1)

var _net_host := false
var _net_started := false

func start_net(host: bool) -> void:
	_net_host = host
	step("net started", func() -> bool:
		if not _net_started:
			_net_started = true
			_start_net_now(_net_host)
		return true)

func _start_net_now(host: bool) -> void:
	var ses := NetworkSession.new()
	ses.name = NetworkSession.NODE_NAME
	root.add_child(ses)
	var err: int
	if host:
		err = ses.start_host(NetworkSession.DEFAULT_PORT)
	else:
		err = ses.start_client("127.0.0.1", NetworkSession.DEFAULT_PORT)
	ck(err == OK, "session started (%d)" % err)
	GameConfig.roster = null
	GameConfig.placement_mode = GameConfig.Placement.ASYMMETRIC
	GameConfig.budget = GameConfig.DEFAULT_BUDGET
	GameConfig.live_placement_visible = true
	NetHandoff.session = ses
	NetHandoff.is_host = host
	if host:
		change_scene_to_file("res://scenes/Lobby.tscn")
	else:
		# Гость уезжает в лобби по связи, как в меню.
		ses.peer_ready.connect(func(_h: bool) -> void:
			change_scene_to_file("res://scenes/Lobby.tscn"))
