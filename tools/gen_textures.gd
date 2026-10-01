extends SceneTree

## Текстуры клеток (items 9/20/24 + «64×64, брутализм, без повторяющегося рисунка»).
## Рисуются кодом: у каждой плитки есть исходник, и тон, шум или размер меняются правкой
## числа. Запуск из корня проекта:
##   godot --headless --script res://tools/gen_textures.gd
## затем `godot --headless --import`. PNG ложатся в res://textures (их подхватывает Sprites;
## файлы игрока в user://textures по-прежнему важнее).
##
## Как устроено, чтобы на поле не было «сетки из одинаковых квадратиков»:
##   * каждый материал БЕСШОВНЫЙ — шум считается на решётке, свёрнутой в тор, и правый край
##     плитки продолжает левый, нижний — верхний. Стена, пол, кирпич идут сплошной тканью;
##   * у материала VARIANTS вариантов: общий бесшовный фон и свои детали (пятна, трещины,
##     сучки, кратеры), убранные от краёв, — края у всех вариантов одинаковы, и любые два
##     встают рядом без шва. Вариант клетки выбирает TerrainTiles по хешу координаты, так
##     что одинаковые плитки не выстраиваются в узор.
##
## Форматы: плитка — лента вариантов N×1 (T·N × T); лист автотайла — столбик вариантов,
## у каждого 4×4 плитки по маске соседей N·1 + E·2 + S·4 + W·8 (4T × 4T·N).
##
## Стиль — брутализм: сырой бетон с отпечатками опалубки и следами стяжек, тяжёлая сталь,
## тёмный кирпич, глухие массы с толстой фаской и глубокой тенью, приглушённые цвета.

const T := 64
const VARIANTS := 6
const OUT := "res://textures/"

func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	# --- Пол: общий и по окружениям (item 24) ---
	_strip("floor", _steel_deck)
	_strip("floor_station", _steel_deck)
	_strip("floor_bunker", _poured_concrete)
	_strip("floor_town", _street)
	_strip("floor_field", _dirt)
	_strip("floor_asteroid", _regolith)
	_strip("floor_grass", _grass)
	_strip("floor_space", _starfield)
	_strip("floor_destroyed", _rubble)
	_strip("floor_epicenter", _scorch)
	_strip("bedrock", _bedrock)
	_save("fire", _fire())
	# --- Стены и прочие стыкующиеся объекты ---
	_sheet("wall", _board_concrete, Color8(128, 126, 120), 6)
	_sheet("wall_field", _board_concrete, Color8(128, 126, 120), 6)
	_sheet("wall_station", _bulkhead, Color8(118, 126, 134), 6)
	_sheet("wall_bunker", _blast_concrete, Color8(92, 92, 86), 6)
	_sheet("wall_town", _dark_brick, Color8(108, 60, 48), 6)
	_sheet("wall_asteroid", _dark_brick, Color8(108, 60, 48), 6)
	_sheet("wood_wall", _timber, Color8(104, 72, 44), 6)
	_sheet("armor_wall", _armor_plate, Color8(58, 64, 72), 6)
	_sheet("glass", _glass_block, Color8(150, 180, 196), 4)
	_sheet("armor_glass", _armor_glass, Color8(96, 126, 160), 4)
	_sheet("dot", _blast_concrete, Color8(110, 110, 104), 7)
	_sheet("dot_open", _embrasure, Color8(110, 110, 104), 7)
	_sheet("ldf", _monolith, Color8(24, 20, 30), 6)
	_sheet("corpse_wall", _flesh_pile, Color8(96, 44, 38), 5)
	_sheet("airlock", _blast_door, Color8(150, 130, 60), 6)
	_sheet("airlock_open", _blast_door_open, Color8(150, 130, 60), 6)
	_sheet("sandbags", _sandbag, Color8(160, 142, 100), 4, 10)
	_sheet("sandbag_wall", _sandbag, Color8(150, 132, 92), 4, 3)
	_sheet("trench", _trench, Color8(70, 54, 38), 3, 6)
	# --- Одиночные объекты ---
	_strip("hedgehog", _hedgehog.bind(false))
	_strip("hedgehog_sandbags", _hedgehog.bind(true))
	_strip("dirt_pile", _dirt_pile)
	_save("drone_station", _drone_station())
	_save("dpmg", _dpmg())
	_save("mine", _mine(Color8(186, 58, 48)))
	_save("av_mine", _mine(Color8(206, 132, 36)))
	_save("glass_shard", _glass_shard())
	print("textures written to %s in %d ms" % [OUT, Time.get_ticks_msec() - t0])
	quit()

# =====================================================================================
#  Шум и помощники
# =====================================================================================

## Хеш целых координат → 0..1. Без RandomNumberGenerator: плитка одинакова при каждом
## запуске, а зерно s разводит слои.
func _h(x: int, y: int, s: int) -> float:
	var h := (x * 374761393 + y * 668265263 + s * 1442695041) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = (h ^ (h >> 16)) & 0x7fffffff
	return float(h % 100000) / 100000.0

## Бесшовный шум значений: решётка cells×cy на плитку, свёрнутая в тор, — правый край
## совпадает с левым, нижний с верхним. cy ≠ cells вытягивает узор (волокна, полосы).
func _tn(x: float, y: float, cells: int, s: int, cy: int = -1) -> float:
	var ny := cells if cy < 0 else cy
	var gx := x / T * cells
	var gy := y / T * ny
	var x0 := int(floor(gx))
	var y0 := int(floor(gy))
	var fx := gx - x0
	var fy := gy - y0
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var xa := posmod(x0, cells)
	var xb := posmod(x0 + 1, cells)
	var ya := posmod(y0, ny)
	var yb := posmod(y0 + 1, ny)
	var a := lerpf(_h(xa, ya, s), _h(xb, ya, s), fx)
	var b := lerpf(_h(xa, yb, s), _h(xb, yb, s), fx)
	return lerpf(a, b, fy)

## Фрактальный бесшовный шум: октавы 8, 16, 32 (все делят плитку нацело). Крупнее 8 на
## плитку не берём: пятно размером с клетку повторялось бы в каждой клетке, и поле читалось
## бы узором из одинаковых квадратов.
func _fbm(x: float, y: float, s: int, octaves: int = 3) -> float:
	var sum := 0.0
	var amp := 0.5
	var cells := 8
	var norm := 0.0
	for o in octaves:
		sum += _tn(x, y, cells, s + o * 17) * amp
		norm += amp
		amp *= 0.5
		cells *= 2
	return sum / norm

func _shade(c: Color, k: float) -> Color:
	return Color(clampf(c.r * k, 0, 1), clampf(c.g * k, 0, 1), clampf(c.b * k, 0, 1), c.a)

## Насколько точка «внутри» плитки: 0 у края, 1 дальше margin — детали вариантов гаснут к
## краям, и края у всех вариантов совпадают.
func _inner(x: int, y: int, margin: float) -> float:
	var d := float(mini(mini(x, y), mini(T - 1 - x, T - 1 - y)))
	return clampf((d - 2.0) / margin, 0.0, 1.0)

func _save(name: String, img: Image) -> void:
	img.save_png(OUT + name + ".png")

## Лента вариантов: fn(x, y, v) → цвет пикселя варианта v.
func _strip(name: String, fn: Callable) -> void:
	var img := Image.create(T * VARIANTS, T, false, Image.FORMAT_RGBA8)
	for v in VARIANTS:
		for y in T:
			for x in T:
				img.set_pixel(v * T + x, y, fn.call(x, y, v))
	_save(name, img)

## Лист автотайла: для каждой маски — материал (fn) во всю клетку или с отступом inset на
## свободных сторонах (мешки, окоп), и тяжёлая брутальная кромка там, где соседа того же
## семейства нет: тёмный контур, светлая фаска сверху-слева, глубокая тень снизу-справа.
## edge — тон контура; bevel — толщина фаски.
func _sheet(name: String, fn: Callable, edge: Color, bevel: int, inset: int = 0) -> void:
	var img := Image.create(T * 4, T * 4 * VARIANTS, false, Image.FORMAT_RGBA8)
	for v in VARIANTS:
		for mask in 16:
			_tile(img, (mask % 4) * T, (v * 4 + mask / 4) * T, mask, v, fn, edge, bevel, inset)
	_save(name + "_autotile", img)
	# Одиночная плитка (маска 0, лента вариантов) — для превью и простых подмен.
	var single := Image.create(T * VARIANTS, T, false, Image.FORMAT_RGBA8)
	for v in VARIANTS:
		_tile(single, v * T, 0, 0, v, fn, edge, bevel, inset)
	_save(name, single)

func _tile(img: Image, ox: int, oy: int, mask: int, v: int, fn: Callable, edge: Color,
		bevel: int, inset: int) -> void:
	var n := mask & 1 != 0
	var e := mask & 2 != 0
	var s := mask & 4 != 0
	var w := mask & 8 != 0
	var x0 := 0 if w else inset
	var x1 := T - 1 if e else T - 1 - inset
	var y0 := 0 if n else inset
	var y1 := T - 1 if s else T - 1 - inset
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c: Color = fn.call(x, y, v, mask)
			if c.a <= 0.0:
				continue
			# Расстояние до свободных кромок — фаска и тень.
			var dn := (y - y0) if not n else 99
			var ds := (y1 - y) if not s else 99
			var dw := (x - x0) if not w else 99
			var de := (x1 - x) if not e else 99
			var dmin := mini(mini(dn, ds), mini(dw, de))
			if dmin == 0:
				c = Color(edge.r * 0.32, edge.g * 0.32, edge.b * 0.32, 1.0)
			elif dmin <= bevel:
				var k := 1.0 - float(dmin - 1) / float(bevel)
				if dn == dmin or dw == dmin:
					c = c.lerp(Color(1, 1, 1, c.a), 0.22 * k)
				else:
					c = c.lerp(Color(0, 0, 0, c.a), 0.45 * k)
			img.set_pixel(ox + x, oy + y, c)

# =====================================================================================
#  Полы (бесшовные; варианты — детали внутри)
# =====================================================================================

## Сталь станции: тёмный рифлёный настил (насечка 8 px — ровная по всему полю, узором
## клетки не читается), мелкая зернь, у вариантов — своя потёртость.
func _steel_deck(x: int, y: int, v: int) -> Color:
	var k := 0.88 + 0.16 * _fbm(x, y, 11 + v)
	var gx := x % 8
	var gy := y % 8
	if (gx == gy and gx < 5) or (gx == 7 - gy and gx > 2):
		k *= 1.14    # насечка
	return _shade(Color8(50, 54, 60), k)

## Пол бункера: тёмный шлифованный бетон, мелкий заполнитель крапом.
func _poured_concrete(x: int, y: int, v: int) -> Color:
	var c := _shade(Color8(62, 62, 60), 0.84 + 0.26 * _fbm(x, y, 21 + v))
	var r := _h(x + v * T, y, 22)
	if r > 0.97:
		c = _shade(c, 0.72)
	elif r > 0.955:
		c = _shade(c, 1.28)
	return c

## Улица города: тёмный бетон-асфальт с щебнем.
func _street(x: int, y: int, v: int) -> Color:
	var c := _shade(Color8(70, 70, 72), 0.82 + 0.26 * _fbm(x, y, 31 + v))
	if _h(x + v * T, y, 32) > 0.95:
		c = _shade(c, 1.3)
	return c

## Земля поля: утоптанная, с камешками и травинками.
func _dirt(x: int, y: int, v: int) -> Color:
	var n := _fbm(x, y, 41)
	var c := Color8(86, 66, 44).lerp(Color8(118, 94, 64), n)
	if _h(x + v * T, y, 42) > 0.97:
		c = Color8(132, 124, 110)
	if _h(x, y, 43 + v) > 0.985:
		c = Color8(78, 104, 52)
	return c

## Реголит астероида: серо-бурый камень; ямка-кратер есть лишь у одного варианта из
## шести — изредка, а не в каждой клетке.
func _regolith(x: int, y: int, v: int) -> Color:
	var c := _shade(Color8(92, 86, 78), 0.76 + 0.36 * _fbm(x, y, 51 + v))
	if _h(x + v * T, y, 53) > 0.975:
		c = _shade(c, 0.7)
	if v == 0:
		var d := Vector2(x, y).distance_to(Vector2(30, 34)) / 9.0
		if d < 1.0:
			c = _shade(c, 0.66 + 0.24 * d)
		elif d < 1.2:
			c = _shade(c, 1.16)
	return c

func _grass(x: int, y: int, v: int) -> Color:
	var c := Color8(46, 72, 38).lerp(Color8(74, 106, 50), _fbm(x, y, 61 + v))
	if _tn(x, y, 32, 62 + v * 3, 8) > 0.78:
		c = _shade(c, 1.22)
	return c

func _starfield(x: int, y: int, v: int) -> Color:
	var c := Color8(5, 5, 14).lerp(Color8(14, 10, 30), _fbm(x, y, 71 + v))
	var r := _h(x + v * T, y, 72)
	if r > 0.9975:
		c = Color8(230, 230, 255)
	elif r > 0.992:
		c = Color8(110, 110, 160)
	return c

func _rubble(x: int, y: int, v: int) -> Color:
	var c := _poured_concrete(x, y, v)
	var n := _tn(x, y, 16, 81 + v)
	if n > 0.7:
		c = _shade(c, 1.25)
	elif n < 0.22:
		c = _shade(c, 0.55)
	return c

func _scorch(x: int, y: int, v: int) -> Color:
	var c := Color8(22, 18, 16).lerp(Color8(54, 44, 36), _fbm(x, y, 91))
	if _h(x + v * T, y, 92) > 0.985:
		c = Color8(140, 64, 28)
	return c

func _bedrock(x: int, y: int, v: int) -> Color:
	var c := _shade(Color8(60, 54, 48), 0.74 + 0.4 * _fbm(x, y, 101 + v))
	# Слоистость — частые тонкие прожилки по всей толще, без крупных пятен.
	if _tn(x, y, 8, 102, 32) > 0.8:
		c = _shade(c, 0.78)
	if _h(x + v * T, y, 103) > 0.982:
		c = Color8(34, 30, 26)
	return c

func _fire() -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	for y in T:
		for x in T:
			var tongue := 0.45 + 0.35 * _tn(x, 0, 8, 111) + 0.2 * _tn(x, y, 16, 112)
			var hgt := float(T - y) / T
			if hgt < tongue:
				var k := hgt / tongue
				var c := Color(1.0, 0.88, 0.35).lerp(Color(0.85, 0.18, 0.04), k)
				c.a = 0.78 - 0.4 * k
				img.set_pixel(x, y, c)
	return img

# =====================================================================================
#  Стены и стыкующиеся объекты: fn(x, y, v, mask) → цвет
# =====================================================================================

## Бетон по опалубке (брутализм): доски опалубки по 8 px с волокном, следы стяжек сеткой
## 32 px, разводы у вариантов.
func _board_concrete(x: int, y: int, v: int, _mask: int) -> Color:
	var board := y / 8
	var grain := _tn(x, y, 2, 121 + board % 4, 16)
	var k := 0.84 + 0.12 * grain + 0.14 * (_fbm(x, y, 122, 3) - 0.5)
	var c := _shade(Color8(132, 130, 124), k * (0.94 + 0.12 * _fbm(x, y, 123 + v)))
	if y % 8 == 7:
		c = _shade(c, 0.78)
	if (x % 32 == 15 or x % 32 == 16) and (y % 32 == 11 or y % 32 == 12):
		c = Color8(54, 54, 52)
	return c

## Переборка станции: рёбра жёсткости через 16 px, заклёпки, копоть.
func _bulkhead(x: int, y: int, v: int, _mask: int) -> Color:
	var c := _shade(Color8(104, 112, 120), 0.88 + 0.14 * _fbm(x, y, 131, 3))
	var rib := x % 16
	if rib == 0:
		c = _shade(c, 0.62)
	elif rib == 1:
		c = _shade(c, 1.22)
	if y % 16 == 4 and rib == 8:
		c = _shade(c, 1.45)
	return _shade(c, 0.93 + 0.12 * _fbm(x, y, 132 + v))

## Броне-бетон бункера и ДОТа: светлая тяжёлая масса над тёмным полом, раковины и
## вертикальные потёки по всей высоте (частые, без крупных пятен).
func _blast_concrete(x: int, y: int, v: int, _mask: int) -> Color:
	var c := _shade(Color8(126, 124, 116), 0.82 + 0.26 * _fbm(x, y, 141 + v))
	if _h(x + v * T, y, 142) > 0.975:
		c = _shade(c, 0.55)
	if _tn(x, y, 16, 143 + v, 4) > 0.76:
		c = _shade(c, 0.86)
	return c

## Амбразура ДОТа: тот же бетон и тёмная щель поперёк.
func _embrasure(x: int, y: int, v: int, mask: int) -> Color:
	var c := _blast_concrete(x, y, v, mask)
	if y >= 28 and y <= 35:
		c = Color8(12, 12, 12) if y > 28 and y < 35 else _shade(c, 0.6)
	return c

## Тёмный «инженерный» кирпич: ложковая перевязка 16×8, швы раствора, тон по хешу самого
## кирпича; кирпичи, переходящие через край плитки, одного тона у всех вариантов.
func _dark_brick(x: int, y: int, v: int, _mask: int) -> Color:
	var row := y / 8
	var off := 8 if row % 2 == 1 else 0
	var bx := posmod(x + off, T) / 16
	if y % 8 == 7 or posmod(x + off, 16) == 15:
		return _shade(Color8(70, 66, 62), 0.9 + 0.2 * _h(x, y, 151))
	var straddles := off != 0 and bx == 3
	var tone := _h(bx, row, 152 if straddles else 152 + v * 31)
	var c := Color8(96, 50, 40).lerp(Color8(122, 70, 54), tone)
	return _shade(c, 0.88 + 0.2 * _tn(x, y, 16, 153))

## Тяжёлый брус: вертикальные доски по 16 px, волокно, сучки у вариантов.
func _timber(x: int, y: int, v: int, _mask: int) -> Color:
	var plank := x / 16
	var c := _shade(Color8(102, 70, 42), 0.78 + 0.32 * _tn(x, y, 8, 161 + plank, 2))
	if x % 16 == 15:
		c = _shade(c, 0.55)
	var knot := Vector2(8 + plank * 16, 16 + _h(plank, v, 162) * 32)
	if Vector2(x, y).distance_to(knot) < 3.0 and _h(plank, v, 163) > 0.5 and _inner(x, y, 4.0) > 0.0:
		c = _shade(c, 0.6)
	return c

## Броня: тёмная сталь, раскосы и двойные ряды заклёпок.
func _armor_plate(x: int, y: int, v: int, _mask: int) -> Color:
	var c := _shade(Color8(58, 64, 72), 0.86 + 0.18 * _fbm(x, y, 171, 3))
	if posmod(x - y, 32) <= 1 or posmod(x + y, 32) <= 1:
		c = _shade(c, 1.22)
	if (y % 16 == 3 or y % 16 == 5) and x % 8 == 4:
		c = _shade(c, 1.5)
	return _shade(c, 0.94 + 0.1 * _fbm(x, y, 172 + v))

## Стеклоблоки: сетка 16 px, толстые светлые швы, блик в каждом блоке.
func _glass_block(x: int, y: int, _v: int, _mask: int) -> Color:
	var gx := x % 16
	var gy := y % 16
	if gx == 0 or gy == 0:
		return Color(0.72, 0.76, 0.78, 0.95)
	var c := Color(0.55, 0.7, 0.8, 0.62)
	if gx + gy < 8:
		c = c.lerp(Color(1, 1, 1, 0.8), 0.5)
	return c

func _armor_glass(x: int, y: int, v: int, mask: int) -> Color:
	if x % 32 <= 2:
		return _armor_plate(x, y, v, mask)
	var c := _glass_block(x, y, v, mask)
	return Color(c.r * 0.7, c.g * 0.82, c.b, minf(1.0, c.a + 0.15))

## ЛДФ — чёрный монолит с лиловыми прожилками.
func _monolith(x: int, y: int, v: int, _mask: int) -> Color:
	if absf(_tn(x, y, 8, 181 + v) - 0.5) < 0.03:
		return Color8(96, 70, 150)
	return Color8(16, 14, 22)

## Стена из тел — тёмная масса с бурыми пятнами (без подробностей).
func _flesh_pile(x: int, y: int, v: int, _mask: int) -> Color:
	return Color8(70, 30, 28).lerp(Color8(124, 92, 78), _fbm(x, y, 191 + v))

## Гермодверь шлюза: стальная плита с жёлто-чёрной полосой поперёк прохода. В
## горизонтальной стене (соседи слева/справа) проход вертикальный, и наоборот.
func _blast_door(x: int, y: int, _v: int, mask: int) -> Color:
	var horiz := mask & (2 | 8) != 0 or mask & (1 | 4) == 0
	var a := x if horiz else y   # вдоль стены
	var b := y if horiz else x   # поперёк — по проходу
	var c := _shade(Color8(92, 94, 98), 0.86 + 0.16 * _fbm(x, y, 201, 3))
	if b >= 24 and b <= 39:
		c = Color8(198, 166, 40) if posmod(a + b, 16) < 8 else Color8(30, 28, 24)
	elif b == 22 or b == 41:
		c = _shade(c, 0.5)
	if a % 32 == 0:
		c = _shade(c, 0.6)
	return c

## Открытый шлюз: створки ушли в стену — посередине пол прохода, по краям рамы.
func _blast_door_open(x: int, y: int, v: int, mask: int) -> Color:
	var horiz := mask & (2 | 8) != 0 or mask & (1 | 4) == 0
	var a := x if horiz else y
	if a >= 10 and a <= 53:
		return _steel_deck(x, y, v)
	return _shade(_blast_door(x, y, v, mask), 0.85)

## Мешки с песком: ряды мешков 21×12 вразбежку с тёмными складками.
func _sandbag(x: int, y: int, v: int, _mask: int) -> Color:
	var row := y / 12
	var off := 10 if row % 2 == 1 else 0
	var bx := posmod(x + off, 21)
	var by := y % 12
	var edge := minf(minf(bx, 20 - bx), minf(by, 11 - by))
	var c := _shade(Color8(162, 144, 102), 0.86 + 0.18 * _tn(x, y, 16, 211 + v))
	if edge < 1.0:
		c = _shade(c, 0.6)
	elif edge < 2.5:
		c = _shade(c, 0.85)
	return c

## Окоп: земляные стенки и тёмное дно по оси соединения.
func _trench(x: int, y: int, v: int, mask: int) -> Color:
	var c := _shade(Color8(84, 64, 44), 0.8 + 0.3 * _fbm(x, y, 221 + v))
	var mid := T / 2
	var half := 12
	var on := absi(x - mid) <= half and absi(y - mid) <= half
	if mask & 1 and absi(x - mid) <= half and y < mid:
		on = true
	if mask & 4 and absi(x - mid) <= half and y >= mid:
		on = true
	if mask & 8 and absi(y - mid) <= half and x < mid:
		on = true
	if mask & 2 and absi(y - mid) <= half and x >= mid:
		on = true
	if on:
		c = _shade(Color8(44, 34, 24), 0.85 + 0.25 * _tn(x, y, 16, 222))
	return c

# =====================================================================================
#  Одиночные объекты
# =====================================================================================

## Противотанковый ёж: три сваренных двутавра (по желанию — на мешках).
func _hedgehog(x: int, y: int, v: int, on_bags: bool) -> Color:
	var c := Color(0, 0, 0, 0)
	if on_bags and y >= 36:
		c = _sandbag(x, y, v, 0)
	var steel := _shade(Color8(124, 126, 132), 0.9 + 0.2 * _h(x, y, 231))
	var d1 := absi(x - y)
	var d2 := absi(x + y - (T - 1))
	if (d1 <= 3 or d2 <= 3) and x > 6 and x < T - 7 and y > 6 and y < T - 7:
		c = steel if mini(d1, d2) <= 1 else _shade(steel, 0.6)
	if absi(x - T / 2) <= 2 and y > 12 and y < T - 12:
		c = _shade(steel, 1.1)
	return c

## Куча земли: насыпь с тенью снизу-справа.
func _dirt_pile(x: int, y: int, v: int) -> Color:
	var mid := Vector2(T / 2.0, T / 2.0 + 4)
	var d := Vector2(x, y).distance_to(mid) / (T * 0.44)
	if d > 1.0 + 0.08 * (_tn(x, y, 8, 241 + v) - 0.5):
		return Color(0, 0, 0, 0)
	var light := 1.15 - 0.45 * d - 0.004 * float(x + y - T)
	return _shade(Color8(104, 78, 50), clampf(light, 0.6, 1.25) * (0.88 + 0.2 * _fbm(x, y, 242)))

func _drone_station() -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var mid := Vector2(T / 2.0 - 0.5, T / 2.0 - 0.5)
	for y in T:
		for x in T:
			var d := Vector2(x, y).distance_to(mid)
			if d < 27.0:
				img.set_pixel(x, y, _shade(Color8(52, 62, 76), 0.9 + 0.15 * _fbm(x, y, 251, 3)))
			if d > 22.0 and d < 27.0:
				img.set_pixel(x, y, Color8(96, 178, 210))
			if absf(d - 9.0) < 1.6:
				img.set_pixel(x, y, Color8(96, 178, 210))
	return img

## Пулемётное гнездо: кольцо мешков и ствол.
func _dpmg() -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var mid := Vector2(T / 2.0 - 0.5, T / 2.0 - 0.5)
	for y in T:
		for x in T:
			var d := Vector2(x, y).distance_to(mid)
			if d > 17.0 and d < 30.0:
				img.set_pixel(x, y, _sandbag(x, y, 0, 0))
	for x in range(T / 2, T - 4):
		for t in range(-2, 3):
			img.set_pixel(x, T / 2 + t, Color8(40, 40, 44) if absi(t) < 2 else Color8(84, 84, 92))
	for y in range(T / 2 - 9, T / 2 + 9):
		for x in range(T / 2 - 10, T / 2 + 2):
			img.set_pixel(x, y, _shade(Color8(62, 64, 70), 0.9 + 0.2 * _h(x, y, 261)))
	return img

## Осколок стекла (item 7): зубчатый полупрозрачный клин со светлой кромкой и бликом.
func _glass_shard() -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var pts := [Vector2(8, 40), Vector2(30, 6), Vector2(40, 20), Vector2(58, 26),
			Vector2(36, 34), Vector2(44, 58)]
	for y in T:
		for x in T:
			if Geometry2D.is_point_in_polygon(Vector2(x, y), PackedVector2Array(pts)):
				var c := Color(0.68, 0.86, 0.96, 0.7)
				if absf(float(x - y) + 8.0) < 2.0:
					c = Color(1, 1, 1, 0.85)   # блик
				img.set_pixel(x, y, c)
	for i in pts.size():
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		for k in 40:
			var p := a.lerp(b, k / 39.0)
			img.set_pixel(int(p.x), int(p.y), Color(0.92, 0.98, 1.0, 0.95))
	return img

func _mine(c: Color) -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var mid := Vector2(T / 2.0 - 0.5, T / 2.0 - 0.5)
	for y in T:
		for x in T:
			var d := Vector2(x, y).distance_to(mid)
			if d < 13.0:
				img.set_pixel(x, y, _shade(c, 0.65 if d > 10.0 else 1.0))
			if d < 3.0:
				img.set_pixel(x, y, Color8(240, 230, 210))
	return img
