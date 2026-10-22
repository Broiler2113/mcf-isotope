@abstract
extends RefCounted

## The resolver's state: every variable, constant and static cache of GameActionResolver,
## and the declarations the files above need. GameActionResolver is one class spread over a
## chain of files by system — ResolverState, ResolverVision, ResolverDamage, ResolverMovement,
## ResolverWorks, ResolverTargeting, ResolverWeapons, ResolverFurnitureAndFire, ResolverWorld, ResolverDrones,
## ResolverVehicles, ResolverEvents, then GameActionResolver.gd. Code moved as it was; only
## the split itself is new (2026-10).

## Единственная точка изменения состояния (см. §2.2):
##   1) проверка легальности → 2) броски через DiceService →
##   3) применение к состоянию → 4) возврат ActionResult (лог/UI публикует вызывающий).
## Никаких прямых мутаций состояния вне этого класса.

var state: GameState
## Туман войны включён по умолчанию; экран Setup может его отключить (§3.9, isotope §12b).
## При выключенном тумане is_visible_to_team всегда истинно (видно всю карту).
## Режим тумана (item 46). fog_enabled остаётся как «туман вообще есть»: по нему
## устроены все быстрые выходы, и переписывать их на сравнение с OFF незачем.
var fog_mode: int = MCF.Fog.STANDARD

var fog_enabled: bool:
	get:
		return fog_mode != MCF.Fog.OFF
	set(v):
		fog_mode = MCF.Fog.STANDARD if v else MCF.Fog.OFF
## Сторона, которая «знает» позиции всех юнитов, игнорируя туман (#43): ИИ ставит
## сюда свой owner, чтобы целиться в скрытых. На отображение тумана игрока НЕ влияет
## (team_visible_coords не смотрит на этот флаг) — только на легальность прицела ИИ.
var omniscient_side: int = -1
## Дружественный огонь (#100, §6.9). Исторически он ВСЕГДА был включён: оружие не
## разбирает форму, и по своим стрелять можно. Настройка лобби (§7 «Лобби») даёт
## его выключить — и тогда ни прицелиться в союзника, ни поймать чужую пулю спиной
## союзник уже не может. По умолчанию true, то есть поведение прежнее.
##
## В партии без команд флаг не меняет ничего, кроме запрета стрелять в СВОИХ же
## юнитов: «союзник» без команд — это только ты сам.
var friendly_fire_enabled: bool = true
## Разрешено ли вообще покидать машину. Выключается ТОЛЬКО тренировочными картами, где
## весь смысл — заставить воевать корпусами (rl/maps/town_tank.json): иначе политика
## паркует танк и уходит воевать пешком, то есть ровно то, ради чего карта и делалась,
## не происходит.
##
## Живёт здесь, рядом с friendly_fire_enabled, а не в rl/: через резолвер ходят ОБЕ
## стороны, и запрет, поставленный в env_server, связал бы только обучаемого, а
## встроенный ИИ продолжил бы спешиваться. Асимметрия правил — это уже не «карта про
## танки», а «карта, где у соперника больше ходов».
var disembark_enabled: bool = true

## Случайные события (§1.5 лобби, item 61). null или выключенные — событий нет и
## ни одного лишнего кубика не бросается, поэтому старые партии идут прежним потоком.
## Живёт на резолвере, входит в снимок состояния (отсчёт до события переживает откат).
var random_events: RandomEvents = null

## Регистратор повтора матча (M12, item 53). Пока он подключён, resolve() записывает
## броски КАЖДОГО верхнеуровневого действия и отдаёт их ему вместе с намерением —
## этого достаточно, чтобы сыграть партию заново (см. ReplayRecorder).
##
## Тип намеренно нежёсткий (RefCounted, а не ReplayRecorder): резолвер — слой правил,
## и знать про запись ему незачем, он лишь зовёт on_resolved. null — записи нет, и
## тогда ни одной лишней строчки не выполняется.
var replay_recorder: RefCounted = null
## Viewers with no recorded undo/redo need no per-action copies of every soldier.
## Live games retain their existing undo behavior.
var track_undo_history: bool = true
## Optional local presentation state; rules-only and replay simulations need none.
var capture_cosmetics: Callable = Callable()
var restore_cosmetics: Callable = Callable()

## Режим партии (0.12): Annihilation / Capture & Hold / Holdout — его состояние.
var mode: MatchMode = null

## Сколько окопов роется за 1 ОД: обычная пехота — 3, инженер — 6 (§3.7).
const DIG_TRENCHES_NORMAL := 3
const DIG_TRENCHES_ENGINEER := 6

## Стекло — единственное, что бьётся осколочной гранатой (#44), и защищается как
## обычный юнит с бронёй 5+.
const GLASS_ARMOR := 5

# --- Откат (§18.2, item 28) --------------------------------------------------
## Стек отката живёт ЗДЕСЬ, а не в боевом экране, и это главное в исправлении
## сетевого Undo. Пока он лежал в Main.gd, сетевая партия не клала в него ничего
## вовсе (_on_intent_ready уходил в сеть раньше), а если бы клала — стеки у пиров
## были бы разные, и откат развёл бы доски. В резолвере оба пира прогоняют ОДНИ И
## ТЕ ЖЕ намерения, поэтому и снимки складываются одинаковые.
var _undo_stack: Array = []
var _redo_stack: Array = []
## Глубина resolve(): слот мирных резолвит намерения ВНУТРИ чужого resolve()
## (см. play_civilian_slots), и снимок для них брать не надо — откатывают ход
## игрока целиком, а не отдельный шаг жителя.
var _resolve_depth: int = 0

## События потока «кубиков», которые на деле — только анимация, без броска.
const ANIMATION_ONLY_EVENTS := ["walk", "hold", "ap", "focus", "slot", "veh_walk", "effects"]

## Предохранитель длины такого смещения: дальше любого отбрасывания и толчка.
const SLIDE_PATH_CAP := 16
## Пленник, переехавший вместе с носильщиком: [юнит, откуда, куда] — показать его переезд
## после самого хода носильщика. Живёт ровно внутри одного resolve().
var _carried_slide: Array = []

## Owner rule (2026-10-18): a shield bearer can be fired at only from a neighbouring cell.
## Snipers, marksmen and anti-tank soldiers may aim from range; a tank's cannon is its own
## intent (VehicleCannonIntent) and never asks this. Holdout wave shields carry no shield.
const SHIELD_RANGED_ABILITIES := [MCF.ABILITY_SNIPER, MCF.ABILITY_MARKSMAN, MCF.ABILITY_ANTI_TANK]

## Узел, который назвал стрелок текущего действия (веха «Modular tank system»).
##
## Живёт ровно на время одного resolve() и ставится в самом начале обработки выстрела.
## Отдельным полем, а не параметром, потому что путь от намерения до урона машине идёт
## через полдюжины функций (_blast, зачистка области, обход машин), и протаскивать
## сквозь них одну строку значило бы переписать их сигнатуры ради неё одной.
var _aimed_component: String = ""
## Откуда пришёл выстрел — по нему считается БОРТ машины (веха 14.1). NOWHERE = стрелка
## на поле нет (подрыв дрона над корпусом, детонация соседней машины): бортов тогда не
## существует, и доступны все целые узлы.
var _aim_from: Vector2i = NOWHERE

## Стены, у которых есть обломки (0.12.1): разлетаются кусками своей плитки.
const CHUNK_WALLS := {MCF.FEATURE_WALL: true, MCF.FEATURE_SOIL: true, MCF.FEATURE_WOOD_WALL: true,
		MCF.FEATURE_SANDBAG_WALL: true, MCF.FEATURE_ARMOR_WALL: true, MCF.FEATURE_DOT: true}
const PILLBOX_CHUNKS_PER_POINT := 4

const ENGINEER_BUILDABLE := {
	MCF.FEATURE_SANDBAGS: MCF.BUILD_COST_SANDBAGS,
	MCF.FEATURE_WALL: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_GLASS: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_AIRLOCK: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_LDF: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_DPMG: MCF.BUILD_COST_DEFAULT,
	MCF.FEATURE_HEDGEHOG: MCF.BUILD_COST_HEDGEHOG,
	MCF.FEATURE_DOT: MCF.BUILD_COST_DOT,
	MCF.FEATURE_DOT_OPEN: MCF.BUILD_COST_DOT,
	MCF.FEATURE_FLOODLIGHT: 1,
}

const WELD_AIRLOCK_AP := 1

## Ломать может шахтёр (стены/стёкла/ЛДФ) и инженер (свои постройки, сетка).
const BREAKABLE := [
	MCF.FEATURE_WALL, MCF.FEATURE_SOIL, MCF.FEATURE_GLASS, MCF.FEATURE_AIRLOCK, MCF.FEATURE_LDF,
	MCF.FEATURE_WOOD_WALL, MCF.FEATURE_ARMOR_WALL, MCF.FEATURE_ARMOR_GLASS,
	MCF.FEATURE_CORPSE_WALL, MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN,
	MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS, MCF.FEATURE_HEDGEHOG,
]

## Клетки с объектом fid в порядке обхода сетки. Индекс общий на все резолверы (static):
## ИИ заводит новый резолвер на КАЖДОЕ решение. Собирается одним проходом по карте на новой
## сетке, а дальше правится по журналу вида клеток (GridCell.look_changes) — только
## клетки, где объект сменился. Прежде known_mine_cells() перебирала все 62 500 клеток
## карты 250×250 на КАЖДЫЙ разлив хода, а шлюзы и станции пересобирались полным проходом
## на любую стройку.
##
## Заодно индекс держит горящие клетки (_burning_cells_of): огонь пишется в тот же журнал.
##
## Отдаваемый массив — сам индекс: его читают сразу и не держат через действие.
static var _feature_index: Dictionary = {}   # fid -> Array[Vector2i] в порядке обхода
static var _feature_at: Dictionary = {}      # Vector2i -> fid
static var _feature_rev: Dictionary = {}     # fid -> номер правки его списка
static var _burning: Array = []              # горящие клетки в порядке обхода
static var _feature_grid: int = 0
static var _feature_look: int = -1

## «Нигде» — маркер отсутствия клетки в результате поиска по маршруту.
const NOWHERE := Vector2i(-9999, -9999)

## Постройки, которые огонь уничтожает вместе с клеткой (#53, #83). ЛДФ здесь нет
## намеренно: несгораемая секция вообще не загорается (_fire_blocked).
const BURNS_AWAY := [
	MCF.FEATURE_WOOD_WALL, MCF.FEATURE_WALL, MCF.FEATURE_SOIL, MCF.FEATURE_GLASS,
	MCF.FEATURE_ARMOR_GLASS, MCF.FEATURE_AIRLOCK,
]

## Газовые клетки, которые команда видит (0.11.3: «gas shouldn't be visible in any fog of
## war»). Сам газ непрозрачен — что в нём, не видно, — но облако видно там, куда дотянулся
## бы взгляд, будь газ прозрачным: стены и вражеские танки закрывают его как обычно. Кеш —
## до первого шага или правки рельефа (газ — тоже правка обзора).
## ponytail: луч на каждую пару «клетка газа × глаз», с выходом на первом увидевшем;
## если облака станут огромными, считать проходом _sweep по маске без газа.
var _gas_seen: Dictionary = {}   # owner -> [vision_epoch, vision_version, {Vector2i: true}]

var _gas_masks_version := -1
var _gas_masks_grid := 0
var _gas_masks_cache: Array = []

# --- Туман войны: обзор одного бойца ------------------------------------------------
## Что видно ИЗ клетки с радиусом r. Ключ — Vector3i(x, y, r), значение — Array[Vector2i]
## видимых клеток в том же порядке обхода, что был у прежнего сплошного пересчёта.
##
## Кеш ОБЩИЙ на все резолверы (static) и живёт, пока не изменится обстановка ПО ОБЗОРУ,
## то есть GridCell.vision_version. Так и надо: «что видно с клетки» — чистая функция от
## рельефа, она не зависит ни от того, чей это боец, ни от того, кто где стоит (живые
## обзор не перекрывают). AIController создаёт новый GameActionResolver на КАЖДОЕ решение,
## поэтому кеш на экземпляре ему бы ничего не дал.
## Клетки хранятся ПЛОСКИМ индексом (y * width + x) в PackedInt32Array, а не массивом
## Vector2i: в бою на сотню бойцов один пересчёт перебирает под сотню тысяч клеток, и
## упаковка каждой в Variant-вектор стоит дороже самой трассировки луча.
static var _seen_cache: Dictionary = {}
static var _seen_version: int = -1
static var _seen_grid: int = 0
## Плоская таблица «клетка рвёт луч» (1 байт на клетку, индекс y * width + x). Луч
## Брезенхэма на каждом шаге спрашивал grid.cell_fast() и два поля объекта клетки; на
## холодном пересчёте по городу 50×50 это ~80 000 вызовов на бойца — секунда на сторону
## при старте партии, загрузке и K_RESYNC. Байт из PackedByteArray вдвое дешевле, а
## результат тот же бит в бит. Собирается заново вместе с кешем — по тем же условиям.
static var _blockers: PackedByteArray = PackedByteArray()
## Та же таблица, транспонированная (x·высота + y): в ней сплошняком лежат столбцы сетки,
## по которым обход ищет стены октантов |dx| ≥ |dy| (_sweep). Правится вместе с основной.
static var _blockers_t: PackedByteArray = PackedByteArray()
static var _sight_gas: Dictionary = {}
## Потолок кеша: за длинный бой в нём оседает по записи на каждую позицию, где кто-то
## постоял, и адресная чистка (проход по всем ключам) начинает стоить дороже пересчёта.
const SEEN_CACHE_CAP := 8192
## И потолок по объёму: на карте 250×250 с безграничным обзором одна запись — до 62 500
## клеток, и восемь тысяч таких записей — это гигабайты. 16 млн клеток — 64 МБ.
const SEEN_CELLS_CAP := 16_000_000
static var _seen_cells: int = 0
## Чувствительные клетки каждой записи кеша (см. _sweep): ключ тот же, что в _seen_cache.
static var _seen_sens: Dictionary = {}

## Корпуса танков в обзоре. Танк — единственная машина, которая закрывает обзор, и
## закрывает он его только ВРАГУ (не своим и не союзникам): свой экипаж и пехота вокруг
## смотрят сквозь, противник за танком ничего не видит. Челнок и борг обзор не закрывают,
## обломки — тоже: это уже не танк. Меняется набор ровно тогда, когда танк переехал, сменил
## хозяина или сгорел, — все три двигают UnitInstance.vision_epoch (Vehicle.gd), так что
## кеш обзора стороны узнаёт об этом сам.
##
## Набор клеток «чужих танков» для стороны получает постоянный номер (_tank_sigs): номер —
## часть ключа кеша обзора. Номера не переиспользуются, поэтому запись, собранная при
## другом расположении танков, никогда не выдаст себя за нынешнюю.
static var _tank_sigs: Dictionary = {}       # PackedInt32Array (клетки) -> номер
static var _tank_sig_cells: Dictionary = {}  # номер -> PackedInt32Array
static var _tank_sig_next: int = 1
static var _tank_masks: Dictionary = {}      # номер -> [_blockers, _blockers_t] с корпусами танков

## Вражеский танк переехал, сменил хозяина или сгорел — номер набора танков у стороны
## стал другим, и ключ обзора тоже. Но обзор из этой точки меняется, только если одна из
## клеток, где танк был или стал, для него чувствительна (_sweep): иначе вся перемена
## лежит в чужой тени. Тогда запись под прежним номером годится и под новым — без обхода.
## Прежние номера — несколько последних, под которыми смотрела эта сторона.
static var _sig_history: Dictionary = {}   # viewer -> Array номеров, новый последним
const SIG_HISTORY := 4

# --- Туман войны: обзор команды -------------------------------------------------------
## Множество клеток, видимых команде, считается ПРИРАЩЕНИЯМИ.
##
## Раньше на каждое изменение обстановки (то есть на каждое действие) множество строилось
## заново: ~(2r+1)² лучей Брезенхэма на каждого своего бойца. При r=12 и сотне бойцов это
## 62 000 лучей — 17 мс, и ровно столько же на КАЖДЫЙ кадр отрисовки, пока идёт чужой ход.
##
## Теперь на клетку хранится СЧЁТЧИК: сколько своих бойцов её видят. Шаг одного бойца
## снимает счётчики его прежнего обзора и добавляет счётчики нового — пара сотен операций
## вместо шестидесяти тысяч лучей.
##
## Счётчики живут в ОТДЕЛЬНОМ словаре с плоским целым ключом (y*width+x), а наружу
## отдаётся привычное множество Vector2i. Разделение не косметическое: пересчёт трогает
## счётчик каждой видимой клетки каждого бойца (под сотню тысяч раз), а вот НАБОР клеток
## меняется только там, где счётчик перешёл через ноль — таких клеток на порядок меньше.
## Значит Vector2i строится ровно на переходах, а не на каждом касании.
##
## Полный пересчёт не остаётся ни на один случай, кроме смены сетки и переключения самого
## тумана. Смерть бойца, посадка в машину, подкрепление и даже РУХНУВШАЯ СТЕНА разбираются
## приращениями: у каждого бойца хранится его последний обзор, и работа идёт только там,
## где он изменился. Рельеф правится точечно (GridCell.vision_changes), поэтому упавшая
## стена меняет обзор нескольким бойцам рядом, а не всей армии.
##
## Хранить сам ПРЕЖНИЙ обзор, а не позицию бойца, здесь обязательно. Снять старый вклад
## можно только тем же множеством клеток, каким он был добавлен, — а «пересчитать обзор
## из прежней клетки» после изменения рельефа дало бы уже другое множество, и счётчики
## разъехались бы навсегда.
var _vis_set: Dictionary = {}      # owner -> {Vector2i: true} — то, что отдаётся наружу
var _vis_counts: Dictionary = {}   # owner -> {плоский индекс: сколько бойцов видят}
var _vis_seen: Dictionary = {}     # owner -> {unit_id: PackedInt32Array} — учтённый вклад
var _vis_epoch: Dictionary = {}    # owner -> UnitInstance.vision_epoch на момент сборки
var _vis_vv: Dictionary = {}       # owner -> GridCell.vision_version на момент сборки
var _vis_grid: int = 0
var _vis_mode: int = -1
## Чьи глаза вливаются в обзор стороны: она сама плюс союзники по команде (§9
## «Туман войны», слияние обзора). Кешируется, потому что спрашивается в горячем
## цикле team_sees() — на КАЖДЫЙ выстрел по каждой возможной цели.
##
## Состав команд по ходу боя не меняется (его задаёт лобби до начала партии), так
## что кеш держится за экземпляр ростера и сбрасывается только вместе с ним.
var _ally_sets: Dictionary = {}
var _ally_roster: int = 0

## Множество клеток, видимых команде (для тумана в UI).
var sight_positions: Dictionary = {}
## Обзоры из промежуточных клеток перехода (вид во время ходьбы, fix-7 #4): ключ кеша →
## видимые клетки. В общий кеш они не идут — отряд из сорока бойцов за шесть шагов
## вытеснял оттуда обзоры всей стоящей армии, и после ходьбы её пересчитывали целиком.
## Действует, пока не сменились стены (_seen_local_vv).
var _seen_local: Dictionary = {}
var _seen_local_vv := -1

## Fog off with gas or smoke on the board (mode 2). Every eye's window is the whole board and
## only the clouds stop sight, so one soldier's view is the board minus a few shadows. The
## per-soldier path paid for each view in full: on a 250×250 board that is 70 000 cells per
## soldier, and one cloud froze every action for seconds. Here an eye contributes only its
## shadow (_sweep_hidden, the exact complement of _sweep), and a cell is hidden from the team
## when every eye's shadow holds it. The set is the same, cell for cell (run_gas_vision).
## null: someone's window is smaller than the board, and the per-soldier path decides.
var _gas_view: Dictionary = {}   # owner -> what _vis_set[owner] was last built from

## [grid id, owner] -> {gas, eyes, counts, hidden}: how many eyes' shadows hold each cell and
## the cells all of them hold. Static, so the fresh resolver the AI builds per decision reuses
## it; a move only swaps one eye's shadow in the counts. `hidden` is never edited in place.
static var _gas_teams: Dictionary = {}

## The cloud cells, sorted: the key every shadow is valid under.
static var _gas_cells_key: Array = []   # [vision_version, grid id]
static var _gas_cells_now := PackedInt32Array()

## origin -> its shadow under the clouds in _shadows_of; flushed when the clouds change.
static var _shadows: Dictionary = {}
static var _shadows_of: Array = []   # [grid id, cloud cells]
static var _shadow_cells := 0
const SHADOW_CELLS_CAP := 8_000_000

## Every cell of the board as a set, built once per board: the starting point of a view.
static var _all_cells_grid := 0
static var _all_cells_set: Dictionary = {}

## Журнал смен видимости для экрана боя: owner -> Array плоских индексов клеток, чья
## видимость сменилась с прошлого take_vis_changes(). Заводится первым же вызовом — пока
## его никто не спрашивает (ИИ, обучение, тесты), он не пишется вовсе.
var _vis_log: Dictionary = {}

## Память разведки (item 46, режим STANDARD): owner -> {Vector2i: true}, всё, что
## сторона когда-либо видела.
##
## Живёт В РЕЗОЛВЕРЕ, а не в GameState, и это осознанно. Память копится ровно тогда,
## когда кто-то СПРАШИВАЕТ обзор стороны, а спрашивают его хост и клиент про разные
## стороны — каждый про свою. Лежи она в состоянии, партия бы тихо разъезжалась:
## поле, которое ни один слепок не сверяет и ни один тест не ловит. Это ровно тот
## класс поломки, который чинил M2, и заводить его заново нельзя.
##
## Как поле показа она к тому же и не нужна в состоянии: каждый клиент рисует свою
## сторону и накапливает ровно свою память.
##
## В REALISTIC режиме память не нужна вовсе — там вне обзора не видно ничего, — но
## копим её всегда: переключить режим посреди партии дешевле, чем восстанавливать
## историю задним числом, а пополняется она только клетками, впервые вошедшими в обзор.
var explored: Dictionary = {}

## Кандидаты на пробуждение (§3 «Нейтралы»): id спящих нейтралов, к которым подобрался
## повод активации — соседняя клетка сменила состояние или в поле зрения вошёл солдат.
## Копятся между действиями и разбираются каскадом в _wake_and_group на верхнем уровне
## resolve(); пустой список — обычное состояние, обходится в один if.
var _activation_frontier: Array[int] = []

## Клетки, с которых нейтрала можно «увидеть» (§3.1b): живые солдаты и корпуса техники
## игроков (item 12), разложенные по линиям огня — строка, столбец, две диагонали. Раньше
## каждый спящий житель перебирал ВСЕХ солдат (и заново собирал их список): 150 жителей ×
## 90 солдат давали ~80 мс на каждое действие в большой партии. Теперь проверяются только
## те, кто с ним на одной прямой, — ровно те, кого пропускал Combat.is_on_firing_line.
## Отладка/тест: шлюзы и пробуждение жителей всегда считаются полностью, без выборки
## «что изменилось». Итог обязан совпасть — это и проверяет tests/run_mp_perf.gd.
var check_everything := false

var _wk_pos: Dictionary = {}   # солдат -> клетка на прошлой проверке пробуждения
var _wk_vv: int = -1
var _wk_vsig: int = 0
var _wk_grid: int = 0

var _wk_seen: Dictionary = {}   # жители, видевшие солдата на прошлой проверке
var _wk_sleepers: Dictionary = {}   # спящие жители на прошлой проверке

## Штаб мирного квартала (#103). Ровно тот же класс, что водит армию ИИ, только с
## нейтральным владельцем: см. большой комментарий в AIController. Хранится на резолвере,
## чтобы план строился ОДИН раз на слот жителей, а не заново на каждое их действие.
var _civ_brain: AIController = null

## Потолок действий за один слот жителей. Страховка, а не правило: каждое действие
## тратит ОД или несомый труп, поэтому цикл и так конечен. Но резолвер зовут из UI-потока,
## и молчаливый вечный цикл здесь означал бы намертво зависшую игру, а не сообщение
## в консоли, — поэтому предохранитель стоит.
const CIVILIAN_ACTION_CAP := 600

# --- Космос / невесомость (§3.11) ---

## Пересчёт состояния шлюзов: открыт (проходим/простреливаем), если рядом (радиус 1)
## стоит любой живой юнит, кроме дрона; иначе закрыт (работает как стена).
## Функцию зовут после КАЖДОГО действия, а шлюзов на карте единицы — поэтому список
## живых юнитов берётся один раз на всю сетку, а не заново на каждый шлюз, и клетка
## достаётся без проверки границ (координаты и так свои).
## Список клеток-шлюзов, общий на все резолверы. Берётся из индекса объектов
## (_feature_cells_of) и пересобирается, только когда сменился сам список шлюзов, а не
## после каждого действия: шлюзы строят и сносят единицы раз за бой, тогда как
## update_airlocks() зовут по разу на КАЖДОЕ действие.
static var _airlock_cells: Array[GridCell] = []
static var _airlock_index: Dictionary = {}   # GridCell -> номер в _airlock_cells
static var _airlock_version: int = -1        # правка списка шлюзов в индексе объектов
static var _airlock_grid: int = 0

## Шлюзы, которые МОГУТ сменить состояние, — в порядке общего списка. Дверь теперь у
## каждого дома и комнаты, и на карте 250×250 их сотни; перебирать все с осмотром
## девяти клеток на каждое действие (а ход — это два вызова) стоило ~5 мс впустую:
## закрытая дверь без никого рядом закрытой и останется.
##
## Сменить состояние может только шлюз, который (а) был открыт после прошлого прохода —
## мог закрыться; (б) стоит рядом с живым бойцом — мог открыться; (в) открылся или
## закрылся с тех пор в обход этого прохода (откат, взрыв, сварка) — такое пересечение
## порога стены пишет журнал обзора GridCell.vision_changes. Тело в проёме держит
## створки открытыми, а открытыми они стали, пока тело было живым, — это случай (а).
## Если журнал оборвался, сменилась сетка или сам список шлюзов — проходим все.
var _al_open: Array[GridCell] = []
var _al_vv: int = -1
var _al_fv: int = -1
var _al_grid: int = 0
## Живые бойцы на прошлом пересчёте шлюзов: id -> клетка (см. _airlock_candidates).
var _al_pos: Dictionary = {}

const DRONE_DIRS_8 := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## Клетка → откуда в неё прилетели по кратчайшему маршруту. Заполняет _drone_reach,
## читает _drone_route (item 12): по ней восстанавливается ПУТЬ, а не только цена.
## Живёт ровно до следующего запроса разлёта — это черновик одного расчёта, не состояние.
var _drone_prev: Dictionary = {}

# --- Перетаскивание трупов и лёгких объектов (§3.4): без броска, БЕЗ ОД, без лимита ---
# Тащить можно труп, мешки с песком, ежа, кучу земли (≤1 м) на соседнюю клетку.
const DRAGGABLE_FEATURES := [
	MCF.FEATURE_SANDBAGS, MCF.FEATURE_HEDGEHOG, MCF.FEATURE_DIRT_PILE,
]

const DPMG_DIRS := [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
		Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]

# =====================================================================================
#  Случайные события (0.9.4, спека «Random Event System»)
# =====================================================================================
## Событие не падает в тот же миг, когда выпало: СНАЧАЛА ОБЪЯВЛЕНИЕ в начале раунда, потом
## удар в конце того же раунда — у каждого игрока ровно один ход (0.11). Параметры (где зона, с какого края
## армия) катаются при объявлении, исход по клеткам — при падении; оба порядка жёстко
## зафиксированы, поэтому хост и клиент прокатывают один поток d6 и сходятся.
##
## Выключенные события (или пустая очередь) не бросают НИ ОДНОГО кубика — поток случайности
## старых партий цел.

## Обстрел: сторона зоны в клетках и порог попадания по клетке (4+ на d6 — ровно половина).
##
## Зона НЕ бывает во всю карту, хотя спека это допускала: на поле 250×250 это 70 000
## бросков d6 за одно событие — и столько же чисел в журнале кубиков, который хост
## отправляет гостю и пишет повтор. Батарея накрывает квадрат, а не планету.
const BARRAGE_SIDE_MIN := 3
const BARRAGE_SIDE_MAX := 16
const BARRAGE_HIT_MIN := 4
## Газ: сторона облака (не больше GAS_SIDE_MAX и не больше трети карты) и сколько раундов
## он стоит. Спасброска нет: каждый раунд свой бросок, 1–2 — смерть.
const GAS_SIDE_MIN := 3
const GAS_SIDE_MAX := 14
const GAS_ROUNDS := 3
const GAS_SURVIVE_MIN := 3
## Независимая армия: длина участка края, на котором она высаживается, и во сколько раз
## её сила отличается от средней армии игрока.
const ARMY_SEGMENT_MIN := 4
const ARMY_SEGMENT_MAX := 10
const ARMY_STRENGTH := 1.0
## Из кого набирается независимая армия: боевые профессии. Мирных, командиров и операторов
## дронов в ней нет — командовать ей некем, а станций у неё не бывает.
const ARMY_ROSTER := ["light_infantry", "heavy_infantry", "machinegunner",
		"sniper", "marksman", "anti_tank", "flamethrower", "shield_bearer", "engineer",
		"miner", "sapper"]
## Если у игроков вообще нечего мерить (нулевая цена), армия приходит такой.
const ARMY_FALLBACK_UNITS := 6

## Доля обстрелов, которые ищут скопление бойцов, а не случайное место (item 6): 4 из 6.
const BARRAGE_SEEK_ON := 4

## И больше этого числа ЖИВЫХ независимых армий на карте не бывает.
const ARMY_MAX := 2

var _army_stats_cache: Dictionary = {}

## Концы коридоров (issues-12 #13): клетка прохода шириной до 3, упёршаяся в стену, за
## которой такой же узкий проход тянется ещё HALL_MIN_RUN клеток. Комнату (шире 3, или
## узкую, но короткую — кладовку, санузел) и дверной проём (за ним снова пол) правило не
## ловит; дверь сбоку проход не расширяет — это вход в комнату. Обход по строкам —
## порядок у всех пиров один. Проходимость — одной маской: на 274×274 поклеточные
## запросы к сетке стоили секунду.
const HALL_MIN_RUN := 7

var _cover_cache: Dictionary = {}

var _fc_unit: Dictionary = {}    # id врага -> [ключ, клетки досягаемости, клетки огня, значения]
var _fc_total: Dictionary = {}
var _fc_grid: int = 0

## Smoke and gas (owner, 2026-10-19): aimed fire into, out of or through a cloud is
## allowed but blind — this much is added to the number the hit die needs.
const SMOKE_HIT_PENALTY := 2

const DIR8 := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## Танк ходит и целится ТОЛЬКО по четырём сторонам света (item 2): диагональные
## развороты и стрельба по диагонали убраны. Пушка и так била лишь по прямой
## (cannon_port), а фронт теперь тоже ограничен ортогональю.
const DIR4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## «Клетка» экипажа внутри машины — вне поля, чтобы любые проверки по координатам
## (обзор/дальность/цели) автоматически исключали пассажиров (§техника).
const OFFBOARD := Vector2i(-9999, -9999)

## Где высадится волна: из трёх бросков края — тот, что дальше всего от защитников.
## Волна, упавшая прямо в окопы, — не штурм, а лотерея; и кубики те же у всех пиров.
const WAVE_EDGE_ROLLS := 3


# =====================================================================================
#  События 0.12: пожар, ЭМИ, пыльная буря, обрушение, подкрепление, награда, старые мины
# =====================================================================================

## Пожар события: свой «поджигатель», которого нет в очереди ходов — его огонь расползается
## раз в раунд, в land_random_events, а не на чьём-то ходу.
const EVENT_FIRE_OWNER := -2
## Владелец старых мин: ничей — их не видит никто, пока сапёр не подсветит.
const OLD_MINE_OWNER := -2
const FIRE_SIDE := 3
const EMP_SIDE := 7
const COLLAPSE_SIDE := 3
## Обрушение: d6 на бойца в зоне, ниже этого — завален.
const COLLAPSE_SURVIVE_MIN := 3
const DUST_ROUNDS := 2
## Пыльная буря: дальше стольких клеток выстрелу нужно на одно больше.
const DUST_CLEAR := 3
const BOUNTY_ROUNDS := 3
## Старая мина рвётся на d6 не ниже этого (треть шагов); кладётся на клетку поля на 5+.
const OLD_MINE_GOES_OFF := 5
const MINEFIELD_LAY_ON := 5
const MINEFIELD_RADIUS := 4
const MINEFIELD_MAX := 10
## Подкрепление: приходит, если слабейшая сторона отстаёт на эту долю от сильнейшей, и
## привозит такую долю разницы.
const REINFORCE_GAP := 0.2
const REINFORCE_SHARE := 0.5
## Стены, которые рушатся: обычные, деревянные и стекло (не броня, не грунт бункера).
const COLLAPSIBLE := [MCF.FEATURE_WALL, MCF.FEATURE_WOOD_WALL, MCF.FEATURE_GLASS]

var _old_mine_roll := 0

# --- Declared here, defined in a file further up the chain ------------------------
## So the files below them can call them (GDScript resolves calls at parse time).
@abstract func _spoil_word() -> String
@abstract func resolve(intent: Intent) -> ActionResult
@abstract func _capture_visual_hold(res: ActionResult, area: Array) -> void
@abstract func _blast(center: Vector2i, res: ActionResult = null, cells: Array[Vector2i] = [],
		epicenter_debris: bool = true, kills_shield: bool = false) -> Array
@abstract func _extinguish_cell(cell: GridCell) -> bool
@abstract func _step_toward(from_coord: Vector2i, to_coord: Vector2i) -> Vector2i
@abstract func _is_shield(u: UnitInstance) -> bool
@abstract func is_fireproof(u: UnitInstance) -> bool
@abstract func stack_onto(cell: GridCell, new_fid: String) -> String
@abstract func _mine_flash(res: ActionResult, coord: Vector2i) -> void
@abstract func _detonate_mine(coord: Vector2i, victim: UnitInstance, res: ActionResult) -> void
@abstract func move_tier_budgets(unit: UnitInstance) -> Array[int]
@abstract func reachable_for(unit: UnitInstance, budget: int, blocked: Dictionary = {},
		vacated: Dictionary = {}, stop_at := Vector2i(-1, -1)) -> Movement.Reachability
@abstract func _fire_on_path(unit: UnitInstance, path: Array) -> Vector2i
@abstract func _mine_on_path(unit: UnitInstance, path: Array) -> Vector2i
@abstract func _resolve_smash_furniture(actor: UnitInstance, coord: Vector2i) -> ActionResult
@abstract func _destroy_furniture(cell: GridCell, res: ActionResult, from: Vector2i = NOWHERE) -> void
@abstract func _lamp_shards(res: ActionResult, c: Vector2i, from: Vector2i, side: int = -1) -> void
@abstract func _put_down_furniture(actor: UnitInstance, coord: Vector2i) -> ActionResult
@abstract func notify_cell_changed(coord: Vector2i) -> void
@abstract func update_airlocks() -> void
@abstract func _apply_zero_g(shooter: UnitInstance, target: UnitInstance, res: ActionResult = null) -> void
@abstract func _recoiled(result: ActionResult, shooter: UnitInstance, aim: Vector2i) -> ActionResult
@abstract func vehicle_covering(c: Vector2i) -> Vehicle
@abstract func _drone_destroyed(drone: UnitInstance, center: Vector2i, why: String,
		radius: int = MCF.ANTI_TANK_BLAST_RADIUS) -> ActionResult
@abstract func _drone_explode(drone: UnitInstance, center: Vector2i, why: String,
		radius: int = MCF.ANTI_TANK_BLAST_RADIUS) -> ActionResult
@abstract func _launch_drone_at(station: Vector2i, pilot: UnitInstance, scout := false) -> UnitInstance
@abstract func _destroy_drone_station(coord: Vector2i) -> void
@abstract func deployed_station_of(operator: UnitInstance) -> Vector2i
@abstract func _drone_at(coord: Vector2i) -> UnitInstance
@abstract func held_unit_of(captor: UnitInstance) -> UnitInstance
@abstract func _gas_survival(u: UnitInstance, res: ActionResult) -> void
@abstract func _sync_gas() -> void
@abstract func gas_blocks_line(a: Vector2i, b: Vector2i) -> bool
@abstract func _line_off_board(a: Vector2i, b: Vector2i) -> bool
@abstract func _validate_actor(unit: UnitInstance, credit: int = 0) -> String
@abstract func _sync_borg(unit: UnitInstance) -> void
@abstract func borg_of(u: UnitInstance) -> Vehicle
@abstract func _seated(veh: Vehicle) -> bool
@abstract func seated_vehicle_of(u: UnitInstance) -> Vehicle
@abstract func _shuttle_passengers_hit(veh: Vehicle, center: Vector2i, in_area: Dictionary,
		res: ActionResult) -> Array
@abstract func cannon_blast_cells(veh: Vehicle, center: Vector2i) -> Array[Vector2i]
@abstract func cannon_port(veh: Vehicle, target: Vector2i) -> Vector2i
@abstract func _damage_vehicles_in_area(area: Array[Vector2i], center: Vector2i, amount: int,
		source_id: int, res: ActionResult, source: String = "cannon",
		aimed: String = "", roll_location: bool = true) -> void
@abstract func _aimable_components(veh: Vehicle, from: Vector2i) -> Array
@abstract func _damage_component(veh: Vehicle, comp: String, amount: int, source: String,
		res: ActionResult) -> void
@abstract func fixture_at(c: Vector2i, side: int = -1) -> String
@abstract func facing_lamp_side(shooter: UnitInstance, c: Vector2i) -> int
@abstract func can_shoot_fixture(shooter: UnitInstance, c: Vector2i, side: int = -1) -> String
@abstract func _resolve_shoot_fixture(shooter: UnitInstance, c: Vector2i, side: int, shots: int) -> ActionResult
@abstract func hit_need(dist: int, fire_range: float) -> int
@abstract func sniper_need(dist: int) -> int
