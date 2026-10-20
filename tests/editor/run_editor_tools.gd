extends "res://tests/SuiteBase.gd"
## Editor tools: lamp colours, built-in presets, items, artwork and decals through JSON,
## blood painting and its undo.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	await _light_colours()
	_builtin_presets()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_items_on_map()
	await _items_editor()

	await _editor_metadata()

	await _editor()

## A lamp's colour is chosen in the editor (right-click or Ctrl+click) and carries into the
## battle: the glow takes the colour, and so does the lamp's glass.
func _light_colours() -> void:
	var ed: Node = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(ed)
	for i in 5: await process_frame
	var c := Vector2i(5, 5)
	var i: int = c.y * ed.map.width + c.x
	var t: Array = ed._tuple(i)
	t[3] = "floor_lamp"
	t[1] = Furniture.height_of("floor_lamp")
	ed._begin()
	ed._write(i, t)
	ed._commit()
	var screen: Vector2 = ed.pan + (Vector2(c) + Vector2(0.5, 0.5)) * ed.cell_size()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.ctrl_pressed = true
	click.position = screen
	ed._unhandled_input(click)
	# 0.12.1: seven common brightness steps plus "Type a value…" for the rest.
	ck(ed._light_menu != null and ed._light_menu.visible and ed._light_menu.item_count == Furniture.LIGHT_TINTS.size() + 1 + 7 + 1
			and ed._light_menu.get_item_index(ed.LIGHT_TYPE_ID) >= 0,
			"Ctrl+click on a lamp opens its colour menu (Mac habit)")
	ed._light_menu.hide()
	for pressed in [true, false]:
		var right := InputEventMouseButton.new()
		right.button_index = MOUSE_BUTTON_RIGHT
		right.pressed = pressed
		right.position = screen
		ed._unhandled_input(right)
	ck(ed._light_menu.visible, "a right-click (two-finger click) opens it too")
	ed._light_menu.id_pressed.emit(4)   # Red
	ck(ed.map.get_tint(i) == 4 and ed._grid.tint_at(c.x, c.y) == 4, "the chosen colour is stored on the map")
	var occ := LightOccluders.new()
	occ.sync(ed._grid)
	ck(occ.sources[c][0].color == Furniture.LIGHT_TINTS[4][1], "the glow takes the colour")
	var back := MapData.from_dict(ed.map.to_dict())
	ck(back.get_tint(i) == 4, "it survives saving the map")
	var g := Grid.new(back.width, back.height)
	back.apply_to_grid(g)
	ck(g.tint_at(c.x, c.y) == 4, "and reaches the battle board")
	var white := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	white.fill(Color(0.95, 0.95, 0.95))
	var red := TerrainTiles.tint_lamp(white, Furniture.LIGHT_TINTS[4][1]).get_pixel(1, 1)
	ck(red.r > 0.8 and red.g < 0.5, "a white lamp's glass turns red with its light")
	ed.undo()
	ck(ed.map.get_tint(i) == 0, "undo puts the colour back")
	ed.queue_free()
	await process_frame

## The built-in rooms are ordinary preset files: listed, renamable, deletable for good.
func _builtin_presets() -> void:
	var store := load("res://src/data/RoomPresetStore.gd")
	var marker: String = store.DIR.path_join(store.SEEDED_MARKER)
	DirAccess.remove_absolute(marker)
	store.remove_preset("Corridor")
	store.seed_builtins()
	ck(store.names().has("Small room") and store.names().has("Hedgehog row"), "built-in rooms are preset files")
	ck(store.rename_preset("Corridor", "zz Hall") and store.names().has("zz Hall") and not store.names().has("Corridor"),
			"a built-in can be renamed")
	store.remove_preset("zz Hall")
	ck(store.seed_builtins() == 0 and not store.names().has("Corridor"), "a deleted built-in stays deleted")
	store.save_preset("Corridor", MapPresets.stamp("corridor"), "station")

## Small items (0.12.1): free-placed [kind, x, y, angle] in the map file; unknown kinds are
## dropped; they ride through stamps (rotated) and onto the battle board.
func _items_on_map() -> void:
	var m := MapData.blank_arena(12, 10)
	m.items = [["mug", 3.25, 4.6, 0.7], ["papers", 5.5, 5.5, 2.0]]
	var d := m.to_dict()
	d["items"].append(["teapot", 1.0, 1.0, 0.0])
	var back := MapData.from_dict(d)
	ck(back.items.size() == 2 and back.items[0][0] == "mug" and is_equal_approx(float(back.items[0][1]), 3.25),
			"items survive the map file at their exact spot; unknown kinds are dropped")
	var p := MapPresets.capture(back, Rect2i(2, 3, 4, 4))
	var r := MapPresets.rotated(p)
	ck(p["items"].size() == 2 and r["items"].size() == 2, "a captured stamp carries its items, also when turned")
	var g := Grid.new(12, 10)
	back.apply_to_grid(g)
	ck(g.map_items.size() == 2 and g.items_in(Vector2i(3, 4)) == [0], "the board knows which items lie in each cell")
	var st := back.build_state(1)
	var rs := StateCodec.decode(StateCodec.encode(st))
	ck(rs.grid.map_items.size() == 2, "saves carry the items")

## In the editor: a click lays the chosen item at the pointer (undoable); a painted table
## lays its set; erasing the table takes its items along.
func _items_editor() -> void:
	var ed: Node = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(ed)
	for i in 5: await process_frame
	ed.create_map("t", "town", Vector2i(16, 12))
	var at := Vector2(5.3, 4.7)
	var screen: Vector2 = ed.pan + at * ed.cell_size()
	ed._select_brush("item:mug")
	ed.item_rotation = 0.5
	ed._press(Vector2i(5, 4), false, screen)
	ed._release(Vector2i(5, 4))
	ck(ed.map.items.size() == 1 and ed.map.items[0][0] == "mug" and Vector2(ed.map.items[0][1], ed.map.items[0][2]).distance_to(at) < 0.01
			and is_equal_approx(float(ed.map.items[0][3]), 0.5), "a click lays a mug at the pointer, at the chosen angle")
	ed.undo()
	ck(ed.map.items.is_empty(), "undo takes it back")
	ed._select_brush("coffee_table")
	ck(ed._set_row.visible and ed._table_set() == "coffee", "a table brush shows its item set (%s)" % ed._table_set())
	ed._cycle_table_set(1)
	ck(ed._table_set() == "meeting", "the arrows pick another set")
	for x in [2, 6, 10, 13]:
		ed._press(Vector2i(x, 8), false)
		ed._release(Vector2i(x, 8))
	var laid: Array = ed.map.items.duplicate()
	ck(not laid.is_empty() and laid.all(func(it: Array) -> bool: return it[0] in ["papers", "folder", "mug", "cup", "phone", "laptop"]),
			"painted tables are laid with the chosen set (%d items)" % laid.size())
	ed._select_tool(ed.Tool.ERASER)
	ed._press(Vector2i(2, 8), false)
	ed._release(Vector2i(2, 8))
	ck(ed.map.items.all(func(it: Array) -> bool: return SmallItems.cell_of(it) != Vector2i(2, 8)), "erasing a table takes its items")
	ed.queue_free()
	await process_frame

const Rooms = preload("res://src/data/RoomPresetStore.gd")

func _editor_metadata() -> void:
	var editor: Variant = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(editor)
	editor.create_map("", "station", Vector2i(20, 20))
	editor._begin()
	editor._write(42, [0, MCF.WALL_HEIGHT, false, MCF.FEATURE_AIRLOCK, -1, -1, 0, 3, 8])
	editor.map.decals.append(["blood_pool", 2.25, 2.75, 0.0, 1.0])
	editor._sync_editor_decals()
	editor._commit()
	var restored := MapData.from_dict(JSON.parse_string(JSON.stringify(editor.map.to_dict())))
	ck(restored.get_accent(42) == 3 and restored.get_door(42) == 8, "map JSON preserves door artwork and station accents")
	ck(restored.decals[0][1] == 2.25, "blood position stays off-grid through JSON")
	editor.undo()
	ck(editor.map.get_door(42) == 0 and editor.map.decals.is_empty(), "undo restores artwork and decals together")
	editor.redo()
	ck(editor.map.get_door(42) == 8 and editor.map.decals.size() == 1, "redo restores artwork and decals together")
	var p := MapPresets.capture(editor.map, Rect2i(2, 2, 4, 3))
	var rotated := MapPresets.rotated(p)
	ck(float(rotated["decals"][0][1]) == 2.25 and float(rotated["decals"][0][2]) == 0.25, "rotated room rotates free-position decals")
	ck(Rooms.save_preset("zz_098_test", p, "station"), "custom room saves")
	var loaded := Rooms.read_preset("zz_098_test")
	ck(not loaded.is_empty() and int(loaded["pattern"]["cells"][0][8]) == 8, "custom room loads its door choice")
	var thumbnail := TerrainTiles.map_preview(Rooms.to_map(loaded["pattern"], "station"))
	ck(thumbnail != null and thumbnail.get_width() > 4, "room preview uses textured cells")
	Rooms.remove_preset("zz_098_test")
	ck(Rooms.read_preset("zz_098_test").is_empty(), "custom room deletion removes the preset")
	editor.resize_map(30, 24)
	ck(editor.map.get_door(62) == 8 and editor.map.decals.size() == 1, "map expansion preserves cells and decals")
	editor.set_preset("bunker")
	ck(editor._ground != null and editor._ground.texture != null, "editor changes to bunker soil background")
	editor.set_preset("station")
	ck(editor._ground.texture == null, "editor switches back to space background")
	editor.queue_free()
	await process_frame

func _editor() -> void:
	var e: Variant = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(e)
	e.create_map("", "town", Vector2i(20, 20))
	e._select_brush("decal:blood_pool")
	e._press(Vector2i(4, 4), false, e.pan + Vector2(4.13, 4.78) * e.cell_size())
	e._paint_decal(Vector2(4.38, 4.78))
	e._release(Vector2i(4, 4))
	ck(e.map.decals.size() == 2, "blood painting moves within one cell")
	ck(is_equal_approx(float(e.map.decals[0][1]), 4.13), "blood preserves exact cursor position")
	e.undo()
	ck(e.map.decals.is_empty(), "one undo removes entire decal stroke")
	e.redo()
	e.rotate_key()
	e._press(Vector2i(5, 5), false, e.pan + Vector2(5.13, 5.78) * e.cell_size())
	e._release(Vector2i(5, 5))
	ck(is_equal_approx(float(e.map.decals.back()[3]), PI / 2), "R rotates decal placement")
	e._select_brush("decal:corpse")
	e._press(Vector2i(6, 6), false, e.pan + Vector2(6.13, 6.78) * e.cell_size())
	e._release(Vector2i(6, 6))
	ck(Vector2(e.map.decals.back()[1], e.map.decals.back()[2]) == Vector2(6.5, 6.5), "corpse snaps to cell center")
	e._select_brush("decal:blood_drop")
	e._press(Vector2i(7, 7), false, e.pan + Vector2(7.2, 7.2) * e.cell_size())
	var count: int = e.map.decals.size()
	var motion := InputEventMouseMotion.new()
	motion.position = e.pan + Vector2(7.8, 7.8) * e.cell_size()
	motion.button_mask = 0
	e._unhandled_input(motion)
	ck(e.map.decals.size() == count and not e._decal_painting, "releasing over the UI cannot leave decal painting stuck on")
	e._select_brush(MCF.FEATURE_WALL)
	var wall_entries: Array = e._variant_entries()
	ck(wall_entries.size() == MCF.ACCENT_COLORS.size(), "wall offers only accent options")
	wall_entries[3][2].call()
	ck(e._brushed([0, 0, false, "", -1], 0)[7] == 3, "wall painting uses chosen accent")
	e._select_brush(MCF.FEATURE_AIRLOCK)
	var door_entries: Array = e._variant_entries()
	ck(door_entries.size() == 1 + TerrainTiles.DOOR_MATERIALS.size() * 3, "door offers only texture options")
	door_entries[8][2].call()
	ck(e._brushed([0, 0, false, "", -1], 0)[8] == 8, "door painting uses selected texture")
	ck(e._door_thumb(7).region != e._door_thumb(8).region, "door preview displays selected sprite variant")
	e._select_brush("floor")
	ck(e._variant_entries().is_empty(), "other brushes offer no wall or door options")
	e.queue_free()
	await process_frame
