class_name Combat
extends RefCounted

## Боевая математика и геометрия ЛОС (см. §3.5, §7).
## Только чистые функции — легко покрывать тестами.

## Дистанция в клетках. Метрика — Чебышёв: диагональный шаг = 1 клетка.
## (Решение автора 2026-08-30; в дизайн-документе метрика не зафиксирована.)
static func distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))

## Число, которое надо выбросить на d6, чтобы попасть (§3.5):
##   x = ceil(дистанция / (дальность / 6))
## Возвращает 1..7; 7 = попасть невозможно.
static func hit_number(dist: int, fire_range: float) -> int:
	if fire_range <= 0.0:
		return 7
	var x := int(ceil(float(dist) / (fire_range / 6.0)))
	return clampi(x, 1, 7)

## Вероятность попадания одним кубиком: P = 1 - (x - 1) / 6.
static func hit_probability(dist: int, fire_range: float) -> float:
	var x := hit_number(dist, fire_range)
	return clampf(1.0 - float(x - 1) / 6.0, 0.0, 1.0)

## Клетки на прямой линии от a до b НЕ включая концы.
## ЛОС только по прямым: вертикаль, горизонталь, диагональ (§3.5).
## Возвращает пустой массив, если a и b не на одной из этих линий.
static func line_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var delta := b - a
	if delta == Vector2i.ZERO:
		return out
	var is_straight := delta.x == 0 or delta.y == 0 or absi(delta.x) == absi(delta.y)
	if not is_straight:
		return out
	var step := Vector2i(signi(delta.x), signi(delta.y))
	var cur := a + step
	while cur != b:
		out.append(cur)
		cur += step
	return out

## Лежит ли цель на прямой линии огня (вертикаль/горизонталь/диагональ) от стрелка.
## Проверка перекрытия юнитами/стенами — отдельно, в резолвере, через line_cells().
static func is_on_firing_line(a: Vector2i, b: Vector2i) -> bool:
	var delta := b - a
	if delta == Vector2i.ZERO:
		return false
	return delta.x == 0 or delta.y == 0 or absi(delta.x) == absi(delta.y)
