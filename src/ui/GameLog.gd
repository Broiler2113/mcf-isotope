class_name GameLog
extends Logger

## Журнал движка в памяти (0.12, «Report a Bug»). Запись логов в файл в проекте выключена,
## поэтому то, что игра печатала и на что ругалась, держится здесь — последние KEEP строк
## по кругу — и уезжает с отчётом об ошибке. Вызовы приходят из любых потоков: под мьютексом.

const KEEP := 1500

static var _ring: PackedStringArray = []
static var _head := 0
static var _mutex := Mutex.new()
static var _installed: GameLog = null

## Подключить один раз на всю игру (из автозагрузки Ui).
static func install() -> void:
	if _installed != null:
		return
	_installed = GameLog.new()
	OS.add_logger(_installed)

func _log_message(message: String, error: bool) -> void:
	_push(("ERROR: " if error else "") + message.strip_edges(false, true))

func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtrace: Array[ScriptBacktrace]) -> void:
	var kind := "WARNING" if error_type == ERROR_TYPE_WARNING else "ERROR"
	_push("%s: %s (%s:%d in %s)" % [kind, rationale if rationale != "" else code, file, line, function])

static func _push(line: String) -> void:
	_mutex.lock()
	if _ring.size() < KEEP:
		_ring.append(line)
	else:
		_ring[_head] = line
		_head = (_head + 1) % KEEP
	_mutex.unlock()

## Всё накопленное, от старого к новому.
static func text() -> String:
	_mutex.lock()
	var out := PackedStringArray()
	for i in _ring.size():
		out.append(_ring[(_head + i) % _ring.size()])
	_mutex.unlock()
	return "\n".join(out)
