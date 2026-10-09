extends SceneTree
## Convert a replay into observations BEFORE actions. Never expose future rolls.
const Obs = preload("res://rl/ObsEncoder.gd")
const Budget = preload("res://rl/IntentBudget.gd")
const Memory = preload("res://rl/EnemyMemory.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		_fail("usage: -- replay.mcfr output.jsonl [round_cap]")
		return
	var f := FileAccess.open_compressed(args[0], FileAccess.READ, ReplayFile.COMPRESSION)
	if f == null or f.get_length() > 128 * 1024 * 1024:
		_fail("unreadable or oversized replay")
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not data is Dictionary or data.get("kind", "") != "replay" or int(data.get("schema", 0)) != 1:
		_fail("unsupported replay format")
		return
	if data.get("meta", {}).get("rl", false):
		_fail("training replays are not human demonstrations")
		return
	var player := ReplayPlayer.new(data)
	player.seek(0)
	if data.get("start", {}).is_empty() or player.state == null or player.step_count() == 0 or player.step_count() > 100000:
		_fail("missing board, empty replay, or too many actions")
		return
	if maxi(player.state.grid.width, player.state.grid.height) > 256:
		_fail("board exceeds 256 tiles")
		return
	var output := FileAccess.open(args[1], FileAccess.WRITE)
	if output == null:
		_fail("cannot write dataset")
		return
	var memories := {}
	var seen := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 61471
	# Uniformly sample a long match; still replay and validate EVERY action.
	var estimated_row_bytes := player.state.grid.width * player.state.grid.height * 64 + 512 * 256
	var sample_budget := mini(2048, maxi(16, 96 * 1024 * 1024 / estimated_row_bytes))
	var stride := maxi(1, ceili(float(player.step_count()) / float(sample_budget)))
	var count := 0
	var skipped := 0
	var cap := int(args[2]) if args.size() > 2 else 40
	while player.has_next():
		var state := player.state
		var r := player.resolver
		var side := state.active_player()
		var played := IntentCodec.decode(player.steps()[player.index].get("i", {}))
		if played == null:
			_fail("unreadable action at %d" % player.index)
			return
		var sample := {}
		var slot := state.roster.slot(side)
		if MCF.is_player(side) and slot != null and slot.kind != Roster.SlotKind.AI:
			seen[side] = int(seen.get(side, 0)) + 1
			if not memories.has(side):
				memories[side] = Memory.new()
			memories[side].observe(r, side)
		if MCF.is_player(side) and seen.has(side) and (int(seen[side]) - 1) % stride == 0 and slot.kind != Roster.SlotKind.AI:
			var actors := Budget.actor_subset(r, side, 16, rng)
			# Keep the demonstrated actor in the shortlist. Match against genuine
			# legal intents before reinserting a target trimmed by the 512 cap.
			if not actors.is_empty():
				actors[played.actor_id] = true
				actors["v%d" % played.actor_id] = true
			var all: Array = Budget.drop_blind_shots(r.legal_intents(side, actors), r, side)
			var key := JSON.stringify(IntentCodec.encode(played))
			var target: Intent = null
			for intent: Intent in all:
				if JSON.stringify(IntentCodec.encode(intent)) == key:
					target = intent
					break
			if target != null:
				var legal: Array = Budget.cap(all, 512, rng, r, side)
				var index := legal.find(target)
				if index < 0:
					legal[-1] = target
					index = legal.size() - 1
				var tac := Obs.tactics(r, side, memories[side])
				var desc: Array = []
				for intent: Intent in legal:
					desc.append(Obs.describe(state, intent, tac))
				sample = {"obs": Obs.encode(r, side, cap, tac), "legal": desc,
						"action": index, "side": side, "round": state.turns.round_number}
		var before := state.dice.fallback_rolls
		var result := player.play_next()
		if result == null or not result.ok or state.dice.fallback_rolls != before or state.dice.scripted_remaining() != 0:
			_fail("replay diverged from current rules at action %d" % player.index)
			return
		if not sample.is_empty():
			output.store_line(JSON.stringify(sample))
			if output.get_position() > 128 * 1024 * 1024:
				_fail("extracted examples exceed 128 MB; split the replay before import")
				return
			count += 1
		else:
			skipped += 1
	output.close()
	print(JSON.stringify({"samples": count, "skipped": skipped, "actions": player.step_count()}))
	quit(0 if count > 0 else 1)

func _fail(message: String) -> void:
	printerr(message)
	quit(1)
