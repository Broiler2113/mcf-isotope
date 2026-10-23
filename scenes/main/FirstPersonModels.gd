class_name FirstPersonModels
extends RefCounted

## Real models for the first-person view (owner, fix-8: furniture made of the board's
## top-down art on boxes looked "very AI and very cheap"). Every piece is built here from
## parts — legs, frames, cushions, drawers, bags, beams — at true size, each part wearing a
## material tile of FirstPersonArt at the one density (32 px a metre) and the colour of the
## board's own art, so variants keep their paint.
##
## A model is built once in its own frame and cached as a mesh: x runs across the piece
## (0..W), z from its back (0, against the wall) to its front (D), y up from the floor.
## FirstPersonBoard stands each piece in the world with the battle screen's own turn and
## merges a chunk's pieces into one mesh.
##
## Vertex colour alpha marks a glowing part (EMIT): lamp heads, screens, LEDs. They are not
## lit by the light map; they are the light.

const EMIT := 0.25

const WOOD := Color(0.62, 0.45, 0.28)
const WOOD_D := Color(0.38, 0.25, 0.15)
const METAL := Color(0.6, 0.62, 0.65)
const METAL_D := Color(0.24, 0.25, 0.27)
const WHITE := Color(0.9, 0.9, 0.88)
const CHROME := Color(0.86, 0.88, 0.9)
const BLACK := Color(0.07, 0.07, 0.08)
const CLOTH := Color(0.92, 0.91, 0.88)

# --- The mesh builder ---------------------------------------------------------------------

## Collects triangles in the model's frame. `xf` places the parts being added (a beam turned
## on its side, a leg leaning out); UVs follow the model's own metres on the face's main axis.
class Sink:
	var _v := PackedVector3Array()
	var _n := PackedVector3Array()
	var _uv := PackedVector2Array()
	var _uv2 := PackedVector2Array()
	var _col := PackedColorArray()
	var _native: RefCounted
	var v: PackedVector3Array:
		get: return _native.arrays()[Mesh.ARRAY_VERTEX] if _native != null else _v
	var n: PackedVector3Array:
		get: return _native.arrays()[Mesh.ARRAY_NORMAL] if _native != null else _n
	var uv: PackedVector2Array:
		get: return _native.arrays()[Mesh.ARRAY_TEX_UV] if _native != null else _uv
	var uv2: PackedVector2Array:
		get: return _native.arrays()[Mesh.ARRAY_TEX_UV2] if _native != null else _uv2
	var col: PackedColorArray:
		get: return _native.arrays()[Mesh.ARRAY_COLOR] if _native != null else _col
	var xf := Transform3D.IDENTITY
	var shade_floor := true   # parts darken toward the floor (contact shadow)

	func _init(use_native := true) -> void:
		_native = NativeVisuals.mesh_builder() if use_native else null

	func _fallback() -> void:
		# Preserve earlier geometry if a native call declines an unsupported input.
		var saved: Array = _native.arrays()
		_v = saved[Mesh.ARRAY_VERTEX]; _n = saved[Mesh.ARRAY_NORMAL]
		_uv = saved[Mesh.ARRAY_TEX_UV]; _uv2 = saved[Mesh.ARRAY_TEX_UV2]
		_col = saved[Mesh.ARRAY_COLOR]
		_native = null

	func append_raw(p: Vector3, nn: Vector3, u: Vector2, layer: Vector2, c: Color) -> void:
		if _native != null:
			_native.add_vertex(p, nn, u, layer, c, false)
			return
		_v.append(p); _n.append(nn); _uv.append(u); _uv2.append(layer); _col.append(c)

	func _vert(p: Vector3, nn: Vector3, u: Vector2, m: int, c: Color) -> void:
		if _native != null:
			_native.add_vertex(p, nn, u, Vector2(m, 0), c, shade_floor)
			return
		_v.append(p)
		_n.append(nn)
		_uv.append(u)
		_uv2.append(Vector2(m, 0))
		if shade_floor and c.a > 0.5:
			var k := 0.62 + 0.38 * smoothstep(0.0, 0.32, p.y)
			c = Color(c.r * k, c.g * k, c.b * k, c.a)
		_col.append(c)

	## A flat polygon (3 or 4 points, any order round its edge) facing out along `out`.
	func face(pts: Array, out: Vector3, m: int, c: Color) -> void:
		if _native != null:
			if _native.face(pts, out, m, c, xf, shade_floor): return
			_fallback()
		var w: Array[Vector3] = []
		for p: Vector3 in pts:
			w.append(xf * p)
		var nn := (xf.basis * out).normalized()
		var an := nn.abs()
		var u: Array[Vector2] = []
		for p: Vector3 in w:
			if an.y >= an.x and an.y >= an.z:
				u.append(Vector2(p.x, p.z))
			elif an.x >= an.z:
				u.append(Vector2(p.z, -p.y))
			else:
				u.append(Vector2(p.x, -p.y))
		for t in range(1, w.size() - 1):
			var a := w[0]
			var b := w[t]
			var cc := w[t + 1]
			# Godot's front faces wind clockwise as seen from outside.
			if (b - a).cross(cc - a).dot(nn) > 0.0:
				_vert(a, nn, u[0], m, c); _vert(cc, nn, u[t + 1], m, c); _vert(b, nn, u[t], m, c)
			else:
				_vert(a, nn, u[0], m, c); _vert(b, nn, u[t], m, c); _vert(cc, nn, u[t + 1], m, c)

	## A polygon with its own UVs (board tiles, wall pictures): no material layer.
	func face_uv(pts: Array, out: Vector3, uvs: Array, c: Color) -> void:
		if _native != null:
			if _native.face_uv(pts, out, uvs, c, xf, shade_floor): return
			_fallback()
		var nn := (xf.basis * out).normalized()
		var w: Array[Vector3] = []
		for p: Vector3 in pts:
			w.append(xf * p)
		for t in range(1, w.size() - 1):
			var a := w[0]
			var b := w[t]
			var cc := w[t + 1]
			if (b - a).cross(cc - a).dot(nn) > 0.0:
				_vert(a, nn, uvs[0], 0, c); _vert(cc, nn, uvs[t + 1], 0, c); _vert(b, nn, uvs[t], 0, c)
			else:
				_vert(a, nn, uvs[0], 0, c); _vert(b, nn, uvs[t], 0, c); _vert(cc, nn, uvs[t + 1], 0, c)

	## Faces to leave out of a box (hidden against something).
	const NO_BOTTOM := 1
	const NO_TOP := 2
	const NO_BACK := 4     # -z
	const NO_FRONT := 8    # +z
	const NO_LEFT := 16    # -x
	const NO_RIGHT := 32   # +x

	func box(lo: Vector3, hi: Vector3, m: int, c: Color, skip := 0) -> void:
		if _native != null:
			_native.box(lo, hi, m, c, skip, xf, shade_floor)
			return
		var x0 := lo.x
		var y0 := lo.y
		var z0 := lo.z
		var x1 := hi.x
		var y1 := hi.y
		var z1 := hi.z
		if skip & NO_TOP == 0:
			face([Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1)], Vector3.UP, m, c)
		if skip & NO_BOTTOM == 0:
			face([Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1)], Vector3.DOWN, m, c)
		if skip & NO_BACK == 0:
			face([Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0)], Vector3.FORWARD, m, c)
		if skip & NO_FRONT == 0:
			face([Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1)], Vector3.BACK, m, c)
		if skip & NO_LEFT == 0:
			face([Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0)], Vector3.LEFT, m, c)
		if skip & NO_RIGHT == 0:
			face([Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0)], Vector3.RIGHT, m, c)

	## A box of size `size` centred at `at`, turned by `basis` (beams, leaning legs, lids).
	func rbox(at: Vector3, size: Vector3, basis: Basis, m: int, c: Color) -> void:
		var keep := xf
		xf = xf * Transform3D(basis, at)
		box(-size * 0.5, size * 0.5, m, c)
		xf = keep

	## An upright prism with `sides` faces (a frustum when r0 != r1), from base up by h.
	## caps: 1 bottom, 2 top. sz squashes it along z (oval bowls).
	func cyl(base: Vector3, r0: float, r1: float, h: float, m: int, c: Color, sides := 10,
			caps := 3, sz := 1.0, top_col := Color(0, 0, 0, 0)) -> void:
		var ring0: Array[Vector3] = []
		var ring1: Array[Vector3] = []
		for i in sides:
			var a := TAU * (i + 0.5) / sides
			var d := Vector3(cos(a), 0, sin(a) * sz)
			ring0.append(base + d * r0)
			ring1.append(base + d * r1 + Vector3(0, h, 0))
		for i in sides:
			var j := (i + 1) % sides
			var mid := (ring0[i] + ring0[j] + ring1[i] + ring1[j]) * 0.25 - base
			face([ring0[i], ring0[j], ring1[j], ring1[i]], Vector3(mid.x, 0, mid.z).normalized(), m, c)
		if caps & 2:
			face(ring1, Vector3.UP, m, top_col if top_col.a > 0.0 else c)
		if caps & 1:
			face(ring0, Vector3.DOWN, m, c)

	## A prism lying along x (pipes, rollers, a fuel tank): its round end faces ±x.
	func xcyl(at: Vector3, r: float, length: float, m: int, c: Color, sides := 10, caps := 3) -> void:
		var keep := xf
		xf = xf * Transform3D(Basis(Vector3(0, 0, 1), -PI / 2), at)
		cyl(Vector3.ZERO, r, r, length, m, c, sides, caps)
		xf = keep

	## The same along z (a barrel's mouth facing you, a wheel seen side-on).
	func zcyl(at: Vector3, r: float, length: float, m: int, c: Color, sides := 10, caps := 3) -> void:
		var keep := xf
		xf = xf * Transform3D(Basis(Vector3(1, 0, 0), PI / 2), at)
		cyl(Vector3.ZERO, r, r, length, m, c, sides, caps)
		xf = keep

	## A rough lump: a faceted ellipsoid with a jittered surface (foliage, heaps, apples).
	func blob(at: Vector3, r: Vector3, m: int, c: Color, seed: int, sides := 7, bands := 4) -> void:
		var rings: Array = []
		for b in range(bands + 1):
			var phi := PI * b / bands
			var ring: Array[Vector3] = []
			for i in sides:
				var th := TAU * (i + (0.5 if b % 2 == 1 else 0.0)) / sides
				var j := 1.0 + 0.16 * (FirstPersonArt._h(i + seed * 7, b, seed) - 0.5) if b > 0 and b < bands else 1.0
				ring.append(at + Vector3(sin(phi) * cos(th) * r.x, cos(phi) * r.y, sin(phi) * sin(th) * r.z) * j)
			rings.append(ring)
		for b in bands:
			var ra: Array = rings[b]
			var rb: Array = rings[b + 1]
			for i in sides:
				var k := (i + 1) % sides
				var pts := [ra[i], ra[k], rb[k], rb[i]] if b > 0 and b < bands - 1 else \
						([ra[i], rb[k], rb[i]] if b == 0 else [ra[i], ra[k], rb[i]])
				var mid := Vector3.ZERO
				for p: Vector3 in pts:
					mid += p
				mid /= pts.size()
				# Each facet a shade of its own: leaves and earth read as clumps.
				var tone := 0.88 + 0.2 * FirstPersonArt._h(i, b, seed + 3)
				face(pts, (mid - at).normalized(), m, Color(c.r * tone, c.g * tone, c.b * tone, c.a))

	## A flat outline (x, z) extruded from y0 to y1 — rubble, a cut-out sign.
	func prism(poly: PackedVector2Array, y0: float, y1: float, m: int, c: Color) -> void:
		var top: Array = []
		var bot: Array = []
		for p: Vector2 in poly:
			top.append(Vector3(p.x, y1, p.y))
			bot.append(Vector3(p.x, y0, p.y))
		face(top, Vector3.UP, m, c)
		var cnt := poly.size()
		var area := 0.0
		for i in cnt:
			area += poly[i].cross(poly[(i + 1) % cnt])
		for i in cnt:
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % cnt]
			var e := b - a
			# Positive area in the x/z plane has its outside to the right of each edge.
			# Inward normals also inverted the winding, hiding the near face of rubble.
			var out := Vector3(e.y, 0, -e.x) if area > 0.0 else Vector3(-e.y, 0, e.x)
			face([bot[i], bot[(i + 1) % cnt], top[(i + 1) % cnt], top[i]], out.normalized(), m, c.darkened(0.12))

	func empty() -> bool:
		return _native.empty() if _native != null else _v.is_empty()

	func arrays() -> Array:
		if _native != null: return _native.arrays()
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = _v
		arr[Mesh.ARRAY_NORMAL] = _n
		arr[Mesh.ARRAY_TEX_UV] = _uv
		arr[Mesh.ARRAY_TEX_UV2] = _uv2
		arr[Mesh.ARRAY_COLOR] = _col
		return arr

	func mesh() -> ArrayMesh:
		var am := ArrayMesh.new()
		if not empty(): am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays())
		return am

# --- Cache ------------------------------------------------------------------------------

static var _cache := {}

## Clip an existing model to one surviving cell, keeping normals, UVs and materials.
## Only damaged/irregular whole pieces use this path; intact models retain their cache.
static func clipped(mesh: ArrayMesh, bounds: Rect2) -> ArrayMesh:
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var arr := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var layers: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
	var colors: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	var out := Sink.new()
	var planes := [Vector3(1, 0, bounds.position.x), Vector3(-1, 0, -bounds.end.x),
			Vector3(0, 1, bounds.position.y), Vector3(0, -1, -bounds.end.y)]
	for i in range(0, positions.size(), 3):
		var poly: Array = []
		for j in 3:
			poly.append([positions[i + j], normals[i + j], uvs[i + j], layers[i + j], colors[i + j]])
		for plane: Vector3 in planes:
			if poly.is_empty():
				break
			var next: Array = []
			var previous: Array = poly.back()
			var pd: float = previous[0].x * plane.x + previous[0].z * plane.y - plane.z
			for vertex: Array in poly:
				var vd: float = vertex[0].x * plane.x + vertex[0].z * plane.y - plane.z
				if (pd >= 0.0) != (vd >= 0.0):
					var t := pd / (pd - vd)
					var cut: Array = []
					for k in 5:
						cut.append(previous[k].lerp(vertex[k], t))
					next.append(cut)
				if vd >= 0.0:
					next.append(vertex)
				previous = vertex
				pd = vd
			poly = next
		for j in range(1, poly.size() - 1):
			for vertex: Array in [poly[0], poly[j], poly[j + 1]]:
				out.append_raw(vertex[0], vertex[1], vertex[2], vertex[3], vertex[4])
	return null if out.empty() else out.mesh()

## The model for `key`, built by `make.call(sink)` the first time. Returns [opaque, glass]
## meshes (either may be empty).
static func cached(key: String, make: Callable) -> Array:
	if _cache.has(key):
		return _cache[key]
	var s := Sink.new()
	var g := Sink.new()
	make.call(s, g)
	var out := [s.mesh() if not s.empty() else null, g.mesh() if not g.empty() else null]
	_cache[key] = out
	return out

static func glow(c: Color) -> Color:
	return Color(c.r, c.g, c.b, EMIT)

# --- Furniture --------------------------------------------------------------------------

## Build furniture `fid` W × D metres (its frame above). ctx: "tint" (Color, a = 0 none),
## "art" (Color), "seed", "jl"/"jr" (the run goes on past its left/right side), "cap"
## (ceiling clearance), "opened", "light" (lamp colour), "lit". Returns the height things
## lie on (its top), or -1 when nothing can lie on it.
static func furniture(s: Sink, g: Sink, fid: String, W: float, D: float, ctx: Dictionary) -> float:
	var base := Furniture.base_of(fid)
	var tint: Color = ctx.get("tint", Color(0, 0, 0, 0))
	var art: Color = ctx.get("art", Color(0.6, 0.6, 0.6))
	var paint := tint if tint.a > 0.0 else art
	var seed := int(ctx.get("seed", 0))
	var jl: bool = ctx.get("jl", false)
	var jr: bool = ctx.get("jr", false)
	var cap := float(ctx.get("cap", 9.0))
	var light: Color = ctx.get("light", Color(1.0, 0.85, 0.6))
	var lit: bool = ctx.get("lit", true)
	var lamp := glow(light.lightened(0.25)) if lit else Color(0.5, 0.5, 0.48)
	match base:
		"chair":
			var c := art.lerp(Color(0.6, 0.2, 0.15), 0.15)
			for p: Vector2 in [Vector2(0.28, 0.32), Vector2(0.69, 0.32), Vector2(0.28, 0.73), Vector2(0.69, 0.73)]:
				var top := 0.9 if p.y < 0.5 else 0.44
				s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.035, top, p.y + 0.035), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(0.26, 0.44, 0.3), Vector3(0.745, 0.48, 0.77), FirstPersonArt.M_FABRIC, c)
			s.box(Vector3(0.3, 0.6, 0.31), Vector3(0.7, 0.86, 0.35), FirstPersonArt.M_FABRIC, c)
			s.box(Vector3(0.3, 0.52, 0.315), Vector3(0.7, 0.55, 0.345), FirstPersonArt.M_WOOD, WOOD_D)
			return 0.48
		"armchair", "sofa":
			var w := W
			for p: Vector2 in [Vector2(0.1, 0.14), Vector2(w - 0.15, 0.14), Vector2(0.1, 0.84), Vector2(w - 0.15, 0.84)]:
				s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.05, 0.08, p.y + 0.05), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(0.06, 0.08, 0.1), Vector3(w - 0.06, 0.36, 0.92), FirstPersonArt.M_FABRIC, paint)
			s.box(Vector3(0.06, 0.36, 0.1), Vector3(0.22, 0.62, 0.92), FirstPersonArt.M_FABRIC, paint)
			s.box(Vector3(w - 0.22, 0.36, 0.1), Vector3(w - 0.06, 0.62, 0.92), FirstPersonArt.M_FABRIC, paint)
			var seats := maxi(1, roundi(w - 0.3))
			var sw := (w - 0.44) / seats
			for i in seats:
				var x0 := 0.22 + i * sw
				s.box(Vector3(x0 + 0.005, 0.36, 0.3), Vector3(x0 + sw - 0.005, 0.48, 0.9), FirstPersonArt.M_CUSHION, paint.lightened(0.06))
				s.box(Vector3(x0 + 0.005, 0.36, 0.1), Vector3(x0 + sw - 0.005, 0.86, 0.3), FirstPersonArt.M_CUSHION, paint.lightened(0.03))
			return 0.48
		"bed":
			var blanket := paint
			for p: Vector2 in [Vector2(0.02, 0.02), Vector2(W - 0.08, 0.02), Vector2(0.02, D - 0.08), Vector2(W - 0.08, D - 0.08)]:
				s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.06, 0.2, p.y + 0.06), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(0.02, 0.14, 0.06), Vector3(W - 0.02, 0.24, D - 0.02), FirstPersonArt.M_WOOD, WOOD)
			s.box(Vector3(0.05, 0.24, 0.07), Vector3(W - 0.05, 0.44, D - 0.04), FirstPersonArt.M_FABRIC, CLOTH)
			s.box(Vector3(0.03, 0.3, 0.62), Vector3(W - 0.03, 0.47, D - 0.03), FirstPersonArt.M_FABRIC, blanket)
			s.box(Vector3(0.025, 0.47, 0.62), Vector3(W - 0.025, 0.48, 0.74), FirstPersonArt.M_FABRIC, blanket.lightened(0.15))
			for i in maxi(1, roundi(W)):
				s.box(Vector3(i + 0.12, 0.44, 0.12), Vector3(i + 0.88 - (0.0 if W > 1.5 else 0.0), 0.56, 0.46), FirstPersonArt.M_CUSHION, CLOTH.lightened(0.04))
			s.box(Vector3(0.0, 0.0, 0.0), Vector3(W, 0.95, 0.06), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(-0.01, 0.95, -0.01), Vector3(W + 0.01, 0.99, 0.07), FirstPersonArt.M_WOOD, WOOD_D.darkened(0.15))
			s.box(Vector3(0.0, 0.0, D - 0.05), Vector3(W, 0.55, D), FirstPersonArt.M_WOOD, WOOD_D)
			return 0.47
		"bunk_bed":
			var hb := minf(1.75, cap)
			var blanket2 := tint if tint.a > 0.0 else Color(0.35, 0.42, 0.3)
			for p: Vector2 in [Vector2(0.02, 0.02), Vector2(W - 0.07, 0.02), Vector2(0.02, D - 0.07), Vector2(W - 0.07, D - 0.07)]:
				s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.05, hb, p.y + 0.05), FirstPersonArt.M_METAL, METAL_D)
			for y in [0.3, 1.25]:
				var yy: float = minf(y, hb - 0.3)
				s.box(Vector3(0.02, yy, 0.02), Vector3(W - 0.02, yy + 0.06, D - 0.02), FirstPersonArt.M_METAL, METAL_D)
				s.box(Vector3(0.06, yy + 0.06, 0.06), Vector3(W - 0.06, yy + 0.2, D - 0.06), FirstPersonArt.M_FABRIC, CLOTH)
				s.box(Vector3(0.05, yy + 0.12, 0.6), Vector3(W - 0.05, yy + 0.22, D - 0.05), FirstPersonArt.M_FABRIC, blanket2)
				s.box(Vector3(0.15, yy + 0.2, 0.1), Vector3(W - 0.15, yy + 0.28, 0.42), FirstPersonArt.M_CUSHION, CLOTH)
			# The upper bunk's guard rail and a ladder at its foot.
			s.box(Vector3(W - 0.05, 1.5, 0.3), Vector3(W - 0.02, 1.54, D - 0.6), FirstPersonArt.M_METAL, METAL_D)
			for k in 4:
				s.box(Vector3(W - 0.05, 0.4 + k * 0.28, D - 0.42), Vector3(W + 0.02, 0.43 + k * 0.28, D - 0.12), FirstPersonArt.M_METAL, METAL)
			return 0.5
		"nightstand":
			s.box(Vector3(0.14, 0.05, 0.16), Vector3(0.86, 0.53, 0.84), FirstPersonArt.M_WOOD, art)
			s.box(Vector3(0.18, 0.0, 0.2), Vector3(0.82, 0.05, 0.8), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(0.12, 0.53, 0.14), Vector3(0.88, 0.56, 0.86), FirstPersonArt.M_WOOD, art.darkened(0.1))
			s.box(Vector3(0.18, 0.3, 0.84), Vector3(0.82, 0.49, 0.86), FirstPersonArt.M_WOOD, art.lightened(0.08))
			s.box(Vector3(0.45, 0.38, 0.86), Vector3(0.55, 0.41, 0.89), FirstPersonArt.M_CHROME, CHROME)
			return 0.56
		"desk", "desk_lamp":
			_drawer_desk(s, W, D, art, FirstPersonArt.M_WOOD, WOOD_D)
			return 0.76
		"office_desk":
			s.box(Vector3(0.0, 0.72, 0.04), Vector3(W, 0.75, 0.96), FirstPersonArt.M_PLASTIC, art.lightened(0.1))
			for x in [0.05, W - 0.09]:
				s.box(Vector3(x, 0, 0.08), Vector3(x + 0.04, 0.72, 0.12), FirstPersonArt.M_METAL, METAL_D)
				s.box(Vector3(x, 0, 0.86), Vector3(x + 0.04, 0.72, 0.9), FirstPersonArt.M_METAL, METAL_D)
				s.box(Vector3(x, 0.02, 0.08), Vector3(x + 0.04, 0.06, 0.9), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(W - 0.55, 0.1, 0.2), Vector3(W - 0.12, 0.68, 0.85), FirstPersonArt.M_METAL, METAL)
			for k in 3:
				s.box(Vector3(W - 0.53, 0.14 + k * 0.18, 0.85), Vector3(W - 0.14, 0.3 + k * 0.18, 0.865), FirstPersonArt.M_METAL, METAL.lightened(0.05))
				s.box(Vector3(W - 0.4, 0.24 + k * 0.18, 0.865), Vector3(W - 0.27, 0.26 + k * 0.18, 0.885), FirstPersonArt.M_CHROME, CHROME)
			s.box(Vector3(0.1, 0.4, 0.06), Vector3(W - 0.1, 0.7, 0.08), FirstPersonArt.M_METAL, METAL_D)
			return 0.75
		"dining_table", "conference_table", "coffee_table", "plastic_table", "steel_table", "park_table":
			return _table(s, base, W, D, paint, art, seed)
		"workbench":
			var x0 := 0.0 if jl else 0.03
			var x1 := 1.0 if jr else 0.97
			s.box(Vector3(x0, 0.84, 0.05), Vector3(x1, 0.92, 0.95), FirstPersonArt.M_PLANKS, WOOD.lightened(0.05))
			for x: float in ([] if jl else [0.06]) + ([] if jr else [0.86]):
				s.box(Vector3(x, 0, 0.1), Vector3(x + 0.08, 0.84, 0.18), FirstPersonArt.M_PLANKS, WOOD_D)
				s.box(Vector3(x, 0, 0.82), Vector3(x + 0.08, 0.84, 0.9), FirstPersonArt.M_PLANKS, WOOD_D)
			s.box(Vector3(x0, 0.16, 0.12), Vector3(x1, 0.2, 0.88), FirstPersonArt.M_PLANKS, WOOD_D)
			if seed % 3 == 0:
				# A vice on the front edge.
				s.box(Vector3(0.3, 0.92, 0.82), Vector3(0.5, 1.0, 0.96), FirstPersonArt.M_METAL, Color(0.25, 0.35, 0.55))
				s.box(Vector3(0.38, 0.94, 0.96), Vector3(0.42, 0.97, 1.08), FirstPersonArt.M_CHROME, CHROME)
			return 0.92
		"exam_table":
			s.box(Vector3(0.2, 0, 0.25), Vector3(0.8, 0.6, D - 0.25), FirstPersonArt.M_METAL, METAL)
			s.box(Vector3(0.12, 0.6, 0.06), Vector3(0.88, 0.64, D - 0.06), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.14, 0.64, 0.08), Vector3(0.86, 0.76, D - 0.08), FirstPersonArt.M_CUSHION, Color(0.42, 0.62, 0.66))
			s.box(Vector3(0.14, 0.76, 0.08), Vector3(0.86, 0.84, 0.42), FirstPersonArt.M_CUSHION, Color(0.42, 0.62, 0.66))
			s.box(Vector3(0.2, 0.765, 0.45), Vector3(0.8, 0.77, D - 0.15), FirstPersonArt.M_PLAIN, WHITE.lightened(0.05))
			return 0.77
		"lab_bench":
			_run_cabinet(s, jl, jr, 0.86, 0.62, WHITE, FirstPersonArt.M_PLASTIC, 2)
			s.box(Vector3(0.0 if jl else 0.0, 0.86, 0.0), Vector3(1.0, 0.91, 0.68), FirstPersonArt.M_PLAIN, Color(0.12, 0.13, 0.14))
			if seed % 2 == 0:
				s.box(Vector3(0.1, 0.91, 0.04), Vector3(0.9, 1.25, 0.08), FirstPersonArt.M_METAL, METAL)
				s.box(Vector3(0.1, 1.22, 0.04), Vector3(0.9, 1.25, 0.24), FirstPersonArt.M_METAL, METAL)
			return 0.91
		"reception_desk":
			var x0b := 0.0 if jl else 0.03
			var x1b := 1.0 if jr else 0.97
			s.box(Vector3(x0b, 0, 0.74), Vector3(x1b, 1.02, 0.82), FirstPersonArt.M_WOOD, art)
			s.box(Vector3(x0b, 1.02, 0.6), Vector3(x1b, 1.06, 0.86), FirstPersonArt.M_WOOD, art.darkened(0.25))
			s.box(Vector3(x0b, 0.72, 0.08), Vector3(x1b, 0.76, 0.74), FirstPersonArt.M_WOOD, art.lightened(0.05))
			s.box(Vector3(x0b, 0.3, 0.83), Vector3(x1b, 0.36, 0.84), FirstPersonArt.M_PLAIN, Color(0.75, 0.6, 0.3))
			if not jl:
				s.box(Vector3(0.03, 0, 0.08), Vector3(0.06, 0.72, 0.74), FirstPersonArt.M_WOOD, art.darkened(0.15))
			if not jr:
				s.box(Vector3(0.94, 0, 0.08), Vector3(0.97, 0.72, 0.74), FirstPersonArt.M_WOOD, art.darkened(0.15))
			return 0.76
		"checkout_counter":
			_run_cabinet(s, jl, jr, 0.88, 0.85, art, FirstPersonArt.M_PLASTIC, 0)
			s.box(Vector3(0.0, 0.88, 0.04), Vector3(1.0, 0.92, 0.9), FirstPersonArt.M_METAL, METAL)
			s.box(Vector3(0.0, 0.92, 0.25), Vector3(1.0, 0.935, 0.65), FirstPersonArt.M_RUBBER, BLACK)
			if seed % 3 == 0:
				s.box(Vector3(0.6, 0.935, 0.68), Vector3(0.9, 1.03, 0.88), FirstPersonArt.M_PLASTIC, Color(0.2, 0.2, 0.22))
				s.rbox(Vector3(0.75, 1.12, 0.74), Vector3(0.24, 0.16, 0.02), Basis(Vector3.RIGHT, -0.3), FirstPersonArt.M_SCREEN, glow(Color(0.6, 0.9, 0.75)))
			return 0.93
		"kitchen_counter":
			_run_cabinet(s, jl, jr, 0.86, 0.6, art.lerp(WHITE, 0.4), FirstPersonArt.M_PLASTIC, 2)
			s.box(Vector3(0.0, 0.86, 0.0), Vector3(1.0, 0.91, 0.66), FirstPersonArt.M_PLAIN, Color(0.72, 0.7, 0.66))
			s.box(Vector3(0.0, 0.91, 0.0), Vector3(1.0, 1.15, 0.015), FirstPersonArt.M_TILE, WHITE)
			return 0.91
		"console":
			s.box(Vector3(0.0 if jl else 0.03, 0, 0.25), Vector3(1.0 if jr else 0.97, 0.72, 0.92), FirstPersonArt.M_PLATE, METAL_D)
			s.rbox(Vector3(0.5, 0.79, 0.62), Vector3(1.0 if jl or jr else 0.94, 0.06, 0.6), Basis(Vector3.RIGHT, 0.22), FirstPersonArt.M_PLATE, METAL_D.lightened(0.1))
			s.rbox(Vector3(0.5, 0.825, 0.6), Vector3(0.7, 0.01, 0.34), Basis(Vector3.RIGHT, 0.22), FirstPersonArt.M_SCREEN, glow(Color(0.5, 1.0, 0.75)))
			for k in 5:
				var bc: Color = [Color(1, 0.3, 0.2), Color(0.3, 1, 0.4), Color(1, 0.8, 0.2), Color(0.3, 0.6, 1), Color(1, 0.3, 0.2)][(k + seed) % 5]
				s.rbox(Vector3(0.18 + k * 0.16, 0.775, 0.84), Vector3(0.06, 0.02, 0.04), Basis(Vector3.RIGHT, 0.22), FirstPersonArt.M_PLAIN, glow(bc))
			s.box(Vector3(0.1, 0.72, 0.18), Vector3(0.9, 1.08, 0.25), FirstPersonArt.M_PLATE, METAL_D)
			s.box(Vector3(0.14, 0.76, 0.25), Vector3(0.86, 1.04, 0.255), FirstPersonArt.M_SCREEN, glow(Color(0.45, 0.85, 1.0)))
			return -1.0
		"wardrobe", "dresser", "cabinet", "tool_cabinet", "filing_cabinet", "locker", "industrial_cabinet", "biohazard_cabinet", "morgue_drawers", "refrigerator", "specimen_fridge":
			return _cabinet(s, base, W, D, paint, art, jl, jr, cap, seed)
		"bookshelf", "display_shelf", "storage_shelf":
			_shelf(s, base, fid, jl, jr, cap, seed, art)
			return -1.0
		"server_rack":
			var hr := minf(2.0, cap)
			s.box(Vector3(0.0 if jl else 0.04, 0, 0.1), Vector3(1.0 if jr else 0.96, hr, 0.9), FirstPersonArt.M_PLATE, Color(0.1, 0.1, 0.11))
			s.box(Vector3(0.08, 0.06, 0.9), Vector3(0.92, hr - 0.06, 0.91), FirstPersonArt.M_MESH, Color(0.3, 0.31, 0.33))
			for k in 14:
				var ly := 0.15 + k * (hr - 0.3) / 14.0
				var on := FirstPersonArt._h(k, seed, 5) > 0.35
				s.box(Vector3(0.12, ly, 0.912), Vector3(0.15, ly + 0.02, 0.92), FirstPersonArt.M_PLAIN,
						glow(Color(0.3, 1.0, 0.45) if on else Color(0.3, 0.6, 1.0)))
				s.box(Vector3(0.18, ly, 0.912), Vector3(0.21, ly + 0.02, 0.92), FirstPersonArt.M_PLAIN, glow(Color(0.3, 0.7, 1.0)))
			return -1.0
		"vending_machine":
			var hv := minf(1.95, cap)
			var body := paint
			s.box(Vector3(0.05, 0, 0.12), Vector3(0.95, hv, 0.92), FirstPersonArt.M_PLATE, body)
			s.box(Vector3(0.1, 0.55, 0.92), Vector3(0.66, hv - 0.2, 0.93), FirstPersonArt.M_GOODS, glow(Color(0.85, 0.88, 0.9)))
			s.box(Vector3(0.68, 0.5, 0.92), Vector3(0.9, hv - 0.2, 0.935), FirstPersonArt.M_PLATE, body.darkened(0.3))
			for k in 9:
				s.box(Vector3(0.72 + (k % 3) * 0.055, 1.1 + (k / 3) * 0.06, 0.935), Vector3(0.76 + (k % 3) * 0.055, 1.14 + (k / 3) * 0.06, 0.945), FirstPersonArt.M_PLAIN, CHROME)
			s.box(Vector3(0.74, 0.85, 0.935), Vector3(0.84, 0.95, 0.94), FirstPersonArt.M_SCREEN, glow(Color(0.4, 1.0, 0.6)))
			s.box(Vector3(0.12, 0.14, 0.92), Vector3(0.64, 0.36, 0.925), FirstPersonArt.M_PLAIN, BLACK)
			s.box(Vector3(0.05, hv - 0.18, 0.92), Vector3(0.95, hv - 0.03, 0.94), FirstPersonArt.M_PLAIN, glow(body.lightened(0.45)))
			return -1.0
		"crate":
			s.box(Vector3(0.17, 0.0, 0.17), Vector3(0.83, 0.64, 0.83), FirstPersonArt.M_PLANKS, art)
			for e in [[Vector3(0.15, 0, 0.15), Vector3(0.21, 0.66, 0.21)], [Vector3(0.79, 0, 0.15), Vector3(0.85, 0.66, 0.21)],
					[Vector3(0.15, 0, 0.79), Vector3(0.21, 0.66, 0.85)], [Vector3(0.79, 0, 0.79), Vector3(0.85, 0.66, 0.85)],
					[Vector3(0.15, 0.6, 0.15), Vector3(0.85, 0.66, 0.21)], [Vector3(0.15, 0.6, 0.79), Vector3(0.85, 0.66, 0.85)],
					[Vector3(0.15, 0.6, 0.21), Vector3(0.21, 0.66, 0.79)], [Vector3(0.79, 0.6, 0.21), Vector3(0.85, 0.66, 0.79)]]:
				s.box(e[0], e[1], FirstPersonArt.M_PLANKS, art.darkened(0.22))
			return 0.66
		"pallet":
			for z in [0.08, 0.46, 0.84]:
				s.box(Vector3(0.05, 0, z), Vector3(0.95, 0.1, z + 0.08), FirstPersonArt.M_PLANKS, WOOD_D)
			for k in 6:
				s.box(Vector3(0.05, 0.1, 0.06 + k * 0.155), Vector3(0.95, 0.14, 0.17 + k * 0.155), FirstPersonArt.M_PLANKS, WOOD)
			return 0.14
		"ammo_crate":
			var olive := Color(0.33, 0.38, 0.24)
			s.box(Vector3(0.2, 0, 0.28), Vector3(0.8, 0.42, 0.72), FirstPersonArt.M_PLATE, olive)
			s.box(Vector3(0.18, 0.42, 0.26), Vector3(0.82, 0.48, 0.74), FirstPersonArt.M_PLATE, olive.darkened(0.15))
			s.box(Vector3(0.22, 0.2, 0.72), Vector3(0.78, 0.26, 0.725), FirstPersonArt.M_PLAIN, Color(0.85, 0.75, 0.2))
			for x in [0.12, 0.82]:
				s.box(Vector3(x, 0.3, 0.45), Vector3(x + 0.06, 0.33, 0.55), FirstPersonArt.M_METAL, METAL_D)
			return 0.48
		"barrel":
			var bc2 := paint
			s.cyl(Vector3(0.5, 0, 0.5), 0.27, 0.27, 0.88, FirstPersonArt.M_METAL, bc2, 14, 3, 1.0, bc2.darkened(0.2))
			for y in [0.25, 0.6]:
				s.cyl(Vector3(0.5, y, 0.5), 0.285, 0.285, 0.035, FirstPersonArt.M_METAL, bc2.darkened(0.15), 14, 3)
			s.cyl(Vector3(0.36, 0.88, 0.5), 0.035, 0.035, 0.025, FirstPersonArt.M_METAL, METAL_D, 6)
			return 0.88
		"gas_canister":
			s.cyl(Vector3(0.5, 0, 0.5), 0.13, 0.13, 0.95, FirstPersonArt.M_METAL, paint, 12, 1)
			s.cyl(Vector3(0.5, 0.95, 0.5), 0.13, 0.05, 0.12, FirstPersonArt.M_METAL, paint, 12, 2)
			s.cyl(Vector3(0.5, 1.07, 0.5), 0.025, 0.025, 0.08, FirstPersonArt.M_CHROME, CHROME, 6)
			s.box(Vector3(0.47, 1.12, 0.46), Vector3(0.53, 1.15, 0.58), FirstPersonArt.M_PLAIN, Color(0.15, 0.15, 0.15))
			return -1.0
		"water_bucket":
			s.cyl(Vector3(0.5, 0, 0.5), 0.13, 0.16, 0.3, FirstPersonArt.M_PLASTIC, paint, 12, 1, 1.0)
			s.cyl(Vector3(0.5, 0.25, 0.5), 0.15, 0.15, 0.01, FirstPersonArt.M_PLAIN, Color(0.35, 0.5, 0.65), 12, 2)
			s.rbox(Vector3(0.5, 0.36, 0.5), Vector3(0.3, 0.012, 0.012), Basis.IDENTITY, FirstPersonArt.M_METAL, METAL_D)
			return -1.0
		"fuel_tank":
			var r := minf(0.75, (minf(W, D) - 0.2) * 0.5)
			var tank := paint.lerp(WHITE, 0.15)
			for x in [0.4, W - 0.55]:
				s.box(Vector3(x, 0, D * 0.5 - r * 0.8), Vector3(x + 0.15, r * 0.6, D * 0.5 + r * 0.8), FirstPersonArt.M_CONCRETE, Color(0.6, 0.6, 0.58))
			s.xcyl(Vector3(0.12, r + 0.12, D * 0.5), r, W - 0.24, FirstPersonArt.M_METAL, tank, 14)
			s.cyl(Vector3(W * 0.5, r * 2.0 + 0.1, D * 0.5), 0.12, 0.12, 0.12, FirstPersonArt.M_METAL, METAL_D, 8)
			for k in 3:
				s.xcyl(Vector3(0.1, r + 0.12, D * 0.5), r + 0.015, 0.04, FirstPersonArt.M_METAL, tank.darkened(0.2), 14)
				s.xcyl(Vector3(W - 0.14, r + 0.12, D * 0.5), r + 0.015, 0.04, FirstPersonArt.M_METAL, tank.darkened(0.2), 14)
			return -1.0
		"generator":
			s.box(Vector3(0.05, 0, 0.1), Vector3(W - 0.05, 0.12, 0.9), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.15, 0.12, 0.18), Vector3(W - 0.15, 1.15, 0.82), FirstPersonArt.M_PLATE, paint)
			s.box(Vector3(0.12, 0.15, 0.2), Vector3(0.15, 1.1, 0.8), FirstPersonArt.M_GRILLE, METAL_D.lightened(0.2))
			s.box(Vector3(W - 0.6, 0.6, 0.82), Vector3(W - 0.25, 1.0, 0.86), FirstPersonArt.M_PLATE, METAL_D)
			s.box(Vector3(W - 0.55, 0.85, 0.86), Vector3(W - 0.5, 0.9, 0.87), FirstPersonArt.M_PLAIN, glow(Color(0.4, 1.0, 0.5)))
			s.box(Vector3(W - 0.45, 0.85, 0.86), Vector3(W - 0.4, 0.9, 0.87), FirstPersonArt.M_PLAIN, glow(Color(1.0, 0.7, 0.2)))
			s.box(Vector3(W - 0.55, 0.66, 0.86), Vector3(W - 0.3, 0.76, 0.865), FirstPersonArt.M_SCREEN, glow(Color(0.5, 0.85, 1.0)))
			s.cyl(Vector3(0.45, 1.15, 0.35), 0.06, 0.06, 0.4, FirstPersonArt.M_METAL, METAL_D, 8)
			s.box(Vector3(0.3, 0.12, 0.83), Vector3(W - 0.7, 0.18, 0.86), FirstPersonArt.M_PLAIN, Color(0.85, 0.7, 0.1))
			return -1.0
		"machinery", "machine_workstation":
			return _machine(s, base, W, D, paint, seed, cap)
		"equipment_cart":
			for p: Vector2 in [Vector2(0.2, 0.25), Vector2(0.77, 0.25), Vector2(0.2, 0.72), Vector2(0.77, 0.72)]:
				s.box(Vector3(p.x, 0.08, p.y), Vector3(p.x + 0.03, 0.9, p.y + 0.03), FirstPersonArt.M_METAL, METAL)
				s.cyl(Vector3(p.x + 0.015, 0, p.y + 0.015), 0.04, 0.04, 0.08, FirstPersonArt.M_RUBBER, BLACK, 8)
			for y in [0.18, 0.5, 0.86]:
				s.box(Vector3(0.18, y, 0.23), Vector3(0.82, y + 0.03, 0.77), FirstPersonArt.M_METAL, METAL.lightened(0.05))
			s.box(Vector3(0.2, 0.9, 0.2), Vector3(0.8, 0.93, 0.23), FirstPersonArt.M_METAL, METAL_D)
			return 0.89
		"vent_fan":
			s.box(Vector3(0.1, 0, 0.35), Vector3(0.9, 0.08, 0.65), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.12, 0.08, 0.42), Vector3(0.88, 0.84, 0.58), FirstPersonArt.M_PLATE, METAL)
			s.zcyl(Vector3(0.5, 0.46, 0.585), 0.33, 0.02, FirstPersonArt.M_MESH, Color(0.2, 0.2, 0.22), 14)
			s.zcyl(Vector3(0.5, 0.46, 0.6), 0.06, 0.03, FirstPersonArt.M_METAL, METAL_D, 8)
			for k in 4:
				s.rbox(Vector3(0.5, 0.46, 0.57), Vector3(0.6, 0.08, 0.01), Basis(Vector3.BACK, k * PI / 4 + 0.3), FirstPersonArt.M_METAL, METAL_D)
			return -1.0
		"washing_machine":
			s.box(Vector3(0.18, 0, 0.15), Vector3(0.82, 0.86, 0.8), FirstPersonArt.M_PLASTIC, WHITE)
			s.zcyl(Vector3(0.5, 0.42, 0.8), 0.2, 0.02, FirstPersonArt.M_CHROME, CHROME, 14)
			s.zcyl(Vector3(0.5, 0.42, 0.81), 0.16, 0.015, FirstPersonArt.M_PLAIN, Color(0.15, 0.2, 0.28), 14)
			s.box(Vector3(0.2, 0.74, 0.8), Vector3(0.8, 0.84, 0.81), FirstPersonArt.M_PLASTIC, WHITE.darkened(0.08))
			s.zcyl(Vector3(0.68, 0.79, 0.81), 0.03, 0.02, FirstPersonArt.M_PLASTIC, METAL_D, 8)
			return 0.86
		"stove":
			s.box(Vector3(0.12, 0, 0.12), Vector3(0.88, 0.88, 0.8), FirstPersonArt.M_METAL, art.lerp(WHITE, 0.3))
			s.box(Vector3(0.12, 0.88, 0.12), Vector3(0.88, 0.9, 0.8), FirstPersonArt.M_PLAIN, Color(0.12, 0.12, 0.13))
			for p: Vector2 in [Vector2(0.32, 0.3), Vector2(0.68, 0.3), Vector2(0.32, 0.62), Vector2(0.68, 0.62)]:
				s.cyl(Vector3(p.x, 0.9, p.y), 0.1, 0.1, 0.012, FirstPersonArt.M_PLAIN, Color(0.2, 0.2, 0.2), 10)
				s.cyl(Vector3(p.x, 0.912, p.y), 0.05, 0.05, 0.008, FirstPersonArt.M_PLAIN, Color(0.08, 0.08, 0.08), 8)
			s.box(Vector3(0.18, 0.12, 0.8), Vector3(0.82, 0.62, 0.81), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.28, 0.28, 0.81), Vector3(0.72, 0.52, 0.812), FirstPersonArt.M_PLAIN, Color(0.08, 0.06, 0.05))
			s.box(Vector3(0.22, 0.66, 0.82), Vector3(0.78, 0.68, 0.86), FirstPersonArt.M_CHROME, CHROME)
			for k in 4:
				s.zcyl(Vector3(0.24 + k * 0.17, 0.78, 0.8), 0.025, 0.03, FirstPersonArt.M_PLAIN, BLACK, 8)
			return 0.9
		"sink":
			s.box(Vector3(0.14, 0.06, 0.1), Vector3(0.86, 0.8, 0.58), FirstPersonArt.M_PLASTIC, art.lerp(WHITE, 0.6))
			s.box(Vector3(0.16, 0.0, 0.12), Vector3(0.84, 0.06, 0.54), FirstPersonArt.M_PLAIN, METAL_D)
			for x in [0.16, 0.51]:
				s.box(Vector3(x, 0.1, 0.58), Vector3(x + 0.33, 0.76, 0.59), FirstPersonArt.M_PLASTIC, art.lerp(WHITE, 0.7))
				s.box(Vector3(x + (0.27 if x < 0.3 else 0.04), 0.5, 0.59), Vector3(x + (0.29 if x < 0.3 else 0.06), 0.68, 0.61), FirstPersonArt.M_CHROME, CHROME)
			# The basin sunk into the counter: rim on four sides round a bowl.
			s.box(Vector3(0.1, 0.8, 0.06), Vector3(0.9, 0.86, 0.17), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.1, 0.8, 0.5), Vector3(0.9, 0.86, 0.64), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.1, 0.8, 0.17), Vector3(0.24, 0.86, 0.5), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.76, 0.8, 0.17), Vector3(0.9, 0.86, 0.5), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.24, 0.72, 0.17), Vector3(0.76, 0.8, 0.5), FirstPersonArt.M_CERAMIC, Color(0.82, 0.84, 0.86), Sink.NO_BOTTOM)
			s.cyl(Vector3(0.5, 0.721, 0.34), 0.025, 0.025, 0.003, FirstPersonArt.M_PLAIN, METAL_D, 8)
			s.cyl(Vector3(0.5, 0.86, 0.1), 0.022, 0.022, 0.2, FirstPersonArt.M_CHROME, CHROME, 8)
			s.box(Vector3(0.485, 1.02, 0.1), Vector3(0.515, 1.05, 0.26), FirstPersonArt.M_CHROME, CHROME)
			s.box(Vector3(0.42, 0.97, 0.08), Vector3(0.58, 0.99, 0.12), FirstPersonArt.M_CHROME, CHROME)
			return -1.0
		"toilet":
			s.cyl(Vector3(0.5, 0, 0.5), 0.13, 0.11, 0.3, FirstPersonArt.M_CERAMIC, WHITE, 12, 1, 1.25)
			s.cyl(Vector3(0.5, 0.3, 0.5), 0.13, 0.2, 0.1, FirstPersonArt.M_CERAMIC, WHITE, 14, 0, 1.25)
			s.cyl(Vector3(0.5, 0.4, 0.5), 0.2, 0.2, 0.025, FirstPersonArt.M_PLASTIC, WHITE.lightened(0.05), 14, 3, 1.25,
					WHITE.darkened(0.04))
			s.cyl(Vector3(0.5, 0.401, 0.52), 0.12, 0.12, 0.026, FirstPersonArt.M_PLAIN, Color(0.45, 0.6, 0.65), 12, 2, 1.25)
			s.rbox(Vector3(0.5, 0.6, 0.27), Vector3(0.38, 0.4, 0.025), Basis(Vector3.RIGHT, -0.12), FirstPersonArt.M_PLASTIC, WHITE.lightened(0.04))
			s.box(Vector3(0.27, 0.38, 0.03), Vector3(0.73, 0.78, 0.22), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.25, 0.78, 0.01), Vector3(0.75, 0.81, 0.24), FirstPersonArt.M_CERAMIC, WHITE.lightened(0.04))
			s.cyl(Vector3(0.5, 0.81, 0.12), 0.03, 0.03, 0.01, FirstPersonArt.M_CHROME, CHROME, 8)
			return -1.0
		"shower":
			s.box(Vector3(0.0, 0, 0.0), Vector3(1.0, 0.07, 1.0), FirstPersonArt.M_CERAMIC, WHITE)
			s.cyl(Vector3(0.5, 0.071, 0.5), 0.04, 0.04, 0.002, FirstPersonArt.M_PLAIN, METAL_D, 8)
			var top := minf(2.1, cap)
			s.box(Vector3(0.47, 0.07, 0.0), Vector3(0.53, top - 0.1, 0.04), FirstPersonArt.M_CHROME, CHROME)
			s.box(Vector3(0.47, top - 0.16, 0.0), Vector3(0.53, top - 0.1, 0.3), FirstPersonArt.M_CHROME, CHROME)
			s.cyl(Vector3(0.5, top - 0.2, 0.32), 0.09, 0.07, 0.05, FirstPersonArt.M_CHROME, CHROME, 10)
			g.box(Vector3(0.0, 0.07, 0.97), Vector3(0.62, top - 0.05, 0.99), 0, Color(0.7, 0.85, 0.95))
			g.box(Vector3(0.97, 0.07, 0.0), Vector3(0.99, top - 0.05, 1.0), 0, Color(0.7, 0.85, 0.95))
			s.box(Vector3(0.0, top - 0.05, 0.96), Vector3(1.0, top - 0.02, 1.0), FirstPersonArt.M_CHROME, CHROME)
			s.box(Vector3(0.96, top - 0.05, 0.0), Vector3(1.0, top - 0.02, 0.96), FirstPersonArt.M_CHROME, CHROME)
			return -1.0
		"bathtub":
			s.box(Vector3(0.04, 0, 0.04), Vector3(W - 0.04, 0.52, 0.12), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.04, 0, D - 0.12), Vector3(W - 0.04, 0.52, D - 0.04), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.04, 0, 0.12), Vector3(0.12, 0.52, D - 0.12), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(W - 0.12, 0, 0.12), Vector3(W - 0.04, 0.52, D - 0.12), FirstPersonArt.M_CERAMIC, WHITE)
			s.box(Vector3(0.12, 0, 0.12), Vector3(W - 0.12, 0.12, D - 0.12), FirstPersonArt.M_CERAMIC, Color(0.84, 0.86, 0.88), Sink.NO_BOTTOM)
			s.box(Vector3(W * 0.5 - 0.02, 0.52, 0.06), Vector3(W * 0.5 + 0.02, 0.66, 0.1), FirstPersonArt.M_CHROME, CHROME)
			s.box(Vector3(W * 0.5 - 0.015, 0.63, 0.1), Vector3(W * 0.5 + 0.015, 0.66, 0.2), FirstPersonArt.M_CHROME, CHROME)
			return -1.0
		"water_cooler":
			s.box(Vector3(0.28, 0, 0.28), Vector3(0.72, 0.95, 0.72), FirstPersonArt.M_PLASTIC, art.lerp(WHITE, 0.5))
			s.box(Vector3(0.32, 0.6, 0.72), Vector3(0.68, 0.64, 0.8), FirstPersonArt.M_PLASTIC, METAL_D)
			s.box(Vector3(0.38, 0.78, 0.72), Vector3(0.44, 0.84, 0.76), FirstPersonArt.M_PLASTIC, Color(0.85, 0.2, 0.15))
			s.box(Vector3(0.56, 0.78, 0.72), Vector3(0.62, 0.84, 0.76), FirstPersonArt.M_PLASTIC, Color(0.2, 0.4, 0.9))
			s.cyl(Vector3(0.5, 0.95, 0.5), 0.15, 0.15, 0.36, FirstPersonArt.M_PLASTIC, Color(0.45, 0.66, 0.9), 12, 0)
			s.cyl(Vector3(0.5, 1.31, 0.5), 0.15, 0.07, 0.06, FirstPersonArt.M_PLASTIC, Color(0.45, 0.66, 0.9), 12, 2)
			return -1.0
		"tv_stand":
			s.box(Vector3(0.08, 0.04, 0.15), Vector3(0.92, 0.48, 0.55), FirstPersonArt.M_WOOD, art)
			s.box(Vector3(0.1, 0.0, 0.17), Vector3(0.9, 0.04, 0.53), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(0.45, 0.48, 0.28), Vector3(0.55, 0.56, 0.36), FirstPersonArt.M_PLASTIC, BLACK)
			s.box(Vector3(0.15, 0.56, 0.29), Vector3(0.85, 0.98, 0.33), FirstPersonArt.M_PLASTIC, BLACK)
			s.box(Vector3(0.17, 0.58, 0.33), Vector3(0.83, 0.96, 0.332), FirstPersonArt.M_PLAIN, glow(Color(0.42, 0.55, 0.85)))
			s.box(Vector3(0.22, 0.6, 0.332), Vector3(0.5, 0.75, 0.334), FirstPersonArt.M_PLAIN, glow(Color(0.35, 0.6, 0.4)))
			s.box(Vector3(0.55, 0.82, 0.332), Vector3(0.7, 0.92, 0.334), FirstPersonArt.M_PLAIN, glow(Color(0.95, 0.9, 0.7)))
			return -1.0
		"piano":
			var pc := art.darkened(0.2) if tint.a == 0.0 else tint
			s.box(Vector3(0.0, 0.0, 0.05), Vector3(W, 1.25, 0.5), FirstPersonArt.M_WOOD, pc)
			s.box(Vector3(-0.02, 1.25, 0.03), Vector3(W + 0.02, 1.29, 0.52), FirstPersonArt.M_WOOD, pc.darkened(0.2))
			s.box(Vector3(0.05, 0.68, 0.5), Vector3(W - 0.05, 0.72, 0.78), FirstPersonArt.M_WOOD, pc)
			s.box(Vector3(0.18, 0.72, 0.52), Vector3(W - 0.18, 0.74, 0.74), FirstPersonArt.M_PLAIN, Color(0.95, 0.94, 0.9))
			var keys := int((W - 0.36) / 0.045)
			for k in keys:
				if k % 7 in [0, 1, 3, 4, 5]:
					s.box(Vector3(0.2 + k * 0.045, 0.74, 0.52), Vector3(0.225 + k * 0.045, 0.755, 0.64), FirstPersonArt.M_PLAIN, BLACK)
			s.rbox(Vector3(W * 0.5, 0.98, 0.52), Vector3(0.7, 0.28, 0.02), Basis(Vector3.RIGHT, -0.25), FirstPersonArt.M_WOOD, pc.darkened(0.1))
			for x in [0.08, W - 0.14]:
				s.box(Vector3(x, 0.0, 0.7), Vector3(x + 0.06, 0.68, 0.76), FirstPersonArt.M_WOOD, pc)
			return 1.29
		"potted_plant":
			_plant(s, fid, seed, art)
			return -1.0
		"trash_bin":
			s.cyl(Vector3(0.5, 0, 0.5), 0.17, 0.2, 0.58, FirstPersonArt.M_PLASTIC, paint, 12, 1)
			s.cyl(Vector3(0.5, 0.58, 0.5), 0.215, 0.215, 0.04, FirstPersonArt.M_PLASTIC, paint.darkened(0.25), 12)
			s.cyl(Vector3(0.5, 0.62, 0.5), 0.03, 0.03, 0.03, FirstPersonArt.M_PLASTIC, paint.darkened(0.3), 6)
			return -1.0
		"dumpster":
			var dc := paint
			s.box(Vector3(0.06, 0.14, 0.1), Vector3(W - 0.06, 1.15, 0.92), FirstPersonArt.M_PLATE, dc)
			for k in int(W * 3):
				var x := 0.2 + k * (W - 0.4) / maxf(1.0, W * 3 - 1)
				s.box(Vector3(x - 0.03, 0.2, 0.92), Vector3(x + 0.03, 1.1, 0.95), FirstPersonArt.M_METAL, dc.darkened(0.12))
			s.rbox(Vector3(W * 0.25, 1.19, 0.5), Vector3(W * 0.5 - 0.04, 0.04, 0.9), Basis(Vector3.RIGHT, 0.12), FirstPersonArt.M_PLASTIC, BLACK.lightened(0.08))
			s.rbox(Vector3(W * 0.75, 1.19, 0.5), Vector3(W * 0.5 - 0.04, 0.04, 0.9), Basis(Vector3.RIGHT, 0.12), FirstPersonArt.M_PLASTIC, BLACK.lightened(0.08))
			for p: Vector2 in [Vector2(0.2, 0.2), Vector2(W - 0.2, 0.2), Vector2(0.2, 0.82), Vector2(W - 0.2, 0.82)]:
				s.zcyl(Vector3(p.x, 0.07, p.y - 0.03), 0.07, 0.06, FirstPersonArt.M_RUBBER, BLACK, 8)
			s.box(Vector3(0.04, 0.95, 0.4), Vector3(0.06, 1.05, 0.6), FirstPersonArt.M_METAL, dc.darkened(0.25))
			return -1.0
		"street_cabinet":
			s.box(Vector3(0.1, 0, 0.25), Vector3(0.9, 0.1, 0.75), FirstPersonArt.M_CONCRETE, Color(0.6, 0.6, 0.58))
			s.box(Vector3(0.14, 0.1, 0.3), Vector3(0.86, 1.36, 0.72), FirstPersonArt.M_PLATE, art)
			s.box(Vector3(0.12, 1.36, 0.28), Vector3(0.88, 1.4, 0.74), FirstPersonArt.M_METAL, art.darkened(0.2))
			s.box(Vector3(0.49, 0.2, 0.72), Vector3(0.51, 1.3, 0.725), FirstPersonArt.M_PLAIN, art.darkened(0.4))
			s.box(Vector3(0.2, 1.0, 0.72), Vector3(0.44, 1.2, 0.73), FirstPersonArt.M_GRILLE, art.darkened(0.1))
			s.box(Vector3(0.6, 1.05, 0.72), Vector3(0.74, 1.17, 0.73), FirstPersonArt.M_PLAIN, Color(0.95, 0.8, 0.1))
			s.box(Vector3(0.55, 0.65, 0.72), Vector3(0.58, 0.8, 0.74), FirstPersonArt.M_CHROME, CHROME)
			return 1.4
		"target":
			s.box(Vector3(0.2, 0, 0.45), Vector3(0.8, 0.04, 0.55), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(0.47, 0.04, 0.47), Vector3(0.53, 1.0, 0.53), FirstPersonArt.M_WOOD, WOOD_D)
			s.box(Vector3(0.15, 0.95, 0.5), Vector3(0.85, 1.65, 0.54), FirstPersonArt.M_WOOD, Color(0.85, 0.8, 0.68))
			var rc := [WHITE, BLACK, WHITE, Color(0.8, 0.15, 0.1)]
			for k in 4:
				s.zcyl(Vector3(0.5, 1.3, 0.54 + k * 0.004), 0.3 - k * 0.075, 0.004, FirstPersonArt.M_PLAIN, rc[k], 16, 2)
			return -1.0
		"bench":
			for k in 3:
				s.box(Vector3(0.02, 0.42, 0.42 + k * 0.17), Vector3(W - 0.02, 0.46, 0.56 + k * 0.17), FirstPersonArt.M_PLANKS, art)
			for k in 2:
				s.box(Vector3(0.02, 0.56 + k * 0.17, 0.28), Vector3(W - 0.02, 0.69 + k * 0.17, 0.32), FirstPersonArt.M_PLANKS, art)
			var frames: Array = [0.12, W - 0.16]
			if W > 2.5:
				frames.append(W * 0.5 - 0.02)
			for x: float in frames:
				s.box(Vector3(x, 0, 0.3), Vector3(x + 0.04, 0.9, 0.34), FirstPersonArt.M_STEEL, METAL_D)
				s.box(Vector3(x, 0, 0.84), Vector3(x + 0.04, 0.42, 0.88), FirstPersonArt.M_STEEL, METAL_D)
				s.box(Vector3(x, 0.38, 0.3), Vector3(x + 0.04, 0.42, 0.88), FirstPersonArt.M_STEEL, METAL_D)
			return 0.46
		"streetlight":
			var top2 := minf(4.2, cap)
			s.box(Vector3(0.38, 0, 0.38), Vector3(0.62, 0.3, 0.62), FirstPersonArt.M_CONCRETE, Color(0.55, 0.55, 0.53))
			s.cyl(Vector3(0.5, 0.3, 0.5), 0.07, 0.045, top2 - 0.3, FirstPersonArt.M_METAL, METAL_D, 8)
			s.box(Vector3(0.47, top2 - 0.1, 0.5), Vector3(0.53, top2 - 0.04, 1.4), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.36, top2 - 0.2, 1.2), Vector3(0.64, top2 - 0.06, 1.62), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.39, top2 - 0.21, 1.23), Vector3(0.61, top2 - 0.2, 1.59), FirstPersonArt.M_PLAIN, lamp)
			return -1.0
		"floodlight", "work_light":
			var hf := minf(1.9 if base == "floodlight" else 1.4, cap)
			for k in 3:
				var a := TAU * k / 3.0
				s.rbox(Vector3(0.5 + cos(a) * 0.17, hf * 0.22, 0.5 + sin(a) * 0.17), Vector3(0.03, hf * 0.47, 0.03),
						Basis(Vector3(sin(a), 0, -cos(a)), 0.38), FirstPersonArt.M_METAL, METAL_D)
			s.cyl(Vector3(0.5, 0.0, 0.5), 0.025, 0.025, hf - 0.15, FirstPersonArt.M_METAL, METAL_D, 6, 2)
			s.rbox(Vector3(0.5, hf - 0.08, 0.56), Vector3(0.42, 0.28, 0.14), Basis(Vector3.RIGHT, 0.35), FirstPersonArt.M_PLATE, METAL_D)
			s.rbox(Vector3(0.5, hf - 0.1, 0.635), Vector3(0.36, 0.22, 0.01), Basis(Vector3.RIGHT, 0.35), FirstPersonArt.M_PLAIN, lamp)
			return -1.0
		"bollard_light":
			s.cyl(Vector3(0.5, 0, 0.5), 0.1, 0.1, 0.72, FirstPersonArt.M_METAL, METAL_D, 10)
			s.cyl(Vector3(0.5, 0.72, 0.5), 0.09, 0.09, 0.1, FirstPersonArt.M_PLAIN, lamp, 10, 0)
			s.cyl(Vector3(0.5, 0.82, 0.5), 0.11, 0.06, 0.06, FirstPersonArt.M_METAL, METAL_D, 10)
			return -1.0
		"floor_lamp", "lamp":
			var hl := minf(1.6 if base == "floor_lamp" else 1.35, cap)
			s.cyl(Vector3(0.5, 0, 0.5), 0.14, 0.12, 0.03, FirstPersonArt.M_METAL, METAL_D, 10)
			s.cyl(Vector3(0.5, 0.03, 0.5), 0.015, 0.015, hl - 0.3, FirstPersonArt.M_METAL, METAL_D, 6)
			s.cyl(Vector3(0.5, hl - 0.3, 0.5), 0.22, 0.13, 0.3, FirstPersonArt.M_FABRIC, Color(0.92, 0.85, 0.7), 12, 0)
			s.cyl(Vector3(0.5, hl - 0.29, 0.5), 0.2, 0.2, 0.001, FirstPersonArt.M_PLAIN, lamp, 12, 1)
			return -1.0
		"bush", "bush_dry", "bush_flowering", "park_tree":
			_greenery(s, base, art, seed, cap, bool(ctx.get("winter", false)))
			return -1.0
		"pine_tree":
			_pine(s, seed, cap, bool(ctx.get("winter", false)))
			return -1.0
		"hedge":
			var x0h := 0.0 if jl else 0.06
			var x1h := 1.0 if jr else 0.94
			s.box(Vector3(x0h, 0.0, 0.18), Vector3(x1h, 0.08, 0.82), FirstPersonArt.M_SOIL, Color(0.3, 0.24, 0.17))
			s.box(Vector3(x0h, 0.08, 0.16), Vector3(x1h, 0.95, 0.84), FirstPersonArt.M_LEAVES, Color(0.24, 0.4, 0.19),
					(Sink.NO_LEFT if jl else 0) | (Sink.NO_RIGHT if jr else 0))
			for k in 4:
				s.blob(Vector3(0.15 + k * 0.24, 0.9, 0.5), Vector3(0.16, 0.08, 0.3), FirstPersonArt.M_LEAVES, Color(0.27, 0.44, 0.21), seed + k, 6, 3)
			if ctx.get("winter", false):
				s.box(Vector3(x0h, 0.95, 0.2), Vector3(x1h, 1.0, 0.8), FirstPersonArt.M_SNOW, Color.WHITE)
			return -1.0
		"tall_grass":
			var cols := [Color(0.42, 0.52, 0.22), Color(0.52, 0.58, 0.28), Color(0.34, 0.45, 0.18)]
			for k in 14:
				var a := TAU * k / 14.0 + seed
				var lean := 0.18 + 0.3 * FirstPersonArt._h(k, seed, 4)
				var hgt := 0.45 + 0.4 * FirstPersonArt._h(k, seed, 5)
				s.rbox(Vector3(0.5 + cos(a) * 0.12, hgt * 0.45, 0.5 + sin(a) * 0.12), Vector3(0.025, hgt, 0.01),
						Basis(Vector3(sin(a), 0, -cos(a)), lean), FirstPersonArt.M_LEAVES, cols[k % 3])
			if ctx.get("winter", false):
				s.blob(Vector3(0.5, 0.08, 0.5), Vector3(0.28, 0.1, 0.28), FirstPersonArt.M_SNOW, Color.WHITE, seed, 7, 3)
			return -1.0
		"flower_bed":
			var x0f := 0.0 if jl else 0.03
			var x1f := 1.0 if jr else 0.97
			s.box(Vector3(x0f, 0.0, 0.08), Vector3(x1f, 0.28, 0.92), FirstPersonArt.M_CONCRETE, Color(0.55, 0.3, 0.24),
					(Sink.NO_LEFT if jl else 0) | (Sink.NO_RIGHT if jr else 0))
			s.box(Vector3(x0f + 0.001, 0.28, 0.14), Vector3(x1f - 0.001, 0.29, 0.86), FirstPersonArt.M_SOIL, Color(0.3, 0.22, 0.15), Sink.NO_BOTTOM)
			var petals := [Color(0.85, 0.27, 0.35), Color(0.95, 0.75, 0.25), Color(0.92, 0.9, 0.95), Color(0.55, 0.35, 0.8)]
			for k in 9:
				var px := 0.12 + (k % 3) * 0.38 + 0.1 * FirstPersonArt._h(k, seed, 6)
				var pz := 0.22 + (k / 3) * 0.26
				s.box(Vector3(px - 0.012, 0.29, pz - 0.012), Vector3(px + 0.012, 0.42, pz + 0.012), FirstPersonArt.M_LEAVES, Color(0.3, 0.5, 0.22))
				if not ctx.get("winter", false):
					s.box(Vector3(px - 0.04, 0.42, pz - 0.04), Vector3(px + 0.04, 0.47, pz + 0.04), FirstPersonArt.M_PLAIN, petals[(k + seed) % 4])
			if ctx.get("winter", false):
				s.box(Vector3(x0f + 0.02, 0.29, 0.12), Vector3(x1f - 0.02, 0.36, 0.88), FirstPersonArt.M_SNOW, Color.WHITE)
			return -1.0
		"planter_bed":
			var x0p := 0.0 if jl else 0.03
			var x1p := 1.0 if jr else 0.97
			s.box(Vector3(x0p, 0.0, 0.1), Vector3(x1p, 0.42, 0.9), FirstPersonArt.M_PLANKS, Color(0.55, 0.38, 0.22),
					(Sink.NO_LEFT if jl else 0) | (Sink.NO_RIGHT if jr else 0))
			s.box(Vector3(x0p + 0.001, 0.42, 0.16), Vector3(x1p - 0.001, 0.44, 0.84), FirstPersonArt.M_SOIL, Color(0.3, 0.22, 0.15), Sink.NO_BOTTOM)
			for k in 3:
				s.blob(Vector3(0.2 + k * 0.3, 0.52, 0.5), Vector3(0.13, 0.1, 0.16), FirstPersonArt.M_LEAVES, Color(0.3, 0.52, 0.22).lightened(0.05 * k), seed + k, 6, 3)
			return 0.44
		"hydroponic_rack":
			var hr := minf(1.6, cap)
			var x0r := 0.0 if jl else 0.03
			var x1r := 1.0 if jr else 0.97
			for p: Vector2 in [Vector2(x0r, 0.1), Vector2(x1r - 0.04, 0.1), Vector2(x0r, 0.86), Vector2(x1r - 0.04, 0.86)]:
				if (p.x < 0.5 and jl) or (p.x > 0.5 and jr):
					continue
				s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.04, hr, p.y + 0.04), FirstPersonArt.M_METAL, METAL_D)
			for level in 3:
				var y := 0.2 + level * (hr - 0.3) / 2.6
				s.box(Vector3(x0r, y, 0.1), Vector3(x1r, y + 0.08, 0.9), FirstPersonArt.M_PLASTIC, Color(0.85, 0.86, 0.84))
				for k in 4:
					s.blob(Vector3(0.14 + k * 0.24, y + 0.14, 0.5), Vector3(0.09, 0.08, 0.16), FirstPersonArt.M_LEAVES,
							Color(0.32, 0.55, 0.24).lightened(0.04 * ((k + level) % 3)), seed + k + level * 4, 6, 3)
				s.box(Vector3(x0r, y + 0.38, 0.45), Vector3(x1r, y + 0.4, 0.55), FirstPersonArt.M_PLAIN, glow(Color(0.95, 0.6, 1.0)))
			return -1.0
		"seed_table":
			s.box(Vector3(0.04, 0.84, 0.06), Vector3(W - 0.04, 0.88, 0.94), FirstPersonArt.M_METAL, METAL.lightened(0.1))
			for p: Vector2 in [Vector2(0.08, 0.1), Vector2(W - 0.12, 0.1), Vector2(0.08, 0.86), Vector2(W - 0.12, 0.86)]:
				s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.04, 0.84, p.y + 0.04), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.08, 0.2, 0.1), Vector3(W - 0.08, 0.23, 0.9), FirstPersonArt.M_METAL, METAL)
			for k in int(W * 2):
				var tx := 0.12 + k * (W - 0.24) / (W * 2)
				s.box(Vector3(tx, 0.88, 0.2), Vector3(tx + 0.4, 0.93, 0.62), FirstPersonArt.M_PLASTIC, Color(0.15, 0.15, 0.16))
				for g2 in 6:
					s.box(Vector3(tx + 0.06 + (g2 % 3) * 0.12, 0.93, 0.3 + (g2 / 3) * 0.18), Vector3(tx + 0.1 + (g2 % 3) * 0.12, 0.99, 0.34 + (g2 / 3) * 0.18),
							FirstPersonArt.M_LEAVES, Color(0.35, 0.6, 0.25))
				s.cyl(Vector3(tx + 0.2, 0.88, 0.8), 0.06, 0.08, 0.12, FirstPersonArt.M_CONCRETE, Color(0.62, 0.32, 0.2), 8)
			return 0.93
		"snowman":
			var snow := Color(0.95, 0.97, 1.0)
			s.blob(Vector3(0.5, 0.3, 0.5), Vector3(0.32, 0.3, 0.32), FirstPersonArt.M_SNOW, snow, seed, 9, 5)
			s.blob(Vector3(0.5, 0.82, 0.5), Vector3(0.23, 0.22, 0.23), FirstPersonArt.M_SNOW, snow, seed + 1, 8, 5)
			s.blob(Vector3(0.5, 1.2, 0.5), Vector3(0.16, 0.16, 0.16), FirstPersonArt.M_SNOW, snow, seed + 2, 8, 4)
			s.cyl(Vector3(0.5, 0.98, 0.5), 0.18, 0.18, 0.06, FirstPersonArt.M_FABRIC, Color(0.7, 0.18, 0.15), 10)
			s.rbox(Vector3(0.5, 1.2, 0.7), Vector3(0.035, 0.035, 0.16), Basis.IDENTITY, FirstPersonArt.M_PLAIN, Color(0.9, 0.48, 0.15))
			for x in [0.44, 0.56]:
				s.box(Vector3(x - 0.018, 1.25, 0.64), Vector3(x + 0.018, 1.28, 0.66), FirstPersonArt.M_PLAIN, BLACK)
			s.cyl(Vector3(0.5, 1.33, 0.5), 0.12, 0.12, 0.03, FirstPersonArt.M_FABRIC, BLACK, 10)
			s.cyl(Vector3(0.5, 1.36, 0.5), 0.08, 0.08, 0.14, FirstPersonArt.M_FABRIC, BLACK, 10)
			return -1.0
		"snowdrift":
			var x0s := -0.05 if jl else 0.05
			var x1s := 1.05 if jr else 0.95
			s.blob(Vector3((x0s + x1s) * 0.5, 0.0, 0.5), Vector3((x1s - x0s) * 0.55, 0.38, 0.42), FirstPersonArt.M_SNOW, Color.WHITE, seed, 9, 4)
			return -1.0
		"toolbox":
			s.box(Vector3(0.28, 0, 0.4), Vector3(0.72, 0.2, 0.6), FirstPersonArt.M_PLATE, Color(0.75, 0.15, 0.1))
			s.box(Vector3(0.4, 0.2, 0.48), Vector3(0.6, 0.24, 0.52), FirstPersonArt.M_PLAIN, BLACK)
			return 0.2
	# Anything not modelled yet: a neat block in its own colour.
	var hh := minf(Furniture.height_of(fid), cap)
	s.box(Vector3(0.08, 0, 0.08), Vector3(W - 0.08, hh, D - 0.08), FirstPersonArt.M_PLAIN, art)
	return hh

## A desk with a drawer pedestal on the left, a side panel on the right, a modesty panel.
static func _drawer_desk(s: Sink, W: float, _D: float, art: Color, m: int, legs: Color) -> void:
	s.box(Vector3(0.0, 0.72, 0.04), Vector3(W, 0.76, 0.96), m, art.lightened(0.05))
	s.box(Vector3(0.04, 0.0, 0.08), Vector3(0.5, 0.72, 0.9), m, art)
	for k in 3:
		s.box(Vector3(0.07, 0.06 + k * 0.22, 0.9), Vector3(0.47, 0.25 + k * 0.22, 0.915), m, art.lightened(0.1))
		s.box(Vector3(0.22, 0.15 + k * 0.22, 0.915), Vector3(0.32, 0.17 + k * 0.22, 0.935), FirstPersonArt.M_CHROME, CHROME)
	s.box(Vector3(W - 0.07, 0.0, 0.08), Vector3(W - 0.03, 0.72, 0.9), m, legs)
	s.box(Vector3(0.5, 0.36, 0.1), Vector3(W - 0.07, 0.72, 0.13), m, legs)

## Tables: a top, an apron under it, legs at the corners (or the table's own kind of base).
static func _table(s: Sink, base: String, W: float, D: float, paint: Color, art: Color, seed: int) -> float:
	match base:
		"park_table":
			for k in 4:
				s.box(Vector3(0.05, 0.72, 0.22 + k * 0.145), Vector3(W - 0.05, 0.76, 0.35 + k * 0.145), FirstPersonArt.M_PLANKS, art)
			for z in [0.02, 0.84]:
				s.box(Vector3(0.1, 0.42, z), Vector3(W - 0.1, 0.46, z + 0.14), FirstPersonArt.M_PLANKS, art)
			for x in [0.3, W - 0.36]:
				s.box(Vector3(x, 0.38, 0.0), Vector3(x + 0.06, 0.42, 1.0), FirstPersonArt.M_PLANKS, WOOD_D)
				s.rbox(Vector3(x + 0.03, 0.36, 0.3), Vector3(0.06, 0.8, 0.06), Basis(Vector3.RIGHT, -0.5), FirstPersonArt.M_PLANKS, WOOD_D)
				s.rbox(Vector3(x + 0.03, 0.36, 0.7), Vector3(0.06, 0.8, 0.06), Basis(Vector3.RIGHT, 0.5), FirstPersonArt.M_PLANKS, WOOD_D)
			return 0.76
		"coffee_table":
			s.box(Vector3(0.1, 0.4, 0.15), Vector3(0.9, 0.45, 0.85), FirstPersonArt.M_WOOD, art)
			for p: Vector2 in [Vector2(0.14, 0.19), Vector2(0.81, 0.19), Vector2(0.14, 0.76), Vector2(0.81, 0.76)]:
				s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.05, 0.4, p.y + 0.05), FirstPersonArt.M_WOOD, art.darkened(0.25))
			s.box(Vector3(0.14, 0.12, 0.19), Vector3(0.86, 0.14, 0.81), FirstPersonArt.M_WOOD, art.darkened(0.15))
			return 0.45
		"conference_table":
			s.box(Vector3(0.05, 0.71, 0.05), Vector3(W - 0.05, 0.76, D - 0.05), FirstPersonArt.M_WOOD, art)
			s.box(Vector3(0.04, 0.68, 0.04), Vector3(W - 0.04, 0.71, D - 0.04), FirstPersonArt.M_WOOD, art.darkened(0.3))
			for x in [W * 0.25, W * 0.75]:
				s.box(Vector3(x - 0.2, 0, D * 0.5 - 0.3), Vector3(x + 0.2, 0.68, D * 0.5 + 0.3), FirstPersonArt.M_WOOD, art.darkened(0.2))
			return 0.76
	var h := 0.75
	var top_m := FirstPersonArt.M_WOOD
	var leg_m := FirstPersonArt.M_WOOD
	var top_c := art
	var leg_c := art.darkened(0.25)
	var leg := 0.06
	match base:
		"plastic_table":
			top_m = FirstPersonArt.M_PLASTIC
			top_c = paint
			leg_m = FirstPersonArt.M_METAL
			leg_c = METAL
			leg = 0.035
			h = 0.72
		"steel_table":
			top_m = FirstPersonArt.M_METAL
			top_c = METAL.lightened(0.1)
			leg_m = FirstPersonArt.M_METAL
			leg_c = METAL_D
			leg = 0.04
			h = 0.86
	s.box(Vector3(0.03, h - 0.04, 0.03), Vector3(W - 0.03, h, D - 0.03), FirstPersonArt.M_PLANKS if top_m == FirstPersonArt.M_WOOD and base == "dining_table" else top_m, top_c)
	s.box(Vector3(0.09, h - 0.13, 0.09), Vector3(W - 0.09, h - 0.04, D - 0.09), leg_m, leg_c, Sink.NO_TOP)
	for p: Vector2 in [Vector2(0.09, 0.09), Vector2(W - 0.09 - leg, 0.09), Vector2(0.09, D - 0.09 - leg), Vector2(W - 0.09 - leg, D - 0.09 - leg)]:
		s.box(Vector3(p.x, 0, p.y), Vector3(p.x + leg, h - 0.13, p.y + leg), leg_m, leg_c, Sink.NO_TOP)
	if base == "steel_table":
		s.box(Vector3(0.09, 0.2, 0.09), Vector3(W - 0.09, 0.23, D - 0.09), leg_m, METAL)
	return h

## A row of base cabinets (counters, lab benches): one section per cell, doors on the front.
static func _run_cabinet(s: Sink, jl: bool, jr: bool, h: float, d: float, col: Color, m: int, doors: int) -> void:
	var x0 := 0.0 if jl else 0.02
	var x1 := 1.0 if jr else 0.98
	s.box(Vector3(x0, 0.1, 0.02), Vector3(x1, h, d), m, col, (Sink.NO_LEFT if jl else 0) | (Sink.NO_RIGHT if jr else 0))
	s.box(Vector3(x0, 0.0, 0.02), Vector3(x1, 0.1, d - 0.06), FirstPersonArt.M_PLAIN, col.darkened(0.55), (Sink.NO_LEFT if jl else 0) | (Sink.NO_RIGHT if jr else 0))
	if doors > 0:
		var w := (x1 - x0 - 0.02) / doors
		for k in doors:
			var a := x0 + 0.01 + k * w
			s.box(Vector3(a + 0.005, 0.14, d), Vector3(a + w - 0.005, h - 0.04, d + 0.015), m, col.lightened(0.06))
			var hx := a + (w - 0.05 if k == 0 else 0.03)
			s.box(Vector3(hx, h - 0.2, d + 0.015), Vector3(hx + 0.02, h - 0.1, d + 0.035), FirstPersonArt.M_CHROME, CHROME)

## Upright storage: wardrobes, dressers, cabinets, lockers, fridges, drawers.
static func _cabinet(s: Sink, base: String, W: float, D: float, paint: Color, art: Color, jl: bool, jr: bool,
		cap: float, seed: int) -> float:
	var spec: Array = {
		"wardrobe": [2.0, 0.6, FirstPersonArt.M_WOOD, "doors2"], "dresser": [0.9, 0.5, FirstPersonArt.M_WOOD, "drawers3"],
		"cabinet": [0.95, 0.5, FirstPersonArt.M_WOOD, "doors2"], "tool_cabinet": [1.0, 0.55, FirstPersonArt.M_PLATE, "drawers6"],
		"filing_cabinet": [1.3, 0.62, FirstPersonArt.M_METAL, "drawers4"], "locker": [1.9, 0.5, FirstPersonArt.M_PLATE, "lockers"],
		"industrial_cabinet": [1.6, 0.6, FirstPersonArt.M_PLATE, "doors2"], "biohazard_cabinet": [1.8, 0.55, FirstPersonArt.M_PLATE, "doors2"],
		"morgue_drawers": [1.9, 0.8, FirstPersonArt.M_METAL, "morgue"], "refrigerator": [1.85, 0.7, FirstPersonArt.M_PLASTIC, "fridge"],
		"specimen_fridge": [1.8, 0.65, FirstPersonArt.M_PLASTIC, "glassdoor"],
	}[base]
	var h := minf(float(spec[0]), cap)
	var d := float(spec[1])
	var m: int = spec[2]
	var kind: String = spec[3]
	var col := paint
	match base:
		"refrigerator", "specimen_fridge": col = WHITE.lerp(art, 0.25)
		"morgue_drawers": col = Color(0.72, 0.74, 0.76)
		"biohazard_cabinet": col = Color(0.88, 0.85, 0.75)
		"filing_cabinet": col = art.lerp(METAL, 0.5)
	var x0 := 0.0 if jl else 0.03
	var x1 := W if jr else W - 0.03
	var skip := (Sink.NO_LEFT if jl else 0) | (Sink.NO_RIGHT if jr else 0)
	var foot := 0.06 if m == FirstPersonArt.M_WOOD else 0.02
	s.box(Vector3(x0, foot, 0.02), Vector3(x1, h, d), m, col, skip)
	if foot > 0.03:
		s.box(Vector3(x0 + 0.03, 0, 0.04), Vector3(x1 - 0.03, foot, d - 0.03), m, col.darkened(0.4), skip)
	if m == FirstPersonArt.M_WOOD:
		s.box(Vector3(x0 - 0.01, h - 0.03, 0.01), Vector3(x1 + 0.01, h, d + 0.02), m, col.darkened(0.15))
	var fx0 := x0 + 0.03
	var fx1 := x1 - 0.03
	var fw := fx1 - fx0
	var lighter := col.lightened(0.07)
	match kind:
		"doors2":
			var leaves := 2 if fw > 0.6 else 1
			var lw := fw / leaves
			for k in leaves:
				var a := fx0 + k * lw
				s.box(Vector3(a + 0.006, foot + 0.04, d), Vector3(a + lw - 0.006, h - 0.06, d + 0.018), m, lighter)
				var hx := a + (lw - 0.07 if k == 0 and leaves == 2 else 0.04)
				s.box(Vector3(hx, h * 0.45, d + 0.018), Vector3(hx + 0.025, h * 0.45 + 0.22, d + 0.04), FirstPersonArt.M_CHROME, CHROME)
			if base == "biohazard_cabinet":
				s.box(Vector3(fx0 + fw * 0.35, h * 0.62, d + 0.018), Vector3(fx0 + fw * 0.65, h * 0.62 + 0.2, d + 0.022), FirstPersonArt.M_PLAIN, Color(0.95, 0.55, 0.1))
			if base == "industrial_cabinet":
				s.box(Vector3(x0, foot, d), Vector3(x1, foot + 0.1, d + 0.02), FirstPersonArt.M_PLAIN, Color(0.85, 0.7, 0.1))
				s.box(Vector3(fx0 + 0.1, h - 0.3, d + 0.018), Vector3(fx1 - 0.1, h - 0.12, d + 0.022), FirstPersonArt.M_GRILLE, col.darkened(0.2))
		"drawers3", "drawers4", "drawers6":
			var rows := int(kind.substr(7))
			var rh := (h - foot - 0.06) / rows
			for k in rows:
				var y := foot + 0.03 + k * rh
				s.box(Vector3(fx0, y + 0.006, d), Vector3(fx1, y + rh - 0.006, d + 0.018), m, lighter)
				var hw := minf(0.18, fw * 0.4) if rows < 6 else fw * 0.7
				s.box(Vector3((fx0 + fx1) * 0.5 - hw * 0.5, y + rh * 0.55, d + 0.018), Vector3((fx0 + fx1) * 0.5 + hw * 0.5, y + rh * 0.55 + 0.02, d + 0.035), FirstPersonArt.M_CHROME, CHROME)
				if base == "filing_cabinet":
					s.box(Vector3((fx0 + fx1) * 0.5 - 0.06, y + rh * 0.72, d + 0.018), Vector3((fx0 + fx1) * 0.5 + 0.06, y + rh * 0.72 + 0.04, d + 0.022), FirstPersonArt.M_PAPER, WHITE)
			if base == "tool_cabinet":
				for p in [0.1, W - 0.16]:
					s.cyl(Vector3(p + 0.03, -0.0, 0.15), 0.035, 0.035, 0.02, FirstPersonArt.M_RUBBER, BLACK, 8)
		"lockers":
			var count := maxi(1, roundi(fw / 0.33))
			var lw2 := fw / count
			for k in count:
				var a2 := fx0 + k * lw2
				s.box(Vector3(a2 + 0.005, foot + 0.05, d), Vector3(a2 + lw2 - 0.005, h - 0.05, d + 0.015), m, lighter)
				s.box(Vector3(a2 + 0.05, h - 0.35, d + 0.015), Vector3(a2 + lw2 - 0.05, h - 0.17, d + 0.018), FirstPersonArt.M_GRILLE, col.darkened(0.15))
				s.box(Vector3(a2 + lw2 - 0.07, h * 0.5, d + 0.015), Vector3(a2 + lw2 - 0.045, h * 0.5 + 0.12, d + 0.035), FirstPersonArt.M_CHROME, CHROME)
				s.box(Vector3(a2 + 0.05, h - 0.48, d + 0.015), Vector3(a2 + 0.12, h - 0.44, d + 0.018), FirstPersonArt.M_PAPER, WHITE)
		"morgue":
			var rows2 := 3
			var rh2 := (h - 0.1) / rows2
			for k in rows2:
				var y2 := 0.05 + k * rh2
				s.box(Vector3(fx0 + 0.03, y2 + 0.03, d), Vector3(fx1 - 0.03, y2 + rh2 - 0.03, d + 0.02), FirstPersonArt.M_METAL, col.lightened(0.08))
				s.box(Vector3((fx0 + fx1) * 0.5 - 0.1, y2 + rh2 * 0.5, d + 0.02), Vector3((fx0 + fx1) * 0.5 + 0.1, y2 + rh2 * 0.5 + 0.03, d + 0.05), FirstPersonArt.M_CHROME, CHROME)
				s.box(Vector3(fx0 + 0.08, y2 + rh2 * 0.7, d + 0.02), Vector3(fx0 + 0.2, y2 + rh2 * 0.7 + 0.05, d + 0.022), FirstPersonArt.M_PAPER, WHITE)
		"fridge":
			s.box(Vector3(fx0, foot + 0.04, d), Vector3(fx1, h * 0.62, d + 0.03), m, lighter)
			s.box(Vector3(fx0, h * 0.62 + 0.012, d), Vector3(fx1, h - 0.03, d + 0.03), m, lighter)
			for y3 in [h * 0.62 - 0.4, h * 0.62 + 0.06]:
				s.box(Vector3(fx1 - 0.08, y3, d + 0.03), Vector3(fx1 - 0.05, y3 + 0.3, d + 0.06), FirstPersonArt.M_CHROME, CHROME)
		"glassdoor":
			s.box(Vector3(fx0, foot + 0.04, d), Vector3(fx1, h - 0.06, d + 0.012), FirstPersonArt.M_PLASTIC, col.darkened(0.1))
			s.box(Vector3(fx0 + 0.05, 0.3, d + 0.012), Vector3(fx1 - 0.05, h - 0.15, d + 0.014), FirstPersonArt.M_GOODS, glow(Color(0.55, 0.75, 0.85)))
			s.box(Vector3(fx1 - 0.06, h * 0.5, d + 0.014), Vector3(fx1 - 0.035, h * 0.5 + 0.3, d + 0.04), FirstPersonArt.M_CHROME, CHROME)
	return h if h < 1.4 else -1.0

## Shelving: uprights, boards, and what is on them (books, goods, boxes).
static func _shelf(s: Sink, base: String, fid: String, jl: bool, jr: bool, cap: float, seed: int, art: Color) -> void:
	var h := minf(1.8 if base == "display_shelf" else 2.0, cap)
	var metal := base == "storage_shelf"
	var frame_c := METAL_D if metal else (art if base == "bookshelf" else WOOD)
	var m := FirstPersonArt.M_METAL if metal else FirstPersonArt.M_WOOD
	var d := 0.45 if metal else 0.38
	var z0 := 0.04 if metal else 0.02
	if not jl:
		s.box(Vector3(0.02, 0, z0), Vector3(0.05, h, d), m, frame_c)
	if not jr:
		s.box(Vector3(0.95, 0, z0), Vector3(0.98, h, d), m, frame_c)
	if not metal:
		s.box(Vector3(0.0 if jl else 0.05, 0, 0.0), Vector3(1.0 if jr else 0.95, h, 0.02), m, frame_c.darkened(0.2))
	var levels := 5 if base == "bookshelf" else 4
	var x0 := 0.0 if jl else 0.05
	var x1 := 1.0 if jr else 0.95
	var contents := str(Furniture.DEFS.get(fid, {}).get("contents", ""))
	for k in levels:
		var y := 0.06 + (h - 0.12) * k / (levels - 1)
		s.box(Vector3(x0, y - 0.03, z0), Vector3(x1, y, d), m, frame_c if not metal else Color(0.85, 0.45, 0.15) if k % 2 == 0 else METAL)
		if k == levels - 1:
			break
		var room := (h - 0.12) / (levels - 1) - 0.05
		var x := x0 + 0.01
		var i := 0
		while x < x1 - 0.06:
			var r := FirstPersonArt._h(i, k, seed)
			var w := 0.1 + r * 0.22
			if x + w > x1 - 0.01:
				w = x1 - 0.01 - x
			var hh := room * (0.65 + 0.3 * FirstPersonArt._h(i, k + 7, seed))
			match base:
				"bookshelf":
					if r < 0.12:
						x += 0.08   # a gap
					else:
						s.box(Vector3(x, y, z0 + 0.05), Vector3(x + w, y + hh, d - 0.03), FirstPersonArt.M_BOOKS, Color.WHITE)
				"display_shelf":
					if contents != "empty":
						var gc := Color.WHITE
						match contents:
							"drinks": gc = Color(0.75, 0.9, 1.0)
							"medical": gc = Color(1.0, 0.85, 0.85)
							"food": gc = Color(1.0, 0.95, 0.8)
						s.box(Vector3(x, y, z0 + 0.06), Vector3(x + w, y + hh * 0.8, d - 0.04), FirstPersonArt.M_GOODS, gc)
				"storage_shelf":
					if contents != "empty" and r > 0.15:
						var bc := Color(0.66, 0.5, 0.32)
						var bm := FirstPersonArt.M_CARDBOARD
						match contents:
							"tools": bc = Color(0.75, 0.18, 0.12); bm = FirstPersonArt.M_PLATE
							"medical": bc = Color(0.9, 0.9, 0.88); bm = FirstPersonArt.M_PLASTIC
							"food": bc = Color(0.7, 0.55, 0.35)
						s.box(Vector3(x, y, z0 + 0.04), Vector3(x + w, y + hh, d - 0.04), bm, bc)
						if contents == "medical":
							s.box(Vector3(x + w * 0.35, y + hh * 0.35, d - 0.04), Vector3(x + w * 0.65, y + hh * 0.65, d - 0.035), FirstPersonArt.M_PLAIN, Color(0.85, 0.1, 0.1))
			x += w + 0.008
			i += 1
	if metal:
		for p: Vector2 in [Vector2(0.02, z0), Vector2(0.95, z0), Vector2(0.02, d - 0.03), Vector2(0.95, d - 0.03)]:
			if (p.x < 0.5 and jl) or (p.x > 0.5 and jr):
				continue
			s.box(Vector3(p.x, 0, p.y), Vector3(p.x + 0.03, h, p.y + 0.03), FirstPersonArt.M_METAL, Color(0.25, 0.35, 0.6))

## Heavy plant: machinery blocks and the lathe-like workstation.
static func _machine(s: Sink, base: String, W: float, D: float, paint: Color, seed: int, cap: float) -> float:
	if base == "machine_workstation":
		s.box(Vector3(0.08, 0, 0.2), Vector3(0.92, 0.8, 0.8), FirstPersonArt.M_PLATE, paint)
		s.box(Vector3(0.06, 0.8, 0.25), Vector3(0.94, 0.86, 0.75), FirstPersonArt.M_METAL, METAL)
		s.box(Vector3(0.08, 0.86, 0.3), Vector3(0.3, 1.15, 0.7), FirstPersonArt.M_PLATE, paint.darkened(0.15))
		s.xcyl(Vector3(0.3, 1.0, 0.5), 0.09, 0.1, FirstPersonArt.M_CHROME, CHROME, 10)
		s.box(Vector3(0.7, 0.86, 0.4), Vector3(0.86, 1.0, 0.6), FirstPersonArt.M_PLATE, paint.darkened(0.15))
		s.xcyl(Vector3(0.6, 1.0, 0.5), 0.02, 0.1, FirstPersonArt.M_CHROME, CHROME, 6)
		s.box(Vector3(0.12, 0.45, 0.8), Vector3(0.4, 0.7, 0.82), FirstPersonArt.M_PLATE, METAL_D)
		s.box(Vector3(0.16, 0.6, 0.82), Vector3(0.2, 0.64, 0.83), FirstPersonArt.M_PLAIN, glow(Color(0.3, 1.0, 0.4)))
		s.box(Vector3(0.24, 0.6, 0.82), Vector3(0.28, 0.64, 0.83), FirstPersonArt.M_PLAIN, glow(Color(1.0, 0.25, 0.2)))
		return -1.0
	var h := minf(2.0, cap)
	s.box(Vector3(0.05, 0, 0.05), Vector3(W - 0.05, 0.15, D - 0.05), FirstPersonArt.M_CONCRETE, Color(0.5, 0.5, 0.48))
	s.box(Vector3(0.2, 0.15, 0.2), Vector3(W * 0.6, h - 0.1, D - 0.2), FirstPersonArt.M_PLATE, paint)
	s.box(Vector3(0.18, h - 0.1, 0.18), Vector3(W * 0.6 + 0.02, h - 0.05, D - 0.18), FirstPersonArt.M_PLATE, paint.darkened(0.2))
	s.xcyl(Vector3(W * 0.6, 0.7, D * 0.5), 0.35, W * 0.3, FirstPersonArt.M_METAL, METAL, 12)
	s.box(Vector3(W - 0.45, 0.15, 0.25), Vector3(W - 0.15, 1.5, 0.6), FirstPersonArt.M_PLATE, METAL_D)
	for k in 3:
		s.box(Vector3(W - 0.4 + k * 0.08, 1.3, 0.6), Vector3(W - 0.36 + k * 0.08, 1.34, 0.61), FirstPersonArt.M_PLAIN,
				glow([Color(0.3, 1.0, 0.4), Color(1.0, 0.75, 0.2), Color(1.0, 0.25, 0.2)][(k + seed) % 3]))
	s.box(Vector3(W - 0.42, 0.9, 0.6), Vector3(W - 0.18, 1.15, 0.605), FirstPersonArt.M_SCREEN, glow(Color(0.5, 0.85, 1.0)))
	for x in [0.35, W * 0.45]:
		s.cyl(Vector3(x, h - 0.05, D - 0.35), 0.06, 0.06, minf(cap, 2.25) - h + 0.05, FirstPersonArt.M_METAL, METAL_D, 8, 0)
	s.box(Vector3(0.2, 0.15, D - 0.2), Vector3(W * 0.6, 0.25, D - 0.19), FirstPersonArt.M_PLAIN, Color(0.85, 0.7, 0.1))
	return -1.0

## Potted plants by variant: a fern, a palm, a flowering shrub or the plain leafy one.
static func _plant(s: Sink, fid: String, seed: int, art: Color) -> void:
	var pot := Color(0.62, 0.32, 0.2)
	s.cyl(Vector3(0.5, 0, 0.5), 0.13, 0.17, 0.3, FirstPersonArt.M_CONCRETE, pot, 10, 1)
	s.cyl(Vector3(0.5, 0.27, 0.5), 0.16, 0.16, 0.01, FirstPersonArt.M_SOIL, Color(0.3, 0.22, 0.15), 10, 2)
	var leaf := Color(0.25, 0.5, 0.22)
	if fid.ends_with("_palm"):
		s.cyl(Vector3(0.5, 0.28, 0.5), 0.03, 0.02, 0.75, FirstPersonArt.M_BARK, Color(0.45, 0.35, 0.22), 6, 0)
		for k in 7:
			var a := TAU * k / 7.0 + seed
			s.rbox(Vector3(0.5 + cos(a) * 0.2, 1.0, 0.5 + sin(a) * 0.2), Vector3(0.45, 0.012, 0.09),
					Basis(Vector3.UP, -a) * Basis(Vector3.BACK, -0.45), FirstPersonArt.M_LEAVES, leaf.lightened(0.05 * (k % 2)))
		return
	if fid.ends_with("_fern"):
		for k in 9:
			var a2 := TAU * k / 9.0 + seed
			s.rbox(Vector3(0.5 + cos(a2) * 0.16, 0.42, 0.5 + sin(a2) * 0.16), Vector3(0.36, 0.01, 0.1),
					Basis(Vector3.UP, -a2) * Basis(Vector3.BACK, -0.6 + 0.2 * (k % 2)), FirstPersonArt.M_LEAVES, leaf.lightened(0.12))
		return
	var foliage := art if art.g > art.r else leaf
	s.blob(Vector3(0.5, 0.58, 0.5), Vector3(0.24, 0.26, 0.24), FirstPersonArt.M_LEAVES, foliage, seed)
	s.blob(Vector3(0.42, 0.74, 0.55), Vector3(0.15, 0.15, 0.15), FirstPersonArt.M_LEAVES, foliage.lightened(0.08), seed + 1)
	if fid.ends_with("_flowering"):
		for k in 8:
			var a3 := TAU * k / 8.0
			s.box(Vector3(0.5 + cos(a3) * 0.2 - 0.025, 0.62 + 0.12 * (k % 3), 0.5 + sin(a3) * 0.2 - 0.025),
					Vector3(0.5 + cos(a3) * 0.2 + 0.025, 0.67 + 0.12 * (k % 3), 0.5 + sin(a3) * 0.2 + 0.025), FirstPersonArt.M_PLAIN,
					[Color(0.95, 0.4, 0.6), Color(1.0, 0.85, 0.3), Color(0.95, 0.95, 0.95)][k % 3])

## A pine: a straight trunk under tiers of dark needles narrowing to a point; snow on each
## tier in winter.
static func _pine(s: Sink, seed: int, cap: float, winter: bool) -> void:
	var top := minf(5.2, cap)
	s.cyl(Vector3(0.5, 0, 0.5), 0.13, 0.06, top * 0.9, FirstPersonArt.M_BARK, Color(0.36, 0.26, 0.18), 7, 0)
	var tiers := 5
	for t in tiers:
		var y0 := top * (0.22 + t * 0.15)
		var r := 0.95 * (1.0 - float(t) / tiers) + 0.15
		var col := Color(0.16, 0.3, 0.17).lightened(0.04 * (t % 2))
		s.cyl(Vector3(0.5, y0, 0.5), r, 0.06, top * 0.24, FirstPersonArt.M_LEAVES, col, 9, 1)
		if winter:
			s.cyl(Vector3(0.5, y0 + top * 0.12, 0.5), r * 0.55, 0.05, top * 0.12, FirstPersonArt.M_SNOW, Color.WHITE, 9, 0)

## Bushes and trees: lumps of leaves (with flowers or bare twigs), a tree's trunk and crown.
static func _greenery(s: Sink, base: String, art: Color, seed: int, cap: float, winter := false) -> void:
	var leaf := art if art.g >= art.r * 0.9 else Color(0.3, 0.48, 0.2)
	if base == "park_tree":
		var top := minf(4.6, cap)
		var trunk_h := top * 0.55
		s.cyl(Vector3(0.5, 0, 0.5), 0.17, 0.1, trunk_h, FirstPersonArt.M_BARK, Color(0.38, 0.28, 0.2), 8, 0)
		s.rbox(Vector3(0.65, trunk_h * 0.8, 0.5), Vector3(0.5, 0.07, 0.07), Basis(Vector3.BACK, 0.7), FirstPersonArt.M_BARK, Color(0.36, 0.27, 0.19))
		s.rbox(Vector3(0.38, trunk_h * 0.9, 0.42), Vector3(0.45, 0.06, 0.06), Basis(Vector3.BACK, -0.8) * Basis(Vector3.UP, 0.6), FirstPersonArt.M_BARK, Color(0.36, 0.27, 0.19))
		var crown_c := leaf
		var cy := trunk_h + (top - trunk_h) * 0.45
		var sz := (top - trunk_h) * 0.6
		s.blob(Vector3(0.5, cy, 0.5), Vector3(sz * 1.15, sz * 0.8, sz * 1.15), FirstPersonArt.M_LEAVES, crown_c, seed, 9, 5)
		for k in 4:
			var a := TAU * k / 4.0 + seed * 0.7
			s.blob(Vector3(0.5 + cos(a) * sz * 0.75, cy - sz * 0.15 + 0.2 * (k % 2), 0.5 + sin(a) * sz * 0.75),
					Vector3(sz * 0.6, sz * 0.5, sz * 0.6), FirstPersonArt.M_LEAVES, crown_c.lightened(0.04 * k - 0.06), seed + k + 1, 7, 4)
		s.blob(Vector3(0.5, cy + sz * 0.55, 0.5), Vector3(sz * 0.6, sz * 0.45, sz * 0.6), FirstPersonArt.M_LEAVES, crown_c.lightened(0.08), seed + 9, 7, 4)
		if winter:
			s.blob(Vector3(0.5, cy + sz * 0.85, 0.5), Vector3(sz * 0.55, sz * 0.22, sz * 0.55), FirstPersonArt.M_SNOW, Color.WHITE, seed + 10, 7, 3)
			for k in 3:
				var a6 := TAU * k / 3.0 + seed
				s.blob(Vector3(0.5 + cos(a6) * sz * 0.7, cy + sz * 0.3, 0.5 + sin(a6) * sz * 0.7), Vector3(sz * 0.35, sz * 0.15, sz * 0.35),
						FirstPersonArt.M_SNOW, Color.WHITE, seed + 11 + k, 6, 3)
		return
	var dry := base == "bush_dry"
	var c := Color(0.46, 0.42, 0.26) if dry else leaf
	var lumps := 0 if dry else 5
	for k in lumps:
		var a2 := TAU * k / lumps + seed
		var r := 0.2 + 0.08 * FirstPersonArt._h(k, seed, 3)
		s.blob(Vector3(0.5 + cos(a2) * 0.17, 0.3 + 0.12 * (k % 2), 0.5 + sin(a2) * 0.17), Vector3(r, r * 0.85, r),
				FirstPersonArt.M_LEAVES, c.lightened(0.05 * (k % 3) - 0.04), seed + k)
	if not dry:
		s.blob(Vector3(0.5, 0.55, 0.5), Vector3(0.22, 0.2, 0.22), FirstPersonArt.M_LEAVES, c.lightened(0.07), seed + 7)
	if winter:
		s.blob(Vector3(0.5, 0.68, 0.5), Vector3(0.26, 0.09, 0.26), FirstPersonArt.M_SNOW, Color.WHITE, seed + 8, 7, 3)
	else:
		# Bare twigs fanning out, a few tufts of dry leaves among them.
		for k in 9:
			var a3 := TAU * k / 9.0 + seed
			var lean := 0.35 + 0.25 * (k % 3)
			s.rbox(Vector3(0.5 + cos(a3) * 0.13, 0.32, 0.5 + sin(a3) * 0.13), Vector3(0.025, 0.62, 0.025),
					Basis(Vector3(sin(a3), 0, -cos(a3)), lean), FirstPersonArt.M_BARK, Color(0.33, 0.25, 0.16))
		for k in 4:
			var a5 := TAU * k / 4.0 + seed * 1.3
			s.blob(Vector3(0.5 + cos(a5) * 0.24, 0.45 + 0.1 * (k % 2), 0.5 + sin(a5) * 0.24), Vector3(0.1, 0.08, 0.1),
					FirstPersonArt.M_LEAVES, c.lightened(0.05 * k), seed + k, 5, 3)
	if base == "bush_flowering":
		for k in 14:
			var a4 := TAU * k / 14.0 + seed * 0.3
			var rr := 0.27 + 0.04 * (k % 3)
			var y := 0.32 + 0.3 * FirstPersonArt._h(k, seed, 9)
			s.box(Vector3(0.5 + cos(a4) * rr - 0.022, y, 0.5 + sin(a4) * rr - 0.022), Vector3(0.5 + cos(a4) * rr + 0.022, y + 0.035, 0.5 + sin(a4) * rr + 0.022),
					FirstPersonArt.M_PLAIN, [Color(0.95, 0.45, 0.65), Color(1.0, 0.92, 0.95), Color(0.95, 0.75, 0.25)][k % 3])

# --- Wall lamps -----------------------------------------------------------------------------

## A lamp on a wall face, in the frame of the cell in front of that face (its back is the
## wall): sconces, strip lights, caged bulkhead lamps, beacons and flood heads.
static func wall_lamp(s: Sink, id: String, light: Color, broken: bool) -> void:
	var on := glow(light.lightened(0.3)) if not broken else Color(0.3, 0.3, 0.3)
	match id:
		"wall_strip":
			s.box(Vector3(0.08, 1.98, 0.0), Vector3(0.92, 2.08, 0.07), FirstPersonArt.M_METAL, METAL)
			s.box(Vector3(0.1, 1.975, 0.01), Vector3(0.9, 1.98, 0.065), FirstPersonArt.M_PLAIN, on)
			s.box(Vector3(0.1, 1.99, 0.07), Vector3(0.9, 2.06, 0.075), FirstPersonArt.M_PLAIN, on)
		"bulkhead_lamp":
			s.box(Vector3(0.36, 1.86, 0.0), Vector3(0.64, 2.06, 0.03), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.39, 1.89, 0.03), Vector3(0.61, 2.03, 0.11), FirstPersonArt.M_PLAIN, on)
			for k in 3:
				s.box(Vector3(0.38, 1.91 + k * 0.05, 0.11), Vector3(0.62, 1.925 + k * 0.05, 0.125), FirstPersonArt.M_METAL, METAL_D)
		"wall_beacon":
			s.box(Vector3(0.42, 1.95, 0.0), Vector3(0.58, 2.03, 0.04), FirstPersonArt.M_METAL, METAL_D)
			s.zcyl(Vector3(0.5, 1.99, 0.04), 0.05, 0.05, FirstPersonArt.M_PLAIN, on, 8)
		"ceiling_lamp":
			s.box(Vector3(0.45, 2.05, 0.0), Vector3(0.55, 2.12, 0.12), FirstPersonArt.M_METAL, METAL_D)
			s.rbox(Vector3(0.5, 2.02, 0.2), Vector3(0.34, 0.14, 0.16), Basis(Vector3.RIGHT, 0.5), FirstPersonArt.M_PLATE, METAL_D)
			s.rbox(Vector3(0.5, 1.975, 0.245), Vector3(0.28, 0.01, 0.1), Basis(Vector3.RIGHT, 0.5), FirstPersonArt.M_PLAIN, on)
		_:
			# A sconce: back plate, an arm, a frosted shade glowing.
			s.box(Vector3(0.43, 1.86, 0.0), Vector3(0.57, 2.02, 0.02), FirstPersonArt.M_METAL, METAL_D)
			s.box(Vector3(0.48, 1.92, 0.02), Vector3(0.52, 1.95, 0.08), FirstPersonArt.M_METAL, METAL_D)
			s.cyl(Vector3(0.5, 1.88, 0.12), 0.07, 0.05, 0.14, FirstPersonArt.M_PLAIN, on, 8)

# --- Features -------------------------------------------------------------------------------

## Sandbags: rows of filled bags in running bond, two bags deep. along_x: the line runs
## along x; `cross`: it also turns here (only the ends of the other direction are added, so
## no two bags overlap). layers: 5 make a metre.
static func sandbags(s: Sink, layers: int, along_x: bool, along_z: bool, seed: int, y0 := 0.0) -> void:
	var lh := 0.19
	for l in layers:
		var y := y0 + l * lh
		if along_x or not along_z:
			_bag_row(s, y, lh, l, seed, false, 0.0, 1.0)
		if along_z:
			if along_x:
				_bag_row(s, y, lh, l, seed, true, 0.0, 0.15)
				_bag_row(s, y, lh, l, seed, true, 0.85, 1.0)
			else:
				_bag_row(s, y, lh, l, seed, true, 0.0, 1.0)

static func _bag_row(s: Sink, y: float, lh: float, layer: int, seed: int, on_z: bool, a0: float, a1: float) -> void:
	var cuts: Array = [0.0, 0.5, 1.0] if layer % 2 == 0 else [0.0, 0.25, 0.75, 1.0]
	for row in 2:
		var d0 := 0.15 + row * 0.35
		for i in cuts.size() - 1:
			var u0: float = maxf(cuts[i], a0)
			var u1: float = minf(cuts[i + 1], a1)
			if u1 - u0 < 0.03:
				continue
			var tone := 0.86 + 0.18 * FirstPersonArt._h(i + row * 5, layer, seed)
			var c := Color(0.66 * tone, 0.59 * tone, 0.44 * tone)
			# Four oval cross-sections make a filled sack with pinched ends, rather than
			# stacked boxes. Keep bags touching in running bond without extra draw calls.
			var keep := s.xf
			if on_z:
				s.xf = s.xf * Transform3D(Basis(Vector3.BACK, Vector3.UP, Vector3.LEFT), Vector3(1, 0, 0))
			var width := u1 - u0
			var rings: Array = []
			for band in 4:
				var along: float = [0.008, minf(0.07, width * 0.25), width - minf(0.07, width * 0.25), width - 0.008][band]
				var pinch := 0.64 if band == 0 or band == 3 else 1.0
				var ring: Array[Vector3] = []
				for k in 8:
					var angle := TAU * (k + 0.5) / 8.0
					var yy := signf(cos(angle)) * pow(absf(cos(angle)), 0.7)
					var zz := signf(sin(angle)) * pow(absf(sin(angle)), 0.7)
					ring.append(Vector3(u0 + along, y + lh * 0.5 + yy * lh * 0.52 * pinch, d0 + 0.175 + zz * 0.182 * pinch))
				rings.append(ring)
			for band in 3:
				for k in 8:
					var j := (k + 1) % 8
					var normal: Vector3 = (rings[band][j] - rings[band][k]).cross(rings[band + 1][k] - rings[band][k]).normalized()
					s.face([rings[band][k], rings[band][j], rings[band + 1][j], rings[band + 1][k]], normal,
							FirstPersonArt.M_BURLAP, c)
			s.face(rings[0], Vector3.LEFT, FirstPersonArt.M_BURLAP, c.darkened(0.08))
			s.face(rings[3], Vector3.RIGHT, FirstPersonArt.M_BURLAP, c.darkened(0.08))
			s.xf = keep

## A Czech hedgehog: three angle-iron beams, square to each other, crossed at their middles
## and standing on three ends, riveted where they meet; turned a little per cell.
static func hedgehog(s: Sink, seed: int, y0 := 0.0, size := 1.0) -> void:
	var length := 1.4 * size
	var up := Vector3(1, 1, 1).normalized()
	var tilt := Basis(Quaternion(up, Vector3.UP)) * Basis.IDENTITY
	var spin := Basis(Vector3.UP, 0.4 + FirstPersonArt._h(seed, 1, 2) * 0.6)
	var centre := Vector3(0.5, y0 + length * 0.5 / sqrt(3.0) + 0.02, 0.5)
	var steel := Color(0.4, 0.33, 0.28)
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		var b := spin * tilt
		var dir: Vector3 = b * axis
		# The beam's own frame: along `dir`, flanges along two perpendiculars.
		var side := dir.cross(Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT).normalized()
		var other := dir.cross(side).normalized()
		var basis := Basis(dir, side, other)
		var keep := s.xf
		s.xf = s.xf * Transform3D(basis, centre)
		s.box(Vector3(-length * 0.5, -0.006, -0.06), Vector3(length * 0.5, 0.006, 0.06), FirstPersonArt.M_STEEL, steel)
		s.box(Vector3(-length * 0.5, 0.006, -0.06), Vector3(length * 0.5, 0.11, -0.048), FirstPersonArt.M_STEEL, steel.darkened(0.1))
		s.xf = keep
	s.rbox(centre, Vector3(0.16, 0.16, 0.16), spin * tilt, FirstPersonArt.M_STEEL, steel.darkened(0.2))

## A heap of earth (or of scrap on a station): rings of jittered points rising to a crown.
static func heap(s: Sink, rubble: bool, seed: int) -> void:
	var radii := [0.5, 0.42, 0.3, 0.14]
	var ys := [0.0, 0.32, 0.6, 0.8]
	var sides := 9
	var rings: Array = []
	for r in radii.size():
		var ring: Array[Vector3] = []
		for i in sides:
			var a := TAU * i / sides + r * 0.3
			var j := 1.0 + 0.22 * (FirstPersonArt._h(i, r, seed) - 0.5)
			ring.append(Vector3(0.5 + cos(a) * radii[r] * j, ys[r] + 0.05 * FirstPersonArt._h(i, r + 4, seed), 0.5 + sin(a) * radii[r] * j))
		rings.append(ring)
	var m := FirstPersonArt.M_GRAVEL if rubble else FirstPersonArt.M_SOIL
	var c := Color(0.5, 0.5, 0.52) if rubble else Color(0.48, 0.36, 0.24)
	for r in rings.size() - 1:
		for i in sides:
			var k := (i + 1) % sides
			var pts := [rings[r][i], rings[r][k], rings[r + 1][k], rings[r + 1][i]]
			var mid: Vector3 = (pts[0] + pts[1] + pts[2] + pts[3]) * 0.25
			var tone := 0.85 + 0.25 * FirstPersonArt._h(i, r, seed + 1)
			s.face(pts, (mid - Vector3(0.5, mid.y - 0.3, 0.5)).normalized(), m, Color(c.r * tone, c.g * tone, c.b * tone))
	s.face(rings[rings.size() - 1], Vector3.UP, m, c.lightened(0.05))
	if rubble:
		for k in 5:
			var a2 := TAU * k / 5.0 + seed
			s.rbox(Vector3(0.5 + cos(a2) * 0.28, 0.3, 0.5 + sin(a2) * 0.28), Vector3(0.32, 0.04, 0.12),
					Basis(Vector3.UP, a2) * Basis(Vector3.RIGHT, 0.6), FirstPersonArt.M_PLATE, METAL.darkened(0.2))

## A stationary machine gun (DPMG) on its tripod, its barrel pointing along +x.
static func dpmg(s: Sink) -> void:
	var olive := Color(0.3, 0.33, 0.22)
	for a in [PI * 0.75, PI * 1.25, 0.0]:
		s.rbox(Vector3(0.5 + cos(a) * 0.22, 0.28, 0.5 + sin(a) * 0.22), Vector3(0.04, 0.62, 0.04),
				Basis(Vector3(sin(a), 0, -cos(a)), -0.55), FirstPersonArt.M_METAL, olive)
	s.cyl(Vector3(0.5, 0.5, 0.5), 0.05, 0.05, 0.12, FirstPersonArt.M_METAL, METAL_D, 8)
	s.box(Vector3(0.28, 0.62, 0.44), Vector3(0.72, 0.76, 0.56), FirstPersonArt.M_PLATE, Color(0.18, 0.19, 0.2))
	s.xcyl(Vector3(0.72, 0.7, 0.5), 0.05, 0.3, FirstPersonArt.M_METAL, Color(0.22, 0.23, 0.24), 10)
	s.xcyl(Vector3(1.0, 0.7, 0.5), 0.018, 0.32, FirstPersonArt.M_METAL, BLACK, 6)
	s.box(Vector3(0.36, 0.5, 0.56), Vector3(0.6, 0.68, 0.7), FirstPersonArt.M_PLATE, olive)
	s.box(Vector3(0.15, 0.62, 0.47), Vector3(0.28, 0.66, 0.53), FirstPersonArt.M_METAL, METAL_D)
	for z in [0.42, 0.58]:
		s.box(Vector3(0.12, 0.6, z - 0.015), Vector3(0.16, 0.72, z + 0.015), FirstPersonArt.M_RUBBER, BLACK)
	s.box(Vector3(0.6, 0.6, 0.3), Vector3(0.64, 1.0, 0.7), FirstPersonArt.M_PLATE, olive.darkened(0.1))

## A drone station: a raised pad with its landing ring, side lights and a mast.
static func drone_station(s: Sink, side: Color) -> void:
	s.box(Vector3(0.06, 0, 0.06), Vector3(0.94, 0.3, 0.94), FirstPersonArt.M_PLATE, METAL_D)
	s.box(Vector3(0.04, 0.3, 0.04), Vector3(0.96, 0.34, 0.96), FirstPersonArt.M_PLATE, METAL_D.lightened(0.1))
	# A ring on a single deck, with no overlapping discs or coplanar cross arms.
	for i in 24:
		var a := TAU * i / 24.0
		var b := TAU * (i + 1) / 24.0
		var center := Vector3(0.5, 0.345, 0.5)
		var da := Vector3(cos(a), 0, sin(a))
		var db := Vector3(cos(b), 0, sin(b))
		s.face([center + da * 0.3, center + da * 0.36, center + db * 0.36, center + db * 0.3],
				Vector3.UP, FirstPersonArt.M_PLAIN, Color(0.9, 0.75, 0.15))
	s.box(Vector3(0.47, 0.34, 0.36), Vector3(0.53, 0.35, 0.64), FirstPersonArt.M_PLAIN, WHITE, Sink.NO_BOTTOM)
	for x in [0.38, 0.53]:
		s.box(Vector3(x, 0.34, 0.47), Vector3(x + 0.09, 0.35, 0.53), FirstPersonArt.M_PLAIN, WHITE,
				Sink.NO_BOTTOM | (Sink.NO_RIGHT if x < 0.5 else Sink.NO_LEFT))
	for z in [0.045, 0.94]:
		for x in [0.12, 0.8]:
			s.box(Vector3(x, 0.22, z), Vector3(x + 0.08, 0.28, z + 0.015), FirstPersonArt.M_PLAIN, glow(side))
	s.cyl(Vector3(0.88, 0.34, 0.12), 0.012, 0.012, 0.5, FirstPersonArt.M_METAL, METAL, 6)
	s.box(Vector3(0.86, 0.84, 0.1), Vector3(0.9, 0.88, 0.14), FirstPersonArt.M_PLAIN, glow(side.lightened(0.3)))

## Mines: an anti-personnel disc with its prongs, a heavier anti-tank plate.
static func mine(s: Sink, av: bool) -> void:
	if av:
		s.cyl(Vector3(0.5, 0, 0.5), 0.17, 0.16, 0.07, FirstPersonArt.M_PLATE, Color(0.25, 0.32, 0.22), 12)
		s.cyl(Vector3(0.5, 0.07, 0.5), 0.07, 0.07, 0.02, FirstPersonArt.M_PLATE, Color(0.2, 0.25, 0.18), 10)
	else:
		s.cyl(Vector3(0.5, 0, 0.5), 0.07, 0.07, 0.04, FirstPersonArt.M_PLATE, Color(0.3, 0.33, 0.22), 10)
		for k in 3:
			s.box(Vector3(0.49 + (k - 1) * 0.02, 0.04, 0.49), Vector3(0.5 + (k - 1) * 0.02, 0.07, 0.5), FirstPersonArt.M_METAL, METAL_D)

## Solar panel cells on their frame, a hand above the deck.
static func solar(s: Sink, seed: int) -> void:
	s.box(Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.04, 1.0), FirstPersonArt.M_METAL, METAL_D, Sink.NO_BOTTOM)
	s.box(Vector3(0.02, 0.04, 0.02), Vector3(0.98, 0.05, 0.98), FirstPersonArt.M_SOLAR, Color.WHITE)
	if seed % 4 == 0:
		s.box(Vector3(0.45, -0.3, 0.45), Vector3(0.55, 0.0, 0.55), FirstPersonArt.M_METAL, METAL_D)

# --- Small items ----------------------------------------------------------------------------

## A small item at true size (×1.3, as the board draws them) centred on the origin, lying on
## y = 0: papers, mugs, monitors, tools... The board's picture gives its main colour.
static func item(s: Sink, kind: String, art: Color) -> void:
	var k := SmallItems.DRAW_SCALE
	var keep := s.xf
	s.xf = s.xf * Transform3D(Basis().scaled(Vector3(k, k, k)), Vector3.ZERO)
	s.shade_floor = false
	var c := art
	match kind:
		"papers", "map_sheet", "newspaper", "newspaper_local", "newspaper_science":
			var sz := Vector2(0.21, 0.3) if kind == "papers" else (Vector2(0.5, 0.4) if kind == "map_sheet" else Vector2(0.3, 0.4))
			s.box(Vector3(-sz.x * 0.5, 0, -sz.y * 0.5), Vector3(sz.x * 0.5, 0.004, sz.y * 0.5), FirstPersonArt.M_PAPER,
					Color(0.95, 0.92, 0.8) if kind == "map_sheet" else Color(0.97, 0.97, 0.95))
		"folder", "clipboard", "magazine":
			s.box(Vector3(-0.12, 0, -0.16), Vector3(0.12, 0.012, 0.16), FirstPersonArt.M_PLASTIC, c)
			if kind == "clipboard":
				s.box(Vector3(-0.1, 0.012, -0.12), Vector3(0.1, 0.014, 0.14), FirstPersonArt.M_PAPER, WHITE)
				s.box(Vector3(-0.04, 0.012, -0.15), Vector3(0.04, 0.025, -0.12), FirstPersonArt.M_CHROME, CHROME)
		"book":
			s.box(Vector3(-0.08, 0, -0.11), Vector3(0.08, 0.035, 0.11), FirstPersonArt.M_PLASTIC, c)
			s.box(Vector3(-0.075, 0.004, -0.105), Vector3(0.082, 0.031, 0.105), FirstPersonArt.M_PAPER, CLOTH)
		"mug":
			s.cyl(Vector3.ZERO, 0.04, 0.04, 0.095, FirstPersonArt.M_CERAMIC, c, 8, 3, 1.0, Color(0.25, 0.15, 0.1))
			s.box(Vector3(0.04, 0.02, -0.008), Vector3(0.065, 0.075, 0.008), FirstPersonArt.M_CERAMIC, c)
		"cup":
			s.cyl(Vector3.ZERO, 0.03, 0.036, 0.1, FirstPersonArt.M_PLAIN, Color(0.75, 0.88, 0.95), 8)
		"plate":
			s.cyl(Vector3.ZERO, 0.08, 0.11, 0.018, FirstPersonArt.M_CERAMIC, WHITE, 12)
		"bottle":
			s.cyl(Vector3.ZERO, 0.035, 0.035, 0.2, FirstPersonArt.M_PLAIN, c, 8, 1)
			s.cyl(Vector3(0, 0.2, 0), 0.035, 0.013, 0.04, FirstPersonArt.M_PLAIN, c, 8, 0)
			s.cyl(Vector3(0, 0.24, 0), 0.013, 0.013, 0.05, FirstPersonArt.M_PLAIN, c, 6)
		"can", "medicine", "sample_vial", "bandages":
			var r := 0.033 if kind == "can" else 0.022
			s.cyl(Vector3.ZERO, r, r, 0.12 if kind == "can" else 0.07, FirstPersonArt.M_METAL if kind == "can" else FirstPersonArt.M_PLASTIC, c, 8)
		"monitor":
			s.box(Vector3(-0.1, 0, -0.08), Vector3(0.1, 0.015, 0.06), FirstPersonArt.M_PLASTIC, BLACK)
			s.box(Vector3(-0.02, 0.015, -0.05), Vector3(0.02, 0.17, -0.02), FirstPersonArt.M_PLASTIC, BLACK)
			s.box(Vector3(-0.27, 0.12, -0.035), Vector3(0.27, 0.45, -0.005), FirstPersonArt.M_PLASTIC, Color(0.1, 0.1, 0.11))
			s.box(Vector3(-0.255, 0.135, -0.005), Vector3(0.255, 0.435, -0.003), FirstPersonArt.M_SCREEN, glow(Color(0.55, 0.75, 1.0)))
		"keyboard":
			s.box(Vector3(-0.22, 0, -0.07), Vector3(0.22, 0.025, 0.07), FirstPersonArt.M_TILE, Color(0.25, 0.25, 0.27))
		"mouse", "remote":
			s.box(Vector3(-0.03, 0, -0.05), Vector3(0.03, 0.025, 0.05) if kind == "mouse" else Vector3(0.025, 0.02, 0.085), FirstPersonArt.M_PLASTIC, BLACK.lightened(0.1))
		"phone":
			s.box(Vector3(-0.09, 0, -0.1), Vector3(0.09, 0.06, 0.1), FirstPersonArt.M_PLASTIC, c)
			s.box(Vector3(-0.08, 0.06, -0.03), Vector3(0.08, 0.09, 0.03), FirstPersonArt.M_PLASTIC, c.darkened(0.2))
		"laptop":
			s.box(Vector3(-0.16, 0, -0.11), Vector3(0.16, 0.02, 0.11), FirstPersonArt.M_METAL, METAL)
			s.rbox(Vector3(0, 0.12, -0.13), Vector3(0.32, 0.22, 0.01), Basis(Vector3.RIGHT, -0.2), FirstPersonArt.M_METAL, METAL)
			s.rbox(Vector3(0, 0.12, -0.124), Vector3(0.29, 0.19, 0.002), Basis(Vector3.RIGHT, -0.2), FirstPersonArt.M_SCREEN, glow(Color(0.6, 0.8, 1.0)))
		"radio", "multimeter", "cash_register":
			var big := kind == "cash_register"
			s.box(Vector3(-0.12 if not big else -0.18, 0, -0.06 if not big else -0.17), Vector3(0.12 if not big else 0.18, 0.12, 0.06 if not big else 0.17), FirstPersonArt.M_PLASTIC, c)
			if kind == "radio":
				s.cyl(Vector3(0.09, 0.12, 0.0), 0.004, 0.004, 0.2, FirstPersonArt.M_CHROME, CHROME, 4, 0)
			if big:
				s.rbox(Vector3(0, 0.2, -0.08), Vector3(0.2, 0.12, 0.015), Basis(Vector3.RIGHT, -0.3), FirstPersonArt.M_SCREEN, glow(Color(0.5, 1.0, 0.7)))
		"headset":
			s.box(Vector3(-0.08, 0, -0.04), Vector3(-0.04, 0.05, 0.04), FirstPersonArt.M_PLASTIC, BLACK)
			s.box(Vector3(0.04, 0, -0.04), Vector3(0.08, 0.05, 0.04), FirstPersonArt.M_PLASTIC, BLACK)
			s.box(Vector3(-0.07, 0.04, -0.01), Vector3(0.07, 0.055, 0.01), FirstPersonArt.M_PLASTIC, BLACK)
		"wrench", "screwdriver", "pliers", "hammer", "saw", "flashlight", "syringe", "flute", "keys", "handcuffs":
			var length: float = {"wrench": 0.22, "screwdriver": 0.18, "pliers": 0.18, "hammer": 0.3, "saw": 0.45,
					"flashlight": 0.2, "syringe": 0.12, "flute": 0.5, "keys": 0.07, "handcuffs": 0.2}[kind]
			s.box(Vector3(-length * 0.5, 0, -0.012), Vector3(length * 0.2, 0.02, 0.012), FirstPersonArt.M_METAL, METAL if kind != "flute" else Color(0.75, 0.75, 0.7))
			s.box(Vector3(length * 0.2, 0, -0.018), Vector3(length * 0.5, 0.03, 0.018), FirstPersonArt.M_PLASTIC, c)
			if kind == "hammer":
				s.box(Vector3(length * 0.42, 0, -0.06), Vector3(length * 0.52, 0.035, 0.06), FirstPersonArt.M_METAL, METAL_D)
			if kind == "saw":
				s.box(Vector3(-length * 0.5, 0, -0.06), Vector3(length * 0.2, 0.004, 0.02), FirstPersonArt.M_METAL, CHROME)
		"flask", "test_tubes", "petri_dish", "microscope":
			match kind:
				"flask":
					s.cyl(Vector3.ZERO, 0.06, 0.02, 0.12, FirstPersonArt.M_PLAIN, Color(0.6, 0.85, 0.75), 8, 1)
					s.cyl(Vector3(0, 0.12, 0), 0.018, 0.018, 0.06, FirstPersonArt.M_PLAIN, Color(0.75, 0.9, 0.95), 6)
				"test_tubes":
					s.box(Vector3(-0.1, 0, -0.03), Vector3(0.1, 0.05, 0.03), FirstPersonArt.M_WOOD, WOOD)
					for t in 4:
						s.cyl(Vector3(-0.075 + t * 0.05, 0.0, 0), 0.01, 0.01, 0.12, FirstPersonArt.M_PLAIN, [Color(0.9, 0.3, 0.3), Color(0.3, 0.8, 0.4), Color(0.3, 0.5, 0.95), Color(0.9, 0.85, 0.3)][t], 6)
				"petri_dish":
					s.cyl(Vector3.ZERO, 0.045, 0.045, 0.012, FirstPersonArt.M_PLAIN, Color(0.85, 0.92, 0.85), 10)
				"microscope":
					s.box(Vector3(-0.07, 0, -0.08), Vector3(0.07, 0.02, 0.08), FirstPersonArt.M_METAL, Color(0.85, 0.85, 0.82))
					s.box(Vector3(-0.02, 0.02, -0.07), Vector3(0.02, 0.22, -0.03), FirstPersonArt.M_METAL, Color(0.85, 0.85, 0.82))
					s.rbox(Vector3(0, 0.22, 0.0), Vector3(0.035, 0.16, 0.035), Basis(Vector3.RIGHT, 0.5), FirstPersonArt.M_METAL, BLACK)
		"tray":
			s.box(Vector3(-0.2, 0, -0.14), Vector3(0.2, 0.02, 0.14), FirstPersonArt.M_METAL, METAL)
		"shirt", "gloves", "boots":
			s.box(Vector3(-0.18, 0, -0.14), Vector3(0.18, 0.04, 0.14) if kind == "shirt" else Vector3(0.1, 0.08, 0.1), FirstPersonArt.M_FABRIC, c)
		"box", "first_aid", "ammunition", "toolbox", "suitcase", "backpack":
			var sz2: Vector3 = {"box": Vector3(0.3, 0.22, 0.25), "first_aid": Vector3(0.3, 0.12, 0.2),
					"ammunition": Vector3(0.3, 0.17, 0.16), "toolbox": Vector3(0.45, 0.2, 0.2),
					"suitcase": Vector3(0.5, 0.16, 0.36), "backpack": Vector3(0.32, 0.18, 0.42)}[kind]
			var m := FirstPersonArt.M_CARDBOARD if kind == "box" else (FirstPersonArt.M_FABRIC if kind == "backpack" else FirstPersonArt.M_PLASTIC)
			s.box(Vector3(-sz2.x * 0.5, 0, -sz2.z * 0.5), Vector3(sz2.x * 0.5, sz2.y, sz2.z * 0.5), m, c)
			if kind == "first_aid":
				s.box(Vector3(-0.06, sz2.y, -0.02), Vector3(0.06, sz2.y + 0.003, 0.02), FirstPersonArt.M_PLAIN, Color(0.85, 0.1, 0.1))
				s.box(Vector3(-0.02, sz2.y, -0.06), Vector3(0.02, sz2.y + 0.003, 0.06), FirstPersonArt.M_PLAIN, Color(0.85, 0.1, 0.1))
			if kind in ["toolbox", "suitcase"]:
				s.box(Vector3(-0.08, sz2.y, -0.015), Vector3(0.08, sz2.y + 0.03, 0.015), FirstPersonArt.M_PLASTIC, BLACK)
		"apple", "orange", "helmet", "hard_hat":
			var r2 := 0.04 if kind in ["apple", "orange"] else 0.14
			s.blob(Vector3(0, r2 * (0.9 if r2 < 0.1 else 0.0), 0), Vector3(r2, r2 * (0.9 if r2 < 0.1 else 0.75), r2), FirstPersonArt.M_PLASTIC, c, 3, 7, 4)
		"bread", "sandwich", "meat", "cheese", "vegetables", "milk_carton":
			var sz3: Vector3 = {"bread": Vector3(0.25, 0.1, 0.12), "sandwich": Vector3(0.12, 0.05, 0.12),
					"meat": Vector3(0.18, 0.05, 0.12), "cheese": Vector3(0.12, 0.06, 0.08),
					"vegetables": Vector3(0.18, 0.07, 0.14), "milk_carton": Vector3(0.07, 0.2, 0.07)}[kind]
			s.box(Vector3(-sz3.x * 0.5, 0, -sz3.z * 0.5), Vector3(sz3.x * 0.5, sz3.y, sz3.z * 0.5), FirstPersonArt.M_PLASTIC, c)
		"guitar", "violin":
			var gl := 0.95 if kind == "guitar" else 0.55
			s.box(Vector3(-gl * 0.5, 0, -gl * 0.18), Vector3(-gl * 0.02, 0.09 * gl, gl * 0.18), FirstPersonArt.M_WOOD, c)
			s.box(Vector3(-gl * 0.02, 0.02, -0.025), Vector3(gl * 0.5, 0.05, 0.025), FirstPersonArt.M_WOOD, WOOD_D)
		"rifle", "pistol", "drill", "fire_extinguisher", "stethoscope":
			match kind:
				"rifle":
					s.box(Vector3(-0.5, 0, -0.06), Vector3(-0.14, 0.065, 0.045), FirstPersonArt.M_WOOD, WOOD_D)
					s.box(Vector3(-0.15, 0.005, -0.045), Vector3(0.19, 0.085, 0.045), FirstPersonArt.M_METAL, METAL)
					s.box(Vector3(0.1, 0.0, -0.05), Vector3(0.28, 0.065, 0.05), FirstPersonArt.M_WOOD, WOOD_D)
					s.box(Vector3(-0.02, 0.01, 0.04), Vector3(0.07, 0.065, 0.18), FirstPersonArt.M_METAL, METAL_D)
					s.box(Vector3(-0.12, 0.01, 0.04), Vector3(-0.075, 0.055, 0.13), FirstPersonArt.M_WOOD, WOOD_D)
					s.xcyl(Vector3(0.19, 0.045, 0), 0.02, 0.31, FirstPersonArt.M_METAL, METAL_D, 6)
				"pistol", "drill":
					s.box(Vector3(-0.08, 0, -0.02), Vector3(0.1, 0.035, 0.02), FirstPersonArt.M_METAL, METAL_D if kind == "pistol" else c)
					s.box(Vector3(-0.08, 0, 0.02), Vector3(-0.03, 0.03, 0.1), FirstPersonArt.M_PLASTIC, BLACK)
				"fire_extinguisher":
					s.cyl(Vector3.ZERO, 0.07, 0.07, 0.45, FirstPersonArt.M_METAL, Color(0.8, 0.12, 0.1), 10)
					s.box(Vector3(-0.02, 0.45, -0.06), Vector3(0.02, 0.5, 0.04), FirstPersonArt.M_PLASTIC, BLACK)
				"stethoscope":
					s.cyl(Vector3.ZERO, 0.025, 0.025, 0.012, FirstPersonArt.M_CHROME, CHROME, 8)
					s.box(Vector3(-0.005, 0, 0.0), Vector3(0.005, 0.008, 0.25), FirstPersonArt.M_RUBBER, BLACK)
		_:
			s.box(Vector3(-0.07, 0, -0.07), Vector3(0.07, 0.07, 0.07), FirstPersonArt.M_PLASTIC, c)
	s.xf = keep
	s.shade_floor = true

# --- Vehicles and drones ------------------------------------------------------------------
# Built round their own centre on the floor, facing +x. All vehicles stand 2 m (owner).

static func vehicle(s: Sink, type: String, paint: Color, wrecked: bool) -> void:
	s.shade_floor = false
	match type:
		"tank": tank_hull(s, paint, wrecked)
		"shuttle": shuttle(s, paint, wrecked)
		"borg": borg(s, paint, wrecked)
		_: s.box(Vector3(-0.5, 0, -0.5), Vector3(0.5, 2.0, 0.5), FirstPersonArt.M_PLATE, paint)

## A tank's hull and tracks (the turret is its own part, so it can turn).
static func tank_hull(s: Sink, paint: Color, wrecked: bool) -> void:
	var c := Color(0.16, 0.15, 0.14) if wrecked else paint
	var track := Color(0.12, 0.12, 0.12)
	for side: float in [-1.0, 1.0]:
		var z0 := 0.85 * side
		var lo := Vector3(-1.45, 0.0, minf(z0, z0 + 0.6 * side))
		var hi := Vector3(1.45, 0.75, maxf(z0, z0 + 0.6 * side))
		s.box(lo, hi, FirstPersonArt.M_RUBBER, track)
		for k in 6:
			s.zcyl(Vector3(-1.2 + k * 0.48, 0.32, (hi.z if side > 0 else lo.z) - 0.01 * side - (0.02 if side > 0 else 0.0)), 0.26, 0.04, FirstPersonArt.M_METAL, METAL_D, 10)
		s.box(Vector3(-1.5, 0.75, lo.z - 0.02), Vector3(1.5, 0.82, hi.z + 0.02), FirstPersonArt.M_PLATE, c.darkened(0.15))
	s.box(Vector3(-1.4, 0.35, -0.85), Vector3(1.2, 1.15, 0.85), FirstPersonArt.M_PLATE, c)
	# A sloped glacis at the front.
	s.face([Vector3(1.2, 1.15, -0.85), Vector3(1.2, 1.15, 0.85), Vector3(1.5, 0.6, 0.85), Vector3(1.5, 0.6, -0.85)],
			Vector3(0.88, 0.48, 0), FirstPersonArt.M_PLATE, c.lightened(0.05))
	s.face([Vector3(1.2, 0.35, -0.85), Vector3(1.5, 0.6, -0.85), Vector3(1.2, 1.15, -0.85)], Vector3.FORWARD, FirstPersonArt.M_PLATE, c)
	s.face([Vector3(1.2, 0.35, 0.85), Vector3(1.5, 0.6, 0.85), Vector3(1.2, 1.15, 0.85)], Vector3.BACK, FirstPersonArt.M_PLATE, c)
	s.box(Vector3(-1.45, 0.9, -0.6), Vector3(-1.3, 1.1, 0.6), FirstPersonArt.M_GRILLE, METAL_D)
	if not wrecked:
		s.box(Vector3(1.38, 0.95, -0.7), Vector3(1.42, 1.0, -0.6), FirstPersonArt.M_PLAIN, glow(Color(1.0, 0.95, 0.8)))
		s.box(Vector3(1.38, 0.95, 0.6), Vector3(1.42, 1.0, 0.7), FirstPersonArt.M_PLAIN, glow(Color(1.0, 0.95, 0.8)))

static func tank_turret(s: Sink, paint: Color, wrecked: bool) -> void:
	var c := Color(0.14, 0.13, 0.12) if wrecked else paint.lightened(0.04)
	s.cyl(Vector3(0, 1.15, 0), 0.72, 0.62, 0.5, FirstPersonArt.M_PLATE, c, 10)
	s.box(Vector3(0.45, 1.25, -0.22), Vector3(0.75, 1.55, 0.22), FirstPersonArt.M_PLATE, c.darkened(0.1))
	s.xcyl(Vector3(0.75, 1.42, 0.0), 0.07, 1.8, FirstPersonArt.M_METAL, c.darkened(0.25), 8)
	s.xcyl(Vector3(2.35, 1.42, 0.0), 0.1, 0.2, FirstPersonArt.M_METAL, c.darkened(0.3), 8)
	s.cyl(Vector3(-0.2, 1.65, 0.25), 0.18, 0.18, 0.12, FirstPersonArt.M_PLATE, c.darkened(0.15), 8)
	s.cyl(Vector3(-0.35, 1.65, -0.35), 0.015, 0.015, 0.35, FirstPersonArt.M_METAL, METAL_D, 4, 0)

## A small space shuttle with four wheels, landing struts, a canopy and aft engines.
static func shuttle(s: Sink, paint: Color, wrecked: bool) -> void:
	var c := Color(0.16, 0.15, 0.14) if wrecked else paint.lerp(WHITE, 0.35)
	for z in [-0.75, 0.75]:
		for x in [-0.6, 0.6]:
			s.box(Vector3(x - 0.04, 0.2, z - 0.04), Vector3(x + 0.04, 0.5, z + 0.04), FirstPersonArt.M_METAL, METAL_D)
			s.zcyl(Vector3(x, 0.22, z + 0.12), 0.22, 0.24, FirstPersonArt.M_RUBBER, BLACK, 16)
			s.zcyl(Vector3(x, 0.22, z + 0.126), 0.105, 0.252, FirstPersonArt.M_METAL, METAL, 12)
	s.box(Vector3(-0.95, 0.4, -0.8), Vector3(0.75, 1.5, 0.8), FirstPersonArt.M_PLATE, c)
	s.face([Vector3(0.75, 1.5, -0.8), Vector3(0.75, 1.5, 0.8), Vector3(1.0, 1.0, 0.7), Vector3(1.0, 1.0, -0.7)], Vector3(0.9, 0.45, 0), FirstPersonArt.M_PLAIN,
			Color(0.1, 0.16, 0.24) if not wrecked else BLACK)
	s.face([Vector3(0.75, 0.4, -0.8), Vector3(1.0, 0.6, -0.7), Vector3(1.0, 1.0, -0.7), Vector3(0.75, 1.5, -0.8)], Vector3.FORWARD, FirstPersonArt.M_PLATE, c)
	s.face([Vector3(0.75, 0.4, 0.8), Vector3(1.0, 0.6, 0.7), Vector3(1.0, 1.0, 0.7), Vector3(0.75, 1.5, 0.8)], Vector3.BACK, FirstPersonArt.M_PLATE, c)
	s.face([Vector3(0.75, 0.4, -0.8), Vector3(0.75, 0.4, 0.8), Vector3(1.0, 0.6, 0.7), Vector3(1.0, 0.6, -0.7)], Vector3(0.6, -0.8, 0), FirstPersonArt.M_PLATE, c.darkened(0.2))
	s.face([Vector3(1.0, 0.6, -0.7), Vector3(1.0, 0.6, 0.7), Vector3(1.0, 1.0, 0.7), Vector3(1.0, 1.0, -0.7)], Vector3.RIGHT, FirstPersonArt.M_PLATE, c.darkened(0.1))
	s.box(Vector3(-0.5, 1.5, -0.04), Vector3(0.1, 2.0, 0.04), FirstPersonArt.M_PLATE, c.darkened(0.15))
	for z2 in [-0.45, 0.45]:
		s.xcyl(Vector3(-1.0, 0.85, z2), 0.22, 0.1, FirstPersonArt.M_METAL, METAL_D, 10)
		s.xcyl(Vector3(-1.02, 0.85, z2), 0.15, 0.02, FirstPersonArt.M_PLAIN, glow(Color(0.5, 0.8, 1.0)) if not wrecked else BLACK, 10)
	s.box(Vector3(-0.95, 0.9, -0.81), Vector3(0.6, 0.98, -0.8), FirstPersonArt.M_PLAIN, paint)
	s.box(Vector3(-0.95, 0.9, 0.8), Vector3(0.6, 0.98, 0.81), FirstPersonArt.M_PLAIN, paint)

## A borg: a one-seat walker — two legs, a cab with its window, two arms.
static func borg(s: Sink, paint: Color, wrecked: bool) -> void:
	var c := Color(0.16, 0.15, 0.14) if wrecked else paint
	for z in [-0.25, 0.25]:
		s.box(Vector3(-0.18, 0.0, z - 0.1), Vector3(0.22, 0.08, z + 0.1), FirstPersonArt.M_PLATE, METAL_D)
		s.box(Vector3(-0.08, 0.08, z - 0.07), Vector3(0.08, 0.55, z + 0.07), FirstPersonArt.M_PLATE, c.darkened(0.2))
		s.box(Vector3(-0.1, 0.5, z - 0.09), Vector3(0.1, 0.62, z + 0.09), FirstPersonArt.M_METAL, METAL_D)
		s.box(Vector3(-0.07, 0.62, z - 0.07), Vector3(0.07, 0.95, z + 0.07), FirstPersonArt.M_PLATE, c.darkened(0.2))
	s.box(Vector3(-0.38, 0.95, -0.4), Vector3(0.36, 1.85, 0.4), FirstPersonArt.M_PLATE, c)
	s.box(Vector3(-0.34, 1.85, -0.36), Vector3(0.3, 1.98, 0.36), FirstPersonArt.M_PLATE, c.darkened(0.15))
	s.box(Vector3(0.36, 1.35, -0.28), Vector3(0.38, 1.7, 0.28), FirstPersonArt.M_PLAIN, Color(0.12, 0.18, 0.26) if not wrecked else BLACK)
	for z2 in [-0.48, 0.48]:
		s.box(Vector3(-0.12, 1.3, z2 - 0.08), Vector3(0.12, 1.75, z2 + 0.08), FirstPersonArt.M_PLATE, c.darkened(0.1))
		s.box(Vector3(-0.05, 0.95, z2 - 0.06), Vector3(0.35, 1.3, z2 + 0.06), FirstPersonArt.M_PLATE, c.darkened(0.25))
	if not wrecked:
		s.box(Vector3(0.37, 1.78, -0.05), Vector3(0.39, 1.82, 0.05), FirstPersonArt.M_PLAIN, glow(Color(1.0, 0.4, 0.2)))

## A quadcopter drone in its side's colour: body, four arms and rotors, a lit band; the
## scout carries a camera lens.
static func drone(s: Sink, paint: Color, scout: bool) -> void:
	s.box(Vector3(-0.13, -0.06, -0.13), Vector3(0.13, 0.06, 0.13), FirstPersonArt.M_PLATE, paint)
	s.box(Vector3(-0.135, -0.015, -0.135), Vector3(0.135, 0.015, 0.135), FirstPersonArt.M_PLAIN, glow(paint.lightened(0.4)))
	for k in 4:
		var a := PI / 4 + k * PI / 2
		var d := Vector3(cos(a), 0, sin(a))
		s.rbox(d * 0.2, Vector3(0.22, 0.025, 0.04), Basis(Vector3.UP, -a), FirstPersonArt.M_METAL, METAL_D)
		s.cyl(d * 0.3 + Vector3(0, 0.0, 0), 0.03, 0.03, 0.05, FirstPersonArt.M_METAL, METAL_D, 6)
		s.cyl(d * 0.3 + Vector3(0, 0.05, 0), 0.14, 0.14, 0.006, FirstPersonArt.M_PLAIN, Color(0.15, 0.15, 0.16, 1.0), 10)
	if scout:
		s.xcyl(Vector3(0.13, -0.05, 0.0), 0.05, 0.06, FirstPersonArt.M_PLAIN, BLACK, 8)
		s.xcyl(Vector3(0.19, -0.05, 0.0), 0.035, 0.005, FirstPersonArt.M_PLAIN, glow(Color(0.5, 0.8, 1.0)), 8)
	else:
		s.box(Vector3(-0.08, -0.14, -0.06), Vector3(0.08, -0.06, 0.06), FirstPersonArt.M_PLATE, Color(0.3, 0.33, 0.22))
