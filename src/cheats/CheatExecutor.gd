class_name CheatExecutor
extends RefCounted

## Only canonical, already-authorized operations enter here. Network authority and
## local console check live rights; replay deliberately ignores later revocations.
static func apply(r: GameActionResolver, intent: CheatIntent) -> ActionResult:
	var checked := CheatCommands.validate_payload(intent.op, intent.args, r.state, intent.issuer)
	if checked.has("error"): return ActionResult.fail(checked.error)
	if checked.access not in ["play", "host_play"]: return ActionResult.fail("This command is not a gameplay intent.")
	intent.args = checked.args
	var a := intent.args
	var state := r.state
	var out: ActionResult
	if intent.op == "spawn_unit" or intent.op.begins_with("unit_"): out = CheatUnits.apply(r, intent)
	elif intent.op == "spawn_vehicle" or intent.op.begins_with("vehicle_"): out = CheatVehicles.apply(r, intent)
	elif intent.op.begins_with("world_"): out = CheatWorld.apply(r, intent)
	elif intent.op.begins_with("event_"): out = CheatEvents.apply(r, intent)
	else:
		out = CheatUnits.result(intent.op.replace("_", " ") + " applied.")
		match intent.op:
			"vision_reveal", "vision_reset", "vision_mines":
				var sides: Array[int] = []
				sides.assign(state.roster.player_ids() if a.owner == -1 else [int(a.owner)])
				for side: int in sides:
					if intent.op == "vision_reveal": state.cheat_vision[side] = true
					elif intent.op == "vision_reset": state.cheat_vision.erase(side)
					elif a.enabled: state.cheat_mines[side] = true
					else: state.cheat_mines.erase(side)
				UnitInstance.vision_epoch += 1
			"turn_end":
				out = r._resolve_end_turn(EndTurnIntent.new(state.active_player()))
				out.cheat_output = "Ended the active turn using normal turn and round rules."
			"turn_refill":
				var count := 0
				for unit: UnitInstance in state.all_units():
					if unit.is_alive() and (a.owner == -1 or unit.owner == a.owner): CheatUnits.refill(unit); count += 1
				out.cheat_output = "Refilled %d living units." % count
			"ai_pause", "ai_resume", "ai_step":
				if not state.roster.is_ai(a.owner): return ActionResult.fail("Choose an AI player, not a human.")
				if intent.op == "ai_step" and state.active_player() != a.owner: return ActionResult.fail("Step requires that AI player's active turn.")
				if intent.op == "ai_resume": state.cheat_ai_paused.erase(a.owner)
				else: state.cheat_ai_paused[a.owner] = true
				out.cheat_output = "%s: %s." % [state.roster.name_of(a.owner), "resumed" if intent.op == "ai_resume" else "one decision, then paused" if intent.op == "ai_step" else "paused after the current action"]
			"ai_speed":
				out.cheat_output = "AI speed: %s → %s." % [GameConfig.ai_speed, a.speed]
				GameConfig.ai_speed = a.speed
			"ai_personality":
				var slot := state.roster.slot(a.owner)
				if not state.roster.is_ai(a.owner): return ActionResult.fail("Personality requires an AI slot.")
				var old := slot.ai_label()
				slot.ai_difficulty = 3 if a.personality == "learned" else 2
				slot.ai_style = maxi(0, ["tactician", "aggressor", "fortifier"].find(a.personality))
				out.cheat_output = "%s: %s → %s." % [slot.display_name, old, slot.ai_label()]
			"match_score":
				if not r.mode.is_capture(): return ActionResult.fail("Scores require Capture & Hold mode.")
				var key := MatchMode.team_key(state.roster, a.owner)
				out.cheat_output = "%s score: %d → %d." % [r.team_label(key), r.mode.scores.get(key, 0), a.points]
				r.mode.scores[key] = a.points
			"match_waves":
				if not r.mode.is_holdout(): return ActionResult.fail("Wave count requires Holdout mode.")
				out.cheat_output = "Total waves: %d → %d (0 means endless)." % [r.mode.waves_total, a.waves]
				r.mode.waves_total = a.waves
			_: return ActionResult.fail("Unknown gameplay operation.")
	if out.ok:
		state.cheat_sequence += 1
		# Details stay in the issuer's console. Shared log identifies the operation only.
		out.log("[CHEAT] %s: %s" % [state.roster.name_of(intent.issuer), intent.op.replace("_", " ")])
	return out
