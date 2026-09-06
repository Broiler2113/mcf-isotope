class_name MCF
extends RefCounted

## Общие константы и перечисления симуляции.
## Магические числа собраны здесь со ссылками на параграфы дизайн-документа.

# --- Очки действия (см. §3.2) ---
const AP_PER_ACTIVATION := 2

# --- Захват и перенос (§3.4) ---
# Перенос удерживаемого юнита: бюджет движения захватившего минус 3 клетки/действие.
const CAPTURE_CARRY_PENALTY := 3

# --- Высоты и стоимость подъёма (см. §3.1) ---
# Стоимость входа в клетку при подъёме, в очках скорости.
const CLIMB_COST := {0.5: 2, 1.0: 3, 1.5: 4}
const FLAT_MOVE_COST := 1
const WALL_HEIGHT := 2.0

# --- Гранаты (см. §3.6) ---
const GRENADE_RANGE := 12
const ITEM_FRAG := "frag_grenade"
const ITEM_EXTINGUISHER := "fire_extinguisher_grenade"

const ITEM_DRONE_STATION := "drone_station"
const ITEM_LDF := "bru"  # стартовый предмет инженера (§3.7)

const ITEM_NAMES := {
	ITEM_FRAG: "Frag Grenade",
	ITEM_EXTINGUISHER: "Fire Extinguisher Grenade",
	ITEM_DRONE_STATION: "Drone Station",
	ITEM_LDF: "LDF",
}

# --- Спецспособности (id в UnitStats.special_ability_id) ---
const ABILITY_SHIELD_BEARER := "shield_bearer"
const ABILITY_ANTI_TANK := "anti_tank"
const ABILITY_ASSAULT := "assault"
const ABILITY_FLAMETHROWER := "flamethrower"
const ABILITY_MARKSMAN := "marksman"
const ABILITY_SNIPER := "sniper"
const ABILITY_DRONE_OPERATOR := "drone_operator"
const ABILITY_ENGINEER := "engineer"
const ABILITY_MINER := "miner"
const ABILITY_SAPPER := "sapper"
const ABILITY_CIVILIAN := "civilian"

# --- Туман войны (§3.9, наше дополнение) ---
# Решение M4: обзор — отдельный параметр (по умолчанию 12 клеток, метрика Чебышёва),
# ПЛОЩАДНОЙ в радиусе обзора; стены (высота 2) перекрывают обзор по лучу, живые юниты —
# нет. Видимость общая на команду. Скрытые вражеские юниты не отображаются и не могут
# быть выбраны целью, пока не войдут в зону видимости.
const DEFAULT_SIGHT_RANGE := 12

# --- Дроны (§3.12) ---
# Полёт 30 клеток = 1 действие; дрон не удаляется от станции дальше 30 клеток.
const DRONE_FLIGHT_RANGE := 30
const DRONE_ARMOR := 5  # броня дрона 5+
const DRONE_STATS_ID := "drone"

# --- Статические объекты на клетке (станции, укрепления §3.7) ---
# ЗАДЕЛ НА БУДУЩЕЕ (не в M3, требуют механик вне текущей модели):
#   • Стена из трупов — нужна укладка 5 трупов на одну клетку, но модель клетки
#     держит одного occupant; поле corpse_count заведено, но стек не образуется.
#   • Окоп (копка из 2 куч земли 0.5 м) — нет источника «куч земли».
#   • ДПМГ (стационарный пулемёт) — это стреляющая сущность; проще как неподвижный
#     UnitInstance, отложено. ДОТ автор пометил «в разработке».
# Мешки/ёж/окоп как ДАННЫЕ КАРТЫ работают через cover_height (система укрытий §3.7).
const FEATURE_DRONE_STATION := "drone_station"
const FEATURE_SANDBAGS := "sandbags"       # мешки с песком, 1 м
const FEATURE_HEDGEHOG := "hedgehog"       # противотанковый ёж, 1 м
const FEATURE_DIRT_PILE := "dirt_pile"     # куча земли, 0.5 м (§3.4/§3.7, копка окопа)
const FEATURE_TRENCH := "trench"           # окоп, авто-укрытие выс. 1
const FEATURE_WALL := "wall"               # стена, 2 м
const FEATURE_GLASS := "glass"             # стекло, 2 м (простреливается лазером как стена)
## ЛДФ (бывш. ЛДФ, item 43). Идентификатор НА ДИСКЕ намеренно остался "bru":
## по нему записаны все существующие карты, и переименование строки сделало бы их
## нечитаемыми ради одной только косметики. Переехали имя константы и подпись.
const FEATURE_LDF := "bru"                 # ЛДФ — стена 1×6
const LDF_WALL_LENGTH := 6                 # ЛДФ строится цепочкой из 6 клеток (§3.7)
const FEATURE_CORPSE_WALL := "corpse_wall" # стена из 5 трупов, 2 м
const FEATURE_AIRLOCK := "airlock"         # шлюз (§3.11): закрыт=стена, открыт при юните рядом
## ДПМГ (бывш. ДПМГ, item 43). Идентификатор на диске так же остался "rsp".
const FEATURE_DPMG := "rsp"                 # ДПМГ — стационарный пулемёт (§3.7), укрытие 1 м
const FEATURE_DOT := "dot"                 # ДОТ — армированная бетонная стена, 2 м (§3.7)
## ДОТ с амбразурами: та же бетонная коробка, но сквозь неё стреляет любой боец,
## стоящий вплотную (кроме противотанкиста — его заряд в амбразуру не пролезает).
const FEATURE_DOT_OPEN := "dot_open"
## Мина (item 45). Укрытия не даёт и проходу не мешает — на неё именно НАСТУПАЮТ.
## Спрятана: чужой видит её, только пока сапёр её подсветил (см. GameState.revealed_mines).
const FEATURE_MINE := "mine"
const FEATURE_WOOD_WALL := "wood_wall"     # деревянная стена, 2 м, горючая — сгорает в огне (#53)
## Мешки, сложенные в два яруса — глухая стена 2 м.
const FEATURE_SANDBAG_WALL := "sandbag_wall"
## Ёж поверх мешков — стена 2 м, но НЕ сплошная: сквозь неё стреляют с соседней клетки.
const FEATURE_HEDGEHOG_SANDBAGS := "hedgehog_sandbags"

## Высота укрытия каждого объекта (§3.7). 2 = полноценная стена.
const FEATURE_HEIGHT := {
	FEATURE_DRONE_STATION: 1.0,
	FEATURE_SANDBAGS: 1.0,
	FEATURE_HEDGEHOG: 1.0,
	FEATURE_DIRT_PILE: 1.0,
	# Окоп — ЯМА, а не укрытие над землёй: своей высоты не даёт (глубина ниже, §3.7).
	FEATURE_TRENCH: 0.0,
	FEATURE_WALL: 2.0,
	FEATURE_GLASS: 2.0,
	FEATURE_LDF: 2.0,
	FEATURE_CORPSE_WALL: 2.0,
	FEATURE_AIRLOCK: 2.0,
	FEATURE_DPMG: 1.0,
	FEATURE_DOT: 2.0,
	FEATURE_DOT_OPEN: 2.0,
	FEATURE_MINE: 0.0,
	FEATURE_WOOD_WALL: 2.0,
	FEATURE_SANDBAG_WALL: 2.0,
	FEATURE_HEDGEHOG_SANDBAGS: 2.0,
}

const FEATURE_NAMES := {
	FEATURE_DRONE_STATION: "Drone Station",
	FEATURE_SANDBAGS: "Sandbags",
	FEATURE_HEDGEHOG: "Anti-Tank Hedgehog",
	FEATURE_DIRT_PILE: "Dirt Pile",
	FEATURE_TRENCH: "Trench",
	FEATURE_WALL: "Wall",
	FEATURE_GLASS: "Glass",
	FEATURE_LDF: "LDF",
	FEATURE_CORPSE_WALL: "Corpse Wall",
	FEATURE_AIRLOCK: "Airlock",
	FEATURE_DPMG: "DPMG (Machine Gun)",
	FEATURE_DOT: "Pillbox (Concrete)",
	FEATURE_DOT_OPEN: "Pillbox (Embrasures)",
	FEATURE_MINE: "Mine",
	FEATURE_WOOD_WALL: "Wooden Wall",
	FEATURE_SANDBAG_WALL: "Sandbag Wall",
	FEATURE_HEDGEHOG_SANDBAGS: "Hedgehog on Sandbags",
}

# --- ДПМГ: стационарный пулемёт (§3.7) ---
# Ставится за 1 действие (инженер), стреляет из соседней клетки любым юнитом.
const DPMG_RANGE := 12
const DPMG_RATE_OF_FIRE := 8

# --- Сапёр и мины (item 45) ---
## За одно действие сапёр ставит до пяти мин.
const MINES_PER_ACTION := 5
## Подсветка чужих мин: радиус по Чебышёву, в пределах линии видимости, на 1 ход.
const MINE_REVEAL_RADIUS := 15
const MINE_REVEAL_TURNS := 1
## Урон мины технике по единой шкале (#89) — как у противотанкиста и дрона.
## В источнике эффект мины не описан вовсе; принято: пехоту убивает наповал на
## своей клетке, технике снимает единицу прочности. См. GAME_SPEC §7.9.
const MINE_VEHICLE_DAMAGE := 1

# --- Космос / невесомость (§3.11) ---
# После выстрела (кроме противотанкиста) в невесомости: стрелка отбрасывает на 1 клетку,
# цель — на 2, только если позади свободно. Шлюз открыт, если юнит в радиусе 1 (кроме дронов).
const ZEROG_SHOOTER_KNOCKBACK := 1
const ZEROG_TARGET_KNOCKBACK := 2
const AIRLOCK_OPEN_RADIUS := 1

# --- Укрепления и высоты укрытий (§3.7) ---
# Укрытие высотой 1 м даёт стрелку −2 к броску попадания; 2 м — глухая стена,
# сквозь неё не стреляют вовсе. Бонус к защите цели укрытие не даёт.
const COVER_MOD := {1.0: 2}
# Окоп глубиной 2 м: боец в нём ниже линии огня и неуязвим для стрельбы,
# если стрелок не стоит вплотную (§3.7).
const TRENCH_DEPTH := 2.0
# На противотанкового ежа не встают (#78) — его ПЕРЕПРЫГИВАЮТ за 2 очка движения,
# приземляясь в следующую клетку по той же прямой.
const HEDGEHOG_JUMP_COST := 2
# Стоимость постройки/слома укреплений в ОД (инженер строит, шахтёр ломает).
const BUILD_COST_DEFAULT := 1   # стена/стекло/ЛДФ — 1 действие
const BUILD_COST_HEDGEHOG := 2  # противотанковый ёж — 2 действия
const BUILD_COST_DOT := 2       # ДОТ (армированный бетон) — 2 действия (§3.7)
# Единая шкала урона MCF (#89): 1 прочность = 10 потенциала лазера = 1 взрыв дрона =
# 1 выстрел противотанкиста = 0.5 выстрела танковой пушки. Проверяется по технике:
# челнок 2 прочности = 20 потенциала, танк 6 = 60 (таблица потерь потенциала).
const POTENTIAL_PER_DURABILITY := 10
# ДОТ держит 2 прочности: первое попадание оставляет трещину, второе валит его.
const DOT_DURABILITY := 2
const BUILD_COST_SANDBAGS := 1  # мешки с песком — 1 действие
# Куча земли: копка даёт 1 м за уровень; второй уровень достраивает её до стены 2 м.
const DIRT_HEIGHT_PER_LEVEL := 1.0
const DIRT_MAX_LEVEL := 2
const BREAK_COST := 1           # шахтёр ломает за 1 действие
# Корпусная стена: 5 трупов на клетке образуют стену (§3.7).
const CORPSE_WALL_COUNT := 5
# Как далеко разлетаются тела рухнувшей от взрыва трупной стены (#98), по Чебышёву.
const CORPSE_SCATTER_RADIUS := 3

# --- Огонь (§3.8) ---
const FIRE_SPREAD_FLAMMABLE := 3  # дерево/трава: загорается на 3+
const FIRE_SPREAD_OTHER := 4      # прочий пол: 4+
const FIRE_SHOOT_PENALTY := 1     # стрельба через горящую клетку: −1 к попаданию (кроме снайпера)
# Тип пола: 0 = обычный (4+), 1 = горючий (дерево/трава, 3+).
const FLOOR_NORMAL := 0
const FLOOR_FLAMMABLE := 1

# --- Спецстрельба (см. §3.13, §3.14) ---
# Противотанкист: радиус авто-поражения взрывом (Чебышёв).
const ANTI_TANK_BLAST_RADIUS := 1
# Прочности, снимаемой с техники попаданием противотанкиста (#67). Пехоту его взрыв
# убивает наповал, но броня держит: танк/челнок теряют одну единицу прочности.
const ANTI_TANK_VEHICLE_DAMAGE := 1
# Взрыв дрона по единой шкале урона — те же 1 прочности, что и у противотанкиста.
const DRONE_EXPLOSION_DAMAGE := 1
# Танковая пушка (#63): взрыв — «ромб» радиуса 2 по манхэттенской метрике (13 клеток).
# Углы срезаны: по диагонали снаряд достаёт только на одну клетку.
const CANNON_BLAST_RADIUS := 2

# --- Формы взрывов (#63, #64) ---
## Квадрат Чебышёва: все клетки, отстоящие не более чем на radius по обеим осям.
## Это классический «3×3» противотанкиста при radius = 1.
static func blast_square(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			out.append(Vector2i(center.x + dx, center.y + dy))
	return out

## Ромб (манхэттенский круг): |dx| + |dy| <= radius. Углы квадрата срезаны —
## форма разлёта осколков танкового снаряда (#63).
static func blast_diamond(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if absi(dx) + absi(dy) <= radius:
				out.append(Vector2i(center.x + dx, center.y + dy))
	return out

## «Крест накрест» (X): эпицентр и четыре ДИАГОНАЛИ (#64). Ортогональные соседи
## НЕ задеты — граната бьёт по косой. Форма разлёта осколков ручных гранат.
static func blast_x(center: Vector2i) -> Array[Vector2i]:
	return [
		center,
		center + Vector2i(-1, -1), center + Vector2i(1, -1),
		center + Vector2i(-1, 1), center + Vector2i(1, 1),
	]
# Штурмовик: дробовик задевает не более 3 целей по прямой (первым трём −1 к защите).
const ASSAULT_MAX_TARGETS := 3
const ASSAULT_DEFENSE_PENALTY := 1
# Огнемётчик: длина струи пламени в клетках.
const FLAME_JET_LENGTH := 6
# Марксманн: запас «потенциала» лазера и стоимости пробития (§3.13).
const MARKSMAN_POTENTIAL := 10
const MARKSMAN_AP_COST := 2  # 1 выстрел лазера = оба ОД
## Таблица потери потенциала (#75, авторская таблица к §3.13). Сколько потенциала
## СЪЕДАЕТ объект, чтобы луч его уничтожил и полетел дальше. Объекта нет в таблице →
## луч проходит насквозь бесплатно. Стекло и деревянная стена гибнут даром: 0.
const LASER_COST := {
	FEATURE_GLASS: 0,
	FEATURE_WOOD_WALL: 0,
	FEATURE_AIRLOCK: 1,
	FEATURE_WALL: 2,
	FEATURE_CORPSE_WALL: 3,   # трупы разлетаются вдоль траектории луча
	FEATURE_LDF: 4,
	FEATURE_SANDBAG_WALL: 2,
	FEATURE_HEDGEHOG_SANDBAGS: 2,
	# Укрытие в один метр луч срезает за единицу (#99): раньше низкий мешок стоил столько
	# же, сколько каменная стена, и марксманн глох на первой же насыпи.
	FEATURE_SANDBAGS: 1,
	FEATURE_HEDGEHOG: 1,
	FEATURE_DIRT_PILE: 1,
	FEATURE_DPMG: 1,
	FEATURE_DRONE_STATION: 1,
	# ДОТ — 2 прочности по единой шкале: 20 потенциала за всю коробку, 10 за трещину.
	FEATURE_DOT: DOT_DURABILITY * POTENTIAL_PER_DURABILITY,
	FEATURE_DOT_OPEN: DOT_DURABILITY * POTENTIAL_PER_DURABILITY,
	# Окопа в таблице НЕТ намеренно (#99): луч идёт над ямой, не задевая ни её саму,
	# ни того, кто в ней сидит. Отсутствие в таблице = «пролетает насквозь даром».
}
const LASER_COST_KILL := 2         # живой боец
const LASER_COST_KILL_CORPSE := 3  # боец, несущий труп-щит
const LASER_COST_SHIELD := 4       # щитоносец поглощает 4 и полностью гасит луч
const LASER_COST_TERRAIN_WALL := 2 # безымянная стена рельефа — как обычная стена
## Стекло луч проходит даром и вдобавок фокусируется в нём: каждое второе разбитое
## стекло ВОЗВРАЩАЕТ единицу потенциала (#99). Правило накопительное — четвёртое
## стекло на пути даёт ещё одну единицу, и так далее.
const LASER_GLASS_RECHARGE_EVERY := 2
const LASER_GLASS_RECHARGE := 1
# Щитоносец: толчок щитом — бросок защиты цели с этим штрафом (§3.14).
const SHIELD_PUSH_DEFENSE_PENALTY := 2
# Снайпер: автопопадание на ≤ этой дистанции без укреплений между стрелком и целью (§5).
const SNIPER_AUTOHIT_RANGE := 12

# --- Стороны ---
## Игроки занимают СПЛОШНОЙ диапазон 0..MAX_PLAYERS-1: owner — это просто номер
## игрока, а не член перечисления из трёх значений. PLAYER_1/PLAYER_2 оставлены
## как имена для нулевого и первого — так читается код, писавшийся под дуэль, и
## так же читается хот-сит на двоих, который никуда не делся.
##
## Нейтралы стоят ЗА диапазоном игроков, а не внутри него (раньше NEUTRAL == 2,
## то есть на месте третьего игрока). Значение −1 на эту роль не годится: им уже
## занята «клетка вне зоны развёртывания» в MapData.zone_owner.
const MAX_PLAYERS := 26
const MAX_TEAMS := 13
enum Owner {PLAYER_1 = 0, PLAYER_2 = 1, NEUTRAL = 26}

## Группы активированных нейтралов (§15 «Нейтралы») получают собственные слоты
## инициативы. Их номера начинаются отсюда, чтобы не столкнуться ни с игроками
## (0..25), ни с общим нейтральным слотом (26).
const NEUTRAL_GROUP_BASE := 100
## Больше ста групп не бывает: нумерация римская и кончается на C (100).
const MAX_NEUTRAL_GROUPS := 100

## Игроки зовутся латинскими буквами по порядку слотов: A, B, C, ... Z.
const PLAYER_LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

## Команды зовутся латинизированными греческими буквами со своим символом.
## Список намеренно берёт только 13 букв из 24 — ровно столько, сколько команд.
## Порядок значим, менять нельзя: по нему команда получает имя от своего номера.
const TEAM_NAMES := [
	["Alpha", "Α"], ["Beta", "Β"], ["Gamma", "Γ"], ["Delta", "Δ"],
	["Epsilon", "Ε"], ["Zeta", "Ζ"], ["Theta", "Θ"], ["Iota", "Ι"],
	["Lambda", "Λ"], ["Omicron", "Ο"], ["Tau", "Τ"], ["Omega", "Ω"],
	["Psi", "Ψ"],
]

## Владелец — играющий человек/ИИ (а не нейтрал и не пустое место)?
static func is_player(owner: int) -> bool:
	return owner >= 0 and owner < MAX_PLAYERS

## Владелец — нейтральная сторона? Общий слот и любая активированная группа.
static func is_neutral(owner: int) -> bool:
	return owner == Owner.NEUTRAL or owner >= NEUTRAL_GROUP_BASE

## Номер группы нейтралов (1..100) по её слоту, или 0, если это не группа.
static func neutral_group_index(owner: int) -> int:
	return owner - NEUTRAL_GROUP_BASE + 1 if owner >= NEUTRAL_GROUP_BASE else 0

## Слот группы нейтралов по её номеру (1 → первая группа).
static func neutral_group_slot(index: int) -> int:
	return NEUTRAL_GROUP_BASE + index - 1

## Римская запись 1..100 — номер группы нейтралов на бейдже и в списке инициативы.
static func roman(n: int) -> String:
	if n <= 0 or n > MAX_NEUTRAL_GROUPS:
		return str(n)
	const VALUES := [100, 90, 50, 40, 10, 9, 5, 4, 1]
	const SIGNS := ["C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
	var out := ""
	var left := n
	for i in VALUES.size():
		while left >= VALUES[i]:
			out += SIGNS[i]
			left -= VALUES[i]
	return out

## Имя команды с её греческим символом: «Omega Ω».
static func team_name(team: int) -> String:
	if team < 0 or team >= TEAM_NAMES.size():
		return "No Team"
	return "%s %s" % [TEAM_NAMES[team][0], TEAM_NAMES[team][1]]

# --- Состояние юнита ---
enum Status {ALIVE, CORPSE, HELD}

# --- Типы действий (каждое стоит 1 ОД, см. §3.2) ---
enum ActionType {MOVE, SHOOT, CAPTURE, USE_ITEM}

## Прочность укрепления в единой шкале урона (0 = объект не имеет прочности и
## сносится любым попаданием). Пока прочность есть только у ДОТа.
static func feature_durability(feature_id: String) -> int:
	if feature_id == FEATURE_DOT or feature_id == FEATURE_DOT_OPEN:
		return DOT_DURABILITY
	return 0

## Имя стороны для журнала и HUD. Игрок — по своей букве, группа нейтралов —
## по своему римскому номеру, общий нейтральный слот — просто «Neutral».
static func owner_name(owner: int) -> String:
	if is_player(owner):
		return "Player %s" % PLAYER_LETTERS[owner]
	if owner >= NEUTRAL_GROUP_BASE:
		return "Neutral %s" % roman(neutral_group_index(owner))
	return "Neutral"
