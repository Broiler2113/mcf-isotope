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
void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - 0.5;
	float fringe = 0.0009 + 0.0016 * dot(c, c);
	vec3 col = vec3(texture(screen, uv + vec2(fringe, 0.0)).r, texture(screen, uv).g,
			texture(screen, uv - vec2(fringe, 0.0)).b);
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
	COLOR = vec4(col * vig, 1.0);
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
