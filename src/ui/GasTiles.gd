class_name GasTiles
extends RefCounted

## Bake connected cloud edges once per source texture. A cloud spans several cells before
## repeating, with mirrored sampling at the pattern boundary and faded outer edges.
## The shipped atlas is 64x4096 (1 MiB RGBA), pre-baked by tools/gen_gas_atlas.gd.
const TILE := 16
const PATTERN := 8
const EDGE := 3.5
static var _source: Texture2D
static var _atlas: Texture2D

static func texture() -> Texture2D:
	var custom := Sprites.texture_of("gas_autotile")
	if custom != null and (Sprites.has_user_override("gas_autotile") or not Sprites.has_user_override("gas")):
		return custom
	var source := Sprites.texture_of("gas")
	if source == _source:
		return _atlas
	_source = source
	_atlas = null
	if source == null:
		return null
	_atlas = bake(source)
	return _atlas

static func bake(source: Texture2D) -> ImageTexture:
	var base := source.get_image()
	if base == null:
		return null
	base = base.duplicate()
	if base.is_compressed():
		base.decompress()
	# A legacy horizontal gas strip remains usable: take its first square tile.
	base = base.get_region(Rect2i(0, 0, mini(base.get_width(), base.get_height()), base.get_height()))
	var side := TILE * PATTERN / 2
	base.resize(side, side, Image.INTERPOLATE_NEAREST)
	var atlas := Image.create(TILE * 4, TILE * 4 * PATTERN * PATTERN, false, Image.FORMAT_RGBA8)
	for variant in PATTERN * PATTERN:
		for mask in 16:
			for y in TILE:
				for x in TILE:
					var sx := (variant % PATTERN) * TILE + x
					var sy := (variant / PATTERN) * TILE + y
					var color := base.get_pixel(sx if sx < side else 2 * side - 1 - sx,
							sy if sy < side else 2 * side - 1 - sy)
					var edge := 1.0
					if mask & Sprites.AUTOTILE_N == 0: edge = minf(edge, (y + 0.5) / EDGE)
					if mask & Sprites.AUTOTILE_E == 0: edge = minf(edge, (TILE - x - 0.5) / EDGE)
					if mask & Sprites.AUTOTILE_S == 0: edge = minf(edge, (TILE - y - 0.5) / EDGE)
					if mask & Sprites.AUTOTILE_W == 0: edge = minf(edge, (x + 0.5) / EDGE)
					color.a *= smoothstep(0.0, 1.0, edge)
					atlas.set_pixel((mask % 4) * TILE + x, (variant * 4 + mask / 4) * TILE + y, color)
	return ImageTexture.create_from_image(atlas)

static func at(grid: Grid, coord: Vector2i) -> bool:
	var cell := grid.cell(coord)
	return cell != null and cell.gas and cell.can_hold_gas()

static func mask_at(grid: Grid, coord: Vector2i) -> int:
	var mask := 0
	if at(grid, coord + Vector2i.UP): mask |= Sprites.AUTOTILE_N
	if at(grid, coord + Vector2i.RIGHT): mask |= Sprites.AUTOTILE_E
	if at(grid, coord + Vector2i.DOWN): mask |= Sprites.AUTOTILE_S
	if at(grid, coord + Vector2i.LEFT): mask |= Sprites.AUTOTILE_W
	return mask

static func source_rect(sheet: Texture2D, coord: Vector2i, mask: int) -> Rect2:
	var tile := sheet.get_width() / 4
	var variants := maxi(1, sheet.get_height() / (tile * 4))
	var variant := (posmod(coord.x, PATTERN) + PATTERN * posmod(coord.y, PATTERN)) % variants
	return Rect2((mask % 4) * tile, (variant * 4 + mask / 4) * tile, tile, tile)
