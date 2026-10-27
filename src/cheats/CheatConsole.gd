class_name CheatConsole
extends CanvasLayer

const SteamChrome = preload("res://src/ui/SteamChrome.gd")

## The console's own dark palette (owner, 0.14.4): black and dark gray under the kit's
## title bar, font and accent color.
const WELL := Color("0b0b0b")
const FIELD := Color("101010")
const EDGE := Color("333333")
const ROW_A := Color("121212")
const ROW_B := Color("181818")
const ROW_HEAD := Color("232323")
const ERROR := Color("e0806a")
const OUTPUT_KEEP := 400

var main: Node
var prompt: Label
var status: Label
var output: RichTextLabel
var input: LineEdit
var hints: ItemList
var hint_syntax: Label
var hint_help: Label
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
var _tool_banner: PanelContainer

static func open(host: Node) -> CheatConsole:
	var console := CheatConsole.new()
	console.main = host
	host.add_child(console)
	return console

func caller() -> int:
	return CheatAccess.console_side(main)

## May use host-only AI and history commands.
func is_host() -> bool:
	return main.net == null or main.net.is_host

## May manage permissions, kick and ban: the network host, or a local game's first human seat.
func is_admin() -> bool:
	return main.net.is_host if main.net != null else CheatAccess.local_admin(main.state, caller())

static func _box(color: Color, border := Color(0, 0, 0, 0), margin := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0 else 0)
	style.set_content_margin_all(margin)
	return style

func _ready() -> void:
	layer = 88
	add_to_group("cheat_console")
	history = main._cheat_history
	history_index = history.size()
	window = FloatingPanel.new()
	add_child(window)
	window.setup("Cheat Console", "CheatConsole", Vector2(760, 540), Vector2(520, 320), true)
	window.close_requested.connect(queue_free)
	var col := window.body
	col.add_theme_constant_override("separation", 6)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	col.add_child(bar)
	prompt = Label.new()
	if Ui != null and Ui.bold_font() != null: prompt.add_theme_font_override("font", Ui.bold_font())
	prompt.add_theme_color_override("font_color", Ui.TEXT_BRIGHT)
	bar.add_child(prompt)
	status = Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bar.add_child(status)
	_refresh_prompt()
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", _box(WELL, EDGE, 8))
	well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(well)
	output = RichTextLabel.new()
	output.bbcode_enabled = false
	output.selection_enabled = true
	output.scroll_following = true
	output.custom_minimum_size = Vector2(0, 100)
	output.add_theme_color_override("default_color", Ui.TEXT)
	output.add_theme_color_override("selection_color", Ui.accent_color() * Color(1, 1, 1, 0.45))
	output.add_theme_constant_override("line_separation", 2)
	output.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	output.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	well.add_child(output)
	_tool_banner = PanelContainer.new()
	_tool_banner.add_theme_stylebox_override("panel", _box(Ui.accent_color() * Color(0.35, 0.35, 0.35, 1), Ui.accent_color(), 6))
	_tool_banner.hide()
	col.add_child(_tool_banner)
	tool_hint = Label.new()
	tool_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tool_hint.add_theme_color_override("font_color", Ui.TEXT_BRIGHT)
	_tool_banner.add_child(tool_hint)
	# Prompt and input share one field; its edge takes the accent color while typing.
	var field := PanelContainer.new()
	var calm := _box(FIELD, EDGE)
	calm.content_margin_left = 8
	var focused := calm.duplicate() as StyleBoxFlat
	focused.border_color = Ui.accent_color()
	field.add_theme_stylebox_override("panel", calm)
	col.add_child(field)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	field.add_child(line)
	var caret := Label.new()
	caret.text = ">"
	caret.add_theme_color_override("font_color", Ui.text_accent_color())
	line.add_child(caret)
	input = LineEdit.new()
	input.placeholder_text = "Type a command, or help"
	input.max_length = 1024
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bare := StyleBoxEmpty.new()
	bare.content_margin_top = 6
	bare.content_margin_bottom = 6
	input.add_theme_stylebox_override("normal", bare)
	input.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	input.add_theme_color_override("font_color", Ui.TEXT_BRIGHT)
	input.add_theme_color_override("font_placeholder_color", Ui.TEXT_DIM)
	input.add_theme_color_override("caret_color", Ui.text_accent_color())
	input.focus_entered.connect(func(): field.add_theme_stylebox_override("panel", focused))
	input.focus_exited.connect(func(): field.add_theme_stylebox_override("panel", calm))
	line.add_child(input)
	hints = ItemList.new()
	hints.allow_reselect = true
	hints.auto_height = false
	hints.add_theme_stylebox_override("panel", _box(FIELD, EDGE, 4))
	hints.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var picked := _box(Ui.accent_color() * Color(0.45, 0.45, 0.45, 1))
	hints.add_theme_stylebox_override("selected", picked)
	hints.add_theme_stylebox_override("selected_focus", picked)
	hints.add_theme_stylebox_override("hovered", _box(Color("1e1e1e")))
	hints.add_theme_color_override("font_color", Ui.TEXT)
	hints.add_theme_color_override("font_hovered_color", Ui.TEXT_BRIGHT)
	hints.add_theme_color_override("font_selected_color", Ui.TEXT_BRIGHT)
	hints.focus_mode = Control.FOCUS_NONE
	col.add_child(hints)
	hint_syntax = Label.new()
	hint_syntax.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_syntax.add_theme_color_override("font_color", Ui.text_accent_color())
	col.add_child(hint_syntax)
	hint_help = Label.new()
	hint_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_help.add_theme_color_override("font_color", Ui.TEXT_DIM)
	col.add_child(hint_help)
	var keys := Label.new()
	keys.text = "Enter run · Tab complete · Up/Down history · Esc close"
	keys.add_theme_color_override("font_color", Ui.TEXT_DIM)
	keys.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys.clip_text = true
	keys.size_flags_stretch_ratio = 20
	window.grip.get_parent().add_child(keys)
	window.grip.get_parent().move_child(keys, 0)
	hints.item_clicked.connect(func(index: int, _at: Vector2, _button: int): _insert_completion(index); _text_changed(input.text))
	input.text_submitted.connect(submit)
	input.text_changed.connect(_text_changed)
	input.gui_input.connect(_input_key)
	var previous: Array = main._cheat_output
	main._cheat_output = []
	if CheatAccess.permitted(main.state, caller()):
		for entry: Array in previous: write(entry[0], entry[1])
	if not main.state.cheats_enabled:
		write("Cheats are disabled for this match, so commands do not run. help still lists them.", "note")
	if main.net != null:
		main.net.cheat_permissions_changed.connect(_permissions_changed)
	input.grab_focus()
	_text_changed("")

func _process(_delta: float) -> void:
	if not CheatAccess.seated(main.state, caller()) or main.replay != null or main._fp != null or main._spectator:
		queue_free()

func _permissions_changed() -> void:
	_refresh_prompt()
	if not CheatAccess.permitted(main.state, caller()):
		# Remove any previously inspected private information immediately on revocation.
		cancel_tool()
		output.clear()
		main._cheat_ids = ""
		main._cheat_coords = false
		main._cheat_output = []
		main.queue_redraw()
	write(CheatQueries.run(main.resolver, {"op": "status", "args": {}}, caller()), "note")
	_text_changed(input.text)

## kind: "" result text, "command" an echoed input line, "error" a refusal, "note" console status.
func write(line: String, kind := "") -> void:
	main._cheat_output.append([line, kind])
	if main._cheat_output.size() > OUTPUT_KEEP: main._cheat_output.pop_front()
	if kind == "command":
		if output.get_paragraph_count() > 1: output.add_text("\n")
		output.push_color(Ui.text_accent_color())
		output.add_text("> " + line + "\n")
		output.pop()
		return
	if kind in ["error", "note"]:
		output.push_color(ERROR if kind == "error" else Ui.TEXT_DIM)
		output.add_text(line + "\n")
		output.pop()
		return
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
				output.set_cell_padding(Rect2(7, 3, 7, 3))
				output.set_cell_border_color(EDGE)
				if index == 0: output.set_cell_row_background_color(ROW_HEAD, ROW_HEAD)
				else: output.set_cell_row_background_color(ROW_A, ROW_B)
				if index == 0: output.push_color(Ui.TEXT_BRIGHT)
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
	options = [] if line.strip_edges().is_empty() else CheatCommands.complete(line, main.state, caller(), main.resolver, is_host(), is_admin())
	hints.visible = not options.is_empty()
	hints.clear()
	# Up to five rows tall: one suggestion does not take the output's space.
	var row := hints.get_theme_font("font").get_height(hints.get_theme_font_size("font_size")) + hints.get_theme_constant("v_separation")
	hints.custom_minimum_size.y = mini(options.size(), 5) * row + 10
	for option: Dictionary in options.slice(0, 100):
		hints.add_item(option.label)
		hints.set_item_tooltip(hints.item_count - 1, option.get("syntax", ""))
	_describe(0)

## Syntax and explanation of the highlighted suggestion, under the list.
func _describe(index: int) -> void:
	var known := index >= 0 and index < options.size()
	hint_syntax.text = str(options[index].get("syntax", "")) if known else ""
	hint_help.text = str(options[index].get("help", "")) if known else ""
	hint_syntax.visible = known
	hint_help.visible = known and not hint_help.text.is_empty()

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
			hints.select(completion_index)
			hints.ensure_current_is_visible()
			_describe(completion_index)
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
	write(line, "command")
	var parsed := CheatCommands.parse(line, main.state, caller())
	if parsed.has("error"): write(parsed.error, "error"); return
	var access: String = parsed.access
	if access == "admin":
		if not is_admin():
			write("Only the host can administer players." if main.net != null else "Only %s, the first human seat, can manage cheat permissions in a local game." % _first_human_name(), "error")
			return
		if parsed.op in ["kick", "ban"]: _moderate(parsed.op, parsed.args.owner); return
		if parsed.op == "permissions": write(CheatQueries.players(main.state)); return
		var allowed: bool = parsed.op == "grant"
		var error: String = main.net.set_cheat_permission(parsed.args.owner, allowed) if main.net != null else CheatAccess.set_permission(main.state, parsed.args.owner, allowed, true)
		if not error.is_empty(): write(error, "error")
		else: write("%s gameplay cheats: %s." % [CheatQueries.player_label(main.state, parsed.args.owner), "allowed" if allowed else "denied"])
		_permissions_changed()
		return
	if access != "safe":
		var denied := CheatAccess.denial(main.state, caller())
		if not denied.is_empty(): write(denied, "error"); return
	match parsed.op:
		"clear": output.clear(); main._cheat_output = []; return
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
		start_tool(parsed)
		return
	if access == "host_history":
		write(main._history_command(parsed, caller()))
		return
	if access in ["safe", "inspect"]: write(CheatQueries.run(main.resolver, parsed, caller())); return
	if main._match_over: write("The match is over; gameplay cheats are unavailable.", "error"); return
	if (main._animating or main._net_playing or main._net_request_pending) and parsed.op not in ["ai_pause", "ai_resume"]:
		write("Wait for the current action to finish, then submit again.", "error")
		return
	if access == "host_play" and not is_host():
		write("Only the host may change shared AI settings.", "error")
		return
	main._on_intent_ready(CheatIntent.new(parsed.op, parsed.args, caller()))
	_text_changed("")

func _first_human_name() -> String:
	for slot: Roster.Slot in main.state.roster.slots:
		if slot.kind == Roster.SlotKind.HUMAN: return main.state.roster.name_of(slot.id)
	return "the first player"

func _refresh_prompt() -> void:
	prompt.text = main.state.roster.name_of(caller())
	var color: Color = Ui.TEXT_DIM
	if not main.state.cheats_enabled:
		status.text = "Cheats are disabled for this match"
		color = ERROR
	elif CheatAccess.permitted(main.state, caller()):
		status.text = "Gameplay cheats allowed"
		color = Ui.text_accent_color()
	else:
		status.text = "Help and roster only · ask the host for permission"
	status.add_theme_color_override("font_color", color)

func start_tool(parsed: Dictionary) -> void:
	tool = parsed.duplicate(true)
	input.release_focus()
	var description := "Inspect cells" if str(parsed.op).begins_with("inspect_") else "Place %s for %s" % [parsed.args.get("type", "event"), CheatQueries.player_label(main.state, parsed.args.get("owner", caller()))]
	tool_hint.text = description + " · click the battlefield · Esc stops"
	_tool_banner.show()
	write(tool_hint.text, "note")

func cancel_tool() -> void:
	tool.clear()
	if is_instance_valid(tool_hint): tool_hint.text = ""
	if is_instance_valid(_tool_banner): _tool_banner.hide()

func board_input(event: InputEvent) -> bool:
	if tool.is_empty(): return false
	if not CheatAccess.permitted(main.state, caller()): cancel_tool(); return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed: return true
		var at: Vector2i = main._pos_to_cell(event.position)
		if not main.state.grid.in_bounds(at): return true
		if str(tool.op).begins_with("inspect_"):
			write("inspect (%d,%d)" % [at.x, at.y], "command")
			write(CheatQueries.inspect_at(main.resolver, at, caller(), str(tool.op).trim_prefix("inspect_").trim_suffix("_tool")))
			return true
		if main._match_over: write("The match is over.", "error"); cancel_tool(); return true
		if main._animating or main._net_playing or main._net_request_pending:
			write("Wait for the current action to finish.", "error"); return true
		var args: Dictionary = tool.args.duplicate(true)
		args.x = at.x
		args.y = at.y
		execute_action(str(tool.op).trim_suffix("_tool"), args)
		return true
	return event is InputEventMouseMotion

func _moderate(op: String, side: int) -> void:
	if main.net == null or main.session == null: write("Player moderation requires a multiplayer lobby.", "error"); return
	if not main.net.is_host: write("Only the host can administer players.", "error"); return
	var slot: Roster.Slot = main.state.roster.slot(side)
	if slot == null or slot.kind != Roster.SlotKind.HUMAN or slot.peer_id <= 1 or not main.session.peers.has(slot.peer_id):
		write("Choose a connected human guest; AI players and the host cannot be kicked or banned.", "error"); return
	var name: String = slot.display_name
	if op == "ban":
		var error: String = main.session.ban_player(slot.peer_id)
		if not error.is_empty(): write(error, "error")
		else: write(name + " banned for this hosted session.")
	else:
		main.session.kick(slot.peer_id)
		write(name + " kicked.")

func execute_action(op: String, args: Dictionary) -> bool:
	var denial := CheatAccess.denial(main.state, caller())
	if not denial.is_empty(): write(denial, "error"); cancel_tool(); return false
	if main._match_over: write("The match is over.", "error"); return false
	if main._animating or main._net_playing or main._net_request_pending: write("Wait for the current action to finish.", "error"); return false
	write("%s at (%d,%d)" % [op.replace("_", " "), int(args.get("x", 0)), int(args.get("y", 0))], "command")
	main._on_intent_ready(CheatIntent.new(op, args, caller()))
	return true
