class_name VehicleDB
extends RefCounted

## Статы техники (раздел «Техника» правил МКФ). Значения — ПО ПРАВИЛАМ книги
## (не по варианту isotope, где танк speed 6, а челнок durability 4).
##
## Поля записи:
##   name          — отображаемое имя.
##   size          — след [w, h] в клетках.
##   durability    — ПРЕЖНИЙ единый пул прочности. С вехи «Modular tank system»
##                   машина разбита на узлы, и её живучесть задаёт
##                   MCF.VEHICLE_COMPONENTS; здесь значение осталось запасным —
##                   его берут только типы, которых в том словаре нет.
##   crew_capacity — всего слотов (живой экипаж + трупы).
##   speed         — очки движения за действие «ход».
##   has_facing    — есть ли фронт (танк — да; челнок — нет).
##   cost          — цена в очках для point-buy.
##   weapons       — список орудий (см. ниже; у челнока пусто).
##
## Орудия танка:
##   main_gun  — пушка: дальность 24 (#22), взрыв-ромб радиуса 2 (#63), 1 ОД,
##               2 прочности технике; не чаще 2×/ход.
## Вторичного лазера у танка больше нет (#63) — единственное орудие — пушка.
const VEHICLES := {
	"tank": {
		"name": "Tank",
		"size": [3, 3],
		"durability": 6,
		"crew_capacity": 3,
		"speed": 16,
		"has_facing": true,
		"cost": 500,
		"weapons": {
			"main_gun": {
				"range": 24, "blast_radius": 2, "ap_cost": 1,
				"vehicle_damage": 2, "max_per_turn": 2,
			},
		},
	},
	"shuttle": {
		"name": "Space Shuttle",
		"size": [2, 2],
		"durability": 4,
		"crew_capacity": 4,
		"speed": 30,
		"has_facing": false,
		"cost": 125,
		"weapons": {},
		# Посадочные места (batch 13, «Shuttle changes»): пассажиры сидят В КЛЕТКАХ
		# следа, видны поверх корпуса, стреляют со своего места и сами под обстрелом.
		# Ходит машина за ОД ВОДИТЕЛЯ: 1 ОД за каждые SHUTTLE_CELLS_PER_AP клеток.
		"seated": true,
	},
	# Борг (batch 13, «Borg characteristics»): одноместная машина 1×1 без узлов, кроме
	# корпуса. Играется как боец — см. UnitInstance.borg_id и MCF.BORG_*.
	"borg": {
		"name": "Borg",
		"size": [1, 1],
		"durability": 2,
		"crew_capacity": 1,
		"speed": 9,
		"has_facing": false,
		"cost": 100,
		"weapons": {},
		"borg": true,
	},
}

## Бросок на уничтожение (1d6): порог «взрыв» и радиус.
## Танк: всегда остаётся корпусом-обломком (укрытие/блок линии); при 4+ ещё и
## взрывается радиусом 2. Челнок: 1-2 → взрыв радиусом 1, иначе просто уничтожен
## (корпуса не остаётся).
const DESTRUCTION := {
	"tank": {"explode_min": 4, "explode_radius": 2, "wreck": true},
	"shuttle": {"explode_min": 1, "explode_max": 2, "explode_radius": 1, "wreck": false},
	# Борг: 4+ — взрыв радиуса 1 (квадрат 3×3, как противотанковый заряд), и тогда от
	# него ничего не остаётся; 1–3 — остов, занимающий клетку.
	"borg": {"explode_min": 4, "explode_radius": 1, "wreck": true, "square": true,
		"wreck_unless_exploded": true},
}

## Машина с посадочными местами: экипаж сидит в клетках следа (челнок).
static func is_seated(id: String) -> bool:
	return bool(VEHICLES.get(id, {}).get("seated", false))

## Борг — одноместная машина, которой управляют как бойцом.
static func is_borg(id: String) -> bool:
	return bool(VEHICLES.get(id, {}).get("borg", false))

static func get_vehicle(id: String) -> Dictionary:
	return VEHICLES.get(id, {})

static func is_vehicle(id: String) -> bool:
	return VEHICLES.has(id)

static func size_of(id: String) -> Vector2i:
	var s: Array = VEHICLES.get(id, {}).get("size", [1, 1])
	return Vector2i(int(s[0]), int(s[1]))

static func ids() -> Array:
	return VEHICLES.keys()

## Цена в очках для point-buy; 0 для неизвестного id.
static func buy_cost(id: String) -> int:
	return int(VEHICLES.get(id, {}).get("cost", 0))
