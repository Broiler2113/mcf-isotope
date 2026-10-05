extends SceneTree
## Batch soil-rulers-laser: soil in bunkers acts as a wall, a laser-blown wall leaves rubble,
## several rulers stay on the field at once.
var fails := 0
var _main: Node = null
var _frames := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1

func _initialize() -> void:
	# --- soil fills the bunker, plain walls only where rooms are ---
	var m := MapGen.generate({"style": MapGen.Style.BUNKER, "size": 1, "seed": 4242, "zones": 2,
			"units": 10, "civilians": 0, "civilian_count": 0})
	var soil := 0
	for f in m.feature_id:
		if f == MCF.FEATURE_SOIL:
			soil += 1
	ck(soil > 0, "a bunker map is dug into soil (%d cells)" % soil)
	var town := MapGen.generate({"style": MapGen.Style.TOWN, "size": 1, "seed": 4242, "zones": 2,
			"units": 10, "civilians": 0, "civilian_count": 0, "space": false})
	ck(not town.feature_id.has(MCF.FEATURE_SOIL), "other styles have no soil")

	# --- soil plays exactly like a wall ---
	var a := MapData.new(20, 10)
	for y in 10:
		for x in 20:
			a.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	a.set_cell(Vector2i(8, 5), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_SOIL)
	a.set_cell(Vector2i(8, 3), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	a.set_spawn(Vector2i(4, 5), "marksman", 0)
	a.set_spawn(Vector2i(4, 3), "marksman", 0)
	a.set_spawn(Vector2i(18, 8), "light_infantry", 1)
	GameConfig.civilians_enabled = false
	var st := a.build_state(1)
	var r := GameActionResolver.new(st)
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	var sc := st.grid.cell(Vector2i(8, 5))
	var wc := st.grid.cell(Vector2i(8, 3))
	ck(sc.is_wall() and sc.blocks_sight() and sc.cover_height == wc.cover_height, "soil is a full wall")
	ck(GameActionResolver.BREAKABLE.has(MCF.FEATURE_SOIL), "soil can be broken like a wall")
	ck(MCF.LASER_COST[MCF.FEATURE_SOIL] == MCF.LASER_COST[MCF.FEATURE_WALL], "the laser pays the same to burn it")

	# --- laser through a wall leaves rubble, like a tank ---
	var mk := st.grid.cell(Vector2i(4, 5)).occupant
	var res := r.resolve(ShootIntent.new(mk.id, -1, -1, Vector2i(12, 5)))
	var debris: Array = []
	for e in res.fx:
		if e.get("fx", "") == "debris":
			debris.append_array(e["cells"])
	ck(res.ok and sc.feature_id == "" and debris.has(Vector2i(8, 5)),
			"the burnt soil cell is marked destroyed (%s)" % [debris])
	var mk2 := st.grid.cell(Vector2i(4, 3)).occupant
	res = r.resolve(ShootIntent.new(mk2.id, -1, -1, Vector2i(12, 3)))
	debris = []
	for e in res.fx:
		if e.get("fx", "") == "debris":
			debris.append_array(e["cells"])
	ck(res.ok and debris.has(Vector2i(8, 3)), "a burnt wall is marked destroyed too")

	# --- no aiming past a body; the aim label for every shooter ---
	var c2 := MapData.new(24, 10)
	for y in 10:
		for x in 24:
			c2.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	c2.set_cell(Vector2i(10, 8), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_GLASS)
	for sp in [[Vector2i(2, 2), "light_infantry", 0], [Vector2i(2, 4), "anti_tank", 0],
			[Vector2i(2, 6), "marksman", 0], [Vector2i(2, 8), "flamethrower", 0],
			[Vector2i(8, 2), "light_infantry", 1], [Vector2i(12, 2), "light_infantry", 1]]:
		c2.set_spawn(sp[0], sp[1], sp[2])
	var st2 := c2.build_state(1)
	var r2 := GameActionResolver.new(st2)
	r2.fog_mode = MCF.Fog.OFF
	while st2.active_player() != 0:
		r2.resolve(EndTurnIntent.new())
	var li := st2.grid.cell(Vector2i(2, 2)).occupant
	var front := st2.grid.cell(Vector2i(8, 2)).occupant
	var back := st2.grid.cell(Vector2i(12, 2)).occupant
	var ids: Array = r2.shootable_target_ids(li)
	ck(ids.has(front.id) and not ids.has(back.id), "the unit behind another cannot be aimed at")
	ck(r2.can_shoot(li, back) == "Another unit is in the way", "and the reason says why")
	var mk3 := st2.grid.cell(Vector2i(2, 6)).occupant
	ck(r2.aim_need(mk3, Vector2i(12, 6)) == 0, "the laser needs no roll")
	var at := st2.grid.cell(Vector2i(2, 4)).occupant
	var at_need := r2.aim_need(at, Vector2i(9, 4))
	ck(at_need == Combat.hit_number(7, at.fire_range()) and at_need >= 1 and at_need <= 6,
			"the anti-tank charge shows its own roll (%d+)" % at_need)
	ck(r2.aim_need(st2.grid.cell(Vector2i(2, 8)).occupant, Vector2i(5, 8)) == 0, "the flame jet needs no roll")
	# 0.9.2: окно — обычная очередь, и в стекло надо попасть (раньше било без броска).
	var pane_need := r2.aim_need(li, Vector2i(10, 8))
	ck(pane_need == r2.pane_hit_need(li, Vector2i(10, 8)) and pane_need >= 1 and pane_need <= 6,
			"a window takes a roll to hit (%d+)" % pane_need)
	ck(r2.aim_need(li, front.coord, front) == r2.hit_need_for(li, front), "a rifle shows hit_need_for")

	# --- a move animates as a walk and stays undoable ---
	var mres := r2.resolve(MoveIntent.new(li.id, Vector2i(2, 0)))
	var walks := mres.dice_events.filter(func(e): return e.get("kind", "") == "walk")
	ck(mres.ok and walks.size() == 1 and walks[0]["path"].back() == Vector2i(2, 0), "a soldier's move is played as a walk")
	ck(not r2._is_irreversible(MoveIntent.new(li.id, Vector2i(2, 1)), mres), "and the move can still be undone")

	# --- several rulers at once, on the real battle screen ---
	var b := MapData.new(20, 10)
	for y in 10:
		for x in 20:
			b.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	b.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	b.set_spawn(Vector2i(17, 5), "light_infantry", 1)
	MapHandoff.pending = b
	GameConfig.roster = Roster.default_duel(false, AIController.Difficulty.EASY)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false
	_main._enter_ruler()
	# Clicks go through _pos_to_cell(get_global_mouse_position()); headless has no mouse,
	# so drive the same branch with the rulers' own state instead.
	for pair in [[Vector2i(1, 1), Vector2i(6, 1)], [Vector2i(1, 3), Vector2i(1, 8)], [Vector2i(3, 3), Vector2i(9, 9)]]:
		_main._ruler_a = pair[0]
		_main._rulers.append([_main._ruler_a, pair[1]])
		_main._ruler_a = Vector2i(-1, -1)
	ck(_main._rulers.size() == 3, "three rulers stay on the field")
	var bs := InputEventKey.new()
	bs.keycode = KEY_BACKSPACE
	bs.pressed = true
	_main._unhandled_input(bs)
	ck(_main._rulers.size() == 2, "Backspace removes the last ruler")
	_main._refresh_ruler_button()
	ck(_main._ruler_btn.text == "Ruler: on (2)", "the button counts them (%s)" % _main._ruler_btn.text)
	_main._enter_ruler()   # toggles off
	ck(_main._rulers.is_empty(), "leaving the ruler clears them all")
	print("soil/rulers: %d failure(s)" % fails)
	quit(1 if fails else 0)
	return true
