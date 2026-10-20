extends "res://tests/SuiteBase.gd"
## Battle sounds: one shot sound per bullet.

func run() -> void:
	shot_sound_cues()

func _lane(from: Vector2i, to: Vector2i, weapon := "") -> Dictionary:
	var ev := {"fx": "lane", "from": [from.x, from.y], "to": [to.x, to.y], "owner": 0, "kind": "shot"}
	if weapon != "": ev["weapon"] = weapon
	return ev

func shot_sound_cues() -> void:
	var fx := FxDecals.new()
	var cues: Array = []
	var volleys: Array = []
	fx.sound_requested.connect(func(id: String, _c: Vector2i, _o: int) -> void: cues.append(id))
	fx.volley_requested.connect(func(id: String, _c: Vector2i, _o: int, n: int) -> void: volleys.append([id, n]))
	fx.apply_lanes([_lane(Vector2i(2, 2), Vector2i(8, 2), "heavy_infantry"),
		{"fx": "tracer", "at": Vector2i(2, 2), "from": [2, 2], "to": [8, 2], "count": 2}])
	ck(cues == ["rifle"] and volleys == [["rifle", 1]], "two bullets of three: two shots heard, no more")
	cues.clear(); volleys.clear()
	fx.apply_lanes([_lane(Vector2i(2, 4), Vector2i(8, 4), "machinegunner"),
		{"fx": "tracer", "at": Vector2i(2, 4), "from": [2, 4], "to": [8, 4], "count": 4}])
	ck(cues == ["mg"] and volleys == [["mg", 3]], "a four-round burst is four machine-gun shots")
	cues.clear()
	fx.apply([{"fx": "chunks", "at": Vector2i(5, 5), "from": Vector2i(4, 5), "fid": MCF.FEATURE_WALL, "crushed": true}])
	ck(cues.has("crunch") and not cues.has("structure"), "a wall pushed over by a hull crunches")
	cues.clear()
	fx.apply([{"fx": "chunks", "at": Vector2i(5, 5), "from": Vector2i(4, 5), "fid": MCF.FEATURE_WALL}])
	ck(cues.has("structure"), "a wall blown down still crashes")
