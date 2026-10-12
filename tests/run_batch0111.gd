extends SceneTree
## 0.11.1 batch (issues-fix-11): lamp brightness, heights as numbers, HARD AI leaving
## announced zones, lamps that break like glass, see-through open doors.

var fails: PackedStringArray = []
func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond: fails.append(what)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_lamp_brightness()
	_height_numbers()
	_hard_ai_leaves_zones()
	_frag_and_lamps()
	_shot_lamp_shards()
	_open_door_see_through()
	print("batch 0.11.1: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

## Colour and brightness share the tint byte; a 0.11 byte (colour only) reads unchanged.
func _lamp_brightness() -> void:
	var t := Furniture.make_tint(4, 5)
	ck(Furniture.tint_colour(t) == 4 and Furniture.tint_level(t) == 5, "tint byte packs colour and brightness")
	ck(Furniture.light_color_of("wall_lamp", t) == Furniture.LIGHT_TINTS[4][1], "brightness keeps the chosen colour")
	ck(Furniture.light_scale_of(3) == 1.0, "a 0.11 colour-only byte is normal brightness")
	ck(Furniture.clean_tint(0xFF) == 0, "unknown colour and level fall back to the lamp's own")
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

## A HARD soldier inside an announced barrage walks out before shooting; it never ends
## an ordinary move inside one.
func _hard_ai_leaves_zones() -> void:
	var m := MapData.blank_arena(30, 20)
	m.set_spawn(Vector2i(10, 10), "light_infantry", 1)
	m.set_spawn(Vector2i(14, 10), "light_infantry", 0)   # in range: without the rule it would shoot
	var s := m.build_state(5)
	s.turns.round_order.assign([1, 0])
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	r.random_events = RandomEvents.new(true, true, 1)
	r.random_events.announce(RandomEvents.MORTAR, {"x": 8, "y": 8, "w": 5, "h": 5}, 1)
	var zone := Rect2i(8, 8, 5, 5)
	var normal := AIController.new(1, AIController.Difficulty.NORMAL)
	normal.bind_match(r)
	ck(not normal._decide(s) is MoveIntent, "NORMAL AI ignores the warning and shoots (unchanged)")
	var ai := AIController.new(1, AIController.Difficulty.HARD)
	ai.bind_match(r)
	var intent: Intent = ai._decide(s)
	ck(intent is MoveIntent and not zone.has_point((intent as MoveIntent).target),
			"HARD soldier in an announced barrage moves out of it before shooting")
	r.random_events.pending.clear()
	var calm := AIController.new(1, AIController.Difficulty.HARD)
	calm.bind_match(r)
	ck(not calm._decide(s) is MoveIntent, "with no warning HARD just shoots")

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
