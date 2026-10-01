extends SceneTree

## Batch «team session» (3 людей против 3 ИИ): правила и механика, которые видны только в
## игре. По проверке на пункт:
##   4/8  — удар противотанкиста по клетке с бойцом проходит ВСЕ проверки (линия, стена,
##          дальность): раньше такая клетка пропускалась сразу, и ИИ бил по корпусу машины
##          через клетку пассажира под любым углом, бросая заведомые 7+;
##   11   — мирных на готовой карте не больше, чем задано ползунком, и прорежены равномерно;
##   22   — полоса развёртывания по выбранной зоне — одна формула для расстановки и превью;
##   24   — сгенерированная карта помнит окружение, плитки берут его вариант;
##   15   — ластик стирает пиксели там, где прошёл, а не точки ломаной;
##   7    — осколки останавливаются о стену, а не «проваливаются» в неё;
##   5/11 — темп ИИ и число мирных едут гостям вместе с правилами лобби;
##   14   — текст чата не может вставить разметку.

var fails: PackedStringArray = []

func ck(c: bool, w: String) -> void:
	if not c:
		fails.append(w)

func _initialize() -> void:
	_blast_cell_checks_occupied_cells()
	_civilians_are_thinned_evenly()
	_bands_follow_chosen_zone()
	_generated_maps_know_their_environment()
	_eraser_clears_pixels_where_it_went()
	_shards_stop_at_walls()
	_lobby_rules_carry_new_settings()
	_chat_text_is_escaped()
	if fails.is_empty():
		print("team session: blast checks, civilians, zones, environments, eraser, shards and lobby rules all hold")
		quit(0)
		return
	printerr("team session: %d failure(s)" % fails.size())
	for f in fails:
		printerr("  " + f)
	quit(1)

func _open_field(w: int, h: int, spawns: Array) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = true
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_enabled = false
	return {"s": st, "r": r, "m": m}

## 4/8: противотанкист в (2, 2), боец противника в (9, 5) — не на линии огня. Раньше
## занятая клетка отвечала "" сразу; теперь — «не на линии».
func _blast_cell_checks_occupied_cells() -> void:
	var f := _open_field(16, 10, [[Vector2i(2, 2), "anti_tank", MCF.Owner.PLAYER_1],
			[Vector2i(9, 5), "light_infantry", MCF.Owner.PLAYER_2]])
	var r: GameActionResolver = f["r"]
	var st: GameState = f["s"]
	var at := st.grid.cell(Vector2i(2, 2)).occupant
	ck(r.can_blast_cell(at, Vector2i(9, 5)) != "", "an occupied cell off the firing line can't be blasted")
	# На линии и в пределах дальности — можно, как и любую другую клетку.
	var f2 := _open_field(16, 10, [[Vector2i(2, 2), "anti_tank", MCF.Owner.PLAYER_1],
			[Vector2i(6, 2), "light_infantry", MCF.Owner.PLAYER_2]])
	var at2: UnitInstance = (f2["s"] as GameState).grid.cell(Vector2i(2, 2)).occupant
	ck((f2["r"] as GameActionResolver).can_blast_cell(at2, Vector2i(6, 2)) == "",
			"an occupied cell on the line and in range can still be blasted")

## 11: на карте 9 мирных, ползунок — 3: остаются ровно 3, по одному из каждой трети.
func _civilians_are_thinned_evenly() -> void:
	var m := MapData.new(20, 6)
	for y in 6:
		for x in 20:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	m.set_spawn(Vector2i(0, 0), "light_infantry", MCF.Owner.PLAYER_1)
	m.set_spawn(Vector2i(19, 0), "light_infantry", MCF.Owner.PLAYER_2)
	for i in 9:
		m.set_spawn(Vector2i(1 + i * 2, 4), "civilian", MCF.Owner.NEUTRAL)
	var keep := GameConfig.civilian_count
	GameConfig.civilian_count = 3
	var st := m.build_state(3)
	var xs: Array = []
	for u in st.all_units():
		if MCF.is_neutral(u.owner):
			xs.append(u.coord.x)
	xs.sort()
	ck(xs.size() == 3, "the civilians slider caps a prepared map (%d left)" % xs.size())
	ck(xs.size() == 3 and xs[0] < 7 and xs[1] >= 7 and xs[1] < 13 and xs[2] >= 13,
			"the kept civilians are spread over the map: %s" % str(xs))
	GameConfig.civilian_count = 0
	var none := 0
	for u in m.build_state(3).all_units():
		if MCF.is_neutral(u.owner):
			none += 1
	ck(none == 0, "zero on the slider means no civilians (%d)" % none)
	GameConfig.civilian_count = keep

## 22: полосы на карте без зон — половинки на двоих, на троих три подряд без зазоров.
func _bands_follow_chosen_zone() -> void:
	ck(MapData.band_of(0, 2, 30) == Vector2i(0, 15) and MapData.band_of(1, 2, 30) == Vector2i(15, 30),
			"two sides split the board in halves")
	var b0 := MapData.band_of(0, 3, 30)
	var b1 := MapData.band_of(1, 3, 30)
	var b2 := MapData.band_of(2, 3, 30)
	ck(b0.x == 0 and b0.y == b1.x and b1.y == b2.x and b2.y == 30, "three bands tile the board: %s %s %s" % [b0, b1, b2])
	ck(MapData.band_of(9, 3, 30) == b2, "an out-of-range zone falls into the last band")

## 24: стиль → окружение, а окружение → своя плитка стены.
func _generated_maps_know_their_environment() -> void:
	for st in MapGen.STYLE_ENV.size():
		var m := MapGen.generate({"style": st, "seed": 7, "size": 0})
		ck(m.env == MapGen.STYLE_ENV[st], "style %d is tagged %s (got %s)" % [st, MapGen.STYLE_ENV[st], m.env])
		ck(MapData.from_dict(m.to_dict()).env == m.env, "the environment survives saving the map")
	ck(TerrainTiles.env_name("wall", "station") == "wall_station", "a station wall uses the station tiles")
	ck(TerrainTiles.env_name("glass", "station") == "glass", "a tile without an environment variant stays generic")
	var v := TerrainTiles.variant_of(Vector2i(3, 9), 6)
	ck(v >= 0 and v < 6 and v == TerrainTiles.variant_of(Vector2i(3, 9), 6), "a cell's variant is stable")

## 15: две линии кистью, ластик поперёк — стёрто ровно там, где прошёл ластик.
func _eraser_clears_pixels_where_it_went() -> void:
	var c := DrawCanvas.new()
	var red := Color(0.9, 0.2, 0.2)
	c.stroke(Vector2(10, 50), Vector2(300, 50), 4.0, red)
	c.stroke(Vector2(10, 150), Vector2(300, 150), 4.0, red)
	c.stroke(Vector2(150, 0), Vector2(150, 200), 12.0, Color(0, 0, 0, 0))
	var img: Image = c._tiles[Vector2i(0, 0)]["img"]
	ck(img.get_pixel(60, 50).a > 0.5 and img.get_pixel(240, 150).a > 0.5, "the brush leaves paint")
	ck(img.get_pixel(150, 50).a == 0.0 and img.get_pixel(150, 150).a == 0.0, "the eraser clears where it passed")
	ck(img.get_pixel(120, 50).a > 0.5 and img.get_pixel(180, 150).a > 0.5,
			"and only there — the rest of the line stays (no straight line re-joins the gap)")

## 7: стена с x ≥ 6 — ни один осколок окна в (4, 4) не ложится за неё.
func _shards_stop_at_walls() -> void:
	var fx := FxDecals.new()
	fx.bounds = Vector2(20, 20)
	fx.solid_at = func(cc: Vector2i) -> bool: return cc.x >= 6
	fx.apply([{"fx": "shards", "at": Vector2i(4, 4), "from": Vector2i(0, 4)}])
	ck(not fx.flying.is_empty(), "the window throws shards")
	for f: Dictionary in fx.flying:
		ck((f["to"] as Vector2).x < 6.0, "a shard flew into the wall: %s" % f["to"])

## 5/11: новые правила лобби доходят до гостя.
func _lobby_rules_carry_new_settings() -> void:
	var keep_c := GameConfig.civilian_count
	var keep_s := GameConfig.ai_speed
	GameConfig.civilian_count = 17
	GameConfig.ai_speed = 2.0
	var rules := NetHandoff.encode_rules()
	GameConfig.civilian_count = 200
	GameConfig.ai_speed = 1.0
	NetHandoff.apply_rules(rules)
	ck(GameConfig.civilian_count == 17 and GameConfig.ai_speed == 2.0,
			"civilians (%d) and AI speed (%.1f) reach the guest" % [GameConfig.civilian_count, GameConfig.ai_speed])
	GameConfig.civilian_count = keep_c
	GameConfig.ai_speed = keep_s
	GameConfig.roster = null

func _chat_text_is_escaped() -> void:
	ck(ChatBox.escape("[b]boom[/b]") == "[lb]b]boom[lb]/b]", "chat text can't inject BBCode")
