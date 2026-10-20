extends "res://tests/SuiteBase.gd"
## Sight in play: no range or direction limit, cut only by a wall or a closed airlock (the
## living, bodies and hulls never block a ray); a vehicle sees with its crew's eyes from its
## whole footprint and an empty one is blind; a body in an airlock keeps it open until moved.

func run() -> void:
	_vision_and_airlocks()

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
