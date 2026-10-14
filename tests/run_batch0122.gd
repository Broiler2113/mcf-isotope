extends SceneTree
## 0.12.2: wall chunks come in sharp, varied shapes and sizes; destroying one cell of a
## joined piece of furniture (a table) leaves the rest standing.

var fails: PackedStringArray = []
func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond: fails.append(what)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_chunk_shapes()
	_partial_furniture()
	print("batch 0.12.2: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

## A wall's chunks differ in shape and size; old saves without a shape still read.
func _chunk_shapes() -> void:
	var fx := FxDecals.new()
	var shapes := {}
	var sizes: Array[float] = []
	for k in 6:
		fx.apply([{"fx": "chunks", "at": Vector2i(10, 10 + k * 3), "from": Vector2i(9, 10 + k * 3), "fid": MCF.FEATURE_WALL, "env": "town", "seq": 100 + k}])
	for f: Dictionary in fx.flying:
		var parts := FxDecals.chunk_parts(str(f["kind"]))
		shapes[parts[1]] = true
		sizes.append(float(f["scale"]))
	ck(shapes.size() >= 4, "chunks come in several sharp shapes (%d)" % shapes.size())
	sizes.sort()
	ck(sizes[0] < 0.7 and sizes[-1] > 1.3, "and in different sizes (%.2f..%.2f)" % [sizes[0], sizes[-1]])
	ck(FxDecals.chunk_parts("chunk:wall_town")[0] == "wall_town", "a 0.12.1 chunk without a shape still reads")
	ck(FxDecals.CHUNK_SHAPES.all(func(p: Array) -> bool: return p.size() <= 6), "shapes are a few straight edges (no round blobs)")

## Smashing or blowing up one cell of a table destroys that cell only.
func _partial_furniture() -> void:
	var m := MapData.blank_arena(16, 10)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(15, 9), "light_infantry", 1)
	for x in range(6, 9):
		for y in range(4, 6):
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, Furniture.height_of("dining_table"), false, "dining_table")
	var st := m.build_state(3)
	var r := GameActionResolver.new(st)
	var res := ActionResult.new()
	r._destroy_furniture(st.grid.cell(Vector2i(6, 4)), res)
	var left := 0
	for x in range(6, 9):
		for y in range(4, 6):
			left += 1 if st.grid.cell(Vector2i(x, y)).feature_id == "dining_table" else 0
	ck(st.grid.cell(Vector2i(6, 4)).feature_id == "" and left == 5, "one destroyed cell leaves the other five (%d)" % left)
	var gres := ActionResult.new()
	r._blast(Vector2i(8, 5), gres, [Vector2i(8, 5)] as Array[Vector2i])
	left = 0
	for x in range(6, 9):
		for y in range(4, 6):
			left += 1 if st.grid.cell(Vector2i(x, y)).feature_id == "dining_table" else 0
	ck(st.grid.cell(Vector2i(8, 5)).feature_id == "" and left == 4, "a blast on one cell takes just that cell (%d left)" % left)
