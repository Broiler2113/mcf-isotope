class_name UnitInstance
extends RefCounted

## Экземпляр юнита на поле: ссылка на характеристики + изменяемое состояние (§6).

## Версия «состава и расстановки войск». Растёт на каждое изменение поля, от которого
## зависит ОБЗОР КОМАНДЫ: координата, признак жизни и сторона юнита.
##
## Нужна ровно для одного: чтобы GameActionResolver.team_visible_coords() умел за одно
## сравнение ответить «с прошлого раза ничего не изменилось». Его зовут из can_shoot()
## по разу на КАЖДУЮ возможную цель, то есть десятки тысяч раз за один показ доступных
## целей; без этой проверки каждый такой вызов заново перебирал бы всю армию, сверяя
## позиции. Версия сетки (GridCell.vision_version) на роль подписи не годится: боец
## погибает, не трогая ни одной клетки — occupant остаётся на месте, теперь как труп.
##
## Поля-источники ОБЯЗАНЫ писаться через сеттеры (то есть обычным `u.coord = x`).
## Запись тем же значением версию не двигает — из тех же соображений, что и в GridCell.
static var vision_epoch: int = 0

var id: int = -1
var stats: UnitStats
var coord: Vector2i:
	set(v):
		if coord == v:
			return
		coord = v
		vision_epoch += 1
var owner: int:
	set(v):
		if owner == v:
			return
		owner = v
		vision_epoch += 1
var remaining_ap: int
var status: int = MCF.Status.ALIVE:
	set(v):
		if status == v:
			return
		status = v
		vision_epoch += 1
var action_state: ActionState = null
var held_item_id: String = ""
## Кто удерживает этого юнита (id захватившего), -1 = свободен (§3.4).
var captor_id: int = -1
## Дрон (§3.12): помечает летающую сущность и её привязку к станции/оператору.
var is_drone: bool = false
var home_station: Vector2i = Vector2i(-1, -1)
var operator_id: int = -1
## Клетка, С КОТОРОЙ дрон завис над стеной (#96); (-1,-1) — он не над стеной.
## Сквозь стену дрон не летает, он лишь зависает над ней, поэтому со стены есть ровно
## один путь — обратно тем же курсом. Без этой памяти дрон переползал бы стену по
## клеткам и оказывался на другой стороне.
var wall_entry_from: Vector2i = Vector2i(-1, -1)
## Мирный житель (§3.10): «вскрыт» ли (замечен/задет) — тогда начинает двигаться.
var civilian_active: bool = false
## Удерживаемого юнита нельзя переносить более одного раза за ход (§3.4).
var carried_this_round: bool = false
## Внутри машины (§техника): id машины, -1 = на поле. Экипаж/пассажир не на сетке.
var aboard_vehicle_id: int = -1
## Остаток «бесплатных» окопов в текущей копке (§3.7): за 1 ОД пехота роет 3, инженер 6.
## Сбрасывается при любом другом действии и в конце хода.
var dig_credits: int = 0
## Инженер получает лишь ОДНУ ЛДФ-стену за игру (#40). После постройки — true.
var ldf_wall_used: bool = false
## Остаток мин текущего действия сапёра (item 45). В отличие от dig_credits, ДРУГИЕ
## действия его НЕ гасят: источник прямо требует, чтобы прерванный сапёр доставил
## оставшиеся мины позже. Гаснет на границе раунда, вместе с ОД.
var mine_credits: int = 0
## Остаток очков движения текущего действия Движения (#44): позволяет доходить
## оставшиеся клетки в рамках того же ОД. Сбрасывается любым другим действием и AP.
var move_credit: int = 0
## Подобранные трупы, которые юнит несёт как переносной щит (#6): каждый даёт +1
## к его броскам защиты. Не сбрасывается на границе раунда — щит остаётся при юните.
var carried_corpses: int = 0
## Клетка с лёгким объектом (мешки/ёж/куча), который юнит тащит за собой (#34).
## Пока объект в руках, движение идёт с тем же штрафом, что и перенос пленника.
const NOT_DRAGGING := Vector2i(-9999, -9999)
var dragging: Vector2i = NOT_DRAGGING

func _init(p_id: int, p_stats: UnitStats, p_coord: Vector2i, p_owner: int) -> void:
	id = p_id
	stats = p_stats
	coord = p_coord
	owner = p_owner
	remaining_ap = max_ap()
	held_item_id = p_stats.default_item_id if p_stats else ""
	# Новый боец на поле — это изменение состава, даже если сеттеры промолчали (боец
	# первой стороны в клетке (0,0) получил бы ровно те значения, что уже стояли).
	vision_epoch += 1

## Сколько ОД юнит получает в свою активацию. Обычно MCF.AP_PER_ACTIVATION, но
## статы могут задать своё число — у командира их 3 (#66).
func max_ap() -> int:
	if stats != null and stats.action_points > 0:
		return stats.action_points
	return MCF.AP_PER_ACTIVATION

func is_alive() -> bool:
	return status == MCF.Status.ALIVE

func is_held() -> bool:
	return status == MCF.Status.HELD

## На поле присутствует (жив или удерживается), не труп — можно выбрать/учитывать.
func is_on_field() -> bool:
	return status != MCF.Status.CORPSE

func reset_ap() -> void:
	remaining_ap = max_ap()
	# Дробимое действие сбрасывается на границе раунда (см. §3.2).
	action_state = null
	# Ограничение «перенос раз за ход» снимается на границе раунда (§3.4).
	carried_this_round = false
	# Недоиспользованное движение не переносится через раунд (#44).
	move_credit = 0
	# Объект выпускается из рук на границе раунда (#34).
	dragging = NOT_DRAGGING
	# Недоставленные мины через раунд не переносятся (item 45).
	mine_credits = 0

func kill() -> void:
	status = MCF.Status.CORPSE
	remaining_ap = 0
	action_state = null
