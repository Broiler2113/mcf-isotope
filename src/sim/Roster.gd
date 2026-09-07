class_name Roster
extends RefCounted

## Состав партии: кто играет, за какую команду и каким цветом.
##
## Раньше этого знания не существовало отдельно — оно было размазано по экрану боя
## (два цвета в словаре), по расстановке (два бюджета) и по перечислению сторон.
## Пока сторон было ровно две, это работало. Начиная с N игроков и команд нужен
## один источник правды, иначе «кто мне союзник» пришлось бы отвечать в четырёх
## местах по-разному.
##
## Ростер — ДАННЫЕ, а не поведение: его собирает лобби, кладёт в GameState и шлёт
## клиентам. Симуляция читает его через team_of()/are_allies() и не знает, откуда
## он взялся.

enum SlotKind {OPEN, CLOSED, HUMAN, AI}

## Цвета игроков. Первые два — исторические синий/красный дуэли, чтобы партия на
## двоих выглядела ровно как раньше. Остальные подобраны так, чтобы различаться
## и на тёмном полу, и на светлом снегу, и в сером тумане войны.
const PALETTE := [
	Color(0.30, 0.55, 1.00), Color(1.00, 0.40, 0.35), Color(0.40, 0.85, 0.45),
	Color(1.00, 0.80, 0.25), Color(0.75, 0.45, 0.95), Color(0.20, 0.85, 0.85),
	Color(1.00, 0.55, 0.15), Color(0.95, 0.45, 0.75), Color(0.55, 0.75, 0.25),
	Color(0.35, 0.45, 0.85), Color(0.85, 0.25, 0.25), Color(0.25, 0.65, 0.55),
	Color(0.90, 0.70, 0.50), Color(0.60, 0.35, 0.25), Color(0.50, 0.85, 0.75),
	Color(0.80, 0.85, 0.40), Color(0.45, 0.30, 0.65), Color(1.00, 0.65, 0.65),
	Color(0.30, 0.75, 1.00), Color(0.70, 0.55, 0.35), Color(0.55, 0.55, 0.60),
	Color(0.95, 0.35, 0.55), Color(0.35, 0.85, 0.30), Color(0.65, 0.75, 0.95),
	Color(0.85, 0.55, 0.90), Color(0.40, 0.60, 0.35),
]

## Цвет нейтральной стороны и её групп — один на всех: нейтралы не команда, они фон.
const NEUTRAL_COLOR := Color(0.80, 0.80, 0.55)

class Slot extends RefCounted:
	var id: int = -1
	var kind: int = SlotKind.OPEN
	## Имя в интерфейсе. По умолчанию «Player A» по букве слота; сеть подставляет
	## сюда имя подключившегося.
	var display_name: String = ""
	var color: Color = Color.WHITE
	## Номер команды или −1 «сам за себя». Командный режим — это просто партия,
	## в которой хотя бы у одного слота team >= 0.
	var team: int = -1
	var ai_difficulty: int = 1
	## Личный бюджет очков. 0 = безлимит (та же условность, что у GameConfig.budget).
	var budget: int = 0
	## Пир, который ведёт этот слот в сетевой партии; −1 — местный или никто.
	var peer_id: int = -1
	## Сторона выбита. Слот НЕ удаляется из инициативы: он остаётся видимым и
	## пропускается — иначе из очереди пропадает история партии (§15.4).
	var eliminated: bool = false

	func is_playing() -> bool:
		return kind == SlotKind.HUMAN or kind == SlotKind.AI

	## Индекс цвета слота в PALETTE (для списков лобби). −1 нет: подбираем ближайший.
	func color_index() -> int:
		for i in Roster.PALETTE.size():
			if Roster.PALETTE[i].is_equal_approx(color):
				return i
		return id % Roster.PALETTE.size()

var slots: Array = []
## Бюджет очков на команду; индекс = номер команды. Пусто — команд нет.
var team_budgets: Array = []

# --- Сборка ------------------------------------------------------------------

## Добавить слот и вернуть его номер (он же owner юнитов этой стороны).
func add_slot(kind: int = SlotKind.OPEN, team: int = -1) -> int:
	var id := slots.size()
	if id >= MCF.MAX_PLAYERS:
		return -1
	var s := Slot.new()
	s.id = id
	s.kind = kind
	s.team = team
	s.color = PALETTE[id % PALETTE.size()]
	s.display_name = MCF.owner_name(id)
	slots.append(s)
	return id

## Партия на двоих без команд — ровно то, чем игра была до этого шага. Служит
## значением по умолчанию везде, где ростер ещё не собран лобби.
static func default_duel(p2_is_ai: bool = false, difficulty: int = 1) -> Roster:
	var r := Roster.new()
	r.add_slot(SlotKind.HUMAN)
	r.add_slot(SlotKind.AI if p2_is_ai else SlotKind.HUMAN)
	r.slots[1].ai_difficulty = difficulty
	return r

## Ростер под уже готовую доску: слоты 0..max(ids), присутствующие — играющие,
## пропуски — закрытые. Нумерация слотов ОБЯЗАНА совпадать с owner юнитов, поэтому
## дыры в середине закрываются, а не ужимаются.
static func for_sides(ids: Array) -> Roster:
	var r := Roster.new()
	var top := -1
	for id in ids:
		if MCF.is_player(int(id)):
			top = maxi(top, int(id))
	if top < 1:
		top = 1  # партия минимум на двоих: пустой слот врага честнее, чем его отсутствие
	for i in top + 1:
		r.add_slot(SlotKind.HUMAN if int(i) in ids else SlotKind.CLOSED)
	return r

func slot(owner: int) -> Slot:
	if owner < 0 or owner >= slots.size():
		return null
	return slots[owner]

# --- Запросы -----------------------------------------------------------------

## Стороны, у которых вообще есть ход: занятые слоты в порядке номеров.
## Именно этот список задаёт порядок инициативы (§3.2).
func player_ids() -> Array[int]:
	var out: Array[int] = []
	for s: Slot in slots:
		if s.is_playing():
			out.append(s.id)
	return out

func team_of(owner: int) -> int:
	var s := slot(owner)
	return s.team if s != null else -1

## Есть ли в партии команды вообще. Пока нет — все правила «для командного режима»
## (дружественный огонь, общий обзор, групповые счётчики) спят.
func has_teams() -> bool:
	for s: Slot in slots:
		if s.team >= 0:
			return true
	return false

## Союзники ли двое. Сам себе — всегда союзник. Нейтралы не в команде ни с кем,
## включая других нейтралов: их вражда ко всем описана отдельно (§14).
func are_allies(a: int, b: int) -> bool:
	if a == b:
		return true
	if not MCF.is_player(a) or not MCF.is_player(b):
		return false
	var ta := team_of(a)
	return ta >= 0 and ta == team_of(b)

## Все стороны, чьё зрение сливается с этой: сам плюс живые союзники по команде.
func vision_sharers(owner: int) -> Array[int]:
	var out: Array[int] = [owner]
	if not MCF.is_player(owner):
		return out
	var t := team_of(owner)
	if t < 0:
		return out
	for s: Slot in slots:
		if s.id != owner and s.is_playing() and s.team == t:
			out.append(s.id)
	return out

func team_members(team: int) -> Array[int]:
	var out: Array[int] = []
	for s: Slot in slots:
		if s.is_playing() and s.team == team:
			out.append(s.id)
	return out

func name_of(owner: int) -> String:
	var s := slot(owner)
	if s != null and s.display_name != "":
		return s.display_name
	return MCF.owner_name(owner)

func color_of(owner: int) -> Color:
	if MCF.is_neutral(owner):
		return NEUTRAL_COLOR
	var s := slot(owner)
	return s.color if s != null else Color.WHITE

func is_eliminated(owner: int) -> bool:
	var s := slot(owner)
	return s != null and s.eliminated

func set_eliminated(owner: int, value: bool) -> void:
	var s := slot(owner)
	if s != null:
		s.eliminated = value

func is_ai(owner: int) -> bool:
	var s := slot(owner)
	return s != null and s.kind == SlotKind.AI

## Цвет каждого игрока уникален (§4 лобби). Проверка живёт здесь, а не в лобби,
## чтобы её нельзя было обойти, собрав ростер другим путём (сохранение, реплей).
func has_duplicate_colors() -> bool:
	var seen := {}
	for s: Slot in slots:
		if not s.is_playing():
			continue
		var key := s.color.to_html(false)
		if seen.has(key):
			return true
		seen[key] = true
	return false

# --- Сериализация (лобби → сеть → сохранение) --------------------------------

func to_dict() -> Dictionary:
	var out: Array = []
	for s: Slot in slots:
		out.append({
			"id": s.id, "kind": s.kind, "name": s.display_name,
			"color": s.color.to_html(false), "team": s.team,
			"ai": s.ai_difficulty, "budget": s.budget, "peer": s.peer_id,
			"dead": s.eliminated,
		})
	return {"slots": out, "team_budgets": team_budgets.duplicate()}

static func from_dict(d: Dictionary) -> Roster:
	var r := Roster.new()
	for rec in d.get("slots", []):
		var id := r.add_slot(int(rec.get("kind", SlotKind.OPEN)),
				int(rec.get("team", -1)))
		if id < 0:
			break
		var s: Slot = r.slots[id]
		s.display_name = str(rec.get("name", s.display_name))
		s.color = Color.from_string(str(rec.get("color", "")), s.color)
		s.ai_difficulty = int(rec.get("ai", 1))
		s.budget = int(rec.get("budget", 0))
		s.peer_id = int(rec.get("peer", -1))
		s.eliminated = bool(rec.get("dead", false))
	for b in d.get("team_budgets", []):
		r.team_budgets.append(int(b))
	return r

## Снимок изменяемой части для Undo. Состав и цвета по ходу боя не меняются —
## меняется только «выбит ли», поэтому снимок такой короткий.
func snapshot() -> Array:
	var out: Array = []
	for s: Slot in slots:
		out.append(s.eliminated)
	return out

func restore(snap: Array) -> void:
	for i in mini(snap.size(), slots.size()):
		slots[i].eliminated = bool(snap[i])
