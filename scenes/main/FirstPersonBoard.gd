class_name FirstPersonBoard
extends RefCounted

## The board in 3D for the first-person view (fix-7 #9): built from the same baked
## tiles as the battle screen, so the floor shows the same blood, debris and remembered
## looks, and walls and objects wear their own top-down art. One cell is 1×1 m; walls go
## up to the ceiling (2.3 m). Station and bunker are roofed everywhere; elsewhere only the
## enclosed buildings are, and their roofs are seen from outside (owner, 2026-10-21).
## Everything is cosmetic: nothing here touches the game state.

const CH := 8            # cells per side of a 3D chunk: few lights touch each mesh
const CEIL := 2.3        # ceiling height, and the height of every wall
const ROOF_T := 0.32     # roof slab thickness above the ceiling
const EAVE := 0.22       # how far a roof overhangs its walls
const TRENCH := 2.0      # trench depth (owner): you can climb down into one
const RES := 32          # tile pixels per cell (the battle screen's sharpest bake)

## Never seen: black. Seen but out of sight now: dimmed. In sight: as it is. The shader
## reads one pixel per cell of the visibility map that FirstPerson keeps in step with fog.
const SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque;
uniform sampler2D tex : source_color, filter_nearest;
uniform sampler2D vis : filter_nearest;
uniform vec2 board = vec2(1.0);
uniform float cut = 0.0;
uniform bool textured = true;
uniform vec4 tint : source_color = vec4(1.0);
uniform float rough = 0.85;
uniform float glow = 0.0;
// Outdoors the baked floor is see-through where the ground shows: the battle screen lays
// its ground wallpaper (16 cells a repeat) underneath, and so does this.
uniform sampler2D ground : source_color, filter_nearest, repeat_enable;
uniform bool has_ground = false;
varying vec3 wpos;
varying vec3 wnorm;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec4 c = textured ? texture(tex, UV) : vec4(1.0);
	if (has_ground) {
		vec4 g = texture(ground, wpos.xz / 16.0);
		c = vec4(mix(g.rgb, c.rgb, c.a), 1.0);
	}
	c *= tint * COLOR;
	if (c.a < cut) discard;
	vec2 cell = floor(wpos.xz - wnorm.xz * 0.02);
	float v = texture(vis, (cell + 0.5) / board).r;
	if (v < 0.2) {
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else {
		float k = v < 0.7 ? 0.38 : 1.0;
		ALBEDO = c.rgb * k;
		ROUGHNESS = rough;
		EMISSION = c.rgb * glow * k;
	}
}
// Stylised light (owner: "not cheap 3D"): two flat bands and a hard shadow edge.
void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float band = smoothstep(0.0, 0.06, ndl) * 0.55 + smoothstep(0.42, 0.5, ndl) * 0.45;
	DIFFUSE_LIGHT += band * ATTENUATION * LIGHT_COLOR;
}
"""

## A picture that always turns to face you around its upright axis, like the sprites of
## 2.5D shooters (owner): soldiers' cut-outs, trees, bushes. Fogged by its own base cell.
const BILLBOARD := """
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
uniform sampler2D tex : source_color, filter_nearest;
uniform sampler2D vis : filter_nearest;
uniform vec2 board = vec2(1.0);
varying vec3 base;
void vertex() {
	base = MODEL_MATRIX[3].xyz;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
		MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}
void fragment() {
	vec4 c = texture(tex, UV);
	if (c.a < 0.5) discard;
	float v = texture(vis, (floor(base.xz) + 0.5) / board).r;
	if (v < 0.2) discard;
	ALBEDO = c.rgb * (v < 0.7 ? 0.38 : 1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
void light() {
	DIFFUSE_LIGHT += (0.55 + 0.45 * step(0.0, dot(NORMAL, LIGHT))) * ATTENUATION * LIGHT_COLOR * 0.8;
}
"""

## Furniture shapes: id -> [shape, real height in metres]. The board keeps its rules
## heights (cover 0.5/1/1.5); these are only how the pieces look.
const SHAPES := {
	"chair": ["chair", 0.9], "armchair": ["armchair", 0.85], "sofa": ["armchair", 0.85],
	"bench": ["bench", 0.47], "toilet": ["toilet", 0.75],
	"desk_lamp": ["table", 0.76], "desk": ["desk", 0.76], "dining_table": ["table", 0.75],
	"coffee_table": ["table", 0.45], "office_desk": ["desk", 0.76], "conference_table": ["table", 0.75],
	"workbench": ["table", 0.9], "steel_table": ["table", 0.85], "plastic_table": ["table", 0.72],
	"lab_bench": ["desk", 0.9], "park_table": ["table", 0.75], "exam_table": ["table", 0.85],
	"equipment_cart": ["cart", 0.9], "bed": ["bed", 0.5], "bunk_bed": ["bunk", 1.75],
	"nightstand": ["box", 0.55], "wardrobe": ["box", 2.0], "dresser": ["box", 0.9],
	"bookshelf": ["shelf", 2.0], "cabinet": ["box", 1.0], "kitchen_counter": ["box", 0.92],
	"refrigerator": ["box", 1.85], "filing_cabinet": ["box", 1.3], "locker": ["box", 1.9],
	"reception_desk": ["box", 1.05], "display_shelf": ["shelf", 1.8], "checkout_counter": ["box", 0.95],
	"vending_machine": ["box", 1.9], "tool_cabinet": ["box", 1.0], "storage_shelf": ["shelf", 2.0],
	"server_rack": ["box", 2.0], "industrial_cabinet": ["box", 1.6], "pallet": ["box", 0.15],
	"crate": ["box", 0.7], "barrel": ["cyl", 0.9], "generator": ["box", 1.3], "toolbox": ["box", 0.3],
	"ammo_crate": ["box", 0.5], "machinery": ["box", 1.6], "dumpster": ["box", 1.3],
	"street_cabinet": ["box", 1.4], "potted_plant": ["plant", 0.95], "tv_stand": ["tv", 0.5],
	"stove": ["box", 0.9], "piano": ["box", 1.2], "water_cooler": ["cooler", 1.35],
	"washing_machine": ["box", 0.9], "fuel_tank": ["cyl", 1.6], "sink": ["box", 0.9],
	"console": ["box", 1.05], "target": ["target", 1.7], "vent_fan": ["box", 0.5],
	"morgue_drawers": ["box", 1.9], "biohazard_cabinet": ["box", 1.8], "specimen_fridge": ["box", 1.8],
	"gas_canister": ["cyl", 1.2], "water_bucket": ["cyl", 0.35], "machine_workstation": ["box", 1.2],
	"bush": ["bush", 0.8], "bush_dry": ["bush", 0.7], "bush_flowering": ["bush", 0.85],
	"park_tree": ["tree", 4.5], "shower": ["shower", 2.1], "bathtub": ["tub", 0.55],
	"streetlight": ["street", 4.2], "floodlight": ["flood", 1.9], "bollard_light": ["bollard", 0.9],
	"work_light": ["flood", 1.5], "floor_lamp": ["pole", 1.6], "lamp": ["pole", 1.3],
}

## Cells under a ceiling: 1 for every cell inside a building, its walls included.
## Station and bunker are roofed throughout (but not over open space); elsewhere a cell
## is inside when no walkable way leads to the map edge, grass and dirt paths, or space,
## without crossing a wall, glass or a door.
static func roofed(grid: Grid, env: String) -> PackedByteArray:
	var w := grid.width
	var h := grid.height
	var out := PackedByteArray()
	out.resize(w * h)
	if env in ["station", "bunker"]:
		for i in w * h:
			out[i] = 0 if grid.cells_flat()[i].is_space else 1
		return out
	var outside := PackedByteArray()
	outside.resize(w * h)
	var queue := PackedInt32Array()
	for y in h:
		for x in w:
			var c := grid.cell_fast(x, y)
			if _barrier(c):
				continue
			var look := grid.floor_look[y * w + x] if y * w + x < grid.floor_look.size() else 0
			if x == 0 or y == 0 or x == w - 1 or y == h - 1 or c.is_space \
					or c.floor_type == MCF.FLOOR_GRASS or look == MCF.Look.GRASS or look == MCF.Look.DIRT:
				outside[y * w + x] = 1
				queue.append(y * w + x)
	var k := 0
	while k < queue.size():
		var i := queue[k]
		k += 1
		var x := i % w
		var y := i / w
		for d: Vector2i in Grid.N4:
			var nx := x + d.x
			var ny := y + d.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var j := ny * w + nx
			if outside[j] == 1 or _barrier(grid.cell_fast(nx, ny)):
				continue
			outside[j] = 1
			queue.append(j)
	for y in h:
		for x in w:
			var i := y * w + x
			var c := grid.cell_fast(x, y)
			if outside[i] == 1 or c.is_space:
				continue
			if not _barrier(c):
				out[i] = 1
	# A wall or door is under the roof when it borders a roofed room.
	for y in h:
		for x in w:
			var i := y * w + x
			if out[i] == 1 or not _barrier(grid.cell_fast(x, y)):
				continue
			for d: Vector2i in Grid.N8:
				var nx := x + d.x
				var ny := y + d.y
				if nx >= 0 and ny >= 0 and nx < w and ny < h and out[ny * w + nx] == 1 \
						and not _barrier(grid.cell_fast(nx, ny)):
					out[i] = 2
					break
	for i in w * h:
		if out[i] == 2:
			out[i] = 1
	return out

static func _barrier(c: GridCell) -> bool:
	return c.cover_height >= MCF.WALL_HEIGHT or c.feature_id == MCF.FEATURE_AIRLOCK \
			or MCF.is_glass(c.feature_id)

static func is_wall(c: GridCell) -> bool:
	return c.cover_height >= MCF.WALL_HEIGHT and not MCF.is_glass(c.feature_id) \
			and c.feature_id != MCF.FEATURE_AIRLOCK and not Furniture.is_furniture(c.feature_id)

## A shader material for the board, sharing the visibility map.
static func material(vis: Texture2D, board: Vector2, tex: Texture2D = null, cut := 0.0,
		tint := Color.WHITE, rough := 0.85, glow := 0.0) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("vis", vis)
	m.set_shader_parameter("board", board)
	m.set_shader_parameter("textured", tex != null)
	if tex != null:
		m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("cut", cut)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("rough", rough)
	m.set_shader_parameter("glow", glow)
	return m

# --- One chunk -------------------------------------------------------------------------

## The chunk at cc (in 3D chunks of CH cells) → {"node": Node3D, "lights": [...],
## "doors": {cell: MeshInstance3D}}. floor_tex / feat_img / feat_tex: the battle screen's
## baked tiles of the TerrainTiles chunk (16 cells) that holds it; tile_cc is that chunk.
static func build(grid: Grid, cc: Vector2i, roof: PackedByteArray, mats: Dictionary,
		tiles: Dictionary) -> Dictionary:
	var node := Node3D.new()
	var floor_st := {}   # TerrainTiles chunk -> SurfaceTool
	var feat_st := {}
	var ceil_st := _st()
	var roof_st := _st()
	var glass_st := _st()
	var glow_st := _st()
	var lights: Array = []
	var doors := {}
	var wall_st := {}   # "kind|accent" -> SurfaceTool: walls in their 3D material
	var env: String = mats.get("env", "town")
	var bills: Array = []   # [base position, size (w, h), art cell, art bbox]
	var w := grid.width
	var x0 := cc.x * CH
	var y0 := cc.y * CH
	for y in range(y0, mini(y0 + CH, grid.height)):
		for x in range(x0, mini(x0 + CH, w)):
			var c := grid.cell_fast(x, y)
			var at := Vector2i(x, y)
			var tcc := Vector2i(x / TerrainTiles.C, y / TerrainTiles.C)
			var tile: Dictionary = tiles.get(tcc, {})
			if tile.is_empty():
				continue
			var uv := _cell_uv(tile, at)
			var roofed: bool = roof[y * w + x] == 1
			var dug := c.feature_id == MCF.FEATURE_TRENCH
			if dug:
				# Bare soil like its sides (owner). ponytail: the floor bake draws the trench
				# itself here, so blood in a trench isn't shown; a decal-only bake would fix it.
				_quad_up(_wall_st(wall_st, "soil", Color(0, 0, 0, 0)), Vector3(x, -TRENCH, y), Vector3(x + 1, -TRENCH, y + 1), Rect2(0, 0, 1, 0.43))
			elif not c.is_space:
				_quad_up(_st_for(floor_st, tcc), Vector3(x, 0.0, y), Vector3(x + 1, 0.0, y + 1), uv)
			if dug:
				# The pit's earthen sides, facing in, wherever the trench ends.
				for d: Vector2i in Grid.N4:
					var n := at + d
					if grid.in_bounds(n) and grid.cell_fast(n.x, n.y).feature_id == MCF.FEATURE_TRENCH:
						continue
					_wall_face(_wall_st(wall_st, "soil", Color(0, 0, 0, 0)), n, -d, -TRENCH, 0.0, _shade(-d))
			if roofed:
				_quad_down(ceil_st, Vector3(x, CEIL, y), Vector3(x + 1, CEIL, y + 1), Rect2(x * 0.5, y * 0.5, 0.5, 0.5))
				# The roof is a thick slab that reaches past the walls on the open sides.
				var lo := Vector3(x, CEIL, y)
				var hi := Vector3(x + 1, CEIL + ROOF_T, y + 1)
				var open_sides: Array[Vector2i] = []
				for d: Vector2i in Grid.N4:
					var n := at + d
					if not grid.in_bounds(n) or roof[n.y * w + n.x] == 0:
						open_sides.append(d)
						if d.x < 0: lo.x -= EAVE
						if d.x > 0: hi.x += EAVE
						if d.y < 0: lo.z -= EAVE
						if d.y > 0: hi.z += EAVE
				_quad_up(roof_st, Vector3(lo.x, hi.y, lo.z), hi, Rect2(lo.x * 0.5, lo.z * 0.5, (hi.x - lo.x) * 0.5, (hi.z - lo.z) * 0.5))
				for d: Vector2i in open_sides:
					_face(roof_st, lo, hi, d, Rect2(0, 0, 0.5, 0.16), Color(0.72, 0.72, 0.72))
					# The underside of the eave, seen from the street.
					var ulo := Vector3(x, CEIL, y)
					var uhi := Vector3(x + 1, CEIL, y + 1)
					match d:
						Vector2i(-1, 0): ulo.x = x - EAVE; uhi.x = x
						Vector2i(1, 0): ulo.x = x + 1; uhi.x = x + 1 + EAVE
						Vector2i(0, -1): ulo.z = y - EAVE; uhi.z = y
						Vector2i(0, 1): ulo.z = y + 1; uhi.z = y + 1 + EAVE
					_quad_down(roof_st, ulo, uhi, Rect2(0, 0, 0.2, 0.2))
			var fs: SurfaceTool = _st_for(feat_st, tcc)
			# Everything the battle screen draws on an open floor cell — small items,
			# drawn features without a height — lies on the floor here too (owner: all
			# decals and items visible in 2D show in 3D).
			if not c.is_space and not is_wall(c) and not MCF.is_glass(c.feature_id) \
					and c.feature_id != MCF.FEATURE_AIRLOCK and not Furniture.is_furniture(c.feature_id) and not dug \
					and (c.cover_height <= 0.0 or c.feature_id == ""):
				_quad_up(fs, Vector3(x, 0.006, y), Vector3(x + 1, 0.006, y + 1), uv)
			if is_wall(c):
				var ws := _wall_st(wall_st, FirstPersonArt.wall_kind(grid, at, env), FirstPersonArt.accent_of(grid, at))
				for d: Vector2i in Grid.N4:
					var n := at + d
					if grid.in_bounds(n) and is_wall(grid.cell_fast(n.x, n.y)):
						continue
					_wall_face(ws, at, d, 0.0, CEIL, _shade(d))
				if not roofed:
					_quad_up(ws, Vector3(x, CEIL, y), Vector3(x + 1, CEIL, y + 1), Rect2(0, 0, 1, 0.04))
				for lamp: Array in c.lamps:
					lights.append(_wall_lamp(at, lamp, glow_st, env in ["station", "bunker"]))
				continue
			if MCF.is_glass(c.feature_id):
				# A whole cell of glass, as thick as the wall it stands in (owner).
				_box(glass_st, Vector3(x, 0, y), Vector3(x + 1, CEIL, y + 1), Rect2(0, 0, 1, 1))
				continue
			if c.feature_id == MCF.FEATURE_AIRLOCK:
				doors[at] = _door(node, grid, at, env, mats, wall_st, roofed)
				continue
			if Furniture.is_furniture(c.feature_id):
				var img: Image = tile["feat_img"]
				var bb := _bbox(img, at, tile)
				var light := _furniture(fs, glow_st, grid, at, c.feature_id, uv, bb,
						roofed, grid.furniture_turn.get(at), bills, _group_box(grid, at, c.feature_id, tiles))
				if not light.is_empty():
					lights.append(light)
				continue
			if c.cover_height > 0.0 and c.feature_id != "" and c.feature_id != MCF.FEATURE_TRENCH:
				var top := minf(c.cover_height, CEIL)
				_box(fs, Vector3(x + 0.04, 0, y + 0.04), Vector3(x + 0.96, top, y + 0.96), uv)
	for tcc: Vector2i in floor_st:
		_add(node, floor_st[tcc], mats["floor"].get(tcc))
	for tcc: Vector2i in feat_st:
		_add(node, feat_st[tcc], mats["feat"].get(tcc))
	_add(node, ceil_st, mats["ceiling"])
	_add(node, roof_st, mats["roof"])
	_add(node, glass_st, mats["glass"])
	_add(node, glow_st, mats["glow"])
	for key: String in wall_st:
		var parts := key.split("|")
		_add(node, wall_st[key], mats["wall_mat"].call(parts[0], Color.html(parts[1]) if parts[1] != "" else Color(0, 0, 0, 0)))
	return {"node": node, "lights": lights, "doors": doors, "bills": bills}

static func _st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color.WHITE)
	return st

static func _st_for(by: Dictionary, key: Vector2i) -> SurfaceTool:
	if not by.has(key):
		by[key] = _st()
	return by[key]

static func _add(node: Node3D, st: SurfaceTool, mat: Material) -> void:
	if mat == null:
		return
	var mesh := st.commit()
	if mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	node.add_child(mi)

## The cell's square in its TerrainTiles chunk texture, in UV space.
static func _cell_uv(tile: Dictionary, at: Vector2i) -> Rect2:
	var cw: int = tile["w"]
	var chh: int = tile["h"]
	var lx := at.x % TerrainTiles.C
	var ly := at.y % TerrainTiles.C
	return Rect2(float(lx) / cw, float(ly) / chh, 1.0 / cw, 1.0 / chh)

## Slightly darker on two sides: faces read as solid even under flat light.
static func _shade(d: Vector2i) -> Color:
	return Color(0.82, 0.82, 0.82) if d.x != 0 else Color.WHITE

static func _runs_x(grid: Grid, at: Vector2i) -> bool:
	var e := at + Vector2i(1, 0)
	var w := at + Vector2i(-1, 0)
	return (grid.in_bounds(e) and _barrier(grid.cell_fast(e.x, e.y))) \
			or (grid.in_bounds(w) and _barrier(grid.cell_fast(w.x, w.y)))

## A piece that spans several cells is one object: the union of its cells' art, in world
## metres, so a bench's seat runs straight and its legs stand only at its true corners.
static func _group_box(grid: Grid, at: Vector2i, fid: String, tiles: Dictionary) -> Rect2:
	var seen := {at: true}
	var todo: Array[Vector2i] = [at]
	var box := Rect2()
	var first := true
	while not todo.is_empty() and seen.size() <= 12:
		var c: Vector2i = todo.pop_back()
		var tile: Dictionary = tiles.get(Vector2i(c.x / TerrainTiles.C, c.y / TerrainTiles.C), {})
		var bb := _bbox(tile["feat_img"], c, tile) if not tile.is_empty() else Rect2(0, 0, 1, 1)
		var r := Rect2(Vector2(c) + bb.position, bb.size)
		box = r if first else box.merge(r)
		first = false
		for d: Vector2i in Grid.N4:
			var n := c + d
			if grid.in_bounds(n) and not seen.has(n) and grid.cell_fast(n.x, n.y).feature_id == fid:
				seen[n] = true
				todo.append(n)
	return box

## The opaque part of the cell's art (fractions of the cell): a chair is small, a table
## fills its cell. The 3D piece stands on exactly that footprint.
static func _bbox(img: Image, at: Vector2i, tile: Dictionary) -> Rect2:
	var lx := (at.x % TerrainTiles.C) * RES
	var ly := (at.y % TerrainTiles.C) * RES
	var x0 := RES
	var y0 := RES
	var x1 := -1
	var y1 := -1
	for y in RES:
		for x in RES:
			if img.get_pixel(lx + x, ly + y).a > 0.35:
				x0 = mini(x0, x)
				y0 = mini(y0, y)
				x1 = maxi(x1, x)
				y1 = maxi(y1, y)
	if x1 < 0:
		return Rect2(0.15, 0.15, 0.7, 0.7)
	return Rect2(float(x0) / RES, float(y0) / RES, float(x1 - x0 + 1) / RES, float(y1 - y0 + 1) / RES)

# --- Geometry primitives -----------------------------------------------------------------

static func _tri(st: SurfaceTool, n: Vector3, a: Vector3, b: Vector3, c: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	st.set_normal(n); st.set_uv(ua); st.add_vertex(a)
	st.set_normal(n); st.set_uv(ub); st.add_vertex(b)
	st.set_normal(n); st.set_uv(uc); st.add_vertex(c)

## A quad a-b-c-d (counter-clockwise seen from where n points).
## rev: the corners are listed the other way round (sides and prisms), so the triangles are
## wound back to Godot's clockwise front faces.
static func _quad(st: SurfaceTool, n: Vector3, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		uv: Rect2, col := Color.WHITE, rev := false) -> void:
	st.set_color(col)
	var u0 := uv.position
	var u1 := uv.end
	if rev:
		_tri(st, n, a, c, b, Vector2(u0.x, u1.y), Vector2(u1.x, u0.y), Vector2(u1.x, u1.y))
		_tri(st, n, a, d, c, Vector2(u0.x, u1.y), Vector2(u0.x, u0.y), Vector2(u1.x, u0.y))
	else:
		_tri(st, n, a, b, c, Vector2(u0.x, u1.y), Vector2(u1.x, u1.y), Vector2(u1.x, u0.y))
		_tri(st, n, a, c, d, Vector2(u0.x, u1.y), Vector2(u1.x, u0.y), Vector2(u0.x, u0.y))
	st.set_color(Color.WHITE)

static func _quad_up(st: SurfaceTool, lo: Vector3, hi: Vector3, uv: Rect2) -> void:
	# Seen from above: x right, z down the texture (north at the top, as on the board).
	_quad(st, Vector3.UP, Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
			Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Rect2(uv.position + Vector2(0, uv.size.y), Vector2(uv.size.x, -uv.size.y)))

static func _quad_down(st: SurfaceTool, lo: Vector3, hi: Vector3, uv: Rect2) -> void:
	_quad(st, Vector3.DOWN, Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
			Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z), uv)

## The face of cell `at` that looks toward direction d, from y0 to y1.
static func _side(st: SurfaceTool, at: Vector2i, d: Vector2i, y0: float, y1: float, uv: Rect2,
		col := Color.WHITE) -> void:
	_face(st, Vector3(at.x, y0, at.y), Vector3(at.x + 1, y1, at.y + 1), d, uv, col)

static func _wall_st(by: Dictionary, kind: String, accent: Color) -> SurfaceTool:
	var key := "%s|%s" % [kind, accent.to_html() if accent.a > 0.0 else ""]
	if not by.has(key):
		by[key] = _st()
	return by[key]

## A wall's side in its 3D material: the texture is a metre wide and the wall's full height,
## laid by world position so the pattern runs on unbroken from cell to cell.
static func _wall_face(st: SurfaceTool, at: Vector2i, d: Vector2i, y0: float, y1: float, col := Color.WHITE) -> void:
	var x0 := float(at.x)
	var z0 := float(at.y)
	var pts: Array[Vector3]
	var along: Array[float]
	var n: Vector3
	match d:
		Vector2i(0, -1):
			pts = [Vector3(x0 + 1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0 + 1, y1, z0)]
			along = [1.0, 0.0, 0.0, 1.0]
			n = Vector3.FORWARD
		Vector2i(0, 1):
			pts = [Vector3(x0, y0, z0 + 1), Vector3(x0 + 1, y0, z0 + 1), Vector3(x0 + 1, y1, z0 + 1), Vector3(x0, y1, z0 + 1)]
			along = [0.0, 1.0, 1.0, 0.0]
			n = Vector3.BACK
		Vector2i(-1, 0):
			pts = [Vector3(x0, y0, z0), Vector3(x0, y0, z0 + 1), Vector3(x0, y1, z0 + 1), Vector3(x0, y1, z0)]
			along = [0.0, 1.0, 1.0, 0.0]
			n = Vector3.LEFT
		_:
			pts = [Vector3(x0 + 1, y0, z0 + 1), Vector3(x0 + 1, y0, z0), Vector3(x0 + 1, y1, z0), Vector3(x0 + 1, y1, z0 + 1)]
			along = [1.0, 0.0, 0.0, 1.0]
			n = Vector3.RIGHT
	var uvs: Array[Vector2] = []
	for k in 4:
		uvs.append(Vector2(along[k], 1.0 - pts[k].y / CEIL))
	st.set_color(col)
	_tri(st, n, pts[0], pts[2], pts[1], uvs[0], uvs[2], uvs[1])
	_tri(st, n, pts[0], pts[3], pts[2], uvs[0], uvs[3], uvs[2])
	st.set_color(Color.WHITE)

## A doorway: a whole cell (owner: 1×1×2.3 like a wall). The lintel above 2.1 m is in the
## surrounding wall's material; below it the door fills the cell — two halves that slide
## apart into the walls (station, bunker, asteroid) or one wooden block that slides aside.
## FirstPerson moves the leaves.
static func _door(node: Node3D, grid: Grid, at: Vector2i, env: String, mats: Dictionary,
		wall_st: Dictionary, roofed: bool) -> Node3D:
	var x := float(at.x)
	var z := float(at.y)
	var along_x := _runs_x(grid, at)
	var kind := "brick"
	var accent := Color(0, 0, 0, 0)
	for d: Vector2i in Grid.N4:
		var n := at + d
		if grid.in_bounds(n) and is_wall(grid.cell_fast(n.x, n.y)):
			kind = FirstPersonArt.wall_kind(grid, n, env)
			accent = FirstPersonArt.accent_of(grid, n)
			break
	var ws := _wall_st(wall_st, kind, Color(0, 0, 0, 0))
	var lintel := 2.1
	for d: Vector2i in Grid.N4:
		_wall_face(ws, at, d, lintel, CEIL, _shade(d))
	if not roofed:
		_quad_up(ws, Vector3(x, CEIL, z), Vector3(x + 1, CEIL, z + 1), Rect2(0, 0, 1, 0.04))
	_quad_down(ws, Vector3(x, lintel, z), Vector3(x + 1, lintel, z + 1), Rect2(0, 0.05, 1, 0.05))
	var wood := env in ["town", "field"]
	var door := Node3D.new()
	door.position = Vector3(x, 0, z)
	door.set_meta("cell", at)
	door.set_meta("along_x", along_x)
	var mat: Material = mats["door_mat"].call("wood" if wood else "metal", accent)
	var leaves := 1 if wood else 2
	var w := 1.0 / leaves
	for k in leaves:
		var leaf := MeshInstance3D.new()
		var st := _st()
		# Width w along the wall line, the full cell across it; built round its own centre.
		var half := Vector3(w * 0.5, 0, 0.5) if along_x else Vector3(0.5, 0, w * 0.5)
		_box(st, -half, half + Vector3(0, lintel, 0), Rect2(0, 0, 1, 1))
		leaf.mesh = st.commit()
		leaf.material_override = mat
		var c := w * 0.5 + k * w
		leaf.position = Vector3(c, 0, 0.5) if along_x else Vector3(0.5, 0, c)
		leaf.set_meta("home", leaf.position)
		leaf.set_meta("side", -1 if k == 0 else 1)
		door.add_child(leaf)
	node.add_child(door)
	return door

## A side face of the box lo..hi on side d (one of N4).
static func _face(st: SurfaceTool, lo: Vector3, hi: Vector3, d: Vector2i, uv: Rect2,
		col := Color.WHITE) -> void:
	match d:
		Vector2i(0, -1):
			_quad(st, Vector3.FORWARD, Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z),
					Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), uv, col, true)
		Vector2i(0, 1):
			_quad(st, Vector3.BACK, Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
					Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), uv, col, true)
		Vector2i(-1, 0):
			_quad(st, Vector3.LEFT, Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z),
					Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z), uv, col, true)
		Vector2i(1, 0):
			_quad(st, Vector3.RIGHT, Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, lo.y, lo.z),
					Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), uv, col, true)

## A box with its art: the top shows uv, each side a band of uv along that edge, so the
## sides carry the object's own colours and detail rather than a flat paint.
static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3, uv: Rect2, sides := true) -> void:
	_quad_up(st, Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), uv)
	if not sides:
		return
	# The sides wear a strip from the middle of the picture: its edges are often
	# see-through on the board and would cut holes in the sides.
	var mid := Rect2(uv.position + uv.size * 0.35, uv.size * 0.3)
	_face(st, lo, hi, Vector2i(0, -1), mid, Color(0.86, 0.86, 0.86))
	_face(st, lo, hi, Vector2i(0, 1), mid, Color(0.72, 0.72, 0.72))
	_face(st, lo, hi, Vector2i(-1, 0), mid, Color(0.8, 0.8, 0.8))
	_face(st, lo, hi, Vector2i(1, 0), mid, Color(0.76, 0.76, 0.76))

## An upright n-sided prism (or a frustum: r0 at the bottom, r1 at the top).
static func _cyl(st: SurfaceTool, c: Vector3, r0: float, r1: float, h: float, uv: Rect2, n := 10) -> void:
	var mid := uv.get_center()
	var cap := Rect2(mid - uv.size * 0.25, uv.size * 0.5)
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var nn := ((d0 + d1) * 0.5).normalized()
		var b0 := c + d0 * r0
		var b1 := c + d1 * r0
		var t0 := c + d0 * r1 + Vector3(0, h, 0)
		var t1 := c + d1 * r1 + Vector3(0, h, 0)
		var shade := 0.75 + 0.25 * maxf(0.0, nn.dot(Vector3(0.3, 0, -0.95)))
		_quad(st, nn, b1, b0, t0, t1, Rect2(uv.position + Vector2(uv.size.x * i / n, 0), Vector2(uv.size.x / n, uv.size.y)),
				Color(shade, shade, shade), true)
		_tri(st, Vector3.UP, c + Vector3(0, h, 0), t0, t1, cap.get_center(), cap.position, cap.end)

## A rounded blob of foliage: two frustums meeting at the widest point.
static func _blob(st: SurfaceTool, c: Vector3, r: float, y0: float, y1: float, uv: Rect2) -> void:
	var mid := y0 + (y1 - y0) * 0.45
	_cyl(st, Vector3(c.x, y0, c.z), r * 0.55, r, mid - y0, uv, 9)
	_cyl(st, Vector3(c.x, mid, c.z), r, r * 0.35, y1 - mid, uv, 9)

# --- Furniture ---------------------------------------------------------------------------

## Build one piece; returns its light (if it shines) as [position, colour, range, energy].
static func _furniture(st: SurfaceTool, glow: SurfaceTool, grid: Grid, at: Vector2i, fid: String,
		uv: Rect2, bb: Rect2, roofed: bool, turn: Variant, bills: Array = [], group := Rect2()) -> Array:
	var base := fid
	for key: String in SHAPES:
		if fid == key or fid.begins_with(key + "_"):
			base = key
			break
	var spec: Array = SHAPES.get(base, ["box", Furniture.height_of(fid)])
	var shape: String = spec[0]
	var h: float = float(spec[1])
	if roofed:
		h = minf(h, CEIL - 0.05)
	var x := float(at.x)
	var z := float(at.y)
	# Footprint from the art; a piece that runs on into the next cell keeps going.
	var fx0 := x + bb.position.x
	var fz0 := z + bb.position.y
	var fx1 := x + bb.end.x
	var fz1 := z + bb.end.y
	var joins := {}
	for d: Vector2i in Grid.N4:
		var n := at + d
		joins[d] = grid.in_bounds(n) and grid.cell_fast(n.x, n.y).feature_id == fid
	var multi := false
	for d: Vector2i in joins:
		multi = multi or joins[d]
	if multi and group.size != Vector2.ZERO:
		# This cell's slice of the whole piece.
		fx0 = maxf(group.position.x, x)
		fz0 = maxf(group.position.y, z)
		fx1 = minf(group.end.x, x + 1)
		fz1 = minf(group.end.y, z + 1)
		bb = Rect2(fx0 - x, fz0 - z, fx1 - fx0, fz1 - fz0)
	var tuv := Rect2(uv.position + uv.size * bb.position, uv.size * bb.size)
	var dot := Rect2(tuv.get_center() - tuv.size * 0.05, tuv.size * 0.1)   # the art's own colour
	var back := Vector2i(0, -1)   # the side a chair's back stands on
	if turn is Array and (turn as Array).size() > 1:
		back = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)][int(turn[1]) % 4]
	var lo := Vector3(fx0, 0, fz0)
	var hi := Vector3(fx1, h, fz1)
	var cx := (fx0 + fx1) * 0.5
	var cz := (fz0 + fz1) * 0.5
	var r := minf(fx1 - fx0, fz1 - fz0) * 0.5
	match shape:
		"table", "cart", "desk":
			var top := 0.05
			_box(st, Vector3(fx0, h - top, fz0), Vector3(fx1, h, fz1), tuv)
			if shape == "desk":
				for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0)]:
					if joins[d]: continue
					var px := fx0 if d.x < 0 else fx1 - 0.05
					_box(st, Vector3(px, 0, fz0 + 0.03), Vector3(px + 0.05, h - top, fz1 - 0.03), dot)
			else:
				_legs(st, lo, Vector3(fx1, h - top, fz1), dot, joins)
			if shape == "cart":
				_box(st, Vector3(fx0, 0.15, fz0), Vector3(fx1, 0.19, fz1), tuv)
		"chair":
			var seat := 0.46
			_box(st, Vector3(fx0, seat - 0.05, fz0), Vector3(fx1, seat, fz1), tuv)
			_legs(st, lo, Vector3(fx1, seat - 0.05, fz1), dot, {})
			_backrest(st, lo, Vector3(fx1, h, fz1), back, seat, dot)
		"armchair":
			_box(st, lo, Vector3(fx1, 0.42, fz1), tuv)
			_backrest(st, lo, Vector3(fx1, h, fz1), back, 0.42, dot, 0.18)
		"bench":
			_box(st, Vector3(fx0, h - 0.05, fz0), Vector3(fx1, h, fz1), tuv)
			_legs(st, lo, Vector3(fx1, h - 0.05, fz1), dot, joins)
		"toilet":
			_cyl(st, Vector3(cx, 0, cz), r * 0.75, r * 0.85, 0.42, dot)
			_backrest(st, lo, Vector3(fx1, h, fz1), back, 0.42, dot, 0.2)
		"bed":
			_box(st, Vector3(fx0, 0.12, fz0), Vector3(fx1, h, fz1), tuv)
			_legs(st, lo, Vector3(fx1, 0.12, fz1), dot, joins)
			if not joins[back]:
				_backrest(st, lo, Vector3(fx1, 1.0, fz1), back, h, dot, 0.08)
		"bunk":
			_box(st, Vector3(fx0, 0.3, fz0), Vector3(fx1, 0.45, fz1), tuv)
			_box(st, Vector3(fx0, 1.35, fz0), Vector3(fx1, 1.5, fz1), tuv)
			_legs(st, lo, Vector3(fx1, h, fz1), dot, joins, 0.06)
		"shelf":
			for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0)]:
				if joins[d]: continue
				var px := fx0 if d.x < 0 else fx1 - 0.04
				_box(st, Vector3(px, 0, fz0), Vector3(px + 0.04, h, fz1), dot)
			var backz := fz0 if back.y < 0 else fz1 - 0.03
			_box(st, Vector3(fx0, 0, backz), Vector3(fx1, h, backz + 0.03), dot)
			for k in 5:
				var yy := 0.05 + (h - 0.08) * k / 4.0
				_box(st, Vector3(fx0, yy, fz0), Vector3(fx1, yy + 0.03, fz1), tuv)
		"cyl":
			_cyl(st, Vector3(cx, 0, cz), r, r, h, tuv)
		"plant":
			_cyl(st, Vector3(cx, 0, cz), r * 0.45, r * 0.55, 0.4, dot)
			bills.append([Vector3(cx, 0.32, cz), Vector2(0.75, 0.75), at, bb, "leaves"])
		"bush":
			bills.append([Vector3(cx, 0.0, cz), Vector2(1.1, h), at, bb, "leaves"])
		"tree":
			var crown := 2.9 if not roofed else 1.3
			var crown_y := h - crown if not roofed else CEIL - 0.05 - crown
			# The trunk runs up into the crown's foot: no floating leaves, no stick across it.
			_cyl(st, Vector3(cx, 0, cz), 0.14, 0.09, crown_y + crown * 0.28, Rect2(dot.position, dot.size), 8)
			bills.append([Vector3(cx, crown_y, cz), Vector2(crown, crown), at, bb, "crown"])
		"tv":
			_box(st, lo, Vector3(fx1, h, fz1), tuv)
			var tz := cz
			_box(glow, Vector3(fx0 + 0.05, h, tz - 0.03), Vector3(fx1 - 0.05, minf(h + 0.55, CEIL - 0.05), tz + 0.03), dot)
		"cooler":
			_box(st, lo, Vector3(fx1, 1.0, fz1), tuv)
			_cyl(st, Vector3(cx, 1.0, cz), r * 0.6, r * 0.6, h - 1.0, dot)
		"target":
			_cyl(st, Vector3(cx, 0, cz), 0.04, 0.04, h - 0.6, dot, 6)
			_box(st, Vector3(fx0, h - 0.8, cz - 0.03), Vector3(fx1, h, cz + 0.03), tuv)
		"tub":
			_box(st, lo, Vector3(fx1, 0.08, fz1), tuv)
			for d: Vector2i in Grid.N4:
				if joins[d]: continue
				var wlo := lo
				var whi := Vector3(fx1, h, fz1)
				match d:
					Vector2i(-1, 0): whi.x = fx0 + 0.07
					Vector2i(1, 0): wlo.x = fx1 - 0.07
					Vector2i(0, -1): whi.z = fz0 + 0.07
					Vector2i(0, 1): wlo.z = fz1 - 0.07
				_box(st, wlo, whi, dot)
		"shower":
			_box(st, lo, Vector3(fx1, 0.08, fz1), tuv)
			_box(glow, Vector3(fx0, CEIL - 0.25, fz0), Vector3(fx0 + 0.15, CEIL - 0.2, fz0 + 0.15), dot)
		"street":
			# Pole, an arm reaching out over the road, a flat head lit underneath.
			var top_y := h if not roofed else CEIL - 0.1
			_cyl(st, Vector3(cx, 0, cz), 0.09, 0.06, top_y, dot, 8)
			var arm := Vector3(0.9, 0, 0)
			_box(st, Vector3(cx - 0.03, top_y - 0.08, cz - 0.03), Vector3(cx + arm.x, top_y - 0.02, cz + 0.03), dot)
			var hx := cx + arm.x
			_box(st, Vector3(hx - 0.28, top_y - 0.16, cz - 0.14), Vector3(hx + 0.18, top_y - 0.04, cz + 0.14), dot)
			_quad_down(glow, Vector3(hx - 0.24, top_y - 0.165, cz - 0.11), Vector3(hx + 0.14, top_y - 0.165, cz + 0.11), dot)
			var scol := Furniture.light_color_of(fid, grid.tint_at(at.x, at.y))
			var sdef := Furniture.def_of(fid)
			return [Vector3(hx - 0.05, top_y - 0.25, cz), scol, float(sdef.get("light_range", 9.0)) * 1.2,
					float(sdef.get("light_energy", 1.0)) * Furniture.light_scale_of(grid.tint_at(at.x, at.y)) * 1.6, "spot"]
		"pole", "flood", "bollard":
			var pole_h := h if shape != "bollard" else h - 0.15
			_cyl(st, Vector3(cx, 0, cz), 0.05 if shape != "bollard" else 0.11, 0.04 if shape != "bollard" else 0.1,
					pole_h, dot, 8)
			var head := Vector3(cx, pole_h, cz)
			if shape == "pole":
				# A lampshade: wide below, narrow on top, glowing.
				_cyl(glow, head - Vector3(0, 0.3, 0), 0.22, 0.12, 0.3, dot, 10)
			elif shape == "flood":
				_box(glow, head - Vector3(0.18, 0.12, 0.08), head + Vector3(0.18, 0.12, 0.08), dot)
			else:
				_cyl(glow, head, 0.1, 0.1, 0.15, dot, 8)
		_:
			_box(st, lo, hi, tuv)
	if not Furniture.emits_light(fid):
		return []
	var col := Furniture.light_color_of(fid, grid.tint_at(at.x, at.y))
	var def := Furniture.def_of(fid)
	var y := minf(h, CEIL - 0.1) if shape in ["pole", "flood", "bollard"] else minf(h + 0.3, CEIL - 0.1)
	return [Vector3(cx, y, cz), col, float(def.get("light_range", 4.0)) * 1.3,
			float(def.get("light_energy", 0.6)) * Furniture.light_scale_of(grid.tint_at(at.x, at.y))]

static func _legs(st: SurfaceTool, lo: Vector3, hi: Vector3, uv: Rect2, joins: Dictionary, t := 0.05) -> void:
	for sx: int in [-1, 1]:
		for sz: int in [-1, 1]:
			# No leg where the piece goes on into the next cell on that side.
			if joins.get(Vector2i(sx, 0), false) or joins.get(Vector2i(0, sz), false):
				continue
			var px := lo.x + 0.03 if sx < 0 else hi.x - 0.03 - t
			var pz := lo.z + 0.03 if sz < 0 else hi.z - 0.03 - t
			_box(st, Vector3(px, lo.y, pz), Vector3(px + t, hi.y, pz + t), uv)

static func _backrest(st: SurfaceTool, lo: Vector3, hi: Vector3, back: Vector2i, from_y: float,
		uv: Rect2, t := 0.06) -> void:
	var blo := Vector3(lo.x, from_y, lo.z)
	var bhi := Vector3(hi.x, hi.y, hi.z)
	match back:
		Vector2i(0, -1): bhi.z = lo.z + t
		Vector2i(0, 1): blo.z = hi.z - t
		Vector2i(-1, 0): bhi.x = lo.x + t
		Vector2i(1, 0): blo.x = hi.x - t
	_box(st, blo, bhi, uv)

## A lamp on a wall face: a glowing fitting near the top of the wall, its light just off it.
static func _wall_lamp(at: Vector2i, lamp: Array, glow: SurfaceTool, roofed_env := false) -> Array:
	var id := str(lamp[0])
	var side := int(lamp[2]) % 4
	var tint := int(lamp[3]) if lamp.size() > 3 else 0
	var d: Vector2i = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)][side]
	var c := Vector3(at.x + 0.5, 1.95, at.y + 0.5) + Vector3(d.x, 0, d.y) * 0.5
	var along := Vector3(absf(d.y), 0, absf(d.x)) * 0.22
	var out := Vector3(d.x, 0, d.y) * 0.07
	var p0 := c - along - Vector3(0, 0.06, 0)
	var p1 := c + along + Vector3(0, 0.06, 0) + out
	_box(glow, p0.min(p1), p0.max(p1), Rect2(0, 0, 1, 1))
	var def := Furniture.def_of(id)
	# On open maps the light sits out in the room below the fitting: right under the ceiling
	# it burned the plaster white (owner: "insane ceiling glow"). Stations keep the old look.
	var pos := c + Vector3(d.x, 0, d.y) * 0.35 if roofed_env else c + Vector3(d.x, 0, d.y) * 0.6 - Vector3(0, 0.35, 0)
	return [pos, Furniture.light_color_of(id, tint),
			float(def.get("light_range", 6.0)) * 1.3, float(def.get("light_energy", 0.8)) * Furniture.light_scale_of(tint)]
