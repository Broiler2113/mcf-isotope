extends SceneTree
## Run recorded requests through the actual Dictionary -> extension boundary.
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3 or not ClassDB.class_exists("MCFPolicy"):
		quit(2)
		return
	var policy: RefCounted = ClassDB.instantiate("MCFPolicy")
	var loaded: Dictionary = policy.call("load_model", args[0])
	if loaded.has("error"):
		printerr(loaded)
		quit(1)
		return
	var input := FileAccess.open(args[1], FileAccess.READ)
	var output := FileAccess.open(args[2], FileAccess.WRITE)
	while input.get_position() < input.get_length():
		var request: Dictionary = JSON.parse_string(input.get_line())
		var start := Time.get_ticks_usec()
		var reply: Dictionary = policy.call("infer", request)
		reply["total_ms"] = float(Time.get_ticks_usec() - start) / 1000.0
		output.store_line(JSON.stringify(reply))
	input.close()
	output.close()
	quit(0)
