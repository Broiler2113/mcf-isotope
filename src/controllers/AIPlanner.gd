class_name AIPlanner
extends RefCounted

## Штабной планировщик хода ИИ (#100).
##
## До этого ИИ был набором одиночек: каждый боец сам смотрел на карту и шёл к
## ближайшему врагу. Из-за этого армия толклась в дверях, перекрывала друг другу
## сектора обстрела и никогда не «уступала дорогу» тому, кому осталось только
## выстрелить.
##
## Теперь ход планируется ЦЕЛИКОМ и ЗАРАНЕЕ — как это делает командир:
##   1) для каждого бойца считаются все клетки, куда он успевает дойти;
##   2) каждая клетка оценивается штабными весами: сколько целей из неё
##      простреливается, насколько она приближает к врагу, укрыта ли она,
##      сколько врагов простреливают её саму и не встаёт ли боец в створ своим;
##   3) клетки раздаются жадно по убыванию оценки, по одной на бойца и без
##      наложений — это и есть распределение задач по армии;
##   4) активации выстраиваются так, чтобы боец, ЗАНИМАЮЩИЙ чужую назначенную
##      клетку, ходил РАНЬШЕ того, кому она обещана. Отсюда и берётся
##      «освободить место товарищу»: план знает, кто кому мешает.
##
## Планировщик ничего не мутирует — он только считает и отдаёт AIController
## назначения и порядок. Все действия по-прежнему идут через резолвер (§2.2).

const GEO_FAR := 1 << 20

## Веса штабной оценки клетки. Выстрел дороже любого манёвра: армия существует,
## чтобы стрелять, а не чтобы красиво стоять.
const W_FIRE := 30.0          # за каждую цель, которую боец накроет из клетки
const W_FIRE_EASE := 2.0      # надбавка за лёгкость попадания (7 − нужное число)
const W_ADVANCE := 3.0        # за шаг сближения по геополю
const W_COVER := 2.5          # за укрытие в клетке
const W_DANGER := -5.0        # за каждого врага, который простреливает клетку
const W_LANE_BLOCK := -20.0   # за то, что встали в створ СВОЕМУ стрелку
const W_LANE_CLEAR := 14.0    # за то, что ушли из чужого створа, освободив линию
const W_STAY := 2.0           # инерция: без выгоды бойца с места не гоняем
const W_STEP := -0.15         # за каждое потраченное очко движения (ровные пути)
## За то, что боец встал НА ДОРОГЕ СВОЕЙ ЖЕ ТЕХНИКЕ (item 2: «creates a path that
## doesn't have allied soldiers in the tanks' way beforehand»).
##
## Танк давит всё, что под гусеницей, и своих в том числе. Запретить ему такой переезд
## мало — от этого он просто перестаёт ехать: пехота уже стоит в колее, объезжать
## машине негде, и вместо раздавленного взвода получается танк, простоявший бой. Лечить
## это надо РАНЬШЕ, на раздаче клеток: штаб просто не посылает людей в коридор, по
## которому сегодня поедет машина. Вес держится между укрытием и створом — место в
## колее плохое, но если там единственная позиция с сектором обстрела, боец всё равно
## её займёт.
const W_TANK_PATH := -12.0

var owner: int = -1
## unit_id -> Vector2i: куда штаб послал бойца в этом ходу.
var destinations: Dictionary = {}
## unit_id -> float: оценка назначенной клетки (AIController поднимает ею приоритет).
var dest_score: Dictionary = {}
## Итоговый порядок активаций: [{id: int, vehicle: bool}].
var order: Array = []

var _state: GameState = null
var _r: GameActionResolver = null
var _enemies: Array = []       # живые враги, по которым ИИ вообще стреляет
var _threats: Array = []       # все живые враги, включая мирных — они тоже стреляют
var _field: GeoField = null    # геополе до врага (шаги в обход стен)
## Клетки, по которым СЕГОДНЯ может проехать наша техника (item 2). Считается один раз
## на план: позиции машин внутри плана не меняются.
var _tank_path: Dictionary = {}

## Карта створов: Vector2i -> {ally_id: true} — кто из своих стрелков простреливает
## эту клетку насквозь. Считается ОДИН раз на весь план.
##
## Раньше `_lane_conflicts` перебирал всех союзников × всех врагов и строил для каждой
## пары массив клеток отрезка — и делал это ЗАНОВО на каждую клетку-кандидата, дважды
## (для новой клетки и для текущей). При 9 бойцах, 9 врагах и ~360 клетках хода это
## десятки миллионов холостых шагов, и именно они, а не «умные веса», составляли ход ИИ.
## Позиции стрелков и врагов внутри одного плана не меняются, поэтому створы —
## величина постоянная: строим их один раз, дальше вопрос «мешаю ли я» стоит O(1).
var _lane_cells: Dictionary = {}

## Карта простреливаемости: Vector2i -> сколько врагов достают эту клетку. Считается
## ОДИН раз на весь план — ровно по той же причине, что и створы: позиции угроз внутри
## плана постоянны, а вопрос «сколько стволов смотрит на эту клетку» раньше задавался
## перебором всех угроз ЗАНОВО для каждой клетки-кандидата каждого бойца.
##
## Строится маршем луча из каждой угрозы по восьми направлениям — тем же восьми, что
## признаёт Combat.is_on_firing_line(). Марш обрывается там же, где обрывался бы ответ
## _fire_ease: когда hit_number перевалил за 7 (дальше он только растёт) или когда на
## луче встала стена/корпус машины (дальше los_blocked вернул бы true для всех). У
## марксмана луч не обрывается вовсе — его лазер бьёт сквозь всё и без учёта дальности.
var _exposure: Dictionary = {}

## Обратная карта целей: Vector2i -> Array[UnitInstance] — какие враги стоят на прямой
## линии огня с этой клетки. Считается ОДИН раз на весь план.
##
## Пункт 1 оценки клетки («сектор обстрела») перебирал ВСЕХ врагов для КАЖДОЙ клетки-
## кандидата: при сотне врагов и ~2900 клетках это 290 000 вызовов _fire_ease, и они одни
## составляли 100 из 122 мс всего плана. Но первое же, что делает _fire_ease, — отсекает
## цель проверкой is_on_firing_line(), и переживают её единицы: клетка «видит» лишь восемь
## лучей, а не всё поле. Значит отбор можно провести один раз с другой стороны — маршем
## лучей ИЗ каждого врага, — и в оценке остаётся десяток кандидатов вместо сотни.
##
## Списки строятся ВНЕШНИМ циклом по _enemies, поэтому внутри каждой клетки враги лежат
## в том же порядке, что и в _enemies. Это не косметика: score складывается из их вкладов
## в этом порядке, сложение float неассоциативно, а расхождение в последнем бите способно
## перевернуть сравнение в rows.sort_custom и увести весь ход ИИ в другую сторону.
##
## Луч НЕ обрывается ни по дальности, ни на стене. Дальность у стрелка своя (а марш идёт
## от цели, стрелок ещё не известен), да и марксман с его бесконечным лазером всё равно
## не дал бы оборвать; стена же режет линию несимметрично — поблажка амбразуре ДОТа в
## los_blocked() отмеряется от СТРЕЛКА. Обе проверки остаются за _fire_ease, здесь только
## геометрия прямой.
var _line_targets: Dictionary = {}

## unit_id -> _unit_value(): ценность цели постоянна на весь план, а спрашивают её на
## каждую удачную пару «клетка × цель».
var _enemy_value: Dictionary = {}

## Полный пересчёт плана на один ход ИИ. field — мультиисточниковое геополе
## AIController'а (кэш там же), чтобы не гонять BFS дважды.
func plan(state: GameState, r: GameActionResolver, field: GeoField,
		vehicle_rows: Array) -> void:
	_state = state
	_r = r
	_field = field
	destinations.clear()
	dest_score.clear()
	order.clear()
	_collect_enemies()

	var actors := _plannable_units()
	# Клетки, занятые нашими же бойцами на СТАРТЕ хода: по ним строятся зависимости
	# «сначала уйди ты, потом займу я».
	var occupied_by: Dictionary = {}   # Vector2i -> unit_id
	for u: UnitInstance in actors:
		occupied_by[u.coord] = u.id

	_build_lanes(actors)
	_build_exposure()
	_build_line_targets()
	_build_tank_paths()

	# Кандидаты — плоские тройки [score, id, coord], а не словари: их десятки тысяч,
	# и словарь на каждую клетку карты стоит дороже самой оценки. Сравнение в
	# сортировке то же самое (только по оценке) и порядок подачи тот же, поэтому
	# и перестановка получается та же.
	var rows: Array = []
	for u: UnitInstance in actors:
		_candidates_for(u, rows)
	# Жадная раздача: лучшее предложение по всей армии забирается первым.
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var taken: Dictionary = {}
	for row: Array in rows:
		var uid: int = row[1]
		if destinations.has(uid):
			continue
		var coord: Vector2i = row[2]
		if taken.has(coord):
			continue
		taken[coord] = true
		destinations[uid] = coord
		dest_score[uid] = row[0]
	# Кому клетка так и не досталась — остаётся на месте (лишь бы не мешал).
	for u: UnitInstance in actors:
		if not destinations.has(u.id):
			destinations[u.id] = u.coord
			dest_score[u.id] = 0.0

	order = _order_activations(actors, occupied_by, vehicle_rows)

## Куда штаб послал бойца; (-1,-1) — плана на него нет.
func destination_of(unit_id: int) -> Vector2i:
	return destinations.get(unit_id, Vector2i(-1, -1))

# --- Сбор данных ---

func _collect_enemies() -> void:
	_enemies = []
	_threats = []
	for u: UnitInstance in _state.all_units():
		if u.owner == owner or not u.is_alive() or u.aboard_vehicle_id != -1:
			continue
		_threats.append(u)
		# К мирным-НПС ИИ не рвётся и целями их не считает (#96).
		if not CivilianAI.is_npc(u):
			_enemies.append(u)

## Бойцы, которых планировщик расставляет: свои, живые, на поле, не дроны.
## Дрон летает по своей геометрии, пленник может только вырываться — им план не нужен.
##
## С #103 этим же планировщиком ходят и мирные жители (owner == NEUTRAL): их квартал
## расставляется той же штабной раскладкой, что и армия. Но только ВСКРЫТЫЕ — пока
## житель не увидел солдата и бой не начался, он по §3.10 неподвижен, и план ему не
## положен: иначе мирные тронулись бы с места до первого выстрела.
func _plannable_units() -> Array:
	var out: Array = []
	for u: UnitInstance in _state.living_units_of(owner):
		if u.is_drone or u.is_held() or u.aboard_vehicle_id != -1:
			continue
		if CivilianAI.is_npc(u) and not u.civilian_active:
			continue
		out.append(u)
	return out

# --- Оценка клеток ---

## Все предложения одного бойца: [{id, coord, score}]. Текущая клетка тоже кандидат —
## иногда лучшее решение это никуда не идти и просто стрелять.
func _candidates_for(u: UnitInstance, out: Array) -> void:
	var budget: int = u.move_credit if u.move_credit > 0 else u.stats.speed
	if u.remaining_ap <= 0 and u.move_credit <= 0:
		budget = 0
	var reach := _r.reachable_for(u, budget) if budget > 0 else null
	var start_geo: int = _field.at(u.coord)
	# «Уходим ли мы из чужого створа» зависит только от бойца, а не от клетки —
	# считаем один раз на все его кандидатуры.
	var leaving_lane := _lane_conflicts(u, u.coord) > 0
	# Оставаться на месте всегда можно — за это и отвечает W_STAY.
	out.append([_score_cell(u, u.coord, start_geo, 0, leaving_lane) + W_STAY, u.id, u.coord])
	if reach == null:
		return
	for coord: Vector2i in reach.cost:
		out.append([_score_cell(u, coord, start_geo, int(reach.cost[coord]), leaving_lane),
			u.id, coord])

## Штабная ценность клетки для конкретного бойца.
func _score_cell(u: UnitInstance, coord: Vector2i, start_geo: int, steps: int,
		leaving_lane: bool) -> float:
	var cell := _state.grid.cell(coord)
	if cell == null:
		return -1e9
	# Вплотную к огню не встаём (#48): пламя расползается. Кроме огнеупорных (#2) —
	# щитоносцу и огнемётчику пожар безразличен, и место у огня им ничем не хуже.
	if not MCF.ability_is_fireproof(u.stats.special_ability_id) and _fire_near(coord):
		return -1e9
	var score := 0.0
	# 1. Сектор обстрела — главное. Считаем каждую цель, до которой из клетки дострелим.
	# Перебираются не все враги, а только стоящие с этой клеткой на одной прямой: остальных
	# _fire_ease всё равно отсеял бы первой же проверкой (см. _line_targets). Порядок
	# внутри списка — тот же, что в _enemies, поэтому сумма складывается бит в бит так же.
	var on_line: Variant = _line_targets.get(coord)
	if on_line != null:
		for e: UnitInstance in on_line:
			var ease := _fire_ease(u, coord, e)
			if ease < 0.0:
				continue
			score += W_FIRE + ease * W_FIRE_EASE + _enemy_value[e.id]
	# 2. Сближение по реальному пути в обход стен.
	var geo: int = _field.at(coord)
	if start_geo < GEO_FAR and geo < GEO_FAR:
		score += float(start_geo - geo) * W_ADVANCE
	elif geo < GEO_FAR:
		score += W_ADVANCE  # были отрезаны, теперь путь есть — это уже прогресс
	# 3. Укрытие и ответный огонь.
	if cell.has_cover():
		score += float(MCF.COVER_MOD.get(cell.cover_height, 1)) * W_COVER
	# Окоп прячет бойца ниже линии огня — самая безопасная клетка на поле (§3.7).
	if cell.feature_id == MCF.FEATURE_TRENCH:
		score += W_COVER * 2.0
	score += float(_exposure.get(coord, 0)) * W_DANGER
	# 4. Не загораживать своим сектор обстрела — и, наоборот, уходить из чужого створа.
	var lanes := _lane_conflicts(u, coord)
	if lanes > 0:
		score += float(lanes) * W_LANE_BLOCK
	elif leaving_lane:
		score += W_LANE_CLEAR  # мы стояли в створе и уходим с него — это ценно само по себе
	# 5. Не стоять на дороге у своей же техники (item 2).
	if _tank_path.has(coord):
		score += W_TANK_PATH
	score += float(steps) * W_STEP
	return score

## Коридор, по которому сегодня поедет своя техника (item 2).
##
## Берём КАЖДОЕ направление, куда машина вправе тронуться (танк — вдоль фронта, челнок —
## на все восемь), планируем ход на весь запас хода теми же правилами, что его исполнят,
## и помечаем все клетки, которые след машины при этом заметёт. Это и есть «дорога
## танка»: не линия, а полоса шириной в корпус.
##
## Планируем на ПОЛНЫЙ запас, хотя машина, скорее всего, проедет меньше: пустая колея
## впереди стоит дёшево, а вот боец, оставленный в трёх клетках по курсу, дороже — танк
## доедет до него именно тогда, когда ему понадобится ехать.
func _build_tank_paths() -> void:
	_tank_path.clear()
	for veh: Vehicle in _state.all_vehicles():
		if veh.owner != owner or not veh.alive():
			continue
		var speed: int = int(VehicleDB.get_vehicle(veh.type_id).get("speed", 0))
		if speed <= 0:
			continue
		var dirs: Array = []
		if veh.facing != Vector2i.ZERO:
			dirs = [veh.facing, -veh.facing]
		else:
			dirs = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
				Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
		for dir: Vector2i in dirs:
			var plan_res := VehicleRules.plan_line_move(_state, veh, dir, speed, speed)
			if not plan_res["ok"]:
				continue
			for i in range(1, int(plan_res["steps"]) + 1):
				for fc: Vector2i in veh.footprint_from(veh.origin + dir * i):
					_tank_path[fc] = true

## Насколько легко бойцу shooter попасть по цели из клетки from: 0..6, −1 = не достанет.
## target можно не задавать, тогда стреляем по клетке at (для оценки простреливаемости).
func _fire_ease(shooter: UnitInstance, from: Vector2i, target: UnitInstance,
		at: Vector2i = Vector2i(-1, -1)) -> float:
	var to_coord: Vector2i = target.coord if target != null else at
	if to_coord == Vector2i(-1, -1) or from == to_coord:
		return -1.0
	if not Combat.is_on_firing_line(from, to_coord):
		return -1.0
	var dist := Combat.distance(from, to_coord)
	var marksman := shooter.stats.special_ability_id == MCF.ABILITY_MARKSMAN
	var need := Combat.hit_number(dist, shooter.stats.fire_range)
	if not marksman and need >= 7:
		return -1.0
	# Боец в окопе недосягаем с дистанции (§3.7) — и для нас, и для врага. Марксману
	# считаем по правилам луча (#105): у него нет поблажки «вплотную», зато из своей
	# канавы он простреливает её насквозь. Без флага план ставил марксману выстрелы,
	# которые резолвер потом отклонял.
	if target != null and _r.trench_protected(from, target, marksman):
		return -1.0
	# Стены и корпуса машин линию рвут; людей игнорируем — их разбирает _lane_conflicts.
	if not marksman and _r.los_blocked(from, to_coord, true, true):
		return -1.0
	# Выстрел, который заведомо парируется (щитоносец издалека, #69) — не выстрел.
	if target != null and _r.shot_is_futile(shooter, target):
		return -1.0
	return float(clampi(7 - need, 0, 6))

## Разметить все створы своих стрелков (#100, оптимизация). Для каждого союзника,
## который в этом ходу ещё может выстрелить, проходим его открытые линии огня и
## помечаем клетки МЕЖДУ ним и целью его id.
##
## Условия отбора пары «стрелок → враг» те же, что были в цикле: цель на прямой,
## дистанция не безнадёжна, и линия не перекрыта стеной (за чужую стену боец не в
## ответе). Проверка «а лежит ли КОНКРЕТНАЯ клетка на отрезке» из условия ушла в
## саму разметку, поэтому порядок проверок стал другим — но конъюнкция та же, и
## множество клеток, где союзник считается перекрытым, совпадает клетка в клетку.
## Союзник учитывается один раз независимо от числа его целей (в исходном коде это
## делал `break`), поэтому в клетке хранится МНОЖЕСТВО id, а не счётчик.
func _build_lanes(allies: Array) -> void:
	_lane_cells = {}
	for a: UnitInstance in allies:
		if a.remaining_ap <= 0:
			continue
		if a.stats.special_ability_id == MCF.ABILITY_MARKSMAN:
			continue  # лазер бьёт сквозь всё, ему створ не перекрыть
		var from: Vector2i = a.coord
		var rng: float = a.stats.fire_range
		var aid: int = a.id
		for e: UnitInstance in _enemies:
			var to: Vector2i = e.coord
			if not Combat.is_on_firing_line(from, to):
				continue
			if Combat.hit_number(Combat.distance(from, to), rng) >= 7:
				continue
			if _r.los_blocked(from, to, true, true):
				continue  # створ и так закрыт стеной — нашей вины тут нет
			var sx := signi(to.x - from.x)
			var sy := signi(to.y - from.y)
			var c := Vector2i(from.x + sx, from.y + sy)
			while c != to:
				var owners: Dictionary = _lane_cells.get(c, {})
				owners[aid] = true
				_lane_cells[c] = owners
				c = Vector2i(c.x + sx, c.y + sy)

## Разметить простреливаемость всего поля (#100, оптимизация). Каждая угроза пускает
## восемь лучей и метит клетки, до которых её выстрел долетает — это ровно те клетки,
## на которых _fire_ease(e, e.coord, null, coord) раньше отвечал «достану».
##
## Совпадение с прежним условием по пунктам: клетка на прямой — по построению луча;
## coord != e.coord — луч начинается с шага 1; дальность — hit_number(d) < 7, и как
## только он дошёл до 7, дальше по лучу он тоже 7 (величина неубывающая по дистанции),
## поэтому обрыв законен; окоп и «бесполезный выстрел» в этой ветке не проверялись
## вовсе (target был null); линия огня — те же правила, что в los_blocked(ignore_units),
## включая поблажку амбразуре ДОТа и мешкам вплотную (d <= 1).
func _build_exposure() -> void:
	_exposure = {}
	var grid := _state.grid
	var gw := grid.width
	var gh := grid.height
	for e: UnitInstance in _threats:
		var marksman := e.stats.special_ability_id == MCF.ABILITY_MARKSMAN
		var rng: float = e.stats.fire_range
		for dir: Vector2i in Grid.N8:
			var dxs := dir.x
			var dys := dir.y
			var x: int = e.coord.x + dxs
			var y: int = e.coord.y + dys
			var d := 1
			while x >= 0 and y >= 0 and x < gw and y < gh:
				if not marksman and Combat.hit_number(d, rng) >= 7:
					break  # дальше по лучу только дальше — попадания уже не будет
				var c := Vector2i(x, y)
				_exposure[c] = int(_exposure.get(c, 0)) + 1
				if not marksman:
					# Преграда НА этой клетке рвёт луч для всех следующих: для них она
					# станет промежуточной, и los_blocked вернёт true.
					var gc := grid.cell_fast(x, y)
					if gc.cover_height >= MCF.WALL_HEIGHT:
						var fid := gc.feature_id
						if not (d <= 1 and (fid == MCF.FEATURE_HEDGEHOG_SANDBAGS \
								or fid == MCF.FEATURE_DOT_OPEN)):
							break
					elif gc.vehicle_id != -1:
						break
				x += dxs
				y += dys
				d += 1

## Разметить, с каких клеток какие враги стоят на прямой линии огня (см. _line_targets).
## Из каждого врага пускаются те же восемь лучей, что признаёт Combat.is_on_firing_line();
## условие симметрично (delta.x == 0, delta.y == 0 либо |dx| == |dy|), поэтому «враг e
## помечен в клетке c» равносильно «is_on_firing_line(c, e.coord)» — клетка в клетку.
## Луч начинается с шага 1, так что собственная клетка врага ему не достаётся: там
## delta нулевая и прежняя проверка тоже отвечала «нет».
func _build_line_targets() -> void:
	_line_targets = {}
	_enemy_value = {}
	var grid := _state.grid
	var gw := grid.width
	var gh := grid.height
	for e: UnitInstance in _enemies:
		_enemy_value[e.id] = _unit_value(e)
		var ex: int = e.coord.x
		var ey: int = e.coord.y
		for dir: Vector2i in Grid.N8:
			var dxs := dir.x
			var dys := dir.y
			var x := ex + dxs
			var y := ey + dys
			while x >= 0 and y >= 0 and x < gw and y < gh:
				var c := Vector2i(x, y)
				var lst: Variant = _line_targets.get(c)
				if lst == null:
					_line_targets[c] = [e]
				else:
					lst.append(e)
				x += dxs
				y += dys

## Сколько своих стрелков боец, стоящий в coord, загораживает от их целей (#100).
## Именно эта величина заставляет ИИ расступаться: клетка в чужом створе стоит дорого.
func _lane_conflicts(u: UnitInstance, coord: Vector2i) -> int:
	var owners: Dictionary = _lane_cells.get(coord, {})
	if owners.is_empty():
		return 0
	# Сам себе створ боец не перекрывает.
	return owners.size() - (1 if owners.has(u.id) else 0)

func _fire_near(coord: Vector2i) -> bool:
	var grid := _state.grid
	var c := grid.cell(coord)
	if c == null:
		return false
	if c.on_fire:
		return true
	# Восемь соседей напрямую: grid.neighbors() строит массив, а сюда заходят
	# все клетки хода каждого бойца.
	for y in range(coord.y - 1, coord.y + 2):
		if y < 0 or y >= grid.height:
			continue
		for x in range(coord.x - 1, coord.x + 2):
			if x < 0 or x >= grid.width:
				continue
			if grid.cell_fast(x, y).on_fire:
				return true
	return false

func _unit_value(u: UnitInstance) -> float:
	var v := 3.0 + float(u.stats.rate_of_fire)
	if u.stats.special_ability_id != "" \
			and u.stats.special_ability_id != MCF.ABILITY_CIVILIAN:
		v += 3.0
	match u.stats.special_ability_id:
		MCF.ABILITY_SNIPER, MCF.ABILITY_MARKSMAN, MCF.ABILITY_ANTI_TANK:
			v += 3.0
	# Нейтрал бьёт по самому ДОРОГОМУ (§4.3): цена цели весит сильнее, чем у армии.
	# Дубль правила из AIController._unit_value — обе оценки обязаны совпадать.
	if MCF.is_neutral(owner):
		v += float(u.stats.cost) * 0.1
	return v

# --- Порядок активаций ---

## Кто ходит раньше. Правило одно и оно же и есть «освободить место»: если клетка,
## назначенная бойцу A, сейчас занята бойцом B, то B обязан сходить ПЕРВЫМ — иначе
## A упрётся в спину товарища и весь план рассыплется. Остальное — по ценности
## назначения: у кого на руках выстрел, тот и начинает бой.
func _order_activations(actors: Array, occupied_by: Dictionary, vehicle_rows: Array) -> Array:
	# Граф ожиданий: waits[A] = B значит «A ждёт, пока B освободит клетку».
	var waits: Dictionary = {}
	for u: UnitInstance in actors:
		var dest: Vector2i = destinations.get(u.id, u.coord)
		if dest == u.coord:
			continue
		if occupied_by.has(dest) and int(occupied_by[dest]) != u.id:
			waits[u.id] = int(occupied_by[dest])

	var by_id: Dictionary = {}
	for u: UnitInstance in actors:
		by_id[u.id] = u
	# Готовые к ходу сортируем по ценности плана: сначала те, кто стреляет.
	var pending: Array = []
	for u: UnitInstance in actors:
		pending.append(u.id)
	pending.sort_custom(func(a: int, b: int) -> bool:
		return float(dest_score.get(a, 0.0)) > float(dest_score.get(b, 0.0)))

	var out: Array = []
	var done: Dictionary = {}
	var guard := pending.size() + 1
	while not pending.is_empty() and guard > 0:
		guard -= 1
		var moved := false
		var still: Array = []
		for uid: int in pending:
			var blocker: int = int(waits.get(uid, -1))
			# Ждём только того, кто ещё не сходил и вообще собирается уходить.
			if blocker != -1 and not done.has(blocker) and by_id.has(blocker):
				still.append(uid)
				continue
			out.append({"id": uid, "vehicle": false})
			done[uid] = true
			moved = true
		pending = still
		if not moved:
			break  # круговая зависимость (все стоят друг у друга на пути) — рвём цикл
	# Остаток (взаимные блокировки) дописываем как есть: пусть ходят, кто-то да сдвинется.
	for uid: int in pending:
		out.append({"id": uid, "vehicle": false})
	out.append_array(vehicle_rows)
	return out
