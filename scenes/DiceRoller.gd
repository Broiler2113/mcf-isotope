class_name DiceRoller
extends CenterContainer

## Экранная анимация кубиков (§1: анимация кубиков + текстовый лог).
## play(dice) прокручивает грани и приземляет финальные значения, затем finished.
## Броски проигрываются по одному (попадание, затем пробитие). Бросок защиты
## требует ручного нажатия «Бросок» защищающимся игроком.

signal finished
## Игрок нажал «Roll» (batch 12 #14) — бросок сейчас закрутится. Сцена боя по этому
## сигналу сообщает остальным, что можно открывать тот же бросок у них.
signal rolled
## Внешнее «можно» для броска, которого ждём от другого игрока (см. release()).
signal _released

## Хелпер оформления окон в стиле «2003 Steam» (preload, без class_name).
const SteamChrome = preload("res://src/ui/SteamChrome.gd")

const SPIN_STEPS := 16       # кол-во прокруток грани (больше = медленнее)
const SPIN_DELAY := 0.07     # пауза между прокрутками, сек
const LAND_PAUSE := 1.9      # пауза показа финального результата, сек (item 33: продлена,
                             # прежние 1.1 c не успевали прочесть; станет настройкой в item 24)

var _row: HBoxContainer
var _prompt: Label
var _roll_btn: Button

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	SteamChrome.apply_panel(panel)
	add_child(panel)
	# Оконная рамка в общем стиле интерфейса: шапка + тело (#61).
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Dice Roll"))
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(SteamChrome.pad(vbox, 16, 12))
	_prompt = Label.new()
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 18)
	_prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prompt.custom_minimum_size = Vector2(360, 0)
	_prompt.hide()
	vbox.add_child(_prompt)
	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override("separation", 8)
	vbox.add_child(_row)
	_roll_btn = Button.new()
	_roll_btn.text = "Roll"
	_roll_btn.custom_minimum_size = Vector2(120, 40)
	_roll_btn.hide()
	vbox.add_child(_roll_btn)
	hide()

## Чужой бросок дождался нажатия у своего хозяина (batch 12 #14): крутим.
func release() -> void:
	_released.emit()

## dice: [{"value": int, "good": bool, "tag": String}]
## manual = true → перед прокруткой ждём нажатия «Roll» (бросок защиты).
## speed — множитель темпа: 2.0 = вдвое быстрее (для заведомо успешных бросков 1+, #46).
## wait_remote = true → кнопки нет, но прокрутка не начнётся, пока не позовут release():
## бросок принадлежит другому игроку, и все ждут ЕГО нажатия (batch 12 #14).
func play(dice: Array, manual: bool = false, prompt: String = "", speed: float = 1.0,
		wait_remote: bool = false) -> void:
	var rate: float = maxf(speed, 0.1)
	for c in _row.get_children():
		c.queue_free()
	var labels: Array[Label] = []
	for _d in dice:
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 34)
		lbl.custom_minimum_size = Vector2(58, 68)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.text = "?"
		_row.add_child(lbl)
		labels.append(lbl)
	show()
	# Подсказку с бонусами/штрафами (#49) показываем всегда, пока крутится кубик.
	if prompt != "":
		_prompt.text = prompt
		_prompt.show()
	if manual:
		_roll_btn.show()
		await _roll_btn.pressed
		_roll_btn.hide()
		rolled.emit()
	elif wait_remote:
		await _released
	for _spin in maxi(1, int(round(SPIN_STEPS / rate))):
		for lbl in labels:
			lbl.text = str(randi_range(1, 6))
		await get_tree().create_timer(SPIN_DELAY).timeout
	for i in dice.size():
		labels[i].text = "%d\n%s" % [dice[i]["value"], dice[i]["tag"]]
		labels[i].add_theme_color_override(
			"font_color", Color(0.45, 1.0, 0.45) if dice[i]["good"] else Color(1.0, 0.5, 0.5)
		)
	await get_tree().create_timer(LAND_PAUSE / rate).timeout
	_prompt.hide()
	hide()
	finished.emit()
