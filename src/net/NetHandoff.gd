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

## Собрать объявление матча из текущего GameConfig и выбранной карты (#99).
static func encode_setup(map: MapData) -> Dictionary:
	return {
		"k": K_SETUP, "m": map.to_dict(), "b": GameConfig.budget,
		"c": GameConfig.civilians_enabled, "f": GameConfig.fog_enabled,
	}

## Клиент принимает условия хоста целиком: он ничего не выбирает сам (#99).
static func apply_setup(msg: Dictionary) -> void:
	GameConfig.budget = int(msg.get("b", GameConfig.DEFAULT_BUDGET))
	GameConfig.civilians_enabled = bool(msg.get("c", true))
	GameConfig.fog_enabled = bool(msg.get("f", false))
	GameConfig.free_placement = true
	GameConfig.p2_is_ai = false
	GameConfig.map_path = ""
	lobby_map = MapData.from_dict(msg.get("m", {}))

static func take_lobby_map() -> MapData:
	var m := lobby_map
	lobby_map = null
	return m
