extends SceneTree

## Far-map decal updates must preserve every pixel and leave simulation/FX data alone.
## -- --bench measures adding one decal after a long match; timings are informational.

var MainScript: Script
var fails: PackedStringArray = []

func ck(ok: bool, message: String) -> void:
	if not ok:
		fails.append(message)

func _initialize() -> void:
	# Load after the project's Ui autoload has been registered.
	MainScript = load("res://scenes/Main.gd")
	_updates_match_reference()
	if "--bench" in OS.get_cmdline_user_args():
		_bench()
	for message in fails:
		printerr("FAIL " + message)
	if fails.is_empty():
		print("decal sync: incremental, mixed-list, reset and off-board updates are pixel-identical; content and state preserved")
	quit(0 if fails.is_empty() else 1)

func _particle(kind: String, pos: Vector2, scale: float = 1.0) -> Dictionary:
	return {"kind": kind, "pos": pos, "rot": 0.3, "scale": scale}

func _main() -> Node:
	var main = MainScript.new()
	main.state = GameState.new(8, 6, 9603)
	main._lod = MainScript.LodLayer.new()
	main._lod_terrain = Image.create(8, 6, false, Image.FORMAT_RGBA8)
	main._lod_terrain.fill(Color(0.14, 0.15, 0.18, 1.0))
	main._lod_decal_reset = main._fx.decal_reset
	return main

## Original full traversal. The flattened gore/props order is deliberately preserved.
func _reference(img: Image, fx: FxDecals, done: int, grid: Grid) -> void:
	var i := 0
	for list: Array in [fx.gore, fx.props]:
		for p: Dictionary in list:
			i += 1
			if i <= done:
				continue
			var pos: Vector2 = p["pos"]
			var c := Vector2i(floori(pos.x), floori(pos.y))
			if not grid.in_bounds(c):
				continue
			var look: Array = FxDecals.LOOK.get(str(p["kind"]), [])
			if look.is_empty():
				continue
			var col: Color = look[1]
			var cover: float = clampf(float(look[0]) * float(p["scale"]), 0.08, 1.0) * col.a
			img.set_pixel(c.x, c.y, img.get_pixel(c.x, c.y).lerp(col, cover))

func _check_update(main: Node, label: String, reset: bool = false) -> void:
	var done: int = main._lod_decal_done
	if reset:
		main._fx.decal_reset += 1
		main._lod_build_terrain()
		done = 0
	var expected: Image = main._lod_terrain.duplicate()
	var state_before: int = main.state.digest_hash()
	var fx_before := JSON.stringify(main._fx.to_dict())
	_reference(expected, main._fx, done, main.state.grid)
	main._lod_sync_decals(main.state.grid)
	ck(main._lod_terrain.get_data() == expected.get_data(), label + ": pixels changed")
	ck(main.state.digest_hash() == state_before, label + ": simulation changed")
	ck(JSON.stringify(main._fx.to_dict()) == fx_before, label + ": cosmetic content changed")
	ck(main._lod_decal_done == main._fx.gore.size() + main._fx.props.size(),
			label + ": consumed count changed")

func _updates_match_reference() -> void:
	var main := _main()
	_check_update(main, "empty")
	main._fx.gore.append(_particle("blood_drop", Vector2(2.3, 3.2)))
	main._fx.gore.append(_particle("blood_pool", Vector2(2.1, 3.7), 0.7))
	_check_update(main, "gore only")
	main._fx.props.append(_particle("casing", Vector2(2.4, 3.8)))
	main._fx.props.append(_particle("shard", Vector2(4.5, 1.8)))
	_check_update(main, "props appended")
	_check_update(main, "idle")
	main._fx.gore.append(_particle("gib", Vector2(2.6, 3.9)))
	main._fx.props.append(_particle("shell_casing", Vector2(5.4, 2.5)))
	_check_update(main, "both lists grew")
	main._fx.props.append(_particle("shard", Vector2(-0.1, 1.0)))
	main._fx.props.append(_particle("casing", Vector2(8.0, 6.0)))
	main._fx.props.append(_particle("unknown", Vector2(1.0, 1.0)))
	_check_update(main, "off-board and unsupported")
	main._fx.props.pop_front()
	_check_update(main, "eviction", true)
	main._fx.gore.clear()
	main._fx.props.clear()
	_check_update(main, "replay reset", true)
	main._fx.props.append(_particle("shard", Vector2(1.1, 1.1)))
	_check_update(main, "after reset")
	main._lod.free()
	main.free()

func _bench() -> void:
	var main := _main()
	for i in 60000:
		main._fx.gore.append(_particle("blood_drop", Vector2(2.3, 3.2)))
	for i in 8000:
		main._fx.props.append(_particle("casing", Vector2(4.3, 2.2)))
	var done := 68000
	main._fx.props.append(_particle("shard", Vector2(5.1, 4.5)))
	var reference: Image = main._lod_terrain.duplicate()
	var old_us := 1 << 60
	var new_us := 1 << 60
	for repetition in 5:
		var t := Time.get_ticks_usec()
		for i in 20:
			_reference(reference, main._fx, done, main.state.grid)
		old_us = mini(old_us, Time.get_ticks_usec() - t)
		t = Time.get_ticks_usec()
		for i in 20:
			main._lod_decal_done = done
			main._lod_sync_decals(main.state.grid)
		new_us = mini(new_us, Time.get_ticks_usec() - t)
	ck(main._lod_terrain.get_data() == reference.get_data(), "benchmark pixels changed")
	print("one new decal after 68000 settled: reference %.1f us / current %.1f us per update" % [
			old_us / 20.0, new_us / 20.0])
	main._lod.free()
	main.free()
