extends SceneTree

var failures: Array[String] = []
func check(ok: bool, why: String) -> void:
	if not ok:
		failures.append(why)
		print("FAIL " + why)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	for size in [0, 1, 2]:
		for seed in range(1, 9):
			var g := MapGen.build({"style": MapGen.Style.TOWN, "size": size, "seed": seed, "furniture": 2})
			for house: Rect2i in g._rooms:
				if str(g._room_kind.get(house, "")) not in ["house", "apartments"]: continue
				var has_room := false
				var has_toilet := false
				for room: Rect2i in g._bathrooms:
					if not house.encloses(room): continue
					has_room = true
					for c in g._rect_cells(room):
						if Furniture.base_of(g.m.get_feature(c)) == "toilet": has_toilet = true
				check(has_room and has_toilet, "town size %d seed %d house %s has restroom and toilet (room=%s toilet=%s)" % [size, seed, house, has_room, has_toilet])
			for i in g.w * g.h:
				if not MCF.is_glass(g.m.feature_id[i]): continue
				check(g.m.get_look(i) < MCF.WALL_LOOK_BASE and g.m.floor_type[i] != MCF.FLOOR_GRASS, "windows have interior floor, seed %d cell %d" % [seed, i])
			_verify_room_lights(g, seed)
			_verify_parks(g, seed)
			var station := MapGen.build({"style": MapGen.Style.STATION, "size": size, "seed": seed, "furniture": 2})
			_verify_station(station, seed)
	for options in [{"size": 0, "seed": 21, "obstacles": false}, {"size": 2, "seed": 22, "symmetric": true, "zones": 4}, {"size": 3, "seed": 13},
			{"size": MapGen.SIZE_CUSTOM, "width": 16, "height": 16, "units": 1, "seed": 24}, {"size": 4, "seed": 25}, {"size": 5, "seed": 26}]:
		options["style"] = MapGen.Style.STATION
		_verify_station(MapGen.build(options), options.seed)
	check(not LightManager.source_on({"id": "streetlight"}, "day"), "streetlights off by day")
	check(LightManager.source_on({"id": "streetlight"}, "night"), "streetlights on at night")
	print("remaining generation: %d failure(s)" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _verify_station(g: MapGen, seed: int) -> void:
	var production := false
	var engineering := false
	for sector in g._dept_sectors:
		if sector[1] == "production": production = true
		if sector[1] == "engineering": engineering = true
	check(engineering, "station %s seed %d has engineering" % [g._core.size, seed])
	var workstations := 0
	var solar := 0
	var docking := 0
	for i in g.w * g.h:
		if g.m.get_look(i) == MCF.Look.SOLAR: solar += 1
		if g.m.feature_id[i] == "machine_workstation": workstations += 1
		if g.m.feature_id[i] != MCF.FEATURE_AIRLOCK: continue
		if g.m.get_door(i) >= 16: docking += 1
		var c := Vector2i(i % g.w, i / g.w)
		for direction: Vector2i in MapGen.N4:
			if not g.m.get_space(c + direction): continue
			var inside := c - direction
			var inner := c - direction * 2
			check(g.m.get_door(i) >= 16 and not g.m.get_space(inside) and g.m.get_cover(inside) < MCF.WALL_HEIGHT and g.m.get_feature(inner) == MCF.FEATURE_AIRLOCK and g.m.get_door(inner.y * g.w + inner.x) >= 16,
					"station seed %d exterior door %s has one-tile chamber and secondary docking door" % [seed, c])
	if production:
		check(workstations > 0, "station seed %d with production has machine workstations" % seed)
	check(solar > 0, "station %s seed %d has solar panels" % [g._core.size, seed])
	check(docking >= 2, "station %s seed %d has paired docking doors" % [g._core.size, seed])

func _verify_parks(g: MapGen, seed: int) -> void:
	var full_parks := 0
	for park in g._parks:
		var found := {}
		for c in g._rect_cells(park):
			found[Furniture.base_of(g.m.get_feature(c))] = true
			if g.m.get_look(c.y * g.w + c.x) == MCF.Look.DIRT: found["path"] = true
		if found.has("bench") and found.has("park_tree") and found.has("vending_machine") and found.has("path"): full_parks += 1
	check(full_parks > 0, "town %s seed %d has a park with paths, trees, benches and vending" % [g._core, seed])

func _verify_room_lights(g: MapGen, seed: int) -> void:
	var lights := MapLighting.new()
	lights.g = g
	lights.map = g.m
	lights.coverage.resize(g.w * g.h)
	lights._index_geometry()
	for i in g.w * g.h:
		var c := Vector2i(i % g.w, i / g.w)
		var fid := g.m.feature_id[i]
		if Furniture.emits_light(fid): lights._illuminate(c, fid)
		for lamp: Array in g.m.fixtures.get(i, []): lights._illuminate(c, lamp[0], int(lamp[2]))
	for room in g._bathrooms:
		var brightest := 0.0
		for c in g._rect_cells(room): brightest = maxf(brightest, lights.coverage[c.y * g.w + c.x])
		check(brightest >= MapLighting.ROOM_TARGET, "town seed %d restroom %s has light on its own side of the wall" % [seed, room])
