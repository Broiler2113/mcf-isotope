extends Node2D

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
	MCF.FEATURE_BRU: "BRU",
	MCF.FEATURE_CORPSE_WALL: "††", MCF.FEATURE_AIRLOCK: "AL",
	MCF.FEATURE_DIRT_PILE: "drt", MCF.FEATURE_RSP: "MG",
	MCF.FEATURE_DOT: "PBX", MCF.FEATURE_WOOD_WALL: "WD",
	MCF.FEATURE_SANDBAG_WALL: "SB", MCF.FEATURE_HEDGEHOG_SANDBAGS: "hSB",
	MCF.FEATURE_DOT_OPEN: "PBX+",
}

## Хелпер оформления окон в стиле «2003 Steam» (preload, без class_name).
const SteamChrome = preload("res://src/ui/SteamChrome.gd")

## GRAB — единая «рука» (#50): и захват бойца, и волочение трупа/мешков/ежа/кучи земли.
## Отдельного режима DRAG больше нет — кнопка одна, цели показываются вместе.
enum Mode {NONE, MENU, MOVE, SHOOT, GRAB, ITEM, PUSH, DRONE_FLY, BUILD, BUILD_WALL, BREAK, RSP_FIRE, DIG, CARRY_DROP,
	CORPSE_DROP, WELD, MOVE_HELD,
	GROUP_MENU, GROUP_MOVE,
	VEH_MENU, VEH_MOVE, VEH_TURN, VEH_CANNON, VEH_DISEMBARK}

## Режимы, чей предпросмотр читает клетку под курсором. Каждому движению мыши нужен
## свой кадр (#97), иначе картинка обновляется только когда камера что-то дёрнет —
## именно так пропадал круг взрыва у пушки, пока режим не был в этом списке.
const HOVER_PREVIEW_MODES := [Mode.MOVE, Mode.ITEM, Mode.SHOOT, Mode.DIG, Mode.CORPSE_DROP,
		Mode.WELD, Mode.MOVE_HELD, Mode.VEH_TURN, Mode.VEH_CANNON]

const OWNER_COLORS := {
	MCF.Owner.PLAYER_1: Color(0.3, 0.55, 1.0),
	MCF.Owner.PLAYER_2: Color(1.0, 0.4, 0.35),
	MCF.Owner.NEUTRAL: Color(0.7, 0.7, 0.7),
}

## Труп на земле (#59): красный круг, прозрачность 50%.
const CORPSE_COLOR := Color(0.8, 0.1, 0.1, 0.5)

## Левый верхний угол — постоянное место всех меню действий (#87).
const MENU_ANCHOR := Vector2(16, 16)
## Запас по высоте под шапку окна и нижнее поле при обрезке прокрутки.
const MENU_CHROME_H := 70.0

## БРУ — чёрные блоки (#85), в отличие от серых бетонных построек.
const BRU_COLOR := Color(0.05, 0.05, 0.07)

var state: GameState
var resolver: GameActionResolver
var controllers: Dictionary = {}

var mode: int = Mode.NONE
var selected_id: int = -1
var reach: Movement.Reachability = null
## Запас движения, на который посчитан `reach` (#103). Нужен подсказке «3/6»: сама
## Reachability знает лишь потраченное, а игроку важно, сколько от ЗАПАСА останется.
var reach_budget: int = 0
var target_ids: Array = []
var item_cells: Array = []
var build_feature: String = ""
## Рисование БРУ-стены (§3.7): цепочка выбранных клеток и флаг «тянем» мышью.
var _wall_cells: Array[Vector2i] = []
var _wall_drawing: bool = false
## Юниты, чья смерть уже применена, но ещё анимируется бросок защиты (#46): рисуем
## их живыми, пока крутится кубик, чтобы не «спойлерить» исход.
var _pending_death_ids: Dictionary = {}
## Проигрываемый пеший переход: id юнита → клетка, на которой он сейчас РИСУЕТСЯ (#96).
## Мирные ходят вне потока намерений, и без этого весь их марш применялся одним кадром —
## житель возникал вплотную к отряду. Состояние уже переехало; словарь влияет только на
## отрисовку, поэтому на симуляцию и сетевой лок-степ он не воздействует.
var _walk_cells: Dictionary = {}
## Сколько точек ОД РИСОВАТЬ у юнита, пока идёт анимация чужого хода (#99): id → число.
## Ход ИИ и слот мирных применяются к состоянию целиком и лишь потом отыгрываются, так
## что без этого жёлтые точки гасли разом до первого кубика и игрок не видел, за что
## именно противник заплатил. На симуляцию словарь не влияет — только на кадр.
var _ap_display: Dictionary = {}
const AP_DOT_DELAY := 0.18
## Стек снимков состояния для отката (#47). Каждый успешный ход локального игрока
## кладёт снимок; кнопка Undo снимает последний. Очищается на границе хода/ИИ.
var _undo_stack: Array[Dictionary] = []
var _undo_btn: Button
## Обратный стек для Redo (#38): туда уходит снимок, снятый кнопкой Undo. Любое новое
## действие делает откатанную ветку недостижимой, поэтому стек чистится.
var _redo_stack: Array[Dictionary] = []
var _redo_btn: Button
## Перетаскивание (§3.4): выбранный объект-клетка на первом шаге, -1 = ещё не выбран.
var drag_object: Vector2i = Vector2i(-1, -1)
var move_dest: Vector2i = Vector2i(-1, -1)  # выбранная цель переноса, ждём клетку пленника
## Копка окопа (§3.7): выбранная клетка окопа и первая куча земли; sentinel -1 = не выбрано.
var dig_trench: Vector2i = Vector2i(-1, -1)
var dig_dirt_a: Vector2i = Vector2i(-1, -1)
## Клетка РСП, из которого сейчас целимся (§3.7).
var rsp_active: Vector2i = Vector2i(-1, -1)
## RTS-выделение группы (#18): id выбранных юнитов и состояние рамки выделения ЛКМ.
## Рамка задаётся экранными точками; протяжка > BOX_DRAG_THRESHOLD включает режим рамки.
var _group_ids: Array[int] = []
## Рамка работает только при нажатой кнопке «Multi-Select» (#21) — иначе ЛКМ
## всегда остаётся обычным кликом по клетке.
var _multi_btn: CheckBox
var _box_dragging: bool = false
var _box_start_screen: Vector2 = Vector2.ZERO
var _box_end_screen: Vector2 = Vector2.ZERO
const BOX_DRAG_THRESHOLD := 8.0
## Техника (§техника): выбранная машина и цели её движения (центр → {dir, steps}).
var selected_vehicle_id: int = -1
var veh_move_targets: Dictionary = {}
var veh_disembark_id: int = -1
var _animating: bool = false

## Пауза между действиями ИИ (#52): бойцы должны ходить ОДИН ЗА ДРУГИМ и на глазах,
## а не отрабатывать всю армию за пару кадров.
const AI_STEP_DELAY := 0.12

## Пауза между клетками пешего перехода (#96) — по ней видно, КУДА идёт житель.
const WALK_STEP_DELAY := 0.07

## Предохранитель от зависшего хода ИИ (#60): столько подряд отклонённых намерений
## терпим, прежде чем сдать ход за него принудительно.
const AI_MAX_DENIED := 12
var _ai_denied_streak: int = 0

var p1_is_ai: bool = false
var p2_is_ai: bool = false
var ai_difficulty: int = AIController.Difficulty.NORMAL

## Панорама «камеры» по полю (WASD / средняя-правая мышь / жест тачпада).
var pan: Vector2 = Vector2.ZERO
const PAN_SPEED := 700.0
var _mouse_panning: bool = false
## Масштаб «камеры» (колесо мыши / жест щипка). Применяется к рисованию через
## draw_set_transform, поэтому CELL в draw-вызовах остаётся прежним.
var zoom: float = 1.0
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
var _status_label: Label
var _info_label: Label
var _log_label: RichTextLabel
var _menu: PanelContainer
var _picker: PanelContainer
var _dice: DiceRoller
## Кастомное модальное окно «выйти в меню» в общем стиле интерфейса (#51), а не
## системный ConfirmationDialog. Полноэкранный затемнитель + рамка SteamChrome.
var _quit_dialog: Control
var _p1_btn: Button
var _p2_btn: Button
var _diff_btn: Button
var networked: bool = false
var my_owner: int = MCF.Owner.PLAYER_1
var session: NetworkSession = null
var net: NetGame = null
## Строка сетевого состояния — видна ТОЛЬКО в сетевой партии (#54); сами кнопки
## Host/Join уехали во вкладку Multiplayer главного меню.
var _net_status: Label

func _ready() -> void:
	p1_is_ai = GameConfig.p1_is_ai
	p2_is_ai = GameConfig.p2_is_ai
	ai_difficulty = GameConfig.ai_difficulty
	# Картинки-замены перечитываются при входе в бой (#55): подменил файл — видно
	# со следующей партии, перезапускать игру не нужно.
	Sprites.reload_overrides()
	_build_state()
	_build_controllers()
	_build_ui()
	Ui.theme_canvas_layers()  # HUD lives on a CanvasLayer; pull in the Steam skin.
	# Связь налажена во вкладке Multiplayer главного меню (#54) — подхватываем её.
	# ДО открытия партии: в сети стартовый слот мирных отыгрывает хост и высылает
	# его броски клиенту (#93), иначе каждая сторона сыграла бы его по-своему.
	_adopt_network()
	# После UI — иначе первые строки боя (порядок инициативы) уйдут в никуда.
	if not networked:
		_open_match()
	_refresh_status()
	set_process(true)
	queue_redraw()

# --- Панорама камеры по WASD ---
func _process(delta: float) -> void:
	# Не двигаем камеру, пока игрок печатает в текстовом поле (например, IP хоста).
	_reposition_hud_grip()
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit:
		return
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): dir.y += 1
	if Input.is_key_pressed(KEY_S): dir.y -= 1
	if Input.is_key_pressed(KEY_A): dir.x += 1
	if Input.is_key_pressed(KEY_D): dir.x -= 1
	if dir != Vector2.ZERO:
		pan += dir.normalized() * PAN_SPEED * delta
		queue_redraw()

func _build_state() -> void:
	if MapHandoff.pending != null:
		state = MapHandoff.pending.build_state(MapHandoff.take_seed())
		resolver = GameActionResolver.new(state)
		resolver.fog_enabled = GameConfig.fog_enabled
		MapHandoff.pending = null
		resolver.update_airlocks()
		state.log.line_added.connect(_on_log_line)
		return
	state = GameState.new(GRID_W, GRID_H)
	resolver = GameActionResolver.new(state)
	resolver.fog_enabled = GameConfig.fog_enabled

	# Демо-ростер: показываем спецстрелков. Слева P1, справа P2 (зеркально).
	# Смещения от края к центру для каждой стороны.
	var roster := [
		["light_infantry", Vector2i(0, 1)],
		["heavy_infantry", Vector2i(0, 3)],
		["sniper", Vector2i(0, 5)],
		["machinegunner", Vector2i(0, 7)],
		["anti_tank", Vector2i(0, 9)],
		["assault", Vector2i(2, 2)],
		["marksman", Vector2i(2, 4)],
		["shield_bearer", Vector2i(2, 6)],
		["miner", Vector2i(2, 8)],
		["commander", Vector2i(2, 10)],
		["drone_operator", Vector2i(2, 0)],
		["engineer", Vector2i(4, 5)],
	]
	for entry in roster:
		var stats: UnitStats = load("res://src/data/units/%s.tres" % entry[0])
		var off: Vector2i = entry[1]
		state.spawn_unit(stats, Vector2i(1 + off.x, off.y), MCF.Owner.PLAYER_1)
		state.spawn_unit(stats, Vector2i(GRID_W - 2 - off.x, off.y), MCF.Owner.PLAYER_2)

	# Мирные жители — нейтральная сторона в центре карты (§3.10). Экран Setup может отключить.
	if GameConfig.civilians_enabled:
		var civ_stats: UnitStats = load("res://src/data/units/civilian.tres")
		for c in [Vector2i(GRID_W / 2, 4), Vector2i(GRID_W / 2, 7)]:
			state.spawn_unit(civ_stats, c, MCF.Owner.NEUTRAL)

	# Демо-техника (§техника): танк 3×3 у P1, челнок 2×2 у P2.
	state.spawn_vehicle("tank", Vector2i(6, 1), MCF.Owner.PLAYER_1)
	state.spawn_vehicle("shuttle", Vector2i(GRID_W - 8, 8), MCF.Owner.PLAYER_2)

	# Инициатива бросается один раз — когда все юниты уже на карте (#53).
	state.turns.begin_match(state.all_units(), state.dice)

	state.log.line_added.connect(_on_log_line)

## Начало боя (#53): объявляем выпавший на всю партию порядок инициативы и, если
## первым в нём стоит слот мирных, сразу отыгрываем его — контроллера у
## нейтральной стороны нет, её ход проводит сам резолвер.
func _open_match() -> void:
	state.log.add("— Initiative this match: %s —" % state.turns.order_names())
	await _play_civilian_result(resolver.play_civilian_slots())
	# Ходящий первым может оказаться машиной (#103): до этого ИИ запускался только ПОСЛЕ
	# чужого действия, и партия «ИИ против ИИ» просто стояла на месте, пока человек не
	# нажмёт что-нибудь — а нажимать ему нечем, своих юнитов у него нет.
	_kick_if_ai()

## Отдать ход текущей стороне, если ею управляет не человек.
func _kick_if_ai() -> void:
	if state == null or _animating:
		return
	var ac: PlayerController = controllers.get(state.active_player())
	if ac != null and not ac.is_local_human():
		_queue_ai_step(ac)

## Показать отыгранный слот мирных (#96): сначала анимация их шагов и бросков, и лишь
## затем строки в журнал — иначе лог сообщал бы об убитом раньше, чем упадёт кубик.
func _play_civilian_result(res: ActionResult) -> void:
	if not res.dice_events.is_empty():
		_pending_death_ids.clear()
		for id: int in res.deaths:
			_pending_death_ids[id] = true
		queue_redraw()
		await _play_dice(res.dice_events)
		_pending_death_ids.clear()
		queue_redraw()
	state.log.publish_result(res)
	_refresh_status()

func _build_controllers() -> void:
	# Обе стороны переключаются человек/ИИ (§2.1, #103). Раньше первый игрок был жёстко
	# прошит локальным человеком, и посмотреть бой ИИ против ИИ было нельзя вообще.
	_make_side(MCF.Owner.PLAYER_1)
	_make_side(MCF.Owner.PLAYER_2)

func _make_p2() -> void:
	_make_side(MCF.Owner.PLAYER_2)

func _side_is_ai(side: int) -> bool:
	return p1_is_ai if side == MCF.Owner.PLAYER_1 else p2_is_ai

func _make_side(side: int) -> void:
	var old: PlayerController = controllers.get(side)
	if old != null and old.intent_ready.is_connected(_on_intent_ready):
		old.intent_ready.disconnect(_on_intent_ready)
	var c: PlayerController
	if _side_is_ai(side):
		c = AIController.new(side, ai_difficulty)
	else:
		c = LocalHumanController.new(side)
	c.intent_ready.connect(_on_intent_ready)
	controllers[side] = c
	_refresh_omniscience()

## Кто видит поле насквозь. ИИ знает позиции всех юнитов сквозь туман (#43): его прицел
## легален и по скрытым.
##
## Поле в резолвере одно, а сторон-всеведущих теперь может быть две (#103). Разводится это
## так: у КАЖДОГО решения ИИ свой резолвер, и он сам ставит туда себя (AIController._decide),
## поэтому общий резолвер Main отвечает лишь за то, что видно на экране. Отсюда и правило —
## если человека за столом не осталось, тумана нет вовсе: зритель смотрит бой целиком, а
## прятать от него нечего.
func _refresh_omniscience() -> void:
	if resolver == null:
		return
	if p1_is_ai and p2_is_ai:
		resolver.fog_enabled = false
		resolver.omniscient_side = -1
	else:
		resolver.fog_enabled = GameConfig.fog_enabled
		if p2_is_ai:
			resolver.omniscient_side = MCF.Owner.PLAYER_2
		elif p1_is_ai:
			resolver.omniscient_side = MCF.Owner.PLAYER_1
		else:
			resolver.omniscient_side = -1

# --- Ввод по сетке ---
func _unhandled_input(event: InputEvent) -> void:
	# Esc — контекстная отмена (#54): сначала снимает выбранное действие, затем
	# снятие выделения, и только на «пустом» состоянии открывает выход в меню.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_escape_pressed()
		get_viewport().set_input_as_handled()
		return
	# Ввод над всплывающим меню принадлежит меню (#8): не панорамируем, не зумим
	# и не кликаем по полю под ним. Прокрутку колесом уже получил сам ScrollContainer;
	# всё, что «просочилось» сюда (например, докрутка на границе), просто гасим, чтобы
	# камера не ехала вместе с меню.
	if event is InputEventMouseButton and _pointer_over_popup(event.position):
		return
	# Панорама мышью (средняя/правая кнопка) и жестом тачпада — работает всегда.
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		_mouse_panning = event.pressed
		return
	if event is InputEventMouseMotion and _mouse_panning:
		pan += event.relative
		queue_redraw()
		return
	if event is InputEventPanGesture:
		pan -= event.delta * 24.0
		queue_redraw()
		return
	# Масштаб: колесо мыши и жест щипка тачпада — сохраняем клетку под курсором.
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, ZOOM_STEP)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
			return
	if event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		return
	if _animating:
		return
	# Рисование БРУ-стены: тянем цепочку клеток левой кнопкой; Backspace — отмена
	# последней/выход, Enter — подтвердить, когда набрано 6 клеток (§3.7).
	if mode == Mode.BUILD_WALL:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_wall_drawing = true
				_wall_try_add(_pos_to_cell(get_global_mouse_position()))
			else:
				_wall_drawing = false
			return
		if event is InputEventMouseMotion:
			if _wall_drawing:
				_wall_try_add(_pos_to_cell(get_global_mouse_position()))
			else:
				queue_redraw()
			return
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_BACKSPACE:
				_wall_undo()
				return
			if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
				_wall_commit()
				return
	if HOVER_PREVIEW_MODES.has(mode) and event is InputEventMouseMotion:
		queue_redraw()  # обновляем предпросмотр радиуса/струи/окопа под курсором
		return
	# Групповое движение: под курсором показываем, кто куда встанет (#88). Рамку
	# выделения не ломаем — перерисовываем только при отпущенной ЛКМ.
	if mode == Mode.GROUP_MOVE and event is InputEventMouseMotion \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
		queue_redraw()
		return
	# Рамка выделения (RTS, #18): в нейтральных режимах ЛКМ тянет прямоугольник,
	# отпускание выделяет всех своих активных юнитов внутри. Короткая протяжка — обычный
	# клик. В сетевой игре групповое управление отключено (риск десинка).
	if _box_selectable() and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_box_start_screen = event.position
			_box_end_screen = event.position
			_box_dragging = false
		else:
			if _box_dragging:
				_box_dragging = false
				_finalize_box()
			else:
				_handle_click(_pos_to_cell(get_global_mouse_position()))
		return
	if _box_selectable() and event is InputEventMouseMotion \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_box_end_screen = event.position
		if not _box_dragging and event.position.distance_to(_box_start_screen) >= BOX_DRAG_THRESHOLD:
			_box_dragging = true
		if _box_dragging:
			queue_redraw()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_click(_pos_to_cell(get_global_mouse_position()))

func _handle_click(coord: Vector2i) -> void:
	if not state.grid.in_bounds(coord):
		_deselect()
		return
	var occupant: UnitInstance = _unit_at(coord)
	# Прицеливание: из стопки «дрон над юнитом» берём того, кто реально доступен как
	# цель, иначе по клетке с дроном нельзя было бы достать наземного бойца (#23).
	if not target_ids.is_empty():
		for u in _stack_at(coord):
			if target_ids.has(u.id):
				occupant = u
				break

	match mode:
		Mode.MOVE:
			if reach != null and reach.can_reach(coord):
				# Если несём пленника — сперва выбираем, куда его положить (§3.4).
				var carried := resolver.held_unit_of(_selected_unit())
				if carried != null:
					move_dest = coord
					item_cells = resolver.carry_drop_cells(coord)
					mode = Mode.CARRY_DROP
					queue_redraw()
					return
				_submit(MoveIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.CARRY_DROP:
			if item_cells.has(coord):
				_submit(MoveIntent.new(selected_id, move_dest, coord))
				return
			_back_to_menu()
		Mode.CORPSE_DROP:
			# Труп кладётся на выбранную клетку, а не молча под ноги (#72).
			if item_cells.has(coord):
				_submit(DropCorpseIntent.new(selected_id, coord))
				return
			_back_to_menu()
		Mode.WELD:
			if item_cells.has(coord):
				_submit(WeldAirlockIntent.new(selected_id, coord))
				return
			_back_to_menu()
		Mode.MOVE_HELD:
			# Пленника переставляем на соседнюю с носильщиком клетку бесплатно (#100).
			if item_cells.has(coord):
				_submit(MoveHeldIntent.new(selected_id, coord))
				return
			_back_to_menu()
		Mode.SHOOT:
			if occupant != null and target_ids.has(occupant.id):
				_begin_shoot(occupant)
				return
			# Марксманн: клик по ЛЮБОЙ клетке задаёт направление, луч уходит вперёд (#49).
			# Отказ (мало ОД, клик по себе) отдаём резолверу — он объяснит причину в журнале.
			if _is_marksman(_selected_unit()) and coord != _selected_unit().coord:
				_submit(ShootIntent.new(selected_id, -1, -1, coord))
				return
			# Противотанкист: удар по пустой клетке пола (§3.14).
			if item_cells.has(coord):
				_submit(ShootIntent.new(selected_id, -1, -1, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.GRAB:
			# Единая «рука» (#50): шаг 1 — боец ИЛИ объект; для объекта шаг 2 — куда тащить.
			if drag_object == Vector2i(-1, -1):
				if occupant != null and target_ids.has(occupant.id):
					_submit(CaptureIntent.new(selected_id, occupant.id))
					return
				if item_cells.has(coord):
					drag_object = coord
					item_cells = resolver.drag_dest_cells(_selected_unit(), coord)
					queue_redraw()
					return
				if _is_own_active(occupant):
					_select(occupant)
					return
				_back_to_menu()
			else:
				if item_cells.has(coord):
					_submit(DragIntent.new(selected_id, drag_object, coord))
					return
				_back_to_menu()
		Mode.ITEM:
			if item_cells.has(coord):
				_submit(UseItemIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.PUSH:
			if occupant != null and target_ids.has(occupant.id):
				_submit(PushIntent.new(selected_id, occupant.id))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.DRONE_FLY:
			if item_cells.has(coord) or _drone_can_ram(coord):
				_submit(DroneMoveIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.BUILD:
			if item_cells.has(coord):
				_submit(BuildIntent.new(selected_id, coord, build_feature))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.BREAK:
			if item_cells.has(coord):
				_submit(BreakIntent.new(selected_id, coord))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.RSP_FIRE:
			if occupant != null and target_ids.has(occupant.id):
				_submit(RSPFireIntent.new(selected_id, rsp_active, occupant.id, -1))
				return
			if _is_own_active(occupant):
				_select(occupant)
				return
			_back_to_menu()
		Mode.DIG:
			# Копка в 3 шага (#16): 1) клетка под окоп, 2) первая куча земли, 3) вторая
			# куча — сразу роем. Игрок сам выбирает, куда лечь вынутой земле.
			if dig_trench == Vector2i(-1, -1):
				if item_cells.has(coord):
					dig_trench = coord
					dig_dirt_a = Vector2i(-1, -1)
					item_cells = resolver.dirt_spots_for(coord, _selected_unit().coord)
					queue_redraw()
					return
				if _is_own_active(occupant):
					_select(occupant)
					return
				_back_to_menu()
			elif dig_dirt_a == Vector2i(-1, -1):
				# Первая куча (можно затем выбрать ту же клетку второй — вырастет выше).
				if item_cells.has(coord):
					dig_dirt_a = coord
					queue_redraw()
					return
				_enter_dig()  # клик мимо — начинаем выбор окопа заново
			else:
				if item_cells.has(coord):
					_submit(DigIntent.new(selected_id, dig_trench, dig_dirt_a, coord))
					return
				_enter_dig()
		Mode.GROUP_MENU:
			# Меню группы открыто: клик по полю снимает выделение (или берёт другой юнит).
			if occupant != null and _is_own_active(occupant):
				_set_group([])
				_select(occupant)
				return
			_set_group([])
		Mode.GROUP_MOVE:
			# Клик по своему юниту вне группы — обычное выделение; иначе двигаем группу.
			if occupant != null and _is_own_active(occupant) and not _group_ids.has(occupant.id):
				_set_group([])
				_select(occupant)
				return
			_group_move_to(coord)
		Mode.VEH_MOVE:
			if veh_move_targets.has(coord):
				var mt: Dictionary = veh_move_targets[coord]
				_submit(VehicleMoveIntent.new(selected_vehicle_id, mt["dir"], mt["steps"]))
				return
			_veh_back_to_menu()
		Mode.VEH_TURN:
			var veh := _selected_vehicle()
			if veh != null:
				var d := coord - veh.center()
				var dir := Vector2i(signi(d.x), signi(d.y))
				if dir != Vector2i.ZERO and dir != veh.facing:
					_submit(VehicleTurnIntent.new(selected_vehicle_id, dir))
					return
			_veh_back_to_menu()
		Mode.VEH_CANNON:
			if item_cells.has(coord):
				_submit(VehicleCannonIntent.new(selected_vehicle_id, coord))
				return
			_veh_back_to_menu()
		Mode.VEH_DISEMBARK:
			if item_cells.has(coord) and veh_disembark_id != -1:
				_submit(VehicleDisembarkIntent.new(veh_disembark_id, coord))
				return
			_veh_back_to_menu()
		_:
			# Клик по корпусу своей машины — выбрать её.
			var cveh := resolver.controllable_vehicle_at(coord, state.active_player())
			if cveh != null and _can_control(cveh.owner):
				_select_vehicle(cveh)
				return
			var pick := _cycle_pick(coord)
			if pick != null:
				_select(pick)
			else:
				_deselect()

## Юнит, которым игрок может командовать ПРЯМО СЕЙЧАС как пехотинцем на поле.
## Сидящий в машине — не такой (#95): при посадке его снимают с сетки и ставят
## coord = OFFBOARD, поэтому меню пехоты для него строить нельзя — половина пунктов
## лезет в state.grid.cell(coord) и получает null. Наружу он выходит только через
## Disembark в меню самой машины.
func _is_own_active(u: UnitInstance) -> bool:
	return u != null and u.is_alive() and u.aboard_vehicle_id == -1 \
			and u.owner == state.active_player() and _can_control(u.owner)

## Может ли ЛОКАЛЬНЫЙ игрок командовать этой стороной. Проверка только на networked
## была дырой (#60): в hotseat она пропускала всех, поэтому на ходу ИИ поле
## оставалось кликабельным. Между шагами ИИ есть пауза AI_STEP_DELAY, и чем больше
## у него юнитов, тем дольше ход — игрок успевал открыть меню чужого бойца и
## доиграть ход за компьютер. Мирные (NEUTRAL) тоже не наши: контроллера у них нет.
func _can_control(unit_owner: int) -> bool:
	if networked:
		return unit_owner == my_owner
	return _owner_is_local_human(unit_owner)

# --- Выбор и меню действий ---
func _select(unit: UnitInstance) -> void:
	selected_id = unit.id
	# Выбор пехотинца снимает выбор машины (#97). Без этого selected_vehicle_id оставался
	# от ранее выбранного танка, и _back_to_menu() после действия солдата открывал меню
	# танка вместо меню самого солдата.
	selected_vehicle_id = -1
	veh_move_targets = {}
	veh_disembark_id = -1
	mode = Mode.MENU
	reach = null
	target_ids = []
	item_cells = []
	_open_menu(unit)
	_refresh_info()
	queue_redraw()

func _deselect() -> void:
	selected_id = -1
	selected_vehicle_id = -1
	veh_move_targets = {}
	veh_disembark_id = -1
	_group_ids = []
	mode = Mode.NONE
	reach = null
	target_ids = []
	item_cells = []
	_menu.hide()
	_picker.hide()
	_refresh_info()
	queue_redraw()

func _back_to_menu() -> void:
	if selected_vehicle_id != -1:
		_veh_back_to_menu()
		return
	var u := state.get_unit(selected_id)
	if _is_own_active(u):
		_select(u)
	else:
		_deselect()

## Контекстная отмена по Esc (#54). Приоритет: закрыть диалог → отменить рисование
## БРУ → выйти из под-режима действия в меню (unchoose) → снять выделение → выход.
func _escape_pressed() -> void:
	if _quit_dialog.visible:
		_quit_dialog.hide()
		return
	if _animating:
		return
	# Отмена незакоммиченного рисования БРУ-стены.
	if mode == Mode.BUILD_WALL:
		_wall_cells = []
		_refresh_undo_btn()
		_back_to_menu()
		return
	# Групповое движение (#19) — вернуться в меню группы.
	if mode == Mode.GROUP_MOVE:
		mode = Mode.GROUP_MENU
		_open_group_menu()
		queue_redraw()
		return
	# Групповое выделение (#18) — снять его.
	if mode == Mode.GROUP_MENU:
		_set_group([])
		return
	# Выбрано действие машины — вернуть меню машины.
	if selected_vehicle_id != -1 and mode != Mode.VEH_MENU:
		_veh_back_to_menu()
		return
	# Выбрано действие пехотинца — вернуть меню юнита (отменить выбор действия).
	if selected_id != -1 and mode != Mode.MENU and mode != Mode.NONE:
		_back_to_menu()
		return
	# Юнит/машина выбраны, но мы в меню — снять выделение.
	if selected_id != -1 or selected_vehicle_id != -1:
		_deselect()
		return
	# Ничего не выбрано — открыть выход в главное меню.
	_quit_dialog.show()

func _selected_unit() -> UnitInstance:
	return state.get_unit(selected_id) if selected_id != -1 else null

# --- Машины (§техника) ---
func _selected_vehicle() -> Vehicle:
	return state.get_vehicle(selected_vehicle_id) if selected_vehicle_id != -1 else null

func _select_vehicle(veh: Vehicle) -> void:
	selected_id = -1
	selected_vehicle_id = veh.id
	veh_move_targets = {}
	veh_disembark_id = -1
	mode = Mode.VEH_MENU
	reach = null
	target_ids = []
	item_cells = []
	_open_vehicle_menu(veh)
	_refresh_info()
	queue_redraw()

func _veh_back_to_menu() -> void:
	var veh := _selected_vehicle()
	if veh != null and veh.alive() and _can_control(veh.owner):
		_select_vehicle(veh)
	else:
		_deselect()

func _open_vehicle_menu(veh: Vehicle) -> void:
	_picker.hide()
	for c in _menu.get_children():
		c.queue_free()
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var vb := _scroll_menu(_menu, spec.get("name", veh.type_id))
	var acting: bool = veh.ap > 0 and _can_control(veh.owner)

	# Докатить остаток прошлого движения можно и без ОД (#97) — как у пехоты.
	var veh_credit := resolver.vehicle_move_credit(veh)
	if (acting or (veh_credit > 0 and _can_control(veh.owner))) \
			and not veh_move_targets_preview(veh).is_empty():
		var move_btn := Button.new()
		move_btn.text = "Move (%d left)" % veh_credit if veh_credit > 0 else "Move"
		move_btn.pressed.connect(_veh_enter_move)
		vb.add_child(move_btn)

	if acting and veh.facing != Vector2i.ZERO:
		var turn_btn := Button.new()
		turn_btn.text = "Turn (%d AP)" % VehicleRules.TURN_COST
		turn_btn.pressed.connect(_veh_enter_turn)
		vb.add_child(turn_btn)

	var gun: Dictionary = spec.get("weapons", {}).get("main_gun", {})
	if acting and not gun.is_empty() and veh.ap >= int(gun.get("ap_cost", 1)) \
			and veh.cannon_shots_this_round < int(gun.get("max_per_turn", 2)):
		var cannon_btn := Button.new()
		cannon_btn.text = "Fire Cannon (%d AP)" % int(gun.get("ap_cost", 1))
		cannon_btn.pressed.connect(_veh_enter_cannon)
		vb.add_child(cannon_btn)

	# Посадка соседней пехоты.
	if _can_control(veh.owner):
		for uid in resolver.vehicle_board_candidates(veh):
			var u := state.get_unit(uid)
			if u == null:
				continue
			var board_btn := Button.new()
			board_btn.text = "Board: %s" % u.stats.display_name
			board_btn.pressed.connect(_veh_board.bind(uid))
			vb.add_child(board_btn)

	# Высадка экипажа.
	if _can_control(veh.owner) and not veh.occupants.is_empty() \
			and not resolver.vehicle_disembark_cells(veh).is_empty():
		for uid in veh.occupants:
			var u := state.get_unit(uid)
			if u == null:
				continue
			var dis_btn := Button.new()
			dis_btn.text = "Disembark: %s" % u.stats.display_name
			dis_btn.pressed.connect(_veh_enter_disembark.bind(uid))
			vb.add_child(dis_btn)

	if not _has_action_button(vb):
		_menu.hide()
		return

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_deselect)
	vb.add_child(cancel_btn)

	_anchor_menu(_menu)
	_menu.show()

## Есть ли куда ехать (для показа кнопки Move без мутаций).
func veh_move_targets_preview(veh: Vehicle) -> Dictionary:
	return resolver.vehicle_move_targets(veh)

func _veh_enter_move() -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	veh_move_targets = resolver.vehicle_move_targets(veh)
	mode = Mode.VEH_MOVE
	item_cells = []
	_menu.hide()
	queue_redraw()

func _veh_enter_turn() -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	mode = Mode.VEH_TURN
	item_cells = []
	veh_move_targets = {}
	_menu.hide()
	queue_redraw()

func _veh_enter_cannon() -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	# Подсветку считает сам резолвер (#58, #62, #70): амбразуры со всех трёх клеток
	# борта, дальность и перекрытие линии огня. Дублировать правила здесь нельзя —
	# именно так подсветка когда-то и разошлась с тем, что выстрел реально может.
	var vis := resolver.team_visible_coords(state.active_player())
	item_cells = resolver.cannon_target_cells(veh, vis)
	mode = Mode.VEH_CANNON
	veh_move_targets = {}
	_menu.hide()
	queue_redraw()

func _veh_board(unit_id: int) -> void:
	_submit(VehicleBoardIntent.new(unit_id, selected_vehicle_id))

func _veh_enter_disembark(unit_id: int) -> void:
	var veh := _selected_vehicle()
	if veh == null:
		return
	veh_disembark_id = unit_id
	item_cells = resolver.vehicle_disembark_cells(veh)
	mode = Mode.VEH_DISEMBARK
	veh_move_targets = {}
	_menu.hide()
	queue_redraw()

func _pending_shoot(u: UnitInstance) -> bool:
	return u.action_state != null and u.action_state.is_pending()

## Есть ли НЕЗАВЕРШЁННАЯ стрельба, цель которой ещё МОЖНО достреливать (#45).
## Устаревшая привязка (цель мертва/скрыта/сошла с линии) не должна блокировать
## возможность начать новую стрельбу оставшимися ОД.
func _valid_pending_shoot(u: UnitInstance) -> bool:
	if not _pending_shoot(u):
		return false
	var t := state.get_unit(u.action_state.target_id)
	return t != null and resolver.can_shoot(u, t) == ""

func _enter_move() -> void:
	var u := _selected_unit()
	# Двигаться можно за новый ОД, либо доходя остаток текущего действия (#44).
	if u == null or (u.remaining_ap <= 0 and u.move_credit <= 0):
		return
	mode = Mode.MOVE
	# Бюджет обязан совпадать с резолвером, иначе подсвеченные клетки не совпадут
	# с тем, что он примет, и движение «не работает» (§3.4, #42/#44/#65).
	var burdened := resolver.held_unit_of(u) != null \
			or resolver.dragged_cell_of(u) != UnitInstance.NOT_DRAGGING
	var carry_budget := maxi(0, u.stats.speed - MCF.CAPTURE_CARRY_PENALTY)
	var budget: int
	if u.move_credit > 0:
		budget = u.move_credit
	elif burdened:
		budget = carry_budget
	else:
		budget = u.stats.speed
	if burdened:
		budget = mini(budget, carry_budget)
	reach = Movement.reachable(state.grid, u.coord, budget)
	reach_budget = budget
	target_ids = []
	_menu.hide()
	queue_redraw()

func _enter_shoot() -> void:
	var u := _selected_unit()
	if u == null:
		return
	mode = Mode.SHOOT
	reach = null
	item_cells = []
	# Устаревшую привязку burst'а сбрасываем, чтобы можно было начать новую стрельбу (#45).
	if _pending_shoot(u) and not _valid_pending_shoot(u):
		u.action_state = null
	# И при незавершённой очереди, и при свежей стрельбе показываем ВСЕ доступные
	# цели: остаток очереди можно дострелить по другой цели (#5).
	if _valid_pending_shoot(u) or u.remaining_ap > 0:
		target_ids = resolver.shootable_target_ids(u)
		# Противотанкист (§3.14) может ещё и ударить по пустой клетке пола.
		if u.stats.special_ability_id == MCF.ABILITY_ANTI_TANK:
			item_cells = resolver.blastable_cells(u)
		# Огнемётчик может пустить струю по пустой клетке пола (в её направлении).
		elif u.stats.special_ability_id == MCF.ABILITY_FLAMETHROWER:
			item_cells = resolver.flammable_cells(u)
	else:
		target_ids = []
	_menu.hide()
	queue_redraw()

func _shoot_ap_cost(u: UnitInstance) -> int:
	return MCF.MARKSMAN_AP_COST if u.stats.special_ability_id == MCF.ABILITY_MARKSMAN else 1

func _is_marksman(u: UnitInstance) -> bool:
	return u != null and u.stats.special_ability_id == MCF.ABILITY_MARKSMAN

## Единая «рука» (#50): в одном режиме и бойцы под захват, и объекты под волочение —
## труп, мешки, ёж, куча земли. Отдельной кнопки Drag больше нет.
func _enter_grab() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.GRAB
	reach = null
	drag_object = Vector2i(-1, -1)
	target_ids = resolver.capturable_target_ids(u)
	item_cells = resolver.draggable_cells(u)
	_menu.hide()
	queue_redraw()

## Перекладывание пленника вокруг носильщика (#100). Свободные соседние клетки
## подсвечиваются теми же средствами, что и клетка сброса при переносе.
func _enter_move_held() -> void:
	var u := _selected_unit()
	if u == null or resolver.held_unit_of(u) == null:
		return
	var cells := resolver.carry_drop_cells(u.coord)
	if cells.is_empty():
		return
	mode = Mode.MOVE_HELD
	reach = null
	target_ids = []
	item_cells = cells
	_menu.hide()
	queue_redraw()

func _enter_item() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0 or resolver.can_use_item(u) != "":
		return
	mode = Mode.ITEM
	reach = null
	target_ids = []
	if u.held_item_id == MCF.ITEM_DRONE_STATION:
		# Станция ставится в соседнюю свободную клетку (§3.12).
		item_cells = []
		for n in state.grid.neighbors(u.coord):
			if state.grid.cell(n).is_empty():
				item_cells.append(n)
	else:
		item_cells = resolver.grenade_target_cells(u)
	_menu.hide()
	queue_redraw()

## Дрон завис над стеной (#96/#99) — единственный его ход отсюда бесплатен и ведёт
## обратно на клетку захода.
func _drone_on_wall(u: UnitInstance) -> bool:
	return u != null and u.is_drone and state.grid.in_bounds(u.coord) \
			and state.grid.cell(u.coord).is_wall()

func _enter_drone_fly() -> void:
	var u := _selected_unit()
	if u == null or not u.is_drone:
		return
	# Спуск со стены бесплатен (#99), поэтому «Fly» открывается и на нулевых ОД —
	# иначе дрон оставался бы сидеть на стене до конца раунда.
	if u.remaining_ap <= 0 and not _drone_on_wall(u):
		return
	mode = Mode.DRONE_FLY
	reach = null
	target_ids = []
	item_cells = resolver.drone_flight_cells(u)
	_menu.hide()
	queue_redraw()

## Всё, что стоит на клетке, сверху вниз: дрон висит НАД наземным юнитом (#13, он не
## занимает слот клетки), под ним — живой юнит или труп.
func _stack_at(coord: Vector2i) -> Array[UnitInstance]:
	var out: Array[UnitInstance] = []
	if not state.grid.in_bounds(coord):
		return out
	var drone := _drone_at(coord)
	if drone != null:
		out.append(drone)
	var occ: UnitInstance = state.grid.cell(coord).occupant
	if occ != null:
		out.append(occ)
	return out

## Юнит на клетке для кликов: верхний в стопке — дрон, если он там есть (#23).
func _unit_at(coord: Vector2i) -> UnitInstance:
	var stack := _stack_at(coord)
	return stack[0] if not stack.is_empty() else null

## Кого из стопки берём при повторных кликах: сначала дрон, следующим кликом — тот,
## кто под ним (#23). Только свои активные — иначе выделение снимается.
func _cycle_pick(coord: Vector2i) -> UnitInstance:
	var pickable: Array[UnitInstance] = []
	for u in _stack_at(coord):
		if u.owner == state.active_player() and u.is_on_field() and _can_control(u.owner):
			pickable.append(u)
	if pickable.is_empty():
		return null
	for i in pickable.size():
		if pickable[i].id == selected_id:
			return pickable[(i + 1) % pickable.size()]
	return pickable[0]

func _drone_at(coord: Vector2i) -> UnitInstance:
	for u in state.all_units():
		if u.is_drone and u.is_alive() and u.coord == coord:
			return u
	return null

func _drone_can_ram(coord: Vector2i) -> bool:
	var u := _selected_unit()
	if u == null or not u.is_drone or not state.grid.in_bounds(coord):
		return false
	var cell := state.grid.cell(coord)
	# Таран только по стене, корпусу машины или другому дрону (#13).
	var other := _drone_at(coord)
	var blocked: bool = cell.is_wall() or cell.vehicle_id != -1 or (other != null and other != u)
	if not blocked:
		return false
	if _adjacent8(coord, u.coord):
		return true
	for fc in item_cells:
		if _adjacent8(coord, fc):
			return true
	return false

func _adjacent8(a: Vector2i, b: Vector2i) -> bool:
	var d := (a - b).abs()
	return maxi(d.x, d.y) == 1

# --- RTS-выделение и групповое движение (#18) ---
## Рамкой можно выделять только в «нейтральных» режимах локальной игры (не во время
## прицеливания и не по сети — там пошаговый ввод идёт через контроллеры).
func _box_selectable() -> bool:
	if networked or state == null:
		return false
	# Рамка включается только тумблером «Multi-Select» (#21).
	if _multi_btn == null or not _multi_btn.button_pressed:
		return false
	var ctrl: PlayerController = controllers.get(state.active_player())
	if ctrl == null or not ctrl.is_local_human():
		return false
	return mode == Mode.NONE or mode == Mode.MENU \
			or mode == Mode.GROUP_MENU or mode == Mode.GROUP_MOVE

func _on_multi_toggled(pressed: bool) -> void:
	if not pressed:
		_set_group([])
	_box_dragging = false
	queue_redraw()

## По завершении рамки — собрать своих активных пехотинцев внутри прямоугольника.
func _finalize_box() -> void:
	var a := _pos_to_cell(_box_start_screen)
	var b := _pos_to_cell(_box_end_screen)
	var x0 := mini(a.x, b.x)
	var x1 := maxi(a.x, b.x)
	var y0 := mini(a.y, b.y)
	var y1 := maxi(a.y, b.y)
	var ids: Array[int] = []
	for u in state.all_units():
		if u.owner != state.active_player() or not u.is_alive() or not _can_control(u.owner):
			continue
		if u.is_drone or u.aboard_vehicle_id != -1:
			continue
		if u.coord.x >= x0 and u.coord.x <= x1 and u.coord.y >= y0 and u.coord.y <= y1:
			ids.append(u.id)
	_set_group(ids)

## Установить выделенную группу. 0 → снять выделение; 1 → обычное меню; ≥2 → меню
## групповых действий (#19).
func _set_group(ids: Array[int]) -> void:
	if ids.is_empty():
		_group_ids = []
		if mode == Mode.GROUP_MENU or mode == Mode.GROUP_MOVE:
			_deselect()
		return
	if ids.size() == 1:
		_group_ids = []
		_select(state.get_unit(ids[0]))
		return
	_group_ids = ids
	selected_id = -1
	selected_vehicle_id = -1
	mode = Mode.GROUP_MENU
	reach = null
	target_ids = []
	item_cells = []
	_picker.hide()
	_open_group_menu()
	_refresh_info()
	queue_redraw()

## Меню действий для выделенной группы (#19). Пока в нём одно действие — движение;
## остальные приказы отдаются юнитам по отдельности.
func _open_group_menu() -> void:
	for c in _menu.get_children():
		c.queue_free()
	var vb := _scroll_menu(_menu, "%d units selected" % _group_ids.size())

	var move_btn := Button.new()
	move_btn.text = "Move"
	move_btn.pressed.connect(_enter_group_move)
	vb.add_child(move_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_deselect)
	vb.add_child(cancel_btn)

	_anchor_menu(_menu)
	_menu.show()

func _enter_group_move() -> void:
	mode = Mode.GROUP_MOVE
	_menu.hide()
	queue_redraw()

## Жадное групповое движение к клетке (#18): каждый юнит по очереди идёт в достижимую
## клетку, ближайшую (Чебышёв) к цели. Резолвится последовательно, поэтому юниты не
## наступают друг на друга. После приказа выделение снимается (#19).
func _group_move_to(dest: Vector2i) -> void:
	if networked or not state.grid.in_bounds(dest):
		return
	var pre_snap := state.snapshot()
	var moved := false
	for id in _group_ids.duplicate():
		var u := state.get_unit(id)
		if u == null or not u.is_alive() or u.remaining_ap <= 0:
			continue
		var target := _best_group_cell(u, dest)
		if target == u.coord:
			continue
		var res := resolver.resolve(MoveIntent.new(id, target))
		if res.ok:
			state.log.publish_result(res)
			moved = true
	if moved:
		_redo_stack.clear()
		_undo_stack.append(pre_snap)
		for c in controllers.values():
			c.notify_state_changed(state)
		_refresh_status()
	_set_group([])
	queue_redraw()

## Объединение достижимых клеток всей выделенной группы — зелёная подсветка (#88).
func _group_reach_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var seen: Dictionary = {}
	for id in _group_ids:
		var u := state.get_unit(id)
		if u == null or not u.is_alive() or u.remaining_ap <= 0:
			continue
		for c: Vector2i in Movement.reachable(state.grid, u.coord, u.stats.speed).cost:
			if not seen.has(c):
				seen[c] = true
				out.append(c)
	return out

## Куда встанет каждый юнит группы, если приказать идти в dest. Повторяет порядок и
## занятость клеток из _group_move_to, поэтому предпросмотр совпадает с результатом.
func _group_move_preview(dest: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var taken: Dictionary = {}
	for id in _group_ids:
		var u := state.get_unit(id)
		if u == null or not u.is_alive() or u.remaining_ap <= 0:
			continue
		var spot := _best_group_cell(u, dest, taken)
		taken[spot] = true
		out.append(spot)
	return out

## Достижимая клетка, ближайшая к цели (при равенстве — та, что дешевле по ходу).
## `taken` — клетки, уже разобранные другими юнитами группы (только для предпросмотра;
## в реальном ходе их занятость видна прямо на сетке).
func _best_group_cell(u: UnitInstance, dest: Vector2i, taken: Dictionary = {}) -> Vector2i:
	var reach_r := Movement.reachable(state.grid, u.coord, u.stats.speed)
	var best := u.coord
	var best_d := Combat.distance(u.coord, dest)
	var best_cost := 0
	for c: Vector2i in reach_r.cost:
		if taken.has(c):
			continue
		var d: int = Combat.distance(c, dest)
		var cost: int = reach_r.cost[c]
		if d < best_d or (d == best_d and cost < best_cost):
			best_d = d
			best_cost = cost
			best = c
	return best

func _enter_push() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.PUSH
	reach = null
	item_cells = []
	target_ids = resolver.pushable_target_ids(u)
	_menu.hide()
	queue_redraw()

func _enter_build(feature_id: String) -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	build_feature = feature_id
	mode = Mode.BUILD
	reach = null
	target_ids = []
	# Для мешков/ежа сюда попадают и клетки под ярус поверх уже стоящих мешков (#31).
	item_cells = resolver.buildable_cells(u, feature_id)
	_menu.hide()
	queue_redraw()

# --- Рисование БРУ-стены (§3.7, БРУ 1×6) ---
func _enter_build_wall() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.BUILD_WALL
	reach = null
	target_ids = []
	build_feature = MCF.FEATURE_BRU
	_wall_cells = []
	_wall_drawing = false
	# Пул допустимых клеток — весь свободный пол (буду фильтровать по соединению).
	item_cells = resolver.buildable_cells(u)
	_menu.hide()
	queue_redraw()

## Годится ли клетка как звено формы: свободный пол, не повтор. Первое (опорное)
## звено — соседнее с инженером; каждое следующее должно примыкать ОРТОГОНАЛЬНО к
## уже поставленному (#80) — стена собирается одной связной цепью, без разрывов и
## диагональных «мостиков». Это зеркало проверки резолвера bru_cells_connected().
## ВАЖНО: клетки проверяем по самой сетке, а не по item_cells (кольцо у инженера) —
## иначе БРУ можно было ставить лишь вокруг инженера.
func _wall_valid_next(coord: Vector2i) -> bool:
	var u := _selected_unit()
	if u == null:
		return false
	if _wall_cells.has(coord):
		return false
	if not state.grid.in_bounds(coord) or not state.grid.cell(coord).is_buildable():
		return false
	if _wall_cells.is_empty():
		return Combat.distance(u.coord, coord) == 1
	for c: Vector2i in _wall_cells:
		if absi(c.x - coord.x) + absi(c.y - coord.y) == 1:
			return true
	return false

func _wall_try_add(coord: Vector2i) -> void:
	if _wall_cells.size() >= MCF.BRU_WALL_LENGTH:
		return
	if not _wall_valid_next(coord):
		queue_redraw()
		return
	_wall_cells.append(coord)
	_refresh_undo_btn()
	queue_redraw()
	if _wall_cells.size() >= MCF.BRU_WALL_LENGTH:
		_wall_commit()

func _wall_undo() -> void:
	if _wall_cells.is_empty():
		_back_to_menu()
		return
	_wall_cells.pop_back()
	_refresh_undo_btn()
	queue_redraw()

func _wall_commit() -> void:
	if _wall_cells.size() != MCF.BRU_WALL_LENGTH:
		return
	_submit(BuildWallIntent.new(selected_id, _wall_cells.duplicate()))

func _enter_break() -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.BREAK
	reach = null
	target_ids = []
	item_cells = resolver.breakable_cells(u)
	_menu.hide()
	queue_redraw()

## Выбор клетки, куда лечь трупу (#72). Раньше кнопка сразу роняла его под ноги, из-за
## чего тело нельзя было положить в нужное место — например, в проём как укрытие (#6).
## Действие бесплатное, поэтому проверки на ОД здесь нет.
func _enter_corpse_drop() -> void:
	var u := _selected_unit()
	if u == null or u.carried_corpses <= 0:
		return
	var cells := resolver.corpse_drop_cells(u)
	if cells.is_empty():
		return
	mode = Mode.CORPSE_DROP
	reach = null
	target_ids = []
	item_cells = cells
	_menu.hide()
	queue_redraw()

## Выбор соседнего шлюза под заварку (#99).
func _enter_weld() -> void:
	var u := _selected_unit()
	if u == null:
		return
	var cells := resolver.weldable_cells(u)
	if cells.is_empty():
		return
	mode = Mode.WELD
	reach = null
	target_ids = []
	item_cells = cells
	_menu.hide()
	queue_redraw()

func _enter_rsp_fire(rsp_coord: Vector2i) -> void:
	var u := _selected_unit()
	if u == null or u.remaining_ap <= 0:
		return
	mode = Mode.RSP_FIRE
	rsp_active = rsp_coord
	reach = null
	item_cells = []
	target_ids = resolver.rsp_targets(u, rsp_coord)
	_menu.hide()
	queue_redraw()

func _enter_dig() -> void:
	var u := _selected_unit()
	if u == null or (u.remaining_ap <= 0 and u.dig_credits <= 0):
		return
	mode = Mode.DIG
	reach = null
	target_ids = []
	dig_trench = Vector2i(-1, -1)
	dig_dirt_a = Vector2i(-1, -1)
	item_cells = resolver.diggable_cells(u)
	_menu.hide()
	queue_redraw()

func _begin_shoot(target: UnitInstance) -> void:
	var shooter := _selected_unit()
	if shooter == null:
		return
	var available: int
	if _pending_shoot(shooter):
		available = shooter.action_state.remaining_shots
	else:
		available = shooter.stats.rate_of_fire
	if available <= 1:
		_submit(ShootIntent.new(selected_id, target.id, -1))
		return
	_open_picker(target, available)

# --- Поток намерений (с анимацией кубиков) ---
func _submit(intent: Intent) -> void:
	if networked and state.active_player() != my_owner:
		return
	var ctrl: LocalHumanController = controllers[state.active_player()]
	ctrl.submit(intent)

## Идентификатор ХОДА: раунд + слот инициативы (#94). Откат живёт только внутри
## одного хода, а сменой активной стороны его не поймать — если вторая сторона
## выбита, её слот пропускается, круг замыкается обратно на нас, и active_player()
## остаётся ТЕМ ЖЕ. По владельцу такой переход неотличим от продолжения хода, и
## Undo уезжал в прошлый раунд — уже после того, как всем восстановили ОД.
func _turn_key() -> Vector2i:
	return Vector2i(state.turns.round_number, state.turns.active_index)

## Действие, которое нельзя откатить (#81). Любой выстрел — открытая карта: кубики
## уже брошены и результат известен, откат превратился бы в переброс. Лазер марксманна
## кубиков не бросает, но тоже необратим — он уже снёс стену и убил всех на линии.
func _is_irreversible(intent: Intent, result: ActionResult) -> bool:
	if not result.dice_events.is_empty():
		return true
	return intent is ShootIntent or intent is RSPFireIntent \
			or intent is DroneDetonateIntent or intent is VehicleCannonIntent

func _on_intent_ready(intent: Intent) -> void:
	if networked:
		net.submit_local(intent)
		return
	_menu.hide()
	_picker.hide()
	var turn_before := _turn_key()
	var actor_before := state.active_player()
	# Снимок ДО применения — для отката (#47). Кладём в стек только при успехе.
	#
	# Снимаем его лишь тогда, когда откат вообще возможен, — то есть ходит подконтрольная
	# игроку сторона. Ровно это условие ниже и решает, попадёт ли снимок в стек, а на ходу
	# ИИ и мирных он гарантированно выбрасывался (#94). Стоит же он недёшево: копия всех
	# юнитов и всех клеток поля, в бою на 200 бойцов — около 3 мс. Умножить на полторы
	# сотни действий вражеского хода, и полсекунды уходило на снимки, которые никто
	# никогда не откроет.
	var undoable := _can_control(actor_before)
	var pre_snap: Dictionary = state.snapshot() if undoable else {}
	# Смерть показываем только ПОСЛЕ анимации броска защиты (#46): снимок живых
	# до применения, чтобы отрисовать погибших ещё живыми, пока крутится кубик.
	var alive_before := {}
	for _u in state.all_units():
		if _u.status != MCF.Status.CORPSE:
			alive_before[_u.id] = true
	# Сколько ОД было у действующего юнита ДО хода (#99): пока крутится кубик, точки
	# рисуем по старому значению, и игрок видит, как одна из них гаснет за действие.
	var ap_actor := state.get_unit(intent.actor_id) if intent.actor_id >= 0 else null
	var ap_before := ap_actor.remaining_ap if ap_actor != null else 0
	var result := resolver.resolve(intent)
	if not result.ok:
		state.log.add("[denied] " + result.reason)
		# Отказ на ходу ИИ раньше просто обрывал цепочку: следующий шаг никто не
		# заказывал. Пока поле было кликабельным (#60), это выглядело как «ИИ отдал
		# ход игроку»; теперь ввод закрыт, и обрыв означал бы намертво зависший ход.
		# Поэтому ведём ИИ дальше, а от зацикливания страхуемся счётчиком подряд идущих
		# отказов — упёршись, сдаём ход принудительно.
		var denied_ctrl: PlayerController = controllers.get(state.active_player())
		if denied_ctrl != null and not denied_ctrl.is_local_human():
			_ai_denied_streak += 1
			denied_ctrl.notify_intent_denied(state)
			if _ai_denied_streak >= AI_MAX_DENIED:
				state.log.add("[ai] stuck after %d refusals - ending turn." % _ai_denied_streak)
				_ai_denied_streak = 0
				_on_intent_ready(EndTurnIntent.new())
				return
			_queue_ai_step(denied_ctrl)
			return
		_back_to_menu()
		return
	_ai_denied_streak = 0
	# Действие удалось — кладём снимок для Undo. Конец хода закрывает откат: чистим
	# стек, чтобы не «отменять» уже сыгранный ход (#94).
	# Новое действие обрывает откатанную ветку — повторять больше нечего (#38).
	#
	# Всё, что бросало кубики (стрельба, ПТУР, подрыв дрона, РСП), откату НЕ подлежит
	# (#81): иначе игрок переигрывал бы неудачный бросок. Раньше такой Undo молча
	# откатывал ПРЕДЫДУЩЕЕ действие — стек чистим целиком.
	#
	# Ходы ИИ и мирных в стек не пишем вовсе (#94): откатывать чужой ход игрок не
	# вправе, а лежащий снимок только и ждал, чтобы Undo увёл партию к чужому бойцу.
	_redo_stack.clear()
	if _turn_key() != turn_before or _is_irreversible(intent, result):
		_undo_stack.clear()
	elif undoable:
		_undo_stack.append(pre_snap)
	if not result.dice_events.is_empty():
		# Кто погиб в этом действии — рисуем живым до конца броска.
		_pending_death_ids.clear()
		for _u in state.all_units():
			if _u.status == MCF.Status.CORPSE and alive_before.has(_u.id):
				_pending_death_ids[_u.id] = true
		if ap_actor != null and ap_actor.remaining_ap != ap_before:
			_ap_display[ap_actor.id] = ap_before
			result.dice_events.append({
				"kind": "ap", "unit": ap_actor.id,
				"from": ap_before, "left": ap_actor.remaining_ap,
			})
		queue_redraw()
		await _play_dice(result.dice_events)
		_pending_death_ids.clear()
		queue_redraw()
	state.log.publish_result(result)
	for c in controllers.values():
		c.notify_state_changed(state)
	var active_ctrl: PlayerController = controllers[state.active_player()]
	if not active_ctrl.is_local_human():
		_refresh_status()
		_deselect()
		_queue_ai_step(active_ctrl)
		return
	_after_action()

## Следующий шаг ИИ — через короткую паузу (#52). Без неё вся армия отрабатывает
## за считаные кадры, и вместо хода видно только мгновенный итог; с паузой бойцы
## заметно ходят ОДИН ЗА ДРУГИМ. Пауза же не даёт кадру «залипнуть» на расчётах.
func _queue_ai_step(ctrl: PlayerController) -> void:
	await get_tree().create_timer(AI_STEP_DELAY).timeout
	# За время паузы ход мог смениться (сдача хода, загрузка, конец боя).
	if is_inside_tree() and state != null and state.active_player() == ctrl.owner:
		ctrl.begin_turn(state)

func _after_action() -> void:
	_refresh_status()
	# Цепочка действий машины: переоткрыть её меню, пока она жива.
	if selected_vehicle_id != -1:
		var veh := _selected_vehicle()
		if veh != null and veh.alive() and _can_control(veh.owner):
			_select_vehicle(veh)
		else:
			_deselect()
		return
	var u := _selected_unit()
	# Копка окопов подряд (#16): пока есть кредит/ОД и куда копать — остаёмся в режиме
	# DIG, не отвлекая игрока меню. Иначе — обычная цепочка действий через меню.
	if mode == Mode.DIG and _is_own_active(u) and (u.remaining_ap > 0 or u.dig_credits > 0) \
			and not resolver.diggable_cells(u).is_empty():
		_enter_dig()
		return
	if _is_own_active(u) and (u.remaining_ap > 0 or _valid_pending_shoot(u) or u.dig_credits > 0 or u.move_credit > 0):
		_select(u)  # переоткрываем меню для цепочки действий
	else:
		_deselect()

func _on_net_applied(_intent: Intent, result: ActionResult) -> void:
	_menu.hide()
	_picker.hide()
	if not result.ok:
		state.log.add("[denied] " + result.reason)
		_after_action()
		return
	if not result.dice_events.is_empty():
		# Убитых мирными держим на карте живыми до конца анимации (#46, #96): передача
		# хода везёт с собой весь слот жителей, и без этого трупы легли бы разом,
		# ещё до первого кубика.
		_pending_death_ids.clear()
		for id: int in result.deaths:
			_pending_death_ids[id] = true
		queue_redraw()
		await _play_dice(result.dice_events)
		_pending_death_ids.clear()
	state.log.publish_result(result)
	_refresh_status()
	queue_redraw()
	_after_action()

## Подхватить связь, налаженную во вкладке Multiplayer главного меню (#54).
## Своих кнопок Host/Join у боя больше нет: сюда приезжает уже готовая сессия.
## Пакеты, пришедшие пока сцена строилась, лежат в буфере сессии — attach() их отдаёт.
func _adopt_network() -> void:
	var s := NetHandoff.take()
	if s == null:
		return
	session = s
	session.message.connect(_on_net_message)
	session.disconnected.connect(_on_net_disconnected)
	_on_peer_ready(NetHandoff.is_host)
	session.attach()

func _on_peer_ready(is_host: bool) -> void:
	networked = true
	my_owner = MCF.Owner.PLAYER_1 if is_host else MCF.Owner.PLAYER_2
	net = NetGame.new(state, resolver, is_host)
	net.outgoing.connect(func(msg: Dictionary) -> void: session.send(msg))
	net.action_applied.connect(_on_net_applied)
	net.initiative_synced.connect(_on_initiative_synced)
	# Порядок инициативы бросается локально у каждой стороны, поэтому хост тут же
	# объявляет свой — он и есть авторитетный (#53).
	net.announce_initiative()
	_setup_network_controllers()
	_deselect()
	if _net_status != null:
		_net_status.text = "Network: you are %s — your army is blue, the enemy red" % [
			"Player A (host)" if is_host else "Player B (joined)"]
		_net_status.show()
	_refresh_status()

## Порядок инициативы согласован (#53, #19). Сам ход мирных уже отыгран внутри
## NetGame — одинаково у обеих сторон; здесь только показываем итог.
func _on_initiative_synced() -> void:
	state.log.add("— Initiative this match: %s —" % _order_labels())
	_refresh_status()
	queue_redraw()
	await _play_civilian_result(net.opening_civilians)
	queue_redraw()

func _on_net_message(msg: Dictionary) -> void:
	if net != null:
		net.receive(msg)

func _on_net_disconnected() -> void:
	if _net_status != null:
		_net_status.text = "Connection lost"
	networked = false
	net = null

func _setup_network_controllers() -> void:
	for c in controllers.values():
		if c.is_local_human() and c.intent_ready.is_connected(_on_intent_ready):
			c.intent_ready.disconnect(_on_intent_ready)
	controllers.clear()
	var mine := LocalHumanController.new(my_owner)
	mine.intent_ready.connect(_on_intent_ready)
	controllers[my_owner] = mine
	var remote: int = MCF.Owner.PLAYER_2 if my_owner == MCF.Owner.PLAYER_1 else MCF.Owner.PLAYER_1
	controllers[remote] = NetworkController.new(remote)

const DEFENSE_PROMPT := "You are under attack — click Roll to defend"
const RESIST_PROMPT := "You are grabbed — click Roll to resist"

## Проиграть все броски результата по одному. Броски попадания идут автоматически,
## броски защиты ждут ручного нажатия «Roll» защищающимся игроком (§3.5).
func _play_dice(events: Array) -> void:
	_animating = true
	# Точки ОД отматываем к тому, что было ДО хода: дальше события гасят их по одной.
	for ev in events:
		if ev.get("kind", "") == "ap" and not _ap_display.has(int(ev["unit"])):
			_ap_display[int(ev["unit"])] = int(ev["from"])
	queue_redraw()  # (состояние уже применено; кадр обновится после анимации)
	for ev in events:
		if ev.get("kind", "") == "focus":
			# Слот мирных отыгрывается сам и где угодно на карте (#103): если очередной
			# житель за краем экрана, подводим к нему камеру — иначе игрок смотрит на
			# кубики, не понимая, чьи они.
			_ensure_visible(ev.get("coord", Vector2i.ZERO))
			continue
		if ev.get("kind", "") == "walk":
			await _play_walk(ev)
			continue
		if ev.get("kind", "") == "ap":
			_ap_display[int(ev["unit"])] = int(ev["left"])
			queue_redraw()
			await get_tree().create_timer(AP_DOT_DELAY).timeout
			continue
		for step in _dice_steps(ev):
			# Ручной бросок ждёт нажатия только у защитника-человека; мирные (NEUTRAL)
			# и ИИ кидают защиту автоматически, но анимация всё равно видна (#64).
			_dice.play(step["faces"], step["manual"], step["prompt"], step.get("speed", 1.0))
			await _dice.finished
	_walk_cells.clear()
	_ap_display.clear()
	_animating = false
	queue_redraw()

## Проиграть один пеший переход по клеткам (#96). Юнит УЖЕ стоит в конце маршрута —
## отматываем его отрисовку к старту и ведём по пути, чтобы игрок увидел, откуда и
## куда пришёл житель, а не обнаружил его вплотную к своему отряду.
func _play_walk(ev: Dictionary) -> void:
	var id := int(ev["unit"])
	_walk_cells[id] = ev["from"]
	queue_redraw()
	for cell: Vector2i in ev["path"]:
		await get_tree().create_timer(WALK_STEP_DELAY).timeout
		_walk_cells[id] = cell
		queue_redraw()
	_walk_cells.erase(id)

## Клетка, на которой юнит рисуется ПРЯМО СЕЙЧАС: обычно его настоящая координата,
## а во время проигрывания перехода — промежуточная клетка маршрута.
func _draw_cell(unit: UnitInstance) -> Vector2i:
	return _walk_cells.get(unit.id, unit.coord)

## Сколько точек ОД показать сейчас: обычно настоящий остаток, а во время чужой
## анимации — то, что уже отыграно (#99).
func _draw_ap(unit: UnitInstance) -> int:
	return int(_ap_display.get(unit.id, unit.remaining_ap))

## Юнит этого владельца управляется локальным человеком (значит, его броски защиты
## ждут ручного нажатия)? Мирные (NEUTRAL) и ИИ — нет: у них нет контроллера-человека.
func _owner_is_local_human(owner_id: int) -> bool:
	# В сетевой игре бросок защиты кидает ТОТ, КОГО бьют, на своём экране (#93).
	# Исход уже определён (у клиента броски подставные), кнопка — только жест игрока,
	# поэтому рассинхрона не будет, а у противника кубик крутится сам.
	if networked:
		return owner_id == my_owner
	var ctrl: PlayerController = controllers.get(owner_id)
	return ctrl != null and ctrl.is_local_human()

## Разбить событие бросков на отдельные шаги: {faces, manual, prompt}.
## Каждый шаг — один кубик, чтобы попадание и пробитие крутились по очереди.
func _dice_steps(ev: Dictionary) -> Array:
	var steps: Array = []
	match ev["kind"]:
		"attack":
			# Сначала ВСЕ броски попадания разом, затем ВСЕ броски пробитии разом (§3.5).
			var hit_faces: Array = []
			var pen_faces: Array = []
			for det in ev["shots"]:
				hit_faces.append(
					{"value": det["hit_roll"], "good": det["hit"], "tag": "Hit %d+" % det["need"]})
				if det["hit"]:
					pen_faces.append(
						{"value": det["def_roll"], "good": not det["parried"], "tag": "Pen %d+" % det["armor"]})
			# Разбивка бонусов/штрафов к попаданию и защите (#49): показываем в подсказке.
			var hit_note := _mods_text("To-hit", ev.get("hit_mods", []))
			steps.append({"faces": hit_faces, "manual": false, "prompt": hit_note,
				"speed": _roll_speed(ev["shots"], "need")})
			if not pen_faces.is_empty():
				var def_note := _mods_text("Defence", ev.get("def_mods", []))
				var prompt: String = DEFENSE_PROMPT
				if def_note != "":
					prompt = def_note + "\n" + DEFENSE_PROMPT
				var manual := _owner_is_local_human(ev.get("def_owner", MCF.Owner.NEUTRAL))
				steps.append({"faces": pen_faces, "manual": manual, "prompt": prompt})
		"opposed":
			steps.append(_step({"value": ev["a_roll"], "good": ev["attacker_wins"], "tag": "Grab"}))
			steps.append(_step(
				{"value": ev["d_roll"], "good": not ev["attacker_wins"], "tag": "Def"},
				_owner_is_local_human(ev.get("def_owner", MCF.Owner.NEUTRAL)), RESIST_PROMPT))
		"check":
			var chk := _step({"value": ev["roll"], "good": ev["ok"], "tag": "%d+" % ev["need"]})
			chk["speed"] = FAST_ROLL_SPEED if int(ev["need"]) <= 1 else 1.0
			steps.append(chk)
		"grenade":
			# Все броски защиты по осколкам — одним общим броском (§3.6).
			var frag_faces: Array = []
			for det in ev["targets"]:
				if det["epicenter"] and det["rolls"].is_empty():
					continue  # эпицентр: автосмерть без броска
				for r in det["rolls"]:
					frag_faces.append(
						{"value": r, "good": r >= det["need"], "tag": "R%d+" % det["need"]})
			if not frag_faces.is_empty():
				# Ручной бросок — только если под осколки попал юнит-человек; если это
				# лишь мирные/ИИ, защита катится сама (но видна).
				var manual := false
				for det in ev["targets"]:
					if _owner_is_local_human(det.get("owner", MCF.Owner.NEUTRAL)):
						manual = true
						break
				steps.append({"faces": frag_faces, "manual": manual, "prompt": DEFENSE_PROMPT})
	return steps

func _step(face: Dictionary, manual: bool = false, prompt: String = "") -> Dictionary:
	return {"faces": [face], "manual": manual, "prompt": prompt}

## Гарантированный бросок (нужно 1+) крутится вдвое быстрее — незачем тянуть (#46).
const FAST_ROLL_SPEED := 2.0

func _roll_speed(entries: Array, key: String) -> float:
	if entries.is_empty():
		return 1.0
	for e in entries:
		if int(e.get(key, 7)) > 1:
			return 1.0
	return FAST_ROLL_SPEED

## Человекочитаемая строка со всеми бонусами/штрафами броска (#49). Пусто — если нет.
## delta 0 = особый эффект (авто-попадание, иммунитет щита) без числа.
func _mods_text(header: String, mods: Array) -> String:
	if mods.is_empty():
		return ""
	var parts: Array[String] = []
	for m in mods:
		var d: int = m.get("delta", 0)
		if d == 0:
			parts.append(str(m.get("label", "")))
		else:
			parts.append("%s %+d" % [m.get("label", ""), d])
	return "%s: %s" % [header, ", ".join(parts)]

# --- Геометрия ---
## ЛОКАЛЬНЫЕ координаты клетки (до pan/zoom). В _draw применяется
## draw_set_transform(pan, 0, zoom), который и добавляет панораму с масштабом.
func _cell_origin(coord: Vector2i) -> Vector2:
	return ORIGIN + Vector2(coord.x * CELL, coord.y * CELL)

## ЭКРАННЫЕ координаты угла клетки (с учётом pan/zoom) — для UI-попапов на
## CanvasLayer, который не участвует в трансформе рисования.
func _cell_screen(coord: Vector2i) -> Vector2:
	return pan + zoom * _cell_origin(coord)

func _pos_to_cell(pos: Vector2) -> Vector2i:
	var local := (pos - pan) / zoom - ORIGIN
	return Vector2i(floori(local.x / CELL), floori(local.y / CELL))

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

func _draw_move_preview() -> void:
	var font := ThemeDB.fallback_font
	var cvec := Vector2(CELL, CELL)
	var half := cvec * 0.5
	var hover := _pos_to_cell(get_global_mouse_position())
	# Путь считаем ОДИН раз и держим множеством: подсветка маршрута идёт внутри общего
	# прохода по клеткам, а искать в массиве на каждую клетку — квадрат.
	var on_path: Dictionary = {}
	var path: Array[Vector2i] = []
	if reach.can_reach(hover):
		path = reach.path_to(hover)
		for p: Vector2i in path:
			on_path[p] = true
	var labels: bool = zoom >= MOVE_LABEL_MIN_ZOOM
	var budget_txt := "/%d" % reach_budget
	for coord: Vector2i in reach.cost:
		var origin := _cell_origin(coord)
		var lit: bool = on_path.has(coord)
		draw_rect(Rect2(origin, cvec),
			Color(0.45, 1.0, 0.55, 0.42) if lit else Color(0.3, 0.8, 0.4, 0.28))
		if not labels:
			continue
		var spent: int = reach.cost[coord]
		draw_string(font, origin + Vector2(4, 13), str(spent) + budget_txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			Color(0.92, 1.0, 0.92) if lit else Color(0.75, 0.9, 0.78, 0.85))
	# Сам маршрут поверх заливки: ломаная от бойца через каждую клетку пути.
	if path.is_empty():
		return
	var u := _selected_unit()
	if u == null:
		return
	var pts := PackedVector2Array()
	pts.append(_cell_origin(u.coord) + half)
	for p: Vector2i in path:
		pts.append(_cell_origin(p) + half)
	draw_polyline(pts, Color(0.05, 0.25, 0.1, 0.65), 5.0)
	draw_polyline(pts, Color(0.6, 1.0, 0.7, 0.95), 2.5)
	for i in range(1, pts.size()):
		draw_circle(pts[i], CELL * 0.09, Color(0.7, 1.0, 0.8, 0.9))
	# Финиш — кольцо и итоговая цена крупнее, её игрок и ищет глазами.
	var last: Vector2 = pts[pts.size() - 1]
	draw_arc(last, CELL * 0.36, 0.0, TAU, 24, Color(0.6, 1.0, 0.7, 0.95), 2.0)
	if labels:
		var total: int = reach.cost[hover]
		var txt := "%d/%d" % [total, reach_budget]
		draw_string(ThemeDB.fallback_font, last + Vector2(-CELL * 0.5, -CELL * 0.42), txt,
			HORIZONTAL_ALIGNMENT_CENTER, CELL, 13, Color(0.1, 0.2, 0.1))
		draw_string(ThemeDB.fallback_font, last + Vector2(-CELL * 0.5, -CELL * 0.45), txt,
			HORIZONTAL_ALIGNMENT_CENTER, CELL, 13, Color(0.75, 1.0, 0.85))

## Клетки, которые накроет струя огнемёта из from к цели (для предпросмотра). Идёт
## единичными шагами в направлении цели, максимум 6 клеток, останавливается на стене.
func _flame_jet_preview(from_coord: Vector2i, toward: Vector2i) -> Array:
	var out: Array = []
	var d := toward - from_coord
	var step := Vector2i(signi(d.x), signi(d.y))
	if step == Vector2i.ZERO:
		return out
	var cur := from_coord + step
	for _i in MCF.FLAME_JET_LENGTH:
		if not state.grid.in_bounds(cur):
			break
		out.append(cur)
		if state.grid.cell(cur).is_wall():
			break
		cur += step
	return out

## Подвести камеру к клетке, если она вне экрана (#103). Масштаб не трогаем: игрок сам
## выбрал, насколько близко смотрит, и менять это за него — потерять его точку обзора.
func _ensure_visible(coord: Vector2i) -> void:
	var view := get_viewport_rect().size
	var centre := _cell_origin(coord) + Vector2(CELL, CELL) * 0.5
	var p := pan + zoom * centre
	var margin: float = minf(CELL * zoom * 2.0, minf(view.x, view.y) * 0.25)
	if p.x >= margin and p.y >= margin and p.x <= view.x - margin and p.y <= view.y - margin:
		return
	pan = view * 0.5 - zoom * centre
	queue_redraw()

## Возврат камеры к исходному виду (#74). На большой карте (город 50×50) легко
## укатиться за край и потерять из виду собственные войска — кнопка сбрасывает
## масштаб и ставит в центр экрана то, ради чего игрок туда смотрит: свою армию.
func _recenter_camera() -> void:
	# Масштаб 1:1 берётся только если карта при нём на экран влезает. На поле 60×40
	# это 2400×1600 px — больше любого окна, и «возврат камеры» возвращал игрока в
	# точно такую же слепоту, из которой он и нажал кнопку. Поэтому отъезжаем ровно
	# настолько, чтобы поле поместилось целиком, и не ближе 1:1.
	var view := get_viewport_rect().size
	var board := Vector2(state.grid.width * CELL, state.grid.height * CELL) \
			+ ORIGIN * 2.0
	var fit: float = minf(view.x / board.x, view.y / board.y)
	zoom = clampf(minf(1.0, fit), ZOOM_MIN, ZOOM_MAX)
	var focus := _home_focus()
	var centre := _cell_origin(focus) + Vector2(CELL, CELL) * 0.5
	pan = view * 0.5 - zoom * centre
	queue_redraw()

## Клетка, на которую смотрит камера «по умолчанию»: середина своих войск на поле,
## а если их не осталось — середина карты.
func _home_focus() -> Vector2i:
	var side: int = my_owner if networked else state.active_player()
	var sum := Vector2i.ZERO
	var n := 0
	for u in state.all_units():
		if u.owner == side and u.is_on_field() and u.aboard_vehicle_id == -1:
			sum += u.coord
			n += 1
	for veh: Vehicle in state.all_vehicles():
		if veh.owner == side and veh.alive():
			sum += veh.center()
			n += 1
	if n == 0:
		return Vector2i(state.grid.width / 2, state.grid.height / 2)
	return Vector2i(sum.x / n, sum.y / n)

## Масштабирование вокруг точки экрана (клетка под курсором остаётся на месте).
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var new_zoom: float = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_zoom, zoom):
		return
	var local := (screen_pos - pan) / zoom
	zoom = new_zoom
	pan = screen_pos - local * zoom
	queue_redraw()

# --- Рендер ---
func _draw() -> void:
	if state == null:
		return
	# Панорама + масштаб «камеры»: всё поле рисуется в локальных координатах.
	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	var font := ThemeDB.fallback_font
	# Множество видимых клеток нужно и дальше по функции (юниты, трупы, техника), поэтому
	# берётся всегда — резолвер отдаёт его из кеша, пока обстановка не изменилась.
	# А вот САМА заливка тумана при выключенном тумане не нужна ни на одной клетке:
	# флаг гасит 2500 лишних обращений к словарю за кадр.
	var fog_on: bool = resolver.fog_enabled
	var visible := resolver.team_visible_coords(state.active_player())
	# Локальные копии полей и констант: тело цикла выполняется до 2500 раз за кадр,
	# и каждое обращение к свойству узла/автозагрузки там заметно.
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	var csize := Vector2(CELL, CELL)
	var grid_col := Color(0.25, 0.27, 0.32)
	var fog_col := Color(0.02, 0.02, 0.04, 0.55)
	var label_off := Vector2(6, CELL - 4)
	for y in gh:
		var oy: float = ORIGIN.y + y * CELL
		for x in gw:
			var cell := grid.cell_fast(x, y)
			var origin := Vector2(ORIGIN.x + x * CELL, oy)
			var rect := Rect2(origin, csize)
			var is_wall := cell.cover_height >= MCF.WALL_HEIGHT
			# Пол: сначала картинка-замена, и только если её нет — заливка цветом (#55).
			var floor_name := "floor"
			if cell.is_space:
				floor_name = "floor_space"
			elif is_wall:
				floor_name = "floor_wall"
			if not Sprites.draw_texture_override_rect(self, floor_name, rect):
				var base_col := Color(0.14, 0.15, 0.18)
				if cell.is_space:
					base_col = Color(0.03, 0.02, 0.08)
				if is_wall:
					base_col = Color(0.35, 0.3, 0.25)
				draw_rect(rect, base_col)
			var h: float = cell.cover_height
			# Низкое укрытие: тон тем ярче, чем выше (§3.7).
			if h > 0.0 and not is_wall:
				if not Sprites.draw_texture_override_rect(self, "floor_cover", rect):
					draw_rect(rect, Color(0.5, 0.45, 0.2, 0.12 + 0.12 * h))
			if cell.on_fire:
				if not Sprites.draw_texture_override_rect(self, "fire", rect):
					draw_rect(rect, Color(1.0, 0.4, 0.05, 0.4))
			# Насыпь земли (§3.10): подпись высоты в клетке. Подписей всего пять штук,
			# поэтому строка берётся из таблицы, а не форматируется заново каждый кадр.
			if h > 0.0:
				draw_string(font, origin + label_off, HEIGHT_LABELS.get(h, "%.1fm" % h),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.9, 0.78, 0.5))
			draw_rect(rect, grid_col, false, 1.0)
			if fog_on and not visible.has(Vector2i(x, y)):
				draw_rect(rect, fog_col)

	if mode == Mode.MOVE and reach != null:
		_draw_move_preview()

	# Групповое движение (#88): зелёным — куда группа вообще дотягивается, а под
	# курсором жёлтыми кружками — куда конкретно встанет каждый выделенный юнит.
	if mode == Mode.GROUP_MOVE:
		for coord: Vector2i in _group_reach_cells():
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.3, 0.8, 0.4, 0.24))
		var ghov := _pos_to_cell(get_global_mouse_position())
		if state.grid.in_bounds(ghov):
			draw_rect(Rect2(_cell_origin(ghov), Vector2(CELL, CELL)), Color(0.95, 0.85, 0.2, 0.20))
			var half := Vector2(CELL, CELL) * 0.5
			for spot: Vector2i in _group_move_preview(ghov):
				var c := _cell_origin(spot) + half
				draw_circle(c, CELL * 0.18, Color(1.0, 0.9, 0.25, 0.85))
				draw_arc(c, CELL * 0.18, 0.0, TAU, 16, Color(0.4, 0.35, 0.05, 0.9), 1.5)

	if mode == Mode.SHOOT or mode == Mode.RSP_FIRE:
		if mode == Mode.RSP_FIRE and rsp_active != Vector2i(-1, -1):
			draw_rect(Rect2(_cell_origin(rsp_active), Vector2(CELL, CELL)), Color(1, 0.5, 0.2, 0.30))
		# Клетки пола под спецудар (противотанкист — взрыв, огнемётчик — струя).
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.9, 0.5, 0.1, 0.16))
		var shov := _pos_to_cell(get_global_mouse_position())
		var su := _selected_unit()
		# Марксманн (#49): под курсором рисуем сам луч — куда он долетит и кого заденет.
		if mode == Mode.SHOOT and _is_marksman(su) and state.grid.in_bounds(shov):
			_draw_laser_preview(su, shov)
		if item_cells.has(shov) and su != null:
			if su.stats.special_ability_id == MCF.ABILITY_FLAMETHROWER:
				# Предпросмотр струи 6×1 в направлении наведённой клетки.
				for jc in _flame_jet_preview(su.coord, shov):
					draw_rect(Rect2(_cell_origin(jc), Vector2(CELL, CELL)), Color(1, 0.4, 0.05, 0.34))
			else:
				# Предпросмотр радиуса взрыва (3x3) вокруг наведённой клетки.
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var bc := Vector2i(shov.x + dx, shov.y + dy)
						if state.grid.in_bounds(bc):
							draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(1, 0.35, 0.1, 0.32))
		for tid in target_ids:
			var t := state.get_unit(tid)
			if t != null:
				var c := _cell_origin(t.coord) + Vector2(CELL, CELL) * 0.5
				draw_arc(c, CELL * 0.46, 0, TAU, 28, Color(1, 0.3, 0.3), 2.5)
				draw_line(c - Vector2(CELL * 0.5, 0), c + Vector2(CELL * 0.5, 0), Color(1, 0.3, 0.3, 0.7), 1.5)
				draw_line(c - Vector2(0, CELL * 0.5), c + Vector2(0, CELL * 0.5), Color(1, 0.3, 0.3, 0.7), 1.5)

	if mode == Mode.GRAB:
		# Бойцы под захват — оранжевые круги; объекты (труп/мешки/ёж/куча) — жёлтые клетки,
		# после выбора объекта те же клетки показывают, куда его можно оттащить (#50).
		if drag_object == Vector2i(-1, -1):
			for tid in target_ids:
				var t := state.get_unit(tid)
				if t != null:
					var c := _cell_origin(t.coord) + Vector2(CELL, CELL) * 0.5
					draw_arc(c, CELL * 0.46, 0, TAU, 28, Color(1, 0.7, 0.2), 2.5)
		var grab_col := Color(0.9, 0.8, 0.2, 0.28) if drag_object == Vector2i(-1, -1) \
			else Color(0.3, 0.8, 0.4, 0.28)
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), grab_col)
		if drag_object != Vector2i(-1, -1):
			draw_rect(Rect2(_cell_origin(drag_object), Vector2(CELL, CELL)), Color(0.9, 0.8, 0.2, 0.40))

	if mode == Mode.PUSH:
		for tid in target_ids:
			var t := state.get_unit(tid)
			if t != null:
				var c := _cell_origin(t.coord) + Vector2(CELL, CELL) * 0.5
				draw_arc(c, CELL * 0.46, 0, TAU, 28, Color(0.4, 0.7, 1.0), 2.5)

	if mode == Mode.ITEM:
		var hover := _pos_to_cell(get_global_mouse_position())
		var is_station: bool = _selected_unit() != null and _selected_unit().held_item_id == MCF.ITEM_DRONE_STATION
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.9, 0.5, 0.1, 0.16))
		if item_cells.has(hover) and not is_station:
			# Предпросмотр зоны взрыва вокруг наведённой клетки (#64): у осколочной и
			# у пожаротушительной это «косой крест», а не квадрат 3×3. Форму берём у
			# резолвера, чтобы подсветка и сам взрыв не могли разойтись.
			var iu := _selected_unit()
			var iid: String = iu.held_item_id if iu != null else MCF.ITEM_FRAG
			for bc: Vector2i in resolver.blast_cells_for_item(iid, hover):
				if state.grid.in_bounds(bc):
					draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(1, 0.35, 0.1, 0.32))

	if mode == Mode.DRONE_FLY:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.3, 0.9, 0.9, 0.18))

	if mode == Mode.BUILD:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.3, 0.8, 0.4, 0.28))

	if mode == Mode.BUILD_WALL:
		# Уже выложенные звенья цепочки (сплошной зелёный) с номерами.
		for i in _wall_cells.size():
			var wc: Vector2i = _wall_cells[i]
			draw_rect(Rect2(_cell_origin(wc), Vector2(CELL, CELL)), Color(0.3, 0.85, 0.45, 0.55))
			draw_string(font, _cell_origin(wc) + Vector2(6, 16), str(i + 1),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.05, 0.15, 0.05))
		# Пока не выложено ни одного звена — подсвечиваем кольцо клеток у инженера
		# (единственная обязательная привязка). Дальше звенья ставятся куда угодно,
		# поэтому весь пол не красим — вместо этого показываем предпросмотр под курсором.
		if _wall_cells.size() < MCF.BRU_WALL_LENGTH:
			var hov := _pos_to_cell(get_global_mouse_position())
			if _wall_cells.is_empty():
				for coord in item_cells:
					if _wall_valid_next(coord):
						var col := Color(0.9, 0.85, 0.3, 0.35) if coord == hov else Color(0.3, 0.8, 0.4, 0.16)
						draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), col)
			# Предпросмотр клетки под курсором: зелёная — можно поставить, красная — нельзя.
			if state.grid.in_bounds(hov) and not _wall_cells.has(hov):
				var ok := _wall_valid_next(hov)
				draw_rect(Rect2(_cell_origin(hov), Vector2(CELL, CELL)),
					Color(0.3, 0.85, 0.45, 0.42) if ok else Color(0.9, 0.3, 0.2, 0.32))

	if mode == Mode.BREAK:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.9, 0.3, 0.2, 0.30))

	if mode == Mode.DIG:
		var dhov := _pos_to_cell(get_global_mouse_position())
		if dig_trench == Vector2i(-1, -1):
			# Шаг 1: клетки под окоп (коричневый).
			for coord in item_cells:
				draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.6, 0.45, 0.2, 0.32))
			if item_cells.has(dhov):
				draw_rect(Rect2(_cell_origin(dhov), Vector2(CELL, CELL)), Color(0.75, 0.55, 0.25, 0.5))
		else:
			# Шаги 2–3: выбранный окоп (тёмный) + места под кучи вынутой земли (песочный).
			draw_rect(Rect2(_cell_origin(dig_trench), Vector2(CELL, CELL)), Color(0.45, 0.32, 0.15, 0.55))
			for coord in item_cells:
				draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.85, 0.7, 0.35, 0.30))
			if dig_dirt_a != Vector2i(-1, -1):
				draw_rect(Rect2(_cell_origin(dig_dirt_a), Vector2(CELL, CELL)), Color(0.9, 0.75, 0.3, 0.55))
			if item_cells.has(dhov):
				draw_rect(Rect2(_cell_origin(dhov), Vector2(CELL, CELL)), Color(0.95, 0.8, 0.4, 0.5))

	if mode == Mode.CARRY_DROP:
		# Цель переноса (синий) и свободные клетки под пленника (голубой).
		if move_dest != Vector2i(-1, -1):
			draw_rect(Rect2(_cell_origin(move_dest), Vector2(CELL, CELL)), Color(0.3, 0.5, 0.9, 0.30))
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.4, 0.7, 1.0, 0.28))

	if mode == Mode.CORPSE_DROP:
		# Клетки под труп — в цвет самого трупа (#59), чтобы связь читалась сразу.
		var chov_c := _pos_to_cell(get_global_mouse_position())
		for coord: Vector2i in item_cells:
			var tint := Color(CORPSE_COLOR, 0.55) if coord == chov_c else Color(CORPSE_COLOR, 0.28)
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), tint)

	if mode == Mode.MOVE_HELD:
		# Куда можно переставить пленника (#100) — тот же голубой, что у сброса переноса.
		var mhov := _pos_to_cell(get_global_mouse_position())
		for coord: Vector2i in item_cells:
			var mt := Color(0.4, 0.7, 1.0, 0.55) if coord == mhov else Color(0.4, 0.7, 1.0, 0.28)
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), mt)

	if mode == Mode.WELD:
		# Шлюзы под заварку — в цвет сварочной дуги (#99).
		var whov := _pos_to_cell(get_global_mouse_position())
		for coord: Vector2i in item_cells:
			var wt := Color(1.0, 0.65, 0.2, 0.55) if coord == whov else Color(1.0, 0.65, 0.2, 0.28)
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), wt)

	if mode == Mode.VEH_MOVE:
		for coord: Vector2i in veh_move_targets.keys():
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.3, 0.8, 0.9, 0.30))

	if mode == Mode.VEH_TURN:
		var vt := _selected_vehicle()
		if vt != null:
			var vc := _cell_origin(vt.center()) + Vector2(CELL, CELL) * 0.5
			draw_arc(vc, CELL * 1.1, 0, TAU, 40, Color(0.9, 0.8, 0.3, 0.6), 2.0)
			# Восемь стрелок = восемь выбираемых направлений (#39). Клик в любую клетку
			# по этому лучу поворачивает корпус туда.
			var thov := _pos_to_cell(get_global_mouse_position())
			var thd := thov - vt.center()
			var thdir := Vector2i(signi(thd.x), signi(thd.y))
			for d: Vector2i in GameActionResolver.DIR8:
				var v := Vector2(d).normalized()
				var col := Color(0.55, 0.5, 0.35, 0.7)
				if d == vt.facing:
					col = Color(0.4, 0.9, 0.5, 0.9)
				elif d == thdir:
					col = Color(1.0, 0.9, 0.35, 1.0)
				var tip := vc + v * (CELL * 1.7)
				draw_line(vc + v * (CELL * 1.15), tip, col, 2.0)
				var perp := Vector2(-v.y, v.x) * (CELL * 0.16)
				draw_colored_polygon(PackedVector2Array([
					tip, tip - v * (CELL * 0.3) + perp, tip - v * (CELL * 0.3) - perp]), col)

	if mode == Mode.VEH_CANNON:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(1, 0.4, 0.1, 0.18))
		var chov := _pos_to_cell(get_global_mouse_position())
		var cveh_sel := _selected_vehicle()
		if item_cells.has(chov) and cveh_sel != null:
			# Предпросмотр берём у резолвера — ромб радиуса 2 (#63), а не квадрат 3×3.
			for bc: Vector2i in resolver.cannon_blast_cells(cveh_sel, chov):
				if state.grid.in_bounds(bc):
					draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(1, 0.35, 0.1, 0.32))

	if mode == Mode.VEH_DISEMBARK:
		for coord in item_cells:
			draw_rect(Rect2(_cell_origin(coord), Vector2(CELL, CELL)), Color(0.4, 0.7, 1.0, 0.28))

	# Статические объекты на клетках (станции дронов и т. п.).
	for y in gh:
		var foy: float = ORIGIN.y + y * CELL
		for x in gw:
			var fcell := grid.cell_fast(x, y)
			if fcell.feature_id == "":
				continue
			var o := Vector2(ORIGIN.x + x * CELL, foy)
			# Имя картинки совпадает с id объекта (sandbags.png, trench.png...) (#55).
			if Sprites.draw_texture_override(self, fcell.feature_id, o, float(CELL)):
				continue
			var tag: String = FEATURE_TAGS.get(fcell.feature_id, "?")
			# БРУ — чёрный монолит (#85): заливка, а не контур, чтобы отличался от бетона.
			if fcell.feature_id == MCF.FEATURE_BRU:
				draw_rect(Rect2(o + Vector2(3, 3), Vector2(CELL - 6, CELL - 6)), BRU_COLOR)
				draw_rect(Rect2(o + Vector2(3, 3), Vector2(CELL - 6, CELL - 6)),
					Color(0.35, 0.35, 0.4), false, 1.0)
				draw_string(font, o + Vector2(6, CELL - 15), tag,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.8, 0.8, 0.85))
				continue
			draw_rect(Rect2(o + Vector2(8, 8), Vector2(CELL - 16, CELL - 16)),
				Color(0.6, 0.6, 0.7), false, 2.0)
			# Тег стоит СТРОКОЙ ВЫШЕ подписи высоты, чтобы они не наезжали друг на друга (#35).
			draw_string(font, o + Vector2(6, CELL - 15), tag,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.75, 0.85))
			# Треснувший ДОТ (потеряна прочность) — красная риска в углу (#89).
			if fcell.feature_durability > 0 and fcell.feature_durability < MCF.feature_durability(fcell.feature_id):
				draw_line(o + Vector2(CELL - 12, 8), o + Vector2(CELL - 6, 16),
					Color(0.9, 0.25, 0.2), 2.0)

	# Трупы идут ОТДЕЛЬНЫМ проходом до корпусов машин (#59): танк наезжает на тело,
	# а не тело лежит поверх брони. Смерти, ещё не показанные из-за анимации броска
	# (#46), рисуются как живые в общем проходе ниже.
	#
	# Труп существует в ДВУХ видах: погибший на месте боец — это occupant клетки со
	# статусом CORPSE, а положенный из рук (#6) — безымянная куча cell.corpse_count.
	# Кучи не рисовались вовсе: тело давало +1 к защите, но на карте его не было.
	for unit: UnitInstance in state.all_units():
		if unit.aboard_vehicle_id != -1:
			continue
		if unit.status != MCF.Status.CORPSE or _pending_death_ids.has(unit.id):
			continue
		if unit.owner != state.active_player() and not visible.has(unit.coord):
			continue
		# Раздавленный гусеницами труп вычищается из клетки (occupant = null), но сам
		# UnitInstance остаётся в списке — без этой проверки он всплывал бы призраком.
		if state.grid.cell(unit.coord) == null or state.grid.cell(unit.coord).occupant != unit:
			continue
		# На клетке может лежать и куча — тогда её рисует проход ниже, одним стеком с
		# общим числом (#98). Без этого два вида трупа накладывались друг на друга и
		# счётчик врал: сверху «x2», а под ним ещё один невидимый труп-occupant.
		if state.grid.cell(unit.coord).corpse_count > 0:
			continue
		_draw_corpse(unit.coord, 1)

	for cy in state.grid.height:
		for cx in state.grid.width:
			var pile_coord := Vector2i(cx, cy)
			var pile_cell := state.grid.cell(pile_coord)
			if pile_cell == null or pile_cell.corpse_count <= 0:
				continue
			if not visible.has(pile_coord):
				continue
			# Павший на месте боец — такое же тело в стеке. Пока его смерть не доиграна
			# (#46), он показан живым, поэтому в счёт стека не идёт.
			var stack := pile_cell.corpse_count
			var pile_occ: UnitInstance = pile_cell.occupant
			if pile_occ != null and pile_occ.status == MCF.Status.CORPSE \
					and not _pending_death_ids.has(pile_occ.id):
				stack += 1
			_draw_corpse(pile_coord, stack)

	# Корпуса машин (§техника): прямоугольник по всему следу, цвет владельца.
	for veh: Vehicle in state.all_vehicles():
		var fp := veh.footprint()
		var vseen := false
		for fc in fp:
			if visible.has(fc):
				vseen = true
				break
		if not vseen:
			continue
		var org := _cell_origin(veh.origin)
		var vsize := Vector2(veh.size.x * CELL, veh.size.y * CELL)
		var hull := Rect2(org + Vector2(3, 3), vsize - Vector2(6, 6))
		var hull_col: Color = _side_color(veh.owner)
		if veh.wrecked:
			hull_col = Color(0.3, 0.3, 0.32)
		var vcenter := org + vsize * 0.5
		# Картинка машины растягивается на весь след и поворачивается по фронту (#55).
		var veh_name := (veh.type_id + "_wreck") if veh.wrecked else veh.type_id
		var veh_key := Sprites.resolve(veh_name)
		if veh_key == "" and veh.wrecked:
			veh_key = Sprites.resolve(veh.type_id)
		if veh_key != "":
			Sprites.draw_texture_override_rect(self, veh_key, Rect2(org, vsize),
				_facing_degrees(veh.facing))
		else:
			draw_rect(hull, hull_col.darkened(0.35))
			draw_rect(hull, hull_col, false, 3.0)
			# Направление (стрелка фронта) — у танка.
			if veh.facing != Vector2i.ZERO and not veh.wrecked:
				var dir := Vector2(veh.facing.x, veh.facing.y).normalized()
				draw_line(vcenter, vcenter + dir * (CELL * 0.6), Color.WHITE, 3.0)
		var label: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
		if veh.wrecked:
			label = "WRECK"
		draw_string(font, org + Vector2(8, 18), "%s" % label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		if not veh.wrecked:
			draw_string(font, org + Vector2(8, vsize.y - 8),
				"DUR %d  CREW %d" % [veh.durability, veh.living_crew_count()],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.9, 0.9, 0.6))

	for unit in state.all_units():
		# Экипаж внутри машины на поле не рисуется (§техника).
		if unit.aboard_vehicle_id != -1:
			continue
		# Во время проигрывания шагов житель рисуется на промежуточной клетке (#96),
		# а не там, где он уже стоит по состоянию.
		var at := _draw_cell(unit)
		var center := _cell_origin(at) + Vector2(CELL, CELL) * 0.5
		# Туман войны (§3.9): чужой юнит виден, только если его клетку видит команда.
		if unit.owner != state.active_player() and not visible.has(at):
			continue
		# Смерть в текущем действии показываем лишь ПОСЛЕ анимации броска (#46):
		# пока крутится кубик, погибший рисуется как живой юнит.
		# Труп уже нарисован проходом выше, под машинами (#59).
		if unit.status == MCF.Status.CORPSE and not _pending_death_ids.has(unit.id):
			continue
		if unit.is_drone:
			# Дрон висит над клеткой (#13): рисуем со сдвигом в верхний-правый угол,
			# чтобы был виден наземный юнит/труп под ним.
			var dc := _cell_origin(at) + Vector2(CELL * 0.72, CELL * 0.28)
			# Тень под дроном по центру клетки — подсказка, что он парит.
			draw_circle(center, CELL * 0.1, Color(0, 0, 0, 0.25))
			var s := CELL * 0.2
			var drone_key := Sprites.resolve("drone", _owner_suffix(unit.owner))
			if drone_key != "":
				# Картинка дрона меньше клетки — он висит в углу над наземным юнитом.
				var dsz := Vector2(CELL, CELL) * 0.5
				Sprites.draw_texture_override_rect(self, drone_key, Rect2(dc - dsz * 0.5, dsz))
			else:
				var pts := PackedVector2Array([
					dc + Vector2(0, -s), dc + Vector2(s, 0),
					dc + Vector2(0, s), dc + Vector2(-s, 0)])
				draw_colored_polygon(pts, _side_color(unit.owner))
				draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.3, 0.9, 0.9), 2.0)
			if unit.id == selected_id:
				draw_arc(dc, CELL * 0.3, 0, TAU, 24, Color(1, 0.9, 0.2), 3.0)
			for i in _draw_ap(unit):
				draw_circle(_cell_origin(at) + Vector2(6 + i * 8, CELL - 6), 3, Color(1, 1, 0.4))
			continue
		# Боец: картинка по id типа (можно отдельную на сторону — light_infantry_p1),
		# иначе прежний кружок владельца с инициалами (#55).
		var unit_key := Sprites.resolve(unit.stats.id, _owner_suffix(unit.owner))
		if unit_key != "":
			Sprites.draw_texture_override(self, unit_key, _cell_origin(at), float(CELL))
		else:
			draw_circle(center, CELL * 0.34, _side_color(unit.owner))
			draw_string(font, center + Vector2(-9, 5), _initials(unit.stats.display_name),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		if unit.id == selected_id:
			draw_arc(center, CELL * 0.42, 0, TAU, 32, Color(1, 0.9, 0.2), 3.0)
		# Вскрытый мирный житель охотится — красное кольцо тревоги (§3.10, #56).
		if unit.owner == MCF.Owner.NEUTRAL and unit.civilian_active:
			draw_arc(center, CELL * 0.45, 0, TAU, 22, Color(0.85, 0.15, 0.15, 0.95), 2.0)
		# Кольцо принадлежности к RTS-группе (#18).
		if _group_ids.has(unit.id):
			draw_arc(center, CELL * 0.46, 0, TAU, 32, Color(0.4, 1.0, 0.5), 2.5)
		if unit.is_held():
			draw_arc(center, CELL * 0.48, 0, TAU, 32, Color(0.8, 0.3, 1.0), 3.0)
		if _pending_shoot(unit):
			draw_arc(center, CELL * 0.5, 0, TAU, 32, Color(1, 0.6, 0.1), 2.0)
		for i in _draw_ap(unit):
			draw_circle(_cell_origin(at) + Vector2(6 + i * 8, CELL - 6), 3, Color(1, 1, 0.4))
		# Инженер израсходовал единственную БРУ-стену (#40): пиксельный «!» рядом.
		if unit.bru_wall_used:
			_draw_pixel_bang(_cell_origin(at) + Vector2(CELL - 12, 4))
		# Юнит тащит на себе труп-щит (#6) — без метки это видно только в подсказке (#71).
		if unit.carried_corpses > 0:
			_draw_corpse_marker(_cell_origin(at) + Vector2(9, 9),
				unit.carried_corpses, font)

	# Рамка выделения (#18): сетка-выровненный зелёный прямоугольник поверх поля.
	if _box_dragging:
		var ba := _pos_to_cell(_box_start_screen)
		var bb := _pos_to_cell(_box_end_screen)
		var bx0 := mini(ba.x, bb.x)
		var by0 := mini(ba.y, bb.y)
		var bw := absi(bb.x - ba.x) + 1
		var bh := absi(bb.y - ba.y) + 1
		var brect := Rect2(_cell_origin(Vector2i(bx0, by0)), Vector2(bw * CELL, bh * CELL))
		draw_rect(brect, Color(0.3, 0.9, 0.4, 0.12))
		draw_rect(brect, Color(0.4, 1.0, 0.5, 0.8), false, 2.0)

## Труп на земле (#59): красный круг на половинной прозрачности — того же размера,
## что и живой боец, но полупрозрачный, поэтому тело сразу отличимо от бойца и не
## закрывает клетку. Подложенная картинка "corpse" (#55), если она есть, важнее.
## count — сколько тел в клетке: у кучи из нескольких рядом стоит число.
## Предпросмотр лазера (#99). Над каждым объектом на пути стоит его цена в потенциале,
## а там, где потенциал кончится, луч обрывается заметной поперечной чертой — иначе
## нельзя было понять, добьёт выстрел до цели или заглохнет на второй стене.
## Разметку даёт resolver.laser_preview — тот же расчёт, по которому пойдёт выстрел.
func _draw_laser_preview(shooter: UnitInstance, aim: Vector2i) -> void:
	var trace: Array = resolver.laser_preview(shooter, aim)
	if trace.is_empty():
		return
	var half := Vector2(CELL, CELL) * 0.5
	var font := ThemeDB.fallback_font
	for rec: Dictionary in trace:
		var bc: Vector2i = rec["coord"]
		draw_rect(Rect2(_cell_origin(bc), Vector2(CELL, CELL)), Color(0.4, 0.9, 1.0, 0.22))
	var last: Vector2i = trace[trace.size() - 1]["coord"]
	draw_line(_cell_origin(shooter.coord) + half, _cell_origin(last) + half,
			Color(0.5, 0.95, 1.0, 0.85), 2.0)
	# Метки цены — вторым проходом, чтобы подсветка клеток их не перекрывала.
	for rec: Dictionary in trace:
		var cost := int(rec["cost"])
		if String(rec["kind"]) == "empty" and cost == 0:
			continue
		var at := _cell_origin(rec["coord"]) + Vector2(CELL * 0.5, 4.0)
		# Стекло возвращает потенциал — такую метку показываем со знаком плюс.
		var text := ("+%d" % -cost) if cost < 0 else ("−%d" % cost)
		var col := Color(0.55, 1.0, 0.6) if cost < 0 else Color(1.0, 0.85, 0.4)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, -1, 13, 3,
				Color(0, 0, 0, 0.9))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, -1, 13, col)
	# Где луч гаснет: поперечная черта на дальней стороне последней клетки.
	var end_org := _cell_origin(last)
	var dir: Vector2i = trace[0]["coord"] - shooter.coord
	var edge := end_org + half + Vector2(dir.x, dir.y) * (CELL * 0.5)
	var across := Vector2(-dir.y, dir.x) * (CELL * 0.42)
	draw_line(edge - across, edge + across, Color(1.0, 0.4, 0.35, 0.95), 3.0)
	var left := int(trace[trace.size() - 1]["left"])
	draw_string_outline(font, end_org + Vector2(CELL * 0.5, CELL - 4), "%d left" % left,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 11, 3, Color(0, 0, 0, 0.9))
	draw_string(font, end_org + Vector2(CELL * 0.5, CELL - 4), "%d left" % left,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 11, Color(0.8, 0.95, 1.0))

func _draw_corpse(coord: Vector2i, count: int) -> void:
	var org := _cell_origin(coord)
	var center := org + Vector2(CELL, CELL) * 0.5
	if not Sprites.draw_texture_override(self, "corpse", org, float(CELL)):
		draw_circle(center, CELL * 0.34, CORPSE_COLOR)
	if count > 1:
		draw_string(ThemeDB.fallback_font, center + Vector2(CELL * 0.16, CELL * 0.3),
			"x%d" % count, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 0.85, 0.85))

## Метка «несёт труп» (#71): кружок цвета трупа (#59) в углу клетки, непрозрачный и
## с чёрной обводкой — иначе на тёмной картинке юнита его не разглядеть. Если трупов
## больше одного, рядом стоит их число (щит даёт +1 к защите за каждый, #6).
func _draw_corpse_marker(at: Vector2, count: int, font: Font) -> void:
	draw_circle(at, 5.0, Color(CORPSE_COLOR, 0.95))
	draw_arc(at, 5.0, 0, TAU, 14, Color(0, 0, 0, 0.85), 1.5)
	if count > 1:
		draw_string(font, at + Vector2(7, 4), str(count),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.9, 0.9))

func _draw_pixel_bang(top_left: Vector2) -> void:
	# Пиксель-арт восклицательного знака: столбик + точка. p = размер «пикселя».
	var p := 3.0
	var col := Color(1.0, 0.85, 0.1)
	var shadow := Color(0, 0, 0, 0.6)
	# Тень со сдвигом для читаемости на любом фоне.
	for off in [Vector2(1, 1), Vector2.ZERO]:
		var c: Color = shadow if off != Vector2.ZERO else col
		var b: Vector2 = top_left + off
		# Ствол: 3 «пикселя» по вертикали.
		for i in 3:
			draw_rect(Rect2(b + Vector2(0, i * p), Vector2(p, p)), c)
		# Точка внизу с зазором.
		draw_rect(Rect2(b + Vector2(0, 4 * p), Vector2(p, p)), c)

## Суффикс стороны для картинок-замен (#55): light_infantry_p1.png и т.п.
func _owner_suffix(owner_id: int) -> String:
	match owner_id:
		MCF.Owner.PLAYER_1: return "_p1"
		MCF.Owner.PLAYER_2: return "_p2"
		MCF.Owner.NEUTRAL: return "_neutral"
	return ""

## Поворот картинки техники под её фронт. Картинка рисуется «носом вверх»,
## поэтому вправо — это +90°. Без заданного фронта не поворачиваем вовсе.
##
## Угол считаем, а не берём из таблицы четырёх сторон (#96): фронт выбирается из всех
## ВОСЬМИ направлений, и раньше любая диагональ проваливалась в 0° — танк, повёрнутый
## на северо-восток, рисовался смотрящим строго на север. Со стороны это выглядело
## так, будто поворот списал ОД и оставил корпус в прежнем направлении.
func _facing_degrees(facing: Vector2i) -> float:
	if facing == Vector2i.ZERO:
		return 0.0
	return rad_to_deg(Vector2(facing).angle()) + 90.0

func _initials(name_ru: String) -> String:
	var parts := name_ru.split(" ", false)
	if parts.size() >= 2:
		return (parts[0].substr(0, 1) + parts[1].substr(0, 1)).to_upper()
	return name_ru.substr(0, 2).to_upper()

# --- Движимое/масштабируемое окно HUD ---
func _on_hud_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_hud_dragging = true
			_hud_drag_offset = _hud_window.position - event.global_position
		else:
			_hud_dragging = false
	elif event is InputEventMouseMotion and _hud_dragging:
		var vp := get_viewport_rect().size
		var new_pos: Vector2 = event.global_position + _hud_drag_offset
		new_pos.x = clampf(new_pos.x, 0.0, maxf(0.0, vp.x - _hud_window.size.x))
		new_pos.y = clampf(new_pos.y, 0.0, maxf(0.0, vp.y - _hud_window.size.y))
		_hud_window.position = new_pos
		_reposition_hud_grip()

func _on_hud_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_hud_resizing = true
			_hud_resize_start = event.global_position
			_hud_resize_origin = _hud_window.size
		else:
			_hud_resizing = false
	elif event is InputEventMouseMotion and _hud_resizing:
		var delta: Vector2 = event.global_position - _hud_resize_start
		var new_size: Vector2 = _hud_resize_origin + delta
		new_size.x = maxf(HUD_MIN_SIZE.x, new_size.x)
		new_size.y = maxf(HUD_MIN_SIZE.y, new_size.y)
		var vp := get_viewport_rect().size
		new_size.x = minf(new_size.x, vp.x - _hud_window.position.x)
		new_size.y = minf(new_size.y, vp.y - _hud_window.position.y)
		_hud_window.size = new_size
		_reposition_hud_grip()

func _reposition_hud_grip() -> void:
	if _hud_grip == null or _hud_window == null:
		return
	_hud_grip.position = _hud_window.position + _hud_window.size - _hud_grip.size

# --- UI ---
func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	add_child(_ui_layer)

	# --- Движимое/масштабируемое окно HUD в стиле Steam ------------------
	var panel := PanelContainer.new()
	panel.position = Vector2(700, 20)
	panel.size = HUD_START_SIZE
	panel.custom_minimum_size = HUD_MIN_SIZE
	SteamChrome.apply_panel(panel)
	_ui_layer.add_child(panel)
	_hud_window = panel

	# Угловой «грип» для изменения размера — отдельный оверлей поверх окна,
	# который _process держит в правом-нижнем углу окна.
	_hud_grip = Control.new()
	_hud_grip.custom_minimum_size = Vector2(18, 18)
	_hud_grip.size = Vector2(18, 18)
	_hud_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_hud_grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	_hud_grip.gui_input.connect(_on_hud_grip_input)
	_ui_layer.add_child(_hud_grip)
	# Видимый маркер грипа (маленький акцентный уголок).
	var grip_mark := ColorRect.new()
	grip_mark.color = Ui.accent_color()
	grip_mark.set_anchors_preset(Control.PRESET_FULL_RECT)
	grip_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_grip.add_child(grip_mark)

	# Внешняя раскладка окна: заголовок-ручка + прокручиваемое тело.
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(frame)

	# Полоса заголовка = ручка перетаскивания окна.
	var header := SteamChrome.header_bar("MCF Tactics")
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	header.gui_input.connect(_on_hud_header_input)
	frame.add_child(header)

	# Тело окна прокручивается, чтобы содержимое влезало при уменьшении.
	var body := ScrollContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(body)

	# Компактная раскладка (#54): служебные кнопки — парами в ряд, шрифты мельче,
	# журнал ниже. Сетевого блока здесь больше нет — он во вкладке главного меню.
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(SteamChrome.pad(vbox, 8, 6))

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 11)
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(_info_label)

	var btn := Button.new()
	btn.text = "End Turn"
	btn.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(btn)
	btn.pressed.connect(_on_end_turn_pressed)

	_undo_btn = _compact_button("Undo", _on_undo_pressed)
	_undo_btn.disabled = true
	_redo_btn = _compact_button("Redo", _on_redo_pressed)
	_redo_btn.disabled = true
	vbox.add_child(_button_row([_undo_btn, _redo_btn]))

	# Эти две подписи длинные, поэтому каждая занимает свою строку: в паре они не
	# помещались по ширине и обрезались до пары букв.
	_p1_btn = _compact_button("", _toggle_p1_ai)
	_p2_btn = _compact_button("", _toggle_p2_ai)
	_diff_btn = _compact_button("", _cycle_difficulty)
	vbox.add_child(_p1_btn)
	vbox.add_child(_p2_btn)
	vbox.add_child(_diff_btn)
	_refresh_ai_buttons()

	# Камеру легко увести за край большой карты (город 50×50) и потерять свои
	# войска — кнопка возвращает вид к исходной точке.
	vbox.add_child(_compact_button("Return to Map", _recenter_camera))

	var menu_btn := _compact_button("Main Menu", _to_menu)
	var editor_btn := _compact_button("Editor", _open_editor)
	vbox.add_child(_button_row([menu_btn, editor_btn]))

	_multi_btn = CheckBox.new()
	_multi_btn.text = "Multi-Select"
	_multi_btn.add_theme_font_size_override("font_size", 12)
	_multi_btn.toggled.connect(_on_multi_toggled)
	vbox.add_child(_multi_btn)

	# Строка сети появляется, только когда партия действительно сетевая.
	_net_status = Label.new()
	_net_status.add_theme_font_size_override("font_size", 11)
	_net_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_status.hide()
	vbox.add_child(_net_status)

	vbox.add_child(_hsep())
	_log_label = RichTextLabel.new()
	_log_label.custom_minimum_size = Vector2(0, 150)
	_log_label.add_theme_font_size_override("normal_font_size", 11)
	_log_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_label.scroll_following = true
	vbox.add_child(_log_label)

	# Всплывающее меню действий и выбор числа выстрелов — в общем оконном стиле
	# SteamChrome (рамка + шапка), как остальной интерфейс. Тело красим один раз,
	# внутренняя начинка перестраивается в _scroll_menu при каждом открытии.
	_menu = PanelContainer.new()
	SteamChrome.apply_panel(_menu)
	_menu.hide()
	_ui_layer.add_child(_menu)

	_picker = PanelContainer.new()
	SteamChrome.apply_panel(_picker)
	_picker.hide()
	_ui_layer.add_child(_picker)

	_dice = DiceRoller.new()
	_ui_layer.add_child(_dice)

	_build_quit_dialog()

## Модальное окно «выход в меню» в общем стиле (#51): затемнитель на весь экран
## и центрированная рамка SteamChrome с заголовком, текстом и кнопками.
func _build_quit_dialog() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.hide()
	# Затемнение фона.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)
	# Центрирующий контейнер.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	# Рамка окна.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	SteamChrome.apply_panel(panel)
	center.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Quit to Main Menu"))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	frame.add_child(SteamChrome.pad(body, 16, 14))
	var msg := Label.new()
	msg.text = "Return to the main menu? Current game progress will be lost."
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size = Vector2(320, 0)
	body.add_child(msg)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(110, 34)
	cancel.pressed.connect(func() -> void: _quit_dialog.hide())
	row.add_child(cancel)
	var ok := Button.new()
	ok.text = "Main Menu"
	ok.custom_minimum_size = Vector2(110, 34)
	ok.pressed.connect(_to_menu)
	row.add_child(ok)
	_quit_dialog = overlay
	_ui_layer.add_child(_quit_dialog)

func _hsep() -> HSeparator:
	return HSeparator.new()

## Невысокая кнопка мелким шрифтом — из таких собрана компактная панель (#54).
func _compact_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 26)
	b.add_theme_font_size_override("font_size", 12)
	# clip_text здесь стоять НЕ должно: с ним кнопка не учитывает ширину надписи в
	# своём минимальном размере, и в узкой панели (#54) от «AI Difficulty: Normal»
	# оставалось две буквы. Пусть лучше панель раздвинется, чем текст исчезнет.
	b.clip_text = false
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(handler)
	return b

## Ряд кнопок в одну строку — вдвое экономит высоту панели (#54).
func _button_row(buttons: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for b: Button in buttons:
		row.add_child(b)
	return row

## Оборачивает вертикальное меню в ScrollContainer с ограничением высоты по экрану,
## чтобы длинные меню не уходили за край и прокручивались.
## Строит начинку всплывающего меню в оконном стиле SteamChrome: шапка с
## заголовком + прокручиваемый столбец кнопок с отступами. Возвращает VBox для
## кнопок. Вызывающий сперва очищает детей панели — рамка пересобирается заново.
func _scroll_menu(panel: PanelContainer, title: String = "Actions") -> VBoxContainer:
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar(title))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 4)
	scroll.add_child(vb)
	frame.add_child(SteamChrome.pad(scroll, 8, 8))
	_cap_scroll_height.call_deferred(scroll, vb)
	return vb

## Под курсором ли какое-либо видимое всплывающее меню (#8).
func _pointer_over_popup(pos: Vector2) -> bool:
	for p in [_menu, _picker]:
		if p != null and p.visible and p.get_global_rect().has_point(pos):
			return true
	return false

func _cap_scroll_height(scroll: ScrollContainer, vb: Control) -> void:
	if not is_instance_valid(scroll) or not is_instance_valid(vb):
		return
	# Меню закреплено в левом верхнем углу (#87): запас снизу — на рамку и поля.
	var cap := get_viewport_rect().size.y - MENU_ANCHOR.y - MENU_CHROME_H
	scroll.custom_minimum_size.y = minf(vb.get_combined_minimum_size().y, maxf(cap, 120.0))

## Меню действий всегда живут в левом верхнем углу экрана, а не над юнитом (#87):
## над юнитом они закрывали поле и уезжали за край при зуме.
func _anchor_menu(panel: Control) -> void:
	panel.position = MENU_ANCHOR

## Цвет стороны с точки зрения того, кто смотрит на экран (#93). В сетевой партии
## СВОЯ армия всегда синяя, чужая — красная, кем бы ты ни был — Player A или B;
## в hotseat перспективы нет, поэтому остаётся жёсткая раскладка P1/P2.
func _side_color(side: int) -> Color:
	if networked and side != MCF.Owner.NEUTRAL:
		return OWNER_COLORS[MCF.Owner.PLAYER_1] if side == my_owner \
				else OWNER_COLORS[MCF.Owner.PLAYER_2]
	return OWNER_COLORS.get(side, Color(0.6, 0.6, 0.6))

func _open_menu(unit: UnitInstance) -> void:
	_picker.hide()
	for c in _menu.get_children():
		c.queue_free()
	var vb := _scroll_menu(_menu, unit.stats.display_name)

	if unit.is_drone:
		# Дрон (§3.12): летать (если оператор у станции) и подрыв.
		var controllable: bool = resolver.operator_controls(unit)
		if not controllable:
			var warn := Label.new()
			warn.text = "Operator not at the station"
			vb.add_child(warn)
		if controllable and (unit.remaining_ap > 0 or _drone_on_wall(unit)):
			var fly_btn := Button.new()
			fly_btn.text = "Descend" if _drone_on_wall(unit) else "Fly"
			fly_btn.pressed.connect(_enter_drone_fly)
			vb.add_child(fly_btn)
		if controllable:
			var det_btn := Button.new()
			det_btn.text = "Detonate"
			det_btn.pressed.connect(_submit.bind(DroneDetonateIntent.new(unit.id)))
			vb.add_child(det_btn)
	elif unit.is_held():
		# Удерживаемый юнит может только пытаться освободиться (§3.4).
		if unit.remaining_ap > 0:
			var release_btn := Button.new()
			release_btn.text = "Break Free (4+)"
			release_btn.pressed.connect(_submit.bind(ReleaseIntent.new(unit.id)))
			vb.add_child(release_btn)
	else:
		if unit.remaining_ap > 0 or unit.move_credit > 0:
			var move_btn := Button.new()
			# Накопленный остаток движения тратится первым, в любой момент хода (#32).
			move_btn.text = "Move (%d left)" % unit.move_credit if unit.move_credit > 0 else "Move"
			move_btn.pressed.connect(_enter_move)
			vb.add_child(move_btn)

		if _valid_pending_shoot(unit) or unit.remaining_ap >= _shoot_ap_cost(unit):
			var shoot_btn := Button.new()
			if _valid_pending_shoot(unit):
				shoot_btn.text = "Finish Burst"
			elif unit.stats.special_ability_id == MCF.ABILITY_MARKSMAN:
				shoot_btn.text = "Laser (2 AP)"
			elif unit.stats.special_ability_id == MCF.ABILITY_MINER \
					or unit.stats.special_ability_id == MCF.ABILITY_SHIELD_BEARER:
				shoot_btn.text = "Hit"  # ближний бой (§3.14)
			elif unit.stats.special_ability_id == MCF.ABILITY_FLAMETHROWER:
				shoot_btn.text = "Flame"
			else:
				shoot_btn.text = "Shoot"
			shoot_btn.pressed.connect(_enter_shoot)
			vb.add_child(shoot_btn)

		# Переложить пленника на другую соседнюю клетку — бесплатно (#100). Кнопка
		# появляется, только пока кого-то держим, и ОД не требует: носильщик просто
		# перехватывает тело, не сходя с места.
		if resolver.held_unit_of(unit) != null:
			var shift_btn := Button.new()
			shift_btn.text = "Shift Captive (free)"
			shift_btn.pressed.connect(_enter_move_held)
			vb.add_child(shift_btn)

		# Одна кнопка на всё, что можно взять руками (#50): боец, труп, мешки, ёж, куча земли.
		if unit.remaining_ap > 0 and (not resolver.capturable_target_ids(unit).is_empty()
				or not resolver.draggable_cells(unit).is_empty()):
			var grab_btn := Button.new()
			grab_btn.text = "Grab"
			grab_btn.pressed.connect(_enter_grab)
			vb.add_child(grab_btn)

		if unit.remaining_ap > 0 and not resolver.pushable_target_ids(unit).is_empty():
			var push_btn := Button.new()
			push_btn.text = "Shield Push"
			push_btn.pressed.connect(_enter_push)
			vb.add_child(push_btn)

		if unit.remaining_ap > 0 and resolver.can_use_item(unit) == "":
			var item_btn := Button.new()
			item_btn.text = MCF.ITEM_NAMES.get(unit.held_item_id, "Item")
			item_btn.pressed.connect(_enter_item)
			vb.add_child(item_btn)

		# Оператор дронов: запуск дрона со стоящей рядом станции (§3.12).
		if unit.remaining_ap > 0 and unit.stats.special_ability_id == MCF.ABILITY_DRONE_OPERATOR \
				and resolver.station_near(unit) != Vector2i(-1, -1) \
				and resolver.active_drone_of(unit) == null:
			var drone_btn := Button.new()
			drone_btn.text = "Launch Drone"
			drone_btn.pressed.connect(_submit.bind(SpawnDroneIntent.new(unit.id)))
			vb.add_child(drone_btn)

		# Инженер: постройка укреплений (§3.7).
		if unit.remaining_ap > 0 and unit.stats.special_ability_id == MCF.ABILITY_ENGINEER:
			for feat in [MCF.FEATURE_SANDBAGS, MCF.FEATURE_WALL, MCF.FEATURE_DOT,
					MCF.FEATURE_DOT_OPEN, MCF.FEATURE_GLASS, MCF.FEATURE_AIRLOCK,
					MCF.FEATURE_BRU, MCF.FEATURE_RSP, MCF.FEATURE_HEDGEHOG]:
				var cost: int = GameActionResolver.ENGINEER_BUILDABLE[feat]
				if unit.remaining_ap < cost:
					continue
				if resolver.buildable_cells(unit, feat).is_empty():
					continue
				# БРУ — одна на всю игру (#40): скрываем кнопку, если уже израсходована.
				if feat == MCF.FEATURE_BRU and unit.bru_wall_used:
					continue
				var bb := Button.new()
				if feat == MCF.FEATURE_BRU:
					# БРУ — цепочка из 6 клеток, «рисуется» вручную (§3.7).
					bb.text = "Build: BRU wall (%d tiles, %d AP)" % [MCF.BRU_WALL_LENGTH, cost]
					bb.pressed.connect(_enter_build_wall)
				else:
					bb.text = "Build: %s (%d AP)" % [MCF.FEATURE_NAMES[feat], cost]
					bb.pressed.connect(_enter_build.bind(feat))
				vb.add_child(bb)

		# Инженер: заварить соседний шлюз (#99).
		if not resolver.weldable_cells(unit).is_empty():
			var weld_btn := Button.new()
			weld_btn.text = "Weld Airlock (%d AP)" % GameActionResolver.WELD_AIRLOCK_AP
			weld_btn.pressed.connect(_enter_weld)
			vb.add_child(weld_btn)

		# Инженер/шахтёр: слом укреплений (§3.7).
		if unit.remaining_ap > 0 and not resolver.breakable_cells(unit).is_empty():
			var brk := Button.new()
			brk.text = "Demolish Fortification"
			brk.pressed.connect(_enter_break)
			vb.add_child(brk)

		# Подобрать труп как переносной щит (+1 к защите) (#6).
		if unit.remaining_ap > 0:
			var corpse_cell := resolver.corpse_pickup_cell(unit)
			if corpse_cell != Vector2i(-999, -999):
				var pick_btn := Button.new()
				pick_btn.text = "Pick Up Corpse (+1 def)"
				pick_btn.pressed.connect(_submit.bind(PickUpCorpseIntent.new(unit.id, corpse_cell)))
				vb.add_child(pick_btn)
		# Положить несомый труп на выбранную клетку — свою или соседнюю (#6, #72).
		if unit.carried_corpses > 0:
			var drop_btn := Button.new()
			drop_btn.text = "Drop Corpse (carrying %d)" % unit.carried_corpses
			drop_btn.pressed.connect(_enter_corpse_drop)
			vb.add_child(drop_btn)

		# РСП (§3.7): стрельба из своего пулемёта рядом.
		if unit.remaining_ap > 0:
			var own_rsp := resolver.rsp_cells(unit, true)
			if not own_rsp.is_empty():
				var rsp_btn := Button.new()
				rsp_btn.text = "Fire RSP"
				rsp_btn.pressed.connect(_enter_rsp_fire.bind(own_rsp[0]))
				vb.add_child(rsp_btn)
			# Отобрать вражеский РСП (по правилу захвата).
			var foe_rsp := resolver.rsp_cells(unit, false)
			if not foe_rsp.is_empty():
				var seize_btn := Button.new()
				seize_btn.text = "Seize RSP"
				seize_btn.pressed.connect(_submit.bind(RSPFireIntent.new(unit.id, foe_rsp[0], -1, -1)))
				vb.add_child(seize_btn)

		# Копка окопа (§3.7): пехота 3 окопа / инженер 6 за 1 ОД.
		if (unit.remaining_ap > 0 or unit.dig_credits > 0) and not resolver.diggable_cells(unit).is_empty():
			var dig_btn := Button.new()
			dig_btn.text = "Dig Trench" if unit.dig_credits <= 0 \
				else "Dig Trench (%d free)" % unit.dig_credits
			dig_btn.pressed.connect(_enter_dig)
			vb.add_child(dig_btn)

		# Посадка в стоящую рядом технику (свою или вражескую).
		if unit.remaining_ap > 0:
			for veh: Vehicle in resolver.boardable_vehicles(unit):
				var vname: String = VehicleDB.get_vehicle(veh.type_id).get("name", veh.type_id)
				var seat_btn := Button.new()
				seat_btn.text = "Board %s" % vname if veh.owner == unit.owner \
					else "Storm %s" % vname
				seat_btn.pressed.connect(_submit.bind(VehicleBoardIntent.new(unit.id, veh.id)))
				vb.add_child(seat_btn)

	# Выдохшемуся юниту меню не нужно (#97): когда ОД кончились и ни одного действия не
	# набралось, панель с одной кнопкой Cancel только загораживает поле. Выделение при
	# этом держим — по нему читается строка характеристик, а снимается оно щелчком мимо.
	if not _has_action_button(vb):
		_menu.hide()
		return

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_deselect)
	vb.add_child(cancel_btn)

	_anchor_menu(_menu)
	_menu.show()

func _has_action_button(vb: VBoxContainer) -> bool:
	for c in vb.get_children():
		if c is Button:
			return true
	return false

func _open_picker(target: UnitInstance, available: int) -> void:
	_menu.hide()
	for c in _picker.get_children():
		c.queue_free()
	var vb := _scroll_menu(_picker, "Shots at %s" % target.stats.display_name)
	var row := HBoxContainer.new()
	vb.add_child(row)
	for n in range(1, available + 1):
		var b := Button.new()
		b.text = str(n)
		b.pressed.connect(_submit.bind(ShootIntent.new(selected_id, target.id, n)))
		row.add_child(b)
	var all_btn := Button.new()
	all_btn.text = "All (%d)" % available
	all_btn.pressed.connect(_submit.bind(ShootIntent.new(selected_id, target.id, -1)))
	vb.add_child(all_btn)
	_anchor_menu(_picker)
	_picker.show()

func _toggle_p2_ai() -> void:
	if _animating or networked:
		return
	p2_is_ai = not p2_is_ai
	_deselect()
	_make_side(MCF.Owner.PLAYER_2)
	_refresh_ai_buttons()
	_kick_if_ai()

## Тот же переключатель для первого игрока (#103) — так бой ИИ против ИИ включается прямо
## посреди партии, не выходя в меню.
func _toggle_p1_ai() -> void:
	if _animating or networked:
		return
	p1_is_ai = not p1_is_ai
	_deselect()
	_make_side(MCF.Owner.PLAYER_1)
	_refresh_ai_buttons()
	queue_redraw()
	_kick_if_ai()

func _cycle_difficulty() -> void:
	if networked:
		return
	ai_difficulty = (ai_difficulty + 1) % 3
	if p1_is_ai:
		_make_side(MCF.Owner.PLAYER_1)
	if p2_is_ai:
		_make_side(MCF.Owner.PLAYER_2)
	_refresh_ai_buttons()
	_kick_if_ai()

func _refresh_ai_buttons() -> void:
	if _p1_btn != null:
		_p1_btn.text = "Player 1: %s" % ("AI" if p1_is_ai else "Human")
	if _p2_btn != null:
		_p2_btn.text = "Player 2: %s" % ("AI" if p2_is_ai else "Human")
	if _diff_btn != null:
		var names := ["Easy", "Normal", "Hard"]
		_diff_btn.text = "AI Difficulty: %s" % names[ai_difficulty]
		_diff_btn.disabled = not (p1_is_ai or p2_is_ai)

func _open_editor() -> void:
	if networked:
		return
	get_tree().change_scene_to_file("res://scenes/MapEditor.tscn")

func _to_menu() -> void:
	# Сессия висит под /root (#54), поэтому её надо закрыть руками: смена сцены
	# сама её не заберёт, а живой ENet-пир помешал бы завести новую партию.
	if session != null:
		session.close()
		session.queue_free()
		session = null
	networked = false
	net = null
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

func _on_end_turn_pressed() -> void:
	if _animating:
		return
	_deselect()
	_submit(EndTurnIntent.new())

## Откат (#47). Отменяет даже мельчайшие шаги: если сейчас рисуется БРУ-стена —
## снимает последнюю выложенную клетку; иначе восстанавливает состояние из стека.
func _on_undo_pressed() -> void:
	if _animating or not _my_turn():
		return
	# Незакоммиченное рисование БРУ-стены: убираем последнюю клетку (как Backspace).
	if not _wall_cells.is_empty():
		_wall_undo()
		return
	if _undo_stack.is_empty():
		return
	# Текущее состояние уходит в Redo, чтобы откат можно было вернуть (#38).
	_redo_stack.append(state.snapshot())
	_apply_snapshot(_undo_stack.pop_back())

## Повтор отменённого действия (#38): зеркало Undo.
func _on_redo_pressed() -> void:
	if _animating or _redo_stack.is_empty() or not _my_turn():
		return
	_undo_stack.append(state.snapshot())
	_apply_snapshot(_redo_stack.pop_back())

func _apply_snapshot(snap: Dictionary) -> void:
	state.restore(snap)
	resolver.update_airlocks()
	_deselect()
	for c in controllers.values():
		c.notify_state_changed(state)
	_refresh_status()
	queue_redraw()

## Откат доступен ТОЛЬКО на своём ходу (#94): на ходу ИИ, мирных или соперника по
## сети кнопка гаснет — переигрывать чужой ход нельзя.
func _my_turn() -> bool:
	return state != null and _can_control(state.active_player())

func _refresh_undo_btn() -> void:
	if _undo_btn == null:
		return
	var mine := _my_turn()
	_undo_btn.disabled = not mine or (_undo_stack.is_empty() and _wall_cells.is_empty())
	if _redo_btn != null:
		_redo_btn.disabled = not mine or _redo_stack.is_empty()

## Имя стороны на экране. В сетевой партии стороны зовутся Player A (хост) и
## Player B (присоединившийся), а своя помечается «(you)» (#93).
func _side_label(side: int) -> String:
	if not networked or side == MCF.Owner.NEUTRAL:
		return MCF.owner_name(side)
	var base := "Player A" if side == MCF.Owner.PLAYER_1 else "Player B"
	return base + " (you)" if side == my_owner else base

func _order_labels() -> String:
	if not networked:
		return state.turns.order_names()
	var parts: Array[String] = []
	for s in state.turns.round_order:
		parts.append(_side_label(s))
	return " → ".join(parts)

func _refresh_status() -> void:
	if _status_label != null:
		# Порядок инициативы фиксирован на всю партию (#53) — держим его на виду,
		# но отдельной строкой: панель теперь узкая (#54).
		_status_label.text = "Turn: %s  |  Round: %d\nOrder: %s" % [
			_side_label(state.active_player()), state.turns.round_number,
			_order_labels()
		]
	_refresh_undo_btn()

func _refresh_info() -> void:
	if _info_label == null:
		return
	var u := _selected_unit()
	if u == null:
		_info_label.text = "%d units selected." % _group_ids.size() if not _group_ids.is_empty() \
			else "Click to select a unit."
		return
	var range_text := "∞" if is_inf(u.stats.fire_range) else (
		"—" if u.stats.fire_range <= 0 else str(int(u.stats.fire_range)))
	var bonus := ""
	if u.stats.target_defense_penalty > 0:
		bonus = "  (−%d to target defense)" % u.stats.target_defense_penalty
	_info_label.text = "%s - range %s, RoF %d, armor %d+, speed %d%s" % [
		u.stats.display_name, range_text,
		u.stats.rate_of_fire, u.stats.armor_threshold, u.stats.speed, bonus,
	]

func _on_log_line(text: String) -> void:
	if _log_label != null:
		_log_label.append_text(text + "\n")
