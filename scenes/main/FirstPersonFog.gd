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
	vec2 uv = vec2(world.x + world.z, world.y);
	float broad = texture(mist, uv * 0.065).r;
	float fine = texture(mist, uv * 0.19 + vec2(0.31, 0.73)).r;
	float cloud = smoothstep(0.15, 0.85, broad * 0.75 + fine * 0.25);
	ALBEDO = mix(vec3(0.035, 0.045, 0.06), vec3(0.19, 0.22, 0.26), cloud);
}
"""
static var _mist: ImageTexture
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
				_quad(vertices, Vector2(x + direction * 0.015, start), Vector2(x + direction * 0.015, y))
			start = y
			direction = next
	for y in range(1, _size.y):
		var start := 0
		var direction := 0
		for x in _size.x + 1:
			var next := int(known[(y - 1) * _size.x + x]) - int(known[y * _size.x + x]) if x < _size.x else 0
			if next == direction: continue
			if direction != 0:
				_quad(vertices, Vector2(start, y + direction * 0.015), Vector2(x, y + direction * 0.015))
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
	vertices.append_array(PackedVector3Array([
		Vector3(a.x, -256, a.y), Vector3(b.x, -256, b.y), Vector3(b.x, 256, b.y),
		Vector3(a.x, -256, a.y), Vector3(b.x, 256, b.y), Vector3(a.x, 256, a.y)]))
	boundary_count += 1
