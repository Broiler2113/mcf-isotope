extends SceneTree

## Скин интерфейса обязан ПЕРЕЖИТЬ ЭКСПОРТ.
##
## Весь интерфейс — панели, кнопки, вкладки, поля, ползунки — собран девятислайсами из
## res://interface_textures. Загружались они сырым Image.load с диска, и движок на это
## предупреждал: «Loaded resource as image file, this will not work on export». В .pck
## сырого PNG нет — держалось всё на запасной ветке, куда код сваливался по счастливой
## случайности (file_exists() в сборке отвечает «нет»). Достаточно было экспорту
## прихватить PNG как обычный файл, и весь скин поехал бы мимо импорта.
##
## Проверяем здесь два обещания разом:
##   1. КАЖДАЯ картинка скина отдаётся и приходит ИМПОРТИРОВАННЫМ ресурсом — то есть
##      ровно тем, что лежит в .pck. ImageTexture в ответе означает сырой файл с диска:
##      в редакторе он виден, в сборке его нет;
##   2. обещание из HOW_TO_REPLACE_INTERFACE_TEXTURES.txt (§4) при этом цело: PNG,
##      положенный поверх и ещё не разобранный редактором, читается с диска.
##
## Шрифт сюда не входит: ui_font.ttf игра не поставляет (по умолчанию системный
## Tahoma), и проверять на пустом месте нечего.

## Имена из §1 справки — по файлу на каждую часть интерфейса.
const SKIN := [
	"panel", "panel_sunken", "header",
	"button_normal", "button_hover", "button_pressed", "button_disabled",
	"tab_active", "tab_inactive", "field",
	"progress_bg", "progress_fill", "slider_track", "slider_grabber",
	"selection", "check_on", "check_off", "arrow_up", "arrow_down",
]

## Автозагрузка `Ui` в прогоне через --script ещё не поднята, поэтому берём сам класс
## и делаем себе отдельный экземпляр. В дерево он не попадает, _ready не срабатывает —
## нам нужны только загрузчики картинок, а они от темы не зависят.
const UI_THEME = preload("res://src/ui/UiTheme.gd")

var ui: Node = UI_THEME.new()
var fails: PackedStringArray = []

func _initialize() -> void:
	_skin_is_imported()
	_dropped_png_still_wins()

	# Свой экземпляр темы держит в кеше все разобранные картинки — отпускаем его до
	# выхода, иначе движок на прощание отчитается о «утёкших» ресурсах.
	ui.free()
	ui = null

	if fails.is_empty():
		print("ui assets: %d skin textures come from the import pipeline" % SKIN.size())
		quit(0)
		return
	printerr("ui assets: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func ck(cond: bool, what: String) -> void:
	if not cond:
		fails.append(what)

## 1. Всё, из чего собран скин, приходит импортированным ресурсом.
func _skin_is_imported() -> void:
	for name: String in SKIN:
		var tex: Texture2D = ui.get_texture(name)
		if tex == null:
			fails.append("%s.png is missing from the skin" % name)
			continue
		# Разобранная движком картинка приходит как CompressedTexture2D (или иной
		# ресурс-текстура); ImageTexture — признак чтения сырого файла в обход импорта.
		ck(not (tex is ImageTexture),
				"%s.png goes through the import pipeline, not a raw disk read" % name)
		ck(tex.get_width() > 0 and tex.get_height() > 0,
				"%s.png has a real size" % name)

## 2. Свежеподложенный файл всё ещё выигрывает у разобранного (§4 справки).
##
## Трогать res://interface_textures прогон не вправе — это рабочие файлы проекта.
## Поэтому проверяется само правило («файл новее своего .import»), на паре временных
## файлов в user://: именно оно решает, читать диск или реестр ресурсов.
func _dropped_png_still_wins() -> void:
	var raw := "user://__ui_assets_probe.png"
	var imported := raw + ".import"
	ck(not UI_THEME._raw_is_newer(raw), "a file that does not exist is not 'freshly dropped'")

	_touch(raw)
	ck(UI_THEME._raw_is_newer(raw), "a PNG with no .import beside it is read off disk")

	# .import ПОЗЖЕ картинки — редактор её разобрал, дальше главный он.
	_touch(imported, 2)
	ck(not UI_THEME._raw_is_newer(raw), "an imported PNG is taken from the resource pipeline")

	# Художник кладёт своё поверх — картинка снова свежее разбора.
	_touch(raw, 4)
	ck(UI_THEME._raw_is_newer(raw), "a PNG dropped in after the import is read off disk again")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(raw))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(imported))

## Создать файл и выставить ему время «сейчас + offset секунд»: разрешение mtime на
## иных файловых системах — целая секунда, и два файла, записанные подряд, оказались
## бы РОВЕСНИКАМИ. Разводим их заведомо дальше этого предела.
func _touch(path: String, offset_sec: int = 0) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		fails.append("cannot write the probe file " + path)
		return
	f.store_string("probe")
	f.close()
	var real := ProjectSettings.globalize_path(path)
	var when := Time.get_unix_time_from_system() + offset_sec
	OS.execute("touch", ["-d", "@%d" % int(when), real])
