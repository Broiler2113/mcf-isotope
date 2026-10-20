extends "res://tests/SuiteBase.gd"
## Dice: impossible rolls never wait, Enter rolls, autoroll.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_impossible_rolls()
	await _enter_rolls()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	await _autoroll()

## A step whose every die needs 7+ never waits for a Roll press.
func _impossible_rolls() -> void:
	var main: Node = load("res://tests/fixtures/GroundBackgroundOnly.gd").new()
	var ev := {"kind": "check", "roll": 3, "need": 7, "ok": false, "roller": 0}
	var steps: Array = main._dice_steps(ev)
	ck(steps.size() == 1 and steps[0].get("auto", false) and not steps[0]["manual"], "a 7+ ck is automatic")
	ck(str(steps[0]["prompt"]).contains("7+"), "and the prompt says why")
	var ok: Array = main._dice_steps({"kind": "check", "roll": 3, "need": 6, "ok": false, "roller": 0})
	ck(not ok[0].get("auto", false), "a 6+ roll stays a normal roll")
	main.free()

func _enter_rolls() -> void:
	var roller: Node = load("res://scenes/DiceRoller.gd").new()
	root.add_child(roller)
	await process_frame
	var pressed := [false]
	roller.play([{"value": 4, "good": true, "tag": "Hit 3+"}], true)
	roller.rolled.connect(func() -> void: pressed[0] = true)
	await process_frame
	ck(roller._roll_btn.visible and roller._roll_btn.text.contains("Enter"), "the Roll button names its key")
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	Input.parse_input_event(key)
	for i in 3: await process_frame
	ck(pressed[0], "Enter rolls the dice")
	roller.queue_free()

## #11: autoroll starts our own roll without a press.
func _autoroll() -> void:
	var ui := root.get_node_or_null("/root/Ui")
	ui.autoroll_dice = true
	var dice: Node = load("res://scenes/DiceRoller.gd").new()
	root.add_child(dice)
	var got := [false]
	dice.rolled.connect(func() -> void: got[0] = true)
	dice.play([{"value": 4, "good": true, "tag": "Pen 4+"}], true, "roll", 50.0)
	for i in 5: await process_frame
	ck(got[0] and not dice._roll_btn.visible, "autoroll: the roll starts on its own, no Roll button")
	ui.autoroll_dice = false
	dice.queue_free()
