class_name BattleMenu
extends CanvasLayer

const Chrome = preload("res://src/ui/SteamChrome.gd")
var main: Node
var buttons: Array[Button] = []

static func open(host: Node) -> BattleMenu:
	if is_instance_valid(host._battle_menu): return host._battle_menu
	var menu := BattleMenu.new()
	host._replay_playing = false
	menu.main = host
	host._battle_menu = menu
	host.add_child(menu)
	return menu

func _ready() -> void:
	layer = 75
	add_to_group("shortcut_modal")
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 320
	Chrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	panel.add_child(frame)
	frame.add_child(Chrome.header_bar("Battle menu"))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 9)
	frame.add_child(Chrome.pad(body, 18, 16))
	for entry: Array in [
		["Return to Menu", func() -> void: main._to_lobby()],
		["Settings", func() -> void: SettingsWindow.open(main)],
		["Save Game", func() -> void: main._save_game()],
		["Save Replay", func() -> void: main._prompt_save_name(true)],
	]:
		var button := Button.new()
		button.text = entry[0]
		button.custom_minimum_size.y = 34
		button.pressed.connect(entry[1])
		body.add_child(button)
		buttons.append(button)
	buttons[2].disabled = main.replay != null or main._spectator or main._animating
	buttons[3].disabled = main.recorder == null or main.recorder.is_empty()
	var close := Button.new()
	close.text = "Resume"
	close.custom_minimum_size.y = 34
	close.pressed.connect(queue_free)
	body.add_child(close)
	Ui.theme_canvas_layers()
	close.grab_focus()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		var modals := get_tree().get_nodes_in_group("shortcut_modal")
		if not modals.is_empty() and modals.back() == self:
			get_viewport().set_input_as_handled()
			queue_free()

func _exit_tree() -> void:
	if is_instance_valid(main):
		main._battle_menu = null
		if main.is_inside_tree() and not main.is_queued_for_deletion(): main._kick_if_ai.call_deferred()
