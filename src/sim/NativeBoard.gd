class_name NativeBoard
extends RefCounted

## The board as the native AI kernels see it (MCFPlanScorer, native/visuals/src/ai_kernel.cpp):
## flat per-cell facts shared by the turn plan (AIPlanner), the decisions (AIController) and
## the civilians' wake-up check (ResolverWorld). Built once per board and patched from the look
## journal; vehicles are read afresh for each scorer.

## Board bits for the native scorer: per cell, exactly what _score_cell and _fire_ease read off
## the board. Built once per board, then patched from the look journal like
## AIController._walk_mask; fire_need depends on the match's corpse rules, so they are keyed.
const SB_WALL := 1
const SB_COVER := 2
const SB_SHELTER := 4
const SB_TRENCH := 8
const SB_HEDGEHOG := 16
const SB_DOT_OPEN := 32
const SB_FIRE := 64
const SB_SPREAD := 128
const SB_OBSCURED := 256
const SB_GLASS := 512     # a pane: a civilian sees through it
const SB_COVER_SHIFT := 12   # 3 bits: MCF.COVER_MOD.get(cover_height, 1) of a cell with cover
const SB_SHIELD_SHIFT := 15  # 3 bits: the hit penalty this cell gives a shot past it
## What a marksman's beam meets in each cell (GameActionResolver._laser_trace): the kind in bits
## 0-2, its cost or durability above. Kept with _sb, from the same journal.
const SL_NONE := 0
const SL_STOP := 1        # armour plate, the edge of the world
const SL_FURNITURE := 2   # costs its durability
const SL_GLASS := 3
const SL_BOX := 4         # a durable box (DOT): cracks by POTENTIAL_PER_DURABILITY
const SL_FIXED := 5       # MCF.LASER_COST
const SL_WALL := 6        # bare terrain wall
const SL_SHIFT := 3
## The occupant of a cell, for the beam.
const SO_ALIVE := 1
const SO_FIELD := 2
const SO_SHIELD := 4
const SO_CORPSE := 8
static var _sb: PackedInt32Array = PackedInt32Array()
static var _sl: PackedInt32Array = PackedInt32Array()
static var _sb_grid := 0
static var _sb_look := -1
static var _sb_legacy := false

static func bits(c: GridCell, r: GameActionResolver) -> int:
	var h := c.cover_height
	var fid := c.feature_id
	var bits := 0
	if h >= MCF.WALL_HEIGHT:
		bits |= SB_WALL
	if c.has_cover():
		bits |= SB_COVER | (int(MCF.COVER_MOD.get(h, 1)) << SB_COVER_SHIFT)
	# shelter(): the same condition, one neighbour at a time.
	if h >= MCF.WALL_HEIGHT or MCF.COVER_MOD.has(h) \
			or (Furniture.is_furniture(fid) and Furniture.cover_penalty(h) > 0):
		bits |= SB_SHELTER
	if fid == MCF.FEATURE_TRENCH:
		bits |= SB_TRENCH
	elif fid == MCF.FEATURE_HEDGEHOG_SANDBAGS:
		bits |= SB_HEDGEHOG
	elif fid == MCF.FEATURE_DOT_OPEN:
		bits |= SB_DOT_OPEN
	if c.on_fire:
		bits |= SB_FIRE
	if r.fire_need(c) <= 6:
		bits |= SB_SPREAD
	if c.obscured():
		bits |= SB_OBSCURED
	if MCF.is_glass(fid):
		bits |= SB_GLASS
	# What this cell takes off a shot at its neighbour behind it (_hit_chance's "shield").
	var shield: int = Furniture.cover_penalty(h) if Furniture.is_furniture(fid) else int(MCF.COVER_MOD.get(h, 0))
	return bits | (clampi(shield, 0, 7) << SB_SHIELD_SHIFT)

static func laser(c: GridCell) -> int:
	var fid := c.feature_id
	if fid == MCF.FEATURE_ARMOR_WALL or fid == MCF.FEATURE_BOUNDARY:
		return SL_STOP
	if Furniture.is_furniture(fid):
		return SL_FURNITURE | (c.feature_durability << SL_SHIFT)
	if fid != "" and MCF.LASER_COST.has(fid):
		if fid == MCF.FEATURE_GLASS:
			return SL_GLASS
		if c.feature_durability > 0:
			return SL_BOX | (c.feature_durability << SL_SHIFT)
		var cost := int(MCF.LASER_COST[fid])
		if fid == MCF.FEATURE_DIRT_PILE and c.cover_height >= MCF.WALL_HEIGHT:
			cost = MCF.LASER_COST_TERRAIN_WALL
		return SL_FIXED | (cost << SL_SHIFT)
	return SL_WALL if c.is_wall() else SL_NONE

static func board(grid: Grid, r: GameActionResolver) -> PackedInt32Array:
	var w := grid.width
	var h := grid.height
	if grid.get_instance_id() != _sb_grid or _sb_look < GridCell.look_log_base \
			or _sb.size() != w * h or _sb_legacy != r.legacy_corpse_rules:
		_sb.resize(w * h)
		_sl.resize(w * h)
		var cells := grid.cells_flat()
		for i in cells.size():
			_sb[i] = bits(cells[i], r)
			_sl[i] = laser(cells[i])
		_sb_grid = grid.get_instance_id()
		_sb_legacy = r.legacy_corpse_rules
	elif _sb_look != GridCell.look_version:
		var ch := GridCell.look_changes
		var i: int = (_sb_look - GridCell.look_log_base) * 2
		while i < ch.size():
			var x := ch[i]
			var y := ch[i + 1]
			if x < w and y < h:
				_sb[y * w + x] = bits(grid.cell_fast(x, y), r)
				_sl[y * w + x] = laser(grid.cell_fast(x, y))
			i += 2
	_sb_look = GridCell.look_version
	return _sb

## The cells under vehicle hulls and the hull on each (Grid.vehicle_id), as flat indices.
static func vehicle_layer(state: GameState) -> Array:
	var grid := state.grid
	var cells := PackedInt32Array()
	var ids := PackedInt32Array()
	for veh: Vehicle in state.all_vehicles():
		for fc: Vector2i in veh.footprint():
			if grid.in_bounds(fc) and grid.cell_fast(fc.x, fc.y).vehicle_id != -1:
				cells.append(fc.y * grid.width + fc.x)
				ids.append(grid.cell_fast(fc.x, fc.y).vehicle_id)
	return [cells, ids]

## A native scorer with this board handed over (set_board), or null: GDScript does the work.
static func scorer(state: GameState, r: GameActionResolver, layer: Array = []) -> RefCounted:
	var native := NativeKernels.plan_scorer()
	if native == null:
		return null
	if layer.is_empty():
		layer = vehicle_layer(state)
	var flags := board(state.grid, r)
	if not native.set_board({"width": state.grid.width, "height": state.grid.height, "flags": flags,
			"laser": _sl, "vehicle_cells": layer[0], "vehicle_ids": layer[1]}):
		return null
	return native
