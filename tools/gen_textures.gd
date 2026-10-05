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
	# `-- --furniture` — только мебель (§3.15): прочие плитки не трогаем, их файлы
	# остаются байт в байт.
	if "--furniture" in OS.get_cmdline_user_args():
		_furniture_all()
		print("furniture textures written to %s in %d ms" % [OUT, Time.get_ticks_msec() - t0])
		quit()
		return
	# `-- --doors` — только двери (0.9.2), остальное байт в байт.
	if "--doors" in OS.get_cmdline_user_args():
		_doors_all()
		print("door textures written to %s in %d ms" % [OUT, Time.get_ticks_msec() - t0])
		quit()
		return
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
	_sheet("soil", _packed_soil, Color8(58, 42, 28), 2)
	_sheet("armor_wall", _armor_plate, Color8(58, 64, 72), 3)
	_sheet("glass", _glass_block, Color8(150, 180, 196), 2)
	_sheet("armor_glass", _armor_glass, Color8(96, 126, 160), 2)
	_sheet("dot", _blast_concrete, Color8(110, 110, 104), 3)
	_sheet("dot_open", _embrasure, Color8(110, 110, 104), 3)
	_sheet("ldf", _monolith, Color8(40, 40, 44), 3)
	_sheet("corpse_wall", _flesh_pile, Color8(96, 44, 38), 2)
	# Двери и шлюзы (0.9.2) — «спереди», поверх стены окружения: _doors_all.
	_doors_all()
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
	_furniture_all()
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
	for y in T:
		for x in T:
			if not _in_band(x, y, mask, inset):
				continue
			var c: Color = fn.call(x, y, v, mask)
			if c.a <= 0.0 or bevel <= 0:
				if c.a > 0.0:
					img.set_pixel(ox + x, oy + y, c)
				continue
			# Расстояние до края формы по четырём сторонам. Форма продолжается за край плитки
			# туда, где есть сосед (_in_band), поэтому на стыке кромки нет, а углы и
			# Т-образные развилки у соседних плиток сходятся точка в точку.
			var dn := _edge_dist(x, y, 0, -1, mask, inset, bevel)
			var ds := _edge_dist(x, y, 0, 1, mask, inset, bevel)
			var dw := _edge_dist(x, y, -1, 0, mask, inset, bevel)
			var de := _edge_dist(x, y, 1, 0, mask, inset, bevel)
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

## Форма стыкующегося объекта: вся клетка (inset 0) или, для мешков, — центральный квадрат
## с отступом inset плюс «рукава» той же ширины к каждому соседу маски. Работает и для точек
## за краем плитки: рукав к соседу продолжается дальше.
func _in_band(x: int, y: int, mask: int, inset: int) -> bool:
	var inx := x >= inset and x <= T - 1 - inset
	var iny := y >= inset and y <= T - 1 - inset
	if inset <= 0:
		return (x >= 0 or mask & 8 != 0) and (x < T or mask & 2 != 0) \
				and (y >= 0 or mask & 1 != 0) and (y < T or mask & 4 != 0)
	if inx and iny:
		return true
	if inx and ((y < inset and mask & 1 != 0) or (y > T - 1 - inset and mask & 4 != 0)):
		return true
	if iny and ((x < inset and mask & 8 != 0) or (x > T - 1 - inset and mask & 2 != 0)):
		return true
	return false

## Сколько точек от (x, y) до края формы в направлении (dx, dy), не дальше bevel+1.
func _edge_dist(x: int, y: int, dx: int, dy: int, mask: int, inset: int, bevel: int) -> int:
	for k in range(1, bevel + 2):
		if not _in_band(x + dx * k, y + dy * k, mask, inset):
			return k - 1
	return 99

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

## Огонь сверху (batch ui-drones): не языки пламени сбоку, а горящая клетка с высоты —
## оранжевое поле с жёлтыми горячими пятнами и тёмно-красными краями языков, бесшовное,
## чтобы пожар на нескольких клетках шёл сплошным полем.
func _fire() -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	for y in T:
		for x in T:
			var n := _fbm(x, y, 111)
			var hot := _tn(x, y, 8, 112)
			var c := Color8(178, 48, 12).lerp(Color8(236, 120, 24), n)
			if hot > 0.62:
				c = c.lerp(Color8(255, 214, 92), clampf((hot - 0.62) * 3.0, 0.0, 1.0))
			c.a = 0.82
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

## Грунт бункера: утрамбованная земля — бурые пласты, комья, камни и тонкие корни.
## Темнее и теплее бетона стен, чтобы толща земли читалась отдельно от облицовки.
func _packed_soil(x: int, y: int, v: int, _mask: int) -> Color:
	var c := Color8(74, 54, 36).lerp(Color8(104, 78, 50), _fbm(x, y, 171 + v))
	# Пласты — пологие полосы, как у среза земли.
	if _tn(x, y + int(4.0 * _fbm(x, 0, 172)), 8, 173, 16) > 0.74:
		c = _shade(c, 0.8)
	var r := _h(x + v * T, y, 174)
	if r > 0.985:
		c = Color8(128, 120, 106)        # камешек
	elif r > 0.965:
		c = _shade(c, 0.62)              # ком
	if _h(x, y * 3 + v, 175) > 0.993:
		c = Color8(46, 32, 20)           # корешок
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

## ЛДФ (batch ui-drones) — резиновый чёрный монолит: матовая сплошная масса без швов и
## прожилок, мягкий отблеск, как у резины, и едва заметная зернистость поверхности.
func _monolith(x: int, y: int, v: int, _mask: int) -> Color:
	var sheen := _tn(x, y, 2, 181, 2)          # широкие мягкие блики через всю стену
	var grain := _h(x + v * T, y, 182)
	var k := 0.85 + 0.4 * sheen + (0.06 if grain > 0.8 else 0.0)
	return _shade(Color8(22, 22, 25), k)

## Стена из тел — тёмная масса с бурыми пятнами (без подробностей).
func _flesh_pile(x: int, y: int, v: int, _mask: int) -> Color:
	return Color8(70, 30, 28).lerp(Color8(124, 92, 78), _fbm(x, y, 191 + v))

## Гермодверь шлюза: стальная плита с жёлто-чёрной полосой поперёк прохода. В
## горизонтальной стене (соседи слева/справа) проход вертикальный, и наоборот.
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

# =====================================================================================
#  Мебель (§3.15): вид сверху, СПИНКОЙ К ВЕРХУ плитки. TerrainTiles поворачивает плитку
#  так, чтобы спинка смотрела в стену (а стул — от своего стола). Тень вниз-вправо тем
#  длиннее, чем выше предмет: 0.5 м — точка, 2 м — четыре.
# =====================================================================================

const WOOD := Color8(126, 88, 54)
const WOOD_DARK := Color8(92, 62, 38)
const STEEL := Color8(118, 124, 132)
const STEEL_DARK := Color8(70, 74, 82)
const FABRIC := Color8(96, 106, 128)
const FABRIC_RED := Color8(132, 70, 60)
const LINEN := Color8(206, 202, 190)
const WHITE_METAL := Color8(198, 202, 204)
const GREEN_PLASTIC := Color8(66, 104, 78)
const OLIVE := Color8(92, 100, 64)
const SCREEN := Color8(70, 170, 190)
const LAMP_RED := Color8(220, 70, 50)
const LAMP_GREEN := Color8(90, 210, 110)

## Основной цвет цветового варианта, пока рисуется вариант (Furniture.VARIANTS).
var _tint := Color(0, 0, 0, 0)

## Основной цвет предмета: у варианта — его, у базового — c.
func _m(c: Color) -> Color:
	return _tint if _tint.a > 0.0 else c

func _furniture_all() -> void:
	for id: String in Furniture.ids():
		# Вариант рисуется как базовый предмет, только основной цвет (_m) — свой.
		_tint = Furniture.tint_of(id)
		var fid := Furniture.base_of(id)
		if Furniture.joins(fid):
			# Многоклеточное: лист автотайла 4×4 (маска соседей того же вида, N1 E2 S4 W8),
			# плюс одиночная плитка = маска 0 — для миниатюр и одной клетки.
			var sheet := Image.create(T * 4, T * 4, false, Image.FORMAT_RGBA8)
			for mask in 16:
				sheet.blit_rect(_joined_tile(fid, mask), Rect2i(0, 0, T, T),
						Vector2i((mask % 4) * T, (mask / 4) * T))
			_save(id + Sprites.AUTOTILE_SUFFIX, sheet)
			_save(id, _joined_tile(fid, 0))
		else:
			_save(id, _furniture(fid))
	_tint = Color(0, 0, 0, 0)

# --- Многоклеточная мебель: плитка секции по маске соседей ---------------------------
## Плитка рисуется в «своей» системе координат предмета: спинка (изголовье, стена) —
## вверху. С открытых сторон (соседа того же вида нет) тело отступает на поле M, у него
## тёмная кромка, светлая фаска сверху-слева и тень вниз-вправо; со сросшихся сторон тело
## идёт до края плитки, и соседние плитки сливаются в один предмет.
const M := 3

func _joined_tile(fid: String, mask: int) -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var n := mask & Sprites.AUTOTILE_N == 0
	var e := mask & Sprites.AUTOTILE_E == 0
	var s := mask & Sprites.AUTOTILE_S == 0
	var w := mask & Sprites.AUTOTILE_W == 0
	var lo := Vector2i(M if w else 0, M if n else 0)
	var hi := Vector2i(T - 1 - (M if e else 0), T - 1 - (M if s else 0))
	var round := fid in ["dining_table", "conference_table", "bed", "sofa", "exam_table", "bunk_bed", "fuel_tank"]
	var base: Color = _joined_base(fid)
	var lift := int(Furniture.height_of(fid) * 2.0)
	# Тело для проверки кромки: со сросшихся сторон оно продолжается за край плитки — иначе
	# крайний ряд точек считался бы кромкой и между клетками предмета темнел бы шов.
	var blo := Vector2i(lo.x if w else -T, lo.y if n else -T)
	var bhi := Vector2i(hi.x if e else 2 * T, hi.y if s else 2 * T)
	for y in T:
		for x in T:
			var inside := _in_body(x, y, blo, bhi, n, e, s, w, round)
			if not inside:
				if _in_body(x - lift, y - lift, blo, bhi, n, e, s, w, round):
					img.set_pixel(x, y, Color(0, 0, 0, 0.38))
				continue
			var c := _shade(base, 0.9 + 0.18 * _fbm(x, y, 311))
			var edge := not _in_body(x - 1, y, blo, bhi, n, e, s, w, round) \
					or not _in_body(x + 1, y, blo, bhi, n, e, s, w, round) \
					or not _in_body(x, y - 1, blo, bhi, n, e, s, w, round) \
					or not _in_body(x, y + 1, blo, bhi, n, e, s, w, round)
			if edge:
				c = _shade(base, 0.45)
			elif (w and x == lo.x + 1) or (n and y == lo.y + 1):
				c = _shade(base, 1.22)
			var d: Variant = _joined_detail(fid, x, y, lo, hi, n, e, s, w)
			if d != null and not edge:
				c = d
			img.set_pixel(x, y, c)
	return img

func _in_body(x: int, y: int, lo: Vector2i, hi: Vector2i, n: bool, e: bool, s: bool, w: bool,
		round: bool) -> bool:
	if x < lo.x or y < lo.y or x > hi.x or y > hi.y:
		return false
	if not round:
		return true
	# Скруглённый угол — только там, где сходятся две открытые стороны.
	var r := 4
	for corner: Array in [[n and w, lo.x + r, lo.y + r, -1, -1], [n and e, hi.x - r, lo.y + r, 1, -1],
			[s and w, lo.x + r, hi.y - r, -1, 1], [s and e, hi.x - r, hi.y - r, 1, 1]]:
		if not corner[0]:
			continue
		var cx: int = corner[1]
		var cy: int = corner[2]
		if (x - cx) * int(corner[3]) > 0 and (y - cy) * int(corner[4]) > 0:
			if Vector2(x - cx, y - cy).length() > r + 0.5:
				return false
	return true

func _joined_base(fid: String) -> Color:
	match fid:
		"bed": return Color8(92, 64, 40)
		"sofa": return _m(FABRIC)
		"piano": return _m(Color8(34, 32, 34))
		"bunk_bed": return STEEL_DARK
		"fuel_tank": return _m(Color8(176, 178, 170))
		"desk", "dining_table", "workbench", "bench", "park_table", "dresser", "reception_desk", "checkout_counter":
			return WOOD
		"conference_table", "wardrobe", "bookshelf": return WOOD_DARK
		"display_shelf": return Color8(150, 120, 84)
		"office_desk": return Color8(150, 150, 146)
		"kitchen_counter": return Color8(176, 172, 160)
		"filing_cabinet": return STEEL
		"locker": return _m(OLIVE)
		"storage_shelf": return STEEL_DARK
		"server_rack": return Color8(36, 38, 44)
		"industrial_cabinet": return Color8(84, 96, 88)
		"generator": return _m(Color8(196, 160, 40))
		"machinery": return Color8(82, 88, 96)
		"exam_table": return STEEL
		"dumpster": return _m(Color8(54, 96, 70))
	return WOOD

## Детали секции: null — оставить тело. lo/hi — края тела, n/e/s/w — открытые стороны.
func _joined_detail(fid: String, x: int, y: int, lo: Vector2i, hi: Vector2i,
		n: bool, e: bool, s: bool, w: bool) -> Variant:
	match fid:
		"bed":
			if (w and x <= lo.x + 1) or (e and x >= hi.x - 1) or (n and y <= lo.y + 1) or (s and y >= hi.y - 1):
				return null   # деревянная рама — только по наружным сторонам
			if n and y <= lo.y + 8 and x >= 6 and x <= 25:
				return Color8(234, 232, 224) if y >= lo.y + 3 else LINEN   # подушка у изголовья
			if n and y <= lo.y + 11:
				return LINEN
			return _shade(_m(Color8(84, 104, 136)), 0.92 + 0.12 * _fbm(x, y, 321))   # одеяло
		"bunk_bed":
			if (w and x <= lo.x + 1) or (e and x >= hi.x - 1) or (n and y <= lo.y + 1) or (s and y >= hi.y - 1):
				return null   # стальная рама
			if n and y <= lo.y + 7 and x >= 7 and x <= 24:
				return Color8(234, 232, 224)
			if (y - lo.y) % 14 == 13:
				return STEEL   # перекладина верхнего яруса
			return _shade(_m(Color8(92, 100, 64)), 0.92 + 0.12 * _fbm(x, y, 322))   # армейское одеяло
		"piano":
			if n and y <= lo.y + 9:
				return _shade(_m(Color8(34, 32, 34)), 0.7)   # корпус над клавиатурой
			if y >= lo.y + 10 and y <= lo.y + 17:
				var k := x % 4
				if k == 0:
					return Color8(90, 90, 90)
				return Color8(16, 16, 18) if (y <= lo.y + 13 and k == 2 and (x / 4) % 7 != 2 and (x / 4) % 7 != 6) else Color8(236, 234, 226)
		"fuel_tank":
			var cx := (lo.x + hi.x) * 0.5 if (w and e) else (float(T) if w else 0.0)
			var cy := (lo.y + hi.y) * 0.5 if (n and s) else (float(T) if n else 0.0)
			var r := Vector2(x - cx, y - cy).length()
			if absf(r - 22.0) < 1.0 or absf(r - 10.0) < 1.0:
				return _shade(_m(Color8(176, 178, 170)), 0.7)   # обручи и люк
			if r < 3.0:
				return Color8(196, 160, 40)
		"sofa":
			if n and y <= lo.y + 6:
				return _shade(_m(FABRIC), 0.66 if y < lo.y + 6 else 0.5)   # спинка и шов под ней
			if (w and x <= lo.x + 4) or (e and x >= hi.x - 4):
				return _shade(_m(FABRIC), 0.76 if x != lo.x + 4 and x != hi.x - 4 else 0.58)   # подлокотник
		"desk":
			if w and x >= lo.x + 4 and x <= lo.x + 12 and y >= lo.y + 4 and y <= lo.y + 10:
				return Color8(222, 220, 210)  # бумаги
			if e and x >= hi.x - 9 and x <= hi.x - 3 and y >= lo.y + 3 and y <= lo.y + 7:
				return Color8(50, 54, 60)     # лампа
		"office_desk":
			if e and x >= hi.x - 14 and x <= hi.x - 3 and y >= lo.y + 2 and y <= lo.y + 7:
				return SCREEN if y >= lo.y + 3 and x <= hi.x - 4 and x >= hi.x - 13 else Color8(40, 42, 48)
			if e and x >= hi.x - 14 and x <= hi.x - 3 and y >= lo.y + 10 and y <= lo.y + 12:
				return Color8(60, 62, 68)     # клавиатура
		"dining_table", "conference_table":
			if (x + y * 3) % 23 == 0 and x > lo.x + 3 and x < hi.x - 3 and y > lo.y + 3 and y < hi.y - 3:
				return _shade(_joined_base(fid), 0.8)   # волокно
			if fid == "conference_table" and n and y >= lo.y + 4 and y <= lo.y + 6 and x >= 10 and x <= 18:
				return Color8(222, 220, 210)  # папка
		"wardrobe":
			if x == 15 or x == 16:
				return _shade(WOOD_DARK, 0.6)
			if (x == 13 or x == 18) and y == (lo.y + hi.y) / 2:
				return Color8(210, 190, 120)
		"dresser":
			if y == (lo.y + hi.y) / 2:
				return _shade(WOOD, 0.6)
			if (x == 9 or x == 22) and (y == (lo.y + hi.y) / 2 - 3 or y == (lo.y + hi.y) / 2 + 3):
				return Color8(210, 190, 120)
		"bookshelf", "display_shelf":
			if y > lo.y + 2 and y < lo.y + 11 and x % 5 != 0 and x > lo.x and x < hi.x:
				var hue := _h(x / 5, 0, 330 if fid == "bookshelf" else 331)
				var c := Color.from_hsv(hue, 0.55, 0.62)
				return c
		"kitchen_counter":
			if s and y >= hi.y - 2:
				return _shade(Color8(176, 172, 160), 0.7)   # фасад
			if w and Vector2(x, y).distance_to(Vector2(lo.x + 10, lo.y + 9)) < 5.0:
				return STEEL if Vector2(x, y).distance_to(Vector2(lo.x + 10, lo.y + 9)) > 1.5 else STEEL_DARK
			if e and (Vector2(x, y).distance_to(Vector2(hi.x - 9, lo.y + 6)) < 3.0
					or Vector2(x, y).distance_to(Vector2(hi.x - 9, lo.y + 13)) < 3.0):
				return Color8(40, 40, 44)   # конфорки
		"filing_cabinet", "locker", "industrial_cabinet":
			if x == 15:
				return _shade(_joined_base(fid), 0.6)   # шов дверец
			if fid == "locker" and (y == lo.y + 4 or y == lo.y + 6) and x % 16 >= 4 and x % 16 <= 10:
				return _shade(_m(OLIVE), 0.6)   # жалюзи
			if fid == "filing_cabinet" and (y == lo.y + 6 or y == lo.y + 12):
				return STEEL_DARK
			if fid == "industrial_cabinet" and n and y >= lo.y + 3 and y <= lo.y + 6 and x % 16 >= 4 and x % 16 <= 9:
				return Color8(220, 190, 60)
		"reception_desk", "checkout_counter":
			if s and y >= hi.y - 3:
				return _shade(WOOD, 0.75)   # фасад стойки
			if fid == "checkout_counter" and w and x >= lo.x + 5 and x <= lo.x + 12 and y >= lo.y + 4 and y <= lo.y + 10:
				return Color8(52, 54, 60) if y > lo.y + 5 else LAMP_GREEN   # касса
			if fid == "reception_desk" and e and x >= hi.x - 12 and x <= hi.x - 4 and y >= lo.y + 3 and y <= lo.y + 8:
				return SCREEN
		"workbench":
			if w and x >= lo.x + 3 and x <= lo.x + 9 and y >= lo.y + 3 and y <= lo.y + 8:
				return STEEL_DARK   # тиски
			if y == lo.y + 12 and x % 9 >= 2 and x % 9 <= 6:
				return STEEL        # инструмент
		"storage_shelf":
			var bx := x % 11
			if bx >= 1 and bx <= 9 and ((y > lo.y + 1 and y < lo.y + 13) or (y > lo.y + 15 and y < hi.y - 1)):
				return Color8(160, 128, 84) if _h(x / 11, y / 15, 340) > 0.35 else Color8(120, 130, 120)
		"server_rack":
			if y % 5 == 0 and x > lo.x + 1 and x < hi.x - 1:
				return Color8(70, 74, 82)
			if y % 5 == 2 and x == hi.x - 4:
				return LAMP_GREEN if _h(x, y, 341) > 0.25 else LAMP_RED
		"generator":
			if w and x >= lo.x + 3 and x <= lo.x + 14 and y >= lo.y + 3 and y <= hi.y - 3:
				return STEEL_DARK if (y - lo.y) % 3 != 0 else STEEL   # решётка
			if e and x >= hi.x - 10 and x <= hi.x - 3 and y >= lo.y + 4 and y <= lo.y + 11:
				return Color8(40, 40, 44) if Vector2(x, y).distance_to(Vector2(hi.x - 6, lo.y + 7)) > 1.5 else LAMP_RED
		"machinery":
			if n and w and Vector2(x, y).distance_to(Vector2(lo.x + 12, lo.y + 12)) < 8.0:
				return Color8(196, 160, 40) if Vector2(x, y).distance_to(Vector2(lo.x + 12, lo.y + 12)) < 4.0 else Color8(52, 56, 62)
			if s and y >= hi.y - 4 and (x + y) % 8 < 4:
				return Color8(196, 160, 40)   # полосы опасности
			if e and x >= hi.x - 6 and x <= hi.x - 3:
				return STEEL_DARK            # трубы
		"exam_table":
			if x <= lo.x + 2 or x >= hi.x - 2:
				return null
			if n and y <= lo.y + 7 and y >= lo.y + 2:
				return Color8(220, 230, 228)
			return Color8(140, 190, 180)
		"bench", "park_table":
			if (y - lo.y) % 5 == 4:
				return _shade(WOOD, 0.6)   # щели между досками
			if fid == "park_table" and ((n and y <= lo.y + 4) or (s and y >= hi.y - 4)):
				return WOOD_DARK          # лавки вдоль стола
		"dumpster":
			if x == 15 or x == 16:
				return _shade(_m(Color8(54, 96, 70)), 0.6)
	return null

func _furniture(fid: String) -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var lift := int(Furniture.height_of(fid) * 2.0)   # длина тени, точки
	var ops := _furniture_ops(fid)
	# Тень всех частей разом — под ними.
	for op: Array in ops:
		if op[0] == "box" or op[0] == "round":
			var r: Rect2i = op[1]
			_fill_shape(img, op[0], Rect2i(r.position + Vector2i(lift, lift), r.size),
					Color(0, 0, 0, 0.38), false)
	for op: Array in ops:
		match op[0]:
			"box":
				_fill_material(img, op[1], op[2], false)
			"round":
				_fill_material(img, op[1], op[2], true)
			"rect":
				var r: Rect2i = op[1]
				img.fill_rect(r, op[2])
			"dot":
				img.set_pixelv(op[1], op[2])
	return img

## Описание предмета набором фигур: ["box", прямоугольник, цвет] — тело с кромкой и
## фаской; ["round", …] — то же, но со скруглением; ["rect", …] — плоская деталь;
## ["dot", точка, цвет].
func _furniture_ops(fid: String) -> Array:
	match fid:
		"chair":
			return [["box", Rect2i(9, 8, 14, 16), WOOD], ["box", Rect2i(9, 6, 14, 5), WOOD_DARK]]
		"armchair":
			var fr := _m(FABRIC_RED)
			return [["round", Rect2i(5, 6, 22, 21), fr], ["box", Rect2i(5, 6, 22, 6), _shade(fr, 0.75)],
					["box", Rect2i(5, 10, 4, 17), _shade(fr, 0.85)], ["box", Rect2i(23, 10, 4, 17), _shade(fr, 0.85)]]
		"sofa":
			return [["round", Rect2i(1, 7, 30, 19), FABRIC], ["box", Rect2i(1, 7, 30, 6), _shade(FABRIC, 0.75)],
					["rect", Rect2i(15, 13, 1, 12), _shade(FABRIC, 0.7)],
					["box", Rect2i(1, 11, 4, 15), _shade(FABRIC, 0.85)], ["box", Rect2i(27, 11, 4, 15), _shade(FABRIC, 0.85)]]
		"bed":
			return [["box", Rect2i(4, 2, 24, 28), WOOD_DARK], ["box", Rect2i(6, 4, 20, 24), LINEN],
					["round", Rect2i(8, 5, 16, 6), Color8(232, 230, 222)],
					["box", Rect2i(6, 13, 20, 15), Color8(84, 104, 136)]]
		"nightstand":
			return [["box", Rect2i(8, 8, 16, 16), WOOD], ["rect", Rect2i(10, 17, 12, 1), WOOD_DARK],
					["dot", Vector2i(16, 20), Color8(210, 190, 120)]]
		"desk":
			return [["box", Rect2i(2, 5, 28, 16), WOOD], ["rect", Rect2i(6, 8, 9, 6), Color8(222, 220, 210)],
					["box", Rect2i(20, 7, 7, 5), Color8(50, 54, 60)]]
		"dining_table":
			return [["round", Rect2i(3, 3, 26, 26), WOOD], ["rect", Rect2i(8, 15, 16, 1), WOOD_DARK]]
		"coffee_table":
			return [["round", Rect2i(6, 9, 20, 14), WOOD_DARK], ["rect", Rect2i(12, 13, 6, 4), Color8(170, 160, 120)]]
		"wardrobe":
			return [["box", Rect2i(1, 2, 30, 15), WOOD_DARK], ["rect", Rect2i(15, 4, 2, 11), _shade(WOOD_DARK, 0.6)],
					["dot", Vector2i(13, 11), Color8(210, 190, 120)], ["dot", Vector2i(18, 11), Color8(210, 190, 120)]]
		"dresser":
			return [["box", Rect2i(2, 3, 28, 13), WOOD], ["rect", Rect2i(4, 8, 24, 1), WOOD_DARK],
					["dot", Vector2i(10, 11), Color8(210, 190, 120)], ["dot", Vector2i(21, 11), Color8(210, 190, 120)]]
		"bookshelf":
			return [["box", Rect2i(1, 2, 30, 11), WOOD_DARK], ["rect", Rect2i(3, 4, 4, 7), Color8(150, 60, 50)],
					["rect", Rect2i(8, 4, 3, 7), Color8(60, 90, 140)], ["rect", Rect2i(12, 4, 5, 7), Color8(170, 150, 80)],
					["rect", Rect2i(19, 4, 3, 7), Color8(70, 120, 80)], ["rect", Rect2i(23, 4, 6, 7), Color8(130, 110, 150)]]
		"cabinet":
			return [["box", Rect2i(3, 3, 26, 14), WOOD], ["rect", Rect2i(15, 5, 1, 10), WOOD_DARK],
					["dot", Vector2i(13, 10), Color8(210, 190, 120)], ["dot", Vector2i(18, 10), Color8(210, 190, 120)]]
		"kitchen_counter":
			return [["box", Rect2i(0, 2, 32, 16), Color8(176, 172, 160)], ["round", Rect2i(9, 5, 12, 9), STEEL],
					["dot", Vector2i(15, 6), STEEL_DARK]]
		"refrigerator":
			return [["box", Rect2i(4, 2, 24, 22), WHITE_METAL], ["rect", Rect2i(6, 10, 20, 1), _shade(WHITE_METAL, 0.7)],
					["rect", Rect2i(23, 4, 1, 5), STEEL_DARK]]
		"office_desk":
			return [["box", Rect2i(2, 4, 28, 15), Color8(150, 150, 146)], ["box", Rect2i(9, 5, 14, 5), Color8(40, 42, 48)],
					["rect", Rect2i(10, 6, 12, 3), SCREEN], ["rect", Rect2i(10, 13, 12, 3), Color8(60, 62, 68)]]
		"conference_table":
			return [["round", Rect2i(1, 6, 30, 20), WOOD_DARK], ["rect", Rect2i(4, 15, 24, 1), _shade(WOOD_DARK, 0.7)],
					["rect", Rect2i(9, 10, 5, 3), Color8(222, 220, 210)], ["rect", Rect2i(19, 18, 5, 3), Color8(222, 220, 210)]]
		"filing_cabinet":
			return [["box", Rect2i(7, 3, 18, 16), STEEL], ["rect", Rect2i(9, 8, 14, 1), STEEL_DARK],
					["rect", Rect2i(9, 13, 14, 1), STEEL_DARK], ["rect", Rect2i(14, 10, 4, 1), Color8(220, 220, 220)]]
		"locker":
			return [["box", Rect2i(6, 2, 20, 14), OLIVE], ["rect", Rect2i(15, 4, 1, 10), _shade(OLIVE, 0.6)],
					["rect", Rect2i(9, 5, 4, 1), _shade(OLIVE, 0.6)], ["rect", Rect2i(19, 5, 4, 1), _shade(OLIVE, 0.6)]]
		"reception_desk":
			return [["box", Rect2i(1, 4, 30, 10), Color8(168, 136, 98)], ["box", Rect2i(1, 4, 7, 22), Color8(168, 136, 98)],
					["box", Rect2i(12, 6, 8, 5), Color8(40, 42, 48)], ["rect", Rect2i(13, 7, 6, 3), SCREEN]]
		"display_shelf":
			return [["box", Rect2i(1, 2, 30, 12), Color8(150, 120, 84)], ["rect", Rect2i(3, 4, 5, 8), Color8(200, 80, 60)],
					["rect", Rect2i(10, 4, 5, 8), Color8(220, 190, 80)], ["rect", Rect2i(17, 4, 5, 8), Color8(80, 150, 200)],
					["rect", Rect2i(24, 4, 5, 8), Color8(110, 180, 100)]]
		"checkout_counter":
			return [["box", Rect2i(1, 6, 30, 12), Color8(160, 128, 90)], ["box", Rect2i(20, 7, 8, 7), Color8(52, 54, 60)],
					["rect", Rect2i(22, 8, 4, 2), LAMP_GREEN], ["rect", Rect2i(4, 9, 12, 2), Color8(60, 60, 64)]]
		"vending_machine":
			return [["box", Rect2i(4, 1, 24, 20), _m(Color8(176, 48, 44))], ["rect", Rect2i(6, 3, 13, 15), Color8(40, 46, 60)],
					["rect", Rect2i(7, 4, 3, 3), Color8(220, 200, 80)], ["rect", Rect2i(11, 4, 3, 3), Color8(80, 190, 120)],
					["rect", Rect2i(15, 4, 3, 3), Color8(90, 140, 230)], ["rect", Rect2i(21, 6, 4, 3), SCREEN]]
		"workbench":
			return [["box", Rect2i(1, 4, 30, 15), WOOD], ["box", Rect2i(4, 6, 6, 5), STEEL_DARK],
					["rect", Rect2i(14, 9, 9, 2), STEEL], ["rect", Rect2i(24, 7, 3, 7), Color8(200, 160, 40)]]
		"tool_cabinet":
			var tc := _m(Color8(170, 40, 36))
			return [["box", Rect2i(5, 3, 22, 15), tc], ["rect", Rect2i(7, 7, 18, 1), _shade(tc, 0.55)],
					["rect", Rect2i(7, 11, 18, 1), _shade(tc, 0.55)], ["rect", Rect2i(7, 14, 18, 1), _shade(tc, 0.55)]]
		"storage_shelf":
			return [["box", Rect2i(0, 6, 32, 20), STEEL_DARK], ["box", Rect2i(2, 8, 9, 7), Color8(160, 128, 84)],
					["box", Rect2i(12, 8, 8, 7), Color8(140, 110, 72)], ["box", Rect2i(21, 8, 9, 7), Color8(160, 128, 84)],
					["box", Rect2i(4, 17, 11, 7), Color8(120, 130, 120)], ["box", Rect2i(17, 17, 11, 7), Color8(160, 128, 84)]]
		"server_rack":
			return [["box", Rect2i(5, 2, 22, 26), Color8(36, 38, 44)], ["rect", Rect2i(7, 5, 18, 1), Color8(70, 74, 82)],
					["rect", Rect2i(7, 10, 18, 1), Color8(70, 74, 82)], ["rect", Rect2i(7, 15, 18, 1), Color8(70, 74, 82)],
					["rect", Rect2i(7, 20, 18, 1), Color8(70, 74, 82)], ["dot", Vector2i(23, 7), LAMP_GREEN],
					["dot", Vector2i(23, 12), LAMP_GREEN], ["dot", Vector2i(21, 12), LAMP_RED], ["dot", Vector2i(23, 17), LAMP_GREEN],
					["dot", Vector2i(23, 22), Color8(230, 180, 60)]]
		"industrial_cabinet":
			return [["box", Rect2i(2, 2, 28, 16), Color8(84, 96, 88)], ["rect", Rect2i(15, 4, 2, 12), _shade(Color8(84, 96, 88), 0.6)],
					["rect", Rect2i(5, 5, 6, 4), Color8(220, 190, 60)], ["rect", Rect2i(21, 7, 3, 4), STEEL]]
		"pallet":
			return [["box", Rect2i(3, 4, 26, 24), Color8(150, 116, 74)], ["rect", Rect2i(3, 10, 26, 2), Color8(96, 70, 44)],
					["rect", Rect2i(3, 19, 26, 2), Color8(96, 70, 44)]]
		"crate":
			return [["box", Rect2i(6, 6, 20, 20), Color8(150, 112, 66)], ["rect", Rect2i(8, 8, 16, 1), Color8(104, 74, 42)],
					["rect", Rect2i(8, 23, 16, 1), Color8(104, 74, 42)], ["rect", Rect2i(15, 8, 2, 16), Color8(104, 74, 42)]]
		"barrel":
			var bc := _m(Color8(52, 92, 132))
			return [["round", Rect2i(7, 7, 18, 18), bc], ["round", Rect2i(11, 11, 10, 10), _shade(bc, 0.75)],
					["dot", Vector2i(13, 13), Color8(200, 200, 200)]]
		"equipment_cart":
			return [["box", Rect2i(6, 4, 20, 22), STEEL], ["box", Rect2i(9, 7, 7, 6), Color8(220, 180, 50)],
					["box", Rect2i(17, 15, 6, 7), STEEL_DARK], ["rect", Rect2i(6, 27, 3, 2), Color8(30, 30, 32)],
					["rect", Rect2i(23, 27, 3, 2), Color8(30, 30, 32)]]
		"generator":
			return [["box", Rect2i(2, 4, 28, 22), Color8(196, 160, 40)], ["box", Rect2i(5, 7, 12, 14), STEEL_DARK],
					["rect", Rect2i(6, 9, 10, 1), STEEL], ["rect", Rect2i(6, 12, 10, 1), STEEL], ["rect", Rect2i(6, 15, 10, 1), STEEL],
					["box", Rect2i(20, 8, 7, 7), Color8(40, 40, 44)], ["dot", Vector2i(23, 11), LAMP_RED]]
		"toolbox":
			return [["box", Rect2i(8, 11, 16, 10), Color8(186, 44, 40)], ["rect", Rect2i(12, 8, 8, 2), Color8(40, 40, 44)],
					["rect", Rect2i(8, 15, 16, 1), _shade(Color8(186, 44, 40), 0.6)]]
		"ammo_crate":
			return [["box", Rect2i(4, 6, 24, 20), OLIVE], ["rect", Rect2i(4, 14, 24, 2), _shade(OLIVE, 0.6)],
					["rect", Rect2i(8, 9, 10, 2), Color8(220, 200, 120)], ["rect", Rect2i(8, 19, 4, 3), Color8(220, 200, 120)]]
		"machinery":
			return [["box", Rect2i(1, 1, 30, 30), Color8(82, 88, 96)], ["round", Rect2i(5, 5, 14, 14), Color8(52, 56, 62)],
					["round", Rect2i(8, 8, 8, 8), Color8(196, 160, 40)], ["box", Rect2i(21, 5, 6, 22), STEEL_DARK],
					["rect", Rect2i(5, 23, 13, 3), Color8(196, 160, 40)], ["dot", Vector2i(24, 9), LAMP_GREEN]]
		"exam_table":
			return [["box", Rect2i(9, 2, 14, 28), STEEL], ["box", Rect2i(10, 4, 12, 24), Color8(140, 190, 180)],
					["round", Rect2i(11, 5, 10, 5), Color8(220, 230, 228)]]
		"bench":
			return [["box", Rect2i(1, 10, 30, 12), WOOD], ["rect", Rect2i(1, 14, 30, 1), WOOD_DARK],
					["rect", Rect2i(1, 18, 30, 1), WOOD_DARK]]
		"trash_bin":
			return [["round", Rect2i(9, 9, 14, 14), _m(GREEN_PLASTIC)], ["round", Rect2i(12, 12, 8, 8), _shade(_m(GREEN_PLASTIC), 0.6)]]
		"potted_plant":
			return [["round", Rect2i(10, 14, 12, 12), Color8(150, 82, 52)], ["round", Rect2i(6, 4, 20, 18), Color8(64, 118, 60)],
					["round", Rect2i(10, 7, 9, 8), Color8(92, 150, 78)], ["dot", Vector2i(20, 13), Color8(40, 84, 40)]]
		"tv_stand":
			return [["box", Rect2i(2, 6, 28, 12), WOOD_DARK], ["box", Rect2i(5, 3, 22, 5), Color8(24, 24, 28)],
					["rect", Rect2i(6, 4, 20, 2), Color8(60, 80, 110)], ["rect", Rect2i(6, 13, 20, 1), _shade(WOOD_DARK, 0.6)]]
		"stove":
			return [["box", Rect2i(4, 2, 24, 22), WHITE_METAL], ["round", Rect2i(7, 5, 7, 7), Color8(40, 40, 44)],
					["round", Rect2i(18, 5, 7, 7), Color8(40, 40, 44)], ["round", Rect2i(7, 14, 7, 7), Color8(40, 40, 44)],
					["round", Rect2i(18, 14, 7, 7), Color8(40, 40, 44)], ["dot", Vector2i(10, 8), LAMP_RED]]
		"water_cooler":
			return [["box", Rect2i(9, 8, 14, 16), WHITE_METAL], ["round", Rect2i(10, 3, 12, 12), Color8(120, 180, 230)],
					["round", Rect2i(13, 6, 6, 6), Color8(170, 215, 245)], ["dot", Vector2i(13, 20), LAMP_RED], ["dot", Vector2i(18, 20), Color8(70, 120, 220)]]
		"washing_machine":
			return [["box", Rect2i(4, 3, 24, 24), WHITE_METAL], ["round", Rect2i(8, 9, 16, 16), Color8(60, 64, 70)],
					["round", Rect2i(11, 12, 10, 10), Color8(130, 170, 200)], ["rect", Rect2i(6, 5, 8, 2), STEEL_DARK]]
		"dumpster":
			return [["box", Rect2i(1, 4, 30, 22), Color8(54, 96, 70)], ["rect", Rect2i(15, 6, 2, 18), _shade(Color8(54, 96, 70), 0.6)],
					["rect", Rect2i(3, 6, 2, 18), _shade(Color8(54, 96, 70), 1.2)]]
		"park_table":
			return [["box", Rect2i(4, 9, 24, 14), WOOD], ["box", Rect2i(4, 3, 24, 4), WOOD_DARK],
					["box", Rect2i(4, 25, 24, 4), WOOD_DARK]]
		"street_cabinet":
			return [["box", Rect2i(6, 4, 20, 13), Color8(110, 120, 112)], ["rect", Rect2i(8, 7, 7, 1), _shade(Color8(110, 120, 112), 0.6)],
					["rect", Rect2i(19, 8, 4, 4), Color8(220, 190, 60)]]
	return [["box", Rect2i(6, 6, 20, 20), WOOD]]

func _in_shape(kind: String, r: Rect2i, x: int, y: int) -> bool:
	if not r.has_point(Vector2i(x, y)):
		return false
	if kind != "round":
		return true
	var cx := r.position.x + (r.size.x - 1) * 0.5
	var cy := r.position.y + (r.size.y - 1) * 0.5
	var dx := (x - cx) / maxf(1.0, r.size.x * 0.5)
	var dy := (y - cy) / maxf(1.0, r.size.y * 0.5)
	return dx * dx + dy * dy <= 1.02

func _fill_shape(img: Image, kind: String, r: Rect2i, c: Color, _blend: bool) -> void:
	for y in range(maxi(0, r.position.y), mini(T, r.end.y)):
		for x in range(maxi(0, r.position.x), mini(T, r.end.x)):
			if _in_shape(kind, r, x, y) and img.get_pixel(x, y).a < 0.5:
				img.set_pixel(x, y, c)

## Тело предмета: материал с лёгкой фактурой, тёмный контур, светлая фаска сверху-слева.
func _fill_material(img: Image, r: Rect2i, base: Color, round: bool) -> void:
	var kind := "round" if round else "box"
	for y in range(maxi(0, r.position.y), mini(T, r.end.y)):
		for x in range(maxi(0, r.position.x), mini(T, r.end.x)):
			if not _in_shape(kind, r, x, y):
				continue
			var c := _shade(base, 0.9 + 0.18 * _fbm(x, y, 301))
			var edge := not _in_shape(kind, r, x - 1, y) or not _in_shape(kind, r, x + 1, y) \
					or not _in_shape(kind, r, x, y - 1) or not _in_shape(kind, r, x, y + 1)
			if edge:
				c = _shade(base, 0.45)
			elif not _in_shape(kind, r, x - 2, y) or not _in_shape(kind, r, x, y - 2):
				c = _shade(base, 1.22)
			img.set_pixel(x, y, c)

# =====================================================================================
#  Двери и шлюзы «спереди» (0.9.2)
# =====================================================================================
## Дверь рисуется так, как её видно спереди, — прямоугольник проёма в раме, — и кладётся
## поверх плитки стены окружения (TerrainTiles), так что стоит в стене любого направления.
## Фон прозрачный. «door_<окружение>» — закрытая, «door_open_<окружение>» — открытая; в
## ленте три варианта, клетка берёт свой по хешу: двери одного здания чуть разные.
## Станция — сдвижной люк с окошком и лампой, бункер и астероид — гермодверь со штурвалом,
## город — филёнчатая деревянная дверь, поле — дощатая.
const DOOR_X0 := 6
const DOOR_X1 := 25
const DOOR_Y0 := 3
const DOOR_Y1 := 29

func _doors_all() -> void:
	for style: String in ["station", "bunker", "asteroid", "town", "field"]:
		for open: bool in [false, true]:
			var img := Image.create(T * 3, T, false, Image.FORMAT_RGBA8)
			for v in 3:
				var one := _door_front(style, open, v)
				img.blit_rect(one, Rect2i(0, 0, T, T), Vector2i(v * T, 0))
			var name := "door_open" if open else "door"
			_save("%s_%s" % [name, style], img)
			if style == "station":
				_save(name, img)   # без окружения — станционный люк

func _door_front(style: String, open: bool, v: int) -> Image:
	var img := Image.create(T, T, false, Image.FORMAT_RGBA8)
	var frame: Color
	match style:
		"station": frame = [Color8(150, 154, 160), Color8(132, 138, 148), Color8(120, 128, 140)][v]
		"bunker": frame = Color8(108, 108, 100)
		"asteroid": frame = Color8(116, 98, 82)
		"town": frame = [Color8(200, 194, 180), Color8(150, 112, 78), Color8(176, 170, 156)][v]
		_: frame = Color8(110, 82, 52)
	var heavy := style == "bunker" or style == "asteroid"
	var fw := 3 if heavy else 2   # толщина рамы
	# Рама с фаской: свет сверху-слева, тень снизу-справа; порог — темнее.
	for y in range(DOOR_Y0 - fw, DOOR_Y1 + 2):
		for x in range(DOOR_X0 - fw, DOOR_X1 + fw + 1):
			if x >= DOOR_X0 and x <= DOOR_X1 and y >= DOOR_Y0 and y <= DOOR_Y1:
				continue
			var c := _shade(frame, 0.88 + 0.16 * _fbm(x, y, 401))
			if x == DOOR_X0 - fw or y == DOOR_Y0 - fw:
				c = _shade(c, 1.2)
			elif x == DOOR_X1 + fw or y == DOOR_Y1 + 1:
				c = _shade(c, 0.55)
			img.set_pixel(x, y, c)
	if style == "station":
		# Жёлто-чёрные полосы над люком и лампа: красная — закрыто, зелёная — открыто.
		for x in range(DOOR_X0 - fw, DOOR_X1 + fw + 1):
			if v != 2:
				img.set_pixel(x, DOOR_Y0 - 2, Color8(198, 166, 40) if posmod(x, 4) < 2 else Color8(30, 28, 24))
		var lamp := Color8(90, 210, 110) if open else Color8(220, 70, 50)
		img.set_pixel(DOOR_X1 + 2, DOOR_Y0 + 2, lamp)
		img.set_pixel(DOOR_X1 + 2, DOOR_Y0 + 3, _shade(lamp, 0.7))
	for y in range(DOOR_Y0, DOOR_Y1 + 1):
		for x in range(DOOR_X0, DOOR_X1 + 1):
			img.set_pixel(x, y, _door_open_px(style, x, y, v) if open else _door_leaf_px(style, x, y, v))
	return img

## Проём открытой двери: темнота внутри, у пола — полоска света с той стороны; у петли —
## край распахнутого полотна (у сдвижного люка и гермодвери — их кромка у рамы).
func _door_open_px(style: String, x: int, y: int, v: int) -> Color:
	var t := float(y - DOOR_Y0) / float(DOOR_Y1 - DOOR_Y0)
	var c := Color(0.05 + 0.06 * t, 0.05 + 0.055 * t, 0.06 + 0.05 * t)
	if y >= DOOR_Y1 - 2:
		c = Color(0.2, 0.19, 0.17).lerp(Color(0.32, 0.3, 0.27), float(y - (DOOR_Y1 - 2)) / 2.0)
	match style:
		"station":
			if x >= DOOR_X1 - 1:   # створка уехала в стену: видна её кромка
				return _shade(Color8(120, 126, 134), 0.8)
		"bunker", "asteroid":
			if y <= DOOR_Y0 + 3:   # гермодверь поднята: снизу видна её кромка с полосами
				return Color8(198, 166, 40) if posmod(x + y, 6) < 3 else Color8(30, 28, 24)
		_:
			# Деревянное полотно распахнуто внутрь — узкая трапеция у левой петли.
			var w := 4 - (y - DOOR_Y0) / 12
			if x <= DOOR_X0 + w:
				return _shade(_door_wood(style, v), 0.75 + 0.1 * _h(x, y, 402))
	return c

func _door_wood(style: String, v: int) -> Color:
	if style == "town":
		return [Color8(118, 74, 42), Color8(52, 84, 60), Color8(120, 52, 40)][v]
	return [Color8(112, 84, 54), Color8(116, 112, 104), Color8(98, 74, 48)][v]

## Закрытое полотно.
func _door_leaf_px(style: String, x: int, y: int, v: int) -> Color:
	var lx := x - DOOR_X0
	var ly := y - DOOR_Y0
	var w := DOOR_X1 - DOOR_X0
	var h := DOOR_Y1 - DOOR_Y0
	match style:
		"station":
			var c := _shade([Color8(100, 106, 114), Color8(92, 100, 112), Color8(74, 86, 104)][v],
					0.9 + 0.12 * _fbm(x, y, 403))
			if v == 0 and lx == w / 2:
				return _shade(c, 0.55)   # шов двух створок
			if v == 2 and absi(lx - ly * w / h) <= 0:
				return _shade(c, 0.55)   # косой шов
			if v == 0 and lx >= 6 and lx <= 13 and ly >= 4 and ly <= 8:
				return Color8(60, 110, 150) if ly > 4 else Color8(140, 190, 220)   # окошко
			if v == 1 and Vector2(lx - w / 2.0, ly - 7).length() < 4.0:
				return Color8(140, 190, 220) if Vector2(lx - w / 2.0, ly - 7).length() < 2.5 else STEEL_DARK
			if v == 1 and (ly == 14 or ly == 20):
				return _shade(c, 0.65)
			if v == 2 and ly >= 12 and ly <= 14:
				return Color8(198, 166, 40) if posmod(lx + ly, 4) < 2 else Color8(30, 28, 24)
			if lx == 0 or ly == 0:
				return _shade(c, 1.15)
			return c
		"bunker", "asteroid":
			var base := Color8(96, 100, 92) if style == "bunker" else Color8(124, 92, 66)
			var c := _shade(base, 0.86 + 0.18 * _fbm(x, y, 404))
			if lx <= 1 or lx >= w - 1 or ly <= 1 or ly >= h - 1:
				c = _shade(c, 0.7 if (lx <= 1 or ly <= 1) else 0.5)
				if (lx + ly) % 4 == 0:
					c = _shade(base, 1.25)   # заклёпки по кромке
				return c
			if v == 1 and (lx == 5 or lx == w - 5) and ly >= 3 and ly <= h - 3:
				return STEEL_DARK   # засовы
			if v == 2 and ly >= h / 2 + 5 and ly <= h / 2 + 7:
				return Color8(198, 166, 40) if posmod(lx + ly, 4) < 2 else Color8(30, 28, 24)
			var d := Vector2(lx - w / 2.0, ly - h / 2.0 + (2 if v == 2 else 0)).length()
			if v != 1 and (absf(d - 5.0) < 0.8 or (d < 5.0 and (absi(lx - w / 2) == 0 or absi(ly - h / 2 + (2 if v == 2 else 0)) == 0))):
				return Color8(176, 150, 60)   # штурвал
			return c
		"town":
			var c := _shade(_door_wood(style, v), 0.86 + 0.18 * _tn(x, y, 2, 405, 12))
			if v == 1 and lx >= 5 and lx <= w - 5 and ly >= 3 and ly <= 9:
				return Color8(150, 190, 210) if not (lx == w / 2 or ly == 6) else _shade(c, 0.6)   # окошко с переплётом
			var panel := (lx >= 3 and lx <= w / 2 - 2 or lx >= w / 2 + 2 and lx <= w - 3) \
					and (ly >= 3 and ly <= h / 2 - 2 or ly >= h / 2 + 2 and ly <= h - 3)
			if v != 1 and panel:
				var edge := lx == 3 or lx == w / 2 + 2 or ly == 3 or ly == h / 2 + 2
				c = _shade(c, 0.78 if edge else 0.92)
			if v == 2 and ly == h / 2 + 4 and lx >= w / 2 - 3 and lx <= w / 2 + 3:
				return Color8(180, 160, 90)   # прорезь для писем
			if lx == w - 4 and ly == h / 2:
				return Color8(214, 184, 90)   # ручка
			return c
		_:
			# Поле: вертикальные доски, у первой двери — Z-распорка, кольцо вместо ручки.
			var c := _shade(_door_wood(style, v), 0.82 + 0.22 * _tn(x, y, 2, 406, 16))
			if lx % 5 == 4:
				c = _shade(c, 0.6)   # щели между досками
			if (ly == 4 or ly == h - 4) or (v == 0 and absi(lx - (h - 4 - ly) * w / (h - 8)) <= 0 and ly > 4 and ly < h - 4):
				c = _shade(Color8(90, 66, 42), 0.95)   # распорки
			if v == 2 and lx >= 6 and lx <= w - 6 and ly >= 7 and ly <= 11:
				return Color8(40, 44, 50)   # окошко
			if Vector2(lx - (w - 4), ly - h / 2).length() > 0.8 and Vector2(lx - (w - 4), ly - h / 2).length() < 2.0:
				return STEEL_DARK
			return c
