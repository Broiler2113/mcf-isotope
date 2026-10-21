extends "res://tests/SuiteBase.gd"
## Effects: decals kept without caps, drifting vacuum debris, decal memory and undo.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_no_caps()

	MainScript = load("res://scenes/Main.gd")
	ManualWindowScript = load("res://src/ui/ManualWindow.gd")
	ManualTextScript = load("res://src/ui/ManualText.gd")
	BugReportScript = load("res://src/ui/BugReportWindow.gd")
	SettingsScript = load("res://src/ui/SettingsWindow.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.fog_mode = MCF.Fog.OFF
	await _space_boundary()

	decal_undo()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_vacuum_debris()
	_decal_memory()
	await _effects_run_while_typing()

## Decals are never evicted (owner: "remove all decal caps").
func _no_caps() -> void:
	var fx := FxDecals.new()
	for i in 2500:
		fx.apply([{"fx": "laser", "from": [0, i % 40], "to": [30, i % 40]}])
	ck(fx.laser_lines.size() >= 2500, "laser scorches are all kept (%d)" % fx.laser_lines.size())
	ck(not ("PROPS_CAP" in FxDecals) and not ("LASER_CAP" in FxDecals), "the decal caps are gone")

var MainScript: GDScript

var ManualWindowScript: GDScript

var ManualTextScript: GDScript

var BugReportScript: GDScript

var SettingsScript: GDScript

func _space_boundary() -> void:
	var m := MapData.blank_arena(16, 12)
	m.env = "station"
	m.set_spawn(Vector2i(3, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 1)
	m.set_cell(Vector2i(15, 5), 0, 2.0, true, MCF.FEATURE_BOUNDARY)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	ck(not main._fx.solid_at.call(Vector2i(15, 5)) and not main._fx.solid_at.call(Vector2i(30, 5)) and main._fx.space_at.call(Vector2i(30, 5)), "space particles ignore invisible boundary and keep vacuum outside grid")
	main._fx.flying = [{"kind": "glass_shard", "from": Vector2(14.5, 5.5), "to": Vector2(17.5, 5.5), "t": 0.0, "dur": 1.0, "drift": true, "rot0": 0.0, "rot1": 1.0, "scale": 1.0}]
	var saved_fx: Dictionary = main._fx.to_dict()
	var checkpoint := ReplayCheckpoint.effects(main.state)
	checkpoint.from_dict(saved_fx)
	checkpoint.advance(100.0)
	ck(checkpoint.flying.size() == 1 and checkpoint.flying[0].origin == Vector2i(14, 5), "replay checkpoints preserve off-map drift and its visible origin")
	main._fx.advance(100.0)
	ck(main._fx.flying.size() == 1 and FxDecals.flight_pos(main._fx.flying[0]).x > 300, "debris drifts indefinitely beyond boundary")
	main.free()

## Undo cuts the decal lists back chunk by chunk (#4): the index stays exact and chunks the
## undone action never touched keep their bucket, so nothing downstream rebuilds them.
func decal_undo() -> void:
	var fx := FxDecals.new()
	for i in 400:
		fx._settle(fx.props if i % 2 else fx.gore,
			{"kind": "casing" if i % 2 else "blood_drop", "pos": Vector2(1.5 + (i % 40), 1.5 + (i / 40) * 3), "rot": 0.0, "scale": 1.0})
	var snap := fx.capture_state()
	var untouched: Array = fx.by_chunk[Vector2i(0, 0)]
	for i in 20:
		fx._settle(fx.props, {"kind": "shard", "pos": Vector2(30.5, 20.5), "rot": 0.0, "scale": 1.0})
	fx._sweep_props({"at": Vector2i(5, 1), "from": Vector2i(4, 1)})
	fx.restore_state(snap)
	var ref := FxDecals.new()
	ref.gore = fx.gore
	ref.props = fx.props
	ref._reindex()
	var exact := ref.by_chunk.size() == fx.by_chunk.size()
	for cc: Vector2i in ref.by_chunk:
		var a: Array = fx.by_chunk.get(cc, [])
		var b: Array = ref.by_chunk[cc]
		exact = exact and a.size() == b.size() and b.all(func(q: Dictionary) -> bool: return a.has(q))
	ck(exact, "after undo the decal index matches the restored lists")
	ck(is_same(fx.by_chunk[Vector2i(0, 0)], untouched), "an untouched chunk keeps its bucket through undo")

func _vacuum_debris() -> void:
	var fx := FxDecals.new()
	fx.bounds = Vector2(40, 40)
	fx.space_at = func(_c: Vector2i) -> bool: return true
	fx.apply([{"fx": "chunks", "at": Vector2i(20, 20), "from": Vector2i(19, 20), "seq": 7}])
	var n := fx.flying.size()
	fx.advance(0.6)
	var before := FxDecals.flight_pos(fx.flying[0])
	fx.advance(0.4)
	ck(fx.flying.size() == n and fx.props.is_empty(), "vacuum debris remains airborne after its normal landing time")
	ck(before.distance_to(FxDecals.flight_pos(fx.flying[0])) > 0.1, "vacuum debris retains momentum")
	var saved := fx.to_dict()
	var loaded := FxDecals.new()
	loaded.space_at = fx.space_at
	loaded.bounds = fx.bounds
	loaded.from_dict(saved)
	ck(loaded.flying.size() == n and loaded.props.is_empty(), "save/load preserves drifting debris without freezing it on space")
	fx.advance(100.0)
	ck(fx.flying.size() == n and fx.props.is_empty(), "debris keeps drifting beyond the edge of space")

func _decal_memory() -> void:
	var fx := FxDecals.new()
	fx._settle(fx.props, {"kind": "casing", "pos": Vector2(1.5, 1.5), "rot": 0.0, "scale": 1.0})
	var memory := DecalMemory.new(fx)
	var visible := {Vector2i(1, 1): true, Vector2i(33, 1): true}
	memory.update(fx, visible, null, 64)
	fx._settle(fx.gore, {"kind": "blood_pool", "pos": Vector2(33.5, 1.5), "rot": 0.0, "scale": 1.0})
	memory.update(fx, visible, [], 64)
	ck(memory.view.by_chunk.get(Vector2i(2, 0), []).size() == 1, "new blood appears in a visible chunk even after props already exist")

## fix-7: while the chat line has focus the camera stays put, but flashes, tracers and
## debris keep playing out instead of freezing on screen.
func _effects_run_while_typing() -> void:
	GameConfig.roster = Roster.default_duel(false)
	var m := MapData.blank_arena(16, 10)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(12, 7), "light_infantry", 1)
	MapHandoff.pending = m
	var main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._fx.apply([{"fx": "flash", "cells": [Vector2i(5, 5)]}])
	var typing := LineEdit.new()
	main._ui_layer.add_child(typing)
	typing.grab_focus()
	main._process(0.6)
	main._process(0.6)
	ck(main._fx.flashes.is_empty(), "an explosion flash fades while the player types in the chat")
	main.queue_free()
	await process_frame
