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
## ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ ПЕРВОЙ ВЕРСИИ (issue 1: «make 100% sure this bug never appears
## again»). Список прежних имён приходилось дописывать руками на КАЖДОЕ переименование —
## то есть починка держалась на том, что о ней вспомнят в нужный момент. Теперь каталог
## соседних app_userdata обходится ЦЕЛИКОМ:
##   • у известных прежних имён (LEGACY_APP_NAMES) забираем всё, как и раньше;
##   • у любой другой соседней папки — ТОЛЬКО карты, и только те, что действительно
##     читаются как карта этой игры (JSON с width/height и слоями). Чужая папка от
##     другой игры на Godot отсеется на разборе, а своя — под каким бы именем игра ни
##     была собрана — найдётся сама.
## Текстуры и сохранённые партии из НЕизвестных папок не трогаем: подмешать чужие
## картинки в интерфейс куда хуже, чем не найти их.

## Имена каталогов app_userdata, из которых забираем ВСЁ (от старых к новым).
const LEGACY_APP_NAMES := ["MCF Tactics"]

## Что именно переносим из известных прежних каталогов. Логи и служебное — не наше дело.
const SUBDIRS := ["maps", "saves", "replays", "textures"]

## Подтянуть всё, чего ещё нет в текущем user://. Возвращает число скопированных файлов.
static func migrate_legacy() -> int:
	var current := OS.get_user_data_dir()
	var parent := current.get_base_dir()
	var copied := 0
	var known := {}
	for legacy_name: String in LEGACY_APP_NAMES:
		var legacy := parent.path_join(legacy_name)
		known[legacy_name] = true
		if legacy == current or not DirAccess.dir_exists_absolute(legacy):
			continue
		for sub: String in SUBDIRS:
			copied += _copy_missing(legacy.path_join(sub), current.path_join(sub))
	# Все прочие соседи: только карты, и только настоящие.
	var siblings := DirAccess.open(parent)
	if siblings != null:
		for name: String in siblings.get_directories():
			var dir := parent.path_join(name)
			if dir == current or known.has(name):
				continue
			copied += _copy_missing(dir.path_join("maps"), current.path_join("maps"), true)
	return copied

## Скопировать из src_dir в dst_dir только те файлы, которых там ещё нет.
## maps_only — брать лишь то, что разбирается как карта этой игры.
static func _copy_missing(src_dir: String, dst_dir: String, maps_only: bool = false) -> int:
	var src := DirAccess.open(src_dir)
	if src == null:
		return 0
	var n := 0
	for file_name: String in src.get_files():
		var src_file := src_dir.path_join(file_name)
		if maps_only and not _is_map_file(src_file):
			continue
		var dst_file := dst_dir.path_join(file_name)
		if FileAccess.file_exists(dst_file):
			continue
		DirAccess.make_dir_recursive_absolute(dst_dir)
		if DirAccess.copy_absolute(src_file, dst_file) == OK:
			n += 1
	return n

## Карта ли это НАШЕЙ игры: JSON с размерами и слоем пола. Проверка нужна там, где мы
## заглядываем в чужую папку: файл под именем maps/*.json может лежать у кого угодно.
static func _is_map_file(path: String) -> bool:
	if not path.ends_with(".json"):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = parsed
	return d.has("width") and d.has("height") and d.has("floor_type")
