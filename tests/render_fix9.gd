extends SceneTree

## Rendered acceptance for fix 9. Images: /tmp/isotope-fix9-*.png.
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(2)
		return
	root.size = Vector2i(900, 600)
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	root.get_node("Ui").dynamic_lighting = false
	var map := MapData.blank_arena(20, 18)
	map.env = "station"
	for x in range(3, 17):
		map.set_cell(Vector2i(x, 5), 0, 0, false, MCF.FEATURE_AIRLOCK if x == 8 else MCF.FEATURE_WALL)
	for fid in [MCF.FEATURE_DOT, MCF.FEATURE_LDF, MCF.FEATURE_DOT_OPEN]:
		map.set_cell(Vector2i(11 + [MCF.FEATURE_DOT, MCF.FEATURE_LDF, MCF.FEATURE_DOT_OPEN].find(fid), 7), 0, 0, false, fid)
	map.set_cell(Vector2i(7, 8), 0, 0, false, MCF.FEATURE_DRONE_STATION)
	map.set_spawn(Vector2i(12, 10), "shuttle", 0)
	var grid := Grid.new(map.width, map.height)
	map.apply_to_grid(grid)
	grid.wall_accent.resize(map.width * map.height)
	grid.wall_accent.fill(1)
	var tiles := TerrainTiles.new(grid, map.env)
	var host := FirstPersonHost.new(map, tiles)
	root.add_child(host)
	host._bodies[Vector2i(6, 9)] = [null, 2]
	tiles.decals[Vector2i.ZERO] = []
	for k in 6:
		tiles.decals[Vector2i.ZERO].append({"kind": "chunk:wall#%d" % k,
				"pos": Vector2(6.1 + (k % 3) * 0.3, 8.1 + (k / 3) * 0.4), "rot": k * 0.3, "scale": 1.0})
	var fp = load("res://scenes/main/FirstPerson.gd").new(host, Vector2i(8, 10))
	root.add_child(fp)
	for i in 8: await process_frame
	fp.set_process(false)
	for shot in [
		["station", Vector3(8.5, 0, 10.2), 0.5, -0.6],
		["fortifications", Vector3(12.5, 0, 10), 0.0, -0.05],
		["door-closed", Vector3(8.5, 0, 8), 0.0, 0.0],
		["door-open", Vector3(8.5, 0, 6.5), 0.0, 0.0],
		["shuttle", Vector3(15.8, 0, 14), 0.75, -0.12],
		["combat", Vector3(8.5, 0, 12), 0.0, -0.1],
	]:
		fp.pos = shot[1]
		fp.yaw = shot[2]
		fp.pitch = shot[3]
		fp._doors(1.0)
		fp._place_camera()
		fp._sync_features()
		fp._sync_units()
		if shot[0] == "combat":
			host._fx.apply([{"fx": "laser", "from": [5, 8], "to": [10, 8]},
					{"fx": "shot", "kind": "rocket", "from": [6, 9], "to": [11, 9]},
					{"fx": "shot", "kind": "shell", "from": [6, 10], "to": [11, 10]},
					{"fx": "tracer", "from": [5, 7], "to": [10, 7]}])
			host._fx.advance(0.04)
			host._fx.flashes.append({"cells": [Vector2i(10, 9)], "t": 0.04, "dur": 0.4})
			fp._sync_combat_fx()
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		fp._vp.get_texture().get_image().save_png("/tmp/isotope-fix9-%s.png" % shot[0])
		print("Rendered ", shot[0])
	fp.free()
	host.free()
	quit()
