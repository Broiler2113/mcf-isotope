extends Node
## Named shortcuts shared by menus, input handlers and the settings editor.
## Contexts allow intentional key reuse; only overlapping contexts conflict.
signal changed
const SETTINGS_PATH := "user://settings.cfg"
const DEFINITIONS: Array = [
	{"id": "game_cancel", "label": "Cancel / close menu", "keys": [KEY_ESCAPE], "contexts": ["*"], "section": "game"},
	{"id": "game_initiative", "label": "Initiative overlay", "keys": [KEY_TAB], "contexts": ["*"], "section": "game"},
	{"id": "game_pause_ai", "label": "Pause AI battle", "keys": [KEY_P], "contexts": ["*"], "section": "game"},
	{"id": "game_save", "label": "Save game", "keys": [KEY_MASK_CTRL | KEY_S], "contexts": ["*"], "section": "game"},
	{"id": "game_undo", "label": "Undo action / drawing", "keys": [KEY_MASK_CTRL | KEY_Z], "contexts": ["*"], "section": "game"},
	{"id": "game_redo", "label": "Redo action", "keys": [KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_Z], "contexts": ["*"], "section": "game"},
	{"id": "game_pan_up", "label": "Pan up", "keys": [KEY_W], "contexts": ["*"], "section": "game"},
	{"id": "game_pan_down", "label": "Pan down", "keys": [KEY_S], "contexts": ["*"], "section": "game"},
	{"id": "game_pan_left", "label": "Pan left", "keys": [KEY_A], "contexts": ["*"], "section": "game"},
	{"id": "game_pan_right", "label": "Pan right", "keys": [KEY_D], "contexts": ["*"], "section": "game"},
	{"id": "game_remove_point", "label": "Remove ruler / wall point", "keys": [KEY_BACKSPACE], "contexts": ["*"], "section": "game"},
	{"id": "game_confirm_wall", "label": "Confirm wall", "keys": [KEY_ENTER, KEY_KP_ENTER], "contexts": ["*"], "section": "game"},
	{"id": "replay_play_pause", "label": "Play / pause replay", "keys": [KEY_SPACE], "contexts": ["replay"], "section": "game"},
	{"id": "replay_forward", "label": "Replay: next step", "keys": [KEY_RIGHT], "contexts": ["replay"], "section": "game"},
	{"id": "replay_back", "label": "Replay: previous step", "keys": [KEY_LEFT], "contexts": ["replay"], "section": "game"},
	{"id": "action_move", "label": "Move / fly / exit shuttle", "keys": [KEY_M], "contexts": ["infantry", "sapper", "engineer", "operator", "miner", "drone", "passenger", "group", "vehicle"], "section": "game"},
	{"id": "action_shoot", "label": "Shoot / detonate / break free / cannon", "keys": [KEY_F], "contexts": ["infantry", "sapper", "engineer", "operator", "miner", "drone", "passenger", "held", "vehicle"], "section": "game"},
	{"id": "action_grab", "label": "Grab", "keys": [KEY_G], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_push", "label": "Shield push", "keys": [KEY_H], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_shift", "label": "Shift captive", "keys": [KEY_C], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_exit", "label": "Exit Borg / disembark", "keys": [KEY_X], "contexts": ["infantry", "sapper", "engineer", "operator", "miner", "vehicle"], "section": "game"},
	{"id": "action_item", "label": "Use item", "keys": [KEY_I], "contexts": ["infantry", "sapper", "engineer", "operator", "miner", "passenger"], "section": "game"},
	{"id": "action_carry", "label": "Carry furniture", "keys": [KEY_R], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_put", "label": "Put down furniture", "keys": [KEY_L], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_break", "label": "Break furniture", "keys": [KEY_K], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_drop", "label": "Drop corpse", "keys": [KEY_O], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_pull", "label": "Pull corpse from vehicle", "keys": [KEY_U], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_dpmg", "label": "Fire DPMG", "keys": [KEY_T], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_seize", "label": "Seize DPMG", "keys": [KEY_E], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_dig", "label": "Dig trench", "keys": [KEY_J], "contexts": ["infantry", "sapper", "engineer", "operator", "miner"], "section": "game"},
	{"id": "action_board", "label": "Board", "keys": [KEY_B], "contexts": ["infantry", "sapper", "engineer", "operator", "miner", "group", "vehicle"], "section": "game"},
	{"id": "action_mine", "label": "Lay mine", "keys": [KEY_N], "contexts": ["sapper"], "section": "game"},
	{"id": "action_av_mine", "label": "Lay anti-vehicle mine", "keys": [KEY_V], "contexts": ["sapper"], "section": "game"},
	{"id": "action_sweep", "label": "Sweep for mines", "keys": [KEY_Q], "contexts": ["sapper"], "section": "game"},
	{"id": "action_disarm", "label": "Disarm mine", "keys": [KEY_Y], "contexts": ["sapper"], "section": "game"},
	{"id": "action_build", "label": "Build fortification", "keys": [KEY_N], "contexts": ["engineer"], "section": "game"},
	{"id": "action_weld", "label": "Weld airlock", "keys": [KEY_V], "contexts": ["engineer"], "section": "game"},
	{"id": "action_demolish", "label": "Demolish fortification", "keys": [KEY_Q], "contexts": ["engineer", "miner"], "section": "game"},
	{"id": "action_repair", "label": "Repair vehicle", "keys": [KEY_Y], "contexts": ["engineer"], "section": "game"},
	{"id": "action_launch", "label": "Launch drone", "keys": [KEY_N], "contexts": ["operator", "passenger"], "section": "game"},
	{"id": "action_pack", "label": "Pack up drone station", "keys": [KEY_V], "contexts": ["operator", "passenger"], "section": "game"},
	{"id": "game_multiselect", "label": "Toggle multiselect (outside passenger menus)", "keys": [KEY_Z], "contexts": ["infantry", "sapper", "engineer", "operator", "miner", "drone", "held", "group", "vehicle"], "section": "game"},
	{"id": "action_seat", "label": "Change seat", "keys": [KEY_Z], "contexts": ["passenger"], "section": "game"},
	{"id": "action_tactical", "label": "Tactical move / vehicle turn", "keys": [KEY_T], "contexts": ["group", "vehicle"], "section": "game"},
	{"id": "action_volley", "label": "Laser volley", "keys": [KEY_L], "contexts": ["group"], "section": "game"},
	{"id": "picker_previous", "label": "Previous page of action choices", "keys": [KEY_PAGEUP], "contexts": ["picker"], "section": "game"},
	{"id": "picker_next", "label": "Next page of action choices", "keys": [KEY_PAGEDOWN], "contexts": ["picker"], "section": "game"},
	{"id": "editor_cancel", "label": "Cancel / close", "keys": [KEY_ESCAPE], "contexts": ["*"], "section": "editor"},
	{"id": "editor_undo", "label": "Undo", "keys": [KEY_MASK_CTRL | KEY_Z], "contexts": ["*"], "section": "editor"},
	{"id": "editor_redo", "label": "Redo", "keys": [KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_Z, KEY_MASK_CTRL | KEY_Y], "contexts": ["*"], "section": "editor"},
	{"id": "editor_copy", "label": "Copy", "keys": [KEY_MASK_CTRL | KEY_C], "contexts": ["*"], "section": "editor"},
	{"id": "editor_cut", "label": "Cut", "keys": [KEY_MASK_CTRL | KEY_X], "contexts": ["*"], "section": "editor"},
	{"id": "editor_paste", "label": "Paste", "keys": [KEY_MASK_CTRL | KEY_V], "contexts": ["*"], "section": "editor"},
	{"id": "editor_select_all", "label": "Select all", "keys": [KEY_MASK_CTRL | KEY_A], "contexts": ["*"], "section": "editor"},
	{"id": "editor_save", "label": "Save map", "keys": [KEY_MASK_CTRL | KEY_S], "contexts": ["*"], "section": "editor"},
	{"id": "editor_new", "label": "New map", "keys": [KEY_MASK_CTRL | KEY_N], "contexts": ["*"], "section": "editor"},
	{"id": "editor_open", "label": "Open map", "keys": [KEY_MASK_CTRL | KEY_O], "contexts": ["*"], "section": "editor"},
	{"id": "editor_fit", "label": "Fit map", "keys": [KEY_MASK_CTRL | KEY_0], "contexts": ["*"], "section": "editor"},
	{"id": "editor_rotate", "label": "Rotate selection / furniture / decal", "keys": [KEY_R], "contexts": ["*"], "section": "editor"},
	{"id": "editor_rotate_auto", "label": "Automatic furniture rotation", "keys": [KEY_MASK_SHIFT | KEY_R], "contexts": ["*"], "section": "editor"},
	{"id": "editor_zoom_in", "label": "Zoom in", "keys": [KEY_EQUAL, KEY_MASK_SHIFT | KEY_EQUAL, KEY_MASK_SHIFT | KEY_PLUS, KEY_PLUS, KEY_KP_ADD], "contexts": ["*"], "section": "editor"},
	{"id": "editor_zoom_out", "label": "Zoom out", "keys": [KEY_MINUS, KEY_KP_SUBTRACT], "contexts": ["*"], "section": "editor"},
	{"id": "editor_flip_h", "label": "Flip horizontally", "keys": [KEY_H], "contexts": ["*"], "section": "editor"},
	{"id": "editor_flip_v", "label": "Flip vertically", "keys": [KEY_V], "contexts": ["*"], "section": "editor"},
	{"id": "editor_delete", "label": "Delete selection", "keys": [KEY_DELETE, KEY_BACKSPACE], "contexts": ["*"], "section": "editor"},
	{"id": "editor_smaller", "label": "Smaller brush", "keys": [KEY_BRACKETLEFT], "contexts": ["*"], "section": "editor"},
	{"id": "editor_larger", "label": "Larger brush", "keys": [KEY_BRACKETRIGHT], "contexts": ["*"], "section": "editor"},
	{"id": "editor_grid", "label": "Toggle grid", "keys": [KEY_G], "contexts": ["*"], "section": "editor"},
	{"id": "editor_play", "label": "Play map", "keys": [KEY_F5], "contexts": ["*"], "section": "editor"},
	{"id": "editor_help", "label": "Keyboard shortcuts", "keys": [KEY_F1], "contexts": ["*"], "section": "editor"},
	{"id": "editor_pan_up", "label": "Pan up", "keys": [KEY_W, KEY_UP], "contexts": ["*"], "section": "editor"},
	{"id": "editor_pan_down", "label": "Pan down", "keys": [KEY_S, KEY_DOWN], "contexts": ["*"], "section": "editor"},
	{"id": "editor_pan_left", "label": "Pan left", "keys": [KEY_A, KEY_LEFT], "contexts": ["*"], "section": "editor"},
	{"id": "editor_pan_right", "label": "Pan right", "keys": [KEY_D, KEY_RIGHT], "contexts": ["*"], "section": "editor"},
	{"id": "editor_brush", "label": "Brush", "keys": [KEY_B], "contexts": ["*"], "section": "editor"},
	{"id": "editor_eraser", "label": "Eraser", "keys": [KEY_E], "contexts": ["*"], "section": "editor"},
	{"id": "editor_line", "label": "Line", "keys": [KEY_L], "contexts": ["*"], "section": "editor"},
	{"id": "editor_rect", "label": "Rectangle", "keys": [KEY_U], "contexts": ["*"], "section": "editor"},
	{"id": "editor_circle", "label": "Circle", "keys": [KEY_C], "contexts": ["*"], "section": "editor"},
	{"id": "editor_fill", "label": "Fill", "keys": [KEY_F], "contexts": ["*"], "section": "editor"},
	{"id": "editor_select", "label": "Select", "keys": [KEY_M], "contexts": ["*"], "section": "editor"},
	{"id": "editor_pick", "label": "Eyedropper", "keys": [KEY_I], "contexts": ["*"], "section": "editor"},
	{"id": "editor_stamp", "label": "Presets", "keys": [KEY_T], "contexts": ["*"], "section": "editor"},
]

func _ready() -> void:
	load_bindings()

func key_event(code: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code & KEY_CODE_MASK
	event.ctrl_pressed = (code & KEY_MASK_CTRL) != 0
	event.shift_pressed = (code & KEY_MASK_SHIFT) != 0
	event.alt_pressed = (code & KEY_MASK_ALT) != 0
	event.meta_pressed = (code & KEY_MASK_META) != 0
	return event

func definition(id: String) -> Dictionary:
	for entry: Dictionary in DEFINITIONS:
		if entry.id == id: return entry
	return {}

func codes(id: String) -> Array:
	var out: Array = []
	for event in InputMap.action_get_events(id):
		if event is InputEventKey: out.append(event.get_keycode_with_modifiers())
	return out

func _apply(id: String, keys: Array) -> void:
	if not InputMap.has_action(id): InputMap.add_action(id)
	InputMap.action_erase_events(id)
	for code: int in keys: InputMap.action_add_event(id, key_event(code))

func load_bindings(path := SETTINGS_PATH) -> void:
	var config := ConfigFile.new()
	config.load(path)
	for entry: Dictionary in DEFINITIONS:
		_apply(entry.id, entry.keys)
	# Load the whole saved map together: swapped bindings must survive reload.
	for entry: Dictionary in DEFINITIONS:
		var saved: Variant = config.get_value("keybinds", entry.id, 0)
		if saved is int and (int(saved) & KEY_CODE_MASK) != 0:
			_apply(entry.id, [saved])
	changed.emit()

func conflicts(id: String, code: int) -> Array[String]:
	var out: Array[String] = []
	var current := definition(id)
	for entry: Dictionary in DEFINITIONS:
		if entry.id == id or entry.section != current.section or not codes(entry.id).has(code): continue
		var overlap: bool = entry.contexts.has("*") or current.contexts.has("*")
		for context: String in current.contexts: overlap = overlap or entry.contexts.has(context)
		if overlap: out.append(entry.label)
	return out

func rebind(id: String, event: InputEventKey, path := SETTINGS_PATH) -> String:
	var code := event.get_keycode_with_modifiers()
	if event.keycode in [KEY_NONE, KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]: return "Press a key, optionally with modifiers."
	var entry := definition(id)
	if entry.is_empty(): return "Unknown shortcut."
	if entry.section == "game" and not id.begins_with("replay_") and ((code >= KEY_1 and code <= KEY_9) or (code >= KEY_KP_1 and code <= KEY_KP_9)):
		return "Numbers 1–9 are reserved for action choices."
	var taken := conflicts(id, code)
	if not taken.is_empty(): return "Already used by: " + ", ".join(taken)
	var config := ConfigFile.new()
	config.load(path)
	config.set_value("keybinds", id, code)
	var error := config.save(path)
	if error != OK: return "Could not save shortcuts (%s)." % error_string(error)
	_apply(id, [code])
	changed.emit()
	return ""

func reset_defaults(path := SETTINGS_PATH) -> String:
	var config := ConfigFile.new()
	config.load(path)
	if config.has_section("keybinds"): config.erase_section("keybinds")
	var error := config.save(path)
	if error != OK: return "Could not save shortcuts (%s)." % error_string(error)
	load_bindings(path)
	return ""

func label(id: String) -> String:
	var names: Array[String] = []
	for code: int in codes(id): names.append(key_event(code).as_text())
	return " / ".join(names)

func matches(event: InputEvent, id: String) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.is_action_pressed(id, false, true)

func down(id: String) -> bool:
	return Input.is_action_pressed(id, true)

func typing(viewport: Viewport) -> bool:
	var focus := viewport.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or focus is SpinBox

func modal_open() -> bool:
	for node in get_tree().get_nodes_in_group("shortcut_modal"):
		if not node.is_queued_for_deletion() and (not node is CanvasItem or node.is_visible_in_tree()): return true
	return false
