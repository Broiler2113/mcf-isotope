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
## Описания КОСМЕТИЧЕСКИХ эффектов (#21): щебень, осколки, гильзы, кровь.
## На правила не влияют совсем — их не читает ни резолвер, ни ИИ, ни слепок доски.
## По сети не едут: клиент выполняет то же намерение тем же резолвером и получает
## тот же список, а разброс каждой частицы FxDecals выводит из самого описания.
var fx: Array = []
## Прежний вид клеток/техники ДО взрыва (item 22): {"cells": {Vector2i: {...}},
## "vehicles": {vid: {...}}}. Чисто для показа — UI рисует эти старые значения, пока
## крутится кубик выстрела, чтобы разрушения и снятая прочность не «спойлерили» до
## броска. На правила и слепок доски не влияет и по сети не едет (как и fx).
var visual_hold: Dictionary = {}

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
