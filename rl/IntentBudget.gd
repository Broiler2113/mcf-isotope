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
##
## ДРОНЫ В ПОДМНОЖЕСТВЕ ВСЕГДА — по той же причине, что и техника. У дрона одно ОД: после
## подлёта он «выдохся» и попадал в хвост жеребьёвки, а подрыв (бесплатный) предлагался
## только тогда, когда в подмножество попадал выдохшийся юнит, то есть почти никогда.
## Дрон долетал до врага и висел над ним до следующего хода, пока его не сбивали.
##
## «Готов» — это «может что-то сделать», а не «есть ОД»: дострел начатой очереди,
## остаток подлёта/хода, лопата и мины в кредит, рывок из своих рук, выгрузка тела —
## всё это бесплатно и раньше тонуло среди выдохшихся.
static func actor_subset(r: GameActionResolver, acting: int, max_actors: int,
		rng: RandomNumberGenerator) -> Dictionary:
	if max_actors <= 0:
		return {}
	var state := r.state
	var ready: Array = []
	var spent: Array = []
	var always: Array = []
	var captors := {}                     # кто кого держит — один проход, не по юниту
	for u: UnitInstance in state.all_units():
		if u.is_held():
			captors[u.captor_id] = true
	for u: UnitInstance in state.all_units():
		if u.owner != acting or not u.is_alive():
			continue
		if u.is_drone:
			# Без оператора у станции у дрона нет ни одного намерения — и места он не занимает.
			if r.operator_controls(u):
				always.append(u.id)
		elif u.borg_id != -1:
			always.append(u.id)
		else:
			(ready if can_act(r, u, captors) else spent).append(u.id)
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


## Может ли юнит сделать хоть что-то, кроме конца хода (дёшево, без перечисления).
## Список путей — тот же, что в LegalIntents._for_unit; разойдётся — юнит всего лишь уйдёт
## не в ту половину жеребьёвки, а не пропадёт из неё.
##
## Экипаж за картой — не «готов», даже с ОД, если высадка запрещена (танковая карта,
## sealed_crew_maps): у него нет НИ ОДНОГО намерения, а раньше он занимал место в
## подмножестве наравне с пехотой — пятнадцать таких на сторону при шестнадцати местах.
static func can_act(r: GameActionResolver, u: UnitInstance, captors: Dictionary) -> bool:
	if u.aboard_vehicle_id != -1:
		if not r.state.grid.in_bounds(u.coord):
			return u.remaining_ap > 0 and r.disembark_enabled
		return u.remaining_ap > 0 or r.disembark_enabled     # из кресла выходят бесплатно
	if u.is_held():
		var captor := r.state.get_unit(u.captor_id)
		return u.remaining_ap > 0 or (captor != null and captor.owner == u.owner)
	return u.remaining_ap > 0 or u.move_credit > 0 or u.dig_credits > 0 or u.mine_credits > 0 \
			or (u.action_state != null and u.action_state.is_pending()) \
			or u.carried_corpses > 0 or captors.has(u.id)


## Клетки, выстрел в которые может задеть ВИДИМОГО врага стороны `side`: клетка каждого
## видимого вражеского юнита и каждой видимой клетки вражеской машины плюс восемь соседних
## (разрыв ПТ, струя огнемёта и снаряд пушки бьют по площади). Значение — СКОЛЬКО врагов
## накроет квадрат 3×3 с центром в этой клетке: им cap() ставит лучший подрыв первым.
## Невидимые враги не в счёт:
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
				var k := c + Vector2i(dx, dy)
				zone[k] = int(zone.get(k, 0)) + 1
	return zone

## Нацелен ли выстрел в зону видимого врага (hostile_zone). Не-выстрелы — false.
##
## Нужен потому, что цель у пушки танка, разрыва ПТ и огнемёта — КЛЕТКА, а не юнит:
## перечислитель честно предлагает стрелять по любой клетке в секторе, и почти все они
## пусты. Винтовочный выстрел адресован юниту-врагу и проходит проверку всегда.
static func aims_at(intent: Intent, zone: Dictionary, state: GameState) -> bool:
	if intent is VehicleCannonIntent:
		return zone.has(intent.target)
	if intent is DroneMoveIntent:
		return zone.has(intent.target)
	if intent is DroneDetonateIntent:
		var d := state.get_unit(intent.actor_id)
		return d != null and zone.has(d.coord)
	if intent is UseItemIntent:
		var thrower := state.get_unit(intent.actor_id)
		return thrower != null and thrower.held_item_id == MCF.ITEM_FRAG and zone.has(intent.target)
	if intent is ShootIntent or intent is DPMGFireIntent:
		if intent.target_id >= 0:
			var t := state.get_unit(intent.target_id)
			return t != null and zone.has(t.coord)
		return intent is ShootIntent and zone.has(intent.target_cell)
	return false


## Выбросить выстрелы «в пустоту»: пушку танка, разрыв ПТ и струю огнемёта по клетке, рядом
## с которой не стоит ни одного видимого врага. Тот же принцип, что «стрельба только по
## врагам» у винтовки (LegalIntents): ход, ценность которого почти всегда нулевая, не
## держим в пространстве действий. Иначе целиться — отдельная задача: у танка из ~366
## клеток сектора враг рядом с ~20, и town-8 за 4.8 млн шагов её не решил (6% попаданий
## против 56% у ИИ); 20 апдейтов с премией только за прицельные — тоже 6%.
##
## Цена: нельзя выстрелить вслепую в туман и нарочно подорвать стену. Выстрел по юниту
## (винтовка, пулемёт, ПТ по цели) не трогается — он и так всегда по врагу.
static func drop_blind_shots(list: Array, r: GameActionResolver, side: int) -> Array:
	var zone := hostile_zone(r, side)
	var out: Array = []
	for it: Intent in list:
		var cell_shot: bool = it is VehicleCannonIntent or (it is ShootIntent and it.target_id < 0)
		if cell_shot and not aims_at(it, zone, r.state):
			continue
		out.append(it)
	return out


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
			# Лучший подрыв — первым: у дрона сотни клеток полёта, и из тех, что рядом с
			# врагом, в список доходит пара штук. Раньше это были случайные соседи
			# ближайшего врага, а не клетка над скоплением.
			hit.sort_custom(func(a: Intent, b: Intent) -> bool:
				return _aim_count(a, zone, r.state) > _aim_count(b, zone, r.state))
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


## Сколько врагов накрывает прицельное намерение (для порядка внутри корзины).
static func _aim_count(intent: Intent, zone: Dictionary, state: GameState) -> int:
	var c := Vector2i(-999, -999)
	if intent is DroneDetonateIntent:
		var d := state.get_unit(intent.actor_id)
		if d != null:
			c = d.coord
	elif "target" in intent and intent.target is Vector2i:
		c = intent.target
	elif "target_id" in intent and intent.target_id >= 0:
		var t := state.get_unit(intent.target_id)
		if t != null:
			c = t.coord
	elif "target_cell" in intent:
		c = intent.target_cell
	return int(zone.get(c, 0))


static func shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
