class_name FloatingPanel
extends PanelContainer
const SteamChrome = preload("res://src/ui/SteamChrome.gd")

## A local, nonmodal window. Only its visible rectangle intercepts board input.
signal close_requested
static var geometry: Dictionary = {}
var body: VBoxContainer
var title_bar: Label
var grip: Button
var window_key := ""
var _dragging := false
var _resizing := false
var _origin := Vector2.ZERO
var _start_rect := Rect2()

func setup(title: String, key: String, preferred: Vector2, minimum: Vector2, dark := false) -> void:
	window_key = key
	add_to_group("board_input_panel")
	name = key + "Window"
	custom_minimum_size = minimum
	mouse_filter = Control.MOUSE_FILTER_STOP
	if dark:
		# Black body with the kit's bevel colors on its edge (console, owner 0.14.4).
		var style := StyleBoxFlat.new()
		style.bg_color = Color("0e0e0e")
		style.border_color = Color("3a3a3a")
		style.set_border_width_all(1)
		style.content_margin_left = 1
		style.content_margin_right = 1
		style.content_margin_top = 1
		style.content_margin_bottom = 1
		add_theme_stylebox_override("panel", style)
	else:
		SteamChrome.apply_panel(self)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	add_child(col)
	var close := Button.new()
	close.text = "✕"
	close.tooltip_text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func(): close_requested.emit())
	# The UI kit's window title bar, as on every other window; the caption drags it.
	var header := SteamChrome.header_bar(title, close)
	col.add_child(header)
	title_bar = header.find_children("*", "Label", true, false)[0]
	title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	title_bar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	title_bar.tooltip_text = "Drag to move this window"
	title_bar.gui_input.connect(_title_input)
	body = VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(SteamChrome.pad(body, 10, 8))
	body.get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL
	var footer := HBoxContainer.new()
	col.add_child(SteamChrome.pad(footer, 10, 0))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.add_child(spacer)
	grip = Button.new()
	grip.name = "ResizeGrip"
	grip.text = "◢"
	grip.flat = true
	grip.focus_mode = Control.FOCUS_NONE
	grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	grip.tooltip_text = "Drag to resize"
	grip.gui_input.connect(_grip_input)
	footer.add_child(grip)
	var vp := get_viewport_rect().size
	var saved: Rect2 = geometry.get(key, Rect2((vp - preferred) * 0.5, preferred))
	position = saved.position
	size = saved.size
	_settle.call_deferred(saved)
	get_viewport().size_changed.connect(_fit)

func _settle(saved: Rect2) -> void:
	# Wrapped labels initially measure against zero-width containers. Let their
	# widths settle before restoring the requested size, rather than retaining
	# a spurious several-thousand-pixel minimum from the first layout pass.
	get_tree().process_frame.connect(_settle_second.bind(saved), CONNECT_ONE_SHOT)

func _settle_second(saved: Rect2) -> void:
	get_tree().process_frame.connect(_settle_final.bind(saved), CONNECT_ONE_SHOT)

func _settle_final(saved: Rect2) -> void:
	position = saved.position
	size = saved.size
	_fit()

func _title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_origin = event.global_position
		_start_rect = get_rect()
		accept_event()

func _grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_resizing = event.pressed
		_origin = event.global_position
		_start_rect = get_rect()
		accept_event()

func _input(event: InputEvent) -> void:
	if not _dragging and not _resizing: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_dragging = false
		_resizing = false
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var delta: Vector2 = event.position - _origin
		if _dragging: position = _start_rect.position + delta
		if _resizing: size = (_start_rect.size + delta).max(get_combined_minimum_size())
		_fit()
		get_viewport().set_input_as_handled()

func _fit() -> void:
	var vp := get_viewport_rect().size
	size = size.min((vp - Vector2(16, 16)).max(get_combined_minimum_size()))
	position = position.clamp(Vector2.ZERO, (vp - size).max(Vector2.ZERO))

func _exit_tree() -> void:
	geometry[window_key] = get_rect()
