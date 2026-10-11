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
	# `-- --floors` — только виды пола комнат (0.9.2).
	if "--floors" in OS.get_cmdline_user_args():
		_floor_looks()
		print("floor looks written to %s in %d ms" % [OUT, Time.get_ticks_msec() - t0])
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
	_floor_looks()
	_save("fire", _fire())
	# --- Стены и прочие стыкующиеся объекты ---
	_sheet("wall", _board_concrete, Color8(128, 126, 120), 3)
	_sheet("wall_field", _board_concrete, Color8(128, 126, 120), 3)
	_sheet("wall_station", _bulkhead, Color8(118, 126, 134), 3)
	_sheet("wall_bunker", _blast_concrete, Color8(92, 92, 86), 3)
	_sheet("wall_town", _dark_brick, Color8(108, 60, 48), 3)
	_sheet("wall_asteroid", _dark_brick, Color8(108, 60, 48), 3)
	_sheet("wood_wall", _timber, Color8(104, 72, 44), 3)
	# Материалы стен (0.9.4): тот же объект, другой облик — город ставит дома из разного.
	_sheet("wall_brick", _red_brick, Color8(150, 76, 56), 3)
	_sheet("wall_stucco", _stucco, Color8(176, 166, 148), 3)
	_sheet("wall_block", _cinder_block, Color8(112, 112, 106), 3)
	_sheet("soil", _packed_soil, Color8(58, 42, 28), 2)
	# Граница мира (0.9.3) — только для бункера: тот же грунт, что и в кайме, чтобы
	# непробиваемый край читался как «земля просто продолжается». У станции, города и
	# поля своей плитки у неё НЕТ намеренно: там видно пол клетки — звёзды или траву.
	_sheet("boundary_bunker", _packed_soil, Color8(58, 42, 28), 2)
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
	# Furniture and lamps are rendered by tools/art/build_furniture.py (0.11).
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

## КУДА ложится файл (item 5). Текстуры разложены по папкам: папка-раздел, в ней папка
## объекта, в ней — всё его хозяйство и образец. Игра читает папки насквозь и берёт имя
## ФАЙЛА, а не папки, поэтому раскладка — чистая опрятность: тот же файл, положенный в
## user://textures как попало, работает по-прежнему.
func _path_of(name: String) -> String:
	var base := name
	if base.ends_with(Sprites.AUTOTILE_SUFFIX):
		base = base.substr(0, base.length() - Sprites.AUTOTILE_SUFFIX.length())
	return "%s%s/%s/%s.png" % [OUT, _section_of(base), base, name]

func _section_of(base: String) -> String:
	if Furniture.ids().has(base):
		return "furniture"
	if base.begins_with("floor"):
		return "floors"
	if base.begins_with("door"):
		return "doors"
	if base.begins_with("wall") or base in ["wood_wall", "armor_wall", "corpse_wall",
			"sandbag_wall", "glass", "armor_glass", "bedrock", "boundary_bunker", "soil"]:
		return "walls"
	if base in ["blood_pool", "blood_splatter", "glass_shard", "shell_casing", "fire"]:
		return "decals"
	return "features"

func _save(name: String, img: Image) -> void:
	var path := _path_of(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	# Образец для объекта БЕЗ автотайла — та же картинка с разметкой по плиткам. У объекта
	# с листом образец свой (его пишет _sheet), и переписывать его нечем: лист сохраняется
	# первым, поэтому проверка на файл здесь честная.
	if not name.ends_with(Sprites.AUTOTILE_SUFFIX) \
			and not FileAccess.file_exists(_path_of(name + Sprites.AUTOTILE_SUFFIX)):
		_write_sample(name, _grid_marks(img, false))

## Образец рядом с плиткой (item 5): та же картинка с разметкой — розовая сетка по границам
## плиток, а у листа автотайла ещё и белые метки сторон, с которых у плитки ЕСТЬ сосед. По
## нему видно, что рисовать в каждой клетке, не читая документации. Игра образцы не читает.
func _grid_marks(src: Image, autotile: bool) -> Image:
	var img := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
	img.blit_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()), Vector2i.ZERO)
	var line := Color(1.0, 0.0, 0.85, 0.85)
	var tick := Color(1.0, 1.0, 1.0, 0.9)
	var cols := maxi(1, img.get_width() / T)
	var rows := maxi(1, img.get_height() / T)
	for r in rows:
		for c in cols:
			var ox := c * T
			var oy := r * T
			for k in T:
				img.set_pixel(ox + k, oy, line)
				img.set_pixel(ox, oy + k, line)
			if not autotile:
				continue
			# Метка стороны = сосед той же породы с этой стороны (N1 E2 S4 W8).
			var mask := r * 4 + c
			for side in 4:
				if mask & (1 << side) == 0:
					continue
				for k in range(T / 3, T - T / 3):
					match side:
						0: img.set_pixel(ox + k, oy + 2, tick)
						1: img.set_pixel(ox + T - 3, oy + k, tick)
						2: img.set_pixel(ox + k, oy + T - 3, tick)
						_: img.set_pixel(ox + 2, oy + k, tick)
	return img

func _write_sample(name: String, img: Image) -> void:
	var path := _path_of(name).get_base_dir() + "/sample.png"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)

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
## Лист — РОВНО ШЕСТНАДЦАТЬ плиток, 4×4 (item 5). Прежде их было столько же на каждый из
## шести вариантов, девяносто шесть штук в файле: «individual objects shouldn't require a
## bizarre autotiling system with 80+ tiles». Разнообразие осталось там, где оно и видно, —
## в ленте вариантов одиночной плитки; стыкующаяся кромка у всех вариантов одна и та же.
func _sheet(name: String, fn: Callable, edge: Color, bevel: int, inset: int = 0) -> void:
	var img := Image.create(T * 4, T * 4, false, Image.FORMAT_RGBA8)
	for mask in 16:
		_tile(img, (mask % 4) * T, (mask / 4) * T, mask, 0, fn, edge, bevel, inset)
	_save(name + Sprites.AUTOTILE_SUFFIX, img)
	_write_sample(name, _grid_marks(img, true))
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

## ОКНО — ОДНО СПЛОШНОЕ СТЕКЛО (0.9.4, просьба игрока: «single, unbroken panes rather than
## grids of squares»). Прежде плитка рисовала стеклоблоки сеткой 8 px: каждая клетка окна
## читалась как решётка из квадратиков, а ряд окон — как клетчатая стена.
##
## Теперь в плитке нет ни одного шва: ровное голубоватое полотно с мягкой бесшовной рябью
## и еле заметным уклоном яркости по высоте (свет сверху). Рама берётся не отсюда — её
## рисует кромка листа (_sheet: контур и фаска только там, где соседа-стекла нет), так что
## ряд окон выходит одной длинной витриной с рамой лишь по краям.
func _glass_block(x: int, y: int, v: int, _mask: int) -> Color:
	# Рябь считается на торе (_fbm), поэтому у соседних клеток она продолжается без стыка.
	var ripple := 0.94 + 0.12 * _fbm(x, y, 181 + v)
	var top := 1.06 - 0.12 * (float(y) / float(T - 1))
	var k := ripple * top
	return Color(clampf(0.52 * k, 0, 1), clampf(0.67 * k, 0, 1), clampf(0.78 * k, 0, 1), 0.60)

## Бронестекло: то же сплошное полотно, но с армирующей проволокой по ДИАГОНАЛИ. Шаг 8 px
## делит плитку нацело по обеим осям, поэтому проволока идёт сквозь всю витрину насквозь,
## не разбивая её на квадратики: сетка — примета брони, а не «окно из кубиков».
func _armor_glass(x: int, y: int, v: int, mask: int) -> Color:
	var c := _glass_block(x, y, v, mask)
	c = Color(c.r * 0.82, c.g * 0.88, c.b, minf(1.0, c.a + 0.16))
	if posmod(x + y, 8) == 0 or posmod(x - y, 8) == 0:
		return Color(minf(1.0, c.r * 1.3), minf(1.0, c.g * 1.3), minf(1.0, c.b * 1.25),
				minf(1.0, c.a + 0.3))
	return c

# --- Материалы стен города (0.9.4, MCF.WALL_LOOKS) --------------------------------------
# Правила у них те же, что у обычной стены, — разный только облик, чтобы дома на одной
# улице не стояли под одну гребёнку.

## Красный кирпич: ложковая перевязка 8×4, светлый раствор, тон у каждого кирпича свой.
func _red_brick(x: int, y: int, v: int, _mask: int) -> Color:
	var row := y / 4
	var off := 4 if row % 2 == 1 else 0
	var bx := posmod(x + off, T) / 8
	if y % 4 == 3 or posmod(x + off, 8) == 7:
		return _shade(Color8(188, 180, 168), 0.9 + 0.16 * _h(x, y, 191))
	var straddles := off != 0 and bx == 3
	var tone := _h(bx, row, 192 if straddles else 192 + v * 31)
	var c := Color8(138, 62, 46).lerp(Color8(176, 94, 64), tone)
	return _shade(c, 0.9 + 0.18 * _tn(x, y, 16, 193))

## Штукатурка: светлая тёплая масса, подтёки, редкие сколы до кирпича.
func _stucco(x: int, y: int, v: int, _mask: int) -> Color:
	var c := _shade(Color8(196, 186, 166), 0.86 + 0.22 * _fbm(x, y, 201 + v))
	if _tn(x, y, 4, 202, 16) > 0.78:
		c = _shade(c, 0.93)                      # подтёк
	if _h(x + v * T, y, 203) > 0.991:
		c = Color8(146, 92, 72)                  # скол до кирпича
	return c

## Шлакоблок: крупные блоки 16×8 с глубоким швом и зернистой поверхностью.
func _cinder_block(x: int, y: int, v: int, _mask: int) -> Color:
	var row := y / 8
	var off := 8 if row % 2 == 1 else 0
	if y % 8 == 7 or posmod(x + off, 16) == 15:
		return _shade(Color8(84, 84, 80), 0.92 + 0.16 * _h(x, y, 211))
	var tone := _h(posmod(x + off, T) / 16, row, 212 + v * 17)
	var c := Color8(124, 124, 118).lerp(Color8(152, 150, 142), tone)
	return _shade(c, 0.88 + 0.2 * _fbm(x, y, 213))

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

const STEEL_DARK := Color8(70, 74, 82)

# =====================================================================================
#  Двери и шлюзы «спереди» (0.9.2)
# =====================================================================================
## Дверь рисуется так, как её видно спереди, — прямоугольник проёма в раме, — и кладётся
## поверх плитки стены окружения (TerrainTiles), так что стоит в стене любого направления.
## Фон прозрачный. «door_<окружение>» — закрытая, «door_open_<окружение>» — открытая; в
## ленте три варианта, клетка берёт свой по хешу: двери одного здания чуть разные.
## Станция — сдвижной люк с окошком и лампой, бункер и астероид — гермодверь со штурвалом,
## город — филёнчатая деревянная дверь, поле — дощатая.
##
## Дверь занимает КЛЕТКУ ЦЕЛИКОМ (0.9.3, по просьбе игрока): рама вплотную к краям плитки,
## полотно — всё, что внутри неё. Прежде полотно было узкой панелью посреди клетки (x 6…25,
## y 3…29), и по бокам в проёме просвечивала стена — дверь читалась как картинка на стене,
## а не как сама стена. Толщина рамы — единственное, что отличает тяжёлую гермодверь от
## лёгкой двери; всё внутреннее считается от размера полотна, а не от прежних координат.
const DOOR_FRAME := 2
const DOOR_FRAME_HEAVY := 3

## Толщина рамы двери по окружению.
func _door_frame_w(style: String) -> int:
	return DOOR_FRAME_HEAVY if (style == "bunker" or style == "asteroid") else DOOR_FRAME

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
	var fw := _door_frame_w(style)
	var x1 := T - 1 - fw
	var y1 := T - 1 - fw
	# Рама с фаской по самому краю клетки: свет сверху-слева, тень снизу-справа.
	for y in T:
		for x in T:
			if x >= fw and x <= x1 and y >= fw and y <= y1:
				continue
			var c := _shade(frame, 0.88 + 0.16 * _fbm(x, y, 401))
			if x == 0 or y == 0:
				c = _shade(c, 1.2)
			elif x == T - 1 or y == T - 1:
				c = _shade(c, 0.55)
			img.set_pixel(x, y, c)
	if style == "station":
		# Жёлто-чёрные полосы по верхней перекладине и лампа: красная — закрыто, зелёная —
		# открыто. Раньше и то и другое лежало ВНЕ двери, на стене; теперь — на самой раме.
		for x in T:
			if v != 2:
				img.set_pixel(x, 1, Color8(198, 166, 40) if posmod(x, 4) < 2 else Color8(30, 28, 24))
		var lamp := Color8(90, 210, 110) if open else Color8(220, 70, 50)
		img.set_pixel(T - 2, fw + 1, lamp)
		img.set_pixel(T - 2, fw + 2, _shade(lamp, 0.7))
	for y in range(fw, y1 + 1):
		for x in range(fw, x1 + 1):
			img.set_pixel(x, y, _door_open_px(style, x, y, v) if open else _door_leaf_px(style, x, y, v))
	return img

## Проём открытой двери: темнота внутри, у пола — полоска света с той стороны; у петли —
## край распахнутого полотна (у сдвижного люка и гермодвери — их кромка у рамы).
func _door_open_px(style: String, x: int, y: int, v: int) -> Color:
	var fw := _door_frame_w(style)
	var y1 := T - 1 - fw
	var t := float(y - fw) / float(y1 - fw)
	var c := Color(0.05 + 0.06 * t, 0.05 + 0.055 * t, 0.06 + 0.05 * t)
	if y >= y1 - 2:
		c = Color(0.2, 0.19, 0.17).lerp(Color(0.32, 0.3, 0.27), float(y - (y1 - 2)) / 2.0)
	match style:
		"station":
			if x >= T - 1 - fw - 1:   # створка уехала в стену: видна её кромка
				return _shade(Color8(120, 126, 134), 0.8)
		"bunker", "asteroid":
			if y <= fw + 3:   # гермодверь поднята: снизу видна её кромка с полосами
				return Color8(198, 166, 40) if posmod(x + y, 6) < 3 else Color8(30, 28, 24)
		_:
			# Деревянное полотно распахнуто внутрь — узкая трапеция у левой петли.
			var lw := 4 - (y - fw) / 12
			if x <= fw + lw:
				return _shade(_door_wood(style, v), 0.75 + 0.1 * _h(x, y, 402))
	return c

func _door_wood(style: String, v: int) -> Color:
	if style == "town":
		return [Color8(118, 74, 42), Color8(52, 84, 60), Color8(120, 52, 40)][v]
	return [Color8(112, 84, 54), Color8(116, 112, 104), Color8(98, 74, 48)][v]

## Закрытое полотно.
func _door_leaf_px(style: String, x: int, y: int, v: int) -> Color:
	var fw := _door_frame_w(style)
	var lx := x - fw
	var ly := y - fw
	var w := T - 1 - fw * 2
	var h := T - 1 - fw * 2
	match style:
		"station":
			var c := _shade([Color8(100, 106, 114), Color8(92, 100, 112), Color8(74, 86, 104)][v],
					0.9 + 0.12 * _fbm(x, y, 403))
			if v == 0 and lx == w / 2:
				return _shade(c, 0.55)   # шов двух створок
			if v == 2 and absi(lx - ly * w / h) <= 0:
				return _shade(c, 0.55)   # косой шов
			# Детали полотна считаются от его размера: полотно теперь во всю клетку, и
			# прежние абсолютные координаты увели бы окошко и полосы вбок.
			if v == 0 and absi(lx - w / 2) <= 4 and ly >= h / 5 and ly <= h / 5 + 4:
				return Color8(60, 110, 150) if ly > h / 5 else Color8(140, 190, 220)   # окошко
			var eye := Vector2(lx - w / 2.0, ly - h / 4.0).length()
			if v == 1 and eye < 4.0:
				return Color8(140, 190, 220) if eye < 2.5 else STEEL_DARK
			if v == 1 and (ly == h / 2 or ly == h * 3 / 4):
				return _shade(c, 0.65)
			if v == 2 and ly >= h / 2 - 1 and ly <= h / 2 + 1:
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

# =====================================================================================
#  Виды пола комнат (0.9.2)
# =====================================================================================
## Полы комнат по их назначению: доски, паркет, плитка, шахматка, ковры, линолеум, рифлёная
## сталь, решётка — и солнечные панели в космосе у станции. Все бесшовные: рисунок кратен
## 32 точкам, и соседние клетки комнаты сливаются в один пол.
func _floor_looks() -> void:
	_strip("floor_wood", _floor_wood)
	_strip("floor_parquet", _floor_parquet)
	_strip("floor_tile", _floor_tile)
	_strip("floor_checker", _floor_checker)
	_strip("floor_carpet_red", _floor_carpet.bind(Color8(128, 40, 42)))
	_strip("floor_carpet_blue", _floor_carpet.bind(Color8(44, 62, 112)))
	_strip("floor_lino", _floor_lino)
	_strip("floor_plate", _floor_plate)
	_strip("floor_grate", _floor_grate)
	_strip("floor_grill", _floor_grill)
	_strip("floor_solar", _floor_solar)

## Доски поперёк клетки: ряды по 8 точек, стыки досок в каждом ряду — свои, волокно вдоль.
func _floor_wood(x: int, y: int, v: int) -> Color:
	var row := y / 8
	var joint := (row * 13 + 5) % 32
	var c := _shade(Color8(148, 104, 62), 0.86 + 0.12 * _h(row, (x + 32 - joint) / 32, 501)
			+ 0.12 * _tn(x, y, 2, 502 + v, 16))
	if y % 8 == 7:
		return _shade(c, 0.62)   # щель между рядами
	if x == joint:
		return _shade(c, 0.7)    # торец доски
	if _h(x + v * T, y, 503) > 0.985:
		c = _shade(c, 0.78)      # сучок
	return c

## Паркет «ёлочкой» попроще — квадраты 8×8, планки в них то вдоль, то поперёк.
func _floor_parquet(x: int, y: int, v: int) -> Color:
	var bx := x / 8
	var by := y / 8
	var along := (bx + by) % 2 == 0
	var lx := x % 8
	var ly := y % 8
	var c := _shade(Color8(104, 66, 38), 0.86 + 0.18 * _tn(x, y, 4, 511 + v, 4 if along else 16))
	if (along and ly % 4 == 3) or (not along and lx % 4 == 3):
		c = _shade(c, 0.72)
	if lx == 7 or ly == 7:
		c = _shade(c, 0.66)
	return c

## Кафель 8×8 с серой затиркой, у каждой плитки — свой оттенок.
func _floor_tile(x: int, y: int, v: int) -> Color:
	if x % 8 == 7 or y % 8 == 7:
		return Color8(150, 152, 150)
	var k := 0.94 + 0.08 * _h(x / 8 + v * 4, y / 8, 521) + 0.04 * _fbm(x, y, 522)
	var c := _shade(Color8(214, 216, 212), k)
	if x % 8 == 0 or y % 8 == 0:
		c = _shade(c, 1.04)
	return c

## Шахматка кухни и закусочной: чёрно-белые плитки 8×8.
func _floor_checker(x: int, y: int, v: int) -> Color:
	var dark := (x / 8 + y / 8) % 2 == 1
	var c := Color8(46, 46, 50) if dark else Color8(220, 218, 210)
	c = _shade(c, 0.95 + 0.08 * _fbm(x, y, 531 + v))
	if x % 8 == 7 or y % 8 == 7:
		c = _shade(c, 0.85)
	return c

## Ковёр: ворс шумом и ромбовая решётка узора с шагом 16.
func _floor_carpet(x: int, y: int, v: int, base: Color) -> Color:
	var c := _shade(base, 0.9 + 0.16 * _fbm(x, y, 541 + v) + 0.06 * _h(x, y, 542))
	var dx := absi((x % 16) - 8)
	var dy := absi((y % 16) - 8)
	if dx + dy == 7:
		c = _shade(c, 1.22)
	elif dx + dy == 0:
		c = Color8(196, 170, 96)
	return c

## Линолеум: бледный, в крапинку, со швом раз в 16 точек.
func _floor_lino(x: int, y: int, v: int) -> Color:
	var c := _shade(Color8(170, 186, 172), 0.94 + 0.08 * _fbm(x, y, 551 + v))
	var r := _h(x + v * T, y, 552)
	if r > 0.94:
		c = _shade(c, 0.82)
	elif r > 0.9:
		c = _shade(c, 1.1)
	if x % 16 == 15:
		c = _shade(c, 0.9)
	return c

## Рифлёная сталь: ромбики-насечки ёлочкой через 8 точек.
func _floor_plate(x: int, y: int, v: int) -> Color:
	var c := _shade(Color8(126, 130, 134), 0.88 + 0.12 * _fbm(x, y, 561 + v))
	var cx := x % 8
	var cy := y % 8
	var flip := (x / 8 + y / 8) % 2 == 0
	var d := (cx - cy) if flip else (cx + cy - 7)
	if absi(d) <= 0 and cx > 1 and cx < 6:
		c = _shade(c, 1.28)
	elif absi(d) == 1 and cx > 1 and cx < 6:
		c = _shade(c, 0.78)
	return c

## Решётка технических туннелей: полосы стали и тёмные ячейки под ними.
func _floor_grate(x: int, y: int, v: int) -> Color:
	var bar_x := x % 8 <= 1
	var bar_y := y % 16 <= 1
	if bar_x or bar_y:
		var c := _shade(Color8(104, 110, 116), 0.9 + 0.14 * _fbm(x, y, 571 + v))
		if (bar_x and x % 8 == 0) or (bar_y and y % 16 == 0):
			c = _shade(c, 1.2)
		return c
	return _shade(Color8(22, 24, 28), 0.8 + 0.4 * _fbm(x, y, 572))

## Решётчатый настил снаружи станции (0.9.3): ПРОЗРАЧНЫЙ, кроме стальных прутьев — сквозь
## ячейки видно то, что под ним (в космосе — звёзды). Шаг 8 точек по обеим осям, так что
## прутья сходятся с каймой солнечной панели (_floor_solar) и мостки переходят в панели
## одной решёткой.
const GRILL_STEP := 8
const GRILL_BAR := 2

func _grill_bar(x: int, y: int, v: int) -> Color:
	var c := _shade(Color8(104, 110, 116), 0.9 + 0.14 * _fbm(x, y, 591 + v))
	if x % GRILL_STEP == 0 or y % GRILL_STEP == 0:
		c = _shade(c, 1.2)      # светлая кромка прута
	elif x % GRILL_STEP == GRILL_BAR - 1 or y % GRILL_STEP == GRILL_BAR - 1:
		c = _shade(c, 0.62)     # тень под ним
	return c

func _floor_grill(x: int, y: int, v: int) -> Color:
	if x % GRILL_STEP < GRILL_BAR or y % GRILL_STEP < GRILL_BAR:
		return _grill_bar(x, y, v)
	return Color(0, 0, 0, 0)

## Солнечная панель снаружи станции: синие ячейки в серебряной раме на решётчатом настиле.
func _floor_solar(x: int, y: int, v: int) -> Color:
	if x <= 1 or y <= 1:
		return _grill_bar(x, y, v)   # панель стоит НА решётке — её прут по краю
	if x == 2 or y == 2 or x == T - 1 or y == T - 1:
		return Color8(176, 180, 186)
	var c := _shade(Color8(36, 58, 120), 0.86 + 0.18 * _fbm(x, y, 581 + v))
	if (x - 2) % 6 == 0 or (y - 2) % 6 == 0:
		c = Color8(150, 164, 190)
	elif (x + y) % 11 == 0:
		c = _shade(c, 1.35)   # блик
	return c

