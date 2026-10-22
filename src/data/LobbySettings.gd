class_name LobbySettings
extends RefCounted

## Save metadata, separate from the simulation and from live network identities.
static func capture() -> Dictionary:
	var settings := NetHandoff.encode_rules()
	for key: String in ["pv", "roster", "spectators"]: settings.erase(key)
	settings["map_path"] = GameConfig.map_path
	settings["allow_spectators"] = NetHandoff.allow_spectators
	return settings

static func apply(settings: Dictionary) -> void:
	if settings.is_empty(): return
	NetHandoff.apply_rules(settings, false)
	GameConfig.map_path = str(settings.get("map_path", ""))
	NetHandoff.allow_spectators = bool(settings.get("allow_spectators", true))

## Rules in the saved battle are authoritative; preparation-only settings stay intact.
static func with_rules(settings: Dictionary, rules: Dictionary) -> Dictionary:
	var out := settings.duplicate(true)
	out["cheats"] = rules.get("cheats", false)
	out["ais"] = rules.get("ai_speed", out.get("ais", 1.0))
	out["f"] = int(rules.get("fog", out.get("f", MCF.Fog.OFF)))
	out["ff"] = bool(rules.get("friendly_fire", out.get("ff", true)))
	var mode: Dictionary = rules.get("mode", {})
	var mode_keys := {"kind": "gm", "zone_count": "cz", "target": "ct", "waves_total": "hw",
			"wave_every": "he", "wave_start": "hs", "excluded_units": "wx"}
	for key: String in mode_keys:
		if mode.has(key): out[mode_keys[key]] = mode[key]
	var events: Dictionary = rules.get("events", rules.get("events_cfg", {}))
	var event_keys := {"enabled": "re", "mandatory": "rm", "interval": "ri", "weights": "rw",
			"army_difficulty": "rad", "excluded_units": "rx"}
	for key: String in event_keys:
		if events.has(key): out[event_keys[key]] = events[key]
	return out
