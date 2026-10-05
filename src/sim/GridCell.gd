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
## (fire_owner, floor_type, corpse_count, feature_owner, feature_durability), версий
## не двигают — лишние сбросы кеша только замедляют. Сеттеры у них есть ради одного
## журнала отката (см. journal ниже).
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

## Версия «просматриваемости» сетки. Двигается ТОЛЬКО тем, что читает blocks_sight():
## cover_height (переход через порог стены) и feature_id (стекло ↔ не-стекло при
## стенной высоте). Корпуса машин обзор не перекрывают (batch 13 #1), и vehicle_id
## её не трогает.
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
	look_version += 1
	look_changes.clear()
	look_log_base = look_version

## Снимок всех общих журналов (вида, обзора, проходимости, отката) и возврат к нему. Нужен
## тем, кто строит ЧЕРНОВУЮ сетку рядом с настоящей доской (предпросмотр редактора, вид
## «было» в бою): Grid.new объявляет журналы оборванными, а держатели кэшей настоящей
## доски тогда пересобирали бы всё. Packed-массивы — копиями: статический массив правится
## на месте, и снимок-ссылка опустел бы вместе с ним (0.9.2, «правки не видны на холсте»).
static func logs_snapshot() -> Array:
	return [look_version, look_changes.duplicate(), look_log_base,
			vision_version, vision_changes.duplicate(), vision_log_base,
			walk_version, feature_version, journaling, journal]

static func logs_restore(s: Array) -> void:
	look_version = s[0]
	look_changes = s[1]
	look_log_base = s[2]
	vision_version = s[3]
	vision_changes = s[4]
	vision_log_base = s[5]
	walk_version = s[6]
	feature_version = s[7]
	journaling = s[8]
	journal = s[9]

## Журнал ВИДА клеток — пол, высота, огонь, космос, объект, насыпь, сварка: всё, из чего
## экран боя собирает дальний план (Main, LOD) и ИИ — карту проходимости рельефа
## (AIController._walk_mask). Устроен как журнал обзора: пары (x, y), по паре на единицу
## look_version, look_log_base — версия начала. Держатель правит у себя только эти
## клетки, а не пересобирает всю карту 250×250.
static var look_version: int = 0
static var look_changes: PackedInt32Array = PackedInt32Array()
static var look_log_base: int = 0

static func log_look_change(x: int, y: int) -> void:
	look_version += 1
	if look_changes.size() >= VISION_LOG_CAP:
		look_changes.clear()
		look_log_base = look_version
		return
	look_changes.append(x)
	look_changes.append(y)

## Смена числа тел в какой-нибудь клетке: экран держит по ней список куч трупов, чтобы
## не перебирать ради них всё поле.
static var corpse_version: int = 0

## Журнал отката (Undo, §18.2). Пока journaling включён, ПЕРВАЯ правка клетки кладёт в
## journal её прежний вид целиком (image()). Резолвер включает журнал на время действия
## человека и хранит в стеке отката только тронутые клетки: полный снимок доски 250×250 —
## это 62 500 словарей и ~250 мс на КАЖДЫЙ щелчок. Поэтому каждое изменяемое поле клетки
## пишется через сеттер, даже если никаких версий не двигает.
static var journaling: bool = false
static var journal: Dictionary = {}   # GridCell -> Array (image() до первой правки)

func _journal() -> void:
	if not journal.has(self):
		journal[self] = image()

## Всё изменяемое в клетке, в порядке, который читает apply_image().
func image() -> Array:
	return [floor_type, cover_height, on_fire, fire_owner, fire_suppressed_until, is_space,
			occupant, vehicle_id, feature_id, station_operator_id, feature_owner,
			feature_durability, corpse_count, dirt_level, airlock_welded]

## Вернуть клетке снятый image() — через сеттеры, чтобы версии и кеши узнали о правке.
## Высота идёт раньше объекта: сеттер feature_id смотрит на неё (стекло в стене).
func apply_image(im: Array) -> void:
	floor_type = im[0]
	cover_height = im[1]
	on_fire = im[2]
	fire_owner = im[3]
	fire_suppressed_until = im[4]
	is_space = im[5]
	occupant = im[6]
	vehicle_id = im[7]
	feature_id = im[8]
	station_operator_id = im[9]
	feature_owner = im[10]
	feature_durability = im[11]
	corpse_count = im[12]
	dirt_level = im[13]
	airlock_welded = im[14]

var coord: Vector2i
var floor_type: int = 0:
	set(v):
		if floor_type != v:
			if journaling: _journal()
			floor_type = v
			log_look_change(coord.x, coord.y)
## Высота укрытия/препятствия: 0 / 0.5 / 1 / 1.5 / 2 (2 = стена).
var cover_height: float = 0.0:
	set(v):
		if cover_height == v:
			return
		if journaling: _journal()
		# Обзору важна не высота, а ровно факт «стена или нет» — _vision_blocked() читает
		# только сравнение с WALL_HEIGHT. Отрытый окоп, мешки с песком, куча земли по пояс
		# высоту меняют, а видно из клетки остаётся ровно то же самое; двигать на них
		# vision_version значило бы выбрасывать кеш обзора всей армии (полсотни тысяч
		# лучей) ради изменения, которого этот кеш не видит.
		var was_wall := cover_height >= MCF.WALL_HEIGHT
		cover_height = v
		walk_version += 1
		log_look_change(coord.x, coord.y)
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
		if journaling: _journal()
		on_fire = v
		burning += 1 if v else -1
		log_look_change(coord.x, coord.y)
		walk_version += 1   # маршрут обходит огонь (#1) — см. заголовок файла
## Сторона, устроившая пожар: огонь расползается только на её ходу (#45). -1 = ничей.
var fire_owner: int = -1:
	set(v):
		if fire_owner != v:
			if journaling: _journal()
			fire_owner = v
## Номер раунда, ДО которого в клетку не может вползти огонь: пожаротушительная
## граната (#19) глушит клетку на EXTINGUISHER_SUPPRESS_TURNS раундов. Запрет
## касается только пассивного разлива — прямой выстрел огнемёта его игнорирует.
var fire_suppressed_until: int = 0:
	set(v):
		if fire_suppressed_until != v:
			if journaling: _journal()
			fire_suppressed_until = v
## "Космос" — правила невесомости (§3.11); задействуется на M5.
var is_space: bool = false:
	set(v):
		if is_space != v:
			if journaling: _journal()
			is_space = v
			log_look_change(coord.x, coord.y)
## Живой юнит ИЛИ труп, занимающий клетку; null = пусто.
var occupant: UnitInstance = null:
	set(v):
		if occupant == v:
			return
		if journaling: _journal()
		occupant = v
		walk_version += 1
## Корпус машины (танк/челнок), накрывающий клетку; -1 = нет (§ «Техника»).
var vehicle_id: int = -1:
	set(v):
		if vehicle_id == v:
			return
		if journaling: _journal()
		# Корпус машины обзор НЕ перекрывает (batch 13 #1): видно всё до стены или
		# закрытого шлюза, и техника, как и живые, лучу не мешает. Поэтому смена
		# vehicle_id версию обзора не двигает — только проходимость.
		vehicle_id = v
		walk_version += 1
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
		if journaling: _journal()
		# Стекло прозрачно для обзора (#29), а высота у него стенная — значит замена
		# стены на стекло (и обратно) при той же высоте меняет просматриваемость, и
		# сеттер высоты этого не заметит. Ловим переход здесь.
		var saw_through := MCF.is_glass(feature_id)
		feature_id = v
		walk_version += 1
		feature_version += 1
		log_look_change(coord.x, coord.y)
		if cover_height >= MCF.WALL_HEIGHT and saw_through != MCF.is_glass(v):
			log_vision_change(coord.x, coord.y)
var feature_owner: int = -1:
	set(v):
		if feature_owner != v:
			if journaling: _journal()
			feature_owner = v
## Оператор, развернувший станцию дронов (item 16); -1 = станции нет или её поставил
## не оператор (старые карты, редактор). Владельца-стороны для правила «одна станция
## на оператора» не хватает: у команды операторов много, а станция у каждого одна.
var station_operator_id: int = -1:
	set(v):
		if station_operator_id != v:
			if journaling: _journal()
			station_operator_id = v
## Остаток прочности укрепления в единой шкале урона (§3.7): 0 = прочности нет,
## объект сносится любым попаданием. У ДОТа 2 — первое попадание оставляет трещину.
var feature_durability: int = 0:
	set(v):
		if feature_durability != v:
			if journaling: _journal()
			feature_durability = v
			# Побитая мебель рисуется с трещинами прямо в плитке (§3.15): кусок рельефа
			# должен узнать, что клетку пора перерисовать.
			log_look_change(coord.x, coord.y)
## Счётчик трупов на клетке — 5 образуют стену из трупов (§3.7).
var corpse_count: int = 0:
	set(v):
		if corpse_count != v:
			if journaling: _journal()
			corpse_count = v
			corpse_version += 1
			walk_version += 1   # куча тел — не проход (batch borg-corpses), маршрут её обходит
## Уровень кучи земли (§3.7): 0 = нет, 1..4 = 0.5 м на уровень (макс. 2 м = стена).
var dirt_level: int = 0:
	set(v):
		if dirt_level == v:
			return
		if journaling: _journal()
		dirt_level = v
		walk_version += 1
		log_look_change(coord.x, coord.y)
## Шлюз заварен инженером (#99): створки больше не разъезжаются от подошедшего юнита,
## клетка навсегда остаётся стеной. Снимается только сносом самого шлюза.
var airlock_welded: bool = false:
	set(v):
		if airlock_welded == v:
			return
		if journaling: _journal()
		airlock_welded = v
		walk_version += 1
		log_look_change(coord.x, coord.y)

func _init(p_coord: Vector2i) -> void:
	coord = p_coord

func is_wall() -> bool:
	return cover_height >= MCF.WALL_HEIGHT

## Перекрывает ли клетка ОБЗОР (batch 13 #1): стена в полный рост — в том числе
## закрытый шлюз, у которого высота стенная, — кроме стекла: сквозь него видно (#29).
## Живые юниты, трупы и корпуса машин лучу не мешают.
func blocks_sight() -> bool:
	return cover_height >= MCF.WALL_HEIGHT and not MCF.is_glass(feature_id)

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
	var fh := MCF.feature_height(id)
	if fh >= 0.0:
		cover_height = fh

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
	station_operator_id = -1
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
	return occupant == null and corpse_count == 0 and not is_wall() and not blocks_move()

## Клетка полностью пустая под постройку укрепления: без юнита, укрытия и объекта.
func is_buildable() -> bool:
	return occupant == null and feature_id == "" and cover_height == 0.0
