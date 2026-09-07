class_name GridCell
extends RefCounted

## Одна клетка сетки (см. §3.1, §6).

## Версия «проходимости» сетки. Растёт на КАЖДУЮ запись в поле, от которого зависит
## walkable_terrain() / Grid.blocks_walk() / стоимость входа в клетку: занятость,
## корпус машины, объект, насыпь, высота укрытия, заваренный шлюз.
##
## Movement.reachable() кеширует разливы Дейкстры и сбрасывает кеш, как только версия
## изменилась. Поэтому перечисленные поля ОБЯЗАНЫ писаться через сеттеры (то есть
## обычным `cell.occupant = x`), а не в обход них. Поля, на проходимость не влияющие
## (fire_owner, floor_type, corpse_count, feature_owner, feature_durability),
## сеттеров намеренно не имеют — лишние сбросы кеша только замедляют.
##
## on_fire — исключение: с #1 огонь стал смертелен, и маршрут не-огнеупорного бойца
## его ОБХОДИТ (Movement.reachable(avoid_fire)). Значит загоревшаяся клетка меняет
## проходимость ровно так же, как выросшая стена, и версию двигать обязана.
##
## Запись ТЕМ ЖЕ значением версию не двигает. Это не микрооптимизация, а условие
## работоспособности кешей: update_airlocks() после каждого действия проходит по всем
## шлюзам и присваивает им высоту заново — почти всегда ту же самую. Без этой проверки
## любой ход сбрасывал бы и разливы, и туман, и кеши не давали бы ничего.
static var walk_version: int = 0

## Версия «просматриваемости» сетки. Двигается ТОЛЬКО двумя полями — cover_height и
## vehicle_id, — потому что ровно их и читает GameActionResolver._vision_blocked().
## И даже ими не на всякую запись, а лишь когда пересечён порог, который этот луч
## проверяет: «высота дошла до стены» и «корпус появился/исчез» (см. сеттеры ниже).
##
## Отдельный счётчик нужен из-за одного факта: ЖИВЫЕ ЮНИТЫ ОБЗОР НЕ ПЕРЕКРЫВАЮТ. Значит
## чужой (да и свой) шаг не меняет того, что видно с любой ДРУГОЙ клетки, — а walk_version
## на каждый шаг двигается, и привязанный к нему кеш тумана обнулялся после каждого
## действия. В бою на 200 бойцов это 60 тысяч лучей Брезенхэма на каждое действие.
##
## Здесь же его нет: пока стены и техника стоят на местах, «что видно из клетки (x,y) с
## радиусом r» — величина постоянная, и её можно кешировать через весь бой. Разрушенная
## стена, построенное укрепление, закрывшийся шлюз, проехавший танк — всё это идёт через
## cover_height/vehicle_id и версию двигает.
static var vision_version: int = 0

## Журнал клеток, на которых этот порог пересекался: подряд идущие пары (x, y), по паре
## на каждую единицу vision_version. Нужен, чтобы держатель кеша обзора мог не выбрасывать
## его целиком, а выкинуть ровно те записи, до которых изменение дотянулось: рухнувшая
## стена в одном углу карты ничего не меняет в том, что видно из другого. Без журнала
## один разрушенный дот стоил полного пересчёта обзора всей армии (~40 мс).
##
## vision_log_base — номер версии, которой соответствует НАЧАЛО журнала. Всё, что старше,
## в журнале уже не описано, и держатель с такой версией обязан сбросить кеш целиком.
## Так закрываются оба случая, когда точечная инвалидация невозможна: новая сетка и
## переполнение журнала (разом рухнувший квартал дешевле пересчитать, чем разбирать).
static var vision_changes: PackedInt32Array = PackedInt32Array()
static var vision_log_base: int = 0
const VISION_LOG_CAP := 4096

static func log_vision_change(x: int, y: int) -> void:
	vision_version += 1
	if vision_changes.size() >= VISION_LOG_CAP:
		vision_changes.clear()
		vision_log_base = vision_version
		return
	vision_changes.append(x)
	vision_changes.append(y)

## Объявить весь прежний журнал недействительным (новая сетка).
static func reset_vision_log() -> void:
	vision_version += 1
	vision_changes.clear()
	vision_log_base = vision_version

var coord: Vector2i
var floor_type: int = 0
## Высота укрытия/препятствия: 0 / 0.5 / 1 / 1.5 / 2 (2 = стена).
var cover_height: float = 0.0:
	set(v):
		if cover_height == v:
			return
		# Обзору важна не высота, а ровно факт «стена или нет» — _vision_blocked() читает
		# только сравнение с WALL_HEIGHT. Отрытый окоп, мешки с песком, куча земли по пояс
		# высоту меняют, а видно из клетки остаётся ровно то же самое; двигать на них
		# vision_version значило бы выбрасывать кеш обзора всей армии (полсотни тысяч
		# лучей) ради изменения, которого этот кеш не видит.
		var was_wall := cover_height >= MCF.WALL_HEIGHT
		cover_height = v
		walk_version += 1
		if was_wall != (v >= MCF.WALL_HEIGHT):
			log_vision_change(coord.x, coord.y)
## Сколько клеток горит прямо сейчас — счётчик на все сетки разом (#106). Нужен ровно
## для одного вопроса: «а есть ли на карте огонь вообще». ИИ спрашивает «не горит ли
## рядом» на КАЖДУЮ клетку разлива каждого бойца, то есть под сотню раз на решение, и
## почти всегда на карте не горит ничего — тогда все девять проверок заведомо впустую.
##
## Считать можно только В СТОРОНУ ЗАВЫШЕНИЯ: если брошенная сетка унесла с собой
## горящие клетки, счётчик останется больше нуля, и проверка просто пойдёт как раньше,
## по клеткам. Занизить его нельзя — любой переход on_fire идёт через этот сеттер.
static var burning: int = 0
var on_fire: bool = false:
	set(v):
		if on_fire == v:
			return
		on_fire = v
		burning += 1 if v else -1
		walk_version += 1   # маршрут обходит огонь (#1) — см. заголовок файла
## Сторона, устроившая пожар: огонь расползается только на её ходу (#45). -1 = ничей.
var fire_owner: int = -1
## Номер раунда, ДО которого в клетку не может вползти огонь: пожаротушительная
## граната (#19) глушит клетку на EXTINGUISHER_SUPPRESS_TURNS раундов. Запрет
## касается только пассивного разлива — прямой выстрел огнемёта его игнорирует.
var fire_suppressed_until: int = 0
## "Космос" — правила невесомости (§3.11); задействуется на M5.
var is_space: bool = false
## Живой юнит ИЛИ труп, занимающий клетку; null = пусто.
var occupant: UnitInstance = null:
	set(v):
		if occupant == v:
			return
		occupant = v
		walk_version += 1
## Корпус машины (танк/челнок), накрывающий клетку; -1 = нет (§ «Техника»).
var vehicle_id: int = -1:
	set(v):
		if vehicle_id == v:
			return
		# Как и с высотой: обзор различает лишь «корпус есть / корпуса нет». Смена одного
		# id на другой без промежуточного -1 (машина сменила хозяина, переехала в тот же
		# след) видимость не меняет, и кеш обзора переживает её без пересчёта.
		var was_hull := vehicle_id != -1
		vehicle_id = v
		walk_version += 1
		if was_hull != (v != -1):
			log_vision_change(coord.x, coord.y)
## Статический объект на клетке (станция дрона, укрепление и т. п.); "" = нет.
## Владелец — для станций/ДПМГ. Высота укрытия задаётся при установке через set_feature().
## Версия «расстановки объектов». Двигается на каждую смену feature_id — только на неё,
## а не на любой ход, как walk_version. По ней GameActionResolver держит список клеток-
## шлюзов: update_airlocks() зовут ПОСЛЕ КАЖДОГО действия, и он перебирал всю карту
## (2400 клеток) ради десятка шлюзов, а чаще всего — ради ни одного.
static var feature_version: int = 0

var feature_id: String = "":
	set(v):
		if feature_id == v:
			return
		feature_id = v
		walk_version += 1
		feature_version += 1
var feature_owner: int = -1
## Остаток прочности укрепления в единой шкале урона (§3.7): 0 = прочности нет,
## объект сносится любым попаданием. У ДОТа 2 — первое попадание оставляет трещину.
var feature_durability: int = 0
## Счётчик трупов на клетке — 5 образуют стену из трупов (§3.7).
var corpse_count: int = 0
## Уровень кучи земли (§3.7): 0 = нет, 1..4 = 0.5 м на уровень (макс. 2 м = стена).
var dirt_level: int = 0:
	set(v):
		if dirt_level == v:
			return
		dirt_level = v
		walk_version += 1
## Шлюз заварен инженером (#99): створки больше не разъезжаются от подошедшего юнита,
## клетка навсегда остаётся стеной. Снимается только сносом самого шлюза.
var airlock_welded: bool = false:
	set(v):
		if airlock_welded == v:
			return
		airlock_welded = v
		walk_version += 1

func _init(p_coord: Vector2i) -> void:
	coord = p_coord

func is_wall() -> bool:
	return cover_height >= MCF.WALL_HEIGHT

## Шлюз, который сам разъедется перед подошедшим бойцом (#100). Пока рядом никого нет,
## створки закрыты и cover_height читается как стена — но для ПЛАНИРОВАНИЯ пути это
## не преграда: боец дойдёт до соседней клетки, шлюз откроется, и он шагнёт внутрь.
## Заваренный инженером шлюз (#99) сюда не попадает — он стена навсегда.
func airlock_opens() -> bool:
	return feature_id == MCF.FEATURE_AIRLOCK and not airlock_welded

## Проходима ли клетка ПЕШКОМ: обычная свободная клетка ИЛИ шлюз, который откроется.
## Занятость (юнит/труп/корпус машины) здесь не проверяется — только сама преграда.
func walkable_terrain() -> bool:
	# Быстрый выход для чистой клетки пола — их на карте подавляющее большинство, а
	# функция стоит в самом низу Дейкстры и всех волновых BFS. Без объекта и без
	# насыпи ни airlock_opens(), ни blocks_move() истинными быть не могут, поэтому
	# остаётся ровно проверка на стену — та же, что и в общем случае ниже.
	if feature_id == "" and dirt_level == 0:
		return cover_height < MCF.WALL_HEIGHT
	if airlock_opens():
		return true
	return not is_wall() and not blocks_move()

func has_feature() -> bool:
	return feature_id != ""

## Есть ли на клетке низкое укрытие (0 < высота < 2) — даёт бонус укрытия (§3.7).
func has_cover() -> bool:
	return cover_height > 0.0 and cover_height < MCF.WALL_HEIGHT

## Установить объект и его высоту укрытия (§3.7).
func set_feature(id: String, owner: int = -1) -> void:
	feature_id = id
	feature_owner = owner
	feature_durability = MCF.feature_durability(id)
	if MCF.FEATURE_HEIGHT.has(id):
		cover_height = MCF.FEATURE_HEIGHT[id]

## Добавить кучу вынутой земли (§3.7): растёт по 0.5 м за уровень, до 2 м (уровень 4).
## Возвращает false, если куча уже максимальной высоты. На уровне 4 работает как стена.
func add_dirt(owner: int = -1) -> bool:
	if dirt_level >= MCF.DIRT_MAX_LEVEL:
		return false
	dirt_level += 1
	feature_id = MCF.FEATURE_DIRT_PILE
	feature_owner = owner
	cover_height = MCF.DIRT_HEIGHT_PER_LEVEL * float(dirt_level)
	return true

## Можно ли досыпать сюда землю: пусто под насыпь ИЛИ уже куча ниже максимума.
func accepts_dirt() -> bool:
	if occupant != null:
		return false
	if dirt_level > 0:
		return dirt_level < MCF.DIRT_MAX_LEVEL
	return feature_id == "" and cover_height == 0.0

## Снять объект (высота укрытия обнуляется — рельеф под ним не моделируется).
func clear_feature() -> void:
	feature_id = ""
	feature_owner = -1
	feature_durability = 0
	cover_height = 0.0
	dirt_level = 0
	airlock_welded = false

## Куча земли выше 1 м (уровень ≥3 = 1.5/2.0 м) — на неё нельзя вставать (§3.7).
func is_tall_dirt() -> bool:
	return MCF.DIRT_HEIGHT_PER_LEVEL * float(dirt_level) > 1.0

## Объект на клетке, на который нельзя наступать (станция дрона — как труп, §3.12;
## высокая куча земли — по правилу высоты; противотанковый ёж — колючая конструкция,
## его только перепрыгивают).
func blocks_move() -> bool:
	return feature_id == MCF.FEATURE_DRONE_STATION or feature_id == MCF.FEATURE_HEDGEHOG \
			or is_tall_dirt()

func is_empty() -> bool:
	return occupant == null and not is_wall() and not blocks_move()

## Клетка полностью пустая под постройку укрепления: без юнита, укрытия и объекта.
func is_buildable() -> bool:
	return occupant == null and feature_id == "" and cover_height == 0.0
