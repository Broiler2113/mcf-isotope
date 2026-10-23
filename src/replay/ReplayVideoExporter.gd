class_name ReplayVideoExporter
extends Node

signal progress(value: float)
signal completed(path: String, error: String)

var cancelled := false
var encoder: ReplayVideoEncoder
var viewport: SubViewport

static func frame_count(actions: int, fps: int, speed: float) -> int:
	return maxi(2, ceili(float(actions) * fps / (30.0 * speed)) + 1)

func run(data: Dictionary, path: String, resolution: Vector2i, fps: int, speed: float, executable: String) -> void:
	if DisplayServer.get_name() == "headless":
		completed.emit("", "Video export needs a rendered game window.")
		return
	encoder = ReplayVideoEncoder.new()
	var error := encoder.start(executable, path, resolution, fps)
	if not error.is_empty(): completed.emit("", error); return
	viewport = SubViewport.new()
	viewport.size = resolution
	viewport.disable_3d = true
	viewport.own_world_3d = true
	viewport.world_2d = World2D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var board: Node = load("res://scenes/Main.tscn").instantiate()
	board.video_export = true
	board.export_replay_data = data
	board._replay_skip_animations = true
	viewport.add_child(board)
	board._audio.suppress = true
	board._ui_layer.visible = false
	board._hud_width = 0
	board._kill_pan_tween()
	var cells := Vector2(board.state.grid.width, board.state.grid.height)
	board.zoom = minf(resolution.x / ((cells.x + 1) * board.CELL), resolution.y / ((cells.y + 1) * board.CELL))
	board.pan = Vector2(resolution) * 0.5 - (board.ORIGIN + cells * board.CELL * 0.5) * board.zoom
	var frames := frame_count(board.replay.step_count(), fps, speed)
	for frame in frames:
		if cancelled: break
		var target := mini(board.replay.step_count(), floori(float(frame) * 30.0 * speed / fps))
		# The final frame always includes the complete board, including short replays.
		if frame == frames - 1: target = board.replay.step_count()
		var started := Time.get_ticks_usec()
		while board.replay.index < target:
			board._apply_timelapse_result(board.replay.play_next())
			if Time.get_ticks_usec() - started > 8000:
				await get_tree().process_frame
				started = Time.get_ticks_usec()
				if cancelled: break
		if cancelled: break
		board._fx.advance(10.0)
		board._sync_lighting()
		board._fit_ground()
		if board._sky != null: board._sky.camera = board.pan
		board.queue_redraw()
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		var bytes := image.get_data()
		while not encoder.push(bytes) and not cancelled and not encoder.status().done:
			await get_tree().process_frame
		if encoder.status().done: break
		progress.emit(float(frame + 1) / frames)
		await get_tree().process_frame
	encoder.finish()
	while not encoder.status().done: await get_tree().process_frame
	encoder.join()
	var result := encoder.status()
	viewport.queue_free()
	viewport = null
	completed.emit("" if cancelled or not result.error.is_empty() else path, "Export canceled." if cancelled else str(result.error))

func cancel() -> void:
	cancelled = true
	if encoder != null: encoder.cancel()

func _exit_tree() -> void:
	if encoder != null:
		encoder.cancel()
		encoder.join()
