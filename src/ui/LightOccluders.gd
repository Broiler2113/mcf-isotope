class_name LightOccluders
extends RefCounted

## Client-only index over the visual-change journal (GridCell.look_changes): which cells
## stop light and which cells emit it. Light is stopped by structure only — a full 2 m
## wall, closed airlock or rock; glass, open doors and all furniture let it through (0.11).
## Nothing here touches the simulation.
var grid_id := 0
var version := -1
## Flat index -> true for every light-blocking cell.
var shapes: Dictionary = {}
## Vector2i -> Array of emitters {kind, color, range, energy, offset}.
var sources: Dictionary = {}
var revision := 0
var cells_read := 0
var changed: Dictionary = {}
var full_sync := false

## Only structure stops light: walls, closed doors and airlocks, rock. Furniture never
## casts a light shadow, even 2 m tall — those shadows read as random black shapes in the
## middle of rooms (0.11 playtest).
static func blocks_light(cell: GridCell) -> bool:
	return cell.cover_height >= MCF.WALL_HEIGHT and not MCF.is_glass(cell.feature_id) \
			and not Furniture.is_furniture(cell.feature_id)

func sync(grid: Grid) -> void:
	changed.clear()
	full_sync = false
	var full := grid_id != grid.get_instance_id() or version < GridCell.look_log_base
	if not full and version == GridCell.look_version: return
	full_sync = full
	if full:
		shapes.clear()
		sources.clear()
		for cell in grid.cells_flat(): _read(cell, grid.width)
	else:
		for i in range((version - GridCell.look_log_base) * 2, GridCell.look_changes.size(), 2):
			var c := Vector2i(GridCell.look_changes[i], GridCell.look_changes[i + 1])
			if grid.in_bounds(c): changed[c] = true
		for c: Vector2i in changed: _read(grid.cell(c), grid.width)
	grid_id = grid.get_instance_id()
	version = GridCell.look_version
	revision += 1

func _read(cell: GridCell, gw: int) -> void:
	cells_read += 1
	var c := cell.coord
	if blocks_light(cell): shapes[c.y * gw + c.x] = true
	else: shapes.erase(c.y * gw + c.x)
	var emitters: Array = []
	var def: Dictionary = Furniture.DEFS.get(cell.feature_id, {})
	if def.get("emits_light", false):
		emitters.append(_emitter("fixture", def, Vector2.ZERO))
	if not cell.fixture.is_empty():
		var fixture_def: Dictionary = Furniture.DEFS.get(str(cell.fixture[0]), {})
		# A wall lamp shines from the face of its wall, half a cell out into the room.
		var offset := Vector2.ZERO if str(cell.fixture[0]) == "ceiling_lamp" \
				else Vector2(Furniture.N4[int(cell.fixture[2])]) * 0.55
		emitters.append(_emitter("mounted", fixture_def, offset))
	if cell.on_fire:
		emitters.append({"kind": "fire", "color": Color(1.0, 0.55, 0.2), "range": 4.5,
				"energy": 0.95, "offset": Vector2.ZERO})
	if emitters.is_empty(): sources.erase(c)
	else: sources[c] = emitters

static func _emitter(kind: String, def: Dictionary, offset: Vector2) -> Dictionary:
	return {"kind": kind, "color": def.get("light_color", Color.WHITE),
			"range": float(def.get("light_range", 6.0)), "energy": float(def.get("light_energy", 0.85)),
			"offset": offset}
