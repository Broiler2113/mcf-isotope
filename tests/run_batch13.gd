extends SceneTree

## Правила batch 13, которые видны только в игре: обзор без ограничений по дальности и
## направлению, который рвут лишь стена и закрытый шлюз (живые, трупы и корпуса машин
## лучу не мешают), машина смотрит глазами экипажа со всего следа, а пустая — слепа;
## труп в проёме шлюза держит створки открытыми, пока его не вытащат; ластик на закупке
## снимает своих и возвращает очки; редактор меняет размер карты, не стирая её, и
## заливка не выходит за стены.

const TS = preload("res://tests/TestSupport.gd")

var fails: PackedStringArray = []
var _placement: Node = null
var _editor: Node = null
var _frame := 0

func ck(c: bool, w: String) -> void:
	if not c:
		fails.append(w)

func _initialize() -> void:
	_vision_and_airlocks()
	# Сцены закупки и редактора получают _ready не раньше первого кадра — их проверяем
	# из _process.
	GameConfig.placement_mode = GameConfig.Placement.ASYMMETRIC
	GameConfig.civilians_enabled = false
	GameConfig.roster = null
	NetHandoff.session = null
	_placement = load("res://scenes/Placement.tscn").instantiate()
	root.add_child(_placement)
	_editor = load("res://scenes/MapEditor.tscn").instantiate()
	root.add_child(_editor)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false
	_eraser()
	_editor_checks()
	if fails.is_empty():
		print("batch 13: unlimited sight, crewed vehicles see, airlock jammed by a body,"
				+ " the eraser refunds, the editor resizes without wiping")
		quit(0)
	else:
		printerr("batch 13: %d failure(s)" % fails.size())
		for f in fails:
			printerr("  " + f)
		quit(1)
	return true

func _vision_and_airlocks() -> void:
	var w := 30; var h := 20
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	# wall column at x=15 with a glass pane at y=5, an airlock at y=10
	for y in h:
		m.set_cell(Vector2i(15, y), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	m.set_cell(Vector2i(15, 5), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_GLASS)
	m.set_cell(Vector2i(15, 10), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_AIRLOCK)
	for x in range(0, 15):
		m.set_cell(Vector2i(x, 12), MCF.FLOOR_NORMAL, 0.0, false, MCF.FEATURE_WALL)
	m.set_spawn(Vector2i(5, 14), "tank", MCF.Owner.PLAYER_1, Vector2i(1, 0))
	m.set_spawn(Vector2i(2, 2), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(3, 2), "light_infantry", MCF.Owner.PLAYER_1)  # stands right of the first
	m.set_spawn(Vector2i(10, 5), "light_infantry", MCF.Owner.PLAYER_1)  # looks straight through the glass
	m.set_spawn(Vector2i(10, 10), "light_infantry", MCF.Owner.PLAYER_1)  # looks straight at the airlock
	m.set_spawn(Vector2i(4, 14), "light_infantry", MCF.Owner.PLAYER_1)  # will board the tank
	m.set_spawn(Vector2i(20, 5), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(20, 10), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(20, 15), "light_infantry", MCF.Owner.PLAYER_2)
	m.set_spawn(Vector2i(10, 2), "light_infantry", MCF.Owner.PLAYER_2)  # behind own unit line from (2,2)
	GameConfig.civilians_enabled = false
	var s := m.build_state(1)
	var r := GameActionResolver.new(s)
	r.fog_enabled = true
	while s.active_player() != MCF.Owner.PLAYER_1:
		r.resolve(EndTurnIntent.new())
	var driver: UnitInstance = s.grid.cell(Vector2i(4, 14)).occupant
	var tank0: Vehicle = s.all_vehicles()[0]
	var br := r.resolve(VehicleBoardIntent.new(driver.id, tank0.id))
	ck(br.ok, "boarded: " + br.reason)
	var vis := r.team_visible_coords(MCF.Owner.PLAYER_1)
	# units don't block: (10,2) seen from (2,2) through (3,2)
	ck(vis.has(Vector2i(10, 2)), "unit line not blocked by own unit")
	# tank sees in all directions incl. right/down from its 3x3
	ck(vis.has(Vector2i(12, 18)), "tank sees down-right")
	ck(vis.has(Vector2i(14, 19)), "tank sees far down-right")
	ck(vis.has(Vector2i(12, 14)), "tank sees right")
	ck(vis.has(Vector2i(5, 19)), "tank sees down")
	ck(vis.has(Vector2i(1, 19)), "tank sees down-left")
	ck(vis.has(Vector2i(0, 13)), "tank sees left")
	# glass transparent, wall blocks, closed airlock blocks
	ck(vis.has(Vector2i(20, 5)), "glass transparent")
	ck(not vis.has(Vector2i(20, 15)), "wall blocks")
	ck(not vis.has(Vector2i(20, 10)), "closed airlock blocks")
	# infinite range: far corner visible
	ck(vis.has(Vector2i(14, 19)), "far cell visible")
	# empty vehicle sees nothing: unload crew by killing them
	var tank: Vehicle = s.all_vehicles()[0]
	var crew_n := tank.occupants.size()
	ck(crew_n > 0, "tank has crew")
	# open the airlock: put a P2 unit next to it
	var u2: UnitInstance = s.grid.cell(Vector2i(20, 10)).occupant
	s.grid.move_occupant(u2.coord, Vector2i(16, 10))
	r.update_airlocks()
	vis = r.team_visible_coords(MCF.Owner.PLAYER_1)
	ck(vis.has(Vector2i(16, 10)), "open airlock passes sight")
	# corpse in the airlock keeps it open (batch 13 #4)
	u2.status = MCF.Status.CORPSE
	s.grid.move_occupant(Vector2i(16, 10), Vector2i(15, 10))
	r.update_airlocks()
	ck(s.grid.cell(Vector2i(15, 10)).cover_height == 0.0, "airlock with corpse stays open")
	s.grid.cell(Vector2i(15, 10)).occupant = null
	r.update_airlocks()
	ck(s.grid.cell(Vector2i(15, 10)).cover_height >= MCF.WALL_HEIGHT, "airlock closes once the body is gone")
	# empty vehicle: kill crew -> no vision from tank
	for id in tank.occupants.duplicate():
		s.units[id].status = MCF.Status.CORPSE
	tank.occupants.clear()
	vis = r.team_visible_coords(MCF.Owner.PLAYER_1)
	ck(not vis.has(Vector2i(12, 18)), "empty tank is blind (cell only tank could see)")

func _eraser() -> void:
	var p = _placement
	p.brush_unit = "light_infantry"
	p._click_cell(Vector2i(2, 2)); p._click_cell(Vector2i(3, 2)); p._click_cell(Vector2i(4, 2))
	ck(p._side_unit_count(0) == 3, "placed 3")
	var spent0: int = p.spent[0]
	p._eraser_btn.button_pressed = true  # toggled -> _toggle_eraser
	ck(p._erasing and p.brush_unit == "", "eraser on clears the brush")
	ck(p._erase_at(Vector2i(2, 2)), "erase one")
	ck(p._side_unit_count(0) == 2 and p.spent[0] == spent0 - p._cost("light_infantry"), "count 2 and refund")
	p._ptool = p.PTool.RECT
	p._erase_many(p._rect_fill_cells(Vector2i(0, 0), Vector2i(10, 10)))
	ck(p._side_unit_count(0) == 0 and p.spent[0] == 0, "rect erase clears all")
	p._on_pick_unit("sniper")
	ck(not p._erasing and not p._eraser_btn.button_pressed, "picking a unit turns eraser off")

func _editor_checks() -> void:
	var ed = _editor
	ed._w_spin.value = 120
	ed._h_spin.value = 90
	ed._on_resize()
	ck(ed.map.width == 120 and ed.map.height == 90, "editor resized")
	ed._select_brush("floor", "Floor")
	ed.brush_size = 5
	ed._paint(Vector2i(50, 50))
	ck(not ed.map.get_space(Vector2i(52, 52)) and not ed.map.get_space(Vector2i(48, 48)),
			"brush size 5 paints a 5x5 block")
	ed._select_brush(MCF.FEATURE_WALL, "Wall")
	for c in ed._rect_cells(Vector2i(10, 10), Vector2i(60, 60)):
		ed._apply_brush(c)
	ed._select_brush("grass", "Grass Floor")
	ed._push_undo()  # то, что делает щелчок мыши перед заливкой
	ed._flood_fill(Vector2i(30, 30))
	ck(ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS
			and ed.map.get_floor(Vector2i(5, 5)) != MCF.FLOOR_GRASS, "flood fill stays inside the walls")
	ed._w_spin.value = 130
	ed._h_spin.value = 70
	ed._on_resize()
	ck(ed.map.get_feature(Vector2i(10, 30)) == MCF.FEATURE_WALL
			and ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS, "resize keeps what was drawn")
	ck(ed._base_img.get_width() == 130 and ed._base_img.get_height() == 70, "base texture follows the size")
	# Откат/повтор (batch 14): снимок на действие, размер откатывается вместе с содержимым.
	ed._undo()
	ck(ed.map.width == 120 and ed.map.height == 90 and ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS,
			"undo restores the previous size and keeps earlier strokes")
	ed._undo()
	ck(ed.map.get_floor(Vector2i(30, 30)) != MCF.FLOOR_GRASS and ed.map.get_feature(Vector2i(10, 30)) == MCF.FEATURE_WALL,
			"second undo takes the flood fill back but keeps the walls")
	ed._redo()
	ck(ed.map.get_floor(Vector2i(30, 30)) == MCF.FLOOR_GRASS, "redo brings the fill back")
	ed._select_brush(MCF.FEATURE_SANDBAGS, "Sandbags")
	ed._push_undo()
	ed._paint(Vector2i(30, 30))
	ck(ed._redo_stack.is_empty() and ed.map.get_feature(Vector2i(30, 30)) == MCF.FEATURE_SANDBAGS,
			"a new stroke after undo clears the redo branch")
