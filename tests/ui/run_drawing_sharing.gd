extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(16, 12)
	map.env = "field"
	map.winter = true
	map.set_cell(Vector2i(7, 7), MCF.FLOOR_GRASS, 0, false, "")
	map.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	map.set_spawn(Vector2i(13, 9), "light_infantry", 1)
	MapHandoff.pending = map
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 4: await process_frame
	var averages: Dictionary = main._lod_texture_averages()
	ck(averages.has("floor_grass") and averages["floor_grass"].r > 0.7, "snow remains white when the battle view zooms out")
	var me: int = main._draw_author()
	var self_scope: int = main.DrawScope.SELF
	var all_scope: int = main.DrawScope.ALL
	var point := Vector2(130, 130)
	var stroke := {"a": me, "s": self_scope, "c": [point.x, point.y], "w": 8, "col": "ff4400"}
	main._on_remote_stroke(stroke.duplicate())
	main._on_remote_stroke({"a": me, "e": true, "c": [point.x, point.y], "r": 8.0})
	main._on_remote_stroke(stroke.duplicate())
	main._add_ruler(me, self_scope, Vector2i(1, 1), Vector2i(4, 6))
	main._reshare_drawings(all_scope)
	ck(_pixel(main, me, all_scope, point).r > 0.9, "sharing preserves the visible stroke")
	ck(main._rulers.size() == 1 and main._rulers[0]["scope"] == all_scope, "sharing publishes the existing ruler")
	ck(main._undo_drawing_of(me) and main._rulers.is_empty(), "ruler can still be undone after sharing")
	ck(main._undo_drawing_of(me) and _pixel(main, me, all_scope, point).a == 0.0, "stroke can still be undone after sharing")
	main._reshare_drawings(all_scope)
	ck(_pixel(main, me, all_scope, point).a == 0.0, "resharing does not resurrect the undone duplicate stroke")
	ck(main._undo_drawing_of(me) and _pixel(main, me, all_scope, point).r > 0.9, "erasure can still be undone after resharing")
	ck(main._undo_drawing_of(me), "the original stroke remains undoable")
	main._clear_my_drawings()
	main._add_ruler(me, self_scope, Vector2i(1, 1), Vector2i(4, 6))
	for i in main.DRAW_UNDO_DEPTH + 1:
		main._on_remote_stroke({"a": me, "s": self_scope, "c": [20.0 + i * 2, 20.0], "w": 2})
	ck(main._drop_last_ruler(me), "Backspace removes a ruler older than the undo limit")
	main._reshare_drawings(all_scope)
	ck(main._rulers.is_empty(), "sharing does not resurrect an old removed ruler")
	ck(not main._multi_btn.visible and not main._height_btn.visible, "multiselect and heightmap are absent from the side panel")
	main.free()
	await process_frame

func _pixel(main: Node, author: int, scope: int, point: Vector2) -> Color:
	var canvas: DrawCanvas = main._canvas(author, scope)
	var key := Vector2i(floori(point.x / DrawCanvas.TILE), floori(point.y / DrawCanvas.TILE))
	if not canvas._tiles.has(key): return Color.TRANSPARENT
	return canvas._tiles[key]["img"].get_pixel(int(point.x) % DrawCanvas.TILE, int(point.y) % DrawCanvas.TILE)
