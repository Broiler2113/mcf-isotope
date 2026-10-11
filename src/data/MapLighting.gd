class_name MapLighting
extends RefCounted

## Coverage pass, after furniture: lights follow actual walls and paths. It uses
## its own deterministic choices, never the combat RNG or the lighting setting.
static func populate(gen: MapGen) -> void:
	if int(gen.opt.get("furniture", MapFurnish.DEFAULT_DENSITY)) <= 0: return
	var plan := MapLighting.new()
	plan.g = gen
	plan.map = gen.m
	plan.coverage.resize(gen.w * gen.h)
	plan._populate()

var g: MapGen
var map: MapData
var coverage := PackedFloat32Array()
var _opaque := PackedByteArray()
var _mountable := PackedByteArray()
var _bare := PackedByteArray()
var _open := PackedByteArray()
static var SEARCH_OFFSETS: Array[Vector2i] = _search_offsets()
static func _search_offsets() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(-4, 5):
		for x in range(-4, 5): out.append(Vector2i(x, y))
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.length_squared() != b.length_squared(): return a.length_squared() < b.length_squared()
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	return out

const N4 := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

func _index_geometry() -> void:
	# The generator already owns flat terrain arrays. Constructing a simulation
	# grid here would allocate tens of thousands of cells and invalidate journals.
	var n := g.w * g.h
	_opaque.resize(n)
	_mountable.resize(n)
	_bare.resize(n)
	_open.resize(n)
	for i in n:
		var fid := map.feature_id[i]
		var height := map.cover_height[i]
		var glass := MCF.is_glass(fid)
		var furniture := Furniture.is_furniture(fid)
		_opaque[i] = int(height > 0 and not glass and fid != MCF.FEATURE_TRENCH)
		_mountable[i] = int(height >= MCF.WALL_HEIGHT and not glass and not furniture and fid != MCF.FEATURE_AIRLOCK)
		_bare[i] = int(map.is_space[i] == 0 and height == 0 and fid == "")
		_open[i] = int(map.is_space[i] == 0 and height < MCF.WALL_HEIGHT and not furniture and fid not in [MCF.FEATURE_DRONE_STATION, MCF.FEATURE_HEDGEHOG])

func _eligible(c: Vector2i) -> bool:
	return g._core.has_point(c) and g._in_f(c)

func _populate() -> void:
	_index_geometry()
	# Existing glowing furniture contributes, but does not replace room illumination.
	for i in map.feature_id.size():
		if Furniture.emits_light(map.feature_id[i]): _illuminate(Vector2i(i % g.w, i / g.w), map.feature_id[i])
	# Streetlights line the verge, never the road surface or a deployment lane.
	if map.env == "town":
		for y in range(2, g.h - 2):
			for x in range(2, g.w - 2):
				var c := Vector2i(x, y)
				var i := y * g.w + x
				if not _eligible(c) or g._street[i] != 0 or g._indoor[i] != 0: continue
				if (x + y) % 9 != 0 or coverage[i] > 0.28: continue
				for direction: Vector2i in N4:
					var n := c + direction
					if g._street[n.y * g.w + n.x] != 0 and _floor_ok(c):
						_place(c, "streetlight", 0)
						break
	# Every playable floor is considered, including deployment zones and service
	# corridors. A lamp may shine into a zone, but no floor fixture occupies it.
	for y in g.h:
		for x in g.w:
			var c := Vector2i(x, y)
			var i := y * g.w + x
			if not _eligible(c) or map.is_space[i] != 0 or map.cover_height[i] > 0 or coverage[i] >= 0.18: continue
			var wall := _wall_near(c)
			if wall != Vector2i(-1, -1):
				var id := _wall_kind(c)
				_place(wall, id, _facing(wall, c))
				if coverage[i] >= 0.18: continue
			var floor_pos := _floor_near(c)
			if floor_pos != Vector2i(-1, -1):
				var outdoors := g._indoor[floor_pos.y * g.w + floor_pos.x] == 0
				var id := _floor_kind(floor_pos, outdoors)
				_place(floor_pos, id, 0)

func _wall_kind(c: Vector2i) -> String:
	var n := posmod(c.x * 11 + c.y * 7, 3)
	match map.env:
		"station": return ["wall_strip", "ceiling_lamp", "wall_lamp"][n]
		"bunker": return ["bulkhead_lamp", "wall_strip", "bulkhead_lamp"][n]
		"asteroid": return ["bulkhead_lamp", "ceiling_lamp", "wall_strip"][n]
		"town": return ["wall_lamp", "wall_lamp", "ceiling_lamp"][n]
	return "bulkhead_lamp"

func _floor_kind(c: Vector2i, outdoors: bool) -> String:
	if outdoors:
		match map.env:
			"town": return "streetlight" if (c.x + c.y) % 3 else "bollard_light"
			"field", "asteroid": return "floodlight"
		return "work_light"
	if map.env == "town": return "floor_lamp" if (c.x + c.y) % 2 else "desk_lamp"
	return "work_light"

func _wall_near(c: Vector2i) -> Vector2i:
	# Nearest first; equal-distance order matches the original row-major scan.
	for delta: Vector2i in SEARCH_OFFSETS:
		var q := c + delta
		if not _eligible(q): continue
		var i := q.y * g.w + q.x
		if _mountable[i] == 0 or map.fixtures.has(i): continue
		if _line_clear(q, c): return q
	return Vector2i(-1, -1)

func _floor_near(c: Vector2i) -> Vector2i:
	# Prefer a fixture slightly into the unlit region, to avoid one at every edge.
	var best := Vector2i(-1, -1)
	var score := -INF
	for delta: Vector2i in SEARCH_OFFSETS:
		var value := -float(delta.length_squared()) * 0.03
		if value <= score: break # coverage is non-negative: no later cell can win.
		var q := c + delta
		if not _floor_ok(q) or not _line_clear(q, c): continue
		value -= coverage[q.y * g.w + q.x]
		if value > score:
			score = value
			best = q
	return best

func _floor_ok(c: Vector2i) -> bool:
	if not _eligible(c): return false
	var i := c.y * g.w + c.x
	if _bare[i] == 0: return false
	if g._zone[i] >= 0 or g._keep[i] != 0 or g._street[i] != 0: return false
	# Leave doors, one-tile passages and their approaches clear.
	var free := 0
	for direction: Vector2i in N4:
		var q := c + direction
		var ni := q.y * g.w + q.x
		if map.feature_id[ni] == MCF.FEATURE_AIRLOCK: return false
		if _bare[ni] != 0: free += 1
	if free < 3: return false
	# One connected arc of empty neighbours is a local proof that placing this
	# object cannot disconnect a path. Also leave the mirror seam untouched.
	var ring: Array[bool] = []
	for delta: Vector2i in MapFurnish.RING:
		var q := c + delta
		if not _eligible(q): return false
		var ni := q.y * g.w + q.x
		if map.feature_id[ni] == MCF.FEATURE_AIRLOCK: return false
		ring.append(_open[ni] != 0)
	var transitions := 0
	for k in 8:
		if ring[k] != ring[(k + 1) % 8]: transitions += 1
	return transitions <= 2

func _place(c: Vector2i, id: String, turn: int) -> void:
	var i := c.y * g.w + c.x
	if Furniture.is_wall_light(id):
		map.fixtures[i] = [id, Furniture.durability_of(id), turn]
	else:
		map.feature_id[i] = id
		map.cover_height[i] = Furniture.height_of(id)
		_opaque[i] = 1
		_bare[i] = 0
		_open[i] = 0
	_illuminate(c, id, turn)

func _illuminate(c: Vector2i, id: String, turn: int = 0) -> void:
	if _opaque.is_empty(): _index_geometry()
	var def: Dictionary = Furniture.DEFS[id]
	var origin := Vector2(c) + Vector2.ONE * 0.5
	if Furniture.is_wall_light(id) and id != "ceiling_lamp":
		origin += Vector2(N4[turn]) * 0.55
	var ray_start := Vector2i(origin.floor())
	var radius := float(def.light_range)
	var r := ceili(radius)
	for y in range(maxi(0, c.y - r), mini(g.h, c.y + r + 1)):
		for x in range(maxi(0, c.x - r), mini(g.w, c.x + r + 1)):
			var i := y * g.w + x
			if _opaque[i] != 0 or map.is_space[i] != 0: continue
			var q := Vector2i(x, y)
			var d := (Vector2(q) + Vector2.ONE * 0.5 - origin).length() / radius
			if d >= 1 or not _line_clear(ray_start, q): continue
			# Matches the radial texture's color * alpha falloff.
			coverage[y * g.w + x] += float(def.light_energy) * (1 - d) * (1 - d)

func _line_clear(a: Vector2i, b: Vector2i) -> bool:
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := signi(b.x - a.x)
	var sy := signi(b.y - a.y)
	var error := dx + dy
	var c := a
	while c != b:
		var e := 2 * error
		if e >= dy:
			error += dy
			c.x += sx
		if e <= dx:
			error += dx
			c.y += sy
		if c == b: break
		if _opaque[c.y * g.w + c.x] != 0: return false
	return true

static func _facing(wall: Vector2i, target: Vector2i) -> int:
	var d := target - wall
	if absi(d.x) > absi(d.y): return 1 if d.x > 0 else 3
	return 2 if d.y > 0 else 0
