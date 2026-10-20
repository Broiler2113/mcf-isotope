extends "res://tests/SuiteBase.gd"
## Blasts: grenades and walls, lamps and shards, wall and pillbox chunks, soot, items thrown,
## blast cells on the firing line, shards stopped by walls.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_frag_and_lamps()
	_shot_lamp_shards()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_wall_chunks()
	_pillbox_chunks()
	_soot()
	_items_in_battle()

	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_chunk_shapes()

	grenades_and_walls()

	_blast_cell_checks_occupied_cells()
	_shards_stop_at_walls()

## A frag grenade makes every lamp in its blast roll like a window; a broken lamp sheds
## glass shards.
func _frag_and_lamps() -> void:
	var seen_break := false
	var seen_hold := false
	for seed in 40:
		var m := MapData.blank_arena(20, 20)
		m.set_spawn(Vector2i(2, 2), "light_infantry", 0)
		m.set_spawn(Vector2i(18, 18), "light_infantry", 1)
		var s := m.build_state(seed)
		var r := GameActionResolver.new(s)
		var lamp := Vector2i(9, 9)   # the frag blast is an X: centre and diagonals
		s.grid.cell(lamp).set_feature("streetlight")
		var wall := Vector2i(11, 11)
		s.grid.cell(wall).set_feature(MCF.FEATURE_WALL)
		s.grid.cell(wall).lamps = [["wall_lamp", 1, 3, 0], ["wall_lamp", 1, 1, 0]]   # west side faces the blast; east does not
		var res := r._explode_frag(s.get_unit(s.grid.cell(Vector2i(2, 2)).occupant.id), Vector2i(10, 10))
		var lamp_rolls := 0
		for ev: Dictionary in res.dice_events:
			if ev.get("kind", "") == "grenade":
				for det: Dictionary in ev["targets"]:
					if str(det["name"]) in ["Streetlight", "Wall Lamp"]:
						lamp_rolls += 1
						ck(det["rolls"].size() == 2 and int(det["need"]) == 6, "a lamp rolls two dice against 6+ like glass")
		if seed == 0:
			ck(lamp_rolls == 2, "the standing lamp and the wall lamp facing the blast roll; the far side does not")
		ck(MapData.lamp_on(s.grid.cell(wall).lamps, 1).size() > 0, "the wall lamp on the far side is untouched")
		var shards := res.fx.filter(func(f: Dictionary) -> bool: return f["fx"] == "shards").size()
		var broken := int(s.grid.cell(lamp).feature_id == "") + int(MapData.lamp_on(s.grid.cell(wall).lamps, 3).is_empty())
		ck(shards == broken, "every broken lamp sheds glass shards (%d/%d)" % [shards, broken])
		seen_break = seen_break or broken > 0
		seen_hold = seen_hold or broken < 2
	ck(seen_break and seen_hold, "lamps sometimes break and sometimes hold")

func _shot_lamp_shards() -> void:
	var m := MapData.blank_arena(20, 20)
	m.set_spawn(Vector2i(5, 10), "light_infantry", 0)
	m.set_spawn(Vector2i(18, 18), "light_infantry", 1)
	var s := m.build_state(3)
	var r := GameActionResolver.new(s)
	var c := Vector2i(7, 10)
	s.grid.cell(c).set_feature(MCF.FEATURE_WALL)
	s.grid.cell(c).lamps = [["wall_lamp", 1, 3, 0]]
	var shooter := s.grid.cell(Vector2i(5, 10)).occupant
	for attempt in 20:
		if MapData.lamp_on(s.grid.cell(c).lamps, 3).is_empty(): break
		shooter.remaining_ap = 1
		shooter.action_state = null
		var res := r._resolve_shoot_fixture(shooter, c, 3, -1)
		if MapData.lamp_on(s.grid.cell(c).lamps, 3).is_empty():
			var sh: Array = res.fx.filter(func(f: Dictionary) -> bool: return f["fx"] == "shards")
			ck(sh.size() == 1 and sh[0]["at"] == Vector2i(6, 10), "a shot-out wall lamp sheds shards onto its own side")
	ck(MapData.lamp_on(s.grid.cell(c).lamps, 3).is_empty(), "the wall lamp was shot out")

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

## A wall's chunks differ in shape and size; old saves without a shape still read.
func _chunk_shapes() -> void:
	var fx := FxDecals.new()
	var shapes := {}
	var sizes: Array[float] = []
	for k in 6:
		fx.apply([{"fx": "chunks", "at": Vector2i(10, 10 + k * 3), "from": Vector2i(9, 10 + k * 3), "fid": MCF.FEATURE_WALL, "env": "town", "seq": 100 + k}])
	for f: Dictionary in fx.flying:
		var parts := FxDecals.chunk_parts(str(f["kind"]))
		shapes[parts[1]] = true
		sizes.append(float(f["scale"]))
	ck(shapes.size() >= 4, "chunks come in several sharp shapes (%d)" % shapes.size())
	sizes.sort()
	ck(sizes[0] < 0.7 and sizes[-1] > 1.3, "and in different sizes (%.2f..%.2f)" % [sizes[0], sizes[-1]])
	ck(FxDecals.chunk_parts("chunk:wall_town")[0] == "wall_town", "a 0.12.1 chunk without a shape still reads")
	ck(FxDecals.CHUNK_SHAPES.all(func(p: Array) -> bool: return p.size() <= 6), "shapes are a few straight edges (no round blobs)")

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func grenades_and_walls() -> void:
	var map := arena()
	map.set_spawn(Vector2i(2, 12), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 2), "light_infantry", 1)
	map.set_cell(Vector2i(4, 12), MCF.FLOOR_NORMAL, 2.0, false, MCF.FEATURE_WALL)
	var r := resolver_for(map)
	var actor: UnitInstance = r.state.grid.cell(Vector2i(2, 12)).occupant
	actor.held_item_id = MCF.ITEM_FRAG
	var cells := r.grenade_target_cells(actor)
	ck(cells.has(Vector2i(3, 12)) and not cells.has(Vector2i(5, 12)), "no grenade target past a wall")
	var res := r.resolve(UseItemIntent.new(actor.id, Vector2i(5, 12)))
	ck(not res.ok and actor.held_item_id == MCF.ITEM_FRAG, "a throw through a wall is refused")

func _open_field(w: int, h: int, spawns: Array) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = true
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	return {"s": st, "r": r, "m": m}

## 4/8: противотанкист в (2, 2), боец противника в (9, 5) — не на линии огня. Раньше
## занятая клетка отвечала "" сразу; теперь — «не на линии».
func _blast_cell_checks_occupied_cells() -> void:
	var f := _open_field(16, 10, [[Vector2i(2, 2), "anti_tank", MCF.Owner.PLAYER_1],
			[Vector2i(9, 5), "light_infantry", MCF.Owner.PLAYER_2]])
	var r: GameActionResolver = f["r"]
	var st: GameState = f["s"]
	var at := st.grid.cell(Vector2i(2, 2)).occupant
	ck(r.can_blast_cell(at, Vector2i(9, 5)) != "", "an occupied cell off the firing line can't be blasted")
	# На линии и в пределах дальности — можно, как и любую другую клетку.
	var f2 := _open_field(16, 10, [[Vector2i(2, 2), "anti_tank", MCF.Owner.PLAYER_1],
			[Vector2i(6, 2), "light_infantry", MCF.Owner.PLAYER_2]])
	var at2: UnitInstance = (f2["s"] as GameState).grid.cell(Vector2i(2, 2)).occupant
	ck((f2["r"] as GameActionResolver).can_blast_cell(at2, Vector2i(6, 2)) == "",
			"an occupied cell on the line and in range can still be blasted")

## 7: стена с x ≥ 6 — ни один осколок окна в (4, 4) не ложится за неё.
func _shards_stop_at_walls() -> void:
	var fx := FxDecals.new()
	fx.bounds = Vector2(20, 20)
	fx.solid_at = func(cc: Vector2i) -> bool: return cc.x >= 6
	fx.apply([{"fx": "shards", "at": Vector2i(4, 4), "from": Vector2i(0, 4)}])
	ck(not fx.flying.is_empty(), "the window throws shards")
	for f: Dictionary in fx.flying:
		ck((f["to"] as Vector2).x < 6.0, "a shard flew into the wall: %s" % f["to"])
