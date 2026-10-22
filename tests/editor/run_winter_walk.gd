extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var editor: Node = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	editor.create_map("Winter preview", "town", Vector2i(20, 16))
	editor.set_winter(true)
	ck(editor.map.winter, "winter applies in the editor")
	editor.undo()
	ck(not editor.map.winter, "winter is undoable")
	editor.redo()
	ck(editor.map.winter, "winter can be redone")
	editor.map.set_cell(Vector2i(6, 6), 0, 2.0, false, MCF.FEATURE_WALL)
	editor.map.decals = [["snowman", 9.5, 7.5, 0.0, 1.0]]
	editor.map.set_spawn(Vector2i(12, 12), "civilian", MCF.Owner.NEUTRAL)
	editor.map.corpses = [10 * editor.map.width + 10]
	GameConfig.civilian_count = 0
	editor._map_replaced()
	var before := JSON.stringify(editor.map.to_dict())
	editor._enter_fp_pick()
	_click(editor, Vector2i(6, 6))
	ck(editor._fp == null and editor._fp_pick, "a blocked start lets the player pick again")
	_click(editor, Vector2i(7, 8))
	for i in 12: await process_frame
	ck(editor._fp != null and not editor._fp_pick and not editor._ui.visible, "a free cell opens the editor walkthrough")
	if editor._fp != null:
		var fp: Control = editor._fp
		ck(editor._fp_host.state.grid.cell(Vector2i(12, 12)).occupant != null, "the walkthrough keeps authored civilians regardless of lobby limits")
		ck(editor._fp_host._corpse_map().has(Vector2i(10, 10)), "the walkthrough includes authored corpse piles")
		ck(GameConfig.civilian_count == 0, "preview does not change lobby settings")
		var ui: Node = root.get_node("Ui")
		ui.snowfall = false
		fp._sync_snow()
		ck(fp._snow == null or not fp._snow.visible, "snowfall can be turned off during a walkthrough")
		ui.snowfall = true
		fp._sync_snow()
		ck(fp._snow != null and fp._snow.emitting and fp._snow.visible, "snowfall can be turned on during a walkthrough")
		fp.leave()
	for i in 2: await process_frame
	ck(editor._fp == null and editor._ui.visible, "leaving restores the editor")
	ck(JSON.stringify(editor.map.to_dict()) == before, "walking preserves the entire editable map")
	editor.create_map("Station preview", "station", Vector2i(20, 16))
	editor.set_winter(true)
	ck(not editor.map.winter, "indoor presets reject winter")
	editor.free()

func _click(editor: Node, cell: Vector2i) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = editor.pan + (Vector2(cell) + Vector2.ONE * 0.5) * editor.cell_size()
	editor._unhandled_input(event)
