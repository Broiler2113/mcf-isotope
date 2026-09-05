class_name CombatLog
extends RefCounted

## Очередь событий для текстового лога и анимации кубиков (§2.2, §6).

signal line_added(text: String)
signal dice_rolled(event: Dictionary)

var lines: Array[String] = []

func add(text: String) -> void:
	lines.append(text)
	line_added.emit(text)

func add_dice(event: Dictionary) -> void:
	dice_rolled.emit(event)

func publish_result(result: ActionResult) -> void:
	for line in result.log_lines:
		add(line)
	for ev in result.dice_events:
		add_dice(ev)
