extends SceneTree
## 0.12.1 batch ("Isotope issues fix 5"): symmetric maps deploy at opposite ends, lamp
## brightness steps (300 % no longer deletes the lamp), time of day, wall and pillbox chunks,
## soot, no decal caps, the flamethrower jet. Interface classes are loaded at run time: they
## use autoloads that a --script run compiles after this file.

var fails: PackedStringArray = []
func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond: fails.append(what)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_symmetric_zones()
	_lamp_levels()
	_time_of_day()
	_wall_chunks()
	_pillbox_chunks()
	_soot()
	_no_caps()
	_flame_jet()
	_drawn_zones()
	_glow_tint()
	_items_on_map()
	_items_in_battle()
	_cabinet_spill()
	_items_generator()
	await _items_editor()
	_projectiles()
	await _impact_in_battle()
	_rubble()
	print("batch 0.12.1: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

## A symmetric random map puts the two deployment zones at opposite ends of the playable
## area (a station's hull floats in space, so its ends are the hull's, not the map's).
func _symmetric_zones() -> void:
	for style in [MapGen.Style.FIELD, MapGen.Style.TOWN, MapGen.Style.STATION]:
		for seed in [3, 11]:
			var m := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": 48, "height": 32,
					"density": 1, "seed": seed, "zones": 2, "symmetric": true, "civilians": 0, "civilian_count": 0})
			var lo := m.width
			var hi := 0
			for i in m.width * m.height:
				if m.is_space[i] == 0:
					lo = mini(lo, i % m.width)
					hi = maxi(hi, i % m.width)
			var mid: Array[float] = []
			for owner in 2:
				var cells: Array = m.zone_cells(owner)
				var sx := 0.0
				for c: Vector2i in cells:
					sx += c.x
				mid.append(sx / maxi(1, cells.size()))
			var span := float(hi - lo + 1)
			var ends := minf(mid[0], mid[1]) - lo < span * 0.3 and hi - maxf(mid[0], mid[1]) < span * 0.3
			ck(ends, "%s seed %d: zones sit at opposite ends (x %.0f and %.0f of %d..%d)" % [
					MapGen.STYLE_NAMES[style], seed, mid[0], mid[1], lo, hi])

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

## The map's time of day travels through files, the battle state, saves and the generator.
func _time_of_day() -> void:
	var m := MapData.blank_arena(12, 10)
	ck(m.time_of_day == "", "a new map has no time of day (plain night lighting)")
	m.time_of_day = "evening"
	var back := MapData.from_dict(m.to_dict())
	ck(back.time_of_day == "evening", "time of day survives the map file")
	var bad := m.to_dict()
	bad["time"] = "noon"
	ck(MapData.from_dict(bad).time_of_day == "", "an unknown time of day is dropped")
	var st := back.build_state(1)
	ck(st.time_of_day == "evening", "the battle starts at the map's time of day")
	ck(StateCodec.decode(StateCodec.encode(st)).time_of_day == "evening", "saves and resyncs carry it")
	var seen := {}
	for seed in 12:
		seen[MapGen.time_choice({"time": "random", "seed": seed})] = true
	ck(seen.size() >= 3 and seen.keys().all(func(t: String) -> bool: return t in MapData.TIMES),
			"Random picks among the four times (%s)" % ", ".join(seen.keys()))
	ck(MapGen.time_choice({"time": "day", "seed": 1}) == "day", "a chosen time is kept")
	var lm: GDScript = load("res://src/ui/LightManager.gd")
	var night: Color = lm.ambient_for("town", 1.0, "night")
	var day: Color = lm.ambient_for("town", 1.0, "day")
	ck(day.get_luminance() > night.get_luminance() + 0.2, "day is much brighter than night")

func _arena(env := "town") -> GameActionResolver:
	var m := MapData.blank_arena(20, 20)
	m.env = env
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 18), "light_infantry", 1)
	return GameActionResolver.new(m.build_state(5))

func _events_of(res: ActionResult, kind: String) -> Array:
	return res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == kind)

## A wall blown down by a blast throws chunks that look like it (its own tile), more and a
## little bigger than glass shards, flying away from the blast.
func _wall_chunks() -> void:
	var r := _arena()
	var wall := Vector2i(11, 10)
	r.state.grid.cell(wall).set_feature(MCF.FEATURE_WALL)
	var res := ActionResult.new()
	r._blast(Vector2i(10, 10), res, MCF.blast_square(Vector2i(10, 10), 1))
	ck(r.state.grid.cell(wall).feature_id == "", "the blast took the wall down")
	var ev := _events_of(res, "chunks")
	ck(ev.size() == 1 and ev[0]["at"] == wall and ev[0]["fid"] == MCF.FEATURE_WALL, "one chunk burst from the wall")
	var fx := FxDecals.new()
	fx.apply(res.fx)
	var chunks := fx.flying.filter(func(f: Dictionary) -> bool: return str(f["kind"]).begins_with("chunk:"))
	ck(chunks.size() >= FxDecals.CHUNKS_MIN and chunks.size() <= FxDecals.CHUNKS_MAX,
			"%d chunks fly (more than a window's shards)" % chunks.size())
	ck(not chunks.is_empty() and str(FxDecals.chunk_parts(str(chunks[0]["kind"]))[0]) == "wall_town", "town walls shed town-wall chunks (%s)" % (
			chunks[0]["kind"] if not chunks.is_empty() else "none"))
	ck(chunks.all(func(f: Dictionary) -> bool: return Vector2(f["to"]).x > 11.0), "every chunk flies away from the blast")
	ck(float(FxDecals.look_of("chunk:wall_town")[0]) > float(FxDecals.LOOK["shard"][0]), "chunks are bigger than glass shards")
	for _i in 10:
		fx.advance(0.5)
	ck(fx.props.any(func(p: Dictionary) -> bool: return str(p["kind"]).begins_with("chunk:")), "the chunks settle on the floor")
	var saved := FxDecals.new()
	saved.from_dict(fx.to_dict())
	ck(saved.props.size() == fx.props.size(), "settled chunks and soot survive a save")
	# Brick walls shed brick.
	var b := _arena()
	b.state.grid.cell(wall).set_feature(MCF.FEATURE_WALL)
	if b.state.grid.floor_look.is_empty():
		b.state.grid.floor_look.resize(b.state.grid.width * b.state.grid.height)
	b.state.grid.floor_look[wall.y * b.state.grid.width + wall.x] = MCF.wall_look(MCF.WALL_LOOKS.find("wall_brick"))
	var bres := ActionResult.new()
	b._blast(Vector2i(10, 10), bres, MCF.blast_square(Vector2i(10, 10), 1))
	var bev := _events_of(bres, "chunks")
	ck(not bev.is_empty() and FxDecals.chunk_art(bev[0]["fid"], int(bev[0]["look"]), str(bev[0]["env"])) == "wall_brick",
			"a brick wall's chunks are brick")

## A pillbox that loses durability spalls chunks back toward whoever hit it.
func _pillbox_chunks() -> void:
	var r := _arena()
	var box := Vector2i(10, 10)
	r.state.grid.cell(box).set_feature(MCF.FEATURE_DOT)
	var before := r.state.grid.cell(box).feature_durability
	var res := ActionResult.new()
	ck(r._pillbox_absorbs(box, 1, res, Vector2i(4, 10)), "the pillbox takes the hit")
	ck(r.state.grid.cell(box).feature_durability == before - 1, "and loses one durability")
	var ev := _events_of(res, "chunks")
	ck(ev.size() == 1 and bool(ev[0].get("toward", false)) and int(ev[0]["count"]) == GameActionResolver.PILLBOX_CHUNKS_PER_POINT,
			"one burst of chunks per durability point")
	var fx := FxDecals.new()
	fx.apply(res.fx)
	ck(not fx.flying.is_empty() and fx.flying.all(func(f: Dictionary) -> bool: return Vector2(f["to"]).x < 10.5),
			"the chunks fly out of the side it was shot from")

## Explosions leave soot: a big patch at the epicenter, smaller varied ones around it.
func _soot() -> void:
	var variants := {}
	var at_center := 0
	for blast in 6:
		var r := _arena()
		var c := Vector2i(6 + blast, 8)
		var res := ActionResult.new()
		r._blast(c, res, MCF.blast_square(c, 1))
		var fx := FxDecals.new()
		fx.apply(res.fx)
		for p: Dictionary in fx.props:
			var k := str(p["kind"])
			if not k.begins_with("soot:"):
				continue
			variants[k] = true
			if Vector2i(floori(p["pos"].x), floori(p["pos"].y)) == c and float(p["scale"]) >= 1.5:
				at_center += 1
	ck(at_center == 6, "every blast leaves a big soot patch on its epicenter (%d/6)" % at_center)
	ck(variants.size() >= 3, "soot patches come in different shapes (%d)" % variants.size())
	var space := FxDecals.new()
	space.space_at = func(_c: Vector2i) -> bool: return true
	space.apply([{"fx": "debris", "at": Vector2i(5, 5), "cells": [Vector2i(5, 5)], "blast": true, "seq": 1}])
	ck(space.props.is_empty(), "no soot over open space")

## Decals are never evicted (owner: "remove all decal caps").
func _no_caps() -> void:
	var fx := FxDecals.new()
	for i in 2500:
		fx.apply([{"fx": "laser", "from": [0, i % 40], "to": [30, i % 40]}])
	ck(fx.laser_lines.size() >= 2500, "laser scorches are all kept (%d)" % fx.laser_lines.size())
	ck(not ("PROPS_CAP" in FxDecals) and not ("LASER_CAP" in FxDecals), "the decal caps are gone")

## The flame is shown as a jet running out of the nozzle cell by cell: the resolver hands the
## screen the jet's cells in order, without spending a board fx number on it.
func _flame_jet() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(5, 10), "flamethrower", 0)
	m.set_spawn(Vector2i(8, 10), "light_infantry", 1)
	var st := m.build_state(2)
	var r := GameActionResolver.new(st)
	var shooter: UnitInstance = st.grid.cell(Vector2i(5, 10)).occupant
	var want := r.flame_cells(shooter.coord, Vector2i(1, 0))
	var seq := st.fx_seq
	var res := r._resolve_flame(shooter, Vector2i(9, 10))
	var jets := _events_of(res, "flame_jet")
	ck(jets.size() == 1 and jets[0]["cells"] == want and jets[0]["from"] == Vector2i(5, 10),
			"the flame hands the screen its jet, nozzle first (%d cells)" % want.size())
	ck(not jets.is_empty() and not jets[0].has("seq"), "the jet takes no board fx number")
	ck(st.fx_seq - seq == res.fx.filter(func(f: Dictionary) -> bool: return f.has("seq")).size(), "fx numbers count only seeded effects")
	ck(res.deaths.size() == 1, "the target in the jet still burns")
	var fx := FxDecals.new()
	fx.apply(res.fx)
	ck(fx.flying.is_empty() and fx.props.is_empty(), "the jet leaves no particles of its own")

## Zones the host draws in the lobby replace Auto placement, ride to guests in the rules,
## are clipped to the board, and Auto (empty) still places them by the map.
func _drawn_zones() -> void:
	var m := MapData.blank_arena(20, 16)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(17, 13), "light_infantry", 1)
	GameConfig.game_mode = MatchMode.Kind.CAPTURE
	GameConfig.capture_drawn = [[4, 4, 3, 3], [12, 8, 2, 2]]
	var r := GameActionResolver.new(m.build_state(9))
	r.prepare_mode(m)
	ck(r.mode.zones == [[4, 4, 3, 3], [12, 8, 2, 2]] and r.mode.holders.size() == 2, "the battle uses the drawn zones")
	var rules := NetHandoff.encode_rules()
	GameConfig.capture_drawn = []
	NetHandoff.apply_rules(rules)
	ck(GameConfig.capture_drawn == [[4, 4, 3, 3], [12, 8, 2, 2]], "drawn zones reach guests in the lobby rules")
	ck(MatchMode.clean_drawn([[18, 14, 5, 5], [30, 30, 2, 2], [1, 1]], 20, 16) == [[18, 14, 2, 2]],
			"zones are clipped to the board and junk is dropped")
	ck(MatchMode.clean_drawn([[0, 0, 1, 1], [1, 0, 1, 1], [2, 0, 1, 1], [3, 0, 1, 1], [4, 0, 1, 1], [5, 0, 1, 1]], 20, 16).size() == 5,
			"no more than five zones (A to E)")
	GameConfig.capture_drawn = []
	var auto := GameActionResolver.new(m.build_state(9))
	auto.prepare_mode(m)
	ck(not auto.mode.zones.is_empty() and auto.mode.zones != [[4, 4, 3, 3], [12, 8, 2, 2]], "Auto still places zones by the map")
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION

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

## Small items (0.12.1): free-placed [kind, x, y, angle] in the map file; unknown kinds are
## dropped; they ride through stamps (rotated) and onto the battle board.
func _items_on_map() -> void:
	var m := MapData.blank_arena(12, 10)
	m.items = [["mug", 3.25, 4.6, 0.7], ["papers", 5.5, 5.5, 2.0]]
	var d := m.to_dict()
	d["items"].append(["teapot", 1.0, 1.0, 0.0])
	var back := MapData.from_dict(d)
	ck(back.items.size() == 2 and back.items[0][0] == "mug" and is_equal_approx(float(back.items[0][1]), 3.25),
			"items survive the map file at their exact spot; unknown kinds are dropped")
	var p := MapPresets.capture(back, Rect2i(2, 3, 4, 4))
	var r := MapPresets.rotated(p)
	ck(p["items"].size() == 2 and r["items"].size() == 2, "a captured stamp carries its items, also when turned")
	var g := Grid.new(12, 10)
	back.apply_to_grid(g)
	ck(g.map_items.size() == 2 and g.items_in(Vector2i(3, 4)) == [0], "the board knows which items lie in each cell")
	var st := back.build_state(1)
	var rs := StateCodec.decode(StateCodec.encode(st))
	ck(rs.grid.map_items.size() == 2, "saves carry the items")

## A blast throws the items lying in its area like casings; the cell remembers they are gone
## (saves too) and the flying items settle on the floor as decals.
func _items_in_battle() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 18), "light_infantry", 1)
	m.set_cell(Vector2i(10, 10), MCF.FLOOR_NORMAL, Furniture.height_of("coffee_table"), false, "coffee_table")
	m.items = [["mug", 10.4, 10.5, 0.0], ["book", 10.6, 10.3, 1.0], ["plate", 15.5, 15.5, 0.0]]
	var st := m.build_state(3)
	var r := GameActionResolver.new(st)
	var res := ActionResult.new()
	r._blast(Vector2i(9, 10), res, MCF.blast_square(Vector2i(9, 10), 1))
	var cell := st.grid.cell(Vector2i(10, 10))
	ck(cell.items_off == 0b11, "both items on the table are knocked off (%d)" % cell.items_off)
	ck(st.grid.cell(Vector2i(15, 15)).items_off == 0, "an item outside the blast stays put")
	var ev := res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "items")
	ck(ev.size() == 1 and (ev[0]["items"] as Array).size() == 2, "one burst carries both items")
	var fx := FxDecals.new()
	fx.apply(res.fx)
	var flying := fx.flying.filter(func(f: Dictionary) -> bool: return str(f["kind"]).begins_with("item:"))
	ck(flying.size() == 2 and flying.all(func(f: Dictionary) -> bool: return float(f["scale"]) == 1.0),
			"they fly from where they lay, at full size")
	ck(flying.all(func(f: Dictionary) -> bool: return Vector2(f["to"]).x > 10.0), "away from the blast")
	for _i in 10:
		fx.advance(0.5)
	ck(fx.props.filter(func(pr: Dictionary) -> bool: return str(pr["kind"]).begins_with("item:")).size() == 2,
			"and land on the floor")
	var res2 := ActionResult.new()
	r._blast(Vector2i(9, 10), res2, MCF.blast_square(Vector2i(9, 10), 1))
	ck(res2.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "items").is_empty(), "nothing is knocked twice")
	var rs := StateCodec.decode(StateCodec.encode(st))
	ck(rs.grid.cell(Vector2i(10, 10)).items_off == 0b11, "saves remember which items are gone")
	r._ignite(st.grid.cell(Vector2i(15, 15)), 0, null)
	ck(st.grid.cell(Vector2i(15, 15)).items_off == 0b1, "fire burns the items on its cell")
	var im := cell.image()
	cell.items_off = 0
	cell.apply_image(im)
	ck(cell.items_off == 0b11, "undo snapshots keep it as well")
	# The board draws standing items over the furniture layer and skips knocked ones.
	var tt: GDScript = load("res://src/ui/TerrainTiles.gd")
	var fresh := m.build_state(3)
	var tiles: Object = tt.new(fresh.grid, "town")
	var blank := Image.create(16 * 32, 16 * 32, false, Image.FORMAT_RGBA8)
	var img := blank.duplicate()
	tiles._bake_items(img, Vector2i.ZERO, 32)
	ck(img.get_used_rect().has_point(Vector2i(roundi(10.4 * 32), roundi(10.5 * 32))), "a standing mug is drawn at its spot")
	fresh.grid.cell(Vector2i(10, 10)).items_off = 0b11
	var img2 := blank.duplicate()
	tiles._bake_items(img2, Vector2i.ZERO, 32)
	ck(not img2.get_used_rect().has_point(Vector2i(roundi(10.4 * 32), roundi(10.5 * 32))), "a knocked one is not")

## A dragged cabinet opens and spills its contents once; it stays open where it goes.
func _cabinet_spill() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(5, 5), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 18), "light_infantry", 1)
	m.set_cell(Vector2i(6, 5), MCF.FLOOR_NORMAL, Furniture.height_of("cabinet"), false, "cabinet")
	var st := m.build_state(4)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r := GameActionResolver.new(st)
	var u: UnitInstance = st.grid.cell(Vector2i(5, 5)).occupant
	var res := r.resolve(DragIntent.new(u.id, Vector2i(6, 5), Vector2i(6, 6)))
	ck(res.ok and st.grid.cell(Vector2i(6, 6)).feature_id == "cabinet", "the cabinet is dragged (%s)" % res.reason)
	var spill := res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "spill")
	ck(spill.size() == 1 and (st.grid.cell(Vector2i(6, 6)).items_off & GridCell.OPENED) != 0, "it opens and spills")
	var fx := FxDecals.new()
	fx.apply(res.fx)
	ck(fx.flying.size() >= SmallItems.SPILL_MIN and fx.flying.all(func(f: Dictionary) -> bool:
			return SmallItems.SPILLS["cabinet"].has(str(f["kind"]).substr(5))), "with things a cabinet holds (%d)" % fx.flying.size())
	u.remaining_ap = 4
	u.dragging = UnitInstance.NOT_DRAGGING
	var res2 := r.resolve(DragIntent.new(u.id, Vector2i(6, 6), Vector2i(6, 5)))
	ck(res2.ok and res2.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "spill").is_empty()
			and (st.grid.cell(Vector2i(6, 5)).items_off & GridCell.OPENED) != 0, "an open, empty cabinet spills nothing more")
	var res3 := ActionResult.new()
	r._blast(Vector2i(6, 5), res3, MCF.blast_square(Vector2i(6, 5), 1))
	ck((st.grid.cell(Vector2i(6, 5)).items_off & GridCell.OPENED) == 0, "a destroyed cabinet leaves no open flag behind")

## Generated maps lay their tables (office desks, dining tables…) and mirror the items on
## symmetric maps.
func _items_generator() -> void:
	var total := 0
	for style in [MapGen.Style.TOWN, MapGen.Style.STATION]:
		var m := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": 60, "height": 44,
				"density": 2, "seed": 21, "zones": 2, "civilians": 0, "civilian_count": 0})
		total += m.items.size()
		var on_tables := m.items.all(func(it: Array) -> bool:
			var c := SmallItems.cell_of(it)
			return SmallItems.is_table(m.get_feature(c)))
		ck(on_tables, "%s: every generated item lies on a table (%d)" % [MapGen.STYLE_NAMES[style], m.items.size()])
		var again := MapGen.generate({"style": style, "size": MapGen.SIZE_CUSTOM, "width": 60, "height": 44,
				"density": 2, "seed": 21, "zones": 2, "civilians": 0, "civilian_count": 0})
		ck(again.items == m.items, "%s: the same seed lays the same items" % MapGen.STYLE_NAMES[style])
	ck(total > 0, "generated towns and stations have items on their tables (%d)" % total)
	var sym := MapGen.generate({"style": MapGen.Style.TOWN, "size": MapGen.SIZE_CUSTOM, "width": 60, "height": 44,
			"density": 2, "seed": 5, "zones": 2, "symmetric": true, "civilians": 0, "civilian_count": 0})
	var left := sym.items.filter(func(it: Array) -> bool: return float(it[1]) < sym.width / 2.0).size()
	var right := sym.items.filter(func(it: Array) -> bool: return float(it[1]) > sym.width / 2.0).size()
	ck(left == right, "a symmetric map mirrors its items (%d | %d)" % [left, right])

## In the editor: a click lays the chosen item at the pointer (undoable); a painted table
## lays its set; erasing the table takes its items along.
func _items_editor() -> void:
	var ed: Node = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(ed)
	for i in 5: await process_frame
	ed.create_map("t", "town", Vector2i(16, 12))
	var at := Vector2(5.3, 4.7)
	var screen: Vector2 = ed.pan + at * ed.cell_size()
	ed._select_brush("item:mug")
	ed.item_rotation = 0.5
	ed._press(Vector2i(5, 4), false, screen)
	ed._release(Vector2i(5, 4))
	ck(ed.map.items.size() == 1 and ed.map.items[0][0] == "mug" and Vector2(ed.map.items[0][1], ed.map.items[0][2]).distance_to(at) < 0.01
			and is_equal_approx(float(ed.map.items[0][3]), 0.5), "a click lays a mug at the pointer, at the chosen angle")
	ed.undo()
	ck(ed.map.items.is_empty(), "undo takes it back")
	ed._select_brush("coffee_table")
	ck(ed._set_row.visible and ed._table_set() == "coffee", "a table brush shows its item set (%s)" % ed._table_set())
	ed._cycle_table_set(1)
	ck(ed._table_set() == "meeting", "the arrows pick another set")
	for x in [2, 6, 10, 13]:
		ed._press(Vector2i(x, 8), false)
		ed._release(Vector2i(x, 8))
	var laid: Array = ed.map.items.duplicate()
	ck(not laid.is_empty() and laid.all(func(it: Array) -> bool: return it[0] in ["papers", "folder", "mug", "cup", "phone", "laptop"]),
			"painted tables are laid with the chosen set (%d items)" % laid.size())
	ed._select_tool(ed.Tool.ERASER)
	ed._press(Vector2i(2, 8), false)
	ed._release(Vector2i(2, 8))
	ck(ed.map.items.all(func(it: Array) -> bool: return SmallItems.cell_of(it) != Vector2i(2, 8)), "erasing a table takes its items")
	ed.queue_free()
	await process_frame

## Shots show a flying projectile and their effects on impact (0.12.1 follow-up): the tank's
## lane points at the clicked cell (not where the shell will fall); the shell, the anti-tank
## rocket and the frag grenade fly to where they really land; the shotgun and the DPMG get
## bullet tracers. None of these take a board effect number.
func _projectiles() -> void:
	var tm := MapData.blank_arena(24, 12)
	tm.set_spawn(Vector2i(3, 5), "tank", 0, Vector2i(1, 0))
	tm.set_spawn(Vector2i(20, 10), "light_infantry", 1)
	var ts := tm.build_state(5)
	ts.turns.round_order = [0, 1]
	ts.turns.active_index = 0
	var r := GameActionResolver.new(ts)
	var tank: Vehicle = ts.all_vehicles()[0]
	var aim := Vector2i(14, 5)
	var short_seen := false
	var lanes_ok := true
	var shots_ok := true
	var reason := ""
	for attempt in 40:
		tank.ap = 9
		tank.cannon_shots_this_round = 0
		var seq := ts.fx_seq
		var res := r.resolve(VehicleCannonIntent.new(tank.id, aim))
		if not res.ok:
			reason = res.reason
			break
		var lane := res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "lane")
		var shot := res.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "shot")
		lanes_ok = lanes_ok and lane.size() == 1 and Vector2i(int(lane[0]["to"][0]), int(lane[0]["to"][1])) == aim
		shots_ok = shots_ok and shot.size() == 1 and shot[0]["kind"] == "shell" and not shot[0].has("seq")
		if not shot.is_empty() and Vector2i(int(shot[0]["to"][0]), int(shot[0]["to"][1])) != aim:
			short_seen = true
		if short_seen and attempt > 5:
			break
	ck(reason == "", "the tank fires (%s)" % reason)
	ck(lanes_ok, "the tank's lane always points at the clicked cell")
	ck(shots_ok, "each cannon shot flies a shell, without a board effect number")
	ck(short_seen, "a short shell flies to where it really lands, not to the aim")
	# Anti-tank rocket, frag grenade, shotgun and DPMG.
	var m := MapData.blank_arena(20, 14)
	m.set_spawn(Vector2i(3, 3), "anti_tank", 0)
	m.set_spawn(Vector2i(3, 6), "assault", 0)
	m.set_spawn(Vector2i(3, 10), "heavy_infantry", 0)
	m.set_spawn(Vector2i(6, 6), "light_infantry", 1)
	m.set_spawn(Vector2i(18, 13), "light_infantry", 1)
	var st := m.build_state(6)
	st.turns.round_order = [0, 1]
	st.turns.active_index = 0
	var r2 := GameActionResolver.new(st)
	var at: UnitInstance = st.grid.cell(Vector2i(3, 3)).occupant
	var ares := r2.resolve(ShootIntent.new(at.id, -1, -1, Vector2i(8, 3)))
	var rocket := ares.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "shot")
	ck(ares.ok and rocket.size() == 1 and rocket[0]["kind"] == "rocket", "the anti-tank shot flies a rocket")
	var asl: UnitInstance = st.grid.cell(Vector2i(3, 6)).occupant
	var sres := r2.resolve(ShootIntent.new(asl.id, st.grid.cell(Vector2i(6, 6)).occupant.id))
	ck(sres.ok and sres.fx.any(func(f: Dictionary) -> bool: return f.get("fx", "") == "tracer"), "the shotgun shows bullet tracers (%s)" % sres.reason)
	var hv: UnitInstance = st.grid.cell(Vector2i(3, 10)).occupant
	hv.held_item_id = MCF.ITEM_FRAG
	var gres := r2.resolve(UseItemIntent.new(hv.id, Vector2i(6, 10)))
	var lob := gres.fx.filter(func(f: Dictionary) -> bool: return f.get("fx", "") == "shot")
	ck(gres.ok and lob.size() == 1 and lob[0]["kind"] == "grenade", "a frag grenade is lobbed (%s)" % gres.reason)
	ck(FxDecals.shot_dur({"kind": "rocket", "from": [0, 0], "to": [30, 0]}) <= FxDecals.SHOT_MAX
			and FxDecals.shot_dur({"kind": "grenade", "from": [0, 0], "to": [1, 0]}) >= FxDecals.SHOT_MIN, "flights stay short")
	var fx := FxDecals.new()
	fx.apply(ares.fx)
	ck(fx.shots.size() == 1, "the effects layer flies the rocket")
	for _i in 10:
		fx.advance(0.1)
	ck(fx.shots.is_empty(), "and lets it go once it lands")

## On the battle screen a killed soldier stays standing until the bullet reaches them, and
## the blood appears with the hit, not when the dice stop.
func _impact_in_battle() -> void:
	var ui := root.get_node("/root/Ui")
	var autoroll: bool = ui.autoroll_dice
	ui.autoroll_dice = true
	var m := MapData.blank_arena(16, 8)
	m.set_spawn(Vector2i(2, 3), "light_infantry", 0)
	m.set_spawn(Vector2i(7, 3), "light_infantry", 1)
	m.set_spawn(Vector2i(15, 7), "light_infantry", 1)
	MapHandoff.pending = m
	GameConfig.fog_mode = MCF.Fog.OFF
	GameConfig.roster = Roster.default_duel(false)
	var main: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	for i in 6: await process_frame
	while main.state == null or main._animating: await process_frame
	var st: GameState = main.state
	while st.active_player() != 0:
		main._on_intent_ready(EndTurnIntent.new())
		for i in 3: await process_frame
		while main._animating: await process_frame
	var shooter: UnitInstance = st.grid.cell(Vector2i(2, 3)).occupant
	var target: UnitInstance = st.grid.cell(Vector2i(7, 3)).occupant
	var res: ActionResult = null
	for attempt in 60:
		shooter.remaining_ap = 2
		shooter.action_state = null
		res = main.resolver.resolve(ShootIntent.new(shooter.id, target.id))
		if not target.is_alive():
			break
	var blood_before: int = main._fx.gore.size()
	main._show_result(res)
	var waited := 0
	while main._fx.tracers.is_empty() and waited < 2000:
		await process_frame
		waited += 1
	ck(not target.is_alive() and main._pending_death_ids.has(target.id) and main._fx.gore.size() == blood_before
			and main._fx.flying.filter(func(f: Dictionary) -> bool: return str(f["kind"]).begins_with("blood")).is_empty(),
			"while the bullet flies, the target still stands and there is no blood yet")
	await create_timer(0.6).timeout
	ck(not main._pending_death_ids.has(target.id), "the hit drops the target")
	ck(main._fx.gore.size() > blood_before or main._fx.flying.size() > 0, "and the blood comes with it")
	main.queue_free()
	await process_frame
	ui.autoroll_dice = autoroll

## On station and asteroid maps digging goes through the deck: the pile is drawn as rubble
## and called "Rubble Pile", the trench has its metal look, the log says rubble; other maps
## keep dirt.
func _rubble() -> void:
	var tt: GDScript = load("res://src/ui/TerrainTiles.gd")
	ck(tt.pile_art("station") == "rubble" and tt.pile_art("asteroid") == "rubble" and tt.pile_art("town") == "soil"
			and tt.pile_art("bunker") == "soil", "station and asteroid piles use the rubble art, other maps dirt")
	ck(tt.env_name("trench", "station") == "trench_station" and tt.env_name("trench", "asteroid") == "trench_asteroid"
			and tt.env_name("trench", "field") == "trench", "station and asteroid trenches are cut into metal")
	for env in ["station", "town"]:
		var m := MapData.blank_arena(12, 8)
		m.env = env
		m.set_spawn(Vector2i(3, 3), "engineer", 0)
		m.set_spawn(Vector2i(11, 7), "light_infantry", 1)
		var st := m.build_state(2)
		st.turns.round_order = [0, 1]
		st.turns.active_index = 0
		var r := GameActionResolver.new(st)
		var name := MCF.feature_name(MCF.FEATURE_DIRT_PILE)
		var eng: UnitInstance = st.grid.cell(Vector2i(3, 3)).occupant
		var res := r.resolve(DigIntent.new(eng.id, Vector2i(4, 3)))
		var log := " ".join(res.log_lines)
		if env == "station":
			ck(name == "Rubble Pile" and res.ok and log.contains("rubble at"), "on a station the pile is a Rubble Pile (%s)" % log)
		else:
			ck(name == "Dirt Pile" and res.ok and log.contains("dirt at"), "elsewhere it stays a Dirt Pile (%s)" % log)
