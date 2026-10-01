class_name ChatBox
extends VBoxContainer

## Чат лобби и экрана закупки (item 14). Тот же разговор, что и в бою: сообщения едут тем
## же ключом "chat" со стороной отправителя, а подпись строит ПОЛУЧАТЕЛЬ (своя — «(you)»,
## item 3). История живёт в NetHandoff.chat_history, поэтому сказанное в лобби видно и на
## закупке, и в бою, пока игроки не разошлись в меню.

const K_CHAT := "chat"

var _label_of: Callable   # side -> подпись
var _my_side: Callable    # () -> своя сторона (-1 — ещё без места)
var _log: RichTextLabel
var _input: LineEdit

func _init(label_of: Callable, my_side: Callable) -> void:
	_label_of = label_of
	_my_side = my_side
	add_theme_constant_override("separation", 6)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(0, 110)
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 12)
	_log.add_theme_font_size_override("bold_font_size", 12)
	add_child(_log)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	_input = LineEdit.new()
	_input.placeholder_text = "Message…"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(func(_t: String) -> void: send())
	row.add_child(_input)
	var btn := Button.new()
	btn.text = "Send"
	btn.pressed.connect(send)
	row.add_child(btn)
	for rec: Dictionary in NetHandoff.chat_history:
		_show(rec)

func send() -> void:
	var text := _input.text.strip_edges()
	if text == "":
		return
	_input.text = ""
	var side: int = _my_side.call()
	var rec := {"side": side, "text": text}
	NetHandoff.chat_history.append(rec)
	_show(rec)
	if NetHandoff.session != null:
		NetHandoff.session.send({"k": K_CHAT, "side": side, "text": text})

## Сообщение из сети. true — это был чат (дальше его разбирать не нужно).
func receive(msg: Dictionary) -> bool:
	if str(msg.get("k", "")) != K_CHAT:
		return false
	var rec := {"side": int(msg.get("side", -1)), "text": str(msg.get("text", ""))}
	NetHandoff.chat_history.append(rec)
	_show(rec)
	return true

func _show(rec: Dictionary) -> void:
	var side := int(rec["side"])
	var who: String = _label_of.call(side) if side >= 0 else "Guest"
	_log.append_text("[b]%s:[/b] %s\n" % [escape(who), escape(str(rec["text"]))])

## Текст игрока в BBCode: «[» превращается в литерал, чтобы никто не мог вставить разметку.
static func escape(t: String) -> String:
	return t.replace("[", "[lb]")
