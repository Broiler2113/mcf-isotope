class_name AIController
extends PlayerController

## Компьютерный противник (M6, §11, §2.1). Жадный тактик: на каждый вызов
## begin_turn() выбирает ОДНО лучшее действие среди своих юнитов и отдаёт его
## как Intent (мутации — только в резолвере, §2.2). Ведущий контроллер (Main)
## снова вызывает begin_turn() после применения — так набирается ход целиком,
## пока не вернётся EndTurnIntent.
##
## Оценка (§11 «position-evaluation»): стрельба ценнее захвата, захват ценнее
## сближения; сближение тем ценнее, чем сильнее сокращает дистанцию до врага и
## чем выше укрытие в целевой клетке. Сложность меняет качество выбора.
##
## С #103 этот же класс водит и МИРНЫХ ЖИТЕЛЕЙ (owner == MCF.Owner.NEUTRAL): раньше у
## них был отдельный, куда более тупой мозг в резолвере, который двигал жителя по одной
## клетке за раз и не знал ни плана, ни укрытий, ни дробления действий. Двух систем с
## одинаковой задачей быть не должно, поэтому осталась одна. Нейтральная сторона тут не
## особый случай, а просто третий владелец: «врагами» для неё автоматически становятся
## обе игровые армии (см. _enemies_of), а друг друга жители не трогают, потому что у них
## общий owner. Единственная поправка — §3.10: невскрытый житель неподвижен (_can_command).

enum Difficulty {EASY, NORMAL, HARD}

const SCORE_SHOOT_BASE := 100.0
const SCORE_CAPTURE_BASE := 70.0
const SCORE_CORPSE_BASE := 40.0
const SCORE_MOVE_BASE := 10.0
## Снос преграды шахтёром (#90): дороже обычного шага — ИИ-шахтёр ПРОБИВАЕТ дорогу
## к врагу, а не обходит её кругом.
const SCORE_BREAK_BASE := 34.0

## Цена одного шага при равном выигрыше (#103). Дробление движения (§3.2) выгодно
## только если ИИ ПЕРЕСТАЁТ выхаживать всю скорость ради одной и той же цели: из двух
## клеток с одинаковым приближением он выбирает ближнюю, а остаток скорости уходит в
## move_credit и тратится ПОСЛЕ выстрела — тем же ходом, но уже зная, куда легли пули.
const SCORE_STEP_COST := 0.35

## Складирование трупов (#103). Тело в руках — щит, тело на земле — стена: пять тел на
## клетке превращаются в укрытие. Обе операции дешевле выстрела, но дороже шага.
const SCORE_CORPSE_DROP_BASE := 30.0
## Подрыв преграды противотанкистом (#103): между сносом стены шахтёром и захватом —
## заряд ценнее кирки, потому что расчищает не клетку, а целый проём 3×3.
const SCORE_BLAST_PATH := 44.0
## Во сколько раз обход должен быть длиннее прямой, чтобы стену стало дешевле взорвать.
const BLAST_DETOUR_FACTOR := 2

## Труп-щит берут, если враг ближе этого (#40); нести больше двух смысла нет.
const CORPSE_GRAB_ENEMY_RANGE := 8
const CORPSE_CARRY_MAX := 2

## Обязательная явка (#103): за ход должно отходить не меньше этой доли живой армии.
## Раньше боец, которому жадная оценка не нашла ни одного кандидата (некуда сближаться,
## стрелять не по кому), молча выбывал из хода — и половина армии простаивала весь бой.
## Теперь после обычного прохода очередь ДОБИРАЕТСЯ бездельниками, и каждому ищется
## хоть какое-то осмысленное дело.
const MIN_ARMY_ACTIVITY := 0.8
## Сколько принудительных попыток даётся одному бездельнику, прежде чем его оставят в
## покое. Без потолка боец, которому и правда некуда деться, крутил бы ход вечно.
const FORCED_TRIES_PER_UNIT := 2

## Надбавка противотанкисту за шаг К ТЕХНИКЕ (#61). Держится между обычным
## сближением и захватом: подойти к танку для него важнее, чем брести к пехоте,
## но выстрел (SCORE_SHOOT_BASE) всё равно перевешивает любой ход.
const SCORE_ANTI_TANK_APPROACH := 25.0

var difficulty: int = Difficulty.NORMAL

## Кэш мультиисточниковых геополей расстояний: ключ "vis"/"all", значение —
## Dictionary{Vector2i -> шаги до ближайшего врага}. Позволяет ИИ обходить стены и
## углы (#62), не пересчитывая BFS на каждого врага и каждый юнит (#63). Живёт весь
## ход ИИ: враги на нашем ходу не двигаются, пересчёт нужен лишь когда кто-то погиб (#52).
var _geo_cache: Dictionary = {}
var _geo_stamp: int = -1
const GEO_FAR := 1 << 20

## Очередь хода (#52): ИИ доигрывает ОДНОГО бойца до конца и лишь затем берётся за
## следующего. Раньше каждое решение перебирало ВСЮ армию, то есть ход стоил O(N²)
## волновых BFS — отсюда фриз при большом числе юнитов. Теперь на решение приходится
## один актёр, и на экране видно, что бойцы ходят по очереди, а не скачут вразнобой.
var _queue: Array = []       # [{id: int, vehicle: bool}] в порядке хода
var _turn_token: int = -1    # ход, для которого построена очередь

## Явка на этот ход (#103): id тех, кто уже что-то сделал, и сколько принудительных
## попыток потрачено на каждого бездельника. Оба словаря живут ровно один ход ИИ.
var _acted: Dictionary = {}
var _forced_tries: Dictionary = {}
## Второй проход очереди уже был. Флаг обязателен: без него очередь добиралась бы
## бездельниками бесконечно и ход ИИ никогда бы не кончился.
var _forced_pass: bool = false

## Штабной план на весь ход (#100): куда каждый боец должен встать и в каком порядке
## армия ходит. Считается ОДИН раз в начале хода — дальше отдельные решения лишь
## исполняют его. См. AIPlanner.
var _planner: AIPlanner = AIPlanner.new()
## Насколько сильно план перевешивает обычную жадную оценку хода. Достаточно, чтобы
## боец шёл в назначенную клетку, но не настолько, чтобы идти вместо выстрела.
const SCORE_PLAN_BONUS := 26.0

func _init(p_owner: int, p_difficulty: int = Difficulty.NORMAL) -> void:
	super(p_owner)
	difficulty = p_difficulty

## Ход ИИ: одно действие за вызов. Main вызывает повторно после каждого resolve.
func begin_turn(state: GameState) -> void:
	if state.active_player() != owner:
		return
	intent_ready.emit(_decide(state))

## Резолвер отказал текущему актёру (#60). Повторять тот же расчёт бессмысленно —
## он снова выдаст то же намерение и ход зациклится, — поэтому актёр снимается с
## очереди и ИИ переходит к следующему бойцу.
func notify_intent_denied(_state: GameState) -> void:
	if not _queue.is_empty():
		_queue.pop_front()

# --- Принятие решения ---
## Одно действие за вызов. Ход состоит из двух проходов очереди:
##   1) обычный — каждый боец играется по жадной оценке до исчерпания кандидатов;
##   2) принудительный (#103) — очередь добирается теми, кто в первом проходе так и не
##      шевельнулся, и им ищется хоть какое-то дело (см. _forced_action).
## Второй проход запускается ровно один раз (`_forced_pass`) и только если явка не
## дотянула до MIN_ARMY_ACTIVITY, поэтому ход всегда конечен.
func _decide(state: GameState) -> Intent:
	_decide_gen += 1  # новое решение — штамп геополя надо сверить заново (#106)
	var r := GameActionResolver.new(state)
	r.omniscient_side = owner  # ИИ знает позиции всех сквозь туман (#43)
	_sync_turn(state, r)
	# Доигрываем текущего актёра; когда ходов у него не осталось — берём следующего.
	# Очередь только укорачивается, поэтому цикл конечен.
	while not _queue.is_empty():
		var row: Dictionary = _queue[0]
		var best := _best_for_actor(state, r, row)
		if best.is_empty() and _forced_pass and not row["vehicle"]:
			best = _forced_action(state, r, row)
		if not best.is_empty():
			_acted[_row_key(row)] = true
			return best["intent"]
		_queue.pop_front()
		if _queue.is_empty() and not _forced_pass:
			_forced_pass = true
			_queue = _idle_rows(state)
	return EndTurnIntent.new()

## Какая доля стороны обязана отходить за ход (#103). Армии хватает MIN_ARMY_ACTIVITY —
## часть бойцов честно нечем занять (сидят в резерве, прикрывают тыл). А вот мирным
## поблажки нет: «каждый житель обязан что-то сделать», значит квота ровно 1.0.
func _activity_quota() -> float:
	return 1.0 if owner == MCF.Owner.NEUTRAL else MIN_ARMY_ACTIVITY

## Ключ явки: техника и пехота нумеруются независимо, поэтому id мало.
func _row_key(row: Dictionary) -> String:
	return ("v%d" if row["vehicle"] else "u%d") % int(row["id"])

## Кто ещё может действовать, но за ход так и не сделал ничего (#103). Возвращаем
## пустой массив, если явка и так набрана — гонять армию ради галочки незачем.
func _idle_rows(state: GameState) -> Array:
	var live: Array = []
	for u: UnitInstance in state.living_units_of(owner):
		if u.is_drone or u.aboard_vehicle_id != -1:
			continue
		if not _can_command(u):
			continue
		live.append(u)
	if live.is_empty():
		return []
	var acted := 0
	for u: UnitInstance in live:
		if _acted.has("u%d" % u.id):
			acted += 1
	if float(acted) >= float(live.size()) * _activity_quota():
		return []
	var rows: Array = []
	for u: UnitInstance in live:
		if _acted.has("u%d" % u.id):
			continue
		if u.is_held():
			continue  # пленник ничего, кроме рывка, не может — им занялся первый проход
		if u.remaining_ap <= 0 and u.move_credit <= 0:
			continue
		rows.append({"id": u.id, "vehicle": false})
	# По id — иначе порядок зависел бы от порядка обхода словаря, и сетевые стороны
	# разъехались бы на разных сборках (§2.3).
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["id"] < b["id"])
	return rows

## Принудительное дело для бездельника (#103). Жадная оценка ему ничего не нашла:
## сближаться некуда (все пути не сокращают дистанцию), стрелять не по кому. Порядок
## отчаяния: перестать быть бесполезным (встать в укрытие / хотя бы сдвинуться) →
## снести соседнюю преграду → закопаться в окоп.
##
## Попытки на бойца ограничены: тот, кому и правда некуда деться (заперт в комнате без
## инструмента), отпускается, иначе ход ИИ крутился бы вокруг него вечно.
func _forced_action(state: GameState, r: GameActionResolver, row: Dictionary) -> Dictionary:
	var key := _row_key(row)
	var tries: int = int(_forced_tries.get(key, 0))
	if tries >= FORCED_TRIES_PER_UNIT:
		return {}
	_forced_tries[key] = tries + 1
	var u := state.get_unit(row["id"])
	if u == null or not u.is_alive() or u.is_held():
		return {}
	# 1. Хоть куда-нибудь: любая достижимая свободная клетка, оценённая укрытием и
	#    близостью к врагу по прямой. Условие «шаг обязан сокращать путь» здесь снято —
	#    именно оно и оставляло бойца стоять столбом.
	if u.remaining_ap > 0 or u.move_credit > 0:
		var enemy := _nearest_enemy(state, u.coord, false, r)
		var reach := Movement.reachable_for(state.grid, u, _move_budget(u))
		var dodge := _avoids_fire(u)
		var best: Dictionary = {}
		for coord: Vector2i in reach.cost:
			if coord == u.coord or state.grid.blocks_walk(coord):
				continue
			if dodge and _fire_near(state, coord):
				continue
			var score := SCORE_MOVE_BASE + _cover_bonus(state, coord)
			if enemy != null:
				score -= Combat.distance(coord, enemy.coord) * 0.5
			score -= float(reach.cost[coord]) * SCORE_STEP_COST
			if best.is_empty() or score > best["score"]:
				best = {"score": score, "intent": MoveIntent.new(u.id, coord)}
		if not best.is_empty():
			return best
	if u.remaining_ap <= 0:
		return {}
	# 2. Пробить стену, в которую упёрлись: у шахтёра/инженера кирка, у противотанкиста
	#    заряд. Обычные проверки (#90) требуют выигрыша по дистанции — здесь не требуем.
	for n: Vector2i in state.grid.neighbors(u.coord):
		if u.remaining_ap >= MCF.BREAK_COST and r.can_break_cell(u, n):
			return {"score": SCORE_BREAK_BASE, "intent": BreakIntent.new(u.id, n)}
	# 3. Ничего не остаётся — окапываемся. Окоп всегда полезен: он и укрытие, и защита
	#    от лазера марксманна (§3.7). Копаем ПОД СОБОЙ, если резолвер это разрешает.
	for c: Vector2i in r.diggable_cells(u):
		if c == u.coord:
			return {"score": SCORE_MOVE_BASE, "intent": DigIntent.new(u.id, c)}
	return {}

## Уникальный номер текущего хода: раунд + чей ход. Смена номера = новый ход ИИ.
func _turn_token_of(state: GameState) -> int:
	return state.turns.round_number * 16 + state.turns.active_index

## Построить очередь заново, если начался новый ход ИИ (#52).
func _sync_turn(state: GameState, r: GameActionResolver) -> void:
	var token := _turn_token_of(state)
	if token == _turn_token:
		return
	_turn_token = token
	_geo_cache.clear()
	_geo_stamp = -1
	_geo_probe = -1  # новый ход: штамп обязан пересчитаться, даже внутри того же решения
	# Явка считается ровно за один ход (#103): в новом ходу все снова «не ходили».
	_acted.clear()
	_forced_tries.clear()
	_forced_pass = false
	# Сперва штаб раскладывает ход целиком (#100), и только потом бойцы начинают
	# исполнять. Геополе считается тут же и переиспользуется планом.
	_planner.owner = owner
	_planner.plan(state, r, _enemy_distance_field(state, false, r), _vehicle_queue(state, r))
	# Копия, а не сам массив: очередь исполнения вычерпывается pop_front'ом, и по
	# ссылке она стирала бы САМ ПЛАН — а он нужен целиком до конца хода (отладка,
	# журнал, проверка «кто кого ждёт»).
	_queue = _planner.order.duplicate()

## Техника в очереди хода: своя/захваченная, ближняя к врагу — первой (§техника).
## Пехотную часть очереди строит планировщик, машины он не расставляет — у них
## своя геометрия движения (курс + шаги), которую клеткой назначения не описать.
func _vehicle_queue(state: GameState, r: GameActionResolver) -> Array:
	var rows: Array = []
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or veh.owner != owner:
			continue
		var ev := _nearest_enemy(state, veh.center(), false, r)
		rows.append({
			"id": veh.id, "vehicle": true,
			"key": Combat.distance(veh.center(), ev.coord) if ev != null else GEO_FAR,
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["key"] < b["key"])
	return rows

## Лучшее действие ОДНОГО актёра очереди; пусто — актёр отходил своё.
func _best_for_actor(state: GameState, r: GameActionResolver, row: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	if row["vehicle"]:
		var veh := state.get_vehicle(row["id"])
		if veh == null or not veh.alive() or veh.owner != owner or veh.ap <= 0:
			return {}
		for cand: Dictionary in _vehicle_candidates(state, r, veh):
			if best.is_empty() or cand["score"] > best["score"]:
				best = cand
		return best
	var u := state.get_unit(row["id"])
	if u == null or not u.is_alive() or u.owner != owner:
		return {}
	if not _can_command(u):
		return {}
	# Недоеденные клетки прошлого движения (§3.2) — полноценный ресурс, а не остаток:
	# их можно дошагать БЕЗ ОД, в том числе уже после выстрела (#103). Раньше боец с
	# нулём ОД снимался с очереди прямо здесь, и весь накопленный кредит пропадал —
	# то есть дробить движение ИИ технически умел, а пользоваться этим не мог.
	if u.remaining_ap <= 0 and u.move_credit <= 0 and not _pending_shoot(u):
		return {}
	# Пленник сохраняет ОД (#76), но единственное, что ему доступно, — рывок на свободу.
	if u.is_held():
		return {"score": 100.0, "intent": ReleaseIntent.new(u.id)}
	for cand: Dictionary in _candidates(state, r, u):
		if best.is_empty() or cand["score"] > best["score"]:
			best = cand
	return best

## Все действия-кандидаты одного юнита с оценками.
func _candidates(state: GameState, r: GameActionResolver, u: UnitInstance) -> Array:
	var out: Array = []
	if u.is_drone:
		var d := _drone_action(state, r, u)
		if not d.is_empty():
			out.append(d)
		return out

	var shoot := _best_shoot(state, r, u)
	if not shoot.is_empty():
		out.append(shoot)

	# Противотанкист — единственный, кто вообще может пробить броню (#61).
	var veh_shot := _best_vehicle_shot(state, r, u)
	if not veh_shot.is_empty():
		out.append(veh_shot)

	# Заряд в стену, если к врагу нет дороги (#103) — тоже выстрел, ОД тратит так же.
	var blast := _best_blast_path(state, r, u)
	if not blast.is_empty():
		out.append(blast)

	# Положить труп — действие БЕСПЛАТНОЕ (#103): доступно и выдохшемуся бойцу.
	var drop := _best_corpse_drop(state, r, u)
	if not drop.is_empty():
		out.append(drop)

	if u.remaining_ap > 0:
		var cap := _best_capture(state, r, u)
		if not cap.is_empty():
			out.append(cap)
		var corpse := _best_corpse_grab(state, r, u)
		if not corpse.is_empty():
			out.append(corpse)
		var brk := _best_break(state, r, u)
		if not brk.is_empty():
			out.append(brk)

	# Ходы доступны и на одном кредите движения, без ОД (#103, §3.2).
	if u.remaining_ap > 0 or u.move_credit > 0:
		var flee := _flee_fire(state, u)
		if not flee.is_empty():
			out.append(flee)
		var to_veh := _move_to_vehicle(state, u)
		if not to_veh.is_empty():
			out.append(to_veh)
		var mv := _best_move(state, r, u)
		if not mv.is_empty():
			out.append(mv)
	return out

## Запас клеток, который боец может пройти ПРЯМО СЕЙЧАС (§3.2, #103). Недоеденный
## кредит прошлого движения тратится ПЕРВЫМ и без ОД — точно так же считает резолвер
## (_resolve_move), поэтому оценка ИИ и правило игры не расходятся.
func _move_budget(u: UnitInstance) -> int:
	return u.move_credit if u.move_credit > 0 else u.stats.speed

## Шахтёр (и инженер) сносит преграду, стоящую на пути к врагу, вместо того чтобы
## обходить её (#90). Берём соседнюю ломаемую клетку, которая ближе к цели, чем мы
## сами; если враг вообще отрезан стенами (геополе до нас не дотянулось) — ломаем
## тем охотнее, иначе ИИ бесконечно шаркает вдоль стены.
func _best_break(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	var ability := u.stats.special_ability_id
	if ability != MCF.ABILITY_MINER and ability != MCF.ABILITY_ENGINEER:
		return {}
	if u.remaining_ap < MCF.BREAK_COST:
		return {}
	var enemy := _nearest_enemy(state, u.coord, false, r)
	if enemy == null:
		return {}
	var field := _enemy_distance_field(state, false, r)
	var walled_off := not field.has(u.coord)
	var here := Combat.distance(u.coord, enemy.coord)
	var best: Dictionary = {}
	for n: Vector2i in state.grid.neighbors(u.coord):
		if not r.can_break_cell(u, n):
			continue
		var gain := float(here - Combat.distance(n, enemy.coord))
		if gain <= 0.0:
			continue  # преграда не на пути к врагу — не тратим ОД
		var score := SCORE_BREAK_BASE + gain * 3.0
		if walled_off:
			score += 20.0
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": BreakIntent.new(u.id, n)}
	return best

## Подбор трупа (#40): труп либо загораживает дорогу к врагу (клетка с ним ближе по
## геополю, но занята), либо враг уже рядом — тогда труп нужен как щит (+1 к защите).
func _best_corpse_grab(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	if u.carried_corpses >= CORPSE_CARRY_MAX:
		return {}
	var enemy := _nearest_enemy(state, u.coord, false, r)
	var enemy_near := enemy != null \
			and Combat.distance(u.coord, enemy.coord) <= CORPSE_GRAB_ENEMY_RANGE
	var field := _enemy_distance_field(state, false, r)
	var start_geo: int = field.at(u.coord)
	var best: Dictionary = {}
	for n: Vector2i in state.grid.neighbors(u.coord):
		if not r.has_corpse(n):
			continue
		var blocking: int = field.at(n)
		var in_the_way := blocking < start_geo
		if not in_the_way and not enemy_near:
			continue
		var score := SCORE_CORPSE_BASE + (12.0 if in_the_way else 0.0)
		# Труп-«жилец» держит клетку целиком (occupant != null), поэтому убрать именно
		# его — расчистка прохода, а не мародёрство (#103). Куча corpse_count дороги не
		# перекрывает, пока не дорастёт до стены, и торопиться с ней незачем.
		if _corpse_blocks_cell(state, n):
			score += 10.0
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": PickUpCorpseIntent.new(u.id, n)}
	return best

## Труп, который ЗАНИМАЕТ клетку и потому непроходим (§3.6). Лежащая куча тел (до
## пяти) проходима, а вот павший на месте боец остаётся жильцом клетки.
func _corpse_blocks_cell(state: GameState, coord: Vector2i) -> bool:
	var c := state.grid.cell(coord)
	return c != null and c.occupant != null and c.occupant.status == MCF.Status.CORPSE

## Разгрузка тел (#103): «муравьиная» половина работы с трупами.
##
## Подбор трупа уже был (#40), а вот КЛАСТЬ ИИ не умел вовсе — тела копились в руках
## до конца боя. Между тем труп на земле полезнее, чем в охапке:
##   * пять тел на клетке становятся трупной стеной (MCF.CORPSE_WALL_COUNT) — готовым
##     укрытием, которое можно возвести там, где стены нет;
##   * тело, вынутое из прохода и сложенное В СТОРОНЕ, освобождает дорогу всей роте, а
##     не только носильщику.
## Поэтому кладём, когда рядом нет врага (щит уже не нужен) и есть куда: сперва в
## соседнюю кучу — так растёт стена, — иначе просто вбок с дороги.
func _best_corpse_drop(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	if u.carried_corpses <= 0:
		return {}
	var enemy := _nearest_enemy(state, u.coord, false, r)
	# Пока враг близко, тело работает щитом (+1 к защите) — не выбрасываем.
	if enemy != null and Combat.distance(u.coord, enemy.coord) <= CORPSE_GRAB_ENEMY_RANGE:
		return {}
	var field := _enemy_distance_field(state, false, r)
	var start_geo: int = int(field.at(u.coord))
	var best: Dictionary = {}
	for n: Vector2i in state.grid.neighbors(u.coord):
		var cell := state.grid.cell(n)
		if cell == null or cell.is_wall() or cell.is_space:
			continue
		var here: int = r.corpses_at(n)
		if here >= MCF.CORPSE_WALL_COUNT:
			continue  # куча полна, шестое тело не влезет
		# Не заваливаем СВОЮ дорогу: клетка, которая ближе к врагу, нужна для прохода.
		if int(field.at(n)) < start_geo:
			continue
		# Растить начатую кучу выгоднее, чем начинать новую: она ближе к стене.
		var score := SCORE_CORPSE_DROP_BASE + float(here) * 6.0
		if here == MCF.CORPSE_WALL_COUNT - 1:
			score += 14.0  # этим телом куча становится укрытием
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": DropCorpseIntent.new(u.id, n)}
	return best

## Можно ли вообще отдавать приказы этому юниту (#103). Единственное исключение —
## мирный житель, которого ещё не «вскрыли» (§3.10): до первого выстрела на карте или
## до встречи с солдатом глазами он стоит на месте и ни во что не вмешивается.
func _can_command(u: UnitInstance) -> bool:
	return not CivilianAI.is_npc(u) or u.civilian_active

func _pending_shoot(u: UnitInstance) -> bool:
	return u.action_state != null and u.action_state.is_pending()

func _shoot_ap_cost(u: UnitInstance) -> int:
	return MCF.MARKSMAN_AP_COST if u.stats.special_ability_id == MCF.ABILITY_MARKSMAN else 1

# --- Оценка целей ---
## Тактическая «стоимость» вражеского юнита: спецстрелки опаснее, мирных-НПС не бьём.
func _unit_value(u: UnitInstance) -> float:
	# Скидка полагается только НЕЙТРАЛЬНОМУ жителю (#96): купленный игроком житель —
	# такой же боец вражеской армии, и обходить его стороной ИИ незачем.
	if CivilianAI.is_npc(u):
		return -1.0
	var v := 3.0 + float(u.stats.rate_of_fire)
	# «Гражданский» — не боевая специальность, надбавки за неё нет.
	if u.stats.special_ability_id != "" \
			and u.stats.special_ability_id != MCF.ABILITY_CIVILIAN:
		v += 3.0
	match u.stats.special_ability_id:
		MCF.ABILITY_SNIPER, MCF.ABILITY_MARKSMAN, MCF.ABILITY_ANTI_TANK:
			v += 3.0
	return v

## Сколько врагов ещё живо — по этому числу инвалидируется геополе (#52), поэтому
## считаем без выделения массива: вызывается на каждое решение ИИ.
func _living_enemy_count(state: GameState) -> int:
	var n := 0
	for u: UnitInstance in state.all_units():
		if u.owner != owner and u.is_alive():
			n += 1
	return n

func _enemies_of(state: GameState) -> Array:
	var out: Array = []
	for u: UnitInstance in state.all_units():
		if u.owner != owner and u.is_alive():
			out.append(u)
	return out

## Перебор идёт по state.all_units() напрямую, без промежуточного списка врагов (#106):
## _enemies_of() строила массив на две сотни элементов, а зовут отсюда по несколько раз
## на каждое решение ИИ. Порядок обхода и все три отсева — те же, что были, поэтому и
## ничья («первый из равноудалённых») разрешается прежним бойцом.
##
## Ответ ещё и запоминается на одно решение. За вызов _candidates() отсюда спрашивают
## ближайшего врага четырежды (ход, труп, пролом, заряд) — и каждый раз из ОДНОЙ И ТОЙ
## ЖЕ клетки одного и того же бойца. Состояние за время решения не меняется, значит и
## ответ обязан совпасть; ключ включает клетку и флаг видимости, так что перепутать
## разные вопросы нельзя.
## Отсев «чужой, живой, не мирный-НПС» тоже делается ОДИН раз на решение, а не на запрос.
## Он не зависит от клетки, из которой спрашивают, зато стоит трёх вызовов функций
## (is_alive, is_npc и обращение к stats внутри неё) на каждого из трёх с половиной сотен
## юнитов — а промахов кеша за решение всё равно несколько. Отобранные бойцы кладутся
## в два параллельных списка: сами объекты и их координаты ПЛОСКИМИ int. Тогда сам поиск
## ближайшего — это цикл по упакованным числам с расстоянием Чебышёва прямо на месте,
## без единого вызова.
##
## Порядок в списках — тот же порядок state.all_units(), а сравнение осталось строгим
## `<`, поэтому из равноудалённых по-прежнему побеждает первый по этому обходу.
var _near_cache: Dictionary = {}
var _near_gen: int = -1
var _near_units: Array[UnitInstance] = []
var _near_xy: PackedInt32Array = PackedInt32Array()

func _nearest_enemy(state: GameState, from_coord: Vector2i, only_visible: bool, r: GameActionResolver) -> UnitInstance:
	var us: int = owner
	if _near_gen != _decide_gen:
		_near_gen = _decide_gen
		_near_cache.clear()
		_near_units.clear()
		_near_xy.clear()
		for e: UnitInstance in state.all_units():
			if e.owner == us or not e.is_alive():
				continue
			if CivilianAI.is_npc(e):
				continue  # к мирным-НПС не рвёмся; купленный житель — обычный боец (#96)
			_near_units.append(e)
			_near_xy.append(e.coord.x)
			_near_xy.append(e.coord.y)
	var ck := Vector3i(from_coord.x, from_coord.y, 1 if only_visible else 0)
	var hit: Variant = _near_cache.get(ck)
	if hit != null or _near_cache.has(ck):
		return hit
	var best: UnitInstance = null
	var best_d := 1 << 30
	var fx := from_coord.x
	var fy := from_coord.y
	var n := _near_units.size()
	var i := 0
	var j := 0
	while i < n:
		var dx: int = absi(fx - _near_xy[j])
		var dy: int = absi(fy - _near_xy[j + 1])
		j += 2
		var d: int = dx if dx > dy else dy
		if d < best_d:
			# Видимость проверяется только у того, кто иначе стал бы лучшим: вызов
			# дорогой, а претендентов на улучшение за проход единицы.
			var e: UnitInstance = _near_units[i]
			if not only_visible or r.is_visible_to_team(us, e):
				best_d = d
				best = e
		i += 1
	_near_cache[ck] = best
	return best

# --- Стрельба ---
func _best_shoot(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	# Дострел незавершённой очереди (§3.2). Цель привязана, но НЕ намертво: если она уже
	# упала (или скрылась), остаток очереди переносится на другого противника тем же ОД
	# (#5) — поэтому при неудаче мы не выходим, а падаем в общий подбор цели ниже (#103).
	if _pending_shoot(u):
		var t := state.get_unit(u.action_state.target_id)
		if t != null and t.is_alive() and r.can_shoot(u, t) == "" and not r.shot_is_futile(u, t):
			return {"score": SCORE_SHOOT_BASE + _unit_value(t),
				"intent": ShootIntent.new(u.id, t.id, _shots_for(r, u, t))}
	elif u.remaining_ap < _shoot_ap_cost(u):
		return {}
	var best: Dictionary = {}
	# hostile_target_ids, а не shootable_target_ids: с появлением дружественного огня
	# (#100) в список «по кому можно стрелять» попали и свои. Расстреливать
	# собственный взвод ИИ не станет.
	for tid: int in r.hostile_target_ids(u):
		var t := state.get_unit(tid)
		if t == null:
			continue
		# Пуля достанется первому живому на линии (#100). Если это свой — выстрел
		# не предлагаем вовсе; если чужой — целимся сразу в него, честной оценкой.
		# Лазер марксманна летит сквозь тела, его перенаправление не касается.
		if u.stats.special_ability_id != MCF.ABILITY_MARKSMAN:
			var blocker := r.first_unit_on_line(u.coord, t.coord)
			if blocker != null:
				if blocker.owner == u.owner or CivilianAI.is_npc(blocker):
					continue
				t = blocker
		# Щитоносца берёт только выстрел в упор (§3.14). can_shoot такой выстрел
		# РАЗРЕШАЕТ — просто все попадания парируются, — поэтому ИИ выбирал щит как
		# обычную цель (за спецспособность ему ещё и +3 к ценности) и разряжал в него
		# очередь с другого конца карты (#69). Дистанцию не считаем сами: правило и
		# исключение для снайпера живут в резолвере.
		if r.shot_is_futile(u, t):
			continue
		var dist := Combat.distance(u.coord, t.coord)
		var hit_need := Combat.hit_number(dist, u.stats.fire_range)
		var ease := float(7 - hit_need)  # чем меньше нужное число, тем выше
		var score := SCORE_SHOOT_BASE + _unit_value(t) + ease * 2.0
		if _pref_hard():
			score += ease  # на «сложном» сильнее любит гарантированные попадания
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": ShootIntent.new(u.id, t.id, _shots_for(r, u, t))}
	return best

## Сколько патронов очереди отдать этой цели (#103). Раньше ИИ всегда слал -1 —
## «весь остаток», — и пулемётчик выпускал шесть патронов в одного пехотинца, хотя
## первого-второго хватало, а остаток очереди можно было тем же ОД перевести на
## соседнюю цель (§3.2, #5).
##
## Считаем ОЖИДАЕМОЕ число выстрелов до одного смертельного попадания:
##   p = P(попал) · P(защита не спасла) = (7−need)/6 · (parry−1)/6,
## и заказываем ceil(1/p) патронов. По лёгкой цели уходит один-два, по бронированной —
## вся очередь (что и правильно). −1 («всё») возвращается там, где дробить нечего:
## очередь длиной 1 или заведомо безнадёжный расклад.
func _shots_for(r: GameActionResolver, u: UnitInstance, t: UnitInstance) -> int:
	var available: int = u.stats.rate_of_fire
	if _pending_shoot(u):
		available = u.action_state.remaining_shots
	if available <= 1:
		return -1
	var cover := r.cover_effect(u, t)
	var need := Combat.hit_number(Combat.distance(u.coord, t.coord), u.stats.fire_range) \
			+ int(cover["hit_penalty"])
	var parry: int = t.stats.armor_threshold + u.stats.target_defense_penalty \
			- int(cover["defense_bonus"]) - t.carried_corpses
	var p_hit := clampf(float(7 - need) / 6.0, 0.0, 1.0)
	var p_pen := clampf(float(parry - 1) / 6.0, 0.0, 1.0)
	var p := p_hit * p_pen
	if p <= 0.001:
		return -1  # шанс исчезающе мал — смысла экономить очередь нет
	return clampi(int(ceil(1.0 / p)), 1, available)

# --- Техника как цель (#61) ---
## Живая вражеская техника на поле. Обломки не трогаем — они уже не воюют.
func _enemy_vehicles(state: GameState) -> Array:
	var out: Array = []
	for veh: Vehicle in state.all_vehicles():
		if veh.alive() and veh.owner != owner:
			out.append(veh)
	return out

func _enemy_vehicle_count(state: GameState) -> int:
	return _enemy_vehicles(state).size()

## Насколько машина ценна как цель: за основу берём прочность и экипаж внутри —
## набитый людьми танк опаснее пустого челнока.
func _vehicle_value(veh: Vehicle) -> float:
	return 6.0 + float(veh.durability) * 2.0 + float(veh.living_crew_count()) * 2.0

## Выстрел противотанкиста по технике (#61). Целями ИИ раньше были ТОЛЬКО юниты
## (shootable_target_ids перебирает пехоту), поэтому танк для него просто не
## существовал: противотанкист стоял рядом с машиной и «бродил», хотя он —
## единственный в армии, чей выстрел снимает с брони прочность.
## Бьём по клетке следа: удар по земле (§3.14) накрывает её взрывом.
func _best_vehicle_shot(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	if u.stats.special_ability_id != MCF.ABILITY_ANTI_TANK:
		return {}
	if u.remaining_ap < _shoot_ap_cost(u):
		return {}
	var best: Dictionary = {}
	for veh: Vehicle in _enemy_vehicles(state):
		for fc: Vector2i in veh.footprint():
			# Условия проверяет сам резолвер — линия огня, стены, дальность.
			if r.can_blast_cell(u, fc) != "":
				continue
			var ease := float(7 - Combat.hit_number(
				Combat.distance(u.coord, fc), u.stats.fire_range))
			var score := SCORE_SHOOT_BASE + _vehicle_value(veh) + ease * 2.0
			if best.is_empty() or score > best["score"]:
				best = {"score": score, "intent": ShootIntent.new(u.id, -1, -1, fc)}
	return best

## Противотанкист прорубает себе дорогу (#103).
##
## Заряд сносит укрепления в квадрате 3×3 (_blast → _blast_destroy_terrain), то есть
## это не только оружие, но и САПЁРНЫЙ инструмент — единственный в армии, который
## пробивает капитальную стену без шахтёра. Пока ИИ этого не знал, противотанкист,
## упёршийся в глухую стену, всю партию шаркал вдоль неё: геополе до врага не
## дотягивалось, сближение не давало выигрыша, стрелять было не по кому.
##
## Стреляем по преграде, когда обход бессмыслен:
##   * прохода к врагу нет вовсе (геополе не накрыло нашу клетку), либо
##   * обход длиннее прямой дистанции в BLAST_DETOUR_FACTOR раз и больше.
## Цель ищем на луче к врагу, начиная с клетки, до которой взрыв не достаёт нас самих
## (радиус +1) — иначе сапёр подорвался бы на собственном заряде.
func _best_blast_path(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	if u.stats.special_ability_id != MCF.ABILITY_ANTI_TANK:
		return {}
	if u.remaining_ap < _shoot_ap_cost(u):
		return {}
	var enemy := _nearest_enemy(state, u.coord, false, r)
	if enemy == null:
		return {}
	var direct := Combat.distance(u.coord, enemy.coord)
	if direct <= MCF.ANTI_TANK_BLAST_RADIUS + 1:
		return {}  # враг и так вплотную — тут не сапёрная задача, а обычный выстрел
	var field := _enemy_distance_field(state, false, r)
	var detour: int = int(field.at(u.coord))
	var walled_off := not field.has(u.coord)
	if not walled_off and detour < direct * BLAST_DETOUR_FACTOR:
		return {}  # дорога есть и она разумной длины — ногами дешевле
	# Заряд летит только по линии огня (8 направлений, §3.5), поэтому перебираем именно
	# их, а не «луч к врагу»: враг почти никогда не стоит ровно на одной из восьми осей.
	# По каждой оси берём ПЕРВУЮ преграду — снесём её, и стена вскроется.
	var reach := int(u.stats.fire_range)
	var best: Dictionary = {}
	for dir: Vector2i in Grid.N8:
		var hit := Vector2i(-1, -1)
		for step in range(1, reach + 1):
			var c := u.coord + dir * step
			var cell := state.grid.cell(c)
			if cell == null:
				break
			if cell.occupant != null and cell.occupant.is_alive():
				break  # живое тело на оси — это работа обычной стрельбы, не сапёра
			if cell.walkable_terrain():
				continue
			# Ближе радиуса взрыва бить нельзя — подорвёмся сами.
			if step <= MCF.ANTI_TANK_BLAST_RADIUS:
				break
			hit = c
			break
		if hit.x < 0:
			continue
		if r.can_blast_cell(u, hit) != "":
			continue
		# Пробоина полезна, только если она ВЕДЁТ к врагу: клетка за стеной должна быть
		# ближе к нему, чем мы сами, иначе ИИ будет крошить стены за спиной.
		var behind := hit + dir
		if Combat.distance(behind, enemy.coord) >= direct:
			continue
		var step_d := Combat.distance(u.coord, hit)
		var score := SCORE_BLAST_PATH + (20.0 if walled_off else 0.0) - float(step_d)
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": ShootIntent.new(u.id, -1, -1, hit)}
	return best

## Сближение противотанкиста с техникой (#61). Пока стрелять не по чему, он должен
## идти К МАШИНЕ, а не тянуться к ближайшему пехотинцу по общему геополю: подойдя к
## пехоте, он так и не окажется на линии огня с танком.
func _move_to_vehicle(state: GameState, u: UnitInstance) -> Dictionary:
	if u.stats.special_ability_id != MCF.ABILITY_ANTI_TANK:
		return {}
	if u.remaining_ap <= 0 and u.move_credit <= 0:
		return {}
	var field := _vehicle_distance_field(state)
	if not field.has(u.coord):
		return {}
	var start: int = field.at(u.coord)
	var reach := Movement.reachable_for(state.grid, u, _move_budget(u))
	var dodge := _avoids_fire(u)
	var best: Dictionary = {}
	for coord: Vector2i in reach.cost:
		if dodge and _fire_near(state, coord):
			continue  # от огня держимся на клетку (#48)
		var gain := float(start - int(field.at(coord)))
		if gain <= 0.0:
			continue
		var score := SCORE_MOVE_BASE + SCORE_ANTI_TANK_APPROACH + gain * 3.0
		score -= float(reach.cost[coord]) * SCORE_STEP_COST
		if _seeks_cover():
			score += _cover_bonus(state, coord)
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": MoveIntent.new(u.id, coord)}
	return best

## Геополе до вражеской техники — тот же волновой BFS, что и для пехоты, но
## засеянный клетками следов машин. Кэш общий, ключ "veh".
func _vehicle_distance_field(state: GameState) -> GeoField:
	_refresh_geo_stamp(state)
	if _geo_cache.has("veh"):
		return _geo_cache["veh"]
	var off: Dictionary = {}
	var grid := state.grid
	var w := grid.width
	var h := grid.height
	var cells: Array[GridCell] = grid.cells_flat()
	var wall_h: float = MCF.WALL_HEIGHT
	# Устройство волны — как у пехотного поля выше (#106): плоские массивы вместо
	# словаря, байт состояния на клетку, соседи по Grid.N8 без промежуточного массива.
	var seen := PackedByteArray()
	seen.resize(w * h)
	var dist := PackedInt32Array()
	dist.resize(w * h)
	dist.fill(GeoField.FAR)
	var qx := PackedInt32Array()
	var qy := PackedInt32Array()
	var qd := PackedInt32Array()
	for veh: Vehicle in _enemy_vehicles(state):
		for fc: Vector2i in veh.footprint():
			var fx: int = fc.x
			var fy: int = fc.y
			if fx < 0 or fy < 0 or fx >= w or fy >= h:
				off[fc] = 0   # след машины свесился за карту — ключ прежний, волны нет
				continue
			var fi := fy * w + fx
			if seen[fi] != 0:
				continue
			seen[fi] = 1
			dist[fi] = 0
			qx.append(fx)
			qy.append(fy)
			qd.append(0)
	var head := 0
	while head < qx.size():
		var cx: int = qx[head]
		var cy: int = qy[head]
		var nd: int = qd[head] + 1
		head += 1
		for d: Vector2i in Grid.N8:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var idx := ny * w + nx
			if seen[idx] != 0:
				continue
			# --- инлайн walkable_terrain(): закрытый шлюз маршруту не помеха (#100).
			var c: GridCell = cells[idx]
			var fid: String = c.feature_id
			var passable: bool
			if fid == "" and c.dirt_level == 0:
				passable = c.cover_height < wall_h
			elif fid == MCF.FEATURE_AIRLOCK and not c.airlock_welded:
				passable = true
			else:
				passable = c.cover_height < wall_h and not c.blocks_move()
			if not passable:
				seen[idx] = 2
				continue
			seen[idx] = 1
			dist[idx] = nd
			qx.append(nx)
			qy.append(ny)
			qd.append(nd)
	var field := GeoField.new(w, h, dist, off)
	_geo_cache["veh"] = field
	return field

# --- Захват ---
func _best_capture(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	var ids := r.capturable_target_ids(u)
	if ids.is_empty():
		return {}
	var best: Dictionary = {}
	for tid: int in ids:
		var t := state.get_unit(tid)
		if t == null or t.owner == u.owner or CivilianAI.is_npc(t):
			continue
		var score := SCORE_CAPTURE_BASE + _unit_value(t)
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": CaptureIntent.new(u.id, t.id)}
	return best

# --- Сближение ---
## Ход по штабному плану (#100): боец идёт в НАЗНАЧЕННУЮ клетку, а не к ближайшему
## врагу. Если дойти за одну активацию нельзя (клетка дальше скорости или её кто-то
## занял), идём в достижимую клетку, которая ближе всего к назначенной — план
## выполняется за два хода, но направление держится армией единое.
func _plan_move(state: GameState, u: UnitInstance) -> Dictionary:
	var dest := _planner.destination_of(u.id)
	if dest == Vector2i(-1, -1) or dest == u.coord:
		return {}
	if u.remaining_ap <= 0 and u.move_credit <= 0:
		return {}
	var budget: int = _move_budget(u)
	var reach := Movement.reachable_for(state.grid, u, budget)
	var dodge := _avoids_fire(u)
	# Клетка назначения из плана штаба может за это время загореться (#1): в разливе
	# она осталась, но входить в неё — гарантированная смерть. Тогда план не
	# исполняется целиком, а доигрывается шагом «в сторону цели» ниже.
	if reach.can_reach(dest) and not state.grid.blocks_walk(dest) \
			and not (dodge and _fire_near(state, dest)):
		return {"score": SCORE_MOVE_BASE + SCORE_PLAN_BONUS,
			"intent": MoveIntent.new(u.id, dest)}
	# Не дотягиваемся — шагаем в сторону назначения, но только если это правда ближе.
	var here := Combat.distance(u.coord, dest)
	var best: Dictionary = {}
	for coord: Vector2i in reach.cost:
		if dodge and _fire_near(state, coord):
			continue
		var gain := float(here - Combat.distance(coord, dest))
		if gain <= 0.0:
			continue
		var score := SCORE_MOVE_BASE + SCORE_PLAN_BONUS * 0.5 + gain * 2.0
		score -= float(reach.cost[coord]) * SCORE_STEP_COST
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": MoveIntent.new(u.id, coord)}
	return best

func _best_move(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	# План старше жадности: если штаб назначил бойцу клетку, идём туда.
	var planned := _plan_move(state, u)
	if not planned.is_empty():
		return planned
	# Сближение оцениваем по РЕАЛЬНОМУ пути в обход стен (геодезическое поле), а не по
	# прямой — иначе ИИ прижимается к стене и застревает у угла (#62). Поле строится
	# ОДНИМ волновым BFS сразу от всех врагов, поэтому не тормозит на ходу ИИ (#63).
	var field := _enemy_distance_field(state, true, r)
	var use_geo := field.has(u.coord)
	if not use_geo:
		field = _enemy_distance_field(state, false, r)
		use_geo = field.has(u.coord)
	# Ближайший по прямой — для сглаживающего уклона и запасного пути, если все
	# враги отрезаны стенами и геополе до нашей клетки не дотягивается.
	var straight := _nearest_enemy(state, u.coord, false, r)
	if not use_geo and straight == null:
		return {}
	var reach := Movement.reachable_for(state.grid, u, _move_budget(u))
	var start_geo: int = field.at(u.coord)
	# Лучшее держим в простых переменных, а не в Dictionary (#106): разлив — под сотню
	# клеток на бойца, и прежний код на каждое улучшение строил и словарь, и MoveIntent,
	# а на каждую клетку ещё и лез в best["score"]. Ничья разрешается по-прежнему первым
	# из равных: сравнение осталось строгим, порядок обхода — тот же.
	var cost: Dictionary = reach.cost
	var grid := state.grid
	var easy := difficulty == Difficulty.EASY
	var covers := _seeks_cover()
	var straight_coord: Vector2i = straight.coord if straight != null else Vector2i.ZERO
	var start_straight: int = Combat.distance(u.coord, straight_coord) if straight != null else 0
	var have_best := false
	var best_score := 0.0
	var best_coord := Vector2i.ZERO
	var dodge := _avoids_fire(u)
	for coord: Vector2i in cost:
		if dodge and _fire_near(state, coord):
			continue  # держим дистанцию минимум в 1 клетку от огня (#48)
		var score: float
		if use_geo:
			var new_geo: int = field.at(coord)
			var gain := float(start_geo - new_geo)
			if gain <= 0.0 and not easy:
				continue  # не подходим ближе по пути — незачем (кроме бестолкового EASY)
			score = SCORE_MOVE_BASE + gain * 3.0
			# Небольшой уклон к клеткам ближе по прямой — сглаживает равные пути.
			if straight != null:
				score -= Combat.distance(coord, straight_coord) * 0.05
		else:
			# Геополе не дотянулось (враг за стеной) — сближаемся по прямой.
			var gain := float(start_straight - Combat.distance(coord, straight_coord))
			if gain <= 0.0 and not easy:
				continue
			score = SCORE_MOVE_BASE + gain * 3.0
		# Каждая пройденная клетка чего-то стоит (#103): при равном приближении ИИ
		# останавливается раньше, а неизрасходованная скорость остаётся кредитом (§3.2)
		# и доходится уже после выстрела — это и есть дробление движения.
		score -= float(cost[coord]) * SCORE_STEP_COST
		if covers:
			var c := grid.cell(coord)
			if c.has_cover():
				score += float(MCF.COVER_MOD.get(c.cover_height, 1)) * 2.0
		if easy:
			score += randf() * 4.0  # шумит, ходит менее осмысленно
		if not have_best or score > best_score:
			have_best = true
			best_score = score
			best_coord = coord
	if not have_best:
		return {}
	return {"score": best_score, "intent": MoveIntent.new(u.id, best_coord)}

## Сбрасывает кэш геополей, если обстановка изменилась. Метка складывается из хода
## и числа живых целей: пока никто не погиб, поля переиспользуются весь ход ИИ.
## Технику (#61) в метку тоже включаем — иначе поле "veh" продолжало бы вести
## бойцов к уже уничтоженной машине до конца хода.
## Штамп сверяется РАЗ НА РЕШЕНИЕ, а не на каждый запрос поля (#106). Пересчёт штампа —
## это два прохода по всем юнитам и всей технике, а за одно решение сюда заходят по
## четыре-пять раз (ход, подбор трупа, пролом стены). Состояние за время решения не
## меняется — _decide() только читает, — поэтому второй и последующие ответы в пределах
## одного решения обязаны совпасть с первым, и сверять их незачем.
var _geo_probe: int = -1
var _decide_gen: int = 0

func _refresh_geo_stamp(state: GameState) -> void:
	if _geo_probe == _decide_gen:
		return
	_geo_probe = _decide_gen
	var stamp := (_turn_token * 1024 + _living_enemy_count(state)) * 64 \
		+ _enemy_vehicle_count(state)
	if stamp != _geo_stamp:
		_geo_cache.clear()
		_geo_stamp = stamp

## Мультиисточниковое геодезическое поле: ОДИН волновой BFS, засеянный сразу из
## клеток ВСЕХ (видимых или всех) немирных врагов. Значение — число шагов до
## ближайшего врага по проходимым клеткам (стены/препятствия непроходимы, живые
## юниты игнорируются). Раньше поле считалось отдельным BFS на каждого врага и на
## каждое решение — отсюда жуткие лаги на ходу ИИ (#63). Кэш живёт весь ход ИИ:
## враги на нашем ходу не ходят, поэтому пересчёт нужен, только когда кто-то из них
## погиб (#52). Ключ: "vis" (только видимые) / "all" (все).
func _enemy_distance_field(state: GameState, only_visible: bool, r: GameActionResolver) -> GeoField:
	_refresh_geo_stamp(state)
	var key := "vis" if only_visible else "all"
	if _geo_cache.has(key):
		return _geo_cache[key]
	var off: Dictionary = {}
	var grid := state.grid
	var w := grid.width
	var h := grid.height
	var cells: Array[GridCell] = grid.cells_flat()
	var wall_h: float = MCF.WALL_HEIGHT
	# Волна идёт по ПЛОСКИМ индексам, а не по словарю (#106). Само поле — обход всей
	# карты, две с половиной тысячи клеток по восемь соседей, и раньше на каждом шаге
	# платились три вещи разом: grid.neighbors() строил новый массив из восьми Vector2i,
	# «уже были тут?» спрашивалось у словаря по ключу-вектору, а проходимость соседа
	# пересчитывалась заново из КАЖДОЙ соседней клетки — то есть у стены до восьми раз.
	#
	# Здесь состояние клетки лежит в плоском байтовом массиве: 0 — не трогали, 1 — взята
	# в волну, 2 — непроходима. Стена получает свою двойку при первой же встрече и дальше
	# отсеивается сравнением байта. Очередь — три PackedInt32Array (x, y и накопленный
	# шаг) вместо массива векторов со чтением цены из словаря.
	#
	# Готовые шаги пишутся сразу в плоский массив GeoField, без словаря на две с половиной
	# тысячи ключей-векторов. Порядок обхода соседей — тот же Grid.N8, что и у
	# grid.neighbors(), а волна FIFO, поэтому и числа в поле остались прежние.
	var seen := PackedByteArray()
	seen.resize(w * h)
	var dist := PackedInt32Array()
	dist.resize(w * h)
	dist.fill(GeoField.FAR)
	var qx := PackedInt32Array()
	var qy := PackedInt32Array()
	var qd := PackedInt32Array()
	for e: UnitInstance in state.all_units():
		if e.owner == owner or not e.is_alive():
			continue
		if CivilianAI.is_npc(e):
			continue  # к мирным-НПС не рвёмся; купленный житель — обычный боец (#96)
		if only_visible and not r.is_visible_to_team(owner, e):
			continue
		var ex: int = e.coord.x
		var ey: int = e.coord.y
		if ex < 0 or ey < 0 or ex >= w or ey >= h:
			# Сидящий в машине вынесен за карту (§техника). Прежний код всё равно клал
			# такой ключ в поле нулём, а соседей у него не было ни одного — повторяем.
			off[e.coord] = 0
			continue
		var ei := ey * w + ex
		if seen[ei] != 0:
			continue
		seen[ei] = 1
		dist[ei] = 0
		qx.append(ex)
		qy.append(ey)
		qd.append(0)
	var head := 0
	while head < qx.size():
		var cx: int = qx[head]
		var cy: int = qy[head]
		var nd: int = qd[head] + 1
		head += 1
		for d: Vector2i in Grid.N8:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var idx := ny * w + nx
			if seen[idx] != 0:
				continue
			# --- инлайн walkable_terrain(): закрытый шлюз маршруту не помеха (#100),
			# он разъедется перед бойцом; стена и препятствие непроходимы.
			var c: GridCell = cells[idx]
			var fid: String = c.feature_id
			var passable: bool
			if fid == "" and c.dirt_level == 0:
				passable = c.cover_height < wall_h   # чистый пол — большинство клеток
			elif fid == MCF.FEATURE_AIRLOCK and not c.airlock_welded:
				passable = true
			else:
				passable = c.cover_height < wall_h and not c.blocks_move()
			if not passable:
				seen[idx] = 2   # стену больше не пересчитываем — она отсеется байтом
				continue
			seen[idx] = 1
			dist[idx] = nd
			qx.append(nx)
			qy.append(ny)
			qd.append(nd)
	var field := GeoField.new(w, h, dist, off)
	_geo_cache[key] = field
	return field

## Стоя вплотную к пламени, ИИ первым делом отходит на безопасную клетку (#48):
## сближение с врагом такой ход обычно не даёт, поэтому он идёт отдельным кандидатом.
func _flee_fire(state: GameState, u: UnitInstance) -> Dictionary:
	# Огнеупорному (#2) бежать не от чего — он в пламени и стоит, и воюет.
	if not _avoids_fire(u) or not _fire_near(state, u.coord):
		return {}
	var reach := Movement.reachable_for(state.grid, u, _move_budget(u))
	var best: Dictionary = {}
	for coord: Vector2i in reach.cost:
		if coord == u.coord or _fire_near(state, coord):
			continue
		var score: float = SCORE_CAPTURE_BASE + 20.0 - float(reach.cost[coord])
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": MoveIntent.new(u.id, coord)}
	return best

## Горит ли сама клетка или любая соседняя (#48): ИИ не встаёт вплотную к пламени —
## огонь расползается на ортогональных соседей и сжигает стоящего там насмерть.
##
## Зовётся на КАЖДУЮ клетку разлива при выборе хода, то есть под сотню раз на бойца, а
## grid.neighbors() строит на каждый вызов новый массив из восьми Vector2i (#106). Обход
## развёрнут по окну 3×3 напрямую: набор проверяемых клеток тот же (восемь соседей в
## границах поля), а «горит ли хоть одна» от порядка обхода не зависит.
## Держится ли этот боец подальше от пламени (#48). Огнеупорные (#2) — нет: для них
## огонь обычная местность, и ИИ, водящий огнемётчика в обход собственного пожара,
## просто не даёт им работать.
func _avoids_fire(u: UnitInstance) -> bool:
	return not MCF.ability_is_fireproof(u.stats.special_ability_id)

func _fire_near(state: GameState, coord: Vector2i) -> bool:
	if GridCell.burning == 0:
		return false  # на карте не горит ничего — соседей можно не смотреть
	var grid := state.grid
	if grid.cell(coord).on_fire:
		return true
	var x := coord.x
	var y := coord.y
	var ny := maxi(0, y - 1)
	var y1 := mini(grid.height - 1, y + 1)
	var x0 := maxi(0, x - 1)
	var x1 := mini(grid.width - 1, x + 1)
	while ny <= y1:
		var nx := x0
		while nx <= x1:
			if (nx != x or ny != y) and grid.cell_fast(nx, ny).on_fire:
				return true
			nx += 1
		ny += 1
	return false

func _cover_bonus(state: GameState, coord: Vector2i) -> float:
	var c := state.grid.cell(coord)
	if c.has_cover():
		return float(MCF.COVER_MOD.get(c.cover_height, 1)) * 2.0
	return 0.0

# --- Дрон (§3.12) ---
func _drone_action(state: GameState, r: GameActionResolver, u: UnitInstance) -> Dictionary:
	if not r.operator_controls(u) or u.remaining_ap <= 0:
		return {}
	# Подрыв, если рядом враг (радиус взрыва 1 по Чебышёву).
	for e: UnitInstance in _enemies_of(state):
		if Combat.distance(u.coord, e.coord) <= MCF.ANTI_TANK_BLAST_RADIUS:
			return {"score": SCORE_SHOOT_BASE + _unit_value(e), "intent": DroneDetonateIntent.new(u.id)}
	# Иначе — лететь к ближайшему врагу.
	var enemy := _nearest_enemy(state, u.coord, false, r)
	if enemy == null:
		return {}
	var best: Dictionary = {}
	for coord: Vector2i in r.drone_flight_cells(u):
		# Зависание над стеной (#96) — приём для подрыва самой стены, а ИИ охотится за
		# людьми. Ему такая клетка только тупик: выход с неё ровно один, назад.
		if state.grid.cell(coord).is_wall():
			continue
		var d := Combat.distance(coord, enemy.coord)
		var score := SCORE_MOVE_BASE + float(1000 - d)
		if best.is_empty() or score > best["score"]:
			best = {"score": score, "intent": DroneMoveIntent.new(u.id, coord)}
	return best

# --- Техника (§техника): ИИ управляет своей/захваченной машиной ---
func _vehicle_candidates(state: GameState, r: GameActionResolver, veh: Vehicle) -> Array:
	var out: Array = []
	var spec := VehicleDB.get_vehicle(veh.type_id)
	var weapons: Dictionary = spec.get("weapons", {})

	# Пушка (взрыв-ромб радиуса 2, #63): бьём по ближайшему видимому врагу в
	# дальности, если рядом с точкой прицела нет своих. Лазера у танка больше нет.
	var gun: Dictionary = weapons.get("main_gun", {})
	if not gun.is_empty() and veh.cannon_shots_this_round < int(gun.get("max_per_turn", 2)) \
			and veh.ap >= int(gun.get("ap_cost", 1)):
		var target := _vehicle_best_target(state, r, veh, int(gun.get("range", MCF.CANNON_RANGE)))
		if target != null and not _ally_near(state, target.coord, MCF.CANNON_BLAST_RADIUS):
			out.append({"score": SCORE_SHOOT_BASE + _unit_value(target) + 6.0,
				"intent": VehicleCannonIntent.new(veh.id, target.coord)})

	# Сближение: катимся к достижимому в обход стен врагу (#62), не по прямой.
	# Прогресс считаем по общему мультиисточниковому геополю (#63), а не по отдельному
	# BFS на врага — иначе ход ИИ жутко тормозит.
	var enemy := _nearest_enemy(state, veh.center(), false, r)
	if enemy != null:
		var field := _enemy_distance_field(state, false, r)
		var use_geo := field.has(veh.center())
		var start_d: int = field.at(veh.center())
		var targets := r.vehicle_move_targets(veh)
		var best_move: Dictionary = {}
		for center: Vector2i in targets.keys():
			var gain: float
			if use_geo:
				var new_d: int = field.at(center)
				gain = float(start_d - new_d)
			else:
				gain = float(Combat.distance(veh.center(), enemy.coord) - Combat.distance(center, enemy.coord))
			if gain <= 0.0 and difficulty != Difficulty.EASY:
				continue
			var score := SCORE_MOVE_BASE + gain * 3.0
			var mv: Dictionary = targets[center]
			if best_move.is_empty() or score > best_move["score"]:
				best_move = {"score": score,
					"intent": VehicleMoveIntent.new(veh.id, mv["dir"], int(mv["steps"]))}
		if not best_move.is_empty():
			out.append(best_move)

		# Разворот танка к врагу, если двигаться вдоль текущего курса некуда.
		if targets.is_empty() and veh.facing != Vector2i.ZERO:
			var want := _dir_toward(veh.center(), enemy.coord)
			if want != Vector2i.ZERO and want != veh.facing and want != -veh.facing:
				out.append({"score": SCORE_MOVE_BASE * 0.5,
					"intent": VehicleTurnIntent.new(veh.id, want)})
	return out

## Ближайший видимый (иначе любой) вражеский НЕмирный юнит в пределах дальности.
## Пушка и лазер танка бьют только по прямой (#55) — цель должна быть на одной
## горизонтали/вертикали с центром машины.
func _vehicle_best_target(state: GameState, r: GameActionResolver, veh: Vehicle, rng: int) -> UnitInstance:
	var best: UnitInstance = null
	var best_d := 1 << 30
	for e: UnitInstance in _enemies_of(state):
		if CivilianAI.is_npc(e):
			continue
		# Прицеливаемся от амбразуры, а не от центра (#62): у танка 3×3 боковые
		# клетки корпуса открывают ещё две линии огня на каждую сторону.
		var port := r.cannon_port(veh, e.coord)
		if port == Vector2i(-1, -1):
			continue  # не по прямой — пушка не достанет
		var d := Combat.distance(port, e.coord)
		if d > rng:
			continue
		if not r.is_visible_to_team(owner, e):
			continue
		# Не предлагаем выстрел сквозь стену/ЛДФ/кучу земли или чужую спину (#58, #70):
		# резолвер такой приказ отклонит, и ИИ застрянет, повторяя его.
		if r.los_blocked(port, e.coord):
			continue
		if d < best_d:
			best_d = d
			best = e
	return best

## Есть ли живой союзник (владельца машины) в радиусе r по Чебышёву от клетки.
func _ally_near(state: GameState, cell: Vector2i, radius: int) -> bool:
	for u: UnitInstance in state.living_units_of(owner):
		if u.aboard_vehicle_id != -1:
			continue
		if Combat.distance(u.coord, cell) <= radius:
			return true
	return false

## Нормализованное 8-направление от a к b (для разворота танка).
func _dir_toward(a: Vector2i, b: Vector2i) -> Vector2i:
	return Vector2i(signi(b.x - a.x), signi(b.y - a.y))

# --- Профиль сложности ---
func _seeks_cover() -> bool:
	return difficulty != Difficulty.EASY

func _pref_hard() -> bool:
	return difficulty == Difficulty.HARD
