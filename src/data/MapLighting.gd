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
## Chebyshev distance (capped at SPACING_CAP + 1) to the nearest wall lamp, kept up to date
## as lamps are placed: the spacing rule becomes one lookup instead of an area scan.
var _lamp_dist := PackedByteArray()
const SPACING_CAP := 5
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
	_lamp_dist.resize(n)
	_lamp_dist.fill(SPACING_CAP + 1)
	for fi: int in map.fixtures:
		for lamp: Array in map.fixtures[fi]:
			_mark_lamp(Vector2i(fi % g.w, fi / g.w) + N4[int(lamp[2])])
	for i in n:
		var fid := map.feature_id[i]
		var height := map.cover_height[i]
		var glass := MCF.is_glass(fid)
		var furniture := Furniture.is_furniture(fid)
		# Only structure stops light (LightOccluders.blocks_light): furniture never does.
		_opaque[i] = int(height >= MCF.WALL_HEIGHT and not glass and not furniture)
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
				if (x + y) % 6 != 0 or coverage[i] > 0.45: continue
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
			var want := _target(i)
			if not _eligible(c) or map.is_space[i] != 0 or map.cover_height[i] > 0 or coverage[i] >= want: continue
			var mount := _wall_near(c)
			# Spacing: a hut or corridor gets a few lamps, not one on every wall tile.
			if not mount.is_empty() and _spaced(mount[0] + N4[mount[1]], 3 if g._indoor[i] != 0 else 5):
				var id := _wall_kind(c) if want > MAINT_TARGET else "bulkhead_lamp"
				_place(mount[0], id, mount[1])
				if coverage[i] >= want: continue
			# Freestanding lamps only indoors (0.11): out on open ground they were free
			# cover nobody asked for. Town streets keep their streetlights above.
			if g._indoor[i] == 0: continue
			var floor_pos := _floor_near(c)
			if floor_pos != Vector2i(-1, -1):
				_place(floor_pos, _floor_kind(floor_pos, false), 0)
	_room_lights()
	_airlock_beacons()

## Wall spacing must not leave a small enclosed restroom dark merely because another
## lamp is close on the opposite side of its wall. Furniture does not exclude a room.
func _room_lights() -> void:
	var seen := {}
	for i in g.w * g.h:
		if seen.has(i) or g._indoor[i] == 0 or _opaque[i] != 0 or map.is_space[i] != 0:
			continue
		var queue: Array[int] = [i]
		seen[i] = true
		var head := 0
		var brightest := 0.0
		while head < queue.size():
			var at := queue[head]
			head += 1
			brightest = maxf(brightest, coverage[at])
			var c := Vector2i(at % g.w, at / g.w)
			for d: Vector2i in N4:
				var n := c + d
				if not map.in_bounds(n): continue
				var ni := n.y * g.w + n.x
				if seen.has(ni) or g._indoor[ni] == 0 or _opaque[ni] != 0 or map.is_space[ni] != 0: continue
				seen[ni] = true
				queue.append(ni)
		if brightest >= ROOM_TARGET: continue
		for at: int in queue:
			var c := Vector2i(at % g.w, at / g.w)
			var mount := _wall_near(c)
			if not mount.is_empty():
				_place(mount[0], "wall_lamp", mount[1])
				break

## How much light a tile should end up with (0.11). Rooms are lit, corridors dimmer and
## service tunnels mostly dark: pools of light, not a flat floodlit board. Outside, only
## walls carry lamps and open ground stays night.
const ROOM_TARGET := 0.4
const HALL_TARGET := 0.25
const MAINT_TARGET := 0.06
const OUTDOOR_TARGET := 0.1

## The renderer's light curve (LightManager shader): 1 - smoothstep(0, 1, d / range).
static func falloff(t: float) -> float:
	var k := clampf(t, 0.0, 1.0)
	return 1.0 - k * k * (3.0 - 2.0 * k)
func _target(i: int) -> float:
	if g._k.size() == g.w * g.h:
		match g._k[i]:
			MapGen.K_MAINT: return MAINT_TARGET
			MapGen.K_HALL, MapGen.K_DHALL: return HALL_TARGET
	if g._indoor[i] != 0: return ROOM_TARGET
	# Town streets have streetlights and the moon; lamps on the outside of buildings only
	# threw long diagonal shadows across the street (0.11 playtest). A station's outside is
	# the hull and space: nothing out there gets a lamp. An asteroid's surface does.
	return 0.0 if map.env in ["town", "field", "station"] else OUTDOOR_TARGET

## Amber service indicators beside about a third of the airlocks — small coloured pools
## that mark the doors in the dark. Deterministic per cell, like every other choice here.
func _airlock_beacons() -> void:
	if map.env == "town" or map.env == "field": return
	for i in map.feature_id.size():
		if map.feature_id[i] != MCF.FEATURE_AIRLOCK or posmod(i * 7919, 3) != 0: continue
		var door := Vector2i(i % g.w, i / g.w)
		for side: Vector2i in N4:
			var wall := door + side
			if not _eligible(wall): continue
			var wi := wall.y * g.w + wall.x
			if _mountable[wi] == 0: continue
			# Hang it on a free face over bare floor that wants light.
			for k in 4:
				var f: Vector2i = wall + N4[k]
				if _eligible(f) and _bare[f.y * g.w + f.x] != 0 and _face_ok(f) \
						and MapData.lamp_on(map.fixtures.get(wi, []), k).is_empty():
					_place(wall, "wall_beacon", k)
					break
			break

## No wall lamp already within r tiles (Chebyshev).
func _spaced(c: Vector2i, r: int) -> bool:
	return _lamp_dist[c.y * g.w + c.x] > r

func _mark_lamp(c: Vector2i) -> void:
	for y in range(maxi(0, c.y - SPACING_CAP), mini(g.h, c.y + SPACING_CAP + 1)):
		for x in range(maxi(0, c.x - SPACING_CAP), mini(g.w, c.x + SPACING_CAP + 1)):
			var d := maxi(absi(x - c.x), absi(y - c.y))
			var i := y * g.w + x
			if d < _lamp_dist[i]: _lamp_dist[i] = d

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
	# Houses and huts get household lamps, never street-style posts (0.11 playtest).
	if map.env in ["town", "field"]: return "floor_lamp"
	return "work_light"

## The nearest wall with a free face towards c: [wall, side], or [] (0.11: one lamp per side).
func _wall_near(c: Vector2i) -> Array:
	# Nearest first; equal-distance order matches the original row-major scan.
	for delta: Vector2i in SEARCH_OFFSETS:
		var q := c + delta
		if not _eligible(q) or _mountable[q.y * g.w + q.x] == 0: continue
		var side := _free_face(q, c)
		if side >= 0: return [q, side]
	return []

## The face of wall q a lamp can hang on to light c: the floor in front of it wants light,
## nothing hangs there yet, and c lies on that side, in sight of it. -1: none. The most
## square-on face wins, so a lamp never ends up on a face pressed against the next wall.
func _free_face(q: Vector2i, c: Vector2i) -> int:
	var lamps: Array = map.fixtures.get(q.y * g.w + q.x, [])
	var best := -1
	var best_dot := 0
	for k in 4:
		var n: Vector2i = N4[k]
		var d := (c.x - q.x) * n.x + (c.y - q.y) * n.y
		var f := q + n
		if d <= best_dot or not _face_ok(f) or not MapData.lamp_on(lamps, k).is_empty(): continue
		if not _line_clear(f, c): continue
		best = k
		best_dot = d
	return best

## Floor in front of a wall lamp: open, not vacuum, and somewhere lamps belong — never the
## outside of a station (0.11: nothing lights up space there).
func _face_ok(f: Vector2i) -> bool:
	if not _eligible(f): return false
	var i := f.y * g.w + f.x
	return _opaque[i] == 0 and map.is_space[i] == 0 and _target(i) > 0.0

func _floor_near(c: Vector2i) -> Vector2i:
	# Prefer a fixture slightly into the unlit region, to avoid one at every edge.
	var best := Vector2i(-1, -1)
	var score := -INF
	for delta: Vector2i in SEARCH_OFFSETS:
		var value := -float(delta.length_squared()) * 0.03
		if value <= score: break # coverage is non-negative: no later cell can win.
		var q := c + delta
		if not _floor_ok(q, true) or not _line_clear(q, c): continue
		value -= coverage[q.y * g.w + q.x]
		if value > score:
			score = value
			best = q
	return best

func _floor_ok(c: Vector2i, indoor := false) -> bool:
	if not _eligible(c): return false
	var i := c.y * g.w + c.x
	if _bare[i] == 0 or (indoor and g._indoor[i] == 0): return false
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
		map.fixtures[i] = MapData.with_lamp(map.fixtures.get(i, []), [id, Furniture.durability_of(id), turn, 0])
		_mark_lamp(c + N4[turn])
	else:
		# A standing lamp is furniture: it takes the floor but never blocks light.
		map.feature_id[i] = id
		map.cover_height[i] = Furniture.height_of(id)
		_bare[i] = 0
		_open[i] = 0
	_illuminate(c, id, turn)

func _illuminate(c: Vector2i, id: String, turn: int = 0) -> void:
	if _opaque.is_empty(): _index_geometry()
	var def: Dictionary = Furniture.DEFS[id]
	var origin := Vector2(c) + Vector2.ONE * 0.5
	if Furniture.is_wall_light(id):
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
			coverage[y * g.w + x] += float(def.light_energy) * falloff(d)

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
