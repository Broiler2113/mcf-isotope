extends SceneTree

## Главное меню — ОДИН список кнопок.
##
## Раньше шесть пунктов меню жили в четырёх разных местах: «New Game» и «Map Editor» на
## вкладке, мультиплеер и файлы — на соседних вкладках, настройки с выходом — отдельной
## строкой внизу. На экране это читалось как две кнопки и пустое поле под ними.
##
## Проверяется то, что игрок и видит: на первой странице лежат ВСЕ шесть пунктов, в одном
## столбце и в одном порядке чтения; полосы вкладок нет; кнопки мультиплеера и файлов
## ведут на свои страницы, и с каждой есть дорога назад.

var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

func _buttons(n: Node, out: Array) -> void:
	if n is Button:
		out.append(n)
	for c in n.get_children():
		_buttons(c, out)

func _labels(n: Node) -> Array:
	var btns: Array = []
	_buttons(n, btns)
	var out: Array = []
	for b: Button in btns:
		out.append(b.text)
	return out

func _press(n: Node, text: String) -> bool:
	var btns: Array = []
	_buttons(n, btns)
	for b: Button in btns:
		if b.text == text:
			b.pressed.emit()
			return true
	return false

func _initialize() -> void:
	var menu = load("res://scenes/MainMenu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame

	var pages: TabContainer = menu._pages
	ck(pages != null and pages.get_tab_count() == 3, "the menu holds three pages")
	ck(not pages.tabs_visible, "and shows no tab strip — the buttons are the navigation")
	ck(pages.current_tab == menu.PAGE_HOME, "it opens on the main list")

	var home := pages.get_tab_control(menu.PAGE_HOME)
	var want := ["New Game", "Map Editor", "Multiplayer", "Saves & Replays", "Settings", "Quit"]
	ck(_labels(home) == want, "every entry is one button in one column, in reading order (%s)"
			% [_labels(home)])

	ck(_press(home, "Multiplayer"), "the Multiplayer button exists")
	ck(pages.current_tab == menu.PAGE_MULTI, "and opens the multiplayer page (%d)" % pages.current_tab)
	var mp := pages.get_tab_control(menu.PAGE_MULTI)
	ck(_press(mp, "< Back"), "that page offers a way back")
	ck(pages.current_tab == menu.PAGE_HOME, "which returns to the main list (%d)" % pages.current_tab)

	ck(_press(home, "Saves & Replays"), "the Saves & Replays button exists")
	ck(pages.current_tab == menu.PAGE_FILES, "and opens its page (%d)" % pages.current_tab)
	var files := pages.get_tab_control(menu.PAGE_FILES)
	ck(_press(files, "< Back"), "it too has a way back")
	ck(pages.current_tab == menu.PAGE_HOME, "back to the list again (%d)" % pages.current_tab)

	menu.free()
	if fails.is_empty():
		print("main menu: one column, six entries, and every page finds its way home")
		quit(0)
		return
	printerr("main menu: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)
