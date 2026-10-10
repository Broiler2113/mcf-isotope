extends SceneTree

## Field and town borders use grass art, including with flammable terrain off.
## The surrounding wallpaper contains no dirt or concrete patches.

var failures: PackedStringArray = []

func _initialize() -> void:
	for style in [MapGen.Style.FIELD, MapGen.Style.TOWN]:
		for flammable in [false, true]:
			for space in [false, true]:
				_check(style, flammable, space)
	if failures.is_empty():
		print("outer grass: field and town borders and wallpaper are grass in both fire modes")
		quit(0)
		return
	for failure in failures:
		printerr(failure)
	quit(1)

func _check(style: int, flammable: bool, space: bool) -> void:
	var m := MapGen.generate({"style": style, "size": 0, "seed": 97,
			"flammable": flammable, "space": space, "density": 0,
			"civilians": 0, "units": 16})
	var tag := "%s flammable=%s space=%s" % [MapGen.STYLE_NAMES[style],
			str(flammable), str(space)]
	var core := Rect2i(MapGen.BORDER_ALL, MapGen.BORDER_ALL,
			m.width - 2 * MapGen.BORDER_ALL, m.height - 2 * MapGen.BORDER_ALL)
	var rim := Vector2i(-1, -1)
	for y in m.height:
		for x in m.width:
			var c := Vector2i(x, y)
			if core.has_point(c) or m.get_space(c):
				continue
			if rim.x < 0 and m.get_feature(c) == MCF.FEATURE_BOUNDARY:
				rim = c
			var grass_type := m.get_floor(c) == MCF.FLOOR_GRASS
			var grass_look := m.get_look(y * m.width + x) == MCF.Look.GRASS
			if not grass_type and not grass_look:
				failures.append("%s: outer tile %s is not grass" % [tag, str(c)])
				return
			if not flammable and grass_type:
				failures.append("%s: outer tile %s became flammable" % [tag, str(c)])
				return
	var battle: Variant = load("res://scenes/Main.gd").new()
	battle.state = m.build_state(97)
	if not space and (battle._ground_floor_name() != "floor_grass"
			or battle._ground_patch_name() != ""):
		failures.append(tag + ": outer wallpaper uses a non-grass tile")
	if rim.x < 0:
		failures.append(tag + ": no ground cell in the outer rim")
		battle.free()
		return
	var tiles := TerrainTiles.new(battle.state.grid, battle.state.env)
	if tiles._floor_name(battle.state.grid.cell(rim), rim) != "floor_grass":
		failures.append(tag + ": close-up border does not use grass art")
	var rim_color: Color = battle._lod_color(battle.state.grid.cell(rim))
	if rim_color.g - rim_color.r < 0.05:
		failures.append(tag + ": distant border is gray rather than green")
	battle.free()
