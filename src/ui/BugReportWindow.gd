class_name BugReportWindow
extends CanvasLayer

## «Report a Bug» (0.12, решение владельца: отчёты уходят на этот сервер, рядом с ретранслятором,
## tools/bugs/isotope_bugs.py). Окно набора: что случилось, как связаться (по желанию), и
## галочки — что приложить: снимок экрана (снят ДО окна), журнал движка (GameLog), журнал
## боя и запись матча. Ничего сверх отмеченного не отправляется.

const SteamChrome = preload("res://src/ui/SteamChrome.gd")
const ENDPOINT := "http://103.86.177.137:8651/report"
const TIMEOUT := 40.0
## Больше этого запись матча не везём: сервер её не примет, а отчёт не должен падать из-за неё.
const MAX_REPLAY := 7_500_000
const SHOT_MAX_W := 1600

var endpoint := ENDPOINT
var _shot_png := PackedByteArray()
var _combat_log := ""
var _replay_json := ""
var _scene := ""

var _text: TextEdit
var _contact: LineEdit
var _send_shot: CheckBox
var _send_log: CheckBox
var _send_match: CheckBox
var _status: Label
var _send_btn: Button
var _close_btn: Button
var _http: HTTPRequest

## Открыть окно отчёта. combat_log и replay_json — из боя (в меню и редакторе их нет).
static func open(host: Node, combat_log := "", replay_json := "") -> BugReportWindow:
	var w := BugReportWindow.new()
	# Снимок — до того, как окно нарисуется: на нём нужна игра, а не сам диалог.
	var img := host.get_viewport().get_texture().get_image()
	if img != null and not img.is_empty():
		if img.get_width() > SHOT_MAX_W:
			img.resize(SHOT_MAX_W, int(img.get_height() * float(SHOT_MAX_W) / img.get_width()),
					Image.INTERPOLATE_BILINEAR)
		w._shot_png = img.save_png_to_buffer()
	w._combat_log = combat_log
	w._replay_json = replay_json if replay_json.length() <= MAX_REPLAY else ""
	var scene := host.get_tree().current_scene
	w._scene = scene.name if scene != null else ""
	host.add_child(w)
	return w

func _ready() -> void:
	layer = 95
	add_to_group("shortcut_modal")
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT
	_http.request_completed.connect(_on_done)
	add_child(_http)
	_build()

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var win := PanelContainer.new()
	SteamChrome.apply_panel(win)
	win.custom_minimum_size = Vector2(600, 0)
	center.add_child(win)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	win.add_child(col)
	col.add_child(SteamChrome.header_bar("Report a Bug"))

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	col.add_child(SteamChrome.pad(body, 16, 12))

	var what := SteamChrome.group_box("What happened?")
	body.add_child(what)
	var intro := Label.new()
	intro.text = "What were you doing, what did you expect, and what happened instead?"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 12)
	what.body.add_child(intro)
	_text = TextEdit.new()
	_text.custom_minimum_size = Vector2(540, 150)
	_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text.placeholder_text = "Example: the tank drove onto a mine at the north gate and the game froze."
	_text.text_changed.connect(_refresh_send)
	what.body.add_child(_text)
	_contact = LineEdit.new()
	_contact.placeholder_text = "Contact (optional) — name, Discord or email, if you'd like a reply"
	_contact.max_length = 200
	what.body.add_child(_contact)

	var attach := SteamChrome.group_box("Attach")
	body.add_child(attach)
	_send_shot = _check(attach.body, "A screenshot of the game", not _shot_png.is_empty())
	_send_log = _check(attach.body, "The game's technical log (errors and warnings)", true)
	var has_match := _combat_log != "" or _replay_json != ""
	_send_match = _check(attach.body, "This match's combat log and replay", has_match)
	_send_match.disabled = not has_match
	if not has_match:
		_send_match.tooltip_text = "Only available during a battle."
	var privacy := Label.new()
	privacy.text = "Reports go to the MCF Isotope team's server. Only what is ticked above, the text you write and the game version are sent."
	privacy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	privacy.custom_minimum_size = Vector2(540, 0)
	privacy.add_theme_font_size_override("font_size", 11)
	privacy.modulate = Color(0.72, 0.75, 0.82)
	body.add_child(privacy)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	col.add_child(SteamChrome.pad(bottom, 16, 12))
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	bottom.add_child(_status)
	_close_btn = Button.new()
	_close_btn.text = "Cancel"
	_close_btn.custom_minimum_size = Vector2(100, 0)
	_close_btn.pressed.connect(queue_free)
	bottom.add_child(_close_btn)
	_send_btn = Button.new()
	_send_btn.text = "Send Report"
	_send_btn.custom_minimum_size = Vector2(130, 0)
	_send_btn.pressed.connect(_send)
	bottom.add_child(_send_btn)
	_refresh_send()
	Ui.theme_canvas_layers()
	_text.grab_focus.call_deferred()

func _check(parent: Control, text: String, on: bool) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.button_pressed = on
	parent.add_child(cb)
	return cb

func _refresh_send() -> void:
	_send_btn.disabled = _text.text.strip_edges() == "" or _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED

## То, что уходит на сервер: только отмеченное, текст и версия.
func payload() -> Dictionary:
	var doc := {
		"description": _text.text.strip_edges(),
		"contact": _contact.text.strip_edges(),
		"version": str(ProjectSettings.get_setting("application/config/version", "dev")),
		"os": "%s %s · %s" % [OS.get_name(), OS.get_version(), RenderingServer.get_video_adapter_name()],
		"scene": _scene,
	}
	if _send_shot.button_pressed and not _shot_png.is_empty():
		doc["screenshot"] = Marshalls.raw_to_base64(_shot_png)
	if _send_log.button_pressed:
		doc["log"] = GameLog.text()
	if _send_match.button_pressed:
		if _combat_log != "":
			doc["combat_log"] = _combat_log
		if _replay_json != "":
			doc["replay"] = _replay_json
	return doc

func _send() -> void:
	if _text.text.strip_edges() == "":
		_status.text = "Please describe what happened first."
		return
	var err := _http.request(endpoint, ["Content-Type: application/json"], HTTPClient.METHOD_POST,
			JSON.stringify(payload()))
	if err != OK:
		_status.text = "Could not send the report (%s)." % error_string(err)
		return
	_send_btn.disabled = true
	_status.text = "Sending…"

func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var reply: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
	if result != HTTPRequest.RESULT_SUCCESS:
		_status.text = "Could not reach the report server — check your connection and try again."
	elif code == 200 and reply is Dictionary and bool(reply.get("ok", false)):
		_status.text = "Thank you! Report #%s was sent." % str(reply.get("id", ""))
		_close_btn.text = "Close"
		_text.editable = false
		_send_btn.visible = false
		return
	elif reply is Dictionary and reply.has("error"):
		_status.text = str(reply["error"])
	else:
		_status.text = "The report server answered with an error (%d)." % code
	_refresh_send()

func _unhandled_key_input(event: InputEvent) -> void:
	if Keybinds.matches(event, "game_cancel") or Keybinds.matches(event, "editor_cancel"):
		get_viewport().set_input_as_handled()
		queue_free()
