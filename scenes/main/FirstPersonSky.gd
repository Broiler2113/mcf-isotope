class_name FirstPersonSky
extends RefCounted

## Skies for first person (issues-12 #19, #20). One sky shader, two kinds:
## - space (station, asteroid): the star field, the Sun — a white-hot disc with a soft glow —
##   and the Earth far off, a lit globe with oceans, land, ice, clouds and a blue rim of air;
## - surface (town, field): the time of day's gradient, the Sun, and clouds drifting slowly
##   overhead; overcast turns them into one grey deck and hides the Sun.
## Directions are fixed per map, so every player sees the same sky.

## Space: the Sun high and to one side, the Earth low on the other, seen two-thirds lit.
const SPACE_SUN := Vector3(0.6, 0.45, -0.66)
const SPACE_EARTH := Vector3(-0.85, 0.24, 0.3)
const EARTH_MAP := "res://textures/first_person/earth.jpg"
const EARTH_RADIUS := 0.3   # radians across the sky: a planet seen from a low orbit
## The Sun to scale (fix-12 #13): 0.53 degrees across, as seen from the Earth.
const SUN_RADIUS := 0.00465

const SHADER := """
shader_type sky;
uniform int kind = 0;                 // 0 space, 1 surface
uniform sampler2D stars : filter_linear, repeat_enable;
uniform float stars_k = 1.0;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_col : source_color = vec3(1.0);
uniform float sun_size = 0.012;
uniform float sun_k = 1.0;
uniform vec3 earth_dir = vec3(1.0, 0.0, 0.0);
uniform float earth_r = 0.3;
// The real globe (fix-12 #8): NASA Blue Marble, equirectangular, public domain.
uniform sampler2D earth_map : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_map = false;
uniform vec3 zenith : source_color = vec3(0.28, 0.48, 0.82);
uniform vec3 horizon : source_color = vec3(0.68, 0.78, 0.9);
uniform vec3 ground : source_color = vec3(0.05);
uniform float cover = 0.45;
uniform vec3 cloud_lit : source_color = vec3(1.0);
uniform vec3 cloud_dark : source_color = vec3(0.6, 0.64, 0.7);
// Overcast (issues-14 #5): one smooth deck — broad soft swells, no streaks, plain toward the
// horizon — instead of a sky full of packed clouds.
uniform float soft = 0.0;

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float noise3(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x), mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x), mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm(vec3 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 5; i++) {
		s += a * noise3(p);
		p = p * 2.03 + vec3(1.7, 9.2, 3.1);
		a *= 0.5;
	}
	return s;
}

float fbm_soft(vec3 p) {
	return noise3(p) * 0.62 + noise3(p * 2.1 + vec3(3.1, 7.7, 1.3)) * 0.26 + noise3(p * 4.3 + vec3(9.2)) * 0.12;
}

vec3 star_field(vec3 d) {
	vec2 uv = vec2(atan(d.x, -d.z) / 6.2831853 + 0.5, acos(clamp(d.y, -1.0, 1.0)) / 3.1415927);
	return texture(stars, uv).rgb * stars_k;
}

vec3 sun_disc(vec3 d, vec3 base) {
	float c = dot(d, normalize(sun_dir));
	float disc = smoothstep(cos(sun_size), cos(sun_size * 0.85), c);
	float glow = pow(max(c, 0.0), 40000.0) * 1.5 + pow(max(c, 0.0), 1500.0) * 0.35 + pow(max(c, 0.0), 60.0) * 0.08;
	return base + sun_col * (disc * 6.0 + glow) * sun_k;
}

vec3 earth(vec3 d, vec3 base) {
	vec3 e = normalize(earth_dir);
	float a = acos(clamp(dot(d, e), -1.0, 1.0));
	vec3 s = normalize(sun_dir);
	if (a > earth_r) {
		// The thin air beyond the limb, on the lit side.
		float halo = exp(-(a - earth_r) * 38.0);
		vec3 limb = normalize(d - e * dot(d, e));
		float lit = clamp(dot(limb, s) * 0.7 + 0.35, 0.0, 1.0);
		return base + vec3(0.25, 0.5, 1.0) * halo * lit * 0.8;
	}
	vec3 t1 = normalize(cross(e, vec3(0.0, 1.0, 0.0)));
	vec3 t2 = cross(t1, e);
	vec2 p = vec2(dot(d, t1), dot(d, t2)) / sin(earth_r);
	float r2 = min(dot(p, p), 1.0);
	vec3 n = normalize(p.x * t1 + p.y * t2 - sqrt(1.0 - r2) * e);
	// The globe turns slowly about its own axis.
	float spin = TIME * 0.004;
	vec3 q = vec3(n.x * cos(spin) - n.z * sin(spin), n.y, n.x * sin(spin) + n.z * cos(spin));
	float land = fbm(q * 2.6 + vec3(4.0));
	float ice = smoothstep(0.78, 0.86, abs(q.y) + (land - 0.5) * 0.15);
	vec3 col = mix(vec3(0.03, 0.09, 0.26), vec3(0.05, 0.16, 0.36), fbm(q * 9.0));
	if (land > 0.53) {
		float dry = fbm(q * 5.0 + vec3(9.0));
		col = mix(vec3(0.1, 0.22, 0.08), vec3(0.42, 0.36, 0.22), smoothstep(0.45, 0.65, dry));
	}
	col = mix(col, vec3(0.92, 0.95, 1.0), ice);
	if (has_map) {
		vec2 uv = vec2(atan(q.x, -q.z) / 6.2831853 + 0.5, acos(clamp(q.y, -1.0, 1.0)) / 3.1415927);
		// One fixed detail level (fix-13 #6): where the longitude wraps and at the poles the
		// screen derivatives jump, and an automatic level drew a thin dark seam across the globe.
		col = textureLod(earth_map, uv, 1.0).rgb;
		// Land is wherever the map is not deep-sea blue; ice is near-white.
		land = 1.0 - smoothstep(0.02, 0.08, col.b - max(col.r, col.g));
		land = land * 0.6;   // as the 0.53 threshold below reads it: land ~0.6, sea 0
		ice = smoothstep(0.55, 0.75, min(col.r, min(col.g, col.b)));
	}
	float cl = smoothstep(0.5, 0.75, fbm(q * 4.0 + vec3(TIME * 0.002, 0.0, 0.0)));
	col = mix(col, vec3(0.95), cl * 0.85);
	float light = smoothstep(-0.12, 0.3, dot(n, s));
	float view = clamp(dot(n, -e), 0.0, 1.0);
	vec3 day = col * (0.15 + 0.95 * light);
	// No city lights on the night side (owner, fix-13 #6: they read as stray yellow dots).
	vec3 rim = vec3(0.3, 0.55, 1.0) * pow(1.0 - view, 3.0) * (0.15 + light) * 1.1;
	// The globe's edge is soft by a pixel or two, not cut out.
	float edge = smoothstep(earth_r, earth_r - 0.004, a);
	return mix(base, day + rim, edge);
}

vec3 surface(vec3 d) {
	float up = d.y;
	vec3 col = up < 0.0 ? mix(horizon, ground, smoothstep(0.0, 0.25, -up))
			: mix(horizon, zenith, pow(smoothstep(0.0, 1.0, up), 0.6));
	col += star_field(d) * smoothstep(0.0, 0.2, up);
	col = sun_disc(d, col);
	if (up > 0.0 && soft > 0.5) {
		vec2 uv = d.xz / (up + 0.35) * 0.55 + vec2(TIME * 0.004, TIME * 0.0015);
		float n = fbm_soft(vec3(uv, TIME * 0.002));
		vec3 deck = mix(cloud_dark, cloud_lit, smoothstep(0.25, 0.75, n));
		deck = mix(horizon, deck, smoothstep(0.02, 0.4, up));
		return mix(col, deck, smoothstep(0.0, 0.08, up));
	}
	if (up > 0.0) {
		vec2 uv = d.xz / (up + 0.12) * 1.4 + vec2(TIME * 0.006, TIME * 0.002);
		float n = fbm(vec3(uv, TIME * 0.003));
		float c = smoothstep(1.0 - cover - 0.12, 1.0 - cover + 0.22, n) * smoothstep(0.0, 0.18, up);
		float n2 = fbm(vec3(uv + normalize(sun_dir).xz * 0.06, TIME * 0.003));
		float lit = clamp(0.55 + (n - n2) * 5.0, 0.0, 1.0);
		vec3 cc = mix(cloud_dark, cloud_lit, lit);
		// Silver edges round the sun.
		cc += sun_col * pow(max(dot(d, normalize(sun_dir)), 0.0), 24.0) * (1.0 - c) * 0.6 * sun_k;
		col = mix(col, cc, c);
	}
	return col;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	if (kind == 0) {
		vec3 col = star_field(d);
		col = sun_disc(d, col);
		COLOR = earth(d, col);
	} else {
		COLOR = surface(d);
	}
}
"""

static var _shader: Shader = null
static var _earth: Texture2D = null

static func _material() -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var m := ShaderMaterial.new()
	m.shader = _shader
	return m

static func space(stars: Texture2D) -> ShaderMaterial:
	var m := _material()
	m.set_shader_parameter("kind", 0)
	m.set_shader_parameter("stars", stars)
	m.set_shader_parameter("sun_dir", SPACE_SUN.normalized())
	m.set_shader_parameter("sun_col", Color(1.0, 0.97, 0.9))
	m.set_shader_parameter("sun_size", SUN_RADIUS)
	m.set_shader_parameter("earth_dir", SPACE_EARTH.normalized())
	m.set_shader_parameter("earth_r", EARTH_RADIUS)
	# Read from source like the other new art: a stale import cache lacks it (no preload).
	if _earth == null:
		var map := Sprites.image_at(EARTH_MAP)
		if map != null:
			map.generate_mipmaps()
			_earth = ImageTexture.create_from_image(map)
	if _earth != null:
		m.set_shader_parameter("earth_map", _earth)
		m.set_shader_parameter("has_map", true)
	return m

## The surface sky for a time of day. sun_dir points at the sun (the DirectionalLight's back).
static func surface(stars: Texture2D, tod: String, overcast: bool, sun_dir: Vector3) -> ShaderMaterial:
	var night := tod in ["night", ""]
	var dusk := tod in ["morning", "evening"]
	var m := _material()
	m.set_shader_parameter("kind", 1)
	m.set_shader_parameter("stars", stars)
	m.set_shader_parameter("stars_k", 0.0 if not night or overcast else 1.0)
	m.set_shader_parameter("sun_dir", sun_dir.normalized())
	m.set_shader_parameter("sun_k", 0.0 if night or overcast else 1.0)
	m.set_shader_parameter("sun_col", Color(1.0, 0.72, 0.45) if dusk else Color(1.0, 0.96, 0.88))
	m.set_shader_parameter("sun_size", SUN_RADIUS)
	var zenith := Color(0.01, 0.012, 0.03) if night else (Color(0.32, 0.42, 0.66) if dusk else Color(0.28, 0.48, 0.82))
	var horizon := Color(0.03, 0.035, 0.06) if night else (Color(0.95, 0.66, 0.45) if dusk else Color(0.68, 0.78, 0.9))
	var lit := Color(0.12, 0.13, 0.17) if night else (Color(1.0, 0.82, 0.68) if dusk else Color(1.0, 1.0, 1.0))
	var dark := Color(0.04, 0.045, 0.06) if night else (Color(0.42, 0.36, 0.42) if dusk else Color(0.62, 0.66, 0.74))
	if overcast:
		var grey := 0.05 if night else (0.42 if dusk else 0.6)
		zenith = Color(grey * 0.92, grey * 0.95, grey)
		horizon = Color(grey * 1.12, grey * 1.13, grey * 1.15)
		lit = Color(grey * 1.25, grey * 1.26, grey * 1.3)
		dark = Color(grey * 0.72, grey * 0.74, grey * 0.8)
	m.set_shader_parameter("zenith", zenith)
	m.set_shader_parameter("horizon", horizon)
	m.set_shader_parameter("ground", Color(0.05, 0.05, 0.05))
	m.set_shader_parameter("cover", 0.97 if overcast else (0.38 if not night else 0.3))
	m.set_shader_parameter("soft", 1.0 if overcast else 0.0)
	m.set_shader_parameter("cloud_lit", lit)
	m.set_shader_parameter("cloud_dark", dark)
	return m

## The horizon colour the surface sky fades the far ground into.
static func horizon_colour(tod: String, overcast: bool) -> Color:
	var night := tod in ["night", ""]
	var dusk := tod in ["morning", "evening"]
	if overcast:
		var g := 0.05 if night else (0.42 if dusk else 0.6)
		return Color(g * 1.12, g * 1.13, g * 1.15)
	return Color(0.03, 0.035, 0.06) if night else (Color(0.95, 0.66, 0.45) if dusk else Color(0.68, 0.78, 0.9))

## Lens flare over the first-person view in space (issues-12 #19): a glare and a star streak on
## the Sun, and ghosts strung through the middle of the screen, growing as you look into it.
## strength (0..1, eased by FirstPerson) is how much of the Sun is in sight.
class LensFlare extends Control:
	var sun := Vector2.ZERO
	var on_screen := false
	var strength := 0.0
	static var _soft: Texture2D = null
	static var _ring: Texture2D = null
	const GHOSTS := [[0.45, 0.05, Color(1.0, 0.7, 0.4)], [0.75, 0.11, Color(0.5, 1.0, 0.6)], [1.1, 0.03, Color(1.0, 1.0, 0.9)],
			[1.4, 0.08, Color(0.5, 0.6, 1.0)], [1.85, 0.17, Color(0.8, 0.5, 1.0)], [2.25, 0.06, Color(1.0, 0.55, 0.35)]]

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)   # before entering the tree, like the crosshair

	func _ready() -> void:
		var add := CanvasItemMaterial.new()
		add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = add
		if _soft == null:
			_soft = _radial([[0.0, Color(1, 1, 1, 1)], [0.35, Color(1, 1, 1, 0.35)], [1.0, Color(1, 1, 1, 0)]])
			_ring = _radial([[0.0, Color(1, 1, 1, 0)], [0.72, Color(1, 1, 1, 0)], [0.86, Color(1, 1, 1, 0.8)], [1.0, Color(1, 1, 1, 0)]])

	static func _radial(stops: Array) -> Texture2D:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array(stops.map(func(s: Array) -> float: return s[0]))
		g.colors = PackedColorArray(stops.map(func(s: Array) -> Color: return s[1]))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 128
		t.height = 128
		return t

	func _draw() -> void:
		if strength <= 0.002 or not on_screen: return
		var h := size.y
		var mid := size * 0.5
		# Looking straight at it, the ghosts and the streak are at their strongest.
		var centred := clampf(1.0 - (sun - mid).length() / (size.length() * 0.5), 0.0, 1.0)
		var k := strength * centred * centred
		_blob(_soft, sun, h * 0.42, Color(1.0, 0.95, 0.85, 0.45 * strength))
		_blob(_soft, sun, h * 0.025, Color(1.0, 1.0, 1.0, 0.8 * strength))   # fix-12 #13: Sun to scale
		draw_texture_rect(_soft, Rect2(sun - Vector2(size.x * 0.55, h * 0.012), Vector2(size.x * 1.1, h * 0.024)), false,
				Color(0.8, 0.88, 1.0, 0.55 * k))
		var axis := mid - sun
		for g: Array in GHOSTS:
			var at: Vector2 = sun + axis * float(g[0])
			var c: Color = g[2]
			_blob(_ring if float(g[1]) > 0.1 else _soft, at, h * float(g[1]), Color(c.r, c.g, c.b, 0.22 * k))

	func _blob(tex: Texture2D, at: Vector2, r: float, c: Color) -> void:
		draw_texture_rect(tex, Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), false, c)
