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
		var style := StyleBoxFlat.new()
		style.bg_color = Color("080b10")
		style.border_color = Color("394653")
		style.set_border_width_all(1)
		style.set_corner_radius_all(5)
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 8
		style.content_margin_bottom = 6
		add_theme_stylebox_override("panel", style)
	else:
		SteamChrome.apply_panel(self)
	var col := VBoxContainer.new()
	add_child(col)
	var header := HBoxContainer.new()
	col.add_child(header)
	title_bar = Label.new()
	title_bar.text = title
	title_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.custom_minimum_size.y = 30
	title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	title_bar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	title_bar.tooltip_text = "Drag to move this window"
	title_bar.gui_input.connect(_title_input)
	header.add_child(title_bar)
	var close := Button.new()
	close.text = "×"
	close.tooltip_text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func(): close_requested.emit())
	header.add_child(close)
	body = VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	var footer := HBoxContainer.new()
	col.add_child(footer)
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
	await get_tree().process_frame
	await get_tree().process_frame
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
