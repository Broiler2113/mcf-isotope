extends SceneTree
## LDF walls never carry service bands (2026-10-18 owner request): a department's colored
## line stops at an LDF instead of running onto it, whatever accent the LDF's cell holds.

var fails := 0
func _initialize() -> void: run.call_deferred()

func paint(ldf_accent: int, c: Vector2i, res: int) -> Image:
	var grid := Grid.new(8, 3)
	grid.wall_accent = PackedByteArray()
	grid.wall_accent.resize(8 * 3)
	for x in range(1, 4):
		grid.cell(Vector2i(x, 1)).set_feature(MCF.FEATURE_WALL)
		grid.wall_accent[1 * 8 + x] = 1
	for x in range(4, 7):
		grid.cell(Vector2i(x, 1)).set_feature(MCF.FEATURE_LDF)
		grid.wall_accent[1 * 8 + x] = ldf_accent
	var tiles := TerrainTiles.new(grid, "station")
	var floor_img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var feat := Image.create(res, res, false, Image.FORMAT_RGBA8)
	tiles._paint(floor_img, feat, c, Vector2i.ZERO, res)
	return feat

func run() -> void:
	for res in [16, 32]:
		var ldf_same := paint(1, Vector2i(5, 1), res).get_data() == paint(0, Vector2i(5, 1), res).get_data()
		var wall_same := paint(1, Vector2i(3, 1), res).get_data() == paint(0, Vector2i(3, 1), res).get_data()
		print(("ok   " if ldf_same else "FAIL ") + "res %d: an LDF looks the same with or without its cell's accent" % res)
		print(("ok   " if wall_same else "FAIL ") + "res %d: the wall's band does not run on into the LDF" % res)
		if not ldf_same: fails += 1
		if not wall_same: fails += 1
	quit(0 if fails == 0 else 1)
