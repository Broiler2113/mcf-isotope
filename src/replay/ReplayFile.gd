class_name ReplayFile
extends RefCounted

## Файлы матча (M12): сохранение `.mcfs` и повтор `.mcfr`.
##
## Оба — один и тот же сжатый JSON, различаются только начинкой: в сохранении лежит
## ОДИН кадр доски плюс метаданные лобби, в повторе — стартовый кадр, поток намерений
## с их бросками и редкие ключевые кадры (см. ReplayRecorder). Поэтому чтение и запись
## у них общие, а разбирают их разные потребители.
##
## Сжатие не ради места, а ради формы: кадр большой карты — это тысячи чисел, и в
## текстовом виде повтор часовой партии разошёлся бы на десятки мегабайт. Читать файл
## обязан тот же режим, каким он записан, — отсюда одна пара функций на оба формата.

const REPLAY_DIR := "user://replays"
const SAVE_DIR := "user://saves"
const REPLAY_EXT := "mcfr"
const SAVE_EXT := "mcfs"
const COMPRESSION := FileAccess.COMPRESSION_GZIP

## Разрешённые символы имени файла — всё прочее (пробелы, кириллица, слэши) просто
## выбрасывается: имя карты приходит из редактора, и класть его в путь как есть нельзя.
const NAME_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

const KIND_SAVE := "save"
const KIND_REPLAY := "replay"

static func write(path: String, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var temporary := "%s.%d-%d.tmp" % [path, OS.get_process_id(), Time.get_ticks_usec()]
	var f := FileAccess.open_compressed(temporary, FileAccess.WRITE, COMPRESSION)
	if f == null:
		return false
	var contents := JSON.stringify(data)
	f.store_string(contents)
	f.flush()
	var ok := f.get_error() == OK
	f.close()
	# Compressed streams can report a full disk only when their final chunk closes.
	# Verify the temporary stream before replacing an existing replay/save.
	var check := FileAccess.open_compressed(temporary, FileAccess.READ, COMPRESSION) if ok else null
	ok = check != null and check.get_as_text() == contents
	if check != null:
		check.close()
	if not ok or DirAccess.rename_absolute(temporary, path) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	_write_note(path, describe(data))
	return true

## Viewing an old replay upgrades it once; save-game reads remain unchanged.
static func read_replay(path: String) -> Dictionary:
	var data := read(path)
	return ReplayMigration.upgrade(data, path)

## Подпись файла для списков меню — из маленького соседнего файла «<путь>.note».
##
## Меню раньше распаковывало и разбирало КАЖДЫЙ повтор и сохранение целиком ради одной
## строки «карта · раунд · действий»: повтор большой карты с кадрами доски — мегабайты, и
## выход в меню медленнел с каждой сыгранной партией. Подпись пишется вместе с файлом; у
## старых файлов она создаётся при первом чтении, дальше — только маленький текст.
const NOTE_EXT := ".note"

static func note_for(path: String) -> String:
	var np := path + NOTE_EXT
	if FileAccess.file_exists(np):
		var nf := FileAccess.open(np, FileAccess.READ)
		if nf != null:
			var t := nf.get_as_text()
			nf.close()
			return t
	var note := describe(read(path))
	_write_note(path, note)
	return note

static func _write_note(path: String, note: String) -> void:
	var nf := FileAccess.open(path + NOTE_EXT, FileAccess.WRITE)
	if nf != null:
		nf.store_string(note)
		nf.close()

## Пустой словарь = файла нет либо он не читается. Разбирать «наполовину прочитанный»
## матч нельзя, поэтому любая беда сводится к одному «не открылось».
static func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open_compressed(path, FileAccess.READ, COMPRESSION)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed

static func list_files(dir: String, ext: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for name in d.get_files():
		if name.ends_with("." + ext):
			out.append(name)
	out.sort()
	out.reverse()   # имена начинаются с даты — свежее сверху
	return out

static func saves() -> PackedStringArray:
	return list_files(SAVE_DIR, SAVE_EXT)

static func replays() -> PackedStringArray:
	return list_files(REPLAY_DIR, REPLAY_EXT)

static func path_for(dir: String, name: String) -> String:
	return "%s/%s" % [dir, name]

## Имя файла по времени: «2026-09-07_18-30-12_town.mcfr». Дата впереди, чтобы
## сортировка по имени была сортировкой по времени.
static func stamped(label: String, ext: String) -> String:
	var t := Time.get_datetime_dict_from_system()
	var stamp := "%04d-%02d-%02d_%02d-%02d-%02d" % [t["year"], t["month"], t["day"],
			t["hour"], t["minute"], t["second"]]
	var safe := label.strip_edges().replace(" ", "-")
	var clean := ""
	for i in safe.length():
		if NAME_CHARS.contains(safe[i]):
			clean += safe[i]
	if clean == "":
		clean = "match"
	return "%s_%s.%s" % [stamp, clean, ext]

## Имя файла из введённого игроком названия (item 19): «Rostov stand.mcfs». Санитизируем
## под безопасные символы; пусто — откатываемся на метку времени, чтобы файл всё же
## получил имя. Расширение добавляем, если игрок его не написал.
static func named(user_name: String, ext: String) -> String:
	var safe := user_name.strip_edges().replace(" ", "-")
	var clean := ""
	for i in safe.length():
		if NAME_CHARS.contains(safe[i]):
			clean += safe[i]
	if clean == "":
		return stamped("match", ext)
	return "%s.%s" % [clean, ext]

## Человекочитаемая подпись файла для списков меню.
static func describe(data: Dictionary) -> String:
	var meta: Dictionary = data.get("meta", {})
	var parts: PackedStringArray = []
	if str(meta.get("map", "")) != "":
		parts.append(str(meta["map"]))
	if int(meta.get("round", 0)) > 0:
		parts.append("round %d" % int(meta["round"]))
	if int(meta.get("steps", 0)) > 0:
		parts.append("%d actions" % int(meta["steps"]))
	if str(meta.get("saved_at", "")) != "":
		parts.append(str(meta["saved_at"]))
	return " · ".join(parts)
