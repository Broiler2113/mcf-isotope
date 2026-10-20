extends "res://tests/SuiteBase.gd"
## Board art: pieces drawn whole, lamps and glow tints, height numbers, doors filling the
## tile, space without tiles, texture folders, welded airlocks, chunk rebuild budget.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_piece_pictures()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_lamp_brightness()
	_height_numbers()
	_open_door_see_through()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	ck(TerrainTiles.height_text(0.0, false, MCF.FEATURE_TRENCH) == "-2", "a trench reads -2 on the heightmap")

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_lamp_levels()
	_glow_tint()

	_doors_fill_the_tile()
	_space_has_no_tile()
	if fails.is_empty():
		print("batch 0.9.3: accents, grill, corridors, doors, the border, empty space"
				+ " and corpse-pile clearing all hold")
	else:
		print("batch 0.9.3: %d failure(s)" % fails.size())

	_textures_live_in_folders()
	if fails.is_empty():
		print("batch 0.9.4: counts, events, raiders, tunnels, asteroid plating and texture"
				+ " folders all hold")
	else:
		print("batch 0.9.4: %d failure(s)" % fails.size())

	_tiles()

	MainScript = load("res://scenes/Main.gd")
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	GameConfig.p1_is_ai = false
	GameConfig.p2_is_ai = false
	GameConfig.fog_mode = MCF.Fog.OFF
	_texture_budget()

	_welded_airlock_tile()

## A fixed-size piece is one picture: each cell shows its part, turned with the piece (0.11).
func _piece_pictures() -> void:
	var g := Grid.new(8, 6)
	for c: Vector2i in [Vector2i(1, 1), Vector2i(2, 1)]: g.cell(c).set_feature("piano")
	for c: Vector2i in [Vector2i(5, 1), Vector2i(5, 2)]:
		g.cell(c).set_feature("piano")
		g.furniture_turn[c] = ["piano", 1]
	var t := TerrainTiles.new(g, "station")
	var piece: Image = Sprites.texture_of("piano_piece").get_image()
	piece.convert(Image.FORMAT_RGBA8)
	var part := func(img: Image, at: Vector2i) -> PackedByteArray:
		return img.get_region(Rect2i(at * 32, Vector2i(32, 32))).get_data()
	ck(t._furniture_image(Vector2i(1, 1), "piano", 32).get_data() == part.call(piece, Vector2i(0, 0))
			and t._furniture_image(Vector2i(2, 1), "piano", 32).get_data() == part.call(piece, Vector2i(1, 0)),
			"a piano shows its own picture across both cells")
	var turned: Image = piece.duplicate()
	turned.rotate_90(CLOCKWISE)
	ck(t._furniture_image(Vector2i(5, 2), "piano", 32).get_data() == part.call(turned, Vector2i(0, 1)),
			"a turned piano shows the turned picture")
	g.cell(Vector2i(2, 1)).clear_feature()
	var lone := TerrainTiles.new(g, "station")
	ck(lone._furniture_image(Vector2i(1, 1), "piano", 32).get_data() != part.call(piece, Vector2i(0, 0)),
			"half a piano falls back to the sheet")

## Colour and brightness share the tint byte; a 0.11 byte (colour only) reads unchanged.
func _lamp_brightness() -> void:
	var t := Furniture.make_tint(4, 5)
	ck(Furniture.tint_colour(t) == 4 and Furniture.tint_level(t) == 5, "tint byte packs colour and brightness")
	ck(Furniture.light_color_of("wall_lamp", t) == Furniture.LIGHT_TINTS[4][1], "brightness keeps the chosen colour")
	ck(Furniture.light_scale_of(3) == 1.0, "a 0.11 colour-only byte is normal brightness")
	# 0.12.1 filled all 16 brightness steps; only an unknown colour can still fall back.
	ck(Furniture.clean_tint(0x0F) == 0 and Furniture.tint_level(Furniture.clean_tint(0xF0)) == 15,
			"an unknown color falls back to the lamp's own; every brightness step is valid")
	var g := Grid.new(4, 4)
	g.cell(Vector2i(1, 1)).set_feature("streetlight")
	g.light_tint.resize(16)
	g.light_tint[1 * 4 + 1] = Furniture.make_tint(0, 5)   # 200 %
	var occ := LightOccluders.new()
	occ.sync(g)
	var e: Dictionary = occ.sources[Vector2i(1, 1)][0]
	var base: Dictionary = Furniture.DEFS["streetlight"]
	ck(is_equal_approx(float(e.energy), float(base.get("light_energy", 0.85)) * 2.0), "200 % doubles the glow")
	ck(float(e.range) > float(base.get("light_range", 6.0)), "a brighter lamp reaches further")
	var m := MapData.blank_arena(6, 6)
	m.fixtures[2 * 6] = MapData.valid_lamps([["wall_lamp", 1, 1, Furniture.make_tint(2, 1)]])
	ck(int(m.fixtures[2 * 6][0][3]) == Furniture.make_tint(2, 1), "wall lamp records keep brightness")

func _height_numbers() -> void:
	ck(TerrainTiles.height_text(0.5) == "0.5" and TerrainTiles.height_text(1.0) == "1"
			and TerrainTiles.height_text(2.0) == "2" and TerrainTiles.height_text(1.5) == "1.5",
			"heights read as plain numbers")
	ck(TerrainTiles.height_text(0.0) == "" and TerrainTiles.height_text(1.0, true) == "",
			"open ground and space carry no number")

## An open door is drawn without a wall behind it: the middle of the doorway is clear.
func _open_door_see_through() -> void:
	var g := Grid.new(5, 5)
	for x in 5: g.cell(Vector2i(x, 2)).set_feature(MCF.FEATURE_WALL)
	var d := Vector2i(2, 2)
	g.cell(d).set_feature(MCF.FEATURE_AIRLOCK)
	var tiles := TerrainTiles.new(g, "station")
	var closed := tiles._door_image(g, d, g.cell(d), 32, true)
	g.cell(d).cover_height = 0.0   # open
	var open := tiles._door_image(g, d, g.cell(d), 32)
	ck(closed.get_pixel(16, 16).a > 0.9, "a closed door is solid")
	ck(open.get_pixel(14, 16).a < 0.05, "an open doorway shows the floor beneath")

## Every brightness step × color is a valid lamp byte, and the lamp menu's ids (colors,
## brightness steps, Type a value, Remove) never collide: the 300 % red lamp used to equal
## Remove and vanished.
func _lamp_levels() -> void:
	var editor: GDScript = load("res://scenes/MapEditor.gd")
	var bad := 0
	for l in Furniture.LIGHT_LEVELS.size():
		for c in Furniture.LIGHT_TINTS.size():
			var t := Furniture.make_tint(c, l)
			if Furniture.clean_tint(t) != t:
				bad += 1
	ck(bad == 0, "every brightness/color pair is a valid lamp byte (%d bad)" % bad)
	var ids := {}
	for c in Furniture.LIGHT_TINTS.size(): ids[c] = true
	for l in Furniture.LIGHT_LEVELS.size(): ids[int(editor.LIGHT_LEVEL_ID) + l] = true
	ids[int(editor.LIGHT_TYPE_ID)] = true
	ids[int(editor.LIGHT_REMOVE)] = true
	ck(ids.size() == Furniture.LIGHT_TINTS.size() + Furniture.LIGHT_LEVELS.size() + 2, "lamp menu ids never collide")
	ck(Furniture.LIGHT_LEVELS.size() <= 16, "brightness steps still fit the tint byte's four bits")
	ck(float(Furniture.LIGHT_LEVELS[Furniture.level_for_percent(300)][1]) == 3.0, "300 % types to the 300 % step")
	ck(float(Furniture.LIGHT_LEVELS[Furniture.level_for_percent(333)][1]) == 3.5, "333 % snaps to the nearest step (350 %)")
	ck(float(Furniture.LIGHT_LEVELS[Furniture.level_for_percent(9)][1]) == 0.1, "a tiny value snaps to 10 %")

## Recoloring a glowing object recolors its sprite's glow (a console's green screen turns
## red), keeps its body as drawn, and white lamp glass still takes the color.
func _glow_tint() -> void:
	var tt: GDScript = load("res://src/ui/TerrainTiles.gd")
	var img := Image.create(4, 1, false, Image.FORMAT_RGBA8)
	var screen := Furniture.base_light_color("console").darkened(0.15)
	img.set_pixel(0, 0, screen)
	img.set_pixel(1, 0, Color(0.22, 0.24, 0.26))
	img.set_pixel(2, 0, Color("#9ea3a8"))   # the console's keyboard
	img.set_pixel(3, 0, Color(0.97, 0.96, 0.92))   # a white light panel (vending machine)
	var red: Color = Furniture.LIGHT_TINTS[4][1]
	var out: Image = tt.tint_lamp(img, red, Furniture.base_light_color("console"))
	var s0 := out.get_pixel(0, 0)
	ck(absf(s0.h - red.h) < 0.03 or absf(s0.h - red.h) > 0.97, "the console's green screen takes the new color (hue %.2f)" % s0.h)
	ck(absf(s0.v - screen.v) < 0.03, "at the same brightness")
	ck(out.get_pixel(1, 0).is_equal_approx(img.get_pixel(1, 0)), "the dark body is left as drawn")
	ck(out.get_pixel(2, 0).is_equal_approx(img.get_pixel(2, 0)), "the console's grey keys stay as drawn")
	ck(not out.get_pixel(3, 0).is_equal_approx(img.get_pixel(3, 0)), "a white light panel takes the color")
	var lamp: Image = tt.tint_lamp(img, red)
	ck(not lamp.get_pixel(3, 0).is_equal_approx(img.get_pixel(3, 0)), "a white lamp's glass still takes the color")

## Дверь занимает клетку целиком: у плитки нет ни одного полностью прозрачного столбца или
## ряда по краям — раньше по бокам оставались поля, и в проёме просвечивала стена.
func _doors_fill_the_tile() -> void:
	Sprites.reload_overrides()
	var thin: Array[String] = []
	for name: String in ["door", "door_station", "door_bunker", "door_town", "door_field",
			"door_asteroid", "door_open", "door_open_station", "door_open_bunker"]:
		var tex := Sprites.texture_of(name)
		if tex == null:
			thin.append(name + " (missing)")
			continue
		var img := tex.get_image()
		if img.is_compressed():
			img.decompress()
		var t := img.get_height()
		for v in img.get_width() / t:
			for edge in 4:
				var opaque := 0
				for k in t:
					var p := Vector2i(v * t + (0 if edge == 0 else (t - 1 if edge == 1 else k)),
							k if edge < 2 else (0 if edge == 2 else t - 1))
					if img.get_pixel(p.x, p.y).a > 0.0:
						opaque += 1
				if opaque < t:
					thin.append("%s[%d] edge %d: %d of %d" % [name, v, edge, opaque, t])
	ck(thin.is_empty(), "doors and airlocks fill the whole tile (%s)" % str(thin.slice(0, 4)))

## Космос не рисует плитки вовсе: за доской параллакс, и своя картинка ему не нужна.
func _space_has_no_tile() -> void:
	var m := MapData.new(6, 6)
	m.fill_all_space()
	m.set_cell(Vector2i(1, 1), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_look(2 * 6 + 2, MCF.Look.SOLAR)
	m.set_look(3 * 6 + 3, MCF.Look.GRILL)
	var g := Grid.new(6, 6)
	m.apply_to_grid(g)
	var t := TerrainTiles.new(g, "station")
	ck(t._floor_name(g.cell(Vector2i(0, 0)), Vector2i(0, 0)) == "",
			"plain space draws no tile at all")
	ck(t._floor_name(g.cell(Vector2i(2, 2)), Vector2i(2, 2)) == "floor_solar",
			"a solar panel still draws itself over the stars")
	ck(t._floor_overlay_name(g.cell(Vector2i(3, 3)), Vector2i(3, 3)) == "floor_grill",
			"the grill is an overlay, so the stars show through its bars")
	ck(t._floor_name(g.cell(Vector2i(1, 1)), Vector2i(1, 1)) == "floor",
			"solid floor is unaffected")

# --- item 5: текстуры по папкам, лист автотайла — ровно 16 плиток -------------------------
func _textures_live_in_folders() -> void:
	Sprites.reload_overrides()
	ck(Sprites.has_override("wall_station") and Sprites.has_override("floor_grass"),
			"textures are found inside their folders")
	ck(not Sprites.has_override("sample"), "a sample is a template, not a tile")
	var sheets := 0
	var wrong := ""
	for name: String in ["wall", "wall_station", "wall_town", "glass", "sandbags", "bed", "sofa"]:
		var tex := Sprites.texture_of(name + Sprites.AUTOTILE_SUFFIX)
		if tex == null:
			wrong = name + " has no sheet"
			continue
		sheets += 1
		if tex.get_height() != tex.get_width():
			wrong = "%s sheet is %dx%d, not a single 4x4 block" % [
					name, tex.get_width(), tex.get_height()]
	ck(sheets == 7 and wrong == "", "every autotile sheet is 16 tiles (%s)" % wrong)
	var missing: PackedStringArray = []
	for section: String in ["walls", "floors", "doors", "features", "furniture", "decals"]:
		var d := DirAccess.open("res://textures/" + section)
		if d == null:
			missing.append(section)
			continue
		for obj: String in d.get_directories():
			if not FileAccess.file_exists("res://textures/%s/%s/sample.png" % [section, obj]) \
					and obj != "blood_pool" and obj != "blood_splatter":
				missing.append(section + "/" + obj)
	ck(missing.is_empty(), "every object folder carries its sample (%s)" % ", ".join(missing))

func _tiles() -> void:
	var doors := Grid.new(20, 2)
	for x in 12: doors.cell_fast(x, 0).set_feature(MCF.FEATURE_AIRLOCK)
	var door_tiles := TerrainTiles.new(doors, "station")
	for x in 12:
		ck(door_tiles._door_anchor(doors, Vector2i(x, 0)) == Vector2i.ZERO, "wide airlock shares a stable sprite variant")
	var g := Grid.new(4, 4)
	g.cell_fast(1, 1).set_feature(MCF.FEATURE_DIRT_PILE)
	g.cell_fast(2, 1).set_feature(MCF.FEATURE_DIRT_PILE)
	ck(TerrainTiles.mask_at(g, Vector2i(1, 1), MCF.FEATURE_DIRT_PILE) == Sprites.AUTOTILE_E, "dirt piles join their neighbors")
	ck(TerrainTiles.tile_name(g.cell_fast(1, 1)) == "soil", "dirt piles use the soil wall artwork")
	var tiles := TerrainTiles.new(g, "town")
	var fx := FxDecals.new()
	fx.track_marks.append({"from": Vector2(0.5, 0.5), "to": Vector2(3.5, 0.5)})
	fx.ground_version += 1
	tiles.sync_decals(fx)
	g.cell_fast(1, 0).set_feature(MCF.FEATURE_WALL)
	tiles._build(Vector2i.ZERO, 32)
	var with_tracks: Image = tiles._chunks[Vector3i(0, 0, 32)]["feat"].get_image()
	var clean := TerrainTiles.new(g, "town")
	clean._build(Vector2i.ZERO, 32)
	ck(with_tracks.get_data() == clean._chunks[Vector3i(0, 0, 32)]["feat"].get_image().get_data(), "track marks never alter the wall layer")

var MainScript: GDScript

func state_of(m: MapData, seed_value := 77) -> GameState:
	var st := m.build_state(seed_value)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	return st

func _texture_budget() -> void:
	var st := state_of(MapData.blank_arena(40, 24))
	var tiles := TerrainTiles.new(st.grid, "town")
	for x in 2: tiles._build(Vector2i(x, 0), 8)
	var old: ImageTexture = tiles._chunks[Vector3i(1, 0, 8)].floor
	tiles._dirty[Vector2i.ZERO] = true
	tiles._dirty[Vector2i(1, 0)] = true
	tiles._built = 0
	tiles._choose(Vector2i.ZERO, 8)
	tiles._choose(Vector2i(1, 0), 8)
	ck(tiles._built == 1 and tiles._dirty.has(Vector2i(1, 0)) and tiles._chunks[Vector3i(1, 0, 8)].floor == old, "an explosion rebuilds one cached terrain chunk per frame, retaining a valid fallback")
	tiles._built = 0
	tiles._choose(Vector2i(1, 0), 8)
	ck(not tiles._dirty.has(Vector2i(1, 0)), "deferred explosion texture catches up on the next frame")

## welded airlock looks different in the baked tile
func _welded_airlock_tile() -> void:
	var g := Grid.new(3, 3)
	var cell := g.cell(Vector2i(1, 1))
	cell.set_feature(MCF.FEATURE_AIRLOCK, -1)
	cell.cover_height = MCF.WALL_HEIGHT
	var tt := TerrainTiles.new(g)
	var a := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var fa := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	tt._paint(a, fa, Vector2i(1, 1), Vector2i.ZERO, 32)
	cell.airlock_welded = true
	var b := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var fb := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	tt._paint(b, fb, Vector2i(1, 1), Vector2i.ZERO, 32)
	ck(fa.get_data() != fb.get_data(), "a welded airlock tile differs from a plain one")
