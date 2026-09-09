class_name UserDataMigration

## Перенос сохранённого из каталога ПРЕЖНЕГО имени игры.
##
## Godot выводит путь user:// из application/config/name. Переименование приложения
## («MCF Tactics» → «MCF Isotope», item 7) увело user:// в НОВУЮ папку, а всё, что игрок
## успел сохранить — карты, партии, повторы, свои текстуры — осталось лежать в старой.
## Наружу это выглядело так, будто сохранённые карты пропали: в выпадающем списке лобби
## оставались только поставочные (res://maps) и «Blank arena».
##
## Поэтому при запуске содержимое прежних каталогов разово подтягивается в текущий.
## Операция намеренно щадящая:
##   • КОПИРУЕТ, а не переносит — старая папка остаётся нетронутой, откатиться можно;
##   • НИКОГДА не перезаписывает уже существующий файл — то, что сохранено под новым
##     именем, всегда новее и главнее;
##   • идемпотентна: второй запуск не копирует ничего.
##
## При следующем переименовании игры сюда достаточно дописать прежнее имя.

## Имена каталогов app_userdata, из которых забираем данные (от старых к новым).
const LEGACY_APP_NAMES := ["MCF Tactics"]

## Что именно переносим. Логи и служебное — не наше дело.
const SUBDIRS := ["maps", "saves", "replays", "textures"]

## Подтянуть всё, чего ещё нет в текущем user://. Возвращает число скопированных файлов.
static func migrate_legacy() -> int:
	var current := OS.get_user_data_dir()
	var parent := current.get_base_dir()
	var copied := 0
	for legacy_name: String in LEGACY_APP_NAMES:
		var legacy := parent.path_join(legacy_name)
		if legacy == current or not DirAccess.dir_exists_absolute(legacy):
			continue
		for sub: String in SUBDIRS:
			copied += _copy_missing(legacy.path_join(sub), current.path_join(sub))
	return copied

## Скопировать из src_dir в dst_dir только те файлы, которых там ещё нет.
static func _copy_missing(src_dir: String, dst_dir: String) -> int:
	var src := DirAccess.open(src_dir)
	if src == null:
		return 0
	var n := 0
	for file_name: String in src.get_files():
		var dst_file := dst_dir.path_join(file_name)
		if FileAccess.file_exists(dst_file):
			continue
		DirAccess.make_dir_recursive_absolute(dst_dir)
		if DirAccess.copy_absolute(src_dir.path_join(file_name), dst_file) == OK:
			n += 1
	return n
