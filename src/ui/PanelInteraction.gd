class_name PanelInteraction
extends RefCounted

## Shared battle and deployment chat window interactions.
static func resize_grip(panel: Control, body: Control, grow_x: float, on_start: Callable) -> Control:
	# Три косые черты — рисуем сами: стрелочных глифов в системном шрифте может не быть.
	var grip := Control.new()
	grip.custom_minimum_size = Vector2(16, 16)
	grip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grip.draw.connect(func() -> void:
		var col := Color("#b0b0b0")
		for i in 3:
			var k := 4.0 + i * 4.0
			if grow_x < 0.0:
				grip.draw_line(Vector2(0, 16 - k), Vector2(k, 16), col, 1.5)
			else:
				grip.draw_line(Vector2(16 - k, 16), Vector2(16, 16 - k), col, 1.5))
	grip.tooltip_text = "Drag to resize"
	grip.mouse_filter = Control.MOUSE_FILTER_STOP
	grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE if grow_x < 0.0 \
			else Control.CURSOR_BDIAGSIZE
	var state := {"on": false, "from": Vector2.ZERO, "size": Vector2.ZERO, "bottom": 0.0,
			"right": 0.0}
	grip.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			state["on"] = e.pressed
			if e.pressed:
				on_start.call()
				state["from"] = e.global_position
				state["size"] = body.custom_minimum_size
				state["bottom"] = panel.position.y + panel.size.y
				state["right"] = panel.position.x + panel.size.x
			grip.accept_event()
		elif e is InputEventMouseMotion and state["on"]:
			var d: Vector2 = e.global_position - state["from"]
			var vp := panel.get_viewport_rect().size
			var sz: Vector2 = state["size"] + Vector2(d.x * grow_x, -d.y)
			sz.x = clampf(sz.x, 220.0, vp.x * 0.6)
			sz.y = clampf(sz.y, 60.0, vp.y * 0.7)
			body.custom_minimum_size = sz
			panel.reset_size()
			# Нижняя кромка (и та боковая, от которой растём) — на месте.
			var bottom: float = state["bottom"]
			panel.position.y = clampf(bottom - panel.size.y, 0.0, vp.y - panel.size.y)
			if grow_x < 0.0:
				panel.position.x = clampf(float(state["right"]) - panel.size.x, 0.0, vp.x - panel.size.x)
			grip.accept_event())
	return grip


static func draggable(panel: Control, header: Control, on_move: Callable) -> void:
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	var drag := {"active": false, "offset": Vector2.ZERO}
	header.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			drag.active = e.pressed
			if e.pressed:
				drag.offset = panel.global_position - e.global_position
				on_move.call()
			header.accept_event()
		elif e is InputEventMouseMotion and drag.active:
			var vp := panel.get_viewport_rect().size
			var pos: Vector2 = e.global_position + drag.offset
			panel.position = pos.clamp(Vector2.ZERO, (vp - panel.size).max(Vector2.ZERO))
			header.accept_event())

## Shared sidebar geometry for deployment and battle.
static func sidebar(panel: Control, width := 264.0) -> void:
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -width
	panel.offset_right = 0.0
	panel.offset_top = 0.0
	panel.offset_bottom = 0.0
