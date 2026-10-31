class_name MapImageWindow
extends CanvasLayer

const Chrome = preload("res://src/ui/SteamChrome.gd")
var main: Node
var resolution: OptionButton
var lighting: CheckBox
var status: Label
var progress_bar: ProgressBar
var save_button: Button
var cancel_button: Button
var worker: MapImageExporter
var dialog: FileDialog
var closing := false

static func open(host: Node) -> MapImageWindow:
	if is_instance_valid(host._image_export_window): return host._image_export_window
	var window := MapImageWindow.new()
	window.main = host
	host._image_export_window = window
	host.add_child(window)
	return window

func _ready() -> void:
	layer = 90
	add_to_group("shortcut_modal")
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	Chrome.apply_panel(panel)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 420
	box.add_theme_constant_override("separation", 10)
	panel.add_child(Chrome.pad(box, 18, 16))
	box.add_child(Chrome.header_bar("Save Image", Chrome.close_x(_close)))
	var description := Label.new()
	description.text = "A detailed PNG of the whole map, without the interface.\nIncludes units and battle debris from your current view."
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(description)
	if main._view_resolver().visibility_limited():
		var fog := Label.new()
		fog.text = "Your current fog of war is preserved."
		box.add_child(fog)
	var row := HBoxContainer.new()
	box.add_child(row)
	var label := Label.new()
	label.text = "Resolution"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	resolution = OptionButton.new()
	var cells := Vector2i(main.state.grid.width, main.state.grid.height)
	for density: int in MapImageExporter.DENSITIES:
		var size := MapImageExporter.image_size(cells, density)
		if not MapImageExporter.fits(size): continue
		resolution.add_item("%d × %d" % [size.x, size.y], density)
	if resolution.item_count > 0: resolution.select(resolution.item_count - 1)
	row.add_child(resolution)
	lighting = CheckBox.new()
	lighting.text = "Dynamic lighting"
	lighting.button_pressed = Ui.dynamic_lighting
	box.add_child(lighting)
	status = Label.new()
	status.custom_minimum_size = Vector2(420, 44)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "Choose the image size and lighting, then save as PNG."
	box.add_child(status)
	progress_bar = ProgressBar.new()
	progress_bar.max_value = 1.0
	progress_bar.step = 0.001
	progress_bar.visible = false
	box.add_child(progress_bar)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(actions)
	cancel_button = Button.new()
	cancel_button.text = "Cancel export"
	cancel_button.visible = false
	cancel_button.pressed.connect(_cancel)
	actions.add_child(cancel_button)
	save_button = Button.new()
	save_button.text = "Save PNG…"
	save_button.disabled = resolution.item_count == 0
	save_button.pressed.connect(_choose_path)
	actions.add_child(save_button)
	if resolution.item_count == 0: status.text = "This map is too large to export as one detailed image."
	Ui.theme_canvas_layers()
	save_button.grab_focus()

func _choose_path() -> void:
	if worker != null or is_instance_valid(dialog): return
	dialog = FileDialog.new()
	dialog.title = "Save Map Image"
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.filters = PackedStringArray(["*.png ; PNG image"])
	dialog.current_file = "map-%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		dialog.queue_free()
		dialog = null
		_start(path if path.to_lower().ends_with(".png") else path + ".png"))
	dialog.canceled.connect(func() -> void:
		dialog.queue_free()
		dialog = null)
	dialog.popup_centered_ratio(0.7)

func _start(path: String) -> void:
	if worker != null: return
	save_button.disabled = true
	resolution.disabled = true
	lighting.disabled = true
	cancel_button.visible = true
	cancel_button.disabled = false
	progress_bar.visible = true
	progress_bar.value = 0.0
	worker = MapImageExporter.new()
	add_child(worker)
	worker.progress.connect(func(value: float, message: String) -> void:
		progress_bar.value = value
		if not worker.cancelled: status.text = message)
	worker.completed.connect(func(saved: String, error: String) -> void:
		status.text = "Saved: " + saved if error.is_empty() else error
		worker.queue_free()
		worker = null
		save_button.disabled = false
		resolution.disabled = false
		lighting.disabled = false
		cancel_button.visible = false
		if closing: queue_free())
	worker.run(main, path, resolution.get_selected_id(), lighting.button_pressed)

func _cancel() -> void:
	if worker == null: return
	worker.cancel()
	cancel_button.disabled = true
	status.text = "Canceling export…"

func _close() -> void:
	if worker != null:
		closing = true
		_cancel()
	else:
		queue_free()

func _input(event: InputEvent) -> void:
	if is_instance_valid(dialog) and dialog.visible: return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		var modals := get_tree().get_nodes_in_group("shortcut_modal")
		if not modals.is_empty() and modals.back() == self:
			get_viewport().set_input_as_handled()
			_close()

func _exit_tree() -> void:
	if is_instance_valid(main): main._image_export_window = null
