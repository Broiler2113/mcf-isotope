extends SceneTree
## Тактические «этюды» для обучения (rl/maps/drill_*.json): маленькие карты, где побеждает
## один определённый приём. Обучаемый играет обе стороны (сторона = сид % 2), так что каждый
## этюд учит и нападать, и обороняться. Пересобрать: godot --headless --script res://rl/tools/make_drills.gd
##
##   drill_mg_nest      — пулемётное гнездо за мешками держит улицу; в лоб не пройти, по
##                        переулкам с севера и юга — можно.
##   drill_tank_screen  — танк с пехотой против засады противотанкистов в руинах: танк без
##                        прикрытия сгорает, с пехотой впереди — давит.
##   drill_breach       — обнесённый стеной двор с одним шлюзом; у нападающих сапёры,
##                        инженеры и огнемётчик.
##   drill_drone_recon  — поле с окопами снайперов и марксманов; у нападающих операторы
##                        дронов — разведать и подорвать, прежде чем идти.
##   drill_crossfire    — зеркальный бой взвод на взвод через стену с тремя проломами:
##                        выигрывает тот, кто сосредоточит огонь на одном проломе.
##   drill_sniper_lanes — параллельные улицы, ряды домов с окнами: дальний бой и смена позиций.

const W := MCF.FEATURE_WALL
const S := MCF.FEATURE_SANDBAGS
const G := MCF.FEATURE_GLASS
const T := MCF.FEATURE_TRENCH
const A := MCF.FEATURE_AIRLOCK

func _initialize() -> void:
	_save("drill_mg_nest", _mg_nest())
	_save("drill_tank_screen", _tank_screen())
	_save("drill_breach", _breach())
	_save("drill_drone_recon", _drone_recon())
	_save("drill_crossfire", _crossfire())
	_save("drill_sniper_lanes", _sniper_lanes())
	quit()

func _blank(w: int, h: int) -> MapData:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	return m

func _f(m: MapData, c: Vector2i, fid: String) -> void:
	m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, fid)

func _rect(m: MapData, r: Rect2i, fid: String) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_f(m, Vector2i(x, y), fid)

## Рамка стен прямоугольника (контур), с проёмами `gaps`.
func _box(m: MapData, r: Rect2i, fid: String, gaps: Array = []) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var edge := x == r.position.x or y == r.position.y or x == r.end.x - 1 or y == r.end.y - 1
			var c := Vector2i(x, y)
			if edge and not gaps.has(c):
				_f(m, c, fid)

func _units(m: MapData, owner: int, stats_id: String, cells: Array) -> void:
	for c: Vector2i in cells:
		m.set_spawn(c, stats_id, owner)

func _col(x: int, ys: Array) -> Array:
	var out: Array = []
	for y: int in ys:
		out.append(Vector2i(x, y))
	return out

func _mg_nest() -> MapData:
	var m := _blank(30, 21)
	# Кварталы сверху и снизу — улица посередине (y 7..13) простреливается гнездом. Вдоль
	# краёв карты (y 0 и y 20) и сквозь кварталы (x 14) — обходные переулки во фланг гнезду.
	_rect(m, Rect2i(8, 1, 14, 6), W)
	_rect(m, Rect2i(8, 14, 14, 6), W)
	_rect(m, Rect2i(14, 1, 2, 6), "")
	_rect(m, Rect2i(14, 14, 2, 6), "")
	# Гнездо: дуга мешков у выхода улицы.
	for c in [Vector2i(23, 8), Vector2i(23, 9), Vector2i(23, 10), Vector2i(23, 11), Vector2i(23, 12),
			Vector2i(24, 7), Vector2i(24, 13)]:
		_f(m, c, S)
	_units(m, 1, "machinegunner", [Vector2i(24, 9), Vector2i(24, 11)])
	_units(m, 1, "light_infantry", [Vector2i(25, 8), Vector2i(25, 12), Vector2i(26, 10)])
	_units(m, 0, "light_infantry", _col(2, [6, 8, 10, 12, 14]))
	_units(m, 0, "assault", [Vector2i(4, 9), Vector2i(4, 11)])
	_units(m, 0, "marksman", [Vector2i(1, 10)])
	_units(m, 0, "engineer", [Vector2i(3, 10)])
	return m

func _tank_screen() -> MapData:
	var m := _blank(36, 24)
	# Руины: обрывки стен в середине карты — укрытия засады.
	for r in [Rect2i(16, 4, 1, 4), Rect2i(19, 9, 4, 1), Rect2i(15, 14, 1, 5), Rect2i(21, 17, 3, 1),
			Rect2i(24, 6, 1, 3), Rect2i(26, 12, 1, 4), Rect2i(12, 10, 2, 1)]:
		_rect(m, r, W)
	for c in [Vector2i(17, 11), Vector2i(18, 11), Vector2i(22, 13), Vector2i(23, 13)]:
		_f(m, c, S)
	# Танк (след 3×3 от (3, 10)) и экипаж вплотную; пехота прикрытия рядом.
	m.set_spawn(Vector2i(3, 10), "tank", 0)
	_units(m, 0, "light_infantry", [Vector2i(2, 10), Vector2i(2, 11), Vector2i(2, 12)])
	_units(m, 0, "light_infantry", [Vector2i(7, 7), Vector2i(7, 15), Vector2i(8, 9), Vector2i(8, 13)])
	_units(m, 0, "engineer", [Vector2i(6, 11)])
	_units(m, 1, "anti_tank", [Vector2i(17, 6), Vector2i(20, 10), Vector2i(16, 16)])
	_units(m, 1, "light_infantry", [Vector2i(25, 7), Vector2i(27, 13), Vector2i(22, 18)])
	return m

func _breach() -> MapData:
	var m := _blank(32, 24)
	# Двор 12×12 за сплошной стеной, единственный вход — шлюз на западной стене.
	_box(m, Rect2i(17, 6, 12, 12), W, [Vector2i(17, 11)])
	_f(m, Vector2i(17, 11), A)
	for c in [Vector2i(19, 10), Vector2i(19, 11), Vector2i(19, 12)]:
		_f(m, c, S)
	_units(m, 1, "machinegunner", [Vector2i(21, 11)])
	_units(m, 1, "light_infantry", [Vector2i(22, 8), Vector2i(22, 15), Vector2i(26, 9), Vector2i(26, 14)])
	_units(m, 0, "sapper", [Vector2i(4, 9), Vector2i(4, 14)])
	_units(m, 0, "engineer", [Vector2i(5, 11), Vector2i(5, 12)])
	_units(m, 0, "light_infantry", [Vector2i(3, 7), Vector2i(3, 16), Vector2i(6, 8), Vector2i(6, 15)])
	_units(m, 0, "flamethrower", [Vector2i(3, 11)])
	return m

func _drone_recon() -> MapData:
	var m := _blank(38, 26)
	for r in [Rect2i(14, 5, 3, 1), Rect2i(20, 12, 1, 3), Rect2i(13, 19, 4, 1), Rect2i(24, 3, 1, 3),
			Rect2i(25, 20, 1, 3), Rect2i(17, 9, 1, 2)]:
		_rect(m, r, W)
	# Окопы обороны.
	for x in range(28, 34):
		_f(m, Vector2i(x, 8), T)
		_f(m, Vector2i(x, 17), T)
	_units(m, 1, "sniper", [Vector2i(30, 8), Vector2i(31, 17)])
	_units(m, 1, "marksman", [Vector2i(32, 8), Vector2i(29, 17)])
	_units(m, 1, "light_infantry", [Vector2i(34, 12), Vector2i(34, 13)])
	_units(m, 0, "drone_operator", [Vector2i(3, 11), Vector2i(3, 14)])
	_units(m, 0, "light_infantry", [Vector2i(2, 8), Vector2i(2, 17), Vector2i(5, 10), Vector2i(5, 15)])
	_units(m, 0, "heavy_infantry", [Vector2i(4, 12)])
	return m

func _crossfire() -> MapData:
	var m := _blank(32, 22)
	# Стена через всю карту с тремя проломами.
	for y in 22:
		if not [3, 4, 10, 11, 17, 18].has(y):
			_f(m, Vector2i(16, y), W)
	for c in [Vector2i(9, 6), Vector2i(9, 15), Vector2i(22, 6), Vector2i(22, 15),
			Vector2i(11, 10), Vector2i(20, 11)]:
		_f(m, c, S)
	for side in 2:
		var x0 := 2 if side == 0 else 29
		var dx := 1 if side == 0 else -1
		_units(m, side, "light_infantry", _col(x0, [4, 7, 10, 13, 16, 19]))
		_units(m, side, "machinegunner", [Vector2i(x0 + dx * 2, 8), Vector2i(x0 + dx * 2, 13)])
		_units(m, side, "assault", [Vector2i(x0 + dx * 3, 11)])
	return m

func _sniper_lanes() -> MapData:
	var m := _blank(40, 21)
	# Два ряда домов вдоль карты: стены с окнами, между ними три улицы.
	for row in [6, 14]:
		for x in range(6, 34):
			var c := Vector2i(x, row)
			_f(m, c, G if x % 5 == 0 else W)
		for x in [12, 20, 28]:
			_f(m, Vector2i(x, row), "")    # проходы между домами
	for side in 2:
		var x0 := 2 if side == 0 else 37
		_units(m, side, "sniper", [Vector2i(x0, 3), Vector2i(x0, 17)])
		_units(m, side, "marksman", [Vector2i(x0, 10)])
		_units(m, side, "light_infantry", [Vector2i(x0, 2), Vector2i(x0, 9), Vector2i(x0, 11), Vector2i(x0, 18)])
	return m

func _save(name: String, m: MapData) -> void:
	var path := "res://rl/maps/%s.json" % name
	var ok := m.save_to(ProjectSettings.globalize_path(path))
	print("%s %s (%d spawns)" % ["wrote" if ok else "FAILED", path, m.spawns.size()])
