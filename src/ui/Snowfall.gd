class_name Snowfall
extends Control

## Snow drifting over a winter map (owner, fix-8 #3): a few hundred flakes in screen space,
## near ones bigger and faster, each swaying on its own; they slide with the camera a
## little, so the board doesn't seem to drag them along. Settings → Display switches it off.

const COUNT := 260
var _flakes: Array[Vector4] = []   # x, y, depth 0..1, phase
var _last_pan := Vector2.INF
var pan := Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in COUNT:
		_flakes.append(Vector4(rng.randf(), rng.randf(), rng.randf(), rng.randf() * TAU))

func _process(delta: float) -> void:
	visible = Ui.snowfall
	if not visible:
		return
	var sz := size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	var moved := Vector2.ZERO if _last_pan == Vector2.INF else pan - _last_pan
	_last_pan = pan
	var t := Time.get_ticks_msec() * 0.001
	for i in _flakes.size():
		var f := _flakes[i]
		var near := 0.35 + 0.65 * f.z
		var y := f.y + delta * (0.05 + 0.09 * near)
		var x := f.x + delta * 0.012 * sin(t * (0.6 + f.z) + f.w) + moved.x * near * 0.35 / sz.x
		y += moved.y * near * 0.35 / sz.y
		_flakes[i] = Vector4(fposmod(x, 1.0), fposmod(y, 1.0), f.z, f.w)
	queue_redraw()

func _draw() -> void:
	for f: Vector4 in _flakes:
		var r := 1.0 + 2.2 * f.z
		var a := 0.45 + 0.45 * f.z
		draw_rect(Rect2(Vector2(f.x * size.x, f.y * size.y), Vector2(r, r)), Color(1, 1, 1, a))
