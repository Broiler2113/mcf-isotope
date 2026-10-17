class_name RejoinStore
extends RefCounted

## Local connection credentials only. Never included in saves, replays or rosters.
const PATH := "user://last_match.cfg"

static func token() -> String:
	return Crypto.new().generate_random_bytes(24).hex_encode()

static func read() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK: return {}
	var data: Variant = cfg.get_value("match", "connection", {})
	return data if data is Dictionary else {}

static func remember(route: Dictionary, identity: String) -> void:
	if route.is_empty() or identity.is_empty(): return
	var cfg := ConfigFile.new()
	cfg.set_value("match", "connection", route.merged({"token": identity}))
	cfg.save(PATH)
