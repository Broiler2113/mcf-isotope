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
	var lamp := Vector2i(4, 5)
	var wall := Vector2i(7, 5)
	grid.cell(lamp).set_feature("lamp")
	grid.cell(wall).set_feature(MCF.FEATURE_WALL)
	grid.cell(Vector2i(7, 6)).set_feature(MCF.FEATURE_GLASS)
	grid.cell(Vector2i(7, 7)).set_feature(MCF.FEATURE_ARMOR_GLASS)
	var index := LightOccluders.new()
	index.sync(grid)
	ck(index.shapes.has(wall), "solid wall casts shadows")
	ck(not index.shapes.has(Vector2i(7, 6)) and not index.shapes.has(Vector2i(7, 7)), "both glass types transmit light")
	var reads := index.cells_read
	index.sync(grid)
	ck(index.cells_read == reads, "unchanged frame does not scan geometry")
	grid.cell(wall).clear_feature()
	index.sync(grid)
	ck(not index.shapes.has(wall) and index.cells_read == reads + 1, "wall destruction updates only that cell")
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
	ck(index.sources[lamp][0].color == Color.WHITE, "gas glow is white")
	grid.cell(lamp).gas = false
	grid.cell(Vector2i(28, 18)).set_feature(MCF.FEATURE_WALL)
	for i in 40: grid.cell(Vector2i(2 + i % 10, 2 + i / 10)).set_feature("lamp")
	var manager := LightManager.new()
	root.add_child(manager)
	var hash_before := StateCodec.encode(state)
	manager.update_view(grid, Vector2.ZERO, 0.5, 32)
	ck(manager.lights.size() == 40 and manager.batches.size() == 2, "all 40 overlapping sources receive independent engine lights")
	var far_shadow := false
	for batch: Dictionary in manager.batches:
		far_shadow = far_shadow or batch.occluders.has(Vector2i(28, 18))
	ck(not far_shadow, "distant walls do not allocate shadow nodes for these lights")
	grid.cell(Vector2i(7, 8)).set_feature(MCF.FEATURE_WALL)
	manager.update_view(grid, Vector2.ZERO, 0.5, 32)
	ck(manager.batches[0].occluders.has(Vector2i(7, 8)), "new nearby wall gains a shadow node incrementally")
	grid.cell(Vector2i(7, 8)).clear_feature()
	manager.update_view(grid, Vector2.ZERO, 0.5, 32)
	ck(not manager.batches[0].occluders.has(Vector2i(7, 8)), "demolition removes its shadow node incrementally")
	ck(StateCodec.encode(state) == hash_before, "lighting leaves simulation state untouched")
	manager.update_view(grid, Vector2.ZERO, 0.5, 32, {Vector2i(2, 2): true}, true)
	ck(manager.lights.size() == 1, "hidden lamps cannot reveal themselves through glow")
	ck(manager._known_shapes.size() == 1, "hidden geometry cannot reveal itself through shadows")
	var fx := FxDecals.new()
	fx.flashes.append({"cells": [Vector2i(15, 5)], "t": 0.0})
	manager.update_view(grid, Vector2.ZERO, 0.5, 32, {}, false, fx)
	var flash: PointLight2D = manager.lights["flash:0:15:5"].light
	ck(is_equal_approx(flash.energy, FxDecals.flash_alpha(fx.flashes[0])), "flash light follows existing alpha")
	fx.flashes[0].t = FxDecals.FLASH_DUR * 0.9
	manager.update_view(grid, Vector2.ZERO, 0.5, 32, {}, false, fx)
	ck(is_equal_approx(flash.energy, FxDecals.flash_alpha(fx.flashes[0])), "flash light fades with the same clock")
	manager.free()

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
	ui.dynamic_lighting = true
	editor._sync_lighting()
	ck(is_instance_valid(editor._lighting), "editor can enable lighting live")
	editor._menu_action("check:lighting")
	ck(editor._lighting == null, "editor preview toggle tears lighting down")
	ui.dynamic_lighting = false
	editor._dirty = false
	current_scene = editor
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = KEY_ESCAPE
	editor._input(event)
	await process_frame
	await process_frame
	ck(current_scene != editor, "Escape can leave the editor without accessing a detached viewport")
