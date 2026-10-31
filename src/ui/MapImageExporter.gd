class_name MapImageExporter
extends Node

signal progress(value: float, message: String)
signal completed(path: String, error: String)

const DENSITIES := [32, 64, 128]
const MAX_PIXELS := 64 * 1024 * 1024
const MAX_SIDE := 16384
const SECTION := 1024
const MARGIN := 64

var cancelled := false
var viewport: SubViewport
var _writer: Thread
var _temporary := ""

static func image_size(cells: Vector2i, density: int) -> Vector2i:
	return cells * density

static func fits(size: Vector2i) -> bool:
	return size.x > 0 and size.y > 0 and size.x <= MAX_SIDE and size.y <= MAX_SIDE \
			and size.x * size.y <= MAX_PIXELS

func run(host: Node, path: String, density: int, lighting: bool) -> void:
	if DisplayServer.get_name() == "headless":
		_finish("", "Image export needs a rendered game window.")
		return
	var size := image_size(Vector2i(host.state.grid.width, host.state.grid.height), density)
	if not DENSITIES.has(density) or not fits(size):
		_finish("", "This resolution is too large. Choose a smaller image size.")
		return
	_temporary = "%s.%d-%d.tmp" % [path, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(_temporary, FileAccess.WRITE)
	if file == null:
		_finish("", "Cannot save to this folder: " + error_string(FileAccess.get_open_error()))
		return
	file.close()
	progress.emit(0.0, "Preparing map…")
	var board: Node = load("res://src/ui/MapImageBoard.gd").new()
	board.capture(host, lighting, density)
	viewport = SubViewport.new()
	viewport.disable_3d = true
	viewport.world_2d = World2D.new()
	viewport.gui_disable_input = true
	viewport.size = Vector2i.ONE * (SECTION + MARGIN * 2)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	viewport.add_child(board)
	var output := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	if output == null or output.is_empty():
		_finish("", "Not enough memory for this image. Choose a smaller image size.")
		return
	var columns := ceili(float(size.x) / SECTION)
	var rows := ceili(float(size.y) / SECTION)
	for row in rows:
		for column in columns:
			if cancelled:
				_finish("", "Image export canceled.")
				return
			var at := Vector2i(column, row) * SECTION
			var section_size := Vector2i(mini(SECTION, size.x - at.x), mini(SECTION, size.y - at.y))
			viewport.size = section_size + Vector2i.ONE * MARGIN * 2
			board.prepare_section(at, MARGIN, size)
			# Terrain, over-unit layers and nested light maps may queue their draw after
			# the board's first pass. Capture only after those layers have caught up.
			for pass_index in 3:
				await get_tree().process_frame
				board._sync_lighting()
				board.queue_redraw()
				await RenderingServer.frame_post_draw
				board.freeze_particles()
				if cancelled: break
			while not cancelled and board._tiles != null and board._tiles._deferred_rebuild:
				await get_tree().process_frame
				board._sync_lighting()
				board.queue_redraw()
				await RenderingServer.frame_post_draw
			if cancelled:
				_finish("", "Image export canceled.")
				return
			var section := viewport.get_texture().get_image()
			if section == null or section.is_empty():
				_finish("", "Could not render the map image.")
				return
			section.convert(Image.FORMAT_RGB8)
			output.blit_rect(section, Rect2i(Vector2i.ONE * MARGIN, section_size), at)
			var fraction := float(row * columns + column + 1) / (rows * columns)
			progress.emit(fraction * 0.9, "Rendering map: %d%%" % roundi(fraction * 100.0))
	viewport.queue_free()
	viewport = null
	progress.emit(0.9, "Writing PNG…")
	_writer = Thread.new()
	var error := _writer.start(func() -> int: return output.save_png(_temporary))
	if error != OK:
		_writer = null
		_finish("", "Could not start saving: " + error_string(error))
		return
	while _writer.is_alive(): await get_tree().process_frame
	error = int(_writer.wait_to_finish())
	_writer = null
	if cancelled:
		_finish("", "Image export canceled.")
	elif error != OK:
		_finish("", "Could not save PNG: " + error_string(error))
	else:
		error = DirAccess.rename_absolute(_temporary, path)
		if error != OK:
			_finish("", "Could not finish saving PNG: " + error_string(error))
		else:
			_temporary = ""
			progress.emit(1.0, "Saved PNG.")
			_finish(path, "")

func cancel() -> void:
	cancelled = true

func _finish(path: String, error: String) -> void:
	if is_instance_valid(viewport): viewport.queue_free()
	viewport = null
	_remove_temporary()
	completed.emit(path, error)

func _remove_temporary() -> void:
	if not _temporary.is_empty():
		DirAccess.remove_absolute(_temporary)
		_temporary = ""

func _exit_tree() -> void:
	cancelled = true
	if _writer != null and _writer.is_started(): _writer.wait_to_finish()
	_remove_temporary()
