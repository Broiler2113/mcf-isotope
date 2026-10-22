class_name CheatEventEditor
extends CanvasLayer

var console: CheatConsole
var spawning := false
var requested := ""
var window: FloatingPanel
var select: OptionButton
var description: Label
var fields: GridContainer
var apply_button: Button
var remove_button: Button
var records: Array[Dictionary] = []
var controls: Dictionary = {}

static func open(owner_console: CheatConsole, spawn_mode: bool, target := "") -> CheatEventEditor:
	for old in owner_console.get_children():
		if old is CheatEventEditor: old.queue_free()
	var editor := CheatEventEditor.new()
	editor.console = owner_console
	editor.spawning = spawn_mode
	editor.requested = target
	owner_console.add_child(editor)
	return editor

func _ready() -> void:
	layer = 89
	window = FloatingPanel.new()
	add_child(window)
	window.setup("Place event" if spawning else "Manage events", "EventEditor", Vector2(480, 440), Vector2(360, 260), true)
	window.close_requested.connect(queue_free)
	select = OptionButton.new()
	window.body.add_child(select)
	select.item_selected.connect(func(_index: int): _show_selected())
	description = Label.new()
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	window.body.add_child(description)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	window.body.add_child(scroll)
	fields = GridContainer.new()
	fields.columns = 2
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(fields)
	var row := HBoxContainer.new()
	window.body.add_child(row)
	apply_button = Button.new()
	apply_button.text = "Place on battlefield" if spawning else "Apply changes"
	apply_button.pressed.connect(_apply)
	row.add_child(apply_button)
	remove_button = Button.new()
	remove_button.text = "Remove event"
	remove_button.visible = not spawning
	remove_button.pressed.connect(func():
		if select.selected >= 0 and select.selected < records.size(): console.execute_action("event_remove", {"target": records[select.selected].ref}))
	row.add_child(remove_button)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(_refresh)
	row.add_child(refresh)
	_refresh()

func _process(_delta: float) -> void:
	if not is_instance_valid(console) or not CheatAccess.permitted(console.main.state, console.caller()): queue_free()

func _refresh() -> void:
	select.clear()
	records.clear()
	var r: GameActionResolver = console.main.resolver
	if spawning:
		var allowed := r._events_allowed()
		for pair: Array in RandomEvents.REGISTRY:
			records.append({"ref": pair[0], "event": pair[0], "properties": defaults(pair[0], r)})
			select.add_item(pair[1] + ("" if allowed.has(pair[0]) else " — unavailable"))
	else:
		records = CheatEventModel.entries(r)
		for entry: Dictionary in records: select.add_item("%s · %s · %s" % [entry.ref, RandomEvents.event_name(entry.event), entry.phase])
	for index in records.size():
		if records[index].ref == requested: select.select(index); break
	_show_selected()

static func defaults(id: String, r: GameActionResolver) -> Dictionary:
	var p := {}
	if id in ["mortar", "gas", "fire", "emp", "collapse"]:
		var side: int = {"mortar": r.BARRAGE_SIDE_MIN, "gas": r.GAS_SIDE_MIN, "fire": r.FIRE_SIDE, "emp": r.EMP_SIDE, "collapse": r.COLLAPSE_SIDE}[id]
		p = {"w": mini(side, r.state.grid.width), "h": mini(side, r.state.grid.height)}
	if id == "gas": p.rounds = r.GAS_ROUNDS
	if id == "dust": p.rounds = r.DUST_ROUNDS
	if id == "bounty": p.rounds = r.BOUNTY_ROUNDS
	if id == "army": p.len = mini(r.ARMY_SEGMENT_MIN, mini(r.state.grid.width, r.state.grid.height))
	if id == "reinforce":
		p = r._reinforce_target()
		for key: String in ["edge", "from", "hx", "hy"]: p.erase(key)
	return p

func _show_selected() -> void:
	for child in fields.get_children():
		fields.remove_child(child)
		child.queue_free()
	controls.clear()
	apply_button.disabled = records.is_empty()
	remove_button.disabled = records.is_empty()
	if records.is_empty(): description.text = "No active events or pending warnings. Use event spawn to create one."; return
	var entry: Dictionary = records[select.selected]
	requested = entry.ref
	var r: GameActionResolver = console.main.resolver
	description.text = RandomEvents.NOTES.get(entry.event, "Harmless smoke reduces visibility.")
	if spawning:
		apply_button.disabled = not r._events_allowed().has(entry.event)
		description.text += "\nClick to choose the area center, a soldier for a bounty, or the landing edge for a force. Dust covers the whole board. Esc stops placement."
	else:
		description.text += "\nOnly this effect's supported properties are editable. Removing an event does not reverse damage already dealt."
	var schema := CheatEventModel.schema(entry.event, r, entry.properties)
	for key: String in entry.properties:
		if not schema.has(key): continue
		var label := Label.new()
		label.text = {"w": "Width (cells)", "h": "Height (cells)", "rounds": "Rounds remaining" if not spawning else "Duration (rounds)", "edge": "Edge (0=N, 1=E, 2=S, 3=W)", "from": "Edge offset", "len": "Landing width", "side": "Player (zero-based slot)", "unit": "Target unit ID"}.get(key, key.capitalize())
		fields.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = schema[key][0]
		spin.max_value = schema[key][1]
		spin.value = entry.properties[key]
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fields.add_child(spin)
		controls[key] = spin
	if controls.is_empty() and not spawning:
		apply_button.disabled = true
		description.text += "\nThis effect can be removed; it has no adjustable numeric properties."

func _apply() -> void:
	if records.is_empty(): return
	var entry: Dictionary = records[select.selected]
	var props := {}
	for key: String in controls:
		var spin: SpinBox = controls[key]
		spin.apply()
		props[key] = int(spin.value)
	if spawning:
		console.start_tool({"op": "event_spawn_tool", "args": {"event": entry.event, "properties": props}})
		queue_free()
	else:
		console.execute_action("event_update", {"target": entry.ref, "properties": props})

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		queue_free()
