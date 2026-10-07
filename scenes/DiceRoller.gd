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
## Поколение показа (batch 14): play(), начатый поверх ещё не докрученного (например,
## ждавшего нажатия ушедшего игрока), делает прежние подписи мусором. Старая корутина,
## проснувшись, обязана это заметить и тихо выйти — иначе «Invalid assignment of
## property 'text' … on a base object of type 'Nil'» на освобождённой подписи.
var _generation: int = 0

func play(dice: Array, manual: bool = false, prompt: String = "", speed: float = 1.0,
		wait_remote: bool = false) -> void:
	var rate: float = maxf(speed, 0.1)
	_generation += 1
	var my_gen := _generation
	for c in _row.get_children():
		c.queue_free()
	# Настоящие кубики (item 16): кувыркаются и подпрыгивают, грани сменяются, к концу
	# броска всё замедляется, и кубик ложится выпавшей гранью вверх.
	var dies: Array[DieView] = []
	for _d in dice:
		var dv := DieView.new()
		dv.custom_minimum_size = Vector2(66, 96)
		dv.value = randi_range(1, 6)
		_row.add_child(dv)
		dies.append(dv)
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
	if my_gen != _generation or not is_inside_tree():
		finished.emit()  # показ перебит новым — тот и докрутит; ждущих всё равно отпускаем
		return
	var steps := maxi(1, int(round(SPIN_STEPS / rate)))
	for spin in steps:
		# Выход из партии посреди броска забирает узел вместе со сценой (item 10).
		if not is_inside_tree():
			return
		var t := float(spin) / steps   # 0 → 1: кувырок затухает
		for i in dies.size():
			var dv := dies[i]
			if not is_instance_valid(dv):
				continue
			dv.value = randi_range(1, 6)
			dv.angle = (1.0 - t) * randf_range(-1.1, 1.1)
			dv.lift = (1.0 - t) * absf(sin(t * PI * 3.0 + i * 1.3)) * 22.0
			dv.queue_redraw()
		# Замедление к концу броска: как настоящий кубик, теряющий разгон.
		await get_tree().create_timer(SPIN_DELAY * (0.6 + t) / maxf(1.0, rate)).timeout
		if my_gen != _generation:
			finished.emit()
			return
	for i in dice.size():
		var dv := dies[i]
		if not is_instance_valid(dv):
			continue
		dv.value = int(dice[i]["value"])
		dv.angle = 0.0
		dv.lift = 0.0
		dv.landed = true
		dv.good = bool(dice[i]["good"])
		dv.tag = str(dice[i]["tag"])
		dv.queue_redraw()
	if not is_inside_tree():
		return
	await get_tree().create_timer(LAND_PAUSE / rate).timeout
	if my_gen != _generation:
		finished.emit()
		return
	_prompt.hide()
	hide()
	finished.emit()

## Один кубик (item 16): скруглённая кость цвета слоновой кости с точками, тенью на
## «столе», наклоном и подскоком во время броска. Упав, показывает обводку удачи (зелёная)
## или неудачи (красная) и подпись под собой.
class DieView extends Control:
	var value := 1
	var angle := 0.0
	var lift := 0.0
	var landed := false
	var good := false
	var tag := ""
	const SIZE := 46.0
	const PIPS := {
		1: [Vector2(0, 0)],
		2: [Vector2(-1, -1), Vector2(1, 1)],
		3: [Vector2(-1, -1), Vector2(0, 0), Vector2(1, 1)],
		4: [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)],
		5: [Vector2(-1, -1), Vector2(1, -1), Vector2(0, 0), Vector2(-1, 1), Vector2(1, 1)],
		6: [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 0), Vector2(1, 0), Vector2(-1, 1), Vector2(1, 1)],
	}
	func _draw() -> void:
		var c := Vector2(size.x * 0.5, SIZE * 0.5 + 14.0)
		# Тень на столе — тем меньше и бледнее, чем выше подскочил кубик.
		var k := clampf(1.0 - lift / 40.0, 0.4, 1.0)
		draw_set_transform(c + Vector2(0, SIZE * 0.55), 0.0, Vector2(1.0, 0.28))
		draw_circle(Vector2.ZERO, SIZE * 0.5 * k, Color(0, 0, 0, 0.35 * k))
		draw_set_transform(c - Vector2(0, lift), angle, Vector2.ONE)
		var r := Rect2(-SIZE * 0.5, -SIZE * 0.5, SIZE, SIZE)
		var body := StyleBoxFlat.new()
		body.bg_color = Color("#e9e3d2")
		body.set_corner_radius_all(9)
		body.set_border_width_all(2)
		body.border_color = Color("#b9b19a")
		body.shadow_color = Color(0, 0, 0, 0.25)
		body.shadow_size = 2
		if landed:
			body.border_color = Color("#4fbf4f") if good else Color("#d05050")
			body.set_border_width_all(3)
		draw_style_box(body, r)
		# Блик по верхней кромке — объём кости.
		draw_line(Vector2(-SIZE * 0.32, -SIZE * 0.4), Vector2(SIZE * 0.32, -SIZE * 0.4),
				Color(1, 1, 1, 0.55), 2.0)
		for p: Vector2 in PIPS.get(value, []):
			draw_circle(p * SIZE * 0.26, SIZE * 0.085, Color("#26221c"))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if landed and tag != "":
			var font := get_theme_default_font()
			draw_string(font, Vector2(0, size.y - 8), tag, HORIZONTAL_ALIGNMENT_CENTER, size.x,
					13, Color("#7fdc7f") if good else Color("#e88080"))
