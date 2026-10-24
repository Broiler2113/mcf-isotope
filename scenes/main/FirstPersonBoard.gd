class_name FirstPersonBoard
extends RefCounted

## The board in 3D for the first-person view (fix-7 #9, rebuilt in fix-8). One cell is
## 1×1 m; walls go up to the ceiling (2.3 m). Station and bunker are roofed everywhere;
## elsewhere only the enclosed buildings are, and their roofs are seen from outside.
##
## What is built here, per chunk of CH×CH cells:
##  * floors from the battle screen's own floor bake (TerrainTiles.FP_RES — the same blood,
##    debris and remembered looks), embossed by their own shading so tiles, planks and grass
##    have depth (owner: floors and walls looked flat);
##  * walls in their 3D materials (FirstPersonArt) with skirting inside and a plinth outside;
##  * every piece of furniture, feature, wall lamp, small item and lump of rubble as a real
##    model (FirstPersonModels), merged into one mesh;
##  * doors, which FirstPerson slides open.
## Light comes from the battle screen's own light map (LightManager), so 3D is lit exactly
## as 2D is (owner, fix-8). The map edge (MCF.FEATURE_BOUNDARY) has no tile on the board and
## so nothing here either: it only stops the walker (owner, fix-8).
## Everything is cosmetic: nothing here touches the game state.

const CH := 8            # cells per side of a 3D chunk
const CEIL := 2.3        # ceiling height, and the height of every wall
const ROOF_T := 0.32     # roof slab thickness above the ceiling
const EAVE := 0.22       # how far a roof overhangs its walls
const TRENCH := 2.0      # trench depth (owner): you can climb down into one
const LINTEL := 2.1      # top of a doorway

## One shader for the whole board. Light: the 2D light map at the point just in front of
## the face (a wall's side reads the floor before it, as on the board), five taps blurred
## like the battle screen's composite; a flat face shade gives shapes their form. Fog: never
## seen is black, seen but out of sight dimmed. SUN marks the lit variant for daylight
## outdoors: the sun's shadows take back part of the light (sun_k) where they fall.
const SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque, unshaded;
uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2DArray mats : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool use_mats = false;
uniform sampler2D vis : filter_nearest, repeat_disable;
uniform sampler2D solid : filter_nearest;
uniform vec2 board = vec2(1.0);
uniform sampler2D lightmap : source_color, filter_linear;
uniform vec4 lm_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 lm_px = vec2(0.01);
uniform bool lm_on = true;
uniform vec3 flat_light : source_color = vec3(1.0);
uniform float cut = 0.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform bool team_stripe = false;
uniform bool stripe_mask = false;
uniform float stripe_half_width = 0.138;
uniform vec4 team_color : source_color = vec4(1.0);
uniform float relief = 0.0;
uniform bool ground_ao = false;
uniform sampler2DArray grounds : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D ground_kind : filter_nearest;
uniform bool has_ground = false;
uniform bool winter = false;
uniform float sun_k = 0.0;
uniform float glow_k = 1.7;
uniform bool no_fog = false;
uniform float render_radius = 1000.0;
uniform bool sight_only = false;
uniform vec4 door_bounds = vec4(0.0);
varying highp vec3 wpos;
varying highp vec3 wnorm;
varying vec3 model_pos;
varying vec3 model_normal;
void vertex() {
	model_pos = VERTEX;
	model_normal = NORMAL;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }
vec3 light_at(vec2 p) {
	if (!lm_on) return flat_light;
	vec2 uv = (p - lm_rect.xy) / lm_rect.zw;
	vec2 o = lm_px * 0.85;
	vec3 c = texture(lightmap, uv).rgb * 0.36;
	c += texture(lightmap, uv + vec2(o.x, o.y)).rgb * 0.16;
	c += texture(lightmap, uv + vec2(-o.x, o.y)).rgb * 0.16;
	c += texture(lightmap, uv + vec2(o.x, -o.y)).rgb * 0.16;
	c += texture(lightmap, uv + vec2(-o.x, -o.y)).rgb * 0.16;
	return c;
}
float solid_at(vec2 cell) { return texture(solid, (cell + 0.5) / board).r; }
// Open ground lies under the floor's picture where it is see-through: one seamless 8 m
// tile of turf or earth (snow in winter) by world position, so no grid of tiles shows.
vec4 base_at(vec2 uv, vec2 xz) {
	vec4 c = texture(tex, uv);
	if (has_ground && c.a < 0.99) {
		float k = texture(ground_kind, (floor(xz) + 0.5) / board).r * 255.0;
		float layer = winter ? 2.0 : (k > 1.5 ? 1.0 : 0.0);
		vec3 g = texture(grounds, vec3(xz / 8.0, layer)).rgb;
		c = vec4(mix(g, c.rgb, c.a), 1.0);
	}
	return c;
}
void fragment() {
	if (!no_fog && distance(wpos, INV_VIEW_MATRIX[3].xyz) > render_radius) discard;
	// Sliding leaves stay inside their opening even after an adjacent wall is destroyed.
	if (door_bounds.z > 0.0 && (wpos.x <= door_bounds.x || wpos.z <= door_bounds.y ||
			wpos.x >= door_bounds.z || wpos.z >= door_bounds.w)) discard;
	vec4 c;
	bool emit = COLOR.a < 0.5;
	if (use_mats) {
		c = texture(mats, vec3(UV, UV2.x));
		c.rgb *= COLOR.rgb;
		c.a = 1.0;
	} else {
		c = base_at(UV, wpos.xz);
		if (relief > 0.0) {
			// The picture's own shading as height, lit from the upper left: one texel's step.
			vec2 ts = 1.0 / vec2(textureSize(tex, 0));
			vec4 d = base_at(UV - ts, wpos.xz - vec2(1.0 / 32.0));
			c.rgb *= clamp(1.0 + relief * (lum(c.rgb) - lum(d.rgb)) * 2.2, 0.72, 1.3);
		}
		c.rgb *= COLOR.rgb;
	}
	c *= tint;
	// A narrow identification stripe follows the roof when hull/turret turn.
	// Use model coordinates so it never slides with the vehicle's world position.
	bool on_stripe = team_stripe && abs(model_pos.z) <= stripe_half_width && model_normal.y > 0.8;
	if (stripe_mask) c.rgb = vec3(on_stripe ? 1.0 : 0.0);
	else if (on_stripe) c.rgb = vec3(lum(c.rgb)) * team_color.rgb;
	if (c.a < cut) discard;
	vec2 cell = floor(wpos.xz - wnorm.xz * 0.02);
	float v = 0.0;
	if (no_fog) v = 1.0;
	else if (all(greaterThanEqual(cell, vec2(0.0))) && all(lessThan(cell, board))) {
		v = texelFetch(vis, ivec2(cell), 0).r;
	}
	if (sight_only && v < 0.7) discard;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	if (v < 0.2) {
		ALBEDO = vec3(0.0);
		//SUN EMISSION = vec3(0.0);
	} else {
		float k = v < 0.7 ? 0.38 : 1.0;
		vec3 n = wnorm;
		float face = n.y > 0.5 ? 1.0 : (n.y < -0.5 ? 0.74 : mix(0.8, 0.9, abs(n.z)));
		float ao = 1.0;
		if (ground_ao) {
			if (n.y > 0.5 && wpos.y < 0.05) {
				// The floor darkens along walls and under furniture.
				vec2 f = fract(wpos.xz);
				vec2 id = floor(wpos.xz);
				float sl = solid_at(id + vec2(-1.0, 0.0));
				float sr = solid_at(id + vec2(1.0, 0.0));
				float st = solid_at(id + vec2(0.0, -1.0));
				float sb = solid_at(id + vec2(0.0, 1.0));
				ao -= 0.3 * sl * (1.0 - smoothstep(0.0, 0.42, f.x));
				ao -= 0.3 * sr * (1.0 - smoothstep(0.0, 0.42, 1.0 - f.x));
				ao -= 0.3 * st * (1.0 - smoothstep(0.0, 0.42, f.y));
				ao -= 0.3 * sb * (1.0 - smoothstep(0.0, 0.42, 1.0 - f.y));
				ao -= 0.2 * solid_at(id + vec2(-1.0, -1.0)) * (1.0 - max(sl, st)) * (1.0 - smoothstep(0.0, 0.42, length(f)));
				ao -= 0.2 * solid_at(id + vec2(1.0, -1.0)) * (1.0 - max(sr, st)) * (1.0 - smoothstep(0.0, 0.42, length(f - vec2(1.0, 0.0))));
				ao -= 0.2 * solid_at(id + vec2(-1.0, 1.0)) * (1.0 - max(sl, sb)) * (1.0 - smoothstep(0.0, 0.42, length(f - vec2(0.0, 1.0))));
				ao -= 0.2 * solid_at(id + vec2(1.0, 1.0)) * (1.0 - max(sr, sb)) * (1.0 - smoothstep(0.0, 0.42, length(f - vec2(1.0, 1.0))));
				float own = solid_at(id);
				if (own < 0.95) ao -= 0.32 * own * smoothstep(0.5, 0.2, length(f - 0.5));
				ao = max(ao, 0.45);
			} else if (abs(n.y) < 0.5) {
				// Walls darken toward the floor and a little under the ceiling.
				ao = (0.7 + 0.3 * smoothstep(0.0, 0.5, wpos.y)) * (0.9 + 0.1 * smoothstep(2.3, 1.9, wpos.y));
			}
		}
		vec3 lit = emit ? vec3(glow_k) : light_at(wpos.xz + n.xz * 0.3) * face * ao;
		ALBEDO = c.rgb * lit * k;
		//SUN EMISSION = emit ? ALBEDO : ALBEDO * (1.0 - sun_k);
		//SUN if (emit) ALBEDO = vec3(0.0);
	}
}
//SUN void light() {
//SUN 	DIFFUSE_LIGHT += ATTENUATION * step(0.001, dot(NORMAL, LIGHT)) * sun_k * LIGHT_COLOR / PI;
//SUN }
"""

## The shader for daylight outdoors: lit by the one sun, which casts the shadows.
static func sun_shader_code() -> String:
	return SHADER.replace("render_mode cull_back, depth_draw_opaque, unshaded;", "render_mode cull_back, depth_draw_opaque;") \
			.replace("//SUN ", "")

## Soldiers: a flat 1.7 m cut-out in its side's colour that turns to face you (owner: keep
## them as they are). Lit by the light map like the board, never below half: on the battle
## screen tokens are never darkened.
const BILLBOARD := """
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, unshaded;
uniform sampler2D tex : source_color, filter_nearest;
uniform sampler2D vis : filter_nearest, repeat_disable;
uniform vec2 board = vec2(1.0);
uniform float render_radius = 1000.0;
uniform sampler2D lightmap : source_color, filter_linear;
uniform vec4 lm_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 lm_px = vec2(0.01);
uniform bool lm_on = true;
uniform vec3 flat_light : source_color = vec3(1.0);
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
	if (distance(base, INV_VIEW_MATRIX[3].xyz) > render_radius) discard;
	if (c.a < 0.5) discard;
	vec2 cell = floor(base.xz);
	if (any(lessThan(cell, vec2(0.0))) || any(greaterThanEqual(cell, board))) discard;
	float v = texelFetch(vis, ivec2(cell), 0).r;
	if (v < 0.2) discard;
	vec3 l = lm_on ? texture(lightmap, (base.xz - lm_rect.xy) / lm_rect.zw).rgb : flat_light;
	ALBEDO = c.rgb * max(l, vec3(0.5)) * (v < 0.7 ? 0.38 : 1.0);
}
"""

## Cells under a ceiling: 1 for every cell inside a building, its walls included.
## Station and bunker are roofed throughout (but not over open space); elsewhere a cell
## is inside when no walkable way leads to the map edge, grass and dirt paths, or space,
## without crossing a wall, glass or a door.
static func roofed(grid: Grid, env: String) -> PackedByteArray:
	var native := NativeKernels.terrain()
	if native != null:
		var result: PackedByteArray = native.roofed(grid.cells_flat(), grid.width, grid.height, grid.floor_look,
			env in ["station", "bunker"], {"boundary": MCF.FEATURE_BOUNDARY, "airlock": MCF.FEATURE_AIRLOCK,
			"glass": [MCF.FEATURE_GLASS, MCF.FEATURE_ARMOR_GLASS], "wall_height": MCF.WALL_HEIGHT,
			"grass_type": MCF.FLOOR_GRASS, "grass_look": MCF.Look.GRASS, "dirt_look": MCF.Look.DIRT})
		if result.size() == grid.width * grid.height: return result
	return _roofed_gd(grid, env)

static func _roofed_gd(grid: Grid, env: String) -> PackedByteArray:
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
	if c.feature_id == MCF.FEATURE_BOUNDARY:
		return false
	return c.cover_height >= MCF.WALL_HEIGHT or c.feature_id == MCF.FEATURE_AIRLOCK \
			or MCF.is_glass(c.feature_id)

## A cell drawn as a solid wall block. Sandbag walls and hedgehogs on bags are modelled
## instead; the map's edge has no picture at all, except the bunker's rock.
static func is_wall(c: GridCell, env := "") -> bool:
	if c.cover_height < MCF.WALL_HEIGHT or MCF.is_glass(c.feature_id) or c.feature_id == MCF.FEATURE_AIRLOCK \
			or Furniture.is_furniture(c.feature_id):
		return false
	match c.feature_id:
		MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS:
			return false
		MCF.FEATURE_BOUNDARY:
			return env == "bunker"
	return true

## How much a cell shades the floor next to it (one texel a cell for the shader): a wall
## fully, tall furniture and bag walls much, low things a little.
static func solid_value(c: GridCell, env: String) -> float:
	if is_wall(c, env) or c.feature_id == MCF.FEATURE_AIRLOCK:
		return 1.0
	if c.feature_id in [MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS]:
		return 0.85
	if Furniture.is_furniture(c.feature_id):
		var h := Furniture.height_of(c.feature_id)
		return 0.7 if h >= 1.5 else (0.45 if h >= 1.0 else 0.3)
	if c.feature_id in [MCF.FEATURE_SANDBAGS, MCF.FEATURE_DIRT_PILE, MCF.FEATURE_DPMG, MCF.FEATURE_DRONE_STATION]:
		return 0.5
	if c.feature_id == MCF.FEATURE_HEDGEHOG:
		return 0.25
	return 0.0

## A shader material for the board.
static func material(shader: Shader, p: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	for k: String in p:
		m.set_shader_parameter(k, p[k])
	return m

# --- One chunk -------------------------------------------------------------------------

## The chunk at cc (in chunks of CH cells) → {"node": Node3D, "doors": {cell: Node3D},
## "tops": {cell: height things lie on}}. ctx: "env", "mats" (floor/floor_cut per tile
## chunk, models, glass, ceiling, roof, wall: Callable(kind, accent), door: Callable(style,
## accent)), "look": Callable(cell, fid) -> [mask, inner, k, corner], "tod", "decals" (the
## battle screen's settled cosmetics in this area), "map_decals".
static func build(grid: Grid, cc: Vector2i, roof: PackedByteArray, ctx: Dictionary) -> Dictionary:
	var job := begin_build(grid, cc, roof, ctx)
	job.advance.call(9223372036854775807)
	return job.finish.call()

## A chunk can be prepared over several frames without exposing a half-built
## board. Its completed node is attached only after all cells and models are ready.
static func begin_build(grid: Grid, cc: Vector2i, roof: PackedByteArray, ctx: Dictionary) -> Dictionary:
	var node := Node3D.new()
	var env: String = ctx["env"]
	var mats: Dictionary = ctx["mats"]
	var floors := {}     # tile chunk -> Sink
	var floors_cut := {}
	var walls := {}      # "kind|accent" -> Sink
	var ceil_s := _sink()
	var roof_s := _sink()
	var models := SurfaceTool.new()
	models.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glass := SurfaceTool.new()
	glass.begin(Mesh.PRIMITIVE_TRIANGLES)
	var loose := FirstPersonModels.Sink.new()       # built in place: items, rubble, trims, glass frames
	var loose_glass := FirstPersonModels.Sink.new()
	var counts := {"models": 0, "glass": 0}
	var doors := {}
	var tops := {}
	var w := grid.width
	var x0 := cc.x * CH
	var y0 := cc.y * CH
	var x1 := mini(x0 + CH, w)
	var y1 := mini(y0 + CH, grid.height)
	var cursor := [x0, y0]
	var advance := func(deadline: int) -> bool:
		while cursor[1] < y1:
			if Time.get_ticks_usec() >= deadline: return false
			var x: int = cursor[0]
			var y: int = cursor[1]
			cursor[0] += 1
			if cursor[0] == x1: cursor[0] = x0; cursor[1] += 1
			var c := grid.cell_fast(x, y)
			var at := Vector2i(x, y)
			var tcc := Vector2i(x / TerrainTiles.C, y / TerrainTiles.C)
			var uv := _cell_uv(grid, tcc, at)
			var is_roofed: bool = roof[y * w + x] == 1
			var fid := c.feature_id
			var dug := fid == MCF.FEATURE_TRENCH
			var wall := is_wall(c, env)
			# --- Floor
			if dug:
				_quad_up(_wall_sink(walls, "trench", Color(0, 0, 0, 0)), Vector3(x, -TRENCH, y), Vector3(x + 1, -TRENCH, y + 1), Rect2(x / 8.0, y / 8.0, 0.125, 0.125))
				for d: Vector2i in Grid.N4:
					var n := at + d
					if grid.in_bounds(n) and grid.cell_fast(n.x, n.y).feature_id == MCF.FEATURE_TRENCH:
						continue
					_wall_face(_wall_sink(walls, "trench", Color(0, 0, 0, 0)), n, -d, -TRENCH, 0.0, true)
			elif not c.is_space and not wall:
				_quad_up(_sink_for(floors, tcc), Vector3(x, 0.0, y), Vector3(x + 1, 0.0, y + 1), uv)
			elif c.is_space:
				var look := grid.look_at(x, y) if not grid.floor_look.is_empty() else 0
				if look == MCF.Look.SOLAR:
					# Solar panels beside the station (owner, fix-8: they were missing).
					_add_model(models, counts, ["solar", (x * 7 + y * 3) % 4], Transform3D(Basis.IDENTITY, Vector3(x, 0, y)),
							func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void: FirstPersonModels.solar(s, (x * 7 + y * 3) % 4))
				elif MCF.FLOOR_OVERLAY_LOOKS.has(look):
					# A grating over open space: its bars, the stars between them.
					_quad_up(_sink_for(floors_cut, tcc), Vector3(x, 0.0, y), Vector3(x + 1, 0.0, y + 1), uv)
			if is_roofed:
				_roof(ceil_s, roof_s, grid, roof, at)
			# --- Walls
			if wall:
				var kind := FirstPersonArt.wall_kind(grid, at, env)
				var ws := _wall_sink(walls, kind, FirstPersonArt.accent_of(grid, at))
				for d: Vector2i in Grid.N4:
					var n := at + d
					if not grid.in_bounds(n) or is_wall(grid.cell_fast(n.x, n.y), env):
						continue
					_wall_face(ws, at, d, 0.0, CEIL)
					_trim(loose, grid, roof, env, kind, at, d)
				if not is_roofed:
					var top_c := Color(0.92, 0.94, 0.98) if ctx.get("winter", false) else FirstPersonArt.wall_top_colour(kind)
					loose.box(Vector3(x, CEIL, y), Vector3(x + 1, CEIL + 0.001, y + 1), FirstPersonArt.M_CONCRETE, top_c, FirstPersonModels.Sink.NO_BOTTOM | FirstPersonModels.Sink.NO_BACK | FirstPersonModels.Sink.NO_FRONT | FirstPersonModels.Sink.NO_LEFT | FirstPersonModels.Sink.NO_RIGHT)
				for lamp: Array in c.lamps:
					_wall_lamp(models, counts, grid, at, lamp)
				continue
			if MCF.is_glass(fid):
				_glass(loose, loose_glass, grid, env, at, fid == MCF.FEATURE_ARMOR_GLASS)
				continue
			if fid == MCF.FEATURE_AIRLOCK:
				doors[at] = _door(node, grid, at, env, mats, walls, is_roofed)
				continue
			var cap := CEIL - 0.03 if is_roofed else 9.0
			if Furniture.is_furniture(fid):
				_piece(models, glass, counts, grid, at, fid, ctx, cap, tops)
				continue
			_feature(models, counts, grid, at, fid, env)
		return true
	var finish := func() -> Dictionary:
		# Small things lying about: the map's items, knocked items and rubble.
		_items(loose, grid, cc, tops)
		_decals(loose, ctx.get("decals", []), Rect2(x0, y0, x1 - x0, y1 - y0))
		_decals(loose, ctx.get("map_decals", []), Rect2(x0, y0, x1 - x0, y1 - y0))
		if not loose.empty():
			models.append_from(loose.mesh(), 0, Transform3D.IDENTITY)
			counts["models"] += 1
		if not loose_glass.empty():
			glass.append_from(loose_glass.mesh(), 0, Transform3D.IDENTITY)
			counts["glass"] += 1
		for tcc: Vector2i in floors:
			_add(node, (floors[tcc] as FirstPersonModels.Sink).mesh(), mats["floor"].get(tcc), false)
		for tcc: Vector2i in floors_cut:
			_add(node, (floors_cut[tcc] as FirstPersonModels.Sink).mesh(), mats["floor_cut"].get(tcc), false)
		_add(node, ceil_s.mesh(), mats["ceiling"], false)
		_add(node, roof_s.mesh(), mats["roof"], true)
		for key: String in walls:
			var parts := key.split("|")
			_add(node, (walls[key] as FirstPersonModels.Sink).mesh(), mats["wall"].call(parts[0], Color.html(parts[1]) if parts[1] != "" else Color(0, 0, 0, 0)), true)
		if counts["models"] > 0:
			_add(node, models.commit(), mats["models"], true)
		if counts["glass"] > 0:
			_add(node, glass.commit(), mats["glass"], false)
		return {"node": node, "doors": doors, "tops": tops}
	return {"node": node, "advance": advance, "finish": finish}

static func _sink() -> FirstPersonModels.Sink:
	var s := FirstPersonModels.Sink.new()
	s.shade_floor = false
	return s

static func _sink_for(by: Dictionary, key: Vector2i) -> FirstPersonModels.Sink:
	if not by.has(key):
		by[key] = _sink()
	return by[key]

static func _wall_sink(by: Dictionary, kind: String, accent: Color) -> FirstPersonModels.Sink:
	var key := "%s|%s" % [kind, accent.to_html() if accent.a > 0.0 else ""]
	if not by.has(key):
		by[key] = _sink()
	return by[key]

static func _add(node: Node3D, mesh: Mesh, mat: Material, shadows: bool) -> void:
	if mat == null or mesh == null or mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(mi)

## A cached model placed with xf into the chunk's merged mesh.
static func _add_model(models: SurfaceTool, counts: Dictionary, key: Array, xf: Transform3D, make: Callable,
		glass: SurfaceTool = null) -> void:
	var built: Array = FirstPersonModels.cached(str(key), make)
	if built[0] != null:
		models.append_from(built[0], 0, xf)
		counts["models"] += 1
	if built[1] != null and glass != null:
		glass.append_from(built[1], 0, xf)
		counts["glass"] += 1

## The cell's square in its tile chunk texture, in UV space.
static func _cell_uv(grid: Grid, tcc: Vector2i, at: Vector2i) -> Rect2:
	var cw := mini(TerrainTiles.C, grid.width - tcc.x * TerrainTiles.C)
	var chh := mini(TerrainTiles.C, grid.height - tcc.y * TerrainTiles.C)
	var lx := at.x % TerrainTiles.C
	var ly := at.y % TerrainTiles.C
	return Rect2(float(lx) / cw, float(ly) / chh, 1.0 / cw, 1.0 / chh)

## A floor quad facing up; the texture's top is north, as on the board.
static func _quad_up(s: FirstPersonModels.Sink, lo: Vector3, hi: Vector3, uv: Rect2) -> void:
	s.face_uv([Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)],
			Vector3.UP, [uv.position, Vector2(uv.end.x, uv.position.y), uv.end, Vector2(uv.position.x, uv.end.y)], Color.WHITE)

static func _quad_down(s: FirstPersonModels.Sink, lo: Vector3, hi: Vector3, uv: Rect2) -> void:
	s.face_uv([Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)],
			Vector3.DOWN, [uv.position, Vector2(uv.end.x, uv.position.y), uv.end, Vector2(uv.position.x, uv.end.y)], Color.WHITE)

## A wall's side toward d, from y0 to y1: the texture is a metre wide and the wall's full
## height, laid by world position so the pattern runs on unbroken from cell to cell.
static func _wall_face(s: FirstPersonModels.Sink, at: Vector2i, d: Vector2i, y0: float, y1: float, earth := false) -> void:
	var x := float(at.x)
	var z := float(at.y)
	var a: Vector3
	var b: Vector3
	match d:
		Vector2i(0, -1): a = Vector3(x + 1, 0, z); b = Vector3(x, 0, z)
		Vector2i(0, 1): a = Vector3(x, 0, z + 1); b = Vector3(x + 1, 0, z + 1)
		Vector2i(-1, 0): a = Vector3(x, 0, z); b = Vector3(x, 0, z + 1)
		_: a = Vector3(x + 1, 0, z + 1); b = Vector3(x + 1, 0, z)
	var ua := 0.0
	var ub := 1.0
	var v0 := 1.0 - y0 / CEIL
	var v1 := 1.0 - y1 / CEIL
	if earth:
		ua = (a.x if d.y != 0 else a.z) / 8.0
		ub = (b.x if d.y != 0 else b.z) / 8.0
		v0 = -y0 / 8.0
		v1 = -y1 / 8.0
	s.face_uv([a + Vector3(0, y0, 0), b + Vector3(0, y0, 0), b + Vector3(0, y1, 0), a + Vector3(0, y1, 0)],
			Vector3(d.x, 0, d.y), [Vector2(ua, v0), Vector2(ub, v0), Vector2(ub, v1), Vector2(ua, v1)], Color.WHITE)

## Skirting inside, a plinth outside: a wall's foot stands out from its face. Walls along x
## carry the trim round outer corners; walls along z stop at their cell, so no two trims
## ever share a face.
static func _trim(s: FirstPersonModels.Sink, grid: Grid, roof: PackedByteArray, env: String, kind: String, at: Vector2i, d: Vector2i) -> void:
	if kind in ["soil", "rock", "ldf", "corpse", "sandbag", "wood"]:
		return
	var n := at + d
	var inside: bool = roof[n.y * grid.width + n.x] == 1 or env in ["station", "bunker"]
	var depth := 0.02 if inside else 0.035
	var h := (0.1 if inside else 0.28) + (0.002 if d.x != 0 else 0.0)
	var col := Color(0.22, 0.22, 0.24) if inside else Color(0.5, 0.48, 0.45)
	if kind == "station" or kind == "bunker":
		col = Color(0.2, 0.21, 0.23)
	var x := float(at.x)
	var z := float(at.y)
	var lo: Vector3
	var hi: Vector3
	match d:
		Vector2i(0, -1): lo = Vector3(x, 0, z - depth); hi = Vector3(x + 1, h, z)
		Vector2i(0, 1): lo = Vector3(x, 0, z + 1); hi = Vector3(x + 1, h, z + 1 + depth)
		Vector2i(-1, 0): lo = Vector3(x - depth, 0, z); hi = Vector3(x, h, z + 1)
		_: lo = Vector3(x + 1, 0, z); hi = Vector3(x + 1 + depth, h, z + 1)
	if d.y != 0:
		# Round an outer corner: the wall ends here on that side.
		for sx: int in [-1, 1]:
			var side := at + Vector2i(sx, 0)
			if grid.in_bounds(side) and not is_wall(grid.cell_fast(side.x, side.y), env):
				if sx < 0: lo.x -= depth
				else: hi.x += depth
	var skip: int = FirstPersonModels.Sink.NO_BOTTOM | [FirstPersonModels.Sink.NO_FRONT, FirstPersonModels.Sink.NO_LEFT, FirstPersonModels.Sink.NO_BACK, FirstPersonModels.Sink.NO_RIGHT][[Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)].find(d)]
	var keep := s.shade_floor
	s.shade_floor = false
	s.box(lo, hi, FirstPersonArt.M_CONCRETE if not inside else FirstPersonArt.M_PLAIN, col, skip)
	s.shade_floor = keep

## Ceiling inside, and a thick roof slab outside that overhangs its open sides.
static func _roof(ceil_s: FirstPersonModels.Sink, roof_s: FirstPersonModels.Sink, grid: Grid, roof: PackedByteArray, at: Vector2i) -> void:
	var x := at.x
	var y := at.y
	var w := grid.width
	_quad_down(ceil_s, Vector3(x, CEIL, y), Vector3(x + 1, CEIL, y + 1), Rect2(x * 0.5, y * 0.5, 0.5, 0.5))
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
	_quad_up(roof_s, Vector3(lo.x, hi.y, lo.z), hi, Rect2(lo.x * 0.5, lo.z * 0.5, (hi.x - lo.x) * 0.5, (hi.z - lo.z) * 0.5))
	for d: Vector2i in open_sides:
		var a: Vector3
		var b: Vector3
		match d:
			Vector2i(0, -1): a = Vector3(hi.x, 0, lo.z); b = Vector3(lo.x, 0, lo.z)
			Vector2i(0, 1): a = Vector3(lo.x, 0, hi.z); b = Vector3(hi.x, 0, hi.z)
			Vector2i(-1, 0): a = Vector3(lo.x, 0, lo.z); b = Vector3(lo.x, 0, hi.z)
			_: a = Vector3(hi.x, 0, hi.z); b = Vector3(hi.x, 0, lo.z)
		roof_s.face_uv([a + Vector3(0, CEIL, 0), b + Vector3(0, CEIL, 0), b + Vector3(0, hi.y, 0), a + Vector3(0, hi.y, 0)],
				Vector3(d.x, 0, d.y), [Vector2(0, 0.16), Vector2(0.5, 0.16), Vector2(0.5, 0), Vector2(0, 0)], Color(0.72, 0.72, 0.72))
		var ulo := Vector3(x, CEIL, y)
		var uhi := Vector3(x + 1, CEIL, y + 1)
		match d:
			Vector2i(-1, 0): ulo.x = x - EAVE; uhi.x = x
			Vector2i(1, 0): ulo.x = x + 1; uhi.x = x + 1 + EAVE
			Vector2i(0, -1): ulo.z = y - EAVE; uhi.z = y
			Vector2i(0, 1): ulo.z = y + 1; uhi.z = y + 1 + EAVE
		_quad_down(roof_s, ulo, uhi, Rect2(0, 0, 0.2, 0.2))

static func _runs_x(grid: Grid, at: Vector2i) -> bool:
	var e := at + Vector2i(1, 0)
	var w := at + Vector2i(-1, 0)
	return (grid.in_bounds(e) and _barrier(grid.cell_fast(e.x, e.y))) \
			or (grid.in_bounds(w) and _barrier(grid.cell_fast(w.x, w.y)))

## Glass: a whole cell of it, as thick as the wall line (owner, fix-7), in a frame of rails
## at the floor and ceiling and posts where the run of glass ends. Its sides against a wall
## or more glass are left out: drawn there they fought the wall's own face and flickered.
static func _glass(s: FirstPersonModels.Sink, gs: FirstPersonModels.Sink, grid: Grid, env: String, at: Vector2i, armored: bool) -> void:
	var x := float(at.x)
	var z := float(at.y)
	var frame := Color(0.24, 0.25, 0.27) if env in ["station", "bunker", "asteroid"] or armored else Color(0.82, 0.81, 0.78)
	var m := FirstPersonArt.M_METAL if frame.r < 0.5 else FirstPersonArt.M_PLAIN
	var skips := _wall_skips(grid, env, at)
	var rail := 0.07 if not armored else 0.12
	gs.box(Vector3(x + 0.006, rail, z + 0.006), Vector3(x + 0.994, CEIL - rail, z + 0.994), 0,
			Color(0.55, 0.72, 0.8) if armored else Color(0.62, 0.8, 0.9), skips | FirstPersonModels.Sink.NO_TOP | FirstPersonModels.Sink.NO_BOTTOM)
	s.box(Vector3(x, 0, z), Vector3(x + 1, rail, z + 1), m, frame, skips | FirstPersonModels.Sink.NO_BOTTOM)
	s.box(Vector3(x, CEIL - rail, z), Vector3(x + 1, CEIL, z + 1), m, frame, skips)
	var along_x := _runs_x(grid, at)
	for e in [-1, 1]:
		var n := at + (Vector2i(e, 0) if along_x else Vector2i(0, e))
		if grid.in_bounds(n) and MCF.is_glass(grid.cell_fast(n.x, n.y).feature_id):
			continue
		if grid.in_bounds(n) and is_wall(grid.cell_fast(n.x, n.y), env):
			continue
		if along_x:
			var px := x if e < 0 else x + 1.0 - rail
			s.box(Vector3(px, rail, z), Vector3(px + rail, CEIL - rail, z + 1), m, frame, skips)
		else:
			var pz := z if e < 0 else z + 1.0 - rail
			s.box(Vector3(x, rail, pz), Vector3(x + 1, CEIL - rail, pz + rail), m, frame, skips)

## Sides of a block that touch a wall (hidden; drawing them would fight its face).
static func _wall_skips(grid: Grid, env: String, at: Vector2i) -> int:
	var k := 0
	var bits := {Vector2i(0, -1): FirstPersonModels.Sink.NO_BACK, Vector2i(0, 1): FirstPersonModels.Sink.NO_FRONT, Vector2i(-1, 0): FirstPersonModels.Sink.NO_LEFT, Vector2i(1, 0): FirstPersonModels.Sink.NO_RIGHT}
	for d: Vector2i in bits:
		var n := at + d
		if grid.in_bounds(n):
			var nc := grid.cell_fast(n.x, n.y)
			if is_wall(nc, env) or MCF.is_glass(nc.feature_id):
				k |= bits[d]
	return k

## A doorway: the lintel above 2.1 m in the surrounding wall's material; below it the door
## — two metal halves that slide apart into the walls (station, bunker, asteroid) or one
## wooden door that slides aside — thinner than the wall, so it never shares a face with it
## (it flickered). Welded airlocks carry their weld beads, welded wooden doors are boarded
## up (owner, fix-8). FirstPerson moves the leaves.
static func _door(node: Node3D, grid: Grid, at: Vector2i, env: String, mats: Dictionary,
		walls: Dictionary, roofed: bool) -> Node3D:
	var x := float(at.x)
	var z := float(at.y)
	var along_x := _runs_x(grid, at)
	var kind := "brick"
	var accent := Color(0, 0, 0, 0)
	for d: Vector2i in Grid.N4:
		var n := at + d
		if grid.in_bounds(n) and is_wall(grid.cell_fast(n.x, n.y), env):
			kind = FirstPersonArt.wall_kind(grid, n, env)
			accent = FirstPersonArt.accent_of(grid, n)
			break
	var ws := _wall_sink(walls, kind, Color(0, 0, 0, 0))
	for d: Vector2i in Grid.N4:
		var n := at + d
		if grid.in_bounds(n) and is_wall(grid.cell_fast(n.x, n.y), env):
			continue
		_wall_face(ws, at, d, LINTEL, CEIL)
	if not roofed:
		_quad_up(ws, Vector3(x, CEIL, z), Vector3(x + 1, CEIL, z + 1), Rect2(0, 0, 1, 0.04))
	_quad_down(ws, Vector3(x, LINTEL, z), Vector3(x + 1, LINTEL, z + 1), Rect2(0, 0.05, 1, 0.05))
	var wood := env in ["town", "field"]
	var door := Node3D.new()
	door.position = Vector3(x, 0, z)
	door.set_meta("cell", at)
	door.set_meta("along_x", along_x)
	var mat: Material = mats["door"].call("wood" if wood else "metal", accent, at)
	var leaves := 1 if wood else 2
	var w := 1.0 / leaves
	var thick := 0.09 if wood else 0.16
	for k in leaves:
		var leaf := MeshInstance3D.new()
		var s := _sink()
		var half := Vector3(w * 0.5, 0, thick * 0.5) if along_x else Vector3(thick * 0.5, 0, w * 0.5)
		_leaf_box(s, -half, half + Vector3(0, LINTEL - 0.005, 0), along_x, k == 1 and leaves == 2)
		leaf.mesh = s.mesh()
		leaf.material_override = mat
		var c := w * 0.5 + k * w
		leaf.position = Vector3(c, 0, 0.5) if along_x else Vector3(0.5, 0, c)
		leaf.set_meta("home", leaf.position)
		leaf.set_meta("side", -1 if k == 0 else 1)
		door.add_child(leaf)
	if grid.cell_fast(at.x, at.y).airlock_welded:
		var deco := FirstPersonModels.Sink.new()
		if wood:
			_boards(deco, along_x, thick)
		else:
			_welds(deco, along_x, thick)
		var mi := MeshInstance3D.new()
		mi.mesh = deco.mesh()
		mi.material_override = mats["models"]
		door.add_child(mi)
		door.set_meta("welded", true)
	node.add_child(door)
	return door

## A leaf as a box whose broad faces carry the door picture the right way round.
static func _leaf_box(s: FirstPersonModels.Sink, lo: Vector3, hi: Vector3, along_x: bool, mirror: bool) -> void:
	var u0 := 1.0 if mirror else 0.0
	var u1 := 0.0 if mirror else 1.0
	var faces := []
	if along_x:
		faces = [[Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3.BACK],
				[Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3.FORWARD]]
	else:
		faces = [[Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3.RIGHT],
				[Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z), Vector3.LEFT]]
	for f: Array in faces:
		s.face_uv([f[0], f[1], f[2], f[3]], f[4], [Vector2(u0, 1), Vector2(u1, 1), Vector2(u1, 0), Vector2(u0, 0)], Color.WHITE)
	# Edges in the leaf's frame colour.
	var edge := [Vector2(0.0, 0.0), Vector2(0.02, 0.0), Vector2(0.02, 0.02), Vector2(0.0, 0.02)]
	s.face_uv([Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)], Vector3.UP, edge, Color(0.6, 0.6, 0.6))
	if along_x:
		s.face_uv([Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z)], Vector3.LEFT, edge, Color(0.6, 0.6, 0.6))
		s.face_uv([Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z)], Vector3.RIGHT, edge, Color(0.6, 0.6, 0.6))
	else:
		s.face_uv([Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z)], Vector3.FORWARD, edge, Color(0.6, 0.6, 0.6))
		s.face_uv([Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)], Vector3.BACK, edge, Color(0.6, 0.6, 0.6))

## Planks nailed across a wooden door on both faces, in the door cell's frame.
static func _boards(s: FirstPersonModels.Sink, along_x: bool, thick: float) -> void:
	var plank := Color(0.5, 0.36, 0.22)
	for side: int in [-1, 1]:
		var off: float = (thick * 0.5 + 0.02) * side
		for spec: Array in [[0.55, 0.18], [1.2, -0.22], [1.75, 0.12]]:
			var basis := Basis(Vector3(0, 0, 1) if along_x else Vector3(1, 0, 0), float(spec[1]))
			var at := Vector3(0.5, float(spec[0]), 0.5 + off) if along_x else Vector3(0.5 + off, float(spec[0]), 0.5)
			var size := Vector3(1.15, 0.16, 0.035) if along_x else Vector3(0.035, 0.16, 1.15)
			s.rbox(at, size, basis, FirstPersonArt.M_WOOD, plank.darkened(0.1 * (spec[0] as float)))

## Weld beads down the seam between the halves and round the frame: lumpy grey-blue metal.
static func _welds(s: FirstPersonModels.Sink, along_x: bool, thick: float) -> void:
	var bead := Color(0.48, 0.5, 0.56)
	for side: int in [-1, 1]:
		var off: float = (thick * 0.5 + 0.012) * side
		var steps := 21
		for k in steps:
			var y := 0.05 + k * (LINTEL - 0.12) / (steps - 1)
			var j := 0.012 * sin(k * 2.3)
			var lo := Vector3(0.48 + j, y, 0.5 + off - 0.012) if along_x else Vector3(0.5 + off - 0.012, y, 0.48 + j)
			var hi := lo + (Vector3(0.04, 0.1, 0.024) if along_x else Vector3(0.024, 0.1, 0.04))
			s.box(lo, hi, FirstPersonArt.M_STEEL, bead.lightened(0.08 * (k % 3)))
		# Round the frame: across the top and down both jambs.
		for k in 10:
			var u := 0.05 + k * 0.09
			var lo2 := Vector3(u, LINTEL - 0.07, 0.5 + off - 0.012) if along_x else Vector3(0.5 + off - 0.012, LINTEL - 0.07, u)
			s.box(lo2, lo2 + (Vector3(0.09, 0.05, 0.024) if along_x else Vector3(0.024, 0.05, 0.09)), FirstPersonArt.M_STEEL, bead)
		for e in [0.02, 0.94]:
			for k in 9:
				var y2 := 0.1 + k * 0.22
				var lo3 := Vector3(e, y2, 0.5 + off - 0.012) if along_x else Vector3(0.5 + off - 0.012, y2, e)
				s.box(lo3, lo3 + (Vector3(0.04, 0.2, 0.024) if along_x else Vector3(0.024, 0.2, 0.04)), FirstPersonArt.M_STEEL, bead.darkened(0.05))

# --- Furniture, lamps and features ------------------------------------------------------------

## A piece of furniture: one model for a whole piece (bed, sofa, table), stood with the
## battle screen's own turn; a run (counter, shelf) one section a cell, joined to its
## neighbours. `tops` learns where small items lie on it.
static func _piece(models: SurfaceTool, glass: SurfaceTool, counts: Dictionary, grid: Grid, at: Vector2i, fid: String,
		ctx: Dictionary, cap: float, tops: Dictionary) -> void:
	var fid_at := func(q: Vector2i) -> String: return grid.cell_fast(q.x, q.y).feature_id if grid.in_bounds(q) else ""
	var cells: Array[Vector2i] = Furniture.piece_cells(fid_at, at)
	var whole := Furniture.is_whole(fid)
	# The 2D board freezes a piece's footprint before combat. A surviving foot of a bed
	# must stay its foot, and a missing table section must remain a hole in the model.
	var frozen: Variant = ctx.get("furniture_look")
	if whole and frozen is Dictionary and frozen.has(at) and frozen[at][0] == fid:
		cells = Furniture.piece_cells(func(q: Vector2i) -> String:
			var record: Array = frozen.get(q, [])
			return str(record[0]) if not record.is_empty() else "", at)
	var lo := cells[0]
	var hi := cells[0]
	for q: Vector2i in cells:
		lo = Vector2i(mini(lo.x, q.x), mini(lo.y, q.y))
		hi = Vector2i(maxi(hi.x, q.x), maxi(hi.y, q.y))
	var look: Array = ctx["look"].call(at, fid)
	var k := int(look[2]) % 4
	var mask := int(look[0])
	var d: Vector2 = [Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1), Vector2(1, 0)][k]   # back → front
	var a := Vector2(d.y, -d.x)                                                     # across
	var size := Vector2(hi - lo + Vector2i.ONE)
	var W := size.x if k % 2 == 0 else size.y
	var D := size.y if k % 2 == 0 else size.x
	# Back-left corner: the rectangle's corner least along both axes.
	var p0 := Vector2(lo)
	var best := INF
	for corner: Vector2 in [Vector2(lo), Vector2(hi.x + 1, lo.y), Vector2(lo.x, hi.y + 1), Vector2(hi + Vector2i.ONE)]:
		var score := corner.dot(a) * 1000.0 + corner.dot(d)
		if score < best:
			best = score
			p0 = corner
	var jl := not whole and (mask & Sprites.AUTOTILE_W) != 0
	var jr := not whole and (mask & Sprites.AUTOTILE_E) != 0
	var tint := Furniture.light_color_of(fid, grid.tint_at(at.x, at.y)) if Furniture.emits_light(fid) else Color(1, 1, 1)
	var lit := LightManager.source_on({"id": fid}, str(ctx.get("tod", "")))
	var seed := (lo.x * 73 + lo.y * 37) % 4
	var winter: bool = ctx.get("winter", false)
	var key := [fid, snappedf(W, 0.01), snappedf(D, 0.01), jl, jr, seed, tint.to_html(), lit, cap < 3.0, winter]
	var top := [-1.0]
	var make := func(s: FirstPersonModels.Sink, g: FirstPersonModels.Sink) -> void:
		top[0] = FirstPersonModels.furniture(s, g, fid, W, D, {"tint": Furniture.tint_of(fid), "art": FirstPersonArt.art_colour(fid),
				"seed": seed, "jl": jl, "jr": jr, "cap": cap, "light": tint, "lit": lit, "winter": winter})
	var tkey := str(key) + "|top"
	var built: Array = FirstPersonModels.cached(str(key), make)
	if not FirstPersonModels._cache.has(tkey):
		FirstPersonModels._cache[tkey] = top[0]
	# A whole piece is built once, at its first cell in reading order.
	var anchor := cells[0]
	for q: Vector2i in cells:
		if q.y < anchor.y or (q.y == anchor.y and q.x < anchor.x):
			anchor = q
	var sliced := whole and (cells.size() != int(size.x * size.y) \
			or cells.any(func(q: Vector2i) -> bool: return fid_at.call(q) != fid))
	if anchor == at or sliced:
		var xf := Transform3D(Basis(Vector3(a.x, 0, a.y), Vector3.UP, Vector3(d.x, 0, d.y)), Vector3(p0.x, 0, p0.y))
		var opaque: ArrayMesh = built[0]
		var transparent: ArrayMesh = built[1]
		if sliced:
			var local := xf.affine_inverse() * Vector3(at.x + 0.5, 0, at.y + 0.5)
			var bounds := Rect2(Vector2(local.x, local.z) - Vector2.ONE * 0.5, Vector2.ONE)
			opaque = FirstPersonModels.clipped(opaque, bounds)
			transparent = FirstPersonModels.clipped(transparent, bounds)
		if opaque != null:
			models.append_from(opaque, 0, xf)
			counts["models"] += 1
		if transparent != null:
			glass.append_from(transparent, 0, xf)
			counts["glass"] += 1
	var surface := float(FirstPersonModels._cache.get(tkey, -1.0))
	if surface > 0.0:
		tops[at] = surface

static func _wall_lamp(models: SurfaceTool, counts: Dictionary, grid: Grid, at: Vector2i, lamp: Array) -> void:
	var id := str(lamp[0])
	var side := int(lamp[2]) % 4
	var tint := int(lamp[3]) if lamp.size() > 3 else 0
	var col := Furniture.light_color_of(id, tint)
	var broken := int(lamp[1]) <= 0
	# The lamp hangs in the cell in front of the face, its back against the wall.
	var d: Vector2 = [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][side]
	var a := Vector2(d.y, -d.x)
	var face_mid := Vector2(at) + Vector2(0.5, 0.5) + d * 0.5
	var p0 := face_mid - a * 0.5
	var basis := Basis(Vector3(a.x, 0, a.y), Vector3.UP, Vector3(d.x, 0, d.y))
	_add_model(models, counts, ["lamp", id, col.to_html(), broken], Transform3D(basis, Vector3(p0.x, 0, p0.y)),
			func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void: FirstPersonModels.wall_lamp(s, id, col, broken))

## Fortifications and earthworks as models: bags, hedgehogs, heaps, the machine gun.
static func _feature(models: SurfaceTool, counts: Dictionary, grid: Grid, at: Vector2i, fid: String, env: String) -> void:
	var xf := Transform3D(Basis.IDENTITY, Vector3(at.x, 0, at.y))
	var seed := (at.x * 31 + at.y * 17) % 5
	match fid:
		MCF.FEATURE_SANDBAGS, MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS:
			var bags := [MCF.FEATURE_SANDBAGS, MCF.FEATURE_SANDBAG_WALL, MCF.FEATURE_HEDGEHOG_SANDBAGS, MCF.FEATURE_HEDGEHOG]
			var ax := false
			var az := false
			for e in [Vector2i(1, 0), Vector2i(-1, 0)]:
				var n: Vector2i = at + e
				ax = ax or (grid.in_bounds(n) and grid.cell_fast(n.x, n.y).feature_id in bags)
			for e in [Vector2i(0, 1), Vector2i(0, -1)]:
				var n2: Vector2i = at + e
				az = az or (grid.in_bounds(n2) and grid.cell_fast(n2.x, n2.y).feature_id in bags)
			var layers := 10 if fid == MCF.FEATURE_SANDBAG_WALL else 5
			_add_model(models, counts, ["bags", fid, ax, az, seed], xf, func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void:
				FirstPersonModels.sandbags(s, layers, ax, az, seed)
				if fid == MCF.FEATURE_HEDGEHOG_SANDBAGS:
					FirstPersonModels.hedgehog(s, seed, 0.95, 0.85))
		MCF.FEATURE_HEDGEHOG:
			_add_model(models, counts, ["hedgehog", seed], xf, func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void: FirstPersonModels.hedgehog(s, seed))
		MCF.FEATURE_DIRT_PILE:
			var rubble := TerrainTiles.pile_art(env) == "rubble"
			_add_model(models, counts, ["heap", rubble, seed], xf, func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void: FirstPersonModels.heap(s, rubble, seed))
		MCF.FEATURE_DPMG:
			var turn := TerrainTiles.dpmg_turn(grid, at)
			var rot := Transform3D(Basis(Vector3.UP, -turn * PI / 4.0), Vector3(at.x + 0.5, 0, at.y + 0.5)) \
					* Transform3D(Basis.IDENTITY, Vector3(-0.5, 0, -0.5))
			_add_model(models, counts, ["dpmg"], rot, func(s: FirstPersonModels.Sink, _g: FirstPersonModels.Sink) -> void: FirstPersonModels.dpmg(s))

# --- Small things ---------------------------------------------------------------------------

## The map's small items standing in this chunk (not the knocked ones: they are cosmetics
## now), on the table they stand on or on the floor.
static func _items(s: FirstPersonModels.Sink, grid: Grid, cc: Vector2i, tops: Dictionary) -> void:
	if grid.map_items.is_empty():
		return
	var area := Rect2i(cc * CH, Vector2i(CH, CH))
	for i in grid.map_items.size():
		var it: Array = grid.map_items[i]
		var cell := SmallItems.cell_of(it)
		if not area.has_point(cell) or not grid.in_bounds(cell):
			continue
		var gc := grid.cell_fast(cell.x, cell.y)
		if gc.items_off != 0 and (gc.items_off & grid.item_bit(i)) != 0:
			continue
		if gc.cover_height >= MCF.WALL_HEIGHT and not Furniture.is_furniture(gc.feature_id):
			continue
		var y := float(tops.get(cell, 0.0))
		_place_item(s, str(it[0]), Vector3(float(it[1]), y, float(it[2])), float(it[3]))

static func _place_item(s: FirstPersonModels.Sink, kind: String, at: Vector3, rot: float) -> void:
	var keep := s.xf
	s.xf = Transform3D(Basis(Vector3.UP, -rot), at)
	FirstPersonModels.item(s, kind, FirstPersonArt.art_colour(SmallItems.texture_name(kind)))
	s.xf = keep

## Knocked items and rubble from the battle's cosmetics: items as themselves, wall chunks
## as sharp lumps of their wall (owner, fix-8: flat chunk pictures looked like "strange
## shapes with barely connected parts").
static func _decals(s: FirstPersonModels.Sink, list: Array, area: Rect2) -> void:
	for d: Dictionary in list:
		var kind := str(d["kind"])
		var p: Vector2 = d["pos"]
		if not area.has_point(p):
			continue
		if kind in MapData.WINTER_DECORATIONS:
			var previous := s.xf
			var turn := Basis(Vector3.UP, float(d["rot"]))
			var scale := float(d.get("scale", 1.0))
			s.xf = Transform3D(turn.scaled(Vector3.ONE * scale), Vector3(p.x, 0, p.y)) \
					* Transform3D(Basis.IDENTITY, Vector3(-0.5, 0, -0.5))
			FirstPersonModels.furniture(s, FirstPersonModels.Sink.new(), kind, 1.0, 1.0, {})
			s.xf = previous
		elif kind.begins_with("item:"):
			_place_item(s, kind.substr(5), Vector3(p.x, 0.0, p.y), float(d["rot"]))
		elif kind.begins_with("chunk:"):
			var parts := FxDecals.chunk_parts(kind)
			var art: String = parts[0]
			var shape: Array = FxDecals.CHUNK_SHAPES[int(parts[1])]
			var r := FxDecals.CHUNK_SIZE * float(d["scale"]) * 0.5
			var poly := PackedVector2Array()
			for q: Vector2 in shape:
				poly.append(q.rotated(float(d["rot"])) * r + p)
			var hgt := r * (0.35 + 0.4 * FirstPersonArt._h(int(p.x * 97.0), int(p.y * 89.0), 7))
			var col := FirstPersonArt.art_colour(art).lerp(Color(0.5, 0.5, 0.5), 0.15)
			var m := FirstPersonArt.M_CONCRETE
			if Furniture.is_furniture(art):
				m = {"wood": FirstPersonArt.M_WOOD, "fabric": FirstPersonArt.M_FABRIC,
						"metal": FirstPersonArt.M_METAL, "plastic": FirstPersonArt.M_PLASTIC}.get(Furniture.def_of(art).get("mat", ""), m)
			elif "wood" in art: m = FirstPersonArt.M_WOOD
			elif "station" in art or "armor" in art or "metal" in art: m = FirstPersonArt.M_PLATE
			s.prism(poly, 0.0, hgt, m, col)
