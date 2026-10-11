class_name LightOccluders
extends RefCounted

## Client-only index over the existing visual-change journal. Cover below the
## sight-blocking height casts a visual shadow too; glass transmits light.
var grid_id := 0
var version := -1
var shapes: Dictionary = {}
var sources: Dictionary = {}
var revision := 0
var cells_read := 0
var changed: Dictionary = {}
var full_sync := false

func sync(grid: Grid) -> void:
	changed.clear()
	full_sync = false
	var full := grid_id != grid.get_instance_id() or version < GridCell.look_log_base
	if not full and version == GridCell.look_version: return
	full_sync = full
	if full:
		shapes.clear()
		sources.clear()
		for cell in grid.cells_flat(): _read(cell)
	else:
		for i in range((version - GridCell.look_log_base) * 2, GridCell.look_changes.size(), 2):
			var c := Vector2i(GridCell.look_changes[i], GridCell.look_changes[i + 1])
			if grid.in_bounds(c): changed[c] = true
		for c: Vector2i in changed: _read(grid.cell(c))
	grid_id = grid.get_instance_id()
	version = GridCell.look_version
	revision += 1

func _read(cell: GridCell) -> void:
	cells_read += 1
	var c := cell.coord
	if cell.cover_height > 0.0 and not MCF.is_glass(cell.feature_id) and cell.feature_id != MCF.FEATURE_TRENCH:
		shapes[c] = true
	else: shapes.erase(c)
	var emitters: Array = []
	var def: Dictionary = Furniture.DEFS.get(cell.feature_id, {})
	if def.get("emits_light", false):
		emitters.append({"kind": "fixture", "color": def.get("light_color", Color.WHITE),
			"range": float(def.get("light_range", 6.0)), "energy": float(def.get("light_energy", 0.85))})
	if not cell.fixture.is_empty():
		var fixture_def: Dictionary = Furniture.DEFS.get(str(cell.fixture[0]), {})
		emitters.append({"kind": "mounted", "color": fixture_def.get("light_color", Color.WHITE),
			"range": float(fixture_def.get("light_range", 6.0)), "energy": float(fixture_def.get("light_energy", 0.85)),
			"offset": Vector2(Furniture.N4[int(cell.fixture[2])]) * 0.55 if str(cell.fixture[0]) != "ceiling_lamp" else Vector2.ZERO})
	if cell.on_fire: emitters.append({"kind": "fire", "color": Color(1.0, 0.56, 0.22), "range": 3.5, "energy": 0.75})
	if cell.gas: emitters.append({"kind": "gas", "color": Color.WHITE, "range": 1.5, "energy": 0.10})
	if emitters.is_empty(): sources.erase(c)
	else: sources[c] = emitters
