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

## Прочность (durability). При 0 машина уничтожена (бросок — на стороне резолвера).
var durability: int = 0

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
	durability = p_durability


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
