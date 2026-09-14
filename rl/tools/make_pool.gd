extends SceneTree

## Стартовый пул карт для фазы A (spec §8.2.2): тестовая арена 34×26 с зеркальными
## армиями из TestSupport — та самая, на которой каждый прогон играет регрессия.
## Остальные карты пула автор делает в редакторе и кладёт рядом (rl/maps/*.json).
##   godot --headless --script res://rl/tools/make_pool.gd

const TS = preload("res://tests/TestSupport.gd")

func _initialize() -> void:
	var m := TS.build_map()
	# Мирные жители в арене остаются в файле: их включает/выключает флаг эпизода.
	var path := ProjectSettings.globalize_path("res://rl/maps/arena_34x26.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var ok := m.save_to(path)
	print("pool: %s (%s)" % [path, "ok" if ok else "FAILED"])
	quit(0 if ok else 1)
