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
## Диагностика лок-степа (AUDIT §2.3). Клиент обязан израсходовать РОВНО столько
## кубиков, сколько прислал хост. Раньше несовпадение проходило молча: очередь
## пустела, и клиент незаметно начинал бросать свои. Счётчики ничего не меняют в
## поведении — они лишь позволяют тесту и отладке увидеть расхождение сразу.
var _scripted_mode: bool = false
## Сколько раз бросок ушёл во внутренний RNG, хотя сторона работает по сценарию.
## Строго > 0 — это уже расхождение.
var fallback_rolls: int = 0
## Сколько бросков взято из СОБСТВЕННОГО генератора (M12). Присланные по сценарию
## броски сюда не идут — они не двигают внутренний RNG. По этой паре «зерно + счётчик»
## сохранение возвращает генератор ровно туда, где его застали: само внутреннее
## состояние RNG — 64-битное число, а через JSON такое едет с потерей точности.
var own_rolls: int = 0

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
		if _scripted_mode:
			fallback_rolls += 1
		v = _rng.randi_range(1, 6)
		own_rolls += 1
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
	_scripted_mode = true
	for r in rolls:
		_scripted.append(int(r))

## Диагностика: сколько присланных бросков осталось неиспользованными. После
## применённого действия у клиента должно быть 0.
func scripted_remaining() -> int:
	return _scripted.size()

## Хост: начать запись бросков нового действия (журнал очищается).
func begin_record() -> void:
	record_enabled = true
	_log.clear()

## Хост: забрать записанные броски действия (и очистить журнал).
func take_log() -> Array[int]:
	var out := _log.duplicate()
	_log.clear()
	return out

# --- Сохранение позиции генератора (M12) ---

## Зерно, с которого генератор стартовал. Вместе с own_rolls полностью описывает,
## где он сейчас находится.
func current_seed() -> int:
	return int(_rng.seed)

## Вернуть генератор в точку «зерно + столько-то сделанных бросков». Броски
## прокручиваются вхолостую тем же вызовом, что и в игре, — иначе поток разошёлся бы.
func restore_position(seed_value: int, count: int) -> void:
	_rng.seed = seed_value
	own_rolls = 0
	for _i in count:
		_rng.randi_range(1, 6)
		own_rolls += 1
