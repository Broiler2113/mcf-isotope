extends SceneTree

## «Play vs latest» (панель RL → train.py play) обязан сажать ОБУЧЕННЫЙ ИИ, а не скрипт.
##
## Игрок заметил, что кнопка «на деле не даёт играть против последней версии»: игра
## открывалась в меню, одиночное лобби по умолчанию сажало скриптовый ИИ, и сервер политики
## простаивал, пока слот не переключали руками. Теперь, если игра запущена с моделью
## (MCF_RL_POLICY), соперник по умолчанию — AI - Learned, а лобби называет модель.
## Без модели ничего не меняется: соперник по умолчанию — прежний скриптовый ИИ.

const LABEL := "town-8 · update 3867 · step 5,939,822"

var fails: PackedStringArray = []
var _lobby: Node = null
var _phase := 0

func _initialize() -> void:
	OS.set_environment(LearnedController.ENV_VAR, "127.0.0.1:7791")
	OS.set_environment(LearnedController.ENV_LABEL, LABEL)
	_open()

func _open() -> void:
	_lobby = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(_lobby)

## Лобби получает _ready только в дереве, то есть к следующему кадру.
func _process(_delta: float) -> bool:
	var slot: Roster.Slot = _lobby.roster.slots[1]
	if _phase == 0:
		ck(slot.kind == Roster.SlotKind.AI, "the opponent seat is an AI")
		ck(slot.ai_difficulty == AIController.Difficulty.LEARNED,
				"with a model served, the opponent is AI - Learned (got %d)" % slot.ai_difficulty)
		ck(str(_lobby._status.text).find(LABEL) >= 0,
				"the lobby names the model (%s)" % _lobby._status.text)
		_lobby.free()
		OS.unset_environment(LearnedController.ENV_VAR)
		OS.unset_environment(LearnedController.ENV_LABEL)
		_phase = 1
		_open()
		return false
	ck(slot.ai_difficulty == Roster.Slot.new().ai_difficulty,
			"without a model the default opponent is unchanged (got %d)" % slot.ai_difficulty)
	_lobby.free()
	if fails.is_empty():
		print("play vs learned: a served model takes the opponent seat and is named")
		quit(0)
	else:
		printerr("play vs learned: %d failure(s)" % fails.size())
		for f in fails:
			printerr("  " + f)
		quit(1)
	return true

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)
