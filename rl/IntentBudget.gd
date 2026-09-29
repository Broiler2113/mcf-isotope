extends RefCounted

const Obs = preload("res://rl/ObsEncoder.gd")

## Бюджет намерений: сколько актёров рассматривать за шаг и сколько кандидатов оставлять.
##
## Живёт отдельно, потому что ОБЕ стороны провода обязаны применять его одинаково. Среда
## обучения (rl/env_server.gd) режет список перед тем, как показать его политике; значит и
## боевой контроллер (src/controllers/LearnedController.gd) обязан резать так же, иначе в
## настоящей партии сеть увидит 8000 кандидатов там, где училась на 512, и будет выбирать
## argmax по совсем другому множеству. Раньше эти функции были только в env_server — и
## расхождение появилось ровно в тот день, когда в обучение добавили потолки.
##
## Ноль в любом из потолков означает «без ограничения».


## Подмножество актёров, которых перечислитель рассматривает на ЭТОМ шаге (пусто = все).
##
## Перебор всех 176 бойцов ротной карты стоит ~148 мс за точку решения; за ход таких точек
## сотни. Выбор новый на каждом шаге, так что за ход очередь доходит до всех. Сначала берутся
## те, у кого ОСТАЛИСЬ ОД: иначе подмножество из выдохшихся юнитов не предложило бы ничего,
## кроме конца хода, и сторона теряла бы ход с полными ОД на руках.
##
## ТЕХНИКА В ПОДМНОЖЕСТВЕ ВСЕГДА. Случайные 16 актёров из 176 означали, что намерения
## конкретной машины попадали в список примерно в 9% точек решения: политика физически
## почти не видела танк, шаттл и борга, и в записях боёв они простаивали всю партию.
## Научиться пользоваться тем, чего не показывают, нельзя, поэтому машины берутся ВНЕ
## жребия. Их мало (на town'е три на сторону), так что на долю пехоты это почти не влияет.
##
## Борг — не самостоятельный актёр: LegalIntents перечисляет его через юнита-пилота
## (u.borg_id != -1), поэтому здесь резервируется именно пилот, а сам борг пропускается —
## ровно как в LegalIntents.enumerate.
static func actor_subset(r: GameActionResolver, acting: int, max_actors: int,
		rng: RandomNumberGenerator) -> Dictionary:
	if max_actors <= 0:
		return {}
	var state := r.state
	var ready: Array = []
	var spent: Array = []
	var always: Array = []
	for u: UnitInstance in state.all_units():
		if u.owner != acting or not u.is_alive():
			continue
		if u.borg_id != -1:
			always.append(u.id)
		else:
			(ready if u.remaining_ap > 0 else spent).append(u.id)
	for veh: Vehicle in state.all_vehicles():
		if veh.owner != acting or not veh.alive() or veh.is_borg():
			continue
		always.append("v%d" % veh.id)
	if always.size() + ready.size() + spent.size() <= max_actors:
		return {}
	shuffle(ready, rng)
	shuffle(spent, rng)
	var out := {}
	# Машины и пилоты боргов — целиком, даже если их одних больше потолка: потолок стоит
	# ради цены перечисления пехоты, а техники на карте единицы.
	for key: Variant in always:
		out[key] = true
	for key: Variant in ready + spent:
		if out.size() >= max_actors:
			break
		out[key] = true
	return out


## Клетки, выстрел в которые может задеть ВИДИМОГО врага стороны `side`: клетка каждого
## видимого вражеского юнита и каждой видимой клетки вражеской машины плюс восемь соседних
## (разрыв ПТ, струя огнемёта и снаряд пушки бьют по площади). Невидимые враги не в счёт:
## иначе награда за «выстрел по врагу» подсказывала бы, где в тумане кто-то стоит.
static func hostile_zone(r: GameActionResolver, side: int) -> Dictionary:
	var zone := {}
	var visible: Dictionary = r.team_visible_coords(side) if r.fog_enabled else {}
	var cells: Array = []
	for u: UnitInstance in r.state.all_units():
		if u.is_alive() and Obs.rel_owner(r, side, u.owner) == 1:
			cells.append(u.coord)
	for veh: Vehicle in r.state.all_vehicles():
		if veh.alive() and Obs.rel_owner(r, side, veh.owner) == 1:
			cells.append_array(veh.footprint())
	for c: Vector2i in cells:
		if r.fog_enabled and not visible.has(c):
			continue
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				zone[c + Vector2i(dx, dy)] = true
	return zone

## Нацелен ли выстрел в зону видимого врага (hostile_zone). Не-выстрелы — false.
##
## Нужен потому, что цель у пушки танка, разрыва ПТ и огнемёта — КЛЕТКА, а не юнит:
## перечислитель честно предлагает стрелять по любой клетке в секторе, и почти все они
## пусты. Винтовочный выстрел адресован юниту-врагу и проходит проверку всегда.
static func aims_at(intent: Intent, zone: Dictionary, state: GameState) -> bool:
	if intent is VehicleCannonIntent:
		return zone.has(intent.target)
	if intent is ShootIntent or intent is DPMGFireIntent:
		if intent.target_id >= 0:
			var t := state.get_unit(intent.target_id)
			return t != null and zone.has(t.coord)
		return intent is ShootIntent and zone.has(intent.target_cell)
	return false


## Урезать список кандидатов до max_candidates, НЕ обедняя выбор.
##
## Равномерная выборка здесь была бы ловушкой: на town'е 59% списка — «шагнуть», и случайные
## 768 из 8366 почти наверняка не содержали бы ни одного выстрела. Поэтому корзины
## (актёр, вид намерения) обходятся по кругу: каждый юнит получает по одному варианту КАЖДОГО
## своего вида, прежде чем кто-то получит второй. Редкие виды (выстрел, постройка, посадка)
## выживают целиком, режется только избыток ходов. EndTurn остаётся всегда — иначе ход
## стало бы нечем закончить.
##
## С резолвером (r, side) внутри каждой корзины первыми идут выстрелы по видимому врагу,
## так что потолок режет только выстрелы в пустоту. Замер на танковой карте (366 точек
## решения): прицельный выстрел доступен в 288, и без приоритета из ~20 прицельных вариантов
## выживало в среднем 15.5, с приоритетом — все. Причиной 6% попаданий town-8 это НЕ было
## (хотя бы один прицельный вариант оставался всегда): политика выбирала клетку наугад,
## потому что премия за выстрел платилась и за пустую — см. _combat_reward в env_server.
static func cap(list: Array, max_candidates: int, rng: RandomNumberGenerator,
		r: GameActionResolver = null, side: int = -1) -> Array:
	if max_candidates <= 0 or list.size() <= max_candidates:
		return list
	var buckets := {}
	var order: Array = []
	var kept: Array = []
	for intent: Intent in list:
		if intent is EndTurnIntent:
			kept.append(intent)
			continue
		var key := "%d:%s" % [intent.actor_id, str(IntentCodec.encode(intent).get("t", ""))]
		if not buckets.has(key):
			buckets[key] = []
			order.append(key)
		buckets[key].append(intent)
	shuffle(order, rng)
	var zone := hostile_zone(r, side) if r != null else {}
	for key: String in order:
		shuffle(buckets[key], rng)
		if not zone.is_empty():
			# Порядок внутри корзины — после той же перетасовки, так что жребий (и значит
			# детерминизм от сида) не меняется; меняется лишь то, кто стоит первым.
			var hit: Array = []
			var rest: Array = []
			for it: Intent in buckets[key]:
				(hit if aims_at(it, zone, r.state) else rest).append(it)
			buckets[key] = hit + rest
	var round_index := 0
	while kept.size() < max_candidates:
		var took := false
		for key: String in order:
			var b: Array = buckets[key]
			if round_index >= b.size():
				continue
			kept.append(b[round_index])
			took = true
			if kept.size() >= max_candidates:
				break
		if not took:
			break          # все корзины исчерпаны раньше потолка
		round_index += 1
	return kept


static func shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
