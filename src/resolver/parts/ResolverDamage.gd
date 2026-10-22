@abstract
extends "res://src/resolver/parts/ResolverVision.gd"

## Killing, bodies and cover: corpses as shields and loads, cover effects, trenches, the
## cosmetic effects every action leaves.

## Эффект укрытия цели при выстреле (§3.7): {"hit_penalty": int, "defense_bonus": int}.
## Укрытие засчитывается ТОЛЬКО когда оно стоит прямо между стрелком и целью и цель
## прижата к нему вплотную. Высота 1 м → стрелку −2 к попаданию; высота 2 м — глухая
## стена (обрабатывается в los_blocked). Если стрелок и цель прижаты к укрытию с двух
## сторон (между ними ровно одна клетка), штраф не действует.
# --- Переносимый труп-щит (#6) ---
## Живой юнит подбирает труп с соседней клетки, чтобы носить его как щит.
func _resolve_pickup_corpse(intent: PickUpCorpseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	var err := _validate_actor(unit)
	if err != "":
		return ActionResult.fail(err)
	if unit.remaining_ap <= 0:
		return ActionResult.fail("Unit has no AP left")
	# Щитоносец корпуса не поднимает (item 17): его руки заняты щитом. Труп-щит —
	# защита для остальных бойцов, но не для того, кто и так укрыт своей плитой.
	if _is_shield(unit):
		return ActionResult.fail("A shield-bearer can't carry corpses")
	# Борг трупов не подбирает: несущему трупы в борг нельзя, значит и в борге их не взять.
	if unit.borg_id != -1:
		return ActionResult.fail("A borg can't pick up corpses")
	if unit.carried_corpses >= MCF.CORPSE_CARRY_MAX:
		return ActionResult.fail("Hands full — %s" % ("one body is the limit"
			if MCF.CORPSE_CARRY_MAX == 1 else "%d bodies is the limit" % MCF.CORPSE_CARRY_MAX))
	if Combat.distance(unit.coord, intent.from) > 1:
		return ActionResult.fail("Corpse is out of reach")
	if not has_corpse(intent.from):
		return ActionResult.fail("No corpse there")
	if state.grid.vehicle_at(intent.from) != -1:
		return ActionResult.fail("The body is under a vehicle")
	var cell := state.grid.cell(intent.from)
	# Снимаем один труп: сперва из кучи corpse_count, иначе труп-occupant.
	if cell.corpse_count > 0:
		cell.corpse_count -= 1
		var bodies := CorpseIdentity.stacked(state, intent.from)
		if not bodies.is_empty(): CorpseIdentity.take(bodies[0], unit)
	elif cell.occupant != null and cell.occupant.status == MCF.Status.CORPSE:
		if legacy_corpse_rules: state.remove_unit(cell.occupant.id)
		else: CorpseIdentity.take(cell.occupant, unit)
		cell.occupant = null
	unit.remaining_ap -= 1
	unit.carried_corpses += 1
	return ActionResult.success(["%s picks up a corpse — carrying %d (+%d defense) [AP: %d]" % [
		unit.stats.display_name, unit.carried_corpses, unit.carried_corpses, unit.remaining_ap]])

## Кладёт один несомый труп на свою/соседнюю проходимую клетку (бесплатно).
func _resolve_drop_corpse(intent: DropCorpseIntent) -> ActionResult:
	var unit := state.get_unit(intent.actor_id)
	# Положить труп — действие БЕСПЛАТНОЕ, поэтому проверку ОД пропускаем (#99): она
	# отказывала выдохшемуся бойцу молча, а кнопка и красные клетки по-прежнему
	# предлагались — со стороны это выглядело как «клик ничего не делает».
	var err := _validate_actor(unit, 1)
	if err != "":
		return ActionResult.fail(err)
	if unit.carried_corpses <= 0:
		return ActionResult.fail("No corpse to drop")
	# Под себя тело не кладут (#10): своя клетка занята самим бойцом, и труп под
	# ногами лишь мешал бы — и ему, и разбору кучи.
	if intent.to == unit.coord:
		return ActionResult.fail("Can't drop a body under yourself")
	if Combat.distance(unit.coord, intent.to) > 1:
		return ActionResult.fail("Too far to place")
	var cell := state.grid.cell(intent.to)
	if not can_drop_corpse_at(intent.to):
		return ActionResult.fail("Can't place a corpse there")
	# Больше пяти тел на клетку не влезает (#98): на пятом куча становится стеной, а
	# стена уже отсеяна проверкой is_wall() выше.
	if corpses_at(intent.to) >= MCF.CORPSE_WALL_COUNT:
		return ActionResult.fail("No room for another body here")
	unit.carried_corpses -= 1
	var bodies := CorpseIdentity.carried(state, unit.id)
	if _add_corpse_to_cell(intent.to, bodies[0] if not bodies.is_empty() else null):
		return ActionResult.success(["%s stacks the fifth body — a corpse wall rises at (%d, %d)" % [
			unit.stats.display_name, intent.to.x, intent.to.y]])
	return ActionResult.success(["%s drops a corpse (%d/%d) at (%d, %d)" % [
		unit.stats.display_name, corpses_at(intent.to), MCF.CORPSE_WALL_COUNT,
		intent.to.x, intent.to.y]])

## Положить описание косметического эффекта (#21). Единственная точка, откуда они
## берутся: если res == null (внутренний вызов без отчёта), эффект просто пропадает —
## показывать его всё равно некому.
func _fx(res: ActionResult, ev: Dictionary) -> void:
	if res != null:
		# Номер события — из доски (batch mp-perf): по нему FxDecals засевает разлёт, и у
		# всех пиров он один и тот же, сколько бы событий кто ни пропустил или ни пересчитал.
		ev["seq"] = state.fx_seq
		state.fx_seq += 1
		res.fx.append(ev)

## Какую гусеницу рвёт то, что приходит СНИЗУ — мина, ёж, упёршийся щитоносец.
##
## Борта у такого удара нет: он приходит под днище, а не с какой-то стороны. Берём
## первую целую по фиксированному порядку (левая, потом правая) — порядок важен не сам
## по себе, а тем, что он ОДИН И ТОТ ЖЕ у хоста и клиента. Целых не осталось — вернём
## корпус, и _damage_component отправит удар туда.
func _a_live_track(veh: Vehicle) -> String:
	for comp: String in MCF.TRACK_COMPONENTS:
		if veh.component_alive(comp):
			return comp
	return MCF.COMP_HULL

## Прямой разрыв В БРОНЕВОЙ ПЛИТЕ (веха 14.1): единственное, что её берёт.
##
## Осколки, огонь, кирка шахтёра, гусеница танка и луч марксмана плиту не трогают — это
## и есть вся её суть. Зато заряд, легший ИМЕННО В НЕЁ, сносит целиком, с одного раза:
## взрывчатка кладётся вплотную и работает на пролом, а не на осколки.
##
## Зовётся из тех же мест, что и _pillbox_absorbs, но ведёт себя иначе: ДОТ забирает
## удар себе и ОТМЕНЯЕТ взрыв, а плита просто рушится, и взрыв идёт своим чередом —
## пехоту вокруг он положит.
func _blast_armor_wall(center: Vector2i, res: ActionResult) -> void:
	if not state.grid.in_bounds(center):
		return
	var cell := state.grid.cell(center)
	if cell == null or cell.feature_id != MCF.FEATURE_ARMOR_WALL:
		return
	_wall_chunks(res, center, center, MCF.FEATURE_ARMOR_WALL)
	cell.clear_feature()
	notify_cell_changed(center)
	_fx(res, {"fx": "debris", "at": center, "cells": [center], "blast": true})
	res.log("Armored Wall at (%d, %d) is blown apart." % [center.x, center.y])

## Мелкие предметы клетки c слетают (0.12.1, чистая косметика): взрыв (far — далеко), или
## мебель под ними сдвинули (близко, как гильзы). from — откуда толчок; c — во все стороны.
## Клетка помечает сбитые (GridCell.items_off), летят они в FxDecals и ложатся на пол.
func _knock_items(res: ActionResult, c: Vector2i, from: Vector2i, far := true) -> void:
	if res == null or state.grid.map_items.is_empty() or not state.grid.in_bounds(c):
		return
	var idx := state.grid.items_in(c)
	if idx.is_empty():
		return
	var cell := state.grid.cell(c)
	var bits := cell.items_off
	var gone: Array = []
	for k in mini(idx.size(), 30):
		if bits & (1 << k):
			continue
		bits |= 1 << k
		gone.append((state.grid.map_items[idx[k]] as Array).duplicate())
	if gone.is_empty():
		return
	cell.items_off = bits
	_fx(res, {"fx": "items", "at": c, "from": from, "items": gone, "far": far})

## Шкаф раскрывается и высыпает вещи (0.12.1) — один раз: раскрытый уже пуст.
## burst (0.12.2, item 3): разбитый шкаф разбрасывает содержимое ВО ВСЕ стороны, а
## сдвинутый — себе за спину.
func _spill(res: ActionResult, c: Vector2i, from: Vector2i, fid: String, burst := false) -> void:
	if res == null or not SmallItems.spills(fid) or not state.grid.in_bounds(c):
		return
	var cell := state.grid.cell(c)
	if cell.items_off & GridCell.OPENED:
		return
	cell.items_off |= GridCell.OPENED
	var ev := {"fx": "spill", "at": c, "from": from, "fid": fid}
	if burst:
		ev["burst"] = true
	_fx(res, ev)

## Мебель сдвинули с src на dst: с неё падают предметы (по ходу), то, что лежало на полу в
## dst, отлетает; шкаф может раскрыться и высыпать вещи позади себя.
func _furniture_moved(res: ActionResult, src: Vector2i, dst: Vector2i, fid: String) -> void:
	if res == null:
		return
	_knock_items(res, src, src - (dst - src), false)
	_knock_items(res, dst, src, false)
	# Не каждый рывок вытряхивает полки (0.12.2, item 24): бросок чисто косметический, из
	# номера события и клетки, — кубики партии он не трогает, а у всех пиров один и тот же.
	if SmallItems.spills(fid) and not (state.grid.cell(dst).items_off & GridCell.OPENED) \
			and _cosmetic_chance("spill_drag", src, SmallItems.SPILL_DRAG_CHANCE):
		_fx(res, {"fx": "spill", "at": src, "from": dst, "fid": fid})
		state.grid.cell(dst).items_off |= GridCell.OPENED

## Косметический «бросок» без кубиков партии: одинаков у хоста и гостя (номер события
## входит в подпись доски), но на правила не влияет и поток случайности не сдвигает.
func _cosmetic_chance(tag: String, c: Vector2i, chance: float) -> bool:
	state.fx_seq += 1  # a failed shake still advances the deterministic cosmetic stream
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(tag) * 1000003 + c.x * 7919 + c.y * 104729 + state.fx_seq * 2654435761
	return rng.randf() < chance

## Обломки стены c (0.12.1) — чистая косметика, зовётся ДО того, как стену снесли: вид
## кускам даёт её объект и материал. from — откуда удар (c — во все стороны); toward —
## куски летят К удару (ДОТ откалывается со стороны выстрела). count 0 — сколько выпадет.
func _wall_chunks(res: ActionResult, c: Vector2i, from: Vector2i, fid: String,
		count := 0, toward := false, crushed := false) -> void:
	var ev := {"fx": "chunks", "at": c, "from": from, "fid": fid,
			"look": state.grid.look_at(c.x, c.y), "env": state.env}
	if crushed:
		ev["crushed"] = true   # under a hull: a crunch, not a crash (sound only)
	if count > 0:
		ev["count"] = count
	if toward:
		ev["toward"] = true
	_fx(res, ev)

## Полёт снаряда на экране (0.12.1): ракета противотанкиста, снаряд танка, граната. Взрыв,
## гибель и снесённые стены экран показывает, когда снаряд долетел. Мимо _fx(): зерна полёту
## не нужно, а номер события (fx_seq) входит в подпись доски.
func _fx_shot(res: ActionResult, kind: String, from: Vector2i, to: Vector2i) -> void:
	if res != null and from != to:
		res.fx.append({"fx": "shot", "kind": kind, "from": [from.x, from.y], "to": [to.x, to.y]})

## Пули-трассеры для выстрелов, у которых их не было (дробовик штурмовика, ДПМГ) — тоже
## мимо _fx(), по той же причине.
func _fx_bullets(res: ActionResult, from: Vector2i, to: Vector2i, count: int) -> void:
	if res != null and count > 0:
		res.fx.append({"fx": "tracer", "at": from, "from": [from.x, from.y], "to": [to.x, to.y], "count": count})

## Дорожка «кто в кого» (issue 8: «add visual clues that would tell the player who is
## shooting at who»). Кладётся КАЖДОЙ атакой — пулей, лучом, струёй, зарядом, пушкой,
## ДПМГ, — чтобы в чужой ход было видно не только «где-то стреляли», но и кто по кому.
## Как и всё в fx, на правила не влияет: слой рисует её у себя и через LANE_DUR забывает.
## weapon — what fired, for the muzzle sound only (FxDecals.WEAPON_SOUND); never read by rules.
func _fx_lane(res: ActionResult, from_coord: Vector2i, to_coord: Vector2i,
		owner: int, kind: String = "shot", weapon: String = "") -> void:
	var ev := {"fx": "lane", "from": [from_coord.x, from_coord.y],
		"to": [to_coord.x, to_coord.y], "owner": owner, "kind": kind}
	if weapon != "":
		ev["weapon"] = weapon
	_fx(res, ev)

static func _weapon_of(shooter: UnitInstance) -> String:
	return "borg" if shooter.borg_id != -1 else shooter.stats.id

## Единственная точка смерти в резолвере (#8). Всё, что боец нёс в руках, обязано
## оказаться на доске: погибший с телом на руках оставляет на своей клетке ДВА трупа —
## своё и принесённое. Раньше груз просто исчезал вместе с носильщиком.
##
## Класть некуда только в двух случаях: боец не на карте (сидит в машине, coord =
## OFFBOARD) или на клетке уже собралась стена из пяти тел. Тогда груз пропадает —
## как и раньше, но теперь это редкий край, а не общее правило.
## from_coord — откуда прилетел убивший удар: брызги (#21.4) летят ПРОТИВ него.
## NOWHERE (значение по умолчанию) = источник неизвестен, тогда веер расходится кругом.
## Сгорел в огне или прижжён лучом (playtest-20): тело остаётся обугленным.
func _kill_burnt(u: UnitInstance) -> void:
	if u != null and u.cheat_invulnerable: return
	if u != null and u.is_on_field():
		u.burnt = true
	_kill(u)

func _kill(u: UnitInstance, res: ActionResult = null, from_coord: Vector2i = NOWHERE,
		blast: bool = false, force: bool = false) -> void:
	# is_on_field, not is_alive: a grabbed soldier (HELD) dies like anyone else.
	if u == null or not u.is_on_field():
		return
	if u.cheat_invulnerable and not force: return
	u.captor_id = -1
	# Дрон — машина: ни лужи, ни брызг, ни ошмётков. Сбитый дрон и так рвётся на своей
	# клетке (_drone_explode), и взрыв оставляет щербины на полу — этого довольно.
	# Трупом он на доске не ложится: клетку дрон не занимает (spawn_unit occupy=false),
	# поэтому проход отрисовки трупов его и не берёт — лишней была ровно кровь.
	if state.grid.in_bounds(u.coord) and not u.is_drone:
		# blast — разорван взрывом или раздавлен: кровь кольцом, ошмётки, лужи шире.
		_fx(res, {"fx": "blood", "at": u.coord,
			"from": from_coord if from_coord != NOWHERE else u.coord, "blast": blast})
	var load: int = u.carried_corpses
	u.carried_corpses = 0
	# Пленник погибшего носильщика освобождается сам (batch 12 #1): держать его больше
	# некому. Раньше он оставался HELD с captor_id на труп — не мог действовать и не мог
	# вырваться, потому что _resolve_release ищет живого захватчика.
	var captive := held_unit_of(u)
	u.kill()
	# Единственная точка, где боец погибает, — здесь же ведём счёт павших по сторонам
	# (item 1). Дрон в своде не участвует: это техника станции, не боец.
	if not u.is_drone:
		state.deaths[u.owner] = int(state.deaths.get(u.owner, 0)) + 1
	# Погибший пассажир челнока (batch 13 S10): выбывает из экипажа, но кресло держит
	# его тело, пока снаружи его не вытащат.
	var seat_veh := seated_vehicle_of(u)
	if seat_veh != null:
		seat_veh.occupants.erase(u.id)
	# Погибший оператор борга (batch 13): машина снова размечается корпусом на своей
	# клетке — её можно выбрать, занять (тело вытолкнется) или добить.
	var bveh := borg_of(u)
	if bveh != null:
		bveh.occupants.erase(u.id)
		if state.grid.in_bounds(u.coord):
			bveh.origin = u.coord
			if state.grid.vehicle_at(u.coord) != -1 and state.grid.vehicle_at(u.coord) != bveh.id:
				# Раздавлен чужим корпусом вместе с оператором — от борга ничего не остаётся.
				u.borg_id = -1
				state.remove_vehicle(bveh.id)
			elif not bveh.wrecked and bveh.alive():
				state.grid.set_vehicle_footprint(bveh.id, bveh.footprint())
	if captive != null:
		captive.status = MCF.Status.ALIVE
		captive.captor_id = -1
		if res != null:
			res.log("%s is free — %s is dead." % [captive.stats.display_name, u.stats.display_name])
	if load <= 0:
		return
	var cell := state.grid.cell(u.coord) if state.grid.in_bounds(u.coord) else null
	if cell == null:
		return
	for _i in load:
		# Сам погибший уже лежит на этой клетке как occupant-труп и в corpses_at
		# посчитан, поэтому под стену остаётся ровно то, что до пяти не добрано.
		if corpses_at(u.coord) >= MCF.CORPSE_WALL_COUNT:
			return
		var bodies := CorpseIdentity.carried(state, u.id)
		_add_corpse_to_cell(u.coord, bodies[0] if not bodies.is_empty() else null)

## +1 к защите цели за каждый несомый ею труп (#6).
func _corpse_shield_bonus(target: UnitInstance) -> int:
	return maxi(0, target.carried_corpses)

func cover_effect(shooter: UnitInstance, target: UnitInstance) -> Dictionary:
	return cover_effect_from(shooter.coord, target)

## То же, что cover_effect, но от произвольной клетки-стрелка (для ДПМГ, §3.7).
func cover_effect_from(from_coord: Vector2i, target: UnitInstance) -> Dictionary:
	var none := {"hit_penalty": 0, "defense_bonus": 0}
	var dist := Combat.distance(from_coord, target.coord)
	if dist <= 1:
		return none  # стрельба в упор — исключение (§3.7)
	# Стрелок и цель прижаты к укрытию с двух сторон — оно не мешает никому.
	if dist == 2:
		return none
	# Укрытие засчитывается только вплотную к цели, по направлению на стрелка.
	var shield_cell := target.coord + _step_toward(target.coord, from_coord)
	if not state.grid.in_bounds(shield_cell):
		return none
	var shield := state.grid.cell(shield_cell)
	var h: float = shield.cover_height
	# Мебель — своя таблица (§3.15): в ней есть и 1.5 м (−3). Обычные объекты и рельеф
	# считаются по MCF.COVER_MOD, как и раньше.
	if Furniture.is_furniture(shield.feature_id):
		var fp := Furniture.cover_penalty(h)
		return {"hit_penalty": fp, "defense_bonus": 0} if fp > 0 else none
	if MCF.COVER_MOD.has(h):
		return {"hit_penalty": int(MCF.COVER_MOD[h]), "defense_bonus": 0}
	# Труп, просто лежащий на земле, укрытием не считается (#97): плашмя он ничего не
	# заслоняет. Прикрывает только сложенная из пяти трупов стена — а она уже учтена
	# выше через cover_height своего FEATURE_CORPSE_WALL.
	return none

## Цель на дне окопа (глубина 2 м) недосягаема для стрельбы, если стрелок не вплотную.
##
## flat_beam=true — стреляют не пулей, а ЛАЗЕРОМ (§3.13), и поблажка «вплотную достанем»
## не действует. Пуля летит по дуге и её можно направить вниз: подойдя к краю окопа,
## боец бьёт в яму сверху. Луч же идёт строго по прямой на высоте стрелка и опуститься
## не может — с края окопа он уходит ровно над головой лежащего. Единственный способ
## достать его лучом — самому быть на дне, то есть в окопе: тогда стрелок и цель на
## одном уровне и луч идёт вдоль канавы.
##
## Без этого различия марксман с соседней клетки убивал залёгшего в окопе, хотя весь
## смысл окопа (и подпись «over the trench» в предпросмотре луча) ровно обратный.
##
## Из окопа луч бьёт ТОЛЬКО вдоль своей канавы (#105). Стрелок на дне сам ниже линии
## поверхности: подняться его луч не может ровно так же, как не мог опуститься, — стоящий
## наверху для него недосягаем, а упирается луч в земляную стенку окопа. Поэтому достать
## можно лишь того, кто лежит в ТОЙ ЖЕ канаве, и лишь если она тянется до него без
## разрыва: луч прямой, на повороте окопа он воткнётся в грунт.
func trench_protected(from_coord: Vector2i, target: UnitInstance,
		flat_beam: bool = false) -> bool:
	var tcell := state.grid.cell(target.coord)
	if tcell == null:
		return false  # цель вне поля (в машине и т. п.) — окоп её не касается (#23)
	var target_in_trench := tcell.feature_id == MCF.FEATURE_TRENCH
	if not flat_beam:
		# Пуля летит по дуге: сверху в яму её направить можно, но только вплотную.
		return target_in_trench and Combat.distance(from_coord, target.coord) > 1
	var from_cell := state.grid.cell(from_coord)
	if from_cell == null or from_cell.feature_id != MCF.FEATURE_TRENCH:
		# Стрелок наверху: в яму луч не опустится ни с какой дистанции.
		return target_in_trench
	# Стрелок на дне: наружу луч не выйдет, и по чужой канаве — тоже.
	return not (target_in_trench and _trench_run_clear(from_coord, target.coord))

## Тянется ли окоп сплошняком по прямой от одной клетки до другой (#105). Концы —
## окопы по построению, проверяем то, что между ними: разрыв означает, что луч уходит
## в земляную стенку, а не вдоль канавы. Соседние клетки проходят сами собой.
##
## Обход без выделения массива: линия огня — одно из восьми направлений, поэтому шаг
## задаётся знаками разностей, как в _first_body_on_line.
func _trench_run_clear(from_coord: Vector2i, to_coord: Vector2i) -> bool:
	var dx := to_coord.x - from_coord.x
	var dy := to_coord.y - from_coord.y
	if (dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy)):
		return false  # не створ — вдоль канавы такой луч не пойдёт
	var sx := signi(dx)
	var sy := signi(dy)
	var grid := state.grid
	var x := from_coord.x + sx
	var y := from_coord.y + sy
	while x != to_coord.x or y != to_coord.y:
		var cell := grid.cell(Vector2i(x, y))
		if cell == null or cell.feature_id != MCF.FEATURE_TRENCH:
			return false
		x += sx
		y += sy
	return true

## Бьёт ли этот стрелок плоским лучом, для которого край окопа — не преимущество.
func _fires_flat_beam(shooter: UnitInstance) -> bool:
	return shooter != null and shooter.attack_ability() == MCF.ABILITY_MARKSMAN

## Почему окоп не даёт выстрелить (#105). Причина зависит от того, кто где: обычно цель
## НИЖЕ линии огня, но марксман со дна канавы упирается в ровно обратное — цель выше него
## либо в другой канаве. Одна подпись на оба случая вводила бы в заблуждение ровно в тот
## момент, когда игрок пытается понять, почему выстрел не проходит.
func _trench_block_reason(shooter: UnitInstance) -> String:
	if _fires_flat_beam(shooter):
		var from_cell := state.grid.cell(shooter.coord)
		if from_cell != null and from_cell.feature_id == MCF.FEATURE_TRENCH:
			return "The beam only runs along this trench"
	return "Target is below the trench line"

## Первая соседняя (или своя) клетка с трупом для подбора (#6); (-999,-999) если нет.
## Клетки может не быть вовсе: у сидящего в машине coord = OFFBOARD (#95).
func corpse_pickup_cell(unit: UnitInstance) -> Vector2i:
	var here := state.grid.cell(unit.coord)
	if here == null:
		return Vector2i(-999, -999)
	if here.corpse_count > 0:
		return unit.coord
	for n in state.grid.neighbors(unit.coord):
		if has_corpse(n):
			return n
	return Vector2i(-999, -999)

## Куда юнит может положить несомый труп (#72): своя клетка и соседние восемь, если
## они проходимы. Условия ДОСЛОВНО те же, что проверяет _resolve_drop_corpse, —
## подсветка в UI не должна расходиться с тем, что резолвер реально разрешает.
func can_drop_corpse_at(coord: Vector2i) -> bool:
	var cell := state.grid.cell(coord)
	return cell != null and cell.walkable_terrain() \
			and cell.vehicle_id == -1 and (cell.occupant == null or not cell.occupant.is_on_field()) \
			and corpses_at(coord) < MCF.CORPSE_WALL_COUNT and _drone_at(coord) == null

func corpse_drop_cells(unit: UnitInstance) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if unit == null or unit.carried_corpses <= 0:
		return out
	# Своей клетки в списке нет (#10) — ровно как и в _resolve_drop_corpse.
	var candidates: Array = state.grid.neighbors(unit.coord)
	for c: Vector2i in candidates:
		var cell := state.grid.cell(c)
		if not can_drop_corpse_at(c):
			continue
		if corpses_at(c) >= MCF.CORPSE_WALL_COUNT:
			continue
		out.append(c)
	return out

## На клетке лежит труп. Укрытием он не работает (#97) — это признак «есть что подобрать».
func has_corpse(coord: Vector2i) -> bool:  # публично: нужен ИИ (#40)
	var c := state.grid.cell(coord)
	if c == null:
		return false
	if c.corpse_count > 0:
		return true
	return c.occupant != null and c.occupant.status == MCF.Status.CORPSE

## Сколько тел лежит на клетке (#98). Труп существует в двух видах — павший на месте
## боец (occupant со статусом CORPSE) и безымянное тело, положенное из рук
## (corpse_count), — и правило «пять тел = стена» считает их вместе. Раньше каждая
## ветка складывала кучу по-своему, поэтому одна и та же клетка могла показывать «x2»
## и держать сверх того труп-occupant, а стена собиралась на разном числе тел.
func corpses_at(coord: Vector2i) -> int:  # публично: нужен UI и подсветка
	var c := state.grid.cell(coord)
	if c == null:
		return 0
	var n := maxi(0, c.corpse_count)
	if c.occupant != null and c.occupant.status == MCF.Status.CORPSE:
		n += 1
	return n

## Кладёт одно тело на клетку; пятое складывает из кучи стену (§3.7, #98).
## Возвращает true, если стена образовалась. Вызывать, только убедившись, что
## corpses_at(coord) < CORPSE_WALL_COUNT — переполнить стену нечем.
func _add_corpse_to_cell(coord: Vector2i, body: UnitInstance = null) -> bool:
	var c := state.grid.cell(coord)
	if body != null:
		body.coord = coord
		body.corpse_carrier_id = -1
		body.corpse_stacked = true
	c.corpse_count += 1
	if corpses_at(coord) < MCF.CORPSE_WALL_COUNT:
		return false
	# Тела ушли внутрь стены: и счётчик, и труп-occupant обнуляются, а сам UnitInstance
	# выбывает из игры. Наружу они вернутся только разлётом от взрыва.
	if c.occupant != null and c.occupant.status == MCF.Status.CORPSE:
		state.remove_unit(c.occupant.id)
		c.occupant = null
	c.corpse_count = 0
	for stacked: UnitInstance in CorpseIdentity.stacked(state, coord): state.remove_unit(stacked.id)
	c.set_feature(MCF.FEATURE_CORPSE_WALL)
	return true

## Случайный индекс 0..n-1 из общего источника бросков (#98). Своего генератора в
## резолвере быть не может: в сетевой партии клиент дословно повторяет последовательность
## d6 хоста (§2.3), и любой посторонний RNG развёл бы стороны. Три кубика дают 216
## значений — остаток от деления распределён достаточно ровно для разлёта тел.
func _rand_index(n: int) -> int:
	if n <= 1:
		return 0
	var v := 0
	for _i in 3:
		v = v * 6 + (state.dice.roll_d6() - 1)
	return v % n

## Разлёт тел трупной стены, рухнувшей от взрыва (#98): пять тел выбрасывает наружу,
## и каждое падает на свою свободную клетку поблизости. По одному на клетку — иначе
## стена тут же собралась бы заново там, где её только что снесли.
func _scatter_corpses_random(center: Vector2i, count: int, res: ActionResult) -> void:
	var free: Array[Vector2i] = []
	for dy in range(-MCF.CORPSE_SCATTER_RADIUS, MCF.CORPSE_SCATTER_RADIUS + 1):
		for dx in range(-MCF.CORPSE_SCATTER_RADIUS, MCF.CORPSE_SCATTER_RADIUS + 1):
			var c: Vector2i = center + Vector2i(dx, dy)
			if not state.grid.in_bounds(c):
				continue
			var cell := state.grid.cell(c)
			if cell.is_space or cell.vehicle_id != -1 or cell.has_feature():
				continue
			if not cell.is_empty() or corpses_at(c) > 0:
				continue
			free.append(c)
	var placed := 0
	while placed < count and not free.is_empty():
		var idx := _rand_index(free.size())
		state.grid.cell(free[idx]).corpse_count = 1
		free.remove_at(idx)
		placed += 1
	if res != null:
		res.log("… the corpse wall bursts — %d bodies are thrown clear." % placed)
