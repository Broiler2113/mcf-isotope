extends SceneTree
## Bodies never land on a cell with a unit (2026-10-18 owner request): drops, drags, bodies
## thrown by a broken corpse wall, cells under a drone, and the map editor's body brush.

var fails := 0
var _frame := 0
var _editor: Node = null

func ck(ok: bool, message: String) -> void:
	print(("ok   " if ok else "FAIL ") + message)
	if not ok: fails += 1

func _initialize() -> void:
	_editor = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(_editor)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 3: return false
	battle()
	editor()
	print("corpse drop: %d failure(s)" % fails)
	quit(0 if fails == 0 else 1)
	return true

func arena() -> GameActionResolver:
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	GameConfig.random_events_enabled = false
	GameConfig.civilians_enabled = false
	GameConfig.roster = Roster.default_duel(false)
	var map := MapData.blank_arena(24, 12)
	map.set_spawn(Vector2i(2, 5), "light_infantry", 0)
	map.set_spawn(Vector2i(20, 5), "light_infantry", 1)
	var s := map.build_state(5)
	s.turns.round_order = [0, 1]
	s.turns.active_index = 0
	var r := GameActionResolver.new(s)
	r.fog_enabled = false
	return r

func add(r: GameActionResolver, kind: String, c: Vector2i, side: int = 0, occupy := true) -> UnitInstance:
	return r.state.spawn_unit(load("res://src/data/units/%s.tres" % kind), c, side, occupy)

func battle() -> void:
	var r := arena()
	var carrier := r.state.grid.cell(Vector2i(2, 5)).occupant
	carrier.carried_corpses = 1
	carrier.remaining_ap = 3
	var mate := add(r, "light_infantry", Vector2i(3, 5))
	ck(not r.corpse_drop_cells(carrier).has(mate.coord), "a soldier's cell is not offered as a drop spot")
	ck(not r.resolve(DropCorpseIntent.new(carrier.id, mate.coord)).ok, "dropping a body on a soldier is refused")
	var drone := add(r, "drone", Vector2i(3, 4), 0, false)
	drone.is_drone = true
	ck(not r.can_drop_corpse_at(Vector2i(3, 4)) and not r.corpse_drop_cells(carrier).has(Vector2i(3, 4)), "the cell under a drone takes no body")
	ck(r.resolve(DropCorpseIntent.new(carrier.id, Vector2i(1, 5))).ok, "a free neighbouring cell still takes it")

	# A corpse wall broken by a beam throws its bodies past soldiers, never onto them.
	r = arena()
	var stand := add(r, "light_infantry", Vector2i(9, 8))
	r.state.grid.cell(Vector2i(8, 8)).corpse_count = 0
	r._scatter_corpses(Vector2i(8, 8), Vector2i(1, 0), 3)
	ck(r.state.grid.cell(stand.coord).corpse_count == 0 and stand.is_alive(), "scattered bodies skip a soldier's cell")
	ck(r.state.grid.cell(Vector2i(8, 8)).corpse_count == 1 and r.state.grid.cell(Vector2i(10, 8)).corpse_count == 1, "they land on the free cells around it")

func editor() -> void:
	var e: Node = _editor
	var c := Vector2i(4, 4)
	e._set_spawn(c, "light_infantry", 0)
	e.brush = e.CORPSE_BRUSH
	e.tool = e.Tool.BRUSH
	var ci: int = c.y * e.map.width + c.x
	e._press(c, false)
	e._release(c)
	ck(not e.map.corpses.has(ci), "the editor's body brush refuses a cell with a unit")
	var d := Vector2i(6, 4)
	var di: int = d.y * e.map.width + d.x
	e._press(d, false)
	e._release(d)
	ck(e.map.corpses.has(di), "the brush still lays a body on a free cell")
	e._set_spawn(d, "light_infantry", 0)
	ck(not e.map.corpses.has(di), "placing a unit on a body clears the body")
