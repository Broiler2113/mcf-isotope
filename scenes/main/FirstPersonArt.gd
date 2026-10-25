class_name FirstPersonArt
extends RefCounted

## Pictures for the 3D view in the SVAROG tank's look — realistic, weathered, pixelated —
## all at ONE density, 32 pixels a metre (owner, fix-8):
##  * materials: a stack of 1 m tiles (wood, fabric, metal, foliage, sandbag cloth...), mostly
##    grey so a model tints them with its own colours. Models lay them by their own metres.
##  * ground: seamless 8 m turf, earth and snow.
##  * walls: each wall material's side, 4 m wide and the full 2.3 m tall; doors, ceilings,
##    roofs and the moon.
## All are drawn by tools/art/build_first_person.py and import as CPU Images (no GPU readback).

const PX := 32                                   # pixels per metre
const H := 74                                    # 2.3 m
const DIR := "res://textures/first_person/"
static var _cache := {}

# --- Materials --------------------------------------------------------------------------

enum {M_PLAIN, M_WOOD, M_METAL, M_PLATE, M_FABRIC, M_PLASTIC, M_CERAMIC, M_LEAVES, M_BARK,
	M_BURLAP, M_CONCRETE, M_RUBBER, M_PAPER, M_STEEL, M_SOIL, M_BOOKS, M_GOODS, M_CUSHION,
	M_GRILLE, M_SCREEN, M_SNOW, M_CARDBOARD, M_TILE, M_CHROME, M_SOLAR, M_MESH, M_GRAVEL,
	M_PLANKS, M_GRASS,
	# Wall surfaces (a 1 m piece of each wall picture, WALL_MATS order) for chunks of walls.
	M_W_BRICK, M_W_STUCCO, M_W_BLOCK, M_W_STATION, M_W_BUNKER, M_W_ARMOR, M_W_DOT, M_W_WOOD,
	M_W_SOIL, M_W_ROCK, M_W_SANDBAG, M_W_CORPSE, M_W_LDF, M_COUNT}
const WALL_MATS := ["brick", "stucco", "block", "station", "bunker", "armor", "dot", "wood", "soil",
	"rock", "sandbag", "corpse", "ldf"]

## The wall kind a chunk's art came from ("" for furniture and the rest).
static func chunk_kind(art: String) -> String:
	match art:
		"wall", "wall_brick", "wall_town": return "brick"
		"wall_stucco": return "stucco"
		"wall_block", "wall_field": return "block"
		"wall_station": return "station"
		"wall_bunker": return "bunker"
		"wall_asteroid": return "rock"
		"armor_wall": return "armor"
		"dot", "dot_open": return "dot"
		"wood_wall": return "wood"
		"soil", "dirt_pile": return "soil"
		"sandbag_wall": return "sandbag"
		"corpse_wall": return "corpse"
		"ldf", "bru": return "ldf"
	return ""

static var _mats: Texture2DArray

## Every material tile, one layer each (M_*), with mipmaps: far surfaces average out
## instead of shimmering.
static func materials() -> Texture2DArray:
	if _mats != null:
		return _mats
	_mats = Texture2DArray.new()
	_mats.create_from_images(_read_layers("material", M_COUNT))
	return _mats

## One shipped picture as a fresh RGBA8 Image (a blank one if it is missing).
static func picture(name: String) -> Image:
	var img := load(DIR + name + ".png") as Image
	img = img.duplicate() if img != null else Image.create(PX, PX, false, Image.FORMAT_RGBA8)
	img.convert(Image.FORMAT_RGBA8)
	return img

static func _read_layers(prefix: String, count: int) -> Array[Image]:
	var out: Array[Image] = []
	for i in count:
		var img := picture("%s_%02d" % [prefix, i])
		img.generate_mipmaps()
		out.append(img)
	return out

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

# --- Open ground ------------------------------------------------------------------------

const GROUND_PX := 256     # one ground tile: 8 m at 32 px a metre, seamless

enum {G_GRASS, G_EARTH, G_SNOW, G_COUNT}
static var _grounds: Texture2DArray
static var _ground_sources: Array[Image] = []

## Turf, bare earth and snow, each an 8 m seamless tile.
static func grounds() -> Texture2DArray:
	if _grounds != null:
		return _grounds
	_grounds = Texture2DArray.new()
	_grounds.create_from_images(_ground_source_images())
	return _grounds

static func _ground_source_images() -> Array[Image]:
	if _ground_sources.is_empty():
		_ground_sources = _read_layers("ground", G_COUNT)
	return _ground_sources

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
	if grid.cell(at).feature_id in [MCF.FEATURE_LDF, MCF.FEATURE_DOT, MCF.FEATURE_DOT_OPEN]:
		return Color(0, 0, 0, 0)
	var i := at.y * grid.width + at.x
	var a := int(grid.wall_accent[i]) if i < grid.wall_accent.size() else 0
	return MCF.ACCENT_COLORS[a] if a > 0 and a < MCF.ACCENT_COLORS.size() else Color(0, 0, 0, 0)

## The side texture of a wall kind, 4 m wide (laid by world position) and 2.3 m tall. A
## department's colour is a painted band at hand height: the wall shows through the paint,
## which is chipped and worn at its ragged edges like the rest of the wall.
static func wall_texture(kind: String, accent: Color) -> ImageTexture:
	if kind in ["ldf", "dot", "dot_open"]:
		accent = Color(0, 0, 0, 0)
	var source: Texture2D = Sprites.texture_of("ldf") if kind == "ldf" and Sprites.has_user_override("ldf") else null
	var key := "wall|%s|%s|%d" % [kind, accent.to_html(), source.get_instance_id() if source != null else 0]
	if _cache.has(key):
		return _cache[key]
	if kind == "trench":
		# The same seamless earth and metre scale on the floor and excavated faces.
		var earth := ImageTexture.create_from_image(_ground_source_images()[G_EARTH])
		_cache[key] = earth
		return earth
	if kind == "ldf":
		# A player's own ldf.png is laid as it is; otherwise the 3D art like every wall.
		if source != null:
			var sheet := source.get_image()
			var tile := sheet.get_region(Rect2i(0, 0, sheet.get_height(), sheet.get_height()))
			tile.generate_mipmaps()
			var same := ImageTexture.create_from_image(tile)
			_cache[key] = same
			return same
	var img := picture("wall_" + (kind if ResourceLoader.exists(DIR + "wall_" + kind + ".png") else "block"))
	if accent.a > 0.0:
		_paint_band(img, accent, H - 40, H - 35)
	img.generate_mipmaps()   # far walls average out instead of shimmering
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex

## Paint rows y0..y1-1 with the accent: shaded by the wall beneath (its bricks, seams and
## grime show through), a little faded, chipped through in places, ragged top and bottom.
static func _paint_band(img: Image, accent: Color, y0: int, y1: int) -> void:
	var paint := accent.lerp(Color(0.5, 0.5, 0.5), 0.12)
	var mean := 0.0
	for y in range(y0, y1):
		for x in img.get_width():
			mean += img.get_pixel(x, y).get_luminance()
	mean /= float((y1 - y0) * img.get_width())
	for y in range(y0 - 1, y1 + 1):
		for x in img.get_width():
			var rim := y < y0 or y >= y1
			var edge := y == y0 or y == y1 - 1
			if rim and _h(x, y, 44) > 0.25: continue          # paint run past the line
			if edge and _h(x / 2, y, 41) < 0.18: continue      # ragged edge
			if _h(x / 3, y / 2, 43) > 0.93: continue           # chipped through
			var base := img.get_pixel(x, y)
			var k := clampf(base.get_luminance() / maxf(mean, 0.05), 0.45, 1.35)
			var worn := 0.15 * _h(x / 4, y / 3, 45)
			img.set_pixel(x, y, base.lerp(Color(paint.r * k, paint.g * k, paint.b * k), 0.85 - worn - (0.4 if rim else 0.0)))

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

## A door leaf at 32 px a metre: a riveted metal half-door 0.5 × 2.1 m with a wired window
## and hazard chevrons at its foot (station, bunker, asteroid: the airlocks), or a whole
## panelled wooden door 1 × 2.1 m (town, field). A metal leaf's edge takes the accent.
static func door_texture(style: String, accent: Color) -> ImageTexture:
	var key := "door|%s|%s" % [style, accent.to_html()]
	if _cache.has(key):
		return _cache[key]
	var img := picture("door_" + ("wood" if style == "wood" else "metal"))
	if style != "wood" and accent.a > 0.0:
		var w := img.get_width()
		for y in img.get_height():
			for x in [0, w - 1]:
				var base := img.get_pixel(x, y)
				img.set_pixel(x, y, base.lerp(accent * (0.6 + 0.6 * base.get_luminance()), 0.8))
		for x in w:
			img.set_pixel(x, 0, img.get_pixel(x, 0).lerp(accent, 0.8))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
