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
var window: FloatingPanel
var tool: Dictionary = {}
var tool_hint: Label

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
	add_to_group("cheat_console")
	history = main._cheat_history
	history_index = history.size()
	window = FloatingPanel.new()
	add_child(window)
	window.setup("Cheat console", "CheatConsole", Vector2(760, 520), Vector2(520, 300), true)
	window.close_requested.connect(queue_free)
	var col := window.body
	prompt = Label.new()
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(prompt)
	_refresh_prompt()
	output = RichTextLabel.new()
	output.bbcode_enabled = false
	output.selection_enabled = true
	output.scroll_following = true
	output.custom_minimum_size = Vector2(0, 100)
	output.add_theme_color_override("default_color", Color("d3dce7"))
	output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(output)
	tool_hint = Label.new()
	tool_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tool_hint.modulate = Color("efd089")
	col.add_child(tool_hint)
	input = LineEdit.new()
	input.placeholder_text = "Command"
	input.max_length = 1024
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color("101720")
	input_style.border_color = Color("46576b")
	input_style.set_border_width_all(1)
	input_style.content_margin_left = 8
	input_style.content_margin_top = 6
	input_style.content_margin_bottom = 6
	input.add_theme_stylebox_override("normal", input_style)
	input.add_theme_color_override("font_color", Color("edf2f8"))
	col.add_child(input)
	hints = ItemList.new()
	hints.custom_minimum_size.y = 84
	hints.allow_reselect = true
	var hint_style := StyleBoxFlat.new()
	hint_style.bg_color = Color("0d1219")
	hints.add_theme_stylebox_override("panel", hint_style)
	hints.add_theme_color_override("font_color", Color("bdcfdf"))
	hints.focus_mode = Control.FOCUS_NONE
	col.add_child(hints)
	hints.item_clicked.connect(func(index: int, _at: Vector2, _button: int): _insert_completion(index); _text_changed(input.text))
	input.text_submitted.connect(submit)
	input.text_changed.connect(_text_changed)
	input.gui_input.connect(_input_key)
	var previous: String = main._cheat_output
	main._cheat_output = ""
	if CheatAccess.permitted(main.state, caller()) and not previous.is_empty(): write(previous.strip_edges())
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
		cancel_tool()
		output.clear()
		main._cheat_ids = ""
		main._cheat_coords = false
		main._cheat_output = ""
		main.queue_redraw()
	write(CheatQueries.run(main.resolver, {"op": "status", "args": {}}, caller()))
	_text_changed(input.text)

func write(line: String) -> void:
	main._cheat_output = (main._cheat_output + line + "\n").right(60000)
	var lines := line.split("\n")
	var row := 0
	while row < lines.size():
		if not lines[row].contains(" | "):
			output.add_text(lines[row] + "\n")
			row += 1
			continue
		var rows: Array = []
		var columns := 0
		while row < lines.size() and lines[row].contains(" | "):
			var cells := lines[row].split(" | ")
			columns = maxi(columns, cells.size())
			rows.append(cells)
			row += 1
		output.push_table(columns)
		for index in rows.size():
			for column in columns:
				output.set_table_column_expand(column, true)
				output.push_cell()
				output.set_cell_padding(Rect2(7, 4, 7, 4))
				output.set_cell_border_color(Color("35404d"))
				output.set_cell_row_background_color(Color("111923"), Color("0c121a"))
				if index == 0: output.push_bold()
				output.add_text(rows[index][column] if column < rows[index].size() else "")
				if index == 0: output.pop()
				output.pop()
		output.pop()
		output.add_text("\n")
	while output.get_paragraph_count() > 600: output.remove_paragraph(0)

func _text_changed(line: String) -> void:
	if _changing: return
	completion_line = line
	completion_index = -1
	options = [] if line.strip_edges().is_empty() else CheatCommands.complete(line, main.state, caller(), main.resolver)
	hints.visible = not options.is_empty()
	hints.clear()
	for option: Dictionary in options.slice(0, 100):
		hints.add_item(option.label)
		hints.set_item_tooltip(hints.item_count - 1, option.get("syntax", ""))

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
		if not tool.is_empty(): cancel_tool()
		else: queue_free()
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
	_text_changed("")
	write("────────────────────────────────────────────────")
	write("> " + line)
	var parsed := CheatCommands.parse(line, main.state, caller())
	if parsed.has("error"): write(parsed.error); return
	var access: String = parsed.access
	if access == "admin":
		if main.net != null and not main.net.is_host: write("Only the host can administer players."); return
		if parsed.op in ["kick", "ban"]: _moderate(parsed.op, parsed.args.owner); return
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
		"clear": output.clear(); main._cheat_output = ""; return
		"coords_on", "coords_off":
			main._cheat_coords = parsed.op == "coords_on"
			write("Tile coordinates: " + ("on" if main._cheat_coords else "off"))
			return
		"ids_on", "ids_off":
			main._cheat_ids = parsed.args.get("category", "all") if parsed.op == "ids_on" else ""
			main.queue_redraw()
			write("Battlefield IDs: " + (main._cheat_ids if not main._cheat_ids.is_empty() else "off"))
			return
	if access == "tool":
		if parsed.op in ["event_spawn_tool", "event_edit_tool"]:
			CheatEventEditor.open(self, parsed.op == "event_spawn_tool", parsed.args.get("event", parsed.args.get("target", "")))
		else: start_tool(parsed)
		return
	if access in ["safe", "inspect"]: write(CheatQueries.run(main.resolver, parsed, caller())); return
	if main._match_over: write("The match is over; gameplay cheats are unavailable."); return
	if (main._animating or main._net_playing or main._net_request_pending) and parsed.op not in ["ai_pause", "ai_resume"]:
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


func start_tool(parsed: Dictionary) -> void:
	tool = parsed.duplicate(true)
	input.release_focus()
	var description := "Inspect cells" if str(parsed.op).begins_with("inspect_") else "Place %s for %s" % [parsed.args.get("type", "event"), main.state.roster.name_of(parsed.args.get("owner", caller()))]
	if parsed.op == "event_spawn_tool": description = "Select two opposite corners for " + RandomEvents.event_name(parsed.args.event) if _area_tool() else "Place " + RandomEvents.event_name(parsed.args.event)
	if parsed.op == "event_remove_tool": description = "Select event to remove"
	tool_hint.text = description + " · Esc stops"
	write(tool_hint.text)

func cancel_tool() -> void:
	tool.clear()
	if is_instance_valid(tool_hint): tool_hint.text = ""

func board_input(event: InputEvent) -> bool:
	if tool.is_empty(): return false
	if not CheatAccess.permitted(main.state, caller()): cancel_tool(); return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed: return true
		var at: Vector2i = main._pos_to_cell(event.position)
		if not main.state.grid.in_bounds(at): return true
		if str(tool.op).begins_with("inspect_"):
			write("────────────────────────────────────────────────")
			write("Inspect (%d, %d)\n" % [at.x, at.y] + CheatQueries.inspect_at(main.resolver, at, caller(), str(tool.op).trim_prefix("inspect_").trim_suffix("_tool")))
			return true
		if main._match_over: write("The match is over."); cancel_tool(); return true
		if main._animating or main._net_playing or main._net_request_pending:
			write("Wait for the current action to finish."); return true
		if tool.op == "event_remove_tool":
			var refs := CheatEventModel.at_cell(main.resolver, at)
			if refs.is_empty(): write("No active event at this cell.")
			elif refs.size() == 1: execute_action("event_remove", {"target": refs[0]})
			else:
				write("Overlapping events: " + ", ".join(refs) + ". Choose one in the event editor.")
				CheatEventEditor.open(self, false, refs[0])
			return true
		var args: Dictionary = tool.args.duplicate(true)
		if _area_tool():
			if not tool.has("corner"):
				tool.corner = at
				tool_hint.text = "First corner (%d,%d) · Select opposite corner · Esc stops" % [at.x, at.y]
				return true
			var low: Vector2i = tool.corner.min(at)
			var size: Vector2i = tool.corner.max(at) - low + Vector2i.ONE
			args.properties.merge({"x": low.x, "y": low.y, "w": size.x, "h": size.y}, true)
			at = low
			tool.erase("corner")
			tool_hint.text = "Select first corner · Esc stops"
		args.x = at.x
		args.y = at.y
		execute_action(str(tool.op).trim_suffix("_tool"), args)
		return true
	return event is InputEventMouseMotion

func _moderate(op: String, side: int) -> void:
	if main.net == null or main.session == null: write("Player moderation requires a multiplayer lobby."); return
	if not main.net.is_host: write("Only the host can administer players."); return
	var slot: Roster.Slot = main.state.roster.slot(side)
	if slot == null or slot.kind != Roster.SlotKind.HUMAN or slot.peer_id <= 1 or not main.session.peers.has(slot.peer_id):
		write("Choose a connected human guest; AI players and the host cannot be kicked or banned."); return
	var name: String = slot.display_name
	if op == "ban":
		var error: String = main.session.ban_player(slot.peer_id)
		write(error if not error.is_empty() else name + " banned for this hosted session.")
	else:
		main.session.kick(slot.peer_id)
		write(name + " kicked.")

func execute_action(op: String, args: Dictionary) -> bool:
	var denial := CheatAccess.denial(main.state, caller())
	if not denial.is_empty(): write(denial); cancel_tool(); return false
	if main._match_over: write("The match is over."); return false
	if main._animating or main._net_playing or main._net_request_pending: write("Wait for the current action to finish."); return false
	write("────────────────────────────────────────────────")
	main._on_intent_ready(CheatIntent.new(op, args, caller()))
	return true

func _area_tool() -> bool:
	return tool.get("op", "") == "event_spawn_tool" and tool.args.event in ["mortar", "gas", "fire", "emp", "collapse"]
