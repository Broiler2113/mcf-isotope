class_name FirstPersonFog
extends MeshInstance3D

## A visible boundary for cells the viewer cannot enter. The mist is opaque and
## world-aligned: it cannot reveal unknown terrain or shimmer with camera motion.
const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;
uniform sampler2D mist : filter_linear_mipmap, repeat_enable;
uniform float render_radius = 160.0;
varying highp vec3 world;
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	if (distance(world.xz, INV_VIEW_MATRIX[3].xz) > render_radius) discard;
	// Smooth (fix-12): broad, low-contrast swells instead of black-and-gray smoke blotches.
	vec2 uv = vec2(world.x + world.z, world.y);
	float broad = texture(mist, uv * 0.028).r;
	float fine = texture(mist, uv * 0.07 + vec2(0.31, 0.73)).r;
	float cloud = smoothstep(0.1, 0.9, broad * 0.8 + fine * 0.2);
	ALBEDO = mix(vec3(0.095, 0.11, 0.135), vec3(0.165, 0.185, 0.22), cloud);
}
"""
static var _mist: ImageTexture
# Offset into unknown cells to avoid z-fighting with their walls. Extend the ends
# by slightly more than that offset so perpendicular/diagonal joins stay sealed.
const EDGE_OFFSET := 0.015
const EDGE_OVERLAP := 0.02
var _source := PackedByteArray()
var _known := PackedByteArray()
var _size := Vector2i.ZERO
var boundary_count := 0

func _init() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	if _mist == null:
		var noise := FastNoiseLite.new()
		noise.seed = 17391
		noise.frequency = 0.035
		noise.fractal_octaves = 3
		var picture := noise.get_seamless_image(128, 128)
		picture.generate_mipmaps()
		_mist = ImageTexture.create_from_image(picture)
	material.set_shader_parameter("mist", _mist)
	material_override = material

func set_view(at: Vector3, distance: float) -> void:
	# Keep the top/bottom outside a walker's view, including noclip at altitude.
	position.y = floorf(at.y / 128.0) * 128.0
	material_override.set_shader_parameter("render_radius", distance)

func update_visibility(picture: Image) -> bool:
	var source := picture.get_data()
	if _size == picture.get_size() and source == _source: return false
	_source = source
	var known := PackedByteArray()
	known.resize(source.size())
	for i in source.size(): known[i] = 1 if source[i] > 51 else 0
	if _size == picture.get_size() and known == _known: return false
	_known = known
	_size = picture.get_size()
	var vertices := PackedVector3Array()
	boundary_count = 0
	# Merge consecutive edges, so an entire unexplored district can be covered
	# by a few quads rather than a separate object for every boundary cell.
	for x in range(1, _size.x):
		var start := 0
		var direction := 0
		for y in _size.y + 1:
			var next := int(known[y * _size.x + x - 1]) - int(known[y * _size.x + x]) if y < _size.y else 0
			if next == direction: continue
			if direction != 0:
				_quad(vertices, Vector2(x + direction * EDGE_OFFSET, start), Vector2(x + direction * EDGE_OFFSET, y))
			start = y
			direction = next
	for y in range(1, _size.y):
		var start := 0
		var direction := 0
		for x in _size.x + 1:
			var next := int(known[(y - 1) * _size.x + x]) - int(known[y * _size.x + x]) if x < _size.x else 0
			if next == direction: continue
			if direction != 0:
				_quad(vertices, Vector2(start, y + direction * EDGE_OFFSET), Vector2(x, y + direction * EDGE_OFFSET))
			start = x
			direction = next
	if vertices.is_empty():
		mesh = null
		return true
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = result
	return true

func _quad(vertices: PackedVector3Array, a: Vector2, b: Vector2) -> void:
	var overlap := (b - a).normalized() * EDGE_OVERLAP
	a -= overlap
	b += overlap
	vertices.append_array(PackedVector3Array([
		Vector3(a.x, -256, a.y), Vector3(b.x, -256, b.y), Vector3(b.x, 256, b.y),
		Vector3(a.x, -256, a.y), Vector3(b.x, 256, b.y), Vector3(a.x, 256, a.y)]))
	boundary_count += 1

## Fog beyond the map's edges on open-air maps (fix-12 #7): the ground past the edge fades into
## mist over FADE metres, where a curtain of mist stands and thins upward into the sky. Both
## are fully fogged where they meet, so no seam shows. Tinted to the horizon (set_bank_tint).
const BANK_SHADER = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
uniform sampler2D mist : filter_linear_mipmap, repeat_enable;
uniform vec3 tint : source_color = vec3(0.68, 0.78, 0.9);
uniform vec2 board = vec2(32.0, 32.0);
uniform float fade = 12.0;
uniform float top = 14.0;
varying highp vec3 world;
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 out_by = max(-world.xz, world.xz - board);
	float d = length(max(out_by, vec2(0.0)));
	float n = texture(mist, vec2(world.x + world.z, world.y) * 0.02 + vec2(TIME * 0.004, 0.0)).r;
	ALBEDO = tint * (0.97 + 0.06 * n);
	float ground = smoothstep(0.0, fade, d) * step(world.y, 0.05);
	float curtain = (1.0 - smoothstep(0.0, top, world.y)) * step(fade - 0.1, d);
	ALPHA = max(ground, curtain);
}
"""
const BANK_FADE := 12.0

static func bounds_bank(w: float, h: float) -> MeshInstance3D:
	if _mist == null: FirstPersonFog.new().free()   # builds the shared mist picture
	var v := PackedVector3Array()
	# The mist carpet: a ring of ground round the board, never under it (trenches are pits).
	var r := 800.0
	for q: Rect2 in [Rect2(-r, -r, w + 2 * r, r), Rect2(-r, h, w + 2 * r, r), Rect2(-r, 0, r, h), Rect2(w, 0, r, h)]:
		var y := 0.005
		v.append_array(PackedVector3Array([Vector3(q.position.x, y, q.position.y), Vector3(q.end.x, y, q.position.y),
				Vector3(q.end.x, y, q.end.y), Vector3(q.position.x, y, q.position.y), Vector3(q.end.x, y, q.end.y),
				Vector3(q.position.x, y, q.end.y)]))
	# The curtain where the ground has gone fully to mist.
	var o := BANK_FADE
	var corners := [Vector2(-o, -o), Vector2(w + o, -o), Vector2(w + o, h + o), Vector2(-o, h + o)]
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		v.append_array(PackedVector3Array([Vector3(a.x, 0, a.y), Vector3(b.x, 0, b.y), Vector3(b.x, 16, b.y),
				Vector3(a.x, 0, a.y), Vector3(b.x, 16, b.y), Vector3(a.x, 16, a.y)]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = BANK_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("mist", _mist)
	mat.set_shader_parameter("board", Vector2(w, h))
	mat.set_shader_parameter("fade", BANK_FADE)
	mi.material_override = mat
	return mi

static func set_bank_tint(bank: MeshInstance3D, tint: Color) -> void:
	(bank.material_override as ShaderMaterial).set_shader_parameter("tint", tint)
