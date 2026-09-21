extends SceneTree

## Слот «AI - Learned» (RL v1, §7/§12) в двух режимах.
##
## 1. БЕЗ МОДЕЛИ. MCF_RL_POLICY не задана — контроллер обязан молча (для партии) уступить
##    место AIController HARD, один раз сообщив причину сигналом fallback_engaged, и
##    дальше водить сторону так, что партия доигрывается.
## 2. С МОДЕЛЬЮ (если MCF_RL_POLICY задана и сервер отвечает). Каждое намерение приходит
##    от политики, резолвер его принимает, запасной мозг НЕ включается. В регрессии этот
##    режим пропускается: сервера политики там нет.

const TS = preload("res://tests/TestSupport.gd")
const ROUNDS := 3
const MAX_ACTIONS := 6000

var fails: PackedStringArray = []
var _pending: Intent = null
var _fallbacks: Array = []

func _initialize() -> void:
	var has_server := OS.get_environment(LearnedController.ENV_VAR) != ""
	if has_server:
		_run_live()
	else:
		_run_fallback()
	if fails.is_empty():
		print("learned controller: %s" % ("policy drives the seat, no fallback" if has_server
				else "no model → AI - Hard takes the seat with a visible reason"))
		quit(0)
		return
	printerr("learned controller: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

func _play(learned: LearnedController) -> Dictionary:
	var state := TS.build_state()
	var r := GameActionResolver.new(state)
	r.fog_mode = MCF.Fog.STANDARD
	r.play_civilian_slots()
	var foe := AIController.new(MCF.Owner.PLAYER_1, AIController.Difficulty.NORMAL)
	foe.intent_ready.connect(_on_intent)
	learned.intent_ready.connect(_on_intent)
	learned.fallback_engaged.connect(func(reason: String) -> void: _fallbacks.append(reason))
	var brains := {MCF.Owner.PLAYER_1: foe, MCF.Owner.PLAYER_2: learned}
	var actions := 0
	var learned_actions := 0
	var refused := 0
	while state.turns.round_number <= ROUNDS and actions < MAX_ACTIONS:
		var side: int = state.active_player()
		_pending = null
		brains[side].begin_turn(state)
		var intent: Intent = _pending if _pending != null else EndTurnIntent.new()
		var res := r.resolve(intent)
		actions += 1
		if side == MCF.Owner.PLAYER_2:
			learned_actions += 1
			if not res.ok:
				refused += 1
		if not res.ok:
			brains[side].notify_intent_denied(state)
	return {"actions": actions, "learned": learned_actions, "refused": refused,
			"rounds": state.turns.round_number}

func _run_fallback() -> void:
	OS.set_environment(LearnedController.ENV_VAR, "")
	var learned := LearnedController.new(MCF.Owner.PLAYER_2)
	var out := _play(learned)
	ck(_fallbacks.size() == 1, "fallback engages exactly once (got %d)" % _fallbacks.size())
	ck(not _fallbacks.is_empty() and str(_fallbacks[0]).contains(LearnedController.ENV_VAR),
			"the reason names the missing variable")
	ck(int(out["rounds"]) > ROUNDS, "the match keeps going under the fallback brain")
	ck(int(out["learned"]) > 3, "the fallback brain actually acts (%d intents)" % out["learned"])
	ck(int(out["refused"]) == 0, "fallback intents are all accepted (%d refused)" % out["refused"])

func _run_live() -> void:
	var learned := LearnedController.new(MCF.Owner.PLAYER_2)
	var out := _play(learned)
	ck(_fallbacks.is_empty(), "no fallback while the policy server answers: %s" % str(_fallbacks))
	ck(int(out["refused"]) == 0, "every policy intent is accepted (%d refused)" % out["refused"])
	ck(int(out["learned"]) > 3, "the policy acts (%d intents)" % out["learned"])
	ck(int(out["rounds"]) > ROUNDS, "the match completes %d rounds" % ROUNDS)

func _on_intent(intent: Intent) -> void:
	_pending = intent
