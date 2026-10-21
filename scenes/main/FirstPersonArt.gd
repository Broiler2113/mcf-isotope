class_name FirstPersonArt
extends RefCounted

## Pictures made for the 3D view (owner: the board's top-down art looked wrong on upright
## faces). Every wall material gets a side texture at true scale — 32 pixels a metre, the
## full 2.3 m height in one picture — and a service's accent runs along it as a level band.
## Doors get leaves of their own. All drawn here in code, cached by kind.

const PX := 32                                   # pixels per metre
const H := 74                                    # 2.3 m
static var _cache := {}

## What a wall cell is made of, as the battle screen would draw it.
static func wall_kind(grid: Grid, at: Vector2i, env: String) -> String:
	var c := grid.cell_fast(at.x, at.y)
	match c.feature_id:
		MCF.FEATURE_WOOD_WALL: return "wood"
		MCF.FEATURE_ARMOR_WALL, MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN: return "armor"
		MCF.FEATURE_LDF: return "ldf"
		MCF.FEATURE_SOIL, MCF.FEATURE_DIRT_PILE: return "soil"
		MCF.FEATURE_CORPSE_WALL: return "corpse"
		MCF.FEATURE_SANDBAG_WALL: return "sandbag"
	var look := MCF.wall_look_tile(grid.look_at(at.x, at.y))
	match look:
		"wall_brick": return "brick"
		"wall_stucco": return "stucco"
		"wall_block": return "block"
		"wall_station": return "station"
	match env:
		"station": return "station"
		"asteroid": return "rock"
		"bunker": return "soil"
		"field": return "block"
	return "brick"

static func accent_of(grid: Grid, at: Vector2i) -> Color:
	var i := at.y * grid.width + at.x
	var a := int(grid.wall_accent[i]) if i < grid.wall_accent.size() else 0
	return MCF.ACCENT_COLORS[a] if a > 0 and a < MCF.ACCENT_COLORS.size() else Color(0, 0, 0, 0)

## The side texture of a wall kind, 1 m wide (it repeats along the wall) and 2.3 m tall.
static func wall_texture(kind: String, accent: Color) -> ImageTexture:
	var key := "wall|%s|%s" % [kind, accent.to_html()]
	if _cache.has(key):
		return _cache[key]
	var img := Image.create(PX, H, false, Image.FORMAT_RGBA8)
	for y in H:
		for x in PX:
			img.set_pixel(x, y, _wall_px(kind, x, y))
	if accent.a > 0.0:
		# A level band at hand height with a darker edge above and below.
		for y in range(H - 40, H - 35):
			for x in PX:
				var edge := y == H - 40 or y == H - 36
				img.set_pixel(x, y, accent.darkened(0.35) if edge else accent)
	img.generate_mipmaps()   # far walls average out instead of shimmering
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex

static func _n(x: int, y: int, s: float = 1.0) -> float:
	return fposmod(sin(x * 12.9898 * s + y * 78.233) * 43758.5453, 1.0)

## One pixel of a wall's side. y = 0 is the top (2.3 m), y = H - 1 the floor.
static func _wall_px(kind: String, x: int, y: int) -> Color:
	var from_floor := H - 1 - y
	var n := _n(x, y)
	match kind:
		"brick":
			# Running bond: 8×4 px bricks (25×12 cm), 1 px mortar, every other course offset.
			var row := from_floor / 4
			var bx := (x + (4 if row % 2 == 1 else 0)) % 8
			if from_floor % 4 == 3 or bx == 7:
				return Color(0.5, 0.48, 0.45)
			var tone := _n(row, (x + (4 if row % 2 == 1 else 0)) / 8, 3.1)
			var base := Color(0.42, 0.15, 0.1).lerp(Color(0.52, 0.22, 0.15), tone)
			return base.darkened(0.06 * n)
		"stucco":
			if from_floor < 8:
				return Color(0.42, 0.4, 0.38).darkened(n * 0.08)   # plinth
			if from_floor == 8:
				return Color(0.3, 0.29, 0.28)
			return Color(0.84, 0.8, 0.72).darkened(n * 0.07)
		"block":
			# Cinder blocks, 12×6 px (40×20 cm), stack bond offset by half.
			var row2 := from_floor / 6
			var bx2 := (x + (6 if row2 % 2 == 1 else 0)) % 12
			if from_floor % 6 == 5 or bx2 == 11:
				return Color(0.42, 0.42, 0.42)
			return Color(0.6, 0.6, 0.58).darkened(n * 0.12)
		"station":
			# Riveted hull panels between a dark kick plate and a trim strip under the ceiling.
			if from_floor < 5:
				return Color(0.2, 0.21, 0.23).lightened(n * 0.05)
			if y < 4:
				return Color(0.3, 0.32, 0.35)
			var py := (from_floor - 5) % 22
			if x == 0 or x == 16 or py == 0:
				return Color(0.24, 0.25, 0.28)
			if (x == 3 or x == 13 or x == 19 or x == 29) and (py == 3 or py == 19):
				return Color(0.72, 0.74, 0.78)
			return Color(0.64, 0.66, 0.7).darkened(n * 0.06 + (0.05 if x > 16 else 0.0))
		"armor":
			if x % 16 == 0 or from_floor % 24 == 0:
				return Color(0.16, 0.17, 0.18)
			if (x % 16 == 3 or x % 16 == 13) and (from_floor % 24 == 4 or from_floor % 24 == 20):
				return Color(0.55, 0.57, 0.6)
			return Color(0.32, 0.34, 0.36).darkened(n * 0.1)
		"wood":
			var plank := x / 6
			if x % 6 == 0:
				return Color(0.25, 0.15, 0.08)
			var grain := 0.06 * sin(from_floor * 0.7 + plank * 2.3) + _n(plank, 0, 2.0) * 0.1
			return Color(0.55, 0.35, 0.18).darkened(grain + n * 0.04)
		"soil":
			var band := 0.08 * sin(from_floor * 0.45 + x * 0.05) + n * 0.12
			return Color(0.42, 0.32, 0.22).darkened(band)
		"rock":
			var strata := 0.1 * sin(from_floor * 0.3 + sin(x * 0.4) * 1.5) + n * 0.15
			return Color(0.38, 0.36, 0.36).darkened(strata)
		"sandbag":
			var row3 := from_floor / 5
			var sx := (x + (5 if row3 % 2 == 1 else 0)) % 10
			if from_floor % 5 == 4 or sx == 9:
				return Color(0.35, 0.31, 0.22)
			return Color(0.66, 0.6, 0.44).darkened(n * 0.1)
		"corpse":
			return Color(0.4, 0.12, 0.1).darkened(n * 0.25)
		"ldf":
			var hex := (x + from_floor) % 8 == 0 or (x - from_floor + 64) % 8 == 0
			return Color(0.45, 0.85, 1.0, 1.0) if hex else Color(0.12, 0.35, 0.5, 1.0).lightened(n * 0.1)
	return Color(0.5, 0.5, 0.5).darkened(n * 0.1)

## A door leaf, 0.5 m wide and 2.1 m tall: a riveted metal slab with a window and hazard
## chevrons at the foot (station, bunker, asteroid) or a wooden door with panels and a handle.
static func door_texture(style: String, accent: Color) -> ImageTexture:
	var key := "door|%s|%s" % [style, accent.to_html()]
	if _cache.has(key):
		return _cache[key]
	var w := 16
	var h := 68
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var n := _n(x, y, 1.7)
			var c: Color
			if style == "wood":
				c = Color(0.48, 0.3, 0.16).darkened(0.06 * sin(y * 0.8 + x * 0.3) + n * 0.05)
				var panel := (y > 6 and y < 30 or y > 36 and y < 62) and x > 2 and x < 13
				if panel and (x == 3 or x == 12 or y == 7 or y == 29 or y == 37 or y == 61):
					c = c.darkened(0.3)
				if x >= 12 and x <= 13 and y >= 33 and y <= 35:
					c = Color(0.85, 0.75, 0.4)   # handle
			else:
				c = Color(0.46, 0.48, 0.52).darkened(n * 0.06)
				if y > 10 and y < 22 and x > 3 and x < 12:
					c = Color(0.25, 0.4, 0.5).lightened(0.15 * float(x + y) / 30.0)   # window
				if y >= h - 10:
					c = Color(0.85, 0.7, 0.1) if ((x + y) / 3) % 2 == 0 else Color(0.12, 0.12, 0.12)
				if x == 0 or x == w - 1 or y == 0:
					c = accent if accent.a > 0.0 else Color(0.28, 0.29, 0.32)
			img.set_pixel(x, y, c)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
