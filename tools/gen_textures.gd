extends SceneTree

## Текстуры клеток (items 9/20/24 + «брутализм, без повторяющегося рисунка»; с gore batch —
## 32×32 в том же стиле).
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

const T := 32
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
	_sheet("wall", _board_concrete, Color8(128, 126, 120), 3)
	_sheet("wall_field", _board_concrete, Color8(128, 126, 120), 3)
	_sheet("wall_station", _bulkhead, Color8(118, 126, 134), 3)
	_sheet("wall_bunker", _blast_concrete, Color8(92, 92, 86), 3)
	_sheet("wall_town", _dark_brick, Color8(108, 60, 48), 3)
	_sheet("wall_asteroid", _dark_brick, Color8(108, 60, 48), 3)
	_sheet("wood_wall", _timber, Color8(104, 72, 44), 3)
	_sheet("armor_wall", _armor_plate, Color8(58, 64, 72), 3)
	_sheet("glass", _glass_block, Color8(150, 180, 196), 2)
	_sheet("armor_glass", _armor_glass, Color8(96, 126, 160), 2)
	_sheet("dot", _blast_concrete, Color8(110, 110, 104), 3)
	_sheet("dot_open", _embrasure, Color8(110, 110, 104), 3)
	_sheet("ldf", _monolith, Color8(24, 20, 30), 3)
	_sheet("corpse_wall", _flesh_pile, Color8(96, 44, 38), 2)
	_sheet("airlock", _blast_door, Color8(150, 130, 60), 3)
	_sheet("airlock_open", _blast_door_open, Color8(150, 130, 60), 3)
	# Город и поле (gore batch): вместо гермодвери — обычная тяжёлая дверь в бетонной раме,
	# закрытая и распахнутая. Правила те же (это всё тот же шлюз), меняется только вид;
	# TerrainTiles берёт «airlock_<окружение>» сам. Астероид остаётся с гермодверью.
	_sheet("airlock_town", _door.bind(false, _street), Color8(96, 92, 86), 0)
	_sheet("airlock_open_town", _door.bind(true, _street), Color8(96, 92, 86), 0)
	_sheet("airlock_field", _door.bind(false, _dirt), Color8(96, 92, 86), 0)
	_sheet("airlock_open_field", _door.bind(true, _dirt), Color8(96, 92, 86), 0)
	_sheet("sandbags", _sandbag, Color8(160, 142, 100), 2, 5)
	_sheet("sandbag_wall", _sandbag, Color8(150, 132, 92), 2, 2)
	# Окоп — без кромки и отступа: он врезан В землю, свою тень рисует сам (_trench).
	_sheet("trench", _trench, Color8(70, 54, 38), 0)
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
		if cells > T / 2:
			break   # мельче двух точек — уже не узор, а рябь
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
	return clampf((d - 1.0) / margin, 0.0, 1.0)

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
			if bevel <= 0:
				pass
			elif dmin == 0:
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
	var gx := x % 4
	var gy := y % 4
	if (gx == gy and gx < 3) or (gx == 3 - gy and gx > 1):
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
		var d := Vector2(x, y).distance_to(Vector2(15, 17)) / 4.5
		if d < 1.0:
			c = _shade(c, 0.66 + 0.24 * d)
		elif d < 1.2:
			c = _shade(c, 1.16)
	return c

func _grass(x: int, y: int, v: int) -> Color:
	var c := Color8(46, 72, 38).lerp(Color8(74, 106, 50), _fbm(x, y, 61 + v))
	if _tn(x, y, 16, 62 + v * 3, 4) > 0.78:
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
	if _tn(x, y, 8, 102, 16) > 0.8:
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

## Бетон по опалубке (брутализм): доски опалубки по 4 px с волокном, разводы у вариантов.
## Следы стяжек убраны по просьбе игрока (четыре тёмных квадратика на плитке).
func _board_concrete(x: int, y: int, v: int, _mask: int) -> Color:
	var board := y / 4
	var grain := _tn(x, y, 2, 121 + board % 4, 8)
	var k := 0.84 + 0.12 * grain + 0.14 * (_fbm(x, y, 122, 3) - 0.5)
	var c := _shade(Color8(132, 130, 124), k * (0.94 + 0.12 * _fbm(x, y, 123 + v)))
	if y % 4 == 3:
		c = _shade(c, 0.8)
	return c

## Переборка станции: рёбра жёсткости через 16 px, заклёпки, копоть.
func _bulkhead(x: int, y: int, v: int, _mask: int) -> Color:
	var c := _shade(Color8(104, 112, 120), 0.88 + 0.14 * _fbm(x, y, 131, 3))
	var rib := x % 8
	if rib == 0:
		c = _shade(c, 0.62)
	elif rib == 1:
		c = _shade(c, 1.22)
	if y % 8 == 2 and rib == 4:
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
	if y >= 13 and y <= 18:
		c = Color8(12, 12, 12) if y > 13 and y < 18 else _shade(c, 0.6)
	return c

## Тёмный «инженерный» кирпич: ложковая перевязка 8×4, швы раствора, тон по хешу самого
## кирпича; кирпичи, переходящие через край плитки, одного тона у всех вариантов.
func _dark_brick(x: int, y: int, v: int, _mask: int) -> Color:
	var row := y / 4
	var off := 4 if row % 2 == 1 else 0
	var bx := posmod(x + off, T) / 8
	if y % 4 == 3 or posmod(x + off, 8) == 7:
		return _shade(Color8(70, 66, 62), 0.9 + 0.2 * _h(x, y, 151))
	var straddles := off != 0 and bx == 3
	var tone := _h(bx, row, 152 if straddles else 152 + v * 31)
	var c := Color8(96, 50, 40).lerp(Color8(122, 70, 54), tone)
	return _shade(c, 0.88 + 0.2 * _tn(x, y, 16, 153))

## Тяжёлый брус: вертикальные доски по 16 px, волокно, сучки у вариантов.
func _timber(x: int, y: int, v: int, _mask: int) -> Color:
	var plank := x / 8
	var c := _shade(Color8(102, 70, 42), 0.78 + 0.32 * _tn(x, y, 8, 161 + plank, 2))
	if x % 8 == 7:
		c = _shade(c, 0.55)
	var knot := Vector2(4 + plank * 8, 8 + _h(plank, v, 162) * 16)
	if Vector2(x, y).distance_to(knot) < 1.6 and _h(plank, v, 163) > 0.5 and _inner(x, y, 2.0) > 0.0:
		c = _shade(c, 0.6)
	return c

## Броня: тёмная сталь, раскосы и двойные ряды заклёпок.
func _armor_plate(x: int, y: int, v: int, _mask: int) -> Color:
	var c := _shade(Color8(58, 64, 72), 0.86 + 0.18 * _fbm(x, y, 171, 3))
	if posmod(x - y, 16) == 0 or posmod(x + y, 16) == 0:
		c = _shade(c, 1.22)
	if (y % 8 == 1 or y % 8 == 3) and x % 4 == 2:
		c = _shade(c, 1.5)
	return _shade(c, 0.94 + 0.1 * _fbm(x, y, 172 + v))

## Стеклоблоки: сетка 16 px, толстые светлые швы, блик в каждом блоке.
func _glass_block(x: int, y: int, _v: int, _mask: int) -> Color:
	var gx := x % 8
	var gy := y % 8
	if gx == 0 or gy == 0:
		return Color(0.72, 0.76, 0.78, 0.95)
	var c := Color(0.55, 0.7, 0.8, 0.62)
	if gx + gy < 5:
		c = c.lerp(Color(1, 1, 1, 0.8), 0.5)
	return c

func _armor_glass(x: int, y: int, v: int, mask: int) -> Color:
	if x % 16 <= 1:
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
	if b >= 12 and b <= 19:
		c = Color8(198, 166, 40) if posmod(a + b, 8) < 4 else Color8(30, 28, 24)
	elif b == 11 or b == 20:
		c = _shade(c, 0.5)
	if a % 16 == 0:
		c = _shade(c, 0.6)
	return c

## Открытый шлюз: створки ушли в стену — посередине пол прохода, по краям рамы.
func _blast_door_open(x: int, y: int, v: int, mask: int) -> Color:
	var horiz := mask & (2 | 8) != 0 or mask & (1 | 4) == 0
	var a := x if horiz else y
	if a >= 5 and a <= 26:
		return _steel_deck(x, y, v)
	return _shade(_blast_door(x, y, v, mask), 0.85)

## Мешки с песком: ряды мешков 11×6 вразбежку с тёмными складками.
func _sandbag(x: int, y: int, v: int, _mask: int) -> Color:
	var row := y / 6
	var off := 5 if row % 2 == 1 else 0
	var bx := posmod(x + off, 11)
	var by := y % 6
	var edge := minf(minf(bx, 10 - bx), minf(by, 5 - by))
	var c := _shade(Color8(162, 144, 102), 0.86 + 0.18 * _tn(x, y, 16, 211 + v))
	if edge < 1.0:
		c = _shade(c, 0.6)
	elif edge < 1.5:
		c = _shade(c, 0.85)
	return c

## Окоп (gore batch): канава, ВРЕЗАННАЯ в землю, а не насыпь поверх неё. Вне канавы
## плитка прозрачна — виден пол клетки; вокруг — узкий бруствер выброшенной земли. Внутри:
## тёмное дно, глубокая тень под северной и западной стенкой (свет сверху-слева) и светлая
## земляная стенка напротив. Ширина канавы ~70 % клетки — боец в неё помещается.
## Всё считается от формы канавы, продолженной ЗА край плитки по маске соседей, и шум у
## всех вариантов общий, поэтому стыки, углы и Т-образные развилки сходятся без шва.
const TRENCH_HALF := 11

func _in_trench(x: int, y: int, mask: int) -> bool:
	var m := T / 2
	var hx := absi(x - m) <= TRENCH_HALF - (1 if x >= m else 0)
	var hy := absi(y - m) <= TRENCH_HALF - (1 if y >= m else 0)
	if hx and hy:
		return true
	if hx and ((y < m and mask & 1 != 0) or (y >= m and mask & 4 != 0)):
		return true
	if hy and ((x < m and mask & 8 != 0) or (x >= m and mask & 2 != 0)):
		return true
	return false

func _trench(x: int, y: int, v: int, mask: int) -> Color:
	if not _in_trench(x, y, mask):
		# Бруствер: земля в 1–2 точках от края канавы, клочками.
		for d in [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 2), Vector2i(0, -2), Vector2i(2, 0), Vector2i(-2, 0)]:
			if _in_trench(x + d.x, y + d.y, mask):
				var near := absi(d.x) + absi(d.y) == 1
				if not near and _tn(x, y, 16, 223) < 0.5:
					break
				var lip := _shade(Color8(104, 82, 56), 0.85 + 0.3 * _fbm(x, y, 221))
				lip.a = 0.95 if near else 0.7
				return lip
		return Color(0, 0, 0, 0)
	var c := _shade(Color8(46, 36, 26), 0.82 + 0.3 * _fbm(x, y, 222))
	# Тень под северной/западной стенкой: чем ближе к ней, тем темнее.
	for k in range(1, 5):
		if not _in_trench(x, y - k, mask) or not _in_trench(x - k, y, mask):
			return _shade(c, 0.45 + 0.12 * k)
	# Освещённая стенка напротив — светлая земля.
	for k in range(1, 3):
		if not _in_trench(x, y + k, mask) or not _in_trench(x + k, y, mask):
			return _shade(Color8(98, 76, 52), 0.9 + 0.2 * _fbm(x, y, 224) - 0.1 * k)
	if _h(x + v * T, y, 225) > 0.97:
		c = _shade(c, 1.35)   # камешки на дне
	return c

## Дверь города и поля (gore batch): бетонная рама по концам проёма, порог — пол
## окружения, полотно — тяжёлые тёмные доски с двумя стальными полосами и ручкой.
## Открытая — полотно повёрнуто на петле вдоль рамы, проход свободен.
func _door(x: int, y: int, v: int, mask: int, open: bool, floor_fn: Callable) -> Color:
	var horiz := mask & (2 | 8) != 0 or mask & (1 | 4) == 0
	var a := x if horiz else y   # вдоль стены
	var b := y if horiz else x   # поперёк — по проходу
	var c: Color = floor_fn.call(x, y, v)
	# Рама: бетонные косяки на всю толщину стены, с фаской.
	if a <= 3 or a >= T - 4:
		var post := _shade(Color8(124, 120, 112), 0.85 + 0.2 * _fbm(x, y, 271))
		if a == 0 or a == T - 1:
			post = _shade(post, 0.55)
		elif a == 3 or a == T - 4:
			post = _shade(post, 0.75)
		return post
	if not open:
		if b >= 12 and b <= 19:
			return _door_leaf(a, b, x, y)
		if a >= 23 and a <= 24 and (b == 10 or b == 11 or b == 20 or b == 21):
			return Color8(150, 146, 132)   # ручка с обеих сторон
		if b == 11 or b == 20:
			return _shade(c, 0.6)   # тень полотна на пороге
		return c
	# Открыто: полотно стоит вдоль левого косяка, распахнутое внутрь (вниз по проходу).
	if a >= 4 and a <= 7 and b >= 16 and b <= T - 3:
		return _door_leaf(b, a, x, y)
	if a == 8 and b >= 17 and b <= T - 2:
		return _shade(c, 0.6)
	return c

func _door_leaf(along: int, across: int, x: int, y: int) -> Color:
	# Цельная тёмная плита: волокно вдоль полотна, две стальные полосы поперёк,
	# светлая верхняя кромка и тёмная нижняя — читается как толщина двери.
	var c := _shade(Color8(76, 52, 34), 0.82 + 0.24 * _tn(x, y, 2, 281, 16))
	if along == 10 or along == 11 or along == 20 or along == 21:
		c = _shade(Color8(88, 90, 94), 0.9 + 0.15 * _h(x, y, 282))
	if across == 12:
		c = _shade(c, 1.3)
	elif across == 19:
		c = _shade(c, 0.6)
	return c

# =====================================================================================
#  Одиночные объекты
# =====================================================================================

## Противотанковый ёж: три сваренных двутавра (по желанию — на мешках).
func _hedgehog(x: int, y: int, v: int, on_bags: bool) -> Color:
	var c := Color(0, 0, 0, 0)
	if on_bags and y >= 18:
		c = _sandbag(x, y, v, 0)
	var steel := _shade(Color8(124, 126, 132), 0.9 + 0.2 * _h(x, y, 231))
	var d1 := absi(x - y)
	var d2 := absi(x + y - (T - 1))
	if (d1 <= 1 or d2 <= 1) and x > 3 and x < T - 4 and y > 3 and y < T - 4:
		c = steel if mini(d1, d2) == 0 else _shade(steel, 0.6)
	if absi(x - T / 2) <= 1 and y > 6 and y < T - 6:
		c = _shade(steel, 1.1)
	return c

## Куча земли: насыпь с тенью снизу-справа.
func _dirt_pile(x: int, y: int, v: int) -> Color:
	var mid := Vector2(T / 2.0, T / 2.0 + 2)
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
			if d < 13.5:
				img.set_pixel(x, y, _shade(Color8(52, 62, 76), 0.9 + 0.15 * _fbm(x, y, 251, 3)))
			if d > 11.0 and d < 13.5:
				img.set_pixel(x, y, Color8(96, 178, 210))
			if absf(d - 4.5) < 0.8:
				img.set_pixel(x, y, Color8(96, 178, 210))
	return img

## Пулемётное гнездо: кольцо мешков и ствол.
func _dpmg() -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var mid := Vector2(T / 2.0 - 0.5, T / 2.0 - 0.5)
	for y in T:
		for x in T:
			var d := Vector2(x, y).distance_to(mid)
			if d > 8.5 and d < 15.0:
				img.set_pixel(x, y, _sandbag(x, y, 0, 0))
	for x in range(T / 2, T - 2):
		for t in range(-1, 2):
			img.set_pixel(x, T / 2 + t, Color8(40, 40, 44) if t == 0 else Color8(84, 84, 92))
	for y in range(T / 2 - 4, T / 2 + 4):
		for x in range(T / 2 - 5, T / 2 + 1):
			img.set_pixel(x, y, _shade(Color8(62, 64, 70), 0.9 + 0.2 * _h(x, y, 261)))
	return img

## Осколок стекла (item 7): зубчатый полупрозрачный клин со светлой кромкой и бликом.
func _glass_shard() -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var pts := [Vector2(4, 20), Vector2(15, 3), Vector2(20, 10), Vector2(29, 13),
			Vector2(18, 17), Vector2(22, 29)]
	for y in T:
		for x in T:
			if Geometry2D.is_point_in_polygon(Vector2(x, y), PackedVector2Array(pts)):
				var c := Color(0.68, 0.86, 0.96, 0.7)
				if absf(float(x - y) + 4.0) < 1.0:
					c = Color(1, 1, 1, 0.85)   # блик
				img.set_pixel(x, y, c)
	for i in pts.size():
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		for k in 20:
			var p := a.lerp(b, k / 19.0)
			img.set_pixel(int(p.x), int(p.y), Color(0.92, 0.98, 1.0, 0.95))
	return img

func _mine(c: Color) -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var mid := Vector2(T / 2.0 - 0.5, T / 2.0 - 0.5)
	for y in T:
		for x in T:
			var d := Vector2(x, y).distance_to(mid)
			if d < 6.5:
				img.set_pixel(x, y, _shade(c, 0.65 if d > 5.0 else 1.0))
			if d < 1.5:
				img.set_pixel(x, y, Color8(240, 230, 210))
	return img
