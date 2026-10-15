class_name ReplayCheckpoint
extends RefCounted

## Dense checkpoints stay compact in memory and inside the existing compressed JSON.
## Payloads contain only plain state data; bytes_to_var does not allow objects.
const ACTION_INTERVAL := 48

## Is a checkpoint due after `since` actions? Every handoff on ordinary boards; on a huge
## board one pack costs ~200 ms (Colossal), so handoffs closer than cells/2048 actions apart
## and the plain interval stretch with the board. Seeking replays at most that many actions.
static func due(state: GameState, since: int, handoff: bool) -> bool:
	var cells := state.grid.width * state.grid.height
	if since >= maxi(ACTION_INTERVAL, cells / 1024):
		return true
	return handoff and since >= cells / 2048
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
	fx.solid_at = func(c: Vector2i) -> bool: return FxDecals.solid_in(state, c)
	fx.space_at = func(c: Vector2i) -> bool: return FxDecals.space_in(state, c)
	return fx

static func apply_effects(fx: FxDecals, result: ActionResult) -> void:
	if result == null or result.fx.is_empty():
		return
	fx.apply(result.fx)
	fx.advance(10.0) # jumping keeps settled decals, not transient flashes or flights
