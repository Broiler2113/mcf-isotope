extends SceneTree

## Разбор ВСЕХ скриптов проекта за один заход.
##
## `godot --check-only --script X.gd` для сценных скриптов не годится: он не видит
## автозагрузку (`Ui`), и любой файл, который её упоминает, «падает» на ровном
## месте. Здесь проект уже запущен по-настоящему, поэтому и автозагрузка на месте,
## и глобальные классы зарегистрированы.

## ВАЖНО: load() мало. Скрипт с синтаксической ошибкой Godot всё равно отдаёт объектом —
## ошибку он печатает, а null не возвращает. Из-за этого проверка годами могла сказать
## «125 scripts parsed clean» на дереве, которое не компилируется: ровно так и случилось,
## когда в GameActionResolver.gd появилось необъявленное `result` — в выводе был
## SCRIPT ERROR, а код возврата ноль и последняя строка «clean». Тест, который не умеет
## падать на самой частой ошибке, хуже отсутствующего: на него полагаются.
##
## reload() возвращает Error и на разборе не врёт — вот по нему и судим.
func _initialize() -> void:
	var bad: PackedStringArray = []
	var n := 0
	var live := _live_scripts()
	for path in _scripts("res://"):
		n += 1
		var s: Resource = load(path)
		if s == null:
			bad.append(path)
			continue
		# ЖИВЫЕ скрипты reload() не переживают по причинам, не имеющим отношения к разбору:
		# этот файл сейчас выполняется сам, а автозагрузки уже созданы в дереве. Для них
		# остаётся проверка load() != null — слабее, но ложных падений не даёт.
		#
		# Свежую копию (GDScript.new() + source_code) пробовать НЕ надо: она не видит ни
		# class_name, ни автозагрузок, и «падает» на 84 файлах из 125.
		if live.has(path):
			continue
		if s is GDScript and (s as GDScript).reload() != OK:
			bad.append(path)
	if bad.is_empty():
		print("check: %d scripts parsed clean" % n)
		quit(0)
		return
	printerr("check: %d of %d scripts failed to load" % [bad.size(), n])
	for b in bad:
		printerr("  " + b)
	quit(1)

## Скрипты, которые в этот момент ИСПОЛНЯЮТСЯ: сам тест и все автозагрузки. Их reload()
## возвращает не-OK независимо от того, как они написаны.
func _live_scripts() -> Dictionary:
	var out := {}
	var self_script: Script = get_script() as Script
	if self_script != null:
		out[self_script.resource_path] = true
	for prop: Dictionary in ProjectSettings.get_property_list():
		var key: String = prop.get("name", "")
		if not key.begins_with("autoload/"):
			continue
		var value := str(ProjectSettings.get_setting(key, ""))
		# Значение — путь, возможно с ведущим "*" (включённая автозагрузка).
		out[value.trim_prefix("*")] = true
	return out


func _scripts(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir.path_join(name)
		if d.current_is_dir():
			out.append_array(_scripts(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()
	return out
