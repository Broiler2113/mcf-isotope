class_name ReplayVideoEncoder
extends RefCounted

## Bounded producer/consumer pipe: rendering stays on the main thread, encoding and
## blocking pipe writes stay on the worker. No temporary image sequence is needed.
var _thread := Thread.new()
var _mutex := Mutex.new()
var _ready := Semaphore.new()
var _frames: Array[PackedByteArray] = []
var _finished := false
var _cancelled := false
var _done := false
var _error := ""
var _pid := -1
var _output := ""
var _temporary := ""
var _bytes_per_frame := 0

static func find_ffmpeg(preferred := "") -> String:
	if not preferred.is_empty() and FileAccess.file_exists(preferred): return preferred
	for path in OS.get_environment("PATH").split(";" if OS.get_name() == "Windows" else ":"):
		var candidate := path.path_join("ffmpeg.exe" if OS.get_name() == "Windows" else "ffmpeg")
		if FileAccess.file_exists(candidate): return candidate
	for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]:
		if FileAccess.file_exists(candidate): return candidate
	return ""

func start(executable: String, destination: String, resolution: Vector2i, fps: int) -> String:
	if _thread.is_started(): return "An export is already running."
	if resolution.x < 2 or resolution.y < 2 or resolution.x % 2 or resolution.y % 2 or fps < 1: return "Choose an even video resolution and a positive frame rate."
	_output = destination
	_temporary = destination + ".%d.part.mp4" % Time.get_ticks_usec()
	_bytes_per_frame = resolution.x * resolution.y * 3
	var args := PackedStringArray(["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
		"-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "%dx%d" % [resolution.x, resolution.y],
		"-framerate", str(fps), "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "fast",
		"-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", _temporary])
	var process := OS.execute_with_pipe(executable, args, true)
	if process.is_empty(): return "Could not start FFmpeg. Select a working FFmpeg executable."
	_pid = int(process.pid)
	var result := _thread.start(_encode.bind(process))
	if result != OK:
		OS.kill(_pid)
		return "Could not start the video encoding worker."
	return ""

func push(frame: PackedByteArray) -> bool:
	_mutex.lock()
	var accept := not _done and not _cancelled and _frames.size() < 2 and frame.size() == _bytes_per_frame
	if accept: _frames.append(frame)
	_mutex.unlock()
	if accept: _ready.post()
	return accept

func finish() -> void:
	_mutex.lock()
	_finished = true
	_mutex.unlock()
	_ready.post()

func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_frames.clear()
	if not _done and _pid > 0 and OS.is_process_running(_pid): OS.kill(_pid)
	_mutex.unlock()
	_ready.post()

func status() -> Dictionary:
	_mutex.lock()
	var value := {"done": _done, "error": _error, "canceled": _cancelled}
	_mutex.unlock()
	return value

func join() -> void:
	if _thread.is_started(): _thread.wait_to_finish()

func _encode(process: Dictionary) -> void:
	var pipe: FileAccess = process.stdio
	var failure := ""
	while true:
		_ready.wait()
		_mutex.lock()
		var stop := _cancelled
		var finish_now := _finished and _frames.is_empty()
		var frame: PackedByteArray = _frames.pop_front() if not _frames.is_empty() else PackedByteArray()
		_mutex.unlock()
		if stop or finish_now: break
		if frame.is_empty(): continue
		pipe.store_buffer(frame)
		if pipe.get_error() != OK:
			failure = "FFmpeg stopped accepting video frames."
			break
	pipe.close()
	var code := -1
	while true:
		_mutex.lock()
		var killed := _cancelled
		var running := not killed and OS.is_process_running(_pid)
		if not killed and not running: code = OS.get_process_exit_code(_pid)
		_mutex.unlock()
		if killed or not running: break
		OS.delay_msec(20)
	var details: String = process.stderr.get_as_text().strip_edges()
	process.stderr.close()
	_mutex.lock()
	if not _cancelled:
		if code != 0 or not failure.is_empty(): _error = "Video encoding failed: " + (details.left(1500) if not details.is_empty() else failure + " (exit %d)" % code)
		elif not FileAccess.file_exists(_temporary): _error = "FFmpeg did not produce a video file."
		elif DirAccess.rename_absolute(_temporary, _output) != OK: _error = "Could not save the completed video to the selected location."
	if FileAccess.file_exists(_temporary): DirAccess.remove_absolute(_temporary)
	_done = true
	_mutex.unlock()
