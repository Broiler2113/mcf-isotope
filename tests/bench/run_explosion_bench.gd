extends SceneTree

## Informational CPU benchmark; timings depend on the renderer and machine.
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var scripts: Array[GDScript] = []
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		var old := GDScript.new()
		old.source_code = FileAccess.get_file_as_string(args[0]).replace("class_name TerrainTiles\n", "")
		if old.reload() != OK:
			quit(1)
			return
		scripts.append(old)
	scripts.append(load("res://src/ui/TerrainTiles.gd"))
	for script: GDScript in scripts:
		var grid := Grid.new(48, 48)
		var tiles = script.new(grid, "town")
		var fx := FxDecals.new()
		tiles.sync_decals(fx)
		for y in 3:
			for x in 3: tiles._build(Vector2i(x, y), 32)
		var cells: Array[Vector2i] = []
		var events: Array = []
		for y in range(12, 20):
			for x in range(12, 20):
				var c := Vector2i(x, y)
				cells.append(c)
				if (x + y) % 3 == 0:
					events.append({"fx": "chunks", "at": c, "from": Vector2i(16, 16), "fid": "wall", "env": "town", "look": 0, "seq": x * 48 + y})
		events.append({"fx": "debris", "at": Vector2i(16, 16), "cells": cells, "blast": true, "seq": 1000})
		var start := Time.get_ticks_usec()
		fx.apply(events)
		var apply_ms := (Time.get_ticks_usec() - start) / 1000.0
		tiles.sync(fx.floor_damage, fx.damage_version)
		tiles.sync_decals(fx)
		tiles._built = 0
		start = Time.get_ticks_usec()
		for y in 3:
			for x in 3: tiles._choose(Vector2i(x, y), 32)
		var impact_ms := (Time.get_ticks_usec() - start) / 1000.0
		print("%s: effects %.2f ms, impact texture rebuilds %.2f ms (%d chunks)" % ["after" if script == scripts.back() else "before", apply_ms, impact_ms, tiles._built])
	quit()
