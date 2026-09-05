class_name ActionResult
extends RefCounted

## Итог обработки Intent'а резолвером. Возвращается контроллеру и публикуется в лог.

var ok: bool = false
## Причина отказа (для нелегальных намерений).
var reason: String = ""
## Строки боевого лога для UI (§2.2, п.4).
var log_lines: Array[String] = []
## Диагностика бросков для анимации кубиков: [{"kind","rolls","need","...}].
var dice_events: Array = []
## Id юнитов, погибших в этом действии (#46). Мутация (kill) уже применена в
## резолвере; список нужен UI, чтобы ПОКАЗАТЬ смерть только ПОСЛЕ анимации броска
## защиты — иначе труп «спойлерит» исход до кубика.
var deaths: Array[int] = []

static func fail(p_reason: String) -> ActionResult:
	var r := ActionResult.new()
	r.ok = false
	r.reason = p_reason
	return r

static func success(lines: Array[String] = []) -> ActionResult:
	var r := ActionResult.new()
	r.ok = true
	r.log_lines = lines
	return r

func log(line: String) -> void:
	log_lines.append(line)
