class_name DecalMemory
extends RefCounted

## Косметика боя, какой её помнит ОДИН зритель под туманом (0.11.3, просьба игрока: «laser
## markings, glass shards and bullet casings — all decals — shouldn't be visible in the fog
## of war until actually seen by your unit»). Тот же принцип, что у памяти доски
## (Main._board_memory): в обзоре — то, что лежит сейчас; вне обзора — то, что зритель
## видел там в последний раз. Гильза, упавшая в темноте, появится, только когда туда
## посмотрят; лужа, сгоревшая в темноте, останется, пока туда не посмотрят.
##
## view — FxDecals с отобранной косметикой: плитки (TerrainTiles.sync_decals) и дальний
## план читают его вместо живого слоя. Живой слой здесь только читается.

const C := FxDecals.DECAL_CHUNK

var view := FxDecals.new()
## Куски, чей запомненный набор сменился, — для дальнего плана. Плитки берут свой
## view.decal_dirty, и забирают его они; этот — отдельно, его забирает Main.
var lod_dirty: Dictionary = {}
var _reset := -1
var _gore_done := 0
var _props_done := 0
var _ground := -1
## Следы гусениц и лазера, разрезанные по границам клеток: кусок — [линия, t0, t1, клетка,
## вид]. Живые куски — по клеткам, дописываются только новыми линиями (списки следов растут
## с конца, пока FxDecals не срежет их по потолку — тогда всё заново). known — что зритель
## помнит, тоже по клеткам; по линиям — то же самое, чтобы склеивать куски одной линии.
var _live_lines: Dictionary = {}    # клетка -> [кусок]
var _known_lines: Dictionary = {}   # клетка -> [кусок]
var _line_known: Dictionary = {}    # линия -> [кусок]
var _line_segs: Dictionary = {}     # линия -> [отрезок для плиток]
var _lines_dirty: Dictionary = {}   # линии, чьи отрезки надо собрать заново
var _lists: Array = [null, null]    # какие массивы следов разобраны (по ссылке)
var _split: Array = [0, 0]          # сколько линий каждого вида уже разрезано

## Память заводится картиной на момент создания, как и копия доски: в начале боя
## косметики нет вовсе, а в загруженной партии зрителю достаётся то, что уже лежит.
func _init(live: FxDecals) -> void:
	view.gore = live.gore.duplicate()
	view.props = live.props.duplicate()
	view._reindex()
	_reset = live.decal_reset
	_gore_done = live.gore.size()
	_props_done = live.props.size()
	_ground = live.ground_version
	_split_new(live)
	for c: Vector2i in _live_lines:
		_set_known(c, _live_lines[c])
	_emit_lines()

## Довести память до живого слоя. visible — обзор зрителя ({Vector2i: true}); changed —
## плоские индексы клеток, чья видимость сменилась (Resolver.take_vis_changes), null —
## «сменилось всё» (новый зритель, перестроенный обзор).
func update(live: FxDecals, visible: Dictionary, changed: Variant, gw: int) -> void:
	var touch := {}
	var full: bool = changed == null or _reset != live.decal_reset
	if full:
		# ponytail: сброс (пожар, потолок) сверяет все куски — ~0.2 с на 68k частиц у
		# потолка; если станет заметно, брать из FxDecals список задетых пожаром кусков.
		_reset = live.decal_reset
		for cc: Vector2i in live.by_chunk:
			touch[cc] = true
		for cc: Vector2i in view.by_chunk:
			touch[cc] = true
	else:
		# Новое оседает только в конец списков (до сброса), поэтому смотрим лишь хвост.
		for pair: Array in [[live.gore, _gore_done], [live.props, _props_done]]:
			var list: Array = pair[0]
			for i in range(int(pair[1]), list.size()):
				touch[_chunk(list[i])] = true
		for k: int in changed:
			touch[Vector2i((k % gw) / C, (k / gw) / C)] = true
	_gore_done = live.gore.size()
	_props_done = live.props.size()
	for cc: Vector2i in touch:
		_rebuild(cc, live, visible)
	if full or _ground != live.ground_version or not (changed as Array).is_empty():
		_update_lines(live, visible, null if full else changed, gw)

## Кусок cc заново: запомненное вне обзора плюс живое в обзоре.
func _rebuild(cc: Vector2i, live: FxDecals, visible: Dictionary) -> void:
	var old: Array = view.by_chunk.get(cc, [])
	var kept: Array = []
	for p: Dictionary in old:
		if not visible.has(_cell(p)):
			kept.append(p)
	for p: Dictionary in live.by_chunk.get(cc, []):
		if visible.has(_cell(p)):
			kept.append(p)
	if _same(old, kept):
		return
	if kept.is_empty():
		view.by_chunk.erase(cc)
	else:
		view.by_chunk[cc] = kept
	lod_dirty[cc] = true
	# Частица у края куска видна и в соседнем — плитки пересобирают и его.
	for y in range(-1, 2):
		for x in range(-1, 2):
			view.decal_dirty[cc + Vector2i(x, y)] = true

func _update_lines(live: FxDecals, visible: Dictionary, changed: Variant, gw: int) -> void:
	var cells := {}
	if _ground != live.ground_version:
		_ground = live.ground_version
		var reset := _split_new(live)
		if reset:
			changed = null
		else:
			cells = _new_cells
	if changed == null:
		for c: Vector2i in _live_lines:
			cells[c] = true
		for c: Vector2i in _known_lines:
			cells[c] = true
	else:
		for k: int in changed:
			cells[Vector2i(k % gw, k / gw)] = true
	for c: Vector2i in cells:
		if visible.has(c):
			_set_known(c, _live_lines.get(c, []))
	if not _lines_dirty.is_empty():
		_emit_lines()

## Клетка c на виду: помнить в ней ровно её живые куски.
func _set_known(c: Vector2i, pieces: Array) -> void:
	var old: Array = _known_lines.get(c, [])
	if _same(old, pieces):
		return
	for piece: Array in old:
		var line: Dictionary = piece[0]
		var mine: Array = _line_known.get(line, [])
		mine.erase(piece)
		if mine.is_empty():
			_line_known.erase(line)
		_lines_dirty[line] = true
	for piece: Array in pieces:
		var line: Dictionary = piece[0]
		if not _line_known.has(line):
			_line_known[line] = []
		(_line_known[line] as Array).append(piece)
		_lines_dirty[line] = true
	if pieces.is_empty():
		_known_lines.erase(c)
	else:
		_known_lines[c] = pieces.duplicate()   # живой список клетки ещё будет дописываться

## Запомненные куски — обратно в линии для плиток: куски одной линии, идущие подряд,
## склеиваются, и полностью увиденная линия выходит ровно той же, что в живом слое
## (иначе полупрозрачные концы кусков темнили бы след точками на каждом стыке).
## Пересобираются только тронутые линии; списки для плиток — сцеплением готовых.
func _emit_lines() -> void:
	for line: Dictionary in _lines_dirty:
		var pieces: Array = _line_known.get(line, [])
		if pieces.is_empty():
			_line_segs.erase(line)
			continue
		pieces.sort_custom(func(a: Array, b: Array) -> bool: return float(a[1]) < float(b[1]))
		var a: Vector2 = line["from"]
		var b: Vector2 = line["to"]
		var segs: Array = [int(pieces[0][4])]   # первым — вид линии
		var t0: float = pieces[0][1]
		var t1: float = pieces[0][2]
		for i in range(1, pieces.size()):
			if float(pieces[i][1]) == t1:
				t1 = pieces[i][2]
				continue
			segs.append({"from": a.lerp(b, t0), "to": a.lerp(b, t1)})
			t0 = pieces[i][1]
			t1 = pieces[i][2]
		segs.append({"from": a.lerp(b, t0), "to": a.lerp(b, t1)} if t0 > 0.0 or t1 < 1.0 else line)
		_line_segs[line] = segs
	_lines_dirty.clear()
	view.track_marks = []
	view.laser_lines = []
	for segs: Array in _line_segs.values():
		var out: Array = view.track_marks if int(segs[0]) == 0 else view.laser_lines
		out.append_array(segs.slice(1))
	view.ground_version += 1

## Дорезать линии, появившиеся с прошлого раза. FxDecals дописывает следы в конец, а на
## потолке отрезает голову новым массивом: тогда куски отрезанных линий выбрасываются, а
## остальные остаются. true — списки заменены целиком (очистка, загрузка): всё заново.
var _new_cells: Dictionary = {}      # клетки, где живые куски сменились
var _pieces_of: Array = [[], []]     # по видам: куски j-й линии списка
func _split_new(live: FxDecals) -> bool:
	_new_cells = {}
	var reset := false
	var drops := [0, 0]
	for kind in 2:
		var list: Array = live.track_marks if kind == 0 else live.laser_lines
		var old: Variant = _lists[kind]
		var pieces_of: Array = _pieces_of[kind]
		if old == null:
			reset = true
		elif is_same(list, old):
			# Тот же массив: очищен на месте (clear) — и, может, уже заполнен заново.
			if list.size() < int(_split[kind]) or (not pieces_of.is_empty()
					and not is_same(list[0], pieces_of[0][0][0])):
				reset = true
		else:
			drops[kind] = _head_drop(old, list)
			if drops[kind] < 0:
				reset = true
	if reset:
		_live_lines = {}
		_split = [0, 0]
		_pieces_of = [[], []]
		drops = [0, 0]
	for kind in 2:
		var list: Array = live.track_marks if kind == 0 else live.laser_lines
		var gone: Array = (_pieces_of[kind] as Array).slice(0, drops[kind])
		for pieces: Array in gone:
			for piece: Array in pieces:
				var c: Vector2i = piece[3]
				var here: Array = _live_lines.get(c, [])
				here.erase(piece)
				if here.is_empty():
					_live_lines.erase(c)
				_new_cells[c] = true
		_pieces_of[kind] = (_pieces_of[kind] as Array).slice(drops[kind])
		_split[kind] = int(_split[kind]) - drops[kind]
		_lists[kind] = list
		for j in range(int(_split[kind]), list.size()):
			(_pieces_of[kind] as Array).append(_split_line(list[j], kind))
		_split[kind] = list.size()
	return reset

## Сколько линий срезано с головы старого списка, чтобы получить новый (−1 — не срез).
static func _head_drop(old: Array, list: Array) -> int:
	if is_same(old, list):
		return 0
	if list.is_empty():
		return -1
	for i in old.size():
		if is_same(old[i], list[0]):
			return i
	return -1

## Линия — кусками по клеткам (точно по пересечениям с сеткой).
func _split_line(line: Dictionary, kind: int) -> Array:
	var a: Vector2 = line["from"]
	var b: Vector2 = line["to"]
	var ts: Array[float] = [0.0, 1.0]
	for axis in 2:
		var lo := minf(a[axis], b[axis])
		var hi := maxf(a[axis], b[axis])
		if hi - lo <= 0.0:
			continue
		for g in range(floori(lo) + 1, ceili(hi)):
			ts.append((float(g) - a[axis]) / (b[axis] - a[axis]))
	ts.sort()
	var mine: Array = []
	for i in ts.size() - 1:
		if ts[i + 1] <= ts[i]:
			continue
		var mid := a.lerp(b, (ts[i] + ts[i + 1]) * 0.5)
		var cell := Vector2i(floori(mid.x), floori(mid.y))
		var piece := [line, ts[i], ts[i + 1], cell, kind]
		if not _live_lines.has(cell):
			_live_lines[cell] = []
		(_live_lines[cell] as Array).append(piece)
		_new_cells[cell] = true
		mine.append(piece)
	return mine

static func _cell(p: Dictionary) -> Vector2i:
	var pos: Vector2 = p["pos"]
	return Vector2i(floori(pos.x), floori(pos.y))

static func _chunk(p: Dictionary) -> Vector2i:
	return _cell(p) / C

## Те же частицы в том же порядке — по ссылке, без сравнения содержимого.
static func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not is_same(a[i], b[i]):
			return false
	return true
