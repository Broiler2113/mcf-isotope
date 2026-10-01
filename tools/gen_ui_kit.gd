extends SceneTree

## Хромировка интерфейса по набору «MCF: Alert! UI kit» (batch «team session», item 23):
## окна, шапки, кнопки, вкладки, поля, ползунки, полосы прокрутки — 9-слайсы в
## res://interface_textures. Цвета, фаски и градиенты взяты из CSS набора как есть
## (фаска: верх и лево светлее, низ и право темнее; кнопки и шапки — вертикальный
## градиент). Части, окрашенные акцентом (галочка, радио, заливка прогресса, выделение),
## тема строит сама при запуске — от выбранного акцента (UiTheme.PALETTES), а здесь
## для них пишется зелёный вариант по умолчанию, чтобы игрок мог подменить файл.
##
## Запуск из корня проекта:  godot --headless --script res://tools/gen_ui_kit.gd
## затем `godot --headless --import`.

const OUT := "res://interface_textures/"
const UI_THEME = preload("res://src/ui/UiTheme.gd")

func _initialize() -> void:
	# Окно (.steam-window): тело #2e2e2e, фаска 2 px.
	_save("panel", _box(32, 32, [Color8(46, 46, 46)], 2,
			Color8(106, 106, 106), Color8(106, 106, 106), Color8(30, 30, 30), Color8(30, 30, 30)))
	# Групповое окошко (.group-box): #2a2a2a, фаска 1 px #6a6a6a / #1e1e1e.
	_save("group", _box(32, 32, [Color8(42, 42, 42)], 1,
			Color8(106, 106, 106), Color8(106, 106, 106), Color8(30, 30, 30), Color8(30, 30, 30)))
	# Утопленное поле (списки, подсказки, прокрутка).
	_save("panel_sunken", _box(32, 32, [Color8(30, 30, 30)], 1,
			Color8(10, 10, 10), Color8(10, 10, 10), Color8(74, 74, 74), Color8(74, 74, 74)))
	# Шапка окна (.window-title): градиент #4e4e4e → #2c2c2c, сверху #6a6a6a, снизу #1a1a1a.
	_save("header", _box(32, 32, [Color8(78, 78, 78), Color8(44, 44, 44)], 1,
			Color8(106, 106, 106), Color8(78, 78, 78), Color8(26, 26, 26), Color8(44, 44, 44)))
	# Кнопка (.btn): #5a5a5a → #353535, кант #8a8a8a/#7a7a7a, низ и право #1a1a1a.
	_save("button_normal", _btn([Color8(90, 90, 90), Color8(53, 53, 53)],
			Color8(138, 138, 138), Color8(122, 122, 122), Color8(26, 26, 26), Color8(26, 26, 26)))
	_save("button_hover", _btn([Color8(104, 104, 104), Color8(62, 62, 62)],
			Color8(154, 154, 154), Color8(138, 138, 138), Color8(26, 26, 26), Color8(26, 26, 26)))
	# Нажатая (.btn:active): градиент наоборот и фаска вдавлена.
	_save("button_pressed", _btn([Color8(42, 42, 42), Color8(58, 58, 58)],
			Color8(26, 26, 26), Color8(26, 26, 26), Color8(106, 106, 106), Color8(106, 106, 106)))
	_save("button_disabled", _btn([Color8(58, 58, 58), Color8(44, 44, 44)],
			Color8(78, 78, 78), Color8(74, 74, 74), Color8(30, 30, 30), Color8(30, 30, 30)))
	# Выпадающий список (select): утопленный #2a2a2a.
	_save("select_normal", _box(32, 32, [Color8(42, 42, 42)], 1,
			Color8(26, 26, 26), Color8(26, 26, 26), Color8(106, 106, 106), Color8(106, 106, 106)))
	_save("select_hover", _box(32, 32, [Color8(52, 52, 52)], 1,
			Color8(26, 26, 26), Color8(26, 26, 26), Color8(122, 122, 122), Color8(122, 122, 122)))
	# Вкладки: активная #5a5a5a → #3a3a3a, неактивная #454545 → #2a2a2a, без нижней кромки.
	_save("tab_active", _tab([Color8(90, 90, 90), Color8(58, 58, 58)], Color8(138, 138, 138),
			Color8(122, 122, 122), Color8(42, 42, 42)))
	_save("tab_inactive", _tab([Color8(69, 69, 69), Color8(42, 42, 42)], Color8(106, 106, 106),
			Color8(90, 90, 90), Color8(42, 42, 42)))
	# Поле ввода (.text-input).
	_save("field", _box(32, 32, [Color8(30, 30, 30)], 1,
			Color8(10, 10, 10), Color8(10, 10, 10), Color8(106, 106, 106), Color8(106, 106, 106)))
	# Прогресс: подложка — утопленная #1e1e1e.
	_save("progress_bg", _box(32, 18, [Color8(30, 30, 30)], 1,
			Color8(10, 10, 10), Color8(10, 10, 10), Color8(106, 106, 106), Color8(106, 106, 106)))
	# Ползунок: рельс 6 px #1e1e1e, ручка 14×18 #6a6a6a → #3a3a3a.
	_save("slider_track", _box(16, 6, [Color8(30, 30, 30)], 1,
			Color8(10, 10, 10), Color8(10, 10, 10), Color8(74, 74, 74), Color8(74, 74, 74)))
	_save("slider_grabber", _grabber())
	# Полоса прокрутки — в том же духе: утопленный жёлоб и выпуклый бегунок.
	_save("scroll_track", _box(12, 32, [Color8(30, 30, 30)], 1,
			Color8(10, 10, 10), Color8(10, 10, 10), Color8(74, 74, 74), Color8(74, 74, 74)))
	_save("scroll_grabber", _box(12, 32, [Color8(90, 90, 90), Color8(58, 58, 58)], 1,
			Color8(138, 138, 138), Color8(122, 122, 122), Color8(26, 26, 26), Color8(26, 26, 26), true))
	_save("scroll_grabber_hl", _box(12, 32, [Color8(110, 110, 110), Color8(70, 70, 70)], 1,
			Color8(154, 154, 154), Color8(138, 138, 138), Color8(26, 26, 26), Color8(26, 26, 26), true))
	# Флажок: пустой утопленный квадрат 16×16; отмеченный и радио тема рисует сама.
	_save("check_off", _check(false))
	_save("arrow_up", _arrow(true))
	_save("arrow_down", _arrow(false))
	# Акцентные части по умолчанию (зелёный) — тема перерисует их под выбранный акцент.
	var ui = UI_THEME.new()
	var pal: Dictionary = UI_THEME.PALETTES["green"]
	_save("check_on", ui.make_check(pal, true))
	_save("progress_fill", ui.make_fill(pal))
	_save("selection", ui.make_selection(pal))
	ui.free()
	print("ui kit written to ", OUT)
	quit()

func _save(name: String, img: Image) -> void:
	img.save_png(OUT + name + ".png")

## Прямоугольник w×h: заливка (один цвет или вертикальный градиент из двух) и фаска
## толщиной bw: top/left/bottom/right — цвета сторон. horizontal — градиент слева направо.
func _box(w: int, h: int, fill: Array, bw: int, top: Color, left: Color, bottom: Color,
		right: Color, horizontal := false) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var c: Color = fill[0]
			if fill.size() > 1:
				var k := float(x) / maxf(1.0, w - 1) if horizontal else float(y) / maxf(1.0, h - 1)
				c = (fill[0] as Color).lerp(fill[1], k)
			img.set_pixel(x, y, c)
	for i in bw:
		for x in w:
			img.set_pixel(x, i, top)
			img.set_pixel(x, h - 1 - i, bottom)
		for y in range(i, h - i):
			img.set_pixel(i, y, left)
			img.set_pixel(w - 1 - i, y, right)
	return img

## Кнопка: как _box с кантом в 1 px, плюс внутренний блик сверху rgba(255,255,255,.08).
func _btn(fill: Array, top: Color, left: Color, bottom: Color, right: Color) -> Image:
	var img := _box(32, 32, fill, 1, top, left, bottom, right)
	for x in range(1, 31):
		img.set_pixel(x, 1, img.get_pixel(x, 1).lerp(Color.WHITE, 0.08))
	return img

## Вкладка: градиент, верхний и боковые канты, низ открыт; углы сверху скруглены (4 px).
func _tab(fill: Array, top: Color, left: Color, right: Color) -> Image:
	var img := _box(32, 32, fill, 1, top, left, fill[1], right)
	for y in 3:
		for x in 3 - y:
			img.set_pixel(x, y, Color(0, 0, 0, 0))
			img.set_pixel(31 - x, y, Color(0, 0, 0, 0))
	return img

func _grabber() -> Image:
	var img := Image.create(14, 19, false, Image.FORMAT_RGBA8)
	var body := _box(14, 18, [Color8(106, 106, 106), Color8(58, 58, 58)], 1,
			Color8(138, 138, 138), Color8(122, 122, 122), Color8(26, 26, 26), Color8(26, 26, 26))
	img.blit_rect(body, Rect2i(0, 0, 14, 18), Vector2i.ZERO)
	for x in 14:
		img.set_pixel(x, 18, Color(0, 0, 0, 0.8))   # тень 0 1px 2px #000
	return img

func _check(_on: bool) -> Image:
	return _box(16, 16, [Color8(30, 30, 30)], 1,
			Color8(10, 10, 10), Color8(10, 10, 10), Color8(106, 106, 106), Color8(106, 106, 106))

func _arrow(up: bool) -> Image:
	var img := Image.create(10, 6, false, Image.FORMAT_RGBA8)
	for y in 5:
		var row := y if up else 4 - y
		for x in range(4 - row, 6 + row):
			img.set_pixel(x, y, Color8(208, 208, 208))
	return img
