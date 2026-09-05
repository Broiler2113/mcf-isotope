class_name MapHandoff
extends RefCounted

## Передача выбранной карты между сценами (редактор → игра). Статический слот
## живёт, пока загружен скрипт класса, поэтому переживает смену сцены (M5).
## null = запускать демо-ростер по умолчанию.
static var pending: MapData = null
## Зерно кубиков для боя. -1 = случайное. В сетевой партии обе стороны получают
## ОДНО зерно от хоста, чтобы совпал и локальный бросок инициативы.
static var dice_seed: int = -1

static func take_seed() -> int:
	var s := dice_seed
	dice_seed = -1
	return s
