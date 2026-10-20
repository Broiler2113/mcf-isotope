extends SceneTree

var failures: Array[String] = []
var checks := 0
func ck(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); printerr("FAIL: " + label)
func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	await _lights()
	await _preview()
	await _editor()
	print("Lighting/QoL: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _lights() -> void:
	var map := MapData.blank_arena(30, 20)
	map.set_spawn(Vector2i(1, 1), "light_infantry", 0)
	map.set_spawn(Vector2i(28, 18), "light_infantry", 1)
	var state := map.build_state(7)
	var grid := state.grid
	var gw := grid.width
	var lamp := Vector2i(4, 5)
	var wall := Vector2i(7, 5)
	grid.cell(lamp).set_feature("lamp")
	grid.cell(wall).set_feature(MCF.FEATURE_WALL)
	grid.cell(Vector2i(7, 6)).set_feature(MCF.FEATURE_GLASS)
	grid.cell(Vector2i(7, 7)).set_feature(MCF.FEATURE_ARMOR_GLASS)
	grid.cell(Vector2i(7, 8)).set_feature("wardrobe")          # 1.5 m furniture
	grid.cell(Vector2i(7, 9)).set_feature("vending_machine")   # 2 m furniture
	var index := LightOccluders.new()
	index.sync(grid)
	ck(index.shapes.has(wall.y * gw + wall.x), "solid wall stops light")
	ck(not index.shapes.has(6 * gw + 7) and not index.shapes.has(7 * gw + 7), "both glass types transmit light")
	ck(not index.shapes.has(8 * gw + 7), "furniture under 2 m lets light through")
	ck(not index.shapes.has(9 * gw + 7), "even 2 m furniture casts no light shadow")
	ck(index.sources.has(Vector2i(7, 9)), "a vending machine glows")
	var reads := index.cells_read
	index.sync(grid)
	ck(index.cells_read == reads, "unchanged frame does not scan geometry")
	grid.cell(wall).clear_feature()
	index.sync(grid)
	ck(not index.shapes.has(wall.y * gw + wall.x) and index.cells_read == reads + 1, "wall destruction updates only that cell")
	grid.cell(lamp).clear_feature()
	index.sync(grid)
	ck(not index.sources.has(lamp), "destroyed furniture stops emitting")
	grid.cell(lamp).on_fire = true
	index.sync(grid)
	ck(index.sources[lamp][0].kind == "fire", "fire ignition adds light")
	grid.cell(lamp).on_fire = false
	index.sync(grid)
	ck(not index.sources.has(lamp), "extinguished fire loses light")
	grid.cell(lamp).gas = true
	index.sync(grid)
	ck(not index.sources.has(lamp), "gas does not glow")
	grid.cell(lamp).gas = false
	for i in 40: grid.cell(Vector2i(2 + i % 10, 12 + i / 10)).set_feature("lamp")
	var host := Node2D.new()
	root.add_child(host)
	var manager := LightManager.new()
	host.add_child(manager)
	var before := StateCodec.encode(state)
	manager.update_view(grid, Vector2.ZERO, 0.5, Vector2.ZERO, 32.0, "station", {}, false, null, null, 0.8)
	ck(manager.last_instances == 41, "every lamp is one instance of a single multimesh (%d)" % manager.last_instances)
	ck(StateCodec.encode(state) == before, "lighting leaves simulation state untouched")
	var drawn := manager.redraws
	for i in 5: manager.update_view(grid, Vector2.ZERO, 0.5, Vector2.ZERO, 32.0, "station", {}, false, null, null, 0.8)
	ck(manager.redraws == drawn, "an unchanged frame does not redraw the light map")
	grid.cell(Vector2i(20, 3)).set_feature(MCF.FEATURE_WALL)
	manager.update_view(grid, Vector2.ZERO, 0.5, Vector2.ZERO, 32.0, "station", {}, false, null, null, 0.8)
	ck(manager.redraws == drawn + 1, "a new wall redraws once")
	ck(manager._walls_img.get_pixel(20, 3).r > 0.9, "the wall mask learns the new wall incrementally")
	grid.cell(Vector2i(12, 5)).on_fire = true
	manager.update_view(grid, Vector2.ZERO, 0.5, Vector2.ZERO, 32.0, "station", {Vector2i(1, 1): true}, true, null, null, 0.8)
	ck(manager.last_instances == 41, "fire the viewer cannot see does not glow")
	manager.update_view(grid, Vector2.ZERO, 0.5, Vector2.ZERO, 32.0, "station", {Vector2i(12, 5): true}, true, null, null, 0.8)
	ck(manager.last_instances == 42, "visible fire glows")
	grid.cell(Vector2i(12, 5)).on_fire = false
	var fx := FxDecals.new()
	fx.flashes.append({"cells": [Vector2i(15, 5)], "t": 0.0})
	manager.update_view(grid, Vector2.ZERO, 0.5, Vector2.ZERO, 32.0, "station", {}, false, fx, null, 0.8)
	ck(manager.last_instances == 42, "an explosion flash adds a light")
	fx.flashes.clear()
	manager.update_view(grid, Vector2.ZERO, 0.5, Vector2.ZERO, 32.0, "station", {}, false, fx, null, 0.8)
	ck(manager.last_instances == 41, "the flash goes away again")
	ck(LightManager.ambient_for("station", 0.0).v > LightManager.ambient_for("station", 1.0).v, "darkness setting dims ambient light")
	host.free()

func _preview() -> void:
	var map := MapData.blank_arena(149, 119)
	for i in 20: map.set_spawn(Vector2i(10 + i % 5, 10 + i / 5), "light_infantry", 0)
	map.set_spawn(Vector2i(140, 110), "light_infantry", 1)
	var state := map.build_state(12)
	state.turns.round_order.assign([0, 1])
	state.turns.active_index = 0
	var resolver := GameActionResolver.new(state)
	var ids: Array[int] = []
	for unit in state.all_units():
		if unit.owner == 0: ids.append(unit.id)
	var preview := GroupMovePreview.new()
	var target := Vector2i(23, 20)
	var max_slice := 0
	var ready := false
	var frames := 0
	var before := state.digest_hash()
	while not ready and frames < 200:
		var start := Time.get_ticks_usec()
		ready = preview.sync(resolver, ids, target, false, 4000)
		max_slice = maxi(max_slice, Time.get_ticks_usec() - start)
		frames += 1
		await process_frame
	ck(ready and frames > 1, "large group preview yields between frames and completes")
	ck(state.digest_hash() == before, "cooperative preview never mutates the match")
	var expected := GroupMovePlanner.plan(resolver, ids, target, false, preview.zone.tier.get(target, 0))
	ck(preview.plan() == expected, "cooperative and immediate orders have identical targets and order")
	state.get_unit(ids[0]).remaining_ap = 0
	preview.sync(resolver, ids, target, false, 1)
	ck(not preview.zone_ready and preview.job == null, "AP changes discard stale plans")
	print("20-soldier giant-map preview: %d frames, longest slice %.2f ms" % [frames, max_slice / 1000.0])

func _editor() -> void:
	var editor = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	editor.brush = "floor:%d" % MCF.Look.WOOD
	editor._hover = Vector2i(10, 10)
	editor._build_preview()
	ck(not editor._pv.is_empty() and editor._pv_floor != null, "floor texture change has a hover preview")
	ck(is_equal_approx(editor._pv_tint.a, 0.5), "floor preview is half opaque")
	var ui := root.get_node("Ui")
	ck(not ui.dynamic_lighting and editor._lighting == null, "lighting defaults off and creates no renderer")
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_L
	key.shift_pressed = true
	editor._input(key)
	ck(is_instance_valid(editor._lighting) and editor._lighting_btn.button_pressed, "Shift+L turns editor lighting on, even with the battle setting off")
	editor._lighting_btn.toggled.emit(false)
	ck(editor._lighting == null and not editor._lighting_btn.button_pressed, "the Lighting button turns it off again")
	editor._menu_action("check:lighting")
	ck(is_instance_valid(editor._lighting), "the View menu entry toggles it too")
	editor._menu_action("check:lighting")
	editor._dirty = false
	current_scene = editor
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = KEY_ESCAPE
	editor._input(event)
	await process_frame
	await process_frame
	ck(current_scene != editor, "Escape can leave the editor without accessing a detached viewport")
