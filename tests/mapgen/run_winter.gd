extends "res://tests/SuiteBase.gd"

## Winter changes presentation only, including generated snow scenery and save/load.
func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	var greenery := {}
	var snow := 0
	for style in [MapGen.Style.TOWN, MapGen.Style.FIELD]:
		for seed_value in [11, 83]:
			var options := {"style": style, "seed": seed_value, "size": MapGen.SIZE_CUSTOM,
					"width": 60, "height": 50, "zones": 2, "units": 12, "furniture": 3, "civilian_count": 0}
			var summer := MapGen.generate(options)
			options["winter"] = true
			var winter := MapGen.generate(options)
			ck(winter.winter, "outdoor generator retains winter")
			for fid in winter.feature_id:
				if MapFurnish.is_greenery(fid): greenery[fid] = true
			var a := summer.to_dict()
			var b := winter.to_dict()
			b.erase("winter")
			b.erase("decals")
			a.erase("decals")
			ck(JSON.stringify(a) == JSON.stringify(b), "winter preserves all terrain, cover, objects, zones, lights and spawns, style %d seed %d" % [style, seed_value])
			ck(JSON.stringify(winter.to_dict()) == JSON.stringify(MapGen.generate(options).to_dict()), "snow decoration is deterministic")
			snow += winter.decals.size()
			var restored := MapData.from_dict(JSON.parse_string(JSON.stringify(winter.to_dict())))
			ck(restored.winter and JSON.stringify(restored.decals) == JSON.stringify(winter.decals), "map JSON retains season and snow decorations")
			var state := restored.build_state(8)
			var encoded := StateCodec.encode(state)
			state.winter = false
			StateCodec.restore_into(state, encoded)
			ck(state.winter and state.grid.map_decals == restored.decals, "saved battle retains winter scenery")
	ck(greenery.size() >= 5, "outdoors have varied greenery: %s" % [greenery.keys()])
	ck(snow > 0, "winter maps contain cosmetic snow scenery")
	for style in [MapGen.Style.STATION, MapGen.Style.BUNKER, MapGen.Style.ASTEROID]:
		var map := MapGen.generate({"style": style, "size": 0, "seed": 11, "winter": true, "civilian_count": 0})
		ck(not map.winter, "winter is unavailable in %s" % map.env)
	var legacy := MapData.from_dict(MapData.blank_arena(12, 10).to_dict())
	ck(not legacy.winter, "older maps default to summer")
	var station := MapGen.generate({"style": MapGen.Style.STATION, "size": 4, "seed": 11, "furniture": 3, "civilian_count": 0})
	ck(station.feature_id.has("planter_bed") and station.feature_id.has("hydroponic_rack"), "large station botany bays contain planters and hydroponics")
