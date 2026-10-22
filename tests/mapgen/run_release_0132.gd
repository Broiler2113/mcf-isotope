extends "res://tests/SuiteBase.gd"

func run() -> void:
	GameConfig.civilians_enabled = false
	var doors := 0
	for style in [MapGen.Style.TOWN, MapGen.Style.FIELD, MapGen.Style.ASTEROID]:
		for seed_value in [11, 132, 991]:
			var map := MapGen.generate({"style": style, "size": 1, "seed": seed_value, "winter": true, "furniture": 3, "civilian_count": 0})
			var grid := Grid.new(map.width, map.height)
			map.apply_to_grid(grid)
			var tiles := TerrainTiles.new(grid, map.env)
			tiles.set_winter(map.winter)
			for cell: GridCell in grid.cells_flat():
				if style == MapGen.Style.ASTEROID:
					ck(not MapFurnish.is_greenery(cell.feature_id), "asteroid contains no trees or greenery")
				if cell.feature_id == MCF.FEATURE_AIRLOCK:
					doors += 1
					ck(cell.floor_type != MCF.FLOOR_GRASS, "door receives actual gameplay floor")
					var name := tiles._floor_name(cell, cell.coord)
					ck(not name.contains("grass") and not name.contains("snow") and not name.contains("dirt"), "door receives constructed floor art: " + name)
	ck(doors > 0, "generated fixtures include doors")
	var map := MapData.blank_arena(12, 10)
	map.env = "field"
	for i in map.floor_type.size(): map.floor_type[i] = MCF.FLOOR_GRASS
	var summer := TerrainTiles.map_preview(map).get_image()
	map.winter = true
	var winter := TerrainTiles.map_preview(map).get_image()
	ck(summer.get_data() != winter.get_data(), "winter preview differs from summer using the same map")
