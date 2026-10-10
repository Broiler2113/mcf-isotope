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
##
## СРЕДИ ГОТОВЫХ ПЕРВЫМИ — ТЕ, КОМУ ЕСТЬ В КОГО СТРЕЛЯТЬ (видимый враг на линии огня в
## пределах дальности). Жребий 16 из ~46 показывал выстрел редкого бойца лишь в части точек,
## где он был законен: на 17 партиях оценки tactical-1 снайпера — в 46%, противотанкиста по
## технике — в 41%, огнемётчика — в 47%. Политика, увидев снайперский выстрел, брала его в
## 31% случаев — она не отказывалась стрелять, ей просто не показывали. Внутри обеих групп
## порядок по-прежнему жребий, и вызовы rng те же, что и раньше.
static func actor_subset(r: GameActionResolver, acting: int, max_actors: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var sight_limited := r.visibility_limited()
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
	var foes := _foe_cells(r, acting)
	var hazards := Obs.hazards(r)
	var endangered: Array = []
	var vehicle_response: Array = []
	var hot: Array = []
	var cold: Array = []
	var visible_vehicles: Array[Vector2i] = []
	var visible: Dictionary = r.team_visible_coords(acting) if sight_limited else {}
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and Obs.rel_owner(r, acting, veh.owner) == 1:
			for c: Vector2i in veh.footprint():
				if not sight_limited or visible.has(c):
					visible_vehicles.append(c)
	for id: int in ready:
		var u := state.get_unit(id)
		var danger := false
		if state.grid.in_bounds(u.coord) and u.aboard_vehicle_id == -1:
			var i := u.coord.y * state.grid.width + u.coord.x
			danger = hazards["gas"][i] + hazards["gas_warning"][i] + hazards["artillery_warning"][i] > 0.0
		if danger:
			endangered.append(id)
		elif u.stats.special_ability_id == MCF.ABILITY_ANTI_TANK \
				and _nearest(visible_vehicles, u.coord) <= int(u.fire_range()) + 4:
			vehicle_response.append(id)
		else:
			(hot if in_contact(u, foes) else cold).append(id)
	ready = endangered + vehicle_response + hot + cold
	var out := {}
	# Машины и пилоты боргов — целиком, даже если их одних больше потолка: потолок стоит
	# ради цены перечисления пехоты, а техники на карте единицы.
	for key: Variant in always:
		out[key] = true
	var infantry_count := 0
	for key: Variant in ready + spent:
		if infantry_count >= max_actors:
			break
		out[key] = true
		infantry_count += 1
	return out


## A company-sized army must actually spend part of its turn. A policy trained on
## platoons can otherwise put most of the softmax mass on EndTurn at its first
## decision on a 100+ soldier board. Apply the same legal gate in training and play.
## Keep EndTurn when no useful action exists, so an obstructed army cannot deadlock.
static func keep_large_army_active(list: Array, state: GameState, side: int) -> Array:
	var troops := 0
	var remaining := 0.0
	var capacity := 0.0
	for u: UnitInstance in state.all_units():
		if u.owner != side or not u.is_alive() or u.is_drone or u.aboard_vehicle_id != -1:
			continue
		troops += 1
		capacity += float(u.max_ap())
		remaining += float(u.remaining_ap)
	if troops < 64 or capacity <= 0.0 or remaining / capacity <= 0.50:
		return list
	var useful := false
	for intent: Intent in list:
		if intent is MoveIntent or intent is ShootIntent or intent is VehicleCannonIntent \
				or intent is VehicleMoveIntent or intent is DroneMoveIntent:
			useful = true
			break
	if not useful:
		return list
	return list.filter(func(intent: Intent) -> bool: return not intent is EndTurnIntent)


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


## Клетки ВИДИМЫХ врагов стороны: бойцы (_visible_foes) и след каждой машины. Туман честен.
static func _foe_cells(r: GameActionResolver, side: int) -> Array[Vector2i]:
	var sight_limited := r.visibility_limited()
	var out := _visible_foes(r, side)
	var visible: Dictionary = r.team_visible_coords(side) if sight_limited else {}
	for veh: Vehicle in r.state.all_vehicles():
		if veh.alive() and Obs.rel_owner(r, side, veh.owner) == 1:
			for c: Vector2i in veh.footprint():
				if not sight_limited or visible.has(c):
					out.append(c)
	return out

## Есть ли у бойца в кого стрелять: враг в пределах дальности и на линии огня (8 направлений).
## Только порядок жеребьёвки, не законность: стены и укрытия проверит перечислитель.
## Разрыв ПТ и струя огнемёта бьют по клетке, а не по линии — им хватает дальности.
static func in_contact(u: UnitInstance, foes: Array[Vector2i]) -> bool:
	if u == null:
		return false
	var reach := u.fire_range()
	if reach <= 0.0:
		return false
	var ability := u.stats.special_ability_id
	var any_line := ability == MCF.ABILITY_ANTI_TANK or ability == MCF.ABILITY_FLAMETHROWER
	for c: Vector2i in foes:
		if float(Combat.distance(u.coord, c)) <= reach \
				and (any_line or Combat.is_on_firing_line(u.coord, c)):
			return true
	return false


## Клетки, выстрел в которые может задеть ВИДИМОГО врага стороны `side`: клетка каждого
## видимого вражеского юнита и каждой видимой клетки вражеской машины плюс восемь соседних
## (разрыв ПТ, струя огнемёта и снаряд пушки бьют по площади). Значение — СКОЛЬКО врагов
## накроет квадрат 3×3 с центром в этой клетке: им cap() ставит лучший подрыв первым.
## Невидимые враги не в счёт:
## иначе награда за «выстрел по врагу» подсказывала бы, где в тумане кто-то стоит.
static func hostile_zone(r: GameActionResolver, side: int) -> Dictionary:
	var sight_limited := r.visibility_limited()
	var zone := {}
	var visible: Dictionary = r.team_visible_coords(side) if sight_limited else {}
	var cells: Array = []
	for u: UnitInstance in r.state.all_units():
		if u.is_alive() and Obs.rel_owner(r, side, u.owner) == 1:
			cells.append(u.coord)
	for veh: Vehicle in r.state.all_vehicles():
		if veh.alive() and Obs.rel_owner(r, side, veh.owner) == 1:
			cells.append_array(veh.footprint())
	for c: Vector2i in cells:
		if sight_limited and not visible.has(c):
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
		var key := "%d:%s" % [intent.actor_id, _kind(intent)]
		if not buckets.has(key):
			buckets[key] = []
			order.append(key)
		buckets[key].append(intent)
	shuffle(order, rng)
	var zone := hostile_zone(r, side) if r != null else {}
	for key: String in order:
		shuffle(buckets[key], rng)
		# Пеший ход не прицеливается никогда — тысячи ходов незачем проверять на прицел.
		if not zone.is_empty() and not key.ends_with(":move"):
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
	if r != null:
		var foes := _visible_foes(r, side)
		var hazards := Obs.hazards(r)
		var vehicle_risk := Obs.vehicle_crush_threat(r, side)
		for key: String in order:
			if key.ends_with(":move") and buckets[key].size() > 4:
				buckets[key] = _tactical_order(buckets[key], r, side, foes, hazards, vehicle_risk)
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


## Порядок ходов внутри корзины юнита: лучшие по тактике вперемешку со случайными.
##
## Потолок кандидатов режет корзину «шагнуть» сильнее всего: у бойца сотни клеток хода, в
## список доходят единицы. Случайные единицы означали, что клетка за укрытием или вне
## простреливаемой линии попадала к политике по жребию, — научиться выбирать её из того,
## чего не показывают, нельзя. Чистая сортировка по эвристике была бы другой ловушкой:
## политика видела бы только то, что считает хорошим эвристика, и не превзошла бы её.
## Поэтому через одного: лучший по оценке, случайный, следующий лучший, случайный…
##
## Оценка клетки: меньше огня по ней (fire_cover врага, туман честен), есть укрытие, ближе
## к видимому врагу. Порядок исходного списка уже перетасован жребием, так что детерминизм
## от сида сохраняется.
static func _visible_foes(r: GameActionResolver, side: int) -> Array[Vector2i]:
	var foes: Array[Vector2i] = []
	var grid := r.state.grid
	for u: UnitInstance in r.state.all_units():
		if u.is_alive() and not u.is_drone and grid.in_bounds(u.coord) \
				and Obs.rel_owner(r, side, u.owner) == 1 and r.is_visible_to_team(side, u):
			foes.append(u.coord)
	return foes

static func _tactical_order(moves: Array, r: GameActionResolver, side: int,
		all_foes: Array[Vector2i] = [], hazards: Dictionary = {},
		vehicle_risk: PackedFloat32Array = PackedFloat32Array()) -> Array:
	var state := r.state
	var grid := state.grid
	var gw := grid.width
	var threat := r.fire_cover(side, true)
	if hazards.is_empty():
		hazards = Obs.hazards(r)
	if vehicle_risk.is_empty():
		vehicle_risk = Obs.vehicle_crush_threat(r, side)
	var foes: Array[Vector2i] = all_foes.duplicate() if not all_foes.is_empty() \
			else _visible_foes(r, side)
	# With no visible contact on a Giant board, keep some moves that advance
	# beyond deployment instead of filling the budget with random local shuffles.
	if foes.is_empty() and maxi(grid.width, grid.height) >= 100:
		foes.append(Vector2i(grid.width / 2, grid.height / 2))
	var actor := state.get_unit(moves[0].actor_id)
	# Сближение меряем до шести ближайших к бойцу врагов, а не до всех: дальше его хода
	# остальные на выбор клетки не влияют, а перебор «каждая клетка × каждый враг» на
	# ротной карте стоил больше, чем весь остальной шаг.
	if actor != null and foes.size() > 6:
		var ac := actor.coord
		var dk := PackedInt64Array()
		for i in foes.size():
			dk.append(Combat.distance(foes[i], ac) * 4096 + i)
		dk.sort()
		var near: Array[Vector2i] = []
		for j in 6:
			near.append(foes[dk[j] % 4096])
		foes = near
	var d0 := _nearest(foes, actor.coord) if actor != null else 0
	# Ключ сортировки — целое: оценка (в сотых, со сдвигом в плюс) и индекс. Родная
	# сортировка целых на порядок быстрее sort_custom с лямбдой, а индекс сохраняет
	# порядок жребия при равной оценке.
	var keys := PackedInt64Array()
	for i in moves.size():
		var c: Vector2i = moves[i].target
		var sc := -1.5 * minf(threat[c.y * gw + c.x], 4.0)
		var ci := c.y * gw + c.x
		# Public event warnings must survive candidate pruning, even under fog.
		if actor != null and actor.borg_id == -1:
			sc -= 6.0 * (hazards["gas"][ci] + hazards["gas_warning"][ci])
			sc -= 6.0 * hazards["artillery_warning"][ci]
			sc -= 8.0 * vehicle_risk[ci]
		if grid.cell_fast(c.x, c.y).has_cover():
			sc += 1.0
		if not foes.is_empty():
			sc += (0.30 if maxi(grid.width, grid.height) >= 100 else 0.15) \
				* float(d0 - _nearest(foes, c))
		keys.append(int(round((1000.0 - sc) * 100.0)) * 65536 + i)
	keys.sort()
	var out: Array = []
	var used := PackedByteArray()
	used.resize(moves.size())
	var top := 0
	var rnd := 0
	while out.size() < moves.size():
		while top < keys.size() and used[keys[top] % 65536]:
			top += 1
		if top < keys.size():
			var bi: int = keys[top] % 65536
			used[bi] = 1
			out.append(moves[bi])
		while rnd < moves.size() and used[rnd]:
			rnd += 1
		if rnd < moves.size():
			used[rnd] = 1
			out.append(moves[rnd])
	return out

static func _nearest(foes: Array[Vector2i], c: Vector2i) -> int:
	var best := 1 << 20
	for f: Vector2i in foes:
		best = mini(best, Combat.distance(f, c))
	return best


## Вид намерения для корзины. Ходы — большая часть списка (с зонами 2-3 ОД их тысячи), и
## строить на каждый словарь провода ради одной строки «move» стоило десятки миллисекунд
## на шаг; частые виды узнаются по классу, остальные — как раньше, через провод.
static func _kind(intent: Intent) -> String:
	if intent is MoveIntent:
		return "move"
	if intent is DroneMoveIntent:
		return "drone_move"
	if intent is VehicleMoveIntent:
		return "veh_move"
	return str(IntentCodec.encode(intent).get("t", ""))


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
