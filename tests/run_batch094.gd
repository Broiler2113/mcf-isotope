extends SceneTree
## Batch 0.9.4 (issues-fix-10): счёт живых и павших, случайные события на полезном участке
## карты, рейдеры, которые доходят до станции, техтуннели без хвостов в космос, постройки
## астероида из обшивки станции и новая раскладка текстур по папкам.

const TS = preload("res://tests/TestSupport.gd")

var fails: PackedStringArray = []

func ck(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails.append(what)

func _initialize() -> void:
	_death_ledger()
	_events_land_on_the_useful_plot()
	_raiders_reach_a_station()
	_no_orphan_tunnels()
	_asteroid_is_built_of_station_plating()
	_textures_live_in_folders()
	if fails.is_empty():
		print("batch 0.9.4: counts, events, raiders, tunnels, asteroid plating and texture"
				+ " folders all hold")
	else:
		print("batch 0.9.4: %d failure(s)" % fails.size())
	quit(1 if not fails.is_empty() else 0)

# --- item 1: павшие считаются по ледж, а не по трупам на доске ---------------------------
## Тело выбывает из партии, как только его подняли щитом (или сложили в кучу), — счёт по
## трупам на доске от этого полз назад. Ледж state.deaths только растёт и переживает и
## откат, и пересылку по сети.
func _death_ledger() -> void:
	var state := TS.build_map().build_state(TS.SEED)
	var resolver := GameActionResolver.new(state)
	var victim: UnitInstance = null
	var taker: UnitInstance = null
	for u: UnitInstance in state.all_units():
		if u.owner == MCF.Owner.PLAYER_2 and victim == null:
			victim = u
		elif u.owner == MCF.Owner.PLAYER_1 and taker == null:
			taker = u
	ck(victim != null and taker != null, "the board has somebody to kill and somebody to carry")
	if victim == null or taker == null:
		return
	resolver._kill(victim)
	ck(int(state.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1, "a death is counted against its side")
	var snap := state.snapshot()
	# Тело уходит из партии — ровно то, что делают подбор щита, куча и кресло.
	state.grid.cell(victim.coord).occupant = null
	state.remove_unit(victim.id)
	var still := 0
	for u: UnitInstance in state.all_units():
		if u.owner == MCF.Owner.PLAYER_2 and u.status == MCF.Status.CORPSE:
			still += 1
	ck(still == 0, "the body is off the board")
	ck(int(state.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1,
			"and the side is still one man down (%s)" % str(state.deaths))
	state.deaths[MCF.Owner.PLAYER_2] = 7       # откат обязан вернуть ледж, а не оставить мой
	state.restore(snap)
	ck(int(state.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1, "undo brings the ledger back")
	var wire := StateCodec.encode(state)
	var there := StateCodec.decode(wire)
	ck(int(there.deaths.get(MCF.Owner.PLAYER_2, 0)) == 1, "and it travels over the wire")
	# Дрон — техника станции: ни в живых, ни в павших.
	var drone := state.spawn_unit(load("res://src/data/units/drone.tres"),
			Vector2i(1, 1), MCF.Owner.PLAYER_1, false)
	drone.is_drone = true
	resolver._kill(drone)
	ck(int(state.deaths.get(MCF.Owner.PLAYER_1, 0)) == 0, "a downed drone is not a casualty")

# --- item 6: газ и обстрел падают на полезный участок ------------------------------------
## На станции край карты — вакуум; зона, выпавшая там, травила пустоту. Зона обязана
## пересекаться с рамкой проходимого участка.
func _events_land_on_the_useful_plot() -> void:
	var outside := 0
	var zones := 0
	for seed_value: int in [11, 23, 57, 101]:
		var m := MapGen.generate({"style": MapGen.Style.STATION, "size": 2, "seed": seed_value,
				"civilians": 0})
		var state := m.build_state(seed_value)
		var resolver := GameActionResolver.new(state)
		var area := resolver._useful_rect()
		for id: String in [RandomEvents.GAS, RandomEvents.MORTAR]:
			for _i in 6:
				var p := resolver._roll_event_params(id)
				var z := Rect2i(int(p["x"]), int(p["y"]), int(p["w"]), int(p["h"]))
				zones += 1
				if not area.intersects(z):
					outside += 1
	ck(outside == 0, "%d of %d event zones fall outside the useful plot" % [outside, zones])

# --- item 6: рейдеры доходят до станции ---------------------------------------------------
## У станции по краям карты вакуум, а жилое начинается клеток через двадцать. Раньше армия
## искала место для высадки только у самой кромки и всегда «поворачивала назад».
func _raiders_reach_a_station() -> void:
	var landed := 0
	var tried := 0
	for seed_value: int in [11, 23, 57, 101]:
		var m := MapGen.generate({"style": MapGen.Style.STATION, "size": 2, "seed": seed_value,
				"civilians": 0})
		var state := m.build_state(seed_value)
		var resolver := GameActionResolver.new(state)
		for edge in 4:
			tried += 1
			var p := {"edge": edge, "from": state.grid.width / 3, "len": 8}
			if not resolver._army_spawn_cells(p).is_empty():
				landed += 1
	ck(landed == tried, "raiders find a landing on every station edge (%d of %d)" % [landed, tried])

# --- items 2 и 3: ни хвостов в космос, ни решета из пустых отсеков -------------------------
## Проход, у которого ВСЕ четыре соседа — пустота или обшивка, никуда не ведёт: это та самая
## нитка, уходившая из станции в космос. Пустых отсеков — считаем дырки: прямоугольные
## каверны внутри обвода станции больше не десятками.
func _no_orphan_tunnels() -> void:
	var dead_ends := 0
	var halls := 0
	for seed_value: int in [11, 23, 57, 101, 7]:
		for size: int in [3, 4]:
			var g := MapGen.build({"style": MapGen.Style.STATION, "size": size,
					"seed": seed_value, "civilians": 0})
			for y in g.h:
				for x in g.w:
					var k: int = g._k[y * g.w + x]
					if k != MapGen.K_HALL and k != MapGen.K_MAINT:
						continue
					halls += 1
					var open := 0
					for d: Vector2i in MapGen.N4:
						var nk: int = g._kind(x + d.x, y + d.y)
						if nk != MapGen.K_VOID and nk != MapGen.K_WALL:
							open += 1
					if open == 0:
						dead_ends += 1
	ck(halls > 0 and dead_ends == 0,
			"no corridor cell leads nowhere (%d of %d)" % [dead_ends, halls])

# --- item 11: постройки астероида — из обшивки станции ------------------------------------
func _asteroid_is_built_of_station_plating() -> void:
	var station := 0
	var other := 0
	for seed_value: int in [11, 23, 57]:
		var m := MapGen.generate({"style": MapGen.Style.ASTEROID, "size": 2, "seed": seed_value,
				"civilians": 0})
		for i in m.width * m.height:
			if m.feature_id[i] != MCF.FEATURE_WALL:
				continue
			var look := m.get_look(i)
			if MCF.wall_look_tile(look) == "wall_station":
				station += 1
			elif MCF.wall_look_tile(look) != "":
				other += 1
	ck(station > 0 and other == 0,
			"asteroid buildings are plated like a station (%d station, %d other)" % [station, other])

# --- item 5: текстуры по папкам, лист автотайла — ровно 16 плиток -------------------------
func _textures_live_in_folders() -> void:
	Sprites.reload_overrides()
	ck(Sprites.has_override("wall_station") and Sprites.has_override("floor_grass"),
			"textures are found inside their folders")
	ck(not Sprites.has_override("sample"), "a sample is a template, not a tile")
	var sheets := 0
	var wrong := ""
	for name: String in ["wall", "wall_station", "wall_town", "glass", "sandbags", "bed", "sofa"]:
		var tex := Sprites.texture_of(name + Sprites.AUTOTILE_SUFFIX)
		if tex == null:
			wrong = name + " has no sheet"
			continue
		sheets += 1
		if tex.get_height() != tex.get_width():
			wrong = "%s sheet is %dx%d, not a single 4x4 block" % [
					name, tex.get_width(), tex.get_height()]
	ck(sheets == 7 and wrong == "", "every autotile sheet is 16 tiles (%s)" % wrong)
	var missing: PackedStringArray = []
	for section: String in ["walls", "floors", "doors", "features", "furniture", "decals"]:
		var d := DirAccess.open("res://textures/" + section)
		if d == null:
			missing.append(section)
			continue
		for obj: String in d.get_directories():
			if not FileAccess.file_exists("res://textures/%s/%s/sample.png" % [section, obj]) \
					and obj != "blood_pool" and obj != "blood_splatter":
				missing.append(section + "/" + obj)
	ck(missing.is_empty(), "every object folder carries its sample (%s)" % ", ".join(missing))
