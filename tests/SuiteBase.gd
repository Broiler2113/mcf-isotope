extends SceneTree

## The frame every system suite stands on (tests/<system>/run_*.gd): ck() records a failed
## check, run() is the suite (it may await), and the process exits 1 when anything failed.
## Each suite name is its path, so a failure says which file to open.

var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)
		printerr("FAIL " + what)

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	await run()
	var suite := (get_script() as Script).resource_path.trim_prefix("res://")
	print("%s: %d failure(s)" % [suite, fails.size()])
	quit(1 if not fails.is_empty() else 0)

func run() -> void:
	pass
