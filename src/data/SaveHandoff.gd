class_name SaveHandoff
extends RefCounted

## Передача загруженного файла между сценами (M12) — та же уловка, что и у MapHandoff:
## статическое поле живёт, пока загружен скрипт класса, поэтому переживает смену сцены.
##
## Два независимых слота, потому что это два РАЗНЫХ режима боевого экрана: продолжение
## сохранённой партии (играем) и просмотр записи (смотрим). Слот забирается ровно один
## раз — иначе выход в меню и «Новая игра» снова уехали бы в чужой матч.

## Содержимое `.mcfs` — партия, которую надо продолжить.
static var pending_save: Dictionary = {}
## Содержимое `.mcfr` — запись, которую надо показать.
static var pending_replay: Dictionary = {}

static func take_save() -> Dictionary:
	var d := pending_save
	pending_save = {}
	return d

static func take_replay() -> Dictionary:
	var d := pending_replay
	pending_replay = {}
	return d

static func discard() -> void:
	pending_save = {}
	pending_replay = {}
