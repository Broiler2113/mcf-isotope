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
const ITEM_BRU := "bru"  # стартовый предмет инженера (§3.7)

const ITEM_NAMES := {
	ITEM_FRAG: "Frag Grenade",
	ITEM_EXTINGUISHER: "Fire Extinguisher Grenade",
	ITEM_DRONE_STATION: "Drone Station",
	ITEM_BRU: "BRU",
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
#   • РСП (стационарный пулемёт) — это стреляющая сущность; проще как неподвижный
#     UnitInstance, отложено. ДОТ автор пометил «в разработке».
# Мешки/ёж/окоп как ДАННЫЕ КАРТЫ работают через cover_height (система укрытий §3.7).
const FEATURE_DRONE_STATION := "drone_station"
const FEATURE_SANDBAGS := "sandbags"       # мешки с песком, 1 м
const FEATURE_HEDGEHOG := "hedgehog"       # противотанковый ёж, 1 м
const FEATURE_DIRT_PILE := "dirt_pile"     # куча земли, 0.5 м (§3.4/§3.7, копка окопа)
const FEATURE_TRENCH := "trench"           # окоп, авто-укрытие выс. 1
const FEATURE_WALL := "wall"               # стена, 2 м
const FEATURE_GLASS := "glass"             # стекло, 2 м (простреливается лазером как стена)
const FEATURE_BRU := "bru"                 # БРУ — стена 1×6
const BRU_WALL_LENGTH := 6                 # БРУ строится цепочкой из 6 клеток (§3.7)
const FEATURE_CORPSE_WALL := "corpse_wall" # стена из 5 трупов, 2 м
const FEATURE_AIRLOCK := "airlock"         # шлюз (§3.11): закрыт=стена, открыт при юните рядом
const FEATURE_RSP := "rsp"                 # РСП — стационарный пулемёт (§3.7), укрытие 1 м
const FEATURE_DOT := "dot"                 # ДОТ — армированная бетонная стена, 2 м (§3.7)
## ДОТ с амбразурами: та же бетонная коробка, но сквозь неё стреляет любой боец,
## стоящий вплотную (кроме противотанкиста — его заряд в амбразуру не пролезает).
const FEATURE_DOT_OPEN := "dot_open"
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
	FEATURE_BRU: 2.0,
	FEATURE_CORPSE_WALL: 2.0,
	FEATURE_AIRLOCK: 2.0,
	FEATURE_RSP: 1.0,
	FEATURE_DOT: 2.0,
	FEATURE_DOT_OPEN: 2.0,
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
	FEATURE_BRU: "BRU",
	FEATURE_CORPSE_WALL: "Corpse Wall",
	FEATURE_AIRLOCK: "Airlock",
	FEATURE_RSP: "RSP (Machine Gun)",
	FEATURE_DOT: "Pillbox (Concrete)",
	FEATURE_DOT_OPEN: "Pillbox (Embrasures)",
	FEATURE_WOOD_WALL: "Wooden Wall",
	FEATURE_SANDBAG_WALL: "Sandbag Wall",
	FEATURE_HEDGEHOG_SANDBAGS: "Hedgehog on Sandbags",
}

# --- РСП: стационарный пулемёт (§3.7) ---
# Ставится за 1 действие (инженер), стреляет из соседней клетки любым юнитом.
const RSP_RANGE := 12
const RSP_RATE_OF_FIRE := 8

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
const BUILD_COST_DEFAULT := 1   # стена/стекло/БРУ — 1 действие
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
	FEATURE_BRU: 4,
	FEATURE_SANDBAG_WALL: 2,
	FEATURE_HEDGEHOG_SANDBAGS: 2,
	# Укрытие в один метр луч срезает за единицу (#99): раньше низкий мешок стоил столько
	# же, сколько каменная стена, и марксманн глох на первой же насыпи.
	FEATURE_SANDBAGS: 1,
	FEATURE_HEDGEHOG: 1,
	FEATURE_DIRT_PILE: 1,
	FEATURE_RSP: 1,
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
enum Owner {PLAYER_1 = 0, PLAYER_2 = 1, NEUTRAL = 2}

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

static func owner_name(owner: int) -> String:
	match owner:
		Owner.PLAYER_1: return "Player 1"
		Owner.PLAYER_2: return "Player 2"
		_: return "Neutral"
