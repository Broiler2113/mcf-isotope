class_name HudIcons
extends RefCounted

## Pixel icons for the battle's top-left buttons (issues-12 #15): a pencil (Drawing), an open
## book (Manual) and a bug (Report a Bug). Drawn here in the kit's neutral greys with a dark
## outline and a shaded lower-right edge, like the bevelled buttons they sit on — built in
## code, so a stale import cache cannot lose them.

const SIZE := 16
const INK := Color(0.09, 0.1, 0.11)
const LIGHT := Color(0.86, 0.87, 0.89)
const SHADE := Color(0.6, 0.62, 0.66)
const WOOD := Color(0.85, 0.7, 0.48)
const LEAD := Color(0.25, 0.26, 0.28)
const ERASER := Color(0.78, 0.45, 0.42)

static var _cache := {}

static func texture(name: String) -> Texture2D:
	if not _cache.has(name):
		_cache[name] = ImageTexture.create_from_image(image(name))
	return _cache[name]

static func image(name: String) -> Image:
	var fill := {}   # Vector2i -> Color: the shapes, before outline and shade
	var ink := {}    # thin strokes drawn in ink over everything (legs, antennae)
	match name:
		"draw": _pencil(fill)
		"manual": _book(fill)
		"bug": _bug(fill, ink)
		"soldier": _soldier(fill)
		"tank": _tank(fill)
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for p: Vector2i in fill:
		var c: Color = fill[p]
		# Lower-right edge in shade: light from the top left, as on the kit's bevels.
		if c == LIGHT and (not fill.has(p + Vector2i.RIGHT) or not fill.has(p + Vector2i.DOWN)):
			c = SHADE
		img.set_pixelv(p, c)
	for y in SIZE:
		for x in SIZE:
			var p := Vector2i(x, y)
			if fill.has(p): continue
			for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if fill.has(p + d):
					img.set_pixelv(p, INK)
					break
	for p: Vector2i in ink:
		if Rect2i(0, 0, SIZE, SIZE).has_point(p): img.set_pixelv(p, INK)
	return img

## A pencil lying corner to corner, point down-left.
static func _pencil(fill: Dictionary) -> void:
	var tip := Vector2(3.0, 13.0)
	var top := Vector2(13.2, 2.8)
	var axis := top - tip
	for y in SIZE:
		for x in SIZE:
			var p := Vector2(x + 0.5, y + 0.5)
			var t := clampf((p - tip).dot(axis) / axis.length_squared(), -1.0, 2.0)
			if t < 0.0 or t > 1.0: continue
			var d := (p - (tip + axis * t)).length()
			var c := Color(0, 0, 0, 0)
			if t < 0.3:
				if d <= 2.2 * t / 0.3 + 0.35: c = LEAD if t < 0.12 else WOOD
			elif d <= 2.2:
				c = LIGHT if t < 0.78 else (SHADE if t < 0.86 else ERASER)
			if c.a > 0.0: fill[Vector2i(x, y)] = c

## An open book seen from the front: two pages of lines on a dark cover.
static func _book(fill: Dictionary) -> void:
	for y in range(3, 12):
		for x in range(1, 15):
			if x == 7 or x == 8: continue
			fill[Vector2i(x, y)] = LIGHT
	for y in [5, 7, 9]:
		for x in range(2, 6): fill[Vector2i(x, y)] = SHADE
		for x in range(10, 14): fill[Vector2i(x, y)] = SHADE
	for x in range(2, 14): fill[Vector2i(x, 12)] = LEAD
	fill[Vector2i(7, 12)] = LEAD
	fill[Vector2i(8, 12)] = LEAD

## A soldier from the front: helmet, head, shoulders and body, legs apart (fix-12 #12).
static func _soldier(fill: Dictionary) -> void:
	for y in SIZE:
		for x in SIZE:
			var p := Vector2(x + 0.5, y + 0.5)
			if p.y < 4.6 and (p - Vector2(8.0, 4.6)).length() <= 3.2: fill[Vector2i(x, y)] = LEAD   # helmet
			elif (p - Vector2(8.0, 5.4)).length() <= 2.2: fill[Vector2i(x, y)] = WOOD               # face
			elif p.y >= 7.5 and p.y < 12.0 and absf(p.x - 8.0) <= 3.6 - (p.y - 7.5) * 0.25: fill[Vector2i(x, y)] = LIGHT
			elif p.y >= 12.0 and p.y < 15.5 and absf(p.x - 8.0) >= 0.7 and absf(p.x - 8.0) <= 2.6: fill[Vector2i(x, y)] = SHADE

## A tank from the side: tracks, hull, turret and gun (fix-12 #12).
static func _tank(fill: Dictionary) -> void:
	for x in range(1, 15):
		for y in range(11, 14): fill[Vector2i(x, y)] = LEAD
	for x in range(2, 14):
		for y in range(8, 11): fill[Vector2i(x, y)] = LIGHT
	for x in range(5, 10):
		for y in range(5, 8): fill[Vector2i(x, y)] = LIGHT
	for x in range(10, 15): fill[Vector2i(x, 6)] = SHADE

## A beetle from above: shell split down the middle, head, six legs and two feelers.
static func _bug(fill: Dictionary, ink: Dictionary) -> void:
	for y in SIZE:
		for x in SIZE:
			var p := Vector2(x + 0.5, y + 0.5)
			if pow((p.x - 8.0) / 3.6, 2) + pow((p.y - 9.8) / 4.4, 2) <= 1.0:
				fill[Vector2i(x, y)] = LIGHT
			elif (p - Vector2(8.0, 4.4)).length() <= 2.0:
				fill[Vector2i(x, y)] = SHADE
	for y in range(7, 14): ink[Vector2i(8, y)] = true
	for side: int in [-1, 1]:
		for leg: Array in [[Vector2(3.6, 8.0), Vector2(1.0, 6.4)], [Vector2(3.4, 10.4), Vector2(0.6, 10.6)],
				[Vector2(3.8, 12.6), Vector2(1.4, 14.6)], [Vector2(6.8, 2.6), Vector2(5.0, 0.4)]]:
			var a: Vector2 = leg[0]
			var b: Vector2 = leg[1]
			if side > 0:
				a = Vector2(16.0 - a.x, a.y)
				b = Vector2(16.0 - b.x, b.y)
			for i in 9:
				var q := a.lerp(b, i / 8.0)
				ink[Vector2i(floori(q.x), floori(q.y))] = true
