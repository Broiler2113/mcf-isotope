extends Node
## Diagnostic scene selected by --native-policy-smoke in release executables.
func _ready() -> void:
	if not ClassDB.class_exists("MCFPolicy") or LearnedController._load_embedded() == null:
		printerr("export smoke: native class or bundled model missing")
		get_tree().quit(1)
		return
	GameConfig.civilians_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	var map := MapData.blank_arena(20, 14)
	map.set_spawn(Vector2i(3, 4), "light_infantry", 0)
	map.set_spawn(Vector2i(15, 9), "light_infantry", 1)
	var state := map.build_state(93)
	var resolver := GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.OFF
	var controller := LearnedController.new(state.active_player())
	var picked := controller._decide(state)
	if picked.is_empty() or not resolver.resolve(picked["intent"]).ok or controller._fallback != null:
		printerr("export smoke: invalid embedded decision: " + controller._last_error)
		get_tree().quit(1)
		return
	print("export smoke: native policy loaded from pack; accepted legal action; " + LearnedController.model_label())
	get_tree().quit(0)
