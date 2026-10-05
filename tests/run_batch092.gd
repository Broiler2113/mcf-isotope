extends SceneTree
## Release 0.9.2: стрельба по окнам и сквозь стёкла по правилу игрока — очередь с выбором
## числа пуль, попадание в стекло, спасбросок стекла, осыпание, дальше летят лишь прошедшие;
## у каждого стекла на линии — по порядку.
var fails := 0
func ck(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: fails += 1

func field(w: int, h: int, spawns: Array, feats: Dictionary = {}) -> Dictionary:
	var m := MapData.new(w, h)
	for y in h:
		for x in w:
			m.set_cell(Vector2i(x, y), MCF.FLOOR_NORMAL, 0.0, false, "")
	for c: Vector2i in feats:
		m.set_cell(c, MCF.FLOOR_NORMAL, 0.0, false, feats[c])
	for sp in spawns:
		m.set_spawn(sp[0], sp[1], sp[2])
	GameConfig.civilians_enabled = false
	var st := m.build_state(5)
	var r := GameActionResolver.new(st)
	r.fog_mode = MCF.Fog.OFF
	while st.active_player() != 0:
		r.resolve(EndTurnIntent.new())
	return {"s": st, "r": r}

func _events(res: ActionResult, kind: String) -> Array:
	return res.dice_events.filter(func(e: Dictionary) -> bool: return e.get("kind", "") == kind)

func _initialize() -> void:
	_window_burst()
	_through_panes()
	print("batch 0.9.2: windows take a chosen burst; every pane on the line is hit, saves, shatters in order" if fails == 0
			else "batch 0.9.2: %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)

## По окну — обычная очередь: игрок выбирает число пуль, остаток дострелить без ОД.
func _window_burst() -> void:
	var f := field(16, 6, [[Vector2i(2, 2), "heavy_infantry", 0], [Vector2i(14, 5), "light_infantry", 1]],
			{Vector2i(6, 2): MCF.FEATURE_ARMOR_GLASS})
	var st: GameState = f["s"]
	var r: GameActionResolver = f["r"]
	var hi := st.grid.cell(Vector2i(2, 2)).occupant
	var ap0 := hi.remaining_ap
	var rof := hi.rate_of_fire()
	var res := r.resolve(ShootIntent.new(hi.id, -1, 1, Vector2i(6, 2)))
	var g := _events(res, "glass")
	ck(res.ok and g.size() == 1 and (g[0]["hits"] as Array).size() == 1,
			"a window shot fires the chosen number of bullets (1 of %d)" % rof)
	ck(hi.remaining_ap == ap0 - 1 and hi.action_state != null and hi.action_state.remaining_shots == rof - 1,
			"…for 1 AP, and the rest of the burst stays")
	ck(int(g[0]["need"]) == r.pane_hit_need(hi, Vector2i(6, 2)) and int(g[0]["save"]) == 4,
			"the bullet rolls to hit the window by distance, armored glass saves on 4+")
	var saves := (g[0]["saves"] as Array).size()
	var hit_n := (g[0]["hits"] as Array).filter(func(h: Dictionary) -> bool: return h["hit"]).size()
	ck(saves == hit_n, "the glass saves only against bullets that hit it (%d hits, %d saves)" % [hit_n, saves])
	if MCF.is_glass(st.grid.cell(Vector2i(6, 2)).feature_id):
		var res2 := r.resolve(ShootIntent.new(hi.id, -1, -1, Vector2i(6, 2)))
		var g2 := _events(res2, "glass")
		ck(res2.ok and hi.remaining_ap == ap0 - 1 and g2.size() == 1 and (g2[0]["hits"] as Array).size() == rof - 1,
				"the rest of the burst goes at the window without another AP")
	# Окно бьётся, только если прошла хоть одна пуля; осколки — в событии броска.
	var broke := 0
	var held := 0
	for i in 40:
		var f2 := field(16, 6, [[Vector2i(2, 2), "heavy_infantry", 0], [Vector2i(14, 5), "light_infantry", 1]],
				{Vector2i(6, 2): MCF.FEATURE_GLASS})
		var st2: GameState = f2["s"]
		st2.dice = DiceService.new(500 + i)
		var u := st2.grid.cell(Vector2i(2, 2)).occupant
		var rr: ActionResult = f2["r"].resolve(ShootIntent.new(u.id, -1, -1, Vector2i(6, 2)))
		var ev: Dictionary = _events(rr, "glass")[0]
		var through := (ev["saves"] as Array).filter(func(sv: Dictionary) -> bool: return not sv["held"]).size()
		var gone := not MCF.is_glass(st2.grid.cell(Vector2i(6, 2)).feature_id)
		if gone != (through > 0) or bool(ev["broke"]) != gone or (gone and (ev["fx"] as Array).is_empty()):
			ck(false, "seed %d: the window breaks exactly when a bullet gets through" % (500 + i))
			return
		if gone:
			broke += 1
		else:
			held += 1
	ck(broke > 0 and held > 0, "the window breaks exactly when a bullet gets through (%d broke, %d held)" % [broke, held])

## Сквозь два стекла к цели: стекло за стеклом, промахи и удержанные пули теряются.
func _through_panes() -> void:
	var seen_two := false
	var seen_lost := false
	for i in 60:
		var f := field(20, 6, [[Vector2i(2, 2), "heavy_infantry", 0], [Vector2i(12, 2), "light_infantry", 1]],
				{Vector2i(5, 2): MCF.FEATURE_GLASS, Vector2i(8, 2): MCF.FEATURE_ARMOR_GLASS})
		var st: GameState = f["s"]
		st.dice = DiceService.new(900 + i)
		var r: GameActionResolver = f["r"]
		var hi := st.grid.cell(Vector2i(2, 2)).occupant
		var foe := st.grid.cell(Vector2i(12, 2)).occupant
		var res := r.resolve(ShootIntent.new(hi.id, foe.id))
		if not res.ok:
			ck(false, "shot through two panes resolves (%s)" % res.reason)
			return
		var g := _events(res, "glass")
		var atk: Array = _events(res, "attack")
		var order_ok: bool = not g.is_empty() and g[0]["cell"] == Vector2i(5, 2)
		var flying := hi.rate_of_fire()
		var chain_ok := true
		for ev: Dictionary in g:
			chain_ok = chain_ok and (ev["hits"] as Array).size() == flying
			flying = (ev["saves"] as Array).filter(func(sv: Dictionary) -> bool: return not sv["held"]).size()
		if g.size() == 1:
			chain_ok = chain_ok and flying == 0   # второе стекло не встретило ни одной пули
		var shots_at_target: int = (atk[0]["shots"] as Array).size() if not atk.is_empty() else -1
		if not (order_ok and chain_ok and shots_at_target == flying):
			ck(false, "seed %d: panes in order, each gets only the bullets the last let through, the target only the rest"
					% (900 + i))
			return
		if g.size() == 2:
			if not seen_two:
				ck(int(g[1]["save"]) == 4, "armored glass on the line now stops bullets too (saves 4+)")
			seen_two = true
		if flying < hi.rate_of_fire():
			seen_lost = true
		# Целое стекло — только если ни одна пуля его не прошла.
		for ev: Dictionary in g:
			var whole := MCF.is_glass(st.grid.cell(ev["cell"]).feature_id)
			if whole == bool(ev["broke"]):
				ck(false, "seed %d: a pane breaks exactly when a bullet passes it" % (900 + i))
				return
	ck(seen_two and seen_lost,
			"bullets reach the second pane only through the first, and the target only through both (60 seeds)")
