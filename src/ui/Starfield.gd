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
## Доля панорамы доски, которую забирает слой (0.9.3): дальний почти стоит, ближний почти
## едет вместе с картой. Порядок — как у LAYERS, от дальнего к ближнему.
const DEPTH := [0.05, 0.12, 0.26]

## Параллакс за ДОСКОЙ боя (0.9.3): клетки космоса больше не рисуются плиткой, и в
## прорехах видно это небо — то же, что в главном меню. Оно сдвигается вслед за панорамой
## доски, отсюда и глубина. В меню доски нет, и слои просто дрейфуют сами.
##
## camera — панорама доски в точках экрана (Main.pan); drift — плывёт ли фон сам по себе.
var camera: Vector2 = Vector2.ZERO
var drift: bool = true
## Share of LAYERS' stars to scatter. Skies behind a board follow Settings → Display
## (issues-13 #2: the full menu sky was too busy there); the menu keeps every star.
var density: float = 1.0
var follows_setting := false

## Оттенки звёзд: холодный белый, голубоватый, тёплый. Разноцветное небо живее
## одноцветного, но разброс намеренно маленький — это фон, а не витраж.
const TINTS := [
	Color(1.0, 1.0, 1.0), Color(0.78, 0.86, 1.0), Color(1.0, 0.92, 0.78),
]

## One full-screen pass draws the black sky and all three layers (zoomed-out FPS, 2026-10-28):
## five stacked full-screen rects (black, a black gradient, three star tiles) cost the
## owner's 1,400-unit station save half its frame on a software renderer.
const SHADER := """
shader_type canvas_item;
uniform sampler2D l0 : repeat_enable, filter_nearest;
uniform sampler2D l1 : repeat_enable, filter_nearest;
uniform sampler2D l2 : repeat_enable, filter_nearest;
uniform vec2 o0;
uniform vec2 o1;
uniform vec2 o2;
uniform vec2 px;
uniform float tile;
void fragment() {
	vec2 p = UV * px;
	vec3 c = vec3(0.0);
	vec4 s = texture(l0, (p - o0) / tile);
	c = mix(c, s.rgb, s.a);
	s = texture(l1, (p - o1) / tile);
	c = mix(c, s.rgb, s.a);
	s = texture(l2, (p - o2) / tile);
	c = mix(c, s.rgb, s.a);
	COLOR = vec4(c, 1.0);
}
"""

var _layers: Array = []
var _viewport_size: Vector2 = Vector2.ZERO
## Размер выставляется в _fit() ЧИСЛОМ, а не привязками: за доской боя небо висит на голом
## CanvasLayer, где прямоугольник родителя нулевой.
var _sky: ColorRect = null
var _mat: ShaderMaterial = null

func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sky = ColorRect.new()
	_sky.color = Color(0, 0, 0)
	_sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	_mat.shader = shader
	_mat.set_shader_parameter("tile", float(TILE))
	_sky.material = _mat
	add_child(_sky)
	for cfg: Dictionary in LAYERS:
		_layers.append({"speed": float(cfg["speed"]), "offset": Vector2.ZERO})
	if follows_setting: density = Ui.star_density
	_build_tiles()
	_fit()
	set_process(true)

func _build_tiles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in LAYERS.size():
		var cfg: Dictionary = LAYERS[i]
		_mat.set_shader_parameter("l%d" % i, _star_tile(rng, int(float(cfg["stars"]) * density), int(cfg["size"]),
				float(cfg["alpha"])))

func _process(delta: float) -> void:
	if follows_setting and density != Ui.star_density:
		density = Ui.star_density
		_build_tiles()
	if get_viewport_rect().size != _viewport_size:
		_fit()
	var dir := DRIFT.normalized()
	for i in _layers.size():
		var layer: Dictionary = _layers[i]
		var offset: Vector2 = layer["offset"]
		if drift:
			offset += dir * float(layer["speed"]) * delta
		# Смещение живёт внутри одной плитки: сдвиг на целую плитку неотличим от нуля,
		# а без сворачивания координата за долгую сессию доросла бы до потери точности.
		var wrapped := Vector2(fposmod(offset.x, float(TILE)), fposmod(offset.y, float(TILE)))
		layer["offset"] = wrapped
		# Панорама доски входит сюда долей DEPTH — тоже свёрнутой по плитке.
		var par := camera * float(DEPTH[i] if i < DEPTH.size() else 0.0)
		_mat.set_shader_parameter("o%d" % i, Vector2(fposmod(wrapped.x + par.x, float(TILE)),
				fposmod(wrapped.y + par.y, float(TILE))))

func _fit() -> void:
	_viewport_size = get_viewport_rect().size
	size = _viewport_size
	if _sky != null:
		_sky.size = _viewport_size
		_mat.set_shader_parameter("px", _viewport_size)

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
