@abstract
extends Node2D

## The battle screen's state: every variable, constant and inner layer of Main, and the
## declarations the files above need. Main is one class spread over a chain of files by
## system — MainState, MainBoardView, MainFogMemory, MainDrawing, MainAnnotations,
## MainPresentation, MainVehicles, MainOrders, MainHud, MainReplay, MainNet, then
## scenes/Main.gd. Code moved as it was; only the split itself is new (2026-10).

## Играбельный hotseat-срез (M1): движение, стрельба с дроблением, смерть/труп.
## Клик по юниту → меню действий (§1). Вся логика — через Intent → Resolver.
## Рендер на примитивах (§1: плейсхолдеры).

const CELL := 40
const ORIGIN := Vector2(40, 40)
const GRID_W := 16
const GRID_H := 12

## Готовые подписи высот укрытия для _draw(): высот всего пять, а «%.1fm» % h в теле
## поклеточного цикла — это до 2500 новых строк на кадр на пустом месте.
const HEIGHT_LABELS := {0.5: "0.5m", 1.0: "1.0m", 1.5: "1.5m", 2.0: "2.0m"}

## Буквенные метки объектов, когда картинки-замены для них нет. Раньше этот словарь
## собирался ЛИТЕРАЛОМ внутри поклеточного цикла _draw() — то есть заново на каждый
## объект на карте в каждом кадре. Здесь он строится один раз при загрузке скрипта.
const FEATURE_TAGS := {
	MCF.FEATURE_DRONE_STATION: "ST", MCF.FEATURE_SANDBAGS: "SB",
	MCF.FEATURE_HEDGEHOG: "hdg", MCF.FEATURE_TRENCH: "tr",
	MCF.FEATURE_WALL: "##", MCF.FEATURE_GLASS: "▢",
	MCF.FEATURE_SOIL: "░░",
	MCF.FEATURE_LDF: "LDF",
	MCF.FEATURE_CORPSE_WALL: "††", MCF.FEATURE_AIRLOCK: "AL",
	MCF.FEATURE_DIRT_PILE: "drt", MCF.FEATURE_DPMG: "MG",
	MCF.FEATURE_DOT: "PBX", MCF.FEATURE_WOOD_WALL: "WD",
	MCF.FEATURE_SANDBAG_WALL: "SB", MCF.FEATURE_HEDGEHOG_SANDBAGS: "hSB",
	MCF.FEATURE_DOT_OPEN: "PBX+",
	MCF.FEATURE_MINE: "!",
	MCF.FEATURE_AV_MINE: "AV",
	# Броневые версии подписаны отдельно: по виду они те же стена и стекло, а правила
	# у них совсем другие, и спутать их на доске нельзя.
	MCF.FEATURE_ARMOR_WALL: "A##",
	MCF.FEATURE_ARMOR_GLASS: "A▢",
}

## Хелпер оформления окон в стиле «2003 Steam» (preload, без class_name).
const SteamChrome = preload("res://src/ui/SteamChrome.gd")

## GRAB — единая «рука» (#50): и захват бойца, и волочение трупа/мешков/ежа/кучи земли.
## Отдельного режима DRAG больше нет — кнопка одна, цели показываются вместе.
enum Mode {NONE, MENU, MOVE, SHOOT, GRAB, ITEM, PUSH, DRONE_FLY, BUILD, BUILD_WALL, BREAK, DPMG_FIRE, DIG, CARRY_DROP,
	CORPSE_DROP, WELD, MOVE_HELD, MINE, DISARM,
	GROUP_MENU, GROUP_MOVE, GROUP_LASER,
	VEH_MENU, VEH_MOVE, VEH_TURN, VEH_CANNON, VEH_DISEMBARK, VEH_SEAT, VEH_BOARD_SEAT,
	DRAW, ERASE, RULER, BOARD_PICK, CARRY_FURN, PUT_FURN}

## Линейка (item 11): два конца и клетка под курсором. Инструмент чисто зрительский —
## состояния не трогает, по сети не ходит, в повтор не пишется.
##
## Меряет она ту же дистанцию, что и правила (Combat.distance — «клетки по-королевски»,
## диагональ равна прямой), а не расстояние по экрану: линейка, показывающая не то
## число, по которому считается попадание, была бы хуже, чем никакой.
var _ruler_a := Vector2i(-1, -1)
var _ruler_hover := Vector2i(-1, -1)
## Закреплённые отрезки линейки — их может быть сколько угодно: [начало, конец].
var _rulers: Array = []
var _ruler_btn: Button = null
## Отряд, выделенный до группового приказа: _after_action выделяет его снова.
var _regroup_ids: Array[int] = []
## Потолки зон хода за 1/2/3 ОД (resolver.move_tier_budgets), см. _enter_move.
var _reach_tiers: Array[int] = []
## Зона полёта дрона (клетка -> цена) и потолок подлёта — для _draw_zone_preview.
var _drone_costs: Dictionary = {}
## Маршрут полёта до наведённой клетки, с памятью на то, для какой клетки он посчитан:
## путь рисуется каждый кадр, а Дейкстра по зоне полёта — не то, что стоит гонять по
## шестьдесят раз в секунду.
var _drone_path: Array[Vector2i] = []
var _drone_path_for := Vector2i(-2, -2)
var _drone_path_from := Vector2i(-2, -2)
var _drone_budget: int = 0
## Потолки зон хода машины за 1/2/3 ОД (resolver.vehicle_tier_budgets).
var _veh_tiers: Array[int] = []

## Аннотации на поле (item 51). Каждый штрих — список клеток, автор и область видимости.
enum DrawScope {SELF, TEAM, ALL}
## Рисунки на поле — растровые холсты по (автор, область видимости) (item 15: «как в Paint»).
var _canvases: Dictionary = {}       # Vector2i(author, scope) -> DrawCanvas
var _cur_stroke: Array = []          # точки текущего штриха/хода ластика (уйдут по сети)
var _stroke_drawing: bool = false
var _draw_scope_team: bool = false  # рисовать «для команды», иначе только себе
var _draw_scope_all: bool = false   # рисовать «для всех», и для врагов (batch 17, item 10)
var _hide_others_draw: bool = false # скрыть чужие рисунки целиком (item 51 — фильтр)
var _hide_my_draw: bool = false     # скрыть свои (batch 17, item 10)
var _hide_all_draw: bool = false    # скрыть все (batch 17, item 10)
const K_CHAT := "chat"
## Выпадающий темп ИИ на панели (item 5).
var _ai_speed_opt: OptionButton = null
## Строка темпа целиком: видна при ИИ в составе или налётчиках на поле (0.11.3).
var _ai_speed_row: Control = null
## Игрок уже подтвердил выстрел по своим (item 13) — повторный клик идёт без вопроса.
var _beam_confirmed := false
const K_DRAW := "draw"
## Игрок нажал «Roll» (batch 12 #14): его бросок открывается на ВСЕХ экранах разом.
## Значения кубиков давно известны (их бросил хост при резолве), по сети едет только
## жест — поэтому рассинхрона быть не может, а ждать нажатия обязаны все.
const K_ROLL := "roll"
## Слот стал ИИ посреди боя (batch 13 #2): хост сообщает гостям, что ушедшего игрока
## ведёт машина — их ростер перестаёт ждать его бросков.
const K_SIDE_AI := "side_ai"
## Исход партии объявляет ХОСТ (batch 14): гость свою доску победой не считает —
## иначе рассинхрон рисовал бы «Player B wins» посреди чужого хода.
const K_OVER := "match_over"
## Хост сменил темп ИИ (item 5): гости показывают ходы ИИ с той же скоростью, иначе у них
## копилась бы очередь анимаций или, наоборот, всё мелькало бы.
const K_AI_SPEED := "ai_speed"

## Режимы, чей предпросмотр читает клетку под курсором. Каждому движению мыши нужен
## свой кадр (#97), иначе картинка обновляется только когда камера что-то дёрнет —
## именно так пропадал круг взрыва у пушки, пока режим не был в этом списке.
## Налёт травяного пола (#14) — им же красит клетку редактор карт.
const GRASS_TINT := Color(0.32, 0.55, 0.18, 0.35)
## Копоть на побитом полу (#21.1), когда картинки-замены нет.
const SCORCH_RUBBLE := Color(0.08, 0.07, 0.06, 0.45)
const SCORCH_EPICENTER := Color(0.03, 0.02, 0.02, 0.72)
## Поворот трупа в позе смерти (#21.4). Отрицательный — против часовой стрелки:
## у Godot ось Y смотрит вниз, и «влево» на экране это минус.
const CORPSE_LIE_DEG := -90.0
## Глухая заливка неизвестной клетки (item 46) — темнее пелены разведанного и
## непрозрачная: под ней не должно просвечивать вообще ничего.
const UNKNOWN_COL := Color(0.02, 0.02, 0.03, 1.0)

## «Нигде» — маркер отсутствия клетки (тот же, что и в резолвере).
const NOWHERE := Vector2i(-9999, -9999)

## VEH_MOVE и DRONE_FLY тоже: без них линия хода и кольцо цели под курсором машины и
## дрона догоняли мышь лишь при следующем постороннем событии — «с задержкой».
const HOVER_PREVIEW_MODES := [Mode.MOVE, Mode.ITEM, Mode.SHOOT, Mode.DIG, Mode.MINE, Mode.DISARM,
		Mode.CORPSE_DROP, Mode.WELD, Mode.MOVE_HELD, Mode.VEH_TURN, Mode.VEH_CANNON, Mode.GROUP_LASER,
		Mode.VEH_MOVE, Mode.DRONE_FLY, Mode.BOARD_PICK]

## Цвета «своя/чужая» для перспективной раскраски дуэли (#93). Цвета КОНКРЕТНЫХ
## игроков берутся из ростера (Roster.PALETTE) — их до 26, в словарь на два они
## больше не помещаются.
const OWN_COLOR := Color(0.3, 0.55, 1.0)
const FOE_COLOR := Color(1.0, 0.4, 0.35)
const NEUTRAL_COLOR := Color(0.7, 0.7, 0.7)

## Труп на земле (#59): красный круг, прозрачность 50%.
const CORPSE_COLOR := Color(0.8, 0.1, 0.1, 0.5)
## Обугленное тело (playtest-20): множитель к картинке трупа — темнее и в бурый.
const BURNT_TINT := Color(0.58, 0.42, 0.28)

## Левый верхний угол — постоянное место всех меню действий (#87).
const MENU_ANCHOR := Vector2(16, 48)
## Запас по высоте под шапку окна и нижнее поле при обрезке прокрутки.
const MENU_CHROME_H := 70.0

## ЛДФ — чёрные блоки (#85), в отличие от серых бетонных построек.
const LDF_COLOR := Color(0.05, 0.05, 0.07)

var state: GameState
var resolver: GameActionResolver
var controllers: Dictionary = {}

var mode: int = Mode.NONE
var selected_id: int = -1
var reach: Movement.Reachability = null
var target_ids: Array = []
var item_cells: Array = []
## Соседние вражеские машины, по которым шахтёр может ударить в режиме «Hit» (item 15).
var _melee_veh_ids: Array = []
## Режим установки мин кладёт противотанковую мину, а не противопехотную (item 13).
var _mine_av: bool = false
var build_feature: String = ""
## Рисование ЛДФ-стены (§3.7): цепочка выбранных клеток и флаг «тянем» мышью.
var _wall_cells: Array[Vector2i] = []
var _wall_drawing: bool = false
## Юниты, чья смерть уже применена, но ещё анимируется бросок защиты (#46): рисуем
## их живыми, пока крутится кубик, чтобы не «спойлерить» исход.
var _pending_death_ids: Dictionary = {}
## «Визуальный слепок» зоны взрыва ДО разрушения (item 22): пока крутится кубик выстрела,
## клетки и техника рисуются по этим старым значениям, чтобы исход не опережал бросок.
## {"cells": {Vector2i: {...}}, "vehicles": {vid: {...}}}. Пусто — рисуем как есть.
var _hold_visual: Dictionary = {}
var _held_grid: Grid = null
var _held_grid_key: Array = []
var _held_fog_source: Dictionary = {}
var _held_visible_source: Dictionary = {}

## Видимый на экране диапазон клеток (item 5) — отсечение трупов и косметики за краем.
var _cull_x0: int = 0
var _cull_x1: int = 0
var _cull_y0: int = 0
var _cull_y1: int = 0
## Проигрываемый пеший переход: id юнита → клетка, на которой он сейчас РИСУЕТСЯ (#96).
## Мирные ходят вне потока намерений, и без этого весь их марш применялся одним кадром —
## житель возникал вплотную к отряду. Состояние уже переехало; словарь влияет только на
## отрисовку, поэтому на симуляцию и сетевой лок-степ он не воздействует.
var _walk_cells: Dictionary = {}
## Доля пути до следующей клетки в точках (id -> Vector2): шаг рисуется плавно, а не
## прыжком из клетки в клетку.
var _walk_offset: Dictionary = {}
## Сколько переходов играется прямо сейчас (групповой приказ идёт всеми сразу).
var _walks_running := 0
## Сдвиг рисунка машины на время плавного переезда (id машины -> Vector2, точки).
var _veh_offset: Dictionary = {}
## Сколько точек ОД РИСОВАТЬ у юнита, пока идёт анимация чужого хода (#99): id → число.
## Ход ИИ и слот мирных применяются к состоянию целиком и лишь потом отыгрываются, так
## что без этого жёлтые точки гасли разом до первого кубика и игрок не видел, за что
## именно противник заплатил. На симуляцию словарь не влияет — только на кадр.
var _ap_display: Dictionary = {}
const AP_DOT_DELAY := 0.18
## Сами стеки отката переехали в резолвер (item 28): в сетевой партии они обязаны
## быть ОДИНАКОВЫМИ у всех пиров, а всё, что живёт в боевом экране, у каждого своё.
## Здесь остались только кнопки.
var _undo_btn: Button
var _redo_btn: Button
## Перетаскивание (§3.4): выбранный объект-клетка на первом шаге, -1 = ещё не выбран.
var drag_object: Vector2i = Vector2i(-1, -1)
var move_dest: Vector2i = Vector2i(-1, -1)  # выбранная цель переноса, ждём клетку пленника
## Копка окопа (§3.7): выбранная клетка окопа и первая куча земли; sentinel -1 = не выбрано.
var dig_trench: Vector2i = Vector2i(-1, -1)
var dig_dirt_a: Vector2i = Vector2i(-1, -1)
## Клетка ДПМГ, из которого сейчас целимся (§3.7).
var rsp_active: Vector2i = Vector2i(-1, -1)
## RTS-выделение группы (#18): id выбранных юнитов и состояние рамки выделения ЛКМ.
## Рамка задаётся экранными точками; протяжка > BOX_DRAG_THRESHOLD включает режим рамки.
var _group_ids: Array[int] = []:
	set(v):
		_group_ids = v
		_group_set = {}
		for id in v:
			_group_set[id] = true
## Те же id, что в _group_ids, — множеством (perf pass #5): _draw спрашивает «в группе ли»
## у каждого бойца на экране, а Array.has() линеен по размеру группы. Сеттер выше держит
## их согласованными; на месте _group_ids не правится нигде — только присваивается.
var _group_set: Dictionary = {}
## Групповое движение «тактическое»: каждый встаёт в укрытие у точки приказа.
var _group_tactical: bool = false
## Раскладка под курсором считается заново, только когда сменились точка или доска.
var _group_plan_key: Array = []
var _group_plan_cache: Array = []
## Рамка работает только при нажатой кнопке «Multi-Select» (#21) — иначе ЛКМ
## всегда остаётся обычным кликом по клетке.
var _multi_btn: CheckBox
var _box_dragging: bool = false
var _box_start_cell := Vector2i.ZERO
var _box_additive := false
var _box_start_screen: Vector2 = Vector2.ZERO
var _box_end_screen: Vector2 = Vector2.ZERO
const BOX_DRAG_THRESHOLD := 8.0
## Техника (§техника): выбранная машина и цели её движения (центр → {dir, steps}).
var selected_vehicle_id: int = -1
## Текущий щелчок ЛКМ — двойной (см. _unhandled_input).
var _click_double := false
var veh_move_targets: Dictionary = {}
var veh_disembark_id: int = -1
## Кто садится в выбранное кресло челнока (batch 13): id пехотинца в режиме VEH_BOARD_SEAT,
## и в какую машину (batch 14: выбор кресла открывается и из меню самого бойца).
var veh_board_id: int = -1
var veh_board_vid: int = -1
var _animating: bool = false

## Пауза между действиями ИИ (#52): бойцы должны ходить ОДИН ЗА ДРУГИМ и на глазах,
## а не отрабатывать всю армию за пару кадров.
const AI_STEP_DELAY := 0.12

## Пауза между клетками пешего перехода (#96) — по ней видно, КУДА идёт житель.
const WALK_STEP_DELAY := 0.07

## Item 32: ход нейтралов раньше тянулся так же медленно, как ход игрока. Их слот
## отыгрывается с ускоренным шагом — заметно быстрее базовой скорости. (Когда появится
## меню настроек из item 24, эти значения станут настраиваемыми; пока — быстрые дефолты.)
const NEUTRAL_WALK_STEP_DELAY := 0.028
## Свои и чужие бойцы и дроны (batch soil-rulers): плавно, но быстро — клетка за 40 мс,
## дрон вдвое быстрее прежнего (тридцать клеток подлёта — около секунды).
const SOLDIER_WALK_STEP_DELAY := 0.04
const DRONE_FLY_STEP_DELAY := 0.035
const NEUTRAL_AP_DOT_DELAY := 0.07
## Идёт отыгрыш нейтрального слота — берём ускоренные паузы выше.
var _fast_playback: bool = false

## Предохранитель от зависшего хода ИИ (#60): столько подряд отклонённых намерений
## терпим, прежде чем сдать ход за него принудительно.
const AI_MAX_DENIED := 12
var _ai_denied_streak: int = 0

var p1_is_ai: bool = false
var p2_is_ai: bool = false

## Панорама «камеры» по полю (WASD / средняя-правая мышь / жест тачпада).
var pan: Vector2 = Vector2.ZERO:
	set(value):
		pan = value
		if is_inside_tree():
			_fit_ground()
			_sync_camera_layers()
			if _sky != null:
				_sky.camera = pan
const PAN_SPEED := 700.0
var _mouse_panning: bool = false
## Масштаб «камеры» (колесо мыши / жест щипка). Применяется к рисованию через
## draw_set_transform, поэтому CELL в draw-вызовах остаётся прежним.
var zoom: float = 1.0:
	set(value):
		zoom = value
		if is_inside_tree():
			_fit_ground()
			_sync_camera_layers()
## Нижняя граница — «вся карта разом». При 0.5 клетка в 40 px оставалась 20 px, и
## поле 60×40 (2400 клеток, бой на 200 бойцов) на экран не влезало никак: игрок
## возил камеру вслепую, не видя ни своего фланга, ни чужого. 0.12 даёт клетку под
## 5 px — фигурки уже не разобрать, но общая форма боя видна целиком, а ради неё
## туда и отъезжают.
const ZOOM_MIN := 0.12
const ZOOM_MAX := 2.5
const ZOOM_STEP := 1.1

var _ui_layer: CanvasLayer
## Движимое/масштабируемое окно HUD (заголовок = ручка перетаскивания, угол = грип).
var _hud_window: PanelContainer
var _hud_grip: Control
var _hud_dragging: bool = false
var _hud_resizing: bool = false
var _hud_drag_offset: Vector2 = Vector2.ZERO
var _hud_resize_start: Vector2 = Vector2.ZERO
var _hud_resize_origin: Vector2 = Vector2.ZERO
const HUD_MIN_SIZE := Vector2(230, 170)
## Стартовый размер боковой панели (#54). Панель заметно уже и ниже прежней
## (540×680): она закрывала половину поля, а сеть с неё уехала в главное меню.
const HUD_START_SIZE := Vector2(330, 430)
## Ширина правого меню (item 6): панель приклеена к правому краю, тянется только по
## горизонтали в этих пределах.
var _hud_width: float = 264.0
const HUD_WIDTH_MIN := 180.0
const HUD_WIDTH_MAX := 460.0
## Толщина кисти рисования (пиксели линии) и радиус ластика (в клетках), item 6.
var _draw_brush: int = 3
## Цвет кисти (issues-12 #8). Последний образец — цвет своей стороны; он хранится
## прозрачным и разворачивается в цвет стороны при каждом штрихе. Owner (2026-10-19): the
## faction colour is no longer first or the default — white is.
const DRAW_COLOURS := [Color("#f2f2f2"), Color("#1c1c1c"), Color("#e04545"),
		Color("#f08c28"), Color("#f2d335"), Color("#4cc764"), Color("#3cc8e0"), Color("#4a78f0"),
		Color("#c25be0"), Color(0, 0, 0, 0)]
var _draw_colour: Color = DRAW_COLOURS[0]
var _side_swatch: Button = null
var _draw_panel: PanelContainer
var _erase_brush: int = 1
var _status_label: Label
## Часы боя. Их двое, и считают они разное.
##
## «In-game» — время ВНУТРИ боя: раунд длится ровно шесть секунд, и других источников у
## него нет. Оно не идёт, пока игрок думает над ходом, и не бежит быстрее, когда он
## торопится: шесть секунд за раунд, и ничто другое его не двигает.
##
## «Real» — время, которое бой занял у стола: обычный секундомер с начала партии,
## останавливается вместе с ней.
const IN_GAME_SECONDS_PER_ROUND := 6
var _clock_label: Label = null
## С появления сцены боя, то есть ПОСЛЕ закупки. Раньше его ставил только _open_match, а
## сетевой бой туда не заходит: там стоял 0, и «Real» считал от запуска игры — с лобби,
## закупкой и всеми прошлыми партиями.
var _real_start_ms: int = Time.get_ticks_msec()
var _real_stop_ms: int = -1   # −1 = секундомер ещё идёт
var _clock_shown := ""
var _clock_key := Vector2i(-1, -1)
var _turn_neighbors_label: Label
var _draw_btn: Button
var _erase_btn: Button
## Откат рисунков (playtest-20): автор -> [{ключ холста: запись DrawCanvas}], по записи на
## штрих или ход ластика. Чужие штрихи пишутся так же — их автор шлёт «undo», и все
## снимают у него одно и то же последнее действие.
var _draw_history: Dictionary = {}
const DRAW_UNDO_DEPTH := 50
var _draw_rec_keys: Array = []
var _info_label: Label
## Живой свод армий и место игрока в очереди (item 20). Полный разбор инициативы
## открывается кнопкой в отдельном центральном оверлее (item 49).
var _init_label: RichTextLabel
var _init_overlay: Control
var _init_overlay_body: VBoxContainer
var _init_overlay_scroll: ScrollContainer = null
## Панель узлов выбранной машины (веха «Modular tank system», §9). Показывается ТОЛЬКО
## пока машина выбрана — постоянно висеть на экране этим числам незачем, — стоит над
## журналом боя и, как остальные окна, таскается за шапку.
var _comp_panel: PanelContainer = null
var _comp_body: VBoxContainer = null
var _comp_moved := false

## Бой машина-против-машины идёт сам и остановить его было нечем (item 4). Пока за
## столом есть человек, пауза не нужна: ход всё равно ждёт его действия. А когда обе
## стороны ведёт ИИ, партия отыгрывается сама собой, и посмотреть на позицию — или
## просто отойти — можно было только закрыв игру.
##
## Пауза держит ровно одно: следующий шаг ИИ. Состояние она не трогает, поэтому
## встать на паузу безопасно в любой момент, в том числе посреди чужого хода —
## доигранное останется доигранным.
var _paused: bool = false
var _pause_btn: Button = null
## Партия окончена (batch 13 #9): осталась одна команда с живыми бойцами (или ни одной).
## С этого момента доска замирает — ни ИИ, ни кнопки, ни сетевые намерения её не двигают;
## остаётся смотреть на поле, сохранить и уйти в меню.
var _match_over: bool = false
var _victory_overlay: Control = null
## «Было / стало» (0.9.2): кнопка в правом меню подменяет доску тем, какой она была в
## самом начале боя, — рельеф, объекты, бойцы и машины на стартовых местах, — а второе
## нажатие (или щелчок по полю) возвращает настоящую. Снимок — копия клеток на черновой
## сетке (её плитки рисуются слоем ПОВЕРХ доски) и список стартовых мест. Только показ:
## на состояние, сеть и повтор не влияет.
var _opening_state: Dictionary = {}
var _before_grid: Grid = null
var _before_tiles: TerrainTiles = null
var _before_units: Array = []      # [stats_id, owner, coord, UnitInstance of the opening board]
var _before_vehicles: Array = []   # [type_id, owner, origin, size, facing]
## Что каждая сторона видела в начале боя (0.11.3): под туманом «было» показывает чужих
## только там, где их видели, — иначе стартовая доска выдавала расстановку противника.
var _before_seen: Dictionary = {}  # side -> {Vector2i: true}
var _before_on := false
var _before_layer: BeforeLayer = null
var _before_btn: Button = null
var _before_note: Label = null

class BeforeLayer extends Node2D:
	var host: Node = null
	func _draw() -> void:
		if host != null:
			host._draw_before(self)

## Какой слот отыгрывается ПРЯМО СЕЙЧАС, когда это не active_player (item 6).
##
## Нейтральные слоты резолвер проводит все разом внутри ОДНОЙ передачи хода, поэтому
## снаружи active_player() уже показывает следующего игрока, и группа жителей никогда
## не оказывалась «активной» в тот момент, когда её ход видно на экране. Резолвер
## помечает начало каждого такого слота событием {"kind": "slot"}, и на время его
## проигрывания подсветка списка инициативы берётся отсюда. −1 = никто.
var _playing_slot: int = -1

## Зелёный «сейчас ходит» в списке инициативы (item 5). Свой цвет, а не общий акцент
## интерфейса: акцент приглушённо-оливковый и рядом с цветными метками сторон за
## «зелёный» не читается, а метка хода обязана быть заметна с одного взгляда.
const TURN_ACTIVE_COLOR := Color(0.35, 0.92, 0.42)

## Прозрачность окна чата (issue 5: «make the chat window half-transparent»). Половина —
## буквально: 0.5 по альфе фона рамки и её шапки, текст внутри остаётся непрозрачным.
const PANEL_GLASS_ALPHA := 0.5

## Чат, докнутый в правый-нижний угол (item 50): тело сворачивается кнопкой заголовка.
var _chat_panel: PanelContainer
var _chat_body: VBoxContainer
## Обёртка-отступ вокруг тела чата — сворачивается целиком (item 15).
var _chat_body_wrap: Control
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _log_label: RichTextLabel
## Журнал боя вынесен из правого меню в свою панель (item 6), внизу слева.
var _log_panel: PanelContainer
## Тело журнала и его стрелка-переключатель (issue 6): журнал сворачивается, как чат.
var _log_body_wrap: Control
var _log_toggle_btn: Button
## Кнопка-стрелка сворачивания чата (item 11) и флаги «панель передвинута вручную»
## (item 8): пока не тронута — держим её в углу автоматически, после перетаскивания — нет.
var _chat_toggle_btn: Button
var _chat_moved: bool = false
var _log_moved: bool = false
## Состояние перетаскивания панелей (item 8).
var _menu: PanelContainer
var _picker: PanelContainer
## Клетка под наведённой кнопкой выбора («Station at (45, 32)» и подобные). Пока мышь на
## кнопке, на доске горит ИМЕННО этот объект: список голых координат глазами не читается,
## а объект на поле — читается сразу. (-1,-1) — ни на что не наведено.
var _hover_cell := Vector2i(-1, -1)
var _dice: DiceRoller
## Кастомное модальное окно «выйти в меню» в общем стиле интерфейса (#51), а не
## системный ConfirmationDialog. Полноэкранный затемнитель + рамка SteamChrome.
var _quit_dialog: Control
## Клетки с телом, которое можно взять в руки прямо сейчас (#7). Подмножество
## item_cells: обе подсвечиваются одинаково, но клик по ним делает разное.
var _corpse_cells: Array = []
## Косметика боя (#21). Правил не касается: слой читает описания из ActionResult.fx
## и рисует их поверх доски. Пустой слой не стоит ничего — все проходы по нему
## начинаются с проверки на пустоту.
var _fx := FxDecals.new()
var _audio: BattleAudio
var _audio_victory_played := false
var _annotations: Node2D
var _net_request_pending := false
var _net_messages: Array[Dictionary] = []
var _p1_btn: Button
var _p2_btn: Button
# --- Запись, сохранение и повтор матча (M12, items 42 и 53) ---
## Регистратор пишет партию по ходу дела; повтор, наоборот, её проигрывает. Оба сразу
## не бывают: смотреть запись и одновременно писать новую нечего.
var recorder: ReplayRecorder = null
var replay: ReplayPlayer = null
var _loaded_from_save: bool = false
var _replay_playing: bool = false
var _replay_speed: float = 1.0
var _replay_bar: PanelContainer = null
var _replay_label: Label = null
var _replay_play_btn: Button = null
var _replay_speed_btn: Button = null
## Таймлайн перемотки записи (item 7) и флаг «обновляем программно, не сейкаем».
var _replay_slider: HSlider = null
var _replay_slider_syncing: bool = false
var _replay_bookmarks: ItemList
var _replay_dragging := false
var _replay_seek_timer: Timer
var _replay_seek_target := 0
var _replay_skip_animations := false
var _save_btn: Button = null
## Пауза между действиями при автопроигрывании — делится на выбранную скорость.
const REPLAY_STEP_DELAY := 0.5
const REPLAY_SPEEDS := [1.0, 2.0, 4.0, 8.0]

var _spectator := false
var _spectator_side := 0
var _spectator_fog := false
## After the match (playtest 2026-10-19): "Look at the Board" may lift all fog of war.
var _reveal_board := false
var _reveal_btn: CheckBox
var _spectator_view: GameActionResolver = null
var networked: bool = false
var my_owner: int = MCF.Owner.PLAYER_1
var session: NetworkSession = null
var net: NetGame = null
## Ручные броски в сети (batch 12 #14). Каждый бросок, которого ждут нажатия, получает
## порядковый номер — одинаковый на всех машинах, потому что действия и их кубики идут
## у всех в одном порядке. Чужое нажатие может прийти раньше, чем мы дойдём до этого
## броска (у соперника анимация впереди) — тогда оно лежит в _roll_inbox.
var _roll_seq: int = 0
var _roll_inbox: Dictionary = {}
signal _roll_arrived(seq: int)
## Пришедшие по сети действия ждут своей очереди на показ (batch 12 #15): второе не
## должно крутить кубики поверх первого.
var _net_queue: Array = []
var _net_playing: bool = false
## Строка сетевого состояния — видна ТОЛЬКО в сетевой партии (#54); сами кнопки
## Host/Join уехали во вкладку Multiplayer главного меню.
var _net_status: Label

# --- Панорама камеры по WASD ---
var _group_zone_layer: Node2D
var _group_zone_draw_key: Array = []
var _group_mouse_cell := Vector2i(-1, -1)
var _group_preview: GroupMovePreview
var _group_order_pending := Vector2i(-1, -1)
var _group_order_signature: Array = []

var _lighting: LightManager

## Время суток без динамического света (0.12.1): ровный оттенок поля CanvasModulate'ом —
## интерфейс на своих CanvasLayer его не получает.
var _time_mod: CanvasModulate = null

## Выбор машины для посадки щелчком (batch borg-corpses): подсвечиваются корпуса всех
## подходящих машин, щелчок по любой клетке корпуса — посадка в неё (группой — всех).
var _board_pick: Array = []
var _board_pick_group := false

## Зоны хода выделенного отряда (batch group-zones): у каждой клетки — лучшая зона, в
## которую до неё дойдёт хоть кто-то из группы (1/2/3 ОД), и подпись «цена/потолок» того,
## кому это дешевле всех. Считается раз на состояние доски и состав группы.
var _gz_key: Array = []
var _gz: Dictionary = {}

## Pull a body out of a vehicle (owner, 2026-10-19): pick the cell it goes to, or click
## the puller to have it carry the body. Same highlight as dropping a carried body.
var _pull_vehicle_id := -1

## Гость вышел из боя (batch 13 #2): его сторону берёт ИИ высокой сложности — на хосте
## настоящий AIController, у остальных гостей та же сторона остаётся удалённой (её ходы
## по-прежнему приходят от хоста), только ростер узнаёт, что за ней машина.
## One automatic desync report per match (DesyncReport), unless switched off in Settings:
## what was sent, or empty.
var _desync_report: Dictionary = {}

const DEFENSE_PROMPT := "You are under attack — click Roll to defend"
const RESIST_PROMPT := "You are grabbed — click Roll to resist"

## Пауза, чтобы осыпавшееся стекло было видно до бросков по цели за ним (секунды).
const GLASS_BREAK_PAUSE := 0.35

## Дождаться всех идущих переходов — но не дольше, чем они могут длиться. Переход ведёт
## счётчик _walks_running; если он почему-то не вернулся к нулю (корутина оборвалась),
## ожидание не должно вешать весь показ хода — а в сетевой партии и ход у обоих пиров.
const WALK_WAIT_LIMIT_MS := 6000

## Проиграть один пеший переход по клеткам (#96). Юнит УЖЕ стоит в конце маршрута —
## отматываем его отрисовку к старту и ведём по пути, чтобы игрок увидел, откуда и
## куда пришёл житель, а не обнаружил его вплотную к своему отряду.
var _inspected_station := Vector2i(-1, -1)
var _walk_jobs: Dictionary = {}
var _walk_serial := 0

## Гарантированный бросок (нужно 1+) крутится вдвое быстрее — незачем тянуть (#46).
const FAST_ROLL_SPEED := 2.0

## Предпросмотр движения (#103): зелёный разлив достижимых клеток, на каждой — во сколько
## очков она обойдётся из общего запаса, а под курсором — САМ МАРШРУТ, которым боец туда
## пойдёт.
##
## Маршрут не выдумывается заново: Movement.Reachability.came_from — это дерево кратчайших
## путей того самого Дейкстры, по которому резолвер и поведёт бойца. Поэтому нарисованная
## линия — не «примерно так», а ровно тот путь, что будет пройден, и подписанная цена ровно
## та, что спишется. Дешевле всего он и есть: Дейкстра других в дерево не кладёт.
##
## Подписи — не украшение, а то, ради чего дробление хода (§3.2) вообще имеет смысл: игрок
## должен видеть, сколько шагов останется в кредите, ЕЩЁ ДО клика. Поэтому формат «4/6»,
## а не голое число: слева цена клетки, справа весь запас.
##
## На сильном отъезде (см. ZOOM_MIN) подписи не рисуются вовсе: при клетке в 5 пикселей
## цифру всё равно не прочесть, а draw_string на каждую из сотен клеток — это заметная
## доля кадра.
const MOVE_LABEL_MIN_ZOOM := 0.45

## Цвета зон хода: [заливка, подсвеченный маршрут, контур, линия пути] за 1/2/3 ОД.
const MOVE_TIER_COLS := [
	[Color(0.3, 0.8, 0.4, 0.28), Color(0.45, 1.0, 0.55, 0.42), Color(0.55, 1.0, 0.65, 0.95), Color(0.6, 1.0, 0.7, 0.95)],
	[Color(1.0, 0.5, 0.0, 0.40), Color(1.0, 0.65, 0.2, 0.55), Color(1.0, 0.7, 0.25, 0.95), Color(1.0, 0.78, 0.4, 0.95)],
	[Color(1.0, 0.1, 0.05, 0.36), Color(1.0, 0.3, 0.2, 0.52), Color(1.0, 0.35, 0.3, 0.95), Color(1.0, 0.5, 0.45, 0.95)],
]

## Подвести камеру к клетке, если она вне экрана (#103). Масштаб не трогаем: игрок сам
## выбрал, насколько близко смотрит, и менять это за него — потерять его точку обзора.
## Длительность плавной доводки камеры к активному юниту (item 52). Зум не трогаем
## (§18.4) — двигаем только панораму.
const ENSURE_VISIBLE_TWEEN := 0.22
var _pan_tween: Tween = null

# --- Рендер ---
## Чьими глазами смотрит этот экран. В сетевой партии — ВСЕГДА своя сторона: чужой
## ход не должен ничего показывать сверх того, что видит игрок. В хот-сите за одним
## экраном перспектива одна на всех и принадлежит тому, чей сейчас ход.
## Чей туман рисуется на ЭТОМ экране (item 46). В сетевой партии — всегда свой, и
## только свой: раньше доска бралась по state.active_player(), поэтому на ходу
## соперника клиент честно перерисовывал ЕГО обзор и показывал игроку всё, что видит
## противник. Ровно это и есть утечка чужого поля зрения из задания.
##
## В горячем кресле (два человека за одним экраном, ИИ) активный игрок и зритель —
## одно и то же лицо, и поведение не меняется.
##
## Против ИИ «активный игрок» во время хода ИИ — сам ИИ, и экран показывал игроку его
## обзор: все вражеские бойцы как на ладони. Поэтому смотрит последний человек, сидевший
## за этим столом, а до первого его хода (ИИ ходит первым) — первый человек в ростере.
## Людей нет вовсе (ИИ против ИИ) — зритель следит за тем, чей ход: тумана там и так нет.
var _last_viewer := -1

# --- Дальний план большой карты ---
## На сильном отъезде клетка — несколько пикселей, и поклеточная отрисовка тратила кадр
## на то, чего не разглядеть: на поле 250×250 при ZOOM_MIN это ~37 000 клеток и ~150 мс на
## КАЖДЫЙ кадр — наведение мыши, панорама, анимация. Ниже LOD_ZOOM доска — три текстуры по
## пикселю на клетку: рельеф, туман и объекты. Их слой стоит ПОД узлом боя
## (show_behind_parent) и едет его же панорамой через свой transform, так что pan и zoom
## его не перерисовывают вовсе. Правятся текстуры попиксельно: рельеф и объекты — по журналу
## вида клеток (GridCell.look_changes), туман — по журналу видимости резолвера
## (take_vis_changes). Бойцы, техника, трупы, мины, подсветки и эффекты рисуются поверх, как
## и раньше; сетки и подписей высоты на таком отъезде нет — их всё равно не разглядеть.
## Плитки видны при любом зуме (gore batch): отъезд больше не сводит доску к пятнам
## цвета — TerrainTiles держит для него куски по 8 точек на клетку. Дальний план остался
## лишь как запасной путь (LOD_ZOOM = 0 его не включает).
const LOD_ZOOM := 0.0
## Ниже этого зума подписи высоты насыпей не рисуются — шрифт всё равно не прочесть.
const HEIGHT_LABEL_ZOOM := 0.6
## Обычный туман (issues-12 #16) — серая пелена поверх ВСЕГО, что сейчас не видно: карта
## под ней видна целиком, со стенами и мебелью, но такой, какой зритель её помнит
## (_board_memory), а бойцы и машины вне обзора не рисуются. Реалистичный — чёрная
## пелена: вне обзора не видно ничего, ни стен, ни мебели.
const FOG_COL := Color(0.12, 0.12, 0.14, 0.62)

## Порядок слоёв: рельеф, сетка, объекты и ПОВЕРХ всего — туман (issues-12 #16). Прежде
## туман лежал между полом и объектами, и стены с мебелью светили сквозь пелену.
##
## Вблизи (far = false) тот же слой выводит рельеф кусками-плитками TerrainTiles и туман
## поверх них: пиксельным плиткам нужна фильтрация NEAREST, а она у узла одна на всё, что
## он рисует, — бойцов главного узла она огрубила бы.
class LodLayer extends Node2D:
	var terrain: ImageTexture = null
	var fog: ImageTexture = null
	var features: ImageTexture = null
	var rect := Rect2()
	var fog_on := false
	var far := true
	var tiles: TerrainTiles = null
	var near_cells := Rect2i()   # видимые клетки ближнего плана
	var grid_col := Color(0, 0, 0, 0)   # сетка клеток; прозрачная — не рисуется
	func _draw() -> void:
		if not far:
			if tiles == null:
				return
			var r := near_cells
			var res := TerrainTiles.prepare(self, float(CELL))
			texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			tiles.draw(self, rect.position, float(CELL), r.position.x, r.position.y, r.end.x, r.end.y,
					false, res)
			# Сетка — под объектами: стену, стол или кровать в несколько клеток она не режет.
			TerrainTiles.draw_grid(self, rect.position, float(CELL), r.position.x, r.position.y,
					r.end.x, r.end.y, grid_col, 1.0)
			tiles.draw(self, rect.position, float(CELL), r.position.x, r.position.y, r.end.x, r.end.y,
					true, res)
			if fog_on and fog != null:
				draw_texture_rect(fog, rect, false)
			return
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		if terrain != null:
			draw_texture_rect(terrain, rect, false)
		if tiles != null:
			tiles.draw_map_decals(self, rect.position, float(CELL), Rect2(Vector2.ZERO, rect.size / CELL))
		if features != null:
			draw_texture_rect(features, rect, false)
		if fog_on and fog != null:
			draw_texture_rect(fog, rect, false)

var _lod: LodLayer = null
var _lod_terrain: Image = null
var _lod_features: Image = null
var _lod_fog: Image = null
var _lod_terrain_key: Array = []   # доска, на которой собран рельеф
var _lod_damage_ver: int = -1      # _fx.damage_version, по которому покрашена копоть
var _lod_damaged: Dictionary = {}  # клетки, покрашенные побитыми
var _lod_fog_key: Array = []       # доска, резолвер, зритель и режим тумана
var _lod_look_ver: int = -1        # до какой GridCell.look_version доведён рельеф
var _lod_terrain_stale := false    # картинка правилась, текстура ещё не выгружена
var _lod_fog_stale := false
var _lod_tex_avg: Dictionary = {}  # имя картинки-замены -> её средний цвет
var _tiles: TerrainTiles = null     # ближний план рельефа кусками-плитками
var _tiles_grid: Array = []      # [доска, туман]: под туманом укрепления не запекаются
## Вид мебели, снятый с доски в начале партии (TerrainTiles.furniture_look): в бою мебель
## заново не срастается. Живёт здесь, а не в плитках, — их пересоздаёт смена доски и тумана.
var _furniture_look: Dictionary = {}
var _furniture_look_of: Array = []   # [board, GridCell.look_version] it was frozen from

## Доска «как её помнит зритель» (issues-12 #4). Под туманом рельеф и объекты рисуются
## не с живой доски, а с её копии, где клетка обновляется, только пока зритель её видит:
## стена, построенная или снесённая в темноте, не появляется и не пропадает, пока туда
## не заглянешь. Копия — своя у каждого зрителя (в хот-сите их несколько); людям она
## снимается сразу, чтобы первый ход одного не утёк другому.
var _fog_mem: Dictionary = {}       # viewer -> Grid
var _fog_mem_grid: Grid = null      # живая доска, с которой сняты копии
var _fog_mem_viewer: int = -999     # чья копия обновлялась последней
var _fog_mem_look: int = -1         # до какой GridCell.look_version копия доведена
var _tile_hold_cells: Dictionary = {}
var _shown_grid: Grid = null        # что рисуется в этом кадре: живая доска или копия
## Щебень и воронки (FxDecals.floor_damage) — тоже вид доски: зритель помнит их такими,
## какими видел. viewer -> {клетка: урон}; версия растёт на каждую правку любой из них.
var _fog_mem_dmg: Dictionary = {}
var _fog_mem_dmg_seen: int = -1     # до какой _fx.damage_version доведена память
var _fog_mem_dmg_ver: int = 0
## Косметика и тела — тоже как их видел зритель (0.11.3): гильза, осколки, лазерный след,
## кровь и труп, появившиеся в темноте, не видны, пока туда не посмотрят.
var _fog_mem_fx: Dictionary = {}       # viewer -> DecalMemory
var _fog_mem_corpses: Dictionary = {}  # viewer -> {клетка: [павший или null, сколько тел]}
## The visible set the memories were last brought up to date with, and whose it is. When
## the view jumps (a walk starts or ends, a pre-impact hold opens or closes) the memories
## re-check only the cells that differ, not the whole view (issues-fix-6 #4: ~90 ms each).
var _mem_visible: Dictionary = {}
var _mem_visible_key: Array = []
## The cells _mem_visible leaves out, when the resolver knows them as a short list (fog off
## with clouds: the board minus clouds and shadows); null when it does not.
var _mem_hidden: Variant = null
var _mem_view: GameActionResolver = null

const LOD_FLOOR := Color(0.14, 0.15, 0.18)
const LOD_WALL := Color(0.35, 0.3, 0.25)
## Космос на дальнем плане (0.9.3) — ПРОЗРАЧНЫЙ: клетки космоса не рисуются вовсе, и
## сквозь них виден параллакс звёзд за доской, как и вблизи.
const LOD_SPACE := Color(0, 0, 0, 0)

## Осевшая косметика на ДАЛЬНЕМ плане (0.9.3). Вблизи кровь и гильзы запечены в плитки
## куска (TerrainTiles._bake_decals), а здесь клетка — один пиксель, и запекать нечего:
## цвет частицы просто подмешивается в пиксель её клетки. Так на отъезде по-прежнему
## видно, где шёл бой, — а это главное, зачем кровь на карте и нужна.
##
## Новое подмешивается по мере появления: списки косметики только растут, пока что-то не
## УБЫЛО (пожар, потолок, загрузка) — а это и есть FxDecals.decal_reset, по которому
## дальний план собирается заново.
var _lod_decal_reset := -1
var _lod_decal_done := 0
## Картинка рельефа, в которую подмешана косметика: пересобранная картинка — без неё.
var _lod_decal_img := 0
## Щебень дальнего плана: живой (без тумана) или память зрителя (_lod_sync).
var _lod_damage_src: Dictionary = {}

## Клетки с кучами тел (cell.corpse_count > 0). Кучи рисуются отдельным проходом, и
## искать их перебором экрана на отъезде — это десятки тысяч клеток за кадр.
var _piles: Array[Vector2i] = []
var _piles_key: Array = []

## Летящие частицы (0.12.2, владелец: «make them always pixelated»): той же картинкой, что
## потом впечётся в пол (TerrainTiles._decal_sprite), в том же разрешении плиток и по той же
## пиксельной сетке — у полёта и у осевшего один вид. Рисует их дочерний слой с фильтрацией
## NEAREST (у узла она одна на всё, а бойцов главного узла огрублять нельзя). На дальнем
## плане плиток нет — тогда по-старому, векторно.
class FlyLayer extends Node2D:
	var items: Array = []   # [текстура, прямоугольник]
	func _draw() -> void:
		for it: Array in items:
			draw_texture_rect(it[0], it[1], false)

var _fly: FlyLayer = null
var _fly_tex: Dictionary = {}   # картинка частицы (Image) -> ImageTexture; на одни плитки
var _fly_tiles: TerrainTiles = null

## СЛУЧАЙНЫЕ СОБЫТИЯ НА КАРТЕ (0.9.4). Объявленное событие игрок обязан ВИДЕТЬ — в этом
## весь смысл предупреждения за раунд: заштрихованная зона с подписью, сколько раундов до
## удара, и подсвеченный участок края там, откуда придёт независимая армия. Стоящий газ
## рисуется своей зелёной пеленой с остатком раундов.
##
## Туман войны тут не при чём: предупреждение объявлено ВСЕМ (его слышат по радио). Сам
## газ под туманом виден лишь там, куда смотрят (0.11.3, _draw_gas_tiles).
const EVENT_COLORS := {
	"mortar": Color(0.95, 0.45, 0.15, 1.0),
	"gas": Color(0.78, 0.92, 0.36, 1.0),   # GAS_TINT, a touch lighter: the warning matches the cloud
	"army": Color(0.85, 0.35, 0.75, 1.0),
	"fire": Color(1.0, 0.3, 0.12, 1.0),
	"emp": Color(0.35, 0.85, 1.0, 1.0),
	"collapse": Color(0.78, 0.66, 0.5, 1.0),
	"reinforce": Color(0.45, 0.9, 0.45, 1.0),
}
## Пыльная буря (0.12): песчаная дымка поверх поля, пока держится.
const DUST_TINT := Color(0.8, 0.64, 0.4, 0.16)
const BOUNTY_COLOR := Color(1.0, 0.82, 0.25)

# --- Режим партии (0.12) ---------------------------------------------------------------
var _objective_group: SteamChrome.GroupBox = null
var _objective_key := ""
const ZONE_IDLE := Color(0.86, 0.88, 0.92)

## Connected gas tiles fade only at exposed edges, with a lighter pass over units.
## Cull to the viewport and draw overlapping clouds only once per cell.
var _gas_canvas_texture: CanvasTexture

## Тон дыма (0.12): тот же облачный рисунок, что у газа, но тёмно-серый — ядовитое облако
## и безвредная завеса не путаются с первого взгляда.
const SMOKE_TINT := Color(0.42, 0.44, 0.48)

## Струя огнемёта (0.12.1, владелец: «not instant»). Пламя бежит от сопла по клеткам
## струи, FLAME_STEP секунд на клетку; огонь на полу и сожжённые появляются, когда фронт
## до них добегает, потом струя гаснет за FLAME_TAIL. Это только показ: доска уже решена.
const FLAME_STEP := 0.045
const FLAME_TAIL := 0.12
var _jet: Dictionary = {}

## Вид частиц переехал в FxDecals.LOOK / TEXTURE (0.9.3): по той же таблице осевшую
## косметику запекает в доску TerrainTiles, и двум копиям разойтись теперь негде.
const FX_TEXTURE := FxDecals.TEXTURE

## Тот же объект на соседней клетке (для автотайла, batch 17, item 12).
## Суффикс картинок стороны — её фракция (batch 17, item 13): «_nova», «_neutral»…
## Ниже этого зума обводка кружка, буквы рода и точки ОД не читаются (клетка — 10 точек):
## их не рисуем, остаётся цветной кружок и все метки состояния.
const UNIT_DETAIL_ZOOM := 0.3

## Метка юнита в кружке — заранее «вылепленная» строка (TextLine) на род: draw_string
## заново раскладывает текст на каждом вызове, а меток на поле сотни (batch mp-perf).
var _tag_lines: Dictionary = {}

## Имя картинки бойца — по (род, владелец), раз на пару, а не строками на каждого бойца
## каждый кадр (batch mp-perf: сотни юнитов на поле).
var _skey_cache: Dictionary = {}

# --- Небо за доской (0.9.3) ---
## Клетки космоса больше не рисуются плиткой — их попросту нет, — и в прорехах доски
## видно параллакс звёзд, тот же, что в главном меню. Слои живут на СВОЁМ CanvasLayer под
## всем остальным: доска рисуется в _draw() этого узла, и подложить что-то под неё иначе
## нельзя. Панораму доски слои забирают долями (Starfield.DEPTH) — отсюда глубина.
##
## Карте без космоса небо не нужно. За краем города и поля рисуется земля;
## если на самой карте есть космос, звёзды остаются видны в этих клетках.
var _sky: Starfield = null

# --- Земля за краем доски (item 7) ---
## За каймой карты (10 клеток грунта или травы) экран кончался чернотой, и доска читалась
## как вырезанный из мира прямоугольник. Теперь та же земля продолжается до краёв экрана —
## обоями из вариантов плитки пола. У города и поля обои целиком травяные, без серых
## проплешин. Это чистый фон под доской: ни клеток, ни правил, ходить там негде.
##
## Город и поле получают траву, бункер — грунт, даже при наличии клеток космоса.
## На станции за бортом остаются звёзды (_build_sky). Фон не рисуется внутри доски.
const GROUND_TILES := 16        # сторона клочка обоев в клетках
const GROUND_PATCH_CHANCE := 0.07

var _ground: GroundBackdrop = null

const _EMPTY_COUNT := {"alive": 0, "dead": 0, "veh": 0, "veh_dead": 0}

var _neutral_camera_row: HBoxContainer
var _neutral_camera_buttons: GridContainer
var _neutral_camera_sides: Array = []

var _force_rows: Dictionary = {}   # "raiders"/"waves" -> [row, button grid, shown keys]

var _walking_view: GameActionResolver

## Heightmap mode (0.11.1): the height of every cover tile written on it as a number.
## Under fog only what the viewer sees now is labelled — no hint of a hidden sandbag.
const HEIGHTMAP_MIN_ZOOM := 0.35
var _heightmap := false
var _height_btn: CheckBox = null

# Shortcuts activate the actual offered buttons; there is no second availability list.
var _menu_actions: Dictionary = {}
var _undo_draw_shortcut_btn: Button
var _number_choices: Array[Button] = []
var _number_page := 0

# --- Declared here, defined in a file further up the chain ------------------------
## So the files below them can call them (GDScript resolves calls at parse time).
@abstract func _kick_if_ai() -> void
@abstract func _save_game() -> void
@abstract func _replay_step() -> void
@abstract func _replay_seek(target: int) -> void
@abstract func _replay_toggle() -> void
@abstract func _side_is_ai(side: int) -> bool
@abstract func _make_side(side: int) -> void
@abstract func _is_own_active(u: UnitInstance) -> bool
@abstract func _on_board(u: UnitInstance) -> bool
@abstract func _can_control(unit_owner: int) -> bool
@abstract func _select(unit: UnitInstance) -> void
@abstract func _deselect() -> void
@abstract func _back_to_menu() -> void
@abstract func _escape_pressed() -> void
@abstract func _selected_unit() -> UnitInstance
@abstract func _selected_vehicle() -> Vehicle
@abstract func _is_marksman(u: UnitInstance) -> bool
@abstract func _unit_at(coord: Vector2i) -> UnitInstance
@abstract func _group_marksmen() -> Array
@abstract func _volley_dir(coord: Vector2i) -> Vector2i
@abstract func _veh_cells(v: Vehicle) -> Array
@abstract func _board_pick_at(coord: Vector2i) -> Vehicle
@abstract func _wall_valid_next(coord: Vector2i) -> bool
@abstract func _submit(intent: Intent) -> void
@abstract func _on_intent_ready(intent: Intent) -> void
@abstract func _queue_ai_step(ctrl: PlayerController) -> void
@abstract func _toggle_pause() -> void
@abstract func _check_match_over() -> bool
@abstract func _declare_match_over(title: String) -> void
@abstract func _before_known(owner: int, cells: Array, viewer: int) -> bool
@abstract func _toggle_before() -> void
@abstract func _after_action() -> void
@abstract func _fit_ground() -> void
@abstract func _build_replay_bar() -> void
@abstract func _toggle_initiative_overlay() -> void
@abstract func _to_lobby() -> void
@abstract func _refresh_initiative_overlay() -> void
@abstract func _draw_ruler() -> void
@abstract func _make_panel_draggable(panel: Control, header: Control, on_move: Callable) -> void
@abstract func _replay_chat_history() -> void
@abstract func _draw_black_cross(origin: Vector2, size: float, alpha: float = 0.95) -> void
@abstract func _neutral_camera_targets() -> Dictionary
@abstract func _scroll_menu(panel: PanelContainer, title: String = "Actions", back := Callable()) -> VBoxContainer
@abstract func _anchor_menu(panel: Control) -> void
@abstract func _has_action_button(vb: VBoxContainer) -> bool
@abstract func _to_menu() -> void
@abstract func _on_end_turn_pressed() -> void
@abstract func _on_undo_pressed() -> void
@abstract func _on_redo_pressed() -> void
@abstract func _resync_after_restore() -> void
@abstract func _my_turn() -> bool
@abstract func _refresh_undo_btn() -> void
@abstract func _side_label(side: int) -> String
@abstract func _refresh_status() -> void
@abstract func _refresh_info() -> void
@abstract func _hint_cell(b: Button, c: Vector2i) -> void
@abstract func _clear_hint_cell() -> void
@abstract func _on_log_line(text: String) -> void
@abstract func _play_victory_audio() -> void
@abstract func _build_spectator_controls(parent: Container) -> void
@abstract func _draw_heights(font: Font, visible: Dictionary, fog_on: bool, x0: int, y0: int, x1: int, y1: int) -> void
@abstract func _sync_camera_layers() -> void
@abstract func _register_menu_action(button: Button, id: String) -> void
@abstract func _number_picker() -> void
