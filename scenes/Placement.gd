extends Node2D

## Экран свободной расстановки + point-buy (§6, §7). Каждая сторона тратит бюджет
## GameConfig.budget на покупку юнитов и ставит их в своей зоне развёртывания.
## Сначала расставляет Player 1, затем Player 2; по кнопке «Start Battle» собирает
## MapData со спавнами и передаёт бой в Main через MapHandoff.

const MAIN_SCENE := "res://scenes/Main.tscn"
const LOBBY_SCENE := "res://scenes/Lobby.tscn"
const MENU_SCENE := "res://scenes/MainMenu.tscn"
## Хелпер оформления окон в стиле «2003 Steam» (preload, без class_name).
const SteamChrome = preload("res://src/ui/SteamChrome.gd")
const CELL := 34
const ORIGIN := Vector2(30, 30)
const PAN_SPEED := 700.0
const ZOOM_MIN := 0.5
const ZOOM_MAX := 2.5
const ZOOM_STEP := 1.1

## Покупаемая техника (§техника, #10): танк и челнок.
const PURCHASABLE_VEHICLES := ["tank", "shuttle", "borg"]

## Покупаемые юниты (дрона в списке нет — его призывает оператор).
## Купленный мирный житель — обычный дешёвый боец СВОЕЙ стороны (#96): игрок им
## командует, и по своим он не стреляет. Нейтральные жители-НПС берутся только из
## разметки самой карты (preserved_neutral) — вот они и враждебны обоим.
const PURCHASABLE := [
	"light_infantry", "heavy_infantry", "assault", "machinegunner",
	"sniper", "marksman", "anti_tank", "flamethrower",
	"commander", "engineer", "miner", "sapper", "drone_operator", "shield_bearer",
	"civilian",
]

## Цвета игроков живут в ростере (batch 12 #11); здесь остался только нейтральный.
const NEUTRAL_COLOR := Color(0.7, 0.7, 0.7)

var map: MapData
var budget: int = 300
## Потрачено очков по сторонам: side -> сумма. Заполняется по составу партии.
var spent: Dictionary = {}
var active_side: int = MCF.Owner.PLAYER_1
## Состав партии: кто вообще расставляется и в каком порядке (хот-сит идёт по нему).
var roster: Roster
var brush_unit: String = ""
## Расставленные игроками юниты: [{"stats_id", "owner", "coord"}].
var placed: Array = []
## Нейтральные спавны исходной карты (мирные), которые сохраняем.
var preserved_neutral: Array = []
## Карта сама размечает зоны развёртывания кистью зон (#52) — тогда играем по ним,
## а не по половинкам поля. На «городе» (#57) это и не пускает игроков в дома.
var _map_zones: bool = false
var _stats_cache: Dictionary = {}

var pan: Vector2 = Vector2.ZERO
var zoom: float = 1.0
var _mouse_panning: bool = false
## Рисование расстановки перетаскиванием (#11): держим ЛКМ и ведём мышью.
var _painting: bool = false
var _paint_last: Vector2i = Vector2i(-9999, -9999)

var _ui: CanvasLayer
var _panel: PanelContainer
var _budget_label: Label
var _phase_label: Label
var _status: Label
var _palette: VBoxContainer
## Техника — своей рамкой под пехотой (аудит UI: разделы — групповые окошки набора).
var _veh_palette: VBoxContainer
var _palette_buttons: Dictionary = {}
var _flow_btn: Button

## Инструменты кисти на фазе закупки (item 12): точка/линия/прямоугольник/круг/заливка
## зоны. Форма ставит выбранного юнита в каждую свою клетку — в пределах зоны, бюджета
## и проходимости. Точка — прежнее поведение (клик + перетаскивание).
enum PTool { POINT, LINE, RECT, CIRCLE, FILL }
var _ptool: int = PTool.POINT
## Ластик (batch 13 #5): пока включён, кисть и формы не ставят, а СНИМАЮТ своих юнитов —
## точкой, протяжкой, линией, прямоугольником, кругом или всей зоной разом.
var _erasing: bool = false
var _eraser_btn: Button = null
var _shape_start: Vector2i = Vector2i(-9999, -9999)
var _shape_cur: Vector2i = Vector2i(-9999, -9999)
var _tool_buttons: Dictionary = {}

# --- Сетевая расстановка (#93) ---
## Экран работает и в сетевой партии: каждый игрок набирает ТОЛЬКО свою армию и
## ставит её ТОЛЬКО в своей зоне. По «Ready» стороны обмениваются ростерами и,
## получив оба, строят одинаковый MapData и уходят в бой.
const K_ROSTER := "roster"
## Живая расстановка (batch 12 #15): пока «Live placement visibility» включена, каждый
## щелчок по полю уезжает остальным, и они видят чужую армию по мере её сборки.
const K_LIVE := "live"
## Просьба показать текущую расстановку (batch 12 #15): шлёт вошедший на экран, чтобы
## увидеть то, что остальные успели поставить до его прихода.
const K_LIVE_REQ := "live_req"
## Слот стал ИИ (batch 13 #2): хост сообщает гостям, что ушедшего игрока подменяет
## машина, — иначе их ростер продолжал бы ждать его армию и его броски.
const K_SLOT_AI := "slot_ai"
## Снять готовность (playtest-20). Гость ПРОСИТ (K_UNREADY_REQ), хост решает и объявляет
## всем (K_UNREADY): начать бой может только хост (K_GO), поэтому просьба, пришедшая уже
## после старта, просто опоздала — и гость уходит в бой с той армией, что успел сдать.
## Иначе гость мог бы снять готовность и переставить армию в ту же секунду, когда хост
## по его старому ростеру уже начал бой.
const K_UNREADY_REQ := "unready_req"
const K_UNREADY := "unready"
const K_GO := "go"
var _net: NetworkSession = null
var _net_is_host: bool = false
var _my_side: int = MCF.Owner.PLAYER_1
var _my_ready: bool = false
## Просьба снять готовность ушла хосту, ответа ещё нет: армию трогать пока нельзя.
var _unready_pending: bool = false
## Хост объявил старт (K_GO): гость уходит в бой, как только у него сошлись все армии.
var _go: bool = false
## Армии, присланные по сети готовыми, по сторонам: side -> Array записей (batch 12 #12).
## Хост шлёт сразу несколько сторон (свою, ИИ, а в зеркальном режиме — всех).
var _remote_units: Dictionary = {}
## Стороны, чья армия уже пришла окончательно.
var _ready_sides: Dictionary = {}
## Чужая расстановка «вживую» (K_LIVE): side -> Array записей, только для показа.
var _live_units: Dictionary = {}
## Общее зерно кубиков, чтобы у обеих сторон совпал локальный бросок инициативы.
var _shared_seed: int = -1
## Порядок инициативы на панели справа (batch group-zones): пересобирается, когда зерно
## становится известно (у гостя — с сообщением хоста).
var _init_box: VBoxContainer = null
## Плитки рельефа (items 1/9) и сетка, из которой они собраны (рельеф карты неизменен).
var _tile_layer: TerrainTiles.Layer = null
## Чат закупки (item 14) — тот же разговор, что в лобби и в бою.
var _chat: ChatBox = null
var _chat_win: PanelContainer = null
var _tile_grid: Grid = null

func _ready() -> void:
	budget = GameConfig.budget
	roster = GameConfig.active_roster()
	for side in _sides():
		spent[side] = 0
	active_side = _sides()[0]
	map = _load_or_blank_map()
	_map_zones = _map_defines_zones()
	# Сохранить нейтральные спавны карты (мирные), сбросить игровые.
	if GameConfig.civilians_enabled:
		for s in map.spawns:
			if int(s["owner"]) == MCF.Owner.NEUTRAL:
				preserved_neutral.append(s)
	map.spawns = []
	_adopt_network()
	# Своё зерно и в одиночной партии: по нему панель показывает порядок инициативы, и
	# по нему же его бросит бой (MapHandoff.dice_seed).
	if not networked():
		_shared_seed = randi() & 0x7FFFFFFF
	_build_sky()
	_home_view.call_deferred()
	_build_ui()
	set_process(true)
	_refresh_labels()
	queue_redraw()
	# Подписываемся на входящие только когда UI готов: attach() сразу же отдаёт
	# всё, что накопилось в буфере, а обработчик трогает метки панели.
	if _net != null:
		_net.attach()
		_net.send({"k": K_LIVE_REQ})

func networked() -> bool:
	return _net != null

## Подхватить связь, налаженную во вкладке Multiplayer главного меню.
func _adopt_network() -> void:
	if NetHandoff.session == null:
		return
	_net_is_host = NetHandoff.is_host
	_net = NetHandoff.take()
	# Своя сторона — слот с моим сетевым номером (batch 12 #8/#11); у хоста он 1.
	# Старая дуэльная раскладка «хост — первый, гость — второй» остаётся запасной.
	var mine := roster.side_of_peer(_net.my_peer_id())
	if mine < 0:
		mine = MCF.Owner.PLAYER_1 if _net_is_host else MCF.Owner.PLAYER_2
	_my_side = mine
	active_side = _my_side
	# Зерно назначает хост — оно едет вместе с его ростером.
	if _net_is_host:
		_shared_seed = randi() & 0x7FFFFFFF
	_net.message.connect(_on_net_message)
	_net.disconnected.connect(_on_net_lost)
	if _net_is_host:
		_net.peer_left.connect(_on_peer_left)

## Гость ушёл с закупки (batch 13 #2): его сторону берёт ИИ высокой сложности. Армию,
## которую он успел сдать, оставляем ему; если не успел — хост набирает её сам, как за
## любой ИИ-слот, даже если уже нажал «Ready».
func _on_peer_left(id: int) -> void:
	var side := roster.side_of_peer(id)
	if side < 0:
		return
	var slot := roster.slot(side)
	slot.kind = Roster.SlotKind.AI
	slot.ai_difficulty = AIController.Difficulty.HARD
	slot.peer_id = -1
	_live_units.erase(side)
	if _net != null:
		_net.send({"k": K_SLOT_AI, "side": side, "ai": slot.ai_difficulty})
	if _ready_sides.has(side) and _remote_units.has(side):
		_status.text = "%s left — a Hard AI takes over their army." % roster.name_of(side)
	else:
		_ready_sides.erase(side)
		_remote_units.erase(side)
		_status.text = "%s left — deploy an army for the Hard AI that takes their place." % roster.name_of(side)
		if _my_ready and GameConfig.placement_mode != GameConfig.Placement.MIRRORED:
			# Своё уже сдано, а за ушедшего никто не ставил: возвращаем кнопку и ведём
			# хоста по его новой стороне. Отправленные раньше стороны переслать не страшно —
			# пакет «sides» заменяет их тем же самым.
			_my_ready = false
			_flow_btn.disabled = false
			active_side = side
			brush_unit = ""
			_populate_palette()
	_refresh_labels()
	queue_redraw()
	_try_start()

## Гость узнал от хоста, что слот стал ИИ (batch 13 #2).
func _apply_slot_ai(msg: Dictionary) -> void:
	var side := int(msg.get("side", -1))
	var slot := roster.slot(side)
	if slot == null:
		return
	slot.kind = Roster.SlotKind.AI
	slot.ai_difficulty = int(msg.get("ai", AIController.Difficulty.HARD))
	slot.peer_id = -1
	_live_units.erase(side)
	if _status != null:
		_status.text = "%s left — a Hard AI takes that side." % roster.name_of(side)
	_refresh_labels()
	queue_redraw()

func _on_net_lost() -> void:
	# Хост, оставшийся без гостей, не уходит в меню (batch 13 #2): ушедших уже подменил
	# ИИ (peer_left приходит раньше), сессия остаётся жить закрытой — её send() молчит, —
	# а расстановка и бой идут дальше тем же сетевым путём, только слать уже некому.
	if _net_is_host:
		if _status != null:
			_status.text = "Everyone else left — the remaining sides are Hard AI. Finish deploying and press Ready."
		_refresh_labels()
		_try_start()
		return
	if _status != null:
		_status.text = "Connection lost — returning to the menu."
	_drop_session()
	get_tree().change_scene_to_file(MENU_SCENE)

## Закрыть и снять узел сессии: он живёт под /root и сменой сцены сам не убирается.
func _drop_session() -> void:
	if _net == null:
		return
	_net.close()
	_net.queue_free()
	_net = null

func _on_net_message(msg: Dictionary) -> void:
	if _chat != null and _chat.receive(msg):
		return
	match str(msg.get("k", "")):
		K_LIVE_REQ:
			_send_live()
			return
		K_SLOT_AI:
			_apply_slot_ai(msg)
			return
		K_UNREADY_REQ:
			# Хост принимает просьбу, только пока бой не начат — начатый бой эту сцену
			# уже закрыл, и опоздавшая просьба сюда не дойдёт.
			if _net_is_host:
				_announce_unready(msg.get("sides", []))
			return
		K_UNREADY:
			_apply_unready(msg.get("sides", []))
			return
		K_GO:
			_go = true
			_try_start()
			return
		NetHandoff.K_SETUP_REQ:
			# Гость остался в лобби без объявления матча (batch 13 #11) — повторяем ему
			# K_SETUP с той же картой; расстановка у него начнётся с этого места.
			if _net_is_host and _net != null:
				# Карта уходит С нейтральными спавнами: здесь они вынуты в
				# preserved_neutral, а гость вынимает их из присланной карты сам.
				var shared := MapData.from_dict(map.to_dict())
				shared.spawns = []
				for n in preserved_neutral:
					shared.set_spawn(n["coord"], n["stats_id"], MCF.Owner.NEUTRAL)
				_net.send(NetHandoff.encode_setup(shared))
			return
		K_LIVE:
			# Чужая армия по мере сборки (batch 12 #15) — только картинка.
			for side in msg.get("sides", []):
				_live_units[int(side)] = []
			for e in msg.get("u", []):
				var side := int(e["o"])
				if not _live_units.has(side):
					_live_units[side] = []
				_live_units[side].append(e)
			queue_redraw()
			return
		K_ROSTER:
			pass
		_:
			return
	# «sides» — чьи армии лежат в пакете (они заменяют прежнее), «ready» — кто
	# подтвердил готовность. Гость зеркальной партии шлёт только готовность: его армию
	# уже прислал хост, и затирать её пустым списком нельзя (batch 12 #12).
	var units: Array = msg.get("u", [])
	var sides: Array = msg.get("sides", [])
	for side in sides:
		_remote_units[int(side)] = []
		_live_units.erase(int(side))
	for e in units:
		var side := int(e["o"])
		if not _remote_units.has(side):
			_remote_units[side] = []
		_remote_units[side].append(e)
	for side in msg.get("ready", sides):
		_ready_sides[int(side)] = true
	if int(msg.get("seed", -1)) >= 0:
		_shared_seed = int(msg["seed"])
		_refresh_initiative()
	# Зеркальная партия (batch 12 #12): армия хоста пришла — моя зона уже заполнена
	# её отражением, самому ставить нечего, остаётся подтвердить готовность.
	_refresh_labels()
	queue_redraw()
	# Гость зеркальной партии подтверждает готовность сам (batch 13 #13): его армия —
	# отражение армии хоста, выбирать ему нечего, а лишняя кнопка только задерживала бой.
	if _mirrored_guest() and _remote_units.has(_my_side) and not _my_ready:
		_status.text = "The host's formation has been mirrored into your zone."
		_on_net_ready()
		return
	if _my_ready:
		_try_start()
	elif _status != null and not _mirrored_guest():
		_status.text = "%s is ready. Deploy your squad and press Ready." % _ready_names()

## Кто из соперников уже готов — для подписи.
## Порядок хода, который бросит бой: игроки (тасовка от общего зерна) и место слота мирных,
## если на карте будут мирные. Пока зерна нет (гость ждёт сообщения хоста) — «бросается».
func _refresh_initiative() -> void:
	if _init_box == null:
		return
	for c in _init_box.get_children():
		c.queue_free()
	if _shared_seed < 0:
		var wait := Label.new()
		wait.text = "Rolled when the host starts the match"
		wait.add_theme_font_size_override("font_size", 11)
		wait.modulate = Color(0.75, 0.78, 0.85)
		_init_box.add_child(wait)
		return
	# Мирные карты ждут в preserved_neutral (map.spawns на закупке чистится); бой вставит
	# их слот, если хоть один житель встанет на поле.
	var neutrals := GameConfig.civilian_count > 0 and not preserved_neutral.is_empty()
	var ids: Array = roster.player_ids().duplicate()
	ids.sort()   # как _player_slots у боя
	var order := TurnManager.roll_order(ids, DiceService.new(_shared_seed), neutrals)
	for i in order.size():
		var sid: int = order[i]
		var irow := HBoxContainer.new()
		irow.add_theme_constant_override("separation", 6)
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(12, 12)
		sw.color = _side_color(sid) if MCF.is_player(sid) else Color(0.6, 0.62, 0.66)
		irow.add_child(sw)
		var nm := "%d. " % (i + 1)
		if MCF.is_player(sid):
			nm += roster.name_of(sid)
			if roster.has_teams() and roster.team_of(sid) >= 0:
				nm += " · %s" % MCF.team_name(roster.team_of(sid))
		else:
			nm += "Neutrals"
		var il := Label.new()
		il.text = nm
		il.add_theme_font_size_override("font_size", 12)
		irow.add_child(il)
		_init_box.add_child(irow)

func _ready_names() -> String:
	var names: Array[String] = []
	for side in _ready_sides:
		if int(side) != _my_side and not _host_sides().has(int(side)):
			names.append(roster.name_of(int(side)))
	return ", ".join(names) if not names.is_empty() else "Another player"

## Гость в зеркальной партии: сам ничего не ставит (batch 12 #12).
func _mirrored_guest() -> bool:
	return networked() and not _net_is_host \
			and GameConfig.placement_mode == GameConfig.Placement.MIRRORED

## Стороны, которые расставляет ЭТА машина (batch 12 #15): свою и — у хоста — все
## ИИ-слоты, ведь больше их набрать некому. В зеркальном режиме ИИ получают отражение
## армии хоста, а не свою закупку.
func _host_sides() -> Array[int]:
	var out: Array[int] = [_my_side]
	if networked() and _net_is_host:
		for side in _sides():
			if side != _my_side and roster.is_ai(side) \
					and GameConfig.placement_mode != GameConfig.Placement.MIRRORED:
				out.append(side)
	return out

## Все ли стороны на месте (batch 12 #12): «when everyone's ready the match starts».
## Стороны, которые ставит хост (ИИ, зеркальные копии), едут с его пакетом.
func _all_sides_ready() -> bool:
	if not _my_ready:
		return false
	for side in _sides():
		if _host_sides().has(side):
			continue
		if not _ready_sides.has(side):
			return false
	return _shared_seed >= 0

## Армию этой стороны собирала ЭТА машина — в присланных пакетах её быть не должно, а
## если она там есть (эхо своего же пакета), брать её не надо. Гость зеркальной партии
## сам не ставит ничего, и его сторона приходит от хоста как чужая.
func _placed_here(side: int) -> bool:
	if _mirrored_guest():
		return false
	if _host_sides().has(side):
		return true
	# Хост зеркальной партии отштамповал все стороны сам — они лежат в placed.
	return networked() and _net_is_host \
			and GameConfig.placement_mode == GameConfig.Placement.MIRRORED and _my_ready

func _try_start() -> void:
	if not _all_sides_ready():
		return
	# Начинает только хост (playtest-20): гость ждёт его K_GO — так снятая готовность
	# не может разминуться со стартом на другой машине.
	if networked() and not _net_is_host:
		if not _go:
			return
	elif networked() and _net != null:
		_net.send({"k": K_GO})
	_start_battle()

## Армия сдана — поле расстановки заперто до Unready (playtest-20).
func _ready_locked() -> bool:
	return networked() and _my_ready

## Кнопка в сетевой партии: Ready, а у готового — Unready (playtest-20).
func _on_net_flow() -> void:
	if _my_ready:
		_on_net_unready()
	else:
		_on_net_ready()

func _on_net_unready() -> void:
	if not _my_ready or _unready_pending or _mirrored_guest():
		return
	var sides: Array = [_my_side]
	if _net_is_host:
		# Хост сдавал и за ИИ — их готовность снимается вместе с его.
		for side in _sides():
			if roster.is_ai(side):
				sides.append(side)
		_announce_unready(sides)
	else:
		_unready_pending = true
		_status.text = "Asking the host to take your army back..."
		_net.send({"k": K_UNREADY_REQ, "sides": sides})
		_refresh_labels()

## Хост: снять готовность сторон у себя и у всех.
func _announce_unready(sides: Array) -> void:
	_net.send({"k": K_UNREADY, "sides": sides})
	_apply_unready(sides)

func _apply_unready(sides: Array) -> void:
	for side in sides:
		_ready_sides.erase(int(side))
	if sides.has(_my_side) and _my_ready:
		_my_ready = false
		_unready_pending = false
		_status.text = "You are no longer ready — change your army and press Ready again."
		_send_live()
	elif not sides.is_empty() and _status != null:
		_status.text = "%s is no longer ready." % roster.name_of(int(sides[0]))
	_refresh_labels()
	queue_redraw()

## Ростер в JSON-совместимом виде (Vector2i → пара x/y).
func _encode_roster(sides: Array = []) -> Array:
	var out: Array = []
	for p in placed:
		if not sides.is_empty() and not sides.has(int(p["owner"])):
			continue
		var c: Vector2i = p["coord"]
		var f := _placed_facing_or_zero(p)
		out.append({"id": p["stats_id"], "o": int(p["owner"]), "x": c.x, "y": c.y,
			"fx": f.x, "fy": f.y})
	return out

## Фронт только для техники (item 21); для пехоты — ноль, чтобы в файл/сеть не ехало лишнее.
func _placed_facing_or_zero(rec: Dictionary) -> Vector2i:
	if VehicleDB.is_vehicle(rec["stats_id"]):
		return _placed_facing(rec)
	return Vector2i.ZERO

func _on_net_ready() -> void:
	if _my_ready:
		return
	# Хост ставит и за ИИ (batch 12 #15): пока не обойдены все его стороны, кнопка
	# ведёт к следующей, а не к готовности.
	var mine := _host_sides()
	var at := mine.find(active_side)
	if not _mirrored_guest() and _side_unit_count(active_side) == 0:
		_status.text = "Deploy at least one unit for %s." % _side_label(active_side)
		return
	if at >= 0 and at < mine.size() - 1:
		active_side = mine[at + 1]
		brush_unit = ""
		_populate_palette()
		_status.text = ""
		_refresh_labels()
		queue_redraw()
		return
	var sent_sides: Array = []
	var ready_sides: Array = []
	if _mirrored_guest():
		# Армия гостя уже на месте — от хоста; едет только готовность.
		ready_sides.append(_my_side)
	else:
		sent_sides.append_array(mine)
		ready_sides.append_array(mine)
	# Зеркальная партия (batch 12 #12): хост отражает свою формацию во ВСЕ остальные зоны
	# — и гостям, и ИИ — и шлёт всё одним пакетом. За ИИ он же и подтверждает готовность;
	# гости подтверждают свою сами, когда увидят отражение.
	if networked() and _net_is_host \
			and GameConfig.placement_mode == GameConfig.Placement.MIRRORED:
		_refresh_mirrors()  # отражения уже стоят живьём (batch 13 #13) — только освежить
		for side in _sides():
			if side == _my_side:
				continue
			sent_sides.append(side)
			if roster.is_ai(side):
				ready_sides.append(side)
	_my_ready = true
	var msg := {"k": K_ROSTER, "u": _encode_roster(sent_sides), "sides": sent_sides,
		"ready": ready_sides}
	if _net_is_host:
		msg["seed"] = _shared_seed
	_net.send(msg)
	for side in ready_sides:
		_ready_sides[side] = true
	_status.text = "Waiting for the other players..."
	_refresh_labels()
	_try_start()

## Отправить свою расстановку «вживую» (batch 12 #15) — если хост это разрешил.
func _send_live() -> void:
	if not networked() or _net == null or _my_ready or not GameConfig.live_placement_visible:
		return
	var mine := _host_sides()
	# Зеркальный хост шлёт и отражения (batch 13 #13): гость видит свою армию живьём.
	if _mirrors_live() and _net_is_host:
		mine = _sides()
	_net.send({"k": K_LIVE, "u": _encode_roster(mine), "sides": mine})

func _load_or_blank_map() -> MapData:
	# Сетевая партия играется на карте ХОСТА, пришедшей целиком (#99) — у клиента
	# такого файла может и не быть, а поле обязано совпасть до клетки.
	var shared := NetHandoff.take_lobby_map()
	if shared != null:
		return shared
	if GameConfig.map_path != "":
		var m := MapData.load_from(GameConfig.map_path)
		if m != null:
			return m
	# Демо/без карты: пустая твёрдая арена, чтобы было куда ставить.
	return MapData.blank_arena()

# --- Данные юнитов ---
func _stats(id: String) -> UnitStats:
	if _stats_cache.has(id):
		return _stats_cache[id]
	var path := "res://src/data/units/%s.tres" % id
	var s: UnitStats = load(path) if ResourceLoader.exists(path) else null
	_stats_cache[id] = s
	return s

## Действующий бюджет стороны (item 40): 0 = безлимит. «Свободная расстановка» снимает
## лимит либо со всех, либо с одного выбранного хостом игрока (GameConfig.unlimited_for).
func _effective_budget(side: int) -> int:
	if GameConfig.unlimited_for(side):
		return 0
	# Личный бюджет игрока из ростера (item 1); 0 = безлимит; иначе общий бюджет партии.
	if roster != null and roster.slot(side) != null and roster.slot(side).budget > 0:
		return roster.slot(side).budget
	return budget

## Разрешён ли юнит активной стороне к покупке (item 2): сперва личное ограничение
## слота, затем общее (GameConfig), иначе можно.
func _unit_allowed_for_active(id: String) -> bool:
	if roster != null and roster.slot(active_side) != null \
			and not roster.slot(active_side).allowed_units.is_empty():
		return roster.slot(active_side).unit_allowed(id)
	return GameConfig.unit_allowed(id)

func _cost(id: String) -> int:
	if VehicleDB.is_vehicle(id):
		return VehicleDB.buy_cost(id)
	var s := _stats(id)
	return s.cost if s != null else 0

func _display_name(id: String) -> String:
	if VehicleDB.is_vehicle(id):
		return String(VehicleDB.get_vehicle(id).get("name", id))
	var s := _stats(id)
	return s.display_name if s != null else id

## След предмета расстановки: техника занимает несколько клеток, пехота — одну (#10).
func _footprint(id: String, coord: Vector2i) -> Array:
	var out: Array = []
	var size := VehicleDB.size_of(id) if VehicleDB.is_vehicle(id) else Vector2i.ONE
	for dy in size.y:
		for dx in size.x:
			out.append(coord + Vector2i(dx, dy))
	return out

## Все клетки следа свободны, в границах и внутри зоны развёртывания стороны.
func _footprint_placeable(id: String, coord: Vector2i, side: int) -> bool:
	for c in _footprint(id, coord):
		if not _cell_placeable(c) or not _in_zone(c, side):
			return false
	return true

# --- Зона развёртывания (§ свободная расстановка). ---
## Размечены ли на карте зоны хотя бы одной ИГРОВОЙ стороны. Нейтральная разметка
## сама по себе зоной высадки не считается: жилой квартал — не плацдарм.
func _map_defines_zones() -> bool:
	for z in map.zone_owner:
		if MCF.is_player(z):
			return true
	return false

## Стороны партии в порядке расстановки.
func _sides() -> Array[int]:
	var ids := roster.player_ids()
	return ids if not ids.is_empty() else [MCF.Owner.PLAYER_1, MCF.Owner.PLAYER_2]

## Карта со своей разметкой играется по ней; иначе — старое правило половинок:
## P1 слева, P2 справа. Нейтральные клетки не подходят никому, поэтому мирные
## кварталы остаются недоступны обоим игрокам.
## Карта со своей разметкой играется по ней; иначе поле делится на вертикальные
## полосы по числу сторон. На двоих это ровно прежнее правило половинок (P1 слева,
## P2 справа) — просто записанное так, чтобы работать и на троих, и на шестерых.
func _in_zone(coord: Vector2i, side: int) -> bool:
	if _map_zones:
		return map.get_zone(coord) == _zone_of(side)
	var band := _zone_band(side)
	return coord.x >= band.x and coord.x < band.y

## Нарисованная на карте зона стороны. Слот может быть посажен в ЛЮБУЮ зону (item 10):
## сверяем с его назначенной зоной, а не жёстко с номером стороны.
func _zone_of(side: int) -> int:
	if roster != null and roster.slot(side) != null:
		return roster.slot(side).zone()
	return side

## Без зон на карте поле делится на вертикальные полосы: [x, y) — столбцы стороны.
## Полоса стороны на карте без зон: выбранная в лобби зона (item 22: раньше выбор здесь
## молча игнорировался), а без выбора — по порядку стороны.
func _zone_band(side: int) -> Vector2i:
	var sides := _sides()
	var order := sides.find(side)
	if order < 0:
		return Vector2i.ZERO
	var slot := roster.slot(side) if roster != null else null
	var index := slot.deploy_zone if slot != null and slot.deploy_zone >= 0 else order
	return MapData.band_of(index, sides.size(), map.width)

func _cell_placeable(coord: Vector2i) -> bool:
	if not map.in_bounds(coord):
		return false
	if map.get_space(coord):
		return false
	if map.get_cover(coord) >= MCF.WALL_HEIGHT:
		return false
	# Объект-препятствие (кроме мягких укрытий) не мешает — но занятые клетки нельзя.
	return _placed_at(coord) == -1 and _neutral_at(coord) == -1

## Контекстное меню поворота танка (item 6/2): четыре стороны света, выбор ставит фронт.
func _open_tank_dir_menu(vi: int, screen_pos: Vector2) -> void:
	var menu := PopupMenu.new()
	var names := ["East →", "South ↓", "West ←", "North ↑"]
	for i in FACING4.size():
		menu.add_item(names[i], i)
	menu.id_pressed.connect(func(id: int) -> void:
		placed[vi]["facing"] = FACING4[id]
		_status.text = "Rotated the %s (free)." % _display_name(placed[vi]["stats_id"])
		_placement_changed()
		menu.queue_free())
	menu.close_requested.connect(func() -> void: menu.queue_free())
	add_child(menu)
	menu.position = Vector2i(screen_pos) + Vector2i(get_window().position)
	menu.popup()

func _placed_at(coord: Vector2i) -> int:
	for i in placed.size():
		if _footprint(placed[i]["stats_id"], placed[i]["coord"]).has(coord):
			return i
	return -1

func _neutral_at(coord: Vector2i) -> int:
	for i in preserved_neutral.size():
		if preserved_neutral[i]["coord"] == coord:
			return i
	return -1

# --- Ввод ---
## Небо за доской (0.9.3): клетки космоса не рисуются, и в прорехах виден параллакс
## звёзд — тот же, что в главном меню и в бою. Карте без космоса оно не нужно.
var _sky: Starfield = null

## Камера на свою зону развёртывания (0.9.3). Раньше экран открывался в углу доски, и
## углом карты был её угол; теперь там кайма — десяток клеток пустой земли или космоса.
func _home_view() -> void:
	var cells: Array = map.zone_cells(active_side)
	var centre := Vector2.ZERO
	if cells.is_empty():
		centre = Vector2(map.width, map.height) * 0.5
	else:
		for c: Vector2i in cells:
			centre += Vector2(c)
		centre /= float(cells.size())
	pan = get_viewport_rect().size * 0.5 - zoom * (_cell_origin(Vector2i(centre)) \
			+ Vector2(CELL, CELL) * 0.5)
	queue_redraw()

func _build_sky() -> void:
	if map == null or not map.is_space.has(1):
		return
	var layer := CanvasLayer.new()
	layer.layer = -10
	add_child(layer)
	_sky = Starfield.new()
	_sky.drift = false
	layer.add_child(_sky)

func _process(delta: float) -> void:
	# Строка состояния — рамкой набора; пустая рамка без сообщения ни к чему.
	if _status != null:
		_status.visible = _status.text != ""
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): dir.y += 1
	if Input.is_key_pressed(KEY_S): dir.y -= 1
	if Input.is_key_pressed(KEY_A): dir.x += 1
	if Input.is_key_pressed(KEY_D): dir.x -= 1
	if dir != Vector2.ZERO:
		pan += dir.normalized() * PAN_SPEED * delta
		queue_redraw()

## Четыре направления фронта — для бесплатного поворота танка на закупке (item 21).
## Диагонали убраны (item 2): танк смотрит только по сторонам света.
const FACING4 := [Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0), Vector2i(0,-1)]

## Направление фронта поставленной машины (item 21); по умолчанию — «в глубину поля»
## от своей стороны. Пехоте фронт не нужен и не хранится.
func _placed_facing(rec: Dictionary) -> Vector2i:
	if rec.has("facing"):
		return rec["facing"]
	return Vector2i(1, 0) if int(rec["owner"]) == _sides()[0] else Vector2i(-1, 0)

func _unhandled_input(event: InputEvent) -> void:
	# Поворот танка под курсором на месте, бесплатно (item 21): клавиша R / Q / E.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode in [KEY_R, KEY_Q, KEY_E]:
		var cur := _pos_to_cell(get_global_mouse_position())
		var vi := _placed_at(cur)
		if vi != -1 and not _ready_locked() and VehicleDB.is_vehicle(placed[vi]["stats_id"]) \
				and bool(VehicleDB.get_vehicle(placed[vi]["stats_id"]).get("has_facing", false)):
			var cur_face := _placed_facing(placed[vi])
			var idx := FACING4.find(cur_face)
			if idx == -1:
				idx = 0
			var step := -1 if event.keycode == KEY_Q else 1
			placed[vi]["facing"] = FACING4[(idx + step + FACING4.size()) % FACING4.size()]
			_status.text = "Rotated the %s (free)." % _display_name(placed[vi]["stats_id"])
			_placement_changed()
		return
	# Ввод над палитрой принадлежит панели — не панорамируем/зумим/ставим под ней.
	if event is InputEventMouseButton and _pointer_over_panel(event.position):
		return
	# ПКМ по поставленному танку — контекстное меню поворота (item 6). Иначе ПКМ панорамит.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var rc := _pos_to_cell(get_global_mouse_position())
		var rvi := _placed_at(rc)
		if rvi != -1 and not _ready_locked() and VehicleDB.is_vehicle(placed[rvi]["stats_id"]) \
				and bool(VehicleDB.get_vehicle(placed[rvi]["stats_id"]).get("has_facing", false)):
			_open_tank_dir_menu(rvi, event.position)
			return
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		_mouse_panning = event.pressed
		return
	if event is InputEventMouseMotion and _mouse_panning:
		pan += event.relative
		queue_redraw()
		return
	# Масштаб как в бою (#9): колесо мыши и щипок тачпада, сохраняя точку под курсором.
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
	if event is InputEventPanGesture:
		pan -= event.delta * 24.0
		queue_redraw()
		return
	# Сданную армию не правят (playtest-20): правка не ушла бы соперникам, и бой начался бы
	# с разными армиями. Сначала Unready.
	if _ready_locked():
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_status.text = "You're ready — press Unready to change your army."
		return
	# Инструменты-формы (item 12): линия/прямоугольник/круг тянутся от нажатия к
	# отпусканию, заливка ставит всю зону одним кликом. Точка — прежнее перетаскивание.
	if _ptool != PTool.POINT:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if _ptool == PTool.FILL:
					if _erasing:
						_erase_many(_zone_cells(active_side))
					else:
						_place_many(_zone_cells(active_side))
				else:
					_shape_start = _pos_to_cell(get_global_mouse_position())
					_shape_cur = _shape_start
			elif _shape_start != Vector2i(-9999, -9999):
				if _erasing:
					_erase_many(_shape_cells(_shape_start, _shape_cur))
				else:
					_place_many(_shape_cells(_shape_start, _shape_cur))
				_shape_start = Vector2i(-9999, -9999)
			return
		if event is InputEventMouseMotion and _shape_start != Vector2i(-9999, -9999):
			_shape_cur = _pos_to_cell(get_global_mouse_position())
			queue_redraw()
			return
		return
	# Расстановка перетаскиванием (#11): зажать ЛКМ и вести мышью — красим клетки.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_painting = true
			_paint_last = _pos_to_cell(get_global_mouse_position())
			if _erasing:
				_erase_at(_paint_last)
			else:
				_click_cell(_paint_last)
		else:
			_painting = false
		return
	if event is InputEventMouseMotion and _painting:
		var cell := _pos_to_cell(get_global_mouse_position())
		if cell != _paint_last:
			_paint_last = cell
			if _erasing:
				_erase_at(cell)
			else:
				_paint_at(cell)
		return

## Под курсором ли панель палитры (#9/#11): её ввод не трогает поле/камеру.
func _pointer_over_panel(pos: Vector2) -> bool:
	return (_panel != null and _panel.get_global_rect().has_point(pos)) \
			or (_chat_win != null and _chat_win.get_global_rect().has_point(pos))

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var new_zoom: float = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_zoom, zoom):
		return
	var local := (screen_pos - pan) / zoom
	zoom = new_zoom
	pan = screen_pos - local * zoom
	queue_redraw()

## Красим клетку при перетаскивании — только СТАВИМ (не возвращаем), чтобы протяжка
## по своим юнитам их не снимала (#11).
## Зеркальная расстановка (item 39): не-хост не расставляет свободно — только «штампует»
## формацию хоста. В этот момент кисть и перетаскивание для него заблокированы.
func _mirror_locked() -> bool:
	if _mirrored_guest():
		return true
	return GameConfig.placement_mode == GameConfig.Placement.MIRRORED \
			and not _sides().is_empty() and active_side != _sides()[0]

## Зеркало живёт само (batch 13 #13): кнопки «Stamp Formation» больше нет. Каждое
## изменение отряда первой стороны тут же отражается во ВСЕ остальные зоны — и в
## хот-сите, и по сети (хост шлёт копии вживую, гости видят свою армию по мере того, как
## хост её собирает). Копии помечены mirror и пересобираются с нуля при каждом изменении,
## поэтому снятый юнит хоста исчезает и из отражений.
func _mirrors_live() -> bool:
	return GameConfig.placement_mode == GameConfig.Placement.MIRRORED \
			and not _mirrored_guest() and not _sides().is_empty()

func _refresh_mirrors() -> void:
	if not _mirrors_live():
		return
	var source: int = _sides()[0]
	var kept: Array = []
	for p in placed:
		if not bool(p.get("mirror", false)):
			kept.append(p)
	placed = kept
	var skipped := 0
	for side in _sides():
		if side == source:
			continue
		var res := _stamp_into(side)
		skipped += int(res["skipped"])
	# О пропущенных сообщаем ЯВНО: молчаливая недостача — это ровно то, из-за чего
	# пропажу танков пришлось ловить в бою, а не на расстановке.
	if skipped > 0 and _status != null:
		_status.text = "%d mirrored unit(s) don't fit the other zone(s)." % skipped

## Единая точка «отряд изменился»: зеркала, подписи, показ, живая рассылка.
func _placement_changed() -> void:
	_refresh_mirrors()
	_refresh_labels()
	queue_redraw()
	_send_live()

## Отражение формации первой стороны в зону target (batch 12 #12): одна функция и для
## хот-сита, и для авто-штампа хоста по сети. У КАЖДОГО игрока — та же армия.
##
## Раньше формация поворачивалась на 180° вокруг центра карты — и это верно лишь для зон
## строго напротив друг друга. Зоны слева и справа на одной высоте, четыре четверти, трое
## игроков — копии улетали мимо чужой зоны и молча пропускались: у соперника оказывалось
## меньше бойцов, а то и ни одного. Теперь перенос подбирается под пару зон (_zone_transform):
## симметрия самой карты, если она переводит зону хоста ровно в зону target, иначе — лучшее
## наложение зон лицом к центру. Бойцу, чьё место занято или вне зоны, ищется ближайшая
## свободная клетка той же зоны: армии одинаковы по составу всегда, по расстановке — насколько
## позволяет карта.
func _stamp_into(target: int) -> Dictionary:
	var host: int = _sides()[0]
	var xf := _zone_transform(host, target)
	var l: Array = xf["l"]
	var t: Vector2i = xf["t"]
	var occ := {}
	for p in placed:
		for c in _footprint(p["stats_id"], p["coord"]):
			occ[c] = true
	for n in preserved_neutral:
		occ[n["coord"]] = true
	var zone := _zone_cells_of(target)
	var added := 0
	var skipped := 0
	for p in placed.duplicate():
		if int(p["owner"]) != host:
			continue
		var id := String(p["stats_id"])
		# Отражается ВЕСЬ СЛЕД, а не одна клетка (item 8): координата записи — левый верхний
		# угол следа, и после отражения угол — это минимум образов всех его клеток.
		var dst := Vector2i(1 << 30, 1 << 30)
		for c: Vector2i in _footprint(id, p["coord"]):
			var q := _apply_xf(l, t, c)
			dst = Vector2i(mini(dst.x, q.x), mini(dst.y, q.y))
		if not _fits(id, dst, target, occ):
			dst = _nearest_fit(id, dst, target, occ, zone)
		if dst.x < 0:
			skipped += 1
			continue
		var rec := {"stats_id": id, "owner": target,
				"coord": dst, "paid_by": target, "mirror": true}
		# Фронт машины поворачивается вместе с формацией — иначе копия встала бы стволом в тыл.
		if VehicleDB.is_vehicle(id) \
				and bool(VehicleDB.get_vehicle(id).get("has_facing", false)):
			var f := _placed_facing(p)
			rec["facing"] = Vector2i(l[0] * f.x + l[1] * f.y, l[2] * f.x + l[3] * f.y)
		placed.append(rec)
		for c in _footprint(id, dst):
			occ[c] = true
		added += 1
	return {"added": added, "skipped": skipped}

## Восемь движений квадрата: (x, y) → (a·x + b·y, c·x + d·y). Тождество, повороты на 90°,
## 180°, 270°, отражения по вертикали, по горизонтали и по двум диагоналям.
const DIHEDRAL := [[1, 0, 0, 1], [0, -1, 1, 0], [-1, 0, 0, -1], [0, 1, -1, 0],
		[-1, 0, 0, 1], [1, 0, 0, -1], [0, 1, 1, 0], [0, -1, -1, 0]]
var _xf_cache := {}
var _zone_cache := {}
var _zone_edges := {}   # side -> [[from, to], …] — границы зоны в клетках

## Отрезки границы зоны: сторона клетки зоны, за которой уже не зона.
func _zone_edges_of(side: int) -> Array:
	if _zone_edges.has(side):
		return _zone_edges[side]
	var inside := {}
	for c: Vector2i in _zone_cells_of(side):
		inside[c] = true
	var out: Array = []
	for c: Vector2i in inside:
		var p := Vector2(c)
		if not inside.has(c + Vector2i.UP):
			out.append([p, p + Vector2(1, 0)])
		if not inside.has(c + Vector2i.DOWN):
			out.append([p + Vector2(0, 1), p + Vector2(1, 1)])
		if not inside.has(c + Vector2i.LEFT):
			out.append([p, p + Vector2(0, 1)])
		if not inside.has(c + Vector2i.RIGHT):
			out.append([p + Vector2(1, 0), p + Vector2(1, 1)])
	_zone_edges[side] = out
	return out
var _sym_cache := {}

func _apply_xf(l: Array, t: Vector2i, c: Vector2i) -> Vector2i:
	return Vector2i(l[0] * c.x + l[1] * c.y, l[2] * c.x + l[3] * c.y) + t

## Клетки зоны стороны (по _in_zone — с полосами, если зон на карте нет).
func _zone_cells_of(side: int) -> Array[Vector2i]:
	if _zone_cache.has(side):
		return _zone_cache[side]
	var out: Array[Vector2i] = []
	for y in map.height:
		for x in map.width:
			if _in_zone(Vector2i(x, y), side):
				out.append(Vector2i(x, y))
	_zone_cache[side] = out
	return out

## Как переносится зона хоста в зону target: {l: движение, t: сдвиг}.
##
## 1. Симметрия САМОЙ КАРТЫ (движение вокруг её центра, при котором рельеф совпадает клетка
##    в клетку), переводящая зону хоста ровно в зону target, — тогда у каждого та же
##    местность вокруг тех же бойцов. Зеркальные карты генератора и честные стоковые карты
##    такую имеют; повороты на 90° и диагонали — только у квадратного поля.
## 2. Иначе — движение со сдвигом центра зоны в центр зоны, при котором зоны перекрываются
##    больше всего; при равенстве — то, что разворачивает формацию лицом к центру карты.
func _zone_transform(host: int, target: int) -> Dictionary:
	var key := Vector2i(host, target)
	if _xf_cache.has(key):
		return _xf_cache[key]
	var src := _zone_cells_of(host)
	var dst := _zone_cells_of(target)
	var inside := {}
	for c in dst:
		inside[c] = true
	var result := {"l": DIHEDRAL[2], "t": Vector2i(map.width - 1, map.height - 1)}
	if src.is_empty() or dst.is_empty():
		_xf_cache[key] = result
		return result
	var w := map.width - 1
	var h := map.height - 1
	var found := false
	for l: Array in DIHEDRAL.slice(1):
		if l[1] != 0 and map.width != map.height:
			continue   # поворот на 90° и диагональ меняют стороны местами — только квадрат
		var t := Vector2i(w, h) - Vector2i(l[0] * w + l[1] * h, l[2] * w + l[3] * h)
		t = Vector2i(t.x / 2, t.y / 2)
		if src.size() != dst.size():
			break
		var all := true
		for c in src:
			if not inside.has(_apply_xf(l, t, c)):
				all = false
				break
		if all and _map_symmetric(l, t):
			result = {"l": l, "t": t}
			found = true
			break
	if not found:
		var cs := Vector2.ZERO
		for c in src:
			cs += Vector2(c)
		cs /= src.size()
		var cd := Vector2.ZERO
		for c in dst:
			cd += Vector2(c)
		cd /= dst.size()
		var mid := Vector2(w, h) * 0.5
		var best := -1
		var best_face := -INF
		for l: Array in DIHEDRAL:
			var lc := Vector2(l[0] * cs.x + l[1] * cs.y, l[2] * cs.x + l[3] * cs.y)
			var t := Vector2i((cd - lc).round())
			var score := 0
			for c in src:
				if inside.has(_apply_xf(l, t, c)):
					score += 1
			var fwd := mid - cs
			var face := Vector2(l[0] * fwd.x + l[1] * fwd.y, l[2] * fwd.x + l[3] * fwd.y) \
					.normalized().dot((mid - cd).normalized())
			if score > best or (score == best and face > best_face):
				best = score
				best_face = face
				result = {"l": l, "t": t}
	_xf_cache[key] = result
	return result

## Совпадает ли рельеф карты со своим образом при движении (l, t).
func _map_symmetric(l: Array, t: Vector2i) -> bool:
	var key := str(l) + str(t)
	if _sym_cache.has(key):
		return _sym_cache[key]
	var ok := true
	for y in map.height:
		for x in map.width:
			var c := Vector2i(x, y)
			var q := _apply_xf(l, t, c)
			if not map.in_bounds(q) or map.get_feature(c) != map.get_feature(q) \
					or map.get_space(c) != map.get_space(q) or map.get_floor(c) != map.get_floor(q):
				ok = false
				break
		if not ok:
			break
	_sym_cache[key] = ok
	return ok

## Весь след предмета — в зоне стороны, на проходимой земле и не на чужом месте (occ).
func _fits(id: String, coord: Vector2i, side: int, occ: Dictionary) -> bool:
	for c in _footprint(id, coord):
		if not map.in_bounds(c) or occ.has(c) or map.get_space(c) \
				or map.get_cover(c) >= MCF.WALL_HEIGHT or not _in_zone(c, side):
			return false
	return true

## Ближайшая к want клетка зоны, куда предмет встаёт целиком; (-1, -1) — места нет.
func _nearest_fit(id: String, want: Vector2i, side: int, occ: Dictionary,
		zone: Array[Vector2i]) -> Vector2i:
	var order := zone.duplicate()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a).distance_squared_to(Vector2(want)) < Vector2(b).distance_squared_to(Vector2(want)))
	for c: Vector2i in order:
		if _fits(id, c, side, occ):
			return c
	return Vector2i(-1, -1)

func _paint_at(coord: Vector2i) -> void:
	if _mirror_locked() or brush_unit == "" or _placed_at(coord) != -1:
		return
	if not _footprint_placeable(brush_unit, coord, active_side):
		return
	var c := _cost(brush_unit)
	var eb := _effective_budget(active_side)
	if eb > 0 and spent[active_side] + c > eb:
		return
	placed.append({"stats_id": brush_unit, "owner": active_side,
			"coord": coord, "paid_by": active_side})
	spent[active_side] += c
	_placement_changed()

func _paid_by(rec: Dictionary) -> int:
	return int(rec.get("paid_by", rec["owner"]))

func _select_tool(t: int) -> void:
	_ptool = t
	_shape_start = Vector2i(-9999, -9999)
	for k: int in _tool_buttons:
		(_tool_buttons[k] as Button).button_pressed = k == t
	queue_redraw()

# --- Инструменты-формы (item 12) ---
## Клетки выбранной формы между a и b.
func _shape_cells(a: Vector2i, b: Vector2i) -> Array:
	match _ptool:
		PTool.LINE: return _line_cells(a, b)
		PTool.RECT: return _rect_fill_cells(a, b)
		PTool.CIRCLE: return _disk_cells(a, b)
	return []

func _line_cells(a: Vector2i, b: Vector2i) -> Array:
	var cells: Array = []
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var x := a.x
	var y := a.y
	while true:
		cells.append(Vector2i(x, y))
		if x == b.x and y == b.y:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy
	return cells

## Сплошной прямоугольник (не рамка) — на закупке важнее заполнить блок бойцами.
func _rect_fill_cells(a: Vector2i, b: Vector2i) -> Array:
	var cells: Array = []
	for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			cells.append(Vector2i(x, y))
	return cells

## Сплошной круг с центром a и радиусом до b.
func _disk_cells(a: Vector2i, b: Vector2i) -> Array:
	var cells: Array = []
	var r := int(round(Vector2(b - a).length()))
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy <= r * r:
				cells.append(a + Vector2i(dx, dy))
	return cells

## Все клетки зоны развёртывания стороны — для заливки.
func _zone_cells(side: int) -> Array:
	var cells: Array = []
	for y in map.height:
		for x in map.width:
			var c := Vector2i(x, y)
			if _in_zone(c, side):
				cells.append(c)
	return cells

## Поставить выбранного юнита во все указанные клетки, где это возможно (зона, бюджет,
## проходимость, свободно). Одна операция — один пересчёт меток.
func _place_many(cells: Array) -> void:
	if _mirror_locked():
		_status.text = "Mirrored placement: the host's formation is mirrored into your zone automatically."
		return
	if brush_unit == "":
		_status.text = "Pick a unit from the palette first."
		return
	var cost := _cost(brush_unit)
	var eb := _effective_budget(active_side)
	var added := 0
	for coord: Vector2i in cells:
		if _placed_at(coord) != -1:
			continue
		if not _footprint_placeable(brush_unit, coord, active_side):
			continue
		if eb > 0 and spent[active_side] + cost > eb:
			break
		placed.append({"stats_id": brush_unit, "owner": active_side,
				"coord": coord, "paid_by": active_side})
		spent[active_side] += cost
		added += 1
	_status.text = "Deployed %d %s." % [added, _display_name(brush_unit)]
	_placement_changed()

## Ластик (batch 13 #5): снять своего юнита с клетки и вернуть очки. Чужих и зеркальных
## копий не трогает. Возвращает true, если что-то снял.
func _erase_at(coord: Vector2i) -> bool:
	var idx := _placed_at(coord)
	if idx == -1:
		return false
	if _paid_by(placed[idx]) != active_side or bool(placed[idx].get("mirror", false)):
		return false
	spent[active_side] -= _cost(placed[idx]["stats_id"])
	placed.remove_at(idx)
	_placement_changed()
	return true

func _erase_many(cells: Array) -> void:
	var removed := 0
	for coord: Vector2i in cells:
		if _erase_at(coord):
			removed += 1
	_status.text = "Removed %d unit(s)." % removed
	_refresh_labels()
	queue_redraw()

func _toggle_eraser(on: bool) -> void:
	_erasing = on
	if on:
		# Ластик и кисть взаимоисключающи: выбранный юнит гаснет в палитре.
		brush_unit = ""
		for bid in _palette_buttons:
			_palette_buttons[bid].button_pressed = false
		_status.text = "Eraser: click or drag over your units to remove them; shapes erase their whole area."
	else:
		_status.text = ""
	queue_redraw()

func _click_cell(coord: Vector2i) -> void:
	# Клик по своему расставленному юниту — снять и вернуть очки.
	var idx := _placed_at(coord)
	if idx != -1:
		if _paid_by(placed[idx]) == active_side and not bool(placed[idx].get("mirror", false)):
			spent[active_side] -= _cost(placed[idx]["stats_id"])
			placed.remove_at(idx)
			_placement_changed()
		elif bool(placed[idx].get("mirror", false)):
			_status.text = "That's a mirrored copy — remove the original instead."
		else:
			_status.text = "That unit belongs to the other side."
		return
	# Иначе — поставить выбранного юнита/технику.
	if _mirror_locked():
		_status.text = "Mirrored placement: the host's formation is mirrored into your zone automatically."
		return
	if brush_unit == "":
		_status.text = "Pick a unit from the palette first."
		return
	if not _footprint_placeable(brush_unit, coord, active_side):
		_status.text = "Can't deploy there — blocked or outside your zone."
		return
	var c := _cost(brush_unit)
	# Бюджет <= 0 — безлимит (§Setup «0 = unlimited»); иначе соблюдаем заданный предел.
	var eb := _effective_budget(active_side)
	if eb > 0 and spent[active_side] + c > eb:
		_status.text = "Not enough points (need %d, have %d)." % [c, eb - spent[active_side]]
		return
	placed.append({"stats_id": brush_unit, "owner": active_side,
			"coord": coord, "paid_by": active_side})
	spent[active_side] += c
	_placement_changed()

# --- Геометрия (локальные координаты; pan/zoom добавляет draw_set_transform) ---
func _cell_origin(coord: Vector2i) -> Vector2:
	return ORIGIN + Vector2(coord.x * CELL, coord.y * CELL)

func _pos_to_cell(pos: Vector2) -> Vector2i:
	var local := (pos - pan) / zoom - ORIGIN
	return Vector2i(floori(local.x / CELL), floori(local.y / CELL))

# --- Рендер ---
func _draw() -> void:
	if map == null:
		return
	draw_set_transform(pan, 0.0, Vector2(zoom, zoom))
	Sprites.set_base_transform(pan, Vector2(zoom, zoom))
	var font := ThemeDB.fallback_font
	# Поле рисуется ТЕМИ ЖЕ спрайтами и цветами, что и в бою (#100): раньше расстановка
	# показывала лишь серые квадраты, и игрок расставлял отряд вслепую — мешки, окопы,
	# шлюзы и ДОТы проявлялись только после старта. Логика повторяет проход Main._draw().
	# И так же — только клетки на экране: на карте 250×250 полный проход — 62 500 клеток
	# на КАЖДЫЙ кадр, а кадр здесь перерисовывается на каждое движение мыши.
	# Слои карты читаются напрямую, а зона стороны считается раз на кадр, не на клетку.
	var tl := _pos_to_cell(Vector2.ZERO)
	var br := _pos_to_cell(get_viewport_rect().size)
	var vx0 := clampi(tl.x - 1, 0, map.width - 1)
	var vx1 := clampi(br.x + 1, 0, map.width - 1)
	var vy0 := clampi(tl.y - 1, 0, map.height - 1)
	var vy1 := clampi(br.y + 1, 0, map.height - 1)
	# Рельеф и объекты — плитками TerrainTiles на слое под нами (items 1/9): раньше каждая
	# видимая клетка рисовалась заново на КАЖДЫЙ кадр — пол, тон укрытия, объект с подписью
	# и подсветка зоны, — и на карте шести игроков с отъездом это были десятки тысяч
	# примитивов на любое движение мыши. Рельеф на расстановке не меняется: куски
	# собираются один раз.
	if _tile_layer == null:
		var g := Grid.new(map.width, map.height)
		map.apply_to_grid(g)
		_tile_layer = TerrainTiles.Layer.new()
		_tile_layer.tiles = TerrainTiles.new(g, map.environment())
		_tile_layer.origin = ORIGIN
		_tile_layer.cell_size = CELL
		_tile_grid = g
		add_child(_tile_layer)
	_tile_layer.position = pan
	if _sky != null:
		_sky.camera = pan   # параллакс за доской (0.9.3) — см. Main._build_sky
	_tile_layer.scale = Vector2(zoom, zoom)
	_tile_layer.cells = Rect2i(vx0, vy0, vx1 - vx0, vy1 - vy0)
	# Сетка — в слое плиток, между полом и объектами: стену или стол в несколько клеток
	# она не режет на куски.
	_tile_layer.grid_color = Color(0.25, 0.27, 0.32)
	_tile_layer.queue_redraw()
	# Подсветка зоны развёртывания активной стороны — только клетки самой зоны.
	var zone_col := Color(_side_color(active_side), 0.10)
	for zc: Vector2i in _zone_cells_of(active_side):
		if zc.x < vx0 or zc.x > vx1 or zc.y < vy0 or zc.y > vy1:
			continue
		var zcell := _tile_grid.cell_fast(zc.x, zc.y)
		if not zcell.is_space and zcell.cover_height < MCF.WALL_HEIGHT:
			draw_rect(Rect2(_cell_origin(zc), Vector2(CELL, CELL)), zone_col)
	# Контур своей зоны (gore batch): тонкая линия цвета стороны по её границе — поверх
	# сетки, чтобы зону было видно и там, где заливка теряется на пёстром полу.
	var edge_col := Color(_side_color(active_side), 0.9)
	for seg: Array in _zone_edges_of(active_side):
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		if maxf(a.x, b.x) < vx0 or minf(a.x, b.x) > vx1 + 1 or maxf(a.y, b.y) < vy0 or minf(a.y, b.y) > vy1 + 1:
			continue
		draw_line(ORIGIN + a * CELL, ORIGIN + b * CELL, edge_col, 2.0)
	# Сохранённые мирные.
	for s in preserved_neutral:
		_draw_token(s["coord"], MCF.Owner.NEUTRAL, s["stats_id"], font)
	# Чужие армии (batch 12 #12/#15): присланные готовыми — как свои; собираемые
	# «вживую» — с тенью, они ещё могут измениться.
	for side in _remote_units:
		if _placed_here(int(side)):
			continue
		for e in _remote_units[side]:
			_draw_token(Vector2i(int(e["x"]), int(e["y"])), int(e["o"]), str(e["id"]), font)
	for side in _live_units:
		if _remote_units.has(side) or _placed_here(int(side)):
			continue
		for e in _live_units[side]:
			var c := Vector2i(int(e["x"]), int(e["y"]))
			_draw_token(c, int(e["o"]), str(e["id"]), font)
			draw_rect(Rect2(_cell_origin(c), Vector2(CELL, CELL)), Color(0, 0, 0, 0.35))
	# Расставленные юниты.
	for p in placed:
		_draw_token(p["coord"], int(p["owner"]), p["stats_id"], font)
		# Стрелка фронта танка (item 21): показывает, куда он смотрит, — крутится клавишей R.
		# Якорь в НИЖНЕМ ЛЕВОМ углу следа (item 3): раньше стрелка шла из центра и
		# перекрывала корпус/инициалы; теперь компактный указатель сидит в углу.
		if VehicleDB.is_vehicle(p["stats_id"]) \
				and bool(VehicleDB.get_vehicle(p["stats_id"]).get("has_facing", false)):
			var vsize := VehicleDB.size_of(p["stats_id"])
			var vorigin := _cell_origin(p["coord"])
			var corner := vorigin + Vector2(CELL * 0.28, vsize.y * CELL - CELL * 0.28)
			var fdir := Vector2(_placed_facing(p)).normalized()
			var alen := CELL * 0.4
			var tip := corner + fdir * alen
			draw_line(corner, tip, Color.WHITE, 3.0)
			var perp := Vector2(-fdir.y, fdir.x) * (CELL * 0.12)
			draw_colored_polygon(PackedVector2Array([
				tip, tip - fdir * (CELL * 0.18) + perp, tip - fdir * (CELL * 0.18) - perp]), Color.WHITE)
	# Предпросмотр формы-инструмента (item 12): куда ляжет линия/прямоугольник/круг.
	if _ptool != PTool.POINT and _shape_start != Vector2i(-9999, -9999):
		for sc: Vector2i in _shape_cells(_shape_start, _shape_cur):
			var col: Color
			if _erasing:
				col = Color(0.95, 0.35, 0.25, 0.4) if _placed_at(sc) != -1 else Color(0.9, 0.3, 0.2, 0.15)
			else:
				col = Color(0.35, 0.85, 0.5, 0.35) if _footprint_placeable(brush_unit, sc, active_side) \
					else Color(0.9, 0.3, 0.2, 0.25)
			draw_rect(Rect2(_cell_origin(sc), Vector2(CELL, CELL)), col)

func _draw_token(coord: Vector2i, owner: int, stats_id: String, font: Font) -> void:
	# Техника (#10) рисуется прямоугольником по всему следу.
	if VehicleDB.is_vehicle(stats_id):
		var size := VehicleDB.size_of(stats_id)
		var rect := Rect2(_cell_origin(coord) + Vector2(3, 3),
			Vector2(size.x * CELL - 6, size.y * CELL - 6))
		draw_rect(rect, Color(_side_color(owner), 0.85))
		draw_rect(rect, Color(0, 0, 0, 0.7), false, 2.0)
		var vname := String(VehicleDB.get_vehicle(stats_id).get("name", "??"))
		draw_string(font, rect.position + Vector2(6, 22), _initials(vname),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, _ink(_side_color(owner)))
		return
	var center := _cell_origin(coord) + Vector2(CELL, CELL) * 0.5
	draw_circle(center, CELL * 0.33, _side_color(owner))
	var s := _stats(stats_id)
	var tag := Sprites.unit_tag(stats_id, s.display_name) if s != null else "??"
	draw_string(font, center + Vector2(-9, 5), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _ink(_side_color(owner)))

func _initials(name: String) -> String:
	var parts := name.split(" ", false)
	if parts.size() >= 2:
		return (parts[0].substr(0, 1) + parts[1].substr(0, 1)).to_upper()
	return name.substr(0, 2).to_upper()

# --- UI ---
func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)

	# Панель прижата к правому краю и тянется на всю высоту окна с отступами (item 23):
	# раньше она стояла в точке (940, 20) с высотой 720 и при окне 720 уходила за нижний
	# край, а на другом размере окна или интерфейса — вовсе мимо экрана.
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -340
	_panel.offset_right = -20
	_panel.offset_top = 20
	_panel.offset_bottom = -20
	_panel.custom_minimum_size = Vector2(320, 0)
	SteamChrome.apply_panel(_panel)
	_ui.add_child(_panel)

	# Оконная рамка со стилем интерфейса: шапка + прокручиваемое тело (#59).
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	_panel.add_child(frame)
	frame.add_child(SteamChrome.header_bar("Deploy Your Force"))

	# Шапка: чья закупка и сколько очков — всегда на виду.
	var top := VBoxContainer.new()
	top.add_theme_constant_override("separation", 2)
	frame.add_child(SteamChrome.pad(top, 10, 8))
	_phase_label = Label.new()
	_phase_label.add_theme_font_size_override("font_size", 16)
	top.add_child(_phase_label)
	_budget_label = Label.new()
	_budget_label.add_theme_font_size_override("font_size", 14)
	top.add_child(_budget_label)

	# Середина прокручивается: разделы — групповые окошки набора (аудит UI), а главная
	# кнопка (Ready / Start Battle) живёт ниже, вне прокрутки, и не уезжает за край.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(300, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var scroll_pad := SteamChrome.pad(scroll, 8, 4)
	scroll_pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(scroll_pad)
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# Инициатива видна уже на расстановке (item 44): тот же жребий (TurnManager.roll_order)
	# от того же зерна, что получит бой.
	var init_group := SteamChrome.group_box_compact("Initiative")
	vbox.add_child(init_group)
	_init_box = VBoxContainer.new()
	init_group.body.add_child(_init_box)
	_refresh_initiative()

	var units_group := SteamChrome.group_box_compact("Infantry")
	vbox.add_child(units_group)
	var hint := Label.new()
	hint.text = "Pick a unit, then click or drag in your zone. Click a deployed unit to refund it. Hover a tank and press R (Q/E) to turn it. WASD or right-drag pans, the wheel zooms."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color("#8a8a8a"))
	units_group.body.add_child(hint)
	_palette = VBoxContainer.new()
	_palette.add_theme_constant_override("separation", 3)
	units_group.body.add_child(_palette)
	var veh_group := SteamChrome.group_box_compact("Vehicles")
	vbox.add_child(veh_group)
	_veh_palette = VBoxContainer.new()
	_veh_palette.add_theme_constant_override("separation", 3)
	veh_group.body.add_child(_veh_palette)
	_populate_palette()

	# Инструменты-формы (item 12): точка/линия/прямоугольник/круг/заливка зоны.
	var brush_group := SteamChrome.group_box_compact("Brush")
	vbox.add_child(brush_group)
	var tools_row := HBoxContainer.new()
	tools_row.add_theme_constant_override("separation", 4)
	brush_group.body.add_child(tools_row)
	for pair in [[PTool.POINT, "Point"], [PTool.LINE, "Line"], [PTool.RECT, "Rect"],
			[PTool.CIRCLE, "Circle"], [PTool.FILL, "Full"]]:
		var tb := Button.new()
		tb.text = String(pair[1])
		tb.toggle_mode = true
		tb.button_pressed = _ptool == int(pair[0])
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.add_theme_font_size_override("font_size", 12)
		var pt: int = int(pair[0])
		tb.pressed.connect(func() -> void: _select_tool(pt))
		tools_row.add_child(tb)
		_tool_buttons[pt] = tb
	# Ластик (batch 13 #5) — отдельный тумблер: работает с любой формой выше.
	_eraser_btn = Button.new()
	_eraser_btn.text = "Eraser  (remove units)"
	_eraser_btn.toggle_mode = true
	_eraser_btn.toggled.connect(_toggle_eraser)
	brush_group.body.add_child(_eraser_btn)

	# Низ окна — вне прокрутки: строка состояния, главная кнопка и выход.
	var bottom := VBoxContainer.new()
	bottom.add_theme_constant_override("separation", 6)
	frame.add_child(SteamChrome.pad(bottom, 10, 10))
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.style_status(_status)
	bottom.add_child(_status)
	_flow_btn = Button.new()
	_flow_btn.custom_minimum_size = Vector2(0, 40)
	_flow_btn.pressed.connect(_on_net_flow if networked() else _on_flow)
	bottom.add_child(_flow_btn)
	var back_btn := Button.new()
	# В сетевой партии «назад» рвёт связь, поэтому ведём в меню, а не в Setup (#93).
	back_btn.text = "Leave Match" if networked() else "Back to Lobby"
	back_btn.pressed.connect(_on_back)
	bottom.add_child(back_btn)

	# Чат закупки (item 14): окошко внизу слева, как в бою. В любой партии (batch
	# group-zones), не только в сетевой: в одиночной пишет сторона, что сейчас закупается,
	# а история та же, что увидит бой (NetHandoff.chat_history).
	var chat_win := PanelContainer.new()
	SteamChrome.apply_panel(chat_win)
	chat_win.anchor_top = 1.0
	chat_win.anchor_bottom = 1.0
	chat_win.offset_left = 20
	chat_win.offset_right = 400
	chat_win.offset_top = -230
	chat_win.offset_bottom = -20
	var cframe := VBoxContainer.new()
	cframe.add_theme_constant_override("separation", 0)
	chat_win.add_child(cframe)
	cframe.add_child(SteamChrome.header_bar("Chat"))
	_chat = ChatBox.new(_side_label, func() -> int:
		return _my_side if networked() else active_side)
	_chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var cpad := SteamChrome.pad(_chat, 8, 8)
	cpad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cframe.add_child(cpad)
	_ui.add_child(chat_win)
	_chat_win = chat_win

	# UI живёт на CanvasLayer — подтянуть общий скин Steam (#59).
	Ui.theme_canvas_layers()

## Наполнить палитру для АКТИВНОЙ стороны (item 2): у каждого игрока может быть свой
## разрешённый состав, поэтому при передаче хода следующему список пересобирается.
func _populate_palette() -> void:
	_palette_buttons = {}
	for box: VBoxContainer in [_palette, _veh_palette]:
		for c in box.get_children():
			c.queue_free()
	for id in PURCHASABLE:
		if not _unit_allowed_for_active(id):
			continue
		var s := _stats(id)
		if s == null:
			continue
		_add_palette_button(id, "%s  -  %d pts" % [s.display_name, s.cost])
	for vid in PURCHASABLE_VEHICLES:
		if not VehicleDB.is_vehicle(vid) or not _unit_allowed_for_active(vid):
			continue
		_add_palette_button(vid, "%s  -  %d pts" % [_display_name(vid), _cost(vid)], true)

func _add_palette_button(id: String, label: String, vehicle: bool = false) -> void:
	var btn := Button.new()
	btn.text = label
	btn.toggle_mode = true
	btn.pressed.connect(_on_pick_unit.bind(id))
	(_veh_palette if vehicle else _palette).add_child(btn)
	_palette_buttons[id] = btn

func _on_pick_unit(id: String) -> void:
	brush_unit = id
	if _erasing and _eraser_btn != null:
		_eraser_btn.button_pressed = false
		_erasing = false
	for bid in _palette_buttons:
		_palette_buttons[bid].button_pressed = (bid == id)
	_status.text = ""

func _refresh_labels() -> void:
	_phase_label.text = "Deploying: %s" % _side_label(active_side)
	_phase_label.modulate = _side_color(active_side)
	var count := 0
	for p in placed:
		if _paid_by(p) == active_side:
			count += 1
	var eb := _effective_budget(active_side)
	if eb > 0:
		_budget_label.text = "Points: %d / %d   (units: %d)" % [spent[active_side], eb, count]
	else:
		_budget_label.text = "Points spent: %d   (unlimited — units: %d)" % [spent[active_side], count]
	if networked():
		var mine := _host_sides()
		var at := mine.find(active_side)
		if _my_ready:
			# Готовность можно снять, пока бой не начат (playtest-20); гостю зеркальной
			# партии снимать нечего — его армия и так отражение хостовой.
			_flow_btn.text = "Waiting..." if _unready_pending or _mirrored_guest() else "Unready"
		elif at >= 0 and at < mine.size() - 1:
			_flow_btn.text = "Next: %s  >" % _side_label(mine[at + 1])
		else:
			_flow_btn.text = "Ready"
		# Гость зеркальной партии готов только когда пришла формация хоста (#12).
		_flow_btn.disabled = _unready_pending or (_mirrored_guest()
				and (_my_ready or not _remote_units.has(_my_side)))
	else:
		var sides := _sides()
		var at := sides.find(active_side)
		if at >= 0 and at < sides.size() - 1 and not _mirrors_live():
			_flow_btn.text = "Next: %s  >" % _side_label(sides[at + 1])
		else:
			_flow_btn.text = "Start Battle"

## Подпись стороны: в сетевой партии игрок видит себя как «Player A/B (you)» (#93).
func _side_label(side: int) -> String:
	var base := roster.name_of(side)
	if networked():
		var slot := roster.slot(side)
		if slot != null and slot.peer_id == 1:
			base += " (host)"
		if side == _my_side:
			base += " (you)"
		elif roster.is_ai(side):
			base += " (AI)"
	return base

## Свои — синие, чужие — красные, у обеих сторон одинаково (#93). В горячем стуле
## цвет остаётся привязан к номеру игрока.
func _side_color(side: int) -> Color:
	if MCF.is_neutral(side):
		return NEUTRAL_COLOR
	# Всегда цвет из ростера (batch 12 #11): игрок ставит войска ТОГО цвета, который
	# выбрал в лобби, и видит его же в бою. Прежняя перспектива «своё синее, чужое
	# красное» показывала на расстановке не те цвета, что потом в бою.
	return roster.color_of(side)

func _side_unit_count(side: int) -> int:
	var n := 0
	for p in placed:
		if int(p["owner"]) == side:
			n += 1
	return n

## Хот-сит: стороны расставляются по очереди, последняя запускает бой.
func _on_flow() -> void:
	if _side_unit_count(active_side) == 0:
		_status.text = "Deploy at least one unit for %s." % _side_label(active_side)
		return
	var sides := _sides()
	var at := sides.find(active_side)
	# Зеркальная партия (batch 13 #13): остальные стороны — отражения, им расставлять
	# нечего, так что после первой стороны сразу в бой.
	if _mirrors_live():
		_refresh_mirrors()
		_start_battle()
		return
	if at >= 0 and at < sides.size() - 1:
		active_side = sides[at + 1]
		brush_unit = ""
		_populate_palette()  # у нового игрока может быть свой разрешённый состав (item 2)
		_status.text = ""
		_refresh_labels()
		queue_redraw()
		return
	_start_battle()

func _start_battle() -> void:
	# Собираем спавны: расставленные игроками + сохранённые мирные.
	map.spawns = []
	for p in placed:
		map.set_spawn(p["coord"], p["stats_id"], int(p["owner"]), _placed_facing_or_zero(p))
	# Армии соперников приходят по сети — все стороны собирают ОДИН И ТОТ ЖЕ ростер (#93).
	# Стороны, что ставила эта машина, в присланных пакетах не встречаются, поэтому
	# дублей не будет.
	for side in _remote_units:
		if _placed_here(int(side)):
			continue
		for e in _remote_units[side]:
			map.set_spawn(Vector2i(int(e["x"]), int(e["y"])), str(e["id"]), int(e["o"]),
				Vector2i(int(e.get("fx", 0)), int(e.get("fy", 0))))
	for s in preserved_neutral:
		map.set_spawn(s["coord"], s["stats_id"], MCF.Owner.NEUTRAL)
	if networked():
		# Своя армия у сторон идёт в списке первой, а id юнитов раздаются по порядку
		# спавна — без канонической сортировки id хоста и клиента разъехались бы, и
		# намерения (они ссылаются на id) применялись бы не к тем юнитам.
		_sort_spawns()
	MapHandoff.pending = map
	# Одно зерно на двоих: локальный бросок инициативы обязан совпасть. И в одиночной
	# партии тоже — его же порядок уже показан на панели справа.
	if _shared_seed >= 0:
		MapHandoff.dice_seed = _shared_seed
	if networked():
		_hand_session_to_battle()
	get_tree().change_scene_to_file(MAIN_SCENE)

func _sort_spawns() -> void:
	map.spawns.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ao := int(a["owner"])
		var bo := int(b["owner"])
		if ao != bo:
			return ao < bo
		var ac: Vector2i = a["coord"]
		var bc: Vector2i = b["coord"]
		if ac.y != bc.y:
			return ac.y < bc.y
		if ac.x != bc.x:
			return ac.x < bc.x
		return str(a["stats_id"]) < str(b["stats_id"]))

## Сессия переезжает в бой: пока сцены меняются, входящие пакеты копятся в буфере
## NetworkSession, а Main подхватит их своим attach().
func _hand_session_to_battle() -> void:
	_net.detach()
	if _net.message.is_connected(_on_net_message):
		_net.message.disconnect(_on_net_message)
	NetHandoff.session = _net
	NetHandoff.is_host = _net_is_host
	_net = null

func _on_back() -> void:
	if _net != null:
		_drop_session()
		get_tree().change_scene_to_file(MENU_SCENE)
		return
	# Одиночная игра теперь создаётся в лобби (item 8/20) — назад ведёт туда же, а не в
	# снятый с потока старый экран Setup.
	get_tree().change_scene_to_file(LOBBY_SCENE)

## Цвет подписи поверх заливки: на светлой (белая сторона) — чёрный, иначе белый.
static func _ink(bg: Color) -> Color:
	return Color.BLACK if bg.get_luminance() > 0.6 else Color.WHITE
