class_name Vehicle
extends RefCounted

## Многоклеточная машина (танк/челнок) — раздел «Техника» правил МКФ.
##
## В отличие от пехоты (гибнет от одного пробивающего попадания), у машины есть
## пул прочности (durability). Это слой ДАННЫХ: геометрия следа, экипаж/пассажиры,
## поворот, пул ОД, пушка и бросок на уничтожение подключаются резолвером.
##
## След (footprint): блок size.x × size.y с верхним-левым углом origin. КАЖДАЯ
## клетка следа регистрируется в Grid (vehicle_id) — непроходима и перекрывает
## линию огня/обзора. Опорная клетка для укрытия/линии — центр (center()).
##
## Чистые данные (RefCounted, без узлов сцены), чтобы состояние сериализовалось.

## Id машин живут в отдельном диапазоне, чтобы не пересекаться с id пехоты (с 0).
const ID_BASE := 3000000

## Геометрия посадочных мест челнока (правила «Техника»). 4 слота — по углам следа
## в фиксированном порядке: 0=ВЛ, 1=ВП (водитель), 2=НЛ, 3=НП.
const SEAT_OFFSETS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]

## Водитель всегда в правой-верхней клетке — слот 1.
const DRIVER_SEAT := 1

var id: int = -1
var type_id: String = ""
var owner: int = -1

## Прочность УЗЛОВ (веха «Modular tank system»): id узла → текущие очки.
## Отсутствующий ключ = узла у этой машины нет вовсе (у челнока нет башни и пушки).
## Заполняется из MCF.VEHICLE_COMPONENTS при появлении машины на поле.
var components: Dictionary = {}

## Прочность КОРПУСА. Осталась отдельным именем, потому что корпус — единственный узел,
## чей ноль означает «машины больше нет»: на него смотрят alive(), условие победы,
## оценка ИИ и слепок доски. Физически это просто ячейка components — синонимы, а не
## два разных числа, иначе они бы неминуемо разошлись.
var durability: int:
	get:
		return int(components.get(MCF.COMP_HULL, 0))
	set(value):
		components[MCF.COMP_HULL] = maxi(0, value)

## Куда башня смотрела при ПОСЛЕДНЕМ выстреле — в системе координат КОРПУСА, а не поля.
## Разбитая башня (tower = 0) больше не поворачивается, и стрелять машина может только
## туда же; но корпус-то вращается, и вместе с ним разворачивается заклиненная башня —
## поэтому направление и хранится относительно фронта. Vector2i.ZERO = ещё не стреляла.
var tower_locked_dir: Vector2i = Vector2i.ZERO

## Верхний-левый угол следа и его размеры в клетках.
var origin: Vector2i = Vector2i.ZERO
var size: Vector2i = Vector2i.ONE

## Направление (единичный вектор) для машин с фронтом — у танка (одно из 8).
## Vector2i.ZERO = без направления (челнок). Танк ходит только вперёд/назад вдоль
## этого вектора и тратит ОД на поворот на месте.
var facing: Vector2i = Vector2i(1, 0)

## Собственный пул ОД машины: РАВЕН числу ЖИВЫХ членов экипажа, пересчитывается в
## начале хода владельца. Тратится на поворот/движение/выстрел.
var ap: int = 0

## ЖИВОЙ экипаж/пассажиры (id юнитов). У танка ОД = occupants.size().
var occupants: Array[int] = []

## Трупы экипажа, занимающие слоты (type_id трупа). Труп держит слот до вытаскивания
## снаружи; ОД не даёт и в выборку «попадание по экипажу» не входит.
var corpse_slots: Array[String] = []

## Позиционные места челнока: массив на 4 слота по углам (см. SEAT_OFFSETS); -1 = пусто.
## Правый-верхний (индекс 1) — всегда водитель. Танк места не использует (seats = []).
var seats: Array[int] = []

## Обломки танка (результат уничтожения без взрыва): прочность 0, экипаж мёртв, но
## корпус ОСТАЁТСЯ на поле как непроходимое препятствие/укрытие и перекрывает линию.
var wrecked: bool = false

## Сколько раз главная пушка стреляла в этом раунде (не чаще 2×/ход).
var cannon_shots_this_round: int = 0

## Неизрасходованные очки скорости прошлого Движения (#97) — то же дробление действия,
## что и move_credit у пехоты (§3.2): проехав часть пути, машина докатывает остаток
## в любой момент своего хода и ОД за это уже не платит. Обнуляется началом хода.
var move_credit: int = 0


func _init(p_id: int = -1, p_type_id: String = "", p_owner: int = -1,
		p_origin: Vector2i = Vector2i.ZERO, p_size: Vector2i = Vector2i.ONE,
		p_durability: int = 0) -> void:
	id = p_id
	type_id = p_type_id
	owner = p_owner
	origin = p_origin
	size = p_size
	# Узлы берутся из справочника по типу машины; p_durability остаётся запасным
	# вариантом для машин, которых в VEHICLE_COMPONENTS нет.
	var spec: Dictionary = MCF.VEHICLE_COMPONENTS.get(p_type_id, {})
	if spec.is_empty():
		components = {MCF.COMP_HULL: maxi(0, p_durability)}
	else:
		components = spec.duplicate()


## Машина «жива» (может действовать / учитывается в условии победы), пока есть
## прочность и она не превращена в обломки.
func alive() -> bool:
	return durability > 0 and not wrecked


## Всего занято слотов (живые + трупы); вместимость — в статах машины.
func slots_used() -> int:
	return occupants.size() + corpse_slots.size()


func capacity() -> int:
	return int(VehicleDB.get_vehicle(type_id).get("crew_capacity", 0))


## Число живых членов экипажа — это ОД машины на ход. Пересчитывается началом хода.
func living_crew_count() -> int:
	return occupants.size()


## Каждая клетка следа при текущем origin.
func footprint() -> Array[Vector2i]:
	return footprint_at(origin, size)


## След, который машина заняла БЫ, если бы origin был new_origin — для проверки хода
## без мутации машины.
func footprint_from(new_origin: Vector2i) -> Array[Vector2i]:
	return footprint_at(new_origin, size)


## Опорная клетка для укрытия/линии: геометрический центр (для чётной стороны —
## смещён к правому-нижнему из четырёх средних клеток).
func center() -> Vector2i:
	return center_of(origin, size)


# --- посадка в челнок -----------------------------------------------------

## Гарантировать массив из 4 слотов (лениво, для только что созданного челнока).
func ensure_seats() -> void:
	if seats.size() != SEAT_OFFSETS.size():
		seats = []
		for _i in SEAT_OFFSETS.size():
			seats.append(-1)


## Абсолютная клетка места i (его угла следа) при текущем origin.
func seat_cell(i: int) -> Vector2i:
	return origin + SEAT_OFFSETS[i]


## Id водителя (правое-верхнее место) или -1, если пусто. Пока -1, челнок не едет.
func driver_id() -> int:
	if seats.size() <= DRIVER_SEAT:
		return -1
	return seats[DRIVER_SEAT]


func has_driver() -> bool:
	return driver_id() >= 0


## Индекс места юнита или -1, если его нет на борту.
func seat_of(unit_id: int) -> int:
	return seats.find(unit_id)


## Первое место для садящегося: водителя, если пусто, иначе первое свободное. -1 = полно.
func first_free_seat() -> int:
	ensure_seats()
	if seats[DRIVER_SEAT] == -1:
		return DRIVER_SEAT
	for i in seats.size():
		if seats[i] == -1:
			return i
	return -1


# --- чистая геометрия (статика, без состояния) ----------------------------

static func footprint_at(origin_cell: Vector2i, size_cells: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in size_cells.y:
		for dx in size_cells.x:
			out.append(origin_cell + Vector2i(dx, dy))
	return out


static func center_of(origin_cell: Vector2i, size_cells: Vector2i) -> Vector2i:
	return origin_cell + size_cells / 2


## Есть ли у машины такой узел ВООБЩЕ (у челнока нет башни и пушки).
func has_component(comp: String) -> bool:
	return components.has(comp)

## Текущие очки узла; 0 и для разбитого, и для отсутствующего.
func component(comp: String) -> int:
	return int(components.get(comp, 0))

## Узел ЖИВ: он есть у машины и его очки не на нуле. Именно этот вопрос задают
## и прицеливание, и каскад, и проверки «может ли ехать/стрелять».
func component_alive(comp: String) -> bool:
	return component(comp) > 0

## Стартовая прочность узла — потолок для ремонта.
func component_max(comp: String) -> int:
	return int(MCF.VEHICLE_COMPONENTS.get(type_id, {}).get(comp, 0))

## Узлы этой машины в порядке каскада, только живые.
func live_components() -> Array:
	var out: Array = []
	for comp: String in MCF.COMPONENT_ORDER:
		if component_alive(comp):
			out.append(comp)
	return out

## Гусеницы, которые у этой машины ЕСТЬ (у танка две, у челнока одна общая).
func track_components() -> Array:
	var out: Array = []
	for comp: String in MCF.TRACK_COMPONENTS:
		if has_component(comp):
			out.append(comp)
	return out

## Сколько гусениц ещё целы.
func live_tracks() -> int:
	var n := 0
	for comp: String in track_components():
		if component_alive(comp):
			n += 1
	return n

## ЕХАТЬ можно только на ОБЕИХ гусеницах: порванная с одной стороны машина крутится на
## месте, но вперёд не идёт.
func can_drive() -> bool:
	var tracks := track_components()
	if tracks.is_empty():
		return true
	return live_tracks() == tracks.size()

## ПОВЕРНУТЬ можно, пока цела хоть одна: танк разворачивается, тормозя одной гусеницей.
## Обе порваны — машина стоит намертво, ни хода, ни разворота.
func can_turn() -> bool:
	var tracks := track_components()
	if tracks.is_empty():
		return true
	return live_tracks() > 0

## Может ли машина стрелять главным орудием.
func can_fire_gun() -> bool:
	return component_alive(MCF.COMP_GUN)

## Заклинена ли башня — стрелять можно только вдоль tower_locked_dir.
func tower_jammed() -> bool:
	return has_component(MCF.COMP_TOWER) and not component_alive(MCF.COMP_TOWER)

## Направление заклиненной башни В КООРДИНАТАХ ПОЛЯ: хранится оно относительно фронта,
## поэтому разворот корпуса разворачивает и её. Vector2i.ZERO = машина ещё не стреляла,
## и заклиненная башня не смотрит никуда.
func tower_world_dir() -> Vector2i:
	if tower_locked_dir == Vector2i.ZERO:
		return Vector2i.ZERO
	if facing == Vector2i.ZERO:
		return tower_locked_dir
	# Фронт корпуса — это поворот от «вправо» (1,0). Тем же поворотом крутим и башню.
	return Vector2i(
		tower_locked_dir.x * facing.x - tower_locked_dir.y * facing.y,
		tower_locked_dir.x * facing.y + tower_locked_dir.y * facing.x)

## Запомнить направление выстрела — в координатах КОРПУСА (обратный поворот).
func remember_shot_dir(world_dir: Vector2i) -> void:
	if world_dir == Vector2i.ZERO:
		return
	if facing == Vector2i.ZERO:
		tower_locked_dir = world_dir
		return
	tower_locked_dir = Vector2i(
		world_dir.x * facing.x + world_dir.y * facing.y,
		world_dir.y * facing.x - world_dir.x * facing.y)


## Борт машины, обращённый к клетке from: "front", "back", "left" или "right".
##
## Считается В КООРДИНАТАХ КОРПУСА: важно не где стрелок стоит на карте, а с какой
## стороны он подходит к ЭТОЙ машине. Ось сравнивается с поперечиной, и что больше —
## то и борт; ровно по диагонали засчитывается БОРТ (более строгий ответ), иначе
## угловой выстрел давал бы доступ к обеим гусеницам сразу.
##
## У машины без фронта (челнок) бортов нет — всегда "front": все её узлы открыты.
func side_facing(from: Vector2i) -> String:
	if facing == Vector2i.ZERO:
		return "front"
	var rel := from - center()
	# Вперёд — вдоль фронта; вправо — фронт, повёрнутый на 90° по часовой стрелке
	# (ось Y на поле смотрит ВНИЗ, поэтому это (-y, x)).
	var fwd := rel.x * facing.x + rel.y * facing.y
	var side := rel.x * -facing.y + rel.y * facing.x
	if absi(fwd) > absi(side):
		return "front" if fwd > 0 else "back"
	if side == 0 and fwd == 0:
		return "front"
	return "right" if side > 0 else "left"

## Куда сейчас смотрит ствол В КООРДИНАТАХ ПОЛЯ. Пока машина не стреляла, башня стоит
## по-походному — вдоль корпуса, — и именно этим направлением считается её сектор.
func gun_world_dir() -> Vector2i:
	var locked := tower_world_dir()
	return locked if locked != Vector2i.ZERO else facing
