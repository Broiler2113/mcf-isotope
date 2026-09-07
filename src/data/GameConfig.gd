class_name GameConfig
extends RefCounted

## Выбор режима из главного меню в игру (M8). Статические поля переживают смену
## сцены, пока загружен скрипт класса (как MapHandoff). ai_difficulty = 1 (НОРМ.)
## совпадает с AIController.Difficulty.NORMAL.
static var p2_is_ai: bool = false
## Первый игрок тоже может быть машиной (#103) — тогда партия идёт ИИ ПРОТИВ ИИ, а человек
## за ней наблюдает. Нужно это не для игры, а для проверки самого ИИ: полный бой прогоняется
## без единого клика, и видно, как штаб на деле распоряжается армией.
static var p1_is_ai: bool = false
static var ai_difficulty: int = 1

## Настройки матча из экрана подготовки (Setup), как в isotope §12b.
## map_path == "" → демо-ростер по умолчанию (см. Main._build_state).
const DEFAULT_BUDGET := 300
static var map_path: String = ""
static var civilians_enabled: bool = true
## Режим тумана (item 46): MCF.Fog.OFF / STANDARD / REALISTIC. Прежний булев
## fog_enabled остался отдельным свойством ниже — им пользуются сохранённые настройки
## и старый экран подготовки, и он просто читает/пишет этот режим.
static var fog_mode: int = MCF.Fog.OFF

static var fog_enabled: bool:
	get:
		return fog_mode != MCF.Fog.OFF
	set(v):
		# Включение «галочкой» даёт СТАНДАРТНЫЙ туман: реалистичный выбирают явно.
		fog_mode = MCF.Fog.STANDARD if v else MCF.Fog.OFF
static var budget: int = DEFAULT_BUDGET
## Свободная расстановка (point-buy + ручной деплой) вместо демо-ростера.
static var free_placement: bool = true
## Состав партии, собранный в лобби (Roster): кто играет, за какую команду, каким
## цветом. null — лобби не собиралось, значит дуэль на двоих по флагам выше.
static var roster: Roster = null
## Дружественный огонь (§7 лобби, item 36). По умолчанию включён — таким он и был.
static var friendly_fire: bool = true

## Режим расстановки (item 39): ASYMMETRIC — каждый расставляет свой отряд свободно
## (как было); MIRRORED — хост расставляет один блок, остальные «штампуют» его копию
## в своей зоне.
enum Placement {ASYMMETRIC, MIRRORED}
static var placement_mode: int = Placement.ASYMMETRIC

## Свободная расстановка без бюджета (item 40). free_unlimited_for: -1 — никому (обычный
## бюджет), -2 — ВСЕМ, иначе номер единственного игрока с бесконечными очками.
const FREE_NONE := -1
const FREE_ALL := -2
static var free_unlimited_for: int = FREE_NONE

## Кто выбирает цвета (§1.3): HOST_DECIDES — цвета назначает хост; PLAYERS_PICK — каждый
## выбирает свой в личном блоке лобби.
enum ArmySelect {HOST_DECIDES, PLAYERS_PICK}
static var army_select_mode: int = ArmySelect.PLAYERS_PICK

## Активный режим правил (§1.3). Пока — только «Domination» как заглушка-модуль.
static var game_mode: String = "domination"

## Видно ли чужую расстановку в фазе закупки (item 48).
static var live_placement_visible: bool = true

## Настройки случайных событий (§1.5, item 61): включены ли, обязательное событие каждый
## ход, сколько ходов между событиями и веса-доли по id события. Пустой roster = каркас
## без включённых событий. См. RandomEvents.
static var random_events_enabled: bool = false
static var random_events_mandatory: bool = false
static var random_events_interval: int = 3
static var random_events_weights: Dictionary = {}

## Бюджет бесконечен для этого игрока? (item 40) 0 в budget исторически уже значил
## «без лимита», этим и пользуемся.
static func unlimited_for(owner: int) -> bool:
	return free_unlimited_for == FREE_ALL \
			or (free_unlimited_for >= 0 and free_unlimited_for == owner)

## Ростер партии, каким его должны видеть экраны. Никогда не null: без лобби это
## дуэль, настроенная флагами p1_is_ai/p2_is_ai.
static func active_roster() -> Roster:
	if roster == null:
		roster = Roster.default_duel(p2_is_ai, ai_difficulty)
		roster.slots[0].kind = Roster.SlotKind.AI if p1_is_ai else Roster.SlotKind.HUMAN
	return roster
