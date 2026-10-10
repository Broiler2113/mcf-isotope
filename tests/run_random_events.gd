extends SceneTree
## Случайные события 0.9.4: предупреждение за раунд, обстрел, газ и независимая армия.
##
## Проверяется ровно то, на чём держится система: событие объявляется и падает РАУНДОМ
## ПОЗЖЕ, параметры катаются при объявлении, исход — при падении, всё из общего потока
## кубиков (значит хост и клиент сходятся), выключенные события не тратят ни одного
## кубика, снимок состояния возвращает и очередь, и стоящий газ, а независимая армия
## получает свой слот в очереди, воюет со всеми и на победу не влияет.

const TS = preload("res://tests/TestSupport.gd")

var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

func _initialize() -> void:
	# Мирных на карте по умолчанию больше нет (0.9.4), а они здесь нужны: рейдеры воюют и
	# с ними. Ставим их явно — ровно так же, как это делает TestSupport.build_state().
	GameConfig.civilians_enabled = true
	_registry()
	_owner_ranges()
	_no_dice_when_off()
	_warning_then_landing()
	_barrage()
	_gas()
	_army()
	_snapshot()
	_determinism()
	if fails.is_empty():
		print("random events: warning, barrage, gas, raiders, snapshot and lock step all hold")
	else:
		print("random events: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

# --- Подмостки ---------------------------------------------------------------------------

## Партия с включёнными событиями: интервал 1 и обязательный режим — событие на каждой
## передаче хода, иначе проверять пришлось бы по десятку ходов.
func _match(weights: Dictionary, seed_value: int = 4242) -> Array:
	var state := TS.build_map().build_state(seed_value)
	var resolver := GameActionResolver.new(state)
	resolver.random_events = RandomEvents.new(true, true, 1, weights)
	state.turns.begin_match(state.all_units(), state.dice, state.roster.player_ids())
	return [state, resolver]

## Партия, в которой события ВЫКЛЮЧЕНЫ, но очередь работает: так проверяется ПАДЕНИЕ
## одного события, без того чтобы следующие сыпались на доску посреди проверки.
func _quiet(seed_value: int) -> Array:
	var state := TS.build_map().build_state(seed_value)
	var resolver := GameActionResolver.new(state)
	resolver.random_events = RandomEvents.new(false)
	state.turns.begin_match(state.all_units(), state.dice, state.roster.player_ids())
	return [state, resolver]

## Объявить событие руками — с настоящими, прокатанными кубиками параметрами.
func _announce(state: GameState, resolver: GameActionResolver, id: String) -> Dictionary:
	var params: Dictionary = resolver._roll_event_params(id)
	return resolver.random_events.announce(id, params, state.turns.round_number)

## Крутить передачи хода, пока `done` не скажет «готово» (или не кончится терпение).
func _until(resolver: GameActionResolver, done: Callable, limit: int = 40) -> bool:
	for _i in limit:
		if done.call():
			return true
		resolver.resolve(EndTurnIntent.new(-1))
	return done.call()

## Передать ход, пока номер раунда не станет `want` (но не дольше 40 передач).
func _end_turns(state: GameState, resolver: GameActionResolver, n: int) -> Array:
	var out: Array = []
	for _i in n:
		out.append(resolver.resolve(EndTurnIntent.new(-1)))
	return out

# --- Проверки ---------------------------------------------------------------------------

func _registry() -> void:
	var ids: Array = []
	for pair in RandomEvents.REGISTRY:
		ids.append(pair[0])
	ck(ids == [RandomEvents.MORTAR, RandomEvents.GAS, RandomEvents.ARMY],
			"the registry is artillery, gas, raiders — in that order")
	ck(RandomEvents.event_name(RandomEvents.MORTAR) == "Artillery Barrage",
			"the old mortar id is now called Artillery Barrage")
	# Старые сохранённые веса с «tremor» не ломают выбор: реестр их просто не знает.
	var ev := RandomEvents.new(true, true, 1, {"tremor": 5, RandomEvents.GAS: 1})
	var dice := DiceService.new(7)
	ck(ev.roll_event(dice) == RandomEvents.GAS, "saved weights with tremor still pick a real event")

func _owner_ranges() -> void:
	ck(MCF.is_independent(MCF.INDEPENDENT_BASE), "owner 200 is an independent army")
	ck(not MCF.is_neutral(MCF.INDEPENDENT_BASE), "and it is NOT read as a neutral civilian")
	ck(not CivilianAI.is_npc(UnitInstance.new(1, load("res://src/data/units/sniper.tres"),
			Vector2i.ZERO, MCF.INDEPENDENT_BASE)), "a raider is not a civilian NPC")
	ck(MCF.is_neutral(MCF.NEUTRAL_GROUP_BASE) and MCF.is_neutral(MCF.Owner.NEUTRAL),
			"civilian groups are still neutral")
	ck(MCF.owner_name(MCF.INDEPENDENT_BASE) == "Raiders I", "and it has its own name")
	var r := Roster.new()
	ck(not r.are_allies(MCF.INDEPENDENT_BASE, MCF.Owner.NEUTRAL)
			and not r.are_allies(MCF.INDEPENDENT_BASE, MCF.INDEPENDENT_BASE + 1),
			"raiders are allies to nobody — not civilians, not other raiders")

func _no_dice_when_off() -> void:
	var state := TS.build_map().build_state(11)
	var resolver := GameActionResolver.new(state)
	resolver.random_events = RandomEvents.new(false)
	state.turns.begin_match(state.all_units(), state.dice, state.roster.player_ids())
	var before := state.dice.own_rolls
	for _i in 6:
		resolver.resolve(EndTurnIntent.new(-1))
	var off := state.dice.own_rolls - before
	# Жители на карте есть, и они бросают свои кубики — сравниваем с той же партией, где
	# события включены: разница и есть цена событий.
	var pair := _match({RandomEvents.MORTAR: 1}, 11)
	var state2: GameState = pair[0]
	var res2: GameActionResolver = pair[1]
	var before2 := state2.dice.own_rolls
	for _i in 6:
		res2.resolve(EndTurnIntent.new(-1))
	ck(state2.dice.own_rolls - before2 > off, "events off roll fewer dice than events on")
	ck(resolver.random_events.pending.is_empty(), "and nothing is ever announced")

func _warning_then_landing() -> void:
	var pair := _match({RandomEvents.MORTAR: 1})
	var state: GameState = pair[0]
	var resolver: GameActionResolver = pair[1]
	var round0 := state.turns.round_number
	var res: ActionResult = resolver.resolve(EndTurnIntent.new(-1))
	ck(resolver.random_events.pending.size() == 1, "a handoff announces exactly one event")
	var entry: Dictionary = resolver.random_events.pending[0]
	ck(int(entry["land"]) == int(entry["announced"]) + 1,
			"it lands one round after the warning")
	var said := " ".join(res.log_lines)
	ck(said.contains("Artillery Barrage") and said.contains("landing at the end of round"),
			"the log says what is coming and when")
	ck(not said.contains("destroyed"), "and nothing is destroyed on the turn it is announced")
	# Крутим передачи хода, пока раунд не перевалит за land: событие обязано упасть ровно
	# в конце своего раунда, а не раньше и не позже.
	var landed_round := -1
	for _i in 30:
		var r: ActionResult = resolver.resolve(EndTurnIntent.new(-1))
		if " ".join(r.log_lines).contains("hits zone"):
			landed_round = state.turns.round_number
			break
	ck(landed_round == int(entry["land"]) + 1 or landed_round == int(entry["land"]),
			"the barrage resolves at the end of the round it was promised (round %d, promised %d)"
			% [landed_round, int(entry["land"])])
	ck(round0 == 1, "the match started in round 1")

func _barrage() -> void:
	# Зона всегда на доске, и бьёт примерно половину клеток в ней.
	var hit := 0
	var cells := 0
	for seed_value: int in [3, 17, 91, 404, 777, 1234]:
		var pair := _quiet(seed_value)
		var state: GameState = pair[0]
		var resolver: GameActionResolver = pair[1]
		var p: Dictionary = _announce(state, resolver, RandomEvents.MORTAR)["params"]
		var inside: bool = int(p["x"]) >= 0 and int(p["y"]) >= 0 \
				and int(p["x"]) + int(p["w"]) <= state.grid.width \
				and int(p["y"]) + int(p["h"]) <= state.grid.height
		ck(inside, "the barrage zone lies inside the map (%s)" % [p])
		var before: Array = []
		for y in range(int(p["y"]), int(p["y"]) + int(p["h"])):
			for x in range(int(p["x"]), int(p["x"]) + int(p["w"])):
				before.append(state.grid.cell(Vector2i(x, y)).feature_id)
		# Клетка-свидетель ЗА зоной: её обстрел тронуть не вправе.
		var witness := Vector2i(int(p["x"]) - 1, int(p["y"]) - 1)
		if not state.grid.in_bounds(witness):
			witness = Vector2i(mini(state.grid.width - 1, int(p["x"]) + int(p["w"])),
					mini(state.grid.height - 1, int(p["y"]) + int(p["h"])))
		var witness_was := state.grid.cell(witness).feature_id
		var witness_inside := witness.x >= int(p["x"]) and witness.y >= int(p["y"]) \
				and witness.x < int(p["x"]) + int(p["w"]) and witness.y < int(p["y"]) + int(p["h"])
		_until(resolver, func() -> bool: return resolver.random_events.pending.is_empty())
		var k := 0
		var changed := 0
		for y in range(int(p["y"]), int(p["y"]) + int(p["h"])):
			for x in range(int(p["x"]), int(p["x"]) + int(p["w"])):
				cells += 1
				if state.grid.cell(Vector2i(x, y)).feature_id != before[k]:
					changed += 1
				k += 1
		hit += changed
		ck(witness_inside or state.grid.cell(witness).feature_id == witness_was,
				"nothing outside the zone is touched")
	ck(cells > 0 and hit > 0, "the barrage destroys what stood in its zones (%d cells)" % hit)

func _gas() -> void:
	var pair := _quiet(55)
	var state: GameState = pair[0]
	var resolver: GameActionResolver = pair[1]
	var p: Dictionary = _announce(state, resolver, RandomEvents.GAS)["params"]
	_until(resolver, func() -> bool: return not resolver.random_events.clouds.is_empty())
	ck(resolver.random_events.clouds.size() == 1, "the cloud settles where it was announced")
	var cl: Dictionary = resolver.random_events.clouds[0]
	ck(int(cl["x"]) == int(p["x"]) and int(cl["y"]) == int(p["y"])
			and int(cl["w"]) == int(p["w"]) and int(cl["h"]) == int(p["h"]),
			"and with the announced zone")
	var inside := Vector2i(int(cl["x"]), int(cl["y"]))
	ck(state.grid.cell(inside).gas, "cells inside the cloud carry gas")
	ck(state.grid.cell(inside).blocks_sight(), "gas blocks sight like a wall")
	var left := Vector2i(int(cl["x"]) - 2, int(cl["y"]))
	var right := Vector2i(int(cl["x"]) + int(cl["w"]) + 1, int(cl["y"]))
	if state.grid.in_bounds(left) and state.grid.in_bounds(right):
		ck(resolver.los_blocked(left, right), "a line THROUGH the gas is blocked")
		ck(not resolver.los_blocked(inside, inside + Vector2i(1, 0)),
				"but two neighbours inside it still see each other (endpoints are not tested)")
		# Обзор (туман войны, развед мин) перекрывается газом так же, как стеной —
		# _vision_blocked читал только стену и пропускал газ (0.9.5).
		ck(resolver._vision_blocked(left, right), "gas blocks vision/fog, not only the firing line")
	# Exercise the actual team-visibility cache as a cloud arrives and dissipates.
	var arena := MapData.blank_arena(12, 12)
	arena.set_spawn(Vector2i(2, 5), "light_infantry", MCF.Owner.PLAYER_1)
	arena.set_spawn(Vector2i(8, 5), "light_infantry", MCF.Owner.PLAYER_2)
	var fog_state := arena.build_state(61)
	var fog_resolver := GameActionResolver.new(fog_state)
	fog_resolver.fog_mode = MCF.Fog.STANDARD
	var target := Vector2i(8, 5)
	ck(fog_resolver.team_visible_coords(MCF.Owner.PLAYER_1).has(target),
			"a soldier across an empty arena starts visible")
	fog_resolver.random_events.add_cloud(5, 4, 2, 3, 2)
	fog_resolver._sync_gas()
	ck(not fog_resolver.team_visible_coords(MCF.Owner.PLAYER_1).has(target),
			"a fresh gas cloud hides the soldier behind it")
	fog_resolver.random_events.clouds.clear()
	fog_resolver._sync_gas()
	ck(fog_resolver.team_visible_coords(MCF.Owner.PLAYER_1).has(target),
			"visibility returns when the cloud clears")
	# Газ травит: боец, поставленный в облако, рискует каждым раундом. По шести зёрнам
	# кто-нибудь да задохнётся — иначе облако было бы безобидным.
	var choked := 0
	for seed_value: int in [1, 2, 3, 4, 5, 6]:
		var gp := _quiet(seed_value)
		var gs: GameState = gp[0]
		var gr: GameActionResolver = gp[1]
		gr.random_events.add_cloud(8, 8, 4, 4, 3)
		gr._sync_gas()
		var victim := gs.spawn_unit(load("res://src/data/units/light_infantry.tres"),
				Vector2i(9, 9), MCF.Owner.PLAYER_1)
		for _i in 12:
			gr.resolve(EndTurnIntent.new(-1))
			if not victim.is_alive():
				break
		if not victim.is_alive():
			choked += 1
	ck(choked > 0, "standing in the gas kills (%d of 6 seeds)" % choked)
	# Облако выдыхается ровно за свои раунды.
	var quiet := TS.build_map().build_state(606)
	var qr := GameActionResolver.new(quiet)
	qr.random_events = RandomEvents.new(false)
	quiet.turns.begin_match(quiet.all_units(), quiet.dice, quiet.roster.player_ids())
	qr.random_events.add_cloud(10, 10, 3, 3, 2)
	qr._sync_gas()
	ck(quiet.grid.cell(Vector2i(11, 11)).gas, "a cloud put on the board gasses its cells")
	var rounds := quiet.turns.round_number
	var guard := 0
	while not qr.random_events.clouds.is_empty() and guard < 60:
		guard += 1
		qr.resolve(EndTurnIntent.new(-1))
	ck(qr.random_events.clouds.is_empty(),
			"the cloud is gone when its rounds run out (%d rounds)"
			% [quiet.turns.round_number - rounds])
	ck(not quiet.grid.cell(Vector2i(11, 11)).gas, "and the cells it covered are clear again")
	ck(GridCell.gassed >= 0, "the gas counter never goes negative")

func _army() -> void:
	var pair := _quiet(909)
	var state: GameState = pair[0]
	var resolver: GameActionResolver = pair[1]
	var order_before := state.turns.round_order.size()
	var p: Dictionary = _announce(state, resolver, RandomEvents.ARMY)["params"]
	_until(resolver, func() -> bool: return resolver.random_events.armies > 0)
	ck(resolver.random_events.armies == 1, "the army lands once")
	var slot := MCF.independent_slot(1)
	var mine: Array = []
	for u: UnitInstance in state.all_units():
		if u.owner == slot:
			mine.append(u)
	ck(mine.size() > 0, "raiders are on the board (%d)" % mine.size())
	ck(state.turns.round_order.has(slot), "their slot is in the initiative order")
	var raider_slots := 0
	for slot_id: int in state.turns.round_order:
		if MCF.is_independent(slot_id):
			raider_slots += 1
	ck(raider_slots == 1, "exactly one raider slot is in the order (order grew from %d to %d)"
			% [order_before, state.turns.round_order.size()])
	var edge := int(p.get("edge", 0)) % 4
	var on_edge := true
	for u: UnitInstance in mine:
		var d: int = [u.coord.y, state.grid.width - 1 - u.coord.x, state.grid.height - 1 - u.coord.y,
				u.coord.x][edge]
		if d > maxi(2, int(p.get("len", 4))):
			on_edge = false
	ck(on_edge, "and on the announced edge")
	# Сила — по средней армии игрока.
	var player_cost := 0
	var sides := {}
	for u: UnitInstance in state.all_units():
		if u.is_alive() and MCF.is_player(u.owner):
			player_cost += u.stats.cost
			sides[u.owner] = true
	var mean := player_cost / maxi(1, sides.size())
	var raider_cost := 0
	for u: UnitInstance in mine:
		raider_cost += u.stats.cost
	ck(raider_cost <= mean + 1000, "their strength follows the average player army (%d vs %d)"
			% [raider_cost, mean])
	ck(not state.roster.player_ids().has(slot), "raiders are not a player side at all")
	# Они ходят сами: передача хода проводит их слот внутри себя, наружу активным игроком
	# снова виден игрок.
	var played := false
	for _i in 12:
		var r: ActionResult = resolver.resolve(EndTurnIntent.new(-1))
		played = played or " ".join(r.log_lines).contains(MCF.owner_name(slot))
		ck(MCF.is_player(state.active_player()), "the raider slot never stays active")
		if played:
			break
	ck(played, "and the resolver plays their turn inside the handoff")
	# И они воюют со всеми: их ИИ видит врага и в игроке, и в жителе. Берём чистую доску —
	# на отыгранной партии жители могли и не дожить до высадки.
	var fresh := TS.build_map().build_state(1)
	fresh.spawn_unit(load("res://src/data/units/sniper.tres"), Vector2i(14, 2), slot)
	var brain := AIController.new(slot, AIController.Difficulty.NORMAL)
	var enemies: Array = brain._enemies_of(fresh)
	var saw_player := false
	var saw_civilian := false
	var saw_self := false
	for u: UnitInstance in enemies:
		saw_player = saw_player or MCF.is_player(u.owner)
		saw_civilian = saw_civilian or MCF.is_neutral(u.owner)
		saw_self = saw_self or u.owner == slot
	ck(saw_player and saw_civilian and not saw_self,
			"raiders count players AND civilians as enemies, but not their own")

func _snapshot() -> void:
	var pair := _match({RandomEvents.GAS: 1}, 31337)
	var state: GameState = pair[0]
	var resolver: GameActionResolver = pair[1]
	resolver.resolve(EndTurnIntent.new(-1))
	for _i in 30:
		if not resolver.random_events.clouds.is_empty():
			break
		resolver.resolve(EndTurnIntent.new(-1))
	var snap := resolver.random_events.snapshot()
	# Через JSON — ровно так снимок уезжает в файл сохранения и гостю по сети.
	var round_trip: Dictionary = JSON.parse_string(JSON.stringify(snap))
	var fresh := RandomEvents.new()
	fresh.restore(round_trip)
	ck(fresh.clouds.size() == resolver.random_events.clouds.size()
			and fresh.pending.size() == resolver.random_events.pending.size(),
			"the queue and the clouds survive a JSON round trip")
	if not resolver.random_events.clouds.is_empty():
		ck(int(fresh.clouds[0]["left"]) == int(resolver.random_events.clouds[0]["left"]),
				"with the rounds they have left")
	# Загрузка обязана вернуть газ и НА КЛЕТКИ, иначе сквозь облако было бы видно.
	var rules := StateCodec.encode_rules(resolver)
	for y in state.grid.height:
		for x in state.grid.width:
			state.grid.cell_fast(x, y).gas = false
	StateCodec.apply_rules(resolver, rules)
	var any := false
	for cl: Dictionary in resolver.random_events.clouds:
		any = any or state.grid.cell(Vector2i(int(cl["x"]), int(cl["y"]))).gas
	ck(any or resolver.random_events.clouds.is_empty(),
			"loading a save puts the gas back on the board")

## Лок-степ: та же партия с тем же зерном даёт то же самое — и объявления, и исход.
func _determinism() -> void:
	var a := _run_stream(2024)
	var b := _run_stream(2024)
	var c := _run_stream(2025)
	ck(a == b, "same seed, same events and same outcome")
	ck(a != c, "another seed plays out differently")

func _run_stream(seed_value: int) -> String:
	var pair := _match(RandomEvents.default_weights(), seed_value)
	var state: GameState = pair[0]
	var resolver: GameActionResolver = pair[1]
	var out: PackedStringArray = []
	for _i in 12:
		var res: ActionResult = resolver.resolve(EndTurnIntent.new(-1))
		for line: String in res.log_lines:
			if line.contains("⚠") or line.contains("zone") or line.contains("Raiders") \
					or line.contains("gas"):
				out.append(line)
	out.append(TS.digest(state))
	return "\n".join(out)
