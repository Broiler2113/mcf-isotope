class_name CorpseIdentity
extends RefCounted

const NOWHERE := Vector2i(-1, -1)

static func id_label(unit: UnitInstance) -> String:
	return "U%d%s" % [unit.id, "-" if unit.status == MCF.Status.CORPSE else ""]

static func cell_of(state: GameState, unit: UnitInstance) -> Vector2i:
	if unit.corpse_carrier_id >= 0:
		var carrier := state.get_unit(unit.corpse_carrier_id)
		return carrier.coord if carrier != null and carrier.is_on_field() else NOWHERE
	if unit.status != MCF.Status.CORPSE: return unit.coord
	var cell := state.grid.cell(unit.coord)
	if cell != null and (cell.occupant == unit or (unit.corpse_stacked and cell.corpse_count > 0)):
		return unit.coord
	if unit.aboard_vehicle_id >= 0:
		var vehicle := state.get_vehicle(unit.aboard_vehicle_id)
		if vehicle != null: return vehicle.origin
	return NOWHERE

static func carried(state: GameState, carrier: int) -> Array[UnitInstance]:
	var out: Array[UnitInstance] = []
	for unit: UnitInstance in state.all_units():
		if unit.status == MCF.Status.CORPSE and unit.corpse_carrier_id == carrier: out.append(unit)
	return out

static func stacked(state: GameState, at: Vector2i) -> Array[UnitInstance]:
	var out: Array[UnitInstance] = []
	for unit: UnitInstance in state.all_units():
		if unit.status == MCF.Status.CORPSE and unit.corpse_stacked and unit.corpse_carrier_id < 0 and unit.coord == at: out.append(unit)
	return out

static func take(body: UnitInstance, carrier: UnitInstance) -> void:
	body.corpse_carrier_id = carrier.id
	body.corpse_stacked = false
	body.coord = carrier.coord
	body.aboard_vehicle_id = -1
	body.borg_id = -1

static func cleanup(state: GameState) -> void:
	for body: UnitInstance in state.all_units():
		if body.corpse_stacked or body.corpse_carrier_id >= 0:
			if cell_of(state, body) == NOWHERE: state.remove_unit(body.id)
