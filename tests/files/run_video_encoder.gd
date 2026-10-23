extends "res://tests/SuiteBase.gd"

func run() -> void:
	var executable := ReplayVideoEncoder.find_ffmpeg()
	if executable.is_empty():
		print("FFmpeg not installed; video encoder integration skipped")
		return
	var path := "/tmp/isotope-encoder-test.mp4" if OS.get_name() != "Windows" else OS.get_environment("TEMP").path_join("isotope-encoder-test.mp4")
	var encoder := ReplayVideoEncoder.new()
	ck(encoder.start(executable, path, Vector2i(64, 48), 30).is_empty(), "FFmpeg launches without a shell")
	var image := Image.create(64, 48, false, Image.FORMAT_RGB8)
	for i in 30:
		image.fill(Color(float(i) / 30, 0.3, 0.1))
		while not encoder.push(image.get_data()) and not encoder.status().done: await process_frame
	encoder.finish()
	var deadline := Time.get_ticks_msec() + 15000
	while not encoder.status().done and Time.get_ticks_msec() < deadline: await process_frame
	if not encoder.status().done: encoder.cancel()
	encoder.join()
	ck(encoder.status().error.is_empty(), "encoder completes: " + str(encoder.status().error))
	ck(FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path).size() > 500, "encoded MP4 exists")
	var original := FileAccess.get_file_as_bytes(path)
	var cancelled := ReplayVideoEncoder.new()
	ck(cancelled.start(executable, path, Vector2i(64, 48), 30).is_empty(), "second encoder starts")
	cancelled.cancel()
	cancelled.join()
	ck(FileAccess.get_file_as_bytes(path) == original, "cancelling preserves an existing destination")
