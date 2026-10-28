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
	return seal(payload(state, resolver, fx), mid_turn)

## What a checkpoint holds, read from the live match (main thread). Every container in it is
## new or never written again (StateCodec's cached cell records), so seal() may run elsewhere.
static func payload(state: GameState, resolver: GameActionResolver, fx: FxDecals) -> Dictionary:
	return {"state": StateCodec.encode(state), "rules": StateCodec.encode_rules(resolver), "fx": fx.to_dict(), "visibility": resolver.explored.duplicate(true)}

## Bytes, compressed, as stored. Reads nothing but payload: safe on a worker thread.
static func seal(data: Dictionary, mid_turn: bool) -> Dictionary:
	var raw := var_to_bytes(data)
	return {"z": Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD)),
			"bytes": raw.size(), "mid_turn": mid_turn}

## seal() for a worker thread: the result goes into box[0].
static func seal_into(box: Array, data: Dictionary, mid_turn: bool) -> void:
	box[0] = seal(data, mid_turn)

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
