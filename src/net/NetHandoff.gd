class_name NetHandoff
extends RefCounted

## Передача УЖЕ УСТАНОВЛЕННОГО соединения из главного меню в бой (#54).
##
## Мультиплеер теперь живёт отдельной вкладкой в меню, а не на боковой панели боя:
## связь налаживается там, и в сцену боя приезжает готовая сессия. Работает так же,
## как MapHandoff: статика живёт, пока загружен скрипт класса, и переживает смену
## сцены. Сам узел NetworkSession висит под /root с постоянным именем — RPC ходит
## по пути узла, поэтому путь обязан совпадать у обеих сторон.

static var session: NetworkSession = null
static var is_host: bool = false

## Объявление матча: хост → клиент (#99).
const K_SETUP := "setup"
## Загруженная хостом партия: хост → клиент (M12, item 42). Едет ЦЕЛИКОМ, ровно по той
## же причине, что и карта, — у клиента этого файла нет и быть не может. Расстановка
## при этом пропускается: армии уже стоят на доске, их только раздают игрокам.
const K_LOAD := "load"

## Карта, объявленная хостом (#99). Едет по сети ЦЕЛИКОМ, а не именем файла: карта
## хоста может быть нарисована в его редакторе, и у клиента такого файла попросту нет.
## Заодно это гарантирует побайтово одинаковое поле у обеих сторон.
static var lobby_map: MapData = null

## Забрать сессию (и обнулить передачу, чтобы бой не подхватил её дважды).
static func take() -> NetworkSession:
	var s := session
	session = null
	return s

## Оборвать неподхваченную сессию — например, игрок ушёл из вкладки мультиплеера.
static func discard() -> void:
	lobby_map = null
	if session != null:
		session.close()
		session.queue_free()
		session = null

## Снимок лобби: хост → все гости (batch 12 #8). Ростер и правила целиком, на каждое
## изменение — гость видит то же окно, что и хост.
const K_LOBBY := "lobby"
## Просьба гостя хосту (batch 12 #8): {"op": "color", "c": idx} — выбрать цвет;
## {"op": "slot", "s": id} — пересесть в открытый слот. Решает хост и рассылает снимок.
const K_LOBBY_REQ := "lobby_req"
## Карта хоста для превью в лобби гостя (batch 12 #8): отдельно от снимка, потому что
## словарь карты велик и меняется редко.
const K_LOBBY_MAP := "lobby_map"

## Все правила партии одним словарём (batch 12 #9/#10): раньше по сети ехали лишь
## карта, бюджет, мирные и туман, а зеркальная расстановка, личные бюджеты слотов,
## видимость чужой расстановки и события оставались у гостя по умолчанию.
static func encode_rules() -> Dictionary:
	var roster := GameConfig.active_roster()
	return {
		"b": GameConfig.budget, "c": GameConfig.civilians_enabled, "f": GameConfig.fog_mode,
		"pm": GameConfig.placement_mode, "lv": GameConfig.live_placement_visible,
		"ff": GameConfig.friendly_fire, "as": GameConfig.army_select_mode,
		"gm": GameConfig.game_mode, "fu": GameConfig.free_unlimited_for,
		"re": GameConfig.random_events_enabled, "rm": GameConfig.random_events_mandatory,
		"ri": GameConfig.random_events_interval,
		"rw": GameConfig.random_events_weights.duplicate(),
		"roster": roster.to_dict(),
	}

static func apply_rules(msg: Dictionary) -> void:
	GameConfig.budget = int(msg.get("b", GameConfig.DEFAULT_BUDGET))
	GameConfig.civilians_enabled = bool(msg.get("c", true))
	# Режим тумана (item 46) едет числом. Старый хост слал сюда bool — int(false)
	# даёт 0, то есть OFF, а int(true) — 1, STANDARD: ровно прежний смысл.
	GameConfig.fog_mode = int(msg.get("f", MCF.Fog.OFF))
	GameConfig.placement_mode = int(msg.get("pm", GameConfig.Placement.ASYMMETRIC))
	GameConfig.live_placement_visible = bool(msg.get("lv", true))
	GameConfig.friendly_fire = bool(msg.get("ff", true))
	GameConfig.army_select_mode = int(msg.get("as", GameConfig.ArmySelect.PLAYERS_PICK))
	GameConfig.game_mode = str(msg.get("gm", "domination"))
	GameConfig.free_unlimited_for = int(msg.get("fu", GameConfig.FREE_NONE))
	GameConfig.random_events_enabled = bool(msg.get("re", false))
	GameConfig.random_events_mandatory = bool(msg.get("rm", false))
	GameConfig.random_events_interval = int(msg.get("ri", 3))
	var rw: Variant = msg.get("rw", {})
	GameConfig.random_events_weights = {}
	if rw is Dictionary:
		for k in rw:
			GameConfig.random_events_weights[str(k)] = float(rw[k])
	GameConfig.allowed_units = {}
	var rd: Variant = msg.get("roster")
	if rd is Dictionary:
		GameConfig.roster = Roster.from_dict(rd)
	GameConfig.free_placement = true
	GameConfig.p2_is_ai = false
	GameConfig.map_path = ""

## Собрать объявление матча из текущего GameConfig и выбранной карты (#99).
static func encode_setup(map: MapData) -> Dictionary:
	var msg := encode_rules()
	msg["k"] = K_SETUP
	msg["m"] = map.to_dict()
	return msg

## Клиент принимает условия хоста целиком: он ничего не выбирает сам (#99).
static func apply_setup(msg: Dictionary) -> void:
	apply_rules(msg)
	lobby_map = MapData.from_dict(msg.get("m", {}))

## Собрать объявление загруженной партии (M12). Ростер в save уже переписан лобби:
## переназначение ролей — это правка ростера, а не переписывание владельцев юнитов.
static func encode_load(save: Dictionary) -> Dictionary:
	return {"k": K_LOAD, "s": save}

static func apply_load(msg: Dictionary) -> void:
	var save: Variant = msg.get("s")
	if not (save is Dictionary):
		return
	SaveHandoff.pending_save = save
	GameConfig.free_placement = true
	GameConfig.p2_is_ai = false
	GameConfig.map_path = ""
	lobby_map = null

static func take_lobby_map() -> MapData:
	var m := lobby_map
	lobby_map = null
	return m
