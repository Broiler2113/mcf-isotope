class_name CheatConsole
extends CanvasLayer

const SteamChrome = preload("res://src/ui/SteamChrome.gd")

var main: Node
var prompt: Label
var output: RichTextLabel
var input: LineEdit
var hints: ItemList
var history: Array[String] = []
var history_index := 0
var draft := ""
var options: Array = []
var completion_line := ""
var completion_index := -1
var _changing := false

static func open(host: Node) -> CheatConsole:
	var console := CheatConsole.new()
	console.main = host
	host.add_child(console)
	return console

func caller() -> int:
	if main.net != null: return main.net.my_owner
	# A local hotseat keeps each seated human's own permissions. During AI turns,
	# keep the local lobby seat instead of borrowing the active AI's identity.
	var side: int = main.state.active_player()
	if CheatAccess.seated(main.state, side): return side
	for slot: Roster.Slot in main.state.roster.slots:
		if slot.kind == Roster.SlotKind.HUMAN: return slot.id
	return -1

func _ready() -> void:
	layer = 88
	add_to_group("shortcut_modal")
	history = main._cheat_history
	history_index = history.size()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.015, 0.025, 0.65)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(760, 520)
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var col := VBoxContainer.new()
	panel.add_child(col)
	col.add_child(SteamChrome.header_bar("Cheat console"))
	prompt = Label.new()
	col.add_child(prompt)
	_refresh_prompt()
	output = RichTextLabel.new()
	output.bbcode_enabled = false
	output.selection_enabled = true
	output.scroll_following = true
	output.custom_minimum_size = Vector2(720, 240)
	output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(output)
	var hint := Label.new()
	hint.text = "Enter submits · ↑/↓ history · Tab completes · Esc closes"
	col.add_child(hint)
	input = LineEdit.new()
	input.placeholder_text = "Type help to browse commands"
	input.max_length = 1024
	col.add_child(input)
	hints = ItemList.new()
	hints.custom_minimum_size.y = 120
	hints.focus_mode = Control.FOCUS_NONE
	col.add_child(hints)
	hints.item_clicked.connect(func(index: int, _at: Vector2, _button: int): _insert_completion(index))
	input.text_submitted.connect(submit)
	input.text_changed.connect(_text_changed)
	input.gui_input.connect(_input_key)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(queue_free)
	col.add_child(close)
	if CheatAccess.permitted(main.state, caller()): output.add_text(main._cheat_output)
	write("Cheats enabled. " + CheatQueries.run(main.resolver, {"op": "status", "args": {}}, caller()))
	write("Use help for commands and bounds. State-changing commands clear undo history.")
	if main.net != null:
		main.net.cheat_permissions_changed.connect(_permissions_changed)
	input.grab_focus()
	_text_changed("")

func _process(_delta: float) -> void:
	if not main.state.cheats_enabled or not CheatAccess.seated(main.state, caller()) or main.replay != null or main._fp != null or main._spectator:
		queue_free()

func _permissions_changed() -> void:
	_refresh_prompt()
	if not CheatAccess.permitted(main.state, caller()):
		# Remove any previously inspected private information immediately on revocation.
		output.clear()
		main._cheat_ids = ""
		main._cheat_output = ""
		main.queue_redraw()
	write(CheatQueries.run(main.resolver, {"op": "status", "args": {}}, caller()))
	_text_changed(input.text)

func write(line: String) -> void:
	output.add_text(line + "\n")
	while output.get_paragraph_count() > 600: output.remove_paragraph(0)

func _text_changed(line: String) -> void:
	if _changing: return
	completion_line = line
	completion_index = -1
	options = CheatCommands.complete(line, main.state, caller())
	hints.clear()
	for option: Dictionary in options.slice(0, 100): hints.add_item(option.label)

func _insert_completion(index: int) -> void:
	if index < 0 or index >= options.size(): return
	_changing = true
	input.text = options[index].insert
	input.caret_column = input.text.length()
	_changing = false
	input.grab_focus()

func _input_key(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed: return
	if event.keycode == KEY_ESCAPE or Keybinds.matches(event, "game_cheats"):
		get_viewport().set_input_as_handled()
		queue_free()
	elif event.keycode == KEY_TAB:
		if not options.is_empty():
			completion_index = posmod(completion_index + (-1 if event.shift_pressed else 1), options.size())
			_insert_completion(completion_index)
		get_viewport().set_input_as_handled()
	elif event.keycode in [KEY_UP, KEY_DOWN]:
		if history_index == history.size(): draft = input.text
		history_index = clampi(history_index + (-1 if event.keycode == KEY_UP else 1), 0, history.size())
		input.text = history[history_index] if history_index < history.size() else draft
		input.caret_column = input.text.length()
		_text_changed(input.text)
		get_viewport().set_input_as_handled()

func submit(line: String) -> void:
	line = line.strip_edges()
	if line.is_empty(): return
	history.append(line)
	if history.size() > 100: history.pop_front()
	history_index = history.size()
	draft = ""
	input.clear()
	write("> " + line)
	var parsed := CheatCommands.parse(line, main.state, caller())
	if parsed.has("error"): write(parsed.error); return
	var access: String = parsed.access
	if access == "admin":
		if main.net != null and not main.net.is_host: write("Only the host can manage cheat permissions."); return
		if parsed.op == "permissions": write(CheatQueries.players(main.state)); return
		var allowed: bool = parsed.op == "grant"
		var error: String = main.net.set_cheat_permission(parsed.args.owner, allowed) if main.net != null else CheatAccess.set_permission(main.state, parsed.args.owner, allowed, true)
		write(error if not error.is_empty() else "%s gameplay cheats: %s." % [main.state.roster.name_of(parsed.args.owner), "allowed" if allowed else "denied"])
		_permissions_changed()
		return
	if access != "safe":
		var denied := CheatAccess.denial(main.state, caller())
		if not denied.is_empty(): write(denied); return
	match parsed.op:
		"clear": output.clear(); return
		"ids_on", "ids_off":
			main._cheat_ids = parsed.args.get("category", "all") if parsed.op == "ids_on" else ""
			main.queue_redraw()
			write("Battlefield IDs: " + (main._cheat_ids if not main._cheat_ids.is_empty() else "off"))
			return
	if access in ["safe", "inspect"]: write(CheatQueries.run(main.resolver, parsed, caller())); return
	if main._match_over: write("The match is over; gameplay cheats are unavailable."); return
	if main._animating or main._net_playing or main._net_request_pending:
		write("Wait for the current action to finish, then submit again.")
		return
	if access == "host_play" and main.net != null and not main.net.is_host:
		write("Only the host may change shared AI settings.")
		return
	main._on_intent_ready(CheatIntent.new(parsed.op, parsed.args, caller()))
	_text_changed("")

func _refresh_prompt() -> void:
	prompt.text = "%s · #%d · %s" % [main.state.roster.name_of(caller()), caller() + 1,
		"Gameplay cheats allowed" if CheatAccess.permitted(main.state, caller()) else "Help and roster only · ask the host for permission"]

func _exit_tree() -> void:
	if is_instance_valid(main) and is_instance_valid(output):
		main._cheat_output = output.get_parsed_text().right(60000)
