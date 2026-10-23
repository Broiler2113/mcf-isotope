@abstract
extends "res://src/resolver/parts/ResolverWorks.gd"

## Who can hit what: lines of fire, glass and windows on the way, hit rolls and the
## legal-target queries the screen and the AI ask.

# --- Вспомогательные для спецстрельбы ---
func _step_toward(from_coord: Vector2i, to_coord: Vector2i) -> Vector2i:
	return Vector2i(signi(to_coord.x - from_coord.x), signi(to_coord.y - from_coord.y))

func _is_shield(u: UnitInstance) -> bool:
	return u != null and u.attack_ability() == MCF.ABILITY_SHIELD_BEARER

## Не гибнет в огне и не обходит его при поиске пути (#1, #2): щитоносец и огнемётчик.
## Публичная — тем же вопросом задаётся Main, когда решает, рисовать ли крест-предупреждение.
func is_fireproof(u: UnitInstance) -> bool:
	# Борг не горит (batch 13 B10): оператор внутри огня не боится.
	if u == null: return false
	if u.cheat_invulnerable: return true
	# Sealed shuttle cabins protect every passenger, including the driver.
	if seated_vehicle_of(u) != null or u.borg_id != -1: return true
	return not _is_wave_fighter(u) and MCF.ability_is_fireproof(u.stats.special_ability_id)

func _is_wave_fighter(u: UnitInstance) -> bool:
	return u != null and mode != null and mode.is_holdout() and u.owner == mode.wave_side

## Blasts (owner, 2026-10-19): every shield bearer, Holdout waves included, lives through
## any blast but a direct tank shell, anti-tank round or drone. Waves still lose the
## shield's other protections (_shield_immunity).
func _blast_shield(u: UnitInstance) -> bool:
	return _is_shield(u)

func _shield_immunity(u: UnitInstance) -> bool:
	return _is_shield(u) and not _is_wave_fighter(u)

## Укрывает только щит МЕЖДУ взрывом и бойцом (fix-7, владелец): соседний щитоносец, а
## боец — по ту сторону от него, если смотреть из эпицентра. Раньше спасался любой сосед
## щитоносца, хоть сбоку, хоть со стороны взрыва.
func _protected_by(u: UnitInstance, protectors: Array, center: Vector2i) -> bool:
	for sb in protectors:
		if u.owner == sb.owner and Combat.distance(u.coord, sb.coord) <= MCF.ANTI_TANK_BLAST_RADIUS:
			var away := Vector2(u.coord - sb.coord)
			var blast := Vector2(sb.coord - center)
			if away.dot(blast) > 0.0:
				return true
	return false

## Выстрел заведомо ничего не даст: щитоносец неуязвим не в упор (§3.14), а очередь
## всё равно спишет ОД. Резолвер такой выстрел ПРИНИМАЕТ (can_shoot молчит, попадания
## просто парируются), поэтому ИИ разряжал магазин в щит с другого конца карты (#69).
## Публичная обёртка нужна, чтобы правило жило в одном месте: исключение для снайпера
## меняется здесь и сразу подхватывается ИИ.
func shot_is_futile(shooter: UnitInstance, target: UnitInstance) -> bool:
	if _shield_blocks_shot(shooter, target):
		return true
	# Семёрки на шестиграннике не бывает (item 6). Укрытие цели и огонь на линии
	# поднимают нужное число, и на 7 выстрел перестаёт быть «плохим» — он становится
	# невозможным. ИИ раньше мерил цель одной дальностью и исправно тратил ОД на
	# бойца за бетонной стеной; теперь такая цель просто не предлагается.
	return hit_need_for(shooter, target) >= 7

## Нужное число на кубике, чтобы попасть (§3.5/§3.7/§3.8/§5) — единственная формула
## на весь проект. Её спрашивает и сам выстрел, и ИИ, прикидывая, стоит ли стрелять:
## две отдельные оценки неизбежно разошлись бы, и разошлись именно там, где дороже
## всего, — в решении «тратить ли ОД».
##
## mods (необязательный) заполняется разбивкой для броска (#49): ярлык на каждую
## правку, в том же порядке, в каком её показывает кубик.
func hit_need_for(shooter: UnitInstance, target: UnitInstance, mods: Array = []) -> int:
	if shooter == null or target == null:
		return 7
	var dist := Combat.distance(shooter.coord, target.coord)
	var is_sniper := shooter.attack_ability() == MCF.ABILITY_SNIPER
	# Снайпер считается по своей лестнице (§5), остальные — по общей формуле (§3.5).
	# Раньше снайпер шёл по общей, и она мазала на каждой полосе: при дальности 40
	# давала 3+ там, где нужно автопопадание, и 3+/4+/5+/6 там, где нужно 2+/3+/4+/5+.
	var need := sniper_need(dist) if is_sniper \
			else hit_need(dist, shooter.fire_range())
	var smoke := smoke_penalty(shooter.coord, target.coord)
	if smoke > 0:
		mods.append({"label": "Smoke or gas on the line", "delta": smoke})
		if is_sniper and need == 1:
			need = 2   # no auto-hit through a cloud
		need += smoke
	if is_sniper and need == 1:
		# Автопопадание — именно АВТО: оно и раньше выставлялось ПОСЛЕ укрытия и
		# перекрывало его, и это сохранено. Снимает автопопадание только укрепление
		# на линии; полоса тогда первая неавтоматическая — 2+, а не общая формула.
		if not _fortification_between(shooter.coord, target.coord):
			mods.append({"label": "Sniper auto-hit", "delta": 0})
			return 1
		need = 2
		mods.append({"label": "Fortification on the line", "delta": 1})
	# Укрытие цели (§3.7).
	var cover := cover_effect(shooter, target)
	var pen := int(cover["hit_penalty"])
	need += pen
	if pen != 0:
		mods.append({"label": "Target cover", "delta": pen})
	return clampi(need, 1, 7)

## Сколько выбросить пушке машины по клетке (подпись прицела) — та же формула, что бросит
## _resolve_vehicle_cannon: от порта, через который пойдёт снаряд. 7 — не выстрелить.
func cannon_aim_need(veh: Vehicle, cell: Vector2i) -> int:
	if veh == null:
		return 7
	var port := cannon_port(veh, cell)
	if port == Vector2i(-1, -1):
		return 7
	var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get("weapons", {}).get("main_gun", {})
	return hit_need(Combat.distance(port, cell), float(int(gun.get("range", MCF.CANNON_RANGE))))

## Сколько выбросить, целясь в клетку (для подписи прицела): та же формула, что бросит
## сам выстрел этого стрелка. 0 — броска нет (лазер, струя, ПТ себе под ноги),
## 7 — не попасть. target — юнит в клетке, если целятся в него.
func aim_need(shooter: UnitInstance, cell: Vector2i, target: UnitInstance = null) -> int:
	if shooter == null:
		return 7
	match shooter.attack_ability():
		MCF.ABILITY_MARKSMAN, MCF.ABILITY_FLAMETHROWER:
			return 0
		MCF.ABILITY_ANTI_TANK:
			if cell == shooter.coord:
				return 0
			return mini(7, hit_need(Combat.distance(shooter.coord, cell), shooter.fire_range())
					+ smoke_penalty(shooter.coord, cell))
	if target == null:
		# Окно: попасть в стекло (0.9.2) — по дальности, как в цель, без укрытия.
		if state.grid.in_bounds(cell) and MCF.is_glass(state.grid.cell(cell).feature_id):
			return pane_hit_need(shooter, cell)
		return hit_need(Combat.distance(shooter.coord, cell), shooter.fire_range())
	return hit_need_for(shooter, target)
func shield_out_of_reach(shooter: UnitInstance, target: UnitInstance) -> bool:
	return _shield_immunity(target) and Combat.distance(shooter.coord, target.coord) > 1 \
			and not SHIELD_RANGED_ABILITIES.has(shooter.attack_ability())

func _shield_blocks_shot(shooter: UnitInstance, target: UnitInstance) -> bool:
	if not _shield_immunity(target):
		return false
	if shooter.attack_ability() == MCF.ABILITY_SNIPER:
		return false  # снайпер бьёт щитоносца с любой дистанции (§3.14)
	return Combat.distance(shooter.coord, target.coord) > 1

## Три проверки ниже раньше делали одно и то же лишнее действие: звали
## Combat.line_cells(), которая СТРОИТ и возвращает массив клеток, чтобы тут же его
## выбросить. На каждый выстрел, на каждую оценку клетки ИИ, на каждый предпросмотр —
## новый массив. Линия проходится теми же шагами, но без единого выделения памяти.
##
## Условие «не по прямой» повторяет line_cells(): она вернула бы пустой массив, а цикл
## по нему не выполнился бы ни разу — то есть ответ «нет», как и здесь.
func _wall_between(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	if _line_off_board(from_coord, to_coord):
		return false
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		if grid.cell_fast(x, y).cover_height >= MCF.WALL_HEIGHT:
			return true
		x += sx
		y += sy
	return false

## Есть ли укрепление (укрытие или стена) между стрелком и целью (§5, автопопадание снайпера).
func _fortification_between(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	if _line_off_board(from_coord, to_coord):
		return false
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		# is_wall() или has_cover() — вместе это просто «высота больше нуля».
		if grid.cell_fast(x, y).cover_height > 0.0:
			return true
		x += sx
		y += sy
	return false

# --- Запросы легальности (для подсветки целей в UI) ---
## allow_embrasure=false — стрелок не может работать через амбразуру ДОТа: заряд
## противотанкиста в узкую щель не пролезает (#86).
## ignore_units=true — считать перекрытой только НЕЖИВУЮ преграду (стена/корпус).
## Дружественный огонь (#100): чужая спина на линии не отменяет выстрел, а ловит его,
## поэтому проверка «можно ли стрелять» игнорирует людей, а попадание перенаправляет
## first_unit_on_line().
## Линия проходится ШАГАМИ, без Combat.line_cells(): та строит и возвращает массив, а
## los_blocked зовётся десятками тысяч раз за один расчёт плана ИИ — на этих
## аллокациях уходило больше времени, чем на саму проверку. Правила ниже те же
## и в том же порядке.
## glass_passable — стекло на линии НЕ отменяет выстрел (#29): пуля пробует его
## пробить, и это решается побульно уже при разрешении очереди (_glass_on_line).
## Флаг только для ПУЛЬ: заряд противотанкиста, снаряд пушки и обзор стекло по-прежнему
## считают стеной, поэтому по умолчанию он выключен.
func los_blocked(from_coord: Vector2i, to_coord: Vector2i, allow_embrasure: bool = true,
		ignore_units: bool = false, glass_passable: bool = false, smoke_passable: bool = false) -> bool:
	if _line_off_board(from_coord, to_coord):
		return false
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if dx == 0 and dy == 0:
		return false
	# Не по прямой — line_cells() вернула бы пустой массив, значит «не перекрыто».
	if dx != 0 and dy != 0 and absi(dx) != absi(dy):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	var d := 1
	# Газ (0.9.4) держит и взгляд, и выстрел — как стена. Спрашивается он ТОЛЬКО когда газ
	# на карте вообще есть: эта функция зовётся десятки тысяч раз за один расчёт плана ИИ.
	# Gas also obscures either endpoint, unlike a wall face or a firing embrasure.
	var any_gas := GridCell.obscurants() > 0 and not smoke_passable
	if any_gas and (grid.cell_fast(from_coord.x, from_coord.y).obscured() \
			or grid.cell_fast(to_coord.x, to_coord.y).obscured()):
		return true
	while x != to_coord.x or y != to_coord.y:
		var cell := grid.cell_fast(x, y)
		if any_gas and cell.obscured():
			return true
		if cell.cover_height >= MCF.WALL_HEIGHT:
			# Ёж поверх мешков — решётчатая стена: с соседней клетки сквозь неё стреляют.
			# ДОТ с амбразурами (#86): боец, прижавшийся к стене вплотную, стреляет
			# сквозь щель. Работает только в упор — издалека в амбразуру не попасть.
			# d == расстояние по Чебышёву от стрелка до этой клетки: шаг диагонали
			# и шаг по оси стоят одинаково, поэтому счётчик и есть дистанция.
			var fid := cell.feature_id
			if d <= 1 and (fid == MCF.FEATURE_HEDGEHOG_SANDBAGS \
					or (allow_embrasure and fid == MCF.FEATURE_DOT_OPEN)):
				pass
			elif glass_passable and MCF.is_glass(fid):
				pass  # стекло пуле не преграда, а испытание (#29)
			else:
				return true
		# Корпус машины перекрывает линию огня (§техника) — кроме своего же: линия,
		# начатая или оконченная на клетке этого корпуса, идёт по его крыше (batch 13:
		# пассажир стреляет со своего кресла, и в пассажира стреляют снаружи).
		elif cell.vehicle_id != -1 and cell.vehicle_id != grid.vehicle_at(from_coord) \
				and cell.vehicle_id != grid.vehicle_at(to_coord):
			return true
		# Живой юнит перекрывает линию огня; труп — нет (решение автора).
		elif not ignore_units and cell.occupant != null and cell.occupant.is_alive():
			return true
		x += sx
		y += sy
		d += 1
	return false

## Сколько стёкол стоит НА ЛИНИИ между стрелком и целью, концы не считая (#29).
## Каждое из них каждая пуля пробивает отдельным броском. Ноль — обычный выстрел,
## и тогда лишних кубиков не бросается вовсе: поток случайности старых партий цел.
func _glass_on_line(from_coord: Vector2i, to_coord: Vector2i) -> int:
	if _line_off_board(from_coord, to_coord):
		return 0
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return 0
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	var panes := 0
	while x != to_coord.x or y != to_coord.y:
		if MCF.is_glass(grid.cell_fast(x, y).feature_id):
			panes += 1
		x += sx
		y += sy
	return panes

## Координаты стёкол НА ЛИНИИ (концы не считая), по порядку от стрелка к цели.
## Нужны, чтобы пробитое стекло можно было РАЗБИТЬ на месте (item 4), а не только
## сосчитать. Порядок совпадает с порядком бросков на пробитие в _resolve_shoot.
func _glass_cells_on_line(from_coord: Vector2i, to_coord: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _line_off_board(from_coord, to_coord):
		return out
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return out
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		# И обычное, и бронестекло: раньше бронестекло на линии пуля не замечала вовсе.
		if MCF.is_glass(grid.cell_fast(x, y).feature_id):
			out.append(Vector2i(x, y))
		x += sx
		y += sy
	return out

## Ни один шаг по линии не имеет смысла, если её конец лежит ВНЕ ПОЛЯ, — а такой конец
## приходит сюда буднично: у бойца В МАШИНЕ координата вынесена за карту (OFFBOARD,
## −9999, §техника). Проверки «на одной ли прямой» это не ловит: от (−9999, −9999)
## диагональ проходит через половину карты, и цикл честно шагал ОТ края мира внутрь,
## индексируя _cells отрицательным адресом на первом же шаге — «Out of bounds get index
## '-509898' (on base: Array[GridCell])» в отчёте игрока (issue 2). Отсекаем такие
## линии в одном месте: каждый ходок по лучу спрашивает эту проверку первой строкой,
## и ни один из них больше не может уйти за край.
##
## Вне поля линия «пустая»: нет ни стены, ни огня, ни стекла, ни тела на пути.
func _line_off_board(a: Vector2i, b: Vector2i) -> bool:
	var g := state.grid
	return not g.in_bounds(a) or not g.in_bounds(b)

## Первый живой боец, стоящий НА ЛИНИИ между стрелком и целью (концы не считаются).
## Именно в него уходит выстрел, если стрелок бьёт сквозь чужую спину (#100).
## null = линия чистая, и пуля дойдёт до заявленной цели.
## skip_allies_of != null — пропускать союзников этого стрелка: при выключенном
## дружественном огне пуля проходит над своими, а не находит их спиной. Иначе
## «огонь по своим отключён» означало бы лишь запрет ПРИЦЕЛИТЬСЯ в союзника, а
## убивать его случайно всё так же было бы можно.
func first_unit_on_line(from_coord: Vector2i, to_coord: Vector2i,
		skip_allies_of: UnitInstance = null) -> UnitInstance:
	if _line_off_board(from_coord, to_coord):
		return null
	# Шаги по линии вместо Combat.line_cells(): массив-посредник здесь не нужен, а
	# функция стоит на пути КАЖДОГО выстрела. Проверка «конец линии» из старого цикла
	# не переносится: line_cells() концы и так не отдавала, она была холостой.
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return null
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		var cell := grid.cell(Vector2i(x, y))
		if cell == null:
			x += sx
			y += sy
			continue
		# Боец на дне окопа сидит ниже линии огня — пуля проходит над ним (§3.7).
		# Сосед по челноку перекрывает линию, как любой боец: стрелять сквозь него нельзя.
		if cell.occupant != null and cell.occupant.is_on_field() \
				and not trench_protected(from_coord, cell.occupant) \
				and not (skip_allies_of != null
						and is_ally_of(skip_allies_of, cell.occupant)):
			return cell.occupant
		x += sx
		y += sy
	return null

## Свой ли это боец для стрелка — сам или союзник по команде. Единственная точка,
## через которую правила спрашивают «в него вообще можно целиться».
## Огневое покрытие клеток (RL-тактика, стиль HARD «фланг»): по каждой клетке — сколько
## попаданий за ход в неё ОЖИДАЕТСЯ от стрелков, то есть сумма P(попадания) × скорострельность.
##
## hostile = true — стрелки, ВРАЖДЕБНЫЕ viewer'у и видимые ему (туман честен: невидимый враг
## сюда не попадает, иначе карта угроз подсказывала бы, где он прячется); false — свои и
## союзные стрелки viewer'а (их он знает всех).
##
## Геометрия та же, что у can_shoot: огонь только по восьми прямым (§3.5), стена или корпус
## машины луч останавливают (стекло — нет), шанс — та же лестница hit_number/sniper.
## Марксман бьёт сквозь всё, огнемёт — на FLAME_JET_LENGTH. Пушка танка — лучами из центра
## на дальность орудия. Окопы и укрытия не учитываются: это оценка «простреливается ли
## клетка», а не точный бросок.
func fire_cover(viewer: int, hostile: bool) -> PackedFloat32Array:
	var grid := state.grid
	var w := grid.width
	var shooters: Array = []
	var key := hash([viewer, hostile, fog_enabled, GridCell.vision_version, w, grid.height])
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or u.aboard_vehicle_id != -1 or u.is_held() \
				or MCF.is_neutral(u.owner) or not grid.in_bounds(u.coord):
			continue
		var mine := state.roster.are_allies(viewer, u.owner)
		if mine == hostile:
			continue
		if hostile and not is_visible_to_team(viewer, u):
			continue
		if u.fire_range() <= 0.0 and u.stats.special_ability_id != MCF.ABILITY_MARKSMAN:
			continue
		shooters.append(u)
		key = hash([key, u.id, u.coord, u.remaining_ap > 0])
	var guns: Array = []
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive() or veh.is_borg() or veh.occupants.is_empty():
			continue
		var gun: Dictionary = VehicleDB.get_vehicle(veh.type_id).get("weapons", {}).get("main_gun", {})
		if gun.is_empty() or state.roster.are_allies(viewer, veh.owner) == hostile:
			continue
		if hostile:
			var seen := not visibility_limited()
			var vis := team_visible_coords(viewer)
			for fc: Vector2i in veh.footprint():
				if vis.has(fc):
					seen = true
					break
			if not seen:
				continue
		guns.append(veh)
		key = hash([key, -1 - veh.id, veh.origin])
	if _cover_cache.has(key):
		return _cover_cache[key]
	var out := PackedFloat32Array()
	out.resize(w * grid.height)
	for u: UnitInstance in shooters:
		if grid.cell(u.coord).obscured():
			continue
		var ability: String = u.attack_ability()
		var pierce := ability == MCF.ABILITY_MARKSMAN
		var sniper := ability == MCF.ABILITY_SNIPER
		var reach := MCF.FLAME_JET_LENGTH if ability == MCF.ABILITY_FLAMETHROWER else 1 << 20
		var rof := float(maxi(1, u.rate_of_fire()))
		for d: Vector2i in DIR8:
			var c: Vector2i = u.coord
			var dist := 0
			while true:
				c += d
				dist += 1
				if dist > reach or not grid.in_bounds(c):
					break
				var cell := grid.cell_fast(c.x, c.y)
				if cell.obscured() or (not pierce and (cell.blocks_sight() or cell.vehicle_id != -1)):
					break
				var need := 1 if pierce else (sniper_need(dist) if sniper
						else hit_need(dist, u.fire_range()))
				if need >= 7:
					break
				out[c.y * w + c.x] += rof * float(7 - need) / 6.0
	for veh: Vehicle in guns:
		var rng := int(VehicleDB.get_vehicle(veh.type_id)["weapons"]["main_gun"].get("range", MCF.CANNON_RANGE))
		for d: Vector2i in DIR8:
			var c: Vector2i = veh.center()
			var dist := 0
			while true:
				c += d
				dist += 1
				if dist > rng or not grid.in_bounds(c):
					break
				var cell := grid.cell_fast(c.x, c.y)
				if cell.vehicle_id == veh.id:
					continue
				if cell.blocks_sight() or cell.vehicle_id != -1:
					break
				out[c.y * w + c.x] += 1.0
	if _cover_cache.size() > 8:
		_cover_cache.clear()
	_cover_cache[key] = out
	return out

## Прогноз на ход противника (RL-тактика): что видимые враги смогут сделать СЛЕДУЮЩИМ ходом.
##   "reach" — сколько врагов дойдут до клетки за один ход (по настоящим путям, как ходят);
##   "fire"  — ожидаемые попадания по клетке после их хода: каждый стрелок берётся в лучшей
##             для него точке из тех, куда дойдёт (решётка 3×3 его разлива плюс текущая
##             клетка), — то есть «здесь безопасно сейчас, но не через ход».
## Туман честен: только враги, видимые viewer'у. Вклад каждого врага кэшируется по его клетке
## и раунду — пока наша сторона ходит, враги стоят, и прогноз считается один раз на ход.
func enemy_forecast(viewer: int) -> Dictionary:
	var grid := state.grid
	var w := grid.width
	var n := w * grid.height
	var gid := grid.get_instance_id()
	if _fc_grid != gid:
		_fc_unit.clear()
		_fc_total.clear()
		_fc_grid = gid
	var hostiles: Array = []
	var key := hash([viewer, fog_enabled, GridCell.vision_version, state.turns.round_number, n])
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or u.aboard_vehicle_id != -1 or u.is_held() \
				or MCF.is_neutral(u.owner) or not grid.in_bounds(u.coord) \
				or state.roster.are_allies(viewer, u.owner) or not is_visible_to_team(viewer, u):
			continue
		hostiles.append(u)
		key = hash([key, u.id, u.coord])
	if _fc_total.has(key):
		return _fc_total[key]
	var reach := PackedFloat32Array()
	reach.resize(n)
	var fire := PackedFloat32Array()
	fire.resize(n)
	for u: UnitInstance in hostiles:
		var ukey := hash([u.coord, GridCell.vision_version, state.turns.round_number])
		var rec: Variant = _fc_unit.get(u.id)
		if rec == null or rec[0] != ukey:
			rec = [ukey] + _forecast_unit(u)
			_fc_unit[u.id] = rec
		for i: int in rec[1]:
			reach[i] += 1.0
		var fi: PackedInt32Array = rec[2]
		var fv: PackedFloat32Array = rec[3]
		for j in fi.size():
			fire[fi[j]] += fv[j]
	if _fc_total.size() > 8:
		_fc_total.clear()
	_fc_total[key] = {"reach": reach, "fire": fire}
	return _fc_total[key]

## Вклад одного врага в прогноз: клетки, куда он дойдёт, и лучший огонь по каждой клетке
## из точек, куда он дойдёт (максимум, а не сумма: стоять он будет в одной точке).
func _forecast_unit(u: UnitInstance) -> Array:
	var grid := state.grid
	var w := grid.width
	var cost: Dictionary = reachable_for(u, move_budget_fresh(u)).cost
	var reach_idx := PackedInt32Array()
	var spots: Array[Vector2i] = [u.coord]
	for c: Vector2i in cost:
		reach_idx.append(c.y * w + c.x)
		if c.x % 3 == 0 and c.y % 3 == 0 and c != u.coord and not grid.blocks_walk(c):
			spots.append(c)
	var best: Dictionary = {}
	var ability: String = u.attack_ability()
	if u.fire_range() > 0.0 or ability == MCF.ABILITY_MARKSMAN:
		var pierce := ability == MCF.ABILITY_MARKSMAN
		var sniper := ability == MCF.ABILITY_SNIPER
		var max_d := MCF.FLAME_JET_LENGTH if ability == MCF.ABILITY_FLAMETHROWER else 1 << 20
		var rof := float(maxi(1, u.rate_of_fire()))
		for from: Vector2i in spots:
			if grid.cell(from).obscured():
				continue
			for d: Vector2i in DIR8:
				var c: Vector2i = from
				var dist := 0
				while true:
					c += d
					dist += 1
					if dist > max_d or not grid.in_bounds(c):
						break
					var cell := grid.cell_fast(c.x, c.y)
					if cell.obscured() or (not pierce and (cell.blocks_sight() or cell.vehicle_id != -1)):
						break
					var need := 1 if pierce else (sniper_need(dist) if sniper
							else hit_need(dist, u.fire_range()))
					if need >= 7:
						break
					var i := c.y * w + c.x
					var v := rof * float(7 - need) / 6.0
					if v > float(best.get(i, 0.0)):
						best[i] = v
	var fi := PackedInt32Array(best.keys())
	var fv := PackedFloat32Array(best.values())
	return [reach_idx, fi, fv]

func is_ally_of(a: UnitInstance, b: UnitInstance) -> bool:
	if a == null or b == null:
		return false
	return state.roster.are_allies(a.owner, b.owner)

## "" = стрелять можно; иначе причина отказа.
func can_shoot(shooter: UnitInstance, target: UnitInstance) -> String:
	if target == null or not target.is_on_field():
		return "No target"
	if target.id == shooter.id:
		return "Can't shoot yourself"
	# СТРЕЛОК вне поля — зеркало проверки цели ниже (issue 2): сидящий в машине стреляет
	# из неё только орудиями машины, а его собственная координата вынесена за карту, и
	# любая линия от неё уходит за край сетки.
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	# Боец В МАШИНЕ целью быть не может (#23): его координата — OFFBOARD (-9999,-9999),
	# и она вне поля. is_on_firing_line() отвечает на неё «да» (по диагонали от почти
	# любой клетки), после чего trench_protected() дёргает cell(OFFBOARD).feature_id на
	# null — отсюда «feature_id on Nil» при нажатии «Стрельба», а los_blocked() за ним
	# уходит шагать десять тысяч клеток к краю мира. Отсекаем такие цели сразу.
	if not state.grid.in_bounds(target.coord):
		return "Target unavailable"
	# Дружественный огонь (#100): по своим стрелять МОЖНО — оружие не разбирает форму.
	# Выключенный в лобби, он запрещает и прицел в союзника (§7 «Лобби»).
	if not friendly_fire_enabled and is_ally_of(shooter, target):
		return "Friendly fire is off"
	# Свой всегда виден, поэтому проверку тумана войны он проходит сам собой.
	# Туман войны (§3.9): скрытого противника нельзя выбрать целью. Smoke and gas on the
	# line no longer forbid the shot — they cost SMOKE_HIT_PENALTY (owner, 2026-10-19).
	if not is_visible_to_team(shooter.owner, target):
		return "Target not visible"
	if not Combat.is_on_firing_line(shooter.coord, target.coord):
		return "Target not on the firing line"
	# Боец на дне окопа скрыт ниже линии огня — достать его можно только вплотную (§3.7),
	# а лазером (§3.13) — только из такого же окопа: луч не гнётся вниз (#103).
	if trench_protected(shooter.coord, target, _fires_flat_beam(shooter)):
		return _trench_block_reason(shooter)

	var dist := Combat.distance(shooter.coord, target.coord)
	if shield_out_of_reach(shooter, target):
		return "The shield stops fire from range - get next to it"
	match shooter.attack_ability():
		MCF.ABILITY_MARKSMAN:
			# Лазер бьёт на любую дистанцию и пробивает препятствия (§3.13).
			return ""
		MCF.ABILITY_FLAMETHROWER:
			# Струя пламени 6 клеток, не проходит сквозь стену (§3.14).
			if dist > MCF.FLAME_JET_LENGTH:
				return "Too far for the flame jet"
			if _wall_between(shooter.coord, target.coord):
				return "Flame jet blocked by a wall"
			return ""

	# Люди на линии выстрел не запрещают (#100): пуля просто достанется первому из них,
	# см. first_unit_on_line(). Стена и корпус машины по-прежнему отменяют стрельбу.
	# Стекло — отдельный случай (#29): по цели ЗА стеклом стрелять можно, каждая пуля
	# пробует его пробить сама. Заряд противотанкиста в это исключение не входит.
	if los_blocked(shooter.coord, target.coord, not _is_anti_tank(shooter), true,
			not _is_anti_tank(shooter), true):
		return "Firing line is blocked"
	# Стоящий за чужой спиной — не цель (batch soil-rulers): пуля и заряд ПТ всё равно
	# достались бы первому на линии (см. перехват в _resolve_shoot), а прицел, который
	# показывает заднего, обещал выстрел, которого в игре нет. Целиться — в того, кто ближе.
	# Your own soldiers block the line too (playtest 2026-10-19: crews leaving a tank fired
	# straight through each other). Friendly fire off only means they are never hit.
	if first_unit_on_line(shooter.coord, target.coord) != null:
		return "Another unit is in the way"
	if hit_need(dist, shooter.fire_range()) + smoke_penalty(shooter.coord, target.coord) >= 7:
		return "Too far to hit through the smoke" if smoke_penalty(shooter.coord, target.coord) > 0 else "Too far"
	return ""
func smoke_penalty(a: Vector2i, b: Vector2i) -> int:
	return SMOKE_HIT_PENALTY if gas_blocks_line(a, b) else 0

## Окно под выстрел (batch ui-drones): видимая клетка со стеклом на линии огня и в
## пределах дальности. Спецстрелкам (противотанкист, огнемётчик, марксман) свой путь.
func can_shoot_window(shooter: UnitInstance, cell: Vector2i) -> String:
	if shooter.attack_ability() in [MCF.ABILITY_ANTI_TANK, MCF.ABILITY_FLAMETHROWER,
			MCF.ABILITY_MARKSMAN, MCF.ABILITY_MINER, MCF.ABILITY_SHIELD_BEARER]:
		return "This unit can't shoot at windows"
	if not state.grid.in_bounds(shooter.coord) or not state.grid.in_bounds(cell):
		return "No target"
	if not MCF.is_glass(state.grid.cell(cell).feature_id):
		return "No window there"
	if not Combat.is_on_firing_line(shooter.coord, cell):
		return "Target not on the firing line"
	if fog_enabled and not team_visible_coords(shooter.owner).has(cell):
		return "Target not visible"
	if los_blocked(shooter.coord, cell, true, true, true):
		return "Firing line is blocked"
	if hit_need(Combat.distance(shooter.coord, cell), shooter.fire_range()) >= 7:
		return "Too far"
	var pending := shooter.action_state != null and shooter.action_state.is_pending()
	if shooter.remaining_ap <= 0 and not pending:
		return "Unit has no AP left"
	return ""

## Окна, которые стрелок сейчас может разбить (для подсветки в режиме стрельбы).
func shootable_window_cells(shooter: UnitInstance) -> Array:
	var out: Array = []
	var reach := int(shooter.fire_range())
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var c := shooter.coord + Vector2i(dx, dy)
			if state.grid.in_bounds(c) and MCF.is_glass(state.grid.cell(c).feature_id) \
					and can_shoot_window(shooter, c) == "":
				out.append(c)
	return out

## Выстрел по окну (0.9.2): обычная очередь — игрок сам выбирает, сколько пуль (остаток
## оплаченной очереди можно дострелить потом, как по бойцу), и обычный порядок: попасть в
## окно, окно держит каждую попавшую пулю спасброском, прошла хоть одна — окно осыпается.
## Стёкла перед окном пули проходят тем же порядком (_through_glass).
func _resolve_shoot_window(shooter: UnitInstance, cell: Vector2i, shots: int = -1) -> ActionResult:
	var pending := shooter.action_state != null and shooter.action_state.is_pending()
	if not pending:
		shooter.remaining_ap -= 1
		shooter.action_state = ActionState.new()
		shooter.action_state.remaining_shots = maxi(1, shooter.rate_of_fire())
	shooter.action_state.target_id = ActionState.WINDOW
	var available: int = shooter.action_state.remaining_shots
	var want: int = available if shots < 0 else clampi(shots, 1, available)
	var result := ActionResult.success()
	var gc := state.grid.cell(cell)
	var what := String(MCF.feature_name(gc.feature_id, "glass")).to_lower()
	var panes := _glass_cells_on_line(shooter.coord, cell)
	panes.append(cell)
	result.log("%s fires %d at the %s at (%d, %d)" % [shooter.stats.display_name, want, what, cell.x, cell.y])
	_through_glass(shooter, panes, want, result)
	shooter.action_state.remaining_shots -= want
	if shooter.action_state.remaining_shots <= 0:
		shooter.action_state = null
	_fx_lane(result, shooter.coord, cell, shooter.owner, "shot", _weapon_of(shooter))
	_fx(result, {"fx": "casings", "at": shooter.coord, "toward": cell, "count": want})
	_fx(result, {"fx": "tracer", "at": shooter.coord, "from": [shooter.coord.x, shooter.coord.y],
		"to": [cell.x, cell.y], "count": want})
	if MCF.is_glass(gc.feature_id):
		result.log("… the %s holds" % what)
	if shooter.action_state != null:
		result.log("… shots remaining in burst: %d" % shooter.action_state.remaining_shots)
	return result

## Сколько выбросить, чтобы пуля этого стрелка попала в стекло в клетке cell: по дальности
## до стекла, как в цель, но без укрытия (у стекла его нет); огонь на линии на попадание не влияет.
func pane_hit_need(shooter: UnitInstance, cell: Vector2i) -> int:
	var dist := Combat.distance(shooter.coord, cell)
	var is_sniper := shooter.attack_ability() == MCF.ABILITY_SNIPER
	var need := sniper_need(dist) if is_sniper \
			else hit_need(dist, shooter.fire_range())
	return clampi(need, 1, 7)

## Очередь сквозь стёкла (0.9.2, правило игрока). Стёкла — по порядку от стрелка; у
## каждого: 1) летящие пули бросают попадание в стекло (pane_hit_need) — промах ушёл в
## раму и стену и дальше не летит; 2) стекло держит каждую попавшую пулю спасброском
## (обычное 5+, бронестекло 4+); 3) хоть одна пуля прошла — стекло осыпается (осколки —
## в событии броска, их показывают сразу после него); 4) прошедшие летят дальше — к
## следующему стеклу или к цели. Возвращает, сколько пуль вышло из последнего стекла.
## Пули очереди летят разом, поэтому все они встречают стекло целым.
func _through_glass(shooter: UnitInstance, panes: Array[Vector2i], bullets: int, res: ActionResult) -> int:
	for pc: Vector2i in panes:
		if bullets <= 0:
			break
		var gcell := state.grid.cell(pc)
		if gcell == null or not MCF.is_glass(gcell.feature_id):
			continue
		var need := pane_hit_need(shooter, pc)
		var save := MCF.glass_bullet_save(gcell.feature_id)
		var hits: Array = []
		var landed := 0
		for _i in bullets:
			var r := state.dice.roll_d6()
			hits.append({"roll": r, "hit": r >= need})
			if r >= need:
				landed += 1
		var saves: Array = []
		var through := 0
		for _i in landed:
			var r := state.dice.roll_d6()
			saves.append({"roll": r, "held": r >= save})
			if r < save:
				through += 1
		var name := String(MCF.feature_name(gcell.feature_id, "Glass"))
		var ev := {"kind": "glass", "name": name, "cell": pc, "need": need, "save": save,
			"hits": hits, "saves": saves, "broke": through > 0, "fx": [],
			"shooter_owner": shooter.owner}
		res.dice_events.append(ev)
		res.log("… %s at (%d, %d): %d of %d hit it (need %d+), %d got through (it holds on %d+)" % [
			name, pc.x, pc.y, landed, bullets, need, through, save])
		if through > 0:
			# Стекло видно целым, пока крутятся его кубики, — осыпается после них.
			_capture_visual_hold(res, [pc])
			gcell.clear_feature()
			notify_cell_changed(pc)
			ev["fx"] = [{"fx": "shards", "at": pc, "from": shooter.coord},
					{"fx": "debris", "at": NOWHERE, "cells": [pc]}]
			res.log("… the %s shatters" % name.to_lower())
		bullets = through
	return bullets

func _is_anti_tank(u: UnitInstance) -> bool:
	return u != null and u.attack_ability() == MCF.ABILITY_ANTI_TANK

## Все, по кому стрелок может открыть огонь. Со времён #100 сюда попадают и СВОИ:
## дружественный огонь разрешён, и игрок должен видеть, что союзник тоже под прицелом.
## Прямая линия — необходимое условие ЛЮБОГО разрешённого выстрела: can_shoot() проверяет
## её раньше всех исключений, включая лазер марксмана и струю огнемёта. Поэтому целей,
## стоящих не на луче, можно отсеивать вычитанием векторов, не заходя в can_shoot() с её
## туманом, окопами и трассировкой. В бою на 200 бойцов так отваливаются девять из десяти.
func shootable_target_ids(shooter: UnitInstance) -> Array:
	var out: Array = []
	var from: Vector2i = shooter.coord
	var sid: int = shooter.id
	for u in state.all_units():
		if u.id == sid or not u.is_on_field():
			continue
		# Экипаж танка (coord = OFFBOARD) на поле не стоит — целью не считается (#23);
		# пассажир челнока сидит в клетке следа и под прицелом (batch 13 S5).
		if not state.grid.in_bounds(u.coord):
			continue
		if not Combat.is_on_firing_line(from, u.coord):
			continue
		if can_shoot(shooter, u) == "":
			out.append(u.id)
	return out

## Только вражеские цели — то, что ищет ИИ и автонаведение. Своих сюда не пускаем,
## иначе «умный» ИИ начал бы расстреливать собственный взвод (#100).
## Своих отсеиваем ДО can_shoot(), а не после: половина армии — свои, и проверять их
## туман, окопы и линию огня только затем, чтобы тут же выбросить, значит удваивать
## работу. Отбор и порядок остаются теми же, что при фильтрации готового списка.
func hostile_target_ids(shooter: UnitInstance) -> Array:
	var out: Array = []
	var from: Vector2i = shooter.coord
	var sowner: int = shooter.owner
	var sid: int = shooter.id
	for u in state.all_units():
		if u.id == sid or not u.is_on_field():
			continue
		# Не считаем целью СОЮЗНИКОВ: ни свой слот, ни товарища по команде, ни (для
		# нейтралов) другого нейтрала — ИИ не должен даже пытаться в них стрелять
		# (item 15 + запрос про ИИ-команды). is_ally_of покрывает все три случая.
		if is_ally_of(shooter, u):
			continue
		if not state.grid.in_bounds(u.coord):
			continue
		if not Combat.is_on_firing_line(from, u.coord):
			continue
		if can_shoot(shooter, u) == "":
			out.append(u.id)
	return out

## "" = противотанкист может ударить по этой клетке пола; иначе причина отказа (§3.14).
func can_blast_cell(shooter: UnitInstance, cell: Vector2i) -> String:
	if shooter.attack_ability() != MCF.ABILITY_ANTI_TANK:
		return "Only the anti-tank can hit the ground"
	if not state.grid.in_bounds(cell):
		return "Target out of bounds"
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	var c := state.grid.cell(cell)
	if c.is_space:
		return "Can't hit space - no floor"
	# Выстрел под себя (#11): собственная клетка — законная цель. Проверять линию огня
	# и дистанцию до самого себя нечего, и is_on_firing_line на нулевом векторе всё
	# равно отвечает «нет», поэтому этот случай обязан отстреливаться первым.
	if cell == shooter.coord:
		return ""
	# Клетка с живым бойцом проверяется наравне с остальными. Раньше она пропускалась
	# сразу — «обычная стрельба это уже покрывает», — и мимо линии огня, стен и дальности
	# шёл любой удар по такой клетке: ИИ бил по корпусу машины через клетку пассажира
	# под любым углом и с любой дистанции, бросая заведомые 7+.
	if not Combat.is_on_firing_line(shooter.coord, cell):
		return "Target not on the firing line"
	# Заряд противотанкиста в амбразуру не пролезает (#86).
	if los_blocked(shooter.coord, cell, false, false, false, true):
		return "Firing line is blocked"
	if hit_need(Combat.distance(shooter.coord, cell), shooter.fire_range()) \
			+ smoke_penalty(shooter.coord, cell) >= 7:
		return "Too far"
	return ""

## Пустые клетки пола, по которым противотанкист может ударить (для подсветки в UI).
func blastable_cells(shooter: UnitInstance) -> Array:
	var out: Array = []
	if shooter.attack_ability() != MCF.ABILITY_ANTI_TANK:
		return out
	var reach := shooter.fire_range()
	# Собственная клетка — первой в списке (#11): она и есть «ударить под себя»,
	# и UI подсвечивает её наравне с остальными. Через ту же проверку, что и остальные:
	# стоящий на клетке космоса (без пола) ударить под себя не может, а список её
	# предлагал — перечислитель RL выдавал намерение, которое резолвер отклонял.
	if can_blast_cell(shooter, shooter.coord) == "":
		out.append(shooter.coord)
	for dy in range(-int(reach), int(reach) + 1):
		for dx in range(-int(reach), int(reach) + 1):
			var c := Vector2i(shooter.coord.x + dx, shooter.coord.y + dy)
			if c == shooter.coord:
				continue
			var cell := state.grid.cell(c) if state.grid.in_bounds(c) else null
			if cell == null or (cell.occupant != null and cell.occupant.is_alive()):
				continue
			if can_blast_cell(shooter, c) == "":
				out.append(c)
	return out

## "" = огнемётчик может пустить струю в направлении этой клетки; иначе причина отказа.
func can_flame_cell(shooter: UnitInstance, cell: Vector2i) -> String:
	if shooter.attack_ability() != MCF.ABILITY_FLAMETHROWER:
		return "Only the flamethrower can spray the ground"
	if not state.grid.in_bounds(cell):
		return "Target out of bounds"
	if not state.grid.in_bounds(shooter.coord):
		return "Shooter is not on the board"
	if cell == shooter.coord:
		return "Pick a cell in front"
	if state.grid.cell(cell).is_space:
		return "Can't ignite space"
	if not Combat.is_on_firing_line(shooter.coord, cell):
		return "Target not on the firing line"
	if Combat.distance(shooter.coord, cell) > MCF.FLAME_JET_LENGTH:
		return "Too far for the flame jet"
	return ""   # a jet is not aimed: smoke and gas don't stop it

## Пустые клетки пола, по которым огнемётчик может пустить струю (для подсветки в UI).
func flammable_cells(shooter: UnitInstance) -> Array:
	var out: Array = []
	if shooter.attack_ability() != MCF.ABILITY_FLAMETHROWER:
		return out
	var reach := MCF.FLAME_JET_LENGTH
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var c := Vector2i(shooter.coord.x + dx, shooter.coord.y + dy)
			if c == shooter.coord:
				continue
			var cell := state.grid.cell(c) if state.grid.in_bounds(c) else null
			if cell == null or (cell.occupant != null and cell.occupant.is_alive()):
				continue
			if can_flame_cell(shooter, c) == "":
				out.append(c)
	return out
