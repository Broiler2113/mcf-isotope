extends SceneTree

## Проверка, что записанный обучением .mcfr играется ReplayPlayer'ом от начала до конца
## без единого отказа: каждое намерение с его бросками принимается резолвером. Это
## тот же путь, каким повтор открывает боевой экран (10.3).
##   godot --headless --script res://rl/tools/check_replay.gd -- /abs/path.mcfr

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: -- <file.mcfr>")
		quit(2)
		return
	var data := ReplayFile.read(args[0])
	if data.is_empty():
		printerr("replay: cannot read %s" % args[0])
		quit(1)
		return
	var player := ReplayPlayer.new(data)
	var n := 0
	var refused := 0
	while player.has_next():
		var res := player.play_next()
		n += 1
		if res != null and not res.ok:
			refused += 1
	print("replay: %d steps, %d refused, meta %s" % [n, refused, JSON.stringify(data.get("meta", {}))])
	quit(0 if refused == 0 and n == player.step_count() else 1)
