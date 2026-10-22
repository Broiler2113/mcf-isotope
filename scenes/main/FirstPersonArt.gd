class_name FirstPersonArt
extends RefCounted

## Pictures made for the 3D view, all at ONE density — 32 pixels a metre, the same as the
## board's floor tiles (owner, fix-8: "textures in completely different resolution"):
##  * materials: a stack of 1 m tiles (wood, fabric, metal, foliage, sandbag cloth...), mostly
##    grey so a model tints them with its own colours. Models lay them by their own metres.
##  * walls: each wall material's side at true scale, 1 m wide and the full 2.3 m tall, with
##    its relief baked in (owner: walls looked flat) — every brick, block, plank and panel is
##    lit on its upper-left edge and shaded in its joints, so they read as built, not painted.
##  * door leaves.
## Generated here, baked by tools/art/build_first_person.gd, then cached in memory.

const PX := 32                                   # pixels per metre
const H := 74                                    # 2.3 m
static var _cache := {}

# --- Materials --------------------------------------------------------------------------

enum {M_PLAIN, M_WOOD, M_METAL, M_PLATE, M_FABRIC, M_PLASTIC, M_CERAMIC, M_LEAVES, M_BARK,
	M_BURLAP, M_CONCRETE, M_RUBBER, M_PAPER, M_STEEL, M_SOIL, M_BOOKS, M_GOODS, M_CUSHION,
	M_GRILLE, M_SCREEN, M_SNOW, M_CARDBOARD, M_TILE, M_CHROME, M_SOLAR, M_MESH, M_GRAVEL,
	M_PLANKS, M_GRASS, M_COUNT}

static var _mats: Texture2DArray

## Every material tile, one layer each (M_*), with mipmaps: far surfaces average out
## instead of shimmering.
static func materials() -> Texture2DArray:
	if _mats != null:
		return _mats
	var imgs := _read_layers("material", M_COUNT, PX)
	if imgs.is_empty(): imgs = material_images()
	_mats = Texture2DArray.new()
	_mats.create_from_images(imgs)
	return _mats

## CPU image generation is retained as the source of the baked assets and a fallback.
static func material_images() -> Array[Image]:
	var imgs: Array[Image] = []
	for m in M_COUNT:
		var img := Image.create(PX, PX, false, Image.FORMAT_RGBA8)
		var hgt := PackedFloat32Array()
		hgt.resize(PX * PX)
		var cols: Array[Color] = []
		cols.resize(PX * PX)
		for y in PX:
			for x in PX:
				var r: Array = _mat_px(m, x, y)
				cols[y * PX + x] = r[0]
				hgt[y * PX + x] = r[1]
		var k := float(_RELIEF[m])
		for y in PX:
			for x in PX:
				var c: Color = cols[y * PX + x]
				if k > 0.0:
					var tl := hgt[posmod(y - 1, PX) * PX + posmod(x - 1, PX)]
					c = _lit(c, 1.0 + k * (hgt[y * PX + x] - tl))
				img.set_pixel(x, y, c)
		img.generate_mipmaps()
		imgs.append(img)
	return imgs

static func _read_layers(prefix: String, count: int, size: int) -> Array[Image]:
	var out: Array[Image] = []
	for i in count:
		var path := "res://textures/first_person/%s_%02d.png" % [prefix, i]
		if not ResourceLoader.exists(path): return []
		var texture: Texture2D = load(path)
		var img := texture.get_image() if texture != null else null
		if img == null or img.get_size() != Vector2i(size, size): return []
		img.convert(Image.FORMAT_RGBA8)
		if not img.has_mipmaps(): img.generate_mipmaps()
		out.append(img)
	return out

## How strongly each material's height shows as relief.
const _RELIEF := [0.0, 0.2, 0.0, 0.5, 0.25, 0.0, 0.0, 0.6, 0.6, 0.15, 0.3, 0.0, 0.0, 0.35, 0.5,
	0.3, 0.3, 0.35, 0.6, 0.0, 0.25, 0.2, 0.45, 0.0, 0.3, 0.5, 0.7, 0.35, 0.5]

static func _lit(c: Color, k: float) -> Color:
	return Color(clampf(c.r * k, 0, 1), clampf(c.g * k, 0, 1), clampf(c.b * k, 0, 1), c.a)

## A pixel hash 0..1.
static func _h(x: int, y: int, s := 0) -> float:
	var n := (x * 374761393 + y * 668265263 + s * 1442695041) & 0x7fffffff
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7fffffff
	return float((n ^ (n >> 16)) & 0xffff) / 65535.0

## Smooth value noise with lattice step `cell`, wrapping every PX pixels (tiles seamlessly).
static func _vn(x: float, y: float, cell: int, s := 0) -> float:
	var p := maxi(1, PX / cell)
	var gx := x / cell
	var gy := y / cell
	var ix := floori(gx)
	var iy := floori(gy)
	var fx := smoothstep(0.0, 1.0, gx - ix)
	var fy := smoothstep(0.0, 1.0, gy - iy)
	var a := _h(posmod(ix, p), posmod(iy, p), s)
	var b := _h(posmod(ix + 1, p), posmod(iy, p), s)
	var c := _h(posmod(ix, p), posmod(iy + 1, p), s)
	var d := _h(posmod(ix + 1, p), posmod(iy + 1, p), s)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)

static func _g(v: float, a := 1.0) -> Color:
	return Color(v, v, v, a)

## [colour, height 0..1] of material m at pixel (x, y). Grey materials are tinted by the
## model; books, goods, screens and solar cells carry their own colours.
static func _mat_px(m: int, x: int, y: int) -> Array:
	var n := _h(x, y, m)
	match m:
		M_PLAIN:
			return [_g(0.9 + 0.06 * _vn(x, y, 8, 1) + 0.03 * n), 0.0]
		M_WOOD:
			# Smooth furniture wood: long grain streaks along u, no joints.
			var g2 := 0.5 + 0.5 * sin(x * 0.35 + _vn(x, y, 8, 37) * 6.0 + y * 1.3)
			return [_g(0.8 + 0.1 * g2 + 0.05 * _vn(x, y, 4, 38) - 0.03 * n), g2 * 0.3]
		M_PLANKS:
			# Boards 8 px (25 cm) wide along u, a dark joint, grain streaks and a knot now and then.
			var board := y / 8
			var in_b := y % 8
			var grain := 0.5 + 0.5 * sin(x * 0.45 + _vn(x, y, 4, board) * 5.0 + board * 2.1)
			var v := 0.78 + 0.12 * grain + 0.08 * _h(board, 3, 7) - 0.04 * n
			if in_b == 7:
				return [_g(0.5), 0.0]
			if _h(x / 6, board, 9) > 0.93 and absi(x % 6 - 3) <= 1 and absi(in_b - 3) <= 1:
				v *= 0.72
			return [_g(v), 1.0 if in_b > 0 else 0.6]
		M_METAL:
			var streak := _h(0, y, 11) * 0.08 + _vn(x, y, 16, 3) * 0.06
			return [_g(0.82 + streak + 0.03 * n), 0.0]
		M_PLATE:
			var px := x % 16
			var py := y % 16
			if px == 0 or py == 0:
				return [_g(0.55), 0.0]
			var rivet := (px == 2 or px == 14) and (py == 2 or py == 14)
			return [_g(0.86 + 0.06 * _vn(x, y, 8, 5) + (0.08 if rivet else 0.0)), 1.6 if rivet else 1.0]
		M_FABRIC:
			var weave := 0.06 if (x + y) % 2 == 0 else -0.04
			return [_g(0.86 + weave + 0.06 * _vn(x, y, 4, 2)), 0.5 + weave * 4.0]
		M_PLASTIC:
			return [_g(0.92 + 0.04 * _vn(x, y, 8, 4) + 0.02 * n), 0.0]
		M_CERAMIC:
			return [_g(0.96 + 0.02 * _vn(x, y, 16, 6) + 0.015 * n), 0.0]
		M_LEAVES:
			var clump := _vn(x, y, 4, 12) * 0.6 + _vn(x, y, 8, 13) * 0.4
			var v2 := 0.55 + 0.5 * clump + 0.1 * n
			return [_g(minf(v2, 1.0)), clump]
		M_BARK:
			var col := _vn(x * 2.5, y * 0.4, 4, 14)
			var v3 := 0.6 + 0.4 * col - (0.25 if col < 0.3 else 0.0) + 0.06 * n
			return [_g(v3), col]
		M_BURLAP:
			# Coarse cloth: faint threads both ways, blotches of grime, never a checker.
			var thread := (0.015 if x % 2 == 0 else 0.0) + (0.012 if y % 3 == 0 else 0.0)
			return [_g(0.82 + thread + 0.1 * _vn(x, y, 8, 15) + 0.04 * n - 0.06 * _vn(x, y, 16, 16)),
					0.5 + thread * 4.0 + 0.2 * _vn(x, y, 4, 17)]
		M_CONCRETE:
			var pore := n > 0.94
			return [_g(0.82 + 0.1 * _vn(x, y, 8, 16) + 0.05 * _h(x, y, 17) - (0.2 if pore else 0.0)),
					0.0 if pore else 0.5 + 0.3 * _vn(x, y, 4, 18)]
		M_RUBBER:
			return [_g(0.9 + 0.06 * n), 0.0]
		M_PAPER:
			# Lines of print on white: every third row, broken into words.
			var line := y % 3 == 1 and x > 2 and x < 29 and _h(x / 3, y, 19) > 0.25 and y > 2 and y < 29
			return [_g(0.6 if line else 0.97), 0.0]
		M_STEEL:
			var rust := _vn(x, y, 4, 20) * 0.6 + _vn(x, y, 8, 21) * 0.4
			var c := Color(0.62, 0.6, 0.58).lerp(Color(0.7, 0.45, 0.3), clampf(rust * 1.4 - 0.5, 0.0, 1.0))
			if _h(x, y / 4, 22) > 0.96:
				c = c.lightened(0.25)   # a bright scratch
			return [c.darkened(0.06 * n), rust]
		M_SOIL:
			var pebble := _vn(x, y, 4, 23)
			var v4 := 0.72 + 0.22 * _vn(x, y, 8, 24) + 0.1 * n
			if pebble > 0.78:
				return [_g(minf(v4 + 0.22, 1.0)), 1.0]
			return [_g(v4), pebble * 0.5]
		M_GRASS:
			# Seamless turf for the open ground (owner, fix-8: grass showed its tiles): clumps
			# at two scales, blades lit on one side, a stray flower.
			var clump := _vn(x, y, 8, 39) * 0.55 + _vn(x, y, 4, 40) * 0.3 + n * 0.15
			var blade := (x + y * 3) % 5 == 0 and _h(x, y, 41) > 0.6
			var gc := Color(0.24, 0.4, 0.16).lerp(Color(0.38, 0.55, 0.22), clump)
			if blade:
				gc = gc.lightened(0.12)
			if _h(x, y, 42) > 0.995:
				gc = Color(0.9, 0.85, 0.4)
			return [gc, clump]
		M_BOOKS:
			# Spines 1-3 px wide in a run of colours, a lighter band near the top of each.
			var w := 0
			var start := 0
			var k := 0
			while start + w <= x:
				start += w
				w = 1 + int(_h(k, 0, 25) * 3.0)
				k += 1
			# Library colours: oxblood, bottle green, navy, tan, black, now and then a cream.
			var lib := [Color(0.45, 0.12, 0.1), Color(0.14, 0.3, 0.18), Color(0.12, 0.18, 0.36), Color(0.6, 0.45, 0.28),
					Color(0.12, 0.11, 0.1), Color(0.78, 0.72, 0.6), Color(0.5, 0.3, 0.14), Color(0.3, 0.12, 0.28)]
			var col2: Color = (lib[int(_h(k, 1, 26) * lib.size()) % lib.size()] as Color).lightened(0.15 * _h(k, 3, 28))
			if y % 10 == 2:
				col2 = col2.lightened(0.35)
			if x == start:
				col2 = col2.darkened(0.3)
			return [col2, 1.0 if x != start else 0.3]
		M_GOODS:
			# Shelves of packets, 8 px rows: coloured boxes with a white label.
			var row := y / 8
			var iy2 := y % 8
			var item := x / 4
			var c2 := Color.from_hsv(_h(item, row, 29), 0.42, 0.45 + 0.25 * _h(item, row, 30))
			if x % 4 == 3 or iy2 < 2:
				return [Color(0.12, 0.12, 0.13), 0.0]
			if iy2 == 4 or iy2 == 5:
				c2 = c2.lerp(Color(0.95, 0.95, 0.92), 0.7)
			return [c2, 1.0]
		M_CUSHION:
			# Tufted: pillows 8 px with a button dimple at each corner.
			var dx := absf(float(x % 16) - 7.5) / 8.0
			var dy := absf(float(y % 16) - 7.5) / 8.0
			var puff := 1.0 - maxf(dx, dy) * maxf(dx, dy)
			var weave := 0.03 if (x + y) % 2 == 0 else 0.0
			return [_g(0.86 + 0.1 * puff + weave + 0.02 * n), puff]
		M_GRILLE:
			var slot := y % 4 >= 2 and x % 16 > 1 and x % 16 < 14
			return [_g(0.22 if slot else 0.85 + 0.05 * n), 0.0 if slot else 1.0]
		M_SCREEN:
			var text := y % 4 == 1 and _h(x / 2, y / 4, 31) > 0.45 and x > 1 and x < 30
			var base := Color(0.05, 0.14, 0.12) if y % 2 == 0 else Color(0.04, 0.11, 0.1)
			return [Color(0.35, 0.95, 0.65) if text else base, 0.0]
		M_SNOW:
			return [Color(0.92, 0.95, 1.0).darkened(0.08 * _vn(x, y, 8, 32)).lightened(0.3 if n > 0.97 else 0.0),
					_vn(x, y, 8, 33)]
		M_CARDBOARD:
			var tape := y >= 14 and y <= 17
			return [_g(0.9 if tape else 0.82 + 0.06 * sin(x * 1.6) * 0.5 + 0.05 * n), 0.4 if x % 2 == 0 else 0.6]
		M_TILE:
			var gx := x % 8 == 0
			var gy := y % 8 == 0
			if gx or gy:
				return [_g(0.62), 0.0]
			return [_g(0.95 + 0.03 * _h(x / 8, y / 8, 34) + 0.015 * n), 1.0]
		M_CHROME:
			return [_g(0.75 + 0.25 * absf(sin(y * 0.2 + x * 0.05))), 0.0]
		M_SOLAR:
			var gl := x % 8 == 0 or y % 8 == 0
			if gl:
				return [Color(0.72, 0.74, 0.78), 1.0]
			var cell := Color(0.08, 0.14, 0.34).lerp(Color(0.18, 0.3, 0.6), float(y % 8) / 8.0 * 0.6 + 0.2 * n)
			if (x % 8 == 4):
				cell = cell.lightened(0.1)   # the cell's busbar
			return [cell, 0.4]
		M_MESH:
			var hole := x % 3 != 0 and y % 3 != 0
			return [_g(0.18 if hole else 0.8), 0.0 if hole else 1.0]
		M_GRAVEL:
			var stone := _vn(x, y, 4, 35) * 0.7 + _vn(x, y, 2, 36) * 0.3
			return [_g(0.55 + 0.45 * stone), stone]
	return [_g(1.0), 0.0]

# --- Open ground ------------------------------------------------------------------------

const GROUND_PX := 256     # one ground tile: 8 m at 32 px a metre, seamless

enum {G_GRASS, G_EARTH, G_SNOW, G_COUNT}
static var _grounds: Texture2DArray

## Value noise wrapping every `period` pixels.
static func _vnp(x: float, y: float, cell: int, period: int, s := 0) -> float:
	var p := maxi(1, period / cell)
	var gx := x / cell
	var gy := y / cell
	var ix := floori(gx)
	var iy := floori(gy)
	var fx := smoothstep(0.0, 1.0, gx - ix)
	var fy := smoothstep(0.0, 1.0, gy - iy)
	var a := _h(posmod(ix, p), posmod(iy, p), s)
	var b := _h(posmod(ix + 1, p), posmod(iy, p), s)
	var c := _h(posmod(ix, p), posmod(iy + 1, p), s)
	var d := _h(posmod(ix + 1, p), posmod(iy + 1, p), s)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)

## Turf, bare earth and snow, each an 8 m seamless tile with its relief baked in.
static func grounds() -> Texture2DArray:
	if _grounds != null:
		return _grounds
	var imgs := _read_layers("ground", G_COUNT, GROUND_PX)
	if imgs.is_empty(): imgs = ground_images()
	_grounds = Texture2DArray.new()
	_grounds.create_from_images(imgs)
	return _grounds

static func ground_images() -> Array[Image]:
	var imgs: Array[Image] = []
	for g in G_COUNT:
		var cols: Array[Color] = []
		var hgt := PackedFloat32Array()
		cols.resize(GROUND_PX * GROUND_PX)
		hgt.resize(GROUND_PX * GROUND_PX)
		for y in GROUND_PX:
			for x in GROUND_PX:
				var r: Array = _ground_px(g, x, y)
				cols[y * GROUND_PX + x] = r[0]
				hgt[y * GROUND_PX + x] = r[1]
		var img := Image.create(GROUND_PX, GROUND_PX, false, Image.FORMAT_RGBA8)
		for y in GROUND_PX:
			for x in GROUND_PX:
				var tl := hgt[posmod(y - 1, GROUND_PX) * GROUND_PX + posmod(x - 1, GROUND_PX)]
				img.set_pixel(x, y, _lit(cols[y * GROUND_PX + x], 1.0 + 0.45 * (hgt[y * GROUND_PX + x] - tl)))
		img.generate_mipmaps()
		imgs.append(img)
	return imgs

static func _ground_px(g: int, x: int, y: int) -> Array:
	var P := GROUND_PX
	var n := _h(x, y, 70 + g)
	var big := _vnp(x, y, 64, P, 71 + g)
	var mid := _vnp(x, y, 16, P, 72 + g)
	var small := _vnp(x, y, 4, P, 73 + g)
	match g:
		G_GRASS:
			# Patches lush and dry, clumps, single blades catching the light, rare flowers.
			var clump := mid * 0.5 + small * 0.35 + n * 0.15
			var lush := Color(0.2, 0.36, 0.13).lerp(Color(0.34, 0.5, 0.19), clump)
			var dry := Color(0.36, 0.4, 0.18).lerp(Color(0.46, 0.48, 0.24), clump)
			var c := lush.lerp(dry, clampf((big - 0.55) * 2.5, 0.0, 0.6))
			if (x + y * 7) % 11 == 0 and _h(x, y, 74) > 0.5:
				c = c.lightened(0.14)
			elif (x * 5 + y) % 13 == 0 and _h(x, y, 75) > 0.6:
				c = c.darkened(0.18)
			if _h(x / 2, y / 2, 76) > 0.997:
				c = [Color(0.95, 0.9, 0.45), Color(0.95, 0.95, 0.92), Color(0.75, 0.55, 0.85)][int(_h(x, y, 77) * 3.0) % 3]
			return [c, clump]
		G_EARTH:
			var pebble := small > 0.8 and n > 0.4
			var c2 := Color(0.36, 0.27, 0.18).lerp(Color(0.47, 0.37, 0.25), mid * 0.7 + big * 0.3).darkened(0.08 * n)
			if pebble:
				c2 = Color(0.55, 0.52, 0.48).darkened(0.15 * n)
			if absf(_vnp(x, y, 32, P, 78) - 0.5) < 0.02:
				c2 = c2.darkened(0.2)   # a crack in the dry earth
			return [c2, 1.0 if pebble else mid * 0.6]
		G_SNOW:
			var drift := big * 0.6 + mid * 0.4
			var c3 := Color(0.86, 0.9, 0.97).lerp(Color(0.97, 0.98, 1.0), drift).darkened(0.04 * small)
			if n > 0.996:
				c3 = Color(1.0, 1.0, 1.0)
			return [c3, drift]
	return [Color(0.5, 0.5, 0.5), 0.0]

# --- 2D art colours ---------------------------------------------------------------------

static var _avg := {}
## The average colour of a 2D picture's solid pixels: a model of a dumpster or a bed takes
## its paint from the board's own art, so every colour variant comes out right.
static func art_colour(name: String, fallback := Color(0.6, 0.6, 0.6)) -> Color:
	if _avg.has(name):
		return _avg[name]
	var out := fallback
	var tex := Sprites.texture_of(name) if Sprites.has_override(name) else null
	if tex == null and Sprites.has_override(name + Sprites.AUTOTILE_SUFFIX):
		tex = Sprites.texture_of(name + Sprites.AUTOTILE_SUFFIX)
	if tex != null:
		var img := tex.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			var sum := Color(0, 0, 0, 0)
			var n := 0
			var step := maxi(1, img.get_width() / 32)
			for y in range(0, img.get_height(), step):
				for x in range(0, img.get_width(), step):
					var p := img.get_pixel(x, y)
					if p.a > 0.6:
						sum += p
						n += 1
			if n > 0:
				out = Color(sum.r / n, sum.g / n, sum.b / n)
	_avg[name] = out
	return out

# --- Walls --------------------------------------------------------------------------------

## What a wall cell is made of, as the battle screen would draw it.
static func wall_kind(grid: Grid, at: Vector2i, env: String) -> String:
	var c := grid.cell_fast(at.x, at.y)
	match c.feature_id:
		MCF.FEATURE_WOOD_WALL: return "wood"
		MCF.FEATURE_ARMOR_WALL: return "armor"
		MCF.FEATURE_DOT: return "dot"
		MCF.FEATURE_DOT_OPEN: return "dot_open"
		MCF.FEATURE_LDF: return "ldf"
		MCF.FEATURE_SOIL, MCF.FEATURE_DIRT_PILE, MCF.FEATURE_BOUNDARY: return "soil"
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
		"bunker": return "bunker"
		"field": return "block"
	return "brick"

static func accent_of(grid: Grid, at: Vector2i) -> Color:
	var i := at.y * grid.width + at.x
	var a := int(grid.wall_accent[i]) if i < grid.wall_accent.size() else 0
	return MCF.ACCENT_COLORS[a] if a > 0 and a < MCF.ACCENT_COLORS.size() else Color(0, 0, 0, 0)

## The side texture of a wall kind, 1 m wide (it repeats along the wall) and 2.3 m tall,
## with its relief lit from the upper left and grime gathering toward the floor.
static func wall_texture(kind: String, accent: Color) -> ImageTexture:
	var key := "wall|%s|%s" % [kind, accent.to_html()]
	if _cache.has(key):
		return _cache[key]
	var cols: Array[Color] = []
	cols.resize(PX * H)
	var hgt := PackedFloat32Array()
	hgt.resize(PX * H)
	for y in H:
		for x in PX:
			var r: Array = _wall_px(kind, x, y)
			cols[y * PX + x] = r[0]
			hgt[y * PX + x] = r[1]
	var img := Image.create(PX, H, false, Image.FORMAT_RGBA8)
	var relief := 0.55 if kind != "ldf" else 0.9
	for y in H:
		for x in PX:
			var c: Color = cols[y * PX + x]
			var tl := hgt[maxi(0, y - 1) * PX + posmod(x - 1, PX)]
			c = _lit(c, 1.0 + relief * (hgt[y * PX + x] - tl))
			# Grime: the bottom half-metre darkens toward the floor (not on the clean LDF).
			var from_floor := H - 1 - y
			if from_floor < 16 and kind != "ldf":
				c = c.darkened(0.16 * (1.0 - from_floor / 16.0) * (0.7 + 0.3 * _h(x, y, 40)))
			img.set_pixel(x, y, c)
	if accent.a > 0.0:
		# A level band at hand height with a darker edge above and below.
		for y in range(H - 40, H - 35):
			for x in PX:
				var edge := y == H - 40 or y == H - 36
				img.set_pixel(x, y, accent.darkened(0.35) if edge else accent.darkened(0.05 * _h(x, y, 41)))
	img.generate_mipmaps()   # far walls average out instead of shimmering
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex

## [colour, height] of one wall pixel. y = 0 is the top (2.3 m), y = H - 1 the floor.
static func _wall_px(kind: String, x: int, y: int) -> Array:
	var from_floor := H - 1 - y
	var n := _h(x, y, 3)
	match kind:
		"brick":
			# Running bond: 8×4 px bricks (25×12 cm), recessed mortar, every course offset.
			var row := from_floor / 4
			var off := 4 if row % 2 == 1 else 0
			var bx := (x + off) % 8
			if from_floor % 4 == 3 or bx == 7:
				return [Color(0.58, 0.56, 0.52).darkened(0.1 * n), 0.0]
			var tone := _h(row, (x + off) / 8, 5)
			var base := Color(0.46, 0.17, 0.11).lerp(Color(0.6, 0.26, 0.16), tone)
			if _h(row, (x + off) / 8, 6) > 0.9:
				base = base.darkened(0.25)   # a burnt brick
			var chip := _h(x, y, 7) > 0.97
			return [base.darkened(0.07 * n + (0.2 if chip else 0.0)), 0.5 if chip else 1.0]
		"stucco":
			if from_floor < 9:
				# A stone plinth in blocks.
				var bx2 := (x + (8 if from_floor >= 5 else 0)) % 16
				if from_floor == 4 or bx2 == 15:
					return [Color(0.3, 0.29, 0.28), 0.0]
				return [Color(0.48, 0.46, 0.43).darkened(0.1 * n), 1.0]
			if from_floor == 9:
				return [Color(0.36, 0.35, 0.33), 1.2]
			var blot := _vn(x, y, 8, 8)
			return [Color(0.86, 0.82, 0.74).darkened(0.07 * blot + 0.04 * n), 0.4 + 0.5 * _vn(x, y, 2, 9)]
		"block":
			# Cinder blocks, 12×6 px (40×20 cm), half-offset courses, bevelled.
			var row2 := from_floor / 6
			var bx3 := (x + (6 if row2 % 2 == 1 else 0)) % 12
			if from_floor % 6 == 5 or bx3 == 11:
				return [Color(0.44, 0.44, 0.43), 0.0]
			var pore := _h(x, y, 10) > 0.93
			return [Color(0.62, 0.62, 0.6).darkened(0.1 * _h(row2, x / 12, 11) + 0.06 * n + (0.12 if pore else 0.0)),
					0.6 if pore else 1.0]
		"station", "bunker":
			# Hull panels between a dark kick plate and a trim strip, bevelled, riveted; the
			# bunker's are concrete grey and heavier.
			var heavy := kind == "bunker"
			if from_floor < 6:
				var stripe := heavy and ((x + from_floor) / 3) % 2 == 0
				return [Color(0.72, 0.6, 0.12) if stripe else Color(0.2, 0.21, 0.23).lightened(n * 0.05), 0.5]
			if y < 4:
				return [Color(0.3, 0.32, 0.35), 1.0 if y > 0 else 0.0]
			var py := (from_floor - 6) % 22
			var seam := x == 0 or x == 16 or py == 0
			if seam:
				return [Color(0.22, 0.23, 0.26), 0.0]
			var rivet := (x == 3 or x == 13 or x == 19 or x == 29) and (py == 3 or py == 19)
			var col := Color(0.6, 0.62, 0.64) if heavy else Color(0.66, 0.68, 0.72)
			if py >= 8 and py <= 13 and x > 20 and x < 28 and not heavy:
				# A vent in every other panel.
				return [Color(0.18, 0.19, 0.2) if py % 2 == 0 else col.darkened(0.15), 0.2 if py % 2 == 0 else 0.9]
			return [col.darkened(n * 0.05 + (0.04 if x > 16 else 0.0) + 0.05 * _vn(x, y, 8, 12)).lightened(0.12 if rivet else 0.0),
					1.6 if rivet else 1.0]
		"armor":
			var ax := x % 16
			var ay := from_floor % 24
			if ax == 0 or ay == 0:
				return [Color(0.14, 0.15, 0.16), 0.0]
			var bolt := (ax == 3 or ax == 13) and (ay == 4 or ay == 20)
			return [Color(0.34, 0.36, 0.38).darkened(n * 0.1 + 0.08 * _vn(x, y, 8, 13)).lightened(0.2 if bolt else 0.0),
					1.7 if bolt else 1.0]
		"dot", "dot_open":
			# Poured concrete: formwork boards 6 px tall, tie holes; the open box has a slit.
			if kind == "dot_open" and from_floor >= 34 and from_floor <= 40 and x > 3 and x < 28:
				return [Color(0.04, 0.04, 0.05), -0.5]
			var board := from_floor / 6
			var line := from_floor % 6 == 0
			var tie := from_floor % 24 == 12 and x % 16 == 8
			var cc := Color(0.56, 0.55, 0.52).darkened(0.06 * _h(board, 1, 14) + 0.08 * _vn(x, y, 8, 15) + 0.05 * n)
			if tie:
				return [cc.darkened(0.45), 0.0]
			return [cc.darkened(0.12 if line else 0.0), 0.7 if line else 1.0]
		"wood":
			var plank := x / 8
			if x % 8 == 0:
				return [Color(0.2, 0.12, 0.06), 0.0]
			var grain := 0.06 * sin(from_floor * 0.5 + plank * 2.3 + _vn(x, y, 4, 16) * 4.0) + _h(plank, 0, 17) * 0.1
			var nail := (x % 8 == 4) and (from_floor == 10 or from_floor == 62)
			return [Color(0.52, 0.33, 0.17).darkened(grain + n * 0.04).lightened(0.25 if nail else 0.0), 1.3 if nail else 1.0]
		"soil":
			var stone := _vn(x, y, 4, 18)
			var band := 0.08 * sin(from_floor * 0.45 + x * 0.05) + n * 0.1
			if stone > 0.8:
				return [Color(0.5, 0.47, 0.42).darkened(0.1 * n), 1.0]
			return [Color(0.42, 0.32, 0.22).darkened(band), stone * 0.6]
		"rock":
			var strata := _vn(x * 0.5, y * 1.5, 4, 19)
			var crack := absf(_vn(x, y, 8, 20) - 0.5) < 0.03
			return [Color(0.4, 0.38, 0.37).darkened(0.18 * strata + 0.08 * n + (0.25 if crack else 0.0)),
					0.0 if crack else strata]
		"sandbag":
			# Rows of filled bags, 16×5 px, staggered, each one bulging.
			var row3 := from_floor / 5
			var sx := (x + (8 if row3 % 2 == 1 else 0)) % 16
			var ry := from_floor % 5
			if ry == 4 or sx == 15:
				return [Color(0.3, 0.27, 0.2), 0.0]
			var bulge := 1.0 - pow(absf(sx - 7.0) / 8.0, 2.0) * 0.6 - pow(absf(ry - 1.5) / 2.5, 2.0) * 0.4
			return [Color(0.66, 0.6, 0.44).darkened(0.08 * _h(row3, x / 16, 21) + 0.06 * n), bulge]
		"corpse":
			var lump := _vn(x, y, 8, 22)
			return [Color(0.38, 0.1, 0.09).darkened(0.25 * n).lerp(Color(0.3, 0.25, 0.2), 0.3 * lump), lump]
		"ldf":
			# Owner (fix-8): the LDF is black, as on the board — matt panels with faint seams
			# and the white tick marks of the board's art.
			var panel := x % 16 == 0 or from_floor % 24 == 0
			var tick := x % 16 == 12 and from_floor % 24 >= 8 and from_floor % 24 <= 13
			if tick:
				return [Color(0.85, 0.86, 0.88), 1.0]
			return [Color(0.035, 0.037, 0.042).lightened(0.03 * n), 0.0 if panel else 1.0]
	return [Color(0.5, 0.5, 0.5).darkened(n * 0.1), 1.0]

## The colour of a wall's top (unroofed walls), seen from above.
static func wall_top_colour(kind: String) -> Color:
	match kind:
		"ldf": return Color(0.04, 0.04, 0.045)
		"wood": return Color(0.42, 0.27, 0.14)
		"soil": return Color(0.4, 0.31, 0.22)
		"sandbag": return Color(0.62, 0.56, 0.42)
		"brick": return Color(0.5, 0.48, 0.45)
	return Color(0.52, 0.53, 0.55)

# --- Doors ------------------------------------------------------------------------------

## A door leaf at 32 px a metre: a riveted metal half-door 0.5 × 2.1 m with a window and
## hazard chevrons at its foot (station, bunker, asteroid), or a whole wooden door 1 × 2.1 m
## with panels and a handle (town, field).
static func door_texture(style: String, accent: Color) -> ImageTexture:
	var key := "door|%s|%s" % [style, accent.to_html()]
	if _cache.has(key):
		return _cache[key]
	var wood := style == "wood"
	var w := 32 if wood else 16
	var h := 68
	var cols: Array[Color] = []
	var hgt := PackedFloat32Array()
	cols.resize(w * h)
	hgt.resize(w * h)
	for y in h:
		for x in w:
			var n := _h(x, y, 42)
			var c: Color
			var hh := 1.0
			if wood:
				c = Color(0.48, 0.3, 0.16).darkened(0.06 * sin(y * 0.8 + x * 0.3) + n * 0.05)
				var inset_x := x > 4 and x < 27
				var panel := inset_x and (y > 6 and y < 30 or y > 36 and y < 62)
				if panel:
					hh = 0.4
					if x == 5 or y == 7 or y == 37:
						hh = 0.2
				if x == 0 or x == w - 1 or y == 0:
					c = c.darkened(0.3)
				if x >= 26 and x <= 28 and y >= 33 and y <= 35:
					c = Color(0.85, 0.75, 0.4)   # handle
					hh = 1.6
			else:
				c = Color(0.46, 0.48, 0.52).darkened(n * 0.06)
				if y > 10 and y < 22 and x > 3 and x < 12:
					c = Color(0.25, 0.4, 0.5).lightened(0.15 * float(x + y) / 30.0)   # window
					hh = 0.3
				if y >= h - 10:
					c = Color(0.85, 0.7, 0.1) if ((x + y) / 3) % 2 == 0 else Color(0.12, 0.12, 0.12)
				if (x == 2 or x == 13) and y % 12 == 4:
					hh = 1.6   # rivets
					c = c.lightened(0.15)
				if x == 0 or x == w - 1 or y == 0:
					c = accent if accent.a > 0.0 else Color(0.28, 0.29, 0.32)
					hh = 0.6
			cols[y * w + x] = c
			hgt[y * w + x] = hh
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var tl := hgt[maxi(0, y - 1) * w + maxi(0, x - 1)]
			img.set_pixel(x, y, _lit(cols[y * w + x], 1.0 + 0.45 * (hgt[y * w + x] - tl)))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
