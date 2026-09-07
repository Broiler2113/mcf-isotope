class_name Starfield
extends Control

## Параллакс-фон главного меню (M13, item 35). Раньше за меню стоял один плоский
## ColorRect — теперь три слоя звёзд, плывущих с разной скоростью: дальние еле-еле,
## ближние заметно. Разная скорость и есть весь параллакс — глубина берётся из неё,
## а не из перспективы.
##
## Каждый слой — ОДНА плитка-текстура, растиражированная на весь экран, и двигается
## не содержимое, а положение прямоугольника. Поэтому кадр стоит трёх спрайтов
## независимо от числа звёзд: рисовать по звезде за кадр (их тут под две сотни) было
## бы на порядок дороже ровно ради того же результата.
##
## Звёзды раскладывает генератор с ФИКСИРОВАННЫМ зерном: меню обязано выглядеть
## одинаково при каждом запуске, иначе игрок каждый раз видит «другую» игру. Кубики
## партии (DiceService) здесь не при чём и не трогаются — это чистая косметика.

## Слои от дальнего к ближнему: сколько звёзд на плитку, скорость (пикселей в
## секунду), сторона звезды в пикселях и яркость.
const LAYERS := [
	{"stars": 560, "speed": 5.0, "size": 1, "alpha": 0.40},
	{"stars": 280, "speed": 13.0, "size": 1, "alpha": 0.68},
	{"stars": 96, "speed": 28.0, "size": 2, "alpha": 1.0},
]
## Сторона плитки. Степень двойки — чтобы тиражирование ложилось без щелей. Плитка
## намеренно крупная: на 256 пикселях один и тот же узор укладывался на экран трижды
## по ширине, и повтор читался как обои. Три слоя с разными скоростями довершают дело —
## совпадение узоров разъезжается, и рисунок не повторяется вовсе.
const TILE := 512
const SEED := 20260907
## Куда «летит» камера. Наклонный дрейф читается как движение; строго горизонтальный
## выглядит как едущая лента.
const DRIFT := Vector2(-1.0, 0.34)

## Оттенки звёзд: холодный белый, голубоватый, тёплый. Разноцветное небо живее
## одноцветного, но разброс намеренно маленький — это фон, а не витраж.
const TINTS := [
	Color(1.0, 1.0, 1.0), Color(0.78, 0.86, 1.0), Color(1.0, 0.92, 0.78),
]

var _layers: Array = []
var _viewport_size: Vector2 = Vector2.ZERO

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var base := TextureRect.new()
	base.texture = _sky_gradient()
	base.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	base.stretch_mode = TextureRect.STRETCH_SCALE
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(base)

	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for cfg: Dictionary in LAYERS:
		var rect := TextureRect.new()
		rect.texture = _star_tile(rng, int(cfg["stars"]), int(cfg["size"]),
				float(cfg["alpha"]))
		rect.stretch_mode = TextureRect.STRETCH_TILE
		# Тиражирование в GL-compatibility включается явно, иначе плитка растянется.
		rect.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_layers.append({"rect": rect, "speed": float(cfg["speed"]),
				"offset": Vector2.ZERO})
	_fit()
	set_process(true)

func _process(delta: float) -> void:
	if get_viewport_rect().size != _viewport_size:
		_fit()
	var dir := DRIFT.normalized()
	for layer: Dictionary in _layers:
		var offset: Vector2 = layer["offset"] + dir * float(layer["speed"]) * delta
		# Смещение живёт внутри одной плитки: сдвиг на целую плитку неотличим от нуля,
		# а без сворачивания координата за долгую сессию доросла бы до потери точности.
		layer["offset"] = Vector2(fposmod(offset.x, float(TILE)),
				fposmod(offset.y, float(TILE)))
		var rect: TextureRect = layer["rect"]
		rect.position = Vector2(layer["offset"]) - Vector2(TILE, TILE)

## Подогнать слои под окно. Каждый на плитку больше экрана с каждой стороны — запас
## под сдвиг, иначе у края появлялась бы пустая полоса.
func _fit() -> void:
	_viewport_size = get_viewport_rect().size
	for layer: Dictionary in _layers:
		(layer["rect"] as TextureRect).size = _viewport_size + Vector2(TILE, TILE) * 2.0

## Плитка со звёздами. Координаты сворачиваются по модулю плитки, поэтому звезда у
## края продолжается на соседней — шва не видно.
func _star_tile(rng: RandomNumberGenerator, count: int, size: int,
		alpha: float) -> ImageTexture:
	var img := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for _i in count:
		var x := rng.randi_range(0, TILE - 1)
		var y := rng.randi_range(0, TILE - 1)
		var tint: Color = TINTS[rng.randi_range(0, TINTS.size() - 1)]
		# Яркость каждой звезды своя: ровное поле одинаковых точек читается как шум.
		var col := Color(tint.r, tint.g, tint.b, alpha * rng.randf_range(0.35, 1.0))
		for dy in size:
			for dx in size:
				img.set_pixel((x + dx) % TILE, (y + dy) % TILE, col)
	return ImageTexture.create_from_image(img)

## Небо за звёздами: сверху чуть синее, снизу почти чёрное.
func _sky_gradient() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.055, 0.065, 0.105))
	gradient.set_color(1, Color(0.015, 0.018, 0.032))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	tex.width = 8
	tex.height = 128
	return tex
