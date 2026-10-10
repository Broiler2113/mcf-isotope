class_name ReplayCheckpoint
extends RefCounted

## Dense checkpoints stay compact in memory and inside the existing compressed JSON.
## Payloads contain only plain state data; bytes_to_var does not allow objects.
const ACTION_INTERVAL := 48
const MAX_BYTES := 64 * 1024 * 1024

static func pack(state: GameState, resolver: GameActionResolver, fx: FxDecals, mid_turn: bool) -> Dictionary:
	var payload := {"state": StateCodec.encode(state), "rules": StateCodec.encode_rules(resolver), "fx": fx.to_dict()}
	var raw := var_to_bytes(payload)
	return {"z": Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD)),
			"bytes": raw.size(), "mid_turn": mid_turn}

static func unpack(frame: Dictionary) -> Dictionary:
	if not frame.has("z"):
		return frame
	var size := int(frame.get("bytes", 0))
	if size <= 0 or size > MAX_BYTES:
		return {}
	var packed := Marshalls.base64_to_raw(str(frame.z))
	var raw := packed.decompress(size, FileAccess.COMPRESSION_ZSTD)
	var value: Variant = bytes_to_var(raw)
	return value if value is Dictionary else {}

static func effects(state: GameState) -> FxDecals:
	var fx := FxDecals.new()
	fx.bounds = Vector2(state.grid.width, state.grid.height)
	var grid := state.grid
	fx.solid_at = func(c: Vector2i) -> bool:
		var cell := grid.cell(c)
		return cell == null or cell.cover_height >= MCF.WALL_HEIGHT
	fx.space_at = func(c: Vector2i) -> bool:
		var cell := grid.cell(c)
		return cell != null and cell.is_space
	return fx

static func apply_effects(fx: FxDecals, result: ActionResult) -> void:
	if result == null or result.fx.is_empty():
		return
	fx.apply(result.fx)
	fx.advance(10.0) # jumping keeps settled decals, not transient flashes or flights
