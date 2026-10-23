class_name FirstPersonHost
extends Node

## The map editor's stand-in for the battle screen when you walk the map in first person
## (owner, fix-8 #17): the board built from the map with no fog of war and no battle going
## on, its placed soldiers standing where they were put. FirstPerson asks it what it would
## ask the battle screen.

const CELL := 32
## Everything is shown as it is: every mine, nothing remembered or hidden.
var editor_view := true
var state: GameState
var resolver: GameActionResolver
var _tiles: TerrainTiles
var _fx := FxDecals.new()
var _fog_mem := {}
var _fog_mem_corpses := {}
var _pending_death_ids := {}
var _walk_cells := {}
var _walk_offset := {}
var _veh_offset := {}
var _roofs := PackedByteArray()
var _bodies := {}
var _features := {}
var _feature_version := -1

func _init(map: MapData, tiles: TerrainTiles) -> void:
	state = map.build_state(1, null, true)
	resolver = GameActionResolver.new(state)
	resolver.fog_mode = MCF.Fog.OFF
	_tiles = tiles
	for c: GridCell in state.grid.cells_flat():
		if c.corpse_count > 0: _bodies[c.coord] = [null, c.corpse_count]

func _view_resolver() -> GameActionResolver:
	return resolver

func _viewing_side() -> int:
	return MCF.Owner.PLAYER_1

func _visible_before_impact(_viewer: int) -> Dictionary:
	return {}

func _draw_cell(u: UnitInstance) -> Vector2i:
	return u.coord

func _side_color(side: int) -> Color:
	return state.roster.color_of(side) if state.roster != null and MCF.is_player(side) else Color(0.62, 0.62, 0.64)

func _corpse_map() -> Dictionary:
	return _bodies

func _terrain_before_impact(base: Grid, _visible: Dictionary, _fog_on: bool) -> Grid:
	return base

func drone_lights(_viewer: int, _visible: Dictionary, _limited: bool) -> Array:
	return []

func _fp_roof(grid: Grid, env: String) -> PackedByteArray:
	if _roofs.size() != grid.width * grid.height:
		_roofs = FirstPersonBoard.roofed(grid, env)
	return _roofs

func _display_feature_cells(fid: String) -> Array[Vector2i]:
	if _feature_version != GridCell.feature_version:
		_features.clear()
		for cell: GridCell in state.grid.cells_flat():
			if cell.feature_id.is_empty(): continue
			if not _features.has(cell.feature_id): _features[cell.feature_id] = [] as Array[Vector2i]
			_features[cell.feature_id].append(cell.coord)
		_feature_version = GridCell.feature_version
	return _features.get(fid, [] as Array[Vector2i])
