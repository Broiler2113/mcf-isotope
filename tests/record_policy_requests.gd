extends SceneTree
## Real resolver/ObsEncoder snapshots for the Python/native tensor parity harness.
const Obs = preload("res://rl/ObsEncoder.gd")
const TS = preload("res://tests/TestSupport.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		quit(2)
		return
	var out := FileAccess.open(args[0], FileAccess.WRITE)
	if out == null:
		quit(2)
		return
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	for size: Vector2i in [Vector2i(34, 26), Vector2i(74, 62), Vector2i(160, 100)]:
		var map := MapData.blank_arena(size.x, size.y)
		var count := 120 if size.x >= 100 else 12
		for side in 2:
			for n in count:
				var x := 3 + n % 15 if side == 0 else size.x - 4 - n % 15
				var y := 3 + n / 15 if side == 0 else size.y - 4 - n / 15
				map.set_spawn(Vector2i(x, y), "light_infantry", side)
		var state := map.build_state(700 + size.x)
		var resolver := GameActionResolver.new(state)
		resolver.fog_mode = MCF.Fog.OFF
		for step in 3:
			_record(out, resolver, step)
		var varied := TS.build_state()
		var varied_resolver := GameActionResolver.new(varied)
		varied_resolver.fog_mode = MCF.Fog.STANDARD
		_record(out, varied_resolver, 0)
	out.close()
	quit(0)

func _record(out: FileAccess, resolver: GameActionResolver, step: int) -> void:
	var side := resolver.state.active_player()
	var tac := Obs.tactics(resolver, side)
	var legal := resolver.legal_intents(side)
	var desc: Array = []
	for intent: Intent in legal:
		desc.append(Obs.describe(resolver.state, intent, tac))
	out.store_line(JSON.stringify({"obs": Obs.encode(resolver, side, 10, tac), "legal": desc}))
	if legal.size() > 1:
		resolver.resolve(legal[mini(1 + step, legal.size() - 1)])
