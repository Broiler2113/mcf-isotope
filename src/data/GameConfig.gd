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

## Ростер партии, каким его должны видеть экраны. Никогда не null: без лобби это
## дуэль, настроенная флагами p1_is_ai/p2_is_ai.
static func active_roster() -> Roster:
	if roster == null:
		roster = Roster.default_duel(p2_is_ai, ai_difficulty)
		roster.slots[0].kind = Roster.SlotKind.AI if p1_is_ai else Roster.SlotKind.HUMAN
	return roster
