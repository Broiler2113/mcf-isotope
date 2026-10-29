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
	# The UI kit's window title bar, as on every other window; the whole bar drags it.
	var header := SteamChrome.header_bar(title, SteamChrome.close_x(func(): close_requested.emit()))
	col.add_child(header)
	title_bar = header.find_children("*", "Label", true, false)[0]
	header.mouse_default_cursor_shape = Control.CURSOR_MOVE
	header.tooltip_text = "Drag to move this window"
	header.gui_input.connect(_title_input)
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
	_add_border()
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

## Every edge and corner resizes (issues-14 #11): a thin ring just outside the window, behind
## it, so it only catches the pointer where the window is not.
const BORDER := 6.0
var _border: Control
var _edges := Vector2i.ZERO   # -1 left/top, 1 right/bottom, 0 that axis stays

func _add_border() -> void:
	_border = Control.new()
	_border.name = "ResizeBorder"
	_border.mouse_filter = Control.MOUSE_FILTER_STOP
	get_parent().add_child(_border)
	get_parent().move_child(_border, get_index())
	_border.gui_input.connect(_border_input)
	item_rect_changed.connect(_place_border)
	visibility_changed.connect(func() -> void: _border.visible = visible)
	tree_exiting.connect(_border.queue_free)

func _place_border() -> void:
	if is_instance_valid(_border):
		_border.position = position - Vector2(BORDER, BORDER)
		_border.size = size + Vector2(BORDER, BORDER) * 2.0

func _edges_at(local: Vector2) -> Vector2i:
	var s := _border.size
	return Vector2i(-1 if local.x < BORDER * 2.0 else (1 if local.x > s.x - BORDER * 2.0 else 0),
			-1 if local.y < BORDER * 2.0 else (1 if local.y > s.y - BORDER * 2.0 else 0))

func _border_input(event: InputEvent) -> void:
	var e := _edges_at(event.position) if event is InputEventMouse else Vector2i.ZERO
	if e.x != 0 and e.y != 0:
		_border.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE if e.x == e.y else Control.CURSOR_BDIAGSIZE
	else:
		_border.mouse_default_cursor_shape = Control.CURSOR_HSIZE if e.x != 0 else Control.CURSOR_VSIZE
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_edges = e
		_resizing = true
		_origin = event.global_position
		_start_rect = get_rect()
		_border.accept_event()

func _title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_origin = event.global_position
		_start_rect = get_rect()
		accept_event()

func _grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_resizing = event.pressed
		_edges = Vector2i(1, 1)
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
		if _resizing: _resize(delta)
		_fit()
		get_viewport().set_input_as_handled()

## Drag the edges in _edges by delta; a left or top edge moves the window, never past its minimum.
func _resize(delta: Vector2) -> void:
	var lo := _start_rect.position
	var hi := _start_rect.end
	var least := get_combined_minimum_size()
	if _edges.x > 0: hi.x = maxf(hi.x + delta.x, lo.x + least.x)
	if _edges.x < 0: lo.x = minf(lo.x + delta.x, hi.x - least.x)
	if _edges.y > 0: hi.y = maxf(hi.y + delta.y, lo.y + least.y)
	if _edges.y < 0: lo.y = minf(lo.y + delta.y, hi.y - least.y)
	position = lo
	size = hi - lo

func _fit() -> void:
	var vp := get_viewport_rect().size
	size = size.min((vp - Vector2(16, 16)).max(get_combined_minimum_size()))
	position = position.clamp(Vector2.ZERO, (vp - size).max(Vector2.ZERO))

func _exit_tree() -> void:
	geometry[window_key] = get_rect()
