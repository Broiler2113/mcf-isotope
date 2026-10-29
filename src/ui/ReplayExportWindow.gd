class_name ReplayExportWindow
extends CanvasLayer

const SteamChrome = preload("res://src/ui/SteamChrome.gd")

var main: Node
var speed: OptionButton
var resolution: OptionButton
var fps: OptionButton
var status: Label
var progress: ProgressBar
var export_button: Button
var cancel_button: Button
var worker: ReplayVideoExporter
var executable := ""
const SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
const RATES := [24, 30, 60]
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0]

static func open(host: Node) -> ReplayExportWindow:
	var window := ReplayExportWindow.new()
	window.main = host
	host._replay_playing = false
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
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 420
	box.add_theme_constant_override("separation", 10)
	panel.add_child(SteamChrome.pad(box, 18, 16))
	box.add_child(SteamChrome.header_bar("Export 2D replay as MP4", SteamChrome.close_x(_close)))
	var text := Label.new()
	text.text = "Whole battlefield, without interface or animation delays.\nAt 1x, the video shows 30 recorded actions per second."
	box.add_child(text)
	speed = _choice(box, "Speed", SPEEDS.map(func(value: float) -> String: return str(value) + "x"))
	speed.select(2)
	resolution = _choice(box, "Resolution", ["1280 × 720", "1920 × 1080", "2560 × 1440", "3840 × 2160"])
	resolution.select(1)
	fps = _choice(box, "Frame rate", ["24 fps", "30 fps", "60 fps"])
	fps.select(1)
	var select := Button.new()
	select.text = "Select FFmpeg executable"
	select.pressed.connect(_select_encoder)
	box.add_child(select)
	executable = ReplayVideoEncoder.find_ffmpeg(Ui.ffmpeg_path)
	status = Label.new()
	status.custom_minimum_size = Vector2(420, 55)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "FFmpeg ready." if not executable.is_empty() else "FFmpeg is required. Install it or select its executable."
	box.add_child(status)
	progress = ProgressBar.new()
	progress.max_value = 1
	progress.step = 0.001
	box.add_child(progress)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)
	export_button = Button.new()
	export_button.text = "Export MP4…"
	export_button.disabled = executable.is_empty()
	export_button.pressed.connect(_choose_output)
	row.add_child(export_button)
	# Only while exporting; the window's ✕ closes it (issues-14 #12).
	cancel_button = Button.new()
	cancel_button.text = "Cancel export"
	cancel_button.visible = false
	cancel_button.pressed.connect(_close)
	row.add_child(cancel_button)
	Ui.theme_canvas_layers()

func _choice(box: VBoxContainer, label: String, values: Array) -> OptionButton:
	var row := HBoxContainer.new()
	box.add_child(row)
	var text := Label.new()
	text.text = label
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	var choice := OptionButton.new()
	for value: String in values: choice.add_item(value)
	row.add_child(choice)
	return choice

func _select_encoder() -> void:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = "Select FFmpeg"
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		executable = path
		Ui.ffmpeg_path = path
		Ui._save_settings()
		export_button.disabled = false
		status.text = "FFmpeg selected."
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered_ratio(0.7)

func _choose_output() -> void:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.filters = PackedStringArray(["*.mp4 ; MP4 video"])
	dialog.current_file = "replay.mp4"
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		dialog.queue_free()
		_start(path if path.to_lower().ends_with(".mp4") else path + ".mp4"))
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered_ratio(0.7)

func _start(path: String) -> void:
	if worker != null: return
	export_button.disabled = true
	speed.disabled = true
	resolution.disabled = true
	fps.disabled = true
	cancel_button.visible = true
	status.text = "Rendering replay…"
	worker = ReplayVideoExporter.new()
	add_child(worker)
	worker.progress.connect(func(value: float) -> void:
		progress.value = value
		status.text = "Encoding video…" if value >= 1 else "Rendering replay: %d%%" % int(value * 100))
	worker.completed.connect(func(saved: String, error: String) -> void:
		status.text = "Saved: " + saved if error.is_empty() else error
		worker.queue_free()
		worker = null
		export_button.disabled = false
		speed.disabled = false
		resolution.disabled = false
		fps.disabled = false
		cancel_button.visible = false)
	worker.run(main.replay.data, path, SIZES[resolution.selected], RATES[fps.selected], SPEEDS[speed.selected], executable)

func _close() -> void:
	if worker != null:
		worker.cancel()
		status.text = "Cancelling export…"
	else: queue_free()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		var modals := get_tree().get_nodes_in_group("shortcut_modal")
		if not modals.is_empty() and modals.back() == self:
			get_viewport().set_input_as_handled()
			_close()
