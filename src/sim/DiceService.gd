class_name DiceService
extends RefCounted

## Единая точка всех бросков кубиков (см. §2.2, §2.3).
## В сетевой игре авторитетен хост: он бросает и ЗАПИСЫВАЕТ результаты (record),
## а клиент их ВОСПРОИЗВОДИТ (feed_scripted) — сам не бросает. Так дублируется
## единственное место броска на обеих сторонах без рассинхрона RNG.

var _rng := RandomNumberGenerator.new()
## Очередь заранее заданных результатов (клиент). Пусто — бросаем сами (хост).
var _scripted: Array[int] = []
## Журнал фактических результатов текущего действия (для отправки клиенту).
var _log: Array[int] = []
var record_enabled: bool = false

func _init(seed_value: int = -1) -> void:
	if seed_value >= 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()

func roll_d6() -> int:
	var v: int
	if not _scripted.is_empty():
		v = _scripted.pop_front()
	else:
		v = _rng.randi_range(1, 6)
	if record_enabled:
		_log.append(v)
	return v

func roll_d6_many(n: int) -> Array[int]:
	var out: Array[int] = []
	for _i in n:
		out.append(roll_d6())
	return out

# --- Сетевой режим (§2.3) ---

## Клиент: задать точную последовательность результатов для следующего действия.
func feed_scripted(rolls: Array) -> void:
	_scripted.clear()
	for r in rolls:
		_scripted.append(int(r))

## Хост: начать запись бросков нового действия (журнал очищается).
func begin_record() -> void:
	record_enabled = true
	_log.clear()

## Хост: забрать записанные броски действия (и очистить журнал).
func take_log() -> Array[int]:
	var out := _log.duplicate()
	_log.clear()
	return out
