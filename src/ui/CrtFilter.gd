class_name CrtFilter
extends CanvasLayer

## Optional CRT-terminal look over the whole game (issues-12 #21, Settings → Display): scanlines,
## an RGB aperture grille, a touch of colour fringing, rounded dark corners like a tube's bezel
## and a faint flicker. The picture is not bent: a curved image would put every click a few
## pixels away from what it shows.
const SHADER := """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen : hint_screen_texture, filter_linear, repeat_disable;
// Settings → Display (issues-13 #5): 0 is the plain picture, 1 the full tube.
uniform float strength = 1.0;
// Chromatic aberration (issues-14 #4): red and blue drift apart from the middle out, a little
// always and more for a moment after a blast or while fire burns near you (0..1).
uniform float shock = 0.0;
void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - 0.5;
	vec2 fringe = c * (0.004 + 0.014 * shock) + vec2(0.0007 + 0.0015 * shock, 0.0);
	vec3 col = vec3(texture(screen, uv + fringe).r, texture(screen, uv).g,
			texture(screen, uv - fringe).b);
	// About 300 lines down the screen whatever the window size, like a terminal tube.
	float rows = max(2.0, (1.0 / SCREEN_PIXEL_SIZE.y) / 300.0);
	float line = 0.5 + 0.5 * cos(FRAGCOORD.y / rows * 6.2831853);
	col *= mix(0.68, 1.0, line);
	int m = int(mod(FRAGCOORD.x, 3.0));
	vec3 grille = vec3(0.88);
	grille[m] = 1.1;
	col *= grille * 1.16;
	col *= 0.992 + 0.008 * sin(TIME * 57.0);
	// Rounded tube corners: a rounded rectangle in pixels, fading out at its edge.
	vec2 half_px = 0.5 / SCREEN_PIXEL_SIZE;
	float r = 0.12 * half_px.y;
	vec2 q = abs(c) / SCREEN_PIXEL_SIZE - (half_px - vec2(r));
	float edge = length(max(q, 0.0)) - r;
	float vig = smoothstep(0.0, -0.45 * r, edge) * (1.0 - 0.55 * dot(c, c));
	COLOR = vec4(mix(texture(screen, uv).rgb, col * vig, strength), 1.0);
}
"""

func _ready() -> void:
	layer = 128
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	mat.shader = shader
	rect.material = mat
	add_child(rect)
	set_strength(Ui.crt_strength)

## How shaken the picture is: what the battle asks for now (Ui.crt_shock), eased so a blast
## flares quickly and fades.
var want := 0.0
var _shock := 0.0
func _process(delta: float) -> void:
	_shock = move_toward(_shock, want, delta * (6.0 if want > _shock else 1.5))
	want = 0.0
	((get_child(0) as ColorRect).material as ShaderMaterial).set_shader_parameter("shock", _shock)

func set_strength(v: float) -> void:
	((get_child(0) as ColorRect).material as ShaderMaterial).set_shader_parameter("strength", v)
