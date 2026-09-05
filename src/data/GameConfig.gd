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
static var fog_enabled: bool = false
static var budget: int = DEFAULT_BUDGET
## Свободная расстановка (point-buy + ручной деплой) вместо демо-ростера.
static var free_placement: bool = true
