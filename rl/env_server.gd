extends SceneTree

## Сервер среды для обучения (RL v1, spec §1 C1, §5.1, §9.1). Один процесс — один слот
## векторизованной среды: тренер на Python говорит с ним JSON-строками через stdin/stdout.
##
##   → {"cmd":"reset", "map":"/abs/path.json", "seed":N, "side":0|1, "opponent":0|1|2|-1,
##      "round_cap":10, "max_steps":3000, "civilians":false, "random_events":false, "fog":1,
##      "friendly_fire":true, "record":true, "max_candidates":0, "max_actors":0}
##   ← {"ok":true, "obs":{...}, "legal":[...], "acting":side, "reward":0, "done":false}
##   → {"cmd":"step", "action":k}          k — индекс в последнем списке legal
##   ← {"obs":..., "legal":[...], "acting":side, "reward":r, "done":bool, "info":{...}}
##   → {"cmd":"save_replay", "path":"/abs/x.mcfr"}   ← {"ok":true}
##   → {"cmd":"quit"}
##
## Ход противника (opponent >= 0 — AIController этой сложности) разыгрывается ВНУТРИ
## процесса, как в tests/run_headless.gd; opponent == -1 означает «внешняя политика»:
## тогда точки решения отдаются и за вторую сторону (поле acting), а тренер сам решает,
## чьи шаги идут в обучение. Награда всегда со стороны side (обучаемого): разница
## стоимости армий с прошлого ответа (§6.1), штраф за передачу хода, терминал ±1, ничья
## по лимиту раундов — малый минус.
##
## Только запись stdout вида {...} — протокол; всё остальное (баннер Godot, ошибки)
## Python отбрасывает. Резолвер обучаемого ходит БЕЗ всеведения (§3.3): туман — тот же,
## что видит человек.

const Obs = preload("res://rl/ObsEncoder.gd")
## preload, а не class_name: rl/ — не часть игрового автозагруза, и ObsEncoder здесь
## подключён так же. Один и тот же бюджет обязан применять и боевой контроллер.
const IntentBudget = preload("res://rl/IntentBudget.gd")

const R_DRAW := -0.1
const AI_TURN_CAP := 4000

## Штрафы задаются В ДОЛЯХ ТИПОВОГО УБИЙСТВА, а не абсолютным числом.
##
## Награда за убийство нормируется на стоимость армий (§6.1), поэтому она зависит от
## размера армии: убитый пехотинец стоит +0.087 на арене (10 бойцов) и +0.0041 на town'е
## (176). Штрафы же были константами — и на town'е конец хода (-0.01) оказывался ВДВОЕ
## ДОРОЖЕ убийства, а один шаг (-0.0005) съедал восьмую его часть. Политика честно
## выучивала, что стрелять невыгодно: замер «всегда стреляй, если можешь» дал среднюю
## награду -0.00062 за выстрел, то есть стрельба в минус.
##
## Теперь штрафы пересчитываются на каждый эпизод от стоимости ТИПОВОГО юнита стороны,
## так что соотношение «убийство : конец хода : шаг» одинаково на любой карте.
const TURNS_PER_KILL := 10.0   # убийство типового юнита ≈ 10 концов хода
const STEPS_PER_KILL := 400.0  # …и ≈ 400 отдельных действий
var _turn_penalty: float = -0.01
var _step_penalty: float = -0.0005
var _typical: float = 0.1      # стоимость типового юнита / _norm

## --- Явная награда за бой ------------------------------------------------------------
##
## Дифференциал стоимости армий (§6.1) уже платит за убийство, но платит НЕТТО: размен,
## в котором ты убил и потерял, выходит в ноль, и политика не видит, что убивать — хорошо.
## Здесь награда за убийство начисляется ОТДЕЛЬНО и безусловно, ровно в стоимости жертвы
## (нормированной, как и всё остальное), — то есть удачный выстрел всегда в плюс.
const R_KILL := 1.0        # доля стоимости убитого; 1.0 = «сколько стоил, столько и дали»
## Цена СВОЕГО бойца, убитого собственным действием. Раньше за своих отвечал только
## дифференциал, и арифметика выходила чудовищная: взрыв, убивающий одного врага и двух
## своих, давал +0.00412 бонуса, +0.00412 дифференциала за врага, −0.00825 за своих и
## +0.00170 за сам выстрел — ИТОГО В ПЛЮС. Политика честно научилась стрелять по своим.
## Теперь свои считаются тем же весом и сверх дифференциала, так что размен «двое своих
## за одного чужого» однозначно убыточен.
const R_FRIENDLY_FIRE := 1.0
## Бонусы за САМО ДЕЙСТВИЕ — маленькие и с потолком. Награждать действие, а не результат,
## — это ровно та форма, из которой вырос move_held: политика выучит жать кнопку. Поэтому
## они (а) на порядок меньше убийства, (б) считаются не больше SHAPING_PER_TURN раз за ход.
## Выстрел по врагу. Поднят 0.05 → 0.30 после семи оценок подряд с win=0.00 и diff,
## намертво застрявшим на −0.70. Замер показал, почему: при 0.05 гарантированная часть
## выстрела составляла +0.00028 против +0.00181 ожидаемых от убийства, то есть 86%
## ценности выстрела было ЛОТЕРЕЕЙ (убивает лишь каждый пятый). Нормированные адвантажи
## из сигнала, который на 86% шум, учатся за astronomическое число примеров — за 73
## апдейта политика сделала ~700 выстрелов, чего не хватает и близко. Теперь надёжная
## часть ≈ половина, и градиент указывает в одну сторону.
##
## Фармить это нельзя по существу: выстрел требует врага в зоне видимости, стоит ОД и
## ограничен SHAPING_PER_TURN за ход. «Нафармить» тут можно только стрельбу по врагу,
## то есть ровно то, чего мы и добиваемся — в отличие от move_held.
## …и платится ЗА ПУЛЮ, а не за нажатие. Плата за действие научила стрелять по одной:
## одиночный выстрел давал тот же бонус, что и очередь из шести, и оставлял юнита в
## состоянии pending — то есть позволял получить бонус ещё раз тем же боезапасом. Шесть
## одиночных приносили вшестеро больше за те же патроны, и в реплеях это видно как
## «стреляет одной пулей и бросает остальные».
const R_SHOT := 0.30
## Свой боец, сгоревший от РАСПОЛЗАНИЯ огня. Множитель к его стоимости, поверх того, что
## за него уже снял дифференциал, — то есть такая потеря обходится в 1 + R_FIRE_DEATH
## стоимости, против 1 + R_FRIENDLY_FIRE за застреленного своими.
##
## Дороже дружественного огня намеренно. Дружественный огонь — цена размена: очередь
## сквозь своего или взрыв ПТ рядом хотя бы БЬЮТ по врагу. Сгоревший от подползшего
## пламени не покупает вообще ничего, и избежать этого можно с гарантией: пламя ползёт
## только по четырём ортогональным соседям, в начале хода той стороны, которая его
## устроила, а живой не-огнеупорный боец рядом с огнём занимается БЕЗ БРОСКА (advance_fire) —
## то есть «стоять вплотную к огню» это не риск, это назначенная смерть через ход.
const R_FIRE_DEATH := 2.0
const R_VEHICLE := 0.30    # осмысленное действие машиной (ход, пушка, таран, посадка).
                           # Было 0.05 — вшестеро дешевле выстрела, и в записях боёв техника
                           # простаивала всю партию. Причин было две, и обе сняты: намерения
                           # машин теперь ВСЕГДА в списке кандидатов (IntentBudget.actor_subset),
                           # а сама работа машиной стоит столько же, сколько нажатие на спуск.
                           # Потолок SHAPING_PER_TURN остаётся: это по-прежнему награда за
                           # действие, а не за результат, и нафармить её ходами танка нельзя.
## Сколько действий за ход вообще могут получить бонус за ДЕЙСТВИЕ (выстрел, работа
## машиной). Было 20, и это оказалось больше, чем стоит сам результат:
##
##   максимум подкрепления за ход = 20 × R_SHOT(0.30) × _typical = 6.0 × _typical
##   одно убийство типового юнита  =      R_KILL(1.0) × _typical = 1.0 × _typical
##
## То есть ход, за который сторона выпустила двадцать очередей и не попала ни разу, стоил
## ШЕСТЬ убитых врагов. Подкрепление задумывалось как подсказка «стрелять вообще бывает
## полезно» — при shoot 0.3% на town-3 она была нужна, — но с таким потолком оно
## перевешивает исход, и политика учится жать на спуск, а не выигрывать перестрелки.
##
## Это видно во ВСЕХ четырёх прогонах одинаково: оценка растёт, пока политика учится
## сближаться, и ломается ровно тогда, когда shoot переваливает ~10%, причём партии при
## этом КОРОЧЕ, а не длиннее — армию разбирают. town-6: shoot 4.6 → 6.0 → 8.0 → 9.5 →
## 14.5%, оценки -0.752 → -0.526 → -0.485 → -0.614, раундов 10.5 → 7.25 → 9.5 → 6.5,
## разгромов 4/4. town-5 то же самое с пиком на 50-м апдейте.
##
## 6 вместо 20 даёт максимум 1.8 × _typical за ход: подсказка остаётся (стрелять всё ещё
## выгоднее, чем не стрелять), но дешевле двух убийств, а не дороже шести. Свою задачу
## она уже выполнила — shoot держится на 10-15% во всех прогонах без неё.
const SHAPING_PER_TURN := 6
## Множитель за НЕСКОЛЬКО убийств ОДНИМ действием: лазер марксмана насквозь, взрыв
## противотанкового заряда, подрыв дрона, шестиклеточный огнемёт. Два трупа с одного
## действия стоят 1.5 суммы, три — 2.0, четыре — 2.5. Считается от суммы стоимостей, так
## что выгодно накрывать дорогих, а не просто многих. Потолок нужен, чтобы редкий
## шестикратный размен не перевесил исход партии целиком.
const R_COMBO := 0.5
const COMBO_MAX := 3.0
## Сколько БЕСПЛАТНЫХ (не потративших ОД) действий разрешено одному юниту за ход.
## Ограничение структурное, а не через награду: перечислитель обязан предлагать такие
## намерения (перекладка пленника и тела — законные ходы), но не бесконечно же.
const FREE_ACTIONS_PER_UNIT := 6
## …и сколько их разрешено ВСЕЙ стороне за ход. Потолка на юнита мало: на town'е 176
## бойцов, то есть 176 × 6 ≈ 1000 бесплатных действий за ход — экономия на порядок, а
## затык остаётся. Проверено: жадная «эксплойтная» политика всё равно упиралась в
## max_steps. Общий бюджет режет именно это; для честной игры он щедр — перекладывают
## пленников и тела единицы юнитов, а не рота.
const FREE_ACTIONS_PER_TURN := 48
## …и на СКОЛЬКИХ бойцах этот бюджет мерили. Оба потолка ниже — штука на ход, а не на
## юнита, и при вчетверо меньшей армии за ход происходит вчетверо меньше решений, так что
## тот же абсолютный бюджет становится вчетверо большей ДОЛЕЙ всего, что делает политика.
## town-5 поймал это ровно так: перетаскивание (бесплатное, как и перекладка пленника, и
## комбинаторно обильное — каждый мешок, ёж и куча земли × каждая соседняя клетка) выросло
## с 6% действий до 35% и стало самым частым действием вообще, обогнав move; оценки при
## этом поехали вниз три раза подряд (-0.239 → -0.293 → -0.407, разгромов 2/4 → 3/4 → 4/4,
## раундов 11.0 → 9.75 → 8.5). 48 из ~150 решений за ход — это и есть та самая треть.
## Поэтому оба потолка теперь масштабируются от размера армии, а не стоят числом.
const BUDGET_BASELINE_UNITS := 176
## Сколько клеток за ход сторона может перекопать (dig). Без потолка политика закапывает
## пол-карты: dig шёл вторым по частоте после move — 14.5% всех действий, — а получившиеся
## траншеи потом мешают её же манёврам. Копать по-прежнему можно, но как приём, а не как
## образ жизни. Потолок структурный, а не через награду: штраф за копание политика
## обобщила бы на «не трогать местность вообще», а окоп под огнём — правильный ход.
const DIGS_PER_TURN := 8

## Оба потолка, пересчитанные под РЕАЛЬНЫЙ размер армии этого эпизода (см.
## BUDGET_BASELINE_UNITS). Считаются один раз на reset'е, как _turn_penalty и _typical.
var _free_turn_cap: int = FREE_ACTIONS_PER_TURN
var _digs_turn_cap: int = DIGS_PER_TURN

var state: GameState = null
var resolver: GameActionResolver = null
var side: int = MCF.Owner.PLAYER_1
var opponent: int = AIController.Difficulty.NORMAL
var round_cap: int = 10
## Потолок шагов эпизода (обеих сторон); задаётся в reset как "max_steps", иначе 300 на раунд.
var max_steps: int = 3000
## Потолок КАНДИДАТОВ на точку решения (0 — без потолка). Ротные карты вроде town дают
## 8000+ законных намерений за ход (из них ~5000 — «шагнуть в клетку»), и цена у этого
## тройная: перечислитель, JSON и тензор кандидатов в буфере роллаута. Потолок режет
## список ЗДЕСЬ, до describe и до провода, — см. IntentBudget.cap().
var max_candidates: int = 0
## Потолок АКТЁРОВ, рассматриваемых за шаг (0 — все). Бьёт по самой дорогой части шага —
## перечислителю; см. IntentBudget.actor_subset().
var max_actors: int = 0
var _cap_rng := RandomNumberGenerator.new()
var brains: Dictionary = {}
var recorder: ReplayRecorder = null
var _legal: Array = []
var _pending: Intent = null
var _norm: float = 1.0
var _last_diff: float = 0.0
var _done: bool = true
var _illegal: int = 0
var _steps: int = 0
var _result: String = ""
## Как закончилась партия: "rout" (одна из армий уничтожена), "count" (перевес по составу
## на лимите раундов) или "" (ничья/страховка). Едет в info, чтобы разгром и победу по
## очкам можно было отличить в логе оценок.
var _by: String = ""
## Бесплатные действия за текущий ход: ключ актёра → счётчик, и "<ключ>|<вид>" → true.
## Обнуляются на смене хода (_turn_token). См. FREE_ACTIONS_PER_UNIT и _drop_looping().
var _free_count: Dictionary = {}
var _free_kinds: Dictionary = {}
var _free_turn: String = ""
var _free_total: int = 0
## Сколько раз за текущий ход уже начислялся бонус за САМО действие (выстрел/машина).
## Обнуляется там же, где счётчики бесплатных действий, — на смене хода.
var _shaping_used: int = 0
## Сколько клеток уже перекопано за этот ход; см. DIGS_PER_TURN.
var _digs_used: int = 0
## Штраф за своих, сгоревших за ЭТОТ шаг среды, и счётчик за эпизод.
##
## Копится отдельно, потому что огонь ползёт не в нашем действии. Пламя расходится в начале
## хода той стороны, которая его зажгла, то есть внутри end_turn'а — а чужие ходы среда
## доигрывает сама, в _advance(), где никакой награды уже не считают. Складывать штраф
## прямо в _combat_reward значило бы ловить лишь ту редкую долю пожаров, что случилась
## ровно в нашем собственном end_turn'е.
var _fire_debt: float = 0.0
var _fire_losses: int = 0

func _initialize() -> void:
	while true:
		var line := OS.read_string_from_stdin(1 << 22)
		if line == "":
			break
		line = line.strip_edges()
		if not line.begins_with("{"):
			continue
		var req: Variant = JSON.parse_string(line)
		if typeof(req) != TYPE_DICTIONARY:
			print(JSON.stringify({"ok": false, "error": "bad json"}))
			continue
		var cmd: String = str(req.get("cmd", ""))
		var resp: Dictionary
		match cmd:
			"reset": resp = _reset(req)
			"step": resp = _step(req)
			"save_replay": resp = _save_replay(str(req.get("path", "")))
			"ping": resp = {"ok": true}
			"quit":
				print(JSON.stringify({"ok": true}))
				break
			_: resp = {"ok": false, "error": "unknown cmd %s" % cmd}
		print(JSON.stringify(resp))
	quit(0)

# --- Эпизод -------------------------------------------------------------------------

func _reset(req: Dictionary) -> Dictionary:
	var path := str(req.get("map", ""))
	var m := MapData.load_from(path)
	if m == null:
		return {"ok": false, "error": "map not found: %s" % path}
	GameConfig.civilians_enabled = bool(req.get("civilians", false))
	var seed_value := int(req.get("seed", 1))
	state = m.build_state(seed_value)
	for pid: int in state.roster.player_ids():
		var s := state.roster.slot(pid)
		if s != null:
			s.kind = Roster.SlotKind.AI   # без стека Undo
	side = int(req.get("side", MCF.Owner.PLAYER_1))
	opponent = int(req.get("opponent", AIController.Difficulty.NORMAL))
	round_cap = int(req.get("round_cap", 10))
	max_steps = int(req.get("max_steps", round_cap * 300))
	max_candidates = int(req.get("max_candidates", 0))
	max_actors = int(req.get("max_actors", 0))
	_cap_rng.seed = seed_value
	resolver = GameActionResolver.new(state)
	resolver.fog_mode = int(req.get("fog", MCF.Fog.STANDARD))
	resolver.friendly_fire_enabled = bool(req.get("friendly_fire", true))
	if bool(req.get("random_events", false)):
		resolver.random_events = RandomEvents.new(true)
	resolver.update_airlocks()
	recorder = null
	if bool(req.get("record", false)):
		recorder = ReplayRecorder.new()
		recorder.begin(state, resolver, {"rl": true, "seed": seed_value, "map": path,
				"side": side, "opponent": opponent})
		resolver.replay_recorder = recorder
		recorder.capture_opening()
	else:
		resolver.play_civilian_slots()
	brains.clear()
	if opponent >= 0:
		for pid: int in state.roster.player_ids():
			if pid != side:
				var ai := AIController.new(pid, opponent)
				ai.intent_ready.connect(_on_intent)
				brains[pid] = ai
	var total := 0.0
	for pid: int in state.roster.player_ids():
		total += Obs.army_value(state, pid)
	_norm = maxf(1.0, total / 2.0)
	# Штрафы — в долях типового убийства (см. TURNS_PER_KILL): иначе на ротной карте
	# конец хода стоит дороже убитого врага, и стрелять становится невыгодно.
	_typical = _typical_unit_value() / _norm
	_turn_penalty = -_typical / TURNS_PER_KILL
	_step_penalty = -_typical / STEPS_PER_KILL
	# Потолки на ход — в ДОЛЮ от армии, на которой их мерили (BUDGET_BASELINE_UNITS), а не
	# абсолютным числом. Минимумы не нулевые: и перетаскивание, и окоп обязаны остаться
	# возможными на любой карте — вопрос лишь в том, чтобы они не были основным занятием.
	var army := maxi(1, _living_count(side))
	_free_turn_cap = maxi(8, int(round(float(FREE_ACTIONS_PER_TURN)
			* float(army) / float(BUDGET_BASELINE_UNITS))))
	_digs_turn_cap = maxi(2, int(round(float(DIGS_PER_TURN)
			* float(army) / float(BUDGET_BASELINE_UNITS))))
	_last_diff = _value_diff()
	_done = false
	_illegal = 0
	_steps = 0
	_result = ""
	_by = ""
	_free_count = {}
	_free_kinds = {}
	_free_turn = ""
	_free_total = 0
	_shaping_used = 0
	_digs_used = 0
	_fire_debt = 0.0
	_fire_losses = 0
	_crew_vehicles()
	_advance()
	return _response(0.0, true)

## Посадить экипажи в машины ПЕРЕД началом партии.
##
## MapData.build_state ставит технику пустой: crew=0/3, ap=0, и ни одного veh_* намерения
## в списке на открытии. То есть политика не «не пользуется танком» — она физически не
## может, пока кто-то не сядет за рычаги, а это цепочка «подойти → сесть → поехать» без
## единой промежуточной награды. В реальной партии игрок покупает технику С экипажем,
## так что пустая машина здесь была артефактом генератора карты, а не правилом игры.
##
## Сажаем соседей-пехотинцев обеих сторон (симметрия важнее удобства) до полной
## вместимости, через обычный резолвер — никаких особых путей, тот же VehicleBoardIntent,
## который потом доступен политике.
func _crew_vehicles() -> void:
	# Посадка идёт через обычный резолвер, а он требует, чтобы актёр принадлежал АКТИВНОМУ
	# игроку. На старте активна лишь одна сторона, поэтому вторая оставалась с пустой
	# техникой — асимметрия, которая тихо подарила бы обучаемому танк в половине эпизодов
	# и отняла в другой. Поэтому на время расстановки активный игрок подменяется, а
	# исходный индекс возвращается сразу после.
	var saved := state.turns.active_index
	for veh: Vehicle in state.all_vehicles():
		if not veh.alive():
			continue
		var owner_idx := state.turns.round_order.find(veh.owner)
		if owner_idx < 0:
			continue
		state.turns.active_index = owner_idx
		var guard := 0
		while veh.living_crew_count() < veh.capacity() and guard < 8:
			guard += 1
			var cands: Array = resolver.vehicle_board_candidates(veh)
			if cands.is_empty():
				break
			var res := resolver.resolve(VehicleBoardIntent.new(int(cands[0]), veh.id))
			if not res.ok:
				break
	state.turns.active_index = saved


func _step(req: Dictionary) -> Dictionary:
	if _done or state == null:
		return {"ok": false, "error": "episode is over — reset first"}
	var k := int(req.get("action", -1))
	if k < 0 or k >= _legal.size():
		return {"ok": false, "error": "action %d out of range (%d legal)" % [k, _legal.size()]}
	var intent: Intent = _legal[k]
	var acting := state.active_player()
	var reward := 0.0
	# ОД актёра ДО действия — по ним и только по ним решается, было ли действие
	# бесплатным. Список «бесплатных видов» хардкодить нельзя: он меняется с правилами,
	# а вот «ОД не убавилось» верно всегда.
	var key := _actor_key(intent)
	var ap_before := _actor_ap(intent)
	var hulls_before := _vehicle_hulls()
	_fire_debt = 0.0
	var res := resolver.resolve(intent)
	_note_fire(res)
	_steps += 1
	if acting == side:
		reward += _step_penalty
		if res.ok:
			reward += _combat_reward(intent, res, hulls_before)
			if _kind_of(intent) == "dig":
				_digs_used += 1
	if not res.ok:
		# Не должно случаться (перечислитель точен) — но если случилось, шаг не теряется:
		# считаем, штрафуем и, чтобы не зациклиться, отдаём ход после серии отказов.
		_illegal += 1
		if acting == side:
			reward += _turn_penalty
		if _illegal % 8 == 0:
			_note_fire(resolver.resolve(EndTurnIntent.new()))
	elif intent is EndTurnIntent:
		if acting == side:
			reward += _turn_penalty
	elif key != "" and _actor_ap(intent) >= ap_before:
		# Действие прошло, а ОД не убавилось — оно бесплатное. Считаем его за этим
		# актёром и запоминаем ВИД: после потолка именно этот вид у него и отключится.
		_free_count[key] = int(_free_count.get(key, 0)) + 1
		_free_kinds["%s|%s" % [key, _kind_of(intent)]] = true
		if acting == state.active_player():
			_free_total += 1          # тот же ход продолжается — бюджет стороны тикает
	_advance()
	# Костры чужих ходов, доигранных только что: они горели наши, а не чужие.
	reward += _fire_debt
	return _response(reward, false)


## Записать сгоревших СВОИХ из результата и назначить за них штраф.
##
## Только своя сторона: за сгоревшего врага дифференциал и так платит, а отдельная премия
## сверху сделала бы поджог выгоднее прицельного огня — ровно та ловушка, в которую на
## этом проекте уже трижды попадали подкрепления за действие.
func _note_fire(res: ActionResult) -> void:
	if res == null or res.fire_deaths.is_empty():
		return
	for id: int in res.fire_deaths:
		var u := state.get_unit(id)
		if u == null or u.owner != side or u.is_drone:
			continue
		_fire_losses += 1
		_fire_debt -= R_FIRE_DEATH * float(u.stats.cost) / _norm

## Ключ актёра намерения: id юнита или "v<id>" для машины (пространства id пересекаются).
func _actor_key(intent: Intent) -> String:
	if intent is EndTurnIntent:
		return ""
	if state.get_unit(intent.actor_id) != null:
		return str(intent.actor_id)
	if state.get_vehicle(intent.actor_id) != null:
		return "v%d" % intent.actor_id
	return ""

## Текущие ОД актёра намерения (−1, если актёра нет).
func _actor_ap(intent: Intent) -> int:
	var u := state.get_unit(intent.actor_id)
	if u != null:
		return u.remaining_ap
	var veh := state.get_vehicle(intent.actor_id)
	return resolver.vehicle_ap(veh) if veh != null else -1

## Скорострельность актёра — знаменатель для платы за пулю.
func _actor_rof(intent: Intent) -> int:
	var u := state.get_unit(intent.actor_id)
	return maxi(1, u.rate_of_fire()) if u != null else 1


func _kind_of(intent: Intent) -> String:
	return str(IntentCodec.encode(intent).get("t", ""))

## Метка текущего хода: сменилась — счётчики бесплатных действий обнуляются.
func _turn_token() -> String:
	return "%d:%d:%d" % [state.active_player(), state.turns.round_number,
			state.turns.active_index]

## Разыграть чужие ходы до следующей точки решения (или конца партии).
func _advance() -> void:
	var guard := 0
	while not _check_over():
		var act := state.active_player()
		if act == side or opponent < 0:
			return
		var ai: AIController = brains.get(act, null)
		if ai == null:
			_note_fire(resolver.resolve(EndTurnIntent.new()))
			continue
		_pending = null
		ai.begin_turn(state)
		var intent: Intent = _pending if _pending != null else EndTurnIntent.new()
		var res := resolver.resolve(intent)
		_note_fire(res)
		if not res.ok:
			ai.notify_intent_denied(state)
		guard += 1
		if guard > AI_TURN_CAP:
			_note_fire(resolver.resolve(EndTurnIntent.new()))
			guard = 0

func _on_intent(intent: Intent) -> void:
	_pending = intent

func _side_has_army(pid: int) -> bool:
	for u in state.all_units():
		if u.owner == pid and u.is_alive() and not u.is_drone:
			return true
	return false

## Исход партии: своя армия мертва — поражение, чужая — победа, обе — ничья.
##
## На лимите раундов партия НЕ ничья по умолчанию, а считается по головам: у кого на конец
## последнего раунда живых бойцов больше, тот и выиграл. Требование «уничтожить все 176
## вражеских юнитов за 13 раундов» было победой только на бумаге — за всю ночь обучения
## win не уходил с 0.00 ни разу, и уйти не мог. Перевес по составу достижим и при этом
## по-прежнему честен: политика сейчас заканчивает матч, потеряв БОЛЬШЕ врага
## (value_diff ≈ −0.5), так что для победы ей всё равно нужно научиться разменивать
## лучше противника, а не просто досидеть до конца.
##
## Ничья остаётся только при РАВНОМ счёте. draw_steps (упёрлись в max_steps) считается
## ничьёй всегда: это признак сломанного эпизода, а не результат партии.
func _check_over() -> bool:
	if _done:
		return true
	var mine := _side_has_army(side)
	var theirs := false
	for pid: int in state.roster.player_ids():
		if pid != side and Obs.rel_owner(resolver, side, pid) == 1 and _side_has_army(pid):
			theirs = true
	if not mine and not theirs:
		_result = "draw"
	elif not mine:
		_result = "loss"
		_by = "rout"
	elif not theirs:
		_result = "win"
		_by = "rout"
	elif state.turns.round_number > round_cap:
		var mine_n := _living_count(side)
		var theirs_n := 0
		for pid: int in state.roster.player_ids():
			if pid != side and Obs.rel_owner(resolver, side, pid) == 1:
				theirs_n += _living_count(pid)
		# Строки результата НЕ новые нарочно: "win"/"loss" читают и награда в _response,
		# и счётчики winrate в train.py, и панель. Как именно победили — в info.by.
		_by = "count"
		if mine_n > theirs_n:
			_result = "win"
		elif mine_n < theirs_n:
			_result = "loss"
		else:
			_result = "draw_cap"
	elif _steps >= max_steps:
		# Страховка от вечного хода: политика (особенно жадная на оценке) может без конца
		# выбирать бесплатное намерение и никогда не завершить ход — раундовый лимит тогда
		# не наступает. Ничья по шагам; на панели видна как drawrate.
		_result = "draw_steps"
	else:
		return false
	_done = true
	return true

## Сколько живых бойцов у стороны. Дроны не в счёт (расходники, не состав); техника тоже —
## «юнитов больше» в постановке владельца означает именно бойцов, а приравнивать танк к
## пехотинцу было бы произвольным весом в ту или другую сторону.
func _living_count(pid: int) -> int:
	var n := 0
	for u in state.all_units():
		if u.owner == pid and u.is_alive() and not u.is_drone:
			n += 1
	return n


## Прочность корпусов всех машин — снимок ДО действия, чтобы заметить уничтоженную.
func _vehicle_hulls() -> Dictionary:
	var out := {}
	for veh: Vehicle in state.all_vehicles():
		out[veh.id] = 1 if veh.alive() else 0
	return out


## Явная награда за бой: убийства по стоимости плюс маленькие бонусы за выстрел и за
## работу машиной. Считается ТОЛЬКО за ход обучаемого и только за успешное действие.
##
## Убийства не ограничены — убивать врага хорошо ровно столько раз, сколько получится.
## Бонусы за само действие ограничены SHAPING_PER_TURN за ход: награда за нажатие кнопки,
## а не за результат, — это та же ловушка, что и бесплатная перекладка пленника.
func _combat_reward(intent: Intent, res: ActionResult, hulls_before: Dictionary) -> float:
	var gained := 0.0
	# 1. Убитые юниты — по стоимости жертвы. Свои потери сюда не идут: за них уже
	#    наказывает дифференциал, и штрафовать дважды значит учить не рисковать вовсе.
	var killed := 0
	var worth := 0.0
	var own_lost := 0.0
	for id: int in res.deaths:
		var victim := state.get_unit(id)
		if victim == null:
			continue
		var rel := Obs.rel_owner(resolver, side, victim.owner)
		if rel == 1:
			worth += float(victim.stats.cost)
			killed += 1
		elif rel == 0:
			# Свой, убитый СВОИМ ЖЕ действием (взрыв ПТ, огнемёт, подрыв дрона, очередь
			# сквозь своих). Дифференциал это тоже заметит — здесь штраф ВТОРОЙ, чтобы
			# он был симметричен бонусу за убийство врага.
			own_lost += float(victim.stats.cost)
	# 2. Уничтоженная техника — тоже по цене, и в тот же зачёт комбо.
	for vid: Variant in hulls_before:
		if int(hulls_before[vid]) == 0:
			continue
		var veh := state.get_vehicle(int(vid))
		if veh != null and not veh.alive() and Obs.rel_owner(resolver, side, veh.owner) == 1:
			worth += float(VehicleDB.buy_cost(veh.type_id))
			killed += 1
	# 3. Комбо: несколько трупов ОДНИМ действием стоят дороже суммы. Именно за это и
	#    берут марксмана, противотанкиста, дрон-подрывника и огнемётчика.
	if killed > 0:
		var combo := minf(1.0 + R_COMBO * float(killed - 1), COMBO_MAX)
		gained += R_KILL * worth / _norm * combo
	if own_lost > 0.0:
		gained -= R_FRIENDLY_FIRE * own_lost / _norm
	# 4. Бонусы за действие — под потолком.
	if _shaping_used < SHAPING_PER_TURN:
		var kind := _kind_of(intent)
		var bonus := 0.0
		if kind == "shoot" or kind == "rsp" or kind == "veh_cannon":
			# Пропорционально ВЫПУЩЕННЫМ пулям, иначе выгодно дробить очередь.
			var fired := 1
			if intent is ShootIntent:
				fired = intent.shots if intent.shots > 0 else maxi(1, _actor_rof(intent))
			bonus = R_SHOT * float(fired) / maxf(1.0, float(_actor_rof(intent)))
		elif kind == "veh_move" or kind == "veh_turn" or kind == "veh_melee":
			# ТОЛЬКО работа машиной как машиной: проехать, довернуть корпус, таранить.
			# (Выстрел из пушки платится выше, по стволам, вместе с обычной стрельбой.)
			#
			# Раньше здесь стоял begins_with("veh_"), то есть бонус получала ЛЮБАЯ возня с
			# техникой — включая посадку и высадку. При R_VEHICLE 0.05 это ничего не стоило,
			# при 0.30 политика нашла петлю за два часа. town-4, доля действий:
			#
			#   апдейт      2      39      64      91     119
			#   veh_out   1.82%   1.82%   2.54%   4.75%   3.71%
			#   veh_board 0.07%   0.65%   1.37%   3.65%   2.73%
			#   veh_move  2.80%   0.20%   0.39%   0.00%   0.26%
			#
			# Вылезти-залезть-вылезти доросло до 8.4% ВСЕХ действий, а езда упала до нуля:
			# бонус платился дважды за петлю, которая не меняет на поле ничего. Это та же
			# ловушка, что и бесплатная перекладка пленника и плата за каждое нажатие спуска.
			# Посадка не нуждается в поощрении вовсе: _crew_vehicles сажает экипажи на
			# reset'е. Починка тоже не здесь — восстановленный корпус уже виден
			# дифференциалу через Obs.army_value.
			bonus = R_VEHICLE
		if bonus > 0.0:
			_shaping_used += 1
			gained += bonus * _typical
	return gained


## Стоимость ТИПОВОГО живого юнита обучаемой стороны на старте эпизода. Медиана, а не
## среднее: одна машина ценой 500 не должна перекашивать масштаб роты из 176 пехотинцев.
func _typical_unit_value() -> float:
	var costs: Array[float] = []
	for u in state.all_units():
		if u.owner == side and u.is_alive() and not u.is_drone:
			costs.append(float(u.stats.cost))
	if costs.is_empty():
		return 1.0
	costs.sort()
	return maxf(1.0, costs[costs.size() / 2])


func _value_diff() -> float:
	var mine := Obs.army_value(state, side)
	var theirs := 0.0
	for pid: int in state.roster.player_ids():
		if Obs.rel_owner(resolver, side, pid) == 1:
			theirs += Obs.army_value(state, pid)
	return mine - theirs

func _response(reward: float, is_reset: bool) -> Dictionary:
	var diff := _value_diff()
	reward += (diff - _last_diff) / _norm
	_last_diff = diff
	var resp := {"ok": true, "reward": reward, "done": _done, "acting": state.active_player(),
			"info": {"round": state.turns.round_number, "steps": _steps, "illegal": _illegal,
				"value_diff": diff / _norm, "fire_losses": _fire_losses}}
	if _done:
		match _result:
			"win": resp["reward"] = float(resp["reward"]) + 1.0
			"loss": resp["reward"] = float(resp["reward"]) - 1.0
			_: resp["reward"] = float(resp["reward"]) + R_DRAW
		resp["info"]["result"] = _result
		resp["info"]["by"] = _by
		_legal = []
		resp["legal"] = []
		resp["obs"] = Obs.encode(resolver, side, round_cap)
		return resp
	var acting := state.active_player()
	var t0 := Time.get_ticks_usec()
	_legal = IntentBudget.cap(_drop_looping(resolver.legal_intents(
			acting, IntentBudget.actor_subset(resolver, acting, max_actors, _cap_rng))),
			max_candidates, _cap_rng)
	var t1 := Time.get_ticks_usec()
	var desc: Array = []
	for intent: Intent in _legal:
		desc.append(Obs.describe(state, intent))
	resp["legal"] = desc
	resp["obs"] = Obs.encode(resolver, acting, round_cap)
	# Во что обошёлся ЭТОТ ответ. Перечислитель — самая дорогая часть шага на больших
	# картах (town без max_actors: ~180 мс из ~190), и когда обучение «висит», первым
	# делом хочется видеть именно это число, а не гадать. Тренер пишет его в TB.
	resp["info"]["legal_ms"] = (t1 - t0) / 1000.0
	resp["info"]["obs_ms"] = (Time.get_ticks_usec() - t1) / 1000.0
	return resp

## Убрать намерения, которыми юнит уже зациклился в этом ходу.
##
## Первый прогон town'а: 75% действий политики — move_held (бесплатная перекладка
## пленника), end — 0.4%, две доигранные партии за 13 апдейтов. Конец хода стоит
## конец хода, бесплатное действие — ноль, так что «перекладывать вечно» строго
## выгоднее; PPO нашёл это за десяток апдейтов. Штраф за шаг убирает выгоду, а этот
## фильтр убирает саму возможность.
##
## Режется ТОЧЕЧНО: только те виды, которые ЭТОТ юнит уже сделал бесплатно
## FREE_ACTIONS_PER_UNIT раз за этот ход. Платные действия, первые N бесплатных и
## чужие юниты не трогаются — перекладка пленника остаётся законным ходом, перестаёт
## быть бесконечной.
func _drop_looping(list: Array) -> Array:
	var token := _turn_token()
	if token != _free_turn:
		_free_turn = token
		_free_count = {}
		_free_kinds = {}
		_free_total = 0
		_shaping_used = 0
		_digs_used = 0
		return list
	# Сначала — КТО упёрся в потолок (бюджет стороны исчерпан — значит все, кто вообще
	# ходил бесплатно). Это дёшево: словарь размером с число отметившихся актёров.
	var dug_out := _digs_used >= _digs_turn_cap
	var side_done := _free_total >= _free_turn_cap
	var blocked := {}
	for key: Variant in _free_count:
		if side_done or int(_free_count[key]) >= FREE_ACTIONS_PER_UNIT:
			blocked[key] = true
	if blocked.is_empty() and not dug_out:
		return list
	# И только теперь фильтр. Порядок важен: _kind_of() зовёт IntentCodec.encode(), а он
	# строит словарь на КАЖДОЕ намерение. Прогон по всему списку стоил 230 мс на шаг
	# (276 против 45 до фильтра) — шестикратное замедление среды. Здесь он достаётся
	# только намерениям упёршихся актёров, которых обычно единицы; лопату же ловим
	# проверкой класса, она бесплатна.
	var out: Array = []
	for intent: Intent in list:
		if dug_out and intent is DigIntent:
			continue
		var key := _actor_key(intent)
		if key != "" and blocked.has(key) \
				and _free_kinds.has("%s|%s" % [key, _kind_of(intent)]):
			continue
		out.append(intent)
	return out

func _save_replay(path: String) -> Dictionary:
	if recorder == null or path == "":
		return {"ok": false, "error": "not recording"}
	var d := recorder.to_dict()
	d["meta"]["result"] = _result
	d["meta"]["steps_rl"] = _steps
	return {"ok": ReplayFile.write(path, d)}
